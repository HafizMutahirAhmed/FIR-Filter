# FIR Filtering of Audio on the Nexys 7 FPGA Using a DSP48 Slice

The on-board MEMS microphone of the **Nexys A7-100T (Nexys 7)** is the input. A
31-tap FIR filter, built around **one DSP48E1 multiply-accumulate slice**,
filters the audio. The result plays from the on-board mono audio jack. Switches
choose the filter: bypass, 3 kHz low-pass or 3 kHz high-pass.

Top-level module: **`audio_fir_system`** (`rtl/audio_fir_system.sv`).

---

## 1. What is an FIR filter?

A Finite Impulse Response (FIR) filter makes each output sample a weighted sum
of the last N input samples:

```
y[n] = sum_{k=0}^{N-1} h[k] * x[n-k]
     = h[0]*x[n] + h[1]*x[n-1] + ... + h[30]*x[n-30]      (N = 31)
```

The weights `h[k]` are the **coefficients**. Picking them sets which frequencies
pass and which are blocked. Here they are designed in Python with
`scipy.signal.firwin` (Hamming window, 31 taps, 3 kHz cutoff).

### System block diagram

```
             M_CLK 2.5 MHz
  +-----+   <-------------+
  | MEMS|                 |
  | mic | --M_DATA (PDM)-->  pdm_decimator  --16-bit PCM @ 39,062.5 Hz-->  fir_filter  ---> pwm_out ---> AUD_PWM ---> audio jack
  +-----+                 |  (count 1s over |      sample_valid           (31 taps,        (8-bit PWM,
                          |   64 bits)      |                              1 x DSP48E1)      ~390 kHz)
                                                                              ^
            SW[1:0] --> 2-FF sync --> mode ---------------------------------- +---> coeff_rom (3 sets from .mem files)
                                         \--> LED[1:0]
            fir output --> |abs| --> bar graph --> LED[15:8]
```

| SW[1:0] | Mode | What you hear |
|---|---|---|
| 00 | bypass | unfiltered mic audio |
| 01 | low-pass, 3 kHz | muffled, "bassy" sound |
| 10 | high-pass, 3 kHz | thin, "tinny" sound |
| 11 | bypass | (unused, same as 00) |

### Files

```
FIR-Filter/
  README.md
  rtl/        audio_fir_system.sv  pdm_decimator.sv  fir_filter.sv  coeff_rom.sv  pwm_out.sv
  coeffs/     lowpass.mem  highpass.mem  bypass.mem
  sim/        tb_fir_filter.sv  tb_pdm_decimator.sv  tb_coeff_rom.sv
              tb_pwm_out.sv  tb_audio_fir_system.sv  tb_fir_audio.sv  tb_chain_audio.sv
              vectors/
  python/     gen_coeffs.py  gen_vectors.py  check_results.py
              make_demo_audio.py  prepare_audio.py  compare_audio.py
              prepare_chain.py  compare_chain.py   (+ saved plots)
  audio/      input.wav (demo input) + sw_*.wav / hw_*.wav results (+ *_chain_*.wav)
  constraints/fir_audio_nexys7.xdc
```

---

## 2. Why one DSP48 is enough

A **DSP48E1** is a hard block inside the Artix-7 that contains a 25x18-bit
multiplier, a 48-bit adder/accumulator, and pipeline registers. One DSP48 can
do one multiply-accumulate (`acc = acc + a*b`) per clock cycle at well over
100 MHz.

**Cycles-per-sample budget:**

```
clock rate   = 100 MHz
sample rate  = 2.5 MHz / 64 = 39,062.5 Hz
cycles/sample = 100,000,000 / 39,062.5 = 2560 cycles
cycles needed = 31 taps + 3 (pipeline) = ~34 cycles
```

We need only 34 of the 2560 available cycles. So **one** multiplier, reused for
all 31 taps one after the other, is plenty. This is the simplest and smallest
possible FIR architecture.

### How `fir_filter.sv` works

1. When `sample_valid` arrives, the new sample is shifted into a 31-entry delay
   line (`delay[0]` = newest).
2. A small FSM goes `IDLE -> RUN -> FLUSH -> DONE`.
   In `RUN` the tap index `k` counts 0..30, feeding `delay[k]` and `h[k]` into
   the MAC, one tap per clock.
