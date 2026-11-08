"""
gen_coeffs.py
Designs the low-pass and high-pass FIR filters, quantizes them to Q1.15 and
writes coeffs/lowpass.mem, coeffs/highpass.mem and coeffs/bypass.mem
(one 4-digit hex word per line, two's complement). Also saves
python/freq_response.png (floating point vs quantized response).

Run:  python3 gen_coeffs.py
"""
from pathlib import Path

import numpy as np
from scipy import signal
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ---- system parameters (must match audio_fir_system.sv) ----
FS = 2.5e6 / 64          # 39,062.5 Hz sample rate
N_TAPS = 31
CUTOFF = 3000.0          # Hz, for both filters
Q = 15                   # Q1.15

ROOT = Path(__file__).resolve().parent.parent
COEFF_DIR = ROOT / "coeffs"


def quantize_q15(h):
    """Round to Q1.15 and clip to the 16-bit signed range."""
    return np.clip(np.round(h * (1 << Q)), -32768, 32767).astype(np.int64)


def write_mem(path, coeffs):
    with open(path, "w") as f:
        for c in coeffs:
            f.write(f"{int(c) & 0xFFFF:04x}\n")


def main():
    COEFF_DIR.mkdir(exist_ok=True)

    h_lp = signal.firwin(N_TAPS, CUTOFF, fs=FS, window="hamming")
    h_hp = signal.firwin(N_TAPS, CUTOFF, fs=FS, window="hamming", pass_zero=False)

    q_lp = quantize_q15(h_lp)
    q_hp = quantize_q15(h_hp)
    q_byp = np.zeros(N_TAPS, dtype=np.int64)
    q_byp[N_TAPS // 2] = 32767       # unit impulse (1.0 is 32767 in Q1.15)

    write_mem(COEFF_DIR / "lowpass.mem", q_lp)
    write_mem(COEFF_DIR / "highpass.mem", q_hp)
    write_mem(COEFF_DIR / "bypass.mem", q_byp)

    print(f"Sample rate      : {FS} Hz, taps = {N_TAPS}, cutoff = {CUTOFF} Hz")
    print(f"Low-pass  coeffs : {q_lp.tolist()}")
    print(f"High-pass coeffs : {q_hp.tolist()}")
    s = int(q_lp.sum())
    print(f"Sum of quantized low-pass coeffs = {s} (ideal 32768, error {s - 32768})")
    if abs(s - 32768) > 32:
        print("WARNING: low-pass DC gain is not close to 1.0")
    print(f"Wrote {COEFF_DIR}/lowpass.mem, highpass.mem, bypass.mem")

    # ---- frequency response plot ----
    fig, ax = plt.subplots(figsize=(8, 4.5))
    for h, q, name, col in [(h_lp, q_lp, "low-pass", "tab:blue"),
                            (h_hp, q_hp, "high-pass", "tab:orange")]:
        w, H = signal.freqz(h, worN=2048, fs=FS)
        _, Hq = signal.freqz(q / (1 << Q), worN=2048, fs=FS)
        ax.plot(w, 20 * np.log10(np.abs(H) + 1e-12), color=col, label=f"{name} (float)")
        ax.plot(w, 20 * np.log10(np.abs(Hq) + 1e-12), color=col, ls="--",
                label=f"{name} (Q1.15)")
    for f0 in (1000, 10000):
        ax.axvline(f0, color="gray", ls=":", lw=1)
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("Magnitude (dB)")
    ax.set_title(f"{N_TAPS}-tap Hamming FIR, cutoff {CUTOFF:.0f} Hz, fs = {FS} Hz")
    ax.set_ylim(-90, 5)
    ax.grid(True, alpha=0.3)
    ax.legend()
    fig.tight_layout()
    out = Path(__file__).resolve().parent / "freq_response.png"
    fig.savefig(out, dpi=120)
    print(f"Saved {out}")


if __name__ == "__main__":
    main()
