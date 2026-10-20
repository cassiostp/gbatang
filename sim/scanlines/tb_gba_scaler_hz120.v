// gba2hdmi (the BRAM framebuffer build, Tang Console 138K) with scanlines, whole frames:
// the HDMI part, the PLL and the frame buffer RAM are stubs (hdmi_stub.v, gba_stubs.v),
// the picture is the scaler's rgb output.
// Checks, for each setting, every output row of the frame against the model of
// src/scanlines.v: which source line it shows, border rows, dark rows and the darkened
// colour; and the horizontal extent of the picture.
// Then the BFI modes (video_config[21:20]): lit/inserted alternation, black
// inserted frames, the Lottes bright/beam pair with exact per-pixel checks
// against sim/scanlines/bfi_lottes.hex (verified against tools/bfi_lottes.py),
// the overlay exempt, and one retention phase swap (forced counter)
// alternating the duplicate.
// Fails with $fatal on the first mismatch.
`timescale 1ns/1ps

module tb_gba_scaler;

    reg clk = 0, clk27 = 0;
    always #10 clk = ~clk;                      // 50 MHz
    always #18.5 clk27 = ~clk27;

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    reg [31:0] vcfg = 0;
    wire [10:0] overlay_x;
    wire  [9:0] overlay_y;
    reg  [15:0] overlay_color = 16'b0_10101_01010_11100;   // BGR5
    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;
    wire       clk_pixel;

    gba2hdmi dut (
        .clk(clk), .clk27(clk27), .resetn(1'b1), .clk_pixel(clk_pixel),
        .pixel_data(18'd0), .pixel_x(8'd0), .pixel_y(8'd0), .pixel_we(1'b0),
        .sound_left(16'd0), .sound_right(16'd0),
        .overlay(ov), .overlay_x(overlay_x), .overlay_y(overlay_y), .overlay_color(overlay_color),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out), .video_config(vcfg),
        .std_timing(1'b0),      // native GBA rate x2
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // what the HDMI sink would show: rgb while cx = x + 1
    reg [23:0] img [0:720*480-1];
    always @(posedge clk_pixel)
        if (dut.cy < 10'd480 && dut.cx >= 11'd1 && dut.cx <= 11'd720)
            img[dut.cy * 720 + dut.cx - 1] = dut.rgb;

    localparam BORDER = 24'h303030;
    localparam R = 3, LINES = 160, TOP = 0, GEOM_W = 720, FULL_W = 720;

    // source picture: line l (0..159) has colour src_color(l) (RGB6), or, when loaded by
    // column, column c has colour col_color(c)
    function [17:0] src_color(input integer l);
        reg [5:0] a, b, c;
        begin
            a = 8 + (l * 5) % 47; b = 8 + (l * 7) % 43; c = 8 + (l * 3) % 41;
            src_color = {a, b, c};
        end
    endfunction
    function [17:0] col_color(input integer n);
        reg [5:0] a, b, c;
        begin
            a = 8 + (n % 12) * 3; b = 40 - (n % 12); c = 12 + (n % 5) * 4;
            col_color = {a, b, c};
        end
    endfunction
    function [23:0] to_rgb(input [17:0] p);       // as in gba2hdmi: RGB6 to RGB8
        to_rgb = {p[17:12], 2'b0, p[11:6], 2'b0, p[5:0], 2'b0};
    endfunction
    function [23:0] overlay_rgb(input [14:0] o);
        overlay_rgb = {o[4:0], 3'b0, o[9:5], 3'b0, o[14:10], 3'b0};
    endfunction
    function [23:0] half_rgb(input [23:0] p);      // BFI dim: every channel halved
        half_rgb = {1'b0, p[23:17], 1'b0, p[15:9], 1'b0, p[7:1]};
    endfunction

    task load_rows;
        integer l, c, i;
        begin
            for (l = 0; l < 160; l = l + 1)
                for (c = 0; c < 240; c = c + 1)
                    dut.u_fb.m[l * 240 + c] = src_color(l);
            // the stub RAM beyond the picture is zeroed so an out-of-range
            // read (xx overshoot on the last column) cannot poison the frame
            // with X
            for (i = 38400; i < 65536; i = i + 1)
                dut.u_fb.m[i] = 18'd0;
        end
    endtask
    task load_columns;
        integer l, c, i;
        begin
            for (l = 0; l < 160; l = l + 1)
                for (c = 0; c < 240; c = c + 1)
                    dut.u_fb.m[l * 240 + c] = col_color(c);
            for (i = 38400; i < 65536; i = i + 1)
                dut.u_fb.m[i] = 18'd0;
        end
    endtask

    function [7:0] dim8(input [7:0] v, input [1:0] d);
        case (d)
        0: dim8 = v - v / 4;
        1: dim8 = v / 2;
        2: dim8 = v / 4;
        default: dim8 = 0;
        endcase
    endfunction

    function [23:0] darken(input [23:0] p, input [1:0] d);
        darken = {dim8(p[23:16], d), dim8(p[15:8], d), dim8(p[7:0], d)};
    endfunction

    // 160 lines: 3 rows per source line with scanlines (480 rows, no border),
    // 3 rows per line without too (160 x 3 = 480 exactly)
    reg cur_geom;
    function integer exp_line(input integer row);     // -1 for a border row
        begin
            // the integer scale is exact, so the fractional counter and the
            // integer geometry agree: every 3 rows are one source line
            exp_line = row / 3;
        end
    endfunction

    // wait for the end of the frame drawn with the new settings: img holds it when this
    // returns (in the blanking after row 480). Called right after the previous check, the
    // next frame is the first with the new settings; at the start it takes one more.
    integer settle_frames = 2;
    task settle;
        begin
            repeat (settle_frames) begin
                while (dut.cy != 10'd521) @(posedge clk_pixel);
                while (dut.cy == 10'd521) @(posedge clk_pixel);
            end
            settle_frames = 1;
        end
    endtask

    task fail(input [8*60-1:0] what, input integer row, input [23:0] got, input [23:0] want);
        begin
            $display("FAIL: %0s at row %0d: got %h, want %h (on=%b out=%b thick=%b dark=%0d ov=%b)",
                     what, row, got, want, sl_on, sl_out, sl_thick, sl_dark, ov);
            $fatal(1, "tb_gba_scaler: FAIL");
        end
    endtask

    integer row, line, nd, XP, x, first, last, runs, runlen, minrun, maxrun, w, pw, ptop;
    reg [23:0] want, got, prev;

    // the picture is full-bleed 720 wide: no borders unless the overlay is up
    // (640 wide, centred: x 40..679)
    task check_rows(input on, input out, input thick, input [1:0] dk, input over);
        begin
            nd = thick ? 2 : 1;
            ptop = cur_geom ? TOP : 0;
            XP = 360;
            for (row = 0; row < 480; row = row + 1) begin
                got = img[row * 720 + XP];
                line = exp_line(row);
                if (over)
                    want = overlay_rgb(overlay_color[14:0]);
                else if (line < 0)
                    want = BORDER;
                else begin
                    want = to_rgb(src_color(line));
                    if (cur_geom ? ((row - ptop) % R >= R - nd) : (on & out & ((row % R) >= R - nd)))
                        want = darken(want, dk);
                end
                if (got !== want) fail("picture", row, got, want);
                if (over) begin
                    if (img[row * 720 + 5] !== BORDER) fail("left border", row, img[row * 720 + 5], BORDER);
                    if (img[row * 720 + 714] !== BORDER) fail("right border", row, img[row * 720 + 714], BORDER);
                end else begin
                    if (img[row * 720 + 0] !== want) fail("left edge", row, img[row * 720 + 0], want);
                    if (img[row * 720 + 719] !== want) fail("right edge", row, img[row * 720 + 719], want);
                end
            end
        end
    endtask

    // horizontal extent and pixel widths on a row through the middle of the picture
    task check_columns;
        begin
            pw = cur_geom ? GEOM_W : FULL_W;
            row = 240;
            first = -1; last = -1; runs = 0; minrun = 99; maxrun = 0; runlen = 0; prev = BORDER;
            for (x = 0; x < 720; x = x + 1) begin
                got = img[row * 720 + x];
                if (got !== BORDER) begin
                    if (first < 0) first = x;
                    last = x;
                    if (got !== prev) begin
                        if (runs > 0) begin
                            if (runlen < minrun) minrun = runlen;
                            if (runlen > maxrun) maxrun = runlen;
                        end
                        runs = runs + 1; runlen = 0;
                    end
                    runlen = runlen + 1;
                end
                prev = got;
            end
            w = last - first + 1;
            if (first !== (720 - pw) / 2 || w !== pw) begin
                $display("FAIL: picture spans x=%0d..%0d (width %0d), want %0d..%0d (geom=%b)", first, last, w, (720 - pw) / 2, (720 + pw) / 2 - 1, cur_geom);
                $fatal(1, "tb_gba_scaler: FAIL");
            end
            if (runs !== 240) begin
                $display("FAIL: %0d source columns on the row, want 240", runs);
                $fatal(1, "tb_gba_scaler: FAIL");
            end
            if (minrun < (pw / 240) || maxrun > (pw + 239) / 240) begin
                $display("FAIL: pixel widths %0d..%0d, want %0d..%0d", minrun, maxrun, pw / 240, (pw + 239) / 240);
                $fatal(1, "tb_gba_scaler: FAIL");
            end
        end
    endtask

    task set(input on, input out, input thick, input [1:0] dk, input over);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over;
            cur_geom = on & ~out & ~over;
            settle;
        end
    endtask

    task run(input on, input out, input thick, input [1:0] dk, input over);
        begin
            set(on, out, thick, dk, over);
            check_rows(on, out, thick, dk, over);
            $display("gba2hdmi on=%b out=%b thick=%b darkness=%0d overlay=%b: ok", on, out, thick, dk, over);
        end
    endtask

    task columns(input on, input out);
        begin
            set(on, out, 0, 2, 0);
            check_columns;
            $display("gba2hdmi columns on=%b out=%b: ok", on, out);
        end
    endtask

    // BFI: sample dut.rgb at the picture centre (cy 240, cx 361: source line 80)
    // in a chosen frame parity. Assumes scanlines off and no colour FX.
    // Modes 2/3 (Lottes HI/LO) exact checks: the expected HI/LO pair comes
    // from bfi_lottes.hex ("HHLL" per input code) indexed by the known
    // static stimulus colour, with the HI side from dut.bfi_phase
    // (no swap runs inside the bench).
    reg [15:0] HEXRAW [0:255];
    reg [7:0] THI [0:255];
    reg [7:0] TLO [0:255];
    initial begin : load_hex
        integer ci;
        $readmemh("bfi_lottes.hex", HEXRAW);
        for (ci = 0; ci < 256; ci = ci + 1) begin
            THI[ci] = HEXRAW[ci][15:8]; TLO[ci] = HEXRAW[ci][7:0];
        end
    end
    // Frame dumps for the report: the settled img as PPM (P3 ASCII).
    task dump_ppm(input [8*64-1:0] path);
        integer fd, dx, dy;
        begin
            fd = $fopen(path, "w");
            $fwrite(fd, "P3\n720 480\n255\n");
            for (dy = 0; dy < 480; dy = dy + 1)
                for (dx = 0; dx < 720; dx = dx + 1)
                    $fwrite(fd, "%0d %0d %0d\n",
                        img[dy * 720 + dx][23:16], img[dy * 720 + dx][15:8], img[dy * 720 + dx][7:0]);
            $fclose(fd);
            $display("gba2hdmi dumped %0s", path);
        end
    endtask
    task sample_frame(input ins, output [23:0] rgb);
        begin
            do begin
                @(posedge clk_pixel);
            end while (!(dut.cy == 10'd240 && dut.cx == 11'd361 && dut.bfi_ins == ins));
            rgb = dut.rgb;
        end
    endtask
    // sample_at(cy_want, ins, rgb, eff): dut.rgb at (cy_want, cx 361) on the
    // next frame with bfi_ins == ins; eff is the effective (phase-applied)
    // inserted flag for the expectation below.
    task sample_at(input [9:0] cy_want, input ins, output [23:0] rgb, output eff);
        begin
            do begin
                @(posedge clk_pixel);
            end while (!(dut.cy == cy_want && dut.cx == 11'd361 && dut.bfi_ins == ins));
            rgb = dut.rgb;
            eff = ins ^ dut.bfi_phase;
        end
    endtask
    // expected Lottes side for sample_at: mode 2 shows HI on lit refreshes
    // everywhere; mode 3 flips the parity per half (split at cy 240).
    function [23:0] want_side(input [23:0] lit, input eff, input [1:0] mode, input [9:0] cy_want);
        reg [23:0] hi, lo;
        reg show;
        begin
            hi = {THI[lit[23:16]], THI[lit[15:8]], THI[lit[7:0]]};
            lo = {TLO[lit[23:16]], TLO[lit[15:8]], TLO[lit[7:0]]};
            show = ~eff ^ ((mode == 2'd3) & (cy_want >= 10'd240));
            want_side = show ? hi : lo;
        end
    endfunction

    task bfi_fail(input [8*60-1:0] what, input [23:0] got, input [23:0] want);
        begin
            $display("FAIL: %0s: got %h, want %h (bfi_mode=%b)", what, got, want, vcfg[21:20]);
            $fatal(1, "tb_gba_scaler: FAIL");
        end
    endtask

    // set the BFI mode in the blanking so the next frame is stable throughout
    task set_bfi(input [1:0] mode);
        begin
            while (dut.cy < 10'd500) @(posedge clk_pixel);
            vcfg[21:20] = mode;
            settle_frames = 1;
            settle;
        end
    endtask

    reg [23:0] lit_rgb, ins_rgb;
    reg [23:0] want_lit;

    initial begin
        cur_geom = 0;
        #1;
        load_rows;
        // by row: the vertical geometry and the darkening
        run(0, 0, 0, 2, 0);                     // off: 3 rows per line, full frame
        run(1, 0, 0, 2, 0);                     // the default: integer, thin, 75 %
        run(1, 0, 1, 0, 0);
        run(1, 0, 0, 1, 0);
        run(1, 0, 1, 3, 0);
        run(1, 1, 0, 2, 0);                     // output rows
        run(1, 1, 1, 1, 0);
        run(1, 0, 0, 2, 1);                     // menu up: the overlay is left alone
        run(1, 1, 1, 2, 1);
        run(1, 0, 1, 2, 0);                     // and back
        // by column: the horizontal geometry (240 columns x 3 = 720)
        load_columns;
        columns(0, 0); columns(1, 0); columns(1, 1);
        // BFI modes, scanlines off for exact pixel values
        load_rows;
        set(0, 0, 0, 2, 0);
        want_lit = to_rgb(src_color(80));
        set_bfi(2'd0);                          // off: both frames lit
        sample_frame(1'b0, lit_rgb);
        if (lit_rgb !== want_lit) bfi_fail("mode 0 lit", lit_rgb, want_lit);
        sample_frame(1'b1, ins_rgb);
        if (ins_rgb !== want_lit) bfi_fail("mode 0 inserted", ins_rgb, want_lit);
        $display("gba2hdmi BFI mode 0 (both lit): ok");
        set_bfi(2'd1);                          // black inserted frame
        sample_frame(1'b0, lit_rgb);
        if (lit_rgb !== want_lit) bfi_fail("mode 1 lit", lit_rgb, want_lit);
        sample_frame(1'b1, ins_rgb);
        if (ins_rgb !== 24'h000000) bfi_fail("mode 1 inserted", ins_rgb, 24'h000000);
        $display("gba2hdmi BFI mode 1 (black): ok");
        // Modes 2 (bright) / 3 (beam): exact Lottes HI/LO values at a top
        // row (cy 100: source line 33) and a bottom row (cy 301: source
        // line 100), both parities, plus same-parity repeats (static
        // stimulus: identical two frames apart). want_side encodes the
        // mode's parity (global for mode 2, flipped per half for mode 3),
        // so these six exact checks prove the flip; both rows are
        // discriminating (HI != LO) by construction of the stimulus.
        begin : bright_beam
            reg [23:0] s0, s1, s0b, s1b, rpt, wlit, wwant;
            reg e0, e1;
            integer m;
            for (m = 2; m <= 3; m = m + 1) begin
                set_bfi(m[1:0]);
                // top half
                wlit = to_rgb(src_color(33));
                sample_at(10'd100, 1'b0, s0, e0);
                wwant = want_side(wlit, e0, m[1:0], 10'd100);
                if (s0 !== wwant) bfi_fail("mode top lit", s0, wwant);
                sample_at(10'd100, 1'b1, s1, e1);
                wwant = want_side(wlit, e1, m[1:0], 10'd100);
                if (s1 !== wwant) bfi_fail("mode top inserted", s1, wwant);
                sample_at(10'd100, 1'b0, rpt, e0);
                if (rpt !== s0) bfi_fail("mode top lit repeat", rpt, s0);
                // bottom half
                wlit = to_rgb(src_color(100));
                sample_at(10'd301, 1'b0, s0b, e0);
                wwant = want_side(wlit, e0, m[1:0], 10'd301);
                if (s0b !== wwant) bfi_fail("mode bottom lit", s0b, wwant);
                sample_at(10'd301, 1'b1, s1b, e1);
                wwant = want_side(wlit, e1, m[1:0], 10'd301);
                if (s1b !== wwant) bfi_fail("mode bottom inserted", s1b, wwant);
                sample_at(10'd301, 1'b1, rpt, e1);
                if (rpt !== s1b) bfi_fail("mode bottom inserted repeat", rpt, s1b);
                $display("gba2hdmi BFI mode %0d (bright/beam exact, top+bottom): ok", m);
            end
        end
        // the overlay stays lit under BFI
        ov = 1;
        set_bfi(2'd1);
        sample_frame(1'b1, ins_rgb);
        if (ins_rgb !== overlay_rgb(overlay_color[14:0])) bfi_fail("overlay under BFI", ins_rgb, overlay_rgb(overlay_color[14:0]));
        sample_frame(1'b0, lit_rgb);
        if (lit_rgb !== overlay_rgb(overlay_color[14:0])) bfi_fail("overlay lit frame", lit_rgb, overlay_rgb(overlay_color[14:0]));
        ov = 0;
        $display("gba2hdmi BFI overlay exempt: ok");
        // retention phase swap: deposit the counter near the end and watch the
        // duplicate alternate (a force would hold it; a deposit lets it run)
        set_bfi(2'd1);
        dut.bfi_swap_cnt = 16'd1797;
        begin
            integer f, eff_seq[0:9];
            for (f = 0; f < 10; f = f + 1) begin
                do begin
                    @(posedge clk_pixel);
                end while (!(dut.cy == 10'd240 && dut.cx == 11'd361));
                eff_seq[f] = dut.bfi_ins ^ dut.bfi_phase;
            end
            // exactly one duplicate pair (the swap), strict alternation elsewhere
            begin
                integer d, dup;
                dup = -1;
                for (d = 0; d < 9; d = d + 1)
                    if (eff_seq[d] == eff_seq[d+1]) begin
                        if (dup != -1) begin
                            $display("FAIL: two swap duplicates in 10 frames");
                            $fatal(1, "tb_gba_scaler: FAIL");
                        end
                        dup = d;
                    end
                if (dup == -1) begin
                    $display("FAIL: no swap duplicate in 10 frames");
                    $fatal(1, "tb_gba_scaler: FAIL");
                end
                $display("swap eff sequence: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d (dup at +%0d)",
                         eff_seq[0], eff_seq[1], eff_seq[2], eff_seq[3], eff_seq[4],
                         eff_seq[5], eff_seq[6], eff_seq[7], eff_seq[8], eff_seq[9], dup);
                $display("gba2hdmi BFI phase swap duplicate: ok");
            end
        end
        // frame dumps for the report (full-bleed 3x; Full and Integer are
        // the same geometry at 480p)
        load_rows;
        set(1, 0, 0, 2, 0);
        set_bfi(2'd0);
        dump_ppm("frame_game.ppm");
        set(0, 0, 0, 2, 0);
        dump_ppm("frame_game_nosl.ppm");
        set(1, 1, 0, 2, 0);
        dump_ppm("frame_game_full.ppm");
        ov = 1;
        set_bfi(2'd1);
        dump_ppm("frame_osd.ppm");
        ov = 0;
        $display("tb_gba_scaler: PASS");
        $finish;
    end

    initial begin
        #4000000000;
        $fatal(1, "tb_gba_scaler: timeout");
    end
endmodule
