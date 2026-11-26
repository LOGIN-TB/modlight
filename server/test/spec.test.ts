import { strict as assert } from 'node:assert'
import { readFileSync } from 'node:fs'
import { describe, test } from 'node:test'
import { podlightModel, type HostingPolicy, type Schedule } from '../src/model.ts'
import * as capacity from '../src/rules/capacity.ts'
import { options } from '../src/rules/gpuSuggestion.ts'
import * as hosting from '../src/rules/hosting.ts'
import * as podPlan from '../src/rules/podPlan.ts'
import * as scheduler from '../src/rules/scheduler.ts'
import { failure, anthropicType, looksDegenerate, summarizeEngineLog, systemMessagesAsReminders, type GatewayError } from '../src/gateway/shape.ts'
import { MODEL_NAME } from '../src/model.ts'
import { specPath } from '../src/spec.ts'
import * as bridge from '../src/gateway/anthropicBridge.ts'
import type { GPUType } from '../src/runpod/types.ts'
import { costOf, providerFailure, rewriteForProvider, supportsPath, usageFrom } from '../src/providers/api.ts'
import * as venice from '../src/providers/venice.ts'
import * as telemetry from '../src/providers/telemetry.ts'

// Every case in spec/cases that applies to the server. The spec is the source of truth: when a
// case fails, fix the code, never the expected value.

interface SpecCase { id: string; title: string; function: string; input: any; expected: any; status?: string }

/** Planning functions that run only in the app (Hugging Face and GGUF analysis). */
const APP_ONLY = new Set(['kvProfile', 'ggufQuants', 'ggufKvProfile'])

const FILES = ['scheduler.json', 'scheduler-podlight.json', 'capacity.json', 'gpu-suggest.json', 'pod-plan.json',
  'hosting.json', 'gateway.json', 'kv-profile.json', 'gguf.json', 'price-guard.json', 'api-provider.json',
  'anthropic-bridge.json', 'api-telemetry.json']

const catalogs = new Map<string, GPUType[]>()
function catalog(path: string): GPUType[] {
  if (!catalogs.has(path)) catalogs.set(path, JSON.parse(readFileSync(specPath(path), 'utf8')).gpus)
  return catalogs.get(path)!
}

const date = (v: string | null | undefined): Date | null => (v ? new Date(v) : null)

function podState(p: any): scheduler.PodState {
  return {
    status: p.status ?? null, startedAt: date(p.startedAt), lastRequestAt: date(p.lastRequestAt),
    engineReady: p.engineReady, inFlightRequests: p.inFlightRequests, startedManually: p.startedManually,
    idleStoppedAt: date(p.idleStoppedAt), paused: p.paused,
  }
}

const schedule = (s: any): Schedule => s as Schedule

/** Deep equality of JSON values; numbers within a relative 1e-9; dates compared as instants. */
function same(a: unknown, b: unknown): boolean {
  if (a === null || b === null || a === undefined || b === undefined) return (a ?? null) === (b ?? null)
  if (typeof a === 'number' && typeof b === 'number') return a === b || Math.abs(a - b) <= 1e-9 * Math.max(Math.abs(a), Math.abs(b))
  if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((x, i) => same(x, b[i]))
  if (typeof a === 'object' && typeof b === 'object') {
    const x = a as Record<string, unknown>
    const y = b as Record<string, unknown>
    const keys = new Set([...Object.keys(x), ...Object.keys(y)])
    return [...keys].every((k) => same(x[k], y[k]))
  }
  return a === b
}

const toIso = (d: Date | null): string | null => (d ? d.toISOString() : null)

