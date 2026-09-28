#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

# shcl CLI - the Python binding's command surface. Flags, output, and exit codes
# mirror the Rust reference exactly; the cicd cross-binding check compares them
# byte for byte, so any drift here fails the pipeline.

import errno
import math
import os
import signal
import stat
import sys

# The single-file library sits two directories up (lib in source/python/, CLI in
# source/python/cmd/shcl/, mirroring the Go layout).
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__)))))
import shcl

class _BestEffort:
	"""stderr, wrapped so a write that fails is dropped. A stream that cannot
	be written has nowhere to report that fact, and the document on stdout is
	still good - where an uncaught OSError would lose that too."""

	def __init__(self, stream):
		self._stream = stream

	def write(self, text):
		try:
			self._stream.write(text)
		except OSError:
			pass
		return len(text)

	def flush(self):
		try:
			self._stream.flush()
		except OSError:
			pass

	def __getattr__(self, name):
		return getattr(self._stream, name)


def write_failed(e):
	"""A stdout write that failed. A reader that closed early is nothing to
	report - nobody is there to read it - so that leaves quietly; anything
	else lost the output, which is the same failure as a file that could not
	be written. The stream is swapped for a sink so the interpreter's own
	exit-time flush does not fail again over the top of the exit code."""
	sys.stdout = open(os.devnull, "w", encoding="utf-8")  # noqa: SIM115
	if isinstance(e, BrokenPipeError):
		return 0
	sys.stderr.write(f"stdout: {e.strerror or e}\n")
	return 8


# Keep in step with source/rust/Cargo.toml, the canonical version source.
VERSION = "2.0.0"

# The build number, set only for a stamped build. The Rust CLI is the one the
# pipeline stamps; see its build.rs.
BUILD = ""

VERSION_LINE = "shcl v" + VERSION + (" build " + BUILD if BUILD else "")

HELP = """shcl - Simple Hierarchical Config Language (reference CLI)

Usage:
  shcl get [type] [options] FILE PATH    read one value (or array) at a path
  shcl set [--write|-w] [options] FILE   apply edits (--set, or ops on stdin);
                                         print FILE with the edited lines
                                         changed (or rewrite FILE in place
                                         with --write, which creates FILE
                                         when it is not there yet)
  shcl fmt [--write|-w] [options] FILE   print the canonical form (or rewrite
                                         FILE in place with --write)
  shcl check [options] FILE              load and print diagnostics
                                         (--schema=SCHEMA, or the file's own
                                         '##    Schema   PATH' line, also
                                         validates FILE against a schema)
  shcl init [--no-banner] --schema=S     print a commented starter config
                                         from a schema (required fields live,
                                         optional commented, wildcards noted)
  shcl count [options] FILE PATH         number of instances at a path
  shcl instances [options] FILE PATH     instance values at a path, one per line
  shcl children [options] FILE [PATH]    child field names under a path, one per
                                         line (the top level when PATH is left
                                         out)
  shcl paths [options] FILE              every field path in the document, one
                                         per line
  shcl migrate [options] FILE            rewrite a 2.x file for the current
                                         rules (print it, rewrite FILE with
                                         --write or -w, keeping the original
                                         as NAME_old_v2.EXT beside it, or name
                                         the lines it would change with
                                         --check)
  shcl tokens FILE                       each line's lexical spans, for seeing
                                         why the parser read a line as it did
                                         (every line on its own, raw bodies
                                         included)
  shcl explain [CODE]                    what a diagnostic code means (every
                                         code, one line each, when CODE is
                                         left out)
  shcl help [CMD] | version              this help (or one subcommand's, with
                                         CMD), or the version (also -h/--help,
                                         -v/-V/--version)
  shcl about | donate                    what shcl is, or how to support it
                                         (also --about, --donate)

set edits FILE, the base document. Edits go in as the repeatable --set,
--set-literal, --set-default, --set-literal-default and --remove options, which
persist with --write; given any of them, no ops are read from stdin. Raw blocks
go in only as a write-ops script on stdin, which can make the other edits too,
one op per line, tab-separated. FILE '-' follows stdin: the document when an
option holds the edits, an empty base when the ops script has stdin instead.
With --write, a FILE that does not exist yet is created. Lines the edits leave
alone come back as they were written; with --layer, or where the edited text
would not load back the same, the whole document comes out canonical, the way
fmt writes it. PATH ends at the first '=' outside quotes and brackets, so a
selector may hold one. Ops:
  int|float|bool|string|datetime<TAB>PATH<TAB>VALUE       set a scalar
  <type>-array<TAB>PATH<TAB>V1<TAB>V2...                  set an inline array
  <type>[-array]-default<TAB>...                          set only if absent
  literal[-default]<TAB>PATH<TAB>TEXT                     set from value syntax
  raw[-default]<TAB>PATH<TAB>INFO<TAB>CONTENT             set a raw block
  empty<TAB>PATH   comment<TAB>PATH<TAB>TEXT   remove<TAB>PATH
  clear-comments<TAB>PATH                                 drop comments above
  banner<TAB>on|off                                       add or drop info block
string/raw values decode \\n \\t \\\\; a line starting with # is a script comment.

Types (get only; default --string):
  --int --float --bool --datetime --string --raw --rawinfo --duration --size
  --array                                read the value as an array of the type
  --rawinfo reads a raw block's info-string (the fence tag), not its content
  --duration prints milliseconds and --size bytes; a bare number takes its
  unit from the field name (timeout-ms, cache_mb), else from --unit

Options (the subcommands each belongs to are in parentheses):
  --default=VALUE                        (get) value to print when the read is
                                         not Good (implies --on-bad=default; for
                                         arrays, substituted per bad slot)
  --on-bad=error|default|flag            (get) error: fail loudly; default:
                                         print the default; flag: print the
                                         value anyway and report via exit code
                                         (the default)
  --slots                                (get) prefix each line with its slot
                                         status and a tab (per element, or per
                                         wildcard slot)
  --unit=UNIT                            (get) the unit a bare number is in,
                                         for --duration (ms s m h d) or --size
                                         (B KB MB GB TB KiB MiB GiB TiB), when
                                         the field name gives none
  --decimal                              (get) --size reads KB to TB as powers
                                         of 1000, not 1024
  --no-banner                            (init, and set --write when it creates
                                         FILE) leave out the info block naming
                                         the format and pointing at its spec
  --write                                (fmt/set/migrate) rewrite FILE in
                                         place, spelled -w too, through a
                                         temp file and a rename; refused
                                         with a FILE of '-'
  --lossy                                (fmt/set/migrate) with --write, rewrite
                                         even when the load dropped lines this
                                         write would delete; without it the
                                         write refuses and nothing is changed
  --from-2x                              (migrate) the file was written for
                                         2.x, so rewrite the spellings the two
                                         rule sets read differently; without
                                         it those are left alone and migrate
                                         exits 7
  --check                                (fmt/migrate) print nothing and exit 6
                                         when fmt would change the file or
                                         migrate would rewrite a line (named on
                                         stderr), or 7 when --write would
                                         refuse it
  --strictness=loose|standard|strict     (get/set/fmt/check/count/instances/
                                         children/paths) or 1|2|3 (default
                                         standard)
  --schema=SCHEMA                        (check/init) validate FILE against a
                                         schema; adds V### diagnostics. check
                                         without it uses FILE's Schema line
  --layer=FILE                           (get/set/fmt/count/instances/children/
                                         paths) merge a lower-priority layer
                                         under FILE; repeatable, earlier =
                                         lower priority
  --set=PATH=VALUE                       (get/set/fmt/count/instances/children/
                                         paths) override one path as the top
                                         layer, after all files; repeatable. On
                                         'set' it is an edit to the document
                                         itself, so it persists with --write.
                                         VALUE goes in as data: its type still
                                         follows the text (8 is an int), but a
                                         comma or quote in it is content, not
                                         syntax
  --set-literal=PATH=TEXT                (same subcommands) as --set, except
                                         TEXT goes in as value
                                         syntax the way a file spells it, so
                                         'ports=80, 443' writes a two-element
                                         array. A # outside quotes ends the
                                         value; text spanning lines is rejected
  --set-default=PATH=VALUE               (same) as --set, but only when nothing
  --set-literal-default=PATH=TEXT        is at the path yet - the write-out-
                                         defaults half of the writer
  --remove=PATH                          (same) delete what is at the path,
                                         with its subtree. Removing nothing is
                                         not an error, but a PATH that cannot
                                         parse is
The five above share one ordered list, so two of them touching the same path
resolve in the order given. Raw blocks still go in through the ops script.

Value options accept either spelling: --default=VALUE or --default VALUE. In
the space form the next argument is taken as the value whatever it looks like,
so --default --int reads --int as the default. Use -- to end the options when a
FILE or PATH begins with a dash.
An option a subcommand does not use is a usage error, not ignored. Also
refused: --write with --layer; --write with --set outside 'set'; --write with a
FILE of '-'; --lossy without --write; --no-banner on 'set' without --write;
--check with --write; --layer=- on 'set'; --array with --raw or --rawinfo;
--default with --on-bad=error or --on-bad=flag; '-' named more than once across
FILE, --layer and --schema. Two options that ask for different answers are a
usage error whichever order they came in, and both are named: two different type
options, or one value option given two different values. Repeating an option
with the same value is allowed, and --layer and --set are ordered lists, so they
repeat.
Every subcommand that loads a document prints the load's diagnostics to stderr,
once per run; 'shcl explain CODE' gives the rule behind one of their codes. An
in-place write also refuses when the load dropped content the rewrite would
delete (--lossy overrides). migrate refuses a file that does not say which
rules it was written for, when the two readings differ (--from-2x says it is
2.x), and reports a 2.x binding it cannot carry.
FILE may be '-' for stdin. With --layer, FILE is the highest file layer and
each --layer is merged under it in order; --set applies last. 'fmt' with
layers prints the merged canonical document.

Exit codes: 0 good, 1 usage error, 2 empty, 3 not found, 4 bad type,
5 multiple instances, 6 check failed, strict load failed, init's schema has
faults, or --check found a rewrite to make, 7 in-place write refused
(--lossy overrides) or migrate left something behind, 8 a file or stream could
not be read or written.
"""

# About and donate are stdout, so they are byte-for-byte contracts across the
# bindings the same way the help text and the init banner are. The version
# concatenates from the constant above so it cannot drift from `shcl version`.
ABOUT = VERSION_LINE + """
Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ].
Project: https://github.com/yottacore/shcl
Licensed under the MIT License. Full text at:
  https://spdx.org/licenses/MIT.html
No warranty.

Simple Hierarchical Config Language. Forgiving to write, predictable to read.
Types live in your code, not in the file, so nothing is guessed at parse time.
One broken line is skipped with a note instead of taking down the whole file.
"""

DONATE = """shcl is free software under the MIT License, and stays that way.

If it saves you time and you want to give something back:
  https://github.com/sponsors/jim-collier
  https://ko-fi.com/jimcollier

A star on the project, a clear bug report, or a mention to someone who needs it
are worth just as much.
"""


