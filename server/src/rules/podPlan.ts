import { readFileSync } from 'node:fs'
import { engineOf, type GPUChoice, type HostingPolicy, type InferenceEngine, type PodlightModel, type PricedChoice, ANYWHERE } from '../model.ts'
import type { CreatePodRequest, GPUType } from '../runpod/types.ts'
import { pricePerHour } from '../runpod/types.ts'
import { sameChoice } from '../runpod/types.ts'
import { specPath } from '../spec.ts'
import { options } from './gpuSuggestion.ts'
import { clouds, StoragePricing } from './hosting.ts'

// The pod Podlight asks RunPod for: a stock engine image, Podlight's start script (spec/pod/boot.sh)
// as the command, the dead-man switch (spec/pod/watchdog.py) beside the engine, optionally a kept
// disk. Port of PodPlan.swift; held to spec/cases/pod-plan.json.

/** Pinned; v0.28.0 is the version Podlight was measured with. Needs CUDA 13.0 hosts. */
export const VLLM_IMAGE = 'vllm/vllm-openai:v0.28.0'
/** `full` carries the Python the watchdog needs. Needs CUDA 12.8 hosts. */
export const LLAMA_IMAGE = 'ghcr.io/ggml-org/llama.cpp:full-cuda12-b12602'
export const ENGINE_PORT = 8000
export const WATCHDOG_PORT = 8001
/** Extra time past "Läuft bis" before the pod's own deadline fires. */
export const DEADLINE_GRACE_MS = 10 * 60_000

export const imageFor = (engine: InferenceEngine): string => (engine === 'vllm' ? VLLM_IMAGE : LLAMA_IMAGE)
export const minCudaVersion = (engine: InferenceEngine): string => (engine === 'vllm' ? '13.0' : '12.8')

const script = (name: string): string => readFileSync(specPath(`pod/${name}`)).toString('base64')
export const POD_SCRIPTS = { watchdog: script('watchdog.py'), boot: script('boot.sh') }

export interface RequestOptions {
  podKey: string
  huggingFaceToken: string | null
  runUntil: Date | null
  heartbeatMinutes: number
  dataCenterIds?: string[] | null
  /** `podlight-` on the Mac, `podlight-srv-` on the server, so pods are told apart at RunPod. */
  namePrefix?: string
}

/** A stopped pod resumes with the environment it was created with; before a resume it gets this
 * version's start script, watchdog and the new deadline. Null when nothing changes. */
export function freshenedEnv(env: Record<string, string>, runUntil: Date | null): Record<string, string> | null {
  if (env.PODLIGHT_API_KEY === undefined) return null
  const fresh: Record<string, string> = { ...env, PODLIGHT_WATCHDOG_B64: POD_SCRIPTS.watchdog, PODLIGHT_BOOT_B64: POD_SCRIPTS.boot }
  if (runUntil) fresh.PODLIGHT_DEADLINE = String(Math.trunc((runUntil.getTime() + DEADLINE_GRACE_MS) / 1000))
  else delete fresh.PODLIGHT_DEADLINE
  const same = Object.keys(fresh).length === Object.keys(env).length && Object.entries(fresh).every(([k, v]) => env[k] === v)
  return same ? null : fresh
}

export function request(model: PodlightModel, o: RequestOptions): CreatePodRequest {
  const engine = engineOf(model.format)
  const cards = model.preferredGPU?.count ?? 1
  const env: Record<string, string> = {
    PODLIGHT_MODEL: model.repoId,
    PODLIGHT_SERVED_NAME: model.name,
    PODLIGHT_API_KEY: o.podKey,
    PODLIGHT_MAX_LEN: String(model.contextTokens),
    PODLIGHT_MAX_SEQS: String(Math.max(4, model.concurrency * 2)),
    PODLIGHT_HEARTBEAT_MINUTES: String(o.heartbeatMinutes),
    PODLIGHT_WATCHDOG_B64: POD_SCRIPTS.watchdog,
    PODLIGHT_BOOT_B64: POD_SCRIPTS.boot,
    PODLIGHT_TP: String(cards),
    PODLIGHT_ENGINE: engine === 'vllm' ? 'vllm' : 'llamacpp',
    HF_XET_HIGH_PERFORMANCE: '1',
  }
  if (model.keepDisk) {
    env.HF_HOME = '/workspace/hf'
    env.LLAMA_CACHE = '/workspace/llama-cache'
  }
  if (engine === 'llamaCpp') {
    env.PODLIGHT_QUANT = model.quant ?? 'Q4_K_M'
    env.PODLIGHT_PARALLEL = String(Math.max(1, model.concurrency))
  }
  if (model.toolCallParser) env.PODLIGHT_TOOL_PARSER = model.toolCallParser
  if (model.reasoningParser) env.PODLIGHT_REASONING_PARSER = model.reasoningParser
  if (o.huggingFaceToken) env.HF_TOKEN = o.huggingFaceToken
  if (o.runUntil) env.PODLIGHT_DEADLINE = String(Math.trunc((o.runUntil.getTime() + DEADLINE_GRACE_MS) / 1000))

  const body: CreatePodRequest = {
    name: `${o.namePrefix ?? 'podlight-'}${model.name}`.slice(0, 60),
    image: imageFor(engine),
    cloud: model.preferredGPU?.cloud ?? 'SECURE',
    gpu: { id: model.preferredGPU?.gpuId ?? 'placeholder', count: cards, minCudaVersion: minCudaVersion(engine) },
    disk: containerGB(model),
    ports: [`${ENGINE_PORT}/http`, `${WATCHDOG_PORT}/http`],
    env,
    entrypoint: ['/bin/bash', '-c'],
    cmd: ['echo "$PODLIGHT_BOOT_B64" | base64 -d > /tmp/podlight-boot.sh && exec bash /tmp/podlight-boot.sh'],
  }
  if (model.keepDisk) body.mounts = { persistent: { size: Math.max(10, persistentGB(model)), path: '/workspace' } }
  if (o.dataCenterIds) body.dataCenterIds = o.dataCenterIds
  return body
}

