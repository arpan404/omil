import React, { useMemo } from "react";
import QRCode from "qrcode";
import { interpolate, useCurrentFrame } from "remotion";
import { clamp, G, MONO, omil, SF } from "../theme";
import { Spinner } from "./Pill";
import { Sym } from "./Symbols";

// iOS light-mode system colours used by the apps around Omil.
export const IOS = {
  bg: "#F2F2F7",
  card: "#FFFFFF",
  label: "#000000",
  secondary: "rgba(60,60,67,0.6)",
  separator: "rgba(60,60,67,0.18)",
  blue: "#007AFF",
  bubble: "#E9E9EB",
  keyboardTray: "#D1D3D9",
  keyLetter: "#FFFFFF",
  keyFunction: "#ADB3BD", // KeyColors.function in KeyboardViewController.swift
};

// ---------------------------------------------------------------- hardware

export const PHONE = { w: 420, h: 870, bezel: 13 };
export const Phone: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div style={{ position: "relative", width: PHONE.w, height: PHONE.h }}>
    {[
      { side: "left", top: 160, h: 32 },
      { side: "left", top: 224, h: 60 },
      { side: "left", top: 298, h: 60 },
      { side: "right", top: 250, h: 92 },
    ].map((k, i) => (
      <div key={i} style={{ position: "absolute", [k.side]: -3.5, top: k.top, width: 5, height: k.h, borderRadius: 3, background: "#C8C8CD" }} />
    ))}
    <div style={{ position: "absolute", inset: 0, borderRadius: 68, padding: 5, background: "#D9D9DE", boxShadow: "inset 0 0 0 1px rgba(0,0,0,0.08), 0 30px 70px -20px rgba(0,0,0,0.28)" }}>
      <div style={{ width: "100%", height: "100%", borderRadius: 63, background: "#0B0B0C", padding: 8 }}>
        <div style={{ position: "relative", width: "100%", height: "100%", borderRadius: 55, overflow: "hidden", background: IOS.bg }}>
          {children}
          <div style={{ position: "absolute", top: 11, left: "50%", translate: "-50% 0", width: 118, height: 34, borderRadius: 20, background: "#000" }} />
          <div style={{ position: "absolute", bottom: 8, left: "50%", translate: "-50% 0", width: 134, height: 5, borderRadius: 3, background: "rgba(0,0,0,0.85)" }} />
        </div>
      </div>
    </div>
  </div>
);

/** iPad Pro 11" in landscape; the screen is 1194×834 pt drawn at `k` px per point. */
export const PAD = { w: 1194, h: 834 };
export const Pad: React.FC<{ k: number; children: React.ReactNode }> = ({ k, children }) => (
  <div style={{ width: PAD.w * k + 36, height: PAD.h * k + 36, borderRadius: 38, padding: 4, background: "#D9D9DE", boxShadow: "inset 0 0 0 1px rgba(0,0,0,0.08), 0 30px 70px -20px rgba(0,0,0,0.28)" }}>
    <div style={{ width: "100%", height: "100%", borderRadius: 34, background: "#0B0B0C", padding: 14 }}>
      <div style={{ position: "relative", width: PAD.w * k, height: PAD.h * k, borderRadius: 20, overflow: "hidden", background: IOS.bg }}>{children}</div>
    </div>
  </div>
);

export const StatusBar: React.FC<{ dark?: boolean; time?: string }> = ({ dark, time = "10:42" }) => {
  const c = dark ? "#FFFFFF" : "#000000";
  return (
    <div style={{ position: "absolute", top: 18, left: 36, right: 28, display: "flex", justifyContent: "space-between", fontFamily: SF, fontSize: 16, fontWeight: 600, color: c, zIndex: 5 }}>
      <span>{time}</span>
      <span style={{ display: "flex", gap: 6, alignItems: "center" }}>
        <Sym name="wifi" size={16} color={c} />
        <svg width="26" height="12" viewBox="0 0 26 12">
          <rect x="0.5" y="0.5" width="22" height="11" rx="3.5" fill="none" stroke={c} strokeOpacity="0.4" />
          <rect x="2" y="2" width="16" height="8" rx="2" fill={c} />
        </svg>
      </span>
    </div>
  );
};