# The diagnostic code table behind `shcl explain`. One entry per code: a
# `CODE|severity|summary` head line, then its detail indented two spaces.
# spec.md's diagnostic tables are the long form; this is the same rules cut to
# what a terminal shows. Like the help text it is byte-for-byte across the
# bindings, and crosscheck compares every code.
CODES = """E001|error|field line under a parent holding stacked '*' list elements
  A parent holds list elements or named children, not both. The field line
  is kept and the elements stay.
E002|error|value after a last-segment selector (a.b[X]: v)
  The selector already says which instance, so the value has nowhere to go
  and is ignored. Put the value on the line that creates the instance.
E003|error|selector names an instance that does not exist
  a[5].b where there is one a. An index selects an existing instance by
  position and never creates one, so a binding line should select by value
  instead. In a file the index is the bare [5], since a # opens a comment.
E004|error|wildcard selector on a binding line
  Wildcards read every instance, so there is no single one to write to.
  They are query-only.
E005|error|unterminated raw block (closing fence never found)
  The block runs to the end of the file. Close it with a fence at the
  opening fence's indent.
E006|error|raw-block fence with no parent field to bind to
  A raw block is a field's value, so a fence needs a field line above it.
E007|error|stacked '*' list element with no parent field
  A '* value' line is an element of the field above it.
E008|error|stacked '*' list element under a parent with field children
  The parent already holds named children, so the element is dropped.
E009|error|empty stacked '*' list element
  A '*' with nothing after it has no value to add.
E010|error|bare comma in a stacked '*' list element
  The stacked form is one element per line. Quote the comma, or write the
  whole array on the field's own line.
E011|error|stacked '*' element for a field that already has a value
  The field's value is kept and the element is ignored. A field is spelled
  one way or the other, not both.
E012|error|indentation matches no open level
  The line is skipped, and anything written deeper is skipped with it
  (E018). A save writes them back as they were when the indent holds a
  space. One indented with tabs alone would bind there, so it is lost.
  Indent to a column some open parent already uses.
E013|error|malformed '*' line ('*' not followed by a space)
  The line is skipped, and what is written under it goes with it.
E014|error|malformed line skipped (the message names the reason)
  The reason and the byte column the line went wrong at are in the prose.
  A quote that never closes in a field name arrives here too.
E015|error|missing colon (repaired as an empty value)
  The name binds with no value rather than the line being dropped.
E016|error|nesting deeper than the 512-level cap (line skipped)
  The cap is what makes any loadable document safe to format, merge and
  copy in every binding.
E017|error|a quote that never closes with the matching quote last
  In a value element or a selector body. The piece is read bare, quotes and
  all, and a comma or comment after it still ends it. The same typo in a
  field name is E014.
E018|error|line written under a line that was skipped
  It is skipped with it, so a skipped line's block never re-parents one
  level up. Fix the line above and this one comes back with it.
E019|error|a value beginning with '[', the way JSON and YAML spell arrays
  An array is comma-separated and written without brackets: ports: 80, 443.
  A '[' after the colon is never a selector, and reading the text without
  its brackets would bake a changed value in, so the line is kept verbatim:
  it binds nothing, a read on it is NotFound, and nothing counts as lost.
E020|error|node cap exceeded (fires only under a caller-supplied cap)
  The parse stopped there and the unparsed remainder counts as lost, so a
  later save refuses rather than writing a truncated file.
E021|error|array longer than the caller-supplied element cap
  The line is skipped whole rather than truncated to a value the author
  never wrote. A fence line's info string is split the same way.
E022|error/hint|the diagnostics list was cut at the caller-supplied cap
  This entry ends the list and counts what was not listed. An error when
  any unlisted one was, so a scan for errors still finds one; a hint
  otherwise.
E023|error|a bad escape in double quotes
  Only \\t, \\n, \\\\, \\", \\', \\uXXXX and \\UXXXXXXXX are escapes there, and a
  \\u or \\U escape must name a character. A Windows path typed in double
  quotes is the usual cause, and its \\n would already be a newline, so the
  line is kept verbatim: it binds nothing and a read on it is NotFound. Use
  single quotes or no quotes, or double each backslash.
H001|hint|repeated bare leaf (an array spelled as repeated lines)
  Repeated leaves are legal - that is how instances are written - but
  'tags: red' twice and 'tags: red, blue' look alike, so the parser says
  which one it read. A schema's repeat bound above 1 disavows it.
H002|hint|a binding merged with a non-adjacent earlier one
  Same name and value, so the two combine. Legal, and only the parser can
  see it happened. The prose names the earlier line, and a schema can
  disavow it per section with 'reopen: true'.
H003|hint|a stacked '*' element spelled like a field binding
  '* name: value' is the YAML habit for a list of objects. Here it is one
  string element, the text 'name: value'. Quote it to keep the string; a
  list of objects is written as instances of a field.
H004|hint|a Windows path in double quotes with a \\t or \\n escape
  "C:\\temp" reads as C:, a tab, then emp. The line loads and saves as
  usual, since that is legal, but a path almost never means it. Single
  quotes or no quotes keep each backslash as written; so does doubling it.
H005|hint|a value in another unit than its field name ends in
  timeout-ms: 5s reads as 5000 milliseconds, since a unit in the value
  wins over the one the name gives a bare number. Legal, and often a slip.
V001|error|unknown field
  No schema path covers it. Only the topmost unknown node is reported; its
  subtree is skipped. The prose carries the did-you-mean suggestion.
V002|error|required path missing
  Declared 'required: yes' and nothing in the document resolves it.
V003|error|wrong type
  The value does not read as the declared type.
V004|error|value not in the allowed set
  The line number is the node, at its first offending element.
V005|error|below the declared min
  The prose names the bound and the value that missed it.
V006|error|above the declared max
  The prose names the bound and the value that missed it.
V007|error|instance count out of repeat bounds
  Too few or too many instances of a field the schema bounds with 'repeat'.
V090|error|unknown schema key
  A schema fault: the key is dropped and the rest of the schema still
  checks the document. The line number is a schema line.
V091|error|unknown schema type name
  A schema fault, on a schema line.
V092|error|bad schema constraint value
  A schema fault, on a schema line. Also covers min or max without a
  numeric type, and 'allowed' with 'type: raw'.
V093|error|bad schema path
  A schema fault, on a schema line. The path spelling could not be read, so
  the unknown-field sweep turns off with it.
V094|error|bad fragment declaration
  No name, a duplicate, or a non-field key inside. A schema fault, on a
  schema line.
V095|error|'inherits' names no declared fragment
  A schema fault, on a schema line. A mount naming a missing fragment
  checks nothing at the mount.
V096|error|schema expands to more fields than generation allows
  Generation lays every path out flat, so mounts multiply. The line number
  is 0: this is about the output, not a schema line.
V097|error|generated output does not load, or fails its own schema
  init checks its own output before returning it, so a starter config that
  would fail its first check is a fault instead. A default outside its
  field's constraints is one cause. A required path nothing can generate is
  the other, such as one with a [#N] selector or a * name. Line 0.
V099|error|schema failed to load
  The schema had error diagnostics of its own; they are printed above this
  with their own line numbers. Line 0.
"""


def status_code(st):
	return st.value


class _SetOpt:
	# One edit from the --set family. All five spellings share a list so they
	# apply in the order given, which is what decides the winner when two target
	# the same path.
	__slots__ = ("path", "value", "kind")

	def __init__(self, path, value, kind):
		self.path = path
		self.value = value
		self.kind = kind

	def apply(self, doc):
		if self.kind == "--set-literal":
			return doc.set_literal(self.path, self.value)
		if self.kind == "--set-default":
			return doc.set_string_default(self.path, self.value)
		if self.kind == "--set-literal-default":
			return doc.set_literal_default(self.path, self.value)
		if self.kind == "--remove":
			# Removing nothing is not a failure, the same as the ops script's
			# `remove`: the point of the option is the path's absence after.
			doc.remove(self.path)
			return True
		return doc.set_string(self.path, self.value)

	def opt(self):
		return self.kind


class _Opts:
	__slots__ = ("kind", "kind_opt", "kind_text", "clash_opt", "clash", "array", "slots", "default", "on_bad", "on_bad_arg", "on_bad_text", "strictness", "strictness_text", "write", "lossy", "from_2x", "check", "no_banner", "schema", "unit", "decimal", "layers", "sets", "args", "seen", "swallowed")

	def __init__(self):
		self.kind = "string"     # int|float|bool|datetime|string|raw
		# Which type option was given, if any. kind cannot answer that, since it
		# starts at the default type.
		self.kind_opt = None
		# As it was typed, for the competing-pair message.
		self.kind_text = None
		# The first competing pair the line held. Two options that ask for
		# different answers are a usage error whichever order they came in, so the
		# pair is recorded here rather than refused on the spot and the "not valid
		# for this subcommand" answer still comes first. clash_opt is set when the
		# pair is one option repeated with a different value, in which case the
		# two entries are the values; otherwise they are whole option spellings.
		self.clash_opt = None
		self.clash = None
		self.array = False
		self.slots = False
		self.default = None
		self.on_bad = "flag"     # error|default|flag
		# What an explicit --on-bad asked for, whatever the order. --default sets
		# on_bad too, so without this the two options silently overwrote each
		# other and which one survived depended on which came last.
		self.on_bad_arg = None
		self.on_bad_text = None
		self.strictness = shcl.Strictness.Standard
		self.strictness_text = None
		self.schema = None
		self.unit = None         # --unit, read against the type at check time
		self.decimal = False
		self.write = False
		self.lossy = False
		self.from_2x = False
		self.check = False
		self.no_banner = False
		self.layers = []         # lower-priority layers, in listed order
		self.sets = []           # final override layer: _SetOpt, in the order given
		self.args = []           # positional: FILE [PATH]
		self.seen = []           # canonical names of options given, for per-command validation
		# A value option in space form that took the LAST word on the line. That
		# word is usually the FILE, and the usage line alone never says so.
		self.swallowed = None    # (option, value)


def _ascii_lower(s):
	# ASCII-only folding, as the reference's to_ascii_lowercase; str.lower()
	# folds the whole of Unicode.
	return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in s)


def _ascii_upper(s):
	# The other way, as to_ascii_uppercase. str.upper() turns a long s into S,
	# so a word that is not ASCII could look up or suggest a code.
	return "".join(chr(ord(c) - 32) if "a" <= c <= "z" else c for c in s)


def known_option(name):
	# A real option by any spelling, -w included. The suggestions draw on
	# option_names alone, which leaves the short form out.
	return name == "-w" or name in option_names()


def note_clash(o, opt, a, b):
	# Record the first competing pair. Only the first is kept: the line is already
	# a usage error, and a second pair would just change which one gets named.
	if o.clash is None:
		o.clash_opt = opt
		o.clash = (a, b)


def _set_value_opt(o, name, v):
	if name == "--default":
		if o.default is not None and o.default != v:
			note_clash(o, "--default", o.default, v)
		o.default = v
		o.on_bad = "default"
		o.seen.append("--default")
	elif name == "--on-bad":
		low = _ascii_lower(v)
		if low not in ("error", "default", "flag"):
			raise ValueError(f"bad --on-bad value: {v} (see --help)")
		if o.on_bad_text is not None and o.on_bad_arg != low:
			note_clash(o, "--on-bad", o.on_bad_text, v)
		o.on_bad = low
		o.on_bad_arg = low
		o.on_bad_text = v
		o.seen.append("--on-bad")
	elif name == "--strictness":
		s = shcl.Strictness.from_arg(v)
		if s is None:
			raise ValueError(f"bad --strictness value: {v} (see --help)")
		if o.strictness_text is not None and o.strictness != s:
			note_clash(o, "--strictness", o.strictness_text, v)
		o.strictness = s
		o.strictness_text = v
		o.seen.append("--strictness")
	elif name == "--schema":
		if o.schema is not None and o.schema != v:
			note_clash(o, "--schema", o.schema, v)
		o.schema = v
		o.seen.append("--schema")
	elif name == "--unit":
		if o.unit is not None and o.unit != v:
			note_clash(o, "--unit", o.unit, v)
		o.unit = v
		o.seen.append("--unit")
	elif name == "--layer":
		o.layers.append(v)
		o.seen.append("--layer")
	elif name == "--remove":
		if v == "":
			raise ValueError("bad --remove value (want PATH) (see --help)")
		if unusable_path(shcl.Document.parse(""), v):
			raise ValueError(f"bad --remove value (not a usable path): {v} (see --help)")
		o.sets.append(_SetOpt(v, "", "--remove"))
		o.seen.append("--remove")
	elif name in ("--set", "--set-literal", "--set-default", "--set-literal-default"):
		ps = split_set(v)
		if ps is None or ps[0] == "":
			raise ValueError(f"bad {name} value (want PATH=VALUE, quotes and brackets balanced): {v} (see --help)")
		o.sets.append(_SetOpt(ps[0], ps[1], name))
		o.seen.append(name)


