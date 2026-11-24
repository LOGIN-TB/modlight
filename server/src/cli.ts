import { Pairing } from './auth/pairing.ts'
import { TokenStore } from './auth/tokens.ts'
import { connectionInfo, lookupPublicIp } from './connection-info.ts'
import { openDatabase } from './store/db.ts'
import { VERSION } from './version.ts'

// Run inside the container: `podlight-code` (a new pairing code, for another Mac or when the
// first code expired) and `podlight-info` (the connection box again, with the open code if any).
// Works next to the running server: SQLite in WAL mode takes the one short write.

const env = process.env
const command = process.argv[2] ?? 'info'
if (command !== 'new-code' && command !== 'info') {
  console.error('Usage: cli.ts new-code | info')
  process.exit(2)
}
const dataDir = env.DATA_DIR ?? '/data'
const db = openDatabase(env.DATABASE_PATH ?? `${dataDir}/podlight.db`)
const pairing = new Pairing(db, new TokenStore(db))
const code = command === 'new-code' ? pairing.issue() : pairing.openCode()
const port = Number.parseInt(env.PORT ?? '8080', 10)
console.log(connectionInfo({ env, version: VERSION, port, code, publicIp: await lookupPublicIp(env) }).join('\n'))
db.close()
