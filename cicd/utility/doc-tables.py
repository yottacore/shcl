#!/usr/bin/env python3

##	Purpose: Run the examples in a design doc's tables through every binding's
##		CLI, and hold each one to the result the table states. The tables are
##		read from the doc each run, so an edit to a row is what gets checked.
##		Every binding has to print the same bytes, and that output has to be
##		what the doc says: four bindings agreeing proves parity, not that the
##		doc's claim holds.
##
##		A table is known by its header. A header with no reader here fails the
##		run, so a new example table can't go unread. A row with no input and
##		result a machine can read is prose and is counted as skipped, and the
##		run fails when fewer rows than MIN were checked.
##	Syntax: doc-tables.py DOC MIN NAME|CLI [NAME|CLI ...]
##	Exit: 0 = every row read holds, 1 = a row fails or too few ran, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

MARK = "◉"
STATUS_RC = {"Empty": 2, "NotFound": 3, "BadType": 4}
NUMBER_WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6}
CODE = re.compile(r"[EHV]\d{3}")
##	A code span that is a whole line by itself: a list item, or a name or path
##	then a colon, a blank and a value. Anything else in a meaning cell is a
##	fragment, such as `[a,, b]`, `host(a:b)`, `rw,noatime` or a schema key's
##	`reopen:`.
WHOLE_LINE = re.compile(r"- \S.*|[^\s:]+:\s+\S.*")
PATH_HEAD = re.compile(r"[A-Za-z][\w-]*\[[^\]\s]*\]")
##	Whole-line spans in a code table that are not an example of the row's code,
##	by content. Each says why.
NOT_AN_EXAMPLE = {
	"- value": "the spelling the row's message points to, not the fault",
	"route: [GET, POST]": "the fault needs lines under it, which a table cell can't show",
	"p: a,b": "the hint needs an older Format line above it",
}


@dataclass
class Row:
	line: int
	cells: list[str]


@dataclass
class Table:
	line: int
	header: list[str]
	rows: list[Row] = field(default_factory=list)


@dataclass
class Result:
	rc: int
	out: str


class Gate:
	def __init__(self, doc: Path, bindings: list[tuple[str, str]], work: Path) -> None:
		self.doc = doc
		self.bindings = bindings
		self.work = work
		self.fails = 0
		self.nFile = 0

	def bad(self, row: Row, msg: str) -> None:
		print(f"doc-tables: {self.doc.name}:{row.line}: {msg}", file=sys.stderr)
		self.fails += 1

	def run(self, row: Row, text: str, argv: list[str]) -> Result:
		"""Every binding on one document. FILE in argv is the document."""
		self.nFile += 1
		path = self.work / f"t{self.nFile}.shcl"
		path.write_text(text, encoding="utf-8", newline="")
		args = [str(path) if a == "FILE" else a for a in argv]
		seen: list[tuple[str, int, bytes]] = []
		for name, cli in self.bindings:
			proc = subprocess.run([cli, *args], capture_output=True, stdin=subprocess.DEVNULL, timeout=60, check=False)
			seen.append((name, proc.returncode, proc.stdout))
		first = seen[0]
		for name, rc, out in seen[1:]:
			if (rc, out) != first[1:]:
				self.bad(row, f"{' '.join(argv)} on {text!r}: {first[0]} exits {first[1]} with {first[2]!r}, {name} exits {rc} with {out!r}")
		return Result(first[1], first[2].decode("utf-8", "surrogateescape"))

	def codes(self, row: Row, text: str) -> list[str]:
		got = self.run(row, text, ["check", "FILE"]).out
		return re.findall(r"^line \d+: \w+: ([EHV]\d{3})$", got, re.M)


def fSplitCells(line: str) -> list[str]:
	"""A table row's cells, split on pipes outside code spans."""
	body = line.strip()
	body = body.removeprefix("|")
	cells: list[str] = []
	cur = ""
	i = 0
	while i < len(body):
		if body[i] == "`":
			n = len(body[i:]) - len(body[i:].lstrip("`"))
			close = re.compile(rf"(?<!`)`{{{n}}}(?!`)").search(body, i + n)
			if close is not None:
				cur += body[i : close.end()]
				i = close.end()
				continue
			cur += body[i : i + n]
			i += n
			continue
		if body[i] == "|":
			cells.append(cur.strip())
			cur = ""
		else:
			cur += body[i]
		i += 1
	cells.append(cur.strip())
	return cells


