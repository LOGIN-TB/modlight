import Foundation
import Testing
@testable import PodlightEngine

@Suite("Server address")
struct ServerAddressTests {
    @Test func aBareHostBecomesHttps() throws {
        #expect(try ServerAddress.normalize("podlight.example.com").absoluteString == "https://podlight.example.com")
        #expect(try ServerAddress.normalize(" https://podlight.example.com/v1/ ").absoluteString == "https://podlight.example.com")
    }

    @Test func plainHttpOnlyOnThisMacAndPrivateNetworks() throws {
        #expect(throws: ServerAddress.Problem.insecure) { try ServerAddress.normalize("http://podlight.example.com") }
        #expect(throws: ServerAddress.Problem.insecure) { try ServerAddress.normalize("http://8.8.8.8:8080") }
        for ok in ["http://localhost:8080", "http://127.0.0.1:8080", "http://192.168.1.20:8080", "http://10.0.0.5",
                   "http://172.20.1.1", "http://nas.local:8080", "http://[::1]:8080"] {
            #expect(throws: Never.self) { try ServerAddress.normalize(ok) }
        }
        #expect(throws: ServerAddress.Problem.insecure) { try ServerAddress.normalize("http://172.32.0.1") }
        #expect(throws: ServerAddress.Problem.invalid) { try ServerAddress.normalize("ftp://x") }
        #expect(throws: ServerAddress.Problem.invalid) { try ServerAddress.normalize("") }
    }

    @Test func aStateFileFromBefore04StillLoads() throws {
        let old = #"{"models":[],"runs":[],"settings":{"dailyLimitUsd":null},"spendByDay":{"2026-11-20":1.5}}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let state = try d.decode(PodlightState.self, from: Data(old.utf8))
        #expect(state.servers.isEmpty)
        #expect(state.settings.dailyLimitUsd == nil)
        #expect(state.spendByDay["2026-11-20"] == 1.5)
    }
}

/// The app's client against the real server (server/src, Node 24), started on a free port with a
/// throwaway data folder. Skipped when Node or the server's dependencies are missing, and in CI
/// (the server has its own job there).
@Suite("Server client against the Node server", .serialized,
       .enabled(if: NodeServer.available && ProcessInfo.processInfo.environment["CI"] == nil))
struct ServerClientTests {
    @Test func pairsReadsStateAndManagesModelsAndKeys() async throws {
        let server = try await NodeServer.start()
        defer { server.stop() }

        let anonymous = ServerClient(baseURL: server.url, token: nil)
        let health = try await anonymous.health()
        #expect(health.name == "Podlight")
        #expect(health.paired == false)

        await #expect(throws: ServerError.self) { try await anonymous.pair(code: "WRONG-CODE-0000", deviceName: "Test") }
        let paired = try await anonymous.pair(code: NodeServer.code, deviceName: "Test Mac")
        #expect(paired.token.hasPrefix("pld-"))
        let client = ServerClient(baseURL: server.url, token: paired.token)

        let empty = try await client.state()
        #expect(empty.models.isEmpty)
        #expect(empty.settings.hasRunpodKey == false)
        #expect(empty.settings.dailyLimitUsd == 10)

        var change = ServerSettingsChange()
        change.dailyLimit(nil)
        change.hosting(HostingPolicy(region: .eu, secureOnly: true))
        change.runpodApiKey("rp-not-real")
        let settings = try await client.update(change)
        #expect(settings.dailyLimitUsd == nil)
        #expect(settings.hostingRegion == .eu)
        #expect(settings.hasRunpodKey)

        var model = PodlightModel(name: "coder", repoId: "Qwen/Qwen3-8B-AWQ", format: .awq, weightBytes: 6e9,
                                  nativeContextTokens: 40_960, toolCallParser: "hermes", reasoningParser: nil, contextTokens: 16_384,
                                  preferredGPU: GPUChoice(gpuId: "NVIDIA L40S", cloud: .secure, count: 2),
                                  kvProfile: KVProfile(bytesPerToken: 65_536, attentionHeads: 32, hybrid: false))
        model.hosting = HostingPolicy(region: .euEEA, secureOnly: true)
        // ISO 8601 dates carry whole seconds, here as in state.json.
        model.createdAt = Date(timeIntervalSince1970: 1_763_683_200)
        try await client.save(model)
        let state = try await client.state()
        #expect(state.models == [model], "the model comes back exactly as the app sent it")
        #expect(state.run(model.id).phase == .stopped)

        var clash = model
        clash.id = UUID()
        await #expect(throws: ServerError.refused(status: 409, message: "A model named \"coder\" already exists on this server.", code: "name_taken")) {
            try await client.save(clash)
        }

