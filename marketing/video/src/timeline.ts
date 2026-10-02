// Everything is laid out in bars of the music (public/music/track.wav, "Driving Ambition",
// ~99.8 BPM, built by scripts/music.py). Each cue lands on a bar or beat.
import timing from "./voice-timing.json";

export const FPS = 30;
export const BEAT_S = 0.60128;
export const BAR_S = 4 * BEAT_S;
export const f = (s: number) => Math.round(s * FPS);
/** Seconds at bar b (fractional bars allowed). */
export const bar = (b: number) => b * BAR_S;
/** Frame at bar b. */
export const barF = (b: number) => f(bar(b));
export const END = barF(22.5);

// The story, in bars. The screen sequence is one continuous take.
export const SCENE = {
  hook: { from: 0, to: 1.5 }, // the problem
  title: { from: 1.5, to: 3 }, // the answer
  screen: { from: 3, to: 14 }, // how it works → why it's smart → make it yours
  everywhere: { from: 14, to: 19 }, // pair with the Mac, then the keyboard on iPhone and iPad
  trust: { from: 19, to: 20 }, // private by design (music peak)
  outro: { from: 20, to: 22.5 }, // call to action (music's ending)
} as const;
export const PUSH_FRAMES = 20;

const beatAfter = (s: number) => Math.ceil(s / BEAT_S - 1e-6) * BEAT_S;

// ---------------------------------------------------------------- the dictation (absolute seconds)

export const VOICE_END = timing.end;
const keyDown = bar(3) + BEAT_S;
const voice = keyDown + 0.2;
const keyUp = voice + VOICE_END + 0.25;
const cleaning = keyUp + 0.35;
const inserting = cleaning + 1.0;
const inserted = inserting + 0.12; // AX insertion is instant
const done = beatAfter(inserted + 0.15);

export const DEMO = {
  pillIn: bar(3) + 0.15,
  keyDown,
  preparing: keyDown,
  recording: keyDown + 0.22,
  voice,
  keyUp,
  cleaning,
  inserting,
  inserted,
  done,
  send: done + 2 * BEAT_S,
  typing: done + 2.6 * BEAT_S,
  reply: bar(7),
  // the Omil window
  windowOpen: bar(7.5),
  changesClick: bar(9),
  verbatimClick: bar(10),
  snippets: bar(11),
  snippetAdd: bar(12),
  dictionary: bar(12.5),
  correctionAdd: bar(13.4),
} as const;

const DROPPED = new Set(["um", "umm", "uh", "so", "friday", "no", "wait"]);
const bare = (w: string) => w.toLowerCase().replace(/[^a-z]/g, "");
export const VOICE_WORDS: { text: string; at: number; drop?: boolean; clean?: string }[] = timing.words.map((w, i, all) => {
  const drop = DROPPED.has(bare(w.text));
  const lastKept = !drop && all.slice(i + 1).every((n) => DROPPED.has(bare(n.text)));
  const clean = lastKept ? w.text.replace(/[^A-Za-z]+$/, "") + "." : w.text.replace(/[^A-Za-z]+$/, "");
  return { text: w.text, at: w.at, drop, clean: drop || clean === w.text ? undefined : clean };
});

export const RAW_TEXT = "Um, so I think we should, uh, ship it on Friday. No wait, Thursday.";
export const CLEAN_TEXT = "I think we should ship it on Thursday.";

export type DiffToken = { text: string; kind: "same" | "added" | "removed" };

/** TranscriptDiff.tokens (OmilCore): LCS over word and punctuation tokens. */
export const diffTokens = (raw: string, cleaned: string): DiffToken[] => {
  const tok = (t: string) => t.match(/[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*|[^\p{L}\p{N}\s]/gu) ?? [];
  const a = tok(raw);
  const b = tok(cleaned);
  const n = a.length;
  const m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const out: DiffToken[] = [];
  let i = 0;
  let j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) {
      out.push({ text: a[i], kind: "same" });
      i++;
      j++;
    } else if (j < m && (i >= n || dp[i][j + 1] > dp[i + 1][j])) out.push({ text: b[j++], kind: "added" });
    else out.push({ text: a[i++], kind: "removed" });
  }
  return out;
};

/** TranscriptDiff.lines: the original line (removals marked) and the cleaned line (additions marked). */
export const diffLines = (raw: string, cleaned: string) => {
  const all = diffTokens(raw, cleaned);
  return { original: all.filter((t) => t.kind !== "added"), cleaned: all.filter((t) => t.kind !== "removed") };
};
export const attaches = (t: string) => t.length === 1 && ".,!?;:)]}%”’".includes(t);
