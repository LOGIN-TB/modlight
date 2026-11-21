import { randomUUID } from 'node:crypto'
import { generateToken, safeEqual, sha256 } from '../crypto.ts'
import type { Db } from '../store/db.ts'

// Two kinds of keys that never stand in for each other:
// - device tokens: an app that controls this server (/admin), issued by pairing;
// - client tokens: an agent that uses models (/v1), issued by an app, optionally limited to models.
// Both are stored as SHA-256 hashes: they are 256-bit random values, so the hash only has to
// survive a database leak.

export type TokenKind = 'device' | 'client'
const TABLE: Record<TokenKind, string> = { device: 'devices', client: 'client_tokens' }
const PREFIX: Record<TokenKind, string> = { device: 'pld-', client: 'pl-' }

export interface Identity {
  id: string
  name: string
  /** Client tokens: model ids this key may use. Null: every model. */
  models: string[] | null
}

export interface TokenSummary {
  id: string
  name: string
  createdAt: string
  lastUsedAt: string | null
  revokedAt: string | null
  models: string[] | null
}

interface Row {
  id: string
  name: string
  token_hash: string
  created_at: string
  last_used_at: string | null
  revoked_at: string | null
  models?: string | null
}

const parseModels = (value: string | null | undefined): string[] | null => (value ? (JSON.parse(value) as string[]) : null)

export class TokenStore {
  private readonly db: Db
  private lastUsedWrites = new Map<string, number>()
  constructor(db: Db) {
    this.db = db
  }

  /** Issues a token and returns it once; it is never retrievable again. */
  issue(kind: TokenKind, name: string, models: string[] | null = null): { id: string; token: string } {
    const id = randomUUID()
    const token = generateToken(PREFIX[kind])
    const now = new Date().toISOString()
    if (kind === 'client') {
      this.db.prepare('INSERT INTO client_tokens (id, name, token_hash, created_at, models) VALUES (?, ?, ?, ?, ?)')
        .run(id, name, sha256(token), now, models ? JSON.stringify(models) : null)
    } else {
      this.db.prepare('INSERT INTO devices (id, name, token_hash, created_at) VALUES (?, ?, ?, ?)')
        .run(id, name, sha256(token), now)
    }
    return { id, token }
  }

  /** Resolves a presented token, or null when unknown or revoked. */
  verify(kind: TokenKind, token: string): Identity | null {
    if (!token.startsWith(PREFIX[kind])) return null
    const presented = sha256(token)
    const rows = this.db.prepare(`SELECT * FROM ${TABLE[kind]} WHERE revoked_at IS NULL`).all() as Row[]
    const match = rows.find((row) => safeEqual(row.token_hash, presented))
    if (!match) return null
    // Agents send many requests; record use at most once a minute.
    const now = Date.now()
    if ((this.lastUsedWrites.get(match.id) ?? 0) < now - 60_000) {
      this.lastUsedWrites.set(match.id, now)
      this.db.prepare(`UPDATE ${TABLE[kind]} SET last_used_at = ? WHERE id = ?`).run(new Date(now).toISOString(), match.id)
    }
    return { id: match.id, name: match.name, models: parseModels(match.models) }
  }

  setModels(id: string, models: string[] | null): boolean {
    return this.db.prepare('UPDATE client_tokens SET models = ? WHERE id = ?')
      .run(models ? JSON.stringify(models) : null, id).changes > 0
  }

  rename(kind: TokenKind, id: string, name: string): boolean {
    return this.db.prepare(`UPDATE ${TABLE[kind]} SET name = ? WHERE id = ?`).run(name, id).changes > 0
  }

  revoke(kind: TokenKind, id: string): boolean {
    return this.db.prepare(`UPDATE ${TABLE[kind]} SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`)
      .run(new Date().toISOString(), id).changes > 0
  }

  /** Removes a revoked entry. Only a revoked one: deleting must never be what cuts off a client. */
  delete(kind: TokenKind, id: string): boolean {
    return this.db.prepare(`DELETE FROM ${TABLE[kind]} WHERE id = ? AND revoked_at IS NOT NULL`).run(id).changes > 0
  }

  list(kind: TokenKind): TokenSummary[] {
    const rows = this.db.prepare(`SELECT * FROM ${TABLE[kind]} ORDER BY created_at DESC`).all() as Row[]
    return rows.map((r) => ({
      id: r.id, name: r.name, createdAt: r.created_at, lastUsedAt: r.last_used_at, revokedAt: r.revoked_at,
      models: parseModels(r.models),
    }))
  }

  activeDevices(): number {
    return (this.db.prepare('SELECT COUNT(*) AS n FROM devices WHERE revoked_at IS NULL').get() as { n: number }).n
  }
}
