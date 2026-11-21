import Foundation

/// A model the user has set up: what to run, how, and on which cards. Called "Modell" in the
/// interface; `name` is what an agent puts in the `model` field.
/// The program that serves a model inside the pod.
public enum InferenceEngine: String, Codable, Sendable {
    /// vLLM: safetensors, AWQ, GPTQ, FP8, NVFP4. Tensor parallel across cards.
    case vllm
    /// llama.cpp's llama-server: GGUF. Layers split across cards.
    case llamaCpp
}

public struct PodlightModel: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Served name, e.g. `qwen3-coder-30b`. Unique; lowercase letters, digits, `-`, `.`, `_`.
    public var name: String
    public var repoId: String
    public var format: WeightFormat
    public var weightBytes: Double
    public var nativeContextTokens: Int?
    public var toolCallParser: String?
    public var reasoningParser: String?
    public var contextTokens: Int
    public var concurrency: Int
    public var goal: SuggestionGoal
    /// The card the user picked. Tried first; the suggestion list follows as fallbacks.
    public var preferredGPU: GPUChoice?
    /// That card's hourly price when the model was set up, for estimates before the first start.
    public var expectedPricePerHour: Double?
    /// Optional recurring window plus idle stop and runtime ceiling. Idle stop is never 0.
    public var schedule: Schedule
    public var createdAt: Date
    /// KV cache per token from the model's config; nil uses the generic estimate.
    public var kvProfile: KVProfile?
    /// Keep a volume disk between runs ("Modell zwischenspeichern"): restarts in about a minute,
    /// but the disk is billed while the pod is stopped. Off: the pod is deleted at its end and
    /// nothing is billed in between.
    public var keepDisk: Bool
    /// Where this model's pods may run. Nil: the default from the settings (models from 0.2).
    public var hosting: HostingPolicy?
    /// The catalog name of `preferredGPU` when it was chosen, e.g. "B300", for display.
    public var preferredGPUName: String?
    /// For GGUF repositories: which quantisation to run, e.g. `Q4_K_M` (llama.cpp's `-hf repo:quant`).
    public var quant: String?

    /// Which engine serves this model: GGUF runs on llama.cpp, everything else on vLLM.
    public var engine: InferenceEngine { format == .gguf ? .llamaCpp : .vllm }

    public init(id: UUID = UUID(), name: String, repoId: String, format: WeightFormat, weightBytes: Double,
                nativeContextTokens: Int?, toolCallParser: String?, reasoningParser: String?,
                contextTokens: Int, concurrency: Int = 1, goal: SuggestionGoal = .balanced,
                preferredGPU: GPUChoice? = nil, schedule: Schedule = PodlightModel.defaultSchedule,
                createdAt: Date = Date(), kvProfile: KVProfile? = nil, keepDisk: Bool = false,
                hosting: HostingPolicy? = nil, preferredGPUName: String? = nil, quant: String? = nil) {
        self.hosting = hosting
        self.preferredGPUName = preferredGPUName
        self.quant = quant
        self.kvProfile = kvProfile
        self.keepDisk = keepDisk
        self.id = id
        self.name = name
        self.repoId = repoId
        self.format = format
        self.weightBytes = weightBytes
        self.nativeContextTokens = nativeContextTokens
        self.toolCallParser = toolCallParser
        self.reasoningParser = reasoningParser
        self.contextTokens = contextTokens
        self.concurrency = concurrency
        self.goal = goal
        self.preferredGPU = preferredGPU
        self.schedule = schedule
        self.createdAt = createdAt
    }

    public static let defaultSchedule = Schedule(
        enabled: false, timezone: TimeZone.current.identifier, weekdays: [1, 2, 3, 4, 5],
        startAt: "08:00", stopAt: "18:00", idleStopMinutes: 30, maxRuntimeHours: 12)

    public var info: ModelInfo {
        var info = ModelInfo(repoId: repoId, access: .open, gated: false, format: format, weightBytes: weightBytes,
                             nativeContextTokens: nativeContextTokens, license: nil,
                             toolCallParser: toolCallParser, reasoningParser: reasoningParser, kvProfile: kvProfile)
        info.quant = quant
        return info
    }

    /// The hosting rules for this model's next start.
    public func hosting(default fallback: HostingPolicy) -> HostingPolicy { hosting ?? fallback }

    private enum CodingKeys: String, CodingKey {
        case id, name, repoId, format, weightBytes, nativeContextTokens, toolCallParser, reasoningParser,
             contextTokens, concurrency, goal, preferredGPU, expectedPricePerHour, schedule, createdAt,
             kvProfile, keepDisk, hosting, preferredGPUName, quant
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        repoId = try c.decode(String.self, forKey: .repoId)
        format = try c.decode(WeightFormat.self, forKey: .format)
        weightBytes = try c.decode(Double.self, forKey: .weightBytes)
        nativeContextTokens = try c.decodeIfPresent(Int.self, forKey: .nativeContextTokens)
        toolCallParser = try c.decodeIfPresent(String.self, forKey: .toolCallParser)
        reasoningParser = try c.decodeIfPresent(String.self, forKey: .reasoningParser)
        contextTokens = try c.decode(Int.self, forKey: .contextTokens)
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? 1
        goal = try c.decodeIfPresent(SuggestionGoal.self, forKey: .goal) ?? .balanced
        preferredGPU = try c.decodeIfPresent(GPUChoice.self, forKey: .preferredGPU)
        expectedPricePerHour = try c.decodeIfPresent(Double.self, forKey: .expectedPricePerHour)
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? Self.defaultSchedule
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        kvProfile = try c.decodeIfPresent(KVProfile.self, forKey: .kvProfile)
        // Models from 0.1 always had a disk; keep their behaviour until the user changes it.
        keepDisk = try c.decodeIfPresent(Bool.self, forKey: .keepDisk) ?? true
        hosting = try c.decodeIfPresent(HostingPolicy.self, forKey: .hosting)
        preferredGPUName = try c.decodeIfPresent(String.self, forKey: .preferredGPUName)
        quant = try c.decodeIfPresent(String.self, forKey: .quant)
    }

    /// A served name derived from a repo id: `Qwen/Qwen3-8B-AWQ` → `qwen3-8b-awq`.
    public static func suggestedName(for repoId: String) -> String {
        let last = repoId.split(separator: "/").last.map(String.init) ?? repoId
        let lowered = last.lowercased().replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
        return lowered.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9._-]{0,62}$"#, options: .regularExpression) != nil
    }
}

