import Foundation
import Observation
import PodlightEngine

/// Where a model lives and runs: this Mac, or one of the Podlight servers the app controls.
enum Source: Hashable, Sendable {
    case local
    case server(UUID)
}

/// What the app knows about one server: its entry, the last state it reported and whether it
/// answers. Polled every few seconds while the app runs.
@MainActor
@Observable
final class ServerMirror: Identifiable {
    enum Status: Equatable {
        case connecting
        case online
        case unreachable(String)
        /// The server refused this app's device token (revoked, or the server was reset).
        case notPaired
    }

    var entry: ServerEntry
    private(set) var snapshot: ServerSnapshot?
    private(set) var status: Status = .connecting
    private(set) var lastContact: Date?
    var tokens: [ClientToken] = []

    nonisolated var id: UUID { entryID }
    private let entryID: UUID

    init(entry: ServerEntry) {
        self.entry = entry
        self.entryID = entry.id
    }

    func client(_ keychain: KeychainStore) -> ServerClient {
        ServerClient(baseURL: entry.baseURL, token: try? keychain.read(.serverToken(entry.id)))
    }

    func refresh(_ keychain: KeychainStore) async {
        do {
            snapshot = try await client(keychain).state()
            status = .online
            lastContact = .now
        } catch .notPaired {
            status = .notPaired
        } catch {
            status = .unreachable(Describe.serverError(error))
        }
    }

    /// Sample data for the help snapshots; never used against a real server.
    func showForSnapshots(_ sample: ServerSnapshot, tokens: [ClientToken]) {
        snapshot = sample
        self.tokens = tokens
        status = .online
    }

    func run(_ id: UUID) -> ModelRun { snapshot?.run(id) ?? ModelRun() }
    var models: [PodlightModel] { snapshot?.models ?? [] }
    var canStart: Bool { status == .online && snapshot?.settings.hasRunpodKey == true }
}

extension AppModel {
    // MARK: Sources

    func source(of modelId: UUID) -> Source {
        if state.models.contains(where: { $0.id == modelId }) { return .local }
        if let server = servers.first(where: { $0.models.contains { $0.id == modelId } }) { return .server(server.id) }
        return .local
    }

    func server(_ id: UUID) -> ServerMirror? { servers.first { $0.id == id } }

    func models(in source: Source) -> [PodlightModel] {
        switch source {
        case .local: state.models
        case .server(let id): server(id)?.models ?? []
        }
    }

    func run(_ modelId: UUID) -> ModelRun {
        switch source(of: modelId) {
        case .local: state.run(modelId)
        case .server(let id): server(id)?.run(modelId) ?? ModelRun()
        }
    }

    /// The latest sample from a model's pod, on this Mac or a server.
    func telemetry(_ modelId: UUID) -> PodTelemetry? {
        if let sample = sampleTelemetry?[modelId]?.last { return sample }
        switch source(of: modelId) {
        case .local: return localTelemetry[modelId]
        case .server(let id): return server(id)?.snapshot?.telemetry[modelId]
        }
    }

    /// The last 30 minutes of a model's pod, oldest first.
    func telemetryHistory(_ modelId: UUID) async -> [PodTelemetry] {
        if let samples = sampleTelemetry?[modelId] { return samples }
        switch source(of: modelId) {
        case .local: return await manager.telemetry(for: modelId)
        case .server(let id):
            guard let server = server(id) else { return [] }
            return (try? await server.client(keychain).telemetry(modelId)) ?? []
        }
    }

    func model(_ id: UUID) -> PodlightModel? {
        state.models.first { $0.id == id } ?? servers.lazy.compactMap { $0.models.first { $0.id == id } }.first
    }

    func canStart(in source: Source) -> Bool {
        switch source {
        case .local: hasRunpodKey
        case .server(let id): server(id)?.canStart ?? false
        }
    }

    func canStart(_ model: PodlightModel) -> Bool { canStart(in: source(of: model.id)) && run(model.id).managedBy == nil }

    func defaultHosting(in source: Source) -> HostingPolicy {
        switch source {
        case .local: state.settings.hosting
        case .server(let id): server(id)?.snapshot?.settings.hosting ?? .anywhere
        }
    }

    func heartbeatMinutes(in source: Source) -> Int {
        switch source {
        case .local: state.settings.heartbeatMinutes
        case .server(let id): server(id)?.snapshot?.settings.heartbeatMinutes ?? 15
        }
    }

