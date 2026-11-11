#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

# The save's changed, create-only and not-regular checks against a real
# folder, over cases drawn from project/fs-rules.tsv: a load spelling, a save
# spelling, and what another program did between them. The expected answer
# comes from reading the folder, never from the library. Rust's
# tests/fs_property.rs is the reference, function for function
# (2026110616475901).
#
# The folder is SHCL_FS_DIR, which the pipeline points at a tmpfs made for the
# run. The budget is SHCL_FS_SECS of wall clock, and SHCL_FUZZ_DUMP gets every
# case run, with its answer, in fs/python-rows.tsv and fs/python-drawn.tsv.
# SHCL_FS_SEED runs only that seed, to replay a failure. Run it as the gate
# does, with -X dev -W error::ResourceWarning.

from __future__ import annotations

import os
import shutil
import stat
import sys
import tempfile
import time
from contextlib import suppress
from dataclasses import dataclass, field
from typing import Any, NamedTuple

_HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))
import shcl  # noqa: E402

_REPO = os.path.dirname(os.path.dirname(os.path.dirname(_HERE)))
RULES = os.path.join(_REPO, "project", "fs-rules.tsv")

# The fewest generated cases a run makes, whatever the budget, so the draw
# guard has enough to judge.
MIN_CASES = 400

LOADED = b"a: 1\n"
OTHER = b"b: 2\n"
MARKER = b"marker: 1\n"

MASK = (1 << 64) - 1

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


class Fatal(Exception):
	"""A test can't go on, as a failed assert or t.Fatal ends it elsewhere."""


@dataclass
class Rule:
	name: str
	path: str
	cwd: str
	os: str


@dataclass
class Rules:
	spells: list[Rule] = field(default_factory=list)
	events: list[Rule] = field(default_factory=list)


def read_rules() -> Rules:
	with open(RULES, encoding="utf-8") as f:
		data = f.read()
	r = Rules()
	for line in data.split("\n"):
		if not line or line.startswith("#"):
			continue
		fields = line.split("\t")
		if len(fields) != 5:
			raise Fatal(f"fs-rules.tsv: not 5 fields: {line!r}")
		rule = Rule(name=fields[1], path=fields[2], cwd=fields[3], os=fields[4])
		on_this_os(rule.os)
		if fields[0] == "spell":
			r.spells.append(rule)
		elif fields[0] == "event":
			r.events.append(rule)
		else:
			raise Fatal(f"fs-rules.tsv: no such kind {fields[0]!r}")
	return r


def on_this_os(os_name: str) -> bool:
	if os_name == "any":
		return True
	if os_name == "posix":
		return os.name != "nt"
	if os_name == "macos":
		return sys.platform == "darwin"
	if os_name == "windows":
		return os.name == "nt"
	raise Fatal(f"fs-rules.tsv: no such os {os_name!r}")


class SplitMix:
	"""splitmix64, since it's a few lines in every binding."""

	def __init__(self, seed: int) -> None:
		self.state = seed & MASK

	def next(self) -> int:
		self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
		z = self.state
		z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
		z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
		return z ^ (z >> 31)

	def below(self, n: int) -> int:
		return self.next() % n


@dataclass
class Case:
	t_there: bool = False
	o_there: bool = False
	load: int = 0
	save: int = 0
	events: list[int] = field(default_factory=list)
	create: bool = False
	force: bool = False


def draw(r: Rules, seed: int) -> Case:
	g = SplitMix(seed)
	c = Case()
	c.t_there = g.below(2) == 1
	c.o_there = g.below(2) == 1
	c.load = g.below(len(r.spells))
	c.save = g.below(len(r.spells))
	for _ in range(1 + g.below(2)):
		c.events.append(g.below(len(r.events)))
	c.create = g.below(4) == 0
	c.force = g.below(4) == 0
	return c


# Named as Rust's Debug names them, so the dumps compare as text.
OK = "Ok"
CHANGED = "Changed"
EXISTS = "Exists"
IS_DIRECTORY = "IsDirectory"
NOT_REGULAR = "NotRegular"
IO = "Io"
OUTCOMES = (OK, CHANGED, EXISTS, IS_DIRECTORY, NOT_REGULAR, IO)


