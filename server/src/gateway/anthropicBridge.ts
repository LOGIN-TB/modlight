// Anthropic Messages ⇄ OpenAI Chat Completions, for providers that only speak the second (Venice).
// Pure: JSON in, JSON out, no I/O. Port of Gateway/AnthropicBridge.swift; both are held to
// spec/cases/anthropic-bridge.json.

type Json = Record<string, unknown>

const isObject = (value: unknown): value is Json => typeof value === 'object' && value !== null && !Array.isArray(value)
const objects = (value: unknown): Json[] => (Array.isArray(value) ? value.filter(isObject) : [])
const str = (value: unknown): string | undefined => (typeof value === 'string' ? value : undefined)
const num = (value: unknown): number => (typeof value === 'number' && Number.isFinite(value) ? value : 0)

/** A request the bridge cannot translate; the gateway answers 400 invalid_request_error. */
export class BridgeError extends Error {}

/** JSON text with sorted keys and no spaces, the same bytes Swift's `.sortedKeys` writes. */
export function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`
  if (isObject(value)) {
    return `{${Object.keys(value).sort().filter((k) => value[k] !== undefined)
      .map((k) => `${JSON.stringify(k)}:${canonicalJSON(value[k])}`).join(',')}}`
  }
  return JSON.stringify(value ?? null)
}

/** The text of a string or of the text blocks in a list, joined with a blank line. */
function text(content: unknown): string {
  if (typeof content === 'string') return content
  return objects(content).filter((b) => b.type === 'text').map((b) => str(b.text) ?? '').join('\n\n')
}

function imagePart(block: Json): Json | null {
  const source = isObject(block.source) ? block.source : {}
  let url: string | undefined
  if (source.type === 'base64') url = `data:${str(source.media_type) ?? 'image/png'};base64,${str(source.data) ?? ''}`
  else if (source.type === 'url') url = str(source.url)
  return url === undefined ? null : { type: 'image_url', image_url: { url } }
}

function userMessages(content: unknown): Json[] {
  if (!Array.isArray(content)) return [{ role: 'user', content: typeof content === 'string' ? content : '' }]
  const out: Json[] = []
  let parts: Json[] = []
  let images: Json[] = []   // from tool results; a tool message holds text only
  const flush = () => {
    const all = [...images, ...parts]
    if (all.length > 0) out.push({ role: 'user', content: all })
    images = []
    parts = []
  }
  for (const block of objects(content)) {
    switch (block.type) {
      case 'tool_result': {
        if (parts.length > 0) flush()
        out.push({ role: 'tool', tool_call_id: str(block.tool_use_id) ?? '', content: text(block.content ?? '') })
        for (const inner of objects(block.content)) {
          const part = inner.type === 'image' ? imagePart(inner) : null
          if (part) images.push(part)
        }
        break
      }
      case 'text': parts.push({ type: 'text', text: str(block.text) ?? '' }); break
      case 'image': { const part = imagePart(block); if (part) parts.push(part); break }
      default: break
    }
  }
  flush()
  return out
}

function assistantMessage(content: unknown): Json {
  if (!Array.isArray(content)) return { role: 'assistant', content: typeof content === 'string' ? content : '' }
  const texts: string[] = []
  const calls: Json[] = []
  for (const block of objects(content)) {
    if (block.type === 'text') texts.push(str(block.text) ?? '')
    else if (block.type === 'tool_use') {
      calls.push({ id: str(block.id) ?? '', type: 'function',
        function: { name: str(block.name) ?? '', arguments: canonicalJSON(isObject(block.input) ? block.input : {}) } })
    }
  }
  const joined = texts.join('\n\n')
  if (calls.length === 0) return { role: 'assistant', content: joined }
  return { role: 'assistant', content: joined === '' ? null : joined, tool_calls: calls }
}

function reasoningEffort(body: Json): string | undefined {
  const thinking = isObject(body.thinking) ? body.thinking : undefined
  if (thinking?.type === 'enabled') {
    const budget = num(thinking.budget_tokens)
    return budget < 4096 ? 'low' : budget < 16384 ? 'medium' : 'high'
  }
  if (thinking?.type === 'adaptive') {
    const effort = isObject(body.output_config) ? str(body.output_config.effort) : undefined
    switch (effort) {
      case 'low': case 'medium': case 'high': return effort
      case 'xhigh': case 'max': return 'high'
      default: return 'medium'
    }
  }
  return undefined
}

/** The Chat Completions body for an Anthropic Messages body. `model` passes unchanged. */
export function request(body: Json): Json {
  if (!Array.isArray(body.messages)) throw new BridgeError('"messages" must be a list.')
  const out: Json = {}
  if (body.model !== undefined) out.model = body.model

  const messages: Json[] = []
  const system = text(body.system ?? '')
  if (system !== '') messages.push({ role: 'system', content: system })
  for (const message of objects(body.messages)) {
    switch (message.role) {
      case 'assistant': messages.push(assistantMessage(message.content)); break
      case 'system': messages.push({ role: 'user', content: `<system-reminder>\n${text(message.content)}\n</system-reminder>` }); break
      default: messages.push(...userMessages(message.content))
    }
  }
  out.messages = messages

  if (typeof body.max_tokens === 'number') out.max_completion_tokens = body.max_tokens
  for (const key of ['temperature', 'top_p', 'top_k']) if (typeof body[key] === 'number') out[key] = body[key]
  if (Array.isArray(body.stop_sequences) && body.stop_sequences.length > 0) out.stop = body.stop_sequences

  const tools = objects(body.tools).filter((t) => isObject(t.input_schema)).map((t) => {
    const fn: Json = { name: str(t.name) ?? '' }
    if (typeof t.description === 'string') fn.description = t.description
    fn.parameters = t.input_schema
    return { type: 'function', function: fn }
  })
  if (tools.length > 0) {
    out.tools = tools
    const choice = isObject(body.tool_choice) ? body.tool_choice : undefined
    switch (choice?.type) {
      case 'auto': out.tool_choice = 'auto'; break
      case 'any': out.tool_choice = 'required'; break
      case 'none': out.tool_choice = 'none'; break
      case 'tool': out.tool_choice = { type: 'function', function: { name: str(choice.name) ?? '' } }; break
      default: break
    }
    if (choice?.disable_parallel_tool_use === true) out.parallel_tool_calls = false
  }

  const effort = reasoningEffort(body)
  if (effort) out.reasoning_effort = effort
  if (body.stream === true) {
    out.stream = true
    out.stream_options = { include_usage: true }
  }
  return out
}

function stopReason(finish: unknown, calledTools: boolean): string {
  if (calledTools) return 'tool_use'
  switch (finish) {
    case 'length': return 'max_tokens'
    case 'tool_calls': case 'function_call': return 'tool_use'
    default: return 'end_turn'
  }
}

function usage(value: unknown): Json {
  const u = isObject(value) ? value : {}
  const cached = num(isObject(u.prompt_tokens_details) ? u.prompt_tokens_details.cached_tokens : undefined)
  return { input_tokens: Math.max(0, num(u.prompt_tokens) - cached), output_tokens: num(u.completion_tokens),
    cache_read_input_tokens: cached, cache_creation_input_tokens: 0 }
}

const messageId = (id: unknown): string => `msg_${str(id) || 'modlight'}`

/** The reasoning text of a message or delta: `reasoning_content` (Venice, DeepSeek) or `reasoning` (vLLM). */
const reasoning = (m: Json): string => str(m.reasoning_content) ?? str(m.reasoning) ?? ''

/** The Anthropic message for a (non-streamed) Chat Completions response. */
export function response(body: Json, requestModel: string): Json {
  const choice = objects(body.choices)[0] ?? {}
  const message = isObject(choice.message) ? choice.message : {}
  const content: Json[] = []
  const thinking = reasoning(message)
  if (thinking !== '') content.push({ type: 'thinking', thinking, signature: '' })
  const said = str(message.content) ?? ''
  if (said !== '') content.push({ type: 'text', text: said })
  const calls = objects(message.tool_calls)
  calls.forEach((call, position) => {
    const fn = isObject(call.function) ? call.function : {}
    const raw = str(fn.arguments) ?? ''
    const block: Json = { type: 'tool_use', id: str(call.id) || `call_${position}`, name: str(fn.name) ?? '', input: {} }
    if (raw.trim() !== '') {
      let parsed: unknown
      try { parsed = JSON.parse(raw) } catch { parsed = undefined }
      if (isObject(parsed)) block.input = parsed
      else block.raw_arguments = raw
    }
    content.push(block)
  })
  return { id: messageId(body.id), type: 'message', role: 'assistant', model: requestModel, content,
    stop_reason: stopReason(choice.finish_reason, calls.length > 0), stop_sequence: null, usage: usage(body.usage) }
}

/** Anthropic's error type for an upstream status. */
export function errorType(status: number): string {
  switch (status) {
    case 401: return 'authentication_error'
    case 402: return 'billing_error'
    case 403: return 'permission_error'
    case 404: return 'not_found_error'
    case 413: return 'request_too_large'
    case 429: return 'rate_limit_error'
    case 503: case 529: return 'overloaded_error'
    default: return status >= 400 && status < 500 ? 'invalid_request_error' : 'api_error'
  }
}

function errorMessage(body: unknown): string | undefined {
  if (typeof body === 'string') return body
  if (!isObject(body)) return undefined
  if (isObject(body.error)) return str(body.error.message)
  return str(body.error) ?? str(body.message) ?? str(body.detail)
}

/** An Anthropic error body for an upstream error: the body as decoded JSON, or its text if not JSON. */
export function error(status: number, body: unknown): Json {
  const message = errorMessage(body)?.trim()
  return { type: 'error', error: { type: errorType(status),
    message: message ? message : `The provider answered with status ${status}.` } }
}

/** Rough input tokens for count_tokens, which an OpenAI-style provider does not offer: Unicode
 * scalars of all text the model reads, / 4 rounded up, plus 1600 per image. */
export function estimateTokens(body: Json): number {
  let scalars = 0
  let images = 0
  const count = (s: unknown) => { if (typeof s === 'string') scalars += [...s].length }
  const blocks = (content: unknown): void => {
    if (typeof content === 'string') { count(content); return }
    for (const b of objects(content)) {
      switch (b.type) {
        case 'text': count(b.text); break
        case 'thinking': count(b.thinking); break
        case 'image': images += 1; break
        case 'tool_use': count(b.name); count(canonicalJSON(b.input ?? {})); break
        case 'tool_result': blocks(b.content); break
        default: break
      }
    }
  }
  blocks(body.system)
  for (const m of objects(body.messages)) blocks(m.content)
  for (const t of objects(body.tools)) {
    count(t.name)
    count(t.description)
    if (t.input_schema !== undefined) count(canonicalJSON(t.input_schema))
  }
  return Math.ceil(scalars / 4) + 1600 * images
}

interface ToolCall { id: string; name: string; arguments: string }

/** Turns Chat Completions stream chunks into Anthropic stream events, one chunk at a time. Each event
 * is the SSE data object; its `type` is the SSE event name. Text and thinking stream live, the first
 * tool call too; later tool calls are sent whole at the end, since their deltas may interleave and
 * Anthropic blocks cannot. */
export class StreamTranslator {
  readonly requestModel: string
  private started = false
  private ended = false
  private nextIndex = 0
  private open: { kind: 'text' | 'thinking' | 'tool'; index: number } | null = null
  /** The OpenAI index of the tool call that streams live. */
  private liveCall: number | null = null
  private calls = new Map<number, ToolCall>()   // collected, in order of first appearance
  private lateText = ''
  private finishReason: unknown = null
  private usage: unknown = null

  constructor(requestModel: string) { this.requestModel = requestModel }

  private start(id: unknown): Json[] {
    if (this.started) return []
    this.started = true
    return [{ type: 'message_start', message: { id: messageId(id), type: 'message', role: 'assistant', model: this.requestModel,
      content: [], stop_reason: null, stop_sequence: null, usage: usage(null) } }]
  }

  private close(): Json[] {
    if (!this.open) return []
    const index = this.open.index
    this.open = null
    return [{ type: 'content_block_stop', index }]
  }

  private ensure(kind: 'text' | 'thinking', events: Json[]): number {
    if (this.open?.kind === kind) return this.open.index
    events.push(...this.close())
    const index = this.nextIndex++
    this.open = { kind, index }
    events.push({ type: 'content_block_start', index, content_block: kind === 'text' ? { type: 'text', text: '' } : { type: 'thinking', thinking: '', signature: '' } })
    return index
  }

  /** The events for one decoded chunk (the JSON after `data:`). */
  feed(chunk: Json): Json[] {
    if (this.ended) return []
    const events = this.start(chunk.id)
    if (chunk.error !== undefined) {
      this.ended = true
      events.push({ type: 'error', error: { type: 'api_error', message: errorMessage({ error: chunk.error })?.trim() || 'The provider stopped the stream.' } })
      return events
    }
    if (chunk.usage != null) this.usage = chunk.usage
    const choice = objects(chunk.choices)[0]
    if (!choice) return events
    const d = isObject(choice.delta) ? choice.delta : {}
    const toolsBegan = this.calls.size > 0

    const thought = reasoning(d)
    if (thought !== '' && !toolsBegan) {
      const index = this.ensure('thinking', events)
      events.push({ type: 'content_block_delta', index, delta: { type: 'thinking_delta', thinking: thought } })
    }
    const said = str(d.content) ?? ''
    if (said !== '') {
      if (toolsBegan) this.lateText += said
      else {
        const index = this.ensure('text', events)
        events.push({ type: 'content_block_delta', index, delta: { type: 'text_delta', text: said } })
      }
    }
    for (const tc of objects(d.tool_calls)) {
      const key = typeof tc.index === 'number' ? tc.index : 0
      const fn = isObject(tc.function) ? tc.function : {}
      const piece = str(fn.arguments) ?? ''
      let call = this.calls.get(key)
      if (!call) {
        call = { id: str(tc.id) || `call_${this.calls.size}`, name: str(fn.name) ?? '', arguments: '' }
        this.calls.set(key, call)
        if (this.liveCall === null) {
          this.liveCall = key
          events.push(...this.close())
          const index = this.nextIndex++
          this.open = { kind: 'tool', index }
          events.push({ type: 'content_block_start', index, content_block: { type: 'tool_use', id: call.id, name: call.name, input: {} } })
        }
      }
      call.arguments += piece
      if (key === this.liveCall && piece !== '' && this.open?.kind === 'tool') {
        events.push({ type: 'content_block_delta', index: this.open.index, delta: { type: 'input_json_delta', partial_json: piece } })
      }
    }
    if (choice.finish_reason != null) this.finishReason = choice.finish_reason
    return events
  }

  /** The closing events, once the upstream stream ended (`[DONE]` or end of body). */
  finish(): Json[] {
    if (this.ended) return []
    const events = this.start(undefined)
    this.ended = true
    events.push(...this.close())
    for (const [key, call] of this.calls) {
      if (key === this.liveCall) continue
      const index = this.nextIndex++
      events.push({ type: 'content_block_start', index, content_block: { type: 'tool_use', id: call.id, name: call.name, input: {} } })
      if (call.arguments !== '') events.push({ type: 'content_block_delta', index, delta: { type: 'input_json_delta', partial_json: call.arguments } })
      events.push({ type: 'content_block_stop', index })
    }
    if (this.lateText !== '') {
      const index = this.nextIndex++
      events.push({ type: 'content_block_start', index, content_block: { type: 'text', text: '' } },
        { type: 'content_block_delta', index, delta: { type: 'text_delta', text: this.lateText } },
        { type: 'content_block_stop', index })
    }
    events.push({ type: 'message_delta', delta: { stop_reason: stopReason(this.finishReason, this.calls.size > 0), stop_sequence: null },
      usage: usage(this.usage) }, { type: 'message_stop' })
    return events
  }
}
