# SPDX-License-Identifier: MIT
# Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

"""SHCL binding for Python: parser, accessor, writer/formatter.

Single file on purpose - the drop-in story is "copy this file into your tree".
Behavior tracks the Rust reference (source/rust/src/lib.rs) byte for byte; the
conformance corpus in project/conformance/ pins every behavior here, and the
cicd cross-binding check compares this against the reference on every run.
Structure deliberately mirrors the reference over Python idiom, so a fix there
ports here by mechanical diff (parity over idiom - see
project/style-guide_code.md).
"""

# The type gate, turned on here rather than left at its default: without this the
# checker skips every unannotated body, which in a module with no annotations is
# the whole file - a gate that cannot fail. `assignment` stays off because the
# structures mirrored from the reference are tagged tuples and index-or-None
# locals, which read as type changes to a checker and are not; everything that
# catches a real misuse (a None reaching an operator, a wrong argument, a bad
# return) is live.
# mypy: check-untyped-defs, disable-error-code="assignment"

from __future__ import annotations

import bisect
import math
import os
import re
import stat
import sys
from collections.abc import Callable
from datetime import timedelta
from decimal import Decimal
from enum import Enum
from typing import Any, Generic, TypeVar

# The public surface, stated rather than inferred: without this `from shcl
# import *` hands out this module's own imports (math, os, stat, Decimal, Enum)
# and its internal ROOT constant alongside the real API.
__all__ = [
	"DateTime",
	"Diagnostic",
	"Document",
	"FORMAT_LINE",
	"DurationUnit",
	"FORMAT_LINE_HEAD",
	"FORMAT_MAJOR",
	"FileStatus",
	"GEN_BANNER",
	"LoadError",
	"MAX_DEPTH",
	"MIGRATED_LINE",
	"Migration",
	"Piece",
	"Quote",
	"RULES_CURRENT",
	"RULES_V2",
	"Read",
	"Rules",
	"SCHEMA_LINE_HEAD",
	"SaveError",
	"SaveFailed",
	"SaveRefused",
	"SegTok",
	"Severity",
	"ShclDateTime",
	"SizeUnit",
	"Status",
	"StatusError",
	"Strictness",
	"Tokens",
	"WriteReason",
	"format_float",
	"format_version",
	"generate",
	"migrate",
	"migrate_unstamped",
	"parse_datetime",
	"quote_segment",
	"read_file",
	"schema_ref",
	"suppress_declared_reopens",
	"suppress_declared_repeats",
	"tokenize",
	"tokenize_value",
	"write_file_atomic",
]

# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------


class Strictness(Enum):
	Loose = 1
	Standard = 2
	Strict = 3

	@staticmethod
	def from_arg(s: str) -> Strictness | None:
		"""Accepts the CLI spellings: loose|standard|strict or 1|2|3."""
		return {
			"loose": Strictness.Loose, "1": Strictness.Loose,
			"standard": Strictness.Standard, "2": Strictness.Standard,
			"strict": Strictness.Strict, "3": Strictness.Strict,
		}.get(_ascii_lower(s))


class Severity(Enum):
	# .name renders "Error"/"Hint" - that spelling is the `check` output contract.
	Error = 1
	Hint = 2


class Status(Enum):
	# Values are the CLI exit codes, so status_code is just Status.value.
	Good = 0
	Empty = 2
	NotFound = 3
	BadType = 4
	Multiple = 5


class WriteReason(Enum):
	"""Why a write would fail (write_reason()): the distinctions behind a
	setter's bare False. Writable = the path passes the writer's validation;
	the rest name the five ways it cannot."""
	Writable = 0
	BadPath = 1       # empty path, or the scanner rejected it
	ValueInPath = 2   # the path carries a `: value` part; writes take values separately
	Wildcard = 3      # wildcard selectors are query-only
	NoSuchIndex = 4   # a `[#k]` instance that does not (and can never) exist
	TooDeep = 5       # deeper than the nesting cap; the writer never creates past it


class Diagnostic:
	__slots__ = ("line", "severity", "message", "code")
	line: int
	severity: Severity
	message: str
	code: str

	def __init__(self, line: int, severity: Severity, message: str, code: str):
		self.line = line          # 1-based
		self.severity = severity
		self.message = message
		self.code = code          # stable machine code (E001.., H001..); the contract

	# The reference derives Debug; print() is how Python gets debugged.
	def __repr__(self) -> str:
		return f"Diagnostic(line={self.line}, severity={self.severity}, message={self.message!r}, code={self.code!r})"


T = TypeVar("T")


class Read(Generic[T]):
	"""Value plus status plus the original raw text (when the path resolved).
	Array reads also carry one status per slot (element, or wildcard instance)
	in .slots; .status is then the worst slot. Scalar reads leave .slots empty.
	.line is the 1-based source line of the resolved binding (0 when the path
	did not resolve to one node, or the node was writer-built), so a consumer
	check the schema cannot express can still cite the line. .quoted is True
	when the read's single scalar element was quoted in the source - the escape
	hatch that lets a downstream language reserve @null while "@null" stays a
	plain string. Arrays, raw blocks, and empties leave it False. A written
	value counts as quoted when a save would quote it."""
	__slots__ = ("value", "status", "raw", "slots", "line", "quoted")
	value: T
	status: Status
	raw: str | None
	slots: list[Status]
	line: int
	quoted: bool

	def __init__(self, value: T, status: Status, raw: str | None, slots: list[Status] | None = None):
		self.value = value
		self.status = status
		self.raw = raw
		self.slots = slots if slots is not None else []
		self.line = 0
		self.quoted = False

	# The reference derives Debug. Enum members are spelled with str(), since a
	# list's repr would print the slots as <Status.Good: 0> beside a plain
	# Status.Good for .status.
	def __repr__(self) -> str:
		slots = ", ".join(str(x) for x in self.slots)
		return (f"Read(value={self.value!r}, status={self.status}, raw={self.raw!r}, "
			f"slots=[{slots}], line={self.line}, quoted={self.quoted})")

	def _at(self, line: int, quoted: bool) -> Read[T]:
		self.line = line
		self.quoted = quoted
		return self

	def ok(self) -> bool:
		"""Whether the author addressed this field at all: Good or Empty. Note
		this deliberately answers differently from the convenience tier, which
		falls back on Empty like any other non-Good read - ok() asks "is this
		field spoken for", get_*_or() asks "do I have a usable value", and an
		explicitly emptied field is the case where those two diverge."""
		return self.status in (Status.Good, Status.Empty)


class LoadError(Exception):
	"""A failed strict load. Carries the full diagnostics list AND the document
	the parse produced anyway - recover-and-continue means the diagnostics are
	the point, and the tree is what a Standard load would have kept."""
	diagnostics: list[Diagnostic]
	document: Document | None

	def __init__(self, diagnostics: list[Diagnostic], document: Document | None = None):
		self.diagnostics = diagnostics
		self.document = document
		# Name the first few failures right in the message; the bare count made
		# callers dig for information the error was already holding.
		errs = [d for d in diagnostics if d.severity == Severity.Error]
		msg = f"strict load failed: {len(errs)} error diagnostic(s)"
		for d in errs[:3]:
			msg += f"; line {d.line}: {d.code} {d.message}"
		if len(errs) > 3:
			msg += f"; +{len(errs) - 3} more"
		super().__init__(msg)


class SaveError(Exception):
	"""Base for the two ways a save does not happen. They are separate classes
	so a caller can tell them apart with `except` rather than by matching on the
	message: a refusal is theirs to reverse, a write failure is not."""


class SaveRefused(SaveError):
	"""The lost-content gate fired: the load dropped content this save would
	delete (see lost_count). save_file_lossy is the override."""
	path: str | os.PathLike[str]
	lost: int

	def __init__(self, path: str | os.PathLike[str], lost: int):
		self.path = path
		self.lost = lost
		super().__init__(f"{path}: refusing to save: load dropped {lost} line(s)/value(s) this write would delete (see diagnostics; save_file_lossy overrides)")


class SaveFailed(SaveError):
	"""The write itself failed; the message is what the system reported."""


class ShclDateTime:
	"""Local (floating) date/time unless a zone suffix was present. Fields mirror
	what was written: a date-only value has no time, and vice versa."""
	__slots__ = ("date", "time", "frac", "zone")
	date: tuple[int, int, int] | None            # (year, month, day)
	time: tuple[int, int, int | None] | None     # (hour, minute, seconds-if-written)
	frac: str | None                             # fractional-second digits as typed
	zone: tuple[str, int | None] | None          # ("utc", None) | ("offset", minutes)

	def __init__(
		self,
		date: tuple[int, int, int] | None = None,
		time: tuple[int, int, int | None] | None = None,
		frac: str | None = None,
		zone: tuple[str, int | None] | None = None,
	):
		self.date = date
		self.time = time
		self.frac = frac
		self.zone = zone

	# Field by field, as the reference derives it. Same-moment comparison is a
	# different question and lives in the value code: `12:00:00Z` and
	# `12:00:00+00:00` are one moment and two values.
	def __eq__(self, other: object) -> bool:
		if not isinstance(other, ShclDateTime):
			return NotImplemented
		return (self.date, self.time, self.frac, self.zone) == (
			other.date, other.time, other.frac, other.zone)

	def __hash__(self) -> int:
		return hash((self.date, self.time, self.frac, self.zone))

	def __repr__(self) -> str:
		return (f"ShclDateTime(date={self.date!r}, time={self.time!r}, "
			f"frac={self.frac!r}, zone={self.zone!r})")

	def __str__(self) -> str:
		out = []
		if self.date is not None:
			y, m, d = self.date
			out.append(f"{y:04d}-{m:02d}-{d:02d}")
			if self.time is not None:
				out.append("T")
		if self.time is not None:
			h, mi, s = self.time
			out.append(f"{h:02d}:{mi:02d}")
			if s is not None:
				out.append(f":{s:02d}")
			if self.frac is not None:
				out.append("." + self.frac)
		if self.zone is not None:
			if self.zone[0] == "utc":
				out.append("Z")
			else:
				off = self.zone[1] or 0   # ("offset", minutes); the None slot is utc's
				sign = "-" if off < 0 else "+"
				a = abs(off)
				out.append(f"{sign}{a // 60:02d}:{a % 60:02d}")
		return "".join(out)


# The name the Go binding uses for the same type; either spelling works.
DateTime = ShclDateTime


def format_float(v: float) -> str:
	"""Float -> string, matching the reference: positional, shortest round-trip,
	never scientific. inf/NaN spelled as the reference spells them."""
	if v != v:
		return "NaN"
	if v == math.inf:
		return "inf"
	if v == -math.inf:
		return "-inf"
	return format(Decimal(repr(v)).normalize(), "f")


# ---------------------------------------------------------------------------
# In-memory model
# ---------------------------------------------------------------------------
# One rule covers everything: a node is (field-name, value, children); nodes
# merge when (name, value) matches; empty values merge into the wrapper node.


class _Element:
	__slots__ = ("text", "quoted")   # text: the logical string - quotes stripped, escapes resolved
	# Declared, not assigned - __slots__ forbids class attributes. The point is
	# the type gate: without a type here every field is Any and the checker has
	# nothing to check.
	text: str
	quoted: bool

	def __init__(self, text, quoted):
		self.text = text
		self.quoted = quoted


class _Lead:
	"""One whole-line comment held as trivia, plus whether a blank line preceded
	it - so a blank between comment-only regions survives the round-trip
	(blank runs collapse to one, same as nodes)."""
	__slots__ = ("text", "blank_before", "depth", "line", "kept")

	def __init__(self, text, blank_before, depth=0, line=0, kept=False):
		self.text = text
		self.blank_before = blank_before
		# Levels deeper than the place it is emitted at. A comment written
		# under the one before it keeps that nesting, so a commented-out block
		# comes back in its shape.
		self.depth = depth
		# The source line it was read from, for the save that keeps lines; 0
		# for one a write made or moved.
		self.line = line
		# A misplaced line kept as written that the settle turned into a
		# comment, since as written it would bind. It is still the user's line,
		# not a comment, so clear_comments and comments leave it alone.
		self.kept = kept

	def is_comment(self):
		return self.text.startswith("#") and not self.kept


def _comment_depth(chain, base, text, indent):
	"""How many levels past its place a pending line is written: the place's
	own level for a comment no deeper than `base`, the place's own indent,
	which also starts a new chain; for a deeper one, one level under the
	nearest comment before it whose indent its own extends, level with one it
	equals, or at the place's level when there is none. `chain` holds those
	comments' indents with their depths, innermost last. A line kept for being
	malformed always sits at the place's level and leaves the chain alone: it
	holds its level on a reload, so written deeper it would move what
	follows."""
	if not text.startswith("#"):
		return 0
	if not (len(indent) > len(base) and indent.startswith(base)):
		chain[:] = [(indent, 0)]
		return 0
	while chain:
		ind, depth = chain[-1]
		if ind == indent:
			return depth
		if len(indent) > len(ind) and indent.startswith(ind):
			break
		chain.pop()
	depth = chain[-1][1] + 1 if chain else 0
	chain.append((indent, depth))
	return depth


class _Pend:
	"""A pending whole-line comment during parse: text, source indent (used only
	to decide whether it hangs on a deeper block), and the blank it consumed.
	`ceiling` is the shortest incoming indent already checked against it: a
	later check can only hang it from a shorter one, so a longer one skips it."""
	__slots__ = ("text", "indent", "blank_before", "ceiling", "line")

	def __init__(self, text, indent, blank_before, line):
		self.text = text
		self.indent = indent
		self.blank_before = blank_before
		self.ceiling = len(indent)
		self.line = line


# Shared empty element list for the kinds that have none: only "cell" ever
# mutates els (the stacked-list append checks kind first), so "empty" and
# "raw" values all point at this one tuple instead of a list each.
_EMPTY_ELS: tuple = ()


class _Value:
	# kind: "empty" | "cell" (els) | "raw" (content/info/fence_char/fence_len)
	__slots__ = ("kind", "els", "content", "info", "fence_char", "fence_len")
	kind: str
	els: list     # _EMPTY_ELS when the kind has no elements; list only for "cell"
	content: str
	info: str
	fence_char: str
	fence_len: int

	def __init__(self, kind):
		# Empty rather than None for the fields the kind decides: a kind never
		# reads the fields it does not use, and an empty value of the declared
		# type means no guard at each use.
		self.kind = kind
		self.els = _EMPTY_ELS
		self.content = ""
		self.info = ""
		self.fence_char = ""
		self.fence_len = 0

	def is_empty(self):
		return self.kind == "empty"

	def copy(self):
		"""Independent copy, element list included - a clone or a merged-in value
		has to survive the document it came from being released."""
		v = _Value(self.kind)
		if self.kind == "cell":
			v.els = [_Element(e.text, e.quoted) for e in self.els]
		v.content = self.content
		v.info = self.info
		v.fence_char = self.fence_char
		v.fence_len = self.fence_len
		return v

	def display(self):
		"""Human/display form; also what selectors match against (case-sensitive)."""
		if self.kind == "empty":
			return ""
		if self.kind == "cell":
			# One element is the overwhelming case (every scalar field), and the
			# join plus generator cost more than the string it produces.
			if len(self.els) == 1:
				return self.els[0].text
			return ", ".join(e.text for e in self.els)
		return self.content


def _empty():
	return _Value("empty")


def _cell(els):
	v = _Value("cell")
	v.els = els
	return v


def _raw(content, info, fence_char, fence_len):
	v = _Value("raw")
	v.content = content
	v.info = info
	v.fence_char = fence_char
	v.fence_len = fence_len
	return v


def _literal_value(text):
	# Read text as the value half of a line, for the setters that take value
	# syntax rather than data: whatever a file line spells with this text is
	# what gets stored, so a trailing blank comes off and a `#` outside quotes
	# ends the value exactly as they would in a file. What is refused is what a
	# file reports as an error, since a setter has no diagnostic to
	# report it with: a line break, which no file line can hold, an unterminated
	# quote (E017), bracket text (E019, the line kept verbatim - writing it as
	# a two-element array holding `[1` and `2]` would be a different wrong
	# answer), and an unknown escape in double quotes (E023).
	if "\n" in text:
		return None
	tok = Tokens()
	s = _value_half(text, tok)
	if any(p.quote is Quote.OPEN for p in tok.elements) or s[tok.value[0]:tok.value[0] + 1] == b"[":
		return None
	if _bad_escape(tok, True) is not None:
		return None
	return _cell_of_tokens(tok, s)


def _fits_i64(v):
	# Python's int is unbounded, the other three bindings' are 64-bit. Text for a
	# value outside that range reads back bad-type in every binding, python
	# included, so a setter refuses it rather than writing a value nothing can
	# read. Same range-check the CLI already does on its side.
	return -(1 << 63) <= v <= (1 << 63) - 1


def _cell_of(text):
	return _cell([_new_element(text)])


def _want(setter, v, kind):
	# A typed setter takes exactly the type its name says; anything else is a
	# programming error and raises, rather than writing text every reader of
	# that type would call bad-type (set_int of 3.5 wrote `3.5`). bool is a
	# subclass of int in Python, so it is carved out of int and float by hand.
	if kind == "int":
		ok = isinstance(v, int) and not isinstance(v, bool)
	elif kind == "float":
		ok = isinstance(v, (int, float)) and not isinstance(v, bool)
	elif kind == "bool":
		ok = isinstance(v, bool)
	elif kind == "str":
		ok = isinstance(v, str)
	else:
		ok = isinstance(v, ShclDateTime)
	if not ok:
		raise TypeError(f"{setter}: want {kind}, got {type(v).__name__}")


def _want_all(setter, v, kind):
	# A sequence, not any iterable. A str is a sequence of one-character strings,
	# so set_string_array("abc") wrote three elements; a generator is consumed by
	# the check and the setter then reads an empty one and reports success.
	if isinstance(v, (str, bytes, bytearray)):
		raise TypeError(f"{setter}: want a list of {kind}, got {type(v).__name__}")
	items = list(v)
	for x in items:
		_want(setter, x, kind)
	return items


def _as_float(v):
	# An int is written as the f64 the other bindings would hold, so
	# 9007199254740993 lands as 9007199254740992 and not its exact digits. One
	# past the float range has no f64 but inf, which is what a caller of the
	# reference would have been holding.
	try:
		return float(v)
	except OverflowError:
		return math.inf if v > 0 else -math.inf


def _array_cell(texts):
	# Inline-array value; the empty array is an empty value (reads back Empty).
	if not texts:
		return _empty()
	return _cell([_new_element(t) for t in texts])


def _choose_fence(content):
	"""Pick a backtick fence long enough that no content line closes it early."""
	maxrun = 0
	for line in content.split("\n"):
		t = line.strip(" \t")
		if t and all(ch == "`" for ch in t):
			maxrun = max(maxrun, len(t))
	return ("`", max(3, maxrun + 1))


class _Trivia:
	"""Comment trivia, boxed off to the side: most nodes carry none, and the
	four empty containers were a third of every node. Verbatim from `#` to end
	of line. Never part of identity or reads; merged instances concatenate
	leading, first trailing wins (later ones demote to leading - a canonical
	line has room for one)."""
	__slots__ = ("leading", "trailing", "after", "inside", "among")

	def __init__(self):
		self.leading = []
		self.trailing = ""        # empty = none
		# Whole-line comments that followed this node's subtree at a deeper
		# indent than the next binding - they belong to this block, not the next
		# node, so a run trailing a block's last child stays put instead of
		# re-attaching dedented. Emitted after the subtree at this node's depth.
		self.after = []
		# Whole-line comments written inside this node's block when no bound
		# child could take them - a header whose children are all commented
		# still owns those lines. Emitted after the subtree one level deeper
		# than this node.
		self.inside = []
		# Kept lines that sat among this node's stacked list elements, each
		# with the number of elements before it. They keep the list stacked on
		# output, so a line fixed by hand is still inside the list.
		self.among = []


class _Node:
	__slots__ = (
		"name", "value", "children", "parent", "line", "star_list", "star_mixed",
		"trivia", "blank_before", "src_set", "src", "name_src",
	)

	def __init__(self, name: str, value, parent, line: int, name_src: str = "") -> None:
		# ASCII-folded to lower; non-ASCII never folds. Interned: siblings and
		# repeated sections share one string object instead of one per node.
		self.name = sys.intern(name)
		# The name as the author spelled it (case unfolded, quotes and escapes
		# resolved) - what authored_name() hands back. Merged instances keep the
		# first binding's spelling, like line() and comments. The same object as
		# `name` when the spellings match (the overwhelmingly common case), so
		# the duplicate per-node string never allocates.
		self.name_src = self.name if name_src == name else sys.intern(name_src)
		self.value = value
		self.children: list[int] = []
		self.parent = parent
		self.line = line
		self.star_list = False    # value built from stacked "* " lines
		self.star_mixed = False   # mix of "* " and field children already diagnosed
		# Comment trivia sidecar (_Trivia): None until the first write, so the
		# common comment-free node never allocates the four containers.
		self.trivia = None
		# Blank-line grouping is the other half of hand-authored layout: set
		# when a blank line preceded this node's binding line (runs collapse).
		self.blank_before = False
		# This node has decided its `src` - set by the first source line whose
		# value the node holds, whether or not a string was worth keeping.
		self.src_set = False
		# Verbatim value text from the source line (after the colon, comment
		# stripped, trimmed) - what a read's `raw` hands back. None when the
		# value was synthesized (writer, stacked list, fence) OR when the
		# spelling is exactly the display form; raw falls back to the display
		# form either way.
		self.src = None

	# Trivia reads hand back the empty shape when no sidecar exists; _triv()
	# allocates one on first write.
	def leading(self):
		t = self.trivia
		return t.leading if t is not None else ()

	def trailing(self):
		t = self.trivia
		return t.trailing if t is not None else ""

	def after(self):
		t = self.trivia
		return t.after if t is not None else ()

	def inside(self):
		t = self.trivia
		return t.inside if t is not None else ()

	def among(self):
		t = self.trivia
		return t.among if t is not None else ()

	def _triv(self):
		t = self.trivia
		if t is None:
			t = self.trivia = _Trivia()
		return t


ROOT = 0
# Stack entry for a binding line that was skipped: it still owns its indent
# level, so the lines written under it are skipped with it instead of
# re-parenting one level up. sys.maxsize so an arena index through it fails
# loudly rather than reading a real node.
DEAD = sys.maxsize
# Stack entry for a line whose indent matched no open level (E012): never a
# level a sibling can bind at, but deeper lines are still under it. It sits
# on top of the levels open before it without closing any of them.
UNOPENED = sys.maxsize - 1
# Ends a name-index chain (see _NameIndex).
NIL = sys.maxsize


def _fold_node_into(arena, survivor, loser):
	"""Merge a later instance into an earlier one under the in-file merge rule:
	children and trivia move over, first trailing wins (a second demotes to a
	leading line), first spelling stays. The caller drops the loser from the
	parent's child list; it keeps its arena slot, unreferenced."""
	# Lists are references: after each move, point the loser at a fresh empty
	# list so the two nodes never share one.
	kids = arena[loser].children
	arena[loser].children = []
	for k in kids:
		arena[k].parent = survivor
	arena[survivor].children.extend(kids)
	lt = arena[loser].trivia
	if lt is not None:
		arena[loser].trivia = None
		st = arena[survivor]._triv()
		st.leading.extend(lt.leading)
		if lt.trailing:
			if not st.trailing:
				st.trailing = lt.trailing
			else:
				st.leading.append(_Lead(lt.trailing, False))
		st.after.extend(lt.after)
		st.inside.extend(lt.inside)
		st.among.extend(lt.among)
		st.among.sort(key=lambda a: a[0])


def _settle_block(arena, n, start):
	"""File a block's comments where a reload does, in place. A block's inside
	comments are written after its last child's block, at that child's level,
	so a reload files them as the last child's own. A child's comments at its
	own level sit right above the next sibling, so a reload files them as that
	sibling's leading ones, from the first one at that level on. The load runs
	this once the tree is final; a merge, a new child and the writer's fold run
	it where they change a child list, or the next step lands differently
	depending on whether the file was saved in between. The text does not move.
	start is the first child whose leading list may gain, so a new last child
	costs one pair; it cannot put a fence after an empty binding either, so only
	a full pass looks for one."""
	kids = arena[n].children
	if not kids:
		return
	if start <= 1:
		_settle_fence_trailing(arena, n)
	t = arena[n].trivia
	if t is not None and t.inside:
		arena[kids[-1]]._triv().after.extend(t.inside)
		t.inside = []
	for i in range(max(start, 1), len(kids)):
		t = arena[kids[i - 1]].trivia
		if t is None:
			continue
		at = next((k for k, c in enumerate(t.after) if c.depth == 0), None)
		if at is None:
			continue
		nt = arena[kids[i]]._triv()
		nt.leading[:0] = t.after[at:]
		del t.after[at:]


def _settle_fence_trailing(arena, n):
	"""A raw block after an empty binding of its name is written with the fence
	on the binding's line, where no comment can follow it, so the emitter writes
	its trailing comment on a line of its own above, after the node's blank. A
	reload files that line as a leading comment, so file it there now."""
	kids = arena[n].children
	if not any((arena[c].value.kind == "raw" and arena[c].trivia is not None and arena[c].trivia.trailing)
			or _stacks(arena[c]) for c in kids):
		return
	empties = set()
	for c in kids:
		nd = arena[c]
		t = nd.trivia
		if nd.value.kind == "raw" and t is not None and t.trailing and nd.name in empties:
			_trailing_to_leading(nd)
		elif _stacks(nd) and nd.name in empties:
			_unstack(nd)
		elif nd.value.is_empty():
			empties.add(nd.name)


def _stacks(nd):
	"""Written stacked: a list holding a kept line among its elements or after
	its last one."""
	t = nd.trivia
	return (t is not None and nd.value.kind == "cell"
		and (bool(t.among) or (nd.star_list and any(not c.text.startswith("#") for c in t.inside))))


def _unstack(nd):
	"""A list after an empty binding of its name cannot be written stacked: its
	bare header would merge into that binding on a reload. It goes inline, and
	the lines among its elements go above it, where a reload files what sits
	there."""
	nd.star_list = False
	t = nd.trivia
	if t is not None and t.among:
		t.leading.extend(a[1] for a in t.among)
		t.among = []


def _trailing_to_leading(nd):
	"""The trailing comment becomes the last leading line, taking the node's
	blank with it, which is the order the emitter writes them in."""
	t = nd.trivia
	t.leading.append(_Lead(t.trailing, nd.blank_before))
	t.trailing = ""
	nd.blank_before = False


def _settle_first_blank(arena, orphans):
	"""The emitter drops a blank before the first thing it prints, so a document
	that kept one there would not survive its own canonical form, and a merge or
	a new first line - where it is no longer first - would place a blank nobody
	wrote. Clear it wherever output starts."""
	kids = arena[ROOT].children
	if kids:
		n = arena[kids[0]]
		if n.trivia is not None and n.trivia.leading:
			n.trivia.leading[0].blank_before = False
		else:
			n.blank_before = False
	elif orphans:
		orphans[0].blank_before = False


# Maximum nesting depth (levels below the document root), enforced at load and
# by the Writer. Deeper lines are skipped with an E016 error. The cap is what
# keeps the recursive tree walks (emit, merge, clone) safely inside every
# binding's stack, so a hostile or machine-generated document can make a load
# fail but never crash the consumer.
MAX_DEPTH = 512

# How much of a file's own name the temporary file beside it borrows, in bytes.
TMP_NAME_BYTES = 64


# ---------------------------------------------------------------------------
# Tokenizer - the one place the lexical rules live
# ---------------------------------------------------------------------------
#
# Every reading of a line's parts goes through tokenize: the parser's line
# dispatch, the path scanner behind every lookup and setter, the comment and
# comma splits, the element cap, the unterminated-quote check, set_literal
# and the CLI's --set split. Seven scanners used to carry their own copy of
# these rules, and every scanner defect since July was two of them
# disagreeing. The rules, one sentence each:
#
# - A piece (a name, a selector body, a value element) is quoted only when
#   its first character is a quote and the next matching quote is the last
#   thing before the piece ends; inside double quotes a backslash escapes the
#   next character, inside single quotes nothing does. Anywhere else a quote
#   is an ordinary character, and a piece that began with one it never closed
#   is kept literally and reported (E017).
# - Escapes are processed inside double quotes only; bare text and single
#   quotes never process a backslash.
# - `#` outside quotes opens a comment, wherever it sits.
# - A space, a tab and a carriage return are blanks: trimmed at a piece's
#   edge, content in the middle of one.
# - A bare name is ASCII letters, digits, `-` and `_`; a `[` right after a
#   name opens a selector, whose bare body runs to the first `]`; a `[` after
#   the separator starts the value, which the parser refuses (E019).
# - A value is split on unquoted commas, each piece trimmed.
#
# Under Rules.V2 the tokenizer reads the 2.x spellings instead, for migrate:
# a backslash shields the next character in bare and single-quoted value text,
# a bare selector body still runs to its first `]`, a separator followed by `[`
# is the selector sugar, and an open quote swallows the rest of the line.
#
# The scan runs over the UTF-8 bytes of the text, so every offset it records
# is a byte offset - the offsets the other bindings record, and what the
# CLI's `tokens` output compares across them. tokenize keeps those bytes on
# the Tokens as `src`, and the helpers that read a piece back take them; a
# caller slices `src` and decodes, never the str it passed in.

# White_Space set, matching Rust char::is_whitespace exactly (so trims agree on
# exotic input - e.g. U+001C-1F are NOT whitespace here, unlike Python's default).
#
# The characters are written out rather than escaped, which is why the noqa is
# here: a linter reads them as typos for a plain space. Do not "fix" them, and do
# not add or drop one without changing the C, Go and Rust sets in the same pass -
# the four have to agree or the bindings stop trimming alike.
_WS = (
	"\t\n\x0b\x0c\r\x20\x85\xa0 "  # noqa: RUF001
	"           "  # noqa: RUF001
	"    　"  # noqa: RUF001
)
_WS_SET = set(_WS)

_ASCII_UPPER_MAP = {ord(c): ord(c) + 32 for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"}


def _ascii_lower(s):
	# Folds A-Z only; non-ASCII passes through untouched (matches to_ascii_lowercase).
	return s.translate(_ASCII_UPPER_MAP)


def _trim(s):
	return s.strip(_WS)


# The grammar's wsp: a space, a tab or a carriage return. The parser trims with
# this and nothing wider - a no-break space or a line separator after a value is
# content, and a Unicode trim used to delete it with no diagnostic.
_WSP = " \t\r"


def _trim_wsp(s):
	return s.strip(_WSP)


def _trim_wsp_end(s):
	return s.rstrip(_WSP)


def _trim_end(s):
	return s.rstrip(_WS)


def _split_ws(s):
	# Like Rust split_whitespace: split on White_Space runs, no empty tokens.
	out = []
	cur: list = []
	for c in s:
		if c in _WS_SET:
			if cur:
				out.append("".join(cur))
				cur = []
		else:
			cur.append(c)
	if cur:
		out.append("".join(cur))
	return out


def _is_ascii_digit(c):
	return "0" <= c <= "9"


def _all_ascii_digits(s):
	# Every char is 0-9; the empty string passes, as an all() over it would.
	# isdigit alone admits every Unicode Nd digit, so the ASCII test rides on it.
	return not s or (s.isascii() and s.isdigit())


_ASCII_DIGITS = frozenset("0123456789")


def _fold_name(s):
	return _ascii_lower(s)


# A closed 64-character set, so membership is one C-level lookup rather than
# two method calls and two comparisons per character. The scanner and the name
# emitter both run this over every character they touch.
_BARE_NAME_CHARS = frozenset(
	"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
)


class Quote(Enum):
	"""How a piece was quoted. OPEN is a piece that began with a quote and
	never closed with the matching quote as its last character: the whole
	piece is kept literally, quotes and all."""
	NONE = 0
	SINGLE = 1
	DOUBLE = 2
	OPEN = 3


class Piece:
	"""One piece of the text: byte offsets of its content. For a quoted piece
	the quotes sit just outside the span; for an open or bare piece the span
	is the trimmed text itself."""
	__slots__ = ("start", "end", "quote")
	start: int
	end: int
	quote: Quote

	def __init__(self, start: int, end: int, quote: Quote):
		self.start = start
		self.end = end
		self.quote = quote

	def __eq__(self, other: object) -> bool:
		return isinstance(other, Piece) and (self.start, self.end, self.quote) == (other.start, other.end, other.quote)

	def __repr__(self) -> str:
		return f"Piece({self.start}, {self.end}, {self.quote.name})"


class SegTok:
	"""One path segment: its name, an optional `[selector]` body, and whether
	the name was the bare `*` wildcard (lookups only)."""
	__slots__ = ("name", "selector", "star")
	name: Piece
	selector: Piece | None
	star: bool

	def __init__(self, name: Piece, selector: Piece | None, star: bool):
		self.name = name
		self.selector = selector
		self.star = star


class Rules(Enum):
	"""Which spelling the tokenizer reads: the current rules, listed at the top
	of this section, or the 2.x rules, for migrate only."""
	CURRENT = 0
	V2 = 1


RULES_CURRENT = Rules.CURRENT
RULES_V2 = Rules.V2


class Tokens:
	"""The spans of one line, or of one lookup path. Nothing is copied: every
	field is a byte offset into `src`, the UTF-8 bytes of the text that was
	tokenized."""
	__slots__ = ("segments", "sep", "value", "elements", "comment", "fault", "cap", "capped", "src")
	segments: list[SegTok]
	# Offset of the separator (`:` on a line, `=` in --set); None when the
	# path ran to the end of the text or into a comment.
	sep: int | None
	# The value: everything after the separator up to the comment, trimmed.
	value: tuple[int, int]
	# The value's comma-separated pieces, empty ones included, each trimmed.
	elements: list[Piece]
	# Offset of the `#` that opens a trailing comment.
	comment: int | None
	# Where the path stopped making sense, and why. A faulted line is
	# malformed as a whole (E014).
	fault: tuple[int, str] | None
	# The caller's element cap (0 = none): the scan stops as soon as the
	# value holds more elements than this, so a capped parse never builds the
	# array it is going to refuse. Kept across tokenize calls.
	cap: int
	# True when the cap stopped the scan; `elements` is then incomplete.
	capped: bool
	src: bytes

	def __init__(self, cap: int = 0):
		self.segments = []
		self.sep = None
		self.value = (0, 0)
		self.elements = []
		self.comment = None
		self.fault = None
		self.cap = cap
		self.capped = False
		self.src = b""

	def _clear(self):
		self.segments = []
		self.sep = None
		self.value = (0, 0)
		self.elements = []
		self.comment = None
		self.fault = None
		self.capped = False

	def element_count(self) -> int:
		"""How many elements the value holds: a quoted piece counts even when
		empty (`""` is a real element), an empty bare slot does not."""
		return sum(1 for p in self.elements if p.quote is not Quote.NONE or p.end > p.start)


# The structure bytes the scan compares against. All ASCII, which UTF-8
# guarantees cannot appear inside a multibyte sequence.
_B_TAB = 0x09
_B_CR = 0x0D
_B_SPACE = 0x20
_B_DQUOTE = 0x22
_B_HASH = 0x23
_B_SQUOTE = 0x27
_B_STAR = 0x2A
_B_COMMA = 0x2C
_B_DOT = 0x2E
_B_LBRACKET = 0x5B
_B_BACKSLASH = 0x5C
_B_RBRACKET = 0x5D
_B_COMMA_BYTES = b","
_WSP_BYTES = b" \t\r"
_BARE_NAME_RUN = re.compile(rb"[A-Za-z0-9_-]*")
# A byte the value fast path cannot take: a quote, or a `#`.
_VALUE_SLOW = re.compile(rb"[\"'#]")


def _looks_like_binding(s):
	"""`* name: value` is the YAML habit for a list of objects. Here it is one
	string element, so the parser says so (H003): the text up to its first colon
	has no blank, and the colon ends the text or a blank follows it."""
	i = s.find(":")
	if i <= 0 or any(c in _WSP for c in s[:i]):
		return False
	return i + 1 == len(s) or s[i + 1] in _WSP


def _is_wsp_byte(b):
	"""A blank: space, tab, or a carriage return, which is trimmed wherever a
	blank is and content in the middle of a piece."""
	return b in (_B_SPACE, _B_TAB, _B_CR)


def _skip_wsp(s, pos):
	n = len(s)
	while pos < n and (s[pos] == _B_SPACE or s[pos] == _B_TAB or s[pos] == _B_CR):
		pos += 1
	return pos


def _utf8_len(b):
	"""Byte length of the UTF-8 character that starts with b. The scan only
	ever compares against ASCII structure bytes, which UTF-8 guarantees cannot
	appear inside a multibyte sequence, so it advances by whole characters and
	every offset it records is a character boundary."""
	if b <= 0x7F:
		return 1
	if 0xC0 <= b <= 0xDF:
		return 2
	if 0xE0 <= b <= 0xEF:
		return 3
	return 4


def _quote_close(s, pos, rules):
	"""Offset of the quote that closes the one at pos, or None."""
	q = s[pos]
	escapes = q == _B_DQUOTE or rules is Rules.V2
	i = pos + 1
	n = len(s)
	while i < n:
		if escapes and s[i] == _B_BACKSLASH and i + 1 < n:
			i += 1 + _utf8_len(s[i + 1])
			continue
		if s[i] == q:
			return i
		i += 1 if s[i] < 0x80 else _utf8_len(s[i])
	return None


def _comment_at(s, i):
	"""True when the byte at i opens a comment. Being outside quotes is the
	caller's business."""
	return s[i] == _B_HASH


def _scan_piece(s, pos, term, rules, comments):
	"""One piece from pos: a value element up to an unquoted comma or comment,
	or a selector body up to an unquoted `]` (term). Returns the trimmed piece
	and the offset of what ended it: the terminator, a comment's `#`, or the
	end of the text. comments is False only for a selector body in a lookup
	path, where `[#N]` is the index spelling."""
	n = len(s)
	pos = _skip_wsp(s, pos)
	start = pos
	quote = Quote.NONE
	if pos < n and (s[pos] == _B_DQUOTE or s[pos] == _B_SQUOTE):
		close = _quote_close(s, pos, rules)
		if close is not None:
			# A value piece may also end at a comment or the line end; a
			# selector body ends at its bracket and nowhere else.
			i = _skip_wsp(s, close + 1)
			if i < n:
				ended = s[i] == term or (term == _B_COMMA and _comment_at(s, i))
			else:
				ended = term == _B_COMMA
			if ended:
				q = Quote.DOUBLE if s[pos] == _B_DQUOTE else Quote.SINGLE
				return Piece(pos + 1, close, q), i
			# Text after the closing quote: the quote was a character after
			# all, and the scan restarts at it. 2.x went on from the close
			# with the quotes read as a pair.
			quote = Quote.OPEN
			if rules is Rules.V2:
				pos = close + 1
		else:
			quote = Quote.OPEN
			if rules is Rules.V2:
				# 2.x: an open quote swallowed the rest of the line.
				end = n
				while end > start and _is_wsp_byte(s[end - 1]):
					end -= 1
				return Piece(start, end, quote), n
	# 2.x shielded a backslash in value text only. A bare selector body ran to
	# its first `]`, the same as now, so shielding one here would hide the `]`.
	shield = rules is Rules.V2 and term == _B_COMMA
	content_end = start
	# The text came off str.encode, so it is valid UTF-8 and a whole-character
	# step never passes the end: pos stays at most n without a clamp per byte.
	# An ASCII byte, which is nearly every byte, steps by one without a call.
	while pos < n:
		b = s[pos]
		if shield and b == _B_BACKSLASH and pos + 1 < n:
			pos += 1 + _utf8_len(s[pos + 1])
			content_end = pos
			continue
		if b == term or (comments and b == _B_HASH):
			break
		pos += 1 if b < 0x80 else _utf8_len(b)
		if b != _B_SPACE and b != _B_TAB and b != _B_CR:
			content_end = pos
	# 2.x judged a value piece quoted by its shape after the scan: a quote at
	# both ends, the last one not escaped, however many closes sat between. A
	# selector body had to close right before its `]`, or the line was E014.
	if rules is Rules.V2 and term == _B_COMMA and quote is Quote.OPEN and content_end - start >= 2 and s[content_end - 1] == s[start]:
		run = 0
		k = content_end - 2
		while k >= start and s[k] == _B_BACKSLASH:
			run += 1
			k -= 1
		if run % 2 == 0:
			q = Quote.DOUBLE if s[start] == _B_DQUOTE else Quote.SINGLE
			return Piece(start + 1, content_end - 1, q), min(pos, n)
	return Piece(start, content_end, quote), min(pos, n)


def tokenize_value(text: str, from_: int, rules: Rules, out: Tokens) -> None:
	"""The value half: everything from the byte offset from_ on, split into
	pieces, with the comment found on the way. A negative offset reads as 0:
	the reference's offset is unsigned, so there is nothing else one can mean,
	and Python read it as an offset from the end (20260918b item 31)."""
	out._clear()
	if from_ < 0:
		from_ = 0
	# A Python string can hold a lone surrogate (os.listdir, sys.argv and
	# os.environ hand them out), and a strict encode raised from a parse that
	# promises never to. Carried through, it is one more non-ASCII character,
	# as it was before the tokenizer read bytes; every decode here matches.
	# The save is where text with no UTF-8 spelling fails.
	s = text.encode("utf-8", "surrogatepass")
	out.src = s
	_scan_value(s, from_, rules, out)


def _scan_value(s, from_, rules, out):
	n = len(s)
	# A from_ that is not a character boundary is not a place the byte loop
	# would ever stop: it strides whole characters, so a comma inside a stride
	# never splits there, while bytes.find would split on it. No in-tree caller
	# does that, but tokenize_value is public, so fall through to the loop.
	if rules is Rules.CURRENT and (from_ >= n or s[from_] & 0xC0 != 0x80) and not _VALUE_SLOW.search(s, from_):
		# Fast path: with no quote and no `#` after the separator, every comma
		# splits and every piece is bare, so the scan would only ever trim.
		# bytes.find and strip run at C speed; the byte loop is the cost, and
		# such values dominate real documents. Same pieces, same cap, same
		# spans as the loop below - one piece at a time, so a capped parse
		# stops where the loop would and never holds the array it refuses.
		count = 0
		at = from_
		while True:
			cut = s.find(_B_COMMA_BYTES, at)
			chunk = s[at:n if cut < 0 else cut]
			a = at + len(chunk) - len(chunk.lstrip(_WSP_BYTES))
			b = a + len(chunk.strip(_WSP_BYTES))
			out.elements.append(Piece(a, b, Quote.NONE))
			if b > a:
				count += 1
				if out.cap and count > out.cap:
					out.capped = True
					out.value = (from_, from_)
					return
			if cut < 0:
				break
			at = cut + 1
		_end_value(s, from_, n, out)
		return
	pos = from_
	count = 0
	while True:
		piece, stop = _scan_piece(s, pos, _B_COMMA, rules, True)
		out.elements.append(piece)
		if piece.quote is not Quote.NONE or piece.end > piece.start:
			count += 1
			if out.cap and count > out.cap:
				out.capped = True
				out.value = (from_, from_)
				return
		if stop < n and s[stop] == _B_COMMA:
			pos = stop + 1
			continue
		if stop < n:
			out.comment = stop
		stop_at = stop
		break
	_end_value(s, from_, stop_at, out)


def _end_value(s: bytes, from_: int, stop_at: int, out: Tokens) -> None:
	a = _skip_wsp(s, from_)
	b = stop_at
	while b > a and _is_wsp_byte(s[b - 1]):
		b -= 1
	out.value = (min(a, b), b)
	if out.elements:
		last = out.elements[-1]
		if last.quote is not Quote.SINGLE and last.quote is not Quote.DOUBLE and last.end > b:
			out.elements[-1] = Piece(last.start, max(b, last.start), last.quote)


def tokenize(text: str, sep: str, path: bool, rules: Rules, out: Tokens) -> None:
	"""Tokenize one line (sep = ":") or one lookup path (path: the bare `*`
	name wildcard is admitted, and a `#` in a selector body is the `[#N]` index
	rather than a comment); the CLI's --set passes "=". out is cleared and
	reused, so a parse allocates once per document rather than once per line.
	text is the line after its indent, or the path."""
	out._clear()
	s = text.encode("utf-8", "surrogatepass")
	out.src = s
	sep_b = ord(sep)
	n = len(s)
	pos = 0
	while True:
		pos = _skip_wsp(s, pos)
		if pos >= n:
			out.fault = (pos, "expected a field name")
			return
		star = False
		b = s[pos]
		if b in (_B_DQUOTE, _B_SQUOTE):
			close = _quote_close(s, pos, rules)
			if close is None:
				out.fault = (pos, "unterminated quote in a field name")
				return
			name = Piece(pos + 1, close, Quote.DOUBLE if b == _B_DQUOTE else Quote.SINGLE)
			pos = close + 1
		elif path and b == _B_STAR:
			star = True
			pos += 1
			name = Piece(pos - 1, pos, Quote.NONE)
		else:
			start = pos
			# The bare-name run, matched at C speed rather than a byte at a
			# time; the class is the same closed ASCII set. A `*` pattern
			# always matches, so the None arm only satisfies the type gate.
			m = _BARE_NAME_RUN.match(s, pos)
			pos = m.end() if m is not None else start
			if pos == start:
				out.fault = (pos, "expected a field name")
				return
			name = Piece(start, pos, Quote.NONE)
		pos = _skip_wsp(s, pos)
		selector = None
		open_at = pos if pos < n and s[pos] == _B_LBRACKET else None
		if open_at is None and rules is Rules.V2 and pos < n and s[pos] == sep_b:
			q = _skip_wsp(s, pos + 1)
			if q < n and s[q] == _B_LBRACKET:
				open_at = q
		if open_at is not None:
			if star:
				out.fault = (open_at, "selector on a name wildcard")
				return
			piece, stop = _scan_piece(s, open_at + 1, _B_RBRACKET, rules, not path)
			if stop >= n or s[stop] != _B_RBRACKET:
				out.fault = (open_at, "unterminated selector")
				return
			if piece.end == piece.start and piece.quote is Quote.NONE:
				out.fault = (open_at, "empty selector")
				return
			if piece.quote is Quote.OPEN and rules is Rules.V2:
				out.fault = (open_at, "unterminated quote in a selector")
				return
			selector = piece
			pos = _skip_wsp(s, stop + 1)
		out.segments.append(SegTok(name, selector, star))
		if pos >= n:
			return
		b = s[pos]
		if b == _B_DOT:
			pos += 1
			continue
		if b == sep_b:
			out.sep = pos
			_scan_value(s, pos + 1, rules, out)
			return
		if _comment_at(s, pos):
			out.comment = pos
			return
		out.fault = (pos, "unexpected character after the path")
		return


def _piece_text(p, s):
	"""The text of a piece as the reader sees it: escapes applied inside double
	quotes, everything else as written. s is the tokenized text's bytes."""
	raw = s[p.start:p.end].decode("utf-8", "surrogatepass")
	if p.quote is Quote.DOUBLE and "\\" in raw:
		return _apply_escapes(raw)
	return raw


def _piece_is(p, s, want):
	"""True when a piece reads as this exact text, without building it."""
	raw = s[p.start:p.end]
	if p.quote is Quote.DOUBLE and _B_BACKSLASH in raw:
		return _apply_escapes(raw.decode("utf-8", "surrogatepass")) == want
	return raw == want.encode("utf-8", "surrogatepass")


def _element_of(p, s):
	"""The element a value piece makes, or None for an empty bare slot
	(dropped, never an error)."""
	if p.quote is Quote.NONE and p.end == p.start:
		return None
	return _Element(_piece_text(p, s), p.quote is Quote.SINGLE or p.quote is Quote.DOUBLE)


def _cell_of_tokens(tok, s):
	"""The value the tokenized pieces spell."""
	els = []
	for p in tok.elements:
		e = _element_of(p, s)
		if e is not None:
			els.append(e)
	return _cell(els) if els else _empty()


def _one_line(s):
	# Value text for a diagnostic message: line breaks and tabs escaped, so one
	# diagnostic is one line. A raw block's body is the value that made this
	# necessary - it carries its own newlines.
	return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")


def _schema_text(s):
	# Schema text for a diagnostic or a generated comment: a path or a type as
	# the schema wrote it, with a line break spelled `\n`, so one diagnostic
	# stays one line. Only the break is escaped, so a path reads the way it was
	# written.
	return s.replace("\n", "\\n")


def _first_where(xs, pred):
	# The reference's Iterator::position, so a range diagnostic can name the
	# value that broke the bound.
	for i, x in enumerate(xs):
		if pred(x):
			return i
	return -1


def _apply_escapes(s):
	"""Escape processing (string reads): \\t \\n \\\\ \\" \\' \\uXXXX
	\\UXXXXXXXX. An unknown pair stays literal, which only 2.x text still
	reaches: the current rules refuse one (E023) before anything is read."""
	return _resolve_escapes(s, Rules.CURRENT)


def _apply_escapes_v2(s):
	"""The 2.x reading, for migrate: no \\u, so 2.x kept \\u0041 as written."""
	return _resolve_escapes(s, Rules.V2)


def _resolve_escapes(s, rules):
	# Fast path: every non-backslash char passes through verbatim, so with no
	# backslash the output is s itself. Hot at parse time too (_disp_key runs
	# per node insert), and backslash-free text dominates.
	if "\\" not in s:
		return s
	out = []
	i = 0
	n = len(s)
	while i < n:
		c = s[i]
		i += 1
		if c != "\\":
			out.append(c)
			continue
		nxt = s[i] if i < n else None
		i += 1
		if nxt in ("u", "U") and rules is Rules.CURRENT:
			ue = _unicode_escape(nxt, s[i:i + 8])
			if ue is not None:
				out.append(ue[0])
				i += ue[1]
				continue
		if nxt == "t":
			out.append("\t")
		elif nxt == "n":
			out.append("\n")
		elif nxt == "\\":
			out.append("\\")
		elif nxt == '"':
			out.append('"')
		elif nxt == "'":
			out.append("'")
		elif nxt is None:
			out.append("\\")
		else:
			out.append("\\")
			out.append(nxt)
	return "".join(out)


_HEX_CHARS = frozenset("0123456789abcdefABCDEF")


def _unicode_escape(kind, after):
	"""The character a \\u or \\U escape names, and how many hex digits spell
	it: four after u, eight after U, as in TOML. None for a short run, a
	surrogate or a value past U+10FFFF."""
	n = 4 if kind == "u" else 8
	digits = after[:n]
	if len(digits) < n or not _HEX_CHARS.issuperset(digits):
		return None
	v = int(digits, 16)
	if v > 0x10FFFF or 0xD800 <= v <= 0xDFFF:
		return None
	return chr(v), n


# Characters canonical output writes as a \u escape, so a reader of the file
# sees every character that is there: controls with no short escape, the
# direction marks, embeddings, overrides and isolates, zero-width spaces, the
# byte order mark, and the line and paragraph separators. The zero-width
# joiner and non-joiner stay as written, since emoji and several scripts need
# them.
_INVISIBLE = frozenset(
	chr(c)
	for lo, hi in (
		(0x00, 0x08),
		(0x0B, 0x1F),
		(0x7F, 0x9F),
		(0x061C, 0x061C),
		(0x200B, 0x200B),
		(0x200E, 0x200F),
		(0x2028, 0x202E),
		(0x2060, 0x2064),
		(0x2066, 0x2069),
		(0xFEFF, 0xFEFF),
	)
	for c in range(lo, hi + 1)
)


def _unicode_escape_text(c):
	return f"\\u{ord(c):04X}"


def _single_scalar(v):
	"""The restriction a QUOTED [value] selector adds on top of the display
	match: quoting selects the scalar spelling only, so the scalar "a, b" and
	the list a, b stop meeting the same selector."""
	return v.kind == "cell" and v.els is not None and len(v.els) == 1


def _disp_key(v):
	"""The predicate a `[value]` selector matches with: the display form, which
	is built from logical strings, so `["q\\"uote"]` finds `'q"uote'` - a
	logical-string match, not spelling against spelling."""
	return v.display()


def _merge_key(name, v):
	"""The (name, merge-key) accelerator key: nodes with equal keys collapse
	into one. An exact tuple reusing the value's own strings, so it is
	injective with no key text built or copied - `[a, b]` never meets the
	single element "a\0b". Info-string is part of identity (a `sql` and a
	`python` block are different values even with equal bodies); fence style
	is not. Where the reference streams these fields through an FNV hash and
	verifies hits, tuples keep the lookup exact - dict and tuple machinery
	here is C-speed, a hand-rolled hash loop is not."""
	k = v.kind
	if k == "cell":
		els = v.els
		if len(els) == 1:
			return (name, "c", (els[0].text,))
		return (name, "c", tuple(e.text for e in els))
	if k == "empty":
		return (name, "e")
	return (name, "r", v.info, v.content)


def _value_key(v):
	"""The value's merge key alone (no name part) - the src-attach guard's
	compare."""
	return _merge_key("", v)


def _src_matches_display(v, s):
	"""True when a source value spelling is exactly the display form - the case
	where `src` need not be stored, since raw's fallback reproduces it. The
	single-scalar display() is the element text itself, so the common compare
	builds nothing."""
	return s == v.display()


def _fence_open(rest):
	"""Opening fence: a run of >=3 backticks or tildes, then an optional info-string."""
	if not rest:
		return None
	first = rest[0]
	if first != "`" and first != "~":
		return None
	run = 0
	for c in rest:
		if c == first:
			run += 1
		else:
			break
	if run < 3:
		return None
	return (first, run, _trim_wsp(rest[run:]))


def _line_fence(tok):
	"""The fence a field line's value opens, if it opens one. A line that did
	not tokenize has no value to read."""
	if tok.fault is not None or tok.sep is None:
		return None
	# A capped scan zeroed the value, and a fence is told by its leading run
	# alone.
	if tok.capped:
		return _fence_open(_trim_wsp(tok.src[tok.value[0]:].decode("utf-8", "surrogatepass")))
	return _fence_open(tok.src[tok.value[0]:tok.value[1]].decode("utf-8", "surrogatepass"))


def _is_fence_close(line, ch, min_len):
	# min_len is the opening fence's length, which the grammar puts at three or
	# more, so the length test already rules out the empty line all() would
	# otherwise accept.
	# A raw body keeps its carriage returns, so only a space or tab is trimmed.
	t = line.strip(" \t")
	return len(t) >= min_len and all(c == ch for c in t)


def _leading_ws(line):
	"""The leading space/tab run of a line (the indent)."""
	return line[:len(line) - len(line.lstrip(" \t"))]


def _strip_common(line, common):
	"""Remove a raw block's nesting indent from one content line: only what the
	line actually shares with it, so a shallower line (whitespace-only, or
	written flush left) keeps its own spacing rather than being blanked."""
	k = 0
	while k < len(common) and k < len(line) and common[k] == line[k]:
		k += 1
	return line[k:]


# ---------------------------------------------------------------------------
# Migration: a 2.x document rewritten for the current lexical rules
# ---------------------------------------------------------------------------


class Migration:
	"""What migrate produced, and what it could not carry across.

	current: the file already names its format, so there was nothing to migrate
	and text is the input. ambiguous: pieces the two rule sets read differently
	and nothing can decide between, left as written; always 0 when the caller
	said the file is 2.x. lost: lines 2.x bound a value on that nothing binds
	now - bracket text after the colon, which has no spelling here."""

	__slots__ = ("text", "current", "ambiguous", "lost")

	def __init__(self, text: str, current: bool = False, ambiguous: int = 0, lost: int = 0) -> None:
		self.text = text
		self.current = current
		self.ambiguous = ambiguous
		self.lost = lost


class _Migrating:
	"""The counters a line rewrite reports back, and the one thing it asks."""

	__slots__ = ("from_v2", "ambiguous", "lost")

	def __init__(self, from_v2):
		self.from_v2 = from_v2
		self.ambiguous = 0
		self.lost = 0


def format_version(text: str) -> int | None:
	"""The format major a document's `##    Format   N` line names, read the way
	migrate reads it. None when no line names one, which is every 2.x file and
	a current one written without the info block. migrate hands a file back
	untouched exactly when this is FORMAT_MAJOR or more, so a program can ask
	before it rewrites anything."""
	return _format_line_version(text[1:] if text.startswith("\ufeff") else text)


def _format_line_version(text):
	"""format_version() on text with the BOM already off.

	Raw bodies are skipped exactly where the rewrite skips them, by walking the
	lines through the same _migrate_line. A Format line pasted into a block is
	that block's content, and taking it as the file's would rewrite a current
	file, or leave an old one alone. A file naming this format on any line has
	nothing to migrate, so the highest line decides: the stamp migrate adds
	comes after an older one, and the next run has to see it."""
	tok = Tokens()
	fence = None
	# Only the blocks a line opens are wanted here, not what it counts.
	dry = _Migrating(True)
	found = None
	for line in text.split("\n"):
		body = line.rstrip("\r")
		if fence is not None:
			if _is_fence_close(body, fence[0], fence[1]):
				fence = None
			continue
		head = _trim_wsp_end(line)
		if head.startswith(FORMAT_LINE_HEAD):
			n = head[len(FORMAT_LINE_HEAD):]
			if n and all("0" <= c <= "9" for c in n):
				# A number too long for int() - CPython refuses past 4300
				# digits - is one no format will ever carry. The reference's
				# parse fails on it too and reads the line as this major, so
				# the file needs nothing (20260918b item 30).
				digits = n.lstrip("0") or "0"
				if len(digits) > 10:
					return FORMAT_MAJOR
				v = int(digits)
				if v >= FORMAT_MAJOR:
					return v
				found = v if found is None else max(found, v)
				continue
		_, fence = _migrate_line(_trim_wsp_end(body[len(_leading_ws(body)):]), tok, fence, dry)
	return found


def schema_ref(text: str) -> str | None:
	"""The schema a document's `##    Schema   REF` line names: a path, or a
	URL for an editor to fetch. None when no line names one. The first such
	line wins, and one inside a raw body is that block's content, as with the
	Format line. A relative path is the caller's to resolve, from the config
	file's directory."""
	if text.startswith("\ufeff"):
		text = text[1:]
	tok = Tokens()
	fence = None
	dry = _Migrating(True)
	for line in text.split("\n"):
		body = line.rstrip("\r")
		if fence is not None:
			if _is_fence_close(body, fence[0], fence[1]):
				fence = None
			continue
		if body.startswith(SCHEMA_LINE_HEAD):
			r = _trim_wsp(body[len(SCHEMA_LINE_HEAD):])
			if r:
				return r
			continue
		_, fence = _migrate_line(_trim_wsp_end(body[len(_leading_ws(body)):]), tok, fence, dry)
	return None


def migrate(text: str, from_v2: bool) -> Migration:
	"""Rewrite a document written under the 2.x rules so this parser reads the
	same tree. Each line is read with the 2.x tokenizer and re-spelled only
	where the two rule sets disagree: a bare or single-quoted piece whose
	backslash meant an escape is double-quoted with that escape; a piece that
	opened a quote it never closed is quoted whole; the `name:[disc]` selector
	sugar loses its colon, and on a last segment becomes `name: disc`, with
	`disc` spelled the way the formatter spells a value. A re-spelled piece
	holding a backslash is double-quoted, so the result reads the same under
	2.x and a second run changes nothing.
	Everything else - comments, blank lines, raw bodies, layout, a line 2.x
	could not read - comes through as written. One shape has no spelling
	here at all: a fence label holding a `#`, which 2.x ran to the end of the
	line and which now ends at the `#`.

	Which file this is cannot be read off the text: `p: 'C:\\temp'` is one value
	under 2.x and another under these rules, so rewriting a 3.0 file changes
	what it says. So the version line decides. A file that names this format is
	returned untouched; one that names an older format, or a caller passing
	from_v2, gets the backslash re-spellings; anything else gets every other
	rewrite and leaves those pieces alone, counted in ambiguous for the caller
	to refuse over. A rewritten file is stamped with the version line, so the
	second run has an answer the first one did not."""
	return _migrate_text(text, from_v2, True)


def migrate_unstamped(text: str, from_v2: bool) -> Migration:
	"""migrate() without the version line or the migrated note, for a program
	that writes GEN_BANNER itself, which carries the version line. The next run
	can tell the result is current only once that is written."""
	return _migrate_text(text, from_v2, False)


def _migrate_text(text, from_v2, stamp):
	whole = text
	bom = ""
	if text.startswith("\ufeff"):
		bom = "\ufeff"
		text = text[1:]
	version = _format_line_version(text)
	if version is not None and version >= FORMAT_MAJOR:
		return Migration(whole, current=True)
	st = _Migrating(from_v2 or version is not None)
	out = [bom]
	tok = Tokens()
	fence = None
	changed = False
	for i, line in enumerate(text.split("\n")):
		if i > 0:
			out.append("\n")
		body = line.rstrip("\r")
		cr = line[len(body):]
		if fence is not None:
			if _is_fence_close(body, fence[0], fence[1]):
				fence = None
			out.append(line)
			continue
		indent = _leading_ws(body)
		rest_full = body[len(indent):]
		rest = _trim_wsp_end(rest_full)
		migrated, fence = _migrate_line(rest, tok, fence, st)
		if migrated != rest:
			changed = True
		out.append(indent)
		out.append(migrated)
		out.append(rest_full[len(rest):])
		out.append(cr)
	# Stamping a file whose ambiguous pieces were left alone would claim a
	# migration that did not finish, and the next run would then skip it. A
	# document that never closes its raw block has nowhere to put the line
	# either: appended, it would be another line of the block's content.
	if stamp and st.ambiguous == 0 and fence is None:
		s = "".join(out)
		if s and not s.endswith("\n"):
			out.append("\n")
		out.append(FORMAT_LINE)
		out.append("\n")
		if changed:
			out.append(MIGRATED_LINE)
			out.append("\n")
	return Migration("".join(out), ambiguous=st.ambiguous, lost=st.lost)


def _splice(s, edits):
	"""Apply edits, each (start, end, replacement) in bytes, to the line's
	bytes."""
	out = []
	at = 0
	for start, end, with_ in sorted(edits, key=lambda e: e[0]):
		out.append(s[at:start])
		out.append(with_)
		at = end
	out.append(s[at:])
	return b"".join(out)


def _reads_same(spelling, quoted, logical):
	"""True when the current tokenizer reads this spelling as one whole piece,
	quoted the same way, with exactly this text, so nothing has to change."""
	tok = Tokens()
	tokenize_value(spelling, 0, Rules.CURRENT, tok)
	if len(tok.elements) != 1 or tok.value != (0, len(tok.src)):
		return False
	p = tok.elements[0]
	return (
		(p.quote is Quote.SINGLE or p.quote is Quote.DOUBLE) == quoted
		and p.quote is not Quote.OPEN
		and _bad_escape(tok, True) is None
		and _piece_text(p, tok.src) == logical
	)


def _migrate_spelling(logical, bare):
	"""How a re-spelled piece is written. 2.x read a backslash in bare and
	single-quoted text as an escape too, and double quotes are where both rule
	sets read one alike. No \\u goes in, since 2.x would keep it as written.
	So the migrated file reads the same under 2.x, and a second run changes
	nothing."""
	if "\\" in logical:
		return _quote_double_as(logical, Rules.V2)
	if bare and not _needs_quotes(logical):
		return logical
	return _quote_text_as(logical, Rules.V2)


def _v2_bracket_array(body):
	"""True when 2.x read this bare `[...]` body as the JSON-habit array rather
	than a discriminator: more than one element, where a comma behind a
	backslash was not one."""
	tok = Tokens()
	tokenize_value(body, 0, Rules.V2, tok)
	return len(tok.elements) > 1


def _value_edits(s, tok, edits, st):
	"""The re-spellings a value's pieces need. Each piece is read the 2.x way
	(escapes everywhere, an open quote kept whole, a quote at both ends making
	it quoted) and re-spelled only where the current rules would read the
	same text as something else."""
	for p in tok.elements:
		raw = s[p.start:p.end].decode("utf-8", "surrogatepass")
		quoted = p.quote is Quote.SINGLE or p.quote is Quote.DOUBLE
		if quoted:
			a, b = p.start - 1, p.end + 1
		else:
			a, b = p.start, p.end
		if p.quote is Quote.NONE and "\\" not in raw and raw:
			continue
		logical = _apply_escapes_v2(raw)
		if _reads_same(s[a:b].decode("utf-8", "surrogatepass"), quoted, logical):
			continue
		# A resolved escape is the one edit that turns on which rule set wrote
		# the file: these bytes say one thing under 2.x and another here. An
		# open quote or an empty slot reads alike either way, so it still goes,
		# and so does an unknown pair in double quotes, which both kept. A \u
		# in double quotes is a character now and was text in 2.x.
		if p.quote is Quote.DOUBLE:
			differs = _unicode_pair_differs(s[p.start:p.end])
		else:
			differs = logical != raw
		if differs and not st.from_v2:
			st.ambiguous += 1
			continue
		spelling = _migrate_spelling(logical, not (quoted or p.quote is Quote.OPEN))
		edits.append((a, b, spelling.encode("utf-8", "surrogatepass")))


def _migrate_line(rest, tok, fence, st):
	"""One line's content after its indent, re-spelled. Returns the text and
	the fence a raw block it opened is closed by (None when it opened none)."""
	if not rest or rest.startswith("#"):
		return rest, fence
	# A child-indent fence: 2.x read the info string to the end of the line.
	fo = _fence_open(rest)
	if fo is not None:
		return rest, (fo[0], fo[1])
	edits: list = []
	s = rest.encode("utf-8", "surrogatepass")
	if rest.startswith("*") and len(s) > 1 and _is_wsp_byte(s[1]):
		tokenize_value(rest, 1, Rules.V2, tok)
		# A bare comma was refused (E010), so there is nothing to carry.
		if len(tok.elements) == 1:
			_value_edits(s, tok, edits, st)
	else:
		tokenize(rest, ":", False, Rules.V2, tok)
		if tok.fault is not None:
			return rest, fence
		last = len(tok.segments) - 1
		for i, seg in enumerate(tok.segments):
			name = s[seg.name.start:seg.name.end].decode("utf-8", "surrogatepass")
			# An unknown pair in double quotes read the same in 2.x, and is
			# E023 now, so its backslash is doubled whichever wrote the file.
			# A \u pair is a character now, so that one needs --from-2x.
			name_raw = s[seg.name.start:seg.name.end]
			if seg.name.quote is Quote.DOUBLE and _v2_kept_escape(name_raw):
				if _unicode_pair_differs(name_raw) and not st.from_v2:
					st.ambiguous += 1
				else:
					edits.append((seg.name.start - 1, seg.name.end + 1, _escape_name_as(_apply_escapes_v2(name), Rules.V2).encode("utf-8", "surrogatepass")))
			if seg.name.quote is Quote.SINGLE and _apply_escapes_v2(name) != name:
				if st.from_v2:
					edits.append((seg.name.start - 1, seg.name.end + 1, _escape_name_as(_apply_escapes_v2(name), Rules.V2).encode("utf-8", "surrogatepass")))
				else:
					st.ambiguous += 1
			sel = seg.selector
			if sel is None:
				continue
			quoted = sel.quote is Quote.SINGLE or sel.quote is Quote.DOUBLE
			# Back from the body to the `[`, and forward to the `]`.
			open_at = sel.start - 1 if quoted else sel.start
			while open_at > 0 and _is_wsp_byte(s[open_at - 1]):
				open_at -= 1
			open_at -= 1
			close = sel.end + 1 if quoted else sel.end
			while s[close] != _B_RBRACKET:
				close += 1
			colon = None
			k = open_at
			while k > 0 and _is_wsp_byte(s[k - 1]):
				k -= 1
			if k > 0 and s[k - 1] == 0x3A:
				colon = k - 1
			body = s[sel.start:sel.end].decode("utf-8", "surrogatepass")
			logical = _apply_escapes_v2(body)
			unknown = sel.quote is Quote.DOUBLE and _v2_kept_escape(s[sel.start:sel.end])
			if i == last and tok.sep is None:
				if colon is not None:
					# `name:[disc]` with nothing after it: 2.x read it as
					# `name: disc`. Two or more elements in there was refused
					# as a bracket array - a comma behind a backslash was not
					# one - and an index or the wildcard was refused as a
					# selector, so those stay as written. A bare body moves
					# into a value, where a fence run opens a raw block and a
					# leading `[` is bracket text, so the emitter spells it.
					if not quoted and (_index_shape(body) or body == "*"):
						return rest, fence
					# 2.x bound the bracket array, as one folded string. There
					# is no spelling to move that to - a value beginning with
					# `[` is bracket text now - so the binding goes, and the
					# caller hears about it rather than reading exit 0.
					if not quoted and _v2_bracket_array(body):
						st.lost += 1
						return rest, fence
					if logical != body and not st.from_v2:
						st.ambiguous += 1
						continue
					if logical != body:
						spelling = _migrate_spelling(logical, False)
					elif quoted and not unknown:
						spelling = _trim_wsp(s[open_at + 1:close].decode("utf-8", "surrogatepass"))
					else:
						spelling = _migrate_spelling(logical, True)
					edits.append((colon, close + 1, (": " + spelling).encode("utf-8", "surrogatepass")))
					continue
			elif colon is not None:
				# The colon goes, and one space after it when the author
				# spaced both sides, so `base : [x]` comes out `base [x]`.
				spaced = colon > 0 and _is_wsp_byte(s[colon - 1]) and _is_wsp_byte(s[colon + 1])
				edits.append((colon, colon + 1 + int(spaced), b""))
			# Double quotes already read alike on both sides, so only the other
			# spellings turn on which rule set wrote the file.
			if unknown and _unicode_pair_differs(s[sel.start:sel.end]) and not st.from_v2:
				st.ambiguous += 1
			elif unknown:
				edits.append((sel.start - 1, sel.end + 1, _migrate_spelling(logical, False).encode("utf-8", "surrogatepass")))
			elif logical != body and sel.quote is not Quote.DOUBLE:
				if st.from_v2:
					if quoted:
						a, b = sel.start - 1, sel.end + 1
					else:
						a, b = sel.start, sel.end
					edits.append((a, b, _migrate_spelling(logical, False).encode("utf-8", "surrogatepass")))
				else:
					st.ambiguous += 1
		if tok.sep is not None:
			# A same-line fence: the info string ran to the end of the line.
			fo = _fence_open(s[tok.value[0]:].decode("utf-8", "surrogatepass"))
			if fo is not None:
				return _splice(s, edits).decode("utf-8", "surrogatepass"), (fo[0], fo[1])
			_value_edits(s, tok, edits, st)
	return _splice(s, edits).decode("utf-8", "surrogatepass"), fence


# ---------------------------------------------------------------------------
# Path scanner (shared by file lines and accessor queries)
# ---------------------------------------------------------------------------
# Selector is a tuple: ("val", str, quoted) | ("idx", int) | ("wild", None).
# quoted: the selector text was quoted in the path. A quoted selector is
# scalar-only - it matches a single-element value whose logical string equals
# the text - so quoting distinguishes the scalar "a, b" from the two-element
# list a, b, the same way quoting escapes elsewhere.


class _Segment:
	# name folded, escapes resolved; name_src as authored (unfolded, quotes
	# stripped, escapes as written); selector None or tuple; star = bare `*`
	# name wildcard (quoted "*" stays a literal name).
	__slots__ = ("name", "name_src", "selector", "star")

	def __init__(self, name, name_src, selector, star=False):
		self.name = name
		self.name_src = name_src
		self.selector = selector
		self.star = star


class _PathError(Exception):
	pass


def _index_shape(body):
	# The spelling of an index selector - an optional `#`, an optional `+`, then
	# digits - whatever its size. The grammar says 1*DIGIT, with no upper bound.
	b = body[1:] if body[:1] == "#" else body
	b = b[1:] if b[:1] == "+" else b
	return bool(b) and _all_ascii_digits(b)


def _parse_uint(s):
	# Rust usize::from_str: an optional leading '+', then ASCII digits, no underscores.
	if not s:
		return None
	body = s[1:] if s[0] == "+" else s
	if not body or not _all_ascii_digits(body):
		return None
	# Length-gate before int(): CPython 3.11+ refuses >4300 decimal digits, but the
	# reference just overflows. Leading zeros are legal and don't count toward range.
	digits = body.lstrip("0") or "0"
	if len(digits) > 20:
		return None
	n = int(digits)
	if n > 2 ** 64 - 1:
		return None
	return n


def _selector_of(p, s):
	"""What a selector body means: `*` the wildcard, an index shape an index,
	a quoted body a value match, anything else a bare value match."""
	body = _piece_text(p, s)
	if p.quote is Quote.SINGLE or p.quote is Quote.DOUBLE:
		# quotes force a value match, even numeric - and scalar-only
		return ("val", body, True)
	if body == "*":
		return ("wild", None)
	if body.startswith("#"):
		n = _parse_uint(body[1:])
		if n is not None:
			return ("idx", n)
	n = _parse_uint(body)
	if n is not None:
		return ("idx", n)
	if _index_shape(body):
		# All digits but past u64: an index no instance can have, not a
		# value selector that would create one on a write.
		return ("idx", 2**64 - 1)
	return ("val", body, False)


def _selector_open_quote(tok):
	"""Whether any segment's selector opens a quote it never closes. The
	tokenizer records it; `_selector_of` reads the body bare either way, so
	only the diagnostic depends on this."""
	return any(seg.selector is not None and seg.selector.quote is Quote.OPEN for seg in tok.segments)


def _unknown_escape(raw):
	"""The character after the first backslash in raw (bytes) that starts no
	escape, or the u or U of one that names no character. Only meaningful for
	a double-quoted piece."""
	i = raw.find(b"\\")
	while i >= 0:
		# A double-quoted piece cannot end on a lone backslash: it would have
		# escaped the closing quote.
		if i + 1 >= len(raw):
			return None
		k = raw[i + 1]
		if k in b"uU":
			if _unicode_escape(chr(k), raw[i + 2:i + 10].decode("latin-1")) is None:
				return chr(k)
		elif k not in b"tn\\\"'":
			return raw[i + 1:].decode("utf-8", "surrogatepass")[0]
		i = raw.find(b"\\", i + 2)
	return None


def _v2_kept_escape(raw):
	"""_unknown_escape by the 2.x rules, which had no \\u: a pair 2.x kept as
	written, so migrate doubles its backslash. Takes bytes."""
	i = raw.find(b"\\")
	while i >= 0:
		if i + 1 >= len(raw):
			return False
		if raw[i + 1] not in b"tn\\\"'":
			return True
		i = raw.find(b"\\", i + 2)
	return False


def _unicode_pair_differs(raw):
	"""A 2.x pair that is a real \\u escape now: 2.x read the text as written
	and the current rules read a character, so only --from-2x can say which.
	Takes bytes."""
	return _v2_kept_escape(raw) and _unknown_escape(raw) is None


def _bad_escape(tok, values):
	"""The first unknown escape in a double-quoted name, selector body or,
	when values is set, value element (E023). `"C:\\work\\new"` is the usual
	way to get one, and by then its `\\n` is already a newline, so the line is
	refused rather than read with the pair kept. A raw block's info string is
	not escape text, so a fence line passes values False."""
	pieces = []
	for seg in tok.segments:
		pieces.append(seg.name)
		if seg.selector is not None:
			pieces.append(seg.selector)
	if values:
		pieces.extend(tok.elements)
	for p in pieces:
		if p.quote is Quote.DOUBLE:
			c = _unknown_escape(tok.src[p.start:p.end])
			if c is not None:
				return c
	return None


def _path_like(p, src):
	"""A double-quoted value that starts like a Windows path, a drive (`C:\\`)
	or a share (`\\\\`), and holds a `\\t` or `\\n` escape (H004).
	`"C:\\temp"` reads as `C:`, a tab and `emp`: legal, and almost never
	meant. Any other pair made the line E023 before this is asked."""
	if p.quote is not Quote.DOUBLE:
		return False
	raw = src[p.start:p.end]
	drive = len(raw) >= 3 and raw[:1].isalpha() and raw[1:3] == b":\\"
	if not drive and not raw.startswith(b"\\\\"):
		return False
	i = 0
	while i + 1 < len(raw):
		if raw[i] != 0x5C:
			i += 1
			continue
		if raw[i + 1] in b"tn":
			return True
		i += 2
	return False


_PATH_HINT = "value looks like a Windows path, and its \\t or \\n reads as a tab or newline; single quotes keep a backslash as written"


def _escape_msg(c):
	if c in ("u", "U"):
		return "bad escape '\\" + c + "' in double quotes; \\u takes 4 hex digits and \\U takes 8, naming a Unicode character; write a backslash as '\\\\' or use single quotes"
	return "unknown escape '\\" + _one_line(c) + "' in double quotes; write a backslash as '\\\\' or use single quotes"


def _bracket_text(tok):
	"""Bracket text (E019): a `[` first after the colon. Read off the first
	piece rather than the value span, since a capped scan empties the span
	and keeps the pieces it built."""
	if tok.sep is None or not tok.elements:
		return False
	p = tok.elements[0]
	return p.quote is Quote.NONE and p.end > p.start and tok.src[p.start] == 0x5B


def _path_of(tok, s):
	"""The path the tokens spell: (segments, value_text), value_text None when
	there was no separator. Raises _PathError with the tokenizer's fault:
	input that is not a path at all, which the caller skips with a
	diagnostic."""
	if tok.fault is not None:
		raise _PathError(tok.fault[1])
	segments = []
	for seg in tok.segments:
		raw = s[seg.name.start:seg.name.end].decode("utf-8", "surrogatepass")
		# Names resolve escapes, the same rule values follow when they are
		# compared: two spellings of one name are one name. name_src keeps
		# the source spelling, which is what authored_name hands back.
		#
		# A name with nothing to resolve and no upper case is already its own
		# resolved, folded spelling, so the source text becomes the name and
		# nothing else is built. That is nearly every name in a document, and
		# this runs once per segment per line.
		if seg.name.quote is Quote.DOUBLE and "\\" in raw:
			name = _fold_name(_piece_text(seg.name, s))
		else:
			name = _fold_name(raw)
		selector = _selector_of(seg.selector, s) if seg.selector is not None else None
		segments.append(_Segment(name, raw, selector, seg.star))
	if tok.sep is None:
		return segments, None
	return segments, s[tok.value[0]:tok.value[1]].decode("utf-8", "surrogatepass")


def _scan_lookup(inp):
	"""Scan a lookup path `a . b [sel] . c`: the document-line spelling plus
	the bare `*` segment (the name wildcard - any child name), which document
	lines never take; only lookups (reads, the writer probe, schema paths)
	do. Whitespace around dots, colons and brackets is insignificant."""
	tok = Tokens()
	tokenize(inp, ":", True, Rules.CURRENT, tok)
	if _bad_escape(tok, False) is not None:
		raise _PathError("unknown escape in double quotes")
	return _path_of(tok, tok.src)


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------


def _locate_in(stack, indent):
	"""_resolve_parent() on a level stack, without moving anything: the parent
	it hands back (None for a line matching no level), the length it cuts the
	stack to, and whether it then pushes this line's column as a skipped
	line's. The emitter runs it on its model of the stack a reload will have."""
	hold = None
	for i in range(len(stack) - 1, -1, -1):
		ind, node = stack[i]
		if ind == indent:
			if node == UNOPENED:
				# Back at a skipped line's column: refused the same way.
				return (None, i + 1, False)
			# Sibling of stack[i]: its parent is the entry below it.
			parent = ROOT if i == 0 else stack[i - 1][1]
			# Keep the sentinel; a top-level line resolves to ROOT.
			return (DEAD if parent == UNOPENED else parent, max(i, 1), False)
		if len(indent) > len(ind) and indent.startswith(ind):
			# A skipped line's unopened level sits on top without opening
			# anything, so it does not count as a level in between.
			if i + 1 < len(stack) and stack[i + 1][1] != UNOPENED:
				break
			return (DEAD if node == UNOPENED else node, i + 1, False)
		if node == UNOPENED:
			hold = i
	# Skipped, but it holds its own column: whatever is written deeper is
	# skipped with it, and a line back at it is refused the same way instead of
	# binding one level up. It closes nothing, so a later line that matches a
	# level open before it still binds there, as in 2.0.0. The hold ends at the
	# first line neither under it nor at it, this one included, which keeps one
	# on the stack at most.
	return (None, len(stack) if hold is None else hold, True)


class _Outcome:
	"""What became of a line the parser did not bind whole. Only the funnel
	(`_Parser._refuse`) reads it; the count and the level follow from it."""

	__slots__ = ("kind", "text", "blank_before", "rest")

	def __init__(self, kind, text="", blank_before=False, rest=()):
		self.kind = kind
		self.text = text  # retained: the line, kept verbatim
		self.blank_before = blank_before  # retained: a blank line preceded it
		self.rest = rest  # stopped: the lines never read


# The line binds; a value it carried has nowhere to go and is gone.
OUT_VALUE_DROPPED = _Outcome("value_dropped")
# Read but not applicable here; re-emitted it could bind elsewhere, so it is
# gone and counts.
OUT_DROPPED = _Outcome("dropped")


def _out_retained(text, blank_before):
	"""Content-malformed: kept verbatim as trivia and written back in place,
	where it re-diagnoses identically and never reads as a binding."""
	return _Outcome("retained", text, blank_before)


def _out_stopped(rest):
	"""The parse stopped before this line; the rest was never read."""
	return _Outcome("stopped", rest=rest)


class _Parser:
	def __init__(self):
		self.arena = [_Node("", _empty(), 0, 0)]
		self.diags = []
		# (indent string, node) for each open level; [0] is the virtual root.
		self.stack = [("", ROOT)]
		# Per-node (name, value-key) -> first matching child, parallel to arena
		# and None until a parent's first insert, so leaves never allocate one.
		# Pure lookup accelerator for _select_or_create; children keeps the
		# order. Keys are _merge_key tuples, so no key text is built or stored.
		self.child_map: list = [None]
		# Per-node (name, display) -> first matching child: the `[value]` selector
		# accelerator (its predicate is display(), a different and non-injective
		# key from child_map's). Same first-wins discipline, same mutation sites,
		# same lazy allocation.
		self.disp_map: list = [None]
		# Whole-line comments waiting for the next line that binds a node. The
		# source indent is kept only to decide after-attachment (a comment
		# deeper than the next binding hangs on the block it sits in).
		self.pending = []
		# (end index, indent length): every pending entry before end has a
		# ceiling at or under that length. Lengths rise along the stack, so a
		# hang check pops the marks above its own indent and walks only what
		# they covered. Without it a run of retained bad lines is rewalked per
		# line and a plain text file parses in quadratic time.
		self.pend_marks = []
		self.saw_blank = False  # a blank line waits to become the next bound node's blank_before
		# An open stacked list defers its merge-key remap (rebuilding the key per
		# element is O(list^2) time); (node, map key, display key) at deferral
		# start, flushed before any map lookup and at end of parse.
		self.star_open = None
		# Parents where a remap landed on a key a sibling already held: the only
		# places a duplicate can survive the keyed lookup, so the fold starts here.
		self.late_dups = []
		# Node -> line of the re-open that H002-hinted it. A merge under a hinted
		# container combines the same two textual regions, so it hints too even
		# when it lands on the newest child at its own scope - that is how every
		# merged level reports, not just the outermost. The stored line splits old
		# children (hint) from ones the re-opened region itself created (silent).
		self.reentered = {}
		# Dropped lines/values canonical output cannot re-emit.
		self.lost = 0
		# Indent of the last E012 line kept as written, while the lines after
		# it sit under it; those are E018 and are kept as written too.
		self.kept_hold = None
		self.kept_any = False
		# parse_limited's caps, 0 = uncapped: nodes counted against the arena
		# (root excluded), elements against a single value's cell, diagnostics
		# against the list. Past the diagnostic cap nothing is listed, only
		# counted (errors, hints), for the one tail entry the parse ends with.
		self.max_nodes = 0
		self.max_elements = 0
		self.max_diags = 0
		self.unlisted_errors = 0
		self.unlisted_hints = 0
		# A raw block's or a stacked list's binding line and the last line it
		# took, for the save that keeps lines.
		self.ends: list[tuple[int, int]] = []
		# Each line counted in lost, kept only for the save that keeps lines,
		# since a capped parse of a huge bad file would hold one per line.
		self.track_dropped = False
		self.dropped: list[int] = []

	def _err(self, line, code, msg):
		self._diag(Diagnostic(line, Severity.Error, msg, code))

	def _diag(self, d):
		# Every parse diagnostic goes through here, so the cap sees them all.
		if self.max_diags and len(self.diags) >= self.max_diags:
			if d.severity == Severity.Error:
				self.unlisted_errors += 1
			else:
				self.unlisted_hints += 1
			return
		self.diags.append(d)

	def _select_or_create(self, parent, name, name_src, value, line):
		"""Find (or create by merge rule) the child of `parent` with this (name, value)."""
		self._star_flush()
		map_key = _merge_key(name, value)
		cmap = self.child_map[parent]
		if cmap is not None:
			found = cmap.get(map_key)
			if found is not None:
				return found
		idx = len(self.arena)
		node = _Node(name, value, parent, line, name_src)
		self.arena.append(node)
		self.arena[parent].children.append(idx)
		self.child_map.append(None)
		self.disp_map.append(None)
		if cmap is None:
			cmap = self.child_map[parent] = {}
		cmap[map_key] = idx
		dmap = self.disp_map[parent]
		if dmap is None:
			dmap = self.disp_map[parent] = {}
		dmap.setdefault((name, _disp_key(node.value)), idx)
		return idx

	def _star_flush(self):
		"""Apply an open stacked list's deferred remap. Runs before any map lookup
		(and at end of parse), so both maps are always fresh when queried."""
		if self.star_open is not None:
			node, key, disp = self.star_open
			self.star_open = None
			self._remap_child(node, key, disp)

	def _remap_child(self, node, old_key, old_disp):
		"""A node's value mutated in place (empty field filled, star element added):
		move its map entry from the old key to the new one. First-wins on both
		sides so lookups keep matching the earliest sibling, like the scan did."""
		parent = self.arena[node].parent
		name = self.arena[node].name
		cmap = self.child_map[parent]
		if cmap is None:
			cmap = self.child_map[parent] = {}
		if cmap.get(old_key) == node:
			del cmap[old_key]
		if cmap.setdefault(_merge_key(name, self.arena[node].value), node) != node:
			self.late_dups.append(parent)
		dmap = self.disp_map[parent]
		if dmap is None:
			dmap = self.disp_map[parent] = {}
		if dmap.get(old_disp) == node:
			del dmap[old_disp]
		dmap.setdefault((name, _disp_key(self.arena[node].value)), node)

	def _fold_late_dups(self):
		"""A value that mutates after its sibling group was keyed - an empty field
		filled by a fence, a stacked list closed - can land on a key an earlier
		sibling already holds, which the keyed lookup can no longer catch. Fold
		those pairs so the tree matches a reparse of its own canonical text.
		Only the parents _remap_child flagged can hold one. Shallowest first,
		since a fold hands the survivor more children and the order they arrive
		in decides whose trailing comment wins; folding keeps depths."""
		parents = set()
		for n in self.late_dups:
			depth, up = 0, n
			while up != ROOT:
				up = self.arena[up].parent
				depth += 1
			parents.add((depth, n))
		self.late_dups = []
		for _, n in sorted(parents):
			self._fold_dups_from(n)

	def _fold_dups_from(self, start):
		"""Depth-first below start, and only into survivors: a fold moves the
		loser's children up to join the survivor's, where they can pair."""
		# Explicit stack: parse-side walks stay iterative so depth can't blow
		# Python's recursion limit.
		stack = [start]
		while stack:
			parent = stack.pop()
			kids = self.arena[parent].children
			# Keyed to positions in keep, so a survivor's grew flag sits beside it.
			first: dict = {}
			keep: list[int] = []
			grew: list[bool] = []
			for c in kids:
				key = _merge_key(self.arena[c].name, self.arena[c].value)
				i = first.get(key)
				if i is not None:
					_fold_node_into(self.arena, keep[i], c)
					grew[i] = True
				else:
					first[key] = len(keep)
					keep.append(c)
					grew.append(False)
			stack.extend(k for k, g in zip(keep, grew) if g)
			self.arena[parent].children = keep

	def _attach_trivia(self, node, indent, trailing):
		"""Hand pending leading comments (and this line's trailing one) to a node.
		First trailing wins; a later one demotes to leading so nothing is lost."""
		if self.pending:
			t = self.arena[node]._triv()
			chain: list[tuple[str, int]] = []
			for p in self.pending:
				t.leading.append(_Lead(p.text, p.blank_before, _comment_depth(chain, indent, p.text, p.indent), p.line))
			self.pending = []
			self.pend_marks = []
		if trailing:
			t = self.arena[node]._triv()
			if not t.trailing:
				t.trailing = trailing
			else:
				t.leading.append(_Lead(trailing, False))

	def _hang_deeper_pending(self, new_indent):
		"""Comments written deeper than the incoming line belong to the block
		they sit in, not to the next binding: hang each on the deepest node
		whose bound indent prefixes the comment's, among the levels the
		incoming line is closing. Written at that node's own level the comment
		trails it (`after`); written deeper it sits inside the node's block
		(`inside`) - so a header whose children are all commented still owns
		them at their depth. Runs before the incoming line resolves (and at
		end of parse with the empty indent, so tail comments keep their block)."""
		if not self.pending:
			return
		new_len = len(new_indent)
		# Only entries above the last mark at or under this indent can hang.
		while self.pend_marks and self.pend_marks[-1][1] > new_len:
			self.pend_marks.pop()
		start = self.pend_marks[-1][0] if self.pend_marks else 0
		taken = self.pending[start:]
		del self.pending[start:]
		# A comment never goes ahead of the one written before it. Once one
		# stays for the incoming line every later one stays too, and one whose
		# block would be written out before the last one's goes there with it
		# instead. What sits before `start` stays, so nothing after it can hang.
		kept = start > 0
		# Where the last comment went: (stack index, node, at its own level).
		last = None
		chain: list[tuple[str, int]] = []
		for p in taken:
			if not kept and p.ceiling > new_len:
				# A level shallower than the incoming line stays open and may
				# still gain children, so a comment must not hang there - it
				# would emit below the child; keep it pending instead.
				at = None
				for si in range(len(self.stack) - 1, -1, -1):
					ind, node = self.stack[si]
					if node != ROOT and node != DEAD and node != UNOPENED and len(ind) >= len(new_indent) and p.indent.startswith(ind):
						# A list element's column is an entry with the list's
						# node on the list's own entry. It is inside the list,
						# not its level.
						column = si > 0 and self.stack[si - 1][1] == node
						at = (si, node, len(ind) == len(p.indent) and not column)
						break
				# A root node's trailing comment emits at column zero, which is
				# exactly how the document's own trailing comment is spelled, so
				# keeping the two apart here made a merge depend on whether the
				# layer had been formatted first. Let it orphan, the way a
				# reload of this document's own output reads it. A comment
				# deeper than the node keeps an indent of its own and comes back
				# where it was, so it still hangs.
				if at is not None and (not at[2] or self.arena[at[1]].parent != ROOT):
					# A deeper block is written out first, and a block's inside
					# comments before its after ones.
					if last is not None and (at[0], not at[2]) > (last[0], not last[2]):
						at = last
					if at != last:
						chain.clear()
					last = at
					lead = _Lead(p.text, p.blank_before, _comment_depth(chain, self.stack[at[0]][0], p.text, p.indent), p.line)
					if at[2]:
						self.arena[at[1]]._triv().after.append(lead)
					else:
						self.arena[at[1]]._triv().inside.append(lead)
					continue
			kept = True
			p.ceiling = min(p.ceiling, new_len)
			self.pending.append(p)
		if self.pend_marks and self.pend_marks[-1][1] == new_len:
			self.pend_marks[-1] = (len(self.pending), new_len)
		else:
			self.pend_marks.append((len(self.pending), new_len))

	def _resolve_parent(self, indent, found):
		"""Resolve which open level this indent belongs to, walking down from
		the top. Equal to a level is its sibling. Deeper than a level is its
		child, unless a level opened under that one is still open, in which case
		the line falls between the two. Anything else is a recoverable error.
		`found` is _locate_in() on the same indent, which the line loop has
		already asked."""
		parent, cut, push = found
		del self.stack[cut:]
		if push:
			self.stack.append((indent, UNOPENED))
		return parent

	def _drop_line(self, line):
		self.lost += 1
		if self.track_dropped:
			self.dropped.append(line)

	def _refuse(self, line, code, msg, outcome, indent):
		"""The one exit for a line the parser does not bind whole. An arm says
		what became of the line and nothing else: the lost count and the level
		the line holds follow from the outcome here, so no arm can forget
		either. design.md's outcome table gives each code its row."""
		self._err(line, code, msg)
		holds = outcome.kind in ("retained", "dropped")
		if outcome.kind in ("value_dropped", "dropped"):
			self._drop_line(line)
		elif outcome.kind == "stopped":
			for k, ln in enumerate(outcome.rest):
				if _trim_wsp(ln):
					self._drop_line(line + k)
		if outcome.kind == "retained":
			p = _Pend(outcome.text, indent, outcome.blank_before, line)
			# A line kept as written never hangs on a block: its indent is not
			# one the output's levels are spelled with, so the block it would
			# match here is not the one it matches on a reload. It waits for
			# the next binding line, as do the pending lines after it.
			if outcome.text.startswith((" ", "\t")):
				p.ceiling = 0
			self.pending.append(p)
		# A refused line owns its indent, so what is written deeper is skipped
		# with it (E018). An indent that matched no level already holds an
		# unopened one, which refuses a sibling the same way; that one stays.
		if holds and not (self.stack and self.stack[-1] == (indent, UNOPENED)):
			self.stack.append((indent, DEAD))

	def _misplaced(self, line, code, indent, rest, had_blank, raw):
		"""A line refused for where it sits rather than for what it says: E012,
		or E018 under one. Written back exactly as it was, it sits the same way
		on a reload, as long as its indent holds a space, since no level the
		emitter opens is spelled with one. A tab-only indent would bind there,
		and a line opening a raw block would take its body along, so those are
		dropped. An E018 line is kept only under a kept E012 one."""
		if raw:
			keep = False
		elif code == "E012":
			keep = " " in indent
		else:
			h = self.kept_hold
			keep = h is not None and len(indent) > len(h) and indent.startswith(h)
		if keep:
			self.kept_any = True
		if code == "E012":
			self.kept_hold = indent if keep else None
			msg = "indentation matches no open level"
		else:
			msg = "parent line was skipped; line skipped"
		self._refuse(line, code, msg, _out_retained(indent + _trim_wsp_end(rest), had_blank) if keep else OUT_DROPPED, indent)

	def _skip_under_dead(self, line, indent):
		"""Diagnose a line written under a skipped line, and skip it too. Its own
		level stays dead so deeper lines go the same way."""
		self._refuse(line, "E018", "parent line was skipped; line skipped", OUT_DROPPED, indent)

	def _skip_field_line(self, lines, i, indent, tok):
		"""Where the parse resumes after a refused field line. Every arm that
		skips one comes through here, so a skipped line whose value opens a raw
		block takes the body with it: read as lines, the body would bind or be
		refused line by line, and its closing fence would open a block that runs
		to the end of the file. A line whose path did not parse has no value to
		read, so it goes alone."""
		fence = _line_fence(tok)
		if fence is None:
			return i + 1
		return self._consume_raw(lines, i + 1, i + 1, indent, fence)[1]

	def _attach_path(self, parent, segs, value, line, indent):
		"""Walk path segments under `parent`, select-or-creating; returns the node
		for the last segment carrying `value`. None aborts the line (diagnosed)."""
		self._star_flush()
		# Field child under a stacked list: diagnose the mix once, keep the field.
		pnode = self.arena[parent]
		if pnode.star_list and not pnode.star_mixed:
			pnode.star_mixed = True
			self._err(line, "E001", "field mixed with list elements")
		# Nesting cap: parent depth plus the segments this line adds. Checked
		# before any node is created so a rejected line leaves nothing behind.
		parent_depth = 0
		up = parent
		while up != ROOT:
			parent_depth += 1
			up = self.arena[up].parent
		if parent_depth + len(segs) > MAX_DEPTH:
			self._refuse(line, "E016", f"nesting deeper than {MAX_DEPTH} levels; line skipped", OUT_DROPPED, indent)
			return None
		cur = parent
		last = len(segs) - 1
		for i, seg in enumerate(segs):
			is_last = i == last
			sel = seg.selector
			if sel is not None and sel[0] == "val":
				# Same escape-applied display predicate resolution uses, so a
				# selector also selects an array-valued instance instead of
				# creating a spurious second one - via the disp_map accelerator
				# (the inline spelling was quadratic in siblings without it).
				# Create only when nothing matches.
				# A quoted selector is scalar-only, so it is the one that needs
				# the fallback scan: the accelerator keeps just the first same-
				# display child, which may be the non-scalar one. An unquoted
				# selector takes whatever the accelerator holds and does not scan,
				# so it can bind a raw block where a quoted selector picks the
				# scalar sibling.
				found = self._find_by_value(cur, seg.name, sel[1], sel[2])
				if found is not None:
					cur = found
				else:
					disc = _cell([_new_element(sel[1])])
					cur = self._select_or_create(cur, seg.name, seg.name_src, disc, line)
				if is_last and not value.is_empty():
					# `a.b[X]: v` - the discriminator is the value; a second
					# value has nowhere unambiguous to go.
					self._refuse(line, "E002", f"value after selector on '{_diag_name(seg.name)}' ignored", OUT_VALUE_DROPPED, indent)
			elif sel is not None and sel[0] == "idx":
				k = sel[1]
				found = None
				seen = 0
				for c in self.arena[cur].children:
					if self.arena[c].name == seg.name:
						if seen == k:
							found = c
							break
						seen += 1
				if found is not None:
					cur = found
				else:
					self._refuse(line, "E003", f"no instance {k} of '{_diag_name(seg.name)}'", OUT_DROPPED, indent)
					return None
				if is_last and not value.is_empty():
					# Same as the value selector: the instance is already chosen,
					# so a trailing value has nowhere to bind.
					self._refuse(line, "E002", f"value after selector on '{_diag_name(seg.name)}' ignored", OUT_VALUE_DROPPED, indent)
			elif sel is not None and sel[0] == "wild":
				self._refuse(line, "E004", "wildcard selector is query-only", OUT_DROPPED, indent)
				return None
			elif not is_last:
				cur = self._select_or_create(cur, seg.name, seg.name_src, _empty(), line)
			else:
				parent = cur
				before = len(self.arena)
				cur = self._select_or_create(cur, seg.name, seg.name_src, value, line)
				# Two separately-written bindings just combined: legal (the
				# merge rule), but only the parser can see it happened, so
				# say so. Adjacent re-mentions (still the newest binding at
				# this scope) and selector/path-intermediate merges stay
				# silent - those are the deliberate redundant-path idiom.
				# Under a hinted container the newest-child pass does not
				# apply to children the earlier region wrote: those merges
				# combine the same two regions, so every level reports.
				if cur < before and self.arena[cur].line != line:
					non_last = self.arena[parent].children[-1] != cur
					reopen_line = self.reentered.get(parent)
					cross_region = reopen_line is not None and self.arena[cur].line < reopen_line
					if non_last or cross_region:
						at = self.arena[cur].line
						self._diag(Diagnostic(
							line, Severity.Hint,
							f"{_h002_head(seg.name)}line {at} (same name and value combine)",
							"H002"))
						self.reentered[cur] = line
		return cur

	def _find_by_value(self, cur, name, text, quoted):
		"""The child of `cur` named `name` whose display form is the selector text
		(escapes applied), or None. Quoted selectors only match a single scalar."""
		want = text
		dmap = self.disp_map[cur]
		found = dmap.get((name, want)) if dmap is not None else None
		if found is not None and quoted and not _single_scalar(self.arena[found].value):
			found = None
		if found is None and quoted:
			# The display map keeps only the first same-display child, which may
			# be an array where a quoted selector wants the scalar. A scalar
			# child with this text is exactly the one-element value the merge
			# map is keyed on, so ask that map: a scan of every sibling was the
			# same answer, quadratic on the create path.
			cmap = self.child_map[cur]
			if cmap is not None:
				return cmap.get(_merge_key(name, _cell([_new_element(want)])))
		return found

	def _consume_raw(self, lines, i, open_line, open_indent, fence):
		"""Consume raw-block content after an opening fence. Returns (value, next
		line index). The closing fence's indent is stripped from each content
		line (the opening line's when the block never closes); the rest is
		content."""
		ch, length, info = fence
		content = []
		nest = open_indent
		closed = False
		while i < len(lines):
			if _is_fence_close(lines[i], ch, length):
				# The closing fence's indent is the nesting; everything a content
				# line carries past it is content, so a body whose lines all
				# share an indent keeps it (a writer-built block depends on that).
				nest = _leading_ws(lines[i])
				closed = True
				i += 1
				break
			content.append(lines[i])
			i += 1
		if not closed:
			self._err(open_line, "E005", "unterminated raw block")
		stripped = [_strip_common(ln, nest) for ln in content]
		return _raw("\n".join(stripped), info, ch, length), i

	def _bind_block(self, parent, value, line, indent):
		"""A bare fence line is a value line for its parent field: fills an empty
		value, else creates a new instance of that field (the repeated-leaf rule).
		Returns the node the block landed on (None = no parent, diagnosed)."""
		if parent == ROOT:
			self._refuse(line, "E006", "raw block with no parent field", OUT_DROPPED, indent)
			return None
		if self.arena[parent].value.is_empty():
			pnode = self.arena[parent]
			old_key = _merge_key(pnode.name, pnode.value)
			old_disp = (pnode.name, _disp_key(pnode.value))
			pnode.value = value
			self._remap_child(parent, old_key, old_disp)
			return parent
		name = self.arena[parent].name
		name_src = self.arena[parent].name_src
		grandparent = self.arena[parent].parent
		return self._select_or_create(grandparent, name, name_src, value, line)

	def _add_star_element(self, parent, tok, s, line, indent):
		"""One stacked-list element (`* scalar`) appends to the parent's array.
		True when it joined the list."""
		if parent == ROOT:
			self._refuse(line, "E007", "list element with no parent field", OUT_DROPPED, indent)
			return False
		# Uniform-or-nothing (spec): a mix with field children is not a block array.
		if self.arena[parent].children:
			self._refuse(line, "E008", "list element mixed with field children; ignored", OUT_DROPPED, indent)
			return False
		# One scalar per line; a bare comma is an error, not a second element.
		if len(tok.elements) > 1:
			self._refuse(line, "E010", "bare comma in list element (one element per line)", OUT_DROPPED, indent)
			return False
		piece = tok.elements[0]
		el = _element_of(piece, s)
		if el is None:
			self._refuse(line, "E009", "empty list element", OUT_DROPPED, indent)
			return False
		if piece.quote is Quote.OPEN:
			self._err(line, "E017", "unterminated quote in value")
		binding_like = not el.quoted and _looks_like_binding(el.text)
		path = _path_like(piece, s)
		clash = _unit_clash(self.arena[parent].name, el.text)
		# Element cap: each element line past it is refused on its own, the way
		# any other bad element line is. Only a line that would join the list:
		# under a field that already has a value it is E011, cap or not.
		if (
			self.max_elements
			and self.arena[parent].star_list
			and self.arena[parent].value.kind == "cell"
			and len(self.arena[parent].value.els) >= self.max_elements
		):
			self._refuse(line, "E021", f"array longer than {self.max_elements} elements; line skipped", OUT_DROPPED, indent)
			return False
		node = self.arena[parent]
		if node.value.kind == "empty":
			old_key = _merge_key(node.name, node.value)
			old_disp = (node.name, _disp_key(node.value))
			node.value = _cell([el])
			node.star_list = True
			# First element: remap now (Empty -> cell changes both keys), then
			# open the deferral window with the current keys. Rebuilding the
			# keys per appended element was O(list^2) time; the maps only need
			# to be fresh when queried, and every query flushes first.
			self._remap_child(parent, old_key, old_disp)
			k = _merge_key(node.name, node.value)
			d = (node.name, _disp_key(node.value))
			self.star_open = (parent, k, d)
		elif node.value.kind == "cell" and node.star_list:
			if self.star_open is None or self.star_open[0] != parent:
				self._star_flush()
				old_key = _merge_key(node.name, node.value)
				old_disp = (node.name, _disp_key(node.value))
				self.star_open = (parent, old_key, old_disp)
			node.value.els.append(el)
		else:
			self._refuse(line, "E011", "field already has a value; list element ignored", OUT_DROPPED, indent)
			return False
		if binding_like:
			self._diag(Diagnostic(line, Severity.Hint, "list element looks like a field binding; it is read as a string (quote it to say so)", "H003"))
		if path:
			self._diag(Diagnostic(line, Severity.Hint, _PATH_HINT, "H004"))
		if clash is not None:
			self._diag(Diagnostic(line, Severity.Hint, clash, "H005"))
		# A kept element holds its column as a dropped one does, with the field
		# as that level's node: a line written deeper binds where it always did,
		# and a line back at the element's column is its sibling, where no level
		# had been opened there and every later sibling was E012 (20260918b
		# item 28).
		self.stack.append((indent, parent))
		return True

	def _keep_among(self, parent):
		"""Kept lines waiting for the list element that just joined sat among
		the list's elements, so they stay there; comments still ride the
		field."""
		if not any(not p.text.startswith("#") for p in self.pending):
			return
		node = self.arena[parent]
		if node.value.kind != "cell":
			return
		before = len(node.value.els) - 1
		rest = []
		among = node._triv().among
		for p in self.pending:
			if p.text.startswith("#"):
				rest.append(p)
			else:
				among.append((before, _Lead(p.text, p.blank_before)))
		self.pending = rest
		self.pend_marks = []

	def _emit_repeated_leaf_hints(self):
		"""Legal input that looks like a common mistake: a field repeating as a bare
		scalar leaf. Mandatory hint per spec (never fails a load)."""
		hints = []
		for parent in range(len(self.arena)):
			children = self.arena[parent].children
			if len(children) < 2:
				continue
			# Group by name in first-appearance order: hint order must be
			# deterministic or the cross-binding check can't compare `check` output.
			# The member list is made only when a name repeats. Nearly every
			# name is seen once, and a list per child was most of what this
			# pass allocated.
			by_name: list = []
			group_of: dict = {}
			for c in children:
				name = self.arena[c].name
				g = group_of.get(name)
				if g is None:
					group_of[name] = len(by_name)
					by_name.append([name, c, None])
				elif by_name[g][2] is None:
					by_name[g][2] = [by_name[g][1], c]
				else:
					by_name[g][2].append(c)
			for name, _, group in by_name:
				if group is None:
					continue
				all_scalar_leaves = all(
					not self.arena[c].children
					and self.arena[c].value.kind == "cell"
					and not self.arena[c].star_list
					for c in group
				)
				if all_scalar_leaves:
					line = max(self.arena[c].line for c in group)
					joined = ", ".join(_diag_value(self.arena[c].value) for c in group)
					hints.append((line, f"{_h001_head(name)}{joined}'?"))
		for line, message in hints:
			self._diag(Diagnostic(line, Severity.Hint, message, "H001"))

	def parse(self, text: str, strictness: Strictness) -> Document:
		# UTF-8 BOM strip, then split keeping raw lines (CR stripped per line).
		if text.startswith("﻿"):
			text = text[1:]
		# The whole trailing CR run goes, not just one: a raw block keeps its
		# content untrimmed, so a line left ending in CR would be written back as
		# CRLF and read as neither - the one shape where the count is visible.
		lines = [ln.rstrip("\r") for ln in text.split("\n")]
		# A newline-terminated text splits into one more piece than it has
		# lines. An unterminated raw block took that empty tail as a body line,
		# so the same last line read differently with and without its newline,
		# which the grammar says are one document.
		if text.endswith("\n"):
			lines.pop()
		i = 0
		nlines = len(lines)
		node_capped = False
		tok = Tokens(self.max_elements)
		locate = _locate_in  # a local, once per line
		while i < nlines:
			# Node cap: reported at the first line not parsed, so the count can
			# overshoot by at most one line's path. The unparsed remainder
			# counts as lost, which is what keeps save_file from writing a
			# silently truncated document.
			if self.max_nodes and len(self.arena) - 1 > self.max_nodes:
				self._refuse(i + 1, "E020", f"node cap of {self.max_nodes} exceeded; parse stopped", _out_stopped(lines[i:]), "")
				node_capped = True
				break
			lineno = i + 1
			line = _trim_wsp_end(lines[i])
			rest = line.lstrip(" \t")
			indent = line[:len(line) - len(rest)]
			# A carriage return is a blank but never indent, so a run of blanks
			# holding one comes off the front of the rest instead.
			rest = rest.lstrip(_WSP)
			lead = len(line) - len(indent) - len(rest)
			if not rest:
				self.saw_blank = True
				i += 1
				continue
			# Whole-line comment: hold it for the next line that binds a node.
			# It consumes a pending blank into its own flag, so a blank between
			# comment-only regions survives the round-trip.
			if rest.startswith("#"):
				self.pending.append(_Pend(rest, indent, self.saw_blank, lineno))
				self.saw_blank = False
				i += 1
				continue
			# A kept misplaced line holds only the lines written under it.
			h = self.kept_hold
			if h is not None and not (len(indent) > len(h) and indent.startswith(h)):
				self.kept_hold = None
			# Any other line consumes the pending blank; only a field line that
			# binds turns it into grouping.
			had_blank = self.saw_blank
			self.saw_blank = False
			# A binding line claims the pending comments - but deeper-written
			# ones hang on their own block first. A line refused for where it
			# sits closes nothing, so it leaves them for the next line: kept,
			# its indent would measure the levels differently on a reload, and
			# dropped, a reload never sees it.
			found = locate(self.stack, indent)
			if found[0] is not None and found[0] != DEAD:
				self._hang_deeper_pending(indent)
			# Child-indent fence: a value line for its parent field. The fence
			# and its info string are the value; a comment may follow them.
			fence = None
			if rest[0] == "`" or rest[0] == "~":
				tokenize_value(rest, 0, Rules.CURRENT, tok)
				# A capped scan zeroed the value, and a fence is told by its
				# leading run alone.
				fence = _fence_open(rest if tok.capped else tok.src[tok.value[0]:tok.value[1]].decode("utf-8", "surrogatepass"))
			if fence is not None:
				comment = tok.src[tok.comment:].decode("utf-8", "surrogatepass") if tok.comment is not None else ""
				parent = self._resolve_parent(indent, found)
				value, nxt = self._consume_raw(lines, i + 1, lineno, indent, fence)
				if parent is None:
					# The body goes with its fence: parsed live, it would read as
					# root bindings and the closing fence would open a second block.
					self._refuse(lineno, "E012", "indentation matches no open level", OUT_DROPPED, indent)
					i = nxt
					continue
				if parent == DEAD:
					self._skip_under_dead(lineno, indent)
				elif tok.capped:
					# The block goes with its line, or the body would read as live
					# lines.
					self._refuse(lineno, "E021", f"array longer than {self.max_elements} elements; line skipped", OUT_DROPPED, indent)
				else:
					node = self._bind_block(parent, value, lineno, indent)
					if node is not None:
						self.ends.append((self.arena[node].line, nxt))
						self._attach_trivia(node, indent, comment)
				i = nxt
				continue
			# Stacked-list element: colon-less by construction ('*' can't begin a name).
			if rest.startswith("*"):
				after = rest[1:]
				# A `*` alone after the trim: whether a space followed it
				# decides between an empty element and a malformed line, and
				# only the untrimmed line still knows.
				spaced = after.startswith((" ", "\t", "\r"))
				if not after:
					at = len(indent) + lead + 1
					spaced = lines[i][at:at + 1] in (" ", "\t", "\r")
				if spaced:
					parent = self._resolve_parent(indent, found)
					if parent is None:
						self._misplaced(lineno, "E012", indent, rest, had_blank, False)
						i += 1
						continue
					if parent == DEAD:
						self._misplaced(lineno, "E018", indent, rest, had_blank, False)
						i += 1
						continue
					tokenize_value(rest, 1, Rules.CURRENT, tok)
					c = _bad_escape(tok, True)
					if c is not None:
						self._refuse(lineno, "E023", _escape_msg(c), _out_retained(_trim_wsp_end(rest), had_blank), indent)
						i += 1
						continue
					comment = tok.src[tok.comment:].decode("utf-8", "surrogatepass") if tok.comment is not None else ""
					# Elements have no node of their own; trivia rides the field. At the
					# root there is no field (E007), so the comment rides the document
					# like any other pending one.
					if parent != ROOT:
						if self._add_star_element(parent, tok, tok.src, lineno, indent):
							self._keep_among(parent)
						head = self.arena[parent].line
						if self.ends and self.ends[-1][0] == head:
							self.ends[-1] = (head, lineno)
						else:
							self.ends.append((head, lineno))
						self._attach_trivia(parent, indent, comment)
					else:
						if comment:
							self.pending.append(_Pend(comment, indent, had_blank, 0))
						self._add_star_element(parent, tok, tok.src, lineno, indent)
					i += 1
					continue
				parent = self._resolve_parent(indent, found)
				if parent is None:
					self._misplaced(lineno, "E012", indent, rest, had_blank, False)
					i += 1
					continue
				if parent == DEAD:
					self._misplaced(lineno, "E018", indent, rest, had_blank, False)
					i += 1
					continue
				# Content-malformed at any position, so safe to retain. The BOM
				# exception the field arm carries cannot apply here: this line
				# starts with the '*' that brought us in.
				self._refuse(lineno, "E013", "malformed line: '*' must be followed by a space", _out_retained(_trim_wsp_end(rest), had_blank), indent)
				i += 1
				continue
			# Field line.
			tokenize(rest, ":", False, Rules.CURRENT, tok)
			s = tok.src
			comment = s[tok.comment:].decode("utf-8", "surrogatepass") if tok.comment is not None else ""
			parent = self._resolve_parent(indent, found)
			if parent is None:
				self._misplaced(lineno, "E012", indent, rest, had_blank, _line_fence(tok) is not None)
				i = self._skip_field_line(lines, i, indent, tok)
				continue
			if parent == DEAD:
				self._misplaced(lineno, "E018", indent, rest, had_blank, _line_fence(tok) is not None)
				i = self._skip_field_line(lines, i, indent, tok)
				continue
			try:
				segments, value_text = _path_of(tok, s)
			except _PathError as e:
				# Content-malformed at any position, so retained - except a line
				# led by a BOM, which the file-start strip would rewrite into
				# something that can bind.
				out = OUT_DROPPED if rest.startswith("\ufeff") else _out_retained(_trim_wsp_end(rest), had_blank)
				# The column counts bytes from the line start, so all four
				# bindings spell it the same on non-ASCII text. The indent and
				# the blank run after it are blanks only, so their lengths are
				# their byte counts.
				col = len(indent) + lead + (tok.fault[0] if tok.fault else 0) + 1
				self._refuse(lineno, "E014", f"malformed line skipped: {e.args[0]}, at column {col}", out, indent)
				i += 1
				continue
			nxt = i + 1
			# A selector body takes the same open-quote rule as a value
			# element, and the same code: the body is read bare, quotes and
			# all, so the line still binds - somewhere the author did not mean.
			if _selector_open_quote(tok):
				self._err(lineno, "E017", "unterminated quote in selector")
			# A value spelled the way JSON, TOML and YAML spell an array. The
			# brackets are not a selector after the colon, and reading the
			# text without them would bake a changed value in, so the line is
			# kept verbatim. Judged before the cap and from the first piece,
			# which the cap keeps: a cap refuses only a line that would bind.
			if _bracket_text(tok):
				self._refuse(lineno, "E019", "bracket array syntax; an array is comma-separated, without brackets", _out_retained(_trim_wsp_end(rest), had_blank), indent)
				i = nxt
				continue
			# Same outcome as bracket text, and judged at the same point: the
			# pair cannot be read as written or as an escape without guessing.
			c = _bad_escape(tok, _line_fence(tok) is None)
			if c is not None:
				self._refuse(lineno, "E023", _escape_msg(c), _out_retained(_trim_wsp_end(rest), had_blank), indent)
				i = nxt
				continue
			# Element cap: the whole line is refused, so a capped load never
			# holds a truncated array that would read as the document's
			# value. The scan stopped at the cap, so nothing past it was
			# built either, and the value span is empty: this has to come
			# before the value is read, or the line would bind as empty.
			if tok.capped:
				self._refuse(lineno, "E021", f"array longer than {self.max_elements} elements; line skipped", OUT_DROPPED, indent)
				i = self._skip_field_line(lines, i, indent, tok)
				continue
			# The verbatim value span, kept for reads' `raw` (only the plain
			# scalar/inline-array case has a one-line source spelling).
			src_text = None
			if value_text is None:
				# A clean path with no colon is the one defined repair: the
				# obvious intent is that path with an empty value.
				self._err(lineno, "E015", "missing colon; repaired as an empty value")
				value = _empty()
			elif value_text == "":
				value = _empty()
			else:
				fence = _fence_open(value_text)
				if fence is not None:
					# Same-line fence spelling.
					value, nxt = self._consume_raw(lines, i + 1, lineno, indent, fence)
				else:
					if any(p.quote is Quote.OPEN for p in tok.elements):
						self._err(lineno, "E017", "unterminated quote in value")
					src_text = value_text
					value = _cell_of_tokens(tok, s)
			# Record only when the bound node holds exactly this line's value
			# (a merge into an equal-valued node keeps the first line's span;
			# a value dropped after a last-segment selector records nothing).
			node = self._attach_path(parent, segments, value, lineno, indent)
			if node is not None:
				if src_text is not None and any(_path_like(p, tok.src) for p in tok.elements):
					self._diag(Diagnostic(lineno, Severity.Hint, _PATH_HINT, "H004"))
				if src_text is not None:
					for p in tok.elements:
						clash = _unit_clash(self.arena[node].name, _piece_text(p, tok.src))
						if clash is not None:
							self._diag(Diagnostic(lineno, Severity.Hint, clash, "H005"))
							break
				# The bound node usually holds the very object just parsed, so
				# identity settles it and neither key gets built. The key
				# compare is only needed when a merge landed on an equal-valued
				# node that already existed.
				if src_text is not None and not self.arena[node].src_set and (
					self.arena[node].value is value
					or _value_key(self.arena[node].value) == _value_key(value)
				):
					self.arena[node].src_set = True
					if not _src_matches_display(self.arena[node].value, src_text):
						self.arena[node].src = src_text
				if had_blank:
					self.arena[node].blank_before = True
				if nxt > i + 1:
					self.ends.append((lineno, nxt))
				self._attach_trivia(node, indent, comment)
				self.stack.append((indent, node))
			i = nxt
		# A cap crossed on the document's last line still reports, with nothing
		# left to skip.
		if not node_capped and self.max_nodes and len(self.arena) - 1 > self.max_nodes:
			self._refuse(nlines, "E020", f"node cap of {self.max_nodes} exceeded; parse stopped", _out_stopped(()), "")
		self._star_flush()
		# Indented tail comments keep their block; only top-level ones orphan.
		# Before the fold, which carries a dropped instance's comments over to
		# the one it joins: after it they would hang on the dropped one.
		self._hang_deeper_pending("")
		self._fold_late_dups()
		for n in range(len(self.arena)):
			_settle_block(self.arena, n, 1)
		self._emit_repeated_leaf_hints()
		chain: list[tuple[str, int]] = []
		orphans = [_Lead(p.text, p.blank_before, _comment_depth(chain, "", p.text, p.indent), p.line) for p in self.pending]
		self.pending = []
		_settle_first_blank(self.arena, orphans)
		# The one entry past the cap: what was not listed, and whether any of
		# it was an error, so a consumer scanning the list for errors still
		# finds one and a Strict load still fails.
		more = self.unlisted_errors + self.unlisted_hints
		if more:
			self.diags.append(Diagnostic(
				0,  # about the list, not a line
				Severity.Error if self.unlisted_errors else Severity.Hint,
				f"diagnostic cap of {self.max_diags} reached; {more} more not listed, {self.unlisted_errors} of them errors",
				"E022"))
		doc = Document(self.arena, self.diags, strictness, orphans, self.lost)
		doc._ends = self.ends
		doc._dropped = self.dropped
		doc._kept = self.kept_any
		doc._settle_kept()
		return doc


# ---------------------------------------------------------------------------
# Document: load, diagnostics, formatter
# ---------------------------------------------------------------------------

_NO_DEFAULT = object()  # get_* sentinel: no call-site default -> must-exist (raises)


class _NameIndex:
	"""The first child of each (parent, name), chained on to the next same-named
	sibling, plus the chain tail so an append is O(1). The key is the exact
	(parent, name) tuple, the same deviation the parser's maps take (see
	_merge_key), so nothing but a same-named sibling can ever be on a chain;
	the lookup still checks the name, as the reference does over its hash."""
	__slots__ = ("first", "last", "next_same")

	def __init__(self, first, last, next_same):
		self.first = first            # (parent, name) -> first child
		self.last = last              # (parent, name) -> last child
		self.next_same = next_same    # per node; NIL ends the chain

	def append(self, key, node):
		if len(self.next_same) <= node:
			self.next_same.extend([NIL] * (node + 1 - len(self.next_same)))
		self.next_same[node] = NIL
		prev = self.last.get(key)
		self.last[key] = node
		if prev is not None:
			self.next_same[prev] = node
		else:
			self.first[key] = node

	# Walks the chain to find the predecessor; a chain is one name's siblings.
	def unlink(self, key, node):
		head = self.first.get(key)
		if head is None:
			return
		nxt = self.next_same[node]
		if head == node:
			if nxt == NIL:
				del self.first[key]
				del self.last[key]
			else:
				self.first[key] = nxt
		else:
			c = head
			while c != NIL and self.next_same[c] != node:
				c = self.next_same[c]
			if c == NIL:
				return
			self.next_same[c] = nxt
			if nxt == NIL:
				self.last[key] = c
		self.next_same[node] = NIL


def _name_key(parent, name):
	return (parent, name)


class _Emit:
	"""Canonical text on its way out, with a model of the level stack a reload
	of it will have at this point: the sentinel and one level per tab up to
	`open`, which the last binding line leaves, then what the lines refused
	since then pushed, and the indent of a kept misplaced line that the lines
	under it are kept with."""
	__slots__ = ("out", "open", "tail", "hold", "record", "fell", "verbatim", "near", "flushed", "kept_near", "lines", "marks", "bodies", "spans")

	def __init__(self, record):
		self.out: list[str] = []
		self.open = -1
		self.tail: list[tuple[str, int]] = []
		self.hold = None
		# _settle_kept() only: the lines written as comments, where they sit
		# and at what depth, and how many went out as written. Then the nodes
		# the lines since the last binding line came from, each with its place
		# in its parent's list, and those a kept line was modeled through.
		self.record = record
		self.fell: list[tuple[int, str, int, int]] = []
		self.verbatim = 0
		self.near: list[tuple[int, int]] = []
		self.flushed = 0
		self.kept_near: list[tuple[int, int]] = []
		# to_text_keep_lines() only: where the lines from each source line
		# start (0 for none), each raw body with the tabs its lines are padded
		# with, and where each value is spelled on its binding line. Positions
		# are indexes into `out`; _emit_marked() makes them offsets.
		self.lines = False
		self.marks: list[tuple[int, int]] = []
		self.bodies: list[tuple[int, int, int]] = []
		self.spans: list[tuple[int, int]] = []

	def mark(self, line):
		if self.lines:
			self.marks.append((len(self.out), line))

	def span(self, at):
		"""A value written from `at` to here, the space before it included."""
		if self.lines:
			self.spans.append((at, len(self.out)))

	def resolve(self, indent):
		"""A line at this indent through the reload's _resolve_parent(): the
		parent it finds, and the model as it leaves it, not yet taken."""
		levels = self.open + 2
		stack = [("", ROOT)]
		stack.extend(("\t" * d, ROOT) for d in range(levels - 1))
		stack.extend(self.tail)
		parent, cut, push = _locate_in(stack, indent)
		del stack[cut:]
		if push:
			stack.append((indent, UNOPENED))
		if len(stack) <= levels:
			return parent, len(stack) - 2, []
		return parent, self.open, stack[levels:]

	def refused(self, indent, open_, tail):
		"""Take a resolve, then the refusal's push: a refused line holds its
		own column unless it already sits there as a skipped line's."""
		self.open = open_
		self.tail = tail
		if not (tail and tail[-1] == (indent, UNOPENED)):
			tail.append((indent, DEAD))

	def placed(self, indent):
		"""A line a reload binds, such as a list element: it resolves, then
		holds its column with a live node."""
		_, self.open, self.tail = self.resolve(indent)
		self.tail.append((indent, ROOT))
		self.hold = None


def _commented(text):
	"""A misplaced line's text as the comment it falls back to."""
	return "# " + text[len(_leading_ws(text)):]


def _push_leads(e, leads, base, at):
	"""Write a run of comments and kept lines, `base` levels deep. A misplaced
	line kept as written (its text carries its own indent, a comment's never
	does) goes back as it was only where a reload keeps it again, which the
	model of the reload's stack answers the way the parser will: refused for
	its indent, or under the kept line before it. A merge or an edit can leave
	it where it would bind, and there it is written as a comment, which reads
	the same. `at` names the list and the index of its first line, for
	_settle_kept()."""
	out = e.out
	last_comment = 0
	for i, c in enumerate(leads):
		if c.blank_before and out:
			out.append("\n")
		# A kept line among list elements is part of the list's run.
		if at[1] != "among":
			e.mark(c.line)
		text = c.text
		if text.startswith((" ", "\t")):
			indent = _leading_ws(text)
			parent, open_, tail = e.resolve(indent)
			h = e.hold
			under = h is not None and len(indent) > len(h) and indent.startswith(h)
			if parent is None:
				keep = " " in indent
			elif parent == DEAD:
				keep = under
			else:
				keep = False
			if keep:
				if parent is None:
					e.hold = indent
				e.refused(indent, open_, tail)
				e.verbatim += 1
				if e.record:
					e.kept_near.extend(e.near[e.flushed:])
					e.flushed = len(e.near)
				out.append(text)
				out.append("\n")
			else:
				# Level with the comment before it, so the run's nesting reads
				# back the same.
				if e.record:
					e.fell.append((at[0], at[1], at[2] + i, last_comment))
				out.append("\t" * (base + last_comment))
				out.append(_commented(text))
				out.append("\n")
			continue
		pad = base + c.depth
		if text.startswith("#"):
			last_comment = c.depth
		else:
			# A kept malformed line resolves and holds its column on a reload.
			indent = "\t" * pad
			_, open_, tail = e.resolve(indent)
			e.hold = None
			e.refused(indent, open_, tail)
		out.append("\t" * pad)
		out.append(text)
		out.append("\n")


class _Marked:
	"""Canonical text with what the save that keeps lines needs to line it up
	against the source: _Emit's marks, bodies and spans as offsets."""
	__slots__ = ("text", "marks", "bodies", "starts", "spans")

	def __init__(self, text, marks, bodies, spans):
		self.text = text
		self.marks = marks
		self.bodies = bodies
		self.starts = [b[0] for b in bodies]
		self.spans = spans


class _Unit:
	"""A run of canonical lines from one source line on (0: from none), with
	the blank lines written before it and the spans of its values. As a group,
	`line` is the first source line of its runs and `parts` the runs."""
	__slots__ = ("line", "start", "end", "blanks", "spans", "parts")

	def __init__(self, line, start, end, blanks):
		self.line = line
		self.start = start
		self.end = end
		self.blanks = blanks
		self.spans = (0, 0)
		self.parts = (0, 0)


def _units_of(m):
	text = m.text
	marks, bodies = m.marks, m.bodies
	units: list[_Unit] = []
	mi = bi = tag = blanks = 0
	open_ = False
	pos = 0
	n = len(text)
	while pos < n:
		nxt = _line_end(text, pos)
		while mi < len(marks) and marks[mi][0] <= pos:
			tag = marks[mi][1]
			mi += 1
		while bi < len(bodies) and bodies[bi][1] <= pos:
			bi += 1
		in_body = bi < len(bodies) and bodies[bi][0] <= pos
		if text[pos] == "\n" and not in_body:
			blanks += 1
			open_ = False
		elif open_ and units and units[-1].line == tag:
			units[-1].end = nxt
		else:
			units.append(_Unit(tag, pos, nxt, blanks))
			blanks = 0
			open_ = True
		pos = nxt
	spans = m.spans
	si = 0
	for u in units:
		while si < len(spans) and spans[si][0] < u.start:
			si += 1
		frm = si
		while si < len(spans) and spans[si][0] < u.end:
			si += 1
		u.spans = (frm, si)
	for i, u in enumerate(units):
		u.parts = (i, i + 1)
	return units


def _group_units(units, owner):
	"""The runs one source line wrote, and every run between them, as one
	group, with a line inside a raw block or a stacked list counted as the
	binding line's. A comment the canonical form writes between a dotted
	line's block and its child sits inside such a group, and the group is kept
	or rewritten whole (20260925b item 2)."""
	def of(u):
		return owner[u.line] if u.line < len(owner) else u.line

	last = [0] * max(len(owner), max((u.line + 1 for u in units), default=0))
	for i, u in enumerate(units):
		last[of(u)] = i
	groups = []
	i = 0
	while i < len(units):
		j, line, k = i, 0, i
		while k <= j:
			o = of(units[k])
			if o != 0:
				j = max(j, last[o])
				line = o if line == 0 else min(line, o)
			k += 1
		g = _Unit(line, units[i].start, units[j].end, units[i].blanks)
		g.spans = (units[i].spans[0], units[j].spans[1])
		g.parts = (i, j + 1)
		groups.append(g)
		i = j + 1
	return groups


def _line_end(text, pos):
	"""Where the line starting at `pos` ends, past its newline."""
	i = text.find("\n", pos)
	return len(text) if i < 0 else i + 1


def _tabs(s, pos=0):
	k = pos
	while k < len(s) and s[k] == "\t":
		k += 1
	return k - pos


def _indent_for(indents, depth, step):
	"""The indent a new line `depth` levels down gets: the last one written
	there, or the nearest shallower one plus a level."""
	j = depth
	while j > 0 and (j >= len(indents) or indents[j] is None):
		j -= 1
	base = indents[j] if j < len(indents) and indents[j] is not None else ""
	return base + step * (depth - j)


def _resize(indents, n):
	if len(indents) > n:
		del indents[n:]
	else:
		indents.extend([None] * (n - len(indents)))


def _note_indent(indents, depth, indent):
	"""A source line written at `depth`. One whose indent does not nest under
	the level above it, a dotted path for one, says nothing about the levels
	after it."""
	if depth == 0:
		fits = indent == ""
	else:
		up = indents[depth - 1] if depth - 1 < len(indents) else None
		fits = indent != "" and (up is None or (len(indent) > len(up) and indent.startswith(up)))
	if fits:
		_resize(indents, depth + 1)
		indents[depth] = indent
	else:
		del indents[1:]


def _last_piece(out):
	return next((p for p in reversed(out) if p), "")


def _write_run(out, m, pos, end, indents, step, eol):
	"""A run the edits wrote, indented the way the lines around it are. A raw
	body keeps its own tabs past the pad, and a kept line its indent."""
	text = m.text
	while pos < end:
		nxt = _line_end(text, pos)
		line = text[pos:nxt - 1]
		b = bisect.bisect_right(m.starts, pos)
		if b > 0 and pos < m.bodies[b - 1][1]:
			pad = m.bodies[b - 1][2]
			if line:
				out.append(_indent_for(indents, pad, step))
				out.append(line[pad:])
		else:
			depth = _tabs(line)
			if line[depth:].startswith(" "):
				out.append(line)
			else:
				indent = _indent_for(indents, depth, step)
				out.append(indent)
				out.append(line[depth:])
				_resize(indents, depth + 1)
				indents[depth] = indent
		out.append(eol)
		pos = nxt


def _authored_head(src, canon):
	"""A binding line the edits rewrote, with the name spelled the way the
	source line spelled it. None unless both lines bind one plain name."""
	t = _trim_wsp_end(src[:-1] if src.endswith("\n") else src)
	ilen = len(t) - len(t.lstrip(" \t"))
	rest = t[ilen:].lstrip(_WSP)
	head = len(t) - len(rest)
	c = canon[_tabs(canon):]
	tok = Tokens()
	cut = []
	for text in (rest, c):
		if text.startswith(("#", "*")):
			return None
		tokenize(text, ":", False, Rules.CURRENT, tok)
		if len(tok.segments) != 1 or tok.segments[0].selector is not None or tok.fault is not None:
			return None
		if tok.sep is None:
			return None
		cut.append((tok.src, tok.sep))
	(sb, s0), (cb, s1) = cut
	return t[:head] + sb[:s0 + 1].decode("utf-8", "surrogatepass") + cb[s1 + 1:].decode("utf-8", "surrogatepass")


def _splice_value(line, was, w, now, u):
	"""A run whose only change is its last value, written into the source
	line in place of the old one, so the name, spacing and comment stay as
	they were. None when anything else changed or the line is not a plain
	field."""
	s0 = was.spans[w.spans[0]:w.spans[1]]
	s1 = now.spans[u.spans[0]:u.spans[1]]
	if not s0 or len(s0) != len(s1):
		return None
	t0, t1 = was.text, now.text
	p0, p1 = w.start, u.start
	for k, (a, b) in enumerate(zip(s0, s1)):
		if t0[p0:a[0]] != t1[p1:b[0]] or (k + 1 < len(s0) and t0[a[0]:a[1]] != t1[b[0]:b[1]]):
			return None
		p0, p1 = a[1], b[1]
	if t0[p0:w.end] != t1[p1:u.end]:
		return None
	last = s1[-1]
	value = t1[last[0]:last[1]]
	t = _trim_wsp_end(line[:-1] if line.endswith("\n") else line)
	tail = line[len(t):]
	ilen = len(t) - len(t.lstrip(" \t"))
	rest = t[ilen:].lstrip(_WSP)
	head = len(t) - len(rest)
	if rest.startswith(("#", "*")):
		return None
	tok = Tokens()
	tokenize(rest, ":", False, Rules.CURRENT, tok)
	colon = tok.sep
	if colon is None or tok.fault is not None:
		return None
	a, b = tok.value
	sb = tok.src
	if _fence_open(sb[a:b].decode("utf-8", "surrogatepass")) is not None or _bracket_text(tok):
		return None
	# The blanks after the colon stay as they were when there was a value and
	# still is one; the canonical value comes with one space.
	gap = ""
	if a == b:
		frm = colon + 1
	else:
		frm = b
		if value.startswith(" "):
			gap, value = sb[colon + 1:a].decode("utf-8", "surrogatepass"), value[1:]
	return (t[:head] + sb[:colon + 1].decode("utf-8", "surrogatepass") + gap + value
		+ sb[frm:].decode("utf-8", "surrogatepass") + tail)


def _splice_group(lines, was, wr, w, now, ur, u):
	"""_splice_value() for a group: the runs line up one for one and differ in
	one, the last its source line wrote, so the line's last value is its value.
	The line and its new text."""
	a, b = wr[w.parts[0]:w.parts[1]], ur[u.parts[0]:u.parts[1]]
	if len(a) != len(b):
		return None
	hit = None
	for k, (x, y) in enumerate(zip(a, b)):
		if x.line != y.line or x.blanks != y.blanks:
			return None
		if was.text[x.start:x.end] != now.text[y.start:y.end]:
			if hit is not None:
				return None
			hit = k
	if hit is None or any(x.line == a[hit].line for x in a[hit + 1:]):
		return None
	k = a[hit].line
	if not 1 <= k <= len(lines):
		return None
	t = _splice_value(lines[k - 1], was, a[hit], now, b[hit])
	return None if t is None else (k, t)


def _keep_lines(src, doc):
	"""to_text_keep_lines() on a loaded text: the loaded document's canonical
	runs line up with the text by the source line each came from, and the
	edited document's runs that match one exactly take that line's text.
	None when the result would not reload as `doc`."""
	no = -1
	# A text that was canonical keeps its lines as the canonical form.
	if not src:
		return doc.to_canonical()
	now = doc._emit_marked()
	p = _Parser()
	p.track_dropped = True
	loaded_doc = p.parse(src, doc._strictness)
	loaded = loaded_doc._emit_marked()
	if now.text == loaded.text:
		return src
	if src.startswith("\ufeff"):
		bom, body = "\ufeff", src[1:]
	else:
		bom, body = "", src
	parts = body.split("\n")
	lines = [p + "\n" for p in parts[:-1]]
	if parts[-1]:
		lines.append(parts[-1])
	n = len(lines)

	def line(k):
		return lines[k - 1]

	def blank(k):
		return not _trim_wsp(lines[k - 1].rstrip("\n"))

	def indent(k):
		t = lines[k - 1]
		return t[:len(t) - len(t.lstrip(" \t"))]

	# The lines each source line stands for: its own, through the end of a raw
	# block or a stacked list. Ranges that overlap, as a list taken up again
	# further down, run together, and each line in a run counts as the run's
	# first line, which stands for the whole run.
	own = list(range(n + 2))
	for k, e in loaded_doc._ends:
		if k <= n:
			own[k] = max(own[k], min(e, n))
	owner = list(range(n + 2))
	end = list(own)
	first = reach = 0
	for k in range(1, n + 1):
		if k <= reach:
			owner[k] = first
		else:
			first = k
		reach = max(reach, own[k])
		end[first] = reach
	was_runs, is_runs = _units_of(loaded), _units_of(now)
	was, is_ = _group_units(was_runs, owner), _group_units(is_runs, owner)
	# Each source line's group in the loaded text, and the lines it stands for,
	# through its last run's.
	at = [no] * (n + 2)
	for i, g in enumerate(was):
		if g.line != 0 and g.line <= n:
			at[g.line] = i
			for r in was_runs[g.parts[0]:g.parts[1]]:
				if r.line != 0 and r.line <= n:
					end[g.line] = max(end[g.line], end[owner[r.line]])
	claimed = [k for k in range(1, n + 1) if at[k] != no]
	# The first group after each one's lines, for telling two that sat next to
	# each other.
	nxt = [0] * (n + 2)
	for k in claimed:
		j = bisect.bisect_right(claimed, end[k])
		nxt[k] = claimed[j] if j < len(claimed) else n + 1
	# A line no group stands for, as a repeat the load folded away, goes out
	# only as it was written, between two kept groups or at either end. One
	# that is not blank and is left out makes the save fall back, since every
	# line no edit touched has to come back (20260925c item 1).
	left = [0 < k <= n and not blank(k) for k in range(n + 2)]
	for k in claimed:
		left[k:min(end[k], n) + 1] = [False] * (min(end[k], n) + 1 - k)
	eol = "\r\n" if n > 0 and line(1).endswith("\r\n") else "\n"
	# One level of the source's indent: a line one level in, or failing that
	# the first indented line, a list element or a fence.
	step = next((indent(u.line) for u in was_runs if u.line != 0 and u.line <= n and _tabs(loaded.text, u.start) == 1 and indent(u.line)), "")
	if not step:
		step = next((indent(k) for k in range(1, n + 1) if not blank(k) and indent(k)), "\t")
	out: list[str] = []

	def break_line():
		last_piece = _last_piece(out)
		if last_piece and not last_piece.endswith("\n"):
			out.append(eol)

	# Which source lines went out as written. Every line the load dropped has
	# to, or the save falls back: a rewritten group can span one, as a stacked
	# list over a refused element (20260926 item 1).
	wrote = [False] * (n + 2)

	# The lines no group stands for that sat right after a kept group, when the
	# group that followed it then does not follow it now. They go out before
	# the next source group, a new line not indented past them, or the end. A
	# new line indented past them goes first, since one written under a
	# dropped line would be dropped with it. A line the load dropped comes
	# back this way.
	def flush(frm, to):
		for g in range(frm, to):
			if left[g]:
				out.append(line(g))
				wrote[g] = True
				left[g] = False

	indents: list[str | None] = [""]
	# The line of the group just written while it is a source one, and the end
	# of the last source group met, kept or not.
	prev = reach = 0
	# The last kept group whose following lines are still to go out.
	owed = 0
	for i, u in enumerate(is_):
		k = u.line
		known = k != 0 and k <= n and at[k] != no
		if known:
			# The canonical form writes this above a source line that sat above
			# it: blocks folded together from two places, or a selector's child
			# under an earlier block. Keeping some of the lines would move the
			# others, so the save falls back.
			if k <= reach:
				return None
			reach = end[k]
		w = was[at[k]] if known else None
		same = w is not None and loaded.text[w.start:w.end] == now.text[u.start:u.end]
		spliced = _splice_group(lines, loaded, was_runs, w, now, is_runs, u) if w is not None and not same else None
		kept = same or spliced is not None
		# The blank lines above a group stay while it has a blank before it.
		# The canonical form can write that blank inside a kept group, as a
		# dotted line's child's, while the source has it above.
		blanks_stay = u.blanks > 0 or (kept and any(r.blanks > 0 for r in is_runs[u.parts[0] + 1:u.parts[1]]))
		# Between two groups that stay next to each other, the source's own
		# lines: a repeat the load folded away stays, and so do the blank lines.
		# The same before the first group. Before any other group from the
		# source, its own blank lines.
		break_line()
		depth = _tabs(now.text, u.start)
		if owed != 0:
			if known:
				due = not (kept and prev == owed and nxt[prev] == k)
			else:
				ind = _indent_for(indents, depth, step)
				g = next((g for g in range(end[owed] + 1, nxt[owed]) if left[g]), 0)
				due = g != 0 and (len(ind) <= len(indent(g)) or not ind.startswith(indent(g)))
			if due:
				flush(end[owed] + 1, nxt[owed])
				break_line()
				owed = 0
		if known:
			owed = 0
		if i == 0:
			if kept and claimed and claimed[0] == k:
				out.extend(lines[:k - 1])
				wrote[1:k] = [True] * (k - 1)
				left[1:k] = [False] * (k - 1)
		elif kept and prev != 0 and nxt[prev] == k:
			gap = range(end[prev] + 1, k)
			blanks = any(blank(g) for g in gap)
			for g in gap:
				if blanks_stay or not blank(g):
					out.append(line(g))
					wrote[g] = True
					left[g] = False
			if not blanks:
				out.extend([eol] * u.blanks)
		elif known and blanks_stay and k > 1 and blank(k - 1):
			g = k - 1
			while g > 1 and blank(g - 1):
				g -= 1
			out.extend(lines[g - 1:k - 1])
		else:
			out.extend([eol] * u.blanks)
		if kept:
			# A spliced line's value replaces the lines it took, as a stacked
			# list's elements.
			g = k
			while g <= end[k]:
				if spliced is not None and spliced[0] == g:
					out.append(spliced[1])
					g = own[g]
				else:
					out.append(line(g))
					wrote[g] = True
				g += 1
			# A line kept as written holds no level's indent.
			if w is not None and not now.text.startswith(" ", u.start + depth):
				_note_indent(indents, depth, indent(was_runs[w.parts[0]].line))
			prev = k
			owed = k
		else:
			# A binding the edits rewrote keeps its line's indent and name.
			frm = u.start
			if known and u.parts[1] - u.parts[0] == 1:
				first = _line_end(now.text, u.start)
				t = _authored_head(line(k), now.text[u.start:first - 1])
				if t is not None:
					out.append(t)
					out.append(eol)
					_note_indent(indents, depth, indent(k))
					frm = first
			_write_run(out, now, frm, u.end, indents, step, eol)
			prev = 0
	if owed != 0:
		break_line()
		flush(end[owed] + 1, n + 1)
	# The blank lines the source ends with stay at the end.
	break_line()
	tail = max((end[k] + 1 for k in claimed), default=1)
	if _last_piece(out) and all(blank(g) for g in range(tail, n + 1)):
		out.extend(lines[tail - 1:])
	if any(left) or not all(wrote[g] for g in loaded_doc._dropped):
		return None
	text = "".join(out)
	# So does a last line with no newline.
	if body and not body.endswith("\n") and text.endswith(eol):
		text = text[:-len(eol)]
	text = bom + text
	# The reload has to be the document, and it may not load with an error the
	# source did not have: a child the edits gave an element list that stayed
	# stacked reads back the same and is E001 (20260925b item 1). A line the
	# load dropped went out as written, and the reload has to drop each one
	# again: one that now binds, even to the same document, reads differently
	# from how the file had it.
	back = _Parser().parse(text, doc._strictness)
	if back._lost == loaded_doc._lost and back.to_canonical() == now.text and _errors_within(back, loaded_doc):
		return text
	return None


def _drop_banners(leads):
	"""Take each run of "##" lines holding the info block's SHCL line or a
	version line out of `leads`, all but a Schema line. Returns how many came
	off, whether the last
	one had a blank above it with no line after it to take that blank, and
	the lines left."""
	def is_block_line(t):
		return t == "## This config file format is SHCL." or t.startswith(FORMAT_LINE_HEAD)

	keep: list[_Lead] = []
	removed, owed = 0, False
	i = 0
	while i < len(leads):
		end = i + 1
		if leads[i].text.startswith("##"):
			while end < len(leads) and leads[end].text.startswith("##") and not leads[end].blank_before:
				end += 1
			if any(is_block_line(c.text) for c in leads[i:end]):
				# The blank that set the block off moves to whatever followed
				# it, so the lines around it stay apart. A Schema line in the
				# block is the author's and stays, with the blank.
				blank = leads[i].blank_before
				at = len(keep)
				keep.extend(c for c in leads[i:end] if c.text.startswith(SCHEMA_LINE_HEAD))
				if at < len(keep):
					keep[at].blank_before = blank
				elif end < len(leads):
					leads[end].blank_before = leads[end].blank_before or blank
				else:
					owed = blank
				removed += 1
				i = end
				continue
		keep.extend(leads[i:end])
		i = end
	if removed:
		# A reload puts a comment at most one level past the one before it,
		# and the first at none, so what followed a block steps up to that.
		room = 0
		for c in keep:
			if c.text.startswith("#"):
				c.depth = min(c.depth, room)
				room = c.depth + 1
	return removed, owed, (keep if removed else leads)


def _errors_within(d, of):
	"""Each error code `d` loads with, `of` loaded with at least as often."""
	def codes(doc):
		return sorted(x.code for x in doc.diags if x.severity == Severity.Error)

	mine, theirs = codes(d), codes(of)
	j = 0
	for c in mine:
		while j < len(theirs) and theirs[j] < c:
			j += 1
		if j == len(theirs) or theirs[j] != c:
			return False
		j += 1
	return True


class Document:
	"""A parsed SHCL document: the tree, its diagnostics, and its strictness level."""
	__slots__ = ("arena", "diags", "_strictness", "orphans", "_lost", "_index", "_probe", "_probe_doc", "_kept", "_kept_near", "_kept_sum", "_ends", "_dropped", "_source")

	def __init__(
		self,
		arena: list[_Node],
		diags: list[Diagnostic],
		strictness: Strictness,
		orphans: list[_Lead] | None = None,
		lost: int = 0,
	) -> None:
		self.arena = arena
		self.diags = diags
		self._strictness = strictness
		self.orphans = orphans if orphans is not None else []
		# Lines or values parsing dropped that canonical output cannot re-emit
		# (bad indentation, an unusable selector, past the depth cap, ...).
		# Content-malformed lines are NOT counted - they are retained as trivia
		# and survive a save. lost_count() serves it; save_file() gates on it.
		self._lost = lost
		# Built on the first path lookup and kept current by the writer (a new
		# child appends, a removed one unlinks); only a merge drops it. Without
		# it every lookup scans the parent's children, so a flat document read
		# or written key by key was quadratic.
		self._index: _NameIndex | None = None
		# Set only on the document a default form checks values against, never
		# on one a caller holds: _set_value stops once the value is judged, so a
		# probe is never written. Built on the first default form that finds its
		# path already there.
		self._probe = False
		self._probe_doc: Document | None = None
		# Holds a misplaced line kept as written, so edits have to settle it.
		self._kept = False
		# What the last settle's kept lines were modeled through, and a sum of
		# it, so an edit that changes none of it skips the settle. Removing a
		# block above all of it goes unseen, which leaves _kept set with no
		# such line left: the next check costs the same, and nothing is wrong.
		self._kept_near: list[tuple[int, int]] = []
		self._kept_sum: tuple = ()
		# The parse's multi-line bindings, from the binding line to the last
		# line each took. Edits leave it alone; only a reparse reads it.
		self._ends: list[tuple[int, int]] = []
		# Each line counted in _lost, once per count, when the parse was asked
		# for them. Only a reparse reads it.
		self._dropped: list[int] = []
		# The text a load kept for to_text_keep_lines(), and empty when that
		# text was already canonical, since the canonical form is then the one
		# that keeps its lines. A merge drops it: the layer's lines are not
		# this text's.
		self._source: str | None = None

	@staticmethod
	def parse(text: str) -> Document:
		"""Parse at Standard strictness. Never fails: bad lines are skipped and
		diagnosed, good values stay readable."""
		return _Parser().parse(text, Strictness.Standard)

	@staticmethod
	def parse_with(text: str, strictness: Strictness) -> Document:
		"""Parse at a chosen strictness. Only Strict can fail (any error
		diagnostic); the raised LoadError still carries the parsed document
		alongside the diagnostics."""
		doc = _Parser().parse(text, strictness)
		if strictness == Strictness.Strict and any(d.severity == Severity.Error for d in doc.diags):
			raise LoadError(list(doc.diags), doc)
		return doc

	@staticmethod
	def parse_limited(
		text: str, strictness: Strictness, max_nodes: int = 0, max_elements: int = 0, max_diags: int = 0
	) -> Document:
		"""Parse with resource caps beside the strictness, for input the
		consumer does not control: a document amplifies to many times its byte
		size in memory, so a size cap alone cannot bound what a load
		allocates. max_nodes stops the parse once a line takes the node count
		past it - one E020 error, and the unparsed remainder counts as lost so
		a save cannot silently truncate. max_elements refuses any line whose
		array would hold more elements (E021, that line alone is skipped).
		max_diags bounds the diagnostics list itself - a document of nothing
		but bad lines costs a diagnostic per line - by listing the first that
		many and ending with one E022 that counts the rest; error_count and
		the Strict gate see that tail as an error whenever an unlisted one
		was. 0 disables a cap, making this parse_with. The caps are parse-time
		only; the write API is the consumer's own arithmetic. As everywhere,
		the raised LoadError fires only at Strict, and a cap diagnostic is an
		error, so a capped Strict load fails; at other levels the parsed part
		stays readable."""
		p = _Parser()
		p.max_nodes = max_nodes
		p.max_elements = max_elements
		p.max_diags = max_diags
		doc = p.parse(text, strictness)
		if strictness == Strictness.Strict and any(d.severity == Severity.Error for d in doc.diags):
			raise LoadError(list(doc.diags), doc)
		return doc

	@staticmethod
	def load_file(path: str | os.PathLike[str]) -> tuple[Document, FileStatus]:
		"""File tier, load half: read and parse path at Standard. Never fails -
		the document always comes back usable (empty when the file could not be
		read), and the returned (document, FileStatus) pair separates the four
		cases consumers otherwise confuse: absent, present-but-unreadable,
		parsed with errors, clean."""
		return Document.load_file_with(path, Strictness.Standard)

	@staticmethod
	def load_file_with(path: str | os.PathLike[str], strictness: Strictness) -> tuple[Document, FileStatus]:
		"""load_file at a chosen strictness. A strict-failing file reports
		HadErrors; the recover-and-continue document still comes back."""
		text, st = read_file(path, 0)
		if text is None:
			return _Parser().parse("", strictness), st
		doc = _Parser().parse(text, strictness)
		if any(d.severity == Severity.Error for d in doc.diags):
			return doc, FileStatus.HadErrors
		return doc, FileStatus.Clean

	def save_file(self, path: str | os.PathLike[str]) -> None:
		"""File tier, save half: write this document's canonical text to path
		through a temp file in the same directory plus a rename, so an
		interrupted save can never truncate the config it rewrites - the same
		mechanics the CLI's --write uses. Refuses when parsing lost content that
		a save would silently delete (see lost_count); save_file_lossy writes
		anyway. Raises SaveRefused for the gate and SaveFailed for a failed
		write: returning the message instead would let the obvious spelling -
		the call on a line of its own - report success while doing nothing."""
		if self._lost > 0:
			raise SaveRefused(path, self._lost)
		err = write_file_atomic(path, self.to_canonical())
		if err is not None:
			raise SaveFailed(err)

	def save_file_lossy(self, path: str | os.PathLike[str]) -> None:
		"""save_file without the lost-content gate: writes even when parsing
		dropped lines this save deletes. The caller owns that choice. Never
		raises SaveRefused - the gate is the one thing it skips."""
		err = write_file_atomic(path, self.to_canonical())
		if err is not None:
			raise SaveFailed(err)

	def diagnostics(self) -> list[Diagnostic]:
		# A copy: the reference hands out a borrowed view nobody can append to,
		# and the document's own list would let a caller's edit and the
		# document's next append overwrite each other.
		return list(self.diags)

	def lost_count(self) -> int:
		"""How many lines or values parsing dropped that canonical output cannot
		re-emit - bad indentation, an unusable selector, a line past the depth
		cap. Content-malformed lines do NOT count: those are retained as trivia
		and survive a save. Nonzero means a save_file would delete hand-written
		content, so save_file refuses then (save_file_lossy overrides), and
		save_file_keep_lines does when it cannot keep the lines."""
		return self._lost

	def error_count(self) -> int:
		"""How many error-severity diagnostics the document carries - the "did
		this file have errors?" predicate, so recover-and-continue can't read
		as success by accident. Counts whatever diagnostics() holds (after
		load_and_validate, that includes validation errors)."""
		return sum(1 for d in self.diags if d.severity == Severity.Error)

	@staticmethod
	def load_and_validate(text: str, schema_text: str, strictness: Strictness) -> Document:
		"""One-shot load-and-validate: parse at a strictness, validate against a
		schema, and hand back the document carrying ONE combined diagnostics
		list (parse first, then validation - the order `check --schema`
		prints), so half the errors can't vanish because a caller forgot one
		of the two lists. Never fails: a strict-failing document comes back as
		the document plus its diagnostics (error_count() answers "did it
		fail"). An empty schema text skips validation entirely. H001 hints the
		schema disavows (a declared repeat upper bound above 1) are dropped."""
		doc = _Parser().parse(text, strictness)
		if _trim(schema_text):
			schema = Document.parse(schema_text)
			# A schema that did not load would silently drop the constraints on
			# its broken lines, or report every field as unknown - either way
			# blaming the document for the schema. Say so instead, as `check`
			# does, and validate nothing.
			if any(d.severity == Severity.Error for d in schema.diags):
				doc.diags.append(Diagnostic(0, Severity.Error, "schema failed to load", "V099"))
				return doc
			vdiags = doc.validate(schema)
			doc.diags.extend(vdiags)
			suppress_declared_repeats(schema, doc.diags)
			suppress_declared_reopens(schema, doc.diags)
		return doc

	def strictness(self) -> Strictness:
		return self._strictness

	# Formatter

	def to_canonical(self) -> str:
		"""Canonical form: block layout, tabs, insertion order, minimal quoting,
		redundancy collapsed, comments re-emitted as attached trivia. Scalar
		text is never rewritten."""
		e = _Emit(False)
		self._emit_all(e)
		return "".join(e.out)

	@staticmethod
	def parse_keep_lines(text: str, strictness: Strictness) -> Document:
		"""parse_with, keeping the text for to_text_keep_lines(). The document
		is the same one parse_with gives; only the save differs."""
		doc = _Parser().parse(text, strictness)
		doc._keep_source(text)
		if strictness == Strictness.Strict and any(d.severity == Severity.Error for d in doc.diags):
			raise LoadError(list(doc.diags), doc)
		return doc

	@staticmethod
	def load_file_keep_lines(path: str | os.PathLike[str], strictness: Strictness) -> tuple[Document, FileStatus]:
		"""load_file_with, keeping the text for to_text_keep_lines()."""
		text, st = read_file(path, 0)
		if text is None:
			return _Parser().parse("", strictness), st
		doc = _Parser().parse(text, strictness)
		doc._keep_source(text)
		if any(d.severity == Severity.Error for d in doc.diags):
			return doc, FileStatus.HadErrors
		return doc, FileStatus.Clean

	def _keep_source(self, text):
		self._source = "" if self.to_canonical() == text else text

	def to_text_keep_lines(self) -> tuple[str, bool]:
		"""The text a save that keeps lines writes, and whether it kept them.
		Each line the edits did not touch is the loaded text's own line, byte
		for byte; a changed value is written into its line; new lines are
		indented the way the lines around them are. The result has to reload
		as this document. When it does not, or the document was not loaded
		with parse_keep_lines or load_file_keep_lines, or it took a merge,
		this is to_canonical() and False."""
		if self._source is not None:
			t = _keep_lines(self._source, self)
			if t is not None:
				return t, True
		return self.to_canonical(), False

	def save_file_keep_lines(self, path: str | os.PathLike[str]) -> bool:
		"""save_file with to_text_keep_lines(): True when it kept the lines,
		False when it wrote the canonical form instead. A line the load dropped
		comes back as written when the lines are kept, so this refuses the way
		save_file does only when it would write canonical."""
		text, kept = self.to_text_keep_lines()
		if not kept and self._lost > 0:
			raise SaveRefused(path, self._lost)
		err = write_file_atomic(path, text)
		if err is not None:
			raise SaveFailed(err)
		return kept

	def _emit_marked(self):
		e = _Emit(False)
		e.lines = True
		self._emit_all(e)
		# Piece indexes to offsets in the joined text.
		offs = [0]
		for piece in e.out:
			offs.append(offs[-1] + len(piece))
		return _Marked(
			"".join(e.out),
			[(offs[at], line) for at, line in e.marks],
			[(offs[a], offs[b], pad) for a, b, pad in e.bodies],
			[(offs[a], offs[b]) for a, b in e.spans],
		)

	def _emit_all(self, e):
		# Explicit stack, children pushed in reverse: the reference handles depths
		# far past Python's recursion limit, so emit must not recurse.
		stack: list = []
		self._emit_children(self.arena[ROOT].children, 0, stack)
		while stack:
			idx, depth, would_merge, pos = stack.pop()
			if would_merge is None:
				# Post-children marker. Comments this block owns with no child
				# to carry them re-emit one deeper, then the ones that hung on
				# this block after its last child at the block's own depth.
				nd = self.arena[idx]
				if e.record:
					e.near.append((idx, pos))
				_push_leads(e, nd.inside(), depth + 1, (idx, "inside", 0))
				_push_leads(e, nd.after(), depth, (idx, "after", 0))
				continue
			self._emit_line(idx, pos, depth, would_merge, e)
			if e.record or self.arena[idx].after() or self.arena[idx].inside():
				# The marker sits under the children, so it pops after them.
				stack.append((idx, depth, None, pos))
			self._emit_children(self.arena[idx].children, depth + 1, stack)
		# Comments that never found a following line re-emit at the end.
		if e.record:
			e.near.append((ROOT, 0))
		_push_leads(e, self.orphans, 0, (ROOT, "orphans", 0))

	def _settle_kept(self):
		"""Make a misplaced line kept as written into the comment the emitter
		writes it as, wherever it would now bind as written, so the document is
		the one its saved text reloads as and the next edit comes out the same
		either way. One among a list's elements goes above the list, as a
		reload files a comment there. Runs after a load and after each edit,
		and only while the document holds such a line."""
		# A line moved out of a list can leave it written inline, which changes
		# what the lines after it sit under, so go again until nothing moves.
		while self._kept and self._settle_kept_once():
			pass
		if self._kept:
			self._kept_sum = self._near_sum()

	def _resettle_kept(self):
		"""After an edit. A kept line binds or not by the lines between it and
		the binding line above, so an edit that changed none of the nodes those
		came from cannot move it, and the whole-document emit is skipped
		(20260924d item 2)."""
		if self._kept and self._near_sum() != self._kept_sum:
			self._settle_kept()

	def _near_sum(self):
		"""Everything the emit model reads from the nodes in `_kept_near`: each
		one still at its place in its parent's list, its child count, its
		value's form and its comment lines. A kept line's parent chain needs no
		entry, since a binding line resets the model to its own depth. An exact
		tuple where the reference streams an FNV hash."""
		arena = self.arena
		parts: list[tuple] = []
		for n, pos in self._kept_near:
			nd = arena[n]
			if n == ROOT:
				parts.append((n, len(nd.children), tuple((c.depth, c.text) for c in self.orphans)))
				continue
			kids = arena[nd.parent].children if 0 <= nd.parent < len(arena) else ()
			v = nd.value
			t = nd.trivia
			parts.append((
				n, len(nd.children), pos < len(kids) and kids[pos] == n, _stacks(nd),
				v.kind, len(v.els) if v.kind == "cell" else 0,
				None if t is None else (
					tuple((c.depth, c.text) for c in t.leading),
					tuple((c.depth, c.text) for c in t.inside),
					tuple((c.depth, c.text) for c in t.after),
					tuple((b, c.depth, c.text) for b, c in t.among))))
		return tuple(parts)

	def _settle_kept_once(self):
		e = _Emit(True)
		self._emit_all(e)
		self._kept = e.verbatim > 0
		self._kept_near = e.kept_near
		among = []
		for node, site, i, depth in e.fell:
			if site == "among":
				among.append((node, i))
				continue
			if site == "orphans":
				lst = self.orphans
			else:
				t = self.arena[node]._triv()
				lst = t.leading if site == "leading" else t.inside if site == "inside" else t.after
			lead = lst[i]
			lead.text = _commented(lead.text)
			lead.depth = depth
			lead.kept = True
		# Out of each list latest first, so a removal leaves the earlier
		# indices alone, then onto the end of the leading lines in order.
		moved_any = bool(among)
		moved = []
		while among:
			node, i = among.pop()
			t = self.arena[node]._triv()
			moved.append(t.among.pop(i)[1])
			if among and among[-1][0] == node:
				continue
			depth = next((c.depth for c in reversed(t.leading) if c.text.startswith("#")), 0)
			for lead in reversed(moved):
				lead.text = _commented(lead.text)
				lead.depth = depth
				lead.line = 0
				lead.kept = True
				t.leading.append(lead)
			moved = []
		return moved_any

	def _emit_children(self, kids, depth, stack):
		"""Emit a sibling run. The parent walk already knows whether an earlier
		same-name sibling is empty (the raw same-line-fence hazard), so one
		seen-empties set here replaces a per-child rescan of the whole run.
		Iterative shape: the flags are computed per run and ride the stack."""
		entries = []
		empties = set()
		for pos, c in enumerate(kids):
			n = self.arena[c]
			wm = n.value.kind == "raw" and n.name in empties
			if n.value.is_empty():
				empties.add(n.name)
			entries.append((c, depth, wm, pos))
		stack.extend(reversed(entries))

	def _emit_line(self, idx, pos, depth, would_merge, e):
		node = self.arena[idx]
		if e.record:
			e.near.append((idx, pos))
		pad = "\t" * depth
		v = node.value
		# Same-line fence spelling can't carry an inline comment (an unbalanced
		# quote in the info-string could hide the `#` on reparse), so its
		# trailing comment joins the leading lines instead; the flag comes from
		# the parent's walk. Each blank rides its own comment (or the binding
		# line), never as the first output line.
		trailing = node.trailing()
		leading = node.leading()
		if leading:
			_push_leads(e, leading, depth, (idx, "leading", 0))
		out = e.out
		if node.blank_before and out:
			out.append("\n")
		e.mark(node.line)
		if would_merge and trailing:
			out.append(pad)
			out.append(trailing)
			out.append("\n")
		out.append(pad)
		out.append(_emit_name(node.name))
		out.append(":")
		# A binding line: a reload's stack is its levels and nothing else.
		e.open = depth
		if e.tail:
			e.tail = []
		e.hold = None
		if e.record:
			e.near = [(idx, pos)]
			e.flushed = 0
		if v.kind == "empty":
			e.span(len(out))
			if trailing:
				out.append("  ")
				out.append(trailing)
			out.append("\n")
		elif v.kind == "cell" and node.trivia is not None and _stacks(node):
			# Stacked, with the kept lines where they sat.
			if trailing:
				out.append("  ")
				out.append(trailing)
			out.append("\n")
			among = node.trivia.among
			column = "\t" * (depth + 1)
			nxt = 0
			for i, el in enumerate(v.els):
				while nxt < len(among) and among[nxt][0] <= i:
					_push_leads(e, (among[nxt][1],), depth + 1, (idx, "among", nxt))
					nxt += 1
				out.append(column)
				out.append("* ")
				out.append(_emit_element(el))
				out.append("\n")
				e.placed(column)
			while nxt < len(among):
				_push_leads(e, (among[nxt][1],), depth + 1, (idx, "among", nxt))
				nxt += 1
		elif v.kind == "cell":
			at = len(out)
			out.append(" ")
			out.append(_emit_cell(v.els))
			e.span(at)
			if trailing:
				out.append("  ")
				out.append(trailing)
			out.append("\n")
		else:
			# Child-indent spelling is canonical: bare name line, fenced block one
			# level deeper, verbatim content. Exception: if an earlier same-name
			# sibling is empty, the bare `name:` header would merge into it on
			# reparse and the fence would fill that instance instead - so use the
			# same-line spelling there.
			if would_merge:
				out.append(" ")
			else:
				if trailing:
					out.append("  ")
					out.append(trailing)
				out.append("\n")
			body_pad = "\t" * (depth + 1)
			fence = v.fence_char * v.fence_len
			if not would_merge:
				out.append(body_pad)
			out.append(_emit_fence_line(v))
			out.append("\n")
			body = len(out)
			if v.content:
				for ln in v.content.split("\n"):
					if ln:
						out.append(body_pad)
					out.append(ln)
					out.append("\n")
			if e.lines:
				e.bodies.append((body, len(out), depth + 1))
			out.append(body_pad)
			out.append(fence)
			out.append("\n")

	# Accessor: path resolution

	def _name_index(self):
		idx = self._index
		if idx is None:
			idx = _NameIndex({}, {}, [NIL] * len(self.arena))
			# From the root, not across the arena: a removed subtree's nodes are
			# still there with their child lists intact, so an arena walk
			# indexes every node the document ever held. Chains stay in file
			# order - a chain is one parent's same-named children, and each
			# parent's are appended in order.
			stack = [ROOT]
			while stack:
				p = stack.pop()
				for c in self.arena[p].children:
					idx.append(_name_key(p, self.arena[c].name), c)
					stack.append(c)
			self._index = idx
		return idx

	def _children_named(self, parent, name):
		idx = self._name_index()
		out = []
		c = idx.first.get(_name_key(parent, name), NIL)
		while c != NIL:
			if self.arena[c].name == name and self.arena[c].parent == parent:
				out.append(c)
			c = idx.next_same[c]
		return out

	def _resolve_from(self, start, segs, group=False):
		# Returns ("none",) | ("one", idx) | ("many", [idx]) | ("slots", [entry]).
		# A slots entry is a node idx, or the Status saying why the sub-path did
		# not land on one node (NotFound missing, Multiple ambiguous).
		# The per-instance sub-resolution behind a wildcard is the same walk
		# over the remaining segments, run flat (_resolve_slots) rather than one
		# frame per wildcard: a path can carry a wildcard per document level,
		# and the frame budget is small. A wildcard inside the sub-walk widens
		# the run rather than ending it, so the two compose.
		# group: a sub-path landing on several nodes joins the slot list instead
		# of becoming one Multiple slot. Reads want the slot per instance, so
		# they leave it off; remove and exists want every node behind the
		# wildcard.
		cur = list(start)
		for i, seg in enumerate(segs):
			nxt = []
			for node in cur:
				if seg.star:
					nxt.extend(self.arena[node].children)
				else:
					nxt.extend(self._children_named(node, seg.name))
			if seg.star:
				# Name wildcard: same per-slot split as `[*]`, over every child.
				rest = segs[i + 1:]
				slots = []
				for inst in nxt:
					if not rest:
						slots.append(inst)
					else:
						slots.extend(self._resolve_slots(inst, rest, group))
				return ("slots", slots)
			sel = seg.selector
			if sel is None:
				cur = nxt
			elif sel[0] == "val":
				want = sel[1]
				cur = [c for c in nxt if _disp_key(self.arena[c].value) == want and (not sel[2] or _single_scalar(self.arena[c].value))]
			elif sel[0] == "idx":
				k = sel[1]
				cur = [nxt[k]] if k < len(nxt) else []
			else:
				# Wildcard: remaining path resolves per-instance; slots stay aligned.
				rest = segs[i + 1:]
				slots = []
				for inst in nxt:
					if not rest:
						slots.append(inst)
					else:
						slots.extend(self._resolve_slots(inst, rest, group))
				return ("slots", slots)
		if len(cur) == 0:
			return ("none",)
		if len(cur) == 1:
			return ("one", cur[0])
		return ("many", cur)

	def _resolve_slots(self, inst, rest, group=False):
		# The slots one wildcard instance contributes: normally one - a node
		# index, or the Status saying why the sub-path did not land on one node
		# (NotFound missing, Multiple ambiguous) - but a further wildcard in
		# `rest` contributes its own slots to the same flat run. Walked with an
		# explicit stack rather than one frame per wildcard: a path can carry a
		# wildcard per document level, and the frame budget is small. The stack
		# is depth-first with children pushed in reverse, so slots come out in
		# file order.
		out = []
		stack = [([inst], rest)]
		while stack:
			cur, segs = stack.pop()
			split = False
			for i, seg in enumerate(segs):
				sel = seg.selector
				nxt = []
				for node in cur:
					if seg.star:
						nxt.extend(self.arena[node].children)
					else:
						nxt.extend(self._children_named(node, seg.name))
				if seg.star or (sel is not None and sel[0] == "wild"):
					tail = segs[i + 1:]
					if not tail:
						out.extend(nxt)
					else:
						stack.extend(([c], tail) for c in reversed(nxt))
					split = True
					break
				if sel is None:
					cur = nxt
				elif sel[0] == "val":
					want = sel[1]
					cur = [c for c in nxt if _disp_key(self.arena[c].value) == want and (not sel[2] or _single_scalar(self.arena[c].value))]
				else:
					k = sel[1]
					cur = [nxt[k]] if k < len(nxt) else []
			if split:
				continue
			if len(cur) == 0:
				out.append(Status.NotFound)
			elif len(cur) == 1:
				out.append(cur[0])
			elif group:
				out.extend(cur)
			else:
				out.append(Status.Multiple)
		return out

	def _resolve(self, path, group=False):
		# Returns a _resolve_from result, or ("err", Status). group puts every
		# node behind a wildcard slot in the list, for the callers that act on
		# the whole match rather than read one value per instance.
		try:
			segments, value_text = _scan_lookup(path)
		except _PathError:
			return ("err", Status.NotFound)
		if value_text is not None:
			return ("err", Status.NotFound)   # a query has no value part
		return self._resolve_from([ROOT], segments, group)

	def count(self, path: str) -> int:
		"""Instance count at a path (0 when nothing matches)."""
		r = self._resolve(path)
		tag = r[0]
		if tag == "one":
			return 1
		if tag == "many" or tag == "slots":
			return len(r[1])
		return 0

	def paths(self) -> list[str]:
		"""Every field path in the document, in file order, deduplicated - a
		query recipe for tooling. A segment that is not bare-name-safe is
		emitted quoted and escaped - the form the path scanner accepts - so
		each path is a well-formed lookup path and nothing in the document is
		hidden."""
		out = []
		seen = set()
		stack = [(c, "") for c in reversed(self.arena[ROOT].children)]
		while stack:
			node, prefix = stack.pop()
			seg = _emit_name(self.arena[node].name)
			path = seg if not prefix else prefix + "." + seg
			if path not in seen:
				seen.add(path)
				out.append(path)
			stack.extend((c, path) for c in reversed(self.arena[node].children))
		return out

	def line(self, path: str) -> int:
		"""1-based source line of the binding at a path, for consumer checks the
		schema cannot express. 0 when the path does not resolve to exactly one
		node, or the node was writer-built. Merged instances cite the first
		binding's line, matching diagnostics."""
		r = self._resolve(path)
		if r[0] == "one":
			return self.arena[r[1]].line
		return 0

	def authored_name(self, path: str) -> str:
		"""The field name at a path exactly as the author spelled it (case
		unfolded, outer quotes stripped), so a message can echo `SYMBOLS` when
		the file said SYMBOLS. Escape sequences stay as written too: a name is
		stored, compared and emitted with its escapes RESOLVED, so this is the
		one call that hands the source spelling back - which is what an
		as-authored accessor is for. Resolution mirrors line(): empty when the path
		does not resolve to exactly one node. Merged instances keep the first
		binding's spelling; a writer-built node keeps the spelling the setter's
		path used."""
		r = self._resolve(path)
		if r[0] == "one":
			return self.arena[r[1]].name_src
		return ""

	def lines(self, path: str) -> list[int]:
		"""The plural line(): 1-based source lines at a path, in file order, so
		a repeated field - the case that most wants a citable line - yields
		every binding's. Wildcard slots that did not resolve stay in the list
		as 0, and a writer-built node is 0, so indices keep matching count()."""
		r = self._resolve(path)
		tag = r[0]
		if tag == "one":
			return [self.arena[r[1]].line]
		if tag == "many":
			return [self.arena[n].line for n in r[1]]
		if tag == "slots":
			return [self.arena[n].line if isinstance(n, int) else 0
				for n in r[1]]
		return []

	def children(self, path: str) -> list[str]:
		"""Child field names under a path, in file order, duplicates included -
		the "what keys are in this section?" question paths() (deduplicated,
		path-shaped) cannot answer. "" enumerates the top level. A path with
		several instances lists the children of each in turn, the way a dotted
		path reaches all of them. Names come back as stored; quote_segment()
		makes one splice-safe in a path."""
		if not _trim(path):
			nodes = [ROOT]
		else:
			r = self._resolve(path)
			tag = r[0]
			if tag == "one":
				nodes = [r[1]]
			elif tag == "many":
				nodes = r[1]
			elif tag == "slots":
				nodes = [n for n in r[1] if isinstance(n, int)]
			else:
				return []
		return [self.arena[c].name for n in nodes for c in self.arena[n].children]

	def instance_paths(self) -> list[str]:
		"""paths() one instance at a time: every binding's path in file order,
		with `[#i]` on each segment whose name repeats under its parent, so
		each path reads exactly one node and a repeated block is walked
		instance by instance. Segments are spelled as paths() spells them."""
		out: list[str] = []
		stack = [(ROOT, "")]
		while stack:
			node, prefix = stack.pop()
			if node != ROOT:
				out.append(prefix)
			kids = self.arena[node].children
			total: dict[str, int] = {}
			for c in kids:
				name = self.arena[c].name
				total[name] = total.get(name, 0) + 1
			at: dict[str, int] = {}
			paths = []
			for c in kids:
				name = self.arena[c].name
				seg = _emit_name(name)
				path = seg if not prefix else prefix + "." + seg
				if total[name] > 1:
					i = at.get(name, 0)
					path += f"[#{i}]"
					at[name] = i + 1
				paths.append((c, path))
			stack.extend(reversed(paths))
		return out

	def instances(self, path: str) -> list[str]:
		"""Instance values at a path, in file order. Wildcard slots that did not
		resolve stay in the list as "" so indices keep matching count()."""
		r = self._resolve(path)
		tag = r[0]
		if tag == "one":
			return [self.arena[r[1]].value.display()]
		if tag == "many":
			return [self.arena[n].value.display() for n in r[1]]
		if tag == "slots":
			return [self.arena[n].value.display() if isinstance(n, int) else ""
				for n in r[1]]
		return []

	# Writer: typed emit, defaults, comments, structural edits
	# The reverse of the Accessor. A setter builds the canonical stored text for a
	# typed value (the inverse of the matching read) and places it at a path,
	# creating intermediate nodes on the way. Reads and to_canonical walk the
	# children lists, so mutating the arena directly is enough.

	@staticmethod
	def new() -> Document:
		"""A fresh document with no bindings - the start point for schema-driven
		generation. Set values, then to_canonical()."""
		return Document.parse("")

	def _new_child(self, parent, name, name_src, value):
		# A list written stacked would get the child after its elements, which
		# reloads as E001, so it goes inline.
		if _stacks(self.arena[parent]):
			_unstack(self.arena[parent])
		idx = len(self.arena)
		node = _Node(name, value, parent, 0, name_src)
		# Hand-written files separate top-level sections with a blank line;
		# writer-built ones do the same (the emitter never blanks line 1).
		node.blank_before = parent == ROOT
		self.arena.append(node)
		self.arena[parent].children.append(idx)
		if self._index is not None:
			self._index.append(_name_key(parent, name), idx)
		_settle_block(self.arena, parent, len(self.arena[parent].children) - 1)
		return idx

	def write_reason(self, path: str) -> WriteReason:
		"""Why a write at this path would fail - the reason behind a setter's
		bare False, so a consumer's error message need not guess. Writable means
		the same validation _place() runs would pass; nothing is created."""
		try:
			segments, value_text = _scan_lookup(path)
		except _PathError:
			return WriteReason.BadPath
		return self._probe_write(segments, value_text)[0]

	def _probe_write(self, segments, value_text, trail=None) -> tuple[WriteReason, list | None]:
		"""The validation walk write_reason and _place share. `trail`, when a
		list is passed, collects where each segment landed - None from the point
		the path falls off the existing tree - so _place can create from exactly
		there instead of scanning the path and walking the tree a second time."""
		if value_text is not None:
			return (WriteReason.ValueInPath, None)
		if not segments:
			return (WriteReason.BadPath, None)
		# Writer side of the load-time nesting cap: never create deeper.
		if len(segments) > MAX_DEPTH:
			return (WriteReason.TooDeep, None)
		# The probe walk _place() validates with: once it falls off the existing
		# tree, a later `[#k]` can never match (fresh intermediates are created
		# childless), so an index segment past that point is unresolvable.
		probe = ROOT
		for seg in segments:
			if seg.star:
				return (WriteReason.Wildcard, None)
			sel = seg.selector
			if sel is not None and sel[0] == "wild":
				return (WriteReason.Wildcard, None)
			if sel is not None and sel[0] == "idx":
				if probe is None:
					return (WriteReason.NoSuchIndex, None)
				matches = self._children_named(probe, seg.name)
				if sel[1] >= len(matches):
					return (WriteReason.NoSuchIndex, None)
				probe = matches[sel[1]]
			elif sel is not None and sel[0] == "val":
				if probe is not None:
					want = sel[1]
					found = None
					for c in self._children_named(probe, seg.name):
						if _disp_key(self.arena[c].value) == want and (not sel[2] or _single_scalar(self.arena[c].value)):
							found = c
							break
					probe = found
			else:
				if probe is not None:
					matches = self._children_named(probe, seg.name)
					probe = matches[0] if matches else None
			if trail is not None:
				trail.append(probe)
		return (WriteReason.Writable, trail)

	def _place(self, path):
		"""Walk (creating as needed) to the node a write targets. A trailing
		name with no selector hits the first same-named instance (or a new one);
		a `[value]` selector selects the matching instance or creates it; `[#k]`
		must already exist. None = path unusable for a write (write_reason()
		says why). Validation runs first, so a doomed path leaves no
		half-created intermediates behind."""
		try:
			segments, value_text = _scan_lookup(path)
		except _PathError:
			return None
		trail: list = []
		if self._probe_write(segments, value_text, trail)[0] != WriteReason.Writable:
			return None
		# Nothing is created until every segment the write would create is known
		# to spell back: the name through the name escaper, an instance selector
		# as the value it binds.
		for i, seg in enumerate(segments):
			if trail[i] is not None:
				continue
			if not _name_reads_back(seg.name):
				return None
			sel = seg.selector
			if sel is not None and sel[0] == "val" and not _value_reads_back(_cell_of(sel[1])):
				return None
		cur = ROOT
		for i, seg in enumerate(segments):
			# The probe already resolved every segment that exists; only the
			# tail it fell off has anything to create.
			if trail[i] is not None:
				cur = trail[i]
				continue
			sel = seg.selector
			if sel is None:
				cur = self._new_child(cur, seg.name, seg.name_src, _empty())
			elif sel[0] == "val":
				cur = self._new_child(cur, seg.name, seg.name_src, _cell_of(sel[1]))
			else:
				# Unreachable: _probe_write refuses a wildcard outright and an
				# unresolvable index, so neither reaches an empty trail slot.
				return None
		return cur

	def _set_value(self, path: str, value) -> bool:
		if not _value_reads_back(value):
			return False
		if self._probe:
			return True
		idx = self._place(path)
		if idx is None:
			return False
		self.arena[idx].value = value
		self.arena[idx].src = None   # written value has no source spelling
		# No longer the list the lines among its elements sat in.
		_unstack(self.arena[idx])
		# An empty binding or a raw block can put a fence after an empty
		# sibling of its name.
		fence_side = value.kind == "raw" or value.is_empty()
		parent, name = self.arena[idx].parent, self.arena[idx].name
		self._collapse_dup(idx)
		if fence_side:
			self._settle_fence_name(parent, name)
		_settle_first_blank(self.arena, self.orphans)
		self._resettle_kept()
		return True

	def _collapse_dup(self, node):
		# A written value may now collide with a same-named sibling under the
		# in-file merge rule; fold the pair the way a reparse would (earlier
		# sibling survives, later one folds children and trivia in) so Writer
		# output stays a formatter fixpoint.
		parent = self.arena[node].parent
		me = self.arena[node]
		key = _merge_key(me.name, me.value)
		other = None
		for c in self._children_named(parent, me.name):
			o = self.arena[c]
			if c != node and _merge_key(o.name, o.value) == key:
				other = c
				break
		if other is None:
			return
		siblings = self.arena[parent].children
		if siblings.index(other) < siblings.index(node):
			survivor, loser = other, node
		else:
			survivor, loser = node, other
		moved = list(self.arena[loser].children)
		_fold_node_into(self.arena, survivor, loser)
		self.arena[parent].children = [c for c in self.arena[parent].children if c != loser]
		_settle_block(self.arena, parent, 1)
		ix = self._index
		if ix is not None:
			ix.unlink(_name_key(parent, self.arena[loser].name), loser)
			for k in moved:
				name = self.arena[k].name
				ix.unlink(_name_key(loser, name), k)
				ix.append(_name_key(survivor, name), k)
		self._fold_dups_below(survivor)

	def _settle_fence_name(self, parent, name):
		"""The write-side twin of _settle_fence_trailing: only the written name's
		instances can change, and walking them off the index keeps a write off
		the rest of the block."""
		seen_empty = False
		for c in self._children_named(parent, name):
			nd = self.arena[c]
			t = nd.trivia
			if seen_empty and nd.value.kind == "raw" and t is not None and t.trailing:
				_trailing_to_leading(nd)
			elif seen_empty and _stacks(nd):
				_unstack(nd)
			elif nd.value.is_empty():
				seen_empty = True

	def _fold_dups_below(self, start):
		"""Folding moves the loser's children up a level, where they can collide
		with the survivor's own. The parser's fold is depth-first for the same
		reason; only a node that just received children can hold a new pair."""
		stack = [start]
		while stack:
			parent = stack.pop()
			kids = self.arena[parent].children
			first: dict = {}
			keep = []
			for c in kids:
				key = _merge_key(self.arena[c].name, self.arena[c].value)
				survivor = first.get(key)
				if survivor is not None:
					moved = list(self.arena[c].children)
					_fold_node_into(self.arena, survivor, c)
					ix = self._index
					if ix is not None:
						ix.unlink(_name_key(parent, self.arena[c].name), c)
						for k in moved:
							name = self.arena[k].name
							ix.unlink(_name_key(c, name), k)
							ix.append(_name_key(survivor, name), k)
					stack.append(survivor)
				else:
					first[key] = c
					keep.append(c)
			self.arena[parent].children = keep
			_settle_block(self.arena, parent, 1)

	def exists(self, path: str) -> bool:
		"""True when the path resolves to at least one real node."""
		r = self._resolve(path, True)
		tag = r[0]
		if tag == "one" or tag == "many":
			return True
		if tag == "slots":
			return any(isinstance(n, int) for n in r[1])
		return False

	def remove(self, path: str) -> int:
		"""Delete the node(s) at a path (with their subtrees); returns how many.

		A removed node's storage is not reclaimed, so a process that adds and removes in a loop grows by a few hundred bytes a pair. Reloading the canonical text gives it back.
		"""
		r = self._resolve(path, True)
		tag = r[0]
		if tag == "one":
			targets = [r[1]]
		elif tag == "many":
			targets = list(r[1])
		elif tag == "slots":
			targets = [n for n in r[1] if isinstance(n, int)]
		else:
			targets = []
		# Mark first, rebuild each touched child list once. Dropping one target
		# at a time rebuilt the same list once per target, which is quadratic
		# when a path matches many siblings.
		pairs: list[tuple[int, int]] = []
		for t in targets:
			p = self.arena[t].parent
			# A node already marked would carry DEAD into the rebuild below as
			# an index, so skip it rather than trust resolve never to name one
			# twice.
			if p == DEAD:
				continue
			if self._index is not None:
				self._index.unlink(_name_key(p, self.arena[t].name), t)
			self.arena[t].parent = DEAD
			pairs.append((t, p))
		# Rebuilding a list puts back the parent of every node it drops, so a
		# mark still standing is also the answer to "has this parent been done
		# yet" - no separate pass to dedupe the parents.
		for t, p in pairs:
			if self.arena[t].parent != DEAD:
				continue
			keep: list[int] = []
			for c in self.arena[p].children:
				if self.arena[c].parent == DEAD:
					self.arena[c].parent = p
				else:
					keep.append(c)
			self.arena[p].children = keep
		_settle_first_blank(self.arena, self.orphans)
		self._resettle_kept()
		return len(targets)

	def set_comment(self, path: str, text: str) -> bool:
		"""Attach a leading comment line to the node at a path (creating an empty
		node if absent). A missing '#' is added, and trailing whitespace comes
		off the way the load takes it, so text that is blank leaves a bare '#'.
		Text holding a line break is refused: a comment is one line, and keeping
		only the first would drop the rest with nothing to say so."""
		_want("set_comment", text, "str")
		c = _comment_line(text)
		if c is None:
			return False
		idx = self._place(path)
		if idx is None:
			return False
		# The node's own blank moves above its first comment; otherwise the
		# blank would separate the comment from what it annotates. Above the
		# first one already there, when there is one.
		nd = self.arena[idx]
		lead = _Lead(c, False)
		t = nd._triv()
		if nd.blank_before:
			nd.blank_before = False
			if t.leading:
				t.leading[0].blank_before = True
			else:
				lead.blank_before = True
		t.leading.append(lead)
		_settle_first_blank(self.arena, self.orphans)
		self._resettle_kept()
		return True

	def comments(self, path: str) -> list[str]:
		"""The comment lines above the node(s) at a path, the ones
		clear_comments takes, in file order, each from its "#" on. A program
		can tell its own comment from one a user wrote there, and set_comment
		puts a line it gave back as it was. Empty when the path reaches
		nothing."""
		r = self._resolve(path, True)
		tag = r[0]
		if tag == "one":
			targets = [r[1]]
		elif tag == "many":
			targets = list(r[1])
		elif tag == "slots":
			targets = [n for n in r[1] if isinstance(n, int)]
		else:
			targets = []
		return [c.text for t in targets if (tr := self.arena[t].trivia) is not None for c in tr.leading if c.is_comment()]

	def clear_comments(self, path: str) -> int:
		"""Take off the comment lines above the node(s) at a path, the lines
		set_comment adds to, so a program can replace a comment rather than
		stack another one on it. Which lines those are is where the load put
		them: everything between the node and the binding line before it, so a
		heading written for a group of fields goes too. A comment on the node's
		own line stays, and so does a line kept as written for being malformed.
		Returns how many lines came off, 0 when the path reaches nothing."""
		r = self._resolve(path, True)
		tag = r[0]
		if tag == "one":
			targets = [r[1]]
		elif tag == "many":
			targets = list(r[1])
		elif tag == "slots":
			targets = [n for n in r[1] if isinstance(n, int)]
		else:
			targets = []
		cleared = 0
		for t in targets:
			nd = self.arena[t]
			tr = nd.trivia
			if tr is None:
				continue
			before = len(tr.leading)
			# The blank above the run is the one that separates it from what
			# comes before, so it stays with whatever is now first.
			blank = before > 0 and tr.leading[0].blank_before
			tr.leading = [c for c in tr.leading if not c.is_comment()]
			gone = before - len(tr.leading)
			if gone == 0:
				continue
			cleared += gone
			# A kept line left in the run may have sat under a comment that
			# went. A reload starts a run at 0 and steps one at a time.
			room = 0
			for c in tr.leading:
				if c.text.startswith("#"):
					c.depth = min(c.depth, room)
					room = c.depth + 1
			if tr.leading:
				tr.leading[0].blank_before = tr.leading[0].blank_before or blank
			else:
				nd.blank_before = nd.blank_before or blank
		if cleared:
			_settle_first_blank(self.arena, self.orphans)
			self._resettle_kept()
		return cleared

	def set_banner(self, on: bool) -> int:
		"""Put the info block (GEN_BANNER) at the end of the document, or with
		on False just take it off. An old block comes off first, found by its
		"This config file format is SHCL." line or its version line, never by
		its links or Legal line, which a later release may spell differently.
		A version line migrate stamped counts too. A block is a run of "##"
		lines with no blank inside, so a "##" comment of the file's own,
		written right against it, goes with it. It is looked for in the footer
		and above every field but the first one and its first child down,
		since a field added below it by hand takes it as its comment. A block
		at the top of the file is left alone. A dotted first line hangs it on
		its last name, which a saved file writes as the first field's first
		child, so a block there is left alone too, however it got there. The
		library save never adds the block by itself; this is for a program
		that wants it in a file it writes. Returns how many old blocks came
		off."""
		_want("set_banner", on, "bool")
		removed = 0
		# The first line's comments are the top of the file, on the first node
		# down, as a dotted line puts them on its last name.
		top = []
		n = ROOT
		while self.arena[n].children:
			n = self.arena[n].children[0]
			top.append(n)
		stack = list(self.arena[ROOT].children)
		while stack:
			n = stack.pop()
			nd = self.arena[n]
			stack.extend(nd.children)
			if n in top or nd.trivia is None:
				continue
			gone, blank, nd.trivia.leading = _drop_banners(nd.trivia.leading)
			if gone:
				removed += gone
				nd.blank_before = nd.blank_before or blank
		gone, _, keep = _drop_banners(self.orphans)
		removed += gone
		self.orphans = keep
		if on:
			open_ = bool(keep) or bool(self.arena[ROOT].children)
			for n, line in enumerate(GEN_BANNER.rstrip("\n").split("\n")):
				keep.append(_Lead(line, n == 0 and open_))
		_settle_first_blank(self.arena, self.orphans)
		self._resettle_kept()
		return removed

	def set_int(self, path: str, v: int) -> bool:
		"""Bind an integer at path, creating the path as needed; False = path not
		writable (write_reason says why - same for every setter). Worth checking
		rather than assuming: an ignored False means the save that follows writes
		a document missing the edit, and reports success doing it. A value of
		the wrong type is a TypeError (same for every typed setter): int here,
		and a bool is not one."""
		_want("set_int", v, "int")
		if not _fits_i64(v):
			return False
		return self._set_value(path, _cell_of(str(v)))

	def set_float(self, path: str, v: float) -> bool:
		"""Bind a float; an int is accepted and written as the float it converts
		to, a bool is a TypeError. An infinity or a NaN (one past the float
		range included) has no spelling the reader accepts, so it fails the
		write rather than binding a value that cannot read back."""
		_want("set_float", v, "float")
		x = _as_float(v)
		if not math.isfinite(x):
			return False
		return self._set_value(path, _cell_of(format_float(x)))

	def set_bool(self, path: str, v: bool) -> bool:
		"""Bind a bool; anything else, 0/1 included, is a TypeError."""
		_want("set_bool", v, "bool")
		return self._set_value(path, _cell_of("true" if v else "false"))

	def set_string(self, path: str, v: str) -> bool:
		"""Bind a string; a non-str is a TypeError."""
		_want("set_string", v, "str")
		return self._set_value(path, _cell_of(v))

	def set_datetime(self, path: str, v: ShclDateTime) -> bool:
		"""Bind a ShclDateTime; anything else is a TypeError. Its fields carry
		no invariant, so a value the reader would refuse (month 13, a fraction
		with no seconds, an empty one) fails the write rather than binding
		text that cannot read back."""
		_want("set_datetime", v, "datetime")
		if not _datetime_reads_back(v):
			return False
		return self._set_value(path, _cell_of(str(v)))

	def set_raw(self, path: str, content: str, info: str) -> bool:
		"""Bind a raw block at a path, picking a fence longer than any content
		line. The info-string is stored as a fence line would read it back
		(trimmed the way the load trims one); one that would not read back whole
		- it holds a line break, or a `#`, which reads as a comment - fails the
		write, as does a body line ending in CR, since the load takes the
		trailing CR run off every line."""
		_want("set_raw", content, "str")
		_want("set_raw", info, "str")
		info = _trim_wsp(info)
		fc, fl = _choose_fence(content)
		return self._set_value(path, _raw(content, info, fc, fl))

	def set_empty(self, path: str) -> bool:
		return self._set_value(path, _empty())

	def set_int_array(self, path: str, v: list[int]) -> bool:
		"""Bind an inline int array; every element is checked as set_int does."""
		v = _want_all("set_int_array", v, "int")
		if not all(_fits_i64(x) for x in v):
			return False
		return self._set_value(path, _array_cell([str(x) for x in v]))

	def set_float_array(self, path: str, v: list[float]) -> bool:
		"""Bind an inline float array; every element is converted as set_float does."""
		v = _want_all("set_float_array", v, "float")
		xs = [_as_float(x) for x in v]
		if not all(math.isfinite(x) for x in xs):
			return False
		return self._set_value(path, _array_cell([format_float(x) for x in xs]))

	def set_bool_array(self, path: str, v: list[bool]) -> bool:
		v = _want_all("set_bool_array", v, "bool")
		return self._set_value(path, _array_cell(["true" if x else "false" for x in v]))

	def set_string_array(self, path: str, v: list[str]) -> bool:
		v = _want_all("set_string_array", v, "str")
		return self._set_value(path, _array_cell(list(v)))

	def set_datetime_array(self, path: str, v: list[ShclDateTime]) -> bool:
		v = _want_all("set_datetime_array", v, "datetime")
		if not all(_datetime_reads_back(x) for x in v):
			return False
		return self._set_value(path, _array_cell([str(x) for x in v]))

	# Default (only-if-absent) forms - the "emit defaults" half of the Writer.
	# The type gate runs whether or not the path exists, so a wrong-typed call
	# fails the same way on every document. A path that already resolves writes
	# nothing and reports what a write there would: the path's verdict, so a
	# wildcard is refused whether or not its slots happen to resolve, and the
	# value's, which the same setter gives on the probe document.
	def _set_default(self, path: str, set_: Callable[[Document, str], bool]) -> bool:
		if not self.exists(path):
			return set_(self, path)
		if self.write_reason(path) != WriteReason.Writable:
			return False
		if self._probe_doc is None:
			self._probe_doc = Document.new()
			self._probe_doc._probe = True
		return set_(self._probe_doc, "v")

	def set_int_default(self, path: str, v: int) -> bool:
		_want("set_int_default", v, "int")
		return self._set_default(path, lambda d, p: d.set_int(p, v))

	def set_float_default(self, path: str, v: float) -> bool:
		_want("set_float_default", v, "float")
		return self._set_default(path, lambda d, p: d.set_float(p, v))

	def set_bool_default(self, path: str, v: bool) -> bool:
		_want("set_bool_default", v, "bool")
		return self._set_default(path, lambda d, p: d.set_bool(p, v))

	def set_literal(self, path: str, text: str) -> bool:
		"""Bind text at path as value syntax rather than as data.

		"80, 443" becomes a two-element array where set_string would store one
		string that has to be quoted. This is how a caller holding value text -
		a config line, a user's --set argument - writes it without knowing its
		shape first. Returns False on text that could not be one line's value.
		"""
		_want("set_literal", text, "str")
		v = _literal_value(text)
		if v is None:
			return False
		return self._set_value(path, v)

	def set_literal_default(self, path: str, text: str) -> bool:
		return self._set_default(path, lambda d, p: d.set_literal(p, text))

	def set_string_default(self, path: str, v: str) -> bool:
		_want("set_string_default", v, "str")
		return self._set_default(path, lambda d, p: d.set_string(p, v))

	def set_datetime_default(self, path: str, v: ShclDateTime) -> bool:
		_want("set_datetime_default", v, "datetime")
		return self._set_default(path, lambda d, p: d.set_datetime(p, v))

	def set_raw_default(self, path: str, content: str, info: str) -> bool:
		return self._set_default(path, lambda d, p: d.set_raw(p, content, info))

	def set_int_array_default(self, path: str, v: list[int]) -> bool:
		_want_all("set_int_array_default", v, "int")
		return self._set_default(path, lambda d, p: d.set_int_array(p, v))

	def set_float_array_default(self, path: str, v: list[float]) -> bool:
		_want_all("set_float_array_default", v, "float")
		return self._set_default(path, lambda d, p: d.set_float_array(p, v))

	def set_bool_array_default(self, path: str, v: list[bool]) -> bool:
		_want_all("set_bool_array_default", v, "bool")
		return self._set_default(path, lambda d, p: d.set_bool_array(p, v))

	def set_string_array_default(self, path: str, v: list[str]) -> bool:
		_want_all("set_string_array_default", v, "str")
		return self._set_default(path, lambda d, p: d.set_string_array(p, v))

	def set_datetime_array_default(self, path: str, v: list[ShclDateTime]) -> bool:
		_want_all("set_datetime_array_default", v, "datetime")
		return self._set_default(path, lambda d, p: d.set_datetime_array(p, v))

	# Layered loading: overlay a higher-priority document

	def merge(self, over: Document) -> None:
		"""Overlay `over` (a higher-priority layer) onto self (the lower one).
		Container instances merge by (name, value) exactly like the in-file rule;
		a leaf name present in `over` replaces self's same-named children at that
		scope - provided those base children are leaves too - so scalars, arrays,
		and raw blocks get real override while a bare section header merges
		instead of wiping. over-only nodes are appended. Comment trivia rides
		with each node. Load(defaults, site, user) is a left fold of this: each
		later file overlaid on the earlier ones.

		The fold is not associative: (A+B)+C and A+(B+C) differ where a bare
		header meets an overridden leaf, so a cached upper pair is not the same
		document the CLI's left fold produces. self keeps its own strictness, so
		a value from a stricter layer reads with self's coercion. And a replaced
		node is kept until the document is dropped: this costs a pass over the
		touched scopes plus an index rebuild on the next read.

		A document merged onto itself is left as it is. The walk reads over
		while it writes self, so the same document on both sides grew without
		end."""
		if over is self:
			return
		self._index = None
		self._source = None
		self._lost += over._lost
		# The layer's own kept lines were modeled against its own tree.
		fresh = over._kept
		self._kept = self._kept or over._kept
		# Only a block the overlay visited can have a changed child list or
		# comments; the rest was settled when it was built. Settling the whole
		# tree made every merge cost the document (20260924 item 6). A block's
		# settle writes only below it, so the order does not matter.
		for n in self._overlay(ROOT, over, ROOT):
			_settle_block(self.arena, n, 1)
		# Layers commonly share a footer; keeping one copy of each keeps a
		# stack of files from repeating it once per layer. Only the lines
		# already here count: a layer's own repeats are its content.
		had = len(self.orphans)
		# A repeat skipped here may be the comment the next one sat under, and
		# a reload puts a comment at most one level past the comment before
		# it, so none goes deeper than that.
		room = next((e.depth + 1 for e in reversed(self.orphans) if e.text.startswith("#")), 0)
		for o in over.orphans:
			if not any(e.text == o.text and e.depth == o.depth for e in self.orphans[:had]):
				depth = o.depth
				if o.text.startswith("#"):
					depth = min(depth, room)
					room = depth + 1
				self.orphans.append(_Lead(o.text, o.blank_before, depth, kept=o.kept))
		_settle_first_blank(self.arena, self.orphans)
		if fresh:
			self._settle_kept()
		else:
			self._resettle_kept()

	# One grouping pass over each side, then a single children rebuild: the
	# old shape re-filtered the over side per distinct name and re-scanned
	# (and re-keyed) the base side per over node - three O(K^2) terms at one
	# parent, plus a full list rebuild per replaced name.
	def _adopt_trivia(self, base, over, ok):
		"""A matched instance keeps the base node, so the over side's comments have
		to move onto it or they are lost. Same rule as an in-file merge: leading
		concatenates in layer order, first trailing wins."""
		# Per-element copies: the merged document must not share list objects
		# with `over`, which the caller may still use.
		st = over.arena[ok].trivia
		if st is None:
			return
		bt = self.arena[base]._triv()
		bt.leading.extend(_Lead(c.text, c.blank_before, c.depth, kept=c.kept) for c in st.leading)
		if st.trailing:
			if not bt.trailing:
				bt.trailing = st.trailing
			else:
				bt.leading.append(_Lead(st.trailing, False))
		bt.after.extend(_Lead(c.text, c.blank_before, c.depth, kept=c.kept) for c in st.after)
		bt.inside.extend(_Lead(c.text, c.blank_before, c.depth, kept=c.kept) for c in st.inside)
		bt.among.extend((pos, _Lead(c.text, c.blank_before, c.depth, kept=c.kept)) for pos, c in st.among)
		bt.among.sort(key=lambda a: a[0])

	def _overlay(self, base_parent, over, over_parent):
		"""Explicit stack rather than recursion, for the same reason _clone_subtree
		uses one. Each level's rebuild depends on nothing the deeper levels do, so
		deferring them changes no result; the walk stays depth-first and in order.
		Returns the base blocks it visited, which are the ones a merge settles."""
		touched = []
		stack = [(base_parent, over_parent)]
		while stack:
			bp, op = stack.pop()
			touched.append(bp)
			stack.extend(reversed(self._overlay_level(bp, over, op)))
		return touched

	def _overlay_level(self, base_parent, over, over_parent):
		"""One level of the overlay. Returns the (base, over) pairs whose subtrees
		still have to be merged, in order."""
		over_kids = over.arena[over_parent].children
		# Over side: name -> node bucket, in first-appearance order.
		order = []
		groups: dict = {}
		for pos, k in enumerate(over_kids):
			n = over.arena[k].name
			g = groups.get(n)
			if g is None:
				order.append(n)
				g = []
				groups[n] = g
			g.append((pos, k))
		# Base side, one pass: does the name have a container instance, and
		# which child carries each (name, key) - every key computed once. The
		# list is copied because the splices below rewrite it as they go.
		base_kids = list(self.arena[base_parent].children)
		has_container: dict = {}
		by_name: dict = {}
		by_key: dict = {}
		for b in base_kids:
			name = self.arena[b].name
			has_container[name] = has_container.get(name, False) or bool(self.arena[b].children)
			by_name.setdefault(name, []).append(b)
			by_key.setdefault(_merge_key(name, self.arena[b].value), b)
		# Decide per name. A name whose over-side nodes are all leaves is an
		# override - but only when the base side of the group is leaf-shaped
		# too. Against a base container, a childless over-node is a wrapper
		# mention, not a leaf, so it falls through to the instance merge: a
		# bare section header in a higher layer never wipes the subtree below.
		# Replaced groups splice in the rebuild; everything appended (unmatched
		# instances, and replaced names base never had) keeps the over file's
		# order, which the per-name pass here would otherwise regroup.
		replace = {}
		appended = []
		pending = []
		for name in order:
			group = groups[name]
			over_leafy = all(not over.arena[k].children for _, k in group)
			in_base = name in has_container
			base_container = has_container.get(name, False)
			if over_leafy and not base_container:
				clones = [(pos, self._clone_subtree(over, ok, base_parent)) for pos, ok in group]
				if in_base:
					# The replaced leaf's comments go with it, which the spec
					# allows; a content-malformed line retained on it is content
					# the parser promised to keep, so those move onto the
					# replacement. A comment starts with `#`, a retained line
					# never does.
					# Off the index, not a scan of every base child: N leaves
					# overridden by the same N names made this quadratic
					# (20260918b item 58).
					kept: list[_Lead] = []
					for b in by_name.get(name, ()):
						nd = self.arena[b]
						lines = [*nd.leading(), *(a[1] for a in nd.among()), *nd.inside(), *nd.after()]
						kept.extend(_Lead(lead.text, lead.blank_before, lead.depth) for lead in lines if not lead.text.startswith("#"))
					if kept:
						t = self.arena[clones[0][1]]._triv()
						t.leading = kept + t.leading
					replace[name] = [c for _, c in clones]
				else:
					appended.extend(clones)
			else:
				for pos, ok in group:
					okey = _merge_key(name, over.arena[ok].value)
					b = by_key.get(okey)
					# A raw block in the higher layer fills a same-named empty
					# binding below, exactly as a fence line fills one inside a
					# single file. Without it, merging two documents and parsing
					# them run together disagree: both bindings survive here and
					# fold there, so merged output is not a formatter fixpoint.
					if b is None and over.arena[ok].value.kind == "raw":
						empty = _merge_key(name, _Value("empty"))
						hit = by_key.get(empty)
						if hit is not None:
							self.arena[hit].value = over.arena[ok].value.copy()
							del by_key[empty]
							by_key.setdefault(okey, hit)
							b = hit
					if b is not None:
						# A stacked spelling no kept line holds is gone on a
						# reload, so it may not decide how the lines the other
						# layer brings are written (20260926 item 4).
						stacked = _stacks(self.arena[b]) or _stacks(over.arena[ok])
						self._adopt_trivia(b, over, ok)
						self.arena[b].star_list = stacked
						# A name that reaches here is never in `replace`, so `b`
						# survives the rebuild below and can wait for it.
						pending.append((b, ok))
					else:
						appended.append((pos, self._clone_subtree(over, ok, base_parent)))
		if not replace and not appended:
			return pending
		# Rebuild once: each replaced group lands at its name's first original
		# position (dropped nodes stay in the arena, unreferenced - reads and
		# emit walk children from the root), appends go at the end.
		new_kids = []
		spliced = set()
		for b in base_kids:
			name = self.arena[b].name
			clones = replace.get(name)
			if clones is None:
				new_kids.append(b)
			elif name not in spliced:
				spliced.add(name)
				new_kids.extend(clones)
		appended.sort(key=lambda pc: pc[0])
		new_kids.extend(c for _, c in appended)
		self.arena[base_parent].children = new_kids
		return pending

	def _clone_subtree(self, over, oi, parent):
		"""Deep-copy `over`'s subtree at `oi` into self's arena under `parent`.
		Explicit stack rather than recursion, for the same reason the parse and
		emit walks are iterative: python's frame budget is small enough that a
		document at the documented depth cap can exhaust it from an already-deep
		caller, and a raise part-way through leaves the base document mutated."""
		root = self._clone_node(over, oi, parent)
		stack = [(oi, root)]
		while stack:
			si, di = stack.pop()
			# Children are pushed reversed so they pop in source order; each
			# appends to its own parent, so sibling order is preserved.
			kids = []
			for ok in over.arena[si].children:
				ci = self._clone_node(over, ok, di)
				self.arena[di].children.append(ci)
				kids.append((ok, ci))
			stack.extend(reversed(kids))
		return root

	def _clone_node(self, over, oi, parent):
		"""One node of _clone_subtree: everything but the children."""
		src = over.arena[oi]
		# Copy the value too - sharing the object (and its element list) with
		# `over` would break the promise that the clone survives its release.
		cv = src.value.copy()
		node = _Node(src.name, cv, parent, src.line, src.name_src)
		node.star_list = src.star_list
		node.star_mixed = src.star_mixed
		st = src.trivia
		if st is not None:
			t = node._triv()
			t.leading = [_Lead(c.text, c.blank_before, c.depth, kept=c.kept) for c in st.leading]
			t.trailing = st.trailing
			t.after = [_Lead(c.text, c.blank_before, c.depth, kept=c.kept) for c in st.after]
			t.inside = [_Lead(c.text, c.blank_before, c.depth, kept=c.kept) for c in st.inside]
			t.among = [(pos, _Lead(c.text, c.blank_before, c.depth, kept=c.kept)) for pos, c in st.among]
		node.blank_before = src.blank_before
		node.src_set = src.src_set
		node.src = src.src
		idx = len(self.arena)
		self.arena.append(node)
		return idx

	# Accessor: typed reads

	def _node_at(self, path):
		# Returns ("ok", node index) or ("err", Status).
		r = self._resolve(path)
		tag = r[0]
		if tag == "err":
			return ("err", r[1])
		if tag == "none":
			return ("err", Status.NotFound)
		if tag == "many" or tag == "slots":
			return ("err", Status.Multiple)
		return ("ok", r[1])

	def _raw_of(self, n):
		"""A read's `raw`: the verbatim source value text when the value came from
		one source line, else the display form (writer-built, stacked list, raw
		block - shapes with no one-line source spelling)."""
		src = self.arena[n].src
		return src if src is not None else self.arena[n].value.display()

	def _scalar_element(self, v):
		# Returns ("ok", element) or ("err", Status).
		if v.kind == "empty":
			return ("err", Status.Empty)
		if v.kind == "raw":
			return ("err", Status.BadType)
		if len(v.els) == 1:
			return ("ok", v.els[0])
		return ("err", Status.BadType)   # an array is not one scalar

	def _read_scalar(self, path: str, coerce: Callable[[Any], T | None], default: T) -> Read[T]:
		na = self._node_at(path)
		if na[0] == "err":
			return Read(default, na[1], None)
		value = self.arena[na[1]].value
		raw = self._raw_of(na[1])
		line = self.arena[na[1]].line
		se = self._scalar_element(value)
		if se[0] == "err":
			return Read(default, se[1], raw)._at(line, False)
		v = coerce(se[1])
		if v is None:
			return Read(default, Status.BadType, raw)._at(line, se[1].quoted)
		return Read(v, Status.Good, raw)._at(line, se[1].quoted)

	def read_int(self, path: str) -> Read[int]:
		lvl = self._strictness
		return self._read_scalar(path, lambda e: _parse_int_text(e, lvl), 0)

	def read_float(self, path: str) -> Read[float]:
		lvl = self._strictness
		return self._read_scalar(path, lambda e: _parse_float_text(e, lvl), 0.0)

	def read_bool(self, path: str) -> Read[bool]:
		lvl = self._strictness
		return self._read_scalar(path, lambda e: _parse_bool_text(e.text, lvl), False)

	def read_datetime(self, path: str) -> Read[ShclDateTime]:
		return self._read_scalar(path, lambda e: parse_datetime(e.text), ShclDateTime())

	def _read_named(self, path: str, coerce: Callable[[Any, str], T | None], default: T) -> Read[T]:
		"""_read_scalar with the node's name, for the reads whose bare number
		takes its unit from the name."""
		na = self._node_at(path)
		if na[0] == "err":
			return Read(default, na[1], None)
		name = self.arena[na[1]].name
		return self._read_scalar(path, lambda e: coerce(e, name), default)

	def read_duration(self, path: str, unit: DurationUnit | None = None) -> Read[timedelta]:
		"""Duration read at a path, in whole milliseconds: `500ms`, `30s`, `1h
		30m`, `2d`. A bare number takes its unit from the field name when the
		name ends in one (`timeout-ms`, `delay_seconds`), else from unit, and is
		BadType with neither."""

		def coerce(e, name):
			bare = _name_unit(name, _DURATION_NAMES) or unit
			d = _parse_duration_text(e.text, bare)
			return None if d is None else timedelta(milliseconds=d[0])

		return self._read_named(path, coerce, timedelta(0))

	def read_size(self, path: str, unit: SizeUnit | None = None, decimal: bool = False) -> Read[int]:
		"""Size read at a path, in whole bytes: `512MB`, `1.5 GiB`. A bare number
		takes its unit the way a duration does. KB to TB are powers of 1024
		unless decimal is set."""

		def coerce(e, name):
			bare = _name_unit(name, _SIZE_NAMES) or unit
			z = _parse_size_text(e.text, bare, decimal)
			return None if z is None else z[0]

		return self._read_named(path, coerce, 0)

	def read_string(self, path: str) -> Read[str]:
		"""Any value reads as a string: a raw block yields its content, an array its
		canonical inline text. Escapes are applied."""
		na = self._node_at(path)
		if na[0] == "err":
			return Read("", na[1], None)
		value = self.arena[na[1]].value
		raw = self._raw_of(na[1])
		line = self.arena[na[1]].line
		if value.kind == "empty":
			return Read("", Status.Empty, raw)._at(line, False)
		if value.kind == "raw":
			return Read(value.content, Status.Good, raw)._at(line, False)
		if len(value.els) == 1:
			return Read(value.els[0].text, Status.Good, raw)._at(line, value.els[0].quoted)
		# Canonical inline form (quoting + escapes intact), so the string
		# re-parses to the same array - not the bare display join.
		return Read(", ".join(_emit_element(e) for e in value.els), Status.Good, raw)._at(line, False)

	def read_raw(self, path: str) -> Read[str]:
		"""Raw-block content (verbatim). Non-block values are BadType."""
		na = self._node_at(path)
		if na[0] == "err":
			return Read("", na[1], None)
		value = self.arena[na[1]].value
		raw = self._raw_of(na[1])
		line = self.arena[na[1]].line
		if value.kind == "raw":
			return Read(value.content, Status.Good, raw)._at(line, False)
		if value.kind == "empty":
			return Read("", Status.Empty, raw)._at(line, False)
		return Read("", Status.BadType, raw)._at(line, False)

	def read_raw_info(self, path: str) -> Read[str]:
		"""The advisory info-string of a raw block ("" when absent)."""
		na = self._node_at(path)
		if na[0] == "err":
			return Read("", na[1], None)
		raw = self._raw_of(na[1])
		line = self.arena[na[1]].line
		value = self.arena[na[1]].value
		# An empty binding has no block, so no info string: `Empty`, the same as a `read_raw` on it. Only a value that is there and is not a block is a type mismatch.
		if value.kind == "raw":
			return Read(value.info, Status.Good, raw)._at(line, False)
		if value.kind == "empty":
			return Read("", Status.Empty, raw)._at(line, False)
		return Read("", Status.BadType, raw)._at(line, False)

	def _read_array(self, path: str, coerce: Callable[[Any], T | None], default: T) -> Read[list[T]]:
		r = self._resolve(path)
		tag = r[0]
		if tag == "err":
			return Read([], r[1], None)
		if tag == "slots":
			# Each slot reads like a scalar of the target type and records its
			# own status; the aggregate is the worst one (never silently Good).
			out = []
			sts = []
			for slot in r[1]:
				if not isinstance(slot, int):
					out.append(default)
					sts.append(slot)
					continue
				se = self._scalar_element(self.arena[slot].value)
				if se[0] == "err":
					out.append(default)
					sts.append(se[1])
					continue
				v, st = _coerced(coerce, se[1], default)
				out.append(v)
				sts.append(st)
			# No slots at all means the wildcard's parent is not there, so the
			# path did not resolve - Empty is for a node that is.
			status = max(sts, key=lambda s: s.value) if sts else Status.NotFound
			return Read(out, status, None, sts)
		if tag == "none":
			return Read([], Status.NotFound, None)
		if tag == "many":
			return Read([], Status.Multiple, None)
		# one
		value = self.arena[r[1]].value
		raw = self._raw_of(r[1])
		line = self.arena[r[1]].line
		nothing: list[T] = []
		if value.kind == "empty":
			return Read(nothing, Status.Empty, raw)._at(line, False)
		if value.kind == "raw":
			return Read(nothing, Status.BadType, raw)._at(line, False)
		out = []
		sts = []
		for el in value.els:
			v, st = _coerced(coerce, el, default)
			out.append(v)
			sts.append(st)
		status = max(sts, key=lambda s: s.value) if sts else Status.Good
		# A one-element cell has a single scalar element, so the flag means the
		# same thing here as on the scalar read of the same node.
		quoted = len(value.els) == 1 and value.els[0].quoted
		return Read(out, status, raw, sts)._at(line, quoted)

	def read_int_array(self, path: str) -> Read[list[int]]:
		lvl = self._strictness
		return self._read_array(path, lambda e: _parse_int_text(e, lvl), 0)

	def read_float_array(self, path: str) -> Read[list[float]]:
		lvl = self._strictness
		return self._read_array(path, lambda e: _parse_float_text(e, lvl), 0.0)

	def read_bool_array(self, path: str) -> Read[list[bool]]:
		lvl = self._strictness
		return self._read_array(path, lambda e: _parse_bool_text(e.text, lvl), False)

	def read_datetime_array(self, path: str) -> Read[list[ShclDateTime]]:
		return self._read_array(path, lambda e: parse_datetime(e.text), ShclDateTime())

	def read_string_array(self, path: str) -> Read[list[str]]:
		return self._read_array(path, lambda e: e.text, "")

	# Convenience/get tier: value on Good, else the call-site default. Pass a
	# `default` to make the read forgiving (Default mode - the call a beginner
	# writes 90% of the time; a missing/empty/bad/ambiguous read can't sneak in
	# as a real zero). With no default it must-exist, raising the Status. Array
	# forms fall back to the whole default list; per-slot substitution is the
	# read_*_array tier or the CLI --default.

	def _get(self, r: Read[T], default: Any) -> T:
		if r.status == Status.Good:
			return r.value
		if default is _NO_DEFAULT:
			raise StatusError(r.status)
		return default

	def get_int(self, path: str, default: Any = _NO_DEFAULT) -> int:
		return self._get(self.read_int(path), default)

	def get_float(self, path: str, default: Any = _NO_DEFAULT) -> float:
		return self._get(self.read_float(path), default)

	def get_bool(self, path: str, default: Any = _NO_DEFAULT) -> bool:
		return self._get(self.read_bool(path), default)

	def get_string(self, path: str, default: Any = _NO_DEFAULT) -> str:
		return self._get(self.read_string(path), default)

	def get_raw(self, path: str, default: Any = _NO_DEFAULT) -> str:
		return self._get(self.read_raw(path), default)

	def get_raw_info(self, path: str, default: Any = _NO_DEFAULT) -> str:
		return self._get(self.read_raw_info(path), default)

	def get_datetime(self, path: str, default: Any = _NO_DEFAULT) -> ShclDateTime:
		return self._get(self.read_datetime(path), default)

	def get_duration(self, path: str, unit: DurationUnit | None = None, default: Any = _NO_DEFAULT) -> timedelta:
		return self._get(self.read_duration(path, unit), default)

	def get_size(self, path: str, unit: SizeUnit | None = None, decimal: bool = False, default: Any = _NO_DEFAULT) -> int:
		return self._get(self.read_size(path, unit, decimal), default)

	def get_int_array(self, path: str, default: Any = _NO_DEFAULT) -> list[int]:
		return self._get(self.read_int_array(path), default)

	def get_float_array(self, path: str, default: Any = _NO_DEFAULT) -> list[float]:
		return self._get(self.read_float_array(path), default)

	def get_bool_array(self, path: str, default: Any = _NO_DEFAULT) -> list[bool]:
		return self._get(self.read_bool_array(path), default)

	def get_string_array(self, path: str, default: Any = _NO_DEFAULT) -> list[str]:
		return self._get(self.read_string_array(path), default)

	def get_datetime_array(self, path: str, default: Any = _NO_DEFAULT) -> list[ShclDateTime]:
		return self._get(self.read_datetime_array(path), default)

	# The same convenience reads with the fallback required rather than optional.
	# get_*(path, default) says the same thing and still works; these exist so
	# the spelling that means "with a fallback" is `_or` in every binding, and a
	# routine ported between two of them cannot keep the call name while changing
	# which tier it lands on.

	def get_int_or(self, path: str, default: int) -> int:
		return self._get(self.read_int(path), default)

	def get_float_or(self, path: str, default: float) -> float:
		return self._get(self.read_float(path), default)

	def get_bool_or(self, path: str, default: bool) -> bool:
		return self._get(self.read_bool(path), default)

	def get_string_or(self, path: str, default: str) -> str:
		return self._get(self.read_string(path), default)

	def get_raw_or(self, path: str, default: str) -> str:
		return self._get(self.read_raw(path), default)

	def get_raw_info_or(self, path: str, default: str) -> str:
		return self._get(self.read_raw_info(path), default)

	def get_datetime_or(self, path: str, default: ShclDateTime) -> ShclDateTime:
		return self._get(self.read_datetime(path), default)

	def get_duration_or(self, path: str, unit: DurationUnit | None, default: timedelta) -> timedelta:
		return self._get(self.read_duration(path, unit), default)

	def get_size_or(self, path: str, unit: SizeUnit | None, decimal: bool, default: int) -> int:
		return self._get(self.read_size(path, unit, decimal), default)

	def get_int_array_or(self, path: str, default: list[int]) -> list[int]:
		return self._get(self.read_int_array(path), default)

	def get_float_array_or(self, path: str, default: list[float]) -> list[float]:
		return self._get(self.read_float_array(path), default)

	def get_bool_array_or(self, path: str, default: list[bool]) -> list[bool]:
		return self._get(self.read_bool_array(path), default)

	def get_string_array_or(self, path: str, default: list[str]) -> list[str]:
		return self._get(self.read_string_array(path), default)

	def get_datetime_array_or(self, path: str, default: list[ShclDateTime]) -> list[ShclDateTime]:
		return self._get(self.read_datetime_array(path), default)

	# --- Validator: schema-as-SHCL (see spec.md "Schema validation") ---------
	# The schema is an ordinary parsed document: a flat list of `field: <path>`
	# instances whose children are the constraints (closed vocabulary).
	# Validation reuses the accessor's path scan and the typed coercions, so
	# document strictness composes for free. Schema faults (V09x) come first
	# and the surviving constraints still check the document; the unknown-field
	# sweep skips only when a fault cost a path spelling. One line-number space
	# per result. The H001/H002 hints a schema disavows are NOT dropped here:
	# they live on the parse's diagnostics, which validation does not touch.
	# Parse then validate and they are still there - call
	# suppress_declared_repeats/suppress_declared_reopens yourself, or use
	# load_and_validate, which runs both for you.

	def validate(self, schema: Document) -> list[Diagnostic]:
		"""Validate against a schema document (itself plain SHCL). Empty result
		= the document conforms. Diagnostic lines are document lines (0 =
		document scope); schema faults (V09x, schema-file lines) come first,
		and the surviving constraints still check the document. The
		unknown-field sweep runs too, unless a fault cost the schema a path
		spelling (an unreadable `field:` path, or a mount naming no declared
		fragment) - only those can turn declared fields into false unknowns;
		a key-level fault keeps its entry's chain."""
		sdef, faults = _build_schema(schema)
		out = faults
		# One mount set for the whole schema: two top-level paths can resolve
		# to the same node and mount the same fragment there, and the spec
		# says each fragment runs once per node.
		mounted: set = set()
		for c in sdef.cons:
			self._v_check_from(c, sdef, ROOT, 0, out, mounted)
		if sdef.paths_complete:
			self._v_unknown(sdef, out)
		return out

	def _v_contexts(self, start, segs, anchor, out):
		# Resolution contexts: the whole document for a plain path; each
		# enclosing instance for the part of a path after a wildcard. required/
		# repeat evaluate per context (anchor line 0 = document scope), so
		# `server[*].port` + required means a port under EACH server -
		# vacuously true with no servers.
		# Explicit stack of (start, segment offset, anchor), children pushed in
		# reverse so contexts come out in the recursive order: one frame per
		# wildcard let a path with one per document level outrun the frame
		# budget.
		stack = [(list(start), 0, anchor)]
		while stack:
			cur, at, anchor = stack.pop()
			done = False
			for i in range(at, len(segs)):
				seg = segs[i]
				nxt = []
				for n in cur:
					if seg.star:
						nxt.extend(self.arena[n].children)
					else:
						nxt.extend(self._children_named(n, seg.name))
				sel = seg.selector
				if seg.star or (sel is not None and sel[0] == "wild"):
					# Wildcard, or the name wildcard (the same per-instance
					# split, over any child name): the rest resolves per instance.
					if i + 1 == len(segs):
						out.append((anchor, nxt))
					else:
						stack.extend(([inst], i + 1, self.arena[inst].line) for inst in reversed(nxt))
					done = True
					break
				if sel is None:
					cur = nxt
				elif sel[0] == "val":
					want = sel[1]
					cur = [c for c in nxt if _disp_key(self.arena[c].value) == want and (not sel[2] or _single_scalar(self.arena[c].value))]
				else:
					cur = [nxt[sel[1]]] if sel[1] < len(nxt) else []
			if not done:
				out.append((anchor, cur))

	# A mounted fragment's fields run per resolved node, right after that
	# node's own checks, in fragment order - depth-first, so diagnostic order
	# stays derivable. Termination is structural: every mount descends at
	# least one document level, and the document is finite.
	# Explicit stack rather than recursion through the mounts: a fragment
	# mounting itself descends one frame per document level, past the frame
	# budget from a deep caller. Three job kinds keep the diagnostics in the
	# recursive order - a constraint resolves to contexts, a context checks
	# its count and then each node, a node runs its own check and then the
	# mounted fragment's fields; each pushes its followers reversed.
	def _v_check_from(self, c, sdef, start, anchor0, out, mounted):
		stack: list = [("check", c, start, anchor0)]
		while stack:
			job = stack.pop()
			if job[0] == "check":
				_, c, start, anchor0 = job
				ctxs: list = []
				self._v_contexts([start], c.segs, anchor0, ctxs)
				for anchor, found in reversed(ctxs):
					stack.append(("ctx", c, anchor, found))
			elif job[0] == "ctx":
				_, c, anchor, found = job
				if c.required and not found:
					_vdiag(out, anchor, "V002", f"required path missing: {_schema_text(c.path)}")
				if c.repeat is not None:
					lo, hi = c.repeat
					n = len(found)
					if n < lo or n > hi:
						_vdiag(out, anchor, "V007", f"instance count out of bounds at '{_schema_text(c.path)}': {n} not in {lo}..{hi}")
				stack.extend(("node", c, n) for n in reversed(found))
			else:
				_, c, n = job
				self._v_node(c, n, out)
				if c.inherits is not None:
					fcs = sdef.frags.get(c.inherits)
					if fcs is not None:
						# Two constraints can resolve to the same node and mount the
						# same fragment there. The second mount would repeat the
						# first's work and its diagnostics, and repeating it per
						# level is what makes a recursive schema cost double per
						# document level, so each pair is done once.
						if (c.inherits, n) not in mounted:
							mounted.add((c.inherits, n))
							stack.extend(("check", fc, n, self.arena[n].line) for fc in reversed(fcs))

	def _v_node(self, c, n, out):
		node = self.arena[n]
		line = node.line
		base = c.ty[:-6] if c.ty is not None and c.ty.endswith("-array") else c.ty
		is_array = c.ty is not None and c.ty.endswith("-array")

		def wrong():
			_vdiag(out, line, "V003", f"wrong type at '{_schema_text(c.path)}': value is not a valid {c.ty}")

		if node.value.kind == "empty":
			# Empty passes everything; required already counted it as present.
			return
		if node.value.kind == "raw":
			# A raw block satisfies `raw` and scalar `string` (any value reads
			# as a string); every other kind is a type miss.
			if c.ty is not None and ((base != "raw" and base != "string") or is_array):
				wrong()
				return
			if c.allowed is not None and c.allowed[0] == "strings":
				if node.value.content not in c.allowed[1]:
					_vdiag(out, line, "V004", f"value not allowed at '{_schema_text(c.path)}': {_one_line(node.value.content)}")
			return
		els = node.value.els
		if base == "raw":
			wrong()
			return
		# A scalar kind on a multi-element value is the array-where-one-scalar-
		# expected miss - except string, which reads arrays.
		if c.ty is not None and not is_array and base != "string" and len(els) > 1:
			wrong()
			return
		# Each typed kind parses every element and bails on the first miss.
		if base == "int":
			vals = [_parse_int_text(e, self._strictness) for e in els]
			if any(v is None for v in vals):
				wrong()
				return
			if c.allowed is not None and c.allowed[0] == "ints":
				for i, v in enumerate(vals):
					if v not in c.allowed[1]:
						_vdiag(out, line, "V004", f"value not allowed at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
						break
			if c.min_i is not None:
				i = _first_where(vals, lambda v: v < c.min_i)
				if i >= 0:
					_vdiag(out, line, "V005", f"value below min {c.min_i} at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
			if c.max_i is not None:
				i = _first_where(vals, lambda v: v > c.max_i)
				if i >= 0:
					_vdiag(out, line, "V006", f"value above max {c.max_i} at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
		elif base == "float":
			vals = [_parse_float_text(e, self._strictness) for e in els]
			if any(v is None for v in vals):
				wrong()
				return
			if c.allowed is not None and c.allowed[0] == "floats":
				for i, v in enumerate(vals):
					if v not in c.allowed[1]:
						_vdiag(out, line, "V004", f"value not allowed at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
						break
			if c.min_f is not None:
				i = _first_where(vals, lambda v: v < c.min_f)
				if i >= 0:
					_vdiag(out, line, "V005", f"value below min {format_float(c.min_f)} at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
			if c.max_f is not None:
				i = _first_where(vals, lambda v: v > c.max_f)
				if i >= 0:
					_vdiag(out, line, "V006", f"value above max {format_float(c.max_f)} at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
		elif base == "bool":
			vals = [_parse_bool_text(e.text, self._strictness) for e in els]
			if any(v is None for v in vals):
				wrong()
				return
			if c.allowed is not None and c.allowed[0] == "bools":
				for i, v in enumerate(vals):
					if v not in c.allowed[1]:
						_vdiag(out, line, "V004", f"value not allowed at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
						break
		elif base == "datetime":
			vals = [parse_datetime(e.text) for e in els]
			if any(v is None for v in vals):
				wrong()
				return
			if c.allowed is not None and c.allowed[0] == "dates":
				for i, v in enumerate(vals):
					if not any(_same_moment(v, a) for a in c.allowed[1]):
						_vdiag(out, line, "V004", f"value not allowed at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
						break
		elif base in ("duration", "size"):
			# A bare number takes its unit from the field name first, as the
			# read does, then the schema's `unit`.
			vals = []
			for e in els:
				if base == "duration":
					d = _parse_duration_text(e.text, _name_unit(node.name, _DURATION_NAMES) or c.unit_d)
					v = None if d is None else d[0]
				else:
					z = _parse_size_text(e.text, _name_unit(node.name, _SIZE_NAMES) or c.unit_s, c.decimal)
					v = None if z is None else z[0]
				if v is None:
					wrong()
					return
				vals.append(v)
			if c.allowed is not None and c.allowed[0] == "ints":
				for i, v in enumerate(vals):
					if v not in c.allowed[1]:
						_vdiag(out, line, "V004", f"value not allowed at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
						break
			if c.min_i is not None and c.min_text is not None:
				for i, v in enumerate(vals):
					if v < c.min_i:
						_vdiag(out, line, "V005", f"value below min {_one_line(c.min_text)} at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
						break
			if c.max_i is not None and c.max_text is not None:
				for i, v in enumerate(vals):
					if v > c.max_i:
						_vdiag(out, line, "V006", f"value above max {_one_line(c.max_text)} at '{_schema_text(c.path)}': {_one_line(els[i].text)}")
						break
		else:
			# string kind or untyped: every element coerces; only the allowed
			# set can fail, in logical-string space.
			if c.allowed is not None and c.allowed[0] == "strings":
				for e in els:
					s = e.text
					if s not in c.allowed[1]:
						_vdiag(out, line, "V004", f"value not allowed at '{_schema_text(c.path)}': {_one_line(s)}")
						break

	def _v_unknown(self, sdef, out):
		# Unknown-field sweep: a schema path legalizes its name chain and every
		# prefix (selectors ignored). Only the topmost unknown node is
		# reported; its subtree is implied unknown and skipped.
		cons = sdef.cons
		# Chains below a fragment mount only match by descending the mounts.
		has_mounts = any(c.inherits is not None for c in cons)
		legal = set()
		# Sibling names per parent chain, built once (schema order): _v_suggest
		# used to rebuild every chain per unknown field, which bit hardest on
		# the wholesale-unmatched documents the feature exists for.
		siblings: dict = {}
		# Paths with a `*` segment can't live in the exact-chain hash; they
		# match element-wise (a star matches any one name, prefixes included).
		star_pats = []
		for c in cons:
			if any(s.star for s in c.segs):
				star_pats.append(c.segs)
			chain = ""
			for s in c.segs:
				if s.star:
					break   # no sibling entry for '*'; deeper chains are pattern-only
				siblings.setdefault(chain, _SuggestNames()).push(s.name)
				chain = _chain_push(chain, s.name)
				legal.add(chain)
		# Both element-wise matchers below used to scan their whole list per
		# document node, which is quadratic once the schema and the document
		# grow together. A path can only match a chain whose first part its own
		# first segment accepts, so one bucket lookup replaces the scan.
		star_idx = _first_index(star_pats)
		# Keyed the way _chain_parts_legal's seen set is: "" for the top-level
		# list, otherwise the fragment name.
		set_idx = {}
		if has_mounts:
			set_idx[""] = _first_index([c.segs for c in cons])
			for name, fcs in sdef.frags.items():
				set_idx[name] = _first_index([c.segs for c in fcs])
		stack = [(c, "", "") for c in reversed(self.arena[ROOT].children)]
		while stack:
			n, pchain, pshown = stack.pop()
			node = self.arena[n]
			chain = _chain_push(pchain, node.name)
			seg = _diag_name(node.name)
			shown = seg if not pshown else pshown + "." + seg
			if (
				chain not in legal
				and not _star_legal(star_pats, star_idx, chain)
				and not (has_mounts and _chain_legal(cons, sdef.frags, set_idx, chain))
			):
				hint = _v_suggest(siblings, pchain, node.name)
				_vdiag(out, node.line, "V001", f"unknown field '{shown}'{hint}")
				continue
			stack.extend((k, chain, shown) for k in reversed(node.children))


class StatusError(Exception):
	"""Raised by the must-exist convenience reads (get_* with no default): a
	public name a caller can actually catch. Carries the Status in .status."""
	status: Status

	def __init__(self, status: Status):
		self.status = status
		super().__init__(status.name)


def _escape_name(name: str) -> str:
	"""Emit a stored (escape-resolved) name in a spelling that reads back as the
	same name: bare when it can be, else quoted with the escapes _apply_escapes
	undoes. This is a true inverse of the name parse, which _quote_text is not -
	that one picks a quote style to AVOID escaping and never escapes a
	backslash, which is right for a value (stored in its escaped spelling) and
	wrong for a name (stored resolved)."""
	return _escape_name_as(name, Rules.CURRENT)


def _escape_name_as(name, rules):
	"""_escape_name for a reader of rules: under 2.x an invisible character is
	written as it is, since 2.x kept a \\u as written."""
	# issuperset iterates the name in C; the generator this replaced made one
	# Python call per character of every name emitted.
	if name and _BARE_NAME_CHARS.issuperset(name):
		return name
	out = ['"']
	for c in name:
		if c == "\\":
			out.append("\\\\")
		elif c == '"':
			out.append('\\"')
		elif c == "\t":
			out.append("\\t")
		elif c == "\n":
			out.append("\\n")
		elif c in _INVISIBLE and rules is Rules.CURRENT:
			out.append(_unicode_escape_text(c))
		else:
			out.append(c)
	out.append('"')
	return "".join(out)


def _emit_name(name: str) -> str:
	return _escape_name(name)


def _diag_name(name):
	# A field name for a diagnostic message: spelled the way the emitter would
	# write it, so a name carrying a line break, a dot or a quote cannot pose as
	# something it is not - a raw `a.b` reads exactly like `a` nesting `b`, and a
	# raw line break splits one diagnostic across two.
	return _emit_name(name)


def _diag_element(e):
	# One element of a value, spelled for a diagnostic message: the emitter's
	# inline spelling, so a value carrying a line break cannot split one
	# diagnostic across two.
	return _emit_element(e)


def _diag_value(v):
	# A value for a diagnostic message. Only a cell reaches this today, from the
	# H001 hint; a raw block has no one-line form worth suggesting.
	if v.kind != "cell":
		return v.display()
	return ", ".join(_diag_element(e) for e in v.els)


def quote_segment(name: str) -> str:
	"""Quote one path segment so it can be spliced into a lookup path: a bare
	name passes through, anything else comes back quoted and escaped in the
	form the path scanner accepts. Splicing user-typed text into a path
	without this is path injection - a dotted name silently reads as nesting.
	Same spelling paths() and the canonical emitter produce."""
	return _emit_name(name)


def _h001_head(name):
	"""The single H001 wording site: the hint builder and the schema suppressor
	both come here, so the suppressor matches the exact head the builder
	emitted - never a re-parse of free prose. (The leaf name cannot ride on
	Diagnostic itself: consumers build Diagnostic literals, so its field set
	is frozen.)"""
	shown = _diag_name(name)
	return f"'{shown}' repeats as a bare leaf - did you mean '{shown}: "


def suppress_declared_repeats(schema: Document, diags: list[Diagnostic]) -> None:
	"""Drop the H001 hints a schema disavows: a field whose declared repeat upper
	bound is above 1 repeats BY DESIGN (repetition is its instance mechanism),
	so the repeated-bare-leaf hint is structurally a false positive there and
	trains users to ignore hints. Matching is by leaf name - the filter
	consumers were hand-rolling - which errs toward quiet, for a hint. Used by
	`check --schema` and load_and_validate; call it wherever doc diagnostics
	and a schema meet. Mutates diags in place."""
	names = _disavowed_names(schema, lambda c: c.repeat is not None and c.repeat[1] > 1)
	if not names:
		return
	heads = [_h001_head(n) for n in names]
	kept = []
	for d in diags:
		if d.code == "H001" and any(d.message.startswith(h) for h in heads):
			continue
		kept.append(d)
	diags[:] = kept


class FileStatus(Enum):
	"""What load_file found: the four cases a consumer's own load path
	otherwise confuses. Clean and HadErrors both carry a usable document;
	NotFound and Unreadable come back with an empty one."""
	Clean = 0        # read and parsed, no error diagnostics (hints allowed)
	HadErrors = 1    # read and parsed, but error diagnostics are present
	NotFound = 2     # no file at the path
	Unreadable = 3   # exists but could not be read (permissions, a directory, bad encoding, past a read_file cap)


# The attribute bits a publish will not carry across by itself - hidden and
# system on windows, nothing anywhere else. ReplaceFile's documented preserve
# list is creation time, short name, object id, DACLs, security attributes,
# encryption, compression and named streams, and the os.replace fallback carries
# nothing at all. Read-only is handled separately: it has to come OFF first.
_CARRIED_ATTRS = 0x2 | 0x4   # FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM


def _carried_attrs(st):
	return getattr(st, "st_file_attributes", 0) & _CARRIED_ATTRS if os.name == "nt" else 0


def _restore_attrs(target, bits):
	import ctypes

	# WinDLL exists only on windows, and mypy checks this file against the
	# POSIX stubs, where the name is simply absent.
	k32 = ctypes.WinDLL("kernel32", use_last_error=True)  # type: ignore[attr-defined]
	k32.GetFileAttributesW.restype = ctypes.c_ulong
	k32.GetFileAttributesW.argtypes = [ctypes.c_wchar_p]
	k32.SetFileAttributesW.restype = ctypes.c_int
	k32.SetFileAttributesW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong]
	now = k32.GetFileAttributesW(str(target))
	if now != 0xFFFFFFFF:
		k32.SetFileAttributesW(str(target), now | bits)


def _publish_file(tmp, target):
	# Move the finished temp file over the target. On windows that means
	# ReplaceFile rather than a rename: a rename publishes a brand-new file and
	# leaves the destination's ACLs, security attributes and named streams
	# behind, which ReplaceFile carries onto the replacement instead. What it
	# does not carry is the basic attributes - hidden and system - which the save
	# re-applies by hand. It needs the destination to exist, and it fails rather
	# than skip a merge it cannot do (no WRITE_DAC, say), so a create and any
	# failure fall back to os.replace. WRITE_THROUGH is asked for and documented
	# as unsupported by ReplaceFile, so durability rests on the file's own
	# fsync.
	#
	# A failure removes the temp file, except where nothing is left at the
	# target.
	if os.name == "nt":
		_windows_publish_file(tmp, target)
		return
	try:
		os.replace(tmp, target)
	except OSError:
		_remove_quietly(tmp)
		raise


# A scanner or an indexer that opens the fresh temp file blocks the replace and
# the rename both, for a moment, and one try made that a failed save.
_PUBLISH_TRIES = 5
_PUBLISH_PAUSE_MS = 50


def _windows_publish_file(tmp, target):
	# ReplaceFile is given a backup name, because without one a failure between
	# its two moves deletes the old file (1176) or leaves it under a name nobody
	# is told (1177). With one, 1177 leaves it at the backup and nothing at the
	# target, so the old file is put back. If even that fails, neither file is
	# removed and the error says where they are.
	import ctypes
	import time

	REPLACEFILE_WRITE_THROUGH = 0x1
	# WinDLL exists only on windows, and mypy checks this file against the
	# POSIX stubs, where the name is simply absent.
	k32 = ctypes.WinDLL("kernel32", use_last_error=True)  # type: ignore[attr-defined]
	k32.ReplaceFileW.restype = ctypes.c_int
	k32.ReplaceFileW.argtypes = [
		ctypes.c_wchar_p,
		ctypes.c_wchar_p,
		ctypes.c_wchar_p,
		ctypes.c_ulong,
		ctypes.c_void_p,
		ctypes.c_void_p,
	]
	backup = _backup_name(tmp)
	moved_away = False
	tries = 0
	while True:
		if not moved_away and os.path.exists(target):
			# The save has gone through, so a backup that will not come off is
			# left rather than failing it.
			if k32.ReplaceFileW(target, tmp, backup, REPLACEFILE_WRITE_THROUGH, None, None):
				_remove_quietly(backup)
				return
			moved_away = not os.path.exists(target) and os.path.exists(backup)
		try:
			os.replace(tmp, target)
			if moved_away:
				_remove_quietly(backup)
			return
		except OSError as e:
			err = e
		tries += 1
		if tries == _PUBLISH_TRIES:
			break
		time.sleep(_PUBLISH_PAUSE_MS / 1000)
	if os.path.exists(target) or (moved_away and _moved_back(backup, target)):
		_remove_quietly(tmp)
		raise err
	if moved_away:
		raise OSError(f"{err}; the old file is left at {backup} and the new text at {tmp}") from err
	raise OSError(f"{err}; the new text is left at {tmp}") from err


def _moved_back(backup, target):
	try:
		_publish_new_file(backup, target)
	except OSError:
		return False
	return True


def _backup_name(tmp):
	# The temp name with its `.tmp` swapped for `.bak`, so the two sit side by
	# side and are the same length. The last `.tmp` is the one the save added.
	d, name = os.path.split(tmp)
	at = name.rfind(".tmp")
	if at < 0:
		return tmp + ".bak"
	return os.path.join(d, name[:at] + ".bak" + name[at + 4 :])


def _remove_quietly(path):
	try:
		os.remove(path)
	except OSError:
		pass


def _publish_new_file(tmp, target):
	# The publish for a save that found nothing at the path, which must not
	# replace a file that turned up since. A hard link fails on anything at the
	# target, so the check and the publish are one step, and the temp name comes
	# off after. The save has gone through by then, so a temp name that will not
	# come off is left rather than failing it. A filesystem with no hard links
	# gets a check and a rename, which leaves only that short gap. On windows a
	# rename already refuses an existing target and needs no hard links.
	if os.name == "nt":
		os.rename(tmp, target)
		return
	try:
		os.link(tmp, target)
	except FileExistsError:
		raise FileExistsError("File exists") from None
	except OSError:
		if os.path.lexists(target):
			raise FileExistsError("File exists") from None
		os.rename(tmp, target)
		return
	_remove_quietly(tmp)


def _sync_dir(d):
	# The rename is a directory change, and the fsync on the file only covered
	# the file: without this a power cut right after a save can lose the publish
	# and leave the old content. Best effort - windows has no directory fsync,
	# and a filesystem that refuses one is not a reason to fail a write that
	# already succeeded.
	try:
		fd = os.open(d, os.O_RDONLY)
	except OSError:
		return
	try:
		os.fsync(fd)
	except OSError:
		pass
	finally:
		os.close(fd)


def _read_capped(f, limit):
	# At most `limit` bytes, in bounded pieces: f.read(n) allocates n bytes up
	# front, so a cap spelled as the type maximum failed on the allocation
	# instead of reading.
	chunks = []
	got = 0
	while got < limit:
		piece = f.read(min(limit - got, 1 << 20))
		if not piece:
			break
		chunks.append(piece)
		got += len(piece)
	return b"".join(chunks)


def read_file(path: str | os.PathLike[str], max_bytes: int = 0) -> tuple[str | None, FileStatus]:
	"""The file tier's read half on its own: (text, FileStatus.Clean), or
	(None, status) saying why not - NotFound, or Unreadable for everything
	else (permissions, a directory, bad encoding, or a file past max_bytes;
	0 is no cap). load_file is this plus a parse. A consumer that needs the
	exact bytes it last saw - to tell its own save coming back as a change
	notification from somebody else's edit - or a bound on how much it will
	read before a parse, calls this and parses the text itself."""
	# A path is a str or a PathLike, and fspath says so with a TypeError: open()
	# takes an int as a file descriptor, so read_file(0) read stdin and closed
	# it.
	path = os.fspath(path)
	try:
		with open(path, "rb") as f:
			# One byte past the cap is read, so a file exactly at it passes and
			# one over is caught without trusting a length from stat.
			data = _read_capped(f, max_bytes + 1) if max_bytes > 0 else f.read()
	except FileNotFoundError:
		return None, FileStatus.NotFound
	except (OSError, ValueError):
		# ValueError is not decorative: a NUL in the path raises it rather
		# than an OSError, and this call promises a status, never a throw.
		return None, FileStatus.Unreadable
	if max_bytes > 0 and len(data) > max_bytes:
		return None, FileStatus.Unreadable
	try:
		return data.decode("utf-8"), FileStatus.Clean
	except UnicodeDecodeError:
		return None, FileStatus.Unreadable


def _not_a_disk_file(path):
	# Something is at the path and is not a disk file: a windows device name.
	# POSIX has no such thing at a path, so this answers False there. os.stat
	# reports a device it can open, which covers CON and NUL, but a reserved
	# name with no device behind it - COM1 on a box with no serial port - is not
	# there to stat, and a save must still refuse it rather than leave the
	# answer to the publish. A reserved name resolves into the device namespace
	# from whatever directory it is typed in, and the full path is where that
	# shows: abspath goes through GetFullPathName, so `\\.\COM1` against a drive
	# path for an ordinary name.
	if sys.platform != "win32":
		return False
	try:
		st = os.stat(path)
	except (OSError, ValueError):
		try:
			return os.path.abspath(path).startswith("\\\\.\\")
		except (OSError, ValueError):
			return False
	return not stat.S_ISREG(st.st_mode) and not stat.S_ISDIR(st.st_mode)


def write_file_atomic(file: str | os.PathLike[str], data: str) -> str | None:
	# The file tier's write mechanism (also what the CLI's --write uses): a
	# temp file in the same dir, then a rename over the target,
	# so an interrupted write can never truncate the config it rewrites. The data
	# is synced before the rename so a crash cannot publish an empty file.
	# Returns None on success, or the error message to report.
	#
	# A rename publishes a new inode, so the target is resolved through symlinks
	# first (otherwise a linked-in config gets replaced by a regular file and the
	# real one is left stale) and the original's mode is copied onto the temp file
	# (otherwise a 600 config comes back at whatever the umask allows). Other hard
	# links to the old inode cannot survive a rename and keep the old content.
	# A NUL in the path raises ValueError rather than OSError, and this call
	# promises a returned message, never a throw. POSIX raises it here, at the
	# resolve; windows resolves such a path happily and raises at the first call
	# that touches the filesystem instead, so every one of them below has to
	# carry the same guard.
	file = os.fspath(file)   # an int is a TypeError here, not a descriptor (see read_file)
	# A path that names a directory rather than a file: it ends in a separator,
	# or its last component is `.` or `..`. The OS refuses to open such a path as
	# a regular file, but a path cleanup drops the trailing separator first, so a
	# save through `f/.` used to rewrite `f` in some bindings.
	if _names_a_directory(file):
		return f"{file}: is a directory"
	try:
		target = _resolve_target(file)
	except (OSError, ValueError) as e:
		return f"{file}: {e}"
	d = os.path.dirname(target)
	if d == "":
		d = "."
	base = os.path.basename(target)
	if base == "":
		base = target
	# At most the first 64 bytes of the name, cut where a character starts, so the
	# temp's own length is fixed. Carrying the whole name put the temp over the
	# filesystem's 255 bytes at a target name in the low 240s - and the exact
	# cut-off moved with the width of the process id, so the same file saved on one
	# machine and failed on another. Bytes, not characters: 64 characters of four
	# bytes each put it back over. A truncated name can collide; the exclusive
	# create and the eight attempts already answer that.
	raw = os.fsencode(base)
	cut = min(len(raw), TMP_NAME_BYTES)
	while 0 < cut < len(raw) and (raw[cut] & 0xC0) == 0x80:
		cut -= 1
	# A cut that backs off to nothing leaves nothing, as in the other three: the
	# empty-name fallback above is for a name that was never there.
	base = os.fsdecode(raw[:cut])
	# Exclusive create: the name is predictable, so anything already sitting
	# there - including a symlink someone else planted - must make this fail
	# rather than be written through. Retry past a stale collision, then give
	# up; refusing to write beats writing somewhere unintended.
	# A file that already exists keeps its own mode, so its temp is born private
	# and the real mode goes on below - the copy is never briefly readable to
	# anyone the original was not. A file that does not exist yet has no mode to
	# preserve, so it takes the one an ordinary create would: 0666 narrowed by
	# the umask, like every other file the user's tools produce.
	try:
		existing = os.stat(target)
	except (OSError, ValueError):
		existing = None
	# Only a regular file is replaced. A rename over a FIFO or a device node
	# swaps it for a regular file at exit 0. Save outcomes in design.md is the
	# rule for what a save does with each thing it can find at the path.
	if existing is not None and not stat.S_ISREG(existing.st_mode):
		return f"{file}: is a directory" if stat.S_ISDIR(existing.st_mode) else f"{file}: not a regular file"
	# os.stat cannot see a reserved name with no device behind it.
	if _not_a_disk_file(target):
		return f"{file}: not a regular file"
	# Windows: a read-only file cannot be replaced, and a read-only temp cannot
	# be removed after a failure, so the attribute comes off the target for the
	# publish and goes back on the new file after it - the same outcome as
	# POSIX, where the rename never needed the file writable.
	read_only = os.name == "nt" and existing is not None and not existing.st_mode & stat.S_IWRITE
	# Hidden and system ride back the same way: ReplaceFile's documented preserve
	# list does not include the basic attributes, and the os.replace fallback
	# carries nothing, so a hidden config came back visible.
	carried = _carried_attrs(existing) if existing is not None else 0
	born = 0o600 if existing is not None else 0o666
	f = None
	tmp = ""
	last = ""
	for attempt in range(8):
		tmp = os.path.join(d, f".{base}.tmp{os.getpid()}.{attempt}")
		try:
			fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, born)
			f = os.fdopen(fd, "w", encoding="utf-8", newline="")
			break
		except (OSError, ValueError) as e:
			last = str(e)
	if f is None:
		return f"{file}: cannot create temporary file: {last}"
	try:
		try:
			f.write(data)
			f.flush()
			os.fsync(f.fileno())
			# On the handle, so umask cannot narrow it the way it narrows a
			# create mode, and after the data, because a write by anyone but
			# root clears setuid/setgid. Best effort: a filesystem that cannot
			# carry the mode is not a reason to fail a write that otherwise
			# succeeded. The whole mode goes, setuid/setgid/sticky included, as
			# an editor's rewrite would carry it. The mode is a POSIX concept -
			# on windows the destination's attributes come across in the publish
			# step instead, and a 3.13 fchmod there would only touch the
			# read-only bit the publish handles itself.
			if existing is not None and os.name != "nt" and hasattr(os, "fchmod"):
				try:
					# The group first, because a chown clears setuid/setgid on
					# most systems. Best effort like the mode: a caller who is
					# not in the old group keeps its own, which is what it had
					# before this. The owner is not carried - see the file tier
					# in spec.md.
					if hasattr(os, "fchown"):
						try:
							os.fchown(f.fileno(), -1, existing.st_gid)
						except OSError:
							pass
					os.fchmod(f.fileno(), stat.S_IMODE(existing.st_mode))
				except OSError:
					pass
		finally:
			f.close()
	# ValueError alongside: text the encoder refuses (a lone surrogate) raises
	# one from write(), and it is a failed save like any other - the same
	# message shape, and no temp file left behind.
	except (OSError, ValueError) as e:
		_remove_quietly(tmp)
		return f"{file}: {e}"
	if read_only:
		_set_read_only(target, False)
	try:
		# Nothing was at the path when the save started, so nothing that turns
		# up before the publish is written over. A failed replace decides for
		# itself whether the temp file can go, since on windows it may be all
		# that is left.
		if existing is None:
			_publish_new_file(tmp, target)
		else:
			_publish_file(tmp, target)
	except OSError as e:
		if carried:
			_restore_attrs(target, carried)
		if read_only:
			_set_read_only(target, True)
		if existing is None:
			_remove_quietly(tmp)
		return f"{file}: {e}"
	if carried:
		_restore_attrs(target, carried)
	if read_only:
		_set_read_only(target, True)
	_sync_dir(d)
	return None


def _names_a_directory(path):
	last = path.replace("\\", "/").rsplit("/", 1)[-1] if os.name == "nt" else path.rsplit("/", 1)[-1]
	return bool(path) and (path[-1] in ("/", "\\" if os.name == "nt" else "/") or last in (".", ".."))


def _resolve_target(file):
	"""The path a save actually rewrites. A symlink is followed so the write goes
	through it; realpath does that but only a path that exists resolves whole,
	so a dangling link is walked by hand and the file is created where it
	points. A path that is no link at all is a plain create at the path as
	given. A link cycle is an error (raised as OSError, the caller reports it):
	silently creating a regular file in its place would be the exact
	replacement the symlink walk exists to avoid."""
	# exists() is False on a NUL, a dangling link and a cycle alike; the calls
	# below raise on the NUL, so the caller sees the same ValueError as before.
	if os.path.exists(file):
		return os.path.realpath(file)
	p = file
	for _ in range(40):
		try:
			nxt = os.readlink(p)
		except OSError:
			break
		# A link whose text ends in a separator, `.` or `..` can only reach a
		# directory, and the kernel refuses to create a file through it.
		if _names_a_directory(nxt):
			raise OSError("is a directory")
		if os.path.isabs(nxt):
			p = nxt
		else:
			p = os.path.join(os.path.dirname(p) or ".", nxt)
	if os.path.islink(p):
		raise OSError("too many levels of symbolic links")
	d = os.path.dirname(p)
	n = os.path.basename(p)
	if d != "" and n != "" and os.path.exists(d):
		return os.path.join(os.path.realpath(d), n)
	return p


def _set_read_only(path, on):
	# Windows only: the read-only attribute is the one mode bit chmod sees.
	try:
		mode = os.stat(path).st_mode
		os.chmod(path, (mode & ~stat.S_IWRITE) if on else (mode | stat.S_IWRITE))
	except OSError:
		pass


def _disavowed_names(schema, pick):
	"""Leaf names of the schema entries `pick` accepts, top-level fields and
	every fragment's fields alike. Read through the built schema, so the names
	are the ones validation will use (escapes resolved) and an entry whose key
	faulted disavows nothing."""
	sdef, _ = _build_schema(schema)
	names = []
	lists = [sdef.cons] + list(sdef.frags.values())
	for cons in lists:
		for c in cons:
			if not pick(c) or not c.segs:
				continue
			# Name wildcard: no single leaf name to disavow.
			seg = c.segs[-1]
			if not seg.star:
				names.append(seg.name)
	return names


def _h002_head(name):
	"""The single H002 wording site: the merge hint and the schema suppressor
	both come here, same discipline as _h001_head."""
	return f"merged with '{_diag_name(name)}' at "


def suppress_declared_reopens(schema: Document, diags: list[Diagnostic]) -> None:
	"""Drop the H002 hints a schema disavows: a section whose entry declares
	`reopen: true` is MEANT to be written in parts, so the merge hint is
	structurally a false positive there. Matching is by leaf name, same as the
	H001 suppressor, and it errs toward quiet, for a hint. Used by
	`check --schema` and load_and_validate; call it wherever doc diagnostics
	and a schema meet. Mutates diags in place."""
	names = _disavowed_names(schema, lambda c: c.reopen)
	if not names:
		return
	heads = [_h002_head(n) for n in names]
	kept = []
	for d in diags:
		if d.code == "H002" and any(d.message.startswith(h) for h in heads):
			continue
		kept.append(d)
	diags[:] = kept


_RESERVED = frozenset(" \t\n,:#\"'[]")


def _needs_quotes(t):
	"""Minimal quoting: bare unless a reserved character (or lookalike hazard) forces it."""
	# isdisjoint iterates the text in C and stops at the first hit; the generator
	# it replaced made one Python call per character of every element emitted.
	needs = (not t) or not _RESERVED.isdisjoint(t) or not _INVISIBLE.isdisjoint(t) or (_fence_open(t) is not None)
	# Edge whitespace still has to force quotes, for the carriage return: it is
	# a blank, so a piece ending in one loses it to the reload. Space and tab
	# are already in the list above. The test is the whole Unicode whitespace
	# set rather than those three, which only ever adds quoting - the parser
	# itself trims no wider than is_wsp, so a leading no-break space is
	# content. Edges only: interior whitespace is never trimmed and quoting it
	# would move bytes.
	if not needs and t and (t[0] in _WS_SET or t[-1] in _WS_SET):
		needs = True
	return needs


def _emit_element(e):
	"""One addition to minimal quoting: an author-quoted element keeps its quotes unless
	the text reads as one of SHCL's own data formats - quoting those is just spelling
	(readers type the value either way), but quoting a plain string is the escape and
	must survive canonicalization. This clause only ever adds quoting, so a bare emit
	stays safe.
	"""
	t = e.text
	needs = _needs_quotes(t) or (e.quoted and not _is_data_format(e))
	return _quote_text(t) if needs else t


def _new_element(text):
	"""An element no source spelled. It counts as quoted when canonical output will
	quote it, so a read gives the same answer before a save as after one."""
	return _Element(text, _needs_quotes(text))


def _is_data_format(e):
	"""True when the text reads as an int, float, bool, or datetime at standard
	strictness - fixed there deliberately, so canonical form cannot vary with
	the load strictness. A number with a leading zero does not count: quotes
	are how a file says the zeros matter, as in a zip code.

	One pass over the text before any coercion: at Standard the int, float and
	datetime forms all require at least one ASCII digit, and the only formats
	that do not are the boolean words, the longest of which is "false". An
	ordinary quoted string fails both tests, so emit stops running four full
	coercions on every quoted element it writes."""
	if _ASCII_DIGITS.isdisjoint(e.text):
		t = _trim(e.text)
		return len(t) <= 5 and _parse_bool_text(t, Strictness.Standard) is not None
	if not _leading_zero(_trim(e.text)):
		if _parse_int_text(e, Strictness.Standard) is not None:
			return True
		if _parse_float_text(e, Strictness.Standard) is not None:
			return True
	if _parse_bool_text(e.text, Strictness.Standard) is not None:
		return True
	return parse_datetime(e.text) is not None


def _leading_zero(t):
	"""A zero followed by another digit, after any sign: `007`, `-012`, `00.5`."""
	if t[:1] in ("+", "-"):
		t = t[1:]
	return len(t) > 1 and t[0] == "0" and t[1] in _ASCII_DIGITS


def _quote_text(t):
	"""Quote a logical string so the tokenizer reads it back as the same
	string. Single quotes are literal, so they are the spelling for text
	holding a double quote or a backslash; double quotes carry the escapes, so
	they are the spelling for a line break, a tab, an invisible character, or
	text holding both quote kinds."""
	return _quote_text_as(t, Rules.CURRENT)


def _quote_text_as(t, rules):
	"""_quote_text for a reader of rules, as in _quote_double_as."""
	control = "\n" in t or "\t" in t or (rules is Rules.CURRENT and not _INVISIBLE.isdisjoint(t))
	if not control and "'" not in t and ('"' in t or "\\" in t):
		return "'" + t + "'"
	return _quote_double_as(t, rules)


def _quote_double_as(t, rules):
	"""The double-quoted spelling for a reader of rules. The two read it alike,
	except a \\u escape, which 2.x kept as written, so for 2.x an invisible
	character goes in as it is."""
	out = ['"']
	for c in t:
		if c == "\\":
			out.append("\\\\")
		elif c == '"':
			out.append('\\"')
		elif c == "\n":
			out.append("\\n")
		elif c == "\t":
			out.append("\\t")
		elif c in _INVISIBLE and rules is Rules.CURRENT:
			out.append(_unicode_escape_text(c))
		else:
			out.append(c)
	out.append('"')
	return "".join(out)


# ---------------------------------------------------------------------------
# The write side's one rule: what is written has to read back
# ---------------------------------------------------------------------------
#
# A setter builds its text through the emitter and reads it back with the
# tokenizer before the document is touched. If the read does not give the value
# it was handed, the write is refused and nothing changes. No setter decides for
# itself what a quote, a `#`, a comma or a carriage return means: twelve review
# items were one setter's private rule disagreeing with the parser's. The typed
# setters keep their own render-and-parse-back on top, since a float or a
# datetime has to read back as that type and not merely as the same text.


def _encodable(text):
	"""True when the text has UTF-8 bytes for the tokenizer to scan. Python is
	the one binding whose string can hold a lone surrogate, so it is the one
	that can be handed text with no spelling at all; the read-back checks let
	that through rather than refusing it, since the save is where a document
	that cannot be encoded fails, and always has."""
	try:
		text.encode("utf-8")
	except UnicodeEncodeError:
		return False
	return True


def _emit_cell(els):
	"""The value half of a binding line, the way _emit_line writes it."""
	return ", ".join(_emit_element(e) for e in els)


def _emit_fence_line(v):
	"""The opening fence line of a raw block: the fence run, then the info
	string behind a space when it would otherwise extend the run."""
	out = v.fence_char * v.fence_len
	if v.info:
		if v.info[0] == v.fence_char:
			out += " "
		out += v.info
	return out


def _value_half(text, tok):
	# Scan text as a line's value half, behind the colon a field line puts
	# there. Returns the line the token spans index into.
	tokenize_value(":" + text, 1, Rules.CURRENT, tok)
	return tok.src


def _value_reads_back(v):
	"""True when a value comes back off the page as itself."""
	if v.kind == "empty":
		return True
	if v.kind == "cell":
		text = _emit_cell(v.els)
		if "\n" in text:
			return False
		if not _encodable(text):
			return True
		tok = Tokens()
		_value_half(text, tok)
		if tok.comment is not None:
			return False
		# Compared against the pieces rather than against a rebuilt value: a
		# bulk write runs this per set, and the text is right there.
		back = [p for p in tok.elements if p.quote is not Quote.NONE or p.end > p.start]
		if len(back) != len(v.els):
			return False
		return all(_piece_is(p, tok.src, e.text) for p, e in zip(back, v.els))
	line = _emit_fence_line(v)
	if "\n" in line:
		return False
	if not _encodable(line):
		return True
	tok = Tokens()
	tokenize_value(line, 0, Rules.CURRENT, tok)
	if _fence_open(tok.src[tok.value[0]:tok.value[1]].decode("utf-8", "surrogatepass")) != (v.fence_char, v.fence_len, v.info):
		return False
	# A body line ending in a carriage return loses it to the load's line-end
	# trim, and one spelling the closing fence would end the block early.
	return all(
		not ln.endswith("\r") and not _is_fence_close(ln, v.fence_char, v.fence_len)
		for ln in v.content.split("\n")
	)


def _name_reads_back(name):
	"""True when a field name comes back off a line as itself."""
	text = _escape_name(name)
	if "\n" in text:
		return False
	if not _encodable(text):
		return True
	tok = Tokens()
	tokenize(text, ":", False, Rules.CURRENT, tok)
	return (
		tok.fault is None
		and len(tok.segments) == 1
		and tok.segments[0].selector is None
		and _piece_is(tok.segments[0].name, tok.src, name)
	)


def _comment_line(text):
	"""The comment line this text is written as, or None when it has no
	spelling. A `#` is added when the text carries none. The load trims every
	line's end, so the trimmed text is what gets written; text holding a line
	break is refused rather than cut down to its first line."""
	if "\n" in text:
		return None
	t = _trim_wsp_end(text)
	if t.startswith("#"):
		line = t
	elif not t:
		line = "#"
	else:
		line = "# " + t
	if not _encodable(line):
		return line
	tok = Tokens()
	tokenize_value(line, 0, Rules.CURRENT, tok)
	if tok.comment == 0 and _trim_wsp_end(line) == line:
		return line
	return None


# ---------------------------------------------------------------------------
# Coercion ("intelligent but safe"; Loose re-admits a closed list of tricks)
# ---------------------------------------------------------------------------

_CURRENCY = set("$¢£¤¥₩₪₫€₭₮₱₲₴₹₺₼₽₾₿")

_I64_MIN = -(2 ** 63)
_I64_MAX = 2 ** 63 - 1


def _strip_currency(t):
	# The remainder after a leading currency symbol, with the space a person
	# writes after one taken off - `$ 1200` reached the int path's thousands
	# branch, which trims, and the float path's shape test, which does not.
	if t and t[0] in _CURRENCY:
		return t[1:].lstrip(_WS)
	return t


def _parse_i64(t):
	# Rust t.parse::<i64>(): optional +/- then ASCII digits, range-checked.
	body = t[1:] if t[:1] in ("+", "-") else t
	if not body or not _all_ascii_digits(body):
		return None
	# Length-gate before int(): CPython 3.11+ refuses >4300 decimal digits, but the
	# reference just overflows. Leading zeros are legal and don't count toward range.
	digits = body.lstrip("0") or "0"
	if len(digits) > 19:
		return None
	n = -int(digits) if t[:1] == "-" else int(digits)
	if n < _I64_MIN or n > _I64_MAX:
		return None
	return n


def _rust_round(f):
	# Nearest integer, ties away from zero (matches Rust f64::round). Returns int.
	fl = math.floor(f)
	diff = f - fl
	if diff < 0.5:
		return fl
	if diff > 0.5:
		return fl + 1
	return fl + 1 if f > 0 else fl


def _parse_int_text(e, level):
	t = _trim(e.text)
	if level == Strictness.Loose:
		t = _strip_currency(t)
	# Plain decimal.
	body = t[1:] if t[:1] in ("+", "-") else t
	if body and _all_ascii_digits(body):
		return _parse_i64(t)
	# Hex, octal and binary.
	if t[:1] == "-":
		neg = True
		prefixed = t[1:]
	else:
		neg = False
		prefixed = t[1:] if t[:1] == "+" else t
	rb = _radix_body(prefixed)
	if rb is not None:
		# Range-check the magnitude against the sign, so the negative i64-min
		# magnitude (0x8000000000000000) reads like its decimal spelling.
		mag = int(rb[1], rb[0])
		if mag > (_I64_MAX + 1 if neg else _I64_MAX):
			return None
		return -mag if neg else mag
	# Thousands separators, only inside quotes (bare commas are reserved).
	if e.quoted and "," in t:
		sign_body = t[1:] if t[:1] in ("+", "-") else t
		groups = sign_body.split(",")
		well_formed = (
			len(groups) > 1
			and groups[0] != ""
			and len(groups[0]) <= 3
			and _all_ascii_digits(groups[0])
			and all(len(g) == 3 and _all_ascii_digits(g) for g in groups[1:])
		)
		if well_formed:
			return _parse_i64(t.replace(",", ""))
	# Loose: a float (including %) rounds, half away from zero.
	if level == Strictness.Loose:
		f = _parse_float_text(e, level)
		if f is not None and not math.isnan(f) and not math.isinf(f):
			r = _rust_round(f)
			# The top bound is 2^63 itself, exclusively: i64 max has no exact
			# double, so a `.0` spelling of it lands above the range.
			if -(2 ** 63) <= r < 2 ** 63:
				return r
	return None


def _float_shape_ok(t):
	body = t[1:] if t[:1] in ("+", "-") else t
	if not body:
		return False
	epos = -1
	for i, c in enumerate(body):
		if c == "e" or c == "E":
			epos = i
			break
	if epos >= 0:
		mantissa = body[:epos]
		exp = body[epos + 1:]
	else:
		mantissa = body
		exp = None
	if exp is not None:
		xb = exp[1:] if exp[:1] in ("+", "-") else exp
		if not xb or not _all_ascii_digits(xb):
			return False
	dot = mantissa.find(".")
	if dot >= 0:
		int_part = mantissa[:dot]
		frac_part = mantissa[dot + 1:]
	else:
		int_part = mantissa
		frac_part = ""
	if int_part == "" and frac_part == "":
		return False
	return _all_ascii_digits(int_part) and _all_ascii_digits(frac_part)


def _parse_float_text(e, level):
	t = _trim(e.text)
	percent = False
	if level == Strictness.Loose:
		t = _strip_currency(t)
		if t.endswith("%"):
			t = _trim_end(t[:-1])
			percent = True
	if _float_shape_ok(t):
		try:
			v = float(t)
		except ValueError:
			return None
		# A literal past the double range is an infinity, which no double
		# holds and no setter can write back: BadType, like a text that is not
		# a number at all.
		if not math.isfinite(v):
			return None
	else:
		# An integer is a valid float on read (incl. hex, octal, binary and quoted thousands).
		iv = _parse_int_text_no_loose(_Element(t, e.quoted))
		if iv is not None:
			v = float(iv)
		else:
			w = _parse_int_text_wide(_Element(t, e.quoted))
			if w is None:
				return None
			v = w
	return v / 100.0 if percent else v


_RADIXES = {"x": 16, "X": 16, "o": 8, "O": 8, "b": 2, "B": 2}


def _radix_body(t):
	"""The digits after a `0x`, `0o` or `0b` prefix, either case, with their
	radix, or None. A bare leading zero is decimal, so `0o` is the one way to
	write an octal mode."""
	if len(t) < 3 or t[0] != "0" or t[1] not in _RADIXES:
		return None
	radix = _RADIXES[t[1]]
	digits = t[2:]
	allowed = "0123456789abcdefABCDEF"[: radix if radix <= 10 else 22]
	if not all(c in allowed for c in digits):
		return None
	return radix, digits


def _parse_int_text_wide(e):
	# The integer spellings the plain float parse does not read - hex, octal,
	# binary and quoted thousands - past the i64 range, as a double: a float
	# read is bounded by the double, not by the integer type. A prefixed number
	# goes in digit by digit in the double, so every binding rounds the same
	# way; the spellings mirror _parse_int_text.
	t = _trim(e.text)
	neg = t.startswith("-")
	body = t[1:] if t[:1] in ("-", "+") else t
	rb = _radix_body(body)
	if rb is not None:
		radix, digits = rb
		v = 0.0
		for c in digits:
			v = v * float(radix) + float(int(c, 16))
	elif e.quoted and "," in body:
		groups = body.split(",")
		well_formed = (
			len(groups) > 1
			and groups[0] != ""
			and len(groups[0]) <= 3
			and _all_ascii_digits(groups[0])
			and all(len(g) == 3 and _all_ascii_digits(g) for g in groups[1:])
		)
		if not well_formed:
			return None
		try:
			v = float(body.replace(",", ""))
		except ValueError:
			return None
	else:
		return None
	if not math.isfinite(v):
		return None
	return -v if neg else v


def _parse_int_text_no_loose(e):
	# Integer forms only (no Loose float fallback) - used by the float path.
	return _parse_int_text(e, Strictness.Standard)


def _parse_bool_text(t, level):
	s = _ascii_lower(_trim(t))
	if s == "true":
		return True
	if s == "false":
		return False
	if level == Strictness.Strict:
		return None
	if s in ("yes", "on", "1"):
		return True
	if s in ("no", "off", "0"):
		return False
	if level == Strictness.Loose:
		if s in ("t", "y", "enable", "enabled"):
			return True
		if s in ("f", "n", "disable", "disabled"):
			return False
	return None


# ---------------------------------------------------------------------------
# Durations and sizes: a number with a unit, or a bare number whose unit the
# field name or the caller gives
# ---------------------------------------------------------------------------


class DurationUnit(Enum):
	"""The unit a duration read gives a bare number, when the field name gives
	none. Smallest first; the value is the spelling."""

	Millis = "ms"
	Seconds = "s"
	Minutes = "m"
	Hours = "h"
	Days = "d"

	def spelling(self) -> str:
		return self.value

	@staticmethod
	def from_spelling(s: str) -> DurationUnit | None:
		"""The unit a value spelling names, lower case only."""
		for u in DurationUnit:
			if u.value == s:
				return u
		return None


_DURATION_MILLIS = {
	DurationUnit.Millis: 1,
	DurationUnit.Seconds: 1_000,
	DurationUnit.Minutes: 60_000,
	DurationUnit.Hours: 3_600_000,
	DurationUnit.Days: 86_400_000,
}


class SizeUnit(Enum):
	"""The unit a size read gives a bare number, when the field name gives none.
	Kilo to Tera are powers of 1024 unless the read asks for decimal; Kibi to
	Tebi always are. The value is the spelling."""

	Bytes = "B"
	Kilo = "KB"
	Mega = "MB"
	Giga = "GB"
	Tera = "TB"
	Kibi = "KiB"
	Mebi = "MiB"
	Gibi = "GiB"
	Tebi = "TiB"

	def spelling(self) -> str:
		return self.value

	@staticmethod
	def from_spelling(s: str) -> SizeUnit | None:
		"""The unit a value spelling names. Letter case is read, since Mb is
		megabits to most readers; kB is the one other spelling taken."""
		if s == "kB":
			return SizeUnit.Kilo
		for u in SizeUnit:
			if u.value == s:
				return u
		return None


def _size_bytes(u, decimal):
	k = 1000 if decimal else 1024
	return {
		SizeUnit.Bytes: 1,
		SizeUnit.Kilo: k,
		SizeUnit.Mega: k**2,
		SizeUnit.Giga: k**3,
		SizeUnit.Tera: k**4,
		SizeUnit.Kibi: 1 << 10,
		SizeUnit.Mebi: 1 << 20,
		SizeUnit.Gibi: 1 << 30,
		SizeUnit.Tebi: 1 << 40,
	}[u]


# The longest duration a read gives, in milliseconds: Go's time.Duration range,
# so every binding holds every duration another one reads.
_DURATION_MAX_MS = 9_223_372_036_854
_U64_MAX = (1 << 64) - 1
_I64_MAX_U = (1 << 63) - 1

# Field name endings that give a bare number its unit, after a `-` or `_`.
# min, m and s are left out: `retries-min` is a minimum, and a trailing s is
# usually a plural. A capitalized word (`timeoutMs`) is not a boundary, since
# names fold to lower case and fmt writes them folded.
_DURATION_NAMES = (
	("ms", DurationUnit.Millis),
	("sec", DurationUnit.Seconds),
	("seconds", DurationUnit.Seconds),
	("minutes", DurationUnit.Minutes),
	("hours", DurationUnit.Hours),
	("days", DurationUnit.Days),
)

_SIZE_NAMES = (
	("bytes", SizeUnit.Bytes),
	("kb", SizeUnit.Kilo),
	("mb", SizeUnit.Mega),
	("gb", SizeUnit.Giga),
	("tb", SizeUnit.Tera),
	("kib", SizeUnit.Kibi),
	("mib", SizeUnit.Mebi),
	("gib", SizeUnit.Gibi),
	("tib", SizeUnit.Tebi),
)

_DURATION_RANK = {u: i for i, u in enumerate(DurationUnit)}


def _name_unit(name, table):
	"""The unit a field name ends in, from table: the ending, in any letter case,
	after a `-` or `_`."""
	for end, unit in table:
		at = len(name) - len(end)
		if at > 0 and _ascii_lower(name[at:]) == end and name[at - 1] in "-_":
			return unit
	return None


def _decimal_at(s):
	"""A decimal number at the start of s: digits, then a point and more digits
	if there is a point. The two digit runs and where it ended, or None."""
	i = 0
	while i < len(s) and s[i] in _ASCII_DIGITS:
		i += 1
	if i == 0:
		return None
	if i >= len(s) or s[i] != ".":
		return s[:i], "", i
	j = i + 1
	while j < len(s) and s[j] in _ASCII_DIGITS:
		j += 1
	if j == i + 1:
		return None
	return s[:i], s[i + 1:j], j


def _scaled(int_digits, frac_digits, scale):
	"""int.frac times scale, exactly, or None when that is not a whole number or
	does not fit, so 1.5s is 1500 ms and 0.0001s is refused. At most 18 digits
	after the point count, and the sum stays in 64 bits, as in the reference."""
	int_digits = int_digits.lstrip("0")
	frac_digits = frac_digits.rstrip("0")
	if len(int_digits) > 19 or len(frac_digits) > 18:
		return None
	total = (int(int_digits) if int_digits else 0) * scale
	if total > _U64_MAX:
		return None
	if frac_digits:
		part = int(frac_digits)
		den = 10 ** len(frac_digits)
		g = math.gcd(scale, den)
		step = den // g
		if part % step:
			return None
		total += part // step * (scale // g)
		if total > _U64_MAX:
			return None
	return total


def _parse_duration_text(t, bare):
	"""A duration in whole milliseconds and the units the text spelled, or None:
	parts such as `1h 30m`, largest unit first and each once, with blanks
	allowed between a number and its unit and between parts. A bare number
	takes bare, and is None without one. No sign."""
	t = _trim_wsp(t)
	d = _decimal_at(t)
	if d is not None and d[2] == len(t):
		if bare is None:
			return None
		ms = _scaled(d[0], d[1], _DURATION_MILLIS[bare])
		if ms is None or ms > _DURATION_MAX_MS:
			return None
		return ms, []
	rest = t
	total = 0
	units: list[DurationUnit] = []
	while rest:
		d = _decimal_at(rest)
		if d is None:
			return None
		rest = rest[d[2]:].lstrip(_WSP)
		n = 0
		while n < len(rest) and rest[n].isascii() and rest[n].isalpha():
			n += 1
		unit = DurationUnit.from_spelling(rest[:n])
		if unit is None or (units and _DURATION_RANK[units[-1]] <= _DURATION_RANK[unit]):
			return None
		v = _scaled(d[0], d[1], _DURATION_MILLIS[unit])
		if v is None:
			return None
		total += v
		if total > _U64_MAX:
			return None
		units.append(unit)
		rest = rest[n:].lstrip(_WSP)
	if not units or total > _DURATION_MAX_MS:
		return None
	return total, units


def _parse_size_text(t, bare, decimal):
	"""A size in whole bytes and the unit the text spelled, or None: a number,
	blanks allowed, then a unit. A bare number takes bare, and is None without
	one. No sign."""
	t = _trim_wsp(t)
	d = _decimal_at(t)
	if d is None:
		return None
	rest = t[d[2]:].lstrip(_WSP)
	unit = None
	if rest:
		unit = SizeUnit.from_spelling(rest)
		if unit is None:
			return None
	use = unit if unit is not None else bare
	if use is None:
		return None
	n = _scaled(d[0], d[1], _size_bytes(use, decimal))
	if n is None or n > _I64_MAX_U:
		return None
	return n, unit


def _unit_clash(name, text):
	"""A value in another unit than the one its field name ends in (H005), as
	`timeout-ms: 5s`. The value's unit is the one read, so this is a hint."""

	def said(v, n):
		return "value is in " + v + " and the name says " + n + "; the value's unit is the one read"

	nu = _name_unit(name, _DURATION_NAMES)
	if nu is not None:
		d = _parse_duration_text(text, None)
		if d is not None and nu not in d[1]:
			return said(d[1][0].value, nu.value)
	su = _name_unit(name, _SIZE_NAMES)
	if su is not None:
		z = _parse_size_text(text, None, False)
		if z is not None and z[1] is not None and z[1] != su:
			return said(z[1].value, su.value)
	return None


# ---------------------------------------------------------------------------
# Date/time (closed whitelist; shape match, then calendar validation)
# ---------------------------------------------------------------------------

_MONTHS = {
	"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
	"jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
	"january": 1, "february": 2, "march": 3, "april": 4, "june": 6,
	"july": 7, "august": 8, "september": 9, "october": 10,
	"november": 11, "december": 12,
}


def _month_from_name(s):
	return _MONTHS.get(_ascii_lower(s))


def _days_in_month(y, m):
	if m in (1, 3, 5, 7, 8, 10, 12):
		return 31
	if m in (4, 6, 9, 11):
		return 30
	if m == 2:
		return 29 if (y % 4 == 0 and y % 100 != 0) or y % 400 == 0 else 28
	return 0


def _valid_date(y, m, d):
	return 1 <= m <= 12 and d >= 1 and d <= _days_in_month(y, m)


def _parse_year4(s):
	if len(s) == 4 and _all_ascii_digits(s):
		return int(s)
	return None


def _parse_num2(s):
	if (len(s) == 1 or len(s) == 2) and _all_ascii_digits(s):
		return int(s)
	return None


def _parse_date_part(s):
	s = _trim(s)
	# Compact 8-digit YYYYMMDD.
	if len(s) == 8 and _all_ascii_digits(s):
		y = int(s[:4])
		m = int(s[4:6])
		d = int(s[6:8])
		return (y, m, d) if _valid_date(y, m, d) else None
	# Space-separated named-month forms; a comma may follow the day in "Mon DD, YYYY".
	toks = _split_ws(s)
	if len(toks) == 3:
		m = _month_from_name(toks[0])
		if m is not None:
			day_tok = toks[1][:-1] if toks[1].endswith(",") else toks[1]
			# The day is DD, like every other form's: a plain integer parse takes
			# a leading '+' and any number of leading zeros, which the whitelist
			# does not list and the delimited spellings refuse.
			d = _parse_num2(day_tok)
			y = _parse_year4(toks[2])
			if d is None or y is None:
				return None
			return (y, m, d) if _valid_date(y, m, d) else None
		m = _month_from_name(toks[1])
		if m is not None:
			d = _parse_num2(toks[0])
			y = _parse_year4(toks[2])
			if d is None or y is None:
				return None
			return (y, m, d) if _valid_date(y, m, d) else None
		return None
	if len(toks) != 1:
		return None
	# Delimited forms: one of - / . used uniformly.
	delim = None
	for c in s:
		if c == "-" or c == "/" or c == ".":
			delim = c
			break
	if delim is None:
		return None
	parts = s.split(delim)
	if len(parts) != 3 or any(p == "" for p in parts):
		return None
	# The delimiter must be uniform: no other delimiter chars anywhere.
	if sum(1 for c in s if c == "-" or c == "/" or c == ".") != 2:
		return None
	if len(parts[0]) == 4 and _all_ascii_digits(parts[0]):
		y = int(parts[0])
		m = _parse_num2(parts[1])
		d = _parse_num2(parts[2])
		if m is None or d is None:
			return None
		return (y, m, d) if _valid_date(y, m, d) else None
	m = _month_from_name(parts[0])
	if m is not None:
		d = _parse_num2(parts[1])
		y = _parse_year4(parts[2])
		if d is None or y is None:
			return None
		return (y, m, d) if _valid_date(y, m, d) else None
	m = _month_from_name(parts[1])
	if m is not None:
		d = _parse_num2(parts[0])
		y = _parse_year4(parts[2])
		if d is None or y is None:
			return None
		return (y, m, d) if _valid_date(y, m, d) else None
	return None   # everything else (MM/DD/YYYY, 2-digit years, epoch) is rejected


def _parse_time_part(s):
	"""Time with optional meridiem, fraction, zone: `H:MM[:SS[.f+]][ AM|PM][Z|+HH:MM]`.
	Returns ((h, mi, sec-if-written), frac-or-None, zone-or-None) or None."""
	t = _trim(s)
	# Zone suffix first (only valid after a time).
	zone = None
	if t and (t[-1] == "Z" or t[-1] == "z"):
		zone = ("utc", None)
		t = _trim_end(t[:-1])
	elif len(t) >= 6:
		tail = t[-6:]
		sign = tail[0]
		if (sign == "+" or sign == "-") and _is_ascii_digit(tail[1]) and _is_ascii_digit(tail[2]) \
				and tail[3] == ":" and _is_ascii_digit(tail[4]) and _is_ascii_digit(tail[5]):
			hh = int(tail[1:3])
			mm = int(tail[4:6])
			if hh <= 23 and mm <= 59:
				off = hh * 60 + mm
				if sign == "-":
					off = -off
				zone = ("offset", off)
				t = _trim_end(t[:-6])
	# Meridiem: dotted a.m. is rejected (the '.' fails the digit checks below).
	meridiem = None   # True = PM
	lower = _ascii_lower(t)
	if lower.endswith("am"):
		meridiem = False
		t = t[:len(_trim_end(lower[:-2]))]
	elif lower.endswith("pm"):
		meridiem = True
		t = t[:len(_trim_end(lower[:-2]))]
	t = _trim_end(t)
	# Fraction: only after seconds, '.' delimiter, 1-9 digits.
	dot = t.find(".")
	if dot >= 0:
		hms = t[:dot]
		f = t[dot + 1:]
		if f == "" or len(f) > 9 or not _all_ascii_digits(f):
			return None
		frac = f
	else:
		hms = t
		frac = None
	parts = hms.split(":")
	if len(parts) < 2 or len(parts) > 3:
		return None
	if frac is not None and len(parts) != 3:
		return None   # fraction can only follow HH:MM:SS
	h_raw = _parse_num2(parts[0])
	if h_raw is None:
		return None
	if len(parts[1]) != 2:
		return None
	mi = _parse_num2(parts[1])
	if mi is None:
		return None
	if len(parts) == 3:
		if len(parts[2]) != 2:
			return None
		sec = _parse_num2(parts[2])
		if sec is None:
			return None
	else:
		sec = None
	if mi > 59 or (sec is not None and sec > 59):
		return None
	if meridiem is None:
		if h_raw > 23:
			return None
		h = h_raw
	else:
		if not (1 <= h_raw <= 12):
			return None
		if not meridiem and h_raw == 12:
			h = 0
		elif not meridiem:
			h = h_raw
		elif h_raw == 12:
			h = 12
		else:
			h = h_raw + 12
	return ((h, mi, sec), frac, zone)


def _datetime_reads_back(v: ShclDateTime) -> bool:
	"""Whether a datetime's canonical spelling reads back as the same value:
	the setter's inverse-of-the-read promise, checked by making the round trip."""
	back = parse_datetime(str(v))
	return back is not None and (back.date, back.time, back.frac, back.zone) == (v.date, v.time, v.frac, v.zone)


def parse_datetime(text: str) -> ShclDateTime | None:
	"""Whole-value date/time parse per the whitelist. None = BadType."""
	t = _trim(text)
	if not t:
		return None
	colon = t.find(":")
	if colon != -1:
		# Scan back over the 1-2 hour digits to find where the time starts.
		k = colon
		while k > 0 and _is_ascii_digit(t[k - 1]) and colon - k < 2:
			k -= 1
		if k == colon:
			return None   # ':' with no hour digits before it
		if k == 0:
			# Time-only value.
			tp = _parse_time_part(t)
			if tp is None:
				return None
			(h, mi, s), frac, zone = tp
			return ShclDateTime(date=None, time=(h, mi, s), frac=frac, zone=zone)
		# Combined: one separator char between date and time.
		sep = t[k - 1]
		if sep not in ("T", "t", " ", "_", "-", "/", "."):
			return None
		date = _parse_date_part(t[:k - 1])
		if date is None:
			return None
		tp = _parse_time_part(t[k:])
		if tp is None:
			return None
		(h, mi, s), frac, zone = tp
		return ShclDateTime(date=date, time=(h, mi, s), frac=frac, zone=zone)
	# Date-only.
	date = _parse_date_part(t)
	if date is None:
		return None
	return ShclDateTime(date=date, time=None, frac=None, zone=None)


# ---------------------------------------------------------------------------
# Validator: schema build helpers (module level; methods live on Document)
# ---------------------------------------------------------------------------

_SCHEMA_TYPES = (
	"int", "float", "bool", "string", "datetime", "raw", "duration", "size",
	"int-array", "float-array", "bool-array", "string-array", "datetime-array",
)


class _Constraint:
	__slots__ = (
		"path", "segs", "ty", "required", "allowed",
		"min_i", "max_i", "min_f", "max_f",
		"unit_d", "unit_s", "decimal", "min_text", "max_text",
		"repeat", "reopen",
		"inherits", "inherits_line",
		"desc", "default_text",
	)

	def __init__(self, path, segs):
		self.path = path          # as written in the schema; message text only
		self.segs = segs
		self.ty = None            # member of _SCHEMA_TYPES
		self.required = False
		self.allowed = None       # ("ints"|"floats"|"bools"|"dates"|"strings", list)
		self.min_i = None
		self.max_i = None
		self.min_f = None
		self.max_f = None
		# duration and size: the unit a bare number takes when the field name
		# gives none, base 10 for KB to TB, and the bounds as the schema
		# spelled them, since min_i and max_i hold them in ms or bytes.
		self.unit_d = None
		self.unit_s = None
		self.decimal = False
		self.min_text = None
		self.max_text = None
		self.repeat = None        # (lo, hi)
		self.reopen = False       # H002 suppressor only; validation ignores it
		self.inherits = None      # fragment mounted at this path (subtree shape)
		self.inherits_line = 0    # schema line of the `inherits` key, for V095
		# Generator-only (`shcl init`): validation ignores both.
		self.desc = None          # `desc`, a one-line description
		self.default_text = None  # `default`, emitted as an inline value

	def clone(self):
		cc = _Constraint(self.path, list(self.segs))
		cc.ty = self.ty
		cc.required = self.required
		cc.allowed = self.allowed
		cc.min_i = self.min_i
		cc.max_i = self.max_i
		cc.min_f = self.min_f
		cc.max_f = self.max_f
		cc.unit_d = self.unit_d
		cc.unit_s = self.unit_s
		cc.decimal = self.decimal
		cc.min_text = self.min_text
		cc.max_text = self.max_text
		cc.repeat = self.repeat
		cc.reopen = self.reopen
		cc.inherits = self.inherits
		cc.inherits_line = self.inherits_line
		cc.desc = self.desc
		cc.default_text = self.default_text
		return cc


class _SchemaDef:
	# An interpreted schema: the top-level constraints plus the named fragments
	# their `inherits` keys can mount. paths_complete is False when a fault
	# cost the schema a path spelling (unreadable `field:` path, or a mount
	# naming no declared fragment); key-level faults keep their entry's chain,
	# so only those two classes can turn declared fields into false unknowns -
	# the sweep runs unless one of them happened.
	__slots__ = ("cons", "frags", "paths_complete")

	def __init__(self, cons, frags, paths_complete):
		self.cons = cons
		self.frags = frags        # name -> list of _Constraint
		self.paths_complete = paths_complete


def _coerced(coerce, el, default):
	"""One slot of an array read: the coerced value, or the type's default with
	BadType."""
	v = coerce(el)
	if v is None:
		return default, Status.BadType
	return v, Status.Good


def _vdiag(out, line, code, msg):
	out.append(Diagnostic(line, Severity.Error, msg, code))


def _single_text(v):
	# One scalar constraint value (escapes applied), or None for anything else.
	if v.kind == "cell" and len(v.els) == 1:
		return v.els[0].text
	return None


def _same_moment(a, b):
	# Two datetimes naming the same moment, whatever the spelling. The struct
	# mirrors what was written, so 12:00:00Z and 12:00:00+00:00 are different
	# values field by field while naming one time, and 12:00:00 and 12:00:00.0
	# differ only in written precision. A [value] selector matches on text, but
	# an allowed set is about the value, so it compares here. An absent zone is
	# local and matches no zone at all - that is the one spelling difference
	# that is a real difference.
	def offset(z):
		if z is None:
			return None
		return 0 if z[0] == "utc" else z[1]

	ao, bo = offset(a.zone), offset(b.zone)
	if (ao is None) != (bo is None) or (a.date is None) != (b.date is None) or (a.time is None) != (b.time is None):
		return False
	if (a.time[2] if a.time else None) != (b.time[2] if b.time else None):
		return False
	if (a.frac or "").rstrip("0") != (b.frac or "").rstrip("0"):
		return False
	if ao is None:
		return a.date == b.date and a.time == b.time

	# Zoned values are instants: the written clock less its offset, the date
	# carrying the day wrap. A time alone lives on a 24-hour cycle.
	def minutes(dt, off):
		hm = (dt.time[0] * 60 + dt.time[1] if dt.time else 0) - off
		if dt.date:
			return _days_from_civil(*dt.date) * 1440 + hm
		return hm % 1440

	return minutes(a, ao) == minutes(b, bo)


def _days_from_civil(y, m, d):
	# Days since 1970-01-01, negative before it.
	if m <= 2:
		y -= 1
	era = y // 400
	yoe = y - era * 400
	doy = (153 * ((m + 9) % 12) + 2) // 5 + d - 1
	doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468


def _build_schema(schema: Document) -> tuple[_SchemaDef, list]:
	"""Interpret a parsed schema document into constraints and fragments, plus
	any schema faults (V09x, schema-file lines). Whatever parsed cleanly is
	kept even when faults are present - a broken key drops that key, a broken
	field drops that field - so a caller can still check the document against
	the surviving constraints."""
	faults: list = []
	cons = []
	frags = {}
	paths_complete = True
	for f in schema.arena[ROOT].children:
		node = schema.arena[f]
		if node.name == "field":
			c = _parse_field(schema, f, faults)
			if c is not None:
				cons.append(c)
			else:
				paths_complete = False
		elif node.name == "fragment":
			name = _single_text(node.value)
			if not name:
				_vdiag(faults, node.line, "V094", "bad schema fragment")
				continue
			# Two `fragment` blocks of one name never reach here: the parse
			# merges them into one node and reports H002. Kept as a guard in
			# case that changes, which is why no case pins it.
			if name in frags:
				_vdiag(faults, node.line, "V094", f"bad schema fragment '{_diag_name(name)}': duplicate")
				continue
			fcs = []
			for k in schema.arena[f].children:
				kid = schema.arena[k]
				if kid.name == "field":
					c = _parse_field(schema, k, faults)
					if c is not None:
						fcs.append(c)
					else:
						paths_complete = False
				else:
					_vdiag(faults, kid.line, "V094", f"bad schema fragment '{_diag_name(name)}': unknown key '{_diag_name(kid.name)}'")
			frags[name] = fcs
		else:
			_vdiag(faults, node.line, "V090", f"unknown schema key '{_diag_name(node.name)}'")
	# Every mount must name a declared fragment; cycles (self or mutual) are
	# legal - expansion is demand-driven against a finite document.
	for c in cons + [fc for fcs in frags.values() for fc in fcs]:
		if c.inherits is not None and c.inherits not in frags:
			_vdiag(faults, c.inherits_line, "V095", f"unknown schema fragment '{_diag_name(c.inherits)}'")
			paths_complete = False
	# One constraint per line in practice, so line order = file order.
	faults.sort(key=lambda d: d.line)
	return _SchemaDef(cons, frags, paths_complete), faults


def _parse_field(schema, f, faults):
	"""One `field:` instance (top-level or inside a fragment) -> a _Constraint.
	None = faults were reported and the constraint is dropped."""
	node = schema.arena[f]
	path = _single_text(node.value)
	if path is None:
		_vdiag(faults, node.line, "V093", "bad schema path")
		return None
	try:
		segs, value_text = _scan_lookup(path)
	except _PathError:
		segs, value_text = None, None
	if segs is None or value_text is not None:
		_vdiag(faults, node.line, "V093", f"bad schema path: {_schema_text(path)}")
		return None
	c = _Constraint(path, segs)
	# Deferred so `min: 1` may precede `type: int` in the file.
	required = None
	reopen_seen = False
	allowed_at = None
	default_at = None
	min_at = None
	max_at = None
	unit_at = None
	decimal_key_at = None
	for k in schema.arena[f].children:
		kid = schema.arena[k]
		if kid.value.is_empty():
			continue  # dangling key: treated as absent
		if kid.name == "type":
			t = _single_text(kid.value)
			if t is not None:
				t = _ascii_lower(t)
			if t in _SCHEMA_TYPES:
				if c.ty is not None:
					_vdiag(faults, kid.line, "V092", "bad schema constraint 'type'")
				else:
					c.ty = t
			elif t is not None:
				_vdiag(faults, kid.line, "V091", f"unknown schema type '{_schema_text(t)}'")
			else:
				_vdiag(faults, kid.line, "V092", "bad schema constraint 'type'")
		elif kid.name == "required":
			t = _single_text(kid.value)
			b = _parse_bool_text(t, Strictness.Standard) if t is not None else None
			if b is not None and required is None:
				required = b
			else:
				_vdiag(faults, kid.line, "V092", "bad schema constraint 'required'")
		elif kid.name == "reopen":
			# Consumed by the H002 suppressor; validation itself ignores it,
			# but a bad value still faults so a typo cannot silently disavow
			# nothing.
			t = _single_text(kid.value)
			b = _parse_bool_text(t, Strictness.Standard) if t is not None else None
			if b is not None and not reopen_seen:
				reopen_seen = True
				c.reopen = b
			else:
				_vdiag(faults, kid.line, "V092", "bad schema constraint 'reopen'")
		elif kid.name == "allowed":
			if kid.value.kind == "cell" and allowed_at is None:
				allowed_at = k
			else:
				_vdiag(faults, kid.line, "V092", "bad schema constraint 'allowed'")
		elif kid.name == "min":
			if kid.value.kind == "cell" and len(kid.value.els) == 1 and min_at is None:
				min_at = k
			else:
				_vdiag(faults, kid.line, "V092", "bad schema constraint 'min'")
		elif kid.name == "max":
			if kid.value.kind == "cell" and len(kid.value.els) == 1 and max_at is None:
				max_at = k
			else:
				_vdiag(faults, kid.line, "V092", "bad schema constraint 'max'")
		elif kid.name == "unit":
			if kid.value.kind == "cell" and len(kid.value.els) == 1 and unit_at is None:
				unit_at = k
			else:
				_vdiag(faults, kid.line, "V092", "bad schema constraint 'unit'")
		elif kid.name == "decimal":
			t = _single_text(kid.value)
			b = _parse_bool_text(t, Strictness.Standard) if t is not None else None
			if b is not None and decimal_key_at is None:
				decimal_key_at = k
				c.decimal = b
			else:
				_vdiag(faults, kid.line, "V092", "bad schema constraint 'decimal'")
		elif kid.name == "repeat":
			if kid.value.kind == "cell" and c.repeat is None and len(kid.value.els) in (1, 2):
				lo = _parse_uint(kid.value.els[0].text)
				hi = _parse_uint(kid.value.els[-1].text)
				if lo is not None and hi is not None and lo <= hi:
					c.repeat = (lo, hi)
				else:
					_vdiag(faults, kid.line, "V092", "bad schema constraint 'repeat'")
			else:
				_vdiag(faults, kid.line, "V092", "bad schema constraint 'repeat'")
		elif kid.name == "inherits":
			t = _single_text(kid.value)
			if t and c.inherits is None:
				c.inherits = t
				c.inherits_line = kid.line
			else:
				_vdiag(faults, kid.line, "V092", "bad schema constraint 'inherits'")
		elif kid.name == "desc":
			# Generator-only (`shcl init`); validation ignores it. First wins.
			# A comma in a sentence makes the value several elements, and the
			# comment is prose: take them all, spelled as written.
			if c.desc is None and kid.value.kind == "cell":
				c.desc = ", ".join(e.text for e in kid.value.els)
		elif kid.name == "default":
			if c.default_text is None:
				c.default_text = _emit_value_inline(kid.value)
				default_at = k
		else:
			_vdiag(faults, kid.line, "V090", f"unknown schema key '{_diag_name(kid.name)}'")
	if required is not None:
		c.required = required
	# A raw block has no inline spelling, so a `default` that is one cannot reach
	# a generated line - it used to be dropped and the field emitted with no
	# value at all - and a `default` under `type: raw` goes out inline and then
	# fails its own type check.
	if default_at is not None:
		dkid = schema.arena[default_at]
		if dkid.value.kind == "raw" or (c.ty == "raw" and c.default_text is not None):
			_vdiag(faults, dkid.line, "V092", "bad schema constraint 'default'")
	base = c.ty[:-6] if c.ty is not None and c.ty.endswith("-array") else c.ty
	if base is None:
		base = "string"
	# `unit` and `decimal` belong to the types that read a bare number in one,
	# and a unit has to be one that type spells.
	if unit_at is not None:
		ukid = schema.arena[unit_at]
		t = _single_text(ukid.value) or ""
		if base == "duration":
			c.unit_d = DurationUnit.from_spelling(t)
		elif base == "size":
			c.unit_s = SizeUnit.from_spelling(t)
		if c.unit_d is None and c.unit_s is None:
			_vdiag(faults, ukid.line, "V092", "bad schema constraint 'unit'")
	if decimal_key_at is not None and base != "size":
		_vdiag(faults, schema.arena[decimal_key_at].line, "V092", "bad schema constraint 'decimal'")
		c.decimal = False

	# A duration or size bound is read the way the document's value is, less
	# the field name: the schema says its unit.
	def quantity(e):
		if base == "duration":
			d = _parse_duration_text(e.text, c.unit_d)
			return None if d is None else d[0]
		if base == "size":
			z = _parse_size_text(e.text, c.unit_s, c.decimal)
			return None if z is None else z[0]
		return None

	if allowed_at is not None:
		kid = schema.arena[allowed_at]
		els = kid.value.els
		# Schema values are read at Standard; only the document's values
		# coerce at the document's strictness.
		ok = True
		if base == "int":
			vals = [_parse_int_text(e, Strictness.Standard) for e in els]
			ok = all(v is not None for v in vals)
			setv = ("ints", vals)
		elif base == "float":
			vals = [_parse_float_text(e, Strictness.Standard) for e in els]
			ok = all(v is not None for v in vals)
			setv = ("floats", vals)
		elif base == "bool":
			vals = [_parse_bool_text(e.text, Strictness.Standard) for e in els]
			ok = all(v is not None for v in vals)
			setv = ("bools", vals)
		elif base == "datetime":
			vals = [parse_datetime(e.text) for e in els]
			ok = all(v is not None for v in vals)
			setv = ("dates", vals)
		elif base in ("raw", "duration", "size"):
			# A raw body has no element space to enumerate, and a duration or
			# size is bounded with min and max rather than listed.
			ok = False
			setv = None
		else:
			setv = ("strings", [e.text for e in els])
		if ok:
			c.allowed = setv
		else:
			_vdiag(faults, kid.line, "V092", "bad schema constraint 'allowed'")
	for at, is_min in ((min_at, True), (max_at, False)):
		if at is None:
			continue
		kid = schema.arena[at]
		el = kid.value.els[0]
		key = "min" if is_min else "max"
		if base == "int":
			v = _parse_int_text(el, Strictness.Standard)
			if v is None:
				_vdiag(faults, kid.line, "V092", f"bad schema constraint '{key}'")
			elif is_min:
				c.min_i = v
			else:
				c.max_i = v
		elif base == "float":
			v = _parse_float_text(el, Strictness.Standard)
			if v is None:
				_vdiag(faults, kid.line, "V092", f"bad schema constraint '{key}'")
			elif is_min:
				c.min_f = v
			else:
				c.max_f = v
		elif base in ("duration", "size"):
			v = quantity(el)
			if v is None:
				_vdiag(faults, kid.line, "V092", f"bad schema constraint '{key}'")
			elif is_min:
				c.min_i, c.min_text = v, el.text
			else:
				c.max_i, c.max_text = v, el.text
		else:
			_vdiag(faults, kid.line, "V092", f"bad schema constraint '{key}'")
	# A lower bound above the upper one admits nothing, so every value fails
	# twice and the schema, not the config, is what has to change. Reported at
	# the max line. The range goes, not the field: a key-level fault keeps its
	# entry, so the path still legalizes its name chain for the unknown-field
	# sweep, and the document is not told off twice per value for a range it
	# could never have satisfied.
	crossed = (c.min_i is not None and c.max_i is not None and c.min_i > c.max_i) or (
		c.min_f is not None and c.max_f is not None and c.min_f > c.max_f
	)
	if crossed:
		line = schema.arena[max_at].line if max_at is not None else schema.arena[f].line
		_vdiag(faults, line, "V092", "bad schema constraint 'max'")
		c.min_i = c.max_i = c.min_f = c.max_f = None
		c.min_text = c.max_text = None
	return c


def _emit_value_inline(v):
	# Re-emit a schema `default`/`allowed` value as an inline value (minimal
	# quoting, array elements joined by ", "). None for empty or raw - neither has
	# a usable one-line form. Used by the generator, not the validator.
	if v.kind != "cell":
		return None
	return _emit_cell(v.els)


def _allowed_join(a):
	kind, items = a
	if kind == "ints":
		return ", ".join(str(x) for x in items)
	if kind == "floats":
		return ", ".join(format_float(x) for x in items)
	if kind == "bools":
		return ", ".join("true" if x else "false" for x in items)
	if kind == "dates":
		return ", ".join(str(x) for x in items)
	return ", ".join(items)  # strings


def _gen_annotation(c, tyname):
	# The `# type, ...` line summarizing a constraint, ASCII only.
	parts = [tyname]
	if c.unit_d is not None:
		parts[0] = tyname + " in " + c.unit_d.value
	elif c.unit_s is not None:
		parts[0] = tyname + " in " + c.unit_s.value
	if c.decimal:
		parts.append("KB to TB in powers of 1000")
	if c.allowed is not None:
		parts.append("one of: " + _allowed_join(c.allowed))
	# The bounds are their own part of the annotation line, not an alternative
	# to `allowed`. A field can carry both, and the validator enforces both. A
	# duration or size bound reads the way the schema spelled it.
	if c.min_text is not None or c.max_text is not None:
		if c.min_text is not None and c.max_text is not None:
			parts.append(c.min_text + "-" + c.max_text)
		elif c.min_text is not None:
			parts.append(">= " + c.min_text)
		else:
			parts.append("<= " + c.max_text)
	elif c.min_i is not None or c.max_i is not None:
		if c.min_i is not None and c.max_i is not None:
			parts.append(f"{c.min_i}-{c.max_i}")
		elif c.min_i is not None:
			parts.append(f">= {c.min_i}")
		else:
			parts.append(f"<= {c.max_i}")
	elif c.min_f is not None or c.max_f is not None:
		if c.min_f is not None and c.max_f is not None:
			parts.append(format_float(c.min_f) + "-" + format_float(c.max_f))
		elif c.min_f is not None:
			parts.append(">= " + format_float(c.min_f))
		else:
			parts.append("<= " + format_float(c.max_f))
	if c.repeat is not None:
		lo, hi = c.repeat
		parts.append(f"repeat {lo}" if lo == hi else f"repeat {lo}-{hi}")
	if c.required:
		parts.append("required")
	return ", ".join(parts)


def _gen_default_text(v):
	# A default carrying a literal newline cannot sit on a value line; the
	# quoted escaped spelling reads back to the same string.
	if "\n" not in v:
		return v
	s = ['"']
	for ch in v:
		if ch == "\\":
			s.append("\\\\")
		elif ch == '"':
			s.append('\\"')
		elif ch == "\n":
			s.append("\\n")
		elif ch == "\t":
			s.append("\\t")
		else:
			s.append(ch)
	s.append('"')
	return "".join(s)


def generate(schema: Document, no_banner: bool = False) -> tuple[str, list[Diagnostic]]:
	"""Emit a commented, typed starter config from a schema (`shcl init
	--schema`). Paths that must exist (required, or a repeat lower bound of 1+)
	are live (their `default`, or an empty value); optional paths are commented
	out so the file is valid and minimal as-is. Prose the generator writes is
	`##` and a commented-out setting is `# `, so the two read apart; both are
	ordinary comments to the language, and nothing reads them back. A
	must-exist wildcard path
	whose parent gets materialized by another live line is generated too, in
	dotted form - otherwise the file would fail the very schema that produced
	it - and remaining wildcard or `[#N]` paths (which cannot be materialized)
	are listed in a trailing comment block. A path whose last segment selects by
	value is written without that selector when it has a `default`, since a
	value after the selector would be ignored: `env[prod]` with `default: prod`
	is `env: prod`. The output always loads clean and
	validates clean against its schema, except a repeat lower bound of 2+
	(identical generated lines would merge, so the shortfall is reported). The
	promise is checked against the finished text, both its load and its
	validation, so a line that does not load, or a schema whose own `default`
	breaks its field's constraints, is a fault (V097) instead of a starter config
	that fails the first time it is checked. A
	footer naming the format and pointing at the spec is written last unless
	no_banner; the flag is negative so leaving it alone writes the footer.
	Returns (text, faults): a non-empty fault list (V09x) means the schema is
	broken and text is empty."""
	# Generation lays the whole schema out, so unlike validation it has no
	# safe partial mode: any fault fails it.
	sdef, faults = _build_schema(schema)
	if faults:
		return "", faults
	cons, cuts = _expand_mounts(sdef)
	if len(cons) > _GEN_MAX_FIELDS:
		faults = []
		_vdiag(faults, 0, "V096", f"schema expands past {_GEN_MAX_FIELDS} fields; fragments mounted at more than one path multiply")
		return "", faults

	def must_exist(c):
		return c.required or (c.repeat is not None and c.repeat[0] >= 1)

	def has_wild(c):
		return any(s.selector is not None and s.selector[0] == "wild" for s in c.segs)

	# `[#N]` needs a pre-existing instance and its `#` would start a comment on a
	# binding line. A path deeper than a document may nest cannot be generated
	# either: the line would draw E016 on the way back in. A newline in a name or
	# a by-value selector is writable, since both are spelled escaped.
	# The reason doubles as the predicate, so the refusal below can never name a
	# path for a reason generation did not act on.
	def why_unwritable(c):
		if len(c.segs) > MAX_DEPTH:
			return "nests past the depth cap"
		for s in c.segs:
			if s.selector is not None and s.selector[0] == "idx":
				return "a [#N] selector needs an instance that does not exist yet"
			if s.star:
				return "a * name segment has no name to write"
		return ""

	def unwritable(c):
		return why_unwritable(c) != ""

	# Live concrete paths materialize instances; decide which must-exist
	# wildcards get filled (their first-wildcard parent chain is a prefix of
	# some live path). Fixpoint: a fill can materialize another's parent.
	def names_of(segs):
		return [s.name for s in segs]

	live = [names_of(c.segs) for c in cons if not has_wild(c) and not unwritable(c) and must_exist(c)]
	fill = [False] * len(cons)
	while True:
		changed = False
		for i, c in enumerate(cons):
			if fill[i] or not has_wild(c) or unwritable(c) or not must_exist(c):
				continue
			k = next(j for j, s in enumerate(c.segs) if s.selector is not None and s.selector[0] == "wild")
			parent = names_of(c.segs[: k + 1])
			# A wildcard in the last segment needs no other line to materialize
			# its parent: the line generated from it is that instance.
			if k + 1 == len(c.segs) or any(len(p) >= len(parent) and p[: len(parent)] == parent for p in live):
				fill[i] = True
				live.append(names_of(c.segs))
				changed = True
		if not changed:
			break
	# A live line with a value materializes an instance carrying that value,
	# and a dotted child names the empty-valued instance instead - so `srv:
	# web` followed by `srv.port:` is two `srv` nodes, and the child never
	# lands where the schema looks. Any line under such a parent selects it by
	# its value: `srv[web].port:`.
	# A filled wildcard emits a valued line of its own, so it belongs here too.
	# First wins, as the line it selects does: of two lines on one path the
	# first spelling is the one written, and its value is the instance.
	parent_values: dict = {}
	for i, c in enumerate(cons):
		if (not has_wild(c) or fill[i]) and not unwritable(c) and must_exist(c) and c.default_text is not None:
			parent_values.setdefault(tuple(names_of(c.segs)), c.default_text)
	# A commented line under a commented valued parent has the same problem
	# once both are uncommented, so it selects the parent's default too. A
	# live line keeps the dotted form under a commented parent: selecting by
	# value would make the optional parent exist.
	commented_values = dict(parent_values)
	for c in cons:
		if not has_wild(c) and not unwritable(c) and not must_exist(c) and c.default_text is not None:
			commented_values.setdefault(tuple(names_of(c.segs)), c.default_text)
	# A path that cannot be written at all belongs in the trailing note, but one
	# that must exist can never be satisfied from there: the self-check would
	# then report the document as missing a path, which points at the config
	# rather than at the schema line that cannot be generated. A repeat lower
	# bound of 2 or more is the one documented shortfall - the line is emitted
	# once and the count reported - so it is not this fault.
	# Every such path is named, not just the first: fixing one only to be refused
	# over the next tells nobody how much is wrong.
	blocked: list[Diagnostic] = []
	for c in cons:
		cannot_satisfy = c.required or (c.repeat is not None and c.repeat[0] == 1)
		if cannot_satisfy and unwritable(c) and not has_wild(c):
			_vdiag(
				blocked,
				0,
				"V097",
				"required path cannot be generated: "
				+ _schema_text(c.path)
				+ " ("
				+ why_unwritable(c)
				+ ")",
			)
	if blocked:
		return "", blocked
	out = []
	wild = []
	# Dropping a trailing `[*]` can render the same line a concrete sibling
	# already wrote; the first spelling wins. A line from a dropped `[value]`
	# selector is its own instance, so two of them with different values are
	# both written: `env[prod]` and `env[dev]` are two `env` lines. Each path
	# maps to None once a plain line wrote it, or to the values written so far.
	emitted: dict = {}
	# A child whose valued parent has no selector spelling cannot be written.
	unspellable: list[Diagnostic] = []
	# One block per generated line - its desc, annotation and binding - with
	# the path's names, so the blocks can be laid out in tree order below.
	blocks = []
	# An optional field's line goes out commented, with the constraint it came
	# from, since the self-check below cannot see a comment.
	commented = []
	for i, c in enumerate(cons):
		tyname = c.ty if c.ty is not None else "any"
		if unwritable(c) or (has_wild(c) and not fill[i]):
			wild.append((_schema_text(c.path), tyname))
			continue
		# A filled wildcard emits in dotted form, targeting the materialized
		# instance - by its value when the materializing line carries one.
		# Rebuilt from the parsed segments, not by cutting text out of the
		# path: the same path can be written several ways, and only the
		# segments say what it means. Otherwise the schema's own spelling.
		values = parent_values if must_exist(c) else commented_values
		under_valued_parent = any(
			c.segs[k - 1].selector is None and tuple(names_of(c.segs[:k])) in values
			for k in range(1, len(c.segs))
		)
		# A name carrying a newline has no verbatim spelling on a binding line;
		# the segment renderer escapes it, so such a path goes through there
		# whether or not it was filled.
		# A value after a last-segment selector is ignored, so a default there
		# goes on the bare path: the line materializes the instance, and
		# validation below decides whether the default names the one selected.
		# The schema's own spelling is kept when a file line reads it back as
		# the same path. A selector body holding a `#` is fine in a lookup and
		# opens a comment on a file line, so that one goes through the renderer.
		last = c.segs[-1]
		selects_by_value = c.default_text is not None and last.selector is not None and last.selector[0] == "val"
		if selects_by_value:
			path = _gen_path_text(c.segs[:-1] + [_Segment(last.name, last.name_src, None, last.star)], values)
		elif fill[i] or under_valued_parent or not _path_reads_back(c.path, c.segs):
			path = _gen_path_text(c.segs, values)
		else:
			path = c.path
		if path is None:
			_vdiag(
				unspellable,
				0,
				"V097",
				"required path cannot be generated: " + _schema_text(c.path) + " (its parent's value has no selector spelling)",
			)
			continue
		dval = c.default_text if c.default_text is not None else ""
		if path not in emitted:
			emitted[path] = {dval} if selects_by_value else None
		elif emitted[path] is None or not selects_by_value or dval in emitted[path]:
			continue
		else:
			emitted[path].add(dval)
		block: list[str] = []
		if c.desc is not None:
			block.extend(("## " if line else "##") + line + "\n" for line in c.desc.split("\n"))
		# The annotation is a comment: a newline smuggled in via an allowed
		# string value must not break out of it.
		block.append("## " + _schema_text(_gen_annotation(c, tyname)) + "\n")
		prefix = "" if must_exist(c) else "# "
		if c.default_text is not None:
			line = f"{path}: {_gen_default_text(c.default_text)}\n"
			block.append(prefix + line)
			if not must_exist(c):
				commented.append((i, line))
		else:
			line = f"{path}:\n"
			block.append(prefix + line)
			if not must_exist(c):
				commented.append((i, line))
		blocks.append((tuple(names_of(c.segs)), "".join(block)))
	# Tree order, first appearance first. A schema may list `a.host.srv`
	# before `a`, and emitted as listed with another field between them,
	# `a: x` re-opens `a` and the load hints it (H002) - in the one file meant
	# to show the format at its cleanest. Every prefix is ranked by where it
	# first appears, so a parent's block comes before its children's, siblings
	# keep schema order, and a schema already in tree order is unchanged.
	rank: dict[tuple[str, ...], int] = {}
	for names, _ in blocks:
		for k in range(1, len(names) + 1):
			rank.setdefault(names[:k], len(rank))
	# A parent's key is a prefix of its children's, and a shorter key sorts
	# first; the sort is stable, so two blocks on one path keep their order.
	blocks.sort(key=lambda b: tuple(rank[b[0][:k]] for k in range(1, len(b[0]) + 1)))
	for n, (_, text) in enumerate(blocks):
		if n > 0:
			out.append("\n")
		out.append(text)
	# Cycle-cut mounts last: their "type" column names the fragment that
	# belongs at the path.
	wild.extend(cuts)
	if wild:
		if blocks:
			out.append("\n")
		out.append("## Paths needing an instance name (not generated):\n")
		for path, tyname in wild:
			out.append(f"##   {path}   {tyname}\n")
	if unspellable:
		return "", unspellable
	text = "".join(out)
	if not no_banner:
		if text:
			text += "\n"
		text += GEN_BANNER
	# The output promises to validate clean against the schema that produced it,
	# so check that here rather than trusting each branch above. A `default`
	# outside its own field's constraints is the schema's fault, and the author
	# should hear about it instead of getting a starter config that fails the
	# first time it is checked. The one sanctioned shortfall is a V007 for a
	# repeat lower bound of 2+: generating that many identical lines merges
	# them into one. A lower bound of 1 is a must-exist path like any other,
	# so its V007 is a fault.
	# The load comes first, in the order `check --schema` prints: a line that
	# does not load is refused even when validation happens to pass without it.
	gdoc = Document.parse(text)
	bad = [
		Diagnostic(0, Severity.Error, f"generated text does not load: {d.code} {d.message}", "V097")
		for d in gdoc.diagnostics()
		if d.severity == Severity.Error
	]
	bad += [
		Diagnostic(0, Severity.Error, "generated value fails the schema that produced it: " + d.message, "V097")
		for d in gdoc.validate(schema)
		if d.severity == Severity.Error and not (d.code == "V007" and _v007_sanctioned(d.message))
	]
	# A commented default fails the same check once someone uncomments it. Each
	# line is read back alone and only its value is checked: uncommenting every
	# line at once would pair a valued parent with a dotted child, which names
	# a second instance, and fault a schema whose lines each work. The value is
	# found through the field's own path, the way validation finds it, so a
	# default naming another instance than the path selects is caught here as
	# it is for a required field.
	for i, line in commented:
		one = Document.parse(line)
		bad += [
			Diagnostic(0, Severity.Error, f"generated text does not load: {d.code} {d.message}", "V097")
			for d in one.diagnostics()
			if d.severity == Severity.Error
		]
		if not one.arena[ROOT].children:
			continue
		ctxs: list = []
		one._v_contexts([ROOT], cons[i].segs, 0, ctxs)
		nodes = [n for _, f in ctxs for n in f]
		if not nodes:
			path = _schema_text(cons[i].path)
			bad.append(Diagnostic(0, Severity.Error, "generated value fails the schema that produced it: default does not name the instance its path selects: " + path, "V097"))
			continue
		found: list[Diagnostic] = []
		for n in nodes:
			one._v_node(cons[i], n, found)
		bad += [
			Diagnostic(0, Severity.Error, "generated value fails the schema that produced it: " + d.message, "V097")
			for d in found
			if d.severity == Severity.Error
		]
	if bad:
		return "", bad
	return text, []


# Ceiling on how many fields one schema may expand to. Fragments that mount
# each other at more than one path multiply, so a short schema can otherwise
# ask for more output than the machine can hold; past this the generator
# reports a schema fault rather than running until something breaks.
_GEN_MAX_FIELDS = 10000

# Footer telling whoever opens the generated file what the format is and where
# its spec lives. It is output, so every binding emits these bytes exactly; the
# Legal line names SHCL as its subject so it cannot be read as a claim over the
# config it sits in. Public because a program that creates a config file of its
# own writes the same block, and a second copy of a byte-for-byte contract
# drifts.
GEN_BANNER = (
	"##\n"
	'## This config file format is SHCL.\n'
	'## "Simple Hierarchical Config Language"\n'
	"##    Format   3\n"
	"##    Home     https://github.com/yottacore/shcl\n"
	"##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md\n"
	"##    Legal    SHCL is Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.\n"
	"##\n"
)

# The format major the info block names. It moves with the format, not with the
# package: a file says which rule set it was written for, and nothing else does.
# The banner's Syntax link names the tag that opened this major, and moves with
# it.
FORMAT_MAJOR = 3

# The start of the block's version line, up to the number. migrate matches on
# this and reads the digits after it, so a later major can still tell an older
# file from one of its own.
FORMAT_LINE_HEAD = "##    Format   "

# The whole version line, as the block spells it. A program writing a config of
# its own emits GEN_BANNER, which carries this; migrate appends this line on its
# own to a file it rewrote, since that file has no block to add it to and
# inventing one would write bytes the document does not hold.
FORMAT_LINE = "##    Format   3"

# The start of a line naming the file's schema, spelled like the Format line,
# for check and for editors: `##    Schema   ./app.schema.shcl`.
SCHEMA_LINE_HEAD = "##    Schema   "

# Written under FORMAT_LINE on a file migrate actually changed. It is a note for
# whoever opens the file; nothing reads it back.
MIGRATED_LINE = "##    Migrated from SHCL 2.x."


def _v007_sanctioned(message):
	"""Whether a V007 from the self-check is the sanctioned kind: its message
	ends `: N not in LO..HI`, and LO is 2 or more."""
	_, sep, rest = message.rpartition(" not in ")
	lo = rest.split("..", 1)[0]
	return bool(sep) and lo.isdigit() and int(lo) >= 2


def _gen_selector_text(v):
	"""The selector body that picks out the instance a line `name: v` makes, or
	None when no body can. It is built from the elements the reader takes out
	of that line's value, and each candidate is scanned back the way a file
	line is scanned, so none of the scanner's rules is copied here to go stale.
	That copy was the cause twice: an all-digit body past 64 bits, and a
	quoted array element spelled as the body. One element tries the spelling
	it was written in first; an array has only the bare body, since a quoted
	selector matches one element only, and a bare one the elements joined."""
	spelled = _gen_default_text(v)
	tok = Tokens()
	tokenize_value(spelled, 0, Rules.CURRENT, tok)
	els = [_piece_text(p, tok.src) for p in tok.elements]
	display = ", ".join(els)
	if len(els) == 1:
		tries = []
		if tok.elements[0].quote is Quote.SINGLE or tok.elements[0].quote is Quote.DOUBLE:
			tries.append((tok.src[tok.value[0]:tok.value[1]].decode("utf-8", "surrogatepass"), els[0], True))
		tries += [(display, display, False), (_quote_text(els[0]), els[0], True)]
	else:
		tries = [(display, display, False)]
	for body, text, quoted in tries:
		if _selector_reads_back(body, text, quoted):
			return body
	return None


def _selector_reads_back(body, text, quoted):
	"""Whether body between brackets on a file line reads back as a value
	selector for text, quoted or bare as asked."""
	# The tokenizer reads one line and never sees a line end, so text carrying a
	# real line break would read back here and then be written across two lines,
	# which is not the same path. A file line cannot hold one, so refuse and let
	# the escaped spelling be tried instead.
	line = f"x[{body}]:"
	if "\n" in line or "\r" in line:
		return False
	tok = Tokens()
	tokenize(line, ":", False, Rules.CURRENT, tok)
	if _selector_open_quote(tok) or tok.comment is not None:
		return False
	try:
		segs, _ = _path_of(tok, tok.src)
	except _PathError:
		return False
	return len(segs) == 1 and segs[0].selector == ("val", text, quoted)


def _path_reads_back(path, segs):
	"""Whether a schema path written on a file line reads back as the same
	segments. A lookup path takes spellings a file line does not."""
	# The tokenizer reads one line and never sees a line end, so text carrying a
	# real line break would read back here and then be written across two lines,
	# which is not the same path. A file line cannot hold one, so refuse and let
	# the escaped spelling be tried instead.
	line = path + ":"
	if "\n" in line or "\r" in line:
		return False
	tok = Tokens()
	tokenize(line, ":", False, Rules.CURRENT, tok)
	if _selector_open_quote(tok) or tok.comment is not None:
		return False
	try:
		got, _ = _path_of(tok, tok.src)
	except _PathError:
		return False
	return len(got) == len(segs) and all(
		a.name == b.name and a.star == b.star and a.selector == b.selector for a, b in zip(got, segs)
	)


def _gen_path_text(segs, parent_values):
	"""Render parsed segments back as a dotted path, dropping wildcard selectors
	(a generated line targets the one instance it materializes) and quoting a
	name that needs it, so the result is a path the scanner reads back the same.
	A segment whose prefix names a live line carrying a value selects that
	instance by the value, in place of a wildcard or a bare name. None when a
	selector has no spelling a file line reads back."""
	out = []
	names = []
	for i, s in enumerate(segs):
		if i > 0:
			out.append(".")
		if s.star:
			out.append("*")
		else:
			out.append(_emit_name(s.name))
		names.append(s.name)
		v = parent_values.get(tuple(names))
		if v is not None and i + 1 < len(segs) and (s.selector is None or s.selector[0] != "val"):
			body = _gen_selector_text(v)
			if body is None:
				return None
			out.append(f"[{body}]")
			continue
		if s.selector is not None:
			if s.selector[0] == "val":
				# The body as the schema meant it: a quoted one stays quoted,
				# and a bare one goes bare when a file line reads it back.
				text = s.selector[1]
				quoted_body = _quote_text(text)
				if not s.selector[2] and _selector_reads_back(text, text, False):
					out.append(f"[{text}]")
				elif _selector_reads_back(quoted_body, text, True):
					out.append(f"[{quoted_body}]")
				else:
					return None
			elif s.selector[0] == "idx":
				out.append(f"[#{s.selector[1]}]")
			# a wildcard selector is dropped
	return "".join(out)


def _expand_mounts(sdef):
	"""Inline every fragment mount into a flat constraint list, depth-first in
	schema order, each field's path and segments prefixed by its mount's. A
	mount whose fragment is already expanding (a cycle) stops there and is
	returned as (path, fragment name) for the trailing not-generated block."""
	out: list = []
	cuts = []
	# Work stack of (constraint, mount prefix or None, chain of fragment names
	# being expanded), fields pushed in reverse so they pop in schema order.
	# One frame per mount level recursed to the depth cap, past the frame
	# budget from a deep caller; the chain each job carries is what the
	# recursion kept on the call stack.
	work: list = [(c, None, ()) for c in reversed(sdef.cons)]
	while work:
		c, at, chain = work.pop()
		cc = c.clone()
		if at is not None:
			p, s = at
			cc.path = f"{p}.{c.path}"
			cc.segs = list(s) + list(c.segs)
		path = cc.path
		segs = cc.segs
		if len(out) > _GEN_MAX_FIELDS:
			break
		out.append(cc)
		if c.inherits is not None:
			# A chain long enough to outrun the stack, or a mount that
			# re-enters, stops here and is noted instead of expanded.
			if c.inherits in chain or len(chain) >= MAX_DEPTH:
				cuts.append((_schema_text(path), _schema_text(c.inherits)))
			else:
				fcs = sdef.frags.get(c.inherits)
				if fcs is not None:
					below = chain + (c.inherits,)
					work.extend((fc, (path, segs), below) for fc in reversed(fcs))
	return out, cuts


def _edit_distance(a, b, cap):
	# Levenshtein distance capped at `cap`, for the "did you mean" prose (never
	# the code): anything past the cap comes back as cap + 1. Only the band
	# |i - j| <= cap of the table is computed, so a pair costs linear time in
	# the names' length, and a length gap past the cap needs no table at all.
	inf = cap + 1
	if abs(len(a) - len(b)) > cap:
		return inf
	prev = [min(j, inf) for j in range(len(b) + 1)]
	cur = [inf] * (len(b) + 1)
	for i in range(1, len(a) + 1):
		cur[0] = min(i, inf)
		lo = max(i - cap, 1)
		hi = min(i + cap, len(b))
		if lo > 1:
			cur[lo - 1] = inf
		row_min = cur[0]
		for j in range(lo, hi + 1):
			cost = 0 if a[i - 1] == b[j - 1] else 1
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost, inf)
			if cur[j] < row_min:
				row_min = cur[j]
		if hi < len(b):
			cur[hi + 1] = inf
		# No cell in a later row can come back under this row's minimum.
		if row_min > cap:
			return inf
		prev, cur = cur, prev
	return prev[len(b)]


def _chain_push(chain, name):
	"""Append a segment to a chain key. Chain keys join segments
	length-prefixed (`<len>:<name>`), not with a bare NUL: NUL is legal in a
	quoted name, so a single field named "x\\0y" would impersonate the
	two-segment path x.y. Same injectivity reasoning as the merge key's cell
	encoding - and like it, the length unit is each binding's native one
	(code points here), because only injectivity matters."""
	return chain + str(len(name)) + ":" + name


def _chain_parts(chain):
	"""Decode a chain key back into its segments. Total: bails at the first
	shape the encoder can't have produced."""
	parts = []
	i = 0
	while i < len(chain):
		n = 0
		while i < len(chain) and "0" <= chain[i] <= "9":
			n = n * 10 + (ord(chain[i]) - 48)
			i += 1
		if i >= len(chain) or chain[i] != ":" or i + 1 + n > len(chain):
			break
		i += 1
		parts.append(chain[i:i + n])
		i += n
	return parts


def _first_index(paths):
	"""Schema paths bucketed by what their first segment accepts. A path can
	only match a chain whose first part is that segment's name, or anything at
	all when the segment is `*`, so a lookup plus the star bucket is the whole
	candidate set. Values are positions in the list the index was built from.
	Both callers ask "does any of these match", so bucket order cannot reach
	the answer."""
	by_name: dict = {}
	stars: list = []
	for i, segs in enumerate(paths):
		# A pathless entry keeps its old place in every candidate set: the scan
		# it replaces looked at one, and what it then did is unchanged.
		if segs and not segs[0].star:
			by_name.setdefault(segs[0].name, []).append(i)
		else:
			stars.append(i)
	return (by_name, stars)


def _candidates(idx, part):
	by_name, stars = idx
	named = by_name.get(part, ())
	return named if not stars else [*named, *stars]


def _star_legal(pats, idx, chain):
	"""Element-wise chain match against the star-bearing schema paths: a `*`
	segment matches any one name, and every prefix of a path is legal."""
	if not pats:
		return False
	parts = _chain_parts(chain)
	return any(
		len(pats[pi]) >= len(parts)
		and all(pats[pi][i].star or pats[pi][i].name == seg for i, seg in enumerate(parts))
		for pi in _candidates(idx, parts[0])
	)


def _chain_legal(cons, frags, set_idx, chain):
	"""Chain legality through fragment mounts: the general matcher - element-
	wise like _star_legal (stars wild, prefixes legal), and when a mount's whole
	path matched with chain left over, the remainder is retried against the
	mounted fragment's fields. Terminates: every descent consumes >= 1 part."""
	parts = _chain_parts(chain)
	return _chain_parts_legal(cons, frags, set_idx, parts)


def _chain_parts_legal(cons, frags, set_idx, parts):
	# Explicit stack of (fragment, constraints, parts consumed) rather than one
	# frame per mount: a chain at the depth cap descends that many mounts. A
	# state seen once is not walked again - two mounts of the same fragment at
	# the same depth used to be walked both, which is 2^depth on a chain that
	# ends unknown.
	stack = [("", cons, 0)]
	seen = set()
	while stack:
		name, cons, at = stack.pop()
		if (name, at) in seen:
			continue
		seen.add((name, at))
		rest = parts[at:]
		# The stack only descends with parts left over, and the sweep never
		# asks about an empty chain, so rest always has a first part to look up.
		idx = set_idx.get(name)
		order = range(len(cons)) if idx is None else _candidates(idx, rest[0])
		for ci in order:
			c = cons[ci]
			n = len(c.segs)
			k = min(len(rest), n)
			if all(c.segs[i].star or c.segs[i].name == rest[i] for i in range(k)):
				if len(rest) <= n:
					return True
				if c.inherits is not None:
					fcs = frags.get(c.inherits)
					if fcs is not None:
						stack.append((c.inherits, fcs, at + n))
	return False


def _v_suggest(siblings, parent_chain, name):
	"""Closest legal sibling name (same parent chain, schema order, edit
	distance <= 2) as "; did you mean 'x'?" - or nothing. Prose only, never
	contract. The sibling lists are prebuilt once per validate."""
	names = siblings.get(parent_chain)
	best = names.closest(name) if names is not None else None
	if best is None:
		return ""
	return f"; did you mean '{_diag_name(best)}'?"


# How many queries the scan answers before a chain gets its index. A few typos
# in a large section should not pay for indexing it.
_SUGGEST_INDEXED = 16
_SUGGEST_SCANS = 16


class _SuggestNames:
	"""The legal names under one parent chain, each once, in schema order.
	Every unknown field used to be compared with every sibling, and the list
	held one copy per schema field, so a document whose names all miss cost
	the schema times the document (20260918b item 10). Past the first few
	queries on a chain, each name of up to _SUGGEST_INDEXED characters is filed
	under every spelling it has with up to two characters deleted. Two names
	within edit distance 2 share such a spelling, so a query checks only the
	names its own spellings find. A longer name keeps the scan, filtered by
	length. The spellings are the dict keys themselves here, where the other
	bindings key on a hash of them: a hash written in Python costs more than
	the dict's own."""

	__slots__ = ("names", "seen", "queries", "index", "long", "stamp")

	def __init__(self):
		self.names = []
		self.seen = set()
		self.queries = 0
		self.index = None
		self.long = []
		# The query that last looked at each name, so a name found under
		# several spellings is measured once.
		self.stamp = []

	def push(self, name):
		if name not in self.seen:
			self.seen.add(name)
			self.names.append(name)

	def closest(self, name):
		self.queries += 1
		best = None
		names = self.names

		def consider(i):
			nonlocal best
			dist = _edit_distance(name, names[i], 2)
			if dist <= 2 and (best is None or (dist, i) < best):
				best = (dist, i)

		if self.queries <= _SUGGEST_SCANS:
			for i in range(len(names)):
				consider(i)
		else:
			if self.index is None:
				index: dict = {}
				for i, n in enumerate(names):
					if len(n) > _SUGGEST_INDEXED:
						self.long.append(i)
						continue
					for sp in _deletion_spellings(n):
						lst = index.setdefault(sp, [])
						if not lst or lst[-1] != i:
							lst.append(i)
				self.index = index
				self.stamp = [0] * len(names)
			stamp = self.stamp
			if len(name) <= _SUGGEST_INDEXED + 2:
				for sp in _deletion_spellings(name):
					for i in self.index.get(sp, ()):
						if stamp[i] != self.queries:
							stamp[i] = self.queries
							consider(i)
			for i in self.long:
				if abs(len(names[i]) - len(name)) <= 2:
					consider(i)
		return None if best is None else names[best[1]]


def _deletion_spellings(s):
	"""Each spelling of s with none, one or two of its characters deleted. The
	same spelling can come up more than once."""
	yield s
	for a in range(len(s)):
		one = s[:a] + s[a + 1:]
		yield one
		for b in range(a, len(one)):
			yield one[:b] + one[b + 1:]
