// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';
import icon from 'astro-icon';

// https://astro.build/config
export default defineConfig({
  site: 'https://omil.arpan.sh',
  devToolbar: { enabled: false },
  integrations: [icon()],
  // One page with about 12 KB of CSS: put it in the HTML so nothing blocks the first paint.
  build: { inlineStylesheets: 'always' },
  vite: {
    // A build keeps its own cache, so building while `bun run dev` is running does not
    // invalidate the dev server's (which showed up as scripts failing with 504s).
    cacheDir: process.argv.includes('build') ? 'node_modules/.vite-build' : 'node_modules/.vite',
    plugins: [tailwindcss()]
  }
});