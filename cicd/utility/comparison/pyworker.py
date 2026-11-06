#!/usr/bin/env python3

"""Python half of the format comparison.

Speaks the same key=value worker protocol the Rust half does, so the orchestrator
does not care which language a measurement came from: one process per
measurement, best of N runs, and peak resident memory read from the kernel's own
high-water mark.

Its job is to answer the question the Rust tier cannot: how much of SHCL's cost
is the format and how much is one implementation of it. So the libraries here are
the ones a Python program would really import - the standard library first, and
whatever the ecosystem reached for where the standard library has no answer.

Most of what Python reaches for is a C extension wearing a Python name - json,
ElementTree and PyYAML's CSafeLoader all are - while this project's own binding
is pure Python by design. So the row worth reading here is tomllib, which is also
pure Python: that pair is the only like-for-like comparison in the tier, and the
notes on each entry say which side it is on.

Anything not installed is reported as unavailable rather than failing the run;
the orchestrator lists what it skipped.
"""

##	Copyright (c) 2026 Bubbles
##	Licensed under The MIT License (MIT). Full text at:
##		https://mit-license.org/
##	SPDX-License-Identifier: MIT

from __future__ import annotations

import sys
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any, Optional

REPO_PY = Path(__file__).absolute().parents[3] / "source" / "python"

# What a loader hands back: (version, parse, emit), optionally a fourth element
# that turns the file's text into whatever its parser wants, and optionally a
# fifth that reads the parsed document and returns why it is not whole - emit
# None when the library cannot write. Optional[] rather than | None: this alias
# is evaluated at import.
Loader = tuple[str, Callable[[Any], Any], Optional[Callable[[Any], str]]]
LoaderPrep = tuple[str, Callable[[Any], Any], Optional[Callable[[Any], str]], Callable[[str], Any]]
LoaderCheck = tuple[str, Callable[[Any], Any], Optional[Callable[[Any], str]], Callable[[str], Any], Callable[[Any], str]]


def vmhwm() -> int:
	"""Kernel peak resident set for this process, in bytes."""
	try:
		with open("/proc/self/status", encoding="utf-8") as f:
			for line in f:
				if line.startswith("VmHWM:"):
					return int(line.split()[1]) * 1024
	except OSError:
		pass
	return 0


#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# One loader per entry. Each returns (version, parse, emit) - emit None when the
# library cannot write - and raises ImportError when it is not installed.
#••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••

def load_shcl() -> LoaderCheck:
	# Every call used to push the same entry again, and the listing calls every
	# loader, so the search path grew a duplicate each time.
	if str(REPO_PY) not in sys.path:
		sys.path.insert(0, str(REPO_PY))
	import shcl

	# The rust tier refuses any document its parse did not read whole. This one
	# took a partial parse and printed a timing at exit 0, so a python-side
	# parity defect would have been measured rather than reported. Outside the
	# timed loop, as the rust guard is.
	def whole(doc: Any) -> str:
		errors = sum(1 for g in doc.diagnostics() if g.severity == shcl.Severity.Error)
		lost = doc.lost_count()
		if errors or lost:
			return f"{errors} diagnostics, {lost} lines lost"
		return ""

	return "working tree", shcl.Document.parse, lambda d: d.to_canonical(), lambda s: s, whole


def load_json() -> Loader:
	import json
	# ensure_ascii off, or every non-ASCII character comes back as an escape and
	# the emitted document stops being the one that was read.
	return getattr(json, "__version__", "stdlib"), json.loads, lambda o: json.dumps(o, indent=2, ensure_ascii=False)


def load_yaml() -> Loader:
	import yaml
	# libyaml through CSafeLoader where it is built, which is what anyone who has
	# noticed PyYAML's speed uses; the pure-Python loader is the fallback.
	loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
	dumper = getattr(yaml, "CSafeDumper", yaml.SafeDumper)
	ver = yaml.__version__ + ("" if hasattr(yaml, "CSafeLoader") else " (no libyaml)")
	# sort_keys off for the same reason JSON gets preserve_order in the Rust tier.
	return (ver,
		lambda s: yaml.load(s, Loader=loader),
		lambda o: yaml.dump(o, Dumper=dumper, allow_unicode=True, default_flow_style=False, sort_keys=False))


def load_toml() -> Loader:
	import tomllib
	try:
		import tomli_w
		return "stdlib + tomli_w " + getattr(tomli_w, "__version__", "?"), tomllib.loads, tomli_w.dumps
	except ImportError:
		return "stdlib", tomllib.loads, None   # tomllib reads only, by design


