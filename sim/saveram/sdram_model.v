// Behavioral 16-bit SDRAM for the gbatang save sims: 4 banks, activate latches
// the row, CL2 reads, byte-masked writes. Only the chip whose CS bit is 1 is
// modeled (sdram_gba's chip 1: EWRAM + cart RAM); chip 0 (cartridge ROM) reads
// back as X and its writes are dropped. The linear word index {BA, row, col}
// is exactly the mapping sdram_gba derives from its byte-address latches, so
// the testbenches can read mem[] with byte addresses of their own.
//
// ROM_PAT=1 also models chip 0 (the cartridge ROM) as a read-only synthetic
// image: the halfword at linear index i reads back as romh(i), so a testbench
// can check ROM fetches without loading 32MB.

module sdram_model #(
    parameter ROM_PAT = 0
) (
    inout  [15:0] SDRAM_DQ,
    input  [12:0] SDRAM_A,
    input  [1:0]  SDRAM_DQM,
    input  [1:0]  SDRAM_BA,
    input         SDRAM_nCS,
    input         SDRAM_nWE,
    input         SDRAM_nRAS,
    input         SDRAM_nCAS,
    input         clk
);

wire [3:0] cmd = {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};
wire [23:0] word = {SDRAM_BA, row_lat[SDRAM_BA], SDRAM_A[8:0]};

reg [12:0] row_lat [0:3];
reg [12:0] row_lat0 [0:3];

function [15:0] romh(input [23:0] idx);
    romh = (idx[15:0] * 16'h9E37) ^ {idx[23:16], idx[7:0]} ^ 16'h5A5A;
endfunction
wire [23:0] word0 = {SDRAM_BA, row_lat0[SDRAM_BA], SDRAM_A[8:0]};
reg [15:0] mem [0:(1<<23)-1];
reg rv = 0, rv1 = 0;
reg [15:0] rq = 0, rq1 = 0;

always @(posedge clk) begin
    if (cmd == 4'b1011)                       // activate, chip 1 (nCS=1)
        row_lat[SDRAM_BA] <= SDRAM_A[12:0];
    else if (cmd == 4'b0011)                  // activate, chip 0
        row_lat0[SDRAM_BA] <= SDRAM_A[12:0];
    else if (cmd == 4'b1100) begin            // write, byte-masked
        if (!SDRAM_DQM[0]) mem[word][7:0]  <= SDRAM_DQ[7:0];
        if (!SDRAM_DQM[1]) mem[word][15:8] <= SDRAM_DQ[15:8];
    end
    {rv1, rq1} <= {rv, rq};
    rv  <= (cmd == 4'b1101) | (ROM_PAT != 0 && cmd == 4'b0101);   // read: data drives two clocks on
    rq  <= cmd[3] ? mem[word] : romh(word0);
end
assign SDRAM_DQ = rv1 ? rq1 : 16'hzzzz;

endmodule
