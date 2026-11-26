// What the gateway changes in a request and what it answers on failure. Port of the pure parts of
// LocalGateway.swift; held to spec/cases/gateway.json.

import type { ModelProvider, PricedChoice } from '../model.ts'
import { providerName, type ProviderFailure } from '../providers/api.ts'

type Json = Record<string, unknown>

/** "$1.19" */
const dollars = (value: number): string => `$${value.toFixed(2)}`

/**
 * Claude Code puts entries with `role: "system"` into `messages` after the first user turn. The
 * engines turn each into another system message, and many chat templates (Qwen's) refuse that.
 * They are handed on in the same place as user text inside `<system-reminder>`, so the prefix the
 * engine caches stays the same. Null when there is nothing to change: forward the body unchanged.
 */
export function systemMessagesAsReminders(body: Json): Json | null {
  const messages = body.messages
  if (!Array.isArray(messages) || !messages.some((m) => isObject(m) && m.role === 'system')) return null
  const rewritten = messages.map((m) => {
    if (!isObject(m) || m.role !== 'system') return m
    let text = ''
    if (typeof m.content === 'string') text = m.content
    else if (Array.isArray(m.content)) {
      text = m.content.filter(isObject).map((b) => b.text).filter((t): t is string => typeof t === 'string').join('\n\n')
    }
    return { role: 'user', content: [{ type: 'text', text: `<system-reminder>\n${text}\n</system-reminder>` }] }
  })
  return { ...body, messages: rewritten }
}

const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value)

/** Things that stop a request, each with its own sentence. Mirrors PodlightError in Swift. */
export type GatewayError =
  | { kind: 'unknownModel' }
  | { kind: 'missingRunpodKey' }
  | { kind: 'limitReached'; limit: string }
  | { kind: 'noCapacity'; tried: string[] }
  | { kind: 'noSuitableCard' }
  | { kind: 'notReadyInTime' }
  | { kind: 'wakeDisabled' }
  | { kind: 'runpod'; status: number; message: string }
  | { kind: 'notAllowed' }
  | { kind: 'hostBusy' }
  | { kind: 'cardTooExpensive'; wanted: PricedChoice | null; ceiling: number; pricier: PricedChoice[] }
  | { kind: 'missingProviderKey'; provider: ModelProvider }
  | { kind: 'provider'; failure: ProviderFailure }
  | { kind: 'unsupportedPath'; path: string; provider: ModelProvider }

export class GatewayFailure extends Error {
  readonly error: GatewayError
  constructor(error: GatewayError) {
    super(error.kind)
    this.error = error
  }
}

export interface Failure {
  status: number
  message: string
  code: string
}

