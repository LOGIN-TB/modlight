import Foundation

/// What the user wants from the card. Default `.balanced`.
public enum SuggestionGoal: String, Codable, Sendable, CaseIterable {
    case economical, balanced, fast
}

/// One card Podlight would rent for a model, with everything the user needs to judge it.
public struct GPUOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(choice.cloud.rawValue)|\(choice.gpuId)|\(choice.count)" }
    public var choice: GPUChoice
    public var displayName: String
    /// Memory of one card.
    public var memoryGiB: Int
    /// Price of the whole pod (all cards), per hour.
    public var pricePerHour: Double
    /// Rough decode speed for one request. Always shown as an estimate.
    public var estimatedTokensPerSecond: Double?
    /// The context Podlight would configure on this card.
    public var contextTokens: Int
    /// The most context these cards could hold for this model, for "up to …" hints.
    public var contextCeiling: Int
    public var availability: RunpodGPUType.Availability?
    /// Data centers in the allowed region that report this card, for display.
    public var dataCenters: [String]

    /// "L40S" or "2 × L40S".
    public var label: String { choice.count > 1 ? "\(choice.count) × \(displayName)" : displayName }
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
    /// A coding agent needs room for its system prompt, tools and files.
    public static let minimumUsefulContext = 16_384
    /// What Podlight proposes before the user chooses: enough for an agent, cheap enough to start.
    public static let defaultContext = 65_536
    /// Below this, "balanced" treats a card as too slow to work with.
    public static let comfortableTokensPerSecond = 15.0
    /// Card counts tried per pod. vLLM splits the model across them (tensor parallel).
    public static let cardCounts = [1, 2, 4, 8]

    /// Context steps offered in the interface, up to the model's own limit.
    public static func contextSteps(upTo native: Int?) -> [Int] {
        let ceiling = native ?? 131_072
        var steps = [8_192, 16_384, 32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576].filter { $0 <= ceiling }
        if !steps.contains(ceiling) { steps.append(ceiling) }
        return steps
    }

    /// Cards that can run `model` with `context` tokens, best first for `goal`. For each card type
    /// the fewest cards that hold the context are offered. The list is also the fallback order.
    public static func options(for model: ModelInfo, catalog: [RunpodGPUType], goal: SuggestionGoal,
                               context requested: Int = defaultContext, concurrency: Int = 1,
                               hosting: HostingPolicy = .anywhere, speeds: GPUSpeedTable = .bundled,
                               includeUnavailable: Bool = false) -> [GPUOption] {
        let context = min(requested, model.nativeContextTokens ?? requested)
        let kv = model.kvBytesPerToken
        var options: [GPUOption] = []
        for gpu in catalog where gpu.manufacturer.uppercased() == "NVIDIA" {
            if !includeUnavailable, let a = gpu.availability, !a.mayBeAvailable { continue }
            if !includeUnavailable, !gpu.mayHaveCuda(atLeast: PodPlan.minCudaVersion) { continue }
            if !includeUnavailable, !hosting.mayHaveCapacity(gpu) { continue }
            guard CardSupport.runsEngineImage(gpu.id), model.format.runs(on: gpu.id) else { continue }
            let baseSpeed = speeds.tokensPerSecond(gpuId: gpu.id, weightsGB: model.weightsGB)
            let centers = (gpu.dataCenters ?? []).map(\.id).filter { hosting.allows(dataCenterId: $0) }

            for cloud in hosting.clouds {
                guard let price = gpu.pricePerHour(in: cloud) else { continue }
                for count in cardCounts where count <= gpu.maxCards(in: cloud) {
                    if let heads = model.kvProfile?.attentionHeads, heads % count != 0 { continue }
                    let plan = Capacity.plan(gpuMemoryGiB: Double(gpu.memory), weightsGiB: model.weightsGiB,
                                             nativeContextTokens: model.nativeContextTokens,
                                             chosen: .init(contextTokens: context, concurrency: concurrency),
                                             kvBytesPerToken: kv, gpuCount: count)
                    guard plan.fits else { continue }
                    // More cards add bandwidth, but splitting costs communication: count each extra
                    // card at 60 %. An estimate, shown as one.
                    let speed = baseSpeed.map { $0 * (1 + 0.6 * Double(count - 1)) }
                    options.append(GPUOption(
                        choice: GPUChoice(gpuId: gpu.id, cloud: cloud, count: count), displayName: gpu.name,
                        memoryGiB: gpu.memory, pricePerHour: price * Double(count), estimatedTokensPerSecond: speed,
                        contextTokens: context, contextCeiling: plan.contextCeiling,
                        availability: gpu.availability, dataCenters: centers))
                    break
                }
            }
        }
        return rank(options, goal: goal)
    }

    /// The longest context any offered card combination could hold, for "at most …" hints when
    /// nothing fits.
    public static func largestFeasibleContext(for model: ModelInfo, catalog: [RunpodGPUType],
                                              hosting: HostingPolicy = .anywhere) -> Int {
        contextSteps(upTo: model.nativeContextTokens).reversed().first { step in
            !options(for: model, catalog: catalog, goal: .economical, context: step, hosting: hosting).isEmpty
        } ?? 0
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
