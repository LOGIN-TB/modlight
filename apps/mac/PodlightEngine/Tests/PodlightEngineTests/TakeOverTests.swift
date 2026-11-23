import Foundation
import Testing
@testable import PodlightEngine

@Suite("Pod owner in the pod name")
struct PodOwnerTests {
    @Test func tagsAreShortSlugsWithARandomTail() {
        let tag = PodOwner.makeTag(hostName: "Holgers MacBook Pro (2)")
        #expect(tag.hasPrefix("holgers-macbook-pro-"))
        #expect(tag.range(of: #"^[a-z0-9-]+-[0-9a-f]{4}$"#, options: .regularExpression) != nil)
        #expect(PodOwner.displayName(of: tag) == "holgers-macbook-pro")
        #expect(PodOwner.makeTag(hostName: "Ünïcode ✨").hasPrefix("n-code-") || PodOwner.makeTag(hostName: "Ünïcode ✨").range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil)
        #expect(PodOwner.makeTag(hostName: "").hasPrefix("mac-"))
    }

    @Test func namesCarryTheOwnerAndStayWithinRunPodsLimit() {
        #expect(PodOwner.podName(model: "coder", owner: "mac-a-1234") == "podlight-coder@mac-a-1234")
        #expect(PodOwner.podName(model: "coder", owner: nil) == "podlight-coder")
        let long = PodOwner.podName(model: String(repeating: "x", count: 63), owner: "holgers-macbook-pro-1a2b")
        #expect(long.count <= 60)
        #expect(PodOwner.owner(ofPodName: long) == "holgers-macbook-pro-1a2b")
    }

    @Test func readsTheOwnerBackAndTellsMacPodsApart() {
        #expect(PodOwner.owner(ofPodName: "podlight-qwen3.8_b-x@mac-b-91ab") == "mac-b-91ab")
        #expect(PodOwner.owner(ofPodName: "podlight-qwen3.8_b-x") == nil, "a pod from before 0.6")
        #expect(PodOwner.owner(ofPodName: "comfy@box") == nil, "not Podlight's")
        #expect(PodOwner.isMacPod("podlight-coder@mac-a-1234"))
        #expect(!PodOwner.isMacPod("podlight-srv-coder"), "a server's pod")
        #expect(!PodOwner.isMacPod("Sage100-db"))
    }

    @Test func aForeignPodIsReadFromItsEnvironment() throws {
        let pod = try RunpodClient.decoder.decode(RunpodPod.self, from: Data(TakeOverFixture.podJSON(
            id: "p1", name: "podlight-coder@mac-a-1234", status: "EXITED").utf8))
        let foreign = try #require(ForeignPod(pod))
        #expect(foreign.servedName == "coder" && foreign.repoId == "Org/Coder-GGUF" && foreign.engine == .llamaCpp)
        #expect(foreign.quant == "Q4_K_M" && foreign.contextTokens == 16_384 && foreign.owner == "mac-a-1234")
        #expect(foreign.persistentGB == 18 && foreign.containerGB == 30 && foreign.podKey == "pod-key-a")
        #expect(abs(foreign.stoppedPerHour - 18 * 0.2 / 730) < 1e-9)

        let info = ModelInfo(repoId: "Org/Coder-GGUF", access: .open, gated: false, format: .gguf, weightBytes: 5e9,
                             nativeContextTokens: 131_072, license: nil, toolCallParser: nil, reasoningParser: nil)
        let model = foreign.model(from: info)
        #expect(model.name == "coder" && model.keepDisk && model.contextTokens == 16_384 && model.concurrency == 2)
        #expect(model.preferredGPU == GPUChoice(gpuId: "NVIDIA RTX A4000", cloud: .community, count: 1))

        // Not Podlight's: no pod key in its environment, or a server's pod.
        let other = try RunpodClient.decoder.decode(RunpodPod.self, from: Data(Fixture.pod().utf8))
        #expect(ForeignPod(other) == nil)
        let server = try RunpodClient.decoder.decode(RunpodPod.self, from: Data(TakeOverFixture.podJSON(
            id: "p2", name: "podlight-srv-coder", status: "RUNNING").utf8))
        #expect(ForeignPod(server) == nil)
    }
}

