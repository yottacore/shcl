#!/usr/bin/env python3

##	Purpose: The comparing half of check-formats.bash.
##
##		For each format, every corpus input under CORPUS and --corpus and every
##		document in --dump is taken with its stamp lines out. A document counts
##		when the format's own CLI loads it clean. The current CLI's `upgrade
##		--from=FORMAT` converts it, and the two readings have to match: the
##		paths in order, the instance count at each, and each instance's string
##		array and raw body, with exit codes. 1.0 to 2.0 have no `paths`
##		command, so their side is asked the paths of the converted file and of
##		the original under the current rules, and a path with a quoted name is
##		left out on both sides. An element holding a line break is printed as
##		it is by the old CLIs, over several lines, or with backslash escapes by
##		3.0-1f8 to 3.0-a37, so it is spelled again by the current CLI through
##		`--set`, which takes the text as data.
##
##		A refusal at exit 7 is how a step reports a line it isn't sure of, so a
##		refused document is counted and shown but doesn't fail the format. A
##		format fails on a reading that differs, other than one KNOWN names, or
##		with fewer than --min documents compared. Prints a summary and the
##		first --show mismatches and refusals of each format, then a PASS or
##		FAIL line per format with its test ID.
##	Syntax: check-format-reads.py --new CLI --corpus DIR --dump DIR [--jobs N]
##		[--min N] [--show N] FORMAT|CLI|CORPUS...
##	Exit: 0 = every format passes, 1 = a format fails, 2 = usage.
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


import argparse
import concurrent.futures as cf
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import threading

STAMP = re.compile(rb"^[ \t]*##[ \t]+(SHCL[ \t]+format|Format)\b", re.I)
STATUS = re.compile(r"^(Good|Empty|NotFound|BadType|Multiple)\t")
QUOTED = re.compile("[\"'\u25c9\\\\]")


##	One test per format, and the formats it can be asked for.
def test_id(tid: str, name: str) -> tuple[str, str]:
	return tid, name


TESTS = {
	"1.0": test_id("dfjac", "format-1.0-round-trips-against-v1.0.0"),
	"1.1": test_id("dfjad", "format-1.1-round-trips-against-v1.1.0"),
	"2.0": test_id("dfjae", "format-2.0-round-trips-against-v2.0.0"),
	"3.0-1f8": test_id("dfjaf", "format-3.0-1f8-round-trips-against-its-pin"),
	"3.0-30d": test_id("dfjag", "format-3.0-30d-round-trips-against-its-pin"),
	"3.0-b10": test_id("dfjah", "format-3.0-b10-round-trips-against-its-pin"),
	"3.0-f8e": test_id("dfjaj", "format-3.0-f8e-round-trips-against-its-pin"),
	"3.0-a37": test_id("dfjak", "format-3.0-a37-round-trips-against-its-pin"),
	"3.0-9ef": test_id("dfjam", "format-3.0-9ef-round-trips-against-its-pin"),
	"3.0-a65": test_id("dfjan", "format-3.0-a65-round-trips-against-its-pin"),
	"3.0": test_id("dfjap", "format-3.0-round-trips-against-v3.0.0-beta1"),
}
##	Readings that differ by decision, by format and corpus case. The step out
##	of 1.0 reads 2 instances that a late block closes onto as 1.1 does, since
##	no text tells such a file apart (the design doc's Reading and converting).
KNOWN = {
	("1.0", "141-nested-late-fold"),
}
BREAKS = re.compile("[\n\v\f\r\x1c\x1d\x1e\x85\u2028\u2029]")


def run(cli: str, args: list[str]) -> tuple[int, str]:
	"""Exit code and stdout. A NUL can't ride an argument, so that read is -2."""
	if any("\0" in x for x in args):
		return -2, ""
	try:
		p = subprocess.run([cli, *args], capture_output=True, timeout=20, stdin=subprocess.DEVNULL)
		return p.returncode, p.stdout.decode("utf-8", "surrogateescape")
	except subprocess.TimeoutExpired:
		return -1, "timeout"


