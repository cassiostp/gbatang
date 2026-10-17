// Simulation stub for Gowin's DPB true dual-port BRAM primitive, enough for
// gowin_dpb_menu (8-bit x 2048, byte writes) in the save sims. The overlay
// text RAM is not exercised by these testbenches.
module DPB (
    output reg [7:0] DOA,
    output reg [7:0] DOB,
    input  CLKA, input  OCEA, input  CEA, input  RESETA, input  WREA,
    input  CLKB, input  OCEB, input  CEB, input  RESETB, input  WREB,
    input  [2:0] BLKSELA, input [2:0] BLKSELB,
    input  [15:0] ADA, input [15:0] DIA,
    input  [15:0] ADB, input [15:0] DIB
);
    parameter READ_MODE0 = 0, READ_MODE1 = 0;
    parameter [1:0] WRITE_MODE0 = 0, WRITE_MODE1 = 0;
    parameter [7:0] BIT_WIDTH_0 = 8, BIT_WIDTH_1 = 8;
    parameter [2:0] BLK_SEL_0 = 0, BLK_SEL_1 = 0;
    parameter RESET_MODE = "SYNC";
    parameter [255:0] INIT_RAM_00 = 0, INIT_RAM_01 = 0, INIT_RAM_02 = 0, INIT_RAM_03 = 0,
        INIT_RAM_04 = 0, INIT_RAM_05 = 0, INIT_RAM_06 = 0, INIT_RAM_07 = 0,
        INIT_RAM_08 = 0, INIT_RAM_09 = 0, INIT_RAM_0A = 0, INIT_RAM_0B = 0,
        INIT_RAM_0C = 0, INIT_RAM_0D = 0, INIT_RAM_0E = 0, INIT_RAM_0F = 0,
        INIT_RAM_10 = 0, INIT_RAM_11 = 0, INIT_RAM_12 = 0, INIT_RAM_13 = 0,
        INIT_RAM_14 = 0, INIT_RAM_15 = 0, INIT_RAM_16 = 0, INIT_RAM_17 = 0,
        INIT_RAM_18 = 0, INIT_RAM_19 = 0, INIT_RAM_1A = 0, INIT_RAM_1B = 0,
        INIT_RAM_1C = 0, INIT_RAM_1D = 0, INIT_RAM_1E = 0, INIT_RAM_1F = 0,
        INIT_RAM_20 = 0, INIT_RAM_21 = 0, INIT_RAM_22 = 0, INIT_RAM_23 = 0,
        INIT_RAM_24 = 0, INIT_RAM_25 = 0, INIT_RAM_26 = 0, INIT_RAM_27 = 0,
        INIT_RAM_28 = 0, INIT_RAM_29 = 0, INIT_RAM_2A = 0, INIT_RAM_2B = 0,
        INIT_RAM_2C = 0, INIT_RAM_2D = 0, INIT_RAM_2E = 0, INIT_RAM_2F = 0,
        INIT_RAM_30 = 0, INIT_RAM_31 = 0, INIT_RAM_32 = 0, INIT_RAM_33 = 0,
        INIT_RAM_34 = 0, INIT_RAM_35 = 0, INIT_RAM_36 = 0, INIT_RAM_37 = 0,
        INIT_RAM_38 = 0, INIT_RAM_39 = 0, INIT_RAM_3A = 0, INIT_RAM_3B = 0,
        INIT_RAM_3C = 0, INIT_RAM_3D = 0, INIT_RAM_3E = 0, INIT_RAM_3F = 0;

    reg [7:0] mem [0:2047];

    always @(posedge CLKA) begin
        if (CEA) begin
            if (WREA) mem[ADA[13:3]] <= DIA[7:0];
            if (OCEA) DOA <= mem[ADA[13:3]];
        end
        if (RESETA) DOA <= 8'h00;
    end
    always @(posedge CLKB) begin
        if (CEB) begin
            if (WREB) mem[ADB[13:3]] <= DIB[7:0];
            if (OCEB) DOB <= mem[ADB[13:3]];
        end
        if (RESETB) DOB <= 8'h00;
    end
endmodule
