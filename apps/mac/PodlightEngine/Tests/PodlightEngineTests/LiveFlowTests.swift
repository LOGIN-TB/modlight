import Foundation
import Testing
@testable import PodlightEngine

// The whole local flow on real RunPod hardware, with a tiny model on the cheapest suitable card.
// Costs real money (roughly 0.10 USD), so it runs only when asked for explicitly:
//   PODLIGHT_LIVE_E2E=1 RUNPOD_API_KEY=… swift test --filter LiveFlow
// Whatever happens, the pod is deleted at the end and RunPod is asked whether it is gone.

private func log(_ message: String) {
    let stamp = Date().formatted(date: .omitted, time: .standard)
    print("[live \(stamp)] \(message)")
    fflush(stdout)
}

@Suite("Live flow on RunPod", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_LIVE_E2E"] == "1"
                && ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] != nil))
struct LiveFlowTests {
    @Test(.timeLimit(.minutes(45)))
    func startServeStopResumeDelete() async throws {
        let apiKey = ProcessInfo.processInfo.environment["RUNPOD_API_KEY"]!
        let keychain = KeychainStore(service: "app.podlight.live.\(UUID().uuidString)")
        try keychain.write(apiKey, for: .runpodAPIKey)
        try keychain.write("gw-live", for: .gatewayKey)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-live-\(UUID()).json")
        let manager = PodManager(store: StateStore(url: stateURL), keychain: keychain)
        let client = RunpodClient(apiKey: apiKey)
        var modelId: UUID?

        func cleanUp() async {
            if let id = modelId {
                let podId = await manager.state().run(id).podId
                try? await manager.remove(id)
                if let podId {
                    do {
                        _ = try await client.pod(id: podId)
                        log("WARNING: pod \(podId) still exists after delete")
                        try? await client.deletePod(id: podId)
                    } catch let e as RunpodError where e.isNotFound {
                        log("pod \(podId) is gone at RunPod (404)")
                    } catch { log("could not confirm deletion: \(error)") }
                }
                try? keychain.delete(.podKey(id))
            }
            for item in [KeychainStore.Item.runpodAPIKey, .gatewayKey] { try? keychain.delete(item) }
            try? FileManager.default.removeItem(at: stateURL)
        }

        do {
            // 1. Read a real model from Hugging Face.
            let info = try await HuggingFaceClient().info("Qwen/Qwen2.5-0.5B-Instruct")
            log("model: \(info.format) \(Format(info.weightBytes)) GB, context \(info.nativeContextTokens ?? 0), tools \(info.toolCallParser ?? "none")")
            #expect(info.access == .open && info.toolCallParser == "hermes")

            var model = PodlightModel(name: "qwen-tiny", repoId: info.repoId, format: info.format, weightBytes: info.weightBytes,
                                      nativeContextTokens: info.nativeContextTokens, toolCallParser: info.toolCallParser,
                                      reasoningParser: info.reasoningParser, contextTokens: 8_192, goal: .economical)
            let catalog = try await client.gpuCatalog()
            let options = GPUSuggestion.options(for: model.info, catalog: catalog, goal: .economical).filter { $0.pricePerHour <= 0.6 }
            log("cheapest suitable: " + options.prefix(5).map { "\($0.displayName) \($0.choice.cloud.rawValue) $\($0.pricePerHour)" }.joined(separator: ", "))
            model.preferredGPU = options.first?.choice
            try await manager.save(model)
            modelId = model.id

            // 2. Start with an end, and wait for the engine.
            let t0 = Date()
            try await manager.start(model.id, until: Date().addingTimeInterval(25 * 60))
            var run = await manager.state().run(model.id)
            log("created pod \(run.podId ?? "?") on \(run.gpuName ?? "?") at $\(run.pricePerHour ?? 0)/h; fell back from \(run.fellBackFrom ?? [])")
            var lastPhase = run.phase
            while Date().timeIntervalSince(t0) < 25 * 60 {
                try await Task.sleep(for: .seconds(15))
                await manager.refresh(model.id)
                run = await manager.state().run(model.id)
                if run.phase != lastPhase { log("phase \(run.phase) after \(Int(Date().timeIntervalSince(t0)))s"); lastPhase = run.phase }
                if run.phase == .ready || run.phase == .failed || run.phase == .stopped { break }
            }
            #expect(run.phase == .ready)
            #expect(run.lastHeartbeatAt != nil, "the watchdog never answered a heartbeat")
            log("ready after \(Int(Date().timeIntervalSince(t0)))s; heartbeat at \(run.lastHeartbeatAt?.description ?? "never")")

            // 3. Through the gateway, streamed, and with a tool.
            let port = Int.random(in: 45_000...48_000)
            let gateway = Task { try await LocalGateway(port: port, manager: manager, key: { "gw-live" }).run() }
            defer { gateway.cancel() }
            try await Task.sleep(for: .seconds(1))
            var chat = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            chat.httpMethod = "POST"
            chat.timeoutInterval = 300
            chat.setValue("Bearer gw-live", forHTTPHeaderField: "Authorization")
            chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
            chat.httpBody = Data(#"{"model":"qwen-tiny","stream":true,"max_tokens":40,"messages":[{"role":"user","content":"Say hello in German."}]}"#.utf8)
            let (streamed, streamResponse) = try await URLSession.shared.data(for: chat)
            let streamText = String(decoding: streamed, as: UTF8.self)
            log("stream: HTTP \((streamResponse as? HTTPURLResponse)?.statusCode ?? 0), \(streamText.components(separatedBy: "data: ").count - 1) events")
            #expect((streamResponse as? HTTPURLResponse)?.statusCode == 200 && streamText.contains("[DONE]"))

            chat.httpBody = Data(#"{"model":"qwen-tiny","max_tokens":120,"tool_choice":"auto","messages":[{"role":"user","content":"What is the weather in Berlin? Use the tool."}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]}"#.utf8)
            let (toolData, toolResponse) = try await URLSession.shared.data(for: chat)
            let toolText = String(decoding: toolData, as: UTF8.self)
            log("tools: HTTP \((toolResponse as? HTTPURLResponse)?.statusCode ?? 0): \(toolText.prefix(400))")
            #expect((toolResponse as? HTTPURLResponse)?.statusCode == 200, "vLLM refused a request with tools")

            // 4. Stop, and check at RunPod.
            try await manager.stop(model.id)
            let stopped = try await client.pod(id: run.podId!)
            log("after stop: RunPod says \(stopped.status)")
            #expect(stopped.status == .exited)

            // 5. Resume: same pod, model already on its disk.
            let t1 = Date()
            try await manager.start(model.id, until: Date().addingTimeInterval(15 * 60))
            let resumedPod = await manager.state().run(model.id).podId
            #expect(resumedPod == run.podId, "resume built a new pod instead")
            while Date().timeIntervalSince(t1) < 15 * 60 {
                try await Task.sleep(for: .seconds(10))
                await manager.refresh(model.id)
                run = await manager.state().run(model.id)
                if run.phase == .ready || run.phase == .failed { break }
            }
            log("resume: \(run.phase) after \(Int(Date().timeIntervalSince(t1)))s on pod \(run.podId ?? "?")")
            #expect(run.phase == .ready)
            log("spend counted: \(await manager.state().spendByDay)")
        } catch {
            log("FAILED: \(error)")
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    private func Format(_ bytes: Double) -> String { String(format: "%.1f", bytes / 1e9) }
}

// 0.2 on real hardware: EU only, no kept disk, two cards with tensor parallel, read through the
// watchdog (engine log) when anything fails.
//   PODLIGHT_LIVE_E2E=1 RUNPOD_API_KEY=… swift test --filter LiveEUTwoCards
@Suite("Live 0.2 on RunPod", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_LIVE_E2E"] == "1"
                && ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] != nil))
struct LiveEUTwoCards {
    /// Requests that end: RunPod's log stream never closes, so every call gets a hard limit.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    func get(_ url: URL, key: String) async -> (Int, Data) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await Self.session.data(for: request) else { return (0, Data()) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @Test(.timeLimit(.minutes(40)))
    func euNoDiskTwoCards() async throws {
        let apiKey = ProcessInfo.processInfo.environment["RUNPOD_API_KEY"]!
        let client = RunpodClient(apiKey: apiKey, transport: Self.session)
        let podKey = PodManager.randomKey()
        var podId: String?

        func cleanUp() async {
            guard let id = podId else { return }
            try? await client.deletePod(id: id)
            do { _ = try await client.pod(id: id); print("[live] WARNING: \(id) still exists") }
            catch let e as RunpodError where e.isNotFound { print("[live] pod \(id) is gone at RunPod (404)") }
            catch { print("[live] could not confirm deletion: \(error)") }
        }

        do {
            let info = try await HuggingFaceClient().info("Qwen/Qwen2.5-0.5B-Instruct")
            let catalog = try await client.gpuCatalog()
            let eu = HostingPolicy(region: .eu)
            func candidates(_ policy: HostingPolicy, count: Int) -> [(GPUChoice, Double)] {
                catalog.filter { $0.manufacturer == "NVIDIA" && CardSupport.runsEngineImage($0.id)
                    && policy.mayHaveCapacity($0) && $0.mayHaveCuda(atLeast: PodPlan.minCudaVersion) }
                    .flatMap { gpu in policy.clouds.compactMap { cloud -> (GPUChoice, Double)? in
                        guard let p = gpu.pricePerHour(in: cloud), gpu.maxCards(in: cloud) >= count, p <= 0.6 else { return nil }
                        return (GPUChoice(gpuId: gpu.id, cloud: cloud, count: count), p * Double(count)) } }
                    .sorted { $0.1 < $1.1 }
            }
            // Two cards anywhere first (scarce in the EU), then one card in the EU to check the region path.
            let choices = Array(candidates(.anywhere, count: 2).prefix(6)) + Array(candidates(eu, count: 1).prefix(4))
            print("[live] choices: " + choices.map { "\($0.0.gpuId) \($0.0.cloud.rawValue) $\($0.1)" }.joined(separator: ", "))
            var model = PodlightModel(name: "qwen-tiny-tp2", repoId: info.repoId, format: info.format, weightBytes: info.weightBytes,
                                      nativeContextTokens: info.nativeContextTokens, toolCallParser: info.toolCallParser,
                                      reasoningParser: info.reasoningParser, contextTokens: 8_192, kvProfile: info.kvProfile,
                                      keepDisk: false)
            model.preferredGPU = choices.first?.0
            let request = PodPlan.request(for: model, podKey: podKey, huggingFaceToken: nil, runUntil: Date().addingTimeInterval(30 * 60),
                                          heartbeatMinutes: 15, dataCenterIds: nil)
            let created = try await client.createPod(request, tryingInOrder: choices.map(\.0), catalog: catalog)
            podId = created.pod.id
            print("[live] created \(created.pod.id): \(created.choice.gpuId) × \(created.choice.count), attempts \(created.attempts.map { "\($0.choice.gpuId):\($0.outcome)" })")
            let t0 = Date()
            let wd = PodPlan.proxyURL(created.pod.id, PodPlan.watchdogPort)
            let engine = PodPlan.proxyURL(created.pod.id, PodPlan.enginePort)
            var ready = false, center: String?
            while Date().timeIntervalSince(t0) < 30 * 60 {
                try await Task.sleep(for: .seconds(15))
                if let pod = try? await client.pod(id: created.pod.id) {
                    center = pod.dataCenterId
                    if pod.status == .exited || pod.status == .terminated { print("[live] pod \(pod.status) after \(Int(Date().timeIntervalSince(t0)))s"); break }
                }
                let (status, body) = await get(wd, key: podKey)
                if status == 200, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], json["engineAlive"] as? Bool == false {
                    let (_, logData) = await get(wd.appendingPathComponent("log"), key: podKey)
                    let lines = (try? JSONSerialization.jsonObject(with: logData) as? [String: Any])?["lines"] as? [String] ?? []
                    print("[live] ENGINE EXITED (code \(json["engineExitCode"] ?? "?")). Last lines:\n" + lines.suffix(25).joined(separator: "\n"))
                    break
                }
                if await get(engine.appendingPathComponent("v1/models"), key: podKey).0 == 200 { ready = true; break }
            }
            print("[live] ready=\(ready) after \(Int(Date().timeIntervalSince(t0)))s in \(center ?? "?")")
            #expect(ready)
            print("[live] placed in \(center ?? "?") with \(created.choice.count) card(s)")
            if ready {
                let (_, logData) = await get(wd.appendingPathComponent("log"), key: podKey)
                let text = ((try? JSONSerialization.jsonObject(with: logData) as? [String: Any])?["lines"] as? [String] ?? []).joined(separator: "\n")
                print("[live] engine log mentions tensor_parallel_size=2: \(text.contains("tensor_parallel_size=2"))")
                var chat = URLRequest(url: engine.appendingPathComponent("v1/chat/completions"))
                chat.httpMethod = "POST"
                chat.setValue("Bearer \(podKey)", forHTTPHeaderField: "Authorization")
                chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
                chat.httpBody = Data(#"{"model":"qwen-tiny-tp2","max_tokens":20,"messages":[{"role":"user","content":"Hallo"}]}"#.utf8)
                let (_, response) = try await Self.session.data(for: chat)
                print("[live] chat on \(created.choice.count) card(s): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
            }
        } catch {
            print("[live] FAILED: \(error)")
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}

// 0.3 on real hardware: a GGUF model on llama.cpp, and the Anthropic and Responses routes that
// Claude Code and Codex use, on both engines. Opt-in, about 0.10 USD per engine:
//   PODLIGHT_LIVE_03=llamacpp|vllm RUNPOD_API_KEY=… swift test --filter Live03
@Suite("Live 0.3 on RunPod", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_LIVE_03"] != nil
                && ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] != nil))
struct Live03Tests {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    @Test(.timeLimit(.minutes(40)))
    func engineServesAllThreeAPIs() async throws {
        let engine = ProcessInfo.processInfo.environment["PODLIGHT_LIVE_03"] == "vllm" ? InferenceEngine.vllm : .llamaCpp
        let apiKey = ProcessInfo.processInfo.environment["RUNPOD_API_KEY"]!
        let keychain = KeychainStore(service: "app.podlight.live.\(UUID().uuidString)")
        try keychain.write(apiKey, for: .runpodAPIKey)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-live-\(UUID()).json")
        let manager = PodManager(store: StateStore(url: stateURL), keychain: keychain)
        let client = RunpodClient(apiKey: apiKey)
        var modelId: UUID?

        func cleanUp() async {
            if let id = modelId {
                let run = await manager.state().run(id)
                if run.phase == .failed || run.phase == .loading {
                    print("[live03] engine log: \(run.lastMessage ?? "-")")
                }
                try? await manager.remove(id)
                if let podId = run.podId {
                    do {
                        _ = try await client.pod(id: podId)
                        print("[live03] WARNING: pod \(podId) still exists; deleting")
                        try? await client.deletePod(id: podId)
                    } catch let e as RunpodError where e.isNotFound {
                        print("[live03] pod \(podId) is gone at RunPod (404)")
                    } catch { print("[live03] could not confirm deletion: \(error)") }
                }
                try? keychain.delete(.podKey(id))
            }
            try? keychain.delete(.runpodAPIKey)
            try? FileManager.default.removeItem(at: stateURL)
        }

        do {
            let repo = engine == .llamaCpp ? "Qwen/Qwen2.5-0.5B-Instruct-GGUF" : "Qwen/Qwen2.5-0.5B-Instruct"
            let info = try await HuggingFaceClient().info(repo)
            print("[live03] \(engine): \(info.format) \(info.quant ?? "-") \(info.weightBytes / 1e9) GB, kv \(info.kvProfile?.bytesPerToken ?? 0), tools \(info.toolCallParser ?? "-")")
            var model = PodlightModel(name: "tiny", repoId: info.repoId, format: info.format, weightBytes: info.weightBytes,
                                      nativeContextTokens: info.nativeContextTokens, toolCallParser: info.toolCallParser,
                                      reasoningParser: info.reasoningParser, contextTokens: 8_192, goal: .economical,
                                      kvProfile: info.kvProfile, quant: info.quant)
            let catalog = try await client.gpuCatalog()
            let options = GPUSuggestion.options(for: model.info, catalog: catalog, goal: .economical).filter { $0.pricePerHour <= 0.5 }
            print("[live03] cheapest: " + options.prefix(5).map { "\($0.label) \($0.choice.cloud.rawValue) $\($0.pricePerHour)" }.joined(separator: ", "))
            model.preferredGPU = options.first?.choice
            try await manager.save(model)
            modelId = model.id

            let t0 = Date()
            try await manager.start(model.id, until: Date().addingTimeInterval(25 * 60))
            var run = await manager.state().run(model.id)
            print("[live03] created \(run.podId ?? "?") on \(run.gpuName ?? "?") at $\(run.pricePerHour ?? 0)/h")
            var lastPhase = run.phase
            while Date().timeIntervalSince(t0) < 25 * 60 {
                try await Task.sleep(for: .seconds(15))
                await manager.refresh(model.id)
                run = await manager.state().run(model.id)
                if run.phase != lastPhase { print("[live03] phase \(run.phase) after \(Int(Date().timeIntervalSince(t0)))s"); lastPhase = run.phase }
                if run.phase == .ready || run.phase == .failed || run.phase == .stopped { break }
            }
            print("[live03] \(run.phase) after \(Int(Date().timeIntervalSince(t0)))s; \(run.lastReason ?? "") \(run.lastMessage ?? "")")
            #expect(run.phase == .ready)
            guard run.phase == .ready else { await cleanUp(); return }

            let port = Int.random(in: 45_000...48_000)
            let gateway = Task { try await LocalGateway(port: port, manager: manager, key: { "gw-live" }).run() }
            defer { gateway.cancel() }
            try await Task.sleep(for: .seconds(1))
            let base = "http://127.0.0.1:\(port)"

            func post(_ path: String, _ body: String, headers: [String: String] = ["Authorization": "Bearer gw-live"]) async throws -> (Int, String) {
                var request = URLRequest(url: URL(string: base + path)!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
                request.httpBody = Data(body.utf8)
                let (data, response) = try await Self.session.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
            }
            let tool = #"{"name":"get_weather","description":"Current weather for a city","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}"#
            let openAITool = #"{"type":"function","function":{"name":"get_weather","description":"Current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}"#

            let chat = try await post("/v1/chat/completions", #"{"model":"tiny","max_tokens":120,"messages":[{"role":"user","content":"What is the weather in Berlin? Use the tool."}],"tools":[\#(openAITool)]}"#)
            print("[live03] chat+tools: \(chat.0) \(chat.1.prefix(300))")
            #expect(chat.0 == 200)

            let anthropicHeaders = ["x-api-key": "gw-live", "anthropic-version": "2023-06-01"]
            let messages = try await post("/v1/messages?beta=true", #"{"model":"tiny","max_tokens":120,"messages":[{"role":"user","content":"What is the weather in Berlin? Use the tool."}],"tools":[\#(tool)]}"#, headers: anthropicHeaders)
            print("[live03] messages+tools: \(messages.0) \(messages.1.prefix(400))")
            #expect(messages.0 == 200)
            #expect(messages.1.contains(#""type":"message""#) || messages.1.contains(#""type": "message""#))

            let streamed = try await post("/v1/messages", #"{"model":"tiny","max_tokens":30,"stream":true,"messages":[{"role":"user","content":"Say hello."}]}"#, headers: anthropicHeaders)
            print("[live03] messages stream: \(streamed.0), events: \(streamed.1.components(separatedBy: "event:").count - 1)")
            #expect(streamed.0 == 200 && streamed.1.contains("message_stop"))

            let count = try await post("/v1/messages/count_tokens", #"{"model":"tiny","messages":[{"role":"user","content":"Hello there"}]}"#, headers: anthropicHeaders)
            print("[live03] count_tokens: \(count.0) \(count.1.prefix(200))")

            let responses = try await post("/v1/responses", #"{"model":"tiny","max_output_tokens":60,"input":"What is the weather in Berlin? Use the tool.","tools":[{"type":"function","name":"get_weather","description":"Current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]}"#)
            print("[live03] responses+tools: \(responses.0) \(responses.1.prefix(400))")
            #expect(responses.0 == 200)
        } catch {
            print("[live03] FAILED: \(error)")
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}

// 0.5 on real hardware: the watchdog's telemetry (nvidia-smi, cgroup, disk, the engine's /metrics)
// reaches PodManager with each heartbeat, idle and under load. Opt-in, about 0.05 USD per engine:
//   PODLIGHT_LIVE_TELEMETRY=vllm|llamacpp RUNPOD_API_KEY=… swift test --filter LiveTelemetry
@Suite("Live telemetry on RunPod", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_LIVE_TELEMETRY"] != nil
                && ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] != nil))
struct LiveTelemetryTests {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    static func describe(_ t: PodTelemetry?) -> String {
        guard let t, let data = try? JSONEncoder().encode(t) else { return "none" }
        return String(decoding: data, as: UTF8.self)
    }

    @Test(.timeLimit(.minutes(40)))
    func telemetryArrivesWithHeartbeats() async throws {
        let engine = ProcessInfo.processInfo.environment["PODLIGHT_LIVE_TELEMETRY"] == "llamacpp" ? InferenceEngine.llamaCpp : .vllm
        let apiKey = ProcessInfo.processInfo.environment["RUNPOD_API_KEY"]!
        let keychain = KeychainStore(service: "app.podlight.live.\(UUID().uuidString)")
        try keychain.write(apiKey, for: .runpodAPIKey)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-live-\(UUID()).json")
        let manager = PodManager(store: StateStore(url: stateURL), keychain: keychain)
        let client = RunpodClient(apiKey: apiKey)
        var modelId: UUID?

        func cleanUp() async {
            if let id = modelId {
                let run = await manager.state().run(id)
                if run.phase == .failed { print("[telemetry] engine log: \(run.lastMessage ?? "-")") }
                try? await manager.remove(id)
                if let podId = run.podId {
                    do {
                        _ = try await client.pod(id: podId)
                        print("[telemetry] WARNING: pod \(podId) still exists; deleting")
                        try? await client.deletePod(id: podId)
                    } catch let e as RunpodError where e.isNotFound {
                        print("[telemetry] pod \(podId) is gone at RunPod (404)")
                    } catch { print("[telemetry] could not confirm deletion: \(error)") }
                }
                try? keychain.delete(.podKey(id))
            }
            try? keychain.delete(.runpodAPIKey)
            try? FileManager.default.removeItem(at: stateURL)
        }

        do {
            let repo = engine == .llamaCpp ? "Qwen/Qwen2.5-0.5B-Instruct-GGUF" : "Qwen/Qwen2.5-0.5B-Instruct"
            let info = try await HuggingFaceClient().info(repo)
            var model = PodlightModel(name: "tiny", repoId: info.repoId, format: info.format, weightBytes: info.weightBytes,
                                      nativeContextTokens: info.nativeContextTokens, toolCallParser: info.toolCallParser,
                                      reasoningParser: info.reasoningParser, contextTokens: 8_192, goal: .economical,
                                      kvProfile: info.kvProfile, quant: info.quant)
            let catalog = try await client.gpuCatalog()
            let options = GPUSuggestion.options(for: model.info, catalog: catalog, goal: .economical).filter { $0.pricePerHour <= 0.5 }
            print("[telemetry] \(engine), cheapest: " + options.prefix(4).map { "\($0.label) \($0.choice.cloud.rawValue) $\($0.pricePerHour)" }.joined(separator: ", "))
            model.preferredGPU = options.first?.choice
            try await manager.save(model)
            modelId = model.id

            let t0 = Date()
            try await manager.start(model.id, until: Date().addingTimeInterval(25 * 60))
            var run = await manager.state().run(model.id)
            print("[telemetry] created \(run.podId ?? "?") on \(run.gpuName ?? "?") at $\(run.pricePerHour ?? 0)/h")
            var firstSampleAt: Int?
            while Date().timeIntervalSince(t0) < 25 * 60 {
                try await Task.sleep(for: .seconds(10))
                await manager.refresh(model.id)
                run = await manager.state().run(model.id)
                if firstSampleAt == nil, let t = await manager.latestTelemetry()[model.id] {
                    firstSampleAt = Int(Date().timeIntervalSince(t0))
                    print("[telemetry] first sample after \(firstSampleAt!)s (phase \(run.phase)): \(Self.describe(t))")
                }
                if run.phase == .ready || run.phase == .failed || run.phase == .stopped { break }
            }
            print("[telemetry] \(run.phase) after \(Int(Date().timeIntervalSince(t0)))s")
            #expect(run.phase == .ready)
            guard run.phase == .ready else { await cleanUp(); return }

            let idle = await manager.latestTelemetry()[model.id]
            print("[telemetry] idle: \(Self.describe(idle))")
            #expect(idle?.gpus?.isEmpty == false, "no nvidia-smi figures")
            #expect((idle?.gpus?.first?.memoryUsedBytes ?? 0) > 0, "no GPU memory in use reported")
            #expect(idle?.memoryTotalBytes != nil && idle?.diskTotalBytes != nil)
            #expect(idle?.engine != nil, "no figures from the engine's /metrics")

            // Under load: a long answer while the heartbeats keep going.
            let port = Int.random(in: 45_000...48_000)
            let gateway = Task { try await LocalGateway(port: port, manager: manager, key: { "gw-live" }).run() }
            defer { gateway.cancel() }
            try await Task.sleep(for: .seconds(1))
            let load = Task {
                for _ in 0..<12 {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer gw-live", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = Data(#"{"model":"tiny","max_tokens":1500,"temperature":0.9,"messages":[{"role":"user","content":"Write a long story about a lighthouse keeper, at least 1000 words."}]}"#.utf8)
                    _ = try? await Self.session.data(for: request)
                }
            }
            var busiest: PodTelemetry?
            for _ in 0..<9 {
                try await Task.sleep(for: .seconds(6))
                await manager.refresh(model.id)
                if let t = await manager.latestTelemetry()[model.id],
                   (t.engine?.generationTokensPerSecond ?? 0) > (busiest?.engine?.generationTokensPerSecond ?? 0) { busiest = t }
            }
            load.cancel()
            print("[telemetry] busiest: \(Self.describe(busiest))")
            #expect((busiest?.engine?.generationTokensPerSecond ?? 0) > 0, "no token rate under load")
            let history = await manager.telemetry(for: model.id)
            print("[telemetry] history: \(history.count) samples, GPU load \(history.compactMap { $0.averageGPUPercent.map { Int($0) } })")
        } catch {
            print("[telemetry] FAILED: \(error)")
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}
