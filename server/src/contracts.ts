import { z } from 'zod'
import { VERSION } from './admin/routes.ts'
import { FORWARDED_PATHS } from './gateway/routes.ts'
import { gpuChoice, hostingPolicy, modelRun, podlightModel, podTelemetry, schedule, serverSettings, settingsPatch } from './model.ts'

// The documents in spec/ that are generated from the server's own schemas, so they cannot drift:
// spec/schema/model.json (the model both sides store) and spec/openapi.json (this server's API).
// `npm run gen` writes them; a test fails when the checked-in copies are stale.

const schema = (s: z.ZodType) => z.toJSONSchema(s, { target: 'draft-2020-12', io: 'input', unrepresentable: 'any' })

export function modelSchema(): object {
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: 'https://github.com/LOGIN-TB/podlight/spec/schema/model.json',
    title: 'PodlightModel',
    description: 'A model as the Podlight app sets it up and the server stores it. Mirrors PodlightModel in apps/mac/PodlightEngine. Generated from server/src/model.ts.',
    ...schema(podlightModel),
  }
}

const ref = (name: string) => ({ $ref: `#/components/schemas/${name}` })
const json = (s: object) => ({ 'application/json': { schema: s } })
const error = { description: 'Error', content: json(ref('Error')) }
const ok = (description: string, s: object = { type: 'object' }) => ({ description, content: json(s) })
const idParam = [{ name: 'id', in: 'path', required: true, schema: { type: 'string', format: 'uuid' } }]
const device = [{ device: [] }]
const client = [{ client: [] }, { clientApiKey: [] }]

