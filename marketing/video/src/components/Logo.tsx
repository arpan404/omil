import React from "react";
import { Img, staticFile } from "remotion";

// Omil glyph traced from AppIcon-1024: x offset from centre, width, height (icon units).
export const LOGO_BARS = [
  { x: -283, w: 52, h: 104 },
  { x: -195, w: 66, h: 225 },
  { x: -98, w: 76, h: 384 },
  { x: 0, w: 72, h: 512 },
  { x: 98, w: 76, h: 384 },
  { x: 195, w: 66, h: 225 },
  { x: 284, w: 52, h: 104 },
];
export const LOGO_HOLE = 102;
export const LOGO_SPAN = 640;

/** The bare glyph. `size` is its rendered width. */
export const Glyph: React.FC<{ size: number; color?: string; id: string; glow?: boolean }> = ({ size, color = "#F5F5F7", id, glow }) => {
  const k = size / LOGO_SPAN;
  return (
    <svg
      width={size}
      height={512 * k}
      viewBox={`${-LOGO_SPAN / 2} -256 ${LOGO_SPAN} 512`}
      style={{ overflow: "visible", filter: glow ? `drop-shadow(0 0 ${size * 0.05}px rgba(255,255,255,0.55))` : undefined }}
    >
      <defs>
        <mask id={`${id}-hole`} maskUnits="userSpaceOnUse" x={-400} y={-400} width={800} height={800}>
          <rect x={-400} y={-400} width={800} height={800} fill="white" />
          <circle r={LOGO_HOLE} fill="black" />
        </mask>
      </defs>
      <g mask={`url(#${id}-hole)`}>
        {LOGO_BARS.map((b) => (
          <rect key={b.x} x={b.x - b.w / 2} y={-b.h / 2} width={b.w} height={b.h} rx={b.w / 2} fill={color} />
        ))}
      </g>
    </svg>
  );
};

/** The real app icon (Apps/Mac/Assets.xcassets/AppIcon-1024.png) in the macOS squircle. */
export const AppIcon: React.FC<{ size: number }> = ({ size }) => (
  <Img
    src={staticFile("img/icon.png")}
    style={{ width: size, height: size, borderRadius: size * 0.225, display: "block", boxShadow: "0 0 0 1px rgba(255,255,255,0.1)" }}
  />
);
