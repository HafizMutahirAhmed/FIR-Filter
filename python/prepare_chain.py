"""
prepare_chain.py
SOFTWARE side of the whole-chain audio verification
(mic PDM -> pdm_decimator -> fir_filter -> pwm_out).

1. Reads a WAV file and converts it to 39,062.5 Hz samples (as prepare_audio.py).
2. Turns the audio into the 1-bit PDM stream a MEMS microphone would produce:
   upsample x64 to 2.5 MHz and run a first-order sigma-delta modulator.
   -> sim/vectors/chain_pdm.txt   (one bit per line, this is the input for
                                   BOTH software and hardware)
3. Bit-exact software models of every block, for bypass/low-pass/high-pass:
     pdm_decimator : pcm[j] = (ones in bits[64j .. 64j+63] - 32) * 512
     fir_filter    : same model as prepare_audio.py
     pwm_out       : duty = sat8((fir >> 8) << 1) + 128
   -> sim/vectors/chain_expected_pcm.txt
      sim/vectors/chain_expected_fir_<mode>.txt
      audio/sw_chain_<mode>.wav

Then run sim/tb_chain_audio.sv and compare with compare_chain.py.

Run:  python3 prepare_chain.py [file.wav] [seconds]
      default file: ../audio/input.wav, default seconds: 0.5
"""
import sys
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile

from prepare_audio import (load_wav_as_fpga_samples, read_mem, fir_model,
                           write_ints, COEFF_DIR, VEC_DIR, AUDIO_DIR, FS_FPGA, MODES)

DECIM = 64
PDM_LEVEL = 0.8      # peak level of the audio inside the PDM stream (<1 for a stable modulator)
OUT_GAIN_SHIFT = 1


def to_pdm(x16):
    """Audio samples (int16 at 39 kHz) -> PDM bits at 2.5 MHz (first-order sigma-delta)."""
    u = signal.resample_poly(x16 / 32768.0, DECIM, 1) * PDM_LEVEL / 0.9
    u = np.clip(u, -0.99, 0.99)
    bits = np.empty(len(u), dtype=np.int8)
    integ = 0.0
    for i, v in enumerate(u):
        b = 1 if integ >= 0.0 else 0
        bits[i] = b
        integ += v - (1.0 if b else -1.0)
    return bits


def decimator_model(bits):
    """Bit-exact model of pdm_decimator.sv: count ones in each 64-bit window."""
    n = len(bits) // DECIM
    ones = bits[:n * DECIM].reshape(n, DECIM).sum(axis=1).astype(np.int64)
    return (ones - DECIM // 2) * 512


def pwm_duty_model(fir):
    """Bit-exact model of the sample -> duty conversion in pwm_out.sv."""
    level = (np.asarray(fir, dtype=np.int64) >> 8) << OUT_GAIN_SHIFT
    return np.clip(level, -128, 127) + 128


def main():
    wav = Path(sys.argv[1]) if len(sys.argv) > 1 else AUDIO_DIR / "input.wav"
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5

    _, x = load_wav_as_fpga_samples(wav, seconds)
    bits = to_pdm(x)
    VEC_DIR.mkdir(parents=True, exist_ok=True)
    AUDIO_DIR.mkdir(exist_ok=True)
    with open(VEC_DIR / "chain_pdm.txt", "w") as f:
        f.write("\n".join("1" if b else "0" for b in bits) + "\n")
    print(f"Input : {wav}, {seconds} s -> {len(x)} samples -> {len(bits)} PDM bits at 2.5 MHz")

    pcm = decimator_model(bits)
    write_ints(VEC_DIR / "chain_expected_pcm.txt", pcm)
    print(f"Software decimator: {len(pcm)} PCM samples -> chain_expected_pcm.txt")

    for mode in MODES:
        fir = fir_model(pcm, read_mem(COEFF_DIR / f"{mode}.mem"))
        write_ints(VEC_DIR / f"chain_expected_fir_{mode}.txt", fir)
        wavfile.write(AUDIO_DIR / f"sw_chain_{mode}.wav", int(FS_FPGA), fir.astype(np.int16))
        print(f"Software {mode:9s}: chain_expected_fir_{mode}.txt, audio/sw_chain_{mode}.wav")

    print("\nNext: run the tb_chain_audio simulation, then compare_chain.py")


if __name__ == "__main__":
    main()
