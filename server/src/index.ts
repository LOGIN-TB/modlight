import { buildServer } from './app.ts'
import { loadOrCreateMasterKey, sealer } from './crypto.ts'
import { openDatabase } from './store/db.ts'
import { VERSION } from './version.ts'
import { connectionInfo, lookupPublicIp } from './connection-info.ts'

// Modlight server: one container, one data volume. Speaks plain HTTP; put a reverse proxy with a
// certificate (Coolify, Traefik, Caddy) in front of it before it is reachable from the internet.

const env = process.env
const dataDir = env.DATA_DIR ?? '/data'
const port = Number.parseInt(env.PORT ?? '8080', 10)
const host = env.HOST ?? '0.0.0.0'

const db = openDatabase(env.DATABASE_PATH ?? `${dataDir}/modlight.db`)
const key = loadOrCreateMasterKey(env.MASTER_KEY_PATH ?? `${dataDir}/keys/master.key`)
const server = await buildServer({
  db, sealer: sealer(key),
  logger: { level: env.LOG_LEVEL ?? 'info' },
  trustProxy: env.TRUST_PROXY !== 'false',
  manager: { log: (message) => server.app.log.info(message) },
})

const code = server.pairing.codeAtStart(env.PAIRING_CODE?.trim() || null)
await server.app.listen({ port, host })
server.app.log.info(`Modlight server ${VERSION} listening on ${host}:${port}`)
// Printed plainly, not as log JSON, so it stands out in `docker logs` and Coolify's log view.
const publicIp = await lookupPublicIp(env)
console.log(connectionInfo({ env, version: VERSION, port, code, publicIp }).join('\n'))

// Every 10 s while something runs, every 20 s otherwise: re-read RunPod, feed the watchdogs,
// apply the rules. Without this loop nothing ever stops, so it never gives up on an error.
let stopping = false
const loop = async (): Promise<void> => {
  if (stopping) return
  try {
    await server.manager.tick()
  } catch (error) {
    server.app.log.error({ err: error }, 'tick failed')
  }
  setTimeout(loop, server.manager.isBusy() ? 10_000 : 20_000).unref()
}
void loop()

// Apart from the tick, which can wait minutes on a start: every 10 s, let go of pods RunPod no
// longer has, so a pod deleted elsewhere does not linger in the app.
const reconcileLoop = async (): Promise<void> => {
  if (stopping) return
  await server.manager.reconcile().catch((error) => server.app.log.error({ err: error }, 'reconcile failed'))
  setTimeout(reconcileLoop, 10_000).unref()
}
setTimeout(reconcileLoop, 10_000).unref()

// Pods keep running when the container stops: the server is the long-running side, and a pod
// without heartbeats stops itself after the configured minutes.
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    stopping = true
    server.app.log.info(`${signal}: closing; running pods stop themselves without heartbeats`)
    void server.app.close().then(() => { db.close(); process.exit(0) })
  })
}
