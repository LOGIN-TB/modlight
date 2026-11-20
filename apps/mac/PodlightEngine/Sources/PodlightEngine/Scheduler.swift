import Foundation

// Should a pod be running right now, and why?
//
// A pure function over an explicit `now`, so every rule can be tested without waiting for a clock
// or a time zone to roll over. The caller feeds it state and carries out what it says.
//
// The rules are not invented here. They are specified as cases in `spec/cases/scheduler*.json`,
// recorded from RunPod Launcher's scheduler, several of them after incidents on real pods. The
// Node service and, later, the Windows app must pass the same cases. Change the spec first.

/// Why the scheduler would start, stop or leave a pod alone. The raw values are the wire codes in
/// `spec/` and in the server API; the interface turns them into sentences.
public enum ScheduleReason: String, Codable, Sendable, CaseIterable {
    case insideSchedule = "inside-schedule"
    case outsideSchedule = "outside-schedule"
    case idleTimeout = "idle-timeout"
    case maxRuntime = "max-runtime"
    case dailyLimit = "daily-limit"
    case monthlyLimit = "monthly-limit"
    case scheduleDisabled = "schedule-disabled"
    case alreadyCorrect = "already-correct"
    case starting
    case idleUntilRequested = "idle-until-requested"
    case manualStart = "manual-start"
    case servingRequests = "serving-requests"
    case paused
    /// Podlight: the end the user chose when starting ("Läuft bis") has been reached.
    case runUntil = "run-until"
}

public struct Action: Codable, Equatable, Sendable {
    public enum Verb: String, Codable, Sendable { case start, stop, nothing }
    public var `do`: Verb
    public var because: ScheduleReason

    public init(_ verb: Verb, because: ScheduleReason) {
        self.do = verb
        self.because = because
    }
}

public struct Schedule: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// IANA zone, e.g. `Europe/Berlin`. The schedule's own, never the machine's.
    public var timezone: String
    /// 0 = Sunday … 6 = Saturday.
    public var weekdays: [Int]
    /// `HH:MM` in `timezone`. A window whose end is before its start crosses midnight.
    public var startAt: String?
    public var stopAt: String?
    /// Podlight never allows 0 here (idle stop is always on); the rule itself treats 0 as off so
    /// it stays identical to the server's.
    public var idleStopMinutes: Int
    public var maxRuntimeHours: Int

    public init(enabled: Bool, timezone: String, weekdays: [Int], startAt: String?, stopAt: String?,
                idleStopMinutes: Int, maxRuntimeHours: Int) {
        self.enabled = enabled
        self.timezone = timezone
        self.weekdays = weekdays
        self.startAt = startAt
        self.stopAt = stopAt
        self.idleStopMinutes = idleStopMinutes
        self.maxRuntimeHours = maxRuntimeHours
    }
}

public struct PodState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running = "RUNNING", starting = "STARTING", provisioning = "PROVISIONING"
        case exited = "EXITED", error = "ERROR", terminated = "TERMINATED"
    }

    public var status: Status?
    public var startedAt: Date?
    /// When the gateway last saw a request. Nil means none since it started.
    public var lastRequestAt: Date?
    /// A pod spends minutes downloading and loading; that time must not count as idle.
    public var engineReady: Bool
    /// Stopping mid-generation throws away work somebody is waiting for.
    public var inFlightRequests: Int
    /// A person asked for this pod; the schedule must not take it before it has been used.
    public var startedManually: Bool
    /// Without this, idle stop and schedule start fight each other all day.
    public var idleStoppedAt: Date?
    /// Held by hand. Reported so the interface can say why nothing happens.
    public var paused: Bool

    public init(status: Status?, startedAt: Date?, lastRequestAt: Date?, engineReady: Bool,
                inFlightRequests: Int, startedManually: Bool, idleStoppedAt: Date?, paused: Bool) {
        self.status = status
        self.startedAt = startedAt
        self.lastRequestAt = lastRequestAt
        self.engineReady = engineReady
        self.inFlightRequests = inFlightRequests
        self.startedManually = startedManually
        self.idleStoppedAt = idleStoppedAt
        self.paused = paused
    }
}

