import React from "react";
import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { Cursor, Desktop, MenuBar, P, pt, SCREEN } from "../components/Mac";
import { Messages, MSG_FIELD } from "../components/Messages";
import { OmilWindow, TARGET, type WindowState } from "../components/OmilWindow";
import { Pill, type PillPhase } from "../components/Pill";
import { bar, DEMO, f, SCENE, VOICE_WORDS } from "../timeline";
import { clamp, G, glide, INK, omil, SF, STAGE } from "../theme";

// Frames local to this sequence.
const SS = f(bar(SCENE.screen.from));
const L = (s: number) => f(s) - SS;
const B = (n: number) => L(bar(n));

const PILL = { x: 720, bottom: 760 }; // PillPosition anchor: bottom centre, screen points
const px = (p: { x: number; y: number }) => ({ x: pt(p.x), y: pt(p.y) });
const PILL_C = px({ x: PILL.x, y: PILL.bottom - 21 });

// ---------------------------------------------------------------- camera (screen px; z = zoom)

type Shot = [frame: number, z: number, x: number, y: number];
const field = px(MSG_FIELD);
const SHOTS: Shot[] = [
  [L(DEMO.pillIn), 3.3, PILL_C.x, PILL_C.y],
  [B(4), 3.3, PILL_C.x, PILL_C.y],
  [B(4.85), 1, 960, 540],
  [L(DEMO.keyUp - 0.4), 1.32, (field.x + PILL_C.x) / 2, 860],
  [L(DEMO.inserted), 1.5, field.x - 60, 880],
  [L(DEMO.send), 1.35, field.x, 720],
  [L(DEMO.reply + 0.5), 1.35, field.x, 690],
  [L(DEMO.windowOpen + 1.0), 1.05, pt(TARGET.window.x), pt(TARGET.window.y)],
  [L(DEMO.changesClick - 0.6), 1.85, pt(TARGET.result.x), pt(TARGET.result.y)],
  [L(DEMO.verbatimClick - 0.9), 1.85, pt(TARGET.result.x), pt(TARGET.result.y)],
  [L(DEMO.verbatimClick - 0.2), 1.9, pt(TARGET.toolbar.x), pt(TARGET.toolbar.y)],
  [L(DEMO.snippets + 0.2), 1.6, pt(TARGET.form.x), pt(TARGET.form.y) - 20],
  [L(DEMO.dictionary + 0.6), 1.6, pt(TARGET.form.x), pt(TARGET.form.y) - 50],
  [B(13.45), 1.6, pt(TARGET.form.x), pt(TARGET.form.y) - 50],
  [B(14), 1, 960, 540],
];
const HERO_END = B(4.85);

const useCamera = () => {
  const frame = useCurrentFrame();
  const at = SHOTS.map((s) => s[0]);
  const o = { ...clamp, easing: glide };
  const z = interpolate(frame, at, SHOTS.map((s) => s[1]), o);
  const fx = interpolate(frame, at, SHOTS.map((s) => s[2]), o);
  const fy = interpolate(frame, at, SHOTS.map((s) => s[3]), o);
  // Once the screen is framed, never show past its edges.
  const keep = interpolate(frame, [B(4.2), HERO_END], [0, 1], clamp);
  let tx = SCREEN.w / 2 - fx * z;
  let ty = SCREEN.h / 2 - fy * z;
  tx = interpolate(keep, [0, 1], [tx, Math.min(0, Math.max(SCREEN.w - SCREEN.w * z, tx))]);
  ty = interpolate(keep, [0, 1], [ty, Math.min(0, Math.max(SCREEN.h - SCREEN.h * z, ty))]);
  return { z, tx, ty };
};

// Screen frame: full-bleed during the opening close-up, then framed on the stage.
const FRAMED = { scale: 0.84, top: 30, radius: 22 };

