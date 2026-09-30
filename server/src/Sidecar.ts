import { ModelError, toModelError } from "./Models"
import {
  ModelRuntimeLifecycle,
  type ModelRuntimeSnapshot,
  type ModelRuntimeState,
} from "./ModelRuntime"

/** A resident model process (llama-server, whisper-server) and its memory lifetime. */

export interface SidecarHandle {
  readonly baseUrl: string
  readonly modelId: string
}

export interface SidecarLease {
  readonly handle: SidecarHandle
  release(): void
}

export interface SidecarSnapshot extends ModelRuntimeSnapshot {
  readonly idleUnloadMs: number
}

export interface SidecarLaunch {
  readonly argv: ReadonlyArray<string>
  readonly port: number
}

interface SidecarOptions {
  readonly name: string
  readonly readyTimeoutMs: number
  /** Keep the tail of stderr for crash reports instead of streaming it to the server log. */
  readonly captureStderr: boolean
}

const configuredIdleMs = Number(process.env.OMIL_MODEL_IDLE_MS ?? 900_000)
const idleUnloadMs = Number.isFinite(configuredIdleMs) && configuredIdleMs >= 1_000
  ? configuredIdleMs
  : 900_000

const READY_POLL_MS = 150
const STDERR_TAIL_CHARS = 4_000

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

export const isHealthy = async (baseUrl: string): Promise<boolean> => {
  try {
    const response = await fetch(`${baseUrl}/health`, { signal: AbortSignal.timeout(3_000) })
    if (!response.ok) return false
    const body = (await response.json()) as { status?: string }
    return body.status === "ok"
  } catch {
    return false
  }
}

export class ManagedSidecar {
  private proc: Bun.Subprocess | null = null
  private liveModel: string | null = null
  private baseUrl: string | null = null
  private loadPromise: Promise<SidecarHandle> | null = null
  private loadPromiseModel: string | null = null
  private idleTimer: ReturnType<typeof setTimeout> | null = null
  private stderrTail = ""
  private stderrDrained: Promise<void> = Promise.resolve()
  private readonly lifecycle = new ModelRuntimeLifecycle()

  constructor(private readonly options: SidecarOptions) {}

  snapshot(): SidecarSnapshot {
    return { ...this.lifecycle.snapshot(), idleUnloadMs }
  }

  live(): string | null {
    return this.liveModel
  }

  memoryState(modelId: string): ModelRuntimeState {
    const snapshot = this.lifecycle.snapshot()
    return snapshot.modelId === modelId ? snapshot.state : "unloaded"
  }

  /**
   * Starts (or reuses) the process for `modelId` and holds it for one inference.
   * A live, ready process is reused without a network round trip; callers
   * report request failures through `verifyAfterFailure`.
   */
  async acquire(modelId: string, launch: () => Promise<SidecarLaunch>): Promise<SidecarLease> {
    try {
      const handle = await this.start(modelId, launch)
      this.clearIdleUnload()
      if (!this.lifecycle.beginUse(modelId)) {
        throw new ModelError(`${this.options.name} model changed before inference could start`)
      }
      let released = false
      return {
        handle,
        release: () => {
          if (released) return
          released = true
          const shouldUnload = this.lifecycle.endUse(modelId)
          if (shouldUnload) {
            void this.terminate()
          } else if (this.lifecycle.snapshot().state === "ready") {
            this.scheduleIdleUnload()
          }
        },
      }
    } catch (error) {
      throw toModelError(error)
    }
  }

  /** Called after a request to the sidecar failed. Restarts it on the next acquire if it is gone or hung. */
  async verifyAfterFailure(): Promise<boolean> {
    const target = this.proc
    const baseUrl = this.baseUrl
    if (target && target.exitCode === null && baseUrl && await isHealthy(baseUrl)) return true
    if (target !== null && target === this.proc) await this.terminate()
    return false
  }

  /** Explicit unload. Active inference finishes first, then releases memory. */
  unload(): Promise<boolean> {
    this.clearIdleUnload()
    return this.requestUnload()
  }

