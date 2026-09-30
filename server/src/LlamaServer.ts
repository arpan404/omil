import { Effect } from "effect"
import type { ServerConfig } from "./Config"
import { ensureModel, ModelError, toModelError } from "./Models"
import {
  ManagedSidecar, type SidecarHandle, type SidecarLease, type SidecarSnapshot,
} from "./Sidecar"

/** The resident cleanup model sidecar. */

export type LlamaHandle = SidecarHandle

const llama = new ManagedSidecar({ name: "llama-server", readyTimeoutMs: 240_000, captureStderr: false })

let lastRequestedModel: string | null = null

/** One slot keeps the whole context for a single request and its prompt cache warm between requests. */
const LLAMA_CONTEXT_TOKENS = 8192

export const acquireLlama = (
  cfg: ServerConfig,
  modelId?: string,
): Effect.Effect<SidecarLease, ModelError, never> =>
  Effect.tryPromise({
    try: () => {
      const selected = modelId ?? cfg.llmModelId
      lastRequestedModel = selected
      return llama.acquire(selected, async () => {
        const model = await Effect.runPromise(ensureModel(cfg, selected))
        return {
          port: cfg.llamaPort,
          argv: [cfg.llamaBin, "-m", model, "--port", String(cfg.llamaPort),
            "-c", String(LLAMA_CONTEXT_TOKENS), "-np", "1", "-fa", "on", "-ngl", "99",
            "--reasoning", "off", "--no-webui"],
        }
      })
    },
    catch: toModelError,
  })

export const unloadLlama = (): Promise<boolean> => llama.unload()

export const stopLlama = (): void => llama.stop()

export const llamaRuntime = (): SidecarSnapshot => llama.snapshot()

export const liveLlmModel = (): string | null => llama.live()

/** The cleanup model the next request most likely uses: the loaded one, else the last requested. */
export const likelyLlmModel = (): string | null => llama.live() ?? lastRequestedModel

export interface ChatMessage { role: "system" | "user"; content: string }

interface ChatCompletion {
  choices?: Array<{ message?: { content?: string } }>
  timings?: {
    prompt_n?: number
    prompt_ms?: number
    cache_n?: number
    predicted_n?: number
    predicted_ms?: number
  }
}

const logTimings = (timings: ChatCompletion["timings"]) => {
  if (!timings) return
  const ms = (value: number | undefined) => Math.round(value ?? 0)
  console.log(`llama timings: prompt=${timings.prompt_n ?? 0} cached=${timings.cache_n ?? 0} ` +
    `prompt_ms=${ms(timings.prompt_ms)} predicted=${timings.predicted_n ?? 0} predicted_ms=${ms(timings.predicted_ms)}`)
}

/** OpenAI-compatible chat completion returning the assistant's plain text. */
export const chatText = (
  handle: LlamaHandle,
  messages: ReadonlyArray<ChatMessage>,
  maxTokens = 1024,
): Effect.Effect<string, ModelError, never> =>
  Effect.gen(function* () {
    const response = yield* Effect.promise(() =>
      fetch(`${handle.baseUrl}/v1/chat/completions`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          messages,
          temperature: 0,
          top_p: 1,
          max_tokens: maxTokens,
        }),
        signal: AbortSignal.timeout(180_000),
      }).catch((error: unknown) => error instanceof Error ? error : new Error(String(error))),
    )
    if (response instanceof Error || !response.ok) {
      if (response instanceof Error) yield* Effect.promise(() => llama.verifyAfterFailure())
      const detail = response instanceof Error ? String(response) : `HTTP ${response.status}`
      return yield* Effect.fail(new ModelError(`llama chat failed: ${detail}`))
    }
    const json = (yield* Effect.promise(() => response.json())) as ChatCompletion
    logTimings(json.timings)
    const content = json.choices?.[0]?.message?.content?.trim()
    if (!content) return yield* Effect.fail(new ModelError("llama returned empty text"))
    return content
  })
