#!/usr/bin/env python3

##	Purpose: Check that project/grammar.abnf is ABNF (RFC 5234, with RFC 7405's
##		%s and %i), that every rule it names is defined and none shadows a core
##		rule, and that a few lines the parser reads derive from the rule meant to
##		cover them. Two review rounds found the grammar unreadable as ABNF or
##		narrower than the parser, and it is the oracle harnesses get written
##		against, so it is checked like code.
##	Syntax: check-abnf.py [GRAMMAR]
##	Exit: 0 = clean, 1 = a check failed, 2 = usage or missing input.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

CORE = {
	"alpha": "%x41-5A / %x61-7A",
	"bit": '"0" / "1"',
	"char": "%x01-7F",
	"cr": "%x0D",
	"crlf": "CR LF",
	"ctl": "%x00-1F / %x7F",
	"digit": "%x30-39",
	"dquote": "%x22",
	"hexdig": 'DIGIT / "A" / "B" / "C" / "D" / "E" / "F"',
	"htab": "%x09",
	"lf": "%x0A",
	"lwsp": "*(WSP / CRLF WSP)",
	"octet": "%x00-FF",
	"sp": "%x20",
	"vchar": "%x21-7E",
	"wsp": "SP / HTAB",
}

## Lines the parser reads, and the rule that has to derive each whole. A False
## is a line the rule must not derive. The info-string rows are 20260918b item
## 51: labels the parser reads and SetRaw writes, which the rule once built
## from bare-plain could not produce. The file rows are 20260909 item 32.
SAMPLES: list[tuple[str, str, bool]] = [
	("info-string", "c", True),
	("info-string", " python", True),
	("info-string", "a:b", True),
	("info-string", "a,b", True),
	("info-string", '"q"', True),
	("info-string", "[x]", True),
	("info-string", 'sql:pg, "v" [x]', True),
	("info-string", "c#", False),
	("info-string", "a # b", False),
	("fence-line", "```c# note", True),
	("fence-line", "\t~~~~ sql:pg", True),
	("field-line", "srv(web).port: 80", True),
	## A selector is written in parens since 2026100610073400, and one in
	## brackets is E029. A bare body ends at the first ")" and holds no "(".
	("field-line", "srv[web].port: 80", False),
	("field-line", "srv (web) . port: 80", True),
	("field-line", 'srv("a)b").p: 1', True),
	("field-line", "srv(a(b)).p: 1", False),
	("field-line", "srv(a(b).p: 1", False),
	("field-line", "srv(St.Paul).p: 1", True),
	("field-line", "k: f(x)", True),
	("field-line", "db: ```sql # the label is sql", True),
	## 20260920 item 5: the bare-value class was the formatter's minimal shape,
	## so the grammar derived none of these. Since the value syntax change
	## (2026100207032800) a quote, a bracket, or a comma or colon before a
	## blank in a bare value is an error. Spaces are fine again since 20261006.
	("field-line", "q: needs no quotes", True),
	("field-line", 'c: say "hi" there', False),
	("field-line", "p: C:\\dir\\file", True),
	("field-line", "url: http://h/#frag", True),
	("field-line", "a: x[y]", False),
	("field-line", "t: 12:30", True),
	("field-line", "k: it's fine", False),
	("field-line", "k: a]b", False),
	("field-line", "k: one, two", False),
	("field-line", "o: rw,noatime", True),
	("field-line", "d: :0", True),
	("field-line", "h: a.com port: 80", False),
	("field-line", "x: a,", False),
	("field-line", "x: done:", False),
	("field-line", "t: a\tb", False),
	("field-line", "k: [a,b]", True),
	("field-line", "k: [a b]", False),
	("field-line", "k: [a:, b]", False),
	("field-line", "srv(a:b).p: 1", False),
	("field-line", 'srv("a:b").p: 1', True),
	("field-line", "\tk: trailing  ", True),
	("field-line", 'q: "needs quotes"', True),
	("field-line", "k: [one, two]", True),
	("field-line", "k: []", True),
	("field-line", "k: [ ]", True),
	("field-line", 'k: [a, "b c", `d`]', True),
	("field-line", "k: [a,, b]", False),
	("field-line", "k: [a, ]", False),
	("field-line", "k: [[a], b]", False),
	("field-line", "log: [INFO] started", False),
	("field-line", "k: [a", False),
	("field-line", "k: x\u2003y", False),
	("field-line", "k: x\u00a0", False),
	("field-line", "k: `#FF8800`", True),
	("field-line", "k: `a\"b`", True),
	("field-line", "k: `x`y", False),
	("field-line", '"404": x', True),
	("field-line", "404: x", False),
	("field-line", "-x: y", False),
	## A backslash is text everywhere, so every pair that was an escape or an
	## E023 reads as itself now. An info string never was escape text.
	("field-line", 'p: "C:\\work"', True),
	("field-line", 'p: "C:\\\\work"', True),
	("field-line", "p: 'C:\\work'", True),
	("info-string", '"C:\\x"', True),
	("field-line", 'p: "\\u00E9"', True),
	("field-line", 'p: "\\U0001F600"', True),
	("field-line", 'p: "\\u12"', True),
	("field-line", 'p: "\\uZZZZ"', True),
	## An escape is a name from the closed list between two marks, in any case.
	("field-line", 'p: "a\u25c9TAB\u25c9b"', True),
	("field-line", "p: My\u25c9SPACE\u25c9App", True),
	("field-line", "p: \u25c9tab\u25c9", True),
	("field-line", "p: \u25c9U+1F600\u25c9", True),
	("field-line", "p: \u25c9U_41\u25c9", True),
	("field-line", 'p: "say \u25c9HELLO\u25c9"', False),
	("field-line", "p: x\u25c9", False),
	("field-line", "p: \u25c9U+0000041\u25c9", False),
	("field-line", "p: `\u25c9`", True),
	("field-line", "p: x  # \u25c9", True),
	## A leading quote opens a quoted piece and a leading "[" opens an array,
	## so neither is a bare value.
	("bareword", '"q"', False),
	("bareword", "[80, 443]", False),
	("bareword", " lead", False),
	("bareword", "trail ", False),
	("bareword", "a,b", True),
	("bareword", "a, b", False),
	("bareword", "a:", False),
	("bareword", "a#b", False),
	## Three of the field lines above as values rather than whole lines, so the
	## tie below has both answers to check for this rule.
	("bareword", "a]b", False),
	("bareword", "C:\\dir\\file", True),
	("bareword", "it's fine", False),
	("bareword", "it's", False),
	("bareword", "12:30", True),
	("bareword", ":x", True),
	("bareword", "a b", True),
	("bareword", "My  App", True),
	("list-item-line", "* Bond James", False),
	("list-item-line", "- Bond James", True),
	("list-item-line", "- name: value", False),
	("list-item-line", "- rw,noatime", True),
	("list-item-line", '- "Bond, James"', True),
	("list-item-line", "- `x`", True),
	("list-item-line", "- -5", True),
	("list-item-line", "-\tx", True),
	("list-item-line", "- localhost:8080", True),
	("list-item-line", "- name:", False),
	("list-item-line", '- "name:"', True),
	("list-item-line", "- [a]", False),
	("list-item-line", "- a, b", False),
	("list-item-line", "-x", False),
	## 20260803 item 32: the parser takes a leading plus on an index, and "-"
	## is no sign, so (-1) is a value selector. The old "#" index is gone.
	("index-sel", "+1", True),
	("index-sel", "#+1", False),
	("index-sel", "-1", False),
	## The formatter's own shape, which nothing on the parse side reaches.
	("fmt-bareword", "plain", True),
	("fmt-bareword", "C:\\dir", False),
	("fmt-bareword", "a]b", False),
	("fmt-bareword", "it's", False),
	("fmt-bareword", "back\\slash", True),
	("fmt-bareword", "localhost:8080", False),
	("fmt-bareword", "a:", False),
	("fmt-bareword", "rw,noatime", False),
	("fmt-bareword", "a,", False),
	("fmt-bareword", ":0", False),
	("fmt-bareword", "f(x)", False),
	("fmt-bareword", "a)", False),
	("fmt-bareword", "a-b.c/d", True),
	("fmt-bareword", "a`b", False),
	("fmt-bareword", "x\u25c9y", False),
	("fmt-bareword", "a\u00a0b", False),
	("fmt-bareword", "a b", False),
	## A character nobody can see is escaped, so it needs quotes. A variation
	## selector after a visible character and a subdivision flag's tags stay.
	("fmt-bareword", "soft­hyphen", False),
	("fmt-bareword", "❤️", True),
	("fmt-bareword", "️a", False),
	("fmt-bareword", "a️️", False),
	("fmt-bareword", "\U0001f3f4\U000e0067\U000e0062\U000e0065\U000e006e\U000e0067\U000e007f", True),
	("fmt-bareword", "\U0001f3f4\U000e0067\U000e007f", False),
	("fmt-bareword", "hidden\U000e0068\U000e0069", False),
	("file", "a: 1", True),
	("file", "a: 1\n", True),
	("file", "a: 1\r\n", True),
	("file", "a: 1\r\r\n", True),
	## Every line may end in blanks and a CR is one, so `file` derives a CR run
	## under `[ CR ] LF` as well. Only the rule itself tells the two apart.
	("newline", "\r\r\n", True),
	("newline", "\n", True),
]

