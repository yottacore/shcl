#!/usr/bin/env python3

##	Purpose: Test IDs. Every test the pipeline runs has one, and prints it
##		on its status line. An ID is the test's creation time in whole minutes
##		since 2000-01-01 00:00 UTC, in lowercase Crockford base 32, padded to
##		five characters, so IDs sort by age. When two tests fall on one minute
##		the newer takes the next free one. An ID never changes once given.
##	Syntax:
##		test-ids.py new [COUNT]   print COUNT fresh IDs (default 1)
##		test-ids.py when ID ...   print the time each ID stands for
##		test-ids.py find ID ...   print where each ID is defined
##		test-ids.py check         every test has an ID, and no two share one
##		test-ids.py list          put the IDs each step runs under it, in the
##		                          step list `cicd.bash --list` feeds it
##		test-ids.py backlog [--since=YYYYmmDD] [FILE]
##		                          every closed bug, feature or enhancement
##		                          names a test ID, or says why it has none
##	Exit: 0 = clean, 1 = a check failed, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


from __future__ import annotations

import fnmatch
import re
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

DIGITS = "0123456789abcdefghjkmnpqrstvwxyz"
EPOCH_2000 = 946684800
WIDTH = 5
ID = r"[0-9a-hjkmnp-tv-z]{5}"
repo = Path(__file__).resolve().parents[2]


def encode(minutes: int) -> str:
	out = ""
	while minutes:
		minutes, digit = divmod(minutes, 32)
		out = DIGITS[digit] + out
	return out.rjust(WIDTH, "0")


def decode(tid: str) -> int:
	minutes = 0
	for ch in tid:
		minutes = minutes * 32 + DIGITS.index(ch)
	return minutes


def fNow() -> int:
	return int(time.time() - EPOCH_2000) // 60


def fWhen(tid: str) -> str:
	stamp = datetime.fromtimestamp(EPOCH_2000 + decode(tid) * 60, tz=timezone.utc)
	return stamp.strftime("%Y-%m-%d %H:%M UTC")


##	Where tests are defined. A "need" pattern finds each test, and the ID
##	pattern has to match on the line it names (0 = the same line, 1 = the next
##	non-blank one). The rest only collect IDs, since a marker is the test there:
##	a failure before the first marker is the runner's to refuse.
NEED: list[tuple[str, str, str, int]] = [
	("source/rust/tests/*.rs", r"^\s*#\[test\]$", rf'^\s*let _id = test_id\("({ID})"\);$', 2),
	("source/rust/src/lib.rs", r"^\s*#\[test\]$", rf'^\s*let _id = test_id\("({ID})"\);$', 2),
	("source/rust/src/main.rs", r"^\s*#\[test\]$", rf'^\s*let _id = test_id\("({ID})"\);$', 2),
	("source/go/*_test.go", r"^func Test\w+\(t \*testing\.T\) \{$", rf'^\tdefer testID\(t, "({ID})"\)$', 1),
]
COLLECT: list[tuple[str, str]] = [
	("source/python/tests/*.py", rf'\btest_id\("({ID})", "[^"]+"\)'),
	("source/go/*_test.go", rf'\bstatusLine\(\w+, "({ID})", "[^"]+"\)'),
	("source/c/tests/*.c", rf'\btest_id\("({ID})", "[^"]+"\)'),
	("source/c/tests/*.cpp", rf'\btest_id\("({ID})", "[^"]+"\)'),
	("cicd/utility/*.bash", rf"\bfTest ({ID}) \S"),
	("cicd/utility/*.py", rf'\btest_id\("({ID})", "[^"]+"\)'),
	("cicd/utility/win-runners.bash", rf"\bfRun --id ({ID}) "),
	("cicd/utility/*.ps1", rf"\bTest-Check -Id '({ID})' "),
	("cicd/config.bash", rf"^PROFILE_CHECK_ID=({ID})$"),
]
##	A marker still holding a base 62 ID from before 2026-10-30 matches none of
##	the above, so it would run unlisted. These find it.
OLD = r"[0-9A-Za-z]{7}"
OLD_COLLECT = [(glob, pattern.replace(ID, OLD)) for glob, pattern in COLLECT]
##	Every test a language's own runner finds, in any tracked file. One outside
##	the NEED table's files, or written so its pattern misses it, would run with
##	no ID and nothing here saying so. TestMain runs the tests and is none. The
##	comparison tool's crate stays out of the gate, so its tests are not CI tests.
STRAY: list[tuple[str, str]] = [
	("*.rs", r"^\s*#\[test\]"),
	("*_test.go", r"^func Test(?!Main\()\w*\("),
]
STRAY_EXEMPT = ("cicd/utility/comparison/",)
##	Arrays whose every row is a test, with the ID as its first field.
ROWS: list[tuple[str, str]] = [
	("cicd/utility/cli-regress.bash", "rows"),
	("cicd/utility/cli-regress.bash", "saveCases"),
	("cicd/utility/cli-regress.bash", "diagExits"),
	("cicd/utility/perf-gate.bash", "workloads"),
]


