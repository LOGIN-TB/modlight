import AppKit
import Foundation
import Observation
import PodlightEngine
import ServiceManagement

/// What the sidebar shows: each model, then the app's own areas.
enum SidebarItem: Hashable {
    case overview
    case model(UUID)
    case connection
    case costs
    case settings
    /// Server mode: one server's connection, costs and settings.
    case serverConnection(UUID)
    case serverCosts(UUID)
    case serverSettings(UUID)
}

/// The app's state and actions, shared by every window and the menu bar.
@MainActor
@Observable
final class AppModel {
    let keychain: KeychainStore
    let manager: PodManager
    let notifier = Notifier()

    private(set) var state = PodlightState()
    /// The latest telemetry per model on this Mac whose pod runs, from the pod's watchdog.
    private(set) var localTelemetry: [UUID: PodTelemetry] = [:]
    /// Podlight pods in the RunPod account that another Mac manages, offered for taking over.
    private(set) var otherMacsPods: [ForeignPod] = []
    /// Pods being taken over right now, for a progress indicator on their row.
    private(set) var takingOver: Set<String> = []
    /// When the account was last searched for other Macs' models, and why that failed, if it did.
    private(set) var otherMacsCheckedAt: Date?
    private(set) var otherMacsError: String?
    /// Telemetry for the screenshots, instead of live pods.
    var sampleTelemetry: [UUID: [PodTelemetry]]?
    private(set) var hasRunpodKey = false
    private(set) var hasHuggingFaceToken = false
    private(set) var gatewayKey: String?
    enum GatewayStatus: Equatable { case starting, running, failed(String) }
    private(set) var gatewayStatus: GatewayStatus = .starting
    /// The address the gateway listens on right now (127.0.0.1 or 0.0.0.0).
    private(set) var gatewayHost = "127.0.0.1"
    /// One-line message about the last action that went wrong, shown where it happened.
    var actionError: String?
    var showingSetup = false
    var showingAddModel = false
    var editingModel: PodlightModel?
    var startingModel: PodlightModel?
    /// The start sheet builds a new pod on a new card (after "the machine's card is busy").
    var startingOnNewCard = false
    /// A model just added with "Add and Start…": its start sheet opens when the add sheet is gone.
    var startAfterAdding: UUID?
    /// Where the add sheet puts a new model.
    var addingTo: Source = .local
    var showingAddServer = false
    /// The Podlight servers this app controls, in the order the user added them.
    var servers: [ServerMirror] = []
    var selection: SidebarItem?
    /// Set by any view that has SwiftUI's openWindow action, so the Dock and the menu bar can
    /// bring the main window back after it was closed.
    var openMainWindow: (() -> Void)?

    private var gatewayTask: Task<Void, Never>?
    private var loops: [Task<Void, Never>] = []

    init(storeURL: URL = StateStore.defaultURL(), keychainService: String = "io.github.login-tb.podlight") {
        keychain = KeychainStore(service: keychainService)
        manager = PodManager(store: StateStore(url: storeURL), keychain: keychain)
        refreshSecrets()
        if gatewayKey == nil {
            let key = "pl-" + PodManager.randomKey()
            try? keychain.write(key, for: .gatewayKey)
            gatewayKey = key
        }
        showingSetup = !hasRunpodKey
    }

