import { Effect } from "effect"
import {
  HttpRouter, HttpServerRequest, HttpServerResponse,
} from "@effect/platform"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import type { ServerConfig } from "./Config"
import { checkAuth } from "./Auth"
import {
  checkBinaries, checkModelReady, deleteModel, ensureModel, ModelError,
  modelFileLifecycle,
} from "./Models"
import { transcribeFile, whisperMemoryState } from "./Whisper"
import { parseAudioSensitivity } from "./AudioSensitivity"
import {
  acquireLlama, llamaRuntime, liveLlmModel, stopLlama, unloadLlama,
} from "./LlamaServer"
import { cleanWithQwen } from "./QwenCleanup"
import { MODELS, modelSpec } from "./Config"
import {
  loadPrompt, resolveCleanupPrompt, savePrompt, resetPrompt, saveSelection, type ModelSelection,
} from "./ServerState"
import type { WritingStyle } from "./Personalization"
import { InferenceQueue } from "./InferenceQueue"

export interface ApiContext {
  readonly cfg: ServerConfig
  readonly token: string
  selection: ModelSelection
}

const unauthorized = HttpServerResponse.text("unauthorized", { status: 401 })
const json = (v: unknown, status = 200) =>
  HttpServerResponse.json(v, { status })

const authed = (ctx: ApiContext, req: HttpServerRequest.HttpServerRequest) =>
  checkAuth(req.headers, ctx.token)

const transcriptionQueue = new InferenceQueue("transcription")
const cleanupQueue = new InferenceQueue("cleanup")

const requestIdentity = (req: HttpServerRequest.HttpServerRequest): string => {
  const value = req.headers["x-omil-request-id"]
  const candidate = Array.isArray(value) ? value[0] : value
  return candidate?.trim().slice(0, 128) || crypto.randomUUID()
}

