// =============================================================================
// fir_filter.sv
// -----------------------------------------------------------------------------
// A 31-tap FIR filter built around ONE multiply-accumulate (MAC) unit:
//
//     y[n] = sum_{k=0}^{N-1} h[k] * x[n-k]
//
// Why one MAC is enough:
//   The system clock is 100 MHz and a new audio sample arrives at 39.0625 kHz,
//   so there are 100e6 / 39062.5 = 2560 clock cycles between samples.
//   We only need N + 3 = 34 cycles to compute one output, so a single
//   multiplier that is reused for every tap is plenty.
//
// The MAC is written in the "canonical" DSP48E1 style (registered inputs,
// registered product, registered accumulator), so Vivado packs the whole MAC
// into exactly one DSP48E1 slice:
//
//     a_reg, b_reg  -> DSP48 A/B input registers   (stage 1)
//     m_reg         -> DSP48 M (multiplier) register (stage 2)
//     p_reg         -> DSP48 P (accumulator) register (stage 3)
//
// Fixed point:
//   samples      : 16-bit signed integers
//   coefficients : 16-bit signed Q1.15  (value = integer / 32768)
//   product      : 32-bit signed
//   accumulator  : 40-bit signed (31 taps * 2^30 max product < 2^35, so safe)
//   output       : acc >>> 15, saturated to 16-bit signed
//
// Pipeline timing (tap index k, cycle t = first cycle of RUN):
//
//   cycle      : t     t+1   t+2   ...  t+30  t+31   t+32   t+33
//   state      : RUN   RUN   RUN   ...  RUN   FLUSH  FLUSH  DONE
//   tap k      : 0     1     2     ...  30
//   a/b_reg    :       k=0   k=1   ...  k=29  k=30   (0)
//   m_reg      :             k=0   ...  k=28  k=29   k=30   (0)
//   p_reg      :                   ...  k=27  k=28   k=29   k=30 <- final sum
//   acc_clear  :             ^ high during t+2: p_reg loads m_reg (tap 0)
//                              instead of adding to the old sum
//
//   So RUN lasts N cycles, FLUSH lasts 2 cycles (the last product still in
//   flight), and in DONE p_reg holds the complete sum of all 31 taps.
//   Outside RUN the coefficient fed to the multiplier is forced to 0, so the
//   accumulator only adds zeros after the last tap (no tap is counted twice).
// =============================================================================
`timescale 1ns / 1ps

module fir_filter #(
    parameter int    N_TAPS     = 31,
    parameter string LP_FILE    = "lowpass.mem",
    parameter string HP_FILE    = "highpass.mem",
    parameter string BYP_FILE   = "bypass.mem"
) (
    input  logic               clk,
    input  logic               rst,          // synchronous, active-high
    input  logic signed [15:0] sample_in,
    input  logic               sample_valid, // one-clock pulse per new sample
    input  logic        [1:0]  mode,         // 00 bypass, 01 low-pass, 10 high-pass
    output logic signed [15:0] sample_out,
    output logic               out_valid     // one-clock pulse per new output
);

    localparam int K_BITS = $clog2(N_TAPS);

    // ------------------------------------------------------------------------
    // Delay line: x[n], x[n-1], ..., x[n-30]
    // delay[0] is the newest sample. It shifts only when the filter is IDLE,
    // so the samples never move while the MAC is reading them.
    // ------------------------------------------------------------------------
    logic signed [15:0] delay [0:N_TAPS-1];

    // ------------------------------------------------------------------------
    // Control FSM
    // ------------------------------------------------------------------------
    typedef enum logic [1:0] {IDLE, RUN, FLUSH, DONE} state_t;
    state_t state;

    logic [K_BITS-1:0] k;          // tap index during RUN
    logic [1:0]        flush_cnt;  // counts the FLUSH cycles
    logic [1:0]        mode_reg;   // mode latched at the start of each sample

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            k         <= '0;
            flush_cnt <= '0;
            mode_reg  <= 2'b00;
            for (int i = 0; i < N_TAPS; i++) delay[i] <= '0;
        end else begin
            case (state)
                IDLE: begin
                    k <= '0;
                    if (sample_valid) begin
                        // shift the new sample into the delay line
                        delay[0] <= sample_in;
                        for (int i = 1; i < N_TAPS; i++) delay[i] <= delay[i-1];
                        mode_reg <= mode;
                        state    <= RUN;
                    end
                end
                RUN: begin
                    if (k == K_BITS'(N_TAPS - 1)) begin
                        flush_cnt <= '0;
                        state     <= FLUSH;
                    end else begin
                        k <= k + 1'b1;
                    end
                end
                FLUSH: begin
                    // wait 2 cycles for the last product to reach p_reg
                    flush_cnt <= flush_cnt + 1'b1;
                    if (flush_cnt == 2'd1) state <= DONE;
                end
                DONE: begin
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // Coefficient ROM (3 sets selected by mode)
    // ------------------------------------------------------------------------
    logic signed [15:0] rom_coeff;

    coeff_rom #(
        .N_TAPS  (N_TAPS),
        .LP_FILE (LP_FILE),
        .HP_FILE (HP_FILE),
        .BYP_FILE(BYP_FILE)
    ) u_coeff_rom (
        .mode (mode_reg),
        .addr (k),
        .coeff(rom_coeff)
    );

    // Operands for the MAC. Outside RUN the coefficient is 0, so the
    // accumulator keeps adding zeros and its value does not change.
    logic signed [15:0] sample_tap;
    logic signed [15:0] coeff;
    logic               run_first;   // high on the cycle that feeds tap 0

    always_comb begin
        sample_tap = delay[k];
        coeff      = (state == RUN) ? rom_coeff : 16'sd0;
        run_first  = (state == RUN) && (k == '0);
    end

    // acc_clear must line up with the moment tap 0's product sits in m_reg,
    // which is 2 cycles after tap 0 was fed in (see timeline above).
    logic first_d1, acc_clear;

    always_ff @(posedge clk) begin
        if (rst) begin
            first_d1  <= 1'b0;
            acc_clear <= 1'b0;
        end else begin
            first_d1  <= run_first;
            acc_clear <= first_d1;
        end
    end

    // ------------------------------------------------------------------------
    // The MAC: one DSP48E1 slice
    // ------------------------------------------------------------------------
    (* use_dsp = "yes" *) logic signed [39:0] p_reg;
    logic signed [15:0] a_reg, b_reg;
    logic signed [31:0] m_reg;

    always_ff @(posedge clk) begin
        a_reg <= sample_tap;                          // stage 1
        b_reg <= coeff;
        m_reg <= a_reg * b_reg;                       // stage 2
        p_reg <= acc_clear ? 40'(m_reg)               // stage 3: start new sum
                           : p_reg + 40'(m_reg);      //          or accumulate
    end

    // ------------------------------------------------------------------------
    // Output: scale back from Q1.15 and saturate to 16-bit signed
    // ------------------------------------------------------------------------
    logic signed [24:0] acc_scaled;    // 40 - 15 = 25 bits
    logic signed [15:0] acc_sat;

    always_comb begin
        acc_scaled = 25'(p_reg >>> 15);
        if (acc_scaled > 25'sd32767)
            acc_sat = 16'sd32767;
        else if (acc_scaled < -25'sd32768)
            acc_sat = -16'sd32768;
        else
            acc_sat = acc_scaled[15:0];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sample_out <= '0;
            out_valid  <= 1'b0;
        end else begin
            out_valid <= (state == DONE);
            if (state == DONE) sample_out <= acc_sat;
        end
    end

endmodule
