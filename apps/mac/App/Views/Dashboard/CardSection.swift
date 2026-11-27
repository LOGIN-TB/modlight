import SwiftUI

/// A titled group of content on a dashboard page inside a `ScrollView`: the title on the left, an
/// optional accessory on the right (an `InfoButton`, a link, a small menu), the content beneath on
/// a calm rounded surface. Content, not navigation, so no glass.
///
///     CardSection("Spending limits") {
///         MeterRow("Today", value: 6.12, limit: 20)
///     } accessory: {
///         InfoButton("At a limit, Modlight stops ...")
///     }
struct CardSection<Content: View, Accessory: View>: View {
    private let title: Text
    private let content: Content
    private let accessory: Accessory
    @ScaledMetric private var padding: CGFloat = 14

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = Text(title)
        self.content = content()
        self.accessory = accessory()
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
        self.title = Text(title)
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                title.font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

extension CardSection where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }
}

private struct SampleDashboard: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CardSection(String("Now")) {
                    MetricGrid {
                        MetricTile(.init(id: "pods", title: "Running pods", value: "2", caption: "1 waiting for a card"))
                        MetricTile(.init(id: "rate", title: "Cost per hour", value: "$1.84/h", caption: "GPU and storage",
                                         sparkline: [1.2, 1.2, 1.84, 1.84, 1.84]), tint: .green)
                        MetricTile(.init(id: "venice", title: "Venice today", value: "$0.42", caption: "312 requests"), tint: .blue)
                    }
                } accessory: {
                    StatusPill(.active(2), tint: .green)
                }
                CardSection(String("Spending limits")) {
                    MeterRow(String("Today"), value: 16.35, limit: 20, segments: [
                        .init("Pods", value: 13.10, color: .green), .init("Venice", value: 3.25, color: .blue)])
                    MeterRow(String("This month"), value: 88.40, limit: 150)
                } accessory: {
                    InfoButton(String("At a limit, Modlight stops this Mac's pods and refuses requests to Venice models until the next day or month."))
                }
                CardSection(String("Tokens today")) {
                    TokenMixBar(newInput: 182_400, cachedInput: 640_000, output: 41_300,
                                newInputUsd: 0.0912, cachedInputUsd: 0.032, outputUsd: 0.0826, tint: .blue)
                }
            }
            .padding(20)
        }
    }
}

#Preview("Cards", traits: .fixedLayout(width: 560, height: 640)) {
    SampleDashboard()
}

#Preview("Cards · dark", traits: .fixedLayout(width: 560, height: 640)) {
    SampleDashboard().preferredColorScheme(.dark)
}
