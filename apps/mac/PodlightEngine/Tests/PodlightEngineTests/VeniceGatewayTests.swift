import Foundation
import Hummingbird
import NIOCore
import Testing
@testable import PodlightEngine

// API models through the gateway, against a stand-in for Venice: the request is rewritten, the
// provider's key is used, usage is counted and its cost booked, errors become Podlight's own.

/// What the fake Venice saw of the last request.
actor VeniceLog {
    var bodies: [Data] = []
    var authorizations: [String] = []
    var paths: [String] = []
    func record(_ body: Data, auth: String, path: String) {
        bodies.append(body)
        authorizations.append(auth)
        paths.append(path)
    }
    var count: Int { bodies.count }
    var lastBody: Data? { bodies.last }
}

extension VeniceLog {
    /// The last request body Venice saw, decoded.
    nonisolated func last() async -> [String: Any]? {
        guard let data = await lastBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private func runFakeVenice(port: Int, log: VeniceLog) async throws {
    let router = Router()
    router.post("/api/v1/chat/completions") { request, _ -> Response in
        var request = request
        let data = Data(buffer: try await request.collectBody(upTo: 1 << 20))
        let body = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        await log.record(data, auth: request.headers[.authorization] ?? "", path: request.uri.path)
        let messages = body["messages"] as? [[String: Any]] ?? []
        let prompt = messages.first?["content"] as? String ?? ""
        if prompt == "broke" {
            return Response(status: .init(code: 402), headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: #"{"error":"Insufficient balance","code":"INSUFFICIENT_BALANCE"}"#)))
        }
        if body["stream"] as? Bool == true {
            let usage = (body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true
            return Response(status: .ok, headers: [.contentType: "text/event-stream"], body: ResponseBody { writer in
                for word in ["Hal", "lo"] {
                    try await writer.write(ByteBuffer(string: #"data: {"choices":[{"index":0,"delta":{"content":"\#(word)"}}]}"# + "\n\n"))
                }
                if usage {
                    try await writer.write(ByteBuffer(string: #"data: {"choices":[],"usage":{"prompt_tokens":1000000,"completion_tokens":500000}}"# + "\n\n"))
                }
                try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
                try await writer.finish(nil)
            })
        }
        let answer = #"{"id":"c1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Hallo"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1200,"completion_tokens":300,"total_tokens":1500},"cost":{"usd":0.25,"diem":0.25}}"#
        return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: answer)))
    }
    router.get("/") { _, _ in "venice" }
    try await Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: port))).run()
}

private func waitFor(port: Int) async throws {
    for _ in 0..<50 {
        if (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)) != nil { return }
        try await Task.sleep(for: .milliseconds(100))
    }
}

@Suite("Venice through the gateway", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                                                           "uses the login keychain; runs on a developer Mac"))
struct VeniceGatewayTests {
    @Test func routesMetersAndMapsErrors() async throws {
        let keychain = KeychainStore(service: "app.podlight.tests.\(UUID().uuidString)")
        defer { for item in [KeychainStore.Item.veniceAPIKey, .gatewayKey] { try? keychain.delete(item) } }
        try keychain.write("gw-test", for: .gatewayKey)

        let venicePort = Int.random(in: 45_000...47_000)
        let gatewayPort = venicePort + 1000
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-venice-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let manager = PodManager(store: StateStore(url: stateURL), keychain: keychain,
                                 apiBaseURL: { _ in URL(string: "http://127.0.0.1:\(venicePort)/api/v1")! })

        let offer = try #require(try VeniceClient.offers(from: Data(contentsOf: Spec.root.appendingPathComponent("fixtures/venice-models.json")))
            .first { $0.providerModelId == "venice-uncensored-1-2" })
        let model = offer.model(named: "uncensored")
        #expect(!model.isPod && model.provider == .venice)
        try await manager.save(model)

        let log = VeniceLog()
        let venice = Task { try await runFakeVenice(port: venicePort, log: log) }
        let gateway = Task { try await LocalGateway(port: gatewayPort, manager: manager, key: { "gw-test" }).run() }
        defer { venice.cancel(); gateway.cancel() }
        try await waitFor(port: venicePort)
        try await waitFor(port: gatewayPort)
        let base = "http://127.0.0.1:\(gatewayPort)"