def unusable_path(doc, path):
	# A path no document can hold, which a remove would take as a miss and
	# exit 0: one the scanner rejects, or one with a value part. A missing
	# path or a wildcard is still fine.
	return doc.write_reason(path) in (shcl.WriteReason.BadPath, shcl.WriteReason.ValueInPath)


def split_set(arg):
	# PATH=VALUE at the first `=` outside quotes and brackets, so a selector
	# holding one (`x[a=b].c=1`) still addresses its instance. The tokenizer
	# reads the path half with `=` as its separator, so quotes and brackets
	# mean here exactly what they mean in a file; an argument whose path half
	# is not a path at all has no `=` to split at. The offset is a byte
	# offset, so the split is made on the bytes.
	tok = shcl.Tokens()
	shcl.tokenize(arg, "=", True, shcl.RULES_CURRENT, tok)
	if tok.sep is None:
		return None
	return tok.src[:tok.sep].decode("utf-8"), tok.src[tok.sep + 1:].decode("utf-8")


def asked_for(argv):
	# Did the command line ask for one of the informational outputs? Only tokens
	# in option position count: the value of a value-taking option and anything
	# after `--` are data (a FILE or PATH spelled `-h` needs the `--` anyway,
	# since the option parser would refuse it). Scanning values too once let a
	# read of a missing path answer with the help text and exit 0.
	i = 0
	while i < len(argv):
		a = argv[i]
		if a in ("-h", "--help"):
			return "help"
		if a in ("-v", "-V", "--version"):
			return "version"
		if a == "--about":
			return "about"
		if a == "--donate":
			return "donate"
		if a == "--":
			return None
		if a in ("--default", "--on-bad", "--strictness", "--schema", "--unit", "--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove"):
			i += 1
		i += 1
	return None


# The type options, as one list. kind_from_opt is still the reader; this is for
# the places that need the spellings themselves - the did-you-mean on a typo,
# and the per-subcommand help.
TYPE_OPTS = ("--int", "--float", "--bool", "--datetime", "--string", "--raw", "--rawinfo", "--duration", "--size")


def kind_from_opt(opt):
	# The type option's kind, or None when the token is not one.
	if opt in TYPE_OPTS:
		return opt[2:]
	return None


def edit_distance(a, b, cap):
	# Levenshtein distance capped at cap; past it, cap + 1. The validator has one
	# of these for schema field names, but it is private and the CLI's lists are
	# a dozen short words, so the CLI computes its own.
	inf = cap + 1
	if abs(len(a) - len(b)) > cap:
		return inf
	prev = list(range(len(b) + 1))
	for i in range(1, len(a) + 1):
		cur = [i] + [0] * len(b)
		for j in range(1, len(b) + 1):
			cost = 0 if a[i - 1] == b[j - 1] else 1
			cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		prev = cur
	return min(prev[len(b)], inf)


def suggest(cands, word):
	# "; did you mean 'x'?" for the nearest candidate within two edits, or
	# nothing. Same wording the validator's unknown-field suggestion uses, and
	# prose either way - a typo's exit code is 1 whether or not this has an idea.
	# Every candidate is ASCII, and C counts distance in bytes where the other
	# three count characters, so a word that is not ASCII gets no suggestion
	# rather than one the four bindings could disagree on.
	if not word.isascii():
		return ""
	w = _ascii_lower(word)
	best, best_dist = "", 3
	for c in cands:
		d = edit_distance(w, _ascii_lower(c), 2)
		if d <= 2 and d < best_dist:
			best, best_dist = c, d
	return f"; did you mean '{best}'?" if best else ""


def command_names():
	# Every command word, for the same. The informational four are commands to a
	# user typing one, whatever the dispatch calls them.
	return COMMANDS + ("help", "version", "about", "donate")


def option_names():
	# Every option spelling some subcommand takes. Built from the table
	# check_opts judges against, so a new option becomes suggestable the moment
	# it is accepted somewhere. The informational flags are in no subcommand's
	# table but are options to anyone typing one.
	v = ["--help", "--version", "--about", "--donate"]
	for cmd in COMMANDS:
		for o in allowed_opts(cmd):
			names = TYPE_OPTS if o == "--<type>" else (o,)
			for name in names:
				if name not in v:
					v.append(name)
	return v


def parse_opts(argv):
	o = _Opts()
	# Value-taking options accept both --opt=VALUE and the space form --opt VALUE.
	i = 0
	while i < len(argv):
		a = argv[i]
		# Everything after `--` is positional, so a file or path may begin
		# with a dash.
		if a == "--":
			o.args.extend(argv[i + 1:])
			return o
		k = kind_from_opt(a)
		if k is not None:
			if o.kind_opt is not None and o.kind_opt != k:
				note_clash(o, None, o.kind_text, a)
			o.kind = k
			o.kind_opt = k
			o.kind_text = a
			o.seen.append("--<type>")
			i += 1
			continue
		if a == "--array":
			o.array = True
			o.seen.append("--array")
		elif a == "--slots":
			o.slots = True
			o.seen.append("--slots")
		elif a == "--no-banner":
			o.no_banner = True
			o.seen.append("--no-banner")
		elif a == "--decimal":
			o.decimal = True
			o.seen.append("--decimal")
		elif a in ("--write", "-w"):
			o.write = True
			o.seen.append("--write")
		elif a == "--lossy":
			o.lossy = True
			o.seen.append("--lossy")
		elif a == "--from-2x":
			o.from_2x = True
			o.seen.append("--from-2x")
		elif a == "--check":
			o.check = True
			o.seen.append("--check")
		elif a in ("--default", "--on-bad", "--strictness", "--schema", "--unit", "--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove"):
			i += 1
			if i >= len(argv):
				raise ValueError(f"missing value for {a} (try {a}=VALUE)")
			_set_value_opt(o, a, argv[i])
			if i + 1 == len(argv):
				o.swallowed = (a, argv[i])
		elif a.startswith("--default="):
			_set_value_opt(o, "--default", a[len("--default="):])
		elif a.startswith("--on-bad="):
			_set_value_opt(o, "--on-bad", a[len("--on-bad="):])
		elif a.startswith("--strictness="):
			_set_value_opt(o, "--strictness", a[len("--strictness="):])
		elif a.startswith("--schema="):
			_set_value_opt(o, "--schema", a[len("--schema="):])
		elif a.startswith("--unit="):
			_set_value_opt(o, "--unit", a[len("--unit="):])
		elif a.startswith("--layer="):
			_set_value_opt(o, "--layer", a[len("--layer="):])
		elif a.startswith("--set-literal-default="):
			_set_value_opt(o, "--set-literal-default", a[len("--set-literal-default="):])
		elif a.startswith("--set-literal="):
			_set_value_opt(o, "--set-literal", a[len("--set-literal="):])
		elif a.startswith("--set-default="):
			_set_value_opt(o, "--set-default", a[len("--set-default="):])
		elif a.startswith("--remove="):
			_set_value_opt(o, "--remove", a[len("--remove="):])
		elif a.startswith("--set="):
			_set_value_opt(o, "--set", a[len("--set="):])
		elif a.startswith("-") and len(a) > 1:
			# The suggestion is against the name half: `--stricness=1` is a typo
			# in the option, not in a spelling that includes a value.
			name = a.split("=")[0]
			# Every value option is matched above, so a real name here is a flag
			# given a value. Calling it unknown would suggest it back.
			if known_option(name):
				raise ValueError(f"option {name} takes no value (see --help)")
			raise ValueError(f"unknown option: {a}{suggest(option_names(), name)} (see --help)")
		else:
			o.args.append(a)
		i += 1
	return o


# A file or stream that could not be read or written. Its own code since a
# script's remedy - fix the path, the permissions, the disk - has nothing to do
# with the remedy for a usage error, which keeps 1.
EXIT_IO = 8


def write_target_ok(file):
	# A --write FILE is a regular file or nothing yet. Asked before the read,
	# since reading a FIFO takes what was written to it and the save would then
	# refuse it anyway, and since a read of windows CON waits on the console
	# rather than returning. A directory is left to the read, which names it.
	try:
		st = os.stat(file)
	except (OSError, ValueError):
		# A windows reserved name with no device behind it is not there to
		# stat, and it still cannot be written. It resolves into the device
		# namespace from whatever directory it is typed in, which is what the
		# full path shows.
		if sys.platform == "win32":
			try:
				full = os.path.abspath(file)
			except (OSError, ValueError):
				return True
			# A drive after the prefix is a volume path to a file that is not
			# there yet, which a create has to be let through (20260926 item 8).
			drive = len(full) >= 6 and full[4].isascii() and full[4].isalpha() and full[5] == ":"
			if full.startswith("\\\\.\\") and not drive:
				sys.stderr.write(f"{file}: not a regular file\n")
				return False
		return True
	if not stat.S_ISREG(st.st_mode) and not stat.S_ISDIR(st.st_mode):
		sys.stderr.write(f"{file}: not a regular file\n")
		return False
	return True


def read_input(file):
	if file == "-":
		try:
			data = sys.stdin.buffer.read()
		except OSError as e:
			# A stdin that is not attached at all reads as an empty document.
			# POSIX says EBADF; windows answers invalid handle or invalid
			# function depending on how the shell closed it.
			if e.errno not in (errno.EBADF, errno.EINVAL) and getattr(e, "winerror", None) not in (1, 6):
				raise
			data = b""
	else:
		# The message for reading a directory is the platform's, and windows
		# spells it four different ways depending on the binding. Say it here.
		if os.path.isdir(file):
			raise OSError(f"{file}: Is a directory")
		# FILE: and the system's own message, as the UI guide has it, not
		# Python's "[Errno 2] ..." form.
		try:
			with open(file, "rb") as f:
				data = f.read()
		except OSError as e:
			raise OSError(f"{file}: {e.strerror or e}") from e
	# The reference reads as UTF-8 and fails on bad bytes; match its exit path.
	try:
		return data.decode("utf-8")
	except UnicodeDecodeError as e:
		raise ValueError(f"{file}: stream did not contain valid UTF-8") from e


def load_doc_from(file, text, strictness, keep=False):
	# Returns (doc, None) or (None, code). On strict load failure, prints the
	# diagnostic lines to stderr, labeled with the file the text came from so
	# a strict failure in one layer of a fold says which layer, and reports 6.
	try:
		if keep:
			return shcl.Document.parse_keep_lines(text, strictness), None
		return shcl.Document.parse_with(text, strictness), None
	except shcl.LoadError as le:
		say_diagnostics_from(file, le.diagnostics)
		errors = sum(1 for d in le.diagnostics if d.severity == shcl.Severity.Error)
		sys.stderr.write(f"strict load failed: {errors} error diagnostic(s)\n")
		return None, 6