// ---------------------------------------------------------------- QR

export const QR: React.FC<{ text: string; size: number }> = ({ text, size }) => {
  const q = useMemo(() => QRCode.create(text, { errorCorrectionLevel: "M" }), [text]);
  const n = q.modules.size;
  const cells: React.ReactNode[] = [];
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (q.modules.get(x, y)) cells.push(<rect key={`${x}-${y}`} x={x} y={y} width={1.02} height={1.02} />);
  return (
    <svg width={size} height={size} viewBox={`0 0 ${n} ${n}`} shapeRendering="crispEdges">
      <g fill="#000">{cells}</g>
    </svg>
  );
};
export const PAIRING_URL = "omil://pair?host=Arpans-MacBook-Pro.local&port=3217&token=Q2h1bmt5LXNhbG1vbi1vbWls";

// ---------------------------------------------------------------- Omil · Settings › Your Mac

const IconTile: React.FC<{ symbol: string; color: string }> = ({ symbol, color }) => (
  <div style={{ width: 29, height: 29, borderRadius: 7, background: color, display: "flex", alignItems: "center", justifyContent: "center" }}>
    <Sym name={symbol} size={17} color="white" weight={2.2} />
  </div>
);

/** SettingsView › Your Mac (ConnectionSettingsView). `connectedAt` flips the hero to Connected. */
export const YourMacScreen: React.FC<{ tapAt: number; connectedAt: number }> = ({ tapAt, connectedAt }) => {
  const frame = useCurrentFrame();
  const connected = frame >= connectedAt;
  const swap = Math.min(1, omil(frame, connectedAt));
  const press = interpolate(frame, [tapAt - 2, tapAt, tapAt + 6], [0, 1, 0], clamp);
  return (
    <div style={{ position: "absolute", inset: 0, fontFamily: SF, color: IOS.label }}>
      <StatusBar />
      <div style={{ position: "absolute", top: 58, left: 0, right: 0, height: 44, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 17, fontWeight: 600 }}>
        <span style={{ position: "absolute", left: 12, display: "flex", alignItems: "center", gap: 2, color: IOS.blue, fontWeight: 400 }}>
          <svg width="12" height="20" viewBox="0 0 12 20">
            <path d="M10 2L2 10l8 8" stroke={IOS.blue} strokeWidth="2.6" fill="none" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          Settings
        </span>
        Your Mac
      </div>
      <div style={{ position: "absolute", top: 114, left: 16, right: 16, display: "flex", flexDirection: "column", gap: 22 }}>
        <div style={{ background: IOS.card, borderRadius: 26, padding: "22px 18px", display: "flex", flexDirection: "column", alignItems: "center", gap: 8, textAlign: "center" }}>
          <div style={{ position: "relative", width: 64, height: 64 }}>
            <div style={{ position: "absolute", inset: 0, borderRadius: 16, background: G.signal, display: "flex", alignItems: "center", justifyContent: "center", opacity: 1 - (connected ? swap : 0) }}>
              <Sym name="laptopcomputer.and.iphone" size={34} color="white" weight={1.8} />
            </div>
            <div style={{ position: "absolute", inset: 0, borderRadius: 16, background: G.success, display: "flex", alignItems: "center", justifyContent: "center", opacity: connected ? swap : 0, scale: String(0.8 + 0.2 * (connected ? swap : 0)) }}>
              <Sym name="checkmark" size={32} color="white" weight={3} />
            </div>
          </div>
          <div style={{ fontSize: 22, fontWeight: 700 }}>{connected ? "Connected" : "Not Connected"}</div>
          <div style={{ fontSize: 15, color: IOS.secondary, lineHeight: 1.3 }}>{connected ? "Speech runs on Arpans-MacBook-Pro.local." : "Pair this iPhone with Omil on your Mac to dictate."}</div>
        </div>
        <div>
          <div style={{ fontSize: 13, color: IOS.secondary, padding: "0 16px 7px", fontWeight: 500 }}>Pair With Your Mac</div>
          <div style={{ background: press > 0 ? `rgba(209,209,214,${press})` : IOS.card, borderRadius: 26, height: 52, display: "flex", alignItems: "center", gap: 14, padding: "0 16px", fontSize: 17 }}>
            <IconTile symbol="qrcode.viewfinder" color="#0A84FF" />
            {connected ? "Scan Pairing Code" : frame >= tapAt ? "Connecting…" : "Scan Pairing Code"}
            <span style={{ marginLeft: "auto" }}>
              <Sym name="chevron.right" size={14} color="rgba(60,60,67,0.3)" weight={2.6} />
            </span>
          </div>
          <div style={{ fontSize: 13, color: IOS.secondary, padding: "7px 16px 0", lineHeight: 1.3 }}>In Omil on your Mac, open Engine, turn on sharing, and choose Pair iPhone.</div>
        </div>
      </div>
    </div>
  );
};

