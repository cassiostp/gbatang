#!/bin/sh
# The same timing bench under Verilator; private headers avoid src/common races.
set -eu
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
THREADS=${VERILATOR_THREADS:-1}
case $THREADS in ''|*[!0-9]*|0) echo "VERILATOR_THREADS must be positive" >&2; exit 2;; esac
case ${1:-both} in
    standard|hz120) VARIANTS=$1;;
    both) VARIANTS='standard hz120';;
    *) echo "usage: $0 [standard|hz120|both]" >&2; exit 2;;
esac
DOCKER_RUN=${DOCKER_RUN:-$(command -v simrun >/dev/null 2>&1 && echo simrun || echo 'docker run --rm')}
case $DOCKER_RUN in *simrun*) CCACHE_OFF=;; *) CCACHE_OFF='-e CCACHE_DISABLE=1';; esac
for V in $VARIANTS; do
    B=build/verilator-$V-threads$THREADS
    mkdir -p "$B/shadow"
    python3 mkshadow.py ../../src "$B/shadow"
    cp "../../src/variant/$V/variant.vh" "$B/shadow/variant.vh"
    $DOCKER_RUN --name "${SIM_PREFIX:-sim$$}_audio_vlt_${V}_t$THREADS" \
        --user "$(id -u):$(id -g)" $CCACHE_OFF \
        -v "$ROOT:/w" -w /w/sim/audio -e "VERILATOR_THREADS=$THREADS" \
        -e "AUDIO_BUILD=$B" --entrypoint sh verilator/verilator:latest -ec '
        verilator --binary --timing --threads "$VERILATOR_THREADS" -j "${JOBS:-$(nproc)}" \
            --top-module tb_audio_hold -Wno-fatal \
            -I"$AUDIO_BUILD/shadow" -I../../src/common --Mdir "$AUDIO_BUILD/obj" \
            tb_audio_hold.v "$AUDIO_BUILD/shadow/gba_sound.v" "$AUDIO_BUILD/shadow/gba_sound_ch1.v" \
            "$AUDIO_BUILD/shadow/gba_sound_ch3.v" "$AUDIO_BUILD/shadow/gba_sound_ch4.v" \
            "$AUDIO_BUILD/shadow/gba_sound_dma.v" "$AUDIO_BUILD/shadow/eprocreg_gba.sv" \
            > "$AUDIO_BUILD/compile.log" 2>&1 || { tail -40 "$AUDIO_BUILD/compile.log"; exit 1; }
        "$AUDIO_BUILD/obj/Vtb_audio_hold" > "$AUDIO_BUILD/run.log" 2>&1
        cat "$AUDIO_BUILD/run.log"
        grep -q "tb_audio_hold: PASS" "$AUDIO_BUILD/run.log"'
done
