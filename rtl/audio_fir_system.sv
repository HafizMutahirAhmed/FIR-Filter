// =============================================================================
// audio_fir_system.sv  (TOP LEVEL)
// -----------------------------------------------------------------------------
// Nexys A7-100T (Nexys 7) audio FIR filter demo:
//
//   MEMS mic --PDM--> pdm_decimator --PCM 39 kHz--> fir_filter --> pwm_out --> jack
//
//   SW[1:0] : 00 bypass, 01 low-pass (3 kHz), 10 high-pass (3 kHz), 11 bypass
//   LED[1:0]: shows the selected mode
//   LED[15:8]: level meter (bar graph) of the filtered output
//
// All system parameters live here and are passed down to the submodules.
// Port names match constraints/fir_audio_nexys7.xdc exactly.
// =============================================================================
`timescale 1ns / 1ps

module audio_fir_system #(
    parameter int    CLK_DIV        = 40,   // 100 MHz / 40 = 2.5 MHz mic clock
    parameter int    DECIM          = 64,   // 2.5 MHz / 64 = 39,062.5 Hz samples
    parameter int    N_TAPS         = 31,   // FIR length
    parameter int    OUT_GAIN_SHIFT = 1,    // PWM output gain = 2^OUT_GAIN_SHIFT
    parameter string LP_FILE        = "lowpass.mem",
    parameter string HP_FILE        = "highpass.mem",
    parameter string BYP_FILE       = "bypass.mem"
) (
    input  logic        clk,         // 100 MHz board clock
    input  logic        CPU_RESETN,  // red reset button, active-low
    input  logic [1:0]  SW,          // filter select
    input  logic        M_DATA,      // mic PDM data
    output logic        M_CLK,       // mic clock (2.5 MHz)
    output logic        M_LRSEL,     // mic channel select
    output logic        AUD_PWM,     // audio PWM output
    output logic        AUD_SD,      // audio amp enable
    output logic [15:0] LED
);

    // ---------------- reset: active-low button -> sync active-high ----------
    logic rst_ff1, rst;

    always_ff @(posedge clk) begin
        rst_ff1 <= ~CPU_RESETN;
        rst     <= rst_ff1;
    end

    // ---------------- switches: 2-FF synchronizer ---------------------------
    logic [1:0] sw_ff1, mode;

    always_ff @(posedge clk) begin
        sw_ff1 <= SW;
        mode   <= sw_ff1;
    end

    // ---------------- microphone -> PCM -------------------------------------
    logic signed [15:0] pcm;
    logic               pcm_valid;

    assign M_LRSEL = 1'b0;   // use the mic's left-channel timing

    pdm_decimator #(
        .CLK_DIV(CLK_DIV),
        .DECIM  (DECIM)
    ) u_pdm (
        .clk         (clk),
        .rst         (rst),
        .m_data      (M_DATA),
        .m_clk       (M_CLK),
        .pcm_out     (pcm),
        .sample_valid(pcm_valid)
    );

    // ---------------- FIR filter (one DSP48) --------------------------------
    logic signed [15:0] fir_out;
    logic               fir_valid;

    fir_filter #(
        .N_TAPS  (N_TAPS),
        .LP_FILE (LP_FILE),
        .HP_FILE (HP_FILE),
        .BYP_FILE(BYP_FILE)
    ) u_fir (
        .clk         (clk),
        .rst         (rst),
        .sample_in   (pcm),
        .sample_valid(pcm_valid),
        .mode        (mode),
        .sample_out  (fir_out),
        .out_valid   (fir_valid)
    );

    // ---------------- PWM audio out ------------------------------------------
    pwm_out #(
        .OUT_GAIN_SHIFT(OUT_GAIN_SHIFT)
    ) u_pwm (
        .clk    (clk),
        .rst    (rst),
        .sample (fir_out),
        .aud_pwm(AUD_PWM),
        .aud_sd (AUD_SD)
    );

    // ---------------- LEDs ----------------------------------------------------
    // Level meter: |fir_out| compared with 8 thresholds (2048, 4096, ... 16384).
    // The bar is updated once per output sample.
    logic [16:0] abs_out;      // 17 bits so that |-32768| fits
    logic [7:0]  meter;

    always_ff @(posedge clk) begin
        if (rst) begin
            abs_out <= '0;
        end else if (fir_valid) begin
            abs_out <= fir_out[15] ? 17'(-$signed({fir_out[15], fir_out}))
                                   : 17'({1'b0, fir_out});
        end
    end

    always_comb begin
        for (int i = 0; i < 8; i++)
            meter[i] = (abs_out >= 17'((i + 1) * 2048));
    end

    assign LED[1:0]  = mode;
    assign LED[7:2]  = 6'b0;
    assign LED[15:8] = meter;

endmodule
