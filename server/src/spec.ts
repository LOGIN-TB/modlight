import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// The shared `spec/` folder: next to `server/` in the repository, or copied to `/app/spec` in the
// image. SPEC_DIR overrides both.
const here = dirname(fileURLToPath(import.meta.url))
const candidates = [process.env.SPEC_DIR, resolve(here, '../../spec'), resolve(here, '../spec')].filter(Boolean) as string[]
export const SPEC_DIR = candidates.find((dir) => existsSync(join(dir, 'data/regions.json'))) ?? candidates[0]!

export const specPath = (relative: string): string => join(SPEC_DIR, relative)
