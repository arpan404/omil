import { Effect } from "effect"
import { mkdtemp, rm, readFile, writeFile } from "node:fs/promises"
import { availableParallelism, tmpdir } from "node:os"
import path from "node:path"
import { modelSpec, VAD_MODEL, type ServerConfig } from "./Config"
import { AUDIO_PROFILES, type AudioProfile, type AudioSensitivity } from "./AudioSensitivity"
import { ensureModel, ModelError, resolveBinary, toModelError } from "./Models"
import type { ModelRuntimeState } from "./ModelRuntime"
import { preprocessWav } from "./AudioPreprocessor"
import { ManagedSidecar, type SidecarSnapshot } from "./Sidecar"

interface TranscriptSegment {
  readonly start: number
  readonly end: number
  readonly text: string
}

interface Transcript {
  readonly text: string
  readonly segments: ReadonlyArray<TranscriptSegment>
  readonly model: string
}

/** Decoding settings shared by whisper-server requests and the whisper-cli fallback. */
const BEAM_SIZE = 5
const BEST_OF = 5

const whisperServer = new ManagedSidecar({ name: "whisper-server", readyTimeoutMs: 120_000, captureStderr: true })

const cliProcesses = new Set<Bun.Subprocess>()
const cliModels = new Map<string, number>()
let lastRequestedModel: string | null = null
/** After whisper-server fails to start, transcribe with whisper-cli for a while instead of retrying on every request. */
let serverRetryAt = 0
const SERVER_RETRY_MS = 60_000

let cachedThreads: number | null = null
/** Performance-core count: efficiency cores slow whisper.cpp's CPU work down. */
const whisperThreads = (): number => {
  if (cachedThreads !== null) return cachedThreads
  let count = 0
  try {
    const out = Bun.spawnSync(["sysctl", "-n", "hw.perflevel0.physicalcpu"], { stderr: "ignore" })
    count = Number(out.stdout.toString().trim())
  } catch { /* not macOS */ }
  cachedThreads = Number.isInteger(count) && count > 0 ? count : Math.max(1, availableParallelism())
  return cachedThreads
}

/** A failed whisper-server start is not a user-facing failure: whisper-cli still transcribes. */
export const whisperMemoryState = (modelId: string): ModelRuntimeState => {
  if ((cliModels.get(modelId) ?? 0) > 0) return "inUse"
  const state = whisperServer.memoryState(modelId)
  return state === "failed" ? "unloaded" : state
}

export const whisperRuntime = (): SidecarSnapshot => whisperServer.snapshot()

/** The model the next dictation most likely uses: the loaded one, else the last requested. */
export const likelyWhisperModel = (): string | null => whisperServer.live() ?? lastRequestedModel

export const unloadWhisper = (): Promise<boolean> => whisperServer.unload()

export const stopWhisper = (): void => {
  whisperServer.stop()
  for (const process of cliProcesses) {
    try { process.kill() } catch { /* already gone */ }
  }
  cliProcesses.clear()
  cliModels.clear()
}

const portIsFree = (port: number): boolean => {
  try {
    const probe = Bun.listen({ hostname: "127.0.0.1", port, socket: { data() {} } })
    probe.stop(true)
    return true
  } catch {
    return false
  }
}

const serverLaunch = (cfg: ServerConfig, modelId: string) => async () => {
  const bin = await resolveBinary(cfg.whisperServerBin)
  if (!bin) throw new ModelError(`${cfg.whisperServerBin} is not installed`)
  const port = cfg.whisperPort
  if (!Number.isInteger(port) || port <= 0 || port > 65_535 || port === cfg.port || port === cfg.llamaPort) {
    throw new ModelError(`whisper-server port ${port} conflicts with the API or cleanup port`)
  }
  if (!portIsFree(port)) throw new ModelError(`whisper-server port ${port} is already in use`)
  const [model, vadModel] = await Promise.all([
    Effect.runPromise(ensureModel(cfg, modelId)),
    Effect.runPromise(ensureModel(cfg, VAD_MODEL.id)),
  ])
  const profile = AUDIO_PROFILES.balanced
  return {
    port,
    argv: [bin, "-m", model, "--host", "127.0.0.1", "--port", String(port),
      "-t", String(whisperThreads()), "-bs", String(BEAM_SIZE), "-bo", String(BEST_OF),
      "--vad", "--vad-model", vadModel, ...vadArgs(profile)],
  }
}

