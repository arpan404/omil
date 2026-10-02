import React from "react";
import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { BackBreadcrumb, IOS, KeyboardCues, KeyboardFooter, keyboardTargets, OmilKeyboard, PAD, Pad, PAIRING_URL, Phone, PHONE, QR, ReturnScreen, ScannerScreen, StatusBar, SystemKeyboard, Tap, YourMacScreen } from "../components/IOS";
import { Sym } from "../components/Symbols";
import { BEAT_S, f, PUSH_FRAMES, SCENE } from "../timeline";
import { clamp, display, G, glide, INK, MONO, omil, SF, STAGE } from "../theme";

/** Devices only, on transparent ground (the site's renders): no headlines or captions. */
const DevicesOnly = React.createContext(false);

const IN = PUSH_FRAMES / 2; // the push from the Mac lands here
const b = (n: number) => IN + f(n * BEAT_S);
const END = IN + f((SCENE.everywhere.to - SCENE.everywhere.from) * 4 * BEAT_S);

// Cues (beats from the start of the chapter)
export const T = {
  scanTap: b(1),
  scanner: b(1.25),
  lock: b(2.6),
  scannerGone: b(3.3),
  connected: b(3.5),
  toPhone: b(5.6), // chapter 2: Messages, with the Omil keyboard
  appSwitch: b(5.9),
  micPhone: b(7),
  omilOpen: b(7.1), // the keyboard opens Omil, already listening
  backTap: b(8.8), // "◀ Messages"
  donePhone: b(10.6),
  insertPhone: b(11.4),
  ownKeyboard: b(12.2), // back to the user's own keyboard
  sendPhone: b(13.1),
  toPad: b(14), // chapter 3: the mic is ready, no trip to the app
  micPad: b(15.2),
  recordPad: b(15.4),
  donePad: b(17.4),
  insertPad: b(18),
};

const PHONE_TEXT = "Running ten minutes late. Start without me.";
const PAD_TEXT = "The release notes look great. Let's ship them with Thursday's build.";
const MAC = "Arpan's MacBook Pro";
const PHONE_CUES: KeyboardCues = { mic: T.micPhone, record: T.backTap + 4, done: T.donePhone, insert: T.insertPhone };
const PAD_CUES: KeyboardCues = { mic: T.micPad, record: T.recordPad, done: T.donePad, insert: T.insertPad };

/** 6. Everywhere: pair with the Mac, then dictate into any app with the Omil keyboard on iPhone and iPad. */
export const Everywhere: React.FC<{ transparent?: boolean }> = ({ transparent = false }) => (
  <DevicesOnly.Provider value={transparent}>
    <EverywhereScene transparent={transparent} />
  </DevicesOnly.Provider>
);

const EverywhereScene: React.FC<{ transparent: boolean }> = ({ transparent }) => {
  const frame = useCurrentFrame();
  const o = { ...clamp, easing: glide };
  const toPhone = interpolate(frame, [T.toPhone, T.toPhone + 20], [0, 1], o);
  const toPad = interpolate(frame, [T.toPad, T.toPad + 22], [0, 1], o);
  const out = interpolate(frame, [END - 9, END], [0, 1], o);
  // push in on the email and the keyboard as the text goes in, centring the iPad
  const zoom = interpolate(frame, [T.donePad - 6, T.insertPad + 8], [0, 1], o);

  // iPhone: right of the Mac sheet (small) → centre-left (full size) → off to the left
  const phoneX = interpolate(toPhone, [0, 1], [1150, 470]) - toPad * 900;
  const phoneY = interpolate(toPhone, [0, 1], [262, 105]);
  const phoneScale = interpolate(toPhone, [0, 1], [0.78, 1]);

  return (
    <AbsoluteFill style={{ background: transparent ? "transparent" : STAGE, opacity: 1 - out }}>
      {/* chapter 1: pairing */}
      <Headline
        at={IN + 2}
        until={T.toPhone}
        style={{ left: 0, right: 0, top: 78, textAlign: "center", alignItems: "center" }}
        title="Your Mac powers your iPhone and iPad."
        sub="Pair once with a QR code. No subscription, no cloud."
      />
      <div style={{ position: "absolute", left: 330 - toPhone * 700, top: 290, opacity: 1 - toPhone }}>
        <PairingSheet connectedAt={T.connected} />
      </div>

      {/* chapter 2: the iPhone */}
      <Headline
        at={T.toPhone + 8}
        until={T.toPad}
        style={{ left: 1030, width: 820, top: 0, bottom: 0, justifyContent: "center" }}
        title={"Dictate in\nany app."}
        sub="Tap the mic on the Omil keyboard and speak. Your words land where you type."
      />
      <Spoken from={PHONE_CUES.record} to={PHONE_CUES.done} text="Running ten minutes late, start without me." style={{ left: 60, width: 380, top: 470 }} />
      <div style={{ position: "absolute", left: phoneX, top: phoneY, scale: String(phoneScale), transformOrigin: "0 0" }}>
        <Phone>
          <PhoneScreen />
        </Phone>
      </div>

      {/* chapter 3: the iPad */}
      <Headline at={T.toPad + 10} until={T.insertPad - 10} style={{ left: 110, width: 560, top: 0, bottom: 0, justifyContent: "center" }} title="Same on iPad." sub="After the first time, the mic is ready right in the keyboard." />
      <Spoken from={PAD_CUES.record} to={PAD_CUES.done} text="The release notes look great, let's ship them with Thursday's build." style={{ left: 110, width: 560, top: 760 }} />
      {/* once it lands, push in on the draft and the keyboard so the insert reads */}
      <div style={{ position: "absolute", left: 700 + (1 - toPad) * 1300 - zoom * 271, top: 160 - zoom * 40, transformOrigin: "50% 64%", scale: String(1 + 0.24 * zoom) }}>
        <Pad k={0.86}>
          <MailCompose />
        </Pad>
      </div>
    </AbsoluteFill>
  );
};

