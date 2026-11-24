import { strict as assert } from 'node:assert'
import { randomBytes } from 'node:crypto'
import { createServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { after, before, beforeEach, describe, test } from 'node:test'
import { buildServer, type Server } from '../src/app.ts'
import { sealer } from '../src/crypto.ts'
import { openDatabase } from '../src/store/db.ts'
import { POD_SCRIPTS } from '../src/rules/podPlan.ts'

// The server end to end, against a fake RunPod and a fake pod (engine on one port, watchdog on
// another). Nothing here reaches the internet.

interface Recorded { method: string; path: string; body: any }

interface FakeRunpodPod {
  id: string; name: string; status: string; cost: number; dataCenterId: string | null; env: Record<string, string>
  gpu?: { id: string; count: number }; disk?: number; mounts?: { persistent?: { size: number } }
}

class FakeRunPod {
  requests: Recorded[] = []
  /** Resumes refused with "not enough free GPUs on the host machine" before one succeeds. */
  hostBusyFor = 0
  pods = new Map<string, FakeRunpodPod>()
  /** What POST /graphql answers for `myself`; null answers with a GraphQL error. */
  balance: { clientBalance: number; currentSpendPerHr: number; spendLimit: number } | null = { clientBalance: 42.5, currentSpendPerHr: 0.86, spendLimit: 80 }
  /** Pod ids GET /v2/pods leaves out, as RunPod's list can lag. */
  hiddenFromList = new Set<string>()
  /** Responses to POST /v2/pods, in order; `capacity` answers RunPod's "no instances" 400. */
  createScript: Array<'ok' | 'capacity'> = []
  /** Card ids without a free machine: creating a pod on them answers "no instances". */
  taken = new Set<string>()
  dataCenterId: string | null = 'EU-RO-1'
  catalog = {
    gpus: [
      { id: 'NVIDIA L40S', name: 'L40S', manufacturer: 'NVIDIA', memory: 48, secure: true, community: true,
        price: { secure: 0.86, community: 0.79 }, availability: 'LOW', maxCount: { secure: 8, community: 8 },
        dataCenters: [{ id: 'EU-RO-1', availability: 'LOW' }, { id: 'US-TX-3', availability: 'LOW' }] },
      { id: 'NVIDIA RTX A6000', name: 'RTX A6000', manufacturer: 'NVIDIA', memory: 48, secure: true, community: true,
        price: { secure: 0.49, community: 0.33 }, availability: 'LOW', maxCount: { secure: 8, community: 8 } },
    ],
  }
  private counter = 0

  handle = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const chunks: Buffer[] = []
    for await (const chunk of req) chunks.push(chunk as Buffer)
    const text = Buffer.concat(chunks).toString('utf8')
    const body = text ? JSON.parse(text) : null
    const path = req.url ?? ''
    this.requests.push({ method: req.method ?? '', path, body })
    const json = (status: number, value: unknown): void => {
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end(value === undefined ? '' : JSON.stringify(value))
    }
    if (path.startsWith('/v2/catalog/gpus')) return json(200, this.catalog)
    if (req.method === 'GET' && (path === '/v2/pods' || path.startsWith('/v2/pods?'))) {
      return json(200, { pods: [...this.pods.values()].filter((p) => !this.hiddenFromList.has(p.id)) })
    }
    if (req.method === 'POST' && path === '/graphql') {
      return this.balance ? json(200, { data: { myself: this.balance } }) : json(200, { errors: [{ message: 'not allowed' }] })
    }
    if (req.method === 'POST' && path === '/v2/pods') {
      const step = this.taken.has(body.gpu?.id) ? 'capacity' : (this.createScript.shift() ?? 'ok')
      if (step === 'capacity') {
        return json(400, { detail: 'There are no longer any instances available with the requested specifications.', status: 400 })
      }
      const id = `pod${++this.counter}`
      const pod: FakeRunpodPod = { id, name: body.name, status: 'RUNNING', cost: 0.86, dataCenterId: this.dataCenterId, env: body.env }
      this.pods.set(id, pod)
      return json(201, pod)
    }
    const match = /^\/v2\/pods\/([^/]+)(\/action)?$/.exec(path)
    if (match) {
      const pod = this.pods.get(match[1]!)
      if (!pod) return json(404, { error: 'pod not found' })
      if (req.method === 'DELETE') { this.pods.delete(pod.id); return json(204, undefined) }
      if (req.method === 'PATCH') { if (body.env) pod.env = body.env; if (body.name) pod.name = body.name; return json(200, pod) }
      if (match[2]) {
        if (body.action === 'start' && this.hostBusyFor > 0) {
          this.hostBusyFor--
          return json(400, { detail: 'There are not enough free GPUs on the host machine to start this pod.', status: 400 })
        }
        pod.status = body.action === 'stop' ? 'EXITED' : 'RUNNING'
        return json(200, pod)
      }
      return json(200, pod)
    }
    json(404, { error: `unhandled ${req.method} ${path}` })
  }
}

/** One fake pod for every pod id: engine and watchdog, recording what reached them. */
class FakePod {
  engineRequests: Array<{ path: string; headers: Record<string, string | string[] | undefined>; body: any }> = []
  heartbeats: any[] = []
  heartbeatKeys: string[] = []
  engineAlive = true
  /** Answers like RunPod's proxy before it routes to the pod: 404, no JSON. */
  proxyNotReadyFor = 0
  /** Set when a slow stream was cut off by the other side. */
  slowStreamAborted = false
  /** Telemetry the watchdog reports; each heartbeat is a new sample. */
  telemetryTime = 1_800_000_000
  /** Start tests seen, and whether the engine answers them with "!!!!…" (a broken model). */
  startTests = 0
  garbage = false
  /** The engine is still loading: /v1/models does not answer yet. */
  loading = false
  /** What the watchdog says of its warm-up; null leaves the field out, as before 0.9.1. */
  warm: boolean | null = null
  /** The loading engine has hung: no CPU, and log, disks and GPU memory stand still. */
  stuck = false

