import type { InferenceEngine } from '../model.ts'

// VRAM and context arithmetic, in GiB. Port of Capacity.swift; held to spec/cases/capacity.json.

export const MARGIN = 0.9
export const MAX_CONCURRENCY = 8
export const MIN_CONTEXT_TOKENS = 4096
export const DEFAULT_KV_BYTES_PER_TOKEN = 83 * 1024
export const LLAMA_COMPUTE_BUFFER_GIB = 1
export const LLAMA_RESERVE_GIB = 1
const STEP = 1024

export const bytesToGiB = (bytes: number): number => bytes / 1_073_741_824

export function kvHeadroomGiB(
  gpuMemoryGiB: number, weightsGiB: number,
  { otherSlotGiB = 0, utilization = 0.94, gpuCount = 1, engine = 'vllm' as InferenceEngine } = {},
): number {
  const cards = Math.max(1, gpuCount)
  if (engine === 'vllm') return gpuMemoryGiB * cards * utilization * (1 - 0.12) - weightsGiB - otherSlotGiB
  return gpuMemoryGiB * cards - LLAMA_COMPUTE_BUFFER_GIB * cards - LLAMA_RESERVE_GIB - weightsGiB - otherSlotGiB
}

export function maxContextTokens(headroomGiB: number, kvBytesPerToken = DEFAULT_KV_BYTES_PER_TOKEN): number {
  if (headroomGiB <= 0 || kvBytesPerToken <= 0) return 0
  const tokens = (headroomGiB * 1_073_741_824) / kvBytesPerToken
  return Math.floor(tokens / 1024) * 1024
}

export interface Plan {
  headroomGib: number
  budgetTokens: number
  contextCeiling: number
  concurrencyCeiling: number
  fits: boolean
  usable: boolean
}

export interface Choice {
  contextTokens: number
  concurrency: number
}

const floorToStep = (tokens: number): number => (tokens <= 0 ? 0 : Math.floor(tokens / STEP) * STEP)

export function plan(
  gpuMemoryGiB: number, weightsGiB: number, nativeContextTokens: number | null, chosen: Choice,
  { kvBytesPerToken = DEFAULT_KV_BYTES_PER_TOKEN, gpuCount = 1, engine = 'vllm' as InferenceEngine } = {},
): Plan {
  const headroom = kvHeadroomGiB(gpuMemoryGiB, weightsGiB, { gpuCount, engine })
  const budget = floorToStep(maxContextTokens(headroom, kvBytesPerToken) * MARGIN)
  const native = nativeContextTokens ?? Number.MAX_SAFE_INTEGER

  const concurrency = Math.min(Math.max(chosen.concurrency, 1), MAX_CONCURRENCY)
  const context = Math.max(chosen.contextTokens, 0)

  const contextCeiling = Math.min(floorToStep(budget / concurrency), native)
  const concurrencyCeiling = context > 0 ? Math.min(Math.max(Math.floor(budget / context), 0), MAX_CONCURRENCY) : MAX_CONCURRENCY

  return {
    headroomGib: headroom,
    budgetTokens: budget,
    contextCeiling,
    concurrencyCeiling,
    fits: context >= MIN_CONTEXT_TOKENS && context <= contextCeiling && concurrency <= concurrencyCeiling,
    usable: Math.min(budget, native) >= MIN_CONTEXT_TOKENS,
  }
}

export function recommend(
  gpuMemoryGiB: number, weightsGiB: number, nativeContextTokens: number | null,
  { kvBytesPerToken = DEFAULT_KV_BYTES_PER_TOKEN, gpuCount = 1 } = {},
): Choice | null {
  const p = plan(gpuMemoryGiB, weightsGiB, nativeContextTokens, { contextTokens: MIN_CONTEXT_TOKENS, concurrency: 1 },
    { kvBytesPerToken, gpuCount })
  if (!p.usable) return null
  return { contextTokens: Math.max(MIN_CONTEXT_TOKENS, p.contextCeiling), concurrency: 1 }
}

/** Which weight precisions and engine images a card can run, by RunPod's card names. */
export const CardSupport = {
  runsEngineImage(gpuId: string, engine: InferenceEngine = 'vllm'): boolean {
    if (engine === 'llamaCpp') return !/\bK(80|40|20)\b/.test(gpuId)
    return !/(V100|P100|P40|\bP4\b|K80|M60|Titan V|Quadro GV100)/i.test(gpuId)
  },
  fp8(gpuId: string): boolean {
    return /(\bada\b|\bl40s?\b|\bl4\b|rtx\s?(40|50)\d\d|rtx\s?pro|\bh100\b|\bh200\b|\bb200\b|\bb300\b|blackwell|hopper)/i.test(gpuId)
  },
  nvfp4(gpuId: string): boolean {
    return /(blackwell|\brtx\s?pro\b|\bb200\b|\bb300\b|rtx\s?50\d\d)/i.test(gpuId)
  },
}