    func deleteStoppedAfterDays(in source: Source) -> Int {
        switch source {
        case .local: state.settings.deleteStoppedAfterDays
        case .server(let id): server(id)?.snapshot?.settings.deleteStoppedAfterDays ?? 3
        }
    }

    func spend(in source: Source) -> Spend {
        switch source {
        case .local: state.spend(on: .now)
        case .server(let id):
            server(id)?.snapshot?.spend ?? Spend(todayUsd: 0, monthUsd: 0, dailyLimitUsd: nil, monthlyLimitUsd: nil)
        }
    }

    func costPerHour(in source: Source) -> Double {
        switch source {
        case .local: state.costPerHour
        case .server(let id): server(id)?.snapshot?.costPerHour ?? 0
        }
    }

    func activeRuns(in source: Source) -> [(PodlightModel, ModelRun)] {
        switch source {
        case .local: state.activeRuns
        case .server(let id): server(id)?.snapshot?.activeRuns ?? []
        }
    }

    /// Everything running anywhere, with where it runs.
    var allActiveRuns: [(Source, PodlightModel, ModelRun)] {
        state.activeRuns.map { (.local, $0.0, $0.1) }
            + servers.flatMap { s in (s.snapshot?.activeRuns ?? []).map { (.server(s.id), $0.0, $0.1) } }
    }

    /// Stopped pods whose disk is kept: RunPod bills them by the hour until the pod is deleted.
    func keptDisks(in source: Source) -> [KeptDisk] {
        models(in: source).compactMap { item in
            let run = run(item.id)
            guard run.podId != nil, run.managedBy == nil, run.phase == .stopped, let gb = run.persistentGB, gb > 0 else { return nil }
            return KeptDisk(source: source, model: item, gb: gb)
        }
    }

    var allKeptDisks: [KeptDisk] {
        ([Source.local] + servers.map { Source.server($0.id) }).flatMap { keptDisks(in: $0) }
    }

    var totalCostPerHour: Double { state.costPerHour + servers.compactMap(\.snapshot?.costPerHour).reduce(0, +) }

    func name(of source: Source) -> String {
        switch source {
        case .local: String(localized: "This Mac")
        case .server(let id): server(id)?.entry.name ?? String(localized: "Server")
        }
    }

    /// The card catalog for setting up a model: RunPod's, through the server's key for a server.
    func gpuCatalog(for source: Source) async throws -> [RunpodGPUType] {
        switch source {
        case .local:
            guard let client = runpod() else { throw PodlightError.missingRunpodKey }
            return try await client.gpuCatalog()
        case .server(let id):
            guard let server = server(id) else { throw ServerError.unreachable("") }
            return try await server.client(keychain).gpuCatalog()
        }
    }

    /// Opens the add sheet for a model on `source`.
    func addModel(to source: Source) {
        addingTo = source
        showingAddModel = true
    }

    // MARK: Server actions

    func syncServers() {
        let entries = state.servers
        var mirrors: [ServerMirror] = []
        for entry in entries {
            if let existing = servers.first(where: { $0.id == entry.id }) {
                existing.entry = entry
                mirrors.append(existing)
            } else {
                mirrors.append(ServerMirror(entry: entry))
            }
        }
        if mirrors.map(\.id) != servers.map(\.id) { servers = mirrors }
    }

