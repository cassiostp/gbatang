// Cartridge GPIO port (0x080000C4 data / C6 direction / C8 control) with
// the devices TangCore supports behind it: the Seiko S-3511A real-time
// clock (Pokemon Ruby/Sapphire/Emerald, Boktai, ...) and Boktai's solar
// sensor. Written from GBATEK's GPIO/RTC/solar sections and the observable
// behaviour of mGBA and GBA_MiSTer (no code copied: GBA_MiSTer is
// GPL-2.0-only, this core is GPL-3.0).
//
// Time comes from the firmware (UART frame 0x14 via iosys): unix seconds
// plus a BCD calendar. The BCD clock free-runs at 1 Hz between frames.
// Until the game writes the RTC (Pokemon's new-game clock set) or a saved
// RTC sector is restored, every frame re-seeds the BCD clock, so a fresh
// game reads the console's Options date/time. Afterwards frames only
// resync the unix counter and the game's own offset is preserved.
//
// The per-game RTC state is one extra 512-byte save block, byte-compatible
// with GBA_MiSTer's .sav extension: "RT" tag, the BCD datetime packed in
// 42 bits, and the unix timestamp it was saved at. On restore the clock
// is fast-forwarded by now - saved (capped at 31 days) once the first
// time frame arrives.
//
// Solar sensor: the cartridge ramp ADC. The game resets an 8-bit counter
// (GPIO bit1), clocks it (bit0) and reads the comparator flag (bit3);
// the counter value at the trip point is the light level (~0xE8 dark,
// ~0x44 bright sun). The firmware supplies the level as a percent.

module gba_gpio_rtc #(
    parameter CLK_HZ = 16650000
) (
    input               clk,
    input               rst,            // new game: loader started (loading 0->1)
    input               rtc_present,
    input               solar_present,

    // GPIO register access (gba_memory bram mux, single cycle)
    input               cs,
    input               valid,          // bram_rd | bram_wr
    input               write,
    input       [1:0]   regsel,         // 0 data (C4), 1 direction (C6), 2 control (C8)
    input      [15:0]   wdata,
    output reg [15:0]   rdata,          // registered, valid the cycle after a read
    output              readable,       // control register bit0: reads return GPIO, not ROM

    // Firmware time feed (frame 0x14)
    input      [31:0]   time_unix,
    input      [55:0]   time_bcd,       // BCD, big-endian like the frame:
                                        // [55:48] year, [47:40] mon,
                                        // [39:32] day, [31:24] wday,
                                        // [23:16] hour, [15:8] min, [7:0] sec
    input               time_strobe,    // toggles on every received frame
    input       [7:0]   solar_pct,      // 0..100

    // Save-channel extra sector (byte port, like the EEPROM's second port)
    input       [8:0]   sv_addr,
    input       [7:0]   sv_din,
    input               sv_we,          // one-cycle strobe per restored byte
    output      [7:0]   sv_q,

    output reg          rtc_written     // pulse: the game set the RTC or its control byte
);

/////////////////////////////////////////////////////////////////////////////////
// BCD helpers and the free-running BCD calendar (kept in binary fields)

function [7:0] bin2bcd(input [6:0] v);
    bin2bcd = ((v / 7'd10) << 4) + (v % 7'd10);
endfunction
function [6:0] bcd2bin(input [7:0] v);
    bcd2bin = v[7:4] * 7'd10 + {3'b0, v[3:0]};
endfunction
// The saved-time packing drops the BCD bits that are always zero.
function [6:0] bcd7(input [6:0] v);  bcd7 = bin2bcd(v); endfunction
function [5:0] bcd6(input [6:0] v);  bcd6 = bin2bcd(v); endfunction
function [4:0] bcd5(input [6:0] v);  bcd5 = bin2bcd(v); endfunction

reg [6:0] t_year;                       // 0..99 (2000 + t_year)
reg [3:0] t_mon;                        // 1..12
reg [5:0] t_day;                        // 1..31
reg [2:0] t_wday;                       // 0 = Sunday
reg [4:0] t_hour;                       // 0..23
reg [5:0] t_min, t_sec;

function [5:0] days_in_month(input [3:0] mon, input [6:0] year);
    case (mon)
    4'd2:    days_in_month = (year[1:0] == 2'b00) ? 6'd29 : 6'd28;  // 2000-2099: leap iff %4==0
    4'd4, 4'd6, 4'd9, 4'd11: days_in_month = 6'd30;
    default: days_in_month = 6'd31;
    endcase
endfunction

reg [31:0] unix_counter;
reg [31:0] div_count;
reg [31:0] ff_count;                    // fast-forward seconds still owed
wire       ff_active = ff_count != 0;
wire       sec_tick  = ff_active | (div_count == CLK_HZ - 1);

