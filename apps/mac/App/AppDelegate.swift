import AppKit
import PodlightEngine
import SwiftUI

/// Quitting with pods running asks first. The gateway lives in this app, so once it quits nothing
/// can reach those pods: they would only cost money until their own dead-man switch stops them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: AppModel?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let folder = Snapshots.requestedDirectory {
            Task { @MainActor in
                await Snapshots.run(into: folder)
                exit(0)
            }
        }
    }

    /// Closing the window keeps Podlight running in the menu bar, and with it the gateway.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let running = model.runningLocalPods
        guard !running.isEmpty else { return .terminateNow }

        let perHour = running.compactMap { $0.1.pricePerHour }.reduce(0, +)
        let names = running.map(\.0.name).joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = running.count == 1
            ? String(localized: "1 pod is still running")
            : String(localized: "\(running.count) pods are still running")
        alert.informativeText = String(localized: """
            \(names) cost about \(Format.money(perHour)) per hour. Once Podlight has quit, agents on this Mac can no longer reach them.

            If you keep them running, each pod stops itself after \(model.state.settings.heartbeatMinutes) minutes without Podlight.
            """)
        alert.addButton(withTitle: String(localized: "Stop and Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit and Keep Running"))
        alert.buttons[1].keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.stopAllAndQuit()
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { model?.openMainWindow?() } }
        return true
    }
}
