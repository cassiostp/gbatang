// Faithful stand-in for src/hdmi/hdmi.sv for the iverilog frame-lock bench
// (iverilog cannot parse packet_assembler.sv's array slices). Replicates the
// real module's pixel counters and the native-rate frame_width select
// exactly: cx counts 0..fw-1 with fw = std_timing ? 858 : NATIVE_FRAME_WIDTH
// (VIC 48 only, like the real hdmi.sv), cy counts 0..524. The TMDS/packet path
// is not modelled (tmds = 0); the DUT-side logic under test (scaler,
// release toggle, audio divider/sampler) is all real.
module hdmi #(
    parameter int VIDEO_ID_CODE = 48,
    parameter bit IT_CONTENT = 1'b1,
    parameter int BIT_WIDTH = 10,
    parameter int BIT_HEIGHT = 10,
    parameter bit DVI_OUTPUT = 1'b0,
    parameter real VIDEO_REFRESH_RATE = 120.0,
    parameter int AUDIO_RATE = 48000,
    parameter int AUDIO_BIT_WIDTH = 16,
    parameter bit [8*8-1:0] VENDOR_NAME = {"Unknown", 8'd0},
    parameter bit [8*16-1:0] PRODUCT_DESCRIPTION = {"FPGA", 96'd0},
    parameter bit [7:0] SOURCE_DEVICE_INFORMATION = 8'h00,
    parameter int START_X = 0,
    parameter int START_Y = 0,
    parameter int NATIVE_FRAME_WIDTH = 861
) (
    input logic clk_pixel_x5,
    input logic clk_pixel,
    input logic clk_audio,
    input logic std_timing,
    input logic reset,
    input logic [23:0] rgb,
    input logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word [1:0],
    output logic [2:0] tmds,
    output logic tmds_clock,
    output logic [BIT_WIDTH-1:0] cx,
    output logic [BIT_HEIGHT-1:0] cy,
    output logic [BIT_WIDTH-1:0] frame_width,
    output logic [BIT_HEIGHT-1:0] frame_height,
    output logic [BIT_WIDTH-1:0] screen_width,
    output logic [BIT_HEIGHT-1:0] screen_height
);
    wire [BIT_WIDTH-1:0] fw = std_timing ? 10'd858 : NATIVE_FRAME_WIDTH;
    assign frame_width = fw;
    assign frame_height = 525;
    assign screen_width = 720;
    assign screen_height = 480;
    assign tmds = 3'b0;
    assign tmds_clock = 1'b0;
    initial begin cx = START_X; cy = START_Y; end
    always @(posedge clk_pixel) begin
        if (reset) begin cx <= START_X; cy <= START_Y; end
        else begin
            cx <= (cx == fw - 1'b1) ? 0 : cx + 1'b1;
            if (cx == fw - 1'b1)
                cy <= (cy == 524) ? 0 : cy + 1'b1;
        end
    end
endmodule
