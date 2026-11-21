import Foundation
import Testing
@testable import PodlightEngine

private func card(_ id: String, memory: Int, secure: Double? = nil, community: Double? = nil, maxCount: Int = 8) throws -> RunpodGPUType {
    let json: [String: Any] = [
        "id": id, "name": id.replacingOccurrences(of: "NVIDIA ", with: ""), "manufacturer": "NVIDIA", "memory": memory,
        "secure": secure != nil, "community": community != nil,
        "price": ["secure": secure ?? 0, "community": community ?? 0], "availability": "LOW",
        "maxCount": ["secure": maxCount, "community": maxCount],
    ]
    return try RunpodClient.decoder.decode(RunpodGPUType.self, from: JSONSerialization.data(withJSONObject: json))
}

private func option(_ gpu: String, count: Int = 1, cloud: RunpodCloud = .secure) -> GPUOption {
    GPUOption(choice: GPUChoice(gpuId: gpu, cloud: cloud, count: count), displayName: gpu, memoryGiB: 48,
              pricePerHour: 1, estimatedTokensPerSecond: nil, contextTokens: 65_536, contextCeiling: 65_536,
              availability: nil, dataCenters: [])
}

@Suite("Card selection follows the context")
struct ReselectionTests {
    @Test func withoutAChoiceOfTheirOwnTheSelectionFollowsTheSuggestion() {
        let result = GPUSuggestion.reselect(previous: GPUChoice(gpuId: "A", cloud: .secure, count: 1), userPicked: false,
                                            options: [option("B"), option("A")])
        #expect(result.selection?.gpuId == "B")
        #expect(result.change == .unchanged)
    }

    @Test func theUsersCardStaysWhileItIsOffered() {
        let mine = GPUChoice(gpuId: "A", cloud: .secure, count: 1)
        let result = GPUSuggestion.reselect(previous: mine, userPicked: true, options: [option("B"), option("A")])
        #expect(result.selection == mine)
        #expect(result.change == .unchanged)
    }

    @Test func aLongerContextMovesToMoreOfTheSameCard() {
        let mine = GPUChoice(gpuId: "A", cloud: .secure, count: 1)
        let result = GPUSuggestion.reselect(previous: mine, userPicked: true, options: [option("B"), option("A", count: 2)])
        #expect(result.selection == GPUChoice(gpuId: "A", cloud: .secure, count: 2))
        #expect(result.change == .moreCards(from: mine, to: GPUChoice(gpuId: "A", cloud: .secure, count: 2)))
    }

    @Test func aCardThatNoLongerFitsGivesWayToTheSuggestion() {
        let mine = GPUChoice(gpuId: "A", cloud: .community, count: 1)
        let result = GPUSuggestion.reselect(previous: mine, userPicked: true, options: [option("B")])
        #expect(result.selection?.gpuId == "B")
        #expect(result.change == .replaced(mine))
    }

    @Test func theNeededMemoryGrowsWithTheContext() {
        let short = Capacity.requiredGiB(weightsGiB: 20, contextTokens: 32_768, kvBytesPerToken: 65_536)
        let long = Capacity.requiredGiB(weightsGiB: 20, contextTokens: 262_144, kvBytesPerToken: 65_536)
        #expect(long > short + 15)
        // vLLM's own share and overhead come on top of weights and cache.
        #expect(short > 20 + 2)
    }
}

@Suite("Location per model")
struct HostingPerModelTests {
    @Test func aModelFrom02UsesTheSettings() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"m","repoId":"o/m","format":"awq","weightBytes":1e9,"contextTokens":8192}"#
        let model = try JSONDecoder().decode(PodlightModel.self, from: Data(old.utf8))
        #expect(model.hosting == nil)
        #expect(model.hosting(default: HostingPolicy(region: .eu)) == HostingPolicy(region: .eu))
    }

    @Test func aModelsOwnLocationWins() throws {
        var model = PodlightModel(name: "m", repoId: "o/m", format: .awq, weightBytes: 1e9, nativeContextTokens: nil,
                                  toolCallParser: nil, reasoningParser: nil, contextTokens: 8192)
        model.hosting = HostingPolicy(region: .anywhere, secureOnly: true)
        let roundTrip = try JSONDecoder().decode(PodlightModel.self, from: JSONEncoder().encode(model))
        #expect(roundTrip.hosting(default: HostingPolicy(region: .eu)) == HostingPolicy(region: .anywhere, secureOnly: true))
    }
}

