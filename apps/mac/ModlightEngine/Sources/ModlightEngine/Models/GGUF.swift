import Foundation

/// One quantisation in a GGUF repository, e.g. `Q4_K_M`, possibly split into several files.
public struct GGUFQuant: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// As llama.cpp's `-hf repo:quant` matches it, e.g. `Q4_K_M`, `UD-Q4_K_XL`, `BF16`.
    public var name: String
    /// Repository paths, shards in order.
    public var files: [String]
    /// All shards together, decimal bytes as Hugging Face reports them.
    public var bytes: Double

    public init(name: String, files: [String], bytes: Double) {
        self.name = name
        self.files = files
        self.bytes = bytes
    }

    /// Below 4 bits models get noticeably worse at code and tool calls.
    public var isVeryLow: Bool {
        name.range(of: #"(^|[-_])(I?Q[123]_|TQ)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 8 bits and up: close to the original, twice the memory of 4 bits.
    public var isHigh: Bool {
        name.range(of: #"(Q8_0|Q6_K|BF16|FP16|F16|FP32|F32)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Reading GGUF repositories: which quantisations they hold, and the architecture from a file's
/// header, so the KV cache per token can be computed like for safetensors models.
public enum GGUF {
    private static let quantPattern =
        #"(?i)(UD-)?(IQ[1-4]_(XXS|XS|S|M|NL)|Q[2-8]_K(_(XL|XXL|S|M|L))?|Q[4-8]_[01]|MXFP4(_MOE)?|TQ[12]_0|BF16|FP16|F16|FP32|F32)$"#
    private static let shardPattern = #"-\d{5}-of-\d{5}$"#

    /// Groups `.gguf` files by quantisation. Projector files (`mmproj`) for images are left out;
    /// shards (`-00001-of-00003`) and quantisation folders (`Q8_0/…`) are joined.
    public static func quants(from files: [(path: String, bytes: Double)]) -> [GGUFQuant] {
        var groups: [String: (files: [String], bytes: Double)] = [:]
        for file in files {
            let lower = file.path.lowercased()
            guard lower.hasSuffix(".gguf"), !lower.contains("mmproj") else { continue }
            let base = String((file.path.split(separator: "/").last ?? Substring(file.path)).dropLast(5))
            let stem = base.replacingOccurrences(of: shardPattern, with: "", options: .regularExpression)
            let name = quantName(stem) ?? stem
            groups[name, default: ([], 0)].files.append(file.path)
            groups[name, default: ([], 0)].bytes += file.bytes
        }
        return groups.map { GGUFQuant(name: $0.key, files: $0.value.files.sorted(), bytes: $0.value.bytes) }
            .sorted { $0.bytes < $1.bytes }
    }

    /// The quantisation at the end of a file name: `Qwen3-8B-UD-Q4_K_XL` → `UD-Q4_K_XL`.
    public static func quantName(_ stem: String) -> String? {
        guard let range = stem.range(of: quantPattern, options: .regularExpression) else { return nil }
        let found = String(stem[range])
        return found.hasPrefix("ud-") || found.hasPrefix("UD-") ? "UD-" + found.dropFirst(3).uppercased() : found.uppercased()
    }

    /// The quantisation Modlight proposes: llama.cpp's own default Q4_K_M, else its closest
    /// relatives, else the smallest 4-bit, else the middle of the list.
    public static func recommended(_ quants: [GGUFQuant]) -> GGUFQuant? {
        for name in ["Q4_K_M", "UD-Q4_K_XL", "Q4_K_XL", "Q4_K_S", "IQ4_XS", "IQ4_NL", "MXFP4", "MXFP4_MOE", "Q4_0"] {
            if let q = quants.first(where: { $0.name.uppercased() == name }) { return q }
        }
        return quants.first { $0.name.contains("4") } ?? (quants.isEmpty ? nil : quants[quants.count / 2])
    }

    // MARK: Header

    public enum HeaderError: Error, Equatable {
        /// The metadata goes on past the bytes read so far.
        case needMoreData
        case notGGUF
    }

    /// Reads the key–value metadata at the start of a GGUF file (format version 2 and 3). Scalars
    /// and strings are kept; arrays (the tokenizer's vocabulary) are skipped.
    public static func metadata(from data: Data) throws -> [String: Any] {
        var reader = Reader(data: data)
        guard try reader.bytes(4) == Data("GGUF".utf8) else { throw HeaderError.notGGUF }
        let version = try reader.u32()
        guard version >= 2 else { throw HeaderError.notGGUF }
        _ = try reader.u64() // tensor count
        let count = try reader.u64()
        var result: [String: Any] = [:]
        for _ in 0..<count {
            let key = try reader.string()
            let type = try reader.u32()
            if let value = try reader.value(type: type) { result[key] = value }
        }
        return result
    }

    /// KV cache per token at f16 (llama.cpp's default), from the header's architecture fields.
    /// Same rules as `KVProfile.from(config:)`: MLA as a compressed vector, hybrid models by their
    /// attention layers.
    public static func kvProfile(from meta: [String: Any]) -> KVProfile? {
        guard let arch = meta["general.architecture"] as? String else { return nil }
        func int(_ key: String) -> Int? { (meta["\(arch).\(key)"] as? Int) }
        guard let layers = int("block_count"), layers > 0 else { return nil }
        let heads = int("attention.head_count")

        if let rank = int("attention.kv_lora_rank"), rank > 0 {
            let rope = int("rope.dimension_count") ?? 0
            return KVProfile(bytesPerToken: Double(layers * (rank + rope) * 2), attentionHeads: heads, hybrid: false)
        }
        guard let heads, heads > 0 else { return nil }
        let kvHeads = int("attention.head_count_kv") ?? heads
        guard let keyLength = int("attention.key_length") ?? int("embedding_length").map({ $0 / heads }), keyLength > 0 else { return nil }
        let valueLength = int("attention.value_length") ?? keyLength

        var attentionLayers = layers
        var hybrid = false
        if let interval = int("full_attention_interval"), interval > 1 {
            attentionLayers = layers / interval
            hybrid = true
        } else if meta.keys.contains(where: { $0.hasPrefix("\(arch).ssm.") }) {
            hybrid = true
        }
        let bytes = Double(attentionLayers * kvHeads * (keyLength + valueLength) * 2) * (hybrid ? KVProfile.hybridOverhead : 1)
        return KVProfile(bytesPerToken: bytes, attentionHeads: heads, hybrid: hybrid)
    }

    public static func contextLength(from meta: [String: Any]) -> Int? {
        guard let arch = meta["general.architecture"] as? String else { return nil }
        return meta["\(arch).context_length"] as? Int
    }

    struct Reader {
        let data: Data
        var offset = 0

        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, offset + n <= data.count else { throw HeaderError.needMoreData }
            defer { offset += n }
            let start = data.startIndex + offset
            return data[start..<start + n]
        }

        mutating func skip(_ n: Int) throws {
            guard n >= 0, offset + n <= data.count else { throw HeaderError.needMoreData }
            offset += n
        }

        mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let raw = try bytes(MemoryLayout<T>.size)
            return raw.reversed().reduce(T(0)) { ($0 << 8) | T($1) }
        }

        mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
        mutating func u64() throws -> UInt64 { try integer(UInt64.self) }

        mutating func string() throws -> String {
            let length = try u64()
            guard length < 64 * 1024 * 1024 else { throw HeaderError.notGGUF }
            return String(decoding: try bytes(Int(length)), as: UTF8.self)
        }

        static func size(of type: UInt32) -> Int? {
            switch type {
            case 0, 1, 7: 1
            case 2, 3: 2
            case 4, 5, 6: 4
            case 10, 11, 12: 8
            default: nil
            }
        }

        mutating func value(type: UInt32) throws -> Any? {
            switch type {
            case 0: return Int(try integer(UInt8.self))
            case 1: return Int(try integer(Int8.self))
            case 2: return Int(try integer(UInt16.self))
            case 3: return Int(try integer(Int16.self))
            case 4: return Int(try integer(UInt32.self))
            case 5: return Int(try integer(Int32.self))
            case 6: return Double(Float(bitPattern: try integer(UInt32.self)))
            case 7: return try integer(UInt8.self) != 0
            case 8: return try string()
            case 9:
                let itemType = try u32()
                let count = try u64()
                if let size = Self.size(of: itemType) {
                    try skip(Int(count) * size)
                } else {
                    for _ in 0..<count { _ = try value(type: itemType) }
                }
                return nil
            case 10: return Int(truncatingIfNeeded: try integer(UInt64.self))
            case 11: return Int(try integer(Int64.self))
            case 12: return Double(bitPattern: try integer(UInt64.self))
            default: throw HeaderError.notGGUF
            }
        }
    }
}
