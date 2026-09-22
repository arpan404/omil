import { Effect } from "effect"
import type { ServerConfig } from "./Config"
import { ensureModel, ModelError } from "./Models"
import {
  ModelRuntimeLifecycle,
  type ModelRuntimeSnapshot,
} from "./ModelRuntime"

/** Manages the resident Qwen sidecar and its memory lifetime. */

export interface LlamaHandle {
  readonly baseUrl: string
  readonly modelId: string
}

export interface LlamaLease {
  readonly handle: LlamaHandle
  release(): void
}

export interface LlamaRuntimeSnapshot extends ModelRuntimeSnapshot {
  readonly idleUnloadMs: number
}

let proc: Bun.Subprocess | null = null
let liveModel: string | null = null
let loadPromise: Promise<LlamaHandle> | null = null
let loadPromiseModel: string | null = null
let idleTimer: ReturnType<typeof setTimeout> | null = null
const lifecycle = new ModelRuntimeLifecycle()

const configuredIdleMs = Number(process.env.OMIL_MODEL_IDLE_MS ?? 120_000)
const idleUnloadMs = Number.isFinite(configuredIdleMs) && configuredIdleMs >= 1_000
  ? configuredIdleMs
  : 120_000

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

const clearIdleUnload = () => {
  if (idleTimer) clearTimeout(idleTimer)
  idleTimer = null
  lifecycle.cancelUnload()
}

const terminateProcess = async (): Promise<void> => {
  const target = proc
  proc = null
  liveModel = null
  if (target && target.exitCode === null) {
    try { target.kill() } catch { /* already gone */ }
    await Promise.race([target.exited.catch(() => -1), sleep(5_000)])
    if (target.exitCode === null) {
      try { target.kill(9) } catch { /* already gone */ }
    }
  }
  lifecycle.markUnloaded()
}

const requestUnload = async (): Promise<boolean> => {
  if (!lifecycle.requestUnload()) return false
  await terminateProcess()
  return true
}

const scheduleIdleUnload = () => {
  if (idleTimer) clearTimeout(idleTimer)
  idleTimer = setTimeout(() => {
    idleTimer = null
    void requestUnload()
  }, idleUnloadMs)
  idleTimer.unref?.()
}

const startLlama = async (cfg: ServerConfig, selected: string): Promise<LlamaHandle> => {
  clearIdleUnload()
  const current = lifecycle.snapshot()
  const baseUrl = `http://127.0.0.1:${cfg.llamaPort}`

  if (liveModel === selected && proc && current.state !== "failed" && await Effect.runPromise(isHealthy(baseUrl))) {
    lifecycle.cancelUnload()
    return { baseUrl, modelId: selected }
  }

  if (loadPromise) {
    if (loadPromiseModel === selected) return loadPromise
    await loadPromise.catch(() => undefined)
  }

  const afterWait = lifecycle.snapshot()
  if (afterWait.activeUses > 0 && afterWait.modelId !== selected) {
    throw new ModelError(`cleanup model '${afterWait.modelId}' is busy; retry the model switch`)
  }
  if (proc) await terminateProcess()

  const token = lifecycle.beginLoading(selected)
  const pending = (async () => {
    const model = await Effect.runPromise(ensureModel(cfg, selected))
    console.log(`loading llama-server (${selected}) on :${cfg.llamaPort}`)
    const child = Bun.spawn(
      [cfg.llamaBin, "-m", model, "--port", String(cfg.llamaPort), "-c", "4096", "--no-webui"],
      { stdout: "ignore", stderr: "pipe" },
    )
    proc = child

    for (let attempt = 0; attempt < 120; attempt += 1) {
      await sleep(2_000)
      if (child !== proc) throw new ModelError("cleanup model load was cancelled")
      if (await Effect.runPromise(isHealthy(baseUrl))) {
        if (!lifecycle.markReady(token)) {
          try { child.kill() } catch { /* already gone */ }
          throw new ModelError("cleanup model selection changed while loading")
        }
        liveModel = selected
        console.log(`llama-server ready (${selected})`)
        return { baseUrl, modelId: selected }
      }
      if (child.exitCode !== null) {
        const errorText = await readStderr(child)
        throw new ModelError(`llama-server exited early: ${errorText.slice(-2000)}`)
      }
    }
    try { child.kill() } catch { /* already gone */ }
    throw new ModelError("llama-server did not become ready in 240s")
  })()

  loadPromise = pending
  loadPromiseModel = selected
  try {
    return await pending
  } catch (error) {
    const reason = error instanceof ModelError ? error.reason : String(error)
    lifecycle.markFailed(token, reason)
    if (proc?.exitCode !== null) proc = null
    liveModel = null
    throw error instanceof ModelError ? error : new ModelError(reason)
  } finally {
    if (loadPromise === pending) {
      loadPromise = null
      loadPromiseModel = null
    }
  }
}

