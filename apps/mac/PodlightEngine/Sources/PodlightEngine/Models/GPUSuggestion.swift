import Foundation

/// What the user wants from the card. Default `.balanced`.
public enum SuggestionGoal: String, Codable, Sendable, CaseIterable {
    case economical, balanced, fast
}

/// One card Podlight would rent for a model, with everything the user needs to judge it.
public struct GPUOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(choice.cloud.rawValue)|\(choice.gpuId)" }
    public var choice: GPUChoice
    public var displayName: String
    public var memoryGiB: Int
    public var pricePerHour: Double
    /// Rough decode speed for one request. Always shown as an estimate.
    public var estimatedTokensPerSecond: Double?
    /// The context Podlight would configure on this card.
    public var contextTokens: Int
    public var availability: RunpodGPUType.Availability?
}

/// Bandwidth table from `spec/data/gpus.json`, bundled with the engine.
public struct GPUSpeedTable: Sendable {
    public struct Entry: Codable, Sendable {
        public var bandwidthGBs: Double
        public var measuredFactor: Double?
    }
    struct File: Codable {
        struct SpeedModel: Codable { var efficiency: Double }
        var speedModel: SpeedModel
        var gpus: [String: Entry]
    }

    public var efficiency: Double
    public var entries: [String: Entry]

    public static let bundled: GPUSpeedTable = {
        guard let url = Bundle.module.url(forResource: "gpus", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return GPUSpeedTable(efficiency: 0.6, entries: [:]) }
        return GPUSpeedTable(efficiency: file.speedModel.efficiency, entries: file.gpus)
    }()

    public init(efficiency: Double, entries: [String: Entry]) {
        self.efficiency = efficiency
        self.entries = entries
    }

    public func tokensPerSecond(gpuId: String, weightsGB: Double) -> Double? {
        guard weightsGB > 0, let entry = entries[gpuId] else { return nil }
        return entry.bandwidthGBs / weightsGB * efficiency * (entry.measuredFactor ?? 1)
    }
}

public enum GPUSuggestion {
    /// A coding agent needs room for its system prompt, tools and files. Cards that cannot give
    /// this much context are not suggested.
    public static let minimumUsefulContext = 16_384
    /// Context Podlight aims for when the card has more: agents rarely use more, and a smaller
    /// window leaves room for a second request.
    public static let targetContext = 65_536
    /// Below this, "balanced" treats a card as too slow to work with.
    public static let comfortableTokensPerSecond = 15.0

    /// Cards that can run `model`, best first for `goal`. The whole list is the fallback order:
    /// when the first card is taken, Podlight tries the next.
    public static func options(for model: ModelInfo, catalog: [RunpodGPUType], goal: SuggestionGoal,
                               speeds: GPUSpeedTable = .bundled, includeUnavailable: Bool = false) -> [GPUOption] {
        var options: [GPUOption] = []
        for gpu in catalog where gpu.manufacturer.uppercased() == "NVIDIA" {
            if !includeUnavailable, let a = gpu.availability, !a.mayBeAvailable { continue }
            guard model.format.runs(on: gpu.id) else { continue }
            guard let recommended = Capacity.recommend(gpuMemoryGiB: Double(gpu.memory), weightsGiB: model.weightsGiB,
                                                       nativeContextTokens: model.nativeContextTokens),
                  recommended.contextTokens >= min(minimumUsefulContext, model.nativeContextTokens ?? .max)
            else { continue }
            let context = min(recommended.contextTokens, targetContext)
            let speed = speeds.tokensPerSecond(gpuId: gpu.id, weightsGB: model.weightsGB)
            for cloud in [RunpodCloud.secure, .community] {
                guard let price = gpu.pricePerHour(in: cloud) else { continue }
                options.append(GPUOption(choice: GPUChoice(gpuId: gpu.id, cloud: cloud), displayName: gpu.name,
                                         memoryGiB: gpu.memory, pricePerHour: price, estimatedTokensPerSecond: speed,
                                         contextTokens: context, availability: gpu.availability))
            }
        }
        return rank(options, goal: goal)
    }

    static func rank(_ options: [GPUOption], goal: SuggestionGoal) -> [GPUOption] {
        let speed: (GPUOption) -> Double = { $0.estimatedTokensPerSecond ?? 0 }
        switch goal {
        case .economical:
            return options.sorted { ($0.pricePerHour, -speed($0)) < ($1.pricePerHour, -speed($1)) }
        case .fast:
            return options.sorted { (-speed($0), $0.pricePerHour) < (-speed($1), $1.pricePerHour) }
        case .balanced:
            // Comfortable cards first, cheapest speed per dollar among them; then the rest by speed.
            let value: (GPUOption) -> Double = { speed($0) / max($0.pricePerHour, 0.01) }
            let comfortable = options.filter { speed($0) >= comfortableTokensPerSecond }
                .sorted { (-value($0), $0.pricePerHour) < (-value($1), $1.pricePerHour) }
            let slow = options.filter { speed($0) < comfortableTokensPerSecond }
                .sorted { (-speed($0), $0.pricePerHour) < (-speed($1), $1.pricePerHour) }
            return comfortable + slow
        }
    }

    /// Cost of running until `end`, at the hourly price.
    public static func cost(pricePerHour: Double, from start: Date, until end: Date) -> Double {
        max(0, end.timeIntervalSince(start)) / 3600 * pricePerHour
    }
}
