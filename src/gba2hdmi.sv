// GBA video and sound to HDMI converter
// nand2mario, 2024.7

module gba2hdmi (
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
    input [31:0] video_config,  // colour controls, CRT mask, LCD grid and smoothing, see video_fx.v, smooth.v

    input std_timing,           // 1: standard 60 Hz 720p timing, 0: native GBA rate (see hdmi.sv)
    output rel_toggle,          // frame lock: toggles once per HDMI frame at RELEASE_ROW (clk_pixel domain)

    // output [7:0] led,

	// output signals
	output       tmds_clk_n,
	output       tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

// include from tang_primer_25k/config.sv and tang_nano_20k/config.sv

localparam FRAMEWIDTH = 1280;
localparam FRAMEHEIGHT = 720;
localparam TOTALWIDTH = 1650;
localparam TOTALHEIGHT = 750;
localparam SCALE = 5;
localparam VIDEOID = 4;
localparam VIDEO_REFRESH = 60.0;

localparam IDIV_SEL_X5 = 3;
localparam FBDIV_SEL_X5 = 54;
localparam ODIV_SEL_X5 = 2;
localparam DUTYDA_SEL_X5 = "1000";
localparam DYN_SDIV_SEL_X5 = 2;
  
localparam CLKFRQ = 74250;

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
// Scale to 1080x720 for GBA video, 960x720 for overlay
// See scanlines.v for the scanline geometry: with scanlines on, 4 output rows
// per source line and 4 columns per pixel, 960x640 centred. The LCD grid
// (video_config[15]) uses that integer geometry too, even with the scanlines off.
// Nearest neighbour; smooth.v blends the source pixels (video_config[19:18]). For that the
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

// scanlines: sl_geom frames are scaled 4 rows per source line
wire sl_geom, sl_show, sl_dark;
wire [7:0] sl_yy;
wire [1:0] sl_dk;
wire row_last;              // sl_geom: this output row is the last of its source line
sl_rows sl (
    .clk(clk_pixel), .cy(cy),
    .cfg_on(scanlines), .cfg_dark(sl_darkness), .cfg_thick(sl_thick), .cfg_out(sl_out),
    .cfg_grid(video_config[15]), .hide(overlay),
    .rows(3'd4), .dark_thin(3'd1), .dark_thick(3'd2), .lines(8'd160), .top(10'd40),
    .geom(sl_geom), .pic_top(), .yy(sl_yy), .show(sl_show), .dark(sl_dark), .last(row_last), .darkness(sl_dk)
);
reg [7:0] yy_s;             // source line to show
always @(posedge clk_pixel) yy_s <= sl_geom ? sl_yy : yy;

// smoothing: the frame buffer is read for line yy_s and for yb_s, one clock each in turn
localparam LINES = 160;       // lines of the picture
wire [1:0] sm_mode;
wire sm_rd_b;
wire [23:0] sm_rgb;
reg [7:0] yb_s;               // the neighbour line to blend with
wire [7:0] ysel = sm_rd_b ? yb_s : yy_s;
wire [7:0] xx_ov;             // xx, SM_LAT clocks old
assign mem_portB_addr = ysel * WIDTH + xx;
assign overlay_x = xx_ov;
assign overlay_y = yy_s;
// image width on screen: 1080 (3:2) for the GBA picture, 960 for the overlay (4:3)
// and for the GBA picture with scanlines (3:2 on 640 rows)
wire [11:0] XSIZE  = (overlay | sl_geom) ? 12'd960 : 12'd1080;
wire [11:0] XSTART = (12'd1280 - XSIZE) >> 1;
wire [11:0] XSTOP  = (12'd1280 + XSIZE) >> 1;

// address calculation
// Assume the video occupies fully on the Y direction, we are upscaling the video by `720/height`.
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
reg cnew = 1'b0;            // the frame buffer address is the first of a source column
always @(posedge clk_pixel) begin
    reg active_t;
    reg [10:0] xcnt_next;
    reg [10:0] ycnt_next;
    xcnt_next = xcnt + (overlay ? 256 : width);
    ycnt_next = ycnt + (overlay ? 224 : height);

    active_t = 0;
    if ({1'b0, cx} == XSTART - 12'd1 - FX_LAT - SM_LAT) begin
        active_t = 1;
        active <= 1;
    end else if ({1'b0, cx} == XSTOP - 12'd1 - FX_LAT - SM_LAT) begin
        active_t = 0;
        active <= 0;
    end

    // the first source column starts with the first pixel, the others when xx changes.
    // Delayed with the frame buffer read below, so it lands on the first read of the column.
    cnew <= ({1'b0, cx} == XSTART - 12'd2 - FX_LAT - SM_LAT) | ((active_t | active) & (xcnt_next >= XSIZE));

    // the last output column of each source pixel: with the integer geometry XSIZE is 960,
    // four columns per pixel. Delayed with the frame buffer read and the smoothing below,
    // so it lands on rgb_pre.
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
        if (ycnt_next >= 720) begin
            ycnt <= ycnt_next - 720;
            // (the rows below the picture show the last line; the menu overlay is 224 lines)
            if (overlay) begin
                if (yy != 8'd223) yy <= yy + 1;
            end else if (yy != LINES - 1) yy <= yy + 1;
        end
    end

    if (cx == 0) begin
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
// is 240 of the 1080 (960) units of a source pixel, vertically 160 of 720.
localparam [16:0] KX_STEP = (65536 * 256 + 240 / 2) / 240;
localparam [16:0] KX_HALF_960 = (65536 * 128 + 960 / 2) / 960;
localparam [16:0] KX_HALF_1080 = (65536 * 128 + 1080 / 2) / 1080;
localparam [16:0] KY_STEP = (65536 * 256 + 160 / 2) / 160;
localparam [16:0] KY_STEP_OV = (65536 * 256 + 224 / 2) / 224;
localparam [16:0] KY_HALF = (65536 * 128 + 720 / 2) / 720;
wire [10:0] xstep = overlay ? 11'd256 : 11'd240;
wire [16:0] kx_step = overlay ? 17'd65536 : KX_STEP;
wire [10:0] ystep = overlay ? 11'd224 : 11'd160;
wire [16:0] ky_step = overlay ? KY_STEP_OV : KY_STEP;
wire [7:0] wx, wy_ax;
wire hnext, vnext_ax;
smooth_axis ax (
    .clk(clk_pixel), .mode(sm_mode), .pos(xcnt), .step(xstep), .size(XSIZE),
    .k_step(kx_step), .k_half(XSIZE == 12'd960 ? KX_HALF_960 : KX_HALF_1080),
    .first(xx == 8'd0), .last(xx == 8'd239), .w(wx), .next(hnext)
);
smooth_axis ay (
    .clk(clk_pixel), .mode(sm_mode), .pos(ycnt), .step(ystep), .size(12'd720),
    .k_step(ky_step), .k_half(KY_HALF),
    .first(yy_s == 8'd0), .last(yy_s == LINES - 1), .w(wy_ax), .next(vnext_ax)
);

// Integer-scale frames show 4 rows per source line: soft blends the rows 1/8 and 3/8
// towards the line before (first half) or after it (second half). Sharp has nothing
// to blend, the rows are whole. TOP is divisible by 4, so cy[1:0] is the row in the line.
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
    .clk(clk_pixel), .cy(cy), .cfg(video_config[19:18]), .mode(sm_mode),
    .rd_b(sm_rd_b), .rd_rgb(fb_rgb), .col_new(cn2), .wx(wx), .hnext(hnext), .wy(wy),
    .rgb_out(sm_rgb)
);

// calc rgb value to hdmi
always @(posedge clk_pixel) begin
    if (active_d & sl_show) begin
        if (overlay)
            rgb_pre <= {overlay_color[4:0],3'b0,overlay_color[9:5],3'b0,overlay_color[14:10],3'b0};       // BGR5 to RGB8
        else
            rgb_pre <= sm_rgb;
    end else
        rgb_pre <= 24'h303030;
    pic_pre <= active_d & sl_show & ~overlay;
    dark_pre <= active_d & sl_show & ~overlay & sl_dark;
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
// and runs again when HDMI reaches RELEASE_ROW. The GBA vblank remainder is
// 68 lines (~5.0 ms, ~225 HDMI rows), so releasing here puts the freshly
// written line 0 a few rows ahead of the HDMI read at the top of the frame;
// writes run faster than reads after that (one GBA line per ~3.3 HDMI rows
// against one line read per 4.5 rows), so the margin only grows down the
// frame. Edge-triggered (one toggle per HDMI frame over a synchroniser in
// the top), so a late arrival waits for the next frame.
localparam RELEASE_ROW = 515;   // HDMI row whose start releases the GBA
reg at_rel_q = 1'b0;
reg rel_toggle_r = 1'b0;
always @(posedge clk_pixel) begin
    at_rel_q <= (cy == RELEASE_ROW);
    if ((cy == RELEASE_ROW) && !at_rel_q)
        rel_toggle_r <= ~rel_toggle_r;
end
assign rel_toggle = rel_toggle_r;

hdmi #( .VIDEO_ID_CODE(VIDEOID), 
        .DVI_OUTPUT(0), 
        .VIDEO_REFRESH_RATE(VIDEO_REFRESH),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE), 
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .START_X(0),
        .START_Y(0),
        .NATIVE_FRAME_WIDTH(1657) )

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
