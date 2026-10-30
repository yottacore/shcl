#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

# Load, read, set, save, merge and validate over every corpus file, round
# after round, under tracemalloc. Round N to 2N is what's judged, since the
# first rounds fill the regex cache and intern strings. Run it as the gate
# does, with -X dev -W error::ResourceWarning.

import tracemalloc

# Before shcl is imported, so a module global it grows is traced to its line.
tracemalloc.start()

import gc  # noqa: E402
import os  # noqa: E402
import sys  # noqa: E402
import tempfile  # noqa: E402
from typing import Any  # noqa: E402

_HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))
import shcl  # noqa: E402

_REPO = os.path.dirname(os.path.dirname(os.path.dirname(_HERE)))
CORPUS = os.path.join(_REPO, "project", "conformance")
ARTIFACT = os.path.join(_REPO, "cicd", "artifacts", "soak", "python-tracemalloc.txt")

# The interned-name table grows once, about 400 KB, near round 5 here, which
# is why N isn't 3. Measured at 6: N and 2N under 8 KB apart. Keeping each
# document's path list grows it about 270 KB.
ROUNDS = 6
MARGIN = 64 << 10

FAILS: list[str] = []
_open: dict[str, str] = {}


def test_id(tid: str, name: str) -> None:
	_open.update(tid=tid, name=name)


def test_id_end(status: str) -> None:
	if _open:
		print(f"{status:<4} {_open['tid']} python {_open['name']}", flush=True)
		_open.clear()


# A ResourceWarning goes off in a destructor, where no exception can get out,
# so -W error alone only prints it.
def _unraisable(u: Any) -> None:
	FAILS.append(f"unraisable in {u.object!r}: {u.exc_type.__name__}: {u.exc_value}")
	sys.__unraisablehook__(u)


def soak_cases() -> list[tuple[str, str, str]]:
	cases = []
	for name in sorted(os.listdir(CORPUS)):
		d = os.path.join(CORPUS, name)
		if not os.path.isdir(d):
			continue
		schema, layer = os.path.join(d, "schema.shcl"), os.path.join(d, "layer1.shcl")
		cases.append((os.path.join(d, "input.shcl"), schema if os.path.exists(schema) else "", layer if os.path.exists(layer) else ""))
	return cases


def soak_round(r: int, cases: list[tuple[str, str, str]], save_to: str, counts: dict[str, int]) -> None:
	for inp, schema_path, layer in cases:
		doc, st = shcl.Document.load_file(inp)
		if st not in (shcl.FileStatus.Clean, shcl.FileStatus.HadErrors):
			raise SystemExit(f"{inp}: load {st}")
		for p in doc.paths():
			doc.read_string(p)
		doc.set_int("soak.round", r)
		doc.set_string("soak.case", f"{r} {inp}")
		# The case naming a newer format saves nowhere (SaveTooNew).
		try:
			doc.save_file_lossy(save_to)
		except (shcl.SaveFailed, shcl.SaveTooNew):
			pass
		else:
			counts["saved"] += 1
			doc.merge(shcl.Document.load_file(save_to)[0])
		if layer:
			doc.merge(shcl.Document.load_file(layer)[0])
		if schema_path:
			doc.validate(shcl.Document.load_file(schema_path)[0])
			counts["validated"] += 1


def soak_snapshot() -> tracemalloc.Snapshot:
	gc.collect()
	return tracemalloc.take_snapshot().filter_traces((
		tracemalloc.Filter(False, tracemalloc.__file__),
		tracemalloc.Filter(False, "<frozen importlib._bootstrap>"),
		tracemalloc.Filter(False, "<frozen importlib._bootstrap_external>"),
	))


def main() -> int:
	sys.unraisablehook = _unraisable
	# The clock every runner pins, as conformance.py does.
	os.environ["SHCL_TEST_CLOCK"] = "2026-10-04 00:15:00 -420 PDT"
	test_id("Et01jhM", "soak_heap_settles")
	cases = soak_cases()
	counts = {"saved": 0, "validated": 0}
	snaps = []
	with tempfile.TemporaryDirectory() as td:
		save_to = os.path.join(td, "soak.shcl")
		for r in range(1, 2 * ROUNDS + 1):
			soak_round(r, cases, save_to, counts)
			if r == 1:
				# From round 2 every cycle the collector finds goes to
				# gc.garbage instead of being freed. Since 3.4 it frees a cycle
				# with __del__ too, so without this only a C type with tp_del
				# would ever land there. Round 1 is left out, since it imports
				# what the library imports late, and ctypes leaves a class of
				# its own in a cycle as it loads on windows.
				gc.collect()
				gc.set_debug(gc.DEBUG_SAVEALL)
			if r % ROUNDS == 0:
				snaps.append(soak_snapshot())
	gc.set_debug(0)
	if counts["saved"] == 0 or counts["validated"] == 0:
		FAILS.append(f"the loop saved {counts['saved']} and validated {counts['validated']} times")
	sizes = [sum(s.size for s in snap.statistics("filename")) for snap in snaps]
	top = snaps[1].compare_to(snaps[0], "lineno")[:25]
	os.makedirs(os.path.dirname(ARTIFACT), exist_ok=True)
	with open(ARTIFACT, "w", encoding="utf-8") as f:
		f.write(f"traced at round {ROUNDS}: {sizes[0]}, at {2 * ROUNDS}: {sizes[1]}\n")
		f.writelines(f"{s}\n" for s in top)
	if sizes[1] > sizes[0] + MARGIN:
		FAILS.append(f"traced memory grew from {sizes[0]} at round {ROUNDS} to {sizes[1]} at round {2 * ROUNDS}, past the {MARGIN} margin; top lines in {ARTIFACT}")
	if gc.garbage:
		FAILS.append(f"{len(gc.garbage)} object(s) in reference cycles, such as {gc.garbage[:3]!r}")
		gc.garbage.clear()
	for f in FAILS:
		sys.stderr.write(f"FAIL {f}\n")
	return 1 if FAILS else 0


if __name__ == "__main__":
	try:
		rc = main()
	except BaseException:
		test_id_end("FAIL")
		raise
	test_id_end("FAIL" if rc else "ok")
	sys.exit(rc)
