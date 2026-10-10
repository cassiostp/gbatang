// The filters running inside gba2hdmi. For a list of settings, the pixels that go into video_fx
// (rgb_pre and its flags) and the pixels that come out, FX_LAT clocks later, are logged with
// the output position, on a set of rows across the frame; model.py check compares each one with
// the golden model, so the CRT mask lands on the right output columns and rows, the scanline
// darkening comes after the colour, the LCD grid darkens the last column and row of every
// source pixel and line, and the border and the overlay are left alone.
// Also checked here on every clock: the picture flag is set exactly for the pixels that are not
// the border colour, and never while the overlay is up; with the integer geometry every source
// pixel spans exactly 4 output columns; the grid column flag fires exactly on the last one;
// and with the grid on and the scanlines off the scanline darkening is not applied.
`timescale 1ns/1ps

module tb_gba_fx;

    localparam FX_LAT = 11;

    reg clk = 0, clk27 = 0;
    always #10 clk = ~clk;                      // 50 MHz
    always #18.5 clk27 = ~clk27;
    wire clk_pixel;

    reg        sl_on = 0, sl_thick = 0, sl_out = 0, ov = 0;
    reg  [1:0] sl_dark = 0;
    reg [31:0] vcfg = 0;

    wire [10:0] ovx;
    wire [9:0] ovy;
    reg [15:0] ovc, ovc1;
    function [14:0] ov_pix(input [7:0] x, input [7:0] y);
        ov_pix = {x[4:0] ^ y[6:2], x[7:3] + y[4:0], y[7:3] ^ x[6:2]} | 15'h4000;   // never the border
    endfunction
    always @(posedge clk_pixel) begin
        ovc1 <= {1'b0, ov_pix(ovx[7:0], ovy[7:0])}; ovc <= ovc1;
    end

    wire [2:0] tmds_d_p, tmds_d_n;
    wire       tmds_clk_p, tmds_clk_n;

    gba2hdmi dut (
        .clk(clk), .clk27(clk27), .resetn(1'b1), .clk_pixel(clk_pixel),
        .pixel_data(18'd0), .pixel_x(8'd0), .pixel_y(8'd0), .pixel_we(1'b0),
        .sound_left(16'd0), .sound_right(16'd0),
        .overlay(ov), .overlay_x(ovx), .overlay_y(ovy), .overlay_color(ovc),
        .scanlines(sl_on), .sl_darkness(sl_dark), .sl_thick(sl_thick), .sl_out(sl_out),
        .video_config(vcfg),
        .tmds_clk_n(tmds_clk_n), .tmds_clk_p(tmds_clk_p), .tmds_d_n(tmds_d_n), .tmds_d_p(tmds_d_p)
    );

    integer i;
    reg [31:0] h;
    initial begin
        #1;
        h = 32'h7654321;
        for (i = 0; i < 240 * 160; i = i + 1) begin
            h = h * 1664525 + 1013904223;
            dut.u_fb.m[i] = h[23:6];
        end
    end

    // what went into video_fx FX_LAT clocks ago: {darkness, row_last, col_last, dark, pic, rgb}
    reg [29:0] hist [0:15];
    reg [29:0] now_in, old_in;
    integer logging = 0, checking = 0, expect_no_sldark = 0, nlog = 0, nbad_pic = 0, nbad_grid = 0, k;
    integer fd;
    reg     in_row;
    // the integer geometry: clocks between source pixel columns, and the column flag history
    integer cyc = 0;
    reg [7:0] xx_r = 0, xx_d1 = 0, xx_d2 = 0;
    reg col_now;
    always @(negedge clk_pixel) begin
        now_in = {dut.sl_dk, dut.fx.row_last_in, dut.fx.col_last_in, dut.dark_pre, dut.pic_pre, dut.rgb_pre};
        old_in = hist[FX_LAT - 1];
        for (k = 15; k > 0; k = k - 1) hist[k] = hist[k - 1];
        hist[0] = now_in;
        // the border colour and the picture flag
        if (logging && dut.pic_pre !== (dut.rgb_pre !== 24'h303030 && !ov)) begin
            nbad_pic = nbad_pic + 1;
            if (nbad_pic <= 5)
                $display("pic flag %b with rgb_pre=%h overlay=%b at cx=%0d cy=%0d", dut.pic_pre, dut.rgb_pre, ov, dut.cx, dut.cy);
        end
        // the grid with the scanlines off: no scanline darkening at all
        if (checking && expect_no_sldark && (dut.sl_dark !== 1'b0 || dut.dark_pre !== 1'b0)) begin
            nbad_grid = nbad_grid + 1;
            if (nbad_grid <= 5)
                $display("scanline darkening with grid on, scanlines off at cx=%0d cy=%0d", dut.cx, dut.cy);
        end
        // the integer geometry: each source pixel is 4 output columns, the column flag is
        // the last of them (the flag trails the xx step by the 2 buffer/rgb_pre stages)
        col_now = dut.fx.col_last_in;
        if (checking && dut.sl_geom && !ov && !$isunknown({col_now, xx_d1, xx_d2}) && dut.active) begin
            cyc = cyc + 1;
            if (!$isunknown(dut.xx) && !$isunknown(xx_r) && dut.xx !== xx_r) begin
                if (cyc !== 4) begin
                    nbad_grid = nbad_grid + 1;
                    if (nbad_grid <= 5)
                        $display("source pixel %0d columns wide at cx=%0d cy=%0d", cyc, dut.cx, dut.cy);
                end
                cyc = 0;
            end
            if (col_now !== (xx_d1 != xx_d2)) begin
                nbad_grid = nbad_grid + 1;
                if (nbad_grid <= 5)
                    $display("column flag %b off the pixel edge at cx=%0d cy=%0d", col_now, dut.cx, dut.cy);
            end
        end else begin
            cyc = 0;
        end
        xx_d2 = xx_d1; xx_d1 = xx_r; xx_r = dut.xx;
        in_row = (dut.cy % 100 < 4) && dut.cy < 10'd720 && dut.cy >= 10'd40;
        if (logging && in_row && dut.cx < 11'd1280) begin
            $fwrite(fd, "%h %0d %0d %0d %0d %0d %0d %0d %h %h\n", vcfg, dut.cx, dut.cy,
                    old_in[24], old_in[25], old_in[29:28], old_in[26], old_in[27], old_in[23:0], dut.rgb);
            nlog = nlog + 1;
        end
    end

    task wait_row730;
        begin
            while (dut.cy == 10'd730) @(posedge clk_pixel);
            while (dut.cy != 10'd730) @(posedge clk_pixel);
        end
    endtask

    // one frame with these settings, logged and grid-checked
    task frame(input on, input out, input thick, input [1:0] dk, input over, input [31:0] cfg, input no_sldark);
        begin
            sl_on = on; sl_out = out; sl_thick = thick; sl_dark = dk; ov = over; vcfg = cfg;
            expect_no_sldark = 0;
            wait_row730;
            logging = 1; checking = 1; expect_no_sldark = no_sldark;
            wait_row730;
            logging = 0; checking = 0; expect_no_sldark = 0;
            $display("gba_fx on=%b out=%b thick=%b darkness=%0d overlay=%b video_config=%h logged", on, out, thick, dk, over, cfg);
        end
    endtask

    localparam [31:0] GRID_ONLY = 32'h0002_8000;   // LCD grid, strength 3/8, nothing else

    initial begin
        fd = $fopen("gba_fx.log", "w");
        wait_row730;
        //    on out thk dk ov  video_config
        frame(0, 0, 0, 0, 0, 3'd2 | (3'd7 << 3) | (3'd2 << 6) | (2'd3 << 9), 0);   // colour only
        frame(0, 0, 0, 0, 0, (2'd1 << 11) | (2'd2 << 13), 0);                      // aperture grille
        frame(1, 0, 0, 1, 0, (2'd2 << 11) | (2'd3 << 13), 0);                      // slot mask + scanlines
        frame(1, 1, 1, 2, 0, (2'd3 << 11) | (2'd1 << 13) | 3'd5, 0);               // dot mask, output rows, brightness -3
        frame(1, 0, 0, 3, 0, (3'd4 << 6) | (2'd1 << 9) | (2'd1 << 11), 0);         // greyscale + gamma + 100 % scanlines
        frame(0, 0, 0, 0, 1, 32'h0001_FFFF, 0);                                    // overlay: untouched
        frame(0, 0, 0, 0, 0, GRID_ONLY, 1);                                       // LCD grid, scanlines off
        frame(1, 0, 1, 2, 0, GRID_ONLY | 3'd1 | (3'd3 << 3), 0);                  // LCD grid + scanlines, thick
        frame(0, 0, 0, 0, 0, 32'h0001_2000, 0);                                    // firmware "off"
        $fclose(fd);
        if (nbad_pic != 0 || nbad_grid != 0 || nlog == 0) begin
            $display("tb_gba_fx: FAIL (%0d picture flag errors, %0d grid errors, %0d pixels logged)", nbad_pic, nbad_grid, nlog);
            $fatal(1, "tb_gba_fx: FAIL");
        end
        $display("tb_gba_fx: %0d pixels logged, picture flag and grid ok", nlog);
        $finish;
    end

    initial begin
        #2000000000000;
        $fatal(1, "tb_gba_fx: timeout");
    end
endmodule