export function failure(error: GatewayError, model: string): Failure {
  switch (error.kind) {
    case 'unknownModel':
      return { status: 404, code: 'model_not_found', message: `This Podlight server has no model named "${model}". GET /v1/models lists them.` }
    case 'missingRunpodKey':
      return { status: 503, code: 'setup_incomplete', message: 'This Podlight server has no RunPod API key yet. Add it in the Podlight app under this server.' }
    case 'limitReached': {
      const limit = error.limit === 'monthly-limit' ? 'monthly' : 'daily'
      return { status: 429, code: 'spend_limit', message: `The server's ${limit} spending limit is reached, so ${model} stays stopped. Raise the limit in the Podlight app.` }
    }
    case 'noCapacity':
      return { status: 503, code: 'no_capacity', message: `RunPod has no free card for ${model} right now (tried: ${error.tried.join(', ')}). Try again in a few minutes.` }
    case 'noSuitableCard':
      return { status: 503, code: 'no_suitable_card', message: `No RunPod card can hold ${model} with its configured context.` }
    case 'notReadyInTime':
      return { status: 503, code: 'starting', message: `${model} is still starting. A new pod can take up to 25 minutes; a resumed one about a minute. Try again shortly.` }
    case 'wakeDisabled':
      return { status: 503, code: 'stopped', message: `${model} is stopped. Start it in the Podlight app.` }
    case 'runpod':
      return { status: 502, code: 'runpod_error', message: `RunPod refused (${error.status}): ${error.message.slice(0, 200)}` }
    case 'notAllowed':
      return { status: 403, code: 'model_not_allowed', message: `This access key may not use ${model}.` }
    case 'cardTooExpensive': {
      const card = error.wanted ? `${error.wanted.name} at ${dollars(error.wanted.pricePerHour)}/h` : 'The chosen card'
      return { status: 503, code: 'card_too_expensive', message: `${card} for ${model} is taken, and the free cards cost more than the server's price step allows. Nothing was booked; the server keeps trying for a card up to ${dollars(error.ceiling)}/h. Start it on a pricier card in the Podlight app, or try again later.` }
    }
    case 'hostBusy':
      return { status: 503, code: 'host_busy', message: `The card on the machine of ${model}'s pod is taken right now, so it could not resume. Its disk with the model is kept, and the server keeps trying to resume it for half an hour. Try again in a few minutes, or start it on a new card in the Podlight app.` }
    case 'missingProviderKey':
      return { status: 503, code: 'setup_incomplete', message: `This Podlight server has no ${providerName(error.provider)} API key yet. Add it in the Podlight app under this server.` }
    case 'provider':
      return { status: error.failure.status, code: error.failure.code, message: error.failure.message }
    case 'unsupportedPath':
      return { status: 404, code: 'unsupported_endpoint', message: `${model} runs at ${providerName(error.provider)}, which does not serve ${error.path}. Use /v1/chat/completions, /v1/responses or /v1/messages.` }
  }
}

export function anthropicType(status: number): string {
  switch (status) {
    case 400: return 'invalid_request_error'
    case 401: return 'authentication_error'
    case 402: return 'billing_error'
    case 403: return 'permission_error'
    case 404: return 'not_found_error'
    case 429: return 'rate_limit_error'
    case 503: return 'overloaded_error'
    default: return 'api_error'
  }
}

/** OpenAI's error shape, or Anthropic's for the Messages API so Claude Code shows the message. */
export function errorBody(status: number, message: string, code: string, anthropic: boolean): Json {
  if (anthropic) return { type: 'error', error: { type: anthropicType(status), message } }
  return { error: { message, type: 'podlight_error', code } }
}

/** True for an answer made of one or two characters repeated, as a model gives when its numbers are
 * broken ("!!!!…" from an NVFP4 build on an RTX PRO 6000, 2026-11-23). */
export function looksDegenerate(text: string): boolean {
  const characters = [...text].filter((c) => !/\s/.test(c))
  if (characters.length < 16) return false
  return new Set(characters).size <= 2
}

/** `gpu-unusable` when the pod's machine could not use its card at all (CUDA failed before the model
 * was touched), else `engine-exited`. The first is the machine's fault; another machine helps. */
export function engineFailureReason(lines: string[]): string {
  const pattern = /(CUDA unknown error|no CUDA-capable device|CUDA driver version is insufficient|NVIDIA driver on your system is too old|Failed to get device capability|cudaErrorNoDevice|CUDA error: initialization error)/
  return lines.some((l) => pattern.test(l)) ? 'gpu-unusable' : 'engine-exited'
}

/** The error lines of an engine log, or its last lines when none says "error". vLLM runs the engine
 * in a process of its own; when it fails, the API server's last words are only "See root cause
 * above". Then that process's lines are left out, so the engine's own error shows. */
export function summarizeEngineLog(all: string[]): string {
  let lines = all
  const pointer = [...lines].reverse().find((l) => l.includes('root cause above'))
  const prefix = pointer?.match(/^\([^)]*\)/)?.[0]
  if (prefix) {
    const others = lines.filter((l) => !l.startsWith(prefix))
    if (others.length > 0) lines = others
  }
  const pattern = /(Error|Exception|error:|CUDA|out of memory|Traceback|failed to|unable to allocate|error loading model)/
  const errors = lines.filter((l) => pattern.test(l))
  return (errors.length > 0 ? errors : lines).slice(-3).map((l) => l.trim()).join('\n')
}
