import ModlightEngine
import SwiftUI

/// Every start has an end. The sheet asks for it and shows what the run will cost.
struct StartSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let model_: ModlightModel

    init(model: ModlightModel, question: PriceQuestion? = nil) {
        model_ = model
        _question = State(initialValue: question)
        _pick = State(initialValue: question?.pricier.first)
    }

    enum Length: Hashable { case hours(Int), until }
    @State private var length: Length = .hours(2)
    @State private var untilTime = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now
    @State private var starting = false
    /// Set when the chosen card was taken and only pricier ones are free.
    @State private var question: PriceQuestion?
    @State private var pick: PricedChoice?

    private var end: Date {
        switch length {
        case .hours(let h): return Date.now.addingTimeInterval(TimeInterval(h) * 3600)
        case .until:
            return untilTime > .now ? untilTime : untilTime.addingTimeInterval(86_400)
        }
    }


    private var source: Source { model.source(of: model_.id) }

    private var stopsEarlier: String {
        let minutes = model.heartbeatMinutes(in: source)
        if case .server = source {
            return String(localized: "It stops earlier when no requests come in for \(model_.schedule.idleStopMinutes) minutes, and by itself if the server \(model.name(of: source)) is unreachable for more than \(minutes) minutes. It keeps running when this Mac sleeps or Modlight quits. You can extend it while it runs.")
        }
        return String(localized: "It stops earlier when no requests come in for \(model_.schedule.idleStopMinutes) minutes, and by itself if this Mac sleeps or Modlight quits for more than \(minutes) minutes. You can extend it while it runs.")
    }

    var body: some View {
        if let question {
            priceBody(question)
        } else {
            startBody
        }
    }

    /// The chosen card is taken: nothing is booked until the user picks a pricier card.
    private func priceBody(_ q: PriceQuestion) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(q.wanted?.name ?? String(localized: "The chosen card")) Is Taken").font(.title2.weight(.semibold))
            Text(q.wanted.map { String(localized: "The card you chose costs \(Format.perHour($0.pricePerHour)). Free right now are only cards that cost more than \(Format.perHour(q.ceiling)), the most a replacement may cost without asking. Modlight has booked nothing.") }
                 ?? String(localized: "Free right now are only cards that cost more than \(Format.perHour(q.ceiling)). Modlight has booked nothing."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Start instead on", selection: $pick) {
                    ForEach(q.pricier, id: \.self) { option in
                        Text([option.name, Format.perHour(option.pricePerHour), q.extra(option)].compactMap { $0 }.joined(separator: " · "))
                            .tag(Optional(option))
                    }
                }
                .pickerStyle(.radioGroup)
                if let pick {
                    LabeledContent("Costs at most", value: Format.money(pick.pricePerHour * max(0, end.timeIntervalSinceNow) / 3600))
                }
            }
            .formStyle(.grouped)
            if let until = q.waitsUntil {
                Text("Or wait: Modlight tries every 30 seconds until \(Format.time(until)) for a card up to \(Format.perHour(q.ceiling)) and then starts by itself. The model's page shows the waiting; Stop Waiting ends it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if q.waitsUntil != nil {
                    Button("Don't Wait") {
                        Task { await model.stop(model_); finish() }
                    }
                }
                Spacer()
                Button(q.waitsUntil != nil ? "Keep Waiting" : "Cancel") { finish() }
                    .keyboardShortcut(.cancelAction)
                Button(pick.map { String(localized: "Start on \($0.name)") } ?? String(localized: "Start")) {
                    guard let pick else { return }
                    starting = true
                    Task {
                        let again = await model.start(model_, until: end, newPod: model.startingOnNewCard, maxPricePerHour: pick.pricePerHour)
                        starting = false
                        if let again { question = again; self.pick = again.pricier.first } else { finish() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(starting || pick == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func finish() {
        model.startingOnNewCard = false
        dismiss()
    }

    private var startBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.startingOnNewCard ? "Start \(model_.name) on a New Card" : "Start \(model_.name)").font(.title2.weight(.semibold))
            if model.startingOnNewCard {
                Text("A new pod downloads the model again, which takes 10–25 minutes. The old pod and its disk stay until the new one answers; if the new one fails, the old one is kept.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if case .server = source {
                Label("On \(model.name(of: source))", systemImage: "server.rack").foregroundStyle(.secondary)
            }
            Form {
                Picker("Runs until", selection: $length) {
                    Text("1 hour from now").tag(Length.hours(1))
                    Text("2 hours from now").tag(Length.hours(2))
                    Text("4 hours from now").tag(Length.hours(4))
                    Text("8 hours from now").tag(Length.hours(8))
                    Text("A time of day…").tag(Length.until)
                }
                .pickerStyle(.radioGroup)
                if length == .until {
                    DatePicker("Until", selection: $untilTime, displayedComponents: .hourAndMinute)
                }
                LabeledContent("Stops at", value: Format.time(end))
                if let cost = model.maximumCost(of: model_, until: end) {
                    LabeledContent("Costs at most", value: Format.money(cost))
                }
                if let gb = model.keptDiskGB(model_) {
                    LabeledContent("Afterwards, while stopped", value: String(localized: "\(Format.keptDisk(gb: gb)) for the disk"))
                } else {
                    LabeledContent("Afterwards", value: String(localized: "the pod is deleted, nothing billed"))
                }
            }
            .formStyle(.grouped)
            Text(stopsEarlier)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.startingOnNewCard = false; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    starting = true
                    Task {
                        let asked = await model.start(model_, until: end, newPod: model.startingOnNewCard)
                        starting = false
                        if let asked {
                            question = asked
                            pick = asked.pricier.first
                        } else {
                            finish()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(starting)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
