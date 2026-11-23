import Foundation
import Testing
@testable import PodlightEngine

// Writes the spec cases that the server (and later Windows) must reproduce, from what the Swift
// engine does today: card suggestions, the pod request, hosting rules and the gateway's rewrites
// and error codes. Runs only with PODLIGHT_RECORD_SPEC=1:
//
//     PODLIGHT_RECORD_SPEC=1 swift test --filter SpecRecorder
//
// Recording is a one-time act per rule. Once a file is in `spec/cases`, its expected values are
// the contract and are never regenerated to make a change pass; a deliberate rule change edits
// the case by hand, with the reason in its title.

enum SpecFixture {
    static let catalogURL = Spec.root.appendingPathComponent("fixtures/catalog.json")

    static func catalog() throws -> [RunpodGPUType] {
        try JSONDecoder().decode(RunpodGPUCatalog.self, from: Data(contentsOf: catalogURL)).gpus
    }

    static let created = Date(timeIntervalSince1970: 1_763_683_200) // 2025-11-21T00:00:00Z
    static let schedule = Schedule(enabled: false, timezone: "Europe/Berlin", weekdays: [1, 2, 3, 4, 5],
                                   startAt: "08:00", stopAt: "18:00", idleStopMinutes: 30, maxRuntimeHours: 12)

    static func model(_ id: Int, name: String, repo: String, format: WeightFormat, gb: Double, native: Int?,
                      context: Int, concurrency: Int = 1, goal: SuggestionGoal = .balanced,
                      kv: KVProfile? = nil, tool: String? = nil, reasoning: String? = nil,
                      preferred: GPUChoice? = nil, keepDisk: Bool = false, hosting: HostingPolicy? = nil,
                      quant: String? = nil) -> PodlightModel {
        PodlightModel(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!, name: name, repoId: repo,
                      format: format, weightBytes: gb * 1e9, nativeContextTokens: native, toolCallParser: tool,
                      reasoningParser: reasoning, contextTokens: context, concurrency: concurrency, goal: goal,
                      preferredGPU: preferred, schedule: schedule, createdAt: created, kvProfile: kv, keepDisk: keepDisk,
                      hosting: hosting, preferredGPUName: nil, quant: quant)
    }

    static let models: [PodlightModel] = [
        model(1, name: "qwen-27b-awq", repo: "QuantTrio/Qwen3.8-27B-AWQ", format: .awq, gb: 19.0, native: 262_144,
              context: 65_536, kv: KVProfile(bytesPerToken: 65_536, attentionHeads: 24, hybrid: false),
              tool: "qwen3_xml", reasoning: "qwen3"),
        model(2, name: "qwen-27b-fp8", repo: "Qwen/Qwen3.8-27B-FP8", format: .fp8, gb: 30.6, native: 262_144,
              context: 32_768, goal: .fast, kv: KVProfile(bytesPerToken: 65_536, attentionHeads: 24, hybrid: false),
              tool: "qwen3_xml", reasoning: "qwen3"),
        model(3, name: "coder-30b-gguf", repo: "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF", format: .gguf, gb: 18.6,
              native: 262_144, context: 131_072, concurrency: 2, kv: KVProfile(bytesPerToken: 98_304, attentionHeads: 32, hybrid: false),
              quant: "Q4_K_M"),
        model(4, name: "tiny", repo: "Qwen/Qwen2.5-0.5B-Instruct", format: .safetensors, gb: 0.99, native: 32_768,
              context: 8_192, goal: .economical, tool: "hermes"),
        model(5, name: "llama-70b-awq", repo: "casperhansen/llama-3.3-70b-instruct-awq", format: .awq, gb: 39.8,
              native: 131_072, context: 131_072, kv: KVProfile(bytesPerToken: 327_680, attentionHeads: 64, hybrid: false),
              tool: "hermes"),
        model(6, name: "odd-heads", repo: "example/odd-heads-32b", format: .safetensors, gb: 64.0, native: 131_072,
              context: 65_536, kv: KVProfile(bytesPerToken: 131_072, attentionHeads: 28, hybrid: true)),
    ]