const Headline: React.FC<{ at: number; until: number; title: string; sub: string; style: React.CSSProperties }> = ({ at, until, title, sub, style }) => {
  const frame = useCurrentFrame();
  if (React.useContext(DevicesOnly)) return null;
  const inP = Math.min(1, omil(frame, at));
  const out = interpolate(frame, [until - 8, until], [0, 1], { ...clamp, easing: glide });
  if (frame < at - 1 || out >= 1) return null;
  return (
    <div style={{ position: "absolute", display: "flex", flexDirection: "column", gap: 18, opacity: inP * (1 - out), translate: `0px ${(1 - inP) * 22 - out * 12}px`, ...style }}>
      <div style={{ ...display(76, 700), color: INK, whiteSpace: "pre-line" }}>{title}</div>
      <div style={{ fontFamily: SF, fontSize: 38, fontWeight: 500, lineHeight: 1.3, letterSpacing: "-0.01em", color: G.muted }}>{sub}</div>
    </div>
  );
};

// ---------------------------------------------------------------- Mac · Engine › Pair iPhone (LANPairingSheet)

const PairingSheet: React.FC<{ connectedAt: number }> = ({ connectedAt }) => {
  const frame = useCurrentFrame();
  const s = 1.18; // px per point
  const connected = Math.min(1, omil(frame, connectedAt));
  const steps = ["Open Omil on your iPhone.", "Go to Settings → Your Mac and tap Scan QR Code.", "Point the camera at this code."];
  return (
    <div style={{ width: 400 * s, borderRadius: 16 * s, background: "#F5F5F7", boxShadow: "0 0 0 0.5px rgba(0,0,0,0.18), 0 24px 60px -16px rgba(0,0,0,0.3)", fontFamily: SF, color: G.ink, overflow: "hidden" }}>
      <div style={{ height: 52 * s, display: "flex", alignItems: "center", justifyContent: "center", position: "relative", fontSize: 13 * s, fontWeight: 700 }}>
        Pair iPhone
        <span style={{ position: "absolute", right: 14 * s, height: 26 * s, padding: `0 ${12 * s}px`, borderRadius: 7 * s, background: G.signal, color: G.signalInk, fontSize: 13 * s, fontWeight: 600, display: "flex", alignItems: "center" }}>Done</span>
      </div>
      <div style={{ padding: `${6 * s}px ${28 * s}px ${24 * s}px`, display: "flex", flexDirection: "column", alignItems: "center", gap: 16 * s }}>
        <div style={{ position: "relative", padding: 14 * s, background: "#FFFFFF", borderRadius: 16 * s }}>
          <QR text={PAIRING_URL} size={176 * s} />
          <div style={{ position: "absolute", inset: 0, borderRadius: 16 * s, boxShadow: `0 0 0 ${3 * s}px rgba(48,209,88,${0.9 * connected})` }} />
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 9 * s, width: 290 * s }}>
          {steps.map((t, i) => (
            <div key={t} style={{ display: "flex", gap: 10 * s, alignItems: "baseline", fontSize: 13 * s }}>
              <span style={{ width: 20 * s, height: 20 * s, borderRadius: 99, background: G.signal, color: G.signalInk, fontSize: 11 * s, fontWeight: 700, display: "inline-flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>{i + 1}</span>
              {t}
            </div>
          ))}
        </div>
        <div style={{ fontSize: 11 * s, color: G.muted, textAlign: "center", width: 300 * s, display: "flex", gap: 5 * s, justifyContent: "center" }}>
          <Sym name="lock" size={11 * s} color={G.muted} weight={2.4} />
          This code includes your connection token. Only show it to devices you trust.
        </div>
        <div style={{ fontFamily: MONO, fontSize: 12 * s, color: G.faint }}>Arpans-MacBook-Pro.local:3217</div>
      </div>
    </div>
  );
};

