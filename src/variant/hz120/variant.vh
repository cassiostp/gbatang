// TangCore build variant: the 480p120 (2x the native rate) build with
// runtime black-frame insertion. Files that differ between the variants do
// `include "variant.vh" and guard the 120 Hz logic with `ifdef HZ120.
`define HZ120
