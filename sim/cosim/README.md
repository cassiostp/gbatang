# GBA co-simulation (`sim/cosim`)

A Verilator model of gbatang's real firmware-facing interface logic — the
`iosys_bl616` UART protocol engine (with OSD text) and the `sdram_gba`
controller (with the battery-save client) — for the TangCore firmware
co-simulation (see firmware `host/README.md`, "RTL backend"). No game, no
video, no audio: it exercises firmware<->core interactions (combos and pad
frames during play, battery-save dumps/restores, reset, MODE, core_config
bits) without hardware.

Ported from the NES template (`nestang` `sim/cosim/`); the "what differs and
why" list is at the bottom.

## Layout

- `cosim_top.sv` — the small top: real `iosys_bl616` (as
  `iosys_bl616_cosim`, generated, see below) + real `sdram_gba` wired
  exactly as `gbatang_top` wires the save channel, plus sim-only
  surroundings: behavioral SDRAM chip (`sdram_chip.sv`), GBA-like CPU
  traffic with a game backup-write hook (`poke_*`, `churn_en`), a ROM byte
  sink, the loader's backup-type latch, MODE silencing, and a `tx_pending`
  output so the bridge never jumps over a reply owed by the model. Clocks
  and reset come from C++ (`fclk` = 4x `clk`, coincident rising edges;
  `mclk` is `clk`: the board's ram clock is 4x the GBA clock and
  `sdram_gba` derives its frame resync from `mclk` itself; `hclk` tied to
  `clk`: the render pipeline is unobserved, OSD text is snapshotted straight
  out of the DPB array).
- `sdram_chip.sv` — behavioral 16-bit SDRAM: the exact command subset
  `sdram_gba` issues for chip 1 (ACT, single-word READ/WRITE with
  auto-precharge, DQM-masked writes, CL2 reads; refresh/mode-set/precharge
  ignored). `sdram_gba` encodes the chip select in the nCS command bit;
  chip 0 (cartridge ROM) is not modeled — nothing reads ROM contents back.
  Powers up all-`0xFF`, retains contents across reset (external chip).
  The save window lands at linear SDRAM byte 0x40000 (see `cosim_top.sv`).
- `gowin/` — behavioural stand-ins for Gowin primitives, shared by every
  testbench and cosim target in this core: currently only the DPB behind
  `gowin_dpb_menu` (OSD text buffer; zero-init, render side unmodelled).
- `core/`, `gba/`, `nes_core/`, `gowin/`, `wave.vcd`, `rtl.v` — a copy of the
  source set needed to elaborate (the same set the `sim/saveram` testbenches
  use, plus the NES text-render chain and the VCD include `textdisp.sv`
  wants), so `rtl.v` builds the tree without `add_all_src`; every file is
  byte-identical to `src/` except the generated copies described below.
- `Makefile` — `make model` (docker Verilator) builds
  `build/obj/Vcosim_top__ALL.a` + `build/runtime/` (Verilator headers) for
  the firmware to link with `-DGBATANG_COSIM_DIR`; `make lint` elaborates
  under iverilog (docker); `make clean`. `build/` is git-ignored.

## Generated sources (build-time, never committed)

`build/gen/` holds mechanical copies of real sources, each verified by the
build (grep checks + printed diff):

- `iosys_bl616_cosim.v` — from `src/iosys/iosys_bl616.v`, with exactly
  three changes: module renamed, the `CORE_ID` parameter deleted and added
  as the `cosim_core_id` input (programming the model answers as the
  programmed core; every reply byte stays DUT-generated), the `tx_data <=
  CORE_ID[7:0]` use pointed at it — plus the two `run.sh`-style softeners
  (`input reg` kbd port, idle kbd path) that non-Gowin tools need.
- `sdram_gba_sim.v` — from `src/memory/sdram_gba.v`: the flash FSM's
  `reg f_addr = expr` declaration-init made into declaration + assignment
  (the very sed `sim/saveram/run.sh` uses; no functional change).
- `uart_fixed_sim.v` — from `src/iosys/uart_fixed.v`: the dummy
  `ASSERTION_ERROR` instances replaced by empty begins. No functional
  change.
- The verilate line waives five style warnings (`-Wno-PINMISSING` etc.)
  that the core's own RTL carries; the log is then grepped for any waived
  warning naming `cosim_top`, `sdram_chip` or `gowin_dpb` (the waivers must
  never cover our files).

## What differs from the NES template (and why)

- Clocks: `fclk` = 4x `clk` (not 3x); there is no `clkref` — `sdram_gba`
  uses `mclk` (here: `clk`) as its resync reference, and iosys runs with
  `FREQ=21_492_000` so the UART hits 2 Mbaud in bridge ticks (the board
  runs iosys at 16.65 MHz; its timers count clocks, not seconds).
- Save map: `sdram_gba`'s save client byte-reads/writes the 128KB cart-RAM
  region (`sv_addr[16]` = flash bank, byte lane = `sv_addr[0]`); save byte
  `o` rides chip 1 halfword 0x20000 + o/2, i.e. linear byte 0x40000 + o.
  Game-side writes arrive through the cart window `0x204_0000 + o` and
  dirty the save via `backup_written` (only while backup type 3 is set),
  exactly like hardware.
- Backup type: `gba_memory` is not instantiated (no game runs), so
  `cosim_top` replicates its loader latch — region-3's first byte sets
  `config_backup_type`, entering `loading==1` clears it. The firmware's
  post-reset resend (`gba_resend_backup_type`) is observable that way.
- `sv_core_we` is the two-flop catch of `backup_written`, copied verbatim
  from `gbatang_top.sv` (the NES template drives it from the traffic
  generator directly).

## Tests

- The firmware `g-rtl-*.script` suite (`bash host/run-tests.sh --rtl-gba`
  in the firmware worktree): menu combo and reset combo during a dump with
  the game writing SRAM continuously, save round trip, core_config bits,
  MODE — all through the real serial link at the real baud. The reset test
  also proves the backup type survives the reset (post-reset game writes
  must dirty again, which only happens with type 3 re-sent).
- `../saveram/run.sh` (iverilog, docker) covers the same RTL pieces with
  direct testbenches (`tb_gba_saves`, `tb_gba_memstream` drive `sdram_gba`
  and `gba_memory` with the real save flow); the cosim reuses their drive
  shapes and command model.
