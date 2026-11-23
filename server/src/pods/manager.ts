import { generateToken } from '../crypto.ts'
import { hostingOf, iso, type ModelRun, parseDate, type PodlightModel, type PodTelemetry, podTelemetry, type ServerSettings } from '../model.ts'
import { allows, dataCenterIds, needsPlacementCheck, StoragePricing } from '../rules/hosting.ts'
import * as podPlan from '../rules/podPlan.ts'
import { admitWake, decide, type Spend } from '../rules/scheduler.ts'
import { GatewayFailure, summarizeEngineLog } from '../gateway/shape.ts'
import { createWithFallback, NoCapacityError, RunpodClient, RunpodError } from '../runpod/client.ts'
import { type Pod, pricePerHour } from '../runpod/types.ts'
import type { SettingsStore } from '../store/settings.ts'
import { dayKey, type StateStore } from '../store/state.ts'

// Runs the server's pods: starts them, keeps their watchdogs fed, and stops them when a rule says
// so. Port of PodManager.swift; RunPod is the source of truth and every tick re-reads it.
//
// The server only ever acts on pods whose id it stored itself. Other pods in the same RunPod
// account (the Mac's, anything else) are never listed, stopped or deleted.

export interface PodEndpoint {
  modelId: string
  baseURL: string
  key: string
}

export interface ManagerOptions {
  store: StateStore
  settings: SettingsStore
  now?: () => Date
  fetch?: typeof fetch
  /** Address of one port of a pod. RunPod's proxy in production; a local server in tests. */
  podURL?: (podId: string, port: number) => string
  /** RunPod API base, for tests. */
  runpodBase?: string
  /** Wait between readiness checks while a woken pod starts. */
  wakePollMs?: number
  log?: (message: string) => void
}

const ACTIVE = new Set(['creating', 'loading', 'ready', 'stopping'])
/** 30 minutes of samples at the 10-second tick. */
export const TELEMETRY_SAMPLES = 180

export class PodManager {
  private readonly store: StateStore
  private readonly settings: SettingsStore
  private readonly now: () => Date
  private readonly fetchImpl: typeof fetch
  private readonly podURL: (podId: string, port: number) => string
  private readonly runpodBase: string | undefined
  private readonly wakePollMs: number
  private readonly log: (message: string) => void
  private readonly inFlight = new Map<string, number>()
  private readonly starts = new Map<string, Promise<void>>()
  /** Telemetry per model while its pod runs, the last 30 minutes. In memory only. */
  private readonly samples = new Map<string, PodTelemetry[]>()
  private ticking = false

  constructor(o: ManagerOptions) {
    this.store = o.store
    this.settings = o.settings
    this.now = o.now ?? (() => new Date())
    this.fetchImpl = o.fetch ?? fetch
    this.podURL = o.podURL ?? podPlan.proxyURL
    this.runpodBase = o.runpodBase
    this.wakePollMs = o.wakePollMs ?? 5_000
    this.log = o.log ?? (() => {})
  }

  // MARK: Spend

  spend(): Spend {
    const s = this.settings.read()
    return this.store.spend(dayKey(this.now(), s.timezone), s)
  }

  private today(): string {
    return dayKey(this.now(), this.settings.read().timezone)
  }

  // MARK: Models

  save(model: PodlightModel): void {
    this.store.saveModel({ ...model, schedule: { ...model.schedule, idleStopMinutes: Math.max(5, model.schedule.idleStopMinutes) } })
  }

  /** Removes a model, deleting its pod and disk at RunPod first. */
  async remove(id: string): Promise<void> {
    this.samples.delete(id)
    const run = this.store.run(id)
    const client = this.clientOrNull()
    if (run.podId && client) {
      try {
        await client.deletePod(run.podId)
      } catch (error) {
        if (!(error instanceof RunpodError && error.isNotFound)) throw this.asFailure(error)
      }
    }
    this.store.removeModel(id)
  }

  // MARK: Start, stop, extend

  /** Starts (or resumes) a model's pod. Returns once RunPod has accepted it. */
  start(id: string, runUntil: Date | null, manual = true): Promise<void> {
    const running = this.starts.get(id)
    if (running) return running
    const task = this.performStart(id, runUntil, manual).finally(() => this.starts.delete(id))
    this.starts.set(id, task)
    return task
  }