class Cli:
	"""What one CLI can be asked, found by probing it once."""

	def __init__(self, path: str, tmp: str) -> None:
		self.path = path
		probe = os.path.join(tmp, "probe-" + hashlib.sha1(path.encode()).hexdigest()[:8] + ".shcl")
		with open(probe, "w") as f:
			f.write("a: 1\n")
		self.paths = run(path, ["paths", probe])[0] == 0
		self.dashdash = run(path, ["count", probe, "--", "a"])[0] == 0
		self.paren = run(path, ["get", probe, "a(0)"])[0] == 0
		with open(probe, "w") as f:
			f.write('a: "x\\ny"\n')
		self.backslash = run(path, ["get", "--array", "--slots", probe, "a"])[1] == 'Good\t"x\\ny"\n'

	def ask(self, cmd: list[str], doc: str, path: str) -> tuple[int, str]:
		return run(self.path, [*cmd, doc, *(["--"] if self.dashdash else []), path])

	def instance(self, path: str, i: int) -> str:
		return f"{path}({i})" if self.paren else f"{path}[#{i}]"


PAIRS = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "0": "\0"}


def unescape(text: str) -> str:
	"""A value as 3.0-1f8 to 3.0-a37 print one in double quotes."""
	def one(m: re.Match[str]) -> str:
		code = m.group(1) or m.group(2)
		if code:
			return chr(int(code, 16))
		return PAIRS.get(m.group(3), m.group(0))
	return re.sub(r"\\(?:u([0-9A-Fa-f]{4})|U([0-9A-Fa-f]{8})|(.))", one, text[1:-1])


def elements(out: str, new: str, respell: bool, backslash: bool = False) -> list[str]:
	"""Each element as `STATUS<tab>TEXT`, a multi-line one put back together."""
	got: list[list[str]] = []
	for ln in out.removesuffix("\n").split("\n") if out else []:
		if STATUS.match(ln) or not got:
			got.append([ln])
		else:
			got[-1].append(ln)
	res = []
	for parts in got:
		el = "\n".join(parts)
		status, _, text = el.partition("\t")
		if backslash and len(text) > 1 and text[0] == text[-1] == '"' and "\\" in text:
			plain = unescape(text)
			if re.search("[\x00-\x08\x0a-\x1f\x7f\x85\u2028\u2029]", plain):
				text = plain
		if respell and BREAKS.search(text):
			_, again = run(new, ["get", "--string", "--array", "--slots", "--set", "v=" + text, "-", "v"])
			text = again.rstrip("\n").partition("\t")[2]
		res.append(status + "\t" + text)
	return res


def reads(cli: Cli, doc: str, paths: list[str], new: str, old: bool) -> list[object]:
	"""Each path, as `~` when the 2 CLIs would spell its name differently."""
	got: list[object] = []
	for p in paths:
		got.append("~" if QUOTED.search(p) else p)
		rc, n = cli.ask(["count"], doc, p)
		got.append(("count", rc, n.strip()))
		if rc != 0 or not n.strip().isdigit():
			continue
		for i in range(int(n)):
			q = cli.instance(p, i)
			rc, arr = cli.ask(["get", "--string", "--array", "--slots"], doc, q)
			got.append(("array", rc, elements(arr, new, old, old and cli.backslash)))
			rc, raw = cli.ask(["get", "--raw"], doc, q)
			## The old CLIs print an empty line for a read that failed, other
			## than an empty value; the current one prints nothing (2026110217340702).
			if old and rc not in (0, 2):
				raw = ""
			got.append(("raw", rc, raw))
	return got


def old_paths(*lists: list[str]) -> list[str]:
	"""The paths 1.0 to 2.0 are asked, all spelled alike in every format."""
	return list(dict.fromkeys(p for got in lists for p in got if not QUOTED.search(p)))


def paths(cli: str, doc: str) -> list[str]:
	rc, out = run(cli, ["paths", doc])
	return [p for p in out.split("\n") if p] if rc == 0 else []


class Tally:
	def __init__(self) -> None:
		self.lock = threading.Lock()
		self.n = {"compared": 0, "same": 0, "differ": 0, "known": 0, "refused": 0, "unclean": 0}
		self.shown: list[str] = []


