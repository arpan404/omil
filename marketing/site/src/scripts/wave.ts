// The page's background motif: Omil's level meter (the bars in the pill and in the logo), drawn
// across the whole screen. It rests as a quiet silhouette and moves while Omil is listening.
// One canvas, redrawn only while something is changing.

type Bar = { x: number; base: number; phase: number; speed: number };

const PITCH = 12; // px between bar centres
const THICK = 6; // px, bar width
const REST = 0.4; // how much of its height a bar keeps when nothing is being said

/** A repeatable pseudo-random number in 0..1 for bar `i`. */
const hash = (i: number) => {
  const s = Math.sin(i * 127.1 + 311.7) * 43758.5453;
  return s - Math.floor(s);
};
const smooth = (x: number, a: number, b: number) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

export type Wave = { setLive(on: boolean): void };

/**
 * `anchor` is where the bars are rooted: "bottom" grows them up from the canvas's bottom edge,
 * "middle" centres them on its middle line. `quiet` is the half-width (0..1 of the canvas) of
 * the calm stretch in the centre, where the pill and the text sit.
 */
export function mountWave(canvas: HTMLCanvasElement, { anchor, quiet }: { anchor: "bottom" | "middle"; quiet: number }): Wave {
  const ctx = canvas.getContext("2d")!;
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  let bars: Bar[] = [];
  let w = 0;
  let h = 0;
  let live = false;
  let energy = 0; // 0 resting, 1 listening; eased
  let frame = 0;

  const layout = () => {
    const dpr = Math.min(devicePixelRatio || 1, 2);
    w = canvas.clientWidth;
    h = canvas.clientHeight;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const n = Math.max(2, Math.floor(w / PITCH));
    const inset = (w - (n - 1) * PITCH) / 2;
    bars = Array.from({ length: n }, (_, i) => {
      const a = Math.abs((i / (n - 1)) * 2 - 1); // 0 at the centre, 1 at the edges
      // Calm in the centre, rising to a crest on either side, falling away towards the edges.
      const envelope = smooth(a, quiet * 0.35, quiet + 0.3) * (1 - 0.8 * smooth(a, quiet + 0.32, 1));
      // Speech has a shape: slow swells with finer detail on top, not noise.
      const swell = 0.5 + 0.25 * Math.sin(i * 0.21 + 1.3) + 0.25 * Math.sin(i * 0.083 + 4.1);
      const shape = 0.3 + 0.7 * (0.6 * swell + 0.4 * hash(i));
      return { x: inset + i * PITCH, base: envelope * shape * 0.9, phase: hash(i + 91) * 6.283, speed: 2.4 + hash(i + 7) * 2.8 };
    });
  };

  const draw = (now: number) => {
    const t = now / 1000;
    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = getComputedStyle(canvas).color;
    ctx.beginPath();
    for (const b of bars) {
      const swell = 0.55 + 0.45 * Math.sin(t * b.speed + b.phase);
      const drift = 0.75 + 0.25 * Math.sin(t * 0.8 + b.x * 0.012);
      const level = b.base * (REST + (1 - REST) * energy * swell * drift);
      const full = anchor === "bottom" ? h : h / 2;
      const len = Math.max(THICK, level * full);
      if (anchor === "bottom") ctx.roundRect(b.x - THICK / 2, h - len, THICK, len + THICK, THICK / 2);
      else ctx.roundRect(b.x - THICK / 2, h / 2 - len, THICK, len * 2, THICK / 2);
    }
    ctx.fill();
  };

  const tick = (now: number) => {
    energy += ((live ? 1 : 0) - energy) * 0.07;
    draw(now);
    // Keep going while listening or still settling; then rest on the last frame.
    frame = live || energy > 0.004 ? requestAnimationFrame(tick) : 0;
    if (!frame) {
      energy = 0;
      draw(now);
    }
  };
  const redraw = () => {
    layout();
    draw(performance.now());
  };

  redraw();
  new ResizeObserver(redraw).observe(canvas);
  // The bars take their colour from the page, so a theme change needs one new frame.
  new MutationObserver(() => !frame && draw(performance.now())).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });

  return {
    setLive(on) {
      live = on;
      if (still) return;
      if (!frame) frame = requestAnimationFrame(tick);
    },
  };
}
