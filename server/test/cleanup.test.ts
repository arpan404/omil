import { describe, expect, test } from "bun:test"
import {
  tokenize, deriveNumber, fillerEdits, numberEdits, validateEdit, render,
  verifyPreservation, type Snapshot,
} from "../src/Cleanup"

const snap = (text: string): Snapshot => {
  const id = "test-snap"
  return { id, revision: 1, tokens: tokenize(text, id) }
}

describe("tokenizer (mirrors OmilCore)", () => {
  test("marks fillers, cues, numbers, protected negation", () => {
    const t = snap("um make it 42, sorry 21").tokens
    expect(t.find((x) => x.text === "um")?.kind).toBe("filler")
    expect(t.find((x) => x.text === "sorry")?.kind).toBe("cue")
    expect(t.find((x) => x.text === "42")?.kind).toBe("number")
    const not = snap("do not send").tokens.find((x) => x.text === "not")!
    expect(not.isProtected).toBe(true)
  })

  test("bare no between content is a cue; 'No worries' is not", () => {
    const t = snap("make it 42, no, keep it").tokens
    expect(t.filter((x) => x.text === "no").every((x) => x.kind === "cue")).toBe(true)
    const w = snap("No worries.").tokens
    expect(w[0].kind).not.toBe("cue")
  })

  test("quoted cues are content", () => {
    const t = snap('She said "sorry, make it 21."').tokens
    expect(t.find((x) => x.text === "sorry")?.kind).not.toBe("cue")
    expect(t.find((x) => x.text === "sorry")?.isProtected).toBe(true)
  })
})

describe("number normalization", () => {
  test("twenty-one -> 21, fifteen -> 15, fifty -> 50", () => {
    expect(deriveNumber(["twenty", "-", "one"])).toBe("21")
    expect(deriveNumber(["fifteen"])).toBe("15")
    expect(deriveNumber(["fifty"])).toBe("50")
  })
  test("non-numbers rejected", () => {
    expect(deriveNumber(["second", "one"])).toBeNull()
    expect(deriveNumber(["hello"])).toBeNull()
  })
  test("pipeline proposes normalization over kept tokens", () => {
    const s = snap("Make it twenty-one.")
    const edits = numberEdits(s, new Set())
    expect(edits.length).toBe(1)
    expect(edits[0].replacementText).toBe("21")
    expect(validateEdit(edits[0], s)).toEqual({ ok: true })
  })
})

describe("validator grounding", () => {
  test("Send 42 must not validate for 'Do not send 42. Send 21.'", () => {
    const s = snap("Do not send 42. Send 21.")
    // A hypothetical edit deleting negation + values without evidence:
    const byText = (w: string) => s.tokens.find((t) => t.text === w)!.id
    const bad = {
      editId: "e1", snapshotId: s.id, op: "deleteFiller" as const,
      targetTokenIds: [byText("not")], evidenceTokenIds: [],
      reason: "x", ruleVersion: "t",
    }
    expect(validateEdit(bad, s).ok).toBe(false)
  })

  test("protected number needs repair evidence", () => {
    const s = snap("make it 42, sorry 21")
    const n42 = s.tokens.find((t) => t.text === "42")!.id
    const noEvidence = {
      editId: "e1", snapshotId: s.id, op: "replaceFromSource" as const,
      targetTokenIds: [n42], evidenceTokenIds: [],
      reason: "x", ruleVersion: "t",
    }
    expect(validateEdit(noEvidence, s).ok).toBe(false)
  })

  test("replacement must be grounded in an evidence span", () => {
    const s = snap("make it 42, sorry 21")
    const ids = s.tokens.map((t) => t.id)
    const invented = {
      editId: "e1", snapshotId: s.id, op: "replaceFromSource" as const,
      targetTokenIds: [ids[2]], evidenceTokenIds: [ids[3], ids[4]],
      reason: "x", ruleVersion: "t", replacementText: "999",
    }
    expect(validateEdit(invented, s).ok).toBe(false)
  })

  test("stale snapshot rejected", () => {
    const s = snap("make it 42")
    const e = {
      editId: "e1", snapshotId: "other", op: "deleteRepeat" as const,
      targetTokenIds: [s.tokens[0].id], evidenceTokenIds: [],
      reason: "x", ruleVersion: "t",
    }
    expect(validateEdit(e, s).ok).toBe(false)
  })
})

describe("render + preservation", () => {
  test("repair render drops cue-adjacent comma", () => {
    const s = snap("make it 42, sorry 21")
    const byText = (w: string) => s.tokens.find((t) => t.text === w)!.id
    const repair = {
      editId: "e1", snapshotId: s.id, op: "replaceFromSource" as const,
      targetTokenIds: [byText("42"), byText("sorry")],
      evidenceTokenIds: [byText("21")],
      reason: "cue", ruleVersion: "t",
    }
    expect(validateEdit(repair, s)).toEqual({ ok: true })
    const out = render(s, [repair])
    expect(out).toBe("Make it 21.")
    expect(verifyPreservation(s, [repair], out)).toBe(true)
  })

  test("preservation catches over-editing", () => {
    const s = snap("Do not send 42. Send 21.")
    // Pretend everything but 'Send 42' was deleted: preservation must fail
    // because kept content tokens are missing from the output.
    const keep = s.tokens.filter((t) => t.text === "Send" || t.text === "42").map((t) => t.id)
    const dropIds = s.tokens.map((t) => t.id).filter((id) => !keep.includes(id))
    const fake = {
      editId: "e1", snapshotId: s.id, op: "replaceFromSource" as const,
      targetTokenIds: dropIds, evidenceTokenIds: keep,
      reason: "x", ruleVersion: "t",
    }
    expect(verifyPreservation(s, [fake], "Send 42.")).toBe(false)
  })
})

describe("filler rules", () => {
  test("standalone um deleted; literal 'word um' preserved", () => {
    const a = snap("um make it 42")
    expect(fillerEdits(a.id, a.tokens).edits.length).toBe(1)
    const b = snap("Do not remove the word um.")
    const r = fillerEdits(b.id, b.tokens)
    expect(r.edits.length).toBe(0)
    expect(r.abstentions.length).toBe(1)
  })
})
