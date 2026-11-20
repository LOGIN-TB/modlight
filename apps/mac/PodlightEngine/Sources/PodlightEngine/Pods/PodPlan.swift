import Foundation

/// Builds the RunPod request for a model: the stock vLLM image, Podlight's start script as the
/// container command, the dead-man switch beside the engine, and a disk that survives stop/start.
public enum PodPlan {
    /// Pinned: `latest` has broken freshly released architectures before. v0.28.0 is the version
    /// RunPod Launcher was measured with (2026-08-30), and its parser names are the ones used here.
    public static let image = "vllm/vllm-openai:v0.28.0"
    public static let enginePort = 8000
    public static let watchdogPort = 8001
    /// Extra time past "Läuft bis" before the pod's own deadline fires. The app stops it on time;
    /// the deadline is only the backstop for when the app cannot.
    public static let deadlineGrace: TimeInterval = 10 * 60

    public static func request(for model: PodlightModel, podKey: String, huggingFaceToken: String?,
                               runUntil: Date?, heartbeatMinutes: Int) -> CreatePodRequest {
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
            // Downloads go to the persistent disk, so a resumed pod starts without downloading.
            "HF_HOME": "/workspace/hf",
        ]
        if let parser = model.toolCallParser { env["PODLIGHT_TOOL_PARSER"] = parser }
        if let parser = model.reasoningParser { env["PODLIGHT_REASONING_PARSER"] = parser }
        if let token = huggingFaceToken, !token.isEmpty { env["HF_TOKEN"] = token }
        if let runUntil { env["PODLIGHT_DEADLINE"] = String(Int(runUntil.addingTimeInterval(deadlineGrace).timeIntervalSince1970)) }

        return CreatePodRequest(
            name: "podlight-\(model.name)".prefix(60).description,
            image: image,
            cloud: model.preferredGPU?.cloud ?? .secure,
            gpu: .init(id: model.preferredGPU?.gpuId ?? "placeholder"),
            disk: 30,
            ports: ["\(enginePort)/http", "\(watchdogPort)/http"],
            env: env,
            entrypoint: ["/bin/bash", "-c"],
            cmd: [#"echo "$PODLIGHT_BOOT_B64" | base64 -d > /tmp/podlight-boot.sh && exec bash /tmp/podlight-boot.sh"#],
            mounts: .init(persistentGB: persistentGB(for: model)))
    }

    /// Room for the weights plus tokenizer, compile caches and a margin.
    public static func persistentGB(for model: PodlightModel) -> Int {
        Int((model.weightBytes / 1_000_000_000 * 1.15).rounded(.up)) + 10
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
    public static func choices(for model: PodlightModel, catalog: [RunpodGPUType], limit: Int = 6) -> [GPUChoice] {
        // A fallback card must hold the context this model is configured for, not just the
        // weights: vLLM refuses to start otherwise, after the download.
        var ordered = GPUSuggestion.options(for: model.info, catalog: catalog, goal: model.goal)
            .filter { option in
                Capacity.plan(gpuMemoryGiB: Double(option.memoryGiB), weightsGiB: model.info.weightsGiB,
                              nativeContextTokens: model.nativeContextTokens,
                              chosen: .init(contextTokens: model.contextTokens, concurrency: model.concurrency)).fits
            }
            .map(\.choice)
        if let preferred = model.preferredGPU {
            ordered.removeAll { $0 == preferred }
            ordered.insert(preferred, at: 0)
        }
        return Array(ordered.prefix(limit))
    }
}
