import Foundation
import Testing
@testable import PodlightEngine

private let gib = 1_073_741_824.0

private func model(weightsGB: Double, native: Int? = 262_144, format: WeightFormat = .awq, context: Int = 65_536,
                   name: String = "qwen-test", preferred: GPUChoice? = nil) -> PodlightModel {
    PodlightModel(name: name, repoId: "Org/Qwen-Test-AWQ", format: format, weightBytes: weightsGB * 1_000_000_000,
                  nativeContextTokens: native, toolCallParser: "qwen3_xml", reasoningParser: "qwen3",
                  contextTokens: context, preferredGPU: preferred)
}

private func gpu(_ id: String, memory: Int, secure: Double? = nil, community: Double? = nil,
                 availability: String = "LOW") throws -> RunpodGPUType {
    let json: [String: Any] = [
        "id": id, "name": id.replacingOccurrences(of: "NVIDIA ", with: ""), "manufacturer": "NVIDIA", "memory": memory,
        "secure": secure != nil, "community": community != nil,
        "price": ["secure": secure ?? 0, "community": community ?? 0], "availability": availability,
    ]
    return try RunpodClient.decoder.decode(RunpodGPUType.self, from: JSONSerialization.data(withJSONObject: json))
}

@Suite("GPU suggestion")
struct GPUSuggestionTests {
    let catalog: [RunpodGPUType]

    init() throws {
        catalog = [
            try gpu("NVIDIA GeForce RTX 3090", memory: 24, secure: 0.46, community: 0.22),
            try gpu("NVIDIA L40S", memory: 48, secure: 0.86, community: 0.79),
            try gpu("NVIDIA RTX A6000", memory: 48, secure: 0.49, community: 0.33),
            try gpu("NVIDIA H100 80GB HBM3", memory: 80, secure: 2.69),
            try gpu("NVIDIA RTX A2000", memory: 6, community: 0.12),
            try gpu("NVIDIA A40", memory: 48, secure: 0.40, availability: "NONE"),
        ]
    }

    @Test func aModelThatDoesNotFitIsNeverSuggestedOnThatCard() {
        // 21 GB of weights: too much for 6 GB, and on 24 GB too little room is left for context.
        let options = GPUSuggestion.options(for: model(weightsGB: 21).info, catalog: catalog, goal: .balanced)
        #expect(!options.contains { $0.choice.gpuId == "NVIDIA RTX A2000" })
        #expect(!options.contains { $0.choice.gpuId == "NVIDIA GeForce RTX 3090" })
        #expect(options.contains { $0.choice.gpuId == "NVIDIA L40S" })
    }

    @Test func cardsWithNoneAvailableAreLeftOut() {
        let options = GPUSuggestion.options(for: model(weightsGB: 19).info, catalog: catalog, goal: .economical)
        #expect(!options.contains { $0.choice.gpuId == "NVIDIA A40" })
    }

    @Test func economicalPutsTheCheapestFirstAndFastPutsTheFastestFirst() {
        let info = model(weightsGB: 21).info
        let cheap = GPUSuggestion.options(for: info, catalog: catalog, goal: .economical)
        let fast = GPUSuggestion.options(for: info, catalog: catalog, goal: .fast)
        #expect(cheap.first?.choice == GPUChoice(gpuId: "NVIDIA RTX A6000", cloud: .community))
        #expect(fast.first?.choice.gpuId == "NVIDIA H100 80GB HBM3")
        #expect(cheap.map(\.pricePerHour) == cheap.map(\.pricePerHour).sorted())
    }

    @Test func balancedPrefersAComfortableSpeedOverTheCheapestCard() throws {
        let options = GPUSuggestion.options(for: model(weightsGB: 19).info, catalog: catalog, goal: .balanced)
        let first = try #require(options.first)
        #expect((first.estimatedTokensPerSecond ?? 0) >= GPUSuggestion.comfortableTokensPerSecond)
    }

    @Test func speedEstimateMatchesTheCalibration() throws {
        // L40S with 19 GB of INT4 weights was measured at 41 tok/s; the estimate stays below that.
        let estimate = try #require(GPUSpeedTable.bundled.tokensPerSecond(gpuId: "NVIDIA L40S", weightsGB: 19))
        #expect(estimate > 20 && estimate < 41)
        // The RTX PRO 4500 was measured far below its bandwidth; the table says so.
        let pro = try #require(GPUSpeedTable.bundled.tokensPerSecond(gpuId: "NVIDIA RTX PRO 4500 Blackwell", weightsGB: 19))
        #expect(pro < 10)
    }

