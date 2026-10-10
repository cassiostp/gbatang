// Behavioral SDRAM chip for the GBA co-sim: answers the exact command subset
// the real sdram_gba issues (single-word accesses, burst length 1, CL2),
// adapted from the sdram_model in sim/saveram (which passes against the real
// controller under tb_sdram_save/tb_gba_saves). Not a full SDRAM model:
// refresh, mode-set and precharge are accepted and ignored; reads complete 2
// fclk after the READ command and the last read word stays on DQ (the
// controller samples once, 3 fclk after CAS, and issues nothing else on the
// bus meanwhile).
//
// sdram_gba encodes the chip select in the nCS bit of every command:
// nCS=1 commands address chip 1 (EWRAM + cart RAM + the RV bank), nCS=0
// commands address chip 0 (cartridge ROM). Only chip 1 is modeled -- nothing
// in the co-sim reads cartridge ROM contents (the CPU stream reads it for
// bus load only, and reads of a floating bus are 0 in 2-state), so this
// instance answers nCS=1 and ignores everything else. The CS_VAL parameter
// documents which half of the pair an instance is.
//
// Address map: ACT latches the 13-bit row per bank; the READ/WRITE column
// A[8:0] selects the word, so the linear word index is {BA, row, col} --
// for every command sdram_gba issues this equals the chip byte address
// [24:1] (the save client's row/column split reproduces the CPU-side layout
// for the same byte, which tb_sdram_save cross-checks). The array is sized
// to EWRAM + cart RAM (word indices < 0x30000); the RV bank cannot be
// addressed from the cosim (rv_req is tied 0) and its commands would wrap.
//
// DQM masks write lanes; reads select the lane by the controller (it picks
// the byte by address bit 0 itself).
//
// Power-up: all 0xFFFF (blank backup RAM reads 0xFF, matching SRAM power-up
// and the firmware's blank-save image). Contents are RETAINED across resetn:
// on hardware reprogramming the FPGA does not clear the external SDRAM.
// COSIM debug port: combinational byte read of the array for expect-save-ram;
// mem is also `verilator public` for fast C++ reads. iverilog ignores both.
module sdram_chip #(
    parameter CS_VAL = 1'b1       // the nCS level this chip answers
) (
    input fclk,
    input [12:0] A,
    input [1:0] BA,
    input [1:0] DQM,
    input nCS,
    input nWE,
    input nRAS,
    input nCAS,
    inout [15:0] SDRAM_DQ
`ifdef COSIM
    , input [18:0] dbg_addr,
    output [7:0] dbg_data
`endif
);

reg [12:0] row_lat [0:3];
reg [15:0] mem [0:(1<<18)-1] /*verilator public*/;

integer i;
initial begin
    for (i = 0; i < (1 << 18); i = i + 1)
        mem[i] = 16'hFFFF;
end

wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};
wire [23:0] word_full = {BA, row_lat[BA], A[8:0]};
wire [17:0] word = word_full[17:0];
reg rv = 0, rv1 = 0;
reg [15:0] rq = 0, rq1 = 0;

always @(posedge fclk) begin
    if (cmd == {CS_VAL, 3'b011})
        row_lat[BA] <= A[12:0];
    else if (cmd == {CS_VAL, 3'b100}) begin
        if (!DQM[0])
            mem[word][7:0] <= SDRAM_DQ[7:0];
        if (!DQM[1])
            mem[word][15:8] <= SDRAM_DQ[15:8];
    end
    {rv1, rq1} <= {rv, rq};
    rv <= (cmd == {CS_VAL, 3'b101});
    rq <= mem[word];
end

assign SDRAM_DQ = rv1 ? rq1 : 16'hzzzz;

`ifdef COSIM
wire [17:0] dbg_word = dbg_addr[18:1];
assign dbg_data = dbg_addr[0] ? mem[dbg_word][15:8] : mem[dbg_word][7:0];
`endif

endmodule