Node = tuple[Any, ...]


class GrammarError(Exception):
	pass


def fStripComment(line: str) -> str:
	out = []
	quoted = False
	prose = False
	for c in line:
		if c == '"' and not prose:
			quoted = not quoted
		elif c == "<" and not quoted:
			prose = True
		elif c == ">" and not quoted:
			prose = False
		elif c == ";" and not quoted and not prose:
			break
		out.append(c)
	return "".join(out)


def fRules(text: str) -> list[tuple[int, str, bool, str]]:
	"""(line number, name, incremental, elements) for each rule."""
	rules: list[tuple[int, str, bool, str]] = []
	for n, raw in enumerate(text.splitlines(), 1):
		line = fStripComment(raw).rstrip()
		if not line.strip():
			continue
		if line[0] in " \t":
			if not rules:
				raise GrammarError(f"line {n}: continuation with no rule above it")
			ln, name, inc, body = rules[-1]
			rules[-1] = (ln, name, inc, body + " " + line.strip())
			continue
		m = re.match(r"([A-Za-z][A-Za-z0-9-]*)\s*(=/|=)\s*(.*)$", line)
		if not m:
			raise GrammarError(f"line {n}: not a rule: {raw.strip()}")
		rules.append((n, m.group(1).lower(), m.group(2) == "=/", m.group(3)))
	return rules


