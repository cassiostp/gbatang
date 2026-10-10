// End-to-end battery-save testbench for gbatang: a CPU stub drives the REAL
// gba_memory (loader, backup type, isreadonly, 8-bit cart-RAM accesses, EEPROM
// serial chip) into the REAL sdram_gba (flash chip emulation, save client) and
// a behavioral SDRAM, while the MCU side is UART frames into the REAL iosys
// (SAVE_IF). It is the firmware's flow, frame for frame:
//
//   0x06 1, ROM bytes, [0x06 4, BIOS bytes], 0x06 3 + backup type byte,
//   0x11 restore blocks, 0x06 0  -> the game runs  -> game writes -> 0x0B
//   notice -> 0x12 block requests -> 0x0A block frames.
//
// The glue between the three (EEPROM mux, dirty catch, port mapping) is a copy
// of gbatang_top.sv's battery-save section; run.sh greps the top for the
// copied lines so a change there cannot go unnoticed.
//
// Covers, per backup type (SRAM, FLASH512K, FLASH1M, EEPROM, SRAM again after
// EEPROM to exercise the save-port mux switch):
//   * the backup type reaches the core before the game runs, and the restored
//     bytes are what the game reads back (restore -> game mapping, byte lanes,
//     flash bank bit);
//   * the game's own writes (SRAM byte stores through region E and its F
//     mirror, FLASH unlock/ID/program/sector erase/chip erase/bank switch,
//     EEPROM serial writes) fire exactly one 0x0B notice per dirty period and
//     show up in the dumped blocks (game -> dump mapping);
//   * a block dump completes while the CPU hammers the SDRAM with back-to-back
//     ROM fetches (ARM, Thumb, ROM+RAM): the save client must get slots.
//
// Needs run.sh's sdram_gba_sim.v (the flash FSM's `reg f_addr = expr`
// initializer made an assignment, as the synthesizer treats it).

