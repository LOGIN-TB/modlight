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

    /// Storage costs fractions of a cent per hour, so it gets a third decimal place.
    static func storagePerHour(_ usd: Double) -> String {
        if usd <= 0 { return String(localized: "nothing") }
        if usd < 0.0005 { return "< " + String(localized: "\(0.001.formatted(.currency(code: "USD").precision(.fractionLength(3))))/h") }
        let digits = usd < 0.1 ? 3 : 2
        return String(localized: "\(usd.formatted(.currency(code: "USD").precision(.fractionLength(digits))))/h")
    }

    /// A kept disk while its pod is stopped: per hour, as RunPod bills it, and per month.
    static func keptDisk(gb: Int) -> String {
        keptDisk(perHour: StoragePricing.stoppedPerHour(volumeGB: gb), perMonth: StoragePricing.stoppedPerMonth(volumeGB: gb))
    }

    static func keptDisk(perHour: Double, perMonth: Double) -> String {
        String(localized: "\(storagePerHour(perHour)) · about \(money(perMonth)) a month")
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
        case let e as ServerError:
            return serverError(e)
        case let e as ServerAddress.Problem:
            return address(e)
        default:
            return error.localizedDescription
        }
    }

    static func serverError(_ error: ServerError) -> String {
        switch error {
        case .unreachable(let message):
            String(localized: "The server does not answer: \(message)")
        case .notPaired:
            String(localized: "The server no longer accepts this Mac. Pair it again under Server Settings.")
        case .refused(_, let message, _):
            message
        case .unexpected(let message):
            String(localized: "The server sent an answer Podlight does not understand. Is it a Podlight server of the same version? (\(message))")
        }
    }

    static func address(_ problem: ServerAddress.Problem) -> String {
        switch problem {
        case .invalid: String(localized: "Enter the server's address, e.g. podlight.example.com.")
        case .insecure: String(localized: "Use an https:// address. Plain http is allowed only for this Mac and your local network, because the keys would travel unencrypted.")
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
        case "engine-exited": String(localized: "The engine stopped with an error, so Podlight ended the pod:")
        case "outside-region": String(localized: "RunPod placed the pod outside your chosen region, so Podlight deleted it straight away. Try again, or allow more regions under Edit.")
        default: code
        }
    }

    /// "EU only · Secure Cloud", for summaries and the model's detail.
    static func hosting(_ policy: HostingPolicy) -> String {
        let region = switch policy.region {
        case .anywhere: String(localized: "Anywhere")
        case .eu: String(localized: "EU only")
        case .euEEA: String(localized: "EU and EEA")
        }
        return policy.clouds == [.secure] ? String(localized: "\(region) · Secure Cloud") : region
    }

    /// "8.99 $/h + 0.02 $/h storage": the card price and the disks, kept apart so the card's
    /// price matches the one in the list.
    static func price(gpu: Double, storage: Double) -> String {
        if storage <= 0 { return Format.perHour(gpu) }
        return String(localized: "\(Format.perHour(gpu)) + \(Format.storagePerHour(storage)) storage")
    }
}
