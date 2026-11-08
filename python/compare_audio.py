"""
compare_audio.py
Compares the HARDWARE output (fir_filter RTL in xsim, audio_out_<mode>.txt)
with the SOFTWARE output (Python model, audio_expected_<mode>.txt) for the
same audio input, sample by sample, and prints PASS/FAIL per mode.

Also writes:
  audio/hw_<mode>.wav        the hardware result, to listen to
  python/audio_compare.png   spectrograms of input / low-pass / high-pass and
                             the average spectrum of software vs hardware

Run:  python3 compare_audio.py [folder]     (default: ../sim/vectors)
"""
import sys
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

FS = 2.5e6 / 64
MODES = ["bypass", "lowpass", "highpass"]
HERE = Path(__file__).resolve().parent
AUDIO_DIR = HERE.parent / "audio"


def read_ints(path):
    return np.loadtxt(path, dtype=np.int64, ndmin=1)


def main():
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "sim" / "vectors"
    x = read_ints(folder / "audio_in.txt")
    print(f"Input: {len(x)} samples ({len(x) / FS:.2f} s)\n")

    all_pass = True
    hw, sw = {}, {}
    for mode in MODES:
        sw[mode] = read_ints(folder / f"audio_expected_{mode}.txt")
        out_file = folder / f"audio_out_{mode}.txt"
        if not out_file.exists():
            print(f"{mode:9s}: FAIL (missing {out_file} - run tb_fir_audio first)")
            all_pass = False
            continue
        hw[mode] = read_ints(out_file)
        n = min(len(sw[mode]), len(hw[mode]))
        diff = hw[mode][:n] - sw[mode][:n]
        mism = int(np.count_nonzero(diff)) + abs(len(sw[mode]) - len(hw[mode]))
        ok = mism == 0
        all_pass &= ok
        print(f"{mode:9s}: {'PASS' if ok else 'FAIL'}  hardware {len(hw[mode])} / "
              f"software {len(sw[mode])} samples, {mism} mismatches, "
              f"max |hw - sw| = {int(np.max(np.abs(diff))) if n else 0}")
        if not ok:
            for i in np.nonzero(diff)[0][:5]:
                print(f"    sample {i}: software {sw[mode][i]}, hardware {hw[mode][i]}")
        wavfile.write(AUDIO_DIR / f"hw_{mode}.wav", int(FS), hw[mode].astype(np.int16))

    # energy in the low (< 3 kHz) and high (> 3 kHz) bands, in dB vs the input
    def band_db(y):
        f, p = signal.welch(y.astype(float), FS, nperseg=2048)
        return (10 * np.log10(p[f < 3000].sum() + 1e-12),
                10 * np.log10(p[f > 3000].sum() + 1e-12))
    lo_in, hi_in = band_db(x)
    print("\nBand energy relative to the input   < 3 kHz   > 3 kHz")
    for mode in hw:
        lo, hi = band_db(hw[mode])
        print(f"  hardware {mode:9s}               {lo - lo_in:7.1f} dB {hi - hi_in:7.1f} dB")

    # ---- plots ----
    fig, axes = plt.subplots(2, 2, figsize=(11, 7.5))
    for ax, (name, y) in zip(axes.flat[:3], [("input", x),
                                              ("hardware low-pass", hw.get("lowpass", x)),
                                              ("hardware high-pass", hw.get("highpass", x))]):
        f, t, s = signal.spectrogram(y.astype(float), FS, nperseg=512, noverlap=384)
        ax.pcolormesh(t, f / 1000, 10 * np.log10(s + 1e-6), shading="auto",
                      vmin=-20, vmax=60, cmap="viridis")
        ax.axhline(3, color="white", ls="--", lw=0.8)
        ax.set_title(f"Spectrogram: {name}")
        ax.set_xlabel("Time (s)")
        ax.set_ylabel("Frequency (kHz)")

    ax = axes.flat[3]
    f, p = signal.welch(x.astype(float), FS, nperseg=2048)
    ax.plot(f / 1000, 10 * np.log10(p + 1e-6), color="black", lw=1, label="input")
    for mode, col in [("lowpass", "tab:blue"), ("highpass", "tab:orange")]:
        if mode in hw:
            f, p = signal.welch(sw[mode].astype(float), FS, nperseg=2048)
            ax.plot(f / 1000, 10 * np.log10(p + 1e-6), color=col, lw=3, alpha=0.4,
                    label=f"software {mode}")
            f, p = signal.welch(hw[mode].astype(float), FS, nperseg=2048)
            ax.plot(f / 1000, 10 * np.log10(p + 1e-6), color=col, lw=1, ls="--",
                    label=f"hardware {mode}")
    ax.axvline(3, color="gray", ls=":", lw=1)
    ax.set_title("Average spectrum: software (thick) vs hardware (dashed)")
    ax.set_xlabel("Frequency (kHz)")
    ax.set_ylabel("Power (dB)")
    ax.grid(True, alpha=0.3)
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(HERE / "audio_compare.png", dpi=110)

    print(f"\nWrote audio/hw_<mode>.wav and {HERE / 'audio_compare.png'}")
    print("\nOVERALL:", "PASS" if all_pass else "FAIL")
    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
