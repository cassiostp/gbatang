#!/bin/sh
# Audio-hold sim (iverilog in tangcore-iv:1). From this directory:
#   ./run.sh [standard|hz120|both]
#   tb_audio_hold   the real gba_sound with a GBA-bus driver: a ch2 square
#                   wave and a DMA-A stream under the frame-lock ce pattern
#                   (502 mclk held per 281398-mclk frame at 138K clocks;
#                   573 per 281469-mclk game frame for the 480p120 lock).
#                   Checks PSG pitch is the GBATEK pitch and follows game
#                   speed (0.05%), the mixer output holds live audio across
#                   holds, DMA consumption tracks ticks exactly, no sample
#                   step exceeds free-run, and the ch3/ch4/length rates
#                   match GBATEK (all PSG timing derives from clk/4).
#
# Tool note: iverilog cannot elaborate the MiSTer-style struct regmap
# (assignment patterns crash it), so run.sh first runs mkshadow.py (host
# python3) to build shadow/ -- bit-identical copies with the regmap struct
# expanded to a 102-bit vector (same bits, member selects become ranges).
# All stepping/mixing logic is byte-identical; Gowin synthesis (CI) compiles
# the untouched originals.
set -e
cd "$(dirname "$0")"
RTL=../../src
SHADOW=$PWD/shadow
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
python3 mkshadow.py "$RTL" "$SHADOW"
# See sim/scanlines/run.sh: the variant header is materialised, not -I'd.
# Do not run two variants concurrently in one checkout.
IV="$DOCKER_RUN --name ${SIM_PREFIX:-sim$$}_r6hz120vgba_audio --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/audio tangcore-iv:1"
run_variant() {
    cp -f "$RTL/variant/$1/variant.vh" "$RTL/common/variant.vh"
    OUT=$2
    LOG=$3
    $IV sh -c 'iverilog -g2012 -o '"$OUT"' -I shadow -I ../../src/common tb_audio_hold.v \
        shadow/gba_sound.v shadow/gba_sound_ch1.v \
        shadow/gba_sound_ch3.v shadow/gba_sound_ch4.v \
        shadow/gba_sound_dma.v shadow/eprocreg_gba.sv \
        && vvp '"$OUT" > "$LOG" 2>&1; rc=$?
    tail -8 "$LOG"
    grep -q "tb_audio_hold: PASS" "$LOG"
}
case "${1:-both}" in
    standard|both)
        run_variant standard tb_audio_hold_std.out audio_std.log
        ;;
esac
case "${1:-both}" in
    hz120|both)
        run_variant hz120 tb_audio_hold_hz120.out audio_hz120.log
        ;;
esac