function run(c: SpecCase): unknown {
  const i = c.input
  switch (c.function) {
    case 'decide':
      return scheduler.decide(schedule(i.schedule), podState(i.pod), i.spend, i.session ? { runUntil: date(i.session.runUntil) } : null, new Date(i.now))
    case 'isInsideWindow': return scheduler.isInsideWindow(schedule(i.schedule), new Date(i.now))
    case 'minutesUntilStop': return scheduler.minutesUntilStop(schedule(i.schedule), new Date(i.now))
    case 'windowOpenedAt': return { __date: toIso(scheduler.windowOpenedAt(schedule(i.schedule), new Date(i.now))) }
    case 'localParts': return scheduler.localParts(new Date(i.instant), i.timeZone)
    case 'admitWake': return scheduler.admitWake(i.spend)
    case 'estimateKvHeadroomGib': return capacity.kvHeadroomGiB(i.gpuMemoryGib, i.weightsGib)
    case 'maxContextTokens': return capacity.maxContextTokens(i.headroomGib)
    case 'recommendCapacity': return capacity.recommend(i.gpuMemoryGib, i.weightsGib, i.nativeContextTokens ?? null)
    case 'planCapacity':
      return capacity.plan(i.gpuMemoryGib, i.weightsGib, i.nativeContextTokens ?? null, { contextTokens: i.contextTokens ?? 0, concurrency: i.concurrency ?? 1 })
    case 'gpuSupports': return { fp8: capacity.CardSupport.fp8(i.gpuId), nvfp4: capacity.CardSupport.nvfp4(i.gpuId) }
    case 'gpuOptions': {
      const model = podlightModel.parse(i.model)
      return options(model, catalog(i.catalog), i.goal, { context: i.context, concurrency: i.concurrency, hosting: i.hosting as HostingPolicy })
        .map((o) => ({ choice: o.choice, pricePerHour: o.pricePerHour, estimatedTokensPerSecond: o.estimatedTokensPerSecond,
          contextTokens: o.contextTokens, contextCeiling: o.contextCeiling, dataCenters: o.dataCenters }))
    }
    case 'podChoices': return podPlan.choices(podlightModel.parse(i.model), catalog(i.catalog), i.hosting)
    case 'priceGuard': return podPlan.priceGuard(i.choices, catalog(i.catalog), i.stepPercent, i.maxPricePerHour ?? null)
    case 'podRequest': {
      const model = podlightModel.parse(i.model)
      const request = podPlan.request(model, { podKey: i.podKey, huggingFaceToken: i.huggingFaceToken, runUntil: date(i.runUntil),
        heartbeatMinutes: i.heartbeatMinutes, dataCenterIds: i.dataCenterIds, namePrefix: 'podlight-' })
      request.env.PODLIGHT_WATCHDOG_B64 = '<base64 of spec/pod/watchdog.py>'
      request.env.PODLIGHT_BOOT_B64 = '<base64 of spec/pod/boot.sh>'
      return { request, persistentGB: podPlan.persistentGB(model), containerGB: podPlan.containerGB(model), storagePerHour: podPlan.storagePerHour(model) }
    }
    case 'hostingClouds': return hosting.clouds(i.hosting)
    case 'needsPlacementCheck': return hosting.needsPlacementCheck(i.hosting)
    case 'hostingAllows': return hosting.allows(i.hosting, i.dataCenterId)
    case 'mayHaveCapacity': return hosting.mayHaveCapacity(i.hosting, catalog(i.catalog).find((g) => g.id === i.gpuId)!)
    case 'dataCenterIds': return hosting.dataCenterIds(i.hosting, catalog(i.catalog))
    case 'storagePricing':
      return { runningPerHour: hosting.StoragePricing.runningPerHour(i.containerGB, i.volumeGB), stoppedPerMonth: hosting.StoragePricing.stoppedPerMonth(i.volumeGB) }
    case 'systemMessagesAsReminders': return systemMessagesAsReminders(i.body)
    case 'gatewayError': {
      const f = failure(i.error as GatewayError, i.model)
      return i.anthropic ? { status: f.status, type: anthropicType(f.status) } : { status: f.status, code: f.code }
    }
    case 'isValidName': return MODEL_NAME.test(i.name)
    case 'summarizeEngineLog': return summarizeEngineLog(i.lines)
    case 'looksDegenerate': return looksDegenerate(i.text)
    case 'veniceOffers': return venice.offers(JSON.parse(readFileSync(specPath(i.catalog), 'utf8')))
    case 'veniceOffer': return venice.offer(i.entry)
    case 'apiCost': return costOf(i.usage, i.pricing)
    case 'apiUsage': return usageFrom(i.body)
    case 'apiForward': return rewriteForProvider(i.body, i.path, i.provider, i.providerModelId)
    case 'apiPathSupported': return supportsPath(i.path, i.provider)
    case 'providerFailure': {
      const f = failure({ kind: 'provider', failure: providerFailure(i.provider, i.status, i.body) }, 'm')
      return i.anthropic ? { status: f.status, type: anthropicType(f.status) } : { status: f.status, code: f.code }
    }
    case 'veniceAccount': return venice.account(i.body)
    case 'apiTelemetrySummary': return telemetry.summary(i.samples, new Date(i.now), i.balanceUsd ?? null)
    case 'apiRateLimitHeaders': return telemetry.rateLimitFromHeaders(i.headers, new Date(i.at))
    case 'apiChunkHasContent': return telemetry.hasContent(i.chunk)
    case 'apiCacheKey': return telemetry.cacheKey(i.body, i.providerModelId)
    case 'anthropicRequest':
      try { return bridge.request(i.body) } catch (e) { if (e instanceof bridge.BridgeError) return { thrown: e.message }; throw e }
    case 'anthropicResponse': return bridge.response(i.body, i.requestModel)
    case 'anthropicStream': {
      const t = new bridge.StreamTranslator(i.requestModel)
      return [...(i.chunks as Record<string, unknown>[]).flatMap((c) => t.feed(c)), ...t.finish()]
    }
    case 'anthropicError': return bridge.error(i.status, i.body)
    case 'anthropicTokenEstimate': return bridge.estimateTokens(i.body)
    default: throw new Error(`no server implementation for ${c.function}`)
  }
}

for (const file of FILES) {
  const doc = JSON.parse(readFileSync(specPath(`cases/${file}`), 'utf8')) as { cases: SpecCase[] }
  describe(`spec/cases/${file}`, () => {
    for (const c of doc.cases) {
      if (APP_ONLY.has(c.function)) continue
      test(`${c.id}: ${c.title}`, () => {
        let got = run(c)
        let expected = c.expected
        if (c.function === 'windowOpenedAt') {
          got = (got as { __date: string | null }).__date
          expected = expected == null ? null : new Date(expected).toISOString()
        }
        assert.ok(same(got, expected), `got ${JSON.stringify(got)}\nexpected ${JSON.stringify(expected)}`)
      })
    }
  })
}
