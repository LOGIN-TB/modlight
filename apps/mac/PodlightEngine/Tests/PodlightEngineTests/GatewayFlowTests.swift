import Foundation
import Hummingbird
import NIOCore
import Testing
@testable import PodlightEngine

// The whole local flow without RunPod: an agent calls the gateway, Podlight wakes the pod through a
// fake RunPod API, waits for a fake vLLM to answer, streams the reply through, and later stops the
// pod at its end. Needs the login keychain, so it runs on a developer Mac and not on CI.

/// Plays RunPod's API and the pod watchdog; everything else goes to the network.
actor FakeRunPod: HTTPTransport {
    var podStatus = "RUNNING"
    var created = 0
    var actions: [String] = []
    var heartbeats: [String] = []
    let catalog: String

    init(catalog: String) { self.catalog = catalog }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func reply(_ code: Int, _ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        if url.host == "127.0.0.1" {
            // Watchdog heartbeat and the engine readiness probe.
            if url.path.hasSuffix("/heartbeat") {
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data("{}".utf8)) as? [String: Any]
                heartbeats.append("\(body?["deadline"] ?? "null")")
            }
            return reply(200, "{}")
        }
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "/v2/catalog/gpus"):
            return reply(200, catalog)
        case ("POST", "/v2/pods"):
            created += 1
            podStatus = "RUNNING"
            return reply(201, Fixture.pod(id: "fakepod", gpu: "NVIDIA L40S", status: "RUNNING"))
        case ("GET", "/v2/pods/fakepod"):
            return reply(200, Fixture.pod(id: "fakepod", gpu: "NVIDIA L40S", status: podStatus))
        case ("POST", "/v2/pods/fakepod/action"):
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
            let action = body?["action"] ?? "?"
            actions.append(action)
            podStatus = action == "stop" ? "EXITED" : "RUNNING"
            return reply(200, Fixture.pod(id: "fakepod", gpu: "NVIDIA L40S", status: podStatus))
        default:
            return reply(404, #"{"detail":"not found"}"#)
        }
    }
}

/// A stand-in for vLLM that streams three chunks, and checks the pod key.
private func runFakeEngine(port: Int, podKey: @escaping @Sendable () -> String?) async throws {
    let router = Router()
    router.post("/v1/chat/completions") { request, _ -> Response in
        guard request.headers[.authorization] == "Bearer \(podKey() ?? "")" else {
            return Response(status: .unauthorized)
        }
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        return Response(status: .ok, headers: headers, body: ResponseBody { writer in
            for word in ["Hal", "lo", "!"] {
                let chunk = #"data: {"choices":[{"index":0,"delta":{"content":"\#(word)"}}]}"# + "\n\n"
                try await writer.write(ByteBuffer(string: chunk))
            }
            try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
            try await writer.finish(nil)
        })
    }
    try await Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: port))).run()
}

private func waitForServer(port: Int) async throws {
    for _ in 0..<50 {
        if (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)) != nil { return }
        try await Task.sleep(for: .milliseconds(100))
    }
}

@Suite("Gateway flow", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                                            "uses the login keychain; runs on a developer Mac"))
struct GatewayFlowTests {
    @Test func wakesStreamsAndStopsAtTheEnd() async throws {
        let keychain = KeychainStore(service: "app.podlight.tests.\(UUID().uuidString)")
        defer { for item in [KeychainStore.Item.runpodAPIKey, .gatewayKey] { try? keychain.delete(item) } }
        try keychain.write("rp-test", for: .runpodAPIKey)
        try keychain.write("gw-test", for: .gatewayKey)

        let enginePort = Int.random(in: 41_000...44_000)
        let gatewayPort = enginePort + 1000
        let fake = FakeRunPod(catalog: #"{"gpus":[{"id":"NVIDIA L40S","name":"L40S","manufacturer":"NVIDIA","memory":48,"secure":true,"community":true,"price":{"secure":0.86,"community":0.79},"availability":"LOW"}]}"#)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let manager = PodManager(store: StateStore(url: stateURL), keychain: keychain, transport: fake,
                                 podURL: { _, port in URL(string: "http://127.0.0.1:\(enginePort)\(port == PodPlan.watchdogPort ? "/wd" : "")")! })

        let m = PodlightModel(name: "qwen-test", repoId: "Org/Qwen-Test-AWQ", format: .awq, weightBytes: 19e9,
                              nativeContextTokens: 262_144, toolCallParser: nil, reasoningParser: nil, contextTokens: 32_768)
        try await manager.save(m)
        let podKey: @Sendable () -> String? = { try? keychain.read(.podKey(m.id)) }

        let engine = Task { try await runFakeEngine(port: enginePort, podKey: podKey) }
        let gateway = Task { try await LocalGateway(port: gatewayPort, manager: manager, key: { "gw-test" }).run() }
        defer { engine.cancel(); gateway.cancel() }
        try await waitForServer(port: gatewayPort)
        let base = "http://127.0.0.1:\(gatewayPort)"

        // Without the key: refused.
        var anonymous = URLRequest(url: URL(string: "\(base)/v1/models")!)
        anonymous.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, refused) = try await URLSession.shared.data(for: anonymous)
        #expect((refused as? HTTPURLResponse)?.statusCode == 401)

        // With the key: the model is listed under its served name.
        var list = URLRequest(url: URL(string: "\(base)/v1/models")!)
        list.setValue("Bearer gw-test", forHTTPHeaderField: "Authorization")
        let (listData, _) = try await URLSession.shared.data(for: list)
        #expect(String(decoding: listData, as: UTF8.self).contains(#""id":"qwen-test""#))

        // A chat request wakes the pod, waits for the engine, and streams the answer through.
        var chat = URLRequest(url: URL(string: "\(base)/v1/chat/completions")!)
        chat.httpMethod = "POST"
        chat.setValue("Bearer gw-test", forHTTPHeaderField: "Authorization")
        chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
        chat.httpBody = Data(#"{"model":"qwen-test","stream":true,"messages":[{"role":"user","content":"Hi"}]}"#.utf8)
        let (chatData, chatResponse) = try await URLSession.shared.data(for: chat)
        let text = String(decoding: chatData, as: UTF8.self)
        #expect((chatResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(text.contains(#""content":"Hal""#) && text.contains("data: [DONE]"))
        #expect(await fake.created == 1)

        var run = await manager.state().run(m.id)
        #expect(run.phase == .ready)
        #expect(run.podId == "fakepod")
        #expect(run.lastRequestAt != nil)
        #expect(await fake.heartbeats.isEmpty == false)

        // "Läuft bis" passes: the next tick stops the pod, and says why.
        try await manager.extend(m.id, until: Date().addingTimeInterval(-1))
        await manager.tick()
        run = await manager.state().run(m.id)
        #expect(await fake.actions == ["stop"])
        #expect(run.phase == .stopped)
        #expect(run.lastReason == "run-until")
        #expect(await manager.state().spendByDay.values.reduce(0, +) >= 0)

        // At the spending limit a request cannot wake it again.
        _ = try await manager.store.update { $0.settings.dailyLimitUsd = 0 }
        let (limitData, limitResponse) = try await URLSession.shared.data(for: chat)
        #expect((limitResponse as? HTTPURLResponse)?.statusCode == 429)
        #expect(String(decoding: limitData, as: UTF8.self).contains("spend_limit"))
        #expect(await fake.actions == ["stop"])
    }
}
