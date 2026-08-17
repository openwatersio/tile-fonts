#!/usr/bin/env python3
"""Check a built fontstack before it is published.

    scripts/verify.py [build/fonts]

The load-bearing check is coverage of the codepoints a chart actually sets. The MapLibre demo
fontstack that seascape used to point at ships only U+2082-2084 of the subscript block, so a
sounding's decimetre digit rendered as tofu for seven of ten digits — which is why the chart
draws that digit as a scaled `format` section instead of a subscript character. A stack that
silently lacks a glyph fails exactly this way: no error, just a missing number on a chart. So
missing coverage is an error here, not a warning.

Glyph PBFs are a small self-describing protobuf, so this parses them directly rather than
taking a dependency to read three fields.
"""
import json
import os
import sys

# The chart sets these; a hole in any of them is a number a mariner cannot read.
REQUIRED = {
    "digits": range(0x30, 0x3A),
    "subscript digits": range(0x2080, 0x208A),          # decimetres, fathom feet
    # Superscript digits are split across two blocks and are not contiguous: 1/2/3 predate the
    # block and live in Latin-1, U+2071 is a letter, and U+2072-2073 are unassigned.
    "superscript digits": [0x00B9, 0x00B2, 0x00B3, 0x2070] + list(range(0x2074, 0x207A)),
    "basic latin": range(0x20, 0x7F),
    "latin-1 supplement": range(0xA0, 0x100),           # accented place names
    "punctuation": [0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026],
    "degree and prime": [0x00B0, 0x2032, 0x2033],       # positions in the chart UI
}


def _varint(d, i):
    r = s = 0
    while True:
        b = d[i]; i += 1
        r |= (b & 0x7F) << s; s += 7
        if not b & 0x80:
            return r, i


def _fields(d):
    i = 0
    while i < len(d):
        key, i = _varint(d, i)
        f, wire = key >> 3, key & 7
        if wire == 2:
            n, i = _varint(d, i); yield f, d[i:i + n]; i += n
        elif wire == 0:
            v, i = _varint(d, i); yield f, v
        elif wire == 5:
            yield f, d[i:i + 4]; i += 4
        elif wire == 1:
            yield f, d[i:i + 8]; i += 8
        else:
            raise ValueError(f"wire type {wire}")


def glyph_ids(path):
    """Codepoints present in one range PBF. glyphs{1} -> fontstack{3} -> glyph{1} = id."""
    out = set()
    with open(path, "rb") as fh:
        data = fh.read()
    for f, stack in _fields(data):
        if f != 1:
            continue
        for f2, glyph in _fields(stack):
            if f2 != 3:
                continue
            for f3, gid in _fields(glyph):
                if f3 == 1:
                    out.add(gid)
    return out


def verify(stack_dir):
    name = os.path.basename(stack_dir)
    ranges = sorted(f for f in os.listdir(stack_dir) if f.endswith(".pbf"))
    if not ranges:
        return [f"{name}: no .pbf ranges"]

    present = set()
    for r in ranges:
        present |= glyph_ids(os.path.join(stack_dir, r))

    problems = []
    for label, block in REQUIRED.items():
        gap = sorted(c for c in block if c not in present)
        if gap:
            shown = ", ".join(f"U+{c:04X}" for c in gap[:8])
            more = f" (+{len(gap) - 8} more)" if len(gap) > 8 else ""
            problems.append(f"{name}: missing {len(gap)} of {label}: {shown}{more}")

    print(f"{name}: {len(ranges)} ranges, {len(present)} glyphs"
          f"{'' if problems else ' — all required blocks covered'}")
    return problems


if __name__ == "__main__":
    root = sys.argv[1] if len(sys.argv) > 1 else "build/fonts"
    if not os.path.isdir(root):
        sys.exit(f"no such directory: {root} (run scripts/build.sh first)")
    stacks = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)))
    if not stacks:
        sys.exit(f"{root} holds no fontstacks")

    failures = []
    for s in stacks:
        failures += verify(os.path.join(root, s))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        sys.exit(f"\n{len(failures)} coverage failure(s) — not publishable")
    print(f"\n{len(stacks)} stack(s) ok")
