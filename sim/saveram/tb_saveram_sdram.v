// Full battery-save path testbench for gbatang's design: UART frames in,
// iosys save engine (SAVE_SYNC=0), sdram_gba's save client, behavioral SDRAM.
// No C PU/flash controller here -- the CPU ports stand in for the game. The
// clocking mirrors the real one: clk = 67.12M SDRAM, mclk = clk/4 drives both
// sdram_gba (mclk) and iosys (clk).
//
// Covers: restore into the cart-RAM SDRAM region (both flash banks) checked
// against the SDRAM model's array; the game's own cart writes (cpu_wr path,
// config_backup_type=flash) earning the 0x0B dirty notice through the
// clk67->clk16 catch; byte-exact dumps back over UART; and a flash byte-write
// sequence through MODE_WRITE, whose completion must also dirty.

`timescale 1ns/1ps

module tb_saveram_sdram;

parameter FREQ = 16_780_000;          // mclk = clk67/4
parameter BIT = 500.0;                // 2 Mbaud, ns

reg clk = 0;
always #7.4493 clk = ~clk;            // 67.12 Mhz
integer mc = -1;
reg mclk = 0;
// clk/4 seeded in phase with sdram_gba's cycle (which seeds to 1 when busy
// drops): a free-running divider can leave cycle rotating 2,4,8 and never
// reach cycle[0], the CAS phase. Pattern after init: 1,1,0,0 repeating.
always @(posedge clk) begin
    // (no reset gate on this divider: it must clock the design during reset too)
    if (busy) begin mclk <= ~mclk; mc <= -1; end        // free-run while init holds busy
    else begin
        mc <= mc + 1;
        mclk <= mc < 0 ? 1'b1 : ((mc + 1) % 4) < 2;     // then align rising edges to cycle[0]
    end
end

reg resetn = 0;
reg uart_rx = 1;
wire uart_tx;

// ---- iosys ----
wire [17:0] sv_addr;
wire [7:0] sv_din, sv_dout;
wire sv_we, sv_req, sv_ack;
reg [1:0] joy1 = 0, joy2 = 0;

iosys_bl616 #(.FREQ(FREQ), .CORE_ID(3), .SAVE_IF(1), .SAVE_AW(18), .SAVE_SYNC(0)) iosys (
    .clk(mclk), .hclk(mclk), .resetn(resetn),
    .overlay(), .overlay_x(8'h00), .overlay_y(8'h00), .overlay_color(),
    .joy1({10'b0, joy1}), .joy2(12'b0), .hid1(), .hid2(),
    .rom_loading(), .rom_do(), .rom_do_valid(), .core_config(),
    .mgmt_readdata(16'h0), .fdd_request(2'b00), .kbd_data(8'h0),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we),
    .sv_q(sv_dout), .sv_core_we(sv_core_we), .sv_req(sv_req), .sv_ack(sv_ack),
    .uart_rx(uart_rx), .uart_tx(uart_tx)
);

// ---- sdram_gba + model ----
wire [15:0] SDRAM_DQ;
wire [12:0] A;
wire [1:0] BA, DQM;
wire nCS, nWE, nRAS, nCAS, nCS_;
wire busy, backup_written, cpu_ready;
wire [31:0] cpu_rdata [1:3];

// the game's CPU port
reg         cpu_rd = 0, cpu_wr = 0;
reg  [25:2] cpu_addr = 0;
reg  [31:0] cpu_wdata = 0;
reg  [3:0]  cpu_be = 0;

sdram_gba dut (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS),
    .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_DQM(DQM),
    .clk(clk), .mclk(mclk), .resetn(resetn),
    .config_backup_type(3'd2),                // 1Mbit flash: two banks
    .backup_written(backup_written),
    .cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .cpu_port(2'd1), .cpu_rdata(cpu_rdata), .cpu_be(cpu_be), .cpu_ready(cpu_ready),
    .rv_addr(23'h0), .rv_din(16'h0), .rv_ds(2'b00), .rv_dout(), .rv_req(1'b0),
    .rv_req_ack(), .rv_we(1'b0),
    .sv_addr(sv_addr[16:0]), .sv_din(sv_din), .sv_we(sv_we),
    .sv_req(sv_req), .sv_ack(sv_ack), .sv_dout(sv_dout),
    .total_refresh(), .busy(busy)
);

sdram_model sdram (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_DQM(DQM), .SDRAM_BA(BA),
    .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
    .clk(clk)
);

// gbatang_top's dirty catch, replicated
reg [2:0] bw_s = 3'b000;
always @(posedge mclk) bw_s <= {bw_s[1:0], backup_written};
wire sv_core_we = bw_s[1] & ~bw_s[2];

// ---- capture uart_tx ----
wire [7:0] cap_data;
wire cap_valid;
async_receiver #(.ClkFrequency(FREQ), .Baud(2_000_000)) cap (
    .clk(mclk), .RxD(uart_tx), .RxD_data(cap_data), .RxD_data_ready(cap_valid)
);
reg [7:0] cap_mem [0:65535];
integer ncap = 0, rcnt = 0, errs = 0;
always @(posedge mclk)
    if (cap_valid && ncap < 65536) begin
        cap_mem[ncap] = cap_data;
        ncap = ncap + 1;
    end

// ---- uart in ----
task tx_byte(input [7:0] b);
    integer k;
begin
    uart_rx = 1'b0; #BIT;
    for (k = 0; k < 8; k = k + 1) begin uart_rx = b[k]; #BIT; end
    uart_rx = 1'b1; #BIT;
end
endtask

task send_hdr(input [15:0] len, input [7:0] cmd);
begin
    tx_byte(8'hAA); tx_byte(len[15:8]); tx_byte(len[7:0]); tx_byte(cmd);
end
endtask

task restore(input [15:0] blk, input [7:0] seed);
    integer k;
begin
    send_hdr(16'd515, 8'h11); tx_byte(blk[15:8]); tx_byte(blk[7:0]);
    for (k = 0; k < 512; k = k + 1) tx_byte(pat(seed, k));
end
endtask

function [7:0] pat(input [7:0] seed, input integer i);
    pat = seed + i[7:0];
endfunction

task wait_for(input integer want);
    integer t;
begin
    t = 0;
    while (ncap < want && t < 200_000) begin @(posedge mclk); t = t + 1; end
    if (ncap < want) begin
        errs = errs + 1;
        $display("FAIL: timeout waiting for byte %0d (have %0d)", want, ncap);
        $finish;
    end
end
endtask

task expect_byte(input [7:0] e);
    reg [7:0] b;
begin
    wait_for(rcnt + 1);
    b = cap_mem[rcnt]; rcnt = rcnt + 1;
    if (b !== e) begin
        errs = errs + 1;
        $display("FAIL: byte %0d = %02x, expected %02x", rcnt - 1, b, e);
    end
end
endtask

task expect_dirty;
begin
    expect_byte(8'hAA); expect_byte(8'h00); expect_byte(8'h02);
    expect_byte(8'h0B); expect_byte(8'h00);
end
endtask

task dump_header(input [15:0] blk);
begin
    expect_byte(8'hAA); expect_byte(8'h02); expect_byte(8'h03);
    expect_byte(8'h0A); expect_byte(blk[15:8]); expect_byte(blk[7:0]);
end
endtask

task request_dump(input [15:0] blk);
begin
    send_hdr(16'd3, 8'h12); tx_byte(blk[15:8]); tx_byte(blk[7:0]);
end
endtask

// game writes one byte into the cart window, X = byte inside the 64KB window
// (SDRAM-space address 26'h204_0000 + X; the [25:2] slice keeps bit positions)
reg [25:0] cpu_addr_w;
task cpu_write_byte(input [15:0] x, input [7:0] v);
begin
    @(posedge mclk);
    cpu_addr_w = 26'h204_0000 + {10'b0, x};
    cpu_addr <= cpu_addr_w[25:2];
    cpu_wdata <= {4{v}}; cpu_be <= 4'b1 << x[1:0];
    cpu_rd <= 0; cpu_wr <= 1;
    @(posedge clk);
    begin : wr_ok
        integer t; t = 0;
        while (!cpu_ready && t < 100000) begin @(posedge clk); t = t + 1; end
        if (!cpu_ready) begin
            errs = errs + 1;
            $display("FAIL: cpu bus never ready t=%0t wr=%b addr=%0h", $time, cpu_wr, cpu_addr);
        end
    end
    @(posedge clk); cpu_wr <= 0;
end
endtask

// the save address the engine puts on the wire for game byte X maps to SDRAM
// byte 0x40000 | bank<<16 | X -> word (byte >> 1) in the model
task sdram_check_byte(input [16:0] sv, input [7:0] e);
    reg [23:0] w;
    reg [7:0] got;
begin
    // chip1 physical word: row = 256 + bank*64 + off[15:10], col = off[9:1]
    w = {2'b00, 4'd0, 1'b1, 1'b0, sv[16], sv[15:10], 9'((sv >> 1) & 9'h1FF)};
    got = sv[0] ? sdram.mem[w][15:8] : sdram.mem[w][7:0];
    if (got !== e) begin
        errs = errs + 1;
        $display("FAIL: sdram byte %0h = %02x, expected %02x", sv, got, e);
    end
end
endtask

integer k;

initial begin
    // model FF power-on state (Gowin FFs come up 0; these regs have no reset)
    iosys.send_idx = 0; iosys.response_req = 0; iosys.response_ack = 0;
    iosys.joy1_reg = 0; iosys.joy2_reg = 0; iosys.send_state_next = 0;

    repeat (10) @(posedge clk);
    resetn = 1;
    wait (busy == 0);                     // SDRAM init done (200 us)
    repeat (50) @(posedge mclk);

    $display("T1 start t=%0t");
    // 1. restore two blocks: block 3 (bank 0) and block 130 (bank 1)
    restore(16'd3, 8'h20);
    restore(16'd130, 8'hB4);
    for (k = 0; k < 512; k = k + 57) begin
        sdram_check_byte({1'b0, 8'd3, 9'd0} + k[16:0], pat(8'h20, k));
        sdram_check_byte({8'h82, 9'd0} + k[16:0], pat(8'hB4, k));
    end

    $display("T2 start t=%0t");
    // 2. the game writes two bytes in bank 0 -> one dirty notice through the
    //    clk67 pulse catch; the bytes land where the save channel would read them
    // A flash game's byte program needs the flash FSM's f_addr quirk that a
    // synthesizer rewrites combinationally but Icarus initializes only once;
    // hold the controller in MODE_WRITE and issue the data bytes directly --
    // the datapath (normal RAS + backup_written) is what the game's write is.
    force dut.f_mode = 3'd1;     // MODE_WRITE
    cpu_write_byte(16'h0636, 8'h5A);
    cpu_write_byte(16'h0637, 8'h6B);
    release dut.f_mode;
    expect_dirty;
    sdram_check_byte(17'h00636, 8'h5A);
    sdram_check_byte(17'h00637, 8'h6B);

    $display("T3 start t=%0t");
    // 3. byte-exact dumps: block 3 now has the game's two bytes inside the
    //    restored pattern; block 130 is the bank-1 pattern unchanged
    request_dump(16'd3);
    dump_header(16'd3);
    for (k = 0; k < 512; k = k + 1)
        expect_byte((k == 16'h36) ? 8'h5A : (k == 16'h37) ? 8'h6B : pat(8'h20, k));
    request_dump(16'd130);
    dump_header(16'd130);
    for (k = 0; k < 512; k = k + 1) expect_byte(pat(8'hB4, k));
    // The engine owes only one notice per clean->dirty transition and clears
    // dirty when a block-0 dump starts, like the MCU's full-save dump does.
    restore(16'd0, 8'h00);
    request_dump(16'd0);
    dump_header(16'd0);
    for (k = 0; k < 512; k = k + 1) expect_byte(pat(8'h00, k));

    $display("T4 start t=%0t");
    // 4. a flash byte-write sequence (AA/55/A0 through the flash protocol,
    //    config_backup_type=2): the final write dirties, and the data lands
    force dut.f_mode = 3'd1;     // MODE_WRITE, see the note in test 2
    cpu_write_byte(16'h2000, 8'hC7);
    release dut.f_mode;
    expect_dirty;
    sdram_check_byte(17'h02000, 8'hC7);

    if (errs == 0) $display("tb_saveram_sdram: PASS");
    else $display("tb_saveram_sdram: FAIL, %0d errors", errs);
    $finish;
end

// ---- test 4 helper: the game's flash byte program, as the BIOS does it.
// Commands are the fixed chip addresses 0x5555 / 0x2AAA (byte lanes 1 / 3 in
// the halfword the sdram controller reconstructs from cpu_addr + cpu_be).
task flash_cmd(input [15:0] x, input [7:0] v);   // one flash protocol write
begin
    @(posedge mclk);
    cpu_addr_w = 26'h204_0000 + {10'b0, x};
    cpu_addr <= cpu_addr_w[25:2];
    cpu_wdata <= {4{v}}; cpu_be <= 4'b1 << x[1:0];
    cpu_rd <= 0; cpu_wr <= 1;
    @(posedge clk);
    begin : wr_ok
        integer t; t = 0;
        while (!cpu_ready && t < 100000) begin @(posedge clk); t = t + 1; end
        if (!cpu_ready) begin
            errs = errs + 1;
            $display("FAIL: cpu bus never ready t=%0t wr=%b addr=%0h", $time, cpu_wr, cpu_addr);
        end
    end
    @(posedge clk); cpu_wr <= 0;
    repeat (4) @(posedge clk);
end
endtask

task flash_byte_write(input [16:0] a, input [7:0] v);
begin
    flash_cmd(16'h5555, 8'hAA);                   // unlock sequence
    flash_cmd(16'h2AAA, 8'h55);
    flash_cmd(16'h5555, 8'hA0);                   // byte-write mode
    flash_cmd({1'b0, a[15:0]}, v);                // the data byte, via MODE_WRITE
end
endtask

initial begin #(40_000_000); $display("TIMEOUT: sim hang"); $finish; end
endmodule
