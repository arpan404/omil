import React from "react";
import { interpolate, useCurrentFrame } from "remotion";
import { attaches, CLEAN_TEXT, diffLines, type DiffToken, RAW_TEXT } from "../timeline";
import { clamp, G, MONO, omil, SF } from "../theme";
import { pt, TrafficLights } from "./Mac";
import { Sym } from "./Symbols";

// Geometry in screen points (1440×810 pt screen). Everything the camera or cursor targets is derived here.
export const OW = { x: 400, y: 62, w: 960, h: 700 };
const SIDE = { x: 8, y: 8, w: 216 };
const DETAIL_X = 232;
const COL = { x: DETAIL_X + 32, w: OW.w - DETAIL_X - 64 }; // RecorderView column (max 720, 32 pt padding)
const COL_CX = COL.x + COL.w / 2;

export type Section = "record" | "history" | "snippets" | "dictionary" | "styles" | "engine";
const ROWS: { id: Section; title: string; icon: string; y: number }[] = [
  { id: "record", title: "Dictate", icon: "waveform", y: 66 },
  { id: "history", title: "History", icon: "clock", y: 98 },
  { id: "snippets", title: "Snippets", icon: "text.quote", y: 148 },
  { id: "dictionary", title: "Dictionary", icon: "character.book.closed", y: 180 },
  { id: "styles", title: "Styles", icon: "textformat", y: 212 },
  { id: "engine", title: "Engine", icon: "cpu", y: 262 },
];

const TABS = [
  { label: "Transcript", w: 82 },
  { label: "Original", w: 70 },
  { label: "Changes", w: 74 },
];
const TABS_BOX = { right: COL.x + COL.w - 10, y: 447, h: 32 };
const TABS_X = TABS_BOX.right - (TABS.reduce((a, t) => a + t.w, 0) + 6);
const tabCenter = (i: number) => ({ x: OW.x + TABS_X + 3 + TABS.slice(0, i).reduce((a, t) => a + t.w, 0) + TABS[i].w / 2, y: OW.y + TABS_BOX.y + TABS_BOX.h / 2 });

const MODE = { x: OW.w - 16 - 132, y: 12, segW: 64, h: 28 };
const modeCenter = (i: number) => ({ x: OW.x + MODE.x + 2 + MODE.segW * i + MODE.segW / 2, y: OW.y + MODE.y + MODE.h / 2 });

/** Screen-point targets for the camera and the cursor. */
export const TARGET = {
  window: { x: OW.x + OW.w / 2, y: OW.y + OW.h / 2 },
  stage: { x: OW.x + COL_CX, y: OW.y + 250 },
  result: { x: OW.x + COL_CX, y: OW.y + 520 },
  changesTab: tabCenter(2),
  verbatim: modeCenter(1),
  toolbar: { x: OW.x + OW.w - 120, y: OW.y + 60 },
  form: { x: OW.x + DETAIL_X + (OW.w - DETAIL_X) / 2, y: OW.y + 300 },
};

export type WindowState = {
  section: Section;
  sectionAt: number;
  prevSection: Section;
  tab: number;
  tabAt: number;
  prevTab: number;
  mode: number;
  modeAt: number;
  snippetTyping: [number, number, number, number];
  snippetAdd: number;
  correctionTyping: [number, number, number, number];
  correctionAdd: number;
};

