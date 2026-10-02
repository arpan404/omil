import React from "react";
import { useAudioData } from "@remotion/media-utils";
import { interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { clamp, omil, SF } from "../theme";
import { Sym } from "./Symbols";

export type PillPhase = "idle" | "preparing" | "recording" | "transcribing" | "cleaning" | "inserting" | "done";

// PillLayout.size in FlowPill.swift (points). The visible capsule is 6 pt smaller (3 pt padding).
const SIZE: Record<PillPhase, [number, number]> = {
  idle: [84, 34],
  preparing: [134, 38],
  recording: [144, 42],
  transcribing: [148, 38],
  cleaning: [148, 38],
  inserting: [148, 38],
  done: [148, 38],
};
const TITLE: Partial<Record<PillPhase, string>> = {
  preparing: "Starting",
  transcribing: "Transcribing",
  cleaning: "Cleaning up",
  inserting: "Inserting",
  done: "Done",
};

/** FlowPill in light mode: a flat capsule, black at 84%, with a 0.5 pt hairline (FlowPill.swift + Glass.swift). `S` is px per point. */
export const Pill: React.FC<{ phase: PillPhase; prev: PillPhase; phaseStart: number; voiceStart: number; S: number }> = ({ phase, prev, phaseStart, voiceStart, S }) => {
  const frame = useCurrentFrame();
  // Panel frame animates with easeOut 0.18 s; content cross-fades with OmilMotion.standard.
  const size = interpolate(frame - phaseStart, [0, 5.4], [0, 1], { ...clamp, easing: (t) => 1 - (1 - t) ** 2 });
  const w = (interpolate(size, [0, 1], [SIZE[prev][0], SIZE[phase][0]]) - 6) * S;
  const h = (interpolate(size, [0, 1], [SIZE[prev][1], SIZE[phase][1]]) - 6) * S;
  const show = Math.min(1, omil(frame, phaseStart));

  return (
    <div style={{ width: w, height: h, borderRadius: h / 2, background: "rgba(0,0,0,0.84)", boxShadow: `inset 0 0 0 ${0.5 * S}px rgba(29,29,31,0.1)` }}>
      <div style={{ height: "100%", display: "flex", alignItems: "center", justifyContent: "center", fontFamily: SF, color: "white" }}>
        <div style={{ opacity: show, scale: String(0.92 + 0.08 * show), display: "flex", alignItems: "center", gap: 6 * S, padding: `0 ${8 * S}px` }}>
          {phase === "idle" && (
            <span style={{ display: "flex", alignItems: "center", gap: 5 * S, fontSize: 12 * S, fontWeight: 500 }}>
              <Sym name="mic.fill" size={12 * S} color="white" />
              Start
            </span>
          )}
          {phase === "recording" && (
            <>
              <Round size={24 * S} bg="rgba(255,255,255,0.1)">
                <Sym name="xmark" size={10 * S} color="rgba(255,255,255,0.78)" />
              </Round>
              <Waveform S={S} voiceStart={voiceStart} />
              <Round size={28 * S} bg="#FFFFFF">
                <Sym name="checkmark" size={12 * S} color="#000" />
              </Round>
            </>
          )}
          {TITLE[phase] && (
            <>
              <div style={{ width: 14 * S, height: 18 * S, display: "flex", alignItems: "center", justifyContent: "center" }}>
                {phase === "done" ? <Sym name="checkmark" size={11 * S} color="#fff" /> : <Spinner size={12 * S} />}
              </div>
              <span style={{ fontSize: 12 * S, fontWeight: 500, color: "rgba(255,255,255,0.92)", whiteSpace: "nowrap" }}>{TITLE[phase]}</span>
              {phase === "preparing" && (
                <Round size={24 * S} bg="rgba(255,255,255,0.1)">
                  <Sym name="xmark" size={10 * S} color="rgba(255,255,255,0.78)" />
                </Round>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
};

const Round: React.FC<{ size: number; bg: string; children: React.ReactNode }> = ({ size, bg, children }) => (
  <div style={{ width: size, height: size, borderRadius: 99, background: bg, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>{children}</div>
);

/** CompactWaveform: 13 capsules from the meter, fed here by the actual voice recording. */
const Waveform: React.FC<{ S: number; voiceStart: number }> = ({ S, voiceStart }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const audio = useAudioData(staticFile("voice/demo.wav"));
  const bars = 13;
  const level = (at: number) => {
    if (!audio) return 0;
    const data = audio.channelWaveforms[0];
    const c = Math.floor(((at - voiceStart) / fps) * audio.sampleRate);
    const half = Math.floor(audio.sampleRate / fps);
    if (c + half < 0 || c - half >= data.length) return 0;
    let sum = 0;
    let n = 0;
    for (let i = Math.max(0, c - half); i < Math.min(data.length, c + half); i += 4) {
      sum += data[i] * data[i];
      n++;
    }
    return Math.min(1, Math.sqrt(sum / Math.max(1, n)) * 4.2);
  };
  return (
    <div style={{ width: 52 * S, height: 24 * S, display: "flex", alignItems: "center", gap: 2.5 * S }}>
      {Array.from({ length: bars }, (_, i) => (
        <div key={i} style={{ flex: 1, height: Math.max(2.5, 2.5 + 24 * 0.78 * level(frame - (bars - 1 - i) * 1.2)) * S, borderRadius: 99, background: "rgba(255,255,255,0.96)" }} />
      ))}
    </div>
  );
};

/** macOS small ProgressView: 8 fading spokes. */
export const Spinner: React.FC<{ size: number; color?: string }> = ({ size, color = "#fff" }) => {
  const frame = useCurrentFrame();
  const step = Math.floor(frame / 2) % 8;
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      {Array.from({ length: 8 }, (_, i) => {
        const a = (i / 8) * Math.PI * 2;
        return <line key={i} x1={12 + Math.sin(a) * 5.5} y1={12 - Math.cos(a) * 5.5} x2={12 + Math.sin(a) * 10} y2={12 - Math.cos(a) * 10} stroke={color} strokeWidth="2.6" strokeLinecap="round" opacity={1 - ((step - i + 8) % 8) * 0.11} />;
      })}
    </svg>
  );
};
