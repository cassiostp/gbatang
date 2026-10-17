// Stand-ins for the Gowin parts of gba2hdmi, for simulation: the video PLL and the
// 240x160 frame buffer block RAM (one clock of read latency).
// HZ120 (from variant.vh on the include path) runs the 54 MHz pixel clock.
`include "variant.vh"

module pll_74 (input clkin, output reg clkout0, output reg clkout1);
    initial begin clkout0 = 0; clkout1 = 0; end
`ifdef HZ120
    always #9.2593 clkout0 = ~clkout0;       // 54 MHz
`else
    always #6.734 clkout0 = ~clkout0;       // 74.25 MHz
`endif
endmodule

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
