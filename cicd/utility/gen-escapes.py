#!/usr/bin/env python3

##	Purpose: The characters canonical output writes as a \u escape, written
##		into the four bindings and the grammar from the one list below. The
##		copies were kept in step by hand, which is how a table drifts. Each
##		copy sits between "gen-escapes.py: begin" and "gen-escapes.py: end".
##	Syntax:
##		gen-escapes.py           check every copy matches the list
##		gen-escapes.py --write   rewrite the copies
##	Exit: 0 = clean, 1 = a copy differs, 2 = usage or a marker is missing.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


from __future__ import annotations

import sys
from pathlib import Path

UNICODE = "18.0"

## Default_Ignorable_Code_Point, as DerivedCoreProperties.txt lists it. The
## format fixes this list, so a later Unicode does not change what a format 3
## file looks like.
IGNORABLE = [
	(0x00AD, 0x00AD),
	(0x034F, 0x034F),
	(0x061C, 0x061C),
	(0x115F, 0x1160),
	(0x17B4, 0x17B5),
	(0x180B, 0x180D),
	(0x180E, 0x180E),
	(0x180F, 0x180F),
	(0x200B, 0x200F),
	(0x202A, 0x202E),
	(0x2060, 0x2064),
	(0x2065, 0x2065),
	(0x2066, 0x206F),
	(0x3164, 0x3164),
	(0xFE00, 0xFE0F),
	(0xFEFF, 0xFEFF),
	(0xFFA0, 0xFFA0),
	(0xFFF0, 0xFFF8),
	(0x1BCA0, 0x1BCA3),
	(0x1D173, 0x1D17A),
	(0xE0000, 0xE0FFF),
]

## Controls with no short escape, the line and paragraph separators, and the
## interlinear annotation marks, which hide the text between them.
ALSO = [(0x00, 0x08), (0x0B, 0x1F), (0x7F, 0x9F), (0x2028, 0x2029), (0xFFF9, 0xFFFB)]

## The joiners stay as written anywhere, since emoji and several scripts need them.
JOINERS = [(0x200C, 0x200D)]

## Variation selectors, which stay as written directly after a visible character.
SELECTORS = [(0x180B, 0x180D), (0x180F, 0x180F), (0xFE00, 0xFE0F), (0xE0100, 0xE01EF)]

## What a bare value can never hold, besides the escaped characters: a blank,
## a line break and the characters that end or open a piece.
RESERVED = {0x09, 0x0A, 0x0D, 0x20, 0x22, 0x23, 0x27, 0x2C, 0x3A, 0x5B, 0x5D}