def classify(err: BaseException | None) -> str:
	if err is None:
		return OK
	if isinstance(err, shcl.SaveChanged):
		return CHANGED
	if isinstance(err, shcl.SaveExists):
		return EXISTS
	if isinstance(err, (shcl.SaveFailed, shcl.WriteError)):
		if err.status is shcl.WriteStatus.IsDirectory:
			return IS_DIRECTORY
		if err.status is shcl.WriteStatus.NotRegular:
			return NOT_REGULAR
		return IO
	raise AssertionError(f"a save this test never asks for: {err!r}") from err


class At(NamedTuple):
	"""What sits at a path, followed through links, read without the library."""
	kind: str  # nothing, file, unreadable, dir, special
	data: bytes = b""


def at(p: str) -> At:
	try:
		st = os.stat(p)
	except OSError:
		return At("nothing")
	if stat.S_ISREG(st.st_mode):
		try:
			with open(p, "rb") as f:
				return At("file", f.read())
		except OSError:
			return At("unreadable")
	if stat.S_ISDIR(st.st_mode):
		return At("dir")
	return At("special")


# The spelling's path, as the library gets it from its working folder.
def spelled(rule: Rule, w: str) -> str:
	p = rule.path.replace("{W}", w)
	if "{S}" in p:
		p = p.replace("{S}", short_form(w))
	return p


# The 8.3 short form of a folder that's there, from the OS.
def short_form(p: str) -> str:
	if sys.platform != "win32":
		return p
	import ctypes

	buf = ctypes.create_unicode_buffer(1024)
	n = ctypes.windll.kernel32.GetShortPathNameW(p, buf, len(buf))
	if not 0 < n < len(buf):
		raise Fatal(f"no short form of {p}")
	return buf.value


# The same path from the case's root, for reading and events. Plain text, not
# os.path.join, so nodir/.. still meets the kernel.
def from_root(root: str, cwd: str, path: str) -> str:
	if os.path.isabs(path):
		return path
	return root + "/" + cwd + "/" + path


def build(root: str, c: Case) -> None:
	w = os.path.join(root, "w")
	os.makedirs(os.path.join(w, "sub"), 0o755)
	os.mkdir(os.path.join(root, "o"), 0o755)
	with open(os.path.join(w, "sub", "t.shcl"), "wb") as f:
		f.write(b"s: 1\n")
	if c.t_there:
		with open(os.path.join(w, "t.shcl"), "wb") as f:
			f.write(LOADED)
	if c.o_there:
		with open(os.path.join(root, "o", "t.shcl"), "wb") as f:
			f.write(b"o: 1\n")
	if os.name != "nt":
		os.symlink(".", os.path.join(w, "lw"))
		os.symlink("t.shcl", os.path.join(w, "lt.shcl"))
		os.symlink("gone.shcl", os.path.join(w, "dl.shcl"))
		os.symlink("cy2.shcl", os.path.join(w, "cy.shcl"))
		os.symlink("cy.shcl", os.path.join(w, "cy2.shcl"))


def is_fifo(p: str) -> bool:
	try:
		return stat.S_ISFIFO(os.stat(p).st_mode)
	except OSError:
		return False


# Removes what's at the path but never a folder, as Rust's remove_file.
def remove_file(p: str) -> None:
	with suppress(OSError):
		if not stat.S_ISDIR(os.lstat(p).st_mode):
			os.remove(p)


def _try(f: Any, *args: Any) -> None:
	with suppress(OSError):
		f(*args)


