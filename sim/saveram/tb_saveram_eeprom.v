// Battery-save testbench for gbatang's EEPROM routing: an EEPROM game sends
// the save channel to port B of the EEPROM's dual-port RAM (blocks 0..15 = the
// 8KB chip), while the game talks to port A with its serial protocol. Mirrors
// gbatang_top's routing exactly: addr/din follow the save channel, the write
// strobe is one clock per issued transaction (the engine's sv_we is held
// between UART bytes and must NOT keep writing during the game's own writes),
// the ack is the request itself (the port answers in one clock) and the dirty
// hook is the chip's `written` pulse.
//
// Covers: the INIT fill (blank RAM is 0xFF), restore through the routing and
// its visibility from the serial side, byte-exact dumps, and a serial write
// earning the 0x0B notice -- with sv_we deliberately left held after the last
// restore byte to prove the strobe.

`timescale 1ns/1ps

module tb_saveram_eeprom;

parameter FREQ = 16_650_000;          // gbatang clk16
parameter BIT = 500.0;                // 2 Mbaud, ns

reg clk = 0;
always #30.03 clk = ~clk;
reg resetn = 0;
reg uart_rx = 1;
wire uart_tx;

wire [17:0] sv_addr;
wire [7:0] sv_din, sv_q;
wire sv_we, sv_req, sv_ack;
wire sv_core_we;
reg  [11:0] joy1 = 0, joy2 = 0;

iosys_bl616 #(.FREQ(FREQ), .CORE_ID(3), .SAVE_IF(1), .SAVE_AW(18), .SAVE_SYNC(0)) dut (
    .clk(clk), .hclk(clk), .resetn(resetn),
    .overlay(), .overlay_x(8'h00), .overlay_y(8'h00), .overlay_color(),
    .joy1(joy1), .joy2(joy2), .hid1(), .hid2(),
    .rom_loading(), .rom_do(), .rom_do_valid(), .core_config(),
    .mgmt_readdata(16'h0), .fdd_request(2'b00), .kbd_data(8'h0),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we),
    .sv_q(sv_q), .sv_core_we(sv_core_we), .sv_req(sv_req), .sv_ack(sv_ack),
    .uart_rx(uart_rx), .uart_tx(uart_tx)
);

// ---- gbatang_top's EEPROM routing, replicated ----
reg sv_req_d = 0;
always @(posedge clk) sv_req_d <= sv_req;
wire eep_wr_stb = (sv_req ^ sv_req_d) & sv_we;    // one clock per transaction
wire eep_save = 1'b1;                             // config_backup_type == 4

// ---- the EEPROM chip: port A is the game, port B the save channel ----
wire [7:0] eep_q;
wire written;
reg cs = 0, swrite = 0, din = 0;
wire dout;

gba_eeprom eep (
    .clk(clk), .rst(~resetn), .cs(cs), .model(1'b0),   // 512B chip (6-bit addr)
    .dma_eepromcount(17'd0),
    .valid(1'b1), .write(swrite), .ready(), .din(din), .dout(dout),
    .written(written),
    .rv_rd(1'b0), .rv_wr(eep_wr_stb), .rv_addr(sv_addr[12:0]),
    .rv_rdata(eep_q), .rv_wdata(sv_din)
);

assign sv_q = eep_q;
assign sv_ack = sv_req;                             // answers in one clock
assign sv_core_we = written;




// ---- capture dut's uart_tx ----
wire [7:0] cap_data;
wire cap_valid;
async_receiver #(.ClkFrequency(FREQ), .Baud(2_000_000)) cap (
    .clk(clk), .RxD(uart_tx), .RxD_data(cap_data), .RxD_data_ready(cap_valid)
);
reg [7:0] cap_mem [0:65535];
integer ncap = 0, rcnt = 0, errs = 0;
always @(posedge clk)
    if (cap_valid && ncap < 65536) begin
        cap_mem[ncap] = cap_data;
        ncap = ncap + 1;
    end

function [7:0] pat(input [7:0] seed, input integer i);
    pat = seed + i[7:0];
endfunction

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

task wait_for(input integer want);
    integer t;
begin
    t = 0;
    while (ncap < want && t < 4_000_000) begin @(posedge clk); t = t + 1; end
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

// ---- the game's serial side: a write transaction to 6-bit block `a` ----
// the bit drivers use non-blocking assignments: a bit set when waking from an
// edge must land on the NEXT edge, or the FSM samples the next bit early.
task serial_write(input [5:0] a, input [63:0] data);
    integer k;
begin
    cs <= 1; din <= 1; @(posedge clk);              // bit1 "1"
    din <= 0; @(posedge clk);                       // bit2 "0": write
    for (k = 5; k >= 0; k = k - 1) begin din <= a[k]; @(posedge clk); end
    for (k = 63; k >= 0; k = k - 1) begin din <= data[k]; @(posedge clk); end
    din <= 0; @(posedge clk);                       // stop bit
    din <= 0; @(posedge clk);
    cs <= 0;
end
endtask

task serial_read(input [5:0] a, input [63:0] e);
    integer k;
    reg [63:0] got;
begin
    cs <= 1; din <= 1; @(posedge clk);              // bit1 "1"
    din <= 1; @(posedge clk);                       // bit2 "1": read
    for (k = 5; k >= 0; k = k - 1) begin din <= a[k]; @(posedge clk); end
    din <= 0; @(posedge clk);                       // trailing 0
    swrite <= 0;                                    // tri-state out: clock data
    for (k = 0; k < 4; k = k + 1) @(posedge clk);   // 4 don't-care bits
    got = 0;
    for (k = 63; k >= 0; k = k - 1) begin
        @(posedge clk);
        got[k] = dout;
    end
    swrite <= 1;
    cs <= 0;
    if (got !== e) begin
        errs = errs + 1;
        $display("FAIL: serial block %0d = %h, expected %h", a, got, e);
    end
end
endtask

integer k;
reg [63:0] sd;

initial begin
    // model FF power-on state (Gowin FFs come up 0; these regs have no reset)
    dut.send_idx = 0; dut.response_req = 0; dut.response_ack = 0;
    dut.joy1_reg = 0; dut.joy2_reg = 0; dut.send_state_next = 0;
    swrite = 1;

    repeat (10) @(posedge clk);
    resetn = 1;

    // let the chip's INIT fill run out (65536 one-bit writes)
    k = 0;
    while (eep.state != eep.IDLE && k < 200000) begin @(posedge clk); k = k + 1; end
    if (eep.state != eep.IDLE) begin
        errs = errs + 1;
        $display("FAIL: INIT did not finish");
    end
    repeat (50) @(posedge clk);

    // 1. a blank EEPROM comes up 0xFF, top to bottom
    for (k = 0; k < 8192; k = k + 797)
        if (eep.m_eeprom.mem[k] !== 8'hFF) begin
            errs = errs + 1;
            $display("FAIL: blank eeprom[%0d] = %02x", k, eep.m_eeprom.mem[k]);
        end

    // 2. restore blocks 0 and 1 through the routing
    restore(16'd0, 8'h5C);
    restore(16'd1, 8'hE1);
    for (k = 0; k < 512; k = k + 61) begin
        if (eep.m_eeprom.mem[k] !== pat(8'h5C, k)) begin
            errs = errs + 1; $display("FAIL: eeprom[%0d] = %02x exp %02x", k, eep.m_eeprom.mem[k], pat(8'h5C, k));
        end
        if (eep.m_eeprom.mem[512 + k] !== pat(8'hE1, k)) begin
            errs = errs + 1; $display("FAIL: eeprom[%0d] = %02x exp %02x", 512 + k, eep.m_eeprom.mem[512 + k], pat(8'hE1, k));
        end
    end
    // the game's side sees the restored bytes in its block 3
    sd = {eep.m_eeprom.mem[24], eep.m_eeprom.mem[25], eep.m_eeprom.mem[26], eep.m_eeprom.mem[27],
          eep.m_eeprom.mem[28], eep.m_eeprom.mem[29], eep.m_eeprom.mem[30], eep.m_eeprom.mem[31]};
    serial_read(6'd3, sd);

    // 3. byte-exact dump of block 0 (sv_we is now HELD at 1 by the engine: a
    //    broken strobe would rewrite byte 511 forever and corrupt later writes)
    request_dump(16'd0);
    dump_header(16'd0);
    for (k = 0; k < 512; k = k + 1) expect_byte(pat(8'h5C, k));

    // 4. a serial write from the game earns exactly one dirty notice, and the
    //    save channel reads it back
    sd = 64'h0123456789abcdef;
    serial_write(6'd5, sd);
    expect_dirty;
    request_dump(16'd0);
    dump_header(16'd0);
    for (k = 0; k < 512; k = k + 1)
        expect_byte((k >= 40 && k < 48) ? sd[63 - (k - 40) * 8 -: 8] : pat(8'h5C, k));

    // 5. and a restore straight after that dump re-lands cleanly
    restore(16'd0, 8'h37);
    for (k = 0; k < 512; k = k + 61)
        if (eep.m_eeprom.mem[k] !== pat(8'h37, k)) begin
            errs = errs + 1;
            $display("FAIL: eeprom[%0d] = %02x exp %02x", k, eep.m_eeprom.mem[k], pat(8'h37, k));
        end

    if (errs == 0) $display("tb_saveram_eeprom: PASS");
    else $display("tb_saveram_eeprom: FAIL, %0d errors", errs);
    $finish;
end

initial begin #(40_000_000); $display("TIMEOUT: sim hang"); $finish; end
endmodule