def fPieces(cell: str) -> list[tuple[str, str]]:
	"""A cell as ("code", text) and ("text", text) pieces, in order."""
	pieces: list[tuple[str, str]] = []
	pos = 0
	for hit in re.finditer(r"(`+)(.+?)(?<!`)\1(?!`)", cell):
		if hit.start() > pos:
			pieces.append(("text", cell[pos : hit.start()]))
		inner = hit.group(2)
		if len(inner) > 1 and inner.startswith(" ") and inner.endswith(" ") and inner.strip():
			inner = inner[1:-1]
		pieces.append(("code", inner))
		pos = hit.end()
	if pos < len(cell):
		pieces.append(("text", cell[pos:]))
	return pieces


def fSpans(cell: str) -> list[str]:
	return [t for k, t in fPieces(cell) if k == "code"]


def fPlain(cell: str) -> str:
	return "".join(t for k, t in fPieces(cell) if k == "text").strip()


def fTables(doc: Path) -> list[Table]:
	lines = doc.read_text(encoding="utf-8").splitlines()
	tables: list[Table] = []
	fence = ""
	i = 0
	while i < len(lines):
		stripped = lines[i].lstrip()
		hit = re.match(r"(~~~+|```+)", stripped)
		if hit and (not fence or stripped.rstrip() == fence):
			fence = "" if fence else hit.group(1)
		elif not fence and stripped.startswith("|") and i + 1 < len(lines) and re.match(r"\s*\|\s*:?-", lines[i + 1]):
			table = Table(i + 1, fSplitCells(lines[i]))
			i += 2
			while i < len(lines) and lines[i].lstrip().startswith("|"):
				table.rows.append(Row(i + 1, fSplitCells(lines[i])))
				i += 1
			tables.append(table)
			continue
		i += 1
	return tables


def fValueLine(text: str) -> str:
	return text + "\n"


def fItemDoc(text: str) -> str:
	return f"list:\n\t{text}\n"


def fFieldPath(line: str) -> str:
	return line.split(": ", 1)[0]


def fEscapes(g: Gate, table: Table) -> tuple[int, int]:
	"""Each name and alias reads as the row's character, and the writer puts the
	first name back for the controls and the mark itself (the other characters
	the writer quotes or escapes by its own rules)."""
	text = ""
	want: dict[str, tuple[Row, str, str | None]] = {}
	for row in table.rows:
		names = fSpans(row.cells[0])
		if len(names) != 1 or not (names[0].startswith(MARK) and names[0].endswith(MARK)):
			g.bad(row, f"no escape name in {row.cells[0]!r}")
			continue
		canon = names[0].strip(MARK)
		aliases = [a.strip(MARK) for a in fSpans(row.cells[1])]
		if "XXXX" in canon:
			##	The code point row names prefixes, so each is tried on a few
			##	code points, and a hidden one has to come back in the first form.
			for prefix in [canon.split("XXXX")[0], *aliases]:
				for hexd, char in (("41", "A"), ("25c9", MARK), ("1F600", "\U0001f600")):
					key = f"e{len(want)}"
					text += f'{key}: "a{MARK}{prefix}{hexd}{MARK}b"\n'
					want[key] = (row, f"a{char}b", None)
				key = f"e{len(want)}"
				text += f'{key}: "a{MARK}{prefix}200b{MARK}b"\n'
				want[key] = (row, "a​b", f'{key}: "a{MARK}{canon.replace("XXXX", "200B")}{MARK}b"')
			continue
		points = re.findall(r"U\+([0-9A-Fa-f]{4,6})", fPlain(row.cells[2]))
		char = "".join(chr(int(p, 16)) for p in points) if points else "".join(fSpans(row.cells[2])[:1])
		if not char:
			g.bad(row, f"no character in {row.cells[2]!r}")
			continue
		written = all(ord(c) < 0x20 or ord(c) == 0x7F for c in char) or char == MARK
		for name in [canon, *aliases]:
			key = f"e{len(want)}"
			text += f'{key}: "a{MARK}{name}{MARK}b"\n'
			want[key] = (row, f"a{char}b", f'{key}: "a{MARK}{canon}{MARK}b"' if written else None)
	if not want:
		return 0, 0
	anyRow = table.rows[0]
	got: dict[str, str] = {}
	for line in g.run(anyRow, text, ["paths", "--json", "FILE"]).out.splitlines():
		obj = json.loads(line)
		got[obj["path"]] = obj["value"]
	fmtLines = {ln.split(":", 1)[0]: ln for ln in g.run(anyRow, text, ["fmt", "FILE"]).out.splitlines()}
	for key, (row, value, line) in want.items():
		if got.get(key) != value:
			g.bad(row, f"{text.splitlines()[int(key[1:])]!r} reads as {got.get(key)!r}, the table says {value!r}")
		if line is not None and fmtLines.get(key) != line:
			g.bad(row, f"{text.splitlines()[int(key[1:])]!r} is written {fmtLines.get(key)!r}, the table's first name gives {line!r}")
	return len({id(r) for r, _, _ in want.values()}), 0


