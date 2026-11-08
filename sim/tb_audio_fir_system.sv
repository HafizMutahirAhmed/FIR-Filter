// =============================================================================
// tb_audio_fir_system.sv
// -----------------------------------------------------------------------------
// Self-checking testbench for the TOP LEVEL (audio_fir_system). It tests the
// whole chain  mic (PDM) -> pdm_decimator -> fir_filter -> pwm_out  plus the
// reset, switch and LED logic, using only the board pins (plus a few internal
// signals for the tone measurements).
//
// The testbench acts as the microphone: after every falling edge of M_CLK it
// drives M_DATA with either a fixed bit pattern or a first-order sigma-delta
// coded sine wave (generated on the fly with real numbers).
//
// Checks:
//   1. Reset (CPU_RESETN low): AUD_PWM = 0, M_CLK = 0, level meter off.
//   2. Always: M_LRSEL = 0, AUD_SD = 1, LED[7:2] = 0.
//   3. Switches: LED[1:0] follows SW after exactly 2 clocks (2-FF sync).
//   4. DC end-to-end: for every SW setting (00, 01, 10, 11) and three mic
//      patterns (all 1, all 0, 1010) the FIR output, the PWM duty measured on
//      the AUD_PWM pin and the LED meter must match the expected values.
//   5. Tones end-to-end: 1 kHz and 10 kHz sines into the mic.
//        bypass   : both tones pass
//        low-pass : 1 kHz passes, 10 kHz is removed
//        high-pass: 10 kHz passes, 1 kHz is removed
//      measured as the RMS of the FIR output.
// Prints "TEST PASSED" or "TEST FAILED" with the number of errors.
// Needs the coefficient .mem files in the xsim folder (Vivado copies them).
// =============================================================================
`timescale 1ns / 1ps

module tb_audio_fir_system;

    localparam int N_TAPS = 31;

    logic        clk = 1'b0;
    logic        CPU_RESETN;
    logic [1:0]  SW;
    logic        M_DATA;
    logic        M_CLK;
    logic        M_LRSEL;
    logic        AUD_PWM;
    logic        AUD_SD;
    logic [15:0] LED;

    always #5 clk = ~clk;   // 100 MHz

    audio_fir_system dut (
        .clk       (clk),
        .CPU_RESETN(CPU_RESETN),
        .SW        (SW),
        .M_DATA    (M_DATA),
        .M_CLK     (M_CLK),
        .M_LRSEL   (M_LRSEL),
        .AUD_PWM   (AUD_PWM),
        .AUD_SD    (AUD_SD),
        .LED       (LED)
    );

    int errors = 0;

    // =========================================================================
    // Microphone model
    // =========================================================================
    bit         mic_sine = 0;      // 0 = fixed pattern, 1 = sine
    logic [3:0] pattern  = 4'b1010;
    int         phase    = 0;
    real        tone_freq = 1000.0;
    real        tone_amp  = 0.5;
    real        integ     = 0.0;

    always @(negedge M_CLK) begin
        real u;
        if (mic_sine) begin
            // first-order sigma-delta modulator
            u = tone_amp * $sin(2.0 * 3.14159265358979 * tone_freq * $realtime * 1.0e-9);
            M_DATA <= (integ >= 0.0);
            integ = integ + u - ((integ >= 0.0) ? 1.0 : -1.0);
        end else begin
            M_DATA <= pattern[3 - phase];
            phase  = (phase + 1) % 4;
        end
    end

    // =========================================================================
    // Check 2: constant outputs
    // =========================================================================
    always @(posedge clk) begin
        if (M_LRSEL !== 1'b0 || AUD_SD !== 1'b1 || LED[7:2] !== 6'b0) begin
            $display("ERROR at %0t: M_LRSEL=%b AUD_SD=%b LED[7:2]=%b",
                     $time, M_LRSEL, AUD_SD, LED[7:2]);
            errors++;
        end
    end

    // =========================================================================
    // Helpers
    // =========================================================================
    logic [15:0] ref_lp  [0:N_TAPS-1];
    logic [15:0] ref_hp  [0:N_TAPS-1];
    logic [15:0] ref_byp [0:N_TAPS-1];

    // sum of the coefficients of one mode = DC gain * 32768
    function automatic int coeff_sum(input logic [1:0] m);
        int s = 0;
        for (int k = 0; k < N_TAPS; k++) begin
            case (m)
                2'b01:   s += $signed(ref_lp[k]);
                2'b10:   s += $signed(ref_hp[k]);
                default: s += $signed(ref_byp[k]);
            endcase
        end
        return s;
    endfunction

    function automatic int sat16(input longint v);
        if (v > 32767)  return 32767;
        if (v < -32768) return -32768;
        return int'(v);
    endfunction

    function automatic int expected_duty(input int s);   // OUT_GAIN_SHIFT = 1
        int level;
        level = (s >>> 8) <<< 1;
        if (level > 127)  level = 127;
        if (level < -128) level = -128;
        return level + 128;
    endfunction

    function automatic logic [7:0] expected_meter(input int s);
        int a;
        logic [7:0] bar;
        a = (s < 0) ? -s : s;
        for (int i = 0; i < 8; i++) bar[i] = (a >= (i + 1) * 2048);
        return bar;
    endfunction

    // wait for n FIR output samples
    task automatic wait_samples(input int n);
        repeat (n) begin
            do @(posedge clk); while (!dut.fir_valid);
        end
    endtask

    // change SW and check that LED[1:0] follows after exactly 2 clocks
    task automatic set_switches(input logic [1:0] s);
        logic [1:0] old;
        @(negedge clk);
        old = LED[1:0];
        SW  = s;
        @(posedge clk);
        #1;
        if (LED[1:0] !== old) begin
            $display("ERROR at %0t: LED[1:0] changed after only 1 clock", $time);
            errors++;
        end
        @(posedge clk);
        #1;
        if (LED[1:0] !== s) begin
            $display("ERROR at %0t: LED[1:0] = %b two clocks after SW = %b", $time, LED[1:0], s);
            errors++;
        end
    endtask

    // =========================================================================
    // Check 4: DC through the whole chain
    // =========================================================================
    task automatic dc_test(input logic [1:0] m, input logic [3:0] p, input int pcm);
        int fir_exp, duty_exp, high;
        logic [7:0] meter_exp;

        pattern = p;
        set_switches(m);
        wait_samples(N_TAPS + 10);    // delay line full of the new value

        fir_exp   = sat16((longint'(pcm) * coeff_sum(m)) >>> 15);
        duty_exp  = expected_duty(fir_exp);
        meter_exp = expected_meter(fir_exp);

        // count the high clocks of AUD_PWM over one 256-clock period
        high = 0;
        repeat (256) begin
            @(posedge clk);
            if (AUD_PWM) high++;
        end

        $display("SW=%b mic=%b: fir_out=%6d (exp %6d)  PWM high=%3d/256 (exp %3d)  LED[15:8]=%b (exp %b)",
                 m, p, dut.fir_out, fir_exp, high, duty_exp, LED[15:8], meter_exp);
        if (dut.fir_out != fir_exp || high != duty_exp || LED[15:8] !== meter_exp) begin
            $display("ERROR: DC test SW=%b pattern=%b failed", m, p);
            errors++;
        end
    endtask

    // =========================================================================
    // Check 5: tones through the whole chain
    // =========================================================================
    task automatic tone_test(input logic [1:0] m, input real f, input bit should_pass);
        real sum_sq, rms;
        string name;

        tone_freq = f;
        mic_sine  = 1;
        set_switches(m);
        wait_samples(N_TAPS + 20);    // let decimator and filter settle

        sum_sq = 0.0;
        for (int i = 0; i < 200; i++) begin
            wait_samples(1);
            sum_sq += real'(dut.fir_out) * real'(dut.fir_out);
        end
        rms = $sqrt(sum_sq / 200.0);

        name = (m == 2'b01) ? "low-pass " : (m == 2'b10) ? "high-pass" : "bypass   ";
        $display("%s  %5.0f Hz tone: output RMS = %7.1f  (%s)",
                 name, f, rms, should_pass ? "should pass, > 4000" : "should be removed, < 1500");
        if ( should_pass && rms < 4000.0) begin
            $display("ERROR: tone should pass but is too small");
            errors++;
        end
        if (!should_pass && rms > 1500.0) begin
            $display("ERROR: tone should be removed but is too large");
            errors++;
        end
    endtask

    // =========================================================================
    // Main sequence
    // =========================================================================
    initial begin
        $readmemh("lowpass.mem",  ref_lp);
        $readmemh("highpass.mem", ref_hp);
        $readmemh("bypass.mem",   ref_byp);

        // ---- Check 1: reset ----
        CPU_RESETN = 1'b0;
        SW         = 2'b00;
        M_DATA     = 1'b0;
        repeat (5) @(posedge clk);
        repeat (100) begin
            @(posedge clk);
            #1;
            if (AUD_PWM !== 1'b0 || M_CLK !== 1'b0 || LED[15:8] !== 8'b0) begin
                $display("ERROR at %0t: outputs not idle during reset", $time);
                errors++;
            end
        end
        CPU_RESETN = 1'b1;
        $display("Check 1 (reset) done, errors so far: %0d", errors);

        // ---- Check 3: switch synchronizer ----
        for (int s = 0; s < 4; s++) set_switches(s[1:0]);
        $display("Check 3 (switches -> LED[1:0]) done, errors so far: %0d", errors);

        // ---- Check 4: DC end-to-end for every switch setting ----
        for (int s = 0; s < 4; s++) begin
            dc_test(s[1:0], 4'b1111,  16384);
            dc_test(s[1:0], 4'b0000, -16384);
            dc_test(s[1:0], 4'b1010,      0);
        end
        $display("Check 4 (DC end-to-end) done, errors so far: %0d", errors);

        // ---- Check 5: tones end-to-end ----
        tone_test(2'b00,  1000.0, 1);
        tone_test(2'b00, 10000.0, 1);
        tone_test(2'b01,  1000.0, 1);
        tone_test(2'b01, 10000.0, 0);
        tone_test(2'b10,  1000.0, 0);
        tone_test(2'b10, 10000.0, 1);
        $display("Check 5 (tones end-to-end) done, errors so far: %0d", errors);

        // ---- reset again in the middle of operation ----
        @(negedge clk);
        CPU_RESETN = 1'b0;
        repeat (5) @(posedge clk);
        #1;
        if (AUD_PWM !== 1'b0 || LED[15:8] !== 8'b0 || dut.fir_out !== 16'sd0) begin
            $display("ERROR: reset during operation did not clear the outputs");
            errors++;
        end
        CPU_RESETN = 1'b1;
        mic_sine = 0;
        dc_test(2'b01, 4'b1111, 16384);   // works again after the reset

        if (errors == 0) $display("TEST PASSED: tb_audio_fir_system");
        else             $display("TEST FAILED: tb_audio_fir_system, %0d errors", errors);
        $display("DONE");
        $finish;
    end

endmodule
