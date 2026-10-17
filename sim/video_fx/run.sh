#!/bin/sh
# video_fx sims (iverilog in tangcore-iv:1). From this directory:
#   ./run.sh [standard|hz120|both]
#   tb_iosys_video_config  iosys command 0x13 (shared logic: runs once)
#   tb_video_fx     video_fx against the golden model (model.py; shared: runs once)
#   tb_gba_regress  gba2hdmi against the scaler before video_fx: identical with no filter on
#                   (standard only: the history baseline is the 720p scaler)
#   tb_gba_fx       the filters inside gba2hdmi, checked against the model (model.py check)
#                   and the grid geometry (check_grid.py) (both variants; the hz120
#                   run uses the 480p120 geometry, grid pitch 3)
#   tb_smooth_regress  gba2hdmi without smoothing against the scaler it was removed
#                   from (build/gba2hdmi_smoff.sv): identical with smoothing off (standard only)
# prep.sh (host python3, git) makes the vectors and the baseline; with a simulator image that has
# neither, run prep.sh on the host first and `python3 -I model.py check gba_fx.log` and
# `python3 -I check_grid.py gba_fx.log 00028000` after.
#
# NOTE: the hz120 run overwrites gba_fx.log, so run standard first when both.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
STUBS=../scanlines/gba_stubs.v
VSTD=../../src/variant/standard
VHZ=../../src/variant/hz120
IV="docker run --rm --name r6hz120vgba_videofx --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/video_fx tangcore-iv:1"
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    sh prep.sh
fi
test -f vec_case.hex -a -f build/gba2hdmi_base.sv -a -f build/gba2hdmi_smoff.sv -a -f build/smooth_base.v

# iosys command 0x13 (a sim copy with the "input reg" port Gowin tolerates softened, like sim/saveram)
sed -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
    $RTL/iosys/iosys_bl616.v > build/iosys_sim.v

run_shared() {
    $IV sh -c 'iverilog -g2012 -DSIM -o tb_iosys_video_config.out tb_iosys_video_config.v build/iosys_sim.v '"$RTL"'/iosys/uart_fixed.v && vvp tb_iosys_video_config.out'
    $IV sh -c 'iverilog -g2012 -o tb_video_fx.out tb_video_fx.v '"$RTL"'/video_fx.v '"$RTL"'/scanlines.v && vvp tb_video_fx.out'
}
run_fx() {
    VDIR=$1
    $IV sh -c 'iverilog -g2012 -o tb_gba_fx.out -I '"$VDIR"' tb_gba_fx.v '"$HDMI"' '"$STUBS"' '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v && vvp tb_gba_fx.out'
}
case "${1:-both}" in
    standard|both)
        run_shared
        $IV sh -c 'iverilog -g2012 -o tb_gba_regress.out -I '"$VSTD"' tb_gba_regress.v '"$HDMI"' '"$STUBS"' '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v \
            '"$RTL"'/video_fx.v build/gba2hdmi_base.sv build/scanlines_base.v && vvp tb_gba_regress.out'
        run_fx "$VSTD"
        $IV sh -c 'iverilog -g2012 -o tb_smooth_regress.out -I '"$VSTD"' tb_smooth_regress.v '"$HDMI"' '"$STUBS"' '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v \
            '"$RTL"'/video_fx.v build/gba2hdmi_smoff.sv build/smooth_base.v && vvp tb_smooth_regress.out'
        if command -v python3 >/dev/null 2>&1; then
            python3 -I model.py check gba_fx.log
            python3 -I check_grid.py gba_fx.log 00028000
        else
            echo "NOTE: python3 not found, run: python3 -I model.py check gba_fx.log && python3 -I check_grid.py gba_fx.log 00028000"
        fi
        ;;
esac
case "${1:-both}" in
    hz120|both)
        run_fx "$VHZ"
        if command -v python3 >/dev/null 2>&1; then
            python3 -I model.py check gba_fx.log
            # pitch 3, width 719: the picture's first column carries pic=0
            # (the active window's one-clock lag, as in the 720p build whose
            # logged picture is likewise shifted), so the logged picture is
            # x=1..719; the trailing column falls outside the logged range.
            python3 -I check_grid.py gba_fx.log 00028000 3 719
        else
            echo "NOTE: python3 not found, run: python3 -I model.py check gba_fx.log && python3 -I check_grid.py gba_fx.log 00028000 3 719"
        fi
        ;;
esac
