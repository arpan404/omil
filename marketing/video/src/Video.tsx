import React from "react";
import { Audio } from "@remotion/media";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { slide } from "@remotion/transitions/slide";
import { AbsoluteFill, interpolate, Sequence, staticFile } from "remotion";
import { Everywhere, T as E } from "./scenes/Everywhere";
import { Screen } from "./scenes/Screen";
import { Hook, Outro, Title, Trust } from "./scenes/Story";
import { barF, DEMO, END, f, PUSH_FRAMES, SCENE, VOICE_END } from "./timeline";
import { glide, STAGE } from "./theme";

const at = (b: number) => barF(b);
const HALF = PUSH_FRAMES / 2;

/** The story: problem → answer → how it works → why it's smart → make it yours → everywhere → trust → call to action. */
export const OmilLaunch: React.FC = () => (
  <AbsoluteFill style={{ background: STAGE }}>
    <Sequence name="1 · The problem" from={at(SCENE.hook.from)} durationInFrames={at(SCENE.hook.to) - at(SCENE.hook.from)}>
      <Hook />
    </Sequence>
    <Sequence name="2 · The answer" from={at(SCENE.title.from)} durationInFrames={at(SCENE.title.to) - at(SCENE.title.from)}>
      <Title />
    </Sequence>
    {/* 3-5 · one continuous screen take, then a push to iPhone and iPad centred on bar 14 */}
    <Sequence name="3-6 · Screen → Everywhere" from={at(SCENE.screen.from)} durationInFrames={at(SCENE.everywhere.to) - at(SCENE.screen.from)}>
      <TransitionSeries>
        <TransitionSeries.Sequence name="Screen" durationInFrames={at(SCENE.screen.to) - at(SCENE.screen.from) + HALF}>
          <Screen />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={slide({ direction: "from-right" })} timing={linearTiming({ durationInFrames: PUSH_FRAMES, easing: glide })} />
        <TransitionSeries.Sequence name="Everywhere" durationInFrames={at(SCENE.everywhere.to) - at(SCENE.everywhere.from) + HALF}>
          <Everywhere />
        </TransitionSeries.Sequence>
      </TransitionSeries>
    </Sequence>
    <Sequence name="7 · Trust" from={at(SCENE.trust.from)} durationInFrames={at(SCENE.trust.to) - at(SCENE.trust.from)}>
      <Trust />
    </Sequence>
    <Sequence name="8 · Call to action" from={at(SCENE.outro.from)} durationInFrames={END - at(SCENE.outro.from)}>
      <Outro />
    </Sequence>
    <Soundtrack />
  </AbsoluteFill>
);

/** A quiet UI sound at absolute frame `at`. */
const Click: React.FC<{ at: number; volume?: number; name?: string }> = ({ at, volume = 0.3, name = "key-up" }) => (
  <Sequence name={name} from={at} layout="none">
    <Audio src={staticFile(`sfx/${name}.wav`)} volume={volume} />
  </Sequence>
);

const Soundtrack: React.FC = () => (
  <>
    <Audio
      name="Music"
      src={staticFile("music/track.wav")}
      volume={(frame) =>
        interpolate(frame, [0, f(DEMO.voice - 0.4), f(DEMO.voice), f(DEMO.voice + VOICE_END), f(DEMO.keyUp + 0.8)], [0.8, 0.8, 0.3, 0.3, 0.8], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        })
      }
    />
    <Audio name="Voice" src={staticFile("voice/demo.wav")} from={f(DEMO.voice)} volume={0.85} />
    {/* only the real interactions, kept soft */}
    <Click at={f(DEMO.keyDown)} name="key-down" volume={0.28} />
    <Click at={f(DEMO.keyUp)} volume={0.4} />
    <Click at={f(DEMO.send)} volume={0.35} />
    <Click at={f(DEMO.changesClick)} volume={0.3} />
    <Click at={f(DEMO.verbatimClick)} volume={0.3} />
    <Click at={f(DEMO.snippets) - 4} volume={0.3} />
    <Click at={f(DEMO.snippetAdd)} volume={0.3} />
    <Click at={f(DEMO.dictionary) - 4} volume={0.3} />
    <Click at={f(DEMO.correctionAdd)} volume={0.3} />
    {/* iPhone and iPad taps (Everywhere starts half a push before bar 14) */}
    {[E.scanTap, E.micPhone, E.backTap, E.donePhone, E.sendPhone, E.micPad, E.donePad].map((t) => (
      <Click key={t} at={at(SCENE.everywhere.from) - HALF + t} volume={0.22} />
    ))}
  </>
);
