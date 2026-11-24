import Foundation

// The Podlight app's side of server mode: talks to a Podlight server's control API (/admin) with
// the device token from pairing. The server runs the pods; this only reads its state and asks it
// to act. The API is described in spec/openapi.json.

/// A server the app knows. Kept in `state.json`; its device token lives in the keychain.
public struct ServerEntry: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    /// The user's name for it, e.g. "Office".
    public var name: String
    /// Root address without `/v1`, e.g. `https://podlight.example.com`.
    public var baseURL: URL
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, baseURL: URL, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.addedAt = addedAt
    }

    /// The address agents use.
    public var gatewayURL: String { baseURL.absoluteString.trimmingTrailingSlash + "/v1" }
}

extension KeychainStore.Item {
    /// The device token this app holds for one server.
    public static func serverToken(_ server: UUID) -> KeychainStore.Item { .init("server-token-\(server.uuidString)") }
}

extension String {
    var trimmingTrailingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

/// Checks and normalises what the user typed as a server address.
public enum ServerAddress {
    public enum Problem: Error, Equatable, Sendable {
        case invalid
        /// Plain http to an address on the internet: the device token and model traffic would be
        /// readable on the way. Only https, except for this Mac and private networks.
        case insecure
    }

    /// `podlight.example.com` → `https://podlight.example.com`; trailing `/v1` and `/` are dropped.
    public static func normalize(_ input: String) throws(Problem) -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw .invalid }
        if !text.contains("://") { text = "https://" + text }
        text = text.trimmingTrailingSlash
        if text.hasSuffix("/v1") { text = String(text.dropLast(3)).trimmingTrailingSlash }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty,
              scheme == "https" || scheme == "http" else { throw .invalid }
        if scheme == "http" && !isLocalOrPrivate(host) { throw .insecure }
        return url
    }

    /// True for this Mac and private network addresses (RFC 1918, link-local, `.local`, ULA).
    public static func isLocalOrPrivate(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h == "::1" { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, let b) where (16...31).contains(b): return true
            default: return false
            }
        }
        return h.hasPrefix("fd") || h.hasPrefix("fc") || h.hasPrefix("fe80:")
    }

    /// Whether the address sends the token unencrypted (allowed only on private networks).
    public static func isUnencrypted(_ url: URL) -> Bool { url.scheme?.lowercased() == "http" }
}

/// What can go wrong talking to a server, each with its own sentence in the interface.
public enum ServerError: Error, Sendable, Equatable {
    case unreachable(String)
    /// The device token was refused: unpaired, or revoked on the server.
    case notPaired
    /// The server answered with an error of its own.
    case refused(status: Int, message: String, code: String)
    case unexpected(String)
}

public struct ServerHealth: Codable, Sendable, Equatable {
    public var status: String
    public var name: String
    public var version: String
    public var paired: Bool
}

/// The server's settings as the app sees them. Secrets appear only as `has…` flags.
public struct ServerSettings: Codable, Sendable, Equatable {
    public var dailyLimitUsd: Double?
    public var monthlyLimitUsd: Double?
    public var heartbeatMinutes: Int
    public var wakeWaitSeconds: Int
    public var deleteStoppedAfterDays: Int
    public var wakeOnRequest: Bool
    public var hostingRegion: HostingRegion
    public var secureCloudOnly: Bool
    public var timezone: String
    public var hasRunpodKey: Bool
    public var hasHuggingFaceToken: Bool

    public var hosting: HostingPolicy { HostingPolicy(region: hostingRegion, secureOnly: secureCloudOnly) }
}

/// One poll of `/admin/state`: everything the app shows for a server.
public struct ServerSnapshot: Sendable, Equatable {
    public var version: String
    public var serverTime: Date?
    public var models: [PodlightModel]
    public var runs: [UUID: ModelRun]
    public var settings: ServerSettings
    public var spendByDay: [String: Double]
    public var spend: Spend
    public var costPerHour: Double
    public var lastClientRequestAt: Date?
    /// The latest telemetry per model whose pod runs. Empty from a server before 0.5.
    public var telemetry: [UUID: PodTelemetry] = [:]
    /// The RunPod account's credit, as the server last read it. Nil from a server before 0.8.
    public var balance: RunpodBalance?

