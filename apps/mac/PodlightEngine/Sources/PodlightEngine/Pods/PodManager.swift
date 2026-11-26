import Foundation
import Security

/// Things that stop a start or a request, each with its own sentence in the interface.
public enum PodlightError: Error, Sendable, Equatable {
    case missingRunpodKey
    /// `daily-limit` or `monthly-limit`.
    case limitReached(String)
    /// Every suitable card was taken. Names of the cards tried.
    case noCapacity([String])
    /// No card in RunPod's catalog can hold this model with its configured context.
    case noSuitableCard
    case unknownModel(String)
    case runpod(status: Int, message: String)
    /// The engine did not answer within the wake wait.
    case notReadyInTime
    /// The model is stopped and waking on request is switched off.
    case wakeDisabled
    case keychain(String)
    /// Another Mac took this model over (its readable name). Take it back to use it here.
    case managedElsewhere(String)
    /// Taking a pod over would add a second model with this name.
    case nameTaken(String)
    /// Hugging Face could not describe the model of a pod being taken over.
    case modelLookup(String)
    /// The card on the machine of a stopped pod is taken. The pod and its disk are kept; start
    /// again later, or on a new card (which builds a new pod and downloads the model again).
    case hostBusy
    /// The model is starting, stopping or waiting for a card; it can move once it runs or stopped.
    case busy
    /// The chosen card is taken and the free ones cost more than the price step allows. Nothing
    /// was booked; Podlight waits for a card up to `ceiling` (when it may), and the user can
    /// start on one of `pricier` instead.
    case cardTooExpensive(wanted: PricedChoice?, ceiling: Double, pricier: [PricedChoice])
    /// An API model, but no key for its provider in the keychain.
    case missingProviderKey(ModelProvider)
    /// The provider answered with an error (balance, key limit, refused key, rate limit …).
    case provider(ProviderFailure)
    /// The provider does not serve this API path (e.g. Venice has no legacy `/v1/completions`).
    case unsupportedPath(String, ModelProvider)
}

/// Where the gateway forwards a request.
public struct PodEndpoint: Sendable, Equatable {
    public var modelId: UUID
    public var baseURL: URL
    public var key: String
}

