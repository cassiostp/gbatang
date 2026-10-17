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
# Three clock configs (half periods in ns):
#   138K      clk16 16.8125 MHz (27*67.25/108, the round-2 PLL), clk50
#             50.4375 MHz: must lock (EXPECT_LOCK=1).
#   60K       clk16 16.81875 MHz (27*37.375/60), clk50 50.45625 MHz: must
#             lock (EXPECT_LOCK=1; same BRAM bench, 60K clocks).
#   slow      clk16 16.75 MHz (pre-round-2 pll_33), clk50 50.25 MHz: the GBA
#             runs slower than HDMI, so the lock must observably fail
#             (EXPECT_LOCK=0 negative control, proves the bench detects it).
set -e
cd "$(dirname "$0")"
RTL=../../src
IV="docker run --rm --name gbaaudio_framelock_tb --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/framelock tangcore-iv:1"
HDMI="hdmi_frame_stub.v"
$IV sh -c 'iverilog -g2012 -o tb_138k.out tb_frame_lock.v prim_stubs.v '"$HDMI"' \
    '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v '"$RTL"'/smooth.v \
    -DCLK16H=29.7369 -DCLKP50H=9.9133 -DEXPECT_LOCK=1 -DSTD=0 \
    && vvp tb_138k.out' 2>&1 | tail -40
$IV sh -c 'iverilog -g2012 -o tb_60k.out tb_frame_lock.v prim_stubs.v '"$HDMI"' \
    '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v '"$RTL"'/smooth.v \
    -DCLK16H=29.7289 -DCLKP50H=9.9096 -DEXPECT_LOCK=1 -DSTD=0 \
    && vvp tb_60k.out' 2>&1 | tail -15
$IV sh -c 'iverilog -g2012 -o tb_slow.out tb_frame_lock.v prim_stubs.v '"$HDMI"' \
    '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v '"$RTL"'/smooth.v \
    -DCLK16H=29.8507 -DCLKP50H=9.9502 -DEXPECT_LOCK=0 -DSTD=0 \
    && vvp tb_slow.out' 2>&1 | tail -15