  private async performStart(id: string, runUntil: Date | null, manual: boolean): Promise<void> {
    const model = this.store.model(id)
    if (!model) throw new GatewayFailure({ kind: 'unknownModel' })
    const wake = admitWake(this.spend())
    if (!wake.admit) throw new GatewayFailure({ kind: 'limitReached', limit: wake.because })
    const client = this.client()
    const settings = this.settings.read()
    const podKey = this.podKey(id)
    const run = this.store.run(id)

    if (run.podId) {
      try {
        const pod = await client.pod(run.podId)
        if (pod.status === 'RUNNING' || pod.status === 'STARTING' || pod.status === 'PROVISIONING') {
          this.store.updateRun(id, (r) => {
            r.runUntil = runUntil ? iso(runUntil) : null
            r.startedManually = r.startedManually || manual
          })
          return
        }
        this.store.updateRun(id, (r) => { r.phase = 'creating'; r.lastReason = null; r.lastMessage = null })
        const resumed = await client.action(run.podId, 'start')
        this.markStarted(id, resumed, runUntil, manual)
        return
      } catch (error) {
        if (error instanceof RunpodError && (error.isNotFound || error.isHostGpuUnavailable)) {
          // Gone, or its host gave the card away: build a new one from the same model.
          if (!error.isNotFound) await client.deletePod(run.podId).catch(() => {})
          this.store.updateRun(id, (r) => { r.podId = null })
        } else if (error instanceof RunpodError) {
          this.fail(id, error)
          throw this.asFailure(error)
        } else {
          throw error
        }
      }
    }

    this.store.updateRun(id, (r) => { r.phase = 'creating'; r.lastReason = null; r.lastMessage = null; r.fellBackFrom = null })
    try {
      const catalog = await client.gpuCatalog()
      const hosting = model.hosting ?? hostingOf(settings)
      const choices = podPlan.choices(model, catalog, hosting)
      if (choices.length === 0) throw new GatewayFailure({ kind: 'noSuitableCard' })
      const request = podPlan.request(model, {
        podKey, huggingFaceToken: this.settings.secret('huggingFaceToken'), runUntil,
        heartbeatMinutes: settings.heartbeatMinutes, dataCenterIds: dataCenterIds(hosting, catalog), namePrefix: 'podlight-srv-',
      })
      const created = await createWithFallback(client, request, choices, catalog)
      const names = new Map(catalog.map((g) => [g.id, g.name]))
      const listed = catalog.find((g) => g.id === created.choice.gpuId)
      const listPrice = listed ? pricePerHour(listed, created.choice.cloud) : null
      const price = created.pod.cost ?? (listPrice != null ? listPrice * created.choice.count : null)
      const name = names.get(created.choice.gpuId) ?? created.choice.gpuId
      this.store.updateRun(id, (r) => {
        r.podId = created.pod.id
        r.gpu = created.choice
        r.gpuName = created.choice.count > 1 ? `${created.choice.count} × ${name}` : name
        r.pricePerHour = price
        r.storagePerHour = podPlan.storagePerHour(model)
        r.persistentGB = model.keepDisk ? podPlan.persistentGB(model) : null
        r.containerGB = podPlan.containerGB(model)
        r.dataCenterId = created.pod.dataCenterId ?? null
        r.hosting = hosting
        r.fellBackFrom = created.attempts.filter((a) => a.outcome !== 'created').map((a) => names.get(a.choice.gpuId) ?? a.choice.gpuId)
      })
      this.markStarted(id, created.pod, runUntil, manual)
    } catch (error) {
      if (error instanceof NoCapacityError) {
        const tried = error.attempts.map((a) => a.choice.gpuId)
        this.store.updateRun(id, (r) => { r.phase = 'failed'; r.lastReason = 'no-capacity'; r.lastMessage = tried.join(', ') })
        throw new GatewayFailure({ kind: 'noCapacity', tried })
      }
      if (error instanceof RunpodError) {
        this.fail(id, error)
        throw this.asFailure(error)
      }
      if (error instanceof GatewayFailure && error.error.kind === 'noSuitableCard') {
        this.store.updateRun(id, (r) => { r.phase = 'failed'; r.lastReason = 'no-suitable-card' })
      }
      throw error
    }
  }