##	Which tests a step runs, for `list`. A step runs a script it starts, at the
##	head of a command or after `;`, `&&`, `|`, `(`, `then` or `env VAR=...`,
##	and a test program it builds with `-o`, not a file it only lints or
##	compiles. A suite's runner names no test file, so it is matched here, and
##	each binding's runner reads the corpus. A script that runs another
##	script's markers lists them too. A wrapper that reruns a suite, such as
##	the sanitizers, lists only its own, so each ID shows under the step that
##	is its home.
CORPUS = "project/conformance"
SUITES: list[tuple[str, list[str]]] = [
	(r"\bcargo test\b.*\bsource/rust/Cargo\.toml\b", ["source/rust/tests/*.rs", "source/rust/src/lib.rs", "source/rust/src/main.rs", CORPUS]),
	## Go builds a _windows file only for windows.
	(r"\bgo -C source/go test\b", ["source/go/*_test.go", "!*_windows_test.go", CORPUS]),
	(r"\bPROFILE_CHECK_ID\b", ["cicd/config.bash"]),
]
CALLS: dict[str, list[str]] = {
	"source/python/tests/conformance.py": [CORPUS],
	"source/c/tests/conformance.c": [CORPUS],
	"cicd/utility/check-docs.bash": ["cicd/utility/check-abnf.py"],
	"cicd/utility/check-formats.bash": ["cicd/utility/check-format-reads.py"],
	"cicd/utility/fs-property.bash": ["source/rust/tests/fs_property.rs", "source/go/fs_property_test.go", "source/python/tests/fs_property.py", "source/c/tests/fs_property.c"],
	"cicd/utility/soak-c.bash": ["source/c/tests/soak.c"],
	"cicd/utility/win-runners.bash": ["cicd/utility/winpath-regress.ps1"],
}
HEAD = r"(?:^|[;&|(]\s*|\bthen\s+|\benv\s+(?:\w+=\S+\s+)*)"
RUN_SCRIPT = rf"{HEAD}(?:\S*/)?([\w-]+\.bash)(?=\s|$)"
RUN_PY = r"\bpython3\s+(?:-[XW]\s+\S+\s+|-\S+\s+)*(\S+\.py)(?=\s|$)"
RUN_PROG = r"\b(source/c/tests/[\w-]+\.(?:c|cpp)) -o\b"


def fStepFiles(step: str, files: set[str]) -> list[str]:
	out: list[str] = []
	for pattern, globs in SUITES:
		if not re.search(pattern, step):
			continue
		skip = [g[1:] for g in globs if g.startswith("!")]
		for glob in globs:
			if glob.startswith("!"):
				continue
			out += sorted(f for f in files if (f == glob or fnmatch.fnmatch(f, glob)) and not any(fnmatch.fnmatch(Path(f).name, k) for k in skip))
	for hit in re.finditer(RUN_SCRIPT, step):
		out.append(f"cicd/utility/{hit.group(1)}")
	for pattern in (RUN_PY, RUN_PROG):
		out += [hit.group(1) for hit in re.finditer(pattern, step)]
	for f in list(out):
		out += CALLS.get(f, [])
	return list(dict.fromkeys(f for f in out if f in files))


