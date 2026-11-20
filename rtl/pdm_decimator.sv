// =============================================================================
// pdm_decimator.sv
// -----------------------------------------------------------------------------
// Turns the 1-bit PDM (pulse density modulation) stream of the on-board MEMS
// microphone into 16-bit signed PCM samples.
//
// 1. Mic clock: a divide-by-CLK_DIV counter makes M_CLK
//    (100 MHz / 40 = 2.5 MHz). M_CLK is low for the first half of the count
//    and high for the second half.
// 2. M_DATA comes from outside the FPGA, so it first goes through a 2-FF
//    synchronizer. It is then sampled once per mic clock by a one-clock strobe
//    placed just before the rising edge of M_CLK (M_LRSEL = 0).
// 3. Decimation with a 3rd-order CIC (cascaded integrator-comb) filter,
//    decimation factor R = DECIM = 64, differential delay 1:
//      - each PDM bit is mapped to x = +1 (bit 1) or -1 (bit 0)
//      - three integrators run at the mic rate (2.5 MHz):
//            i1 += x ;  i2 += i1 ;  i3 += i2
//      - every 64 bits the value of i3 goes through three combs at the
//        output rate (39,062.5 Hz):
//            c1 = i3 - i3_prev ;  c2 = c1 - c1_prev ;  c3 = c2 - c2_prev
//      - DC gain = R^3 = 2^18, so c3 is in -262144 .. +262144 (19 bits plus
//        sign). The registers are W = 21 bits wide. Two's complement wrap-
//        around inside the integrators is expected and harmless: the combs
//        undo it exactly (standard CIC property).
//    The CIC response is sinc^3: it rejects the mic's high-frequency
//    quantization noise far better than a plain ones-counter (sinc^1), and
//    gives about 18 bits of resolution instead of 6.
// 4. Scaling to 16 bits:
//        pcm = sat16( c3 >>> (4 - MIC_GAIN_SHIFT) )
//    MIC_GAIN_SHIFT = 0: full-scale PDM maps to +/-16384 (same scale as the
//    old ones-counter, used by the testbenches). Each step up doubles the
//    gain; MIC_GAIN_SHIFT = 4 uses the full CIC resolution (pcm = c3,
//    saturated). Real speech is far below mic full scale, so the board uses
//    a gain > 0.
//    One sample_valid pulse is produced every 64 mic clocks:
//        2.5 MHz / 64 = 39,062.5 Hz.
// =============================================================================
`timescale 1ns / 1ps

module pdm_decimator #(
    parameter int CLK_DIV        = 40,   // 100 MHz / 40 = 2.5 MHz mic clock
    parameter int DECIM          = 64,   // mic bits per PCM sample (CIC R)
    parameter int MIC_GAIN_SHIFT = 0     // 0..4, see header
) (
    input  logic               clk,
    input  logic               rst,
    input  logic               m_data,       // raw PDM bit from the mic
    output logic               m_clk,        // clock to the mic
    output logic signed [15:0] pcm_out,
    output logic               sample_valid  // one-clock pulse per PCM sample
);

    localparam int DIV_BITS = $clog2(CLK_DIV);
    localparam int DEC_BITS = $clog2(DECIM);
    localparam int W        = 3 * $clog2(DECIM) + 3;   // 21 bits for R = 64
    localparam int SHIFT    = 4 - MIC_GAIN_SHIFT;

    // ---------------- mic clock generation ----------------
    logic [DIV_BITS-1:0] div_cnt;
    logic                bit_strobe;   // one clk wide, once per mic clock

    always_ff @(posedge clk) begin
        if (rst) begin
            div_cnt <= '0;
            m_clk   <= 1'b0;
        end else begin
            if (div_cnt == DIV_BITS'(CLK_DIV - 1)) div_cnt <= '0;
            else                                   div_cnt <= div_cnt + 1'b1;
            m_clk <= (div_cnt >= DIV_BITS'(CLK_DIV / 2 - 1)) &&
                     (div_cnt != DIV_BITS'(CLK_DIV - 1));
        end
    end

    // strobe on the last clock of the low half (just before M_CLK rises)
    assign bit_strobe = (div_cnt == DIV_BITS'(CLK_DIV / 2 - 1));

    // ---------------- 2-FF synchronizer for M_DATA ----------------
    logic data_ff1, data_sync;

    always_ff @(posedge clk) begin
        data_ff1  <= m_data;
        data_sync <= data_ff1;
    end

    // ---------------- CIC integrators (mic rate) ----------------
    logic        [DEC_BITS-1:0] bit_cnt;
    logic signed [W-1:0]        x;
    logic signed [W-1:0]        i1, i2, i3;            // registers
    logic signed [W-1:0]        i1_n, i2_n, i3_n;      // values after this bit

    assign x    = data_sync ? W'(1) : -W'(1);
    assign i1_n = i1 + x;
    assign i2_n = i2 + i1_n;
    assign i3_n = i3 + i2_n;

    // ---------------- CIC combs (output rate) ----------------
    // The integrator output at the end of a window is registered first (s,
    // comb_go), and the combs run on the next clock. This splits the six
    // adders into two clock cycles so timing is met at 100 MHz.
    logic signed [W-1:0] s;                            // i3 at window end
    logic                comb_go;
    logic signed [W-1:0] d1, d2, d3;                   // comb delay registers
    logic signed [W-1:0] c1, c2, c3;
    logic signed [W-1:0] scaled;
    logic signed [15:0]  pcm_sat;

    assign c1     = s    - d1;
    assign c2     = c1   - d2;
    assign c3     = c2   - d3;
    assign scaled = c3 >>> SHIFT;

    always_comb begin
        if      (scaled >  W'(32767))  pcm_sat = 16'sd32767;
        else if (scaled < -W'(32768))  pcm_sat = -16'sd32768;
        else                           pcm_sat = scaled[15:0];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            bit_cnt      <= '0;
            i1           <= '0;
            i2           <= '0;
            i3           <= '0;
            d1           <= '0;
            d2           <= '0;
            d3           <= '0;
            s            <= '0;
            comb_go      <= 1'b0;
            pcm_out      <= '0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            comb_go      <= 1'b0;
            if (comb_go) begin
                // run the combs, output one sample
                d1           <= s;
                d2           <= c1;
                d3           <= c2;
                pcm_out      <= pcm_sat;
                sample_valid <= 1'b1;
            end
            if (bit_strobe) begin
                i1 <= i1_n;
                i2 <= i2_n;
                i3 <= i3_n;
                if (bit_cnt == DEC_BITS'(DECIM - 1)) begin
                    // window complete: hand i3 to the combs
                    s       <= i3_n;
                    comb_go <= 1'b1;
                    bit_cnt <= '0;
                end else begin
                    bit_cnt <= bit_cnt + 1'b1;
                end
            end
        end
    end

endmodule
