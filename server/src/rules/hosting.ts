import { readFileSync } from 'node:fs'
import type { HostingPolicy, RunpodCloud } from '../model.ts'
import { type GPUType, mayBeAvailable } from '../runpod/types.ts'
import { specPath } from '../spec.ts'

// Where pods may run, and what disks cost. Values from spec/data/regions.json; held to
// spec/cases/hosting.json. Port of Hosting.swift.

interface RegionsFile {
  regions: Record<'eu' | 'euEEA', { prefixes: string[] }>
  storagePricing: {
    containerDiskRunningUsdPerGBMonth: number
    volumeDiskRunningUsdPerGBMonth: number
    volumeDiskStoppedUsdPerGBMonth: number
    hoursPerMonth: number
  }
}

const regions = JSON.parse(readFileSync(specPath('data/regions.json'), 'utf8')) as RegionsFile

export function prefixes(policy: HostingPolicy): string[] | null {
  return policy.region === 'anywhere' ? null : regions.regions[policy.region].prefixes
}

/** With a region only Secure Cloud is used: community pods report no data center. */
export function clouds(policy: HostingPolicy): RunpodCloud[] {
  return policy.secureOnly || prefixes(policy) ? ['SECURE'] : ['SECURE', 'COMMUNITY']
}

export const needsPlacementCheck = (policy: HostingPolicy): boolean => prefixes(policy) !== null

export function allows(policy: HostingPolicy, dataCenterId: string | null | undefined): boolean {
  const p = prefixes(policy)
  if (!p) return true
  if (!dataCenterId) return false
  return p.some((prefix) => dataCenterId.startsWith(prefix))
}

/** Whether a card may be free somewhere the policy allows. Without per-center figures, kept. */
export function mayHaveCapacity(policy: HostingPolicy, gpu: GPUType): boolean {
  const centers = gpu.dataCenters
  if (!prefixes(policy) || !centers || centers.length === 0) return true
  return centers.some((c) => allows(policy, c.id) && (c.availability == null || mayBeAvailable(c.availability)))
}

/** The data centers to request. Null means "let RunPod choose". */
export function dataCenterIds(policy: HostingPolicy, catalog: GPUType[]): string[] | null {
  if (!prefixes(policy)) return null
  const ids = new Set(catalog.flatMap((g) => g.dataCenters ?? []).map((c) => c.id).filter((id) => allows(policy, id)))
  return [...ids].sort()
}

const prices = regions.storagePricing
export const StoragePricing = {
  hoursPerMonth: prices.hoursPerMonth,
  runningPerHour(containerGB: number, volumeGB: number): number {
    return (containerGB * prices.containerDiskRunningUsdPerGBMonth + volumeGB * prices.volumeDiskRunningUsdPerGBMonth) / prices.hoursPerMonth
  },
  stoppedPerMonth(volumeGB: number): number {
    return volumeGB * prices.volumeDiskStoppedUsdPerGBMonth
  },
}
