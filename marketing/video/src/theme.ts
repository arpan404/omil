import type React from "react";
import { loadFont } from "@remotion/fonts";
import { Easing, spring, type SpringConfig } from "remotion";
import { staticFile } from "remotion";

// The app's own font: macOS SF Pro / SF Mono (variable, with optical sizes), loaded from the
// system files copied by scripts/assets.sh. Chrome cannot resolve "SF Pro" or -apple-system.
loadFont({ family: "SF", url: staticFile("fonts/SFNS.ttf"), weight: "1 1000" });
loadFont({ family: "SF Mono", url: staticFile("fonts/SFNSMono.ttf"), weight: "1 1000" });
export const SF = `"SF", system-ui, sans-serif`;
export const MONO = `"SF Mono", ui-monospace, monospace`;

/** Display type the way Apple sets it. */
export const display = (size: number, weight = 600): React.CSSProperties => ({
  fontFamily: SF,
  fontSize: size,
  fontWeight: weight,
  letterSpacing: size >= 80 ? "-0.022em" : "-0.015em",
  lineHeight: 1.08,
});

/** OmilDesign Graphite, light (Sources/OmilDesign/Palette.swift). Signal is black in light mode. */
export const G = {
  canvas: "#F5F5F7",
  sidebar: "#F0F0F2",
  panel: "#FFFFFF",
  panelDeep: "#F2F2F4",
  panelLifted: "#E8E8ED",
  line: "#E5E5EA",
  lineStrong: "#D1D1D6",
  ink: "#1D1D1F",
  muted: "#6E6E73",
  faint: "#86868B",
  signal: "#1D1D1F",
  signalInk: "#FFFFFF",
  recording: "#FF3B30",
  success: "#248A3D",
  warning: "#C93400",
  /** OmilTheme.groupFill: ink at 4.5% in light. */
  groupFill: "rgba(29,29,31,0.045)",
  /** liquidGlass() in light mode is flat: white at 92% with a 0.5 pt ink hairline, no shadow. */
  floating: "rgba(255,255,255,0.92)",
  hairline: "rgba(29,29,31,0.1)",
};

/** The film around the screens: Apple-style light stage, ink type. */
export const STAGE = "#F5F5F7";
export const INK = "#1D1D1F";

/** OmilMotion.standard = spring(response 0.32, dampingFraction 0.86), as a Remotion spring. */
const RESPONSE = 0.32;
const DAMPING_FRACTION = 0.86;
const stiffness = (2 * Math.PI / RESPONSE) ** 2;
export const OMIL_SPRING: Partial<SpringConfig> = { mass: 1, stiffness, damping: 2 * DAMPING_FRACTION * Math.sqrt(stiffness) };
/** Spring progress (0→1) starting at `at`, using the app's motion. */
export const omil = (frame: number, at: number, fps = 30) => spring({ frame: frame - at, fps, config: OMIL_SPRING });

/** Camera and title moves: slow in, slow out. */
export const glide = Easing.bezier(0.45, 0, 0.15, 1);
export const easeOut = Easing.bezier(0.16, 1, 0.3, 1);
export const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
