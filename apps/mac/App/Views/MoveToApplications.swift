import AppKit
import SwiftUI

/// Offers to move Podlight into the Applications folder when it runs from the disk image or
/// Downloads. A Finder window cannot animate, so the animation lives here instead of in the DMG.
@MainActor
enum MoveToApplications {
    static let declinedKey = "declinedMoveToApplications"
    static let destination = URL(fileURLWithPath: "/Applications/Podlight.app")

    /// Not for development builds, not when already installed, not after "Not Now".
    static var shouldOffer: Bool {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Applications/") || path.contains("/DerivedData/") || path.contains("/build/") { return false }
        if Snapshots.requestedDirectory != nil { return false }
        return !UserDefaults.standard.bool(forKey: declinedKey)
    }

    /// Copies this app to /Applications (an older copy goes to the Trash) and opens the copy.
    static func moveAndRelaunch() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: Bundle.main.bundleURL, to: destination)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

struct MoveToApplicationsView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelled = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 22) {
            Text("Move Podlight to Applications?").font(.title2.weight(.semibold))
            HStack(spacing: 0) {
                ZStack {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 84, height: 84)
                        .offset(x: travelled ? 210 : 0)
                        .scaleEffect(travelled ? 0.55 : 1)
                        .opacity(travelled ? 0 : 1)
                }
                .frame(width: 100, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 120)
                Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications"))
                    .resizable().frame(width: 84, height: 84)
            }
            .frame(height: 100)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Podlight moves into the Applications folder"))
            Text("Podlight is running from the disk image or your Downloads folder. In Applications it starts reliably at login and updates itself.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                Button("Not Now") {
                    UserDefaults.standard.set(true, forKey: MoveToApplications.declinedKey)
                    dismissWindow(id: "move")
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move to Applications") {
                    do { try MoveToApplications.moveAndRelaunch() } catch {
                        self.error = String(localized: "Podlight could not be moved (\(error.localizedDescription)). Drag it into Applications in the Finder instead.")
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                travelled = false
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.easeInOut(duration: 1.2)) { travelled = true }
                try? await Task.sleep(for: .milliseconds(1900))
            }
        }
    }
}
