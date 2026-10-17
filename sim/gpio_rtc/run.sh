#!/bin/sh
# GPIO/RTC/solar testbenches: tb_gba_gpio_rtc (the S-3511A + solar + save
# sector model on its own) and tb_gpio_decode (gba_memory's GPIO window
# decode with the model wired as in gbatang_top). Needs iverilog; without a
# local one it falls back to the tangcore-iv Docker image, same as
# sim/saveram (COMMON.md naming).
set -eu
cd "$(dirname "$0")"
SRC=../../src
run() {
    if command -v iverilog >/dev/null 2>&1; then
        sh -c "$1"
    elif docker image inspect tangcore-iv:1 >/dev/null 2>&1; then
        docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/../..":/w \
            -w /w/sim/gpio_rtc tangcore-iv:1 sh -c "$1"
    else
        echo "need iverilog or docker (tangcore-iv:1)" >&2; exit 1
    fi
}
run "iverilog -g2005 -Wall -o tb_gpio.vvp $SRC/memory/gba_gpio_rtc.v tb_gba_gpio_rtc.v && vvp tb_gpio.vvp" 2>&1 | tee tb_gpio.log
grep -q "tb_gba_gpio_rtc: PASS" tb_gpio.log || { echo "tb_gba_gpio_rtc: FAIL"; exit 1; }
rm -f tb_gpio.vvp tb_gpio.log
# The decode bench needs the BIOS hex in the working directory (readmemh).
cp $SRC/memory/gba_bios_cultofgba.hex .
run "iverilog -g2012 -Wall -DVERILATOR -I$SRC/common -o tb_dec.vvp $SRC/memory/gba_memory.sv $SRC/memory/gba_gpio_rtc.v $SRC/memory/gba_eeprom.sv $SRC/memory/mem_eeprom_sim.v $SRC/common/sim_spram_be.sv tb_gpio_decode.v && vvp tb_dec.vvp" 2>&1 | tee tb_dec.log
grep -q "tb_gpio_decode: PASS" tb_dec.log || { echo "tb_gpio_decode: FAIL"; exit 1; }
rm -f tb_dec.vvp tb_dec.log gba_bios_cultofgba.hex