  private markStarted(id: string, pod: Pod, runUntil: Date | null, manual: boolean): void {
    const t = iso(this.now())
    this.store.updateRun(id, (r) => {
      const before = r.phase
      r.podStatus = pod.status
      r.phase = 'loading'
      r.startedAt = t
      r.accountedUntil = t
      r.engineReady = false
      r.startedManually = manual
      r.runUntil = runUntil ? iso(runUntil) : null
      r.idleStoppedAt = null
      r.stoppedAt = null
      r.lastRequestAt = null
      if (pod.cost) r.pricePerHour = pod.cost
    })
    this.log(`started ${id} on pod ${pod.id}`)
  }

  private fail(id: string, error: RunpodError): void {
    this.store.updateRun(id, (r) => {
      r.phase = 'failed'
      r.lastReason = 'runpod-error'
      r.lastMessage = `${error.status}: ${error.body.slice(0, 200)}`
    })
  }

  /**
   * Ends a run. With a kept disk the pod is stopped (GPU billing ends, the disk stays); without,
   * it is deleted and nothing is billed until the next start.
   */
  async stop(id: string, reason = 'manual'): Promise<void> {
    const run = this.store.run(id)
    if (!run.podId) return
    this.account(id, run)
    this.store.updateRun(id, (r) => { r.phase = 'stopping' })
    const keepDisk = this.store.model(id)?.keepDisk ?? true
    try {
      if (keepDisk) {
        const pod = await this.client().action(run.podId, 'stop')
        this.markStopped(id, pod.status, reason)
      } else {
        await this.client().deletePod(run.podId)
        this.markStopped(id, null, reason)
        this.store.updateRun(id, (r) => { r.podId = null; r.podStatus = null; r.persistentGB = null })
      }
      this.log(`stopped ${id}: ${reason}`)
    } catch (error) {
      if (error instanceof RunpodError && error.isNotFound) {
        this.store.updateRun(id, (r) => { r.podId = null; r.phase = 'stopped'; r.podStatus = null })
        return
      }
      if (error instanceof RunpodError) {
        this.fail(id, error)
        throw this.asFailure(error)
      }
      throw error
    }
  }

  private markStopped(id: string, status: Pod['status'] | null, reason: string): void {
    this.samples.delete(id)
    const t = iso(this.now())
    this.store.updateRun(id, (r) => {
      r.storageAccountedUntil = t
      r.podStatus = status ?? 'EXITED'
      r.phase = 'stopped'
      r.engineReady = false
      r.stoppedAt = t
      r.lastReason = reason
      r.runUntil = null
      if (reason === 'idle-timeout') r.idleStoppedAt = t
    })
  }

  /** Moves "Läuft bis" and tells the pod's watchdog at once. */
  async extend(id: string, until: Date): Promise<void> {
    this.store.updateRun(id, (r) => { r.runUntil = iso(until) })
    const run = this.store.run(id)
    if (run.podId && run.podStatus === 'RUNNING') await this.heartbeat(run.podId, id, until)
  }

  // MARK: Gateway

