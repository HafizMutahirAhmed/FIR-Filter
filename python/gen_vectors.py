"""
gen_vectors.py
Creates the simulation test vectors in sim/vectors/:

  input.txt              2000 samples of 0.5*sin(1 kHz) + 0.25*sin(10 kHz), int16
  expected_bypass.txt    \
  expected_lowpass.txt    > bit-exact golden model of fir_filter.sv
  expected_highpass.txt  /
  pdm_input.txt          first-order sigma-delta PDM stream of a 1 kHz sine
                         (one bit per line, at the 2.5 MHz mic clock rate)

The golden model uses exactly the same integer arithmetic as the RTL:
    acc = sum(h[k] * x[n-k])        (exact integer, fits in 40 bits)
    y   = sat16(acc >> 15)          (arithmetic shift = floor, like >>>)

Run gen_coeffs.py first (this script reads coeffs/*.mem).
Run:  python3 gen_vectors.py
"""
from pathlib import Path

import numpy as np

FS = 2.5e6 / 64          # 39,062.5 Hz
PDM_FS = 2.5e6           # mic clock
N_SAMPLES = 2000
N_PDM_BITS = 5000        # two periods of 1 kHz -> 78 PCM samples

ROOT = Path(__file__).resolve().parent.parent
COEFF_DIR = ROOT / "coeffs"
VEC_DIR = ROOT / "sim" / "vectors"

MODES = ["bypass", "lowpass", "highpass"]


def read_mem(path):
    """Read a .mem file (4-digit hex, two's complement) into signed ints."""
    vals = []
    for line in open(path):
        line = line.strip()
        if line:
            v = int(line, 16)
            vals.append(v - 0x10000 if v & 0x8000 else v)
    return vals


def fir_golden(x, h):
    """Bit-exact integer model of fir_filter.sv."""
    n_taps = len(h)
    delay = [0] * n_taps                  # delay[0] = newest sample
    y = []
    for s in x:
        delay = [int(s)] + delay[:-1]
        acc = sum(hk * xk for hk, xk in zip(h, delay))
        assert -(1 << 39) <= acc < (1 << 39), "accumulator overflow"
        out = acc >> 15                   # Python >> on ints = arithmetic shift
        y.append(max(-32768, min(32767, out)))
    return y


def write_ints(path, vals):
    with open(path, "w") as f:
        for v in vals:
            f.write(f"{int(v)}\n")


def main():
    VEC_DIR.mkdir(parents=True, exist_ok=True)

    # ---- FIR test input ----
    t = np.arange(N_SAMPLES) / FS
    x_f = 0.5 * np.sin(2 * np.pi * 1000 * t) + 0.25 * np.sin(2 * np.pi * 10000 * t)
    x = np.clip(np.round(x_f * 32767), -32768, 32767).astype(int)
    write_ints(VEC_DIR / "input.txt", x)

    # ---- golden outputs ----
    for mode in MODES:
        h = read_mem(COEFF_DIR / f"{mode}.mem")
        y = fir_golden(x, h)
        write_ints(VEC_DIR / f"expected_{mode}.txt", y)
        print(f"expected_{mode}.txt : {len(y)} samples, "
              f"min {min(y)}, max {max(y)}")

    # ---- PDM stream for tb_pdm_decimator (first-order sigma-delta) ----
    tp = np.arange(N_PDM_BITS) / PDM_FS
    u = 0.5 * np.sin(2 * np.pi * 1000 * tp)      # amplitude 0.5 of full scale
    integ = 0.0
    bits = []
    for v in u:
        fb = 1.0 if integ >= 0 else -1.0
        bit = 1 if fb > 0 else 0
        bits.append(bit)
        integ += v - fb
    write_ints(VEC_DIR / "pdm_input.txt", bits)

    print(f"input.txt     : {len(x)} samples")
    print(f"pdm_input.txt : {len(bits)} bits")
    print(f"Wrote vectors to {VEC_DIR}")


if __name__ == "__main__":
    main()