        let key = try await client.createClientToken(name: "OpenCode", models: [model.id])
        #expect(key.token?.hasPrefix("pl-") == true)
        #expect(key.models == [model.id])
        try await client.setModels(ofClientToken: key.id, to: nil)
        #expect(try await client.clientTokens().first?.models == nil)
        try await client.revokeClientToken(key.id)
        try await client.deleteClientToken(key.id)
        #expect(try await client.clientTokens().isEmpty)

        let code = try await client.newPairingCode()
        #expect(code.code.count == 14)
        #expect(try await client.devices().contains { $0.current == true })

        try await client.remove(model.id)
        #expect(try await client.state().models.isEmpty)

        await #expect(throws: ServerError.notPaired) { try await ServerClient(baseURL: server.url, token: "pld-nope").state() }
    }
}

/// Runs `node server/src/index.ts` for a test.
final class NodeServer: @unchecked Sendable {
    static let code = "TEST-CODE-2345"
    static let repo = Spec.root.deletingLastPathComponent()
    static var node: String? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var available: Bool {
        node != nil && FileManager.default.fileExists(atPath: repo.appendingPathComponent("server/node_modules/fastify").path)
    }

    let process: Process
    let url: URL
    let dataDir: URL

    private init(process: Process, url: URL, dataDir: URL) {
        self.process = process
        self.url = url
        self.dataDir = dataDir
    }

    static func start() async throws -> NodeServer {
        let port = Int.random(in: 20_000...40_000)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-server-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node!)
        process.arguments = ["--disable-warning=ExperimentalWarning", "src/index.ts"]
        process.currentDirectoryURL = repo.appendingPathComponent("server")
        process.environment = ["PATH": "/usr/bin:/bin", "PORT": String(port), "HOST": "127.0.0.1", "DATA_DIR": data.path,
                               "PAIRING_CODE": code, "LOG_LEVEL": "warn"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let server = NodeServer(process: process, url: URL(string: "http://127.0.0.1:\(port)")!, dataDir: data)
        for _ in 0..<50 {
            if (try? await ServerClient(baseURL: server.url, token: nil).health()) != nil { return server }
            try await Task.sleep(for: .milliseconds(100))
        }
        server.stop()
        throw ServerError.unreachable("the Node server did not start")
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: dataDir)
    }
}

@Suite("Pod telemetry")
struct TelemetryDecodingTests {
    @Test("a snapshot carries telemetry per model, and a broken sample does not cost the snapshot")
    func snapshotTelemetry() throws {
        let id = UUID()
        func json(_ telemetry: String) -> Data {
            Data(#"{"version":"0.5.0","models":[],"runs":{},"settings":{"dailyLimitUsd":10,"monthlyLimitUsd":100,"heartbeatMinutes":15,"wakeWaitSeconds":600,"deleteStoppedAfterDays":3,"wakeOnRequest":true,"hostingRegion":"anywhere","secureCloudOnly":false,"timezone":"UTC","hasRunpodKey":true,"hasHuggingFaceToken":false},"spendByDay":{},"spend":{"todayUsd":0,"monthUsd":0,"dailyLimitUsd":10,"monthlyLimitUsd":100},"costPerHour":0,"telemetry":\#(telemetry)}"#.utf8)
        }
        let good = try ServerClient.decoder.decode(ServerSnapshot.self, from: json(#"{"\#(id.uuidString.lowercased())":{"time":1800000000,"gpus":[{"utilPercent":87,"memoryUsedBytes":4.5e10,"memoryTotalBytes":4.8e10}],"engine":{"generationTokensPerSecond":58}}}"#))
        #expect(good.telemetry[id]?.averageGPUPercent == 87)
        #expect(good.telemetry[id]?.gpuMemoryFraction == 0.9375)
        #expect(good.telemetry[id]?.engine?.generationTokensPerSecond == 58)
        let broken = try ServerClient.decoder.decode(ServerSnapshot.self, from: json(#"{"x":{"time":"soon"}}"#))
        #expect(broken.telemetry.isEmpty)
    }
}
