import { afterEach, describe, expect, test } from "bun:test"
import { ManagedSidecar } from "../src/Sidecar"

const FAKE_SERVER = `
let health = 0
const server = Bun.serve({ hostname: "127.0.0.1", port: Number(process.argv[1]), fetch(req) {
  const path = new URL(req.url).pathname
  if (path === "/health") { health++; return Response.json({ status: "ok" }) }
  if (path === "/health-count") return Response.json({ health })
  if (path === "/exit") { setTimeout(() => process.exit(3), 10); return new Response("bye") }
  return new Response("not found", { status: 404 })
} })
`

const freePort = () => {
  const probe = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response() })
  const port = probe.port!
  probe.stop(true)
  return port
}

const waitFor = async (condition: () => boolean, ms = 5_000) => {
  const deadline = Date.now() + ms
  while (!condition() && Date.now() < deadline) await Bun.sleep(20)
  return condition()
}

let sidecar: ManagedSidecar | null = null
afterEach(() => sidecar?.stop())

describe("managed sidecar", () => {
  test("starts promptly, reuses a ready process without a health request, and recovers from a crash", async () => {
    const port = freePort()
    let launches = 0
    const launch = async () => {
      launches++
      return { port, argv: [process.execPath, "-e", FAKE_SERVER, String(port)] }
    }
    sidecar = new ManagedSidecar({ name: "fake", readyTimeoutMs: 10_000, captureStderr: true })
    expect(sidecar.memoryState("m")).toBe("unloaded")

    const started = performance.now()
    const first = await sidecar.acquire("m", launch)
    expect(performance.now() - started).toBeLessThan(1_500)
    expect(sidecar.memoryState("m")).toBe("inUse")
    first.release()
    expect(sidecar.memoryState("m")).toBe("ready")

    const healthBefore = (await (await fetch(`http://127.0.0.1:${port}/health-count`)).json()).health
    const second = await sidecar.acquire("m", launch)
    second.release()
    const healthAfter = (await (await fetch(`http://127.0.0.1:${port}/health-count`)).json()).health
    expect(launches).toBe(1)
    expect(healthAfter).toBe(healthBefore)

    await fetch(`http://127.0.0.1:${port}/exit`)
    expect(await waitFor(() => sidecar!.memoryState("m") === "unloaded")).toBe(true)
    expect(sidecar.live()).toBeNull()

    const third = await sidecar.acquire("m", launch)
    third.release()
    expect(launches).toBe(2)
    expect(sidecar.live()).toBe("m")

    expect(await sidecar.unload()).toBe(true)
    expect(sidecar.snapshot().state).toBe("unloaded")
    expect(await fetch(`http://127.0.0.1:${port}/health`).then(() => true, () => false)).toBe(false)
  }, 20_000)

  test("restarts for a different model and reports a failed start", async () => {
    const port = freePort()
    const launch = async () => ({ port, argv: [process.execPath, "-e", FAKE_SERVER, String(port)] })
    sidecar = new ManagedSidecar({ name: "fake", readyTimeoutMs: 10_000, captureStderr: true })
    ;(await sidecar.acquire("a", launch)).release()
    ;(await sidecar.acquire("b", launch)).release()
    expect(sidecar.memoryState("a")).toBe("unloaded")
    expect(sidecar.memoryState("b")).toBe("ready")
    sidecar.stop()

    const failing = async () => ({ port, argv: [process.execPath, "-e", "console.error('bad model'); process.exit(2)"] })
    const error = await sidecar.acquire("c", failing).catch((reason) => reason)
    expect(error.reason).toContain("exited early with status 2")
    expect(error.reason).toContain("bad model")
    expect(sidecar.memoryState("c")).toBe("failed")
  }, 20_000)
})

test("a stop during model preparation does not leave a process behind", async () => {
  const port = freePort()
  let release!: () => void
  const gate = new Promise<void>((resolve) => { release = resolve })
  const local = new ManagedSidecar({ name: "fake", readyTimeoutMs: 10_000, captureStderr: true })
  const pending = local.acquire("m", async () => {
    await gate
    return { port, argv: [process.execPath, "-e", FAKE_SERVER, String(port)] }
  }).catch((error) => error)
  local.stop()
  release()
  expect((await pending).reason).toContain("cancelled")
  await Bun.sleep(300)
  expect(await fetch(`http://127.0.0.1:${port}/health`).then(() => true, () => false)).toBe(false)
  expect(local.snapshot().state).toBe("unloaded")
})