export function openapi(): object {
  const forwarded = Object.fromEntries(FORWARDED_PATHS.map((path) => [path, {
    post: {
      tags: ['gateway'], security: client,
      summary: path.startsWith('/v1/messages') ? 'Anthropic Messages API, passed to the engine' : path.startsWith('/v1/responses') ? 'OpenAI Responses API, passed to the engine' : 'OpenAI API, passed to the engine',
      description: 'The `model` field picks the model. A stopped model is woken (spend limits are checked first) and the request held until it answers. Request and response are passed through unchanged, streaming included; on /v1/messages, `role: "system"` entries inside `messages` become user text in `<system-reminder>`.',
      requestBody: { required: true, content: json({ type: 'object', required: ['model'], properties: { model: { type: 'string' } } }) },
      responses: { 200: { description: 'The engine\'s answer (JSON or text/event-stream)' }, 400: error, 401: error, 403: error, 404: error, 429: error, 502: error, 503: error },
    },
  }]))

  return {
    openapi: '3.1.0',
    info: {
      title: 'Podlight server', version: VERSION,
      description: 'Gateway for agents (/v1, client tokens) and control API for Podlight apps (/admin, device tokens from pairing). Plain HTTP; run it behind a reverse proxy with TLS.',
      license: { name: 'MIT' },
    },
    components: {
      securitySchemes: {
        device: { type: 'http', scheme: 'bearer', description: 'Device token (pld-…) from POST /pair.' },
        client: { type: 'http', scheme: 'bearer', description: 'Client token (pl-…) created in the app.' },
        clientApiKey: { type: 'apiKey', in: 'header', name: 'x-api-key', description: 'Client token, as Claude Code sends ANTHROPIC_API_KEY.' },
      },
      schemas: {
        PodlightModel: schema(podlightModel),
        ModelRun: schema(modelRun),
        Schedule: schema(schedule),
        HostingPolicy: schema(hostingPolicy),
        GPUChoice: schema(gpuChoice),
        PodTelemetry: { ...schema(podTelemetry), description: 'One sample of what a pod is doing, measured by its watchdog. `time` is Unix seconds; a missing source leaves out its fields.' },
        Settings: { allOf: [schema(serverSettings), { type: 'object', properties: { hasRunpodKey: { type: 'boolean' }, hasHuggingFaceToken: { type: 'boolean' }, hasVeniceKey: { type: 'boolean' } } }] },
        SettingsPatch: schema(settingsPatch),
        Spend: { type: 'object', properties: { todayUsd: { type: 'number' }, monthUsd: { type: 'number' }, dailyLimitUsd: { type: ['number', 'null'] }, monthlyLimitUsd: { type: ['number', 'null'] } } },
        State: {
          type: 'object',
          properties: {
            version: { type: 'string' }, serverTime: { type: 'string', format: 'date-time' },
            models: { type: 'array', items: ref('PodlightModel') },
            runs: { type: 'object', additionalProperties: ref('ModelRun'), description: 'Keyed by model id.' },
            settings: ref('Settings'), spendByDay: { type: 'object', additionalProperties: { type: 'number' } },
            spend: ref('Spend'), costPerHour: { type: 'number' }, lastClientRequestAt: { type: ['string', 'null'] },
            telemetry: { type: 'object', additionalProperties: ref('PodTelemetry'), description: 'The latest sample per model whose pod runs, keyed by model id.' },
            balance: { oneOf: [ref('Balance'), { type: 'null' }], description: 'The RunPod account, at most about a minute old; null until first read or without a key.' },
            apiUsage: { type: 'object', description: 'Tokens and cost of API models: day (yyyy-MM-dd) → model id → totals.',
              additionalProperties: { type: 'object', additionalProperties: ref('APIUsageTotals') } },
            veniceAccount: { oneOf: [ref('APIAccount'), { type: 'null' }], description: 'The Venice account, at most about a minute old; null until first read or without a key.' },
          },
        },
        APIUsageTotals: {
          type: 'object',
          properties: { requests: { type: 'integer' }, promptTokens: { type: 'integer' }, completionTokens: { type: 'integer' }, cachedTokens: { type: 'integer' }, usd: { type: 'number' } },
        },
        APIAccount: {
          type: 'object',
          properties: {
            balances: { type: 'array', items: { type: 'object', properties: { currency: { type: 'string' }, amount: { type: 'number' } } } },
            tier: { type: 'string' }, keyExpiration: { type: 'string', format: 'date-time' }, nextEpochBegins: { type: 'string', format: 'date-time' },
            rateLimits: { type: 'array', items: { type: 'object', properties: { model: { type: 'string' }, type: { type: 'string' }, amount: { type: 'number' } } } },
            checkedAt: { type: 'string', format: 'date-time' },
          },
        },
        Balance: {
          type: 'object',
          properties: {
            usd: { type: 'number', description: 'Credit left in the RunPod account.' },
            spendPerHourUsd: { type: 'number', description: 'What everything in the account costs per hour now, by RunPod.' },
            spendLimitUsd: { type: ['number', 'null'], description: "RunPod's own spend limit for the account." },
            checkedAt: { type: 'string', format: 'date-time' },
          },
        },
        ClientToken: {
          type: 'object',
          properties: {
            id: { type: 'string' }, name: { type: 'string' }, createdAt: { type: 'string' }, lastUsedAt: { type: ['string', 'null'] },
            revokedAt: { type: ['string', 'null'] }, models: { type: ['array', 'null'], items: { type: 'string', format: 'uuid' } },
            token: { type: 'string', description: 'Only in the answer to POST /admin/client-tokens.' },
          },
        },
        Error: { type: 'object', properties: { error: { type: 'object', properties: { message: { type: 'string' }, code: { type: 'string' }, type: { type: 'string' } } } } },
      },
    },
    paths: {
      '/health': { get: { tags: ['server'], summary: 'Liveness, version, whether any app is paired', responses: { 200: ok('Status') } } },
      '/pair': { post: {
        tags: ['server'], summary: 'Exchange the pairing code from the log for a device token',
        requestBody: { required: true, content: json({ type: 'object', required: ['code'], properties: { code: { type: 'string' }, deviceName: { type: 'string' } } }) },
        responses: { 200: ok('Device token', { type: 'object', properties: { token: { type: 'string' }, id: { type: 'string' }, version: { type: 'string' } } }), 403: error },
      } },
      '/v1/models': { get: { tags: ['gateway'], security: client, summary: 'Models this key may use (OpenAI and Anthropic fields)', responses: { 200: ok('List'), 401: error } } },
      ...forwarded,
      '/admin/state': { get: { tags: ['admin'], security: device, summary: 'Everything the app shows: models, runs, settings, spend', responses: { 200: ok('State', ref('State')), 401: error } } },
      '/admin/refresh': { post: { tags: ['admin'], security: device, summary: 'Compare the stored pods with RunPod now and let go of deleted ones', responses: { 200: ok('Done', { type: 'object', properties: { ok: { type: 'boolean' } } }) } } },
      '/admin/settings': {
        get: { tags: ['admin'], security: device, summary: 'Settings (secrets only as has… flags)', responses: { 200: ok('Settings', ref('Settings')) } },
        patch: { tags: ['admin'], security: device, summary: 'Change settings; secrets are write-only, "" removes one', requestBody: { content: json(ref('SettingsPatch')) }, responses: { 200: ok('Settings', ref('Settings')), 400: error } },
      },
      '/admin/settings/verify-runpod': { post: { tags: ['admin'], security: device, summary: 'Check a RunPod key (the given one, or the stored one)', responses: { 200: ok('Result', { type: 'object', properties: { result: { enum: ['valid', 'invalid', 'missingPermission', 'unreachable'] } } }) } } },
      '/admin/settings/verify-venice': { post: { tags: ['admin'], security: device, summary: 'Check a Venice key (the given one, or the stored one); with the account when valid', responses: { 200: ok('Result', { type: 'object', properties: { result: { enum: ['valid', 'invalid', 'unreachable'] }, account: ref('APIAccount') } }) } } },
      '/admin/catalog/venice': { get: { tags: ['admin'], security: device, summary: 'Venice\'s text models with prices, privacy tier and capabilities', responses: { 200: ok('Catalog'), 502: error } } },
      '/admin/catalog/gpus': { get: { tags: ['admin'], security: device, summary: 'RunPod\'s GPU catalog with availability, through the server\'s key', responses: { 200: ok('Catalog'), 503: error } } },
      '/admin/models': { get: { tags: ['admin'], security: device, summary: 'Models', responses: { 200: ok('Models', { type: 'array', items: ref('PodlightModel') }) } } },
      '/admin/models/{id}': {
        put: { tags: ['admin'], security: device, summary: 'Add or replace a model', parameters: idParam, requestBody: { required: true, content: json(ref('PodlightModel')) }, responses: { 200: ok('Model', ref('PodlightModel')), 400: error, 409: error } },
        delete: { tags: ['admin'], security: device, summary: 'Remove a model, deleting its pod and disk', parameters: idParam, responses: { 204: { description: 'Removed' }, 404: error } },
      },
      '/admin/models/{id}/adopt': { post: {
        tags: ['admin'], security: device, parameters: idParam,
        summary: "Take a model over from a Mac with its pod and the pod's key; the pod is renamed to a server pod, nothing is downloaded again",
        requestBody: { required: true, content: json({ type: 'object', required: ['model', 'podKey'], properties: { model: ref('PodlightModel'), podKey: { type: 'string' }, podId: { type: ['string', 'null'] } } }) },
        responses: { 200: ok('Model and run', { type: 'object', properties: { model: ref('PodlightModel'), run: ref('ModelRun') } }), 400: error, 409: error },
      } },
      '/admin/models/{id}/start': { post: { tags: ['admin'], security: device, summary: 'Start until a time ("Läuft bis"); without one, idle stop ends it', parameters: idParam,
        requestBody: { content: json({ type: 'object', properties: { until: { type: ['string', 'null'], format: 'date-time' }, newPod: { type: 'boolean', description: 'Delete a stopped pod with its disk and build a new one (when its machine has no free card).' }, maxPricePerHour: { type: ['number', 'null'], description: 'The user approved a pricier card: cards up to this price per hour (whole pod) may be booked. Without it, a fallback may cost at most fallbackPriceStepPercent more than the chosen card; above that the start answers 503 card_too_expensive and the run waits for a card within the price.' } } }) }, responses: { 200: ok('Run', ref('ModelRun')), 429: error, 503: error } } },
      '/admin/models/{id}/stop': { post: { tags: ['admin'], security: device, summary: 'Stop (kept disk) or delete the pod', parameters: idParam, responses: { 200: ok('Run', ref('ModelRun')) } } },
      '/admin/models/{id}/extend': { post: { tags: ['admin'], security: device, summary: 'Move "Läuft bis"', parameters: idParam,
        requestBody: { required: true, content: json({ type: 'object', required: ['until'], properties: { until: { type: 'string', format: 'date-time' } } }) }, responses: { 200: ok('Run', ref('ModelRun')) } } },
      '/admin/models/{id}/log': { get: { tags: ['admin'], security: device, summary: 'The engine\'s last log lines', parameters: idParam, responses: { 200: ok('Lines') } } },
      '/admin/models/{id}/telemetry': { get: { tags: ['admin'], security: device, summary: 'What the pod has been doing in the last 30 minutes, oldest first', parameters: idParam,
        responses: { 200: ok('Samples', { type: 'object', properties: { samples: { type: 'array', items: ref('PodTelemetry') } } }), 404: error } } },
      '/admin/client-tokens': {
        get: { tags: ['admin'], security: device, summary: 'Access keys for agents', responses: { 200: ok('Keys', { type: 'array', items: ref('ClientToken') }) } },
        post: { tags: ['admin'], security: device, summary: 'Create an access key, optionally limited to models; the key is shown once',
          requestBody: { required: true, content: json({ type: 'object', required: ['name'], properties: { name: { type: 'string' }, models: { type: ['array', 'null'], items: { type: 'string', format: 'uuid' } } } }) },
          responses: { 200: ok('Key', ref('ClientToken')) } },
      },
      '/admin/client-tokens/{id}': {
        patch: { tags: ['admin'], security: device, summary: 'Rename or change the models of an access key', parameters: idParam, responses: { 200: ok('Key', ref('ClientToken')), 404: error } },
        delete: { tags: ['admin'], security: device, summary: 'Delete a revoked access key', parameters: idParam, responses: { 204: { description: 'Deleted' }, 409: error } },
      },
      '/admin/client-tokens/{id}/revoke': { post: { tags: ['admin'], security: device, summary: 'Revoke an access key', parameters: idParam, responses: { 204: { description: 'Revoked' }, 404: error } } },
      '/admin/devices': { get: { tags: ['admin'], security: device, summary: 'Paired apps', responses: { 200: ok('Devices') } } },
      '/admin/devices/{id}/revoke': { post: { tags: ['admin'], security: device, summary: 'Unpair an app', parameters: idParam, responses: { 204: { description: 'Revoked' } } } },
      '/admin/pair/new-code': { post: { tags: ['admin'], security: device, summary: 'A new pairing code for another device', responses: { 200: ok('Code') } } },
      '/admin/activity': { get: { tags: ['admin'], security: device, summary: 'The last 50 control actions', responses: { 200: ok('Entries') } } },
    },
  }
}
