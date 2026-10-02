// Where releases live. No side effects here, so page scripts can import it too.
export const GITHUB_URL = "https://github.com/arpan404/omil";
export const LATEST_RELEASE_API = "https://api.github.com/repos/arpan404/omil/releases/latest";

export type Release = { tag_name?: string; published_at?: string; assets?: { name: string; browser_download_url: string }[] };

/** The DMG of a GitHub release, if it has one. */
export const dmgOf = (release: Release | null | undefined): string | undefined =>
  release?.assets?.find((a) => a.name.endsWith(".dmg"))?.browser_download_url;
