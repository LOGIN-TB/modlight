import type { PodStatus, Schedule } from '../model.ts'

// Should a pod be running right now, and why? A pure function over an explicit `now`.
// Port of apps/mac/ModlightEngine/Sources/ModlightEngine/Scheduler.swift; both are held to
// spec/cases/scheduler*.json. Change the spec first, then both implementations.

export type ScheduleReason =
  | 'inside-schedule' | 'outside-schedule' | 'idle-timeout' | 'max-runtime' | 'daily-limit' | 'monthly-limit'
  | 'schedule-disabled' | 'already-correct' | 'starting' | 'idle-until-requested' | 'manual-start'
  | 'serving-requests' | 'paused' | 'run-until'

export interface Action {
  do: 'start' | 'stop' | 'nothing'
  because: ScheduleReason
}

export interface PodState {
  status: PodStatus | null
  startedAt: Date | null
  lastRequestAt: Date | null
  engineReady: boolean
  inFlightRequests: number
  startedManually: boolean
  idleStoppedAt: Date | null
  paused: boolean
}

export interface Spend {
  todayUsd: number
  monthUsd: number
  dailyLimitUsd: number | null
  monthlyLimitUsd: number | null
}

export interface Session {
  runUntil: Date | null
}

export interface WakeDecision {
  admit: boolean
  because: string
}

export const CLOSING_SOON_MINUTES = 30

export function decide(schedule: Schedule, pod: PodState, spend: Spend, session: Session | null, now: Date): Action {
  const isUp = pod.status === 'RUNNING'
  const isComingUp = pod.status === 'STARTING' || pod.status === 'PROVISIONING'

  // Spend limits come first and are absolute.
  if (isUp || isComingUp) {
    const reason = limitReached(spend)
    if (reason) return { do: 'stop', because: reason }
  }

  // A pod still coming up is left alone: acting would restart a boot that is going fine.
  if (isComingUp) return { do: 'nothing', because: 'starting' }

  if (isUp) {
    const ceiling = exceedsRuntimeCeiling(schedule, pod, now)
    const ended = session?.runUntil != null && now.getTime() >= session.runUntil.getTime()

    // Never cut off work in progress, except for the rules that exist to stop money being spent.
    if (pod.inFlightRequests > 0 && !ceiling && !ended) return { do: 'nothing', because: 'serving-requests' }
    if (ceiling) return { do: 'stop', because: 'max-runtime' }
    if (ended) return { do: 'stop', because: 'run-until' }

    // Nothing is idle until it can serve, and idleness runs from this pod's own start.
    const since = laterOf(pod.startedAt, pod.lastRequestAt)
    if (schedule.idleStopMinutes > 0 && pod.engineReady && since) {
      const idleMinutes = (now.getTime() - since.getTime()) / 60_000
      if (idleMinutes >= schedule.idleStopMinutes) return { do: 'stop', because: 'idle-timeout' }
    }
  }

  if (!schedule.enabled) return { do: 'nothing', because: 'schedule-disabled' }

  // Below the limits and runtime rules on purpose: a pause never keeps a pod alive past them.
  if (pod.paused) return { do: 'nothing', because: 'paused' }

  const wanted = isInsideWindow(schedule, now)

  if (wanted && !isUp) {
    // Stopped for idleness inside this very window: stay down until the next window or a request.
    if (stoppedIdleInThisWindow(schedule, pod, now)) return { do: 'nothing', because: 'idle-until-requested' }
    return { do: 'start', because: 'inside-schedule' }
  }

  if (!wanted && isUp) {
    // A manual start outranks the schedule until the pod has actually been used.
    if (pod.startedManually && !hasBeenUsed(pod)) return { do: 'nothing', because: 'manual-start' }
    return { do: 'stop', because: 'outside-schedule' }
  }
  return { do: 'nothing', because: 'already-correct' }
}

/** May a request wake a stopped pod? Asked before anything starts. */
export function admitWake(spend: Spend): WakeDecision {
  const reason = limitReached(spend)
  return reason ? { admit: false, because: reason } : { admit: true, because: 'within-limits' }
}