    @Test func fp8NeedsACardThatRunsIt() {
        let options = GPUSuggestion.options(for: model(weightsGB: 30, format: .fp8).info, catalog: catalog, goal: .economical)
        #expect(!options.contains { $0.choice.gpuId == "NVIDIA RTX A6000" })
        #expect(options.contains { $0.choice.gpuId == "NVIDIA L40S" })
    }

    @Test func bundledTableIsTheSpecTable() throws {
        let spec = try Data(contentsOf: Spec.root.appendingPathComponent("data/gpus.json"))
        let bundled = try Data(contentsOf: #require(Bundle.module.url(forResource: "gpus", withExtension: "json", subdirectory: nil))
                               ?? Bundle(for: BundleToken.self).url(forResource: "gpus", withExtension: "json")!)
        #expect(spec == bundled, "copy spec/data/gpus.json to Sources/PodlightEngine/Resources/gpus.json")
    }
}

private final class BundleToken {}

@Suite("Hugging Face rules")
struct HuggingFaceRuleTests {
    @Test(arguments: [
        ("Qwen/Qwen3-8B", "Qwen/Qwen3-8B"),
        ("https://huggingface.co/Qwen/Qwen3-8B", "Qwen/Qwen3-8B"),
        ("https://huggingface.co/Qwen/Qwen3-8B/tree/main", "Qwen/Qwen3-8B"),
        ("  RedHatAI/Qwen3.8-27B-INT4 \n", "RedHatAI/Qwen3.8-27B-INT4"),
    ])
    func readsRepoIdsFromWhatPeoplePaste(input: String, expected: String) {
        #expect(HuggingFaceClient.repoId(fromUserInput: input) == expected)
    }

    @Test func rejectsWhatIsNotARepo() {
        #expect(HuggingFaceClient.repoId(fromUserInput: "qwen") == nil)
        #expect(HuggingFaceClient.repoId(fromUserInput: "https://example.com/a/b") == nil)
    }

    @Test func detectsFormats() {
        #expect(HuggingFaceClient.detectFormat(repoId: "a/b", filenames: ["m-Q4_K_M.gguf"], quantization: nil) == .gguf)
        #expect(HuggingFaceClient.detectFormat(repoId: "mlx-community/x-mlx", filenames: [], quantization: nil) == .mlx)
        #expect(HuggingFaceClient.detectFormat(repoId: "a/b", filenames: ["x.safetensors"], quantization: ["quant_method": "awq"]) == .awq)
        let nvfp4: [String: Any] = ["quant_method": "compressed-tensors",
                                    "config_groups": ["g": ["weights": ["num_bits": 4, "type": "float"]]]]
        #expect(HuggingFaceClient.detectFormat(repoId: "a/b", filenames: ["x.safetensors"], quantization: nvfp4) == .nvfp4)
        let int4: [String: Any] = ["quant_method": "compressed-tensors", "config_groups": ["g": ["weights": ["num_bits": 4, "type": "int"]]]]
        #expect(HuggingFaceClient.detectFormat(repoId: "a/b", filenames: ["x.safetensors"], quantization: int4) == .awq)
        #expect(HuggingFaceClient.detectFormat(repoId: "a/b-FP8", filenames: ["x.safetensors"], quantization: nil) == .fp8)
        #expect(HuggingFaceClient.detectFormat(repoId: "a/b", filenames: ["x.safetensors"], quantization: nil) == .safetensors)
    }

    @Test func toolParserComesFromTheTemplateNotTheName() {
        #expect(HuggingFaceClient.toolCallParser(chatTemplate: nil) == nil)
        #expect(HuggingFaceClient.toolCallParser(chatTemplate: "no tools here") == nil)
        #expect(HuggingFaceClient.toolCallParser(chatTemplate: "<tool_call>{json}</tool_call>") == "hermes")
        #expect(HuggingFaceClient.toolCallParser(chatTemplate: "<tool_call><function=x><parameter=y>") == "qwen3_xml")
        #expect(HuggingFaceClient.reasoningParser(chatTemplate: "<think>") == "qwen3")
    }

