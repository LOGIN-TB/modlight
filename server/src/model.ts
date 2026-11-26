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

/** Where a model runs. `runpod`: a pod Podlight starts. Others: an API provider billing per token. */
export const modelProvider = z.enum(['runpod', 'venice'])
export type ModelProvider = z.infer<typeof modelProvider>

export const apiPrivacy = z.enum(['private', 'anonymized'])
export type APIPrivacy = z.infer<typeof apiPrivacy>

/** USD per million tokens. Without a cache rate, cached tokens cost the input price. */
export const apiRates = z.object({
  input: z.number().nonnegative(),
  output: z.number().nonnegative(),
  cacheRead: optional(z.number().nonnegative()),
  cacheWrite: optional(z.number().nonnegative()),
})
export type APIRates = z.infer<typeof apiRates>

export const apiPricing = apiRates.extend({
  /** Prompts with more tokens than this are billed at `extended`. */
  extendedAboveTokens: optional(z.number().int().positive()),
  extended: optional(apiRates),
})
export type APIPricing = z.infer<typeof apiPricing>

export const apiModelSpec = z.object({
  /** Sent upstream in `model`. */
  providerModelId: z.string().min(1),
  displayName: z.string(),
  privacy: apiPrivacy,
  /** `tools`, `vision`, `reasoning`, `code`. */
  capabilities: z.array(z.string()),
  maxCompletionTokens: optional(z.number().int().positive()),
  pricing: apiPricing,
  pricedAt: z.string(),
  removesAt: optional(z.string()),
})
export type APIModelSpec = z.infer<typeof apiModelSpec>

export const MODEL_NAME = /^[a-z0-9][a-z0-9._-]{0,62}$/

/** A model as the Mac app sets it up. `name` is what an agent puts in the `model` field. */
export const podlightModel = z.object({
  id: z.guid(),
  name: z.string().regex(MODEL_NAME, 'lowercase letters, digits, ".", "_" and "-", at most 63'),
  repoId: z.string().min(1),
  format: weightFormat,
  /** Bytes as Hugging Face reports them (decimal). 0 for API models. */
  weightBytes: z.number().nonnegative(),
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
  /** Where the model runs: a pod (`runpod`) or an API provider. Missing before 0.11: a pod. */
  provider: modelProvider.default('runpod'),
  /** API models: the provider's id, prices and traits. */
  api: optional(apiModelSpec),
})
export type PodlightModel = z.infer<typeof podlightModel>

/** Podlight starts and stops a pod for this model; false for API models, which are always ready. */
export const isPod = (model: Pick<PodlightModel, 'provider'>): boolean => (model.provider ?? 'runpod') === 'runpod'

export type InferenceEngine = 'vllm' | 'llamaCpp'
export const engineOf = (format: WeightFormat): InferenceEngine => (format === 'gguf' ? 'llamaCpp' : 'vllm')

export const podStatus = z.enum(['RUNNING', 'STARTING', 'PROVISIONING', 'EXITED', 'ERROR', 'TERMINATED'])
export type PodStatus = z.infer<typeof podStatus>

export const runPhase = z.enum(['stopped', 'creating', 'loading', 'ready', 'stopping', 'failed'])
export type RunPhase = z.infer<typeof runPhase>

/** What the server knows about one model's pod. RunPod is the source of truth for the rest. */
/** A card choice with its name and price per hour for the whole pod. */
export const pricedChoice = z.object({ choice: gpuChoice, name: z.string(), pricePerHour: z.number() })
export type PricedChoice = z.infer<typeof pricedChoice>

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
  /** What the chosen card would have cost per hour, when the start fell back to another one. */
  wantedPricePerHour: optional(z.number()),
  lastHeartbeatAt: optional(z.string()),
  persistentGB: optional(z.number().int()),
  containerGB: optional(z.number().int()),
  storagePerHour: optional(z.number()),
  dataCenterId: optional(z.string()),
  accountedUntil: optional(z.string()),
  storageAccountedUntil: optional(z.string()),
  hosting: optional(hostingPolicy),
  /** The pod's machine had no free card at the last start; the server keeps trying to resume it. */
  waitingForCard: optional(z.object({
    until: z.string(),
    runUntil: optional(z.string()),
    manual: z.boolean(),
    lastTryAt: optional(z.string()),
    /** Waiting for a new pod: the most a card may cost per hour (whole pod). */
    maxPricePerHour: optional(z.number()),
    /** The chosen card that was taken, with its price. */
    wanted: optional(pricedChoice),
    /** Cards that may be free but cost more than the ceiling, cheapest first. */
    pricier: optional(z.array(pricedChoice)),
  })),
  /** "Start on a New Card": the old pod, kept until the new one answers, put back if it fails. */
  replacing: optional(z.object({
    podId: z.string(),
    gpu: optional(gpuChoice),
    gpuName: optional(z.string()),
    pricePerHour: optional(z.number()),
    persistentGB: optional(z.number().int()),
    containerGB: optional(z.number().int()),
    storagePerHour: optional(z.number()),
    dataCenterId: optional(z.string()),
    hosting: optional(hostingPolicy),
  })),
  /** An old pod to delete once its replacement answered. */
  oldPodToDelete: optional(z.string()),
  /** The current run resumed a kept disk rather than building a new pod. */
  resumed: optional(z.boolean()),
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
  /** Since the engine started: prompt tokens read (reused ones included) and tokens written. */
  promptTokensTotal: optional(z.number()),
  generationTokensTotal: optional(z.number()),
  /** Share of prompt tokens taken from the engine's cache. */
  promptCacheHitPercent: optional(z.number()),
  /** Tokens per second while reading and while writing, over the latest requests. */
  promptSpeed: optional(z.number()),
  generationSpeed: optional(z.number()),
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
  /** A replacement card may cost this many percent more than the chosen one; above that the
   * server books nothing and waits for a cheaper one. 0: no extra cost at all. */
  fallbackPriceStepPercent: z.number().int().min(0).max(1000).default(50),
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
