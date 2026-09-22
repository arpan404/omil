import { Effect } from "effect"
import { mkdtemp, rm, readFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import type { ServerConfig } from "./Config"
import { ensureModel, ModelError } from "./Models"

export interface TranscriptSegment {
  readonly start: number
  readonly end: number
  readonly text: string
}

export interface Transcript {
  readonly text: string
  readonly segments: ReadonlyArray<TranscriptSegment>
  readonly model: string
}

const activeProcesses = new Set<Bun.Subprocess>()
const activeModels = new Map<string, number>()

export const whisperMemoryState = (modelId: string): "inUse" | "unloaded" =>
  (activeModels.get(modelId) ?? 0) > 0 ? "inUse" : "unloaded"

export const stopWhisper = (): void => {
  for (const process of activeProcesses) {
    try { process.kill() } catch { /* already gone */ }
  }
  activeProcesses.clear()
  activeModels.clear()
}

/** Whisper transcription via the whisper.cpp sidecar. Batch per utterance. */
export const transcribeFile = (
  cfg: ServerConfig,
  audioPath: string,
  language = "en",
  modelId?: string,
): Effect.Effect<Transcript, ModelError, never> =>
  Effect.gen(function* () {
    const selected = modelId ?? cfg.whisperModelId
    const whisperLanguage = normalizeWhisperLanguage(language)
    const model = yield* ensureModel(cfg, selected)
    const dir = yield* Effect.promise(() => mkdtemp(path.join(tmpdir(), "omil-whisper-")))
    let proc: Bun.Subprocess | null = null
    try {
      const base = path.join(dir, "out")
      const child = Bun.spawn(
        [cfg.whisperBin, "-m", model, "-f", audioPath, "-l", whisperLanguage, "-oj", "-of", base, "-np"],
        { stdout: "pipe", stderr: "pipe" },
      )
      proc = child
      activeProcesses.add(child)
      activeModels.set(selected, (activeModels.get(selected) ?? 0) + 1)
      const [code, stderr] = yield* Effect.promise(async () => {
        const c = await child.exited
        const err = child.stderr && typeof child.stderr !== "number"
          ? await new Response(child.stderr as ReadableStream).text().catch(() => "")
          : ""
        return [c, err] as const
      })
      if (code !== 0) {
        return yield* Effect.fail(new ModelError(`whisper-cli exited ${code}: ${String(stderr).slice(-2000)}`))
      }
      const raw = yield* Effect.promise(() => readFile(`${base}.json`, "utf8").catch(() => ""))
      if (!raw) {
        const detail = String(stderr).trim().slice(-1200)
        return yield* Effect.fail(new ModelError(
          `whisper-cli produced no JSON output${detail ? `: ${detail}` : ""}`,
        ))
      }
      return parseWhisperJson(raw, selected)
    } finally {
      if (proc) {
        activeProcesses.delete(proc)
        const remaining = Math.max(0, (activeModels.get(selected) ?? 1) - 1)
        if (remaining === 0) activeModels.delete(selected)
        else activeModels.set(selected, remaining)
        if (proc.exitCode === null) {
          try { proc.kill() } catch { /* already gone */ }
        }
      }
      yield* Effect.promise(() => rm(dir, { recursive: true, force: true }))
    }
  })

export const normalizeWhisperLanguage = (language: string): string => {
  const normalized = language.trim().toLowerCase()
  if (!normalized || normalized === "auto") return normalized || "en"
  return normalized.split(/[-_]/, 1)[0] || "en"
}

const tsToSec = (s: string): number => {
  // "00:00:02,400"
  const m = s.match(/(\d+):(\d+):([\d.,]+)/)
  if (!m) return 0
  return Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3].replace(",", "."))
}

export function parseWhisperJson(raw: string, model: string): Transcript {
  const json = JSON.parse(raw) as {
    transcription?: Array<{ timestamps?: { from?: string; to?: string }; text?: string }>
  }
  const segments: TranscriptSegment[] = (json.transcription ?? []).map((t) => ({
    start: tsToSec(t.timestamps?.from ?? "00:00:00,000"),
    end: tsToSec(t.timestamps?.to ?? "00:00:00,000"),
    text: (t.text ?? "").trim(),
  }))
  return { text: segments.map((s) => s.text).join(" ").trim(), segments, model }
}