  engine = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const chunks: Buffer[] = []
    for await (const chunk of req) chunks.push(chunk as Buffer)
    const text = Buffer.concat(chunks).toString('utf8')
    if (req.url === '/v1/models') {
      if (this.loading || this.stuck) { res.writeHead(503); return void res.end('loading') }
      res.writeHead(200, { 'content-type': 'application/json' })
      return void res.end('{"data":[]}')
    }
    if (text.includes('Reply with one word: ready')) {
      this.startTests += 1
      res.writeHead(200, { 'content-type': 'application/json' })
      return void res.end(JSON.stringify({ choices: [{ message: { content: this.garbage ? '!'.repeat(48) : 'ready' }, finish_reason: 'stop' }] }))
    }
    if (this.proxyNotReadyFor > 0) {
      this.proxyNotReadyFor -= 1
      res.writeHead(404, { 'content-type': 'text/plain' })
      return void res.end('')
    }
    const body = text ? JSON.parse(text) : null
    this.engineRequests.push({ path: req.url ?? '', headers: req.headers, body })
    if (body?.slow) {
      res.writeHead(200, { 'content-type': 'text/event-stream' })
      const timer = setInterval(() => res.write('data: {"x":1}\n\n'), 50)
      res.on('close', () => { clearInterval(timer); if (!res.writableFinished) this.slowStreamAborted = true })
      return
    }
    if (req.url?.startsWith('/v1/messages')) {
      res.writeHead(200, { 'content-type': 'text/event-stream' })
      res.write('event: ping\ndata: {"type":"ping"}\n\n')
      res.write('event: message_stop\ndata: {"type":"message_stop"}\n\n')
      return void res.end()
    }
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ choices: [{ message: { content: 'hello from the pod' } }] }))
  }

  watchdog = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const chunks: Buffer[] = []
    for await (const chunk of req) chunks.push(chunk as Buffer)
    if (req.url === '/heartbeat') {
      this.heartbeats.push(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'))
      this.heartbeatKeys.push(String(req.headers.authorization ?? ''))
    }
    res.writeHead(200, { 'content-type': 'application/json' })
    if (req.url === '/log') return void res.end(JSON.stringify({ lines: ['loading', 'torch.OutOfMemoryError: CUDA out of memory'] }))
    const telemetry = { time: this.telemetryTime++, cpuPercent: 12.5, gpus: [{ index: 0, name: 'NVIDIA A40', utilPercent: 87, memoryUsedBytes: 4.5e10, memoryTotalBytes: 4.8e10, temperatureC: 55, powerW: 250.3, powerLimitW: null }],
      engine: { running: 2, waiting: 0, kvCachePercent: 41.5, generationTokensPerSecond: 58 } }
    if (this.stuck) {
      const still = { time: this.telemetryTime++, cpuPercent: 0, diskUsedBytes: 1.6e7, volumeUsedBytes: 2.1e10, gpus: [{ memoryUsedBytes: 4e6 }] }
      return void res.end(JSON.stringify({ engineAlive: true, engineExitCode: null, engineLogBytes: 300, telemetry: still }))
    }
    res.end(JSON.stringify({ engineAlive: this.engineAlive, engineExitCode: this.engineAlive ? null : 1, ...(this.warm === null ? {} : { engineWarm: this.warm }), telemetry }))
  }
}

async function listen(handler: (req: IncomingMessage, res: ServerResponse) => Promise<void>): Promise<{ server: HttpServer; url: string }> {
  const server = createServer((req, res) => { void handler(req, res) })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  return { server, url: `http://127.0.0.1:${(server.address() as AddressInfo).port}` }
}

const MODEL_ID = '00000000-0000-4000-8000-000000000001'
const OTHER_ID = '00000000-0000-4000-8000-000000000002'
const model = (id = MODEL_ID, name = 'coder', extra: Record<string, unknown> = {}) => ({
  id, name, repoId: 'Qwen/Qwen3-8B-AWQ', format: 'awq', weightBytes: 6e9, nativeContextTokens: 40960,
  contextTokens: 16384, concurrency: 1, goal: 'balanced',
  preferredGPU: { gpuId: 'NVIDIA L40S', cloud: 'SECURE', count: 2 },
  schedule: { enabled: false, timezone: 'Europe/Berlin', weekdays: [1, 2, 3, 4, 5], startAt: '08:00', stopAt: '18:00', idleStopMinutes: 30, maxRuntimeHours: 12 },
  keepDisk: false, ...extra,
})

