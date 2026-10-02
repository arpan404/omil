import React from "react";
import { Composition, Folder } from "remotion";
import { Everywhere } from "./scenes/Everywhere";
import { CleanDesktop } from "./scenes/Screen";
import { barF, FPS, SCENE } from "./timeline";

// Clean renders of the app UI for the marketing site (site/public/media), made with
// `bun run site-media`. Each crop is in Mac screen pixels (1920x1080).
const LEN = barF(SCENE.screen.to) - barF(SCENE.screen.from);

export const SiteShots: React.FC = () => (
  <Folder name="Site">
    {/* The whole Mac screen, without the pill (the site draws its own) */}
    <Composition id="SiteDesktop" component={() => <CleanDesktop crop={{ x: 0, y: 0 }} pill={false} />} durationInFrames={LEN} fps={FPS} width={1920} height={1080} />
    {/* iPhone and iPad on a transparent background (crop in the media script) */}
    <Composition id="SiteDevices" component={() => <Everywhere transparent />} durationInFrames={barF(SCENE.everywhere.to) - barF(SCENE.everywhere.from) + 10} fps={FPS} width={1920} height={1080} />
  </Folder>
);
