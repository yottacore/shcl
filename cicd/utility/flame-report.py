#!/usr/bin/env python3

##	Purpose: Summarize the newest shcl profiler flamegraph - self-time hot
##		spots, inclusive call buckets, and the caller chain of the top leaves -
##		by parsing the pprof/inferno SVG (its fg:w attribute = raw sample counts).
##		Runs two ways: plain (print the report, meant to run every cicd run) and
##		--check (print only when the newest flamegraph is newer than the one last
##		recorded in a local marker, then record it - meant for session startup so
##		a look is a no-op until there is something new to read).
##	History: At bottom of script.

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT


from __future__ import annotations

import argparse
import bisect
import html
import re
import sys
import time
from pathlib import Path
from typing import NoReturn

STEP      = 16.0            # flamegraph row height in the SVG, px, until fParse reads the real one off the rows
SELF_TOP  = 22             	# self-time leaders to list
INCL_TOP  = 14             	# inclusive-time buckets to list
CHAIN     = 4              	# leaves whose caller chain we walk up to the root
SEEN_FILE = ".flame-seen"  	# marker basename, kept in the profiling dir - outside the git repo

NAME_RE   = re.compile(r"flame_(\d{8}-\d{6})_\w+\.svg$")
FRAME_RE  = re.compile(r"<title>(.*?)</title><rect ([^>]*?)/>", re.S)
ATTR_RES  = {key: re.compile(re.escape(key) + r'="([\d.]+)"') for key in ("y", "fg:x", "fg:w")}
SAMPLES_RE = re.compile(r"\s*\(\d[\d,]* samples.*$")

Frame = tuple[str, float, float, float]   # (name, x, y, w) in raw samples


def fSkip(msg: str) -> NoReturn:
	##	2 = environmental skip (no dir / unparseable) - non-fatal, matches the
	##	cicd profiler stage which treats such things as a warning, not a failure.
	sys.stderr.write(f"flame-report: {msg}\n")
	sys.exit(2)


def fKept(path: Path) -> tuple[int, int] | None:
	##	The profiler writes what it kept beside the SVG, because the sampler
	##	drops a sample whose leaf is inside libc rather than truncating it and
	##	the graph itself has no trace of that. An older graph has no such
	##	file, and says nothing rather than guessing.
	##	Rotation retags the SVG and leaves the sidecar under its old role, so a
	##	missing one is looked for by the timestamp in the name.
	sidecar = Path(f"{path}.samples")
	m = NAME_RE.match(path.name)
	if not sidecar.is_file() and m:
		sidecar = next(iter(sorted(path.parent.glob(f"flame_{m.group(1)}_*.svg.samples"))), sidecar)
	try:
		got, want = sidecar.read_text().split()[:2]
		return int(got), int(want)
	except (OSError, ValueError):
		return None


def fAge(path: Path) -> str:
	##	How old the graph is, in whichever unit reads plainest. The name has a
	##	timestamp, but nobody reads a date as an age, and SEEN and NEW look the
	##	same whether the profile behind them is from this morning or a fortnight
	##	ago - and a stale one has been read as today's picture of the code.
	try:
		secs = max(0, int(time.time() - path.stat().st_mtime))
	except OSError:
		return "?"
	if secs < 5400:
		return f"{secs // 60}m"
	if secs < 172800:
		return f"{secs // 3600}h"
	return f"{secs // 86400}d"


def fNewest(pdir: Path) -> tuple[str, str] | None:
	##	Sort on the timestamp, NOT the role suffix: GFS rotation retags the role
	##	(frequent -> latest -> hour/day/...) as time passes, but the timestamp in
	##	the name is stable.
	best = None
	for entry in pdir.iterdir():
		m = NAME_RE.match(entry.name)
		if m and (best is None or m.group(1) > best[0]):
			best = (m.group(1), entry.name)
	return best


def fAttr(attrs: str, key: str) -> float | None:
	vm = ATTR_RES[key].search(attrs)
	return float(vm.group(1)) if vm else None


