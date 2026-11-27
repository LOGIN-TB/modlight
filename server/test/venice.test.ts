import { strict as assert } from 'node:assert'
import { randomBytes } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { createServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { after, before, beforeEach, describe, test } from 'node:test'
import { buildServer, type Server } from '../src/app.ts'
import { sealer } from '../src/crypto.ts'
import { openDatabase } from '../src/store/db.ts'
import { offers } from '../src/providers/venice.ts'
import { specPath } from '../src/spec.ts'

// Venice models on the server, against a fake Venice: the request is rewritten and sent with the
// server's Venice key, usage is booked, errors become Modlight's, Claude Code goes through the
// bridge, and RunPod is never asked. Nothing here reaches the internet.

class FakeVenice {
  requests: Array<{ path: string; auth: string; body: any }> = []
  handle = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const chunks: Buffer[] = []
    for await (const chunk of req) chunks.push(chunk as Buffer)
    const text = Buffer.concat(chunks).toString('utf8')
    const body = text ? JSON.parse(text) : null
    const path = req.url ?? ''
    const auth = req.headers.authorization ?? ''
    this.requests.push({ path, auth, body })
    const json = (status: number, value: unknown): void => {
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end(JSON.stringify(value))
    }
    if (path === '/api/v1/api_keys/rate_limits') {
      if (auth !== 'Bearer VENICE_INFERENCE_KEY_test') return json(401, { error: 'Authentication failed' })
      return json(200, { data: { apiTier: { id: 'paid' }, balances: { USD: 12.5, DIEM: 0 }, rateLimits: [] } })
    }
    if (path.startsWith('/api/v1/models')) return json(200, JSON.parse(readFileSync(specPath('fixtures/venice-models.json'), 'utf8')))
    if (path === '/api/v1/chat/completions') {
      const prompt = body.messages?.at(-1)?.content
      if (prompt === 'broke') return json(402, { error: 'Insufficient balance', code: 'INSUFFICIENT_BALANCE' })
      if (body.stream) {
        res.writeHead(200, { 'content-type': 'text/event-stream', 'x-ratelimit-limit-requests': '100', 'x-ratelimit-remaining-requests': '66',
          'x-ratelimit-limit-tokens': '2000000', 'x-ratelimit-remaining-tokens': '412000' })
        for (const word of ['Hal', 'lo']) res.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: word } }] })}\n\n`)
        if (body.stream_options?.include_usage) {
          res.write(`data: ${JSON.stringify({ choices: [], usage: { prompt_tokens: 1_000_000, completion_tokens: 500_000 } })}\n\n`)
        }
        res.end('data: [DONE]\n\n')
        return
      }
      return json(200, { id: 'c1', object: 'chat.completion', choices: [{ index: 0, message: { role: 'assistant', content: 'Hallo' }, finish_reason: 'stop' }],
        usage: { prompt_tokens: 1200, completion_tokens: 300 }, cost: { usd: 0.25, diem: 0.25 } })
    }
    json(404, { error: `unhandled ${path}` })
  }
}

function listen(handler: (req: IncomingMessage, res: ServerResponse) => void): Promise<{ server: HttpServer; url: string }> {
  return new Promise((resolve) => {
    const server = createServer(handler)
    server.listen(0, '127.0.0.1', () => resolve({ server, url: `http://127.0.0.1:${(server.address() as AddressInfo).port}` }))
  })
}

const MODEL_ID = '7A2B3C4D-0000-4000-8000-00000000AA01'
const offer = offers(JSON.parse(readFileSync(specPath('fixtures/venice-models.json'), 'utf8'))).find((o) => o.providerModelId === 'venice-uncensored-1-2')!

