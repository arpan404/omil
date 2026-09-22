import { describe, expect, test } from "bun:test"
import { InferenceQueue } from "../src/InferenceQueue"

const deferred = <T>() => {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  const promise = new Promise<T>((ok, fail) => {
    resolve = ok
    reject = fail
  })
  return { promise, resolve, reject }
}

describe("inference queue", () => {
  test("runs jobs in FIFO order with one active worker", async () => {
    const queue = new InferenceQueue("transcription")
    const firstGate = deferred<string>()
    const order: string[] = []

    const first = queue.enqueue("device-a", async () => {
      order.push("a-start")
      const value = await firstGate.promise
      order.push("a-end")
      return value
    })
    const second = queue.enqueue("device-b", async () => {
      order.push("b-start")
      return "b"
    })

    await Promise.resolve()
    expect(queue.snapshot().active?.requestId).toBe("device-a")
    expect(queue.snapshot().pending.map((job) => job.requestId)).toEqual(["device-b"])
    firstGate.resolve("a")

    expect((await first).value).toBe("a")
    expect((await second).value).toBe("b")
    expect(order).toEqual(["a-start", "a-end", "b-start"])
    expect(queue.snapshot().completed).toBe(2)
  })

  test("a failed job does not block the next device", async () => {
    const queue = new InferenceQueue("cleanup")
    const first = queue.enqueue("device-a", async () => {
      throw new Error("failed")
    })
    const second = queue.enqueue("device-b", async () => "ready")

    await expect(first).rejects.toThrow("failed")
    expect((await second).value).toBe("ready")
    expect(queue.snapshot()).toMatchObject({ active: null, pending: [], completed: 2 })
  })

  test("each closure keeps its client preferences", async () => {
    const queue = new InferenceQueue("cleanup")
    const preferences = [
      { device: "phone", mode: "verbatim", model: "qwen-small" },
      { device: "mac", mode: "clean", model: "qwen-large" },
    ] as const

    const results = await Promise.all(preferences.map((preference) =>
      queue.enqueue(preference.device, async () => ({ ...preference }))))

    expect(results.map((result) => result.value)).toEqual([...preferences])
  })
})
