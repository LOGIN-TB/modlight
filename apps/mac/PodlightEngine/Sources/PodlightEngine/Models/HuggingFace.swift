import Foundation

/// How a model's weights are stored. Decides which engine and which cards can run it.
public enum WeightFormat: String, Codable, Sendable, Equatable {
    case safetensors, awq, gptq, fp8, nvfp4, gguf, mlx, unknown

    /// Podlight 1.0 runs vLLM only. GGUF (llama.cpp) is planned; MLX never runs on NVIDIA.
    public var runsOnVLLM: Bool {
        switch self {
        case .safetensors, .awq, .gptq, .fp8, .nvfp4, .unknown: true
        case .gguf, .mlx: false
        }
    }

    /// Can a card with this name run these weights?
    public func runs(on gpuId: String) -> Bool {
        switch self {
        case .fp8: CardSupport.fp8(gpuId)
        case .nvfp4: CardSupport.nvfp4(gpuId)
        default: true
        }
    }

    /// Shown to the user; 4-bit builds are the ones worth suggesting.
    public var isFourBit: Bool { self == .awq || self == .gptq || self == .nvfp4 }
}

/// One search hit.
public struct ModelHit: Codable, Sendable, Equatable, Identifiable {
    public var id: String { repoId }
    public var repoId: String
    public var downloads: Int
    public var likes: Int
    public var gated: Bool
    public var format: WeightFormat
}

/// What Podlight needs to know about a model before suggesting a card.
public struct ModelInfo: Codable, Sendable, Equatable {
    public enum Access: String, Codable, Sendable { case open, needsToken, missing, unreachable }

    public var repoId: String
    public var access: Access
    public var gated: Bool
    public var format: WeightFormat
    /// Sum of the weight files, in bytes as Hugging Face reports them (decimal).
    public var weightBytes: Double
    public var nativeContextTokens: Int?
    public var license: String?
    /// vLLM `--tool-call-parser`, read from the model's own chat template. Nil: no tool support.
    public var toolCallParser: String?
    /// vLLM `--reasoning-parser` for thinking models.
    public var reasoningParser: String?

    public init(repoId: String, access: Access, gated: Bool, format: WeightFormat, weightBytes: Double,
                nativeContextTokens: Int?, license: String?, toolCallParser: String?, reasoningParser: String?) {
        self.repoId = repoId
        self.access = access
        self.gated = gated
        self.format = format
        self.weightBytes = weightBytes
        self.nativeContextTokens = nativeContextTokens
        self.license = license
        self.toolCallParser = toolCallParser
        self.reasoningParser = reasoningParser
    }

    public var weightsGiB: Double { Capacity.bytesToGiB(weightBytes) }
    public var weightsGB: Double { weightBytes / 1_000_000_000 }
}

/// Reads the Hugging Face Hub. A token is optional and only needed for gated models.
public struct HuggingFaceClient: Sendable {
    public static let baseURL = URL(string: "https://huggingface.co")!

    private let token: String?
    private let transport: HTTPTransport

    public init(token: String? = nil, transport: HTTPTransport = URLSession.shared) {
        self.token = token?.isEmpty == true ? nil : token
        self.transport = transport
    }

    /// Accepts a repo id (`Qwen/Qwen3-8B`) or any huggingface.co URL pointing into a repo.
    public static func repoId(fromUserInput input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let host = url.host, host.hasSuffix("huggingface.co") {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            text = "\(parts[0])/\(parts[1])"
        }
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#
        return text.range(of: pattern, options: .regularExpression) != nil ? text : nil
    }

    /// Text-generation models matching `query`, quantised builds included even when untagged,
    /// most downloaded first. MLX builds are dropped: they never run on rented NVIDIA cards.
    public func search(_ query: String, limit: Int = 25) async throws -> [ModelHit] {
        async let tagged = page(query, tag: "text-generation", limit: limit)
        async let untagged = page(query, tag: nil, limit: limit)
        var seen: [String: ModelHit] = [:]
        for raw in try await tagged + untagged {
            guard let repo = raw["id"] as? String ?? raw["modelId"] as? String, seen[repo] == nil else { continue }
            let format = Self.detectFormat(repoId: repo, filenames: [], quantization: nil)
            if format == .mlx { continue }
            seen[repo] = ModelHit(repoId: repo, downloads: raw["downloads"] as? Int ?? 0,
                                  likes: raw["likes"] as? Int ?? 0, gated: Self.isGated(raw["gated"]), format: format)
        }
        return seen.values.sorted { $0.downloads > $1.downloads }.prefix(limit).map { $0 }
    }

    /// Everything needed to suggest a card and start the engine.
    public func info(_ repoId: String) async throws -> ModelInfo {
        let (status, data) = try await get("/api/models/\(repoId)", query: ["blobs": "true"])
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let access: ModelInfo.Access = status == 401 || status == 403 ? .needsToken : status == 404 ? .missing : .unreachable
            return ModelInfo(repoId: repoId, access: access, gated: status == 401 || status == 403, format: .unknown,
                             weightBytes: 0, nativeContextTokens: nil, license: nil, toolCallParser: nil, reasoningParser: nil)
        }

        let siblings = (json["siblings"] as? [[String: Any]]) ?? []
        let files = siblings.compactMap { $0["rfilename"] as? String }
        let gated = Self.isGated(json["gated"])
        let cardData = json["cardData"] as? [String: Any]
        let license = cardData?["license"] as? String

        // The repository's own config, not the listing's trimmed copy: the listing drops the
        // `type: float` that tells NVFP4 from AWQ.
        let config = files.contains("config.json") ? try? await rawJSON(repoId, "config.json") : nil
        let quantization = (config?["quantization_config"] as? [String: Any])
            ?? ((json["config"] as? [String: Any])?["quantization_config"] as? [String: Any])
        let format = Self.detectFormat(repoId: repoId, filenames: files, quantization: quantization)

