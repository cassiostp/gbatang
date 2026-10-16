// Runtime-baud UART RX/TX for the fast ROM-load link (iosys FAST_UART).
//
// Same structure as uart_fixed.v (fpga4fun async_receiver/transmitter with a
// fractional BaudTickGen), but the tick increment is selected at runtime by
// baud_code: 0=BAUD0 (the normal 2 Mbaud), 1=BAUD1, 2=BAUD2, 3=BAUD3. These
// run in a fast clock domain (e.g. the 67 MHz SDRAM clock) so the receiver
// keeps >= 8x oversampling at the fast rates; ClkFrequency must satisfy
// ClkFrequency >= BAUD3*8. Switch baud_code only while both directions are
// idle (iosys_bl616 enforces that), so a byte is never mid-flight at a switch.
//
// Author: TangCore fastload (derived from uart_fixed.v, (c) fpga4fun/KNJN)

module BaudTickGenN(
	input clk, enable,
	input [1:0] baud_code,
	output tick
);
parameter ClkFrequency = 67000000;
parameter Baud0 = 2000000;
parameter Baud1 = 4000000;
parameter Baud2 = 5000000;
parameter Baud3 = 8000000;
parameter Oversampling = 1;

localparam AccWidth = 19;
// nand2mario's idiom from uart_fixed.v: the longint cast avoids 32-bit
// overflow (524288 * 8M * 8). The explicit [AccWidth:0] range matters too:
// every value fits (the largest, 8 Mbaud at 67.25 MHz x8, is ~498950 <
// 2^19), and without it Icarus minimal-sizes the unsized localparam, so the
// slices below would read out-of-range X. (uart_fixed.v's ASSERTION_ERROR
// guards are omitted here on purpose: Verilator rejects them, see sim/cosim's
// uart_fixed_sim.v sed. ClkFrequency >= BAUD3*8 is stated in the header.)
localparam [AccWidth:0] Inc0 = (longint'(1 << AccWidth) * Baud0 * Oversampling + ClkFrequency/2) / ClkFrequency;
localparam [AccWidth:0] Inc1 = (longint'(1 << AccWidth) * Baud1 * Oversampling + ClkFrequency/2) / ClkFrequency;
localparam [AccWidth:0] Inc2 = (longint'(1 << AccWidth) * Baud2 * Oversampling + ClkFrequency/2) / ClkFrequency;
localparam [AccWidth:0] Inc3 = (longint'(1 << AccWidth) * Baud3 * Oversampling + ClkFrequency/2) / ClkFrequency;

reg [AccWidth:0] Inc = Inc0;
always @* case (baud_code)
	0: Inc = Inc0;
	1: Inc = Inc1;
	2: Inc = Inc2;
	default: Inc = Inc3;
endcase

reg [AccWidth:0] Acc = 0;
always @(posedge clk)
	if (enable)
		Acc <= Acc[AccWidth-1:0] + Inc;
	else
		Acc <= Inc;

assign tick = Acc[AccWidth];
endmodule


module fast_async_transmitter(
	input clk,
	input TxD_start,
	input [7:0] TxD_data,
	input [1:0] baud_code,
	output TxD,
	output TxD_busy
);
parameter ClkFrequency = 67000000;
parameter Baud0 = 2000000;
parameter Baud1 = 4000000;
parameter Baud2 = 5000000;
parameter Baud3 = 8000000;

wire BitTick;
BaudTickGenN #(ClkFrequency, Baud0, Baud1, Baud2, Baud3, 1) tickgen(
	.clk(clk), .enable(TxD_busy), .baud_code(baud_code), .tick(BitTick));

reg [3:0] TxD_state = 0;
wire TxD_ready = (TxD_state==0);
assign TxD_busy = ~TxD_ready;

reg [7:0] TxD_shift = 0;
always @(posedge clk)
begin
	if(TxD_ready & TxD_start)
		TxD_shift <= TxD_data;
	else
	if(TxD_state[3] & BitTick)
		TxD_shift <= (TxD_shift >> 1);

	case(TxD_state)
		4'b0000: if(TxD_start) TxD_state <= 4'b0100;
		4'b0100: if(BitTick) TxD_state <= 4'b1000;  // start bit
		4'b1000: if(BitTick) TxD_state <= 4'b1001;  // bit 0
		4'b1001: if(BitTick) TxD_state <= 4'b1010;  // bit 1
		4'b1010: if(BitTick) TxD_state <= 4'b1011;  // bit 2
		4'b1011: if(BitTick) TxD_state <= 4'b1100;  // bit 3
		4'b1100: if(BitTick) TxD_state <= 4'b1101;  // bit 4
		4'b1101: if(BitTick) TxD_state <= 4'b1110;  // bit 5
		4'b1110: if(BitTick) TxD_state <= 4'b1111;  // bit 6
		4'b1111: if(BitTick) TxD_state <= 4'b0010;  // bit 7
		4'b0010: if(BitTick) TxD_state <= 4'b0011;  // stop1
		4'b0011: if(BitTick) TxD_state <= 4'b0000;  // stop2
		default: if(BitTick) TxD_state <= 4'b0000;
	endcase
end

assign TxD = (TxD_state<4) | (TxD_state[3] & TxD_shift[0]);
endmodule


module fast_async_receiver(
	input clk,
	input RxD,
	input [1:0] baud_code,
	output reg RxD_data_ready = 0,
	output reg [7:0] RxD_data = 0, 
	output RxD_idle,
	output reg RxD_endofpacket = 0
);
parameter ClkFrequency = 67000000;
parameter Baud0 = 2000000;
parameter Baud1 = 4000000;
parameter Baud2 = 5000000;
parameter Baud3 = 8000000;
parameter Oversampling = 8;

reg [3:0] RxD_state = 0;

wire OversamplingTick;
BaudTickGenN #(ClkFrequency, Baud0, Baud1, Baud2, Baud3, Oversampling) tickgen(
	.clk(clk), .enable(1'b1), .baud_code(baud_code), .tick(OversamplingTick));

reg [1:0] RxD_sync = 2'b11;
always @(posedge clk) if(OversamplingTick) RxD_sync <= {RxD_sync[0], RxD};

reg [1:0] Filter_cnt = 2'b11;
reg RxD_bit = 1'b1;
always @(posedge clk)
if(OversamplingTick)
begin
	if(RxD_sync[1]==1'b1 && Filter_cnt!=2'b11) Filter_cnt <= Filter_cnt + 1'd1;
	else
	if(RxD_sync[1]==1'b0 && Filter_cnt!=2'b00) Filter_cnt <= Filter_cnt - 1'd1;

	if(Filter_cnt==2'b11) RxD_bit <= 1'b1;
	else
	if(Filter_cnt==2'b00) RxD_bit <= 1'b0;
end

function integer log2(input integer v); begin log2=0; while(v>>log2) log2=log2+1; end endfunction
localparam l2o = log2(Oversampling);
reg [l2o-2:0] OversamplingCnt = 0;
always @(posedge clk) if(OversamplingTick) OversamplingCnt <= (RxD_state==0) ? 1'd0 : OversamplingCnt + 1'd1;
wire sampleNow = OversamplingTick && (OversamplingCnt==Oversampling/2-1);

always @(posedge clk)
case(RxD_state)
	4'b0000: if(~RxD_bit) RxD_state <= 4'b0001;  // start bit found?
	4'b0001: if(sampleNow) RxD_state <= 4'b1000;  // sync start bit to sampleNow
	4'b1000: if(sampleNow) RxD_state <= 4'b1001;  // bit 0
	4'b1001: if(sampleNow) RxD_state <= 4'b1010;  // bit 1
	4'b1010: if(sampleNow) RxD_state <= 4'b1011;  // bit 2
	4'b1011: if(sampleNow) RxD_state <= 4'b1100;  // bit 3
	4'b1100: if(sampleNow) RxD_state <= 4'b1101;  // bit 4
	4'b1101: if(sampleNow) RxD_state <= 4'b1110;  // bit 5
	4'b1110: if(sampleNow) RxD_state <= 4'b1111;  // bit 6
	4'b1111: if(sampleNow) RxD_state <= 4'b0010;  // bit 7
	4'b0010: if(sampleNow) RxD_state <= 4'b0000;  // stop bit
	default: RxD_state <= 4'b0000;
endcase

always @(posedge clk)
if(sampleNow && RxD_state[3]) RxD_data <= {RxD_bit, RxD_data[7:1]};

always @(posedge clk)
begin
	RxD_data_ready <= (sampleNow && RxD_state==4'b0010 && RxD_bit);
end

reg [l2o+1:0] GapCnt = 0;
always @(posedge clk) if (RxD_state!=0) GapCnt<=0; else if(OversamplingTick & ~GapCnt[log2(Oversampling)+1]) GapCnt <= GapCnt + 1'h1;
assign RxD_idle = GapCnt[l2o+1];
always @(posedge clk) RxD_endofpacket <= OversamplingTick & ~GapCnt[l2o+1] & &GapCnt[l2o:0];

endmodule