/// What is happening with one model's pod, as the interface shows it.
public enum RunPhase: String, Codable, Sendable {
    /// No pod running (none, or stopped with its disk kept).
    case stopped
    /// Podlight is asking RunPod for a card.
    case creating
    /// The pod is up and the engine is downloading or loading the model.
    case loading
    /// Answers requests.
    case ready
    case stopping
    case failed
}

/// Everything Podlight knows about one model's pod. Derived from RunPod on every tick; RunPod is
/// the source of truth, this record only remembers what RunPod does not (why it stopped, until
/// when it may run).
public struct ModelRun: Codable, Sendable, Equatable {
    public var podId: String?
    public var gpu: GPUChoice?
    public var gpuName: String?
    public var pricePerHour: Double?
    public var podStatus: PodState.Status?
    public var phase: RunPhase = .stopped
    public var startedAt: Date?
    public var lastRequestAt: Date?
    public var idleStoppedAt: Date?
    public var stoppedAt: Date?
    public var engineReady = false
    public var startedManually = false
    /// "Läuft bis". Nil for a pod a request woke; idle stop and the runtime ceiling end those.
    public var runUntil: Date?
    /// Why it last stopped or failed, as a reason code for the interface.
    public var lastReason: String?
    public var lastMessage: String?
    /// Fallback attempts of the last start, for "RTX 3090 was taken, started on V100".
    public var fellBackFrom: [String]?
    public var lastHeartbeatAt: Date?
    public var persistentGB: Int?
    /// Size of the container disk of the current pod, for the storage share of the cost.
    public var containerGB: Int?
    /// Storage cost per hour while running (container disk plus kept volume disk).
    public var storagePerHour: Double?
    /// Where RunPod placed the pod.
    public var dataCenterId: String?
    /// Running time up to this moment is already in the spend ledger.
    public var accountedUntil: Date?
    /// Storage of a stopped pod is booked up to here.
    public var storageAccountedUntil: Date?
    /// The hosting rules the pod was created under; its placement is checked against these.
    public var hosting: HostingPolicy?

