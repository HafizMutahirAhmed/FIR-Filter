// =============================================================================
// tb_coeff_rom.sv
// -----------------------------------------------------------------------------
// Self-checking testbench for coeff_rom.
//   1. Reads the three .mem files itself and checks EVERY address of EVERY
//      mode (00, 01, 10, 11) against them -> tests the mode mux, the address
//      decode and the sign of the output.
//   2. Checks properties of the coefficient sets that must always hold:
//        - no X/Z values (the .mem files were found and are complete)
//        - bypass = single 0x7FFF at the centre tap, zeros elsewhere
//        - low-pass and high-pass are symmetric (linear phase)
//        - low-pass DC gain ~ 1.0  (sum ~ 32768)
//        - high-pass DC gain ~ 0   (|sum| small)
// Prints "TEST PASSED" or "TEST FAILED" with the number of errors.
// Needs the .mem files in the xsim folder (Vivado copies them automatically
// when they are added to the project).
// =============================================================================
`timescale 1ns / 1ps

module tb_coeff_rom;

    localparam int N_TAPS = 31;

    logic        [1:0]  mode;
    logic        [4:0]  addr;
    logic signed [15:0] coeff;

    coeff_rom #(.N_TAPS(N_TAPS)) dut (
        .mode (mode),
        .addr (addr),
        .coeff(coeff)
    );

    // the testbench's own copy of the coefficient files
    logic [15:0] ref_lp  [0:N_TAPS-1];
    logic [15:0] ref_hp  [0:N_TAPS-1];
    logic [15:0] ref_byp [0:N_TAPS-1];

    int errors = 0;

    // read the ROM output for one mode/address
    task automatic read_rom(input logic [1:0] m, input int k, output logic signed [15:0] c);
        mode = m;
        addr = k[4:0];
        #1;
        c = coeff;
    endtask

    initial begin
        logic signed [15:0] c, c_mirror, expected;
        int sum_lp, sum_hp;

        $readmemh("lowpass.mem",  ref_lp);
        $readmemh("highpass.mem", ref_hp);
        $readmemh("bypass.mem",   ref_byp);

        // ---- 1. every address of every mode ----
        for (int m = 0; m < 4; m++) begin
            for (int k = 0; k < N_TAPS; k++) begin
                read_rom(m[1:0], k, c);
                case (m)
                    1:       expected = ref_lp[k];
                    2:       expected = ref_hp[k];
                    default: expected = ref_byp[k];   // 00 and 11 = bypass
                endcase
                if ($isunknown(c)) begin
                    $display("ERROR: mode %0d addr %0d is X (mem file missing?)", m, k);
                    errors++;
                end else if (c !== expected) begin
                    $display("ERROR: mode %0d addr %0d: got %0d, expected %0d", m, k, c, expected);
                    errors++;
                end
            end
        end
        $display("Checked all 4 modes x %0d addresses", N_TAPS);

        // ---- 2. properties ----
        sum_lp = 0;
        sum_hp = 0;
        for (int k = 0; k < N_TAPS; k++) begin
            // bypass impulse
            read_rom(2'b00, k, c);
            if (k == N_TAPS / 2 && c !== 16'sh7FFF) begin
                $display("ERROR: bypass centre tap = %0d, expected 32767", c);
                errors++;
            end
            if (k != N_TAPS / 2 && c !== 16'sd0) begin
                $display("ERROR: bypass tap %0d = %0d, expected 0", k, c);
                errors++;
            end

            // symmetry h[k] == h[N-1-k]
            read_rom(2'b01, k, c);
            read_rom(2'b01, N_TAPS - 1 - k, c_mirror);
            if (c !== c_mirror) begin
                $display("ERROR: low-pass not symmetric at tap %0d", k);
                errors++;
            end
            sum_lp += c;

            read_rom(2'b10, k, c);
            read_rom(2'b10, N_TAPS - 1 - k, c_mirror);
            if (c !== c_mirror) begin
                $display("ERROR: high-pass not symmetric at tap %0d", k);
                errors++;
            end
            sum_hp += c;
        end

        $display("Sum low-pass  = %0d (DC gain %f)", sum_lp, sum_lp / 32768.0);
        $display("Sum high-pass = %0d (DC gain %f)", sum_hp, sum_hp / 32768.0);
        if (sum_lp < 32768 - 64 || sum_lp > 32768 + 64) begin
            $display("ERROR: low-pass DC gain is not ~1.0");
            errors++;
        end
        if (sum_hp < -1024 || sum_hp > 1024) begin
            $display("ERROR: high-pass DC gain is not ~0");
            errors++;
        end

        if (errors == 0) $display("TEST PASSED: tb_coeff_rom");
        else             $display("TEST FAILED: tb_coeff_rom, %0d errors", errors);
        $finish;
    end

endmodule