TOKEN = re.compile(r"""
	\s+
	| (?P<name>[A-Za-z][A-Za-z0-9-]*)
	| (?P<rep>\d*\*\d*|\d+)
	| (?P<punct>[()\[\]/])
	| (?P<str>(?:%[si])?"[^"]*")
	| (?P<num>%x[0-9A-Fa-f]+(?:(?:\.[0-9A-Fa-f]+)+|-[0-9A-Fa-f]+)?
		|%d[0-9]+(?:(?:\.[0-9]+)+|-[0-9]+)?
		|%b[01]+(?:(?:\.[01]+)+|-[01]+)?)
	| (?P<prose><[^>]*>)
""", re.VERBOSE)


def fTokens(body: str) -> list[tuple[str, str]]:
	toks: list[tuple[str, str]] = []
	i = 0
	while i < len(body):
		m = TOKEN.match(body, i)
		if not m or m.end() == i:
			raise GrammarError(f"cannot read {body[i:i + 20]!r}")
		i = m.end()
		if m.lastgroup:
			toks.append((m.lastgroup, m.group(m.lastgroup)))
			# Elements concatenate only across whitespace, so %xEOF is a bad
			# number and not %xE followed by a rule named OF.
			if m.lastgroup in ("name", "str", "num", "prose") and i < len(body) and (body[i].isalnum() or body[i] in '%"<'):
				raise GrammarError(f"no space after {m.group(m.lastgroup)!r}")
	return toks