##	A suite step's own filter, so it lists only the tests it runs: cargo's
##	`--test`, `--lib` and `--bins`, libtest's `--skip`, `--exact` and name
##	filters, and go's `-run` and `-skip`. Each test is matched by its function
##	name, which libtest also matches by substring, inside its module path. The
##	corpus runs only when a test of its runner does. A test whose name can't be
##	found, and an ID TestMain prints, are kept, since no filter stops those.
CORPUS_RUNNERS = {"rust": "source/rust/tests/conformance.rs", "go": "source/go/shcl_test.go"}
CARGO_VALUED = {"--manifest-path", "-j", "--jobs", "-p", "--package", "--features", "-F", "--target", "--profile", "--test", "--bin", "--example", "--bench", "--target-dir", "--config", "--color", "--message-format", "-Z"}
LIBTEST_VALUED = {"--test-threads", "--logfile", "--color", "--format", "-Z", "--shuffle-seed"}
Keep = Callable[[str, "str | None"], bool]


def fWords(step: str) -> list[str]:
	try:
		lex = shlex.shlex(step, posix=True, punctuation_chars=True)
		lex.whitespace_split = True
		return list(lex)
	except ValueError:
		return step.split()


##	The words after `HEAD... SUB` up to the end of that command, or None.
def fArgsAfter(words: list[str], head: list[str], sub: str) -> list[str] | None:
	for i, w in enumerate(words):
		if w != head[0] or words[i + 1 : i + len(head)] != head[1:]:
			continue
		rest = words[i + len(head) :]
		while rest and rest[0] != sub and rest[0].startswith("-"):
			rest = rest[2:] if rest[0] in ("-C",) else rest[1:]
		if not rest or rest[0] != sub:
			continue
		out: list[str] = []
		for w2 in rest[1:]:
			if re.fullmatch(r"[;&|()]+", w2):
				break
			out.append(w2)
		return out
	return None


def fCargoKeep(args: list[str]) -> Keep:
	targets: set[str] = set()
	names: list[str] = []
	skips: list[str] = []
	exact = False
	after = False
	i = 0
	while i < len(args):
		w = args[i]
		flag, eq, val = w.partition("=")
		valued = LIBTEST_VALUED if after else CARGO_VALUED
		if w == "--" and not after:
			after = True
		elif flag in valued or flag == "--skip":
			if not eq:
				i += 1
				val = args[i] if i < len(args) else ""
			if flag == "--skip" and after:
				skips.append(val)
			elif flag == "--test" and not after:
				targets.add(f"source/rust/tests/{val}.rs")
			elif flag == "--bin" and not after:
				targets.add("source/rust/src/main.rs")
		elif w == "--lib" and not after:
			targets.add("source/rust/src/lib.rs")
		elif w == "--bins" and not after:
			targets.add("source/rust/src/main.rs")
		elif w == "--exact" and after:
			exact = True
		elif not w.startswith("-"):
			names.append(w)
		i += 1

	def hit(pattern: str, name: str) -> bool:
		return name == pattern if exact else pattern in name

	def keep(file: str, name: str | None) -> bool:
		if targets and file not in targets:
			return False
		if name is None:
			return True
		if names and not any(hit(n, name) for n in names):
			return False
		return not any(hit(k, name) for k in skips)

	return keep


def fGoKeep(args: list[str]) -> Keep:
	found: dict[str, str] = {}
	i = 0
	while i < len(args):
		flag, eq, val = args[i].lstrip("-").partition("=")
		if args[i].startswith("-") and flag in ("run", "skip"):
			if not eq:
				i += 1
				val = args[i] if i < len(args) else ""
			found[flag] = val
		i += 1
	pats: dict[str, re.Pattern[str]] = {}
	for flag, val in found.items():
		## Only the part a top-level test is matched by; past a `/` it's subtests.
		top = val.split("/")[0]
		if flag == "skip" and "/" in val:
			continue
		try:
			pats[flag] = re.compile(top)
		except re.error:
			continue

	def keep(file: str, name: str | None) -> bool:
		if name is None or name == "TestMain":
			return True
		if "run" in pats and not pats["run"].search(name):
			return False
		return not ("skip" in pats and pats["skip"].search(name))

	return keep


