import { Effect } from "effect"
import { randomBytes } from "node:crypto"
import { mkdir, readFile, writeFile, chmod } from "node:fs/promises"
import path from "node:path"

/**
 * LAN bearer-token auth. Token is generated on first run, stored 0600 in the
 * data dir, and must be entered once in each Swift client (Mac Settings,
 * iOS Settings). No accounts, no third parties.
 */

export const TOKEN_FILE = "omil-token"

export const loadOrCreateToken = (dataDir: string): Effect.Effect<string, never, never> =>
  Effect.promise(async () => {
    await mkdir(dataDir, { recursive: true })
    const file = path.join(dataDir, TOKEN_FILE)
    try {
      const t = (await readFile(file, "utf8")).trim()
      if (t.length >= 16) return t
    } catch {
      // fall through to generation
    }
    const token = randomBytes(24).toString("base64url")
    await writeFile(file, token, { mode: 0o600 })
    await chmod(file, 0o600)
    console.log(`\nNew Omil server token (enter it in the Mac/iOS app Settings):\n\n    ${token}\n`)
    return token
  })

export const checkAuth = (
  headers: Record<string, string | string[] | undefined>,
  token: string,
): boolean => {
  const raw = headers["authorization"]
  const h = Array.isArray(raw) ? raw[0] ?? "" : raw ?? ""
  if (!h.toLowerCase().startsWith("bearer ")) return false
  const presented = h.slice(7).trim()
  return (
    presented.length === token.length &&
    presented.length > 0 &&
    timingSafeEqualStr(presented, token)
  )
}

function timingSafeEqualStr(a: string, b: string): boolean {
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}
