#!/bin/sh
# Scanline sims (iverilog in tangcore-iv:1). From this directory:
#   ./run.sh [standard|hz120|both]
#   tb_scanlines    the row generator and the darkening (src/scanlines.v, shared
#                   by both variants: the 120 Hz build uses the same file)
#   tb_gba_scaler   gba2hdmi whole frames at 720p (the standard variant), with stubs
#                   for the HDMI part, the PLL and the block RAM
#   tb_gba_scaler_hz120  gba2hdmi whole frames at 480p120 (the hz120 variant):
#                   geometry, darkening, BFI modes, the overlay exemption, one
#                   retention phase swap, and the report frame dumps
#   tb_textdisp     the 480p OSD glyph fix (the hz120 variant only: the
#                   standard build has no font_xoff for the bench to drive)
set -e
cd "$(dirname "$0")"
RTL=../../src
# The build variant: run.sh materialises src/common/variant.vh (git-ignored,
# as build.tcl does) before compiling, and compiles with -I on src/common, so
# the RTL and the testbenches see the same variant.vh Gowin sees. Do not run
# two variants concurrently in one checkout.
set_variant() {
    cp -f "$RTL/variant/$1/variant.vh" "$RTL/common/variant.vh"
}
VINCL="$RTL/common"
IV="docker run --rm --name r6hz120vgba_scan --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/scanlines tangcore-iv:1"
case "${1:-both}" in
    standard|both)
        set_variant standard
        $IV sh -c 'iverilog -g2012 -I '"$VINCL"' -o tb_scanlines.out tb_scanlines.v '"$RTL"'/scanlines.v && vvp tb_scanlines.out'
        $IV sh -c 'iverilog -g2012 -I '"$VINCL"' -o tb_gba_scaler.out tb_gba_scaler.v hdmi_stub.v gba_stubs.v '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v && vvp tb_gba_scaler.out'
        ;;
esac
case "${1:-both}" in
    hz120|both)
        set_variant hz120
        $IV sh -c 'iverilog -g2012 -I '"$VINCL"' -o tb_gba_scaler_hz120.out tb_gba_scaler_hz120.v hdmi_stub.v gba_stubs.v '"$RTL"'/gba2hdmi.sv '"$RTL"'/scanlines.v '"$RTL"'/video_fx.v && vvp tb_gba_scaler_hz120.out'
        $IV sh -c 'iverilog -g2012 -I '"$VINCL"' -o tb_textdisp.out tb_textdisp.v '"$RTL"'/iosys/textdisp.v && vvp tb_textdisp.out'
        ;;
esac