def fSuiteKeep(step: str) -> tuple[str, Keep] | None:
	words = fWords(step)
	args = fArgsAfter(words, ["cargo"], "test")
	if args is not None:
		return "rust", fCargoKeep(args)
	args = fArgsAfter(words, ["go"], "test")
	if args is not None:
		return "go", fGoKeep(args)
	return None


##	The test function an ID line sits in: the nearest `fn` or `func` above it.
NAME_AT = {".rs": re.compile(r"^\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)"), ".go": re.compile(r"^func\s+(\w+)\(")}
nameCache: dict[str, list[str]] = {}


def fTestName(file: str, line: int) -> str | None:
	pattern = NAME_AT.get(Path(file).suffix)
	if pattern is None:
		return None
	if file not in nameCache:
		nameCache[file] = (repo / file).read_text(encoding="utf-8").splitlines()
	for text in reversed(nameCache[file][: line - 1]):
		hit = pattern.match(text)
		if hit:
			return hit.group(1)
	return None


##	Reads the step list on stdin: a stage title at the left, a step under it
##	on a tab, and after a \x1f the command it runs when the label is not one.
##	Prints it back with each test ID the step runs under it, on two tabs.
def fList() -> int:
	found = fScan()[0]
	byFile: dict[str, list[tuple[str, str, int]]] = {}
	for tid, file, line in found:
		key = CORPUS if file.startswith(CORPUS + "/") else file
		byFile.setdefault(key, []).append((tid, file, line))
	out: list[str] = []
	for row in sys.stdin.read().splitlines():
		label, _, command = row.partition("\x1f")
		out.append(label)
		if not row.startswith("\t"):
			continue
		step = (command or label).strip()
		suite = fSuiteKeep(step)
		for file in fStepFiles(step, set(byFile)):
			if suite and file == CORPUS:
				runner = CORPUS_RUNNERS[suite[0]]
				names = [fTestName(runner, n) for _, _, n in byFile.get(runner, [])]
				if not any(suite[1](runner, name) for name in names if name not in (None, "TestMain")):
					continue
			for tid, where, n in byFile[file]:
				if suite and file != CORPUS and not suite[1](file, fTestName(file, n)):
					continue
				at = where if file == CORPUS else f"{where}:{n}"
				out.append(f"\t\t{tid}  {at}")
	print("\n".join(out))
	return 0


##	A marker in a comment is a test taken out, so it counts as none, as a
##	commented-out Rust or Go test does. Each line comes back with what a
##	comment hides blanked: a `#` line in Python, Bash and PowerShell, and a
##	`//` line or a `/* */` span in C and C++.
def fLiveLines(path: Path) -> list[str]:
	lines = path.read_text(encoding="utf-8").splitlines()
	if path.suffix not in (".c", ".cpp"):
		return ["" if line.lstrip().startswith("#") else line for line in lines]
	live: list[str] = []
	block = False
	for line in lines:
		text = ""
		while line:
			if block:
				end = line.find("*/")
				if end < 0:
					break
				line, block = line[end + 2 :], False
			else:
				start = line.find("/*")
				if start < 0:
					text += line
					break
				text, line, block = text + line[:start], line[start + 2 :], True
		live.append("" if text.lstrip().startswith("//") else text)
	return live


