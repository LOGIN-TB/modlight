import Foundation

/// One card type in one cloud to try, and how many of them in one pod.
public struct GPUChoice: Sendable, Hashable, Codable {
    public var gpuId: String
    public var cloud: RunpodCloud
    /// Cards in the pod (tensor parallel). 1 unless a long context needs more memory.
    public var count: Int

    public init(gpuId: String, cloud: RunpodCloud, count: Int = 1) {
        self.gpuId = gpuId
        self.cloud = cloud
        self.count = max(1, count)
    }

    // 0.1 stored choices without a count.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gpuId = try c.decode(String.self, forKey: .gpuId)
        cloud = try c.decode(RunpodCloud.self, forKey: .cloud)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
    }
}

/// What happened to one choice while creating a pod. Shown to the user ("RTX 3090 was taken,
/// started on V100 instead") and kept for the cost record.
public struct CreationAttempt: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case created
        /// RunPod had no free machine with that card.
        case noCapacity
        /// Not tried: the catalog said none are available right now.
        case skippedUnavailable
    }
    public var choice: GPUChoice
    public var outcome: Outcome
}

public struct PodCreated: Sendable {
    public var pod: RunpodPod
    public var choice: GPUChoice
    public var attempts: [CreationAttempt]
    /// True when the first choice was not the one that worked.
    public var usedFallback: Bool { attempts.first?.choice != choice }
}

/// Every choice was taken. Carries the attempts so the interface can say which cards were tried.
public struct NoCapacityError: Error, Sendable, Equatable {
    public var attempts: [CreationAttempt]
}

extension RunpodClient {
    /// Creates a pod on the first card in `choices` that RunPod can actually provide.
    ///
    /// Capacity is the normal failure, not an exception: on 2026-11-20 three cards the catalog
    /// listed as available were gone seconds later. Any other error (bad key, invalid request)
    /// stops immediately, because trying the next card would fail the same way.
    ///
    /// - Parameter catalog: when given, choices the catalog marks as having none available are
    ///   skipped without asking RunPod. An empty or missing catalog tries everything.
    public func createPod(_ base: CreatePodRequest, tryingInOrder choices: [GPUChoice],
                          catalog: [RunpodGPUType] = []) async throws -> PodCreated {
        let cards = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var attempts: [CreationAttempt] = []

        for choice in choices {
            let card = cards[choice.gpuId]
            let noneFree = card?.availability.map { !$0.mayBeAvailable } ?? false
            // A card whose free hosts all run an older CUDA than the engine image needs would
            // accept the pod and then fail to start the engine.
            let noSuitableHost: Bool = {
                guard let minimum = base.gpu.minCudaVersion, let card else { return false }
                return !card.mayHaveCuda(atLeast: minimum)
            }()
            if noneFree || noSuitableHost {
                attempts.append(CreationAttempt(choice: choice, outcome: .skippedUnavailable))
                continue
            }
            var request = base
            request.gpu.id = choice.gpuId
            request.gpu.count = choice.count
            request.cloud = choice.cloud
            // The engine must split across exactly the cards this attempt gets. A fallback with fewer
            // cards than the first choice otherwise starts vLLM with a tensor-parallel size the pod
            // cannot meet, and it exits at once (seen live on 2026-11-21).
            if request.env["MODLIGHT_TP"] != nil { request.env["MODLIGHT_TP"] = String(choice.count) }
            do {
                let pod = try await createPod(request)
                attempts.append(CreationAttempt(choice: choice, outcome: .created))
                return PodCreated(pod: pod, choice: choice, attempts: attempts)
            } catch let error as RunpodError where error.isCapacityExhausted {
                attempts.append(CreationAttempt(choice: choice, outcome: .noCapacity))
            }
        }
        throw NoCapacityError(attempts: attempts)
    }
}
