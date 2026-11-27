import AppKit
import Foundation
import Observation
import ModlightEngine
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

    private(set) var state = ModlightState()
    /// The latest telemetry per model on this Mac whose pod runs, from the pod's watchdog.
    private(set) var localTelemetry: [UUID: PodTelemetry] = [:]
    /// Requests the gateway on this Mac is answering right now, per model.
    private(set) var localInFlight: [UUID: Int] = [:]
    /// Each local API model's requests of the last half hour and its provider's latest rate limit.
    private(set) var localAPISamples: [UUID: [APIRequestSample]] = [:]
    private(set) var localAPIRateLimits: [UUID: APIRateLimit] = [:]
    /// Venice's public figures per model id (uptime, first token, speed), read every five minutes.
    private(set) var venicePerformance: [String: VenicePerformance] = [:]
    private var venicePerformanceAt: Date?
    /// Ticks with the state reload, so "answered a moment ago" goes out on time.
    private(set) var now = Date.now
    /// Modlight pods in the RunPod account that another Mac manages, offered for taking over.
    private(set) var otherMacsPods: [ForeignPod] = []
    /// Pods being taken over right now, for a progress indicator on their row.
    private(set) var takingOver: Set<String> = []
    /// When the account was last searched for other Macs' models, and why that failed, if it did.
    private(set) var otherMacsCheckedAt: Date?
    private(set) var otherMacsError: String?
    /// The RunPod account's credit, read with this Mac's key; nil without a key or an answer.
    private(set) var localBalance: RunpodBalance?
    /// Telemetry for the screenshots, instead of live pods.
    var sampleTelemetry: [UUID: [PodTelemetry]]?
    private(set) var hasRunpodKey = false
    private(set) var hasVeniceKey = false
    /// The Venice account behind this Mac's key: balances, tier, key expiry, rate limits.
    private(set) var veniceAccount: APIAccount?
    private(set) var veniceAccountCheckedAt: Date?
    /// Venice's catalog, read when the add sheet or a price check needs it.
    private(set) var veniceCatalog: [APIModelOffer] = []
    private(set) var veniceCatalogLoadedAt: Date?
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
    var editingModel: ModlightModel?
    var startingModel: ModlightModel?
    /// The start sheet builds a new pod on a new card (after "the machine's card is busy").
    var startingOnNewCard = false
    /// A model just added with "Add and Start…": its start sheet opens when the add sheet is gone.
    var startAfterAdding: UUID?
    /// Where the add sheet puts a new model.
    var addingTo: Source = .local
    var showingAddServer = false
    /// The "Bring This Mac's Setup Along" sheet, for one server.
    var transfer: TransferRequest?
    /// The server paired a moment ago, for the transfer offer once the pairing sheet is gone.
    var justPaired: UUID?
    /// The Modlight servers this app controls, in the order the user added them.
    var servers: [ServerMirror] = []
    var selection: SidebarItem?
    /// Set by any view that has SwiftUI's openWindow action, so the Dock and the menu bar can
    /// bring the main window back after it was closed.
    var openMainWindow: (() -> Void)?

    private var gatewayTask: Task<Void, Never>?
    private var loops: [Task<Void, Never>] = []

    init(storeURL: URL = StateStore.defaultURL(), keychainService: String = "io.github.login-tb.modlight") {
        keychain = KeychainStore(service: keychainService)
        manager = PodManager(store: StateStore(url: storeURL), keychain: keychain)
        refreshSecrets()
        if gatewayKey == nil {
            let key = "ml-" + PodManager.randomKey()
            try? keychain.write(key, for: .gatewayKey)
            gatewayKey = key
        }
        showingSetup = !hasRunpodKey && !hasVeniceKey
    }

    /// Any provider set up on this Mac: RunPod for pods, Venice for API models.
    var hasAnyProvider: Bool { hasRunpodKey || hasVeniceKey }

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
        // Other Macs' pods and the account's credit: one request each a minute.
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshOtherMacsPods()
                await self.refreshBalance()
                await self.refreshVeniceAccount()
                await self.refreshVenicePrices()
                await self.refreshVenicePerformance()
                try? await Task.sleep(for: .seconds(60))
            }
        })
        // Apart from the tick, which can wait minutes on a start: let go of deleted pods at once.
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.manager.reconcile()
                try? await Task.sleep(for: .seconds(10))
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
        let inFlight = await manager.inFlightCounts()
        if inFlight != localInFlight { localInFlight = inFlight }
        let live = await manager.apiTelemetryByModel()
        if live.samples != localAPISamples { localAPISamples = live.samples }
        if live.rateLimits != localAPIRateLimits { localAPIRateLimits = live.rateLimits }
        now = .now
        syncServers()
        notifier.compare(previous: previous, current: state)
        // A request to a Venice model was booked: read the balance again soon, so it follows use.
        if previous.apiUsage != state.apiUsage, hasVeniceKey,
           veniceAccountCheckedAt.map({ Date.now.timeIntervalSince($0) > 5 }) ?? true {
            Task { await refreshVeniceAccount() }
        }
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

    var selectedModel: ModlightModel? {
        guard case .model(let id) = selection else { return nil }
        return model(id)
    }

    private func refreshSecrets() {
        hasRunpodKey = keychain.contains(.runpodAPIKey)
        hasVeniceKey = keychain.contains(.veniceAPIKey)
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

    /// Checks a Venice key and saves it when Venice accepts it.
    func saveVeniceKey(_ key: String) async -> APIKeyCheck {
        let outcome = await VeniceClient(apiKey: key).checkKey()
        if case .valid(let account) = outcome {
            do {
                try keychain.write(key, for: .veniceAPIKey)
            } catch {
                return .unreachable(error.localizedDescription)
            }
            refreshSecrets()
            veniceAccount = account
            veniceAccountCheckedAt = .now
        }
        return outcome
    }

    func removeVeniceKey() {
        try? keychain.delete(.veniceAPIKey)
        refreshSecrets()
        veniceAccount = nil
        veniceAccountCheckedAt = nil
    }

    func venice() -> VeniceClient { VeniceClient(apiKey: try? keychain.read(.veniceAPIKey)) }

    /// Reads the Venice balance. A failure keeps the last answer (it shows its time).
    func refreshVeniceAccount() async {
        guard hasVeniceKey else { veniceAccount = nil; return }
        veniceAccountCheckedAt = .now
        if let account = try? await venice().account() { veniceAccount = account }
    }

    /// Venice's catalog; read again after an hour.
    @discardableResult
    func loadVeniceCatalog(force: Bool = false) async throws -> [APIModelOffer] {
        if !force, let at = veniceCatalogLoadedAt, Date.now.timeIntervalSince(at) < 3600, !veniceCatalog.isEmpty { return veniceCatalog }
        veniceCatalog = try await venice().catalog()
        veniceCatalogLoadedAt = .now
        return veniceCatalog
    }

    /// Venice changes prices now and then: once a day each Venice model on this Mac takes the
    /// catalog's current ones, so costs are counted right.
    func refreshVenicePrices() async {
        let stale = state.models.filter { $0.provider == .venice && ($0.api.map { Date.now.timeIntervalSince($0.pricedAt) > 86_400 } ?? false) }
        guard !stale.isEmpty, let catalog = try? await loadVeniceCatalog() else { return }
        for var item in stale {
            guard let offer = catalog.first(where: { $0.providerModelId == item.api?.providerModelId }) else { continue }
            item.api?.pricing = offer.pricing
            item.api?.pricedAt = .now
            item.api?.removesAt = offer.removesAt
            try? await manager.save(item)
        }
        await reloadState()
    }

    /// Venice's public per-model figures, when a Venice model is set up here or on a server.
    func refreshVenicePerformance(force: Bool = false) async {
        let anyVenice = state.models.contains { $0.provider == .venice } || servers.contains { $0.models.contains { $0.provider == .venice } }
        guard anyVenice else { return }
        if !force, let at = venicePerformanceAt, Date.now.timeIntervalSince(at) < 300 { return }
        venicePerformanceAt = .now
        if let figures = try? await VeniceClient(apiKey: nil).performance() { venicePerformance = figures }
    }

    /// For the help snapshots: live figures without a gateway.
    func showAPITelemetryForSnapshots(samples: [UUID: [APIRequestSample]], rateLimits: [UUID: APIRateLimit],
                                      performance: [String: VenicePerformance]) {
        localAPISamples = samples
        localAPIRateLimits = rateLimits
        venicePerformance = performance
    }

    /// Venice's rate limits for one model, from the account.
    func veniceLimits(for providerModelId: String) -> [APIAccount.RateLimit] {
        veniceAccount?.rateLimits.filter { $0.model == providerModelId } ?? []
    }

    func newGatewayKey() {
        let key = "ml-" + PodManager.randomKey()
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
    func save(_ model: ModlightModel, to target: Source? = nil) async -> Bool {
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

    func remove(_ model: ModlightModel) async {
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

    /// Starts a model. Returns a question when the chosen card is taken and only pricier ones are
    /// free: nothing was booked, and the user decides. `maxPricePerHour` is that decision.
    @discardableResult
    func start(_ model: ModlightModel, until: Date, newPod: Bool = false, maxPricePerHour: Double? = nil) async -> PriceQuestion? {
        actionError = nil
        notifier.requestPermissionOnce()
        var question: PriceQuestion?
        do {
            switch source(of: model.id) {
            case .local:
                try await manager.start(model.id, until: until, manual: true, newPod: newPod, maxPricePerHour: maxPricePerHour)
            case .server(let id):
                guard let server = server(id) else { return nil }
                try await server.client(keychain).start(model.id, until: until, newPod: newPod, maxPricePerHour: maxPricePerHour)
                await server.refresh(keychain)
            }
        } catch ModlightError.hostBusy {
            // The model's page shows the waiting and what the user can do instead.
        } catch ModlightError.cardTooExpensive(let wanted, let ceiling, let pricier) {
            question = PriceQuestion(wanted: wanted, ceiling: ceiling, pricier: pricier,
                                     waitsUntil: state.run(model.id).waitingForCard?.until)
        } catch ServerError.refused(_, _, "host_busy") {
            if case .server(let id) = source(of: model.id) { await server(id)?.refresh(keychain) }
        } catch ServerError.refused(_, let message, "card_too_expensive") {
            if case .server(let id) = source(of: model.id), let server = server(id) {
                await server.refresh(keychain)
                if let waiting = server.snapshot?.run(model.id).waitingForCard, let ceiling = waiting.maxPricePerHour {
                    question = PriceQuestion(wanted: waiting.wanted, ceiling: ceiling, pricier: waiting.pricier ?? [],
                                             waitsUntil: waiting.until)
                } else {
                    actionError = message
                }
            }
        } catch {
            actionError = Describe.error(error)
        }
        await reloadState()
        return question
    }

    // MARK: Refresh

    private(set) var refreshing = false

    /// "Refresh": asks RunPod now, here and on every server, instead of at the next round.
    func refreshNow() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.manager.reconcile() }
            for server in servers {
                let keychain = keychain
                group.addTask {
                    try? await server.client(keychain).refresh()
                    await server.refresh(keychain)
                }
            }
        }
        await reloadState()
        await refreshOtherMacsPods()
        await refreshBalance()
    }

    // MARK: Account

    /// Sample credit for the help snapshots.
    func showBalanceForSnapshots(_ balance: RunpodBalance) { localBalance = balance }

    /// A sample Venice account and catalog for the help snapshots.
    func showVeniceForSnapshots(account: APIAccount, catalog: [APIModelOffer]) {
        veniceAccount = account
        veniceAccountCheckedAt = .now
        veniceCatalog = catalog
        veniceCatalogLoadedAt = .now
    }

    /// Reads the account's credit. A failure keeps the last answer (it shows its time).
    func refreshBalance() async {
        guard let client = runpod() else { localBalance = nil; return }
        if var balance = try? await client.balance() {
            balance.checkedAt = .now
            localBalance = balance
        }
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
    func takeBack(_ model: ModlightModel) async {
        actionError = nil
        do { try await manager.takeBack(model.id) } catch { actionError = Describe.error(error) }
        await reloadState()
        await refreshOtherMacsPods()
    }

    /// For screenshots only.
    func showOtherMacsPodsForSnapshots(_ pods: [ForeignPod]) { otherMacsPods = pods }

    func stop(_ model: ModlightModel) async {
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

    func extend(_ model: ModlightModel, by interval: TimeInterval) async {
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

    func updateSettings(_ change: @escaping @Sendable (inout ModlightSettings) -> Void) async {
        _ = try? await manager.store.update { change(&$0.settings) }
        await reloadState()
    }

    // MARK: Costs

    /// What a run of `model` until `end` costs at most: cards plus storage.
    func maximumCost(of model: ModlightModel, until end: Date) -> Double? {
        let run = run(model.id)
        guard let price = run.pricePerHour ?? model.expectedPricePerHour else { return nil }
        let storage = run.storagePerHour ?? PodPlan.storagePerHour(for: model)
        return GPUSuggestion.cost(pricePerHour: price + storage, from: .now, until: end)
    }

    /// Size of the disk a model keeps while its pod is stopped, if it keeps one: the pod's own
    /// once it has one, else the planned size.
    func keptDiskGB(_ model: ModlightModel) -> Int? {
        guard model.keepDisk else { return nil }
        return run(model.id).persistentGB ?? PodPlan.persistentGB(for: model)
    }

    // MARK: Quit

    var runningLocalPods: [(ModlightModel, ModelRun)] { state.activeRuns }

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

/// The chosen card is taken and only pricier ones are free: what to show the user.
struct PriceQuestion: Equatable {
    var wanted: PricedChoice?
    /// The most a card may cost without asking.
    var ceiling: Double
    /// Cards that may be free, cheapest first.
    var pricier: [PricedChoice]
    /// Modlight keeps trying within the price until then; nil when it does not wait.
    var waitsUntil: Date?

    /// "+240 %" against the chosen card, or nil without its price.
    func extra(_ option: PricedChoice) -> String? {
        guard let base = wanted?.pricePerHour, base > 0 else { return nil }
        return "+\(Int(((option.pricePerHour / base - 1) * 100).rounded())) %"
    }
}
