// Stand-ins for the Gowin primitives used by the real hdmi.sv, for simulation.
module OSER10 (output Q, input D0, D1, D2, D3, D4, D5, D6, D7, D8, D9, PCLK, FCLK, RESET);
    assign Q = 1'b0;    // TMDS serial bits are not checked by this bench
endmodule

module ELVDS_OBUF (input I, output O, output OB);
    assign O = I;
    assign OB = ~I;
endmodule

// 74.25 MHz pixel clock stand-in for pll_74 (exact half period in ns).
// CLK16H/CLKP50H come from the bench -D flags; the pixel clock is exact.
// HZ120 (from variant.vh on the include path) runs the 54 MHz pixel clock.
`include "variant.vh"

module pll_74 (input clkin, output reg clkout0, output reg clkout1);
    initial begin clkout0 = 0; clkout1 = 0; end
`ifdef HZ120
    always #9.2592593 clkout0 = ~clkout0;   // 54 MHz (480p120)
`else
    always #6.7340065 clkout0 = ~clkout0;   // 74.25 MHz
`endif
endmodule

// 240x160x18 frame buffer block RAM (one clock of read latency, like fb.v).
module fb (douta, doutb, clka, ocea, cea, reseta, wrea, clkb, oceb, ceb, resetb, wreb, ada, dina, adb, dinb);
    output reg [17:0] douta;
    output reg [17:0] doutb;
    input clka, ocea, cea, reseta, wrea, clkb, oceb, ceb, resetb, wreb;
    input [15:0] ada;
    input [17:0] dina;
    input [15:0] adb;
    input [17:0] dinb;
    reg [17:0] m [0:65535];
    always @(posedge clka) if (wrea) m[ada] <= dina;
    always @(posedge clkb) doutb <= m[adb];
endmodule
