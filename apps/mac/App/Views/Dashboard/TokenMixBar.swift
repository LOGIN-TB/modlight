import SwiftUI

/// Where the tokens went: new input, input read from the provider's cache, and output, as one
/// stacked bar with a legend of tokens and dollars per part, and optionally a hint beneath
/// ("Most input is new: ..."). The bar is proportional to tokens; the legend says what they cost.
///
///     TokenMixBar(newInput: 182_000, cachedInput: 640_000, output: 41_000,
///                 newInputUsd: 0.091, cachedInputUsd: 0.032, outputUsd: 0.082,
///                 hint: "Most of the prompt comes from the cache.")
struct TokenMixBar: View {
    private struct Part: Identifiable {
        let id: String
        let label: String
        let tokens: Int
        let usd: Double?
        let color: Color
    }

    private let parts: [Part]
    private let hint: String?
    @ScaledMetric private var barHeight: CGFloat = 10

    /// - Parameters:
    ///   - newInput, cachedInput, output: token counts.
    ///   - newInputUsd, cachedInputUsd, outputUsd: what each part cost; nil leaves the dollars out.
    ///   - hint: one sentence of advice under the legend, shown with a lightbulb in the warning colour.
    ///   - tint: the colour of input; cached input is a lighter shade of it, output is purple.
    init(newInput: Int, cachedInput: Int, output: Int,
         newInputUsd: Double? = nil, cachedInputUsd: Double? = nil, outputUsd: Double? = nil,
         hint: String? = nil, tint: Color = .accentColor) {
        parts = [
            Part(id: "new", label: String(localized: "New input"), tokens: newInput, usd: newInputUsd, color: tint),
            Part(id: "cached", label: String(localized: "Cached input"), tokens: cachedInput, usd: cachedInputUsd, color: tint.opacity(0.4)),
            Part(id: "output", label: String(localized: "Output"), tokens: output, usd: outputUsd, color: .purple),
        ]
        self.hint = hint
    }

    private var total: Int { parts.map(\.tokens).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar
            legend
            if let hint {
                Label {
                    Text(hint).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Hint: \(hint)"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Token mix"))
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if total > 0 {
                    let shown = parts.filter { $0.tokens > 0 }
                    // 1-point gaps between parts, so neighbours read apart in any colour.
                    let width = geo.size.width - CGFloat(max(0, shown.count - 1))
                    HStack(spacing: 1) {
                        ForEach(shown) { part in
                            Rectangle().fill(part.color)
                                .frame(width: max(2, width * Double(part.tokens) / Double(total)))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: barHeight)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(parts) { part in
                GridRow {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 10, height: 10)
                        Text(part.label)
                    }
                    Text(String(localized: "\(Format.tokenCount(part.tokens)) tokens"))
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                    Text(part.usd.map(Format.smallMoney) ?? "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(part.label))
                .accessibilityValue(Text([String(localized: "\(Format.tokenCount(part.tokens)) tokens"),
                                          part.usd.map(Format.smallMoney)].compactMap { $0 }.joined(separator: ", ")))
            }
        }
        .font(.callout)
    }
}

#Preview("Token mix", traits: .fixedLayout(width: 420, height: 200)) {
    TokenMixBar(newInput: 182_400, cachedInput: 640_000, output: 41_300,
                newInputUsd: 0.0912, cachedInputUsd: 0.032, outputUsd: 0.0826, tint: .blue)
        .padding()
}

#Preview("Token mix · hint, dark", traits: .fixedLayout(width: 420, height: 220)) {
    TokenMixBar(newInput: 912_000, cachedInput: 8_200, output: 12_900,
                newInputUsd: 0.456, cachedInputUsd: 0.0004, outputUsd: 0.0258,
                hint: String("Almost no input comes from the cache. Keep the start of the prompt the same between requests."),
                tint: .blue)
        .padding()
        .preferredColorScheme(.dark)
}
