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
    /// Where the model runs: a pod Podlight starts (`runpod`) or an API provider that serves it.
    public var provider: ModelProvider = .runpod
    /// For API models: the provider's id, prices and traits. Nil for pods.
    public var api: APIModelSpec?

    /// Podlight starts and stops a pod for this model. False: an API provider serves it, always ready.
    public var isPod: Bool { !provider.isAPI }

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
             kvProfile, keepDisk, hosting, preferredGPUName, quant, provider, api
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
        // Models from before 0.11 have no provider: they are pods.
        provider = try c.decodeIfPresent(ModelProvider.self, forKey: .provider) ?? .runpod
        api = try c.decodeIfPresent(APIModelSpec.self, forKey: .api)
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
    /// What the chosen card would have cost per hour, when the start fell back to another one.
    public var wantedPricePerHour: Double?
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
    /// Another Mac took this model's pod over (its tag). This Mac then leaves the pod alone until
    /// it is taken back.
    public var managedBy: String?
    /// The model's record in the RunPod account (a private template), so other Macs see it.
    public var recordId: String?
    /// The engine's last log lines when it failed, for "Show Engine Log".
    public var engineLog: [String]?
    /// The pod's machine had no free card at the last start. Podlight keeps trying to resume the
    /// pod with its disk instead of giving it up.
    public var waitingForCard: WaitingForCard?
    /// "Start on a New Card": the old pod and its disk, kept until the new pod answers, and put
    /// back if the new one fails.
    public var replacing: ReplacedPod?
    /// An old pod to delete once its replacement answered (tried again each tick until it is gone).
    public var oldPodToDelete: String?
    /// The current run resumed a kept disk (about a minute) rather than building a new pod.
    public var resumed: Bool?

    public init() {}
}

/// A start waiting for a card: the one on a stopped pod's machine (resume), or, for a new pod,
/// one within the price ceiling when only pricier cards were free.
public struct WaitingForCard: Codable, Sendable, Equatable {
    /// Podlight stops trying then: the run's end, or half an hour for a run a request woke.
    public var until: Date
    public var runUntil: Date?
    public var manual: Bool
    public var lastTryAt: Date?
    /// Set when waiting for a new pod: the most a card may cost per hour (all cards of the pod).
    public var maxPricePerHour: Double?
    /// The chosen card that was taken, and what it costs, for "RTX 4090 at 0.79 $/h is taken".
    public var wanted: PricedChoice?
    /// Cards that might be free but cost more than the ceiling, cheapest first.
    public var pricier: [PricedChoice]?

    public init(until: Date, runUntil: Date?, manual: Bool, lastTryAt: Date? = nil,
                maxPricePerHour: Double? = nil, wanted: PricedChoice? = nil, pricier: [PricedChoice]? = nil) {
        self.until = until; self.runUntil = runUntil; self.manual = manual; self.lastTryAt = lastTryAt
        self.maxPricePerHour = maxPricePerHour; self.wanted = wanted; self.pricier = pricier
    }
}

/// A card choice with its name and price per hour for the whole pod.
public struct PricedChoice: Codable, Sendable, Equatable, Hashable {
    public var choice: GPUChoice
    public var name: String
    public var pricePerHour: Double

    public init(choice: GPUChoice, name: String, pricePerHour: Double) {
        self.choice = choice; self.name = name; self.pricePerHour = pricePerHour
    }
}

/// The parts of a run that belong to its pod, so a replaced pod can be put back.
public struct ReplacedPod: Codable, Sendable, Equatable {
    public var podId: String
    public var gpu: GPUChoice?
    public var gpuName: String?
    public var pricePerHour: Double?
    public var persistentGB: Int?
    public var containerGB: Int?
    public var storagePerHour: Double?
    public var dataCenterId: String?
    public var hosting: HostingPolicy?

    public init(of run: ModelRun, podId: String) {
        self.podId = podId; gpu = run.gpu; gpuName = run.gpuName; pricePerHour = run.pricePerHour
        persistentGB = run.persistentGB; containerGB = run.containerGB; storagePerHour = run.storagePerHour
        dataCenterId = run.dataCenterId; hosting = run.hosting
    }

