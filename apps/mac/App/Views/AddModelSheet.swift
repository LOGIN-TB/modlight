import PodlightEngine
import SwiftUI

/// Adding a model in four short steps: find it, check it, choose a card, name it.
struct AddModelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
    @State private var loadingCatalog = false
    @State private var catalogError: String?

    // Finish
    @State private var name = ""
    @State private var context = 32_768
    @State private var idleMinutes = 30

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
        .frame(width: 720, height: 560)
    }

    private var header: some View {
        HStack {
            Text("Add Model").font(.title2.weight(.semibold))
            Spacer()
            Text(stepTitle).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var stepTitle: String {
        switch step {
        case .find: String(localized: "Step 1 of 4: Find")
        case .check: String(localized: "Step 2 of 4: Check")
        case .card: String(localized: "Step 3 of 4: GPU")
        case .finish: String(localized: "Step 4 of 4: Name")
        }
    }

    private var footer: some View {
        HStack {
            if step != .find { Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .find } }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            switch step {
            case .find:
                EmptyView()
            case .check:
                Button("Choose GPU") { step = .card; Task { await loadCatalog() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!(info.map(canRun) ?? false))
            case .card:
                Button("Continue") { prepareFinish(); step = .finish }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            case .finish:
                Button("Add Model") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!nameIsValid)
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
                        Text("Tip: 4-bit builds (AWQ, GPTQ, INT4) need half the memory and run faster.")
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
            if !result.format.isFourBit { variants = await model.huggingFace.fourBitVariants(of: repo) }
        } catch {
            info = ModelInfo(repoId: repo, access: .unreachable, gated: false, format: .unknown, weightBytes: 0,
                             nativeContextTokens: nil, license: nil, toolCallParser: nil, reasoningParser: nil)
        }
    }

    private func canRun(_ info: ModelInfo) -> Bool {
        info.access == .open && info.format.runsOnVLLM && info.weightBytes > 0
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
                            GridRow { Text("Format").foregroundStyle(.secondary); FormatBadge(format: info.format) }
                            GridRow { Text("Download").foregroundStyle(.secondary); Text(Format.gigabytes(info.weightBytes)) }
                            if let native = info.nativeContextTokens {
                                GridRow { Text("Longest context").foregroundStyle(.secondary); Text("\(Format.tokens(native)) tokens") }
                            }
                            GridRow {
                                Text("Tool calls").foregroundStyle(.secondary)
                                Text(info.toolCallParser != nil ? "Yes, for coding agents" : "No: coding agents will not work well")
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
            if info.format == .gguf {
                Label("This is a GGUF build. Podlight 0.1 runs vLLM, which needs safetensors weights. Pick a 4-bit AWQ or GPTQ build instead.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
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
        guard let info, let client = model.runpod() else { catalogError = Describe.error(PodlightError.missingRunpodKey); return }
        loadingCatalog = true
        catalogError = nil
        defer { loadingCatalog = false }
        do {
            catalog = try await client.gpuCatalog()
            recompute(info)
        } catch {
            catalogError = Describe.error(error)
        }
    }

    private func recompute(_ info: ModelInfo) {
        options = GPUSuggestion.options(for: info, catalog: catalog, goal: goal)
        chosen = options.first?.id
    }

    private var cardStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("What matters most?", selection: $goal) {
                Text("Economical").tag(SuggestionGoal.economical)
                Text("Balanced").tag(SuggestionGoal.balanced)
                Text("Fast").tag(SuggestionGoal.fast)
            }
            .pickerStyle(.segmented)
            .onChange(of: goal) { if let info { recompute(info) } }
            if loadingCatalog { ProgressView("Asking RunPod which cards are free…") }
            if let catalogError { Label(catalogError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if !loadingCatalog && options.isEmpty && catalogError == nil {
                Label("No card at RunPod can hold this model right now. Try a 4-bit build.", systemImage: "exclamationmark.triangle")
            }
            Table(options, selection: $chosen) {
                TableColumn("GPU") { o in
                    HStack {
                        Text(o.displayName)
                        if o.id == options.first?.id { Text("Suggested").font(.caption).padding(.horizontal, 5).background(.tint.opacity(0.15), in: .capsule) }
                    }
                }
                TableColumn("Memory") { o in Text("\(o.memoryGiB) GB") }.width(70)
                TableColumn("Cloud") { o in Text(o.choice.cloud == .secure ? "Secure" : "Community") }.width(90)
                TableColumn("Price") { o in Text(Format.perHour(o.pricePerHour)) }.width(80)
                TableColumn("Speed (est.)") { o in Text(Format.speed(o.estimatedTokensPerSecond)) }.width(110)
                TableColumn("Context") { o in Text(Format.tokens(o.contextTokens)) }.width(70)
            }
            Text("Speeds are estimates from memory bandwidth. If the chosen card is taken when you start, Podlight tries the next ones in this list.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Step 4

    private var selectedOption: GPUOption? { options.first { $0.id == chosen } }

    private func prepareFinish() {
        guard let info, let option = selectedOption else { return }
        if name.isEmpty { name = PodlightModel.suggestedName(for: info.repoId) }
        context = option.contextTokens
    }

    private var contextChoices: [Int] {
        let ceiling = selectedOption?.contextTokens ?? 32_768
        let steps = [8_192, 16_384, 32_768, 65_536, 131_072, 262_144].filter { $0 <= ceiling }
        return steps.contains(ceiling) ? steps : steps + [ceiling]
    }

    private var nameIsValid: Bool {
        PodlightModel.isValidName(name) && !model.state.models.contains { $0.name == name }
    }

    private var finishStep: some View {
        Form {
            TextField("Name for agents", text: $name)
            if !name.isEmpty && !nameIsValid {
                Text(model.state.models.contains { $0.name == name }
                     ? "Another model already uses this name."
                     : "Use lowercase letters, digits, dots and dashes.")
                    .font(.caption).foregroundStyle(.red)
            }
            Picker("Context", selection: $context) {
                ForEach(contextChoices, id: \.self) { Text("\(Format.tokens($0)) tokens").tag($0) }
            }
            Picker("Stop when idle for", selection: $idleMinutes) {
                ForEach([10, 15, 30, 60, 120], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            if let option = selectedOption {
                LabeledContent("GPU", value: "\(option.displayName) · \(Format.perHour(option.pricePerHour))")
            }
        }
        .formStyle(.grouped)
    }

    private func save() async {
        guard let info, let option = selectedOption else { return }
        var schedule = PodlightModel.defaultSchedule
        schedule.idleStopMinutes = idleMinutes
        var item = PodlightModel(name: name, repoId: info.repoId, format: info.format, weightBytes: info.weightBytes,
                                 nativeContextTokens: info.nativeContextTokens, toolCallParser: info.toolCallParser,
                                 reasoningParser: info.reasoningParser, contextTokens: context, goal: goal,
                                 preferredGPU: option.choice, schedule: schedule)
        item.expectedPricePerHour = option.pricePerHour
        await model.save(item)
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
