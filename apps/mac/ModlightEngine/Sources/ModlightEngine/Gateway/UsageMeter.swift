import Foundation

/// Reads what an API provider's answer used while it passes through the gateway, line by line.
///
/// A streamed answer (server-sent events) carries usage in its last chunk, which Modlight asked
/// for with `stream_options.include_usage`; if the agent did not ask itself, that chunk is dropped
/// so the agent sees the stream it expected. A plain JSON answer is kept until it ends and read
/// then. Nothing is changed otherwise.
struct UsageMeter {
    /// Drop the usage-only chunk (empty `choices`) of a chat completion stream.
    let dropUsageChunk: Bool
    private(set) var usage: APIUsage?
    /// When the first chunk with model output passed: the time to first token.
    private(set) var firstContentAt: Date?
    private var body = Data()
    private var bodyTooLong = false
    private static let bodyLimit = 32 * 1024 * 1024

    init(dropUsageChunk: Bool) {
        self.dropUsageChunk = dropUsageChunk
    }

    /// One line of the answer, newline included. Returns what to pass on: the line, or nothing.
    mutating func pass(_ line: Data) -> Data? {
        guard line.starts(with: Self.dataPrefix) else {
            keep(line)
            return line
        }
        let payload = line.dropFirst(Self.dataPrefix.count)
        guard let json = (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any] else { return line }
        if firstContentAt == nil, APITelemetry.hasContent(json) { firstContentAt = Date() }
        guard let found = APIUsage.from(json) else { return line }
        usage = found
        if dropUsageChunk, let choices = json["choices"] as? [Any], choices.isEmpty { return nil }
        return line
    }

    /// The usage, once the answer has ended.
    mutating func finish() -> APIUsage? {
        if usage == nil, !bodyTooLong, !body.isEmpty,
           let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            usage = APIUsage.from(json)
        }
        return usage
    }

    private mutating func keep(_ line: Data) {
        guard !bodyTooLong else { return }
        if body.count + line.count > Self.bodyLimit {
            bodyTooLong = true
            body = Data()
        } else {
            body.append(line)
        }
    }

    private static let dataPrefix = Data("data:".utf8)
}
