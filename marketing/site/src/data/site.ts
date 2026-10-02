// Facts the page states. Keep them in line with the repository README.
import { dmgOf, GITHUB_URL, LATEST_RELEASE_API, type Release } from "./release";

// The download buttons fetch the DMG itself. Its file name carries the version, so the latest
// release is looked up when the site is built, and again in the browser on every visit
// (Layout.astro), so a new release never waits for a site deploy. The fallback is the release
// that was current when this was written.
const FALLBACK = {
  dmg: "https://github.com/arpan404/omil/releases/download/v0.1.6/Omil-0.1.6-7-macos-arm64.dmg",
  version: "0.1.6",
  published: undefined as string | undefined,
};

async function latestRelease(): Promise<typeof FALLBACK> {
  try {
    const res = await fetch(LATEST_RELEASE_API, {
      headers: { Accept: "application/vnd.github+json" },
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) return FALLBACK;
    const release = (await res.json()) as Release;
    const dmg = dmgOf(release);
    if (!dmg) return FALLBACK;
    return { dmg, version: release.tag_name?.replace(/^v/, "") ?? FALLBACK.version, published: release.published_at };
  } catch {
    return FALLBACK;
  }
}

const release = await latestRelease();
export const DOWNLOAD_URL = release.dmg;
/** The version and date of the release the site was built against (for structured data). */
export const VERSION = release.version;
export const RELEASED = release.published;
export const SITE_URL = "https://omil.arpan.sh";
export { GITHUB_URL };

// How the page is described to search engines, link previews and AI assistants.
export const SITE_NAME = "Omil";
export const TITLE = "Omil: free, private voice dictation for Mac";
export const DESCRIPTION =
  "Omil is free voice dictation for Mac. Hold a key, speak, and clean text is typed into any app. It runs on your Mac: no account, no cloud, no subscription.";
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
