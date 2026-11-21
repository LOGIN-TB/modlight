import { strict as assert } from 'node:assert'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { modelSchema, openapi } from '../src/contracts.ts'
import { specPath } from '../src/spec.ts'

// spec/schema/model.json and spec/openapi.json are generated; run `npm run gen` after a change.
for (const [file, build] of [['schema/model.json', modelSchema], ['openapi.json', openapi]] as const) {
  test(`spec/${file} is up to date`, () => {
    const stored = readFileSync(specPath(file), 'utf8')
    assert.equal(stored, `${JSON.stringify(build(), null, 2)}\n`, `spec/${file} is stale: run npm run gen in server/`)
  })
}
