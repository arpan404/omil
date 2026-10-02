// The dock is the key and the pill at the bottom of the screen (Dock.astro), with the level
// meter behind it. The hero drives it while the headline is dictated, and the story drives it
// as the page scrolls.

import type { Wave } from "./wave";

export type PillState = "idle" | "listening" | "cleaning" | "done";

let wave: Wave | undefined;
/** Dock.astro hands over the meter once its canvas is mounted. */
export const attachWave = (w: Wave) => (wave = w);

export function setDock(down: boolean, pill: PillState): void {
  document.querySelector("[data-dock-key]")?.classList.toggle("is-down", down);
  const el = document.getElementById("dock-pill");
  if (el) el.dataset.state = pill;
  // The meter behind the page moves while Omil is listening.
  wave?.setLive(pill === "listening");
}

export const dockPill = () => document.getElementById("dock-pill")?.dataset.state as PillState | undefined;
