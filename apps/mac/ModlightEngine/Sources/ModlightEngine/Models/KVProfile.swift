import Foundation

/// How much KV cache one token of context costs for a particular model, read from its config.json.
///
/// 0.1 used one figure for every model (83 KiB, measured on Qwen3.8-27B). That is far too much for
/// small models, which hid the long contexts they can actually hold, and it capped what Modlight
/// offered. The cache size follows the architecture, so it can be computed:
///
///     bytes per token = 2 (K and V) × attention layers × KV heads × head size × 2 bytes (bf16)
///
/// Hybrid models (Qwen3.5/3.8 with linear attention, Mamba hybrids) keep a recurrent state per
/// sequence besides the cache, and vLLM sizes its cache blocks around it. Calibration: Qwen3.8-27B
/// computes to 64 KiB and measured 82.8 KiB on 2026-08-30, so hybrids get a factor of 1.3.
public struct KVProfile: Codable, Sendable, Equatable {
    public var bytesPerToken: Double
    /// vLLM needs the attention heads to divide evenly across the cards of a pod.
    public var attentionHeads: Int?
    public var hybrid: Bool

    public static let hybridOverhead = 1.3

    public init(bytesPerToken: Double, attentionHeads: Int?, hybrid: Bool) {
        self.bytesPerToken = bytesPerToken
        self.attentionHeads = attentionHeads
        self.hybrid = hybrid
    }

    /// Nil when the config lacks what is needed; callers fall back to `Capacity.defaultKVBytesPerToken`.
    public static func from(config: [String: Any]?) -> KVProfile? {
        guard let config else { return nil }
        let text = (config["text_config"] as? [String: Any]) ?? config
        func int(_ key: String) -> Int? { (text[key] ?? config[key]) as? Int }

        guard let layers = int("num_hidden_layers"), layers > 0 else { return nil }
        let heads = int("num_attention_heads")

        // Multi-head latent attention (DeepSeek and relatives): one compressed vector per layer.
        if let rank = int("kv_lora_rank"), rank > 0 {
            let rope = int("qk_rope_head_dim") ?? 0
            return KVProfile(bytesPerToken: Double(layers * (rank + rope) * 2), attentionHeads: heads, hybrid: false)
        }

        guard let heads, heads > 0 else { return nil }
        let kvHeads = int("num_key_value_heads") ?? heads
        guard let headDim = int("head_dim") ?? int("hidden_size").map({ $0 / heads }), headDim > 0 else { return nil }

        var attentionLayers = layers
        var hybrid = false
        if let types = (text["layer_types"] ?? config["layer_types"]) as? [String], !types.isEmpty {
            // Sliding-window layers are counted in full: it errs on the safe side.
            let linear = types.filter { $0.contains("linear") || $0.contains("mamba") || $0.contains("recurrent") }.count
            attentionLayers = types.count - linear
            hybrid = linear > 0
        } else if let interval = int("full_attention_interval"), interval > 1 {
            attentionLayers = layers / interval
            hybrid = true
        } else if let pattern = (text["hybrid_override_pattern"] ?? config["hybrid_override_pattern"]) as? String {
            attentionLayers = pattern.filter { $0 == "*" }.count
            hybrid = attentionLayers < pattern.count
        }
        guard attentionLayers > 0 else { return nil }

        let bytes = Double(2 * attentionLayers * kvHeads * headDim * 2) * (hybrid ? hybridOverhead : 1)
        return KVProfile(bytesPerToken: bytes, attentionHeads: heads, hybrid: hybrid)
    }
}
