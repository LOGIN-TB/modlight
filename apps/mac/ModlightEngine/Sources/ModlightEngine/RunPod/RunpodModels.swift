import Foundation

// Shapes of RunPod's REST API v2 (https://api.runpod.io/v2), as far as Modlight uses them.
// Taken from real responses captured on 2026-11-20, not from documentation prose. Unknown fields
// are ignored, so RunPod adding one does not break decoding.

/// Which RunPod cloud a pod runs in. Prices and capacity differ per cloud.
public enum RunpodCloud: String, Codable, Sendable, Hashable {
    case secure = "SECURE"
    case community = "COMMUNITY"
}

public struct RunpodPod: Codable, Sendable, Equatable, Identifiable {
    public struct GPU: Codable, Sendable, Equatable {
        public var id: String
        public var count: Int?
    }

    public var id: String
    public var name: String
    public var status: PodState.Status
    /// Transitions RunPod allows from here, e.g. `stop`, `start`, `terminate`.
    public var actions: [String]?
    public var gpu: GPU?
    public var cloud: RunpodCloud?
    /// USD per hour while running.
    public var cost: Double?
    public var image: String?
    public var createdAt: Date?
    /// Set again on every resume (measured 2026-11-23).
    public var startedAt: Date?
    public var dataCenterId: String?
    /// The pod's environment. Modlight's pods carry their model and pod key here.
    public var env: [String: String]?
    /// Container disk in GB.
    public var disk: Int?
    public var mounts: CreatePodRequest.Mounts?
}

/// A pod template. Modlight keeps one private template per model as the model's record in the
/// account (see `ModelRecord`).
public struct RunpodTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var env: [String: String]?

    public init(id: String, name: String, env: [String: String]?) {
        self.id = id
        self.name = name
        self.env = env
    }
}

struct RunpodTemplateList: Decodable {
    var templates: [RunpodTemplate]
    private enum CodingKeys: String, CodingKey { case templates }
    /// RunPod answers with a bare array or with `{"templates": [...]}`; a template that does not
    /// decode is skipped.
    init(from decoder: Decoder) throws {
        var list: UnkeyedDecodingContainer
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self), keyed.contains(.templates) {
            list = try keyed.nestedUnkeyedContainer(forKey: .templates)
        } else {
            list = try decoder.unkeyedContainer()
        }
        var out: [RunpodTemplate] = []
        struct Skipped: Decodable {}
        while !list.isAtEnd {
            if let t = try? list.decode(RunpodTemplate.self) { out.append(t) } else { _ = try? list.decode(Skipped.self) }
        }
        templates = out
    }
}

public struct RunpodPodList: Codable, Sendable {
    public struct Pagination: Codable, Sendable {
        public var hasNextPage: Bool?
        public var nextCursor: String?
    }
    public var pods: [RunpodPod]
    public var pagination: Pagination?

    private enum CodingKeys: String, CodingKey { case pods, pagination }
    private struct Skipped: Decodable {}

    /// A pod that does not decode (a shape Modlight does not know, someone else's odd pod) is
    /// left out instead of making the whole list unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pagination = try c.decodeIfPresent(Pagination.self, forKey: .pagination)
        var list = try c.nestedUnkeyedContainer(forKey: .pods)
        var pods: [RunpodPod] = []
        while !list.isAtEnd {
            if let pod = try? list.decode(RunpodPod.self) { pods.append(pod) } else { _ = try? list.decode(Skipped.self) }
        }
        self.pods = pods
    }
}

/// What Modlight asks RunPod to create. Only the fields Modlight sets.
public struct CreatePodRequest: Codable, Sendable, Equatable {
    public struct GPU: Codable, Sendable, Equatable {
        public var id: String
        public var count: Int
        /// Lowest CUDA version the host must offer, as `major.minor`. The engine image dictates it.
        public var minCudaVersion: String?
        public init(id: String, count: Int = 1, minCudaVersion: String? = nil) {
            self.id = id
            self.count = count
            self.minCudaVersion = minCudaVersion
        }
    }

    public var name: String
    public var image: String
    public var cloud: RunpodCloud
    public var gpu: GPU
    /// Container disk in GB.
    public var disk: Int
    /// e.g. `8000/http`.
    public var ports: [String]
    public var env: [String: String]
    /// Arguments for the image's entrypoint. Parsed shell-style by RunPod.
    public var args: String?
    /// Replaces the image's entrypoint (exec form). Lets Modlight run its own start script in the
    /// stock vLLM image instead of maintaining an image of its own.
    public var entrypoint: [String]?
    public var cmd: [String]?
    public var mounts: Mounts?
    public var dataCenterIds: [String]?

