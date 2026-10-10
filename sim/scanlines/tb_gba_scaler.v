// gba2hdmi (the BRAM framebuffer build, Tang Console 138K) with scanlines, whole frames:
// the HDMI part, the PLL and the frame buffer RAM are stubs (hdmi_stub.v, gba_stubs.v),
// the picture is the scaler's rgb output.
// Checks, for each setting, every output row of the frame against the model of
// src/scanlines.v: which source line it shows, border rows, dark rows and the darkened
// colour; and the horizontal extent of the picture.
// Fails with $fatal on the first mismatch.
`timescale 1ns/1ps

module tb_gba_scaler;

    reg clk = 0, clk27 = 0;
    always #10 clk = ~clk;                      // 50 MHz
    always #18.5 clk27 = ~clk27;

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
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
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out), .video_config(32'd0),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    // what the HDMI sink would show: rgb while cx = x + 1
    reg [23:0] img [0:1280*720-1];
    always @(posedge clk_pixel)
        if (dut.cy < 10'd720 && dut.cx >= 11'd1 && dut.cx <= 11'd1280)
            img[dut.cy * 1280 + dut.cx - 1] = dut.rgb;

    localparam BORDER = 24'h303030;
    localparam R = 4, LINES = 160, TOP = 40, GEOM_W = 960, FULL_W = 1080;

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

    task load_rows;
        integer l, c;
        begin
            for (l = 0; l < 160; l = l + 1)
                for (c = 0; c < 240; c = c + 1)
                    dut.u_fb.m[l * 240 + c] = src_color(l);
        end
    endtask
    task load_columns;
        integer l, c;
        begin
            for (l = 0; l < 160; l = l + 1)
                for (c = 0; c < 240; c = c + 1)
                    dut.u_fb.m[l * 240 + c] = col_color(c);
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

    // 160 lines: 4 rows each with scanlines (640 rows, 40 border rows above and below),
    // 4 or 5 without (the old scale)
    reg cur_geom;
    function integer exp_line(input integer row);     // -1 for a border row
        begin
            if (cur_geom)
                exp_line = (row < TOP || row >= TOP + R * LINES) ? -1 : (row - TOP) / R;
            else
                exp_line = row * LINES / 720;
        end
    endfunction

    // wait for the end of the frame drawn with the new settings: img holds it when this
    // returns (in the blanking at row 726). Called right after the previous check, the
    // next frame is the first with the new settings; at the start it takes one more.
    integer settle_frames = 2;
    task settle;
        begin
            repeat (settle_frames) begin
                while (dut.cy != 10'd725) @(posedge clk_pixel);
                while (dut.cy == 10'd725) @(posedge clk_pixel);
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

    task check_rows(input on, input out, input thick, input [1:0] dk, input over);
        begin
            nd = thick ? 2 : 1;
            ptop = cur_geom ? TOP : 0;
            XP = 640;
            for (row = 0; row < 720; row = row + 1) begin
                got = img[row * 1280 + XP];
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
                if (img[row * 1280 + 50] !== BORDER) fail("left border", row, img[row * 1280 + 50], BORDER);
                if (img[row * 1280 + 1250] !== BORDER) fail("right border", row, img[row * 1280 + 1250], BORDER);
            end
        end
    endtask

    // horizontal extent and pixel widths on a row through the middle of the picture
    task check_columns;
        begin
            pw = cur_geom ? GEOM_W : FULL_W;
            row = 360;
            first = -1; last = -1; runs = 0; minrun = 99; maxrun = 0; runlen = 0; prev = BORDER;
            for (x = 0; x < 1280; x = x + 1) begin
                got = img[row * 1280 + x];
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
            if (first !== (1280 - pw) / 2 || w !== pw) begin
                $display("FAIL: picture spans x=%0d..%0d (width %0d), want %0d..%0d (geom=%b)", first, last, w, (1280 - pw) / 2, (1280 + pw) / 2 - 1, cur_geom);
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

    initial begin
        cur_geom = 0;
        #1;
        load_rows;
        // by row: the vertical geometry and the darkening
        run(0, 0, 0, 2, 0);                     // off: the old geometry
        run(1, 0, 0, 2, 0);                     // the default: integer, thin, 75 %
        run(1, 0, 1, 0, 0);
        run(1, 0, 0, 1, 0);
        run(1, 0, 1, 3, 0);
        run(1, 1, 0, 2, 0);                     // output rows
        run(1, 1, 1, 1, 0);
        run(1, 0, 0, 2, 1);                     // menu up: the overlay is left alone
        run(1, 1, 1, 2, 1);
        run(1, 0, 1, 2, 0);                     // and back
        // by column: the horizontal geometry
        load_columns;
        columns(0, 0); columns(1, 0); columns(1, 1);
        $display("tb_gba_scaler: PASS");
        $finish;
    end

    initial begin
        #4000000000;
        $fatal(1, "tb_gba_scaler: timeout");
    end
endmodule