def fScan() -> tuple[list[tuple[str, str, int]], list[str]]:
	found: list[tuple[str, str, int]] = []
	bad: list[str] = []

	if not (repo / CORPUS).is_dir():
		bad.append(f"{CORPUS}: missing")
	for case in sorted((repo / CORPUS).glob("*")):
		if not case.is_dir():
			continue
		rel = f"project/conformance/{case.name}/test-id"
		try:
			tid = (case / "test-id").read_text(encoding="utf-8").strip()
		except FileNotFoundError:
			bad.append(f"{rel}: missing")
			continue
		if not re.fullmatch(ID, tid):
			bad.append(f"{rel}: not an ID: {tid!r}")
			continue
		found.append((tid, rel, 1))

	for glob, need, want, reach in NEED:
		for path in sorted(repo.glob(glob)):
			rel = str(path.relative_to(repo))
			lines = path.read_text(encoding="utf-8").splitlines()
			for n, line in enumerate(lines):
				if not re.match(need, line):
					continue
				## A Rust test's ID is the first line of its body, below the fn line.
				hit = None
				seen = 0
				for m in range(n + 1, len(lines)):
					if not lines[m].strip():
						continue
					seen += 1
					if seen == reach:
						hit = re.match(want, lines[m])
						break
					if lines[m].lstrip().startswith("#["):
						seen -= 1
				if hit is None:
					bad.append(f"{rel}:{n + 1}: a test with no ID line under it")
					continue
				found.append((hit.group(1), rel, m + 1))

	placed = {(str(p.relative_to(repo)), need) for glob, need, _, _ in NEED for p in repo.glob(glob)}
	tracked = subprocess.run(["git", "-C", str(repo), "ls-files", "-z"], capture_output=True, check=True).stdout.decode().split("\0")
	for glob, pattern in STRAY:
		for rel in sorted(t for t in tracked if fnmatch.fnmatch(Path(t).name, glob) and not t.startswith(STRAY_EXEMPT)):
			for n, line in enumerate((repo / rel).read_text(encoding="utf-8").splitlines()):
				if re.match(pattern, line) and not any(f == rel and re.match(need, line) for f, need in placed):
					bad.append(f"{rel}:{n + 1}: a test in a place the tables here do not know")

	for (glob, pattern), (_, old) in zip(COLLECT, OLD_COLLECT):
		for path in sorted(repo.glob(glob)):
			if path.name == Path(__file__).name:
				continue
			rel = str(path.relative_to(repo))
			for n, line in enumerate(fLiveLines(path)):
				for hit in re.finditer(pattern, line):
					found.append((hit.group(1), rel, n + 1))
				for hit in re.finditer(old, line):
					bad.append(f"{rel}:{n + 1}: an ID in the old base 62 form: {hit.group(1)}")

	for file, name in ROWS:
		if not (repo / file).is_file():
			bad.append(f"{file}: missing")
			continue
		lines = (repo / file).read_text(encoding="utf-8").splitlines()
		start = next((n for n, line in enumerate(lines) if line == f"{name}=("), None)
		if start is None:
			bad.append(f"{file}: no {name}=( array")
			continue
		for n in range(start + 1, len(lines)):
			line = lines[n]
			if line == ")":
				break
			if not line.lstrip().startswith(("'", '"')):
				continue
			hit = re.match(rf"""^\s*['"]({ID})\|""", line)
			if hit is None:
				bad.append(f"{file}:{n + 1}: a {name} row with no ID first")
				continue
			found.append((hit.group(1), file, n + 1))
	return found, bad


def fCheck() -> int:
	found, bad = fScan()
	soon = fNow() + 1440
	first: dict[str, str] = {}
	for tid, file, line in found:
		at = f"{file}:{line}"
		if tid in first:
			bad.append(f"{at}: ID {tid} is already used at {first[tid]}")
			continue
		first[tid] = at
		## Nothing here is older than the repo, and nothing is from the future,
		## less the day a run of new IDs on a busy minute can push ahead.
		if not 20 * 365 * 1440 < decode(tid) < soon:
			bad.append(f"{at}: ID {tid} stands for {fWhen(tid)}")
	for problem in bad:
		print(f"test-ids: {problem}", file=sys.stderr)
	if bad:
		print(f"test-ids: {len(bad)} problem(s). A new test takes its ID from `cicd/utility/test-ids.py new`.", file=sys.stderr)
		return 1
	print(f"test-ids: OK ({len(found)} tests)")
	return 0


