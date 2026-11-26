import PodlightEngine
import Sparkle
import SwiftUI

@main
struct PodlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    private let updater = SPUStandardUpdaterController(startingUpdater: !Bundle.main.isUnconfiguredForUpdates,
                                                       updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Podlight", id: "main") {
            RootView()
                .environment(model)
                .onAppear {
                    delegate.model = model
                    if Snapshots.requestedDirectory == nil { model.launch() }
                }
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
                    .disabled(Bundle.main.isUnconfiguredForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Model…") { model.addModel(to: .local) }
                    .keyboardShortcut("n")
                    .disabled(!model.hasRunpodKey)
                Button("Add Server…") { model.showingAddServer = true }
            }
            CommandMenu("Model") {
                let selected = model.selectedModel
                let phase = selected.map { model.run($0.id).phase } ?? .stopped
                Button("Start…") { model.startingModel = selected }
                    .keyboardShortcut("r")
                    .disabled(selected == nil || phase != .stopped && phase != .failed)
                Button("Stop") { if let selected { Task { await model.stop(selected) } } }
                    .keyboardShortcut(".")
                    .disabled(selected == nil || phase == .stopped || phase == .failed)
                Button("Extend by One Hour") { if let selected { Task { await model.extend(selected, by: 3600) } } }
                    .keyboardShortcut("e")
                    .disabled(selected == nil || phase == .stopped || phase == .failed)
                Divider()
                Button("Edit…") { model.editingModel = selected }
                    .disabled(selected == nil || (phase != .stopped && phase != .failed))
            }
            CommandMenu("Connection") {
                Button("Copy Address") { Pasteboard.copy(model.localBaseURL) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Copy API Key") { Pasteboard.copy(model.gatewayKey ?? "") }
                Button("Copy OpenCode Configuration") { Pasteboard.copy(model.openCodeConfig(baseURL: model.localBaseURL)) }
            }
            CommandGroup(replacing: .help) {
                Button("Podlight Help") { openWindow(id: "help") }
                    .keyboardShortcut("?")
                Button("Run Setup Again…") { model.showingSetup = true }
                Divider()
                Link("RunPod Console", destination: Links.runpodConsole)
                Link("Podlight on GitHub", destination: Links.repository)
            }
        }

        Window("Move Podlight", id: "move") {
            MoveToApplicationsView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Podlight Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 760, height: 620)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon: a lit bulb while anything runs, so a running pod is never invisible.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let active = !model.state.activeRuns.isEmpty
        Image(systemName: active ? "lightbulb.max.fill" : "lightbulb")
            .accessibilityLabel(active ? Text("Podlight: pods running") : Text("Podlight: nothing running"))
    }
}

enum Links {
    static let runpodConsole = URL(string: "https://console.runpod.io")!
    static let runpodAPIKeys = URL(string: "https://console.runpod.io/user/settings")!
    static let runpodBilling = URL(string: "https://console.runpod.io/user/billing")!
    static let veniceAPIKeys = URL(string: "https://venice.ai/settings/api")!
    static let veniceSignUp = URL(string: "https://venice.ai/sign-up")!
    static let venicePricing = URL(string: "https://docs.venice.ai/overview/pricing")!
    static let huggingFaceTokens = URL(string: "https://huggingface.co/settings/tokens")!
    static let huggingFace = URL(string: "https://huggingface.co/models?pipeline_tag=text-generation&sort=trending")!
    static let repository = URL(string: "https://github.com/LOGIN-TB/podlight")!
    static let openCode = URL(string: "https://opencode.ai/docs/models")!
    static let claudeCodeGateway = URL(string: "https://code.claude.com/docs/en/llm-gateway")!
    static let codexConfig = URL(string: "https://learn.chatgpt.com/docs/config-file/config-reference")!
    static let pi = URL(string: "https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md")!
    static let serverCompose = URL(string: "https://github.com/LOGIN-TB/podlight/blob/main/server/docker-compose.yml")!
    static let serverDocs = URL(string: "https://github.com/LOGIN-TB/podlight/blob/main/server/README.md")!
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension Bundle {
    /// Builds without a Sparkle key (local development) do not check for updates.
    var isUnconfiguredForUpdates: Bool {
        (object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
    }
}
