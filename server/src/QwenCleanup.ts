import { Effect } from "effect"
import {
  tokenize, fillerEdits, numberEdits, validateEdit, render, verifyPreservation,
  RULES_VERSION, type ProposedEdit, type Abstention, type Snapshot, type Token,
} from "./Cleanup"
import { resolve as resolveDeterministic } from "./Resolver"
import { chatJson, type LlamaHandle, type ChatMessage } from "./LlamaServer"
import { ModelError } from "./Models"
import { applyWritingStyle, expandSnippets, type WritingStyle } from "./Personalization"

export interface CleanedResult {
  readonly snapshotId: string
  readonly tokens: Token[]
  readonly text: string
  readonly acceptedEdits: ProposedEdit[]
  readonly rejected: Array<{ edit: ProposedEdit; reason: string }>
  readonly abstentions: Abstention[]
  readonly rulesVersion: string
  readonly appliedSnippetTriggers?: readonly string[]
  readonly writingStyle?: WritingStyle
}

const SYSTEM_PROMPT = `You repair spoken dictation transcripts. You NEVER rewrite freely: you output ONLY grounded edit operations over the given tokens, or no edits.

Token IDs are stable references like "a1f3c9-4". Quoted text and ordinary apologies ("I am sorry about the delay") are CONTENT, never cues. Treat "sorry", "I mean", "actually", "no" as POSSIBLE cues for ordinary replacements only: they authorize an edit ONLY with a type-compatible reparandum on the left and repair on the right (numbers replace numbers, days replace days, names replace names). "or maybe" / "or" alone is ambiguity: do nothing. Negation ("not", "never", "don't") must survive unless the repair restates it. Output NO edits for reversals ("keep ..."), restarts ("scratch that"), subject restatements ("actually Bob 24"), or mirrored restatements — those are handled deterministically. When evidence is insufficient, output zero edits.

Reply with a single JSON object: {"edits": [{"op": "replaceFromSource", "targetTokenIds": [...], "evidenceTokenIds": [...], "reason": "..."}]}.
- Delete the reparandum + cue (+ redundant restated verbs); the repair value STAYS IN PLACE, so replacementText is omitted.
- Cue/filler tokens are removed only as part of a validated repair. Never invent words.

Example — replacement. Tokens:
a-0 [word] "make" / a-1 [word] "it" / a-2 [number,protected] "42" / a-3 [punctuation] "," / a-4 [cue] "sorry" / a-5 [number,protected] "21"
Correct output: {"edits": [{"op": "replaceFromSource", "targetTokenIds": ["a-2", "a-4"], "evidenceTokenIds": ["a-5", "a-4"], "reason": "sorry replaces 42 with 21"}]}
("42" and the cue are deleted; "21" stays in place.)

Example — preserve. "Do not send 42. Send 21." has NO cue (no sorry/actually cue between compatible values). Correct output: {"edits": []}
"I am sorry about the delay." — "sorry" has no number/name/day on its left, so it is an ordinary apology. Correct output: {"edits": []}`

export const DEFAULT_SYSTEM_PROMPT = SYSTEM_PROMPT

export interface CleanupInput {
  readonly text: string
  readonly mode: "verbatim" | "clean"
  readonly dictionary?: Record<string, string>
  readonly snippets?: Record<string, string>
  readonly style?: WritingStyle
}