/** The DataScanner sheet: camera view with the Mac's pairing code locked in. */
export const ScannerScreen: React.FC<{ from: number; lockAt: number }> = ({ from, lockAt }) => {
  const frame = useCurrentFrame();
  const lock = Math.min(1, omil(frame, lockAt));
  const up = Math.min(1, omil(frame, from));
  return (
    <div style={{ position: "absolute", inset: 0, background: "#1B1C1E", translate: `0px ${(1 - up) * 860}px`, fontFamily: SF }}>
      <StatusBar dark />
      <div style={{ position: "absolute", top: 64, left: 0, right: 0, textAlign: "center", color: "white", fontSize: 17, fontWeight: 600 }}>
        <span style={{ position: "absolute", left: 18, fontWeight: 400 }}>Cancel</span>
        Scan Pairing Code
      </div>
      {/* the Mac's screen seen through the camera */}
      <div style={{ position: "absolute", left: 40, right: 40, top: 230, height: 330, borderRadius: 18, background: "#E9E9EE", display: "flex", alignItems: "center", justifyContent: "center", rotate: "-3deg", filter: "blur(0.3px)" }}>
        <div style={{ padding: 10, background: "white", borderRadius: 10 }}>
          <QR text={PAIRING_URL} size={170} />
        </div>
      </div>
      {/* recognised-item highlight */}
      <div style={{ position: "absolute", left: 197 - 110 + (1 - lock) * -20, top: 395 - 110 + (1 - lock) * -20, width: 220 + (1 - lock) * 40, height: 220 + (1 - lock) * 40, borderRadius: 22, border: `4px solid rgba(255,214,10,${0.4 + 0.6 * lock})`, rotate: "-3deg" }} />
      <div style={{ position: "absolute", bottom: 120, left: 0, right: 0, textAlign: "center", color: "rgba(255,255,255,0.8)", fontSize: 15 }}>Point the camera at the code on your Mac.</div>
    </div>
  );
};

// ---------------------------------------------------------------- Omil · the screen the keyboard opens (ReturnToAppView)

/** Moving bars for a live microphone, like Waveform in the app. */
const level = (frame: number, i: number) => Math.abs(Math.sin((frame - i * 1.4) * 0.31) * Math.cos((frame - i) * 0.13));

export const Bars: React.FC<{ count: number; height: number; width?: number; gap?: number; frame: number }> = ({ count, height, width = 3, gap = 3, frame }) => (
  <div style={{ display: "flex", alignItems: "center", gap, height }}>
    {Array.from({ length: count }, (_, i) => (
      <div key={i} style={{ width, height: 4 + level(frame, i) * (height - 6), borderRadius: 3, background: G.recording, opacity: 0.35 + 0.65 * level(frame, i) }} />
    ))}
  </div>
);

