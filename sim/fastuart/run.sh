#!/bin/sh
# Fast-UART sims (iverilog) for iosys_bl616 FAST_UART. From this directory:
#   ./run.sh              compile and run the fast-UART testbench
# Follows sim/saveram: the tangcore-iv:1 docker image (arm64 Icarus) when
# present, else a host iverilog. Gowin tolerates the "input reg" port
# declaration in iosys; iverilog does not, so a sim-only copy softens it.
set -e
cd "$(dirname "$0")"
RTL=../../src
# Runner: simrun when present (persistent ccache + full-core env), else plain docker.
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo "docker run --rm")};
sed -e 's/input reg  \[7:0\] kbd_data/input [7:0] kbd_data/' \
    -e 's/^\( *\)kbd_data <= rx_data;/\1;                       \/\/ sim: kbd path idle/' \
    $RTL/iosys/iosys_bl616.v > iosys_sim.v

run() {                                        # compile + run one testbench
    if docker image inspect tangcore-iv:1 >/dev/null 2>&1; then
        $DOCKER_RUN --user "$(id -u):$(id -g)" -v "$PWD:/w" -v "$PWD/$RTL:/src:ro" -w /w \
            --entrypoint sh tangcore-iv:1 \
            -c "iverilog -g2012 -DSIM -o $1 $2 && vvp $1"
    else
        iverilog -g2012 -DSIM -o $1 $2 && vvp $1
    fi
}

SIM=/src
docker image inspect tangcore-iv:1 >/dev/null 2>&1 || SIM=$RTL

run tb_iosys_fastuart.out \
  "tb_iosys_fastuart.v iosys_sim.v $SIM/iosys/uart_fixed.v $SIM/iosys/uart_fast.v $SIM/common/dual_clk_fifo.v"
