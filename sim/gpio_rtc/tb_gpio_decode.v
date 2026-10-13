// CPU-path check for the cartridge GPIO window (gba_memory decode +
// gba_gpio_rtc wired as in gbatang_top): loader byte 1 enables the devices,
// 16-bit LDRH/STRH to 0x080000C4/C6/C8 reach the block, reads fall through
// to ROM in write-only mode, and 32-bit accesses never touch GPIO.
`timescale 1ns/1ps

module tb_gpio_decode;

reg clk = 0;
always #30 clk = ~clk;                 // ~16.6 MHz like the core

reg resetn = 0;
reg rom_en = 0;
reg [31:0] rom_addr = 0;
reg thumb = 0;
reg ram_cen = 0, ram_wen = 0;
reg [31:0] ram_addr = 0, ram_wdata = 0;
reg [3:0] ram_be = 0;
wire [31:0] ram_rdata, rom_data;
wire cpu_en;

reg [2:0] loading = 0;
reg [7:0] loader_data = 0;
reg loader_valid = 0;
wire gbaon;
wire [2:0] config_backup_type;
wire [1:0] config_gpio;

wire gpio_cs, gpio_valid, gpio_write, gpio_readable;
wire [1:0] gpio_regsel;
wire [15:0] gpio_wdata, gpio_rdata;

reg [31:0] time_unix = 0;
reg [55:0] time_bcd = 0;
reg time_strobe = 0;
reg [7:0] solar_pct = 50;

integer errs = 0;

wire [31:0] sdram_rdata [1:3];
assign sdram_rdata[1] = 32'hA5A5A5A5;   // fake ROM content at the GPIO window
assign sdram_rdata[2] = 32'hA5A5A5A5;
assign sdram_rdata[3] = 32'hA5A5A5A5;

gba_memory mem (
    .clk(clk), .resetn(resetn), .ce(1'b1),
    .rom_en(rom_en), .rom_addr(rom_addr), .rom_data(rom_data),
    .thumb(thumb), .cpu_en(cpu_en),
    .ram_cen(ram_cen), .ram_wen(ram_wen), .ram_addr(ram_addr),
    .ram_rdata(ram_rdata), .ram_wdata(ram_wdata), .ram_be(ram_be),
    .dma_on(1'b0), .dma_addr(32'h0), .dma_wdata(32'h0), .dma_ena(1'b0),
    .dma_wr(1'b0), .dma_be(4'h0), .dma_rdata(), .dma_done(),
    .dma_eepromcount(17'd0),
    .gb_bus_din(), .gb_bus_dout(32'h0), .gb_bus_adr(), .gb_bus_rnw(),
    .gb_bus_ena(), .gb_bus_done(), .gb_bus_acc(), .gb_bus_be(), .gb_bus_rst(),
    .sdram_addr(), .sdram_wdata(), .sdram_rdata(sdram_rdata),
    .sdram_rd(), .sdram_wr(), .sdram_be(), .sdram_port(),
    .sdram_ready(1'b1), .backup_written(1'b0),
    .eeprom_rd(1'b0), .eeprom_wr(4'h0), .eeprom_addr(13'h0),
    .eeprom_rdata(), .eeprom_wdata(8'h0), .eeprom_written(),
    .loading(loading), .loader_data(loader_data), .loader_valid(loader_valid),
    .gbaon(gbaon), .config_backup_type(config_backup_type),
    .config_gpio(config_gpio),
    .gpio_cs(gpio_cs), .gpio_valid(gpio_valid), .gpio_write(gpio_write),
    .gpio_regsel(gpio_regsel), .gpio_wdata(gpio_wdata),
    .gpio_rdata(gpio_rdata), .gpio_readable(gpio_readable),
    .cartram_dirty(), .cartram_dirty_clear(1'b0),
    .vram_lo_addr(), .vram_lo_din(), .vram_lo_dout(32'h0),
    .vram_lo_we(), .vram_lo_be(),
    .vram_hi_addr(), .vram_hi_din(), .vram_hi_dout(32'h0),
    .vram_hi_we(), .vram_hi_be(),
    .oamram_addr(), .oamram_din(), .oamram_dout(32'h0), .oamram_we(),
    .palette_bg_addr(), .palette_bg_din(), .palette_bg_dout(32'h0),
    .palette_bg_we(),
    .palette_oam_addr(), .palette_oam_din(), .palette_oam_dout(32'h0),
    .palette_oam_we()
);

gba_gpio_rtc #(.CLK_HZ(100000)) rtc (
    .clk(clk), .rst(loading == 3'd1),
    .rtc_present(config_gpio[0]), .solar_present(config_gpio[1]),
    .cs(gpio_cs), .valid(gpio_valid), .write(gpio_write),
    .regsel(gpio_regsel), .wdata(gpio_wdata),
    .rdata(gpio_rdata), .readable(gpio_readable),
    .time_unix(time_unix), .time_bcd(time_bcd), .time_strobe(time_strobe),
    .solar_pct(solar_pct),
    .sv_addr(9'd0), .sv_din(8'h0), .sv_we(1'b0), .sv_q(),
    .rtc_written()
);

task check(input cond, input [8*64-1:0] what);
    if (!cond) begin
        errs = errs + 1;
        $display("FAIL: %0s (t=%0t)", what, $time);
    end
endtask

// One 16-bit CPU data access; holds the request past cpu_en like the CPU.
task cpu_wr(input [27:0] a, input [15:0] v);
    begin
        @(negedge clk);
        ram_cen = 1; ram_wen = 1; ram_addr = {4'h0, a};
        ram_wdata = a[1] ? {v, 16'h0} : {16'h0, v};
        ram_be = a[1] ? 4'b1100 : 4'b0011;
        @(posedge clk);                 // request sampled here
        @(negedge clk);
        ram_cen = 0; ram_wen = 0; ram_be = 0;
    end
endtask

task cpu_rd(input [27:0] a, output [15:0] v);
    begin
        @(negedge clk);
        ram_cen = 1; ram_wen = 0; ram_addr = {4'h0, a};
        ram_be = a[1] ? 4'b1100 : 4'b0011;
        @(posedge clk);
        @(posedge clk); #1;             // data valid the cycle after cpu_en
        v = a[1] ? ram_rdata[31:16] : ram_rdata[15:0];
        @(negedge clk);
        ram_cen = 0; ram_be = 0;
    end
endtask

task cfg_byte(input [7:0] v);
    begin
        @(negedge clk); loader_data = v; loader_valid = 1;
        @(negedge clk); loader_valid = 0;
    end
endtask

// Pin-level RTC bit-bang through the CPU port (pins = {flg,cs,sio,sck}).
task pins_wr(input [3:0] v);
    cpu_wr(28'h80000C4, {12'b0, v});
endtask
task send_bit(input b);
    begin
        pins_wr({1'b0, 1'b1, b, 1'b0});
        pins_wr({1'b0, 1'b1, b, 1'b1});
    end
endtask
task send_byte(input [7:0] v);
    integer i;
    for (i = 0; i < 8; i = i + 1) send_bit(v[i]);
endtask
task recv_bit(output b);
    reg [15:0] v;
    begin
        pins_wr({1'b0, 1'b1, 1'b0, 1'b0});
        cpu_rd(28'h80000C4, v);
        b = v[1];
        pins_wr({1'b0, 1'b1, 1'b0, 1'b1});
    end
endtask
task recv_byte(output [7:0] v);
    integer i;
    reg b;
    for (i = 0; i < 8; i = i + 1) begin recv_bit(b); v[i] = b; end
endtask

reg [15:0] v16;
reg [7:0] rb;
reg rb1;
integer i;

initial begin
    mem.state = 0;                      // no reset on the state machine
    repeat (4) @(negedge clk);
    resetn = 1;
    // A ROM load resets the loader config and the RTC, like hardware.
    @(negedge clk); loading = 1;
    repeat (4) @(negedge clk); loading = 0;
    repeat (2) @(negedge clk);

    // ---- no GPIO yet: C4 reads fall through to ROM, writes are dropped --
    cpu_rd(28'h80000C4, v16);
    check(v16 == 16'hA5A5, "write-only C4 reads ROM before enable");
    check(gpio_cs == 0, "gpio quiet with no loader flags");

    // ---- loader config: no backup, RTC+solar, solar % (ignored) ----------
    @(negedge clk); loading = 3;
    cfg_byte(8'd0);
    cfg_byte(8'd3);
    cfg_byte(8'd50);
    @(negedge clk); loading = 0;
    repeat (2) @(negedge clk);
    check(config_gpio == 2'd3, "loader byte 1 reaches config_gpio");

    // ---- still write-only: reads stay ROM --------------------------------
    cpu_rd(28'h80000C4, v16);
    check(v16 == 16'hA5A5, "write-only C4 reads ROM after enable");

    // ---- enable read/write mode ------------------------------------------
    cpu_wr(28'h80000C8, 16'h0001);
    cpu_rd(28'h80000C8, v16);
    check(v16 == 16'h0001, "control reads back in R/W mode");
    cpu_wr(28'h80000C6, 16'h0007);
    cpu_rd(28'h80000C6, v16);
    check(v16 == 16'h0007, "direction reads back");

    // ---- seed the clock, read it back through the CPU port ---------------
    @(negedge clk);
    time_unix = 32'd1791894840;
    time_bcd = {8'h26, 8'h10, 8'h13, 8'h02, 8'h12, 8'h34, 8'h56};
    time_strobe = ~time_strobe;
    repeat (4) @(negedge clk);
    pins_wr(4'b0000);
    pins_wr(4'b0101);
    send_byte(8'hA6);
    cpu_wr(28'h80000C6, 16'h0005);       // SIO becomes an input
    for (i = 0; i < 7; i = i + 1) begin
        recv_byte(rb);
        case (i)
        0: check(rb == 8'h26, "cpu-path datetime year");
        1: check(rb == 8'h10, "cpu-path datetime mon");
        2: check(rb == 8'h13, "cpu-path datetime day");
        3: check(rb == 8'h02, "cpu-path datetime wday");
        4: check(rb == 8'h12, "cpu-path datetime hour");
        5: check(rb == 8'h34, "cpu-path datetime min");
        6: check(rb == 8'h56 || rb == 8'h57, "cpu-path datetime sec");
        endcase
    end
    pins_wr(4'b0000);

    // ---- 32-bit and 8-bit accesses never touch GPIO -----------------------
    @(negedge clk);
    ram_cen = 1; ram_wen = 1; ram_addr = 32'h080000C4;
    ram_wdata = 32'hDEADBEEF; ram_be = 4'b1111;
    @(posedge clk); #1;
    check(gpio_cs == 0, "32-bit write ignores GPIO");
    @(negedge clk); ram_cen = 0; ram_be = 0;
    @(negedge clk);
    ram_cen = 1; ram_wen = 0; ram_addr = 32'h080000C4; ram_be = 4'b0001;
    @(posedge clk); #1;
    check(gpio_cs == 0, "8-bit read ignores GPIO");
    @(negedge clk); ram_cen = 0; ram_be = 0;

    // ---- mirror bank: C4 at 0x0A0000C4 hits too ---------------------------
    cpu_wr(28'hA0000C8, 16'h0001);
    cpu_rd(28'hA0000C8, v16);
    check(v16 == 16'h0001, "mirror-bank control works");

    // ---- new game without GPIO: the window is plain ROM again -------------
    @(negedge clk); loading = 1;
    repeat (4) @(negedge clk); loading = 0;
    @(negedge clk); loading = 3;
    cfg_byte(8'd3);
    cfg_byte(8'd0);
    @(negedge clk); loading = 0;
    repeat (2) @(negedge clk);
    cpu_rd(28'h80000C4, v16);
    check(v16 == 16'hA5A5, "C4 is ROM again without flags");
    check(gpio_cs == 0, "gpio quiet without flags");

    if (errs == 0) $display("tb_gpio_decode: PASS");
    else $fatal(1, "tb_gpio_decode: FAIL, %0d errors", errs);
    $finish;
end

initial begin #(20_000_000); $fatal(1, "TIMEOUT: sim hang"); end

endmodule
