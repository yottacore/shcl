#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

# Conformance-corpus runner for the Python binding. Same corpus every shipped
# binding must pass; column meanings live in project/conformance/README.md. Plain
# stdlib (no pytest) so cicd runs it with a bare python3. Exit nonzero on any miss.

import ast
import collections
import math
import os
import re
import stat
import sys
import tempfile
import time
import tracemalloc
import types
from pathlib import Path
from typing import Any, Optional

_HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))            # source/python (the lib)
import shcl  # noqa: E402

_REPO = os.path.dirname(os.path.dirname(os.path.dirname(_HERE)))   # github/
CORPUS = os.path.join(_REPO, "project", "conformance")

## One status line per test, with its test ID, for the pipeline's console. A
## marker opens a test and closes the one before it. A test fails on an exit
## while it is open, or on a failure added to FAILS since it opened.
FAILS: list[str] = []
_open: dict[str, Any] = {}
## The corpus cases while their dimensions run, and where their failures start.
_corpus: dict[str, Any] = {}


def test_line(status: str, tid: str, name: str) -> None:
	print(f"{status:<4} {tid} python {name}", flush=True)


def test_id_end(status: Optional[str] = None) -> None:
	if not _open:
		return
	if status is None:
		status = "FAIL" if len(FAILS) > _open["fails"] else _open["status"]
	test_line(status, _open["tid"], _open["name"])
	_open.clear()


def test_id(tid: str, name: str) -> None:
	test_id_end()
	_open.update(tid=tid, name=name, status="ok", fails=len(FAILS))


def test_skip() -> None:
	if _open:
		_open["status"] = "skip"


def corpus_lines(abort: str = "") -> None:
	## A case failed when a failure message names it first. After an exit part
	## way through, only the cases known to fail get a line: the rest did not
	## all run.
	cases, start = _corpus["cases"], _corpus["start"]
	_corpus.clear()
	named = FAILS[start:] + ([abort] if abort else [])
	for case in cases:
		bad = any(f.startswith(case["name"] + ": ") for f in named)
		if bad or not abort:
			test_line("FAIL" if bad else "ok", case["id"], "corpus/" + case["name"])


def tsv_escape(s):
	return s.replace("\n", "\\n").replace("\t", "\\t")


def parse_level(s):
	if s in (None, "", "standard"):
		return shcl.Strictness.Standard
	if s == "loose":
		return shcl.Strictness.Loose
	if s == "strict":
		return shcl.Strictness.Strict
	raise SystemExit(f"unknown level '{s}' in reads.tsv")


def load_cases():
	cases = []
	for name in sorted(os.listdir(CORPUS)):
		d = os.path.join(CORPUS, name)
		if not os.path.isdir(d):
			continue
		# A case directory with no input.shcl is a mistake, not a non-case: it
		# used to be skipped without a word while check-docs still wanted its
		# README note, so the case read as present and asserted nothing.
		inp = os.path.join(d, "input.shcl")
		if not os.path.exists(inp):
			raise SystemExit(f"{name}: missing input.shcl")
		# Its test ID. A synthetic corpus built for a gate may have none.
		tid = _text_or_none(os.path.join(d, "test-id"))
		case = {
			"name": name,
			"id": tid.strip() if tid else "-------",
			"input": _read(inp),
			"expected": _read(os.path.join(d, "expected.shcl")),
			"reads": _read(os.path.join(d, "reads.tsv")),
			"expected_diags": _read(os.path.join(d, "expected-diags.txt")),
			"write_ops": None,
			"expected_write": None,
			"expected_keep": None,
			"write_bad_ops": None,
		}
		# write.ops, expected-write.shcl and expected-keep.shcl come together.
		ops = os.path.join(d, "write.ops")
		if os.path.exists(ops):
			case["write_ops"] = _read(ops)
			case["expected_write"] = _read(os.path.join(d, "expected-write.shcl"))
			case["expected_keep"] = _read(os.path.join(d, "expected-keep.shcl"))
		elif os.path.exists(os.path.join(d, "expected-keep.shcl")):
			raise SystemExit(f"{name}: expected-keep.shcl without write.ops")
		bad = os.path.join(d, "write-bad.ops")
		if os.path.exists(bad):
			case["write_bad_ops"] = _read(bad)
		case["schema"] = None
		case["expected_validate"] = None
		sch = os.path.join(d, "schema.shcl")
		if os.path.exists(sch):
			case["schema"] = _read(sch)
			case["expected_validate"] = _read(os.path.join(d, "expected-validate.txt"))
		case["layers"] = []
		case["merge_sets"] = ""
		case["expected_merged"] = None
		em = os.path.join(d, "expected-merged.shcl")
		if os.path.exists(em):
			# Layer files: every layer*.shcl, in filename (= priority) order.
			for n in sorted(os.listdir(d)):
				if n.startswith("layer") and n.endswith(".shcl"):
					case["layers"].append(_read(os.path.join(d, n)))
			ms = os.path.join(d, "merge.sets")
			if os.path.exists(ms):
				case["merge_sets"] = _read(ms)
			case["expected_merged"] = _read(em)
		case["init_schema"] = None
		case["expected_init"] = None
		isch = os.path.join(d, "init-schema.shcl")
		if os.path.exists(isch):
			case["init_schema"] = _read(isch)
			case["expected_init"] = _read(os.path.join(d, "expected-init.shcl"))
		case["expected_migrate"] = None
		case["expected_migrate_diags"] = None
		emig = os.path.join(d, "expected-migrate.shcl")
		emigd = os.path.join(d, "expected-migrate-diags.txt")
		if os.path.exists(emig) != os.path.exists(emigd):
			raise SystemExit(f"{name}: expected-migrate.shcl and expected-migrate-diags.txt must come as a pair")
		if os.path.exists(emig):
			case["expected_migrate"] = _read(emig)
			case["expected_migrate_diags"] = _read(emigd)
		cases.append(case)
	if not cases:
		raise SystemExit(f"no corpus cases found under {CORPUS}")
	return cases


def _read(path):
	with open(path, "rb") as f:
		return f.read().decode("utf-8")


def _diag_text(text):
	"""The load diagnostics of `text` at Standard, written the way `check`
	prints them: one line per diagnostic, then the summary."""
	diags = shcl.Document.parse(text).diagnostics()
	got = ""
	errors = 0
	for d in diags:
		got += f"line {d.line}: {d.severity.name}: {d.code}\n"
		if d.severity == shcl.Severity.Error:
			errors += 1
	if errors > 0:
		got += f"failed: {len(diags)} diagnostic(s), {errors} error(s)\n"
	else:
		got += f"ok ({len(diags)} diagnostic(s))\n"
	return got


def scalar_read(doc, kind, query):
	# Returns (value_string, status, slot_statuses).
	if kind == "int":
		r = doc.read_int(query)
		return str(r.value), r.status, r.slots
	if kind == "float":
		r = doc.read_float(query)
		return shcl.format_float(r.value), r.status, r.slots
	if kind == "bool":
		r = doc.read_bool(query)
		return ("true" if r.value else "false"), r.status, r.slots
	if kind == "datetime":
		r = doc.read_datetime(query)
		return str(r.value), r.status, r.slots
	if kind == "string":
		r = doc.read_string(query)
		return tsv_escape(r.value), r.status, r.slots
	if kind == "raw":
		r = doc.read_raw(query)
		return tsv_escape(r.value), r.status, r.slots
	if kind == "rawinfo":
		r = doc.read_raw_info(query)
		return tsv_escape(r.value), r.status, r.slots
	if kind == "int[]":
		r = doc.read_int_array(query)
		return "|".join(str(v) for v in r.value), r.status, r.slots
	if kind == "float[]":
		r = doc.read_float_array(query)
		return "|".join(shcl.format_float(v) for v in r.value), r.status, r.slots
	if kind == "bool[]":
		r = doc.read_bool_array(query)
		return "|".join("true" if v else "false" for v in r.value), r.status, r.slots
	if kind == "datetime[]":
		r = doc.read_datetime_array(query)
		return "|".join(str(v) for v in r.value), r.status, r.slots
	if kind == "string[]":
		r = doc.read_string_array(query)
		return "|".join(tsv_escape(v) for v in r.value), r.status, r.slots
	if kind.startswith(("duration", "size")):
		# duration[@UNIT] or size[@UNIT][+decimal]: the unit a bare number
		# takes, and KB to TB in powers of 1000.
		rest = kind.removesuffix("+decimal")
		decimal = rest != kind
		base, _, unit = rest.partition("@")
		if base == "duration":
			du = shcl.DurationUnit.from_spelling(unit) if unit else None
			r = doc.read_duration(query, du)
			ms = r.value.days * 86_400_000 + r.value.seconds * 1000 + r.value.microseconds // 1000
			return str(ms), r.status, r.slots
		su = shcl.SizeUnit.from_spelling(unit) if unit else None
		r = doc.read_size(query, su, decimal)
		return str(r.value), r.status, r.slots
	raise SystemExit(f"unknown type '{kind}'")


def _op_text(s):
	# An ops value with the file's escapes resolved, by the file's reader; a
	# backslash is text (mirrors the CLI's _op_text). Raises ValueError.
	if "◉" not in s:
		return s
	if '"' in s and "'" not in s:
		text = f"v: '{s}'\n"
	else:
		text = 'v: "' + s.replace('"', "◉DOUBLE_QUOTE◉") + '"\n'
	doc = shcl.Document.parse(text)
	for d in doc.diagnostics():
		if d.severity == shcl.Severity.Error:
			raise ValueError(d.message)
	return doc.read_string("v").value


def _op_dt(s):
	dt = shcl.parse_datetime(s)
	if dt is None:
		raise ValueError(f"bad datetime: {s}")
	return dt


def _op_bool(s):
	if s == "true":
		return True
	if s == "false":
		return False
	raise ValueError(f"bad bool: {s}")


def _op_int(s):
	# Rust i64 FromStr grammar by hand: int() alone is too lax (it accepts
	# underscores, surrounding whitespace, and non-ASCII digits).
	t = s[1:] if s[:1] in ("+", "-") else s
	if t == "" or any(c < "0" or c > "9" for c in t):
		raise ValueError(f"bad int: {s}")
	# Length-gate before int(): CPython 3.11+ refuses >4300 decimal digits, but the
	# reference just overflows. Leading zeros are legal and don't count toward range.
	digits = t.lstrip("0") or "0"
	if len(digits) > 19:
		raise ValueError(f"bad int: {s}")
	v = -int(digits) if s[:1] == "-" else int(digits)
	if v < -(2 ** 63) or v > 2 ** 63 - 1:
		raise ValueError(f"bad int: {s}")
	return v


def _float_grammar_ok(s):
	# Rust f64 FromStr grammar: optional sign, then inf|infinity|nan (ASCII
	# case-insensitive) or digits['.'[digits]] / '.'digits, with an optional
	# e|E[sign]digits exponent. ASCII digits only, whole string must match.
	t = s[1:] if s[:1] in ("+", "-") else s
	low = "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in t)
	if low in ("inf", "infinity", "nan"):
		return True
	n = len(t)

	def digits(j):
		while j < n and "0" <= t[j] <= "9":
			j += 1
		return j

	j = digits(0)
	int_digits = j > 0
	frac_digits = False
	if j < n and t[j] == ".":
		k = digits(j + 1)
		frac_digits = k > j + 1
		j = k
	if not int_digits and not frac_digits:
		return False
	if j < n and t[j] in ("e", "E"):
		j += 1
		if j < n and t[j] in ("+", "-"):
			j += 1
		k = digits(j)
		if k == j:
			return False
		j = k
	return j == n


def _op_flt(s):
	# float() after the grammar gate is safe. Overflow (1e400) yields inf,
	# which the reader refuses, so it is a bad value like the CLI says.
	if not _float_grammar_ok(s):
		raise ValueError(f"bad float: {s}")
	x = float(s)
	if not math.isfinite(x):
		raise ValueError(f"bad float: {s}")
	return x


# What an op name this runner does not have comes back as. A write-bad.ops row
# spelled wrong is a fixture mistake, and without telling it apart it counted as
# exactly the refusal the row exists to assert.
_UNKNOWN_OP = "unknown op: "


def try_apply_op(doc, line):
	# Apply one write-ops line via the library Writer, with the same value gates
	# the CLI applies. A returned string = the op must be rejected (bad value or
	# unusable path); None = applied.
	f = line.split("\t")

	def g(i):
		return f[i] if i < len(f) else ""

	path, v = g(1), g(2)
	arr = f[2:] if len(f) > 2 else []
	op = f[0]
	try:
		if op == "int":
			wrote = doc.set_int(path, _op_int(v))
		elif op == "float":
			wrote = doc.set_float(path, _op_flt(v))
		elif op == "bool":
			wrote = doc.set_bool(path, _op_bool(v))
		elif op == "string":
			wrote = doc.set_string(path, _op_text(v))
		elif op == "datetime":
			wrote = doc.set_datetime(path, _op_dt(v))
		elif op == "literal":
			wrote = doc.set_literal(path, v)
		elif op == "literal-default":
			wrote = doc.set_literal_default(path, v)
		elif op == "int-default":
			wrote = doc.set_int_default(path, _op_int(v))
		elif op == "float-default":
			wrote = doc.set_float_default(path, _op_flt(v))
		elif op == "bool-default":
			wrote = doc.set_bool_default(path, _op_bool(v))
		elif op == "string-default":
			wrote = doc.set_string_default(path, _op_text(v))
		elif op == "datetime-default":
			wrote = doc.set_datetime_default(path, _op_dt(v))
		elif op == "int-array":
			wrote = doc.set_int_array(path, [_op_int(x) for x in arr])
		elif op == "float-array":
			wrote = doc.set_float_array(path, [_op_flt(x) for x in arr])
		elif op == "bool-array":
			wrote = doc.set_bool_array(path, [_op_bool(x) for x in arr])
		elif op == "string-array":
			wrote = doc.set_string_array(path, [_op_text(x) for x in arr])
		elif op == "datetime-array":
			wrote = doc.set_datetime_array(path, [_op_dt(x) for x in arr])
		elif op == "int-array-default":
			wrote = doc.set_int_array_default(path, [_op_int(x) for x in arr])
		elif op == "float-array-default":
			wrote = doc.set_float_array_default(path, [_op_flt(x) for x in arr])
		elif op == "bool-array-default":
			wrote = doc.set_bool_array_default(path, [_op_bool(x) for x in arr])
		elif op == "string-array-default":
			wrote = doc.set_string_array_default(path, [_op_text(x) for x in arr])
		elif op == "datetime-array-default":
			wrote = doc.set_datetime_array_default(path, [_op_dt(x) for x in arr])
		elif op == "raw":
			wrote = doc.set_raw(path, _op_text(g(3)), v)
		elif op == "raw-default":
			wrote = doc.set_raw_default(path, _op_text(g(3)), v)
		elif op == "empty":
			wrote = doc.set_empty(path)
		elif op == "comment":
			wrote = doc.set_comment(path, _op_text(v))
		elif op == "remove":
			doc.remove(path)
			wrote = shcl.SetStatus.Ok
		elif op == "clear-comments":
			doc.clear_comments(path)
			wrote = shcl.SetStatus.Ok
		elif op == "banner":
			if path not in ("on", "off"):
				return f"bad banner: {path}"
			doc.set_banner(path == "on")
			wrote = shcl.SetStatus.Ok
		else:
			return f"{_UNKNOWN_OP}{op}"
	except ValueError as e:
		return str(e)
	if wrote is not shcl.SetStatus.Ok:
		return f"cannot write {path}: {wrote.name}"
	return None


def apply_op(doc, line, at):
	# Good-path wrapper: the op must apply.
	err = try_apply_op(doc, line)
	if err is not None:
		raise SystemExit(f"{at}: {err}")


# The alphabet the setter round-trip fixture draws from: every character that
# means something to the tokenizer, plus a blank the load trims and a no-break
# space it does not. Same fixture in every runner.
SETTER_SOUP = ('"', "'", "\\", "#", ",", "[", "]", "\r", "\n", " ", "\t", "\u00a0", "a")


def soup_inputs():
	# Every string of one and two characters over that alphabet, and the empty
	# string.
	out = [""]
	for a in SETTER_SOUP:
		out.append(a)
		for b in SETTER_SOUP:
			out.append(a + b)
	return out


def _text_or_none(path):
	try:
		return _read(path)
	except OSError:
		return None


def windows_publish_failures(td):
	# A save always puts its temp file beside the target, so these call the
	# publish directly.
	test_id("EqYZV7w", "a_failed_publish_loses_neither_file")
	_failed_publish_loses_neither_file(td)
	test_id("EqYZV7x", "a_brief_hold_is_waited_out")
	_brief_hold_is_waited_out(td)
	test_id_end()


def _failed_publish_loses_neither_file(td):
	import subprocess

	# Taking add-file away from the target's folder, with the temp file in
	# another, lets ReplaceFile move the old file out to the backup and then
	# refuses the new one its place: error 1177, with nothing at the target.
	# Neither the rename nor putting the old file back can get in either.
	x, y = os.path.join(td, "px"), os.path.join(td, "py")
	os.makedirs(x)
	os.makedirs(y)
	target, tmp = os.path.join(y, "t.shcl"), os.path.join(x, ".t.shcl.tmp1.0")
	backup = os.path.join(x, ".t.shcl.bak1.0")
	for path, text in ((target, "old\n"), (tmp, "new\n"), (os.path.join(x, "probe"), "")):
		with open(path, "w", encoding="utf-8", newline="") as fh:
			fh.write(text)
	subprocess.run(["icacls", y, "/deny", "*S-1-1-0:(WD)"], check=True, capture_output=True)
	try:
		# The hosted runner's administrator is let through anyway, and the
		# case cannot be set up there.
		try:
			os.rename(os.path.join(x, "probe"), os.path.join(y, "probe"))
			print("conformance: skipping the failed-publish fixture (a move into a denied folder went through)")
			return
		except OSError:
			pass
		try:
			shcl._publish_file(tmp, target)
			raise SystemExit("the publish went through")
		except OSError as e:
			msg = str(e)
	finally:
		subprocess.run(["icacls", y, "/remove:d", "*S-1-1-0"], check=True, capture_output=True)
	if _text_or_none(target) == "old\n":
		if os.path.exists(tmp):
			raise SystemExit(f"the temp file was left: {msg}")
		return
	if _text_or_none(target) is not None:
		raise SystemExit(f"target holds neither text: {msg}")
	if _text_or_none(backup) != "old\n" or _text_or_none(tmp) != "new\n":
		raise SystemExit(f"a failed publish lost a file: {msg}")
	if backup not in msg or tmp not in msg:
		raise SystemExit(f"the error does not name both files: {msg}")


def _brief_hold_is_waited_out(td):
	import ctypes
	import threading

	# Anything holding the temp file open without delete sharing fails the
	# replace and the rename both, the way a scanner looking at a fresh file
	# does. A hold that ends in a few milliseconds must not fail the save.
	k32 = ctypes.WinDLL("kernel32", use_last_error=True)  # type: ignore[attr-defined]
	k32.CreateFileW.restype = ctypes.c_void_p
	k32.CreateFileW.argtypes = [
		ctypes.c_wchar_p,
		ctypes.c_ulong,
		ctypes.c_ulong,
		ctypes.c_void_p,
		ctypes.c_ulong,
		ctypes.c_ulong,
		ctypes.c_void_p,
	]
	k32.CloseHandle.argtypes = [ctypes.c_void_p]
	h = os.path.join(td, "ph")
	os.makedirs(h)
	target, tmp = os.path.join(h, "t.shcl"), os.path.join(h, ".t.shcl.tmp1.0")
	for path, text in ((target, "old\n"), (tmp, "new\n")):
		with open(path, "w", encoding="utf-8", newline="") as fh:
			fh.write(text)
	# GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING
	hold = k32.CreateFileW(tmp, 0x80000000, 0x1, None, 3, 0, None)
	if hold in (None, ctypes.c_void_p(-1).value):
		raise SystemExit("could not hold the temp file open")

	def free():
		time.sleep(0.02)
		k32.CloseHandle(hold)

	freed = threading.Thread(target=free)
	freed.start()
	try:
		shcl._publish_file(tmp, target)
	except OSError as e:
		raise SystemExit(f"a brief hold failed the publish: {e}") from None
	finally:
		freed.join()
	if _read(target) != "new\n":
		raise SystemExit("a brief hold: the target was not replaced")
	if os.path.exists(tmp) or os.path.exists(os.path.join(h, ".t.shcl.bak1.0")):
		raise SystemExit("a brief hold: the temp or the backup was left behind")


