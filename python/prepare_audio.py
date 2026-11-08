"""
prepare_audio.py
SOFTWARE side of the audio-file verification.

1. Reads a WAV file (any sample rate, mono or stereo, 8/16/32-bit or float).
2. Mixes it to mono, resamples it to the FPGA sample rate (39,062.5 Hz) and
   converts it to 16-bit signed integers -> sim/vectors/audio_in.txt
   (this is the input for BOTH the software model and the hardware).
3. Filters it with the bit-exact software model of fir_filter.sv
   (same coefficients from coeffs/*.mem, same >>> 15 and saturation)
   for bypass, low-pass and high-pass:
       sim/vectors/audio_expected_<mode>.txt
       audio/sw_<mode>.wav           (listen to the software result)
       audio/input_39k.wav           (the input as the FPGA sees it)

Then run the hardware simulation (sim/tb_fir_audio.sv) and compare with
compare_audio.py.

Run:  python3 prepare_audio.py [file.wav] [max_seconds]
      default file: ../audio/input.wav, default max_seconds: 3
"""
import sys
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile

FS_FPGA = 2.5e6 / 64      # 39,062.5 Hz
ROOT = Path(__file__).resolve().parent.parent
COEFF_DIR = ROOT / "coeffs"
VEC_DIR = ROOT / "sim" / "vectors"
AUDIO_DIR = ROOT / "audio"
MODES = ["bypass", "lowpass", "highpass"]


def read_mem(path):
    """Read a .mem file (4-digit hex, two's complement) into signed ints."""
    vals = []
    for line in open(path):
        line = line.strip()
        if line:
            v = int(line, 16)
            vals.append(v - 0x10000 if v & 0x8000 else v)
    return np.array(vals, dtype=np.int64)


def fir_model(x, h):
    """Bit-exact model of fir_filter.sv (vectorised).
    acc[n] = sum h[k]*x[n-k] (exact 64-bit integers, delay line starts at 0)
    y[n]   = sat16(acc[n] >> 15)   (numpy >> on int64 is an arithmetic shift)
    """
    acc = np.convolve(x.astype(np.int64), h.astype(np.int64))[:len(x)]
    return np.clip(acc >> 15, -32768, 32767).astype(np.int64)


def load_wav_as_fpga_samples(path, max_seconds):
    fs_in, data = wavfile.read(path)
    # convert to float in -1..1
    if data.dtype == np.int16:
        data = data / 32768.0
    elif data.dtype == np.int32:
        data = data / 2147483648.0
    elif data.dtype == np.uint8:
        data = (data - 128) / 128.0
    else:
        data = data.astype(np.float64)
    if data.ndim == 2:                       # stereo -> mono
        data = data.mean(axis=1)
    data = data[:int(max_seconds * fs_in)]

    # resample fs_in -> 39,062.5 Hz with a rational ratio
    # 39062.5 = 78125 / 2, so ratio = 78125 / (2 * fs_in)
    up, down = 78125, 2 * fs_in
    g = np.gcd(up, down)
    y = signal.resample_poly(data, up // g, down // g)

    # normalise to 90 % of full scale so the whole range is exercised
    peak = np.max(np.abs(y))
    if peak > 0:
        y = y / peak * 0.9
    return fs_in, np.clip(np.round(y * 32767), -32768, 32767).astype(np.int64)


def write_ints(path, vals):
    with open(path, "w") as f:
        f.write("\n".join(str(int(v)) for v in vals) + "\n")


def write_wav(path, x):
    # WAV files need an integer rate; 39062 Hz plays 0.001 % slow (inaudible)
    wavfile.write(path, int(FS_FPGA), np.asarray(x, dtype=np.int16))


def main():
    wav = Path(sys.argv[1]) if len(sys.argv) > 1 else AUDIO_DIR / "input.wav"
    max_seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

    fs_in, x = load_wav_as_fpga_samples(wav, max_seconds)
    VEC_DIR.mkdir(parents=True, exist_ok=True)
    AUDIO_DIR.mkdir(exist_ok=True)
    write_ints(VEC_DIR / "audio_in.txt", x)
    write_wav(AUDIO_DIR / "input_39k.wav", x)
    print(f"Input : {wav} ({fs_in} Hz) -> {len(x)} samples at {FS_FPGA} Hz "
          f"({len(x) / FS_FPGA:.2f} s)")
    print(f"Wrote {VEC_DIR / 'audio_in.txt'}")

    for mode in MODES:
        h = read_mem(COEFF_DIR / f"{mode}.mem")
        y = fir_model(x, h)
        write_ints(VEC_DIR / f"audio_expected_{mode}.txt", y)
        write_wav(AUDIO_DIR / f"sw_{mode}.wav", y)
        print(f"Software {mode:9s}: wrote audio_expected_{mode}.txt and audio/sw_{mode}.wav")

    print("\nNext: run the tb_fir_audio simulation, then compare_audio.py")


if __name__ == "__main__":
    main()