public struct Spend: Codable, Equatable, Sendable {
    public var todayUsd: Double
    public var monthUsd: Double
    public var dailyLimitUsd: Double?
    public var monthlyLimitUsd: Double?

    public init(todayUsd: Double, monthUsd: Double, dailyLimitUsd: Double?, monthlyLimitUsd: Double?) {
        self.todayUsd = todayUsd
        self.monthUsd = monthUsd
        self.dailyLimitUsd = dailyLimitUsd
        self.monthlyLimitUsd = monthlyLimitUsd
    }
}

/// One run that a person started. Podlight: every start has an end.
public struct Session: Codable, Equatable, Sendable {
    public var runUntil: Date?
    public init(runUntil: Date?) { self.runUntil = runUntil }
}

public struct WakeDecision: Codable, Equatable, Sendable {
    public var admit: Bool
    public var because: String
}

public enum Scheduler {
    /// How far ahead a closing window is worth mentioning.
    public static let closingSoonMinutes = 30

    public static func decide(schedule: Schedule, pod: PodState, spend: Spend, session: Session? = nil,
                              now: Date) -> Action {
        let isUp = pod.status == .running
        let isComingUp = pod.status == .starting || pod.status == .provisioning

        // Spend limits come first and are absolute.
        if isUp || isComingUp, let reason = limitReached(spend) {
            return Action(.stop, because: reason)
        }

        // A pod still coming up is left alone: acting would restart a boot that is going fine.
        if isComingUp { return Action(.nothing, because: .starting) }

        if isUp {
            let ceiling = exceedsRuntimeCeiling(schedule, pod, now)
            let ended = runUntilReached(session, now)

            // Never cut off work in progress, except for the rules that exist to stop money
            // being spent: the runtime ceiling, the chosen end, and the spend limits above.
            if pod.inFlightRequests > 0 && !ceiling && !ended {
                return Action(.nothing, because: .servingRequests)
            }
            if ceiling { return Action(.stop, because: .maxRuntime) }
            if ended { return Action(.stop, because: .runUntil) }

            // Nothing is idle until it can serve, and idleness runs from this pod's own start.
            if schedule.idleStopMinutes > 0 && pod.engineReady,
               let since = laterOf(pod.startedAt, pod.lastRequestAt) {
                let idleMinutes = now.timeIntervalSince(since) / 60
                if idleMinutes >= Double(schedule.idleStopMinutes) {
                    return Action(.stop, because: .idleTimeout)
                }
            }
        }

        if !schedule.enabled { return Action(.nothing, because: .scheduleDisabled) }

        // Below the limits and runtime rules on purpose: a pause never keeps a pod alive past them.
        if pod.paused { return Action(.nothing, because: .paused) }

        let wanted = isInsideWindow(schedule, now: now)

        if wanted && !isUp {
            // Stopped for idleness inside this very window: stay down until the next window or
            // a request. Restarting here would undo the saving the idle rule just made.
            if stoppedIdleInThisWindow(schedule, pod, now) {
                return Action(.nothing, because: .idleUntilRequested)
            }
            return Action(.start, because: .insideSchedule)
        }

        if !wanted && isUp {
            // A manual start outranks the schedule until the pod has actually been used.
            if pod.startedManually && !hasBeenUsed(pod) {
                return Action(.nothing, because: .manualStart)
            }
            return Action(.stop, because: .outsideSchedule)
        }
        return Action(.nothing, because: .alreadyCorrect)
    }

    /// May a request wake a stopped pod? Asked by the gateway *before* it starts anything, so a
    /// client that keeps calling cannot start a pod the next tick would stop again.
    public static func admitWake(spend: Spend) -> WakeDecision {
        if let reason = limitReached(spend) {
            return WakeDecision(admit: false, because: reason.rawValue)
        }
        return WakeDecision(admit: true, because: "within-limits")
    }

