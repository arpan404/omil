import { Effect } from "effect"
import type { ServerConfig } from "./Config"
import { ensureModel, ModelError } from "./Models"

/**
 * Manages the llama-server sidecar (Qwen 4B cleanup model) as a child
 * process with readiness polling. Dies with the Effect scope that owns it.
 */

export interface LlamaHandle {
  readonly baseUrl: string
  readonly modelId: string
}

let proc: Bun.Subprocess | null = null

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

export const ensureLlama = (
  cfg: ServerConfig,
): Effect.Effect<LlamaHandle, ModelError, never> =>
  Effect.gen(function* () {
    const model = yield* ensureModel(cfg, cfg.llmModelId)
    const baseUrl = `http://127.0.0.1:${cfg.llamaPort}`
    if (yield* isHealthy(baseUrl)) return { baseUrl, modelId: cfg.llmModelId }
    if (proc) {
      try { proc.kill() } catch { /* already dead */ }
      proc = null
    }
    console.log(`starting llama-server (${cfg.llmModelId}) on :${cfg.llamaPort} …`)
    proc = Bun.spawn(
      [cfg.llamaBin, "-m", model, "--port", String(cfg.llamaPort), "-c", "4096", "--no-webui"],
      { stdout: "ignore", stderr: "pipe" },
    )
    // Wait for the model to load (large first boot: tens of seconds).
    for (let i = 0; i < 120; i++) {
      yield* Effect.promise(() => sleep(2000))
      if (yield* isHealthy(baseUrl)) {
        console.log("llama-server ready")
        return { baseUrl, modelId: cfg.llmModelId }
      }
      const exited = proc === null || proc.exitCode !== null
      if (exited) {
        const errText = yield* Effect.promise(async () => {
          try {
            const s = proc?.stderr
            if (s && typeof s !== "number") return await new Response(s as ReadableStream).text()
          } catch { /* noop */ }
          return ""
        })
        return yield* Effect.fail(new ModelError(`llama-server exited early: ${errText.slice(-2000)}`))
      }
    }
    return yield* Effect.fail(new ModelError("llama-server did not become ready in 240s"))
  })

const isHealthy = (baseUrl: string): Effect.Effect<boolean, never, never> =>
  Effect.promise(async () => {
    try {
      const res = await fetch(`${baseUrl}/health`, { signal: AbortSignal.timeout(3000) })
      if (!res.ok) return false
      const j = (await res.json()) as { status?: string; error?: unknown }
      return j.status === "ok"
    } catch {
      return false
    }
  })

export const stopLlama = (): void => {
  if (proc) {
    try { proc.kill() } catch { /* noop */ }
    proc = null
  }
}

export interface ChatMessage { role: "system" | "user"; content: string }

/** OpenAI-compatible chat completion, JSON-object constrained. */
export const chatJson = (
  handle: LlamaHandle,
  messages: ReadonlyArray<ChatMessage>,
  maxTokens = 1024,
): Effect.Effect<unknown, ModelError, never> =>
  Effect.gen(function* () {
    const res = yield* Effect.promise(() =>
      fetch(`${handle.baseUrl}/v1/chat/completions`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          messages,
          temperature: 0,
          top_p: 1,
          max_tokens: maxTokens,
          response_format: { type: "json_object" },
        }),
        signal: AbortSignal.timeout(180_000),
      }).catch((e) => ({ ok: false as const, err: e })),
    )
    if (typeof res !== "object" || res === null || !("ok" in res) || !res.ok) {
      const detail = res && typeof res === "object" && "err" in res ? String((res as { err: unknown }).err) : `HTTP ${(res as Response).status}`
      return yield* Effect.fail(new ModelError(`llama chat failed: ${detail}`))
    }
    const json = (yield* Effect.promise(() => (res as Response).json())) as {
      choices?: Array<{ message?: { content?: string } }>
    }
    const content = json.choices?.[0]?.message?.content ?? ""
    try {
      return JSON.parse(content) as unknown
    } catch {
      // Salvage: first {...} block.
      const m = content.match(/\{[\s\S]*\}/)
      if (m) {
        try { return JSON.parse(m[0]) as unknown } catch { /* fallthrough */ }
      }
      return yield* Effect.fail(new ModelError(`llama returned non-JSON: ${content.slice(0, 300)}`))
    }
  })
