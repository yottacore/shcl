#!/usr/bin/env python3

##	Purpose: The characters canonical output writes as an escape, the escape
##		names and the whitespace list, written into the four bindings, the
##		grammar and the spec from the one list below. The copies were kept in
##		step by hand, which is how a table drifts. Each copy sits between
##		"gen-escapes.py: begin" and "gen-escapes.py: end".
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

## Besides whitespace, what a bare piece can't hold as text: the characters
## that end, open or quote one, and the escape mark. ":" "[" and "]" are text
## in some pieces and not others, so the grammar adds them back rule by rule.
RESERVED = {0x22, 0x23, 0x27, 0x2C, 0x3A, 0x5B, 0x5D, 0x60, 0x25C9}


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

## Unicode's White_Space property, which a bare value or selector body can't
## hold. Stable across Unicode versions, and fixed here like the list above.
WHITE_SPACE = [
	(0x0009, 0x000D),
	(0x0020, 0x0020),
	(0x0085, 0x0085),
	(0x00A0, 0x00A0),
	(0x1680, 0x1680),
	(0x2000, 0x200A),
	(0x2028, 0x2029),
	(0x202F, 0x202F),
	(0x205F, 0x205F),
	(0x3000, 0x3000),
]

## The escape character, U+25C9 FISHEYE, which opens and closes an escape.
ESCAPE_MARK = 0x25C9

## The closed list of escape names (value-syntax.md, Escape list). The first
## name for each text is the one the writer uses; the rest are read as aliases.
ESCAPE_NAMES = [
	("NUL", "\x00"), ("NULL", "\x00"),
	("BEL", "\x07"), ("BELL", "\x07"),
	("BACKSPACE", "\x08"), ("BS", "\x08"),
	("TAB", "\t"), ("HT", "\t"), ("HORIZONTAL_TAB", "\t"),
	("NEWLINE", "\n"), ("LF", "\n"), ("LINEFEED", "\n"), ("LINE_FEED", "\n"), ("NEW_LINE", "\n"),
	("VT", "\x0b"), ("VERTICAL_TAB", "\x0b"), ("VERTICALTAB", "\x0b"),
	("FF", "\x0c"), ("FORM_FEED", "\x0c"), ("FORMFEED", "\x0c"),
	("CR", "\r"), ("CARRIAGERETURN", "\r"), ("CARRIAGE_RETURN", "\r"),
	("CRLF", "\r\n"), ("CARRIAGERETURN_LINEFEED", "\r\n"), ("CARRIAGE_RETURN_LINE_FEED", "\r\n"),
	("ESC", "\x1b"), ("ESCAPE", "\x1b"),
	("DEL", "\x7f"), ("DELETE", "\x7f"),
	("SPACE", " "),
	("SINGLE_QUOTE", "'"), ("SQUOTE", "'"), ("S_QUOTE", "'"), ("SINGLEQUOTE", "'"),
	("DOUBLE_QUOTE", '"'), ("DQUOTE", '"'), ("D_QUOTE", '"'), ("DOUBLEQUOTE", '"'),
	("BACK_TICK", "`"), ("BACKTICK", "`"), ("TICK", "`"),
	("ESCAPE_CHAR", chr(ESCAPE_MARK)), ("FISHEYE", chr(ESCAPE_MARK)),
]

## What goes before the hex digits of a code point escape. The writer uses the
## first. No two can match the same name, so the order is only for the writer.
CODE_PREFIXES = ["U+", "UNICODE+", "UNICODE-", "UNICODE_", "UNICODE", "U-", "U_", "U"]

HEAD = f"Generated from Unicode {UNICODE} by cicd/utility/gen-escapes.py. Edit the script, not this block."


def fHex(c: int) -> str:
	return f"0x{c:04X}"


def fRustText(text: str) -> str:
	return '"' + "".join(f"\\u{{{ord(c):X}}}" for c in text) + '"'


def fRust() -> list[str]:
	lines = [f"// {HEAD}"]
	for name, ranges in (("INVISIBLE", INVISIBLE), ("SELECTORS", SELECTORS), ("WHITE_SPACE", WHITE_SPACE)):
		lines += ["#[rustfmt::skip]", f"const {name}: [(u32, u32); {len(ranges)}] = ["]
		lines += [f"\t({fHex(lo)}, {fHex(hi)})," for lo, hi in ranges]
		lines += ["];"]
	lines += [f"const ESCAPE_MARK: char = '\\u{{{ESCAPE_MARK:X}}}';"]
	lines += ["#[rustfmt::skip]", f"const ESCAPE_NAMES: [(&str, &str); {len(ESCAPE_NAMES)}] = ["]
	lines += [f'\t("{name}", {fRustText(text)}),' for name, text in ESCAPE_NAMES]
	lines += ["];"]
	lines += ["#[rustfmt::skip]", f"const CODE_PREFIXES: [&str; {len(CODE_PREFIXES)}] = ["]
	lines += [f'\t"{p}",' for p in CODE_PREFIXES]
	lines += ["];"]
	return lines


