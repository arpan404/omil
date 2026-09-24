import { Effect, Layer } from "effect"
import { HttpServer } from "@effect/platform"
import { BunHttpServer, BunRuntime } from "@effect/platform-bun"
import { loadConfig } from "./Config"
import { loadOrCreateToken } from "./Auth"
import { ensureModel } from "./Models"
import { loadSelection } from "./ServerState"
import { makeRouter, stopLlama, type ApiContext } from "./Api"
import { stopWhisper } from "./Whisper"

/**
 * Omil inference core. Serves Whisper transcription + local-model cleanup to
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
  const ownerPid = Number(process.env.OMIL_PARENT_PID ?? 0)
  if (Number.isInteger(ownerPid) && ownerPid > 1) {
    const ownerWatch = setInterval(() => {
      try {
        process.kill(ownerPid, 0)
      } catch {
        stopLlama()
        stopWhisper()
        process.exit(0)
      }
    }, 1_000)
    ownerWatch.unref()
  }
  // Detached prefetch: `bun src/main.ts --download-models` ensures both
  // weight files, then exits. Survives client disconnects.
  if (process.argv.includes("--download-models")) {
    const sel = yield* Effect.promise(() => loadSelection(cfg.dataDir))
    const orExit = (label: string) => (e: { reason: string }) =>
      Effect.sync((): never => {
        console.error(`${label} failed: ${e.reason}`)
        return process.exit(1)
      })
    yield* ensureModel(cfg, sel.whisper).pipe(Effect.catchAll(orExit("whisper")))
    yield* ensureModel(cfg, sel.llm).pipe(Effect.catchAll(orExit("llm")))
    console.log("all models ready")
    return
  }
  const token = yield* loadOrCreateToken(cfg.dataDir)
  const selection = yield* Effect.promise(() => loadSelection(cfg.dataDir))
  const ctx: ApiContext = { cfg, token, selection }
  console.log(`Omil inference core: http://${cfg.host}:${cfg.port}`)
  console.log(`whisper=${cfg.whisperModelId} llm=${cfg.llmModelId} (downloaded on first use)`)
  yield* Effect.addFinalizer(() => Effect.sync(() => {
    stopLlama()
    stopWhisper()
  }))
  const server = HttpServer.serve(makeRouter(ctx))
  yield* Layer.launch(Layer.provide(server, BunHttpServer.layer({
    port: cfg.port,
    hostname: cfg.host,
  })))
  // Park forever; Ctrl-C triggers the scope finalizer (llama shutdown).
  yield* Effect.never
})

program.pipe(Effect.scoped, BunRuntime.runMain)
