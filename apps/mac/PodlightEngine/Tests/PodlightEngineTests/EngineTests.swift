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
        let m = model(weightsGB: 19)
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