/// Runs the pods for "This Mac": starts them, keeps them alive while wanted, and stops them when
/// a rule says so. RunPod is the source of truth; every tick re-reads it.
public actor PodManager {
    public let store: StateStore
    private let keychain: KeychainStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    /// Address of one port of a pod. RunPod's proxy in the app; a local server in tests.
    private let podURL: @Sendable (_ podId: String, _ port: Int) -> URL
    private var inFlight: [UUID: Int] = [:]
    private var starts: [UUID: Task<Void, Error>] = [:]
    /// Telemetry per model while its pod runs, the last 30 minutes. In memory only.
    private var samples: [UUID: [PodTelemetry]] = [:]
    /// What was last written to each model's record, so unchanged records are not written again.
    private var published: [UUID: String] = [:]
    private var lastRecordCheck: Date?

    /// How often and how far apart a resume is tried again while the pod's machine has no free
    /// card. RunPod often frees it within seconds (measured: 10 s after a stop).
    private let hostBusyTries: Int
    private let hostBusyDelay: Duration
    /// While the machine stays busy, the resume is tried again this often, in the background.
    private let cardRetryInterval: TimeInterval
    /// A loading engine with no sign of progress for this long is taken as hung.
    private let loadStallLimit: TimeInterval
    /// What a loading pod last showed of its progress, and since when, per model. In memory only.
    private var loadProgress: [UUID: (signature: LoadSignature, since: Date)] = [:]

    public init(store: StateStore, keychain: KeychainStore = KeychainStore(),
                transport: HTTPTransport = URLSession.shared, now: @escaping @Sendable () -> Date = Date.init,
                podURL: @escaping @Sendable (_ podId: String, _ port: Int) -> URL = PodPlan.proxyURL,
                hostBusyTries: Int = 5, hostBusyDelay: Duration = .seconds(15),
                cardRetryInterval: TimeInterval = 30, loadStallLimit: TimeInterval = 600) {
        self.hostBusyTries = max(1, hostBusyTries)
        self.hostBusyDelay = hostBusyDelay
        self.cardRetryInterval = cardRetryInterval
        self.loadStallLimit = loadStallLimit
        self.store = store
        self.keychain = keychain
        self.transport = transport
        self.now = now
        self.podURL = podURL
    }

    public func state() async -> PodlightState { await store.current() }

    // MARK: Models

    public func save(_ model: PodlightModel) async throws {
        var adjusted = model
        adjusted.schedule.idleStopMinutes = max(5, adjusted.schedule.idleStopMinutes)
        let model = adjusted
        try await store.update { state in
            if let index = state.models.firstIndex(where: { $0.id == model.id }) {
                state.models[index] = model
            } else {
                state.models.append(model)
            }
        }
    }

    /// Removes a model, deleting its pod and disk at RunPod first.
    public func remove(_ id: UUID) async throws {
        samples[id] = nil
        let run = await store.current().run(id)
        // A pod another Mac took over is that Mac's now: removing the model here leaves it alone.
        if let podId = run.podId, run.managedBy == nil, let client = try? client() {
            do { try await client.deletePod(id: podId) } catch let e as RunpodError where e.isNotFound {}
        }
        if let recordId = run.recordId, run.managedBy == nil, let client = try? client() {
            do { try await client.deleteTemplate(id: recordId) } catch let e as RunpodError where e.isNotFound {} catch {}
        }
        published[id] = nil
        try? keychain.delete(.podKey(id))
        try await store.update { state in
            state.models.removeAll { $0.id == id }
            state.runs[id] = nil
        }
    }

    // MARK: Hand over to a server

    /// Hands a model to a Podlight server with its pod (running, or stopped with its disk) and the
    /// pod's key, so nothing is downloaded again. `adopt` is the server's call; it renames the pod
    /// to a server pod. This Mac stops acting on the model first and puts it back if the server
    /// refuses; once the server has it, the model's record in the account goes (other Macs no
    /// longer offer it) and the model leaves this Mac. The pod is never touched here.
    public func handOver(_ id: UUID, toServer serverName: String,
                         adopt: @Sendable (PodlightModel, String, String?) async throws -> Void) async throws {
        let state = await store.current()
        guard let model = state.models.first(where: { $0.id == id }) else { throw PodlightError.unknownModel(id.uuidString) }
        let run = state.run(id)
        if let other = run.managedBy { throw PodlightError.managedElsewhere(PodOwner.displayName(of: other)) }
        guard starts[id] == nil, run.waitingForCard == nil, run.replacing == nil,
              run.phase == .stopped || run.phase == .failed || run.phase == .ready else { throw PodlightError.busy }
        let key = try podKey(for: id)

        try await updateRun(id) { $0.managedBy = serverName; $0.engineReady = false }
        do {
            try await adopt(model, key, run.podId)
        } catch {
            try? await updateRun(id) { $0.managedBy = nil; $0.engineReady = run.engineReady }
            throw error
        }
        account(id: id, run: run) // The server counts from now.
        if let recordId = run.recordId, let client = try? client() {
            do { try await client.deleteTemplate(id: recordId) } catch {}
        }
        published[id] = nil
        samples[id] = nil
        loadProgress[id] = nil
        try? keychain.delete(.podKey(id))
        try await store.update { state in
            state.models.removeAll { $0.id == id }
            state.runs[id] = nil
        }
    }

    // MARK: Start, stop, extend

    /// Starts (or resumes) a model's pod. Returns once RunPod has accepted it; the engine then
    /// needs minutes to load, which `tick` follows.
    /// `newPod`: the user chose a new card for a pod whose machine is busy. Only then is a stopped
    /// pod with its disk deleted to build a new one.
    /// `maxPricePerHour`: the user approved a pricier card; cards up to this price may be booked.
    public func start(_ id: UUID, until runUntil: Date?, manual: Bool = true, newPod: Bool = false,
                      maxPricePerHour: Double? = nil) async throws {
        try await start(id, until: runUntil, manual: manual, newPod: newPod, maxPricePerHour: maxPricePerHour, retrying: nil)
    }

    private func start(_ id: UUID, until runUntil: Date?, manual: Bool, newPod: Bool, maxPricePerHour: Double?,
                       retrying: WaitingForCard?) async throws {
        if let running = starts[id] { return try await running.value }
        let task = Task {
            try await self.performStart(id, until: runUntil, manual: manual, newPod: newPod,
                                        maxPricePerHour: maxPricePerHour, retrying: retrying)
        }
        starts[id] = task
        defer { starts[id] = nil }
        try await task.value
    }

    private func performStart(_ id: UUID, until runUntil: Date?, manual: Bool, newPod: Bool,
                              maxPricePerHour: Double?, retrying: WaitingForCard?) async throws {
        let state = await store.current()
        guard let model = state.models.first(where: { $0.id == id }) else { throw PodlightError.unknownModel(id.uuidString) }
        if let other = state.run(id).managedBy { throw PodlightError.managedElsewhere(PodOwner.displayName(of: other)) }
        let wake = Scheduler.admitWake(spend: state.spend(on: now()))
        guard wake.admit else { throw PodlightError.limitReached(wake.because) }
        let client = try client()
        let podKey = try podKey(for: id)
        let owner = await ownTag()
        var run = state.run(id)
        // A new start ends any waiting for the old machine's card.
        if run.waitingForCard != nil { try await updateRun(id) { $0.waitingForCard = nil } }

        if newPod, let podId = run.podId {
            // The old pod and its disk stay until the new pod answers; if the new one fails, the
            // old one is put back. A failed earlier replacement is deleted, its original kept.
            if run.replacing != nil {
                do { try await client.deletePod(id: podId) } catch let e as RunpodError where e.isNotFound {} catch let e as RunpodError {
                    throw PodlightError.runpod(status: e.status, message: e.body)
                }
            }
            let replaced = run.replacing ?? ReplacedPod(of: run, podId: podId)
            run.podId = nil
            try await updateRun(id) { $0.replacing = replaced; $0.podId = nil; $0.podStatus = nil; $0.persistentGB = nil }
        }

        if let podId = run.podId {
            do {
                let pod = try await client.pod(id: podId)
                if pod.status == .running || pod.status == .starting || pod.status == .provisioning {
                    try await updateRun(id) {
                        $0.runUntil = runUntil
                        $0.startedManually = $0.startedManually || manual
                    }
                    return
                }
                try await updateRun(id) { $0.phase = .creating; $0.lastReason = nil; $0.lastMessage = nil }
                // Resume with this version's start script and watchdog, not the ones it was made with.
                if let env = pod.env, let fresh = PodPlan.freshenedEnv(env, runUntil: runUntil) {
                    try? await client.updateEnv(pod: podId, to: fresh)
                }
                let resumed = try await resumeWaitingForHost(client, podId)
                try await markStarted(id, pod: resumed, runUntil: runUntil, manual: manual, resumed: true)
                return
            } catch let error as RunpodError where error.isHostGPUUnavailable {
                // Its machine gave the card away. The pod and its disk stay: deleting them would
                // throw away the downloaded model long before its deletion date. Podlight keeps
                // trying in the background until the run's end; the user may start on a new card.
                let waiting = WaitingForCard(until: runUntil ?? now().addingTimeInterval(Self.wokenWaitForCard),
                                             runUntil: runUntil, manual: manual, lastTryAt: now())
                try await updateRun(id) {
                    $0.phase = .stopped; $0.lastReason = "host-busy"; $0.lastMessage = nil; $0.waitingForCard = waiting
                }
                throw PodlightError.hostBusy
            } catch let error as RunpodError where error.isNotFound {
                // Gone: build a new one from the same model.
                run.podId = nil
                try await updateRun(id) { $0.podId = nil }
            } catch let error as RunpodError {
                try await fail(id, error)
                throw PodlightError.runpod(status: error.status, message: error.body)
            }
        }

        do {
            try await createPod(id, model: model, state: state, client: client, podKey: podKey, owner: owner,
                                runUntil: runUntil, manual: manual, maxPricePerHour: maxPricePerHour, retrying: retrying)
        } catch {
            // No new pod came of it: a replaced pod is the model's pod again.
            try? await putBackReplacedPod(id)
            throw error
        }
    }

    /// How long a start that a request woke waits for a busy machine's card.
    static let wokenWaitForCard: TimeInterval = 1800

    private func createPod(_ id: UUID, model: PodlightModel, state: PodlightState, client: RunpodClient, podKey: String,
                           owner: String?, runUntil: Date?, manual: Bool, maxPricePerHour: Double?,
                           retrying: WaitingForCard?) async throws {
        try await updateRun(id) { $0.phase = .creating; $0.lastReason = nil; $0.lastMessage = nil; $0.fellBackFrom = nil }
        var priced: PriceGuard?
        var offered: [PricedChoice] = []
        do {
            let catalog = try await client.gpuCatalog()
            let hosting = model.hosting(default: state.settings.hosting)
            let choices = PodPlan.choices(for: model, catalog: catalog, hosting: hosting)
            guard !choices.isEmpty else { throw PodlightError.noSuitableCard }
            let token = try? keychain.read(.huggingFaceToken)
            let request = PodPlan.request(for: model, podKey: podKey, huggingFaceToken: token, runUntil: runUntil,
                                          heartbeatMinutes: state.settings.heartbeatMinutes,
                                          dataCenterIds: hosting.dataCenterIds(in: catalog), owner: owner)
            // Fallbacks up to the price step only; pricier cards that may be free are offered.
            let guarded = PodPlan.priceGuard(choices: choices, catalog: catalog,
                                             stepPercent: state.settings.fallbackPriceStepPercent,
                                             maxPricePerHour: maxPricePerHour)
            priced = guarded
            let byId = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            offered = guarded.above.filter { byId[$0.choice.gpuId]?.availability.map(\.mayBeAvailable) ?? true }
            let created = try await client.createPod(request, tryingInOrder: guarded.within, catalog: catalog)
            let names = Dictionary(catalog.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let price = created.pod.cost ?? catalog.first { $0.id == created.choice.gpuId }
                .flatMap { $0.pricePerHour(in: created.choice.cloud) }.map { $0 * Double(created.choice.count) }
            let storage = PodPlan.storagePerHour(for: model)
            let name = names[created.choice.gpuId] ?? created.choice.gpuId
            try await updateRun(id) {
                $0.podId = created.pod.id
                $0.gpu = created.choice
                $0.gpuName = created.choice.count > 1 ? "\(created.choice.count) × \(name)" : name
                $0.pricePerHour = price
                $0.storagePerHour = storage
                $0.persistentGB = model.keepDisk ? PodPlan.persistentGB(for: model) : nil
                $0.containerGB = PodPlan.containerGB(for: model)
                $0.dataCenterId = created.pod.dataCenterId
                $0.hosting = hosting
                $0.fellBackFrom = created.attempts.filter { $0.outcome != .created }.map { names[$0.choice.gpuId] ?? $0.choice.gpuId }
                $0.wantedPricePerHour = created.usedFallback ? guarded.wanted?.pricePerHour : nil
            }
            try await markStarted(id, pod: created.pod, runUntil: runUntil, manual: manual, resumed: false)
        } catch let error as NoCapacityError {
            let tried = error.attempts.map(\.choice.gpuId)
            // Nothing booked. Without a replaced pod to put back, keep trying within the price,
            // until the run's end (half an hour for a woken one), as for a busy machine.
            let canWait = await store.current().run(id).replacing == nil
            if let ceiling = priced?.ceiling, !offered.isEmpty || retrying != nil {
                let waiting = WaitingForCard(until: retrying?.until ?? runUntil ?? now().addingTimeInterval(Self.wokenWaitForCard),
                                             runUntil: runUntil, manual: manual, lastTryAt: now(),
                                             maxPricePerHour: ceiling, wanted: priced?.wanted, pricier: offered)
                try await updateRun(id) {
                    $0.phase = .stopped; $0.lastReason = "card-too-expensive"; $0.lastMessage = tried.joined(separator: ", ")
                    $0.waitingForCard = canWait ? waiting : nil
                }
                if offered.isEmpty { throw PodlightError.noCapacity(tried) }
                throw PodlightError.cardTooExpensive(wanted: priced?.wanted, ceiling: ceiling, pricier: offered)
            }
            try await updateRun(id) { $0.phase = .failed; $0.lastReason = "no-capacity"; $0.lastMessage = tried.joined(separator: ", ") }
            throw PodlightError.noCapacity(tried)
        } catch let error as RunpodError {
            try await fail(id, error)
            throw PodlightError.runpod(status: error.status, message: error.body)
        } catch let error as PodlightError {
            try await updateRun(id) { $0.phase = .failed; $0.lastReason = "no-suitable-card" }
            throw error
        }
    }

    /// Resumes a stopped pod, trying again for about a minute while its machine has no free card.
    private func resumeWaitingForHost(_ client: RunpodClient, _ podId: String) async throws -> RunpodPod {
        var attempt = 1
        while true {
            do {
                return try await client.perform(.start, onPod: podId)
            } catch let error as RunpodError where error.isHostGPUUnavailable && attempt < hostBusyTries {
                attempt += 1
                try await Task.sleep(for: hostBusyDelay)
            }
        }
    }

    private func markStarted(_ id: UUID, pod: RunpodPod, runUntil: Date?, manual: Bool, resumed: Bool) async throws {
        let t = now()
        loadProgress[id] = nil
        try await updateRun(id) {
            $0.resumed = resumed
            $0.waitingForCard = nil
            $0.podStatus = pod.status
            $0.phase = .loading
            $0.engineLog = nil
            $0.startedAt = t
            $0.accountedUntil = t
            $0.engineReady = false
            $0.startedManually = manual
            $0.runUntil = runUntil
            $0.idleStoppedAt = nil
            $0.stoppedAt = nil
            $0.lastRequestAt = nil
            if let cost = pod.cost { $0.pricePerHour = cost }
        }
    }

    private func fail(_ id: UUID, _ error: RunpodError) async throws {
        try await updateRun(id) {
            $0.phase = .failed
            $0.lastReason = "runpod-error"
            $0.lastMessage = "\(error.status): \(error.body.prefix(200))"
        }
    }

    /// Ends a run. With a kept disk the pod is stopped (GPU billing ends, the disk stays and is
    /// billed); without, it is deleted and nothing is billed until the next start.
    /// `reason` is a schedule reason code or `manual` / `app-quit`.
    public func stop(_ id: UUID, reason: String = "manual") async throws {
        let state = await store.current()
        let run = state.run(id)
        // Stopping a start that waits for its machine's card just ends the waiting.
        if run.waitingForCard != nil {
            try await updateRun(id) { $0.waitingForCard = nil }
            if run.phase == .stopped || run.phase == .failed { return }
        }
        guard let podId = run.podId else { return }
        account(id: id, run: run)
        loadProgress[id] = nil
        if run.replacing != nil {
            // A new pod that never answered ends by being deleted; the old pod with the
            // downloaded model is the model's pod again.
            try await updateRun(id) { $0.phase = .stopping }
            do { try await client().deletePod(id: podId) } catch let e as RunpodError where e.isNotFound {} catch let e as RunpodError {
                try await fail(id, e)
                throw PodlightError.runpod(status: e.status, message: e.body)
            }
            try await putBackReplacedPod(id)
            try await markStopped(id, status: .exited, reason: reason)
            return
        }
        try await updateRun(id) { $0.phase = .stopping }
        let keepDisk = state.models.first { $0.id == id }?.keepDisk ?? true
        do {
            if keepDisk {
                let pod = try await client().perform(.stop, onPod: podId)
                try await markStopped(id, status: pod.status, reason: reason)
            } else {
                try await client().deletePod(id: podId)
                try await markStopped(id, status: nil, reason: reason)
                try await updateRun(id) { $0.podId = nil; $0.podStatus = nil; $0.persistentGB = nil }
            }
        } catch let error as RunpodError where error.isNotFound {
            try await updateRun(id) { $0.podId = nil; $0.phase = .stopped; $0.podStatus = nil }
        } catch let error as RunpodError {
            try await fail(id, error)
            throw PodlightError.runpod(status: error.status, message: error.body)
        }
    }

    private func markStopped(_ id: UUID, status: PodState.Status?, reason: String) async throws {
        samples[id] = nil
        let t = now()
        try await updateRun(id) {
            $0.storageAccountedUntil = t
            $0.podStatus = status ?? .exited
            $0.phase = .stopped
            $0.engineReady = false
            $0.stoppedAt = t
            $0.lastReason = reason
            $0.runUntil = nil
            if reason == ScheduleReason.idleTimeout.rawValue { $0.idleStoppedAt = t }
        }
    }

    /// Moves "Läuft bis" and tells the pod's watchdog at once.
    public func extend(_ id: UUID, until: Date) async throws {
        try await updateRun(id) { $0.runUntil = until }
        let run = await store.current().run(id)
        if let podId = run.podId, run.podStatus == .running { _ = await heartbeat(podId: podId, modelId: id, runUntil: until) }
    }

    /// Stops every pod this Mac runs. Used when the app quits.
    public func stopAll(reason: String = "app-quit") async {
        let state = await store.current()
        await withTaskGroup(of: Void.self) { group in
            for (model, run) in state.runs.compactMap({ id, run in state.models.first { $0.id == id }.map { ($0, run) } })
            where run.managedBy == nil && (run.podId != nil && [.creating, .loading, .ready, .stopping].contains(run.phase) || run.podStatus == .running) {
                group.addTask { try? await self.stop(model.id, reason: reason) }
            }
        }
    }

    // MARK: Other Macs

    /// This Mac's tag in pod names, made on first use.
    public func ownTag() async -> String {
        if let tag = await store.current().deviceTag { return tag }
        let tag = PodOwner.makeTag(hostName: Host.current().localizedName ?? "mac")
        try? await store.update { if $0.deviceTag == nil { $0.deviceTag = tag } }
        return await store.current().deviceTag ?? tag
    }

    /// The models in the RunPod account that this Mac does not manage: another Mac's, with or
    /// without a pod (from their records), and bare pods an older version created. Server pods
    /// and pods without Podlight's environment are left out.
    public func podsFromOtherMacs() async throws -> [ForeignPod] {
        let state = await store.current()
        let mine = await ownTag()
        let client = try client()
        let owned = state.models.filter { state.run($0.id).managedBy == nil }
        let ownedIds = Set(owned.map(\.id))
        let ownedPods = Set(owned.compactMap { state.run($0.id).podId })
        async let podList = client.listPods()
        async let recordList = client.listTemplates()
        let pods = try await podList
        let records = (try? await recordList) ?? []
        let podsById = Dictionary(pods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var found: [ForeignPod] = []
        var recordedPods = Set<String>()
        for record in records where record.name.hasPrefix(ModelRecord.prefix) {
            guard let content = record.env.flatMap(ModelRecord.decode) else { continue }
            if let podId = content.podId { recordedPods.insert(podId) }
            guard ModelRecord.owner(ofName: record.name) != mine, !ownedIds.contains(content.model.id) else { continue }
            if let foreign = ForeignPod(record: record, pod: content.podId.flatMap { podsById[$0] }) { found.append(foreign) }
        }
        for pod in pods where !recordedPods.contains(pod.id) && !ownedPods.contains(pod.id) && pod.status != .terminated {
            if let foreign = ForeignPod(pod), foreign.owner != mine { found.append(foreign) }
        }
        return found.sorted { $0.servedName < $1.servedName }
    }

    /// Takes another Mac's model over and renames its record and pod to this Mac; the other Mac
    /// lets go when it next looks. From a record the model comes over exactly; from a bare pod
    /// (older version) it is rebuilt from the pod and Hugging Face (`lookup`, nil asks Hugging Face).
    @discardableResult
    public func takeOver(_ foreign: ForeignPod,
                         lookup: (@Sendable (String) async throws -> ModelInfo)? = nil) async throws -> UUID {
        let state = await store.current()
        let client = try client()
        let mine = await ownTag()

        // Read again: the list may be a minute old.
        var current = foreign
        if let recordId = foreign.recordId {
            let records = try await runpod { try await client.listTemplates() }
            guard let record = records.first(where: { $0.id == recordId }) else {
                throw PodlightError.runpod(status: 404, message: "the model is no longer in the RunPod account")
            }
            let content = record.env.flatMap(ModelRecord.decode)
            var pod: RunpodPod?
            if let podId = content?.podId { pod = try? await client.pod(id: podId) }
            guard let fresh = ForeignPod(record: record, pod: pod) else { throw PodlightError.runpod(status: 0, message: "not a Podlight model") }
            current = fresh
        } else if let podId = foreign.podId {
            let pod = try await runpod { try await client.pod(id: podId) }
            guard let fresh = ForeignPod(pod) else { throw PodlightError.runpod(status: 0, message: "not a Podlight pod") }
            current = fresh
        }

        // A model this Mac released earlier: take it back instead of adding a second one.
        if let id = current.recordedModel?.id, state.models.contains(where: { $0.id == id }) {
            try await takeBack(id)
            return id
        }
        if let podId = current.podId, let (id, _) = state.runs.first(where: { $0.value.podId == podId && $0.value.managedBy != nil }) {
            try await takeBack(id)
            return id
        }
        if state.model(named: current.servedName) != nil { throw PodlightError.nameTaken(current.servedName) }

        var info: ModelInfo?
        if current.recordedModel == nil {
            do {
                var described: ModelInfo
                if let lookup {
                    described = try await lookup(current.repoId)
                } else {
                    described = try await HuggingFaceClient(token: try? keychain.read(.huggingFaceToken), transport: transport).info(current.repoId)
                }
                if let quant = current.quant, described.format == .gguf { described = described.choosing(quant: quant) }
                info = described
            } catch {
                throw PodlightError.modelLookup("\(error)")
            }
        }
        let model = info.map { current.model(from: $0) } ?? current.recordedModel!
        do { try keychain.write(current.podKey, for: .podKey(model.id)) } catch { throw PodlightError.keychain("\(error)") }

        do {
            if let recordId = current.recordId {
                try await client.renameTemplate(id: recordId, to: ModelRecord.name(model: model.name, owner: mine))
            }
            if let podId = current.podId, current.hasPod {
                try await client.rename(pod: podId, to: PodOwner.podName(model: model.name, owner: mine))
            }
        } catch let e as RunpodError {
            try? keychain.delete(.podKey(model.id))
            throw PodlightError.runpod(status: e.status, message: e.body)
        }

        let t = now()
        var run = ModelRun()
        run.recordId = current.recordId
        run.lastReason = "taken-over"
        if let podId = current.podId, current.hasPod {
            run.podId = podId
            run.podStatus = current.status
            run.phase = current.isRunning ? .loading : .stopped
            run.gpu = model.preferredGPU
            run.gpuName = current.gpuId.map { Self.shortGPUName($0, count: current.gpuCount) }
            run.pricePerHour = current.pricePerHour
            run.persistentGB = current.persistentGB
            run.containerGB = current.containerGB
            run.storagePerHour = StoragePricing.runningPerHour(containerGB: current.containerGB ?? 0, volumeGB: current.persistentGB ?? 0)
            run.dataCenterId = current.dataCenterId
            // Costs count from now on this Mac; idle stop and deletion of unused pods count from
            // now too, so a pod in use elsewhere is not stopped the moment it arrives.
            run.startedAt = current.isRunning ? t : nil
            run.accountedUntil = t
            run.storageAccountedUntil = t
            run.lastRequestAt = t
            run.stoppedAt = current.isRunning ? nil : t
        }
        let newRun = run
        try await store.update { state in
            state.models.append(model)
            state.runs[model.id] = newRun
        }
        published[model.id] = nil
        if current.isRunning { await refresh(model.id) }
        return model.id
    }

    /// Takes a model back that another Mac took over: reads its record (the other Mac may have
    /// changed it or started a new pod), and renames record and pod to this Mac again.
    public func takeBack(_ id: UUID) async throws {
        let state = await store.current()
        guard var model = state.models.first(where: { $0.id == id }) else { throw PodlightError.unknownModel(id.uuidString) }
        let client = try client()
        let mine = await ownTag()
        var run = state.run(id)

        if let recordId = run.recordId {
            let records = try await runpod { try await client.listTemplates() }
            if let record = records.first(where: { $0.id == recordId }), let content = record.env.flatMap(ModelRecord.decode) {
                model = content.model
                if content.podId != run.podId { run = ModelRun(); run.recordId = recordId; run.podId = content.podId }
                try await runpod { try await client.renameTemplate(id: recordId, to: ModelRecord.name(model: model.name, owner: mine)) }
            } else {
                run.recordId = nil
            }
        }

        var status: PodState.Status?
        if let podId = run.podId {
            do {
                let pod = try await client.pod(id: podId)
                status = pod.status
                try await client.rename(pod: podId, to: PodOwner.podName(model: model.name, owner: mine))
            } catch let e as RunpodError where e.isNotFound {
                run.podId = nil
            } catch let e as RunpodError {
                throw PodlightError.runpod(status: e.status, message: e.body)
            }
        }
        let t = now()
        let running = status == .running || status == .starting || status == .provisioning
        run.managedBy = nil
        run.podStatus = run.podId == nil ? nil : status
        run.phase = running ? .loading : .stopped
        run.accountedUntil = t
        run.storageAccountedUntil = t
        run.lastRequestAt = t
        run.startedAt = running ? t : run.startedAt
        run.stoppedAt = running ? nil : (run.podId == nil ? run.stoppedAt : t)
        run.runUntil = nil
        run.lastReason = "taken-back"
        let newRun = run
        let newModel = model
        try await store.update { state in
            if let index = state.models.firstIndex(where: { $0.id == id }) { state.models[index] = newModel }
            state.runs[id] = newRun
        }
        published[id] = nil
        if running { await refresh(id) }
    }

    // MARK: Records in the RunPod account

    /// Checks the records against the account (another Mac may have taken a model over), then
    /// writes the records of this Mac's models that changed. Checking comes first, so a model that
    /// moved while this Mac was off is released, not grabbed back.
    public func syncRecords(force: Bool = false) async {
        guard let client = try? client() else { return }
        let state = await store.current()
        let mine = await ownTag()
        var owned = state.models.filter { state.run($0.id).managedBy == nil }
        var desired: [UUID: (name: String, env: [String: String], signature: String)] = [:]
        for model in owned {
            guard let key = try? podKey(for: model.id) else { continue }
            let name = ModelRecord.name(model: model.name, owner: mine)
            let env = ModelRecord.env(model: model, podKey: key, podId: state.run(model.id).podId)
            let signature = name + "|" + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
            desired[model.id] = (name, env, signature)
        }
        let pending = owned.filter { published[$0.id] != desired[$0.id]?.signature }
        let due = force || lastRecordCheck.map { now().timeIntervalSince($0) >= 60 } ?? true
        guard !pending.isEmpty || due else { return }

        guard let records = try? await client.listTemplates() else { return }
        lastRecordCheck = now()
        let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for model in owned {
            let run = state.run(model.id)
            guard let recordId = run.recordId else { continue }
            guard let record = byId[recordId] else {
                // Gone (deleted at RunPod): written again below.
                published[model.id] = nil
                try? await updateRun(model.id) { $0.recordId = nil }
                continue
            }
            if let other = ModelRecord.owner(ofName: record.name), other != mine {
                samples[model.id] = nil
                published[model.id] = nil
                try? await updateRun(model.id) { $0.managedBy = other; $0.engineReady = false; $0.phase = .stopped }
                owned.removeAll { $0.id == model.id }
            }
        }

        let current = await store.current()
        for model in owned where published[model.id] != desired[model.id]?.signature {
            guard let want = desired[model.id] else { continue }
            var recordId = current.run(model.id).recordId
            do {
                if let id = recordId {
                    try await client.updateTemplate(id: id, name: want.name, env: want.env)
                } else {
                    let image = PodPlan.image(for: model.engine)
                    do {
                        recordId = try await client.createTemplate(name: want.name, image: image, env: want.env).id
                    } catch let e as RunpodError where e.status == 400 {
                        // Already there under this name (an earlier write whose answer was lost).
                        guard let existing = records.first(where: { $0.name == want.name }) else { throw e }
                        recordId = existing.id
                        try await client.updateTemplate(id: existing.id, name: want.name, env: want.env)
                    }
                }
                published[model.id] = want.signature
                let id = recordId
                try? await updateRun(model.id) { $0.recordId = id }
            } catch let e as RunpodError where e.isNotFound {
                try? await updateRun(model.id) { $0.recordId = nil }
            } catch {
                continue // RunPod unreachable: try again next tick.
            }
        }
    }

    /// Runs a RunPod call and turns its error into the interface's.
    private func runpod<T: Sendable>(_ call: () async throws -> T) async throws -> T {
        do { return try await call() } catch let e as RunpodError {
            throw PodlightError.runpod(status: e.status, message: e.body)
        }
    }

    static func shortGPUName(_ id: String, count: Int) -> String {
        let name = id.replacingOccurrences(of: "NVIDIA ", with: "").replacingOccurrences(of: "GeForce ", with: "")
        return count > 1 ? "\(count) × \(name)" : name
    }

    // MARK: Gateway

    /// The pod for `name`, woken and waited for if needed.
    public func endpoint(forModelNamed name: String) async throws -> PodEndpoint {
        let state = await store.current()
        guard let model = state.model(named: name) else { throw PodlightError.unknownModel(name) }
        if let other = state.run(model.id).managedBy { throw PodlightError.managedElsewhere(PodOwner.displayName(of: other)) }
        if let ready = try readyEndpoint(model.id, state: state) { return ready }

        let phase = state.run(model.id).phase
        if ![.creating, .loading].contains(phase) {
            guard state.settings.wakeOnRequest else { throw PodlightError.wakeDisabled }
            try await start(model.id, until: nil, manual: false)
        }

        let deadline = now().addingTimeInterval(TimeInterval(state.settings.wakeWaitSeconds))
        while now() < deadline {
            try await Task.sleep(for: .seconds(5))
            await refresh(model.id)
            let current = await store.current()
            if let ready = try readyEndpoint(model.id, state: current) { return ready }
            if [.failed, .stopped].contains(current.run(model.id).phase) {
                throw PodlightError.runpod(status: 0, message: current.run(model.id).lastMessage ?? "the pod stopped while starting")
            }
        }
        throw PodlightError.notReadyInTime
    }

    private func readyEndpoint(_ id: UUID, state: PodlightState) throws -> PodEndpoint? {
        let run = state.run(id)
        guard run.phase == .ready, let podId = run.podId else { return nil }
        return PodEndpoint(modelId: id, baseURL: podURL(podId, PodPlan.enginePort), key: try podKey(for: id))
    }

    /// An agent reached the gateway with a valid key. Written at most once a minute.
    public func clientSeen() async {
        let t = now()
        if let last = await store.current().lastClientRequestAt, t.timeIntervalSince(last) < 60 { return }
        _ = try? await store.update { $0.lastClientRequestAt = t }
    }

    public func requestBegan(_ id: UUID) async {
        inFlight[id, default: 0] += 1
        let t = now()
        try? await updateRun(id) { $0.lastRequestAt = t }
    }

    public func requestEnded(_ id: UUID) async {
        inFlight[id] = max(0, (inFlight[id] ?? 1) - 1)
        let t = now()
        try? await updateRun(id) { $0.lastRequestAt = t }
    }

    public func requestsInFlight(_ id: UUID) -> Int { inFlight[id] ?? 0 }

    // MARK: Tick

    /// Re-reads every pod from RunPod, keeps the watchdogs fed, and applies the rules.
    public func tick() async {
        guard (try? client()) != nil else { return }
        let state = await store.current()
        // A model another Mac took over is left alone until it is taken back.
        for model in state.models where state.run(model.id).managedBy == nil {
            await refresh(model.id)
            await applyRules(model.id)
        }
        await retryWaitingStarts()
        await deleteReplacedPods()
        await deleteLongStopped()
        await accountStoredDisks()
        await syncRecords()
    }

    /// The old pod of a "Start on a New Card" whose new pod answered, and its disk, are deleted.
    private func deleteReplacedPods() async {
        for (id, run) in await store.current().runs {
            guard let old = run.oldPodToDelete, let client = try? client() else { continue }
            do { try await client.deletePod(id: old) } catch let e as RunpodError where e.isNotFound {} catch { continue }
            try? await updateRun(id) { $0.oldPodToDelete = nil }
        }
    }

    /// Puts the pod a "Start on a New Card" replaced back as the model's pod.
    private func putBackReplacedPod(_ id: UUID) async throws {
        guard let replaced = await store.current().run(id).replacing else { return }
        try await updateRun(id) { replaced.restore(into: &$0) }
    }

    /// Tries again to resume the pods whose machine had no free card, until each run's end.
    private func retryWaitingStarts() async {
        let state = await store.current()
        let t = now()
        for (id, run) in state.runs {
            guard let waiting = run.waitingForCard else { continue }
            if run.podId == nil, waiting.maxPricePerHour != nil {
                await retryAffordableStart(id, run: run, waiting: waiting, state: state, at: t)
                continue
            }
            guard let podId = run.podId, run.managedBy == nil, run.phase == .stopped || run.phase == .failed,
                  t < waiting.until, Scheduler.admitWake(spend: state.spend(on: t)).admit else {
                try? await updateRun(id) { $0.waitingForCard = nil }
                continue
            }
            if let last = waiting.lastTryAt, t.timeIntervalSince(last) < cardRetryInterval { continue }
            guard let client = try? client() else { return }
            do {
                let pod = try await client.perform(.start, onPod: podId)
                try? await updateRun(id) { $0.lastReason = nil }
                try? await markStarted(id, pod: pod, runUntil: waiting.runUntil, manual: waiting.manual, resumed: true)
            } catch let error as RunpodError where error.isHostGPUUnavailable {
                try? await updateRun(id) { $0.waitingForCard?.lastTryAt = t }
            } catch let error as RunpodError where error.isNotFound {
                try? await updateRun(id) { $0.waitingForCard = nil; $0.podId = nil; $0.podStatus = nil; $0.lastReason = "pod-gone" }
            } catch let error as RunpodError {
                try? await updateRun(id) { $0.waitingForCard = nil }
                try? await fail(id, error)
            } catch {
                // RunPod unreachable: try again next time.
                try? await updateRun(id) { $0.waitingForCard?.lastTryAt = t }
            }
        }
    }

    /// A new pod waiting for a card within its price: tried again every 30 seconds until its end.
    private func retryAffordableStart(_ id: UUID, run: ModelRun, waiting: WaitingForCard, state: PodlightState, at t: Date) async {
        guard run.managedBy == nil, run.phase == .stopped || run.phase == .failed, t < waiting.until,
              state.models.contains(where: { $0.id == id }), Scheduler.admitWake(spend: state.spend(on: t)).admit else {
            try? await updateRun(id) { $0.waitingForCard = nil }
            return
        }
        if let last = waiting.lastTryAt, t.timeIntervalSince(last) < cardRetryInterval { return }
        do {
            try await start(id, until: waiting.runUntil, manual: waiting.manual, newPod: false,
                            maxPricePerHour: waiting.maxPricePerHour, retrying: waiting)
        } catch PodlightError.cardTooExpensive, PodlightError.noCapacity {
            // Still waiting: createPod kept the waiting with this try's time.
        } catch {
            // RunPod unreachable or refused: keep waiting unless the start cleared it.
            if await store.current().run(id).waitingForCard == nil, await store.current().run(id).phase != .failed {
                try? await updateRun(id) { var w = waiting; w.lastTryAt = t; $0.waitingForCard = w }
            }
        }
    }

    /// A stopped pod's kept volume disk is billed (0.20 USD/GB/month); book it as it accrues so
    /// limits and the cost view include it.
    private func accountStoredDisks() async {
        let t = now()
        try? await store.update { state in
            for (id, run) in state.runs where run.podId != nil && run.phase == .stopped && run.managedBy == nil {
                guard let gb = run.persistentGB, gb > 0, let since = run.storageAccountedUntil ?? run.stoppedAt else { continue }
                let hours = max(0, t.timeIntervalSince(since)) / 3600
                let cost = StoragePricing.stoppedPerMonth(volumeGB: gb) / StoragePricing.hoursPerMonth * hours
                state.spendByDay[PodlightState.dayKey(t), default: 0] += cost
                state.runs[id]?.storageAccountedUntil = t
            }
        }
    }

    /// Brings one model's record in line with RunPod and its engine.
    public func refresh(_ id: UUID) async {
        guard let client = try? client() else { return }
        let run = await store.current().run(id)
        guard let podId = run.podId, run.managedBy == nil else { return }

        let pod: RunpodPod
        do {
            pod = try await client.pod(id: podId)
        } catch let error as RunpodError where error.isNotFound {
            await podGone(id, podId: podId)
            return
        } catch {
            return // RunPod unreachable: keep what we know, try again next tick.
        }
        if pod.status == .terminated {
            await podGone(id, podId: podId)
            return
        }
        // A server took the model over (its pods are named podlight-srv-…): let go, never claim it back.
        if pod.name.hasPrefix(PodOwner.serverPrefix) {
            samples[id] = nil
            try? await updateRun(id) { $0.managedBy = "Podlight server"; $0.engineReady = false; $0.phase = .stopped; $0.podStatus = pod.status }
            return
        }

        // The pod's name says which Mac manages it. Another Mac's tag: it took the model over, so
        // this Mac lets go at once (no heartbeat, no idle stop, no cost). No tag: a pod from before
        // 0.6, claimed for this Mac.
        let mine = await ownTag()
        switch PodOwner.owner(ofPodName: pod.name) {
        case let other? where other != mine:
            samples[id] = nil
            try? await updateRun(id) {
                $0.managedBy = other; $0.engineReady = false; $0.phase = .stopped; $0.podStatus = pod.status
            }
            return
        case nil:
            if let model = await store.current().models.first(where: { $0.id == id }) {
                try? await client.rename(pod: podId, to: PodOwner.podName(model: model.name, owner: mine))
            }
        default:
            break
        }

        account(id: id, run: run)

        // RunPod treats requested data centers as a preference. A pod outside the allowed region
        // is deleted at once, before it serves anything.
        let current = await store.current()
        let hosting = run.hosting
            ?? current.models.first { $0.id == id }?.hosting(default: current.settings.hosting)
            ?? current.settings.hosting
        // A running pod that reports no data center cannot be confirmed inside the region either.
        let unverifiable = hosting.needsPlacementCheck && pod.dataCenterId == nil && pod.status == .running
        if unverifiable || pod.dataCenterId.map({ !hosting.allows(dataCenterId: $0) }) == true {
            let center = pod.dataCenterId ?? "unknown"
            try? await client.deletePod(id: podId)
            try? await updateRun(id) {
                $0.podId = nil; $0.podStatus = nil; $0.phase = .failed; $0.engineReady = false
                $0.lastReason = "outside-region"; $0.lastMessage = center; $0.dataCenterId = center
            }
            return
        }
        var ready = run.engineReady
        var heartbeatAt = run.lastHeartbeatAt
        if pod.status == .running {
            let watchdog = await heartbeat(podId: podId, modelId: id, runUntil: run.runUntil)
            if watchdog != nil { heartbeatAt = now() }
            if let telemetry = watchdog?.telemetry { record(telemetry, for: id) }
            // The engine died: say why, then end the pod now instead of after the watchdog's grace.
            if watchdog?.engineAlive == false {
                let lines = await engineLog(podId: podId, modelId: id)
                let message = lines.map(Self.summarizeEngineLog)
                    ?? "exit code \(watchdog?.engineExitCode.map(String.init) ?? "?")"
                let reason = Self.engineFailureReason(lines ?? [])
                try? await stop(id, reason: reason)
                try? await updateRun(id) {
                    $0.phase = .failed; $0.lastReason = reason; $0.lastMessage = message; $0.engineLog = lines
                }
                return
            }
            // A loading engine that shows no progress at all (no download, no log line, no GPU
            // memory, no CPU) has hung, often on a stalled download. It would bill until the run's end.
            if !ready, let watchdog, noteLoadProgress(id, watchdog) {
                let lines = await engineLog(podId: podId, modelId: id)
                let last = lines?.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                try? await stop(id, reason: "engine-stuck")
                try? await updateRun(id) {
                    $0.phase = .failed; $0.lastReason = "engine-stuck"; $0.engineLog = lines
                    $0.lastMessage = last.map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }
                }
                return
            }
            // Ready once the engine answers and the watchdog (which must answer) has warmed it up, so an agent's first
            // request does not wait for GPU code to be compiled.
            if !ready, let watchdog, watchdog.engineWarm != false, await engineAnswers(podId: podId, modelId: id) {
                // Start test: a model that only repeats one character (a broken quantisation or
                // kernel) would make every agent request run to its length limit.
                if let model = await store.current().models.first(where: { $0.id == id }),
                   let garbage = await garbageAnswer(podId: podId, model: model) {
                    let sample = String(garbage.prefix(40))
                    try? await stop(id, reason: "garbage-output")
                    try? await updateRun(id) {
                        $0.phase = .failed; $0.lastReason = "garbage-output"; $0.lastMessage = "\"\(sample)…\""
                    }
                    return
                }
                ready = true
                loadProgress[id] = nil
                // The new pod of a "Start on a New Card" answers: the old pod can go.
                if let replaced = run.replacing {
                    try? await updateRun(id) { $0.replacing = nil; $0.oldPodToDelete = replaced.podId }
                    await deleteReplacedPods()
                }
            }
        } else {
            ready = false
            samples[id] = nil
            loadProgress[id] = nil
        }

        let wasRunning = run.podStatus == .running
        let engineReady = ready
        let heartbeatTime = heartbeatAt
        let t = now()
        try? await updateRun(id) {
            guard $0.podId == podId else { return } // Gone or replaced while we asked.
            $0.podStatus = pod.status
            $0.engineReady = engineReady
            $0.lastHeartbeatAt = heartbeatTime
            if let center = pod.dataCenterId { $0.dataCenterId = center }
            if let cost = pod.cost, cost > 0 { $0.pricePerHour = cost }
            switch pod.status {
            case .running: $0.phase = engineReady ? .ready : .loading
            case .starting, .provisioning: $0.phase = .loading
            case .exited, .terminated:
                if $0.phase != .failed { $0.phase = .stopped }
                // Stopped by something other than Podlight: most likely the pod's own watchdog.
                if wasRunning && $0.phase != .stopping && $0.stoppedAt == nil {
                    $0.stoppedAt = t
                    $0.lastReason = $0.lastReason ?? "stopped-outside"
                }
            case .error: $0.phase = .failed; $0.lastReason = "pod-error"
            }
        }
    }

    /// RunPod no longer has the pod (deleted, at RunPod or by Podlight): the run lets go of it.
    private func podGone(_ id: UUID, podId: String) async {
        let run = await store.current().run(id)
        guard run.podId == podId else { return } // Someone else got here first.
        account(id: id, run: run)
        loadProgress[id] = nil
        samples[id] = nil
        try? await updateRun(id) {
            $0.podId = nil; $0.podStatus = nil; $0.engineReady = false; $0.phase = .stopped; $0.lastReason = "pod-gone"
        }
        try? await putBackReplacedPod(id)
    }

    private var reconciling = false

    /// Compares this Mac's pods with RunPod's list and lets go of every pod RunPod no longer has.
    /// One list request plus a check per missing pod (the list can lag behind a new pod). It does
    /// not wait for the tick, which can spend minutes on a start, so a deleted pod goes at once.
    public func reconcile() async {
        guard !reconciling, let client = try? client() else { return }
        reconciling = true
        defer { reconciling = false }
        guard let pods = try? await client.listPods() else { return }
        let listed = Dictionary(pods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let state = await store.current()
        for model in state.models where state.run(model.id).managedBy == nil {
            guard let podId = state.run(model.id).podId else { continue }
            if let pod = listed[podId] {
                if pod.status == .terminated { await podGone(model.id, podId: podId) }
                continue
            }
            do {
                if try await client.pod(id: podId).status == .terminated { await podGone(model.id, podId: podId) }
            } catch let error as RunpodError where error.isNotFound {
                await podGone(model.id, podId: podId)
            } catch {}
        }
    }

    private func applyRules(_ id: UUID) async {
        let state = await store.current()
        guard let model = state.models.first(where: { $0.id == id }) else { return }
        let run = state.run(id)
        guard run.managedBy == nil else { return } // Released while the tick ran.
        let podState = PodState(
            status: run.podId == nil ? nil : run.podStatus, startedAt: run.startedAt, lastRequestAt: run.lastRequestAt,
            engineReady: run.engineReady, inFlightRequests: inFlight[id] ?? 0, startedManually: run.startedManually,
            idleStoppedAt: run.idleStoppedAt, paused: false)
        let action = Scheduler.decide(schedule: model.schedule, pod: podState, spend: state.spend(on: now()),
                                      session: Session(runUntil: run.runUntil), now: now())
        switch action.do {
        case .stop: try? await stop(id, reason: action.because.rawValue)
        case .start: try? await start(id, until: nil, manual: false)
        case .nothing: break
        }
    }

    private func deleteLongStopped() async {
        let state = await store.current()
        let cutoff = now().addingTimeInterval(-TimeInterval(state.settings.deleteStoppedAfterDays) * 86_400)
        // A failed start keeps its stopped pod too (with a kept disk); it counts like a stopped one.
        for (id, run) in state.runs where run.podId != nil && (run.phase == .stopped || run.phase == .failed) && run.managedBy == nil {
            // A stopped pod with no date at all (from an older state) starts its clock now instead
            // of counting as ancient and being deleted at once.
            guard let lastUse = [run.stoppedAt, run.lastRequestAt, run.startedAt].compactMap({ $0 }).max() else {
                let t = now()
                try? await updateRun(id) { $0.stoppedAt = t }
                continue
            }
            guard lastUse < cutoff, let podId = run.podId, let client = try? client() else { continue }
            do {
                try await client.deletePod(id: podId)
            } catch let e as RunpodError where e.isNotFound {
            } catch { continue }
            try? await updateRun(id) { $0.podId = nil; $0.podStatus = nil; $0.lastReason = "deleted-unused" }
        }
    }

    // MARK: Spend

    /// Adds running time since the last booking to today's spend.
    private func account(id: UUID, run: ModelRun) {
        guard run.podStatus == .running, let price = run.pricePerHour, let since = run.accountedUntil ?? run.startedAt else { return }
        let t = now()
        let cost = max(0, t.timeIntervalSince(since)) / 3600 * (price + (run.storagePerHour ?? 0))
        Task { [store] in
            try? await store.update { state in
                state.spendByDay[PodlightState.dayKey(t), default: 0] += cost
                state.runs[id, default: ModelRun()].accountedUntil = t
            }
        }
    }

    // MARK: Pod HTTP

    /// What the watchdog reports with each heartbeat.
    struct WatchdogStatus: Sendable {
        var engineAlive: Bool?
        var engineExitCode: Int?
        var telemetry: PodTelemetry?
        /// Size of the engine's log; it grows while the engine works.
        var engineLogBytes: Int?
        /// False while the watchdog warms the engine up (GPU code compiled on first use); nil from
        /// a watchdog before 0.9.1, which counts as warm.
        var engineWarm: Bool?
    }

    /// What shows a loading engine at work. Sizes in 64 MB steps, so small noise does not count.
    struct LoadSignature: Equatable {
        var storedSteps: Int?
        var gpuMemorySteps: Int?
        var logBytes: Int?

        init(_ status: WatchdogStatus) {
            let step = 64.0 * 1_048_576
            let t = status.telemetry
            let stored = [t?.diskUsedBytes, t?.volumeUsedBytes].compactMap { $0 }
            storedSteps = stored.isEmpty ? nil : Int(stored.reduce(0, +) / step)
            let gpu = (t?.gpus ?? []).compactMap(\.memoryUsedBytes)
            gpuMemorySteps = gpu.isEmpty ? nil : Int(gpu.reduce(0, +) / step)
            logBytes = status.engineLogBytes
        }
    }

    /// Notes what a loading pod shows. True once it has shown no progress for `loadStallLimit`.
    /// Without telemetry (a watchdog from before 0.5) nothing is decided.
    private func noteLoadProgress(_ id: UUID, _ status: WatchdogStatus) -> Bool {
        guard status.telemetry != nil else { return false }
        let t = now()
        let signature = LoadSignature(status)
        let busy = (status.telemetry?.cpuPercent ?? 0) >= 1
        guard let seen = loadProgress[id], seen.signature == signature, !busy else {
            loadProgress[id] = (signature, t)
            return false
        }
        return t.timeIntervalSince(seen.since) >= loadStallLimit
    }

    // MARK: Telemetry

    private func record(_ sample: PodTelemetry, for id: UUID) {
        var list = samples[id] ?? []
        if list.last?.time == sample.time { return }
        list.append(sample)
        if list.count > PodTelemetry.historyLimit { list.removeFirst(list.count - PodTelemetry.historyLimit) }
        samples[id] = list
    }

    /// The latest sample per model whose pod runs.
    public func latestTelemetry() -> [UUID: PodTelemetry] {
        samples.compactMapValues(\.last)
    }

    /// The last 30 minutes of one model's pod, oldest first.
    public func telemetry(for id: UUID) -> [PodTelemetry] { samples[id] ?? [] }

    private func heartbeat(podId: String, modelId: UUID, runUntil: Date?) async -> WatchdogStatus? {
        guard let key = try? podKey(for: modelId) else { return nil }
        var request = URLRequest(url: podURL(podId, PodPlan.watchdogPort).appendingPathComponent("heartbeat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let deadline: Any = runUntil.map { $0.addingTimeInterval(PodPlan.deadlineGrace).timeIntervalSince1970 } ?? NSNull()
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["deadline": deadline])
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200 else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // A watchdog from before 0.5 sends no telemetry; a sample that does not decode is left out.
        let telemetry = (json?["telemetry"] as? [String: Any])
            .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(PodTelemetry.self, from: $0) }
        return WatchdogStatus(engineAlive: json?["engineAlive"] as? Bool, engineExitCode: json?["engineExitCode"] as? Int,
                              telemetry: telemetry, engineLogBytes: json?["engineLogBytes"] as? Int,
                              engineWarm: json?["engineWarm"] as? Bool)
    }

    /// The last lines vLLM wrote, kept by the watchdog because RunPod drops a stopped pod's output.
    /// Reduced to the lines that say what went wrong.
    /// The engine's last lines, kept by the watchdog because RunPod drops a stopped pod's output.
    private func engineLog(podId: String, modelId: UUID) async -> [String]? {
        guard let key = try? podKey(for: modelId) else { return nil }
        var request = URLRequest(url: podURL(podId, PodPlan.watchdogPort).appendingPathComponent("log"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200,
              let lines = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["lines"] as? [String]
        else { return nil }
        return lines
    }

    /// `gpu-unusable` when the pod's machine could not use its card at all (CUDA failed before the
    /// model was touched; seen on an RTX PRO 6000 host where the same model ran on a B200), else
    /// `engine-exited`. The first is the machine's fault, so the remedy is another machine.
    static func engineFailureReason(_ lines: [String]) -> String {
        let pattern = #"(CUDA unknown error|no CUDA-capable device|CUDA driver version is insufficient|NVIDIA driver on your system is too old|Failed to get device capability|cudaErrorNoDevice|CUDA error: initialization error)"#
        return lines.contains { $0.range(of: pattern, options: .regularExpression) != nil } ? "gpu-unusable" : "engine-exited"
    }

    /// The error lines of an engine log, or its last lines when none says "error". vLLM runs the
    /// engine in a process of its own; when it fails, the API server's last words are only "See
    /// root cause above". Then that process's lines are left out, so the engine's own error shows.
    static func summarizeEngineLog(_ lines: [String]) -> String {
        var lines = lines
        if let pointer = lines.last(where: { $0.contains("root cause above") }),
           let prefix = pointer.range(of: #"^\([^)]*\)"#, options: .regularExpression).map({ String(pointer[$0]) }) {
            let others = lines.filter { !$0.hasPrefix(prefix) }
            if !others.isEmpty { lines = others }
        }
        let errors = lines.filter { $0.range(of: #"(Error|Exception|error:|CUDA|out of memory|Traceback|failed to|unable to allocate|error loading model)"#, options: .regularExpression) != nil }
        let picked = (errors.isEmpty ? lines : errors).suffix(3)
        return picked.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    /// True for an answer made of one or two characters repeated, as a model gives when its
    /// numbers are broken ("!!!!…" from an NVFP4 build on an RTX PRO 6000, 2026-11-23).
    static func looksDegenerate(_ text: String) -> Bool {
        let characters = text.filter { !$0.isWhitespace }
        guard characters.count >= 16 else { return false }
        return Set(characters).count <= 2
    }

    /// Asks the model one short question. Returns its answer when that answer is degenerate; nil
    /// when it is fine or the test itself could not run (the start is never held up by the test).
    private func garbageAnswer(podId: String, model: PodlightModel) async -> String? {
        guard let key = try? podKey(for: model.id) else { return nil }
        for withKwargs in [true, false] {
            var body: [String: Any] = [
                "model": model.name, "max_tokens": 48, "temperature": 0,
                "messages": [["role": "user", "content": "Reply with one word: ready"]],
            ]
            // Without thinking, so a reasoning model answers within the few tokens allowed.
            if withKwargs { body["chat_template_kwargs"] = ["enable_thinking": false] }
            var request = URLRequest(url: podURL(podId, PodPlan.enginePort).appendingPathComponent("v1/chat/completions"))
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, response) = try? await transport.send(request) else { return nil }
            if response.statusCode == 400 && withKwargs { continue } // an engine that refuses the kwargs
            guard response.statusCode == 200,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let message = ((json["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any] else { return nil }
            let text = [message["content"], message["reasoning_content"], message["reasoning"]]
                .compactMap { $0 as? String }.joined()
            return Self.looksDegenerate(text) ? text : nil
        }
        return nil
    }

    private func engineAnswers(podId: String, modelId: UUID) async -> Bool {
        guard let key = try? podKey(for: modelId) else { return false }
        var request = URLRequest(url: podURL(podId, PodPlan.enginePort).appendingPathComponent("v1/models"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await transport.send(request) else { return false }
        return response.statusCode == 200
    }

    // MARK: Helpers

    private func client() throws -> RunpodClient {
        guard let key = try? keychain.read(.runpodAPIKey), !key.isEmpty else { throw PodlightError.missingRunpodKey }
        return RunpodClient(apiKey: key, transport: transport)
    }

    private func podKey(for id: UUID) throws -> String {
        if let existing = try? keychain.read(.podKey(id)), !existing.isEmpty { return existing }
        let key = Self.randomKey()
        do { try keychain.write(key, for: .podKey(id)) } catch { throw PodlightError.keychain("\(error)") }
        return key
    }

    /// 32 random bytes, URL-safe base64.
    public static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func updateRun(_ id: UUID, _ change: @Sendable (inout ModelRun) -> Void) async throws {
        try await store.update { state in
            var run = state.runs[id] ?? ModelRun()
            change(&run)
            state.runs[id] = run
        }
    }
}
