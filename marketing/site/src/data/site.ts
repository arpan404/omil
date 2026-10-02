// Facts the page states. Keep them in line with the repository README.
import { dmgOf, GITHUB_URL, LATEST_RELEASE_API } from "./release";

// The download buttons fetch the DMG itself. Its file name carries the version, so the latest
// one is looked up when the site is built, and again in the browser on every visit
// (Layout.astro), so a new release never waits for a site deploy. The fallback is the release
// that was current when this was written.
const FALLBACK_DMG = "https://github.com/arpan404/omil/releases/download/v0.1.6/Omil-0.1.6-7-macos-arm64.dmg";

async function latestDmg(): Promise<string> {
  try {
    const res = await fetch(LATEST_RELEASE_API, {
      headers: { Accept: "application/vnd.github+json" },
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) return FALLBACK_DMG;
    return dmgOf(await res.json()) ?? FALLBACK_DMG;
  } catch {
    return FALLBACK_DMG;
  }
}

export const DOWNLOAD_URL = await latestDmg();
export const SITE_URL = "https://omil.arpan.sh";
export { GITHUB_URL };
export const REQUIREMENTS = "Requires an Apple silicon Mac with macOS 14 or later.";

export const RAW_TEXT = "Um, so I think we should, uh, ship it on Friday. No wait, Thursday.";
export const CLEAN_TEXT = "I think we should ship it on Thursday.";

export type DiffToken = { text: string; kind: "same" | "added" | "removed" };

/** TranscriptDiff.tokens (OmilCore): LCS over word and punctuation tokens. */
export const diffTokens = (raw: string, cleaned: string): DiffToken[] => {
  const tok = (t: string) => t.match(/[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*|[^\p{L}\p{N}\s]/gu) ?? [];
  const a = tok(raw);
  const b = tok(cleaned);
  const dp = Array.from({ length: a.length + 1 }, () => new Array<number>(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--)
    for (let j = b.length - 1; j >= 0; j--) dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const out: DiffToken[] = [];
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      out.push({ text: a[i++], kind: "same" });
      j++;
    } else if (j < b.length && (i >= a.length || dp[i][j + 1] > dp[i + 1][j])) out.push({ text: b[j++], kind: "added" });
    else out.push({ text: a[i++], kind: "removed" });
  }
  return out;
};

/** Punctuation that hugs the previous token. */
export const attaches = (t: string) => t.length === 1 && ".,!?;:)]}%”’".includes(t);
