import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import { z } from 'zod'
import type { Pairing } from '../auth/pairing.ts'
import type { Identity, TokenStore } from '../auth/tokens.ts'
import { GatewayFailure, failure } from '../gateway/shape.ts'
import { iso, modlightModel, settingsPatch } from '../model.ts'
import { AdoptRefused, type PodManager } from '../pods/manager.ts'
import { RunpodClient } from '../runpod/client.ts'
import { audit, type Db } from '../store/db.ts'
import type { SettingsStore } from '../store/settings.ts'
import { NameTakenError, type StateStore } from '../store/state.ts'
import { presentedKey } from '../gateway/routes.ts'

// The control API for Modlight apps: pairing, settings, models, runs, client tokens. Every
// /admin route needs a device token; a client token is refused here, as a device token is on /v1.

import { VERSION } from '../version.ts'

export { VERSION }

interface Deps {
  db: Db
  tokens: TokenStore
  pairing: Pairing
  settings: SettingsStore
  store: StateStore
  manager: PodManager
  fetch?: typeof fetch
  runpodBase?: string
  wrongKeyDelayMs?: number
}

declare module 'fastify' {
  interface FastifyRequest {
    device?: Identity
  }
}

const pairBody = z.object({ code: z.string().min(1).max(64), deviceName: z.string().max(100).default('') })
const startBody = z.object({ until: z.string().datetime({ offset: true }).nullish(), newPod: z.boolean().optional(), maxPricePerHour: z.number().positive().nullish() })
const extendBody = z.object({ until: z.string().datetime({ offset: true }) })
const tokenBody = z.object({ name: z.string().min(1).max(100), models: z.array(z.guid()).nullish() })
const tokenPatch = z.object({ name: z.string().min(1).max(100).optional(), models: z.array(z.guid()).nullish() })
const verifyBody = z.object({ runpodApiKey: z.string().optional() })
const verifyVeniceBody = z.object({ veniceApiKey: z.string().optional() })
const adoptBody = z.object({ model: modlightModel, podKey: z.string().min(16).max(200), podId: z.string().min(1).max(64).nullish() })

function problem(reply: FastifyReply, status: number, message: string, code: string): FastifyReply {
  return reply.code(status).send({ error: { message, code } })
}

