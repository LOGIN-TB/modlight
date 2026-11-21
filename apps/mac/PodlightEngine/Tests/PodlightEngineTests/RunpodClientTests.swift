import Foundation
import Testing
@testable import PodlightEngine

// Replays responses captured from RunPod on 2026-11-20 (IDs and values replaced where private).
// No network, no cost; the real API is exercised separately and only with the owner's go-ahead.

actor FakeTransport: HTTPTransport {
    enum Reply { case status(Int, String), failure(URLError) }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.cannotConnectToHost) }
        switch replies.removeFirst() {
        case .status(let code, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        case .failure(let error):
            throw error
        }
    }
}

enum Fixture {
    /// Shape of a real create/get response (spike pod, since deleted), private values replaced.
    static func pod(id: String = "abc123podid", gpu: String = "Tesla V100-SXM2-16GB", status: String = "RUNNING",
                    dataCenterId: String? = nil) -> String {
        """
        {"actions":["stop","restart","terminate"],"args":null,"cloud":"COMMUNITY","cost":0.23,
         "createdAt":"2026-11-20T18:39:25.101Z","cudaVersion":"12.4","dataCenterId":\(dataCenterId.map { "\"\($0)\"" } ?? "null"),"disk":5,
         "env":{"EXAMPLE":"value"},"globalNetworking":{"enabled":false},
         "gpu":{"count":1,"id":"\(gpu)","memory":62,"vcpuCount":6},"id":"\(id)",
         "image":"python:3.12-slim","locked":false,"mounts":{},"name":"podlight-test","ports":["8000/http"],
         "registry":null,"runtime":null,"ssh":{"direct":null,"proxy":{"host":"ssh.runpod.io","port":22}},
         "startedAt":"2026-11-20T18:39:25.090Z","status":"\(status)","tags":[],"template":null}
        """
    }

    /// Verbatim body RunPod returned when a card was taken.
    static let noCapacity = #"{"detail":"There are no longer any instances available with the requested specifications. Please refresh and try again.","status":400,"title":"Bad Request"}"#

