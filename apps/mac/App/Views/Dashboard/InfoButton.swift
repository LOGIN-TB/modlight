import SwiftUI

/// A small ⓘ that shows a paragraph in a popover: the explanation a long section footer used to
/// carry, out of the way until someone asks.
///
///     CardSection("Spending limits") { ... } accessory: { InfoButton("At a limit, Podlight stops ...") }
struct InfoButton: View {
    private let text: Text
    @State private var shown = false
    @ScaledMetric private var width: CGFloat = 300

    init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S) {
        self.text = Text(text)
    }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(Text("More information"))
        .accessibilityLabel(Text("More information"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            text
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .leading)
                .padding(14)
                .textSelection(.enabled)
        }
    }
}

#Preview("Info button", traits: .fixedLayout(width: 360, height: 120)) {
    HStack {
        Text(verbatim: "Spending limits").font(.headline)
        InfoButton(String("At a limit, Podlight stops this Mac's pods, does not start or wake them again, and refuses requests to Venice models until the next day or month."))
    }
    .padding()
}

#Preview("Info button · dark", traits: .fixedLayout(width: 360, height: 120)) {
    HStack {
        Text(verbatim: "Last 30 days").font(.headline)
        InfoButton(String("These figures are Podlight's own count."))
    }
    .padding()
    .preferredColorScheme(.dark)
}
