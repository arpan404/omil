export type ModelRuntimeState =
  | "unloaded"
  | "loading"
  | "ready"
  | "inUse"
  | "unloading"
  | "failed"

export interface ModelRuntimeSnapshot {
  readonly state: ModelRuntimeState
  readonly modelId: string | null
  readonly activeUses: number
  readonly unloadPending: boolean
  readonly error: string | null
}

export interface ModelLoadToken {
  readonly generation: number
  readonly modelId: string
}

/**
 * Small synchronous state machine used by model-process owners. It prevents a
 * late load completion or an unload request from tearing down a model that an
 * inference request is still using.
 */
export class ModelRuntimeLifecycle {
  private state: ModelRuntimeState = "unloaded"
  private modelId: string | null = null
  private activeUses = 0
  private unloadPending = false
  private error: string | null = null
  private generation = 0

  snapshot(): ModelRuntimeSnapshot {
    return {
      state: this.state,
      modelId: this.modelId,
      activeUses: this.activeUses,
      unloadPending: this.unloadPending,
      error: this.error,
    }
  }

  beginLoading(modelId: string): ModelLoadToken {
    this.generation += 1
    this.state = "loading"
    this.modelId = modelId
    this.activeUses = 0
    this.unloadPending = false
    this.error = null
    return { generation: this.generation, modelId }
  }

  markReady(token: ModelLoadToken): boolean {
    if (!this.matches(token) || this.state !== "loading") return false
    this.state = "ready"
    this.error = null
    return true
  }

  markFailed(token: ModelLoadToken, error: string): boolean {
    if (!this.matches(token)) return false
    this.state = "failed"
    this.activeUses = 0
    this.unloadPending = false
    this.error = error
    return true
  }

  beginUse(modelId: string): boolean {
    if (this.modelId !== modelId || (this.state !== "ready" && this.state !== "inUse")) {
      return false
    }
    this.activeUses += 1
    this.state = "inUse"
    this.unloadPending = false
    return true
  }

  /** Returns true when the process owner should unload now. */
  endUse(modelId: string): boolean {
    if (this.modelId !== modelId || this.activeUses === 0) return false
    this.activeUses -= 1
    if (this.activeUses > 0) return false
    if (this.unloadPending) {
      this.state = "unloading"
      return true
    }
    this.state = "ready"
    return false
  }

  /** Returns true when no active inference blocks an immediate unload. */
  requestUnload(): boolean {
    if (this.state === "unloaded") return false
    if (this.activeUses > 0) {
      this.unloadPending = true
      return false
    }
    this.state = "unloading"
    this.unloadPending = true
    return true
  }

  cancelUnload(): void {
    if (this.state === "unloading" && this.modelId) this.state = "ready"
    this.unloadPending = false
  }

  markUnloaded(): void {
    this.generation += 1
    this.state = "unloaded"
    this.modelId = null
    this.activeUses = 0
    this.unloadPending = false
    this.error = null
  }

  private matches(token: ModelLoadToken): boolean {
    return token.generation === this.generation && token.modelId === this.modelId
  }
}