# Another program's act between the load and the save. Each one that the tree
# makes impossible, such as a write through a link cycle, does nothing, the
# same in both trees.
def apply(event: str, root: str, load: str, save: str) -> None:
	w = os.path.join(root, "w")

	def write(p: str) -> None:
		if is_fifo(p):
			return
		with suppress(OSError), open(p, "wb") as f:
			f.write(OTHER)

	if event in ("none", "chdir"):
		pass
	elif event == "write-load":
		write(load)
	elif event == "write-save":
		write(save)
	elif event == "remove-load":
		remove_file(load)
	elif event == "fifo-load":
		remove_file(load)
		_try(os.mkfifo, load, 0o600)
	elif event == "dir-load":
		remove_file(load)
		_try(os.mkdir, load, 0o755)
	elif event == "mkdir":
		_try(os.mkdir, os.path.join(w, "nodir"), 0o755)
		_try(os.mkdir, os.path.join(w, "nd"), 0o755)
	elif event == "link-made":
		_try(os.symlink, "sub", os.path.join(w, "nd"))
	elif event == "relink":
		remove_file(os.path.join(w, "lw"))
		_try(os.symlink, "sub", os.path.join(w, "lw"))
		remove_file(os.path.join(w, "lt.shcl"))
		_try(os.symlink, "sub/t.shcl", os.path.join(w, "lt.shcl"))
	elif event == "unread":
		# A file only, since a folder without its bits stops the case.
		with suppress(OSError):
			if stat.S_ISREG(os.stat(load).st_mode):
				os.chmod(load, 0o200)
	else:
		raise AssertionError(f"no such event {event!r}")


# Every name under the root, with what it is and holds, links not followed,
# so a refused save can be shown to have written nothing anywhere.
def snapshot(root: str) -> dict[str, str]:
	out: dict[str, str] = {}

	def walk(d: str) -> None:
		try:
			names = os.listdir(d)
		except OSError:
			out[d] = "unlistable"
			return
		for name in names:
			p = os.path.join(d, name)
			try:
				st = os.lstat(p)
			except OSError:
				out[p] = "gone"
				continue
			if stat.S_ISLNK(st.st_mode):
				out[p] = "link " + os.readlink(p)
			elif stat.S_ISDIR(st.st_mode):
				walk(p)
				out[p] = "dir"
			elif stat.S_ISREG(st.st_mode):
				try:
					with open(p, "rb") as f:
						out[p] = f"file {f.read()!r}"
				except OSError:
					out[p] = f"file of {st.st_size} bytes, unreadable"
			else:
				out[p] = "special"

	walk(root)
	return out


# Gives back the bits an event took, so the tree can go.
def remove_tree(root: str) -> None:
	def unlock(p: str) -> None:
		try:
			if not stat.S_ISDIR(os.lstat(p).st_mode):
				return
			os.chmod(p, 0o700)
			names = os.listdir(p)
		except OSError:
			return
		for name in names:
			unlock(os.path.join(p, name))

	unlock(root)
	shutil.rmtree(root, ignore_errors=True)


@dataclass
class Ran:
	"""One case's run and its answers."""
	line: str
	skipped: bool = False
	same: bool = False
	expected: str = IO
	got: str = IO


def describe(r: Rules, c: Case) -> str:
	events = ",".join(r.events[e].name for e in c.events)
	return (f"t={int(c.t_there)} o={int(c.o_there)} load={r.spells[c.load].name} save={r.spells[c.save].name} "
		f"events={events} create={int(c.create)} force={int(c.force)}")


# The answer the save has to give, from the case's tree, and whether the 2
# spellings name one file, from the replica: a marker written through the save
# spelling and read back through the load spelling.
def oracle(save_at: str, r_save_at: str, r_load_at: str, save_path: str, loaded: bytes | None, c: Case) -> tuple[str, bool]:
	def verdict() -> str:
		try:
			st = os.stat(r_save_at)
		except OSError:
			pass
		else:
			if stat.S_ISDIR(st.st_mode):
				return IS_DIRECTORY
			if not stat.S_ISREG(st.st_mode):
				return NOT_REGULAR
		try:
			with open(r_save_at, "wb") as f:
				f.write(MARKER)
		except OSError:
			return IO
		return OK

	v = verdict()
	same = v == OK and at(r_load_at) == At("file", MARKER)
	if save_path.endswith(("/", "/.", "/..")):
		return IS_DIRECTORY, same
	if c.create and os.path.lexists(save_at):
		return EXISTS, same
	if c.create or c.force:
		return v, same
	a = at(save_at)
	if a.kind == "unreadable":
		return CHANGED, same
	if a.kind == "file" and (loaded is None or loaded != a.data):
		return CHANGED, same
	return v, same


def _save(doc: shcl.Document, path: str, opts: shcl.SaveOptions) -> BaseException | None:
	try:
		doc.save_file_with(path, opts)
	except (shcl.SaveError, shcl.WriteError) as e:
		return e
	return None


