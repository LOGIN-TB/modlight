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

    /// The image for the menu bar, always the same size so the item never shifts when the bulb
    /// lights up. A coloured one is drawn into a bitmap rather than handed over as a symbol: the
    /// menu bar blends symbol images with its background, which turned blue into red. Off, it is a
    /// template, so it follows the menu bar's own colour as before.
    @MainActor
    func image() -> NSImage {
        let key = "\(symbolName)|\(colors?.map { $0.description }.joined(separator: ",") ?? "template")"
        if let cached = Self.cache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: Self.pointSize, weight: .regular)
            .applying(colors.map { NSImage.SymbolConfiguration(paletteColors: $0) } ?? NSImage.SymbolConfiguration())
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        let canvas = Self.canvas
        let image = NSImage(size: canvas, flipped: false) { rect in
            let size = symbol.size
            symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                   width: size.width, height: size.height))
            return true
        }
        image.isTemplate = colors == nil
        Self.cache[key] = image
        return image
    }

    private static let pointSize: CGFloat = 15
    /// The lit bulb with its rays is the widest state; every state is drawn on its size.
    private static let canvas: NSSize = {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let size = NSImage(systemSymbolName: "lightbulb.max.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.size ?? NSSize(width: 20, height: 18)
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }()
    @MainActor private static var cache: [String: NSImage] = [:]

    /// `-PodlightLampPreview pod|venice|both` at launch shows that state, to check the colours in
    /// the menu bar without a running pod or a paid request.
    static var preview: MenuBarLamp? {
        switch UserDefaults.standard.string(forKey: "PodlightLampPreview") {
        case "pod": MenuBarLamp(podActive: true, apiProviders: [])
        case "venice": MenuBarLamp(podActive: false, apiProviders: [.venice])
        case "both": MenuBarLamp(podActive: true, apiProviders: [.venice])
        default: nil
        }
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