describe('Podlight server', () => {
  let runpod: FakeRunPod
  let pod: FakePod
  let servers: HttpServer[] = []
  let runpodURL = ''
  let engineURL = ''
  let watchdogURL = ''
  let s: Server
  let device = ''

  before(async () => {
    runpod = new FakeRunPod()
    pod = new FakePod()
    const r = await listen(runpod.handle)
    const e = await listen(pod.engine)
    const w = await listen(pod.watchdog)
    servers = [r.server, e.server, w.server]
    runpodURL = r.url
    engineURL = e.url
    watchdogURL = w.url
  })

  after(() => { for (const server of servers) server.close() })

  beforeEach(async () => {
    runpod.requests = []
    runpod.pods.clear()
    runpod.createScript = []
    runpod.taken = new Set()
    runpod.dataCenterId = 'EU-RO-1'
    pod.engineRequests = []
    pod.heartbeats = []
    pod.engineAlive = true
    pod.proxyNotReadyFor = 0
    pod.loading = false
    pod.stuck = false
    pod.garbage = false
    pod.warm = null
    s = await buildServer({
      db: openDatabase(':memory:'), sealer: sealer(randomBytes(32)), wrongKeyDelayMs: 0, proxyRetryDelayMs: 10,
      manager: { runpodBase: runpodURL, wakePollMs: 20, hostBusyTries: 3, hostBusyDelayMs: 5, cardRetryMs: 0, loadStallMs: 0, podURL: (_id, port) => (port === 8000 ? engineURL : watchdogURL) },
    })
    const code = s.pairing.issue().code
    const paired = await s.app.inject({ method: 'POST', url: '/pair', payload: { code, deviceName: 'Test Mac' } })
    device = paired.json().token
    await admin('PATCH', '/admin/settings', { runpodApiKey: 'rp-test', dailyLimitUsd: 10 })
    await admin('PUT', `/admin/models/${MODEL_ID}`, model())
  })

  const admin = (method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE', url: string, payload?: unknown) =>
    s.app.inject({ method, url, headers: { authorization: `Bearer ${device}` }, ...(payload === undefined ? {} : { payload: payload as object }) })

  async function clientToken(models: string[] | null = null): Promise<string> {
    const response = await admin('POST', '/admin/client-tokens', { name: 'agent', models })
    return response.json().token
  }

  test('a pairing code works once, survives wrong guesses up to the limit, and keys stay apart', async () => {
    const code = s.pairing.issue().code
    const wrong = await s.app.inject({ method: 'POST', url: '/pair', payload: { code: 'AAAA-BBBB-CCCC' } })
    assert.equal(wrong.statusCode, 403)
    const right = await s.app.inject({ method: 'POST', url: '/pair', payload: { code: code.toLowerCase(), deviceName: 'Second' } })
    assert.equal(right.statusCode, 200)
    const again = await s.app.inject({ method: 'POST', url: '/pair', payload: { code } })
    assert.equal(again.statusCode, 403)
    assert.match(again.json().error.message, /already been used/)

    const client = await clientToken()
    const clientOnAdmin = await s.app.inject({ method: 'GET', url: '/admin/state', headers: { authorization: `Bearer ${client}` } })
    assert.equal(clientOnAdmin.statusCode, 401)
    const deviceOnGateway = await s.app.inject({ method: 'GET', url: '/v1/models', headers: { authorization: `Bearer ${device}` } })
    assert.equal(deviceOnGateway.statusCode, 401)
    const ok = await s.app.inject({ method: 'GET', url: '/v1/models', headers: { 'x-api-key': client } })
    assert.equal(ok.statusCode, 200)
  })

  test('five wrong codes lock pairing until a new code', async () => {
    const code = s.pairing.issue().code
    for (let i = 0; i < 5; i++) await s.app.inject({ method: 'POST', url: '/pair', payload: { code: 'WRONG' } })
    const late = await s.app.inject({ method: 'POST', url: '/pair', payload: { code } })
    assert.equal(late.statusCode, 403)
    assert.match(late.json().error.message, /Too many/)
  })

  test('the state carries the RunPod balance, read in the background and kept a minute', async () => {
    const first = (await admin('GET', '/admin/state')).json()
    assert.equal(first.balance, null, 'not read yet: the state does not wait for it')
    await s.manager.refreshBalance()
    const second = (await admin('GET', '/admin/state')).json()
    assert.deepEqual({ ...second.balance, checkedAt: undefined }, { usd: 42.5, spendPerHourUsd: 0.86, spendLimitUsd: 80, checkedAt: undefined })
    const asked = runpod.requests.filter((r) => r.path === '/graphql').length
    await admin('GET', '/admin/state')
    assert.equal(runpod.requests.filter((r) => r.path === '/graphql').length, asked, 'fresh: no new question')

    runpod.balance = null
    await s.manager.accountChanged()
    await s.manager.refreshBalance()
    assert.equal((await admin('GET', '/admin/state')).json().balance, null, 'a key without GraphQL access shows none')
    runpod.balance = { clientBalance: 42.5, currentSpendPerHr: 0.86, spendLimit: 80 }
  })

  test('a pod deleted at RunPod is let go at once by refresh', async () => {
    await admin('POST', `/admin/models/${MODEL_ID}/start`, { until: new Date(Date.now() + 3600_000).toISOString() })
    const podId = s.store.run(MODEL_ID).podId!
    runpod.pods.delete(podId)
    const response = await admin('POST', '/admin/refresh')
    assert.equal(response.statusCode, 200)
    const run = (await admin('GET', '/admin/state')).json().runs[MODEL_ID]
    assert.equal(run.podId, undefined)
    assert.equal(run.lastReason, 'pod-gone')
  })

  test('a pod missing from the lagging list but still there is kept', async () => {
    await admin('POST', `/admin/models/${MODEL_ID}/start`, { until: new Date(Date.now() + 3600_000).toISOString() })
    const podId = s.store.run(MODEL_ID).podId!
    runpod.hiddenFromList.add(podId)
    await s.manager.reconcile()
    runpod.hiddenFromList.clear()
    assert.equal(s.store.run(MODEL_ID).podId, podId)
    runpod.pods.get(podId)!.status = 'TERMINATED'
    await s.manager.reconcile()
    assert.equal(s.store.run(MODEL_ID).podId ?? null, null)
  })

  test('a pod status RunPod added since does not cost the run its pod', async () => {
    await admin('POST', `/admin/models/${MODEL_ID}/start`, { until: new Date(Date.now() + 3600_000).toISOString() })
    const podId = s.store.run(MODEL_ID).podId!
    runpod.pods.get(podId)!.status = 'PAUSED'
    await s.manager.tick()
    const run = s.store.run(MODEL_ID)
    assert.equal(run.podId, podId)
    assert.equal(run.podStatus, 'RUNNING', 'the last known status stays')
    s.db.prepare('UPDATE runs SET json = json_set(json, \'$.podStatus\', \'PAUSED\') WHERE model_id = ?').run(MODEL_ID)
    assert.equal(s.store.run(MODEL_ID).podId, podId, 'an unreadable field drops alone')
  })

  const MAC_KEY = 'mac-pod-key-0123456789abcdef'
  const macPod = (status: string, extra: Partial<FakeRunpodPod> = {}): FakeRunpodPod => {
    const p: FakeRunpodPod = {
      id: 'macpod1', name: 'podlight-small@studio-mac-7c1e', status, cost: 0.44, dataCenterId: 'EU-RO-1',
      env: { PODLIGHT_API_KEY: MAC_KEY, PODLIGHT_MODEL: 'Qwen/Qwen3-8B-AWQ', HF_HOME: '/workspace/hf' },
      gpu: { id: 'NVIDIA L40S', count: 1 }, disk: 20, mounts: { persistent: { size: 30 } }, ...extra,
    }
    runpod.pods.set(p.id, p)
    return p
  }
  const handOver = (podId: string | null, name = 'small', extra: Record<string, unknown> = {}) =>
    admin('POST', `/admin/models/${OTHER_ID}/adopt`, { model: model(OTHER_ID, name, { keepDisk: true, preferredGPU: { gpuId: 'NVIDIA L40S', cloud: 'SECURE', count: 1 }, ...extra }), podKey: MAC_KEY, podId })

  test('a running model from a Mac comes over with its pod and key, renamed, nothing built anew', async () => {
    macPod('RUNNING')
    const response = await handOver('macpod1')
    assert.equal(response.statusCode, 200, response.body)
    assert.equal(runpod.pods.get('macpod1')!.name, 'podlight-srv-small')
    assert.equal(runpod.requests.some((r) => r.method === 'POST' && r.path === '/v2/pods'), false)
    const run = s.store.run(OTHER_ID)
    assert.equal(run.podId, 'macpod1')
    assert.equal(run.persistentGB, 30)
    assert.equal(run.containerGB, 20)
    assert.equal(run.gpuName, 'L40S')
    assert.equal(run.lastReason, 'handed-over')
    assert.equal(pod.heartbeatKeys.at(-1), `Bearer ${MAC_KEY}`, "the watchdog gets the Mac's pod key")
    assert.equal(run.phase, 'ready', 'the engine answered the start test')
    // Agents reach it through the server with the pod's own key.
    const client = await clientToken()
    const reply = await s.app.inject({ method: 'POST', url: '/v1/chat/completions', headers: { authorization: `Bearer ${client}` }, payload: { model: 'small', messages: [{ role: 'user', content: 'x' }] } })
    assert.equal(reply.statusCode, 200)
    assert.equal(pod.engineRequests.at(-1)!.headers.authorization, `Bearer ${MAC_KEY}`)
  })

  test('a stopped model from a Mac keeps its disk: the next start resumes the same pod', async () => {
    macPod('EXITED')
    assert.equal((await handOver('macpod1')).statusCode, 200)
    assert.equal(s.store.run(OTHER_ID).phase, 'stopped')
    assert.equal((await admin('POST', `/admin/models/${OTHER_ID}/start`, {})).statusCode, 200)
    assert.equal(runpod.requests.some((r) => r.method === 'POST' && r.path === '/v2/pods'), false, 'no new pod, no new download')
    assert.equal(runpod.pods.get('macpod1')!.status, 'RUNNING')
    assert.equal(runpod.pods.get('macpod1')!.env.PODLIGHT_API_KEY, MAC_KEY)
    assert.equal(s.store.run(OTHER_ID).podId, 'macpod1')
  })

  test('handing over is refused for server pods, name clashes, pods outside the region, and busy pods', async () => {
    macPod('RUNNING', { name: 'podlight-srv-small' })
    assert.equal((await handOver('macpod1')).json().error.code, 'not_a_mac_pod')
    macPod('RUNNING')
    const clash = await handOver('macpod1', 'coder')
    assert.equal(clash.statusCode, 409)
    assert.equal(clash.json().error.code, 'name_taken')
    assert.equal(runpod.pods.get('macpod1')!.name, 'podlight-small@studio-mac-7c1e', 'nothing renamed')
    macPod('RUNNING', { dataCenterId: 'US-TX-3' })
    assert.equal((await handOver('macpod1', 'small', { hosting: { region: 'eu', secureOnly: true } })).json().error.code, 'outside_region')
    macPod('STARTING')
    assert.equal((await handOver('macpod1')).json().error.code, 'pod_busy')
    assert.equal(s.store.model(OTHER_ID), null, 'nothing stayed behind')
  })

  test('a model whose pod is gone comes over without one', async () => {
    const response = await handOver('nosuchpod')
    assert.equal(response.statusCode, 200)
    assert.equal(s.store.model(OTHER_ID)?.name, 'small')
    assert.equal(s.store.run(OTHER_ID).podId ?? null, null)
    assert.equal((await handOver(null)).json().error.code, 'already_here')
  })

  test('secrets are write-only', async () => {
    const settings = (await admin('GET', '/admin/settings')).json()
    assert.equal(settings.hasRunpodKey, true)
    assert.equal(JSON.stringify(settings).includes('rp-test'), false)
    const raw = s.db.prepare(`SELECT value FROM settings WHERE key = 'runpodApiKey'`).get() as { value: string }
    assert.equal(raw.value.includes('rp-test'), false, 'stored encrypted')
  })

  test('a token limited to models sees and uses only those', async () => {
    await admin('PUT', `/admin/models/${OTHER_ID}`, model(OTHER_ID, 'other'))
    const limited = await clientToken([OTHER_ID])
    const list = (await s.app.inject({ method: 'GET', url: '/v1/models', headers: { authorization: `Bearer ${limited}` } })).json()
    assert.deepEqual(list.data.map((m: { id: string }) => m.id), ['other'])
    const refused = await s.app.inject({ method: 'POST', url: '/v1/chat/completions', headers: { authorization: `Bearer ${limited}` },
      payload: { model: 'coder', messages: [] } })
    assert.equal(refused.statusCode, 403)
    assert.equal(refused.json().error.code, 'model_not_allowed')
    assert.equal(runpod.requests.filter((r) => r.path === '/v2/pods' && r.method === 'POST').length, 0)
  })

  test('a reached limit refuses the wake before anything is created', async () => {
    const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
    s.store.addSpend(today, 12)
    const client = await clientToken()
    const response = await s.app.inject({ method: 'POST', url: '/v1/messages', headers: { authorization: `Bearer ${client}` },
      payload: { model: 'coder', messages: [] } })
    assert.equal(response.statusCode, 429)
    assert.equal(response.json().error.type, 'rate_limit_error')
    assert.equal(runpod.requests.some((r) => r.method === 'POST' && r.path === '/v2/pods'), false)
  })

  test('a request wakes the model, falls back past a taken card, and streams the Messages API through', async () => {
    runpod.createScript = ['capacity', 'ok']
    const client = await clientToken()
    const response = await s.app.inject({
      method: 'POST', url: '/v1/messages?beta=true',
      headers: { authorization: `Bearer ${client}`, 'anthropic-version': '2023-06-01', 'anthropic-beta': 'x', 'content-type': 'application/json' },
      payload: { model: 'coder', system: [{ type: 'text', text: 'top' }],
        messages: [{ role: 'user', content: 'hi' }, { role: 'system', content: 'Environment' }], stream: true },
    })
    assert.equal(response.statusCode, 200)
    assert.match(response.body, /event: ping/)
    assert.match(response.headers['content-type'] as string, /text\/event-stream/)

    const creates = runpod.requests.filter((r) => r.method === 'POST' && r.path === '/v2/pods')
    assert.equal(creates.length, 2)
    assert.equal(creates[0]!.body.gpu.count, 2)
    assert.equal(creates[0]!.body.env.PODLIGHT_TP, '2')
    assert.match(creates[0]!.body.name, /^podlight-srv-coder/)
    assert.equal(creates[1]!.body.env.PODLIGHT_TP, String(creates[1]!.body.gpu.count))

    const reached = pod.engineRequests.at(-1)!
    assert.equal(reached.path, '/v1/messages?beta=true')
    assert.equal(reached.headers['anthropic-version'], '2023-06-01')
    assert.equal(reached.headers.authorization?.toString().startsWith('Bearer '), true)
    assert.notEqual(reached.headers.authorization, `Bearer ${client}`, 'the pod gets its own key, not the client token')
    assert.deepEqual(reached.body.messages.map((m: { role: string }) => m.role), ['user', 'user'])
    assert.match(reached.body.messages[1].content[0].text, /^<system-reminder>\nEnvironment/)

    const run = (await admin('GET', '/admin/state')).json().runs[MODEL_ID]
    assert.equal(run.phase, 'ready')
    assert.equal(run.startedManually, false)
    assert.ok(run.fellBackFrom.length === 1)
  })

  test('a chat body without system entries reaches the engine byte for byte', async () => {
    const client = await clientToken()
    const raw = '{"model":"coder",  "messages":[{"role":"user","content":"x"}]}'
    const response = await s.app.inject({ method: 'POST', url: '/v1/chat/completions',
      headers: { authorization: `Bearer ${client}`, 'content-type': 'application/json' }, payload: raw })
    assert.equal(response.statusCode, 200)
    assert.equal(response.json().choices[0].message.content, 'hello from the pod')
    assert.equal(JSON.stringify(pod.engineRequests.at(-1)!.body), JSON.stringify(JSON.parse(raw)))
  })

  test('telemetry from each heartbeat reaches the state and the history, and ends with the pod', async () => {
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, {})).statusCode, 200)
    await s.manager.tick()
    await s.manager.tick()
    const state = (await admin('GET', '/admin/state')).json()
    assert.equal(state.telemetry[MODEL_ID].gpus[0].utilPercent, 87)
    assert.equal(state.telemetry[MODEL_ID].gpus[0].powerLimitW, null)
    assert.equal(state.telemetry[MODEL_ID].engine.generationTokensPerSecond, 58)
    const running = state.runs[MODEL_ID]
    assert.ok(running.storagePerHour > 0)
    assert.ok(Math.abs(state.costPerHour - (running.pricePerHour + running.storagePerHour)) < 1e-9, 'cost per hour includes the storage')
    const history = (await admin('GET', `/admin/models/${MODEL_ID}/telemetry`)).json()
    assert.equal(history.samples.length, 2)
    assert.ok(history.samples[0].time < history.samples[1].time)
    assert.equal((await admin('GET', `/admin/models/${OTHER_ID}/telemetry`)).statusCode, 404)

    await admin('POST', `/admin/models/${MODEL_ID}/stop`)
    assert.deepEqual((await admin('GET', `/admin/models/${MODEL_ID}/telemetry`)).json().samples, [])
    assert.equal((await admin('GET', '/admin/state')).json().telemetry[MODEL_ID], undefined)
  })

  test('a manual start with an end feeds the watchdog the deadline and the end stops and deletes the pod', async () => {
    const until = new Date(Date.now() + 60 * 60_000)
    const started = await admin('POST', `/admin/models/${MODEL_ID}/start`, { until: until.toISOString() })
    assert.equal(started.statusCode, 200)
    const create = runpod.requests.find((r) => r.method === 'POST' && r.path === '/v2/pods')!
    assert.equal(create.body.env.PODLIGHT_DEADLINE, String(Math.trunc((until.getTime() + 600_000) / 1000)))
    await s.manager.tick()
    assert.equal(pod.heartbeats.length, 1)
    // Stored to the second, as Swift reads ISO dates.
    assert.equal(pod.heartbeats[0].deadline, Math.trunc(until.getTime() / 1000) + 600)

    // Move the end into the past: the next tick stops it, and without a kept disk deletes it.
    s.store.updateRun(MODEL_ID, (r) => { r.runUntil = new Date(Date.now() - 1000).toISOString() })
    await s.manager.tick()
    const run = s.store.run(MODEL_ID)
    assert.equal(run.phase, 'stopped')
    assert.equal(run.lastReason, 'run-until')
    assert.equal(run.podId ?? null, null)
    assert.ok(runpod.requests.some((r) => r.method === 'DELETE'))
  })

  test('a stopped pod resumes with this version\'s start script and watchdog', async () => {
    await admin('PUT', `/admin/models/${MODEL_ID}`, model(MODEL_ID, 'coder', { keepDisk: true }))
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, {})).statusCode, 200)
    await admin('POST', `/admin/models/${MODEL_ID}/stop`)
    const podId = s.store.run(MODEL_ID).podId!
    const stopped = runpod.pods.get(podId)!
    assert.equal(stopped.status, 'EXITED')
    const key = stopped.env.PODLIGHT_API_KEY
    assert.ok(key)
    // As made by an older version.
    stopped.env = { ...stopped.env, PODLIGHT_BOOT_B64: 'old', PODLIGHT_WATCHDOG_B64: 'old' }
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, {})).statusCode, 200)
    const patch = runpod.requests.find((r) => r.method === 'PATCH' && r.path === `/v2/pods/${podId}`)
    assert.ok(patch, 'the env is replaced before the resume')
    assert.equal(runpod.pods.get(podId)!.env.PODLIGHT_BOOT_B64, POD_SCRIPTS.boot)
    assert.equal(runpod.pods.get(podId)!.env.PODLIGHT_WATCHDOG_B64, POD_SCRIPTS.watchdog)
    assert.equal(runpod.pods.get(podId)!.env.PODLIGHT_API_KEY, key, 'the rest stays')
    assert.equal(runpod.pods.get(podId)!.status, 'RUNNING')
  })

  test('a pricier fallback is offered, not booked; the server waits within the price, and an approved price books it', async () => {
    // Two A6000 for 0.66 $/h, and no extra cost allowed: every other card is above the price.
    await admin('PATCH', '/admin/settings', { fallbackPriceStepPercent: 0 })
    await admin('PUT', `/admin/models/${MODEL_ID}`, model(MODEL_ID, 'coder', { preferredGPU: { gpuId: 'NVIDIA RTX A6000', cloud: 'COMMUNITY', count: 2 } }))
    runpod.taken = new Set(['NVIDIA RTX A6000'])
    const creates = () => runpod.requests.filter((r) => r.method === 'POST' && r.path === '/v2/pods')

    const refused = await admin('POST', `/admin/models/${MODEL_ID}/start`, { until: new Date(Date.now() + 3_600_000).toISOString() })
    assert.equal(refused.statusCode, 503)
    assert.equal(refused.json().error.code, 'card_too_expensive')
    assert.ok(creates().every((r) => r.body.gpu.id === 'NVIDIA RTX A6000'), 'only the chosen card was tried')
    assert.equal(runpod.pods.size, 0, 'nothing booked')
    let run = s.store.run(MODEL_ID)
    assert.equal(run.phase, 'stopped')
    assert.equal(run.lastReason, 'card-too-expensive')
    assert.equal(run.waitingForCard?.maxPricePerHour, 0.66)
    assert.equal(run.waitingForCard?.wanted?.pricePerHour, 0.66)
    const cheapest = run.waitingForCard?.pricier?.[0]
    assert.ok(cheapest && cheapest.pricePerHour > 0.66)

    // Still taken: still waiting, nothing booked. A request that wakes it is told why.
    await s.manager.tick()
    assert.equal(runpod.pods.size, 0)
    assert.ok(s.store.run(MODEL_ID).waitingForCard)

    // The user approves the cheapest pricier card: it is booked there, and the waiting ends.
    const approved = await admin('POST', `/admin/models/${MODEL_ID}/start`, { until: new Date(Date.now() + 3_600_000).toISOString(), maxPricePerHour: cheapest.pricePerHour })
    assert.equal(approved.statusCode, 200)
    run = s.store.run(MODEL_ID)
    assert.equal(run.gpu?.gpuId, cheapest.choice.gpuId)
    assert.equal(run.waitingForCard ?? null, null)
    assert.equal(run.wantedPricePerHour, 0.66)
    await admin('POST', `/admin/models/${MODEL_ID}/stop`)
  })

  test('a woken model waits for a card within the price and starts on one once it is free', async () => {
    await admin('PATCH', '/admin/settings', { fallbackPriceStepPercent: 0 })
    await admin('PUT', `/admin/models/${MODEL_ID}`, model(MODEL_ID, 'coder', { preferredGPU: { gpuId: 'NVIDIA RTX A6000', cloud: 'COMMUNITY', count: 2 } }))
    runpod.taken = new Set(['NVIDIA RTX A6000'])
    const client = await clientToken()
    const woken = await s.app.inject({ method: 'POST', url: '/v1/chat/completions', headers: { authorization: `Bearer ${client}` },
      payload: { model: 'coder', messages: [{ role: 'user', content: 'hi' }] } })
    assert.equal(woken.statusCode, 503)
    assert.equal(woken.json().error.code, 'card_too_expensive')
    const waiting = s.store.run(MODEL_ID).waitingForCard
    assert.equal(waiting?.manual, false)
    assert.ok(Date.parse(waiting!.until) - Date.now() > 29 * 60_000, 'half an hour for a woken run')

    // The A6000 comes free: the next tick books it, within the price.
    runpod.taken = new Set()
    await s.manager.tick()
    const run = s.store.run(MODEL_ID)
    assert.equal(run.gpu?.gpuId, 'NVIDIA RTX A6000')
    assert.equal(run.waitingForCard ?? null, null)
    assert.equal(runpod.pods.size, 1)
  })

  test('a busy machine keeps the stopped pod and its disk; only a chosen new card replaces it', async () => {
    await admin('PUT', `/admin/models/${MODEL_ID}`, model(MODEL_ID, 'coder', { keepDisk: true }))
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, {})).statusCode, 200)
    await admin('POST', `/admin/models/${MODEL_ID}/stop`)
    const podId = s.store.run(MODEL_ID).podId!

    // Busy for two tries, free on the third: it resumes.
    runpod.hostBusyFor = 2
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, {})).statusCode, 200)
    assert.equal(s.store.run(MODEL_ID).podId, podId)
    await admin('POST', `/admin/models/${MODEL_ID}/stop`)

    // Busy for longer: the pod stays, the start says why, and the server keeps trying.
    runpod.hostBusyFor = 10
    const busy = await admin('POST', `/admin/models/${MODEL_ID}/start`, {})
    assert.equal(busy.statusCode, 503)
    assert.equal(busy.json().error.code, 'host_busy')
    assert.equal(s.store.run(MODEL_ID).podId, podId)
    assert.equal(s.store.run(MODEL_ID).lastReason, 'host-busy')
    assert.equal(s.store.run(MODEL_ID).phase, 'stopped')
    assert.ok(s.store.run(MODEL_ID).waitingForCard)
    assert.ok(runpod.pods.has(podId), 'the pod and its disk are kept')
    assert.ok(!runpod.requests.some((r) => r.method === 'DELETE'))
    await s.manager.tick()
    assert.ok(s.store.run(MODEL_ID).waitingForCard, 'still busy: still waiting')

    // The card comes free: the next tick resumes the same pod.
    runpod.hostBusyFor = 0
    await s.manager.tick()
    assert.equal(s.store.run(MODEL_ID).podId, podId)
    assert.equal(s.store.run(MODEL_ID).waitingForCard ?? null, null)
    assert.equal(s.store.run(MODEL_ID).resumed, true)
    assert.equal(runpod.pods.get(podId)!.status, 'RUNNING')
    await admin('POST', `/admin/models/${MODEL_ID}/stop`)

    // Stop ends the waiting.
    runpod.hostBusyFor = 10
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, {})).statusCode, 503)
    await admin('POST', `/admin/models/${MODEL_ID}/stop`)
    assert.equal(s.store.run(MODEL_ID).waitingForCard ?? null, null)

    // A new card builds a new pod but keeps the old one until the new one answers.
    runpod.hostBusyFor = 0
    pod.loading = true
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, { newPod: true })).statusCode, 200)
    const newId = s.store.run(MODEL_ID).podId!
    assert.notEqual(newId, podId)
    assert.equal(s.store.run(MODEL_ID).replacing?.podId, podId)
    await s.manager.refresh(MODEL_ID)
    assert.ok(runpod.pods.has(podId), 'the old pod stays while the new one loads')
    pod.loading = false
    await s.manager.refresh(MODEL_ID)
    assert.equal(s.store.run(MODEL_ID).phase, 'ready')
    assert.ok(!runpod.pods.has(podId), 'the old pod goes once the new one answers')
    assert.equal(s.store.run(MODEL_ID).replacing ?? null, null)
  })

  test('a new card that fails puts the old pod back', async () => {
    await admin('PUT', `/admin/models/${MODEL_ID}`, model(MODEL_ID, 'coder', { keepDisk: true }))
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, {})).statusCode, 200)
    await admin('POST', `/admin/models/${MODEL_ID}/stop`)
    const oldId = s.store.run(MODEL_ID).podId!
    pod.garbage = true
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, { newPod: true })).statusCode, 200)
    const newId = s.store.run(MODEL_ID).podId!
    await s.manager.refresh(MODEL_ID)
    const run = s.store.run(MODEL_ID)
    assert.equal(run.podId, oldId)
    assert.equal(run.phase, 'failed')
    assert.equal(run.lastReason, 'garbage-output')
    assert.equal(run.replacing ?? null, null)
    assert.ok(runpod.pods.has(oldId) && !runpod.pods.has(newId))
  })

  test('a loading engine that shows no progress is stopped as hung', async () => {
    await admin('PUT', `/admin/models/${MODEL_ID}`, model(MODEL_ID, 'coder', { keepDisk: true }))
    pod.stuck = true
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, {})).statusCode, 200)
    await s.manager.refresh(MODEL_ID)
    assert.equal(s.store.run(MODEL_ID).phase, 'loading')
    await s.manager.refresh(MODEL_ID)
    const run = s.store.run(MODEL_ID)
    assert.equal(run.phase, 'failed')
    assert.equal(run.lastReason, 'engine-stuck')
    assert.equal(run.podStatus, 'EXITED')
  })

  test('a model is ready only once the watchdog has warmed the engine up', async () => {
    pod.warm = false
    assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, {})).statusCode, 200)
    await s.manager.tick()
    assert.equal(s.store.run(MODEL_ID).phase, 'loading', 'the engine answers, but the warm-up still runs')
    pod.warm = true
    await s.manager.tick()
    assert.equal(s.store.run(MODEL_ID).phase, 'ready')
  })

  test('the start test stops a model that only repeats one character', async () => {
    pod.garbage = true
    pod.startTests = 0
    try {
      assert.equal((await admin('POST', `/admin/models/${MODEL_ID}/start`, {})).statusCode, 200)
      const podId = s.store.run(MODEL_ID).podId!
      await s.manager.tick()
      const run = s.store.run(MODEL_ID)
      assert.equal(pod.startTests, 1)
      assert.equal(run.phase, 'failed')
      assert.equal(run.lastReason, 'garbage-output')
      assert.match(run.lastMessage ?? '', /^"!!!!/)
      assert.ok(!runpod.pods.has(podId), 'without a kept disk the useless pod is deleted')
    } finally {
      pod.garbage = false
    }
  })

  test('a pod outside the allowed region is deleted at once', async () => {
    await admin('PUT', `/admin/models/${MODEL_ID}`, model(MODEL_ID, 'coder', { hosting: { region: 'eu', secureOnly: true } }))
    runpod.dataCenterId = 'US-TX-3'
    await admin('POST', `/admin/models/${MODEL_ID}/start`, { until: new Date(Date.now() + 3600_000).toISOString() })
    const create = runpod.requests.find((r) => r.method === 'POST' && r.path === '/v2/pods')!
    assert.deepEqual(create.body.dataCenterIds, ['EU-RO-1'])
    await s.manager.tick()
    const run = s.store.run(MODEL_ID)
    assert.equal(run.lastReason, 'outside-region')
    assert.equal(runpod.pods.size, 0)
  })

  test('an engine that died is reported with its log and the pod ended', async () => {
    await admin('POST', `/admin/models/${MODEL_ID}/start`, { until: new Date(Date.now() + 3600_000).toISOString() })
    pod.engineAlive = false
    await s.manager.tick()
    const run = s.store.run(MODEL_ID)
    assert.equal(run.phase, 'failed')
    assert.equal(run.lastReason, 'engine-exited')
    assert.match(run.lastMessage ?? '', /out of memory/)
  })

  test('the server never touches a pod it did not create', async () => {
    runpod.pods.set('foreign1', { id: 'foreign1', name: 'someone-else', status: 'RUNNING', cost: 1, dataCenterId: null, env: {} })
    await admin('POST', `/admin/models/${MODEL_ID}/start`, { until: new Date(Date.now() + 3600_000).toISOString() })
    await s.manager.tick()
    await admin('POST', `/admin/models/${MODEL_ID}/stop`)
    await admin('DELETE', `/admin/models/${MODEL_ID}`)
    await s.manager.tick()
    assert.equal(runpod.requests.some((r) => r.path.includes('foreign1')), false)
    assert.equal(runpod.pods.get('foreign1')?.status, 'RUNNING')
  })

  test("RunPod's proxy 404 right after a wake is waited out, not passed on", async () => {
    const client = await clientToken()
    pod.proxyNotReadyFor = 2
    const response = await s.app.inject({ method: 'POST', url: '/v1/chat/completions',
      headers: { authorization: `Bearer ${client}` }, payload: { model: 'coder', messages: [] } })
    assert.equal(response.statusCode, 200)
    assert.equal(pod.proxyNotReadyFor, 0)

    pod.proxyNotReadyFor = 100
    const late = await s.app.inject({ method: 'POST', url: '/v1/chat/completions',
      headers: { authorization: `Bearer ${client}` }, payload: { model: 'coder', messages: [] } })
    assert.equal(late.statusCode, 503)
    assert.equal(late.json().error.code, 'starting')
    pod.proxyNotReadyFor = 0
  })

  test('an agent that goes away stops the generation at the pod', async () => {
    const client = await clientToken()
    await s.app.listen({ port: 0, host: '127.0.0.1' })
    const address = s.app.server.address() as AddressInfo
    const abort = new AbortController()
    const response = await fetch(`http://127.0.0.1:${address.port}/v1/chat/completions`, {
      method: 'POST', signal: abort.signal,
      headers: { authorization: `Bearer ${client}`, 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'coder', messages: [], stream: true, slow: true }),
    })
    const reader = response.body!.getReader()
    await reader.read()
    abort.abort()
    for (let i = 0; i < 50 && !pod.slowStreamAborted; i++) await new Promise((r) => setTimeout(r, 20))
    assert.equal(pod.slowStreamAborted, true)
    await s.app.close()
  })

  test('a model name is unique per server', async () => {
    const clash = await admin('PUT', `/admin/models/${OTHER_ID}`, model(OTHER_ID, 'coder'))
    assert.equal(clash.statusCode, 409)
    const bad = await admin('PUT', `/admin/models/${OTHER_ID}`, model(OTHER_ID, 'Has Space'))
    assert.equal(bad.statusCode, 400)
  })
})