    public init() {}
}

public struct PodlightSettings: Codable, Sendable, Equatable {
    public var dailyLimitUsd: Double? = 10
    public var monthlyLimitUsd: Double? = 100
    /// Minutes without a heartbeat after which a pod stops itself (Mac asleep, app gone).
    public var heartbeatMinutes: Int = 15
    /// How long the gateway holds a request while a stopped pod starts.
    public var wakeWaitSeconds: Int = 600
    public var gatewayPort: Int = 7635
    /// Stopped pods unused for this long are deleted, disk included.
    public var deleteStoppedAfterDays: Int = 3
    /// Wake a stopped pod when an agent sends a request.
    public var wakeOnRequest: Bool = true
    /// Where pods may run.
    public var hostingRegion: HostingRegion = .anywhere
    /// Only RunPod's Secure Cloud (certified data centers).
    public var secureCloudOnly: Bool = false
    /// Accept connections from other computers on the local network, not only from this Mac.
    public var allowLAN: Bool = false

    public init() {}

    public var hosting: HostingPolicy { HostingPolicy(region: hostingRegion, secureOnly: secureCloudOnly) }

    private enum CodingKeys: String, CodingKey {
        case dailyLimitUsd, monthlyLimitUsd, heartbeatMinutes, wakeWaitSeconds, gatewayPort, deleteStoppedAfterDays,
             wakeOnRequest, hostingRegion, secureCloudOnly, allowLAN
    }

    // Every field optional on read, so a settings file from an older version keeps its values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PodlightSettings()
        dailyLimitUsd = c.contains(.dailyLimitUsd) ? try c.decodeIfPresent(Double.self, forKey: .dailyLimitUsd) : d.dailyLimitUsd
        monthlyLimitUsd = c.contains(.monthlyLimitUsd) ? try c.decodeIfPresent(Double.self, forKey: .monthlyLimitUsd) : d.monthlyLimitUsd
        heartbeatMinutes = try c.decodeIfPresent(Int.self, forKey: .heartbeatMinutes) ?? d.heartbeatMinutes
        wakeWaitSeconds = try c.decodeIfPresent(Int.self, forKey: .wakeWaitSeconds) ?? d.wakeWaitSeconds
        gatewayPort = try c.decodeIfPresent(Int.self, forKey: .gatewayPort) ?? d.gatewayPort
        deleteStoppedAfterDays = try c.decodeIfPresent(Int.self, forKey: .deleteStoppedAfterDays) ?? d.deleteStoppedAfterDays
        wakeOnRequest = try c.decodeIfPresent(Bool.self, forKey: .wakeOnRequest) ?? d.wakeOnRequest
        hostingRegion = try c.decodeIfPresent(HostingRegion.self, forKey: .hostingRegion) ?? d.hostingRegion
        secureCloudOnly = try c.decodeIfPresent(Bool.self, forKey: .secureCloudOnly) ?? d.secureCloudOnly
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? d.allowLAN
    }

    // "No limit" is written as an explicit null: a missing key reads as the default limit.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dailyLimitUsd, forKey: .dailyLimitUsd)
        try c.encode(monthlyLimitUsd, forKey: .monthlyLimitUsd)
        try c.encode(heartbeatMinutes, forKey: .heartbeatMinutes)
        try c.encode(wakeWaitSeconds, forKey: .wakeWaitSeconds)
        try c.encode(gatewayPort, forKey: .gatewayPort)
        try c.encode(deleteStoppedAfterDays, forKey: .deleteStoppedAfterDays)
        try c.encode(wakeOnRequest, forKey: .wakeOnRequest)
        try c.encode(hostingRegion, forKey: .hostingRegion)
        try c.encode(secureCloudOnly, forKey: .secureCloudOnly)
        try c.encode(allowLAN, forKey: .allowLAN)
    }
}

