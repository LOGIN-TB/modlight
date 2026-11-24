import { generateToken } from '../crypto.ts'
import { hostingOf, iso, type ModelRun, parseDate, type PodlightModel, podStatus, type PodTelemetry, podTelemetry, type PricedChoice, type ServerSettings } from '../model.ts'
import { allows, dataCenterIds, needsPlacementCheck, StoragePricing } from '../rules/hosting.ts'
import * as podPlan from '../rules/podPlan.ts'
import { admitWake, decide, type Spend } from '../rules/scheduler.ts'
import { engineFailureReason, GatewayFailure, looksDegenerate, summarizeEngineLog } from '../gateway/shape.ts'
import { type AccountBalance, createWithFallback, NoCapacityError, RunpodClient, RunpodError } from '../runpod/client.ts'
import { mayBeAvailable, type Pod, pricePerHour } from '../runpod/types.ts'
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
  /** Tries, and the wait between them, to resume a pod whose machine has no free card. */
  hostBusyTries?: number
  hostBusyDelayMs?: number
  /** While the machine stays busy, the resume is tried again this often, in the background. */
  cardRetryMs?: number
  /** A loading engine with no sign of progress for this long is taken as hung. */
  loadStallMs?: number
  log?: (message: string) => void
}

/** Why a model from a Mac cannot come over; the app shows the message. */
export class AdoptRefused extends Error {
  readonly code: string
  constructor(message: string, code: string) {
    super(message)
    this.code = code
  }
}

/** What the watchdog reports with each heartbeat. `engineLogBytes` grows while the engine works. */
interface WatchdogStatus { engineAlive?: boolean; engineExitCode?: number; engineLogBytes?: number; telemetry?: unknown }

/** How long a start that a request woke waits for a busy machine's card. */
const WOKEN_WAIT_FOR_CARD_MS = 30 * 60_000
/** A start waiting for a card: to resume a pod, or a new pod within a price. */
type WaitingForCard = NonNullable<ModelRun['waitingForCard']>

