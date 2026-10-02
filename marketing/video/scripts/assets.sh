#!/usr/bin/env bash
# Fetches music + SFX and renders the voice. All sources are free for commercial use:
#   Music: "House Fest" by Alejandro Magaña (A. M.), Mixkit Stock Music Free License
#   SFX: Mixkit Sound Effects Free License; Kenney Interface Sounds (CC0)
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
mk() { curl -sfL -A "Mozilla/5.0" -o "$tmp/$1" "$2"; }

# Music: "House Fest" (123 BPM), re-arranged bar by bar to fit the video (scripts/music.py),
# which also writes the kick envelope used for bass-reactive motion.
mk music.mp3 https://assets.mixkit.co/music/113/113.mp3
mkdir -p public/music
"${PYTHON:-/tmp/kokoro-env/bin/python}" scripts/music.py "$tmp/music.mp3"

mk whoosh.mp3 https://assets.mixkit.co/active_storage/sfx/1490/1490-preview.mp3
mk sweep.mp3 https://assets.mixkit.co/active_storage/sfx/166/166-preview.mp3
mk pop.mp3 https://assets.mixkit.co/active_storage/sfx/3005/3005-preview.mp3
mk chime.mp3 https://assets.mixkit.co/active_storage/sfx/2867/2867-preview.mp3
mk typing.mp3 https://assets.mixkit.co/active_storage/sfx/2538/2538-preview.mp3
for f in select_002 click_004 toggle_002 pluck_001 pluck_002 confirmation_002; do
  mk "$f.ogg" "https://raw.githubusercontent.com/kapishdima/soundcn/main/assets/kenney_interface-sounds/$f.ogg"
done
for f in whoosh sweep pop chime; do ffmpeg -y -loglevel error -i "$tmp/$f.mp3" -ar 48000 public/sfx/$f.wav; done
ffmpeg -y -loglevel error -ss 6.0 -t 1.3 -i "$tmp/typing.mp3" -af "afade=t=out:st=1.1:d=0.2" -ar 48000 public/sfx/typing.wav
ffmpeg -y -loglevel error -i "$tmp/select_002.ogg" -i "$tmp/click_004.ogg" -filter_complex "[1]adelay=12[b];[0][b]amix=inputs=2:normalize=0" -ar 48000 public/sfx/key-down.wav
ffmpeg -y -loglevel error -i "$tmp/click_004.ogg" -ar 48000 public/sfx/key-up.wav
ffmpeg -y -loglevel error -i "$tmp/toggle_002.ogg" -ar 48000 public/sfx/toggle.wav
ffmpeg -y -loglevel error -i "$tmp/pluck_001.ogg" -ar 48000 public/sfx/pluck.wav
ffmpeg -y -loglevel error -i "$tmp/pluck_002.ogg" -ar 48000 public/sfx/incoming.wav
ffmpeg -y -loglevel error -i "$tmp/confirmation_002.ogg" -ar 48000 public/sfx/done.wav

# SF Pro / SF Mono from this Mac (Apple's license allows UI mockups for Apple platforms, not redistribution).
mkdir -p public/fonts
cp /System/Library/Fonts/SFNS.ttf /System/Library/Fonts/SFNSMono.ttf public/fonts/

# Voice: the chosen Qwen3-TTS take (see scripts/voice.py), lightly cleaned and loudness-normalised,
# then word-aligned so captions and demo cues follow it.
mkdir -p public/voice
ffmpeg -y -loglevel error -i voice/qwen3-clone-take6.wav -af "aresample=48000:resampler=soxr,highpass=f=70,loudnorm=I=-16:TP=-1.5:LRA=7" public/voice/demo.wav
bun scripts/align-voice.ts >/dev/null
rm -rf "$tmp"
echo "assets ready"
