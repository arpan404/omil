import React from "react";
import { interpolate, useCurrentFrame } from "remotion";
import { clamp, SF } from "../theme";
import { Glyph } from "./Logo";
import { Sym } from "./Symbols";

/** The screen is a 1440×810 pt display rendered at 1920×1080 px. */
export const P = 4 / 3;
export const pt = (n: number) => n * P;
export const SCREEN = { w: 1920, h: 1080 };

/** A solid desktop colour (System Settings → Wallpaper → Colors), extended past the edges for the camera. */
export const Desktop: React.FC = () => <div style={{ position: "absolute", inset: "-60%", background: "#CDD1D9" }} />;

export const TrafficLights: React.FC<{ size?: number; gap?: number }> = ({ size = pt(12), gap = pt(8) }) => (
  <div style={{ display: "flex", gap }}>
    {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
      <div key={c} style={{ width: size, height: size, borderRadius: 99, background: c, boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.3)" }} />
    ))}
  </div>
);

/** Translucent 24 pt menu bar with Omil's menu bar extra (filled while recording). */
export const MenuBar: React.FC<{ app: string; menus: string[]; recording?: boolean }> = ({ app, menus, recording }) => (
  <div
    style={{
      position: "absolute",
      top: 0,
      left: 0,
      right: 0,
      height: pt(24),
      display: "flex",
      alignItems: "center",
      padding: `0 ${pt(14)}px`,
      gap: pt(18),
      fontFamily: SF,
      fontSize: pt(13),
      fontWeight: 500,
      color: "#1D1D1F",
      background: "rgba(246,246,248,0.62)",
      backdropFilter: "blur(30px) saturate(1.6)",
    }}
  >
    <span style={{ fontSize: pt(15), marginTop: -pt(1) }}>{""}</span>
    <span style={{ fontWeight: 700 }}>{app}</span>
    {menus.map((m) => (
      <span key={m}>{m}</span>
    ))}
    <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: pt(14) }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "center", width: pt(24), height: pt(18), borderRadius: pt(5), background: recording ? "rgba(255,59,48,0.95)" : "transparent" }}>
        <Glyph size={pt(15)} color={recording ? "#FFFFFF" : "#1D1D1F"} id="menubar-glyph" />
      </div>
      <Battery />
      <Sym name="wifi" size={pt(15)} color="#1D1D1F" />
      <Sym name="magnifyingglass" size={pt(14)} color="#1D1D1F" weight={2.2} />
      <Sym name="switch.2" size={pt(16)} color="#1D1D1F" />
      <span>Tue Oct 7&nbsp;&nbsp;10:42 AM</span>
    </div>
  </div>
);

const Battery: React.FC = () => (
  <svg width={pt(25)} height={pt(12)} viewBox="0 0 25 12">
    <rect x="0.6" y="0.6" width="21" height="10.8" rx="3" fill="none" stroke="#1D1D1F" strokeOpacity="0.4" strokeWidth="1.1" />
    <rect x="2.2" y="2.2" width="14.5" height="7.6" rx="1.6" fill="#1D1D1F" />
    <rect x="22.6" y="4" width="1.6" height="4" rx="0.8" fill="#1D1D1F" fillOpacity="0.4" />
  </svg>
);

/** macOS arrow pointer. `x`/`y` are where the arrow's tip points; a click dips it around the tip. */
export const Cursor: React.FC<{ x: number; y: number; clickAt?: number[]; size?: number; opacity?: number }> = ({ x, y, clickAt = [], size = 1, opacity = 1 }) => {
  const frame = useCurrentFrame();
  const press = clickAt.reduce((m, c) => Math.max(m, interpolate(frame, [c - 2, c, c + 4], [0, 1, 0], clamp)), 0);
  const w = 30 * size;
  const k = w / 17;
  return (
    <svg
      width={w}
      height={40 * size}
      viewBox="0 0 17 23"
      style={{ position: "absolute", left: x - k, top: y - k, opacity, scale: String(1 - press * 0.12), transformOrigin: `${k}px ${k}px`, filter: "drop-shadow(0 1.5px 2.5px rgba(0,0,0,0.3))" }}
    >
      <path d="M1 1v17.5l4.2-4 2.9 6.8 3-1.3-2.9-6.6h6z" fill="black" stroke="white" strokeWidth="1.3" strokeLinejoin="round" />
    </svg>
  );
};
