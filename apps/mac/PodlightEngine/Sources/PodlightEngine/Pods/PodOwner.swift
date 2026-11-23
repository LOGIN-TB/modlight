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

/// A model's record in the RunPod account, so another Mac with the same key sees the model even
/// while it has no pod (a model without a kept disk has none between runs). Stored as a private
/// pod template, which RunPod keeps for free: its name says which Mac manages the model, its
/// environment holds the model, the pod key and the current pod. Never shown as a template.
public enum ModelRecord {
    public static let prefix = "podlight-model-"
    static let maxNameLength = 80

    public static func name(model: String, owner: String) -> String {
        let room = maxNameLength - prefix.count - owner.count - 1
        return prefix + String(model.prefix(max(1, room))) + String(PodOwner.separator) + owner
    }

    public static func owner(ofName name: String) -> String? {
        guard name.hasPrefix(prefix), let at = name.lastIndex(of: PodOwner.separator) else { return nil }
        let tag = String(name[name.index(after: at)...])
        return tag.isEmpty ? nil : tag
    }

    public static func env(model: PodlightModel, podKey: String, podId: String?) -> [String: String] {
        let json = (try? StateStore.encoder.encode(model)) ?? Data()
        var env = ["PODLIGHT_RECORD": "1", "PODLIGHT_MODEL_B64": json.base64EncodedString(), "PODLIGHT_API_KEY": podKey]
        if let podId { env["PODLIGHT_POD_ID"] = podId }
        return env
    }

    public static func decode(_ env: [String: String]) -> (model: PodlightModel, podKey: String, podId: String?)? {
        guard env["PODLIGHT_RECORD"] == "1", let b64 = env["PODLIGHT_MODEL_B64"], let data = Data(base64Encoded: b64),
              let model = try? StateStore.decoder.decode(PodlightModel.self, from: data),
              let key = env["PODLIGHT_API_KEY"], !key.isEmpty else { return nil }
        let pod = env["PODLIGHT_POD_ID"].flatMap { $0.isEmpty ? nil : $0 }
        return (model, key, pod)
    }
}

/// A model in the RunPod account that another Mac manages, with what is needed to take it over:
/// from its record (any model of a Mac on 0.7 or later, with or without a pod), or from a pod
/// alone (a pod from an older version).
public struct ForeignPod: Sendable, Equatable, Identifiable {
    /// The record's id, or the pod's id for a pod without a record.
    public var id: String
    public var podId: String?
    public var recordId: String?
    /// The model's name for agents.
    public var servedName: String
    public var repoId: String
    public var engine: InferenceEngine
    public var quant: String?
    public var contextTokens: Int
    /// The pod's state; nil when the model has no pod right now (stopped, nothing kept).
    public var status: PodState.Status?
    public var gpuId: String?
    public var gpuCount: Int
    public var cloud: RunpodCloud?
    /// GPU price per hour while running (from the pod, or the price when it was set up).
    public var pricePerHour: Double?
    public var persistentGB: Int?
    public var containerGB: Int?
    public var dataCenterId: String?
    /// The managing Mac's tag; nil for a pod from before 0.6.
    public var owner: String?

    var podKey: String
    /// The exact model, when it comes from a record.
    var recordedModel: PodlightModel?
    var toolCallParser: String?
    var reasoningParser: String?
    var maxSeqs: Int?
    var parallel: Int?

    public var isRunning: Bool { status == .running || status == .starting || status == .provisioning }
    public var hasPod: Bool { status != nil }

    /// Storage per hour while the pod is stopped (only a kept disk is billed).
    public var stoppedPerHour: Double { persistentGB.map { StoragePricing.stoppedPerHour(volumeGB: $0) } ?? 0 }

    /// Reads a pod at RunPod. Nil unless a Mac's Podlight created it (its environment carries the
    /// pod key and the model).
    public init?(_ pod: RunpodPod) {
        guard PodOwner.isMacPod(pod.name), let env = pod.env,
              let key = env["PODLIGHT_API_KEY"], !key.isEmpty,
              let repo = env["PODLIGHT_MODEL"], let served = env["PODLIGHT_SERVED_NAME"] else { return nil }
        id = pod.id
        podId = pod.id
        servedName = served
        repoId = repo
        engine = env["PODLIGHT_ENGINE"] == "llamacpp" ? .llamaCpp : .vllm
        quant = env["PODLIGHT_QUANT"]
        contextTokens = env["PODLIGHT_MAX_LEN"].flatMap(Int.init) ?? 8192
        gpuCount = pod.gpu?.count ?? env["PODLIGHT_TP"].flatMap(Int.init) ?? 1
        owner = PodOwner.owner(ofPodName: pod.name)
        podKey = key
        toolCallParser = env["PODLIGHT_TOOL_PARSER"]
        reasoningParser = env["PODLIGHT_REASONING_PARSER"]
        maxSeqs = env["PODLIGHT_MAX_SEQS"].flatMap(Int.init)
        parallel = env["PODLIGHT_PARALLEL"].flatMap(Int.init)
        apply(pod)
    }

    /// Reads a model record, with its pod if it has one.
    public init?(record: RunpodTemplate, pod: RunpodPod?) {
        guard let env = record.env, let content = ModelRecord.decode(env) else { return nil }
        let model = content.model
        id = record.id
        recordId = record.id
        podId = content.podId
        servedName = model.name
        repoId = model.repoId
        engine = model.engine
        quant = model.quant
        contextTokens = model.contextTokens
        gpuId = model.preferredGPU?.gpuId
        gpuCount = model.preferredGPU?.count ?? 1
        cloud = model.preferredGPU?.cloud
        pricePerHour = model.expectedPricePerHour
        owner = ModelRecord.owner(ofName: record.name)
        podKey = content.podKey
        recordedModel = model
        if let pod, pod.status != .terminated { apply(pod) } else { podId = nil }
    }

    private mutating func apply(_ pod: RunpodPod) {
        status = pod.status
        gpuId = pod.gpu?.id ?? gpuId
        if let count = pod.gpu?.count { gpuCount = count }
        cloud = pod.cloud ?? cloud
        pricePerHour = pod.cost ?? pricePerHour
        persistentGB = pod.mounts?.persistent?.size
        containerGB = pod.disk
        dataCenterId = pod.dataCenterId
    }

    /// The model as this Mac will keep it: exact from a record; from a bare pod completed from
    /// Hugging Face (weights, native context, format, KV profile), which its environment lacks.
    public func model(from info: ModelInfo) -> PodlightModel {
        if let recordedModel { return recordedModel }
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