def fMerge(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
	out: list[tuple[int, int]] = []
	for lo, hi in sorted(ranges):
		if out and lo <= out[-1][1] + 1:
			out[-1] = (out[-1][0], max(out[-1][1], hi))
		else:
			out.append((lo, hi))
	return out


def fSubtract(ranges: list[tuple[int, int]], drop: list[tuple[int, int]]) -> list[tuple[int, int]]:
	out: list[tuple[int, int]] = []
	for lo, hi in fMerge(ranges):
		for dlo, dhi in fMerge(drop):
			if dhi < lo or dlo > hi:
				continue
			if dlo > lo:
				out.append((lo, dlo - 1))
			lo = dhi + 1
			if lo > hi:
				break
		if lo <= hi:
			out.append((lo, hi))
	return out


INVISIBLE = fSubtract(IGNORABLE + ALSO, JOINERS)

HEAD = f"Generated from Unicode {UNICODE} by cicd/utility/gen-escapes.py. Edit the script, not this block."


def fHex(c: int) -> str:
	return f"0x{c:04X}"


def fRust() -> list[str]:
	lines = [f"// {HEAD}"]
	for name, ranges in (("INVISIBLE", INVISIBLE), ("SELECTORS", SELECTORS)):
		lines += ["#[rustfmt::skip]", f"const {name}: [(u32, u32); {len(ranges)}] = ["]
		lines += [f"\t({fHex(lo)}, {fHex(hi)})," for lo, hi in ranges]
		lines += ["];"]
	return lines


def fGo() -> list[str]:
	lines = [f"// {HEAD}"]
	for name, ranges in (("invisibleRanges", INVISIBLE), ("selectorRanges", SELECTORS)):
		lines += [f"var {name} = [][2]rune{{"]
		lines += [f"\t{{{fHex(lo)}, {fHex(hi)}}}," for lo, hi in ranges]
		lines += ["}"]
	## gofmt wants a blank line between the closing brace and the end marker.
	return lines + [""]


def fPython() -> list[str]:
	lines = [f"# {HEAD}"]
	for name, ranges in (("_INVISIBLE_RANGES", INVISIBLE), ("_SELECTOR_RANGES", SELECTORS)):
		lines += [f"{name} = ("]
		lines += [f"\t({fHex(lo)}, {fHex(hi)})," for lo, hi in ranges]
		lines += [")"]
	return lines


def fC() -> list[str]:
	lines = [f"/* {HEAD} */"]
	for name, ranges in (("invisible_ranges", INVISIBLE), ("selector_ranges", SELECTORS)):
		lines += [f"static const uint32_t {name}[][2] = {{"]
		lines += [f"\t{{{fHex(lo)}, {fHex(hi)}}}," for lo, hi in ranges]
		lines += ["};"]
	return lines


def fAbnfAlts(rule: str, ranges: list[tuple[int, int]]) -> list[str]:
	alts = [f"%x{lo:X}" if lo == hi else f"%x{lo:X}-{hi:X}" for lo, hi in ranges]
	lines: list[str] = []
	line = f"{rule:<15} = {alts[0]}"
	for alt in alts[1:]:
		if len(line) + len(alt) + 3 > 72:
			lines.append(line)
			line = " " * 16 + "/ " + alt
		else:
			line += " / " + alt
	return lines + [line]


def fAbnf() -> list[str]:
	## The bare class leaves out the joiners and selectors too, since
	## fmt-bareword places them itself.
	bare = fSubtract([(0x21, 0x10FFFF)], [(c, c) for c in RESERVED] + INVISIBLE + JOINERS + SELECTORS)
	return [f"; {HEAD}"] + fAbnfAlts("fmt-bare-char", bare) + fAbnfAlts("variation-sel", SELECTORS)


TARGETS = [
	("source/rust/src/lib.rs", "// ", fRust),
	("source/go/shcl.go", "// ", fGo),
	("source/python/shcl.py", "# ", fPython),
	("source/c/shcl.h", "// ", fC),
	("project/grammar.abnf", "; ", fAbnf),
]


def main() -> int:
	args = sys.argv[1:]
	if args not in ([], ["--write"]):
		print("usage: gen-escapes.py [--write]", file=sys.stderr)
		return 2
	root = Path(__file__).resolve().parent.parent.parent
	rc = 0
	for rel, lead, fBlock in TARGETS:
		path = root / rel
		text = path.read_text(encoding="utf-8")
		lines = text.split("\n")
		begin, end = f"{lead}gen-escapes.py: begin", f"{lead}gen-escapes.py: end"
		if lines.count(begin) != 1 or lines.count(end) != 1 or lines.index(begin) > lines.index(end):
			print(f"gen-escapes: {rel}: needs one '{begin}' line and one '{end}' line after it", file=sys.stderr)
			return 2
		first, last = lines.index(begin) + 1, lines.index(end)
		want = fBlock()
		if lines[first:last] == want:
			continue
		if args:
			path.write_text("\n".join(lines[:first] + want + lines[last:]), encoding="utf-8")
			print(f"gen-escapes: rewrote {rel}")
		else:
			print(f"gen-escapes: {rel}: the escape table differs from gen-escapes.py (run it with --write)", file=sys.stderr)
			rc = 1
	return rc


if __name__ == "__main__":
	sys.exit(main())


##	History:
##		2026-09-28  Created, when the escape set grew to Unicode's
##		            Default_Ignorable_Code_Point list.
