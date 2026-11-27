import CryptoKit
import Foundation

/// One request to an API model, as the gateway saw it: what it used, what it cost, how fast it
/// came. Kept for the last half hour per model, in memory, for the model's live view.
public struct APIRequestSample: Codable, Sendable, Equatable {
    /// When the answer ended.
    public var time: Date
    public var promptTokens: Int
    public var cachedTokens: Int
    public var completionTokens: Int
    public var usd: Double
    /// From sending the request to the first content of a streamed answer. Nil when not streamed.
    public var ttftMs: Int?
    /// From sending the request to the end of the answer.
    public var durationMs: Int
    /// The status the agent got: 200, or Modlight's error status.
    public var status: Int
    public var streamed: Bool

    public init(time: Date, promptTokens: Int, cachedTokens: Int, completionTokens: Int, usd: Double,
                ttftMs: Int?, durationMs: Int, status: Int, streamed: Bool) {
        self.time = time
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.completionTokens = completionTokens
        self.usd = usd
        self.ttftMs = ttftMs
        self.durationMs = durationMs
        self.status = status
        self.streamed = streamed
    }

    /// Output tokens per second while the model wrote: after the first token, until the end.
    public var outputTokensPerSecond: Double? {
        guard streamed, let ttft = ttftMs, durationMs > ttft, completionTokens > 0 else { return nil }
        return Double(completionTokens) / (Double(durationMs - ttft) / 1000)
    }
}

/// The provider's rate limit for a key and model, from the headers of its latest answer.
public struct APIRateLimit: Codable, Sendable, Equatable {
    public var limitRequests: Int?
    public var remainingRequests: Int?
    public var resetRequests: Date?
    public var limitTokens: Int?
    public var remainingTokens: Int?
    public var resetTokens: Date?
    /// When the answer carrying these headers came.
    public var at: Date

    public init(limitRequests: Int? = nil, remainingRequests: Int? = nil, resetRequests: Date? = nil,
                limitTokens: Int? = nil, remainingTokens: Int? = nil, resetTokens: Date? = nil, at: Date) {
        self.limitRequests = limitRequests
        self.remainingRequests = remainingRequests
        self.resetRequests = resetRequests
        self.limitTokens = limitTokens
        self.remainingTokens = remainingTokens
        self.resetTokens = resetTokens
        self.at = at
    }

    /// Venice's `x-ratelimit-{limit,remaining,reset}-{requests,tokens}`; resets are Unix
    /// milliseconds. Header names in any case. Nil without any of them.
    public static func from(headers: [String: String], at: Date) -> APIRateLimit? {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) },
                                 uniquingKeysWith: { a, _ in a })
        func int(_ name: String) -> Int? { lowered["x-ratelimit-\(name)"].flatMap { Int($0) ?? Double($0).map { Int($0) } } }
        func date(_ name: String) -> Date? {
            lowered["x-ratelimit-\(name)"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        let limit = APIRateLimit(limitRequests: int("limit-requests"), remainingRequests: int("remaining-requests"),
                                 resetRequests: date("reset-requests"), limitTokens: int("limit-tokens"),
                                 remainingTokens: int("remaining-tokens"), resetTokens: date("reset-tokens"), at: at)
        let any = [limit.limitRequests, limit.remainingRequests, limit.limitTokens, limit.remainingTokens].contains { $0 != nil }
        return any ? limit : nil
    }
}

/// What an API model did in the last half hour, worked out from its samples. Pure, shared with
/// the server (spec/cases/api-telemetry.json).
public struct APITelemetrySummary: Codable, Sendable, Equatable {
    public struct Minute: Codable, Sendable, Equatable {
        public var start: Date
        /// Prompt tokens not read from the cache.
        public var newInput: Int
        public var cachedInput: Int
        public var output: Int
        public var usd: Double
        public var requests: Int
    }

    /// 30 one-minute buckets, oldest first, the last one is the current minute.
    public var minutes: [Minute]
    public var requests: Int
    /// Requests per minute over the last five minutes.
    public var requestsPerMinute: Double
    /// Share of prompt tokens read from the cache; nil without prompt tokens.
    public var cacheShare: Double?
    /// Median time to the first token of streamed answers (the lower middle for an even count).
    public var ttftP50Ms: Int?
    /// Median output speed of streamed answers.
    public var tokensPerSecondMedian: Double?
    /// Share of requests that ended with an error status.
    public var errorShare: Double?
    /// What the last 15 minutes cost, as an hourly rate.
    public var usdPerHour: Double
    /// Mean prompt size of answered requests: how much context an agent sends each time.
    public var averagePromptTokens: Int?
    /// How long the balance lasts at `usdPerHour`.
    public var runwayHours: Double?
}