/////////////////////////////////////////////////////////////////////////////////
// Firmware seed / saved-sector fast-forward

reg        strobe_r;
reg        game_set;                    // the game wrote its RTC: stop re-seeding
reg        sector_loaded;               // a valid "RT" sector was restored
reg        sector_pending;              // ... and still owes its fast-forward
reg        rx_pending;                  // restored sector complete, parse it next cycle
reg [31:0] unix_saved;

/////////////////////////////////////////////////////////////////////////////////
// GPIO pins

reg [3:0] latch, dir, pins_prev;
reg       ctrl_rd;
assign    readable = ctrl_rd;

reg       sio_out;
reg [7:0] solar_count;
wire [15:0] solar_span = solar_pct * 16'd182;
wire [7:0] solar_thr = 8'd250 - solar_span / 16'd100;
wire       solar_flg = solar_count >= solar_thr;
wire [3:0] dev_out = {solar_flg, 1'b0, sio_out, 1'b0};
wire [3:0] live_pins = (latch & dir) | (dev_out & ~dir);

/////////////////////////////////////////////////////////////////////////////////
// S-3511A protocol

localparam ST_CMD = 2'd0, ST_WR = 2'd1, ST_RD = 2'd2, ST_DONE = 2'd3;
reg [1:0]  state;
reg [7:0]  shiftreg;
reg [2:0]  nbits;                       // bits of the current byte so far
reg [2:0]  byteidx, nbytes;
reg [2:0]  cmd;
reg        prev_sck;
reg [3:0]  new_latch, new_dir, newpins; // combinational work regs for pin writes
reg        edge_rising, edge_falling;
reg [7:0]  byte_v;                      // last assembled serial byte
reg [7:0]  control;                     // S-3511A control register (bit6: 24h)
reg [7:0]  buf0, buf1, buf2, buf3, buf4, buf5, buf6;

function [7:0] rd_byte(input [2:0] i);
    case (i)
    3'd0: rd_byte = buf0;
    3'd1: rd_byte = buf1;
    3'd2: rd_byte = buf2;
    3'd3: rd_byte = buf3;
    3'd4: rd_byte = buf4;
    3'd5: rd_byte = buf5;
    default: rd_byte = buf6;
    endcase
endfunction
wire [7:0] cur_rd_byte = rd_byte(byteidx);

