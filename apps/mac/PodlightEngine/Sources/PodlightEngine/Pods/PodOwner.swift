import Foundation

/// Which Mac manages a pod, written into the pod's name at RunPod: `podlight-<model>@<mac>`.
///
/// RunPod keeps the name while a pod is stopped and renames without a restart (measured
/// 2026-11-23), so the name is the one marker every Mac sees, also for pods from older versions
/// and for a Mac that was off while another took its model over. Model names never contain `@`.
public enum PodOwner {
    public static let prefix = "podlight-"
    static let serverPrefix = "podlight-srv-"
    static let separator: Character = "@"
    static let maxNameLength = 60

    /// A short, stable tag for this Mac: its name as a slug plus four random hex digits.
    public static func makeTag(hostName: String) -> String {
        let slug = hostName.lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
            .reduce(into: "") { out, c in if !(c == "-" && out.last == "-") { out.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let head = String(slug.prefix(20)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let random = String(format: "%04x", UInt16.random(in: .min ... .max))
        return (head.isEmpty ? "mac" : head) + "-" + random
    }

    /// The pod name for a model managed by the Mac with this tag.
    public static func podName(model: String, owner: String?) -> String {
        guard let owner else { return String((prefix + model).prefix(maxNameLength)) }
        let room = maxNameLength - prefix.count - owner.count - 1
        return prefix + String(model.prefix(max(1, room))) + String(separator) + owner
    }

    /// The managing Mac's tag, or nil for a pod named before 0.6.
    public static func owner(ofPodName name: String) -> String? {
        guard name.hasPrefix(prefix), let at = name.lastIndex(of: separator) else { return nil }
        let tag = String(name[name.index(after: at)...])
        return tag.isEmpty ? nil : tag
    }

    /// A pod a Mac created (not a server's, not someone else's).
    public static func isMacPod(_ name: String) -> Bool {
        name.hasPrefix(prefix) && !name.hasPrefix(serverPrefix)
    }

    /// The readable part of a tag, without its random suffix: `holgers-macbook-pro`.
    public static func displayName(of tag: String) -> String {
        guard let dash = tag.lastIndex(of: "-"), tag.distance(from: dash, to: tag.endIndex) == 5 else { return tag }
        return String(tag[..<dash])
    }
}

/// A Podlight pod in the RunPod account that another Mac manages (or that an older version
/// created), with what is needed to take it over.
public struct ForeignPod: Sendable, Equatable, Identifiable {
    public var id: String
    /// The model's name for agents, from the pod's environment.
    public var servedName: String
    public var repoId: String
    public var engine: InferenceEngine
    public var quant: String?
    public var contextTokens: Int
    public var status: PodState.Status
    public var gpuId: String?
    public var gpuCount: Int
    public var cloud: RunpodCloud?
    /// GPU price per hour while running.
    public var pricePerHour: Double?
    public var persistentGB: Int?
    public var containerGB: Int?
    public var dataCenterId: String?
    /// The managing Mac's tag; nil for a pod from before 0.6.
    public var owner: String?

    var podKey: String
    var toolCallParser: String?
    var reasoningParser: String?
    var maxSeqs: Int?
    var parallel: Int?

    public var isRunning: Bool { status == .running || status == .starting || status == .provisioning }

    /// Storage per hour while the pod is stopped (only a kept disk is billed).
    public var stoppedPerHour: Double { persistentGB.map { StoragePricing.stoppedPerHour(volumeGB: $0) } ?? 0 }

    /// Reads a pod at RunPod. Nil unless a Mac's Podlight created it (its environment carries the
    /// pod key and the model).
    public init?(_ pod: RunpodPod) {
        guard PodOwner.isMacPod(pod.name), let env = pod.env,
              let key = env["PODLIGHT_API_KEY"], !key.isEmpty,
              let repo = env["PODLIGHT_MODEL"], let served = env["PODLIGHT_SERVED_NAME"] else { return nil }
        id = pod.id
        servedName = served
        repoId = repo
        engine = env["PODLIGHT_ENGINE"] == "llamacpp" ? .llamaCpp : .vllm
        quant = env["PODLIGHT_QUANT"]
        contextTokens = env["PODLIGHT_MAX_LEN"].flatMap(Int.init) ?? 8192
        status = pod.status
        gpuId = pod.gpu?.id
        gpuCount = pod.gpu?.count ?? env["PODLIGHT_TP"].flatMap(Int.init) ?? 1
        cloud = pod.cloud
        pricePerHour = pod.cost
        persistentGB = pod.mounts?.persistent?.size
        containerGB = pod.disk
        dataCenterId = pod.dataCenterId
        owner = PodOwner.owner(ofPodName: pod.name)
        podKey = key
        toolCallParser = env["PODLIGHT_TOOL_PARSER"]
        reasoningParser = env["PODLIGHT_REASONING_PARSER"]
        maxSeqs = env["PODLIGHT_MAX_SEQS"].flatMap(Int.init)
        parallel = env["PODLIGHT_PARALLEL"].flatMap(Int.init)
    }

    /// The model as this Mac will keep it, completed from Hugging Face (weights, native context,
    /// format, KV profile) because the pod's environment does not carry those.
    public func model(from info: ModelInfo) -> PodlightModel {
        let concurrency = engine == .llamaCpp ? (parallel ?? 1) : max(1, (maxSeqs ?? 4) / 2)
        var model = PodlightModel(
            name: servedName, repoId: repoId, format: info.format, weightBytes: info.weightBytes,
            nativeContextTokens: info.nativeContextTokens,
            toolCallParser: toolCallParser ?? info.toolCallParser, reasoningParser: reasoningParser ?? info.reasoningParser,
            contextTokens: contextTokens, concurrency: concurrency,
            preferredGPU: gpuId.map { GPUChoice(gpuId: $0, cloud: cloud ?? .community, count: gpuCount) },
            kvProfile: info.kvProfile, keepDisk: (persistentGB ?? 0) > 0, quant: quant ?? info.quant)
        model.expectedPricePerHour = pricePerHour
        return model
    }
}