const vadArgs = (profile: AudioProfile): string[] => [
  "--vad-threshold", String(profile.vadThreshold),
  "--vad-min-speech-duration-ms", String(profile.minSpeechMs),
  "--vad-min-silence-duration-ms", String(profile.minSilenceMs),
  "--vad-speech-pad-ms", String(profile.speechPadMs),
]

const serverAvailable = async (cfg: ServerConfig): Promise<boolean> =>
  Date.now() >= serverRetryAt && await resolveBinary(cfg.whisperServerBin) !== null

/** Loads whisper-server for a model ahead of the first dictation. Safe to call repeatedly. */
export const warmWhisper = async (cfg: ServerConfig, modelId: string): Promise<void> => {
  if (!await serverAvailable(cfg)) return
  let lease
  try {
    lease = await whisperServer.acquire(modelId, serverLaunch(cfg, modelId))
  } catch (error) {
    serverRetryAt = Date.now() + SERVER_RETRY_MS
    throw error
  }
  lease.release()
}

/** Whisper transcription of one utterance held in memory. */
export const transcribeAudio = (
  cfg: ServerConfig,
  wav: Buffer,
  language = "en",
  modelId?: string,
  sensitivity: AudioSensitivity = "balanced",
): Effect.Effect<Transcript, ModelError, never> =>
  Effect.gen(function* () {
    const selected = modelId ?? cfg.whisperModelId
    lastRequestedModel = selected
    const whisperLanguage = normalizeWhisperLanguage(language)
    if (!supportsWhisperLanguage(selected, whisperLanguage)) {
      return yield* Effect.fail(new ModelError("Distil-Whisper large-v3 supports English only. Choose a multilingual Whisper model for this language."))
    }
    const prepared = preprocessWav(wav, sensitivity)
    if (prepared.silent) return { text: "", segments: [], model: selected }
    const model = yield* ensureModel(cfg, selected)
    const vadModel = yield* ensureModel(cfg, VAD_MODEL.id)
    const profile = AUDIO_PROFILES[sensitivity]
    if (yield* Effect.promise(() => serverAvailable(cfg))) {
      const viaServer = yield* Effect.either(Effect.tryPromise({
        try: () => transcribeWithServer(cfg, prepared.wav, whisperLanguage, selected, profile),
        catch: toModelError,
      }))
      if (viaServer._tag === "Right") return viaServer.right
      console.error(`whisper-server unavailable, using whisper-cli: ${viaServer.left.reason}`)
    }
    return yield* transcribeWithCli(cfg, prepared.wav, whisperLanguage, selected, model, vadModel, profile)
  })

const transcribeWithServer = async (
  cfg: ServerConfig,
  wav: Buffer,
  language: string,
  modelId: string,
  profile: AudioProfile,
): Promise<Transcript> => {
  let lease
  try {
    lease = await whisperServer.acquire(modelId, serverLaunch(cfg, modelId))
  } catch (error) {
    serverRetryAt = Date.now() + SERVER_RETRY_MS
    throw error
  }
  try {
    const form = new FormData()
    form.append("file", new Blob([wav as Uint8Array<ArrayBuffer>], { type: "audio/wav" }), "audio.wav")
    for (const [key, value] of Object.entries(serverRequestFields(language, profile))) form.append(key, value)
    let response: Response
    try {
      response = await fetch(`${lease.handle.baseUrl}/inference`, {
        method: "POST",
        body: form,
        signal: AbortSignal.timeout(600_000),
      })
    } catch (error) {
      await whisperServer.verifyAfterFailure()
      throw new ModelError(`whisper-server request failed: ${String(error)}`)
    }
    const body = await response.text()
    if (!response.ok) throw new ModelError(`whisper-server HTTP ${response.status}: ${body.slice(0, 500)}`)
    return parseWhisperServerJson(body, modelId)
  } finally {
    lease.release()
  }
}