/// A small GGUF header as llama.cpp writes it: magic, version 3, counts, then key–value pairs.
private struct GGUFWriter {
    var data = Data("GGUF".utf8)
    var pairs = Data()
    var count: UInt64 = 0

    static func u32(_ v: UInt32, into d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    static func u64(_ v: UInt64, into d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    static func str(_ s: String, into d: inout Data) { u64(UInt64(s.utf8.count), into: &d); d.append(contentsOf: Array(s.utf8)) }

    mutating func string(_ key: String, _ value: String) { Self.str(key, into: &pairs); Self.u32(8, into: &pairs); Self.str(value, into: &pairs); count += 1 }
    mutating func uint32(_ key: String, _ value: UInt32) { Self.str(key, into: &pairs); Self.u32(4, into: &pairs); Self.u32(value, into: &pairs); count += 1 }
    mutating func strings(_ key: String, _ values: [String]) {
        Self.str(key, into: &pairs); Self.u32(9, into: &pairs); Self.u32(8, into: &pairs); Self.u64(UInt64(values.count), into: &pairs)
        for v in values { Self.str(v, into: &pairs) }
        count += 1
    }
    mutating func floats(_ key: String, count n: Int) {
        Self.str(key, into: &pairs); Self.u32(9, into: &pairs); Self.u32(6, into: &pairs); Self.u64(UInt64(n), into: &pairs)
        pairs.append(Data(count: n * 4))
        count += 1
    }

    mutating func finish() -> Data {
        var out = data
        Self.u32(3, into: &out)
        Self.u64(0, into: &out)
        Self.u64(count, into: &out)
        return out + pairs
    }
}

@Suite("GGUF")
struct GGUFTests {
    @Test func quantisationsAreGroupedWithShardsAndFolders() {
        let files: [(path: String, bytes: Double)] = [
            ("Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf", 18.6e9),
            ("Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf", 17.7e9),
            ("Qwen3-Coder-30B-A3B-Instruct-Q8_0.gguf", 32.5e9),
            ("BF16/Qwen3-Coder-30B-A3B-Instruct-BF16-00001-of-00002.gguf", 49.9e9),
            ("BF16/Qwen3-Coder-30B-A3B-Instruct-BF16-00002-of-00002.gguf", 11.2e9),
            ("mmproj-F16.gguf", 0.6e9),
            ("README.md", 1e3),
        ]
        let quants = GGUF.quants(from: files)
        #expect(quants.map(\.name) == ["UD-Q4_K_XL", "Q4_K_M", "Q8_0", "BF16"])
        let bf16 = quants.last!
        #expect(bf16.files.count == 2 && abs(bf16.bytes - 61.1e9) < 1e6)
        #expect(GGUF.recommended(quants)?.name == "Q4_K_M")
        #expect(GGUF.quantName("gpt-oss-20b-mxfp4") == "MXFP4")
        #expect(GGUF.quantName("model-IQ4_XS") == "IQ4_XS")
        #expect(quants.first { $0.name == "Q8_0" }?.isHigh == true)
        #expect(GGUFQuant(name: "Q3_K_M", files: [], bytes: 0).isVeryLow)
    }

    @Test func theHeaderGivesTheCachePerToken() throws {
        // Qwen3-Coder-30B-A3B Q4_K_M: 48 layers × 4 KV heads × (128 + 128) × 2 bytes = 96 KiB.
        var w = GGUFWriter()
        w.string("general.architecture", "qwen3moe")
        w.uint32("qwen3moe.block_count", 48)
        w.uint32("qwen3moe.context_length", 262_144)
        w.uint32("qwen3moe.embedding_length", 2048)
        w.uint32("qwen3moe.attention.head_count", 32)
        w.uint32("qwen3moe.attention.head_count_kv", 4)
        w.uint32("qwen3moe.attention.key_length", 128)
        w.uint32("qwen3moe.attention.value_length", 128)
        w.strings("tokenizer.ggml.tokens", (0..<2000).map { "tok\($0)" })
        w.floats("tokenizer.ggml.scores", count: 2000)
        w.string("tokenizer.chat_template", "{% if tools %}<tool_call>{% endif %}")
        let data = w.finish()

        let meta = try GGUF.metadata(from: data)
        #expect(meta["tokenizer.chat_template"] as? String != nil, "arrays before it are skipped, not lost")
        let profile = try #require(GGUF.kvProfile(from: meta))
        #expect(profile.bytesPerToken == 98_304)
        #expect(profile.attentionHeads == 32)
        #expect(GGUF.contextLength(from: meta) == 262_144)

        // Cut short: the reader asks for more instead of guessing.
        #expect(throws: GGUF.HeaderError.needMoreData) { try GGUF.metadata(from: data.prefix(data.count / 2)) }
        #expect(throws: GGUF.HeaderError.notGGUF) { try GGUF.metadata(from: Data("NOPE0000".utf8)) }
    }

    @Test func llamaCppGetsItsImageAndCommand() {
        var m = PodlightModel(name: "coder", repoId: "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF", format: .gguf,
                              weightBytes: 18.6e9, nativeContextTokens: 262_144, toolCallParser: "qwen3_xml",
                              reasoningParser: nil, contextTokens: 131_072,
                              preferredGPU: GPUChoice(gpuId: "NVIDIA L40S", cloud: .secure, count: 2), quant: "Q4_K_M")
        m.keepDisk = true
        let request = PodPlan.request(for: m, podKey: "k", huggingFaceToken: nil, runUntil: nil, heartbeatMinutes: 15)
        #expect(m.engine == .llamaCpp)
        #expect(request.image.hasPrefix("ghcr.io/ggml-org/llama.cpp:full-cuda12-"))
        #expect(request.gpu.minCudaVersion == "12.8")
        #expect(request.env["PODLIGHT_ENGINE"] == "llamacpp")
        #expect(request.env["PODLIGHT_QUANT"] == "Q4_K_M")
        #expect(request.env["LLAMA_CACHE"] == "/workspace/llama-cache")
        #expect(request.gpu.count == 2)

        let boot = String(decoding: PodPlan.resource("boot", "sh"), as: UTF8.self)
        #expect(boot.contains(#"-hf "$PODLIGHT_MODEL:$PODLIGHT_QUANT""#))
        #expect(boot.contains("-sm layer"))
    }

    @Test func llamaCppCardsSplitLayersAndAddNoSpeed() throws {
        // 30 heads do not divide by 4 or 8, which only vLLM's tensor parallel cares about.
        var info = ModelInfo(repoId: "o/m-GGUF", access: .open, gated: false, format: .gguf, weightBytes: 60e9,
                             nativeContextTokens: 131_072, license: nil, toolCallParser: nil, reasoningParser: nil,
                             kvProfile: KVProfile(bytesPerToken: 98_304, attentionHeads: 30, hybrid: false))
        info.quant = "Q8_0"
        let catalog = [try card("NVIDIA RTX A5000", memory: 24, secure: 0.27)]
        let options = GPUSuggestion.options(for: info, catalog: catalog, goal: .economical, context: 65_536,
                                            speeds: GPUSpeedTable(efficiency: 0.6, entries: ["NVIDIA RTX A5000": .init(bandwidthGBs: 768)]))
        let first = try #require(options.first)
        #expect(first.choice.count == 4, "60 GB of weights plus cache need four 24 GB cards")
        #expect(first.estimatedTokensPerSecond.map { abs($0 - 768 / 60 * 0.6) < 0.01 } == true)

        // V100 is too old for vLLM's image, not for llama.cpp's.
        #expect(CardSupport.runsEngineImage("Tesla V100-SXM2-32GB", engine: .llamaCpp))
        #expect(!CardSupport.runsEngineImage("Tesla V100-SXM2-32GB", engine: .vllm))
    }

    /// Reads a real header from Hugging Face. Opt-in: PODLIGHT_LIVE_HF=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_LIVE_HF"] == "1"))
    func aRealRepositoryReadsLikeTheMeasurement() async throws {
        let info = try await HuggingFaceClient().info("unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF")
        print("[live-hf] format \(info.format), quant \(info.quant ?? "-"), \(info.weightBytes / 1e9) GB, ctx \(info.nativeContextTokens ?? 0), kv \(info.kvProfile?.bytesPerToken ?? 0), tools \(info.toolCallParser ?? "-"), quants \(info.quants?.map(\.name) ?? [])")
        #expect(info.format == .gguf)
        #expect(info.quant == "Q4_K_M")
        #expect(info.kvProfile?.bytesPerToken == 98_304)
        #expect(info.toolCallParser != nil)
    }
}
