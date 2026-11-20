import Foundation

/// A model the user has set up: what to run, how, and on which cards. Called "Modell" in the
/// interface; `name` is what an agent puts in the `model` field.
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

    public init(id: UUID = UUID(), name: String, repoId: String, format: WeightFormat, weightBytes: Double,
                nativeContextTokens: Int?, toolCallParser: String?, reasoningParser: String?,
                contextTokens: Int, concurrency: Int = 1, goal: SuggestionGoal = .balanced,
                preferredGPU: GPUChoice? = nil, schedule: Schedule = PodlightModel.defaultSchedule,
                createdAt: Date = Date()) {
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
        ModelInfo(repoId: repoId, access: .open, gated: false, format: format, weightBytes: weightBytes,
                  nativeContextTokens: nativeContextTokens, license: nil,
                  toolCallParser: toolCallParser, reasoningParser: reasoningParser)
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
    /// Running time up to this moment is already in the spend ledger.
    public var accountedUntil: Date?

    public init() {}
}

public struct PodlightSettings: Codable, Sendable, Equatable {
    public var dailyLimitUsd: Double? = 10
    public var monthlyLimitUsd: Double? = 100
    /// Minutes without a heartbeat after which a pod stops itself (Mac asleep, app gone).
    public var heartbeatMinutes: Int = 15
    /// How long the gateway holds a request while a stopped pod starts.
    public var wakeWaitSeconds: Int = 420
    public var gatewayPort: Int = 7635
    /// Stopped pods unused for this long are deleted, disk included.
    public var deleteStoppedAfterDays: Int = 3
    /// Wake a stopped pod when an agent sends a request.
    public var wakeOnRequest: Bool = true

    public init() {}
}

/// Everything Podlight persists, in one file.
public struct PodlightState: Codable, Sendable, Equatable {
    public var models: [PodlightModel] = []
    public var runs: [UUID: ModelRun] = [:]
    public var settings = PodlightSettings()
    /// USD spent per local calendar day, key `yyyy-MM-dd`.
    public var spendByDay: [String: Double] = [:]

    public init() {}

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
