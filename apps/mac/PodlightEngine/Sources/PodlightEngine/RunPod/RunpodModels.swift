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
        public init(id: String, count: Int = 1) { self.id = id; self.count = count }
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
    public var dataCenterIds: [String]?

    public init(name: String, image: String, cloud: RunpodCloud, gpu: GPU, disk: Int, ports: [String],
                env: [String: String], args: String? = nil, dataCenterIds: [String]? = nil) {
        self.name = name
        self.image = image
        self.cloud = cloud
        self.gpu = gpu
        self.disk = disk
        self.ports = ports
        self.env = env
        self.args = args
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

    public var id: String
    public var name: String
    public var manufacturer: String
    /// VRAM in GB.
    public var memory: Int
    public var secure: Bool
    public var community: Bool
    public var price: Price
    public var availability: Availability?

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
