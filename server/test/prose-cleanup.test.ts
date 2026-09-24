import { describe, expect, test } from "bun:test"
import { Effect } from "effect"
import { cleanLocal, cleanWithQwen } from "../src/QwenCleanup"
import { stripMarkdownFormatting, validateProseCleanup, wordChanges } from "../src/ProseCleanup"

describe("prose cleanup", () => {
  test("removes model-added Markdown without changing URLs or ordinary punctuation", () => {
    expect(stripMarkdownFormatting("# **The system** should check https://example.com/my_file.")).toBe(
      "The system should check https://example.com/my_file.",
    )
    expect(stripMarkdownFormatting("```text\nThe **first** one is ready.\n```")).toBe(
      "The first one is ready.",
    )
  })

  test("accepts local grammar and spelling edits with a word diff", () => {
    const before = "kubernetees seem to work but its setting are wrong"
    const after = "Kubernetes seems to work, but its settings are wrong."
    const result = validateProseCleanup(before, after)
    expect(result.ok).toBe(true)
    expect(wordChanges(before, after)).toEqual([
      { before: ["kubernetees", "seem"], after: ["Kubernetes", "seems"] },
      { before: ["setting"], after: ["settings"] },
    ])
  })

  test("rejects changed negation, names, quotes, and invented content", () => {
    const unsafe = [
      ["Do not send 42 copies.", "Send 42 copies."],
      ["Send the report to Bob.", "Send the report to Rob."],
      ['Write "kubectl delete" exactly.', 'Write "kubectl apply" exactly.'],
      ["The cluster is ready.", "The production cluster is ready."],
    ]
    for (const [before, after] of unsafe) {
      expect(validateProseCleanup(before, after).ok).toBe(false)
    }
  })

  test("accepts a misheard term only when nearby text establishes it", () => {
    const before = "Please check cooper net ease settings."
    const after = "Please check Kubernetes settings."
    expect(validateProseCleanup(before, after).ok).toBe(false)
    expect(validateProseCleanup(before, after, {}, {
      before: "The deployment runs on Kubernetes.", after: "",
    }).ok).toBe(true)
    expect(validateProseCleanup(before, "Please check Kubernetes settings and restart production.", {}, {
      before: "The deployment runs on Kubernetes.", after: "",
    }).ok).toBe(false)
  })

  test("allows a context-supported word correction without an app-specific vocabulary", () => {
    expect(validateProseCleanup(
      "The input fields in snippets and disney are broken.",
      "The input fields in snippets and dictionary are broken.",
    ).ok).toBe(true)
    expect(validateProseCleanup(
      "I watched a Disney movie.",
      "I watched a Dictionary movie.",
    ).ok).toBe(false)
    expect(validateProseCleanup(
      "The kubenerties deployment failed.",
      "The Kubernetes deployment failed.",
    ).ok).toBe(true)
    expect(validateProseCleanup(
      "I spoke with Disney about the fields.",
      "I spoke with Dictionary about the fields.",
    ).ok).toBe(false)
  })

  test("applies a confirmed spoken form before the model copyedit", () => {
    const result = cleanLocal("deploy to cube netties", "clean", { "cube netties": "Kubernetes" })
    expect(result.text).toBe("Deploy to Kubernetes.")
    expect(result.acceptedEdits.some((edit) => edit.op === "dictionarySubstitution")).toBe(true)
  })

  test("keeps ordinary number words and accepts removal of an abandoned repeated start", () => {
    expect(cleanLocal("the one I sent before and the second one").text)
      .toBe("The one I sent before and the second one.")
    expect(validateProseCleanup(
      "I sent you, I mean, I sent you the previous message.",
      "I sent you the previous message.",
    ).ok).toBe(true)
    expect(validateProseCleanup("The one I sent.", "The 1 I sent.").ok).toBe(false)
  })

  test("corrects grammar and technical-term casing after structural repair", async () => {
    let calls = 0
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        calls++
        const body = await request.json() as { messages: Array<{ content: string }> }
        expect(body.messages[0]?.content).toContain("edit a speech transcript")
        expect(body.messages[0]?.content).not.toContain("targetTokenIds")
        expect(body.messages[0]?.content).not.toContain("Kubernetes")
        expect(body).not.toHaveProperty("response_format")
        return Response.json({ choices: [{ message: {
          content: "Kubernetes seems to like Kubernetes, but its configuration is wrong.",
        } }] })
      },
    })
    try {
      const result = await Effect.runPromise(cleanWithQwen(
        { baseUrl: `http://localhost:${server.port}`, modelId: "test" },
        { text: "kubernetes seem to like kubernetes but its configuration are wrong", mode: "clean" },
      ))
      expect(result.text).toBe("Kubernetes seems to like Kubernetes, but its configuration is wrong.")
      expect(calls).toBe(1)
    } finally {
      await server.stop()
    }
  })

  test("rejects a fluent rewrite that changes a number", async () => {
    const server = Bun.serve({
      port: 0,
      fetch: async (request) => {
        const body = await request.json() as { messages: Array<{ content: string }> }
        expect(body).not.toHaveProperty("response_format")
        return Response.json({ choices: [{ message: { content: "Send 21 copies to Bob." } }] })
      },
    })
    try {
      const result = await Effect.runPromise(cleanWithQwen(
        { baseUrl: `http://localhost:${server.port}`, modelId: "test" },
        { text: "Send 42 copies to Bob", mode: "clean" },
      ))
      expect(result.text).toBe("Send 42 copies to Bob.")
      expect(result.abstentions.some((item) => item.reason === "unsafeProseRewrite")).toBe(true)
    } finally {
      await server.stop()
    }
  })
})
