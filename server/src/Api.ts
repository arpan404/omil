import { Effect } from "effect"
import {
  HttpRouter, HttpServerRequest, HttpServerResponse,
} from "@effect/platform"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import type { ServerConfig } from "./Config"
import { checkAuth } from "./Auth"
import { checkBinaries, checkModelReady } from "./Models"
import { transcribeFile } from "./Whisper"
import { ensureLlama, stopLlama, liveLlmModel, type LlamaHandle } from "./LlamaServer"
import { cleanWithQwen } from "./QwenCleanup"
import { MODELS, modelSpec } from "./Config"
import {
  loadPrompt, savePrompt, resetPrompt, saveSelection, type ModelSelection,
} from "./ServerState"

export interface ApiContext {
  readonly cfg: ServerConfig
  readonly token: string
  selection: ModelSelection
  llama: LlamaHandle | null
}

const unauthorized = HttpServerResponse.text("unauthorized", { status: 401 })
const json = (v: unknown, status = 200) =>
  HttpServerResponse.json(v, { status })

const authed = (ctx: ApiContext, req: HttpServerRequest.HttpServerRequest) =>
  checkAuth(req.headers, ctx.token)

export const makeRouter = (ctx: ApiContext) =>
  HttpRouter.empty.pipe(
    HttpRouter.get("/v1/health", Effect.gen(function* () {
      const bins = yield* checkBinaries(ctx.cfg)
      // Non-mutating: never triggers downloads.
      const whisperReady = yield* checkModelReady(ctx.cfg, ctx.selection.whisper)
      const llmReady = yield* checkModelReady(ctx.cfg, ctx.selection.llm)
      return yield* json({
        ok: true,
        whisperBin: bins.whisper, llamaBin: bins.llama,
        whisperModelReady: whisperReady, llmModelReady: llmReady,
        llamaLive: ctx.llama !== null,
        liveLlmModel: liveLlmModel(),
        whisperModel: ctx.selection.whisper, llmModel: ctx.selection.llm,
      })
    })),
    HttpRouter.get("/v1/models", Effect.gen(function* () {
      const req = yield* HttpServerRequest.HttpServerRequest
      if (!authed(ctx, req)) return unauthorized
      const out = []
      for (const m of MODELS) {
        out.push({
          id: m.id, kind: m.kind, description: m.description,
          filename: m.filename,
          approxBytes: m.expectedBytes,
          downloaded: yield* checkModelReady(ctx.cfg, m.id),
          selected: (m.kind === "whisper" ? ctx.selection.whisper : ctx.selection.llm) === m.id,
        })
      }
      return yield* json({ models: out, selection: ctx.selection })
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
        // Restart the sidecar lazily: drop the handle; next cleanup boots it.
        stopLlama()
        ctx.llama = null
      }
      return yield* json({ selection: next, note: llmChanged ? "llm sidecar restarts on next cleanup" : "selection saved" })
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
      // Body: WAV bytes (Content-Type: audio/wav, octet-stream).
      const dir = yield* Effect.promise(() => mkdtemp(path.join(tmpdir(), "omil-up-")))
      try {
        const audioPath = path.join(dir, "audio.wav")
        const buf = yield* req.arrayBuffer
        if (buf.byteLength === 0) return yield* json({ error: "empty body" }, 400)
        if (buf.byteLength > 200 * 1024 * 1024) return yield* json({ error: "audio too large (200MB cap)" }, 413)
        yield* Effect.promise(() => writeFile(audioPath, Buffer.from(buf)))
        const outcome = yield* Effect.either(transcribeFile(ctx.cfg, audioPath, language, ctx.selection.whisper))
        if (outcome._tag === "Left") {
          const msg = outcome.left.reason
          const needsModels = /download|checksum|size|binary|exited/i.test(msg)
          return yield* json({ error: msg }, needsModels ? 503 : 500)
        }
        const t = outcome.right
        return yield* json({
          text: t.text,
          segments: t.segments,
          model: t.model,
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
        text?: string; mode?: "verbatim" | "clean"; dictionary?: Record<string, string>
      }
      if (!body.text || typeof body.text !== "string") return yield* json({ error: "missing text" }, 400)
      if (body.text.length > 200_000) return yield* json({ error: "text too long" }, 413)
      if (!ctx.llama || ctx.llama.modelId !== ctx.selection.llm) {
        const started = yield* Effect.either(ensureLlama(ctx.cfg, ctx.selection.llm))
        if (started._tag === "Left") {
          return yield* json({ error: `cleanup model unavailable: ${started.left.reason}` }, 503)
        }
        ctx.llama = started.right
      }
      const prompt = yield* Effect.promise(() => loadPrompt(ctx.cfg.dataDir))
      const result = yield* cleanWithQwen(ctx.llama, {
        text: body.text,
        mode: body.mode === "verbatim" ? "verbatim" : "clean",
        dictionary: body.dictionary,
      }, prompt.text)
      return yield* json({ ...result, promptCustom: prompt.isCustom })
    })),
  )

export { stopLlama }
