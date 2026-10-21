#!/bin/sh
# Frame-lock sims (iverilog in tangcore-iv:1). From this directory:
#   ./run.sh [standard|hz120|both]
#   tb_frame_lock   the real gba2hdmi (138K BRAM path) with a faithful
#                   hdmi.sv stand-in (hdmi_frame_stub.v: identical cx/cy and
#                   frame_width semantics; iverilog cannot parse the real
#                   packet_assembler.sv) at the native htotal (1657 at 720p,
#                   861 at 480p120), against a line-cited model of the GBA frame
#                   (1008+224 mclk/line, 228 lines), gated by an exact copy of
#                   the gbatang_top halt block. Startup, steady lock, menu pause,
#                   core reset. The hz120 variant reads every game frame twice
#                   (lit, then inserted), so its hframe counts are doubled.
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
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
# See sim/scanlines/run.sh: the variant header is materialised and -I'd.
# Do not run two variants concurrently in one checkout.
set_variant() {
    cp -f "$RTL/variant/$1/variant.vh" "$RTL/common/variant.vh"
}
VINCL="$RTL/common"
IV="$DOCKER_RUN --name ${SIM_PREFIX:-sim$$}_r6hz120vgba_framelock --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/framelock tangcore-iv:1"
HDMI="hdmi_frame_stub.v"
run_iv() {
    LOG=$1; LINES=$2; shift 2
    # Keep the engine status: piping into tail hides compile/assertion errors.
    if $IV "$@" >"$LOG" 2>&1; then
        tail -n "$LINES" "$LOG"
    else
        cat "$LOG"
        return 1
    fi
}
run_clocks() {
    set_variant $1
    OUT=$2
    run_iv "${OUT}_138k.log" 40 sh -c 'iverilog -g2012 -o '"$OUT"'_138k.out tb_frame_lock.v -I '"$VINCL"' prim_stubs.v '"$HDMI"' \
        '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v \
        -DCLK16H=29.7369 -DCLKP50H=9.9133 -DEXPECT_LOCK=1 -DSTD=0 \
        && vvp '"$OUT"'_138k.out'
    run_iv "${OUT}_60k.log" 15 sh -c 'iverilog -g2012 -o '"$OUT"'_60k.out tb_frame_lock.v -I '"$VINCL"' prim_stubs.v '"$HDMI"' \
        '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v \
        -DCLK16H=29.7289 -DCLKP50H=9.9096 -DEXPECT_LOCK=1 -DSTD=0 \
        && vvp '"$OUT"'_60k.out'
    run_iv "${OUT}_slow.log" 15 sh -c 'iverilog -g2012 -o '"$OUT"'_slow.out tb_frame_lock.v -I '"$VINCL"' prim_stubs.v '"$HDMI"' \
        '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v \
        -DCLK16H=29.8507 -DCLKP50H=9.9502 -DEXPECT_LOCK=0 -DSTD=0 \
        && vvp '"$OUT"'_slow.out'
}
case "${1:-both}" in
    standard|both)
        run_clocks standard tb_std
        ;;
esac
case "${1:-both}" in
    hz120|both)
        run_clocks hz120 tb_hz120
        ;;
esac
