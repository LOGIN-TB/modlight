import Foundation

/// Venice.ai's API (https://docs.venice.ai): a catalog of ready models, billed per token,
/// OpenAI-compatible. Podlight reads the catalog and the key's account; requests themselves go
/// through the gateway.
public struct VeniceClient: Sendable {
    public static let baseURL = URL(string: "https://api.venice.ai/api/v1")!
    /// Where people create a key.
    public static let keysPage = URL(string: "https://venice.ai/settings/api")!

    private let apiKey: String?
    private let transport: HTTPTransport
    private let base: URL

    public init(apiKey: String?, transport: HTTPTransport = URLSession.shared, baseURL: URL = VeniceClient.baseURL) {
        self.apiKey = apiKey
        self.transport = transport
        self.base = baseURL
    }

    /// Text models Venice serves now. The catalog needs no key.
    public func catalog() async throws -> [APIModelOffer] {
        let (data, _) = try await get("models", query: ["type": "text"], auth: false)
        return try Self.offers(from: data)
    }

    /// Checks the key with the one call every key type may make; on success with its balances.
    public func checkKey() async -> APIKeyCheck {
        do {
            return .valid(try await account())
        } catch let error as VeniceError where error.status == 401 || error.status == 403 {
            return .invalid
        } catch let error as VeniceError {
            return .unreachable("Venice answered \(error.status)")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// Balances, tier, key expiry and rate limits (`GET /api_keys/rate_limits`; Inference keys may ask).
    public func account() async throws -> APIAccount {
        let (data, _) = try await get("api_keys/rate_limits", query: [:], auth: true)
        return try Self.account(from: data)
    }

    /// Venice's public figures per model (uptime, time to first token, output speed), refreshed by
    /// Venice every five minutes. No key needed.
    public static let performanceIndex = URL(string: "https://metrics.venice.ai/v1/index.json")!

    public func performance(from url: URL = VeniceClient.performanceIndex) async throws -> [String: VenicePerformance] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw VeniceError(status: response.statusCode, body: "") }
        return try Self.performance(from: data)
    }

