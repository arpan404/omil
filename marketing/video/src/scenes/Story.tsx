import { Sym } from "../components/Symbols";
import React from "react";
import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { AppIcon } from "../components/Logo";
import { BEAT_S, f, SCENE } from "../timeline";
import { clamp, display, G, glide, INK, MONO, omil, SF, STAGE } from "../theme";

const beat = (n: number) => f(n * BEAT_S);
const len = (id: keyof typeof SCENE) => f((SCENE[id].to - SCENE[id].from) * 4 * BEAT_S);

/** Rise in on the app's spring; ease out (up and away) over the last frames of the scene. */
const useLine = (at: number, end: number) => {
  const frame = useCurrentFrame();
  const inP = Math.min(1, omil(frame, at));
  const out = interpolate(frame, [end - 9, end], [0, 1], { ...clamp, easing: glide });
  return { opacity: inP * (1 - out), translate: `0px ${(1 - inP) * 26 - out * 14}px` } as React.CSSProperties;
};

// 1. The problem
export const Hook: React.FC = () => {
  const end = len("hook");
  return (
    <AbsoluteFill style={{ background: STAGE, alignItems: "center", justifyContent: "center", flexDirection: "column" }}>
      <div style={{ ...display(124, 700), color: INK, ...useLine(beat(0.5), end) }}>You think faster</div>
      <div style={{ ...display(124, 700), color: G.muted, ...useLine(beat(2), end) }}>than you type.</div>
    </AbsoluteFill>
  );
};

// 2. The answer
export const Title: React.FC = () => {
  const end = len("title");
  const frame = useCurrentFrame();
  const icon = Math.min(1, omil(frame, beat(0.25)));
  const out = interpolate(frame, [end - 9, end], [0, 1], { ...clamp, easing: glide });
  return (
    <AbsoluteFill style={{ background: STAGE, alignItems: "center", justifyContent: "center", flexDirection: "column", gap: 44 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 44, opacity: 1 - out }}>
        <div style={{ opacity: icon, scale: String(0.9 + 0.1 * icon) }}>
          <AppIcon size={176} />
        </div>
        <div style={{ ...display(170, 700), color: INK, ...useLine(beat(1), end) }}>Omil</div>
      </div>
      <div style={{ fontFamily: SF, fontSize: 48, fontWeight: 500, letterSpacing: "-0.012em", color: G.muted, ...useLine(beat(2.25), end) }}>Voice to text, right on your Mac.</div>
    </AbsoluteFill>
  );
};

// 7. Trust (on the music's peak)
export const Trust: React.FC = () => {
  const end = len("trust");
  const facts = ["Runs entirely on your Mac.", "No account.", "No cloud.", "Free."];
  return (
    <AbsoluteFill style={{ background: STAGE, alignItems: "center", justifyContent: "center", flexDirection: "column", gap: 40 }}>
      <div style={{ ...display(132, 700), color: INK, ...useLine(beat(0.1), end) }}>Private by design.</div>
      <div style={{ display: "flex", gap: 30, fontFamily: SF, fontSize: 46, fontWeight: 500, letterSpacing: "-0.012em", color: G.muted }}>
        {facts.map((t, i) => (
          <span key={t} style={useLine(beat(1 + i * 0.5), end)}>
            {t}
          </span>
        ))}
      </div>
    </AbsoluteFill>
  );
};

// 8. Call to action (the music's own ending)
export const Outro: React.FC = () => {
  const end = len("outro");
  const frame = useCurrentFrame();
  const icon = Math.min(1, omil(frame, beat(0.1)));
  const fade = interpolate(frame, [end - 18, end], [1, 0], { ...clamp, easing: glide });
  return (
    <AbsoluteFill style={{ background: STAGE, alignItems: "center", justifyContent: "center", flexDirection: "column", gap: 52, opacity: fade }}>
      <div style={{ display: "flex", alignItems: "center", gap: 36 }}>
        <div style={{ opacity: icon, scale: String(0.9 + 0.1 * icon) }}>
          <AppIcon size={150} />
        </div>
        <div style={{ ...display(140, 700), color: INK, ...useLine(beat(0.6), end + 99) }}>Omil</div>
      </div>
      <div style={{ display: "flex", gap: "0.3em", ...display(72, 700), color: INK }}>
        <span style={useLine(beat(1.6), end + 99)}>Hold ⌥.</span>
        <span style={useLine(beat(2.2), end + 99)}>Speak.</span>
        <span style={useLine(beat(2.8), end + 99)}>Release.</span>
      </div>
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 20, ...useLine(beat(4), end + 99) }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "18px 36px", borderRadius: 99, background: INK, color: "#FFFFFF", fontFamily: SF, fontWeight: 600, fontSize: 36, letterSpacing: "-0.01em" }}>
          <Sym name="arrow.down.to.line" size={32} color="#FFFFFF" weight={2.4} />
          omil.arpan.sh
        </div>
        <div style={{ fontFamily: SF, fontSize: 32, color: G.muted, letterSpacing: "-0.01em" }}>Free for Apple silicon Macs · macOS 14 or later</div>
      </div>
    </AbsoluteFill>
  );
};