def _temp_takes_the_targets_dacl(td):
	import ctypes
	import subprocess
	import threading

	# A save over a file whose DACL is narrower than its directory's must not
	# put the new text under the directory's. Holding the target without delete
	# sharing fails the publish on every try, which keeps the temp file there
	# long enough for a poller to read its DACL. Same fixture in every runner.
	if hasattr(ctypes.WinDLL("ntdll"), "wine_get_version"):  # type: ignore[attr-defined]
		print("conformance: skipping the temp-file DACL fixture (wine keeps no ACLs)")
		test_skip()
		return
	adv = ctypes.WinDLL("advapi32", use_last_error=True)  # type: ignore[attr-defined]
	k32 = ctypes.WinDLL("kernel32", use_last_error=True)  # type: ignore[attr-defined]
	adv.GetFileSecurityW.restype = ctypes.c_int
	adv.GetFileSecurityW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong)]
	to_sddl = adv.ConvertSecurityDescriptorToStringSecurityDescriptorW
	to_sddl.restype = ctypes.c_int
	to_sddl.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
	k32.LocalFree.argtypes = [ctypes.c_void_p]
	k32.CreateFileW.restype = ctypes.c_void_p
	k32.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
	k32.CloseHandle.argtypes = [ctypes.c_void_p]

	def sddl(path):
		# The file's DACL as SDDL, or None when it cannot be read.
		need = ctypes.c_ulong(0)
		adv.GetFileSecurityW(path, 0x4, None, 0, ctypes.byref(need))
		if not need.value:
			return None
		sd = (ctypes.c_uint64 * ((need.value + 7) // 8))()
		if not adv.GetFileSecurityW(path, 0x4, sd, ctypes.sizeof(sd), ctypes.byref(need)):
			return None
		out = ctypes.c_void_p()
		if not to_sddl(sd, 1, 0x4, ctypes.byref(out), None) or out.value is None:
			return None
		text = ctypes.wstring_at(out.value)
		k32.LocalFree(out)
		return text

	def poll(path, stop, seen):
		while not stop.is_set():
			got = sddl(path)
			if got is not None:
				seen.append(got)

	d = os.path.join(td, "pdacl")
	os.makedirs(d)
	subprocess.run(["icacls", d, "/grant", "*S-1-5-32-545:(OI)(CI)(R)"], check=True, capture_output=True)
	setups = (
		("a.shcl", ["/inheritance:r", "/grant:r", os.environ.get("USERNAME", "") + ":(F)"], "D:P"),
		("b.shcl", ["/grant", "*S-1-5-19:(R)"], "D:AI"),
	)
	for name, acl, prefix in setups:
		target = os.path.join(d, name)
		with open(target, "w", encoding="utf-8", newline="") as fh:
			fh.write("a: 1\n")
		subprocess.run(["icacls", target, *acl], check=True, capture_output=True)
		want = sddl(target) or ""
		if not want.startswith(prefix):
			raise SystemExit(f"{name}: the fixture did not take: {want}")
		tmp = os.path.join(d, f".{name}.tmp{os.getpid()}.0")
		# GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING
		hold = k32.CreateFileW(target, 0x80000000, 0x1, None, 3, 0, None)
		if hold in (None, ctypes.c_void_p(-1).value):
			raise SystemExit("could not hold the target open")
		seen: list[str] = []
		stop = threading.Event()
		poller = threading.Thread(target=poll, args=(tmp, stop, seen))
		poller.start()
		try:
			err = shcl.write_file_atomic(target, "a: 2\n")
		finally:
			stop.set()
			poller.join()
			k32.CloseHandle(hold)
		if err is None:
			raise SystemExit(f"{name}: a save over a held file went through")
		if not seen:
			raise SystemExit(f"{name}: the temp file was never seen")
		if seen[-1] != want:
			raise SystemExit(f"{name}: the temp file's DACL is {seen[-1]}, want {want}")
		left = [n for n in os.listdir(d) if ".tmp" in n or ".bak" in n]
		if left:
			raise SystemExit(f"{name}: left behind: {left}")
		err = shcl.write_file_atomic(target, "a: 2\n")
		if err is not None:
			raise SystemExit(err)
		if sddl(target) != want:
			raise SystemExit(f"{name}: the saved file's DACL is {sddl(target)}, want {want}")
	fresh, plain = os.path.join(d, "n.shcl"), os.path.join(d, "p.shcl")
	err = shcl.write_file_atomic(fresh, "a: 2\n")
	if err is not None:
		raise SystemExit(err)
	with open(plain, "w", encoding="utf-8", newline="") as fh:
		fh.write("a: 2\n")
	born = sddl(plain)
	if born is None:
		raise SystemExit("the plain file's DACL could not be read")
	if sddl(fresh) != born:
		raise SystemExit(f"a new file's DACL is {sddl(fresh)}, want {born}")
	with open(fresh, "rb") as nh, open(os.path.join(d, "b.shcl"), "rb") as bh:
		if nh.read() != bh.read():
			raise SystemExit("an overwrite and a create wrote different bytes")
	# With no DACL to copy, the create still goes through, with the
	# directory's.
	copied = os.path.join(d, "c.shcl")
	os.close(shcl._create_like(os.path.join(d, "missing.shcl"), copied))
	if sddl(copied) != born:
		raise SystemExit(f"a temp file with no DACL to copy has {sddl(copied)}, want {born}")


def setters_write_only_what_reads_back():
	# A setter writes only what reads back. Each one builds its text through the
	# emitter and hands it to the tokenizer before the document is touched, so
	# for every input either the call refuses and the document is byte-identical,
	# or the canonical text reloads to itself and the read gives the value back.
	# Twelve review items were one setter's own trim, carriage-return or `#` rule
	# disagreeing with the parser's. Every accepted write also goes into one
	# document that is saved and loaded back at the end, since the file tier
	# checks what an in-memory reload does not: a setter once took bytes the save
	# wrote and the next load refused. Same fixture in every runner.
	def put(d, kind, p, s):
		if kind == 0:
			return d.set_string(p, s)
		if kind == 1:
			return d.set_literal(p, s)
		if kind == 2:
			return d.set_comment(p, s)
		if kind == 3:
			return d.set_raw(p, s, "t")
		if kind == 4:
			return d.set_raw(p, "body", s)
		return d.set_string_array(p, ["x", s])

	every = shcl.Document.parse("")
	slot = 0
	for s in soup_inputs():
		for kind in range(6):
			doc = shcl.Document.parse("k: 1\n")
			before = doc.to_canonical()
			applied = put(doc, kind, "k", s)
			if applied:
				slot += 1
				if not put(every, kind, f"k{slot}", s):
					raise SystemExit(f"slot {slot} refused what k took (setter {kind}, input {s!r})")
			if not applied:
				if doc.to_canonical() != before:
					raise SystemExit(f"a refused write changed the document (setter {kind}, input {s!r})")
				continue
			text = doc.to_canonical()
			back = shcl.Document.parse(text)
			if back.to_canonical() != text:
				raise SystemExit(f"written text is not a fixpoint (setter {kind}, input {s!r}):\n{text}")
			if back.instances("k") != doc.instances("k"):
				raise SystemExit(f"the value read differs after a reload (setter {kind}, input {s!r}):\n{text}")
			if kind == 0 and back.read_string("k").value != s:
				raise SystemExit(f"string {s!r} read back {back.read_string('k').value!r}")
			# A comment has no accessor of its own, so the oracle is the text:
			# whatever the load would keep of what was handed in has to be in the
			# document, not a shortened form of it.
			if kind == 2 and s.rstrip(" \t\r") not in text:
				raise SystemExit(f"the comment handed in is not in the document ({s!r}):\n{text}")
			if kind in (3, 4):
				if back.get_raw("k") != doc.get_raw("k"):
					raise SystemExit(f"raw body {s!r} got {back.get_raw('k')!r}")
				if back.read_raw_info("k").value != doc.read_raw_info("k").value:
					raise SystemExit(f"raw info {s!r} got {back.read_raw_info('k').value!r}")
			if kind == 5 and back.read_string_array("k").value != ["x", s]:
				raise SystemExit(f"array {s!r} got {back.read_string_array('k').value!r}")
		# The same rule for a name: whatever quote_segment writes has to come
		# back as one segment holding that name, or the write is refused.
		path = shcl.quote_segment(s)
		doc = shcl.Document.parse("k: 1\n")
		before = doc.to_canonical()
		applied = doc.set_string(path, "v")
		if applied and not every.set_string(path, "v"):
			raise SystemExit(f"the name {s!r} was refused the second time")
		if not applied:
			if doc.to_canonical() != before:
				raise SystemExit(f"a refused name write changed the document ({s!r})")
			continue
		text = doc.to_canonical()
		back = shcl.Document.parse(text)
		if back.to_canonical() != text:
			raise SystemExit(f"name {s!r} is not a fixpoint:\n{text}")
		if back.read_string(path).value != "v":
			raise SystemExit(f"name {s!r} did not read back:\n{text}")
	with tempfile.TemporaryDirectory() as td:
		f = os.path.join(td, "all.shcl")
		every.save_file(f)
		back, st = shcl.Document.load_file(f)
		if st != shcl.FileStatus.Clean:
			raise SystemExit(f"every accepted write together loaded {st}")
		if back.to_canonical() != every.to_canonical():
			raise SystemExit("every accepted write together changed on a save and load")


def setter_status_agrees_with_the_path_check():
	# A setter's status agrees with check_set_path over generated documents:
	# a path reason is what check_set_path gives for that path, a value reason
	# comes with a path that checks Ok, and a refusal writes nothing. The
	# reference runs it over its fuzz soup; this runs it over the sequence
	# fixture's documents and the setter soup.
	S = shcl.SetStatus
	g = SeqGen(0x5EED57A71C0000D1)
	soup = soup_inputs()
	seen = set()
	for i in range(3000):
		text = g.doc()
		doc = shcl.Document.parse(text)
		paths = doc.paths()
		if not paths or g.below(4) == 0:
			path = f"new{g.below(3)}.k"
		else:
			path = paths[g.below(len(paths))]
		path += ("", "", "", "", ".kid", "(*)", "(7)", "..x")[g.below(8)]
		v = soup[g.below(len(soup))]
		checked = doc.check_set_path(path)
		before = doc.to_canonical()
		op = g.below(10)
		if op == 0:
			got = doc.set_int(path, 7)
		elif op == 1:
			got = doc.set_string(path, v)
		elif op == 2:
			got = doc.set_literal(path, v)
		elif op == 3:
			got = doc.set_comment(path, v)
		elif op == 4:
			got = doc.set_raw(path, v, soup[g.below(len(soup))])
		elif op == 5:
			got = doc.set_int_array(path, [1, 2])
		elif op == 6:
			got = doc.set_float(path, math.nan if len(v) % 2 == 0 else 1.5)
		elif op == 7:
			got = doc.set_literal_default(path, v)
		elif op == 8:
			got = doc.set_int_array_default(path, [3])
		else:
			got = doc.set_empty(path)
		seen.add(got.name)
		want = got if got.value <= S.UnderArray.value else S.Ok
		if checked is not want:
			raise SystemExit(f"iteration {i}: op {op} at {path!r} with {v!r} gave {got}, check_set_path {checked}:\n{text}")
		if got is not S.Ok and doc.to_canonical() != before:
			raise SystemExit(f"iteration {i}: op {op} at {path!r} gave {got} and wrote:\n{text}")
	# Guard: the documents still reach path and value reasons both.
	for want_name in ("Ok", "BadPath", "Wildcard", "NoSuchIndex", "Multiple", "UnderArray", "HasChildren",
			"NotFinite", "BadRawInfo", "BadComment", "NotOneValue"):
		if want_name not in seen:
			raise SystemExit(f"never saw {want_name}: {sorted(seen)}")


class SeqGen:
	"""The sequence fixture's generator: xorshift64* on a fixed seed, so every
	runner builds the same documents and the same steps."""

	def __init__(self, seed):
		self.s = seed

	def below(self, n):
		x = self.s
		x ^= x >> 12
		x ^= (x << 25) & 0xFFFFFFFFFFFFFFFF
		x ^= x >> 27
		self.s = x
		return ((x * 0x2545F4914F6CDD1D) & 0xFFFFFFFFFFFFFFFF) % n

	def doc(self):
		# Lines that have comments and blanks somewhere a later step can move
		# them: comments at every depth, empty and reopened blocks, a same-line
		# fence with a comment after an empty binding, and misplaced lines kept
		# as written, one of them among a list's elements.
		out = []
		depth = 0
		for _ in range(1 + self.below(10)):
			r = self.below(6)
			if r == 0:
				depth = 0
			elif r == 1:
				depth = max(depth - 1, 0)
			elif r == 2:
				depth = min(depth + 1, 3)
			ind = "\t" * depth
			name = SEQ_NAMES[self.below(3)]
			shape = self.below(10)
			if shape == 0:
				out.append(f"{ind}# c{self.below(3)}")
			elif shape == 1:
				out.append("")
			elif shape == 2:
				out.append(f"{ind}{name}:")
			elif shape == 3:
				out.append(f"{ind}{name}: {self.below(3)}")
			elif shape == 4:
				out.append(f"{ind}{name}: ```x  # t\n{ind}\tbody\n{ind}\t```")
			elif shape == 5:
				out.append(f"{ind}{name}: {self.below(3)}  # t")
			elif shape == 6:
				out.append(f"{ind}{name}.{name}: 1")
			elif shape == 7:
				out.append(f"{ind} {name}: {self.below(3)}")
			elif shape == 8:
				out.append(f"{ind}{name}:\n{ind}\t- 1\n{ind} x: 1\n{ind}\t- 2")
			else:
				out.append(f"{ind}\t# deep")
		return "".join(line + "\n" for line in out)


SEQ_NAMES = ["a", "b", "m"]


def no_new_errors(text, base):
	"""Every error code text loads with, base loaded with at least as often."""
	count = collections.Counter(d.code for d in shcl.Document.parse(base).diagnostics() if d.severity == shcl.Severity.Error)
	count.subtract(d.code for d in shcl.Document.parse(text).diagnostics() if d.severity == shcl.Severity.Error)
	return min(count.values(), default=0) >= 0


def keeps_every_line(base):
	"""On a base that loads clean, a new field saved with the lines kept writes
	every line of the base that is not blank, in order. A repeat the load
	folded away comes back too (20260925c item 1). A kept misplaced line is
	left out, since it turns into a comment once a new field above it would
	take it as a child."""
	doc = shcl.Document.parse_keep_lines(base, shcl.Strictness.Standard)
	if any(d.severity == shcl.Severity.Error for d in doc.diagnostics()) or not doc.set_int("zz_new", 1):
		return True
	text, kept = doc.to_text_keep_lines()
	rest = iter(text.split("\n"))
	return not kept or all(any(t == ln for t in rest) for ln in base.split("\n") if ln.strip())


def list_after_empty(doc) -> bool:
	"""A list with a field under it (E001) after an empty binding of its name
	that has fields of its own. A merge or an edit can leave one, and then no
	text reloads as it: stacked, its header joins that binding and its items
	are dropped (E008), and in brackets it is E028 (2026100511210900). The save
	gate counts its items lost, so it is never written; the fixture checks that
	and skips the rest."""
	for p in doc.instance_paths():
		r = doc.read_string(p)
		if not doc.children(p) or r.status != shcl.Status.Good or r.quoted or not r.value.startswith("["):
			continue
		if not p.endswith(")"):
			continue
		at = p.rfind("(")
		if at < 0:
			continue
		try:
			k = int(p[at + 1:-1])
		except ValueError:
			continue
		for j in range(k):
			e = f"{p[:at]}({j})"
			if doc.read_string(e).status == shcl.Status.Empty and doc.children(e):
				return True
	return False


def reload_took_only_comments(live: str, back: str) -> bool:
	"""A kept line the settle turned into a comment is still the user's line,
	so clear_comments and a remove beside it leave it (design.md, Kept lines
	under edits). The canonical text writes it as a comment, and the reload
	takes it like one, so the two cannot agree (20260926 item 2). True when
	that is all that differs: the reload's comment lines are some of the
	document's, in order, and without comment and blank lines the two load as
	one document. A comment the reload took can also take a blank with it,
	step the comments after it back a level, or leave a kept line heading the
	block below, so the rest is compared as documents. A check of the
	target's comments missed one below the target (2026100506223902)."""

	def comment(line: str) -> bool:
		return line.lstrip("\t").startswith("#")

	have = iter(ln.lstrip("\t") for ln in live.split("\n") if comment(ln))
	if not all(any(h == ln.lstrip("\t") for h in have) for ln in back.split("\n") if comment(ln)):
		return False

	def bare(text: str) -> str:
		rest = "".join(ln + "\n" for ln in text.split("\n") if ln and not comment(ln))
		return shcl.Document.parse(rest).to_canonical()

	return bare(live) == bare(back)


def a_remove_keeps_a_settled_line_below_it():
	# The issue's steps, which the fuzz reached with the value syntax: the
	# setter comments out `a: [1` and makes `a` with the lines under it, and
	# the new `c` goes between the kept line and the settled one, so the
	# settled line sits below it. The remove leaves it there. The reload reads
	# a plain comment and takes it with the field.
	live = shcl.Document.parse("a: [1\n\t\t\": \n\t d-: 2\n\te: 3\n")
	if live.clear_comments("a.d") != 0:
		raise SystemExit("clear_comments took a line at a.d")
	if not live.set_empty("a.c") or not live.set_raw("b.c", "body", "v0"):
		raise SystemExit("a setter refused")
	back = shcl.Document.parse(live.to_canonical())
	if live.remove("a.c") != 1 or back.remove("a.c") != 1:
		raise SystemExit("a remove missed")
	a, b = live.to_canonical(), back.to_canonical()
	if "\n\t\":\n\t# d-: 2\n\nb:\n" not in a:
		raise SystemExit(f"the document wrote {a!r}")
	if "\n\t\":\n\nb:\n" not in b:
		raise SystemExit(f"the reload wrote {b!r}")
	if not reload_took_only_comments(a, b) or reload_took_only_comments(b, a):
		raise SystemExit(f"reload_took_only_comments got it wrong:\n{a}---\n{b}")


def edits_and_merges_match_a_reload():
	# A merge or an edit leaves the document its own saved text reloads as,
	# comments included, so the next step comes out the same whether or not the file
	# was saved in between. Comments were filed one way by a load and another by
	# a merge, a new child or the writer's fold three times in three days, and
	# the text fixpoint cannot see it, since both placements are fixpoints. Same
	# fixture in every runner.
	g = SeqGen(0x5EED0923C0DE0003)
	for i in range(3000):
		base = g.doc()
		# Loaded to keep its lines, which is the same tree: each step's save
		# that keeps them reloads as the document, or is the canonical form.
		live = shcl.Document.parse_keep_lines(base, shcl.Strictness.Standard)
		log = "base:\n" + base
		if not keeps_every_line(base):
			raise SystemExit(f"a new field moved or dropped a line at iteration {i}:\n{log}")
		for _ in range(2 + g.below(3)):
			back = shcl.Document.parse(live.to_canonical())
			paths = live.paths()
			if not paths or g.below(3) == 0:
				path = SEQ_NAMES[g.below(3)] + "." + SEQ_NAMES[g.below(3)]
			else:
				path = paths[g.below(len(paths))]
			v = f"v{g.below(3)}"
			op = g.below(11)
			layer = g.doc()
			for d in (live, back):
				if op <= 1:
					d.merge(shcl.Document.parse(layer))
				elif op == 2:
					d.set_int(path, 7)
				elif op == 3:
					d.set_string(path, v)
				elif op == 4:
					d.remove(path)
				elif op == 5:
					d.set_comment(path, v)
				elif op == 6:
					d.set_empty(path)
				elif op == 7:
					d.set_raw(path, "body", v)
				elif op == 8:
					d.set_int_default(path, 1)
				elif op == 9:
					d.clear_comments(path)
				else:
					d.set_banner(v != "v0")
			log += f"merge:\n{layer}" if op <= 1 else f"op {op} at {path!r}\n"
			if list_after_empty(live):
				if live.lost_count() == 0:
					raise SystemExit(f"a list no text loads back saves at iteration {i}:\n{log}")
				break
			a, b = live.to_canonical(), back.to_canonical()
			if a != b and not (op in (4, 9) and reload_took_only_comments(a, b)):
				raise SystemExit(f"a step on the document and on its reload differ at iteration {i}:\n{log}--- live\n{a}--- reload\n{b}")
			t, kept = live.to_text_keep_lines()
			if kept and shcl.Document.parse(t).to_canonical() != a:
				raise SystemExit(f"kept lines reload as another document at iteration {i}:\n{log}--- wrote\n{t}")
			if kept and not no_new_errors(t, base):
				raise SystemExit(f"kept lines load with a new error at iteration {i}:\n{log}--- wrote\n{t}")
			# Every line the load dropped went out as written (20260926 item 1).
			if kept and shcl.Document.parse(t).lost_count() != shcl.Document.parse(base).lost_count():
				raise SystemExit(f"kept lines lost a dropped line at iteration {i}:\n{log}--- wrote\n{t}")
			if not kept and t != a:
				raise SystemExit(f"a save that kept no lines is not canonical at iteration {i}:\n{log}")


def main():
	fails = FAILS
	cases = load_cases()

	test_id("EqLrWHw", "surrogate_parses_and_fails_the_save")
	# A lone surrogate, which os.listdir, sys.argv and os.environ hand out, is
	# one more character to the parse and to a lookup path, as it was before
	# the tokenizer read bytes (20260918b item 20). A strict encode made parse
	# raise, where it promises never to. The save is where it fails. Python
	# only: no other binding's string can hold one.
	sdoc = shcl.Document.parse("a: x\udc80\n\"k\udc81\": 2\n")
	if sdoc.to_canonical() != "a: x\udc80\n\"k\udc81\": 2\n" or sdoc.diagnostics():
		fails.append("surrogate: the parse did not keep the text")
	if sdoc.read_string("a").value != "x\udc80" or sdoc.read_string('"k\udc81"').status != shcl.Status.Good:
		fails.append("surrogate: a read did not find what the parse kept")
	# Was NotFound until reads got BadPath (2026100717500001): a bare name
	# outside ASCII is refused, so the quoted spelling is the miss now.
	# if sdoc.read_string("z\udc80").status != shcl.Status.NotFound or sdoc.exists("q\udc80.r"):
	# 	fails.append("surrogate: a path holding one is not NotFound")
	if sdoc.read_string("z\udc80").status != shcl.Status.BadPath or sdoc.exists("q\udc80.r"):
		fails.append("surrogate: a bare path holding one is not BadPath")
	if sdoc.read_string('"z\udc80"').status != shcl.Status.NotFound or sdoc.exists('"q\udc80".r'):
		fails.append("surrogate: a quoted path holding one is not NotFound")
	with tempfile.TemporaryDirectory() as sd:
		try:
			sdoc.save_file(os.path.join(sd, "s.shcl"))
			fails.append("surrogate: a document with no UTF-8 spelling saved")
		except shcl.SaveFailed:
			pass

	test_id("EqLxvWz", "tokenize_value_takes_a_negative_offset_as_zero")
	# The reference's tokenizer offset is unsigned, so a negative one has
	# nothing else it can mean. Go panicked and Python read it as an offset
	# from the end (20260918b item 31). Same fixture in the Go test.
	neg, zero = shcl.Tokens(), shcl.Tokens()
	shcl.tokenize_value("x, 'y' # c", -3, shcl.Rules.CURRENT, neg)
	shcl.tokenize_value("x, 'y' # c", 0, shcl.Rules.CURRENT, zero)
	if [(p.start, p.end, p.quote) for p in neg.elements] != [(p.start, p.end, p.quote) for p in zero.elements] \
			or neg.value != zero.value or neg.comment != zero.comment:
		fails.append("a negative tokenizer offset did not read as zero")

	test_id("EqLqxgn", "merge_onto_itself_leaves_it_alone")
	# A document merged onto itself is left as it is (20260918b item 19). The
	# walk read over while it wrote self, so Go doubled a retained line, Python
	# grew without end and C ran out of memory. Every corpus input, and the
	# three lines that showed it. Same fixture in every runner.
	for name, text in [("self-merge", "# c\na: 1\nbad line\n")] + [(c["name"], c["input"]) for c in cases]:
		doc = shcl.Document.parse(text)
		before = doc.to_canonical()
		doc.merge(doc)
		if doc.to_canonical() != before:
			fails.append(f"{name}: merge onto itself changed the document")

	test_id_end()
	_corpus.update(cases=cases, start=len(FAILS))
	# Write dimension: the library Writer must reproduce expected-write.shcl and
	# the result must be a formatter fixpoint.
	# The one loaded to keep its lines is the same document, and its save must
	# reproduce expected-keep.shcl.
	for case in cases:
		if case["write_ops"] is None:
			continue
		doc = shcl.Document.parse(case["input"])
		keep = shcl.Document.parse_keep_lines(case["input"], shcl.Strictness.Standard)
		for n, line in enumerate(case["write_ops"].split("\n")):
			line = line[:-1] if line.endswith("\r") else line
			if line == "" or line.startswith("#"):
				continue
			at = f"{case['name']}: write.ops line {n + 1}"
			apply_op(doc, line, at)
			apply_op(keep, line, at)
		got = doc.to_canonical()
		if got != case["expected_write"]:
			fails.append(f"{case['name']}: writer output differs from expected-write.shcl")
		if shcl.Document.parse(got).to_canonical() != got:
			fails.append(f"{case['name']}: written output is not a fmt fixpoint")
		text, lines_kept = keep.to_text_keep_lines()
		if text != case["expected_keep"]:
			fails.append(f"{case['name']}: output differs from expected-keep.shcl")
		if not lines_kept and text != got:
			fails.append(f"{case['name']}: a save that kept no lines is not canonical")
		if shcl.Document.parse(text).to_canonical() != got:
			fails.append(f"{case['name']}: expected-keep.shcl reloads as another document")

	# Loaded to keep its lines and saved with no edits, every input is its own
	# text again, byte for byte.
	for case in cases:
		kdoc = shcl.Document.parse_keep_lines(case["input"], shcl.Strictness.Standard)
		if kdoc.to_text_keep_lines() != (case["input"], True):
			fails.append(f"{case['name']}: an unedited save changed the text")

	# Bad-op dimension: each write-bad.ops line, applied alone to the case
	# input, must be rejected (bad value, bad datetime, or unusable path) and
	# leave the document unchanged.
	test_id("Er207Yh", "a_misspelled_op_is_told_apart_from_a_refusal")
	# The names-no-op guard below is only worth something while a misspelled
	# op still comes back told apart from an ordinary refusal.
	opdoc = shcl.Document.parse("a: 1\n")
	err = try_apply_op(opdoc, "itn\ta\t1")
	if err is None or not err.startswith(_UNKNOWN_OP):
		fails.append(f"a misspelled op read as a refusal: {err}")
	err = try_apply_op(opdoc, "int\ta\tx")
	if err is None or err.startswith(_UNKNOWN_OP):
		fails.append(f"a refusal read as a misspelled op: {err}")
	test_id_end()
	for case in cases:
		if case["write_bad_ops"] is None:
			continue
		for n, line in enumerate(case["write_bad_ops"].split("\n")):
			line = line[:-1] if line.endswith("\r") else line
			if line == "" or line.startswith("#"):
				continue
			doc = shcl.Document.parse(case["input"])
			before = doc.to_canonical()
			err = try_apply_op(doc, line)
			if err is None:
				fails.append(f"{case['name']}: write-bad.ops line {n + 1} was accepted: {line}")
			elif err.startswith(_UNKNOWN_OP):
				fails.append(f"{case['name']}: write-bad.ops line {n + 1} names no op: {line}")
			if doc.to_canonical() != before:
				fails.append(f"{case['name']}: write-bad.ops line {n + 1} changed the document: {line}")

	# Layered-load dimension: fold the layer files (lowest first) and input.shcl
	# (highest file layer) via the library merge, apply the path=value overrides
	# as the top layer, and match the golden merged canonical.
	for case in cases:
		if case["expected_merged"] is None:
			continue
		texts = list(case["layers"]) + [case["input"]]
		doc = shcl.Document.parse(texts[0])
		for t in texts[1:]:
			doc.merge(shcl.Document.parse(t))
		for line in case["merge_sets"].split("\n"):
			if line == "" or line.startswith("#"):
				continue
			eq = line.find("=")
			if eq < 0:
				raise SystemExit(f"{case['name']}: bad merge.sets line: {line}")
			if not doc.set_string(line[:eq], line[eq + 1:]):
				raise SystemExit(f"{case['name']}: merge.set did not apply: {line}")
		got = doc.to_canonical()
		# Reads answered by the merged document itself, not just its text: a
		# merged arena holds dropped nodes, a rebuilt index and cloned child
		# lists, and only a read walks those. instances() is left out because it
		# hands back the source spelling, which canonical output may rewrite.
		# Same fixture in every runner.
		mback = shcl.Document.parse(got)
		if doc.paths() != mback.paths():
			fails.append(f"{case['name']}: merged paths differ from a reparse")
		for mp in doc.paths():
			if doc.count(mp) != mback.count(mp):
				fails.append(f"{case['name']}: merged count {mp}")
			if doc.children(mp) != mback.children(mp):
				fails.append(f"{case['name']}: merged children {mp}")
			mx, my = doc.read_string(mp), mback.read_string(mp)
			if (mx.value, mx.status) != (my.value, my.status):
				fails.append(f"{case['name']}: merged read {mp}")
			mx, my = doc.read_string_array(mp), mback.read_string_array(mp)
			if (mx.value, mx.status, mx.slots) != (my.value, my.status, my.slots):
				fails.append(f"{case['name']}: merged array read {mp}")
		if got != case["expected_merged"]:
			fails.append(f"{case['name']}: merged output differs from expected-merged.shcl")
		if shcl.Document.parse(got).to_canonical() != got:
			fails.append(f"{case['name']}: merged output is not a fmt fixpoint")

	# Generation dimension: generate on the schema must reproduce the golden
	# starter config, and that output must itself load cleanly.
	for case in cases:
		if case["init_schema"] is None:
			continue
		text, ifaults = shcl.generate(shcl.Document.parse(case["init_schema"]))
		if ifaults:
			fails.append(f"{case['name']}: init schema has faults")
			continue
		if text != case["expected_init"]:
			fails.append(f"{case['name']}: init output differs from expected-init.shcl")
		# The footer is the only difference the flag makes: everything before
		# it is byte-for-byte what the default run produced.
		bare, _ = shcl.generate(shcl.Document.parse(case["init_schema"]), True)
		if not bare or not text.startswith(bare):
			fails.append(f"{case['name']}: --no-banner output is not a prefix of the default")
		elif "This config file format is SHCL." not in text[len(bare):]:
			fails.append(f"{case['name']}: default init output is missing the format footer")
		# Valid SHCL, and not so much as a hint: a starter that hints on its own
		# first lines (H002 from a parent re-opened after another field) teaches
		# a reader to ignore them.
		gdoc = shcl.Document.parse(text)
		if gdoc.diagnostics():
			fails.append(f"{case['name']}: generated starter does not load cleanly: {gdoc.diagnostics()}")
		# And it must satisfy the very schema that produced it - case 026's
		# golden once failed its own schema (repeat lower bound and a
		# materialized wildcard were ignored).
		sdoc = shcl.Document.parse(case["init_schema"])
		if any(d.severity == shcl.Severity.Error for d in gdoc.validate(sdoc)):
			fails.append(f"{case['name']}: generated starter fails its own schema")

	# Migration dimension: migrate on the input must reproduce the golden byte
	# for byte, and the golden's load diagnostics are pinned beside it, so a
	# rewrite that no longer loads cannot pass. A fmt fixpoint is not required,
	# since migrate keeps the author's layout; the migrate fixpoint is checked
	# next.
	for case in cases:
		if case["expected_migrate"] is None:
			continue
		got = shcl.migrate(case["input"], True).text
		if got != case["expected_migrate"]:
			fails.append(f"{case['name']}: migrate output differs from expected-migrate.shcl")
		if _diag_text(got) != case["expected_migrate_diags"]:
			fails.append(f"{case['name']}: migrated text's diagnostics differ from expected-migrate-diags.txt")
	for case in cases:
		once = shcl.migrate(case["input"], True).text
		if shcl.migrate(once, True).text != once:
			fails.append(f"{case['name']}: migrate changes its own output")
	# Over every input, not only the migrate cases: the stamp is the one
	# difference, and a file is current exactly when its Format line says so.
	for case in cases:
		for from_v2 in (True, False):
			stamped = shcl.migrate(case["input"], from_v2)
			unstamped = shcl.migrate_unstamped(case["input"], from_v2)
			if (unstamped.current, unstamped.ambiguous, unstamped.lost) != (stamped.current, stamped.ambiguous, stamped.lost):
				fails.append(f"{case['name']}: counts differ without the stamp")
			if shcl.FORMAT_LINE_HEAD in unstamped.text and shcl.FORMAT_LINE_HEAD not in case["input"]:
				fails.append(f"{case['name']}: migrate_unstamped wrote a Format line")
			# The stamp's lines end the way most of the input's lines do.
			crlf = case["input"].count("\r\n")
			eol = "\r\n" if crlf > case["input"].count("\n") - crlf else "\n"
			stamp_want = unstamped.text
			if not stamped.current and stamped.text != unstamped.text:
				if stamp_want and not stamp_want.endswith("\n"):
					stamp_want += eol
				stamp_want += shcl.FORMAT_LINE + eol
				if unstamped.text != case["input"]:
					stamp_want += shcl.MIGRATED_LINE + eol
			if stamped.text != stamp_want:
				fails.append(f"{case['name']}: the stamp is not the only difference")
			named = shcl.format_version(case["input"])
			if stamped.current != (named is not None and named >= shcl.FORMAT_MAJOR):
				fails.append(f"{case['name']}: current disagrees with format_version")

	# Diagnostics: count, line, severity, and stable code per case - the same
	# shape `check` prints to stdout at Standard (its cross-binding contract).
	for case in cases:
		if _diag_text(case["input"]) != case["expected_diags"]:
			fails.append(f"{case['name']}: diagnostics differ from expected-diags.txt")

	# Schema dimension: golden = the exact `check --schema` stdout at Standard
	# (doc parse diags, then validation diags, then the summary). A schema that
	# does not load cleanly is a single V099, mirroring the CLI. It comes from
	# validate() itself, and load_and_validate has to give the same list, so
	# every entry point is held to the one golden.
	for case in cases:
		if case["schema"] is None:
			continue
		doc = shcl.Document.parse(case["input"])
		diags = list(doc.diagnostics())
		sdoc = shcl.Document.parse(case["schema"])
		diags.extend(doc.validate(sdoc))
		if not any(sd.severity == shcl.Severity.Error for sd in sdoc.diagnostics()):
			shcl.suppress_declared_repeats(sdoc, diags)
			shcl.suppress_declared_reopens(sdoc, diags)
		got = ""
		errors = 0
		for d in diags:
			got += f"line {d.line}: {d.severity.name}: {d.code}\n"
			if d.severity == shcl.Severity.Error:
				errors += 1
		one_shot = shcl.Document.load_and_validate(case["input"], case["schema"], shcl.Strictness.Standard)
		lv = "".join(f"line {d.line}: {d.severity.name}: {d.code}\n" for d in one_shot.diagnostics())
		if lv != got:
			fails.append(f"{case['name']}: load_and_validate disagrees with parse then validate")
		if errors > 0:
			got += f"failed: {len(diags)} diagnostic(s), {errors} error(s)\n"
		else:
			got += f"ok ({len(diags)} diagnostic(s))\n"
		if got != case["expected_validate"]:
			fails.append(f"{case['name']}: validation output differs from expected-validate.txt")

	# The canonical formatter must match expected.shcl and be a fixpoint.
	for case in cases:
		got = shcl.Document.parse(case["input"]).to_canonical()
		if got != case["expected"]:
			fails.append(f"{case['name']}: canonical output differs from expected.shcl")
		again = shcl.Document.parse(got).to_canonical()
		if again != got:
			fails.append(f"{case['name']}: formatter is not idempotent")

	# Typed reads must match expected value + status.
	for case in cases:
		for n, line in enumerate(case["reads"].split("\n")):
			if n == 0 or not line.strip():
				continue
			cols = line.split("\t")
			if len(cols) < 4:
				fails.append(f"{case['name']}: reads.tsv line {n + 1} too short")
				continue
			query, kind, expected, status = cols[0], cols[1], cols[2], cols[3]
			level = parse_level(cols[4] if len(cols) > 4 else None)
			at = f"{case['name']}: reads.tsv line {n + 1} ({query} {kind})"

			if kind == "load":
				try:
					shcl.Document.parse_with(case["input"], level)
					ok = True
				except shcl.LoadError:
					ok = False
				want = {"ok": True, "fail": False}.get(expected)
				if want is None:
					fails.append(f"{at}: bad load expectation '{expected}'")
				elif ok != want:
					fails.append(f"{at}: load outcome (got {ok}, want {want})")
				continue

			try:
				doc = shcl.Document.parse_with(case["input"], level)
			except shcl.LoadError as e:
				fails.append(f"{at}: load failed but reads.tsv has reads there: {e}")
				continue

			if kind == "schema":
				got = shcl.schema_ref(case["input"]) or "-"
				if got != expected:
					fails.append(f"{at}: schema got {got!r} want {expected!r}")
				continue
			if kind == "lost":
				if str(doc.lost_count()) != expected:
					fails.append(f"{at}: lost got {doc.lost_count()} want {expected}")
				continue
			if kind == "count":
				if str(doc.count(query)) != expected:
					fails.append(f"{at}: count got {doc.count(query)} want {expected}")
				# A status other than `-` pins the read_ twin too.
				rc = doc.read_count(query)
				if status != "-" and (str(rc.value), rc.status.name) != (expected, status):
					fails.append(f"{at}: read_count got {rc.value} {rc.status.name} want {expected} {status}")
				continue
			if kind == "instances":
				got = "|".join(doc.instances(query))
				if got != expected:
					fails.append(f"{at}: instances got {got!r} want {expected!r}")
				ri = doc.read_instances(query)
				if status != "-" and ("|".join(ri.value), ri.status.name) != (expected, status):
					fails.append(f"{at}: read_instances got {ri.value!r} {ri.status.name} want {expected!r} {status}")
				continue
			if kind == "children":
				got = "|".join(doc.children(query))
				if got != expected:
					fails.append(f"{at}: children got {got!r} want {expected!r}")
				rk = doc.read_children(query)
				if status != "-" and ("|".join(rk.value), rk.status.name) != (expected, status):
					fails.append(f"{at}: read_children got {rk.value!r} {rk.status.name} want {expected!r} {status}")
				continue
			if kind == "paths":
				got = "|".join(doc.paths())
				if got != expected:
					fails.append(f"{at}: paths got {got!r} want {expected!r}")
				continue
			if kind == "instance_paths":
				got = "|".join(doc.instance_paths())
				if got != expected:
					fails.append(f"{at}: instance_paths got {got!r} want {expected!r}")
				continue
			if kind == "comments":
				got = "|".join(doc.comments(query))
				if got != expected:
					fails.append(f"{at}: comments got {got!r} want {expected!r}")
				continue

			got_value, got_status, got_slots = scalar_read(doc, kind, query)
			if got_status.name != status:
				fails.append(f"{at}: status got {got_status.name} want {status}")
			if expected != "-" and got_value != expected:
				fails.append(f"{at}: value got {got_value!r} want {expected!r}")
			# Optional 6th column: per-slot statuses, |-joined (needs col 5 set).
			if len(cols) > 5:
				got = "|".join(st.name for st in got_slots)
				if got != cols[5]:
					fails.append(f"{at}: slots got {got!r} want {cols[5]!r}")

	corpus_lines()
	if fails:
		for f in fails:
			sys.stderr.write("FAIL " + f + "\n")
		sys.stderr.write(f"conformance: {len(fails)} failure(s)\n")
		return 1
	test_id("EloioKn", "paths_enumeration_shape")
	# paths(): file order, deduplicated, non-bare segments quoted so every
	# path resolves. Same fixture is pinned in every runner.
	pdoc = shcl.Document.parse('a: 1\na.b: 2\n"q n": 3\nx:\n\tb: 4\nx.b: 5\n')
	if pdoc.paths() != ["a", "a.b", '"q n"', "x", "x.b"]:
		raise SystemExit(f"paths() fixture mismatch: {pdoc.paths()}")
	for p in pdoc.paths():
		if pdoc.count(p) < 1:
			raise SystemExit("emitted path does not resolve: " + p)
	# quote_segment: same spelling both directions, injection-safe.
	if (shcl.quote_segment("port"), shcl.quote_segment("q n"), shcl.quote_segment("a.b")) != ("port", '"q n"', '"a.b"'):
		raise SystemExit("quote_segment spelling drift")
	qr = pdoc.read_int(shcl.quote_segment("q n"))
	if (qr.value, qr.status) != (3, shcl.Status.Good):
		raise SystemExit("quoted segment read failed")
	test_id("Elp3cOj", "one_shot_load_and_validate")
	# One combined diagnostics list (parse first, then validation) and an
	# error predicate, so recover-and-continue can't read as success by
	# accident. Same fixture in every runner.
	otext = ": nope\nport: x\n"
	oschema = "field: port\n\ttype: int\n"
	odoc = shcl.Document.load_and_validate(otext, oschema, shcl.Strictness.Standard)
	ocodes = [d.code for d in odoc.diagnostics()]
	if ocodes != ["E014", "V003"]:
		raise SystemExit(f"load_and_validate codes got {ocodes}")
	if odoc.error_count() != 2:
		raise SystemExit(f"error_count got {odoc.error_count()}")
	if odoc.read_string("port").value != "x":  # doc still usable
		raise SystemExit("load_and_validate doc not readable")
	# Commented out 2026-10-08: Strict raises here as it does in parse_with
	# (2026100717500012); strict_fails_the_same_from_every_entry_point has it.
	# # Strict never raises here; the diagnostics are the answer.
	# ostrict = shcl.Document.load_and_validate(otext, oschema, shcl.Strictness.Strict)
	# if ostrict.error_count() < 2:
	# 	raise SystemExit(f"strict error_count got {ostrict.error_count()}")
	try:
		shcl.Document.load_and_validate(otext, oschema, shcl.Strictness.Strict)
		raise SystemExit("strict load_and_validate did not raise")
	except shcl.LoadError as e:
		if e.document is None or e.document.error_count() != 2:
			raise SystemExit("strict load_and_validate lost its document") from e
	# An empty schema declares nothing and validates nothing.
	oplain = shcl.Document.load_and_validate("a: 1\n", "", shcl.Strictness.Standard)
	if (oplain.error_count(), len(oplain.diagnostics())) != (0, 0):
		raise SystemExit("empty-schema load_and_validate not clean")
	test_id("Es9mP70", "strict_fails_the_same_from_every_entry_point")
	# Strict fails the load on any error diagnostic, from every entry point,
	# with the document inside the error. The file tier and the one-shot gave
	# a plain document where parse_with raised. Same fixture in every runner.
	with tempfile.TemporaryDirectory() as std_dir:
		sf = os.path.join(std_dir, "t.shcl")
		stext = ": nope\nport: 1\n"
		with open(sf, "w", encoding="utf-8", newline="") as fh:
			fh.write(stext)
		sschema = "field: port\n\ttype: int\n"
		strict = shcl.Strictness.Strict
		D = shcl.Document
		sruns = [
			("parse_with", lambda: D.parse_with(stext, strict)),
			("parse_limited", lambda: D.parse_limited(stext, strict)),
			("parse_keep_lines", lambda: D.parse_keep_lines(stext, strict)),
			("load_and_validate", lambda: D.load_and_validate(stext, sschema, strict)),
			("load_file_with", lambda: D.load_file_with(sf, strict)),
			("load_file_keep_lines", lambda: D.load_file_keep_lines(sf, strict)),
		]
		for sname, srun in sruns:
			try:
				srun()
				raise SystemExit(f"{sname}: a strict load with an error did not raise")
			except shcl.LoadError as e:
				if [d.code for d in e.diagnostics] != ["E014"]:
					raise SystemExit(f"{sname}: diagnostics {[d.code for d in e.diagnostics]}") from e
				if e.document is None or e.document.get_int("port") != 1:
					raise SystemExit(f"{sname}: the document does not come back") from e
		# A schema finding is an error in the same list, so it fails the
		# one-shot at Strict too.
		try:
			D.load_and_validate("port: x\n", sschema, strict)
			raise SystemExit("a schema finding at Strict did not raise")
		except shcl.LoadError as e:
			if [d.code for d in e.diagnostics] != ["V003"]:
				raise SystemExit(f"schema finding at Strict: {[d.code for d in e.diagnostics]}") from e
		# Below Strict nothing fails, and the file status says HadErrors.
		standard = shcl.Strictness.Standard
		D.parse_with(stext, standard)
		D.parse_limited(stext, standard)
		D.parse_keep_lines(stext, standard)
		if D.load_and_validate(stext, sschema, standard).error_count() != 1:
			raise SystemExit("load_and_validate at Standard")
		if D.load_file_with(sf, standard)[1] != shcl.FileStatus.HadErrors:
			raise SystemExit("load_file_with at Standard")
		if D.load_file_keep_lines(sf, standard)[1] != shcl.FileStatus.HadErrors:
			raise SystemExit("load_file_keep_lines at Standard")
		# A file that could not be read has no diagnostics, so Strict gives
		# its status like any other level.
		snone = os.path.join(std_dir, "none.shcl")
		if D.load_file_with(snone, strict)[1] != shcl.FileStatus.NotFound:
			raise SystemExit("load_file_with on a missing file")
		if D.load_file_keep_lines(snone, strict)[1] != shcl.FileStatus.NotFound:
			raise SystemExit("load_file_keep_lines on a missing file")
	test_id("Eqzz38d", "one_shot_load_reports_a_broken_schema")
	# A schema that does not load would otherwise drop the constraints on its
	# broken lines, or report every field as unknown - blaming the document.
	# Same fixture in every runner.
	bschema = "field: apikey\n\ttype: string\n  required: true\n"
	bdoc = shcl.Document.load_and_validate("host: example\n", bschema, shcl.Strictness.Standard)
	bds = bdoc.diagnostics()
	if [d.code for d in bds] != ["V099"]:
		raise SystemExit(f"broken schema: expected only the schema fault, got {[d.code for d in bds]}")
	if bdoc.error_count() != 1:
		raise SystemExit(f"broken schema: error_count got {bdoc.error_count()}")
	# A schema that loads still validates normally.
	if shcl.Document.load_and_validate("host: example\n", "field: host\n", shcl.Strictness.Standard).error_count() != 0:
		raise SystemExit("loading schema: load_and_validate not clean")
	# An empty schema still means "skip validation", not "everything unknown".
	if shcl.Document.load_and_validate("host: example\n", "", shcl.Strictness.Standard).error_count() != 0:
		raise SystemExit("empty schema: load_and_validate not clean")
	test_id("Es8Oq5D", "validate_and_generate_report_a_broken_schema")
	# The quote never closes, so the max line is lost and a parse then
	# validate passed 99999 with no word. Same fixture in every runner.
	qschema = shcl.Document.parse('field: port\n\ttype: int\n\tmax: "65535\n')
	qvs = shcl.Document.parse("port: 99999\n").validate(qschema)
	if [(d.line, d.severity, d.code) for d in qvs] != [(0, shcl.Severity.Error, "V099")]:
		raise SystemExit(f"broken schema: validate got {[d.code for d in qvs]}, want a lone V099")
	qtext, qfaults = shcl.generate(qschema, True)
	if qtext != "" or [d.code for d in qfaults] != ["V099"]:
		raise SystemExit(f"broken schema: generate got {qtext!r}, {[d.code for d in qfaults]}, want a lone V099")
	# A document that came through load_and_validate holds V codes of its own,
	# and they are not load errors when it is used as a schema.
	qchecked = shcl.Document.load_and_validate("field: port\n", "field: other\n", shcl.Strictness.Standard)
	if not qchecked.diagnostics() or qchecked.diagnostics()[0].code != "V001":
		raise SystemExit("checked schema: want V001 first")
	if shcl.Document.parse("port: 1\n").validate(qchecked):
		raise SystemExit("checked schema as a schema: validate not clean")
	test_id("Eqzz38e", "nul_name_does_not_satisfy_a_dotted_schema_path")
	# The unknown-field chain key is length-prefixed, not NUL-joined: a single
	# field whose name literally contains a NUL must not impersonate the
	# two-segment path x.y. Same fixture in every runner.
	nschema = shcl.Document.parse("field: x.y\n")
	nvs = shcl.Document.parse("\"x\x00y\": 1\n").validate(nschema)
	if len(nvs) != 1:
		raise SystemExit(f"NUL-bearing name slipped past the sweep: {[d.code for d in nvs]}")
	if nvs[0].code != "V001" or not nvs[0].message.startswith("unknown field "):
		raise SystemExit(f"NUL name: got {nvs[0].code} {nvs[0].message!r}")
	# The genuinely two-segment spelling still validates clean.
	if shcl.Document.parse("x:\n\ty: 1\n").validate(nschema) != []:
		raise SystemExit("x.y did not validate clean")
	test_id("Eqzz38f", "docstrings_come_first")
	# A docstring below the first statement is an inert expression, and the
	# method has no documentation. merge lost its own that way, and no linter
	# says so.
	if not (shcl.Document.merge.__doc__ or "").strip():
		raise SystemExit("Document.merge has no docstring")
	with open(shcl.__file__, encoding="utf-8") as src:
		stree = ast.parse(src.read())
	for snode in ast.walk(stree):
		if isinstance(snode, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
			for sst in snode.body[1:]:
				if isinstance(sst, ast.Expr) and isinstance(sst.value, ast.Constant) and isinstance(sst.value.value, str):
					raise SystemExit(f"shcl.py:{sst.lineno}: a string statement below the first one documents nothing")
	test_id("Es9JVrZ", "bad_path_reads_say_bad_path")
	# A path the scanner refuses, or one with a value part, is BadPath on every
	# read with a status, where a path that parses and finds nothing stays
	# NotFound. The no-status calls give their empty answer and _or its
	# default. Same fixture in every runner.
	bpdoc = shcl.Document.parse("site: a\n\tport: 1\n")
	if bpdoc.read_int("site(0).port").status is not shcl.Status.Good:
		raise SystemExit(f"site(0).port {bpdoc.read_int('site(0).port')!r}")
	if bpdoc.read_int("nope").status is not shcl.Status.NotFound:
		raise SystemExit(f"nope {bpdoc.read_int('nope')!r}")
	for bpath in ("site[0].port", "site(.port", "site..port", "", "user name", "site.port: 1", "h:p"):
		bpr = bpdoc.read_int(bpath)
		if (bpr.status, bpr.value, bpr.raw) != (shcl.Status.BadPath, 0, None):
			raise SystemExit(f"read_int({bpath!r}) {bpr!r}")
		for bpread in (
			bpdoc.read_float, bpdoc.read_bool, bpdoc.read_string, bpdoc.read_raw,
			bpdoc.read_raw_info, bpdoc.read_datetime, bpdoc.read_duration, bpdoc.read_size,
			bpdoc.read_float_array, bpdoc.read_bool_array, bpdoc.read_string_array,
			bpdoc.read_datetime_array,
		):
			if bpread(bpath).status is not shcl.Status.BadPath:
				raise SystemExit(f"{bpread.__name__}({bpath!r}) {bpread(bpath)!r}")
		bpa = bpdoc.read_int_array(bpath)
		if (bpa.status, bpa.value, bpa.slots) != (shcl.Status.BadPath, [], []):
			raise SystemExit(f"read_int_array({bpath!r}) {bpa!r}")
		for bpget in (bpdoc.get_int, bpdoc.get_string_array):
			bpraised = None
			try:
				bpget(bpath)
			except shcl.StatusError as e:
				bpraised = e.status
			if bpraised is not shcl.Status.BadPath:
				raise SystemExit(f"{bpget.__name__}({bpath!r}) raised {bpraised}")
		if bpdoc.get_int(bpath, 8) != 8 or bpdoc.get_int_or(bpath, 8) != 8:
			raise SystemExit(f"get_int default ({bpath!r})")
		if bpdoc.count(bpath) != 0 or bpdoc.instances(bpath) != []:
			raise SystemExit(f"count/instances ({bpath!r})")
		if bpath and bpdoc.children(bpath) != []:
			raise SystemExit(f"children({bpath!r}) {bpdoc.children(bpath)}")
	# The empty path is the top level for children(), as documented.
	if bpdoc.children("") != ["site"]:
		raise SystemExit(f"children('') {bpdoc.children('')}")
	# Last in the order, so a worst-of aggregate puts it on top; its value is
	# the CLI's usage exit.
	if list(shcl.Status)[-1] is not shcl.Status.BadPath or shcl.Status.BadPath.value != 1:
		raise SystemExit(f"BadPath order or value {list(shcl.Status)}")
	test_id("EsDQqYf", "list_reads_say_bad_path")
	# The list reads' status twins: BadPath for a path that cannot be read,
	# NotFound for one that matches nothing, Good otherwise, with the value the
	# plain call gives. Same fixture in every runner.
	ldoc = shcl.Document.parse("site: a\n\tport: 1\nsite: b\n")
	lgood = shcl.Status.Good
	lc = ldoc.read_count("site")
	if (lc.value, lc.status, lc.line) != (2, lgood, 0):
		raise SystemExit(f"read_count(site) {lc!r}")
	lc = ldoc.read_count("site(0)")
	if (lc.value, lc.status, lc.line) != (1, lgood, 1):
		raise SystemExit(f"read_count(site(0)) {lc!r}")
	# An unresolved wildcard slot still counts, as in count().
	lc = ldoc.read_count("site(*).port")
	if (lc.value, lc.status) != (2, lgood):
		raise SystemExit(f"read_count(site(*).port) {lc!r}")
	for lpath in ("nope", "nope(*)"):
		if ldoc.read_count(lpath).status is not shcl.Status.NotFound:
			raise SystemExit(f"read_count({lpath!r}) {ldoc.read_count(lpath)!r}")
	li = ldoc.read_instances("site")
	if (li.value, li.status) != (["a", "b"], lgood):
		raise SystemExit(f"read_instances(site) {li!r}")
	li = ldoc.read_instances("site(*).port")
	if (li.value, li.status) != (["1", ""], lgood):
		raise SystemExit(f"read_instances(site(*).port) {li!r}")
	if ldoc.read_instances("nope").status is not shcl.Status.NotFound:
		raise SystemExit(f"read_instances(nope) {ldoc.read_instances('nope')!r}")
	lk = ldoc.read_children("site(0)")
	if (lk.value, lk.status, lk.line) != (["port"], lgood, 1):
		raise SystemExit(f"read_children(site(0)) {lk!r}")
	# An empty section is Good, a missing one NotFound.
	lk = ldoc.read_children("site(1)")
	if (lk.value, lk.status) != ([], lgood):
		raise SystemExit(f"read_children(site(1)) {lk!r}")
	if ldoc.read_children("nope").status is not shcl.Status.NotFound:
		raise SystemExit(f"read_children(nope) {ldoc.read_children('nope')!r}")
	lk = ldoc.read_children("")
	if ("|".join(lk.value), lk.status) != ("site|site", lgood):
		raise SystemExit(f"read_children('') {lk!r}")
	for lpath in ("site[0].port", "site(.port", "site..port", "", "user name", "site.port: 1", "h:p"):
		lc = ldoc.read_count(lpath)
		if (lc.value, lc.status, lc.slots) != (0, shcl.Status.BadPath, []):
			raise SystemExit(f"read_count({lpath!r}) {lc!r}")
		li = ldoc.read_instances(lpath)
		if (li.value, li.status) != ([], shcl.Status.BadPath):
			raise SystemExit(f"read_instances({lpath!r}) {li!r}")
		lk = ldoc.read_children(lpath)
		if lpath and (lk.value, lk.status) != ([], shcl.Status.BadPath):
			raise SystemExit(f"read_children({lpath!r}) {lk!r}")
	test_id("ElouJ8N", "check_set_path_names_the_failure")
	# The path's half of a setter's status. Same fixture in every runner.
	wdoc = shcl.Document.parse("a:\n\tb: 1\n")
	for wpath, wwant in (
		("a.b", shcl.SetStatus.Ok),
		("a.new(Boston).x", shcl.SetStatus.Ok),   # creatable
		("", shcl.SetStatus.BadPath),
		("a..b", shcl.SetStatus.BadPath),
		("a.b: 2", shcl.SetStatus.ValueInPath),
		("a(*).b", shcl.SetStatus.Wildcard),
		("a(5).b", shcl.SetStatus.NoSuchIndex),
		("nope(0).b", shcl.SetStatus.NoSuchIndex),
		(".".join(["d"] * 513), shcl.SetStatus.TooDeep),
		# A literal line break is writable wherever a path can have one: a name
		# emits through the name escaper and a selector value through the value
		# emitter, and both write a break \n and read it back as one. The
		# selector was refused while the value emitter still wrote elements in
		# their source spelling and had nothing to escape with. Not
		# corpus-pinnable - an ops line cannot contain a raw newline.
		('a("p\nq").b', shcl.SetStatus.Ok),
		('"x\ny".b', shcl.SetStatus.Ok),
		('"x\\ny".b', shcl.SetStatus.Ok),
	):
		wgot = wdoc.check_set_path(wpath)
		if wgot is not wwant:
			raise SystemExit(f"check_set_path({wpath!r}) got {wgot} want {wwant}")
	# The probe never creates: the doc is unchanged after all of the above.
	if wdoc.count("a") != 1:
		raise SystemExit("check_set_path probe created an instance")
	if wdoc.paths() != ["a", "a.b"]:
		raise SystemExit(f"check_set_path probe changed paths: {wdoc.paths()}")
	test_id("Es9S4kL", "refused_values_pass_the_path_check")
	# The values a setter refuses on a path check_set_path passes. Each one
	# here is refused, writes nothing, and the path checks Ok. Same fixture in
	# every runner, plus Python's own: an int outside the 64-bit range.
	# setter_status_names_each_refusal has the status each one gives.
	rtext = "ports: [80, 443]\nsec:\n\tx: 1\n"
	rwant = shcl.Document.parse(rtext).to_canonical()
	for rwhat, rpath, rset in (
		("NaN float", "f", lambda d: d.set_float("f", math.nan)),
		("infinite float", "f", lambda d: d.set_float("f", math.inf)),
		("infinite float in an array", "f", lambda d: d.set_float_array("f", [1.0, -math.inf])),
		("month 13", "t", lambda d: d.set_datetime("t", shcl.ShclDateTime(date=(2026, 13, 1)))),
		("raw info with #", "r", lambda d: d.set_raw("r", "body", "sh # x")),
		("raw info with a line break", "r", lambda d: d.set_raw("r", "body", "sh\nx")),
		("raw body line ending in CR", "r", lambda d: d.set_raw("r", "a\r\nb", "")),
		("comment with a line break", "sec.x", lambda d: d.set_comment("sec.x", "a\nb")),
		("literal of two values", "l", lambda d: d.set_literal("l", "a, b")),
		("literal with an open quote", "l", lambda d: d.set_literal("l", '"abc')),
		("literal with a line break", "l", lambda d: d.set_literal("l", "a\nb")),
		("array on a field with lines under it", "sec", lambda d: d.set_int_array("sec", [1, 2])),
		("literal array on a field with lines under it", "sec", lambda d: d.set_literal("sec", "[1, 2]")),
		# The path check says UnderArray for this one now (2026100907362300),
		# since no value could go there. setter_status_names_each_refusal has
		# it.
		# ("field under an array", "ports.x", lambda d: d.set_int("ports.x", 1)),
		("int past 64 bits", "i", lambda d: d.set_int("i", 1 << 64)),
		("int array past 64 bits", "i", lambda d: d.set_int_array("i", [1, -(1 << 63) - 1])),
	):
		rdoc = shcl.Document.parse(rtext)
		if rset(rdoc) is shcl.SetStatus.Ok:
			raise SystemExit(f"{rwhat}: the setter wrote")
		if rdoc.check_set_path(rpath) is not shcl.SetStatus.Ok:
			raise SystemExit(f"{rwhat}: check_set_path = {rdoc.check_set_path(rpath)}")
		if rdoc.to_canonical() != rwant:
			raise SystemExit(f"{rwhat}: wrote {rdoc.to_canonical()!r}")
	test_id("EsDeik0", "setter_status_values_in_order")
	# Every status a setter gives, in the order every binding numbers them.
	# The other three print the same names. Same fixture in every runner.
	snames = [st.name for st in shcl.SetStatus]
	if snames != [
		"Ok", "BadPath", "ValueInPath", "Wildcard", "NoSuchIndex", "TooDeep", "Multiple", "UnderArray",
		"HasChildren", "NotFinite", "BadDateTime", "BadRawInfo", "BadRawBody", "BadComment", "NotOneValue",
		"NotUtf8", "OutOfRange", "NoReadBack",
	]:
		raise SystemExit(f"SetStatus names {snames}")
	if [st.value for st in shcl.SetStatus] != list(range(len(snames))):
		raise SystemExit(f"SetStatus values {[st.value for st in shcl.SetStatus]}")
	test_id("EsDeiqL", "setter_status_only_ok_is_true")
	# Python-only: only Ok is true, so a caller's `if not doc.set_int(...)`
	# from when setters gave a bool still means refused. A plain IntEnum would
	# make Ok, the 0, the false one.
	for st in shcl.SetStatus:
		if bool(st) != (st is shcl.SetStatus.Ok):
			raise SystemExit(f"bool({st}) is {bool(st)}")
	if isinstance(shcl.SetStatus.Ok, int):
		raise SystemExit("SetStatus.Ok compares as an int")
	tdoc = shcl.Document.parse("p: 1\np: 2\n")
	if tdoc.set_int("p", 3) or not tdoc.set_int("q", 3):
		raise SystemExit(f"a setter's truth value: {tdoc.to_canonical()!r}")
	test_id("EsDeim8", "setter_status_names_each_refusal")
	# A setter's status names why it wrote nothing. A path reason is the one
	# check_set_path gives, and wins over a value reason when both apply, since
	# the path is what to fix first; a value reason comes with a path that
	# checks Ok. A default form on a path already there writes nothing and
	# gives what the plain setter would. Same fixture in every runner, plus
	# Python's own NotUtf8 and OutOfRange cases. NoReadBack has no case: no
	# value is known that fails to read back.
	S = shcl.SetStatus
	stext = "a:\n\tb: 1\nports: [80, 443]\nsec:\n\tx: 1\nport: 1\nport: 2\n"
	smonth13 = shcl.ShclDateTime(date=(2026, 13, 1))
	sdeep = ".".join(["d"] * 513)
	sbad = "a\udcffb"
	for spath, swant, sset in (
		("a.b", S.Ok, lambda d: d.set_int("a.b", 2)),
		("a.c", S.Ok, lambda d: d.set_float("a.c", 2.5)),
		("a.b", S.Ok, lambda d: d.set_int_default("a.b", 9)),
		("", S.BadPath, lambda d: d.set_int("", 1)),
		("a..b", S.BadPath, lambda d: d.set_string("a..b", "v")),
		("a.b: 2", S.ValueInPath, lambda d: d.set_int("a.b: 2", 1)),
		("a(*).b", S.Wildcard, lambda d: d.set_int("a(*).b", 1)),
		("a(5).b", S.NoSuchIndex, lambda d: d.set_int("a(5).b", 1)),
		(sdeep, S.TooDeep, lambda d: d.set_int(sdeep, 1)),
		("port", S.Multiple, lambda d: d.set_int("port", 9)),
		("ports.x", S.UnderArray, lambda d: d.set_int("ports.x", 1)),
		("ports.x.y", S.UnderArray, lambda d: d.set_int("ports.x.y", 1)),
		("ports.x", S.UnderArray, lambda d: d.set_comment("ports.x", "c")),
		("ports.x", S.UnderArray, lambda d: d.set_int_default("ports.x", 1)),
		("sec", S.HasChildren, lambda d: d.set_int_array("sec", [1, 2])),
		("sec", S.HasChildren, lambda d: d.set_string_array("sec", ["v"])),
		("sec", S.HasChildren, lambda d: d.set_literal("sec", "[1, 2]")),
		("f", S.NotFinite, lambda d: d.set_float("f", math.nan)),
		("f", S.NotFinite, lambda d: d.set_float_array("f", [1.0, math.inf])),
		("a.b", S.NotFinite, lambda d: d.set_float_default("a.b", math.nan)),
		("t", S.BadDateTime, lambda d: d.set_datetime("t", smonth13)),
		("r", S.BadRawInfo, lambda d: d.set_raw("r", "body", "sh # x")),
		("r", S.BadRawInfo, lambda d: d.set_raw("r", "body", "sh\nx")),
		("a.b", S.BadRawInfo, lambda d: d.set_raw_default("a.b", "body", "sh # x")),
		("r", S.BadRawBody, lambda d: d.set_raw("r", "a\r\nb", "")),
		("sec.x", S.BadComment, lambda d: d.set_comment("sec.x", "a\nb")),
		("l", S.NotOneValue, lambda d: d.set_literal("l", "a, b")),
		("l", S.NotOneValue, lambda d: d.set_literal("l", '"abc')),
		("l", S.NotOneValue, lambda d: d.set_literal("l", "a\nb")),
		("a.b", S.NotOneValue, lambda d: d.set_literal_default("a.b", "a, b")),
		# Both halves wrong: the path's reason.
		("a(*).b", S.Wildcard, lambda d: d.set_float("a(*).b", math.nan)),
		("ports.x", S.UnderArray, lambda d: d.set_literal("ports.x", "a, b")),
		("a..b", S.BadPath, lambda d: d.set_comment("a..b", "a\nb")),
		("a(5).b", S.NoSuchIndex, lambda d: d.set_raw("a(5).b", "x", "#")),
		("port", S.Multiple, lambda d: d.set_int_array("port", [1])),
		("port", S.Multiple, lambda d: d.set_float_default("port", math.nan)),
		# Python's own. Text with no UTF-8 spelling in a value is NotUtf8, in a
		# path BadPath, and an int past 64 bits OutOfRange.
		("s", S.NotUtf8, lambda d: d.set_string("s", sbad)),
		("sec.x", S.NotUtf8, lambda d: d.set_comment("sec.x", sbad)),
		("r", S.NotUtf8, lambda d: d.set_raw("r", "body", sbad)),
		("r", S.NotUtf8, lambda d: d.set_raw("r", sbad, "")),
		("l", S.NotUtf8, lambda d: d.set_literal("l", sbad)),
		("a.b", S.NotUtf8, lambda d: d.set_string_default("a.b", sbad)),
		(f'"{sbad}"', S.BadPath, lambda d: d.set_int(f'"{sbad}"', 1)),
		(f'"{sbad}".x', S.BadPath, lambda d: d.set_int(f'"{sbad}".x', 1)),
		(f"a({sbad}).x", S.BadPath, lambda d: d.set_int(f"a({sbad}).x", 1)),
		(f'a("{sbad}").x', S.BadPath, lambda d: d.set_int(f'a("{sbad}").x', 1)),
		(f'"{sbad}"', S.BadPath, lambda d: d.set_comment(f'"{sbad}"', "c")),
		(f'"{sbad}"', S.BadPath, lambda d: d.set_string(f'"{sbad}"', sbad)),
		("i", S.OutOfRange, lambda d: d.set_int("i", 1 << 64)),
		("i", S.OutOfRange, lambda d: d.set_int_array("i", [1, -(1 << 63) - 1])),
		("a.b", S.OutOfRange, lambda d: d.set_int_default("a.b", 1 << 63)),
		("a(*).b", S.Wildcard, lambda d: d.set_int("a(*).b", 1 << 64)),
	):
		sdoc = shcl.Document.parse(stext)
		sbefore = sdoc.to_canonical()
		sgot = sset(sdoc)
		if sgot is not swant:
			raise SystemExit(f"{spath!r}: got {sgot}, want {swant}")
		schecked = shcl.Document.parse(stext).check_set_path(spath)
		if schecked is not (swant if swant.value <= S.UnderArray.value else S.Ok):
			raise SystemExit(f"{spath!r}: check_set_path = {schecked}")
		if sgot is not S.Ok and sdoc.to_canonical() != sbefore:
			raise SystemExit(f"{spath!r}: wrote {sdoc.to_canonical()!r}")
	test_id("EsDeioE", "setter_status_agrees_with_the_path_check")
	setter_status_agrees_with_the_path_check()
	test_id("Es9aZSH", "repeated_path_refuses_a_setter")
	# A setter on a path that matches more than one field at any step writes
	# nothing and the path checks Multiple, so a write never says Ok where the
	# read after it would say Multiple. An index or value selector picks
	# one. Same fixture in every runner.
	mtext = "port: 1\nport: 2\nsite: a\n\troot: /x\nsite: b\n\troot: /y\nsec:\n\tk: 1\n\tk: 2\n"
	mwant = shcl.Document.parse(mtext).to_canonical()
	for mpath, mset in (
		("port", lambda d: d.set_int("port", 9)),
		("port", lambda d: d.set_string("port", "9")),
		("port", lambda d: d.set_literal("port", "9")),
		("port", lambda d: d.set_int_array("port", [9])),
		("port", lambda d: d.set_empty("port")),
		("port", lambda d: d.set_raw("port", "x", "")),
		("port", lambda d: d.set_comment("port", "c")),
		("port", lambda d: d.set_int_default("port", 9)),
		("port", lambda d: d.set_literal_default("port", "9")),
		("site.root", lambda d: d.set_string("site.root", "/z")),
		("site.new", lambda d: d.set_string("site.new", "v")),
		("site.new", lambda d: d.set_string_default("site.new", "v")),
		("sec.k", lambda d: d.set_int("sec.k", 9)),
		("sec.k.x", lambda d: d.set_int("sec.k.x", 9)),
	):
		mdoc = shcl.Document.parse(mtext)
		mgot = mset(mdoc)
		if mgot is not shcl.SetStatus.Multiple:
			raise SystemExit(f"{mpath}: the setter gave {mgot}")
		if mdoc.check_set_path(mpath) is not shcl.SetStatus.Multiple:
			raise SystemExit(f"{mpath}: check_set_path = {mdoc.check_set_path(mpath)}")
		if mdoc.to_canonical() != mwant:
			raise SystemExit(f"{mpath}: wrote {mdoc.to_canonical()!r}")
	mdoc = shcl.Document.parse(mtext)
	if not (mdoc.set_int("port(1)", 9) and mdoc.set_string("site(1).root", "/z")
			and mdoc.set_string("site(a).root", "/w") and mdoc.set_int("sec.k(0)", 7)):
		raise SystemExit("a setter naming one instance was refused")
	if (mdoc.get_int_or("port(0)", 0), mdoc.get_int_or("port(1)", 0), mdoc.get_string_or("site(b).root", ""),
			mdoc.get_string_or("site(a).root", ""), mdoc.get_int_or("sec.k(0)", 0)) != (1, 9, "/z", "/w", 7):
		raise SystemExit(f"wrote the wrong instance: {mdoc.to_canonical()!r}")
	# A remove takes every instance it matches, as a read sees them.
	if mdoc.remove("port") != 2 or mdoc.check_set_path("port") is not shcl.SetStatus.Ok:
		raise SystemExit("remove on a repeated path")
	test_id("Es9aZSJ", "setters_refuse_text_that_is_not_utf8")
	# A lone surrogate has no UTF-8 spelling, so no save could write it. Every
	# setter that takes text refuses it, as Go's refuse bytes that are not
	# UTF-8: it gives NotUtf8, writes nothing, and the path checks Ok. The same
	# cases are in the C runner.
	utext = "sec:\n\tx: 1\nsrv: a\n"
	uwant = shcl.Document.parse(utext).to_canonical()
	ubad = "a\udcffb"
	for upath, uset in (
		("s", lambda d: d.set_string("s", ubad)),
		("s", lambda d: d.set_string_default("s", ubad)),
		("s", lambda d: d.set_string_array("s", ["ok", ubad])),
		("s", lambda d: d.set_string_array_default("s", ["ok", ubad])),
		("sec.x", lambda d: d.set_comment("sec.x", ubad)),
		("r", lambda d: d.set_raw("r", ubad, "")),
		("r", lambda d: d.set_raw("r", "body", ubad)),
		("r", lambda d: d.set_raw_default("r", ubad, "")),
		("l", lambda d: d.set_literal("l", ubad)),
		("l", lambda d: d.set_literal("l", f'"{ubad}"')),
		("l", lambda d: d.set_literal("l", f"[ok, {ubad}]")),
		("l", lambda d: d.set_literal_default("l", ubad)),
		# A path that is not UTF-8 checks BadPath now, from check_set_path as
		# from the setter (2026100907362300), so these moved to
		# setter_status_names_each_refusal.
		# (f'"{ubad}"', lambda d: d.set_int(f'"{ubad}"', 1)),
		# (f'"{ubad}".x', lambda d: d.set_int(f'"{ubad}".x', 1)),
		# (f"srv({ubad}).x", lambda d: d.set_int(f"srv({ubad}).x", 1)),
		# (f'srv("{ubad}").x', lambda d: d.set_int(f'srv("{ubad}").x', 1)),
		# (f'"{ubad}"', lambda d: d.set_comment(f'"{ubad}"', "c")),
	):
		udoc = shcl.Document.parse(utext)
		ugot = uset(udoc)
		if ugot is not shcl.SetStatus.NotUtf8:
			raise SystemExit(f"{upath!r}: the setter gave {ugot}")
		if udoc.check_set_path(upath) is not shcl.SetStatus.Ok:
			raise SystemExit(f"{upath!r}: check_set_path = {udoc.check_set_path(upath)}")
		if udoc.to_canonical() != uwant:
			raise SystemExit(f"{upath!r}: wrote {udoc.to_canonical()!r}")
	test_id("Eof29pb", "setters_refuse_a_value_the_reader_refuses")
	# Each setter is the inverse of its read, so a value with no spelling the
	# reader accepts fails the write and leaves the document alone. Same
	# fixture in every runner.
	sdoc = shcl.Document.parse("z: 0\n")
	NF = shcl.SetStatus.NotFinite
	for v in (math.inf, -math.inf, math.nan):
		if (sdoc.set_float("f", v), sdoc.set_float_default("f", v), sdoc.set_float_array("f", [1.0, v])) != (NF, NF, NF):
			raise SystemExit(f"float {v} was not refused as NotFinite")
		# A default form on a path that is already there writes nothing, and
		# still refuses what the plain setter would.
		if (sdoc.set_float_default("z", v), sdoc.set_float_array_default("z", [1.0, v])) != (NF, NF):
			raise SystemExit(f"float {v} passed a default form on a present path")
	if sdoc.set_float("f", 2.5) is not shcl.SetStatus.Ok or sdoc.get_float("f") != 2.5:
		raise SystemExit("a finite float was refused")
	if sdoc.set_float_default("z", 2.5) is not shcl.SetStatus.Ok or sdoc.get_float("z") != 0:
		raise SystemExit("a finite float default on a present path was refused or written")
	DT = shcl.ShclDateTime
	bad_dts = [
		DT(),                                                  # nothing written
		DT(date=(2026, 13, 1)),                                # month 13
		DT(date=(2026, 2, 30)),                                # February 30
		DT(date=(-1, 1, 1)),                                   # negative year
		DT(time=(24, 0, None)),                                # hour 24
		DT(time=(1, 2, None), frac="5"),                       # fraction with no seconds
		DT(time=(1, 2, 3), frac=""),                           # empty fraction
		DT(time=(1, 2, 3), frac="12345678901"),                # 11 digits
		DT(time=(1, 2, None), zone=("offset", 9999)),          # +166:39
		DT(date=(2026, 1, 1), zone=("utc", None)),             # zone on a date alone
	]
	BD = shcl.SetStatus.BadDateTime
	for dt in bad_dts:
		if (sdoc.set_datetime("d", dt), sdoc.set_datetime_default("d", dt), sdoc.set_datetime_array("d", [DT(date=(2026, 1, 1)), dt])) != (BD, BD, BD):
			raise SystemExit(f"datetime {dt} was not refused as BadDateTime")
		if (sdoc.set_datetime_default("z", dt), sdoc.set_datetime_array_default("z", [DT(date=(2026, 1, 1)), dt])) != (BD, BD):
			raise SystemExit(f"datetime {dt} passed a default form on a present path")
	ok_dt = DT(date=(2026, 1, 2), time=(3, 4, 5), frac="60", zone=("offset", -90))
	if sdoc.set_datetime("d", ok_dt) is not shcl.SetStatus.Ok or str(sdoc.get_datetime("d")) != str(ok_dt):
		raise SystemExit("a valid datetime was refused or read back differently")
	if sdoc.to_canonical() != 'z: 0\n\nf: 2.5\n\nd: "2026-01-02T03:04:05.60-01:30"\n':
		raise SystemExit(f"document after the refusals: {sdoc.to_canonical()!r}")
	test_id("EryEqlx", "a_backtick_value_reads_raw_with_its_flag")
	# A backtick value is raw text the program decodes itself: read as
	# written, with its own flag beside .quoted. A setter keeps the backticks
	# when the new text fits in them, and the writer picks quotes when it does
	# not. Same fixture in every runner.
	bdoc = shcl.Document.parse("c: `#FF8800`\nq: \"x\"\nb: x\na: [`1`, b]\nn: `7`\n")
	br = bdoc.read_string("c")
	if (br.value, br.quoted, br.backtick) != ("#FF8800", True, True):
		raise SystemExit(f"backtick c: {br!r}")
	br = bdoc.read_string("q")
	if (br.quoted, br.backtick) != (True, False):
		raise SystemExit(f"backtick q: {br!r}")
	br = bdoc.read_string("b")
	if (br.quoted, br.backtick) != (False, False):
		raise SystemExit(f"backtick b: {br!r}")
	bra = bdoc.read_string_array("a")
	if (len(bra.value), bra.quoted, bra.backtick) != (2, False, False):
		raise SystemExit(f"backtick a: {bra!r}")
	bri = bdoc.read_int("n")
	if (bri.value, bri.backtick) != (7, True):
		raise SystemExit(f"backtick n: {bri!r}")
	if not bdoc.set_string("c", "#00FF00") or not bdoc.read_string("c").backtick:
		raise SystemExit("an overwrite lost the backticks")
	if not bdoc.set_string("c", "a`b") or bdoc.read_string("c").backtick:
		raise SystemExit("a backtick value holding a backtick")
	if not bdoc.to_canonical().startswith('c: "a`b"\n'):
		raise SystemExit(f"backtick fixture wrote {bdoc.to_canonical()!r}")
	test_id("EnLyQsX", "raw_block_line_endings_normalize_and_round_trip")
	# A raw body is the only content kept untrimmed, so it is the only place a
	# trailing CR survives the load - and one written back becomes CRLF, which
	# reads as neither. The whole trailing run comes off instead; a CR inside a
	# line is content and stays. Same fixture in every runner: a golden would be
	# rewritten by any platform's line-ending translation.
	rdoc = shcl.Document.parse("r:\n\t~~~\n\tone\r\r\n\ta\rb\n\t~~~\n")
	if rdoc.read_raw("r").value != "one\na\rb":
		raise SystemExit(f"raw content: {rdoc.read_raw('r').value!r}")
	rcanon = rdoc.to_canonical()
	if shcl.Document.parse(rcanon).to_canonical() != rcanon:
		raise SystemExit("raw block with CR is not a formatter fixpoint")
	test_id("Eqpzw7X", "children_and_instance_paths_walk_a_repeated_key")
	# gitsby's report: children() on a repeated key answered nothing, and a
	# walk had to know to index each instance.
	gdoc = shcl.Document.parse("account: w\n\temail: e@x\n\t\tsshkey: k1\n\temail: f@x\n\t\tsshkey: k2\n")
	if gdoc.children("account(0).email") != ["sshkey", "sshkey"]:
		raise SystemExit(f"children across instances got {gdoc.children('account(0).email')}")
	if gdoc.children("account.email(1)") != ["sshkey"]:
		raise SystemExit(f"children of one instance got {gdoc.children('account.email(1)')}")
	want_paths = [
		"account",
		"account.email(0)",
		"account.email(0).sshkey",
		"account.email(1)",
		"account.email(1).sshkey",
	]
	if gdoc.instance_paths() != want_paths:
		raise SystemExit(f"instance_paths() got {gdoc.instance_paths()}")
	if gdoc.get_string("account.email(1).sshkey") != "k2":
		raise SystemExit("an instance path did not read its node")
	test_id("EoM2uEi", "read_surface_line_quoted_children")
	# line/quoted on the read result, line(path), children(path). Same
	# fixture in every runner (C pins the same answers on shcl_quoted and
	# shcl_line; its read structs stay value+status).
	ldoc = shcl.Document.parse('a: @null\nb: "@null"\ncode:\n\thook: 1\n\thook: 2\n\tdone: 3\n')
	if ldoc.read_string("a").quoted:
		raise SystemExit("unquoted read reports quoted")
	if not ldoc.read_string("b").quoted:
		raise SystemExit("quoted read not flagged")
	if ldoc.read_string("code").quoted:
		raise SystemExit("a block reports quoted")
	if ldoc.read_string("missing").quoted:
		raise SystemExit("missing path reports quoted")
	if ldoc.read_string("b").line != 2:
		raise SystemExit(f"read line got {ldoc.read_string('b').line}")
	if ldoc.line("code.done") != 6:
		raise SystemExit(f"line() got {ldoc.line('code.done')}")
	if ldoc.line("code") != 3:
		raise SystemExit(f"line() on merged instance got {ldoc.line('code')}")
	if ldoc.line("missing") != 0:
		raise SystemExit(f"line() on missing path got {ldoc.line('missing')}")
	# lines(): the plural - a repeated field cites every binding, wildcard
	# slots keep their index (0 = unresolved), a miss is the empty list.
	if ldoc.line("code.hook") != 0:  # Multiple - the singular's gap
		raise SystemExit(f"line() on repeated field got {ldoc.line('code.hook')}")
	if ldoc.lines("code.hook") != [4, 5]:
		raise SystemExit(f"lines() got {ldoc.lines('code.hook')}")
	if ldoc.lines("code.done") != [6]:
		raise SystemExit(f"lines() single got {ldoc.lines('code.done')}")
	if ldoc.lines("a") != [1]:
		raise SystemExit(f"lines() top-level got {ldoc.lines('a')}")
	if ldoc.lines("code(*).done") != [6]:
		raise SystemExit(f"lines() wildcard got {ldoc.lines('code(*).done')}")
	if ldoc.lines("code(*).nope") != [0]:
		raise SystemExit(f"lines() unresolved slot got {ldoc.lines('code(*).nope')}")
	if ldoc.lines("missing"):
		raise SystemExit("lines() on missing path not empty")
	if ldoc.children("code") != ["hook", "hook", "done"]:
		raise SystemExit(f"children() got {ldoc.children('code')}")
	if ldoc.children("") != ["a", "b", "code"]:
		raise SystemExit(f"top-level children() got {ldoc.children('')}")
	if ldoc.children("missing"):
		raise SystemExit("children() on missing path not empty")
	# authored_name(): the author's spelling, unfolded; merged instances keep
	# the first binding's; unresolved or Multiple is empty; writer-built
	# keeps the setter path's spelling.
	sdoc2 = shcl.Document.parse("SYMBOLS: 3\nCode:\n\tx: 1\ncode:\n\ty: 2\n")
	if sdoc2.authored_name("symbols") != "SYMBOLS":
		raise SystemExit(f"authored_name(symbols) got {sdoc2.authored_name('symbols')}")
	if sdoc2.authored_name("code") != "Code":
		raise SystemExit(f"authored_name(code) got {sdoc2.authored_name('code')}")
	if sdoc2.authored_name("missing") != "":
		raise SystemExit("authored_name(missing) not empty")
	if not sdoc2.set_int("NewTop.n", 1):
		raise SystemExit("set_int NewTop.n failed")
	if sdoc2.authored_name("newtop") != "NewTop":
		raise SystemExit(f"authored_name(newtop) got {sdoc2.authored_name('newtop')}")
	# Escapes ARE resolved on a name, so both spellings of the path find the same
	# node - while authored_name still hands back the source spelling, which is
	# the one thing it is for. Same fixture in every runner.
	sdoc3 = shcl.Document.parse('"Ab◉TAB◉Cd": 2\n')
	esc_name = sdoc3.authored_name('"ab◉tab◉cd"')
	if esc_name != "Ab◉TAB◉Cd":
		raise SystemExit(f"authored_name escaped got {esc_name!r}")
	lit_name = sdoc3.authored_name('"ab\tcd"')
	if lit_name != "Ab◉TAB◉Cd":
		raise SystemExit(f"authored_name via the literal spelling got {lit_name!r}")
	if sdoc3.read_int('"ab\tcd"').value != 2:
		raise SystemExit("read via the literal spelling failed")
	# Canonical output folds the case, as it always has, and escapes the tab.
	if sdoc3.to_canonical() != '"ab◉TAB◉cd": 2\n':
		raise SystemExit(f"canonical name spelling got {sdoc3.to_canonical()!r}")
	# An array read of a one-element cell answers the same as the scalar read of
	# the same node: there is a single scalar element, which is what the flag is
	# about. More than one element, and there is none to report. Same fixture in
	# Rust and Go.
	qdoc = shcl.Document.parse('a: @null\nb: "@null"\n')
	if not qdoc.read_string_array("b").quoted:
		raise SystemExit("a one-element quoted cell reads unquoted as an array")
	if qdoc.read_string_array("a").quoted:
		raise SystemExit("a one-element bare cell reads quoted as an array")
	if shcl.Document.parse('m: ["x", "y"]\n').read_string_array("m").quoted:
		raise SystemExit("a two-element cell reported a single element's quoting")
	test_id("EomvfCu", "save_refuses_a_directory_shaped_path")
	# A path that names a directory - it ends in a separator, or its last
	# component is `.` or `..` - is not a document. A path cleanup drops the
	# trailing separator first, so a save through `f/.` used to rewrite `f` in
	# some bindings. Same fixture in every runner.
	with tempfile.TemporaryDirectory() as dtd:
		dfile = os.path.join(dtd, "f.shcl")
		with open(dfile, "w", encoding="utf-8", newline="") as fh:
			fh.write("a: 1\n")
		ddoc = shcl.Document.parse("a: 2\n")
		for suffix in ("/", "/.", "/.."):
			try:
				ddoc.save_file(dfile + suffix)
				raise SystemExit(f"save through {dfile + suffix} was accepted")
			except shcl.SaveFailed:
				pass
		if _read(dfile) != "a: 1\n":
			raise SystemExit("a refused save changed the file")
		ddoc.save_file(dfile)
		if _read(dfile) != "a: 2\n":
			raise SystemExit("the plain path did not save")
	test_id("EomsV3Y", "typed_array_setters_take_a_list")
	# A typed array setter takes a list of its type, not any iterable: a str is a
	# sequence of one-character strings, so set_string_array("abc") wrote three
	# elements, and a generator was consumed by the type check before the setter
	# read it - an empty value written at True. The three untyped setters raised
	# from inside on a non-string; they gate like their typed siblings now.
	# Python-only: the other three bindings are statically typed here.
	gdoc = shcl.Document.new()
	for setter, args in (
		("set_string_array", ("k", "abc")),
		("set_int_array", ("k", b"12")),
		("set_comment", ("k", 5)),
		("set_raw", ("k", 5, "")),
		("set_literal", ("k", 5)),
	):
		try:
			getattr(gdoc, setter)(*args)
			raise SystemExit(f"{setter} accepted the wrong type")
		except TypeError:
			pass
	gen = (x for x in [1, 2, 3])   # not a list on purpose: that is the fixture
	if not gdoc.set_int_array("k", gen) or gdoc.to_canonical() != "k: [1, 2, 3]\n":  # type: ignore[arg-type]
		raise SystemExit(f"a generator wrote {gdoc.to_canonical()!r}")
	test_id("EommtF5", "written_spelling_matches_its_reload")
	# A written value with both quote kinds is stored the way its own reload
	# stores it, so instances() and a read's raw text agree across a save. The
	# emitter escapes the double quotes; the writer used to keep them bare. Same
	# fixture in every runner.
	wdoc = shcl.Document.parse("x: 1\n")
	if not wdoc.set_string("k", "q\"q'"):
		raise SystemExit("set_string refused")
	wback = shcl.Document.parse(wdoc.to_canonical())
	if wback.instances("k") != wdoc.instances("k"):
		raise SystemExit(f"instances after a reload {wback.instances('k')}, written {wdoc.instances('k')}")
	if wdoc.get_string_or("k", "") != "q\"q'":
		raise SystemExit("written value did not read back")
	test_id("EomjcaY", "index_rebuild_ignores_removed_nodes")
	# The name index used to be rebuilt by walking the arena, which still holds
	# every node a set-and-remove cycle ever made - so the first read after a
	# merge grew with the number of edits, not with the document. Timed against
	# the same document with no dead nodes; the ratio is what matters, since an
	# absolute figure would be a machine constant. Same fixture in every runner.
	ms = []
	for churned in (False, True):
		idoc = shcl.Document.parse("g:\n\tk: 1\n")
		if churned:
			# A subtree per cycle, not a leaf. A removed leaf leaves its
			# parent's list, so the old walk only stepped over it and cost
			# three times a sound build. A removed subtree keeps its own list,
			# and the old walk indexed every dead child.
			for i in range(50000):
				if not idoc.set_int("g.tmp.x", i) or idoc.remove("g.tmp") != 1:
					raise SystemExit(f"churn cycle {i}: set or remove refused")
		iother = shcl.Document.parse("g:\n\tk: 1\n")
		t0 = time.perf_counter()
		for _ in range(2000):
			idoc.merge(iother)
			if idoc.get_int_or("g.k", -1) != 1:
				raise SystemExit("index walk: wrong result")
		ms.append((time.perf_counter() - t0) * 1000.0)
	# A generous ratio on purpose: the chain list is still sized by the arena,
	# which is a fill the walk cannot avoid. What the bound catches is the walk
	# itself going over every dead node. Two thousand merges put that cost well
	# past the constant term a shared runner needs; the smaller fixture this
	# used to run could not fail on any machine.
	# A clock too coarse to see the fresh side leaves the ratio with no
	# denominator. That used to skip the judgment, and skip it silently. The
	# constant term alone is an absolute figure on whatever machine is running,
	# so it gets room: the healthy churned side has measured half a second on
	# the hosted windows runner, and the defect is tens of seconds.
	bound = 3000.0 if ms[0] <= 0 else ms[0] * 25 + 1000
	if ms[1] > bound:
		raise SystemExit(f"index rebuild after churn {ms[1]:.1f} ms against {ms[0]:.1f} ms fresh (bound {bound:.1f} ms)")
	test_id("EqoaM6E", "merge_settles_only_what_it_touched")
	# A merge settles the comments of the blocks it visited, not of the whole
	# tree: a whole-tree pass made each small merge cost the document, and a
	# caller folding many layers onto a big one paid it every time. Timed
	# against the same merges with the big block left out. Same fixture in every
	# runner, with 200 merges here rather than 2000: the defect is still seconds.
	ms = []
	for big in (False, True):
		text = "g:\n\tk: 1\n"
		if big:
			text += "big:\n" + "".join(f"\tc{i}: {i}\n" for i in range(100000))
		mdoc = shcl.Document.parse(text)
		mother = shcl.Document.parse("g:\n\tk: 1\n")
		t0 = time.perf_counter()
		for _ in range(200):
			mdoc.merge(mother)
		ms.append((time.perf_counter() - t0) * 1000.0)
		if mdoc.get_int_or("g.k", -1) != 1:
			raise SystemExit("merge fixture: wrong result")
	bound = 3000.0 if ms[0] <= 0 else ms[0] * 25 + 1000
	if ms[1] > bound:
		raise SystemExit(f"200 merges beside a big block {ms[1]:.1f} ms against {ms[0]:.1f} ms without it (bound {bound:.1f} ms) - the merge settles blocks it never touched")
	test_id("EqqmFxS", "a_far_kept_line_costs_an_edit_nothing")
	# A misplaced line kept as written made every edit and merge re-emit the
	# whole document to settle it, even one far from the line. Timed against the
	# same steps on the same document without the line. Same fixture in every
	# runner, with 50 of each here rather than 500: the defect is still seconds.
	# Edits first, since a merge drops the name index and the edit after it
	# would rebuild it over the whole document either way.
	ms = []
	for with_line in (False, True):
		text = "g:\n\tk: 1\nbig:\n" + "".join(f"\tc{i}: {i}\n" for i in range(100000))
		if with_line:
			text += " x: y\n"
		kdoc = shcl.Document.parse(text)
		kother = shcl.Document.parse("g:\n\tj: 1\n")
		t0 = time.perf_counter()
		for i in range(50):
			if not kdoc.set_int("g.k", i):
				raise SystemExit("kept-line fixture: set_int refused")
		for _ in range(50):
			kdoc.merge(kother)
		ms.append((time.perf_counter() - t0) * 1000.0)
		if kdoc.get_int_or("g.k", -1) != 49:
			raise SystemExit("kept-line fixture: wrong result")
		if kdoc.to_canonical().endswith("\n x: y\n") != with_line:
			raise SystemExit("kept-line fixture: the kept line is not where the fixture put it")
	bound = 3000.0 if ms[0] <= 0 else ms[0] * 25 + 1000
	if ms[1] > bound:
		raise SystemExit(f"50 edits and merges beside a kept line {ms[1]:.1f} ms against {ms[0]:.1f} ms without it (bound {bound:.1f} ms) - each one settles the whole document")
	test_id("EreVRei", "a_kept_line_gone_from_the_tree_refuses_the_save")
	# The save gate on kept lines, from inside: once the edits that lose one
	# are fixed, no public call reaches the gate, so this takes a line out by
	# hand. Same fixture in every runner.
	kbase = "x: 1\nr: [1, 2\ny: 3\n"

	def kept_child(doc, name):
		return next(c for c in doc.arena[shcl.ROOT].children if doc.arena[c].name == name)

	kdoc = shcl.Document.parse_keep_lines(kbase, shcl.Strictness.Standard)
	if kdoc.lost_count() != 0:
		fails.append("kept gate: lost before the edit")
	gone = kdoc.arena[kept_child(kdoc, "y")]._triv().leading.pop()
	if not gone.is_kept_line():
		fails.append(f"kept gate: took {gone.text!r}, not a kept line")
	if kdoc.lost_count() != 1:
		fails.append(f"kept gate: lost_count {kdoc.lost_count()}, want 1")
	if kdoc.to_text_keep_lines()[1]:
		fails.append("kept gate: the keep save kept lines with one gone")
	with tempfile.TemporaryDirectory() as ktd:
		kpath = os.path.join(ktd, "f.shcl")
		with open(kpath, "w", encoding="utf-8", newline="") as kf:
			kf.write(kbase)
		for save in (kdoc.save_file, kdoc.save_file_keep_lines):
			try:
				save(kpath)
				fails.append(f"kept gate: {save.__name__} wrote")
			except shcl.SaveRefused as e:
				if e.lost != 1:
					fails.append(f"kept gate: {save.__name__} refused with {e.lost}")
				if str(e) != f"{kpath}: refusing to save: this write would delete 1 line(s)/value(s) from the file (see diagnostics; save_file_lossy overrides)":
					fails.append(f"kept gate: {save.__name__} said {e}")
		with open(kpath, encoding="utf-8", newline="") as kf:
			if kf.read() != kbase:
				fails.append("kept gate: the file changed")

	test_id("EreVRgk", "a_remove_takes_the_kept_line_heading_its_field")
	# design.md's table: a remove takes the kept line written as the field's
	# own line, and nothing beside it.
	kdoc = shcl.Document.parse("a: [1\n\tb: 2\ny: 3\n")
	if kdoc.remove("a") != 1 or kdoc.lost_count() != 0 or kdoc.to_canonical() != "y: 3\n":
		fails.append(f"kept gate: removing a field opened from a kept line lost {kdoc.lost_count()} and wrote {kdoc.to_canonical()!r}")

	def check_removes(cases):
		for text, path, want in cases:
			kdoc = shcl.Document.parse(text)
			n = kdoc.remove(path)
			out = kdoc.to_canonical()
			if n != 1 or kdoc.lost_count() != 0 or out != want:
				fails.append(f"kept gate: removing {path} from {text!r} took {n}, lost {kdoc.lost_count()} and wrote {out!r}")
			elif shcl.Document.parse(out).to_canonical() != out:
				fails.append(f"kept gate: removing {path} from {text!r} wrote text that reloads otherwise")

	test_id("ErgTogT", "a_remove_leaves_the_kept_lines_beside_it")
	# design.md's table: a remove leaves the kept lines beside its target,
	# above or below it, with the comments above them (2026100307163901).
	check_removes([
		(kbase, "y", "x: 1\nr: [1, 2\n"),
		("x: 1\nbad name: 1\ny: 3\n", "y", "x: 1\nbad name: 1\n"),
		("j:\n\tr: [1\n\tq: 1\nz: 2\n", "j.q", "j:\n\tr: [1\nz: 2\n"),
		("j:\n\tq: 1\n\tr: [1\nz: 2\n", "j.q", "j:\n\tr: [1\nz: 2\n"),
		("j:\n\tq: 1\n\tr: [1\n\tw: 3\nz: 2\n", "j.q", "j:\n\tr: [1\n\tw: 3\nz: 2\n"),
		("# on r\nr: [1\n# on y\ny: 3\nz: 1\n", "y", "# on r\nr: [1\nz: 1\n"),
	])

	test_id("ErgToiG", "a_field_opened_by_a_kept_line_goes_with_its_last_line")
	# A field opened only by the lines under it goes with the last of them,
	# and its kept line stays (escblock; 2026100307163907).
	check_removes([
		("a: [1\n\tb: 2\ny: 3\n", "a.b", "a: [1\ny: 3\n"),
		("a: [1\n\tb: 2\n\tc: 3\ny: 3\n", "a.b", "a: [1\n\tc: 3\ny: 3\n"),
		("a: [1\n\tb: 2\n\tr: [3\ny: 3\n", "a.b", "a: [1\n\tr: [3\ny: 3\n"),
		("o: [9\n\ta: [1\n\t\tb: 2\ny: 3\n", "o.a.b", "o: [9\n\ta: [1\ny: 3\n"),
		("o:\n\ta: [1\n\t\tb: 2\n", "o.a.b", "o:\n\ta: [1\n"),
	])

	test_id("Erlf17j", "a_setter_comments_out_the_kept_line_heading_its_target")
	# A setter on a field a kept line opened writes that line as a comment
	# with a note, so the file has one line for the field (2026100307163907).
	held_clock = os.environ.get("SHCL_TEST_CLOCK")
	os.environ["SHCL_TEST_CLOCK"] = "2026-10-04 00:15:00 -420 PDT"
	for text, set_path, set_want in [
		("a: [1\n\tb: 2\ny: 3\n", "a",
			"# a: [1  ## commented out by shcl when setting a, 2026-10-04 00:15:00 PDT: E019 malformed array, no closing ']' on the line\na: 5\n\tb: 2\ny: 3\n"),
		("o:\n\ta: \"x◉Q◉\"\n\t\tb: 2\n", "o.a",
			"o:\n\t# a: \"x◉Q◉\"  ## commented out by shcl when setting o.a, 2026-10-04 00:15:00 PDT: E023 unknown escape '◉Q◉'\n\ta: 5\n\t\tb: 2\n"),
		("p: host: a.com\n\tq: 1\n", "p",
			"# p: host: a.com  ## commented out by shcl when setting p, 2026-10-04 00:15:00 PDT: E025 a colon then a space in a bare value\np: 5\n\tq: 1\n"),
		("r: \"open\n\tq: 1\n", "r",
			"# r: \"open  ## commented out by shcl when setting r, 2026-10-04 00:15:00 PDT: E017 unterminated quote in value\nr: 5\n\tq: 1\n"),
		("404: x\n\tq: 1\n", "\"404\"",
			"# 404: x  ## commented out by shcl when setting \"404\", 2026-10-04 00:15:00 PDT: E014 field name needs quotes\n\"404\": 5\n\tq: 1\n"),
	]:
		kdoc = shcl.Document.parse_keep_lines(text, shcl.Strictness.Standard)
		took = kdoc.set_int(set_path, 5)
		out = kdoc.to_canonical()
		if not took or kdoc.lost_count() != 0 or out != set_want:
			fails.append(f"kept gate: setting {set_path} in {text!r} wrote {out!r}")
			continue
		back = shcl.Document.parse(out)
		if back.diagnostics() or back.count(set_path) != 1 or back.to_canonical() != out:
			fails.append(f"kept gate: the reload of {out!r} differs")
		if kdoc.to_text_keep_lines() != (out, True):
			fails.append(f"kept gate: the keep save of {text!r} gave {kdoc.to_text_keep_lines()!r}")
	if held_clock is None:
		del os.environ["SHCL_TEST_CLOCK"]
	else:
		os.environ["SHCL_TEST_CLOCK"] = held_clock
	# Only the field the kept line opened: a child of it, or a field beside a
	# kept line, leaves the line as it was.
	for set_path, set_want in [("a.c", "a: [1\n\tb: 2\n\tc: 5\n"), ("z", "a: [1\n\tb: 2\n\nz: 5\n")]:
		kdoc = shcl.Document.parse("a: [1\n\tb: 2\n")
		if not kdoc.set_int(set_path, 5) or kdoc.to_canonical() != set_want:
			fails.append(f"kept gate: setting {set_path} beside a kept line wrote {kdoc.to_canonical()!r}")

	test_id("ErmXhtL", "a_setter_comments_out_every_kept_line_of_its_name")
	# A setter writing `a` writes every kept line named `a` in that block as
	# the noted comment, and a field it creates goes right under the first of
	# them, so a later hand fix never gives Multiple (2026100307163907).
	held_clock = os.environ.get("SHCL_TEST_CLOCK")
	os.environ["SHCL_TEST_CLOCK"] = "2026-10-04 00:15:00 -420 PDT"
	na, noa, nac = (f"  ## commented out by shcl when setting {p}, 2026-10-04 00:15:00 PDT: E019 malformed array, no closing ']' on the line" for p in ("a", "o.a", "a.c"))
	for text, set_path, set_want, set_count in [
		# No loaded `a`: the new line goes under the first comment.
		("a: [1\ny: 3\n", "a", f"# a: [1{na}\na: 5\ny: 3\n", 1),
		("x: 1\na: [1\ny: 3\na: [2\n", "a", f"x: 1\n# a: [1{na}\na: 5\ny: 3\n# a: [2{na}\n", 1),
		# What was under the line goes under the new one.
		("a: [1\n\t# under\n\tb: [2\ny: 3\n", "a", f"# a: [1{na}\na: 5\n\t# under\n\tb: [2\ny: 3\n", 1),
		# At the end of a block.
		("o:\n\tx: 1\n\ta: [1\n", "o.a", f"o:\n\tx: 1\n\t# a: [1{noa}\n\ta: 5\n", 1),
		# A field made on the way writes its line too.
		("a: [1\ny: 3\n", "a.c", f"# a: [1{nac}\na:\n\tc: 5\ny: 3\n", 1),
		# A loaded `a` changes in place.
		("a: 1\nb: [1\na: [2\n", "a", f"a: 5\nb: [1\n# a: [2{na}\n", 1),
		# A kept line with a kept line under it stays as it is, since as a
		# comment it would leave that line under the field above.
		# Two valid lines wrote the first one here until a setter on a
		# repeated path was refused (2026100717500010); the refusal is
		# checked below.
		# ("a: 1\na: 2\n", "a", "a: 5\na: 2\n", 2),
		("a: 1\na: [2\n\tc: [3\n", "a", "a: 5\na: [2\n\tc: [3\n", 1),
	]:
		kdoc = shcl.Document.parse_keep_lines(text, shcl.Strictness.Standard)
		took = kdoc.set_int(set_path, 5)
		out = kdoc.to_canonical()
		if not took or kdoc.lost_count() != 0 or out != set_want:
			fails.append(f"kept gate: setting {set_path} in {text!r} wrote {out!r}")
			continue
		back = shcl.Document.parse(out)
		if back.count(set_path) != set_count or back.to_canonical() != out:
			fails.append(f"kept gate: the reload of {out!r} differs")
		if kdoc.to_text_keep_lines() != (out, True):
			fails.append(f"kept gate: the keep save of {text!r} gave {kdoc.to_text_keep_lines()!r}")
	if held_clock is None:
		del os.environ["SHCL_TEST_CLOCK"]
	else:
		os.environ["SHCL_TEST_CLOCK"] = held_clock
	# Two valid lines stay as they are: the setter refuses the path.
	kdoc = shcl.Document.parse_keep_lines("a: 1\na: 2\n", shcl.Strictness.Standard)
	if kdoc.set_int("a", 5) or kdoc.to_text_keep_lines() != ("a: 1\na: 2\n", True):
		fails.append(f"kept gate: two valid lines gave {kdoc.to_text_keep_lines()!r}")
	# set_comment makes the field without touching the line.
	kdoc = shcl.Document.parse("a: [1\ny: 3\n")
	if not kdoc.set_comment("a", "n") or kdoc.to_canonical() != "a: [1\ny: 3\n\n# n\na:\n":
		fails.append(f"kept gate: set_comment beside a kept line wrote {kdoc.to_canonical()!r}")

	test_id("Erlf1AN", "a_note_names_the_zone_or_its_offset")
	# The zone's short name, else its offset; and the test clock's form.
	for offset, name, want in [
		(-420, "PDT", "PDT"), (-420, "", "UTC-07:00"), (240, "+04", "UTC+04:00"), (330, "IST", "IST"),
		(-150, "-0230", "UTC-02:30"), (0, "Pacific Daylight Time", "UTC+00:00"), (0, "", "UTC+00:00"),
	]:
		if shcl._zone_label(offset, name) != want:
			fails.append(f"note clock: zone label of {offset} {name!r} is {shcl._zone_label(offset, name)!r}, want {want!r}")
	for spec, want in [
		("2026-10-04 00:15:00 -420 PDT", ("2026-10-04 00:15:00", -420, "PDT")),
		("2026-10-04 00:15:00 60", ("2026-10-04 00:15:00", 60, "")),
		("2026-10-04 00:15:00", None),
		("2026-10-04 00:15:00 x PDT", None),
	]:
		if shcl._test_clock(spec) != want:
			fails.append(f"note clock: test clock {spec!r} read as {shcl._test_clock(spec)!r}")
	when, offset, name = shcl._local_clock()
	label = f"{when} {shcl._zone_label(offset, name)}"
	if not re.fullmatch(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ([A-Za-z]+|UTC[+-]\d\d:\d\d)", label) or abs(offset) > 14 * 60:
		fails.append(f"note clock: the local clock gave {label!r} ({offset})")

	test_id("EreVRis", "a_merged_layer_owes_its_kept_lines")
	kdoc = shcl.Document.parse("a: 1\n")
	kdoc.merge(shcl.Document.parse(kbase))
	if kdoc.lost_count() != 0 or "r: [1, 2\n" not in kdoc.to_canonical():
		fails.append("kept gate: a merged layer's kept line counted as lost or went missing")
	# Owed, not just present: taking it out again is a loss.
	kdoc.arena[kept_child(kdoc, "y")]._triv().leading.pop()
	if kdoc.lost_count() != 1:
		fails.append(f"kept gate: a merged kept line taken out gave lost_count {kdoc.lost_count()}, want 1")

	test_id("ErfGoMM", "a_replaced_leaf_takes_its_settled_kept_line")
	# design.md's table: a settled kept line on a leaf the layer replaces goes
	# with the leaf's comments, so it is no longer owed.
	kdoc = shcl.Document.parse("x: 0\n\tc: 2\n  a: 5\nb: 1\n")
	if kdoc.remove("x.c") != 1 or kdoc.to_canonical() != "x: 0\n# a: 5\nb: 1\n":
		fails.append(f"kept gate: the replaced-leaf fixture wrote {kdoc.to_canonical()!r} after the remove")
	kdoc.merge(shcl.Document.parse("b: 9\n"))
	if kdoc.lost_count() != 0 or kdoc.to_canonical() != "x: 0\nb: 9\n":
		fails.append(f"kept gate: a replaced leaf's settled line lost {kdoc.lost_count()} and wrote {kdoc.to_canonical()!r}")

	test_id("ErfGoMN", "a_footer_line_the_base_has_is_not_owed_twice")
	# design.md's table: the footer dedup skips a layer's kept line the base
	# already has, so that copy is not owed.
	kdoc = shcl.Document.parse("bad name: 1\n")
	kdoc.merge(shcl.Document.parse("bad name: 1\n"))
	if kdoc.lost_count() != 0 or kdoc.to_canonical() != "bad name: 1\n":
		fails.append(f"kept gate: a deduped footer line lost {kdoc.lost_count()} and wrote {kdoc.to_canonical()!r}")

	test_id("ErkSyPf", "a_replaced_leaf_leaves_the_lines_beside_it")
	# design.md's table: a replaced leaf takes only its own comments, the ones
	# a remove would take. A settled line or a comment past a kept line beside
	# it stays with that line.
	kdoc = shcl.Document.parse("    srv: a\n  srv(x): [3\nb(x): [4\n# mine\nq: c\n")
	if kdoc.to_canonical() != "srv: a\n# srv(x): [3\nb(x): [4\n# mine\nq: c\n":
		fails.append(f"kept gate: the beside fixture loaded as {kdoc.to_canonical()!r}")
	kdoc.merge(shcl.Document.parse("q: 9\n"))
	if kdoc.lost_count() != 0 or kdoc.to_canonical() != "srv: a\n# srv(x): [3\nb(x): [4\nq: 9\n":
		fails.append(f"kept gate: a replaced leaf's neighbors lost {kdoc.lost_count()} and wrote {kdoc.to_canonical()!r}")
	kdoc = shcl.Document.parse("p:\n\tq: c\n\t# mine\n\tb(x): [4\n\t# n\n")
	kdoc.merge(shcl.Document.parse("p:\n\tq: 9\n"))
	if kdoc.lost_count() != 0 or kdoc.to_canonical() != "p:\n\tb(x): [4\n\t# n\n\tq: 9\n":
		fails.append(f"kept gate: a replaced leaf's lines below lost {kdoc.lost_count()} and wrote {kdoc.to_canonical()!r}")
	# The failure report above has run already, so these end the run here.
	if fails:
		test_id_end()
		raise SystemExit("\n".join(f"FAIL {f}" for f in fails))
	test_id("EolmVOa", "diagnostics_hand_out_a_copy")
	# What a read hands out must not be the document's own list: a caller
	# clearing it used to take the document's diagnostics with it, and a failed
	# strict load handed out the same list again. Same fixture in Go.
	adoc = shcl.Document.parse("a: 1\na: 2\n")
	handed = adoc.diagnostics()
	if not handed:
		raise SystemExit("aliasing fixture: want a diagnostic to work with")
	handed.clear()
	if not adoc.diagnostics():
		raise SystemExit("diagnostics() handed out the document's own list")
	try:
		shcl.Document.parse_with("a\n", shcl.Strictness.Strict)
		raise SystemExit("aliasing fixture: want a strict load failure")
	except shcl.LoadError as e:
		e.diagnostics.clear()
		if e.document is not None and not e.document.diagnostics():
			raise SystemExit("LoadError shares the document's diagnostics list") from None
	test_id("EofAXrW", "parse_limited_caps")
	# parse_limited: the caps exist because a document amplifies to many times
	# its byte size in memory, so read_file's byte cap alone cannot bound a
	# load. Same fixture in every runner.
	ltext = "a: 1\nb: 2\nc: 3\nd: 4\n"
	ldoc = shcl.Document.parse_limited(ltext, shcl.Strictness.Standard, 2, 0)
	lcaps = [g for g in ldoc.diagnostics() if g.code == "E020"]
	if len(lcaps) != 1 or lcaps[0].line != 4:
		raise SystemExit(f"node cap: {[(g.line, g.code) for g in ldoc.diagnostics()]}")
	if ldoc.lost_count() != 1 or ldoc.get_int("a") != 1 or ldoc.exists("d"):
		raise SystemExit("node cap: remainder must be lost and unparsed")
	ldoc = shcl.Document.parse_limited("a: 1\nb: 2\nc: 3", shcl.Strictness.Standard, 2, 0)
	if sum(1 for g in ldoc.diagnostics() if g.code == "E020") != 1 or ldoc.lost_count() != 0:
		raise SystemExit("node cap crossed on the last line must still report")
	ldoc = shcl.Document.parse_limited("x.y.z: 1\n", shcl.Strictness.Standard, 1, 0)
	if sum(1 for g in ldoc.diagnostics() if g.code == "E020") != 1 or ldoc.get_int("x.y.z") != 1:
		raise SystemExit("node cap overshoot line must stay in the document")
	ldoc = shcl.Document.parse_limited(ltext, shcl.Strictness.Standard, 0, 0)
	if ldoc.diagnostics():
		raise SystemExit("uncapped parse_limited must match parse_with")
	ldoc = shcl.Document.parse_limited("arr: [1, 2, 3]\nok: 5\n", shcl.Strictness.Standard, 0, 2)
	lcaps = [g for g in ldoc.diagnostics() if g.code == "E021"]
	if len(lcaps) != 1 or lcaps[0].line != 1 or ldoc.exists("arr") or ldoc.get_int("ok") != 5 or ldoc.lost_count() != 1:
		raise SystemExit("element cap: the whole line is refused, the rest untouched")
	ldoc = shcl.Document.parse_limited("arr:\n\t- 1\n\t- 2\n\t- 3\n", shcl.Strictness.Standard, 0, 2)
	if sum(1 for g in ldoc.diagnostics() if g.code == "E021") != 1 or ldoc.get_int_array("arr") != [1, 2]:
		raise SystemExit("element cap: a stacked array keeps what fit")
	# A malformed array past the cap stayed E019 and kept. Since 2026-10-05
	# the cap wins over a broken value, so this is E021 now: see
	# a_cap_wins_over_a_broken_value.
	# ldoc = shcl.Document.parse_limited("arr: [1,, 2, 3]\nk: x\n\t- 1\n", shcl.Strictness.Standard, 0, 1)
	# lgot = [(g.line, g.code) for g in ldoc.diagnostics()]
	# if lgot != [(1, "E019"), (3, "E011")] or ldoc.lost_count() != 1 or "arr: [1,, 2, 3]" not in ldoc.to_canonical():
	# 	raise SystemExit(f"element cap over a refused line: {lgot} lost {ldoc.lost_count()}")
	# The count the cap judges is the count the array reads back as, spelling
	# by spelling: quoted commas, a backslash (a character, so it shields
	# nothing), the empty array, a quoted Unicode blank (content: only a space
	# or a tab is blank, and bare it is E025). Refused at one under, kept at
	# exact. A quote that never closes made the comma after it split before
	# the value syntax; that line is E017 now and binds nothing. An empty slot
	# is E019 now, and a bare comma E026.
	counts = [
		("[1, 2, 3]", 3), ('["a, b", c]', 2), ("[a\\, b, c]", 3), ("[]", 0),
		("[ ]", 0), (" a ", 1), ("[\"\", '']", 2), ("'a\", b'", 1),
		# ('"open, b', 2),
		("\\", 1), ('[x,"\u3000"]', 2), ('[x, "\u00a0y"]', 2), ("[80]", 1),
	]
	for spelling, n in counts:
		text = f"v: {spelling}\n"
		ldoc = shcl.Document.parse_limited(text, shcl.Strictness.Standard, 0, max(n, 1))
		if any(g.code == "E021" for g in ldoc.diagnostics()):
			raise SystemExit(f"{spelling!r} at cap {n}: E021")
		r = ldoc.read_string_array("v")
		if n == 0:
			if r.status != shcl.Status.Good or r.value:
				raise SystemExit(f"{spelling!r}: want empty, got {r.status}")
		elif r.status != shcl.Status.Good or len(r.value) != n:
			raise SystemExit(f"{spelling!r}: want {n} elements, got {r.value} {r.status}")
		if n >= 2:
			ldoc = shcl.Document.parse_limited(text, shcl.Strictness.Standard, 0, n - 1)
			if ldoc.lost_count() != 1:
				raise SystemExit(f"{spelling!r} at cap {n - 1}: not refused")
	# An open quote was judged before the cap and kept the line. Since
	# 2026-10-05 the cap wins: see a_cap_wins_over_a_broken_value.
	# ldoc = shcl.Document.parse_limited('v: [a, "open, b]\n', shcl.Strictness.Standard, 0, 1)
	# if [g.code for g in ldoc.diagnostics()] != ["E017"] or ldoc.lost_count() != 0:
	# 	raise SystemExit("refused line must report the cap alone")
	# A fence whose info string splits past the cap is refused with its block,
	# in both spellings, so the body never reads as live lines. Same fixture in
	# every runner. Only a comma with a blank after it splits since 20261006.
	for ftext in (
		"secrets:\n\t```a, b, c, d\n\tpassword: hunter2\n\t```\nafter: 1\n",
		"secrets: ```a, b, c, d\n\tpassword: hunter2\n\t```\nafter: 1\n",
	):
		ldoc = shcl.Document.parse_limited(ftext, shcl.Strictness.Standard, 0, 3)
		if (
			[g.code for g in ldoc.diagnostics()] != ["E021"]
			or ldoc.exists("secrets.password")
			or ldoc.get_int("after", None) != 1
			or ldoc.lost_count() != 1
		):
			raise SystemExit(f"{ftext!r}: a capped fence must go with its block")
	# What a capped parse holds is the text and its lines. The refused line
	# used to be built in full first (38x the text), so the cap saved nothing.
	btext = "arr: [" + "1, " * 200000 + "1]\nok: 5\n"
	tracemalloc.start()
	ldoc = shcl.Document.parse_limited(btext, shcl.Strictness.Standard, 0, 8)
	lpeak = tracemalloc.get_traced_memory()[1]
	tracemalloc.stop()
	if ldoc.lost_count() != 1 or ldoc.get_int("ok") != 5:
		raise SystemExit("capped parse: wrong result")
	if lpeak > len(btext) * 8:
		raise SystemExit(f"a capped parse held the array it refused: {lpeak} bytes for {len(btext)} of text")
	# Diagnostic cap: the first N are listed and one E022 tail counts the
	# rest. Its severity is Error when any unlisted one was, so a scan of the
	# list for errors still finds one and error_count stays nonzero.
	bad = "no colon\n" * 50
	ldoc = shcl.Document.parse_limited(bad, shcl.Strictness.Standard, 0, 0, 10)
	lds = ldoc.diagnostics()
	if len(lds) != 11 or any(g.code != "E014" for g in lds[:10]):
		raise SystemExit(f"diag cap: {[g.code for g in lds]}")
	if (lds[10].code, lds[10].severity, lds[10].line, lds[10].message) != (
		"E022", shcl.Severity.Error, 0, "diagnostic cap of 10 reached; 40 more not listed, 40 of them errors"
	):
		raise SystemExit(f"diag cap tail: {lds[10]}")
	if ldoc.error_count() != 11:
		raise SystemExit(f"diag cap: error count {ldoc.error_count()}")
	try:
		shcl.Document.parse_limited(bad, shcl.Strictness.Strict, 0, 0, 10)
		raise SystemExit("diag cap: capped strict load must fail")
	except shcl.LoadError:
		pass
	# Hints past the cap leave a Hint tail, so a document with no error still
	# loads at Strict.
	hints = "x: 1\nx: 2\ny: 1\ny: 2\n"
	ldoc = shcl.Document.parse_limited(hints, shcl.Strictness.Strict, 0, 0, 1)
	lds = ldoc.diagnostics()
	if [(g.code, g.severity) for g in lds] != [("H001", shcl.Severity.Hint), ("E022", shcl.Severity.Hint)]:
		raise SystemExit(f"hint tail: {[(g.code, g.severity) for g in lds]}")
	if not lds[1].message.endswith("1 more not listed, 0 of them errors") or ldoc.error_count() != 0:
		raise SystemExit(f"hint tail: {lds[1].message} {ldoc.error_count()}")
	# At the cap exactly, nothing is unlisted and there is no tail.
	if len(shcl.Document.parse_limited(hints, shcl.Strictness.Standard, 0, 0, 2).diagnostics()) != 2:
		raise SystemExit("at the cap: a tail appeared")
	# The stacked spelling refuses each element line past the cap on its own,
	# and every refusal is a diagnostic: with the element cap alone, 200k
	# refused lines cost more than the elements they refused. The diagnostic
	# cap is what bounds that.
	btext = "arr:\n" + "\t- 1\n" * 200000
	tracemalloc.start()
	ldoc = shcl.Document.parse_limited(btext, shcl.Strictness.Standard, 0, 8, 100)
	lpeak = tracemalloc.get_traced_memory()[1]
	tracemalloc.stop()
	if len(ldoc.diagnostics()) != 101 or ldoc.lost_count() != 200000 - 8:
		raise SystemExit("diagnostic-capped parse: wrong result")
	# 16x rather than 8x: the split lines alone are 10x here, since a
	# five-byte line is a fifty-byte str object. Uncapped it is 48x.
	if lpeak > len(btext) * 16:
		raise SystemExit(f"a diagnostic-capped parse held its unlisted diagnostics: {lpeak} bytes for {len(btext)} of text")
	try:
		shcl.Document.parse_limited(ltext, shcl.Strictness.Strict, 2, 0)
		raise SystemExit("capped strict load must fail")
	except shcl.LoadError as ex:
		if ex.document is None or ex.document.get_int("a") != 1:
			raise SystemExit("failed strict doc must stay readable") from None
	test_id("EryEqnz", "a_cap_wins_over_a_broken_value")
	# An item or a line past the caller's element cap is E021 and dropped,
	# even when its value is broken: the cap wins over a value fault. A fault
	# in the path or the name still comes first, and a broken item within the
	# cap is still kept. Same fixture in every runner.

	def cap_codes(text, cap):
		cdoc = shcl.Document.parse_limited(text, shcl.Strictness.Standard, 0, cap)
		return [(g.line, g.code) for g in cdoc.diagnostics()], cdoc.lost_count(), cdoc.to_canonical()

	# Bracket arrays: an empty slot, an open quote, no closing bracket, text
	# after it. Each is E021 at a cap below its length, and its own code at a
	# cap that fits.
	for ctext, own in (
		("arr: [1,, 2, 3]\n", "E019"),
		('arr: [a, "open, b]\n', "E017"),
		("arr: [a, b, c\n", "E019"),
		("arr: [a, b] c\n", "E019"),
		("arr: [a, b c, d]\n", "E025"),
	):
		got, lost, out = cap_codes(ctext, 1)
		if got != [(1, "E021")] or lost != 1 or "arr" in out:
			raise SystemExit(f"{ctext!r} at cap 1: {got} lost {lost} out {out!r}")
		got, lost, _ = cap_codes(ctext, 9)
		if got != [(1, own)] or lost != 0:
			raise SystemExit(f"{ctext!r} under the cap: {got} lost {lost}")
	# A bare comma outside brackets counts its pieces the same way.
	if cap_codes("a: x, y, z\n", 2)[0] != [(1, "E021")]:
		raise SystemExit(f"bare comma past the cap: {cap_codes('a: x, y, z', 2)[0]}")
	if cap_codes("a: x, y, z\n", 3)[0] != [(1, "E026")]:
		raise SystemExit(f"bare comma within the cap: {cap_codes('a: x, y, z', 3)[0]}")
	# A stacked item past the cap is dropped whatever it holds; within the
	# cap a broken one is kept and the list loads around it.
	got, lost, out = cap_codes("x:\n\t- a\n\t- b\n\t- \"open\n\t- c d\nz: 1\n", 2)
	if got != [(4, "E021"), (5, "E021")] or lost != 2 or out != "x:\n\t- a\n\t- b\nz: 1\n":
		raise SystemExit(f"items past the cap: {got} lost {lost} out {out!r}")
	got, lost, out = cap_codes("x:\n\t- a\n\t- \"open\n\t- b\n", 2)
	if got != [(3, "E017")] or lost != 0 or '- "open' not in out:
		raise SystemExit(f"a broken item within the cap: {got} lost {lost} out {out!r}")
	# An element under a field with a value is E011, cap or not.
	if cap_codes("k: x\n\t- 1\n", 1)[0] != [(2, "E011")]:
		raise SystemExit("item under a value")
	# The path and the name are judged first.
	if cap_codes("404: [a, b, c]\n", 1)[0] != [(1, "E014")]:
		raise SystemExit(f"a bad name past the cap: {cap_codes('404: [a, b, c]', 1)[0]}")

	test_id("EryEqq5", "no_colon_repair_stays_narrow")
	# Only one clean name or path with no colon is repaired (E015), a bad bare
	# name like 404 included. Anything with a blank in a bare name could be a
	# name or a name and a value, so it is E014 and kept as written.
	for nline, nquoted in (
		("square-miles 300", '"square-miles 300"'),
		("this is ! not parseable", '"this is ! not parseable"'),
		("user name", '"user name"'),
		("user\tname", '"user◉TAB◉name"'),
		("a.b c", 'a."b c"'),
	):
		ndoc = shcl.Document.parse(f"k: 1\n{nline}\nz: 2\n")
		if [g.code for g in ndoc.diagnostics()] != ["E014"]:
			raise SystemExit(f"{nline!r}: {ndoc.diagnostics()}")
		if ndoc.lost_count() != 0:
			raise SystemExit(f"{nline!r}: lost_count {ndoc.lost_count()}")
		if ndoc.to_canonical() != f"k: 1\n{nline}\nz: 2\n":
			raise SystemExit(f"{nline!r} wrote {ndoc.to_canonical()!r}")
		if ndoc.exists(nquoted):
			raise SystemExit(f"{nline!r} bound {nquoted}")
	# The message names where the second word starts, as before chunk A.
	ndoc = shcl.Document.parse("a:\n\t  square-miles 300\n")
	if ndoc.diagnostics()[0].message != "malformed line skipped: unexpected character after the path, at column 17":
		raise SystemExit(f"message {ndoc.diagnostics()[0].message!r}")
	for nline, nout in (("404", '"404":'), ("-x", '"-x":'), ("a.9b", 'a:\n\t"9b":')):
		ndoc = shcl.Document.parse(f"{nline}\n")
		if [g.code for g in ndoc.diagnostics()] != ["E015"]:
			raise SystemExit(f"{nline!r}: {ndoc.diagnostics()}")
		if ndoc.to_canonical() != f"{nout}\n":
			raise SystemExit(f"{nline!r} wrote {ndoc.to_canonical()!r}")
	test_id("EnKYjpg", "set_int_refuses_past_64_bits")
	# Also python-only: an int outside the 64-bit range the other three
	# bindings use writes text every reader calls bad-type, so the setter
	# refuses instead. The edges themselves still write.
	rdoc = shcl.Document.parse("a: 1")
	if rdoc.set_int("b", 1 << 63) or rdoc.set_int("b", -(1 << 63) - 1):
		raise SystemExit("set_int accepted an out-of-range value")
	if rdoc.set_int_array("c", [1, 1 << 64]):
		raise SystemExit("set_int_array accepted an out-of-range value")
	if not rdoc.set_int("d", (1 << 63) - 1) or not rdoc.set_int("e", -(1 << 63)):
		raise SystemExit("set_int refused an in-range edge")
	if rdoc.to_canonical() != "a: 1\n\nd: 9223372036854775807\n\ne: -9223372036854775808\n":
		raise SystemExit(f"set_int range check left the wrong document: {rdoc.to_canonical()!r}")
	test_id("EnKYjph", "deep_documents_from_a_deep_caller")
	# Also python-only: the frame budget is small, so a document at the
	# documented depth cap has to survive every walk from an already-deep
	# caller. Merge and clone were the two still recursing.
	deep = "\n".join("\t" * i + f"l{i}:" for i in range(511)) + "\n" + "\t" * 511 + "v: 1\n"

	def _at_depth(k, fn):
		if k:
			return _at_depth(k - 1, fn)
		return fn()

	def _merge_deep():
		base = shcl.Document.parse(deep)
		base.merge(shcl.Document.parse(deep))
		return base.to_canonical()

	if _at_depth(900, _merge_deep) != _merge_deep():
		raise SystemExit("deep merge from a deep caller diverged")
	# Wildcard resolution, validation through mounts and the unknown-field
	# sweep behind it, and generation through mounts each recursed one
	# frame per level, so from a caller 600 frames deep a document or
	# schema at the cap raised RecursionError. Each from that depth.
	ddoc = shcl.Document.parse(deep)
	stars = ".".join(["*"] * 512)
	if _at_depth(600, lambda: ddoc.count(stars)) != 1:
		raise SystemExit("deep wildcard resolve from a deep caller")
	vschema = shcl.Document.parse("field: l0\n\tinherits: f\nfragment: f\n\tfield: *\n\t\tinherits: f\n")
	if _at_depth(600, lambda: ddoc.validate(vschema)) != []:
		raise SystemExit("deep validate through mounts from a deep caller")
	wschema = shcl.Document.parse(f"field: {stars}\n")
	if _at_depth(600, lambda: ddoc.validate(wschema)) != []:
		raise SystemExit("deep wildcard validate from a deep caller")
	# 512 distinct fragments in one chain: a re-entered name cuts at once,
	# so only a chain that long reaches the depth cut.
	gs = ["field: a\n\tinherits: f0\n"]
	for k in range(512):
		gs.append(f"fragment: f{k}\n\tfield: b\n" + (f"\t\tinherits: f{k + 1}\n" if k < 511 else ""))
	gschema = shcl.Document.parse("".join(gs))
	gtext, gfaults = _at_depth(600, lambda: shcl.generate(gschema))
	if gfaults or gtext != shcl.generate(gschema)[0] or gtext.count("\n#") < 512:
		raise SystemExit("deep generate through mounts from a deep caller")
	test_id("Er6DIqW", "file_tier_load_save")
	# load_file/save_file: the status separates absent / unreadable / parsed
	# with errors / clean, and a save round-trips through the atomic write.
	# Same fixture in every runner.
	with tempfile.TemporaryDirectory() as td:
		fpath = os.path.join(td, "t.shcl")
		_, fst = shcl.Document.load_file(fpath)
		if fst != shcl.FileStatus.NotFound:
			raise SystemExit(f"load_file missing got {fst}")
		_, fst = shcl.Document.load_file(td)  # a directory is not readable
		if fst != shcl.FileStatus.Unreadable:
			raise SystemExit(f"load_file directory got {fst}")
		# Python-only, so not in the shared fixture: a NUL in the path raises
		# ValueError out of the path calls where the other bindings report. Both
		# halves promise a status or a message, never a throw.
		_, fst = shcl.Document.load_file("a\0b")
		if fst != shcl.FileStatus.Unreadable:
			raise SystemExit(f"load_file NUL path got {fst}")
		try:
			shcl.Document.parse("a: 1").save_file("a\0b")
			raise SystemExit("save_file NUL path reported success")
		except shcl.SaveFailed:
			pass
		# Bad encoding is unreadable too: the parser assumes well-formed text, so a
		# binary file loading clean would read back mangled and a later save would
		# write the mangled version over the original.
		with open(fpath, "wb") as fbin:
			fbin.write(b"a: 1\nb: \xff\xfe bad\n")
		fdoc, fst = shcl.Document.load_file(fpath)
		if fst != shcl.FileStatus.Unreadable or fdoc.to_canonical() != "":
			raise SystemExit(f"load_file bad encoding got {fst} {fdoc.to_canonical()!r}")
		# newline="" on the seeds below: text mode would translate \n on windows,
		# so the fixture would be feeding different bytes there than anywhere else.
		with open(fpath, "w", encoding="utf-8", newline="") as fh:
			fh.write("a: 1\n: broken\n")
		fdoc, fst = shcl.Document.load_file(fpath)
		if fst != shcl.FileStatus.HadErrors:
			raise SystemExit(f"load_file broken got {fst}")
		if fdoc.get_int("a", default=0) != 1:
			raise SystemExit("load_file broken read failed")
		with open(fpath, "w", encoding="utf-8", newline="") as fh:
			fh.write("a: 1\nb: x\n")
		fdoc, fst = shcl.Document.load_file(fpath)
		if fst != shcl.FileStatus.Clean:
			raise SystemExit(f"load_file clean got {fst}")
		# read_file is the load's read half on its own: the exact bytes, or
		# the status. The cap counts bytes, and a file exactly at it passes.
		# Same fixture in every runner.
		if shcl.read_file(fpath, 0) != ("a: 1\nb: x\n", shcl.FileStatus.Clean):
			raise SystemExit("read_file")
		if shcl.read_file(fpath, 10) != ("a: 1\nb: x\n", shcl.FileStatus.Clean):
			raise SystemExit("read_file at the cap")
		if shcl.read_file(fpath, 9) != (None, shcl.FileStatus.Unreadable):
			raise SystemExit("read_file past the cap")
		# A cap given as the type maximum used to overflow the over-cap probe
		# and read nothing. Same fixture in every runner.
		if shcl.read_file(fpath, sys.maxsize) != ("a: 1\nb: x\n", shcl.FileStatus.Clean):
			raise SystemExit("read_file at the largest cap")
		if shcl.read_file(os.path.join(td, "none.shcl"), 0) != (None, shcl.FileStatus.NotFound):
			raise SystemExit("read_file missing")
		if not fdoc.set_int("c", 3):
			raise SystemExit("set_int c failed")
		fdoc.save_file(fpath)
		fback, fst = shcl.Document.load_file(fpath)
		if fst != shcl.FileStatus.Clean or fback.to_canonical() != fdoc.to_canonical():
			raise SystemExit("save round-trip mismatch")
		# Creating a file and overwriting one are two different code paths in
		# the write - the create picks its own mode, the overwrite copies the
		# target's, and the publish step differs by platform (windows goes
		# through ReplaceFile, with a rename fallback). Both run everywhere: an
		# overwrite used to throw outright on windows here, which no POSIX-only
		# fixture could ever have caught. Same fixture in every runner.
		fresh = os.path.join(td, "fresh.shcl")
		ndoc = shcl.Document.parse("a: 1\n")
		ndoc.save_file(fresh)
		back, bst = shcl.Document.load_file(fresh)
		if bst != shcl.FileStatus.Clean or back.to_canonical() != "a: 1\n":
			raise SystemExit("new file did not round-trip")
		ndoc.save_file(fresh)
		back, bst = shcl.Document.load_file(fresh)
		if bst != shcl.FileStatus.Clean or back.to_canonical() != "a: 1\n":
			raise SystemExit("overwritten file did not round-trip")

		test_id("ErOTliS", "save_writes_lf_bytes")
		# A load reads a CR as a blank, so only the bytes show a text-mode fd on
		# windows. Python-only: the other three write through binary handles.
		lfdoc = shcl.Document.parse("a: 1\nb:\n\tc: 2\n")
		lf = os.path.join(td, "lf.shcl")
		for how in ("create", "overwrite"):
			lfdoc.save_file(lf)
			written = Path(lf).read_bytes()
			if written != b"a: 1\nb:\n\tc: 2\n":
				raise SystemExit(f"{how} wrote {written!r}")

		test_id("EnWwo1I", "save_keeps_the_file_mode")
		# A new file ends up where an ordinary create puts one - 0666 narrowed by the
		# umask - and an existing one keeps the mode it had. Neither is visible
		# on stdout, so no corpus case can see either, and neither is a windows
		# concept, so the mode half is POSIX-only.
		if os.name == "posix":
			probe = os.path.join(td, "probe")
			Path(probe).touch()
			mode_want = os.stat(probe).st_mode & 0o777
			born = os.path.join(td, "born.shcl")
			ndoc.save_file(born)
			mode = os.stat(born).st_mode & 0o777
			if mode != mode_want:
				raise SystemExit(f"new file mode {mode:o}, want {mode_want:o}")
			os.chmod(born, 0o640)
			ndoc.save_file(born)
			mode = os.stat(born).st_mode & 0o777
			if mode != 0o640:
				raise SystemExit(f"existing file mode {mode:o}, want 640")
			test_id("EoTHZsG", "save_keeps_set_id_bits")
			# setuid and setgid come over too: applying the mode before the
			# data lets the kernel clear them on the write.
			# BSD gives a new file the directory's group, and refuses setgid on
			# a file whose group the caller is not in. Its own group fixes both.
			try:
				os.chown(born, -1, os.getegid())
				os.chmod(born, 0o6750)
			except PermissionError:
				pass
			if os.stat(born).st_mode & 0o7777 == 0o6750:
				ndoc.save_file(born)
				if os.stat(born).st_mode & 0o7777 != 0o6750:
					raise SystemExit("save dropped a set-id bit")
			else:
				# Setgid is cleared when the file's group is not one of the caller's,
				# which happens on ordinary boxes. The skip was silent, so this
				# fixture passed wherever it fired.
				got = os.stat(born).st_mode & 0o7777
				print(f"conformance: skipping the set-id fixture (mode came back {got:o}, want 6750)")
				test_skip()
			test_id("EoM2uEj", "save_creates_the_file_behind_a_dangling_symlink")
			# A link to a file that is not there yet is written through like any
			# other link: the file appears where the link points and the link
			# stays a link. Same fixture in every POSIX runner.
			os.mkdir(os.path.join(td, "real"))
			link = os.path.join(td, "c.shcl")
			os.symlink("real/c.shcl", link)
			shcl.Document.parse("a: 1\n").save_file(link)
			if not os.path.islink(link):
				raise SystemExit("save replaced the dangling link")
			if _read(os.path.join(td, "real", "c.shcl")) != "a: 1\n":
				raise SystemExit("save did not create the file behind the link")
			test_id("EqGYvEu", "save_takes_a_name_with_no_early_character_start")
			# A name whose first 64 bytes hold no character start: the cut backs
			# off to nothing, and the temp name used to fall back to the whole
			# path, directory and all, so the save failed. Python-only: the
			# other three have no fallback to reach.
			os.mkdir(os.path.join(td, "sub"))
			odd = os.path.join(td, "sub", os.fsdecode(b"\xc3" + b"\x80" * 70))
			# A filesystem that holds UTF-8 names only, such as ZFS with
			# utf8only, refuses this name whatever the temp is called.
			try:
				with open(odd, "w"):
					pass
				os.remove(odd)
				takes_odd = True
			except OSError:
				takes_odd = False
				print("conformance: skipping the non-UTF-8 name save (this filesystem refuses the name)")
				test_skip()
			if takes_odd:
				werr = shcl.write_file_atomic(odd, "a: 1\n")
				if werr is not None:
					raise SystemExit(f"save of a name with no early character start failed: {werr}")
				if _read(odd) != "a: 1\n":
					raise SystemExit("save of a name with no early character start wrote the wrong text")
		if os.name != "nt":
			test_id("EoUxXlT", "save_reports_a_symlink_cycle_instead_of_replacing_it")
			# Two links pointing at each other resolve to nothing, so the save
			# fails and says why. It must not "fix" the cycle by dropping a
			# regular file over one of the links. Same fixture in every POSIX
			# runner.
			cyc_a = os.path.join(td, "cyc-a.shcl")
			cyc_b = os.path.join(td, "cyc-b.shcl")
			os.symlink("cyc-b.shcl", cyc_a)
			os.symlink("cyc-a.shcl", cyc_b)
			try:
				shcl.Document.parse("a: 1\n").save_file(cyc_a)
				raise SystemExit("a symlink cycle saved without an error")
			except shcl.SaveFailed:
				pass
			for link in (cyc_a, cyc_b):
				if not os.path.islink(link):
					raise SystemExit("a symlink cycle was replaced by a regular file")
			test_id("EqLbKeN", "save_replaces_only_a_regular_file")
			# Save outcomes in design.md, the rows the CLI's own check hides. A
			# FIFO was swapped for a regular file at exit 0, a link whose text
			# names a directory made a file of that name, and Go cleaned `lnk/..`
			# as text where the kernel follows lnk first. Same fixture in every
			# POSIX runner.
			tdoc = shcl.Document.parse("a: 1\n")
			fifo = os.path.join(td, "p.shcl")
			os.mkfifo(fifo)
			try:
				tdoc.save_file(fifo)
				raise SystemExit("a FIFO saved without an error")
			except shcl.SaveFailed:
				pass
			if not stat.S_ISFIFO(os.lstat(fifo).st_mode):
				raise SystemExit("a FIFO was replaced by a regular file")
			ldir = os.path.join(td, "l.shcl")
			os.symlink("d/", ldir)
			try:
				tdoc.save_file(ldir)
				raise SystemExit("a link naming a directory saved without an error")
			except shcl.SaveFailed:
				pass
			if os.path.lexists(os.path.join(td, "d")):
				raise SystemExit("a link naming a directory made a file")
			os.makedirs(os.path.join(td, "tgt", "real", "sub"))
			os.makedirs(os.path.join(td, "tgt", "top"))
			os.symlink("../real/sub", os.path.join(td, "tgt", "top", "lnkdir"))
			os.symlink("../x.shcl", os.path.join(td, "tgt", "real", "sub", "f.shcl"))
			tdoc.save_file(os.path.join(td, "tgt", "top", "lnkdir", "f.shcl"))
			if _read(os.path.join(td, "tgt", "real", "x.shcl")) != "a: 1\n":
				raise SystemExit("save did not create the file behind lnk/..")
			if os.path.lexists(os.path.join(td, "tgt", "top", "x.shcl")):
				raise SystemExit("lnk/.. was cleaned as text")
		if os.name == "nt":
			test_id("EoM2uEk", "save_rewrites_a_read_only_file")
			# A read-only target is rewritten, as it is on POSIX, and comes back
			# read-only; no temp file is left behind. Same fixture in every runner.
			ro = os.path.join(td, "ro.shcl")
			with open(ro, "w", encoding="utf-8", newline="") as fh:
				fh.write("a: 1\n")
			os.chmod(ro, stat.S_IREAD)
			shcl.Document.parse("a: 2\n").save_file(ro)
			if _read(ro) != "a: 2\n":
				raise SystemExit("read-only file not rewritten")
			if os.stat(ro).st_mode & stat.S_IWRITE:
				raise SystemExit("rewritten file did not come back read-only")
			if [n for n in os.listdir(td) if ".tmp" in n]:
				raise SystemExit("read-only rewrite left a temp file")
			os.chmod(ro, stat.S_IREAD | stat.S_IWRITE)
			test_id("Eom3Uj3", "save_keeps_hidden_and_system")
			# Hidden and system come back too: ReplaceFile's preserve list does
			# not include the basic attributes and the os.replace fallback
			# keeps none, so a hidden config used to come back visible.
			import ctypes

			# WinDLL and st_file_attributes exist only on windows, and mypy
			# checks this file against the POSIX stubs, where both are absent.
			k32 = ctypes.WinDLL("kernel32", use_last_error=True)  # type: ignore[attr-defined]
			k32.SetFileAttributesW(ro, 0x2 | 0x4)
			shcl.Document.parse("a: 3\n").save_file(ro)
			after = os.stat(ro).st_file_attributes  # type: ignore[attr-defined]
			if not after & 0x2:
				raise SystemExit("file did not come back hidden")
			if not after & 0x4:
				raise SystemExit("file did not come back system")
			k32.SetFileAttributesW(ro, 0x80)
			windows_publish_failures(td)
			test_id("ErO2NoG", "temp_takes_the_targets_dacl")
			_temp_takes_the_targets_dacl(td)
		test_id("EoM2uEl", "a_surrogate_save_leaves_no_temp_file")
		# A document holding a lone surrogate has no UTF-8 spelling; the save
		# fails like any other failed write, and leaves no temp file behind.
		# A setter put the surrogate in until setters refused text with no UTF-8
		# spelling (2026100815543610); a parse still keeps one.
		# surdoc = shcl.Document.parse("a: 1\n")
		# if not surdoc.set_string("s", "\udcff"):
		# 	raise SystemExit("set_string refused a surrogate")
		surdoc = shcl.Document.parse("a: 1\ns: \udcff\n")
		if surdoc.read_string("s").value != "\udcff":
			raise SystemExit("the parse dropped a surrogate")
		try:
			surdoc.save_file(fpath)
			raise SystemExit("save_file wrote a lone surrogate")
		except shcl.SaveFailed:
			pass
		if [n for n in os.listdir(td) if ".tmp" in n]:
			raise SystemExit("failed save left a temp file")
		test_id("EoM2uEm", "an_int_is_not_a_path")
		# A path is a str or a PathLike, never a descriptor: read_file(0) used
		# to read stdin and close it.
		bad_path: Any = 0
		for call in (
			lambda: shcl.read_file(bad_path),
			lambda: shcl.Document.load_file(bad_path),
			lambda: shcl.write_file_atomic(bad_path, "a: 1\n"),
		):
			try:
				call()
				raise SystemExit("an int was taken as a path")
			except TypeError:
				pass
		os.fstat(0)  # raises if the read closed stdin
		test_id("EnKwdMW", "lost_and_save_gate")
		# Content-malformed lines are retained as trivia (lost_count 0, the
		# line survives a save); position-dependent drops count as lost and
		# make save_file refuse until the caller opts into save_file_lossy.
		# Same fixture in every runner.
		kept = shcl.Document.parse("a: 1\nsquare-miles 300\nb: 2\n")
		if kept.lost_count() != 0:
			raise SystemExit(f"kept lost_count got {kept.lost_count()}")
		if "square-miles 300\n" not in kept.to_canonical():
			raise SystemExit("retained line missing from canonical output")
		# An indent matching no level is kept as written when it holds a
		# space, which no level the emitter writes can equal, and lost when it
		# is tabs.
		spaced = shcl.Document.parse("a:\n\tb: 1\n  c: 2\n\td: 3\n")
		if spaced.lost_count() != 0:
			raise SystemExit(f"spaced lost_count got {spaced.lost_count()}")
		if spaced.to_canonical() != "a:\n\tb: 1\n  c: 2\n\td: 3\n":
			raise SystemExit(f"spaced line not kept as written: {spaced.to_canonical()!r}")
		lostdoc = shcl.Document.parse("a:\n\t\tb: 1\n\tc: 2\n")
		if lostdoc.lost_count() != 1:
			raise SystemExit(f"lost lost_count got {lostdoc.lost_count()}")
		kept.save_file(fpath)
		kback, _ = shcl.Document.load_file(fpath)
		if "square-miles 300\n" not in kback.to_canonical():
			raise SystemExit("retained line lost through save round-trip")
		try:
			lostdoc.save_file(fpath)
			raise SystemExit("save_file did not refuse a lossy save")
		except shcl.SaveRefused:
			pass
		lostdoc.save_file_lossy(fpath)
		# A refusal and a failed write are separate classes, not two spellings of
		# one message, and the gate answers before any i/o - so an unwritable path
		# still reports the refusal. Same fixture in every runner.
		bad = os.path.join(td, "nope", "t.shcl")
		try:
			kept.save_file(bad)
			raise SystemExit("save_file to an unwritable path reported success")
		except shcl.SaveRefused:
			raise SystemExit("a failed write reported as a refusal") from None
		except shcl.SaveFailed:
			pass
		try:
			lostdoc.save_file(bad)
			raise SystemExit("save_file did not refuse an unwritable path")
		except shcl.SaveRefused as e:
			if e.lost != 1:
				raise SystemExit(f"SaveRefused lost got {e.lost}") from None
		# A save that keeps lines writes the dropped line back as it was, so it
		# refuses only when it falls back to canonical. Here removing the line
		# above it would make it a child of `a`.
		keep = shcl.Document.parse_keep_lines("a:\n\t\tb: 1\n\tc: 2\n", shcl.Strictness.Standard)
		if not keep.set_int("a.b", 5):
			raise SystemExit("keep set_int a.b failed")
		if keep.save_file_keep_lines(fpath) is not True:
			raise SystemExit("save_file_keep_lines did not keep the dropped line")
		with open(fpath, encoding="utf-8", newline="") as fh:
			if fh.read() != "a:\n\t\tb: 5\n\tc: 2\n":
				raise SystemExit("save_file_keep_lines wrote the wrong text")
		if keep.remove("a.b") != 1:
			raise SystemExit("keep remove a.b failed")
		try:
			keep.save_file_keep_lines(fpath)
			raise SystemExit("save_file_keep_lines did not refuse a canonical fallback")
		except shcl.SaveRefused as e:
			if e.lost != 1:
				raise SystemExit(f"SaveRefused lost got {e.lost}") from None
	test_id("Elop5Fi", "strict_failure_carries_document")
	# A failed strict load hands back the document and names the first
	# failures in the message - the diagnostics are the point.
	try:
		shcl.Document.parse_with("ok: 1\n: nope\n", shcl.Strictness.Strict)
		raise SystemExit("strict load unexpectedly passed")
	except shcl.LoadError as le:
		if le.document is None or le.document.read_int("ok").value != 1:
			raise SystemExit("LoadError does not include a usable document") from None
		if "; line " not in str(le):
			raise SystemExit("LoadError message lacks diagnostics: " + str(le)) from None
	test_id("ElonRnP", "raw_is_source_text")
	# raw: the verbatim value span from the source line, quotes and all - not
	# the canonical form, which rewrites `[a,  "b c"]` to `[a, "b c"]`. Same
	# fixture in every runner whose read result exposes raw (the C read
	# structs deliberately do not).
	rdoc = shcl.Document.parse('regex: "^\\d{2,3}$"\nlist: [a,  "b c"]\n')
	if rdoc.read_string("regex").raw != '"^\\d{2,3}$"':
		raise SystemExit(f"raw fixture mismatch: {rdoc.read_string('regex').raw!r}")
	if rdoc.read_string_array("list").raw != '[a,  "b c"]':
		raise SystemExit(f"raw fixture mismatch: {rdoc.read_string_array('list').raw!r}")
	# A written value has no source spelling; raw falls back to display. The
	# selector's escaped spelling must reach the existing instance.
	rdoc2 = shcl.Document.parse("who: 'q\"uote'\n")
	if not rdoc2.set_int('who("q◉DQUOTE◉uote").n', 5):
		raise SystemExit("escaped selector write failed")
	if rdoc2.count("who") != 1:
		raise SystemExit("escaped selector created a second instance")
	rr = rdoc2.read_int('who(\'q"uote\').n')
	if (rr.value, rr.status) != (5, shcl.Status.Good):
		raise SystemExit("escaped selector read failed")
	if rr.raw != "5":
		raise SystemExit(f"written raw mismatch: {rr.raw!r}")
	test_id("EnLD4c5", "convenience_tier_falls_back_only_on_good")
	# The get-tier value survives only on Good; Empty/BadType/NotFound all fall
	# back to the call-site default, so a real zero can't be faked. `_or` is the
	# cross-binding spelling for it, so a routine ported between two bindings
	# cannot keep the call name while changing which tier it uses. Same
	# fixture in every runner.
	cdoc = shcl.Document.parse("a: 42\nb: not-a-number\ne:\narr: [1, 2, 3]\nblk:\n\t```html\n\thi\n\t```\n")
	if cdoc.get_int_or("a", 9) != 42:
		raise SystemExit(f"get_int_or Good got {cdoc.get_int_or('a', 9)}")
	for p in ("b", "e", "missing"):
		if cdoc.get_int_or(p, 9) != 9:
			raise SystemExit(f"get_int_or({p!r}) did not fall back")
	if cdoc.get_int_array_or("arr", [7]) != [1, 2, 3]:
		raise SystemExit(f"get_int_array_or Good got {cdoc.get_int_array_or('arr', [7])}")
	if cdoc.get_int_array_or("missing", [7]) != [7]:
		raise SystemExit("get_int_array_or missing did not fall back")
	if cdoc.get_string_or("missing", "fb") != "fb":
		raise SystemExit("get_string_or missing did not fall back")
	# The must-exist form raises a class a caller can catch by its public name.
	try:
		cdoc.get_int("missing")
		raise SystemExit("get_int on a missing field did not raise")
	except shcl.StatusError as e:
		if e.status != shcl.Status.NotFound:
			raise SystemExit(f"get_int missing raised {e.status}") from None
	# The raw block's info-string was the one typed read with no convenience
	# tier, so it alone forced a caller down to the status tier.
	if cdoc.get_raw_info("blk") != "html":
		raise SystemExit("get_raw_info did not read the info-string")
	if cdoc.get_raw_info_or("blk", "fb") != "html":
		raise SystemExit("get_raw_info_or Good did not read through")
	if cdoc.get_raw_info_or("missing", "fb") != "fb":
		raise SystemExit("get_raw_info_or missing did not fall back")
	# ok() and the convenience tier deliberately disagree on an explicitly
	# emptied field: one asks whether the author spoke for it, the other whether
	# there is a usable value.
	if not cdoc.read_int("e").ok():
		raise SystemExit("an emptied field is not ok()")
	if cdoc.read_int("missing").ok():
		raise SystemExit("a missing field is ok()")
	test_id("EoM2uEn", "set_raw_keeps_a_shared_indent_and_trims_the_info")
	# The body's shared indent survives a reload (the closing fence's indent
	# is what comes off), the info-string is stored as a fence line reads it
	# back, and an info with a line break or a `#` has no spelling and fails
	# the write. Same fixture in every runner.
	rawdoc = shcl.Document.new()
	if not rawdoc.set_raw("q", "  a\n  b", " sql "):
		raise SystemExit("set_raw failed")
	rawback = shcl.Document.parse(rawdoc.to_canonical())
	if rawback.get_raw("q") != "  a\n  b":
		raise SystemExit(f"set_raw indent got {rawback.get_raw('q')!r}")
	if rawback.read_raw_info("q").value != "sql":
		raise SystemExit("set_raw info not trimmed")
	if rawdoc.set_raw("q", "x", "a\nb"):
		raise SystemExit("set_raw accepted an info with a line break")
	# A trailing CR is a blank and comes off, as the load takes it; one
	# mid-info is content.
	if not rawdoc.set_raw("q", "x", "ab\r"):
		raise SystemExit("set_raw refused an info ending in CR")
	if shcl.Document.parse(rawdoc.to_canonical()).read_raw_info("q").value != "ab":
		raise SystemExit("set_raw trailing CR info not trimmed")
	if not rawdoc.set_raw("q", "x", "a\rb"):
		raise SystemExit("set_raw refused an info with a mid-string CR")
	rawback = shcl.Document.parse(rawdoc.to_canonical())
	if rawback.read_raw_info("q").value != "a\rb":
		raise SystemExit(f"set_raw mid-string CR info got {rawback.read_raw_info('q').value!r}")
	if rawdoc.set_raw("q", "x", "a # b"):
		raise SystemExit("set_raw accepted an info with a #")
	# An info string has no quoting of its own: quotes are characters in it,
	# so they hide nothing, and a `#` glued to the label opens a comment too.
	if rawdoc.set_raw("q", "x", '"a # b"'):
		raise SystemExit("set_raw accepted a quoted #")
	if rawdoc.set_raw("q", "x", "c#"):
		raise SystemExit("set_raw accepted a # glued to the label")
	# A body line ending in CR has no fence spelling: the load takes the whole
	# trailing CR run off every line, so it is refused rather than lost. A CR
	# mid-line is content and still round-trips.
	if rawdoc.set_raw("q", "a\r\nb", "") or rawdoc.set_raw("q", "\r", ""):
		raise SystemExit("set_raw accepted a body with a line-ending CR")
	if not rawdoc.set_raw("q", "a\rb", ""):
		raise SystemExit("set_raw refused a body with a mid-line CR")
	rawback = shcl.Document.parse(rawdoc.to_canonical())
	if rawback.get_raw("q") != "a\rb":
		raise SystemExit(f"set_raw mid-line CR got {rawback.get_raw('q')!r}")
	test_id("EoM2uEo", "typed_setters_take_exactly_their_type")
	# Typed setters take exactly their type and raise a TypeError naming the
	# setter for anything else, rather than writing text the reader of that
	# type would call bad-type (set_int of 3.5 wrote `3.5`). bool is an int
	# in Python, so the int and float gates carve it out; an int is a float.
	tdoc = shcl.Document.parse("a: 1\n")
	for setter, args in (
		("set_int", ("a", 3.5)),
		("set_int", ("a", True)),
		("set_int", ("a", "3")),
		("set_float", ("a", True)),
		("set_float", ("a", "1.5")),
		("set_bool", ("a", 1)),
		("set_string", ("a", 5)),
		("set_datetime", ("a", "2026-01-01")),
		("set_int_array", ("a", [1, 2.5])),
		("set_float_array", ("a", [1.5, False])),
		("set_bool_array", ("a", [True, 0])),
		("set_string_array", ("a", ["x", None])),
		("set_datetime_array", ("a", ["2026-01-01"])),
		("set_int_default", ("a", 1.0)),
		("set_float_default", ("a", "1")),
		("set_bool_default", ("a", "true")),
		("set_string_default", ("a", 1)),
		("set_datetime_default", ("a", 1)),
		("set_int_array_default", ("a", [True])),
		("set_float_array_default", ("a", ["1"])),
		("set_bool_array_default", ("a", [1])),
		("set_string_array_default", ("a", [1])),
		("set_datetime_array_default", ("a", [1])),
	):
		try:
			getattr(tdoc, setter)(*args)
			raise SystemExit(f"{setter} accepted {args[1]!r}")
		except TypeError as e:
			if not str(e).startswith(setter + ":"):
				raise SystemExit(f"{setter} TypeError does not name it: {e}") from None
	if tdoc.to_canonical() != "a: 1\n":
		raise SystemExit("a refused setter changed the document")
	if not tdoc.set_float("f", 3) or tdoc.read_float("f").value != 3.0:
		raise SystemExit("set_float refused an int")
	if not tdoc.set_float_array_default("g", [1, 2.5]) or tdoc.read_float_array("g").value != [1.0, 2.5]:
		raise SystemExit("set_float_array_default refused an int element")
	test_id("EoSTzzc", "set_float_writes_an_int_as_its_f64")
	# Python-only: an int is written as the float it converts to, the f64 a
	# caller of the other bindings would hold - not its exact digits. One past
	# the float range has no f64 but inf, which the reader refuses, so it
	# fails the write like any other infinity.
	if not tdoc.set_float("h", 9007199254740993) or tdoc.read_string("h").value != "9007199254740992":
		raise SystemExit(f"set_float of a wide int wrote {tdoc.read_string('h').value!r}")
	if tdoc.set_float_array("i", [10 ** 400, -(10 ** 400)]) or tdoc.exists("i"):
		raise SystemExit("set_float_array past the float range bound a value")

	test_id("EpGigIQ", "setters_write_only_what_reads_back")
	setters_write_only_what_reads_back()
	test_id("Eqk24nb", "edits_and_merges_match_a_reload")
	edits_and_merges_match_a_reload()
	test_id("ErpmA4L", "a_remove_keeps_a_settled_line_below_it")
	a_remove_keeps_a_settled_line_below_it()

	test_id("EqAaU1A", "repr_names_the_fields")
	# Python-only: Diagnostic and Read used to print as object addresses, where
	# the other three print their fields. Printing a value is how Python gets
	# debugged, so the repr has to name them.
	rdoc = shcl.Document.parse("a: 1\nbad line\n")
	dtext = repr(rdoc.diagnostics()[0])
	if "E014" not in dtext or "line=2" not in dtext or "0x" in dtext:
		raise SystemExit(f"Diagnostic repr is not readable: {dtext}")
	rtext = repr(rdoc.read_int("a"))
	if "value=1" not in rtext or "Status.Good" not in rtext or "0x" in rtext:
		raise SystemExit(f"Read repr is not readable: {rtext}")

	test_id("EqMO8f2", "datetimes_compare_by_field")
	# Python-only, and the same class as the two above: two parses of one
	# datetime compared unequal, since nothing but identity said otherwise.
	# The other three compare field by field. Same-moment is a separate
	# question and belongs to the value code, so `12:00:00Z` and
	# `12:00:00+00:00` still differ here.
	ddoc = shcl.Document.parse("a: 2026-09-19T12:00:00Z\nb: 2026-09-19T12:00:00Z\n"
		"c: 2026-09-19T12:00:00+00:00\nd: 2026-09-19\n")
	da, db, dc, dd = (ddoc.get_datetime(p) for p in ("a", "b", "c", "d"))
	if da != db or hash(da) != hash(db) or len({da, db}) != 1:
		raise SystemExit("two parses of one datetime are not equal")
	if da in (dd, dc, "2026-09-19T12:00:00Z"):
		raise SystemExit("datetimes that differ compare equal")
	dtxt = repr(da)
	if "2026" not in dtxt or "zone=" not in dtxt or "0x" in dtxt:
		raise SystemExit(f"ShclDateTime repr is not readable: {dtxt}")

	test_id("EpGigIS", "a_line_break_in_a_path_writes_and_reads_back")
	# Both halves of a path can contain a line break and write it \n: a name
	# through the name escaper, a selector value through the value emitter. The
	# selector was refused while elements were stored in their source spelling
	# and the emitter had nothing to escape with. Same fixture in every runner.
	nldoc = shcl.Document.parse("z: 0\n")
	if not nldoc.set_int('x("p\nq").c', 1) or not nldoc.set_int('"a\nb".c', 1):
		raise SystemExit("a line break in a path was refused")
	nltext = nldoc.to_canonical()
	nlback = shcl.Document.parse(nltext)
	if nlback.error_count() != 0:
		raise SystemExit(f"the reload has {nlback.error_count()} error(s):\n{nltext}")
	if nlback.to_canonical() != nltext:
		raise SystemExit(f"a line break in a path is not a fixpoint:\n{nltext}")
	for nlpath in ('x("p◉NEWLINE◉q").c', '"a◉NEWLINE◉b".c', '"a\nb".c'):
		if nlback.read_int(nlpath).value != 1:
			raise SystemExit(f"read {nlpath!r} got {nlback.read_int(nlpath).value}")

	test_id("EoXKdQm", "hot_path_shortcuts_hold")
	# Three hot-path shortcuts this binding has because it is the slow one.
	# Each is asserted structurally, by what the code does rather than by a
	# clock: a wall-time threshold on a constant-factor win either flakes or
	# never fires. Their combined effect was parse-plus-emit 1.05 s -> 0.87 s on
	# a 1.7 MB document, output byte-identical.
	class _CountingList(list):
		iters = 0

		def __iter__(self):
			_CountingList.iters += 1
			return list.__iter__(self)

	pdoc = shcl.Document.parse("one: a\ntwo: [a, b]\n")
	for pnode in pdoc.arena:
		if pnode.value.kind in ("cell", "array"):
			pnode.value.els = _CountingList(pnode.value.els)
	for want_len, want_iters in ((1, 0), (2, 2)):
		_CountingList.iters = 0
		for pnode in pdoc.arena:
			if pnode.value.kind in ("cell", "array") and len(pnode.value.els) == want_len:
				pnode.value.display()
				shcl._merge_key(pnode.name, pnode.value)
		if _CountingList.iters != want_iters:
			raise SystemExit(
				f"display/merge-key walked a {want_len}-element cell {_CountingList.iters} time(s), want {want_iters}"
			)

	# The source-attach guard settles the common line by identity, so neither
	# key is built. Anything above zero means it went back to comparing a value
	# with itself the long way.
	key_calls = [0]
	real_value_key = shcl._value_key
	try:
		shcl._value_key = lambda v: (key_calls.__setitem__(0, key_calls[0] + 1), real_value_key(v))[1]
		shcl.Document.parse("".join(f"k{i}: v{i}\n" for i in range(200)))
	finally:
		shcl._value_key = real_value_key
	if key_calls[0]:
		raise SystemExit(f"the source-attach guard built {key_calls[0]} value key(s) on 200 plain lines")

	test_id("Eq4AfLU", "value_fast_path_matches_the_byte_loop")
	# The value fast path has to answer exactly what the byte loop does, at any
	# offset public tokenize_value takes - including one mid-character, where
	# the loop strides past a comma that bytes.find would have split on. U+00E9
	# is two bytes, so offset 1 is its continuation byte and the comma is at 2.
	nbtok = shcl.Tokens()
	shcl.tokenize_value("é,", 1, shcl.Rules.CURRENT, nbtok)
	nbspans = [(p.start, p.end) for p in nbtok.elements]
	if nbspans != [(1, 3)]:
		raise SystemExit(f"tokenize_value from a mid-character offset gave {nbspans}, want [(1, 3)]")
	# A comma splits only with a blank or the end after it, on the fast path
	# as in the loop. A `#` after the value sends the same text down the loop.
	for fv in ("a,b", "a, b", "a,", "a ,b", ",a", "a,,b", "a, ,b", " a , b", "x,\t,y", "rw,noatime, c"):
		ftok, ltok = shcl.Tokens(), shcl.Tokens()
		shcl.tokenize_value(fv, 0, shcl.Rules.CURRENT, ftok)
		shcl.tokenize_value(fv + "#c", 0, shcl.Rules.CURRENT, ltok)
		fspans = [(p.start, p.end) for p in ftok.elements]
		lspans = [(p.start, p.end) for p in ltok.elements]
		if fspans != lspans or ftok.value != ltok.value:
			raise SystemExit(f"{fv!r}: the fast path gave {fspans} {ftok.value}, the loop {lspans} {ltok.value}")

	test_id("Er7vwKQ", "format_version_caps_at_32_bits")
	# Digits past 32 bits are not a 2.x file either, so they read as the
	# current major, in every binding (20260926 item 9).
	if shcl.format_version("##    Format   4294967295\na: 1\n") != 4294967295:
		raise SystemExit("format_version: 4294967295 did not read as itself")
	if shcl.format_version("##    Format   4294967296\na: 1\n") != shcl.FORMAT_MAJOR:
		raise SystemExit("format_version: 4294967296 did not read as the current major")

	test_id("EpFxQH3", "tokenizer_helpers_are_module_level")
	# The tokenizer's helpers are module level. Defined inside it they would
	# be rebuilt, with a fresh cell each, once per document line.
	for fn in (shcl.tokenize, shcl.tokenize_value, shcl._scan_piece):
		inner = [c.co_name for c in fn.__code__.co_consts if isinstance(c, types.CodeType)]
		if inner:
			raise SystemExit(f"{fn.__name__} rebuilds {inner} on every call")

	test_id("EryEqsA", "a_comma_splits_a_bare_value_only_before_a_blank")
	# A comma splits a value outside brackets only with a blank, a comment or
	# the end after it; inside brackets every one does (value-syntax.md,
	# 20261006). 2.x split on every comma, which migrate still reads.
	ctok = shcl.Tokens()
	for cline, cpieces in (
		("x: rw,noatime", 1),
		("x: ,a", 1),
		("x: a,,b", 1),
		("x: a, b", 2),
		("x: a,", 2),
		("x: a,# c", 2),
		("x: a,\tb", 2),
		("x: [a,b]", 2),
		("x: [rw,noatime, c]", 3),
	):
		shcl.tokenize(cline, ":", False, shcl.Rules.CURRENT, ctok)
		if len(ctok.elements) != cpieces:
			raise SystemExit(f"{cline!r}: {len(ctok.elements)} pieces, want {cpieces}")
	shcl.tokenize("x: a,b", ":", False, shcl.Rules.V2, ctok)
	if len(ctok.elements) != 2:
		raise SystemExit(f"2.x: {len(ctok.elements)} pieces")

	test_id("EryEquE", "bare_spaces_colons_and_commas")
	# Spaces in a bare value or item are fine. A tab, a bracket, a quote, or a
	# colon or comma with a blank or the end after it is one error, and its
	# message says what to do.
	for btext, bcode, bfix in (
		("x: host: a.com port: 80\n", "E025", "put each field on its own line"),
		("x: done:\n", "E025", "quote it"),
		("x: a\tb\n", "E025", "quote it"),
		("x: a[b]c\n", "E025", "quote it"),
		("x: [New York, Boston]\n", "E025", "quote it"),
		("x: [a:, b]\n", "E025", "quote it"),
		("x: a,\n", "E026", "write an array in brackets"),
		("x: 80, 443\n", "E026", "write an array in brackets"),
		("x: a: b, c\n", "E025", "put each field on its own line"),
		("x:\n\t- name: value\n", "E027", "as instances"),
		("x:\n\t- name:\n", "E027", "as instances"),
		("x:\n\t- a, b\n", "E026", "quote the text"),
		("x:\n\t- a\tb\n", "E025", "quote it"),
		("x:\n\t- [a]\n", "E019", "quote the item"),
		("x(a:b).y: 1\n", "E025", "quote it"),
		("x(a,b).y: 1\n", "E025", "quote it"),
		("x(a[b).y: 1\n", "E025", "quote it"),
		("x(a(b).y: 1\n", "E025", "quote it"),
	):
		bds = shcl.Document.parse(btext).diagnostics()
		if len(bds) != 1 or bds[0].code != bcode or bfix not in bds[0].message:
			raise SystemExit(f"{btext!r}: {bds}")
	for btext, bpath, bwant in (
		("x: My  App\n", "x", "My  App"),
		("x: rw,noatime\n", "x", "rw,noatime"),
		("x: :0\n", "x", ":0"),
		("x: https://a.com:8080/p?q=1,2\n", "x", "https://a.com:8080/p?q=1,2"),
		("x: Jul 12 2026  # c\n", "x", "Jul 12 2026"),
		("x:\n\t- New  York\n\t- :0\n", "x", '["New  York", ":0"]'),
	):
		bdoc = shcl.Document.parse(btext)
		if bdoc.diagnostics():
			raise SystemExit(f"{btext!r}: {bdoc.diagnostics()}")
		if bdoc.get_string(bpath, None) != bwant:
			raise SystemExit(f"{btext!r}: {bdoc.read_string(bpath)!r}")
	if shcl.Document.parse("x: 80,443\n").read_int("x").status == shcl.Status.Good:
		raise SystemExit("80,443 read as a number")

	test_id("EryEqwF", "the_writer_quotes_a_colon_or_comma")
	# The reader takes a colon or comma bare where it is text, but the writer
	# quotes any whitespace, colon, comma, paren or bracket wherever it sits, so
	# nobody has to know the reader's rules. A quoted value keeps its quotes and
	# its quote kind, a quoted number included.
	qcdoc = shcl.Document.new()
	if not (qcdoc.set_string("opts", "rw,noatime") and qcdoc.set_string("display", ":0") and qcdoc.set_string("end", "a,")
			and qcdoc.set_string("title", "My App") and qcdoc.set_string_array("tags", ["rw,noatime", "b"])
			and qcdoc.set_string("call", "f(x)") and qcdoc.set_string("box", "a[0]") and qcdoc.set_string("tabbed", "a\tb")
			and qcdoc.set_string("plain", "a-b.c/d")):
		raise SystemExit("a setter refused")
	qcout = qcdoc.to_canonical()
	for qcwant in (
		'opts: "rw,noatime"\n', 'display: ":0"\n', 'end: "a,"\n', 'title: "My App"\n', 'tags: ["rw,noatime", b]\n',
		'call: "f(x)"\n', 'box: "a[0]"\n', 'tabbed: "a◉TAB◉b"\n', "plain: a-b.c/d\n",
	):
		if qcwant not in qcout:
			raise SystemExit(f"{qcwant!r} not in {qcout!r}")
	qcback = shcl.Document.parse(qcout)
	if qcback.to_canonical() != qcout:
		raise SystemExit(f"reload wrote {qcback.to_canonical()!r}")
	if qcback.get_string_array("tags", None) != ["rw,noatime", "b"]:
		raise SystemExit(f"tags: {qcback.read_string_array('tags')!r}")
	qcdoc = shcl.Document.parse('n: "1,000"\n')
	if qcdoc.to_canonical() != 'n: "1,000"\n':
		raise SystemExit(f"wrote {qcdoc.to_canonical()!r}")
	if qcdoc.get_int("n", None) != 1000:
		raise SystemExit(f"n: {qcdoc.read_int('n')!r}")
	qcdoc = shcl.Document.parse("ver: \"8\"\nok: 'true'\nat: 2:30PM\nhost: localhost:8080\n")
	if qcdoc.to_canonical() != "ver: \"8\"\nok: 'true'\nat: \"2:30PM\"\nhost: \"localhost:8080\"\n":
		raise SystemExit(f"wrote {qcdoc.to_canonical()!r}")
	if qcdoc.get_int("ver", None) != 8:
		raise SystemExit(f"ver: {qcdoc.read_int('ver')!r}")
	if not qcdoc.set_int("ver", 9) or not qcdoc.to_canonical().startswith('ver: "9"\n'):
		raise SystemExit(f"ver set wrote {qcdoc.to_canonical()!r}")
	qchint = shcl.Document.parse("t: a,b\nt: c\n").diagnostics()[0]
	if qchint.code != "H001" or 't: ["a,b", c]' not in qchint.message:
		raise SystemExit(f"hint {qchint!r}")

	test_id("ErylLpa", "a_list_no_text_loads_back_refuses_to_save")
	# A list with a field under it (E001) after an empty binding of its name
	# that has fields: no text loads it back, since a reload joins the list's
	# header to that binding and drops its items (E008). The load is left as
	# it is; a save that would write it refuses (2026100511210900). An edit
	# and a merge can each leave one. Same fixture in every runner.
	lsrc = "x: v\n\tf: 1\nx:\n\t- a\n\t- b\n\tg: 2\n"
	ldoc = shcl.Document.parse_keep_lines(lsrc, shcl.Strictness.Standard)
	if ldoc.lost_count() != 0:
		raise SystemExit(f"load lost {ldoc.lost_count()}")
	if not ldoc.set_empty("x(v)"):
		raise SystemExit("set empty refused")
	ltext = ldoc.to_canonical()
	if ltext != "x:\n\tf: 1\nx:\n\t- a\n\t- b\n\tg: 2\n":
		raise SystemExit(f"canonical {ltext!r}")
	if shcl.Document.parse(ltext).lost_count() != 2:
		raise SystemExit(f"the reload drops both items: {shcl.Document.parse(ltext).lost_count()}")
	if ldoc.lost_count() != 2:
		raise SystemExit(f"lost {ldoc.lost_count()}")
	if ldoc.to_text_keep_lines()[1]:
		raise SystemExit("the source was canonical, and still no lines are kept")
	with tempfile.TemporaryDirectory() as ld:
		lf = os.path.join(ld, "t.shcl")
		Path(lf).write_bytes(lsrc.encode())
		for lsave in (ldoc.save_file, ldoc.save_file_keep_lines):
			try:
				lsave(lf)
				raise SystemExit(f"{lsave.__name__} went through")
			except shcl.SaveRefused as e:
				if e.lost != 2:
					raise SystemExit(f"{lsave.__name__}: lost {e.lost}") from None
		if Path(lf).read_bytes() != lsrc.encode():
			raise SystemExit(f"file changed: {Path(lf).read_bytes()!r}")
		ldoc.save_file_lossy(lf)
	# The same through a merge: the list arrives over an empty binding.
	lmerged = shcl.Document.parse("x:\n\tf: 1\n")
	lmerged.merge(shcl.Document.parse("x:\n\t- a\n\t- b\n\tg: 2\n"))
	if lmerged.lost_count() != 2:
		raise SystemExit(f"merge lost {lmerged.lost_count()}: {lmerged.to_canonical()!r}")
	# An empty binding with no fields takes the list in, so nothing is lost,
	# and a list with no field under it goes in brackets.
	for lsrc in ("x: v\nx:\n\t- a\n\tg: 2\n", "x: v\n\tf: 1\nx:\n\t- a\n\t- b\n"):
		ldoc = shcl.Document.parse(lsrc)
		if not ldoc.set_empty("x(v)") or ldoc.lost_count() != 0:
			raise SystemExit(f"{lsrc!r}: lost {ldoc.lost_count()}: {ldoc.to_canonical()!r}")

	test_id("ErylLpb", "a_list_joining_an_emptied_field_keeps_its_fields_found")
	# A setter that empties a field joins the stacked list after it, fields
	# and all, as a reload would. A read made before the write has the lookup
	# built, and the fields that moved still have to be found through it.
	for jsrc, jpath, jfield, jwant in (
		("b: x\nb:\n\t- 3\n\tk: 1\n", "b(0)", "b.k", "1"),
		("b: x\nb: y z\n\t- 3\n\tk: 1\n", "b(0)", "b.k", "1"),
		("x: v\nx:\n\t- a\n\tg: 2\n", "x(v)", "x.g", "2"),
	):
		jdoc = shcl.Document.parse(jsrc)
		if jdoc.read_string(jfield).status != shcl.Status.Good:
			raise SystemExit(f"{jsrc!r}: before: {jdoc.read_string(jfield)!r}")
		if not jdoc.set_empty(jpath):
			raise SystemExit(f"{jsrc!r}: set empty refused")
		jback = shcl.Document.parse(jdoc.to_canonical())
		for jd, jwhich in ((jback, "reload"), (jdoc, "live")):
			jr = jd.read_string(jfield)
			if jr.status != shcl.Status.Good or jr.value != jwant:
				raise SystemExit(f"{jsrc!r}: {jwhich}: {jr!r}")
		if jdoc.paths() != jback.paths():
			raise SystemExit(f"{jsrc!r}: paths {jdoc.paths()} vs {jback.paths()}")

	test_id("ErylLpc", "a_list_the_source_loads_back_keeps_its_lines")
	# A load can build that list too, under a kept array line (E028). The
	# canonical text writes the line as a comment and cannot load the list
	# back, so that save refuses. The source text does, so with no edits the
	# save that keeps lines writes it as it was.
	ksrc = "c:\n\ts: 1\nc: [1]\n\tb(*): 1\n\t- 3\n\ta: 2\n"
	kdoc = shcl.Document.parse_keep_lines(ksrc, shcl.Strictness.Standard)
	if kdoc.lost_count() != 2:
		raise SystemExit(f"the wildcard line and the item: lost {kdoc.lost_count()}")
	if kdoc.to_text_keep_lines() != (ksrc, True):
		raise SystemExit(f"keep: {kdoc.to_text_keep_lines()!r}")
	with tempfile.TemporaryDirectory() as kd:
		kpath = os.path.join(kd, "t.shcl")
		Path(kpath).write_bytes(ksrc.encode())
		try:
			kdoc.save_file(kpath)
			raise SystemExit("save went through")
		except shcl.SaveRefused as e:
			if e.lost != 2:
				raise SystemExit(f"save: lost {e.lost}") from None
		if not kdoc.save_file_keep_lines(kpath):
			raise SystemExit("the keep save kept no lines")
		if Path(kpath).read_bytes() != ksrc.encode():
			raise SystemExit(f"file changed: {Path(kpath).read_bytes()!r}")

	test_id("ErylLpd", "a_merged_list_joins_an_empty_field_past_a_comment")
	# A merge adds a list with a field under it as a new instance after an
	# empty binding of its name. A comment or kept line left after the
	# binding held the join off, though a reload joins the two
	# (2026100520243961).
	for mbase in (
		"p:\n\ts:\n\t# c\n",
		"p:\n\ts:\n\tk: [1\n",
		"p:\n\ts:\n\t# c\n\t\t# d\n",
		"p:\n\ts:\n\t# c\n\tt: 2\n",
	):
		mdoc = shcl.Document.parse(mbase)
		mdoc.merge(shcl.Document.parse("p:\n\ts:\n\t\t- 0\n\t\tc: 1\n"))
		mtext = mdoc.to_canonical()
		mback = shcl.Document.parse(mtext)
		if mback.to_canonical() != mtext:
			raise SystemExit(f"{mbase!r}: not a fixpoint: {mtext!r}")
		if mdoc.paths() != mback.paths():
			raise SystemExit(f"{mbase!r}: paths {mdoc.paths()} vs {mback.paths()}")
		for md in (mdoc, mback):
			mr = md.read_string("p.s.c")
			if mr.status != shcl.Status.Good or mr.value != "1":
				raise SystemExit(f"{mbase!r}: p.s.c {mr!r}")
		if len(mdoc.instances("p.s")) != 1:
			raise SystemExit(f"{mbase!r}: {len(mdoc.instances('p.s'))} instances")

	test_id("ErylLpe", "a_remove_settles_a_list_after_an_empty_field")
	# The remove twin: the merge without the gap builds the list no text loads
	# back, after a binding with a field. A remove that takes that field joins
	# the list, and one that takes the list's field puts it in brackets, as a
	# reload reads each.
	for rpath, rwant in (
		("p.s.x", "p:\n\ts:\n\t\t- 0\n\t\tc: 1\n"),
		("p.s.c", "p:\n\ts:\n\t\tx: 1\n\ts: [0]\n"),
	):
		rdoc = shcl.Document.parse("p:\n\ts:\n\t\tx: 1\n")
		rdoc.merge(shcl.Document.parse("p:\n\ts:\n\t\t- 0\n\t\tc: 1\n"))
		if rdoc.lost_count() == 0:
			raise SystemExit(f"{rpath}: the list no text loads back")
		if rdoc.remove(rpath) != 1:
			raise SystemExit(f"{rpath}: remove missed")
		rtext = rdoc.to_canonical()
		if rtext != rwant:
			raise SystemExit(f"{rpath}: {rtext!r}")
		rback = shcl.Document.parse(rtext)
		if rback.to_canonical() != rtext or rdoc.paths() != rback.paths():
			raise SystemExit(f"{rpath}: reload differs")
		if rdoc.lost_count() != 0:
			raise SystemExit(f"{rpath}: lost {rdoc.lost_count()}")

	test_id("ErylLpf", "a_setter_keeps_fields_and_arrays_apart")
	# A field with lines under it takes one plain value or none (E028), so a
	# setter puts no field under an array and no array over fields. Each used
	# to write text that reloads as E028.
	asrc = "l: [a]\nc: 1\n\tk: 2\n"
	adoc = shcl.Document.parse(asrc)
	if adoc.set_int("l.c", 1):
		raise SystemExit(f"a field under an array: {adoc.to_canonical()!r}")
	if adoc.set_literal("c", "[1, 2]") or adoc.set_string_array("c", ["1"]):
		raise SystemExit(f"an array over fields: {adoc.to_canonical()!r}")
	if adoc.to_canonical() != asrc:
		raise SystemExit(f"changed: {adoc.to_canonical()!r}")
	# An array with nothing under it takes a new one, and a stacked list
	# written with '- ' stays stacked.
	adoc = shcl.Document.parse("l: [a]\nz:\n\t- a\n\t- b\n")
	if not adoc.set_string_array("l", ["b", "c"]) or not adoc.set_string_array("z", ["x"]):
		raise SystemExit("an array setter refused")
	if adoc.to_canonical() != "l: [b, c]\nz:\n\t- x\n":
		raise SystemExit(f"got {adoc.to_canonical()!r}")

	test_id("ErysKPJ", "bracket_selectors_are_the_old_spelling")
	# A selector is written in parens. One in brackets is the old spelling: a
	# file line is E029 and kept, and a lookup, a setter or a schema path in
	# brackets is refused. A body starting with `#`, the old index, is refused
	# too. Same fixture in every runner.
	odoc = shcl.Document.parse("srv: web\n\tport: 80\nsrv[web]:\n\thost: h\n")
	ods = odoc.diagnostics()
	if len(ods) != 1 or ods[0].code != "E029" or ods[0].line != 3:
		raise SystemExit(f"diagnostics {ods}")
	if odoc.lost_count() != 0:
		raise SystemExit(f"lost {odoc.lost_count()}")
	if odoc.read_string("srv(web).host").value != "h":
		raise SystemExit(f"srv(web).host = {odoc.read_string('srv(web).host')!r}")
	if odoc.count("srv") != 1:
		raise SystemExit(f"srv count {odoc.count('srv')}")
	# Was NotFound until reads got BadPath (2026100717500001).
	# if odoc.read_string("srv[web].host").status != shcl.Status.NotFound:
	# 	raise SystemExit(f"srv[web].host {odoc.read_string('srv[web].host')!r}")
	if odoc.read_string("srv[web].host").status != shcl.Status.BadPath:
		raise SystemExit(f"srv[web].host {odoc.read_string('srv[web].host')!r}")
	if odoc.count("srv[web]") != 0:
		raise SystemExit(f"srv[web] count {odoc.count('srv[web]')}")
	for opath, owant in (
		("srv[web].x", shcl.SetStatus.BadPath),
		("srv(#0).x", shcl.SetStatus.BadPath),
		("srv(0).x", shcl.SetStatus.Ok),
	):
		if odoc.check_set_path(opath) != owant:
			raise SystemExit(f"check_set_path({opath!r}) = {odoc.check_set_path(opath)}, want {owant}")
	if odoc.set_int("srv[web].x", 1):
		raise SystemExit("a setter took a path in brackets")
	if not odoc.set_int("srv(web).x", 1):
		raise SystemExit("a setter refused srv(web).x")
	if not odoc.to_canonical().startswith("srv[web]:\nsrv: web\n"):
		raise SystemExit(f"got {odoc.to_canonical()!r}")
	otok = shcl.Tokens()
	shcl.tokenize("a(x).b[y].c: 1", ":", False, shcl.Rules.CURRENT, otok)
	if otok.bracket_selector != 6:
		raise SystemExit(f"bracket_selector {otok.bracket_selector}, want 6")
	shcl.tokenize("a(x).b(y).c: 1", ":", False, shcl.Rules.CURRENT, otok)
	if otok.bracket_selector is not None:
		raise SystemExit(f"bracket_selector {otok.bracket_selector}, want None")
	oschema = shcl.Document.parse('field: "srv[*].port"\n')
	if not any(v.code == "V093" and "parens" in v.message for v in shcl.Document.parse("srv: a\n").validate(oschema)):
		raise SystemExit("no V093 naming parens")

	test_id("ErysKS0", "init_refuses_a_child_of_an_array_parent")
	# A parent whose default is an array has no selector a child line can use,
	# since a selector matches one plain value. Generation refuses it rather
	# than write a child that makes another instance.
	aschema = shcl.Document.parse("field: tags\n\trequired: yes\n\tdefault: [a]\nfield: tags.k\n\trequired: yes\n")
	atext, afaults = shcl.generate(aschema, True)
	if not any(d.code == "V097" and "no selector spelling" in d.message for d in afaults):
		raise SystemExit(f"a child of an array parent generated: {atext!r} {afaults}")

	test_id("Es1eIOp", "migrate_brackets_a_2x_comma_list")
	# migrate writes a 2.x comma list in brackets, with or without a blank
	# after the comma, since 2.x read both as arrays. In a file that does not
	# say it is 2.x, `a,b` is a string under these rules, so it is left and
	# counted; `a, b` is an error here, so it converts either way. A lone bare
	# value these rules refuse is quoted.
	mm = shcl.migrate("x: a, b\ny: a,b\nz: \"q\", r\nw: New York,,b\nv: done:\nu: rw,noatime\n", True)
	if mm.ambiguous != 0:
		raise SystemExit(f"ambiguous {mm.ambiguous}")
	if not mm.text.startswith("x: [a, b]\ny: [a, b]\nz: [\"q\", r]\nw: [\"New York\", b]\nv: \"done:\"\nu: [rw, noatime]\n"):
		raise SystemExit(repr(mm.text))
	if shcl.Document.parse(mm.text).diagnostics():
		raise SystemExit(f"{shcl.Document.parse(mm.text).diagnostics()}")
	mm = shcl.migrate("x: a, b\ny: a,b\n", False)
	if mm.ambiguous != 1:
		raise SystemExit(f"ambiguous {mm.ambiguous}")
	if not mm.text.startswith("x: [a, b]\ny: a,b\n"):
		raise SystemExit(repr(mm.text))

	test_id("Es1eIOq", "migrate_writes_star_items_as_dashes")
	# A 2.x `*` item becomes `- `, and an item these rules would read as
	# something else is quoted, such as one that looks like `- name: value`.
	mm = shcl.migrate("list:\n\t* a\n\t* key: value\n\t* 'c'\n\t* O'Brien\n", True)
	if not mm.text.startswith("list:\n\t- a\n\t- \"key: value\"\n\t- 'c'\n\t- \"O'Brien\"\n"):
		raise SystemExit(repr(mm.text))
	mback = shcl.Document.parse(mm.text)
	if mback.diagnostics():
		raise SystemExit(f"{mback.diagnostics()}")
	mread = mback.read_string_array("list")
	if mread.status != shcl.Status.Good or mread.value != ["a", "key: value", "c", "O'Brien"]:
		raise SystemExit(f"list: {mread.value!r} {mread.status}")

	test_id("Es1eIOr", "migrate_quotes_a_name_not_led_by_a_letter")
	# A bare 2.x name not led by a letter is quoted, so `-x: y` and `- :0`
	# stay fields rather than reading as list items, and `404` stays a name.
	mm = shcl.migrate("404: a\n-x: y\nl:\n\t- :0\na.9b: 2\n_id: 7\n", True)
	if not mm.text.startswith("\"404\": a\n\"-x\": y\nl:\n\t\"-\" :0\na.\"9b\": 2\n\"_id\": 7\n"):
		raise SystemExit(repr(mm.text))
	mback = shcl.Document.parse(mm.text)
	if mback.diagnostics():
		raise SystemExit(f"{mback.diagnostics()}")
	for mpath, mwant in (("\"-x\"", "y"), ("l.\"-\"", "0")):
		mread = mback.read_string(mpath)
		if mread.status != shcl.Status.Good or mread.value != mwant:
			raise SystemExit(f"{mpath}: {mread.value!r} {mread.status}")
	mint = mback.read_int("a.\"9b\"")
	if mint.status != shcl.Status.Good or mint.value != 2:
		raise SystemExit(f"a.9b: {mint.value!r} {mint.status}")

	test_id("Es1eIOs", "migrate_escapes_a_real_mark")
	# 2.x read a `◉` as text. A name, a bare value and a selector body
	# holding one get the escape for a real mark, so they still read as that
	# text.
	mm = shcl.migrate("\"a\u25c9q\u25c9\": 1\nbare: My\u25c9SPACE\u25c9App\ns[x\u25c9y].p: 2\n", True)
	mback = shcl.Document.parse(mm.text)
	if mback.diagnostics():
		raise SystemExit(f"{mback.diagnostics()}\n{mm.text}")
	mpaths = mback.paths()
	if len(mpaths) < 2 or mpaths[0] != "\"a\u25c9ESCAPE_CHAR\u25c9q\u25c9ESCAPE_CHAR\u25c9\"" or mpaths[1] != "bare":
		raise SystemExit(f"{mpaths!r}\n{mm.text}")
	mread = mback.read_string("bare")
	if mread.status != shcl.Status.Good or mread.value != "My\u25c9SPACE\u25c9App":
		raise SystemExit(f"bare: {mread.value!r} {mread.status}")
	if mback.count("s") != 1:
		raise SystemExit(f"count s {mback.count('s')}")
	mread = mback.read_string("s(0)")
	if mread.status != shcl.Status.Good or mread.value != "x\u25c9y":
		raise SystemExit(f"s(0): {mread.value!r} {mread.status}")

	test_id("Es1eIOt", "migrate_quotes_a_bare_selector_these_rules_refuse")
	# A 2.x selector goes in parens, and a bare body these rules refuse, such
	# as one with a quote or a space, is quoted, so its block still loads.
	mm = shcl.migrate("srv[O'Brien].port: 1\nsrv[New York].port: 2\n", True)
	if not mm.text.startswith("srv(\"O'Brien\").port: 1\nsrv(\"New York\").port: 2\n"):
		raise SystemExit(repr(mm.text))
	mback = shcl.Document.parse(mm.text)
	if mback.diagnostics():
		raise SystemExit(f"{mback.diagnostics()}")
	if mback.count("srv") != 2:
		raise SystemExit(f"count srv {mback.count('srv')}")

	test_id("Es1eIOu", "migrate_writes_selectors_in_parens")
	# Every 2.x selector goes in parens: an index, a value, the sugar on a
	# segment before the last, and a body with a paren in it, quoted. A
	# selector in brackets is E029 under these rules, so a file that does not
	# say it is 2.x gets the same rewrite, with nothing counted.
	mtext = "a[x].k: 1\nb: y\nb[0].k: 2\nc[a(b)].k: 3\ne:[f].g: 4\nr[\"x\"]:\n\ts: 1\n"
	mwant_text = "a(x).k: 1\nb: y\nb(0).k: 2\nc(\"a(b)\").k: 3\ne(f).g: 4\nr(\"x\"):\n\ts: 1\n"
	for mfrom in (True, False):
		mm = shcl.migrate(mtext, mfrom)
		if mm.ambiguous != 0 or mm.lost != 0:
			raise SystemExit(f"from_v2 {mfrom}: ambiguous {mm.ambiguous}, lost {mm.lost}\n{mm.text}")
		if not mm.text.startswith(mwant_text):
			raise SystemExit(f"from_v2 {mfrom}: {mm.text!r}")
	mback = shcl.Document.parse(shcl.migrate(mtext, True).text)
	if mback.diagnostics():
		raise SystemExit(f"{mback.diagnostics()}")
	for mpath, mwant_int in (("c(\"a(b)\").k", 3), ("e(f).g", 4), ("b(y).k", 2), ("r(x).s", 1)):
		mint = mback.read_int(mpath)
		if mint.status != shcl.Status.Good or mint.value != mwant_int:
			raise SystemExit(f"{mpath}: {mint.value!r} {mint.status}")

	test_id("Es1eIOv", "migrate_counts_what_nothing_spells")
	# What 2.x bound and nothing spells now is counted lost, so the CLI
	# refuses at 7: a selector with a comma, which matched an array value, and
	# a comma list with lines under it. A list of only empty slots, which 2.x
	# read as empty, is an empty value.
	mm = shcl.migrate("a[x, y].b: 1\n", True)
	if mm.lost != 1:
		raise SystemExit(f"lost {mm.lost}")
	mm = shcl.migrate("a: 1, 2\n\tb: 1\nc: 3, 4\n", True)
	if mm.lost != 1:
		raise SystemExit(f"lost {mm.lost}\n{mm.text}")
	mm = shcl.migrate("e: ,\nf: , # c\n", True)
	if mm.lost != 0:
		raise SystemExit(f"lost {mm.lost}")
	if not mm.text.startswith("e:\nf: # c\n"):
		raise SystemExit(repr(mm.text))
	mback = shcl.Document.parse(mm.text)
	if mback.diagnostics():
		raise SystemExit(f"{mback.diagnostics()}")
	if mback.read_string("e").status != shcl.Status.Empty:
		raise SystemExit(f"e: {mback.read_string('e').status}")

	test_id("Es1eIOw", "migrate_leaves_what_reads_clean_now")
	# A file that does not say it is 2.x could be a 3.0 one. A piece that
	# reads clean under these rules too, such as an escape, a backtick value,
	# `[a]` or a `- ` item, is left as written and counted, so the CLI asks
	# for --from-2x rather than changing a correct file at exit 0. A selector
	# in brackets is E029 now, so its line is rewritten the 2.x way.
	mtext = "x: \"a\u25c9TAB\u25c9b\"\n\"n\u25c9TAB\u25c9\": 1\nl:\n\t- :0\ns[\"\u25c9TAB\u25c9\"].p: 1\nb: `abc`\nc: [a]\n"
	mm = shcl.migrate(mtext, False)
	if mm.ambiguous != 5:
		raise SystemExit(f"ambiguous {mm.ambiguous}\n{mm.text}")
	mwant_text = mtext.replace("s[\"\u25c9TAB\u25c9\"]", "s(\"\u25c9ESCAPE_CHAR\u25c9TAB\u25c9ESCAPE_CHAR\u25c9\")", 1)
	if mm.text != mwant_text:
		raise SystemExit(f"got {mm.text!r}\nwant {mwant_text!r}")
	if "ESCAPE_CHAR" not in shcl.migrate(mtext, True).text:
		raise SystemExit("no ESCAPE_CHAR with from_v2")

	# upgrade and upgrade_file (2026100313461649): a file this version cannot
	# load clean is backed up under a timestamped name and written fresh, and
	# a good one is never touched. The backup's name reads the clock, so it is
	# pinned for all of them.
	held_clock = os.environ.get("SHCL_TEST_CLOCK")
	os.environ["SHCL_TEST_CLOCK"] = "2026-10-04 00:15:00 -420 PDT"
	up_v2 = "name: \"say \\\"hi\\\"\"\ntags: a, b\n\n#\n# This config file format is SHCL.\n# \"Simple Hierarchical Config Language\"\n#    Legal    SHCL is Copyright © 2026 Jim Collier. License: MIT. No warranty.\n#\n"
	up_tag = "_backup_20261004-001500_format-v2"

	test_id("Es2k1AZ", "upgrade_leaves_a_clean_or_stamped_file")
	# a,b is one string now and an array under 2.x, but it loads clean, and
	# nothing says the file is 2.x.
	up = shcl.upgrade("a: 1\nb: x,y\n", False)
	if not up.current or up.text != "a: 1\nb: x,y\n" or up.diagnostics:
		raise SystemExit(f"clean: {up.current} {up.text!r} {up.diagnostics}")
	if not shcl.upgrade(f"p: a,b\n\n{shcl.GEN_BANNER}", True).current:
		raise SystemExit("stamped: not current")
	# A beta build stamped the same Format line, so its errors are left too.
	up_beta = f"tags: a, b\n\n{shcl.GEN_BANNER}"
	up = shcl.upgrade(up_beta, True)
	if not up.current or up.text != up_beta or up.format != 3:
		raise SystemExit(f"beta: {up.current} {up.format} {up.text!r}")

	test_id("Es2k1DD", "upgrade_from_v2_rewrites_a_clean_file_that_reads_differently")
	# The caller says it is 2.x, where a,b was an array.
	up = shcl.upgrade("p: a,b\n", True)
	if up.current or up.lost != 0 or up.diagnostics:
		raise SystemExit(f"a,b: {up.current} {up.lost} {up.diagnostics}")
	if up.text != f"p: [a, b]\n\n{shcl.GEN_BANNER}":
		raise SystemExit(repr(up.text))
	# Nothing reads differently, so there is nothing to do.
	up = shcl.upgrade("a: 1\nb: x\n", True)
	if not up.current or up.text != "a: 1\nb: x\n":
		raise SystemExit(f"same: {up.current} {up.text!r}")

	test_id("Es2k1Fd", "upgrade_writes_a_fresh_file_with_the_info_block")
	up = shcl.upgrade(up_v2, False)
	if up.current or up.ambiguous != 0 or up.lost != 0 or up.format != 2:
		raise SystemExit(f"{up.current} {up.ambiguous} {up.lost} {up.format}")
	if not any(d.code == "E026" for d in up.diagnostics):
		raise SystemExit(f"{up.diagnostics}")
	# 2.x's block goes, links or none, and the one init writes takes its
	# place.
	up_want = f"name: 'say \\\"hi\\\"'\ntags: [a, b]\n\n{shcl.GEN_BANNER}"
	if up.text != up_want:
		raise SystemExit(f"got {up.text!r}\nwant {up_want!r}")
	if not shcl.upgrade(up.text, False).current:
		raise SystemExit("the fresh text is not current")

	test_id("Es2k1IT", "upgrade_refuses_text_that_reads_two_ways")
	up_amb = "a: x,y\nb: \"q\n"
	up = shcl.upgrade(up_amb, False)
	if up.current or up.ambiguous != 1 or up.text != up_amb:
		raise SystemExit(f"{up.current} {up.ambiguous} {up.text!r}")
	up = shcl.upgrade(up_amb, True)
	if up.ambiguous != 0 or not up.text.startswith("a: [x, y]\nb: '\"q'\n\n##\n"):
		raise SystemExit(f"from_v2: {up.ambiguous} {up.text!r}")

	test_id("Es2k1LA", "backup_name_puts_the_tag_before_the_extension")
	for up_file, up_format, up_want in (
		("f.shcl", 2, f"f{up_tag}.shcl"),
		("a/b.c.shcl", 2, f"a/b.c{up_tag}.shcl"),
		(".shclrc", 2, f".shclrc{up_tag}"),
		("d.x/f", 2, f"d.x/f{up_tag}"),
		("f.shcl", 3, "f_backup_20261004-001500_format-v3.shcl"),
	):
		if shcl.backup_file_name(up_file, up_format) != up_want:
			raise SystemExit(f"{up_file}: {shcl.backup_file_name(up_file, up_format)!r}")

	test_id("Es2k1Ny", "upgrade_file_backs_up_then_rewrites")
	with tempfile.TemporaryDirectory() as ud:
		up_path = os.path.join(ud, "f.shcl")
		with open(up_path, "wb") as uf:
			uf.write(up_v2.encode("utf-8"))
		if os.name == "posix":
			os.chmod(up_path, 0o640)
		up = shcl.upgrade_file(up_path, False)
		up_backup = os.path.join(ud, f"f{up_tag}.shcl")
		if up.backup != up_backup:
			raise SystemExit(f"backup {up.backup!r}")
		with open(up_backup, "rb") as uf:
			if uf.read() != up_v2.encode("utf-8"):
				raise SystemExit("the backup is not the original")
		with open(up_path, "rb") as uf:
			if uf.read() != up.text.encode("utf-8"):
				raise SystemExit("the file is not the fresh text")
		if os.name == "posix" and stat.S_IMODE(os.stat(up_backup).st_mode) != 0o640:
			raise SystemExit(f"mode {stat.S_IMODE(os.stat(up_backup).st_mode):o}")
		# The second start finds a current file and writes nothing.
		up = shcl.upgrade_file(up_path, False)
		if not up.current or up.backup != "" or len(os.listdir(ud)) != 2:
			raise SystemExit(f"again: {up.current} {up.backup!r} {os.listdir(ud)}")

	test_id("Es2k1Qn", "upgrade_file_never_writes_over_a_backup")
	with tempfile.TemporaryDirectory() as ud:
		up_path = os.path.join(ud, "f.shcl")
		with open(up_path, "wb") as uf:
			uf.write(up_v2.encode("utf-8"))
		up_backup = os.path.join(ud, f"f{up_tag}.shcl")
		with open(up_backup, "wb") as uf:
			uf.write(b"x\n")
		try:
			shcl.upgrade_file(up_path, False)
			raise SystemExit("taken: wrote")
		except shcl.UpgradeBackupTaken as e:
			if e.name != up_backup:
				raise SystemExit(f"taken: {e.name!r}") from None
		with open(up_path, "rb") as uf:
			if uf.read() != up_v2.encode("utf-8"):
				raise SystemExit("taken: the file changed")
		with open(up_backup, "rb") as uf:
			if uf.read() != b"x\n":
				raise SystemExit("taken: the backup changed")
		# Nothing at the path, and text that reads two ways, write nothing.
		try:
			shcl.upgrade_file(os.path.join(ud, "none.shcl"), False)
			raise SystemExit("none: no error")
		except shcl.UpgradeNotFound:
			pass
		up_amb_path = os.path.join(ud, "amb.shcl")
		with open(up_amb_path, "wb") as uf:
			uf.write(b"a: x,y\nb: \"q\n")
		try:
			shcl.upgrade_file(up_amb_path, False)
			raise SystemExit("amb: no error")
		except shcl.UpgradeAmbiguous as e:
			if e.count != 1:
				raise SystemExit(f"amb: count {e.count}") from None
		if len(os.listdir(ud)) != 3:
			raise SystemExit(f"left {os.listdir(ud)}")
	if held_clock is None:
		del os.environ["SHCL_TEST_CLOCK"]
	else:
		os.environ["SHCL_TEST_CLOCK"] = held_clock

	test_id_end()
	print(f"conformance: {len(cases)} case(s) pass")
	return 0


if __name__ == "__main__":
	## An exit or an exception fails the test that was open, and any corpus
	## case it names.
	try:
		rc = main()
	except SystemExit as e:
		if e.code not in (None, 0):
			if _corpus:
				corpus_lines(str(e.code))
			test_id_end("FAIL")
		raise
	except BaseException as e:
		if _corpus:
			corpus_lines(str(e))
		test_id_end("FAIL")
		raise
	test_id_end("FAIL" if rc else None)
	sys.exit(rc)
