import Foundation

// VRAM and context arithmetic. Ported from RunPod Launcher (packages/shared/src/vram.ts,
// capacity.ts) and held to the same numbers by `spec/cases/capacity.json`.
//
// Everything is GiB. Hugging Face reports decimal bytes; mixing the two is a 7% error, which on a
// 48 GiB card invents 3.5 GB of room that is not there.

public enum Capacity {
    /// The estimate ran 5.4% over the truth on the one run it can be checked against, so a tenth
    /// is kept back: an engine that refuses to start after the download is the expensive failure.
    public static let margin = 0.9
    /// Not a memory limit; hybrid-attention models need a cache block per sequence.
    public static let maxConcurrency = 8
    /// Below this a context window is not worth starting an engine for.
    public static let minContextTokens = 4096
    /// Fewer GiB than this for the cache and the card holds little more than the weights.
    public static let minUsableKVGiB = 4.0
    /// KV cache cost of one token, measured on Qwen3.8-27B (83 KiB at two precisions). Smaller
    /// models are cheaper per token, so this errs on the safe side.
    public static let defaultKVBytesPerToken = 83.0 * 1024
    private static let step = 1024

    public static func bytesToGiB(_ bytes: Double) -> Double { bytes / 1_073_741_824 }

    /// GiB left for the KV cache after the engine's cap, a 12% overhead share, and the weights.
    /// The overhead share is a fit to three measurements, not a model of the allocator.
    /// With several cards (tensor parallel) the weights and the cache are spread across all of
    /// them, and each card keeps its own overhead.
    ///
    /// llama.cpp takes what it needs instead of a share: a compute buffer per card (about 1 GiB,
    /// measured as "CUDA compute buffer size" in its log) and a reserve of 1 GiB, as its own
    /// `--fit` keeps back.
    public static func kvHeadroomGiB(gpuMemoryGiB: Double, weightsGiB: Double,
                                     otherSlotGiB: Double = 0, utilization: Double = 0.94, gpuCount: Int = 1,
                                     engine: InferenceEngine = .vllm) -> Double {
        let cards = Double(max(1, gpuCount))
        switch engine {
        case .vllm:
            return gpuMemoryGiB * cards * utilization * (1 - 0.12) - weightsGiB - otherSlotGiB
        case .llamaCpp:
            return gpuMemoryGiB * cards - llamaComputeBufferGiB * cards - llamaReserveGiB - weightsGiB - otherSlotGiB
        }
    }

    public static let llamaComputeBufferGiB = 1.0
    public static let llamaReserveGiB = 1.0

    /// Card memory (all cards together) a model needs for `contextTokens` × `concurrency`: the
    /// inverse of `plan`, for "needs about 142 GB" next to the card list.
    public static func requiredGiB(weightsGiB: Double, contextTokens: Int, concurrency: Int = 1,
                                   kvBytesPerToken: Double = defaultKVBytesPerToken,
                                   engine: InferenceEngine = .vllm) -> Double {
        let kvGiB = Double(contextTokens * max(1, concurrency)) * kvBytesPerToken / 1_073_741_824 / margin
        switch engine {
        case .vllm: return (weightsGiB + kvGiB) / (0.94 * (1 - 0.12))
        case .llamaCpp: return weightsGiB + kvGiB + llamaComputeBufferGiB + llamaReserveGiB
        }
    }

    public static func maxContextTokens(headroomGiB: Double, kvBytesPerToken: Double = defaultKVBytesPerToken) -> Int {
        guard headroomGiB > 0, kvBytesPerToken > 0 else { return 0 }
        let tokens = headroomGiB * 1_073_741_824 / kvBytesPerToken
        return Int((tokens / 1024).rounded(.down)) * 1024
    }

    public struct Plan: Codable, Equatable, Sendable {
        public var headroomGib: Double
        /// Tokens the card holds across all requests at once, margin applied.
        public var budgetTokens: Int
        public var contextCeiling: Int
        public var concurrencyCeiling: Int
        public var fits: Bool
        public var usable: Bool
    }

