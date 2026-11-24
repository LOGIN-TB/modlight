import Foundation
import Testing
@testable import PodlightEngine

// A model handed from this Mac to a Podlight server on real RunPod hardware: started here with a
// kept disk, handed over while it runs, served through the server, stopped and resumed there
// without a new pod, then deleted. Costs real money (well under 0.10 USD), so it runs only when
// asked for, against a server started for it:
//   PODLIGHT_LIVE_E2E=1 RUNPOD_API_KEY=… PODLIGHT_SERVER_URL=http://127.0.0.1:18080 \
//   PODLIGHT_SERVER_CODE=XXXX-XXXX-XXXX swift test --filter LiveHandOver
// Whatever happens, the pod is deleted at the end and RunPod is asked whether it is gone.

private func log(_ message: String) {
    print("[handover \(Date().formatted(date: .omitted, time: .standard))] \(message)")
    fflush(stdout)
}

@Suite("Live hand-over to a server", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_LIVE_E2E"] == "1"
                && ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] != nil
                && ProcessInfo.processInfo.environment["PODLIGHT_SERVER_CODE"] != nil))
struct LiveHandOverTests {
    @Test(.timeLimit(.minutes(45)))
    func handOverServeStopResumeDelete() async throws {
        let env = ProcessInfo.processInfo.environment
        let apiKey = env["RUNPOD_API_KEY"]!
        let serverURL = URL(string: env["PODLIGHT_SERVER_URL"] ?? "http://127.0.0.1:18080")!
        let keychain = KeychainStore(service: "app.podlight.live.\(UUID().uuidString)")
        try keychain.write(apiKey, for: .runpodAPIKey)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-handover-\(UUID()).json")
        let store = StateStore(url: stateURL)
        try await store.update { $0.deviceTag = "live-mac-\(String(format: "%04x", UInt16.random(in: .min ... .max)))" }
        let manager = PodManager(store: store, keychain: keychain)
        let runpod = RunpodClient(apiKey: apiKey)
        var podId: String?
        var modelId: UUID?

        // Pair as a Mac would, and copy the RunPod key over.
        let paired = try await ServerClient(baseURL: serverURL, token: nil).pair(code: env["PODLIGHT_SERVER_CODE"]!, deviceName: "live test")
        let server = ServerClient(baseURL: serverURL, token: paired.token)
        var change = ServerSettingsChange()
        change.runpodApiKey(apiKey)
        _ = try await server.update(change)

        func cleanUp() async {
            if let id = modelId { try? await server.remove(id) }
            if let id = modelId, await manager.state().models.contains(where: { $0.id == id }) { try? await manager.remove(id) }
            if let podId {
                do {
                    _ = try await runpod.pod(id: podId)
                    log("WARNING: pod \(podId) still exists; deleting it directly")
                    try? await runpod.deletePod(id: podId)
                } catch let e as RunpodError where e.isNotFound {
                    log("pod \(podId) is gone at RunPod (404)")
                } catch { log("could not confirm deletion: \(error)") }
            }
            if let id = modelId { try? keychain.delete(.podKey(id)) }
            try? keychain.delete(.runpodAPIKey)
            try? FileManager.default.removeItem(at: stateURL)
        }

        func waitOnServer(_ id: UUID, for phase: RunPhase, minutes: Double) async throws -> ModelRun {
            let t0 = Date()
            var run = ModelRun()
            while Date().timeIntervalSince(t0) < minutes * 60 {
                run = try await server.state().run(id)
                if run.phase == phase || run.phase == .failed { break }
                try await Task.sleep(for: .seconds(10))
            }
            log("server: \(run.phase) after \(Int(Date().timeIntervalSince(t0)))s (\(run.lastReason ?? "-"))")
            return run
        }

        do {
            // 1. On this Mac: a tiny model with a kept disk, started and ready.
            let info = try await HuggingFaceClient().info("Qwen/Qwen2.5-0.5B-Instruct")
            var model = PodlightModel(name: "qwen-handover", repoId: info.repoId, format: info.format, weightBytes: info.weightBytes,
                                      nativeContextTokens: info.nativeContextTokens, toolCallParser: info.toolCallParser,
                                      reasoningParser: info.reasoningParser, contextTokens: 8_192, goal: .economical, keepDisk: true)
            let catalog = try await runpod.gpuCatalog()
            let options = GPUSuggestion.options(for: model.info, catalog: catalog, goal: .economical).filter { $0.pricePerHour <= 0.4 }
            model.preferredGPU = options.first?.choice
            try await manager.save(model)
            modelId = model.id
            let t0 = Date()
            try await manager.start(model.id, until: Date().addingTimeInterval(30 * 60))
            var run = await manager.state().run(model.id)
            podId = run.podId
            log("Mac created pod \(run.podId ?? "?") on \(run.gpuName ?? "?") at $\(run.pricePerHour ?? 0)/h")
            while Date().timeIntervalSince(t0) < 25 * 60 {
                try await Task.sleep(for: .seconds(15))
                await manager.refresh(model.id)
                run = await manager.state().run(model.id)
                if run.phase == .ready || run.phase == .failed || run.phase == .stopped { break }
            }
            log("Mac: \(run.phase) after \(Int(Date().timeIntervalSince(t0)))s")
            try #require(run.phase == .ready)
            await manager.syncRecords(force: true)
            #expect(try await runpod.listTemplates().contains { $0.name.hasPrefix("podlight-model-qwen-handover@") })

            // 2. Hand it over while it runs.
            try await manager.handOver(model.id, toServer: "live") { m, key, pod in
                try await server.adopt(m, podKey: key, podId: pod)
            }
            #expect(await manager.state().models.isEmpty)
            let renamed = try await runpod.pod(id: podId!)
            log("after hand-over the pod is called \(renamed.name), \(renamed.status)")
            #expect(renamed.name == "podlight-srv-qwen-handover" && renamed.status == .running)
            #expect(try await !runpod.listTemplates().contains { $0.name.hasPrefix("podlight-model-qwen-handover@") })
            let onServer = try await waitOnServer(model.id, for: .ready, minutes: 5)
            #expect(onServer.phase == .ready && onServer.podId == podId && onServer.lastHeartbeatAt != nil)

            // 3. Served through the server with an access key.
            let token = try await server.createClientToken(name: "live", models: nil)
            var chat = URLRequest(url: serverURL.appendingPathComponent("v1/chat/completions"))
            chat.httpMethod = "POST"
            chat.timeoutInterval = 120
            chat.setValue("Bearer \(token.token ?? "")", forHTTPHeaderField: "Authorization")
            chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
            chat.httpBody = Data(#"{"model":"qwen-handover","max_tokens":20,"messages":[{"role":"user","content":"Say hello."}]}"#.utf8)
            let (answer, response) = try await URLSession.shared.data(for: chat)
            log("chat through the server: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(String(decoding: answer, as: UTF8.self).prefix(160))")
            #expect((response as? HTTPURLResponse)?.statusCode == 200)

            // 4. Stopped and resumed by the server: the same pod, the model already on its disk.
            try await server.stop(model.id)
            #expect(try await runpod.pod(id: podId!).status == .exited)
            let t1 = Date()
            try await server.start(model.id, until: Date().addingTimeInterval(15 * 60))
            let resumed = try await waitOnServer(model.id, for: .ready, minutes: 12)
            log("resume on the server took \(Int(Date().timeIntervalSince(t1)))s, pod \(resumed.podId ?? "?"), resumed: \(resumed.resumed == true)")
            #expect(resumed.phase == .ready && resumed.podId == podId)
        } catch {
            log("FAILED: \(error)")
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}
