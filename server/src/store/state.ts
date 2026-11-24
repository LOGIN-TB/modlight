import type { Sealer } from '../crypto.ts'
import { emptyRun, modelRun, type ModelRun, podlightModel, type PodlightModel } from '../model.ts'
import type { Spend } from '../rules/scheduler.ts'
import type { Db } from './db.ts'

/** Models, their runs and the spend ledger, in SQLite. RunPod is the source of truth for pods. */
export class StateStore {
  private readonly db: Db
  private readonly sealer: Sealer
  constructor(db: Db, sealer: Sealer) {
    this.db = db
    this.sealer = sealer
  }

  models(): PodlightModel[] {
    const rows = this.db.prepare('SELECT json FROM models ORDER BY position, name').all() as Array<{ json: string }>
    return rows.flatMap((r) => {
      const parsed = podlightModel.safeParse(JSON.parse(r.json))
      return parsed.success ? [parsed.data] : []
    })
  }

  model(id: string): PodlightModel | null {
    const row = this.db.prepare('SELECT json FROM models WHERE id = ? COLLATE NOCASE').get(id) as { json: string } | undefined
    return row ? podlightModel.parse(JSON.parse(row.json)) : null
  }

  modelNamed(name: string): PodlightModel | null {
    const row = this.db.prepare('SELECT json FROM models WHERE name = ?').get(name) as { json: string } | undefined
    return row ? podlightModel.parse(JSON.parse(row.json)) : null
  }

  /** Inserts or replaces. Throws when another model already has the name. */
  saveModel(model: PodlightModel): void {
    const clash = this.db.prepare('SELECT id FROM models WHERE name = ? AND id <> ? COLLATE NOCASE').get(model.name, model.id)
    if (clash) throw new NameTakenError(model.name)
    const position = (this.db.prepare('SELECT COALESCE(MAX(position), 0) + 1 AS p FROM models').get() as { p: number }).p
    this.db.prepare(`INSERT INTO models (id, name, json, position) VALUES (?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET name = excluded.name, json = excluded.json`)
      .run(model.id, model.name, JSON.stringify(model), position)
  }

  removeModel(id: string): void {
    this.db.transaction(() => {
      this.db.prepare('DELETE FROM models WHERE id = ? COLLATE NOCASE').run(id)
      this.db.prepare('DELETE FROM runs WHERE model_id = ? COLLATE NOCASE').run(id)
    })()
  }

  /** The pod's own key, created on first use and kept encrypted. */
  podKey(id: string, create: () => string): string {
    const row = this.db.prepare('SELECT pod_key FROM models WHERE id = ? COLLATE NOCASE').get(id) as { pod_key: string | null } | undefined
    if (row?.pod_key) return this.sealer.open(row.pod_key)
    const key = create()
    this.db.prepare('UPDATE models SET pod_key = ? WHERE id = ? COLLATE NOCASE').run(this.sealer.seal(key), id)
    return key
  }

  /** Sets the pod's key, for a pod that came with its key (a model handed over from a Mac). */
  setPodKey(id: string, key: string): void {
    this.db.prepare('UPDATE models SET pod_key = ? WHERE id = ? COLLATE NOCASE').run(this.sealer.seal(key), id)
  }

  run(id: string): ModelRun {
    const row = this.db.prepare('SELECT json FROM runs WHERE model_id = ? COLLATE NOCASE').get(id) as { json: string } | undefined
    if (!row) return emptyRun()
    const raw = JSON.parse(row.json) as Record<string, unknown>
    const parsed = modelRun.safeParse(raw)
    if (parsed.success) return parsed.data
    // A field that no longer parses (a pod status RunPod added, say) must not cost the whole run,
    // above all its pod id: without it the pod would bill on, unseen.
    const broken = new Set(parsed.error.issues.map((issue) => String(issue.path[0])))
    return modelRun.safeParse(Object.fromEntries(Object.entries(raw).filter(([key]) => !broken.has(key)))).data ?? emptyRun()
  }

  runs(): Record<string, ModelRun> {
    return Object.fromEntries(this.models().map((m) => [m.id, this.run(m.id)]))
  }

  updateRun(id: string, change: (run: ModelRun) => void): ModelRun {
    return this.db.transaction(() => {
      const run = this.run(id)
      change(run)
      // Drop keys set to undefined/null so the stored JSON stays the shape Swift writes.
      const clean = Object.fromEntries(Object.entries(run).filter(([, v]) => v !== undefined && v !== null))
      this.db.prepare(`INSERT INTO runs (model_id, json) VALUES (?, ?)
        ON CONFLICT(model_id) DO UPDATE SET json = excluded.json`).run(id, JSON.stringify(clean))
      return run
    })()
  }

  addSpend(day: string, usd: number): void {
    if (!(usd > 0)) return
    this.db.prepare(`INSERT INTO spend_by_day (day, usd) VALUES (?, ?)
      ON CONFLICT(day) DO UPDATE SET usd = usd + excluded.usd`).run(day, usd)
  }

  spendByDay(): Record<string, number> {
    const rows = this.db.prepare('SELECT day, usd FROM spend_by_day ORDER BY day').all() as Array<{ day: string; usd: number }>
    return Object.fromEntries(rows.map((r) => [r.day, r.usd]))
  }

  spend(today: string, limits: { dailyLimitUsd: number | null; monthlyLimitUsd: number | null }): Spend {
    const byDay = this.spendByDay()
    const month = today.slice(0, 7)
    return {
      todayUsd: byDay[today] ?? 0,
      monthUsd: Object.entries(byDay).filter(([d]) => d.startsWith(month)).reduce((sum, [, v]) => sum + v, 0),
      dailyLimitUsd: limits.dailyLimitUsd,
      monthlyLimitUsd: limits.monthlyLimitUsd,
    }
  }

  meta(key: string): string | null {
    return (this.db.prepare('SELECT value FROM meta WHERE key = ?').get(key) as { value: string } | undefined)?.value ?? null
  }

  setMeta(key: string, value: string): void {
    this.db.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value').run(key, value)
  }
}

export class NameTakenError extends Error {
  readonly modelName: string
  constructor(name: string) {
    super(`A model named "${name}" already exists on this server.`)
    this.modelName = name
  }
}

/** `yyyy-MM-dd` of an instant in a time zone (unknown zones fall back to UTC). */
export function dayKey(date: Date, timeZone: string): string {
  let fmt: Intl.DateTimeFormat
  try {
    fmt = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
  } catch {
    fmt = new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', year: 'numeric', month: '2-digit', day: '2-digit' })
  }
  return fmt.format(date)
}
