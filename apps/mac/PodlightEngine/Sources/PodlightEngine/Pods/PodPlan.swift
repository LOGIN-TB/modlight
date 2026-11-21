import Foundation

/// Builds the RunPod request for a model: a stock engine image (vLLM, or llama.cpp for GGUF),
/// Podlight's start script as the container command, the dead-man switch beside the engine, and
/// optionally a disk that survives stop/start.
public enum PodPlan {
    /// Pinned: `latest` has broken freshly released architectures before. v0.28.0 is the version
    /// RunPod Launcher was measured with (2026-08-30), and its parser names are the ones used here.
    public static let image = "vllm/vllm-openai:v0.28.0"
    /// The image is built on CUDA 13.0.2 (NVIDIA_REQUIRE_CUDA=cuda>=13.0, read from its config on
    /// 2026-11-20). A host with an older driver cannot start it, and RunPod has 12.4 hosts.
    public static let minCudaVersion = "13.0"

    /// llama.cpp's server image, `full` because it carries the Python the watchdog needs. Pinned to
    /// a build; its cuda12 flavour needs a host with CUDA 12.8 or newer (NVIDIA_REQUIRE_CUDA).
    public static let llamaImage = "ghcr.io/ggml-org/llama.cpp:full-cuda12-b12602"
    public static let llamaMinCudaVersion = "12.8"

    public static func image(for engine: InferenceEngine) -> String { engine == .vllm ? image : llamaImage }
    public static func minCudaVersion(for engine: InferenceEngine) -> String {
        engine == .vllm ? minCudaVersion : llamaMinCudaVersion
    }
    public static let enginePort = 8000
    public static let watchdogPort = 8001
    /// Extra time past "Läuft bis" before the pod's own deadline fires. The app stops it on time;
    /// the deadline is only the backstop for when the app cannot.
    public static let deadlineGrace: TimeInterval = 10 * 60

    public static func request(for model: PodlightModel, podKey: String, huggingFaceToken: String?,
                               runUntil: Date?, heartbeatMinutes: Int, dataCenterIds: [String]? = nil) -> CreatePodRequest {
        let cards = model.preferredGPU?.count ?? 1
        var env: [String: String] = [
            "PODLIGHT_MODEL": model.repoId,
            "PODLIGHT_SERVED_NAME": model.name,
            "PODLIGHT_API_KEY": podKey,
            "PODLIGHT_MAX_LEN": String(model.contextTokens),
            // vLLM queues what does not fit; a small cap keeps hybrid-attention models startable.
            "PODLIGHT_MAX_SEQS": String(max(4, model.concurrency * 2)),
            "PODLIGHT_HEARTBEAT_MINUTES": String(heartbeatMinutes),
            "PODLIGHT_WATCHDOG_B64": resource("watchdog", "py").base64EncodedString(),
            "PODLIGHT_BOOT_B64": resource("boot", "sh").base64EncodedString(),
            "PODLIGHT_TP": String(cards),
            "PODLIGHT_ENGINE": model.engine == .vllm ? "vllm" : "llamacpp",
            // Xet's high-performance mode replaced hf_transfer for fast Hub downloads.
            "HF_XET_HIGH_PERFORMANCE": "1",
        ]
        // With a kept disk, downloads go there so a resumed pod starts without downloading.
        if model.keepDisk {
            env["HF_HOME"] = "/workspace/hf"
            env["LLAMA_CACHE"] = "/workspace/llama-cache"
        }
        if model.engine == .llamaCpp {
            env["PODLIGHT_QUANT"] = model.quant ?? "Q4_K_M"
            env["PODLIGHT_PARALLEL"] = String(max(1, model.concurrency))
        }
        if let parser = model.toolCallParser { env["PODLIGHT_TOOL_PARSER"] = parser }
        if let parser = model.reasoningParser { env["PODLIGHT_REASONING_PARSER"] = parser }
        if let token = huggingFaceToken, !token.isEmpty { env["HF_TOKEN"] = token }
        if let runUntil { env["PODLIGHT_DEADLINE"] = String(Int(runUntil.addingTimeInterval(deadlineGrace).timeIntervalSince1970)) }

        return CreatePodRequest(
            name: "podlight-\(model.name)".prefix(60).description,
            image: image(for: model.engine),
            cloud: model.preferredGPU?.cloud ?? .secure,
            gpu: .init(id: model.preferredGPU?.gpuId ?? "placeholder", count: cards, minCudaVersion: minCudaVersion(for: model.engine)),
            disk: containerGB(for: model),
            ports: ["\(enginePort)/http", "\(watchdogPort)/http"],
            env: env,
            entrypoint: ["/bin/bash", "-c"],
            cmd: [#"echo "$PODLIGHT_BOOT_B64" | base64 -d > /tmp/podlight-boot.sh && exec bash /tmp/podlight-boot.sh"#],
            mounts: model.keepDisk ? .init(persistentGB: persistentGB(for: model)) : nil,
            dataCenterIds: dataCenterIds)
    }

    /// Room for the weights plus tokenizer, compile caches and a margin.
    public static func persistentGB(for model: PodlightModel) -> Int {
        Int((model.weightBytes / 1_000_000_000 * 1.15).rounded(.up)) + 10
    }

    /// Without a kept disk the download lands on the container disk, which must hold it.
    public static func containerGB(for model: PodlightModel) -> Int {
        model.keepDisk ? 30 : Int((model.weightBytes / 1_000_000_000 * 1.15).rounded(.up)) + 20
    }

    /// Storage cost per hour while this model's pod runs.
    public static func storagePerHour(for model: PodlightModel) -> Double {
        StoragePricing.runningPerHour(containerGB: containerGB(for: model),
                                      volumeGB: model.keepDisk ? persistentGB(for: model) : 0)
    }

    /// RunPod's HTTP proxy for one port of a pod.
    public static func proxyURL(_ podId: String, _ port: Int) -> URL {
        URL(string: "https://\(podId)-\(port).proxy.runpod.net")!
    }

    static func resource(_ name: String, _ ext: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("missing bundled resource \(name).\(ext)")
        }
        return data
    }

    /// The fallback order for a start: the user's card first, then the suggestion for the goal.
    /// Every fallback holds the configured context (vLLM refuses to start otherwise, after the
    /// download) and obeys the hosting rules.
    public static func choices(for model: PodlightModel, catalog: [RunpodGPUType], hosting: HostingPolicy = .anywhere,
                               limit: Int = 6) -> [GPUChoice] {
        var ordered = GPUSuggestion.options(for: model.info, catalog: catalog, goal: model.goal,
                                            context: model.contextTokens, concurrency: model.concurrency,
                                            hosting: hosting).map(\.choice)
        if let preferred = model.preferredGPU, hosting.clouds.contains(preferred.cloud) {
            ordered.removeAll { $0 == preferred }
            ordered.insert(preferred, at: 0)
        }
        return Array(ordered.prefix(limit))
    }
}
