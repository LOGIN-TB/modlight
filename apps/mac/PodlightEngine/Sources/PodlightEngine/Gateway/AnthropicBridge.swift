import Foundation

/// Anthropic Messages ⇄ OpenAI Chat Completions, for providers that only speak the second (Venice
/// has `/chat/completions` but no `/messages`, and Claude Code speaks only Messages). Pure: JSON in,
/// JSON out, no I/O. `server/src/gateway/anthropicBridge.ts` is the same code; both are held to
/// `spec/cases/anthropic-bridge.json`.
enum AnthropicBridge {
    /// A request the bridge cannot translate; the gateway answers 400 `invalid_request_error`.
    struct InvalidRequest: Error, Equatable, Sendable {
        let message: String
    }

    // MARK: Request

    /// The Chat Completions body for an Anthropic Messages body. `model` passes unchanged; the
    /// caller rewrites it to the provider's name.
    static func request(_ json: [String: Any]) throws -> [String: Any] {
        guard let source = json["messages"] as? [Any] else { throw InvalidRequest(message: "\"messages\" must be a list.") }
        var out: [String: Any] = [:]
        if let model = json["model"] { out["model"] = model }

        var messages: [[String: Any]] = []
        let system = text(json["system"])
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        for case let message as [String: Any] in source {
            switch message["role"] as? String {
            case "assistant": messages.append(assistantMessage(message["content"]))
            // As in `LocalGateway.systemMessagesAsReminders`: the chat templates behind a provider
            // refuse a second system message.
            case "system": messages.append(["role": "user", "content": "<system-reminder>\n\(text(message["content"]))\n</system-reminder>"])
            default: messages += userMessages(message["content"])
            }
        }
        out["messages"] = messages

        if let max = number(json["max_tokens"]) { out["max_completion_tokens"] = max }
        for key in ["temperature", "top_p", "top_k"] { if let value = number(json[key]) { out[key] = value } }
        if let stop = json["stop_sequences"] as? [Any], !stop.isEmpty { out["stop"] = stop }

        let tools = objects(json["tools"]).compactMap { tool -> [String: Any]? in
            guard let schema = tool["input_schema"] as? [String: Any] else { return nil }   // server tools (web_search)
            var function: [String: Any] = ["name": tool["name"] as? String ?? "", "parameters": schema]
            if let description = tool["description"] as? String { function["description"] = description }
            return ["type": "function", "function": function]
        }
        if !tools.isEmpty {
            out["tools"] = tools
            let choice = json["tool_choice"] as? [String: Any]
            switch choice?["type"] as? String {
            case "auto": out["tool_choice"] = "auto"
            case "any": out["tool_choice"] = "required"
            case "none": out["tool_choice"] = "none"
            case "tool": out["tool_choice"] = ["type": "function", "function": ["name": choice?["name"] as? String ?? ""]]
            default: break
            }
            if choice?["disable_parallel_tool_use"] as? Bool == true { out["parallel_tool_calls"] = false }
        }

        if let effort = reasoningEffort(json) { out["reasoning_effort"] = effort }
        if json["stream"] as? Bool == true {
            out["stream"] = true
            out["stream_options"] = ["include_usage": true]
        }
        return out
    }

    private static func userMessages(_ content: Any?) -> [[String: Any]] {
        guard let blocks = content as? [Any] else { return [["role": "user", "content": content as? String ?? ""]] }
        var out: [[String: Any]] = []
        var parts: [[String: Any]] = []
        var images: [[String: Any]] = []   // from tool results; a tool message holds text only
        func flush() {
            let all = images + parts
            if !all.isEmpty { out.append(["role": "user", "content": all]) }
            images = []
            parts = []
        }
        for case let block as [String: Any] in blocks {
            switch block["type"] as? String {
            case "tool_result":
                if !parts.isEmpty { flush() }
                out.append(["role": "tool", "tool_call_id": block["tool_use_id"] as? String ?? "", "content": text(block["content"])])
                images += objects(block["content"]).filter { $0["type"] as? String == "image" }.compactMap(imagePart)
            case "text": parts.append(["type": "text", "text": block["text"] as? String ?? ""])
            case "image": if let part = imagePart(block) { parts.append(part) }
            default: break
            }
        }
        flush()
        return out
    }

