// The box the server prints when it starts (and `modlight-code` prints on demand): everything
// someone needs to connect the Modlight app, readable in `docker logs` and Coolify's log view.
// Pure apart from the public-IP lookup, so every variant is tested.

type Env = Record<string, string | undefined>
export type Lang = 'en' | 'de'

export interface ConnectionInput {
  env: Env
  version: string
  /** The port the server listens on inside the container. */
  port: number
  code: { code: string; expiresAt: string } | null
  publicIp: string | null
  now?: Date
}

const RULE = '═'.repeat(72)

const TEXT = {
  en: {
    title: (v: string) => `MODLIGHT SERVER ${v} – CONNECTION`,
    address: 'Address for the Modlight app',
    domain: 'your domain',
    coolify: 'Coolify domain',
    plainHttp: 'This address is plain http. The app only accepts https here: give the service an https domain.',
    lan: 'your network only, unencrypted',
    lanUnknown: (port: string) => `http://<IP of this server>:${port}   (your network; the IP: \`hostname -I\` on the server,`,
    lanUnknown2: 'or set HOST_IP so it shows here)',
    publicIp: (ip: string) => `Public IP ${ip}: the app needs https for addresses on the internet.`,
    publicHow: (port: string) => [
      `Point a domain at this IP and let a reverse proxy (Coolify, Caddy, Traefik, nginx)`,
      `forward it to port ${port}, then enter https://<domain> in the app.`,
    ],
    code: 'Pairing code',
    valid: (minutes: number, until: string) => `valid ${minutes} min (until ${until} UTC), single use`,
    expired: 'expired: create a new one (see below)',
    paired: 'Already paired. For another Mac: Server Settings › Pair Another Mac… in a paired app,',
    paired2: 'or the command below.',
    steps: 'In the Modlight app: Add Server…, then enter the address and the pairing code.',
    newCode: (container: string) => `New pairing code: docker exec ${container} modlight-code`,
  },
  de: {
    title: (v: string) => `MODLIGHT-SERVER ${v} – VERBINDUNG`,
    address: 'Adresse für die Modlight-App',
    domain: 'deine Domain',
    coolify: 'Coolify-Domain',
    plainHttp: 'Diese Adresse ist nur http. Die App verlangt hier https: gib dem Dienst eine https-Domain.',
    lan: 'nur im eigenen Netz, unverschlüsselt',
    lanUnknown: (port: string) => `http://<IP dieses Servers>:${port}   (im eigenen Netz; die IP: \`hostname -I\` auf dem Server,`,
    lanUnknown2: 'oder HOST_IP setzen, dann steht sie hier)',
    publicIp: (ip: string) => `Öffentliche IP ${ip}: Für Adressen im Internet verlangt die App https.`,
    publicHow: (port: string) => [
      `Lass eine Domain auf diese IP zeigen und einen Reverse Proxy (Coolify, Caddy, Traefik, nginx)`,
      `auf Port ${port} weiterleiten, dann in der App https://<domain> eingeben.`,
    ],
    code: 'Kopplungscode',
    valid: (minutes: number, until: string) => `gültig ${minutes} Min. (bis ${until} UTC), nur einmal`,
    expired: 'abgelaufen: neuen erzeugen (siehe unten)',
    paired: 'Schon gekoppelt. Für einen weiteren Mac: in einer gekoppelten App Server-Einstellungen › Weiteren Mac koppeln …,',
    paired2: 'oder der Befehl unten.',
    steps: 'In der Modlight-App: Server hinzufügen …, dann Adresse und Kopplungscode eingeben.',
    newCode: (container: string) => `Neuer Kopplungscode: docker exec ${container} modlight-code`,
  },
} as const

export function language(env: Env): Lang {
  const chosen = (env.MODLIGHT_LANG ?? env.LANG ?? '').toLowerCase()
  return chosen.startsWith('de') ? 'de' : 'en'
}