def fCodes(g: Gate, table: Table) -> tuple[int, int]:
	"""A whole line quoted in a code's meaning gives that code, and only that.
	A retired code gives none, and a line its row says is another code now
	gives that one."""
	checked = prose = 0
	retiredCol = len(table.header) > 2 and table.header[2] == "Outcome"
	for row in table.rows:
		code = next((s for s in fSpans(row.cells[0]) if CODE.fullmatch(s)), None)
		if code is None:
			g.bad(row, f"no code in {row.cells[0]!r}")
			continue
		spans = fSpans(row.cells[1])
		lines = [s for s in spans if WHOLE_LINE.fullmatch(s) and s not in NOT_AN_EXAMPLE]
		if not lines:
			prose += 1
			continue
		checked += 1
		retired = retiredCol and fPlain(row.cells[2]).startswith("None")
		now = [s for s in spans if CODE.fullmatch(s) and s != code]
		for line in lines:
			got = g.codes(row, fItemDoc(line) if line.startswith("- ") else fValueLine(line))
			if retired:
				wantCodes = now[-1:]
			else:
				wantCodes = [code]
			if got != wantCodes:
				g.bad(row, f"{line!r} gives {got or 'no diagnostic'}, the table says {wantCodes or 'none'}")
	return checked, prose


def fReads(g: Gate, table: Table) -> tuple[int, int]:
	"""A line, what it reads as, and why. The reads-as cell is a value, a code,
	or one of a few worded results, and a wording with no rule here fails."""
	checked = 0
	for row in table.rows:
		spans = fSpans(row.cells[0])
		if len(spans) != 1 or ": " not in spans[0]:
			g.bad(row, f"no field line in {row.cells[0]!r}")
			continue
		line = spans[0]
		text = fValueLine(line)
		path = fFieldPath(line)
		said = row.cells[1]
		said_spans = fSpans(said)
		said_plain = fPlain(said)
		checked += 1
		clean = "ok (0 diagnostic(s))\n"
		if not said_plain and len(said_spans) == 1 and CODE.fullmatch(said_spans[0]):
			got = g.codes(row, text)
			if got != said_spans:
				g.bad(row, f"{line!r} gives {got or 'no diagnostic'}, the table says {said_spans[0]}")
			continue
		check = g.run(row, text, ["check", "FILE"]).out
		if check != clean:
			g.bad(row, f"{line!r} does not load clean: {check!r}")
		read = g.run(row, text, ["get", "FILE", path])
		count = re.fullmatch(r"(\w+) (lines|elements)", said_plain)
		if not said_plain and len(said_spans) == 1:
			if (read.rc, read.out) != (0, said_spans[0] + "\n"):
				g.bad(row, f"{line!r} reads as {read.out!r} at exit {read.rc}, the table says {said_spans[0]!r}")
		elif said_plain == ", flagged as backticked" and len(said_spans) == 1:
			if (read.rc, read.out) != (0, said_spans[0] + "\n"):
				g.bad(row, f"{line!r} reads as {read.out!r} at exit {read.rc}, the table says {said_spans[0]!r}")
			tokens = g.run(row, text, ["tokens", "FILE"]).out
			if not re.search(r" elem=\d+-\d+`$", tokens, re.M):
				g.bad(row, f"{line!r} is not flagged as backticked: {tokens!r}")
		elif count and count.group(1) in NUMBER_WORDS:
			n = NUMBER_WORDS[count.group(1)]
			if count.group(2) == "elements":
				read = g.run(row, text, ["get", "--array", "FILE", path])
			if read.rc != 0 or len(read.out.splitlines()) != n:
				g.bad(row, f"{line!r} reads as {read.out!r} at exit {read.rc}, the table says {said_plain}")
		elif said_plain == "a date":
			read = g.run(row, text, ["get", "--datetime", "FILE", path])
			if read.rc != 0:
				g.bad(row, f"{line!r} does not read as a date: exit {read.rc}")
		elif said_plain == "field" and len(said_spans) == 1:
			name = said_spans[0]
			quoted = name if re.fullmatch(r"[A-Za-z][\w-]*", name) else f'"{name}"'
			if read.rc != 0 or g.run(row, text, ["get", "FILE", quoted]).rc != 0:
				g.bad(row, f"{line!r} has no field {name!r}")
		else:
			checked -= 1
			g.bad(row, f"no rule here for reads-as {said!r}")
	return checked, 0


