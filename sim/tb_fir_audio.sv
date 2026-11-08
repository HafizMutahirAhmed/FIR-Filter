// =============================================================================
// tb_fir_audio.sv
// -----------------------------------------------------------------------------
// HARDWARE side of the audio-file verification.
//
// Reads the audio samples made by python/prepare_audio.py (audio_in.txt), sends
// them through the real fir_filter RTL in bypass, low-pass and high-pass mode
// (one mode after the other, reset in between), and writes the outputs to
// audio_out_<mode>.txt. python/compare_audio.py then compares them sample by
// sample with the software model and turns them into WAV files.
//
// The audio is NOT fed in real time: each new sample is sent as soon as the
// previous output is ready (~37 clocks per sample instead of 2560). The
// filter does exactly the same calculation, only the simulation is ~70x
// faster, so a few seconds of audio simulate in under a minute.
//
// See tb_fir_filter.sv for why VEC_DIR should be an absolute path.
// =============================================================================
`timescale 1ns / 1ps

module tb_fir_audio;

    parameter string VEC_DIR = "/home/mutahir/Documents/SV/FIR-Filter/sim/vectors/";

    logic               clk = 1'b0;
    logic               rst;
    logic signed [15:0] sample_in;
    logic               sample_valid;
    logic        [1:0]  mode;
    logic signed [15:0] sample_out;
    logic               out_valid;

    always #5 clk = ~clk;   // 100 MHz

    fir_filter #(.N_TAPS(31)) dut (
        .clk         (clk),
        .rst         (rst),
        .sample_in   (sample_in),
        .sample_valid(sample_valid),
        .mode        (mode),
        .sample_out  (sample_out),
        .out_valid   (out_valid)
    );

    int audio [$];      // all input samples (a queue grows as needed)

    task automatic read_audio();
        int fd, value;
        fd = $fopen({VEC_DIR, "audio_in.txt"}, "r");
        if (fd == 0) begin
            $display("ERROR: cannot open %saudio_in.txt - run prepare_audio.py and check VEC_DIR", VEC_DIR);
            $finish;
        end
        while ($fscanf(fd, "%d", value) == 1) audio.push_back(value);
        $fclose(fd);
        $display("Read %0d audio samples (%.2f s at 39062.5 Hz)", audio.size(), audio.size() / 39062.5);
    endtask

    task automatic run_mode(input logic [1:0] m, input string name);
        int fd, timeout;
        fd = $fopen({VEC_DIR, "audio_out_", name, ".txt"}, "w");
        if (fd == 0) begin
            $display("ERROR: cannot write %saudio_out_%s.txt", VEC_DIR, name);
            $finish;
        end

        // reset so the delay line starts from zero, like the software model
        mode <= m;
        rst  <= 1'b1;
        repeat (5) @(posedge clk);
        rst  <= 1'b0;
        @(posedge clk);

        foreach (audio[i]) begin
            sample_in    <= audio[i][15:0];
            sample_valid <= 1'b1;
            @(posedge clk);
            sample_valid <= 1'b0;

            timeout = 0;
            do begin
                @(posedge clk);
                timeout++;
            end while (!out_valid && timeout < 200);
            if (!out_valid) begin
                $display("ERROR: no out_valid for sample %0d", i);
                $finish;
            end
            $fwrite(fd, "%0d\n", sample_out);
            @(posedge clk);        // filter is back in IDLE, send the next one
        end

        $fclose(fd);
        $display("Hardware %s: wrote %0d samples to %saudio_out_%s.txt",
                 name, audio.size(), VEC_DIR, name);
    endtask

    initial begin
        rst          = 1'b1;
        sample_in    = '0;
        sample_valid = 1'b0;
        mode         = 2'b00;

        read_audio();
        run_mode(2'b00, "bypass");
        run_mode(2'b01, "lowpass");
        run_mode(2'b10, "highpass");

        $display("DONE");
        $finish;
    end

endmodule