  /** Process shutdown path. The operating system releases child memory. */
  stop(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer)
    this.idleTimer = null
    const target = this.proc
    this.proc = null
    this.liveModel = null
    this.baseUrl = null
    this.loadPromise = null
    this.loadPromiseModel = null
    if (target) {
      try { target.kill() } catch { /* already gone */ }
    }
    this.lifecycle.markUnloaded()
  }

  private isLive(modelId: string): boolean {
    const state = this.lifecycle.snapshot().state
    return this.liveModel === modelId && this.baseUrl !== null && this.proc !== null
      && this.proc.exitCode === null && (state === "ready" || state === "inUse")
  }

  private async start(selected: string, launch: () => Promise<SidecarLaunch>): Promise<SidecarHandle> {
    this.clearIdleUnload()
    if (this.isLive(selected)) return { baseUrl: this.baseUrl!, modelId: selected }

    if (this.loadPromise) {
      if (this.loadPromiseModel === selected) return this.loadPromise
      await this.loadPromise.catch(() => undefined)
      if (this.isLive(selected)) return { baseUrl: this.baseUrl!, modelId: selected }
    }

    const afterWait = this.lifecycle.snapshot()
    if (afterWait.activeUses > 0 && afterWait.modelId !== selected) {
      throw new ModelError(`${this.options.name} model '${afterWait.modelId}' is busy; retry the model switch`)
    }
    if (this.proc) await this.terminate()

    const token = this.lifecycle.beginLoading(selected)
    const { name } = this.options
    const pending = (async () => {
      const { argv, port } = await launch()
      const current = this.lifecycle.snapshot()
      if (current.state !== "loading" || current.modelId !== selected) {
        throw new ModelError(`${name} load was cancelled`)
      }
      const baseUrl = `http://127.0.0.1:${port}`
      console.log(`loading ${name} (${selected}) on :${port}`)
      const child = Bun.spawn([...argv], {
        stdout: "ignore",
        stderr: this.options.captureStderr ? "pipe" : "inherit",
      })
      this.proc = child
      this.stderrTail = ""
      if (this.options.captureStderr) this.drainStderr(child)
      void child.exited.then((code) => this.onExit(child, code))

      const deadline = Date.now() + this.options.readyTimeoutMs
      while (Date.now() < deadline) {
        if (child !== this.proc) throw new ModelError(`${name} load was cancelled`)
        if (child.exitCode !== null) {
          await Promise.race([this.stderrDrained, sleep(500)])
          throw new ModelError(`${name} exited early with status ${child.exitCode}${this.stderrDetail()}`)
        }
        // A foreign listener on the port must not be mistaken for our child.
        if (await isHealthy(baseUrl) && child.exitCode === null) {
          if (!this.lifecycle.markReady(token)) {
            try { child.kill() } catch { /* already gone */ }
            throw new ModelError(`${name} model selection changed while loading`)
          }
          this.liveModel = selected
          this.baseUrl = baseUrl
          console.log(`${name} ready (${selected})`)
          return { baseUrl, modelId: selected }
        }
        await sleep(READY_POLL_MS)
      }
      try { child.kill() } catch { /* already gone */ }
      throw new ModelError(`${name} did not become ready in ${Math.round(this.options.readyTimeoutMs / 1000)}s`)
    })()

    this.loadPromise = pending
    this.loadPromiseModel = selected
    try {
      return await pending
    } catch (error) {
      const failure = toModelError(error)
      this.lifecycle.markFailed(token, failure.reason)
      if (this.proc?.exitCode !== null) this.proc = null
      this.liveModel = null
      this.baseUrl = null
      throw failure
    } finally {
      if (this.loadPromise === pending) {
        this.loadPromise = null
        this.loadPromiseModel = null
      }
    }
  }

  private onExit(child: Bun.Subprocess, code: number | null): void {
    // Deliberate terminations clear `proc` first; anything else is a crash.
    if (child !== this.proc) return
    const state = this.lifecycle.snapshot().state
    if (state === "loading") return
    console.error(`${this.options.name} exited unexpectedly (status ${code})${this.stderrDetail()}`)
    this.proc = null
    this.liveModel = null
    this.baseUrl = null
    this.clearIdleUnload()
    this.lifecycle.markUnloaded()
  }

  private drainStderr(child: Bun.Subprocess): void {
    const stream = child.stderr
    if (!stream || typeof stream === "number") return
    this.stderrDrained = (async () => {
      const decoder = new TextDecoder()
      try {
        for await (const chunk of stream as unknown as AsyncIterable<Uint8Array>) {
          if (child !== this.proc) continue
          this.stderrTail = (this.stderrTail + decoder.decode(chunk, { stream: true })).slice(-STDERR_TAIL_CHARS)
        }
      } catch { /* process gone */ }
    })()
  }

  private stderrDetail(): string {
    const tail = this.stderrTail.trim().split("\n").slice(-8).join("\n")
    return tail ? `: ${tail}` : ""
  }

  private clearIdleUnload(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer)
    this.idleTimer = null
    this.lifecycle.cancelUnload()
  }

  private scheduleIdleUnload(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer)
    this.idleTimer = setTimeout(() => {
      this.idleTimer = null
      void this.requestUnload()
    }, idleUnloadMs)
    this.idleTimer.unref?.()
  }

  private async requestUnload(): Promise<boolean> {
    if (!this.lifecycle.requestUnload()) return false
    await this.terminate()
    return true
  }

  private async terminate(): Promise<void> {
    const target = this.proc
    this.proc = null
    this.liveModel = null
    this.baseUrl = null
    if (target && target.exitCode === null) {
      try { target.kill() } catch { /* already gone */ }
      await Promise.race([target.exited.catch(() => -1), sleep(5_000)])
      if (target.exitCode === null) {
        try { target.kill(9) } catch { /* already gone */ }
      }
    }
    this.lifecycle.markUnloaded()
  }
}