def fParse(path: Path) -> tuple[int, list[Frame]]:
	##	Skip rather than trust anything that is not a whole graph: a file cut
	##	off mid-write, or one whose rows are not where the row height says,
	##	still yields a sample count and some frames, and the report it gave
	##	summed to a fraction of the samples with the marker written. The row
	##	height comes off the rows themselves; the root and the self-time sum
	##	are the checks that a graph is all there.
	global STEP
	text = path.read_text(encoding="utf-8", errors="replace")
	m = re.search(r'total_samples="(\d+)"', text)
	total = int(m.group(1)) if m else 0
	frames: list[Frame] = []
	for fm in FRAME_RE.finditer(text):
		attrs = fm.group(2)
		y, x, w = fAttr(attrs, "y"), fAttr(attrs, "fg:x"), fAttr(attrs, "fg:w")
		if y is None or x is None or w is None:
			continue
		name = SAMPLES_RE.sub("", html.unescape(fm.group(1)))
		frames.append((name, x, y, w))
	if not total or not frames:
		fSkip(f"could not parse a flamegraph out of {path}")
	if not text.rstrip().endswith("</svg>"):
		fSkip(f"{path} does not end in </svg>; cut off mid-write")
	ys = sorted({fr[2] for fr in frames})
	gaps = {round(b - a, 6) for a, b in zip(ys, ys[1:])}
	if len(gaps) > 1:
		fSkip(f"rows are not evenly spaced in {path} (gaps {sorted(gaps)}); not a whole flamegraph")
	if gaps:
		STEP = gaps.pop()
	roots = [fr for fr in frames if fr[2] == ys[-1]]
	if len(roots) != 1 or abs(roots[0][3] - total) > 1e-6:
		fSkip(f"no single root frame spanning all {total} samples in {path}; not a whole flamegraph")
	return total, frames


def fAnalyze(total: int, frames: list[Frame], top: int) -> None:
	##	Rows keyed by y and sorted by x, with the x list beside each, so a
	##	frame's parent or children are a bisect and a short walk rather than a
	##	scan of the whole row for every frame.
	rows: dict[float, list[Frame]] = {}
	for fr in frames:
		rows.setdefault(fr[2], []).append(fr)
	rowXs: dict[float, list[float]] = {}
	for y, row in rows.items():
		row.sort(key=lambda fr: fr[1])
		rowXs[y] = [fr[1] for fr in row]
	eps = 1e-6

	def kids(fr: Frame) -> list[Frame]:
		_, x, y, w = fr
		row = rows.get(y - STEP)
		if not row:
			return []
		out = []
		for c in row[bisect.bisect_left(rowXs[y - STEP], x - eps):]:
			if c[1] + c[3] > x + w + eps:
				break
			out.append(c)
		return out

	def parent(fr: Frame) -> Frame | None:
		_, x, y, w = fr
		row = rows.get(y + STEP)
		if not row:
			return None
		i = bisect.bisect_right(rowXs[y + STEP], x + eps) - 1
		if i >= 0 and row[i][1] + row[i][3] >= x + w - eps:
			return row[i]
		return None

	selfOf = {fr: fr[3] - sum(c[3] for c in kids(fr)) for fr in frames}
	if abs(sum(selfOf.values()) - total) > 1 or min(selfOf.values()) < -1e-6:
		fSkip(f"self time sums to {sum(selfOf.values()):.0f} of {total} samples; frames are missing or misplaced, not a whole flamegraph")

	selfBy: dict[str, float] = {}
	inclBy: dict[str, float] = {}
	byName: dict[str, list[Frame]] = {}
	parse = emit = reads = other = 0.0
	for fr in frames:
		name = fr[0]
		byName.setdefault(name, []).append(fr)
		##	Once per stack: a recursive call, or one name inlined at two depths,
		##	sits inside itself and would be counted again.
		up = parent(fr)
		while up and up[0] != name:
			up = parent(up)
		if not up:
			inclBy[name] = inclBy.get(name, 0.0) + fr[3]
		s = selfOf[fr]
		selfBy[name] = selfBy.get(name, 0.0) + s
		if s <= 0:
			continue
		anc: list[str] = []                          # ancestor names (self up to root)
		cur: Frame | None = fr
		while cur:
			anc.append(cur[0])
			cur = parent(cur)
		##	Buckets keyed to shcl's hot subsystems (the cicd workload is `fmt`, so
		##	parse + emit dominate; reads shows up if the workload ever adds gets).
		##	The docs gate checks every name below against the reference: the lookup
		##	scanner was renamed once and its whole bucket moved into `other` with
		##	nothing saying so.
		if any("Parser::parse" in a or "Document::parse" in a for a in anc):
			parse += s
		elif any("to_canonical" in a or "emit_node" in a for a in anc):
			emit += s
		elif any("scan_lookup" in a or "::read_" in a for a in anc):
			reads += s
		else:
			other += s

	def pct(v: float) -> str:
		return f"{v / total * 100:5.1f}%"

	print("attribution (self-time):")
	print(f"  parse (tokenize/merge/diags) .: {pct(parse)}")
	print(f"  emit (canonical formatter) ...: {pct(emit)}")
	print(f"  reads (lookup/coercion) ......: {pct(reads)}")
	print(f"  other ........................: {pct(other)}")
	print()

	print("top self-time (where CPU actually burns):")
	for name, v in sorted(selfBy.items(), key=lambda kv: -kv[1])[:top]:
		if v < 1:
			break
		print(f"  {pct(v)} {int(v):4d}  {name}")
	print()

	print("top inclusive (call buckets):")
	for name, v in sorted(inclBy.items(), key=lambda kv: -kv[1])[:INCL_TOP]:
		print(f"  {pct(v)} {int(v):4d}  {name}")
	print()

	print(f"caller chains of the top {CHAIN} leaves:")
	for name, v in sorted(selfBy.items(), key=lambda kv: -kv[1])[:CHAIN]:
		fr = max(byName[name], key=selfOf.__getitem__)
		print(f"  {name}  ({pct(v)} self)")
		cur, depth = parent(fr), 0
		while cur and depth < 12:
			print(f"      {cur[0]}")
			if cur[0] == "all":
				break
			cur, depth = parent(cur), depth + 1


