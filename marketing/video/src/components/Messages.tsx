import React from "react";
import { interpolate, useCurrentFrame } from "remotion";
import { CLEAN_TEXT } from "../timeline";
import { clamp, omil, SF } from "../theme";
import { pt, TrafficLights } from "./Mac";
import { Sym } from "./Symbols";

/** Messages window position on the 1440×810 pt screen. */
export const MSG = { x: 300, y: 64, w: 840, h: 640 };
/** Centre of the message field, screen points. */
export const MSG_FIELD = { x: MSG.x + 292 + (MSG.w - 292) / 2, y: MSG.y + MSG.h - 26 };

const D = {
  window: "#FFFFFF",
  sidebar: "#F4F4F7",
  hair: "rgba(0,0,0,0.1)",
  text: "#1D1D1F",
  secondary: "#86868B",
  gray: "#E9E9EB",
  blue: "#0A84FF",
};

const CONVERSATIONS = [
  { name: "Maya Chen", preview: "When are we shipping the update?", time: "10:42 AM" },
  { name: "Leo Park", preview: "Changelog is merged ✅", time: "10:38 AM" },
  { name: "Design Team", preview: "Ana: The new icons look great", time: "9:12 AM" },
  { name: "Sam Rivera", preview: "See you tomorrow!", time: "Yesterday" },
  { name: "Priya Nair", preview: "Sent the contract over 👍", time: "Yesterday" },
];

/** Messages in light mode. Frames are absolute (screen-sequence local). */
export const Messages: React.FC<{ inserted: number; send: number; typing: number; reply: number }> = ({ inserted, send, typing, reply }) => {
  const frame = useCurrentFrame();
  return (
    <div
      style={{
        position: "absolute",
        left: pt(MSG.x),
        top: pt(MSG.y),
        width: pt(MSG.w),
        height: pt(MSG.h),
        borderRadius: pt(16),
        overflow: "hidden",
        display: "flex",
        background: D.window,
        boxShadow: "0 0 0 0.5px rgba(0,0,0,0.2), 0 22px 60px -10px rgba(0,0,0,0.35)",
        fontFamily: SF,
        color: D.text,
      }}
    >
      <div style={{ width: pt(292), background: D.sidebar, borderRight: `0.5px solid ${D.hair}`, padding: `${pt(14)}px ${pt(10)}px` }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: `0 ${pt(6)}px ${pt(14)}px` }}>
          <TrafficLights />
          <Sym name="square.and.pencil" size={pt(17)} color={D.secondary} weight={1.8} />
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: pt(5), height: pt(28), borderRadius: pt(8), background: "rgba(0,0,0,0.055)", padding: `0 ${pt(8)}px`, color: D.secondary, fontSize: pt(13), marginBottom: pt(8) }}>
          <Sym name="magnifyingglass" size={pt(13)} color={D.secondary} />
          Search
        </div>
        {CONVERSATIONS.map((c, i) => (
          <div key={c.name} style={{ display: "flex", gap: pt(9), padding: pt(8), borderRadius: pt(9), background: i === 0 ? D.blue : "transparent" }}>
            <Monogram name={c.name} size={pt(40)} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
                <span style={{ fontSize: pt(13), fontWeight: 600, color: i === 0 ? "white" : D.text }}>{c.name}</span>
                <span style={{ fontSize: pt(11.5), color: i === 0 ? "rgba(255,255,255,0.8)" : D.secondary }}>{c.time}</span>
              </div>
              <div style={{ fontSize: pt(12.5), lineHeight: 1.3, color: i === 0 ? "rgba(255,255,255,0.85)" : D.secondary, marginTop: pt(1), whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{c.preview}</div>
            </div>
          </div>
        ))}
      </div>
      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <div style={{ height: pt(54), display: "flex", alignItems: "center", padding: `0 ${pt(16)}px`, borderBottom: `0.5px solid ${D.hair}` }}>
          <div style={{ flex: 1 }} />
          <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: pt(2) }}>
            <Monogram name="Maya Chen" size={pt(28)} />
            <span style={{ fontSize: pt(11), display: "flex", alignItems: "center", gap: pt(2) }}>
              Maya Chen <Sym name="chevron.right" size={pt(8)} color={D.secondary} />
            </span>
          </div>
          <div style={{ flex: 1, display: "flex", justifyContent: "flex-end", gap: pt(16) }}>
            <Sym name="video" size={pt(18)} color={D.secondary} weight={1.7} />
            <Sym name="info.circle" size={pt(17)} color={D.secondary} weight={1.7} />
          </div>
        </div>
        <Thread send={send} typing={typing} reply={reply} frame={frame} />
        <Field inserted={inserted} send={send} frame={frame} />
      </div>
    </div>
  );
};

