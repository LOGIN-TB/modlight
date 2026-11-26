import Foundation

/// Where a model runs. `runpod`: Podlight starts a pod for it (Hugging Face weights on a rented
/// card, billed per hour). Every other case is an API provider that already serves the model and
/// bills per token; Podlight only routes requests to it and counts what they cost.
public enum ModelProvider: String, Codable, Sendable, CaseIterable {
    case runpod
    case venice

    public var isAPI: Bool { self != .runpod }

    /// The provider's name as people know it.
    public var displayName: String {
        switch self {
        case .runpod: "RunPod"
        case .venice: "Venice"
        }
    }

    /// Where requests for its models go. Nil for pods: each has its own address.
    public var apiBaseURL: URL? {
        switch self {
        case .runpod: nil
        case .venice: VeniceClient.baseURL
        }
    }
}

/// How a provider treats prompts. Venice: `private` runs on hardware that keeps nothing,
/// `anonymized` passes the prompt to a third party (Claude, GPT, Gemini …) without who sent it.
public enum APIPrivacy: String, Codable, Sendable, CaseIterable {
    case `private`
    case anonymized
}

/// USD per million tokens.
public struct APIRates: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    /// Prompt tokens read from the provider's cache. Nil: billed as `input`.
    public var cacheRead: Double?
    /// Prompt tokens written to the provider's cache. Nil: billed as `input`.
    public var cacheWrite: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// A model's token prices. Some models cost more once a prompt is longer than a threshold.
public struct APIPricing: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?
    /// Prompts with more tokens than this are billed at `extended`.
    public var extendedAboveTokens: Int?
    public var extended: APIRates?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil,
                extendedAboveTokens: Int? = nil, extended: APIRates? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.extendedAboveTokens = extendedAboveTokens
        self.extended = extended
    }

    public var base: APIRates { APIRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite) }

    /// The rates a prompt of this many tokens is billed at.
    public func rates(promptTokens: Int) -> APIRates {
        if let above = extendedAboveTokens, let extended, promptTokens > above { return extended }
        return base
    }
}

/// What Podlight keeps about a model an API provider serves.
public struct APIModelSpec: Codable, Sendable, Equatable {
    /// The provider's id, sent upstream in `model`, e.g. `kimi-k3`.
    public var providerModelId: String
    /// The provider's name for it, e.g. "Kimi K3".
    public var displayName: String
    public var privacy: APIPrivacy
    /// `tools`, `vision`, `reasoning`, `code`.
    public var capabilities: [String]
    public var maxCompletionTokens: Int?
    public var pricing: APIPricing
    /// When `pricing` was read from the provider's catalog.
    public var pricedAt: Date
    /// The provider retires the model on this date.
    public var removesAt: Date?

    public init(providerModelId: String, displayName: String, privacy: APIPrivacy, capabilities: [String],
                maxCompletionTokens: Int?, pricing: APIPricing, pricedAt: Date, removesAt: Date? = nil) {
        self.providerModelId = providerModelId
        self.displayName = displayName
        self.privacy = privacy
        self.capabilities = capabilities
        self.maxCompletionTokens = maxCompletionTokens
        self.pricing = pricing
        self.pricedAt = pricedAt
        self.removesAt = removesAt
    }
}

/// One entry of a provider's catalog, as the "add model" sheet lists it.
public struct APIModelOffer: Codable, Sendable, Equatable, Identifiable {
    public var provider: ModelProvider
    public var providerModelId: String
    public var displayName: String
    public var description: String?
    public var contextTokens: Int
    public var maxCompletionTokens: Int?
    public var privacy: APIPrivacy
    public var capabilities: [String]
    public var traits: [String]
    public var pricing: APIPricing
    public var removesAt: Date?
    /// A served name for Podlight, derived from the provider's id.
    public var suggestedName: String

    public var id: String { "\(provider.rawValue):\(providerModelId)" }

    /// The model Podlight stores when the user adds this offer under `name`.
    public func model(named name: String, at date: Date = Date()) -> PodlightModel {
        var model = PodlightModel(name: name, repoId: providerModelId, format: .unknown, weightBytes: 0,
                                  nativeContextTokens: contextTokens, toolCallParser: nil, reasoningParser: nil,
                                  contextTokens: contextTokens, createdAt: date)
        model.provider = provider
        model.api = APIModelSpec(providerModelId: providerModelId, displayName: displayName, privacy: privacy,
                                 capabilities: capabilities, maxCompletionTokens: maxCompletionTokens,
                                 pricing: pricing, pricedAt: date, removesAt: removesAt)
        return model
    }
}

