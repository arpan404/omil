import { describe, expect, test } from "bun:test"
import { cleanLocal } from "../src/QwenCleanup"

interface CorpusCase {
  id: string
  rawTranscript: string
  intendedOutput: string
  acceptableAlternatives: string[]
  protectedSpans: string[]
  locale: string
  tags: string[]
  split: string
  mustEdit: boolean
}

const corpus = (await Bun.file(
  "../Tests/OmilCoreTests/Fixtures/corpus.json",
).json()) as { version: string; cases: CorpusCase[] }

describe(`corpus parity (${corpus.version}, deterministic TS engine — mirrors Swift, no model)`, () => {
  let exact = 0
  let harmful = 0
  for (const c of corpus.cases) {
    test(c.id, () => {
      const view = cleanLocal(c.rawTranscript, "clean")
      const ok = view.text === c.intendedOutput || c.acceptableAlternatives.includes(view.text)
      if (ok) exact++
      for (const span of c.protectedSpans) {
        if (!view.text.toLowerCase().includes(span.toLowerCase())) harmful++
      }
      if (c.mustEdit) {
        expect(view.acceptedEdits.length).toBeGreaterThan(0)
      }
      expect(ok).toBe(true)
    })
  }
  test("summary", () => {
    console.log(`corpus parity: exact=${exact}/${corpus.cases.length} harmful=${harmful}`)
    expect(harmful).toBe(0)
  })
})
