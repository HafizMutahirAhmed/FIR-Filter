// =============================================================================
// tb_chain_audio.sv
// -----------------------------------------------------------------------------
// HARDWARE side of the whole-chain audio verification. The complete top level
// audio_fir_system is simulated:
//
//   chain_pdm.txt --> M_DATA pin --> pdm_decimator --> fir_filter --> pwm_out --> AUD_PWM pin
//
// The PDM bits (made from an audio file by python/prepare_chain.py) are put
// on M_DATA like a real microphone: bit 0 before the first M_CLK period, then
// the next bit after every falling edge of M_CLK. The whole file is played
// once for each switch setting: bypass (00), low-pass (01), high-pass (10),
// with a reset (CPU_RESETN) before each run.
//
// Recorded for each mode (compared with python/compare_chain.py):
//   chain_out_pcm_<mode>.txt  decimator output, one value per PCM sample
//   chain_out_fir_<mode>.txt  FIR output, one value per sample
//   chain_out_pwm_<mode>.txt  for every 256-clock PWM period: the FIR value the
//                             PWM loaded at the start of the period and the
//                             number of clocks AUD_PWM was high (measured on
//                             the output pin)
//
// This runs in real time (2560 clocks per audio sample), because the mic
// clock and decimator are part of the test. 0.5 s of audio = 3 x 50 M clocks.
// See tb_fir_filter.sv for why VEC_DIR should be an absolute path.
// =============================================================================
`timescale 1ns / 1ps

module tb_chain_audio;

    parameter string VEC_DIR = "/home/mutahir/Documents/SV/FIR-Filter/sim/vectors/";

    logic        clk = 1'b0;
    logic        CPU_RESETN;
    logic [1:0]  SW;
    logic        M_DATA;
    logic        M_CLK;
    logic        M_LRSEL;
    logic        AUD_PWM;
    logic        AUD_SD;
    logic [15:0] LED;

    always #5 clk = ~clk;   // 100 MHz

    audio_fir_system dut (
        .clk       (clk),
        .CPU_RESETN(CPU_RESETN),
        .SW        (SW),
        .M_DATA    (M_DATA),
        .M_CLK     (M_CLK),
        .M_LRSEL   (M_LRSEL),
        .AUD_PWM   (AUD_PWM),
        .AUD_SD    (AUD_SD),
        .LED       (LED)
    );

    // ---------------- PDM input bits ----------------
    bit pdm_bits [$];

    task automatic read_pdm();
        int fd, value;
        fd = $fopen({VEC_DIR, "chain_pdm.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open %schain_pdm.txt - run prepare_chain.py and check VEC_DIR", VEC_DIR);
            $finish;
        end
        while ($fscanf(fd, "%d", value) == 1) pdm_bits.push_back(value[0]);
        $fclose(fd);
        $display("Read %0d PDM bits (%.3f s of audio)", pdm_bits.size(), pdm_bits.size() / 2.5e6);
    endtask

    // ---------------- recorders ----------------
    bit logging = 0;
    int fd_pcm, fd_fir, fd_pwm;

    // decimator and FIR outputs
    always @(posedge clk) begin
        if (logging) begin
            if (dut.pcm_valid) $fwrite(fd_pcm, "%0d\n", dut.pcm);
            if (dut.fir_valid) $fwrite(fd_fir, "%0d\n", dut.fir_out);
        end
    end

    // PWM: count the high clocks of the AUD_PWM pin in each 256-clock period.
    // pwm_out loads a new duty at the clock edge where its counter is 255,
    // from the FIR value present at that edge. AUD_PWM is registered, so that
    // period shows up on the pin one clock later; the period is complete at
    // the edge where the counter is 0 again.
    int          pwm_high;
    int          win_fir,  pend_fir;
    bit          win_ok,   pend_ok;

    always @(posedge clk) begin
        if (!logging || dut.rst) begin
            win_ok  <= 0;
            pend_ok <= 0;
        end else begin
            if (dut.u_pwm.counter == 8'd0) begin
                if (win_ok) $fwrite(fd_pwm, "%0d %0d\n", win_fir, pwm_high + AUD_PWM);
                pwm_high = 0;
                win_fir  = pend_fir;
                win_ok  <= pend_ok;
            end else begin
                pwm_high = pwm_high + AUD_PWM;
            end
            if (dut.u_pwm.counter == 8'd255) begin
                pend_fir = dut.fir_out;
                pend_ok <= 1;
            end
        end
    end

    // ---------------- one complete run for one switch setting ----------------
    task automatic run_mode(input logic [1:0] sw_value, input string name);
        fd_pcm = $fopen({VEC_DIR, "chain_out_pcm_", name, ".txt"}, "w");
        fd_fir = $fopen({VEC_DIR, "chain_out_fir_", name, ".txt"}, "w");
        fd_pwm = $fopen({VEC_DIR, "chain_out_pwm_", name, ".txt"}, "w");

        // reset with the new switch setting and the first PDM bit on M_DATA
        CPU_RESETN = 1'b0;
        SW         = sw_value;
        M_DATA     = pdm_bits[0];
        repeat (20) @(posedge clk);
        logging = 1;
        @(negedge clk);
        CPU_RESETN = 1'b1;

        // like the mic: next bit after every falling edge of M_CLK
        for (int i = 1; i < pdm_bits.size(); i++) begin
            @(negedge M_CLK);
            M_DATA <= pdm_bits[i];
        end
        @(negedge M_CLK);        // let the last window, FIR and PWM finish
        repeat (1000) @(posedge clk);

        logging = 0;
        $fclose(fd_pcm);
        $fclose(fd_fir);
        $fclose(fd_pwm);
        $display("Hardware %s: done at %0t", name, $time);
    endtask

    initial begin
        CPU_RESETN = 1'b0;
        SW         = 2'b00;
        M_DATA     = 1'b0;

        read_pdm();
        run_mode(2'b00, "bypass");
        run_mode(2'b01, "lowpass");
        run_mode(2'b10, "highpass");

        $display("DONE");
        $finish;
    end

endmodule