    static let policies: [(String, HostingPolicy)] = [
        ("anywhere", .anywhere),
        ("secure", HostingPolicy(region: .anywhere, secureOnly: true)),
        ("eu", HostingPolicy(region: .eu, secureOnly: true)),
        ("euEEA", HostingPolicy(region: .euEEA, secureOnly: true)),
    ]
}

private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
}()

private func json<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
}

private func optional<T: Encodable>(_ value: T?) throws -> Any { try value.map(json) ?? NSNull() }

/// The placeholder spec cases use for the embedded pod scripts, so the cases stay readable.
enum PodScriptMarker {
    static let watchdog = "<base64 of spec/pod/watchdog.py>"
    static let boot = "<base64 of spec/pod/boot.sh>"
}

private struct CaseFile {
    var name: String
    var description: String
    var cases: [[String: Any]] = []

    mutating func add(_ id: String, _ title: String, _ function: String, input: Any, expected: Any) {
        cases.append(["id": id, "title": title, "function": function, "input": input, "expected": expected])
    }

    func write() throws {
        let doc: [String: Any] = ["description": description, "recordedFrom": "Swift engine (PodlightEngine), Podlight 0.3.2", "cases": cases]
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: Spec.root.appendingPathComponent("cases/\(name)"))
    }
}

