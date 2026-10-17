#!/bin/sh
# Scanline sims (iverilog in tangcore-iv:1). From this directory:  ./run.sh
#   tb_scanlines    the row generator and the darkening (src/scanlines.v)
#   tb_gba_scaler   gba2hdmi (the BRAM framebuffer build) whole frames, with stubs
#                   for the HDMI part, the PLL and the block RAM
set -e
cd "$(dirname "$0")"
RTL=../../src
IV="docker run --rm --name r6hz120gba_scan --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/scanlines tangcore-iv:1"
$IV sh -c 'iverilog -g2012 -o tb_scanlines.out tb_scanlines.v '"$RTL"'/scanlines.v && vvp tb_scanlines.out'
$IV sh -c 'iverilog -g2012 -o tb_gba_scaler.out tb_gba_scaler.v hdmi_stub.v gba_stubs.v '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v '"$RTL"'/smooth.v && vvp tb_gba_scaler.out'
$IV sh -c 'iverilog -g2012 -o tb_textdisp.out tb_textdisp.v '"$RTL"'/iosys/textdisp.v && vvp tb_textdisp.out'