def unchanged_since_read(file, before):
	# FILE still holds the bytes the load read. `set` waits on stdin between the
	# load and the save, and an edit made in that wait was reverted at exit 0.
	# A gap is left between this read and the publish, the width of one save.
	try:
		with open(file, "rb") as fh:
			if fh.read() == before.encode("utf-8"):
				return True
	except (OSError, ValueError):
		pass
	sys.stderr.write(f"{file}: changed since it was read; nothing written\n")
	return False


def write_back(doc, file, o, read=None, keep=False):
	# The in-place half of fmt/set. Overwriting the source is the one place a
	# recovered load turns destructive, so the save runs through the library's
	# own gate rather than a second copy of the rule - the CLI and a consumer
	# program cannot then disagree about which rewrites are safe. read is the
	# bytes FILE held when the command read it, and None when this write is
	# creating FILE.
	if read is not None and not unchanged_since_read(file, read):
		return EXIT_IO
	# Nothing to write: what the save would publish is already on disk. A
	# rewrite would give the file a new inode and mtime for nothing, so an
	# idempotent --set-default in a provisioning script reported a change on
	# every run, watchers fired, other hard links broke, and a canonical file
	# in a read-only directory failed. The refusal comes first: a load that
	# dropped content refuses the write whatever the bytes say, unless the
	# lines were kept, which writes the dropped lines back as they were.
	text, kept = doc.to_text_keep_lines() if keep else (doc.to_canonical(), False)
	if read is not None and (o.lossy or kept or doc.lost_count() == 0) and text == read:
		return 0
	# The text is already built, so the line-keeping save writes it rather than
	# building it again, with the same refusal save_file_keep_lines makes
	# (20260926 idea 3).
	try:
		if o.lossy and keep:
			err = shcl.write_file_atomic(file, text)
			if err is not None:
				raise shcl.SaveFailed(err)
		elif o.lossy:
			doc.save_file_lossy(file)
		elif keep and not kept and doc.lost_count() > 0:
			raise shcl.SaveRefused(file, doc.lost_count())
		elif keep:
			err = shcl.write_file_atomic(file, text)
			if err is not None:
				raise shcl.SaveFailed(err)
		else:
			doc.save_file(file)
		# A created file is the one write with nothing to compare against
		# afterwards, and a typo in the name used to end at exit 0 with an
		# empty stderr and a new file nobody asked for.
		if read is None:
			sys.stderr.write(f"{file}: created\n")
		# A save meant to keep the lines rewrote the whole file, and that is
		# worth a line (20260926 idea 2).
		if keep and not kept:
			sys.stderr.write(f"{file}: rewritten in the canonical form; the lines could not be kept as they were\n")
		return 0
	# The rule stays in the library; only the wording is the CLI's, because the
	# override a user has here is a flag, not a function.
	except shcl.SaveRefused as e:
		sys.stderr.write(f"{file}: refusing to rewrite: the load dropped {e.lost} line(s)/value(s) this write would delete (--lossy overrides)\n")
		return 7
	except shcl.SaveError as e:
		sys.stderr.write(str(e) + "\n")
	return EXIT_IO


def load_layered(o, file):
	# Load file with o's lower-priority --layer files underneath and its --set
	# overrides on top - the layered-load fold. Every layer parses at the
	# requested strictness; a strict-load failure on any layer aborts like a
	# single-file strict failure. Returns (doc, None) or (None, code).
	# It prints every layer's diagnostics itself, lowest first, before the --set
	# overrides run: they belong to the load, and a refused edit used to return
	# with nothing said about them. A merge does not carry diagnostics over, so
	# reading them off the merged document drops the ones for FILE itself, which
	# is the one the caller named.
	doc, _, code = load_layered_from(o, file, None, False)
	return doc, code


def load_layered_from(o, file, given, keep):
	# The same fold with FILE's text given rather than read, which is how `set`
	# creates a file or takes an empty document, and FILE's text handed back.
	# `set` kept its own copy of the fold, and twice a fix to this one missed
	# it. Returns (doc, text, None) or (None, "", code).
	texts = [read_input(lf) for lf in o.layers]
	texts.append(read_input(file) if given is None else given)
	# Lowest layer first, each labeled with its own file when there is more than
	# one: the line numbers share a space on the screen otherwise, and two layers
	# with a bad line 2 printed the same thing twice.
	names = list(o.layers) + [file]
	def label(i):
		return names[i] if len(names) > 1 else ""
	# Only a document with no layers under it keeps its lines: a merge drops them.
	doc, code = load_doc_from(label(0), texts[0], o.strictness, keep and len(texts) == 1)
	if doc is None:
		return None, "", code
	say_diagnostics_from(label(0), doc.diagnostics())
	for i, t in enumerate(texts[1:]):
		over, c = load_doc_from(label(i + 1), t, o.strictness)
		if over is None:
			return None, "", c
		say_diagnostics_from(label(i + 1), over.diagnostics())
		doc.merge(over)
	for st in o.sets:
		if not st.apply(doc):
			why = describe_refusal(doc, st.path, "the value text is not one value")
			sys.stderr.write(f"{st.opt()}: cannot write {st.path}: {why}\n")
			return None, "", 1
	return doc, texts[-1], None


def allowed_opts(cmd):
	# The options each subcommand takes. check_opts judges against it, the
	# per-subcommand help is cut from the full help with it, and the shell
	# completions carry the same table (check-completions.bash diffs the two).
	if cmd == "get":
		allowed = ("--<type>", "--array", "--slots", "--unit", "--decimal", "--default", "--on-bad", "--strictness", "--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove")
	elif cmd == "set":
		allowed = ("--strictness", "--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove", "--write", "--lossy", "--no-banner")
	elif cmd == "fmt":
		allowed = ("--write", "--lossy", "--check", "--strictness", "--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove")
	elif cmd == "check":
		allowed = ("--strictness", "--schema")
	elif cmd == "init":
		allowed = ("--schema", "--no-banner")
	elif cmd == "migrate":
		allowed = ("--write", "--lossy", "--from-2x", "--check")
	elif cmd in ("tokens", "explain"):
		allowed = ()
	elif cmd in ("count", "instances", "children", "paths"):
		allowed = ("--strictness", "--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove")
	else:
		allowed = ()
	return allowed


def help_for(cmd):
	# One subcommand's slice of the help: its usage entry, the type block when it
	# takes one, and the option entries allowed_opts lets it have. Cut from the
	# full help rather than written out a second time, so the two cannot drift
	# and the four bindings stay byte-identical for free. An entry keeps the
	# "(get)" style annotation it carries there, which still reads true.
	lines = HELP.split("\n")
	out = ["Usage:"]
	want = f"  shcl {cmd} "
	taking = False
	for line in lines:
		if line.startswith("  shcl "):
			taking = line.startswith(want)
		elif taking and not line.startswith("   "):
			taking = False
		if taking:
			out.append(line)
	# A paragraph of the full help that opens with the subcommand's own name is
	# that subcommand's - today that is set's write-ops block, which is the half
	# of set a user most needs in front of them.
	for i, line in enumerate(lines):
		if line.startswith(cmd + " "):
			out.append("")
			for para in lines[i:]:
				if not para:
					break
				out.append(para)
			break
	allowed = allowed_opts(cmd)
	if "--<type>" in allowed:
		for i, line in enumerate(lines):
			if line.startswith("Types ("):
				out.append("")
				for t in lines[i:]:
					if not t:
						break
					out.append(t)
				break
	# The option entries, in the order the full help lists them. A head line is
	# `  --name`; the deeper-indented lines under it are its text, and the first
	# line at column zero ends the block.
	entries = []
	in_block = False
	keep = False
	for line in lines:
		if not in_block:
			in_block = line.startswith("Options (")
			continue
		if line.startswith("  --"):
			name = line[2:].replace("=", " ").split(" ")[0]
			keep = name in allowed
		elif not line.startswith("   "):
			break
		if keep:
			entries.append(line)
	if entries:
		out.append("")
		out.append("Options (the subcommands each belongs to are in parentheses):")
		out.extend(entries)
	else:
		out.append("")
		out.append(f"{cmd} takes no options.")
	out.append("")
	out.append("See 'shcl help' for the full text, and 'shcl explain CODE' for a code.")
	return "\n".join(out) + "\n"


def check_opts(cmd, o):
	# Every option must be meaningful for its subcommand; an option that would be
	# silently ignored (`set --write` before it existed, `--schema` on `get`) is a
	# usage error instead. Returns an exit code, or None to proceed.
	allowed = allowed_opts(cmd)
	for s in o.seen:
		if s not in allowed:
			if s == "--<type>":
				sys.stderr.write(f"type options are not valid for {cmd} (see --help)\n")
			elif cmd == "init" and s == "--strictness":
				# Deliberate, not an oversight: the schema is a program artifact,
				# so it always loads at Standard - the same rule `check --schema`
				# follows for the schema half.
				sys.stderr.write(
					"option --strictness not valid for init: a schema always loads at standard strictness, being a program artifact rather than user data (see --help)\n"
				)
			elif cmd == "check" and s in ("--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove"):
				# The one refusal a user is likely to want anyway: check reports
				# line numbers, and a merged document has no single file to
				# number against. Naming the pipeline turns a dead end into a
				# one-liner.
				sys.stderr.write(
					f"option {s} not valid for check: diagnostics cite line numbers, which a merged document has none of. Pipe instead: shcl fmt {s} ... FILE | shcl check --schema=SCHEMA -\n"
				)
			else:
				sys.stderr.write(f"option {s} not valid for {cmd} (see --help)\n")
			return 1
	# Options that ask for different answers used to resolve last-wins with
	# nothing said, so which answer you got depended on typing order. Two type
	# options are one case, one value option given two values the other.
	# Repeating an option with the same value competes with nothing and stays
	# allowed, and so do --layer and --set, which are ordered lists.
	if o.clash is not None:
		a, b = o.clash
		if o.clash_opt is not None:
			sys.stderr.write(f"{o.clash_opt}={a} cannot be combined with {o.clash_opt}={b} (see --help)\n")
		else:
			sys.stderr.write(f"{a} cannot be combined with {b} (see --help)\n")
		return 1
	# --unit and --decimal say how to read a bare number, which only the
	# duration and size reads have.
	if o.unit is not None and o.kind not in ("duration", "size"):
		sys.stderr.write("--unit needs --duration or --size (see --help)\n")
		return 1
	if o.decimal and o.kind != "size":
		sys.stderr.write("--decimal needs --size (see --help)\n")
		return 1
	if o.unit is not None:
		unit_of = shcl.DurationUnit.from_spelling if o.kind == "duration" else shcl.SizeUnit.from_spelling
		if unit_of(o.unit) is None:
			sys.stderr.write(f"bad --unit value for --{o.kind}: {o.unit} (see --help)\n")
			return 1
	# Writing back the merged document would fold the lower layers permanently
	# into the top file, which is the opposite of what layering is for. On 'set'
	# the --set values are edits to the document rather than a layer over it, so
	# persisting them is the whole point; everywhere else they stay ephemeral.
	if o.write and o.layers:
		sys.stderr.write("--write cannot be combined with --layer (see --help)\n")
		return 1
	if o.write and o.sets and cmd != "set":
		sys.stderr.write(f"--write cannot be combined with {o.sets[0].opt()} (see --help)\n")
		return 1
	# --default says "substitute this" and --on-bad=error says "fail instead", so
	# the two together are a contradiction. Each used to overwrite the other's
	# mode, which made the answer depend on the order they were typed in.
	if "--default" in o.seen and o.on_bad_arg is not None and o.on_bad_arg != "default":
		sys.stderr.write(f"--default cannot be combined with --on-bad={o.on_bad_arg} (see --help)\n")
		return 1
	# --lossy only overrides the in-place write's refusal, so on its own it says
	# nothing and would read as protection the command never had.
	if o.lossy and not o.write:
		sys.stderr.write("--lossy is only meaningful with --write (see --help)\n")
		return 1
	# On set, --no-banner shapes only the file a write creates, so without
	# --write it would be accepted and do nothing.
	if o.no_banner and cmd == "set" and not o.write:
		sys.stderr.write("--no-banner is only meaningful with --write (see --help)\n")
		return 1
	if o.check and o.write:
		sys.stderr.write("--check cannot be combined with --write (see --help)\n")
		return 1
	# The ops script already has stdin, so a layer cannot read it too.
	if cmd == "set" and any(lf == "-" for lf in o.layers):
		sys.stderr.write("--layer=- is not valid for set: stdin carries the ops script or the document (see --help)\n")
		return 1
	# Stdin reads once; a second '-' would silently get an empty document.
	stdin_uses = sum(1 for lf in o.layers if lf == "-") + int(o.schema == "-") + int(bool(o.args) and o.args[0] == "-")
	if stdin_uses > 1:
		sys.stderr.write("'-' (stdin) can be named only once across FILE, --layer and --schema\n")
		return 1
	return None


