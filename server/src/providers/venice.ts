// Venice.ai (https://docs.venice.ai): the catalog of ready models and the key's account. Port of
// VeniceClient.swift; the parsing is held to spec/cases/api-provider.json.

import type { APIPricing, APIPrivacy, APIRates } from '../model.ts'
import { VENICE_BASE_URL } from './api.ts'

type Json = Record<string, unknown>
const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value)
const num = (value: unknown): number | null => (typeof value === 'number' && Number.isFinite(value) ? value : null)

export interface APIModelOffer {
  provider: 'venice'
  providerModelId: string
  displayName: string
  description?: string
  contextTokens: number
  maxCompletionTokens?: number
  privacy: APIPrivacy
  capabilities: string[]
  traits: string[]
  pricing: APIPricing
  removesAt?: string
  suggestedName: string
}

export interface APIAccount {
  balances: { currency: string; amount: number }[]
  tier?: string
  keyExpiration?: string
  nextEpochBegins?: string
  rateLimits: { model: string; type: string; amount: number }[]
}

/** `Qwen/Qwen3-8B` → `qwen3-8b`, as ModlightModel.suggestedName in Swift. */
export function suggestedName(id: string): string {
  const last = id.split('/').filter(Boolean).pop() ?? id
  return last.toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '')
}