3. The MAC is written in the canonical DSP48 style. Vivado places all four
   registers inside one DSP48E1:
   ```systemverilog
   a_reg <= sample_tap;     b_reg <= coeff;           // stage 1 (A/B regs)
   m_reg <= a_reg * b_reg;                             // stage 2 (M reg)
   p_reg <= acc_clear ? m_reg : p_reg + m_reg;         // stage 3 (P reg)
   ```
4. Because of the 3-stage pipeline, the product of tap 0 reaches the
   accumulator 2 cycles after it is fed in. `acc_clear` is delayed by exactly
   2 cycles so the accumulator *starts* the new sum with tap 0. `FLUSH` waits
   2 cycles for the last product. A timeline is in the comment block at the
   top of `fir_filter.sv`.
5. In `DONE` the result is shifted back (`acc >>> 15`), saturated to 16 bits,
   and given out with a one-clock `out_valid` pulse.

Bypass mode uses the **same** datapath with a coefficient set that is a single
impulse (0x7FFF) at the centre tap, so there is no special-case logic.

---

## 3. Fixed-point format (Q1.15)

The FPGA uses integers only. A coefficient between -1 and +1 is stored as a
16-bit signed integer equal to `value * 32768` (Q1.15: 1 sign bit, 15
fraction bits).

Example: the centre coefficient of the low-pass is `0.1530`.

```
0.1530 * 32768 = 5014   -> stored as hex 0x1396
```

Multiplying a 16-bit sample by a Q1.15 coefficient gives a 32-bit product
that is 32768 times too big. Summing 31 products needs at most 36 bits, so the
**40-bit** accumulator cannot overflow. At the end we divide by 32768 with an
arithmetic right shift, `acc >>> 15`, and clip to -32768..32767.

Example: sample `x = 10000`, coefficient `5014`:

```
10000 * 5014 = 50,140,000      50,140,000 >>> 15 = 1530   (= 10000 * 0.1530)
```

Note: `+1.0` cannot be stored in Q1.15. The largest value is 32767/32768. So
bypass mode gives `floor(x * 32767 / 32768)`, which is the input (delayed by
15 samples) minus at most 1 LSB.

---

## 4. Vivado GUI guide (step by step)

Written for Vivado 2022.2. The RTL and testbenches were checked with Vivado 2022.2's command-line tools (xsim, synthesis, implementation). The GUI click paths below were not tried step by step, and menu names may differ slightly in other versions.

### Step 0 — Generate coefficients and test vectors (Python)

The repository already contains the generated `.mem` and vector files. Re-run
the scripts if you change a filter. Open a terminal:

```bash
pip install numpy scipy matplotlib          # once
cd python
python3 gen_coeffs.py      # writes coeffs/*.mem and python/freq_response.png
python3 gen_vectors.py     # writes sim/vectors/input.txt, expected_*.txt, pdm_input.txt
```

### Step 1 — Create the project

1. Start Vivado. Click **File > Project > New...** (or **Create Project** on the
   start page). Click **Next**.
2. **Project name:** `fir_audio_nexys7`. Choose a location (it can be a
   separate folder, e.g. `FIR-Filter/vivado`). Keep **Create project
   subdirectory** ticked. **Next**.
3. **Project type:** select **RTL Project**. Tick **Do not specify sources at this
   time**. **Next**.
4. **Default Part:** select the **Parts** tab, type `xc7a100tcsg324-1` in the
   search box, select **xc7a100tcsg324-1**. **Next > Finish**.

### Step 2 — Add design sources (RTL + .mem files)

1. In the **Flow Navigator** (left), under **PROJECT MANAGER**, click **Add Sources**.
2. Select **Add or create design sources > Next**.
3. Click **Add Files**. Select all five files in `rtl/` (`*.sv`).
4. Click **Add Files** again. Go to `coeffs/` and set the file filter to
   **All Files**. Select `lowpass.mem`, `highpass.mem`, `bypass.mem`.
5. **Untick** *Copy sources into project*, so that re-running the Python scripts
   updates the files Vivado uses. **Finish**.
6. In the **Sources** window the `.mem` files appear under
   **Design Sources > Memory File** (or *Memory Initialization Files*).
   They are used for both synthesis and simulation by default.

> If the `.mem` files are missing, synthesis still succeeds, but the ROM is all
> zeros and the board stays silent. Check the synthesis log for
> `$readmem data file 'lowpass.mem' is read successfully`.

### Step 3 — Add the constraints file