def main() -> None:
	default_dir = Path(__file__).absolute().parent.parent / "artifacts" / "profiling"

	ap = argparse.ArgumentParser(description="Summarize the newest shcl profiler flamegraph.")
	ap.add_argument("--dir", default=default_dir, type=Path, help="profiling directory (default: %(default)s)")
	ap.add_argument("--file", help="analyze this SVG instead of the newest in --dir")
	ap.add_argument("--top", type=int, default=SELF_TOP, help="self-time leaders to list")
	ap.add_argument("--check", action="store_true",
	                help="startup gate: print only if newer than the local marker, then record it")
	ap.add_argument("--force", action="store_true", help="with --check, report even if already seen")
	ap.add_argument("--no-mark", action="store_true", help="with --check, do not update the marker")
	a = ap.parse_args()

	if a.file:
		path = Path(a.file)
		if not path.is_file():
			fSkip(f"no such file: {path}")
		name = path.name
		m = NAME_RE.match(name)
		ts = m.group(1) if m else ""
	else:
		if not a.dir.is_dir():
			fSkip(f"no profiling dir: {a.dir}")
		nb = fNewest(a.dir)
		if not nb:
			fSkip(f"no flamegraphs in {a.dir}")
		ts, name = nb
		path = a.dir / name

	##	SEEN only when the marker names the newest graph exactly, and --file never
	##	moves it: a marker ahead of every graph used to silence the gate for good.
	marker = a.dir / SEEN_FILE
	if a.check and not a.force and not a.file:
		seen = ""
		try:
			seen = marker.read_text().strip()
		except OSError:
			pass
		if ts and ts == seen:
			print(f"SEEN {name}  (nothing newer than {seen}, {fAge(path)} old)")
			return

	total, frames = fParse(path)
	print(f"{'NEW' if a.check else 'FLAME'} {name}  ({ts or 'n/a'}, {total} samples, {fAge(path)} old)")
	kept = fKept(path)
	if kept:
		got, want = kept
		share = 100.0 * got / want if want else 0.0
		print(f"  {got} of about {want} samples reached the graph ({share:.0f}%); the rest had a leaf")
		print("  inside libc and were dropped, so allocation, copying and write time are not here")
		print("  and every percentage below is a share of what survived")
	print()
	fAnalyze(total, frames, a.top)

	if a.check and not a.no_mark and not a.file and ts:
		try:
			marker.write_text(ts + "\n")
		except OSError as e:
			sys.stderr.write(f"flame-report: could not write marker: {e}\n")


if __name__ == "__main__":
	main()


##	History:
##		- 20260712: Created from the SilkTerm sibling; attribution buckets redone for shcl (parse / emit / reads).
##		- 20260829: Regexes compiled once; rows indexed and bisected instead of scanned per frame.
##		- 2026-09-02 JC: A truncated or reshaped graph skips at exit 2 instead of
##		  reporting a fraction of it; the row height is read off the rows.
##		- 20260914: The marker moves only on the newest graph, and SEEN needs an
##		  exact match. A sidecar left under an old role is found by timestamp.
##		- 20260922: A name inside itself on one stack counts once in the inclusive list.