/** "◀ Messages": the breadcrumb iOS shows in place of the clock after one app opens another. */
export const BackBreadcrumb: React.FC<{ app: string; press?: number }> = ({ app, press = 0 }) => (
  <div style={{ position: "absolute", top: 19, left: 22, display: "flex", alignItems: "center", gap: 3, fontFamily: SF, fontSize: 13, fontWeight: 600, color: IOS.blue, opacity: 1 - 0.5 * press, zIndex: 6 }}>
    <svg width="7" height="12" viewBox="0 0 7 12">
      <path d="M6 1L1 6l5 5" stroke={IOS.blue} strokeWidth="2" fill="none" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
    {app}
  </div>
);

/** ReturnToAppView (KeyboardSessionView.swift): Omil is already listening and points at the way back. */
export const ReturnScreen: React.FC<{ from: number; app: string; backAt: number }> = ({ from, app, backAt }) => {
  const frame = useCurrentFrame();
  const press = interpolate(frame, [backAt - 3, backAt, backAt + 5], [0, 1, 0], clamp);
  const nudge = (Math.sin((frame - from) / 7) + 1) / 2;
  const secs = Math.max(0, Math.floor((frame - from) / 30));
  return (
    <div style={{ position: "absolute", inset: 0, fontFamily: SF, color: G.ink, background: G.canvas }}>
      <BackBreadcrumb app={app} press={press} />
      <div style={{ position: "absolute", top: 18, right: 28, display: "flex", gap: 6, alignItems: "center" }}>
        <Sym name="wifi" size={16} color="#000" />
        <svg width="26" height="12" viewBox="0 0 26 12">
          <rect x="0.5" y="0.5" width="22" height="11" rx="3.5" fill="none" stroke="#000" strokeOpacity="0.4" />
          <rect x="2" y="2" width="16" height="8" rx="2" fill="#000" />
        </svg>
      </div>
      <div style={{ position: "absolute", top: 60, left: 24, display: "flex", alignItems: "flex-start", gap: 6, color: G.ink, fontSize: 15, fontWeight: 600 }}>
        <svg width="20" height="20" viewBox="0 0 20 20" style={{ translate: `${-3 * nudge}px ${-3 * nudge}px` }}>
          <path d="M16 16L4 4M4 12V4h8" stroke={G.ink} strokeWidth="2.4" fill="none" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
        <span style={{ paddingTop: 8 }}>Tap here to go back</span>
      </div>
      <div style={{ position: "absolute", top: 250, left: 24, right: 24, display: "flex", flexDirection: "column", alignItems: "center", gap: 16, textAlign: "center" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 7, padding: "7px 13px", borderRadius: 99, background: "#FFFFFF", boxShadow: `inset 0 0 0 0.5px ${G.line}`, fontSize: 15, fontWeight: 600 }}>
          <div style={{ width: 8, height: 8, borderRadius: 9, background: G.recording, opacity: 0.45 + 0.55 * Math.abs(Math.sin(frame / 8)) }} />
          Listening
        </div>
        <div style={{ scale: "1.4", height: 60, display: "flex", alignItems: "center" }}>
          <Bars count={32} height={40} frame={frame} />
        </div>
        <div style={{ fontSize: 22, fontWeight: 600, fontVariantNumeric: "tabular-nums" }}>0:{String(secs).padStart(2, "0")}</div>
        <div style={{ fontSize: 22, fontWeight: 700 }}>Go back and keep talking</div>
        <div style={{ fontSize: 17, color: G.muted, lineHeight: 1.3 }}>Omil is listening. When you finish, tap Done on the Omil keyboard and your words appear where you were typing.</div>
      </div>
      <div style={{ position: "absolute", left: 24, right: 24, bottom: 46, display: "flex", flexDirection: "column", gap: 14, alignItems: "center" }}>
        <div style={{ alignSelf: "stretch", height: 50, borderRadius: 99, background: G.signal, color: G.signalInk, display: "flex", alignItems: "center", justifyContent: "center", gap: 8, fontSize: 17, fontWeight: 600 }}>
          <Sym name="checkmark" size={17} color={G.signalInk} /> Done
        </div>
        <div style={{ alignSelf: "stretch", height: 50, borderRadius: 99, background: "rgba(29,29,31,0.07)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: 17, fontWeight: 600 }}>Cancel</div>
        <div style={{ fontSize: 13, color: G.muted, display: "flex", gap: 5, alignItems: "center" }}>
          <Sym name="mic.fill" size={13} color={G.recording} /> Keyboard mic ready for 4:5{9 - Math.min(9, secs)} <span style={{ color: G.faint }}>·</span>
          <span style={{ color: G.ink, fontWeight: 600 }}>Turn Off</span>
        </div>
      </div>
    </div>
  );
};

// ---------------------------------------------------------------- the Omil keyboard (KeyboardViewController.swift)

export type KeyboardCues = {
  /** Tap on the mic. */
  mic: number;
  /** Listening starts (back from Omil, or straight away when the mic is ready). */
  record: number;
  /** Tap on ✓. */
  done: number;
  /** The text goes in. */
  insert: number;
};

/**
 * The Omil keyboard (KeyboardViewController.swift), modeled on Wispr Flow's: a toolbar with the
 * dictation pill between two round buttons ([⏻] [🎙 Dictate 4:31] → [✕] [waveform 0:07] [✓] →
 * [↶] [Inserted]), over a compact keypad of numbers and punctuation, then space and return.
 * `k` scales points to px; `pad` uses the 264 pt iPad height and has its own globe key.
 */
export const OmilKeyboard: React.FC<{ cues: KeyboardCues; mac: string; k?: number; pad?: boolean; ready?: boolean; returnTitle?: string }> = ({
  cues,
  k = 1,
  pad = false,
  ready = false,
  returnTitle = "return",
}) => {
  const frame = useCurrentFrame();
  const phase = frame < cues.mic ? "idle" : frame < cues.record ? "opening" : frame < cues.done ? "recording" : frame < cues.insert ? "processing" : "inserted";
  const height = (pad ? 264 : 216) * k;
  const row = (pad ? 54 : 42) * k;
  const key: React.CSSProperties = { flex: 1, height: row, borderRadius: 8 * k, background: IOS.keyLetter, boxShadow: `0 ${1 * k}px 0 rgba(0,0,0,0.3)`, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 21 * k };
  const fn: React.CSSProperties = { ...key, flex: "none", background: IOS.keyFunction };
  const pillPress = interpolate(frame, [cues.mic - 3, cues.mic, cues.mic + 5], [0, 1, 0], clamp);
  const donePress = interpolate(frame, [cues.done - 3, cues.done, cues.done + 5], [0, 1, 0], clamp);
  const pop = Math.min(1, omil(frame, phase === "recording" ? cues.record : phase === "inserted" ? cues.insert : phase === "processing" ? cues.done : cues.mic));
  const secs = Math.max(0, Math.floor((frame - cues.record) / 30));
  const C = 44 * k;
  const circle = (sym: string, fill: string, ink: string, press = 0) => (
    <div style={{ width: C, height: C, borderRadius: 99, background: fill, display: "flex", alignItems: "center", justifyContent: "center", scale: String(1 - 0.06 * press), opacity: phase === "idle" ? 1 : pop }}>
      <Sym name={sym} size={19 * k} color={ink} weight={2.6} />
    </div>
  );
  const pillFill = phase === "recording" ? "rgba(255,59,48,0.14)" : phase === "idle" ? G.signal : IOS.keyLetter;
  const label = (t: string) => <span style={{ fontSize: 15 * k, fontWeight: 600, color: IOS.secondary }}>{t}</span>;
  return (
    <div style={{ height, background: IOS.keyboardTray, padding: `${6 * k}px ${3 * k}px ${4 * k}px`, display: "flex", flexDirection: "column", gap: 6 * k, fontFamily: SF, color: IOS.label }}>
      {/* toolbar */}
      <div style={{ height: 50 * k, marginBottom: 2 * k, display: "flex", alignItems: "center", gap: 10 * k, padding: `0 ${4 * k}px` }}>
        <div style={{ width: C }}>
          {phase === "recording" ? circle("xmark", IOS.keyFunction, IOS.label) : phase === "inserted" ? circle("arrow.uturn.backward", IOS.keyFunction, IOS.label) : ready || phase !== "idle" ? circle("power", IOS.keyFunction, IOS.label) : circle("gearshape", IOS.keyFunction, IOS.label)}
        </div>
        <div style={{ flex: 1, height: 50 * k, borderRadius: 99, background: pillFill, display: "flex", alignItems: "center", justifyContent: "center", gap: 8 * k, padding: `0 ${16 * k}px`, scale: String(1 - 0.05 * pillPress), overflow: "hidden" }}>
          {phase === "idle" && (
            <>
              <Sym name="mic.fill" size={20 * k} color={G.signalInk} />
              <span style={{ fontSize: 17 * k, fontWeight: 600, color: G.signalInk }}>{ready ? "Dictate" : "Start Omil"}</span>
              {ready && <span style={{ fontSize: 13 * k, fontWeight: 600, color: "rgba(255,255,255,0.6)", fontVariantNumeric: "tabular-nums" }}>4:31</span>}
            </>
          )}
          {(phase === "opening" || phase === "processing") && (
            <>
              <Spinner size={16 * k} color={IOS.secondary} />
              {label(phase === "opening" ? "Opening Omil…" : "Transcribing…")}
            </>
          )}
          {phase === "recording" && (
            <>
              <div style={{ flex: 1, display: "flex", justifyContent: "center", overflow: "hidden", opacity: pop }}>
                <Bars count={pad ? 70 : 28} height={32 * k} width={3 * k} gap={2.5 * k} frame={frame} />
              </div>
              <span style={{ fontSize: 15 * k, fontWeight: 600, color: G.recording, fontVariantNumeric: "tabular-nums" }}>0:{String(secs).padStart(2, "0")}</span>
            </>
          )}
          {phase === "inserted" && (
            <span style={{ display: "flex", alignItems: "center", gap: 6 * k, fontSize: 15 * k, fontWeight: 600, opacity: pop }}>
              <Sym name="checkmark.circle.fill" size={18 * k} color="#34C759" /> Inserted
            </span>
          )}
        </div>
        <div style={{ width: C }}>{phase === "recording" && circle("checkmark", G.signal, G.signalInk, donePress)}</div>
      </div>
      {/* keypad */}
      <div style={{ display: "flex", gap: 6 * k }}>
        {"1234567890".split("").map((c) => (
          <div key={c} style={key}>{c}</div>
        ))}
      </div>
      <div style={{ display: "flex", gap: 6 * k }}>
        {[".", ",", "?", "!", "'", "-", "@"].map((c) => (
          <div key={c} style={key}>{c}</div>
        ))}
        <div style={{ ...fn, width: 56 * k }}>
          <DeleteGlyph k={k} />
        </div>
      </div>
      <div style={{ display: "flex", gap: 6 * k }}>
        {pad && (
          <div style={{ ...fn, width: 46 * k }}>
            <Globe size={20 * k} />
          </div>
        )}
        <div style={{ ...key, fontSize: 17 * k }}>space</div>
        <div style={{ ...fn, width: 92 * k, fontSize: 17 * k }}>{returnTitle}</div>
      </div>
    </div>
  );
};

/** The dictation pill (mic) and the ✓ beside it, from the keyboard's top-left. */
export const keyboardTargets = (width: number, k = 1) => ({
  mic: { x: width / 2, y: (6 + 25) * k },
  done: { x: width - (3 + 4 + 22) * k, y: (6 + 25) * k },
});

const DeleteGlyph: React.FC<{ k: number }> = ({ k }) => (
  <svg width={22 * k} height={16 * k} viewBox="0 0 22 16">
    <path d="M7 1h13a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H7L1 8z M11 5l6 6M17 5l-6 6" fill="none" stroke="#000" strokeWidth="1.6" strokeLinejoin="round" strokeLinecap="round" />
  </svg>
);

/** The user's own keyboard, which comes back after inserting (iPhone, English QWERTY). */
export const SystemKeyboard: React.FC<{ returnTitle?: string }> = () => {
  const rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"];
  const key: React.CSSProperties = { height: 42, borderRadius: 8, background: IOS.keyLetter, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 23, boxShadow: "0 1px 0 rgba(0,0,0,0.25)" };
  return (
    <div style={{ height: 216, background: IOS.keyboardTray, padding: "10px 3px 4px", display: "flex", flexDirection: "column", gap: 11, fontFamily: SF, color: IOS.label }}>
      {rows.map((r, i) => (
        <div key={r} style={{ display: "flex", gap: 6, padding: `0 ${i === 1 ? 19 : 0}px` }}>
          {i === 2 && <div style={{ ...key, width: 44, background: IOS.keyFunction, fontSize: 18 }}>⇧</div>}
          {r.split("").map((c) => (
            <div key={c} style={{ ...key, flex: 1, paddingBottom: 3 }}>
              {c}
            </div>
          ))}
          {i === 2 && (
            <div style={{ ...key, width: 44, background: IOS.keyFunction }}>
              <DeleteGlyph k={1} />
            </div>
          )}
        </div>
      ))}
      <div style={{ display: "flex", gap: 6 }}>
        <div style={{ ...key, width: 92, background: IOS.keyFunction, fontSize: 17 }}>123</div>
        <div style={{ ...key, flex: 1, fontSize: 17 }}>space</div>
        <div style={{ ...key, width: 92, background: IOS.keyFunction, fontSize: 17 }}>return</div>
      </div>
    </div>
  );
};

/** Below a third-party keyboard on Face ID iPhones, iOS draws the globe and dictation keys. */
export const KeyboardFooter: React.FC = () => (
  <div style={{ height: 70, background: IOS.keyboardTray, display: "flex", justifyContent: "space-between", padding: "10px 30px 0" }}>
    <Globe size={26} />
    <Sym name="mic" size={26} color="#000" weight={1.7} />
  </div>
);

const Globe: React.FC<{ size: number }> = ({ size }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="#000" strokeWidth="1.7">
    <circle cx="12" cy="12" r="9.5" />
    <path d="M2.5 12h19M12 2.5c3 3 3 16 0 19M12 2.5c-3 3-3 16 0 19" />
  </svg>
);

/** A finger tap on glass. */
export const Tap: React.FC<{ x: number; y: number; at: number }> = ({ x, y, at }) => {
  const frame = useCurrentFrame();
  const t = interpolate(frame, [at - 4, at, at + 12], [0, 1, 2], clamp);
  if (t <= 0 || t >= 2) return null;
  const r = t < 1 ? 22 : 22 + (t - 1) * 30;
  return <div style={{ position: "absolute", left: x - r, top: y - r, width: r * 2, height: r * 2, borderRadius: 99, background: `rgba(0,0,0,${t < 1 ? 0.16 * t : 0.16 * (2 - t)})`, pointerEvents: "none" }} />;
};

export const MonoText: React.FC<{ children: React.ReactNode }> = ({ children }) => <span style={{ fontFamily: MONO }}>{children}</span>;
