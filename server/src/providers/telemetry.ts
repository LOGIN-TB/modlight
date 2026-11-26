// Live telemetry of API models: one sample per request, the provider's rate-limit headers, and
// the half-hour summary. Port of Providers/APITelemetry.swift; held to spec/cases/api-telemetry.json.

import { createHash } from 'node:crypto'

type Json = Record<string, unknown>
const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value)

export interface APIRequestSample {
  /** ISO 8601, when the answer ended. */
  time: string
  promptTokens: number
  cachedTokens: number
  completionTokens: number
  usd: number
  ttftMs?: number
  durationMs: number
  status: number
  streamed: boolean
}

export interface APIRateLimit {
  limitRequests?: number
  remainingRequests?: number
  resetRequests?: string
  limitTokens?: number
  remainingTokens?: number
  resetTokens?: string
  at: string
}

export interface Minute { start: string; newInput: number; cachedInput: number; output: number; usd: number; requests: number }

export interface APITelemetrySummary {
  minutes: Minute[]
  requests: number
  requestsPerMinute: number
  cacheShare?: number
  ttftP50Ms?: number
  tokensPerSecondMedian?: number
  errorShare?: number
  usdPerHour: number
  averagePromptTokens?: number
  runwayHours?: number
}

export const WINDOW_MS = 30 * 60 * 1000

/** ISO 8601 without fractional seconds, as Swift writes dates. */
export const isoSeconds = (date: Date): string => date.toISOString().replace(/\.\d{3}Z$/, 'Z')

export function outputTokensPerSecond(s: APIRequestSample): number | null {
  if (!s.streamed || s.ttftMs == null || s.durationMs <= s.ttftMs || s.completionTokens <= 0) return null
  return s.completionTokens / ((s.durationMs - s.ttftMs) / 1000)
}

function lowerMedian(values: number[]): number | null {
  if (values.length === 0) return null
  return [...values].sort((a, b) => a - b)[Math.floor((values.length - 1) / 2)]!
}

export function summary(samples: APIRequestSample[], now: Date, balanceUsd: number | null): APITelemetrySummary {
  const t = now.getTime()
  const at = (s: APIRequestSample): number => Date.parse(s.time)
  const recent = samples.filter((s) => at(s) > t - WINDOW_MS && at(s) <= t)
  const current = Math.floor(t / 60_000) * 60_000
  const starts = Array.from({ length: 30 }, (_, i) => current - (29 - i) * 60_000)
  const minutes: Minute[] = starts.map((start) => ({ start: isoSeconds(new Date(start)), newInput: 0, cachedInput: 0, output: 0, usd: 0, requests: 0 }))
  for (const s of recent) {
    const offset = Math.floor((at(s) - starts[0]!) / 60_000)
    if (offset < 0 || offset >= 30) continue
    const m = minutes[offset]!
    m.newInput += Math.max(0, s.promptTokens - s.cachedTokens)
    m.cachedInput += s.cachedTokens
    m.output += s.completionTokens
    m.usd += s.usd
    m.requests += 1
  }
  const prompt = recent.reduce((sum, s) => sum + s.promptTokens, 0)
  const cached = recent.reduce((sum, s) => sum + s.cachedTokens, 0)
  const answered = recent.filter((s) => s.status < 400 && s.promptTokens > 0)
  const lastFive = recent.filter((s) => at(s) > t - 5 * 60_000).length
  const usdPerHour = recent.filter((s) => at(s) > t - 15 * 60_000).reduce((sum, s) => sum + s.usd, 0) * 4
  const errors = recent.filter((s) => s.status >= 400).length
  const out: APITelemetrySummary = { minutes, requests: recent.length, requestsPerMinute: lastFive / 5, usdPerHour }
  if (prompt > 0) out.cacheShare = cached / prompt
  const ttft = lowerMedian(recent.flatMap((s) => (s.ttftMs == null ? [] : [s.ttftMs])))
  if (ttft !== null) out.ttftP50Ms = ttft
  const speed = lowerMedian(recent.flatMap((s) => { const v = outputTokensPerSecond(s); return v === null ? [] : [v] }))
  if (speed !== null) out.tokensPerSecondMedian = speed
  if (recent.length) out.errorShare = errors / recent.length
  if (answered.length) out.averagePromptTokens = Math.floor(answered.reduce((sum, s) => sum + s.promptTokens, 0) / answered.length)
  if (balanceUsd != null && usdPerHour > 0 && balanceUsd > 0) out.runwayHours = balanceUsd / usdPerHour
  return out
}

/** Venice's `x-ratelimit-{limit,remaining,reset}-{requests,tokens}`; resets are Unix ms. Null without any. */
export function rateLimitFromHeaders(headers: Record<string, string>, at: Date): APIRateLimit | null {
  const lowered = new Map(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v).trim()]))
  const int = (name: string): number | undefined => {
    const v = lowered.get(`x-ratelimit-${name}`)
    if (v === undefined) return undefined
    const n = Number(v)
    return Number.isFinite(n) ? Math.trunc(n) : undefined
  }
  const date = (name: string): string | undefined => {
    const v = lowered.get(`x-ratelimit-${name}`)
    const n = v === undefined ? NaN : Number(v)
    return Number.isFinite(n) ? isoSeconds(new Date(n)) : undefined
  }
  const fields: Omit<APIRateLimit, 'at'> = {
    limitRequests: int('limit-requests'), remainingRequests: int('remaining-requests'), resetRequests: date('reset-requests'),
    limitTokens: int('limit-tokens'), remainingTokens: int('remaining-tokens'), resetTokens: date('reset-tokens'),
  }
  if ([fields.limitRequests, fields.remainingRequests, fields.limitTokens, fields.remainingTokens].every((v) => v === undefined)) return null
  const out: APIRateLimit = { at: isoSeconds(at) }
  for (const [k, v] of Object.entries(fields)) if (v !== undefined) (out as unknown as Record<string, unknown>)[k] = v
  return out
}

/** A stream chunk with model output (text, reasoning, a tool call): its arrival is the first token. */
export function hasContent(chunk: Json): boolean {
  if (typeof chunk.type === 'string') return chunk.type.endsWith('.delta')
  if (!Array.isArray(chunk.choices)) return false
  return chunk.choices.some((choice) => {
    const delta = isObject(choice) && isObject(choice.delta) ? choice.delta : {}
    for (const key of ['content', 'reasoning_content', 'reasoning']) {
      if (typeof delta[key] === 'string' && (delta[key] as string).length > 0) return true
    }
    return Array.isArray(delta.tool_calls) && delta.tool_calls.length > 0
  })
}

/** The same model and system prompt give the same key, so Venice keeps an agent on one cache. */
export function cacheKey(body: Json, providerModelId: string): string | null {
  let system = typeof body.instructions === 'string' ? body.instructions : ''
  for (const message of Array.isArray(body.messages) ? body.messages : []) {
    if (!isObject(message) || (message.role !== 'system' && message.role !== 'developer')) continue
    if (typeof message.content === 'string') system += message.content
    else if (Array.isArray(message.content)) {
      system += message.content.filter(isObject).map((p) => (typeof p.text === 'string' ? p.text : '')).join('')
    }
  }
  if (!system) return null
  return 'podlight-' + createHash('sha256').update(`${providerModelId}\n${system}`).digest('hex').slice(0, 32)
}
