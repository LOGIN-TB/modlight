import { readFileSync } from 'node:fs'

/** The server's version, from its package.json, so it cannot drift from the release. */
export const VERSION: string = (JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as { version: string }).version
