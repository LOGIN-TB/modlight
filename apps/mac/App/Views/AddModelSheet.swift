import PodlightEngine
import SwiftUI

/// Adding a model in four short steps: find it, check it, choose context and card, name it.
/// Editing an existing model opens at the third step.
struct AddModelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let editing: PodlightModel?
    /// Where the model is set up: this Mac or a server. Fixed for an existing model.
    private let target: Source

    enum Step: Int { case find, check, card, finish }
    @State private var step: Step = .find

    // Find
    @State private var query = ""
    @State private var hits: [ModelHit] = []
    @State private var searching = false
    @State private var searchError: String?

    // Check
    @State private var info: ModelInfo?
    @State private var checking = false
    @State private var variants: [ModelHit] = []

    // Card
    @State private var goal: SuggestionGoal = .balanced
    @State private var catalog: [RunpodGPUType] = []
    @State private var options: [GPUOption] = []
    @State private var chosen: GPUOption.ID?
    /// Set only when the user clicks a row: until then the selection follows the suggestion.
    @State private var userPicked = false
    @State private var selectionNote: String?
    @State private var region: HostingRegion = .anywhere
    @State private var secureOnly = false
    @State private var hostingLoaded = false
    @State private var loadingCatalog = false
    @State private var catalogError: String?

    // Context and finish
    @State private var name = ""
    @State private var context = GPUSuggestion.defaultContext
    @State private var idleMinutes = 30
    @State private var keepDisk = false

    init(editing: PodlightModel? = nil, target: Source = .local) {
        self.editing = editing
        self.target = target
        guard let editing else { return }
        _step = State(initialValue: .card)
        _info = State(initialValue: editing.info)
        _name = State(initialValue: editing.name)
        _context = State(initialValue: editing.contextTokens)
        _idleMinutes = State(initialValue: editing.schedule.idleStopMinutes)
        _keepDisk = State(initialValue: editing.keepDisk)
        _goal = State(initialValue: editing.goal)
        if let preferred = editing.preferredGPU {
            _chosen = State(initialValue: "\(preferred.cloud.rawValue)|\(preferred.gpuId)|\(preferred.count)")
            _userPicked = State(initialValue: true)
        }
    }

    private var hosting: HostingPolicy { HostingPolicy(region: region, secureOnly: secureOnly) }

    /// The table's selection; a click there counts as the user's own choice.
    private var tableSelection: Binding<GPUOption.ID?> {
        Binding(get: { chosen }, set: { value in
            chosen = value
            userPicked = value != nil
            selectionNote = nil
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .find: findStep
                case .check: checkStep
                case .card: cardStep
                case .finish: finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            Divider()
            footer
        }
        .frame(width: 760, height: 600)
        .task {
            if !hostingLoaded {
                let fallback = model.defaultHosting(in: target)
                let start = editing?.hosting(default: fallback) ?? fallback
                region = start.region
                secureOnly = start.secureOnly
                hostingLoaded = true
            }
            if editing != nil && catalog.isEmpty { await loadCatalog() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(editing == nil ? "Add Model" : "Edit \(editing?.name ?? "")").font(.title2.weight(.semibold))
                if case .server = target {
                    Label("On \(model.name(of: target))", systemImage: "server.rack").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(stepTitle).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var stepTitle: String {
        switch step {
        case .find: String(localized: "Step 1 of 4: Find")
        case .check: String(localized: "Step 2 of 4: Check")
        case .card: String(localized: "Step 3 of 4: Location, context and GPU")
        case .finish: String(localized: "Step 4 of 4: Name and disk")
        }
    }

    private var footer: some View {
        HStack {
            if step != .find && !(editing != nil && step == .card) {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .find }
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            switch step {
            case .find:
                EmptyView()
            case .check:
                Button("Choose Location and GPU") {
                    context = min(GPUSuggestion.defaultContext, info?.nativeContextTokens ?? GPUSuggestion.defaultContext)
                    step = .card
                    Task { await loadCatalog() }
                }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(!(info.map(canRun) ?? false))
            case .card:
                Button("Continue") { prepareFinish(); step = .finish }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            case .finish:
                if editing == nil {
                    Button("Add Only") { Task { await save(start: false) } }
                        .disabled(!nameIsValid)
                    Button("Add and Start…") { Task { await save(start: true) } }
                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                        .disabled(!nameIsValid)
                } else {
                    Button("Save") { Task { await save(start: false) } }
                        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                        .disabled(!nameIsValid)
                }
            }
        }
        .padding(16)
    }

    // MARK: Step 1

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Hugging Face, or paste a link to a model page.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("e.g. Qwen3 Coder, or https://huggingface.co/…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await searchOrOpen() } }
                Button("Search") { Task { await searchOrOpen() } }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if searching { ProgressView().controlSize(.small) }
            if let searchError { Label(searchError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            List(hits) { hit in
                Button { Task { await check(hit.repoId) } } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(hit.repoId).font(.body.weight(.medium))
                            Text("\(hit.downloads.formatted()) downloads").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if hit.gated { Image(systemName: "lock").help("Needs a Hugging Face token") }
                        FormatBadge(format: hit.format)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if hits.isEmpty && !searching {
                    VStack(spacing: 8) {
                        Text("Tip: 4-bit builds (AWQ, GPTQ, NVFP4, or GGUF Q4) need half the memory and run faster.")
                        Link("Browse popular models on Hugging Face", destination: Links.huggingFace)
                    }
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
    }

    private func searchOrOpen() async {
        searchError = nil
        if let repo = HuggingFaceClient.repoId(fromUserInput: query), query.contains("/") {
            await check(repo)
            return
        }
        searching = true
        defer { searching = false }
        do {
            hits = try await model.huggingFace.search(query)
            if hits.isEmpty { searchError = String(localized: "Nothing found. Try a shorter name.") }
        } catch {
            searchError = String(localized: "Hugging Face could not be reached.")
        }
    }

    // MARK: Step 2

    private func check(_ repo: String) async {
        step = .check
        checking = true
        info = nil
        variants = []
        defer { checking = false }
        do {
            let result = try await model.huggingFace.info(repo)
            info = result
            if !result.format.isFourBit && result.format != .gguf { variants = await model.huggingFace.fourBitVariants(of: repo) }
        } catch {
            info = ModelInfo(repoId: repo, access: .unreachable, gated: false, format: .unknown, weightBytes: 0,
                             nativeContextTokens: nil, license: nil, toolCallParser: nil, reasoningParser: nil)
        }
    }

    private func canRun(_ info: ModelInfo) -> Bool {
        info.access == .open && info.format.runsOnAnEngine && info.weightBytes > 0 && (info.format != .gguf || info.quant != nil)
    }

    private var checkStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if checking {
                    ProgressView("Reading the model from Hugging Face…")
                } else if let info {
                    Text(info.repoId).font(.title3.weight(.semibold)).textSelection(.enabled)
                    problems(info)
                    if info.access == .open {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow {
                                Text("Format").foregroundStyle(.secondary)
                                HStack { FormatBadge(format: info.format); if info.format == .gguf { Text("runs with llama.cpp").foregroundStyle(.secondary) } }
                            }
                            if let quants = info.quants, !quants.isEmpty {
                                GridRow {
                                    Text("Quantisation").foregroundStyle(.secondary)
                                    Picker("Quantisation", selection: Binding(get: { info.quant ?? "" }, set: { self.info = info.choosing(quant: $0) })) {
                                        ForEach(quants) { q in
                                            Text("\(q.name) · \(Format.gigabytes(q.bytes))\(q.name == GGUF.recommended(quants)?.name ? String(localized: " · suggested") : "")").tag(q.name)
                                        }
                                    }
                                    .labelsHidden()
                                    .fixedSize()
                                }
                                if let q = quants.first(where: { $0.name == info.quant }) {
                                    GridRow {
                                        Text("")
                                        Text(q.isVeryLow ? "Below 4 bits models get noticeably worse at code and tool calls."
                                             : q.isHigh ? "Close to the original, but about twice the memory of 4 bits."
                                             : "4 bits: half the memory of 8 bits, with little loss. A good default.")
                                            .font(.caption).foregroundStyle(q.isVeryLow ? Color.orange : Color.secondary)
                                    }
                                }
                            }
                            GridRow { Text("Download").foregroundStyle(.secondary); Text(Format.gigabytes(info.weightBytes)) }
                            if let native = info.nativeContextTokens {
                                GridRow { Text("Longest context").foregroundStyle(.secondary); Text("\(Format.tokens(native)) tokens") }
                            }
                            GridRow {
                                Text("Tool calls").foregroundStyle(.secondary)
                                Text(info.toolCallParser != nil ? "Yes, for coding agents" : "No: coding agents will not work well")
                            }
                            if let kv = info.kvProfile {
                                GridRow {
                                    Text("Memory per token").foregroundStyle(.secondary)
                                    Text("\(Int((kv.bytesPerToken / 1024).rounded())) KiB, read from the model")
                                }
                            }
                            if let license = info.license {
                                GridRow { Text("Licence").foregroundStyle(.secondary); Text(license) }
                            }
                        }
                    }
                    if !variants.isEmpty {
                        Divider()
                        Text("Smaller 4-bit builds of this model").font(.headline)
                        Text("Half the memory, more room for context, and usually faster: measured twice as fast on the same card.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(variants.prefix(4)) { v in
                            HStack {
                                Text(v.repoId)
                                FormatBadge(format: v.format)
                                Spacer()
                                Button("Use This Instead") { Task { await check(v.repoId) } }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func problems(_ info: ModelInfo) -> some View {
        switch info.access {
        case .needsToken:
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This model needs a Hugging Face token, and access approved on its page.")
                    HStack {
                        Link("Open the model page", destination: URL(string: "https://huggingface.co/\(info.repoId)")!)
                        Text("·")
                        SettingsLink { Text("Add a token in Settings") }.buttonStyle(.link)
                    }
                }
            } icon: { Image(systemName: "lock") }
        case .missing:
            Label("There is no model with this name on Hugging Face.", systemImage: "questionmark.circle")
        case .unreachable:
            Label("Hugging Face could not be reached. Check the connection and try again.", systemImage: "wifi.exclamationmark")
        case .open:
            if info.format == .gguf && (info.quants ?? []).isEmpty {
                Label("No GGUF files found in this repository.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if info.format == .mlx {
                Label("MLX builds run on Apple chips only, not on RunPod's NVIDIA cards.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if info.weightBytes == 0 {
                Label("No weight files found in this repository.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }

    // MARK: Step 3

    private func loadCatalog() async {
        guard let info else { return }
        loadingCatalog = true
        catalogError = nil
        defer { loadingCatalog = false }
        do {
            catalog = try await model.gpuCatalog(for: target)
            recompute(info)
        } catch {
            catalogError = Describe.error(error)
        }
    }

    private func recompute(_ info: ModelInfo) {
        let previous = selectedOption?.choice ?? options.first { $0.id == chosen }?.choice ?? choice(from: chosen)
        options = GPUSuggestion.options(for: info, catalog: catalog, goal: goal, context: context, hosting: hosting)
        let result = GPUSuggestion.reselect(previous: previous, userPicked: userPicked, options: options)
        chosen = result.selection.map { "\($0.cloud.rawValue)|\($0.gpuId)|\($0.count)" }
        switch result.change {
        case .unchanged:
            selectionNote = nil
        case .moreCards(_, let to):
            selectionNote = String(localized: "Your card needs \(to.count) of itself for \(Format.tokens(context)) tokens; the selection follows.")
        case .replaced:
            userPicked = false
            selectionNote = String(localized: "Your card no longer holds \(Format.tokens(context)) tokens here, so the suggestion is selected.")
        }
    }

    /// Rebuilds a choice from a row id (`cloud|gpu|count`), for a selection whose row is gone.
    private func choice(from id: GPUOption.ID?) -> GPUChoice? {
        guard let parts = id?.split(separator: "|", omittingEmptySubsequences: false), parts.count == 3,
              let cloud = RunpodCloud(rawValue: String(parts[0])), let count = Int(parts[2]) else { return nil }
        return GPUChoice(gpuId: String(parts[1]), cloud: cloud, count: count)
    }

    /// Card memory the model needs for the chosen context, so the effect of the context is visible.
    private var requiredMemoryText: String? {
        guard let info else { return nil }
        let gib = Capacity.requiredGiB(weightsGiB: info.weightsGiB, contextTokens: min(context, info.nativeContextTokens ?? context),
                                       kvBytesPerToken: info.kvBytesPerToken, engine: info.engine)
        return String(localized: "For \(Format.tokens(context)) tokens the model needs about \(Int(gib.rounded(.up))) GB of card memory.")
    }

    private var cardStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("Where pods may run", selection: $region) {
                    Text("Anywhere").tag(HostingRegion.anywhere)
                    Text("EU only").tag(HostingRegion.eu)
                    Text("EU and EEA (incl. Iceland, Norway)").tag(HostingRegion.euEEA)
                }
                Toggle("Secure Cloud only", isOn: Binding(get: { secureOnly || region != .anywhere }, set: { secureOnly = $0 }))
                    .disabled(region != .anywhere)
                    .help("Certified data centers instead of community hosts. With a region, Podlight always uses Secure Cloud, because community hosts report no location.")
                Picker("Context", selection: $context) {
                    ForEach(GPUSuggestion.contextSteps(upTo: info?.nativeContextTokens), id: \.self) {
                        Text("\(Format.tokens($0)) tokens").tag($0)
                    }
                }
                Picker("What matters most?", selection: $goal) {
                    Text("Economical").tag(SuggestionGoal.economical)
                    Text("Balanced").tag(SuggestionGoal.balanced)
                    Text("Fast").tag(SuggestionGoal.fast)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .frame(height: 196)
            .scrollDisabled(true)
            .onChange(of: goal) { if let info { recompute(info) } }
            .onChange(of: context) { if let info { recompute(info) } }
            .onChange(of: region) { if let info { recompute(info) } }
            .onChange(of: secureOnly) { if let info { recompute(info) } }

            HStack(alignment: .firstTextBaseline) {
                if let requiredMemoryText { Text(requiredMemoryText) }
                Spacer()
                if !loadingCatalog { Text("\(options.count) options").foregroundStyle(.secondary) }
            }
            .font(.callout)
            if let selectionNote {
                Label(selectionNote, systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(.orange)
            }

            if loadingCatalog { ProgressView("Asking RunPod which cards are free…") }
            if let catalogError { Label(catalogError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if !loadingCatalog && options.isEmpty && catalogError == nil, let info {
                let feasible = GPUSuggestion.largestFeasibleContext(for: info, catalog: catalog, hosting: hosting)
                Label(feasible > 0
                      ? String(localized: "No free card combination holds \(Format.tokens(context)) tokens right now. At most \(Format.tokens(feasible)) tokens are possible.")
                      : String(localized: "No card at RunPod can hold this model right now. Try a 4-bit build, or allow more regions above."),
                      systemImage: "exclamationmark.triangle")
            }
            Table(options, selection: tableSelection) {
                TableColumn("GPU") { o in
                    HStack {
                        Text(o.label)
                        if o.id == options.first?.id { Text("Suggested").font(.caption).padding(.horizontal, 5).background(.tint.opacity(0.15), in: .capsule) }
                    }
                }
                TableColumn("Memory") { o in Text("\(o.memoryGiB * o.choice.count) GB") }.width(70)
                TableColumn("Cloud") { o in Text(o.choice.cloud == .secure ? "Secure" : "Community") }.width(84)
                TableColumn("Price") { o in Text(Format.perHour(o.pricePerHour)) }.width(80)
                TableColumn("Speed (est.)") { o in Text(Format.speed(o.estimatedTokensPerSecond)) }.width(100)
                TableColumn("Where") { o in Text(o.dataCenters.isEmpty ? "–" : o.dataCenters.prefix(2).joined(separator: ", ")) }.width(110)
            }
            Text("Longer contexts need more memory, so they may need a larger card or several. Speeds are estimates from memory bandwidth. If the chosen card is taken when you start, Podlight tries the next ones in this list.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 4

    private var selectedOption: GPUOption? { options.first { $0.id == chosen } }


    private func prepareFinish() {
        guard let info else { return }
        if name.isEmpty { name = PodlightModel.suggestedName(for: info.repoId) }
    }

    private var nameIsValid: Bool {
        PodlightModel.isValidName(name) && !model.models(in: target).contains { $0.name == name && $0.id != editing?.id }
    }

    /// The model as it would be saved, for cost previews.
    private var draft: PodlightModel? {
        guard let info, let option = selectedOption else { return nil }
        var schedule = editing?.schedule ?? PodlightModel.defaultSchedule
        schedule.idleStopMinutes = idleMinutes
        var item = PodlightModel(id: editing?.id ?? UUID(), name: name, repoId: info.repoId, format: info.format,
                                 weightBytes: info.weightBytes, nativeContextTokens: info.nativeContextTokens,
                                 toolCallParser: info.toolCallParser, reasoningParser: info.reasoningParser,
                                 contextTokens: option.contextTokens, goal: goal, preferredGPU: option.choice,
                                 schedule: schedule, createdAt: editing?.createdAt ?? Date(), kvProfile: info.kvProfile,
                                 keepDisk: keepDisk, hosting: hosting, preferredGPUName: option.label, quant: info.quant)
        item.expectedPricePerHour = option.pricePerHour
        return item
    }

    private var finishStep: some View {
        Form {
            Section {
                TextField("Name for agents", text: $name)
                    .disabled(editing != nil)
                if !name.isEmpty && !nameIsValid {
                    Text(model.models(in: target).contains { $0.name == name }
                         ? "Another model already uses this name."
                         : "Use lowercase letters, digits, dots and dashes.")
                        .font(.caption).foregroundStyle(.red)
                }
                Picker("Stop when idle for", selection: $idleMinutes) {
                    ForEach([10, 15, 30, 60, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            }
            Section {
                Toggle("Keep model on disk", isOn: $keepDisk)
                if let draft {
                    Text(keepDisk
                         ? "The next start takes about a minute instead of 10–25. The disk (\(PodPlan.persistentGB(for: draft)) GB) costs about \(Format.money(StoragePricing.stoppedPerMonth(volumeGB: PodPlan.persistentGB(for: draft)))) a month while the model is stopped. Podlight deletes it after \(model.deleteStoppedAfterDays(in: target)) days without use."
                         : "Nothing is billed while the model is stopped. Each start downloads the model again, which takes 10–25 minutes.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Disk")
            }
            if let draft, let option = selectedOption {
                Section("Summary") {
                    LabeledContent("GPU", value: option.label)
                    LabeledContent("Where", value: Describe.hosting(hosting))
                    LabeledContent("Context", value: String(localized: "\(Format.tokens(option.contextTokens)) tokens"))
                    LabeledContent("Price while running", value: Describe.price(gpu: option.pricePerHour, storage: PodPlan.storagePerHour(for: draft)))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save(start: Bool) async {
        guard let item = draft else { return }
        guard await model.save(item, to: editing == nil ? target : nil) else { return }
        // The start sheet opens once this one is gone; two sheets cannot share a window.
        if start { model.startAfterAdding = item.id }
        dismiss()
    }
}

struct FormatBadge: View {
    let format: WeightFormat

    var body: some View {
        Text(format.rawValue.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(format.isFourBit ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15), in: .capsule)
            .accessibilityLabel(Text("Format \(format.rawValue)"))
    }
}
