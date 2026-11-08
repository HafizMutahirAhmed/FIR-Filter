// =============================================================================
// tb_fir_filter.sv
// -----------------------------------------------------------------------------
// Main testbench for fir_filter. It is self-checking: it contains its own
// simple reference model of the FIR (same integer maths as the RTL) and
// compares EVERY output sample with it. It also writes the outputs of the
// vector test to text files so python/check_results.py can compare them with
// the independent Python golden model.
//
// Tests (all in one simulation run):
//   1. Vector test: input.txt through bypass, low-pass and high-pass, one
//      after the other, one sample every SAMPLE_PERIOD (2560) clocks = the
//      real 39.0625 kHz rate. Outputs go to out_<mode>.txt.
//   2. Impulse response: a single 32767 sample followed by zeros must give
//      back the coefficients (scaled) for every mode.
//   3. Saturation: worst-case input patterns that drive the accumulator past
//      the 16-bit range, in both directions -> output must clip to
//      +32767 / -32768.
//   4. Mode latching: changing 'mode' while a sample is being computed must
//      not change that output (the mode is latched when sample_valid comes).
//   5. Reset during a computation: no output for the aborted sample, and the
//      filter restarts from an empty delay line.
//   6. Random full-scale samples in all four mode codes (11 = bypass).
// Always checked: exactly one out_valid per accepted sample, one clock wide,
// with the same latency every time.
//
// FILE PATHS: xsim runs inside
//     <project>/fir_audio_nexys7.sim/sim_1/behav/xsim/
// so a relative path like "input.txt" is looked up THERE, not in sim/vectors.
// An absolute path is the safest choice: set VEC_DIR below to the absolute
// path of your sim/vectors folder (keep the trailing '/'). The output files
// are written to the same folder.
// (The coefficient .mem files are found because Vivado copies them into the
// xsim folder when they are added to the project.)
// =============================================================================
`timescale 1ns / 1ps

module tb_fir_filter;

    parameter string VEC_DIR       = "/home/mutahir/Documents/SV/FIR-Filter/sim/vectors/";
    parameter int    SAMPLE_PERIOD = 2560;   // clocks between input samples (vector test)
    parameter int    FAST_PERIOD   = 50;     // clocks between samples (directed tests)
    parameter int    MAX_SAMPLES   = 4096;
    localparam int   N_TAPS        = 31;

    logic               clk = 1'b0;
    logic               rst;
    logic signed [15:0] sample_in;
    logic               sample_valid;
    logic        [1:0]  mode;
    logic signed [15:0] sample_out;
    logic               out_valid;

    always #5 clk = ~clk;   // 100 MHz

    fir_filter #(.N_TAPS(N_TAPS)) dut (
        .clk         (clk),
        .rst         (rst),
        .sample_in   (sample_in),
        .sample_valid(sample_valid),
        .mode        (mode),
        .sample_out  (sample_out),
        .out_valid   (out_valid)
    );

    int errors    = 0;
    int n_checked = 0;
    int n_sat     = 0;     // outputs where the model saturated
    int latency   = -1;    // clocks from sample_valid to out_valid

    // =========================================================================
    // Reference model (plain integer maths, like the Python golden model)
    // =========================================================================
    logic [15:0] ref_lp  [0:N_TAPS-1];
    logic [15:0] ref_hp  [0:N_TAPS-1];
    logic [15:0] ref_byp [0:N_TAPS-1];
    int          ref_delay [0:N_TAPS-1];

    function automatic int ref_coeff(input logic [1:0] m, input int k);
        case (m)
            2'b01:   return $signed(ref_lp[k]);
            2'b10:   return $signed(ref_hp[k]);
            default: return $signed(ref_byp[k]);
        endcase
    endfunction

    function automatic void ref_reset();
        for (int k = 0; k < N_TAPS; k++) ref_delay[k] = 0;
    endfunction

    // push one sample into the model and return the expected output
    function automatic int ref_step(input int x, input logic [1:0] m);
        longint acc;
        longint y;
        for (int k = N_TAPS - 1; k > 0; k--) ref_delay[k] = ref_delay[k-1];
        ref_delay[0] = x;
        acc = 0;
        for (int k = 0; k < N_TAPS; k++) acc += longint'(ref_coeff(m, k)) * ref_delay[k];
        y = acc >>> 15;
        if (y > 32767)  begin y = 32767;  n_sat++; end
        if (y < -32768) begin y = -32768; n_sat++; end
        return int'(y);
    endfunction

    // =========================================================================
    // out_valid monitor: count pulses and check they are one clock wide
    // =========================================================================
    int   n_out_valid = 0;
    logic out_valid_d = 1'b0;

    always @(posedge clk) begin
        out_valid_d <= out_valid;
        if (out_valid) n_out_valid++;
        if (out_valid && out_valid_d) begin
            $display("ERROR at %0t: out_valid longer than one clock", $time);
            errors++;
        end
    end

    // =========================================================================
    // Send one sample, wait for its output, check it against the model
    // =========================================================================
    task automatic send_sample(input int x, input int gap, output int y);
        int expected, cycles;

        expected = ref_step(x, mode);

        sample_in    <= x[15:0];
        sample_valid <= 1'b1;
        @(posedge clk);
        sample_valid <= 1'b0;

        cycles = 0;
        do begin
            @(posedge clk);
            cycles++;
        end while (!out_valid && cycles < 200);

        if (!out_valid) begin
            $display("ERROR at %0t: no out_valid within 200 clocks", $time);
            errors++;
            y = 0;
        end else begin
            y = sample_out;
            if (latency < 0) latency = cycles;
            if (cycles != latency) begin
                $display("ERROR at %0t: latency %0d, expected %0d", $time, cycles, latency);
                errors++;
            end
            if (y != expected) begin
                $display("ERROR at %0t: mode %b input %0d: got %0d, expected %0d",
                         $time, mode, x, y, expected);
                errors++;
            end
        end
        n_checked++;
        repeat (gap - cycles - 1) @(posedge clk);
    endtask

    task automatic do_reset();
        rst <= 1'b1;
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        ref_reset();
    endtask

    // =========================================================================
    // Test 1: vector test with file output
    // =========================================================================
    int samples [0:MAX_SAMPLES-1];
    int n_samples;

    task automatic read_input();
        int fd, value;
        fd = $fopen({VEC_DIR, "input.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open %sinput.txt - check VEC_DIR", VEC_DIR);
            $finish;
        end
        n_samples = 0;
        while (n_samples < MAX_SAMPLES && $fscanf(fd, "%d", value) == 1) begin
            samples[n_samples] = value;
            n_samples++;
        end
        $fclose(fd);
        $display("Read %0d input samples", n_samples);
    endtask

    task automatic run_mode(input logic [1:0] m, input string name);
        int fd, y;
        fd = $fopen({VEC_DIR, "out_", name, ".txt"}, "w");
        if (fd == 0) begin
            $display("ERROR: cannot write %sout_%s.txt", VEC_DIR, name);
            $finish;
        end
        mode = m;
        do_reset();     // the delay line starts from zero, like the golden model
        for (int i = 0; i < n_samples; i++) begin
            send_sample(samples[i], SAMPLE_PERIOD, y);
            $fwrite(fd, "%0d\n", y);
        end
        $fclose(fd);
        $display("Test 1 (%s): wrote %0d samples to %sout_%s.txt", name, n_samples, VEC_DIR, name);
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        int y, y_expected, sent, outs_before;

        rst          = 1'b1;
        sample_in    = '0;
        sample_valid = 1'b0;
        mode         = 2'b00;

        $readmemh("lowpass.mem",  ref_lp);
        $readmemh("highpass.mem", ref_hp);
        $readmemh("bypass.mem",   ref_byp);

        // ---- Test 1 ----
        read_input();
        run_mode(2'b00, "bypass");
        run_mode(2'b01, "lowpass");
        run_mode(2'b10, "highpass");
        $display("Test 1 done, errors so far: %0d", errors);

        // ---- Test 2: impulse response ----
        for (int m = 0; m < 3; m++) begin
            mode = m[1:0];
            do_reset();
            send_sample(32767, FAST_PERIOD, y);
            for (int k = 1; k < N_TAPS + 5; k++) begin
                send_sample(0, FAST_PERIOD, y);
                // explicit check: output k is the k-th coefficient (scaled)
                if (k < N_TAPS) begin
                    y_expected = (32767 * ref_coeff(m[1:0], k)) >>> 15;
                    if (y != y_expected) begin
                        $display("ERROR: impulse mode %0d tap %0d: got %0d, expected %0d",
                                 m, k, y, y_expected);
                        errors++;
                    end
                end else if (y != 0) begin
                    $display("ERROR: impulse mode %0d: output %0d after the last tap is %0d",
                             m, k, y);
                    errors++;
                end
            end
        end
        $display("Test 2 (impulse response) done, errors so far: %0d", errors);

        // ---- Test 3: saturation ----
        // input x[n-k] = +/-full scale with the sign of h[k] -> |acc| is maximal
        for (int m = 1; m < 3; m++) begin
            mode = m[1:0];
            for (int pol = 0; pol < 2; pol++) begin
                do_reset();
                n_sat = 0;
                for (int j = 0; j < N_TAPS; j++) begin
                    // the sample sent at step j ends up at tap N_TAPS-1-j
                    int c;
                    c = ref_coeff(m[1:0], N_TAPS - 1 - j);
                    if (pol == 0) send_sample((c >= 0) ?  32767 : -32768, FAST_PERIOD, y);
                    else          send_sample((c >= 0) ? -32768 :  32767, FAST_PERIOD, y);
                end
                if (n_sat == 0) begin
                    $display("ERROR: saturation test did not reach saturation (mode %0d)", m);
                    errors++;
                end
                if (y != ((pol == 0) ? 32767 : -32768)) begin
                    $display("ERROR: saturation mode %0d: last output %0d", m, y);
                    errors++;
                end
            end
        end
        $display("Test 3 (saturation) done, errors so far: %0d", errors);

        // ---- Test 4: mode change during a computation ----
        mode = 2'b01;
        do_reset();
        for (int i = 0; i < 40; i++) begin
            int x, expected, cycles;
            x = $random % 20000;
            // model uses the mode at sample_valid time
            expected = ref_step(x, mode);
            sample_in    <= x[15:0];
            sample_valid <= 1'b1;
            @(posedge clk);
            sample_valid <= 1'b0;
            // change mode right after the sample (non-blocking, like a flip-flop
            // output, so there is no race with the DUT at this clock edge)
            mode <= (i % 2) ? 2'b01 : 2'b10;
            cycles = 0;
            do begin @(posedge clk); cycles++; end while (!out_valid && cycles < 200);
            if (sample_out != expected) begin
                $display("ERROR: mode latch test %0d: got %0d, expected %0d", i, sample_out, expected);
                errors++;
            end
            n_checked++;
            repeat (10) @(posedge clk);
        end
        $display("Test 4 (mode latching) done, errors so far: %0d", errors);

        // ---- Test 5: reset in the middle of a computation ----
        mode = 2'b01;
        do_reset();
        for (int i = 0; i < 10; i++) send_sample($random % 30000, FAST_PERIOD, y);
        outs_before = n_out_valid;
        sample_in    <= 16'sd12345;
        sample_valid <= 1'b1;
        @(posedge clk);
        sample_valid <= 1'b0;
        repeat (10) @(posedge clk);           // filter is now in RUN
        do_reset();                           // abort it (model is cleared too)
        repeat (100) @(posedge clk);
        if (n_out_valid != outs_before) begin
            $display("ERROR: out_valid came for a sample that was aborted by reset");
            errors++;
        end
        if (sample_out !== 16'sd0) begin
            $display("ERROR: sample_out not 0 after reset");
            errors++;
        end
        for (int i = 0; i < 50; i++) send_sample($random % 30000, FAST_PERIOD, y);
        $display("Test 5 (reset during computation) done, errors so far: %0d", errors);

        // ---- Test 6: random full-scale samples, all four mode codes ----
        for (int m = 0; m < 4; m++) begin
            mode = m[1:0];
            do_reset();
            for (int i = 0; i < 300; i++) send_sample($signed($random) >>> 16, FAST_PERIOD, y);
        end
        $display("Test 6 (random, modes 00/01/10/11) done, errors so far: %0d", errors);

        // ---- summary ----
        repeat (100) @(posedge clk);
        if (n_out_valid != n_checked) begin
            $display("ERROR: %0d out_valid pulses for %0d accepted samples", n_out_valid, n_checked);
            errors++;
        end
        $display("Checked %0d output samples, latency = %0d clocks after sample_valid",
                 n_checked, latency);
        if (errors == 0) $display("TEST PASSED: tb_fir_filter");
        else             $display("TEST FAILED: tb_fir_filter, %0d errors", errors);
        $display("DONE");
        $finish;
    end

endmodule