def load_toml_edit() -> Loader:
	import tomlkit
	return getattr(tomlkit, "__version__", "?"), tomlkit.parse, tomlkit.dumps


def load_xml() -> Loader:
	import xml.etree.ElementTree as ET
	return "stdlib", ET.fromstring, lambda e: ET.tostring(e, encoding="unicode")


def load_xml_lxml() -> LoaderPrep:
	from lxml import etree
	# huge_tree lifts libxml2's built-in size ceilings, which a document of the
	# size this tool generates walks straight into - the parse fails outright
	# otherwise. Turning them off is the fair setting rather than a thumb on the
	# scale: they guard against hostile input, and this input is ours.
	parser = etree.XMLParser(huge_tree=True)
	# The bytes go in through `prepare`, not inside the timed parse. lxml's own
	# entry point wants bytes where every other loader here wants str, and
	# charging it for the encode is a cost none of the others pay.
	return (etree.__version__,
		(lambda b: etree.fromstring(b, parser)),
		(lambda e: etree.tostring(e, encoding="unicode")),
		(lambda s: s.encode("utf-8")))


#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••
# One scalar count per document shape, for the orchestrator's pre-flight. Each
# counts what its opposite number in the rust tier counts: one per scalar, one
# per array element, nothing for a container binding.
#•••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••••

def data_scalars(v: Any) -> int:
	"""json, yaml and both toml readers: a mapping or a sequence recurses, and
	anything else is one value. Mapping and Sequence rather than dict and list,
	since tomlkit hands back its own container types."""
	if isinstance(v, Mapping):
		return sum(data_scalars(x) for x in v.values())
	if isinstance(v, Sequence) and not isinstance(v, (str, bytes, bytearray)):
		return sum(data_scalars(x) for x in v)
	return 1


def xml_scalars(el: Any) -> int:
	"""Both XML readers: a leaf element has the value, a branch has
	none. lxml puts comments and processing instructions in the child list with
	a tag that is not a string, so they are dropped."""
	kids = [k for k in el if isinstance(getattr(k, "tag", None), str)]
	if not kids:
		return 1
	return sum(xml_scalars(k) for k in kids)


def shcl_scalars(doc: Any) -> int:
	"""The binding, walked the way the rust tier walks it: children() and
	instances(), not paths(), which deduplicates and would fold every repeated
	instance into one."""
	import shcl

	def walk(prefix: str) -> int:
		kids = doc.children(prefix)
		if not kids:
			r = doc.read_string_array(prefix)
			if r.status == shcl.Status.Good:
				return len(r.value)
			return 1 if doc.read_raw(prefix).status == shcl.Status.Good else 0
		n = 0
		seen = set()
		for name in kids:
			if name in seen:              # one visit per distinct name
				continue
			seen.add(name)
			seg = shcl.quote_segment(name)
			base = seg if not prefix else f"{prefix}.{seg}"
			insts = doc.instances(base)
			if len(insts) > 1:
				n += sum(walk(f"{base}({shcl.quote_segment(v)})") for v in insts)
			else:
				n += walk(base)
		return n

	return walk("")


ENTRIES = {
	"shcl":      (load_shcl,      "shcl", "shcl (this repo)",      "layout+comments",
		"pure python - no C anywhere, which is the row to read tomllib against", shcl_scalars),
	"json":      (load_json,      "json", "json (stdlib)",         "data",
		"C accelerated - the stdlib module is a thin shell over _json", data_scalars),
	"yaml":      (load_yaml,      "yaml", "PyYAML",                "data",
		"C accelerated where libyaml is built, which CSafeLoader uses", data_scalars),
	"toml":      (load_toml,      "toml", "tomllib (stdlib)",      "data",
		"pure python, and read-only by design; tomli_w supplies a writer when installed", data_scalars),
	"toml-edit": (load_toml_edit, "toml", "tomlkit",               "layout+comments",
		"pure python; the answer to toml_edit - keeps the file as written", data_scalars),
	"xml":       (load_xml,       "xml",  "xml.etree.ElementTree", "data",
		"C accelerated - the stdlib module is a shell over _elementtree/expat", xml_scalars),
	"xml-lxml":  (load_xml_lxml,  "xml",  "lxml",                  "data",
		"C - a binding to libxml2, with huge_tree on so its size ceilings do not refuse the document", xml_scalars),
}


