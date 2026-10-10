#!/bin/sh
# video_fx sims (iverilog). From this directory:  ./run.sh
#   tb_iosys_video_config  iosys command 0x13
#   tb_video_fx     video_fx against the golden model (model.py)
#   tb_gba_regress  gba2hdmi against the scaler before video_fx: identical with no filter on
#   tb_gba_fx       the filters inside gba2hdmi, checked against the model (model.py check)
#                   and the grid geometry (check_grid.py)
# prep.sh (python3, git) makes the vectors and the baseline; with a simulator image that has
# neither, run prep.sh on the host first and `python3 -I model.py check gba_fx.log` and
# `python3 -I check_grid.py gba_fx.log 00028000` after.
set -e
cd "$(dirname "$0")"
RTL=../../src
HDMI=../scanlines/hdmi_stub.v
STUBS=../scanlines/gba_stubs.v
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    sh prep.sh
fi
test -f vec_case.hex -a -f build/gba2hdmi_base.sv

# iosys command 0x13 (a sim copy with the "input reg" port Gowin tolerates softened, like sim/saveram)
sed -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
    $RTL/iosys/iosys_bl616.v > build/iosys_sim.v
iverilog -g2012 -DSIM -o tb_iosys_video_config.out tb_iosys_video_config.v build/iosys_sim.v $RTL/iosys/uart_fixed.v
vvp tb_iosys_video_config.out

iverilog -g2012 -o tb_video_fx.out tb_video_fx.v $RTL/video_fx.v $RTL/scanlines.v
vvp tb_video_fx.out

iverilog -g2012 -o tb_gba_regress.out tb_gba_regress.v $HDMI $STUBS $RTL/gba2hdmi.sv $RTL/scanlines.v \
    $RTL/video_fx.v build/gba2hdmi_base.sv build/scanlines_base.v
vvp tb_gba_regress.out

iverilog -g2012 -o tb_gba_fx.out tb_gba_fx.v $HDMI $STUBS $RTL/gba2hdmi.sv $RTL/scanlines.v $RTL/video_fx.v
vvp tb_gba_fx.out
if command -v python3 >/dev/null 2>&1; then
    python3 -I model.py check gba_fx.log
    python3 -I check_grid.py gba_fx.log 00028000
else
    echo "NOTE: python3 not found, run: python3 -I model.py check gba_fx.log && python3 -I check_grid.py gba_fx.log 00028000"
fi
