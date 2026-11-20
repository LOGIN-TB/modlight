import Foundation

/// Sends one HTTP request. `URLSession` in the app; a recording fake in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// RunPod answered, but not with success.
public struct RunpodError: Error, Sendable, Equatable, CustomStringConvertible {
    public var status: Int
    public var operation: String
    /// The start of RunPod's response body. Never contains the API key: RunPod does not echo it.
    public var body: String

    public var description: String { "RunPod \(operation) failed: \(status) \(body.prefix(300))" }

    /// No machine with that card was free. Not an edge case: capacity for affordable cards moves
    /// within seconds (measured 2026-08-30 and again 2026-11-20). Means "try another card".
    public var isCapacityExhausted: Bool {
        status == 400 && body.localizedCaseInsensitiveContains("no longer any instances available")
    }

    /// A stopped pod cannot resume because its host gave the card away. Build a new one instead.
    public var isHostGPUUnavailable: Bool {
        status == 400 && body.localizedCaseInsensitiveContains("not enough free GPUs")
    }

    public var isUnauthorized: Bool { status == 401 }
    public var isForbidden: Bool { status == 403 }
    public var isNotFound: Bool { status == 404 }
}

/// Result of checking a key the user just pasted. Each case needs a different sentence in setup.
public enum RunpodKeyCheck: Sendable, Equatable {
    case valid
    /// Wrong, revoked or mistyped.
    case invalid
    /// Real key, but its permissions do not include managing pods.
    case missingPermission
    /// RunPod could not be reached; the key may be fine.
    case unreachable(String)
}

/// The RunPod REST API v2, as far as Podlight needs it.
///
/// Always `api.runpod.io/v2`: `rest.runpod.io/v1` was not even reachable from inside a pod when
/// measured, and the dead-man switch in the pod must use the same API as the app.
public struct RunpodClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.runpod.io")!

    private let apiKey: String
    private let transport: HTTPTransport
    private let baseURL: URL

    public init(apiKey: String, transport: HTTPTransport = URLSession.shared, baseURL: URL = defaultBaseURL) {
        self.apiKey = apiKey
        self.transport = transport
        self.baseURL = baseURL
    }

    // MARK: Key

    /// Checks a key without changing anything. Podlight needs to read and write pods.
    public func checkKey() async -> RunpodKeyCheck {
        do {
            _ = try await call("listPods", "GET", "/v2/pods", query: ["limit": "1"]) as RunpodPodList
            return .valid
        } catch let error as RunpodError where error.isUnauthorized {
            return .invalid
        } catch let error as RunpodError where error.isForbidden {
            return .missingPermission
        } catch let error as RunpodError {
            return .unreachable("RunPod answered \(error.status)")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    // MARK: Pods

    public func listPods() async throws -> [RunpodPod] {
        let list: RunpodPodList = try await call("listPods", "GET", "/v2/pods")
        return list.pods
    }

    public func pod(id: String) async throws -> RunpodPod {
        try await call("getPod", "GET", "/v2/pods/\(escape(id))")
    }

    public func createPod(_ request: CreatePodRequest) async throws -> RunpodPod {
        try await call("createPod", "POST", "/v2/pods", body: request)
    }

    public enum PodAction: String, Sendable { case start, stop, restart, terminate }

    /// `stop` ends GPU billing and keeps the disk; `start` resumes on the same host if it can.
    public func perform(_ action: PodAction, onPod id: String) async throws -> RunpodPod {
        try await call("podAction", "POST", "/v2/pods/\(escape(id))/action", body: ["action": action.rawValue])
    }

    /// Removes the pod and its disk for good.
    public func deletePod(id: String) async throws {
        _ = try await raw("deletePod", "DELETE", "/v2/pods/\(escape(id))")
    }

    // MARK: Catalog

    /// The card catalog. Ask with availability every time before starting: a stored answer goes
    /// stale within minutes.
    public func gpuCatalog(withAvailability: Bool = true) async throws -> [RunpodGPUType] {
        let query = withAvailability ? ["include": "AVAILABILITY", "product": "POD", "count": "1"] : [:]
        let catalog: RunpodGPUCatalog = try await call("listGpuTypes", "GET", "/v2/catalog/gpus", query: query)
        return catalog.gpus
    }

    // MARK: Plumbing

    private func call<T: Decodable>(_ operation: String, _ method: String, _ path: String,
                                    query: [String: String] = [:], body: (any Encodable & Sendable)? = nil) async throws -> T {
        let data = try await raw(operation, method, path, query: query, body: body)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw RunpodError(status: 200, operation: operation,
                              body: "unexpected response shape: \(error)")
        }
    }

    @discardableResult
    private func raw(_ operation: String, _ method: String, _ path: String,
                     query: [String: String] = [:], body: (any Encodable & Sendable)? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw RunpodError(status: response.statusCode, operation: operation,
                              body: String(decoding: data.prefix(500), as: UTF8.self))
        }
        return data
    }

    private func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "not ISO 8601: \(text)"))
        }
        return decoder
    }()
}