    @Test func servedNamesAreSafe() {
        #expect(PodlightModel.suggestedName(for: "RedHatAI/Qwen3.8-27B-INT4") == "qwen3.8-27b-int4")
        #expect(PodlightModel.isValidName("qwen3.8-27b-int4"))
        #expect(!PodlightModel.isValidName("Qwen 3"))
    }
}

@Suite("Pod plan")
struct PodPlanTests {
    @Test func startsTheStockImageWithPodlightsScriptAndAKeptDisk() throws {
        var m = model(weightsGB: 19)
        m.keepDisk = true
        let request = PodPlan.request(for: m, podKey: "pod-secret", huggingFaceToken: "hf_x",
                                      runUntil: Date(timeIntervalSince1970: 1_000_000), heartbeatMinutes: 15)
        #expect(request.image == PodPlan.image)
        #expect(request.entrypoint == ["/bin/bash", "-c"])
        #expect(request.ports == ["8000/http", "8001/http"])
        #expect(request.mounts?.persistent?.size == PodPlan.persistentGB(for: m))
        #expect(request.env["PODLIGHT_SERVED_NAME"] == "qwen-test")
        #expect(request.env["PODLIGHT_TOOL_PARSER"] == "qwen3_xml")
        #expect(request.env["HF_TOKEN"] == "hf_x")
        #expect(request.env["HF_HOME"] == "/workspace/hf")
        #expect(request.env["PODLIGHT_DEADLINE"] == String(1_000_000 + 600))
        // The script that runs is the one bundled with this build.
        let boot = try #require(request.env["PODLIGHT_BOOT_B64"].flatMap { Data(base64Encoded: $0) })
        #expect(String(decoding: boot, as: UTF8.self).contains("vllm serve"))
        let watchdog = try #require(request.env["PODLIGHT_WATCHDOG_B64"].flatMap { Data(base64Encoded: $0) })
        #expect(String(decoding: watchdog, as: UTF8.self).contains("/v2/pods/{POD_ID}/action"))
    }

    @Test func fallbackCardsMustHoldTheConfiguredContext() throws {
        let catalog = [
            try gpu("NVIDIA L40S", memory: 48, secure: 0.86),
            try gpu("NVIDIA GeForce RTX 4090", memory: 24, community: 0.34),
            try gpu("NVIDIA H100 80GB HBM3", memory: 80, secure: 2.69),
        ]
        // 19 GB weights, 131k context: does not fit on 24 GB, fits on 48 and 80.
        let m = model(weightsGB: 19, context: 131_072, preferred: GPUChoice(gpuId: "NVIDIA H100 80GB HBM3", cloud: .secure))
        let choices = PodPlan.choices(for: m, catalog: catalog)
        #expect(choices.first == GPUChoice(gpuId: "NVIDIA H100 80GB HBM3", cloud: .secure))
        #expect(!choices.contains { $0.gpuId == "NVIDIA GeForce RTX 4090" })
        #expect(choices.contains { $0.gpuId == "NVIDIA L40S" })
    }
}