class Kept(Exception):
	"""A case failed, and its tree is kept to look at."""


def run_case(r: Rules, base: str, label: str, c: Case) -> Ran:
	ran = Ran(line=label + "\t" + describe(r, c))
	ran.skipped = not on_this_os(r.spells[c.load].os) or not on_this_os(r.spells[c.save].os)
	if any(not on_this_os(r.events[e].os) for e in c.events):
		ran.skipped = True
	if ran.skipped:
		return ran
	root = os.path.join(base, label.replace(":", "-"))
	x = os.path.join(root, "x")
	rp = os.path.join(root, "r")
	build(x, c)
	build(rp, c)
	load = r.spells[c.load]
	save = r.spells[c.save]
	xw, rw = os.path.join(x, "w"), os.path.join(rp, "w")
	load_path = spelled(load, xw)
	x_load_at = from_root(x, load.cwd, load_path)
	r_load_at = from_root(rp, load.cwd, spelled(load, rw))

	before_load = at(x_load_at)
	os.chdir(os.path.join(x, load.cwd))
	doc, st = shcl.Document.load_file(load_path)
	loaded = None
	if before_load.kind == "file" and st in (shcl.FileStatus.Clean, shcl.FileStatus.HadErrors):
		loaded = before_load.data
	doc.set_int("k", 7)

	save_cwd = save.cwd
	for e in c.events:
		name = r.events[e].name
		if name == "chdir":
			save_cwd = "o" if save_cwd == "w" else "w"
		for tree in (x, rp):
			w = os.path.join(tree, "w")
			lp = from_root(tree, load.cwd, spelled(load, w))
			sp = from_root(tree, save_cwd, spelled(save, w))
			apply(name, tree, lp, sp)

	save_path = spelled(save, xw)
	x_save_at = from_root(x, save_cwd, save_path)
	r_save_at = from_root(rp, save_cwd, spelled(save, rw))
	expected, same = oracle(x_save_at, r_save_at, r_load_at, save_path, loaded, c)
	ran.same = same
	ran.expected = expected

	before = snapshot(x)
	os.chdir(os.path.join(x, save_cwd))
	opts = shcl.SaveOptions(lossy=True, force=c.force, create=c.create)
	first = _save(doc, save_path, opts)
	ran.got = classify(first)
	os.chdir(base)

	def keep(why: str) -> Kept:
		return Kept(f"{ran.line}: {why}\n\tthe tree is kept at {root}")

	if ran.got != expected:
		raise keep(f"expected {expected}, got {first!r}")
	if ran.got == OK:
		# A file already there keeps its mode, so one an event took the read
		# bits off is still unreadable after the save.
		if at(x_save_at).kind == "unreadable":
			os.chmod(x_save_at, 0o600)
		a = at(x_save_at)
		if a != At("file", doc.to_canonical().encode("utf-8")):
			raise keep(f"saved, but the path holds {a}")
		# What this document last wrote is no change, and a create-only save
		# now finds its own file.
		os.chdir(os.path.join(x, save_cwd))
		again = _save(doc, save_path, opts)
		os.chdir(base)
		want = EXISTS if c.create else OK
		if classify(again) != want:
			raise keep(f"the second save gave {again!r}")
	else:
		after = snapshot(x)
		if after != before:
			raise keep(f"refused as {first!r}, but the tree changed:\n\tbefore {before}\n\tafter {after}")
	remove_tree(root)
	return ran


# The folder the cases go in: SHCL_FS_DIR, or the temp folder with a note,
# never the project tree.
def base_dir(test: str) -> str:
	parent = os.environ.get("SHCL_FS_DIR", "")
	if not parent:
		parent = tempfile.gettempdir()
		print(f"note: SHCL_FS_DIR is not set, so the filesystem cases go under {parent}", file=sys.stderr)
	base = os.path.join(parent, f"shcl-fs-python-{os.getpid()}-{test}")
	remove_tree(base)
	os.makedirs(base, 0o755)
	return os.path.realpath(base)