1. **Add Sources > Add or create constraints > Next**.
2. **Add Files** > `constraints/fir_audio_nexys7.xdc`. Untick copy. **Finish**.

### Step 4 — Set the top module

1. In **Sources > Design Sources**, right-click **audio_fir_system** >
   **Set as Top** (it is usually picked automatically and shown in bold).

### Step 5 — Add simulation sources and set the simulation top

1. **Add Sources > Add or create simulation sources > Next**.
2. **Add Files** > select all five testbenches in `sim/` (`tb_*.sv`).
   Untick copy. **Finish**.
3. In **Sources > Simulation Sources > sim_1**, right-click **tb_fir_filter** >
   **Set as Top**.
4. **Vector file path:** open `sim/tb_fir_filter.sv` and
   `sim/tb_pdm_decimator.sv` and set the `VEC_DIR` parameter to the **absolute**
   path of your `sim/vectors/` folder, with a trailing `/`, for example
   ```systemverilog
   parameter string VEC_DIR = "C:/projects/FIR-Filter/sim/vectors/";
   ```
   (Use forward slashes `/` on Windows too.) xsim runs inside
   `fir_audio_nexys7.sim/sim_1/behav/xsim/`, so relative paths would point
   there. The `.mem` files are found automatically because Vivado copies them
   into that folder. The other three testbenches need no files.
5. **Simulation run time:** every testbench ends itself with `$finish`. In the
   Flow Navigator, right-click **SIMULATION > Simulation Settings...**, open
   the **Simulation** tab, and set `xsim.simulate.runtime*` to **`all`**.
   Click **OK**.

### Step 6 — Run the testbenches

There is one self-checking testbench per module. Each one prints
**`TEST PASSED: <name>`** or **`TEST FAILED: <name>, N errors`** in the
**Tcl Console**. Run them one at a time: right-click the testbench under
**Simulation Sources > sim_1 > Set as Top**, then **Flow Navigator >
SIMULATION > Run Simulation > Run Behavioral Simulation**. Close the
simulation (**File > Close Simulation**) before running the next one.

| Testbench | Module under test | What it checks | Sim time |
|---|---|---|---|
| `tb_coeff_rom` | `coeff_rom` | every address of all 4 mode codes vs the `.mem` files, no X values, bypass = impulse, filters symmetric, low-pass DC gain ≈ 1, high-pass DC gain ≈ 0 | < 1 µs |
| `tb_pwm_out` | `pwm_out` | AUD_PWM = 0 in reset, AUD_SD = 1, 256-clock period, measured duty for 55 samples (incl. saturation) with gain shift 1 and 0, duty only changes at counter wrap | ~0.4 ms |
| `tb_pdm_decimator` | `pdm_decimator` | reset state, M_CLK = 2.5 MHz / 50 %, one-clock `sample_valid` every 2560 clocks, exact PCM for 5 bit patterns (−16384 … +16384), 1 kHz sine amplitude; writes `pdm_output.txt` | ~3 ms |
| `tb_fir_filter` | `fir_filter` (+ `coeff_rom`) | built-in reference model checks every output: 2000-sample vector test in 3 modes (writes `out_*.txt`), impulse response, saturation both ways, mode change during a computation, reset during a computation, 1200 random samples in all 4 mode codes, constant latency, one `out_valid` per sample | ~154 ms (20–60 s real time) |
| `tb_audio_fir_system` | whole design (top level) | reset, constant outputs (M_LRSEL, AUD_SD, LED[7:2]), switch → LED 2-clock sync, DC through mic → FIR → PWM pin + LED meter for all 4 switch settings, 1 kHz / 10 kHz tones through bypass / low-pass / high-pass, reset during operation | ~52 ms |

After `tb_fir_filter` (and optionally `tb_pdm_decimator`), compare with the
independent Python golden model in a terminal:

```bash
cd python
python3 check_results.py ../sim/vectors
```

Expected output:

```
bypass   : PASS  (2000 samples, 0 mismatches)
lowpass  : PASS  (2000 samples, 0 mismatches)
highpass : PASS  (2000 samples, 0 mismatches)
...
OVERALL: PASS
```

It saves `python/result_plot.png` (time signals and FFT) and, if
`pdm_output.txt` exists, `python/pdm_plot.png` (should show a coarse 1 kHz
sine of about ±8000). In the waveform window you can also right-click a
signal such as `pcm_out` > **Waveform Style > Analog** to see it as a wave.

### Step 6b — Verify with an audio file (software vs hardware)