/** ISO 8601 without fractional seconds, as Swift writes dates. */
const isoDate = (text: string): string | undefined => {
  const d = new Date(text)
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

function rates(json: Json): APIRates | null {
  const usd = (key: string): number | null => (isObject(json[key]) ? num((json[key] as Json).usd) : null)
  const input = usd('input')
  const output = usd('output')
  if (input === null || output === null) return null
  const r: APIRates = { input, output }
  const read = usd('cache_input')
  const write = usd('cache_write')
  if (read !== null) r.cacheRead = read
  if (write !== null) r.cacheWrite = write
  return r
}

export function pricing(json: unknown): APIPricing | null {
  if (!isObject(json)) return null
  const base = rates(json)
  if (!base) return null
  const p: APIPricing = { ...base }
  const extended = json.extended
  if (isObject(extended)) {
    const r = rates(extended)
    const threshold = num(extended.context_token_threshold)
    if (r && threshold !== null) {
      p.extendedAboveTokens = threshold
      p.extended = r
    }
  }
  return p
}

/** One catalog entry as an offer; null for offline, non-text or unpriced models. */
export function offer(entry: Json): APIModelOffer | null {
  const id = entry.id
  if (typeof id !== 'string' || !id) return null
  if (typeof entry.type === 'string' && entry.type !== 'text') return null
  const spec = isObject(entry.model_spec) ? entry.model_spec : {}
  if (spec.offline === true) return null
  const p = pricing(spec.pricing)
  if (!p) return null
  const context = num(entry.context_length) ?? num(spec.availableContextTokens) ?? 0
  if (context <= 0) return null
  const caps = isObject(spec.capabilities) ? spec.capabilities : {}
  const capabilities = ([['supportsFunctionCalling', 'tools'], ['supportsVision', 'vision'], ['supportsReasoning', 'reasoning'], ['optimizedForCode', 'code']] as const)
    .filter(([key]) => caps[key] === true).map(([, name]) => name)
  const name = typeof spec.name === 'string' && spec.name ? spec.name : id
  const o: APIModelOffer = {
    provider: 'venice', providerModelId: id, displayName: name, contextTokens: context,
    privacy: spec.privacy === 'private' || spec.privacy === 'anonymized' ? spec.privacy : 'anonymized',
    capabilities, traits: Array.isArray(spec.traits) ? spec.traits.filter((t): t is string => typeof t === 'string') : [],
    pricing: p, suggestedName: suggestedName(id),
  }
  if (typeof spec.description === 'string' && spec.description) o.description = spec.description
  const max = num(spec.maxCompletionTokens)
  if (max !== null) o.maxCompletionTokens = max
  const removes = isObject(spec.deprecation) && typeof spec.deprecation.removesAt === 'string' ? isoDate(spec.deprecation.removesAt) : undefined
  if (removes) o.removesAt = removes
  return o
}

export function offers(json: unknown): APIModelOffer[] {
  if (!isObject(json) || !Array.isArray(json.data)) throw new Error('no model list in the answer')
  return json.data.filter(isObject).map(offer).filter((o): o is APIModelOffer => o !== null)
}

/** `GET /api_keys/rate_limits` (any key type may ask). */
export function account(json: unknown): APIAccount {
  if (!isObject(json) || !isObject(json.data)) throw new Error('no account in the answer')
  const body = json.data
  const raw = isObject(body.balances) ? body.balances : {}
  const balances = ['USD', 'DIEM', 'BUNDLED_CREDITS'].flatMap((currency) => {
    const amount = num(raw[currency])
    return amount === null ? [] : [{ currency, amount }]
  })
  const rateLimits = (Array.isArray(body.rateLimits) ? body.rateLimits : []).filter(isObject).flatMap((entry) => {
    const model = typeof entry.apiModelId === 'string' ? entry.apiModelId : ''
    return (Array.isArray(entry.rateLimits) ? entry.rateLimits : []).filter(isObject).flatMap((l) => {
      const amount = num(l.amount)
      return typeof l.type === 'string' && amount !== null ? [{ model, type: l.type, amount }] : []
    })
  })
  const result: APIAccount = { balances, rateLimits }
  if (isObject(body.apiTier) && typeof body.apiTier.id === 'string') result.tier = body.apiTier.id
  const expiry = typeof body.keyExpiration === 'string' ? isoDate(body.keyExpiration) : undefined
  if (expiry) result.keyExpiration = expiry
  const epoch = typeof body.nextEpochBegins === 'string' ? isoDate(body.nextEpochBegins) : undefined
  if (epoch) result.nextEpochBegins = epoch
  return result
}

export type KeyCheck = { valid: true; account: APIAccount } | { valid: false; reason: 'invalid' | 'unreachable'; message?: string }

export class VeniceClient {
  private readonly apiKey: string | null
  private readonly baseURL: string
  private readonly fetcher: typeof fetch

  constructor(apiKey: string | null, baseURL: string = VENICE_BASE_URL, fetcher: typeof fetch = fetch) {
    this.apiKey = apiKey
    this.baseURL = baseURL
    this.fetcher = fetcher
  }

  /** Text models Venice serves now; the catalog needs no key. */
  async catalog(): Promise<APIModelOffer[]> {
    return offers(await this.get('/models?type=text', false))
  }

  async account(): Promise<APIAccount> {
    return account(await this.get('/api_keys/rate_limits', true))
  }

  async checkKey(): Promise<KeyCheck> {
    try {
      return { valid: true, account: await this.account() }
    } catch (error) {
      if (error instanceof VeniceError && (error.status === 401 || error.status === 403)) return { valid: false, reason: 'invalid' }
      return { valid: false, reason: 'unreachable', message: error instanceof Error ? error.message : String(error) }
    }
  }

  private async get(path: string, auth: boolean): Promise<unknown> {
    const headers: Record<string, string> = { accept: 'application/json' }
    if (auth) {
      if (!this.apiKey) throw new VeniceError(401, 'no key')
      headers.authorization = `Bearer ${this.apiKey}`
    }
    const response = await this.fetcher(`${this.baseURL}${path}`, { headers, signal: AbortSignal.timeout(30_000) })
    const text = await response.text()
    if (!response.ok) throw new VeniceError(response.status, text.slice(0, 500))
    return JSON.parse(text)
  }
}

export class VeniceError extends Error {
  readonly status: number
  readonly body: string
  constructor(status: number, body: string) {
    super(`Venice answered ${status}: ${body.slice(0, 200)}`)
    this.status = status
    this.body = body
  }
}