    public func run(_ id: UUID) -> ModelRun { runs[id] ?? ModelRun() }

    public var activeRuns: [(PodlightModel, ModelRun)] {
        models.compactMap { m in
            let r = run(m.id)
            return [.creating, .loading, .ready, .stopping].contains(r.phase) ? (m, r) : nil
        }
    }
}

extension ServerSnapshot: Decodable {
    private enum Keys: String, CodingKey {
        case version, serverTime, models, runs, settings, spendByDay, spend, costPerHour, lastClientRequestAt, telemetry, balance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decode(String.self, forKey: .version)
        serverTime = try c.decodeIfPresent(Date.self, forKey: .serverTime)
        models = try c.decode([PodlightModel].self, forKey: .models)
        // Keyed by the model id as a string; Swift dictionaries with UUID keys are not JSON objects.
        let byString = try c.decode([String: ModelRun].self, forKey: .runs)
        runs = Dictionary(uniqueKeysWithValues: byString.compactMap { key, run in UUID(uuidString: key).map { ($0, run) } })
        settings = try c.decode(ServerSettings.self, forKey: .settings)
        spendByDay = try c.decode([String: Double].self, forKey: .spendByDay)
        spend = try c.decode(Spend.self, forKey: .spend)
        costPerHour = try c.decode(Double.self, forKey: .costPerHour)
        lastClientRequestAt = try c.decodeIfPresent(Date.self, forKey: .lastClientRequestAt)
        // A sample that does not decode must not cost the whole snapshot.
        let samples = (try? c.decodeIfPresent([String: PodTelemetry].self, forKey: .telemetry)) ?? [:]
        telemetry = Dictionary(uniqueKeysWithValues: samples.compactMap { key, t in UUID(uuidString: key).map { ($0, t) } })
        balance = try? c.decodeIfPresent(RunpodBalance.self, forKey: .balance)
    }
}

/// An access key for agents. The key itself only comes back once, when it is created.
public struct ClientToken: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: Date?
    public var lastUsedAt: Date?
    public var revokedAt: Date?
    /// Model ids this key may use; nil means every model.
    public var models: [UUID]?
    public var token: String?
}

public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: Date?
    public var lastUsedAt: Date?
    public var revokedAt: Date?
    public var current: Bool?
}

public struct PairingCode: Codable, Sendable, Equatable {
    public var code: String
    public var expiresAt: Date
}

/// A change to the server's settings. Only fields that are set are sent; `setLimit` can send an
/// explicit null ("no limit").
public struct ServerSettingsChange: Sendable {
    public var values: [String: JSONValue] = [:]
    public init() {}

    public enum JSONValue: Sendable, Equatable {
        case number(Double), int(Int), bool(Bool), string(String), null
        var any: Any {
            switch self {
            case .number(let v): v
            case .int(let v): v
            case .bool(let v): v
            case .string(let v): v
            case .null: NSNull()
            }
        }
    }

    public mutating func dailyLimit(_ value: Double?) { values["dailyLimitUsd"] = value.map { .number($0) } ?? .null }
    public mutating func monthlyLimit(_ value: Double?) { values["monthlyLimitUsd"] = value.map { .number($0) } ?? .null }
    public mutating func heartbeatMinutes(_ value: Int) { values["heartbeatMinutes"] = .int(value) }
    public mutating func wakeWaitSeconds(_ value: Int) { values["wakeWaitSeconds"] = .int(value) }
    public mutating func deleteStoppedAfterDays(_ value: Int) { values["deleteStoppedAfterDays"] = .int(value) }
    public mutating func wakeOnRequest(_ value: Bool) { values["wakeOnRequest"] = .bool(value) }
    public mutating func hosting(_ policy: HostingPolicy) {
        values["hostingRegion"] = .string(policy.region.rawValue)
        values["secureCloudOnly"] = .bool(policy.secureOnly)
    }
    public mutating func timezone(_ value: String) { values["timezone"] = .string(value) }
    /// Write-only on the server; an empty string removes it.
    public mutating func runpodApiKey(_ value: String) { values["runpodApiKey"] = .string(value) }
    public mutating func huggingFaceToken(_ value: String) { values["huggingFaceToken"] = .string(value) }
}