@Suite("SpecRecorder", .enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_RECORD_SPEC"] == "1"))
struct SpecRecorder {
    @Test func recordGpuSuggestions() throws {
        let catalog = try SpecFixture.catalog()
        var file = CaseFile(name: "gpu-suggest.json", description: """
            Which cards Podlight offers for a model, best first for the model's goal; also the fallback order when a \
            pod is created. Input: a model (spec/schema/model.json), the catalog fixture, a hosting policy. Expected: \
            the options in order. Compare numbers with a relative tolerance of 1e-9.
            """)
        for model in SpecFixture.models {
            for (policyName, policy) in SpecFixture.policies {
                for goal in SuggestionGoal.allCases where goal == model.goal || policyName == "anywhere" {
                    let options = GPUSuggestion.options(for: model.info, catalog: catalog, goal: goal, context: model.contextTokens,
                                                        concurrency: model.concurrency, hosting: policy)
                    let expected: [[String: Any]] = try options.map { o in
                        ["choice": try json(o.choice), "pricePerHour": o.pricePerHour,
                         "estimatedTokensPerSecond": o.estimatedTokensPerSecond.map { $0 as Any } ?? NSNull(),
                         "contextTokens": o.contextTokens, "contextCeiling": o.contextCeiling, "dataCenters": o.dataCenters]
                    }
                    file.add("\(model.name)-\(policyName)-\(goal.rawValue)",
                             "\(model.name), \(policyName), goal \(goal.rawValue)", "gpuOptions",
                             input: ["model": try json(model), "catalog": "fixtures/catalog.json", "goal": goal.rawValue,
                                     "context": model.contextTokens, "concurrency": model.concurrency, "hosting": try json(policy)],
                             expected: expected)
                }
            }
        }
        try file.write()
    }

    @Test func recordPodPlans() throws {
        let catalog = try SpecFixture.catalog()
        var file = CaseFile(name: "pod-plan.json", description: """
            The pod Podlight asks RunPod for, and the order of cards it tries. `podRequest` expects the request body \
            (CreatePodRequest; absent optional fields are left out) with the two base64 pod scripts replaced by \
            markers, plus disk sizes and the storage cost per hour. `podChoices` expects the cards tried in order.
            """)
        let until = ISO8601DateFormatter().date(from: "2026-11-21T18:00:00Z")!
        let variants: [(String, PodlightModel, String?, Date?, [String]?)] = [
            ("awq-plain", SpecFixture.models[0], nil, nil, nil),
            ("awq-until-token", SpecFixture.models[0], "hf_test", until, nil),
            ("fp8-keep-disk", { var m = SpecFixture.models[1]; m.keepDisk = true
                                m.preferredGPU = GPUChoice(gpuId: "NVIDIA L40S", cloud: .secure, count: 1); return m }(), nil, until, nil),
            ("gguf-two-slots", { var m = SpecFixture.models[2]
                                 m.preferredGPU = GPUChoice(gpuId: "NVIDIA RTX A6000", cloud: .community, count: 2); return m }(), nil, nil, nil),
            ("gguf-keep-disk-eu", { var m = SpecFixture.models[2]; m.keepDisk = true
                                    m.hosting = HostingPolicy(region: .eu, secureOnly: true); return m }(), "hf_test", until, ["EU-RO-1", "EU-SE-1"]),
            ("70b-four-cards", { var m = SpecFixture.models[4]
                                 m.preferredGPU = GPUChoice(gpuId: "NVIDIA L40S", cloud: .secure, count: 4); return m }(), nil, nil, nil),
        ]
        for (id, model, token, runUntil, centers) in variants {
            var request = PodPlan.request(for: model, podKey: "POD_KEY", huggingFaceToken: token, runUntil: runUntil,
                                          heartbeatMinutes: 15, dataCenterIds: centers)
            request.env["PODLIGHT_WATCHDOG_B64"] = PodScriptMarker.watchdog
            request.env["PODLIGHT_BOOT_B64"] = PodScriptMarker.boot
            file.add(id, "Pod request for \(id)", "podRequest",
                     input: ["model": try json(model), "podKey": "POD_KEY", "huggingFaceToken": token as Any? ?? NSNull(),
                             "runUntil": runUntil.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull(),
                             "heartbeatMinutes": 15, "dataCenterIds": centers as Any? ?? NSNull()],
                     expected: ["request": try json(request), "persistentGB": PodPlan.persistentGB(for: model),
                                "containerGB": PodPlan.containerGB(for: model), "storagePerHour": PodPlan.storagePerHour(for: model)])
        }

        let choiceVariants: [(String, PodlightModel, HostingPolicy)] = [
            ("no-preference", SpecFixture.models[0], .anywhere),
            ("preferred-first", { var m = SpecFixture.models[0]
                                  m.preferredGPU = GPUChoice(gpuId: "NVIDIA H100 80GB HBM3", cloud: .community, count: 1); return m }(), .anywhere),
            ("preferred-not-in-suggestions", { var m = SpecFixture.models[0]
                                               m.preferredGPU = GPUChoice(gpuId: "NVIDIA H200", cloud: .secure, count: 1); return m }(), .anywhere),
            ("community-preference-under-eu", { var m = SpecFixture.models[0]
                                                m.preferredGPU = GPUChoice(gpuId: "NVIDIA GeForce RTX 4090", cloud: .community, count: 1); return m }(),
             HostingPolicy(region: .eu, secureOnly: true)),
            ("gguf-anywhere", SpecFixture.models[2], .anywhere),
            ("70b-anywhere", SpecFixture.models[4], .anywhere),
            ("odd-heads", SpecFixture.models[5], .anywhere),
            ("tiny-limit-six", SpecFixture.models[3], .anywhere),
        ]
        for (id, model, policy) in choiceVariants {
            let choices = PodPlan.choices(for: model, catalog: catalog, hosting: policy)
            file.add(id, "Cards tried for \(id)", "podChoices",
                     input: ["model": try json(model), "catalog": "fixtures/catalog.json", "hosting": try json(policy)],
                     expected: try json(choices))
        }
        try file.write()
    }

    @Test func recordHosting() throws {
        let catalog = try SpecFixture.catalog()
        var file = CaseFile(name: "hosting.json", description: """
            Where a pod may run (spec/data/regions.json) and what its disks cost. A region always means Secure Cloud, \
            because community pods report no data center.
            """)
        let centers: [String?] = ["EU-RO-1", "EU-SE-1", "EUR-IS-1", "EUR-NO-2", "US-TX-3", "CA-MTL-1", "EUROPE-1", nil]
        for (name, policy) in SpecFixture.policies {
            file.add("clouds-\(name)", "Clouds for \(name)", "hostingClouds", input: ["hosting": try json(policy)],
                     expected: try json(policy.clouds))
            file.add("placement-check-\(name)", "Placement check for \(name)", "needsPlacementCheck",
                     input: ["hosting": try json(policy)], expected: policy.needsPlacementCheck)
            for center in centers {
                file.add("allows-\(name)-\(center ?? "none")", "\(name) allows \(center ?? "no data center")?", "hostingAllows",
                         input: ["hosting": try json(policy), "dataCenterId": center as Any? ?? NSNull()],
                         expected: policy.allows(dataCenterId: center))
            }
            for gpu in catalog {
                file.add("capacity-\(name)-\(gpu.id)", "\(gpu.id) may be free under \(name)?", "mayHaveCapacity",
                         input: ["hosting": try json(policy), "catalog": "fixtures/catalog.json", "gpuId": gpu.id],
                         expected: policy.mayHaveCapacity(gpu))
            }
            file.add("data-centers-\(name)", "Data centers requested under \(name)", "dataCenterIds",
                     input: ["hosting": try json(policy), "catalog": "fixtures/catalog.json"],
                     expected: policy.dataCenterIds(in: catalog) as Any? ?? NSNull())
        }
        for (container, volume) in [(30, 0), (42, 0), (30, 32), (100, 250)] {
            file.add("storage-\(container)-\(volume)", "Storage for \(container) GB container, \(volume) GB volume", "storagePricing",
                     input: ["containerGB": container, "volumeGB": volume],
                     expected: ["runningPerHour": StoragePricing.runningPerHour(containerGB: container, volumeGB: volume),
                                "stoppedPerMonth": StoragePricing.stoppedPerMonth(volumeGB: volume)])
        }
        try file.write()
    }

    @Test func recordGateway() throws {
        var file = CaseFile(name: "gateway.json", description: """
            What the gateway changes and says. `systemMessagesAsReminders` (Anthropic Messages API only): expected is \
            the rewritten body, or null when the body must be forwarded unchanged. `gatewayError`: status and code \
            (OpenAI shape) or error type (Anthropic shape); the message text may differ per implementation. \
            `isValidName`: the served-name rule. `summarizeEngineLog`: the lines shown when an engine dies.
            """)
        let bodies: [(String, String)] = [
            ("no-system", #"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#),
            ("system-string", #"{"model":"m","system":[{"type":"text","text":"top"}],"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]},{"role":"system","content":"Environment"},{"role":"assistant","content":"ok"}]}"#),
            ("system-blocks", #"{"model":"m","messages":[{"role":"user","content":"a"},{"role":"system","content":[{"type":"text","text":"one"},{"type":"text","text":"two"},{"type":"image"}]}]}"#),
            ("system-empty", #"{"model":"m","messages":[{"role":"system"},{"role":"user","content":"a"}]}"#),
            ("no-messages", #"{"model":"m","prompt":"x"}"#),
        ]
        for (id, body) in bodies {
            let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
            file.add("reminders-\(id)", "System entries in messages: \(id)", "systemMessagesAsReminders",
                     input: ["body": object], expected: LocalGateway.systemMessagesAsReminders(object) ?? NSNull())
        }

        let errors: [(String, PodlightError, [String: Any])] = [
            ("unknown-model", .unknownModel("x"), ["kind": "unknownModel"]),
            ("setup", .missingRunpodKey, ["kind": "missingRunpodKey"]),
            ("daily", .limitReached("daily-limit"), ["kind": "limitReached", "limit": "daily-limit"]),
            ("monthly", .limitReached("monthly-limit"), ["kind": "limitReached", "limit": "monthly-limit"]),
            ("capacity", .noCapacity(["NVIDIA L40S"]), ["kind": "noCapacity", "tried": ["NVIDIA L40S"]]),
            ("no-card", .noSuitableCard, ["kind": "noSuitableCard"]),
            ("not-ready", .notReadyInTime, ["kind": "notReadyInTime"]),
            ("wake-off", .wakeDisabled, ["kind": "wakeDisabled"]),
            ("runpod", .runpod(status: 500, message: "boom"), ["kind": "runpod", "status": 500, "message": "boom"]),
        ]
        for (id, error, input) in errors {
            for anthropic in [false, true] {
                let failure = LocalGateway.failure(for: error, model: "m")
                var expected: [String: Any] = ["status": failure.status]
                if anthropic { expected["type"] = LocalGateway.anthropicType(failure.status) } else { expected["code"] = failure.code }
                file.add("error-\(id)-\(anthropic ? "anthropic" : "openai")", "Error \(id), \(anthropic ? "Anthropic" : "OpenAI") shape",
                         "gatewayError", input: ["error": input, "model": "m", "anthropic": anthropic], expected: expected)
            }
        }

        for name in ["qwen3-coder-30b", "a", "a.b_c-d", "Qwen3", "-lead", "with/slash", "with space", "", String(repeating: "x", count: 63), String(repeating: "x", count: 64), "ümlaut"] {
            file.add("name-\(name.isEmpty ? "empty" : name.count > 20 ? "len\(name.count)" : name)", "Served name \"\(name)\"", "isValidName",
                     input: ["name": name], expected: PodlightModel.isValidName(name))
        }

        let logs: [(String, [String])] = [
            ("oom", ["INFO loading", "torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 2.00 GiB", "INFO shutting down"]),
            ("none", ["line 1", "line 2", "line 3", "line 4"]),
            ("llama", ["llama_model_load: error loading model: tensor shape mismatch", "srv main: exiting"]),
            ("many-errors", ["Error a", "  Error b  ", "Traceback (most recent call last):", "ValueError: bad", "INFO end"]),
            // vLLM's engine in its own process: the API server only points back at it.
            ("root-cause-above", [
                "(EngineCore_DP0 pid=120) ERROR 11-23 13:05:01 [core.py:708] EngineCore failed to start.",
                "(EngineCore_DP0 pid=120) ERROR 11-23 13:05:01 [core.py:708] Traceback (most recent call last):",
                "(EngineCore_DP0 pid=120) ERROR 11-23 13:05:01 [core.py:708] ValueError: To serve at least one request with the model's max seq len (262144), 12.5 GiB KV cache is needed, which is larger than the available KV cache memory (9.8 GiB).",
                "(APIServer pid=68) Traceback (most recent call last):",
                "(APIServer pid=68)     raise RuntimeError(",
                "(APIServer pid=68) RuntimeError: Engine core initialization failed. See root cause above. Failed core proc(s): {}",
            ]),
        ]
        for (id, lines) in logs {
            file.add("log-\(id)", "Engine log summary: \(id)", "summarizeEngineLog", input: ["lines": lines],
                     expected: PodManager.summarizeEngineLog(lines))
        }

        // The start test: an answer of one or two repeated characters means a broken model.
        let answers: [(String, String)] = [
            ("bangs", String(repeating: "!", count: 48)),
            ("ready", "ready"),
            ("ready-sentence", "Ready. I am here and listening!"),
            ("short-repeat", "!!!!!!"),
            ("two-chars", String(repeating: "?!", count: 20)),
            ("spaces", String(repeating: "! ", count: 30)),
            ("three-chars", String(repeating: "abc", count: 10)),
            ("empty", ""),
        ]
        for (id, text) in answers {
            file.add("degenerate-\(id)", "Start test answer: \(id)", "looksDegenerate", input: ["text": text],
                     expected: PodManager.looksDegenerate(text))
        }
        try file.write()
    }
}
