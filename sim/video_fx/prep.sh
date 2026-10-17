#!/bin/sh
# Host-side preparation for run.sh: needs python3 and git.
#   vec_*.hex           test vectors from the golden model (model.py gen)
#   build/*_base.*      the scaler before video_fx, from git history ($BASE), with the module
#                       names suffixed _base so that both can be in one simulation
set -e
cd "$(dirname "$0")"
BASE=${BASE:-344a973}       # the last commit without video_fx
SMOFFBASE=${SMOFFBASE:-8ee44b0}   # the branch base: the scaler with smoothing, driven off below
python3 -I model.py selfcheck
python3 -I model.py gen
mkdir -p build
git show $BASE:src/gba2hdmi.sv | sed \
    -e 's/^module gba2hdmi (/module gba2hdmi_base (/' \
    -e 's/^sl_rows sl (/sl_rows_base sl (/' \
    -e 's/^sl_dim dim (/sl_dim_base dim (/' > build/gba2hdmi_base.sv
git show $BASE:src/scanlines.v | sed \
    -e 's/^module sl_rows (/module sl_rows_base (/' \
    -e 's/^module sl_dim (/module sl_dim_base (/' > build/scanlines_base.v
grep -q '^module gba2hdmi_base (' build/gba2hdmi_base.sv
grep -q '^sl_rows_base sl (' build/gba2hdmi_base.sv
grep -q '^sl_dim_base dim (' build/gba2hdmi_base.sv
grep -q '^module sl_rows_base (' build/scanlines_base.v
grep -q '^module sl_dim_base (' build/scanlines_base.v
git show $SMOFFBASE:src/gba2hdmi.sv | sed \
    -e 's/^module gba2hdmi (/module gba2hdmi_smoff (/' \
    -e 's/^smooth sm (/smooth_base sm (/' \
    -e 's/^smooth_axis a/smooth_axis_base a/' > build/gba2hdmi_smoff.sv
git show $SMOFFBASE:src/smooth.v | sed \
    -e 's/^module smooth (/module smooth_base (/' \
    -e 's/^module smooth_axis (/module smooth_axis_base (/' > build/smooth_base.v
grep -q '^module gba2hdmi_smoff (' build/gba2hdmi_smoff.sv
grep -q '^smooth_base sm (' build/gba2hdmi_smoff.sv
grep -q '^smooth_axis_base a' build/gba2hdmi_smoff.sv
grep -q '^module smooth_base (' build/smooth_base.v
grep -q '^module smooth_axis_base (' build/smooth_base.v
echo "prep: vectors and baseline from $BASE ready"
