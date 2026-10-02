# Omil website

One static page, built with Astro and Tailwind v4.

```sh
bun install
bun run dev      # http://localhost:4321
bun run build    # writes dist/
```

## Sections

`src/pages/index.astro` lists the sections in order. Each is a component in `src/components/`.

| Component | What it shows |
| --- | --- |
| `Hero` | The headline is dictated on load: words appear, the filler is struck out, and the sentence closes up. |
| `Story` | How it works. The screen stays put while you scroll through one dictation: key down, speaking, key up, text typed. Scrolling back reverses it. |
| `Dock` | The key and the pill at the bottom of the screen, with the level meter behind them. Shared by `Hero` and `Story`. |
| `Cleanup` | The same sentence as the app's Changes view shows it, plus Clean and Verbatim. |
| `Personal` | Snippets and Dictionary, then History, No waiting, and Your prompt. |
| `Private` | The four steps that all run on the Mac. |
| `Devices` | iPhone and iPad, coming soon. |
| `Faq`, `Footer` | Questions, the final download button, and the theme switch. |

Shared pieces: `DownloadButton`, `Pill` (the app's pill, with a `data-state` of `idle`, `listening`, `cleaning`, or `done`), `ThemeSwitch`, and `Nav`.

## Download button

Every download button links straight to the DMG. The link is set when the site is built and updated again in the browser on each visit (`src/layouts/Layout.astro` asks the GitHub API for the latest release). A new release shows up without redeploying the site. If the request fails, the built link stays.

## Search, sharing, and AI assistants

- `src/data/site.ts` holds the page title and description. `src/data/faq.ts` holds the questions. Both feed everything below, so edit them there.
- `Layout.astro` writes the meta tags: description, canonical URL, Open Graph and X cards, icons, and the web manifest.
- `Schema.astro` writes the structured data (schema.org): the app, its price, version and requirements, and the FAQ. It has no ratings because Omil has none.
- `/robots.txt`, `/sitemap.xml`, and `/llms.txt` are built from `src/pages/`. `llms.txt` is the page's facts in plain Markdown for AI assistants.
- The share image is `public/media/og.png` (1200 × 630). Edit `og/og.html` and run `bun run og` to render it again. It needs Google Chrome.
- The page's HTML contains the finished text. The headline's filler words are added by script, so search engines and link previews read "You think faster than you type."
- CSS is inlined into the page (`astro.config.mjs`), so nothing blocks the first paint.

After deploying, check the preview with a link debugger (for example LinkedIn Post Inspector or opengraph.xyz) and submit the sitemap in Google Search Console.

## Styles

`src/styles/global.css` holds the colors, the type classes, the buttons, `.glass` (frosted panes), and `.pool` (the soft light behind a pane). The palette is black, white, and grey. Red and green appear only for removed and added text, as in the app.

Light and dark follow the system. The switch in the nav and footer saves a choice, and `Layout.astro` applies it before the page paints.

## Motion

- `src/scripts/motion.ts` has the small helpers the headline and the story use.
- `src/scripts/wave.ts` draws the level meter on a canvas. It only redraws while it is moving.
- `src/scripts/dock.ts` lets `Hero` and `Story` set the key, the pill, and the meter.
- Scroll-linked motion uses [Motion](https://motion.dev)'s `scroll()`.
- Elements with `data-reveal` fade in when they enter the screen.

Everything respects `prefers-reduced-motion`.

## Media

`public/media` holds the iPhone and iPad images, the icons, and the social card. They are rendered from the app's UI components in `../video`:

```sh
cd ../video && bun run site-media
```

Everything else on the page is drawn in HTML.

## Facts on the page

The requirements line and the sample sentence live in `src/data/site.ts`. Keep the copy in line with the main README: Apple silicon, macOS 14 or later, English only, iPhone and iPad not released yet.