/** An address the app accepts only over https: anything but localhost and private networks. */
function isPublicHost(host: string): boolean {
  const h = host.toLowerCase().replace(/^\[|\]$/g, '')
  if (h === 'localhost' || h.endsWith('.local') || h.endsWith('.localhost')) return false
  if (/^(127|10)\./.test(h) || /^192\.168\./.test(h) || /^169\.254\./.test(h)) return false
  const m = /^172\.(\d+)\./.exec(h)
  if (m && Number(m[1]) >= 16 && Number(m[1]) <= 31) return false
  if (h === '::1' || /^f[cd]/.test(h) || h.startsWith('fe80')) return false
  return true
}

/**
 * The address the server is published under: PUBLIC_URL, else the domain Coolify gives the
 * service (SERVICE_URL_* has the scheme, SERVICE_FQDN_* in Coolify 4 does not). Several domains
 * are comma-separated; the first one counts.
 */
export function publicUrl(env: Env): { url: string; source: 'own' | 'coolify' } | null {
  const own = env.PUBLIC_URL?.trim()
  if (own) return { url: withScheme(own), source: 'own' }
  const keys = Object.keys(env).filter((k) => /^SERVICE_URL_/.test(k)).sort()
    .concat(Object.keys(env).filter((k) => /^SERVICE_FQDN_/.test(k)).sort())
  for (const key of keys) {
    const value = env[key]?.split(',')[0]?.trim()
    if (value) return { url: withScheme(value), source: 'coolify' }
  }
  return null
}

function withScheme(value: string): string {
  const url = /^https?:\/\//i.test(value) ? value : `https://${value}`
  return url.replace(/\/+$/, '')
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname
  } catch {
    return url
  }
}

export function connectionInfo(input: ConnectionInput): string[] {
  const { env, version, port, code, publicIp } = input
  const now = input.now ?? new Date()
  const t = TEXT[language(env)]
  const hostPort = env.HOST_PORT?.trim() || String(port)
  const container = env.HOSTNAME?.trim() || '<container>'
  const lines: string[] = ['', RULE, `  ${t.title(version)}`, RULE, '', `  ${t.address}`]

  const published = publicUrl(env)
  if (published) {
    lines.push(`    ${published.url}   (${published.source === 'own' ? t.domain : t.coolify})`)
    if (published.url.startsWith('http://') && isPublicHost(hostOf(published.url))) lines.push(`    ${t.plainHttp}`)
  }
  const hostIp = env.HOST_IP?.trim()
  if (hostIp) {
    lines.push(`    http://${hostIp.includes(':') ? `[${hostIp}]` : hostIp}:${hostPort}   (${t.lan})`)
  } else if (!published) {
    lines.push(`    ${t.lanUnknown(hostPort)}`, `    ${t.lanUnknown2}`)
  }
  const httpsPublished = published?.url.startsWith('https://') ?? false
  if (publicIp && !httpsPublished) {
    lines.push('', `    ${t.publicIp(publicIp)}`, ...t.publicHow(String(port)).map((l) => `    ${l}`))
  }

  lines.push('', `  ${t.code}`)
  if (code) {
    const expires = new Date(code.expiresAt)
    const minutes = Math.max(0, Math.round((expires.getTime() - now.getTime()) / 60_000))
    const until = expires.toISOString().slice(11, 16)
    lines.push(`    ${code.code}      ${minutes > 0 ? t.valid(minutes, until) : t.expired}`)
  } else {
    lines.push(`    ${t.paired}`, `    ${t.paired2}`)
  }

  lines.push('', `  ${t.steps}`, `  ${t.newCode(container)}`, RULE, '')
  return lines
}

/** The server's public IP, from a plain-text echo service. Null when off, slow or unreachable. */
export async function lookupPublicIp(env: Env, fetchImpl: typeof fetch = fetch, timeoutMs = 3000): Promise<string | null> {
  if (env.PUBLIC_IP_LOOKUP === 'false') return null
  try {
    const response = await fetchImpl('https://api.ipify.org', { signal: AbortSignal.timeout(timeoutMs) })
    if (!response.ok) return null
    const ip = (await response.text()).trim()
    return /^[0-9a-f.:]{3,45}$/i.test(ip) ? ip : null
  } catch {
    return null
  }
}
