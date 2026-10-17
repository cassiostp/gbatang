// Testbench for gba_gpio_rtc (cart GPIO + S-3511A RTC + solar sensor).
// Bit-bangs the 3-wire RTC protocol the way a game driver does (GBATEK):
// CS frames a transfer, command/data bits go LSB-first, SIO is sampled on
// SCK rising edges (writes) and driven on falling edges (reads). Covers
// datetime read/write, the control register and 12h hour format, the
// time-only read, the solar ramp ADC count, the MiSTer-format save
// sector (encode + restore fast-forward), and firmware re-seeding rules.

`timescale 1ns/1ps

module tb_gba_gpio_rtc;

reg clk = 0;
always #5 clk = ~clk;

reg        rst = 0;
reg        cs = 0, valid = 0, write = 0;
reg  [1:0] regsel = 0;
reg [15:0] wdata = 0;
wire [15:0] rdata;
wire       readable;
reg [31:0] time_unix = 0;
reg [55:0] time_bcd = 0;
reg        time_strobe = 0;
reg  [7:0] solar_pct = 50;
reg  [8:0] sv_addr = 0;
reg  [7:0] sv_din = 0;
reg        sv_we = 0;
wire [7:0] sv_q;
wire       rtc_written;

integer errs = 0;
reg     saw_rtc_written = 0;
always @(posedge clk) if (rtc_written) saw_rtc_written <= 1;

// CLK_HZ small enough to tick, large enough that bit-banging (a few
// thousand clocks) never crosses a second unless the test wants it to.
gba_gpio_rtc #(.CLK_HZ(100000)) dut (
    .clk(clk), .rst(rst), .rtc_present(1'b1), .solar_present(1'b1),
    .cs(cs), .valid(valid), .write(write), .regsel(regsel), .wdata(wdata),
    .rdata(rdata), .readable(readable),
    .time_unix(time_unix), .time_bcd(time_bcd), .time_strobe(time_strobe),
    .solar_pct(solar_pct),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we), .sv_q(sv_q),
    .rtc_written(rtc_written)
);

task check(input cond, input [8*64-1:0] what);
    if (!cond) begin
        errs = errs + 1;
        $display("FAIL: %0s (t=%0t)", what, $time);
    end
endtask

task gpio_wr(input [1:0] r, input [15:0] v);
    begin
        @(negedge clk); cs = 1; valid = 1; write = 1; regsel = r; wdata = v;
        @(negedge clk); cs = 0; valid = 0; write = 0;
    end
endtask

task gpio_rd(input [1:0] r, output [15:0] v);
    begin
        @(negedge clk); cs = 1; valid = 1; write = 0; regsel = r;
        @(negedge clk); cs = 0; valid = 0; v = rdata;
    end
endtask

// Pin-level helpers. Current direction/latch are tracked on the TB side
// only through data writes, exactly like a driver: pins = {flg,cs,sio,sck}.
reg [3:0] pins;
task pins_wr(input [3:0] v);
    begin
        pins = v;
        gpio_wr(2'd0, {12'b0, v});
    end
endtask

task send_bit(input b);
    begin
        pins_wr({1'b0, 1'b1, b, 1'b0});     // CS=1 SIO=b SCK=0
        pins_wr({1'b0, 1'b1, b, 1'b1});     // SCK rising: chip samples
    end
endtask

task send_byte(input [7:0] v);
    integer i;
    for (i = 0; i < 8; i = i + 1) send_bit(v[i]);
endtask

task recv_bit(output b);
    reg [15:0] v;
    begin
        pins_wr({1'b0, 1'b1, 1'b0, 1'b0});  // SCK falling: chip drives SIO
        gpio_rd(2'd0, v);
        b = v[1];
        pins_wr({1'b0, 1'b1, 1'b0, 1'b1});
    end
endtask

task recv_byte(output [7:0] v);
    integer i;
    reg b;
    for (i = 0; i < 8; i = i + 1) begin recv_bit(b); v[i] = b; end
endtask

task xfer_begin;
    begin
        gpio_wr(2'd1, 16'h0007);            // SCK/SIO/CS outputs
        pins_wr(4'b0000);                   // CS low
        pins_wr(4'b0101);                   // CS high, SCK high
    end
endtask
task xfer_end;
    pins_wr(4'b0000);
endtask
task dir_sio_in;
    gpio_wr(2'd1, 16'h0005);                // SIO becomes an input
endtask
task dir_sio_out;
    gpio_wr(2'd1, 16'h0007);
endtask

task send_time_frame(input [31:0] unix_s,
                     input [7:0] y, input [7:0] mo, input [7:0] d,
                     input [7:0] wd, input [7:0] h, input [7:0] mi,
                     input [7:0] s);
    // Byte order must match the firmware's clock_send_to_core: unix BE32,
    // then BCD year mon day wday hour min sec (a swapped year/sec here
    // once passed this bench while disagreeing with the firmware).
    begin
        @(negedge clk);
        time_unix = unix_s;
        time_bcd = {y, mo, d, wd, h, mi, s};
        time_strobe = ~time_strobe;
        repeat (4) @(negedge clk);
    end
endtask

reg [7:0] rb [0:6];
reg [7:0] sector [0:11];
integer i, n;
reg [15:0] v16;

initial begin
    // ---- reset + firmware seed: 2026-10-13 (Tue) 12:34:56 ----
    rst = 1; repeat (4) @(negedge clk); rst = 0; repeat (2) @(negedge clk);
    check(readable == 0, "write-only after reset");
    gpio_wr(2'd2, 16'h0001);
    check(readable == 1, "readable after control write");
    send_time_frame(32'd1791894840, 8'h26, 8'h10, 8'h13, 8'h02, 8'h12, 8'h34, 8'h56);

    xfer_begin; send_byte(8'hA6); dir_sio_in;   // datetime read
    for (i = 0; i < 7; i = i + 1) recv_byte(rb[i]);
    xfer_end;
    check(rb[0] == 8'h26 && rb[1] == 8'h10 && rb[2] == 8'h13 && rb[3] == 8'h02 &&
          rb[4] == 8'h12 && rb[5] == 8'h34 && (rb[6] == 8'h56 || rb[6] == 8'h57),
          "datetime read returns the seeded time");

    // ---- control register + 12h format ----
    xfer_begin; send_byte(8'hC6); dir_sio_in; recv_byte(rb[0]); xfer_end;
    check(rb[0] == 8'h40, "control defaults to 24h mode");
    xfer_begin; send_byte(8'h46); send_byte(8'h00); xfer_end;   // 12h mode
    check(saw_rtc_written, "control write pulses rtc_written");
    xfer_begin; send_byte(8'hE6); dir_sio_in;   // time read
    recv_byte(rb[0]); recv_byte(rb[1]); recv_byte(rb[2]); xfer_end;
    check(rb[0] == 8'h92 && rb[1] == 8'h34, "12h hour is 12 PM (0x92)");
    xfer_begin; send_byte(8'h46); send_byte(8'h40); xfer_end;   // back to 24h

    // ---- datetime write: 2027-01-02 (Sat) 03:04:05, then read back ----
    saw_rtc_written = 0;
    xfer_begin; send_byte(8'h26);
    send_byte(8'h27); send_byte(8'h01); send_byte(8'h02); send_byte(8'h06);
    send_byte(8'h03); send_byte(8'h04); send_byte(8'h05);
    xfer_end;
    check(saw_rtc_written, "datetime write pulses rtc_written");
    // A later firmware frame must not override the game's own clock.
    send_time_frame(32'd1791894900, 8'h26, 8'h10, 8'h13, 8'h02, 8'h12, 8'h35, 8'h56);
    xfer_begin; send_byte(8'hA6); dir_sio_in;
    for (i = 0; i < 7; i = i + 1) recv_byte(rb[i]);
    xfer_end;
    check(rb[0] == 8'h27 && rb[1] == 8'h01 && rb[2] == 8'h02 && rb[3] == 8'h06 &&
          rb[4] == 8'h03 && rb[5] == 8'h04 && rb[6] == 8'h05,
          "datetime write took effect and survives re-seed");

    // ---- solar ramp: 50% -> threshold 159 ----
    gpio_wr(2'd1, 16'h0007);
    pins_wr(4'b0010);                       // RST high (bit1), CS low
    pins_wr(4'b0000);
    n = 0;
    gpio_rd(2'd0, v16);
    while (!v16[3] && n < 300) begin
        pins_wr(4'b0001);                   // CLK rising
        pins_wr(4'b0000);
        n = n + 1;
        gpio_rd(2'd0, v16);
    end
    check(n == 159, "solar ADC trips at the 50% count");

    // ---- save sector encode ----
    for (i = 0; i < 12; i = i + 1) begin
        sv_addr = i[8:0]; #1; sector[i] = sv_q;
    end
    check(sector[0] == 8'h54 && sector[1] == 8'h52, "sector carries RT tag");
    // Full payload, packed independently here: 2027-01-02 Sat 03:04:05 at
    // unix 1791894900 (the last frame; no tick elapsed since).
    begin : sector_check
        reg [79:0] want;
        want = {6'b0, 32'd1791894900, 8'h27, 5'h01, 6'h02, 3'd6,
                6'h03, 7'h04, 7'h05};
        for (i = 0; i < 10; i = i + 1)
            check(sector[2 + i] == want[i * 8 +: 8], "sector payload byte");
    end

    // ---- restore + fast-forward by 1h02m05s ----
    rst = 1; repeat (4) @(negedge clk); rst = 0; repeat (2) @(negedge clk);
    gpio_wr(2'd2, 16'h0001);
    for (i = 0; i < 12; i = i + 1) begin
        @(negedge clk); sv_addr = i[8:0]; sv_din = sector[i]; sv_we = 1;
        @(negedge clk); sv_we = 0;
    end
    repeat (4) @(negedge clk);
    send_time_frame(32'd1791894900 + 32'd3725, 8'h26, 8'h10, 8'h13, 8'h02,
                    8'h13, 8'h37, 8'h41);
    repeat (4000) @(negedge clk);           // fast-forward runs 1 s/clock
    xfer_begin; send_byte(8'hA6); dir_sio_in;
    for (i = 0; i < 7; i = i + 1) recv_byte(rb[i]);
    xfer_end;
    check(rb[0] == 8'h27 && rb[1] == 8'h01 && rb[2] == 8'h02 && rb[3] == 8'h06 &&
          rb[4] == 8'h04 && rb[5] == 8'h06 && rb[6] == 8'h10,
          "restored clock fast-forwarded by the saved interval");

    if (errs == 0) $display("tb_gba_gpio_rtc: PASS");
    else $fatal(1, "tb_gba_gpio_rtc: FAIL, %0d errors", errs);
    $finish;
end

initial begin #(20_000_000); $fatal(1, "TIMEOUT: sim hang"); end

endmodule