    /// `{models: [{id, uptime_24h_percent, deprecated, performance: {1h|4h|24h: {ttft_ms: {p50, p90}, tokens_per_second}}}]}`.
    public static func performance(from data: Data) throws -> [String: VenicePerformance] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { throw VeniceError(status: 200, body: "no models in the metrics") }
        var out: [String: VenicePerformance] = [:]
        for model in models {
            guard let id = model["id"] as? String else { continue }
            let figures = model["performance"] as? [String: Any] ?? [:]
            func window(_ key: String) -> VenicePerformance.Window? {
                guard let w = figures[key] as? [String: Any] else { return nil }
                let ttft = w["ttft_ms"] as? [String: Any] ?? [:]
                return VenicePerformance.Window(ttftP50Ms: APIUsage.int(ttft["p50"]), ttftP90Ms: APIUsage.int(ttft["p90"]),
                                                tokensPerSecond: APIUsage.double(w["tokens_per_second"]))
            }
            out[id] = VenicePerformance(uptime24hPercent: APIUsage.double(model["uptime_24h_percent"]),
                                        deprecated: model["deprecated"] as? Bool ?? false,
                                        lastHour: window("1h"), lastDay: window("24h"))
        }
        return out
    }

    private func get(_ path: String, query: [String: String], auth: Bool) async throws -> (Data, HTTPURLResponse) {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth {
            guard let apiKey, !apiKey.isEmpty else { throw VeniceError(status: 401, body: "no key") }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw VeniceError(status: response.statusCode, body: String(data: data.prefix(500), encoding: .utf8) ?? "")
        }
        return (data, response)
    }

    // MARK: Parsing (pure; shared with the server through spec/cases/api-provider.json)

    static func offers(from data: Data) throws -> [APIModelOffer] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else {
            throw VeniceError(status: 200, body: "no model list in the answer")
        }
        return entries.compactMap(offer(from:))
    }

    /// One catalog entry as an offer. Nil for models that are offline or not text models.
    public static func offer(from entry: [String: Any]) -> APIModelOffer? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        if let type = entry["type"] as? String, type != "text" { return nil }
        let spec = entry["model_spec"] as? [String: Any] ?? [:]
        if spec["offline"] as? Bool == true { return nil }
        guard let pricing = pricing(spec["pricing"] as? [String: Any]) else { return nil }
        let context = APIUsage.int(entry["context_length"]) ?? APIUsage.int(spec["availableContextTokens"]) ?? 0
        guard context > 0 else { return nil }
        let caps = spec["capabilities"] as? [String: Any] ?? [:]
        var capabilities: [String] = []
        if caps["supportsFunctionCalling"] as? Bool == true { capabilities.append("tools") }
        if caps["supportsVision"] as? Bool == true { capabilities.append("vision") }
        if caps["supportsReasoning"] as? Bool == true { capabilities.append("reasoning") }
        if caps["optimizedForCode"] as? Bool == true { capabilities.append("code") }
        let removes = ((spec["deprecation"] as? [String: Any])?["removesAt"] as? String).flatMap(parseDate)
        let name = (spec["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        return APIModelOffer(
            provider: .venice, providerModelId: id, displayName: name,
            description: (spec["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            contextTokens: context, maxCompletionTokens: APIUsage.int(spec["maxCompletionTokens"]),
            privacy: APIPrivacy(rawValue: spec["privacy"] as? String ?? "") ?? .anonymized,
            capabilities: capabilities, traits: spec["traits"] as? [String] ?? [],
            pricing: pricing, removesAt: removes, suggestedName: PodlightModel.suggestedName(for: id))
    }

    /// `{input: {usd}, output: {usd}, cache_input?, cache_write?, extended?: {context_token_threshold, …}}`.
    static func pricing(_ json: [String: Any]?) -> APIPricing? {
        guard let json, let base = rates(json) else { return nil }
        var pricing = APIPricing(input: base.input, output: base.output, cacheRead: base.cacheRead, cacheWrite: base.cacheWrite)
        if let extended = json["extended"] as? [String: Any], let rates = rates(extended),
           let threshold = APIUsage.int(extended["context_token_threshold"]) {
            pricing.extendedAboveTokens = threshold
            pricing.extended = rates
        }
        return pricing
    }

    private static func rates(_ json: [String: Any]) -> APIRates? {
        func usd(_ key: String) -> Double? { APIUsage.double((json[key] as? [String: Any])?["usd"]) }
        guard let input = usd("input"), let output = usd("output") else { return nil }
        return APIRates(input: input, output: output, cacheRead: usd("cache_input"), cacheWrite: usd("cache_write"))
    }

    /// `GET /api_keys/rate_limits`: `{data: {balances: {USD, DIEM, BUNDLED_CREDITS}, apiTier: {id},
    /// keyExpiration, nextEpochBegins, rateLimits: [{apiModelId, rateLimits: [{amount, type}]}]}}`.
    public static func account(from data: Data) throws -> APIAccount {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["data"] as? [String: Any] else {
            throw VeniceError(status: 200, body: "no account in the answer")
        }
        let raw = body["balances"] as? [String: Any] ?? [:]
        let balances = ["USD", "DIEM", "BUNDLED_CREDITS"].compactMap { currency in
            APIUsage.double(raw[currency]).map { APIAccount.Balance(currency: currency, amount: $0) }
        }
        let limits = (body["rateLimits"] as? [[String: Any]] ?? []).flatMap { entry -> [APIAccount.RateLimit] in
            let model = entry["apiModelId"] as? String ?? ""
            return (entry["rateLimits"] as? [[String: Any]] ?? []).compactMap { limit in
                guard let type = limit["type"] as? String, let amount = APIUsage.double(limit["amount"]) else { return nil }
                return APIAccount.RateLimit(model: model, type: type, amount: amount)
            }
        }
        return APIAccount(balances: balances, tier: (body["apiTier"] as? [String: Any])?["id"] as? String,
                          keyExpiration: (body["keyExpiration"] as? String).flatMap(parseDate),
                          nextEpochBegins: (body["nextEpochBegins"] as? String).flatMap(parseDate),
                          rateLimits: limits)
    }

    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: .iso8601)
    }
}

/// Venice answered, but not with success.
public struct VeniceError: Error, Sendable, Equatable, CustomStringConvertible {
    public var status: Int
    public var body: String
    public var description: String { "Venice answered \(status): \(body.prefix(200))" }
}

/// How a Venice model performs for everyone, from Venice's public metrics.
public struct VenicePerformance: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public var ttftP50Ms: Int?
        public var ttftP90Ms: Int?
        public var tokensPerSecond: Double?
    }
    public var uptime24hPercent: Double?
    public var deprecated: Bool
    public var lastHour: Window?
    public var lastDay: Window?
}