// ---------------------------------------------------------------- iPhone screen sequence

const SW = PHONE.w - 2 * PHONE.bezel; // screen width in px (≈ points)
const SH = PHONE.h - 2 * PHONE.bezel;

const PhoneScreen: React.FC = () => {
  const frame = useCurrentFrame();
  const swap = interpolate(frame, [T.appSwitch, T.appSwitch + 14], [0, 1], { ...clamp, easing: glide });
  const scannerDown = Math.min(1, omil(frame, T.scannerGone));
  // the keyboard opens Omil (zooming up from the mic key), then "◀ Messages" brings you back
  const open = Math.min(1, omil(frame, T.omilOpen));
  const back = interpolate(frame, [T.backTap + 1, T.backTap + 12], [0, 1], { ...clamp, easing: glide });
  const mic = keyboardTargets(SW).mic;
  return (
    <div style={{ position: "absolute", inset: 0 }}>
      {/* Omil › Settings › Your Mac, then the swipe across the home indicator to Messages */}
      {frame < T.appSwitch + 16 && (
        <div style={{ position: "absolute", inset: 0, translate: `${-swap * SW}px 0px` }}>
          <YourMacScreen tapAt={T.scanTap} connectedAt={T.connected} />
          <Tap x={SW / 2} y={360} at={T.scanTap} />
          {frame >= T.scanner && frame < T.scannerGone + 20 && (
            <div style={{ position: "absolute", inset: 0, translate: `0px ${scannerDown * SH}px` }}>
              <ScannerScreen from={T.scanner} lockAt={T.lock} />
            </div>
          )}
        </div>
      )}
      {frame >= T.appSwitch && (
        <div style={{ position: "absolute", inset: 0, translate: `${(1 - swap) * SW}px 0px` }}>
          <MessagesIOS />
        </div>
      )}
      {frame >= T.omilOpen && back < 1 && (
        <div
          style={{
            position: "absolute",
            inset: 0,
            transformOrigin: `${mic.x}px ${KB_TOP + mic.y}px`,
            scale: String((0.12 + 0.88 * open) * (1 - 0.08 * back)),
            opacity: Math.min(1, open * 3) * (1 - back),
            borderRadius: 40 * (1 - open),
            overflow: "hidden",
          }}
        >
          <ReturnScreen from={T.omilOpen} app="Messages" backAt={T.backTap} />
        </div>
      )}
      <Tap x={50} y={26} at={T.backTap} />
    </div>
  );
};

/** What the speaker says, word by word, beside the device while the keyboard listens. */
const Spoken: React.FC<{ from: number; to: number; text: string; style: React.CSSProperties }> = ({ from, to, text, style }) => {
  const frame = useCurrentFrame();
  if (React.useContext(DevicesOnly)) return null;
  const words = text.split(" ");
  const shown = interpolate(frame, [from + 3, to - 6], [0, words.length], clamp);
  const fade = interpolate(frame, [from - 4, from + 4, to + 6, to + 16], [0, 1, 1, 0], clamp);
  if (fade <= 0) return null;
  return (
    <div style={{ position: "absolute", display: "flex", flexDirection: "column", gap: 14, opacity: fade, ...style }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, fontFamily: SF, fontSize: 24, fontWeight: 600, color: G.recording }}>
        <Sym name="mic.fill" size={24} color={G.recording} /> Speaking
      </div>
      <div style={{ fontFamily: SF, fontSize: 36, fontWeight: 500, lineHeight: 1.3, color: INK }}>
        “
        {words.map((w, i) => (
          <span key={i} style={{ opacity: Math.max(0.15, Math.min(1, shown - i)) }}>
            {w}{i < words.length - 1 ? " " : ""}
          </span>
        ))}
        ”
      </div>
    </div>
  );
};

