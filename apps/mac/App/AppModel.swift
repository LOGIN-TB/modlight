import AppKit
import Foundation
import Observation
import PodlightEngine
import ServiceManagement

/// What the sidebar shows: each model, then the app's own areas.
enum SidebarItem: Hashable {
    case model(UUID)
    case connection
    case costs
    case settings
}

/// The app's state and actions, shared by every window and the menu bar.
@MainActor
@Observable
final class AppModel {
    let keychain: KeychainStore
    let manager: PodManager
    let notifier = Notifier()

    private(set) var state = PodlightState()
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
        notifier.compare(previous: previous, current: state)
        if selection == nil || !isValid(selection) { selection = state.models.first.map { .model($0.id) } ?? .connection }
    }

    private func isValid(_ item: SidebarItem?) -> Bool {
        guard case .model(let id) = item else { return item != nil }
        return state.models.contains { $0.id == id }
    }

    var selectedModel: PodlightModel? {
        guard case .model(let id) = selection else { return nil }
        return state.models.first { $0.id == id }
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

    func save(_ model: PodlightModel) async {
        do {
            try await manager.save(model)
            await reloadState()
            selection = .model(model.id)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func remove(_ model: PodlightModel) async {
        do {
            try await manager.remove(model.id)
            await reloadState()
            if selection == .model(model.id) { selection = state.models.first.map { .model($0.id) } ?? .connection }
        } catch {
            actionError = Describe.error(error)
        }
    }

    func start(_ model: PodlightModel, until: Date) async {
        actionError = nil
        notifier.requestPermissionOnce()
        do {
            try await manager.start(model.id, until: until, manual: true)
        } catch {
            actionError = Describe.error(error)
        }
        await reloadState()
    }

    func stop(_ model: PodlightModel) async {
        do {
            try await manager.stop(model.id, reason: "manual")
        } catch {
            actionError = Describe.error(error)
        }
        await reloadState()
    }

    func extend(_ model: PodlightModel, by interval: TimeInterval) async {
        let base = max(state.run(model.id).runUntil ?? .now, .now)
        try? await manager.extend(model.id, until: base.addingTimeInterval(interval))
        await reloadState()
    }

    func updateSettings(_ change: @escaping @Sendable (inout PodlightSettings) -> Void) async {
        _ = try? await manager.store.update { change(&$0.settings) }
        await reloadState()
    }

    // MARK: Costs

    /// What a run of `model` until `end` costs at most: cards plus storage.
    func maximumCost(of model: PodlightModel, until end: Date) -> Double? {
        let run = state.run(model.id)
        guard let price = run.pricePerHour ?? model.expectedPricePerHour else { return nil }
        let storage = run.storagePerHour ?? PodPlan.storagePerHour(for: model)
        return GPUSuggestion.cost(pricePerHour: price + storage, from: .now, until: end)
    }

    /// Monthly cost of a kept disk while the pod is stopped, if the model keeps one.
    func keptDiskPerMonth(_ model: PodlightModel) -> Double? {
        model.keepDisk ? StoragePricing.stoppedPerMonth(volumeGB: PodPlan.persistentGB(for: model)) : nil
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

    /// OpenCode, current format (opencode.ai/docs/models, "Compatible"), for the global
    /// ~/.config/opencode/opencode.json. Contains the key, so never for a repository.
    func openCodeConfig(baseURL: String) -> String {
        let first = state.models.first?.name ?? "model"
        let models = state.models.map { model in
            """
                    "\(model.name)": {
                      "name": "\(model.name) (Podlight)",
                      "capabilities": { "tools": \(model.toolCallParser != nil), "input": ["text"], "output": ["text"] },
                      "limit": { "context": \(model.contextTokens), "output": \(min(16_384, model.contextTokens / 4)) }
                    }
            """
        }.joined(separator: ",\n")
        return """
        {
          "$schema": "https://opencode.ai/config.json",
          "model": "podlight/\(first)",
          "providers": {
            "podlight": {
              "name": "Podlight",
              "package": "@opencode/ai/providers/openai-compatible",
              "settings": {
                "baseURL": "\(baseURL)",
                "apiKey": "\(gatewayKey ?? "")",
                "headerTimeout": 600000
              },
              "models": {
        \(models)
              }
            }
          }
        }
        """
    }

    /// pi, ~/.pi/agent/models.json (github.com/earendil-works/pi, docs/models.md).
    func piConfig(baseURL: String) -> String {
        let models = state.models.map { model in
            "        { \"id\": \"\(model.name)\", \"contextWindow\": \(model.contextTokens), \"maxTokens\": \(min(16_384, model.contextTokens / 4)) }"
        }.joined(separator: ",\n")
        return """
        {
          "$schema": "https://pi.dev/schemas/models.schema.json",
          "providers": {
            "podlight": {
              "baseUrl": "\(baseURL)",
              "api": "openai-completions",
              "apiKey": "\(gatewayKey ?? "")",
              "models": [
        \(models)
              ]
            }
          }
        }
        """
    }

    /// Environment variables most OpenAI-compatible tools read (Aider, scripts, SDKs).
    func environmentConfig(baseURL: String) -> String {
        """
        export OPENAI_BASE_URL="\(baseURL)"
        export OPENAI_API_BASE="\(baseURL)"
        export OPENAI_API_KEY="\(gatewayKey ?? "")"
        # Model: \(state.models.map(\.name).joined(separator: " | "))
        """
    }
}
