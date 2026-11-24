import { strict as assert } from 'node:assert'
import { describe, test } from 'node:test'
import { connectionInfo, language, lookupPublicIp, publicUrl } from '../src/connection-info.ts'

const now = new Date('2026-11-24T10:00:00Z')
const code = { code: 'ABCD-EFGH-JKLM', expiresAt: '2026-11-24T10:30:00Z' }
const box = (env: Record<string, string | undefined>, extra: Partial<Parameters<typeof connectionInfo>[0]> = {}) =>
  connectionInfo({ env, version: '0.8.0', port: 8080, code, publicIp: null, now, ...extra }).join('\n')

describe('connection box', () => {
  test('Coolify: the domain from SERVICE_URL, without the internal port, comes first', () => {
    const text = box({ SERVICE_URL_PODLIGHT_8080: 'https://podlight.example.com', SERVICE_FQDN_PODLIGHT_8080: 'podlight.example.com', HOSTNAME: 'abc123' })
    assert.match(text, /https:\/\/podlight\.example\.com {3}\(Coolify domain\)/)
    assert.match(text, /ABCD-EFGH-JKLM {6}valid 30 min \(until 10:30 UTC\)/)
    assert.match(text, /docker exec abc123 podlight-code/)
    assert.doesNotMatch(text, /IP of this server/)
  })

  test('a FQDN without scheme gets https, several domains use the first', () => {
    assert.deepEqual(publicUrl({ SERVICE_FQDN_PODLIGHT_8080: 'a.example.com,b.example.com' }), { url: 'https://a.example.com', source: 'coolify' })
    assert.deepEqual(publicUrl({ PUBLIC_URL: 'https://own.example.com/', SERVICE_URL_X: 'https://c.example.com' }), { url: 'https://own.example.com', source: 'own' })
    assert.equal(publicUrl({ SERVICE_FQDN_PODLIGHT_8080: '' }), null)
  })

  test('a plain-http public domain (Coolify sslip.io) is flagged', () => {
    const text = box({ SERVICE_URL_PODLIGHT_8080: 'http://podlight.203.0.113.7.sslip.io' })
    assert.match(text, /only accepts https/)
  })

  test('plain Docker: LAN address from HOST_IP, public IP with the reverse-proxy hint', () => {
    const text = box({ HOST_IP: '192.168.1.20', HOST_PORT: '9000' }, { publicIp: '203.0.113.7' })
    assert.match(text, /http:\/\/192\.168\.1\.20:9000 {3}\(your network only, unencrypted\)/)
    assert.match(text, /Public IP 203\.0\.113\.7/)
    assert.match(text, /reverse proxy/)
  })

  test('nothing known: says how to find the IP', () => {
    const text = box({})
    assert.match(text, /http:\/\/<IP of this server>:8080/)
    assert.match(text, /HOST_IP/)
  })

  test('the public IP is left out when an https domain is there', () => {
    const text = box({ PUBLIC_URL: 'https://podlight.example.com' }, { publicIp: '203.0.113.7' })
    assert.doesNotMatch(text, /203\.0\.113\.7/)
  })

  test('already paired, expired code, German', () => {
    assert.match(box({}, { code: null }), /Already paired/)
    assert.match(box({}, { code: { code: 'X', expiresAt: '2026-11-24T09:00:00Z' } }), /expired/)
    const de = box({ PODLIGHT_LANG: 'de', HOST_IP: '10.0.0.5' })
    assert.match(de, /VERBINDUNG/)
    assert.match(de, /Kopplungscode/)
    assert.match(de, /gültig 30 Min\./)
    assert.equal(language({ LANG: 'de_DE.UTF-8' }), 'de')
    assert.equal(language({}), 'en')
  })

  test('public IP lookup: off, ok, garbage, failure', async () => {
    const reply = (body: string, ok = true) => (async () => new Response(body, { status: ok ? 200 : 500 })) as unknown as typeof fetch
    assert.equal(await lookupPublicIp({ PUBLIC_IP_LOOKUP: 'false' }, reply('1.2.3.4')), null)
    assert.equal(await lookupPublicIp({}, reply('203.0.113.7\n')), '203.0.113.7')
    assert.equal(await lookupPublicIp({}, reply('<html>')), null)
    assert.equal(await lookupPublicIp({}, reply('', false)), null)
    assert.equal(await lookupPublicIp({}, (async () => { throw new Error('offline') }) as unknown as typeof fetch), null)
  })
})