        let weightBytes = siblings.reduce(0.0) { sum, file in
            guard let name = file["rfilename"] as? String,
                  name.range(of: #"\.(safetensors|bin)$"#, options: [.regularExpression, .caseInsensitive]) != nil
            else { return sum }
            return sum + (file["size"] as? Double ?? Double(file["size"] as? Int ?? 0))
        }

        let template = await chatTemplate(repoId, files: files)
        return ModelInfo(
            repoId: repoId, access: .open, gated: gated, format: format, weightBytes: weightBytes,
            nativeContextTokens: Self.context(from: config), license: license,
            toolCallParser: Self.toolCallParser(chatTemplate: template),
            reasoningParser: Self.reasoningParser(chatTemplate: template)
        )
    }

    /// 4-bit builds of the same model, smallest download first. Suggested because a 4-bit build
    /// was twice as fast and held twice the context on the same card (measured 2026-08-30).
    public func fourBitVariants(of repoId: String) async -> [ModelHit] {
        let name = repoId.split(separator: "/").last.map(String.init) ?? repoId
        let base = name.replacingOccurrences(of: #"[-_](Instruct|Chat|it)$"#, with: "", options: .regularExpression)
        guard let hits = try? await search(base, limit: 40) else { return [] }
        return hits.filter { $0.repoId != repoId && $0.format.isFourBit }
    }

    // MARK: Rules (pure, tested)

    public static func detectFormat(repoId: String, filenames: [String], quantization: [String: Any]?) -> WeightFormat {
        if filenames.contains(where: { $0.lowercased().hasSuffix(".gguf") }) { return .gguf }
        let name = repoId.lowercased()
        if name.range(of: #"\bmlx\b"#, options: .regularExpression) != nil { return .mlx }

        let method = (quantization?["quant_method"] as? String ?? "").lowercased()
        if method.contains("awq") { return .awq }
        if method.contains("gptq") { return .gptq }
        if method.contains("fp8") || (quantization?["fmt"] as? String ?? "").lowercased().contains("e4m3") { return .fp8 }
        if method.contains("compressed-tensors") {
            let groups = (quantization?["config_groups"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
            let weights = groups.compactMap { $0["weights"] as? [String: Any] }
            if weights.contains(where: { ($0["num_bits"] as? Int) == 4 && ($0["type"] as? String)?.lowercased() == "float" }) { return .nvfp4 }
            if weights.contains(where: { ($0["num_bits"] as? Int) == 4 }) { return .awq }
            if weights.contains(where: { ($0["num_bits"] as? Int) == 8 }) { return .fp8 }
            return name.range(of: "w4a16|int4", options: .regularExpression) != nil ? .awq : .fp8
        }

        if name.contains("gguf") { return .gguf }
        if name.contains("nvfp4") { return .nvfp4 }
        if name.contains("awq") || name.range(of: "w4a16|int4", options: .regularExpression) != nil { return .awq }
        if name.contains("gptq") { return .gptq }
        if name.contains("fp8") { return .fp8 }
        return filenames.isEmpty ? .unknown : .safetensors
    }

    /// The tool-call format comes from the model's chat template, never its name: Qwen3 templates
    /// emit XML that the `hermes` parser cannot read. Parser names as in vLLM v0.28.
    public static func toolCallParser(chatTemplate: String?) -> String? {
        guard let t = chatTemplate, t.contains("<tool_call>") else { return nil }
        if t.contains("<function=") && t.contains("<parameter=") { return "qwen3_xml" }
        return "hermes"
    }

    public static func reasoningParser(chatTemplate: String?) -> String? {
        guard let t = chatTemplate, t.contains("<think>") else { return nil }
        return "qwen3"
    }

    /// Multimodal repos keep the limit under `text_config`.
    static func context(from config: [String: Any]?) -> Int? {
        guard let config else { return nil }
        let candidates = [config["max_position_embeddings"], (config["text_config"] as? [String: Any])?["max_position_embeddings"]]
        return candidates.compactMap { $0 as? Int }.first { $0 > 0 }
    }

    static func isGated(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let s = value as? String { return !s.isEmpty && s != "false" }
        return false
    }

    // MARK: Plumbing

    private func page(_ query: String, tag: String?, limit: Int) async throws -> [[String: Any]] {
        var q = ["search": query, "sort": "downloads", "direction": "-1", "limit": String(limit * 2)]
        if let tag { q["pipeline_tag"] = tag }
        let (status, data) = try await get("/api/models", query: q)
        guard status == 200 else { return [] }
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// The Jinja template: inside `tokenizer_config.json` in older repos, `chat_template.jinja` in newer.
    private func chatTemplate(_ repoId: String, files: [String]) async -> String? {
        if files.contains("tokenizer_config.json"),
           let config = try? await rawJSON(repoId, "tokenizer_config.json"),
           let template = config["chat_template"] as? String {
            return template
        }
        if files.contains("chat_template.jinja"),
           let result = try? await get("/\(repoId)/resolve/main/chat_template.jinja"), result.0 == 200 {
            return String(decoding: result.1, as: UTF8.self)
        }
        return nil
    }

    private func rawJSON(_ repoId: String, _ file: String) async throws -> [String: Any]? {
        let (status, data) = try await get("/\(repoId)/resolve/main/\(file)")
        guard status == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func get(_ path: String, query: [String: String] = [:]) async throws -> (Int, Data) {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.send(request)
        return (response.statusCode, data)
    }
}
