import PodlightEngine
import SwiftUI

// Venice: ready models billed per token. The key, the catalog to add from, an API model's page
// and the balance.

// MARK: Key

/// Enter and check the Venice key, with the steps to get one right beside the field.
struct VeniceKeyStep: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void
    var showsSkip = false
    @State private var key = ""
    @State private var checking = false
    @State private var result: APIKeyCheck?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Venice API key").font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Create an account at venice.ai and add credit: USD credits by card or crypto, or a Pro plan with monthly credits.")
                Text("2. Open Settings → API and click \"Generate New API Key\".")
                Text("3. Choose the type \"Inference Only\". An expiry date and a daily limit are optional.")
                Text("4. Copy the key and paste it here. Venice shows it only once.")
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link(destination: Links.veniceAPIKeys) { Label("Open Venice API Settings", systemImage: "arrow.up.forward.square") }
                Link(destination: Links.veniceSignUp) { Label("Create an Account", systemImage: "person.badge.plus") }
            }
            SecureField("Paste the API key (VENICE_INFERENCE_KEY_…)", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await check() } }
            resultView
            Spacer()
            HStack {
                if showsSkip { Button("Skip") { onDone() }.keyboardShortcut(.cancelAction) }
                Text("The key is stored in this Mac's keychain and only ever sent to Venice.")
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
            ProgressView("Asking Venice…").controlSize(.small)
        } else if let result {
            switch result {
            case .valid(let account):
                Label("The key works. Balance: \(VeniceText.balances(account))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .invalid:
                Label("Venice does not accept this key. Check that it was copied completely, or create a new one.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            case .unreachable(let why):
                Label("Venice could not be reached (\(why)). Check the internet connection and try again.", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func check() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        checking = true
        defer { checking = false }
        let outcome = await model.saveVeniceKey(trimmed)
        result = outcome
        if case .valid = outcome {
            key = ""
            try? await Task.sleep(for: .milliseconds(900))
            onDone()
        }
    }
}

/// The Venice key in Settings → Providers.
struct VeniceKeySettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var confirmingRemove = false

    var body: some View {
        LabeledContent("Venice API key", value: model.hasVeniceKey ? String(localized: "Saved in the keychain") : String(localized: "Not set"))
        if let account = model.veniceAccount {
            LabeledContent("Venice balance", value: VeniceText.balances(account))
            if let expiry = account.keyExpiration {
                LabeledContent("Key expires", value: Format.time(expiry))
            }
        }
        HStack {
            Button(model.hasVeniceKey ? "Replace Venice Key…" : "Add Venice Key…") { editing = true }
            if model.hasVeniceKey {
                Button("Remove Venice Key", role: .destructive) { confirmingRemove = true }
            }
        }
        .sheet(isPresented: $editing) {
            VeniceKeyStep(onDone: { editing = false }, showsSkip: true)
                .environment(model)
                .padding(20)
                .frame(width: 560, height: 460)
        }
        .confirmationDialog("Remove the Venice key?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { model.removeVeniceKey() }
        } message: {
            Text("Venice models stay in Podlight but answer agents with an error until a key is added again.")
        }
    }
}

// MARK: Text

enum VeniceText {
    /// "$12.50 · 3.25 DIEM · $1.00 credits"
    static func balances(_ account: APIAccount) -> String {
        var parts: [String] = []
        if let usd = account.amount("USD") { parts.append(usd.formatted(.currency(code: "USD").precision(.fractionLength(2)))) }
        if let diem = account.amount("DIEM"), diem > 0 { parts.append("\(diem.formatted(.number.precision(.fractionLength(0...2)))) DIEM") }
        if let bundled = account.amount("BUNDLED_CREDITS"), bundled > 0 { parts.append(String(localized: "\(Format.money(bundled)) plan credits")) }
        return parts.isEmpty ? String(localized: "none") : parts.joined(separator: " · ")
    }

    static func privacy(_ privacy: APIPrivacy) -> String {
        switch privacy {
        case .private: String(localized: "Private")
        case .anonymized: String(localized: "Anonymized")
        }
    }

    static func privacyHelp(_ privacy: APIPrivacy) -> String {
        switch privacy {
        case .private: String(localized: "Runs on hardware that keeps nothing: no prompt or answer is stored.")
        case .anonymized: String(localized: "A third party (for example Anthropic, OpenAI or Google) runs the model. Venice passes the prompt on without who sent it; that provider's terms apply.")
        }
    }

    static func capability(_ name: String) -> String {
        switch name {
        case "tools": String(localized: "Tools")
        case "vision": String(localized: "Images")
        case "reasoning": String(localized: "Reasoning")
        case "code": String(localized: "Code")
        default: name
        }
    }

    /// "$0.50 in · $2.00 out per 1M tokens"
    static func prices(_ pricing: APIPricing) -> String {
        String(localized: "\(Format.perMillion(pricing.input)) in · \(Format.perMillion(pricing.output)) out per 1M tokens")
    }

    static func limit(_ limit: APIAccount.RateLimit) -> String {
        let amount = Int(limit.amount)
        return switch limit.type {
        case "RPM": String(localized: "\(amount) requests a minute")
        case "RPD": String(localized: "\(amount) requests a day")
        case "TPM": String(localized: "\(Format.tokenCount(amount)) tokens a minute")
        default: "\(amount) \(limit.type)"
        }
    }
}

struct PrivacyBadge: View {
    let privacy: APIPrivacy

    var body: some View {
        Label(VeniceText.privacy(privacy), systemImage: privacy == .private ? "lock.shield" : "eye.slash")
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(privacy == .private ? Color.green.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
            .help(VeniceText.privacyHelp(privacy))
    }
}

// MARK: Adding

/// "Add Model": a pod for a Hugging Face model, or a ready model at Venice.
struct AddModelChooser: View {
    @Environment(AppModel.self) private var model
    let target: Source
    enum Kind: Hashable { case pod, venice }
    @State private var kind: Kind?

    init(target: Source, initial: Kind? = nil) {
        self.target = target
        _kind = State(initialValue: initial)
    }

    private var podPossible: Bool { model.canStart(in: target) }
    private var venicePossible: Bool {
        switch target {
        case .local: true
        case .server: model.hasVeniceKey(in: target)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Where it runs", selection: Binding(get: { kind ?? defaultKind }, set: { kind = $0 })) {
                Text("Own pod at RunPod · per hour").tag(Kind.pod)
                Text("Ready model at Venice · per token").tag(Kind.venice)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20).padding(.top, 14)
            switch kind ?? defaultKind {
            case .pod:
                if podPossible {
                    AddModelSheet(target: target)
                } else {
                    missing(String(localized: "Pods need a RunPod API key."), action: String(localized: "Add RunPod Key in Setup…")) {
                        model.showingAddModel = false
                        model.showingSetup = true
                    }
                }
            case .venice:
                if venicePossible {
                    AddVeniceModelView(target: target)
                } else {
                    missing(String(localized: "This server has no Venice API key yet. Add it under the server's settings."), action: nil) {}
                }
            }
        }
    }

    private var defaultKind: Kind { podPossible || !venicePossible ? (model.hasVeniceKey(in: target) && !podPossible ? .venice : .pod) : .venice }

    private func missing(_ text: String, action: String?, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            if let action { Button(action, action: perform).buttonStyle(.glassProminent) }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { model.showingAddModel = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 600)
    }
}

/// Venice's catalog with search and filters; pick one, name it, add it. Nothing is charged until an
/// agent uses it.
struct AddVeniceModelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: Source

    @State private var query = ""
    @State private var includeAnonymized = false
    @State private var needed: Set<String> = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var selected: APIModelOffer.ID?
    @State private var name = ""
    @State private var nameEdited = false
    @State private var showingKey = false
    @State private var saving = false

    private var offers: [APIModelOffer] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return model.veniceCatalog
            .filter { includeAnonymized || $0.privacy == .private }
            .filter { needed.isSubset(of: Set($0.capabilities)) }
            .filter { offer in
                let text = "\(offer.displayName) \(offer.providerModelId) \(offer.description ?? "")".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            .sorted { a, b in
                let ta = a.traits.contains { $0.hasPrefix("default") }, tb = b.traits.contains { $0.hasPrefix("default") }
                return ta != tb ? ta : a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
    }

    private var chosen: APIModelOffer? { model.veniceCatalog.first { $0.id == selected } }
    private var takenNames: Set<String> { Set(model.models(in: target).map(\.name)) }
    private var nameProblem: String? {
        if name.isEmpty { return nil }
        if !PodlightModel.isValidName(name) { return String(localized: "Lowercase letters, digits, \".\", \"_\" and \"-\".") }
        if takenNames.contains(name) { return String(localized: "There is already a model with this name.") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a Venice Model").font(.title2.weight(.semibold))
                    if case .server = target {
                        Label("On \(model.name(of: target))", systemImage: "server.rack").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Link("Venice prices", destination: Links.venicePricing).font(.callout)
            }
            .padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if target == .local && !model.hasVeniceKey {
                    HStack {
                        Label("Add your Venice API key, so agents can use what you add here.", systemImage: "key")
                        Spacer()
                        Button("Add Key…") { showingKey = true }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    TextField("Search, e.g. qwen, coder, glm", text: $query).textFieldStyle(.roundedBorder)
                    Toggle("Include anonymized", isOn: $includeAnonymized)
                        .help(VeniceText.privacyHelp(.anonymized))
                }
                HStack(spacing: 6) {
                    Text("Needs:").foregroundStyle(.secondary)
                    ForEach(["tools", "code", "reasoning", "vision"], id: \.self) { capability in
                        Toggle(VeniceText.capability(capability), isOn: Binding(
                            get: { needed.contains(capability) },
                            set: { if $0 { needed.insert(capability) } else { needed.remove(capability) } }))
                            .toggleStyle(.button)
                            .controlSize(.small)
                    }
                    Spacer()
                    Text("\(offers.count) models").font(.caption).foregroundStyle(.secondary)
                }
                List(offers, selection: $selected) { offer in
                    VeniceOfferRow(offer: offer).tag(offer.id)
                }
                .overlay {
                    if loading { ProgressView("Reading Venice's catalog…") }
                    else if let loadError {
                        VStack(spacing: 8) {
                            Label(loadError, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                            Button("Try Again") { Task { await load(force: true) } }
                        }
                    } else if offers.isEmpty {
                        Text(includeAnonymized ? "Nothing matches." : "Nothing matches among the private models. Include anonymized ones?")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 760, height: 600)
        .task { await load(force: false) }
        .onChange(of: selected) {
            if !nameEdited, let chosen { name = uniqueName(chosen.suggestedName) }
        }
        .sheet(isPresented: $showingKey) {
            VeniceKeyStep(onDone: { showingKey = false }, showsSkip: true)
                .environment(model)
                .padding(20)
                .frame(width: 560, height: 460)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let chosen {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chosen.displayName).font(.callout.weight(.medium))
                    Text(VeniceText.prices(chosen.pricing)).font(.caption).foregroundStyle(.secondary)
                }
                TextField("Name for agents", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                if let nameProblem { Text(nameProblem).font(.caption).foregroundStyle(.red) }
            } else {
                Text("Choose a model. Nothing is charged until an agent uses it.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Add Model") { Task { await add() } }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(chosen == nil || name.isEmpty || nameProblem != nil || saving)
        }
        .padding(16)
    }

    private func uniqueName(_ base: String) -> String {
        let start = PodlightModel.isValidName(base) ? base : "venice-model"
        var candidate = start
        var n = 2
        while takenNames.contains(candidate) { candidate = "\(start)-\(n)"; n += 1 }
        return candidate
    }

    private func load(force: Bool) async {
        guard force || model.veniceCatalog.isEmpty else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            try await model.loadVeniceCatalog(force: force)
        } catch {
            loadError = String(localized: "Venice's catalog could not be read.")
        }
    }

    private func add() async {
        guard let chosen else { return }
        saving = true
        defer { saving = false }
        if await model.save(chosen.model(named: name), to: target) { dismiss() }
    }
}

struct VeniceOfferRow: View {
    let offer: APIModelOffer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(offer.displayName).font(.body.weight(.medium))
                    PrivacyBadge(privacy: offer.privacy)
                }
                Text(offer.providerModelId).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 6) {
                    ForEach(offer.capabilities, id: \.self) { Text(VeniceText.capability($0)).font(.caption2).foregroundStyle(.secondary) }
                    if let removes = offer.removesAt {
                        Label("Retired on \(removes.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar.badge.exclamationmark")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Format.perMillion(offer.pricing.input)) / \(Format.perMillion(offer.pricing.output))")
                    .font(.callout.monospacedDigit())
                    .help("Per million tokens in / out")
                Text("\(Format.tokens(offer.contextTokens)) context").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// Renaming an API model; there is nothing else to edit.
struct RenameAPIModelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: PodlightModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(item.name)").font(.title2.weight(.semibold))
            TextField("Name for agents", text: $name).textFieldStyle(.roundedBorder)
            Text("Agents use this name in the model field. Change it in their configuration too.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var renamed = item
                    renamed.name = name
                    Task { if await model.save(renamed) { dismiss() } }
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(!PodlightModel.isValidName(name) || model.models(in: model.source(of: item.id)).contains { $0.name == name && $0.id != item.id })
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = item.name }
    }
}

// MARK: Balance

/// The Venice balance and what Venice models cost today and this month.
struct VeniceCostsSection: View {
    @Environment(AppModel.self) private var model
    let source: Source

    var body: some View {
        let apiModels = model.models(in: source).filter { !$0.isPod }
        if model.hasVeniceKey(in: source) || !apiModels.isEmpty {
            Section {
                if let account = model.veniceAccount(in: source) {
                    LabeledContent("Balance", value: VeniceText.balances(account))
                    if let next = account.nextEpochBegins, account.amount("DIEM").map({ $0 > 0 }) ?? false {
                        LabeledContent("DIEM renews", value: Format.time(next))
                    }
                } else if model.hasVeniceKey(in: source) {
                    LabeledContent("Balance", value: String(localized: "Not read yet"))
                }
                LabeledContent("Today", value: Format.smallMoney(model.apiSpend(in: source, period: AppModel.todayKey)))
                LabeledContent("This month", value: Format.smallMoney(model.apiSpend(in: source, period: AppModel.monthKey)))
                ForEach(apiModels) { item in
                    let month = model.apiTotals(item.id, period: AppModel.monthKey)
                    LabeledContent(item.name, value: month.requests == 0 ? String(localized: "No requests this month")
                                   : String(localized: "\(Format.smallMoney(month.usd)) · \(Format.tokenCount(month.promptTokens + month.completionTokens)) tokens"))
                }
                if source == .local, let checked = model.veniceAccountCheckedAt {
                    Text("Balance as of \(Format.time(checked)). Costs are counted from each answer as it arrives.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Venice")
            } footer: {
                Text("Venice uses DIEM first, then plan credits, then USD. The spending limits count Venice and pods together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