// Hour byte in the chip's format for the current 12/24h mode.
function [7:0] hour_bcd(input [4:0] h, input mode24);
    reg [4:0] h12;
    begin
        h12 = h % 7'd12;
        if (h12 == 0) h12 = 5'd12;
        hour_bcd = mode24 ? bin2bcd({2'b0, h}) : {h >= 5'd12, bcd7({2'b0, h12})};
    end
endfunction
function [4:0] hour_bin(input [7:0] b, input mode24);
    reg [6:0] v;
    begin
        v = bcd2bin({1'b0, b[6:0]});
        hour_bin = mode24 ? v[4:0] : (v % 7'd12) + (b[7] ? 7'd12 : 7'd0);
    end
endfunction

/////////////////////////////////////////////////////////////////////////////////
// Save sector encode (dump) / decode (restore)

wire [79:0] sector_v = {6'b0, unix_counter,
    bin2bcd(t_year), bcd5({3'b0, t_mon}),
    bcd6(t_day), t_wday, bcd6({2'b0, t_hour}),
    bcd7(t_min), bcd7(t_sec)};
assign sv_q = sv_addr == 9'd0 ? 8'h54 :             // "RT", little-endian words
              sv_addr == 9'd1 ? 8'h52 :
              sv_addr <  9'd12 ? sector_v[{sv_addr - 9'd2, 3'b0} +: 8] : 8'h00;

reg [7:0] rxb [0:11];                   // restored sector, first 12 bytes
wire [79:0] rx_v = {rxb[11], rxb[10], rxb[9], rxb[8], rxb[7],
                    rxb[6], rxb[5], rxb[4], rxb[3], rxb[2]};

/////////////////////////////////////////////////////////////////////////////////

always @(posedge clk) begin
    rtc_written <= 0;

    if (rst) begin
        latch <= 0; dir <= 0; ctrl_rd <= 0; pins_prev <= 0;
        rdata <= 0;
        state <= ST_CMD; nbits <= 0; byteidx <= 0; prev_sck <= 1;
        sio_out <= 1; control <= 8'h40;
        t_year <= 0; t_mon <= 1; t_day <= 1; t_wday <= 6;   // 2000-01-01, Saturday
        t_hour <= 0; t_min <= 0; t_sec <= 0;
        unix_counter <= 0; div_count <= 0; ff_count <= 0;
        game_set <= 0; sector_loaded <= 0; sector_pending <= 0; rx_pending <= 0;
        strobe_r <= time_strobe;
        solar_count <= 0;
    end else begin

    // ---- 1 Hz tick and calendar advance (also the fast-forward engine) ----
    if (sec_tick) begin
        div_count <= ff_active ? div_count : 0;
        if (ff_active)
            ff_count <= ff_count - 1;
        unix_counter <= unix_counter + 1;
        t_sec <= t_sec + 1;
        if (t_sec == 6'd59) begin
            t_sec <= 0;
            t_min <= t_min + 1;
            if (t_min == 6'd59) begin
                t_min <= 0;
                t_hour <= t_hour + 1;
                if (t_hour == 5'd23) begin
                    t_hour <= 0;
                    t_wday <= t_wday == 3'd6 ? 3'd0 : t_wday + 1;
                    t_day <= t_day + 1;
                    if (t_day == days_in_month(t_mon, t_year)) begin
                        t_day <= 1;
                        t_mon <= t_mon + 1;
                        if (t_mon == 4'd12) begin
                            t_mon <= 1;
                            t_year <= t_year == 7'd99 ? 7'd0 : t_year + 1;
                        end
                    end
                end
            end
        end
    end else
        div_count <= div_count + 1;

    // ---- firmware time frame ----
    strobe_r <= time_strobe;
    if (time_strobe != strobe_r) begin
        unix_counter <= time_unix;
        div_count <= 0;
        if (sector_pending) begin
            sector_pending <= 0;
            if (time_unix >= unix_saved)
                ff_count <= (time_unix - unix_saved > 32'd2678400)  // 31 days
                          ? 32'd2678400 : time_unix - unix_saved;
        end else if (!sector_loaded && !game_set) begin
            t_year <= bcd2bin(time_bcd[55:48]);
            t_mon  <= bcd2bin(time_bcd[47:40]);
            t_day  <= bcd2bin(time_bcd[39:32]);
            t_wday <= bcd2bin(time_bcd[31:24]);
            t_hour <= bcd2bin(time_bcd[23:16]);
            t_min  <= bcd2bin(time_bcd[15:8]);
            t_sec  <= bcd2bin(time_bcd[7:0]);
        end
    end

    // ---- save sector restore stream ----
    if (sv_we && sv_addr < 9'd12) begin
        rxb[sv_addr[3:0]] <= sv_din;
        if (sv_addr == 9'd11)
            rx_pending <= 1;
    end
    if (rx_pending) begin               // rx_v is complete one cycle later
        rx_pending <= 0;
        if (rxb[0] == 8'h54 && rxb[1] == 8'h52 &&
            bcd2bin({3'b0, rx_v[33:29]}) >= 1 && bcd2bin({3'b0, rx_v[33:29]}) <= 12 &&
            bcd2bin({2'b0, rx_v[28:23]}) >= 1 && bcd2bin({2'b0, rx_v[28:23]}) <= 31) begin
            t_sec  <= bcd2bin({1'b0, rx_v[6:0]});
            t_min  <= bcd2bin({1'b0, rx_v[13:7]});
            t_hour <= bcd2bin({2'b0, rx_v[19:14]});
            t_wday <= rx_v[22:20];
            t_day  <= bcd2bin({2'b0, rx_v[28:23]});
            t_mon  <= bcd2bin({3'b0, rx_v[33:29]});
            t_year <= bcd2bin(rx_v[41:34]);
            unix_saved <= rx_v[73:42];
            sector_loaded <= 1;
            sector_pending <= 1;
        end
    end

    // ---- GPIO register access ----
    if (cs && valid) begin
        if (!write) begin
            rdata <= regsel == 2'd0 ? {12'b0, live_pins} :
                     regsel == 2'd1 ? {12'b0, dir} : {15'b0, ctrl_rd};
        end else if (regsel == 2'd2) begin
            ctrl_rd <= wdata[0];
        end else begin
            // Data or direction write: recompute the pins and let the
            // devices react to the edges, like the cartridge hardware.
            new_latch = regsel == 2'd0 ? wdata[3:0] : latch;
            new_dir   = regsel == 2'd1 ? wdata[3:0] : dir;
            newpins   = (new_latch & new_dir) | (dev_out & ~new_dir);
            if (regsel == 2'd0) latch <= new_latch;
            if (regsel == 2'd1) dir <= new_dir;

            // Solar ramp: active while CS (bit2) is low.
            if (solar_present && !newpins[2]) begin
                if (newpins[1])
                    solar_count <= 0;
                else if (newpins[0] && !pins_prev[0])
                    solar_count <= solar_count + 1;
            end

            // S-3511A: bit0 SCK, bit1 SIO, bit2 CS (high = selected).
            if (rtc_present) begin
                if (!newpins[2]) begin
                    state <= ST_CMD;
                    nbits <= 0;
                    prev_sck <= 1;      // SCK is considered high while CS is low
                    sio_out <= 1;
                end else begin
                    edge_rising  =  newpins[0] && !prev_sck;
                    edge_falling = !newpins[0] &&  prev_sck;
                    prev_sck <= newpins[0];
                    case (state)
                    ST_CMD: if (edge_rising) begin
                        shiftreg <= {newpins[1], shiftreg[7:1]};
                        nbits <= nbits + 1;
                        if (nbits == 3'd7) begin
                            byte_v = {newpins[1], shiftreg[7:1]};
                            nbits <= 0;
                            byteidx <= 0;
                            cmd <= byte_v[6:4];
                            if (byte_v[3:0] != 4'h6) begin
                                state <= ST_DONE;
                            end else case (byte_v[6:4])
                            3'd0: begin                 // force reset
                                control <= 0;
                                t_year <= 0; t_mon <= 1; t_day <= 1; t_wday <= 0;
                                t_hour <= 0; t_min <= 0; t_sec <= 0;
                                state <= ST_DONE;
                            end
                            3'd2, 3'd4, 3'd6: begin     // datetime / control / time
                                nbytes <= byte_v[6:4] == 3'd2 ? 3'd7 :
                                          byte_v[6:4] == 3'd4 ? 3'd1 : 3'd3;
                                state <= byte_v[7] ? ST_RD : ST_WR;
                                if (byte_v[7]) begin    // snapshot for the read
                                    buf0 <= bin2bcd(t_year);
                                    buf1 <= bin2bcd({3'b0, t_mon});
                                    buf2 <= bin2bcd(t_day);
                                    buf3 <= {5'b0, t_wday};
                                    buf4 <= hour_bcd(t_hour, control[6]);
                                    buf5 <= bin2bcd(t_min);
                                    buf6 <= bin2bcd(t_sec);
                                    if (byte_v[6:4] == 3'd4)
                                        buf0 <= control;
                                    if (byte_v[6:4] == 3'd6) begin
                                        buf0 <= hour_bcd(t_hour, control[6]);
                                        buf1 <= bin2bcd(t_min);
                                        buf2 <= bin2bcd(t_sec);
                                    end
                                end
                            end
                            default: state <= ST_DONE;  // force IRQ, unused regs
                            endcase
                        end
                    end
                    ST_WR: if (edge_rising) begin
                        shiftreg <= {newpins[1], shiftreg[7:1]};
                        nbits <= nbits + 1;
                        if (nbits == 3'd7) begin
                            byte_v = {newpins[1], shiftreg[7:1]};
                            nbits <= 0;
                            byteidx <= byteidx + 1;
                            case (byteidx)
                            3'd0: buf0 <= byte_v;
                            3'd1: buf1 <= byte_v;
                            3'd2: buf2 <= byte_v;
                            3'd3: buf3 <= byte_v;
                            3'd4: buf4 <= byte_v;
                            3'd5: buf5 <= byte_v;
                            default: buf6 <= byte_v;
                            endcase
                            if (byteidx == nbytes - 1) begin
                                state <= ST_DONE;
                                rtc_written <= 1;
                                if (cmd == 3'd4) begin
                                    control <= byte_v;  // its only byte, not yet in buf0
                                end else if (cmd == 3'd2) begin
                                    // A game datetime write wins over a
                                    // restored sector whose fast-forward is
                                    // still pending: the game set its own
                                    // clock after the load (control writes
                                    // don't: games rewrite those at boot).
                                    sector_pending <= 0;
                                    t_year <= bcd2bin(buf0);
                                    t_mon  <= bcd2bin(buf1);
                                    t_day  <= bcd2bin(buf2);
                                    t_wday <= bcd2bin(buf3);
                                    t_hour <= hour_bin(buf4, control[6]);
                                    t_min  <= bcd2bin(buf5);
                                    t_sec  <= bcd2bin(byte_v);
                                    game_set <= 1;
                                end else if (cmd == 3'd6) begin
                                    sector_pending <= 0;
                                    t_hour <= hour_bin(buf0, control[6]);
                                    t_min  <= bcd2bin(buf1);
                                    t_sec  <= bcd2bin(byte_v);
                                    game_set <= 1;
                                end
                            end
                        end
                    end
                    ST_RD: if (edge_falling) begin
                        sio_out <= cur_rd_byte[nbits];
                        nbits <= nbits + 1;
                        if (nbits == 3'd7) begin
                            nbits <= 0;
                            byteidx <= byteidx + 1;
                            if (byteidx == nbytes - 1)
                                state <= ST_DONE;
                        end
                    end
                    default: ;                  // ST_DONE: wait for CS to drop
                    endcase
                end
            end
            pins_prev <= newpins;
        end
    end
    end
end

endmodule