  /** The pod for `name`, woken and waited for if needed. */
  async endpoint(name: string): Promise<PodEndpoint> {
    const model = this.store.modelNamed(name)
    if (!model) throw new GatewayFailure({ kind: 'unknownModel' })
    const ready = this.readyEndpoint(model.id)
    if (ready) return ready

    const settings = this.settings.read()
    const phase = this.store.run(model.id).phase
    if (phase !== 'creating' && phase !== 'loading') {
      if (!settings.wakeOnRequest) throw new GatewayFailure({ kind: 'wakeDisabled' })
      await this.start(model.id, null, false)
    }

    const deadline = this.now().getTime() + settings.wakeWaitSeconds * 1000
    while (this.now().getTime() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, this.wakePollMs))
      await this.refresh(model.id)
      const current = this.readyEndpoint(model.id)
      if (current) return current
      const run = this.store.run(model.id)
      if (run.phase === 'failed' || run.phase === 'stopped') {
        throw new GatewayFailure({ kind: 'runpod', status: 0, message: run.lastMessage ?? 'the pod stopped while starting' })
      }
    }
    throw new GatewayFailure({ kind: 'notReadyInTime' })
  }

  private readyEndpoint(id: string): PodEndpoint | null {
    const run = this.store.run(id)
    if (run.phase !== 'ready' || !run.podId) return null
    return { modelId: id, baseURL: this.podURL(run.podId, podPlan.ENGINE_PORT), key: this.podKey(id) }
  }

  /** An agent reached the gateway with a valid key. Written at most once a minute. */
  clientSeen(): void {
    const last = parseDate(this.store.meta('lastClientRequestAt'))
    const t = this.now()
    if (last && t.getTime() - last.getTime() < 60_000) return
    this.store.setMeta('lastClientRequestAt', iso(t))
  }

  requestBegan(id: string): void {
    this.inFlight.set(id, (this.inFlight.get(id) ?? 0) + 1)
    const t = iso(this.now())
    this.store.updateRun(id, (r) => { r.lastRequestAt = t })
  }

  requestEnded(id: string): void {
    this.inFlight.set(id, Math.max(0, (this.inFlight.get(id) ?? 1) - 1))
    const t = iso(this.now())
    this.store.updateRun(id, (r) => { r.lastRequestAt = t })
  }

  requestsInFlight(id: string): number {
    return this.inFlight.get(id) ?? 0
  }

  // MARK: Tick

  /** Something is starting or running, so the next tick should come sooner. */
  isBusy(): boolean {
    return Object.values(this.store.runs()).some((r) => ACTIVE.has(r.phase) || r.podStatus === 'RUNNING')
  }

  /** Re-reads every pod from RunPod, keeps the watchdogs fed, and applies the rules. */
  async tick(): Promise<void> {
    if (this.ticking || !this.clientOrNull()) return
    this.ticking = true
    try {
      for (const model of this.store.models()) {
        await this.refresh(model.id)
        await this.applyRules(model.id)
      }
      await this.deleteLongStopped()
      this.accountStoredDisks()
    } finally {
      this.ticking = false
    }
  }

  /** A stopped pod's kept volume disk is billed; book it as it accrues. */
  private accountStoredDisks(): void {
    const t = this.now()
    for (const [id, run] of Object.entries(this.store.runs())) {
      if (!run.podId || run.phase !== 'stopped' || !run.persistentGB) continue
      const since = parseDate(run.storageAccountedUntil ?? run.stoppedAt)
      if (!since) continue
      const hours = Math.max(0, t.getTime() - since.getTime()) / 3_600_000
      this.store.addSpend(this.today(), (StoragePricing.stoppedPerMonth(run.persistentGB) / StoragePricing.hoursPerMonth) * hours)
      this.store.updateRun(id, (r) => { r.storageAccountedUntil = iso(t) })
    }
  }

  /** Brings one model's record in line with RunPod and its engine. */
  async refresh(id: string): Promise<void> {
    const client = this.clientOrNull()
    const run = this.store.run(id)
    if (!client || !run.podId) return
    const podId = run.podId

    let pod: Pod
    try {
      pod = await client.pod(podId)
    } catch (error) {
      if (error instanceof RunpodError && error.isNotFound) {
        this.account(id, run)
        this.store.updateRun(id, (r) => { r.podId = null; r.podStatus = null; r.phase = 'stopped'; r.lastReason = 'pod-gone' })
      }
      return // RunPod unreachable: keep what we know, try again next tick.
    }

    this.account(id, run)

    // RunPod treats requested data centers as a preference. A pod outside the allowed region is
    // deleted at once, before it serves anything.
    const model = this.store.model(id)
    const hosting = run.hosting ?? model?.hosting ?? hostingOf(this.settings.read())
    const unverifiable = needsPlacementCheck(hosting) && !pod.dataCenterId && pod.status === 'RUNNING'
    if (unverifiable || (pod.dataCenterId && !allows(hosting, pod.dataCenterId))) {
      const center = pod.dataCenterId ?? 'unknown'
      await client.deletePod(podId).catch(() => {})
      this.store.updateRun(id, (r) => {
        r.podId = null; r.podStatus = null; r.phase = 'failed'; r.engineReady = false
        r.lastReason = 'outside-region'; r.lastMessage = center; r.dataCenterId = center
      })
      return
    }

    let ready = run.engineReady
    let heartbeatAt = run.lastHeartbeatAt
    if (pod.status === 'RUNNING') {
      const watchdog = await this.heartbeat(podId, id, parseDate(run.runUntil))
      if (watchdog) heartbeatAt = iso(this.now())
      if (watchdog?.telemetry) this.record(id, watchdog.telemetry)
      // The engine died: say why, then end the pod now instead of after the watchdog's grace.
      if (watchdog?.engineAlive === false) {
        const message = (await this.engineFailure(podId, id)) ?? `exit code ${watchdog.engineExitCode ?? '?'}`
        await this.stop(id, 'engine-exited').catch(() => {})
        this.store.updateRun(id, (r) => { r.phase = 'failed'; r.lastReason = 'engine-exited'; r.lastMessage = message })
        return
      }
      if (!ready) ready = await this.engineAnswers(podId, id)
    } else {
      ready = false
      this.samples.delete(id)
    }

    const wasRunning = run.podStatus === 'RUNNING'
    const t = iso(this.now())
    this.store.updateRun(id, (r) => {
      const before = r.phase
      r.podStatus = pod.status
      r.engineReady = ready
      r.lastHeartbeatAt = heartbeatAt ?? null
      if (pod.dataCenterId) r.dataCenterId = pod.dataCenterId
      if (pod.cost && pod.cost > 0) r.pricePerHour = pod.cost
      switch (pod.status) {
        case 'RUNNING': r.phase = ready ? 'ready' : 'loading'; break
        case 'STARTING': case 'PROVISIONING': r.phase = 'loading'; break
        case 'EXITED': case 'TERMINATED':
          if (r.phase !== 'failed') r.phase = 'stopped'
          // Stopped by something other than Podlight: most likely the pod's own watchdog.
          if (wasRunning && before !== 'stopping' && !r.stoppedAt) {
            r.stoppedAt = t
            r.lastReason = r.lastReason ?? 'stopped-outside'
          }
          break
        case 'ERROR': r.phase = 'failed'; r.lastReason = 'pod-error'; break
      }
    })
  }

  private async applyRules(id: string): Promise<void> {
    const model = this.store.model(id)
    if (!model) return
    const run = this.store.run(id)
    const action = decide(model.schedule, {
      status: run.podId ? (run.podStatus ?? null) : null,
      startedAt: parseDate(run.startedAt), lastRequestAt: parseDate(run.lastRequestAt), engineReady: run.engineReady,
      inFlightRequests: this.requestsInFlight(id), startedManually: run.startedManually,
      idleStoppedAt: parseDate(run.idleStoppedAt), paused: false,
    }, this.spend(), { runUntil: parseDate(run.runUntil) }, this.now())
    if (action.do === 'stop') await this.stop(id, action.because).catch((e) => this.log(`stop ${id} failed: ${e}`))
    if (action.do === 'start') await this.start(id, null, false).catch((e) => this.log(`start ${id} failed: ${e}`))
  }

  private async deleteLongStopped(): Promise<void> {
    const days = this.settings.read().deleteStoppedAfterDays
    const cutoff = this.now().getTime() - days * 86_400_000
    const client = this.clientOrNull()
    if (!client) return
    for (const [id, run] of Object.entries(this.store.runs())) {
      if (!run.podId || run.phase !== 'stopped') continue
      const lastUse = Math.max(...[run.stoppedAt, run.lastRequestAt, run.startedAt].map((d) => parseDate(d)?.getTime() ?? 0))
      if (lastUse >= cutoff) continue
      try {
        await client.deletePod(run.podId)
      } catch (error) {
        if (!(error instanceof RunpodError && error.isNotFound)) continue
      }
      this.store.updateRun(id, (r) => { r.podId = null; r.podStatus = null; r.lastReason = 'deleted-unused' })
    }
  }

  /** Adds running time since the last booking to today's spend. */
  private account(id: string, run: ModelRun): void {
    const since = parseDate(run.accountedUntil ?? run.startedAt)
    if (run.podStatus !== 'RUNNING' || run.pricePerHour == null || !since) return
    const t = this.now()
    const cost = (Math.max(0, t.getTime() - since.getTime()) / 3_600_000) * (run.pricePerHour + (run.storagePerHour ?? 0))
    this.store.addSpend(this.today(), cost)
    this.store.updateRun(id, (r) => { r.accountedUntil = iso(t) })
  }

  // MARK: Pod HTTP

  private async podFetch(podId: string, modelId: string, port: number, path: string, init: RequestInit = {}): Promise<Response | null> {
    try {
      return await this.fetchImpl(`${this.podURL(podId, port)}${path}`, {
        ...init,
        headers: { Authorization: `Bearer ${this.podKey(modelId)}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
        signal: AbortSignal.timeout(10_000),
      })
    } catch {
      return null
    }
  }

  private record(id: string, raw: unknown): void {
    const parsed = podTelemetry.safeParse(raw)
    if (!parsed.success) return
    const list = this.samples.get(id) ?? []
    if (list.at(-1)?.time === parsed.data.time) return
    list.push(parsed.data)
    if (list.length > TELEMETRY_SAMPLES) list.splice(0, list.length - TELEMETRY_SAMPLES)
    this.samples.set(id, list)
  }

  /** The latest sample per model whose pod runs. */
  latestTelemetry(): Record<string, PodTelemetry> {
    const latest: Record<string, PodTelemetry> = {}
    for (const [id, list] of this.samples) {
      const last = list.at(-1)
      if (last) latest[id] = last
    }
    return latest
  }

  /** The last 30 minutes of one model's pod, oldest first. */
  telemetry(id: string): PodTelemetry[] {
    return [...(this.samples.get(id) ?? [])]
  }

  private async heartbeat(podId: string, modelId: string, runUntil: Date | null): Promise<{ engineAlive?: boolean; engineExitCode?: number; telemetry?: unknown } | null> {
    const deadline = runUntil ? (runUntil.getTime() + podPlan.DEADLINE_GRACE_MS) / 1000 : null
    const response = await this.podFetch(podId, modelId, podPlan.WATCHDOG_PORT, '/heartbeat', {
      method: 'POST', body: JSON.stringify({ deadline }),
    })
    if (!response || response.status !== 200) return null
    const json = (await response.json().catch(() => ({}))) as { engineAlive?: boolean; engineExitCode?: number; telemetry?: unknown }
    return json
  }

  /** The last lines the engine wrote, kept by the watchdog because RunPod drops a stopped pod's output. */
  private async engineFailure(podId: string, modelId: string): Promise<string | null> {
    const response = await this.podFetch(podId, modelId, podPlan.WATCHDOG_PORT, '/log')
    if (!response || response.status !== 200) return null
    const json = (await response.json().catch(() => null)) as { lines?: string[] } | null
    return json?.lines ? summarizeEngineLog(json.lines) : null
  }

  /** The engine's last log lines, for the app's detail view. */
  async engineLog(id: string): Promise<string[] | null> {
    const run = this.store.run(id)
    if (!run.podId || run.podStatus !== 'RUNNING') return null
    const response = await this.podFetch(run.podId, id, podPlan.WATCHDOG_PORT, '/log')
    if (!response || response.status !== 200) return null
    return ((await response.json().catch(() => null)) as { lines?: string[] } | null)?.lines ?? null
  }

  private async engineAnswers(podId: string, modelId: string): Promise<boolean> {
    const response = await this.podFetch(podId, modelId, podPlan.ENGINE_PORT, '/v1/models')
    return response?.status === 200
  }

  // MARK: Helpers

  client(): RunpodClient {
    const client = this.clientOrNull()
    if (!client) throw new GatewayFailure({ kind: 'missingRunpodKey' })
    return client
  }

  clientOrNull(): RunpodClient | null {
    const key = this.settings.secret('runpodApiKey')
    return key ? new RunpodClient(key, this.fetchImpl, this.runpodBase) : null
  }

  private podKey(id: string): string {
    return this.store.podKey(id, () => generateToken())
  }

  private asFailure(error: unknown): GatewayFailure {
    if (error instanceof GatewayFailure) return error
    if (error instanceof RunpodError) return new GatewayFailure({ kind: 'runpod', status: error.status, message: error.body })
    return new GatewayFailure({ kind: 'runpod', status: 0, message: String(error) })
  }

  /** Current cost per hour of everything running. */
  costPerHour(): number {
    return Object.values(this.store.runs())
      .filter((r) => r.podStatus === 'RUNNING' || r.phase === 'loading' || r.phase === 'ready')
      .reduce((sum, r) => sum + (r.pricePerHour ?? 0), 0)
  }

  settingsSnapshot(): ServerSettings {
    return this.settings.read()
  }
}