class Parser:
	def __init__(self, toks: list[tuple[str, str]]) -> None:
		self.toks = toks
		self.i = 0

	def fPeek(self) -> tuple[str, str] | None:
		return self.toks[self.i] if self.i < len(self.toks) else None

	def fAlt(self) -> Node:
		alts = [self.fCat()]
		while self.fPeek() == ("punct", "/"):
			self.i += 1
			alts.append(self.fCat())
		return ("alt", alts)

	def fCat(self) -> Node:
		items = []
		while (t := self.fPeek()) is not None and t not in (("punct", "/"), ("punct", ")"), ("punct", "]")):
			items.append(self.fRep())
		if not items:
			raise GrammarError("empty alternative")
		return ("cat", items)

	def fRep(self) -> Node:
		t = self.fPeek()
		lo, hi = 1, 1
		if t is not None and t[0] == "rep":
			self.i += 1
			if "*" in t[1]:
				a, b = t[1].split("*")
				lo, hi = int(a or 0), (int(b) if b else -1)
			else:
				lo = hi = int(t[1])
		el = self.fElement()
		return el if (lo, hi) == (1, 1) else ("rep", lo, hi, el)

	def fElement(self) -> Node:
		t = self.fPeek()
		if t is None:
			raise GrammarError("rule ends where an element was expected")
		self.i += 1
		kind, v = t
		if kind == "name":
			return ("rule", v.lower())
		if t == ("punct", "(") or t == ("punct", "["):
			inner = self.fAlt()
			close = ")" if v == "(" else "]"
			if self.fPeek() != ("punct", close):
				raise GrammarError(f"no closing {close}")
			self.i += 1
			return inner if v == "(" else ("rep", 0, 1, inner)
		if kind == "str":
			sensitive = v.startswith("%s")
			return ("str", v[v.index('"') + 1:-1], sensitive)
		if kind == "num":
			base = {"x": 16, "d": 10, "b": 2}[v[1]]
			digits = v[2:]
			if "-" in digits:
				a, b = digits.split("-")
				return ("range", int(a, base), int(b, base))
			return ("str", "".join(chr(int(p, base)) for p in digits.split(".")), True)
		if kind == "prose":
			raise GrammarError(f"prose value {v} cannot be checked")
		raise GrammarError(f"unexpected {v!r}")


def fCompile(body: str) -> Node:
	p = Parser(fTokens(body))
	node = p.fAlt()
	left = p.fPeek()
	if left is not None:
		raise GrammarError(f"unexpected {left[1]!r}")
	return node


def fRefs(node: Node, out: set[str]) -> None:
	kind = node[0]
	if kind == "rule":
		out.add(node[1])
	elif kind in ("alt", "cat"):
		for n in node[1]:
			fRefs(n, out)
	elif kind == "rep":
		fRefs(node[3], out)


