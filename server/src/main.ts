import { Effect, Layer } from "effect"
import { HttpServer } from "@effect/platform"
import { BunHttpServer, BunRuntime } from "@effect/platform-bun"
import { loadConfig } from "./Config"
import { loadOrCreateToken } from "./Auth"
import { ensureModel } from "./Models"
import { makeRouter, stopLlama, type ApiContext } from "./Api"

/**
 * Omil inference core. Serves Whisper transcription + Qwen cleanup to
 * Omil Swift clients on the LAN. Run on your Mac; point iPhone/iPad at it.
 *
 *   bun src/main.ts
 *
 * Env: OMIL_HOST (default 127.0.0.1), OMIL_PORT (3217), OMIL_DATA (./data),
 *      OMIL_WHISPER_BIN, OMIL_LLAMA_BIN, OMIL_LLAMA_PORT (3218),
 *      OMIL_WHISPER_MODEL, OMIL_LLM_MODEL
 */

const program = Effect.gen(function* () {
  const cfg = yield* loadConfig
  // Detached prefetch: `bun src/main.ts --download-models` ensures both
  // weight files, then exits. Survives client disconnects.
  if (process.argv.includes("--download-models")) {
    yield* ensureModel(cfg, cfg.whisperModelId)
    yield* ensureModel(cfg, cfg.llmModelId)
    console.log("all models ready")
    return
  }
  const token = yield* loadOrCreateToken(cfg.dataDir)
  const ctx: ApiContext = { cfg, token, llama: null }
  console.log(`Omil inference core: http://${cfg.host}:${cfg.port}`)
  console.log(`whisper=${cfg.whisperModelId} llm=${cfg.llmModelId} (downloaded on first use)`)
  yield* Effect.addFinalizer(() => Effect.sync(() => stopLlama()))
  const server = HttpServer.serve(makeRouter(ctx))
  yield* Layer.launch(Layer.provide(server, BunHttpServer.layer({ port: cfg.port })))
  // Park forever; Ctrl-C triggers the scope finalizer (llama shutdown).
  yield* Effect.never
})

program.pipe(Effect.scoped, BunRuntime.runMain)