export const acquireLlama = (
  cfg: ServerConfig,
  modelId?: string,
): Effect.Effect<LlamaLease, ModelError, never> =>
  Effect.tryPromise({
    try: async () => {
      const selected = modelId ?? cfg.llmModelId
      const handle = await startLlama(cfg, selected)
      clearIdleUnload()
      if (!lifecycle.beginUse(selected)) {
        throw new ModelError("cleanup model changed before inference could start")
      }
      let released = false
      return {
        handle,
        release() {
          if (released) return
          released = true
          const shouldUnload = lifecycle.endUse(selected)
          if (shouldUnload) {
            void terminateProcess()
          } else if (lifecycle.snapshot().state === "ready") {
            scheduleIdleUnload()
          }
        },
      }
    },
    catch: (error) => error instanceof ModelError ? error : new ModelError(String(error)),
  })

/** Explicit unload. Active inference finishes first, then releases memory. */
export const unloadLlama = (): Promise<boolean> => {
  clearIdleUnload()
  return requestUnload()
}

/** Process shutdown path. The operating system releases child memory. */
export const stopLlama = (): void => {
  if (idleTimer) clearTimeout(idleTimer)
  idleTimer = null
  if (proc) {
    try { proc.kill() } catch { /* already gone */ }
  }
  proc = null
  liveModel = null
  loadPromise = null
  loadPromiseModel = null
  lifecycle.markUnloaded()
}

export const llamaRuntime = (): LlamaRuntimeSnapshot => ({
  ...lifecycle.snapshot(),
  idleUnloadMs,
})

export const liveLlmModel = (): string | null => liveModel

const isHealthy = (baseUrl: string): Effect.Effect<boolean, never, never> =>
  Effect.promise(async () => {
    try {
      const response = await fetch(`${baseUrl}/health`, { signal: AbortSignal.timeout(3_000) })
      if (!response.ok) return false
      const body = (await response.json()) as { status?: string }
      return body.status === "ok"
    } catch {
      return false
    }
  })

const readStderr = async (child: Bun.Subprocess): Promise<string> => {
  try {
    const stream = child.stderr
    if (stream && typeof stream !== "number") {
      return await new Response(stream as ReadableStream).text()
    }
  } catch { /* no diagnostic available */ }
  return ""
}

export interface ChatMessage { role: "system" | "user"; content: string }

/** OpenAI-compatible chat completion, JSON-object constrained. */
export const chatJson = (
  handle: LlamaHandle,
  messages: ReadonlyArray<ChatMessage>,
  maxTokens = 1024,
): Effect.Effect<unknown, ModelError, never> =>
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
          response_format: { type: "json_object" },
        }),
        signal: AbortSignal.timeout(180_000),
      }).catch((error) => ({ ok: false as const, error })),
    )
    if (typeof response !== "object" || response === null || !("ok" in response) || !response.ok) {
      const detail = response && typeof response === "object" && "error" in response
        ? String((response as { error: unknown }).error)
        : `HTTP ${(response as Response).status}`
      return yield* Effect.fail(new ModelError(`llama chat failed: ${detail}`))
    }
    const json = (yield* Effect.promise(() => (response as Response).json())) as {
      choices?: Array<{ message?: { content?: string } }>
    }
    const content = json.choices?.[0]?.message?.content ?? ""
    try {
      return JSON.parse(content) as unknown
    } catch {
      const match = content.match(/\{[\s\S]*\}/)
      if (match) {
        try { return JSON.parse(match[0]) as unknown } catch { /* fall through */ }
      }
      return yield* Effect.fail(new ModelError(`llama returned non-JSON: ${content.slice(0, 300)}`))
    }
  })
