// API providers: models someone else serves and bills per token. Port of the pure parts of
// Providers/APIProvider.swift; held to spec/cases/api-provider.json.

import type { APIPricing, APIRates, ModelProvider } from '../model.ts'

type Json = Record<string, unknown>
const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value)
const num = (value: unknown): number | null => (typeof value === 'number' && Number.isFinite(value) ? value : null)

export const VENICE_BASE_URL = 'https://api.venice.ai/api/v1'

export const providerName = (provider: ModelProvider): string => (provider === 'venice' ? 'Venice' : 'RunPod')

export function providerBaseURL(provider: ModelProvider): string | null {
  return provider === 'venice' ? VENICE_BASE_URL : null
}

/** Tokens one request used. `promptTokens` includes cached ones (OpenAI's `prompt_tokens`). */
export interface APIUsage {
  promptTokens: number
  completionTokens: number
  cachedTokens: number
  cacheWriteTokens: number
  /** The provider's own price for the request, when the answer carries one. */
  providerCostUsd?: number
}

/** `usage` (Chat Completions or Responses shape) and `cost.usd` from an answer, a final stream
 * chunk or a `response.completed` event. Null without usage. */
export function usageFrom(json: Json): APIUsage | null {
  const holder = isObject(json.response) && json.response.usage !== undefined ? json.response : json
  const usage = holder.usage
  if (!isObject(usage)) return null
  const prompt = num(usage.prompt_tokens) ?? num(usage.input_tokens)
  const completion = num(usage.completion_tokens) ?? num(usage.output_tokens)
  if (prompt === null && completion === null) return null
  const details = (isObject(usage.prompt_tokens_details) ? usage.prompt_tokens_details
    : isObject(usage.input_tokens_details) ? usage.input_tokens_details : {}) as Json
  const cached = num(details.cached_tokens) ?? num(usage.cache_read_input_tokens) ?? 0
  const written = num(details.cache_creation_tokens) ?? num(details.cache_write_tokens) ?? num(usage.cache_creation_input_tokens) ?? 0
  const costHolder = isObject(holder.cost) ? holder.cost : isObject(json.cost) ? json.cost : null
  const result: APIUsage = { promptTokens: prompt ?? 0, completionTokens: completion ?? 0, cachedTokens: cached, cacheWriteTokens: written }
  const usd = costHolder ? num(costHolder.usd) : null
  if (usd !== null) result.providerCostUsd = usd
  return result
}

export function ratesFor(pricing: APIPricing, promptTokens: number): APIRates {
  if (pricing.extendedAboveTokens != null && pricing.extended && promptTokens > pricing.extendedAboveTokens) return pricing.extended
  return pricing
}

/** The provider's own figure wins; otherwise tokens × prices, with cached and cache-written
 * prompt tokens taken out of the plain input and billed at their own rates. */
export function costOf(usage: APIUsage, pricing: APIPricing): { usd: number; source: 'provider' | 'computed' } {
  if (usage.providerCostUsd != null && usage.providerCostUsd >= 0) return { usd: usage.providerCostUsd, source: 'provider' }
  const r = ratesFor(pricing, usage.promptTokens)
  const plain = Math.max(0, usage.promptTokens - usage.cachedTokens - usage.cacheWriteTokens)
  const usd = (plain * r.input + usage.cachedTokens * (r.cacheRead ?? r.input)
    + usage.cacheWriteTokens * (r.cacheWrite ?? r.input) + usage.completionTokens * r.output) / 1_000_000
  return { usd, source: 'computed' }
}

/** `model` becomes the provider's id; a streamed chat completion always asks for usage; Venice's
 * own system prompt is turned off unless the agent set `venice_parameters`. */
export function rewriteForProvider(body: Json, path: string, provider: ModelProvider, providerModelId: string): { body: Json; clientWantsUsage: boolean } {
  const out: Json = { ...body, model: providerModelId }
  let wantsUsage = true
  if (path === '/v1/chat/completions') {
    if (out.stream === true) {
      const options: Json = isObject(out.stream_options) ? { ...out.stream_options } : {}
      wantsUsage = options.include_usage === true
      options.include_usage = true
      out.stream_options = options
    }
    if (provider === 'venice' && out.venice_parameters === undefined) out.venice_parameters = { include_venice_system_prompt: false }
  }
  return { body: out, clientWantsUsage: wantsUsage }
}

const VENICE_PATHS = new Set(['/v1/chat/completions', '/v1/responses', '/v1/embeddings', '/v1/messages', '/v1/messages/count_tokens'])

export function supportsPath(path: string, provider: ModelProvider): boolean {
  return provider === 'runpod' || VENICE_PATHS.has(path)
}

export interface ProviderFailure { status: number; code: string; message: string }

/** A provider's error answer as Podlight's own: used-up balance, key limit, refused key, rate
 * limit; anything else keeps its status. */
export function providerFailure(provider: ModelProvider, status: number, text: string): ProviderFailure {
  let json: Json | null = null
  try { const parsed = JSON.parse(text); json = isObject(parsed) ? parsed : null } catch { /* not JSON */ }
  const error = json?.error
  const detail = typeof error === 'string' ? error
    : isObject(error) ? (typeof error.message === 'string' ? error.message : typeof error.code === 'string' ? error.code : text)
      : typeof json?.message === 'string' ? json.message : text
  const code = (isObject(error) && typeof error.code === 'string' ? error.code : typeof json?.code === 'string' ? json.code : '')
  const haystack = `${code} ${text}`.toUpperCase()
  const name = providerName(provider)
  if (haystack.includes('API_KEY_USD_SPEND_LIMIT_EXCEEDED') || haystack.includes('API_KEY_DIEM_SPEND_LIMIT_EXCEEDED')) {
    return { status: 402, code: 'provider_key_limit', message: `The ${name} API key reached its own spending limit for today. Raise it at venice.ai → Settings → API, or wait for the next day.` }
  }
  if (status === 402 || haystack.includes('INSUFFICIENT_BALANCE')) {
    return { status: 402, code: 'provider_balance', message: `Your ${name} balance is used up. Top it up at venice.ai, then try again.` }
  }
  if (status === 401 || status === 403) {
    return { status: 502, code: 'provider_auth', message: `${name} refused the server's API key (${status}). Check it in the Podlight app under this server.` }
  }
  if (status === 429) return { status: 429, code: 'provider_rate_limit', message: `${name} is rate-limiting this key. Try again in a moment.` }
  const shown = detail ? detail.slice(0, 300) : 'no details'
  return { status: status >= 400 && status < 600 ? status : 502, code: 'provider_error', message: `${name} answered ${status}: ${shown}` }
}

/** Tokens and cost one model used on one day. */
export interface APIUsageTotals { requests: number; promptTokens: number; completionTokens: number; cachedTokens: number; usd: number }

export const emptyTotals = (): APIUsageTotals => ({ requests: 0, promptTokens: 0, completionTokens: 0, cachedTokens: 0, usd: 0 })

export function addUsage(totals: APIUsageTotals, usage: APIUsage, usd: number): APIUsageTotals {
  return {
    requests: totals.requests + 1, promptTokens: totals.promptTokens + usage.promptTokens,
    completionTokens: totals.completionTokens + usage.completionTokens, cachedTokens: totals.cachedTokens + usage.cachedTokens,
    usd: totals.usd + usd,
  }
}