    private static func assistantMessage(_ content: Any?) -> [String: Any] {
        guard let blocks = content as? [Any] else { return ["role": "assistant", "content": content as? String ?? ""] }
        var texts: [String] = []
        var calls: [[String: Any]] = []
        for case let block as [String: Any] in blocks {
            switch block["type"] as? String {
            case "text": texts.append(block["text"] as? String ?? "")
            case "tool_use":
                calls.append(["id": block["id"] as? String ?? "", "type": "function",
                              "function": ["name": block["name"] as? String ?? "",
                                           "arguments": canonicalJSON(block["input"] as? [String: Any] ?? [:])]])
            default: break   // thinking: Chat Completions takes none back
            }
        }
        let joined = texts.joined(separator: "\n\n")
        if calls.isEmpty { return ["role": "assistant", "content": joined] }
        return ["role": "assistant", "content": joined.isEmpty ? NSNull() : joined, "tool_calls": calls]
    }

    private static func imagePart(_ block: [String: Any]) -> [String: Any]? {
        let source = block["source"] as? [String: Any] ?? [:]
        let url: String
        switch source["type"] as? String {
        case "base64": url = "data:\(source["media_type"] as? String ?? "image/png");base64,\(source["data"] as? String ?? "")"
        case "url":
            guard let link = source["url"] as? String else { return nil }
            url = link
        default: return nil
        }
        return ["type": "image_url", "image_url": ["url": url]]
    }

    /// Thinking budget to effort: below 4096 low, below 16384 medium, else high. Adaptive thinking
    /// takes `output_config.effort`, medium without one.
    private static func reasoningEffort(_ json: [String: Any]) -> String? {
        let thinking = json["thinking"] as? [String: Any]
        switch thinking?["type"] as? String {
        case "enabled":
            let budget = (thinking?["budget_tokens"] as? NSNumber)?.doubleValue ?? 0
            return budget < 4096 ? "low" : budget < 16384 ? "medium" : "high"
        case "adaptive":
            switch (json["output_config"] as? [String: Any])?["effort"] as? String {
            case let effort? where ["low", "medium", "high"].contains(effort): return effort
            case "xhigh", "max": return "high"
            default: return "medium"
            }
        default: return nil
        }
    }

    // MARK: Response

