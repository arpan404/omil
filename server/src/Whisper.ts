import { Effect } from "effect"
import { mkdtemp, rm, readFile, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { modelSpec, VAD_MODEL, type ServerConfig } from "./Config"
import { AUDIO_PROFILES, type AudioSensitivity } from "./AudioSensitivity"
import { ensureModel, ModelError } from "./Models"
import { preprocessWav } from "./AudioPreprocessor"

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
  sensitivity: AudioSensitivity = "balanced",
): Effect.Effect<Transcript, ModelError, never> =>
  Effect.gen(function* () {
    const selected = modelId ?? cfg.whisperModelId
    const whisperLanguage = normalizeWhisperLanguage(language)
    if (!supportsWhisperLanguage(selected, whisperLanguage)) {
      return yield* Effect.fail(new ModelError("Distil-Whisper large-v3 supports English only. Choose a multilingual Whisper model for this language."))
    }
    const profile = AUDIO_PROFILES[sensitivity]
    const prepared = yield* Effect.promise(() => readFile(audioPath).then((wav) => preprocessWav(wav, sensitivity)))
    if (prepared.silent) return { text: "", segments: [], model: selected }
    const model = yield* ensureModel(cfg, selected)
    const vadModel = yield* ensureModel(cfg, VAD_MODEL.id)
    const dir = yield* Effect.promise(() => mkdtemp(path.join(tmpdir(), "omil-whisper-")))
    let proc: Bun.Subprocess | null = null
    try {
      const base = path.join(dir, "out")
      const input = path.join(dir, "input.wav")
      yield* Effect.promise(() => writeFile(input, prepared.wav))
      const child = Bun.spawn(
        [cfg.whisperBin, "-m", model, "-f", input, "-l", whisperLanguage,
          "--vad", "--vad-model", vadModel,
          "--vad-threshold", String(profile.vadThreshold),
          "--vad-min-speech-duration-ms", String(profile.minSpeechMs),
          "--vad-min-silence-duration-ms", String(profile.minSilenceMs),
          "--vad-speech-pad-ms", String(profile.speechPadMs),
          "-oj", "-of", base, "-np"],
        { stdout: "ignore", stderr: "pipe" },
      )
      proc = child
      activeProcesses.add(child)
      activeModels.set(selected, (activeModels.get(selected) ?? 0) + 1)
      const stderrPromise = child.stderr && typeof child.stderr !== "number"
        ? new Response(child.stderr as ReadableStream).text().catch(() => "")
        : Promise.resolve("")
      const [code, stderr] = yield* Effect.promise(async () => {
        const c = await child.exited
        const err = await stderrPromise
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

export const supportsWhisperLanguage = (modelId: string, language: string): boolean => {
  const spec = modelSpec(modelId)
  return spec?.language === undefined || normalizeWhisperLanguage(language) === spec.language
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
