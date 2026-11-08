"""
make_demo_audio.py
Creates a 3-second demo audio file audio/input.wav (44.1 kHz, 16-bit, mono)
that makes the filter effect easy to hear and see:
  0.0 - 1.0 s : a short melody (notes 262..523 Hz with harmonics)
                plus "hi-hat" noise bursts (mostly high frequencies)
  1.0 - 3.0 s : a sweep (chirp) from 100 Hz to 15 kHz
You can use any other WAV file instead (see prepare_audio.py).

Run:  python3 make_demo_audio.py
"""
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile

FS = 44100
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "audio" / "input.wav"


def main():
    rng = np.random.default_rng(1)
    t = np.arange(int(1.0 * FS)) / FS

    # melody: 8 notes of 1/8 s, each with 3 harmonics and a soft envelope
    notes = [262, 294, 330, 349, 392, 440, 494, 523]
    melody = np.zeros_like(t)
    seg = len(t) // len(notes)
    env = np.hanning(seg)
    for i, f in enumerate(notes):
        tt = t[:seg]
        tone = (np.sin(2 * np.pi * f * tt) + 0.5 * np.sin(2 * np.pi * 2 * f * tt)
                + 0.25 * np.sin(2 * np.pi * 3 * f * tt))
        melody[i * seg:(i + 1) * seg] = tone * env

    # hi-hat: high-passed noise bursts every 1/8 s
    noise = signal.lfilter(*signal.butter(4, 6000, "highpass", fs=FS),
                           rng.standard_normal(len(t)))
    hihat = np.zeros_like(t)
    burst = int(0.03 * FS)
    for i in range(len(notes)):
        start = i * seg + seg // 2
        hihat[start:start + burst] = noise[start:start + burst] * np.exp(-np.arange(burst) / (0.006 * FS))
    part1 = 0.35 * melody / np.max(np.abs(melody)) + 0.35 * hihat / np.max(np.abs(hihat))

    # sweep 100 Hz -> 15 kHz
    t2 = np.arange(int(2.0 * FS)) / FS
    part2 = 0.6 * signal.chirp(t2, 100, t2[-1], 15000, method="logarithmic")

    audio = np.concatenate([part1, part2])
    OUT.parent.mkdir(exist_ok=True)
    wavfile.write(OUT, FS, np.round(audio * 32767).astype(np.int16))
    print(f"Wrote {OUT} ({len(audio) / FS:.1f} s, {FS} Hz, mono, 16-bit)")


if __name__ == "__main__":
    main()
