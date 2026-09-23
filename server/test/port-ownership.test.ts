import { expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"

test("starting the API leaves another process on the model port running", async () => {
  const dataDir = await mkdtemp(path.join(tmpdir(), "omil-port-test-"))
  const listener = Bun.spawn([
    process.execPath,
    "-e",
    "const server = Bun.serve({ hostname: '127.0.0.1', port: 0, fetch: () => new Response('other app') }); console.log(server.port)",
  ], { stdout: "pipe", stderr: "pipe" })

  try {
    const reader = listener.stdout.getReader()
    let output = ""
    while (!output.includes("\n")) {
      const chunk = await reader.read()
      if (chunk.done) throw new Error("other listener failed to start")
      output += new TextDecoder().decode(chunk.value)
    }
    reader.releaseLock()
    const modelPort = Number(output.trim())

    const probe = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("probe") })
    const apiPort = probe.port
    probe.stop()

    const backend = Bun.spawn([process.execPath, "src/main.ts"], {
      cwd: path.join(import.meta.dir, ".."),
      env: {
        ...process.env,
        OMIL_HOST: "127.0.0.1",
        OMIL_PORT: String(apiPort),
        OMIL_LLAMA_PORT: String(modelPort),
        OMIL_DATA: dataDir,
        OMIL_PARENT_PID: "0",
      },
      stdout: "pipe",
      stderr: "pipe",
    })
    try {
      let ready = false
      for (let attempt = 0; attempt < 40; attempt++) {
        if (backend.exitCode !== null) break
        try {
          ready = (await fetch(`http://127.0.0.1:${apiPort}/v1/health`)).ok
        } catch { /* server is still starting */ }
        if (ready) break
        await Bun.sleep(100)
      }
      expect(ready).toBe(true)
      expect(listener.exitCode).toBeNull()
      expect((await fetch(`http://127.0.0.1:${modelPort}`)).status).toBe(200)
    } finally {
      backend.kill()
      await backend.exited
    }
  } finally {
    listener.kill()
    await listener.exited
    await rm(dataDir, { recursive: true, force: true })
  }
}, 10_000)
