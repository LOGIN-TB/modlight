import { createCipheriv, createDecipheriv, createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

// Taken over from RunPod Launcher's service (store/crypto.ts).

const ALGORITHM = 'aes-256-gcm'
const KEY_BYTES = 32
const IV_BYTES = 12

/**
 * Loads the master key, creating it on first start. A file in the data volume rather than a
 * password: the server has to stop a pod at 03:00 without anybody present, also after a reboot.
 */
export function loadOrCreateMasterKey(path: string): Buffer {
  try {
    const key = readFileSync(path)
    if (key.length !== KEY_BYTES) throw new Error(`Master key at ${path} is ${key.length} bytes, expected ${KEY_BYTES}`)
    return key
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    const key = randomBytes(KEY_BYTES)
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
    writeFileSync(path, key, { mode: 0o600 })
    chmodSync(path, 0o600)
    return key
  }
}

export interface Sealer {
  seal(plaintext: string): string
  open(stored: string): string
}

export function sealer(key: Buffer): Sealer {
  return {
    seal(plaintext) {
      const iv = randomBytes(IV_BYTES)
      const cipher = createCipheriv(ALGORITHM, key, iv)
      const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()])
      return [iv, cipher.getAuthTag(), ciphertext].map((b) => b.toString('base64url')).join('.')
    },
    open(stored) {
      const parts = stored.split('.')
      if (parts.length !== 3) throw new Error('Malformed encrypted value')
      const [iv, tag, ciphertext] = parts.map((p) => Buffer.from(p, 'base64url')) as [Buffer, Buffer, Buffer]
      const decipher = createDecipheriv(ALGORITHM, key, iv)
      decipher.setAuthTag(tag)
      return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8')
    },
  }
}

/** Constant-time comparison, for tokens and pairing codes. */
export function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a, 'utf8')
  const y = Buffer.from(b, 'utf8')
  if (x.length !== y.length) {
    timingSafeEqual(x, x)
    return false
  }
  return timingSafeEqual(x, y)
}

export const sha256 = (value: string): string => createHash('sha256').update(value).digest('hex')

/**
 * A URL-safe random token, 256 bits. The first character is forced alphanumeric: a token starting
 * with `-` is read as a flag on a command line (seen with vLLM's --api-key).
 */
export function generateToken(prefix = '', bytes = 32): string {
  const alphanumeric = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  const raw = randomBytes(bytes)
  const token = raw.toString('base64url')
  return prefix + alphanumeric[raw[0]! % alphanumeric.length]! + token.slice(1)
}

/** A short code a person can read off a log and retype. No 0/O, 1/I/L. */
export function generatePairingCode(): string {
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
  const chars = Array.from(randomBytes(12), (byte) => alphabet[byte % alphabet.length])
  return `${chars.slice(0, 4).join('')}-${chars.slice(4, 8).join('')}-${chars.slice(8, 12).join('')}`
}
