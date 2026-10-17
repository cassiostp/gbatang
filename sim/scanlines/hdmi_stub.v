// Stand-ins for the Gowin and HDMI parts of a scaler, for simulation: a pixel
// counter with the real module's timing (cx counts the frame_width x 525
// frame, std_timing ? 858 : NATIVE_FRAME_WIDTH like the real hdmi.sv VIC 48, and
// the picture is the rgb input seen while cx = x + 1), and a pass-through
// output buffer. An unconnected std_timing (the history baselines built by
// prep.sh predate the port) reads as Z and selects the standard 858.
module hdmi #(
    parameter VIDEO_ID_CODE = 48,
    parameter DVI_OUTPUT = 0,
    parameter VIDEO_REFRESH_RATE = 120.0,
    parameter IT_CONTENT = 1,
    parameter AUDIO_RATE = 48000,
    parameter AUDIO_BIT_WIDTH = 16,
    parameter START_X = 0,
    parameter START_Y = 0,
    parameter NATIVE_FRAME_WIDTH = 861
) (
    input         clk_pixel_x5,
    input         clk_pixel,
    input         clk_audio,
    input         std_timing,
    input  [23:0] rgb,
    input         reset,
    input  [15:0] audio_sample_word [1:0],
    output [2:0]  tmds,
    output        tmds_clock,
    output reg [10:0] cx = START_X,
    output reg [9:0]  cy = START_Y,
    output [10:0] frame_width,
    output [9:0]  frame_height
);
    wire std_eff = (std_timing === 1'b0) ? 1'b0 : 1'b1;
    wire [10:0] fw = std_eff ? 11'd858 : NATIVE_FRAME_WIDTH;
    assign frame_width = fw;
    assign frame_height = 525;
    assign tmds = 3'b0;
    assign tmds_clock = 1'b0;
    always @(posedge clk_pixel) begin
        cx <= (cx == fw - 1'b1) ? 11'd0 : cx + 11'd1;
        if (cx == fw - 1'b1)
            cy <= (cy == 10'd524) ? 10'd0 : cy + 10'd1;
    end
endmodule

module ELVDS_OBUF (input I, output O, output OB);
    assign O = I;
    assign OB = ~I;
endmodule
