"""
check_results.py
Compares the xsim output files (out_bypass.txt, out_lowpass.txt,
out_highpass.txt) with the golden model (expected_*.txt), sample by sample,
and prints PASS/FAIL per mode. Saves python/result_plot.png with the input vs
the filtered outputs and their FFT magnitudes.

If pdm_output.txt (from tb_pdm_decimator) is in the same folder, it is also
plotted to python/pdm_plot.png for a visual check.

Run:  python3 check_results.py <folder with the xsim output files>
      (default folder: ../sim/vectors)
"""
import sys
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

FS = 2.5e6 / 64
MODES = ["bypass", "lowpass", "highpass"]
HERE = Path(__file__).resolve().parent


def read_ints(path):
    return np.array([int(l) for l in open(path) if l.strip()], dtype=np.int64)


def tone_db(y, f0):
    """Level of the tone at f0 (dB relative to full scale) using a Hann window."""
    y = y.astype(float) / 32768.0
    w = np.hanning(len(y))
    spec = np.abs(np.fft.rfft(y * w)) / (w.sum() / 2)
    freqs = np.fft.rfftfreq(len(y), 1 / FS)
    i = np.argmin(np.abs(freqs - f0))
    return 20 * np.log10(spec[max(i - 2, 0):i + 3].max() + 1e-12)


def main():
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "sim" / "vectors"
    x = read_ints(folder / "input.txt")

    all_pass = True
    outputs = {}
    for mode in MODES:
        exp = read_ints(folder / f"expected_{mode}.txt")
        out_file = folder / f"out_{mode}.txt"
        if not out_file.exists():
            print(f"{mode:9s}: FAIL (missing {out_file})")
            all_pass = False
            continue
        got = read_ints(out_file)
        n = min(len(exp), len(got))
        mism = int(np.sum(exp[:n] != got[:n])) + abs(len(exp) - len(got))
        ok = mism == 0
        all_pass &= ok
        outputs[mode] = got
        print(f"{mode:9s}: {'PASS' if ok else 'FAIL'}  "
              f"({len(got)} samples, {mism} mismatches)")
        if not ok:
            idx = np.nonzero(exp[:n] != got[:n])[0][:5]
            for i in idx:
                print(f"    sample {i}: expected {exp[i]}, got {got[i]}")

    # tone levels: low-pass should keep 1 kHz and kill 10 kHz, high-pass the opposite
    print("\nTone levels (dBFS)      1 kHz    10 kHz")
    print(f"  input             {tone_db(x, 1000):8.1f}  {tone_db(x, 10000):8.1f}")
    for mode, y in outputs.items():
        print(f"  {mode:16s}  {tone_db(y, 1000):8.1f}  {tone_db(y, 10000):8.1f}")

    # ---- plots ----
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(9, 7))
    n_show = 200
    t_ms = np.arange(n_show) / FS * 1000
    ax1.plot(t_ms, x[:n_show], label="input", color="black", lw=1)
    for mode, col in [("lowpass", "tab:blue"), ("highpass", "tab:orange")]:
        if mode in outputs:
            ax1.plot(t_ms, outputs[mode][:n_show], label=mode, color=col)
    ax1.set_xlabel("Time (ms)")
    ax1.set_ylabel("Sample value")
    ax1.set_title("Input (1 kHz + 10 kHz) vs filtered output")
    ax1.grid(True, alpha=0.3)
    ax1.legend(loc="upper right")

    def spectrum(y):
        y = y.astype(float) / 32768.0
        w = np.hanning(len(y))
        s = np.abs(np.fft.rfft(y * w)) / (w.sum() / 2)
        return np.fft.rfftfreq(len(y), 1 / FS), 20 * np.log10(s + 1e-9)

    f, s = spectrum(x)
    ax2.plot(f, s, label="input", color="black", lw=1)
    for mode, col in [("lowpass", "tab:blue"), ("highpass", "tab:orange")]:
        if mode in outputs:
            f, s = spectrum(outputs[mode])
            ax2.plot(f, s, label=mode, color=col)
    for f0 in (1000, 10000):
        ax2.axvline(f0, color="gray", ls=":", lw=1)
    ax2.set_xlabel("Frequency (Hz)")
    ax2.set_ylabel("Magnitude (dBFS)")
    ax2.set_title("FFT magnitude")
    ax2.set_ylim(-110, 0)
    ax2.grid(True, alpha=0.3)
    ax2.legend(loc="upper right")
    fig.tight_layout()
    fig.savefig(HERE / "result_plot.png", dpi=120)
    print(f"\nSaved {HERE / 'result_plot.png'}")

    pdm_file = folder / "pdm_output.txt"
    if pdm_file.exists():
        p = read_ints(pdm_file)
        fig, ax = plt.subplots(figsize=(8, 3.5))
        ax.plot(np.arange(len(p)) / FS * 1000, p, marker=".")
        ax.set_xlabel("Time (ms)")
        ax.set_ylabel("PCM value")
        ax.set_title("pdm_decimator output for a 1 kHz PDM sine")
        ax.grid(True, alpha=0.3)
        fig.tight_layout()
        fig.savefig(HERE / "pdm_plot.png", dpi=120)
        print(f"Saved {HERE / 'pdm_plot.png'}")

    print("\nOVERALL:", "PASS" if all_pass else "FAIL")
    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