    /// Is `now` inside the window, in the schedule's own time zone?
    public static func isInsideWindow(_ schedule: Schedule, now: Date) -> Bool {
        guard let startAt = schedule.startAt, let stopAt = schedule.stopAt else { return false }
        let local = localParts(now, timeZone: schedule.timezone)
        let minutes = local.hour * 60 + local.minute
        let start = toMinutes(startAt)
        let stop = toMinutes(stopAt)

        if start == stop { return false }
        if start < stop {
            return schedule.weekdays.contains(local.weekday) && minutes >= start && minutes < stop
        }
        // Crosses midnight: the small hours belong to the previous day's window, so a Friday
        // night run is not cut off at midnight because Saturday is not a working day.
        if minutes >= start { return schedule.weekdays.contains(local.weekday) }
        let previousDay = (local.weekday + 6) % 7
        return minutes < stop && schedule.weekdays.contains(previousDay)
    }

    /// Minutes until the open window closes, only when that is within `closingSoonMinutes`.
    public static func minutesUntilStop(_ schedule: Schedule, now: Date) -> Int? {
        guard schedule.enabled, let stopAt = schedule.stopAt else { return nil }
        guard isInsideWindow(schedule, now: now) else { return nil }
        let local = localParts(now, timeZone: schedule.timezone)
        let minutes = local.hour * 60 + local.minute
        let stop = toMinutes(stopAt)
        let remaining = stop > minutes ? stop - minutes : stop + 24 * 60 - minutes
        return remaining <= closingSoonMinutes ? remaining : nil
    }

    /// When the window we are currently inside opened; identifies one occurrence of it.
    public static func windowOpenedAt(_ schedule: Schedule, now: Date) -> Date? {
        guard let startAt = schedule.startAt, isInsideWindow(schedule, now: now) else { return nil }
        let local = localParts(now, timeZone: schedule.timezone)
        let nowMinutes = local.hour * 60 + local.minute
        let startMinutes = toMinutes(startAt)
        let sinceOpen = nowMinutes >= startMinutes
            ? nowMinutes - startMinutes
            : nowMinutes + (24 * 60 - startMinutes)
        return now.addingTimeInterval(-Double(sinceOpen) * 60)
    }

    public struct LocalParts: Codable, Equatable, Sendable {
        public var hour: Int
        public var minute: Int
        /// 0 = Sunday … 6 = Saturday.
        public var weekday: Int
    }

    /// Hour, minute and weekday of `instant` in an IANA zone. An unknown zone falls back to UTC,
    /// as the server does.
    public static func localParts(_ instant: Date, timeZone identifier: String) -> LocalParts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: instant)
        return LocalParts(hour: c.hour ?? 0, minute: c.minute ?? 0, weekday: (c.weekday ?? 1) - 1)
    }

    // MARK: - Helpers

    private static func limitReached(_ spend: Spend) -> ScheduleReason? {
        if let limit = spend.dailyLimitUsd, spend.todayUsd >= limit { return .dailyLimit }
        if let limit = spend.monthlyLimitUsd, spend.monthUsd >= limit { return .monthlyLimit }
        return nil
    }

    private static func exceedsRuntimeCeiling(_ schedule: Schedule, _ pod: PodState, _ now: Date) -> Bool {
        guard schedule.maxRuntimeHours > 0, let startedAt = pod.startedAt else { return false }
        return now.timeIntervalSince(startedAt) / 3600 >= Double(schedule.maxRuntimeHours)
    }

    private static func runUntilReached(_ session: Session?, _ now: Date) -> Bool {
        guard let end = session?.runUntil else { return false }
        return now >= end
    }

    private static func stoppedIdleInThisWindow(_ schedule: Schedule, _ pod: PodState, _ now: Date) -> Bool {
        guard let stoppedAt = pod.idleStoppedAt else { return false }
        if let last = pod.lastRequestAt, last > stoppedAt { return false }
        guard let openedAt = windowOpenedAt(schedule, now: now) else { return false }
        return stoppedAt >= openedAt
    }

    private static func hasBeenUsed(_ pod: PodState) -> Bool {
        guard let last = pod.lastRequestAt, let started = pod.startedAt else { return false }
        return last > started
    }

    private static func laterOf(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return a > b ? a : b
    }

    private static func toMinutes(_ hhmm: String) -> Int {
        let parts = hhmm.split(separator: ":")
        let hours = parts.first.flatMap { Int($0) } ?? 0
        let minutes = parts.dropFirst().first.flatMap { Int($0) } ?? 0
        return hours * 60 + minutes
    }
}
