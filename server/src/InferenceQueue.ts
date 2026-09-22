export interface QueueJobInfo {
  readonly jobId: string
  readonly requestId: string
  readonly enqueuedAt: number
  readonly startedAt: number | null
}

export interface QueueSnapshot {
  readonly name: string
  readonly active: QueueJobInfo | null
  readonly pending: ReadonlyArray<QueueJobInfo>
  readonly completed: number
}

export interface QueuedResult<T> {
  readonly value: T
  readonly jobId: string
  readonly requestId: string
  readonly positionAtEnqueue: number
  readonly waitedMs: number
}

interface PendingJob<T> extends QueueJobInfo {
  readonly positionAtEnqueue: number
  readonly run: () => Promise<T>
  readonly resolve: (value: QueuedResult<T>) => void
  readonly reject: (error: unknown) => void
}

/**
 * A FIFO, single-worker queue for one inference resource. Work closures keep
 * each request's model and cleanup preferences, even if global settings change
 * before the job starts.
 */
export class InferenceQueue {
  private readonly pending: Array<PendingJob<unknown>> = []
  private active: QueueJobInfo | null = null
  private draining = false
  private completed = 0

  constructor(readonly name: string) {}

  enqueue<T>(requestId: string, run: () => Promise<T>): Promise<QueuedResult<T>> {
    const enqueuedAt = Date.now()
    const positionAtEnqueue = this.pending.length + (this.active ? 1 : 0)
    return new Promise<QueuedResult<T>>((resolve, reject) => {
      this.pending.push({
        jobId: crypto.randomUUID(),
        requestId,
        enqueuedAt,
        startedAt: null,
        positionAtEnqueue,
        run,
        resolve: resolve as (value: QueuedResult<unknown>) => void,
        reject,
      })
      void this.drain()
    })
  }

  snapshot(): QueueSnapshot {
    return {
      name: this.name,
      active: this.active ? { ...this.active } : null,
      pending: this.pending.map(({ jobId, requestId, enqueuedAt, startedAt }) => ({
        jobId, requestId, enqueuedAt, startedAt,
      })),
      completed: this.completed,
    }
  }

  private async drain(): Promise<void> {
    if (this.draining) return
    this.draining = true
    try {
      for (;;) {
        const job = this.pending.shift()
        if (!job) break
        const startedAt = Date.now()
        this.active = {
          jobId: job.jobId,
          requestId: job.requestId,
          enqueuedAt: job.enqueuedAt,
          startedAt,
        }
        try {
          const value = await job.run()
          job.resolve({
            value,
            jobId: job.jobId,
            requestId: job.requestId,
            positionAtEnqueue: job.positionAtEnqueue,
            waitedMs: Math.max(0, startedAt - job.enqueuedAt),
          })
        } catch (error) {
          job.reject(error)
        } finally {
          this.completed += 1
          this.active = null
        }
      }
    } finally {
      this.draining = false
      if (this.pending.length > 0) void this.drain()
    }
  }
}