export const Screen: React.FC = () => {
  const frame = useCurrentFrame();
  const cam = useCamera();
  const framed = interpolate(frame, [B(4), HERO_END], [0, 1], { ...clamp, easing: glide });
  const scale = 1 - (1 - FRAMED.scale) * framed;
  const left = ((SCREEN.w - SCREEN.w * scale) / 2) * framed;
  const top = FRAMED.top * framed;
  const fadeIn = interpolate(frame, [0, 10], [0, 1], clamp);
  const recording = frame >= L(DEMO.recording) && frame < L(DEMO.keyUp);

  return (
    <AbsoluteFill style={{ background: STAGE }}>
      <div
        style={{
          position: "absolute",
          left,
          top,
          width: SCREEN.w * scale,
          height: SCREEN.h * scale,
          borderRadius: FRAMED.radius * framed,
          overflow: "hidden",
          opacity: fadeIn,
          boxShadow: framed > 0 ? `0 0 0 1px rgba(0,0,0,${0.08 * framed}), 0 30px 80px -30px rgba(0,0,0,${0.35 * framed})` : "none",
        }}
      >
        <div style={{ width: SCREEN.w, height: SCREEN.h, scale: String(scale), transformOrigin: "0 0" }}>
          <div style={{ position: "absolute", inset: 0, transformOrigin: "0 0", translate: `${cam.tx}px ${cam.ty}px`, scale: String(cam.z) }}>
            <Desktop />
            <MenuBar app={frame >= L(DEMO.windowOpen) ? "Omil" : "Messages"} menus={frame >= L(DEMO.windowOpen) ? ["File", "Edit", "View", "Window", "Help"] : ["File", "Edit", "View", "Conversations", "Window", "Help"]} recording={recording} />
            <Messages inserted={L(DEMO.inserted)} send={L(DEMO.send)} typing={L(DEMO.typing)} reply={L(DEMO.reply)} />
            <WindowLayer />
            <PillLayer />
            <CursorLayer />
          </div>
        </div>
      </div>
      <Caption />
      <KeyCast />
    </AbsoluteFill>
  );
};

/** The Mac screen at frame `frame` of this sequence with no camera, captions or cursor, cropped to
 * `crop` (screen px). Used for the marketing site's stills and hero loop. */
export const CleanDesktop: React.FC<{ crop: { x: number; y: number }; pill?: boolean }> = ({ crop, pill = true }) => {
  const frame = useCurrentFrame();
  const recording = frame >= L(DEMO.recording) && frame < L(DEMO.keyUp);
  return (
    <AbsoluteFill style={{ background: "#CDD1D9", overflow: "hidden" }}>
      <div style={{ position: "absolute", left: -crop.x, top: -crop.y, width: SCREEN.w, height: SCREEN.h }}>
        <Desktop />
        <MenuBar app={frame >= L(DEMO.windowOpen) ? "Omil" : "Messages"} menus={frame >= L(DEMO.windowOpen) ? ["File", "Edit", "View", "Window", "Help"] : ["File", "Edit", "View", "Conversations", "Window", "Help"]} recording={recording} />
        <Messages inserted={L(DEMO.inserted)} send={L(DEMO.send)} typing={L(DEMO.typing)} reply={L(DEMO.reply)} />
        <WindowLayer />
        {pill && <PillLayer />}
      </div>
    </AbsoluteFill>
  );
};

/** Frames (local to this sequence) for the site: the dictation loop and the window pages. */
export const SITE_FRAMES = {
  loopFrom: L(DEMO.keyDown) - 12,
  loopTo: L(DEMO.reply) + 24,
  changes: L(DEMO.changesClick) + 24,
  snippets: L(DEMO.snippetAdd) + 24,
  dictionary: L(DEMO.correctionAdd) + 24,
};

// ---------------------------------------------------------------- Omil window

const WINDOW: WindowState = {
  section: "record",
  sectionAt: L(DEMO.windowOpen),
  prevSection: "record",
  tab: 2,
  tabAt: L(DEMO.changesClick),
  prevTab: 0,
  mode: 1,
  modeAt: L(DEMO.verbatimClick),
  snippetTyping: [L(DEMO.snippets + 0.35), L(DEMO.snippets + 0.9), L(DEMO.snippets + 1.05), L(DEMO.snippets + 2.0)],
  snippetAdd: L(DEMO.snippetAdd),
  correctionTyping: [L(DEMO.dictionary + 0.35), L(DEMO.dictionary + 0.85), L(DEMO.dictionary + 1.0), L(DEMO.dictionary + 1.35)],
  correctionAdd: L(DEMO.correctionAdd),
};

export const WindowLayer: React.FC = () => {
  const frame = useCurrentFrame();
  const open = L(DEMO.windowOpen);
  if (frame < open) return null;
  // macOS window open: quick scale-up and fade (~0.25 s ease-out)
  const p = interpolate(frame, [open, open + 8], [0, 1], { ...clamp, easing: (t) => 1 - (1 - t) ** 3 });
  const state: WindowState =
    frame >= L(DEMO.dictionary)
      ? { ...WINDOW, section: "dictionary", prevSection: "snippets", sectionAt: L(DEMO.dictionary) }
      : frame >= L(DEMO.snippets)
        ? { ...WINDOW, section: "snippets", prevSection: "record", sectionAt: L(DEMO.snippets) }
        : WINDOW;
  return (
    <div style={{ position: "absolute", inset: 0, opacity: p, scale: String(0.94 + 0.06 * p), transformOrigin: `${pt(TARGET.window.x)}px ${pt(TARGET.window.y)}px` }}>
      <OmilWindow s={state} />
    </div>
  );
};