This test uses a **recorded audio file** instead of the microphone. The same
samples are filtered twice: by the Python model (**software**) and by the
`fir_filter` RTL in the simulator (**hardware**). The two results must be
identical, sample for sample, and you can listen to both.

```
audio/input.wav --prepare_audio.py--> audio_in.txt (16-bit, 39,062.5 Hz)
                                          |                     |
                                  Python FIR model      tb_fir_audio (RTL, xsim)
                                          |                     |
                         audio_expected_<mode>.txt   audio_out_<mode>.txt
                                          \_____ compare_audio.py _____/
                                           PASS/FAIL + hw_*.wav + plot
```

1. **Pick the audio.** `audio/input.wav` is a 3 s demo (melody, hi-hat noise
   bursts and a 100 Hz → 15 kHz sweep), made by `python3 make_demo_audio.py`.
   You can use any WAV file instead (any sample rate, mono or stereo).
2. **Software:** in a terminal
   ```bash
   cd python
   python3 prepare_audio.py                       # uses ../audio/input.wav, first 3 s
   python3 prepare_audio.py my_song.wav 5         # or: your own file, first 5 s
   ```
   This writes `sim/vectors/audio_in.txt`, the software results
   `sim/vectors/audio_expected_<mode>.txt`, and `audio/sw_<mode>.wav`.
3. **Hardware:** in Vivado set **tb_fir_audio** as the simulation top (set its
   `VEC_DIR` as in Step 5) and run the behavioral simulation. The audio is not
   fed in real time. Each sample is sent as soon as the previous output is
   ready (~37 clocks instead of 2560), so 3 s of audio takes about 30 s of
   real time. The Tcl Console prints `Hardware <mode>: wrote ... samples` and
   `DONE`.
4. **Compare:**
   ```bash
   python3 compare_audio.py
   ```
   Expected:
   ```
   bypass   : PASS  hardware 117188 / software 117188 samples, 0 mismatches, max |hw - sw| = 0
   lowpass  : PASS  ...
   highpass : PASS  ...
   OVERALL: PASS
   ```
   It writes the hardware results as `audio/hw_<mode>.wav` (play them next to
   `audio/input_39k.wav`: low-pass sounds muffled, high-pass sounds thin) and
   `python/audio_compare.png` (spectrograms + software vs hardware spectrum).

### Step 6c — Audio file through the WHOLE chain (mic → filter → PWM pin)

Step 6b tests only the filter. This test sends the audio file through the
complete top level `audio_fir_system`, starting at the microphone pin:

```
audio file --prepare_chain.py--> PDM bits (2.5 MHz, like the mic) = chain_pdm.txt
   software: decimator model -> FIR model -> PWM model
   hardware: M_DATA pin -> pdm_decimator -> fir_filter -> pwm_out -> AUD_PWM pin   (tb_chain_audio)
compare_chain.py checks, for each mode:
   decimator output  : every PCM sample
   FIR output        : every sample
   AUD_PWM pin       : high time in every 256-clock PWM period = software duty
```

1. **Software:**
   ```bash
   cd python
   python3 prepare_chain.py                      # ../audio/input.wav, first 0.5 s
   python3 prepare_chain.py my_song.wav 1.0      # or: your own file, first 1 s
   ```
2. **Hardware:** set **tb_chain_audio** as the simulation top (set its
   `VEC_DIR`) and run the behavioral simulation. This one **must** run in real
   time, because the mic clock and decimator are part of the test (2560 clocks
   per sample). It simulates the clip 3 times, once per mode. Expect about
   **3 minutes for 0.5 s of audio** (about 6 minutes for 1 s). Wait for
   `DONE`.
3. **Compare:**
   ```bash
   python3 compare_chain.py
   ```
   Expected, for each mode:
   ```
   bypass:
       decimator : PASS  hardware 19532 / software 19532 values, 0 mismatches
       FIR       : PASS  hardware 19532 / software 19532 values, 0 mismatches
       PWM pin   : PASS  195322 PWM periods, 0 wrong duty, 0 out of order
   ...
   OVERALL: PASS
   ```
   It writes `audio/hw_chain_<mode>.wav`, which is audio rebuilt from the AUD_PWM
   pin, and `python/chain_compare.png`. The plot shows that the pin audio is
   8-bit: its noise floor is much higher than the 16-bit filter output (see
   *Limitations*).

### Step 7 — Synthesis, implementation, bitstream

