// =============================================================================
// coeff_rom.sv
// -----------------------------------------------------------------------------
// Holds three sets of N_TAPS x 16-bit FIR coefficients (Q1.15) and returns the
// coefficient at 'addr' from the set chosen by 'mode':
//
//     mode = 00 -> bypass   (a single impulse at the centre tap)
//     mode = 01 -> low-pass
//     mode = 10 -> high-pass
//     mode = 11 -> bypass   (unused switch setting, treated as bypass)
//
// The coefficients are loaded at elaboration time with $readmemh from text
// files (one 4-digit hex word per line) produced by python/gen_coeffs.py.
// The read is combinational, so Vivado builds a small LUT ROM.
//
// IMPORTANT (Vivado): the .mem files (coeffs/lowpass.mem, highpass.mem,
// bypass.mem) must be added to the project as DESIGN sources (for synthesis)
// and must also be visible to SIMULATION (xsim) - Vivado then copies them next
// to the design / simulation run. If they are missing, $readmemh fails
// silently in synthesis and the ROM synthesizes to all zeros (silent output).
// =============================================================================
`timescale 1ns / 1ps

module coeff_rom #(
    parameter int    N_TAPS   = 31,
    parameter string LP_FILE  = "lowpass.mem",
    parameter string HP_FILE  = "highpass.mem",
    parameter string BYP_FILE = "bypass.mem"
) (
    input  logic        [1:0]                mode,
    input  logic        [$clog2(N_TAPS)-1:0] addr,
    output logic signed [15:0]               coeff
);

    logic [15:0] rom_lp  [0:N_TAPS-1];
    logic [15:0] rom_hp  [0:N_TAPS-1];
    logic [15:0] rom_byp [0:N_TAPS-1];

    initial begin
        $readmemh(LP_FILE,  rom_lp);
        $readmemh(HP_FILE,  rom_hp);
        $readmemh(BYP_FILE, rom_byp);
    end

    always_comb begin
        case (mode)
            2'b01:   coeff = rom_lp[addr];
            2'b10:   coeff = rom_hp[addr];
            default: coeff = rom_byp[addr];
        endcase
    end

endmodule
