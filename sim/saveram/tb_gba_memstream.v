// CPU-side access streams through the REAL gba_memory into the REAL sdram_gba
// and a behavioral SDRAM: checks that a CPU access reaches the controller
// exactly once and measures what each access costs, in mclk periods.
//
// Why it exists: gba_memory holds a RAM/ROM access's sdram_rd/sdram_wr strobe
// for a second mclk period (the buffered copy it drives in REQ1_WAIT), and
// sdram_gba arbitrates once per mclk period. Unless the controller recognises
// the held copy as a repeat, a served one-halfword request runs again: a flash
// command write twice (AA,AA breaks the unlock sequence), any write or read
// twice on the SDRAM bus, and the repeat takes the slot the refresh and the
// save client were waiting for. The mask that suppresses the repeat must not
// also delay a genuinely new request that follows right behind a served one.
// tb_sdram_save / tb_gba_saves can't see either effect (the first drives
// sdram_gba from a hand-made strobe, the second has gaps between accesses), so
// this bench drives gba_memory's CPU port back to back:
//
//   * a CPU stub that presents the next request in the very cycle after cpu_en
//     (the fastest the CPU can go), in all three shapes gba_cpu produces:
//     ROM only, RAM only (strobe held two periods), ROM+RAM (REQ2, one period);
//   * ROM fetches (ARM, Thumb, random), EWRAM/IWRAM 8/16/32-bit reads and
//     writes, SRAM byte writes to 0x0E000000, FLASH512/FLASH1M unlock +
//     program/ID/bank-switch/sector-erase, and a random mix of everything;
//   * the controller side is instrumented (run.sh injects event counters into
//     a copy of sdram_gba): CPU requests accepted, flash-FSM command runs,
//     erase slots; plus a monitor on the SDRAM command bus.
//
// Checks (all fatal): read data and the SDRAM contents match a reference;
// every request is accepted exactly once (accepts == requests, flash FSM runs
// == flash command writes, bus ACT/RD/WR == halfwords expected); no held
// strobe is ever served again; no fresh strobe is ever left unserved for its
// first slot; refresh and the RV/save clients still get slots while the CPU
// goes flat out; no stream takes more mclk periods than the pre-fix controller
// did (base_of(), measured with `./run.sh tb_gba_memstream_prefix`, which runs
// this bench against sdram_gba.v from before ecf535e and is expected to fail).
//
// Clocks: clk is the 67.12MHz SDRAM clock and mclk = clk/4, derived one delta
// after clk. sdram_gba arbitrates on the clk edge that coincides with mclk's
// rising edge (the phase the header diagram of sdram_gba.v and the SDC's
// 4-cycle clk16<->clk67 paths describe), gba_memory flops on mclk: in
// hardware each side samples the other's pre-edge value. The sdram_gba ->
// gba_memory direction needs shadow registers here (captured mid-period, when
// nothing moves) so that the result does not depend on delta ordering.
// IVFLAGS=-DPHASE_B moves the slot one clk earlier as a diagnostic; neither the
// pre-fix nor the fixed controller works there (the REQ2 streams deadlock).

`timescale 1ns/1ps

module tb_gba_memstream;

`ifdef PREFIX
localparam PRE = 1;                 // reporting run against the pre-fix controller
`else
localparam PRE = 0;
`endif

