# Regenerates voice/qwen3-clone-take6.wav, the demo line used in the video.
#
# Model: Qwen3-TTS 1.7B Base (Apache-2.0) via mlx-audio, cloning the `en_man` sample voice
# from github.com/boson-ai/higgs-audio (examples/voice_prompts, Apache-2.0). Chosen from a
# shoot-out of Qwen3-TTS, Fish S2 Pro, Higgs v2/v3, VoxCPM2, Dia, Voxtral and Kokoro, scored
# with UTMOS naturalness, pitch range and whisper accuracy.
#
# Setup:  uv venv --python 3.12 /tmp/mlxa-env && uv pip install mlx-audio soundfile
# Run:    /tmp/mlxa-env/bin/python scripts/voice.py
import os, urllib.request
import numpy as np, soundfile as sf, mlx.core as mx
from mlx_audio.tts.utils import load_model

TEXT = "Um, so I think we should... uh, ship it on Friday. No, wait. Thursday."
BASE = "https://raw.githubusercontent.com/boson-ai/higgs-audio/main/examples/voice_prompts/en_man"
os.makedirs("/tmp/omil-ref", exist_ok=True)
for ext in ("wav", "txt"):
    urllib.request.urlretrieve(f"{BASE}.{ext}", f"/tmp/omil-ref/en_man.{ext}")

model = load_model("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")
mx.random.seed(int(os.environ.get("SEED", "6")))
results = list(model.generate(text=TEXT, ref_audio="/tmp/omil-ref/en_man.wav", ref_text=open("/tmp/omil-ref/en_man.txt").read().strip()))
audio = np.concatenate([np.array(r.audio).reshape(-1) for r in results])
sf.write("voice/qwen3-clone-take6.wav", audio, results[0].sample_rate)
print("wrote voice/qwen3-clone-take6.wav")
