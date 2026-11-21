import Foundation
import PodlightEngine

/// Numbers, money and times as people read them, in their own locale.
enum Format {
    static func money(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(usd < 10 ? 2 : 0)))
    }

    static func perHour(_ usd: Double) -> String {
        String(localized: "\(money(usd))/h")
    }

    static func tokens(_ count: Int) -> String {
        count >= 1024 ? "\(count / 1024)k" : "\(count)"
    }

    static func gigabytes(_ bytes: Double) -> String {
        (bytes / 1_000_000_000).formatted(.number.precision(.fractionLength(1))) + " GB"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    static func remaining(until date: Date, now: Date = .now) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }

    static func speed(_ tokensPerSecond: Double?) -> String {
        guard let t = tokensPerSecond else { return "–" }
        return String(localized: "about \(Int(t.rounded())) tok/s")
    }
}

/// Error sentences that say what happened and what to do, in the user's language.
enum Describe {
    static func error(_ error: Error) -> String {
        switch error {
        case let e as PodlightError:
            switch e {
            case .missingRunpodKey:
                return String(localized: "Add your RunPod API key first (Podlight → Settings → Access).")
            case .limitReached(let which):
                return which == "monthly-limit"
                    ? String(localized: "The monthly spending limit is reached. Raise it in Settings to start again.")
                    : String(localized: "Today's spending limit is reached. Raise it in Settings or start again tomorrow.")
            case .noCapacity(let tried):
                return String(localized: "RunPod has no free card right now (tried: \(tried.joined(separator: ", "))). Try again in a few minutes, or choose \"Fast\" for more card types.")
            case .noSuitableCard:
                return String(localized: "No RunPod card can hold this model with its context. Choose a smaller context or a 4-bit variant.")
            case .unknownModel(let name):
                return String(localized: "There is no model named \(name).")
            case .runpod(let status, let message):
                return status == 401
                    ? String(localized: "RunPod did not accept the API key. Check it in Settings → Access.")
                    : String(localized: "RunPod refused: \(message)")
            case .notReadyInTime:
                return String(localized: "The model is still loading. A new pod can take up to 25 minutes; resuming one takes about a minute.")
            case .wakeDisabled:
                return String(localized: "The model is stopped. Start it in Podlight.")
            case .keychain(let message):
                return String(localized: "Podlight could not use the keychain: \(message)")
            }
        case let e as RunpodError:
            return String(localized: "RunPod refused (\(e.status)).")
        default:
            return error.localizedDescription
        }
    }

    /// Why a pod last stopped, for the model's detail and the menu bar.
    static func reason(_ code: String?) -> String? {
        switch code {
        case nil: nil
        case "manual": String(localized: "Stopped by you.")
        case "app-quit": String(localized: "Stopped when Podlight quit.")
        case "run-until": String(localized: "Stopped at the end you chose.")
        case "idle-timeout": String(localized: "Stopped because no requests came in.")
        case "max-runtime": String(localized: "Stopped at the maximum runtime.")
        case "daily-limit": String(localized: "Stopped at today's spending limit.")
        case "monthly-limit": String(localized: "Stopped at the monthly spending limit.")
        case "outside-schedule": String(localized: "Stopped when the schedule window closed.")
        case "stopped-outside": String(localized: "Stopped outside Podlight, most likely by its own safety stop (no contact with Podlight, or its end passed).")
        case "pod-gone": String(localized: "The pod no longer exists at RunPod.")
        case "deleted-unused": String(localized: "Deleted after three days unused. The next start builds a new pod.")
        case "no-capacity": String(localized: "No free card at RunPod.")
        case "no-suitable-card": String(localized: "No card can hold this model.")
        case "runpod-error": String(localized: "RunPod reported an error.")
        case "pod-error": String(localized: "The pod is in an error state at RunPod.")
        case "outside-region": String(localized: "RunPod placed the pod outside your chosen region, so Podlight deleted it straight away. Try again, or allow more regions in Settings.")
        default: code
        }
    }
}