class Matcher:
	"""Every end position a rule can reach from a start, so an ambiguous
	grammar needs no backtracking."""

	def __init__(self, rules: dict[str, Node], text: str) -> None:
		self.rules = rules
		self.text = text
		self.memo: dict[tuple[int, int], frozenset[int]] = {}
		self.busy: set[tuple[int, int]] = set()

	def fMatch(self, node: Node, pos: int) -> frozenset[int]:
		key = (id(node), pos)
		if key in self.memo:
			return self.memo[key]
		if key in self.busy:
			return frozenset()
		self.busy.add(key)
		got = self.fEval(node, pos)
		self.busy.discard(key)
		self.memo[key] = got
		return got

	def fEval(self, node: Node, pos: int) -> frozenset[int]:
		kind = node[0]
		t = self.text
		if kind == "rule":
			return self.fMatch(self.rules[node[1]], pos)
		if kind == "str":
			s, sensitive = node[1], node[2]
			seg = t[pos:pos + len(s)]
			hit = seg == s if sensitive else seg.lower() == s.lower()
			return frozenset([pos + len(s)]) if hit else frozenset()
		if kind == "range":
			return frozenset([pos + 1]) if pos < len(t) and node[1] <= ord(t[pos]) <= node[2] else frozenset()
		if kind == "alt":
			out: set[int] = set()
			for n in node[1]:
				out |= self.fMatch(n, pos)
			return frozenset(out)
		if kind == "cat":
			cur = {pos}
			for n in node[1]:
				nxt: set[int] = set()
				for p in cur:
					nxt |= self.fMatch(n, p)
				cur = nxt
				if not cur:
					break
			return frozenset(cur)
		lo, hi, el = node[1], node[2], node[3]
		frontier = {pos}
		seen: set[int] = set()
		ends: set[int] = set()
		count = 0
		while frontier:
			if count >= lo:
				frontier -= seen
				seen |= frontier
				ends |= frontier
			if count == hi:
				break
			nxt = set()
			for p in frontier:
				nxt |= self.fMatch(el, p)
			frontier = nxt
			count += 1
		return frozenset(ends)


##	The tokenizer tie. A row above is the grammar's claim about one piece of
##	text; what follows runs the same text through the real CLI and requires the
##	reading to agree. Without it the rows are a second grammar written by hand,
##	which is how the info-string rule came to be narrower than the parser.
##	Indentation and fence termination are context ABNF cannot state, so a line
##	rule's sample goes under a parent field, with a tab added when it has
##	no indent of its own - the rule's own indent is *(SP / HTAB), so that stays
##	inside it.

LINE_RULES = ("field-line", "fence-line", "list-item-line")


def fCli() -> Path | None:
	"""The debug CLI, or None when nothing is built."""
	env = os.environ.get("SHCL_CLI")
	path = Path(env) if env else Path(__file__).resolve().parent.parent.parent / "source" / "rust" / "target" / "debug" / "shcl"
	return path if os.access(path, os.X_OK) else None


def fRun(cli: Path, args: list[str], work: Path) -> tuple[int, list[str]]:
	r = subprocess.run([str(cli), *args], cwd=work, capture_output=True, encoding="utf-8", check=False)
	return r.returncode, r.stdout.splitlines()


def fWrite(work: Path, text: str) -> None:
	## Bytes, so a row with CRLF reaches the parser as it is written.
	(work / "s.shcl").write_bytes(text.encode("utf-8"))


def fClean(cli: Path, work: Path) -> bool:
	rc, out = fRun(cli, ["check", "s.shcl"], work)
	return rc == 0 and any("0 diagnostic(s)" in ln for ln in out)


def fFenceClose(cli: Path, work: Path, line: str) -> str:
	"""The closer a probe needs, read off the tokenizer's own value span rather
	than guessed from the text. Empty when the line opens no block."""
	(work / "one.shcl").write_bytes((line + "\n").encode("utf-8"))
	rc, out = fRun(cli, ["tokens", "one.shcl"], work)
	if rc != 0 or not out:
		return ""
	m = re.search(r" value=(\d+)-(\d+)", out[0])
	if not m:
		return ""
	## Spans are relative to the line with its indent taken off.
	body = line.lstrip(" \t")
	value = body[int(m.group(1)):int(m.group(2))]
	for ch in ("`", "~"):
		run = len(value) - len(value.lstrip(ch))
		if run >= 3:
			return ch * run
	return ""


def fLineProbe(cli: Path, work: Path, text: str) -> str:
	line = text if text[:1] in (" ", "\t") else "\t" + text
	indent = line[:len(line) - len(line.lstrip(" \t"))]
	close = fFenceClose(cli, work, line)
	rest = [indent + "x", indent + close] if close else []
	return "p:\n" + "".join(ln + "\n" for ln in [line, *rest])


