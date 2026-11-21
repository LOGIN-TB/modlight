import { readFileSync } from 'node:fs'
import { engineOf, type GPUChoice, type HostingPolicy, type InferenceEngine, type PodlightModel, ANYWHERE } from '../model.ts'
import type { CreatePodRequest, GPUType } from '../runpod/types.ts'
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
