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

// 0.2 on real hardware: EU only, no kept disk, two cards with tensor parallel.
//   PODLIGHT_LIVE_E2E=1 RUNPOD_API_KEY=… swift test --filter LiveEUTwoCards
@Suite("Live 0.2 on RunPod", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_LIVE_E2E"] == "1"
                && ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] != nil))
struct LiveEUTwoCards {
    @Test(.timeLimit(.minutes(45)))
    func euNoDiskTwoCards() async throws {
        let apiKey = ProcessInfo.processInfo.environment["RUNPOD_API_KEY"]!
        let keychain = KeychainStore(service: "app.podlight.live.\(UUID().uuidString)")
        try keychain.write(apiKey, for: .runpodAPIKey)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-live-\(UUID()).json")
        let store = StateStore(url: stateURL)
        _ = try await store.update { $0.settings.hostingRegion = .eu }
        let manager = PodManager(store: store, keychain: keychain)
        let client = RunpodClient(apiKey: apiKey)
        var modelId: UUID?
        var podId: String?

        func cleanUp() async {
            if let id = modelId { try? await manager.remove(id) }
            if let podId {
                do { _ = try await client.pod(id: podId); print("[live] WARNING: \(podId) still exists"); try? await client.deletePod(id: podId) }
                catch let e as RunpodError where e.isNotFound { print("[live] pod \(podId) is gone at RunPod (404)") }
                catch { print("[live] could not confirm deletion: \(error)") }
            }
            if let id = modelId { try? keychain.delete(.podKey(id)) }
            try? keychain.delete(.runpodAPIKey)
            try? FileManager.default.removeItem(at: stateURL)
        }

        do {
            let info = try await HuggingFaceClient().info("Qwen/Qwen2.5-0.5B-Instruct")
            print("[live] kv profile: \(info.kvProfile.map { "\(Int($0.bytesPerToken)) B/token, \($0.attentionHeads ?? 0) heads" } ?? "none")")
            let catalog = try await client.gpuCatalog()
            let eu = HostingPolicy(region: .eu)
            // Cheapest card type that may be free in the EU and allows two per pod.
            let candidates = catalog.filter { $0.manufacturer == "NVIDIA" && CardSupport.runsEngineImage($0.id)
                && eu.mayHaveCapacity($0) && $0.mayHaveCuda(atLeast: PodPlan.minCudaVersion) }
                .flatMap { gpu in eu.clouds.compactMap { cloud in
                    gpu.pricePerHour(in: cloud).flatMap { p in gpu.maxCards(in: cloud) >= 2 ? (gpu, cloud, p) : nil } } }
                .sorted { $0.2 < $1.2 }
            print("[live] EU candidates: " + candidates.prefix(5).map { "\($0.0.name) \($0.1.rawValue) $\($0.2)" }.joined(separator: ", "))
            let pick = try #require(candidates.first(where: { $0.2 <= 0.6 }), "no affordable EU card allowing two per pod")

            var model = PodlightModel(name: "qwen-tiny-tp2", repoId: info.repoId, format: info.format, weightBytes: info.weightBytes,
                                      nativeContextTokens: info.nativeContextTokens, toolCallParser: info.toolCallParser,
                                      reasoningParser: info.reasoningParser, contextTokens: 8_192, goal: .economical,
                                      kvProfile: info.kvProfile, keepDisk: false)
            model.preferredGPU = GPUChoice(gpuId: pick.0.id, cloud: pick.1, count: 2)
            try await manager.save(model)
            modelId = model.id

            let t0 = Date()
            try await manager.start(model.id, until: Date().addingTimeInterval(25 * 60))
            var run = await manager.state().run(model.id)
            podId = run.podId
            print("[live] created \(run.podId ?? "?") on \(run.gpuName ?? "?") at $\(run.pricePerHour ?? 0)/h + storage $\(String(format: "%.4f", run.storagePerHour ?? 0))/h; dc \(run.dataCenterId ?? "not yet")")
            let pod = try await client.pod(id: run.podId!)
            print("[live] RunPod: gpu \(pod.gpu?.id ?? "?") × \(pod.gpu?.count ?? 0), cost $\(pod.cost ?? 0)/h, dc \(pod.dataCenterId ?? "nil")")
            #expect(pod.gpu?.count == 2)

            while Date().timeIntervalSince(t0) < 28 * 60 {
                try await Task.sleep(for: .seconds(15))
                await manager.refresh(model.id)
                run = await manager.state().run(model.id)
                if run.phase == .ready || run.phase == .failed || run.phase == .stopped { break }
            }
            print("[live] phase \(run.phase) after \(Int(Date().timeIntervalSince(t0)))s, dc \(run.dataCenterId ?? "nil"), reason \(run.lastReason ?? "-")")
            #expect(run.phase == .ready)
            #expect(run.dataCenterId?.hasPrefix("EU-") == true)

            // Logs: did tensor parallel and the Xet download path show up?
            var logRequest = URLRequest(url: URL(string: "https://api.runpod.io/v2/pods/\(run.podId!)/logs")!)
            logRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            logRequest.timeoutInterval = 15
            if let (data, _) = try? await URLSession.shared.data(for: logRequest) {
                let text = String(decoding: data, as: UTF8.self)
                for needle in ["tensor_parallel_size=2", "tensor-parallel-size", "xet", "Xet", "HF_XET"] {
                    print("[live] log mentions \(needle): \(text.contains(needle))")
                }
            }

            if run.phase == .ready {
                let endpoint = try await manager.endpoint(forModelNamed: model.name)
                var chat = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/chat/completions"))
                chat.httpMethod = "POST"
                chat.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
                chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
                chat.httpBody = Data(#"{"model":"qwen-tiny-tp2","max_tokens":20,"messages":[{"role":"user","content":"Hallo"}]}"#.utf8)
                let (_, response) = try await URLSession.shared.data(for: chat)
                print("[live] chat via TP=2: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
            }

            // Without a kept disk the end deletes the pod.
            try await manager.stop(model.id)
            do { _ = try await client.pod(id: podId!); Issue.record("pod still exists after stop without disk") }
            catch let e as RunpodError where e.isNotFound { print("[live] stop without disk: pod deleted (404)") }
            podId = nil
            print("[live] spend counted: \(await manager.state().spendByDay)")
        } catch {
            print("[live] FAILED: \(error)")
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}
