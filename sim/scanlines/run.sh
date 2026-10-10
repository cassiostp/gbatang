#!/bin/sh
# Scanline sims (iverilog). From this directory:  ./run.sh
#   tb_scanlines    the row generator and the darkening (src/scanlines.v)
#   tb_gba_scaler   gba2hdmi (the BRAM framebuffer build) whole frames, with stubs
#                   for the HDMI part, the PLL and the block RAM
set -e
RTL=../../src
iverilog -g2012 -o tb_scanlines.out tb_scanlines.v $RTL/scanlines.v
vvp tb_scanlines.out
iverilog -g2012 -o tb_gba_scaler.out tb_gba_scaler.v hdmi_stub.v gba_stubs.v $RTL/gba2hdmi.sv $RTL/scanlines.v $RTL/video_fx.v
vvp tb_gba_scaler.out
