import { Effect } from "effect"
import {
  tokenize, fillerEdits, dictionaryEdits, numberEdits, validateEdit, render, verifyPreservation,
  RULES_VERSION, type ProposedEdit, type Abstention, type Snapshot, type Token,
} from "./Cleanup"
import { resolve as resolveDeterministic } from "./Resolver"
import { type LlamaHandle } from "./LlamaServer"
import { ModelError } from "./Models"
import { applyWritingStyle, expandSnippets, type WritingStyle } from "./Personalization"
import { PROSE_SYSTEM_PROMPT, proposeProseCleanup, validateProseCleanup, type CleanupContext, type WordChange } from "./ProseCleanup"

interface CleanedResult {
  readonly snapshotId: string
  readonly tokens: Token[]
  readonly text: string
  readonly acceptedEdits: ProposedEdit[]
  readonly rejected: Array<{ edit: ProposedEdit; reason: string }>
  readonly abstentions: Abstention[]
  readonly rulesVersion: string
  readonly appliedSnippetTriggers?: readonly string[]
  readonly writingStyle?: WritingStyle
  readonly proseChanges?: WordChange[]
}

export const DEFAULT_SYSTEM_PROMPT = PROSE_SYSTEM_PROMPT

interface CleanupInput {
  readonly text: string
  readonly mode: "verbatim" | "clean"
  readonly dictionary?: Record<string, string>
  readonly snippets?: Record<string, string>
  readonly style?: WritingStyle
  readonly context?: CleanupContext
}

interface StructuralPass {
  readonly snapshotId: string
  readonly tokens: Token[]
  readonly text: string
  readonly acceptedEdits: ProposedEdit[]
  readonly rejected: Array<{ edit: ProposedEdit; reason: string }>
  readonly abstentions: Abstention[]
}

/**
 * Deterministic filler removal, spoken-correction repair, dictionary and
 * number normalization, all through one validator and render. Falls back to
 * fewer repairs, then verbatim text, when the preservation check fails.
 */
function structuralPass(input: string, dictionary: Record<string, string>): StructuralPass {
  const snapshotId = crypto.randomUUID()
  const tokens = tokenize(input, snapshotId)
  const snap: Snapshot = { id: snapshotId, revision: 1, tokens }
  const abstentions: Abstention[] = []
  const fill = fillerEdits(snapshotId, tokens)
  abstentions.push(...fill.abstentions)
  const det = resolveDeterministic(snap)
  abstentions.push(...det.abstentions)

  const claimed = new Set<string>()
  const accepted: ProposedEdit[] = []
  const rejected: Array<{ edit: ProposedEdit; reason: string }> = []
  const consider = (edit: ProposedEdit) => {
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
  for (const e of dictionaryEdits(snap, dictionary, claimed)) consider(e)
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
      text = verbatim(input)
      abstentions.push({ reason: "missingEvidence", detail: "fallback to verbatim", tokenIds: [] })
    }
  }
  return { snapshotId, tokens, text, acceptedEdits: final, rejected, abstentions }
}

export const cleanWithQwen = (
  handle: LlamaHandle | null,
  input: CleanupInput,
  systemPrompt?: string,
): Effect.Effect<CleanedResult, ModelError, never> =>
  Effect.gen(function* () {
    if (input.mode === "verbatim") {
      const snapshotId = crypto.randomUUID()
      const personalized = expandSnippets(verbatim(input.text), input.snippets)
      return {
        snapshotId, tokens: tokenize(input.text, snapshotId), text: personalized.text,
        acceptedEdits: [], rejected: [], abstentions: [], rulesVersion: `${RULES_VERSION}/verbatim`,
        appliedSnippetTriggers: personalized.appliedSnippetTriggers,
        writingStyle: "automatic" as const,
      }
    }

    if (!handle) return yield* Effect.fail(new ModelError("cleanup model is not running"))

    // Deterministic repairs handle explicit spoken corrections before the
    // model sees complete prose. No token IDs are sent to the model.
    const structural = structuralPass(input.text, input.dictionary ?? {})
    const abstentions = [...structural.abstentions]
    let text = structural.text

    // One full-text model call fixes grammar and spelling, then a word diff
    // rejects changes to meaning-bearing content before any result reaches the client.
    let proseChanges: WordChange[] = []
    const prose = yield* proposeProseCleanup(handle, text, input.dictionary ?? {}, input.context, systemPrompt).pipe(
      Effect.catchAll((error) => {
        abstentions.push({ reason: "modelUnavailable", detail: `copyedit: ${error.reason}`, tokenIds: [] })
        return Effect.succeed(text)
      }),
    )
    const checked = validateProseCleanup(text, prose, input.dictionary, input.context)
    if (checked.ok) {
      text = prose
      proseChanges = checked.changes
    } else {
      abstentions.push({ reason: "unsafeProseRewrite", detail: checked.reason, tokenIds: [] })
    }

    const styled = applyWritingStyle(text, input.style)
    const personalized = expandSnippets(styled, input.snippets)
    return {
      snapshotId: structural.snapshotId,
      tokens: structural.tokens,
      acceptedEdits: structural.acceptedEdits,
      rejected: structural.rejected,
      abstentions,
      text: personalized.text,
      rulesVersion: `${RULES_VERSION}/deterministic+prose-3+personalization`,
      appliedSnippetTriggers: personalized.appliedSnippetTriggers,
      writingStyle: input.style ?? "automatic",
      proseChanges,
    }
  })

/** The deterministic pipeline alone, without a model call. */
export function cleanLocal(
  text: string,
  mode: "verbatim" | "clean" = "clean",
  dictionary: Record<string, string> = {},
): CleanedResult {
  if (mode === "verbatim") {
    const snapshotId = crypto.randomUUID()
    return {
      snapshotId, tokens: tokenize(text, snapshotId), text: verbatim(text),
      acceptedEdits: [], rejected: [], abstentions: [], rulesVersion: `${RULES_VERSION}/verbatim`,
    }
  }
  return { ...structuralPass(text, dictionary), rulesVersion: `${RULES_VERSION}/local` }
}

function verbatim(text: string): string {
  const t = text.trim().replace(/\s+/g, " ")
  if (!t) return t
  const cased = t.replace(/(^|[.?!:]\s+)([a-z])/g, (_m, p1: string, p2: string) => p1 + p2.toUpperCase())
  const first = cased.replace(/^[a-z]/, (c) => c.toUpperCase())
  return ".?!".includes(first[first.length - 1] ?? "") ? first : first + "."
}
