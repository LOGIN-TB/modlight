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

    public init(store: StateStore, keychain: KeychainStore = KeychainStore(),
                transport: HTTPTransport = URLSession.shared, now: @escaping @Sendable () -> Date = Date.init,
                podURL: @escaping @Sendable (_ podId: String, _ port: Int) -> URL = PodPlan.proxyURL) {
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
        if let podId = run.podId, let client = try? client() {
            do { try await client.deletePod(id: podId) } catch let e as RunpodError where e.isNotFound {}
        }
        try? keychain.delete(.podKey(id))
        try await store.update { state in
            state.models.removeAll { $0.id == id }
            state.runs[id] = nil
        }
    }

    // MARK: Start, stop, extend

    /// Starts (or resumes) a model's pod. Returns once RunPod has accepted it; the engine then
    /// needs minutes to load, which `tick` follows.
    public func start(_ id: UUID, until runUntil: Date?, manual: Bool = true) async throws {
        if let running = starts[id] { return try await running.value }
        let task = Task { try await self.performStart(id, until: runUntil, manual: manual) }
        starts[id] = task
        defer { starts[id] = nil }
        try await task.value
    }

    private func performStart(_ id: UUID, until runUntil: Date?, manual: Bool) async throws {
        let state = await store.current()
        guard let model = state.models.first(where: { $0.id == id }) else { throw PodlightError.unknownModel(id.uuidString) }
        let wake = Scheduler.admitWake(spend: state.spend(on: now()))
        guard wake.admit else { throw PodlightError.limitReached(wake.because) }
        let client = try client()
        let podKey = try podKey(for: id)
        var run = state.run(id)

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
                let resumed = try await client.perform(.start, onPod: podId)
                try await markStarted(id, pod: resumed, runUntil: runUntil, manual: manual)
                return
            } catch let error as RunpodError where error.isNotFound || error.isHostGPUUnavailable {
                // Gone, or its host gave the card away: build a new one from the same model.
                if !error.isNotFound { try? await client.deletePod(id: podId) }
                run.podId = nil
                try await updateRun(id) { $0.podId = nil }
            } catch let error as RunpodError {
                try await fail(id, error)
                throw PodlightError.runpod(status: error.status, message: error.body)
            }
        }

        try await updateRun(id) { $0.phase = .creating; $0.lastReason = nil; $0.lastMessage = nil; $0.fellBackFrom = nil }
        do {
            let catalog = try await client.gpuCatalog()
            let hosting = model.hosting(default: state.settings.hosting)
            let choices = PodPlan.choices(for: model, catalog: catalog, hosting: hosting)
            guard !choices.isEmpty else { throw PodlightError.noSuitableCard }
            let token = try? keychain.read(.huggingFaceToken)
            let request = PodPlan.request(for: model, podKey: podKey, huggingFaceToken: token, runUntil: runUntil,
                                          heartbeatMinutes: state.settings.heartbeatMinutes,
                                          dataCenterIds: hosting.dataCenterIds(in: catalog))
            let created = try await client.createPod(request, tryingInOrder: choices, catalog: catalog)
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
            }
            try await markStarted(id, pod: created.pod, runUntil: runUntil, manual: manual)
        } catch let error as NoCapacityError {
            let tried = error.attempts.map(\.choice.gpuId)
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

    private func markStarted(_ id: UUID, pod: RunpodPod, runUntil: Date?, manual: Bool) async throws {
        let t = now()
        try await updateRun(id) {
            $0.podStatus = pod.status
            $0.phase = .loading
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
        guard let podId = run.podId else { return }
        account(id: id, run: run)
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
            where run.podId != nil && [.creating, .loading, .ready, .stopping].contains(run.phase) || run.podStatus == .running {
                group.addTask { try? await self.stop(model.id, reason: reason) }
            }
        }
    }

    // MARK: Gateway

    /// The pod for `name`, woken and waited for if needed.
    public func endpoint(forModelNamed name: String) async throws -> PodEndpoint {
        let state = await store.current()
        guard let model = state.model(named: name) else { throw PodlightError.unknownModel(name) }
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
        for model in state.models {
            await refresh(model.id)
            await applyRules(model.id)
        }
        await deleteLongStopped()
        await accountStoredDisks()
    }

    /// A stopped pod's kept volume disk is billed (0.20 USD/GB/month); book it as it accrues so
    /// limits and the cost view include it.
    private func accountStoredDisks() async {
        let t = now()
        try? await store.update { state in
            for (id, run) in state.runs where run.podId != nil && run.phase == .stopped {
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
        guard let podId = run.podId else { return }

        let pod: RunpodPod
        do {
            pod = try await client.pod(id: podId)
        } catch let error as RunpodError where error.isNotFound {
            account(id: id, run: run)
            try? await updateRun(id) { $0.podId = nil; $0.podStatus = nil; $0.phase = .stopped; $0.lastReason = "pod-gone" }
            return
        } catch {
            return // RunPod unreachable: keep what we know, try again next tick.
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
                let message = await engineFailure(podId: podId, modelId: id)
                    ?? "exit code \(watchdog?.engineExitCode.map(String.init) ?? "?")"
                try? await stop(id, reason: "engine-exited")
                try? await updateRun(id) { $0.phase = .failed; $0.lastReason = "engine-exited"; $0.lastMessage = message }
                return
            }
            if !ready { ready = await engineAnswers(podId: podId, modelId: id) }
        } else {
            ready = false
            samples[id] = nil
        }

        let wasRunning = run.podStatus == .running
        let engineReady = ready
        let heartbeatTime = heartbeatAt
        let t = now()
        try? await updateRun(id) {
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

    private func applyRules(_ id: UUID) async {
        let state = await store.current()
        guard let model = state.models.first(where: { $0.id == id }) else { return }
        let run = state.run(id)
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
        for (id, run) in state.runs where run.podId != nil && run.phase == .stopped {
            let lastUse = [run.stoppedAt, run.lastRequestAt, run.startedAt].compactMap { $0 }.max() ?? .distantPast
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
                              telemetry: telemetry)
    }

    /// The last lines vLLM wrote, kept by the watchdog because RunPod drops a stopped pod's output.
    /// Reduced to the lines that say what went wrong.
    private func engineFailure(podId: String, modelId: UUID) async -> String? {
        guard let key = try? podKey(for: modelId) else { return nil }
        var request = URLRequest(url: podURL(podId, PodPlan.watchdogPort).appendingPathComponent("log"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200,
              let lines = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["lines"] as? [String]
        else { return nil }
        return Self.summarizeEngineLog(lines)
    }

    /// The error lines of an engine log, or its last lines when none says "error".
    static func summarizeEngineLog(_ lines: [String]) -> String {
        let errors = lines.filter { $0.range(of: #"(Error|Exception|error:|CUDA|out of memory|Traceback|failed to|unable to allocate|error loading model)"#, options: .regularExpression) != nil }
        let picked = (errors.isEmpty ? lines : errors).suffix(3)
        return picked.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
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
