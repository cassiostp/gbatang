#!/bin/sh
# Battery-save sims (iverilog) for the gbatang save channel. From this dir:
#   ./run.sh              compile and run all four testbenches
# This machine has no host iverilog, so run.sh uses the tangcore-iv:1 docker
# image (arm64 Icarus) when present, and falls back to a host iverilog.
# Gowin tolerates the "input reg" port declaration in iosys; iverilog does
# not, so run.sh compiles a sim-only copy with it softened.
set -e
RTL=../../src
sed -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
    $RTL/iosys/iosys_bl616.v > iosys_sim.v

run() {                                        # compile + run one testbench
    if docker image inspect tangcore-iv:1 >/dev/null 2>&1; then
        docker run --rm -v "$PWD:/w" -v "$PWD/$RTL:/src:ro" -w /w \
            --entrypoint sh tangcore-iv:1 \
            -c "iverilog -g2012 -o $1 $2 && vvp $1 $EXTRA"
    else
        iverilog -g2012 -o $1 $2 && vvp $1 $EXTRA
    fi
}

SIM=/src
docker image inspect tangcore-iv:1 >/dev/null 2>&1 || SIM=$RTL

run_tb() {                                      # one testbench by name
    case "$1" in
      tb_saveram)
        run tb_saveram.out \
          "tb_saveram.v iosys_sim.v $SIM/iosys/uart_fixed.v $SIM/iosys/textdisp.v $SIM/iosys/gowin_dpb_menu.v dpb_sim.v" ;;
      tb_sdram_save)
        run tb_sdram_save.out \
          "tb_sdram_save.v $SIM/memory/sdram_gba.v sdram_model.v" ;;
      tb_saveram_sdram)
        run tb_saveram_sdram.out \
          "tb_saveram_sdram.v iosys_sim.v $SIM/iosys/uart_fixed.v $SIM/iosys/textdisp.v $SIM/iosys/gowin_dpb_menu.v dpb_sim.v $SIM/memory/sdram_gba.v sdram_model.v" ;;
      tb_saveram_eeprom)
        run tb_saveram_eeprom.out \
          "tb_saveram_eeprom.v iosys_sim.v $SIM/iosys/uart_fixed.v $SIM/iosys/textdisp.v $SIM/iosys/gowin_dpb_menu.v dpb_sim.v $SIM/memory/gba_eeprom.sv $SIM/memory/mem_eeprom_sim.v" ;;
      tb_probe_t)
        run tb_probe_t.out \
          "tb_probe_t.v iosys_sim.v $SIM/iosys/uart_fixed.v $SIM/iosys/textdisp.v $SIM/iosys/gowin_dpb_menu.v dpb_sim.v $SIM/memory/gba_eeprom.sv $SIM/memory/mem_eeprom_sim.v" ;;
    esac
}

case "${1:-all}" in
  all) run_tb tb_sdram_save; run_tb tb_saveram; run_tb tb_saveram_sdram; run_tb tb_saveram_eeprom ;;
  *)   run_tb "$1" ;;
esac