export const makeRouter = (ctx: ApiContext) =>
  HttpRouter.empty.pipe(
    HttpRouter.get("/v1/health", Effect.gen(function* () {
      const bins = yield* checkBinaries(ctx.cfg)
      // Non-mutating: never triggers downloads.
      const whisperReady = yield* checkModelReady(ctx.cfg, ctx.selection.whisper)
      const llmReady = yield* checkModelReady(ctx.cfg, ctx.selection.llm)
      const runtime = llamaRuntime()
      return yield* json({
        ok: true,
        whisperBin: bins.whisper, llamaBin: bins.llama,
        whisperModelReady: whisperReady, llmModelReady: llmReady,
        llamaLive: runtime.state === "ready" || runtime.state === "inUse",
        liveLlmModel: liveLlmModel(),
        llmRuntime: runtime,
        whisperModel: ctx.selection.whisper, llmModel: ctx.selection.llm,
      })
    })),
    HttpRouter.get("/v1/models", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      const out = []
      const runtime = llamaRuntime()
      for (const m of MODELS) {
        const downloaded = yield* checkModelReady(ctx.cfg, m.id)
        const file = modelFileLifecycle(ctx.cfg, m.id)
        out.push({
          id: m.id, kind: m.kind, description: m.description,
          filename: m.filename,
          approxBytes: m.expectedBytes,
          downloaded,
          selected: (m.kind === "whisper" ? ctx.selection.whisper : ctx.selection.llm) === m.id,
          fileState: file?.state ?? (downloaded ? "ready" : "missing"),
          receivedBytes: file?.receivedBytes ?? (downloaded ? m.expectedBytes : 0),
          totalBytes: file?.totalBytes ?? m.expectedBytes,
          fileError: file?.error ?? null,
          memoryState: m.kind === "whisper"
            ? whisperMemoryState(m.id)
            : runtime.modelId === m.id ? runtime.state : "unloaded",
          activeUses: m.kind === "llm" && runtime.modelId === m.id ? runtime.activeUses : 0,
        })
      }
      return yield* json({ models: out, selection: ctx.selection, llmRuntime: runtime })
    })),
    HttpRouter.get("/v1/queue", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      return yield* json({
        transcription: transcriptionQueue.snapshot(),
        cleanup: cleanupQueue.snapshot(),
      })
    })),
    HttpRouter.post("/v1/models/select", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      const body = (yield* req.json) as { whisper?: string; llm?: string }
      const next: ModelSelection = { ...ctx.selection }
      if (body.whisper !== undefined) {
        const spec = body.whisper ? modelSpec(body.whisper) : undefined
        if (!spec || spec.kind !== "whisper") return yield* json({ error: `unknown whisper model '${body.whisper}'` }, 400)
        next.whisper = spec.id
      }
      if (body.llm !== undefined) {
        const spec = body.llm ? modelSpec(body.llm) : undefined
        if (!spec || spec.kind !== "llm") return yield* json({ error: `unknown llm '${body.llm}'` }, 400)
        next.llm = spec.id
      }
      const llmChanged = next.llm !== ctx.selection.llm
      ctx.selection = next
      yield* Effect.promise(() => saveSelection(ctx.cfg.dataDir, next))
      if (llmChanged) {
        // An active cleanup keeps its lease. Memory releases immediately after
        // that request; an idle model releases now.
        yield* Effect.promise(() => unloadLlama())
      }
      return yield* json({ selection: next, note: llmChanged ? "llm sidecar restarts on next cleanup" : "selection saved" })
    })),
    HttpRouter.post("/v1/models/prepare", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      const body = yield* req.json.pipe(
        Effect.map((value) => value as { model?: unknown }),
        Effect.catchAll(() => Effect.succeed({} as { model?: unknown })),
      )
      if (body.model !== undefined) {
        if (typeof body.model !== "string") {
          return yield* json({ error: "model must be a string" }, 400)
        }
        const spec = modelSpec(body.model)
        if (!spec) return yield* json({ error: `unknown model '${body.model}'` }, 400)
        const prepared = yield* Effect.either(ensureModel(ctx.cfg, spec.id))
        if (prepared._tag === "Left") {
          return yield* json({ error: prepared.left.reason, model: spec.id }, 503)
        }
        return yield* json({ ready: true, model: spec.id })
      }
      const whisper = yield* Effect.either(ensureModel(ctx.cfg, ctx.selection.whisper))
      if (whisper._tag === "Left") {
        return yield* json({ error: whisper.left.reason, model: ctx.selection.whisper }, 503)
      }
      const llm = yield* Effect.either(ensureModel(ctx.cfg, ctx.selection.llm))
      if (llm._tag === "Left") {
        return yield* json({ error: llm.left.reason, model: ctx.selection.llm }, 503)
      }
      return yield* json({ ready: true, whisper: ctx.selection.whisper, llm: ctx.selection.llm })
    })),
    HttpRouter.post("/v1/models/unload", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      const unloaded = yield* Effect.promise(() => unloadLlama())
      return yield* json({ unloaded, runtime: llamaRuntime() })
    })),
    HttpRouter.post("/v1/models/delete", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      const body = (yield* req.json) as { model?: unknown }
      if (typeof body.model !== "string") {
        return yield* json({ error: "model must be a string" }, 400)
      }
      const spec = modelSpec(body.model)
      if (!spec) return yield* json({ error: `unknown model '${body.model}'` }, 400)

      const queue = spec.kind === "whisper" ? transcriptionQueue.snapshot() : cleanupQueue.snapshot()
      if (queue.active || queue.pending.length > 0) {
        return yield* json({ error: `${queue.name} jobs are still queued; try again when the queue is empty` }, 409)
      }
      if (spec.kind === "whisper" && whisperMemoryState(spec.id) === "inUse") {
        return yield* json({ error: "the transcription model is in use" }, 409)
      }
      if (spec.kind === "llm" && liveLlmModel() === spec.id) {
        const runtime = llamaRuntime()
        if (runtime.activeUses > 0) return yield* json({ error: "the cleanup model is in use" }, 409)
        yield* Effect.promise(() => unloadLlama())
      }
      const removed = yield* Effect.either(deleteModel(ctx.cfg, spec.id))
      if (removed._tag === "Left") return yield* json({ error: removed.left.reason }, 409)
      return yield* json({ removed: removed.right, model: spec.id })
    })),
    HttpRouter.get("/v1/prompt", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      const p = yield* Effect.promise(() => loadPrompt(ctx.cfg.dataDir))
      return yield* json(p)
    })),
    HttpRouter.post("/v1/prompt", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      const body = (yield* req.json) as { text?: string }
      if (!body.text || typeof body.text !== "string" || body.text.trim().length < 50) {
        return yield* json({ error: "prompt text too short (min 50 chars)" }, 400)
      }
      if (body.text.length > 50_000) return yield* json({ error: "prompt too long" }, 413)
      yield* Effect.promise(() => savePrompt(ctx.cfg.dataDir, body.text as string))
      return yield* json({ isCustom: true })
    })),
    HttpRouter.del("/v1/prompt", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      yield* Effect.promise(() => resetPrompt(ctx.cfg.dataDir))
      return yield* json({ isCustom: false })
    })),
    HttpRouter.post("/v1/transcribe", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      const search = new URL(req.url, "http://x").searchParams
      const language = search.get("language") ?? "en"
      const sensitivity = parseAudioSensitivity(search.get("sensitivity"))
      if (!sensitivity) return yield* json({ error: "unknown speech sensitivity" }, 400)
      const requestedModel = search.get("model") ?? ctx.selection.whisper
      const model = modelSpec(requestedModel)
      if (!model || model.kind !== "whisper") {
        return yield* json({ error: `unknown whisper model '${requestedModel}'` }, 400)
      }
      const requestId = requestIdentity(req)
      // Body: WAV bytes (Content-Type: audio/wav, octet-stream).
      const dir = yield* Effect.promise(() => mkdtemp(path.join(tmpdir(), "omil-up-")))
      try {
        const audioPath = path.join(dir, "audio.wav")
        const buf = yield* req.arrayBuffer
        if (buf.byteLength === 0) return yield* json({ error: "empty body" }, 400)
        if (buf.byteLength > 200 * 1024 * 1024) return yield* json({ error: "audio too large (200MB cap)" }, 413)
        yield* Effect.promise(() => writeFile(audioPath, Buffer.from(buf)))
        const outcome = yield* Effect.either(Effect.tryPromise({
          try: () => transcriptionQueue.enqueue(
            requestId,
            () => Effect.runPromise(transcribeFile(ctx.cfg, audioPath, language, model.id, sensitivity)),
          ),
          catch: (error) => error instanceof ModelError ? error : new ModelError(String(error)),
        }))
        if (outcome._tag === "Left") {
          const msg = outcome.left.reason
          const needsModels = /download|checksum|size|binary|exited/i.test(msg)
          return yield* json({ error: msg }, needsModels ? 503 : 500)
        }
        const queued = outcome.right
        const t = queued.value
        return yield* json({
          text: t.text,
          segments: t.segments,
          model: t.model,
          requestId: queued.requestId,
          queue: {
            jobId: queued.jobId,
            positionAtEnqueue: queued.positionAtEnqueue,
            waitedMs: queued.waitedMs,
          },
          warning: "server-side inference on your own Mac; LAN transport, no third parties",
        })
      } finally {
        yield* Effect.promise(() => rm(dir, { recursive: true, force: true }))
      }
    })),
    HttpRouter.post("/v1/cleanup", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      const body = (yield* req.json) as {
        text?: string
        mode?: "verbatim" | "clean"
        dictionary?: Record<string, string>
        snippets?: Record<string, string>
        style?: WritingStyle
        model?: string
        systemPrompt?: string
      }
      if (!body.text || typeof body.text !== "string") return yield* json({ error: "missing text" }, 400)
      if (body.text.length > 200_000) return yield* json({ error: "text too long" }, 413)
      if (body.systemPrompt !== undefined &&
          (typeof body.systemPrompt !== "string" || body.systemPrompt.trim().length < 50)) {
        return yield* json({ error: "system prompt too short (min 50 chars)" }, 400)
      }
      if (body.systemPrompt && body.systemPrompt.length > 50_000) {
        return yield* json({ error: "system prompt too long" }, 413)
      }
      const mode = body.mode === "verbatim" ? "verbatim" : "clean"
      const requestedModel = body.model ?? ctx.selection.llm
      const model = modelSpec(requestedModel)
      if (!model || model.kind !== "llm") {
        return yield* json({ error: `unknown cleanup model '${requestedModel}'` }, 400)
      }
      const requestId = requestIdentity(req)
      const prompt = yield* Effect.promise(() => resolveCleanupPrompt(ctx.cfg.dataDir, body.systemPrompt))
      const preferences = {
        text: body.text,
        mode,
        dictionary: body.dictionary,
        snippets: body.snippets,
        style: body.style,
      } as const
      const outcome = yield* Effect.either(Effect.tryPromise({
        try: () => cleanupQueue.enqueue(requestId, () => Effect.runPromise(Effect.gen(function* () {
          const lease = mode === "clean"
            ? yield* acquireLlama(ctx.cfg, model.id)
            : null
          const handle = lease?.handle ?? null
          return yield* cleanWithQwen(handle, preferences, prompt.text).pipe(
            Effect.ensuring(Effect.sync(() => lease?.release())),
          )
        }))),
        catch: (error) => error instanceof ModelError ? error : new ModelError(String(error)),
      }))
      if (outcome._tag === "Left") {
        return yield* json({ error: `cleanup model unavailable: ${outcome.left.reason}` }, 503)
      }
      const queued = outcome.right
      return yield* json({
        ...queued.value,
        promptCustom: prompt.isCustom,
        requestId: queued.requestId,
        queue: {
          jobId: queued.jobId,
          positionAtEnqueue: queued.positionAtEnqueue,
          waitedMs: queued.waitedMs,
        },
      })
    })),
  )

export { stopLlama }
