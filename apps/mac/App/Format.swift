import Foundation
import ModlightEngine

/// Numbers, money and times as people read them, in their own locale.
enum Format {
    static func money(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(usd < 10 ? 2 : 0)))
    }

    /// This build's version, e.g. "0.6.1 (10)". Read from the bundle, which takes it from
    /// MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml, so every release shows its own.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
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

    /// Token counts as people read them: 950, 12.4k, 3.2M.
    static func tokenCount(_ count: Int) -> String {
        let n = Double(count)
        if count < 1000 { return count.formatted() }
        if count < 1_000_000 { return (n / 1000).formatted(.number.precision(.fractionLength(count < 10_000 ? 1 : 0))) + "k" }
        return (n / 1_000_000).formatted(.number.precision(.fractionLength(count < 100_000_000 ? 1 : 0))) + " M"
    }

    /// A price per million tokens: "$0.50"; small prices get more decimals.
    static func perMillion(_ usd: Double) -> String {
        usd.formatted(.currency(code: "USD").precision(.fractionLength(usd < 0.1 ? 3 : 2)))
    }

    /// Cost of API use, down to a hundredth of a cent.
    static func smallMoney(_ usd: Double) -> String {
        if usd > 0 && usd < 0.0001 { return "< " + 0.0001.formatted(.currency(code: "USD").precision(.fractionLength(4))) }
        return usd.formatted(.currency(code: "USD").precision(.fractionLength(usd < 1 ? 4 : 2)))
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
        case let e as ModlightError:
            switch e {
            case .missingRunpodKey:
                return String(localized: "Add your RunPod API key first (Modlight → Settings → Providers).")
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
                    ? String(localized: "RunPod did not accept the API key. Check it in Settings → Providers.")
                    : String(localized: "RunPod refused: \(message)")
            case .notReadyInTime:
                return String(localized: "The model is still loading. A new pod can take up to 25 minutes; resuming one takes about a minute.")
            case .wakeDisabled:
                return String(localized: "The model is stopped. Start it in Modlight.")
            case .keychain(let message):
                return String(localized: "Modlight could not use the keychain: \(message)")
            case .managedElsewhere(let mac):
                return String(localized: "\(mac) manages this model now. Take it back to use it on this Mac.")
            case .nameTaken(let name):
                return String(localized: "This Mac already has a model named \(name). Rename or remove it first, then take the pod over.")
            case .hostBusy:
                return String(localized: "The card on the machine of this model's pod is taken right now. The pod and its disk with the model are kept, and Modlight keeps trying to resume it until the end you chose. You can also start on a new card (the model is downloaded again).")
            case .busy:
                return String(localized: "The model is starting, stopping or waiting for a card. Hand it over once it runs or has stopped.")
            case .cardTooExpensive(let wanted, let ceiling, _):
                let card = wanted?.name ?? String(localized: "The chosen card")
                return String(localized: "\(card) is taken, and the free cards cost more than \(Format.perHour(ceiling)). Nothing was booked.")
            case .modelLookup(let message):
                return String(localized: "Hugging Face could not describe the model, so it cannot be taken over yet: \(message)")
            case .missingProviderKey(let provider):
                return String(localized: "Add your \(provider.displayName) API key first (Modlight → Settings → Providers).")
            case .provider(let failure):
                return failure.message
            case .unsupportedPath(let path, let provider):
                return String(localized: "\(provider.displayName) does not serve \(path).")
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

    /// Why a server would not take a model from this Mac, in the app's language.
    static func handOverRefused(_ error: ServerError) -> String {
        guard case .refused(_, let message, let code) = error else { return serverError(error) }
        switch code {
        case "name_taken": return String(localized: "The server already has a model with this name. Rename one of them first.")
        case "already_here": return String(localized: "This model is already on the server.")
        case "not_a_mac_pod": return String(localized: "The pod was not created by Modlight on a Mac, so the server does not take it.")
        case "pod_busy": return String(localized: "The pod is starting or stopping. Hand the model over once it runs or has stopped.")
        case "outside_region": return String(localized: "The pod runs outside the server's region, and the server would delete it there. Allow that region on the server first. (\(message))")
        case "setup_incomplete": return String(localized: "The server has no RunPod API key yet. Copy this Mac's key to it first.")
        default: return message
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
            String(localized: "The server sent an answer Modlight does not understand. Is it a Modlight server of the same version? (\(message))")
        }
    }

    static func address(_ problem: ServerAddress.Problem) -> String {
        switch problem {
        case .invalid: String(localized: "Enter the server's address, e.g. modlight.example.com.")
        case .insecure: String(localized: "Use an https:// address. Plain http is allowed only for this Mac and your local network, because the keys would travel unencrypted.")
        }
    }

    /// Why a pod last stopped, for the model's detail and the menu bar.
    static func reason(_ code: String?) -> String? {
        switch code {
        case nil: nil
        case "manual": String(localized: "Stopped by you.")
        case "app-quit": String(localized: "Stopped when Modlight quit.")
        case "run-until": String(localized: "Stopped at the end you chose.")
        case "idle-timeout": String(localized: "Stopped because no requests came in.")
        case "max-runtime": String(localized: "Stopped at the maximum runtime.")
        case "daily-limit": String(localized: "Stopped at today's spending limit.")
        case "monthly-limit": String(localized: "Stopped at the monthly spending limit.")
        case "outside-schedule": String(localized: "Stopped when the schedule window closed.")
        case "stopped-outside": String(localized: "Stopped outside Modlight, most likely by its own safety stop (no contact with Modlight, or its end passed).")
        case "pod-gone": String(localized: "The pod no longer exists at RunPod.")
        case "deleted-unused": String(localized: "Deleted after three days unused. The next start builds a new pod.")
        case "no-capacity": String(localized: "No free card at RunPod.")
        case "no-suitable-card": String(localized: "No card can hold this model.")
        case "runpod-error": String(localized: "RunPod reported an error.")
        case "pod-error": String(localized: "The pod is in an error state at RunPod.")
        case "engine-exited": String(localized: "The engine stopped with an error, so Modlight ended the pod:")
        case "outside-region": String(localized: "RunPod placed the pod outside your chosen region, so Modlight deleted it straight away. Try again, or allow more regions under Edit.")
        case "host-busy": String(localized: "The card on the pod's machine was taken, so it could not resume. Its disk with the model is kept.")
        case "card-too-expensive": String(localized: "The chosen card was taken, and the free ones cost more than the set extra cost. Nothing was booked.")
        case "engine-stuck": String(localized: "The engine made no progress for 10 minutes while loading (often a stalled download on that machine), so Modlight stopped the pod. Start again, or start on a new card. Its last line:")
        case "gpu-unusable": String(localized: "The RunPod machine could not use its card (a CUDA error before the model was loaded). That is the machine, not the model: start on a new card, or choose another card type under Edit.")
        case "garbage-output": String(localized: "Start test failed: the model answered only with repeated characters, so Modlight stopped it. This build of the model does not work on this card (often a broken quantisation); try another build, such as a GGUF, or another card. Its answer:")
        case "taken-over": String(localized: "Taken over from another Mac.")
        case "taken-back": String(localized: "Taken back from another Mac.")
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
