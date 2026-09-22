import { describe, expect, test } from "bun:test"
import { Effect } from "effect"
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { ModelRuntimeLifecycle } from "../src/ModelRuntime"
import { checkModelReady, deleteModel } from "../src/Models"
import type { ServerConfig } from "../src/Config"

describe("model runtime lifecycle", () => {
  test("defers unload until the active inference releases its lease", () => {
    const runtime = new ModelRuntimeLifecycle()
    const load = runtime.beginLoading("qwen-a")

    expect(runtime.markReady(load)).toBe(true)
    expect(runtime.beginUse("qwen-a")).toBe(true)
    expect(runtime.requestUnload()).toBe(false)
    expect(runtime.snapshot()).toMatchObject({
      state: "inUse",
      modelId: "qwen-a",
      activeUses: 1,
      unloadPending: true,
    })

    expect(runtime.endUse("qwen-a")).toBe(true)
    expect(runtime.snapshot().state).toBe("unloading")
    runtime.markUnloaded()
    expect(runtime.snapshot()).toEqual({
      state: "unloaded",
      modelId: null,
      activeUses: 0,
      unloadPending: false,
      error: null,
    })
  })

  test("ignores a stale completion after a newer model starts loading", () => {
    const runtime = new ModelRuntimeLifecycle()
    const first = runtime.beginLoading("qwen-a")
    const second = runtime.beginLoading("qwen-b")

    expect(runtime.markReady(first)).toBe(false)
    expect(runtime.snapshot()).toMatchObject({ state: "loading", modelId: "qwen-b" })
    expect(runtime.markReady(second)).toBe(true)
    expect(runtime.snapshot()).toMatchObject({ state: "ready", modelId: "qwen-b" })
  })

  test("a new use cancels a pending idle unload", () => {
    const runtime = new ModelRuntimeLifecycle()
    const load = runtime.beginLoading("qwen-a")
    runtime.markReady(load)

    expect(runtime.requestUnload()).toBe(true)
    expect(runtime.beginUse("qwen-a")).toBe(false)
    runtime.cancelUnload()
    expect(runtime.beginUse("qwen-a")).toBe(true)
    expect(runtime.snapshot()).toMatchObject({ state: "inUse", unloadPending: false })
  })
})

describe("model file lifecycle", () => {
  test("an unpinned partial file is not reported as downloaded", async () => {
    const dataDir = await mkdtemp(path.join(tmpdir(), "omil-model-state-"))
    const cfg: ServerConfig = {
      host: "127.0.0.1",
      port: 3217,
      dataDir,
      whisperBin: "whisper-cli",
      llamaBin: "llama-server",
      llamaPort: 3218,
      whisperModelId: "whisper-large-v3",
      llmModelId: "qwen3-4b-instruct",
    }
    try {
      const dir = path.join(dataDir, "models")
      await mkdir(dir, { recursive: true })
      await writeFile(path.join(dir, "ggml-large-v3.bin"), new Uint8Array([1, 2, 3]))

      expect(await Effect.runPromise(checkModelReady(cfg, "whisper-large-v3"))).toBe(false)
    } finally {
      await rm(dataDir, { recursive: true, force: true })
    }
  })

  test("deleting a model removes its file and readiness state", async () => {
    const dataDir = await mkdtemp(path.join(tmpdir(), "omil-model-delete-"))
    const cfg: ServerConfig = {
      host: "127.0.0.1",
      port: 3217,
      dataDir,
      whisperBin: "whisper-cli",
      llamaBin: "llama-server",
      llamaPort: 3218,
      whisperModelId: "whisper-large-v3-turbo",
      llmModelId: "qwen3-4b-instruct",
    }
    try {
      const dir = path.join(dataDir, "models")
      await mkdir(dir, { recursive: true })
      await writeFile(path.join(dir, "ggml-large-v3-turbo.bin"), new Uint8Array([1, 2, 3]))

      expect(await Effect.runPromise(deleteModel(cfg, "whisper-large-v3-turbo"))).toBe(true)
      expect(await Bun.file(path.join(dir, "ggml-large-v3-turbo.bin")).exists()).toBe(false)
      expect(await Effect.runPromise(checkModelReady(cfg, "whisper-large-v3-turbo"))).toBe(false)
    } finally {
      await rm(dataDir, { recursive: true, force: true })
    }
  })
})