// ---------------------------------------------------------------- pill

export const PillLayer: React.FC = () => {
  const frame = useCurrentFrame();
  const stages: [number, PillPhase][] = [
    [L(DEMO.pillIn), "idle"],
    [L(DEMO.preparing), "preparing"],
    [L(DEMO.recording), "recording"],
    [L(DEMO.keyUp), "transcribing"],
    [L(DEMO.cleaning), "cleaning"],
    [L(DEMO.inserting), "inserting"],
    [L(DEMO.done), "done"],
  ];
  if (frame < stages[0][0]) return null;
  let i = 0;
  stages.forEach(([at], k) => {
    if (frame >= at) i = k;
  });
  const [start, phase] = stages[i];
  const prev = stages[Math.max(0, i - 1)][1];
  const shown = Math.min(1, omil(frame, stages[0][0]));
  const gone = L(DEMO.done + 1.4); // completion shows for 1.4 s, then the pill hides
  const hide = interpolate(frame, [gone, gone + 6], [0, 1], clamp);
  if (hide >= 1) return null;
  const panelH = phase === "recording" ? 42 : phase === "idle" ? 34 : 38;
  return (
    <div style={{ position: "absolute", left: pt(PILL.x), top: pt(PILL.bottom - panelH + 3), translate: "-50% 0", opacity: shown * (1 - hide) }}>
      <Pill phase={phase} prev={prev} phaseStart={start} voiceStart={L(DEMO.voice)} S={P} />
    </div>
  );
};

// ---------------------------------------------------------------- cursor (tip lands on the real control centres)

const CursorLayer: React.FC = () => {
  const frame = useCurrentFrame();
  const appear = L(DEMO.windowOpen + 1.3);
  const c1 = L(DEMO.changesClick);
  const c2 = L(DEMO.verbatimClick);
  if (frame < appear) return null;
  const tab = px(TARGET.changesTab);
  const ver = px(TARGET.verbatim);
  const start = { x: tab.x + 260, y: tab.y + 220 };
  const travel = (from: { x: number; y: number }, to: { x: number; y: number }, a: number, b: number) => {
    const t = interpolate(frame, [a, b], [0, 1], { ...clamp, easing: glide });
    return { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t - Math.sin(t * Math.PI) * 40, t };
  };
  const toTab = travel(start, tab, c1 - 22, c1 - 2);
  const pos = frame < c1 + 6 ? toTab : travel(tab, ver, c2 - 24, c2 - 2);
  const fade = interpolate(frame, [appear, appear + 8, c2 + 18, c2 + 28], [0, 1, 1, 0], clamp);
  return <Cursor x={pos.x} y={pos.y} clickAt={[c1, c2]} size={P} opacity={fade} />;
};

// ---------------------------------------------------------------- caption (one line under the screen)

const CAPTIONS: [number, string][] = [
  [DEMO.inserting + 0.4, "Clean text, right where you were typing."],
  [DEMO.windowOpen, "Every dictation is saved in Omil."],
  [DEMO.changesClick, "See exactly what was cleaned up."],
  [DEMO.verbatimClick, "Prefer every word? Switch to Verbatim."],
  [DEMO.snippets, "Snippets turn a short phrase into a full reply."],
  [DEMO.dictionary, "Teach it the names and words you use."],
];

const Caption: React.FC = () => {
  const frame = useCurrentFrame();
  const y = FRAMED.top + SCREEN.h * FRAMED.scale + (SCREEN.h - FRAMED.top - SCREEN.h * FRAMED.scale) / 2;
  const style: React.CSSProperties = { position: "absolute", left: 0, right: 0, top: y, translate: "0 -50%", display: "flex", justifyContent: "center", fontFamily: SF, fontSize: 42, fontWeight: 600, letterSpacing: "-0.012em", color: INK, whiteSpace: "nowrap" };
  if (frame < L(DEMO.inserting + 0.4)) return <LiveWords style={style} />;
  const end = B(13.8);
  const idx = CAPTIONS.findIndex(([at], i) => frame >= L(at) && frame < (CAPTIONS[i + 1] ? L(CAPTIONS[i + 1][0]) : end));
  if (idx < 0) return null;
  const at = L(CAPTIONS[idx][0]);
  const next = CAPTIONS[idx + 1] ? L(CAPTIONS[idx + 1][0]) : end;
  const inP = Math.min(1, omil(frame, at));
  const out = interpolate(frame, [next - 6, next], [0, 1], clamp);
  return (
    <div style={{ ...style, opacity: inP * (1 - out), translate: `0 calc(-50% + ${(1 - inP) * 10 - out * 6}px)` }}>
      {CAPTIONS[idx][1]}
    </div>
  );
};

