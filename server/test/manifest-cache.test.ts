import { describe, expect, test } from "bun:test"
import { Effect } from "effect"
import { chmod, mkdir, mkdtemp, rm, truncate, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { modelSpec, VAD_MODEL, type ServerConfig } from "../src/Config"
import { checkModelReady, deleteModel, resolveBinary } from "../src/Models"

const configFor = (dataDir: string): ServerConfig => ({
  host: "127.0.0.1", port: 3217, dataDir,
  whisperBin: "whisper-cli", whisperServerBin: "whisper-server", llamaBin: "llama-server",
  llamaPort: 3218, whisperPort: 3219,
  whisperModelId: "whisper-large-v3-turbo-q8", llmModelId: "qwen3.5-2b",
})

describe("model manifest cache", () => {
  test("sees pins written by this process and edits made on disk", async () => {
    const dataDir = await mkdtemp(path.join(tmpdir(), "omil-manifest-"))
    const cfg = configFor(dataDir)
    const models = path.join(dataDir, "models")
    const weight = path.join(models, VAD_MODEL.filename)
    const manifest = path.join(models, "manifest.local.json")
    try {
      await mkdir(models, { recursive: true })
      // Right size, no pin: a pinned-checksum model is not ready until verified.
      await writeFile(weight, new Uint8Array(VAD_MODEL.expectedBytes!))
      expect(await Effect.runPromise(checkModelReady(cfg, VAD_MODEL.id))).toBe(false)

      await writeFile(manifest, JSON.stringify({
        [VAD_MODEL.filename]: { sha256: VAD_MODEL.expectedSha256, bytes: VAD_MODEL.expectedBytes, url: VAD_MODEL.url },
      }))
      expect(await Effect.runPromise(checkModelReady(cfg, VAD_MODEL.id))).toBe(true)

      await writeFile(manifest, "{}")
      expect(await Effect.runPromise(checkModelReady(cfg, VAD_MODEL.id))).toBe(false)

      await rm(manifest)
      expect(await Effect.runPromise(checkModelReady(cfg, VAD_MODEL.id))).toBe(false)
    } finally {
      await rm(dataDir, { recursive: true, force: true })
    }
  })

  test("drops a deleted model's pin from the cached manifest", async () => {
    const dataDir = await mkdtemp(path.join(tmpdir(), "omil-manifest-delete-"))
    const cfg = configFor(dataDir)
    const models = path.join(dataDir, "models")
    const spec = modelSpec("whisper-base-q8")!
    const weight = path.join(models, spec.filename)
    try {
      await mkdir(models, { recursive: true })
      await writeFile(weight, "")
      await truncate(weight, spec.expectedBytes!)
      await writeFile(path.join(models, "manifest.local.json"), JSON.stringify({
        [spec.filename]: { sha256: spec.expectedSha256, bytes: spec.expectedBytes, url: spec.url },
        "other.bin": { sha256: "keep", bytes: 1, url: "https://example.test/other" },
      }))
      expect(await Effect.runPromise(checkModelReady(cfg, spec.id))).toBe(true)

      expect(await Effect.runPromise(deleteModel(cfg, spec.id))).toBe(true)
      const onDisk = await Bun.file(path.join(models, "manifest.local.json")).json()
      expect(Object.keys(onDisk)).toEqual(["other.bin"])

      await writeFile(weight, "")
      await truncate(weight, spec.expectedBytes!)
      expect(await Effect.runPromise(checkModelReady(cfg, spec.id))).toBe(false)
    } finally {
      await rm(dataDir, { recursive: true, force: true })
    }
  })
})

describe("binary resolution cache", () => {
  test("finds a newly installed tool and forgets a removed one", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "omil-bin-"))
    const tool = path.join(dir, `omil-fake-tool-${crypto.randomUUID()}`)
    const originalPath = process.env.PATH
    process.env.PATH = `${dir}${path.delimiter}${originalPath ?? ""}`
    try {
      expect(await resolveBinary(path.basename(tool))).toBeNull()
      await writeFile(tool, "#!/bin/sh\n")
      await chmod(tool, 0o755)
      expect(await resolveBinary(path.basename(tool))).toBe(tool)
      expect(await resolveBinary(path.basename(tool))).toBe(tool)
      await rm(tool)
      expect(await resolveBinary(path.basename(tool))).toBeNull()
    } finally {
      process.env.PATH = originalPath
      await rm(dir, { recursive: true, force: true })
    }
  })
})
