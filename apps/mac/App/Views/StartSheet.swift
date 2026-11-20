import PodlightEngine
import SwiftUI

/// Every start has an end. The sheet asks for it and shows what the run will cost.
struct StartSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let model_: PodlightModel

    init(model: PodlightModel) { model_ = model }

    enum Length: Hashable { case hours(Int), until }
    @State private var length: Length = .hours(2)
    @State private var untilTime = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now
    @State private var starting = false

    private var end: Date {
        switch length {
        case .hours(let h): return Date.now.addingTimeInterval(TimeInterval(h) * 3600)
        case .until:
            return untilTime > .now ? untilTime : untilTime.addingTimeInterval(86_400)
        }
    }

    private var price: Double? {
        model.state.run(model_.id).pricePerHour ?? model_.expectedPricePerHour
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Start \(model_.name)").font(.title2.weight(.semibold))
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
                if let price {
                    LabeledContent("Costs at most", value: Format.money(GPUSuggestion.cost(pricePerHour: price, from: .now, until: end)))
                }
            }
            .formStyle(.grouped)
            Text("It stops earlier when no requests come in for \(model_.schedule.idleStopMinutes) minutes, and by itself if this Mac sleeps or Podlight quits for more than \(model.state.settings.heartbeatMinutes) minutes. You can extend it while it runs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    starting = true
                    Task {
                        await model.start(model_, until: end)
                        starting = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(starting)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
