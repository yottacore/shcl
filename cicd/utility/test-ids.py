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
##	Exit: 0 = clean, 1 = a check failed, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


from __future__ import annotations

import fnmatch
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

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
		for file in fStepFiles((command or label).strip(), set(byFile)):
			for tid, where, n in byFile[file]:
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
