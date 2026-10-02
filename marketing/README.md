# Marketing

- `site/`: the website (Astro and Tailwind). `bun install`, then `bun run dev`.
- `video/`: the launch film (Remotion). It also renders the website's media from the
  app's own UI components with `bun run site-media`, which writes to `site/public/media`.

Both are Bun projects with their own `package.json` and are independent of the Swift
build.