const Monogram: React.FC<{ name: string; size: number }> = ({ name, size }) => (
  <div style={{ width: size, height: size, borderRadius: 99, background: "#9A9FAA", color: "white", fontWeight: 600, fontSize: size * 0.42, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
    {name
      .split(" ")
      .map((p) => p[0])
      .join("")}
  </div>
);

const Bubble: React.FC<{ me?: boolean; tail?: boolean; children: React.ReactNode; style?: React.CSSProperties }> = ({ me, tail, children, style }) => {
  const fill = me ? D.blue : D.gray;
  return (
    <div style={{ position: "relative", alignSelf: me ? "flex-end" : "flex-start", maxWidth: pt(380), padding: `${pt(6.5)}px ${pt(12)}px`, borderRadius: pt(17), background: fill, color: me ? "white" : D.text, fontSize: pt(13.5), lineHeight: 1.32, ...style }}>
      {children}
      {tail && (
        <svg width={pt(11)} height={pt(16)} viewBox="0 0 11 16" style={{ position: "absolute", bottom: 0, [me ? "right" : "left"]: -pt(4.5), transform: me ? undefined : "scaleX(-1)" }}>
          <path d="M0 0 C0 8 2.5 13 10.5 15.8 C5 16.4 1.5 15.4 -2 13 L-2 0 Z" fill={fill} />
        </svg>
      )}
    </div>
  );
};

const Stamp: React.FC<{ time: string }> = ({ time }) => (
  <div style={{ alignSelf: "center", fontSize: pt(11), color: D.secondary, margin: `${pt(8)}px 0 ${pt(4)}px` }}>
    <b style={{ fontWeight: 600 }}>Today</b> {time}
  </div>
);

const Thread: React.FC<{ send: number; typing: number; reply: number; frame: number }> = ({ send, typing, reply, frame }) => {
  const sent = Math.min(1, omil(frame, send));
  const t = interpolate(frame, [typing, typing + 6, reply - 2, reply + 2], [0, 1, 1, 0], clamp);
  const r = Math.min(1, omil(frame, reply));
  const dot = (i: number) => 0.35 + 0.65 * Math.max(0, Math.sin(frame * 0.32 - i * 0.9));
  return (
    <div style={{ flex: 1, display: "flex", flexDirection: "column", justifyContent: "flex-end", gap: pt(3), padding: `0 ${pt(18)}px ${pt(10)}px`, overflow: "hidden" }}>
      <Stamp time="9:58 AM" />
      <Bubble tail>Morning! Did the build pass?</Bubble>
      <Bubble me>Yep, notarized and signed ✅</Bubble>
      <Bubble me tail>Uploading the DMG now</Bubble>
      <Bubble tail>Amazing 🙌</Bubble>
      <Stamp time="10:41 AM" />
      <Bubble>Release notes look great!</Bubble>
      <Bubble tail={frame < send}>When are we shipping the update?</Bubble>
      {frame >= send && (
        <div style={{ alignSelf: "flex-end", display: "flex", flexDirection: "column", alignItems: "flex-end", gap: pt(2), marginTop: pt(6) }}>
          <Bubble me tail style={{ opacity: sent, translate: `0px ${(1 - sent) * pt(30)}px`, scale: String(0.88 + 0.12 * sent), transformOrigin: "100% 100%" }}>
            {CLEAN_TEXT}
          </Bubble>
          <span style={{ fontSize: pt(10.5), color: D.secondary, fontWeight: 500, opacity: interpolate(frame, [send + 12, send + 20], [0, 1], clamp) }}>{frame >= reply - 8 ? "Read 10:43 AM" : "Delivered"}</span>
        </div>
      )}
      {frame >= typing && frame < reply + 2 && (
        <Bubble tail style={{ padding: `${pt(10)}px ${pt(13)}px`, opacity: t }}>
          <div style={{ display: "flex", gap: pt(4) }}>
            {[0, 1, 2].map((i) => (
              <div key={i} style={{ width: pt(7), height: pt(7), borderRadius: 9, background: "#8E8E93", opacity: dot(i) }} />
            ))}
          </div>
        </Bubble>
      )}
      {frame >= reply && (
        <Bubble tail style={{ opacity: r, translate: `0px ${(1 - r) * pt(20)}px`, scale: String(0.9 + 0.1 * r), transformOrigin: "0% 100%" }}>
          Perfect. Thursday it is 🚀
        </Bubble>
      )}
    </div>
  );
};

const Field: React.FC<{ inserted: number; send: number; frame: number }> = ({ inserted, send, frame }) => {
  const hasText = frame >= inserted && frame < send;
  const caretOn = Math.floor(frame / 16) % 2 === 0;
  return (
    <div style={{ height: pt(48), display: "flex", alignItems: "center", gap: pt(10), padding: `0 ${pt(14)}px ${pt(4)}px` }}>
      <div style={{ width: pt(28), height: pt(28), borderRadius: 99, background: "rgba(0,0,0,0.06)", display: "flex", alignItems: "center", justifyContent: "center" }}>
        <Sym name="plus" size={pt(14)} color={D.secondary} weight={2.4} />
      </div>
      <div style={{ flex: 1, height: pt(30), borderRadius: pt(15), border: "1px solid rgba(0,0,0,0.14)", boxShadow: "0 0 0 3.5px rgba(10,132,255,0.3)", display: "flex", alignItems: "center", padding: `0 ${pt(8)}px 0 ${pt(12)}px`, fontSize: pt(13.5), whiteSpace: "pre" }}>
        {hasText && <span style={{ color: D.text }}>{CLEAN_TEXT}</span>}
        <span style={{ width: pt(1.5), height: pt(16), background: D.blue, opacity: caretOn ? 1 : 0, marginLeft: 1 }} />
        {!hasText && <span style={{ color: "#A1A1A6" }}>iMessage</span>}
        <div style={{ marginLeft: "auto", display: "flex", gap: pt(10) }}>
          <Sym name="face.smiling" size={pt(16)} color="#A1A1A6" weight={1.8} />
          <Sym name="waveform.mic" size={pt(16)} color="#A1A1A6" weight={1.8} />
        </div>
      </div>
    </div>
  );
};
