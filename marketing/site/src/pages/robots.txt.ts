import type { APIRoute } from "astro";
import { SITE_URL } from "../data/site";

// Everything may be crawled, by search engines and AI crawlers alike.
export const GET: APIRoute = () =>
  new Response(`User-agent: *\nAllow: /\n\nSitemap: ${SITE_URL}/sitemap.xml\n`, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