public enum APITelemetry {
    /// Samples are kept and summarised for this long.
    public static let window: TimeInterval = 30 * 60

    public static func summary(_ samples: [APIRequestSample], now: Date, balanceUsd: Double?) -> APITelemetrySummary {
        let recent = samples.filter { $0.time > now.addingTimeInterval(-window) && $0.time <= now }
        let currentMinute = (now.timeIntervalSince1970 / 60).rounded(.down) * 60
        var minutes = (0..<30).map { index in
            APITelemetrySummary.Minute(start: Date(timeIntervalSince1970: currentMinute - Double(29 - index) * 60),
                                       newInput: 0, cachedInput: 0, output: 0, usd: 0, requests: 0)
        }
        for sample in recent {
            let offset = Int(((sample.time.timeIntervalSince1970 - minutes[0].start.timeIntervalSince1970) / 60).rounded(.down))
            guard (0..<30).contains(offset) else { continue }
            minutes[offset].newInput += max(0, sample.promptTokens - sample.cachedTokens)
            minutes[offset].cachedInput += sample.cachedTokens
            minutes[offset].output += sample.completionTokens
            minutes[offset].usd += sample.usd
            minutes[offset].requests += 1
        }
        let prompt = recent.map(\.promptTokens).reduce(0, +)
        let cached = recent.map(\.cachedTokens).reduce(0, +)
        let answered = recent.filter { $0.status < 400 && $0.promptTokens > 0 }
        let lastFive = recent.filter { $0.time > now.addingTimeInterval(-5 * 60) }.count
        let usdPerHour = recent.filter { $0.time > now.addingTimeInterval(-15 * 60) }.map(\.usd).reduce(0, +) * 4
        let errors = recent.filter { $0.status >= 400 }.count
        return APITelemetrySummary(
            minutes: minutes,
            requests: recent.count,
            requestsPerMinute: Double(lastFive) / 5,
            cacheShare: prompt > 0 ? Double(cached) / Double(prompt) : nil,
            ttftP50Ms: lowerMedian(recent.compactMap(\.ttftMs)),
            tokensPerSecondMedian: lowerMedian(recent.compactMap(\.outputTokensPerSecond)),
            errorShare: recent.isEmpty ? nil : Double(errors) / Double(recent.count),
            usdPerHour: usdPerHour,
            averagePromptTokens: answered.isEmpty ? nil : answered.map(\.promptTokens).reduce(0, +) / answered.count,
            runwayHours: balanceUsd.flatMap { balance in usdPerHour > 0 && balance > 0 ? balance / usdPerHour : nil })
    }

    static func lowerMedian<T: Comparable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[(values.count - 1) / 2]
    }

    /// A stream chunk that carries what the model wrote (text, reasoning or a tool call), not
    /// only a role or the usage: its arrival is the time to first token.
    public static func hasContent(_ chunk: [String: Any]) -> Bool {
        if let type = chunk["type"] as? String { return type.hasSuffix(".delta") }
        guard let choices = chunk["choices"] as? [[String: Any]] else { return false }
        return choices.contains { choice in
            let delta = choice["delta"] as? [String: Any] ?? [:]
            for key in ["content", "reasoning_content", "reasoning"] {
                if let text = delta[key] as? String, !text.isEmpty { return true }
            }
            if let calls = delta["tool_calls"] as? [Any], !calls.isEmpty { return true }
            return false
        }
    }

    /// The cache key Modlight sends when the agent sent none: the same model and system prompt
    /// always give the same key, so Venice routes them to a backend that has the prefix cached.
    /// Nil without a system prompt (nothing stable to key on).
    public static func cacheKey(_ body: [String: Any], providerModelId: String) -> String? {
        var system = ""
        if let instructions = body["instructions"] as? String { system = instructions }
        for message in body["messages"] as? [[String: Any]] ?? [] {
            guard let role = message["role"] as? String, role == "system" || role == "developer" else { continue }
            switch message["content"] {
            case let text as String: system += text
            case let parts as [[String: Any]]: system += parts.compactMap { $0["text"] as? String }.joined()
            default: break
            }
        }
        guard !system.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("\(providerModelId)\n\(system)".utf8))
        return "modlight-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
