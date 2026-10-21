Read the project-wide rules first: https://github.com/cassiostp/tangcore/blob/main/AGENTS.md

# gbatang — GBA core

GBA for the Tang Console 138K/60K. Started as a port of `MiSTer-devel/GBA_MiSTer`, now about half-rewritten (traditional FPGA-replica design at 16 MHz, `risclite/ARM9-compatible-soft-CPU-core` CPU, rewritten memory system).

## Layout

- Top: `src/gbatang_top.sv` (`module gbatang_top`); CPU/GPU/memory under `src/` and `src/memory/`.
- Video: 138K uses BRAM `src/gba2hdmi.sv` + `src/fb.v`; 60K uses DDR3 `src/gba2hdmi_ddr3.sv` + `src/ddr3_framebuffer.v` + `src/ddr3_memory_interface/`. HDMI core `src/hdmi/hdmi.sv`; helpers `src/scanlines.v`, `src/video_fx.v`, `src/smooth.v`.
- Memory: `src/memory/sdram_gba.v` (+ `rv_sdram_adapter.v`, `gba_memory.sv`, `mem_eeprom/iwram.v`); 60K only adds the DDR3 interface.
- iosys: `src/iosys/iosys_bl616.v` is the build's copy (plus `uart_fixed.v`, `uart_fast.v`, `textdisp.v`, `gowin_dpb_menu.v`). `iosys_picorv32.v` exists but is not in `build.tcl`.
- PLLs: `src/pll/` (138K: `pll_27/33/74/12.v`), `src/plla/` (60K: plus `pll_ddr3/hdmi`, `pll_mDRP_intf.v`).
- Board wrappers `src/boards/`: `console60k.v`/`console138k.v` (USB1+USB2, `DDR3_FRAMEBUFFER` only on 60K), `mega60k.v`/`mega138k[v].v`/`mega138kpro.v`, `verilator_sim.v`.

## Building

```tcl
gw_sh build.tcl <device>   # console60k mega60k console138k mega138k mega138kpro
```

`build.tcl` selects the CST/SDC/PLL/video stack per family; there is no controller argument.

Build variants (`TANGCORE_VARIANT`, unset or `standard` = the 720p60 build; `hz120` = the
480p120 build with runtime BFI, console138k only; anything else is an error):

```tcl
gw_sh build.tcl console138k                       # standard 720p60 bitstream
TANGCORE_VARIANT=hz120 gw_sh build.tcl console138k  # 480p120 bitstream (load as gbatang_120hz.bin)
```

The RTL sees the variant through `variant.vh`: `build.tcl` copies
`src/variant/<variant>/variant.vh` to `src/common/variant.vh` (on the include
path, like the other shared headers; `HZ120` is defined for hz120 and nowhere
else; the copy is git-ignored). `src/pll/pll_74_hz120.v` (54 MHz) replaces
`src/pll/pll_74.v` (74.25 MHz) in the hz120 build. CI:

```sh
gh workflow run cores.yml -R cassiostp/tangcore --ref ci/core-builds -f core=gbatang -f ref=<branch> -f board=console138k
gh workflow run cores.yml -R cassiostp/tangcore --ref ci/core-builds -f core=gbatang -f ref=<branch> -f board=console138k -f variant=hz120
```

Fails on any setup/hold violation.

## Clocks and constraints

- 138K `src/gbatang.sdc`: `clk16` ~16.8125 MHz, `clk67 = clk16 x4`, `clk50 = clk16 x3`; HDMI `hclk5/hclk` lines are commented out.
- 60K `src/gbatang_ddr.sdc`: same `clk16/clk67/clk50` at ~16.81875 MHz, plus DDR3 `clk4x` ~297 MHz and `clk1x` ~74.25 MHz with `set_clock_groups -asynchronous` between `clk50/clk4x/clk1x`.
- Producers: `pll_27` (50 -> 27 MHz), `pll_33` (27 -> `clk50/clk16/clk67`), `pll_12` (12 MHz USB); 138K `pll_74` in `gba2hdmi.sv`, 60K `pll_ddr3`/`pll_hdmi` in the DDR3 framebuffer.

## Native-rate lock

HDMI uses a 1657-pixel native line (`.NATIVE_FRAME_WIDTH(1657)` in `src/gba2hdmi.sv` and `src/ddr3_framebuffer.v`); `std_timing = 1` selects the standard 1650 line. `video_std_timing` is tied `1'b0` in `src/gbatang_top.sv`, so the build is native-only.
The top halts the GBA (`frame_halt`, `core_hold`) on the first vblank trigger and releases at HDMI `RELEASE_ROW = 515`; `core_hold` gates CPU/GPU/DMA/timers/sound.

