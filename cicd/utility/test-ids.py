#!/usr/bin/env python3

##	Purpose: Test IDs. Every test the pipeline runs carries one, and prints it
##		on its status line. An ID is the test's creation time in milliseconds
##		since 2000-01-01 00:00 UTC, in base 62 (0-9, A-Z, a-z), padded to seven
##		characters, so IDs sort by age.
##	Syntax:
##		test-ids.py new [COUNT]   print COUNT fresh IDs (default 1)
##		test-ids.py when ID ...   print the time each ID stands for
##		test-ids.py find ID ...   print where each ID is defined
##		test-ids.py check         every test has an ID, and no two share one
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

DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
EPOCH_2000 = 946684800
WIDTH = 7
ID = r"[0-9A-Za-z]{7}"
repo = Path(__file__).resolve().parents[2]


def encode(ms: int) -> str:
	out = ""
	while ms:
		ms, digit = divmod(ms, 62)
		out = DIGITS[digit] + out
	return out.rjust(WIDTH, "0")


def decode(tid: str) -> int:
	ms = 0
	for ch in tid:
		ms = ms * 62 + DIGITS.index(ch)
	return ms


def fWhen(tid: str) -> str:
	secs, ms = divmod(decode(tid), 1000)
	stamp = datetime.fromtimestamp(EPOCH_2000 + secs, tz=timezone.utc)
	return stamp.strftime("%Y-%m-%d %H:%M:%S.") + f"{ms:03d} UTC"


##	Where tests are defined. A "need" pattern finds each test, and the ID
##	pattern has to match on the line it names (0 = the same line, 1 = the next
##	non-blank one). The rest only collect IDs, since a marker is the test there:
##	a failure before the first marker is the runner's to refuse.
NEED: list[tuple[str, str, str, int]] = [
	("source/rust/tests/*.rs", r"^\s*#\[test\]$", rf'^\s*let _id = test_id\("({ID})"\);$', 2),
	("source/rust/src/lib.rs", r"^\s*#\[test\]$", rf'^\s*let _id = test_id\("({ID})"\);$', 2),
	("source/go/*_test.go", r"^func Test\w+\(t \*testing\.T\) \{$", rf'^\tdefer testID\(t, "({ID})"\)$', 1),
]
COLLECT: list[tuple[str, str]] = [
	("source/python/tests/*.py", rf'\btest_id\("({ID})", "[^"]+"\)'),
	("source/c/tests/*.c", rf'\btest_id\("({ID})", "[^"]+"\)'),
	("source/c/tests/*.cpp", rf'\btest_id\("({ID})", "[^"]+"\)'),
	("cicd/utility/*.bash", rf"\bfTest ({ID}) \S"),
	("cicd/utility/*.py", rf'\btest_id\("({ID})", "[^"]+"\)'),
	("cicd/utility/win-runners.bash", rf"\bfRun --id ({ID}) "),
	("cicd/utility/*.ps1", rf"\bTest-Check -Id '({ID})' "),
	("cicd/config.bash", rf"^PROFILE_CHECK_ID=({ID})$"),
]
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
	("cicd/utility/perf-gate.bash", "workloads"),
]


def fScan() -> tuple[list[tuple[str, str, int]], list[str]]:
	found: list[tuple[str, str, int]] = []
	bad: list[str] = []

	for case in sorted((repo / "project/conformance").iterdir()):
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

	for glob, pattern in COLLECT:
		for path in sorted(repo.glob(glob)):
			if path.name == Path(__file__).name:
				continue
			rel = str(path.relative_to(repo))
			for n, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
				for hit in re.finditer(pattern, line):
					found.append((hit.group(1), rel, n + 1))

	for file, name in ROWS:
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
	now = (time.time() - EPOCH_2000) * 1000 + 86400000
	first: dict[str, str] = {}
	for tid, file, line in found:
		at = f"{file}:{line}"
		if tid in first:
			bad.append(f"{at}: ID {tid} is already used at {first[tid]}")
			continue
		first[tid] = at
		## Nothing here is older than the repo, and nothing is from the future.
		if not 20 * 365 * 86400000 < decode(tid) < now:
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
	ms = int((time.time() - EPOCH_2000) * 1000)
	while count:
		tid = encode(ms)
		ms += 1
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
	print(f"test-ids: bad arguments: {' '.join(args)} (try --help)", file=sys.stderr)
	return 2


if __name__ == "__main__":
	sys.exit(main())


##	History:
##		2026-09-27  Created.
