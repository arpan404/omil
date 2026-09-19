import { Effect } from "effect"
import { mkdir, rm } from "node:fs/promises"
import path from "node:path"
import { createHash } from "node:crypto"
import { modelSpec, type ServerConfig } from "./Config"

/**
 * Model asset management: explicit, versioned, integrity-recorded downloads.
 * Binaries (whisper.cpp, llama.cpp) come from the environment (brew);
 * weights download here on first run with size verification and
 * trust-on-first-use SHA-256 pinning (recorded in manifest.local.json,
 * verified on every later boot, removable by deleting the models dir).
 */

export class ModelError {
  readonly _tag = "ModelError"
  constructor(readonly reason: string) {}
}

export const modelsDir = (cfg: ServerConfig) => path.join(cfg.dataDir, "models")
export const modelPath = (cfg: ServerConfig, id: string) => {
  const spec = modelSpec(id)
  if (!spec) throw new ModelError(`unknown model ${id}`)
  return path.join(modelsDir(cfg), spec.filename)
}

export const checkBinaries = (cfg: ServerConfig): Effect.Effect<Record<string, boolean>, never, never> =>
  Effect.promise(async () => {
    const out: Record<string, boolean> = {}
    for (const [name, bin] of [["whisper", cfg.whisperBin], ["llama", cfg.llamaBin]] as const) {
      try {
        const proc = Bun.spawn([bin, "--version"], { stdout: "pipe", stderr: "pipe" })
        await proc.exited
        out[name] = proc.exitCode === 0
      } catch {
        out[name] = false
      }
    }
    return out
  })

const sha256File = async (file: string): Promise<string> => {
  const h = createHash("sha256")
  const f = Bun.file(file)
  const stream = f.stream()
  for await (const chunk of stream as unknown as AsyncIterable<Uint8Array>) h.update(chunk)
  return h.digest("hex")
}

interface LocalManifest { [filename: string]: { sha256: string; bytes: number; url: string } }

const readManifest = async (cfg: ServerConfig): Promise<LocalManifest> => {
  try {
    return await Bun.file(path.join(modelsDir(cfg), "manifest.local.json")).json()
  } catch {
    return {}
  }
}

const writeManifest = async (cfg: ServerConfig, m: LocalManifest) => {
  await Bun.write(path.join(modelsDir(cfg), "manifest.local.json"), JSON.stringify(m, null, 2))
}

/** Non-mutating readiness probe for /v1/health (never downloads). */
export const checkModelReady = (
  cfg: ServerConfig,
  id: string,
): Effect.Effect<boolean, never, never> =>
  Effect.promise(async () => {
    const spec = modelSpec(id)
    if (!spec) return false
    try {
      const f = Bun.file(modelPath(cfg, id))
      if (!(await f.exists())) return false
      const manifest = await readManifest(cfg).catch(() => ({} as LocalManifest))
      const pinned = manifest[spec.filename]
      if (pinned) {
        if (f.size !== pinned.bytes) return false
        return (await sha256File(modelPath(cfg, id))) === pinned.sha256
      }
      if (spec.expectedBytes !== null) return sizeMatches(spec.expectedBytes, f.size)
      return true // unpinned catalog entry: presence is readiness; verified on use
    } catch {
      return false
    }
  })

/** Ensure a weight file exists and matches its pinned (or expected) identity. */
export const ensureModel = (
  cfg: ServerConfig,
  id: string,
): Effect.Effect<string, ModelError, never> =>
  Effect.gen(function* () {
    const spec = modelSpec(id)
    if (!spec) return yield* Effect.fail(new ModelError(`unknown model ${id}`))
    yield* Effect.promise(() => mkdir(modelsDir(cfg), { recursive: true }))
    const dest = modelPath(cfg, id)
    const manifest = yield* Effect.promise(() => readManifest(cfg))
    const pinned = manifest[spec.filename]

    const file = Bun.file(dest)
    if (yield* Effect.promise(() => file.exists())) {
      const size = file.size
      if (pinned) {
        const actual = yield* Effect.promise(() => sha256File(dest))
        if (actual !== pinned.sha256) {
          return yield* Effect.fail(
            new ModelError(`${spec.filename}: checksum mismatch (expected ${pinned.sha256.slice(0, 12)}…, got ${actual.slice(0, 12)}…). Delete it to re-download.`),
          )
        }
        return dest
      }
      // No pin yet: a size mismatch means a stale partial (e.g. killed
      // download) — remove it and download fresh below.
      const sizeOk = spec.expectedBytes !== null
        ? sizeMatches(spec.expectedBytes, size)
        : true // unpinned: pin whatever is here (TOFU), server re-verifies on use
      if (!sizeOk) {
        console.log(`${spec.filename}: removing stale partial (${(size / 1e6).toFixed(1)} MB)`)
        yield* Effect.promise(() => rm(dest, { force: true }))
      } else {
        const sha = yield* Effect.promise(() => sha256File(dest))
        manifest[spec.filename] = { sha256: sha, bytes: size, url: spec.url }
        yield* Effect.promise(() => writeManifest(cfg, manifest))
        console.log(`pinned ${spec.filename} sha256=${sha.slice(0, 16)}… (trust-on-first-use)`)
        return dest
      }
    }

    // Download.
    console.log(`downloading ${spec.id}${spec.expectedBytes !== null ? ` (${(spec.expectedBytes / 1e9).toFixed(2)} GB)` : ""} from ${spec.url}`)
    const res = yield* Effect.promise(() => fetch(spec.url) as Promise<Response>)
    if (!res.ok || !res.body) {
      return yield* Effect.fail(new ModelError(`download failed: HTTP ${res.status}`))
    }
    const writer = file.writer()
    let received = 0
    const total = Number(res.headers.get("content-length") ?? spec.expectedBytes ?? 0)
    const reader = res.body.getReader()
    for (;;) {
      const { done, value } = yield* Effect.promise(() => reader.read() as Promise<ReadableStreamReadResult<Uint8Array>>)
      if (done) break
      writer.write(value)
      received += value.byteLength
      if (received % (64 * 1024 * 1024) < value.byteLength) {
        console.log(total > 0
          ? `  ${(received / 1e9).toFixed(2)} / ${(total / 1e9).toFixed(2)} GB`
          : `  ${(received / 1e9).toFixed(2)} GB`)
      }
    }
    writer.end()
    yield* Effect.promise(() => Promise.resolve(writer.flush()))
    const contentLength = Number(res.headers.get("content-length") ?? 0)
    if (!sizeMatches(spec.expectedBytes, received, contentLength)) {
      return yield* Effect.fail(
        new ModelError(`download incomplete: got ${received} bytes` + (spec.expectedBytes !== null ? `, expected ~${spec.expectedBytes}` : `, server reported ${contentLength}`)),
      )
    }
    const sha = yield* Effect.promise(() => sha256File(dest))
    manifest[spec.filename] = { sha256: sha, bytes: received, url: spec.url }
    yield* Effect.promise(() => writeManifest(cfg, manifest))
    console.log(`downloaded + pinned ${spec.filename} sha256=${sha.slice(0, 16)}…`)
    return dest
  })

function sizeMatches(expected: number | null, actual: number, contentLength?: number): boolean {
  if (expected !== null) return Math.abs(actual - expected) / expected < 0.05
  // Unpinned catalog entry: require byte-exact match with the download itself.
  return contentLength !== undefined && contentLength > 0 && actual === contentLength
}
