import { z } from 'zod'

// The shapes Podlight shares between the Mac app and the server. They mirror the Swift types in
// apps/mac/PodlightEngine (PodlightModel, ModelRun, HostingPolicy, ...) field for field, so a model
// set up on the Mac is stored here unchanged. `spec/schema/model.json` is emitted from these.
//
// Swift leaves out optional fields that are nil; JSON from it has no key rather than `null`.
// Both are accepted here.

const optional = <T extends z.ZodType>(schema: T) => schema.nullish()

export const weightFormat = z.enum(['safetensors', 'awq', 'gptq', 'fp8', 'nvfp4', 'gguf', 'mlx', 'unknown'])
export type WeightFormat = z.infer<typeof weightFormat>

export const suggestionGoal = z.enum(['economical', 'balanced', 'fast'])
export type SuggestionGoal = z.infer<typeof suggestionGoal>

export const runpodCloud = z.enum(['SECURE', 'COMMUNITY'])
export type RunpodCloud = z.infer<typeof runpodCloud>

export const hostingRegion = z.enum(['anywhere', 'eu', 'euEEA'])
export type HostingRegion = z.infer<typeof hostingRegion>

export const hostingPolicy = z.object({
  region: hostingRegion,
  /** Only RunPod's Secure Cloud (certified data centers). A region implies it. */
  secureOnly: z.boolean(),
})
export type HostingPolicy = z.infer<typeof hostingPolicy>
export const ANYWHERE: HostingPolicy = { region: 'anywhere', secureOnly: false }

export const gpuChoice = z.object({
  gpuId: z.string().min(1),
  cloud: runpodCloud,
  /** Cards in the pod. 1 unless a long context needs more memory. */
  count: z.number().int().min(1).default(1),
})
export type GPUChoice = z.infer<typeof gpuChoice>

export const kvProfile = z.object({
  bytesPerToken: z.number().positive(),
  attentionHeads: optional(z.number().int().positive()),
  hybrid: z.boolean().default(false),
})
export type KVProfile = z.infer<typeof kvProfile>

const hhmm = z.string().regex(/^\d{1,2}:\d{2}$/)

export const schedule = z.object({
  enabled: z.boolean(),
  /** IANA zone, e.g. `Europe/Berlin`. The schedule's own. */
  timezone: z.string().min(1),
  /** 0 = Sunday … 6 = Saturday. */
  weekdays: z.array(z.number().int().min(0).max(6)),
  startAt: optional(hhmm),
  stopAt: optional(hhmm),
  /** Never below 5: idle stop is always on. */
  idleStopMinutes: z.number().int(),
  maxRuntimeHours: z.number().int().min(0),
})
export type Schedule = z.infer<typeof schedule>

export const MODEL_NAME = /^[a-z0-9][a-z0-9._-]{0,62}$/

/** A model as the Mac app sets it up. `name` is what an agent puts in the `model` field. */
export const podlightModel = z.object({
  id: z.guid(),
  name: z.string().regex(MODEL_NAME, 'lowercase letters, digits, ".", "_" and "-", at most 63'),
  repoId: z.string().min(1),
  format: weightFormat,
  /** Bytes as Hugging Face reports them (decimal). */
  weightBytes: z.number().positive(),
  nativeContextTokens: optional(z.number().int().positive()),
  toolCallParser: optional(z.string()),
  reasoningParser: optional(z.string()),
  contextTokens: z.number().int().positive(),
  concurrency: z.number().int().min(1).default(1),
  goal: suggestionGoal.default('balanced'),
  preferredGPU: optional(gpuChoice),
  expectedPricePerHour: optional(z.number()),
  schedule,
  createdAt: optional(z.string()),
  kvProfile: optional(kvProfile),
  /** Keep a volume disk between runs. Off: the pod is deleted at its end. */
  keepDisk: z.boolean(),
  /** Nil: the server's default hosting. */
  hosting: optional(hostingPolicy),
  preferredGPUName: optional(z.string()),
  /** GGUF: the quantisation llama.cpp loads (`-hf repo:quant`). */
  quant: optional(z.string()),
})
export type PodlightModel = z.infer<typeof podlightModel>

export type InferenceEngine = 'vllm' | 'llamaCpp'
export const engineOf = (format: WeightFormat): InferenceEngine => (format === 'gguf' ? 'llamaCpp' : 'vllm')

export const podStatus = z.enum(['RUNNING', 'STARTING', 'PROVISIONING', 'EXITED', 'ERROR', 'TERMINATED'])
export type PodStatus = z.infer<typeof podStatus>

export const runPhase = z.enum(['stopped', 'creating', 'loading', 'ready', 'stopping', 'failed'])
export type RunPhase = z.infer<typeof runPhase>