def fTyped(g: Gate, table: Table) -> tuple[int, int]:
	"""File says, then one column per typed read, named `Read as TYPE[ array]`."""
	cols: list[list[str]] = []
	for head in table.header[1:]:
		hit = re.fullmatch(r"Read as (\w+)( array)?", head)
		if hit is None:
			g.bad(table.rows[0], f"no read for column {head!r}")
			return 0, 0
		cols.append([f"--{hit.group(1)}", *(["--array"] if hit.group(2) else [])])
	checked = 0
	for row in table.rows:
		spans = fSpans(row.cells[0])
		if len(spans) != 1 or ": " not in spans[0]:
			g.bad(row, f"no field line in {row.cells[0]!r}")
			continue
		checked += 1
		line = spans[0]
		for argv, cell in zip(cols, row.cells[1:], strict=True):
			read = g.run(row, fValueLine(line), ["get", *argv, "FILE", fFieldPath(line)])
			said = fSpans(cell)
			what = f"{line!r} read {' '.join(argv)}"
			if (len(said) == 1 and said[0] in STATUS_RC) or fPlain(cell) == "empty":
				rc = STATUS_RC.get(said[0] if said else "Empty", 2)
				if read.rc != rc:
					g.bad(row, f"{what} exits {read.rc}, the table says {cell}")
			elif fPlain(cell) == "error":
				if read.rc in (0, 1):
					g.bad(row, f"{what} exits {read.rc}, the table says it fails")
			elif len(said) == 1 and not fPlain(cell):
				want = said[0] + "\n"
				if "--array" in argv:
					inner = said[0].removeprefix("[").removesuffix("]")
					want = "".join(e + "\n" for e in inner.split(", ") if e)
				if (read.rc, read.out) != (0, want):
					g.bad(row, f"{what} gives {read.out!r} at exit {read.rc}, the table says {said[0]}")
			else:
				g.bad(row, f"no rule here for {cell!r}")
	return checked, 0


def fWrap(before: str, after: str) -> tuple[str, str, str | None]:
	"""A 2.x spelling put where it means what the table says: a whole line as
	is, an item under a field, a selector at the head of a path, anything else
	as a value. The value's path comes back for a read."""
	if before.startswith(("* ", "- ")):
		return fItemDoc(before), fItemDoc(after), None
	if WHOLE_LINE.fullmatch(before):
		return fValueLine(before), fValueLine(after), None
	if PATH_HEAD.fullmatch(before):
		return f"{before}.k: 1\n", f"{after}.k: 1\n", None
	return f"v: {before}\n", f"v: {after}\n", "v"


