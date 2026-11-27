import Foundation
import ModlightEngine
import UserNotifications

/// Notifications for what happens while Modlight is in the background: a model became ready, a
/// run is about to end (with "extend by one hour"), a limit or the safety stop ended a run, or a
/// pod landed outside the chosen region. Permission is asked the first time a model is started,
/// not at launch.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let extendAction = "extend-1h"
    nonisolated static let endingCategory = "run-ending"

    var onExtend: ((UUID) -> Void)?
    private var warnedEnding: Set<String> = []
    private var asked = false

    override init() {
        super.init()
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let extend = UNNotificationAction(identifier: Self.extendAction, title: String(localized: "Extend by One Hour"))
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.endingCategory, actions: [extend],
                                                                 intentIdentifiers: [])])
    }

    func requestPermissionOnce() {
        guard !asked, Bundle.main.bundleIdentifier != nil else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Looks at what changed since the last reload and says what deserves a notification.
    func compare(previous: ModlightState, current: ModlightState) {
        for model in current.models {
            let before = previous.run(model.id), now = current.run(model.id)
            if before.phase != .ready && now.phase == .ready && previous.runs[model.id] != nil {
                post(String(localized: "\(model.name) is ready"),
                     String(localized: "Agents can use it now."), id: "ready-\(model.id)")
            }
            if let end = now.runUntil, now.phase == .ready {
                let key = "\(model.id)-\(end.timeIntervalSince1970)"
                let left = end.timeIntervalSinceNow
                if left > 0, left <= 10 * 60, !warnedEnding.contains(key) {
                    warnedEnding.insert(key)
                    post(String(localized: "\(model.name) stops in \(Int(left / 60) + 1) minutes"),
                         String(localized: "Extend it if you are still working."), id: "ending-\(model.id)",
                         category: Self.endingCategory, modelId: model.id)
                }
            }
            if before.managedBy == nil, let other = now.managedBy, previous.runs[model.id] != nil {
                post(String(localized: "\(model.name) moved to \(PodOwner.displayName(of: other))"),
                     String(localized: "That Mac manages it now. Take it back in Modlight to use it here."), id: "moved-\(model.id)")
            }
            if before.lastReason != now.lastReason, let reason = now.lastReason {
                switch reason {
                case "daily-limit", "monthly-limit":
                    post(String(localized: "\(model.name) stopped at your spending limit"),
                         Describe.reason(reason) ?? "", id: "limit-\(model.id)")
                case "stopped-outside":
                    post(String(localized: "\(model.name) was stopped by its safety stop"),
                         Describe.reason(reason) ?? "", id: "outside-\(model.id)")
                case "outside-region":
                    post(String(localized: "\(model.name) was not started"),
                         Describe.reason(reason) ?? "", id: "region-\(model.id)")
                default: break
                }
            }
        }
    }

    private func post(_ title: String, _ body: String, id: String, category: String? = nil, modelId: UUID? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        if let modelId { content.userInfo = ["model": modelId.uuidString] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Self.extendAction,
              let raw = response.notification.request.content.userInfo["model"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { onExtend?(id) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
