import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { modelSchema, openapi } from './contracts.ts'
import { specPath } from './spec.ts'

const write = (relative: string, value: object): void => {
  const path = specPath(relative)
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`)
  console.log(`wrote ${path}`)
}
write('schema/model.json', modelSchema())
write('openapi.json', openapi())