        func post(_ path: String, _ body: String) async throws -> (Int, String) {
            var r = URLRequest(url: URL(string: "\(base)\(path)")!)
            r.httpMethod = "POST"
            r.setValue("Bearer gw-test", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(body.utf8)
            let (data, response) = try await URLSession.shared.data(for: r)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }

        // Without a Venice key: setup is incomplete, nothing reaches Venice.
        let (noKey, noKeyBody) = try await post("/v1/chat/completions", #"{"model":"uncensored","messages":[{"role":"user","content":"Hi"}]}"#)
        #expect(noKey == 503 && noKeyBody.contains("setup_incomplete"))
        #expect(await log.count == 0)

        try keychain.write("VENICE_INFERENCE_KEY_test", for: .veniceAPIKey)

        // A plain request: Venice's id, its key, its system prompt off; the answer's cost is booked.
        let (plain, plainBody) = try await post("/v1/chat/completions", #"{"model":"uncensored","messages":[{"role":"user","content":"Hi"}]}"#)
        #expect(plain == 200 && plainBody.contains("Hallo"))
        #expect(await log.last()?["model"] as? String == "venice-uncensored-1-2")
        #expect(await log.authorizations.last == "Bearer VENICE_INFERENCE_KEY_test")
        #expect(await log.paths.last == "/api/v1/chat/completions")
        #expect((await log.last()?["venice_parameters"] as? [String: Any])?["include_venice_system_prompt"] as? Bool == false)
        try await Task.sleep(for: .milliseconds(200))
        var state = await manager.state()
        let today = PodlightState.dayKey(Date())
        #expect(state.apiTotals(model.id, period: today).requests == 1)
        #expect(state.apiTotals(model.id, period: today).promptTokens == 1200)
        #expect(abs((state.spendByDay[today] ?? 0) - 0.25) < 1e-9, "Venice's own cost.usd")

        // A stream the agent asked no usage for: Podlight asks, counts, and drops that chunk.
        let (stream, streamBody) = try await post("/v1/chat/completions", #"{"model":"uncensored","stream":true,"messages":[{"role":"user","content":"Hi"}]}"#)
        #expect(stream == 200 && streamBody.contains(#""content":"Hal""#) && streamBody.contains("[DONE]"))
        #expect(!streamBody.contains("prompt_tokens"), "the usage chunk is not passed to an agent that did not ask")
        try await Task.sleep(for: .milliseconds(200))
        state = await manager.state()
        let expected = 0.25 + offer.pricing.input + offer.pricing.output * 0.5
        #expect(state.apiTotals(model.id, period: today).requests == 2)
        #expect(abs((state.spendByDay[today] ?? 0) - expected) < 1e-9, "1M in and 0.5M out at the stored prices")

        // An agent that asks for usage gets it.
        let (_, withUsage) = try await post("/v1/chat/completions", #"{"model":"uncensored","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"Hi"}]}"#)
        #expect(withUsage.contains("prompt_tokens"))

        // Venice's error becomes Podlight's, in each API's shape.
        let (broke, brokeBody) = try await post("/v1/chat/completions", #"{"model":"uncensored","messages":[{"role":"user","content":"broke"}]}"#)
        #expect(broke == 402 && brokeBody.contains("provider_balance"))

        // Legacy completions: Venice does not serve them.
        let (legacy, legacyBody) = try await post("/v1/completions", #"{"model":"uncensored","prompt":"Hi"}"#)
        #expect(legacy == 404 && legacyBody.contains("unsupported_endpoint"))

        // At the spending limit API models are refused like pods.
        _ = try await manager.store.update { $0.settings.dailyLimitUsd = 0.01 }
        let before = await log.count
        let (limited, limitedBody) = try await post("/v1/chat/completions", #"{"model":"uncensored","messages":[{"role":"user","content":"Hi"}]}"#)
        #expect(limited == 429 && limitedBody.contains("spend_limit"))
        #expect(await log.count == before)

        // Starting or ticking never asks RunPod about an API model.
        try await manager.start(model.id, until: nil)
        #expect(await manager.state().run(model.id).podId == nil)
    }
}

@Suite("Usage meter")
struct UsageMeterTests {
    @Test func dropsTheUsageChunkOnlyWhenAsked() {
        let chunk = Data(#"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#.utf8 + [10])
        let text = Data(#"data: {"choices":[{"delta":{"content":"x"}}]}"#.utf8 + [10])
        var dropping = UsageMeter(dropUsageChunk: true)
        #expect(dropping.pass(text) == text)
        #expect(dropping.pass(chunk) == nil)
        #expect(dropping.finish() == APIUsage(promptTokens: 3, completionTokens: 2))
        var keeping = UsageMeter(dropUsageChunk: false)
        #expect(keeping.pass(chunk) == chunk)
    }

    @Test func readsAPlainAnswerAtTheEnd() {
        var meter = UsageMeter(dropUsageChunk: false)
        for line in [#"{"choices":[],"#, #""usage":{"prompt_tokens":5,"completion_tokens":1},"cost":{"usd":0.5}}"#] {
            #expect(meter.pass(Data(line.utf8)) != nil)
        }
        #expect(meter.finish() == APIUsage(promptTokens: 5, completionTokens: 1, providerCostUsd: 0.5))
    }
}
