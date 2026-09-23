import { expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { loadPrompt, resolveCleanupPrompt, savePrompt } from "../src/ServerState"

test("request prompt overrides the stored prompt only for that cleanup", async () => {
  const dataDir = await mkdtemp(path.join(tmpdir(), "omil-prompt-test-"))
  const stored = "Use this stored system prompt for ordinary cleanup requests."
  const request = "Use this request-specific system prompt for this cleanup only."
  try {
    await savePrompt(dataDir, stored)
    expect(await resolveCleanupPrompt(dataDir, request)).toEqual({ text: request, isCustom: true })
    expect(await resolveCleanupPrompt(dataDir)).toEqual({ text: stored, isCustom: true })
    expect((await loadPrompt(dataDir)).text).toBe(stored)
  } finally {
    await rm(dataDir, { recursive: true, force: true })
  }
})
