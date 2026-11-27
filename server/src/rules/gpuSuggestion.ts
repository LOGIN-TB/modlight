import { readFileSync } from 'node:fs'
import { ANYWHERE, engineOf, type GPUChoice, type HostingPolicy, type ModlightModel, type SuggestionGoal } from '../model.ts'
import { type GPUType, mayBeAvailable, mayHaveCuda, maxCards, pricePerHour } from '../runpod/types.ts'
import { specPath } from '../spec.ts'
import { bytesToGiB, CardSupport, DEFAULT_KV_BYTES_PER_TOKEN, plan } from './capacity.ts'
import { allows, clouds, mayHaveCapacity } from './hosting.ts'
import { minCudaVersion } from './podPlan.ts'

// Which cards can run a model, best first for its goal; also the fallback order when a pod is
// created. Port of GPUSuggestion.swift; held to spec/cases/gpu-suggest.json.

export const COMFORTABLE_TOKENS_PER_SECOND = 15
export const CARD_COUNTS = [1, 2, 4, 8]

export interface GPUOption {
  choice: GPUChoice
  displayName: string
  memoryGiB: number
  /** The whole pod, all cards, per hour. */
  pricePerHour: number
  estimatedTokensPerSecond: number | null
  contextTokens: number
  contextCeiling: number
  dataCenters: string[]
}

interface SpeedFile {
  speedModel: { efficiency: number }
  gpus: Record<string, { bandwidthGBs: number; measuredFactor?: number | null }>
}
const speeds = JSON.parse(readFileSync(specPath('data/gpus.json'), 'utf8')) as SpeedFile

export function tokensPerSecond(gpuId: string, weightsGB: number): number | null {
  const entry = speeds.gpus[gpuId]
  if (weightsGB <= 0 || !entry) return null
  return (entry.bandwidthGBs / weightsGB) * speeds.speedModel.efficiency * (entry.measuredFactor ?? 1)
}

const formatRuns = (format: ModlightModel['format'], gpuId: string): boolean =>
  format === 'fp8' ? CardSupport.fp8(gpuId) : format === 'nvfp4' ? CardSupport.nvfp4(gpuId) : true

export function options(
  model: ModlightModel, catalog: GPUType[], goal: SuggestionGoal,
  { context: requested = 65_536, concurrency = 1, hosting = ANYWHERE as HostingPolicy, includeUnavailable = false } = {},
): GPUOption[] {
  const context = Math.min(requested, model.nativeContextTokens ?? requested)
  const kv = model.kvProfile?.bytesPerToken ?? DEFAULT_KV_BYTES_PER_TOKEN
  const engine = engineOf(model.format)
  const weightsGiB = bytesToGiB(model.weightBytes)
  const weightsGB = model.weightBytes / 1_000_000_000
  const result: GPUOption[] = []

  for (const gpu of catalog) {
    if (gpu.manufacturer.toUpperCase() !== 'NVIDIA') continue
    if (!includeUnavailable && gpu.availability != null && !mayBeAvailable(gpu.availability)) continue
    if (!includeUnavailable && !mayHaveCuda(gpu, minCudaVersion(engine))) continue
    if (!includeUnavailable && !mayHaveCapacity(hosting, gpu)) continue
    if (!CardSupport.runsEngineImage(gpu.id, engine) || !formatRuns(model.format, gpu.id)) continue
    const baseSpeed = tokensPerSecond(gpu.id, weightsGB)
    const centers = (gpu.dataCenters ?? []).map((c) => c.id).filter((id) => allows(hosting, id))

    for (const cloud of clouds(hosting)) {
      const price = pricePerHour(gpu, cloud)
      if (price == null) continue
      for (const count of CARD_COUNTS) {
        if (count > maxCards(gpu, cloud)) continue
        // vLLM's tensor parallel splits the attention heads; llama.cpp splits layers.
        const heads = model.kvProfile?.attentionHeads
        if (engine === 'vllm' && heads != null && heads % count !== 0) continue
        const p = plan(gpu.memory, weightsGiB, model.nativeContextTokens ?? null, { contextTokens: context, concurrency },
          { kvBytesPerToken: kv, gpuCount: count, engine })
        if (!p.fits) continue
        // vLLM: each extra card counts at 60 %. llama.cpp: more cards add memory, not speed.
        const speed = engine === 'vllm' && baseSpeed != null ? baseSpeed * (1 + 0.6 * (count - 1)) : baseSpeed
        result.push({
          choice: { gpuId: gpu.id, cloud, count }, displayName: gpu.name, memoryGiB: gpu.memory,
          pricePerHour: price * count, estimatedTokensPerSecond: speed, contextTokens: context,
          contextCeiling: p.contextCeiling, dataCenters: centers,
        })
        break
      }
    }
  }
  return rank(result, goal)
}

/** Lexicographic comparison of number tuples, as Swift compares tuples. */
function byTuple<T>(key: (item: T) => number[]): (a: T, b: T) => number {
  return (a, b) => {
    const x = key(a)
    const y = key(b)
    for (let i = 0; i < x.length; i++) {
      if (x[i]! < y[i]!) return -1
      if (x[i]! > y[i]!) return 1
    }
    return 0
  }
}

export function rank(list: GPUOption[], goal: SuggestionGoal): GPUOption[] {
  const speed = (o: GPUOption): number => o.estimatedTokensPerSecond ?? 0
  switch (goal) {
    case 'economical':
      return [...list].sort(byTuple((o) => [o.pricePerHour, -speed(o)]))
    case 'fast':
      return [...list].sort(byTuple((o) => [-speed(o), o.pricePerHour]))
    case 'balanced': {
      // Comfortable cards first, cheapest speed per dollar among them; then the rest by speed.
      const value = (o: GPUOption): number => speed(o) / Math.max(o.pricePerHour, 0.01)
      const comfortable = list.filter((o) => speed(o) >= COMFORTABLE_TOKENS_PER_SECOND)
        .sort(byTuple((o) => [-value(o), o.pricePerHour]))
      const slow = list.filter((o) => speed(o) < COMFORTABLE_TOKENS_PER_SECOND)
        .sort(byTuple((o) => [-speed(o), o.pricePerHour]))
      return [...comfortable, ...slow]
    }
  }
}