@Suite("Reading the pod list")
struct PodListReadingTests {
    @Test func anOddPodOrAnUnknownStatusDoesNotHideTheOthers() throws {
        let json = """
        {"pods":[\(TakeOverFixture.podJSON(id: "p1", name: "podlight-coder@mac-a-1234", status: "RUNNING")),
                 {"id":"odd","name":"someone-else","status":"RUNNING","gpu":"not an object"},
                 \(TakeOverFixture.podJSON(id: "p2", name: "podlight-other@mac-a-1234", status: "CREATED")),
                 \(TakeOverFixture.podJSON(id: "p3", name: "podlight-third@mac-a-1234", status: "PAUSED"))],
         "pagination":{"hasNextPage":false,"nextCursor":null}}
        """
        let list = try RunpodClient.decoder.decode(RunpodPodList.self, from: Data(json.utf8))
        #expect(list.pods.map(\.id) == ["p1", "p2", "p3"], "the odd pod is skipped, not the list")
        #expect(list.pods.map(\.status) == [.running, .provisioning, .exited])
    }
}

enum TakeOverFixture {
    static func podJSON(id: String, name: String, status: String, key: String = "pod-key-a") -> String {
        """
        {"id":"\(id)","name":"\(name)","status":"\(status)","cloud":"COMMUNITY","cost":0.17,"disk":30,
         "gpu":{"id":"NVIDIA RTX A4000","count":1},"mounts":{"persistent":{"size":18,"path":"/workspace"}},
         "startedAt":"2026-11-23T09:00:00.000Z","dataCenterId":"EU-RO-1",
         "env":{"PODLIGHT_API_KEY":"\(key)","PODLIGHT_MODEL":"Org/Coder-GGUF","PODLIGHT_SERVED_NAME":"coder",
                "PODLIGHT_ENGINE":"llamacpp","PODLIGHT_QUANT":"Q4_K_M","PODLIGHT_MAX_LEN":"16384","PODLIGHT_PARALLEL":"2",
                "PODLIGHT_TP":"1","HF_HOME":"/workspace/hf"}}
        """
    }
}

