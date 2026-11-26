import Database from 'better-sqlite3'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'

export type Db = Database.Database

/**
 * Versioned migrations: each entry runs once, in order, inside a transaction, and
 * `PRAGMA user_version` records how far the database is. Never edit an entry that has shipped;
 * add a new one.
 */
const MIGRATIONS: string[] = [
  `CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, encrypted INTEGER NOT NULL DEFAULT 0);
   CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
     created_at TEXT NOT NULL, last_used_at TEXT, revoked_at TEXT);
   CREATE TABLE client_tokens (id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
     created_at TEXT NOT NULL, last_used_at TEXT, revoked_at TEXT, models TEXT);
   CREATE TABLE pairing (id INTEGER PRIMARY KEY CHECK (id = 1), code TEXT NOT NULL, expires_at TEXT NOT NULL,
     attempts INTEGER NOT NULL DEFAULT 0, redeemed INTEGER NOT NULL DEFAULT 0);
   CREATE TABLE models (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, json TEXT NOT NULL, pod_key TEXT,
     position INTEGER NOT NULL DEFAULT 0);
   CREATE TABLE runs (model_id TEXT PRIMARY KEY, json TEXT NOT NULL);
   CREATE TABLE spend_by_day (day TEXT PRIMARY KEY, usd REAL NOT NULL);
   CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
   CREATE TABLE audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, actor TEXT NOT NULL,
     action TEXT NOT NULL, detail TEXT);`,
  // 0.11: tokens and cost of API models (Venice) per day and model.
  `CREATE TABLE api_usage (day TEXT NOT NULL, model_id TEXT NOT NULL, requests INTEGER NOT NULL DEFAULT 0,
     prompt_tokens INTEGER NOT NULL DEFAULT 0, completion_tokens INTEGER NOT NULL DEFAULT 0,
     cached_tokens INTEGER NOT NULL DEFAULT 0, usd REAL NOT NULL DEFAULT 0, PRIMARY KEY (day, model_id));`,
]

export function openDatabase(path: string): Db {
  if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true })
  const db = new Database(path)
  db.pragma('journal_mode = WAL')
  db.pragma('foreign_keys = ON')
  migrate(db)
  return db
}

export function migrate(db: Db): void {
  const current = db.pragma('user_version', { simple: true }) as number
  for (let version = current; version < MIGRATIONS.length; version++) {
    db.transaction(() => {
      db.exec(MIGRATIONS[version]!)
      db.pragma(`user_version = ${version + 1}`)
    })()
  }
}

export function audit(db: Db, actor: string, action: string, detail?: string): void {
  db.prepare('INSERT INTO audit_log (at, actor, action, detail) VALUES (?, ?, ?, ?)')
    .run(new Date().toISOString(), actor, action, detail ?? null)
  // Keep the log bounded; it is for "what happened recently", not an archive.
  db.prepare('DELETE FROM audit_log WHERE id <= (SELECT MAX(id) - 1000 FROM audit_log)').run()
}