# Writes the cases a test ran in fs/NAME.tsv under SHCL_FUZZ_DUMP, up to
# SHCL_FUZZ_DUMP_MAX lines.
def dump(name: str, lines: list[str]) -> None:
	d = os.environ.get("SHCL_FUZZ_DUMP", "")
	if not d:
		return
	try:
		most = int(os.environ.get("SHCL_FUZZ_DUMP_MAX", "").strip())
	except ValueError:
		most = 5000
	d = os.path.join(d, "fs")
	os.makedirs(d, 0o755, exist_ok=True)
	with open(os.path.join(d, name + ".tsv"), "w", encoding="utf-8", newline="\n") as f:
		f.writelines(line + "\n" for line in lines[:most])


def dump_line(ran: Ran) -> str:
	if ran.skipped:
		return ran.line + "\tskipped"
	return f"{ran.line}\tsame={int(ran.same)}\t{ran.got}"


# SHCL_FS_SECS, 2 when unset. A value that isn't a count is a mistake, not a
# setting.
def budget_secs() -> int:
	v = os.environ.get("SHCL_FS_SECS")
	if v is None:
		return 2
	try:
		n = int(v.strip())
	except ValueError:
		n = -1
	if n < 0:
		raise Fatal(f"SHCL_FS_SECS is not a count: {v!r}")
	return n


class Row(NamedTuple):
	id: str
	# The row's own platform where its spellings don't say, for an item whose
	# bug was on one platform only.
	only: str
	t: bool
	o: bool
	load: str
	save: str
	events: tuple[str, ...]
	create: bool
	expected: str


# One row per past bug of the class, each a case the generator can draw.
# 2026110313211991 was the CLIs' own check; its library twin is the FIFO row.
ROWS = (
	Row("2026102910482342", "any", True, False, "bare", "bare", ("write-load",), False, CHANGED),
	Row("2026110312163201-gone", "any", True, False, "bare", "dot", ("remove-load",), False, OK),
	Row("2026110312163201-made", "any", False, False, "bare", "bare", ("write-load",), False, CHANGED),
	Row("2026110312163201-abs", "any", True, False, "dot", "abs", ("write-load",), False, CHANGED),
	Row("2026110312163202-fifo", "any", True, False, "dot", "dot", ("fifo-load",), False, NOT_REGULAR),
	Row("2026110312163202-unread", "any", True, False, "dot", "dot", ("write-load", "unread"), False, CHANGED),
	Row("2026110312163207", "any", False, False, "dangle", "dangle", ("none",), True, EXISTS),
	Row("2026110314064292", "any", False, False, "bare", "nodir", ("none",), False, IO),
	Row("2026110314240418", "any", False, False, "nddot", "nd", ("mkdir", "write-load"), False, CHANGED),
	Row("2026110408432594-link", "windows", False, False, "dangle", "dangle", ("none",), True, EXISTS),
	Row("2026110408432594-dot", "windows", False, False, "nddot", "nd", ("mkdir", "write-load"), False, CHANGED),
	Row("2026110613470307", "any", False, False, "nodir", "nodir", ("mkdir", "write-save"), False, CHANGED),
	Row("2026110613470307-otherwd", "any", True, True, "bare", "bare", ("chdir",), False, CHANGED),
	Row("2026110613470307-win", "windows", True, False, "wnodir", "bare", ("write-load",), False, CHANGED),
	Row("2026110613470307-case", "macos", True, False, "case", "bare", ("write-load",), False, CHANGED),
	Row("2026110613470308-trail", "any", True, False, "bare", "trail", ("none",), False, IS_DIRECTORY),
	Row("2026110613470308-dot", "any", True, False, "bare", "traildot", ("none",), True, IS_DIRECTORY),
	Row("2026110613470308-swap", "any", True, False, "bare", "bare", ("dir-load",), False, IS_DIRECTORY),
)


def index(rules: list[Rule], name: str) -> int:
	for i, rule in enumerate(rules):
		if rule.name == name:
			return i
	raise Fatal(f"fs-rules.tsv has no {name!r}, which a fixed row names")