##	Each test's name, as a backlog row is likely to give it: a corpus folder,
##	a script's test or row name, a runner's name string, or a Rust or Go test
##	function's name.
def fNames(found: list[tuple[str, str, int]]) -> dict[str, list[str]]:
	names: dict[str, list[str]] = {}
	cache: dict[str, list[str]] = {}
	for tid, file, n in found:
		if file.startswith(CORPUS + "/"):
			names.setdefault(file.split("/")[2], []).append(tid)
			continue
		if file not in cache:
			cache[file] = (repo / file).read_text(encoding="utf-8").splitlines()
		lines = cache[file]
		text = lines[n - 1]
		hit = re.search(rf"""(?:\b{tid}", "|\bfTest {tid} |--id {tid} "|-Id '{tid}' .*\s'|['"]{tid}\|)([^"'|\s][^"'|]*)""", text)
		if hit is None:
			for back in range(n - 2, max(n - 8, -1), -1):
				hit = re.match(r"^\s*(?:pub )?(?:fn|func) (\w+)\(", lines[back])
				if hit:
					break
		if hit:
			names.setdefault(hit.group(1).strip(), []).append(tid)
	return names


##	The closed items of a backlog, for `backlog`: each bug, feature or
##	enhancement closed as Done, and each checkmark item under a legacy Done heading. Gives the
##	line, the title, the Closed date and the text of its test row with that
##	row's sub-bullets. A legacy item with no row of its own takes the one of the
##	nearest item it sits in that has one, as check-docs `dd72g` does.
ROW = re.compile(r"^(\t*)- (?:Test case:|Test:|Pinned by\b:?|Pinned:)\s*(.*)$")


def fClosedItems(path: Path) -> tuple[list[tuple[int, str, str, str]], dict[str, str]]:
	lines = path.read_text(encoding="utf-8").split("\n")
	inside = template = False
	for i, line in enumerate(lines):
		if line.startswith("<!--"):
			inside = True
		if line.startswith("## "):
			template = line.rstrip() == "## Template"
		if inside or template:
			lines[i] = ""
		if "-->" in line:
			inside = False

	def depth(line: str) -> int:
		return len(line) - len(line.lstrip("\t"))

	def body(i: int) -> list[str]:
		out = []
		for line in lines[i + 1 :]:
			if line.startswith("#") or (line.strip() and depth(line) <= depth(lines[i])):
				break
			if line.strip():
				out.append(line)
		return out

	def testRow(rows: list[str], d: int) -> str | None:
		for k, line in enumerate(rows):
			m = ROW.match(line)
			if m and len(m.group(1)) == d + 1:
				text = [m.group(2)]
				for more in rows[k + 1 :]:
					if depth(more) <= d + 1:
						break
					text.append(more.strip())
				return " ".join(text)
		return None

	items: list[tuple[int, str, str, str]] = []
	byId: dict[str, str] = {}
	heading = ""
	legacy: dict[int, str | None] = {}
	for i, line in enumerate(lines):
		if line.startswith("#"):
			heading = line.lstrip("#").strip()
			continue
		if re.match(r"^- \S", line) and not line.startswith("- \u2705"):
			rows = body(i)
			field = {m.group(1): m.group(2) for m in (re.match(r"^\t- ([^:]+): (.*)$", r) for r in rows) if m}
			row = testRow(rows, 0)
			if "ID" in field and row is not None:
				byId[field["ID"]] = row
			fixed = field.get("Status") == "Done" or (field.get("Status") == "Closed" and field.get("Closed reason") == "Done")
			if fixed and field.get("Type") in ("Bug", "Feature", "Enhancement"):
				items.append((i + 1, line[2:], field.get("Closed", ""), row or ""))
			continue
		m = re.match(r"^(\t*)- \u2705 ", line)
		if m and heading.startswith("Done"):
			d = len(m.group(1))
			legacy[i] = testRow(body(i), d)
			row = legacy[i]
			up = d
			for j in range(i - 1, -1, -1):
				if row is not None or up == 0 or lines[j].startswith("#"):
					break
				if lines[j].strip() and depth(lines[j]) < up:
					up = depth(lines[j])
					row = legacy.get(j)
			closed = next((r.split(": ", 1)[1] for r in body(i) if r.startswith("\t" * (d + 1) + "- Closed: ")), "")
			items.append((i + 1, line.strip()[2:], closed, row or ""))
	return items, byId


