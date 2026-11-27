import Foundation

/// One sample of what a pod is doing, measured by its watchdog (spec/pod/watchdog.py) and sent back
/// with each heartbeat. RunPod's API reports no GPU memory in use and no disk, so the pod measures
/// itself. A source the pod lacks leaves its fields nil. Mirrors `podTelemetry` in server/src/model.ts.
public struct PodTelemetry: Codable, Sendable, Equatable {
    /// Unix seconds, from the pod's clock.
    public var time: Double
    public var cpuPercent: Double?
    public var memoryUsedBytes: Double?
    public var memoryTotalBytes: Double?
    public var diskUsedBytes: Double?
    public var diskTotalBytes: Double?
    public var volumeUsedBytes: Double?
    public var volumeTotalBytes: Double?
    public var gpus: [GPU]?
    public var engine: Engine?

    public struct GPU: Codable, Sendable, Equatable {
        public var index: Int?
        public var name: String?
        public var utilPercent: Double?
        public var memoryUsedBytes: Double?
        public var memoryTotalBytes: Double?
        public var temperatureC: Double?
        public var powerW: Double?
        public var powerLimitW: Double?

        public init(index: Int? = nil, name: String? = nil, utilPercent: Double? = nil, memoryUsedBytes: Double? = nil,
                    memoryTotalBytes: Double? = nil, temperatureC: Double? = nil, powerW: Double? = nil, powerLimitW: Double? = nil) {
            self.index = index; self.name = name; self.utilPercent = utilPercent
            self.memoryUsedBytes = memoryUsedBytes; self.memoryTotalBytes = memoryTotalBytes
            self.temperatureC = temperatureC; self.powerW = powerW; self.powerLimitW = powerLimitW
        }
    }

    /// What the engine reports on /metrics. Rates cover the seconds since the previous sample.
    public struct Engine: Codable, Sendable, Equatable {
        public var running: Int?
        public var waiting: Int?
        public var kvCachePercent: Double?
        public var promptTokensPerSecond: Double?
        public var generationTokensPerSecond: Double?
        /// Since the engine started: prompt tokens read (reused ones included) and tokens written.
        public var promptTokensTotal: Int?
        public var generationTokensTotal: Int?
        /// Share of prompt tokens taken from the engine's cache instead of being read again.
        public var promptCacheHitPercent: Double?
        /// Tokens per second while reading a prompt and while writing an answer, over the latest
        /// requests; they stay between requests. From 0.10 watchdogs.
        public var promptSpeed: Double?
        public var generationSpeed: Double?

        public init(running: Int? = nil, waiting: Int? = nil, kvCachePercent: Double? = nil,
                    promptTokensPerSecond: Double? = nil, generationTokensPerSecond: Double? = nil,
                    promptTokensTotal: Int? = nil, generationTokensTotal: Int? = nil, promptCacheHitPercent: Double? = nil,
                    promptSpeed: Double? = nil, generationSpeed: Double? = nil) {
            self.running = running; self.waiting = waiting; self.kvCachePercent = kvCachePercent
            self.promptTokensPerSecond = promptTokensPerSecond; self.generationTokensPerSecond = generationTokensPerSecond
            self.promptTokensTotal = promptTokensTotal; self.generationTokensTotal = generationTokensTotal
            self.promptCacheHitPercent = promptCacheHitPercent; self.promptSpeed = promptSpeed; self.generationSpeed = generationSpeed
        }
    }

    public init(time: Double, cpuPercent: Double? = nil, memoryUsedBytes: Double? = nil, memoryTotalBytes: Double? = nil,
                diskUsedBytes: Double? = nil, diskTotalBytes: Double? = nil, volumeUsedBytes: Double? = nil,
                volumeTotalBytes: Double? = nil, gpus: [GPU]? = nil, engine: Engine? = nil) {
        self.time = time; self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes; self.memoryTotalBytes = memoryTotalBytes
        self.diskUsedBytes = diskUsedBytes; self.diskTotalBytes = diskTotalBytes
        self.volumeUsedBytes = volumeUsedBytes; self.volumeTotalBytes = volumeTotalBytes
        self.gpus = gpus; self.engine = engine
    }

    public var date: Date { Date(timeIntervalSince1970: time) }

    /// GPU load across the pod's cards, for the compact indicators.
    public var averageGPUPercent: Double? {
        let values = (gpus ?? []).compactMap(\.utilPercent)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// GPU memory in use across the pod's cards, as a fraction.
    public var gpuMemoryFraction: Double? {
        let cards = gpus ?? []
        let used = cards.compactMap(\.memoryUsedBytes).reduce(0, +)
        let total = cards.compactMap(\.memoryTotalBytes).reduce(0, +)
        return total > 0 ? used / total : nil
    }

    /// 30 minutes of samples at the 10-second tick.
    public static let historyLimit = 180
}