const Monogram: React.FC<{ text: string; size: number }> = ({ text, size }) => (
  <div style={{ width: size, height: size, borderRadius: 99, background: "#A2A7B2", color: "white", fontWeight: 600, fontSize: size * 0.4, display: "flex", alignItems: "center", justifyContent: "center" }}>{text}</div>
);

const KB_TOP = SH - 216 - 70; // the Omil keyboard, then iOS's globe and dictation strip

const MessagesIOS: React.FC = () => {
  const frame = useCurrentFrame();
  const inserted = frame >= T.insertPhone;
  const sent = frame >= T.sendPhone;
  const bubble = Math.min(1, omil(frame, T.sendPhone));
  const fade = Math.min(1, omil(frame, T.insertPhone));
  const own = interpolate(frame, [T.ownKeyboard, T.ownKeyboard + 6], [0, 1], clamp);
  const caretOn = Math.floor(frame / 15) % 2 === 0;
  const kbTop = KB_TOP;
  const { mic, done } = keyboardTargets(SW);
  const returning = frame >= T.backTap && frame < T.backTap + 60;
  return (
    <div style={{ position: "absolute", inset: 0, background: "#FFFFFF", fontFamily: SF }}>
      {returning ? <BackBreadcrumb app="Omil" /> : <StatusBar />}
      <div style={{ position: "absolute", top: 54, left: 0, right: 0, display: "flex", flexDirection: "column", alignItems: "center", gap: 4 }}>
        <Monogram text="LP" size={50} />
        <span style={{ fontSize: 12, color: IOS.label }}>Leo Park ›</span>
      </div>
      <div style={{ position: "absolute", left: 14, right: 14, bottom: SH - kbTop + 62, display: "flex", flexDirection: "column", gap: 6, fontSize: 17 }}>
        <div style={{ alignSelf: "center", fontSize: 12, color: IOS.secondary, marginBottom: 6 }}>Today 10:41 AM</div>
        <div style={{ alignSelf: "flex-start", maxWidth: 270, padding: "8px 13px", borderRadius: 19, background: IOS.bubble }}>Are you still coming to the 10:30?</div>
        {sent && (
          <div style={{ alignSelf: "flex-end", maxWidth: 280, padding: "8px 13px", borderRadius: 19, background: IOS.blue, color: "white", opacity: bubble, translate: `0px ${(1 - bubble) * 40}px`, scale: String(0.9 + 0.1 * bubble), transformOrigin: "100% 100%" }}>
            {PHONE_TEXT}
          </div>
        )}
      </div>
      {/* input bar */}
      <div style={{ position: "absolute", left: 10, right: 10, top: kbTop - 52, height: 44, display: "flex", alignItems: "center", gap: 8 }}>
        <div style={{ width: 36, height: 36, borderRadius: 99, background: "#EDEDF0", display: "flex", alignItems: "center", justifyContent: "center" }}>
          <Sym name="plus" size={18} color="#6B6B70" weight={2.4} />
        </div>
        <div style={{ flex: 1, minHeight: 36, borderRadius: 18, border: "1px solid rgba(0,0,0,0.14)", display: "flex", alignItems: "center", padding: "6px 6px 6px 14px", fontSize: 16, color: inserted && !sent ? IOS.label : "#A1A1A6", lineHeight: 1.25 }}>
          <span style={{ flex: 1 }}>
            {inserted && !sent ? <span style={{ opacity: fade, background: `rgba(0,122,255,${0.14 * (1 - fade)})` }}>{PHONE_TEXT}</span> : "iMessage"}
            {!sent && <span style={{ display: "inline-block", width: 2, height: 19, marginLeft: 1, verticalAlign: "-4px", background: IOS.blue, opacity: caretOn ? 1 : 0 }} />}
          </span>
          {inserted && !sent && (
            <div style={{ width: 28, height: 28, borderRadius: 99, background: IOS.blue, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
              <Sym name="arrow.up" size={16} color="white" />
            </div>
          )}
        </div>
      </div>
      {inserted && !sent && <Tap x={SW - 30} y={kbTop - 30} at={T.sendPhone} />}
      <div style={{ position: "absolute", left: 0, right: 0, top: kbTop, bottom: 0, background: IOS.keyboardTray }}>
        {/* after inserting, Omil hands back to your own keyboard */}
        <div style={{ position: "absolute", inset: 0, opacity: 1 - own }}>
          <OmilKeyboard cues={PHONE_CUES} mac={MAC} returnTitle="send" />
        </div>
        {own > 0 && (
          <div style={{ position: "absolute", inset: 0, opacity: own }}>
            <SystemKeyboard />
          </div>
        )}
        <div style={{ position: "absolute", left: 0, right: 0, bottom: 0 }}>
          <KeyboardFooter />
        </div>
      </div>
      <Tap x={mic.x} y={kbTop + mic.y} at={T.micPhone} />
      <Tap x={done.x} y={kbTop + done.y} at={T.donePhone} />
    </div>
  );
};

// ---------------------------------------------------------------- iPad · Mail

const MailCompose: React.FC = () => {
  const frame = useCurrentFrame();
  const k = 0.86;
  const inserted = frame >= T.insertPad;
  const fade = Math.min(1, omil(frame, T.insertPad));
  const caretOn = Math.floor(frame / 15) % 2 === 0;
  const kb = 264 * k;
  const { mic, done } = keyboardTargets(PAD.w * k, k);
  const row = (label: string, value: React.ReactNode) => (
    <div style={{ display: "flex", alignItems: "center", gap: 8 * k, height: 44 * k, borderBottom: `0.5px solid ${IOS.separator}`, fontSize: 17 * k }}>
      <span style={{ color: IOS.secondary }}>{label}</span>
      {value}
    </div>
  );
  return (
    <div style={{ position: "absolute", inset: 0, fontFamily: SF, color: IOS.label, background: "#E9E9EE" }}>
      <div style={{ position: "absolute", left: 120 * k, right: 120 * k, top: 26 * k, bottom: kb, borderRadius: `${14 * k}px ${14 * k}px 0 0`, background: "#FFFFFF", boxShadow: "0 0 0 0.5px rgba(0,0,0,0.08)", padding: `0 ${22 * k}px` }}>
        <div style={{ height: 56 * k, display: "flex", alignItems: "center", justifyContent: "center", position: "relative", fontSize: 17 * k, fontWeight: 600 }}>
          <span style={{ position: "absolute", left: 0, color: IOS.blue, fontWeight: 400 }}>Cancel</span>
          New Message
          <div style={{ position: "absolute", right: 0, width: 32 * k, height: 32 * k, borderRadius: 99, background: inserted ? IOS.blue : "#C7C7CC", display: "flex", alignItems: "center", justifyContent: "center" }}>
            <Sym name="arrow.up" size={18 * k} color="white" />
          </div>
        </div>
        {row("To:", <span style={{ padding: `${3 * k}px ${10 * k}px`, borderRadius: 99, background: "rgba(0,122,255,0.12)", color: IOS.blue }}>Maya Chen</span>)}
        {row("Cc/Bcc, From:", <span>arpan@omil.app</span>)}
        {row("Subject:", <span>Release notes</span>)}
        <div style={{ paddingTop: 16 * k, fontSize: 17 * k, lineHeight: 1.45 }}>
          <div>Hi Maya,</div>
          <div style={{ minHeight: 26 * k, marginTop: 12 * k }}>
            {inserted && <span style={{ opacity: fade, background: `rgba(0,122,255,${0.12 * (1 - fade)})` }}>{PAD_TEXT}</span>}
            <span style={{ display: "inline-block", width: 2, height: 20 * k, marginLeft: 1, verticalAlign: "-3px", background: IOS.blue, opacity: caretOn ? 1 : 0 }} />
          </div>
        </div>
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, bottom: 0 }}>
        <OmilKeyboard cues={PAD_CUES} mac={MAC} k={k} pad ready />
      </div>
      <Tap x={mic.x} y={PAD.h * k - kb + mic.y} at={T.micPad} />
      <Tap x={done.x} y={PAD.h * k - kb + done.y} at={T.donePad} />
    </div>
  );
};
