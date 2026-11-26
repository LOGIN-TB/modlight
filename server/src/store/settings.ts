import type { Sealer } from '../crypto.ts'
import { serverSettings, type ServerSettings, type SettingsPatch } from '../model.ts'
import type { Db } from './db.ts'

/** The server's settings: plain values as one JSON row, secrets encrypted and never read back out. */
export class SettingsStore {
  private readonly db: Db
  private readonly sealer: Sealer
  constructor(db: Db, sealer: Sealer) {
    this.db = db
    this.sealer = sealer
  }

  read(): ServerSettings {
    const row = this.db.prepare(`SELECT value FROM settings WHERE key = 'settings'`).get() as { value: string } | undefined
    const stored = row ? (JSON.parse(row.value) as unknown) : {}
    const parsed = serverSettings.safeParse(stored)
    return parsed.success ? parsed.data : serverSettings.parse({})
  }

  update(patch: SettingsPatch): ServerSettings {
    const { runpodApiKey, huggingFaceToken, veniceApiKey, ...plain } = patch
    const next = serverSettings.parse({ ...this.read(), ...plain })
    this.db.transaction(() => {
      this.db.prepare(`INSERT INTO settings (key, value) VALUES ('settings', ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value`).run(JSON.stringify(next))
      if (runpodApiKey !== undefined) this.setSecret('runpodApiKey', runpodApiKey)
      if (huggingFaceToken !== undefined) this.setSecret('huggingFaceToken', huggingFaceToken)
      if (veniceApiKey !== undefined) this.setSecret('veniceApiKey', veniceApiKey)
    })()
    return next
  }

  secret(name: 'runpodApiKey' | 'huggingFaceToken' | 'veniceApiKey'): string | null {
    const row = this.db.prepare('SELECT value FROM settings WHERE key = ? AND encrypted = 1').get(name) as { value: string } | undefined
    if (!row) return null
    try {
      return this.sealer.open(row.value)
    } catch {
      return null
    }
  }

  private setSecret(name: string, value: string): void {
    const trimmed = value.trim()
    if (trimmed === '') {
      this.db.prepare('DELETE FROM settings WHERE key = ?').run(name)
      return
    }
    this.db.prepare(`INSERT INTO settings (key, value, encrypted) VALUES (?, ?, 1)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, encrypted = 1`).run(name, this.sealer.seal(trimmed))
  }
}
