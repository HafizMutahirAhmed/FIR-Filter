// =============================================================================
// tb_pwm_out.sv
// -----------------------------------------------------------------------------
// Self-checking testbench for pwm_out. Two copies of the DUT are tested at the
// same time: OUT_GAIN_SHIFT = 1 (the default) and OUT_GAIN_SHIFT = 0.
//
// Checks:
//   1. During reset: AUD_PWM = 0. AUD_SD is always 1.
//   2. For many input samples (zero, small, large, both extremes, values that
//      saturate, random values) the number of '1' cycles in one 256-clock PWM
//      period equals the expected duty:
//          duty = sat_8bit((sample >>> 8) <<< OUT_GAIN_SHIFT) + 128
//   3. The PWM period is exactly 256 clocks (counter wraps correctly).
//   4. The duty register only changes when the counter wraps (no glitches).
// Prints "TEST PASSED" or "TEST FAILED" with the number of errors.
// =============================================================================
`timescale 1ns / 1ps

module tb_pwm_out;

    logic               clk = 1'b0;
    logic               rst;
    logic signed [15:0] sample;
    logic               pwm_g1, sd_g1;    // OUT_GAIN_SHIFT = 1
    logic               pwm_g0, sd_g0;    // OUT_GAIN_SHIFT = 0

    always #5 clk = ~clk;   // 100 MHz

    pwm_out #(.OUT_GAIN_SHIFT(1)) dut_g1 (
        .clk(clk), .rst(rst), .sample(sample), .aud_pwm(pwm_g1), .aud_sd(sd_g1)
    );
    pwm_out #(.OUT_GAIN_SHIFT(0)) dut_g0 (
        .clk(clk), .rst(rst), .sample(sample), .aud_pwm(pwm_g0), .aud_sd(sd_g0)
    );

    int errors = 0;
    int n_tests = 0;

    // reference model of the sample -> duty conversion
    function automatic int expected_duty(input int s, input int gain_shift);
        int level;
        level = (s >>> 8) <<< gain_shift;
        if (level > 127)  level = 127;
        if (level < -128) level = -128;
        return level + 128;
    endfunction

    // ---- check 1: AUD_SD always 1 ----
    always @(posedge clk) begin
        if (sd_g1 !== 1'b1 || sd_g0 !== 1'b1) begin
            $display("ERROR at %0t: AUD_SD is not 1", $time);
            errors++;
        end
    end

    // ---- check 4: duty only changes right after the counter wraps ----
    logic [7:0] prev_duty, prev_cnt;
    always @(posedge clk) begin
        if (!rst && dut_g1.duty !== prev_duty && prev_cnt !== 8'd255) begin
            $display("ERROR at %0t: duty changed in the middle of a PWM period", $time);
            errors++;
        end
        prev_duty <= dut_g1.duty;
        prev_cnt  <= dut_g1.counter;
    end

    // count the high cycles of both outputs over one full 256-clock period
    task automatic measure(output int high_g1, output int high_g0);
        high_g1 = 0;
        high_g0 = 0;
        repeat (256) begin
            @(posedge clk);
            if (pwm_g1) high_g1++;
            if (pwm_g0) high_g0++;
        end
    endtask

    task automatic check_sample(input logic signed [15:0] s);
        int h1, h0, e1, e0;
        sample = s;
        repeat (2 * 256) @(posedge clk);   // let the new duty take effect
        measure(h1, h0);
        e1 = expected_duty(s, 1);
        e0 = expected_duty(s, 0);
        n_tests++;
        if (h1 != e1 || h0 != e0) begin
            $display("ERROR: sample %6d: gain1 high=%0d (exp %0d), gain0 high=%0d (exp %0d)",
                     s, h1, e1, h0, e0);
            errors++;
        end
    endtask

    initial begin
        int  period;
        time t_start;

        sample = '0;
        rst    = 1'b1;
        repeat (2) @(posedge clk);     // synchronous reset needs a clock edge
        repeat (10) begin
            @(posedge clk);
            #1;
            if (pwm_g1 !== 1'b0 || pwm_g0 !== 1'b0) begin
                $display("ERROR: AUD_PWM not 0 during reset");
                errors++;
            end
        end
        @(negedge clk);
        rst = 1'b0;

        // ---- check 3: PWM period = 256 clocks ----
        // time between two rising edges of AUD_PWM, in clock cycles (10 ns)
        sample = 16'sd0;                     // duty 128
        repeat (2 * 256) @(posedge clk);
        @(posedge pwm_g1);
        t_start = $time;
        @(posedge pwm_g1);
        period = int'(($time - t_start) / 10);
        if (period != 256) begin
            $display("ERROR: PWM period = %0d clocks, expected 256", period);
            errors++;
        end else begin
            $display("PWM period = 256 clocks (%.1f kHz)", 1e6 / (period * 10.0));
        end

        // ---- check 2: directed values ----
        check_sample(16'sd0);         // silence -> 128
        check_sample(16'sd255);       // still level 0
        check_sample(16'sd256);       // level +1
        check_sample(-16'sd1);        // level -1 (arithmetic shift)
        check_sample(-16'sd256);
        check_sample(-16'sd257);
        check_sample(16'sd8191);
        check_sample(16'sd16383);     // gain 1: 63*2 = 126 -> 254
        check_sample(16'sd16384);     // gain 1: 64*2 = 128 -> saturates to 255
        check_sample(-16'sd16384);    // gain 1: -128 -> 0
        check_sample(-16'sd16385);    // gain 1: saturates low -> 0
        check_sample(16'sd32767);     // full scale
        check_sample(-16'sd32768);    // full scale negative
        check_sample(16'sd12345);
        check_sample(-16'sd9876);

        // ---- random values ----
        repeat (40) check_sample($random);

        $display("Checked %0d samples", n_tests);
        if (errors == 0) $display("TEST PASSED: tb_pwm_out");
        else             $display("TEST FAILED: tb_pwm_out, %0d errors", errors);
        $finish;
    end

endmodule