def fMigration(g: Gate, table: Table) -> tuple[int, int]:
	"""Before, a 2.x spelling, and After, what `migrate --from-2x` writes. A
	before cell is one or more spans joined by "or", maybe with a comma and a
	description after, and the after cell opens with a span or "As written".
	Anything else is prose."""
	checked = prose = 0
	for row in table.rows:
		pieces = fPieces(row.cells[0])
		if len(pieces) > 1 and pieces[-1][0] == "text" and pieces[-1][1].startswith(","):
			pieces = pieces[:-1]
		befores = [t for k, t in pieces if k == "code"]
		joins = {t.strip() for k, t in pieces if k == "text"}
		afterPieces = fPieces(row.cells[1])
		if not befores or joins - {"or"} or not afterPieces:
			prose += 1
			continue
		kind, first = afterPieces[0]
		if kind == "code":
			afters = [first] * len(befores)
		elif first.startswith("As written"):
			afters = befores
		else:
			prose += 1
			continue
		readsAs = re.search(r"reads as `([^`]*)`", row.cells[1])
		checked += 1
		for before, after in zip(befores, afters, strict=True):
			text, want, path = fWrap(before, after)
			mig = g.run(row, text, ["migrate", "--from-2x", "FILE"])
			body = "".join(ln + "\n" for ln in mig.out.splitlines() if not ln.startswith("##"))
			if (mig.rc, body) != (0, want):
				g.bad(row, f"migrate --from-2x on {text!r} gives {body!r} at exit {mig.rc}, the table says {want!r}")
				continue
			if readsAs and path is not None:
				read = g.run(row, mig.out, ["get", "FILE", path])
				if read.out != readsAs.group(1) + "\n":
					g.bad(row, f"{want!r} reads as {read.out!r}, the table says {readsAs.group(1)!r}")
	return checked, prose


def fTokens(cell: str) -> dict[str, bool]:
	"""`a`/`b` pairs, true then false, with `enable(d)` standing for both."""
	tokens: dict[str, bool] = {}
	for yes, no in re.findall(r"`([^`]+)`/`([^`]+)`", cell):
		for word, value in ((yes, True), (no, False)):
			opt = re.fullmatch(r"(\w+)\((\w+)\)", word)
			for w in [opt.group(1), opt.group(1) + opt.group(2)] if opt else [word]:
				tokens[w] = value
	return tokens


def fStrictness(g: Gate, table: Table) -> tuple[int, int]:
	"""One column per level, `Name (N)`. A row is a conversion, `TYPE -> TYPE`
	with `in` -> out pairs or `in` -> TYPE with a value per level, or a token
	set of `true`/`false` pairs. A row with no input it names is prose."""
	levels: list[str] = []
	for head in table.header[1:]:
		hit = re.search(r"\((\d)", head)
		if hit is None:
			g.bad(table.rows[0], f"no level in column {head!r}")
			return 0, 0
		levels.append(hit.group(1))
	types = {"int": "--int", "float": "--float", "boolean": "--bool"}
	checked = prose = 0
	for row in table.rows:
		behavior = row.cells[0]
		cells = row.cells[1:]
		sets = [fTokens(c) for c in cells]
		kind = behavior.split()[0].lower() if behavior.split() else ""
		if all(sets) or (any(sets) and kind in types):
			for i, cell in enumerate(cells):
				base = re.search(r"(\w+) set plus", cell)
				if base:
					col = next((j for j, h in enumerate(table.header[1:]) if h.startswith(base.group(1))), None)
					if col is None:
						g.bad(row, f"no column {base.group(1)!r} to add to")
						continue
					sets[i] = {**sets[col], **sets[i]}
			everyToken = {t for s in sets for t in s}
			checked += 1
			for level, accepted in zip(levels, sets, strict=True):
				for tok in sorted(everyToken):
					read = g.run(row, f"v: {tok}\n", ["get", types[kind], f"--strictness={level}", "FILE", "v"])
					if tok in accepted:
						want = "true\n" if accepted[tok] else "false\n"
						if (read.rc, read.out) != (0, want):
							g.bad(row, f"{tok!r} at strictness {level} gives {read.out!r} at exit {read.rc}, the table says {want.strip()}")
					elif read.rc != STATUS_RC["BadType"]:
						g.bad(row, f"{tok!r} at strictness {level} exits {read.rc}, the table leaves it out")
			continue
		conv = re.fullmatch(r"(?:(\w+)|`([^`]+)`) -> (\w+)", behavior)
		if conv is None or conv.group(3) not in types:
			prose += 1
			continue
		pairs = [re.findall(r"`([^`]+)` -> ([^\s,)]+)", c) for c in cells]
		inputs = [conv.group(2)] if conv.group(2) else []
		inputs += [i for p in pairs for i, _ in p if i not in inputs]
		if not inputs:
			prose += 1
			continue
		checked += 1
		for level, cell, pair in zip(levels, cells, pairs, strict=True):
			said = dict(pair)
			for value in inputs:
				read = g.run(row, f"v: {value}\n", ["get", types[conv.group(3)], f"--strictness={level}", "FILE", "v"])
				if fSpans(cell) == ["BadType"]:
					want: tuple[int, str | None] = (STATUS_RC["BadType"], None)
				elif value in said:
					want = (0, said[value] + "\n")
				elif conv.group(2) and not fSpans(cell):
					want = (0, fPlain(cell) + "\n")
				else:
					g.bad(row, f"no rule here for {cell!r}")
					break
				if read.rc != want[0] or (want[1] is not None and read.out != want[1]):
					g.bad(row, f"{value!r} at strictness {level} gives {read.out!r} at exit {read.rc}, the table says {cell}")
	return checked, prose