    /// The Anthropic message for a (non-streamed) Chat Completions response.
    static func response(_ json: [String: Any], requestModel: String) -> [String: Any] {
        let choice = objects(json["choices"]).first ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]
        var content: [[String: Any]] = []
        let thinking = reasoning(message)
        if !thinking.isEmpty { content.append(["type": "thinking", "thinking": thinking, "signature": ""]) }
        if let said = message["content"] as? String, !said.isEmpty { content.append(["type": "text", "text": said]) }
        let calls = objects(message["tool_calls"])
        for (position, call) in calls.enumerated() {
            let function = call["function"] as? [String: Any] ?? [:]
            let raw = function["arguments"] as? String ?? ""
            let id = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(position)"
            var block: [String: Any] = ["type": "tool_use", "id": id, "name": function["name"] as? String ?? "", "input": [String: Any]()]
            if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
                    block["input"] = parsed
                } else {
                    block["raw_arguments"] = raw
                }
            }
            content.append(block)
        }
        return ["id": messageId(json["id"]), "type": "message", "role": "assistant", "model": requestModel, "content": content,
                "stop_reason": stopReason(choice["finish_reason"], calledTools: !calls.isEmpty), "stop_sequence": NSNull(),
                "usage": usage(json["usage"])]
    }

    /// Tool calls always mean `tool_use`: some providers say `stop` although the message calls tools.
    static func stopReason(_ finish: Any?, calledTools: Bool) -> String {
        if calledTools { return "tool_use" }
        switch finish as? String {
        case "length": return "max_tokens"
        case "tool_calls", "function_call": return "tool_use"
        default: return "end_turn"   // stop, content_filter, none
        }
    }

    /// `prompt_tokens` includes the cached tokens; Anthropic counts them apart.
    static func usage(_ value: Any?) -> [String: Any] {
        let u = value as? [String: Any] ?? [:]
        let cached = count((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])
        return ["input_tokens": max(0, count(u["prompt_tokens"]) - cached), "output_tokens": count(u["completion_tokens"]),
                "cache_read_input_tokens": cached, "cache_creation_input_tokens": 0]
    }

    private static func messageId(_ id: Any?) -> String {
        guard let id = id as? String, !id.isEmpty else { return "msg_podlight" }
        return "msg_\(id)"
    }

    /// `reasoning_content` (Venice, DeepSeek) or `reasoning` (vLLM).
    private static func reasoning(_ message: [String: Any]) -> String {
        message["reasoning_content"] as? String ?? message["reasoning"] as? String ?? ""
    }

    // MARK: Errors

    /// Anthropic's error type for an upstream status.
    static func errorType(_ status: Int) -> String {
        switch status {
        case 401: "authentication_error"
        case 402: "billing_error"
        case 403: "permission_error"
        case 404: "not_found_error"
        case 413: "request_too_large"
        case 429: "rate_limit_error"
        case 503, 529: "overloaded_error"
        case 400..<500: "invalid_request_error"
        default: "api_error"
        }
    }

    /// An Anthropic error body for an upstream error; `body` is the decoded JSON, or its text.
    static func error(status: Int, body: Any?) -> [String: Any] {
        let message = errorMessage(body)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ["type": "error", "error": ["type": errorType(status),
                                           "message": message.isEmpty ? "The provider answered with status \(status)." : message]]
    }

    /// The same for the raw bytes of an upstream answer.
    static func error(status: Int, data: Data) -> [String: Any] {
        let body: Any? = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? String(data: data, encoding: .utf8)
        return error(status: status, body: body)
    }

    private static func errorMessage(_ body: Any?) -> String? {
        switch body {
        case let text as String: return text
        case let json as [String: Any]:
            if let inner = json["error"] as? [String: Any] { return inner["message"] as? String }
            return json["error"] as? String ?? json["message"] as? String ?? json["detail"] as? String
        default: return nil
        }
    }

    // MARK: count_tokens

    /// Rough input tokens for `count_tokens`, which an OpenAI-style provider does not offer: Unicode
    /// scalars of all text the model reads, / 4 rounded up, plus 1600 per image.
    static func estimateTokens(_ json: [String: Any]) -> Int {
        var scalars = 0
        var images = 0
        func add(_ value: Any?) { if let s = value as? String { scalars += s.unicodeScalars.count } }
        func blocks(_ content: Any?) {
            if let s = content as? String { add(s); return }
            for block in objects(content) {
                switch block["type"] as? String {
                case "text": add(block["text"])
                case "thinking": add(block["thinking"])
                case "image": images += 1
                case "tool_use": add(block["name"]); add(canonicalJSON(block["input"] ?? [String: Any]()))
                case "tool_result": blocks(block["content"])
                default: break
                }
            }
        }
        blocks(json["system"])
        for message in objects(json["messages"]) { blocks(message["content"]) }
        for tool in objects(json["tools"]) {
            add(tool["name"])
            add(tool["description"])
            if let schema = tool["input_schema"] { add(canonicalJSON(schema)) }
        }
        return (scalars + 3) / 4 + 1600 * images
    }

    // MARK: Stream

    /// Turns Chat Completions stream chunks into Anthropic stream events, one chunk at a time. Each
    /// event is the SSE data object; its `type` is the SSE event name. Text and thinking stream live,
    /// the first tool call too; later tool calls are sent whole at the end, since their deltas may
    /// interleave and Anthropic blocks cannot.
    struct StreamTranslator: Sendable {
        let requestModel: String
        private enum Kind: Sendable { case text, thinking, tool }
        private struct ToolCall: Sendable { var key: Int; var id: String; var name: String; var arguments: String }

        private var started = false
        private var ended = false
        private var nextIndex = 0
        private var open: (kind: Kind, index: Int)?
        /// The OpenAI index of the tool call that streams live.
        private var liveCall: Int?
        private var calls: [ToolCall] = []   // in order of first appearance
        private var lateText = ""
        private var finishReason: String?
        private var usage: [String: Int]?

        init(requestModel: String) { self.requestModel = requestModel }

        /// The events for one decoded chunk (the JSON after `data:`).
        mutating func feed(_ chunk: [String: Any]) -> [[String: Any]] {
            if ended { return [] }
            var events = start(chunk["id"])
            if let error = chunk["error"] {
                ended = true
                let message = AnthropicBridge.errorMessage(["error": error])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                events.append(["type": "error", "error": ["type": "api_error",
                                                          "message": message.isEmpty ? "The provider stopped the stream." : message]])
                return events
            }
            if let u = chunk["usage"] as? [String: Any] {
                usage = AnthropicBridge.usage(u).compactMapValues { $0 as? Int }
            }
            guard let choice = AnthropicBridge.objects(chunk["choices"]).first else { return events }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            let toolsBegan = !calls.isEmpty

            let thought = AnthropicBridge.reasoning(delta)
            if !thought.isEmpty && !toolsBegan {
                let index = ensure(.thinking, &events)
                events.append(["type": "content_block_delta", "index": index, "delta": ["type": "thinking_delta", "thinking": thought]])
            }
            if let said = delta["content"] as? String, !said.isEmpty {
                if toolsBegan {
                    lateText += said
                } else {
                    let index = ensure(.text, &events)
                    events.append(["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": said]])
                }
            }
            for call in AnthropicBridge.objects(delta["tool_calls"]) {
                let key = (call["index"] as? NSNumber)?.intValue ?? 0
                let function = call["function"] as? [String: Any] ?? [:]
                let piece = function["arguments"] as? String ?? ""
                if !calls.contains(where: { $0.key == key }) {
                    let id = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(calls.count)"
                    let new = ToolCall(key: key, id: id, name: function["name"] as? String ?? "", arguments: "")
                    calls.append(new)
                    if liveCall == nil {
                        liveCall = key
                        events += close()
                        let index = nextIndex
                        nextIndex += 1
                        open = (.tool, index)
                        events.append(["type": "content_block_start", "index": index,
                                       "content_block": ["type": "tool_use", "id": new.id, "name": new.name, "input": [String: Any]()]])
                    }
                }
                if let position = calls.firstIndex(where: { $0.key == key }) { calls[position].arguments += piece }
                if key == liveCall, !piece.isEmpty, let current = open, current.kind == .tool {
                    events.append(["type": "content_block_delta", "index": current.index,
                                   "delta": ["type": "input_json_delta", "partial_json": piece]])
                }
            }
            if let finish = choice["finish_reason"] as? String { finishReason = finish }
            return events
        }

        /// The closing events, once the upstream stream ended (`[DONE]` or end of body).
        mutating func finish() -> [[String: Any]] {
            if ended { return [] }
            var events = start(nil)
            ended = true
            events += close()
            for call in calls where call.key != liveCall {
                let index = nextIndex
                nextIndex += 1
                events.append(["type": "content_block_start", "index": index,
                               "content_block": ["type": "tool_use", "id": call.id, "name": call.name, "input": [String: Any]()]])
                if !call.arguments.isEmpty {
                    events.append(["type": "content_block_delta", "index": index,
                                   "delta": ["type": "input_json_delta", "partial_json": call.arguments]])
                }
                events.append(["type": "content_block_stop", "index": index])
            }
            if !lateText.isEmpty {
                let index = nextIndex
                nextIndex += 1
                events += [["type": "content_block_start", "index": index, "content_block": ["type": "text", "text": ""]],
                           ["type": "content_block_delta", "index": index, "delta": ["type": "text_delta", "text": lateText]],
                           ["type": "content_block_stop", "index": index]]
            }
            events.append(["type": "message_delta",
                           "delta": ["stop_reason": AnthropicBridge.stopReason(finishReason, calledTools: !calls.isEmpty),
                                     "stop_sequence": NSNull()],
                           "usage": usage.map { $0 as [String: Any] } ?? AnthropicBridge.usage(nil)])
            events.append(["type": "message_stop"])
            return events
        }

        private mutating func start(_ id: Any?) -> [[String: Any]] {
            if started { return [] }
            started = true
            return [["type": "message_start",
                     "message": ["id": AnthropicBridge.messageId(id), "type": "message", "role": "assistant", "model": requestModel,
                                 "content": [Any](), "stop_reason": NSNull(), "stop_sequence": NSNull(),
                                 "usage": AnthropicBridge.usage(nil)]]]
        }

        private mutating func close() -> [[String: Any]] {
            guard let current = open else { return [] }
            open = nil
            return [["type": "content_block_stop", "index": current.index]]
        }

        private mutating func ensure(_ kind: Kind, _ events: inout [[String: Any]]) -> Int {
            if let current = open, current.kind == kind { return current.index }
            events += close()
            let index = nextIndex
            nextIndex += 1
            open = (kind, index)
            let block: [String: Any] = kind == .text ? ["type": "text", "text": ""] : ["type": "thinking", "thinking": "", "signature": ""]
            events.append(["type": "content_block_start", "index": index, "content_block": block])
            return index
        }
    }

    // MARK: Helpers

    /// JSON text with sorted keys and no spaces, the same bytes the server's `canonicalJSON` writes.
    static func canonicalJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The text of a string or of the text blocks in a list, joined with a blank line.
    private static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        return objects(content).filter { $0["type"] as? String == "text" }.map { $0["text"] as? String ?? "" }.joined(separator: "\n\n")
    }

    private static func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// A JSON number that is not a boolean.
    private static func number(_ value: Any?) -> NSNumber? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    private static func count(_ value: Any?) -> Int {
        guard let n = number(value) else { return 0 }
        return n.intValue
    }
}