/** The spoken words as they arrive; on release the fillers are struck and fold away. */
const LiveWords: React.FC<{ style: React.CSSProperties }> = ({ style }) => {
  const frame = useCurrentFrame();
  const voice = L(DEMO.voice);
  if (frame < voice) return null;
  const struckAt = L(DEMO.cleaning);
  const fold = interpolate(frame, [struckAt + 10, struckAt + 22], [0, 1], { ...clamp, easing: glide });
  const out = interpolate(frame, [L(DEMO.inserting + 0.4) - 6, L(DEMO.inserting + 0.4)], [0, 1], clamp);
  return (
    <div style={{ ...style, opacity: 1 - out }}>
      {VOICE_WORDS.map((w, i) => {
        const at = voice + Math.round(w.at * 30);
        if (frame < at) return null;
        const appear = Math.min(1, omil(frame, at));
        const strike = w.drop ? interpolate(frame, [struckAt + i * 0.6, struckAt + 6 + i * 0.6], [0, 1], clamp) : 0;
        const gone = w.drop ? fold : 0;
        return (
          <span
            key={i}
            style={{
              position: "relative",
              display: "inline-block",
              maxWidth: (1 - gone) * 260,
              marginRight: i === VOICE_WORDS.length - 1 ? 0 : (1 - gone) * 11,
              opacity: appear * (1 - gone),
              translate: `0px ${(1 - appear) * 6}px`,
              overflow: gone > 0 ? "hidden" : "visible",
              color: w.drop && strike > 0 ? G.faint : INK,
            }}
          >
            {w.clean && fold > 0.5 ? w.clean : w.text}
            {w.drop && strike > 0 && <span style={{ position: "absolute", left: -2, top: "55%", height: 3, width: `calc((100% + 4px) * ${strike})`, background: G.recording, borderRadius: 2 }} />}
          </span>
        );
      })}
    </div>
  );
};

// ---------------------------------------------------------------- KeyCastr-style shortcut overlay

const KEYS: { from: number; to: number; key: string; label: string }[] = [
  { from: DEMO.keyDown - 0.1, to: DEMO.keyUp + 0.5, key: "⌥", label: "Right Option" },
  { from: DEMO.send - 0.25, to: DEMO.send + 0.7, key: "↩", label: "Return" },
  { from: DEMO.snippets - 0.35, to: DEMO.snippets + 0.8, key: "⌘3", label: "Snippets" },
  { from: DEMO.dictionary - 0.35, to: DEMO.dictionary + 0.8, key: "⌘4", label: "Dictionary" },
];

const KeyCast: React.FC = () => {
  const frame = useCurrentFrame();
  const k = KEYS.find((e) => frame >= L(e.from) && frame < L(e.to));
  if (!k) return null;
  const a = L(k.from);
  const b = L(k.to);
  const pressed = k.key === "⌥" ? frame >= L(DEMO.keyDown) && frame < L(DEMO.keyUp) : frame >= a + 6 && frame < a + 10;
  const p = Math.min(1, omil(frame, a)) * interpolate(frame, [b - 6, b], [1, 0], clamp);
  const label = k.key === "⌥" ? (frame >= L(DEMO.keyUp) ? "Released" : "Hold Right Option") : k.label;
  return (
    <div style={{ position: "absolute", left: 56, bottom: 46, opacity: p, translate: `0px ${(1 - p) * 10}px`, display: "flex", alignItems: "center", gap: 16, fontFamily: SF }}>
      <div
        style={{
          minWidth: 64,
          height: 64,
          padding: "0 14px",
          borderRadius: 14,
          background: "#FFFFFF",
          boxShadow: pressed ? "inset 0 0 0 1.5px rgba(29,29,31,0.35)" : "inset 0 0 0 1px rgba(29,29,31,0.12), 0 3px 0 rgba(29,29,31,0.12)",
          translate: `0px ${pressed ? 3 : 0}px`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: k.key.length > 1 ? 26 : 32,
          fontWeight: 500,
          color: INK,
        }}
      >
        {k.key}
      </div>
      <span style={{ fontSize: 26, fontWeight: 600, color: INK }}>{label}</span>
    </div>
  );
};