READERS: dict[str, Callable[[Gate, Table], tuple[int, int]]] = {
	"Canonical|Aliases|Character": fEscapes,
	"Escape|Aliases|Character": fEscapes,
	"Code|Meaning|Outcome": fCodes,
	"Code|Meaning": fCodes,
	"Line|Reads as|Why": fReads,
	"File says|Read as int|Read as int array|Read as string": fTyped,
	"Before|After": fMigration,
	"Behavior|Loose (1)|Standard (2, default)|Strict (3)": fStrictness,
}
##	Tables with no example in them, by header, and why.
PROSE_TABLES = {
	"Text|`◉` escapes|Whitespace inside|Notes": "the rules in short, one row per kind of text",
	"ID|Title|Relation": "backlog items",
	"Language|Convenience tier|Full tier": "call spellings in each language",
	"Key|Value|Meaning": "schema keys",
	"Code|Meaning|Line": "schema codes, which name no line",
}


def main() -> int:
	if len(sys.argv) < 4 or not sys.argv[2].isdigit():
		print("usage: doc-tables.py DOC MIN NAME|CLI [NAME|CLI ...]", file=sys.stderr)
		return 2
	doc = Path(sys.argv[1])
	floor = int(sys.argv[2])
	bindings = [tuple(b.split("|", 1)) for b in sys.argv[3:]]
	if not doc.is_file() or any(len(b) != 2 for b in bindings):
		print(f"doc-tables: no doc at {doc}, or a binding is not NAME|CLI", file=sys.stderr)
		return 2
	checked = prose = 0
	with tempfile.TemporaryDirectory() as work:
		g = Gate(doc, [(b[0], b[1]) for b in bindings], Path(work))
		tables = fTables(doc)
		for table in tables:
			key = "|".join(table.header)
			if key in PROSE_TABLES:
				prose += len(table.rows)
				continue
			reader = READERS.get(key)
			if reader is None:
				g.bad(Row(table.line, []), f"a table this gate has no reader for: {key!r}. Teach doc-tables.py to read it, or list it as prose")
				continue
			c, p = reader(g, table)
			if c == 0:
				g.bad(Row(table.line, []), f"no row of the table {key!r} was checked")
			checked += c
			prose += p
		fails = g.fails
	print(f"doc-tables: {doc.name}: {checked} row(s) checked in {len(tables)} table(s), {prose} prose row(s) skipped")
	if checked < floor:
		print(f"doc-tables: {doc.name}: only {checked} row(s) checked, under the floor of {floor}", file=sys.stderr)
		return 1
	return 1 if fails else 0


if __name__ == "__main__":
	sys.exit(main())


##	History:
##		2026-10-10  Created: the value syntax doc's and the spec's example
##		            tables run through all four CLIs (2026100719122102).
