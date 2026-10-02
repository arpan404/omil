# Omil marketing site

Astro + Tailwind v4, one static page. Light and dark follow the system, with a
System/Light/Dark switch in the nav and footer (the choice is saved and resolved before
first paint in `src/layouts/Layout.astro`).

```sh
bun install
bun run dev      # http://localhost:4321
bun run build    # -> dist/
```

## Page

The page is a story told in order. Content sits on a quiet canvas, with a few large panes
of frosted glass (one or two to a section, never nested). The background motif is the
product's own level meter, drawn across the screen. `src/pages/index.astro` stacks the
sections in `src/components/`:

- `Hero`: the problem, dictated in front of the reader. The key at the bottom of the screen
  goes down and the pill listens while the headline arrives word by word, as spoken; the key
  comes up, the filler is struck in red and drops out, and the words settle (a FLIP over
  transforms). One sentence and the download.
- `Story`: how it works, told by scrolling. The screen holds still (`position: sticky`)
  while one sentence goes through a dictation: the key goes down, the words are said, the
  key comes up and the filler is struck, and the clean sentence is typed at the cursor.
  Scrolling back undoes it. The scene is a small state machine (five states picked from the
  scroll position) in the component's script.
- `Dock`: the key and the pill on a pane of glass. They sit at the bottom of the window,
  where the pill sits on a Mac, from the first screen to the end of the story
  (`position: sticky` at the end of the wrapper around both). Behind them, across the whole
  screen, is the level meter (`src/scripts/wave.ts`, one canvas): it rests as a faint
  silhouette and moves while the pill is listening. The hero and the story drive both
  through `src/scripts/dock.ts`. The footer mounts a second meter around the last pill.
- `Cleanup`: the same sentence as the app's Changes view shows it; the diff is computed at
  build time with the same tokenizer as the app (`src/data/site.ts`). Clean and Verbatim.
- `Personal`: Snippets and Dictionary as type (what you say, what Omil writes), then
  History, No waiting and Your prompt in a line each.
- `Private`: where the audio goes, four steps on the Mac, with a signal travelling the path.
- `Devices`: iPhone and iPad, coming soon.
- `Faq`, `Footer` (the final download, dictated word by word, and the theme switch).

Shared pieces: `DownloadButton` (the only download action), `Pill` (the app's pill, drawn
in HTML, with its Start / listening / Cleaning up / Done states; scripts set `data-state`),
`ThemeSwitch` (in the nav and the footer), `Nav` (a floating capsule whose thumb follows
the section being read).

## Download

Every `DownloadButton` points at the DMG itself. Its file name carries the version, so the
link is resolved twice: when the site is built (`src/data/site.ts`), and again in the
browser on every visit (`src/layouts/Layout.astro` asks the GitHub API for the latest
release and repoints the buttons). A new release is picked up without a site deploy; if the
request fails, the built link stays.

## Design

Tokens and the few shared classes live in `src/styles/global.css`: the Graphite palette
(monochrome, with the app's red and green only for removed and added text), the type
classes, the buttons, `.glass` (frosted glass: a translucent fill, a backdrop blur and a
lit edge, solid under `prefers-reduced-transparency`) and `.pool` (soft light behind a
pane, so the glass has something to frost). They sit in Tailwind's `components` layer, so
utilities override them. A fine grain covers the page from one fixed layer.

## Motion

Transform and opacity only (plus the pill and the accordion, which change size), and
everything respects `prefers-reduced-motion`. Reveals use one IntersectionObserver
(`data-reveal`, `data-reveal-stagger`). Scroll-linked motion (the story, the device depth)
uses [Motion](https://motion.dev)'s `scroll()`. The headline and the story use the small
FLIP helpers in `src/scripts/motion.ts`. Looping motion only runs while its section is on
screen, and the level meter only redraws while it is moving.

## Media

Everything in `public/media` is rendered from the app's own UI components in
`../video/` (the same ones the launch film uses), not screenshots:

```sh
cd ../video && bun run site-media
```

`ipad.webp` and `iphone-done.webp` are the keyboards on a transparent background
(`SiteDevices`). `og.png` is the social card. Everything else on the page is drawn in HTML.

## Facts on the page

Requirements and the shared transcript live in `src/data/site.ts`. Keep the copy
in line with the repository README: Apple silicon, macOS 14 or later, English only,
iPhone and iPad not released yet.