export async function registerAdmin(app: FastifyInstance, deps: Deps): Promise<void> {
  const { tokens, pairing, settings, store, manager } = deps
  const delay = deps.wrongKeyDelayMs ?? 1000

  app.get('/health', async () => ({ status: 'ok', name: 'Modlight', version: VERSION, paired: tokens.activeDevices() > 0 }))

  app.post('/pair', async (request, reply) => {
    const body = pairBody.safeParse(request.body)
    if (!body.success) return problem(reply, 400, 'Send {"code": "...", "deviceName": "..."}.', 'invalid_request')
    const result = pairing.redeem(body.data.code, body.data.deviceName)
    if (!result.ok) {
      await new Promise((resolve) => setTimeout(resolve, delay))
      return problem(reply, 403, result.reason, 'pairing_refused')
    }
    audit(deps.db, body.data.deviceName || 'device', 'paired')
    return { token: result.token, id: result.id, version: VERSION }
  })

  await app.register(async (admin) => {
    admin.addHook('onRequest', async (request: FastifyRequest, reply: FastifyReply) => {
      const identity = tokens.verify('device', presentedKey(request))
      if (!identity) {
        await new Promise((resolve) => setTimeout(resolve, delay))
        return problem(reply, 401, 'This app is not paired with the server, or its pairing was revoked.', 'not_paired')
      }
      request.device = identity
    })

    admin.setErrorHandler((error, _request, reply) => {
      if (error instanceof GatewayFailure) {
        const f = failure(error.error, 'this model')
        return problem(reply, f.status, f.message, f.code)
      }
      if (error instanceof NameTakenError) return problem(reply, 409, error.message, 'name_taken')
      if (error instanceof AdoptRefused) return problem(reply, 409, error.message, error.code)
      if (error instanceof z.ZodError) return problem(reply, 400, z.prettifyError(error), 'invalid_request')
      const status = (error as { statusCode?: number }).statusCode ?? 500
      return problem(reply, status, (error as Error).message, status === 500 ? 'internal' : 'invalid_request')
    })

    const actor = (request: FastifyRequest): string => request.device?.name ?? 'device'
    const publicSettings = () => ({
      ...settings.read(),
      hasRunpodKey: settings.secret('runpodApiKey') !== null,
      hasHuggingFaceToken: settings.secret('huggingFaceToken') !== null,
      hasVeniceKey: settings.secret('veniceApiKey') !== null,
    })

    // "Refresh" in the app: ask RunPod now instead of waiting for the next round.
    admin.post('/admin/refresh', async () => {
      await manager.reconcile()
      return { ok: true }
    })

    admin.get('/admin/state', async () => ({
      version: VERSION,
      serverTime: iso(new Date()),
      models: store.models(),
      runs: store.runs(),
      settings: publicSettings(),
      spendByDay: store.spendByDay(),
      spend: manager.spend(),
      costPerHour: manager.costPerHour(),
      lastClientRequestAt: store.meta('lastClientRequestAt'),
      telemetry: manager.latestTelemetry(),
      balance: manager.balance(),
      apiUsage: store.apiUsage(),
      apiUsageByHour: store.apiUsageByHour(),
      apiTelemetry: manager.apiTelemetry(),
      veniceAccount: manager.veniceAccount(),
    }))

    admin.get('/admin/settings', async () => publicSettings())

    admin.patch('/admin/settings', async (request) => {
      const patch = settingsPatch.parse(request.body ?? {})
      settings.update(patch)
      if (patch.runpodApiKey !== undefined) manager.accountChanged()
      if (patch.veniceApiKey !== undefined) manager.veniceChanged()
      audit(deps.db, actor(request), 'settings', Object.keys(patch).join(', '))
      return publicSettings()
    })

    admin.post('/admin/settings/verify-runpod', async (request) => {
      const body = verifyBody.parse(request.body ?? {})
      const key = body.runpodApiKey?.trim() || settings.secret('runpodApiKey')
      if (!key) return { result: 'invalid' }
      return { result: await new RunpodClient(key, deps.fetch, deps.runpodBase).checkKey() }
    })

    // A Venice key is checked with the one call every key type may make; the answer carries the balance.
    admin.post('/admin/settings/verify-venice', async (request) => {
      const body = verifyVeniceBody.parse(request.body ?? {})
      const key = body.veniceApiKey?.trim() || settings.secret('veniceApiKey')
      if (!key) return { result: 'invalid' }
      const check = await manager.veniceClient(key).checkKey()
      return check.valid ? { result: 'valid', account: check.account } : { result: check.reason, message: check.message ?? null }
    })

    admin.get('/admin/catalog/venice', async () => ({ models: await manager.veniceClient().catalog() }))

    admin.get('/admin/catalog/gpus', async () => ({ gpus: await manager.client().gpuCatalog() }))

    admin.get('/admin/models', async () => store.models())

    admin.put<{ Params: { id: string } }>('/admin/models/:id', async (request, reply) => {
      const model = modlightModel.parse(request.body)
      if (model.id.toLowerCase() !== request.params.id.toLowerCase()) return problem(reply, 400, 'The id in the path and the body differ.', 'invalid_request')
      manager.save(model)
      audit(deps.db, actor(request), 'model saved', model.name)
      return store.model(model.id)
    })

    // A model handed over from a Mac, with its pod and the pod's key: nothing is downloaded again.
    admin.post<{ Params: { id: string } }>('/admin/models/:id/adopt', async (request, reply) => {
      const body = adoptBody.parse(request.body)
      if (body.model.id.toLowerCase() !== request.params.id.toLowerCase()) return problem(reply, 400, 'The id in the path and the body differ.', 'invalid_request')
      await manager.adopt(body.model, body.podKey, body.podId ?? null)
      audit(deps.db, actor(request), 'model handed over', body.model.name)
      return { model: store.model(body.model.id), run: store.run(body.model.id) }
    })

    admin.delete<{ Params: { id: string } }>('/admin/models/:id', async (request, reply) => {
      const model = store.model(request.params.id)
      if (!model) return problem(reply, 404, 'No such model.', 'model_not_found')
      await manager.remove(model.id)
      audit(deps.db, actor(request), 'model removed', model.name)
      return reply.code(204).send()
    })

    admin.post<{ Params: { id: string } }>('/admin/models/:id/start', async (request, reply) => {
      const model = store.model(request.params.id)
      if (!model) return problem(reply, 404, 'No such model.', 'model_not_found')
      const body = startBody.parse(request.body ?? {})
      await manager.start(model.id, body.until ? new Date(body.until) : null, true, body.newPod ?? false, body.maxPricePerHour ?? null)
      audit(deps.db, actor(request), 'start', `${model.name} until ${body.until ?? 'idle stop'}`)
      return store.run(model.id)
    })

    admin.post<{ Params: { id: string } }>('/admin/models/:id/stop', async (request, reply) => {
      const model = store.model(request.params.id)
      if (!model) return problem(reply, 404, 'No such model.', 'model_not_found')
      await manager.stop(model.id, 'manual')
      audit(deps.db, actor(request), 'stop', model.name)
      return store.run(model.id)
    })

    admin.post<{ Params: { id: string } }>('/admin/models/:id/extend', async (request, reply) => {
      const model = store.model(request.params.id)
      if (!model) return problem(reply, 404, 'No such model.', 'model_not_found')
      const body = extendBody.parse(request.body ?? {})
      await manager.extend(model.id, new Date(body.until))
      audit(deps.db, actor(request), 'extend', `${model.name} until ${body.until}`)
      return store.run(model.id)
    })

    admin.get<{ Params: { id: string } }>('/admin/models/:id/log', async (request, reply) => {
      const model = store.model(request.params.id)
      if (!model) return problem(reply, 404, 'No such model.', 'model_not_found')
      return { lines: (await manager.engineLog(model.id)) ?? [] }
    })

    admin.get<{ Params: { id: string } }>('/admin/models/:id/telemetry', async (request, reply) => {
      const model = store.model(request.params.id)
      if (!model) return problem(reply, 404, 'No such model.', 'model_not_found')
      return { samples: manager.telemetry(model.id) }
    })

    admin.get('/admin/client-tokens', async () => tokens.list('client'))

    admin.post('/admin/client-tokens', async (request) => {
      const body = tokenBody.parse(request.body)
      const issued = tokens.issue('client', body.name, body.models ?? null)
      audit(deps.db, actor(request), 'client token created', body.name)
      return { ...tokens.list('client').find((t) => t.id === issued.id), token: issued.token }
    })

    admin.patch<{ Params: { id: string } }>('/admin/client-tokens/:id', async (request, reply) => {
      const body = tokenPatch.parse(request.body ?? {})
      const exists = tokens.list('client').some((t) => t.id === request.params.id)
      if (!exists) return problem(reply, 404, 'No such access key.', 'not_found')
      if (body.name) tokens.rename('client', request.params.id, body.name)
      if (body.models !== undefined) tokens.setModels(request.params.id, body.models ?? null)
      return tokens.list('client').find((t) => t.id === request.params.id)
    })

    admin.post<{ Params: { id: string } }>('/admin/client-tokens/:id/revoke', async (request, reply) => {
      if (!tokens.revoke('client', request.params.id)) return problem(reply, 404, 'No such active access key.', 'not_found')
      audit(deps.db, actor(request), 'client token revoked', request.params.id)
      return reply.code(204).send()
    })

    admin.delete<{ Params: { id: string } }>('/admin/client-tokens/:id', async (request, reply) => {
      if (!tokens.delete('client', request.params.id)) return problem(reply, 409, 'Revoke the access key before deleting it.', 'still_active')
      return reply.code(204).send()
    })

    admin.get('/admin/devices', async (request) =>
      tokens.list('device').map((d) => ({ ...d, current: d.id === request.device?.id })))

    admin.post<{ Params: { id: string } }>('/admin/devices/:id/revoke', async (request, reply) => {
      if (!tokens.revoke('device', request.params.id)) return problem(reply, 404, 'No such active device.', 'not_found')
      audit(deps.db, actor(request), 'device revoked', request.params.id)
      return reply.code(204).send()
    })

    admin.post('/admin/pair/new-code', async (request) => {
      audit(deps.db, actor(request), 'pairing code created')
      return pairing.issue()
    })

    admin.get('/admin/activity', async () =>
      deps.db.prepare('SELECT at, actor, action, detail FROM audit_log ORDER BY id DESC LIMIT 50').all())
  })
}
