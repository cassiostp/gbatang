#!/bin/sh
# Audio-hold sim (iverilog). From this directory:  ./run.sh
#   tb_audio_hold   the real gba_sound with a GBA-bus driver: a ch2 square
#                   wave and a DMA-A stream under the frame-lock ce pattern
#                   (502 mclk held per 281398-mclk frame at the 138K clocks).
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
python3 mkshadow.py "$RTL" "$SHADOW"
IV="docker run --rm --name audio_tb --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/audio tangcore-iv:1"
$IV sh -c 'iverilog -g2012 -o tb_audio_hold.out -I shadow tb_audio_hold.v \
    shadow/gba_sound.v shadow/gba_sound_ch1.v \
    shadow/gba_sound_ch3.v shadow/gba_sound_ch4.v \
    shadow/gba_sound_dma.v shadow/eprocreg_gba.sv \
    && vvp tb_audio_hold.out' > audio.log 2>&1; rc=$?
tail -8 audio.log
grep -q "tb_audio_hold: PASS" audio.log
