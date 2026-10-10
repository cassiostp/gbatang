#!/bin/sh
# Battery-save sims (iverilog) for the gbatang save channel. From this dir:
#   ./run.sh              compile and run all five testbenches
# This machine has no host iverilog, so run.sh uses the tangcore-iv:1 docker
# image (arm64 Icarus) when present, and falls back to a host iverilog.
# Gowin tolerates the "input reg" port declaration in iosys; iverilog does
# not, so run.sh compiles a sim-only copy with it softened.
set -e
RTL=../../src
sed -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
    $RTL/iosys/iosys_bl616.v > iosys_sim.v

# sdram_gba's flash FSM declares `reg [15:0] f_addr = {cpu_addr[15:2], 2'b0};`
# inside its clocked block. The synthesizer re-evaluates that on every pass;
# Icarus initializes it once at time 0 (and warns), which freezes the command
# address decode. tb_gba_saves drives real unlock sequences, so it compiles a
# copy with the initializer split into a declaration and an assignment.
sed -e 's/^\( *\)reg \[15:0\] f_addr = {cpu_addr\[15:2\], 2.b0};/\1reg [15:0] f_addr;/' \
    -e 's/^\( *\)case (cpu_be)$/\1f_addr = {cpu_addr[15:2], 2'"'"'b0};\n\1case (cpu_be)/' \
    $RTL/memory/sdram_gba.v > sdram_gba_sim.v
grep -q 'f_addr = {cpu_addr\[15:2\], 2.b0};$' sdram_gba_sim.v && \
    ! grep -q 'reg \[15:0\] f_addr = ' sdram_gba_sim.v || \
    { echo "run.sh: sdram_gba.v's f_addr line changed, fix the sed" >&2; exit 1; }

# gba_memory's $readmemh wants the BIOS image in the working directory
cp $RTL/memory/gba_bios_cultofgba.hex .

# tb_gba_saves copies gbatang_top.sv's battery-save glue; fail if the top moved on.
for l in "wire        eep_save = config_backup_type == 3'd4;" \
         "assign sdram_sv_addr = sv_addr[16:0];" \
         "assign sv_q = eep_save ? eeprom_rdata : sdram_sv_q;" \
         "assign sv_ack = eep_save ? sv_req : sdram_sv_ack;" \
         "assign eeprom_wr    = (sv_req ^ sv_req_d) & sv_we & eep_save;" \
         "assign eeprom_addr  = sv_addr[12:0];" \
         "assign eeprom_wdata = sv_din;" \
         "assign sv_core_we = (bw_s[1] & ~bw_s[2]) | (eeprom_written & eep_save);" \
         ".sv_req(sv_req & ~eep_save), .sv_ack(sdram_sv_ack), .sv_dout(sdram_sv_q)"; do
    grep -qF -- "$l" $RTL/gbatang_top.sv || \
        { echo "run.sh: gbatang_top.sv no longer has: $l (update tb_gba_saves.v's glue copy)" >&2; exit 1; }
done

run() {                                        # compile + run one testbench
    if docker image inspect tangcore-iv:1 >/dev/null 2>&1; then
        docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/w" -v "$PWD/$RTL:/src:ro" -w /w \
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
      tb_gba_saves)
        run tb_gba_saves.out \
          "-DVERILATOR -I$SIM/common tb_gba_saves.v iosys_sim.v $SIM/iosys/uart_fixed.v $SIM/iosys/textdisp.v $SIM/iosys/gowin_dpb_menu.v dpb_sim.v sdram_gba_sim.v sdram_model.v $SIM/memory/gba_memory.sv $SIM/memory/gba_eeprom.sv $SIM/memory/mem_eeprom_sim.v $SIM/common/sim_spram_be.sv" ;;
    esac
}

case "${1:-all}" in
  all) run_tb tb_sdram_save; run_tb tb_saveram; run_tb tb_saveram_sdram; run_tb tb_saveram_eeprom; run_tb tb_gba_saves ;;
  *)   run_tb "$1" ;;
esac