    /// Host-local disk that survives stop/start, so a resumed pod does not download the model again.
    public struct Mounts: Codable, Sendable, Equatable {
        public struct Persistent: Codable, Sendable, Equatable {
            public var size: Int
            public var path: String
        }
        public var persistent: Persistent?
        public init(persistentGB: Int, path: String = "/workspace") {
            persistent = Persistent(size: max(10, persistentGB), path: path)
        }
    }

    public init(name: String, image: String, cloud: RunpodCloud, gpu: GPU, disk: Int, ports: [String],
                env: [String: String], args: String? = nil, entrypoint: [String]? = nil, cmd: [String]? = nil,
                mounts: Mounts? = nil, dataCenterIds: [String]? = nil) {
        self.name = name
        self.image = image
        self.cloud = cloud
        self.gpu = gpu
        self.disk = disk
        self.ports = ports
        self.env = env
        self.args = args
        self.entrypoint = entrypoint
        self.cmd = cmd
        self.mounts = mounts
        self.dataCenterIds = dataCenterIds
    }
}

/// One card type in RunPod's catalog.
public struct RunpodGPUType: Codable, Sendable, Equatable, Identifiable {
    /// RunPod reports `LOW` or `NONE` in practice. Neither is a promise: a card reported `LOW`
    /// was gone seconds later in testing, so creation must always be ready to fall back.
    public enum Availability: Codable, Sendable, Equatable {
        case none, low, medium, high
        case other(String)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "NONE": self = .none
            case "LOW": self = .low
            case "MEDIUM": self = .medium
            case "HIGH": self = .high
            default: self = .other(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .none: try c.encode("NONE")
            case .low: try c.encode("LOW")
            case .medium: try c.encode("MEDIUM")
            case .high: try c.encode("HIGH")
            case .other(let raw): try c.encode(raw)
            }
        }

        /// Worth trying at all. Says nothing about whether it will still be there.
        public var mayBeAvailable: Bool {
            switch self {
            case .none: false
            default: true
            }
        }
    }

    public struct Price: Codable, Sendable, Equatable {
        public var community: Double?
        public var secure: Double?
    }

    public struct MaxCount: Codable, Sendable, Equatable {
        public var community: Int?
        public var secure: Int?
    }

    /// One data center that offers this card, with its availability.
    public struct DataCenterAvailability: Codable, Sendable, Equatable {
        public var id: String
        public var name: String?
        public var availability: Availability?
    }

    /// CUDA versions RunPod's hosts with this card run, and whether any of them is free now.
    public struct CudaVersion: Codable, Sendable, Equatable {
        public var version: String
        public var available: Bool
    }

    public var id: String
    public var name: String
    public var manufacturer: String
    /// VRAM in GB.
    public var memory: Int
    public var secure: Bool
    public var community: Bool
    public var price: Price
    public var availability: Availability?
    public var cudaVersions: [CudaVersion]?
    /// The most cards of this type one pod can have, per cloud (the largest machine).
    public var maxCount: MaxCount?
    public var dataCenters: [DataCenterAvailability]?

    public func maxCards(in cloud: RunpodCloud) -> Int {
        let value = cloud == .secure ? maxCount?.secure : maxCount?.community
        return value ?? 1
    }

    /// Whether a host with at least `minimum` CUDA may be free. True when RunPod does not say.
    public func mayHaveCuda(atLeast minimum: String) -> Bool {
        guard let versions = cudaVersions, !versions.isEmpty else { return true }
        return versions.contains { $0.available && Self.compare($0.version, minimum) >= 0 }
    }

    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// Hourly price in this cloud, or nil when the card is not offered there. RunPod reports
    /// `0` for "not offered", so 0 is treated the same as missing.
    public func pricePerHour(in cloud: RunpodCloud) -> Double? {
        let offered = cloud == .secure ? secure : community
        let value = cloud == .secure ? price.secure : price.community
        guard offered, let value, value > 0 else { return nil }
        return value
    }
}

public struct RunpodGPUCatalog: Codable, Sendable {
    public var gpus: [RunpodGPUType]
}

/// The RunPod account's credit (`myself` in RunPod's GraphQL API).
public struct RunpodBalance: Codable, Sendable, Equatable {
    /// Credit left, USD.
    public var usd: Double
    /// What everything in the account costs per hour right now, by RunPod.
    public var spendPerHourUsd: Double
    /// RunPod's own spend limit for the account.
    public var spendLimitUsd: Double?
    /// When it was read (set by whoever reads it).
    public var checkedAt: Date?

    public init(usd: Double, spendPerHourUsd: Double, spendLimitUsd: Double?, checkedAt: Date? = nil) {
        self.usd = usd
        self.spendPerHourUsd = spendPerHourUsd
        self.spendLimitUsd = spendLimitUsd
        self.checkedAt = checkedAt
    }

    /// Hours the credit lasts at the current rate; nil while nothing costs anything.
    public var hoursLeft: Double? { spendPerHourUsd > 0 ? usd / spendPerHourUsd : nil }
}