/// A provider account as Podlight shows it: what is left, and what the key may do.
public struct APIAccount: Codable, Sendable, Equatable {
    public struct Balance: Codable, Sendable, Equatable {
        /// `USD`, `DIEM`, `BUNDLED_CREDITS`.
        public var currency: String
        public var amount: Double
        public init(currency: String, amount: Double) {
            self.currency = currency
            self.amount = amount
        }
    }

    public struct RateLimit: Codable, Sendable, Equatable {
        public var model: String
        /// `RPM`, `RPD`, `TPM`.
        public var type: String
        public var amount: Double
        public init(model: String, type: String, amount: Double) {
            self.model = model
            self.type = type
            self.amount = amount
        }
    }

    public var balances: [Balance]
    /// The provider's tier for the key, e.g. `paid`.
    public var tier: String?
    public var keyExpiration: Date?
    public var nextEpochBegins: Date?
    public var rateLimits: [RateLimit]

    public init(balances: [Balance], tier: String? = nil, keyExpiration: Date? = nil,
                nextEpochBegins: Date? = nil, rateLimits: [RateLimit] = []) {
        self.balances = balances
        self.tier = tier
        self.keyExpiration = keyExpiration
        self.nextEpochBegins = nextEpochBegins
        self.rateLimits = rateLimits
    }

    public func amount(_ currency: String) -> Double? { balances.first { $0.currency == currency }?.amount }

    public var usd: Double? { amount("USD") }
}

/// Result of checking a provider key.
public enum APIKeyCheck: Sendable, Equatable {
    case valid(APIAccount)
    case invalid
    case unreachable(String)
}

/// Tokens one request used, read from the provider's answer.
public struct APIUsage: Codable, Sendable, Equatable {
    /// All prompt tokens, cached ones included (OpenAI's `prompt_tokens`).
    public var promptTokens: Int
    public var completionTokens: Int
    /// Prompt tokens read from the cache.
    public var cachedTokens: Int
    /// Prompt tokens written to the cache.
    public var cacheWriteTokens: Int
    /// The provider's own price for the request, when the answer carries one.
    public var providerCostUsd: Double?

    public init(promptTokens: Int, completionTokens: Int, cachedTokens: Int = 0, cacheWriteTokens: Int = 0,
                providerCostUsd: Double? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.providerCostUsd = providerCostUsd
    }

    /// Reads `usage` (Chat Completions or Responses shape) and an optional `cost.usd` from an
    /// answer, a final stream chunk or a Responses `response.completed` event. Nil without usage.
    public static func from(_ json: [String: Any]) -> APIUsage? {
        let holder = (json["response"] as? [String: Any]).flatMap { $0["usage"] != nil ? $0 : nil } ?? json
        guard let usage = holder["usage"] as? [String: Any] else { return nil }
        let prompt = int(usage["prompt_tokens"]) ?? int(usage["input_tokens"])
        let completion = int(usage["completion_tokens"]) ?? int(usage["output_tokens"])
        guard prompt != nil || completion != nil else { return nil }
        let details = (usage["prompt_tokens_details"] ?? usage["input_tokens_details"]) as? [String: Any] ?? [:]
        let cached = int(details["cached_tokens"]) ?? int(usage["cache_read_input_tokens"]) ?? 0
        let written = int(details["cache_creation_tokens"]) ?? int(details["cache_write_tokens"])
            ?? int(usage["cache_creation_input_tokens"]) ?? 0
        let cost = ((holder["cost"] ?? json["cost"]) as? [String: Any])?["usd"]
        return APIUsage(promptTokens: prompt ?? 0, completionTokens: completion ?? 0, cachedTokens: cached,
                        cacheWriteTokens: written, providerCostUsd: double(cost))
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: n
        case let n as NSNumber: n.intValue
        case let n as Double: Int(n)
        default: nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: n
        case let n as NSNumber: n.doubleValue
        case let n as Int: Double(n)
        default: nil
        }
    }
}

/// What a request cost.
public struct APICost: Sendable, Equatable {
    /// `provider`: the answer said what it costs. `computed`: tokens × the stored prices.
    public enum Source: String, Sendable { case provider, computed }
    public var usd: Double
    public var source: Source

    /// The provider's own figure wins; otherwise tokens × prices. Cached and cache-written
    /// prompt tokens are taken out of the plain input and billed at their own rates.
    public static func of(_ usage: APIUsage, pricing: APIPricing) -> APICost {
        if let usd = usage.providerCostUsd, usd >= 0 { return APICost(usd: usd, source: .provider) }
        let rates = pricing.rates(promptTokens: usage.promptTokens)
        let plain = max(0, usage.promptTokens - usage.cachedTokens - usage.cacheWriteTokens)
        let usd = (Double(plain) * rates.input
            + Double(usage.cachedTokens) * (rates.cacheRead ?? rates.input)
            + Double(usage.cacheWriteTokens) * (rates.cacheWrite ?? rates.input)
            + Double(usage.completionTokens) * rates.output) / 1_000_000
        return APICost(usd: usd, source: .computed)
    }
}

