import Foundation

// Shapes of RunPod's REST API v2 (https://api.runpod.io/v2), as far as Podlight uses them.
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
    public var startedAt: Date?
    public var dataCenterId: String?
}

public struct RunpodPodList: Codable, Sendable {
    public var pods: [RunpodPod]
}

/// What Podlight asks RunPod to create. Only the fields Podlight sets.
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
    /// Replaces the image's entrypoint (exec form). Lets Podlight run its own start script in the
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
