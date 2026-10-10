# video_fx sims (`sim/video_fx`)

Testbenches for `src/video_fx.v` (colour controls, CRT mask, LCD grid) and its
integration in `gba2hdmi`. iverilog; `./run.sh` runs everything.

| test | what it checks |
| --- | --- |
| `tb_iosys_video_config.v` | iosys command `0x13` through the real UART receiver: sets `video_config` big-endian, leaves `core_config` alone (and the other way round), ignores other commands, reset clears it |
| `tb_video_fx.v` | the module alone, against `model.py`: every brightness / contrast / saturation / gamma, every mask type and strength with the LCD grid off and at its four strengths, and 300 random settings with random pictures, borders, scanline darkening and grid flags |
| `tb_gba_regress.v` | `gba2hdmi` against the scaler before `video_fx` (built from git history by `prep.sh`): with a `video_config` that enables nothing (`0`, the firmware's all-off `0x00012000`, and `0x00032000` with strengths set but all effects off) the rgb stream into the hdmi module is identical clock for clock, two whole frames per scanline mode, with the menu overlay up or not |
| `tb_gba_fx.v` + `model.py check` | the filters running inside `gba2hdmi`: the pixels going in and coming out of `video_fx` are logged with their output position and compared with the model, so the mask lands on the right columns and rows, the scanline darkening follows the colour stage, and the border and the overlay stay untouched. The testbench itself also checks that every source pixel spans exactly 4 output columns with the integer geometry, that the grid column flag fires exactly on the last one, and that with the grid on and the scanlines off no scanline darkening is applied |
| `check_grid.py` | the grid-only frame of `gba_fx.log`, independently of the logged flags: every darkened pixel is the last output column of a source pixel or the last output row of a source line of the 960x640 picture, and every such non-black pixel is darkened |

`model.py` is the golden model, written from the spec (the `video_config` table in the header of
`video_fx.v`), not from the Verilog; `model.py selfcheck` also compares it with
real-number arithmetic and a few hand-computed values. `tools/video_fx_gamma.py`
generates the gamma tables inside `video_fx.v` (`--check` tells whether the file
is up to date); the model computes the tables itself.

`prep.sh` needs python3 and git (vectors from the model, the baseline scaler
from `$BASE`, the last commit without `video_fx`). The simulator image used on
arm64 (`tangcore-iv:1`) has neither: run `sh prep.sh` on the host, then
`docker run --rm --user $(id -u):$(id -g) -v $PWD/../..:/w -w /w/sim/video_fx tangcore-iv:1 sh run.sh`
and `python3 -I model.py check gba_fx.log` and `python3 -I check_grid.py gba_fx.log 00028000` on the host.
