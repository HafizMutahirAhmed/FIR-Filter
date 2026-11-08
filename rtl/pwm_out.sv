// =============================================================================
// pwm_out.sv
// -----------------------------------------------------------------------------
// Drives the board's mono audio jack with an 8-bit PWM signal.
//
// 1. Convert the signed 16-bit sample to an unsigned 8-bit duty cycle:
//        level = (sample >>> 8) <<< OUT_GAIN_SHIFT   (signed, then saturated
//                                                     to -128..127)
//        duty  = level + 128                         (0..255, 128 = silence)
//    OUT_GAIN_SHIFT adds digital gain (each step = x2) because the mic signal
//    is fairly quiet.
// 2. An 8-bit counter running at 100 MHz wraps every 256 clocks, giving a
//    PWM carrier of 100 MHz / 256 = ~390 kHz. AUD_PWM = (counter < duty).
//    The on-board low-pass filter after the pin smooths this into audio.
// 3. The duty value is only updated when the counter wraps, so a PWM period
//    is never cut short.
// 4. AUD_SD = 1 keeps the audio amplifier enabled.
// =============================================================================
`timescale 1ns / 1ps

module pwm_out #(
    parameter int OUT_GAIN_SHIFT = 1
) (
    input  logic               clk,
    input  logic               rst,
    input  logic signed [15:0] sample,
    output logic               aud_pwm,
    output logic               aud_sd
);

    logic signed [15:0] level;     // sample >>> 8, then gain, then saturated
    logic signed [15:0] level_sat;
    logic        [7:0]  duty_next;
    logic        [7:0]  duty;
    logic        [7:0]  counter;

    always_comb begin
        level = (sample >>> 8) <<< OUT_GAIN_SHIFT;    // -128..127 times gain
        if (level > 16'sd127)       level_sat = 16'sd127;
        else if (level < -16'sd128) level_sat = -16'sd128;
        else                        level_sat = level;
        duty_next = level_sat[7:0] + 8'd128;          // offset to 0..255
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            counter <= '0;
            duty    <= 8'd128;
            aud_pwm <= 1'b0;
        end else begin
            counter <= counter + 1'b1;
            if (counter == 8'd255) duty <= duty_next;
            aud_pwm <= (counter < duty);
        end
    end

    assign aud_sd = 1'b1;

endmodule
