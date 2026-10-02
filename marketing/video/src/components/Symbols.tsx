import React from "react";

// Small SF Symbols look-alikes (24pt grid) for the symbols the app uses.
const PATHS: Record<string, { d: string; fill?: boolean; w?: number }> = {
  waveform: { d: "M3 10v4M7 7v10M11 4v16M15 8v8M19 6v12M21 11v2" },
  clock: { d: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3.2 2" },
  "text.quote": { d: "M4 6h16M4 11h16M4 16h10M17.5 15.5c1.4 0 2.5 1 2.5 2.4 0 1.6-1.2 2.6-2.6 3.1" },
  "character.book.closed": { d: "M6 3h11a2 2 0 0 1 2 2v14H8a2 2 0 0 1-2-2V3zM6 17a2 2 0 0 1 2-2h11M10.5 11.5l1.8-5 1.8 5M11.1 10h2.4" },
  textformat: { d: "M3 18l5-12 5 12M4.8 14h6.4M15 18v-5.5a2.5 2.5 0 0 1 5 0V18M15 15h5" },
  cpu: { d: "M7 7h10v10H7zM10 10h4v4h-4zM9 3v4M15 3v4M9 17v4M15 17v4M3 9h4M3 15h4M17 9h4M17 15h4" },
  "mic.fill": { d: "M12 2.5a3.5 3.5 0 0 1 3.5 3.5v5.5a3.5 3.5 0 0 1-7 0V6A3.5 3.5 0 0 1 12 2.5z", fill: true },
  mic: { d: "M12 2.5a3.5 3.5 0 0 1 3.5 3.5v5.5a3.5 3.5 0 0 1-7 0V6A3.5 3.5 0 0 1 12 2.5zM5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21M9 21h6" },
  xmark: { d: "M6.5 6.5l11 11M17.5 6.5l-11 11", w: 2.6 },
  checkmark: { d: "M5 12.5l4.5 4.5L19 7.5", w: 2.8 },
  "doc.on.doc": { d: "M9 7V5a2 2 0 0 1 2-2h7a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-2M5 8h9a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2z" },
  ellipsis: { d: "M6 12h.01M12 12h.01M18 12h.01", w: 3.2 },
  magnifyingglass: { d: "M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM15.5 15.5L20 20" },
  gearshape: { d: "M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zM12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1" },
  "clock.arrow.circlepath": { d: "M4 12a8 8 0 1 0 2.3-5.6M4 4v3.5h3.5M12 8v4.5l3 1.8" },
  "stop.fill": { d: "M7 7h10v10H7z", fill: true },
  "arrow.uturn.backward": { d: "M9 14L4 9l5-5M4 9h10a6 6 0 0 1 0 12h-3" },
  "checkmark.circle.fill": { d: "M12 2.5a9.5 9.5 0 1 0 0 19 9.5 9.5 0 0 0 0-19z", fill: true },
  "square.and.arrow.up": { d: "M12 3v12M7.5 7.5L12 3l4.5 4.5M7 11H5v10h14V11h-2" },
  power: { d: "M12 3v8M7.2 6.2a7.5 7.5 0 1 0 9.6 0", w: 2.4 },
  plus: { d: "M12 5v14M5 12h14" },
  "arrow.down.to.line": { d: "M12 4v11M6.5 9.5L12 15l5.5-5.5M5 20h14", w: 2.4 },
  "arrow.up": { d: "M12 19V5M6 11l6-6 6 6", w: 2.6 },
  "face.smiling": { d: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM8.5 14a4.5 4.5 0 0 0 7 0M9 9.5h.01M15 9.5h.01" },
  "square.and.pencil": { d: "M13 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-7M17.5 3.5l3 3L12 15H9v-3z" },
  wifi: { d: "M2.5 9a14 14 0 0 1 19 0M5.5 12.2a9.5 9.5 0 0 1 13 0M8.6 15.4a5 5 0 0 1 6.8 0M12 19h.01", w: 2.2 },
  lock: { d: "M7 11V8a5 5 0 0 1 10 0v3M5.5 11h13v10h-13z" },
  "wand.and.stars": { d: "M4 20L15 9M13 7l4 4M18 3v3M16.5 4.5h3M7 4v2M6 5h2M20 13v2M19 14h2" },
  "text.cursor": { d: "M12 4v16M9 4h6M9 20h6" },
  video: { d: "M3.5 7.5A1.5 1.5 0 0 1 5 6h9a1.5 1.5 0 0 1 1.5 1.5v9A1.5 1.5 0 0 1 14 18H5a1.5 1.5 0 0 1-1.5-1.5zM15.5 10.5l5-3v9l-5-3" },
  "info.circle": { d: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v5.5M12 7.6v.01", w: 1.9 },
  "chevron.right": { d: "M9.5 6l6 6-6 6", w: 2.4 },
  "switch.2": { d: "M7 8h10a2.5 2.5 0 0 1 0 5H7a2.5 2.5 0 0 1 0-5zM7 14h10a2.5 2.5 0 0 1 0 5H7a2.5 2.5 0 0 1 0-5zM15.5 10.5h.01M8.5 16.5h.01", w: 1.8 },
  "apps.circle": { d: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 8v8M8 12h8" },
  "laptopcomputer.and.iphone": { d: "M3 6.5A1.5 1.5 0 0 1 4.5 5h11A1.5 1.5 0 0 1 17 6.5V15H3zM1 17h14.5M18.5 9h3a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-3a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1zM20 18.2h.01" },
  "qrcode.viewfinder": { d: "M3 8V5a2 2 0 0 1 2-2h3M16 3h3a2 2 0 0 1 2 2v3M21 16v3a2 2 0 0 1-2 2h-3M8 21H5a2 2 0 0 1-2-2v-3M7.5 7.5h3v3h-3zM13.5 7.5h3v3h-3zM7.5 13.5h3v3h-3zM14 14h2.5M14 16.5h.01M16.5 14v2.5" },
  "waveform.mic": { d: "M8 9v6M12 6v12M16 9v6M4 11v2M20 11v2" },
};

export const Sym: React.FC<{ name: keyof typeof PATHS | string; size: number; color?: string; weight?: number; style?: React.CSSProperties }> = ({
  name,
  size,
  color = "currentColor",
  weight = 2,
  style,
}) => {
  const p = PATHS[name];
  if (!p) return null;
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" style={{ flexShrink: 0, ...style }}>
      {p.fill ? (
        <path d={p.d} fill={color} />
      ) : (
        <path d={p.d} fill="none" stroke={color} strokeWidth={p.w ?? weight} strokeLinecap="round" strokeLinejoin="round" />
      )}
      {name === "mic.fill" && <path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21" fill="none" stroke={color} strokeWidth={2.2} strokeLinecap="round" />}
      {name === "checkmark.circle.fill" && <path d="M7.5 12.3l3 3 6-6.3" fill="none" stroke="white" strokeWidth={2.4} strokeLinecap="round" strokeLinejoin="round" />}
    </svg>
  );
};