function veniceModel(): object {
  return {
    id: MODEL_ID, name: 'uncensored', repoId: offer.providerModelId, format: 'unknown', weightBytes: 0,
    nativeContextTokens: offer.contextTokens, contextTokens: offer.contextTokens, keepDisk: false, provider: 'venice',
    schedule: { enabled: false, timezone: 'UTC', weekdays: [1], startAt: '08:00', stopAt: '18:00', idleStopMinutes: 30, maxRuntimeHours: 12 },
    api: { providerModelId: offer.providerModelId, displayName: offer.displayName, privacy: offer.privacy, capabilities: offer.capabilities,
      pricing: offer.pricing, pricedAt: '2026-11-26T10:00:00Z' },
  }
}

describe('Venice models on the server', () => {
  let venice: FakeVenice
  let server: HttpServer
  let veniceURL = ''
  let s: Server
  let device = ''
  let client = ''

  before(async () => {
    venice = new FakeVenice()
    const v = await listen(venice.handle)
    server = v.server
    veniceURL = v.url
  })
  after(() => server.close())

  beforeEach(async () => {
    venice.requests = []
    s = await buildServer({
      db: openDatabase(':memory:'), sealer: sealer(randomBytes(32)), wrongKeyDelayMs: 0,
      manager: { runpodBase: 'http://127.0.0.1:9', apiBaseURL: (p) => (p === 'venice' ? `${veniceURL}/api/v1` : null) },
    })
    const code = s.pairing.issue().code
    device = (await s.app.inject({ method: 'POST', url: '/pair', payload: { code, deviceName: 'Test Mac' } })).json().token
    await admin('PATCH', '/admin/settings', { dailyLimitUsd: 10 })
    const put = await admin('PUT', `/admin/models/${MODEL_ID}`, veniceModel())
    assert.equal(put.statusCode, 200, put.body)
    client = (await admin('POST', '/admin/client-tokens', { name: 'agent', models: null })).json().token
  })

  const admin = (method: 'GET' | 'POST' | 'PUT' | 'PATCH', url: string, payload?: unknown) =>
    s.app.inject({ method, url, headers: { authorization: `Bearer ${device}` }, ...(payload === undefined ? {} : { payload: payload as object }) })
  const agent = (url: string, payload: object) =>
    s.app.inject({ method: 'POST', url, headers: { authorization: `Bearer ${client}` }, payload })
  const settle = () => new Promise((resolve) => setTimeout(resolve, 20))

  test('a Venice key is checked, stored write-only and reported with its balance', async () => {
    const wrong = (await admin('POST', '/admin/settings/verify-venice', { veniceApiKey: 'nope' })).json()
    assert.equal(wrong.result, 'invalid')
    const right = (await admin('POST', '/admin/settings/verify-venice', { veniceApiKey: 'VENICE_INFERENCE_KEY_test' })).json()
    assert.equal(right.result, 'valid')
    assert.equal(right.account.balances[0].amount, 12.5)
    await admin('PATCH', '/admin/settings', { veniceApiKey: 'VENICE_INFERENCE_KEY_test' })
    const settings = (await admin('GET', '/admin/settings')).json()
    assert.equal(settings.hasVeniceKey, true)
    assert.equal(JSON.stringify(settings).includes('VENICE_INFERENCE_KEY_test'), false)
    await s.manager.refreshVeniceAccount()
    const state = (await admin('GET', '/admin/state')).json()
    assert.equal(state.veniceAccount.balances[0].amount, 12.5)
    const catalog = (await admin('GET', '/admin/catalog/venice')).json()
    assert.ok(catalog.models.some((m: { providerModelId: string }) => m.providerModelId === 'venice-uncensored-1-2'))
  })

  test('without a key the agent hears that setup is incomplete, and Venice is not asked', async () => {
    const r = await agent('/v1/chat/completions', { model: 'uncensored', messages: [{ role: 'user', content: 'Hi' }] })
    assert.equal(r.statusCode, 503)
    assert.equal(r.json().error.code, 'setup_incomplete')
    assert.equal(venice.requests.length, 0)
  })

  test('requests are rewritten, metered and booked; errors and limits answer like Modlight', async () => {
    await admin('PATCH', '/admin/settings', { veniceApiKey: 'VENICE_INFERENCE_KEY_test' })
    const plain = await agent('/v1/chat/completions', { model: 'uncensored', messages: [{ role: 'user', content: 'Hi' }] })
    assert.equal(plain.statusCode, 200)
    assert.ok(plain.body.includes('Hallo'))
    const sent = venice.requests.at(-1)!
    assert.equal(sent.path, '/api/v1/chat/completions')
    assert.equal(sent.auth, 'Bearer VENICE_INFERENCE_KEY_test')
    assert.equal(sent.body.model, 'venice-uncensored-1-2')
    assert.equal(sent.body.venice_parameters.include_venice_system_prompt, false)
    assert.equal(sent.body.prompt_cache_key, undefined, 'no system prompt, no cache key')
    await agent('/v1/chat/completions', { model: 'uncensored', messages: [{ role: 'system', content: 'You are Claude Code.' }, { role: 'user', content: 'Hi' }] })
    assert.match(String(venice.requests.at(-1)!.body.prompt_cache_key), /^modlight-[0-9a-f]{32}$/)

    const stream = await agent('/v1/chat/completions', { model: 'uncensored', stream: true, messages: [{ role: 'user', content: 'Hi' }] })
    assert.ok(stream.body.includes('"content":"Hal"') && stream.body.includes('[DONE]'))
    assert.equal(stream.body.includes('prompt_tokens'), false, 'the usage chunk is not passed to an agent that did not ask')
    await settle()

    const state = (await admin('GET', '/admin/state')).json()
    const live = state.apiTelemetry[MODEL_ID]
    assert.equal(live.samples.length, 3)
    const streamedSample = live.samples.at(-1)
    assert.equal(streamedSample.streamed, true)
    assert.ok(streamedSample.ttftMs !== undefined && streamedSample.durationMs >= streamedSample.ttftMs)
    assert.equal(live.rateLimit.remainingRequests, 66)
    assert.equal(Object.values(state.apiUsageByHour).length, 1)
    const day = Object.keys(state.apiUsage)[0]!
    const totals = state.apiUsage[day][MODEL_ID]
    assert.equal(totals.requests, 3)
    const expected = 0.25 * 2 + offer.pricing.input + offer.pricing.output * 0.5
    assert.ok(Math.abs(state.spendByDay[day] - expected) < 1e-9, `spend ${state.spendByDay[day]} vs ${expected}`)

    const messages = await agent('/v1/messages', { model: 'uncensored', max_tokens: 100, stream: true, messages: [{ role: 'user', content: 'Hi' }] })
    assert.equal(messages.statusCode, 200)
    assert.ok(messages.body.includes('event: message_start') && messages.body.includes('"text":"Hal"') && messages.body.includes('event: message_stop'))
    const count = await agent('/v1/messages/count_tokens', { model: 'uncensored', messages: [{ role: 'user', content: 'Hello there' }] })
    assert.ok(count.json().input_tokens > 0)

    const broke = await agent('/v1/messages', { model: 'uncensored', max_tokens: 10, messages: [{ role: 'user', content: 'broke' }] })
    assert.equal(broke.statusCode, 402)
    assert.equal(broke.json().error.type, 'billing_error')
    const legacy = await agent('/v1/completions', { model: 'uncensored', prompt: 'Hi' })
    assert.equal(legacy.statusCode, 404)
    assert.equal(legacy.json().error.code, 'unsupported_endpoint')

    await admin('PATCH', '/admin/settings', { dailyLimitUsd: 0.01 })
    const before = venice.requests.length
    const limited = await agent('/v1/chat/completions', { model: 'uncensored', messages: [{ role: 'user', content: 'Hi' }] })
    assert.equal(limited.statusCode, 429)
    assert.equal(limited.json().error.code, 'spend_limit')
    assert.equal(venice.requests.length, before)
  })

  test('starting an API model asks RunPod nothing', async () => {
    const r = await admin('POST', `/admin/models/${MODEL_ID}/start`, {})
    assert.equal(r.statusCode, 200, r.body)
    assert.equal(r.json().podId, undefined)
  })
})
