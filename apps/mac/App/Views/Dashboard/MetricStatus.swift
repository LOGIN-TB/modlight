import SwiftUI

/// How a figure stands, shown on dashboards as an icon and a colour together, never colour alone.
/// `normal` shows neither: most figures are just figures.
enum MetricStatus: Hashable, Sendable {
    case normal, good, warning, critical

    var color: Color? {
        switch self {
        case .normal: nil
        case .good: .green
        case .warning: .orange
        case .critical: .red
        }
    }

    var symbol: String? {
        switch self {
        case .normal: nil
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    /// What VoiceOver says after the value.
    var spoken: String? {
        switch self {
        case .normal: nil
        case .good: String(localized: "Good")
        case .warning: String(localized: "Warning")
        case .critical: String(localized: "Critical")
        }
    }
}