// ---------------------------------------------------------------- clocks
reg clk = 0;
always #7.4493 clk = ~clk;          // 67.12MHz
reg [1:0] ph = 0;
always @(posedge clk) ph <= ph + 2'd1;
reg mclk = 0;
always @(posedge clk) mclk <= ph[1];    // clk/4, one delta after clk
// What sdram_gba sees as mclk. Normally the same signal: it spots the rising edge one clk
// late, so its arbitration slot (cycle[3]) lands ON mclk's next rising edge, which is the
// phase the SDC's 4-cycle clk16<->clk67 paths and the header's timing diagram describe.
// -DPHASE_B hands it mclk one clk early, putting the slot one clk BEFORE mclk's edge: a
// diagnostic for how much the arbitration depends on that phase (see the report).
reg mclk_s = 0;
`ifdef PHASE_B
always @(posedge clk) mclk_s <= (ph + 2'd1) >> 1;
localparam [3:0] SLOT_CYCLE = 4'b0010;  // sdram_gba's one-hot cycle at mclk's rising edge
`else
always @(*) mclk_s = mclk;
localparam [3:0] SLOT_CYCLE = 4'b0001;
`endif

reg resetn = 0;

// ---------------------------------------------------------------- CPU port
reg         rom_en = 0, thumb = 0, ram_cen = 0, ram_wen = 0;
reg  [31:0] rom_addr = 0, ram_addr = 0, ram_wdata = 0;
reg   [3:0] ram_be = 0;
wire [31:0] rom_data, ram_rdata;
wire        cpu_en;

reg   [2:0] loading = 0;
reg   [7:0] loader_data = 0;
reg         loader_valid = 0;
wire  [2:0] config_backup_type;

// ---------------------------------------------------------------- gba_memory
wire  [1:0] cpu_mem_port;
wire [25:2] cpu_mem_addr;
wire [31:0] cpu_mem_wdata;
wire [31:0] cpu_mem_rdata [1:3];
wire  [3:0] cpu_mem_be;
wire        cpu_mem_rd, cpu_mem_wr, cpu_mem_ready;
wire        backup_written;

// sdram_gba's outputs change at clk edges that coincide with mclk's; gba_memory
// must see the values from before that edge (see header). They only ever change
// on those edges, so a copy taken at the falling clk edge IS the pre-edge value.
reg         cpu_ready_q = 0;
reg  [31:0] cpu_rdata_q [1:3];
always @(negedge clk) begin
    cpu_ready_q    <= cpu_mem_ready;
    cpu_rdata_q[1] <= cpu_mem_rdata[1];
    cpu_rdata_q[2] <= cpu_mem_rdata[2];
    cpu_rdata_q[3] <= cpu_mem_rdata[3];
end

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
    .eeprom_rd(1'b0), .eeprom_wr(4'b0000), .eeprom_addr(13'h0),
    .eeprom_rdata(), .eeprom_wdata(8'h0), .eeprom_written(),
    .loading(loading), .loader_data(loader_data), .loader_valid(loader_valid),
    .gbaon(), .config_backup_type(config_backup_type),
    .cartram_dirty(), .cartram_dirty_clear(1'b0),
    .gb_bus_din(), .gb_bus_dout(32'h0), .gb_bus_adr(), .gb_bus_rnw(), .gb_bus_ena(),
    .gb_bus_done(), .gb_bus_acc(), .gb_bus_be(), .gb_bus_rst(),
    .vram_lo_addr(), .vram_lo_din(), .vram_lo_dout(32'h0), .vram_lo_we(), .vram_lo_be(),
    .vram_hi_addr(), .vram_hi_din(), .vram_hi_dout(32'h0), .vram_hi_we(), .vram_hi_be(),
    .oamram_addr(), .oamram_din(), .oamram_dout(32'h0), .oamram_we(),
    .palette_bg_addr(), .palette_bg_din(), .palette_bg_dout(32'h0), .palette_bg_we(),
    .palette_oam_addr(), .palette_oam_din(), .palette_oam_dout(32'h0), .palette_oam_we()
);

// ---------------------------------------------------------------- SDRAM side
wire [15:0] SDRAM_DQ;
wire [12:0] A;
wire  [1:0] BA, DQM;
wire        nCS, nWE, nRAS, nCAS;
wire        busy;

// background clients: the RV softcore and the iosys save channel (reads only)
reg  [16:0] sv_addr_r = 0;
reg         sv_req_r = 0;
reg  [22:1] rv_addr_r = 22'h001000;
reg         rv_req_r = 0;
wire        sv_ack, rv_ack;

sdram_gba sdramc (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS),
    .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_DQM(DQM),
    .clk(clk), .mclk(mclk_s), .resetn(resetn),
    .cpu_addr(cpu_mem_addr), .cpu_wdata(cpu_mem_wdata), .cpu_rdata(cpu_mem_rdata),
    .cpu_rd(cpu_mem_rd), .cpu_wr(cpu_mem_wr), .cpu_be(cpu_mem_be),
    .cpu_ready(cpu_mem_ready), .cpu_port(cpu_mem_port),
    .config_backup_type(config_backup_type), .backup_written(backup_written),
    .rv_addr(rv_addr_r), .rv_din(16'h0), .rv_ds(2'b11), .rv_dout(), .rv_req(rv_req_r),
    .rv_req_ack(rv_ack), .rv_we(1'b0),
    .sv_addr(sv_addr_r), .sv_din(8'h0), .sv_we(1'b0),
    .sv_req(sv_req_r), .sv_ack(sv_ack), .sv_dout(),
    .total_refresh(), .busy(busy)
);

sdram_model #(.ROM_PAT(1)) sdram (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_DQM(DQM), .SDRAM_BA(BA),
    .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
    .clk(clk)
);

// power-on state of the flops the RTL leaves uninitialized (FFs start at 0 on the FPGA)
initial begin
    sdramc.refresh_cnt = 0;
    sdramc.rv_req_ack = 0;
    mem.state = 0;                      // gba_memory's state machine has no reset either
    mem.double_req = 0;
    mem.dma_sdram = 0;
end

// ---------------------------------------------------------------- monitors
// SDRAM command bus
integer n_act = 0, n_rd = 0, n_wr = 0, n_ref = 0;
always @(posedge clk) begin
    case ({nCS, nRAS, nCAS, nWE})
    4'b0011, 4'b1011: n_act = n_act + 1;
    4'b0100, 4'b1100: n_wr  = n_wr + 1;
    4'b0101, 4'b1101: n_rd  = n_rd + 1;
    4'b0001:          n_ref = n_ref + 1;      // chip 0 refresh = one refresh round
    default: ;
    endcase
end

// Per mclk edge, from the controller's point of view: is the strobe it
// arbitrates a fresh request (gba_memory in MAIN/REQ1_START/REQ2_START) or the
// held copy of one already presented (REQ1_WAIT)? and did the controller
// accept a request at this edge? Evaluated at mclk's rising edge: sdram_gba
// ran its slot on the clk edge just before, gba_memory has not moved yet.
integer acc_prev = 0;
integer n_fresh = 0, n_fresh_unserved = 0, n_held = 0, n_held_served = 0, n_phase = 0;
integer cyc = 0;
always @(posedge mclk) begin : mon
    integer acc_now;
    reg strobe, held, served;
    cyc <= cyc + 1;
    acc_now = sdramc.dbg_cpu_acc + sdramc.dbg_flash_cmds;
    served = acc_now != acc_prev;
    acc_prev = acc_now;
    strobe = cpu_mem_rd | cpu_mem_wr;
    held = mem.state == 3'd2;                       // REQ1_WAIT
    if (strobe &  held) begin n_held  = n_held  + 1; if (served)  n_held_served    = n_held_served + 1; end
    if (strobe & ~held) begin n_fresh = n_fresh + 1; if (!served) n_fresh_unserved = n_fresh_unserved + 1; end
    // sdram_gba's slot (cycle[3]) must stay where the phase put it
    if (cyc > 100 && sdramc.cycle[3:0] != SLOT_CYCLE) n_phase = n_phase + 1;
end

// background clients: one outstanding request each, re-issued when served
integer bg_t = 0, bg_sv_n = 0, bg_rv_n = 0;
reg bg_en = 0, sv_ack_d = 0, rv_ack_d = 0;
always @(posedge clk) begin
    sv_ack_d <= sv_ack; rv_ack_d <= rv_ack;
    if (sv_ack != sv_ack_d) bg_sv_n <= bg_sv_n + 1;
    if (rv_ack != rv_ack_d) bg_rv_n <= bg_rv_n + 1;
    if (bg_en) begin
        bg_t <= bg_t + 1;
        if (sv_req_r == sv_ack && bg_t[4:0] == 5'd7) begin
            sv_req_r <= ~sv_req_r; sv_addr_r <= sv_addr_r + 17'd37;
        end
        if (rv_req_r == rv_ack && bg_t[4:0] == 5'd19) begin
            rv_req_r <= ~rv_req_r; rv_addr_r <= rv_addr_r + 22'd3;
        end
    end
end

// ---------------------------------------------------------------- reference memories
reg [7:0] ew [0:65535];                 // EWRAM, first 64KB
reg [7:0] iw [0:4095];                  // IWRAM, first 4KB
reg [7:0] cr [0:131071];                // cart RAM: SRAM, flash bank 0/1
reg       g_bank = 0;                   // flash bank the build is currently in

function [7:0] getb(input [27:0] a);
    case (a[27:24])
    4'h2:    getb = ew[a[15:0]];
    4'h3:    getb = iw[a[11:0]];
    default: getb = cr[{g_bank, a[15:0]}];
    endcase
endfunction

task putb(input [27:0] a, input [7:0] v);
begin
    case (a[27:24])
    4'h2:    ew[a[15:0]] = v;
    4'h3:    iw[a[11:0]] = v;
    default: cr[{g_bank, a[15:0]}] = v;
    endcase
end
endtask

function sdram_space(input [27:0] a);
    sdram_space = (a[27:24] == 4'h2) || (a[27:24] >= 4'hE);
endfunction

task init_ram;                          // EWRAM + IWRAM known contents, model and reference
    integer k;
begin
    for (k = 0; k < 65536; k = k + 1) ew[k] = k * 5 + 1;
    for (k = 0; k < 4096;  k = k + 1) iw[k] = k * 3 + 7;
    for (k = 0; k < 32768; k = k + 1) sdram.mem[k] = {ew[2*k+1], ew[2*k]};
    for (k = 0; k < 1024;  k = k + 1) mem.iwram.mem[k] = {iw[4*k+3], iw[4*k+2], iw[4*k+1], iw[4*k]};
end
endtask

task init_cart(input [7:0] seed, input fill);   // cart RAM: fill=1 -> FF (erased flash), else pattern
    integer k;
begin
    for (k = 0; k < 131072; k = k + 1) cr[k] = fill ? 8'hFF : (k * 11 + seed);
    for (k = 0; k < 65536; k = k + 1)
        sdram.mem[24'h020000 + k] = {cr[2*k+1], cr[2*k]};     // bank 0 at +0, bank 1 at +0x8000
end
endtask

// compare the model's EWRAM / cart RAM contents with the reference
integer mism = 0;
task verify_mem(input integer banks);
    integer k;
    reg [15:0] w;
begin
    for (k = 0; k < 32768; k = k + 1) begin
        w = sdram.mem[k];
        if (w !== {ew[2*k+1], ew[2*k]}) begin
            if (mism < 8) $display("  MISMATCH ewram halfword %0d: sdram %04x ref %04x", k, w, {ew[2*k+1], ew[2*k]});
            mism = mism + 1;
        end
    end
    for (k = 0; k < 32768 * banks; k = k + 1) begin
        w = sdram.mem[24'h020000 + k];
        if (w !== {cr[2*k+1], cr[2*k]}) begin
            if (mism < 8) $display("  MISMATCH cart halfword %0d: sdram %04x ref %04x", k, w, {cr[2*k+1], cr[2*k]});
            mism = mism + 1;
        end
    end
end
endtask

// ---------------------------------------------------------------- request queue
localparam QN = 2048;
reg        q_rom [0:QN-1];
reg [31:0] q_raddr [0:QN-1];
reg        q_th [0:QN-1];
reg        q_ram [0:QN-1];
reg        q_wr [0:QN-1];
reg [31:0] q_aaddr [0:QN-1];
reg [31:0] q_wd [0:QN-1];
reg  [3:0] q_be [0:QN-1];
integer    q_gap [0:QN-1];
reg [31:0] q_erom [0:QN-1], q_mrom [0:QN-1];
reg [31:0] q_eram [0:QN-1], q_mram [0:QN-1];
integer    q_n = 0;
integer    exp_acc = 0;                 // requests that must reach sdram_gba's arbitration
integer    exp_cmds = 0;                // ... of which flash FSM commands
integer    exp_act = 0;                 // SDRAM halfword transactions (ACT + RD/WR each)
reg        skip_act = 0;                // stream with erase: the bus count includes the erase writes

// fetch attached to every request: 0 none, 1 Thumb from SDRAM ROM, 2 ARM from SDRAM ROM, 3 Thumb from IWRAM
integer fm = 0;
integer pc = 0, ipc = 0;
reg     g_fl = 0;                       // the request being built is a flash command write

task attach_fetch(input integer i);
begin
    q_rom[i] = fm != 0;
    q_th[i] = fm == 1 || fm == 3;
    q_erom[i] = 0; q_mrom[i] = 0;
    q_raddr[i] = 0;
    case (fm)
    1: begin
        q_raddr[i] = 32'h0800_0000 + pc;
        q_erom[i] = {2{sdram.romh(pc[24:1])}}; q_mrom[i] = 32'hFFFF_FFFF;
        pc = pc + 2; exp_acc = exp_acc + 1; exp_act = exp_act + 1;
    end
    2: begin
        q_raddr[i] = 32'h0800_0000 + pc;
        q_erom[i] = {sdram.romh({pc[24:2], 1'b1}), sdram.romh({pc[24:2], 1'b0})}; q_mrom[i] = 32'hFFFF_FFFF;
        pc = pc + 4; exp_acc = exp_acc + 1; exp_act = exp_act + 2;
    end
    3: begin
        q_raddr[i] = 32'h0300_0000 + (ipc & 32'hFFE);
        ipc = ipc + 2;
    end
    default: ;
    endcase
end
endtask

// ROM-only request at an explicit address
task add_rom(input [27:0] addr, input th, input integer gap);
    integer i;
begin
    i = q_n; q_n = q_n + 1;
    q_rom[i] = 1; q_raddr[i] = {4'h0, addr}; q_th[i] = th;
    q_ram[i] = 0; q_wr[i] = 0; q_aaddr[i] = 0; q_wd[i] = 0; q_be[i] = 0; q_gap[i] = gap;
    q_mram[i] = 0; q_eram[i] = 0;
    if (th) begin
        q_erom[i] = {2{sdram.romh(addr[24:1])}};
        exp_act = exp_act + 1;
    end else begin
        q_erom[i] = {sdram.romh({addr[24:2], 1'b1}), sdram.romh({addr[24:2], 1'b0})};
        exp_act = exp_act + 2;
    end
    q_mrom[i] = 32'hFFFF_FFFF;
    exp_acc = exp_acc + 1;
end
endtask

// RAM access (sz 0 byte, 1 halfword, 2 word) with the current fetch attached
task add_mem(input wr, input [1:0] sz, input [27:0] addr, input [31:0] data, input integer gap);
    integer i, k, nb;
    reg [3:0] be;
    reg [31:0] wd, m, e;
begin
    i = q_n; q_n = q_n + 1;
    attach_fetch(i);
    q_ram[i] = 1; q_wr[i] = wr; q_aaddr[i] = {4'h0, addr}; q_gap[i] = gap;
    case (sz)
    2'd0:    begin be = 4'b0001 << addr[1:0]; wd = {4{data[7:0]}};  m = 32'hFF << (8 * addr[1:0]); nb = 1; end
    2'd1:    begin be = addr[1] ? 4'b1100 : 4'b0011; wd = {2{data[15:0]}}; m = addr[1] ? 32'hFFFF_0000 : 32'h0000_FFFF; nb = 2; end
    default: begin be = 4'b1111; wd = data; m = 32'hFFFF_FFFF; nb = 4; end
    endcase
    q_be[i] = be; q_wd[i] = wr ? wd : 32'h0;
    q_mram[i] = 0; q_eram[i] = 0;
    if (wr) begin
        if (!g_fl)
            for (k = 0; k < nb; k = k + 1) putb({addr[27:2], 2'b00} + (sz == 2'd0 ? addr[1:0] : sz == 2'd1 ? {addr[1], 1'b0} : 0) + k, data >> (8 * k));
    end else begin
        e = 0;
        for (k = 0; k < nb; k = k + 1)
            e = e | (getb({addr[27:2], 2'b00} + (sz == 2'd0 ? addr[1:0] : sz == 2'd1 ? {addr[1], 1'b0} : 0) + k) <<
                     (8 * ((sz == 2'd0 ? addr[1:0] : sz == 2'd1 ? {addr[1], 1'b0} : 2'd0) + k)));
        q_eram[i] = e; q_mram[i] = m;
    end
    if (sdram_space(addr)) begin
        exp_acc = exp_acc + 1;
        if (g_fl) exp_cmds = exp_cmds + 1;
        else      exp_act = exp_act + ((be[1:0] != 0 && be[3:2] != 0) ? 2 : 1);
    end
end
endtask

// expected value of the byte read just queued (flash ID mode answers, not the array)
task exp_byte(input [7:0] v);
    integer i;
begin
    i = q_n - 1;
    q_eram[i] = {24'h0, v} << (8 * q_aaddr[i][1:0]);
    q_mram[i] = 32'hFF << (8 * q_aaddr[i][1:0]);
end
endtask

task q_reset;
begin
    q_n = 0; exp_acc = 0; exp_cmds = 0; exp_act = 0; skip_act = 0;
    fm = 0; pc = 0; ipc = 0; g_fl = 0;
end
endtask

// ---------------------------------------------------------------- CPU stub
// Presents request i, holds it until cpu_en, presents request i+1 in the very
// next cycle (plus the request's own idle gap). The data of a completed request
// is on rom_data/ram_rdata the cycle after cpu_en and is compared then.
reg     eng_run = 0, eng_pend = 0, eng_done = 0, chk_pend = 0;
integer eng_i = 0, eng_n = 0, eng_gap = 0, eng_t0 = 0, chk_i = 0;
integer st_t0 = 0, st_end = 0, st_latsum = 0, st_latmax = 0, st_first = 0;
integer errs = 0, derrs = 0;

always @(posedge mclk) begin : eng
    integer lat;
    if (chk_pend) begin
        if ((rom_data & q_mrom[chk_i]) !== (q_erom[chk_i] & q_mrom[chk_i])) begin
            derrs = derrs + 1;
            if (derrs <= 8) $display("  DATA req %0d: rom %08x expected %08x (mask %08x) addr %08x", chk_i, rom_data, q_erom[chk_i], q_mrom[chk_i], q_raddr[chk_i]);
        end
        if ((ram_rdata & q_mram[chk_i]) !== (q_eram[chk_i] & q_mram[chk_i])) begin
            derrs = derrs + 1;
            if (derrs <= 8) $display("  DATA req %0d: ram %08x expected %08x (mask %08x) addr %08x", chk_i, ram_rdata, q_eram[chk_i], q_mram[chk_i], q_aaddr[chk_i]);
        end
        chk_pend = 0;
    end
    if (eng_run & eng_pend & cpu_en) begin
        lat = cyc - eng_t0;
        st_latsum = st_latsum + lat;
        if (lat > st_latmax) st_latmax = lat;
        if (q_mrom[eng_i] != 0 || q_mram[eng_i] != 0) begin chk_pend = 1; chk_i = eng_i; end
        eng_pend = 0;
        eng_i = eng_i + 1;
        if (eng_i == eng_n) begin
            eng_run = 0; st_end = cyc; eng_done = 1;
            rom_en <= 0; ram_cen <= 0; ram_wen <= 0;
        end else
            eng_gap = q_gap[eng_i];
    end
    if (eng_run & ~eng_pend) begin
        if (eng_gap > 0) begin
            eng_gap = eng_gap - 1;
            rom_en <= 0; ram_cen <= 0; ram_wen <= 0;
        end else begin
            rom_en <= q_rom[eng_i]; rom_addr <= q_raddr[eng_i]; thumb <= q_th[eng_i];
            ram_cen <= q_ram[eng_i]; ram_wen <= q_wr[eng_i]; ram_addr <= q_aaddr[eng_i];
            ram_wdata <= q_wd[eng_i]; ram_be <= q_be[eng_i];
            eng_pend = 1; eng_t0 = cyc;
            if (st_first) begin st_t0 = cyc; st_first = 0; end
        end
    end
end

// ---------------------------------------------------------------- streams
localparam NS = 40;
reg [8*22-1:0] s_name [0:NS-1];
integer s_cyc [0:NS-1];
integer ns = 0;

task do_stream(input [8*22-1:0] name, input bg, input integer base);
    integer t, limit, n;
    integer a_act, a_rd, a_wr, a_ref, a_fr, a_fu, a_h, a_hs, a_acc, a_cmd, a_ers, a_sv, a_rv, a_ph;
    integer d_act, d_rd, d_wr, d_ref, d_fr, d_fu, d_h, d_hs, d_acc, d_cmd, d_ers, d_sv, d_rv;
    integer cycles, serr;
    reg done_ok;
begin
    n = q_n;
    serr = 0; derrs = 0;
    limit = n * 40 + 30000;
    @(negedge mclk);
    a_act = n_act; a_rd = n_rd; a_wr = n_wr; a_ref = n_ref;
    a_fr = n_fresh; a_fu = n_fresh_unserved; a_h = n_held; a_hs = n_held_served;
    a_acc = sdramc.dbg_cpu_acc; a_cmd = sdramc.dbg_flash_cmds; a_ers = sdramc.dbg_erase_slots;
    a_sv = bg_sv_n; a_rv = bg_rv_n; a_ph = n_phase;
    st_latsum = 0; st_latmax = 0; st_first = 1; chk_pend = 0;
    eng_i = 0; eng_n = n; eng_gap = q_gap[0]; eng_pend = 0; eng_done = 0;
    bg_en = bg;
    eng_run = 1;
    t = 0;
    while (!eng_done && t < limit) begin @(negedge mclk); t = t + 1; end
    done_ok = eng_done;
    bg_en = 0;
    repeat (8) @(negedge mclk);             // let the last transactions drain
    cycles = st_end - st_t0;
    d_act = n_act - a_act; d_rd = n_rd - a_rd; d_wr = n_wr - a_wr; d_ref = n_ref - a_ref;
    d_fr = n_fresh - a_fr; d_fu = n_fresh_unserved - a_fu; d_h = n_held - a_h; d_hs = n_held_served - a_hs;
    d_acc = sdramc.dbg_cpu_acc - a_acc; d_cmd = sdramc.dbg_flash_cmds - a_cmd; d_ers = sdramc.dbg_erase_slots - a_ers;
    d_sv = bg_sv_n - a_sv; d_rv = bg_rv_n - a_rv;
    s_name[ns] = name; s_cyc[ns] = cycles; ns = ns + 1;

    $display("%-22s n=%4d cyc=%6d (%0d.%02d/req) lat<=%0d | acc=%0d/%0d fsm=%0d/%0d act=%0d/%0d rd=%0d wr=%0d ref=%0d erase=%0d | held=%0d dup=%0d fresh=%0d late=%0d | sv=%0d rv=%0d",
             name, n, cycles, cycles / n, (cycles * 100 / n) % 100, st_latmax,
             d_acc + d_cmd, exp_acc, d_cmd, exp_cmds, d_act, exp_act, d_rd, d_wr, d_ref, d_ers,
             d_h, d_hs, d_fr, d_fu, d_sv, d_rv);

    if (!done_ok) begin serr = serr + 1; $display("  FAIL: stream did not finish (cpu_en never came)"); end
    if (derrs != 0) begin serr = serr + 1; $display("  FAIL: %0d read-data mismatches", derrs); end
    if (d_hs != 0) begin serr = serr + 1; $display("  FAIL: %0d held strobe(s) served again (a served request ran twice)", d_hs); end
    if (d_fu != 0) begin serr = serr + 1; $display("  FAIL: %0d fresh request(s) not accepted at their first slot", d_fu); end
    if (d_acc + d_cmd != exp_acc) begin serr = serr + 1; $display("  FAIL: sdram_gba accepted %0d requests, the CPU made %0d", d_acc + d_cmd, exp_acc); end
    if (d_cmd != exp_cmds) begin serr = serr + 1; $display("  FAIL: flash FSM ran %0d commands, the CPU wrote %0d", d_cmd, exp_cmds); end
    if (!bg && !skip_act && (d_act != exp_act || d_rd + d_wr != exp_act)) begin
        serr = serr + 1; $display("  FAIL: SDRAM bus saw %0d ACT, %0d RD + %0d WR, expected %0d of each", d_act, d_rd, d_wr, exp_act);
    end
    // the held copy used to take the slot refresh and the RV/save clients wait for: with the
    // CPU going flat out they must still get theirs (a refresh is due every 512 clk = 128 mclk)
    if (!skip_act && d_ref < cycles / 128 - 1) begin
        serr = serr + 1; $display("  FAIL: only %0d refreshes in %0d mclk periods (>= %0d due): refresh starved", d_ref, cycles, cycles / 128 - 1);
    end
    if (bg && (d_sv < cycles / 16 || d_rv < cycles / 16)) begin
        serr = serr + 1; $display("  FAIL: background clients starved: %0d save + %0d RV transactions in %0d mclk periods (>= %0d each expected)", d_sv, d_rv, cycles, cycles / 16);
    end
    if (n_phase != a_ph) begin serr = serr + 1; $display("  FAIL: sdram_gba's slot drifted off mclk's rising edge"); end
    if (!PRE && base != 0 && cycles > base) begin
        serr = serr + 1; $display("  FAIL: %0d mclk periods, the pre-fix controller needed %0d", cycles, base);
    end
    errs = errs + serr;
end
endtask

// ---------------------------------------------------------------- stream builders
reg [31:0] rng = 32'h1BADB002;
function [31:0] xs(input [31:0] x);
begin x = x ^ (x << 13); x = x ^ (x >> 17); x = x ^ (x << 5); xs = x; end
endfunction

// random access in the 4KB window of EWRAM (region 0), IWRAM (1), or EWRAM/IWRAM/cart RAM (2)
task add_rand(input integer region, input integer gap);
    reg [1:0] sz;
    reg [27:0] a;
    reg [3:0] sel;
begin
    rng = xs(rng); sel = rng[19:16];
    rng = xs(rng); sz = rng[9:8] == 2'd3 ? 2'd2 : rng[9:8];
    rng = xs(rng);
    a = rng[11:0] & (sz == 2 ? 12'hFFC : sz == 1 ? 12'hFFE : 12'hFFF);
    if (region == 0 || (region == 2 && sel < 9))       a = 28'h200_0000 + a;
    else if (region == 1 || (region == 2 && sel < 13)) a = 28'h300_0000 + a;
    else                                               begin a = 28'hE00_0000 + rng[15:0]; sz = 2'd0; end
    rng = xs(rng);
    add_mem(rng[16], sz, a, xs(rng), gap);
end
endtask

task b_rom_seq(input th, input integer n);
    integer k;
begin
    q_reset;
    for (k = 0; k < n; k = k + 1) add_rom(28'h800_0000 + (th ? 2 * k : 4 * k), th, 0);
end
endtask

task b_rom_rand(input integer n);
    integer k;
    reg th;
begin
    q_reset;
    for (k = 0; k < n; k = k + 1) begin
        rng = xs(rng); th = rng[3];
        add_rom(28'h800_0000 + ((rng >> 8) & (th ? 28'hFFFFE : 28'hFFFFC)), th, 0);
    end
end
endtask

// n accesses to EWRAM of one kind: kind 0 W32/R32 alternating, 1 W16/R16, 2 W8/R8,
// 3 W16 x n, 4 R16 x n, 5 W8 x n, 6 R8 x n, 7 W32 x n, 8 R32 x n
task b_ew(input integer kind, input integer n, input integer fmode);
    integer k;
    reg [27:0] a;
begin
    q_reset; fm = fmode;
    for (k = 0; k < n; k = k + 1) begin
        case (kind)
        0: add_mem(k[0] ? 1'b0 : 1'b1, 2'd2, 28'h200_0000 + 4 * (k >> 1), 32'hC0DE_0000 + k, 0);
        1: add_mem(k[0] ? 1'b0 : 1'b1, 2'd1, 28'h200_0000 + 2 * (k >> 1), 32'hA000 + k, 0);
        2: add_mem(k[0] ? 1'b0 : 1'b1, 2'd0, 28'h200_0000 + (k >> 1), 32'h40 + k, 0);
        3: add_mem(1'b1, 2'd1, 28'h200_0100 + 2 * k, 32'hB000 + k, 0);
        4: add_mem(1'b0, 2'd1, 28'h200_0100 + 2 * k, 0, 0);
        5: add_mem(1'b1, 2'd0, 28'h200_0300 + k, 32'h80 + k, 0);
        6: add_mem(1'b0, 2'd0, 28'h200_0300 + k, 0, 0);
        7: add_mem(1'b1, 2'd2, 28'h200_0500 + 4 * k, 32'hD00D_0000 + k, 0);
        default: add_mem(1'b0, 2'd2, 28'h200_0500 + 4 * k, 0, 0);
        endcase
    end
end
endtask

task b_ew_rand(input integer n, input integer fmode, input integer maxgap);
    integer k;
begin
    q_reset; fm = fmode;
    for (k = 0; k < n; k = k + 1) begin
        rng = xs(rng);
        add_rand(0, maxgap == 0 ? 0 : rng[1:0] % (maxgap + 1));
    end
end
endtask

// sdram ROM fetch + IWRAM data (REQ1 sdram, REQ2 bram)
task b_rom_iw(input integer n);
    integer k;
begin
    q_reset; fm = 1;
    for (k = 0; k < n; k = k + 1) add_rand(1, 0);
end
endtask

// SRAM byte stores / loads
task b_sram(input integer n, input wr, input integer fmode);
    integer k;
begin
    q_reset; fm = fmode;
    for (k = 0; k < n; k = k + 1) begin
        rng = xs(rng);
        add_mem(wr, 2'd0, 28'hE00_0000 + 7 * k, wr ? rng[7:0] : 0, 0);
    end
end
endtask

// everything, with every fetch shape and random gaps
task b_mixed(input integer n);
    integer k;
    reg th;
begin
    q_reset;
    for (k = 0; k < n; k = k + 1) begin
        rng = xs(rng); fm = rng[1:0];
        rng = xs(rng);
        if (rng[2:0] == 3'd0) begin                 // ROM-only fetch in between
            th = rng[3];
            add_rom(28'h800_0000 + ((rng >> 4) & (th ? 28'hFFFFE : 28'hFFFFC)), th, rng[5:4] == 0 ? 1 : 0);
        end else
            add_rand(2, rng[7:6] == 2'd3 ? 1 : 0);
    end
end
endtask

// ---- flash chip protocol, as a game's save library issues it
localparam [27:0] CART = 28'hE00_0000;
task fl_w(input [15:0] a, input [7:0] v);       // command-space write: runs the FSM, stores nothing
begin g_fl = 1; add_mem(1'b1, 2'd0, CART + a, v, 0); g_fl = 0; end
endtask
task fl_unlock; begin fl_w(16'h5555, 8'hAA); fl_w(16'h2AAA, 8'h55); end endtask
task fl_cmd(input [7:0] c); begin fl_unlock; fl_w(16'h5555, c); end endtask
task fl_prog(input [15:0] a, input [7:0] v);    // unlock + A0 + data byte (array write)
begin fl_cmd(8'hA0); add_mem(1'b1, 2'd0, CART + a, v, 0); end
endtask
task fl_rd(input [15:0] a);
begin add_mem(1'b0, 2'd0, CART + a, 0, 0); end
endtask

// FLASH512 (type 1) or FLASH1M (type 2): program, read back, ID mode, programming AA at 5555,
// and for 1M a bank switch with a program in bank 1
task b_flash(input integer fmode, input one_m);
    reg [7:0] id0, id1;
begin
    q_reset; fm = fmode; g_bank = 0;
    id0 = one_m ? 8'h62 : 8'h32; id1 = one_m ? 8'h13 : 8'h1B;
    fl_prog(16'h0010, 8'hD1);
    fl_prog(16'h0011, 8'hD2);
    fl_prog(16'h1234, 8'hD3);
    fl_rd(16'h0010); fl_rd(16'h0011); fl_rd(16'h1234); fl_rd(16'h0012);
    fl_cmd(8'h90);                                  // ID mode
    fl_rd(16'h0000); exp_byte(id0);
    fl_rd(16'h0001); exp_byte(id1);
    fl_cmd(8'hF0);                                  // leave ID mode
    fl_rd(16'h0010);
    fl_prog(16'h5555, 8'hAA);                       // data that looks like an unlock's first byte
    fl_prog(16'h0013, 8'hD4);                       // the next unlock must still work
    fl_rd(16'h5555); fl_rd(16'h0013);
    if (one_m) begin
        fl_cmd(8'hB0); fl_w(16'h0000, 8'h01);       // bank 1
        g_bank = 1;
        fl_prog(16'h0020, 8'hE1);
        fl_rd(16'h0020); fl_rd(16'h0010);           // bank 1 has no D1 at 0x10
        fl_cmd(8'hB0); fl_w(16'h0000, 8'h00);       // back to bank 0
        g_bank = 0;
        fl_rd(16'h0010); fl_rd(16'h0013);
    end
end
endtask

// sector erase of the 4KB sector at 0x1000 (stalls the CPU until done)
task b_flash_erase(input integer fmode);
    integer k;
begin
    q_reset; fm = fmode; g_bank = 0; skip_act = 1;
    fl_prog(16'h1234, 8'h77);
    fl_prog(16'h0800, 8'h66);
    fl_cmd(8'h80); fl_unlock; fl_w(16'h1000, 8'h30);
    for (k = 0; k < 4096; k = k + 1) cr[16'h1000 + k] = 8'hFF;
    fl_rd(16'h1234); fl_rd(16'h0800); fl_rd(16'h1FFF);
end
endtask

// ---------------------------------------------------------------- loader helpers
task set_backup(input [2:0] t);
begin
    @(negedge mclk); loading = 3'd3;
    repeat (4) @(negedge mclk);
    loader_data = {5'b0, t}; loader_valid = 1;
    @(negedge mclk); loader_valid = 0;
    repeat (2) @(negedge mclk);
    loading = 3'd0;
    repeat (4) @(negedge mclk);
    if (config_backup_type !== t) begin
        errs = errs + 1; $display("FAIL: backup type %0d did not reach the core (%0d)", t, config_backup_type);
    end
end
endtask

// ---------------------------------------------------------------- loader
// n bytes pushed one per 3 mclk (the fastest gba_memory's loader takes them); mode 2 =
// cart RAM from 0x0E000000, mode 1 = ROM from 0x08000000 (chip 0, the model drops it).
task t_loader(input [2:0] mode, input integer n, input [8*22-1:0] name);
    integer k, t0, t, cycles, a_acc, a_act, d_acc, d_act, serr;
begin
    serr = 0;
    @(negedge mclk);
    a_acc = sdramc.dbg_cpu_acc; a_act = n_act; t0 = cyc;
    loading = mode;
    repeat (4) @(negedge mclk);
    for (k = 0; k < n; k = k + 1) begin
        loader_data = k * 3 + 1; loader_valid = 1;
        @(negedge mclk); loader_valid = 0;
        repeat (2) @(negedge mclk);
    end
    t = 0;
    while (sdramc.dbg_cpu_acc - a_acc < n && t < 1000) begin @(negedge mclk); t = t + 1; end
    cycles = cyc - t0;
    repeat (8) @(negedge mclk);
    loading = 3'd0;
    repeat (4) @(negedge mclk);
    d_acc = sdramc.dbg_cpu_acc - a_acc; d_act = n_act - a_act;
    $display("%-22s n=%4d cyc=%6d (%0d.%02d/byte) | acc=%0d/%0d act=%0d/%0d", name, n, cycles, cycles / n, (cycles * 100 / n) % 100, d_acc, n, d_act, n);
    if (d_acc != n || d_act != n) begin serr = serr + 1; $display("  FAIL: the loader's %0d writes reached the SDRAM as %0d requests / %0d ACT", n, d_acc, d_act); end
    if (!PRE && base_of(name) != 0 && cycles > base_of(name)) begin
        serr = serr + 1; $display("  FAIL: %0d mclk periods, the pre-fix controller needed %0d", cycles, base_of(name));
    end
    if (mode == 3'd2)
        for (k = 0; k < n; k = k + 1) cr[k] = k * 3 + 1;      // verify_mem checks the SDRAM against this
    s_name[ns] = name; s_cyc[ns] = cycles; ns = ns + 1;
    errs = errs + serr;
end
endtask

// ---------------------------------------------------------------- baselines
// mclk periods per stream on the pre-fix controller (sdram_gba.v at ecf535e^),
// as printed by `./run.sh tb_gba_memstream_prefix`. 0 = not gated.
function integer base_of(input [8*22-1:0] name);
begin
    case (name)
    "rom_arm_seq":           base_of = 768;
    "rom_thumb_seq":         base_of = 512;
    "rom_random":            base_of = 634;
    "ew_w32_r32":            base_of = 768;
    "ew_w16_r16":            base_of = 512;
    "ew_w8_r8":              base_of = 512;
    "ew_w16_x128":           base_of = 256;
    "ew_r16_x128":           base_of = 256;
    "ew_w8_x128":            base_of = 256;
    "ew_r8_x128":            base_of = 256;
    "ew_w32_x128":           base_of = 384;
    "ew_r32_x128":           base_of = 384;
    "ew_random":             base_of = 1025;
    "ew_random_gaps":        base_of = 1315;
    "thumbrom+ew_random":    base_of = 1351;
    "armrom+ew_random":      base_of = 1647;
    "iwramfetch+ew_random":  base_of = 1061;
    "thumbrom+iwram_random": base_of = 900;
    "sram_w8":               base_of = 512;
    "sram_r8":               base_of = 512;
    "thumbrom+sram_w8":      base_of = 1024;
    "iwramfetch+sram_w8":    base_of = 768;
    "mixed_all_shapes":      base_of = 1821;
    "loader_cartram":        base_of = 197;
    "loader_rom":            base_of = 197;
    "flash512_ramonly":      base_of = 70;
    "flash512_thumbrom":     base_of = 140;
    "flash512_iwramfetch":   base_of = 105;
    "flash1m_ramonly":       base_of = 102;
    "flash1m_thumbrom":      base_of = 204;
    "bg_rom_thumb_seq":      base_of = 1200;
    "bg_ew_w16_x128":        base_of = 256;
    "bg_ew_r16_x128":        base_of = 256;
    "bg_ew_random":          base_of = 1487;
    "bg_thumbrom+ew_random": base_of = 2694;
    "bg_mixed_all_shapes":   base_of = 2243;
    default: base_of = 0;      // flash512_erase: the pre-fix controller never starts the erase
    endcase
end
endfunction

// ---------------------------------------------------------------- main
task run(input [8*22-1:0] name, input bg);
begin
    do_stream(name, bg, base_of(name));
end
endtask

initial begin
    #1;
    repeat (12) @(negedge clk);
    resetn = 1;
    while (busy !== 1'b0) @(negedge mclk);
    repeat (40) @(negedge mclk);
    set_backup(3'd3);
    init_ram;
    init_cart(8'h5A, 1'b0);
    repeat (20) @(negedge mclk);
    $display("backup type SRAM; streams (cyc = mclk periods; acc=accepted/expected requests, fsm=flash FSM runs/expected, act=SDRAM ACT seen/expected,");
    $display("held = held strobes seen, dup = of those served again; fresh = fresh strobes, late = of those not accepted at their first slot)");

    // ROM fetch streams
    b_rom_seq(0, 256);              run("rom_arm_seq", 0);
    b_rom_seq(1, 256);              run("rom_thumb_seq", 0);
    b_rom_rand(256);                run("rom_random", 0);

    // RAM streams, RAM only (the strobe is held two periods)
    b_ew(0, 256, 0);                run("ew_w32_r32", 0);
    b_ew(1, 256, 0);                run("ew_w16_r16", 0);
    b_ew(2, 256, 0);                run("ew_w8_r8", 0);
    b_ew(3, 128, 0);                run("ew_w16_x128", 0);
    b_ew(4, 128, 0);                run("ew_r16_x128", 0);
    b_ew(5, 128, 0);                run("ew_w8_x128", 0);
    b_ew(6, 128, 0);                run("ew_r8_x128", 0);
    b_ew(7, 128, 0);                run("ew_w32_x128", 0);
    b_ew(8, 128, 0);                run("ew_r32_x128", 0);
    b_ew_rand(400, 0, 0);           run("ew_random", 0);
    b_ew_rand(400, 0, 2);           run("ew_random_gaps", 0);

    // ROM + RAM pairs (REQ2: the second strobe is held one period)
    b_ew_rand(300, 1, 0);           run("thumbrom+ew_random", 0);
    b_ew_rand(300, 2, 0);           run("armrom+ew_random", 0);
    b_ew_rand(300, 3, 0);           run("iwramfetch+ew_random", 0);
    b_rom_iw(300);                  run("thumbrom+iwram_random", 0);

    // SRAM byte stores (0x0E000000)
    b_sram(256, 1, 0);              run("sram_w8", 0);
    b_sram(256, 0, 0);              run("sram_r8", 0);
    b_sram(256, 1, 1);              run("thumbrom+sram_w8", 0);
    b_sram(256, 1, 3);              run("iwramfetch+sram_w8", 0);
    b_mixed(500);                   run("mixed_all_shapes", 0);
    verify_mem(1);

    // ROM / cart RAM loading through gba_memory's loader (single-period strobes, 3 mclk per byte)
    t_loader(3'd2, 64, "loader_cartram");
    t_loader(3'd1, 64, "loader_rom");
    set_backup(3'd3);
    verify_mem(1);

    // FLASH512: unlock + program / ID / AA-data, in each fetch shape
    set_backup(3'd1);
    init_cart(8'h00, 1'b1);
    b_flash(0, 0);                  run("flash512_ramonly", 0);
    verify_mem(1);
    init_cart(8'h00, 1'b1);
    b_flash(1, 0);                  run("flash512_thumbrom", 0);
    verify_mem(1);
    init_cart(8'h00, 1'b1);
    b_flash(3, 0);                  run("flash512_iwramfetch", 0);
    verify_mem(1);
    init_cart(8'h00, 1'b1);
    b_flash_erase(0);               run("flash512_erase", 0);
    verify_mem(1);

    // FLASH1M: also bank switch
    set_backup(3'd2);
    init_cart(8'h00, 1'b1);
    b_flash(0, 1);                  run("flash1m_ramonly", 0);
    verify_mem(2);
    init_cart(8'h00, 1'b1);
    b_flash(1, 1);                  run("flash1m_thumbrom", 0);
    verify_mem(2);

    // background clients: refresh and the save/RV requests must still get slots
    set_backup(3'd3);
    init_cart(8'h5A, 1'b0);
    b_rom_seq(1, 600);              run("bg_rom_thumb_seq", 1);
    b_ew(3, 128, 0);                run("bg_ew_w16_x128", 1);
    b_ew(4, 128, 0);                run("bg_ew_r16_x128", 1);
    b_ew_rand(600, 0, 0);           run("bg_ew_random", 1);
    b_ew_rand(600, 1, 0);           run("bg_thumbrom+ew_random", 1);
    b_mixed(600);                   run("bg_mixed_all_shapes", 1);
    verify_mem(1);

    if (mism != 0) begin errs = errs + 1; $display("FAIL: %0d SDRAM content mismatches", mism); end
    if (PRE) $display("-- pre-fix reference run: periods per stream, for base_of() --");
    if (PRE) for (ns = 0; ns < NS && s_cyc[ns] != 0; ns = ns + 1) $display("    \"%0s\": base_of = %0d;", s_name[ns], s_cyc[ns]);
    if (errs != 0) $fatal(1, "tb_gba_memstream: FAIL, %0d failed checks", errs);
    $display("tb_gba_memstream: PASS");
    $finish;
end

// watchdog
initial begin
    #400_000_000;
    $fatal(1, "tb_gba_memstream: timeout");
end

endmodule