def describe_refusal(doc, path, unwritable):
	# The per-binding wording behind a setter's bare False. When the path itself
	# is fine what failed is the text, and only the caller knows which half of
	# the op that was, so it names it: a setter refused for its value used to
	# report the sentence written for set_literal whatever the op.
	reason = doc.write_reason(path)
	if reason == shcl.WriteReason.Writable:
		return unwritable
	if reason == shcl.WriteReason.BadPath:
		return "not a usable path"
	if reason == shcl.WriteReason.ValueInPath:
		return "a path with a value part cannot be written"
	if reason == shcl.WriteReason.Wildcard:
		return "a wildcard path cannot be written"
	if reason == shcl.WriteReason.NoSuchIndex:
		return "no instance at that index"
	return "deeper than the nesting cap"


def say_diagnostics(diags):
	# The load's diagnostics, one line each, in the shape every command uses.
	say_diagnostics_from("", diags)


def say_diagnostics_from(file, diags):
	# The same, labeled with the file the diagnostics came from. Under --layer
	# several files are loaded and their line numbers share one space on the
	# screen, so two layers with a bad line 2 printed the same thing twice with
	# nothing to tell them apart.
	for d in diags:
		# V090-V095 carry a schema line; V096 and V097 are about generation as a
		# whole and carry line 0, so "schema line 0" named a line space they are
		# not in. V099 stands for a schema that did not load and is line 0 too.
		space = "schema line" if d.code.startswith("V09") and d.code not in ("V096", "V097", "V099") else "line"
		where = f"{file} {space}" if file else space
		sys.stderr.write(f"{where} {d.line}: {d.severity.name}: {d.code} {d.message}\n")


def _fmt_scalar(kind, value):
	if kind == "int":
		return str(value)
	if kind == "float":
		return shcl.format_float(value)
	if kind == "bool":
		return "true" if value else "false"
	if kind == "duration":
		return str(value.days * 86_400_000 + value.seconds * 1000 + value.microseconds // 1000)
	# datetime / string / raw / size all stringify directly.
	return str(value)


def do_get(o):
	if len(o.args) != 2:
		sys.stderr.write("usage: shcl get [type] [options] FILE PATH (see --help)\n")
		return 1
	file, path = o.args[0], o.args[1]
	try:
		doc, code = load_layered(o, file)
	except (OSError, ValueError) as e:
		sys.stderr.write(str(e) + "\n")
		return EXIT_IO
	if doc is None:
		return code
	if o.array:
		if o.kind == "int":
			r = doc.read_int_array(path)
			lines = [str(v) for v in r.value]
		elif o.kind == "float":
			r = doc.read_float_array(path)
			lines = [shcl.format_float(v) for v in r.value]
		elif o.kind == "bool":
			r = doc.read_bool_array(path)
			lines = ["true" if v else "false" for v in r.value]
		elif o.kind == "datetime":
			r = doc.read_datetime_array(path)
			lines = [str(v) for v in r.value]
		elif o.kind in ("raw", "rawinfo", "duration", "size"):
			sys.stderr.write(f"--{o.kind} has no --array form (see --help)\n")
			return 1
		else:
			r = doc.read_string_array(path)
			lines = r.value
		status = r.status
		slots = r.slots
	else:
		if o.kind == "int":
			r = doc.read_int(path)
		elif o.kind == "float":
			r = doc.read_float(path)
		elif o.kind == "bool":
			r = doc.read_bool(path)
		elif o.kind == "datetime":
			r = doc.read_datetime(path)
		elif o.kind == "raw":
			r = doc.read_raw(path)
		elif o.kind == "rawinfo":
			r = doc.read_raw_info(path)
		elif o.kind == "duration":
			r = doc.read_duration(path, shcl.DurationUnit.from_spelling(o.unit) if o.unit else None)
		elif o.kind == "size":
			r = doc.read_size(path, shcl.SizeUnit.from_spelling(o.unit) if o.unit else None, o.decimal)
		else:
			r = doc.read_string(path)
		if o.kind in ("string", "raw", "rawinfo"):
			lines = [r.value]
		else:
			lines = [_fmt_scalar(o.kind, r.value)]
		status = r.status
		slots = []

	def slot_at(i):
		# Per-line slot status: falls back to the aggregate for scalar reads.
		return slots[i] if i < len(slots) else status

	# An array or a slot listing is one line per element, so a value holding a
	# line break takes its escaped spelling there. A plain scalar read prints the
	# value as it is, since the whole output is that one value.
	def emit(lns):
		for i, ln in enumerate(lns):
			if o.slots:
				print(f"{slot_at(i).name}\t{one_line(ln)}")
			elif o.array:
				print(one_line(ln))
			else:
				print(ln)

	# Why the read failed is worth saying even when the exit code already carries
	# it: at the default mode the user otherwise gets an empty line, a nonzero
	# code, and nothing to go on. Stdout is untouched - this only ever goes to
	# stderr. Two silences are deliberate: default mode, because a caller who
	# supplied a fallback has already said the miss is expected, and Empty
	# outside error mode, because an empty value is a legitimate answer here
	# rather than a failure - the same reason ok() counts it as fine.
	if (
		status != shcl.Status.Good
		and o.on_bad != "default"
		and (status != shcl.Status.Empty or o.on_bad == "error")
	):
		type_name = f"{o.kind} array" if o.array else o.kind
		if status == shcl.Status.BadType:
			raw = doc.read_string(path).raw
			reason = (
				f"value {quoted(raw)} is not a valid {type_name}"
				if raw is not None
				else f"value is not a valid {type_name}"
			)
		elif status == shcl.Status.NotFound:
			reason = "no value at that path"
		elif status == shcl.Status.Empty:
			reason = "the value is empty"
		else:
			reason = "the path matches multiple instances"
		sys.stderr.write(
			f"cannot read {path} as {type_name}: {reason} (in {file})\n"
		)
	if status == shcl.Status.Good or (status == shcl.Status.Empty and o.on_bad == "flag"):
		emit(lines)
		return status_code(status)
	if o.on_bad == "default":
		dv = o.default if o.default is not None else ""
		if slots:
			# Array read: the default substitutes per bad slot; alignment holds.
			emit([ln if slot_at(i) == shcl.Status.Good else dv for i, ln in enumerate(lines)])
		elif o.slots:
			print(f"{status.name}\t{one_line(dv)}")
		elif o.array:
			print(one_line(dv))
		else:
			print(dv)
		return 0
	if o.on_bad == "error":
		# The message already went to stderr above; error mode differs only in
		# printing nothing on stdout.
		return status_code(status)
	# flag: print the zero/empty value anyway; the exit code carries the status.
	emit(lines)
	return status_code(status)


def quoted(s):
	# The source text, quoted for a message: one line whatever it holds, with
	# the same escapes in every binding.
	out = ['"']
	for c in s:
		if c == '"':
			out.append('\\"')
		elif c == "\\":
			out.append("\\\\")
		elif c == "\n":
			out.append("\\n")
		elif c == "\r":
			out.append("\\r")
		elif c == "\t":
			out.append("\\t")
		elif ord(c) < 0x20 or c == "\x7f":
			out.append(f"\\u{{{ord(c):x}}}")
		else:
			out.append(c)
	out.append('"')
	return "".join(out)


def do_fmt(o):
	if len(o.args) != 1:
		sys.stderr.write("usage: shcl fmt [--write|-w] [options] FILE (see --help)\n")
		return 1
	file = o.args[0]
	if o.write and file == "-":
		sys.stderr.write("fmt --write cannot rewrite stdin; drop --write to print, or pass a FILE\n")
		return 1
	if o.write and not write_target_ok(file):
		return EXIT_IO
	try:
		doc, read, code = load_layered_from(o, file, None, False)
	except (OSError, ValueError) as e:
		sys.stderr.write(str(e) + "\n")
		return EXIT_IO
	if doc is None:
		return code
	# --check is migrate --check's sibling, and the spelling every other
	# formatter has: print nothing, and say by the exit code whether a rewrite
	# would change the file. It was `shcl fmt f | cmp -s - f` before.
	if o.check:
		# The save gate --write goes through is asked first, so 6 never
		# promises a rewrite the same command would refuse to make.
		if not o.lossy and doc.lost_count() != 0:
			sys.stderr.write(f"{file}: fmt --write would refuse: the load dropped {doc.lost_count()} line(s)/value(s) it would delete (--lossy overrides)\n")
			return 7
		if doc.to_canonical() == read:
			return 0
		sys.stderr.write(f"{file}: not canonical; fmt --write would rewrite it\n")
		return 6
	if o.write:
		return write_back(doc, file, o, read)
	sys.stdout.write(doc.to_canonical())
	return 0


def rewritten_lines(before, after):
	# The numbers of the lines migrate spells differently, counted from 1. The
	# rewrite goes line for line and only appends, so line N of the input is
	# line N of the output.
	if before == "":
		return []
	b = before[:-1] if before.endswith("\n") else before
	return [i + 1 for i, (x, y) in enumerate(zip(b.split("\n"), after.split("\n"))) if x != y]


def old_copy_name(file):
	# Where migrate --write keeps the file it replaces: _old_v2 before the last
	# dot of the file name, or on the end when it has none. A leading dot is
	# part of the name, not an extension.
	start = file.rfind("/") + 1
	if os.name == "nt":
		start = max(start, file.rfind("\\") + 1)
	dot = file.rfind(".", start)
	if dot > start:
		return file[:dot] + "_old_v2" + file[dot:]
	return file + "_old_v2"


def keep_original(file, text):
	# The original bytes, at the old-copy name, before the migrated text
	# replaces them. The create is exclusive, so an earlier copy is never
	# replaced, and the copy is synced before the save starts.
	old = old_copy_name(file)
	try:
		fd = os.open(old, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0), 0o600)
	except FileExistsError:
		return None, f"{old}: already exists; migrate keeps the original file there, so nothing was written"
	except (OSError, ValueError) as e:
		return None, f"{old}: {getattr(e, 'strerror', None) or e}"
	try:
		with os.fdopen(fd, "wb") as fh:
			fh.write(text.encode("utf-8"))
			# Born private, then given the original's bits, so a 600 config
			# never has a readable copy. Best effort, the way the save carries
			# the mode.
			if hasattr(os, "fchmod"):
				try:
					os.fchmod(fh.fileno(), stat.S_IMODE(os.stat(file).st_mode))
				except OSError:
					pass
			fh.flush()
			os.fsync(fh.fileno())
	except OSError as e:
		try:
			os.remove(old)
		except OSError:
			pass
		return None, f"{old}: {e.strerror or e}"
	return old, None


