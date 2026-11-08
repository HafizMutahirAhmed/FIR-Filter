"""
compare_chain.py
Compares the HARDWARE results of the whole chain (tb_chain_audio.sv) with
the SOFTWARE models (prepare_chain.py) for the same PDM input, for bypass,
low-pass and high-pass:

  1. decimator : every PCM sample   (chain_out_pcm_<mode> vs chain_expected_pcm)
  2. FIR       : every output sample (chain_out_fir_<mode> vs chain_expected_fir_<mode>)
  3. PWM pin   : every 256-clock PWM period: the measured high time on AUD_PWM
                 must equal the software duty for the FIR value loaded, and the
                 loaded FIR values must follow the software FIR output in order.

Also writes audio/hw_chain_<mode>.wav, rebuilt from the AUD_PWM pin (duty of
each PWM period, 390,625 Hz, averaged down by 10 to 39,062.5 Hz: roughly
what the board's audio low-pass filter makes of the PWM signal), and
python/chain_compare.png.

Run:  python3 compare_chain.py [folder]     (default: ../sim/vectors)
"""
import sys
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from prepare_chain import pwm_duty_model

FS = 2.5e6 / 64
MODES = ["bypass", "lowpass", "highpass"]
HERE = Path(__file__).resolve().parent
AUDIO_DIR = HERE.parent / "audio"


def read_ints(path):
    return np.loadtxt(path, dtype=np.int64, ndmin=1)


def compare(name, hw, sw):
    """Sample-by-sample compare. Returns the number of mismatches."""
    n = min(len(hw), len(sw))
    diff = hw[:n] - sw[:n]
    mism = int(np.count_nonzero(diff)) + abs(len(hw) - len(sw))
    print(f"    {name:10s}: {'PASS' if mism == 0 else 'FAIL'}  hardware {len(hw)} / software "
          f"{len(sw)} values, {mism} mismatches")
    for i in np.nonzero(diff)[0][:3]:
        print(f"        index {i}: software {sw[i]}, hardware {hw[i]}")
    return mism


def check_pwm(pwm, fir_sw):
    """pwm: rows of (fir value loaded, measured high clocks)."""
    loaded, high = pwm[:, 0], pwm[:, 1]
    bad_duty = int(np.count_nonzero(high != pwm_duty_model(loaded)))

    # the loaded values must walk through the software FIR output in order
    j, bad_order = 0, 0
    for v in loaded:
        while j < len(fir_sw) and fir_sw[j] != v:
            j += 1
        if j == len(fir_sw):
            bad_order += 1
            j = 0
    mism = bad_duty + bad_order
    print(f"    {'PWM pin':10s}: {'PASS' if mism == 0 else 'FAIL'}  {len(pwm)} PWM periods, "
          f"{bad_duty} wrong duty, {bad_order} out of order")
    return mism


def main():
    folder = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "sim" / "vectors"
    pcm_sw = read_ints(folder / "chain_expected_pcm.txt")

    all_pass = True
    pin_audio = {}
    for mode in MODES:
        print(f"{mode}:")
        try:
            pcm_hw = read_ints(folder / f"chain_out_pcm_{mode}.txt")
            fir_hw = read_ints(folder / f"chain_out_fir_{mode}.txt")
            pwm_hw = np.loadtxt(folder / f"chain_out_pwm_{mode}.txt", dtype=np.int64, ndmin=2)
        except (OSError, ValueError) as e:
            print(f"    FAIL: missing hardware output ({e}) - run tb_chain_audio first")
            all_pass = False
            continue
        fir_sw = read_ints(folder / f"chain_expected_fir_{mode}.txt")

        mism = compare("decimator", pcm_hw, pcm_sw)
        mism += compare("FIR", fir_hw, fir_sw)
        mism += check_pwm(pwm_hw, fir_sw)
        all_pass &= (mism == 0)

        # rebuild audio from the PWM pin: duty 0..255 -> -32768..32512, 390,625 Hz -> /10
        analog = (pwm_hw[:, 1] - 128) * 256.0
        pin_audio[mode] = signal.resample_poly(analog, 1, 10)
        wavfile.write(AUDIO_DIR / f"hw_chain_{mode}.wav", int(FS),
                      np.clip(pin_audio[mode], -32768, 32767).astype(np.int16))

    # ---- plot: software vs hardware, per mode ----
    # thick  : software PWM model (8-bit duty from the software FIR output)
    # dashed : audio rebuilt from the AUD_PWM pin (hardware)
    # thin   : software 16-bit FIR output, for reference. The gap between it
    #          and the 8-bit curves is the 8-bit PWM quantization noise.
    fig, axes = plt.subplots(1, 3, figsize=(14, 4.2), sharey=True)
    for ax, mode in zip(axes, MODES):
        if mode not in pin_audio:
            continue
        fir_sw = read_ints(folder / f"chain_expected_fir_{mode}.txt")
        sw_pwm = (pwm_duty_model(fir_sw) - 128) * 256.0
        for y, style, label in [(fir_sw.astype(float), dict(color="gray", lw=1), "software FIR (16-bit)"),
                                (sw_pwm, dict(color="tab:blue", lw=3, alpha=0.4), "software PWM model (8-bit)"),
                                (pin_audio[mode], dict(color="tab:red", lw=1, ls="--"), "hardware AUD_PWM pin")]:
            f, p = signal.welch(y, FS, nperseg=min(2048, len(y)))
            ax.plot(f / 1000, 10 * np.log10(p + 1e-6), label=label, **style)
        ax.axvline(3, color="gray", ls=":", lw=1)
        ax.set_title(mode)
        ax.set_xlabel("Frequency (kHz)")
        ax.grid(True, alpha=0.3)
    axes[0].set_ylabel("Power (dB)")
    axes[0].legend(fontsize=8)
    fig.suptitle("Whole chain (mic PDM -> decimator -> FIR -> PWM): software vs hardware")
    fig.tight_layout()
    fig.savefig(HERE / "chain_compare.png", dpi=110)

    print(f"\nWrote audio/hw_chain_<mode>.wav and {HERE / 'chain_compare.png'}")
    print("\nOVERALL:", "PASS" if all_pass else "FAIL")
    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