/** Omil's main window in light mode (MainWindowView.swift, Graphite). */
export const OmilWindow: React.FC<{ s: WindowState }> = ({ s }) => {
  const frame = useCurrentFrame();
  const pageIn = Math.min(1, omil(frame, s.sectionAt));
  const hl = interpolate(Math.min(1, omil(frame, s.sectionAt)), [0, 1], [ROWS.find((r) => r.id === s.prevSection)!.y, ROWS.find((r) => r.id === s.section)!.y]);
  const title = ROWS.find((r) => r.id === s.section)!.title;
  const subtitle = s.section === "snippets" ? (frame >= s.snippetAdd + 2 ? "3 snippets" : "2 snippets") : s.section === "dictionary" ? (frame >= s.correctionAdd + 2 ? "4 corrections" : "3 corrections") : "";

  return (
    <div
      style={{
        position: "absolute",
        left: pt(OW.x),
        top: pt(OW.y),
        width: pt(OW.w),
        height: pt(OW.h),
        borderRadius: pt(16),
        overflow: "hidden",
        // GlassBackdrop: under-window material with the canvas tint at 48% (transparency 0.44)
        background: "rgba(245,245,247,0.97)",
        backdropFilter: "blur(40px) saturate(1.5)",
        boxShadow: "0 0 0 0.5px rgba(0,0,0,0.18), 0 24px 70px -12px rgba(0,0,0,0.35)",
        fontFamily: SF,
        color: G.ink,
      }}
    >
      {/* sidebar: inset source list */}
      <div style={{ position: "absolute", left: pt(SIDE.x), top: pt(SIDE.y), width: pt(SIDE.w), bottom: pt(8), borderRadius: pt(12), background: "rgba(250,250,252,0.78)", boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.07)" }}>
        <div style={{ position: "absolute", left: pt(12), top: pt(12) }}>
          <TrafficLights />
        </div>
        <div style={{ position: "absolute", left: pt(10), right: pt(10), top: pt(hl - SIDE.y - 15), height: pt(30), borderRadius: pt(8), background: "rgba(29,29,31,0.12)" }} />
        {ROWS.map((r) => {
          const selected = r.id === s.section;
          return (
            <div key={r.id} style={{ position: "absolute", left: pt(18), top: pt(r.y - SIDE.y - 15), height: pt(30), display: "flex", alignItems: "center", gap: pt(8), fontSize: pt(13), fontWeight: selected ? 500 : 400 }}>
              <div style={{ width: pt(22), display: "flex", justifyContent: "center" }}>
                <Sym name={r.icon} size={pt(15)} color={selected ? G.signal : G.muted} weight={selected ? 2.4 : 1.9} />
              </div>
              {r.title}
            </div>
          );
        })}
        {[
          ["Personalize", 124],
          ["System", 238],
        ].map(([t, y]) => (
          <div key={t} style={{ position: "absolute", left: pt(20), top: pt((y as number) - SIDE.y - 7), fontSize: pt(11), fontWeight: 600, color: G.faint }}>
            {t}
          </div>
        ))}
      </div>

      {/* toolbar */}
      <div style={{ position: "absolute", left: pt(DETAIL_X + 16), top: pt(9) }}>
        <div style={{ fontSize: pt(15), fontWeight: 700, letterSpacing: "-0.01em" }}>{title}</div>
        {subtitle && <div style={{ fontSize: pt(11), color: G.muted }}>{subtitle}</div>}
      </div>
      {s.section === "record" && <ModePicker mode={s.mode} at={s.modeAt} />}

      {/* page: opacity + 8 pt rise, as MainWindowView's section transition */}
      <div style={{ position: "absolute", left: pt(DETAIL_X), right: 0, top: 0, bottom: 0, opacity: pageIn, translate: `0px ${(1 - pageIn) * pt(8)}px` }}>
        {s.section === "record" && <Dictate s={s} />}
        {s.section === "snippets" && <Snippets s={s} />}
        {s.section === "dictionary" && <Dictionary s={s} />}
      </div>
      <Toasts s={s} />
    </div>
  );
};

/** Native segmented control (ModePicker), equal-width segments. */
const ModePicker: React.FC<{ mode: number; at: number }> = ({ mode, at }) => {
  const frame = useCurrentFrame();
  const p = Math.min(1, omil(frame, at));
  const x = mode === 1 ? p : 0;
  return (
    <div style={{ position: "absolute", left: pt(MODE.x), top: pt(MODE.y), width: pt(MODE.segW * 2 + 4), height: pt(MODE.h), borderRadius: pt(MODE.h / 2), background: "rgba(0,0,0,0.06)", fontSize: pt(12), fontWeight: 500 }}>
      <div style={{ position: "absolute", top: pt(2), left: pt(2 + x * MODE.segW), width: pt(MODE.segW), height: pt(MODE.h - 4), borderRadius: pt((MODE.h - 4) / 2), background: "#FFFFFF", boxShadow: "0 0.5px 2px rgba(0,0,0,0.18)" }} />
      {["Clean", "Verbatim"].map((t, i) => (
        <div key={t} style={{ position: "absolute", top: pt(2), left: pt(2 + i * MODE.segW), width: pt(MODE.segW), height: pt(MODE.h - 4), display: "flex", alignItems: "center", justifyContent: "center", color: G.ink }}>
          {t}
        </div>
      ))}
    </div>
  );
};

const Dictate: React.FC<{ s: WindowState }> = ({ s }) => {
  const frame = useCurrentFrame();
  const tabP = Math.min(1, omil(frame, s.tabAt));
  const tab = frame >= s.tabAt ? s.tab : s.prevTab;
  const thumbX = interpolate(tabP, [0, 1], [TABS.slice(0, s.prevTab).reduce((a, t) => a + t.w, 0), TABS.slice(0, s.tab).reduce((a, t) => a + t.w, 0)]);
  const thumbW = interpolate(tabP, [0, 1], [TABS[s.prevTab].w, TABS[s.tab].w]);
  const text = tab === 0 ? CLEAN_TEXT : RAW_TEXT;
  const left = COL.x - DETAIL_X;
  return (
    <>
      {/* RecorderStage */}
      <div style={{ position: "absolute", left: pt(left), width: pt(COL.w), top: pt(80), height: pt(340), display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: pt(20) }}>
        <div style={{ height: pt(24), padding: `0 ${pt(11)}px`, borderRadius: 99, background: G.floating, boxShadow: `inset 0 0 0 ${pt(0.5)}px ${G.hairline}`, display: "flex", alignItems: "center", gap: pt(6), fontSize: pt(11), fontWeight: 500, color: G.muted }}>
          <div style={{ width: pt(6), height: pt(6), borderRadius: 9, background: G.success }} />
          Finished
        </div>
        <div style={{ width: pt(128), height: pt(128), display: "flex", alignItems: "center", justifyContent: "center" }}>
          <div style={{ width: pt(88), height: pt(88), borderRadius: 99, background: G.signal, boxShadow: `inset 0 0 0 ${pt(0.5)}px ${G.hairline}`, display: "flex", alignItems: "center", justifyContent: "center" }}>
            <Sym name="mic.fill" size={pt(28)} color={G.signalInk} />
          </div>
        </div>
        <div style={{ textAlign: "center" }}>
          <div style={{ fontSize: pt(22), fontWeight: 700, letterSpacing: "-0.3px" }}>Done</div>
          <div style={{ fontSize: pt(13), color: G.muted, marginTop: pt(6), maxWidth: pt(420) }}>Inserted into focused field.</div>
        </div>
        <div style={{ height: pt(32) }} />
      </div>

      {/* ResultCard */}
      <div style={{ position: "absolute", left: pt(left), width: pt(COL.w), top: pt(TABS_BOX.y) }}>
        <div style={{ height: pt(TABS_BOX.h), display: "flex", alignItems: "center", padding: `0 ${pt(10)}px`, fontSize: pt(13), fontWeight: 600 }}>Last Transcript</div>
        <div style={{ position: "absolute", left: pt(TABS_X - left - DETAIL_X), top: 0, width: pt(TABS.reduce((a, t) => a + t.w, 0) + 6), height: pt(TABS_BOX.h), borderRadius: 99, background: G.floating, boxShadow: `inset 0 0 0 ${pt(0.5)}px ${G.hairline}` }}>
          <div style={{ position: "absolute", top: pt(3), left: pt(3 + thumbX), width: pt(thumbW), height: pt(26), borderRadius: 99, background: "rgba(29,29,31,0.09)" }} />
          <div style={{ position: "absolute", top: pt(3), left: pt(3), display: "flex" }}>
            {TABS.map((t, i) => (
              <div key={t.label} style={{ width: pt(t.w), height: pt(26), display: "flex", alignItems: "center", justifyContent: "center", fontSize: pt(12), fontWeight: i === tab ? 600 : 500, color: i === tab ? G.ink : G.muted }}>
                {t.label}
              </div>
            ))}
          </div>
        </div>
        <div style={{ marginTop: pt(8), background: G.groupFill, borderRadius: pt(10) }}>
          <div style={{ padding: `${pt(14)}px ${pt(16)}px`, minHeight: pt(96), fontFamily: SF, fontSize: pt(15), lineHeight: 1.42, color: G.ink }}>{tab === 2 ? <GitDiff raw={RAW_TEXT} cleaned={CLEAN_TEXT} /> : text}</div>
          <div style={{ height: 1, margin: `0 ${pt(12)}px`, background: "rgba(0,0,0,0.08)" }} />
          <div style={{ display: "flex", alignItems: "center", gap: pt(6), padding: `${pt(7)}px ${pt(8)}px ${pt(7)}px ${pt(14)}px`, fontSize: pt(11), color: G.muted }}>
            <Sym name="checkmark.circle.fill" size={pt(13)} color={G.success} />
            Inserted into focused field
            <div style={{ marginLeft: "auto", display: "flex", gap: pt(14) }}>
              <Sym name="arrow.uturn.backward" size={pt(14)} color={G.muted} />
              <Sym name="doc.on.doc" size={pt(14)} color={G.muted} />
            </div>
          </div>
        </div>
      </div>

      {/* ShortcutDock */}
      <div style={{ position: "absolute", left: pt(left), width: pt(COL.w), bottom: pt(20), display: "flex", justifyContent: "center" }}>
        <div style={{ height: pt(40), padding: `0 ${pt(16)}px`, borderRadius: 99, background: G.floating, boxShadow: `inset 0 0 0 ${pt(0.5)}px ${G.hairline}`, display: "flex", alignItems: "center", gap: pt(18), fontSize: pt(12), color: G.muted }}>
          {[
            ["Right Option", "Hold to talk"],
            ["⌃⌥O", "Start or stop"],
            ["esc", "Cancel"],
          ].map(([k, l]) => (
            <span key={k} style={{ display: "flex", alignItems: "center", gap: pt(7) }}>
              <KeyCap>{k}</KeyCap>
              {l}
            </span>
          ))}
        </div>
      </div>
    </>
  );
};

/** GitDiffView (OmilDesign): "−" original on red, "+" cleaned on green, changed words highlighted. */
export const GitDiff: React.FC<{ raw: string; cleaned: string; scale?: number; font?: number }> = ({ raw, cleaned, scale = 1, font = 12 }) => {
  const { original, cleaned: clean } = diffLines(raw, cleaned);
  const line = (sign: string, tokens: DiffToken[], changed: DiffToken["kind"], tint: string) => (
    <div style={{ display: "flex", alignItems: "baseline", gap: pt(10) * scale, padding: `${pt(6) * scale}px ${pt(10) * scale}px`, borderRadius: pt(6) * scale, background: `${tint}14` }}>
      <span style={{ width: pt(12) * scale, fontWeight: 600, color: tint, flexShrink: 0 }}>{sign}</span>
      <span>
        {tokens.map((t, i) => (
          <React.Fragment key={i}>
            {i > 0 && !attaches(t.text) ? " " : ""}
            <span style={t.kind === changed ? { background: `${tint}3D`, borderRadius: 2 } : undefined}>{t.text}</span>
          </React.Fragment>
        ))}
      </span>
    </div>
  );
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: pt(4) * scale, fontFamily: MONO, fontSize: pt(font) * scale, lineHeight: 1.45, color: G.ink }}>
      {line("−", original, "removed", G.recording)}
      {line("+", clean, "added", G.success)}
    </div>
  );
};

