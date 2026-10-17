// Save-channel unit test for sdram_gba: the req/ack byte client that reads and
// writes the 128KB cart RAM region (flash bank 1 at 64KB..128KB), verified
// against a behavioral 16-bit SDRAM (sdram_model.v). Covers ack'd byte
// writes/reads (byte lane, both banks, whole-region walk), the game's own
// writes showing through into the save channel and back, arbitration (the CPU
// wins a slot both want; a save request queued behind a full-rate CPU stream
// still gets the slots the stream leaves), and that a save transaction never
// issues twice. Run with run.sh.

`timescale 1ns/1ps

module tb_sdram_save;

reg clk = 0;
always #7.4493 clk = ~clk;            // 67.12 Mhz SDRAM clock
integer mc = -1;
reg mclk = 0;
// mclk = clk/4. In hardware it is the PLL's quarter clock, phase-locked to the
// controller's `cycle` (which seeds to 1 when init finishes). A free-running
// divider could leave `cycle` rotating 2,4,8 without cycle[0], which skips the
// CAS phase. So start the divider high exactly when busy drops: pattern 1,1,0,0.
always @(posedge clk) begin
    // (no reset gate on this divider: it must clock the design during reset too)
    if (busy) begin mclk <= ~mclk; mc <= -1; end        // free-run while init holds busy
    else begin
        mc <= mc + 1;
        mclk <= mc < 0 ? 1'b1 : ((mc + 1) % 4) < 2;     // then align rising edges to cycle[0]
    end
end

reg resetn = 0;

wire busy;
wire [15:0] SDRAM_DQ;
wire [12:0] A;
wire [1:0] BA, DQM;
wire nCS, nWE, nRAS, nCAS;
wire backup_written;

// save client side
reg  [16:0] sv_addr = 0;
reg  [7:0]  sv_din = 0;
reg         sv_we = 0, sv_req = 0;
wire        sv_ack;
wire [7:0]  sv_dout;

// CPU-side ports
// cpu_addr is sdram_gba's SDRAM-space address: bit 25 chip, [24:2] word address,
// cart RAM at 26'h204_0000 + byte offset. The tasks drive b[25:2] so the bit
// positions survive the [25:2]-range assignment.
reg         cpu_rd = 0, cpu_wr = 0;
reg  [25:2] cpu_addr = 0;
reg  [31:0] cpu_wdata = 0;
reg  [3:0]  cpu_be = 0;
wire        cpu_ready;
wire [31:0] cpu_rdata [1:3];

reg [2:0] cfg = 3'd3;               // backup type, see the dirty-flag phase

sdram_gba dut (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS),
    .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_DQM(DQM),
    .clk(clk), .mclk(mclk), .resetn(resetn), .config_backup_type(cfg),
    .backup_written(backup_written),
    .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .cpu_port(2'd1), .cpu_rdata(cpu_rdata), .cpu_be(cpu_be), .cpu_ready(cpu_ready),
    .rv_addr(23'h0), .rv_din(16'h0), .rv_ds(2'b00), .rv_dout(), .rv_req(1'b0),
    .rv_req_ack(), .rv_we(1'b0),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we),
    .sv_req(sv_req), .sv_ack(sv_ack), .sv_dout(sv_dout),
    .total_refresh(), .busy(busy)
);

sdram_model sdram (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_DQM(DQM), .SDRAM_BA(BA),
    .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
    .clk(clk)
);

// the save client must not accept a second request before the ack
integer errs = 0;
integer bw_count = 0;               // backup_written pulse tally
always @(posedge clk) bw_count <= bw_count + backup_written;

reg sv_req_d = 0;
always @(posedge clk) begin
    sv_req_d <= sv_req;
    if (sv_req != sv_req_d && sv_req_d != sv_ack) begin
        errs = errs + 1;
        $display("FAIL: two save requests at once t=%0t ack=%b we=%b addr=%05h", $time, sv_ack, sv_we, sv_addr);
    end
end

// ---- save client tasks ----
task done_ok;
    integer t;
begin
    t = 0;
    @(posedge clk);                         // let this task's req toggle land first
    while (sv_ack != sv_req && t < 100000) begin @(posedge clk); t = t + 1; end
    if (sv_ack != sv_req) begin
        errs = errs + 1;
        $display("FAIL: save ack timeout");
    end
end
endtask

task sv_write(input [16:0] a, input [7:0] d);
begin
    @(posedge mclk); sv_addr <= a; sv_din <= d; sv_we <= 1; sv_req <= ~sv_req;
    done_ok;
end
endtask

task sv_read(input [16:0] a, input [7:0] e);
    reg [7:0] got;
begin
    @(posedge mclk); sv_addr <= a; sv_we <= 0; sv_req <= ~sv_req;
    done_ok;
    repeat (20) @(posedge clk);             // data lands at the frame's cycle[3]
    got = sv_dout;
    if (got !== e) begin
        errs = errs + 1;
        $display("FAIL: sv read [%05x] = %02x, expected %02x", a, got, e);
    end
end
endtask

// ---- the game's side: 32-bit CPU requests, held until taken (cpu_ready),
// like gba_memory does. `b` is an SDRAM-space address (cart RAM = 26'h204_0000 +
// byte offset); cpu_write touches only b's byte lane.
task cpu_write(input [25:0] b, input [7:0] v);
begin
    @(posedge mclk);
    cpu_addr <= b[25:2];                       // keep bit positions (b is the SDRAM-space address)
    cpu_wdata <= {4{v}};
    cpu_be <= 4'b1 << b[1:0];
    cpu_rd <= 0; cpu_wr <= 1;
    @(posedge clk);                         // ride the next decision edge
    begin : wait_rd
        integer t; t = 0;
        while (!cpu_ready && t < 20000) begin @(posedge clk); t = t + 1; end
        if (!cpu_ready) $display("HANG: cpu task never ready t=%0t we=%b addr=%07h", $time, cpu_wr, cpu_addr);
    end
    @(posedge clk); cpu_wr <= 0;
end
endtask

task cpu_read(input [25:0] b, input [3:0] be);
begin
    @(posedge mclk);
    cpu_addr <= b[25:2];                       // keep bit positions (b is the SDRAM-space address)
    cpu_be <= be;
    cpu_rd <= 1; cpu_wr <= 0;
    @(posedge clk);
    begin : wait_rr
        integer t; t = 0;
        while (!cpu_ready && t < 20000) begin @(posedge clk); t = t + 1; end
        if (!cpu_ready) $display("HANG: cpu task never ready t=%0t we=%b addr=%07h", $time, cpu_wr, cpu_addr);
    end
    @(posedge clk); cpu_rd <= 0;
    repeat (4) @(posedge clk);              // data lands right after ready
end
endtask

function [7:0] pat(input integer i);
    pat = (i * 7 + 13) & 8'hFF;
endfunction

// a full-rate CPU stream: one request presented across every decision edge
reg cpu_stream = 0;
reg [25:0] saddr = 0;
integer srun = 0;
always @(posedge mclk) begin
    if (cpu_stream) begin
        cpu_addr <= saddr[25:2]; cpu_be <= 4'b1111; cpu_wdata <= {4{8'h77}};
        cpu_rd <= 0; cpu_wr <= 1;
        if (saddr == 26'h200_0040) srun <= srun + 1;
        saddr <= (saddr == 26'h200_0040) ? 26'h200_0000 : saddr + 4;
        if (srun == 8) begin cpu_stream <= 0; cpu_wr <= 0; end   // stop and release the bus
    end
    // (no `else cpu_wr <= 0`: it would stomp the cpu_write/cpu_read tasks'
    // own requests, which also drive the bus on posedge mclk)
end

integer k;
reg ack_before;
time t_cpu, t_sv;

initial begin
    repeat (10) @(posedge clk);
    resetn = 1;
    wait (busy == 0);                       // init ends after 200 us
    repeat (20) @(posedge clk);

    // 1. byte writes/reads across the whole 128KB: both flash banks (the walk
    //    crosses 64KB at k=131), several rows
    for (k = 0; k < 256; k = k + 1)
        sv_write(k[16:0] * 509, pat(k));    // k*509 walks 0 .. 128KB
    for (k = 0; k < 256; k = k + 1)
        sv_read(k[16:0] * 509, pat(k));

    // 2. byte lane: writes at even and odd addresses must not disturb the
    //    other half of the halfword
    sv_write(17'h00100, 8'hAA);
    sv_write(17'h00101, 8'h55);
    sv_write(17'h10102, 8'h33);             // bank 1
    sv_write(17'h10103, 8'hCC);
    sv_read(17'h00100, 8'hAA);
    sv_read(17'h00101, 8'h55);
    sv_read(17'h10100, 8'hxx);              // bank 1's neighbours untouched
    sv_read(17'h10101, 8'hxx);
    sv_read(17'h10102, 8'h33);
    sv_read(17'h10103, 8'hCC);

    // 3. the game's own view: a CPU byte write into the cart window shows up
    //    in the save channel, and a save-channel write shows up in reads
    cpu_write(26'h204_1236, 8'h5A);         // one byte, lane 2
    sv_read(17'h01236, 8'h5A);
    sv_write(17'h01237, 8'h6B);
    cpu_read(26'h204_1236, 4'b1000);
    if (cpu_rdata[1][7:0] !== 8'h6B) begin
        errs = errs + 1;
        $display("FAIL: cpu sees %02x, expected 6B", cpu_rdata[1][7:0]);
    end
    cpu_write(26'h205_1236, 8'h4E);         // bank 1 is 64KB up
    sv_read(17'h11236, 8'h4E);

    // 3.5 dirty flag: game byte writes into the backup region pulse
    // backup_written; reads, save-channel writes and non-backup writes do not.
    // f_mode is forced for the flash flavour because Gowin builds derive it
    // from the command sequence, whose f_addr static init Icarus won't repeat.
    bw_count = 0; cpu_write(26'h204_2000, 8'h11);
    repeat (8) @(posedge mclk);
    if (bw_count == 0) begin errs = errs + 1; $display("FAIL: game write did not set dirty"); end
    bw_count = 0; cpu_read(26'h204_2000, 4'b1111);
    repeat (8) @(posedge mclk);
    if (bw_count != 0) begin errs = errs + 1; $display("FAIL: read set dirty"); end
    bw_count = 0; cpu_write(26'h200_1000, 8'h22);        // EWRAM, not backup
    repeat (8) @(posedge mclk);
    if (bw_count != 0) begin errs = errs + 1; $display("FAIL: EWRAM write set dirty"); end
    bw_count = 0; sv_write(17'h02100, 8'h33);            // save channel
    repeat (8) @(posedge mclk);
    if (bw_count != 0) begin errs = errs + 1; $display("FAIL: save-channel write set dirty"); end
    cfg = 3'd1; dut.f_mode = 3'd1;                      // flash program mode
    bw_count = 0; cpu_write(26'h204_2002, 8'h44);
    repeat (8) @(posedge mclk);
    if (bw_count == 0) begin errs = errs + 1; $display("FAIL: flash-mode write did not set dirty"); end
    dut.f_mode = 3'd0; cfg = 3'd3;
    sv_read(17'h02000, 8'h11);              // the game's bytes landed in the
    sv_read(17'h02002, 8'h44);              // save channel's address space

    // 3.6 back-to-back: the ~cpu_ready mask on new requests must delay, never
    //    drop, a legitimate second write presented while the first one's ready
    //    is still up (gba_memory holds its strobe until taken, so it simply
    //    waits a frame). Eight consecutive byte writes, then read them back
    //    through the save channel.
    for (k = 0; k < 8; k = k + 1)
        cpu_write(26'h204_3000 + k, 8'hA0 + k);
    for (k = 0; k < 8; k = k + 1)
        sv_read(17'h03000 + k, 8'hA0 + k);

    // 4. arbitration. (a) a CPU request and a save request that become pending
    //    together: the CPU gets the slot first, the save request the next one.
    //    (b) a save request queued behind a full-rate CPU write stream (a fresh
    //    request presented every mclk, even in the period where ready is up,
    //    which gba_memory itself never does) is served in a gap the stream
    //    leaves -- a request that was already served and is merely still being
    //    presented does not count as a new one -- and the stream's own writes land.
    ack_before = sv_ack;
    @(posedge mclk);
    cpu_addr <= 26'h204_3000 >> 2; cpu_be <= 4'b0001; cpu_wdata <= {4{8'hA7}};
    cpu_rd <= 0; cpu_wr <= 1;
    sv_addr <= 17'h02200; sv_din <= 8'h3E; sv_we <= 1; sv_req <= ~sv_req;
    t_cpu = 0; t_sv = 0;
    begin : race
        integer t; t = 0;
        while ((t_cpu == 0 || t_sv == 0) && t < 400) begin
            @(posedge clk); t = t + 1;
            if (t_cpu == 0 && cpu_ready) t_cpu = $time;
            if (t_sv == 0 && sv_ack != ack_before) t_sv = $time;
        end
    end
    @(posedge clk); cpu_wr <= 0;
    if (t_cpu == 0 || t_sv == 0 || t_sv <= t_cpu) begin
        errs = errs + 1;
        $display("FAIL: CPU request must be served before the save request (cpu %0t, save %0t)", t_cpu, t_sv);
    end
    repeat (8) @(posedge mclk);
    sv_read(17'h03000, 8'hA7);
    sv_read(17'h02200, 8'h3E);

    ack_before = sv_ack;
    cpu_stream = 1; saddr = 26'h200_0000; srun = 0;
    @(posedge mclk); sv_addr <= 17'h02000; sv_din <= 8'hD5; sv_we <= 1;
    sv_req <= ~sv_req;
    while (cpu_stream) @(posedge mclk);     // until the stream finishes
    done_ok;
    cpu_read(26'h200_0000, 4'b1111);         // EWRAM: last thing the stream wrote
    if (cpu_rdata[1] !== 32'h7777_7777) begin
        errs = errs + 1;
        $display("FAIL: EWRAM through the stream = %08x", cpu_rdata[1]);
    end
    sv_read(17'h02000, 8'hD5);              // the queued save write landed

    // 5. a dump-like byte burst: write then read one whole block, byte exact
    for (k = 0; k < 512; k = k + 1) sv_write(k[16:0], pat(k));
    for (k = 0; k < 512; k = k + 1) sv_read(k[16:0], pat(k));

    if (errs == 0) $display("tb_sdram_save: PASS");
    else $fatal(1, "tb_sdram_save: FAIL, %0d errors", errs);
    $finish;
end

initial begin #(40_000_000); $fatal(1, "TIMEOUT: sim hang"); end
endmodule
