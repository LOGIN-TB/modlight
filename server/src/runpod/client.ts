import type { GPUChoice } from '../model.ts'
import { type CreatePodRequest, type GPUType, mayBeAvailable, mayHaveCuda, type Pod } from './types.ts'

// RunPod REST v2 at api.runpod.io, the API the pod's watchdog also uses. Port of RunpodClient.swift.

export const RUNPOD_BASE = 'https://api.runpod.io'

export class RunpodError extends Error {
  readonly status: number
  readonly body: string
  constructor(status: number, body: string) {
    super(`RunPod ${status}: ${body.slice(0, 300)}`)
    this.status = status
    this.body = body
  }
  /** RunPod had no machine with that card free. Normal, not exceptional: try the next card. */
  get isCapacityExhausted(): boolean {
    return this.status === 400 && /no longer any instances available/i.test(this.body)
  }
  /** A stopped pod's host gave its card away; build a new pod instead. */
  get isHostGpuUnavailable(): boolean {
    return this.status === 400 && /not enough free GPUs/i.test(this.body)
  }
  get isNotFound(): boolean {
    return this.status === 404
  }
}

export type KeyCheck = 'valid' | 'invalid' | 'missingPermission' | 'unreachable'

export class RunpodClient {
  private readonly apiKey: string
  private readonly fetchImpl: typeof fetch
  private readonly base: string
  constructor(apiKey: string, fetchImpl: typeof fetch = fetch, base = RUNPOD_BASE) {
    this.apiKey = apiKey
    this.fetchImpl = fetchImpl
    this.base = base
  }

  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    const response = await this.fetchImpl(new URL(path, this.base), {
      method,
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        Accept: 'application/json',
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(30_000),
    })
    const text = await response.text().catch(() => '')
    if (!response.ok) throw new RunpodError(response.status, text)
    return (text ? JSON.parse(text) : undefined) as T
  }

  async checkKey(): Promise<KeyCheck> {
    try {
      await this.call('GET', '/v2/pods?limit=1')
      return 'valid'
    } catch (error) {
      if (error instanceof RunpodError) return error.status === 401 ? 'invalid' : error.status === 403 ? 'missingPermission' : 'unreachable'
      return 'unreachable'
    }
  }

  pod(id: string): Promise<Pod> {
    return this.call('GET', `/v2/pods/${encodeURIComponent(id)}`)
  }

  createPod(body: CreatePodRequest): Promise<Pod> {
    return this.call('POST', '/v2/pods', body)
  }

  action(id: string, action: 'start' | 'stop' | 'restart' | 'terminate'): Promise<Pod> {
    return this.call('POST', `/v2/pods/${encodeURIComponent(id)}/action`, { action })
  }

  async deletePod(id: string): Promise<void> {
    await this.call('DELETE', `/v2/pods/${encodeURIComponent(id)}`)
  }

  async gpuCatalog(): Promise<GPUType[]> {
    const result = await this.call<{ gpus: GPUType[] }>('GET', '/v2/catalog/gpus?include=AVAILABILITY&product=POD&count=1')
    return result.gpus
  }
}

export interface CreationAttempt {
  choice: GPUChoice
  outcome: 'created' | 'noCapacity' | 'skippedUnavailable'
}

export class NoCapacityError extends Error {
  readonly attempts: CreationAttempt[]
  constructor(attempts: CreationAttempt[]) {
    super('no capacity')
    this.attempts = attempts
  }
}

/**
 * Creates a pod on the first card RunPod can actually provide. Capacity is the normal failure;
 * any other error stops at once, because the next card would fail the same way.
 */
export async function createWithFallback(client: RunpodClient, base: CreatePodRequest, choices: GPUChoice[], catalog: GPUType[] = [])
  : Promise<{ pod: Pod; choice: GPUChoice; attempts: CreationAttempt[] }> {
  const cards = new Map(catalog.map((g) => [g.id, g]))
  const attempts: CreationAttempt[] = []
  for (const choice of choices) {
    const card = cards.get(choice.gpuId)
    const noneFree = card?.availability != null && !mayBeAvailable(card.availability)
    const noSuitableHost = card != null && base.gpu.minCudaVersion != null && !mayHaveCuda(card, base.gpu.minCudaVersion)
    if (noneFree || noSuitableHost) {
      attempts.push({ choice, outcome: 'skippedUnavailable' })
      continue
    }
    const request: CreatePodRequest = {
      ...base,
      cloud: choice.cloud,
      gpu: { ...base.gpu, id: choice.gpuId, count: choice.count },
      // The engine must split across exactly the cards this attempt gets (seen live 2026-11-21).
      env: base.env.PODLIGHT_TP !== undefined ? { ...base.env, PODLIGHT_TP: String(choice.count) } : base.env,
    }
    try {
      const pod = await client.createPod(request)
      attempts.push({ choice, outcome: 'created' })
      return { pod, choice, attempts }
    } catch (error) {
      if (error instanceof RunpodError && error.isCapacityExhausted) {
        attempts.push({ choice, outcome: 'noCapacity' })
        continue
      }
      throw error
    }
  }
  throw new NoCapacityError(attempts)
}
