#!/usr/bin/env python3
"""Independent check of the LCD grid geometry in a gba_fx.log frame with only
the grid on (no colour, mask or scanlines): every picture pixel the grid
darkens must be the last output column of a source pixel or the last output
row of a source line, and every last column/row pixel that is not black must
be darkened. Needs no trust in the flags the testbench logs: the picture
origin and size are read from the log itself (with the integer geometry the
picture is 960x640, 4 columns per pixel and 4 rows per line), so a darkened
pixel must satisfy (x - x0) % 4 == 3 or (y - y0) % 4 == 3.

Run with python3 -I:  check_grid.py gba_fx.log GRIDCFG
"""
import sys


def unpack(v):
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


def main(path, cfg):
    pic = {}
    for line in open(path):
        t = line.split()
        if int(t[0], 16) != cfg:
            continue
        x, y = int(t[1]), int(t[2])
        if not int(t[3]):
            if unpack(int(t[9], 16)) != unpack(int(t[8], 16)):
                print("MISMATCH x=%d y=%d: border/overlay pixel changed" % (x, y))
                return 1
            continue
        pic[(x, y)] = (unpack(int(t[8], 16)), unpack(int(t[9], 16)))
    if not pic:
        print("grid check: no picture pixels")
        return 1
    x0, x1 = min(x for x, _ in pic), max(x for x, _ in pic)
    y0, y1 = min(y for _, y in pic), max(y for _, y in pic)
    bad = dark = col_hit = row_hit = 0
    for (x, y), (rgb, got) in pic.items():
        last_col = (x - x0) % 4 == 3
        last_row = (y - y0) % 4 == 3
        if got != rgb:
            dark += 1
            col_hit += last_col
            row_hit += last_row
            if not (last_col or last_row):
                bad += 1
                if bad <= 10:
                    print("MISMATCH x=%d y=%d: darkened but not a last column/row" % (x, y))
        elif rgb != (0, 0, 0) and (last_col or last_row):
            bad += 1
            if bad <= 10:
                print("MISMATCH x=%d y=%d: last column/row not darkened" % (x, y))
    print("grid check: picture x=%d..%d, %d logged rows, %d picture pixels, %d darkened (%d last-column, %d last-row), %d mismatches"
          % (x0, x1, len({y for _, y in pic}), len(pic), dark, col_hit, row_hit, bad))
    if x1 - x0 + 1 != 960:      # the logged rows cover every output column: 4 columns per pixel
        print("grid check: picture is not 960 wide")
        bad += 1
    if dark == 0 or col_hit == 0 or row_hit == 0:
        print("grid check: no coverage (no darkened / column / row pixels)")
        bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], int(sys.argv[2], 16)))
