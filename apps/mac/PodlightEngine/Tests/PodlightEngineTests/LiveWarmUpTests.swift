import Foundation
import Testing
@testable import PodlightEngine

// The warm-up on real hardware: llama.cpp on a card the stock image has no finished GPU code for
// (A100 or H100), so the driver compiles it on first use. The watchdog's warm-up must take that
// time while the engine still counts as warming up, a long first request must then be quick, and
// a resumed pod must find the compiled code on its kept disk. Creates the pod itself, on those
// cards only (a start through Podlight may fall back to a card with finished code). Costs real
// money (about 0.30 USD), so it runs only when asked for:
//   PODLIGHT_LIVE_WARMUP=1 RUNPOD_API_KEY=… swift test --filter LiveWarmUp
// Whatever happens, the pod is deleted at the end and RunPod is asked whether it is gone.

private func log(_ message: String) {
    print("[warmup \(Date().formatted(date: .omitted, time: .standard))] \(message)")
    fflush(stdout)
}

@Suite("Live warm-up", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_LIVE_WARMUP"] == "1"
                && ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] != nil))
struct LiveWarmUpTests {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        return URLSession(configuration: config)
    }()

    @Test(.timeLimit(.minutes(45)))
    func warmUpBeforeReadyAndCompiledCodeKeptForResume() async throws {
        let client = RunpodClient(apiKey: ProcessInfo.processInfo.environment["RUNPOD_API_KEY"]!)
        let key = "warmup-\(UUID().uuidString)"
        var podId: String?

        func cleanUp() async {
            guard let podId else { return }
            try? await client.deletePod(id: podId)
            do {
                _ = try await client.pod(id: podId)
                log("WARNING: pod \(podId) still exists; deleting it again")
                try? await client.deletePod(id: podId)
            } catch let e as RunpodError where e.isNotFound {
                log("pod \(podId) is gone at RunPod (404)")
            } catch { log("could not confirm deletion: \(error)") }
        }

        func call(_ port: Int, _ path: String, body: String? = nil) async -> (Int, Data) {
            var request = URLRequest(url: URL(string: "https://\(podId!)-\(port).proxy.runpod.net\(path)")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("Podlight-live-test", forHTTPHeaderField: "User-Agent")
            if let body {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(body.utf8)
            }
            guard let (data, response) = try? await Self.session.data(for: request) else { return (0, Data()) }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }

        func json(_ data: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }

        /// Seconds until the engine first answered, and until the watchdog called it warm.
        func waitWarm(_ label: String) async throws -> (answered: TimeInterval, warm: TimeInterval) {
            let t0 = Date()
            var answeredAt: Date?
            while Date().timeIntervalSince(t0) < 20 * 60 {
                try await Task.sleep(for: .seconds(3))
                let (code, data) = await call(8001, "/status")
                guard code == 200 else { continue }
                let status = json(data)
                if answeredAt == nil, await call(8000, "/v1/models").0 == 200 {
                    answeredAt = Date()
                    log("\(label): engine answers after \(Int(Date().timeIntervalSince(t0))) s, warm: \(status["engineWarm"] ?? "?")")
                }
                if status["engineAlive"] as? Bool == false { break }
                if status["engineWarm"] as? Bool == true, answeredAt != nil { break }
            }
            let answered = answeredAt.map { $0.timeIntervalSince(t0) } ?? -1
            let warm = Date().timeIntervalSince(t0)
            log("\(label): warm after \(Int(warm)) s")
            return (answered, warm)
        }

        func warmUpLine() async -> String? {
            let lines = json(await call(8001, "/log").1)["lines"] as? [String] ?? []
            return lines.last { $0.contains("warm-up") }
        }

        do {
            let info = try await HuggingFaceClient().info("Qwen/Qwen2.5-0.5B-Instruct-GGUF")
            let model = PodlightModel(name: "warmup", repoId: info.repoId, format: info.format, weightBytes: info.weightBytes,
                                      nativeContextTokens: info.nativeContextTokens, toolCallParser: info.toolCallParser,
                                      reasoningParser: info.reasoningParser, contextTokens: 8_192, goal: .economical,
                                      kvProfile: info.kvProfile, keepDisk: true, quant: info.quant)
            // Cards the stock llama.cpp image carries only as PTX: sm_80 (A100) and sm_90 (H100).
            let catalog = try await client.gpuCatalog()
            let jit = GPUSuggestion.options(for: model.info, catalog: catalog, goal: .economical)
                .filter { ($0.choice.gpuId.contains("A100") || $0.choice.gpuId.contains("H100")) && $0.choice.count == 1 && $0.pricePerHour <= 3.0 }
            log("cards: " + jit.map { "\($0.choice.gpuId) \($0.choice.cloud.rawValue) $\($0.pricePerHour)" }.joined(separator: ", "))
            try #require(!jit.isEmpty)
            let request = PodPlan.request(for: model, podKey: key, huggingFaceToken: nil, runUntil: Date().addingTimeInterval(30 * 60),
                                          heartbeatMinutes: 15, dataCenterIds: nil)
            let created = try await client.createPod(request, tryingInOrder: jit.map(\.choice), catalog: catalog)
            podId = created.pod.id
            log("created \(created.pod.id) on \(created.choice.gpuId) \(created.choice.cloud.rawValue)")

            // 1. A new pod: the warm-up compiles the GPU code before the engine counts as warm.
            let first = try await waitWarm("new pod")
            let firstLine = await warmUpLine()
            log("log: \(firstLine ?? "-")")
            #expect(firstLine?.contains("warm-up done") == true)

            // 2. A long first request, as an agent sends it: quick, because the code is compiled.
            let prompt = String(repeating: "Podlight keeps models on rented cards and stops them when idle. ", count: 250)
            let body = String(decoding: try JSONSerialization.data(withJSONObject: ["model": "warmup", "prompt": prompt, "max_tokens": 16]), as: UTF8.self)
            let t1 = Date()
            let (status, _) = await call(8000, "/v1/completions", body: body)
            let firstRequest = Date().timeIntervalSince(t1)
            log("first long request after the warm-up: HTTP \(status) in \(String(format: "%.1f", firstRequest)) s")
            #expect(status == 200 && firstRequest < 15)

            // 3. Stopped and resumed: the compiled code is on the kept disk, the warm-up is short.
            _ = try await client.perform(.stop, onPod: created.pod.id)
            try await Task.sleep(for: .seconds(5))
            _ = try await client.perform(.start, onPod: created.pod.id)
            let second = try await waitWarm("resumed pod")
            let secondLine = await warmUpLine()
            log("log after resume: \(secondLine ?? "-")")
            log("warm-up (engine answering → warm): new pod \(Int(first.warm - first.answered)) s, resumed \(Int(second.warm - second.answered)) s")
            #expect(secondLine?.contains("warm-up done") == true)
        } catch {
            log("FAILED: \(error)")
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}
