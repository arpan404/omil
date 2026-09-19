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

/** Whisper transcription via the whisper.cpp sidecar. Batch per utterance. */
export const transcribeFile = (
  cfg: ServerConfig,
  audioPath: string,
  language = "en",
  modelId?: string,
): Effect.Effect<Transcript, ModelError, never> =>
  Effect.gen(function* () {
    const selected = modelId ?? cfg.whisperModelId
    const model = yield* ensureModel(cfg, selected)
    const dir = yield* Effect.promise(() => mkdtemp(path.join(tmpdir(), "omil-whisper-")))
    try {
      const base = path.join(dir, "out")
      const proc = Bun.spawn(
        [cfg.whisperBin, "-m", model, "-f", audioPath, "-l", language, "-oj", "-of", base, "-np"],
        { stdout: "pipe", stderr: "pipe" },
      )
      const [code, stderr] = yield* Effect.promise(async () => {
        const c = await proc.exited
        const err = proc.stderr && typeof proc.stderr !== "number"
          ? await new Response(proc.stderr as ReadableStream).text().catch(() => "")
          : ""
        return [c, err] as const
      })
      if (code !== 0) {
        return yield* Effect.fail(new ModelError(`whisper-cli exited ${code}: ${String(stderr).slice(-2000)}`))
      }
      const raw = yield* Effect.promise(() => readFile(`${base}.json`, "utf8").catch(() => ""))
      if (!raw) return yield* Effect.fail(new ModelError("whisper-cli produced no JSON output"))
      return parseWhisperJson(raw, selected)
    } finally {
      yield* Effect.promise(() => rm(dir, { recursive: true, force: true }))
    }
  })

const tsToSec = (s: string): number => {
  // "00:00:02,400"
  const m = s.match(/(\d+):(\d+):([\d.]+)/)
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