    public struct Choice: Codable, Equatable, Sendable {
        public var contextTokens: Int
        public var concurrency: Int
        public init(contextTokens: Int, concurrency: Int) {
            self.contextTokens = contextTokens
            self.concurrency = concurrency
        }
    }

    /// One budget spent two ways: context × concurrency has to fit in the same pool of tokens.
    public static func plan(gpuMemoryGiB: Double, weightsGiB: Double, nativeContextTokens: Int?,
                            chosen: Choice, kvBytesPerToken: Double = defaultKVBytesPerToken, gpuCount: Int = 1,
                            engine: InferenceEngine = .vllm) -> Plan {
        let headroom = kvHeadroomGiB(gpuMemoryGiB: gpuMemoryGiB, weightsGiB: weightsGiB, gpuCount: gpuCount, engine: engine)
        let budget = floorToStep(Double(maxContextTokens(headroomGiB: headroom, kvBytesPerToken: kvBytesPerToken)) * margin)
        let native = nativeContextTokens ?? Int.max

        let concurrency = min(max(chosen.concurrency, 1), maxConcurrency)
        let context = max(chosen.contextTokens, 0)

        let contextCeiling = min(floorToStep(Double(budget) / Double(concurrency)), native)
        let concurrencyCeiling = context > 0 ? min(max(budget / context, 0), maxConcurrency) : maxConcurrency

        return Plan(
            headroomGib: headroom,
            budgetTokens: budget,
            contextCeiling: contextCeiling,
            concurrencyCeiling: concurrencyCeiling,
            fits: context >= minContextTokens && context <= contextCeiling && concurrency <= concurrencyCeiling,
            usable: min(budget, native) >= minContextTokens
        )
    }

    /// The pair to start from: the whole budget as context, one request at a time. Nil when
    /// nothing usable fits.
    public static func recommend(gpuMemoryGiB: Double, weightsGiB: Double, nativeContextTokens: Int?,
                                 kvBytesPerToken: Double = defaultKVBytesPerToken, gpuCount: Int = 1) -> Choice? {
        let p = plan(gpuMemoryGiB: gpuMemoryGiB, weightsGiB: weightsGiB, nativeContextTokens: nativeContextTokens,
                     chosen: Choice(contextTokens: minContextTokens, concurrency: 1),
                     kvBytesPerToken: kvBytesPerToken, gpuCount: gpuCount)
        guard p.usable else { return nil }
        return Choice(contextTokens: max(minContextTokens, p.contextCeiling), concurrency: 1)
    }

    private static func floorToStep(_ tokens: Double) -> Int {
        tokens <= 0 ? 0 : Int((tokens / Double(step)).rounded(.down)) * step
    }
}

/// Which weight precisions a card can run. Name patterns, as RunPod names its cards.
public enum CardSupport {
    /// The pinned vLLM image is built for compute capability 7.5 and newer
    /// (TORCH_CUDA_ARCH_LIST in vllm/vllm-openai:v0.28.0). Volta and older cannot run it at all.
    /// llama.cpp's cuda12 image also carries code for Maxwell, Pascal and Volta (compute 5.0+), so
    /// only Kepler is out.
    public static func runsEngineImage(_ gpuId: String, engine: InferenceEngine = .vllm) -> Bool {
        if engine == .llamaCpp { return gpuId.range(of: #"\bK(80|40|20)\b"#, options: .regularExpression) == nil }
        return gpuId.range(of: #"(V100|P100|P40|\bP4\b|K80|M60|Titan V|Quadro GV100)"#,
                    options: [.regularExpression, .caseInsensitive]) == nil
    }

    public static func fp8(_ gpuId: String) -> Bool {
        gpuId.range(of: #"(\bada\b|\bl40s?\b|\bl4\b|rtx\s?(40|50)\d\d|rtx\s?pro|\bh100\b|\bh200\b|\bb200\b|\bb300\b|blackwell|hopper)"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func nvfp4(_ gpuId: String) -> Bool {
        gpuId.range(of: #"(blackwell|\brtx\s?pro\b|\bb200\b|\bb300\b|rtx\s?50\d\d)"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }
}
