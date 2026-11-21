import { Readable } from 'node:stream'
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import { Agent, fetch as undiciFetch } from 'undici'
import type { Identity, TokenStore } from '../auth/tokens.ts'
import type { PodManager } from '../pods/manager.ts'
import type { StateStore } from '../store/state.ts'
import { errorBody, failure, GatewayFailure, systemMessagesAsReminders } from './shape.ts'

// The endpoint agents talk to: OpenAI-compatible, plus the Responses API (Codex) and the
// Anthropic Messages API (Claude Code), passed through to the engine. Port of LocalGateway.swift.
// Every request needs a client token; the `model` field picks the model; a stopped pod is woken
// (spend limits checked first) and the request held until it answers.

export const FORWARDED_PATHS = [
  '/v1/chat/completions', '/v1/completions', '/v1/embeddings',
  '/v1/responses', '/v1/responses/input_tokens',
  '/v1/messages', '/v1/messages/count_tokens',
]

/** Request headers the engine needs to see unchanged. */
const PASSED_HEADERS = ['anthropic-version', 'anthropic-beta', 'openai-beta', 'accept']

/** Long prefills and generations: Node's default 300 s header timeout is too short. */
const upstreamAgent = new Agent({ headersTimeout: 900_000, bodyTimeout: 900_000, connectTimeout: 30_000 })

export const BODY_LIMIT = 64 * 1024 * 1024

/** Tries after a proxy 404, 5 s apart: up to 30 s for RunPod's proxy to start routing. */
const PROXY_RETRIES = 6

/** An engine answers with JSON; RunPod's proxy, before it routes to the pod, does not. */
export const isProxyNotReady = (response: Response): boolean =>
  response.status === 404 && !(response.headers.get('content-type') ?? '').includes('application/json')

interface Deps {
  tokens: TokenStore
  manager: PodManager
  store: StateStore
  fetch?: typeof fetch
  /** Pause after a wrong key, so guessing is slow. */
  wrongKeyDelayMs?: number
  /** Wait between tries while RunPod's proxy is not yet routing. */
  proxyRetryDelayMs?: number
}

declare module 'fastify' {
  interface FastifyRequest {
    client?: Identity
  }
}

/** A client token limited to models may use only those. */
const allowed = (identity: Identity | undefined, modelId: string): boolean =>
  !identity?.models || identity.models.some((id) => id.toLowerCase() === modelId.toLowerCase())

const isAnthropic = (url: string): boolean => url.startsWith('/v1/messages')

function send(reply: FastifyReply, status: number, message: string, code: string, anthropic: boolean): FastifyReply {
  return reply.code(status).type('application/json').send(errorBody(status, message, code, anthropic))
}

export function presentedKey(request: FastifyRequest): string {
  const header = request.headers.authorization ?? ''
  const bearer = header.startsWith('Bearer ') ? header.slice(7).trim() : ''
  if (bearer) return bearer
  const apiKey = request.headers['x-api-key']
  return (Array.isArray(apiKey) ? apiKey[0] : apiKey)?.trim() ?? ''
}

