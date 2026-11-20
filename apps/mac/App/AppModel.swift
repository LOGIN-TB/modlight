import AppKit
import Foundation
import Observation
import PodlightEngine
import ServiceManagement

/// The app's state and actions, shared by every window and the menu bar.
@MainActor
@Observable
final class AppModel {
    let keychain: KeychainStore
    let manager: PodManager

    private(set) var state = PodlightState()
    private(set) var hasRunpodKey = false
    private(set) var hasHuggingFaceToken = false
    private(set) var gatewayKey: String?
    enum GatewayStatus: Equatable { case starting, running, failed(String) }
    private(set) var gatewayStatus: GatewayStatus = .starting
    /// One-line message about the last action that went wrong, shown where it happened.
    var actionError: String?
    var showingSetup = false
    var showingAddModel = false
    var startingModel: PodlightModel?
    var selection: SidebarItem? = .models
    var selectedModelID: UUID?
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
        startGateway()
        loops.append(Task { [weak self] in
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
        state = await manager.state()
    }

    private func refreshSecrets() {
        hasRunpodKey = keychain.contains(.runpodAPIKey)
        hasHuggingFaceToken = keychain.contains(.huggingFaceToken)
        gatewayKey = try? keychain.read(.gatewayKey)
    }

    // MARK: Gateway

    var gatewayPort: Int { state.settings.gatewayPort }
    var gatewayBaseURL: String { "http://127.0.0.1:\(gatewayPort)/v1" }

    func startGateway() {
        gatewayTask?.cancel()
        gatewayStatus = .starting
        let manager = manager
        let keychain = keychain
        let port = state.settings.gatewayPort
        gatewayTask = Task { [weak self] in
            do {
                let gateway = LocalGateway(port: port, manager: manager, key: { try? keychain.read(.gatewayKey) })
                try await gateway.run(onReady: {
                    Task { @MainActor in self?.gatewayStatus = .running }
                })
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.gatewayStatus = .failed(error.localizedDescription) }
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
            selectedModelID = model.id
        } catch {
            actionError = error.localizedDescription
        }
    }

    func remove(_ model: PodlightModel) async {
        do {
            try await manager.remove(model.id)
            await reloadState()
            if selectedModelID == model.id { selectedModelID = state.models.first?.id }
        } catch {
            actionError = Describe.error(error)
        }
    }

    func start(_ model: PodlightModel, until: Date) async {
        actionError = nil
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

    // MARK: Connection snippets

    /// OpenCode's current config format (opencode.ai/docs/models, "Compatible"). Meant for the
    /// global ~/.config/opencode/opencode.json, never for a repository: it contains the key.
    var openCodeConfig: String {
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
                "baseURL": "\(gatewayBaseURL)",
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

    /// For any other OpenAI-compatible client.
    var genericConfig: String {
        """
        Base URL:  \(gatewayBaseURL)
        API key:   \(gatewayKey ?? "")
        Model:     \(state.models.map(\.name).joined(separator: " | "))
        """
    }
}

enum SidebarItem: Hashable {
    case models, connection, costs
}