/** Room for the weights plus tokenizer, compile caches and a margin. */
export const persistentGB = (model: PodlightModel): number => Math.ceil((model.weightBytes / 1_000_000_000) * 1.15) + 10

/** Without a kept disk the download lands on the container disk, which must hold it. */
export const containerGB = (model: PodlightModel): number =>
  model.keepDisk ? 30 : Math.ceil((model.weightBytes / 1_000_000_000) * 1.15) + 20

export const storagePerHour = (model: PodlightModel): number =>
  StoragePricing.runningPerHour(containerGB(model), model.keepDisk ? persistentGB(model) : 0)

export const proxyURL = (podId: string, port: number): string => `https://${podId}-${port}.proxy.runpod.net`

/** The fallback order for a start: the user's card first, then the suggestion for the goal. */
export function choices(model: PodlightModel, catalog: GPUType[], hosting: HostingPolicy = ANYWHERE, limit = 6): GPUChoice[] {
  const ordered = options(model, catalog, model.goal, { context: model.contextTokens, concurrency: model.concurrency, hosting })
    .map((o) => o.choice)
  const preferred = model.preferredGPU
  if (preferred && clouds(hosting).includes(preferred.cloud)) {
    const rest = ordered.filter((c) => !sameChoice(c, preferred))
    return [preferred, ...rest].slice(0, limit)
  }
  return ordered.slice(0, limit)
}

/** The cards a start may book without asking, and the pricier ones it may only offer. */
export interface PriceGuard {
  /** The first choice with its price; null when the catalog has no price for it. */
  wanted: PricedChoice | null
  /** The most a card may cost per hour; null when there is no reference price. */
  ceiling: number | null
  /** Cards to try, in the original order. */
  within: GPUChoice[]
  /** Cards above the ceiling, cheapest first. */
  above: PricedChoice[]
}

const round3 = (value: number): number => Math.round(value * 1000) / 1000

/**
 * The cards of a start split by price. The first choice sets the reference; a fallback may cost up
 * to `stepPercent` more, or up to `maxPricePerHour` when the user approved a pricier card. Prices
 * are per hour for the whole pod. A card without a price counts as too expensive; without a
 * reference price and no maximum, nothing is held back. Port of PodPlan.priceGuard.
 */
export function priceGuard(choices: GPUChoice[], catalog: GPUType[], stepPercent: number, maxPricePerHour: number | null = null): PriceGuard {
  const cards = new Map(catalog.map((g) => [g.id, g]))
  const priced = (choice: GPUChoice): PricedChoice | null => {
    const card = cards.get(choice.gpuId)
    const price = card ? pricePerHour(card, choice.cloud) : null
    if (!card || price == null) return null
    return { choice, name: choice.count > 1 ? `${choice.count} × ${card.name}` : card.name, pricePerHour: round3(price * choice.count) }
  }
  const first = choices[0]
  if (!first) return { wanted: null, ceiling: null, within: [], above: [] }
  const wanted = priced(first)
  const ceiling = maxPricePerHour ?? (wanted ? round3(wanted.pricePerHour * (1 + Math.max(0, stepPercent) / 100)) : null)
  if (ceiling == null) return { wanted, ceiling: null, within: choices, above: [] }
  const within: GPUChoice[] = []
  const above: PricedChoice[] = []
  for (const choice of choices) {
    const item = priced(choice)
    if (item && item.pricePerHour <= ceiling + 1e-9) within.push(choice)
    else if (item) above.push(item)
  }
  above.sort((a, b) => a.pricePerHour - b.pricePerHour)
  return { wanted, ceiling, within, above }
}
