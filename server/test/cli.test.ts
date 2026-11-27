import { strict as assert } from 'node:assert'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, test } from 'node:test'
import { Pairing } from '../src/auth/pairing.ts'
import { TokenStore } from '../src/auth/tokens.ts'
import { openDatabase } from '../src/store/db.ts'

// modlight-info and modlight-code as the container runs them, against a data folder of their own.
const cli = (dataDir: string, command: string): string =>
  execFileSync(process.execPath, ['--disable-warning=ExperimentalWarning', 'src/cli.ts', command], {
    env: { PATH: process.env.PATH, DATA_DIR: dataDir, PUBLIC_IP_LOOKUP: 'false', MODLIGHT_LANG: 'en' },
    encoding: 'utf8',
  })

const withData = (prepare: (pairing: Pairing, tokens: TokenStore, db: ReturnType<typeof openDatabase>) => void): string => {
  const dir = mkdtempSync(join(tmpdir(), 'modlight-cli-'))
  const db = openDatabase(join(dir, 'modlight.db'))
  const tokens = new TokenStore(db)
  prepare(new Pairing(db, tokens), tokens, db)
  db.close()
  return dir
}
const expire = (db: ReturnType<typeof openDatabase>): void => {
  db.prepare("UPDATE pairing SET expires_at = '2026-01-01T00:00:00.000Z'").run()
}
const codeIn = (box: string): string | undefined => /\b([A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4})\b/.exec(box)?.[1]

describe('modlight-info', () => {
  test('nothing paired and the code expired: a fresh code, not "Already paired"', () => {
    const dir = withData((pairing, _tokens, db) => { pairing.issue(); expire(db) })
    try {
      const box = cli(dir, 'info')
      assert.doesNotMatch(box, /Already paired/)
      assert.ok(codeIn(box))
      assert.equal(cli(dir, 'info').includes(codeIn(box)!), true, 'the same code until it is used or expires')
    } finally { rmSync(dir, { recursive: true, force: true }) }
  })

  test('an open code is shown as it is', () => {
    let code = ''
    const dir = withData((pairing) => { code = pairing.issue().code })
    try {
      assert.equal(codeIn(cli(dir, 'info')), code)
    } finally { rmSync(dir, { recursive: true, force: true }) }
  })

  test('a paired device and no open code: "Already paired", no new code', () => {
    const dir = withData((pairing, tokens, db) => { pairing.issue(); expire(db); tokens.issue('device', 'Mac') })
    try {
      const box = cli(dir, 'info')
      assert.match(box, /Already paired/)
      assert.equal(codeIn(box), undefined)
      assert.ok(codeIn(cli(dir, 'new-code')), 'modlight-code still makes one')
    } finally { rmSync(dir, { recursive: true, force: true }) }
  })
})
