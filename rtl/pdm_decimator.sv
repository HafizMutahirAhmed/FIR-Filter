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
// 3. Decimation: count how many '1' bits arrive in DECIM = 64 mic clocks.
//    The count is 0..64; 32 means "silence". The PCM value is
//        pcm = (count - 32) <<< 9        -> about -16384 .. +16384
//    and one sample_valid pulse is produced every 64 mic clocks:
//        2.5 MHz / 64 = 39,062.5 Hz.
//
// NOTE: counting ones over a window is a boxcar (sinc^1) filter. It is crude:
// only 65 output levels (about 6 bits) and some aliasing of high-frequency
// noise. That is fine for this demo. A 3rd-order CIC filter would be better
// and is a possible stretch goal (not implemented here).
// =============================================================================
`timescale 1ns / 1ps

module pdm_decimator #(
    parameter int CLK_DIV = 40,   // 100 MHz / 40 = 2.5 MHz mic clock
    parameter int DECIM   = 64    // mic bits per PCM sample
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
    localparam int CNT_BITS = $clog2(DECIM + 1);

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

    // ---------------- count ones over DECIM bits ----------------
    logic [DEC_BITS-1:0] bit_cnt;
    logic [CNT_BITS-1:0] ones_cnt;
    logic [CNT_BITS-1:0] ones_total;

    assign ones_total = ones_cnt + CNT_BITS'(data_sync);

    always_ff @(posedge clk) begin
        if (rst) begin
            bit_cnt      <= '0;
            ones_cnt     <= '0;
            pcm_out      <= '0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            if (bit_strobe) begin
                if (bit_cnt == DEC_BITS'(DECIM - 1)) begin
                    // window complete: convert the count to signed PCM
                    pcm_out      <= 16'(($signed({1'b0, ones_total}) - DECIM / 2) <<< 9);
                    sample_valid <= 1'b1;
                    ones_cnt     <= '0;
                    bit_cnt      <= '0;
                end else begin
                    ones_cnt <= ones_total;
                    bit_cnt  <= bit_cnt + 1'b1;
                end
            end
        end
    end

endmodule