`timescale 1ns/1ps

module tb_gba_saves;

parameter FREQ = 16_780_000;          // mclk = clk67/4
parameter BIT = 500.0;                // 2 Mbaud, ns

reg clk = 0;
always #7.4493 clk = ~clk;            // 67.12 Mhz SDRAM clock
integer mc = -1;
reg mclk = 0;
// clk/4 seeded in phase with sdram_gba's cycle (see tb_sdram_save.v)
always @(posedge clk) begin
    if (busy) begin mclk <= ~mclk; mc <= -1; end
    else begin
        mc <= mc + 1;
        mclk <= mc < 0 ? 1'b1 : ((mc + 1) % 4) < 2;
    end
end

reg resetn = 0;
reg uart_rx = 1;
wire uart_tx;

// ---------------------------------------------------------------- CPU side
reg         rom_en = 0, thumb = 0, ram_cen = 0, ram_wen = 0;
reg  [31:0] rom_addr = 0, ram_addr = 0, ram_wdata = 0;
reg   [3:0] ram_be = 0;
wire [31:0] rom_data, ram_rdata;
wire        cpu_en;

// ---------------------------------------------------------------- gba_memory
wire [1:0]  cpu_mem_port;
wire [25:2] cpu_mem_addr;
wire [31:0] cpu_mem_wdata;
wire [31:0] cpu_mem_rdata [1:3];
wire        cpu_mem_rd, cpu_mem_wr, cpu_mem_ready;
// In hardware gba_memory (clk16) and sdram_gba (clk67) flops share the clk16
// edge, so gba_memory samples sdram_gba's outputs from BEFORE that edge. Here
// mclk is derived with <=, one delta after clk, so the clk67 registers have
// already moved; these shadow registers hand gba_memory the pre-edge values.
reg         cpu_ready_q = 0;
reg  [31:0] cpu_rdata_q [1:3];
always @(posedge clk) begin
    cpu_ready_q <= cpu_mem_ready;
    cpu_rdata_q[1] <= cpu_mem_rdata[1];
    cpu_rdata_q[2] <= cpu_mem_rdata[2];
    cpu_rdata_q[3] <= cpu_mem_rdata[3];
end
wire [3:0]  cpu_mem_be;
wire        backup_written;
wire        eeprom_wr_w;
wire [12:0] eeprom_addr;
wire  [7:0] eeprom_rdata, eeprom_wdata;
wire        eeprom_written;
wire  [7:0] loader_do;
wire        loader_do_valid;
wire  [7:0] rom_loading;
wire  [2:0] loading = rom_loading[2:0];
wire        gbaon;
wire  [2:0] config_backup_type;

gba_memory mem (
    .clk(mclk), .resetn(resetn), .ce(1'b1),
    .rom_en(rom_en), .rom_addr(rom_addr), .rom_data(rom_data), .thumb(thumb), .cpu_en(cpu_en),
    .ram_cen(ram_cen), .ram_wen(ram_wen), .ram_addr(ram_addr), .ram_rdata(ram_rdata),
    .ram_wdata(ram_wdata), .ram_be(ram_be),
    .dma_on(1'b0), .dma_addr(32'h0), .dma_wdata(32'h0), .dma_ena(1'b0),
    .dma_wr(1'b0), .dma_be(4'h0), .dma_rdata(), .dma_done(), .dma_eepromcount(17'd0),
    .sdram_addr(cpu_mem_addr), .sdram_wdata(cpu_mem_wdata), .sdram_rdata(cpu_rdata_q),
    .sdram_rd(cpu_mem_rd), .sdram_wr(cpu_mem_wr), .sdram_be(cpu_mem_be),
    .sdram_port(cpu_mem_port), .sdram_ready(cpu_ready_q), .backup_written(backup_written),
    .eeprom_rd(1'b0), .eeprom_wr({3'b000, eeprom_wr_w}), .eeprom_addr(eeprom_addr),
    .eeprom_rdata(eeprom_rdata), .eeprom_wdata(eeprom_wdata),
    .eeprom_written(eeprom_written),
    .loading(loading), .loader_data(loader_do), .loader_valid(loader_do_valid),
    .gbaon(gbaon), .config_backup_type(config_backup_type),
    .cartram_dirty(), .cartram_dirty_clear(1'b0),
    .gb_bus_din(), .gb_bus_dout(32'h0), .gb_bus_adr(), .gb_bus_rnw(), .gb_bus_ena(),
    .gb_bus_done(), .gb_bus_acc(), .gb_bus_be(), .gb_bus_rst(),
    .vram_lo_addr(), .vram_lo_din(), .vram_lo_dout(32'h0), .vram_lo_we(), .vram_lo_be(),
    .vram_hi_addr(), .vram_hi_din(), .vram_hi_dout(32'h0), .vram_hi_we(), .vram_hi_be(),
    .oamram_addr(), .oamram_din(), .oamram_dout(32'h0), .oamram_we(),
    .palette_bg_addr(), .palette_bg_din(), .palette_bg_dout(32'h0), .palette_bg_we(),
    .palette_oam_addr(), .palette_oam_din(), .palette_oam_dout(32'h0), .palette_oam_we()
);

// ---------------------------------------------------------------- SDRAM
wire [15:0] SDRAM_DQ;
wire [12:0] A;
wire [1:0] BA, DQM;
wire nCS, nWE, nRAS, nCAS;
wire busy;
wire [16:0] sdram_sv_addr;
wire  [7:0] sdram_sv_q;
wire        sdram_sv_ack;

sdram_gba sdramc (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS),
    .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_DQM(DQM),
    .clk(clk), .mclk(mclk), .resetn(resetn),
    .cpu_addr(cpu_mem_addr), .cpu_wdata(cpu_mem_wdata), .cpu_rdata(cpu_mem_rdata),
    .cpu_rd(cpu_mem_rd), .cpu_wr(cpu_mem_wr), .cpu_be(cpu_mem_be),
    .cpu_ready(cpu_mem_ready), .cpu_port(cpu_mem_port),
    .config_backup_type(config_backup_type), .backup_written(backup_written),
    .rv_addr(22'h0), .rv_din(16'h0), .rv_ds(2'b00), .rv_dout(), .rv_req(1'b0),
    .rv_req_ack(), .rv_we(1'b0),
    .sv_addr(sdram_sv_addr), .sv_din(sv_din), .sv_we(sv_we),
    .sv_req(sv_req & ~eep_save), .sv_ack(sdram_sv_ack), .sv_dout(sdram_sv_q),
    .total_refresh(), .busy(busy)
);

sdram_model sdram (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_DQM(DQM), .SDRAM_BA(BA),
    .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
    .clk(clk)
);

// ---------------------------------------------------------------- iosys
wire [17:0] sv_addr;
wire  [7:0] sv_din, sv_q;
wire        sv_we, sv_req, sv_ack, sv_core_we;

iosys_bl616 #(.FREQ(FREQ), .CORE_ID(3), .SAVE_IF(1), .SAVE_AW(18), .SAVE_SYNC(0)) iosys (
    .clk(mclk), .hclk(mclk), .resetn(resetn),
    .overlay(), .overlay_x(8'h00), .overlay_y(8'h00), .overlay_color(),
    .joy1(12'b0), .joy2(12'b0), .hid1(), .hid2(),
    .rom_loading(rom_loading), .rom_do(loader_do), .rom_do_valid(loader_do_valid),
    .core_config(),
    .mgmt_readdata(16'h0), .fdd_request(2'b00), .kbd_data(8'h0),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we), .sv_q(sv_q),
    .sv_core_we(sv_core_we), .sv_req(sv_req), .sv_ack(sv_ack),
    .uart_rx(uart_rx), .uart_tx(uart_tx)
);

// ---- gbatang_top.sv battery-save glue (copy; run.sh checks the originals) ----
wire eep_save = config_backup_type == 3'd4;
assign sdram_sv_addr = sv_addr[16:0];
assign sv_q = eep_save ? eeprom_rdata : sdram_sv_q;
assign sv_ack = eep_save ? sv_req : sdram_sv_ack;
reg sv_req_d = 0;
always @(posedge mclk) sv_req_d <= sv_req;
assign eeprom_wr_w  = (sv_req ^ sv_req_d) & sv_we & eep_save;
assign eeprom_addr  = sv_addr[12:0];
assign eeprom_wdata = sv_din;
reg [2:0] bw_s = 3'b000;
always @(posedge mclk) bw_s <= {bw_s[1:0], backup_written};
assign sv_core_we = (bw_s[1] & ~bw_s[2]) | (eeprom_written & eep_save);
// ---- end of copy ----

// ---------------------------------------------------------------- UART capture
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

function [7:0] pat(input [7:0] seed, input integer i);
    pat = seed + i[7:0];
endfunction

task restore(input [15:0] blk, input [7:0] seed);
    integer k;
begin
    send_hdr(16'd515, 8'h11); tx_byte(blk[15:8]); tx_byte(blk[7:0]);
    for (k = 0; k < 512; k = k + 1) tx_byte(pat(seed, k));
end
endtask

task request_dump(input [15:0] blk);
begin
    send_hdr(16'd3, 8'h12); tx_byte(blk[15:8]); tx_byte(blk[7:0]);
end
endtask

task set_loading(input [7:0] s);
begin
    send_hdr(16'd2, 8'h06); tx_byte(s);
end
endtask

task send_data(input integer n, input [7:0] seed);   // loader bytes (cmd 7)
    integer k;
begin
    send_hdr(n + 1, 8'h07);
    for (k = 0; k < n; k = k + 1) tx_byte(pat(seed, k));
end
endtask

task wait_for(input integer want);
    integer t;
begin
    t = 0;
    while (ncap < want && t < 400_000) begin @(posedge mclk); t = t + 1; end
    if (ncap < want) begin
        errs = errs + 1;
        $display("FAIL: timeout waiting for UART byte %0d (have %0d) t=%0t", want, ncap, $time);
        $fatal(1, "tb_gba_saves: FAIL, %0d errors", errs);
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
        $display("FAIL: uart byte %0d = %02x, expected %02x (t=%0t)", rcnt - 1, b, e, $time);
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

// no UART traffic is pending: nothing but what the test expects may arrive
task expect_quiet(input integer cycles);
    integer n0;
begin
    n0 = ncap;
    repeat (cycles) @(posedge mclk);
    if (ncap != n0 || ncap != rcnt) begin
        errs = errs + 1;
        $display("FAIL: unexpected UART traffic: %0d bytes arrived (unread %0d) t=%0t",
                 ncap - n0, ncap - rcnt, $time);
        rcnt = ncap;
    end
end
endtask

// dump block `blk`; expect(k) = the byte at offset k, supplied by a mask:
// every byte equals pat(seed,k) except patch bytes poked in `pk_off[i]`.
integer pk_n = 0;
integer pk_off [0:7];
reg [7:0] pk_val [0:7];
task patches_clear; begin pk_n = 0; end endtask
task patch(input integer off, input [7:0] v);
begin pk_off[pk_n] = off; pk_val[pk_n] = v; pk_n = pk_n + 1; end
endtask

task check_dump(input [15:0] blk, input [7:0] seed, input fill_ff);
    integer k, i;
    reg [7:0] e;
begin
    request_dump(blk);
    dump_header(blk);
    for (k = 0; k < 512; k = k + 1) begin
        e = fill_ff ? 8'hFF : pat(seed, k);
        for (i = 0; i < pk_n; i = i + 1) if (pk_off[i] == k) e = pk_val[i];
        expect_byte(e);
    end
    patches_clear;
end
endtask

// ---------------------------------------------------------------- the CPU
// gba_cpu raises rom_en for the next instruction while a load/store runs, and
// game code that writes the flash/EEPROM runs from RAM, so the data access
// normally arrives as the second half of a ROM+RAM pair (gba_memory REQ2_*).
// That matters for flash command writes: the RAM-only path (cpu_fetch = 0)
// holds sdram_wr for two mclk periods, REQ2_START only for one.
reg cpu_fetch = 1;
reg [31:0] rd_val;
task cpu_ram(input wr, input [27:0] addr, input [31:0] wd, input [3:0] be);
    integer t;
begin
    @(posedge mclk);
    ram_cen <= 1; ram_wen <= wr; ram_addr <= {4'b0, addr}; ram_wdata <= wd; ram_be <= be;
    if (cpu_fetch) begin rom_en <= 1; rom_addr <= 32'h0300_0100; thumb <= 1; end
    t = 0;
    @(posedge mclk);
    while (!cpu_en && t < 400000) begin @(posedge mclk); t = t + 1; end
    if (!cpu_en) begin
        errs = errs + 1;
        $display("FAIL: cpu_en never came, wr=%b addr=%07h t=%0t", wr, addr, $time);
        $fatal(1, "tb_gba_saves: FAIL, %0d errors", errs);
    end
    ram_cen <= 0; ram_wen <= 0; rom_en <= 0;
    @(posedge mclk);                      // the data is on ram_rdata the cycle after cpu_en
    rd_val = ram_rdata;
    repeat (2) @(posedge mclk);
end
endtask

// byte store / load the way gba_cpu issues them: data replicated, one-hot be
task cpu_wr8(input [27:0] addr, input [7:0] v);
begin cpu_ram(1'b1, addr, {4{v}}, 4'b0001 << addr[1:0]); end
endtask

task cpu_rd8(input [27:0] addr, input [7:0] e);
    reg [7:0] got;
begin
    cpu_ram(1'b0, addr, 32'h0, 4'b0001 << addr[1:0]);
    got = rd_val >> (8 * addr[1:0]);
    if (got !== e) begin
        errs = errs + 1;
        $display("FAIL: cpu read8 %07h = %02x, expected %02x (type %0d, t=%0t)",
                 addr, got, e, config_backup_type, $time);
    end
end
endtask

// ---- flash chip protocol, as the BIOS/save library issues it ----
localparam [27:0] CART = 28'hE00_0000;
task fl_unlock;
begin cpu_wr8(CART + 28'h5555, 8'hAA); cpu_wr8(CART + 28'h2AAA, 8'h55); end
endtask
task fl_cmd(input [7:0] c);
begin fl_unlock; cpu_wr8(CART + 28'h5555, c); end
endtask
task fl_program(input [15:0] x, input [7:0] v);
begin fl_cmd(8'hA0); cpu_wr8(CART + x, v); end
endtask
task fl_sector_erase(input [15:0] x);
begin fl_cmd(8'h80); fl_unlock; cpu_wr8(CART + x, 8'h30); end
endtask
task fl_chip_erase;
begin fl_cmd(8'h80); fl_unlock; cpu_wr8(CART + 28'h5555, 8'h10); end
endtask
task fl_bank(input b);
begin fl_cmd(8'hB0); cpu_wr8(CART, {7'b0, b}); end
endtask

// ---- EEPROM serial protocol: one bit per halfword access in region D ----
task ee_bit(input b);
begin cpu_ram(1'b1, 28'hD00_0000, {31'b0, b}, 4'b0011); end
endtask
task ee_write_block(input [13:0] a, input [63:0] data);
    integer k;
begin
    ee_bit(1); ee_bit(0);
    for (k = 13; k >= 0; k = k - 1) ee_bit(a[k]);
    for (k = 63; k >= 0; k = k - 1) ee_bit(data[k]);
    ee_bit(0);
end
endtask
task ee_read_block(input [13:0] a, input [63:0] e);
    integer k;
    reg [63:0] got;
begin
    ee_bit(1); ee_bit(1);
    for (k = 13; k >= 0; k = k - 1) ee_bit(a[k]);
    ee_bit(0);
    for (k = 0; k < 4; k = k + 1) cpu_ram(1'b0, 28'hD00_0000, 32'h0, 4'b0011);
    for (k = 63; k >= 0; k = k - 1) begin
        cpu_ram(1'b0, 28'hD00_0000, 32'h0, 4'b0011);
        got[k] = rd_val[0];
    end
    if (got !== e) begin
        errs = errs + 1;
        $display("FAIL: eeprom serial block %0d = %h, expected %h", a, got, e);
    end
end
endtask

// ---------------------------------------------------------------- loading
reg bios_sent = 0;
task load_game(input [7:0] btype);      // firmware's loadgba(), up to the restores
begin
    set_loading(1);
    send_data(16, 8'h40);                       // a few ROM bytes
    if (!bios_sent) begin                       // gba_load_bios(): first game only
        set_loading(4);
        send_data(8, 8'h77);
        bios_sent = 1;
    end
    set_loading(3);                             // backup type, after the ROM
    send_data(1, btype);
end
endtask

task start_game;
    integer t;
begin
    set_loading(0);
    t = 0;
    while (!gbaon && t < 100000) begin @(posedge mclk); t = t + 1; end
    if (!gbaon) begin
        errs = errs + 1;
        $display("FAIL: gbaon never came up");
        $fatal(1, "tb_gba_saves: FAIL, %0d errors", errs);
    end
    repeat (20) @(posedge mclk);
end
endtask

task expect_type(input [2:0] t);
begin
    if (config_backup_type !== t) begin
        errs = errs + 1;
        $display("FAIL: backup type is %0d, expected %0d", config_backup_type, t);
    end
end
endtask

// ---------------------------------------------------------------- CPU load
// back-to-back fetches from the cartridge ROM, like gba_cpu running game code
// out of the SDRAM: the next address is presented the cycle after cpu_en
// mode: 0 off | 1 ARM | 2 Thumb | 3 Thumb + an IWRAM load every 8th instruction
//       | 4 Thumb + an EWRAM (SDRAM) load every 4th | 5 ARM + EWRAM load every 4th
reg [2:0]  bg_mode = 0;
reg        bg_on = 0;
reg [31:0] bg_pc = 32'h0800_0000;
integer    bg_n = 0;
wire       bg_thumb = (bg_mode == 2 || bg_mode == 3 || bg_mode == 4);
wire       bg_ldr   = (bg_mode == 3) ? (bg_n % 8 == 0) : (bg_mode == 4 || bg_mode == 5) ? (bg_n % 4 == 0) : 1'b0;
wire [31:0] bg_dbase = (bg_mode == 3) ? 32'h0300_0040 : 32'h0200_0040;
always @(posedge mclk) begin
    if (bg_mode != 0 && !bg_on) begin
        rom_en <= 1; rom_addr <= bg_pc; thumb <= bg_thumb;
        ram_cen <= 0; bg_n <= 0; bg_on <= 1;
    end else if (bg_mode != 0 && cpu_en) begin
        bg_pc <= bg_pc + (bg_thumb ? 2 : 4);
        rom_addr <= bg_pc + (bg_thumb ? 2 : 4);
        bg_n <= bg_n + 1;
        // the next instruction: with or without a data access
        if (((bg_mode == 3) ? ((bg_n + 1) % 8 == 0) : (bg_mode >= 4) ? ((bg_n + 1) % 4 == 0) : 0)) begin
            ram_cen <= 1; ram_wen <= 0; ram_be <= 4'b1111;
            ram_addr <= ((bg_mode == 3) ? 32'h0300_0040 : 32'h0200_0040) + ((bg_n * 4) & 32'hFC);
        end else
            ram_cen <= 0;
    end else if (bg_mode == 0 && bg_on) begin
        rom_en <= 0; ram_cen <= 0; bg_on <= 0;
    end
end

// how busy the CPU keeps the SDRAM request strobes: mclk periods with rd|wr up
integer strobe_cyc = 0, all_cyc = 0;
always @(posedge mclk) begin
    all_cyc <= all_cyc + 1;
    if (cpu_mem_rd | cpu_mem_wr) strobe_cyc <= strobe_cyc + 1;
end

time t_start;
integer r0, a0;
task timed_dump(input [15:0] blk, input [7:0] seed, input integer limit_us);
    time dt;
begin
    t_start = $time; r0 = strobe_cyc; a0 = all_cyc;
    check_dump(blk, seed, 0);
    dt = ($time - t_start) / 1000;
    $display("  block %0d dump under load (mode %0d): %0d us (idle ~2900); request strobe up in %0d of %0d mclk periods",
             blk, bg_mode, dt, strobe_cyc - r0, all_cyc - a0);
    if (dt > limit_us) begin
        errs = errs + 1;
        $display("FAIL: dump took %0d us under CPU load, limit %0d", dt, limit_us);
    end
end
endtask

// ---------------------------------------------------------------- the tests
integer k;
reg [63:0] sd;
initial begin
    // model FF power-on state (Gowin FFs come up 0; these regs have no reset)
    iosys.send_idx = 0; iosys.response_req = 0; iosys.response_ack = 0;
    iosys.joy1_reg = 0; iosys.joy2_reg = 0; iosys.send_state_next = 0;
    mem.state = 0;

    repeat (10) @(posedge clk);
    resetn = 1;
    wait (busy == 0);                     // SDRAM init done (200 us)
    repeat (50) @(posedge mclk);

    // ============================================================= SRAM
    $display("T1 SRAM start t=%0t", $time);
    load_game(8'd3);
    restore(16'd0, 8'h10);
    restore(16'd5, 8'h20);
    restore(16'd63, 8'h30);
    start_game;
    expect_type(3'd3);
    // restore -> game: the CPU reads what the MCU put there, odd and even bytes
    cpu_rd8(CART + 0,              pat(8'h10, 0));
    cpu_rd8(CART + 1,              pat(8'h10, 1));
    cpu_rd8(CART + 2,              pat(8'h10, 2));
    cpu_rd8(CART + 3,              pat(8'h10, 3));
    cpu_rd8(CART + 5*512 + 1,      pat(8'h20, 1));
    cpu_rd8(CART + 5*512 + 254,    pat(8'h20, 254));
    cpu_rd8(CART + 63*512 + 511,   pat(8'h30, 511));
    cpu_rd8(28'hF00_0000 + 5*512 + 2, pat(8'h20, 2));      // region F mirror
    expect_quiet(2000);                                    // reads dirty nothing
    // game -> dump: first write notifies, the rest of the burst does not
    cpu_wr8(CART + 5*512 + 7, 8'hD3);                      // odd
    expect_dirty;
    cpu_wr8(CART + 5*512 + 8, 8'hE4);                      // even
    cpu_wr8(28'hF00_0000 + 5*512 + 9, 8'hF5);              // via the F mirror
    cpu_wr8(CART + 63*512 + 511, 8'h9A);
    cpu_rd8(CART + 5*512 + 7, 8'hD3);
    patch(7, 8'hD3); patch(8, 8'hE4); patch(9, 8'hF5);
    check_dump(16'd5, 8'h20, 0);
    patch(511, 8'h9A);
    check_dump(16'd63, 8'h30, 0);
    check_dump(16'd0, 8'h10, 0);                           // block 0 starts clean
    expect_quiet(2000);
    cpu_wr8(CART + 3, 8'h66);                              // new dirty period
    expect_dirty;
    patch(3, 8'h66);
    check_dump(16'd0, 8'h10, 0);

    // dump while the CPU fetches from the SDRAM flat out
    $display("T1b starvation start t=%0t", $time);
    begin : load_modes
        integer m, i;
        for (i = 0; i < 5; i = i + 1) begin
            m = (i == 0) ? 1 : (i == 1) ? 3 : (i == 2) ? 4 : (i == 3) ? 5 : 2;
            bg_mode = 0; repeat (20) @(posedge mclk);
            bg_mode = m; repeat (200) @(posedge mclk);
            patch(7, 8'hD3); patch(8, 8'hE4); patch(9, 8'hF5);
            timed_dump(16'd5, 8'h20, 12000);
        end
        bg_mode = 0; repeat (200) @(posedge mclk);
    end
    expect_quiet(2000);

    // ============================================================= FLASH 512K
    $display("T2 FLASH512K start t=%0t", $time);
    load_game(8'd1);
    restore(16'd0, 8'h40);
    restore(16'd127, 8'h50);
    start_game;
    expect_type(3'd1);
    // the chip answers the library's ID probe only because the type got there
    fl_cmd(8'h90);
    cpu_rd8(CART + 0, 8'h32);
    cpu_rd8(CART + 1, 8'h1B);
    fl_cmd(8'hF0);
    cpu_rd8(CART + 0, pat(8'h40, 0));
    expect_quiet(2000);                                    // commands alone dirty nothing
    cpu_rd8(CART + 127*512 + 4, pat(8'h50, 4));
    // byte program
    fl_program(16'hFE03, 8'h5A);
    expect_dirty;
    cpu_rd8(CART + 16'hFE03, 8'h5A);
    patch(3, 8'h5A);
    check_dump(16'd127, 8'h50, 0);
    check_dump(16'd0, 8'h40, 0);                           // clean again
    // sector erase of 0xF000..0xFFFF (4KB), which holds block 127
    fl_sector_erase(16'hF000);
    expect_dirty;
    cpu_rd8(CART + 16'hFE03, 8'hFF);
    cpu_rd8(CART + 16'hF000, 8'hFF);
    check_dump(16'd127, 8'h50, 1);
    check_dump(16'd0, 8'h40, 0);

    // The same chip protocol with RAM-only accesses (no instruction fetch
    // overlapped): gba_memory holds sdram_wr for two mclk periods there, and the
    // chip must still see each command once.
    $display("T2b FLASH512K, RAM-only accesses start t=%0t", $time);
    cpu_fetch = 0;
    load_game(8'd1);
    restore(16'd0, 8'h44);
    start_game;
    fl_cmd(8'h90);
    cpu_rd8(CART + 0, 8'h32);
    cpu_rd8(CART + 1, 8'h1B);
    fl_cmd(8'hF0);
    cpu_rd8(CART + 4, pat(8'h44, 4));
    expect_quiet(2000);
    fl_program(16'h0123, 8'h77);
    expect_dirty;
    patch(16'h123, 8'h77);
    check_dump(16'd0, 8'h44, 0);
    cpu_fetch = 1;

    // ============================================================= FLASH 1M
    $display("T3 FLASH1M start t=%0t", $time);
    load_game(8'd2);
    restore(16'd0, 8'h60);
    restore(16'd130, 8'h70);                               // bank 1
    restore(16'd255, 8'h80);                               // bank 1, last block
    start_game;
    expect_type(3'd2);
    fl_cmd(8'h90);
    cpu_rd8(CART + 0, 8'h62);
    cpu_rd8(CART + 1, 8'h13);
    fl_cmd(8'hF0);
    cpu_rd8(CART + 0, pat(8'h60, 0));                      // bank 0
    fl_bank(1);
    cpu_rd8(CART + 2*512 + 5,   pat(8'h70, 5));            // block 130 = bank 1 + 0x400
    cpu_rd8(CART + 127*512 + 9, pat(8'h80, 9));            // block 255
    expect_quiet(2000);
    fl_program(16'h0410, 8'h3C);                           // bank 1
    expect_dirty;
    patch(16, 8'h3C);
    check_dump(16'd130, 8'h70, 0);
    check_dump(16'd0, 8'h60, 0);                           // bank 0 untouched, clears dirty
    fl_bank(0);
    cpu_rd8(CART + 5, pat(8'h60, 5));                      // bank 0 again
    fl_chip_erase;
    expect_dirty;
    check_dump(16'd130, 8'h70, 1);
    check_dump(16'd255, 8'h80, 1);
    check_dump(16'd0, 8'h60, 1);

    // T3b: the flash bank parks at 0 for the next game. Leave bank 1 selected,
    // reload as FLASH512, and the ID probe + reads must see bank 0 (without
    // the park they read bank 1's stale data and the probe misses its address).
    fl_bank(1);
    $display("T3b bank reset start t=%0t", $time);
    load_game(8'd1);
    restore(16'd0, 8'h90);
    start_game;
    expect_type(3'd1);
    fl_cmd(8'h90);
    cpu_rd8(CART + 0, 8'h32);
    cpu_rd8(CART + 1, 8'h1B);
    fl_cmd(8'hF0);
    cpu_rd8(CART + 0, pat(8'h90, 0));
    cpu_rd8(CART + 4, pat(8'h90, 4));
    expect_quiet(2000);

    // ============================================================= EEPROM
    $display("T4 EEPROM start t=%0t", $time);
    load_game(8'd4);
    restore(16'd0, 8'h5C);
    restore(16'd1, 8'hE1);
    start_game;
    expect_type(3'd4);
    // the serial chip sees the restored bytes: block 3 = bytes 24..31
    ee_read_block(14'd3, {pat(8'h5C,24), pat(8'h5C,25), pat(8'h5C,26), pat(8'h5C,27),
                          pat(8'h5C,28), pat(8'h5C,29), pat(8'h5C,30), pat(8'h5C,31)});
    expect_quiet(2000);
    ee_write_block(14'd5, 64'h0123456789abcdef);
    expect_dirty;
    sd = 64'h0123456789abcdef;
    for (k = 0; k < 8; k = k + 1) patch(40 + k, sd[63 - k * 8 -: 8]);
    check_dump(16'd0, 8'h5C, 0);
    check_dump(16'd1, 8'hE1, 0);
    ee_read_block(14'd5, 64'h0123456789abcdef);

    // ============================================================= SRAM again
    // the save port mux flips back from the EEPROM to the SDRAM client
    $display("T5 SRAM after EEPROM start t=%0t", $time);
    load_game(8'd3);
    restore(16'd2, 8'hA0);
    start_game;
    expect_type(3'd3);
    cpu_rd8(CART + 2*512 + 100, pat(8'hA0, 100));
    cpu_wr8(CART + 2*512 + 101, 8'h12);
    expect_dirty;
    patch(101, 8'h12);
    check_dump(16'd2, 8'hA0, 0);
    expect_quiet(2000);

    if (errs == 0) $display("tb_gba_saves: PASS");
    else $fatal(1, "tb_gba_saves: FAIL, %0d errors", errs);
    $finish;
end

initial begin #(400_000_000); $fatal(1, "TIMEOUT: sim hang"); end
endmodule