def fTie(cli: Path, work: Path, rule: str, text: str) -> bool:
	"""Does the CLI read TEXT the way the grammar row says it does?"""
	if rule == "file":
		fWrite(work, text)
		return fClean(cli, work)
	if rule == "bareword":
		fWrite(work, f"k: {text}\n")
		if not fClean(cli, work):
			return False
		rc, out = fRun(cli, ["get", "--array", "s.shcl", "k"], work)
		return rc == 0 and out == [text]
	if rule == "info-string":
		fWrite(work, f"p:\n\t```{text}\n\tx\n\t```\n")
		## The rule takes the leading blanks with it; the parser records the
		## label trimmed, so that is what the sample is compared against.
		rc, out = fRun(cli, ["get", "--rawinfo", "s.shcl", "p"], work)
		return rc == 0 and out == [text.strip(" \t\r")]
	if rule == "newline":
		## The whole run ends the line, so the value reads back with none of it.
		## Bytes, since text mode would read a stray CR as a line end too.
		fWrite(work, f"a: 1{text}")
		r = subprocess.run([str(cli), "get", "s.shcl", "a"], cwd=work, capture_output=True, check=False)
		return fClean(cli, work) and r.returncode == 0 and r.stdout == b"1\n"
	if rule == "index-sel":
		## Index 1 is the second instance; a value selector finds neither.
		fWrite(work, "srv: a\n\tport: 1\nsrv: b\n\tport: 2\n")
		rc, out = fRun(cli, ["get", "s.shcl", f"srv({text}).port"], work)
		return rc == 0 and out == ["2"]
	if rule == "fmt-bareword":
		## The formatter's class, so the formatter is what answers: the value
		## goes in as data and the emitter picks the spelling.
		fWrite(work, "k: placeholder\n")
		rc, out = fRun(cli, ["set", f"--set=k={text}", "s.shcl"], work)
		return rc == 0 and out == [f"k: {text}"]
	fWrite(work, fLineProbe(cli, work, text))
	if not fClean(cli, work):
		return False
	if rule == "field-line":
		rc, out = fRun(cli, ["paths", "s.shcl"], work)
		return rc == 0 and any(ln.startswith("p.") for ln in out)
	if rule == "fence-line":
		return fRun(cli, ["get", "--raw", "s.shcl", "p"], work)[0] == 0
	## list-item-line: the parent has the item and no child field.
	return fRun(cli, ["get", "s.shcl", "p"], work)[0] == 0 and fRun(cli, ["children", "s.shcl", "p"], work)[1] == []


## One status line per test, with its test ID. A marker opens a test and
## closes the one before; a test fails when FAILS grew while it was open.
FAILS = [0]
_open: dict[str, Any] = {}


def test_line(status: str, tid: str, name: str) -> None:
	print(f"{status:<4} {tid} check-abnf {name}", flush=True)


def test_id_end(status: str | None = None) -> None:
	if not _open:
		return
	if status is None:
		status = "FAIL" if FAILS[0] > _open["fails"] else _open["status"]
	test_line(status, _open["tid"], _open["name"])
	_open.clear()


def test_id(tid: str, name: str) -> None:
	test_id_end()
	_open.update(tid=tid, name=name, status="ok", fails=FAILS[0])


def test_skip() -> None:
	if _open:
		_open["status"] = "skip"