export const cleanWithQwen = (
  handle: LlamaHandle | null,
  input: CleanupInput,
  systemPrompt?: string,
): Effect.Effect<CleanedResult, ModelError, never> =>
  Effect.gen(function* () {
    const snapshotId = crypto.randomUUID()
    const tokens = tokenize(input.text, snapshotId)
    const snap: Snapshot = { id: snapshotId, revision: 1, tokens }

    if (input.mode === "verbatim") {
      const personalized = expandSnippets(verbatim(input.text), input.snippets)
      return {
        snapshotId, tokens, text: personalized.text,
        acceptedEdits: [], rejected: [], abstentions: [], rulesVersion: `${RULES_VERSION}/verbatim`,
        appliedSnippetTriggers: personalized.appliedSnippetTriggers,
        writingStyle: "automatic" as const,
      }
    }

    if (!handle) return yield* Effect.fail(new ModelError("cleanup model is not running"))

    const abstentions: Abstention[] = []
    const fill = fillerEdits(snapshotId, tokens)
    abstentions.push(...fill.abstentions)

    // Deterministic repairs first (restarts, ordinary cues, keep-reversals,
    // scoped and structural): Qwen competes for the same targets and loses
    // conflicts, so validated deterministic edits always win ties.
    const det = resolveDeterministic(snap)
    abstentions.push(...det.abstentions)

    // Qwen proposes repairs; invalid proposals are dropped, never applied loosely.
    const proposed: ProposedEdit[] = yield* proposeRepairs(handle, snap, input.dictionary ?? {}, systemPrompt).pipe(
      Effect.catchAll((e) => {
        abstentions.push({
          reason: "modelUnavailable",
          detail: String((e as { reason?: unknown }).reason ?? e),
          tokenIds: [],
        })
        return Effect.succeed([] as ProposedEdit[])
      }),
    )

    const claimed = new Set<string>()
    const accepted: ProposedEdit[] = []
    const rejected: Array<{ edit: ProposedEdit; reason: string }> = []
    const consider = (edit: ProposedEdit) => {
      if (edit.snapshotId !== snapshotId) {
        rejected.push({ edit, reason: "stale snapshot" })
        abstentions.push({ reason: "staleSnapshot", detail: "proposal references wrong snapshot", tokenIds: edit.targetTokenIds })
        return
      }
      if (edit.targetTokenIds.some((t) => claimed.has(t))) {
        rejected.push({ edit, reason: "conflicting edit" })
        abstentions.push({ reason: "conflictingEdits", detail: "target already claimed", tokenIds: edit.targetTokenIds })
        return
      }
      const v = validateEdit(edit, snap, input.dictionary)
      if (!v.ok) {
        rejected.push({ edit, reason: v.reason })
        abstentions.push({ reason: "invalidProposal", detail: v.reason, tokenIds: edit.targetTokenIds })
        return
      }
      accepted.push(edit)
      for (const t of edit.targetTokenIds) claimed.add(t)
    }
    for (const e of [...fill.edits, ...det.edits, ...proposed]) consider(e)

    const kept = new Set(accepted.flatMap((e) => e.targetTokenIds))
    for (const e of numberEdits(snap, kept)) consider(e)

    let final = accepted
    let text = render(snap, final)
    if (!verifyPreservation(snap, final, text)) {
      final = accepted.filter((e) => e.op === "deleteFiller" || e.op === "deleteRepeat" || e.op === "normalizeNumber")
      text = render(snap, final)
      abstentions.push({ reason: "ambiguousScope", detail: "preservation check failed; repairs dropped", tokenIds: [] })
      if (!verifyPreservation(snap, final, text)) {
        final = []
        text = verbatim(input.text)
        abstentions.push({ reason: "missingEvidence", detail: "fallback to verbatim", tokenIds: [] })
      }
    }

    const styled = applyWritingStyle(text, input.style)
    const personalized = expandSnippets(styled, input.snippets)
    return {
      snapshotId, tokens,
      acceptedEdits: final, rejected, abstentions,
      text: personalized.text,
      rulesVersion: `${RULES_VERSION}/qwen-hybrid+personalization`,
      appliedSnippetTriggers: personalized.appliedSnippetTriggers,
      writingStyle: input.style ?? "automatic",
    }
  })

/**
 * Local-only pipeline (no model call): deterministic filler + resolver +
 * normalization through the same validator and render. Used by tests and as
 * the offline fallback. Qwen proposals slot into `consider()` above.
 */