public struct ServerClient: Sendable {
    public let baseURL: URL
    private let token: String?
    private let transport: HTTPTransport

    public init(baseURL: URL, token: String?, transport: HTTPTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    // MARK: Without a token

    public func health() async throws(ServerError) -> ServerHealth {
        try decode(ServerHealth.self, from: try await call("GET", "/health", timeout: 8))
    }

    /// Exchanges the pairing code from the server's log for a device token.
    public func pair(code: String, deviceName: String) async throws(ServerError) -> (token: String, id: String) {
        struct Answer: Decodable { var token: String; var id: String }
        let answer = try decode(Answer.self, from: try await call("POST", "/pair", body: ["code": code, "deviceName": deviceName]))
        return (answer.token, answer.id)
    }

    // MARK: State and settings

    public func state() async throws(ServerError) -> ServerSnapshot {
        try decode(ServerSnapshot.self, from: try await call("GET", "/admin/state", timeout: 10))
    }

    public func update(_ change: ServerSettingsChange) async throws(ServerError) -> ServerSettings {
        try decode(ServerSettings.self, from: try await call("PATCH", "/admin/settings", body: change.values.mapValues(\.any)))
    }

    public func verifyRunpodKey(_ key: String?) async throws(ServerError) -> RunpodKeyCheck {
        struct Answer: Decodable { var result: String }
        let body: [String: Any] = key.map { ["runpodApiKey": $0] } ?? [:]
        let answer = try decode(Answer.self, from: try await call("POST", "/admin/settings/verify-runpod", body: body, timeout: 30))
        switch answer.result {
        case "valid": return .valid
        case "invalid": return .invalid
        case "missingPermission": return .missingPermission
        default: return .unreachable(String(localized: "The server could not reach RunPod."))
        }
    }

    public func gpuCatalog() async throws(ServerError) -> [RunpodGPUType] {
        try decode(RunpodGPUCatalog.self, from: try await call("GET", "/admin/catalog/gpus", timeout: 30)).gpus
    }

    // MARK: Models and runs

    public func save(_ model: PodlightModel) async throws(ServerError) {
        let data: Data
        do { data = try Self.encoder.encode(model) } catch { throw .unexpected("\(error)") }
        _ = try await call("PUT", "/admin/models/\(model.id.uuidString)", rawBody: data)
    }

    /// Hands a model from this Mac to the server, with its pod and the pod's key when it has one:
    /// the server renames the pod to its own and runs it from now on, disk and all.
    public func adopt(_ model: PodlightModel, podKey: String, podId: String?) async throws(ServerError) {
        struct Body: Encodable { var model: PodlightModel; var podKey: String; var podId: String? }
        let data: Data
        do { data = try Self.encoder.encode(Body(model: model, podKey: podKey, podId: podId)) } catch { throw .unexpected("\(error)") }
        _ = try await call("POST", "/admin/models/\(model.id.uuidString)/adopt", rawBody: data, timeout: 60)
    }

    /// Asks the server to compare its pods with RunPod now (instead of at its next round).
    public func refresh() async throws(ServerError) {
        _ = try await call("POST", "/admin/refresh", timeout: 60)
    }

    public func remove(_ id: UUID) async throws(ServerError) {
        _ = try await call("DELETE", "/admin/models/\(id.uuidString)", timeout: 60)
    }

    /// `newPod`: delete a stopped pod with its disk and build a new one (its machine was busy).
    public func start(_ id: UUID, until: Date?, newPod: Bool = false) async throws(ServerError) {
        var body: [String: Any] = ["until": until.map { Self.iso($0) } ?? NSNull()]
        if newPod { body["newPod"] = true }
        _ = try await call("POST", "/admin/models/\(id.uuidString)/start", body: body, timeout: 120)
    }

    public func stop(_ id: UUID) async throws(ServerError) {
        _ = try await call("POST", "/admin/models/\(id.uuidString)/stop", timeout: 60)
    }

    public func extend(_ id: UUID, until: Date) async throws(ServerError) {
        _ = try await call("POST", "/admin/models/\(id.uuidString)/extend", body: ["until": Self.iso(until)])
    }

    public func engineLog(_ id: UUID) async throws(ServerError) -> [String] {
        struct Answer: Decodable { var lines: [String] }
        return try decode(Answer.self, from: try await call("GET", "/admin/models/\(id.uuidString)/log", timeout: 20)).lines
    }

    /// What one model's pod has been doing in the last 30 minutes, oldest first.
    public func telemetry(_ id: UUID) async throws(ServerError) -> [PodTelemetry] {
        struct Answer: Decodable { var samples: [PodTelemetry] }
        return try decode(Answer.self, from: try await call("GET", "/admin/models/\(id.uuidString)/telemetry")).samples
    }

    // MARK: Access keys and devices

    public func clientTokens() async throws(ServerError) -> [ClientToken] {
        try decode([ClientToken].self, from: try await call("GET", "/admin/client-tokens"))
    }

    public func createClientToken(name: String, models: [UUID]?) async throws(ServerError) -> ClientToken {
        let body: [String: Any] = ["name": name, "models": models.map { $0.map(\.uuidString) } ?? NSNull()]
        return try decode(ClientToken.self, from: try await call("POST", "/admin/client-tokens", body: body))
    }

    public func setModels(ofClientToken id: String, to models: [UUID]?) async throws(ServerError) {
        _ = try await call("PATCH", "/admin/client-tokens/\(id)", body: ["models": models.map { $0.map(\.uuidString) } ?? NSNull()])
    }

    public func revokeClientToken(_ id: String) async throws(ServerError) {
        _ = try await call("POST", "/admin/client-tokens/\(id)/revoke")
    }

    public func deleteClientToken(_ id: String) async throws(ServerError) {
        _ = try await call("DELETE", "/admin/client-tokens/\(id)")
    }

    public func devices() async throws(ServerError) -> [PairedDevice] {
        try decode([PairedDevice].self, from: try await call("GET", "/admin/devices"))
    }

    public func revokeDevice(_ id: String) async throws(ServerError) {
        _ = try await call("POST", "/admin/devices/\(id)/revoke")
    }

    public func newPairingCode() async throws(ServerError) -> PairingCode {
        try decode(PairingCode.self, from: try await call("POST", "/admin/pair/new-code"))
    }

    // MARK: HTTP

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil, rawBody: Data? = nil,
                      timeout: TimeInterval = 15) async throws(ServerError) -> Data {
        var request = URLRequest(url: URL(string: baseURL.absoluteString.trimmingTrailingSlash + path)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let rawBody {
            request.httpBody = rawBody
        } else if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        if request.httpBody != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw .unreachable(error.localizedDescription)
        }
        if (200..<300).contains(response.statusCode) { return data }
        if response.statusCode == 401 && path.hasPrefix("/admin") { throw .notPaired }
        let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        throw .refused(status: response.statusCode,
                       message: error?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                       code: error?["code"] as? String ?? "")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(ServerError) -> T {
        do { return try Self.decoder.decode(T.self, from: data) } catch { throw .unexpected("\(T.self): \(error)") }
    }

    /// The server writes ISO 8601 with or without fractional seconds.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "not ISO 8601: \(text)"))
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
