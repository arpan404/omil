# Builds public/music/track.wav from "Driving Ambition" by Ahjay Stelino (Mixkit, ~99.8 BPM,
# C major) by re-ordering whole bars: the gentle intro under the title and the dictation, the
# lift (bass and drums entering) on the feature section, its peak under the privacy line and its
# own resolving ending under the logo.
import subprocess, sys
import numpy as np

SRC = sys.argv[1] if len(sys.argv) > 1 else "/tmp/music3/32.mp3"
SR = 48000
BEAT = 0.60128                # fitted from librosa beat times
BAR = 4 * BEAT
PHASE = 0.050                 # first downbeat in the source

# Video bar -> source bar (22.5 bars). Story beats in brackets.
PLAN = [5, 6, 7,                              # v0-2   problem + answer
        8, 9, 10, 11, 12, 13, 14, 15,         # v3-10  how it works, why it's smart
        16, 17, 18,                           # v11-13 lift: make it yours
        19, 20, 21, 22, 23,                   # v14-18 everywhere: pair, iPhone keyboard, iPad
        35,                                   # v19    peak: private by design
        36, 37, 38]                           # v20-22 the track's own ending under the call to action
TOTAL_BARS = 22.5

raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", SRC, "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"], capture_output=True, check=True).stdout
src = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2)

def bar(k):
    a = int(round((PHASE + k * BAR) * SR))
    return src[a:int(round((PHASE + (k + 1) * BAR) * SR))].copy()

fade = int(0.008 * SR)
ramp = np.linspace(0, 1, fade, dtype=np.float32)[:, None]
parts = []
for i, k in enumerate(PLAN):
    seg = bar(k)
    if i > 0 and PLAN[i - 1] != k - 1:
        seg[:fade] *= ramp
        parts[-1][-fade:] *= ramp[::-1]
    parts.append(seg)
out = np.concatenate(parts)[: int(round(TOTAL_BARS * BAR * SR))]
fi = int(0.4 * SR)
out[:fi] *= np.linspace(0, 1, fi, dtype=np.float32)[:, None]
fl = int(1.2 * SR)
out[-fl:] *= np.linspace(1, 0, fl, dtype=np.float32)[:, None] ** 2
out = out / np.abs(out).max() * 0.89
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "f32le", "-ac", "2", "-ar", str(SR), "-i", "-", "-c:a", "pcm_s16le", "public/music/track.wav"], input=out.astype(np.float32).tobytes(), check=True)
print(f"track {len(out) / SR:.2f}s")
