import { strict as assert } from 'node:assert'
import { randomBytes } from 'node:crypto'
import { createServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { after, before, beforeEach, describe, test } from 'node:test'
import { buildServer, type Server } from '../src/app.ts'
import { sealer } from '../src/crypto.ts'
import { openDatabase } from '../src/store/db.ts'

// The server end to end, against a fake RunPod and a fake pod (engine on one port, watchdog on
// another). Nothing here reaches the internet.

interface Recorded { method: string; path: string; body: any }

class FakeRunPod {
  requests: Recorded[] = []
  pods = new Map<string, { id: string; status: string; cost: number; dataCenterId: string | null; env: Record<string, string> }>()
  /** Responses to POST /v2/pods, in order; `capacity` answers RunPod's "no instances" 400. */
  createScript: Array<'ok' | 'capacity'> = []
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
    if (req.method === 'GET' && path.startsWith('/v2/pods?')) return json(200, { pods: [] })
    if (req.method === 'POST' && path === '/v2/pods') {
      const step = this.createScript.shift() ?? 'ok'
      if (step === 'capacity') {
        return json(400, { detail: 'There are no longer any instances available with the requested specifications.', status: 400 })
      }
      const id = `pod${++this.counter}`
      const pod = { id, status: 'RUNNING', cost: 0.86, dataCenterId: this.dataCenterId, env: body.env }
      this.pods.set(id, pod)
      return json(201, { ...pod, name: body.name })
    }
    const match = /^\/v2\/pods\/([^/]+)(\/action)?$/.exec(path)
    if (match) {
      const pod = this.pods.get(match[1]!)
      if (!pod) return json(404, { error: 'pod not found' })
      if (req.method === 'DELETE') { this.pods.delete(pod.id); return json(204, undefined) }
      if (match[2]) {
        pod.status = body.action === 'stop' ? 'EXITED' : 'RUNNING'
        return json(200, { ...pod, name: 'x' })
      }
      return json(200, { ...pod, name: 'x' })
    }
    json(404, { error: `unhandled ${req.method} ${path}` })
  }
}

/** One fake pod for every pod id: engine and watchdog, recording what reached them. */
class FakePod {
  engineRequests: Array<{ path: string; headers: Record<string, string | string[] | undefined>; body: any }> = []
  heartbeats: any[] = []
  engineAlive = true
  /** Answers like RunPod's proxy before it routes to the pod: 404, no JSON. */
  proxyNotReadyFor = 0
  /** Set when a slow stream was cut off by the other side. */
  slowStreamAborted = false
  /** Telemetry the watchdog reports; each heartbeat is a new sample. */
  telemetryTime = 1_800_000_000

  engine = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const chunks: Buffer[] = []
    for await (const chunk of req) chunks.push(chunk as Buffer)
    const text = Buffer.concat(chunks).toString('utf8')
    if (req.url === '/v1/models') {
      res.writeHead(200, { 'content-type': 'application/json' })
      return void res.end('{"data":[]}')
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
    if (req.url === '/heartbeat') this.heartbeats.push(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'))
    res.writeHead(200, { 'content-type': 'application/json' })
    if (req.url === '/log') return void res.end(JSON.stringify({ lines: ['loading', 'torch.OutOfMemoryError: CUDA out of memory'] }))
    const telemetry = { time: this.telemetryTime++, cpuPercent: 12.5, gpus: [{ index: 0, name: 'NVIDIA A40', utilPercent: 87, memoryUsedBytes: 4.5e10, memoryTotalBytes: 4.8e10, temperatureC: 55, powerW: 250.3, powerLimitW: null }],
      engine: { running: 2, waiting: 0, kvCachePercent: 41.5, generationTokensPerSecond: 58 } }
    res.end(JSON.stringify({ engineAlive: this.engineAlive, engineExitCode: this.engineAlive ? null : 1, telemetry }))
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
    runpod.dataCenterId = 'EU-RO-1'
    pod.engineRequests = []
    pod.heartbeats = []
    pod.engineAlive = true
    pod.proxyNotReadyFor = 0
    s = await buildServer({
      db: openDatabase(':memory:'), sealer: sealer(randomBytes(32)), wrongKeyDelayMs: 0, proxyRetryDelayMs: 10,
      manager: { runpodBase: runpodURL, wakePollMs: 20, podURL: (_id, port) => (port === 8000 ? engineURL : watchdogURL) },
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
    runpod.pods.set('foreign1', { id: 'foreign1', status: 'RUNNING', cost: 1, dataCenterId: null, env: {} })
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
