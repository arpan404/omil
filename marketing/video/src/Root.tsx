import React from "react";
import { Composition, Folder } from "remotion";
import { Everywhere } from "./scenes/Everywhere";
import { Screen } from "./scenes/Screen";
import { Hook, Outro, Title, Trust } from "./scenes/Story";
import { barF, END, FPS, PUSH_FRAMES, SCENE } from "./timeline";
import { SiteShots } from "./SiteShots";
import { OmilLaunch } from "./Video";

const len = (id: keyof typeof SCENE, extra = 0) => barF(SCENE[id].to) - barF(SCENE[id].from) + extra;

export const Root: React.FC = () => (
  <>
    <Composition id="OmilLaunch" component={OmilLaunch} durationInFrames={END} fps={FPS} width={1920} height={1080} />
    <Folder name="Scenes">
      <Composition id="Hook" component={Hook} durationInFrames={len("hook")} fps={FPS} width={1920} height={1080} />
      <Composition id="Title" component={Title} durationInFrames={len("title")} fps={FPS} width={1920} height={1080} />
      <Composition id="Screen" component={Screen} durationInFrames={len("screen", PUSH_FRAMES / 2)} fps={FPS} width={1920} height={1080} />
      <Composition id="Everywhere" component={Everywhere} durationInFrames={len("everywhere", PUSH_FRAMES / 2)} fps={FPS} width={1920} height={1080} />
      <Composition id="Trust" component={Trust} durationInFrames={len("trust")} fps={FPS} width={1920} height={1080} />
      <Composition id="Outro" component={Outro} durationInFrames={END - barF(SCENE.outro.from)} fps={FPS} width={1920} height={1080} />
    </Folder>
    <SiteShots />
  </>
);