    func refreshServers() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                let keychain = keychain
                group.addTask { await server.refresh(keychain) }
            }
        }
    }

    func refreshServer(_ id: UUID) async {
        await server(id)?.refresh(keychain)
    }

    /// Pairs with a server and remembers it. The device token goes to the keychain.
    func addServer(name: String, address: String, code: String) async throws -> UUID {
        let url: URL
        do { url = try ServerAddress.normalize(address) } catch { throw error }
        let anonymous = ServerClient(baseURL: url, token: nil)
        _ = try await anonymous.health()
        let deviceName = Host.current().localizedName ?? "Mac"
        let paired = try await anonymous.pair(code: code, deviceName: deviceName)
        let entry = ServerEntry(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? (url.host() ?? "Server") : name,
                                baseURL: url)
        try keychain.write(paired.token, for: .serverToken(entry.id))
        _ = try await manager.store.update { $0.servers.append(entry) }
        await reloadState()
        await refreshServer(entry.id)
        justPaired = entry.id
        return entry.id
    }

    /// After pairing: offer to bring this Mac's key, rules and models along, when there is any.
    func offerTransferAfterPairing() {
        guard let id = justPaired else { return }
        justPaired = nil
        guard hasRunpodKey || !state.models.isEmpty else { return }
        transfer = TransferRequest(serverID: id)
    }

    /// Forgets a server. Its pods keep running under the server's own rules.
    func removeServer(_ id: UUID) async {
        try? keychain.delete(.serverToken(id))
        _ = try? await manager.store.update { $0.servers.removeAll { $0.id == id } }
        if case .serverConnection(id) = selection { selection = .overview }
        if case .serverCosts(id) = selection { selection = .overview }
        if case .serverSettings(id) = selection { selection = .overview }
        await reloadState()
    }

    func renameServer(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        _ = try? await manager.store.update { state in
            if let index = state.servers.firstIndex(where: { $0.id == id }) { state.servers[index].name = trimmed }
        }
        await reloadState()
    }

    /// Changes the server's settings; returns an error sentence, or nil.
    @discardableResult
    func updateServer(_ id: UUID, _ change: ServerSettingsChange) async -> String? {
        guard let server = server(id) else { return nil }
        do {
            _ = try await server.client(keychain).update(change)
            await server.refresh(keychain)
            return nil
        } catch {
            return Describe.serverError(error)
        }
    }

    // MARK: From this Mac to a server

    /// Copies this Mac's RunPod key and Hugging Face token (`keys`) and its limits and rules
    /// (`rules`) to a server, so nothing is typed twice. Returns an error sentence, or nil.
    func copyFromThisMac(to id: UUID, keys: Bool, rules: Bool) async -> String? {
        var change = ServerSettingsChange()
        if keys {
            if let key = try? keychain.read(.runpodAPIKey), !key.isEmpty { change.runpodApiKey(key) }
            if let token = try? keychain.read(.huggingFaceToken), !token.isEmpty { change.huggingFaceToken(token) }
        }
        if rules {
            let s = state.settings
            change.dailyLimit(s.dailyLimitUsd)
            change.monthlyLimit(s.monthlyLimitUsd)
            // The server's ranges are narrower than what an old state file may hold.
            change.heartbeatMinutes(min(60, max(5, s.heartbeatMinutes)))
            change.wakeWaitSeconds(min(900, max(30, s.wakeWaitSeconds)))
            change.deleteStoppedAfterDays(min(30, max(1, s.deleteStoppedAfterDays)))
            change.wakeOnRequest(s.wakeOnRequest)
            change.hosting(s.hosting)
            change.timezone(TimeZone.current.identifier)
            change.fallbackPriceStepPercent(s.fallbackPriceStepPercent)
        }
        guard !change.values.isEmpty else { return nil }
        return await updateServer(id, change)
    }

    /// Models of this Mac that can move to a server right now: not managed elsewhere, and not
    /// starting, stopping or waiting for a card.
    var modelsReadyToHandOver: [PodlightModel] {
        state.models.filter { item in
            let run = state.run(item.id)
            return run.managedBy == nil && run.waitingForCard == nil && run.replacing == nil
                && [.stopped, .failed, .ready].contains(run.phase)
        }
    }

    /// Hands one model of this Mac to a server, with its pod and disk. Returns an error sentence, or nil.
    func handOver(_ modelId: UUID, to serverId: UUID) async -> String? {
        guard let server = server(serverId) else { return nil }
        let client = server.client(keychain)
        do {
            try await manager.handOver(modelId, toServer: server.entry.name) { model, key, podId in
                try await client.adopt(model, podKey: key, podId: podId)
            }
        } catch let error as ServerError {
            await reloadState()
            return Describe.handOverRefused(error)
        } catch {
            await reloadState()
            return Describe.error(error)
        }
        await reloadState()
        await server.refresh(keychain)
        return nil
    }

    func loadTokens(_ id: UUID) async {
        guard let server = server(id) else { return }
        if let tokens = try? await server.client(keychain).clientTokens() { server.tokens = tokens }
    }
}

/// A stopped pod's kept disk and what it costs.
struct KeptDisk: Identifiable {
    let source: Source
    let model: PodlightModel
    let gb: Int
    var id: UUID { model.id }
    var perHour: Double { StoragePricing.stoppedPerHour(volumeGB: gb) }
    var perMonth: Double { StoragePricing.stoppedPerMonth(volumeGB: gb) }
}

extension Array where Element == KeptDisk {
    var gb: Int { map(\.gb).reduce(0, +) }
    var perHour: Double { map(\.perHour).reduce(0, +) }
    var perMonth: Double { map(\.perMonth).reduce(0, +) }
}