def one(fmt: str, old: Cli, new: Cli, src: str, data: bytes, tmp: str, tally: Tally, show: int) -> None:
	with tempfile.TemporaryDirectory(dir=tmp) as d:
		f = os.path.join(d, "f.shcl")
		g = os.path.join(d, "g.shcl")
		with open(f, "wb") as h:
			h.write(data)
		if run(old.path, ["check", f])[0] != 0:
			with tally.lock:
				tally.n["unclean"] += 1
			return
		rc, made = run(new.path, ["upgrade", "--from=" + fmt, f])
		if rc != 0:
			with tally.lock:
				tally.n["compared"] += 1
				tally.n["refused"] += 1
				if len(tally.shown) < show:
					tally.shown.append(f"-- {fmt} {src}: upgrade --from={fmt} exit {rc}")
			return
		with open(g, "w", encoding="utf-8", errors="surrogateescape") as h:
			h.write(made)
		new_paths = paths(new.path, g)
		if old.paths:
			paths_old, paths_new = paths(old.path, f), new_paths
		else:
			## A path the conversion dropped is missing from its file, so the
			## original's paths under the current rules are asked too.
			paths_old = paths_new = old_paths(new_paths, paths(new.path, f))
		a = [len(paths_old), *reads(old, f, paths_old, new.path, True)]
		b = [len(paths_new), *reads(new, g, paths_new, new.path, False)]
		with tally.lock:
			tally.n["compared"] += 1
			if a == b:
				tally.n["same"] += 1
				return
			if (fmt, src.split("/")[0]) in KNOWN:
				tally.n["known"] += 1
				return
			tally.n["differ"] += 1
			if len(tally.shown) < show:
				at = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
				x = a[at] if at < len(a) else "(none)"
				y = b[at] if at < len(b) else "(none)"
				tally.shown.append(f"-- {fmt} {src}: read {at} differs\n   {fmt}: {x!r}\n   now: {y!r}\n-- in\n"
					+ data.decode("utf-8", "replace") + "\n-- out\n" + made)


def docs(dirs: list[str], dump: str) -> list[tuple[str, bytes]]:
	found = []
	for d in dirs:
		for top, _, names in os.walk(d):
			if "input.shcl" in names:
				found.append(os.path.join(top, "input.shcl"))
	found += sorted(os.path.join(dump, n) for n in os.listdir(dump) if n.endswith(".shcl"))
	seen, out = set(), []
	for path in found:
		with open(path, "rb") as h:
			data = b"\n".join(ln for ln in h.read().split(b"\n") if not STAMP.match(ln))
		key = hashlib.sha256(data).digest()
		if key not in seen:
			seen.add(key)
			out.append((os.path.relpath(path, os.path.dirname(os.path.dirname(path))), data))
	return out


def main() -> int:
	ap = argparse.ArgumentParser()
	ap.add_argument("--new", required=True)
	ap.add_argument("--corpus", required=True)
	ap.add_argument("--dump", required=True)
	ap.add_argument("--jobs", type=int, default=1)
	ap.add_argument("--min", type=int, default=40)
	ap.add_argument("--show", type=int, default=3)
	ap.add_argument("specs", nargs="+")
	a = ap.parse_args()
	failed = 0
	with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as tmp:
		new = Cli(a.new, tmp)
		if not new.paths or not new.paren:
			print(f"check-format-reads: {a.new} is not a current CLI", file=sys.stderr)
			return 2
		for spec in a.specs:
			fmt, cli, own = spec.split("|", 2)
			if fmt not in TESTS:
				print(f"check-format-reads: no test for format {fmt}", file=sys.stderr)
				return 2
			tid, name = TESTS[fmt]
			old = Cli(cli, tmp)
			tally = Tally()
			work = docs([own, a.corpus], a.dump)
			with cf.ThreadPoolExecutor(max(1, a.jobs)) as ex:
				for fut in [ex.submit(one, fmt, old, new, src, data, tmp, tally, a.show) for src, data in work]:
					fut.result()
			n = tally.n
			ok = n["differ"] == 0 and n["compared"] >= a.min
			failed += not ok
			print(f"check-formats: {fmt}: compared {n['compared']} (same {n['same']}, differ {n['differ']},"
				f" known {n['known']}, refused {n['refused']}), not clean under {fmt} {n['unclean']}")
			for line in tally.shown:
				print(line)
			if n["compared"] < a.min:
				print(f"-- {fmt}: fewer than {a.min} documents compared")
			print(f"{'PASS' if ok else 'FAIL':<4} {tid} check-formats {name}")
			sys.stdout.flush()
	return 1 if failed else 0


if __name__ == "__main__":
	sys.exit(main())


##	History:
##		2026-11-20  Created: each published format and pin round-trips
##		            against its own CLI (2026111907080466).