1. **Flow Navigator > SYNTHESIS > Run Synthesis** > **OK**.
2. When it finishes, choose **Run Implementation** in the pop-up > **OK**.
3. When it finishes, choose **Generate Bitstream** > **OK**.
4. **Check the DSP count:** **Flow Navigator > IMPLEMENTATION > Open
   Implemented Design**, then **Reports > Report Utilization...** > **OK**.
   Under **DSP** you should see **DSP48E1 = 1**. You can also open the
   synthesis log (**Reports** tab at the bottom > *Synthesis > Vivado
   Synthesis Report*) and find the *DSP Final Report*, which shows the A/B, M
   and P registers inside the one DSP.
5. **Check timing:** in the implemented design, **Reports > Timing > Report
   Timing Summary** > **OK** (or look at the **Project Summary** tab).
   **WNS must be >= 0** (all timing met).

Expected warnings that are harmless: `port AUD_SD / M_LRSEL / LED[2..7] driven
by constant`, and `DRC CFGBVS-1 Missing CFGBVS and CONFIG_VOLTAGE`.

### Step 8 — Program the board

1. Connect the Nexys A7 with the USB cable (PROG/UART port) and switch it on.
2. **Flow Navigator > PROGRAM AND DEBUG > Open Hardware Manager**.
3. Click **Open target > Auto Connect** (green bar at the top).
4. Click **Program device** > **xc7a100t_0**. The bitstream file
   (`.../audio_fir_system.bit`) is filled in. Click **Program**.

---

## 5. Testing on the board

1. Plug headphones or powered speakers into the **mono audio jack**.
   Start with low volume.
2. Play a tone, music, or speak near the on-board microphone.
3. Change **SW[1:0]**:
   - `00` bypass: normal (but low-quality) mic sound.
   - `01` low-pass: high frequencies removed, so the sound is muffled.
   - `10` high-pass: low frequencies removed, so the sound is thin.
   A tone generator app on a phone makes this very clear: a 1 kHz tone passes
   low-pass and is cut by high-pass; a 10 kHz tone does the opposite.
4. **LED[1:0]** shows the mode. **LED[15:8]** is a level bar: more LEDs light up
   for louder output.
5. Press **CPU_RESET** (red button) to reset the design.
6. If the sound is too quiet or clips, change `OUT_GAIN_SHIFT` in
   `audio_fir_system.sv` (0 = quieter, 2 = louder) and rebuild.

---

## 6. Pin table

All pins are from Digilent's `Nexys-A7-100T-Master.xdc`. All use LVCMOS33.

| Port (`audio_fir_system`) | Pin | Board net |
|---|---|---|
| `clk` | E3 | 100 MHz oscillator (`create_clock -period 10.000`) |
| `CPU_RESETN` | C12 | red CPU_RESET button, active-low |
| `SW[0]` | J15 | switch 0 |
| `SW[1]` | L16 | switch 1 |
| `M_CLK` | J5 | microphone clock (output) |
| `M_DATA` | H5 | microphone PDM data (input) |
| `M_LRSEL` | F5 | microphone L/R select, driven 0 |
| `AUD_PWM` | A11 | audio PWM output |
| `AUD_SD` | D12 | audio amplifier enable, driven 1 |
| `LED[0]..LED[7]` | H17, K15, J13, N14, R18, V17, U17, U16 | LEDs 0–7 |
| `LED[8]..LED[15]` | V16, T15, U14, T16, V15, V14, V12, V11 | LEDs 8–15 |

---

## 7. Limitations

- **Crude decimator:** counting ones over 64 bits is a 1st-order (sinc¹)
  filter. It gives only 65 levels (about 6 bits) and lets some high-frequency
  noise alias into the audio band. A 3rd-order CIC decimator would be better
  (not implemented).
- **8-bit PWM output:** only 256 output levels, so you will hear some hiss.
- **Mono:** one microphone, one output channel.
- **Mic sampling edge:** with `M_LRSEL = 0`, data is sampled just before the
  rising edge of `M_CLK`. If the output is only noise on your board, check the
  microphone timing in the Digilent Nexys A7 reference manual.
- **Audio output drive:** `AUD_PWM` is driven push-pull (0/1). The Digilent
  reference manual describes the audio output in more detail; check it if the
  sound is distorted.
- **Bypass** is a 15-sample (≈0.38 ms) delayed copy of the input, scaled by
  32767/32768.
