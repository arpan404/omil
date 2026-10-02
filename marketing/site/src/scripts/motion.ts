// Small motion helpers shared by the page's scripts. Transform and opacity only.
// Scroll-linked motion and springs come from Motion (motion.dev); these cover the rest.

export const EASE = "cubic-bezier(0.16, 1, 0.3, 1)";
export const reduceMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

export const wait = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/**
 * FLIP: measure the given elements, apply a layout change, then animate each element from
 * where it was to where it is now with a transform. Elements that leave the layout should be
 * faded out by the caller before `mutate` hides them.
 */
export async function flip(elements: HTMLElement[], mutate: () => void, duration = 700): Promise<void> {
  if (reduceMotion()) {
    mutate();
    return;
  }
  const before = new Map(elements.map((el) => [el, el.getBoundingClientRect()]));
  mutate();
  const animations: Animation[] = [];
  for (const el of elements) {
    const a = before.get(el)!;
    const b = el.getBoundingClientRect();
    if (b.width === 0 && b.height === 0) continue;
    const dx = a.left - b.left;
    const dy = a.top - b.top;
    if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5) continue;
    animations.push(
      el.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: "none" }], {
        duration,
        easing: EASE,
        fill: "both",
      }),
    );
  }
  await Promise.all(animations.map((a) => a.finished.catch(() => undefined)));
  animations.forEach((a) => a.cancel());
}

/** Fade and shrink an element away. Resolves when it is invisible. */
export async function fadeOut(el: HTMLElement, duration = 420): Promise<void> {
  if (reduceMotion()) {
    el.style.opacity = "0";
    return;
  }
  const a = el.animate([{ opacity: 1, transform: "none" }, { opacity: 0, transform: "scale(0.85)" }], {
    duration,
    easing: EASE,
    fill: "forwards",
  });
  await a.finished.catch(() => undefined);
}

/** Rise in from slightly below. */
export function riseIn(el: HTMLElement, duration = 600, delay = 0): Animation | undefined {
  if (reduceMotion()) return undefined;
  return el.animate([{ opacity: 0, transform: "translateY(0.4em)" }, { opacity: 1, transform: "none" }], {
    duration,
    delay,
    easing: EASE,
    fill: "backwards",
  });
}

/** Runs `enter` the first time the element is mostly on screen. */
export function onceVisible(el: Element, enter: () => void, amount = 0.5): void {
  const io = new IntersectionObserver(
    ([e]) => {
      if (!e.isIntersecting) return;
      io.disconnect();
      enter();
    },
    { threshold: amount },
  );
  io.observe(el);
}

/** Tells the element (data-live) whether it is on screen, so looping motion can rest off screen. */
export function whileVisible(el: HTMLElement, change?: (visible: boolean) => void): void {
  new IntersectionObserver(
    ([e]) => {
      el.toggleAttribute("data-live", e.isIntersecting);
      change?.(e.isIntersecting);
    },
    { threshold: 0.15 },
  ).observe(el);
}
