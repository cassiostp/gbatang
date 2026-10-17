// Frame-lock bench (iverilog): the real gba2hdmi (138K BRAM path) with the
// real hdmi.sv at the native htotal 861 (480p120), against a line-cited model of the
// GBA frame (gba_gpu_timing.v: 1008+224 mclk per line, 228 lines; vblank on
// the 159->160 transition). The model's mclk counting is gated by the DUT's
// release toggle through an exact copy of the gbatang_top halt block, and by
// pause_tb like the menu pause. The HDMI output runs at twice the game rate:
// every game frame is read twice, so settled inserted reads may show data up
// to a game frame old; anything older is a tear.
//
// -D flags: CLK16H/CLKP50H (half periods in ns), EXPECT_LOCK (1: the GBA runs
// faster than HDMI and must lock; 0: current silicon, must observably fail),
// STD (hdmi std_timing input value).
`timescale 1ns/1ps

module tb_frame_lock;

    reg clk16 = 0, clk50 = 0, clk27 = 0;
    always #`CLK16H clk16 = ~clk16;
    always #`CLKP50H clk50 = ~clk50;
    always #18.5185 clk27 = ~clk27;             // 27 MHz (pll_74 stub ignores it)

    reg resetn = 0;
    reg pause_tb = 0;
    reg gbaon_tb = 0;

    reg [17:0] px_data = 0;
    reg [7:0] px_x = 0, px_y = 0;
    reg px_we = 0;
    reg [15:0] snd_l = 0, snd_r = 1000;

    wire [10:0] ovx; wire [9:0] ovy;
    wire std_w = `STD;

    gba2hdmi dut (
        .clk(clk50), .clk27(clk27), .resetn(resetn), .clk_pixel(),
        .pixel_data(px_data), .pixel_x(px_x), .pixel_y(px_y), .pixel_we(px_we),
        .sound_left(snd_l), .sound_right(snd_r),
        .overlay(1'b0), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(16'd0),
        .scanlines(1'b0), .sl_darkness(2'd0), .sl_thick(1'b0), .sl_out(1'b0),
        .video_config(32'd0),
        .std_timing(std_w), .rel_toggle(),
        .tmds_clk_n(), .tmds_clk_p(), .tmds_d_n(), .tmds_d_p()
    );
    wire clk_pixel = dut.clk_pixel;

    // GBA frame model: mclk counting, gated exactly like the top gates the
    // machine (cpu_en/gpu.pause/timer/dma). Pixel emission is illustrative
    // (one we per source column in the visible window); line completion times
    // and the vblank pulse are cycle-exact to gba_gpu_timing.v.
    reg [10:0] mcyc = 0;        // 0..1231
    reg [7:0] mline = 0;        // 0..227
    reg [9:0] seq = 0;          // GBA frame sequence
    reg [7:0] next_col = 0;
    reg vblank_tb = 0;
    reg [9:0] exp_seq [0:159];  // writer seq recorded at each line completion
    realtime write_end [0:159];

    // Top-level halt block, exact copy of gbatang_top.sv
    reg [2:0] rel_sync = 0;
    reg rel_lvl_q = 0;
    wire rel_pulse_tb = rel_sync[2] ^ rel_lvl_q;
    reg frame_halt_tb = 0;
    wire held = pause_tb | frame_halt_tb;
    always @(posedge clk16) begin
        if (!resetn || !gbaon_tb) begin
            rel_sync <= 3'b0;
            rel_lvl_q <= 1'b0;
            frame_halt_tb <= 1'b0;
        end else begin
            rel_sync <= {rel_sync[1:0], dut.rel_toggle_r};
            rel_lvl_q <= rel_sync[2];
            if (vblank_tb)
                frame_halt_tb <= 1'b1;
            else if (rel_pulse_tb)
                frame_halt_tb <= 1'b0;
        end
    end

    always @(posedge clk16) begin
        vblank_tb <= 1'b0;
        if (!resetn || !gbaon_tb) begin
            mcyc <= 0; mline <= 0; seq <= 0; next_col <= 0;
        end else if (!held) begin
            if (mcyc == 11'd1231) begin
                mcyc <= 0;
                next_col <= 0;
                if (mline == 8'd159) begin
                    mline <= 8'd160;
                    vblank_tb <= 1'b1;
                end else if (mline == 8'd227) begin
                    mline <= 8'd0;
                    seq <= seq + 1'b1;
                end else
                    mline <= mline + 8'd1;
            end else begin
                mcyc <= mcyc + 1'b1;
                if (mline < 8'd160 && mcyc == 11'd1007) begin
                    exp_seq[mline] <= seq;
                    write_end[mline] <= $time;
                end
            end
        end
    end

    // pixel emission on the falling edge (DUT samples on clk50)
    always @(negedge clk16) begin
        px_we <= 1'b0;
        if (resetn && gbaon_tb && !held && mline < 8'd160 && mcyc < 11'd1008) begin
            if (mcyc == (next_col * 21) / 5 && next_col < 8'd240) begin
                px_we <= 1'b1;
                px_x <= next_col;
                px_y <= mline;
                px_data <= {seq, mline};    // 10+8 = 18 bit tag
            end
        end
    end
    // slow audio ramp (both channels), free-running like the PSG
    reg [11:0] snd_div = 0;
    always @(posedge clk16) begin
        if (!resetn) begin snd_l <= 0; snd_r <= 1000; snd_div <= 0; end
        else begin
            snd_div <= snd_div + 1'b1;
            if (snd_div == 0) begin snd_l <= snd_l + 1'b1; snd_r <= snd_r + 1'b1; end
        end
    end

    // HDMI frame tracking + per-line read ages (clk_pixel domain)
    integer hframe = -1;
    integer halts_this = 0;
    realtime halt_start = 0, halt_acc = 0;
    integer vblanks_this = 0;
    reg [7:0] yy_prev = 0;
    integer read_seen [0:159];
    integer stale = 0;
    realtime min_age = 1e18, max_age = -1e18;
    integer i, j;
    reg was_halt = 0;
    reg [9:0] last_cy = 0;
    integer skip_until = 4;     // forgive hframes below this (startup/pause/reset)

    always @(posedge clk_pixel) begin
        if (!resetn) begin
            hframe <= -1;
        end else begin
            if (last_cy == 10'd524 && dut.cy == 10'd0)
                hframe <= hframe + 1;
            last_cy <= dut.cy;
        end
    end
    // read_seen reset on power/reset release (fb holds pre-reset pixels)
    reg resetn_q = 0;
    always @(posedge clk_pixel) begin
        resetn_q <= resetn;
        if (resetn && !resetn_q)
            for (j = 0; j < 160; j = j + 1) read_seen[j] = -1;
    end

    // halt edge accounting (clk16 domain copy for duration)
    always @(posedge clk16) begin
        if (frame_halt_tb && !was_halt) halt_start <= $time;
        if (!frame_halt_tb && was_halt) halt_acc <= halt_acc + ($time - halt_start);
        was_halt <= frame_halt_tb;
    end
    always @(posedge vblank_tb) vblanks_this <= vblanks_this + 1;
    always @(posedge frame_halt_tb) halts_this <= halts_this + 1;

    // read-start detection: yy_s entering a new line
    always @(posedge clk_pixel) begin
        if (resetn && hframe >= skip_until && !pause_tb) begin
            if (dut.yy_s != yy_prev && dut.yy_s < 8'd160) begin
                read_seen[dut.yy_s] <= read_seen[dut.yy_s] + 1;
                if (read_seen[dut.yy_s] > 0) begin
                    if (dut.u_fb.m[dut.yy_s * 240][17:8] !== exp_seq[dut.yy_s]) begin
                        stale <= stale + 1;
                        if (stale < 20)
                            $display("STALE hframe=%0d line=%0d cy=%0d cx=%0d tag=%h exp=%h t=%0t",
                                hframe, dut.yy_s, dut.cy, dut.cx,
                                dut.u_fb.m[dut.yy_s * 240][17:8], exp_seq[dut.yy_s], $time);
                    end else begin
                        realtime age;
                        age = $time - write_end[dut.yy_s];
                        if (age < min_age) min_age = age;
                        if (age > max_age) max_age = age;
                        if (age <= 0 || age > 16740000) begin
                            stale <= stale + 1;
                            if (stale < 20)
                                $display("BADAGE hframe=%0d line=%0d age=%0t", hframe, dut.yy_s, age);
                        end
                    end
                end
            end
            yy_prev <= dut.yy_s;
        end
    end

    // audio continuity: sample the HDMI audio words on clk_audio
    integer audio_n = 0, audio_bad = 0;
    reg [15:0] audio_prev = 0;
    reg audio_first = 1;
    reg audio_rst_q = 0;
    always @(posedge dut.clk_audio) begin
        audio_rst_q <= resetn;
        if (!resetn || !audio_rst_q) audio_first <= 1;
        else if (gbaon_tb) begin
            audio_n <= audio_n + 1;
            if (!audio_first) begin
                integer d;
                d = dut.audio_sample_word[0] - audio_prev;
                if (d < 0) d = -d;
                // ramp wraps FFFF->0000: forgive the wrap step
                if (d > 4 && !(audio_prev > 16'hFFF0 && dut.audio_sample_word[0] < 16'h0010)) begin
                    audio_bad <= audio_bad + 1;
                    if (audio_bad < 10)
                        $display("AUDIOJUMP n=%0d prev=%h now=%h", audio_n, audio_prev, dut.audio_sample_word[0]);
                end
            end
            audio_first <= 0;
            audio_prev <= dut.audio_sample_word[0];
        end
    end

    // scenario driver + verdict
    integer errors = 0;
    integer f_mark = 0;
    integer phase = 0;      // 0 startup, 1 steady, 2 pause, 3 relock1, 4 reset-wait, 5 relock2, 6 done
    integer pause_frames = 0;
    reg need_reset = 0;
    reg [9:0] cy_prev2 = 0;

    task frame_tick;    // called on each cy wrap
    begin
        $display("FRAME h=%0d halts=%0d vblanks=%0d halt_us=%0.2f min_age_us=%0.2f max_age_us=%0.2f stale=%0d audio=%0d/%0d",
            hframe, halts_this, vblanks_this, halt_acc / 1000.0,
            (min_age > 1e17) ? -1.0 : min_age / 1000.0,
            (max_age < 0) ? -1.0 : max_age / 1000.0, stale, audio_bad, audio_n);
        case (phase)
        0: if (hframe >= 8) begin
            if (`EXPECT_LOCK) begin
                if (halts_this < 4 || vblanks_this < 4) begin
                    $display("FAIL: startup did not lock (halts=%0d vblanks=%0d)", halts_this, vblanks_this);
                    errors <= errors + 1;
                end
            end
            phase <= 1; f_mark <= hframe;
            halts_this <= 0; vblanks_this <= 0; halt_acc <= 0; stale <= 0; min_age <= 1e18; max_age <= -1e18;
        end
        1: if (hframe - f_mark >= 24) begin
            $display("STEADY halts=%0d vblanks=%0d halt_us_per_frame=%0.2f stale=%0d",
                halts_this, vblanks_this, halt_acc / 12.0 / 1000.0, stale);
            if (`EXPECT_LOCK) begin
                if (halts_this != 12 || vblanks_this != 12) begin
                    $display("FAIL: steady not 1:1 (halts=%0d vblanks=%0d)", halts_this, vblanks_this);
                    errors <= errors + 1;
                end
                if (stale != 0) begin $display("FAIL: steady stale=%0d", stale); errors <= errors + 1; end
            end
            phase <= 2; pause_tb <= 1'b1; pause_frames <= 0;
            halts_this <= 0; vblanks_this <= 0; halt_acc <= 0; stale <= 0; min_age <= 1e18; max_age <= -1e18;
        end
        2: begin
            pause_frames <= pause_frames + 1;
            if (pause_frames >= 6) begin
                pause_tb <= 1'b0;
                skip_until <= hframe + 4;
                phase <= 3; f_mark <= hframe;
                halts_this <= 0; vblanks_this <= 0; halt_acc <= 0; stale <= 0; min_age <= 1e18; max_age <= -1e18;
            end
        end
        3: if (hframe - f_mark >= 8) begin
            $display("POSTPAUSE halts=%0d vblanks=%0d stale=%0d", halts_this, vblanks_this, stale);
            if (`EXPECT_LOCK && vblanks_this < 3) begin
                $display("FAIL: post-pause no progress (vblanks=%0d)", vblanks_this);
                errors <= errors + 1;
            end
            phase <= 4;
            need_reset <= 1'b1;
            halts_this <= 0; vblanks_this <= 0; halt_acc <= 0; stale <= 0; min_age <= 1e18; max_age <= -1e18;
        end
        5: if (hframe - f_mark >= 12) begin
            $display("POSTRESET halts=%0d vblanks=%0d stale=%0d", halts_this, vblanks_this, stale);
            if (`EXPECT_LOCK && vblanks_this < 5) begin
                $display("FAIL: post-reset no progress (vblanks=%0d)", vblanks_this);
                errors <= errors + 1;
            end
            phase <= 6;
        end
        endcase
    end
    endtask

    always @(posedge clk_pixel) begin
        cy_prev2 <= dut.cy;
        if (resetn && cy_prev2 == 10'd524 && dut.cy == 10'd0)
            frame_tick;
    end

    // core reset scenario (200 us), driven outside the clocked tick
    always @(posedge need_reset) begin
        resetn = 1'b0;
        #200000;
        resetn = 1'b1;
        skip_until = hframe + 4;
        f_mark = hframe;
        phase = 5;
    end

    initial begin
        for (i = 0; i < 160; i = i + 1) begin read_seen[i] = -1; exp_seq[i] = 10'h3ff; write_end[i] = 0; end
        // Gowin regs power up 0; force the same so clk_audio runs (no reset in the DUT)
        dut.audio_divider = 0;
        dut.clk_audio = 0;
        #100000 resetn = 1'b1;      // 100 us power-on reset
        #1000 gbaon_tb = 1'b1;
        wait (phase == 6);
        #100000;
        if (`EXPECT_LOCK) begin
            if (errors == 0 && stale == 0 && audio_bad == 0)
                $display("tb_frame_lock: PASS");
            else
                $display("tb_frame_lock: FAIL errors=%0d stale=%0d audio_bad=%0d", errors, stale, audio_bad);
        end else begin
            // negative control: the slow GBA must observably miss the lock
            if (stale > 0)
                $display("tb_frame_lock: PASS (slow-GBA control caught %0d stale reads)", stale);
            else
                $display("tb_frame_lock: FAIL (slow-GBA control saw no failure)");
        end
        $finish;
    end

    // watchdog: ~200 HDMI frames max
    initial begin
        #2200000000;
        $display("tb_frame_lock: FAIL (watchdog)");
        $finish;
    end

endmodule