export async function registerGateway(app: FastifyInstance, deps: Deps): Promise<void> {
  const upstreamFetch = deps.fetch ?? (undiciFetch as unknown as typeof fetch)
  const delay = deps.wrongKeyDelayMs ?? 1000
  const retryDelay = deps.proxyRetryDelayMs ?? 5000

  await app.register(async (scope) => {
    // The body is forwarded byte for byte, so it is kept raw and parsed only to read `model`.
    scope.removeAllContentTypeParsers()
    scope.addContentTypeParser('*', { parseAs: 'buffer', bodyLimit: BODY_LIMIT }, (_req, body, done) => done(null, body))

    scope.addHook('onRequest', async (request, reply) => {
      const identity = deps.tokens.verify('client', presentedKey(request))
      if (!identity) {
        await new Promise((resolve) => setTimeout(resolve, delay))
        return send(reply, 401, 'Wrong or missing API key. Create one in the Podlight app under this server → Connection.',
          'invalid_api_key', isAnthropic(request.url))
      }
      request.client = identity
      deps.manager.clientSeen()
    })

    scope.get('/v1/models', async (request) => {
      const models = deps.store.models().filter((m) => allowed(request.client, m.id))
      // OpenAI's fields, plus Anthropic's `type` and `display_name` for Claude Code's model list.
      const data = models.map((m) => {
        const created = m.createdAt ? new Date(m.createdAt) : new Date(0)
        return {
          id: m.name, object: 'model', type: 'model', display_name: m.name, owned_by: 'podlight',
          created: Math.floor(created.getTime() / 1000), created_at: created.toISOString().replace(/\.\d{3}Z$/, 'Z'),
          max_model_len: m.contextTokens, context_length: m.contextTokens,
        }
      })
      return { object: 'list', data, has_more: false, ...(data.length ? { first_id: data[0]!.id, last_id: data.at(-1)!.id } : {}) }
    })

    for (const path of FORWARDED_PATHS) {
      scope.post(path, async (request, reply) => forward(request, reply, path))
    }
  })

  async function forward(request: FastifyRequest, reply: FastifyReply, path: string): Promise<FastifyReply> {
    const anthropic = isAnthropic(path)
    let data = Buffer.isBuffer(request.body) ? request.body : Buffer.alloc(0)
    let json: Record<string, unknown>
    try {
      const parsed = JSON.parse(data.toString('utf8')) as unknown
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) throw new Error('not an object')
      json = parsed as Record<string, unknown>
    } catch {
      return send(reply, 400, 'The request body is not JSON.', 'invalid_json', anthropic)
    }
    if (anthropic) {
      const fixed = systemMessagesAsReminders(json)
      if (fixed) data = Buffer.from(JSON.stringify(fixed))
    }
    const name = typeof json.model === 'string' ? json.model : ''
    if (!name) {
      const names = deps.store.models().filter((m) => allowed(request.client, m.id)).map((m) => m.name)
      return send(reply, 400, `Set "model" to one of: ${names.join(', ')}.`, 'model_missing', anthropic)
    }

    const model = deps.store.modelNamed(name)
    if (model && !allowed(request.client, model.id)) {
      const f = failure({ kind: 'notAllowed' }, name)
      return send(reply, f.status, f.message, f.code, anthropic)
    }

    let endpoint
    try {
      endpoint = await deps.manager.endpoint(name)
    } catch (error) {
      if (error instanceof GatewayFailure) {
        const f = failure(error.error, name)
        return send(reply, f.status, f.message, f.code, anthropic)
      }
      throw error
    }

    deps.manager.requestBegan(endpoint.modelId)
    let ended = false
    const end = (): void => {
      if (ended) return
      ended = true
      deps.manager.requestEnded(endpoint.modelId)
    }

    // Claude Code sends `?beta=true`; keep any query as it came.
    const query = request.url.includes('?') ? request.url.slice(request.url.indexOf('?')) : ''
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${endpoint.key}`,
    }
    for (const header of PASSED_HEADERS) {
      const value = request.headers[header]
      if (typeof value === 'string') headers[header] = value
    }

    // A client that goes away stops the generation it asked for.
    const abort = new AbortController()
    // The request's own 'close' has already fired once Fastify read the body; the response's
    // fires when the connection goes away, and before it finished only if the client left.
    reply.raw.on('close', () => { if (!reply.raw.writableFinished) abort.abort() })

    // RunPod's proxy answers 404 without JSON while it is not yet routing to a freshly started
    // pod, even after the engine reported ready (seen live 2026-11-21: the first request after a
    // wake). The request is held anyway, so it is tried again for a while instead of passing a
    // misleading 404 on to the agent.
    let upstream: Response | null = null
    for (let attempt = 0; attempt <= PROXY_RETRIES; attempt++) {
      try {
        upstream = await upstreamFetch(`${endpoint.baseURL}${path}${query}`, {
          method: 'POST', headers, body: data, signal: abort.signal,
          // undici's own option; the global fetch types do not know it.
          dispatcher: upstreamAgent,
        } as RequestInit)
      } catch (error) {
        end()
        return send(reply, 502, `The pod for ${name} did not answer: ${(error as Error).message}`, 'upstream_unreachable', anthropic)
      }
      if (!isProxyNotReady(upstream)) break
      await upstream.body?.cancel().catch(() => {})
      if (attempt < PROXY_RETRIES) await new Promise((resolve) => setTimeout(resolve, retryDelay))
    }
    if (!upstream || isProxyNotReady(upstream)) {
      end()
      const f = failure({ kind: 'notReadyInTime' }, name)
      reply.header('retry-after', '30')
      return send(reply, f.status, f.message, f.code, anthropic)
    }

    reply.code(upstream.status)
    reply.header('content-type', upstream.headers.get('content-type') ?? 'application/json')
    reply.header('cache-control', 'no-cache')
    if (!upstream.body) {
      end()
      return reply.send('')
    }
    const stream = Readable.fromWeb(upstream.body as import('node:stream/web').ReadableStream)
    stream.on('end', end)
    stream.on('error', end)
    stream.on('close', end)
    return reply.send(stream)
  }
}
