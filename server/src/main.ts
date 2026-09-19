import { Effect, Layer } from "effect"
import { HttpServer } from "@effect/platform"
import { BunHttpServer, BunRuntime } from "@effect/platform-bun"
import { loadConfig } from "./Config"
import { loadOrCreateToken } from "./Auth"
import { ensureModel } from "./Models"
import { loadSelection } from "./ServerState"
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
  // Reclaim a stale llama sidecar port left by a killed predecessor
  // (single-user Mac; the app owns this port).
  yield* Effect.promise(async () => {
    try {
      const res = Bun.spawnSync(["sh", "-c", `lsof -ti tcp:${cfg.llamaPort} 2>/dev/null`])
      const out = typeof res.stdout === "string" ? res.stdout : Buffer.from(res.stdout as Uint8Array).toString()
      for (const pid of out.split(/\s+/).filter(Boolean)) {
        if (/^\d+$/.test(pid) && Number(pid) !== process.pid) {
          try { process.kill(Number(pid)) } catch { /* already gone */ }
        }
      }
    } catch { /* lsof unavailable */ }
  })
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
  const ctx: ApiContext = { cfg, token, selection, llama: null }
  console.log(`Omil inference core: http://${cfg.host}:${cfg.port}`)
  console.log(`whisper=${cfg.whisperModelId} llm=${cfg.llmModelId} (downloaded on first use)`)
  yield* Effect.addFinalizer(() => Effect.sync(() => stopLlama()))
  const server = HttpServer.serve(makeRouter(ctx))
  yield* Layer.launch(Layer.provide(server, BunHttpServer.layer({ port: cfg.port })))
  // Park forever; Ctrl-C triggers the scope finalizer (llama shutdown).
  yield* Effect.never
})

program.pipe(Effect.scoped, BunRuntime.runMain)
