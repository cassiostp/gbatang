#!/usr/bin/env python3
# mkshadow.py: iverilog work-around for the MiSTer-style struct regmap.
#
# The gba sound sources describe their MMIO map with a packed struct type
# (regmap_type in pproc_bus_gba.sv) and struct assignment patterns
# ('{...}). Icarus Verilog 12 (tangcore-iv:1) cannot elaborate struct
# assignment patterns ("sorry: ... using old method", aborts), so the real
# sources cannot be compiled by it as-is. Gowin synthesis (CI) compiles the
# untouched originals; this script produces bit-identical shadow copies for
# the iverilog benches only:
#
#   parameter/localparam regmap_type NAME = '{f0..f5};
#       -> [101:0] NAME = {f0, 6'd f1, 6'd f2, 28'd f3, 32'd f4, 2'd f5};
#   parameter regmap_type NAME;  ->  parameter [101:0] NAME = 102'd0;
#   NAME.upper/lower/Adr/def/size/acccesstype  ->  NAME[hi:lo] bit ranges.
#
# A packed struct assigns/initialises in declaration order, so the struct
# pattern and the concatenation carry exactly the same bits; member selects
# become the matching bit ranges (Adr 101:74, upper 73:68, lower 67:62,
# size 61:34, def 33:2, acccesstype 1:0). All other text -- every line of
# stepping/mixing logic -- is copied byte-identical. Usage:
#   python3 mkshadow.py <srcroot> <shadowdir>
import re
import sys
import pathlib

WIDTHS = (28, 6, 6, 28, 32, 2)
RANGE = {'Adr': (101, 74), 'upper': (73, 68), 'lower': (67, 62),
         'size': (61, 34), 'def': (33, 2), 'acccesstype': (1, 0)}
ACCMAP = {'readwrite': 0, 'readonly': 1, 'writeonly': 2, 'writeDone': 3}
SIZED = re.compile(r"[0-9]+'[hdbHDB][0-9a-fA-F_xXzZ?]+")
NUM = re.compile(r"[0-9]+")
DECL = re.compile(
    r"(?P<kw>localparam|parameter)(?P<sp>\s+)regmap_type(?P<sp2>\s+)"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    r"(?P<init>\s*=\s*('\{[^}]*\}|[^;]+?))?(?P<semi>\s*;)")


def size_field(field, width):
    field = field.strip()
    if field in ACCMAP:
        assert width == 2, field
        return "2'd%d" % ACCMAP[field]
    if NUM.fullmatch(field):
        return "%d'd%s" % (width, field)
    assert SIZED.fullmatch(field), field
    return field


def collect_names(text):
    return set(match.group('name') for match in DECL.finditer(text))


def transform(text, names):

    def decl_sub(match):
        init = match.group('init')
        head = "%s%s[101:0]%s%s" % (
            match.group('kw'), match.group('sp'),
            match.group('sp2'), match.group('name'))
        if init is None:
            # valueless declaration (ch1 channel params): default is dead --
            # every instantiation overrides all of them -- so any value goes.
            return head + " = 102'd0;"
        if "'{" not in init:
            # non-struct initializer (dma REG_FIFO = FIFO_A): keep the value,
            # convert only the type.
            return head + init + ";"
        fields = init.split('{', 1)[1].rsplit('}', 1)[0].split(',')
        assert len(fields) == 6, match.group(0)
        sized = ", ".join(size_field(f, w)
                          for f, w in zip(fields, WIDTHS))
        return "%s%s[101:0]%s%s = {%s};" % (
            match.group('kw'), match.group('sp'),
            match.group('sp2'), match.group('name'), sized)

    text = DECL.sub(decl_sub, text)
    for name in sorted(names, key=len, reverse=True):
        for member, (hi, lo) in RANGE.items():
            text = re.sub(r"\b%s\s*\.\s*%s\b" % (re.escape(name), member),
                          "%s[%d:%d]" % (name, hi, lo), text)
    return text


INST = re.compile(
    r"eProcReg_gba\s*#\([^;]*?\)\s*\w+\s*\((?P<ports>[^;]*?)\)\s*;")


def pad_eprocreg(text):
    # iverilog rejects omitted trailing positional ports; pad eProcReg_gba
    # instantiations (12 ports: clk + 8 bus + Din + Dout + written) with
    # empty slots. `GB_BUS_PORTS_LIST expands to 8 ports but shows no comma.
    def pad(match):
        ports = match.group('ports')
        assert ports.count('`GB_BUS_PORTS_LIST') == 1, match.group(0)
        real = ports.count(',') + 1 + 7
        missing = 12 - real
        assert 0 <= missing <= 2, match.group(0)
        body = match.group(0).rstrip()
        assert body.endswith(');'), match.group(0)
        return body[:-2] + ", " * missing + ");"
    return INST.sub(pad, text)


def main():
    srcroot = pathlib.Path(sys.argv[1])
    shadow = pathlib.Path(sys.argv[2])
    shadow.mkdir(parents=True, exist_ok=True)
    files = ['sound/gba_sound.v', 'sound/gba_sound_ch1.v',
             'sound/gba_sound_ch3.v', 'sound/gba_sound_ch4.v',
             'sound/gba_sound_dma.v', 'common/eprocreg_gba.sv',
             'common/preg_gba_sound.sv', 'common/pproc_bus_gba.sv']
    names = set()
    for rel in files:
        names |= collect_names((srcroot / rel).read_text())
    for rel in files:
        src = (srcroot / rel).read_text()
        out = transform(src, names)
        out = pad_eprocreg(out)
        assert "'{" not in out, rel
        (shadow / pathlib.Path(rel).name).write_text(out)
    print("shadow: %d files" % len(files))


main()
