import SwiftUI

/// Tiles side by side, as many as fit (each at least about 140 points wide), wrapping onto more
/// rows when the window is narrow.
///
///     MetricGrid { ForEach(metrics) { MetricTile($0) } }
struct MetricGrid<Content: View>: View {
    @ScaledMetric private var minimumWidth: CGFloat
    private let spacing: CGFloat
    private let content: Content

    init(minimumTileWidth: CGFloat = 140, spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        _minimumWidth = ScaledMetric(wrappedValue: minimumTileWidth)
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: spacing, alignment: .top)],
                  alignment: .leading, spacing: spacing) {
            content
        }
    }
}

private let sampleFigures: [MetricTile.Metric] = [
    .init(id: "pods", title: "Running pods", value: "2", caption: "1 waiting for a card"),
    .init(id: "rate", title: "Cost per hour", value: "$1.84/h", caption: "GPU and storage"),
    .init(id: "today", title: "Today", value: "$6.12", caption: "of $20.00"),
    .init(id: "month", title: "This month", value: "$88.40", caption: "of $150.00"),
    .init(id: "venice", title: "Venice", value: "$0.42", caption: "today"),
]

#Preview("Grid · wide", traits: .fixedLayout(width: 640, height: 200)) {
    MetricGrid { ForEach(sampleFigures) { MetricTile($0) } }
        .padding()
}

#Preview("Grid · narrow, dark", traits: .fixedLayout(width: 220, height: 420)) {
    MetricGrid { ForEach(sampleFigures) { MetricTile($0) } }
        .padding()
        .preferredColorScheme(.dark)
}