def do_migrate(o):
	# A 2.x file rewritten for the current rules. The rewrite is text to text;
	# the load after it is for the diagnostics and the save gate, the same
	# gate fmt --write goes through.
	if len(o.args) != 1:
		sys.stderr.write("usage: shcl migrate [options] FILE (see --help)\n")
		return 1
	file = o.args[0]
	if o.write and file == "-":
		sys.stderr.write("migrate --write cannot rewrite stdin; drop --write to print, or pass a FILE\n")
		return 1
	if o.write and not write_target_ok(file):
		return EXIT_IO
	try:
		text = read_input(file)
	except (OSError, ValueError) as e:
		sys.stderr.write(str(e) + "\n")
		return EXIT_IO
	m = shcl.migrate(text, o.from_2x)
	doc, code = load_doc_from("", m.text, o.strictness)
	if doc is None:
		return code
	say_diagnostics_from("", doc.diagnostics())
	# The file says it was written for these rules, so there is nothing to do
	# and nothing to write. Saying so beats printing the input back silently.
	if m.current:
		sys.stderr.write(f"{file}: nothing to migrate: the file already names its format\n")
		if not o.write and not o.check:
			sys.stdout.write(m.text)
		return 0
	rc = 0
	if m.ambiguous != 0:
		sys.stderr.write(f"{file}: {m.ambiguous} value(s) read one way under 2.x and another under these rules, and the file does not say which it was written for; left as written (--from-2x rewrites them)\n")
		rc = 7
	if m.lost != 0:
		sys.stderr.write(f"{file}: {m.lost} line(s) bound a value under 2.x that nothing binds now: bracket text after the colon, which has no spelling here (--lossy overrides)\n")
		if not o.lossy:
			rc = 7
	rewritten = rewritten_lines(text, m.text)
	# A save keeps a line at an indent no level matches, but 2.x placed some
	# such lines by a looser rule and read them, so a migration that leaves
	# one has not carried the file across. With nothing lost, every one of
	# them is kept.
	misplaced = sum(1 for d in doc.diagnostics() if d.code in ("E012", "E018"))
	if o.check:
		for n in rewritten:
			sys.stderr.write(f"{file}:{n}: migrate would rewrite this line\n")
		# Same as fmt --check: the save gate --write goes through is asked
		# before 6, so 6 never promises a rewrite that would be refused.
		if rc == 0 and not o.lossy and doc.lost_count() != 0:
			sys.stderr.write(f"{file}: migrate --write would refuse: the migrated text drops {doc.lost_count()} line(s)/value(s) on load (--lossy overrides)\n")
			rc = 7
		elif rc == 0 and not o.lossy and misplaced != 0:
			sys.stderr.write(f"{file}: migrate --write would refuse: the migrated text leaves {misplaced} line(s) unread at an indent no open level matches (--lossy overrides)\n")
			rc = 7
		if rc == 0 and rewritten:
			rc = 6
		return rc
	if o.write:
		if rc != 0:
			sys.stderr.write(f"{file}: refusing to rewrite; nothing changed\n")
			return rc
		if doc.lost_count() != 0 and not o.lossy:
			sys.stderr.write(f"{file}: refusing to rewrite: the migrated text drops {doc.lost_count()} line(s)/value(s) on load (--lossy overrides)\n")
			return 7
		if misplaced != 0 and not o.lossy:
			sys.stderr.write(f"{file}: refusing to rewrite: the migrated text leaves {misplaced} line(s) unread at an indent no open level matches (--lossy overrides)\n")
			return 7
		if not unchanged_since_read(file, text):
			return EXIT_IO
		# Only a rewrite leaves a 2.x original to keep. A file that just gains
		# the Format line reads the same either way, and may be a 3.0 file
		# with no stamp.
		old = None
		if rewritten:
			old, err = keep_original(file, text)
			if err is not None:
				sys.stderr.write(err + "\n")
				return EXIT_IO
		err = shcl.write_file_atomic(file, m.text)
		if err is not None:
			sys.stderr.write(err + "\n")
			# With the original still in place the copy would only stand in
			# the way of the next run. A replace that fails part way on windows
			# can leave nothing at FILE, and then the copy is all there is.
			if old is not None:
				try:
					with open(file, "rb") as fh:
						same = fh.read() == text.encode("utf-8")
				except (OSError, ValueError):
					same = False
				if same:
					try:
						os.remove(old)
					except OSError:
						pass
				else:
					sys.stderr.write(f"{file}: the original is {old}\n")
			return EXIT_IO
		if old is not None:
			sys.stderr.write(f"{file}: migrated, {len(rewritten)} line(s) rewritten; the original is {old}\n")
		else:
			sys.stderr.write(f"{file}: migrated, {len(rewritten)} line(s) rewritten\n")
		return 0
	sys.stdout.write(m.text)
	return rc


def _span(p):
	mark = {shcl.Quote.NONE: "", shcl.Quote.SINGLE: "'", shcl.Quote.DOUBLE: '"', shcl.Quote.OPEN: "?"}[p.quote]
	return f"{p.start}-{p.end}{mark}"


def code_line(head):
	# `CODE  severity  summary` - the one line both explain forms lead with.
	f = (head.split("|", 2) + ["", ""])[:3]
	return f"{f[0]}  {f[1]:<10}  {f[2]}"


def code_heads():
	# The head lines of the code table, in table order.
	return [line for line in CODES.split("\n") if line and not line.startswith(" ")]


def do_explain(o):
	if not o.args:
		heads = "".join(code_line(h) + "\n" for h in code_heads())
		sys.stdout.write("\nDiagnostic codes:\n\n" + heads + "\n'shcl explain CODE' has the rule behind one of them.\n\n")
		return 0
	if len(o.args) > 1:
		sys.stderr.write("usage: shcl explain [CODE] (see --help)\n")
		return 1
	code = _ascii_upper(o.args[0])
	# The entry runs from its head line to the next one. Built up first, since a
	# code the table does not carry prints nothing at all.
	body = []
	found = False
	for line in CODES.rstrip("\n").split("\n"):
		if not line.startswith(" "):
			if found:
				break
			found = line.split("|", 1)[0] == code
			if found:
				body.append(code_line(line))
			continue
		if found:
			body.append(line)
	if not found:
		names = [h.split("|", 1)[0] for h in code_heads()]
		sys.stderr.write(
			f"unknown diagnostic code: {code}{suggest(names, code)} (shcl explain lists them all)\n"
		)
		return 1
	sys.stdout.write("\n" + "\n".join(body) + "\n\n")
	return 0


def do_tokens(o):
	# Every line's spans, one line of output per input line: the indent
	# length, then each token as kind=start-end with a mark for how it was
	# quoted (', ", or ? for a quote that never closed), offsets counted in
	# bytes from the first character after the indent. A blank line and a
	# comment line say so; every other line is tokenized on its own, raw
	# bodies included, since this is the lexical view and not the parse.
	if len(o.args) != 1:
		sys.stderr.write("usage: shcl tokens FILE (see --help)\n")
		return 1
	try:
		text = read_input(o.args[0])
	except (OSError, ValueError) as e:
		sys.stderr.write(str(e) + "\n")
		return EXIT_IO
	if text.startswith("\ufeff"):
		text = text[1:]
	lines = [ln.rstrip("\r") for ln in text.split("\n")]
	if text.endswith("\n"):
		lines.pop()
	tok = shcl.Tokens()
	out = []
	for i, line in enumerate(lines):
		rest = line.lstrip(" \t")
		ilen = len(line) - len(rest)
		rest = rest.rstrip(" \t\r")
		out.append(f"{i + 1}:{ilen}")
		if not rest:
			out.append(" blank\n")
			continue
		# The parser takes a leading carriage return off with the indent's blanks.
		body = rest.lstrip(" \t\r")
		lead = len(rest) - len(body)
		if body.startswith("#"):
			out.append(" comment\n")
			continue
		# A stacked element and a fence line are value halves on their own. A
		# `*` is an element when a blank follows it, trailing or not, which only
		# the untrimmed line still shows (20260923 item 12).
		after = ilen + lead + 1
		star = body.startswith("*") and line[after:after + 1] in (" ", "\t", "\r")
		fence = body.startswith("```") or body.startswith("~~~")
		if star or fence:
			shcl.tokenize_value(rest, lead + int(star), shcl.RULES_CURRENT, tok)
			out.append(" star" if star else " fence")
			out.append(f" value={tok.value[0]}-{tok.value[1]}")
			out.extend(f" elem={_span(p)}" for p in tok.elements)
			if tok.comment is not None:
				out.append(f" comment={tok.comment}")
			out.append("\n")
			continue
		shcl.tokenize(rest, ":", False, shcl.RULES_CURRENT, tok)
		for seg in tok.segments:
			out.append(f" {'star' if seg.star else 'name'}={_span(seg.name)}")
			if seg.selector is not None:
				out.append(f" sel={_span(seg.selector)}")
		if tok.sep is not None:
			out.append(f" sep={tok.sep} value={tok.value[0]}-{tok.value[1]}")
			out.extend(f" elem={_span(p)}" for p in tok.elements)
		if tok.comment is not None:
			out.append(f" comment={tok.comment}")
		if tok.fault is not None:
			out.append(f" fault={tok.fault[0]}:{tok.fault[1]}")
		out.append("\n")
	sys.stdout.write("".join(out))
	return 0


def _unescape_ops(s):
	# Decode an ops value: \n \t \\ only; other `\x` stays verbatim.
	out = []
	i = 0
	while i < len(s):
		c = s[i]
		if c != "\\" or i + 1 >= len(s):
			out.append(c)
			i += 1
			continue
		nxt = s[i + 1]
		if nxt == "n":
			out.append("\n")
		elif nxt == "t":
			out.append("\t")
		elif nxt == "\\":
			out.append("\\")
		else:
			out.append("\\")
			out.append(nxt)
		i += 2
	return "".join(out)


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
	# The language's own float reader takes inf and nan, and overflow (1e400)
	# ends up on them too; the document's reader does not, so they are bad
	# values here, the way a bad datetime is.
	if not _float_grammar_ok(s):
		raise ValueError(f"bad float: {s}")
	x = float(s)
	if not math.isfinite(x):
		raise ValueError(f"bad float: {s}")
	return x


_OP_FIELDS = {
	"empty": 2, "remove": 2, "clear-comments": 2, "banner": 2,
	"raw": 4, "raw-default": 4,
	"int": 3, "float": 3, "bool": 3, "string": 3, "datetime": 3, "literal": 3, "comment": 3,
	"int-default": 3, "float-default": 3, "bool-default": 3, "string-default": 3,
	"datetime-default": 3, "literal-default": 3,
}


