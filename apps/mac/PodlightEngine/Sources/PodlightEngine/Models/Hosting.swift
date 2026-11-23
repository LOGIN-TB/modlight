import Foundation

/// Where pods may run. "EU" and "EU + EEA" are matched by data-center ID prefix (spec/data/regions.json).
public enum HostingRegion: String, Codable, Sendable, CaseIterable {
    case anywhere, eu, euEEA

    public var prefixes: [String]? {
        switch self {
        case .anywhere: nil
        case .eu: ["EU-"]
        case .euEEA: ["EU-", "EUR-IS-", "EUR-NO-"]
        }
    }
}

/// The hosting rules for a start: which data centers, which clouds.
public struct HostingPolicy: Codable, Sendable, Equatable {
    public var region: HostingRegion
    /// Only RunPod's Secure Cloud: certified data centers instead of community hosts.
    public var secureOnly: Bool

    public init(region: HostingRegion = .anywhere, secureOnly: Bool = false) {
        self.region = region
        self.secureOnly = secureOnly
    }

    public static let anywhere = HostingPolicy()

    /// With a region chosen only Secure Cloud is used: community pods report no data center
    /// (`dataCenterId` stayed empty while running, measured 2026-11-21), so their location could
    /// never be checked.
    public var clouds: [RunpodCloud] { secureOnly || region.prefixes != nil ? [.secure] : [.secure, .community] }

    /// Whether a pod's placement must be confirmed by a reported data center.
    public var needsPlacementCheck: Bool { region.prefixes != nil }

    public func allows(dataCenterId: String?) -> Bool {
        guard let prefixes = region.prefixes else { return true }
        guard let id = dataCenterId else { return false }
        return prefixes.contains { id.hasPrefix($0) }
    }

    /// Whether a card may be free somewhere this policy allows. Without per-data-center figures
    /// the card is kept: the request restricts placement and the check after the start decides.
    public func mayHaveCapacity(_ gpu: RunpodGPUType) -> Bool {
        guard region.prefixes != nil, let centers = gpu.dataCenters, !centers.isEmpty else { return true }
        return centers.contains { allows(dataCenterId: $0.id) && ($0.availability?.mayBeAvailable ?? true) }
    }

    /// The data centers to request, collected from the catalog. Nil means "let RunPod choose".
    public func dataCenterIds(in catalog: [RunpodGPUType]) -> [String]? {
        guard region.prefixes != nil else { return nil }
        let ids = Set(catalog.flatMap { $0.dataCenters ?? [] }.map(\.id).filter { allows(dataCenterId: $0) })
        return ids.sorted()
    }
}

/// RunPod's storage prices (docs.runpod.io/pods/pricing, 2026-11-21), in USD per GB and month.
public enum StoragePricing {
    public static let containerDiskRunning = 0.10
    public static let volumeDiskRunning = 0.10
    public static let volumeDiskStopped = 0.20
    public static let hoursPerMonth = 730.0

    /// Storage cost per hour while the pod runs.
    public static func runningPerHour(containerGB: Int, volumeGB: Int) -> Double {
        (Double(containerGB) * containerDiskRunning + Double(volumeGB) * volumeDiskRunning) / hoursPerMonth
    }

    /// Storage cost per month while the pod is stopped (only a kept volume disk is billed).
    public static func stoppedPerMonth(volumeGB: Int) -> Double {
        Double(volumeGB) * volumeDiskStopped
    }

    /// Storage cost per hour while the pod is stopped; RunPod bills it by the hour.
    public static func stoppedPerHour(volumeGB: Int) -> Double {
        stoppedPerMonth(volumeGB: volumeGB) / hoursPerMonth
    }
}
