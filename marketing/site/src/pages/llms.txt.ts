import type { APIRoute } from "astro";
import { faqs } from "../data/faq";
import { CLEAN_TEXT, DOWNLOAD_URL, GITHUB_URL, RAW_TEXT, REQUIREMENTS, SITE_URL, VERSION } from "../data/site";

// /llms.txt: the page's facts as plain Markdown, for AI assistants that answer questions about
// Omil (https://llmstxt.org). It is built from the same data as the page.
export const GET: APIRoute = () => {
  const text = `# Omil

> Omil is free voice dictation for Apple silicon Macs. Hold Right Option, speak, and let go. Clean text is typed into the app you were using. Speech recognition and cleanup run on the Mac. There is no account, no cloud service and no subscription.

## Facts

- Price: free. No account, no trial, no paid plan.
- Platform: Mac only. ${REQUIREMENTS}
- Languages: English only.
- Current version: ${VERSION}.
- Privacy: audio, transcripts and cleanup stay on the Mac. The internet is used only for the first setup and for updates.
- Source code: public at ${GITHUB_URL}.
- iPhone and iPad: not released yet. The planned keyboard sends dictation to the user's Mac for transcription.
- No Windows or Android app.

## How it works

1. Hold Right Option in any app, wherever the cursor is.
2. Speak naturally. Pauses, restarts and corrections are fine.
3. Let go. Omil removes filler words, follows spoken corrections, fixes grammar, and types the result at the cursor.

Example. Spoken: "${RAW_TEXT}" Typed: "${CLEAN_TEXT}"

## Features

- Clean mode removes fillers, follows corrections and fixes grammar. Verbatim mode keeps every word.
- Dictionary: teach it names and terms it mishears.
- Snippets: say a short phrase and a longer text is typed.
- History: the last 200 dictations, searchable and replayable.
- The cleanup instructions are plain text the user can edit.
- A new recording can start while the last one is still being cleaned up.

## Questions

${faqs.map((f) => `### ${f.q}\n\n${f.a}`).join("\n\n")}

## Links

- [Website](${SITE_URL}/)
- [Download for Mac](${DOWNLOAD_URL})
- [Source code](${GITHUB_URL})
- [Release notes](${GITHUB_URL}/releases)
- [How Omil works](${GITHUB_URL}/blob/main/docs/SYSTEM.md)
`;
  return new Response(text, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
};
