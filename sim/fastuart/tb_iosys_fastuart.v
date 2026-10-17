// iosys_bl616 FAST_UART (commands 0x15/0x16), through the real wire at
// bit level: core ID at 2 Mbaud, negotiate code 3 (8 Mbaud), 4 KB of
// pseudo-random ROM data checked byte for byte at rom_do, the 0x0D CRC
// answer against an independent CRC, one wire byte flipped (CRC must
// catch it), switch back to 2 Mbaud, the 1 s revert watchdog, and an
// out-of-range baud code. FREQ is scaled down 10x so the watchdog (FREQ
// clk cycles) fires in 100 ms of sim time; in FAST_UART mode FREQ feeds
// only that watchdog, the wire rates come from FAST_FREQ.
`timescale 1ns/1ps

module tb_iosys_fastuart;

    parameter FREQ = 2_149_200;                 // watchdog scale only (see above)
    parameter FAST_FREQ = 85_968_000;           // 4x the 21.492 MHz bench clock
    parameter real BIT2M = 500.0;               // ns per bit at 2 Mbaud
    parameter real BIT8M = 125.0;               // ns per bit at 8 Mbaud

    reg clk = 0;
    always #23.264 clk = ~clk;                  // 21.492 MHz
    reg clk_fast = 0;
    always #5.816 clk_fast = ~clk_fast;         // 85.97 MHz
    reg resetn = 1;
    reg uart_rx = 1;
    wire uart_tx;
    wire [7:0] rom_loading, rom_do;
    wire rom_do_valid;

    iosys_bl616 #(.FREQ(FREQ), .CORE_ID(3), .FAST_UART(1), .FAST_FREQ(FAST_FREQ)) dut (
        .clk(clk), .clk_fast(clk_fast), .hclk(clk), .resetn(resetn),
        .overlay(), .overlay_x(8'h00), .overlay_y(8'h00), .overlay_color(),
        .joy1(12'h0), .joy2(12'h0), .hid1(), .hid2(),
        .rom_loading(rom_loading), .rom_do(rom_do), .rom_do_valid(rom_do_valid),
        .mgmt_address(), .mgmt_read(), .mgmt_readdata(16'h0), .mgmt_write(), .mgmt_writedata(),
        .fdd_request(2'b00), .kbd_data(8'h0), .kbd_data_valid(),
        .core_config(), .video_config(),
        .sv_addr(), .sv_din(), .sv_we(), .sv_q(8'h0), .sv_core_we(1'b0),
        .sv_req(), .sv_ack(1'b0),
        .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    // -- independent CRC-32 (zlib) for the expected answers --
    function [31:0] crc32_next(input [31:0] c, input [7:0] d);
        integer i;
        reg [31:0] x;
        begin
            x = c ^ {24'b0, d};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            crc32_next = x;
        end
    endfunction

    // -- deterministic ROM byte i (a hash, so sender and checker agree) --
    function [7:0] rom_byte(input integer i);
        reg [31:0] h;
        begin
            h = (i + 32'h9E3779B9) * 32'h85EBCA6B;
            h = h ^ (h >> 13);
            rom_byte = h[7:0] ^ h[15:8];
        end
    endfunction

    // -- rom_do scoreboard: every loader byte must match the stream --
    integer sb_idx = 0;
    integer sb_base = 0;            // stream offset of the current load
    integer flip_at = -1;           // stream index flipped on the wire (-1 none)
    always @(posedge clk) if (rom_do_valid) begin
        if (rom_do !== wire_byte(sb_base + sb_idx)) begin
            $display("FAIL: rom_do[%0d] = %h, want %h", sb_idx, rom_do,
                     wire_byte(sb_base + sb_idx));
            $fatal(1, "tb_iosys_fastuart: data mismatch");
        end
        sb_idx = sb_idx + 1;
    end
    function [7:0] wire_byte(input integer i);
        wire_byte = (i == flip_at) ? (rom_byte(i) ^ 8'hFF) : rom_byte(i);
    endfunction

    real cur_bit;
    task tx_byte(input [7:0] b);
        integer k;
        begin
            uart_rx = 1'b0; #cur_bit;
            for (k = 0; k < 8; k = k + 1) begin uart_rx = b[k]; #cur_bit; end
            uart_rx = 1'b1; #cur_bit;
        end
    endtask

    task rx_byte(output [7:0] b);
        integer k;
        begin
            wait (uart_tx == 1'b1);
            @(negedge uart_tx);
            #(cur_bit * 1.5);
            for (k = 0; k < 8; k = k + 1) begin b[k] = uart_tx; #cur_bit; end
            if (uart_tx !== 1'b1) begin
                $display("FAIL: reply stop bit not high");
                $fatal(1, "tb_iosys_fastuart: framing");
            end
        end
    endtask

    // receive one AA len type ... frame; payload into pay[0..], plen bytes
    reg [7:0] pay [0:15];
    task rx_frame(output [7:0] typ, output integer plen);
        reg [7:0] b, lh, ll;
        integer i, len;
        begin
            rx_byte(b);
            if (b !== 8'hAA) begin
                $display("FAIL: reply starts %h not AA", b);
                $fatal(1, "tb_iosys_fastuart: reply sync");
            end
            rx_byte(lh); rx_byte(ll); rx_byte(typ);
            len = (lh << 8) | ll;
            plen = len - 1;
            for (i = 0; i < plen; i = i + 1) rx_byte(pay[i]);
        end
    endtask

    task expect_core_id;
        reg [7:0] typ;
        integer plen;
        begin
            tx_byte(8'hAA); tx_byte(8'h00); tx_byte(8'h01); tx_byte(8'h01);
            rx_frame(typ, plen);
            if (typ !== 8'h01 || plen !== 1 || pay[0] !== 8'd3) begin
                $display("FAIL: core id reply typ=%h plen=%0d id=%h", typ, plen, pay[0]);
                $fatal(1, "tb_iosys_fastuart: core id");
            end
        end
    endtask

    task baud_cmd(input [7:0] code, input [7:0] want_accept);
        reg [7:0] typ;
        integer plen;
        begin
            tx_byte(8'hAA); tx_byte(8'h00); tx_byte(8'h02); tx_byte(8'h15);
            tx_byte(code);
            rx_frame(typ, plen);
            if (typ !== 8'h0C || plen !== 2 || pay[0] !== want_accept || pay[1] !== 8'd3) begin
                $display("FAIL: baud ack typ=%h plen=%0d [%h %h], want accept %h",
                         typ, plen, pay[0], pay[1], want_accept);
                $fatal(1, "tb_iosys_fastuart: baud ack");
            end
        end
    endtask

    task set_loading(input [7:0] s);
        begin
            tx_byte(8'hAA); tx_byte(8'h00); tx_byte(8'h02); tx_byte(8'h06);
            tx_byte(s);
            #(4 * cur_bit);
        end
    endtask

    // stream n ROM bytes from stream offset base as 1024-byte cmd-7 frames
    task send_rom(input integer base, input integer n);
        integer sent, chunk, i;
        begin
            sent = 0;
            while (sent < n) begin
                chunk = (n - sent > 1024) ? 1024 : n - sent;
                tx_byte(8'hAA);
                tx_byte((chunk + 1) >> 8);
                tx_byte((chunk + 1) & 255);
                tx_byte(8'h07);
                for (i = 0; i < chunk; i = i + 1)
                    tx_byte(wire_byte(base + sent + i));
                sent = sent + chunk;
            end
            #(4 * cur_bit);
        end
    endtask

    // ask for the CRC answer and check it against crc over the wire stream
    task expect_crc(input integer base, input integer n);
        reg [7:0] typ;
        integer plen, i;
        reg [31:0] c, got_crc, got_cnt;
        begin
            c = 32'hFFFF_FFFF;
            for (i = 0; i < n; i = i + 1) c = crc32_next(c, wire_byte(base + i));
            c = c ^ 32'hFFFF_FFFF;
            tx_byte(8'hAA); tx_byte(8'h00); tx_byte(8'h01); tx_byte(8'h16);
            rx_frame(typ, plen);
            got_crc = {pay[0], pay[1], pay[2], pay[3]};
            got_cnt = {pay[4], pay[5], pay[6], pay[7]};
            if (typ !== 8'h0D || plen !== 8 || got_crc !== c || got_cnt !== n) begin
                $display("FAIL: crc reply typ=%h crc=%h (want %h) cnt=%0d (want %0d)",
                         typ, got_crc, c, got_cnt, n);
                $fatal(1, "tb_iosys_fastuart: crc reply");
            end
        end
    endtask

    reg [31:0] sanity;
    integer i;
    reg [7:0] digits [0:8];
    initial begin
        // bench CRC self-check against the standard vector "123456789"
        digits[0]="1"; digits[1]="2"; digits[2]="3"; digits[3]="4"; digits[4]="5";
        digits[5]="6"; digits[6]="7"; digits[7]="8"; digits[8]="9";
        sanity = 32'hFFFF_FFFF;
        for (i = 0; i < 9; i = i + 1) sanity = crc32_next(sanity, digits[i]);
        if ((sanity ^ 32'hFFFF_FFFF) !== 32'hCBF43926) begin
            $display("FAIL: bench crc vector %h", sanity ^ 32'hFFFF_FFFF);
            $fatal(1, "tb_iosys_fastuart: bench crc broken");
        end

        cur_bit = BIT2M;
        #200 resetn = 0;                        // 1->0: the dual_clk_fifo
        #200;                                   // async resets need the edge
        // Like sim/saveram's benches: response_req/ack have no reset and rely
        // on power-up init (0 on HW and under Verilator); force them for Icarus.
        dut.send_idx = 0; dut.response_req = 0; dut.response_ack = 0;
        dut.joy1_reg = 0; dut.joy2_reg = 0; dut.send_state_next = 0;
        resetn = 1;
        #5000;
        expect_core_id;                       // plain 2 Mbaud still works

        baud_cmd(8'd7, 8'd0);                 // out of range: no switch
        expect_core_id;                       // still at 2 Mbaud

        baud_cmd(8'd3, 8'd3);                 // negotiate 8 Mbaud (ack at 2M)
        #20000;                               // both ends switch in the gap
        cur_bit = BIT8M;
        expect_core_id;                       // confirmed at 8 Mbaud

        sb_base = 0; sb_idx = 0; flip_at = -1;
        set_loading(8'd1);
        send_rom(0, 4096);
        if (sb_idx !== 4096) begin
            $display("FAIL: loader got %0d of 4096 bytes", sb_idx);
            $fatal(1, "tb_iosys_fastuart: byte count");
        end
        expect_crc(0, 4096);
        set_loading(8'd0);

        // one flipped wire byte: data scoreboard follows the wire, the
        // CRC of the unflipped stream must NOT match, the wire CRC must.
        sb_base = 4096; sb_idx = 0; flip_at = 4096 + 100;
        set_loading(8'd1);
        send_rom(4096, 1024);
        expect_crc(4096, 1024);               // over wire bytes (flip incl.)
        begin : flipped_differs
            // The reply just matched the flipped stream's CRC; the
            // unflipped stream's CRC (what the firmware computes over
            // the file) must differ, i.e. the check detects the error.
            reg [31:0] c_orig, c_wire;
            integer j;
            c_orig = 32'hFFFF_FFFF; c_wire = 32'hFFFF_FFFF;
            for (j = 0; j < 1024; j = j + 1) begin
                c_orig = crc32_next(c_orig, rom_byte(4096 + j));
                c_wire = crc32_next(c_wire, wire_byte(4096 + j));
            end
            if (c_orig === c_wire) begin
                $display("FAIL: flipped byte left the CRC unchanged");
                $fatal(1, "tb_iosys_fastuart: crc blind to flip");
            end
        end
        flip_at = -1;
        set_loading(8'd0);

        baud_cmd(8'd0, 8'd0);                 // switch back (ack at 8M)
        #20000;
        cur_bit = BIT2M;
        expect_core_id;                       // back at 2 Mbaud

        baud_cmd(8'd3, 8'd3);                 // to 8 Mbaud again, then silence
        #120_000_000;                         // > the 100 ms scaled watchdog
        expect_core_id;                       // at 2M: the core reverted itself

        $display("tb_iosys_fastuart: PASS");
        $finish;
    end

    initial begin
        #400_000_000;
        $fatal(1, "tb_iosys_fastuart: timeout");
    end
endmodule
