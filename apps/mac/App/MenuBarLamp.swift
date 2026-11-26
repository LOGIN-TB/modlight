import AppKit
import PodlightEngine
import SwiftUI

extension ModelProvider {
    /// The colour the menu bar bulb takes while this provider is in use: green for a running pod,
    /// a colour of its own for each API provider.
    var activityColor: NSColor {
        switch self {
        case .runpod: .systemGreen
        case .venice: .systemBlue
        }
    }
}

/// What the menu bar bulb shows: off, green for a running pod, the provider's colour while an API
/// model answers, and both at once as a green bulb with coloured rays.
struct MenuBarLamp: Equatable {
    var podActive: Bool
    /// API providers with requests in flight or answered a moment ago, first one first.
    var apiProviders: [ModelProvider]

    var isLit: Bool { podActive || !apiProviders.isEmpty }

    var symbolName: String { isLit ? "lightbulb.max.fill" : "lightbulb" }

    /// Palette colours for the bulb (first) and its rays (second); nil keeps the plain template look.
    var colors: [NSColor]? {
        let api = apiProviders.first?.activityColor
        switch (podActive, api) {
        case (false, nil): return nil
        case (true, nil): return [ModelProvider.runpod.activityColor]
        case (false, let api?): return [api]
        case (true, let api?): return [ModelProvider.runpod.activityColor, api]
        }
    }

    /// The image for the menu bar. A coloured one is not a template, or macOS would draw it in one colour.
    func image() -> NSImage {
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        guard let colors else {
            base.isTemplate = true
            return base
        }
        let config = NSImage.SymbolConfiguration(pointSize: 0, weight: .regular, scale: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = false
        return image
    }

    var accessibilityText: String {
        let names = apiProviders.map(\.displayName).joined(separator: ", ")
        switch (podActive, apiProviders.isEmpty) {
        case (false, true): return String(localized: "Podlight: nothing running")
        case (true, true): return String(localized: "Podlight: pods running")
        case (false, false): return String(localized: "Podlight: requests to \(names) running")
        case (true, false): return String(localized: "Podlight: pods running, requests to \(names) running")
        }
    }
}