##	A row passes when it names a test's ID, says why there is none by starting
##	with "none" or "no ", or names backlog items whose rows each pass, as a
##	parent naming its children does.
def fRowPasses(row: str, known: set[str], byId: dict[str, str], seen: frozenset[str] = frozenset()) -> bool:
	if any(w in known for w in re.findall(rf"\b{ID}\b", row)):
		return True
	if re.match(r"(?i)(none|no )", row.strip()):
		return True
	refs = [r for r in re.findall(r"\b\d{16}\b", row) if r not in seen]
	return bool(refs) and all(r in byId and fRowPasses(byId[r], known, byId, seen | {r}) for r in refs)


def fBacklog(path: Path, since: str) -> int:
	if not path.is_file():
		print(f"test-ids: {path}: missing", file=sys.stderr)
		return 2
	found = fScan()[0]
	known = {tid for tid, _, _ in found}
	names = fNames(found)
	items, byId = fClosedItems(path)
	gaps = 0
	for n, title, closed, row in items:
		day = re.sub(r"\D", "", closed)[:8]
		if since and not day >= since:
			continue
		if fRowPasses(row, known, byId):
			continue
		gaps += 1
		print(f"{path.name}:{n}: {title[:70]}")
		could: list[str] = []
		for word in re.findall(r"`([^`]+)`", row) + [f"{c}-*" for c in re.findall(r"\bcorpus (?:cases? )?(\d{3})\b", row)]:
			if len(word.replace("*", "")) < 4:
				continue
			for name in sorted(fnmatch.filter(names, word) if "*" in word else [word] if word in names else []):
				could += [f"{tid} ({name})" for tid in names[name]]
		if could:
			print(f"\tcould name: {', '.join(dict.fromkeys(could))}")
	if gaps:
		print(f"test-ids: {gaps} closed item(s) name no test ID and give no reason.", file=sys.stderr)
		return 1
	print(f"test-ids: OK ({len(items)} closed items)")
	return 0


def fNew(count: int) -> int:
	used = {tid for tid, _, _ in fScan()[0]}
	minute = fNow()
	while count:
		tid = encode(minute)
		minute += 1
		if tid in used:
			continue
		print(tid)
		count -= 1
	return 0


def main() -> int:
	args = sys.argv[1:]
	if not args or args[0] in ("-h", "--help"):
		for line in Path(__file__).read_text(encoding="utf-8").splitlines():
			if line.startswith("##\tHistory"):
				break
			if line.startswith("##"):
				print(line[2:].replace("\t", "", 1))
		return 0 if args else 2
	cmd, rest = args[0], args[1:]
	if cmd == "new" and len(rest) <= 1 and all(a.isdigit() and int(a) > 0 for a in rest):
		return fNew(int(rest[0]) if rest else 1)
	if cmd == "when" and rest and all(re.fullmatch(ID, a) for a in rest):
		for tid in rest:
			print(f"{tid}  {fWhen(tid)}")
		return 0
	if cmd == "find" and rest:
		found = fScan()[0]
		rc = 0
		for tid in rest:
			hits = [f"{file}:{line}" for t, file, line in found if t == tid]
			if not hits:
				print(f"{tid}  not found", file=sys.stderr)
				rc = 1
			for hit in hits:
				print(f"{tid}  {hit}")
		return rc
	if cmd == "check" and not rest:
		return fCheck()
	if cmd == "list" and not rest:
		return fList()
	if cmd == "backlog" and len(rest) <= 2:
		since = ""
		if rest and rest[0].startswith("--since="):
			since = rest.pop(0).split("=", 1)[1]
		if re.fullmatch(r"(\d{8})?", since) and len(rest) <= 1:
			return fBacklog(Path(rest[0]) if rest else repo / "project/backlog.md", since)
	print(f"test-ids: bad arguments: {' '.join(args)} (try --help)", file=sys.stderr)
	return 2


if __name__ == "__main__":
	sys.exit(main())


##	History:
##		2026-09-27  Created.
##		2026-10-16  A commented-out marker is no test.
##		2026-10-30  Crockford base 32 minutes, per the shared CICD rules. Every
##		            base 62 millisecond ID converted once, from its own time.
##		            `list`, for the test IDs `cicd.bash --list` prints.
##		2026-10-31  `backlog`, for closed items that name no test ID.
##		2026-11-23  `list` follows a suite step's own test filter.