    /// Real catalog entries, captured 2026-11-20.
    static let catalog = #"""
    {"gpus": [
     {"availability": "NONE", "community": true, "id": "NVIDIA L40S", "manufacturer": "NVIDIA", "maxCount": {"community": 8, "secure": 8}, "memory": 48, "name": "L40S", "pool": "ADA_48_PRO", "price": {"community": 0.79, "secure": 1.09, "serverless": 1.89}, "secure": true},
     {"availability": "LOW", "community": false, "id": "NVIDIA RTX 2000 Ada Generation", "manufacturer": "NVIDIA", "maxCount": {"community": 0, "secure": 8}, "memory": 16, "minRam": 31, "minVcpuCount": 8, "name": "RTX 2000 Ada", "pool": "AMPERE_16", "price": {"community": 0.5, "secure": 0.24, "serverless": 0.58}, "secure": true},
     {"availability": "LOW", "community": true, "id": "Tesla V100-SXM2-16GB", "manufacturer": "NVIDIA", "maxCount": {"community": 8, "secure": 0}, "memory": 16, "name": "V100 SXM2", "pool": null, "price": {"community": 0.23, "secure": 0}, "secure": false},
     {"availability": "SOMETHING_NEW", "community": true, "id": "Future GPU", "manufacturer": "NVIDIA", "memory": 96, "name": "Future", "price": {"community": 2.0}, "secure": false}
    ]}
    """#

    static let base = CreatePodRequest(name: "podlight-test", image: "python:3.12-slim", cloud: .secure,
                                       gpu: .init(id: "placeholder"), disk: 5, ports: ["8000/http"],
                                       env: ["LAUNCHER_API_KEY": "gateway-secret"])
}

@Suite("RunPod client")
struct RunpodClientTests {
    @Test func createPodSendsWhatRunPodExpects() async throws {
        let transport = FakeTransport([.status(201, Fixture.pod())])
        let client = RunpodClient(apiKey: "test-key", transport: transport)

        var request = Fixture.base
        request.gpu.id = "Tesla V100-SXM2-16GB"
        request.cloud = .community
        let pod = try await client.createPod(request)

        #expect(pod.id == "abc123podid")
        #expect(pod.status == .running)
        #expect(pod.cost == 0.23)
        #expect(pod.gpu?.id == "Tesla V100-SXM2-16GB")

        let sent = try #require(await transport.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://api.runpod.io/v2/pods")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(sent.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["cloud"] as? String == "COMMUNITY")
        #expect((json["gpu"] as? [String: Any])?["id"] as? String == "Tesla V100-SXM2-16GB")
        #expect((json["env"] as? [String: String])?["LAUNCHER_API_KEY"] == "gateway-secret")
    }

    @Test func fallsBackWhenACardIsTaken() async throws {
        let transport = FakeTransport([
            .status(400, Fixture.noCapacity),
            .status(400, Fixture.noCapacity),
            .status(201, Fixture.pod(gpu: "NVIDIA RTX A2000")),
        ])
        let client = RunpodClient(apiKey: "k", transport: transport)
        let choices = [
            GPUChoice(gpuId: "NVIDIA RTX 2000 Ada Generation", cloud: .secure),
            GPUChoice(gpuId: "NVIDIA GeForce RTX 3090", cloud: .community),
            GPUChoice(gpuId: "NVIDIA RTX A2000", cloud: .community),
        ]

        let created = try await client.createPod(Fixture.base, tryingInOrder: choices)

        #expect(created.choice == choices[2])
        #expect(created.usedFallback)
        #expect(created.attempts.map(\.outcome) == [.noCapacity, .noCapacity, .created])
        // Each attempt asked for its own card in its own cloud.
        let sentCards = try await transport.requests.map { request -> String in
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            return "\(json["cloud"]!)|\((json["gpu"] as! [String: Any])["id"]!)"
        }
        #expect(sentCards == ["SECURE|NVIDIA RTX 2000 Ada Generation", "COMMUNITY|NVIDIA GeForce RTX 3090",
                              "COMMUNITY|NVIDIA RTX A2000"])
    }

    @Test func aFallbackWithFewerCardsTellsTheEngineSo() async throws {
        // Seen live: two cards were asked for, a one-card fallback was created, and vLLM exited with
        // "World size (2) is larger than the number of available GPUs (1)".
        let transport = FakeTransport([.status(400, Fixture.noCapacity), .status(201, Fixture.pod())])
        let client = RunpodClient(apiKey: "k", transport: transport)
        var base = Fixture.base
        base.env["PODLIGHT_TP"] = "2"
        _ = try await client.createPod(base, tryingInOrder: [
            GPUChoice(gpuId: "NVIDIA RTX 3070", cloud: .community, count: 2),
            GPUChoice(gpuId: "NVIDIA A40", cloud: .secure, count: 1),
        ])
        let bodies = try await transport.requests.map { try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any] }
        #expect((bodies[0]["env"] as? [String: String])?["PODLIGHT_TP"] == "2")
        #expect((bodies[1]["env"] as? [String: String])?["PODLIGHT_TP"] == "1")
        #expect((bodies[1]["gpu"] as? [String: Any])?["count"] as? Int == 1)
    }

    @Test func stopsAtTheFirstErrorThatIsNotCapacity() async throws {
        let transport = FakeTransport([.status(401, #"{"detail":"unauthorized"}"#), .status(201, Fixture.pod())])
        let client = RunpodClient(apiKey: "k", transport: transport)

        await #expect(throws: RunpodError.self) {
            _ = try await client.createPod(Fixture.base, tryingInOrder: [
                GPUChoice(gpuId: "A", cloud: .secure), GPUChoice(gpuId: "B", cloud: .secure),
            ])
        }
        // A bad key fails the same way on every card; trying more would only add noise.
        #expect(await transport.requests.count == 1)
    }

    @Test func reportsEveryAttemptWhenNoCardIsLeft() async throws {
        let transport = FakeTransport([.status(400, Fixture.noCapacity), .status(400, Fixture.noCapacity)])
        let client = RunpodClient(apiKey: "k", transport: transport)
        let choices = [GPUChoice(gpuId: "A", cloud: .secure), GPUChoice(gpuId: "B", cloud: .community)]

        do {
            _ = try await client.createPod(Fixture.base, tryingInOrder: choices)
            Issue.record("expected NoCapacityError")
        } catch let error as NoCapacityError {
            #expect(error.attempts == [
                CreationAttempt(choice: choices[0], outcome: .noCapacity),
                CreationAttempt(choice: choices[1], outcome: .noCapacity),
            ])
        }
    }

    @Test func skipsCardsTheCatalogHasNoneOf() async throws {
        let catalog = try RunpodClient.decoder.decode(RunpodGPUCatalog.self, from: Data(Fixture.catalog.utf8)).gpus
        let transport = FakeTransport([.status(201, Fixture.pod(gpu: "Tesla V100-SXM2-16GB"))])
        let client = RunpodClient(apiKey: "k", transport: transport)

        let created = try await client.createPod(Fixture.base, tryingInOrder: [
            GPUChoice(gpuId: "NVIDIA L40S", cloud: .secure),          // NONE in the catalog
            GPUChoice(gpuId: "Tesla V100-SXM2-16GB", cloud: .community),
        ], catalog: catalog)

        #expect(created.attempts.map(\.outcome) == [.skippedUnavailable, .created])
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [
        (200, RunpodKeyCheck.valid),
        (401, RunpodKeyCheck.invalid),
        (403, RunpodKeyCheck.missingPermission),
        (500, RunpodKeyCheck.unreachable("RunPod answered 500")),
    ])
    func checksAKeyWithoutChangingAnything(status: Int, expected: RunpodKeyCheck) async throws {
        let transport = FakeTransport([.status(status, status == 200 ? #"{"pods":[]}"# : "{}")])
        let result = await RunpodClient(apiKey: "k", transport: transport).checkKey()
        #expect(result == expected)
        let sent = try #require(await transport.requests.first)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.absoluteString == "https://api.runpod.io/v2/pods?limit=1")
    }

    @Test func aKeyCheckWithoutNetworkSaysSoInsteadOfCallingTheKeyWrong() async {
        let transport = FakeTransport([.failure(URLError(.notConnectedToInternet))])
        let result = await RunpodClient(apiKey: "k", transport: transport).checkKey()
        guard case .unreachable = result else {
            Issue.record("expected .unreachable, got \(result)")
            return
        }
    }

    @Test func stopAndDeleteUseTheRightCalls() async throws {
        let transport = FakeTransport([.status(200, Fixture.pod(status: "EXITED")), .status(204, "")])
        let client = RunpodClient(apiKey: "k", transport: transport)

        let stopped = try await client.perform(.stop, onPod: "abc123podid")
        try await client.deletePod(id: "abc123podid")

        #expect(stopped.status == .exited)
        let sent = await transport.requests
        #expect(sent.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(sent.map { $0.url!.path } == ["/v2/pods/abc123podid/action", "/v2/pods/abc123podid"])
        let action = try JSONSerialization.jsonObject(with: sent[0].httpBody!) as? [String: String]
        #expect(action == ["action": "stop"])
    }

    @Test func recognisesTheErrorsThatNeedAnotherCardOrANewPod() {
        #expect(RunpodError(status: 400, operation: "createPod", body: Fixture.noCapacity).isCapacityExhausted)
        let hostGone = RunpodError(status: 400, operation: "podAction",
                                   body: "There are not enough free GPUs on the host machine to start this pod.")
        #expect(hostGone.isHostGPUUnavailable)
        #expect(!hostGone.isCapacityExhausted)
    }
}

@Suite("GPU catalog")
struct GPUCatalogTests {
    let gpus: [RunpodGPUType]

    init() throws {
        gpus = try RunpodClient.decoder.decode(RunpodGPUCatalog.self, from: Data(Fixture.catalog.utf8)).gpus
    }

    func gpu(_ id: String) throws -> RunpodGPUType { try #require(gpus.first { $0.id == id }) }

    @Test func pricesExistOnlyWhereTheCardIsOffered() throws {
        let ada = try gpu("NVIDIA RTX 2000 Ada Generation")
        #expect(ada.pricePerHour(in: .secure) == 0.24)
        // RunPod lists a community price but marks the card as not offered there.
        #expect(ada.pricePerHour(in: .community) == nil)

        let v100 = try gpu("Tesla V100-SXM2-16GB")
        #expect(v100.pricePerHour(in: .community) == 0.23)
        // RunPod reports 0 for "not offered".
        #expect(v100.pricePerHour(in: .secure) == nil)
    }

    @Test func availabilityIsReadButNeverTrusted() throws {
        #expect(try gpu("NVIDIA L40S").availability == RunpodGPUType.Availability.none)
        #expect(try gpu("Tesla V100-SXM2-16GB").availability?.mayBeAvailable == true)
        // A value RunPod adds later must not break decoding the whole catalog.
        #expect(try gpu("Future GPU").availability == .other("SOMETHING_NEW"))
    }
}

@Suite("Keychain", .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                            "uses the login keychain; runs on a developer Mac, not on CI runners"))
struct KeychainStoreTests {
    @Test func roundTripTrimsAndDeletes() throws {
        let store = KeychainStore(service: "app.podlight.tests.\(UUID().uuidString)")
        defer { try? store.delete(.runpodAPIKey) }

        #expect(try store.read(.runpodAPIKey) == nil)
        try store.write("  first-value\n", for: .runpodAPIKey)
        #expect(try store.read(.runpodAPIKey) == "first-value")
        try store.write("second-value", for: .runpodAPIKey)
        #expect(try store.read(.runpodAPIKey) == "second-value")
        #expect(store.contains(.runpodAPIKey))
        #expect(!store.contains(.huggingFaceToken))
        try store.delete(.runpodAPIKey)
        #expect(try store.read(.runpodAPIKey) == nil)
    }
}
