import { Effect, Layer } from "effect"
import { HttpServer } from "@effect/platform"
import { BunHttpServer, BunRuntime } from "@effect/platform-bun"
import { loadConfig, VAD_MODEL, type ServerConfig } from "./Config"
import { loadOrCreateToken } from "./Auth"
import { checkModelReady, ensureModel } from "./Models"
import { loadSelection, type ModelSelection } from "./ServerState"
import { makeRouter, type ApiContext } from "./Api"
import { stopLlama } from "./LlamaServer"
import { stopWhisper, warmWhisper } from "./Whisper"

/**
 * Omil inference core. Serves Whisper transcription + local-model cleanup to
 * Omil Swift clients on the LAN. Run on your Mac; point iPhone/iPad at it.
 *
 *   bun src/main.ts
 *
 * Env: OMIL_HOST (default 127.0.0.1), OMIL_PORT (3217), OMIL_DATA (./data),
 *      OMIL_WHISPER_BIN, OMIL_WHISPER_SERVER_BIN, OMIL_LLAMA_BIN,
 *      OMIL_LLAMA_PORT (3218), OMIL_WHISPER_PORT (llama port + 1),
 *      OMIL_WHISPER_MODEL, OMIL_LLM_MODEL
 */

/**
 * Hashes already-downloaded weights and loads whisper-server so the first
 * dictation after launch skips both. Never downloads a missing model.
 */
const prepareAtBoot = (cfg: ServerConfig, selection: ModelSelection) =>
  Effect.gen(function* () {
    if (yield* checkModelReady(cfg, selection.whisper)) {
      yield* ensureModel(cfg, selection.whisper)
      yield* ensureModel(cfg, VAD_MODEL.id)
      yield* Effect.tryPromise({
        try: () => warmWhisper(cfg, selection.whisper),
        catch: (error) => error,
      })
    }
    if (yield* checkModelReady(cfg, selection.llm)) yield* ensureModel(cfg, selection.llm)
  }).pipe(
    Effect.catchAll((error) => Effect.sync(() => {
      const reason = typeof error === "object" && error !== null && "reason" in error ? error.reason : error
      console.error(`boot preparation: ${String(reason)}`)
    })),
  )

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
  console.log(`whisper=${selection.whisper} llm=${selection.llm} (downloaded on first use)`)
  yield* Effect.addFinalizer(() => Effect.sync(() => {
    stopLlama()
    stopWhisper()
  }))
  yield* Effect.forkDaemon(prepareAtBoot(cfg, selection))
  const server = HttpServer.serve(makeRouter(ctx))
  // Runs until interrupted; Ctrl-C triggers the scope finalizer (sidecar shutdown).
  yield* Layer.launch(Layer.provide(server, BunHttpServer.layer({
    port: cfg.port,
    hostname: cfg.host,
  })))
})

program.pipe(Effect.scoped, BunRuntime.runMain)