@Suite("Engine image requirements")
struct EngineImageTests {
    private func card(_ id: String, cuda: [(String, Bool)]?) throws -> RunpodGPUType {
        var json: [String: Any] = ["id": id, "name": id, "manufacturer": "NVIDIA", "memory": 48, "secure": true,
                                   "community": false, "price": ["secure": 0.5], "availability": "LOW"]
        if let cuda { json["cudaVersions"] = cuda.map { ["version": $0.0, "available": $0.1] } }
        return try RunpodClient.decoder.decode(RunpodGPUType.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func voltaCardsCannotRunTheImage() {
        #expect(!CardSupport.runsEngineImage("Tesla V100-SXM2-16GB"))
        #expect(CardSupport.runsEngineImage("NVIDIA RTX A2000"))
        #expect(CardSupport.runsEngineImage("NVIDIA L40S"))
    }

    @Test func onlyCardsWithAFreeCuda13HostAreSuggested() throws {
        let catalog = [
            try card("NVIDIA L40S", cuda: [("12.4", true), ("13.2", false)]),
            try card("NVIDIA RTX A6000", cuda: [("12.4", false), ("13.0", true)]),
            try card("NVIDIA A40", cuda: nil),
        ]
        let model = PodlightModel(name: "m", repoId: "o/m", format: .awq, weightBytes: 10e9, nativeContextTokens: 65_536,
                                  toolCallParser: nil, reasoningParser: nil, contextTokens: 32_768)
        let ids = Set(GPUSuggestion.options(for: model.info, catalog: catalog, goal: .economical).map(\.choice.gpuId))
        #expect(ids == ["NVIDIA RTX A6000", "NVIDIA A40"])
    }

    @Test func theRequestAsksForACuda13Host() {
        let model = PodlightModel(name: "m", repoId: "o/m", format: .awq, weightBytes: 10e9, nativeContextTokens: nil,
                                  toolCallParser: nil, reasoningParser: nil, contextTokens: 32_768)
        let request = PodPlan.request(for: model, podKey: "k", huggingFaceToken: nil, runUntil: nil, heartbeatMinutes: 15)
        #expect(request.gpu.minCudaVersion == "13.0")
    }

    @Test func versionsCompareNumerically() {
        #expect(RunpodGPUType.compare("13.10", "13.2") == 1)
        #expect(RunpodGPUType.compare("12.9", "13.0") == -1)
        #expect(RunpodGPUType.compare("13.0", "13") == 0)
    }
}

@Suite("Context, KV cache and several cards")
struct ContextAndCardsTests {
    /// The relevant fields of RedHatAI/Qwen3.8-27B-INT4's config.json (read 2026-11-21).
    nonisolated(unsafe) static let qwen38: [String: Any] = [
        "text_config": ["num_hidden_layers": 64, "num_attention_heads": 24, "num_key_value_heads": 4, "head_dim": 256,
                        "hidden_size": 5120, "full_attention_interval": 4,
                        "layer_types": Array(repeating: ["linear_attention", "linear_attention", "linear_attention", "full_attention"], count: 16).flatMap { $0 }],
    ]

    @Test func hybridModelsMatchTheMeasurement() throws {
        // Measured on an L40S: 134,106 tokens in 10.58 GiB = 82.8 KiB per token.
        let profile = try #require(KVProfile.from(config: Self.qwen38))
        #expect(profile.hybrid)
        #expect(abs(profile.bytesPerToken / 1024 - 82.8) < 1.5)
        #expect(profile.attentionHeads == 24)
    }

    @Test func standardModelsUseTheExactFormula() throws {
        // Qwen3-8B: 36 layers × 8 KV heads × 128 × 2 (K, V) × 2 bytes = 144 KiB.
        let profile = try #require(KVProfile.from(config: ["num_hidden_layers": 36, "num_attention_heads": 32,
                                                           "num_key_value_heads": 8, "head_dim": 128]))
        #expect(profile.bytesPerToken == 147_456)
        #expect(!profile.hybrid)
        // Qwen2.5-0.5B has no head_dim: hidden_size / heads = 64.
        let small = try #require(KVProfile.from(config: ["num_hidden_layers": 24, "num_attention_heads": 14,
                                                         "num_key_value_heads": 2, "hidden_size": 896]))
        #expect(small.bytesPerToken == 12_288)
    }

    @Test func latentAttentionIsCompact() throws {
        let profile = try #require(KVProfile.from(config: ["num_hidden_layers": 61, "num_attention_heads": 128,
                                                           "kv_lora_rank": 512, "qk_rope_head_dim": 64]))
        #expect(profile.bytesPerToken == Double(61 * 576 * 2))
    }

    @Test func contextIsNoLongerCappedAt64k() throws {
        // A small model with a real KV profile and a 1M-token limit on an 80 GB card.
        let info = ModelInfo(repoId: "o/m", access: .open, gated: false, format: .awq, weightBytes: 4e9,
                             nativeContextTokens: 1_048_576, license: nil, toolCallParser: nil, reasoningParser: nil,
                             kvProfile: KVProfile(bytesPerToken: 12_288, attentionHeads: 16, hybrid: false))
        let catalog = [try gpu("NVIDIA H100 80GB HBM3", memory: 80, secure: 2.69)]
        let options = GPUSuggestion.options(for: info, catalog: catalog, goal: .economical, context: 262_144)
        #expect(options.first?.contextTokens == 262_144)
        #expect(GPUSuggestion.contextSteps(upTo: 1_048_576).last == 1_048_576)
    }

    @Test func longContextsAreOfferedOnSeveralCards() throws {
        let info = ModelInfo(repoId: "o/m", access: .open, gated: false, format: .awq, weightBytes: 19e9,
                             nativeContextTokens: 262_144, license: nil, toolCallParser: nil, reasoningParser: nil,
                             kvProfile: KVProfile.from(config: Self.qwen38))
        var card = try gpu("NVIDIA L40S", memory: 48, secure: 0.86)
        card.maxCount = .init(community: nil, secure: 8)
        // 262k tokens at ~83 KiB need about 21 GiB of cache: more than one 48 GB card holds beside 17.7 GiB of weights.
        let options = GPUSuggestion.options(for: info, catalog: [card], goal: .economical, context: 262_144)
        let first = try #require(options.first)
        #expect(first.choice.count == 2)
        #expect(abs(first.pricePerHour - 1.72) < 0.001)
        #expect(first.label == "2 × L40S")
    }

    @Test func cardCountsMustDivideTheAttentionHeads() throws {
        let info = ModelInfo(repoId: "o/m", access: .open, gated: false, format: .awq, weightBytes: 19e9,
                             nativeContextTokens: 1_048_576, license: nil, toolCallParser: nil, reasoningParser: nil,
                             kvProfile: KVProfile(bytesPerToken: 300_000, attentionHeads: 6, hybrid: false))
        var card = try gpu("NVIDIA L40S", memory: 48, secure: 0.86)
        card.maxCount = .init(community: nil, secure: 8)
        let counts = GPUSuggestion.options(for: info, catalog: [card], goal: .economical, context: 131_072).map(\.choice.count)
        #expect(!counts.contains(4) && !counts.contains(8), "6 heads cannot be split across 4 or 8 cards")
    }

    @Test func hostingRulesFilterCardsAndPickDataCenters() throws {
        var card = try gpu("NVIDIA L40S", memory: 48, secure: 0.86, community: 0.79)
        card.dataCenters = [.init(id: "US-TX-3", name: nil, availability: .low), .init(id: "EUR-IS-2", name: nil, availability: .low)]
        let model = PodlightModel(name: "m", repoId: "o/m", format: .awq, weightBytes: 10e9, nativeContextTokens: 65_536,
                                  toolCallParser: nil, reasoningParser: nil, contextTokens: 32_768)
        let eu = HostingPolicy(region: .eu)
        #expect(GPUSuggestion.options(for: model.info, catalog: [card], goal: .economical, context: 32_768, hosting: eu).isEmpty,
                "only offered outside the EU")
        let eea = HostingPolicy(region: .euEEA, secureOnly: true)
        let options = GPUSuggestion.options(for: model.info, catalog: [card], goal: .economical, context: 32_768, hosting: eea)
        #expect(options.map(\.choice.cloud) == [.secure])
        #expect(eea.dataCenterIds(in: [card]) == ["EUR-IS-2"])
        #expect(HostingPolicy.anywhere.dataCenterIds(in: [card]) == nil)
    }

    @Test func storagePricesFollowRunPod() {
        #expect(abs(StoragePricing.stoppedPerMonth(volumeGB: 30) - 6.0) < 0.0001)
        #expect(abs(StoragePricing.runningPerHour(containerGB: 30, volumeGB: 30) - 6.0 / 730) < 0.000_001)
        #expect(abs(StoragePricing.stoppedPerHour(volumeGB: 40) - 8.0 / 730) < 0.000_001)
    }

    @Test func costPerHourCountsTheStorageOfRunningPods() {
        var state = PodlightState()
        var running = ModelRun()
        running.phase = .ready
        running.pricePerHour = 0.40
        running.storagePerHour = 0.01
        var stopped = ModelRun()
        stopped.pricePerHour = 0.30
        stopped.storagePerHour = 0.02
        state.runs = [UUID(): running, UUID(): stopped]
        #expect(abs(state.costPerHour - 0.41) < 0.000_001)
    }

    @Test func settingsFromVersion01KeepTheirValues() throws {
        let old = #"{"dailyLimitUsd":null,"monthlyLimitUsd":50,"heartbeatMinutes":15,"wakeWaitSeconds":600,"gatewayPort":7635,"deleteStoppedAfterDays":3,"wakeOnRequest":true}"#
        let settings = try JSONDecoder().decode(PodlightSettings.self, from: Data(old.utf8))
        #expect(settings.dailyLimitUsd == nil && settings.monthlyLimitUsd == 50)
        #expect(settings.hostingRegion == .anywhere && !settings.allowLAN)
        // "No limit" survives a round trip.
        let again = try JSONDecoder().decode(PodlightSettings.self, from: JSONEncoder().encode(settings))
        #expect(again.dailyLimitUsd == nil)
    }
}
