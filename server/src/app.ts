import Fastify, { type FastifyInstance } from 'fastify'
import { Pairing } from './auth/pairing.ts'
import { TokenStore } from './auth/tokens.ts'
import { type Sealer } from './crypto.ts'
import { registerAdmin } from './admin/routes.ts'
import { BODY_LIMIT, registerGateway } from './gateway/routes.ts'
import { PodManager, type ManagerOptions } from './pods/manager.ts'
import type { Db } from './store/db.ts'
import { SettingsStore } from './store/settings.ts'
import { StateStore } from './store/state.ts'

export interface Server {
  app: FastifyInstance
  db: Db
  tokens: TokenStore
  pairing: Pairing
  settings: SettingsStore
  store: StateStore
  manager: PodManager
}

export interface BuildOptions {
  db: Db
  sealer: Sealer
  logger?: boolean | object
  trustProxy?: boolean
  manager?: Partial<ManagerOptions>
  fetch?: typeof fetch
  wrongKeyDelayMs?: number
  proxyRetryDelayMs?: number
}

/** Everything but the listening socket and the tick loop, so tests can drive it with inject(). */
export async function buildServer(o: BuildOptions): Promise<Server> {
  const app = Fastify({
    logger: o.logger ?? false,
    // Long generations must not be cut off by our own server.
    requestTimeout: 0,
    bodyLimit: BODY_LIMIT,
    trustProxy: o.trustProxy ?? false,
  })
  const tokens = new TokenStore(o.db)
  const pairing = new Pairing(o.db, tokens)
  const settings = new SettingsStore(o.db, o.sealer)
  const store = new StateStore(o.db, o.sealer)
  const manager = new PodManager({ store, settings, ...(o.fetch ? { fetch: o.fetch } : {}), ...o.manager })
  const delay = o.wrongKeyDelayMs ?? 1000
  await registerAdmin(app, {
    db: o.db, tokens, pairing, settings, store, manager, wrongKeyDelayMs: delay,
    ...(o.fetch ? { fetch: o.fetch } : {}), ...(o.manager?.runpodBase ? { runpodBase: o.manager.runpodBase } : {}),
  })
  await registerGateway(app, {
    tokens, manager, store, wrongKeyDelayMs: delay, ...(o.fetch ? { fetch: o.fetch } : {}),
    ...(o.proxyRetryDelayMs !== undefined ? { proxyRetryDelayMs: o.proxyRetryDelayMs } : {}),
  })
  return { app, db: o.db, tokens, pairing, settings, store, manager }
}
