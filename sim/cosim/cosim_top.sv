// cosim_top: the GBA co-simulation DUT. A small top around the REAL gbatang
// interface logic -- iosys_bl616 (UART protocol, OSD text, save channel) and
// sdram_gba (SDRAM controller incl. the battery-save client) -- plus a
// behavioral SDRAM chip, GBA-like CPU traffic and test hooks. No game, no
// video, no audio: this exercises firmware<->core interactions (pad frames,
// combos, save dumps/restores, reset, MODE, core_config) without hardware.
//
// CYCLES AND CLOCKS
//   clk/mclk/resetn come from the C++ bridge; fclk must be exactly 4x clk
//   (sdram_gba's 4-cycle frame resyncs on every mclk posedge, and its clkref
//   IS mclk: the board runs the 67MHz ram clock at 4 x the 16.65MHz GBA
//   clock, phase-locked). mclk is clk: the bridge's sim tick is one iosys/
//   GBA clock period, and fclk is the coincident 4x ram clock. hclk is tied
//   to clk by the bridge: it only feeds textdisp's render pipeline, whose
//   pixels nobody observes (OSD text is snapshotted straight out of the DPB
//   array, below).
//   One sim tick (firmware sim_time, 1/21.492MHz) is one clk period; iosys
//   runs with FREQ=21_492_000 so its UART lands at the real 2 Mbaud in ticks
//   (the board runs iosys at 16.65MHz; everything else in iosys counts
//   clocks, not seconds, so it tracks sim time like on hardware).
//
// PROGRAMMING MODEL
//   The generated iosys_bl616_cosim answers core-ID replies with the
//   cosim_core_id input (see Makefile: the ONLY difference from the real
//   iosys_bl616.v, made by mechanical sed at build time and verified by
//   diff). Programming a bitstream = the bridge sets cosim_core_id and
//   pulses resetn, like hardware loading fresh logic. SDRAM contents are
//   RETAINED across reset (external chip), matching hardware.
//   silence=1 (MODE blackout) forces both UART lines idle; the bridge ends
//   it with a reset pulse and cosim_core_id=0 (flash bitstream), after which
//   the firmware reboots.
//
// LOADER / BACKUP TYPE
//   gba_memory is not instantiated (no game runs here), so cosim_top
//   replicates its loader latch: a backup-type byte arriving while
//   rom_loading==3 (loader region 3) sets config_backup_type, and entering
//   loading==1 clears it (see src/memory/gba_memory.sv). The firmware sends
//   the type after each ROM load AND again after every reset combo
//   (gba_resend_backup_type), so the model must see type 3 again post-reset.
//   ROM/BIOS streams (loading 1 and 4) just count into rom_bytes.
//   v1 models the SRAM backup (type 3): the EEPROM port (type 4) is answered
//   immediately with blank data, never stored, like gbatang_top's mux shape
//   with no EEPROM chip behind it.
//
// GAME/TRAFFIC MODEL
//   The cpu_* ports get GBA-like traffic (LFSR-driven, deterministic): one
//   word read every 8 clk from cartridge ROM / EWRAM, presented and held
//   until cpu_ready takes it, like gba_memory presents requests. churn_en:
//   the "game" continuously byte-writes the cart-RAM backup window
//   (0x204_0000 + offset); with backup type 3 set, sdram_gba pulses
//   backup_written -> sv_core_we -> iosys dirties the save and owes the MCU
//   a 0x0B notice.
//   poke_valid/poke_off/poke_data/poke_ack: single game-path backup writes
//   for wram-write/wram-burst (and poke-save). Poke wins over churn and
//   normal reads for its slot.
//   The save channel has the lowest SDRAM priority (real arbitration), so
//   dumps genuinely contend with game traffic.
//
// OBSERVABILITY (all real unless noted)
//   core_config/overlay: straight out of iosys (expect-config-bit reads the
//   real register). rom_bytes: ROM/BIOS payload bytes consumed (the firmware
//   streams them; no loader parses them here). sdram_busy: controller init.
//   OSD text / save RAM: read by the C++ bridge DIRECTLY out of the
//   behavioral arrays (gowin_dpb_menu.mem, sdram_chip.mem, both
//   `verilator public`), no model clocking per cell. The char buffer lives
//   at DPB $000-$37F = {1'b0, y[4:0], x[4:0]} (32x28). The save window is
//   sdram_gba's static cart-RAM map: save byte o rides chip 1 halfword
//   {BA=0, row={00001,0,sv[16:10]}, col=sv[9:1]} = word 0x20000 + o/2, byte
//   lane sv_addr[0], i.e. linear SDRAM byte address 0x40000 + o (tb_sdram_save
//   cross-checks this against the CPU cart window at 0x204_0000 + o).
module cosim_top (
    input wire clk,
    input wire fclk,
    input wire hclk,
    input wire resetn,

    input wire [11:0] joy1,
    input wire [11:0] joy2,

    input wire uart_rx,
    output wire uart_tx,
    input wire silence,
    input wire [15:0] cosim_core_id,

    output wire [31:0] core_config,
    output wire overlay,
    output wire sdram_busy,
    output reg [31:0] rom_bytes,
    // TX-pending for the bridge's idle jump: a reply owed or a frame on the
    // wire. Hierarchical into iosys (cosim-owned top; the DUT itself is
    // untouched): send_state covers every TX frame, response_* the core-ID /
    // config-string handoff (RX posts, TX picks up a tick or two later), and
    // sv_* the save-block / dirty-notice path. Without this the bridge would
    // jump over the idle gap between a request and its reply, skipping the
    // reply unsampled. (A joypad frame due on its 20 ms timer is NOT
    // included: delaying it by a jump is harmless, the firmware polls.)
    output wire tx_pending,
    input wire poke_valid,
    input wire [15:0] poke_off,
    input wire [7:0] poke_data,
    output reg poke_ack,
    input wire churn_en
);