/// Everything Podlight persists, in one file.
public struct PodlightState: Codable, Sendable, Equatable {
    public var models: [PodlightModel] = []
    public var runs: [UUID: ModelRun] = [:]
    public var settings = PodlightSettings()
    /// USD spent per local calendar day, key `yyyy-MM-dd`.
    public var spendByDay: [String: Double] = [:]
    /// When an agent last reached the gateway with a valid key, for "agent connected" on the overview.
    public var lastClientRequestAt: Date?
    /// Podlight servers this app controls (server mode). Their device tokens are in the keychain.
    public var servers: [ServerEntry] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case models, runs, settings, spendByDay, lastClientRequestAt, servers
    }

    // Every field optional on read, so a state file from an older version still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decodeIfPresent([PodlightModel].self, forKey: .models) ?? []
        runs = try c.decodeIfPresent([UUID: ModelRun].self, forKey: .runs) ?? [:]
        settings = try c.decodeIfPresent(PodlightSettings.self, forKey: .settings) ?? PodlightSettings()
        spendByDay = try c.decodeIfPresent([String: Double].self, forKey: .spendByDay) ?? [:]
        lastClientRequestAt = try c.decodeIfPresent(Date.self, forKey: .lastClientRequestAt)
        servers = try c.decodeIfPresent([ServerEntry].self, forKey: .servers) ?? []
    }

    public func run(_ id: UUID) -> ModelRun { runs[id] ?? ModelRun() }

    public func model(named name: String) -> PodlightModel? { models.first { $0.name == name } }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func spend(on date: Date, calendar: Calendar = .current) -> Spend {
        let today = Self.dayKey(date, calendar: calendar)
        let month = String(today.prefix(7))
        return Spend(
            todayUsd: spendByDay[today] ?? 0,
            monthUsd: spendByDay.filter { $0.key.hasPrefix(month) }.values.reduce(0, +),
            dailyLimitUsd: settings.dailyLimitUsd,
            monthlyLimitUsd: settings.monthlyLimitUsd)
    }

    /// Current hourly cost of everything running.
    public var costPerHour: Double {
        runs.values.filter { $0.podStatus == .running || $0.phase == .loading || $0.phase == .ready }
            .compactMap(\.pricePerHour).reduce(0, +)
    }

    public var activeRuns: [(PodlightModel, ModelRun)] {
        models.compactMap { m in
            let r = run(m.id)
            return [.creating, .loading, .ready, .stopping].contains(r.phase) ? (m, r) : nil
        }
    }
}

/// Saves `PodlightState` as JSON in Application Support. No secrets go in here.
public actor StateStore {
    private let url: URL
    private(set) var state: PodlightState

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? Self.decoder.decode(PodlightState.self, from: data) {
            state = decoded
        } else {
            state = PodlightState()
        }
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Podlight", isDirectory: true).appendingPathComponent("state.json")
    }

    public func current() -> PodlightState { state }

    public func update<T: Sendable>(_ change: @Sendable (inout PodlightState) throws -> T) throws -> T {
        let result = try change(&state)
        try save()
        return result
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
