// =============================================================================
// tb_pdm_decimator.sv
// -----------------------------------------------------------------------------
// Self-checking testbench for pdm_decimator. The testbench plays the role of
// the microphone: after every falling edge of m_clk it puts the next PDM bit
// on m_data.
//
// Checks:
//   1. During reset: m_clk = 0, pcm_out = 0, no sample_valid.
//   2. m_clk period = 400 ns (2.5 MHz) with 200 ns high / 200 ns low.
//   3. sample_valid is one clock wide and comes every 2560 clocks
//      (39,062.5 Hz).
//   4. Exact PCM values for fixed bit patterns (the number of ones in every
//      64-bit window is known, whatever the window alignment):
//        all 0      ->  0 ones -> -16384
//        1000 ...   -> 16 ones ->  -8192
//        1010 ...   -> 32 ones ->      0
//        1110 ...   -> 48 ones ->  +8192
//        all 1      -> 64 ones -> +16384
//   5. A sigma-delta coded 1 kHz sine from pdm_input.txt (made by
//      gen_vectors.py). The output is written to pdm_output.txt
//      (check_results.py plots it as pdm_plot.png) and its peak value is
//      checked to be close to 0.5 * 16384 = 8192.
// Prints "TEST PASSED" or "TEST FAILED" with the number of errors.
// See tb_fir_filter.sv for why VEC_DIR should be an absolute path.
// =============================================================================
`timescale 1ns / 1ps

module tb_pdm_decimator;

    parameter string VEC_DIR  = "/home/mutahir/Documents/SV/FIR-Filter/sim/vectors/";
    parameter int    MAX_BITS = 8192;

    logic               clk = 1'b0;
    logic               rst;
    logic               m_data;
    logic               m_clk;
    logic signed [15:0] pcm_out;
    logic               sample_valid;

    always #5 clk = ~clk;   // 100 MHz

    pdm_decimator #(.CLK_DIV(40), .DECIM(64)) dut (
        .clk         (clk),
        .rst         (rst),
        .m_data      (m_data),
        .m_clk       (m_clk),
        .pcm_out     (pcm_out),
        .sample_valid(sample_valid)
    );

    int errors = 0;

    // ---------------- microphone model ----------------
    // pattern: 4-bit pattern repeated forever, or the bits from the file
    logic [3:0] pattern;
    bit         use_file = 0;
    logic       file_bits [0:MAX_BITS-1];
    int         n_file_bits;
    int         bit_idx = 0;
    int         phase   = 0;

    always @(negedge m_clk) begin
        if (use_file) begin
            m_data  <= (bit_idx < n_file_bits) ? file_bits[bit_idx] : 1'b0;
            bit_idx <= bit_idx + 1;
        end else begin
            m_data  <= pattern[3 - phase];
            phase   <= (phase + 1) % 4;
        end
    end

    // ---------------- sample_valid monitor (check 3) ----------------
    int  last_valid_cycle = -1;
    int  cycle = 0;
    int  n_valid = 0;
    logic valid_d = 1'b0;

    always @(posedge clk) begin
        cycle++;
        valid_d <= sample_valid;
        if (sample_valid && valid_d) begin
            $display("ERROR at %0t: sample_valid longer than one clock", $time);
            errors++;
        end
        if (sample_valid) begin
            if (last_valid_cycle >= 0 && cycle - last_valid_cycle != 2560) begin
                $display("ERROR at %0t: sample_valid spacing %0d clocks, expected 2560",
                         $time, cycle - last_valid_cycle);
                errors++;
            end
            last_valid_cycle = cycle;
            n_valid++;
        end
    end

    // wait for the next PCM sample and return it
    task automatic next_sample(output logic signed [15:0] value);
        do @(posedge clk); while (!sample_valid);
        value = pcm_out;   // pcm_out is valid in the same cycle as sample_valid
    endtask

    // feed a repeating pattern and check the steady-state PCM value
    task automatic check_pattern(input logic [3:0] p, input int expected, input string name);
        logic signed [15:0] v;
        pattern = p;
        next_sample(v);                 // first windows may contain old bits
        next_sample(v);
        for (int i = 0; i < 4; i++) begin
            next_sample(v);
            if (v !== expected) begin
                $display("ERROR: pattern %s: pcm = %0d, expected %0d", name, v, expected);
                errors++;
            end
        end
        $display("Pattern %-10s -> pcm = %0d (expected %0d)", name, v, expected);
    endtask

    initial begin
        int fd, value, fd_out, peak_pos, peak_neg;
        time t_rise1, t_rise2, t_fall;
        logic signed [15:0] v;

        // ---- check 1: reset ----
        pattern = 4'b0000;
        m_data  = 1'b0;
        rst     = 1'b1;
        repeat (2) @(posedge clk);     // synchronous reset needs a clock edge
        repeat (100) begin
            @(posedge clk);
            #1;
            if (m_clk !== 1'b0 || pcm_out !== 16'sd0 || sample_valid !== 1'b0) begin
                $display("ERROR: outputs not idle during reset");
                errors++;
            end
        end
        @(negedge clk);
        rst = 1'b0;

        // ---- check 2: mic clock timing ----
        @(posedge m_clk); t_rise1 = $time;
        @(negedge m_clk); t_fall  = $time;
        @(posedge m_clk); t_rise2 = $time;
        $display("m_clk: period %0d ns, high %0d ns", t_rise2 - t_rise1, t_fall - t_rise1);
        if (t_rise2 - t_rise1 != 400 || t_fall - t_rise1 != 200) begin
            $display("ERROR: m_clk is not 2.5 MHz with 50%% duty cycle");
            errors++;
        end

        // ---- check 4: fixed patterns ----
        check_pattern(4'b0000, -16384, "all 0");
        check_pattern(4'b1000,  -8192, "1000");
        check_pattern(4'b1010,      0, "1010");
        check_pattern(4'b1110,   8192, "1110");
        check_pattern(4'b1111,  16384, "all 1");
        check_pattern(4'b0000, -16384, "all 0");

        // ---- check 5: 1 kHz sine from file ----
        fd = $fopen({VEC_DIR, "pdm_input.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open %spdm_input.txt - check VEC_DIR", VEC_DIR);
            $finish;
        end
        n_file_bits = 0;
        while (n_file_bits < MAX_BITS && $fscanf(fd, "%d", value) == 1) begin
            file_bits[n_file_bits] = value[0];
            n_file_bits++;
        end
        $fclose(fd);
        $display("Read %0d PDM bits", n_file_bits);

        fd_out = $fopen({VEC_DIR, "pdm_output.txt"}, "w");
        @(posedge clk);
        while (!sample_valid) @(posedge clk);   // start at a window boundary
        @(negedge m_clk);
        use_file = 1;
        bit_idx  = 0;

        peak_pos = 0;
        peak_neg = 0;
        for (int i = 0; i < n_file_bits / 64; i++) begin
            next_sample(v);
            $fwrite(fd_out, "%0d\n", v);
            if (i >= 2) begin   // skip the first windows (mix of old and new bits)
                if (v > peak_pos) peak_pos = v;
                if (v < peak_neg) peak_neg = v;
            end
        end
        $fclose(fd_out);
        $display("Sine: peak +%0d / %0d (expected about +/-8192), written to %spdm_output.txt",
                 peak_pos, peak_neg, VEC_DIR);
        if (peak_pos < 7000 || peak_pos > 9500 || peak_neg > -7000 || peak_neg < -9500) begin
            $display("ERROR: sine amplitude is wrong");
            errors++;
        end

        $display("Checked %0d sample_valid pulses", n_valid);
        if (errors == 0) $display("TEST PASSED: tb_pdm_decimator");
        else             $display("TEST FAILED: tb_pdm_decimator, %0d errors", errors);
        $display("DONE");
        $finish;
    end

endmodule
