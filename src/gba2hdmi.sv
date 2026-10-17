// GBA video and sound to HDMI converter
// nand2mario, 2024.7

module gba2hdmi #(
    // 0 compiles the smoothing blend out (nearest-neighbour). The 120 Hz
    // build sets it: video_config[19:18] stays unused there.
    parameter bit SMOOTH_EN = 1'b0
) (
	input clk,      // clock
    input clk27,
	input resetn,
    output clk_pixel,

    // gba video signals
    input [17:0] pixel_data,    // RGB6
    input [7:0] pixel_x,
    input [7:0] pixel_y,
    input pixel_we,

    // audio input
    input [15:0] sound_left,
    input [15:0] sound_right,

    // overlay interface
    input overlay,
    output [10:0] overlay_x,
    output [9:0] overlay_y,
    input [15:0] overlay_color,
    input scanlines,            // core_config[16]: scanlines on
    input [1:0] sl_darkness,    // core_config[19:18]: 25, 50, 75, 100 % dark
    input sl_thick,             // core_config[20]: thick lines
    input sl_out,               // core_config[21]: dark output rows instead of an integer scale
    input [31:0] video_config,  // colour controls, CRT mask, LCD grid (video_fx.v);
                                // [21:20] BFI mode, [19:18] unused (smoothing compiled out)

    input std_timing,           // 1: standard 120 Hz 480p timing, 0: native GBA rate x2 (see hdmi.sv)
    output rel_toggle,          // frame lock: toggles once per game frame at RELEASE_ROW (clk_pixel domain)

    // output [7:0] led,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

// include from tang_primer_25k/config.sv and tang_nano_20k/config.sv

localparam FRAMEWIDTH = 720;
localparam FRAMEHEIGHT = 480;
localparam TOTALWIDTH = 858;
localparam TOTALHEIGHT = 525;
localparam SCALE = 5;
localparam VIDEOID = 48;            // 480p120: VIC 2/3 totals at 54 MHz, for BFI
localparam VIDEO_REFRESH = 120.0;   // the audio clock regeneration only: the line is NATIVE below
// 54 MHz / (861x525) = 119.4624 Hz, twice 59.7312 Hz: the largest
// whole-pixel line at or above twice the GBA 59.7275 Hz that locks on the
// 138K clocks (free-run 59.8531 Hz, 34.1 us halt); the 860 line would run
// 59.8007 Hz (+0.12 % fast), 861 is +0.006 % over native. 720 active pixels
// fit with 141 of blanking; the sync pulse keeps the standard position.
localparam NATIVE_LINE = 861;

localparam IDIV_SEL_X5 = 3;
localparam FBDIV_SEL_X5 = 54;
localparam ODIV_SEL_X5 = 2;
localparam DUTYDA_SEL_X5 = "1000";
localparam DYN_SDIV_SEL_X5 = 2;
  
localparam CLKFRQ = 54000;

localparam COLLEN = 80;
localparam AUDIO_BIT_WIDTH = 16;

localparam POWERUPNS = 100000000.0;
localparam CLKPERNS = (1.0/CLKFRQ)*1000000.0;
localparam int POWERUPCYCLES = $rtoi($ceil( POWERUPNS/CLKPERNS ));

pll_74 pll74(.clkin(clk27), .clkout0(clk_pixel), .clkout1(clk_5x_pixel));

// video stuff
wire [9:0] cy, frameHeight;
wire [10:0] cx, frameWidth;

//
// BRAM frame buffer
//
logic [17:0] mem_portA_wdata;

localparam WIDTH=240, width=240;
localparam HEIGHT=160, height=160;
localparam COLOR_BITS=6;

localparam FB_DEPTH = WIDTH * HEIGHT;
localparam COLOR_WIDTH = COLOR_BITS * 3;
localparam FB_AWIDTH = $clog2(FB_DEPTH);
// reg [COLOR_WIDTH-1:0] mem [0:FB_DEPTH-1];
reg [FB_AWIDTH-1:0] mem_portA_addr;
reg mem_portA_we;

wire [FB_AWIDTH-1:0] mem_portB_addr;
reg [COLOR_WIDTH-1:0] mem_portB_rdata;

fb u_fb(
    .clka(clk), .clkb(clk_pixel), .reseta('b0), .resetb(1'b0), .cea('b1), .ceb('b1), 
    // port A write
    .ada(mem_portA_addr), .douta(), .ocea(1'b0), .wrea(mem_portA_we), .dina(mem_portA_wdata),
    // port B read
    .adb(mem_portB_addr), .doutb(mem_portB_rdata), .oceb(1'b1), .wreb('b0), .dinb('b0)
);

// 
// Data input and initial background loading
//
logic [8:0] r_scanline;
logic [8:0] r_cycle;
always @(posedge clk) begin
    mem_portA_we <= pixel_we;
    mem_portA_addr <= pixel_y * 240 + pixel_x;
    mem_portA_wdata <= pixel_data;
end

// audio stuff
//    localparam AUDIO_RATE=32000;        // weird only 32K sampling rate works
//    localparam AUDIO_RATE=96000;
localparam AUDIO_RATE=48000;
localparam AUDIO_CLK_DELAY = CLKFRQ * 1000 / AUDIO_RATE / 2;
logic [$clog2(AUDIO_CLK_DELAY)-1:0] audio_divider;
logic clk_audio;

always_ff@(posedge clk_pixel) 
begin
    if (audio_divider != AUDIO_CLK_DELAY - 1) 
        audio_divider++;
    else begin 
        clk_audio <= ~clk_audio; 
        audio_divider <= 0; 
    end
end

reg [15:0] audio_sample_word [1:0], audio_sample_word0 [1:0];
always @(posedge clk_pixel) begin       // crossing clock domain
    audio_sample_word0[0] <= sound_left;
    audio_sample_word[0] <= audio_sample_word0[0];
    audio_sample_word0[1] <= sound_right;
    audio_sample_word[1] <= audio_sample_word0[1];
end

//
// Video
// Scale to 720x480 for GBA video (240x160 at 3x, full frame), 640 wide
// centred for the overlay (256x224 at 2.5x)
// See scanlines.v for the scanline geometry: with scanlines on, 3 output rows
// per source line, filling the frame. The LCD grid
// (video_config[15]) uses that integer geometry too, even with the scanlines off.
// Nearest neighbour; smoothing is compiled out of this 120 Hz build
// (SMOOTH_EN = 0, video_config[19:18] unused). For that the
// frame buffer is read twice per source column, the line to show and its neighbour line.
// The fb block RAM (fb.mod, read_mode bypass) has one clock of read latency, like the
// gba_stubs.v stand-in, so with the fb_q register the read data is ready two clocks
// after the address, as smooth expects.
//
wire [23:0] rgb;            // actual RGB output
reg [23:0] rgb_pre;         // before video_fx
reg pic_pre;                // rgb_pre is a pixel of the picture, not the border or the overlay
reg dark_pre;
reg col_last_1, col_last_2; // the last output column of a source pixel, with the frame buffer read
reg active                  /* xsynthesis syn_keep=1 */;
reg [$clog2(WIDTH)-1:0] xx  /* xsynthesis syn_keep=1 */; // scaled-down pixel position
reg [$clog2(HEIGHT)-1:0] yy /* xsynthesis syn_keep=1 */;
reg [10:0] xcnt             /* xsynthesis syn_keep=1 */;
reg [10:0] ycnt             /* xsynthesis syn_keep=1 */;                  // fractional scaling counters
reg [9:0] cy_r;

// scanlines: sl_geom frames are scaled 3 rows per source line, 720x480:
// the integer scale fills the frame exactly, so there is no border.
wire sl_geom, sl_show, sl_dark;
wire [7:0] sl_yy;
wire [1:0] sl_dk;
wire row_last;              // sl_geom: this output row is the last of its source line
sl_rows sl (
    .clk(clk_pixel), .cy(cy),
    .cfg_on(scanlines), .cfg_dark(sl_darkness), .cfg_thick(sl_thick), .cfg_out(sl_out),
    .cfg_grid(video_config[15]), .hide(overlay),
    .rows(3'd3), .dark_thin(3'd1), .dark_thick(3'd2), .lines(8'd160), .top(10'd0),
    .geom(sl_geom), .pic_top(), .yy(sl_yy), .show(sl_show), .dark(sl_dark), .last(row_last), .darkness(sl_dk)
);
// second sl_rows, 11 clocks into the future: show/dark for the row the
// rgb_pre pixels belong to (see cy_flag above)
wire sl_f_show, sl_f_dark;
wire [7:0] sl_f_yy;
wire sl_f_last;
wire [1:0] sl_f_dk;
sl_rows sl_f (
    .clk(clk_pixel), .cy(cy_flag),
    .cfg_on(scanlines), .cfg_dark(sl_darkness), .cfg_thick(sl_thick), .cfg_out(sl_out),
    .cfg_grid(video_config[15]), .hide(overlay),
    .rows(3'd3), .dark_thin(3'd1), .dark_thick(3'd2), .lines(8'd160), .top(10'd0),
    .geom(), .pic_top(), .yy(sl_f_yy), .show(sl_f_show), .dark(sl_f_dark), .last(sl_f_last), .darkness(sl_f_dk)
);
reg [7:0] yy_s;             // source line to show
always @(posedge clk_pixel) yy_s <= sl_geom ? sl_yy : yy;

// The picture is full-bleed (XSTART = 0), so the first pixels of every row
// are read while cy still shows the previous row: a read lands on the screen
// FX_LAT + SM_LAT + 2 = 22 clocks after its address cycle, and the 21
// address cycles before cx == 0 belong to the row being drawn. The line for
// those addresses is the coming row's, not the current one: yy_a counts it,
// advancing at the address-block start (cx == NATIVE_LINE - 22) with the same
// 3-rows phasing sl_rows uses (a clocked counter keeps the frame-buffer
// address path shallow; yy/ycnt would give the fractional stagger). The
// scanline flags are sampled with rgb_pre, 11 clocks after the addresses, so
// a second sl_rows on cy_flag (the row showing then, plus sl_rows' own
// register) provides row-correct show/dark; overlay_y, the grid flags and
// the (dead) smoothing weights keep the row-aligned yy_s.
wire [9:0] cy_next = (cy == 10'd524) ? 10'd0 : cy + 10'd1;
wire [9:0] cy_flag = ({1'b0, cx} >= NATIVE_LINE - 12) ? cy_next : cy;
// address-block line counter: one advance per row, three rows per line,
// holding the last line below the picture, reset for row 0. It fires at
// cx == 839 - 1 so the new line is already up for the first address cycle.
reg [1:0] rcnt_a = 2'd0;
reg [7:0] yy_a = 8'd0;
always @(posedge clk_pixel) begin
    if ({1'b0, cx} == NATIVE_LINE - 23) begin
        if (cy == 10'd524) begin yy_a <= 8'd0; rcnt_a <= 2'd0; end
        else if (yy_a == 8'd159) begin yy_a <= 8'd159; rcnt_a <= rcnt_a + 2'd1; end
        else if (rcnt_a == 2'd2) begin yy_a <= yy_a + 8'd1; rcnt_a <= 2'd0; end
        else rcnt_a <= rcnt_a + 2'd1;
    end
end
wire [7:0] ysel = overlay ? yy_s : (sm_rd_b ? yb_s : yy_a);

// smoothing: the frame buffer is read for line ysel and for yb_s, one clock each in turn
localparam LINES = 160;       // lines of the picture
wire [1:0] sm_mode;
wire sm_rd_b;
wire [23:0] sm_rgb;
reg [7:0] yb_s;               // the neighbour line to blend with (smoothing is compiled out)
wire [7:0] xx_ov;             // xx, SM_LAT clocks old
assign mem_portB_addr = ysel * WIDTH + xx;
assign overlay_x = xx_ov;
assign overlay_y = yy_s;
// image width on screen: 720 for the GBA picture (240 x 3, full frame),
// 640 for the overlay (256 x 2.5, centred like the NES one)
wire [11:0] XSIZE  = overlay ? 12'd640 : 12'd720;
wire [11:0] XSTART = (12'd720 - XSIZE) >> 1;
wire [11:0] XSTOP  = (12'd720 + XSIZE) >> 1;

// address calculation
// Assume the video occupies fully on the Y direction, we are upscaling the video by `480/height`.
// xcnt and ycnt are fractional scaling counters.
// video_fx follows rgb_pre with FX_LAT register stages. Its first stage is the one that sl_dim
// used to be (active started at XSTART - 2 then), so active starts FX_LAT - 1 clocks earlier
// than that, at XSTART - 1 - FX_LAT. The smoothing is between the frame buffer and rgb_pre:
// rgb_pre comes SM_LAT clocks later than the frame buffer read alone would give it, so active
// starts SM_LAT clocks earlier still. The xx/xcnt counters run with it; the overlay lookup
// address (xx_ov) and `active` are delayed back by SM_LAT, so the picture, the overlay and
// the border land where they did.
localparam FX_LAT = 11;     // clocks from rgb_pre to rgb, see video_fx.v
localparam SM_LAT = 9;      // the frame buffer read is followed by smooth.v (LAT 8) and the rgb_pre register
// The active window starts FX_LAT + SM_LAT + 1 clocks before XSTART and ends
// there before XSTOP. The picture is full-bleed (XSTART = 0), so the start
// edge wraps around the end of the line: the edges are mod NATIVE_LINE.
wire [11:0] act_on = (XSTART >= 12'd1 + FX_LAT + SM_LAT) ? XSTART - 12'd1 - FX_LAT - SM_LAT
                                                         : XSTART + NATIVE_LINE - 12'd1 - FX_LAT - SM_LAT;
wire [11:0] act_off = (XSTOP >= 12'd1 + FX_LAT + SM_LAT) ? XSTOP - 12'd1 - FX_LAT - SM_LAT
                                                         : XSTOP + NATIVE_LINE - 12'd1 - FX_LAT - SM_LAT;
wire [11:0] col_on = (act_on == 12'd0) ? NATIVE_LINE - 12'd1 : act_on - 12'd1;
reg cnew = 1'b0;            // the frame buffer address is the first of a source column
always @(posedge clk_pixel) begin
    reg active_t;
    reg [10:0] xcnt_next;
    reg [10:0] ycnt_next;
    xcnt_next = xcnt + (overlay ? 256 : width);
    ycnt_next = ycnt + (overlay ? 224 : height);

    active_t = 0;
    if ({1'b0, cx} == act_on) begin
        active_t = 1;
        active <= 1;
    end else if ({1'b0, cx} == act_off) begin
        active_t = 0;
        active <= 0;
    end

    // the first source column starts with the first pixel, the others when xx changes.
    // Delayed with the frame buffer read below, so it lands on the first read of the column.
    cnew <= ({1'b0, cx} == col_on) | ((active_t | active) & (xcnt_next >= XSIZE));

    // the last output column of each source pixel: with the integer geometry
    // XSIZE is 720 (640 for the overlay), three columns per picture pixel
    // (2 or 3 per overlay pixel). Delayed with the frame buffer read and the
    // smoothing below, so it lands on rgb_pre.
    col_last_1 <= (active_t | active) & (xcnt_next >= XSIZE);
    col_last_2 <= col_last_1;

    if (active_t | active) begin        // increment xx
        xcnt <= xcnt_next;
        if (xcnt_next >= XSIZE) begin
            xcnt <= xcnt_next - XSIZE;
            xx <= xx + 1;
        end
    end

    cy_r <= cy;
    if (cy[0] != cy_r[0]) begin         // increment yy at new lines
        ycnt <= ycnt_next;
        if (ycnt_next >= 480) begin
            ycnt <= ycnt_next - 480;
            // (the rows below the picture show the last line; the menu overlay is 224 lines)
            if (overlay) begin
                if (yy != 8'd223) yy <= yy + 1;
            end else if (yy != LINES - 1) yy <= yy + 1;
        end
    end

    // The picture is full-bleed, so the active window wraps around cx == 0:
    // the per-row counter reset sits just before the window (col_on), not at
    // cx == 0, or the first pixels of every row would show twice.
    if ({1'b0, cx} == col_on) begin
        xx <= 0;
        xcnt <= 0;
    end
    
    if (cy == 0) begin
        yy <= 0;
        ycnt <= 0;
    end 

end

// xx and active, delayed by SM_LAT
reg [8*SM_LAT-1:0] xx_sh;
reg [SM_LAT-1:0] act_sh;
always @(posedge clk_pixel) begin
    xx_sh <= {xx_sh[8*SM_LAT-9:0], xx};
    act_sh <= {act_sh[SM_LAT-2:0], active};
end
assign xx_ov = xx_sh[8*SM_LAT-1 -: 8];
wire active_d = act_sh[SM_LAT-1];

// the grid flags, delayed by the smoothing so they still land on the last column/row
// of each source pixel at rgb_pre
reg [SM_LAT-1:0] col_sh, row_sh;
always @(posedge clk_pixel) begin
    col_sh <= {col_sh[SM_LAT-2:0], col_last_2};
    row_sh <= {row_sh[SM_LAT-2:0], row_last};
end
wire col_last_d = col_sh[SM_LAT-1];
wire row_last_d = row_sh[SM_LAT-1];

// The weights of the blend, from the same counters (smooth.v). Horizontally the output pixel
// is 240 of the 720 units of a source pixel (256 of 640 for the overlay),
// vertically 160 of 480. With SMOOTH_EN = 0 the mode is always off and the
// weights are unused, but the axes still elaborate.
localparam [16:0] KX_STEP = (65536 * 256 + 240 / 2) / 240;
localparam [16:0] KX_HALF_640 = (65536 * 128 + 640 / 2) / 640;
localparam [16:0] KX_HALF_720 = (65536 * 128 + 720 / 2) / 720;
localparam [16:0] KY_STEP = (65536 * 256 + 160 / 2) / 160;
localparam [16:0] KY_STEP_OV = (65536 * 256 + 224 / 2) / 224;
localparam [16:0] KY_HALF = (65536 * 128 + 480 / 2) / 480;
wire [10:0] xstep = overlay ? 11'd256 : 11'd240;
wire [16:0] kx_step = overlay ? 17'd65536 : KX_STEP;
wire [10:0] ystep = overlay ? 11'd224 : 11'd160;
wire [16:0] ky_step = overlay ? KY_STEP_OV : KY_STEP;
wire [7:0] wx, wy_ax;
wire hnext, vnext_ax;
smooth_axis ax (
    .clk(clk_pixel), .mode(sm_mode), .pos(xcnt), .step(xstep), .size(XSIZE),
    .k_step(kx_step), .k_half(XSIZE == 12'd640 ? KX_HALF_640 : KX_HALF_720),
    .first(xx == 8'd0), .last(xx == 8'd239), .w(wx), .next(hnext)
);
smooth_axis ay (
    .clk(clk_pixel), .mode(sm_mode), .pos(ycnt), .step(ystep), .size(12'd480),
    .k_step(ky_step), .k_half(KY_HALF),
    .first(yy_s == 8'd0), .last(yy_s == LINES - 1), .w(wy_ax), .next(vnext_ax)
);

// Integer-scale frames show 3 rows per source line. Smoothing is compiled out
// of this build (SMOOTH_EN = 0, wy is always 0), so the soft-blend row weights
// below are inert; they are kept for the shape of a later rebase with smoothing.
wire [1:0] row_idx = cy[1:0];
wire vnext_geom = (row_idx >= 2'd2);
wire [7:0] w_geom_raw = (row_idx == 2'd0 || row_idx == 2'd3) ? 8'd96 : 8'd32;
wire geom_blend = (sm_mode == 2'd2) & (vnext_geom ? (yy_s != LINES - 1) : (yy_s != 8'd0));
wire [7:0] wy = sl_geom ? (geom_blend ? w_geom_raw : 8'd0) : wy_ax;
wire vnext = sl_geom ? vnext_geom : vnext_ax;
always @(posedge clk_pixel)
    yb_s <= vnext ? ((yy_s == LINES - 1) ? yy_s : yy_s + 8'd1)
                  : ((yy_s == 8'd0) ? yy_s : yy_s - 8'd1);

// the frame buffer read, and the first-of-column flag with it
reg [COLOR_WIDTH-1:0] fb_q;
reg cn1, cn2;
always @(posedge clk_pixel) begin
    fb_q <= mem_portB_rdata;
    cn1 <= cnew;
    cn2 <= cn1;
end
wire [23:0] fb_rgb = {fb_q[COLOR_BITS*2 +: COLOR_BITS], {(8-COLOR_BITS){1'b0}},
        fb_q[COLOR_BITS +: COLOR_BITS], {(8-COLOR_BITS){1'b0}},
        fb_q[0 +: COLOR_BITS], {(8-COLOR_BITS){1'b0}}};    // RGB6 to RGB8

smooth sm (
    .clk(clk_pixel), .cy(cy), .cfg(SMOOTH_EN ? video_config[19:18] : 2'd0), .mode(sm_mode),
    .rd_b(sm_rd_b), .rd_rgb(fb_rgb), .col_new(cn2), .wx(wx), .hnext(hnext), .wy(wy),
    .rgb_out(sm_rgb)
);

// calc rgb value to hdmi. In an inserted BFI frame the whole picture area
// (border included) is black or dimmed; the menu overlay is exempt so the
// menu stays steady while the game is paused under it.
wire bfi_dark = bfi_eff_ins & (bfi_mode != 2'd0) & ~overlay;
reg [23:0] rgb_norm;
always @* begin
    if (active_d & sl_f_show) begin
        if (overlay)
            rgb_norm = {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};       // BGR5 to RGB8
        else
            rgb_norm = sm_rgb;
    end else
        rgb_norm = 24'h303030;
end
always @(posedge clk_pixel) begin
    if (!bfi_dark)
        rgb_pre <= rgb_norm;
    else if (bfi_mode == 2'd1)
        rgb_pre <= 24'h000000;
    else
        rgb_pre <= {1'b0, rgb_norm[23:17], 1'b0, rgb_norm[15:9], 1'b0, rgb_norm[7:1]};
    pic_pre <= active_d & sl_f_show & ~overlay & ~bfi_dark;
    dark_pre <= active_d & sl_f_show & ~overlay & sl_f_dark & ~bfi_dark;
end

// colour controls, the scanline darkening, the LCD grid and the CRT mask
video_fx fx (
    .clk(clk_pixel), .cx(cx), .cy(cy), .video_config(video_config),
    .rgb_in(rgb_pre), .pic_in(pic_pre), .dark_in(dark_pre), .darkness(sl_dk),
    .col_last_in(col_last_d), .row_last_in(row_last_d),
    .rgb_out(rgb)
);

// HDMI output.
logic[2:0] tmds;

// Frame lock release: the top-level halt waits at the first GBA vblank line
// and runs again when HDMI reaches RELEASE_ROW in an even frame. Each game
// frame is read twice (lit, then inserted), and the release is edge-triggered
// (one toggle per game frame over a synchroniser in the top), so a late
// arrival waits for the next pair and the phase is exact. The GBA vblank
// remainder is 68 lines (~5.0 ms, ~313 HDMI rows). Releasing at 453 leaves
// the inserted read of the frame just lit ahead of the writer overwriting it
// (needs row > 212) while the next lit read still runs behind the writer
// (needs row < 484): writes are slower than reads here (one GBA line per
// ~4.6 HDMI rows against one line read per 3 rows), so the margin shrinks
// down the frame, from ~284 rows at the top to ~31 rows at line 159.
//
// LCD image retention: BFI at half the refresh rate always shows the image
// on frames of the same LCD polarity, leaving a DC bias. Every
// BFI_SWAP_FRAMES game frames (~30 s) the lit/inserted assignment flips,
// so the image averages to zero DC over minutes. The flip is armed at a
// release and takes effect at the next frame start, so one boundary shows
// two lits or two blacks in a row (alternating); the release cadence never
// moves, so there is no tear and no audio gap, just one 8 ms duplicate per
// swap. The menu overlay is exempt from darkening, so the menu itself stays
// steady while the game behind it keeps alternating.
//
// BFI mode is video_config[21:20]: 0 off (both frames lit), 1 black inserted
// frame, 2 inserted frame at 1/2 brightness, 3 treated as 1.
localparam RELEASE_ROW = 453;   // HDMI row whose start releases the GBA (even frames)
localparam BFI_SWAP_FRAMES = 1800;  // game frames between lit/inserted swaps (~30 s)

// HDMI frame parity (toggles every frame) and the BFI phase: the inserted
// (darkened) frame is bfi_ins ^ bfi_phase, while releases stay on even
// frames so the game timing never shifts at a swap. Single driver (Gowin
// rejects the two-block form).
wire [1:0] bfi_cfg = video_config[21:20];
wire [1:0] bfi_mode = (bfi_cfg == 2'd3) ? 2'd1 : bfi_cfg;
reg bfi_ins = 1'b1;
reg bfi_phase = 1'b0;
reg [15:0] bfi_swap_cnt = 16'd0;
reg bfi_swap_pending = 1'b0;
reg at_f0_q = 1'b0;
reg at_rel_q = 1'b0;
reg rel_toggle_r = 1'b0;
always @(posedge clk_pixel) begin
    at_f0_q <= (cy == 10'd0);
    at_rel_q <= (cy == RELEASE_ROW);
    if ((cy == 10'd0) && !at_f0_q) begin
        bfi_ins <= ~bfi_ins;
        if (bfi_swap_pending) begin
            bfi_phase <= ~bfi_phase;
            bfi_swap_pending <= 1'b0;
        end
    end
    if ((cy == RELEASE_ROW) && !at_rel_q && !bfi_ins) begin
        rel_toggle_r <= ~rel_toggle_r;
        if (bfi_swap_cnt == BFI_SWAP_FRAMES - 1) begin
            bfi_swap_cnt <= 16'd0;
            bfi_swap_pending <= 1'b1;
        end else
            bfi_swap_cnt <= bfi_swap_cnt + 16'd1;
    end
end
wire bfi_eff_ins = bfi_ins ^ bfi_phase;
assign rel_toggle = rel_toggle_r;

hdmi #( .VIDEO_ID_CODE(VIDEOID), 
        .DVI_OUTPUT(0), 
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE), 
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0),
        .NATIVE_FRAME_WIDTH(NATIVE_LINE) )

hdmi( .clk_pixel_x5(clk_5x_pixel), 
        .clk_pixel(clk_pixel), 
        .clk_audio(clk_audio),
        .std_timing(std_timing),
        .rgb(rgb), 
        .reset( 0 ),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds), 
        .tmds_clock(tmdsClk), 
        .cx(cx), 
        .cy(cy),
        .frame_width( frameWidth ),
        .frame_height( frameHeight ) );

// Gowin LVDS output buffer
ELVDS_OBUF tmds_bufds [3:0] (
    .I({clk_pixel, tmds}),
    .O({tmds_clk_p, tmds_d_p}),
    .OB({tmds_clk_n, tmds_d_n})
);


endmodule