// ---- UART gating (MODE blackout) ----
wire uart_rx_iosys = silence ? 1'b1 : uart_rx;
wire uart_tx_iosys;
assign uart_tx = silence ? 1'b1 : uart_tx_iosys;

// ---- save channel (iosys <-> sdram_gba), as gbatang_top wires it ----
wire [17:0] sv_addr;
wire [7:0] sv_din, sv_q;
wire sv_we, sv_req, sv_ack, sv_core_we;
wire [16:0] sdram_sv_addr;
wire [7:0] sdram_sv_q;
wire sdram_sv_ack;
reg  [2:0] config_backup_type = 0;
wire backup_written;
wire eep_save = config_backup_type == 3'd4;      // EEPROM: not modeled (v1)

assign sdram_sv_addr = sv_addr[16:0];
assign sv_q = eep_save ? 8'h0 : sdram_sv_q;
assign sv_ack = eep_save ? sv_req : sdram_sv_ack;   // an absent chip answers at once

// ---- loader latch (the backup-type part of gba_memory's loader FSM) ----
// loading==3's first byte is the backup type; entering loading==1 clears it.
wire [7:0] rom_loading;
reg  [2:0] loading_r = 0;
reg  [2:0] cfg_ptr = 0;
always @(posedge clk) begin
    if (!resetn) begin
        config_backup_type <= 3'd0;
        cfg_ptr <= 2'd0;
        loading_r <= 3'd0;
    end else begin
        loading_r <= rom_loading[2:0];
        if (rom_loading[2:0] != loading_r) begin
            cfg_ptr <= 2'd0;
            if (rom_loading[2:0] == 3'd1)         // reset backup settings on load start
                config_backup_type <= 3'd0;
        end else if (rom_loading[2:0] == 3'd3 && rom_do_valid) begin
            if (cfg_ptr == 2'd0)
                config_backup_type <= rom_do;
            cfg_ptr <= cfg_ptr + 2'd1;
        end
    end
end

// ---- dirty: backup_written is a one-slot pulse inside the sdram frame; ----
// ---- two-flop catch in clk, exactly as gbatang_top samples it          ----
reg [2:0] bw_s = 3'b000;
always @(posedge clk) bw_s <= {bw_s[1:0], backup_written};
assign sv_core_we = bw_s[1] & ~bw_s[2];

// ---- ROM sink: count what the firmware streams (no loader here) ----
wire [7:0] rom_do;
wire rom_do_valid;
always @(posedge clk) begin
    if (!resetn)
        rom_bytes <= 0;
    else if (rom_do_valid)
        rom_bytes <= rom_bytes + 1;
end

assign tx_pending = (sys.send_state != 4'd0) || (sys.response_req != sys.response_ack) ||
                    (sys.sv_rd_req != sys.sv_rd_ack) || sys.sv_notify;

iosys_bl616_cosim #(
    .FREQ(21_492_000),
    .SAVE_IF(1),
    .SAVE_AW(18),
    .SAVE_SYNC(0)
) sys (
    .clk(clk),
    .hclk(hclk),
    .resetn(resetn),
    .cosim_core_id(cosim_core_id),

    .overlay(overlay),
    .overlay_x(8'h00),
    .overlay_y(8'h00),
    .overlay_color(),
    .joy1(joy1),
    .joy2(joy2),
    .hid1(),
    .hid2(),

    .rom_loading(rom_loading),
    .rom_do(rom_do),
    .rom_do_valid(rom_do_valid),

    .mgmt_address(),
    .mgmt_read(),
    .mgmt_readdata(16'h0),
    .mgmt_write(),
    .mgmt_writedata(),
    .fdd_request(2'b00),

    .kbd_data(8'h0),
    .kbd_data_valid(),

    .sv_addr(sv_addr),
    .sv_din(sv_din),
    .sv_we(sv_we),
    .sv_q(sv_q),
    .sv_core_we(sv_core_we),
    .sv_req(sv_req),
    .sv_ack(sv_ack),

    .core_config(core_config),
    .uart_rx(uart_rx_iosys),
    .uart_tx(uart_tx_iosys)
);

// ---- SDRAM: real controller + behavioral chip, as gbatang_top ----
wire [15:0] sdram_dq;
wire [12:0] sdram_a;
wire [1:0] sdram_ba, sdram_dqm;
wire sdram_ncs, sdram_nwe, sdram_nras, sdram_ncas;

// CPU-side requests (the traffic model below drives them like gba_memory)
reg         cpu_rd = 0, cpu_wr = 0;
reg  [25:2] cpu_addr = 0;
reg  [31:0] cpu_wdata = 0;
reg  [3:0]  cpu_be = 0;
wire        cpu_ready;
wire [31:0] cpu_rdata [1:3];

sdram_gba sdram (
    .SDRAM_DQ(sdram_dq),
    .SDRAM_A(sdram_a),
    .SDRAM_BA(sdram_ba),
    .SDRAM_DQM(sdram_dqm),
    .SDRAM_nCS(sdram_ncs),
    .SDRAM_nWE(sdram_nwe),
    .SDRAM_nRAS(sdram_nras),
    .SDRAM_nCAS(sdram_ncas),
    .clk(fclk),
    .mclk(clk),
    .resetn(resetn),
    .config_backup_type(config_backup_type),
    .backup_written(backup_written),
    .cpu_rd(cpu_rd),
    .cpu_wr(cpu_wr),
    .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata),
    .cpu_port(2'd1),
    .cpu_rdata(cpu_rdata),
    .cpu_be(cpu_be),
    .cpu_ready(cpu_ready),
    .rv_addr(22'h0),
    .rv_din(16'h0),
    .rv_ds(2'b00),
    .rv_dout(),
    .rv_req(1'b0),
    .rv_req_ack(),
    .rv_we(1'b0),
    .sv_addr(sdram_sv_addr),
    .sv_din(sv_din),
    .sv_we(sv_we),
    .sv_req(sv_req & ~eep_save),
    .sv_ack(sdram_sv_ack),
    .sv_dout(sdram_sv_q),
    .total_refresh(),
    .busy(sdram_busy)
);

sdram_chip chip (
    .fclk(fclk),
    .A(sdram_a),
    .BA(sdram_ba),
    .DQM(sdram_dqm),
    .nCS(sdram_ncs),
    .nWE(sdram_nwe),
    .nRAS(sdram_nras),
    .nCAS(sdram_ncas),
    .SDRAM_DQ(sdram_dq)
);

// ---- GBA-like CPU traffic + game backup writes (clk domain) ----
// Deterministic 16-bit LFSR (x^16+x^14+x^13+x^11+1), never zero.
reg [15:0] lfsr = 16'hACE1;
function [15:0] lfsr_next(input [15:0] s);
    lfsr_next = {s[14:0], s[15] ^ s[13] ^ s[12] ^ s[10]};
endfunction

localparam [25:0] CART_BASE = 26'h204_0000;   // backup RAM (chip 1)
localparam [25:0] EW_BASE   = 26'h200_0000;   // EWRAM (chip 1)

wire [25:0] read_addr = lfsr[13]
    ? {2'h0, lfsr, 8'h0}                                   // cartridge ROM (chip 0)
    : EW_BASE | {9'h0, lfsr, 1'b0};                        // EWRAM (chip 1)
wire [25:0] churn_addr = CART_BASE + {11'h0, (lfsr[14:0] ^ churn_div[14:0])};
wire [25:0] poke_addr  = CART_BASE + {10'h0, poke_off};

reg  [1:0]  cstate = 0;                        // 0 idle, 1 held-until-taken, 2 release
reg         is_write = 0, is_poke = 0;
reg  [15:0] tc = 0;
reg  [15:0] churn_div = 0;

always @(posedge clk) begin
    if (!resetn) begin
        cpu_rd <= 0;
        cpu_wr <= 0;
        cpu_addr <= 0;
        cpu_wdata <= 0;
        cpu_be <= 0;
        cstate <= 0;
        is_write <= 0;
        is_poke <= 0;
        poke_ack <= 0;
        tc <= 0;
        churn_div <= 0;
        lfsr <= 16'hACE1;
    end else begin
        tc <= tc + 1;
        lfsr <= lfsr_next(lfsr);
        // poke_ack is level (not a pulse): it stays up from accept until the
        // bridge releases poke_valid, so a batch-granularity sampler cannot
        // miss it between evaluations.
        if (!poke_valid)
            poke_ack <= 0;

        case (cstate)
        0: begin
            if (poke_valid) begin
                // Test hook: one game-path backup write (dirties the save).
                cpu_addr <= poke_addr[25:2];
                cpu_wdata <= {4{poke_data}};
                cpu_be <= 4'b0001 << poke_addr[1:0];
                cpu_wr <= 1; cpu_rd <= 0;
                is_write <= 1; is_poke <= 1;
                cstate <= 1;
            end else if (churn_en && (tc % 48 == 0)) begin
                // The game scribbles backup RAM (combo-during-dump).
                churn_div <= churn_div + 1;
                cpu_addr <= churn_addr[25:2];
                cpu_wdata <= {4{lfsr[7:0] ^ churn_div[7:0]}};
                cpu_be <= 4'b0001 << churn_addr[1:0];
                cpu_wr <= 1; cpu_rd <= 0;
                is_write <= 1; is_poke <= 0;
                cstate <= 1;
            end else if (tc % 8 == 0) begin
                // ROM/EWRAM fetch: one word read, presented until taken.
                cpu_addr <= read_addr[25:2];
                cpu_be <= 4'b1111;
                cpu_rd <= 1; cpu_wr <= 0;
                is_write <= 0; is_poke <= 0;
                cstate <= 1;
            end
        end
        1: begin
            // Hold the strobe until sdram_gba takes the request (gba_memory
            // does the same): sdram_gba masks repeats with cpu_ready, so
            // holding can only delay a request, never double- or drop it.
            if (cpu_ready) begin
                if (is_poke)
                    poke_ack <= 1;
                cstate <= 2;
            end
        end
        2: begin
            // Release one tick after the accept: the next decision slot's
            // ~cpu_ready mask would skip it anyway, and by the slot after
            // that the strobe is down, so nothing re-runs the request.
            cpu_rd <= 0;
            cpu_wr <= 0;
            cpu_be <= 0;
            cstate <= 0;
        end
        default: cstate <= 0;
        endcase
    end
end

endmodule