## Firmware link

- Core ID 3 (`CORE_ID(3)` in `src/gbatang_top.sv`).
- Save channel `SAVE_IF=1, SAVE_AW=18, SAVE_SYNC=0` (128 KB window): `sv_addr[17:9]` block, EEPROM/SRAM/Flash512K/Flash1M selected by `config_backup_type`, `sv_rtc` overflow bit, `sv_core_we` dirty; plus `FAST_UART=1` for the negotiated 8 Mbaud ROM stream (`0x15/0x16`, CRC-verified).
- `core_config` bits used: `[17]` menu pause, `[6]` freeze, `[5:0]` DDR3 prefetch delay, `[16]` scanlines, `[19:18]` darkness, `[20]` thick, `[21]` out; `video_config` drives `video_fx.v`/`smooth.v`.
- `iosys_bl616.v` is one of six divergent copies (`cassiostp/tangcore#30`): a fix to one usually belongs in the others.

## Simulations (`sim/*/README.md` says how to run where it exists)

Sim scripts use `simrun` when it is on PATH (else `docker run --rm`);
set `SIM_PREFIX` to namespace container names when sharing the machine.
`simrun` is an optional local helper (persistent ccache + full-core env),
not part of the repositories.

- `audio`: real `gba_sound` under a `core_hold` enable pattern (pitch, mixer-hold, DMA ticks, no-click). The same timing bench runs under Verilator by default (one model thread); `SIM_ENGINE=iverilog` selects the original Icarus path.
- `cosim`: Verilator `iosys_bl616`+`sdram_gba` + chip for firmware co-sim (`firmware host/README.md` RTL backend).
- `fastuart`: `FAST_UART 0x15/0x16` at wire level, 8 Mbaud + CRC + watchdog.
- `framelock`: real `gba2hdmi` at the native htotal vs the GPU-timing model + top halt copy, 138K/60K must lock.
- `gpio_rtc`: S-3511A bit-bang + solar + save sector; `0x080000C4/C6/C8` decode.
- `saveram`: end-to-end `0x06/0x11/0x0B/0x12/0x0A` per backup type plus SDRAM/EEPROM/memstream benches.
- `scanlines`: row generator/darkening plus whole-frame `gba2hdmi` vs model.
- `tmds`: 2-stage `tmds_channel` vs the git-history direct version over ~2.5M clocks.
- `video_fx`: `0x13`, `video_fx` vs `model.py`, git-history regress with filters off, FX and smoothing checks.

The video benches (`scanlines`, `framelock`, `audio`, `video_fx`) run for both variants:
`sh sim/<bench>/run.sh [standard|hz120|both]` (default `both`; the `tb_*` module-level and
shared-logic benches run once). Each `run.sh` materialises `src/common/variant.vh` for the
variant it is running (same file `build.tcl` generates) and compiles with `-I`
on `src/common`; do not run two variants concurrently in one checkout. At 120 Hz the GBA picture is a full-bleed 3x (240x160 to
720x480), so `core_config[21]` (Full/Integer) changes nothing; the `video_config[21:20]` BFI
modes are covered by `tb_gba_scaler_hz120`.

## Traps

- The 60K build swaps the whole video stack (no `fb.v`/`gba2hdmi.sv`/`scanlines.v`/`video_fx.v`/`smooth.v`/`pll_74`, adds the DDR3 stack); only `console*` boards define USB.
- HDMI `hclk5/hclk` constraints are commented out in both SDCs; multicycle `4/3` `clk67<->clk16` and `3/2` `clk16<->clk50` plus the GPU/VRAM `set_false_path` carry the timing.
- `video_std_timing` is hard `0`; the "needs the PLL fix" comment at `gbatang_top.sv` is still in the tree.

Run `sh sim/regress.sh quick both` before handing work back; `quick` is the minimum check. Use `full both` for all benches, `--only bench1,bench2` to select, and `--list` for tiers, variants, images and typical times. At most two benches run together (users of the shared variant header run serially); logs and tables are in `sim/.regress/`. `TANGCORE_ROMS` defaults to `~/tangcore-test-bundle/test roms`; missing ROMs and unsupported variants SKIP. Keep ROM-derived output local.
