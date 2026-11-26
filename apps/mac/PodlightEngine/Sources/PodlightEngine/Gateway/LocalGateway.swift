import Foundation
import Hummingbird
import NIOCore

/// The OpenAI-compatible endpoint for agents, e.g. OpenCode, with the Responses API for Codex and
/// the Anthropic Messages API for Claude Code passed through to the engine (vLLM and llama.cpp
/// both serve them).
///
/// Listens on 127.0.0.1 by default; with "local network" switched on, on every interface so other
/// computers can use it. Either way it always wants Podlight's key: without it any program, web
/// page or device could wake a pod at the owner's expense. The `model` field picks the model; a
/// stopped pod is woken and the request held until it answers (up to the wake wait).
public struct LocalGateway: Sendable {
    public let port: Int
    /// `127.0.0.1` for this Mac only, `0.0.0.0` for the local network.
    public let host: String
    private let manager: PodManager
    private let keyProvider: @Sendable () -> String?
    private let transport: HTTPTransport
    /// Wait between tries while RunPod's proxy is not yet routing; shorter in tests.
    private let proxyRetryDelay: Duration

    public init(port: Int, host: String = "127.0.0.1", manager: PodManager, transport: HTTPTransport = URLSession.shared,
                proxyRetryDelay: Duration = .seconds(5), key: @escaping @Sendable () -> String?) {
        self.proxyRetryDelay = proxyRetryDelay
        self.port = port
        self.host = host
        self.manager = manager
        self.keyProvider = key
        self.transport = transport
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    /// Runs until the surrounding task is cancelled. Throws when the port is taken.
    public func run(onReady: @escaping @Sendable () -> Void = {}) async throws {
        let router = Router()
        router.middlewares.add(AuthMiddleware(key: keyProvider))

        router.get("/v1/models") { _, _ -> Response in
            await manager.clientSeen()
            let state = await manager.state()
            // OpenAI's fields, plus Anthropic's `type` and `display_name` for Claude Code's model list.
            let data: [[String: Any]] = state.models.map { model in
                ["id": model.name, "object": "model", "type": "model", "display_name": model.name, "owned_by": "podlight",
                 "created": Int(model.createdAt.timeIntervalSince1970),
                 "created_at": ISO8601DateFormatter().string(from: model.createdAt),
                 "max_model_len": model.contextTokens, "context_length": model.contextTokens]
            }
            var list: [String: Any] = ["object": "list", "data": data, "has_more": false]
            if let first = state.models.first?.name, let last = state.models.last?.name {
                list["first_id"] = first
                list["last_id"] = last
            }
            return Self.json(200, list)
        }

        for path in Self.forwardedPaths {
            router.post(RouterPath(path)) { request, _ -> Response in
                try await self.forward(request, path: path)
            }
        }

        router.get("/") { _, _ -> Response in
            Self.json(200, ["name": "Podlight", "openai_base_url": "http://127.0.0.1:\(port)/v1"])
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port), serverName: "Podlight"),
            onServerRunning: { _ in onReady() })
        try await app.run()
    }

    /// POST routes passed to the engine as they are.
    static let forwardedPaths = [
        "/v1/chat/completions", "/v1/completions", "/v1/embeddings",
        // OpenAI Responses API: Codex speaks only this.
        "/v1/responses", "/v1/responses/input_tokens",
        // Anthropic Messages API: Claude Code.
        "/v1/messages", "/v1/messages/count_tokens",
    ]

    /// Claude Code puts entries with `role: "system"` into `messages` (its environment, reminders),
    /// after the first user turn. The engines turn each into one more system message, and many chat
    /// templates, Qwen's among them, refuse that with "System message must be at the beginning".
    /// Podlight hands them on in the same place as user text inside `<system-reminder>`, the way
    /// Claude Code marks such text elsewhere, so the prefix the engine caches stays the same.
    /// Returns nil when there is nothing to change, so the body goes on byte for byte.
    static func systemMessagesAsReminders(_ json: [String: Any]) -> [String: Any]? {
        guard var messages = json["messages"] as? [[String: Any]],
              messages.contains(where: { $0["role"] as? String == "system" }) else { return nil }
        for index in messages.indices where messages[index]["role"] as? String == "system" {
            let text: String
            switch messages[index]["content"] {
            case let string as String: text = string
            case let blocks as [[String: Any]]: text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            default: text = ""
            }
            messages[index] = ["role": "user",
                               "content": [["type": "text", "text": "<system-reminder>\n\(text)\n</system-reminder>"]]]
        }
        var result = json
        result["messages"] = messages
        return result
    }

    /// Tries after a proxy 404: up to 30 seconds for RunPod's proxy to start routing.
    static let proxyRetries = 6

    /// An engine answers with JSON; RunPod's proxy, before it routes to the pod, does not.
    static func isProxyNotReady(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, http.statusCode == 404 else { return false }
        return !(http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("application/json")
    }

    /// Request headers the engine needs to see unchanged.
    static let passedHeaders = ["anthropic-version", "anthropic-beta", "openai-beta"]

    private func forward(_ incoming: Request, path: String) async throws -> Response {
        var incoming = incoming
        let anthropic = path.hasPrefix("/v1/messages")
        await manager.clientSeen()
        let body = try await incoming.collectBody(upTo: 64 * 1024 * 1024)
        var data = Data(buffer: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.error(400, "The request body is not JSON.", code: "invalid_json", anthropic: anthropic)
        }
        guard let name = json["model"] as? String, !name.isEmpty else {
            let names = await manager.state().models.map(\.name)
            return Self.error(400, "Set \"model\" to one of: \(names.joined(separator: ", ")).", code: "model_missing", anthropic: anthropic)
        }

        let endpoint: PodEndpoint
        do {
            endpoint = try await manager.endpoint(forModelNamed: name)
        } catch let error as PodlightError {
            return Self.response(for: error, model: name, anthropic: anthropic)
        }

        // What goes upstream: a pod gets the body as it came (system entries fixed for the Messages
        // API); an API provider gets its own model id and a request for usage.
        var meter: UsageMeter?
        var upstreamPath = path
        /// Claude Code's Messages request, sent to the provider as a chat completion.
        var bridged = false
        switch endpoint.upstream {
        case .pod:
            if anthropic, let fixed = Self.systemMessagesAsReminders(json),
               let encoded = try? JSONSerialization.data(withJSONObject: fixed) {
                data = encoded
            }
        case .api(let provider, let providerModelId):
            guard APIForward.supports(path, provider: provider) else {
                return Self.response(for: .unsupportedPath(path, provider), model: name, anthropic: anthropic)
            }
            var outgoing = json
            if path == "/v1/messages/count_tokens" {
                // OpenAI-style providers cannot count; Claude Code only needs an estimate.
                return Self.json(200, ["input_tokens": AnthropicBridge.estimateTokens(json)])
            }
            if path == "/v1/messages" {
                do {
                    outgoing = try AnthropicBridge.request(json)
                } catch let error as AnthropicBridge.InvalidRequest {
                    return Self.error(400, error.message, code: "invalid_request", anthropic: true)
                }
                upstreamPath = "/v1/chat/completions"
                bridged = true
            }
            let rewritten = APIForward.rewrite(outgoing, path: upstreamPath, provider: provider, providerModelId: providerModelId)
            data = (try? JSONSerialization.data(withJSONObject: rewritten.body)) ?? data
            meter = UsageMeter(dropUsageChunk: !rewritten.clientWantsUsage)
        }

        await manager.requestBegan(endpoint.modelId)
        // A pod's address is its engine's root (`…/v1/…` follows); a provider's ends in its own
        // version (`https://api.venice.ai/api/v1`), so only the rest of the path follows.
        let relative = endpoint.upstream == .pod ? String(path.dropFirst()) : String(upstreamPath.dropFirst("/v1/".count))
        var target = endpoint.baseURL.appendingPathComponent(relative)
        // Claude Code sends `?beta=true`; keep any query as it came.
        if let query = incoming.uri.query, !query.isEmpty, var parts = URLComponents(url: target, resolvingAgainstBaseURL: false) {
            parts.percentEncodedQuery = query
            target = parts.url ?? target
        }
        var upstream = URLRequest(url: target)
        upstream.httpMethod = "POST"
        upstream.httpBody = data
        upstream.timeoutInterval = 900
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        if let accept = incoming.headers[.accept] { upstream.setValue(accept, forHTTPHeaderField: "Accept") }
        for name in Self.passedHeaders {
            if let value = Self.header(name, in: incoming) { upstream.setValue(value, forHTTPHeaderField: name) }
        }

        // RunPod's proxy answers 404 without JSON while it is not yet routing to a freshly started
        // pod, even after the engine reported ready (seen live 2026-11-21 on the first request
        // after a wake). The request is held anyway, so it is tried again for up to 30 seconds.
        // An API provider is always routed: one try.
        let tries = endpoint.upstream == .pod ? Self.proxyRetries : 0
        let started = Date()
        var bytes: URLSession.AsyncBytes?
        var response: URLResponse?
        for attempt in 0...tries {
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: upstream)
            } catch {
                await manager.requestEnded(endpoint.modelId)
                let what = endpoint.upstream == .pod ? "The pod for \(name)" : "\(Self.upstreamName(endpoint)) for \(name)"
                return Self.error(502, "\(what) did not answer: \(error.localizedDescription)", code: "upstream_unreachable", anthropic: anthropic)
            }
            guard endpoint.upstream == .pod, let r = response, Self.isProxyNotReady(r) else { break }
            bytes?.task.cancel()
            if attempt < tries { try? await Task.sleep(for: proxyRetryDelay) }
        }
        guard let bytes, let response, endpoint.upstream != .pod || !Self.isProxyNotReady(response) else {
            await manager.requestEnded(endpoint.modelId)
            return Self.response(for: .notReadyInTime, model: name, anthropic: anthropic)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 502
        let rateLimit = http.flatMap { response in
            APIRateLimit.from(headers: Dictionary(response.allHeaderFields.compactMap { key, value in
                (key as? String).map { ($0, "\(value)") } }, uniquingKeysWith: { a, _ in a }), at: Date())
        }

        // A provider's error becomes Podlight's own, in the agent's API shape.
        if case .api(let provider, _) = endpoint.upstream, status >= 400 {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= 64 * 1024 { break }
                }
            } catch {}
            let failure = APIForward.failure(provider: provider, status: status, body: body)
            await manager.finishAPIRequest(endpoint.modelId, usage: nil, started: started, firstContent: nil, ended: Date(),
                                           status: failure.status, streamed: false, rateLimit: rateLimit)
            await manager.requestEnded(endpoint.modelId)
            return Self.response(for: .provider(failure), model: name, anthropic: anthropic)
        }

        var headers = HTTPFields()
        headers[.contentType] = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        headers[.cacheControl] = "no-cache"

        let manager = self.manager
        let modelId = endpoint.modelId
        if bridged {
            let streamed = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream")
            headers[.contentType] = streamed ? "text/event-stream" : "application/json"
            return Response(status: .init(code: status), headers: headers,
                            body: Self.bridgedBody(bytes, streamed: streamed, model: name, manager: manager, modelId: modelId,
                                                   started: started, status: status, rateLimit: rateLimit))
        }
        let startingMeter = meter
        let streamedAnswer = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream")
        let responseBody = ResponseBody { writer in
            var meter = startingMeter
            defer {
                let usage = meter?.finish()
                let firstContent = meter?.firstContentAt
                let metered = meter != nil
                let ended = Date()
                Task {
                    if metered {
                        await manager.finishAPIRequest(modelId, usage: usage, started: started, firstContent: firstContent,
                                                       ended: ended, status: status, streamed: streamedAnswer, rateLimit: rateLimit)
                    }
                    await manager.requestEnded(modelId)
                }
            }
            var buffer = ByteBuffer()
            buffer.reserveCapacity(4096)
            var line = Data()
            for try await byte in bytes {
                if meter != nil {
                    // Metered: whole lines, so the usage chunk can be read and, if wanted, dropped.
                    line.append(byte)
                    guard byte == UInt8(ascii: "\n") || line.count >= 1_048_576 else { continue }
                    if let passed = meter?.pass(line) { try await writer.write(ByteBuffer(bytes: passed)) }
                    line.removeAll(keepingCapacity: true)
                    continue
                }
                buffer.writeInteger(byte)
                // Server-sent events: pass every line on at once, so tokens reach the agent as
                // they are produced rather than in 16 KB lumps.
                if byte == UInt8(ascii: "\n") || buffer.readableBytes >= 16_384 {
                    try await writer.write(buffer)
                    buffer.clear()
                }
            }
            if !line.isEmpty, let passed = meter?.pass(line) { try await writer.write(ByteBuffer(bytes: passed)) }
            if buffer.readableBytes > 0 { try await writer.write(buffer) }
            try await writer.finish(nil)
        }
        return Response(status: .init(code: status), headers: headers, body: responseBody)
    }

    /// A provider's chat completion answer as Anthropic Messages: a stream event by event, or one
    /// message. Usage is booked from the provider's answer either way.
    static func bridgedBody(_ bytes: URLSession.AsyncBytes, streamed: Bool, model: String,
                            manager: PodManager, modelId: UUID, started: Date, status: Int,
                            rateLimit: APIRateLimit?) -> ResponseBody {
        ResponseBody { writer in
            var usage: APIUsage?
            var firstContent: Date?
            defer {
                let booked = usage
                let first = firstContent
                let ended = Date()
                Task {
                    await manager.finishAPIRequest(modelId, usage: booked, started: started, firstContent: first, ended: ended,
                                                   status: status, streamed: streamed, rateLimit: rateLimit)
                    await manager.requestEnded(modelId)
                }
            }
            func send(_ events: [[String: Any]]) async throws {
                for event in events {
                    let type = event["type"] as? String ?? "message"
                    try await writer.write(ByteBuffer(string: "event: \(type)\ndata: \(AnthropicBridge.canonicalJSON(event))\n\n"))
                }
            }
            if streamed {
                var translator = AnthropicBridge.StreamTranslator(requestModel: model)
                var line = Data()
                func take(_ line: Data) async throws {
                    guard line.starts(with: Data("data:".utf8)) else { return }
                    let payload = Data(line.dropFirst(5))
                    guard let chunk = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }
                    if let found = APIUsage.from(chunk) { usage = found }
                    if firstContent == nil, APITelemetry.hasContent(chunk) { firstContent = Date() }
                    try await send(translator.feed(chunk))
                }
                for try await byte in bytes {
                    line.append(byte)
                    guard byte == UInt8(ascii: "\n") else { continue }
                    try await take(line)
                    line.removeAll(keepingCapacity: true)
                }
                if !line.isEmpty { try await take(line) }
                try await send(translator.finish())
            } else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                usage = APIUsage.from(json)
                let message = AnthropicBridge.response(json, requestModel: model)
                try await writer.write(ByteBuffer(bytes: (try? JSONSerialization.data(withJSONObject: message)) ?? Data("{}".utf8)))
            }
            try await writer.finish(nil)
        }
    }

    static func upstreamName(_ endpoint: PodEndpoint) -> String {
        if case .api(let provider, _) = endpoint.upstream { return provider.displayName }
        return "The pod"
    }

    // MARK: Responses

    /// What the gateway answers for an error: HTTP status, sentence and code. Pure, so the server
    /// can be held to the same codes (spec/cases/gateway.json).
    struct Failure: Equatable, Sendable {
        var status: Int
        var message: String
        var code: String
    }

    static func failure(for error: PodlightError, model: String) -> Failure {
        switch error {
        case .unknownModel:
            return Failure(status: 404, message: "Podlight has no model named \"\(model)\". GET /v1/models lists them.", code: "model_not_found")
        case .missingRunpodKey:
            return Failure(status: 503, message: "Podlight has no RunPod API key yet. Open Podlight and finish setup.", code: "setup_incomplete")
        case .limitReached(let which):
            let limit = which == "monthly-limit" ? "monthly" : "daily"
            return Failure(status: 429, message: "Podlight's \(limit) spending limit is reached, so \(model) stays stopped. Raise the limit in Podlight → Costs.", code: "spend_limit")
        case .noCapacity(let tried):
            return Failure(status: 503, message: "RunPod has no free card for \(model) right now (tried: \(tried.joined(separator: ", "))). Try again in a few minutes.", code: "no_capacity")
        case .noSuitableCard:
            return Failure(status: 503, message: "No RunPod card can hold \(model) with its configured context.", code: "no_suitable_card")
        case .notReadyInTime:
            return Failure(status: 503, message: "\(model) is still starting. A new pod can take up to 25 minutes (the GPU host downloads the engine and the model); a resumed one about a minute. Try again shortly, or start it in Podlight beforehand.", code: "starting")
        case .wakeDisabled:
            return Failure(status: 503, message: "\(model) is stopped. Start it in Podlight.", code: "stopped")
        case .runpod(let status, let message):
            return Failure(status: 502, message: "RunPod refused (\(status)): \(message.prefix(200))", code: "runpod_error")
        case .keychain(let message):
            return Failure(status: 500, message: "Podlight could not read its keychain: \(message)", code: "keychain")
        case .managedElsewhere(let mac):
            return Failure(status: 409, message: "\(model) is managed by another Mac (\(mac)) now. Use it there, or take it back in Podlight on this Mac.", code: "managed_elsewhere")
        case .hostBusy:
            return Failure(status: 503, message: "The card on the machine of \(model)'s pod is taken right now, so it could not resume. Its disk with the model is kept, and Podlight keeps trying to resume it for half an hour. Try again in a few minutes, or start it on a new card in Podlight.", code: "host_busy")
        case .cardTooExpensive(let wanted, let ceiling, _):
            let card = wanted.map { "\($0.name) at \(Self.dollars($0.pricePerHour))/h" } ?? "The chosen card"
            return Failure(status: 503, message: "\(card) for \(model) is taken, and the free cards cost more than Podlight's price step allows. Nothing was booked; Podlight keeps trying for a card up to \(Self.dollars(ceiling))/h. Start it on a pricier card in Podlight, or try again later.", code: "card_too_expensive")
        case .missingProviderKey(let provider):
            return Failure(status: 503, message: "Podlight has no \(provider.displayName) API key yet. Add it in Podlight → Settings → Providers.", code: "setup_incomplete")
        case .provider(let failure):
            return Failure(status: failure.status, message: failure.message, code: failure.code)
        case .unsupportedPath(let path, let provider):
            return Failure(status: 404, message: "\(model) runs at \(provider.displayName), which does not serve \(path). Use /v1/chat/completions, /v1/responses or /v1/messages.", code: "unsupported_endpoint")
        case .nameTaken, .modelLookup, .busy:
            return Failure(status: 500, message: "Podlight could not serve \(model).", code: "internal")
        }
    }

    /// "$1.19": two decimals, three below a cent's worth of precision is noise here.
    static func dollars(_ value: Double) -> String { String(format: "$%.2f", value) }

    static func response(for error: PodlightError, model: String, anthropic: Bool = false) -> Response {
        let f = failure(for: error, model: model)
        return Self.error(f.status, f.message, code: f.code, anthropic: anthropic)
    }

    /// Anthropic's error type for an HTTP status.
    static func anthropicType(_ status: Int) -> String {
        switch status {
        case 400: "invalid_request_error"
        case 401: "authentication_error"
        case 402: "billing_error"
        case 403: "permission_error"
        case 404: "not_found_error"
        case 429: "rate_limit_error"
        case 503: "overloaded_error"
        default: "api_error"
        }
    }

    /// OpenAI's error shape, or Anthropic's for the Messages API so Claude Code shows the message.
    static func error(_ status: Int, _ message: String, code: String, anthropic: Bool = false) -> Response {
        if anthropic {
            return json(status, ["type": "error", "error": ["type": anthropicType(status), "message": message]])
        }
        return json(status, ["error": ["message": message, "type": "podlight_error", "code": code]])
    }

    /// A request header by name, case-insensitively.
    static func header(_ name: String, in request: Request) -> String? {
        request.headers.first { $0.name.canonicalName == name.lowercased() }?.value
    }

    static func json(_ status: Int, _ object: Any) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: .init(code: status), headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

/// Every request needs Podlight's key, as a bearer token or `X-Api-Key`. Compared in constant time.
struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let key: @Sendable () -> String?

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if request.uri.path == "/" { return try await next(request, context) }
        guard let expected = key(), !expected.isEmpty else {
            return LocalGateway.error(503, "Podlight has no gateway key yet. Open Podlight and finish setup.", code: "setup_incomplete")
        }
        // `Authorization: Bearer` (OpenAI, Codex, Claude Code's ANTHROPIC_AUTH_TOKEN) or
        // `X-Api-Key` (Claude Code's ANTHROPIC_API_KEY).
        let header = request.headers[.authorization] ?? ""
        let bearer = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : ""
        let given = bearer.isEmpty ? (LocalGateway.header("x-api-key", in: request) ?? "") : bearer
        guard Self.constantTimeEqual(given, expected) else {
            // A pause on every wrong key makes guessing slow, which matters once the network can reach us.
            try? await Task.sleep(for: .seconds(1))
            return LocalGateway.error(401, "Wrong or missing API key. Copy it from Podlight → Connection.", code: "invalid_api_key",
                                      anthropic: request.uri.path.hasPrefix("/v1/messages"))
        }
        return try await next(request, context)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}
