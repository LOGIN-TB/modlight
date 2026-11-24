import { generatePairingCode, safeEqual } from '../crypto.ts'
import type { Db } from '../store/db.ts'
import type { TokenStore } from './tokens.ts'

/**
 * First contact between an app and the server. The code is short enough to read off a container
 * log, which makes it the weakest secret here: single use, 30 minutes, five wrong guesses. It is
 * kept in the database so a restart does not silently replace the code someone is about to type.
 */
export class Pairing {
  static readonly TTL_MINUTES = 30
  static readonly MAX_ATTEMPTS = 5
  private readonly db: Db
  private readonly tokens: TokenStore

  constructor(db: Db, tokens: TokenStore) {
    this.db = db
    this.tokens = tokens
  }

  private row(): { code: string; expires_at: string; attempts: number; redeemed: number } | undefined {
    return this.db.prepare('SELECT code, expires_at, attempts, redeemed FROM pairing WHERE id = 1').get() as never
  }

  /**
   * The code to print at start. A fresh one when there is none, it expired or was used up, or a
   * fixed one from PAIRING_CODE. Null when a device is already paired and no code is open: then
   * nothing pairs until a paired app asks for a new code.
   */
  codeAtStart(fixed: string | null): { code: string; expiresAt: string } | null {
    if (fixed) return this.issue(fixed)
    const open = this.openCode()
    if (open) return open
    if (this.tokens.activeDevices() > 0) return null
    return this.issue(generatePairingCode())
  }

  /** The code that can still be redeemed, if any. */
  openCode(): { code: string; expiresAt: string } | null {
    const row = this.row()
    const open = row && !row.redeemed && row.attempts < Pairing.MAX_ATTEMPTS && Date.parse(row.expires_at) > Date.now()
    return open ? { code: row.code, expiresAt: row.expires_at } : null
  }

  issue(code: string = generatePairingCode()): { code: string; expiresAt: string } {
    const expiresAt = new Date(Date.now() + Pairing.TTL_MINUTES * 60_000).toISOString()
    this.db.prepare(`INSERT INTO pairing (id, code, expires_at, attempts, redeemed) VALUES (1, ?, ?, 0, 0)
      ON CONFLICT(id) DO UPDATE SET code = excluded.code, expires_at = excluded.expires_at, attempts = 0, redeemed = 0`)
      .run(code, expiresAt)
    return { code, expiresAt }
  }

  redeem(presented: string, deviceName: string): { ok: true; token: string; id: string } | { ok: false; reason: string } {
    const row = this.row()
    if (!row) return { ok: false, reason: 'No pairing code is open. Run podlight-code in the server\'s container, or create one in a paired app.' }
    if (row.redeemed) return { ok: false, reason: 'This pairing code has already been used. Create a new one in a paired app, or run podlight-code in the server\'s container.' }
    if (row.attempts >= Pairing.MAX_ATTEMPTS) return { ok: false, reason: 'Too many wrong attempts. Run podlight-code in the server\'s container for a new code.' }
    if (Date.parse(row.expires_at) <= Date.now()) return { ok: false, reason: 'This pairing code has expired. Run podlight-code in the server\'s container for a new one.' }

    const normalise = (value: string): string => value.trim().toUpperCase().replace(/\s+/g, '')
    if (!safeEqual(normalise(presented), normalise(row.code))) {
      this.db.prepare('UPDATE pairing SET attempts = attempts + 1 WHERE id = 1').run()
      return { ok: false, reason: 'Wrong pairing code.' }
    }
    // Burn the code before issuing: a code that survives its own redemption is an invitation.
    this.db.prepare('UPDATE pairing SET redeemed = 1 WHERE id = 1').run()
    const issued = this.tokens.issue('device', deviceName.trim() || 'Unnamed device')
    return { ok: true, token: issued.token, id: issued.id }
  }
}