def main() -> int:
	here = Path(__file__).resolve().parent
	path = Path(sys.argv[1]) if len(sys.argv) > 1 else here.parent.parent / "project" / "grammar.abnf"
	if not path.is_file():
		print(f"check-abnf: no such file: {path}", file=sys.stderr)
		return 2

	def fBad(msg: str) -> None:
		print(f"check-abnf: {msg}", file=sys.stderr)
		FAILS[0] += 1

	test_id("EqL32jg", "grammar-is-abnf")
	rules: dict[str, Node] = {}
	lines: dict[str, int] = {}
	try:
		parsed = fRules(path.read_text(encoding="utf-8"))
	except GrammarError as e:
		print(f"check-abnf: {path.name}: {e}", file=sys.stderr)
		return 1
	for n, name, inc, body in parsed:
		try:
			node = fCompile(body)
		except GrammarError as e:
			fBad(f"{path.name}:{n}: {name}: {e}")
			continue
		if name in CORE:
			fBad(f"{path.name}:{n}: {name} redefines the core rule of that name (rule names ignore case)")
		if inc:
			if name not in rules:
				fBad(f"{path.name}:{n}: {name} =/ with no rule to add to")
				continue
			rules[name] = ("alt", [rules[name], node])
		elif name in rules:
			fBad(f"{path.name}:{n}: {name} defined twice")
		else:
			rules[name] = node
			lines[name] = n
	for name, body in CORE.items():
		rules.setdefault(name, fCompile(body))
	for name, node in sorted(rules.items()):
		refs: set[str] = set()
		fRefs(node, refs)
		for r in sorted(refs - rules.keys()):
			fBad(f"{path.name}:{lines.get(name, 0)}: {name} names {r}, which is not defined")
	if FAILS[0]:
		test_id_end()
		print(f"check-abnf: {FAILS[0]} problem(s)", file=sys.stderr)
		return 1
	test_id("EqL32jh", "samples-derive")
	for rule, text, want in SAMPLES:
		if rule not in rules:
			fBad(f"no rule {rule} to check {text!r} against")
			continue
		got = len(text) in Matcher(rules, text).fMatch(rules[rule], 0)
		if got != want:
			fBad(f"{rule} {'does not derive' if want else 'derives'} {text!r}")
	if FAILS[0]:
		test_id_end()
		print(f"check-abnf: {FAILS[0]} problem(s)", file=sys.stderr)
		return 1

	test_id("EqWax3I", "samples-read-alike-by-the-cli")
	cli = fCli()
	if cli is None:
		if os.environ.get("SHCL_GATE_STRICT"):
			fBad("no debug binary to read the samples with, and the gate requires it")
			test_id_end()
			print(f"check-abnf: {FAILS[0]} problem(s)", file=sys.stderr)
			return 1
		## On stderr, where a skip reads as the warning it is.
		test_skip()
		print("check-abnf: SKIPPED the tokenizer tie - no debug binary (cargo build first)", file=sys.stderr)
		with open(os.environ.get("SHCL_GATE_SKIPS") or os.devnull, "a", encoding="utf-8") as fh:
			fh.write("check-abnf\n")
		test_id_end()
		print(f"check-abnf: OK ({len(rules) - len(CORE)} rules, {len(SAMPLES)} samples, tie skipped)")
		return 0

	with tempfile.TemporaryDirectory() as tmp:
		work = Path(tmp)
		for rule, text, want in SAMPLES:
			if fTie(cli, work, rule, text) == want:
				continue
			fBad(f"{rule} {text!r}: the grammar {'derives' if want else 'refuses'} it and the CLI does the opposite")
	if FAILS[0]:
		test_id_end()
		print(f"check-abnf: {FAILS[0]} problem(s)", file=sys.stderr)
		return 1
	test_id_end()
	print(f"check-abnf: OK ({len(rules) - len(CORE)} rules, {len(SAMPLES)} samples, {len(SAMPLES)} ties)")
	return 0


if __name__ == "__main__":
	rc = main()
	test_id_end("FAIL" if rc else None)
	sys.exit(rc)


##	History:
##		2026-09-19  Created, when the info-string rule turned out narrower than
##		            the fence labels the parser reads (20260918b item 51).
##		2026-09-21  Every sample is also read by the real CLI, so the rows
##		            cannot drift away from the parser and the formatter.
##		2026-09-26  The newline rule takes a whole CR run.
##		2026-10-05  The value syntax: brackets, "- " items, escape names and
##		            the bare rules.
##		2026-10-06  Selectors in parens.