def apply_op(doc, line):
	f = line.split("\t")
	# Every op but the array forms takes a fixed number of tab-separated fields.
	# Extra ones used to be dropped, so a `raw` whose content held a literal tab
	# lost everything after it and still reported success; the escape for a tab
	# inside a value is `\t`.
	want = _OP_FIELDS.get(f[0])
	if want is not None and len(f) > want:
		raise ValueError(f"{f[0]} takes {want} tab-separated field(s), got {len(f)}")

	def get(i):
		return f[i] if i < len(f) else ""

	path, v = get(1), get(2)
	arr = f[2:] if len(f) > 2 else []
	op = f[0]
	if op == "int":
		wrote = doc.set_int(path, _op_int(v))
	elif op == "float":
		wrote = doc.set_float(path, _op_flt(v))
	elif op == "bool":
		wrote = doc.set_bool(path, _op_bool(v))
	elif op == "string":
		wrote = doc.set_string(path, _unescape_ops(v))
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
		wrote = doc.set_string_default(path, _unescape_ops(v))
	elif op == "datetime-default":
		wrote = doc.set_datetime_default(path, _op_dt(v))
	elif op == "int-array":
		wrote = doc.set_int_array(path, [_op_int(x) for x in arr])
	elif op == "float-array":
		wrote = doc.set_float_array(path, [_op_flt(x) for x in arr])
	elif op == "bool-array":
		wrote = doc.set_bool_array(path, [_op_bool(x) for x in arr])
	elif op == "string-array":
		wrote = doc.set_string_array(path, [_unescape_ops(x) for x in arr])
	elif op == "datetime-array":
		wrote = doc.set_datetime_array(path, [_op_dt(x) for x in arr])
	elif op == "int-array-default":
		wrote = doc.set_int_array_default(path, [_op_int(x) for x in arr])
	elif op == "float-array-default":
		wrote = doc.set_float_array_default(path, [_op_flt(x) for x in arr])
	elif op == "bool-array-default":
		wrote = doc.set_bool_array_default(path, [_op_bool(x) for x in arr])
	elif op == "string-array-default":
		wrote = doc.set_string_array_default(path, [_unescape_ops(x) for x in arr])
	elif op == "datetime-array-default":
		wrote = doc.set_datetime_array_default(path, [_op_dt(x) for x in arr])
	elif op == "raw":
		wrote = doc.set_raw(path, _unescape_ops(get(3)), v)
	elif op == "raw-default":
		wrote = doc.set_raw_default(path, _unescape_ops(get(3)), v)
	elif op == "empty":
		wrote = doc.set_empty(path)
	elif op == "comment":
		wrote = doc.set_comment(path, _unescape_ops(v))
	elif op in ("remove", "clear-comments") and unusable_path(doc, path):
		raise ValueError(f"cannot {op} {path}: not a usable path")
	elif op == "remove":
		doc.remove(path)
		wrote = True
	elif op == "clear-comments":
		doc.clear_comments(path)
		wrote = True
	elif op == "banner":
		# The second field is on or off, not a path.
		if path not in ("on", "off"):
			raise ValueError(f"bad banner: {path} (on or off)")
		doc.set_banner(path == "on")
		wrote = True
	else:
		raise ValueError(f"unknown op: {op}")
	if not wrote:
		# Which half of the op had no spelling: the reader is otherwise sent to
		# the value when it was the info string or the comment that failed.
		if op in ("literal", "literal-default"):
			unwritable = "the value text is not one value"
		elif op == "comment":
			unwritable = "the comment text is not one line"
		elif op in ("raw", "raw-default"):
			unwritable = _raw_refusal(_unescape_ops(get(3)))
		else:
			unwritable = "the value has no spelling that reads back"
		raise ValueError(f"cannot write {path}: {describe_refusal(doc, path, unwritable)}")


def _raw_refusal(content):
	"""Which half of a `raw` op had no spelling, and why. The half is asked of the

	library rather than worked out here: an empty info string always reads back,
	so a write that still fails with one is the body's fault. Re-deriving the
	rule in the CLI is how the two copies drift.
	"""
	probe = shcl.Document.new()
	if not probe.set_raw("p", content, ""):
		return "the block body has no spelling that reads back: a line ending in a carriage return is trimmed on the way back in, and a line spelling the closing fence would end the block early"
	return "the info string has no spelling that reads back: a '#' in it opens a comment, and a line break has no inline spelling"


def do_set(o):
	if len(o.args) != 1:
		sys.stderr.write("usage: shcl set [--write|-w] [options] FILE (see --help)\n")
		return 1
	file = o.args[0]
	if o.write and file == "-":
		sys.stderr.write("set --write cannot rewrite stdin; drop --write to print, or pass a FILE\n")
		return 1
	if o.write and not write_target_ok(file):
		return EXIT_IO
	# Base doc: with the edits given as options no ops script is read, so a '-'
	# file is the document on stdin the way it is everywhere else; only when
	# stdin is the ops script does '-' mean an empty base. Reading neither threw
	# a piped document away at exit 0.
	# --write names the file this command produces, so a FILE that is not there
	# yet is a create and the edits go into a new document. Only under --write,
	# and only when nothing is at the path at all: without --write there is
	# nothing to create, and a file that exists but cannot be read is still an
	# error rather than something to quietly write over.
	# A created file starts out as the info block, so a new config says what
	# format it is. Comments in an otherwise empty document are the document's
	# trailing trivia, so the edits go above it and the write still goes
	# through the library's save gate.
	# The --layer files sit under it and --set overrides sit on top, before
	# ops, through the same fold every other subcommand uses.
	creating = o.write and file != "-" and not os.path.exists(file)
	given = None
	if creating:
		given = "" if o.no_banner else shcl.GEN_BANNER
	elif file == "-" and not o.sets:
		given = ""
	try:
		# Lines the edits leave alone are written back as they were, so a
		# hand-kept file stays the way it was kept. A created file has none.
		doc, read, code = load_layered_from(o, file, given, not creating)
	except (OSError, ValueError) as e:
		sys.stderr.write(str(e) + "\n")
		return EXIT_IO
	if doc is None:
		return code
	# --set carries the edits, so stdin is left alone: reading it here would
	# block on the console for anyone who passed edits as options.
	# The ops script is contract input like the reference's read_to_string:
	# bad bytes are a hard error, never silently replaced.
	ops = ""
	if not o.sets:
		# Say so before blocking. With nothing on stdin this used to sit there
		# silently, which reads as a hang rather than as a prompt; the note is
		# unconditional so a pipeline and a terminal behave identically. The
		# program-name prefix marks it as a notice; errors carry none.
		sys.stderr.write(
			"shcl: reading write-ops from stdin (one op per line, tab-separated; end with EOF)\n"
		)
		try:
			ops = sys.stdin.buffer.read().decode("utf-8")
		except UnicodeDecodeError:
			sys.stderr.write("stdin: invalid UTF-8\n")
			return EXIT_IO
	# Byte order marks off the front: Windows PowerShell 5.1 puts one or more
	# before text it pipes to a program (20260924 item
	# 7), and the first op then read as unknown. No op starts with one.
	ops = ops.lstrip("\ufeff")
	pieces = ops.split("\n")
	for n, line in enumerate(pieces):
		# One CR off each piece: the CR of a CRLF, or of a CRLF at EOF that lost
		# its LF. A second one is the value's.
		line = line[:-1] if line.endswith("\r") else line
		if line == "" or line.startswith("#"):
			continue
		try:
			apply_op(doc, line)
		except ValueError as e:
			sys.stderr.write(f"op line {n + 1}: {e}\n")
			return 1
	if o.write:
		# "Create" was decided before the wait on stdin, so a file that turned
		# up meanwhile is refused rather than replaced.
		if creating and os.path.exists(file):
			sys.stderr.write(f"{file}: file exists (it appeared while the edits were read)\n")
			return EXIT_IO
		# The banner seeded an empty document, so the blank line above it was
		# the document's first and the parse drops those on purpose. Put it
		# back now that the edits sit above it, so a created file reads the
		# way init's output does.
		if creating and not o.no_banner:
			text = doc.to_canonical()
			if text.endswith(shcl.GEN_BANNER):
				head = text[: -len(shcl.GEN_BANNER)]
				if head and not head.endswith("\n\n"):
					doc = shcl.Document.parse(head + "\n" + shcl.GEN_BANNER)
		# A file that was there is read again first, for the same wait.
		return write_back(doc, file, o, None if creating else read, not creating)
	sys.stdout.write(doc.to_text_keep_lines()[0])
	return 0


def schema_for(o, file, text):
	"""The schema check validates against: --schema, else the one the file
	names on its Schema line. A relative path there is read from the config
	file's directory, the way an editor reads it. A URL is left to editors,
	since a check that reads the network because of a line in a file is not
	one to run unattended."""
	if o.schema is not None:
		return o.schema
	named = shcl.schema_ref(text)
	if named is None:
		return None
	if "://" in named:
		sys.stderr.write("the file names its schema by URL (" + named + "), which check does not fetch; pass --schema=SCHEMA to validate against it\n")
		return None
	c = named[0]
	if c in "/\\" or (len(named) >= 2 and named[1] == ":" and c.isascii() and c.isalpha()):
		return named
	k = max(file.rfind("/"), file.rfind("\\"))
	d = file[:k] if k >= 0 and file != "-" else "."
	return d + "/" + named


def do_check(o):
	if len(o.args) != 1:
		sys.stderr.write("usage: shcl check [options] FILE (see --help)\n")
		return 1
	try:
		text = read_input(o.args[0])
	except (OSError, ValueError) as e:
		sys.stderr.write(str(e) + "\n")
		return EXIT_IO
	# A strict load fails and still hands back the document it recovered, which
	# is what the library's one-shot validate walks. So the schema half runs
	# either way: at strict a user was getting less out of check than at
	# standard on the same file, and check writes nothing, so fmt's refusal to
	# rewrite a strict-failing document does not carry over.
	strict_failed = False
	try:
		doc = shcl.Document.parse_with(text, o.strictness)
	except shcl.LoadError as le:
		# The library always attaches the recovered document; the type allows
		# None for a caller building one by hand, so fall back to an empty
		# document rather than carry an assert into the CLI.
		doc = le.document if le.document is not None else shcl.Document.parse("")
		strict_failed = True
	diags = list(doc.diagnostics())
	# --schema: append validation diagnostics under the same contract. The
	# schema itself always loads at Standard (a program artifact); one that
	# does not load cleanly is a single V099 schema fault.
	schema_file = schema_for(o, o.args[0], text)
	if schema_file is not None:
		try:
			stext = read_input(schema_file)
		except (OSError, ValueError) as e:
			sys.stderr.write(str(e) + "\n")
			return EXIT_IO
		sdoc = shcl.Document.parse(stext)
		if any(sd.severity == shcl.Severity.Error for sd in sdoc.diagnostics()):
			for sd in sdoc.diagnostics():
				sys.stderr.write(f"schema line {sd.line}: {sd.severity.name}: {sd.code} {sd.message}\n")
			diags.append(shcl.Diagnostic(0, shcl.Severity.Error, "schema failed to load", "V099"))
		else:
			# The schema's own load has something to say too: an H001 on a
			# repeated `allowed` is what explains the V092 below it. On
			# stderr with the schema's own line numbers, the way a V099's
			# are - stdout is the code contract.
			for sd in sdoc.diagnostics():
				sys.stderr.write(f"schema line {sd.line}: {sd.severity.name}: {sd.code} {sd.message}\n")
			diags.extend(doc.validate(sdoc))
			shcl.suppress_declared_repeats(sdoc, diags)
			shcl.suppress_declared_reopens(sdoc, diags)
	# stdout carries the stable codes - the cross-binding contract. The prose is
	# per-binding voice and goes to stderr (which the differential check drops).
	# A V090-V093 line number is a SCHEMA line (the code table says so); the
	# prose names the file so the two number spaces cannot be confused.
	for d in diags:
		print(f"line {d.line}: {d.severity.name}: {d.code}")
	say_diagnostics(diags)
	# The codes are the portable half of a diagnostic and nothing else on screen
	# says where to look one up.
	if diags:
		sys.stderr.write("(run 'shcl explain CODE' for the rule behind a code)\n")
	errors = sum(1 for d in diags if d.severity == shcl.Severity.Error)
	if strict_failed:
		print(f"strict load failed: {len(diags)} diagnostic(s)")
		return 6
	if errors > 0:
		# Loaded, but lines were dropped: nonzero so a CI gate on check catches it.
		print(f"failed: {len(diags)} diagnostic(s), {errors} error(s)")
		return 6
	print(f"ok ({len(diags)} diagnostic(s))")
	return 0