    /// Starts the gateway and the two loops: a fast one that mirrors state for the interface and
    /// a slower one that asks RunPod and applies the rules.
    func launch() {
        guard loops.isEmpty else { return }
        notifier.onExtend = { [weak self] id in
            guard let self, let model = self.state.models.first(where: { $0.id == id }) else { return }
            Task { await self.extend(model, by: 3600) }
        }
        loops.append(Task { [weak self] in
            await self?.reloadState()
            self?.startGateway()
            while !Task.isCancelled {
                await self?.reloadState()
                try? await Task.sleep(for: .seconds(1))
            }
        })
        // Servers run their own rules; the app only mirrors what they report.
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshServers()
                try? await Task.sleep(for: .seconds(5))
            }
        })
        // Other Macs' pods: one list request a minute, and after every take-over.
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshOtherMacsPods()
                try? await Task.sleep(for: .seconds(60))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.manager.tick()
                let busy = self.state.activeRuns.contains { $0.1.phase != .ready }
                try? await Task.sleep(for: .seconds(busy ? 10 : 20))
            }
        })
    }

    func reloadState() async {
        let previous = state
        state = await manager.state()
        let telemetry = await manager.latestTelemetry()
        if telemetry != localTelemetry { localTelemetry = telemetry }
        syncServers()
        notifier.compare(previous: previous, current: state)
        if selection == nil || !isValid(selection) { selection = .overview }
    }

    private func isValid(_ item: SidebarItem?) -> Bool {
        switch item {
        case .model(let id): return model(id) != nil || servers.contains { $0.snapshot == nil }
        case .serverConnection(let id), .serverCosts(let id), .serverSettings(let id): return server(id) != nil
        case nil: return false
        default: return true
        }
    }

    /// Opens the start sheet for a model added with "Add and Start…".
    func addSheetDismissed() {
        guard let id = startAfterAdding else { return }
        startAfterAdding = nil
        startingModel = model(id)
    }

    var selectedModel: PodlightModel? {
        guard case .model(let id) = selection else { return nil }
        return model(id)
    }

    private func refreshSecrets() {
        hasRunpodKey = keychain.contains(.runpodAPIKey)
        hasHuggingFaceToken = keychain.contains(.huggingFaceToken)
        gatewayKey = try? keychain.read(.gatewayKey)
    }

    // MARK: Gateway

    var gatewayPort: Int { state.settings.gatewayPort }
    var localBaseURL: String { "http://127.0.0.1:\(gatewayPort)/v1" }

    /// Addresses for other computers, when the local network may connect.
    var networkBaseURLs: [String] {
        guard state.settings.allowLAN else { return [] }
        let names = [NetworkAddresses.bonjourName()].compactMap { $0 } + NetworkAddresses.lanIPv4()
        return names.map { "http://\($0):\(gatewayPort)/v1" }
    }

    func startGateway() {
        gatewayTask?.cancel()
        gatewayStatus = .starting
        let manager = manager
        let keychain = keychain
        let port = state.settings.gatewayPort
        let host = state.settings.allowLAN ? "0.0.0.0" : "127.0.0.1"
        gatewayHost = host
        gatewayTask = Task { [weak self] in
            // A cancelled server, or the copy that just relaunched us, may still hold the port for a
            // moment: try a few times before reporting it as taken.
            for attempt in 1...5 {
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 300 : 1000))
                if Task.isCancelled { return }
                do {
                    let gateway = LocalGateway(port: port, host: host, manager: manager, key: { try? keychain.read(.gatewayKey) })
                    try await gateway.run(onReady: {
                        Task { @MainActor in self?.gatewayStatus = .running }
                    })
                    return
                } catch is CancellationError {
                    return
                } catch {
                    if attempt == 5 { await MainActor.run { self?.gatewayStatus = .failed(error.localizedDescription) } }
                }
            }
        }
    }

    func restartGateway() async {
        await reloadState()
        startGateway()
    }

    // MARK: Secrets

    func saveRunpodKey(_ key: String) throws {
        try keychain.write(key, for: .runpodAPIKey)
        refreshSecrets()
    }

    func saveHuggingFaceToken(_ token: String) throws {
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try keychain.delete(.huggingFaceToken)
        } else {
            try keychain.write(token, for: .huggingFaceToken)
        }
        refreshSecrets()
    }

    func newGatewayKey() {
        let key = "pl-" + PodManager.randomKey()
        try? keychain.write(key, for: .gatewayKey)
        refreshSecrets()
    }

    var huggingFace: HuggingFaceClient { HuggingFaceClient(token: try? keychain.read(.huggingFaceToken)) }

    func runpod() -> RunpodClient? {
        guard let key = try? keychain.read(.runpodAPIKey) else { return nil }
        return RunpodClient(apiKey: key)
    }

    // MARK: Models

    /// Saves a model where it lives; a new one goes to `source` (the add sheet's target).
    /// Returns false when it could not be saved; the reason is in `actionError`.
    @discardableResult
    func save(_ model: PodlightModel, to target: Source? = nil) async -> Bool {
        let where_ = target ?? source(of: model.id)
        do {
            switch where_ {
            case .local:
                try await manager.save(model)
                await reloadState()
            case .server(let id):
                guard let server = server(id) else { return false }
                try await server.client(keychain).save(model)
                await server.refresh(keychain)
            }
            actionError = nil
            selection = .model(model.id)
            return true
        } catch {
            actionError = Describe.error(error)
            return false
        }
    }

    func remove(_ model: PodlightModel) async {
        let where_ = source(of: model.id)
        do {
            switch where_ {
            case .local:
                try await manager.remove(model.id)
                await reloadState()
            case .server(let id):
                guard let server = server(id) else { return }
                try await server.client(keychain).remove(model.id)
                await server.refresh(keychain)
            }
            if selection == .model(model.id) { selection = .overview }
        } catch {
            actionError = Describe.error(error)
        }
    }

    func start(_ model: PodlightModel, until: Date, newPod: Bool = false) async {
        actionError = nil
        notifier.requestPermissionOnce()
        do {
            switch source(of: model.id) {
            case .local:
                try await manager.start(model.id, until: until, manual: true, newPod: newPod)
            case .server(let id):
                guard let server = server(id) else { return }
                try await server.client(keychain).start(model.id, until: until, newPod: newPod)
                await server.refresh(keychain)
            }
        } catch PodlightError.hostBusy {
            // The model's page shows the waiting and what the user can do instead.
        } catch ServerError.refused(_, _, "host_busy") {
            if case .server(let id) = source(of: model.id) { await server(id)?.refresh(keychain) }
        } catch {
            actionError = Describe.error(error)
        }
        await reloadState()
    }

    // MARK: Other Macs

    func refreshOtherMacsPods() async {
        guard hasRunpodKey else { otherMacsPods = []; return }
        do {
            otherMacsPods = try await manager.podsFromOtherMacs()
            otherMacsError = nil
        } catch {
            otherMacsError = Describe.error(error)
        }
        otherMacsCheckedAt = .now
    }

    /// Takes another Mac's model over; that Mac lets go when it next looks. With `thenStart`, the
    /// start sheet opens right after, so "Start…" on another Mac's model is one step.
    func takeOver(_ pod: ForeignPod, thenStart: Bool = false) async {
        actionError = nil
        takingOver.insert(pod.id)
        defer { takingOver.remove(pod.id) }
        do {
            let id = try await manager.takeOver(pod)
            await reloadState()
            selection = .model(id)
            let phase = run(id).phase
            if thenStart, phase == .stopped || phase == .failed, let item = state.models.first(where: { $0.id == id }) {
                startingModel = item
            }
        } catch {
            actionError = Describe.error(error)
        }
        await refreshOtherMacsPods()
    }

    /// Takes a model back that another Mac took over.
    func takeBack(_ model: PodlightModel) async {
        actionError = nil
        do { try await manager.takeBack(model.id) } catch { actionError = Describe.error(error) }
        await reloadState()
        await refreshOtherMacsPods()
    }

    /// For screenshots only.
    func showOtherMacsPodsForSnapshots(_ pods: [ForeignPod]) { otherMacsPods = pods }

    func stop(_ model: PodlightModel) async {
        do {
            switch source(of: model.id) {
            case .local:
                try await manager.stop(model.id, reason: "manual")
            case .server(let id):
                guard let server = server(id) else { return }
                try await server.client(keychain).stop(model.id)
                await server.refresh(keychain)
            }
        } catch {
            actionError = Describe.error(error)
        }
        await reloadState()
    }

    func extend(_ model: PodlightModel, by interval: TimeInterval) async {
        let base = max(run(model.id).runUntil ?? .now, .now)
        let until = base.addingTimeInterval(interval)
        switch source(of: model.id) {
        case .local:
            try? await manager.extend(model.id, until: until)
        case .server(let id):
            guard let server = server(id) else { return }
            do { try await server.client(keychain).extend(model.id, until: until) } catch { actionError = Describe.error(error) }
            await server.refresh(keychain)
        }
        await reloadState()
    }

    func updateSettings(_ change: @escaping @Sendable (inout PodlightSettings) -> Void) async {
        _ = try? await manager.store.update { change(&$0.settings) }
        await reloadState()
    }

    // MARK: Costs

    /// What a run of `model` until `end` costs at most: cards plus storage.
    func maximumCost(of model: PodlightModel, until end: Date) -> Double? {
        let run = run(model.id)
        guard let price = run.pricePerHour ?? model.expectedPricePerHour else { return nil }
        let storage = run.storagePerHour ?? PodPlan.storagePerHour(for: model)
        return GPUSuggestion.cost(pricePerHour: price + storage, from: .now, until: end)
    }

    /// Size of the disk a model keeps while its pod is stopped, if it keeps one: the pod's own
    /// once it has one, else the planned size.
    func keptDiskGB(_ model: PodlightModel) -> Int? {
        guard model.keepDisk else { return nil }
        return run(model.id).persistentGB ?? PodPlan.persistentGB(for: model)
    }

    // MARK: Quit

    var runningLocalPods: [(PodlightModel, ModelRun)] { state.activeRuns }

    func stopAllAndQuit() {
        Task {
            await manager.stopAll(reason: "app-quit")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    // MARK: Login item

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: Configuration files for agents

    /// The ready-made agent configurations for this Mac's gateway.
    var localAgentConfigs: AgentConfigs { AgentConfigs(key: gatewayKey ?? "", models: state.models) }

    func openCodeConfig(baseURL: String) -> String { localAgentConfigs.openCode(baseURL: baseURL) }

    /// Claude Code needs at least this much context to work; below it compacts constantly.
    static let claudeCodeMinimumContext = AgentConfigs.claudeCodeMinimumContext
}