/// Tokens and cost one model used on one day.
public struct APIUsageTotals: Codable, Sendable, Equatable {
    public var requests: Int = 0
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var cachedTokens: Int = 0
    public var usd: Double = 0

    public init() {}

    public mutating func add(_ usage: APIUsage, cost: APICost) {
        requests += 1
        promptTokens += usage.promptTokens
        completionTokens += usage.completionTokens
        cachedTokens += usage.cachedTokens
        usd += cost.usd
    }

    public static func + (a: APIUsageTotals, b: APIUsageTotals) -> APIUsageTotals {
        var sum = a
        sum.requests += b.requests
        sum.promptTokens += b.promptTokens
        sum.completionTokens += b.completionTokens
        sum.cachedTokens += b.cachedTokens
        sum.usd += b.usd
        return sum
    }
}

/// Rewrites a request body for an API provider. Pure, shared with the server
/// (spec/cases/api-provider.json).
public enum APIForward {
    public struct Rewritten: @unchecked Sendable {
        public var body: [String: Any]
        /// The agent asked for the usage chunk itself; otherwise Podlight reads it and drops it.
        public var clientWantsUsage: Bool
    }

    /// `model` becomes the provider's id. A streamed chat completion always asks for usage, so
    /// Podlight can count tokens. Venice adds its own system prompt unless told not to; an agent
    /// brings its own, so Podlight turns Venice's off unless the agent set `venice_parameters`.
    public static func rewrite(_ json: [String: Any], path: String, provider: ModelProvider,
                               providerModelId: String) -> Rewritten {
        var body = json
        body["model"] = providerModelId
        var wantsUsage = true
        if path == "/v1/chat/completions" {
            if body["stream"] as? Bool == true {
                var options = body["stream_options"] as? [String: Any] ?? [:]
                wantsUsage = options["include_usage"] as? Bool == true
                options["include_usage"] = true
                body["stream_options"] = options
            }
            if provider == .venice, body["venice_parameters"] == nil {
                body["venice_parameters"] = ["include_venice_system_prompt": false]
            }
        }
        return Rewritten(body: body, clientWantsUsage: wantsUsage)
    }

    /// Paths an API provider serves. The rest answer 404 for these models.
    public static func supports(_ path: String, provider: ModelProvider) -> Bool {
        switch provider {
        case .runpod: true
        case .venice: ["/v1/chat/completions", "/v1/responses", "/v1/embeddings",
                       "/v1/messages", "/v1/messages/count_tokens"].contains(path)
        }
    }

    /// An error answer from the provider, as Podlight's own error: a used-up balance or key limit,
    /// a refused key, rate limits; anything else keeps its status.
    public static func failure(provider: ModelProvider, status: Int, body: Data) -> ProviderFailure {
        let text = String(data: body, encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = json?["error"]
        let detail: String = switch error {
        case let s as String: s
        case let o as [String: Any]: (o["message"] as? String) ?? (o["code"] as? String) ?? text
        default: (json?["message"] as? String) ?? text
        }
        let code = ((error as? [String: Any])?["code"] as? String) ?? (json?["code"] as? String) ?? ""
        let haystack = (code + " " + text).uppercased()
        let name = provider.displayName
        if haystack.contains("API_KEY_USD_SPEND_LIMIT_EXCEEDED") || haystack.contains("API_KEY_DIEM_SPEND_LIMIT_EXCEEDED") {
            return ProviderFailure(status: 402, code: "provider_key_limit",
                                   message: "The \(name) API key reached its own spending limit for today. Raise it at venice.ai → Settings → API, or wait for the next day.")
        }
        if status == 402 || haystack.contains("INSUFFICIENT_BALANCE") {
            return ProviderFailure(status: 402, code: "provider_balance",
                                   message: "Your \(name) balance is used up. Top it up at venice.ai, then try again.")
        }
        if status == 401 || status == 403 {
            return ProviderFailure(status: 502, code: "provider_auth",
                                   message: "\(name) refused Podlight's API key (\(status)). Check it in Podlight → Settings → Providers.")
        }
        if status == 429 {
            return ProviderFailure(status: 429, code: "provider_rate_limit",
                                   message: "\(name) is rate-limiting this key. Try again in a moment.")
        }
        let shown = detail.isEmpty ? "no details" : String(detail.prefix(300))
        return ProviderFailure(status: status >= 400 && status < 600 ? status : 502, code: "provider_error",
                               message: "\(name) answered \(status): \(shown)")
    }
}

/// A provider's error as the gateway passes it on.
public struct ProviderFailure: Sendable, Equatable {
    public var status: Int
    public var code: String
    public var message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }
}