def emit_list() -> None:
	"""key|format|library|retains|version|note for every entry that can be imported."""
	for key, (loader, fmt, lib, retains, note, _scalars) in ENTRIES.items():
		try:
			version = loader()[0]
		# Not just ImportError: a loader that fails any other way is one entry
		# unavailable, not the whole listing gone.
		except Exception as e:
			print(f"unavailable|{key}|{type(e).__name__}: {e}")
			continue
		print(f"available|{key}|{fmt}|{lib}|{retains}|{version}|{note}")


def unpack(loaded: tuple[Any, ...]) -> tuple[Any, Any, Any, Any]:
	"""(parse, emit, prepare, whole) out of a loader's three to five elements.
	A loader whose parser wants something other than the file's text says so
	with a fourth element; a fifth reads the parsed document and says why it is
	not whole."""
	prepare = loaded[3] if len(loaded) > 3 else (lambda s: s)
	whole = loaded[4] if len(loaded) > 4 else None
	return loaded[1], loaded[2], prepare, whole


def count(key: str, path: str) -> None:
	"""The orchestrator's pre-flight: parse once and say how many scalar values
	are in the document. Its own mode, so the walk costs the measured run
	neither clock nor memory - the rust worker leaves it out the same way."""
	scalars = ENTRIES[key][5]
	try:
		loaded = ENTRIES[key][0]()
	except ImportError as e:
		print(f"skipped={e}")
		return
	parse, _, prepare, whole = unpack(loaded)
	try:
		doc = parse(prepare(Path(path).read_text(encoding="utf-8")))
	except Exception as e:
		print(f"failed={type(e).__name__}: {e}".replace("\n", " "))
		return
	if whole is not None:
		why = whole(doc)
		if why:
			print(f"failed={why}")
			return
	print(f"scalars={scalars(doc)}")


def run(key: str, path: str, iters: int) -> None:
	try:
		loaded = ENTRIES[key][0]()
	except ImportError as e:
		print(f"skipped={e}")
		return
	# Whatever `prepare` builds is built once, before the baseline, so neither
	# the clock nor the memory figure includes it.
	parse, emit, prepare, whole = unpack(loaded)
	src = Path(path).read_text(encoding="utf-8")
	subject = prepare(src)

	base = vmhwm()
	try:
		doc = parse(subject)
	except Exception as e:                                    # any parse failure is a result
		print(f"failed={type(e).__name__}: {e}".replace("\n", " "))
		return
	rss = vmhwm()
	if whole is not None:
		why = whole(doc)
		if why:
			print(f"failed={why}")
			return
	del doc

	best = None
	for _ in range(iters):
		t = time.perf_counter()
		doc = parse(subject)
		secs = time.perf_counter() - t
		if best is None or secs < best:
			best = secs
		del doc

	doc = parse(subject)
	emit_best = None
	out = ""
	if emit is not None:
		for _ in range(iters):
			t = time.perf_counter()
			out = emit(doc)
			secs = time.perf_counter() - t
			if emit_best is None or secs < emit_best:
				emit_best = secs

	print(f"parse-secs={best:.6f}")
	if emit_best is not None:
		print(f"emit-secs={emit_best:.6f}")
	print(f"emit-bytes={len(out.encode('utf-8'))}")
	print(f"roundtrip={'true' if out and out == src else 'false'}")
	# The count is the pre-flight's job, not the measurement's, as in the rust
	# worker. `--count` is where it comes from.
	print("scalars=0")
	print(f"rss-bytes={rss}")
	print(f"base-rss-bytes={base}")


def main() -> int:
	args = sys.argv[1:]
	if args and args[0] == "--list":
		emit_list()
		return 0
	if args and args[0] == "--count":
		if len(args) != 3 or args[1] not in ENTRIES:
			print("usage: pyworker.py --count KEY FILE", file=sys.stderr)
			return 2
		count(args[1], args[2])
		return 0
	if len(args) != 3 or args[0] not in ENTRIES:
		print("usage: pyworker.py --list | --count KEY FILE | KEY FILE ITERS", file=sys.stderr)
		return 2
	try:
		iters = int(args[2])
	except ValueError:
		iters = 0
	# Zero timed rounds leaves the best time unset, which used to raise while
	# formatting it - two lines below a usage line that says what ITERS is.
	if iters < 1:
		print("usage: pyworker.py --list | --count KEY FILE | KEY FILE ITERS (ITERS is a positive integer)", file=sys.stderr)
		return 2
	run(args[0], args[1], iters)
	return 0


if __name__ == "__main__":
	sys.exit(main())