export function isInsideWindow(schedule: Schedule, now: Date): boolean {
  const { startAt, stopAt } = schedule
  if (!startAt || !stopAt) return false
  const local = localParts(now, schedule.timezone)
  const minutes = local.hour * 60 + local.minute
  const start = toMinutes(startAt)
  const stop = toMinutes(stopAt)

  if (start === stop) return false
  if (start < stop) return schedule.weekdays.includes(local.weekday) && minutes >= start && minutes < stop
  // Crosses midnight: the small hours belong to the previous day's window.
  if (minutes >= start) return schedule.weekdays.includes(local.weekday)
  const previousDay = (local.weekday + 6) % 7
  return minutes < stop && schedule.weekdays.includes(previousDay)
}

export function minutesUntilStop(schedule: Schedule, now: Date): number | null {
  if (!schedule.enabled || !schedule.stopAt) return null
  if (!isInsideWindow(schedule, now)) return null
  const local = localParts(now, schedule.timezone)
  const minutes = local.hour * 60 + local.minute
  const stop = toMinutes(schedule.stopAt)
  const remaining = stop > minutes ? stop - minutes : stop + 24 * 60 - minutes
  return remaining <= CLOSING_SOON_MINUTES ? remaining : null
}

export function windowOpenedAt(schedule: Schedule, now: Date): Date | null {
  if (!schedule.startAt || !isInsideWindow(schedule, now)) return null
  const local = localParts(now, schedule.timezone)
  const nowMinutes = local.hour * 60 + local.minute
  const startMinutes = toMinutes(schedule.startAt)
  const sinceOpen = nowMinutes >= startMinutes ? nowMinutes - startMinutes : nowMinutes + (24 * 60 - startMinutes)
  return new Date(now.getTime() - sinceOpen * 60_000)
}

export interface LocalParts {
  hour: number
  minute: number
  /** 0 = Sunday … 6 = Saturday. */
  weekday: number
}

const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const formatters = new Map<string, Intl.DateTimeFormat>()

/** Hour, minute and weekday of `instant` in an IANA zone. An unknown zone falls back to UTC. */
export function localParts(instant: Date, timeZone: string): LocalParts {
  let formatter = formatters.get(timeZone)
  if (!formatter) {
    const options: Intl.DateTimeFormatOptions = { hour: '2-digit', minute: '2-digit', weekday: 'short', hourCycle: 'h23' }
    try {
      formatter = new Intl.DateTimeFormat('en-US', { ...options, timeZone })
    } catch {
      formatter = new Intl.DateTimeFormat('en-US', { ...options, timeZone: 'UTC' })
    }
    formatters.set(timeZone, formatter)
  }
  const parts = Object.fromEntries(formatter.formatToParts(instant).map((p) => [p.type, p.value]))
  return {
    hour: Number(parts.hour) % 24,
    minute: Number(parts.minute),
    weekday: WEEKDAYS.indexOf(parts.weekday ?? 'Sun'),
  }
}

function limitReached(spend: Spend): ScheduleReason | null {
  if (spend.dailyLimitUsd != null && spend.todayUsd >= spend.dailyLimitUsd) return 'daily-limit'
  if (spend.monthlyLimitUsd != null && spend.monthUsd >= spend.monthlyLimitUsd) return 'monthly-limit'
  return null
}

function exceedsRuntimeCeiling(schedule: Schedule, pod: PodState, now: Date): boolean {
  if (schedule.maxRuntimeHours <= 0 || !pod.startedAt) return false
  return (now.getTime() - pod.startedAt.getTime()) / 3_600_000 >= schedule.maxRuntimeHours
}

function stoppedIdleInThisWindow(schedule: Schedule, pod: PodState, now: Date): boolean {
  const stoppedAt = pod.idleStoppedAt
  if (!stoppedAt) return false
  if (pod.lastRequestAt && pod.lastRequestAt > stoppedAt) return false
  const openedAt = windowOpenedAt(schedule, now)
  if (!openedAt) return false
  return stoppedAt >= openedAt
}

function hasBeenUsed(pod: PodState): boolean {
  if (!pod.lastRequestAt || !pod.startedAt) return false
  return pod.lastRequestAt > pod.startedAt
}

function laterOf(a: Date | null, b: Date | null): Date | null {
  if (!a) return b
  if (!b) return a
  return a > b ? a : b
}

function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(':')
  return (Number.parseInt(h ?? '0', 10) || 0) * 60 + (Number.parseInt(m ?? '0', 10) || 0)
}
