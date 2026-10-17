// Audio-hold bench (iverilog): the real gba_sound (PSG ch1-4, both DMA
// channels, mixer) with a GBA-bus driver. Programs a ch2 square wave and a
// DMA-A stream, then runs them under a ce pattern that mimics core_hold
// (HOLD mclk held every FRAME mclk, exact counts) like the frame lock does.
// The DMA timer ticks are issued only while ce=1, modelling gba_timer, whose
// gb_on=~core_hold already freezes it (gba_timer_module.v:77).
//
// Checks:
//  1. PSG pitch is the GBATEK pitch: ch1/2 wave period is 128*(2048-N)
//     clk (the PSG timebase is clk/4 = 4.194304 MHz, one wavetable step
//     every 4*(2048-N) PSG cycles), and under gating it follows game
//     speed (0.05%).
//  2. The mixer output holds (never silent, never forced to 0) across holds.
//  3. DMA consumption tracks issued ticks exactly (floor(ticks/4) dwords)
//     with no lost writes, and the FIFO does not move during holds, so the
//     DirectSound rate follows game speed.
//  4. No sample step larger than the free-run maximum (no clicks/buzz).
//  5. ch3 wave period is 32 * 8*(2048-N) clk, the ch4 LFSR clocks at
//     524288 Hz / r / 2^(s+1), and a length-limited ch2 note ends after
//     its 256 Hz length ticks (all clk/4-derived, GBATEK rates).
`timescale 1ns/1ps

// File-scope copy of the bus/regmap header: Verilator 5.052 hits an internal
// error (V3LinkDotIfaceCapture) on the module-scope `includes of this header
// combined with struct-typed parameters, so the header is included once here
// at compilation-unit scope instead. The include guard makes every
// module-scope copy empty, and all modules share this one typedef. Gowin
// synthesis (CI) still compiles the untouched module-scope includes.
`include "pproc_bus_gba.sv"

module tb_audio_hold;

    localparam CLK16H = 29.7369;            // 138K clk16 16.8125 MHz, half period
    localparam FRAME = 281469;              // mclk per game frame at 16.8125 MHz (480p120 lock: 59.7312 Hz)
    localparam HOLD = FRAME - 280896;       // 573 mclk halted per frame
    localparam NFRAMES = 24;
    localparam FREE_CLKS = 3000000;
    localparam WAVE_N = 1929;               // ch2 freq reg
    localparam WAVE_PERIOD = 128 * (2048 - WAVE_N);  // 15232 mclk: GBATEK
                                            // 131072/(2048-N) Hz at 16.78 MHz
                                            // (8 steps x 4 PSG cycles x 4 clk)
    localparam WAVE3_N = 1984;              // ch3 rate reg (2048-N = 64)
    localparam WAVE3_PERIOD = 32 * 8 * (2048 - WAVE3_N);  // 16384 mclk
    localparam TICK_EVERY = 1600;           // DMA timer tick spacing (active clks)

    reg clk = 0;
    always #CLK16H clk = ~clk;

    reg reset = 1;
    reg ce = 1;

    reg [31:0] gb_bus_din = 0;
    wire [31:0] gb_bus_dout;
    reg [27:0] gb_bus_adr = 0;
    reg gb_bus_rnw = 1;
    reg gb_bus_ena = 0;
    reg gb_bus_done = 1;
    reg [1:0] gb_bus_acc = 2'b10;
    reg [3:0] gb_bus_be = 0;
    reg gb_bus_rst = 0;

    reg timer0_tick = 0;
    reg timer1_tick = 0;

    wire [1:0] sound_dma_req;
    wire signed [15:0] sound_out_left, sound_out_right;
    wire [31:0] debug_fifocount;

    gba_sound dut (
        .clk(clk), .gb_on(1'b1), .reset(reset), .ce(ce),
        .gb_bus_din(gb_bus_din), .gb_bus_dout(gb_bus_dout),
        .gb_bus_adr(gb_bus_adr), .gb_bus_rnw(gb_bus_rnw),
        .gb_bus_ena(gb_bus_ena), .gb_bus_done(gb_bus_done),
        .gb_bus_acc(gb_bus_acc), .gb_bus_be(gb_bus_be),
        .gb_bus_rst(gb_bus_rst),
        .timer0_tick(timer0_tick), .timer1_tick(timer1_tick),
        .sound_dma_req(sound_dma_req),
        .sound_out_left(sound_out_left), .sound_out_right(sound_out_right),
        .debug_fifocount(debug_fifocount)
    );

    task bus_write(input [27:0] adr, input [31:0] data, input [3:0] be);
        @(posedge clk);
        gb_bus_adr <= adr; gb_bus_din <= data; gb_bus_rnw <= 0;
        gb_bus_be <= be; gb_bus_acc <= 2'b10; gb_bus_ena <= 1;
        @(posedge clk); @(posedge clk);
        gb_bus_ena <= 0;
        @(posedge clk); @(posedge clk); @(posedge clk);
    endtask

    integer errors = 0;
    integer i;

    // edge/period measurement state (written by monitor, read by sequence)
    reg prev_neg = 0;
    integer edge_cnt = 0;
    integer first_edge_clk = 0, last_edge_clk = 0;
    integer first_edge_hold = 0, last_edge_hold = 0;
    integer clk_cnt = 0, hold_cnt = 0;
    reg armed = 0;

    // hold constancy state
    reg signed [15:0] hold_val = 0;
    reg in_hold = 0;
    integer fifo_at_hold_entry = 0;
    integer phase = 0;

    // max-step trackers (one enable per phase; enables set before the phase)
    reg track_free = 0, track_gated = 0;
    integer free_max_delta = 0, gated_max_step = 0;
    reg signed [15:0] prev_samp = 0;
    integer d;

    // DMA state
    reg dma_active = 0;
    reg refill_en = 0;
    integer ticks_issued = 0;
    integer tick_phase = 0;
    integer dwords_written = 0;
    integer lost_writes = 0;
    reg [31:0] wdata = 32'h04030201;
    integer pops = 0;
    reg [2:0] last_base = 0;

    task arm_edges;
        edge_cnt <= 0; clk_cnt <= 0; hold_cnt <= 0;
        first_edge_clk <= 0; last_edge_clk <= 0;
        first_edge_hold <= 0; last_edge_hold <= 0;
        prev_neg <= (sound_out_left < 0);
        armed <= 1;
    endtask

    always @(posedge clk) begin
        if (armed) begin
            clk_cnt <= clk_cnt + 1;
            if (!ce) hold_cnt <= hold_cnt + 1;
            if (prev_neg && sound_out_left >= 0) begin
                edge_cnt <= edge_cnt + 1;
                if (edge_cnt == 0) begin
                    first_edge_clk <= clk_cnt;
                    first_edge_hold <= hold_cnt;
                end
                last_edge_clk <= clk_cnt;
                last_edge_hold <= hold_cnt;
            end
            prev_neg <= (sound_out_left < 0);
        end

        // hold constancy: every held sample equals the hold-entry value, and
        // the value is live audio (never the muted 0)
        if (!ce && !reset) begin
            if (!in_hold) begin
                hold_val <= sound_out_left;
                in_hold <= 1;
                if (sound_out_left == 0) begin
                    $display("FAIL: hold entered with silent output (phase %0d t=%0t)",
                             phase, $time);
                    errors <= errors + 1;
                end
                fifo_at_hold_entry <= debug_fifocount;
            end else begin
                if (sound_out_left !== hold_val) begin
                    $display("FAIL: output moved during hold (%0d -> %0d)",
                             hold_val, sound_out_left);
                    errors <= errors + 1;
                end
                if (debug_fifocount !== fifo_at_hold_entry) begin
                    $display("FAIL: DMA fifo moved during hold");
                    errors <= errors + 1;
                end
            end
        end else
            in_hold <= 0;

        // max-step trackers
        if (!reset) begin
            d = (sound_out_left >= prev_samp)
                ? (sound_out_left - prev_samp) : (prev_samp - sound_out_left);
            if (track_free && d > free_max_delta) free_max_delta <= d;
            if (track_gated && d > gated_max_step) gated_max_step <= d;
        end
        prev_samp <= sound_out_left;

        // count DMA fifo pops (base advances once per popped dword)
        if (!reset) begin
            if (!$isunknown(dut.igba_sound_dmaA.fifo_base)
                && !$isunknown(last_base)
                && dut.igba_sound_dmaA.fifo_base !== last_base)
                pops <= pops + 1;
            last_base <= dut.igba_sound_dmaA.fifo_base;
        end
    end

    real free_per, gated_per, ratio;
    integer expect_fifo;

    initial begin
        repeat (20) @(posedge clk);
        reset <= 0;
        repeat (10) @(posedge clk);

        // master enable (SOUNDCNT_X bit 7)
        bus_write(28'h084, 32'h00000080, 4'h3);
        // SOUNDCNT_L: master vol 7/7, ch2 enable R+L
        bus_write(28'h080, 32'h00002277, 4'h3);
        // SOUNDCNT_H: PSG volume 100%
        bus_write(28'h080, 32'h00020000, 4'hC);
        // ch2: duty 2 (50%), vol 12, no envelope
        bus_write(28'h068, 32'h0000C080, 4'h3);
        // ch2: freq N, infinite length, restart
        bus_write(28'h06C, 32'h00008000 | WAVE_N, 4'h3);
        repeat (100) @(posedge clk);

        // ---- Phase A: free-run pitch reference (DMA off) ----
        track_free <= 1;
        arm_edges;
        repeat (FREE_CLKS) @(posedge clk);
        track_free <= 0;
        armed <= 0;
        repeat (4) @(posedge clk);
        free_per = 1.0 * (last_edge_clk - first_edge_clk) / (edge_cnt - 1);
        $display("free: edges=%0d clks/period=%0f (expect %0d) maxstep=%0d",
                 edge_cnt, free_per, WAVE_PERIOD, free_max_delta);
        if (edge_cnt < 150) begin
            $display("FAIL: too few free edges"); errors = errors + 1;
        end
        if (free_per < WAVE_PERIOD - 0.01 || free_per > WAVE_PERIOD + 0.01) begin
            $display("FAIL: free pitch != GBATEK 131072/(2048-N) Hz"); errors = errors + 1;
        end

        // ---- Phase B: gated run, PSG only ----
        track_gated <= 1;
        phase <= 2;
        arm_edges;
        for (i = 0; i < NFRAMES; i = i + 1) begin
            repeat (FRAME - HOLD) @(posedge clk);
            ce <= 0;
            repeat (HOLD) @(posedge clk);
            ce <= 1;
        end
        repeat (WAVE_PERIOD * 3) @(posedge clk);
        track_gated <= 0;
        armed <= 0;
        repeat (4) @(posedge clk);
        // wave-advance clks between first/last edge, holds subtracted exactly
        gated_per = 1.0 * ((last_edge_clk - first_edge_clk)
                         - (last_edge_hold - first_edge_hold))
                        / (edge_cnt - 1);
        ratio = gated_per / free_per;
        $display("gated: edges=%0d advance/period=%0f free=%0f ratio=%0f (tol 0.0005)",
                 edge_cnt, gated_per, free_per, ratio);
        if (ratio < 0.9995 || ratio > 1.0005) begin
            $display("FAIL: PSG pitch does not follow game speed");
            errors = errors + 1;
        end
        $display("max step free=%0d gated=%0d", free_max_delta, gated_max_step);
        if (gated_max_step > free_max_delta) begin
            $display("FAIL: gated step exceeds free step (click/buzz)");
            errors = errors + 1;
        end

        // ---- Phase C: DMA-A follows gated ticks ----
        phase <= 3;
        bus_write(28'h080, 32'h00000077, 4'h3);   // ch2 L/R off, vols kept
        bus_write(28'h080, 32'h03840000, 4'hC);  // fifo reset + A en L+R, vol 100%
        bus_write(28'h080, 32'h03040000, 4'hC);  // clear reset, keep enables
        for (i = 0; i < 7; i = i + 1) begin
            bus_write(28'h0A0, wdata, 4'hF);
            dwords_written = dwords_written + 1;
            wdata = wdata + 32'h04040404;
        end
        dma_active <= 1;
        refill_en <= 1;
        repeat (2) @(posedge clk);
        for (i = 0; i < NFRAMES; i = i + 1) begin
            repeat (FRAME - HOLD) @(posedge clk);
            ce <= 0;
            repeat (HOLD) @(posedge clk);
            ce <= 1;
        end
        refill_en <= 0;
        repeat (TICK_EVERY * 8) @(posedge clk);   // flush issued ticks
        dma_active <= 0;
        repeat (4) @(posedge clk);
        // conservation: dwords enter only via bus writes, leave only via
        // pops (one per 4 ticks); the afterfifo stage is downstream of the
        // fifo count, so no extra term.
        expect_fifo = dwords_written - ticks_issued / 4;
        $display("dma: ticks=%0d fifo=%0d expect=%0d written=%0d lost=%0d pops=%0d",
                 ticks_issued, debug_fifocount, expect_fifo,
                 dwords_written, lost_writes, pops);
        if (lost_writes != 0) begin
            $display("FAIL: DMA writes lost (fifo overran)"); errors = errors + 1;
        end
        if (debug_fifocount !== expect_fifo) begin
            $display("FAIL: DMA consumption does not track ticks");
            errors = errors + 1;
        end
        if (pops !== ticks_issued / 4) begin
            $display("FAIL: DMA pops do not track ticks");
            errors = errors + 1;
        end

        // ---- Phase D: ch3/ch4 rates + ch2 length tick (GBATEK, clk/4) ----
        phase <= 4;
        // DMA channels off, PSG volume 100%
        bus_write(28'h080, 32'h00020000, 4'hC);
        // wave RAM: 16 digits F then 16 digits 0 (written to the access
        // bank; the bank select below points playback at it)
        bus_write(28'h090, 32'hFFFFFFFF, 4'hF);
        bus_write(28'h094, 32'hFFFFFFFF, 4'hF);
        bus_write(28'h098, 32'h00000000, 4'hF);
        bus_write(28'h09C, 32'h00000000, 4'hF);
        // SOUND3CNT_L: dimension 0, bank 1 (the written bank), channel on;
        // SOUND3CNT_H (same word): length 0, volume 100%
        bus_write(28'h070, 32'h200000C0, 4'hF);
        // SOUNDCNT_L: ch3 enable R+L only
        bus_write(28'h080, 32'h00004477, 4'h3);
        // SOUND3CNT_X: rate WAVE3_N, restart, no length stop
        bus_write(28'h074, 32'h00008000 | WAVE3_N, 4'h3);
        repeat (200) @(posedge clk);
        arm_edges;
        repeat (2000000) @(posedge clk);
        armed <= 0;
        repeat (4) @(posedge clk);
        free_per = 1.0 * (last_edge_clk - first_edge_clk) / (edge_cnt - 1);
        $display("ch3: edges=%0d clks/period=%0f (expect %0d)",
                 edge_cnt, free_per, WAVE3_PERIOD);
        if (edge_cnt < 100) begin
            $display("FAIL: too few ch3 edges"); errors = errors + 1;
        end
        if (free_per < WAVE3_PERIOD - 0.05 || free_per > WAVE3_PERIOD + 0.05) begin
            $display("FAIL: ch3 rate != GBATEK 2097152/(2048-N) samples/s");
            errors = errors + 1;
        end

        // ch4: LFSR rate. ratio code 1 (r=1), shift s=0: 524288/1/2 Hz,
        // i.e. one shift per 64 clk. Count shifts hierarchically.
        bus_write(28'h080, 32'h00008877, 4'h3);   // ch4 enable R+L only
        bus_write(28'h078, 32'h00008000, 4'h3);   // vol 8, no envelope, len 0
        bus_write(28'h07C, 32'h00008001, 4'h3);   // r=1, s=0, restart
        repeat (200) @(posedge clk);
        begin : ch4count
            integer shifts, k;
            reg [14:0] prev_lfsr;
            shifts = 0;
            prev_lfsr = dut.igba_sound_ch4.lfsr;
            for (k = 0; k < 640000; k = k + 1) begin
                @(posedge clk);
                if (dut.igba_sound_ch4.lfsr !== prev_lfsr) shifts = shifts + 1;
                prev_lfsr = dut.igba_sound_ch4.lfsr;
            end
            $display("ch4: shifts=%0d in 640000 clk (expect 10000 +/- 100)", shifts);
            if (shifts < 9900 || shifts > 10100) begin
                $display("FAIL: ch4 LFSR rate != GBATEK 524288/r/2^(s+1) Hz");
                errors = errors + 1;
            end
        end

        // ch2 length: length_left = 4 ticks at 256 Hz = 4*65536 clk.
        // The tick counter free-runs, so the note must still be on at
        // +131072 clk (2 ticks cannot have elapsed... up to 3 may) and
        // must be off by +400000 clk (more than 5 ticks always elapse).
        bus_write(28'h080, 32'h00002277, 4'h3);   // ch2 enable R+L only
        bus_write(28'h068, 32'h0000C080 | 60, 4'h3);  // len 60 -> 4 left
        bus_write(28'h06C, 32'h0000C000 | WAVE_N, 4'h3);  // len flag + restart
        repeat (131072) @(posedge clk);
        if (!dut.igba_sound_ch2.ch_on) begin
            $display("FAIL: ch2 length expired before 2 ticks (131072 clk)");
            errors = errors + 1;
        end
        repeat (400000 - 131072) @(posedge clk);
        if (dut.igba_sound_ch2.ch_on) begin
            $display("FAIL: ch2 length not expired after 400000 clk");
            errors = errors + 1;
        end
        $display("ch2 length: on at 131072 clk, off by 400000 clk (4x65536)");

        if (errors == 0)
            $display("tb_audio_hold: PASS");
        else
            $display("tb_audio_hold: FAIL errors=%0d", errors);
        $finish;
    end

    // tick generator: only while ce=1 once DMA is active (models the frozen
    // gba_timer); refill model: one dword per dma_req pulse, never when full.
    // (Refill owns the bus only while refill_en; the bus_write task owns it
    // otherwise.)
    always @(posedge clk) begin
        timer0_tick <= 0;
        if (!reset && dma_active && ce) begin
            tick_phase <= tick_phase + 1;
            if (tick_phase == TICK_EVERY - 1) begin
                tick_phase <= 0;
                timer0_tick <= 1;
                ticks_issued <= ticks_issued + 1;
            end
        end
        if (refill_en && !reset && sound_dma_req[0]) begin
            if (debug_fifocount >= 7)
                lost_writes <= lost_writes + 1;
            else begin
                gb_bus_adr <= 28'h0A0; gb_bus_din <= wdata;
                gb_bus_rnw <= 0; gb_bus_be <= 4'hF; gb_bus_acc <= 2'b10;
                gb_bus_ena <= 1;
                wdata <= wdata + 32'h04040404;
                dwords_written <= dwords_written + 1;
            end
        end else if (refill_en)
            gb_bus_ena <= 0;
    end

    // watchdog
    initial begin
        #(CLK16H * 2 * (FREE_CLKS + NFRAMES * (FRAME + 20000) * 2 + 8000000));
        $display("tb_audio_hold: FAIL (watchdog)");
        $finish;
    end

endmodule