/** What shows a loading engine at work. Sizes in 64 MB steps, so small noise does not count. */
export function loadSignature(t: PodTelemetry, logBytes: number | null): string {
  const step = 64 * 1_048_576
  const stored = [t.diskUsedBytes, t.volumeUsedBytes].filter((v): v is number => typeof v === 'number')
  const gpu = (t.gpus ?? []).map((g) => g.memoryUsedBytes).filter((v): v is number => typeof v === 'number')
  return JSON.stringify([
    stored.length ? Math.floor(stored.reduce((a, b) => a + b, 0) / step) : null,
    gpu.length ? Math.floor(gpu.reduce((a, b) => a + b, 0) / step) : null,
    logBytes,
  ])
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

  private readonly hostBusyTries: number
  private readonly hostBusyDelayMs: number
  private readonly cardRetryMs: number
  private readonly loadStallMs: number
  /** What a loading pod last showed of its progress, and since when (ms), per model. In memory. */
  private readonly loadProgress = new Map<string, { signature: string; since: number }>()

  constructor(o: ManagerOptions) {
    this.hostBusyTries = Math.max(1, o.hostBusyTries ?? 5)
    this.hostBusyDelayMs = o.hostBusyDelayMs ?? 15_000
    this.cardRetryMs = o.cardRetryMs ?? 30_000
    this.loadStallMs = o.loadStallMs ?? 600_000
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

  // MARK: Account balance

  private balanceCache: (AccountBalance & { checkedAt: string }) | null = null
  private balanceFetch: Promise<void> | null = null

  /**
   * The RunPod account's credit as last read, at most a minute old in use: an older answer is
   * returned as it is and a new one fetched in the background, so /admin/state never waits on it.
   */
  balance(): (AccountBalance & { checkedAt: string }) | null {
    const checked = this.balanceCache ? Date.parse(this.balanceCache.checkedAt) : 0
    if (this.now().getTime() - checked >= 60_000) void this.refreshBalance()
    return this.balanceCache
  }

  /** Another RunPod key: the old account's balance is not this one's. */
  accountChanged(): void {
    this.balanceCache = null
    void this.refreshBalance()
  }

  refreshBalance(): Promise<void> {
    this.balanceFetch ??= (async () => {
      const client = this.clientOrNull()
      if (!client) { this.balanceCache = null; return }
      try {
        this.balanceCache = { ...(await client.balance()), checkedAt: iso(this.now()) }
      } catch (error) {
        this.log(`balance: ${error}`)
      }
    })().finally(() => { this.balanceFetch = null })
    return this.balanceFetch
  }

  // MARK: Models

  save(model: PodlightModel): void {
    this.store.saveModel({ ...model, schedule: { ...model.schedule, idleStopMinutes: Math.max(5, model.schedule.idleStopMinutes) } })
  }

  /**
   * Takes a model over from a Mac, with its pod (running or stopped with its disk) and the pod's
   * key, so nothing is downloaded again. The pod is renamed to a server pod: the Mac sees that
   * and lets go, other Macs no longer offer it. Without a pod (or one RunPod no longer has) only
   * the model comes over.
   */
  async adopt(model: PodlightModel, podKey: string, podId: string | null): Promise<void> {
    if (this.store.model(model.id)) throw new AdoptRefused('This model is already on the server.', 'already_here')
    let pod: Pod | null = null
    const client = podId ? this.client() : null
    if (client && podId) {
      try {
        pod = await client.pod(podId)
      } catch (error) {
        if (!(error instanceof RunpodError && error.isNotFound)) throw this.asFailure(error)
      }
      if (pod?.status === 'TERMINATED') pod = null
    }
    if (pod) {
      if (!pod.name.startsWith('podlight-') || pod.name.startsWith('podlight-srv-')) {
        throw new AdoptRefused('That pod was not created by Podlight on a Mac.', 'not_a_mac_pod')
      }
      if (!['RUNNING', 'EXITED'].includes(pod.status)) {
        throw new AdoptRefused('The pod is starting or stopping. Try again when it runs or has stopped.', 'pod_busy')
      }
      // The server deletes pods outside its region at once; it must not do that to a disk it was given.
      const hosting = model.hosting ?? hostingOf(this.settings.read())
      if ((needsPlacementCheck(hosting) && !pod.dataCenterId) || (pod.dataCenterId && !allows(hosting, pod.dataCenterId))) {
        throw new AdoptRefused(`The pod is in ${pod.dataCenterId ?? 'an unknown data center'}, outside the server's region. Allow that region for the model or on the server first.`, 'outside_region')
      }
    }

    this.save(model) // Throws NameTakenError on a name clash, before anything changes at RunPod.
    this.store.setPodKey(model.id, podKey)
    if (!pod || !client) return

    try {
      await client.rename(pod.id, `podlight-srv-${model.name}`.slice(0, 60))
    } catch (error) {
      this.store.removeModel(model.id)
      throw this.asFailure(error)
    }
    const catalog = await client.gpuCatalog().catch(() => [])
    const t = iso(this.now())
    const running = pod.status === 'RUNNING'
    const count = pod.gpu?.count ?? 1
    const cardName = catalog.find((g) => g.id === pod.gpu?.id)?.name ?? pod.gpu?.id ?? null
    const volume = pod.mounts?.persistent?.size ?? null
    const container = pod.disk ?? null
    const adopted = pod
    this.store.updateRun(model.id, (r) => {
      r.podId = adopted.id
      r.podStatus = adopted.status
      r.phase = running ? 'loading' : 'stopped'
      r.gpu = adopted.gpu ? { gpuId: adopted.gpu.id, cloud: adopted.cloud ?? 'COMMUNITY', count } : (model.preferredGPU ?? null)
      r.gpuName = cardName ? (count > 1 ? `${count} × ${cardName}` : cardName) : null
      r.pricePerHour = adopted.cost ?? model.expectedPricePerHour ?? null
      r.persistentGB = volume
      r.containerGB = container
      r.storagePerHour = StoragePricing.runningPerHour(container ?? 0, volume ?? 0)
      r.dataCenterId = adopted.dataCenterId ?? null
      // Costs, idle stop and deletion of unused pods count from now on the server.
      r.startedAt = running ? t : null
      r.accountedUntil = t
      r.storageAccountedUntil = t
      r.lastRequestAt = t
      r.stoppedAt = running ? null : t
      r.lastReason = 'handed-over'
    })
    this.log(`took over ${model.name} with pod ${adopted.id} from a Mac`)
    if (running) await this.refresh(model.id)
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

  /** Resumes a stopped pod, trying again for about a minute while its machine has no free card. */
  private async resumeWaitingForHost(client: RunpodClient, podId: string): Promise<Pod> {
    for (let attempt = 1; ; attempt++) {
      try {
        return await client.action(podId, 'start')
      } catch (error) {
        if (!(error instanceof RunpodError && error.isHostGpuUnavailable) || attempt >= this.hostBusyTries) throw error
        await new Promise((resolve) => setTimeout(resolve, this.hostBusyDelayMs))
      }
    }
  }

  /** Starts (or resumes) a model's pod. Returns once RunPod has accepted it. `newPod`: the user
   * chose a new card for a pod whose machine is busy; only then is a stopped pod deleted. */
  start(id: string, runUntil: Date | null, manual = true, newPod = false, maxPricePerHour: number | null = null,
    retrying: WaitingForCard | null = null): Promise<void> {
    const running = this.starts.get(id)
    if (running) return running
    const task = this.performStart(id, runUntil, manual, newPod, maxPricePerHour, retrying).finally(() => this.starts.delete(id))
    this.starts.set(id, task)
    return task
  }

  private async performStart(id: string, runUntil: Date | null, manual: boolean, newPod: boolean,
    maxPricePerHour: number | null, retrying: WaitingForCard | null): Promise<void> {
    const model = this.store.model(id)
    if (!model) throw new GatewayFailure({ kind: 'unknownModel' })
    const wake = admitWake(this.spend())
    if (!wake.admit) throw new GatewayFailure({ kind: 'limitReached', limit: wake.because })
    const client = this.client()
    const settings = this.settings.read()
    const podKey = this.podKey(id)
    const run = this.store.run(id)
    // A new start ends any waiting for the old machine's card.
    if (run.waitingForCard) this.store.updateRun(id, (r) => { r.waitingForCard = null })

    if (newPod && run.podId) {
      // The old pod and its disk stay until the new pod answers; if the new one fails, the old one
      // is put back. A failed earlier replacement is deleted, its original kept.
      if (run.replacing) {
        try {
          await client.deletePod(run.podId)
        } catch (error) {
          if (!(error instanceof RunpodError && error.isNotFound)) throw this.asFailure(error)
        }
      }
      const replaced = run.replacing ?? {
        podId: run.podId, gpu: run.gpu, gpuName: run.gpuName, pricePerHour: run.pricePerHour, persistentGB: run.persistentGB,
        containerGB: run.containerGB, storagePerHour: run.storagePerHour, dataCenterId: run.dataCenterId, hosting: run.hosting,
      }
      this.store.updateRun(id, (r) => { r.replacing = replaced; r.podId = null; r.podStatus = null; r.persistentGB = null })
      run.podId = null
    }

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
        // Resume with this version's start script and watchdog, not the ones it was made with.
        const fresh = pod.env ? podPlan.freshenedEnv(pod.env, runUntil) : null
        if (fresh) await client.updateEnv(run.podId, fresh).catch(() => {})
        const resumed = await this.resumeWaitingForHost(client, run.podId)
        this.markStarted(id, resumed, runUntil, manual, true)
        return
      } catch (error) {
        if (error instanceof RunpodError && error.isHostGpuUnavailable) {
          // Its machine gave the card away. The pod and its disk stay: deleting them would throw
          // away the downloaded model long before its deletion date. The server keeps trying in
          // the background until the run's end; the user may start on a new card.
          const t = this.now()
          const waiting = {
            until: iso(runUntil ?? new Date(t.getTime() + WOKEN_WAIT_FOR_CARD_MS)),
            runUntil: runUntil ? iso(runUntil) : null, manual, lastTryAt: iso(t),
          }
          this.store.updateRun(id, (r) => { r.phase = 'stopped'; r.lastReason = 'host-busy'; r.lastMessage = null; r.waitingForCard = waiting })
          throw new GatewayFailure({ kind: 'hostBusy' })
        }
        if (error instanceof RunpodError && error.isNotFound) {
          // Gone: build a new one from the same model.
          this.store.updateRun(id, (r) => { r.podId = null })
        } else if (error instanceof RunpodError) {
          this.fail(id, error)
          throw this.asFailure(error)
        } else {
          throw error
        }
      }
    }

    try {
      await this.createPod(id, model, client, podKey, runUntil, manual, maxPricePerHour, retrying)
    } catch (error) {
      // No new pod came of it: a replaced pod is the model's pod again.
      this.putBackReplacedPod(id)
      throw error
    }
  }

  private async createPod(id: string, model: PodlightModel, client: RunpodClient, podKey: string, runUntil: Date | null, manual: boolean,
    maxPricePerHour: number | null, retrying: WaitingForCard | null): Promise<void> {
    const settings = this.settings.read()
    this.store.updateRun(id, (r) => { r.phase = 'creating'; r.lastReason = null; r.lastMessage = null; r.fellBackFrom = null })
    let priced: podPlan.PriceGuard | null = null
    let offered: PricedChoice[] = []
    try {
      const catalog = await client.gpuCatalog()
      const hosting = model.hosting ?? hostingOf(settings)
      const choices = podPlan.choices(model, catalog, hosting)
      if (choices.length === 0) throw new GatewayFailure({ kind: 'noSuitableCard' })
      const request = podPlan.request(model, {
        podKey, huggingFaceToken: this.settings.secret('huggingFaceToken'), runUntil,
        heartbeatMinutes: settings.heartbeatMinutes, dataCenterIds: dataCenterIds(hosting, catalog), namePrefix: 'podlight-srv-',
      })
      // Fallbacks up to the price step only; pricier cards that may be free are offered.
      const guarded = podPlan.priceGuard(choices, catalog, settings.fallbackPriceStepPercent, maxPricePerHour)
      priced = guarded
      const byId = new Map(catalog.map((g) => [g.id, g]))
      offered = guarded.above.filter((o) => mayBeAvailable(byId.get(o.choice.gpuId)?.availability))
      const created = await createWithFallback(client, request, guarded.within, catalog)
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
        r.wantedPricePerHour = created.attempts[0]?.outcome !== 'created' ? (guarded.wanted?.pricePerHour ?? null) : null
      })
      this.markStarted(id, created.pod, runUntil, manual, false)
    } catch (error) {
      if (error instanceof NoCapacityError) {
        const tried = error.attempts.map((a) => a.choice.gpuId)
        const ceiling = priced?.ceiling ?? null
        // Nothing booked. Without a replaced pod to put back, keep trying within the price until
        // the run's end (half an hour for a woken one), as for a busy machine.
        if (ceiling != null && (offered.length > 0 || retrying)) {
          const canWait = !this.store.run(id).replacing
          const waiting: WaitingForCard = {
            until: retrying?.until ?? iso(runUntil ?? new Date(this.now().getTime() + WOKEN_WAIT_FOR_CARD_MS)),
            runUntil: runUntil ? iso(runUntil) : null, manual, lastTryAt: iso(this.now()),
            maxPricePerHour: ceiling, wanted: priced?.wanted ?? null, pricier: offered,
          }
          this.store.updateRun(id, (r) => {
            r.phase = 'stopped'; r.lastReason = 'card-too-expensive'; r.lastMessage = tried.join(', ')
            r.waitingForCard = canWait ? waiting : null
          })
          if (offered.length === 0) throw new GatewayFailure({ kind: 'noCapacity', tried })
          throw new GatewayFailure({ kind: 'cardTooExpensive', wanted: priced?.wanted ?? null, ceiling, pricier: offered })
        }
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

  private markStarted(id: string, pod: Pod, runUntil: Date | null, manual: boolean, resumed: boolean): void {
    const t = iso(this.now())
    this.loadProgress.delete(id)
    this.store.updateRun(id, (r) => {
      r.resumed = resumed
      r.waitingForCard = null
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
    // Stopping a start that waits for its machine's card just ends the waiting.
    if (run.waitingForCard) {
      this.store.updateRun(id, (r) => { r.waitingForCard = null })
      if (run.phase === 'stopped' || run.phase === 'failed') return
    }
    if (!run.podId) return
    this.account(id, run)
    this.loadProgress.delete(id)
    if (run.replacing) {
      // A new pod that never answered ends by being deleted; the old pod with the downloaded model
      // is the model's pod again.
      this.store.updateRun(id, (r) => { r.phase = 'stopping' })
      try {
        await this.client().deletePod(run.podId)
      } catch (error) {
        if (!(error instanceof RunpodError && error.isNotFound)) {
          if (error instanceof RunpodError) this.fail(id, error)
          throw this.asFailure(error)
        }
      }
      this.putBackReplacedPod(id)
      this.markStopped(id, 'EXITED', reason)
      this.log(`stopped ${id}: ${reason}; the replaced pod is back`)
      return
    }
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
      await this.retryWaitingStarts()
      await this.deleteReplacedPods()
      await this.deleteLongStopped()
      this.accountStoredDisks()
    } finally {
      this.ticking = false
    }
  }

  /** The old pod of a "Start on a New Card" whose new pod answered, and its disk, are deleted. */
  private async deleteReplacedPods(): Promise<void> {
    const client = this.clientOrNull()
    if (!client) return
    for (const [id, run] of Object.entries(this.store.runs())) {
      if (!run.oldPodToDelete) continue
      try {
        await client.deletePod(run.oldPodToDelete)
      } catch (error) {
        if (!(error instanceof RunpodError && error.isNotFound)) continue
      }
      this.store.updateRun(id, (r) => { r.oldPodToDelete = null })
    }
  }

  /** Puts the pod a "Start on a New Card" replaced back as the model's pod. */
  private putBackReplacedPod(id: string): void {
    const replaced = this.store.run(id).replacing
    if (!replaced) return
    this.store.updateRun(id, (r) => {
      Object.assign(r, {
        podId: replaced.podId, gpu: replaced.gpu, gpuName: replaced.gpuName, pricePerHour: replaced.pricePerHour,
        persistentGB: replaced.persistentGB, containerGB: replaced.containerGB, storagePerHour: replaced.storagePerHour,
        dataCenterId: replaced.dataCenterId, hosting: replaced.hosting,
      })
      r.podStatus = 'EXITED'; r.engineReady = false; r.replacing = null
    })
  }

  /** Tries again to resume the pods whose machine had no free card, until each run's end. */
  private async retryWaitingStarts(): Promise<void> {
    const t = this.now()
    for (const [id, run] of Object.entries(this.store.runs())) {
      const waiting = run.waitingForCard
      if (!waiting) continue
      if (!run.podId && waiting.maxPricePerHour != null) {
        await this.retryAffordableStart(id, run, waiting, t)
        continue
      }
      const until = parseDate(waiting.until)
      if (!run.podId || (run.phase !== 'stopped' && run.phase !== 'failed') || !until || t >= until || !admitWake(this.spend()).admit) {
        this.store.updateRun(id, (r) => { r.waitingForCard = null })
        continue
      }
      const last = parseDate(waiting.lastTryAt)
      if (last && t.getTime() - last.getTime() < this.cardRetryMs) continue
      const client = this.clientOrNull()
      if (!client) return
      try {
        const pod = await client.action(run.podId, 'start')
        this.store.updateRun(id, (r) => { r.lastReason = null })
        this.markStarted(id, pod, parseDate(waiting.runUntil), waiting.manual, true)
      } catch (error) {
        if (error instanceof RunpodError && error.isHostGpuUnavailable) {
          this.store.updateRun(id, (r) => { if (r.waitingForCard) r.waitingForCard.lastTryAt = iso(t) })
        } else if (error instanceof RunpodError && error.isNotFound) {
          this.store.updateRun(id, (r) => { r.waitingForCard = null; r.podId = null; r.podStatus = null; r.lastReason = 'pod-gone' })
        } else if (error instanceof RunpodError) {
          this.store.updateRun(id, (r) => { r.waitingForCard = null })
          this.fail(id, error)
        } else {
          // RunPod unreachable: try again next time.
          this.store.updateRun(id, (r) => { if (r.waitingForCard) r.waitingForCard.lastTryAt = iso(t) })
        }
      }
    }
  }

  /** A new pod waiting for a card within its price: tried again every 30 seconds until its end. */
  private async retryAffordableStart(id: string, run: ModelRun, waiting: WaitingForCard, t: Date): Promise<void> {
    const until = parseDate(waiting.until)
    if ((run.phase !== 'stopped' && run.phase !== 'failed') || !until || t >= until || !this.store.model(id) || !admitWake(this.spend()).admit) {
      this.store.updateRun(id, (r) => { r.waitingForCard = null })
      return
    }
    const last = parseDate(waiting.lastTryAt)
    if (last && t.getTime() - last.getTime() < this.cardRetryMs) return
    try {
      await this.start(id, parseDate(waiting.runUntil), waiting.manual, false, waiting.maxPricePerHour ?? null, waiting)
    } catch (error) {
      if (error instanceof GatewayFailure && (error.error.kind === 'cardTooExpensive' || error.error.kind === 'noCapacity')) return
      // RunPod unreachable or refused: keep waiting unless the start ended it.
      const now = this.store.run(id)
      if (!now.waitingForCard && now.phase !== 'failed') {
        this.store.updateRun(id, (r) => { r.waitingForCard = { ...waiting, lastTryAt: iso(t) } })
      }
    }
  }

  /** Notes what a loading pod shows. True once it has shown no progress for `loadStallMs`. Without
   * telemetry (a watchdog from before 0.5) nothing is decided. */
  private noteLoadProgress(id: string, status: { engineLogBytes?: number; telemetry?: unknown }): boolean {
    const parsed = podTelemetry.safeParse(status.telemetry)
    if (!status.telemetry || !parsed.success) return false
    const signature = loadSignature(parsed.data, status.engineLogBytes ?? null)
    const t = this.now().getTime()
    const busy = (parsed.data.cpuPercent ?? 0) >= 1
    const seen = this.loadProgress.get(id)
    if (!seen || seen.signature !== signature || busy) {
      this.loadProgress.set(id, { signature, since: t })
      return false
    }
    return t - seen.since >= this.loadStallMs
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
      if (error instanceof RunpodError && error.isNotFound) this.podGone(id, podId)
      return // RunPod unreachable: keep what we know, try again next tick.
    }
    if (pod.status === 'TERMINATED') return this.podGone(id, podId)

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
        const lines = await this.engineLogLines(podId, id)
        const message = lines ? summarizeEngineLog(lines) : `exit code ${watchdog.engineExitCode ?? '?'}`
        const reason = engineFailureReason(lines ?? [])
        await this.stop(id, reason).catch(() => {})
        this.store.updateRun(id, (r) => { r.phase = 'failed'; r.lastReason = reason; r.lastMessage = message })
        return
      }
      // A loading engine that shows no progress at all (no download, no log line, no GPU memory, no
      // CPU) has hung, often on a stalled download. It would bill until the run's end.
      if (!ready && watchdog && this.noteLoadProgress(id, watchdog)) {
        const lines = await this.engineLogLines(podId, id)
        const last = lines?.filter((l) => l.trim()).at(-1)?.trim().slice(0, 200) ?? null
        await this.stop(id, 'engine-stuck').catch(() => {})
        this.store.updateRun(id, (r) => { r.phase = 'failed'; r.lastReason = 'engine-stuck'; r.lastMessage = last })
        return
      }
      if (!ready && (await this.engineAnswers(podId, id))) {
        // Start test: a model that only repeats one character (a broken quantisation or kernel)
        // would make every agent request run to its length limit.
        const model = this.store.model(id)
        const garbage = model ? await this.garbageAnswer(podId, id, model.name) : null
        if (garbage !== null) {
          await this.stop(id, 'garbage-output').catch(() => {})
          this.store.updateRun(id, (r) => { r.phase = 'failed'; r.lastReason = 'garbage-output'; r.lastMessage = `"${garbage.slice(0, 40)}…"` })
          return
        }
        ready = true
        this.loadProgress.delete(id)
        // The new pod of a "Start on a New Card" answers: the old pod can go.
        const replaced = this.store.run(id).replacing
        if (replaced) {
          this.store.updateRun(id, (r) => { r.replacing = null; r.oldPodToDelete = replaced.podId })
          await this.deleteReplacedPods()
        }
      }
    } else {
      ready = false
      this.samples.delete(id)
      this.loadProgress.delete(id)
    }

    const wasRunning = run.podStatus === 'RUNNING'
    const t = iso(this.now())
    this.store.updateRun(id, (r) => {
      if (r.podId !== podId) return // Gone or replaced while we asked.
      const before = r.phase
      // A status RunPod added since: keep the last known one rather than guess.
      if (podStatus.safeParse(pod.status).success) r.podStatus = pod.status
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

  /** RunPod no longer has the pod (deleted, at RunPod or by Podlight): the run lets go of it. */
  private podGone(id: string, podId: string): void {
    const run = this.store.run(id)
    if (run.podId !== podId) return // Someone else got here first.
    this.account(id, run)
    this.loadProgress.delete(id)
    this.samples.delete(id)
    this.store.updateRun(id, (r) => { r.podId = null; r.podStatus = null; r.engineReady = false; r.phase = 'stopped'; r.lastReason = 'pod-gone' })
    this.putBackReplacedPod(id)
  }

  private reconciling: Promise<void> | null = null

  /**
   * Compares the stored pods with RunPod's list and lets go of every pod RunPod no longer has.
   * One list request plus a check per missing pod (the list can lag behind a new pod), and it
   * never waits for a start or a start test, so a deleted pod is gone within seconds.
   */
  reconcile(): Promise<void> {
    this.reconciling ??= (async () => {
      const client = this.clientOrNull()
      if (!client) return
      let listed: Map<string, Pod>
      try {
        listed = new Map((await client.listPods()).map((p) => [p.id, p]))
      } catch {
        return // RunPod unreachable: the next round tries again.
      }
      for (const model of this.store.models()) {
        const podId = this.store.run(model.id).podId
        if (!podId) continue
        const pod = listed.get(podId)
        if (pod && pod.status !== 'TERMINATED') continue
        if (pod?.status === 'TERMINATED') { this.podGone(model.id, podId); continue }
        try {
          const fresh = await client.pod(podId)
          if (fresh.status === 'TERMINATED') this.podGone(model.id, podId)
        } catch (error) {
          if (error instanceof RunpodError && error.isNotFound) this.podGone(model.id, podId)
        }
      }
    })().finally(() => { this.reconciling = null })
    return this.reconciling
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
      // A failed start keeps its stopped pod too (with a kept disk); it counts like a stopped one.
      if (!run.podId || (run.phase !== 'stopped' && run.phase !== 'failed')) continue
      const dates = [run.stoppedAt, run.lastRequestAt, run.startedAt].map((d) => parseDate(d)?.getTime()).filter((t): t is number => t !== undefined)
      // A stopped pod with no date at all starts its clock now instead of counting as ancient.
      if (dates.length === 0) { this.store.updateRun(id, (r) => { r.stoppedAt = iso(this.now()) }); continue }
      const lastUse = Math.max(...dates)
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

  private async podFetch(podId: string, modelId: string, port: number, path: string, init: RequestInit = {}, timeoutMs = 10_000): Promise<Response | null> {
    try {
      return await this.fetchImpl(`${this.podURL(podId, port)}${path}`, {
        ...init,
        headers: { Authorization: `Bearer ${this.podKey(modelId)}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
        signal: AbortSignal.timeout(timeoutMs),
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

  private async heartbeat(podId: string, modelId: string, runUntil: Date | null): Promise<WatchdogStatus | null> {
    const deadline = runUntil ? (runUntil.getTime() + podPlan.DEADLINE_GRACE_MS) / 1000 : null
    const response = await this.podFetch(podId, modelId, podPlan.WATCHDOG_PORT, '/heartbeat', {
      method: 'POST', body: JSON.stringify({ deadline }),
    })
    if (!response || response.status !== 200) return null
    return (await response.json().catch(() => ({}))) as WatchdogStatus
  }

  /** The last lines the engine wrote, kept by the watchdog because RunPod drops a stopped pod's output. */
  private async engineLogLines(podId: string, modelId: string): Promise<string[] | null> {
    const response = await this.podFetch(podId, modelId, podPlan.WATCHDOG_PORT, '/log')
    if (!response || response.status !== 200) return null
    const json = (await response.json().catch(() => null)) as { lines?: string[] } | null
    return json?.lines ?? null
  }

  /** The engine's last log lines, for the app's detail view. */
  async engineLog(id: string): Promise<string[] | null> {
    const run = this.store.run(id)
    if (!run.podId || run.podStatus !== 'RUNNING') return null
    const response = await this.podFetch(run.podId, id, podPlan.WATCHDOG_PORT, '/log')
    if (!response || response.status !== 200) return null
    return ((await response.json().catch(() => null)) as { lines?: string[] } | null)?.lines ?? null
  }

  /** The model's answer to one short question when that answer is degenerate; null when it is fine
   * or the test could not run (the start is never held up by the test). */
  private async garbageAnswer(podId: string, modelId: string, name: string): Promise<string | null> {
    for (const withKwargs of [true, false]) {
      const body: Record<string, unknown> = {
        model: name, max_tokens: 48, temperature: 0, messages: [{ role: 'user', content: 'Reply with one word: ready' }],
      }
      // Without thinking, so a reasoning model answers within the few tokens allowed.
      if (withKwargs) body.chat_template_kwargs = { enable_thinking: false }
      const response = await this.podFetch(podId, modelId, podPlan.ENGINE_PORT, '/v1/chat/completions',
        { method: 'POST', body: JSON.stringify(body) }, 60_000)
      if (!response) return null
      if (response.status === 400 && withKwargs) continue
      if (response.status !== 200) return null
      const json = (await response.json().catch(() => null)) as { choices?: Array<{ message?: Record<string, unknown> }> } | null
      const message = json?.choices?.[0]?.message
      if (!message) return null
      const text = ['content', 'reasoning_content', 'reasoning'].map((k) => message[k]).filter((v): v is string => typeof v === 'string').join('')
      return looksDegenerate(text) ? text : null
    }
    return null
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

  /** Current cost per hour of everything running: the GPU and the pod's storage. */
  costPerHour(): number {
    return Object.values(this.store.runs())
      .filter((r) => r.podStatus === 'RUNNING' || r.phase === 'loading' || r.phase === 'ready')
      .reduce((sum, r) => sum + (r.pricePerHour == null ? 0 : r.pricePerHour + (r.storagePerHour ?? 0)), 0)
  }

  settingsSnapshot(): ServerSettings {
    return this.settings.read()
  }
}
