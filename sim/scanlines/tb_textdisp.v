// textdisp at 480p overlay holds (iverilog): the OSD glyph fix.
//
// At 640 px wide each overlay pixel holds for only 2-3 HDMI clocks
// (640/256 = 2.5), so by the time the font byte arrives (MAIN->FETCH->OUTPUT,
// 2 clocks) the live x has already advanced to the neighbour pixel. The fix
// latches the font bit offset at fetch time (font_xoff). This bench drives x
// with 3,2,3,2... holds like the 640-wide overlay, with a single-bit font
// (only bit 2 set), and checks every output clock against an independent
// model of the latch. Pixels whose latched offset is 2 must read TEXT,
// pixels whose offset is 0 must read BACK (the live-x bug selects bit 2
// there); the other offsets read BACK either way.
// Fails with $fatal on the first mismatch.
`timescale 1ns/1ps

// Bench-only stand-in for gowin_dpb_menu: byte-wide dual-port RAM, one clock
// of read latency on port B, with a backdoor for the font area (port A can
// only address the char/logo half, like the real initialisation).
module gowin_dpb_menu(douta, doutb, clka, ocea, cea, reseta, wrea, clkb, oceb, ceb, resetb, wreb, ada, dina, adb, dinb);
    output reg [7:0] douta;
    output reg [7:0] doutb;
    input clka, ocea, cea, reseta, wrea, clkb, oceb, ceb, resetb, wreb;
    input [10:0] ada;
    input [7:0] dina;
    input [10:0] adb;
    input [7:0] dinb;
    reg [7:0] m [0:2047];
    always @(posedge clka) if (wrea) m[ada] <= dina;
    always @(posedge clkb) doutb <= m[adb];
endmodule

module tb_textdisp;
    reg hclk = 0;
    always #9.2593 hclk = ~hclk;                // 54 MHz pixel clock

    reg [7:0] x = 0;
    reg [7:0] y = 8'd4;
    wire [14:0] color;
    reg [3:0] reg_char_we = 0;
    reg [31:0] reg_char_di = 0;

    textdisp dut (
        .clk(1'b0), .hclk(hclk), .resetn(1'b1),
        .x(x), .y(y), .color(color),
        .reg_char_we(reg_char_we), .reg_char_di(reg_char_di)
    );

    // font: char 2 is all bit-2 (8'h04); everything else 0
    integer i;
    initial begin
        #1;
        for (i = 0; i < 2048; i = i + 1)
            dut.menu_mem.m[i] = 8'd0;
        for (i = 0; i < 8; i = i + 1)
            dut.menu_mem.m[1024 + 2 * 8 + i] = 8'h04;
        // char row 0: all char 2 (not the cursor column: x[7:3] != 0)
        for (i = 0; i < 32; i = i + 1)
            dut.menu_mem.m[i] = 8'd2;
        // Gowin powers up 0; force the same (no reset in the DUT)
        dut.state = 0;
        dut.color_buf = BACK;
        dut.x_r = 0;
        dut.is_cursor = 0;
        dut.logo_active = 0;
        dut.logo_xoff = 0;
        dut.font_xoff = 0;
        dut.logo_addr = 0;
    end

    localparam [14:0] BACK = 15'b00000_00000_00000;
    localparam [14:0] TEXT = 15'b10000_11111_11111;

    // x driver: 640-wide overlay holds, 3,2,3,2... (256 pixels per 640 clocks)
    // The model mirrors the DUT pipeline: an advance is visible at the output
    // two clocks later (MAIN->FETCH->OUTPUT; the bench samples post-NBA
    // values in iverilog). Calibrated against the DUT trace; the negative
    // control (unfixed textdisp) must fail.
    integer hold = 3, hold_n = 0;
    reg [2:0] last_xoff = 0;
    reg have_xoff = 0;
    reg [2:0] xo_d1 = 0, xo_d2 = 0;
    reg hv_d1 = 0, hv_d2 = 0;
    integer errs = 0, checked = 0;
    reg [14:0] want;

    always @(posedge hclk) begin
        xo_d1 <= last_xoff; hv_d1 <= have_xoff;
        xo_d2 <= xo_d1; hv_d2 <= hv_d1;
        if (hv_d2 && x[7:3] != 0) begin
            want = (xo_d2 == 3'd2) ? TEXT : BACK;
            if (color !== want) begin
                errs <= errs + 1;
                if (errs < 10)
                    $display("FAIL: x=%0d xoff=%0d (d1=%0d last=%0d dut_xoff=%0d): got %h, want %h",
                             x, xo_d2, xo_d1, last_xoff, dut.font_xoff, color, want);
                if (errs == 10) $fatal(1, "tb_textdisp: FAIL");
            end
            checked <= checked + 1;
        end
        // advance x with 3,2 holds (skip the cursor column x < 8)
        if (x >= 8'd8) begin
            hold_n <= hold_n + 1;
            if (hold_n == hold - 1) begin
                hold_n <= 0;
                hold <= (hold == 3) ? 2 : 3;
                x <= x + 8'd1;
                last_xoff <= x[2:0] + 3'd1;
                have_xoff <= 1'b1;
            end
        end else begin
            x <= x + 8'd1;
            last_xoff <= x[2:0] + 3'd1;
            have_xoff <= 1'b0;      // no check while crossing the cursor column
        end
        if (x == 8'd255) begin
            $display("tb_textdisp: PASS (%0d clocks checked, 3/2 holds)", checked);
            $finish;
        end
    end

    initial begin
        #4000000;
        $display("tb_textdisp: FAIL (timeout, checked=%0d errs=%0d)", checked, errs);
        $finish;
    end
endmodule