const KeyCap: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <span style={{ fontSize: pt(11), fontWeight: 500, color: G.ink, padding: `0 ${pt(7)}px`, height: pt(22), minWidth: pt(22), display: "inline-flex", alignItems: "center", justifyContent: "center", borderRadius: pt(5), background: G.panelLifted, boxShadow: `inset 0 0 0 1px ${G.lineStrong}` }}>
    {children}
  </span>
);

// ---------------------------------------------------------------- grouped forms (Snippets, Dictionary)

const typed = (frame: number, text: string, from: number, to: number) => text.slice(0, Math.round(interpolate(frame, [from, to], [0, text.length], clamp)));

const FormSection: React.FC<{ header: string; footer?: React.ReactNode; children: React.ReactNode }> = ({ header, footer, children }) => (
  <div style={{ display: "flex", flexDirection: "column", gap: pt(6) }}>
    <div style={{ fontSize: pt(13), fontWeight: 600, padding: `0 ${pt(10)}px` }}>{header}</div>
    <div style={{ background: "#FFFFFF", borderRadius: pt(10), boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.08)", padding: `0 ${pt(12)}px` }}>{children}</div>
    {footer && <div style={{ display: "flex", alignItems: "center", padding: `${pt(2)}px ${pt(10)}px`, fontSize: pt(11.5), color: G.muted }}>{footer}</div>}
  </div>
);

const Row: React.FC<{ children: React.ReactNode; last?: boolean; style?: React.CSSProperties }> = ({ children, last, style }) => (
  <div style={{ display: "flex", alignItems: "center", minHeight: pt(36), borderBottom: last ? "none" : "0.5px solid rgba(0,0,0,0.1)", fontSize: pt(13), ...style }}>{children}</div>
);

const Field: React.FC<{ value: string; prompt: string; caret: boolean }> = ({ value, prompt, caret }) => {
  const frame = useCurrentFrame();
  return (
    <span style={{ marginLeft: "auto", display: "inline-flex", alignItems: "center", color: value ? G.ink : G.faint, whiteSpace: "pre" }}>
      {value || prompt}
      {caret && <span style={{ width: pt(1.5), height: pt(15), marginLeft: 1, background: G.ink, opacity: Math.floor(frame / 15) % 2 === 0 ? 1 : 0 }} />}
    </span>
  );
};

const Prominent: React.FC<{ label: string; pressAt: number }> = ({ label, pressAt }) => {
  const frame = useCurrentFrame();
  const press = interpolate(frame, [pressAt - 2, pressAt, pressAt + 5], [0, 1, 0], clamp);
  return <span style={{ marginLeft: "auto", height: pt(26), padding: `0 ${pt(12)}px`, borderRadius: pt(7), background: G.signal, color: G.signalInk, fontSize: pt(13), fontWeight: 600, display: "inline-flex", alignItems: "center", opacity: 1 - press * 0.22 }}>{label}</span>;
};

const Trash: React.FC = () => (
  <svg width={pt(14)} height={pt(14)} viewBox="0 0 24 24" fill="none" stroke={G.faint} strokeWidth="2" strokeLinecap="round">
    <path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13" />
  </svg>
);

/** A row that springs open when it is added (withAnimation(OmilMotion.standard)). */
const Inserted: React.FC<{ at: number; children: React.ReactNode; height: number }> = ({ at, children, height }) => {
  const frame = useCurrentFrame();
  if (frame < at) return null;
  const p = Math.min(1, omil(frame, at));
  return <div style={{ maxHeight: pt(height) * p, opacity: p, overflow: "hidden" }}>{children}</div>;
};

const Snippets: React.FC<{ s: WindowState }> = ({ s }) => {
  const frame = useCurrentFrame();
  const [t0, t1, b0, b1] = s.snippetTyping;
  const added = frame >= s.snippetAdd;
  const trigger = added ? "" : typed(frame, "sign off", t0, t1);
  const body = added ? "" : typed(frame, "Thanks! Talk soon,\nArpan", b0, b1);
  return (
    <div style={{ position: "absolute", left: pt(24), right: pt(24), top: pt(64), display: "flex", flexDirection: "column", gap: pt(18) }}>
      <FormSection
        header="New Snippet"
        footer={
          <>
            Say the phrase on its own or inside a sentence.
            <Prominent label="Add Snippet" pressAt={s.snippetAdd} />
          </>
        }
      >
        <Row>
          When I say
          <Field value={trigger} prompt="my intro" caret={!added && frame < b0} />
        </Row>
        <Row last style={{ flexDirection: "column", alignItems: "stretch", padding: `${pt(8)}px 0` }}>
          Write this
          <div style={{ marginTop: pt(6), padding: pt(8), minHeight: pt(56), borderRadius: pt(6), background: "rgba(29,29,31,0.04)", whiteSpace: "pre", color: body ? G.ink : G.faint }}>{body || "The text Omil should insert"}</div>
        </Row>
      </FormSection>
      <FormSection header="Saved Snippets">
        <Inserted at={s.snippetAdd} height={62}>
          <Row>
            <SnippetRow trigger="sign off" text="Thanks! Talk soon, Arpan" />
          </Row>
        </Inserted>
        <Row>
          <SnippetRow trigger="my address" text="221B Baker Street, London NW1 6XE" />
        </Row>
        <Row last>
          <SnippetRow trigger="calendar" text="cal.com/arpan/30min" />
        </Row>
      </FormSection>
    </div>
  );
};

const SnippetRow: React.FC<{ trigger: string; text: string }> = ({ trigger, text }) => (
  <div style={{ flex: 1, display: "flex", alignItems: "center", padding: `${pt(6)}px 0` }}>
    <div style={{ flex: 1 }}>
      <div style={{ fontWeight: 500 }}>“{trigger}”</div>
      <div style={{ color: G.muted, marginTop: pt(3) }}>{text}</div>
    </div>
    <Trash />
  </div>
);

const Dictionary: React.FC<{ s: WindowState }> = ({ s }) => {
  const frame = useCurrentFrame();
  const [h0, h1, w0, w1] = s.correctionTyping;
  const added = frame >= s.correctionAdd;
  const heard = added ? "" : typed(frame, "oh mill", h0, h1);
  const write = added ? "" : typed(frame, "Omil", w0, w1);
  const row = (k: string, v: string, last?: boolean) => (
    <Row last={last}>
      <span style={{ color: G.muted }}>{k}</span>
      <span style={{ margin: `0 ${pt(10)}px`, display: "inline-flex" }}>
        <Sym name="chevron.right" size={pt(9)} color={G.faint} weight={2.6} />
      </span>
      <span style={{ fontWeight: 500 }}>{v}</span>
      <span style={{ marginLeft: "auto" }}>
        <Trash />
      </span>
    </Row>
  );
  return (
    <div style={{ position: "absolute", left: pt(24), right: pt(24), top: pt(64), display: "flex", flexDirection: "column", gap: pt(18) }}>
      <FormSection
        header="New Correction"
        footer={
          <>
            Use this for names and words Omil mishears.
            <Prominent label="Add Correction" pressAt={s.correctionAdd} />
          </>
        }
      >
        <Row>
          When I say
          <Field value={heard} prompt="oh mill" caret={!added && frame < w0} />
        </Row>
        <Row last>
          Write instead
          <Field value={write} prompt="Omil" caret={!added && frame >= w0} />
        </Row>
      </FormSection>
      {/* keys are sorted, so the new correction lands second */}
      <FormSection header="Corrections">
        {row("cube and eighties", "Kubernetes")}
        <Inserted at={s.correctionAdd} height={37}>
          {row("oh mill", "Omil")}
        </Inserted>
        {row("our pan", "Arpan")}
        {row("post grass", "PostgreSQL", true)}
      </FormSection>
    </div>
  );
};

/** ToastCenter: a 38 pt capsule that rises from the bottom. */
const Toasts: React.FC<{ s: WindowState }> = ({ s }) => {
  const frame = useCurrentFrame();
  const list: [number, string][] = [
    [s.snippetAdd + 3, "Snippet Added"],
    [s.correctionAdd + 3, "Correction Added"],
  ];
  const current = [...list].reverse().find(([at]) => frame >= at);
  if (!current) return null;
  const [at, label] = current;
  const inP = Math.min(1, omil(frame, at));
  const outP = interpolate(frame, [at + 40, at + 48], [0, 1], clamp);
  const p = inP * (1 - outP);
  if (p <= 0) return null;
  return (
    <div style={{ position: "absolute", left: pt(DETAIL_X), right: 0, bottom: pt(20), display: "flex", justifyContent: "center", opacity: p, translate: `0px ${(1 - inP) * pt(30)}px`, scale: String(0.96 + 0.04 * inP) }}>
      <div style={{ height: pt(38), padding: `0 ${pt(16)}px`, borderRadius: 99, background: G.floating, boxShadow: `inset 0 0 0 ${pt(0.5)}px ${G.hairline}`, display: "flex", alignItems: "center", gap: pt(8) }}>
        <Sym name="checkmark.circle.fill" size={pt(15)} color={G.signal} />
        <span style={{ fontSize: pt(13), fontWeight: 500, color: G.ink }}>{label}</span>
      </div>
    </div>
  );
};