# Every past bug of the class, as a fixed row the generator can draw too.
def the_save_checks_hold_on_every_past_path_bug(r: Rules) -> None:
	base = base_dir("rows")
	lines: list[str] = []
	failed: list[str] = []
	for row in ROWS:
		c = Case(t_there=row.t, o_there=row.o, load=index(r.spells, row.load), save=index(r.spells, row.save), create=row.create)
		c.events = [index(r.events, e) for e in row.events]
		if not on_this_os(row.only):
			lines.append(f"row:{row.id}\tskipped")
			continue
		# Every row runs, so one red run names each past bug that's back.
		try:
			ran = run_case(r, base, f"row:{row.id}", c)
		except Kept as e:
			failed.append(str(e))
			continue
		lines.append(dump_line(ran))
		if not ran.skipped and ran.expected != row.expected:
			failed.append(f"{ran.line}: the oracle says {ran.expected}, the row {row.expected}")
	dump("python-rows", lines)
	if failed:
		raise Fatal("\n".join(failed))
	remove_tree(base)


# Cases drawn by seed for the budget. Each case is a pure function of its
# seed, so a failure replays from the seed in its message. A run that never
# drew each spelling, event, answer, and both one file and 2, fails, since it
# didn't test what it says.
def the_save_checks_hold_on_drawn_paths_and_events(r: Rules) -> None:
	base = base_dir("drawn")
	v = os.environ.get("SHCL_FS_SEED")
	if v is not None:
		try:
			seed = int(v.strip())
		except ValueError:
			seed = -1
		if not 0 <= seed <= MASK:
			raise Fatal(f"SHCL_FS_SEED is not a seed: {v!r}")
		try:
			ran = run_case(r, base, f"seed:{seed}", draw(r, seed))
		except Kept as e:
			raise Fatal(str(e)) from None
		print(dump_line(ran), file=sys.stderr)
		remove_tree(base)
		return
	until = time.monotonic() + budget_secs()
	spells: set[int] = set()
	events: set[int] = set()
	outcomes: set[str] = set()
	sames: set[bool] = set()
	lines: list[str] = []
	seed = 0
	while seed < MIN_CASES or time.monotonic() < until:
		c = draw(r, seed)
		try:
			ran = run_case(r, base, f"seed:{seed}", c)
		except Kept as e:
			raise Fatal(str(e)) from None
		lines.append(dump_line(ran))
		if not ran.skipped:
			spells.update((c.load, c.save))
			events.update(c.events)
			outcomes.add(ran.got)
			sames.add(ran.same)
		seed += 1
	dump("python-drawn", lines)
	missed = [f"{seed} cases never drew the spelling {s.name}" for i, s in enumerate(r.spells) if on_this_os(s.os) and i not in spells]
	missed += [f"{seed} cases never drew the event {e.name}" for i, e in enumerate(r.events) if on_this_os(e.os) and i not in events]
	# Only a FIFO is neither a file nor a folder here, and Windows has none.
	missed += [f"{seed} cases never gave {o}" for o in OUTCOMES if o not in outcomes and (o != NOT_REGULAR or on_this_os("posix"))]
	if len(sames) != 2:
		missed.append(f"{seed} cases never gave both one file and 2")
	if missed:
		raise Fatal("\n".join(missed))
	remove_tree(base)


def run_test(test: Any, r: Rules) -> None:
	start = len(FAILS)
	# The cases change the working folder, so it's put back after each test.
	back = os.getcwd()
	try:
		test(r)
	except Fatal as e:
		FAILS.append(f"{_open['name']}: {e}")
	finally:
		os.chdir(back)
	test_id_end("FAIL" if len(FAILS) > start else "PASS")


def main() -> int:
	sys.unraisablehook = _unraisable
	# The clock every runner pins, as conformance.py does.
	os.environ["SHCL_TEST_CLOCK"] = "2026-10-04 00:15:00 -420 PDT"
	r = read_rules()
	test_id("df4dk", "the_save_checks_hold_on_every_past_path_bug")
	run_test(the_save_checks_hold_on_every_past_path_bug, r)
	test_id("df4dm", "the_save_checks_hold_on_drawn_paths_and_events")
	run_test(the_save_checks_hold_on_drawn_paths_and_events, r)
	for f in FAILS:
		sys.stderr.write(f"FAIL {f}\n")
	return 1 if FAILS else 0


if __name__ == "__main__":
	try:
		code = main()
	except BaseException:
		test_id_end("FAIL")
		raise
	sys.exit(code)