def do_init(o):
	if o.args:
		sys.stderr.write("init takes no file argument (see --help)\n")
		return 1
	if o.schema is None:
		sys.stderr.write("init needs --schema=FILE (see --help)\n")
		return 1
	try:
		stext = read_input(o.schema)
	except (OSError, ValueError) as e:
		sys.stderr.write(str(e) + "\n")
		return EXIT_IO
	# The schema always loads at Standard - a program artifact, not user data.
	sdoc = shcl.Document.parse(stext)
	if any(d.severity == shcl.Severity.Error for d in sdoc.diagnostics()):
		for d in sdoc.diagnostics():
			sys.stderr.write(f"schema line {d.line}: {d.severity.name}: {d.code} {d.message}\n")
		sys.stderr.write("init: schema failed to load\n")
		# A broken schema is a config-semantics failure, not a usage error:
		# same exit as `check --schema` reporting it.
		return 6
	text, faults = shcl.generate(sdoc, o.no_banner)
	if faults:
		say_diagnostics(faults)
		sys.stderr.write("init: schema has faults\n")
		return 6
	sys.stdout.write(text)
	return 0


def one_line(v):
	"""A value for a one-per-line listing. instances promises one line per
	instance, and a value holding a line break broke that, so a caller splitting
	on newlines counted more instances than count reports. Only such a value
	changes. The escaped spelling is the one _gen_default_text writes."""
	if "\n" not in v and "\r" not in v:
		return v
	out = ['"']
	for ch in v:
		if ch == "\\":
			out.append("\\\\")
		elif ch == '"':
			out.append('\\"')
		elif ch == "\n":
			out.append("\\n")
		elif ch == "\r":
			out.append("\\r")
		elif ch == "\t":
			out.append("\\t")
		else:
			out.append(ch)
	out.append('"')
	return "".join(out)


def do_enum(o, want_count):
	if len(o.args) != 2:
		name = "count" if want_count else "instances"
		sys.stderr.write(f"usage: shcl {name} [options] FILE PATH (see --help)\n")
		return 1
	file, path = o.args[0], o.args[1]
	try:
		doc, code = load_layered(o, file)
	except (OSError, ValueError) as e:
		sys.stderr.write(str(e) + "\n")
		return EXIT_IO
	if doc is None:
		return code
	if want_count:
		print(doc.count(path))
	else:
		for v in doc.instances(path):
			print(one_line(v))
	return 0


def do_children(o):
	# Child field names under a path, one per line, in file order and with
	# duplicates kept. PATH may be left out to enumerate the top level. Each name
	# comes out in the form a path accepts, so one holding a dot or a quote
	# splices back into a path with no further work.
	if len(o.args) == 1:
		file, path = o.args[0], ""
	elif len(o.args) == 2:
		file, path = o.args[0], o.args[1]
	else:
		sys.stderr.write("usage: shcl children [options] FILE [PATH] (see --help)\n")
		return 1
	try:
		doc, code = load_layered(o, file)
	except (OSError, ValueError) as e:
		sys.stderr.write(str(e) + "\n")
		return EXIT_IO
	if doc is None:
		return code
	for name in doc.children(path):
		print(shcl.quote_segment(name))
	return 0


def do_paths(o):
	# Every field path in the document, one per line, in file order and
	# deduplicated - the whole-document counterpart of do_children.
	if len(o.args) != 1:
		sys.stderr.write("usage: shcl paths [options] FILE (see --help)\n")
		return 1
	try:
		doc, code = load_layered(o, o.args[0])
	except (OSError, ValueError) as e:
		sys.stderr.write(str(e) + "\n")
		return EXIT_IO
	if doc is None:
		return code
	for p in doc.paths():
		print(p)
	return 0


COMMANDS = ("get", "set", "fmt", "check", "init", "count", "instances", "children", "paths", "migrate", "tokens", "explain")


def run(argv):
	# Undecodable argv bytes arrive as surrogate-escaped chars; reject like the
	# reference (exit 1) instead of feeding a garbled path or query downstream.
	for a in argv:
		try:
			a.encode("utf-8")
		except UnicodeEncodeError:
			sys.stderr.write("invalid argument encoding (expected UTF-8)\n")
			return 1
	asked = asked_for(argv)
	# One convention: asking for the help - by name, by flag, or by asking for
	# nothing at all - prints it and succeeds. The blank lines separate the
	# block from the surrounding prompts. A bare run used to print the same
	# text unpadded and exit 1, which read as neither a help nor an error.
	if not argv:
		sys.stdout.write("\n" + HELP + "\n")
		return 0
	if asked == "help" or argv[0] == "help":
		# `shcl help CMD` and `shcl CMD --help` narrow to one subcommand. In the
		# flag form the command is the first word, which a bare `--help` is not.
		# An empty word is still a topic, as it is in the reference: `help ''`
		# names no command, which is not the same as naming none.
		if argv[0] == "help":
			# A help flag after `help` asks for the same thing twice, so it is no
			# topic: `help --help` and `help get -h` print what they name.
			words = [w for w in argv[1:] if w not in ("-h", "--help")]
			if len(words) > 1:
				sys.stderr.write("usage: shcl help [CMD] (see --help)\n")
				return 1
			topic = words[0] if words else None
		else:
			topic = None if argv[0].startswith("-") else argv[0]
		# The informational words are the full help's own last two lines, so
		# there is nothing narrower to show for them.
		if topic is None or topic in ("help", "version", "about", "donate"):
			sys.stdout.write("\n" + HELP + "\n")
			return 0
		if topic in COMMANDS:
			sys.stdout.write("\n" + help_for(topic) + "\n")
			return 0
		sys.stderr.write(f"unknown command: {topic}{suggest(command_names(), topic)} (see --help)\n")
		return 1
	# The word forms take nothing after them but their own flags, as `help`
	# takes a command at most: an option a command does not use is a usage
	# error (20260923 item 17). The flag spellings still work anywhere.
	for word, flags in (("version", ("-v", "-V", "--version")), ("about", ("--about",)), ("donate", ("--donate",))):
		if argv[0] == word and any(a not in flags for a in argv[1:]):
			sys.stderr.write(f"usage: shcl {word} (see --help)\n")
			return 1
	if asked == "version" or argv[0] == "version":
		print(VERSION_LINE)
		return 0
	if asked == "about" or argv[0] == "about":
		sys.stdout.write("\n" + ABOUT + "\n")
		return 0
	if asked == "donate" or argv[0] == "donate":
		sys.stdout.write("\n" + DONATE + "\n")
		return 0
	cmd = argv[0]
	if cmd not in COMMANDS:
		# Before the options are judged, so a typo in the command is reported
		# as that and not as an option the wrong command cannot take.
		if cmd.startswith("-") and cmd != "--":
			name = cmd.split("=")[0]
			if known_option(name):
				# It is a real option, just in front of the subcommand. Calling
				# it unknown and then suggesting the same spelling back says
				# nothing about what is actually wrong.
				sys.stderr.write(f"option {name} goes after the subcommand (see --help)\n")
			else:
				sys.stderr.write(f"unknown option: {cmd}{suggest(option_names(), name)} (see --help)\n")
		else:
			sys.stderr.write(f"unknown command: {cmd}{suggest(command_names(), cmd)} (see --help)\n")
		return 1
	try:
		o = parse_opts(argv[1:])
	except ValueError as e:
		sys.stderr.write(str(e) + "\n")
		return 1
	code = check_opts(cmd, o)
	if code is not None:
		return code
	# A value option in space form takes the next word, so `check --schema FILE`
	# leaves no FILE and the usage line alone never says where it went. Judged
	# after the options, so an option the command does not take is named as
	# that. init and explain want no FILE.
	if cmd not in ("init", "explain") and not o.args and o.swallowed is not None:
		name, value = o.swallowed
		sys.stderr.write(f"option {name} took '{value}' as its value, so no FILE is left; spell it {name}=VALUE\n")
		return 1
	if cmd == "get":
		return do_get(o)
	if cmd == "set":
		return do_set(o)
	if cmd == "fmt":
		return do_fmt(o)
	if cmd == "check":
		return do_check(o)
	if cmd == "init":
		return do_init(o)
	if cmd == "count":
		return do_enum(o, True)
	if cmd == "instances":
		return do_enum(o, False)
	if cmd == "children":
		return do_children(o)
	if cmd == "paths":
		return do_paths(o)
	if cmd == "migrate":
		return do_migrate(o)
	if cmd == "tokens":
		return do_tokens(o)
	if cmd == "explain":
		return do_explain(o)
	# A refusal rather than a fall-through: with one, adding a name to COMMANDS
	# without adding a branch here quietly ran whichever command the last line
	# named, with no message. run() gates on COMMANDS first, so this is only
	# reachable through that mistake.
	sys.stderr.write(f"{cmd}: no dispatch arm (see --help)\n")
	return 1


def main():
	# Restore the default SIGPIPE disposition: Python installs SIG_IGN, which turns
	# a closed stdout into a BrokenPipeError instead of the conventional signal
	# death (exit 141). With SIG_DFL a broken pipe kills us like head/cat, matching
	# the other bindings; no BrokenPipeError to catch.
	if hasattr(signal, "SIGPIPE"):
		signal.signal(signal.SIGPIPE, signal.SIG_DFL)
	# A standard stream that was closed before the start (fmt - <&-, fmt FILE
	# >&-) is None here. The reference reads such a stdin as empty and drops
	# what it writes to such a stdout or stderr, so each gets the same: an
	# empty document in, a sink for the output. The stdin one is a text stream
	# so the .buffer reads below find one.
	if sys.stdin is None:
		sys.stdin = open(os.devnull, encoding="utf-8")  # noqa: SIM115
	if sys.stdout is None:
		sys.stdout = open(os.devnull, "w", encoding="utf-8")  # noqa: SIM115
	if sys.stderr is None:
		sys.stderr = open(os.devnull, "w", encoding="utf-8")  # noqa: SIM115
	# Output is UTF-8 and LF on every platform, as the reference writes it:
	# the text streams take the locale's encoding, and translate \n to \r\n on
	# windows, unless told not to. stdin is read through .buffer everywhere,
	# so it never decodes or translates. A stream that cannot be reconfigured
	# (replaced, or not a text stream) is left alone.
	for stream in (sys.stdout, sys.stderr):
		reconfigure = getattr(stream, "reconfigure", None)
		if reconfigure is not None:
			try:
				reconfigure(encoding="utf-8", newline="\n")
			except (ValueError, OSError):
				pass
	sys.stderr = _BestEffort(sys.stderr)
	try:
		code = run(sys.argv[1:])
		# A tail still sitting in the buffer when the work is done fails the
		# same way a write does.
		sys.stdout.flush()
	except OSError as e:
		return write_failed(e)
	return code


if __name__ == "__main__":
	sys.exit(main())