export function cleanLocal(
  text: string,
  mode: "verbatim" | "clean" = "clean",
  dictionary: Record<string, string> = {},
): CleanedResult {
  const snapshotId = crypto.randomUUID()
  const tokens = tokenize(text, snapshotId)
  const snap: Snapshot = { id: snapshotId, revision: 1, tokens }
  if (mode === "verbatim") {
    return {
      snapshotId, tokens, text: verbatim(text),
      acceptedEdits: [], rejected: [], abstentions: [], rulesVersion: `${RULES_VERSION}/verbatim`,
    }
  }
  const abstentions: Abstention[] = []
  const fill = fillerEdits(snapshotId, tokens)
  abstentions.push(...fill.abstentions)
  const det = resolveDeterministic(snap)
  abstentions.push(...det.abstentions)
  const claimed = new Set<string>()
  const accepted: ProposedEdit[] = []
  const rejected: Array<{ edit: ProposedEdit; reason: string }> = []
  const consider = (edit: ProposedEdit) => {
    if (edit.snapshotId !== snapshotId) {
      rejected.push({ edit, reason: "stale snapshot" })
      return
    }
    if (edit.targetTokenIds.some((t) => claimed.has(t))) {
      rejected.push({ edit, reason: "conflicting edit" })
      abstentions.push({ reason: "conflictingEdits", detail: "target already claimed", tokenIds: edit.targetTokenIds })
      return
    }
    const v = validateEdit(edit, snap, dictionary)
    if (!v.ok) {
      rejected.push({ edit, reason: v.reason })
      abstentions.push({ reason: "invalidProposal", detail: v.reason, tokenIds: edit.targetTokenIds })
      return
    }
    accepted.push(edit)
    for (const t of edit.targetTokenIds) claimed.add(t)
  }
  for (const e of [...fill.edits, ...det.edits]) consider(e)
  const kept = new Set(accepted.flatMap((e) => e.targetTokenIds))
  for (const e of numberEdits(snap, kept)) consider(e)
  let final = accepted
  let outText = render(snap, final)
  if (!verifyPreservation(snap, final, outText)) {
    final = accepted.filter((e) => e.op === "deleteFiller" || e.op === "deleteRepeat" || e.op === "normalizeNumber")
    outText = render(snap, final)
    abstentions.push({ reason: "ambiguousScope", detail: "preservation check failed; repairs dropped", tokenIds: [] })
    if (!verifyPreservation(snap, final, outText)) {
      final = []
      outText = verbatim(text)
      abstentions.push({ reason: "missingEvidence", detail: "fallback to verbatim", tokenIds: [] })
    }
  }
  return {
    snapshotId, tokens, text: outText,
    acceptedEdits: final, rejected, abstentions,
    rulesVersion: `${RULES_VERSION}/local`,
  }
}

interface RawProposal {
  op?: string
  targetTokenIds?: string[]
  evidenceTokenIds?: string[]
  replacementText?: string
  candidateValue?: string
  replacementAnchor?: number
  reason?: string
}

function proposeRepairs(
  handle: LlamaHandle,
  snap: Snapshot,
  dictionary: Record<string, string>,
  systemPrompt?: string,
): Effect.Effect<ProposedEdit[], ModelError, never> {
  const tokenLines = snap.tokens.map((t) => `${t.id} [${t.kind}${t.isProtected ? ",protected" : ""}] "${t.text}"`).join("\n")
  const messages: ChatMessage[] = [
    { role: "system", content: systemPrompt ?? SYSTEM_PROMPT },
    {
      role: "user",
      content: `Transcript tokens:\n${tokenLines}\n\nRaw: "${snap.tokens.map((t) => t.text).join(" ")}"\nDictionary (confirmed only): ${JSON.stringify(dictionary)}\nReply with the JSON object.`,
    },
  ]
  return Effect.gen(function* () {
    const raw = (yield* chatJson(handle, messages, 1024)) as { edits?: RawProposal[] }
    if (process.env.OMIL_DEBUG === "1") {
      console.log("QWEN raw edits:", JSON.stringify(raw.edits ?? raw).slice(0, 2000))
    }
    const edits: ProposedEdit[] = []
    for (const p of raw.edits ?? []) {
      if (p.op !== "replaceFromSource" && p.op !== "selectCandidate") continue
      if (!Array.isArray(p.targetTokenIds) || p.targetTokenIds.length === 0) continue
      edits.push({
        editId: crypto.randomUUID(),
        snapshotId: snap.id,
        op: p.op,
        targetTokenIds: p.targetTokenIds.filter((t): t is string => typeof t === "string"),
        evidenceTokenIds: Array.isArray(p.evidenceTokenIds) ? p.evidenceTokenIds.filter((t): t is string => typeof t === "string") : [],
        candidateValue: typeof p.candidateValue === "string" ? p.candidateValue : undefined,
        reason: typeof p.reason === "string" ? p.reason : "qwen proposal",
        ruleVersion: "qwen3-4b",
        replacementText: typeof p.replacementText === "string" ? p.replacementText : undefined,
        replacementAnchor: typeof p.replacementAnchor === "number" ? p.replacementAnchor : undefined,
      })
    }
    return edits
  })
}

function verbatim(text: string): string {
  const t = text.trim().replace(/\s+/g, " ")
  if (!t) return t
  const cased = t.replace(/(^|[.?!:]\s+)([a-z])/g, (_m, p1: string, p2: string) => p1 + p2.toUpperCase())
  const first = cased.replace(/^[a-z]/, (c) => c.toUpperCase())
  return ".?!".includes(first[first.length - 1] ?? "") ? first : first + "."
}
