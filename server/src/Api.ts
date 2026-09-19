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
import { ensureLlama, stopLlama, type LlamaHandle } from "./LlamaServer"
import { cleanWithQwen } from "./QwenCleanup"

export interface ApiContext {
  readonly cfg: ServerConfig
  readonly token: string
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
      const whisperReady = yield* checkModelReady(ctx.cfg, ctx.cfg.whisperModelId)
      const llmReady = yield* checkModelReady(ctx.cfg, ctx.cfg.llmModelId)
      return yield* json({
        ok: true,
        whisperBin: bins.whisper, llamaBin: bins.llama,
        whisperModelReady: whisperReady, llmModelReady: llmReady,
        llamaLive: ctx.llama !== null,
        whisperModel: ctx.cfg.whisperModelId, llmModel: ctx.cfg.llmModelId,
      })
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
        const outcome = yield* Effect.either(transcribeFile(ctx.cfg, audioPath, language))
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
      if (!ctx.llama) {
        const started = yield* Effect.either(ensureLlama(ctx.cfg))
        if (started._tag === "Left") {
          return yield* json({ error: `cleanup model unavailable: ${started.left.reason}` }, 503)
        }
        ctx.llama = started.right
      }
      const result = yield* cleanWithQwen(ctx.llama, {
        text: body.text,
        mode: body.mode === "verbatim" ? "verbatim" : "clean",
        dictionary: body.dictionary,
      })
      return yield* json(result)
    })),
  )

export { stopLlama }
