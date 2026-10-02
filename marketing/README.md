# Marketing

- `site/` is the website (Astro and Tailwind). Run `bun install`, then `bun run dev`.
- `video/` is the launch film (Remotion). It also renders the website's images: `bun run site-media` writes them to `site/public/media`.

Both are Bun projects with their own `package.json`. Neither is part of the Swift build.
