import PodlightEngine
import SwiftUI

/// First run: the one thing Podlight cannot work without (a RunPod key), the optional one
/// (a Hugging Face token), and then straight to the first model. Can be left and resumed.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0
    private func dismiss() { model.showingSetup = false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: RunpodKeyStep(onDone: { page = 2 })
                case 2: HuggingFaceStep(onDone: { page = 3 })
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .frame(maxWidth: 600, maxHeight: 520)
        .onAppear { if model.hasRunpodKey { page = model.hasHuggingFaceToken ? 3 : 2 } }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "lightbulb.max").font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
            Text("Welcome to Podlight").font(.largeTitle.weight(.semibold))
            Text("Podlight runs a language model of your choice on a rented GPU at RunPod, and lets the coding agent on this Mac use it, for example OpenCode.")
            VStack(alignment: .leading, spacing: 10) {
                Label("You pick a model, Podlight suggests a GPU and shows the price.", systemImage: "cpu")
                Label("Every start has an end. Idle pods stop by themselves.", systemImage: "timer")
                Label("If this Mac sleeps or Podlight quits, pods stop after a few minutes.", systemImage: "moon.zzz")
                Label("Your keys stay in this Mac's keychain.", systemImage: "lock")
            }
            .foregroundStyle(.secondary)
            Spacer()
            Text("You need a RunPod account with some credit. Setting up takes about a minute.")
                .font(.callout)
            HStack {
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Set Up") { page = 1 }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green).accessibilityHidden(true)
            Text("Podlight is connected to RunPod").font(.largeTitle.weight(.semibold))
            Text("Next, add a model. Podlight checks whether it suits a coding agent, suggests a GPU and shows the cost per hour. Nothing is started or charged until you press Start.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Good first choices for coding:").font(.headline)
                Text("• A 4-bit build (AWQ, GPTQ or INT4) of a coding model between 7 and 32 billion parameters.")
                Text("• Optional: a Hugging Face token, only for gated models (Settings → Access).")
            }
            .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add First Model…") {
                    dismiss()

                    Task { try? await Task.sleep(for: .milliseconds(300)); model.showingAddModel = true }
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Enter and check the RunPod key, with the steps to create one right beside the field.
struct RunpodKeyStep: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void
    @State private var key = ""
    @State private var checking = false
    @State private var result: RunpodKeyCheck?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your RunPod API key").font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Open RunPod's settings and sign in.")
                Text("2. Under \"API Keys\", click \"Create API Key\" and name it \"Podlight\".")
                Text("3. Choose the permission \"All\", or \"Restricted\" with read and write access to Pods.")
                Text("4. Copy the key and paste it here. RunPod shows it only once.")
            }
            Link(destination: Links.runpodAPIKeys) { Label("Open RunPod Settings", systemImage: "arrow.up.forward.square") }
            SecureField("Paste the API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await check() } }
            resultView
            Spacer()
            HStack {
                Text("The key is stored in this Mac's keychain and only ever sent to RunPod.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check and Save") { Task { await check() } }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
            }
        }
    }

    @ViewBuilder private var resultView: some View {
        if checking {
            ProgressView("Asking RunPod…").controlSize(.small)
        } else if let result {
            switch result {
            case .valid:
                Label("The key works.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .invalid:
                Label("RunPod does not know this key. Check that it was copied completely, or create a new one.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            case .missingPermission:
                Label("The key is valid but may not manage pods. Create one with \"All\", or \"Restricted\" with Pods: read and write.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .unreachable(let why):
                Label("RunPod could not be reached (\(why)). Check the internet connection and try again.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func check() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        checking = true
        defer { checking = false }
        let outcome = await RunpodClient(apiKey: trimmed).checkKey()
        result = outcome
        if outcome == .valid {
            do {
                try model.saveRunpodKey(trimmed)
                key = ""
                try? await Task.sleep(for: .milliseconds(600))
                onDone()
            } catch {
                result = .unreachable(error.localizedDescription)
            }
        }
    }
}


/// Optional, recommended: a Hugging Face token. Pods download over addresses RunPod shares, and
/// Hugging Face limits anonymous downloads per address more strictly (huggingface.co/docs/hub/rate-limits).
struct HuggingFaceStep: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void
    @State private var token = ""
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hugging Face token (recommended)").font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("Pods download models over addresses RunPod shares with other customers. Hugging Face limits downloads without an account more strictly, which can stop a download halfway.", systemImage: "arrow.down.circle")
                Label("Gated models such as Llama or Gemma need a token, after you accept their licence on the model page.", systemImage: "lock")
                Label("A token with read access is enough. It is stored in this Mac's keychain and passed to your own pods only.", systemImage: "key")
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Link(destination: Links.huggingFaceTokens) { Label("Create a Token at Hugging Face", systemImage: "arrow.up.forward.square") }
            SecureField("Paste the token (hf_…)", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await check() } }
            if checking { ProgressView("Asking Hugging Face…").controlSize(.small) }
            if let message { Text(message).foregroundStyle(.secondary) }
            Spacer()
            HStack {
                Button("Skip") { onDone() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Check and Save") { Task { await check() } }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
            }
        }
    }

    private func check() async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        checking = true
        defer { checking = false }
        switch await HuggingFaceClient(token: trimmed).checkToken() {
        case .valid(let user):
            try? model.saveHuggingFaceToken(trimmed)
            message = user.isEmpty ? String(localized: "Saved.") : String(localized: "Saved for \(user).")
            try? await Task.sleep(for: .milliseconds(600))
            onDone()
        case .invalid:
            message = String(localized: "Hugging Face does not accept this token.")
        case .unreachable:
            message = String(localized: "Hugging Face could not be reached.")
        }
    }
}
