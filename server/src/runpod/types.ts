import type { GPUChoice, PodStatus, RunpodCloud } from '../model.ts'

// Shapes of RunPod's REST API v2 (https://api.runpod.io/v2) as far as Podlight uses them; the same
// subset as RunpodModels.swift. Unknown fields are ignored.

/** RunPod reports `LOW` or `NONE` in practice. Neither is a promise. */
export type Availability = string

export interface DataCenterAvailability {
  id: string
  name?: string | null
  availability?: Availability | null
}

export interface GPUType {
  id: string
  name: string
  manufacturer: string
  /** VRAM in GB. */
  memory: number
  secure: boolean
  community: boolean
  price: { community?: number | null; secure?: number | null }
  availability?: Availability | null
  cudaVersions?: Array<{ version: string; available: boolean }> | null
  maxCount?: { community?: number | null; secure?: number | null } | null
  dataCenters?: DataCenterAvailability[] | null
}

export interface Pod {
  id: string
  name: string
  status: PodStatus
  actions?: string[] | null
  gpu?: { id: string; count?: number | null } | null
  cloud?: RunpodCloud | null
  /** USD per hour while running. */
  cost?: number | null
  image?: string | null
  dataCenterId?: string | null
  /** The pod's environment; Podlight's pods carry their start script and watchdog here. */
  env?: Record<string, string> | null
  /** Container disk in GB. */
  disk?: number | null
  mounts?: { persistent?: { size?: number | null } | null } | null
}

export interface CreatePodRequest {
  name: string
  image: string
  cloud: RunpodCloud
  gpu: { id: string; count: number; minCudaVersion?: string }
  /** Container disk in GB. */
  disk: number
  ports: string[]
  env: Record<string, string>
  entrypoint?: string[]
  cmd?: string[]
  mounts?: { persistent?: { size: number; path: string } }
  dataCenterIds?: string[]
}

/** Worth trying at all. Says nothing about whether it will still be there. */
export const mayBeAvailable = (availability: Availability | null | undefined): boolean => availability !== 'NONE'

export function maxCards(gpu: GPUType, cloud: RunpodCloud): number {
  const value = cloud === 'SECURE' ? gpu.maxCount?.secure : gpu.maxCount?.community
  return value ?? 1
}

export function compareVersions(a: string, b: string): number {
  const x = a.split('.').map((p) => Number.parseInt(p, 10) || 0)
  const y = b.split('.').map((p) => Number.parseInt(p, 10) || 0)
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const l = x[i] ?? 0
    const r = y[i] ?? 0
    if (l !== r) return l < r ? -1 : 1
  }
  return 0
}

/** Whether a host with at least `minimum` CUDA may be free. True when RunPod does not say. */
export function mayHaveCuda(gpu: GPUType, minimum: string): boolean {
  const versions = gpu.cudaVersions
  if (!versions || versions.length === 0) return true
  return versions.some((v) => v.available && compareVersions(v.version, minimum) >= 0)
}

/** Hourly price in this cloud, or null when not offered there. RunPod reports 0 for "not offered". */
export function pricePerHour(gpu: GPUType, cloud: RunpodCloud): number | null {
  const offered = cloud === 'SECURE' ? gpu.secure : gpu.community
  const value = cloud === 'SECURE' ? gpu.price.secure : gpu.price.community
  if (!offered || value == null || value <= 0) return null
  return value
}

export const sameChoice = (a: GPUChoice, b: GPUChoice): boolean =>
  a.gpuId === b.gpuId && a.cloud === b.cloud && a.count === b.count
