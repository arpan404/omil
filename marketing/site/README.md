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

`src/pages/index.astro` stacks the sections in `src/components/`:

- `Hero`: on the left the headline arrives as spoken and cleans itself (filler struck in
  red, then a FLIP over transforms as the words settle). On the right a dictation plays on
  a stage drawn in HTML: an app window, what is being heard, and the pill. It loops through
  Mail, Notes and Messages until the reader holds the key under it (mouse, touch, Space or
  Enter) or the real Right Option key. The three steps beside the key light up as it plays.
  The scenes are data at the top of `Hero.astro`.
- `Cleanup`: the Clean / Original / Changes tabs; the diff is computed at build time with
  the same tokenizer as the app (`src/data/site.ts`).
- `Personal`: five tiles (Snippets, Dictionary, History, No waiting, Your prompt), each
  showing its feature in HTML with the app's own sample data.
- `Private`: where the audio goes, all inside the Mac, with a signal travelling the path.
- `Devices`: iPhone and iPad, coming soon.
- `Faq`, `Footer` (the final download, dictated word by word, and the theme switch).

Shared pieces: `DownloadButton` (the only download action; it points at the DMG with the
`download` attribute), `Pill` (the app's pill, drawn in HTML, with its Start / listening /
Cleaning up / Done states; scripts set `data-state`), `ThemeSwitch` (in the nav and the
footer), `Nav` (a floating capsule whose thumb follows the section being read).

## Design

Tokens and component classes live in `src/styles/global.css`: the Graphite palette
(monochrome, with the app's red and green only for removed and added text), `.tile` (a
flat block of the page), `.desk` (the backdrop behind product visuals), `.card` (anything
that floats above those), and the buttons. Tiles are 32px, cards 20px, controls are pills.
They sit in Tailwind's `components` layer, so utilities override them.

## Motion

Transform and opacity only (plus one pill and one accordion that change size), and
everything respects `prefers-reduced-motion`. Reveals use one IntersectionObserver
(`data-reveal`, `data-reveal-stagger`). Scroll-linked motion (the device depth) uses [Motion](https://motion.dev)'s `scroll()`, which runs on native scroll
timelines where the browser has them. The headline and the stage use the small FLIP helpers
in `src/scripts/motion.ts`. Looping motion only runs while its section is on screen.

## Media

Everything in `public/media` is rendered from the app's own UI components in
`../video/` (the same ones the launch film uses), not screenshots:

```sh
cd ../video && bun run site-media
```

`ipad.webp` and `iphone-done.webp` are the keyboards on a transparent background
(`SiteDevices`). `og.png` is the social card. Everything else on the page is drawn in HTML.

## Facts on the page

Download link, requirements and the shared transcript live in `src/data/site.ts`. The
download URL is resolved at build time from the latest GitHub release DMG. Keep the copy
in line with the repository README: Apple silicon, macOS 14 or later, English only,
iPhone and iPad not released yet.