    /// Puts this pod back as the run's pod, stopped.
    public func restore(into run: inout ModelRun) {
        run.podId = podId; run.gpu = gpu; run.gpuName = gpuName; run.pricePerHour = pricePerHour
        run.persistentGB = persistentGB; run.containerGB = containerGB; run.storagePerHour = storagePerHour
        run.dataCenterId = dataCenterId; run.hosting = hosting
        run.podStatus = .exited; run.engineReady = false; run.replacing = nil
    }
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
    /// A replacement card may cost this many percent more than the chosen one before Podlight asks
    /// (or, without anyone to ask, waits for a cheaper one). 0: ask at any extra cost.
    public var fallbackPriceStepPercent: Int = 50

    public init() {}

    public var hosting: HostingPolicy { HostingPolicy(region: hostingRegion, secureOnly: secureCloudOnly) }

    private enum CodingKeys: String, CodingKey {
        case dailyLimitUsd, monthlyLimitUsd, heartbeatMinutes, wakeWaitSeconds, gatewayPort, deleteStoppedAfterDays,
             wakeOnRequest, hostingRegion, secureCloudOnly, allowLAN, fallbackPriceStepPercent
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
        fallbackPriceStepPercent = try c.decodeIfPresent(Int.self, forKey: .fallbackPriceStepPercent) ?? d.fallbackPriceStepPercent
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
        try c.encode(fallbackPriceStepPercent, forKey: .fallbackPriceStepPercent)
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
    /// This Mac's tag in pod names (`podlight-<model>@<tag>`), made once.
    public var deviceTag: String?
    /// Tokens and cost of API models, per local day (`yyyy-MM-dd`) and model id (UUID string).
    /// Their cost is in `spendByDay` too, so the limits cover pods and API models together.
    public var apiUsage: [String: [String: APIUsageTotals]] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case models, runs, settings, spendByDay, lastClientRequestAt, servers, deviceTag, apiUsage
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
        deviceTag = try c.decodeIfPresent(String.self, forKey: .deviceTag)
        apiUsage = try c.decodeIfPresent([String: [String: APIUsageTotals]].self, forKey: .apiUsage) ?? [:]
    }

    /// Books one API request: its tokens for the model, its cost into the day's spend.
    public mutating func recordAPIUsage(_ usage: APIUsage, cost: APICost, model: UUID, at date: Date,
                                        calendar: Calendar = .current) {
        let day = Self.dayKey(date, calendar: calendar)
        apiUsage[day, default: [:]][model.uuidString, default: APIUsageTotals()].add(usage, cost: cost)
        spendByDay[day, default: 0] += cost.usd
    }

    /// One API model's totals for a day, or for a month when `period` is `yyyy-MM`.
    public func apiTotals(_ model: UUID, period: String) -> APIUsageTotals {
        apiUsage.filter { $0.key.hasPrefix(period) }.compactMap { $0.value[model.uuidString] }.reduce(APIUsageTotals(), +)
    }

    /// Every API model's cost for a day or month (`yyyy-MM-dd` or `yyyy-MM`).
    public func apiSpend(period: String) -> Double {
        apiUsage.filter { $0.key.hasPrefix(period) }.flatMap(\.value.values).map(\.usd).reduce(0, +)
    }

    public func run(_ id: UUID) -> ModelRun { runs[id] ?? ModelRun() }

    public func model(named name: String) -> PodlightModel? { models.first { $0.name == name } }

    /// Models Podlight runs on pods; API models have no pod to start, stop or watch.
    public var podModels: [PodlightModel] { models.filter(\.isPod) }

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
    /// What everything running costs per hour: the GPU and the pod's storage.
    public var costPerHour: Double {
        runs.values.filter { $0.managedBy == nil && ($0.podStatus == .running || $0.phase == .loading || $0.phase == .ready) }
            .map { ($0.pricePerHour ?? 0) + ($0.pricePerHour == nil ? 0 : $0.storagePerHour ?? 0) }.reduce(0, +)
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