def fGoText(text: str) -> str:
	return '"' + "".join(f"\\u{ord(c):04X}" for c in text) + '"'


def fGo() -> list[str]:
	lines = [f"// {HEAD}"]
	for name, ranges in (("invisibleRanges", INVISIBLE), ("selectorRanges", SELECTORS), ("whiteSpaceRanges", WHITE_SPACE)):
		lines += [f"var {name} = [][2]rune{{"]
		lines += [f"\t{{{fHex(lo)}, {fHex(hi)}}}," for lo, hi in ranges]
		lines += ["}"]
	lines += ["", f"const escapeMark = '\\u{ESCAPE_MARK:04X}'", ""]
	lines += [f"var escapeNames = [{len(ESCAPE_NAMES)}]struct{{ name, text string }}{{"]
	lines += [f'\t{{"{name}", {fGoText(text)}}},' for name, text in ESCAPE_NAMES]
	lines += ["}"]
	lines += [f"var codePrefixes = [{len(CODE_PREFIXES)}]string{{"]
	lines += [f'\t"{p}",' for p in CODE_PREFIXES]
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


def fAbnfWords(rule: str, words: list[str]) -> list[str]:
	alts = [f'"{w}"' for w in words]
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
	bare = fSubtract([(0x21, 0x10FFFF)], [(c, c) for c in RESERVED] + WHITE_SPACE + INVISIBLE + JOINERS + SELECTORS)
	text = fSubtract([(0x00, 0x10FFFF)], [(c, c) for c in RESERVED] + WHITE_SPACE)
	## A bare selector body ends at its ")", and holds no "(" either.
	sel = fSubtract(text, [(0x28, 0x29)])
	## ABNF strings ignore case, as escape names do.
	names = fAbnfWords("escape-name", [n for n, _ in ESCAPE_NAMES]) + ["                / code-point"]
	return ([f"; {HEAD}"] + fAbnfAlts("fmt-bare-char", bare) + fAbnfAlts("variation-sel", SELECTORS)
		+ fAbnfAlts("bare-text", text) + fAbnfAlts("sel-text", sel) + names
		+ fAbnfWords("code-prefix", CODE_PREFIXES))


def fSpec() -> list[str]:
	rows: list[list[str]] = []
	for name, text in ESCAPE_NAMES:
		if rows and rows[-1][3] == text:
			rows[-1][1] += (", " if rows[-1][1] else "") + f"`\u25c9{name}\u25c9`"
			continue
		rows.append([f"`\u25c9{name}\u25c9`", "", " ".join(f"U+{ord(c):04X}" for c in text), text])
	prefixes = ", ".join(f"`{p}`" for p in CODE_PREFIXES[1:])
	table = [["Escape", "Aliases", "Character"], [":---", ":---", ":---"]]
	table += [[r[0], r[1] or "none", r[2]] for r in rows]
	table += [["`\u25c9U+XXXX\u25c9`", f"{prefixes} in place of `U+`", "The character at that hex code point"]]
	widths = [max(len(r[i]) for r in table) for i in range(2)]
	out = [f"<!-- {HEAD} -->", ""]
	out += [f"| {r[0]:<{widths[0]}} | {r[1]:<{widths[1]}} | {r[2]}" for r in table]
	return out + [""]


TARGETS = [
	("source/rust/src/lib.rs", "// ", fRust),
	("source/go/shcl.go", "// ", fGo),
	("source/python/shcl.py", "# ", fPython),
	("source/c/shcl.h", "// ", fC),
	("project/grammar.abnf", "; ", fAbnf),
	("project/spec.md", "<!-- ", fSpec),
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
		tail = " -->" if lead == "<!-- " else ""
		begin, end = f"{lead}gen-escapes.py: begin{tail}", f"{lead}gen-escapes.py: end{tail}"
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
##		2026-10-05  Escape names, code point prefixes and White_Space, for
##		            the value syntax. Rust only so far.
##		2026-10-05  The grammar takes the escape names, the bare text class
##		            and White_Space too, and spec.md the escape table.
##		2026-10-06  A selector text class, the bare one without parens.
##		2026-10-06  Go takes the escape names, code point prefixes and
##		            White_Space.