export const serverRequestFields = (language: string, profile: AudioProfile): Record<string, string> => ({
  response_format: "verbose_json",
  language,
  temperature: "0",
  beam_size: String(BEAM_SIZE),
  best_of: String(BEST_OF),
  // Token timestamps would make the server wrap segments at 60 characters.
  token_timestamps: "false",
  no_language_probabilities: "true",
  vad: "true",
  vad_threshold: String(profile.vadThreshold),
  vad_min_speech_duration_ms: String(profile.minSpeechMs),
  vad_min_silence_duration_ms: String(profile.minSilenceMs),
  vad_speech_pad_ms: String(profile.speechPadMs),
})

const transcribeWithCli = (
  cfg: ServerConfig,
  wav: Buffer,
  language: string,
  selected: string,
  model: string,
  vadModel: string,
  profile: AudioProfile,
): Effect.Effect<Transcript, ModelError, never> =>
  Effect.gen(function* () {
    const dir = yield* Effect.promise(() => mkdtemp(path.join(tmpdir(), "omil-whisper-")))
    let proc: Bun.Subprocess | null = null
    try {
      const base = path.join(dir, "out")
      const input = path.join(dir, "input.wav")
      yield* Effect.promise(() => writeFile(input, wav))
      const child = Bun.spawn(
        [cfg.whisperBin, "-m", model, "-f", input, "-l", language,
          "--vad", "--vad-model", vadModel, ...vadArgs(profile),
          "-oj", "-of", base, "-np"],
        { stdout: "ignore", stderr: "pipe" },
      )
      proc = child
      cliProcesses.add(child)
      cliModels.set(selected, (cliModels.get(selected) ?? 0) + 1)
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
        cliProcesses.delete(proc)
        const remaining = Math.max(0, (cliModels.get(selected) ?? 1) - 1)
        if (remaining === 0) cliModels.delete(selected)
        else cliModels.set(selected, remaining)
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

/** Mirrors whisper-cli's `to_timestamp(t, comma = true)` for a time in 10 ms units. */
const centisecondsToTimestamp = (centiseconds: number): string => {
  let ms = centiseconds * 10
  const hours = Math.floor(ms / 3_600_000)
  ms -= hours * 3_600_000
  const minutes = Math.floor(ms / 60_000)
  ms -= minutes * 60_000
  const seconds = Math.floor(ms / 1_000)
  ms -= seconds * 1_000
  const pad = (value: number, width = 2) => String(value).padStart(width, "0")
  return `${pad(hours)}:${pad(minutes)}:${pad(seconds)},${pad(ms, 3)}`
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

/**
 * whisper-server's verbose_json reports seconds as `t * 0.01`. Converting back
 * through the CLI timestamp format keeps /v1/transcribe numbers identical to
 * the whisper-cli path.
 */
export function parseWhisperServerJson(raw: string, model: string): Transcript {
  const json = JSON.parse(raw) as {
    segments?: Array<{ start?: number; end?: number; text?: string }>
  }
  const seconds = (value: number | undefined) =>
    tsToSec(centisecondsToTimestamp(Math.max(0, Math.round((value ?? 0) * 100))))
  const segments: TranscriptSegment[] = (json.segments ?? []).map((segment) => ({
    start: seconds(segment.start),
    end: seconds(segment.end),
    text: (segment.text ?? "").trim(),
  }))
  return { text: segments.map((s) => s.text).join(" ").trim(), segments, model }
}
