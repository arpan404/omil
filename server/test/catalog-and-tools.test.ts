import { describe, expect, test } from "bun:test"
import { Effect } from "effect"
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { DEFAULT_LLM, DEFAULT_WHISPER, MODELS, type ServerConfig } from "../src/Config"
import { checkBinaries, verifiedSha256 } from "../src/Models"

describe("curated Mac models", () => {
  test("offers distinct transcription and cleanup models with pinned downloads", () => {
    expect(MODELS.filter((model) => model.kind === "whisper").map((model) => model.id))
      .toEqual(["whisper-base-q8", "whisper-small-q8", "whisper-medium-q8", "whisper-large-v3-turbo-q8", "whisper-large-v3-q5", "whisper-distil-large-v3"])
    expect(MODELS.filter((model) => model.kind === "llm").map((model) => model.id))
      .toEqual(["qwen3.5-0.8b", "qwen3.5-2b", "qwen3.5-4b", "qwen3.5-9b", "llama-3.1-8b-instruct", "gemma-3-4b-it"])
    expect(new Set(MODELS.map((model) => model.id)).size).toBe(MODELS.length)
    expect(new Set(MODELS.map((model) => model.filename)).size).toBe(MODELS.length)
    expect(MODELS.every((model) => model.expectedSha256 && model.expectedBytes)).toBe(true)
    expect(DEFAULT_WHISPER).toBe("whisper-large-v3-turbo-q8")
    expect(DEFAULT_LLM).toBe("qwen3.5-2b")
  })
})

describe("tool and model verification", () => {
  test("checks executable presence without launching inference tools", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "omil-tools-"))
    const marker = path.join(dir, "launched")
    const executable = path.join(dir, "whisper-cli")
    try {
      await writeFile(executable, `#!/bin/sh\ntouch '${marker}'\n`)
      await chmod(executable, 0o755)
      const cfg = { whisperBin: executable, llamaBin: path.join(dir, "missing") } as ServerConfig
      expect(await Effect.runPromise(checkBinaries(cfg))).toEqual({ whisper: true, llama: false })
      expect(await Bun.file(marker).exists()).toBe(false)
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  test("rechecks a model when its contents change at the same size", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "omil-hash-"))
    const file = path.join(dir, "model.gguf")
    try {
      await writeFile(file, "one")
      const first = await verifiedSha256(file)
      expect(await verifiedSha256(file)).toBe(first)
      await writeFile(file, "two")
      expect(await verifiedSha256(file)).not.toBe(first)
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })
})