/** What the server knows about one model's pod. RunPod is the source of truth for the rest. */
export const modelRun = z.object({
  podId: optional(z.string()),
  gpu: optional(gpuChoice),
  gpuName: optional(z.string()),
  pricePerHour: optional(z.number()),
  podStatus: optional(podStatus),
  phase: runPhase.default('stopped'),
  startedAt: optional(z.string()),
  lastRequestAt: optional(z.string()),
  idleStoppedAt: optional(z.string()),
  stoppedAt: optional(z.string()),
  engineReady: z.boolean().default(false),
  startedManually: z.boolean().default(false),
  /** "Läuft bis". Nil for a pod a request woke. */
  runUntil: optional(z.string()),
  lastReason: optional(z.string()),
  lastMessage: optional(z.string()),
  fellBackFrom: optional(z.array(z.string())),
  lastHeartbeatAt: optional(z.string()),
  persistentGB: optional(z.number().int()),
  containerGB: optional(z.number().int()),
  storagePerHour: optional(z.number()),
  dataCenterId: optional(z.string()),
  accountedUntil: optional(z.string()),
  storageAccountedUntil: optional(z.string()),
  hosting: optional(hostingPolicy),
})
export type ModelRun = z.infer<typeof modelRun>
export const emptyRun = (): ModelRun => modelRun.parse({})

/** One GPU in a pod, as the pod's watchdog reads it from nvidia-smi. Unknown values are null. */
export const gpuTelemetry = z.object({
  index: optional(z.number()),
  name: optional(z.string()),
  utilPercent: optional(z.number()),
  memoryUsedBytes: optional(z.number()),
  memoryTotalBytes: optional(z.number()),
  temperatureC: optional(z.number()),
  powerW: optional(z.number()),
  powerLimitW: optional(z.number()),
})

/** What the engine is doing, from its /metrics. Rates cover the seconds since the last sample. */
export const engineTelemetry = z.object({
  running: optional(z.number()),
  waiting: optional(z.number()),
  kvCachePercent: optional(z.number()),
  promptTokensPerSecond: optional(z.number()),
  generationTokensPerSecond: optional(z.number()),
})

/**
 * One sample of what a pod is doing, measured by its watchdog (spec/pod/watchdog.py) and sent back
 * with each heartbeat. RunPod's API reports no GPU memory in use and no disk, so the pod measures
 * itself. `time` is Unix seconds. A missing source leaves out its fields.
 */
export const podTelemetry = z.object({
  time: z.number(),
  cpuPercent: optional(z.number()),
  memoryUsedBytes: optional(z.number()),
  memoryTotalBytes: optional(z.number()),
  diskUsedBytes: optional(z.number()),
  diskTotalBytes: optional(z.number()),
  volumeUsedBytes: optional(z.number()),
  volumeTotalBytes: optional(z.number()),
  gpus: optional(z.array(gpuTelemetry)),
  engine: optional(engineTelemetry),
})
export type PodTelemetry = z.infer<typeof podTelemetry>

/** Server settings an app may read and change. Secrets are separate and write-only. */
export const serverSettings = z.object({
  dailyLimitUsd: z.number().positive().nullable().default(10),
  monthlyLimitUsd: z.number().positive().nullable().default(100),
  /** Minutes without a heartbeat after which a pod stops itself (server down). */
  heartbeatMinutes: z.number().int().min(5).max(60).default(15),
  /** How long the gateway holds a request while a stopped pod starts. */
  wakeWaitSeconds: z.number().int().min(30).max(900).default(600),
  deleteStoppedAfterDays: z.number().int().min(1).max(30).default(3),
  wakeOnRequest: z.boolean().default(true),
  hostingRegion: hostingRegion.default('anywhere'),
  secureCloudOnly: z.boolean().default(false),
  /** Days for the spend ledger and limits are counted in this zone. */
  timezone: z.string().default('UTC'),
})
export type ServerSettings = z.infer<typeof serverSettings>

export const settingsPatch = serverSettings.partial().extend({
  /** Write-only. Empty string removes it. */
  runpodApiKey: z.string().optional(),
  huggingFaceToken: z.string().optional(),
})
export type SettingsPatch = z.infer<typeof settingsPatch>

export const hostingOf = (s: ServerSettings): HostingPolicy => ({ region: s.hostingRegion, secureOnly: s.secureCloudOnly })

/** ISO 8601 without fractional seconds, which Swift's `.iso8601` strategy cannot read. */
export const iso = (date: Date): string => date.toISOString().replace(/\.\d{3}Z$/, 'Z')
export const parseDate = (value: string | null | undefined): Date | null => (value ? new Date(value) : null)
