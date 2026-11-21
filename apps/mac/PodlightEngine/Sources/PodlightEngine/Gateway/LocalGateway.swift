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

    public init(port: Int, host: String = "127.0.0.1", manager: PodManager, transport: HTTPTransport = URLSession.shared,
                key: @escaping @Sendable () -> String?) {
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

    /// Request headers the engine needs to see unchanged.
    static let passedHeaders = ["anthropic-version", "anthropic-beta", "openai-beta"]

    private func forward(_ incoming: Request, path: String) async throws -> Response {
        var incoming = incoming
        let anthropic = path.hasPrefix("/v1/messages")
        await manager.clientSeen()
        let body = try await incoming.collectBody(upTo: 64 * 1024 * 1024)
        let data = Data(buffer: body)
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

        await manager.requestBegan(endpoint.modelId)
        var target = endpoint.baseURL.appendingPathComponent(String(path.dropFirst()))
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

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: upstream)
        } catch {
            await manager.requestEnded(endpoint.modelId)
            return Self.error(502, "The pod for \(name) did not answer: \(error.localizedDescription)", code: "upstream_unreachable", anthropic: anthropic)
        }
        let http = response as? HTTPURLResponse
        var headers = HTTPFields()
        headers[.contentType] = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        headers[.cacheControl] = "no-cache"

        let manager = self.manager
        let modelId = endpoint.modelId
        let responseBody = ResponseBody { writer in
            defer { Task { await manager.requestEnded(modelId) } }
            var buffer = ByteBuffer()
            buffer.reserveCapacity(4096)
            for try await byte in bytes {
                buffer.writeInteger(byte)
                // Server-sent events: pass every line on at once, so tokens reach the agent as
                // they are produced rather than in 16 KB lumps.
                if byte == UInt8(ascii: "\n") || buffer.readableBytes >= 16_384 {
                    try await writer.write(buffer)
                    buffer.clear()
                }
            }
            if buffer.readableBytes > 0 { try await writer.write(buffer) }
            try await writer.finish(nil)
        }
        return Response(status: .init(code: http?.statusCode ?? 502), headers: headers, body: responseBody)
    }

    // MARK: Responses

    static func response(for error: PodlightError, model: String, anthropic: Bool = false) -> Response {
        switch error {
        case .unknownModel:
            return Self.error(404, "Podlight has no model named \"\(model)\". GET /v1/models lists them.", code: "model_not_found", anthropic: anthropic)
        case .missingRunpodKey:
            return Self.error(503, "Podlight has no RunPod API key yet. Open Podlight and finish setup.", code: "setup_incomplete", anthropic: anthropic)
        case .limitReached(let which):
            let limit = which == "monthly-limit" ? "monthly" : "daily"
            return Self.error(429, "Podlight's \(limit) spending limit is reached, so \(model) stays stopped. Raise the limit in Podlight → Costs.", code: "spend_limit", anthropic: anthropic)
        case .noCapacity(let tried):
            return Self.error(503, "RunPod has no free card for \(model) right now (tried: \(tried.joined(separator: ", "))). Try again in a few minutes.", code: "no_capacity", anthropic: anthropic)
        case .noSuitableCard:
            return Self.error(503, "No RunPod card can hold \(model) with its configured context.", code: "no_suitable_card", anthropic: anthropic)
        case .notReadyInTime:
            return Self.error(503, "\(model) is still starting. A new pod can take up to 25 minutes (the GPU host downloads the engine and the model); a resumed one about a minute. Try again shortly, or start it in Podlight beforehand.", code: "starting", anthropic: anthropic)
        case .wakeDisabled:
            return Self.error(503, "\(model) is stopped. Start it in Podlight.", code: "stopped", anthropic: anthropic)
        case .runpod(let status, let message):
            return Self.error(502, "RunPod refused (\(status)): \(message.prefix(200))", code: "runpod_error", anthropic: anthropic)
        case .keychain(let message):
            return Self.error(500, "Podlight could not read its keychain: \(message)", code: "keychain", anthropic: anthropic)
        }
    }

    /// OpenAI's error shape, or Anthropic's for the Messages API so Claude Code shows the message.
    static func error(_ status: Int, _ message: String, code: String, anthropic: Bool = false) -> Response {
        if anthropic {
            let type = switch status {
            case 400: "invalid_request_error"
            case 401: "authentication_error"
            case 404: "not_found_error"
            case 429: "rate_limit_error"
            case 503: "overloaded_error"
            default: "api_error"
            }
            return json(status, ["type": "error", "error": ["type": type, "message": message]])
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
