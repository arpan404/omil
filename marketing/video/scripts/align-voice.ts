// Word-aligns public/voice/demo.wav with whisper.cpp and writes src/voice-timing.json,
// which drives the live caption and the demo's cue timing.
import { $ } from "bun";
import { homedir } from "node:os";

const MODEL = process.env.WHISPER_MODEL ?? `${homedir()}/Library/Application Support/Omil/server/models/ggml-large-v3-turbo-q8_0.bin`;
const tmp = "/tmp/omil-voice-align";
await $`ffmpeg -y -loglevel error -i public/voice/demo.wav -ar 16000 -ac 1 ${tmp}.wav`;
await $`whisper-cli -m ${MODEL} -f ${tmp}.wav -ml 1 -sow -oj -of ${tmp} -np --prompt ${"Um, uh."}`.quiet();

type Seg = { offsets: { from: number; to: number }; text: string };
const json = (await Bun.file(`${tmp}.json`).json()) as { transcription: Seg[] };
const words = json.transcription
  .map((s) => ({ text: s.text.trim(), at: s.offsets.from / 1000, end: s.offsets.to / 1000 }))
  .filter((w) => w.text.length > 0);

// Whisper's word starts run early; snap each to the first loud sample after it.
const pcm = new Int16Array(await $`ffmpeg -loglevel error -i ${tmp}.wav -f s16le -ac 1 -`.arrayBuffer());
const loud = (t: number) => {
  const sr = 16000;
  const win = sr / 100;
  for (let i = Math.floor(t * sr); i < pcm.length - win; i += win) {
    let s = 0;
    for (let j = 0; j < win; j++) s += pcm[i + j] * pcm[i + j];
    if (Math.sqrt(s / win) > 900) return i / sr;
  }
  return t;
};
const aligned = words.map((w, i) => {
  const next = words[i + 1]?.at ?? w.end;
  return { ...w, at: Math.min(loud(w.at), next - 0.02) };
});
const end = aligned.at(-1)!.end;
await Bun.write("src/voice-timing.json", JSON.stringify({ words: aligned, end }, null, 2));
console.log(aligned.map((w) => `${w.at.toFixed(2)} ${w.text}`).join("\n"), `\nend ${end.toFixed(2)}s`);
