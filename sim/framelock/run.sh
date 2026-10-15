#!/bin/sh
# Frame-lock sims (iverilog). From this directory:  ./run.sh
#   tb_frame_lock   the real gba2hdmi (138K BRAM path) with a faithful
#                   hdmi.sv stand-in (hdmi_frame_stub.v: identical cx/cy and
#                   frame_width semantics; iverilog cannot parse the real
#                   packet_assembler.sv) at the native htotal 1657, against a
#                   line-cited model of the GBA frame (1008+224 mclk/line, 228
#                   lines), gated by an exact copy of the gbatang_top halt
#                   block. Startup, 12-frame steady lock, 3-frame menu pause,
#                   200 us core reset. The real hdmi.sv is elaborated under
#                   Verilator instead (see below): it parses the SV the
#                   iverilog image cannot.
#
# Two clock configs (half periods in ns):
#   proposed  clk16 16.90654 MHz (27*67/107, the PLL fix in the report's open
#             questions), clk50 50.25 MHz: must lock (EXPECT_LOCK=1).
#   silicon   clk16 16.75 MHz (current pll_33), clk50 50.25 MHz: the GBA runs
#             slower than HDMI, so the lock must observably fail (EXPECT_LOCK=0
#             negative control, proves the bench detects it).
set -e
cd "$(dirname "$0")"
RTL=../../src
IV="docker run --rm --name framelock_tb --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/framelock tangcore-iv:1"
HDMI="hdmi_frame_stub.v"
$IV sh -c 'iverilog -g2012 -o tb_proposed.out tb_frame_lock.v prim_stubs.v '"$HDMI"' \
    '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v '"$RTL"'/smooth.v \
    -DCLK16H=29.5746 -DCLKP50H=9.9502 -DEXPECT_LOCK=1 -DSTD=0 \
    && vvp tb_proposed.out' 2>&1 | tail -40
$IV sh -c 'iverilog -g2012 -o tb_silicon.out tb_frame_lock.v prim_stubs.v '"$HDMI"' \
    '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v '"$RTL"'/smooth.v \
    -DCLK16H=29.8507 -DCLKP50H=9.9502 -DEXPECT_LOCK=0 -DSTD=0 \
    && vvp tb_silicon.out' 2>&1 | tail -15