/// One RunPod account two Macs share: pods keep their name, status and environment, can be
/// renamed, listed, stopped, resumed and deleted. Heartbeats and engine probes answer 200.
actor SharedRunPod: HTTPTransport {
    struct Pod { var name: String; var status: String; var env: [String: String] }
    struct Template { var name: String; var env: [String: String] }
    var pods: [String: Pod] = [:]
    var templates: [String: Template] = [:]
    var deleted: [String] = []
    /// Resumes refused with "not enough free GPUs on the host machine" before one succeeds.
    var hostBusyFor = 0
    func setHostBusy(_ n: Int) { hostBusyFor = n }
    var renames: [String] = []
    private var next = 0

    func add(id: String, name: String, status: String, env: [String: String]) { pods[id] = Pod(name: name, status: status, env: env) }
    func name(of id: String) -> String? { pods[id]?.name }
    func env(of id: String) -> [String: String]? { pods[id]?.env }
    func setEnv(_ id: String, _ key: String, _ value: String) { pods[id]?.env[key] = value }
    func recordNames() -> [String] { templates.values.map(\.name).sorted() }
    func recordPodId() -> String? { templates.values.first?.env["PODLIGHT_POD_ID"] }

    private func json(_ id: String, _ pod: Pod) -> String {
        let env = String(decoding: try! JSONSerialization.data(withJSONObject: pod.env), as: UTF8.self)
        return """
        {"id":"\(id)","name":"\(pod.name)","status":"\(pod.status)","cloud":"COMMUNITY","cost":0.17,"disk":30,
         "gpu":{"id":"NVIDIA RTX A4000","count":1},"mounts":{"persistent":{"size":18,"path":"/workspace"}},"env":\(env)}
        """
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func reply(_ code: Int, _ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        if url.host == "127.0.0.1" { return reply(200, #"{"engineAlive":true}"#) }
        let parts = url.path.split(separator: "/").map(String.init) // v2, pods, id, action
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        if parts.count >= 2, parts[1] == "templates" {
            func tjson(_ id: String, _ t: Template) -> String {
                let env = String(decoding: try! JSONSerialization.data(withJSONObject: t.env), as: UTF8.self)
                return #"{"id":"\#(id)","name":"\#(t.name)","env":\#(env),"public":false}"#
            }
            switch (request.httpMethod ?? "GET", parts.count) {
            case ("GET", 2):
                return reply(200, #"{"templates":[\#(templates.map { tjson($0.key, $0.value) }.joined(separator: ","))]}"#)
            case ("POST", 2):
                let name = body?["name"] as? String ?? "?"
                if templates.values.contains(where: { $0.name == name }) { return reply(400, #"{"detail":"Template name must be unique."}"#) }
                next += 1
                let id = "tpl\(next)"
                templates[id] = Template(name: name, env: body?["env"] as? [String: String] ?? [:])
                return reply(201, tjson(id, templates[id]!))
            case ("PATCH", 3):
                guard templates[parts[2]] != nil else { return reply(404, #"{"detail":"not found"}"#) }
                if let name = body?["name"] as? String { templates[parts[2]]!.name = name }
                if let env = body?["env"] as? [String: String] { templates[parts[2]]!.env = env }
                return reply(200, tjson(parts[2], templates[parts[2]]!))
            case ("DELETE", 3):
                templates[parts[2]] = nil
                return reply(204, "")
            default:
                return reply(404, #"{"detail":"not found"}"#)
            }
        }
        switch (request.httpMethod ?? "GET", parts.count) {
        case ("GET", 3) where parts[1] == "catalog":
            return reply(200, #"{"gpus":[{"id":"NVIDIA RTX A4000","name":"RTX A4000","manufacturer":"NVIDIA","memory":16,"secure":true,"community":true,"price":{"secure":0.25,"community":0.17},"availability":"HIGH"}]}"#)
        case ("GET", 2):
            return reply(200, #"{"pods":[\#(pods.map { json($0.key, $0.value) }.joined(separator: ","))],"pagination":{"hasNextPage":false}}"#)
        case ("POST", 2):
            next += 1
            let id = "pod\(next)"
            pods[id] = Pod(name: body?["name"] as? String ?? "?", status: "RUNNING", env: body?["env"] as? [String: String] ?? [:])
            return reply(201, json(id, pods[id]!))
        case ("GET", 3):
            guard let pod = pods[parts[2]] else { return reply(404, #"{"detail":"pod not found"}"#) }
            return reply(200, json(parts[2], pod))
        case ("PATCH", 3):
            guard pods[parts[2]] != nil else { return reply(404, #"{"detail":"pod not found"}"#) }
            if let name = body?["name"] as? String { pods[parts[2]]!.name = name; renames.append(name) }
            if let env = body?["env"] as? [String: String] { pods[parts[2]]!.env = env }
            return reply(200, json(parts[2], pods[parts[2]]!))
        case ("DELETE", 3):
            pods[parts[2]] = nil
            deleted.append(parts[2])
            return reply(204, "")
        case ("POST", 4):
            guard pods[parts[2]] != nil else { return reply(404, #"{"detail":"pod not found"}"#) }
            if (body?["action"] as? String) == "start", hostBusyFor > 0 {
                hostBusyFor -= 1
                return reply(400, #"{"detail":"There are not enough free GPUs on the host machine to start this pod.","status":400}"#)
            }
            pods[parts[2]]!.status = (body?["action"] as? String) == "stop" ? "EXITED" : "RUNNING"
            return reply(200, json(parts[2], pods[parts[2]]!))
        default:
            return reply(404, #"{"detail":"not found"}"#)
        }
    }
}

@Suite("Taking a model over from another Mac", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                                                                    "uses the login keychain; runs on a developer Mac"))
struct TakeOverFlowTests {
    struct Mac {
        let manager: PodManager
        let keychain: KeychainStore
        let stateURL: URL
        func cleanUp(models: [UUID]) {
            for item in [KeychainStore.Item.runpodAPIKey] + models.map(KeychainStore.Item.podKey) { try? keychain.delete(item) }
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    static func mac(_ runpod: SharedRunPod, tag: String) async throws -> Mac {
        let keychain = KeychainStore(service: "app.podlight.tests.\(UUID().uuidString)")
        try keychain.write("rp-test", for: .runpodAPIKey)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-takeover-\(UUID()).json")
        let store = StateStore(url: url)
        try await store.update { $0.deviceTag = tag }
        let manager = PodManager(store: store, keychain: keychain, transport: runpod,
                                 podURL: { _, port in URL(string: "http://127.0.0.1:1/\(port)")! },
                                 hostBusyTries: 3, hostBusyDelay: .zero)
        return Mac(manager: manager, keychain: keychain, stateURL: url)
    }

    static let info: @Sendable (String) async throws -> ModelInfo = { repo in
        ModelInfo(repoId: repo, access: .open, gated: false, format: .awq, weightBytes: 6e9, nativeContextTokens: 131_072,
                  license: nil, toolCallParser: "hermes", reasoningParser: nil)
    }

    @Test func theSecondMacTakesOverAndTheFirstLetsGoUntilItTakesItBack() async throws {
        let runpod = SharedRunPod()
        let a = try await Self.mac(runpod, tag: "mac-a-aaaa")
        let b = try await Self.mac(runpod, tag: "mac-b-bbbb")

        // A starts a model with a kept disk: the pod is named after A.
        let model = PodlightModel(name: "coder", repoId: "Org/Coder-AWQ", format: .awq, weightBytes: 6e9,
                                  nativeContextTokens: 131_072, toolCallParser: nil, reasoningParser: nil,
                                  contextTokens: 16_384, preferredGPU: GPUChoice(gpuId: "NVIDIA RTX A4000", cloud: .community),
                                  keepDisk: true)
        try await a.manager.save(model)
        try await a.manager.start(model.id, until: nil)
        let podId = try #require(await a.manager.state().run(model.id).podId)
        #expect(await runpod.name(of: podId) == "podlight-coder@mac-a-aaaa")
        let aKey = try a.keychain.read(.podKey(model.id))

        // B sees it as another Mac's pod and takes it over, pod key included.
        let found = try await b.manager.podsFromOtherMacs()
        #expect(found.map(\.id) == [podId])
        #expect(found.first?.owner == "mac-a-aaaa")
        #expect(try await a.manager.podsFromOtherMacs().isEmpty, "A does not offer its own pod")
        let bId = try await b.manager.takeOver(try #require(found.first), lookup: Self.info)
        var bIds = [bId]
        defer { a.cleanUp(models: [model.id]); b.cleanUp(models: bIds) }
        #expect(await runpod.name(of: podId) == "podlight-coder@mac-b-bbbb")
        #expect(try b.keychain.read(.podKey(bId)) == aKey)
        let bState = await b.manager.state()
        #expect(bState.models.first?.name == "coder" && bState.run(bId).podId == podId && bState.run(bId).managedBy == nil)

        // A notices on its next tick and lets go: no start, no gateway, no cost, no deletion.
        await a.manager.tick()
        let released = await a.manager.state().run(model.id)
        #expect(released.managedBy == "mac-b-bbbb")
        await #expect(throws: PodlightError.managedElsewhere("mac-b")) { try await a.manager.start(model.id, until: nil) }
        await #expect(throws: PodlightError.managedElsewhere("mac-b")) { _ = try await a.manager.endpoint(forModelNamed: "coder") }
        #expect(await a.manager.state().costPerHour == 0)

        // B stops it; A takes it back from the list of other Macs' pods, and B lets go.
        try await b.manager.stop(bId)
        let again = try await a.manager.podsFromOtherMacs()
        #expect(again.map(\.id) == [podId])
        let back = try await a.manager.takeOver(try #require(again.first), lookup: Self.info)
        #expect(back == model.id, "taking back keeps A's model instead of adding a second one")
        #expect(await runpod.name(of: podId) == "podlight-coder@mac-a-aaaa")
        #expect(await a.manager.state().run(model.id).managedBy == nil)
        await b.manager.tick()
        #expect(await b.manager.state().run(bId).managedBy == "mac-a-aaaa")

        // Removing the model on B leaves A's pod alone.
        try await b.manager.remove(bId)
        bIds = []
        #expect(await runpod.deleted.isEmpty)
        #expect(await runpod.pods[podId] != nil)
    }

    @Test func aPodFromBeforeTheOwnerTagIsClaimedAndANameClashIsRefused() async throws {
        let runpod = SharedRunPod()
        let a = try await Self.mac(runpod, tag: "mac-a-aaaa")
        let b = try await Self.mac(runpod, tag: "mac-b-bbbb")
        let model = PodlightModel(name: "coder", repoId: "Org/Coder-AWQ", format: .awq, weightBytes: 6e9,
                                  nativeContextTokens: 131_072, toolCallParser: nil, reasoningParser: nil,
                                  contextTokens: 16_384, keepDisk: true)
        try await a.manager.save(model)
        try a.keychain.write("pod-key-a", for: .podKey(model.id))
        defer { a.cleanUp(models: [model.id]); b.cleanUp(models: []) }
        await runpod.add(id: "old", name: "podlight-coder", status: "EXITED",
                         env: ["PODLIGHT_API_KEY": "pod-key-a", "PODLIGHT_MODEL": "Org/Coder-AWQ", "PODLIGHT_SERVED_NAME": "coder"])
        // B lists an untagged pod as from an older version.
        #expect(try await b.manager.podsFromOtherMacs().first?.owner == nil)

        let stopped = Date()
        try await StateStore(url: a.stateURL).update {
            $0.runs[model.id, default: ModelRun()].podId = "old"
            $0.runs[model.id, default: ModelRun()].stoppedAt = stopped
        }
        let reloaded = PodManager(store: StateStore(url: a.stateURL), keychain: a.keychain, transport: runpod,
                                  podURL: { _, port in URL(string: "http://127.0.0.1:1/\(port)")! })
        await reloaded.tick()
        #expect(await runpod.name(of: "old") == "podlight-coder@mac-a-aaaa", "A claims its own pod from before 0.6")

        // B already has a model with that name: taking A's over is refused.
        let mine = PodlightModel(name: "coder", repoId: "Other/Model", format: .awq, weightBytes: 1e9, nativeContextTokens: nil,
                                 toolCallParser: nil, reasoningParser: nil, contextTokens: 4096)
        try await b.manager.save(mine)
        let found = try #require(try await b.manager.podsFromOtherMacs().first)
        await #expect(throws: PodlightError.nameTaken("coder")) { try await b.manager.takeOver(found, lookup: Self.info) }
        #expect(await runpod.name(of: "old") == "podlight-coder@mac-a-aaaa")
    }

    @Test func aStoppedModelWithoutAPodIsSeenTakenOverStartedAndTakenBack() async throws {
        let runpod = SharedRunPod()
        let a = try await Self.mac(runpod, tag: "mac-a-aaaa")
        let b = try await Self.mac(runpod, tag: "mac-b-bbbb")
        // A has a model it never started (no kept disk, so no pod between runs).
        let model = PodlightModel(name: "coder", repoId: "Org/Coder-AWQ", format: .awq, weightBytes: 6e9,
                                  nativeContextTokens: 131_072, toolCallParser: "hermes", reasoningParser: nil,
                                  contextTokens: 16_384, preferredGPU: GPUChoice(gpuId: "NVIDIA RTX A4000", cloud: .community))
        try await a.manager.save(model)
        await a.manager.syncRecords(force: true)
        defer { a.cleanUp(models: [model.id]); b.cleanUp(models: [model.id]) }
        #expect(await runpod.recordNames() == ["podlight-model-coder@mac-a-aaaa"])
        #expect(await runpod.pods.isEmpty)

        // B sees it although it has no pod, and takes it over exactly (same id, no Hugging Face).
        let found = try await b.manager.podsFromOtherMacs()
        let foreign = try #require(found.first)
        #expect(found.count == 1 && foreign.servedName == "coder" && !foreign.hasPod && foreign.owner == "mac-a-aaaa")
        #expect(try await a.manager.podsFromOtherMacs().isEmpty, "A does not offer its own model")
        let id = try await b.manager.takeOver(foreign)
        #expect(id == model.id)
        let taken = try #require(await b.manager.state().models.first)
        // Dates go through JSON with whole seconds, as in the state file.
        #expect(taken.name == model.name && taken.repoId == model.repoId && taken.contextTokens == model.contextTokens
                && taken.toolCallParser == model.toolCallParser && taken.preferredGPU == model.preferredGPU && taken.keepDisk == model.keepDisk)
        #expect(try b.keychain.read(.podKey(id)) == a.keychain.read(.podKey(id)))
        #expect(await runpod.recordNames() == ["podlight-model-coder@mac-b-bbbb"])

        // A lets go at its next check, and does not grab it back.
        await a.manager.syncRecords(force: true)
        #expect(await a.manager.state().run(id).managedBy == "mac-b-bbbb")
        await a.manager.syncRecords(force: true)
        #expect(await runpod.recordNames() == ["podlight-model-coder@mac-b-bbbb"])

        // B starts it; the record learns the new pod.
        try await b.manager.start(id, until: nil)
        let podId = try #require(await b.manager.state().run(id).podId)
        #expect(await runpod.name(of: podId) == "podlight-coder@mac-b-bbbb")
        await b.manager.syncRecords(force: true)
        #expect(await runpod.recordPodId() == podId)

        // A takes it back, pod included; B lets go.
        let again = try #require(try await a.manager.podsFromOtherMacs().first)
        #expect(again.podId == podId && again.isRunning)
        #expect(try await a.manager.takeOver(again) == id)
        #expect(await a.manager.state().run(id).podId == podId)
        #expect(await a.manager.state().run(id).managedBy == nil)
        #expect(await runpod.name(of: podId) == "podlight-coder@mac-a-aaaa")
        #expect(await runpod.recordNames() == ["podlight-model-coder@mac-a-aaaa"])
        await b.manager.tick()
        #expect(await b.manager.state().run(id).managedBy == "mac-a-aaaa")

        // Deleting it on A, which manages it, removes pod and record.
        try await a.manager.remove(id)
        #expect(await runpod.pods.isEmpty)
        #expect(await runpod.recordNames().isEmpty)
    }

    @Test func aStoppedPodResumesWithThisVersionsScripts() async throws {
        let runpod = SharedRunPod()
        let a = try await Self.mac(runpod, tag: "mac-a-aaaa")
        let model = PodlightModel(name: "coder", repoId: "Org/Coder-AWQ", format: .awq, weightBytes: 6e9,
                                  nativeContextTokens: 131_072, toolCallParser: nil, reasoningParser: nil,
                                  contextTokens: 16_384, preferredGPU: GPUChoice(gpuId: "NVIDIA RTX A4000", cloud: .community),
                                  keepDisk: true)
        try await a.manager.save(model)
        defer { a.cleanUp(models: [model.id]) }
        try await a.manager.start(model.id, until: nil)
        let podId = try #require(await a.manager.state().run(model.id).podId)
        try await a.manager.stop(model.id)
        // As made by an older version.
        await runpod.setEnv(podId, "PODLIGHT_BOOT_B64", "old")
        await runpod.setEnv(podId, "PODLIGHT_WATCHDOG_B64", "old")
        let key = await runpod.env(of: podId)?["PODLIGHT_API_KEY"]

        let until = Date().addingTimeInterval(3600)
        try await a.manager.start(model.id, until: until)
        let env = try #require(await runpod.env(of: podId))
        #expect(env["PODLIGHT_BOOT_B64"] == PodPlan.resource("boot", "sh").base64EncodedString())
        #expect(env["PODLIGHT_WATCHDOG_B64"] == PodPlan.resource("watchdog", "py").base64EncodedString())
        #expect(env["PODLIGHT_DEADLINE"] == String(Int(until.addingTimeInterval(PodPlan.deadlineGrace).timeIntervalSince1970)))
        #expect(env["PODLIGHT_API_KEY"] == key, "the rest stays")
        #expect(PodPlan.freshenedEnv(env, runUntil: until) == nil, "nothing to change the second time")
        #expect(PodPlan.freshenedEnv(["X": "1"], runUntil: nil) == nil, "not Podlight's")
    }

    @Test func aBusyMachineKeepsTheStoppedPodAndOnlyANewCardReplacesIt() async throws {
        let runpod = SharedRunPod()
        let a = try await Self.mac(runpod, tag: "mac-a-aaaa")
        let model = PodlightModel(name: "coder", repoId: "Org/Coder-AWQ", format: .awq, weightBytes: 6e9,
                                  nativeContextTokens: 131_072, toolCallParser: nil, reasoningParser: nil,
                                  contextTokens: 16_384, preferredGPU: GPUChoice(gpuId: "NVIDIA RTX A4000", cloud: .community),
                                  keepDisk: true)
        try await a.manager.save(model)
        defer { a.cleanUp(models: [model.id]) }
        try await a.manager.start(model.id, until: nil)
        let podId = try #require(await a.manager.state().run(model.id).podId)
        try await a.manager.stop(model.id)

        // Busy for two tries, free on the third: it resumes the same pod.
        await runpod.setHostBusy(2)
        try await a.manager.start(model.id, until: nil)
        #expect(await a.manager.state().run(model.id).podId == podId)
        try await a.manager.stop(model.id)

        // Busy for longer: the pod and its disk stay, and the start says why.
        await runpod.setHostBusy(10)
        await #expect(throws: PodlightError.hostBusy) { try await a.manager.start(model.id, until: nil) }
        let run = await a.manager.state().run(model.id)
        #expect(run.podId == podId && run.lastReason == "host-busy" && run.phase == .stopped)
        #expect(await runpod.pods[podId] != nil)
        #expect(await runpod.deleted.isEmpty)

        // Only the user's choice of a new card replaces it.
        await runpod.setHostBusy(0)
        try await a.manager.start(model.id, until: nil, newPod: true)
        #expect(await runpod.deleted == [podId])
        #expect(await a.manager.state().run(model.id).podId != podId)
    }

    @Test func aStoppedPodWithoutDatesStartsItsDeletionClockInsteadOfVanishing() async throws {
        let runpod = SharedRunPod()
        let a = try await Self.mac(runpod, tag: "mac-a-aaaa")
        let model = PodlightModel(name: "coder", repoId: "Org/Coder-AWQ", format: .awq, weightBytes: 6e9,
                                  nativeContextTokens: 131_072, toolCallParser: nil, reasoningParser: nil,
                                  contextTokens: 16_384, keepDisk: true)
        try await a.manager.save(model)
        defer { a.cleanUp(models: [model.id]) }
        await runpod.add(id: "kept", name: "podlight-coder@mac-a-aaaa", status: "EXITED",
                         env: ["PODLIGHT_API_KEY": "k", "PODLIGHT_MODEL": "Org/Coder-AWQ", "PODLIGHT_SERVED_NAME": "coder"])
        try await StateStore(url: a.stateURL).update { $0.runs[model.id, default: ModelRun()].podId = "kept" }
        let reloaded = PodManager(store: StateStore(url: a.stateURL), keychain: a.keychain, transport: runpod,
                                  podURL: { _, port in URL(string: "http://127.0.0.1:1/\(port)")! })
        await reloaded.tick()
        #expect(await runpod.pods["kept"] != nil, "not deleted as if ancient")
        #expect(await reloaded.state().run(model.id).stoppedAt != nil, "its clock starts now")
    }
}
