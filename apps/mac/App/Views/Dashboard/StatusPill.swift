import SwiftUI

/// What a model is doing, as a small capsule: ready (a steady dot), active with the number of
/// requests in flight (a gently breathing dot, still under Reduce Motion), or an error (a warning
/// icon in red). The text says the state too, so the colour is never the only signal.
///
///     StatusPill(.active(2), tint: .blue)
struct StatusPill: View {
    enum State: Hashable, Sendable {
        case ready
        case active(Int)
        case error
    }

    private let state: State
    private let tint: Color
    private let label: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - tint: the provider's colour (pod green, Venice blue); an error is always red.
    ///   - label: replaces the default text ("Ready", "2 active", "Error").
    init(_ state: State, tint: Color, label: String? = nil) {
        self.state = state
        self.tint = tint
        self.label = label
    }

    private var color: Color { state == .error ? .red : tint }

    private var text: String {
        if let label { return label }
        switch state {
        case .ready: return String(localized: "Ready")
        case .active(let count): return String(localized: "\(count) active")
        case .error: return String(localized: "Error")
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            indicator
            Text(text).monospacedDigit().lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.15), in: .capsule)
        .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 0.5))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }

    @ViewBuilder private var indicator: some View {
        switch state {
        case .ready:
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(color)
        case .active:
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(color)
                .symbolEffect(.breathe.pulse, options: .repeating, isActive: !reduceMotion)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
        }
    }
}

#Preview("Status pills", traits: .sizeThatFitsLayout) {
    VStack(alignment: .leading, spacing: 10) {
        HStack { StatusPill(.ready, tint: .green); StatusPill(.active(3), tint: .green); StatusPill(.error, tint: .green) }
        HStack { StatusPill(.ready, tint: .blue); StatusPill(.active(1), tint: .blue); StatusPill(.ready, tint: .blue, label: String("Idle")) }
    }
    .padding()
}

#Preview("Status pills · dark", traits: .sizeThatFitsLayout) {
    HStack { StatusPill(.ready, tint: .green); StatusPill(.active(12), tint: .blue); StatusPill(.error, tint: .blue) }
        .padding()
        .preferredColorScheme(.dark)
}
