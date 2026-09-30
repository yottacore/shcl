// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// shcl CLI - the Go binding's command surface. Flags, output, and exit codes
// mirror the Rust reference exactly; the cicd cross-binding check compares the
// two byte for byte, so any drift here fails the pipeline.
package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"math"
	"os"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"unicode/utf8"

	shcl "github.com/yottacore/shcl/source/go/v2"
)

// Every stdout write goes through these. A reader that closed early is not an
// error worth reporting - nobody is there to read one - so that leaves
// quietly; anything else lost the output, which is the same failure as a file
// that could not be written.
func outf(format string, a ...any) {
	if _, err := fmt.Fprintf(os.Stdout, format, a...); err != nil {
		writeFailed(err)
	}
}

func outln(a ...any) {
	if _, err := fmt.Fprintln(os.Stdout, a...); err != nil {
		writeFailed(err)
	}
}

func outs(a ...any) {
	if _, err := fmt.Fprint(os.Stdout, a...); err != nil {
		writeFailed(err)
	}
}

// EPIPE on unix, where the SIGPIPE default usually ends the process before the
// error is seen at all; on windows a closed reader arrives as
// ERROR_BROKEN_PIPE, which Go surfaces as errno 109 rather than mapping it.
func brokenPipe(err error) bool {
	if errors.Is(err, syscall.EPIPE) {
		return true
	}
	var errno syscall.Errno
	return runtime.GOOS == "windows" && errors.As(err, &errno) && errno == 109
}

func writeFailed(err error) {
	if brokenPipe(err) {
		os.Exit(0)
	}
	fmt.Fprintf(os.Stderr, "stdout: %v\n", err)
	os.Exit(8)
}

// Keep in step with source/rust/Cargo.toml, the canonical version source.
const version = "2.0.0"

// The build number, set only for a stamped build (-ldflags "-X main.build=ID").
// The Rust CLI is the one the pipeline stamps; see its build.rs.
var build = ""

var versionLine = "shcl v" + version + buildSuffix()

func buildSuffix() string {
	if build == "" {
		return ""
	}
	return " build " + build
}

const help = `shcl - Simple Hierarchical Config Language (reference CLI)

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
  shcl help [CMD]                        this help (or one subcommand's, with
                                         CMD); also -h or --help, which after
                                         CMD give that one's
  shcl --version                         the version (also -v or -V)
  shcl --about | --donate                what shcl is, or how to support it

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
string/raw values decode \n \t \\; a line starting with # is a script comment.

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
                                         (B kB KB MB GB TB KiB MiB GiB TiB),
                                         when the field name gives none
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
FILE or PATH begins with a dash. The flags -h, --help, -v, -V, --version,
--about and --donate count anywhere an option can go. Several in one run each
print once, in the order given.
An option a subcommand does not use is a usage error, not ignored. Also
refused: --write with --layer; --write with --set outside 'set'; --write with a
FILE of '-'; --lossy without --write; --no-banner on 'set' without --write;
--check with --write; --layer=- on 'set'; --array with --raw, --rawinfo,
--duration or --size; --default with --on-bad=error or --on-bad=flag; '-' named
more than once across FILE, --layer and --schema. Two options that ask for
different answers are a usage error whichever order they came in, and both are
named: two different type options, or one value option given two different
values. Repeating an option with the same value is allowed, and --layer and
--set are ordered lists, so they repeat.
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
`

// About and donate are stdout, so they are byte-for-byte contracts across the
// bindings the same way the help text and the init banner are. The version
// concatenates from the const above so it cannot drift from `shcl --version`.
var about = versionLine + `
Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ].
Project: https://github.com/yottacore/shcl
Licensed under the MIT License. Full text at:
  https://spdx.org/licenses/MIT.html
No warranty.

Simple Hierarchical Config Language. Forgiving to write, predictable to read.
Types live in your code, not in the file, so nothing is guessed at parse time.
One broken line is skipped with a note instead of taking down the whole file.
`

const donate = `shcl is free software under the MIT License, and stays that way.

If it saves you time and you want to give something back:
  https://github.com/sponsors/jim-collier
  https://ko-fi.com/jimcollier

A star on the project, a clear bug report, or a mention to someone who needs it
are worth just as much.
`

// The diagnostic code table behind `shcl explain`. One entry per code: a
// `CODE|severity|summary` head line, then its detail indented two spaces.
// spec.md's diagnostic tables are the long form; this is the same rules cut to
// what a terminal shows. Like the help text it is byte-for-byte across the
// bindings, and crosscheck compares every code.
const codes = `E001|error|field line under a parent holding stacked '*' list elements
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
  Only \t, \n, \\, \", \', \uXXXX and \UXXXXXXXX are escapes there, and a
  \u or \U escape must name a character. A Windows path typed in double
  quotes is the usual cause, and its \n would already be a newline, so the
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
H004|hint|a Windows path in double quotes with a \t or \n escape
  "C:\temp" reads as C:, a tab, then emp. The line loads and saves as
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
`

func statusCode(st shcl.Status) int {
	switch st {
	case shcl.Good:
		return 0
	case shcl.Empty:
		return 2
	case shcl.NotFound:
		return 3
	case shcl.BadType:
		return 4
	case shcl.Multiple:
		return 5
	}
	return 0
}

// setKind is which spelling produced one edit. They share a single ordered
// list, so two options touching the same path resolve in the order given.
type setKind int

const (
	setData setKind = iota
	setLiteral
	setDataDefault
	setLiteralDefault
	setRemove
)

// setOpt is one --set/--set-literal override. Both spellings share a list so
// they apply in the order given, which is what decides the winner when two
// target the same path.
type setOpt struct {
	path  string
	value string
	kind  setKind
}

func (s setOpt) apply(doc *shcl.Document) bool {
	switch s.kind {
	case setLiteral:
		return doc.SetLiteral(s.path, s.value)
	case setDataDefault:
		return doc.SetStringDefault(s.path, s.value)
	case setLiteralDefault:
		return doc.SetLiteralDefault(s.path, s.value)
	case setRemove:
		// Removing nothing is not a failure, the same as the ops script's
		// `remove`: the point of the option is the path's absence after.
		doc.Remove(s.path)
		return true
	}
	return doc.SetString(s.path, s.value)
}

func (s setOpt) opt() string {
	switch s.kind {
	case setLiteral:
		return "--set-literal"
	case setDataDefault:
		return "--set-default"
	case setLiteralDefault:
		return "--set-literal-default"
	case setRemove:
		return "--remove"
	}
	return "--set"
}

type kind int

const (
	kindInt kind = iota
	kindFloat
	kindBool
	kindDatetime
	kindString
	kindRaw
	kindRawInfo
	kindDuration
	kindSize
)

// The type options, as one list. kindFromOpt is still the reader; this is for
// the places that need the spellings themselves - the did-you-mean on a typo,
// and the per-subcommand help.
var typeOpts = [...]string{"--int", "--float", "--bool", "--datetime", "--string", "--raw", "--rawinfo", "--duration", "--size"}

func kindFromOpt(opt string) (kind, bool) {
	switch opt {
	case "--int":
		return kindInt, true
	case "--float":
		return kindFloat, true
	case "--bool":
		return kindBool, true
	case "--datetime":
		return kindDatetime, true
	case "--string":
		return kindString, true
	case "--raw":
		return kindRaw, true
	case "--rawinfo":
		return kindRawInfo, true
	case "--duration":
		return kindDuration, true
	case "--size":
		return kindSize, true
	}
	return kindString, false
}

func (k kind) name() string {
	switch k {
	case kindInt:
		return "int"
	case kindFloat:
		return "float"
	case kindBool:
		return "bool"
	case kindDatetime:
		return "datetime"
	case kindRaw:
		return "raw"
	case kindRawInfo:
		return "rawinfo"
	case kindDuration:
		return "duration"
	case kindSize:
		return "size"
	}
	return "string"
}

type onBad int

// was reports whether an option was given at all, which is not the same as its
// value being non-empty: `--default=` is a legitimate empty default.
func (o *opts) was(name string) bool {
	for _, s := range o.seen {
		if s == name {
			return true
		}
	}
	return false
}

func (b onBad) name() string {
	switch b {
	case onBadError:
		return "error"
	case onBadDefault:
		return "default"
	}
	return "flag"
}

const (
	onBadError onBad = iota
	onBadDefault
	onBadFlag
)

type opts struct {
	kind kind
	// Which type option was given, if any. kind cannot answer that, since it
	// starts at the default type.
	kindSet  bool
	kindOpt  kind
	kindText string // as it was typed, for the competing-pair message
	// The first competing pair the line held. Two options that ask for different
	// answers are a usage error whichever order they came in, so the pair is
	// recorded here rather than refused on the spot and the "not valid for this
	// subcommand" answer still comes first. clashOpt is set when the pair is one
	// option repeated with a different value, in which case a and b are the two
	// values; otherwise a and b are whole option spellings.
	clash    bool
	clashOpt string
	clashA   string
	clashB   string
	array    bool
	slots    bool
	def      string
	onBad    onBad
	// What an explicit --on-bad asked for, whatever the order. --default sets
	// onBad too, so without this the two options silently overwrote each other
	// and which one survived depended on which came last.
	onBadSet    bool
	onBadWanted onBad
	onBadText   string
	strictness  shcl.Strictness
	strictText  string
	write       bool
	lossy       bool
	from2x      bool
	check       bool
	noBanner    bool
	// schemaSet, not an empty schema path: `--schema=` is a path the command
	// line gave, and the other three read it and fail at exit 8 (20260918b
	// item 33, the class of 20260918 item 9).
	schema    string
	schemaSet bool
	unit      string // --unit, read against the type at check time
	unitSet   bool
	decimal   bool
	layers    []string // lower-priority layers, in listed order
	sets      []setOpt // final override layer, in the order given
	args      []string // positional: FILE [PATH]
	seen      []string // canonical names of options given, for per-command validation
	// A value option in space form that took the LAST word on the line. That
	// word is usually the FILE, and the usage line alone never says so.
	swallowedOpt   string
	swallowedValue string
}

// askedFor is the informational outputs the command line asks for, each once,
// in the order first asked. Only tokens in option position count: the value of
// a value-taking option and anything after `--` are data (a FILE or PATH
// spelled `-h` needs the `--` anyway, since the option parser would refuse it).
// Scanning values too once let a read of a missing path answer with the help
// text and exit 0. `--about` opens with the version line, so it covers
// `--version`.
func askedFor(argv []string) []string {
	var asked []string
	add := func(w string) {
		for _, a := range asked {
			if a == w {
				return
			}
		}
		asked = append(asked, w)
	}
scan:
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		switch {
		case a == "-h" || a == "--help":
			add("help")
		case a == "-v" || a == "-V" || a == "--version":
			add("version")
		case a == "--about":
			add("about")
		case a == "--donate":
			add("donate")
		case a == "--":
			break scan
		case a == "--default" || a == "--on-bad" || a == "--strictness" || a == "--schema" ||
			a == "--unit" || a == "--layer" || a == "--set" || a == "--set-literal" ||
			a == "--set-default" || a == "--set-literal-default" || a == "--remove":
			i++
		}
	}
	hasAbout := false
	for _, a := range asked {
		hasAbout = hasAbout || a == "about"
	}
	if hasAbout {
		kept := asked[:0]
		for _, a := range asked {
			if a != "version" {
				kept = append(kept, a)
			}
		}
		asked = kept
	}
	return asked
}

// infoFlags are the flags that ask for an informational output.
var infoFlags = [...]string{"-h", "--help", "-v", "-V", "--version", "--about", "--donate"}

// unusablePath: a path no document can hold, which a remove would take as a
// miss and exit 0: one the scanner rejects, or one with a value part. A
// missing path or a wildcard is still fine.
func unusablePath(doc *shcl.Document, path string) bool {
	r := doc.WriteReason(path)
	return r == shcl.BadPath || r == shcl.ValueInPath
}

// splitSet: PATH=VALUE at the first `=` outside quotes and brackets, so a
// selector holding one (`x[a=b].c=1`) still addresses its instance. The
// tokenizer reads the path half with `=` as its separator, so quotes and
// brackets mean here exactly what they mean in a file; an argument whose
// path half is not a path at all has no `=` to split at.
func splitSet(arg string) (string, string, bool) {
	var tok shcl.Tokens
	shcl.Tokenize(arg, '=', true, shcl.RulesCurrent, &tok)
	if tok.Sep < 0 {
		return "", "", false
	}
	return arg[:tok.Sep], arg[tok.Sep+1:], true
}

// asciiUpper folds a-z only. strings.ToUpper folds by Unicode, which turns a
// long s into S, so a word that is not ASCII could look up or suggest a code.
func asciiUpper(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] >= 'a' && b[i] <= 'z' {
			b[i] -= 'a' - 'A'
		}
	}
	return string(b)
}

// asciiLower folds A-Z only, mirroring the library helper the strictness option
// already goes through. strings.ToLower folds by Unicode, which is a different
// question from "is this one of three ASCII words".
func asciiLower(s string) string {
	i := 0
	for ; i < len(s); i++ {
		if s[i] >= 'A' && s[i] <= 'Z' {
			break
		}
	}
	if i == len(s) {
		return s
	}
	b := []byte(s)
	for ; i < len(b); i++ {
		if b[i] >= 'A' && b[i] <= 'Z' {
			b[i] += 'a' - 'A'
		}
	}
	return string(b)
}

// Record the first competing pair. Only the first is kept: the line is already
// a usage error, and a second pair would just change which one gets named.
func (o *opts) noteClash(opt, a, b string) {
	if !o.clash {
		o.clash, o.clashOpt, o.clashA, o.clashB = true, opt, a, b
	}
}

func setValueOpt(o *opts, name, v string) error {
	switch name {
	case "--default":
		if o.was("--default") && o.def != v {
			o.noteClash("--default", o.def, v)
		}
		o.def = v
		o.onBad = onBadDefault
		o.seen = append(o.seen, "--default")
	case "--on-bad":
		var mode onBad
		switch asciiLower(v) {
		case "error":
			mode = onBadError
		case "default":
			mode = onBadDefault
		case "flag":
			mode = onBadFlag
		default:
			return fmt.Errorf("bad --on-bad value: %s (see --help)", v)
		}
		if o.onBadSet && o.onBadWanted != mode {
			o.noteClash("--on-bad", o.onBadText, v)
		}
		o.onBad = mode
		o.seen = append(o.seen, "--on-bad")
		o.onBadSet, o.onBadWanted, o.onBadText = true, mode, v
	case "--strictness":
		s, ok := shcl.StrictnessFromArg(v)
		if !ok {
			return fmt.Errorf("bad --strictness value: %s (see --help)", v)
		}
		if o.was("--strictness") && o.strictness != s {
			o.noteClash("--strictness", o.strictText, v)
		}
		o.strictness = s
		o.strictText = v
		o.seen = append(o.seen, "--strictness")
	case "--schema":
		if o.schemaSet && o.schema != v {
			o.noteClash("--schema", o.schema, v)
		}
		o.schema = v
		o.schemaSet = true
		o.seen = append(o.seen, "--schema")
	case "--unit":
		if o.unitSet && o.unit != v {
			o.noteClash("--unit", o.unit, v)
		}
		o.unit = v
		o.unitSet = true
		o.seen = append(o.seen, "--unit")
	case "--layer":
		o.layers = append(o.layers, v)
		o.seen = append(o.seen, "--layer")
	case "--remove":
		if v == "" {
			return fmt.Errorf("bad --remove value (want PATH) (see --help)")
		}
		if unusablePath(shcl.New(), v) {
			return fmt.Errorf("bad --remove value (not a usable path): %s (see --help)", v)
		}
		o.sets = append(o.sets, setOpt{path: v, kind: setRemove})
		o.seen = append(o.seen, "--remove")
	case "--set", "--set-literal", "--set-default", "--set-literal-default":
		p, val, ok := splitSet(v)
		if !ok || p == "" {
			return fmt.Errorf("bad %s value (want PATH=VALUE, quotes and brackets balanced): %s (see --help)", name, v)
		}
		k := setData
		switch name {
		case "--set-literal":
			k = setLiteral
		case "--set-default":
			k = setDataDefault
		case "--set-literal-default":
			k = setLiteralDefault
		}
		o.sets = append(o.sets, setOpt{path: p, value: val, kind: k})
		o.seen = append(o.seen, name)
	}
	return nil
}

// editDistance is the Levenshtein distance capped at cap; past it, cap + 1.
// The validator has one of these for schema field names, but it is not
// exported and the CLI's lists are a dozen short words, so the CLI computes
// its own.
func editDistance(a, b string, cap int) int {
	ar, br := []rune(a), []rune(b)
	inf := cap + 1
	gap := len(ar) - len(br)
	if gap < 0 {
		gap = -gap
	}
	if gap > cap {
		return inf
	}
	prev := make([]int, len(br)+1)
	cur := make([]int, len(br)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ar); i++ {
		cur[0] = i
		for j := 1; j <= len(br); j++ {
			cost := 1
			if ar[i-1] == br[j-1] {
				cost = 0
			}
			cur[j] = prev[j] + 1
			if cur[j-1]+1 < cur[j] {
				cur[j] = cur[j-1] + 1
			}
			if prev[j-1]+cost < cur[j] {
				cur[j] = prev[j-1] + cost
			}
		}
		prev, cur = cur, prev
	}
	if prev[len(br)] > inf {
		return inf
	}
	return prev[len(br)]
}

// suggest is "; did you mean 'x'?" for the nearest candidate within two edits,
// or nothing. Same wording the validator's unknown-field suggestion uses, and
// prose either way - a typo's exit code is 1 whether or not this has an idea.
func suggest(cands []string, word string) string {
	// Every candidate is ASCII, and C counts distance in bytes where the other
	// three count characters, so a word that is not ASCII gets no suggestion
	// rather than one the four bindings could disagree on.
	for i := 0; i < len(word); i++ {
		if word[i] >= 0x80 {
			return ""
		}
	}
	w := asciiLower(word)
	best, bestDist := "", 3
	for _, c := range cands {
		if d := editDistance(w, asciiLower(c), 2); d <= 2 && d < bestDist {
			best, bestDist = c, d
		}
	}
	if best == "" {
		return ""
	}
	return "; did you mean '" + best + "'?"
}

// commandNames is every command word, for the same. The informational flags
// are in the list too, so a word left over from 2.x, such as `version`, points
// at its flag.
func commandNames() []string {
	return append(commands[:], "help", "--version", "--about", "--donate")
}

// optionNames is every option spelling some subcommand takes. Built from the
// table checkOpts judges against, so a new option becomes suggestable the
// moment it is accepted somewhere.
func optionNames() []string {
	// The informational flags are in no subcommand's table but are options to
	// anyone typing one.
	v := []string{"--help", "--version", "--about", "--donate"}
	has := func(name string) bool {
		for _, x := range v {
			if x == name {
				return true
			}
		}
		return false
	}
	for _, cmd := range commands {
		for _, o := range allowedOpts(cmd) {
			if o == "--<type>" {
				for _, t := range typeOpts {
					if !has(t) {
						v = append(v, t)
					}
				}
			} else if !has(o) {
				v = append(v, o)
			}
		}
	}
	return v
}

// knownOption is a real option by any spelling, -w included. The suggestions
// draw on optionNames alone, which leaves the short form out.
func knownOption(name string) bool {
	if name == "-w" {
		return true
	}
	for _, n := range optionNames() {
		if n == name {
			return true
		}
	}
	return false
}

func parseOpts(argv []string) (*opts, error) {
	o := &opts{kind: kindString, onBad: onBadFlag, strictness: shcl.Standard}
	// Value-taking options accept both --opt=VALUE and the space form --opt VALUE.
	for i := 0; i < len(argv); i++ {
		a := argv[i]
		// Everything after `--` is positional, so a file or path may begin
		// with a dash.
		if a == "--" {
			o.args = append(o.args, argv[i+1:]...)
			return o, nil
		}
		if k, ok := kindFromOpt(a); ok {
			if o.kindSet && o.kindOpt != k {
				o.noteClash("", o.kindText, a)
			}
			o.kind = k
			o.kindSet, o.kindOpt, o.kindText = true, k, a
			o.seen = append(o.seen, "--<type>")
			continue
		}
		switch {
		case a == "--array":
			o.array = true
			o.seen = append(o.seen, "--array")
		case a == "--slots":
			o.slots = true
			o.seen = append(o.seen, "--slots")
		case a == "--write" || a == "-w":
			o.write = true
			o.seen = append(o.seen, "--write")
		case a == "--lossy":
			o.lossy = true
			o.seen = append(o.seen, "--lossy")
		case a == "--from-2x":
			o.from2x = true
			o.seen = append(o.seen, "--from-2x")
		case a == "--check":
			o.check = true
			o.seen = append(o.seen, "--check")
		case a == "--no-banner":
			o.noBanner = true
			o.seen = append(o.seen, "--no-banner")
		case a == "--decimal":
			o.decimal = true
			o.seen = append(o.seen, "--decimal")
		case a == "--default" || a == "--on-bad" || a == "--strictness" || a == "--schema" ||
			a == "--unit" || a == "--layer" || a == "--set" || a == "--set-literal" ||
			a == "--set-default" || a == "--set-literal-default" || a == "--remove":
			i++
			if i >= len(argv) {
				return nil, fmt.Errorf("missing value for %s (try %s=VALUE)", a, a)
			}
			if err := setValueOpt(o, a, argv[i]); err != nil {
				return nil, err
			}
			if i+1 == len(argv) {
				o.swallowedOpt, o.swallowedValue = a, argv[i]
			}
		case strings.HasPrefix(a, "--layer="):
			if err := setValueOpt(o, "--layer", a[len("--layer="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--set-literal-default="):
			if err := setValueOpt(o, "--set-literal-default", a[len("--set-literal-default="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--set-literal="):
			if err := setValueOpt(o, "--set-literal", a[len("--set-literal="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--set-default="):
			if err := setValueOpt(o, "--set-default", a[len("--set-default="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--remove="):
			if err := setValueOpt(o, "--remove", a[len("--remove="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--set="):
			if err := setValueOpt(o, "--set", a[len("--set="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--default="):
			if err := setValueOpt(o, "--default", a[len("--default="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--on-bad="):
			if err := setValueOpt(o, "--on-bad", a[len("--on-bad="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--schema="):
			if err := setValueOpt(o, "--schema", a[len("--schema="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--unit="):
			if err := setValueOpt(o, "--unit", a[len("--unit="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "--strictness="):
			if err := setValueOpt(o, "--strictness", a[len("--strictness="):]); err != nil {
				return nil, err
			}
		case strings.HasPrefix(a, "-") && len(a) > 1:
			// The suggestion is against the name half: `--stricness=1` is a typo
			// in the option, not in a spelling that includes a value.
			name := strings.SplitN(a, "=", 2)[0]
			// Every value option is matched above, so a real name here is a flag
			// given a value. Calling it unknown would suggest it back.
			if knownOption(name) {
				return nil, fmt.Errorf("option %s takes no value (see --help)", name)
			}
			return nil, fmt.Errorf("unknown option: %s%s (see --help)", a,
				suggest(optionNames(), name))
		default:
			o.args = append(o.args, a)
		}
	}
	return o, nil
}

// allowedOpts is the options each subcommand takes. checkOpts judges against
// it, the per-subcommand help is cut from the full help with it, and the shell
// completions carry the same table (check-completions.bash diffs the two).
func allowedOpts(cmd string) []string {
	var allowed []string
	switch cmd {
	case "get":
		allowed = []string{"--<type>", "--array", "--slots", "--unit", "--decimal", "--default", "--on-bad", "--strictness",
			"--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove"}
	case "set":
		allowed = []string{"--strictness", "--layer", "--set", "--set-literal", "--set-default",
			"--set-literal-default", "--remove", "--write", "--lossy", "--no-banner"}
	case "fmt":
		allowed = []string{"--write", "--lossy", "--check", "--strictness", "--layer", "--set", "--set-literal",
			"--set-default", "--set-literal-default", "--remove"}
	case "check":
		allowed = []string{"--strictness", "--schema"}
	case "init":
		allowed = []string{"--schema", "--no-banner"}
	case "migrate":
		allowed = []string{"--write", "--lossy", "--from-2x", "--check"}
	case "tokens", "explain":
		allowed = []string{}
	case "count", "instances", "children", "paths":
		allowed = []string{"--strictness", "--layer", "--set", "--set-literal", "--set-default",
			"--set-literal-default", "--remove"}
	}
	return allowed
}

// helpTopic is the subcommand a help asks about, or "" for none. `shcl help
// CMD` names it after the word, which takes one topic at most and the
// informational flags; `shcl CMD --help` names it first. A help flag after
// `help` asks for the same thing twice, so it is no topic. An empty word is
// still a topic, as it is in the reference: it names no command, which is not
// the same as naming none. A usage error comes back as its exit code.
func helpTopic(argv []string) (string, int) {
	topic, hasTopic := "", false
	if len(argv) == 0 {
		return "", 0
	}
	if argv[0] == "help" {
		var words []string
		for _, w := range argv[1:] {
			flag := false
			for _, f := range infoFlags {
				flag = flag || w == f
			}
			if !flag {
				words = append(words, w)
			}
		}
		if len(words) > 1 {
			fmt.Fprintln(os.Stderr, "usage: shcl help [CMD] (see --help)")
			return "", 1
		}
		if len(words) == 1 {
			topic, hasTopic = words[0], true
		}
	} else if !strings.HasPrefix(argv[0], "-") {
		topic, hasTopic = argv[0], true
	}
	if !hasTopic || topic == "help" {
		return "", 0
	}
	for _, c := range commands {
		if c == topic {
			return topic, 0
		}
	}
	fmt.Fprintf(os.Stderr, "unknown command: %s%s (see --help)\n", topic, suggest(commandNames(), topic))
	return "", 1
}

// helpFor is one subcommand's slice of the help: its usage entry, the type
// block when it takes one, and the option entries allowedOpts lets it have.
// Cut from the full help rather than written out a second time, so the two
// cannot drift and the four bindings stay byte-identical for free. An entry
// keeps the "(get)" style annotation it carries there, which still reads true.
func helpFor(cmd string) string {
	var out strings.Builder
	out.WriteString("Usage:\n")
	lines := strings.Split(help, "\n")
	want := "  shcl " + cmd + " "
	taking := false
	for _, l := range lines {
		if strings.HasPrefix(l, "  shcl ") {
			taking = strings.HasPrefix(l, want)
		} else if taking && !strings.HasPrefix(l, "   ") {
			taking = false
		}
		if taking {
			out.WriteString(l + "\n")
		}
	}
	// A paragraph of the full help that opens with the subcommand's own name is
	// that subcommand's - today that is set's write-ops block, which is the
	// half of set a user most needs in front of them.
	lead := cmd + " "
	for i, l := range lines {
		if !strings.HasPrefix(l, lead) {
			continue
		}
		out.WriteString("\n")
		for _, p := range lines[i:] {
			if p == "" {
				break
			}
			out.WriteString(p + "\n")
		}
		break
	}
	allowed := allowedOpts(cmd)
	takesType := false
	for _, a := range allowed {
		if a == "--<type>" {
			takesType = true
		}
	}
	if takesType {
		for i, l := range lines {
			if !strings.HasPrefix(l, "Types (") {
				continue
			}
			out.WriteString("\n")
			for _, p := range lines[i:] {
				if p == "" {
					break
				}
				out.WriteString(p + "\n")
			}
			break
		}
	}
	// The option entries, in the order the full help lists them. A head line is
	// `  --name`; the deeper-indented lines under it are its text, and the
	// first line at column zero ends the block.
	var entries strings.Builder
	inBlock, keep := false, false
	for _, l := range lines {
		if !inBlock {
			inBlock = strings.HasPrefix(l, "Options (")
			continue
		}
		if strings.HasPrefix(l, "  --") {
			name := strings.FieldsFunc(l[2:], func(r rune) bool { return r == '=' || r == ' ' })[0]
			keep = false
			for _, a := range allowed {
				if a == name {
					keep = true
				}
			}
		} else if !strings.HasPrefix(l, "   ") {
			break
		}
		if keep {
			entries.WriteString(l + "\n")
		}
	}
	if entries.Len() == 0 {
		out.WriteString("\n" + cmd + " takes no options.\n")
	} else {
		out.WriteString("\nOptions (the subcommands each belongs to are in parentheses):\n")
		out.WriteString(entries.String())
	}
	out.WriteString("\nSee 'shcl help' for the full text, and 'shcl explain CODE' for a code.\n")
	return out.String()
}

// Every option must be meaningful for its subcommand; an option that would be
// silently ignored (`set --write` before it existed, `--schema` on `get`) is a
// usage error instead.
func checkOpts(cmd string, o *opts) int {
	allowed := allowedOpts(cmd)
	for _, s := range o.seen {
		ok := false
		for _, a := range allowed {
			if s == a {
				ok = true
				break
			}
		}
		if !ok {
			if s == "--<type>" {
				fmt.Fprintf(os.Stderr, "type options are not valid for %s (see --help)\n", cmd)
			} else if cmd == "init" && s == "--strictness" {
				// Deliberate, not an oversight: the schema is a program artifact,
				// so it always loads at Standard - the same rule `check --schema`
				// follows for the schema half.
				fmt.Fprintln(os.Stderr, "option --strictness not valid for init: a schema always loads at "+
					"standard strictness, being a program artifact rather than user data (see --help)")
			} else if cmd == "check" && (s == "--layer" || s == "--set" || s == "--set-literal" ||
				s == "--set-default" || s == "--set-literal-default" || s == "--remove") {
				// The one refusal a user is likely to want anyway: check reports
				// line numbers, and a merged document has no single file to
				// number against. Naming the pipeline turns a dead end into a
				// one-liner.
				fmt.Fprintf(os.Stderr, "option %s not valid for check: diagnostics cite line numbers, "+
					"which a merged document has none of. Pipe instead: "+
					"shcl fmt %s ... FILE | shcl check --schema=SCHEMA -\n", s, s)
			} else {
				fmt.Fprintf(os.Stderr, "option %s not valid for %s (see --help)\n", s, cmd)
			}
			return 1
		}
	}
	// Options that ask for different answers used to resolve last-wins with
	// nothing said, so which answer you got depended on typing order. Two type
	// options are one case, one value option given two values the other.
	// Repeating an option with the same value competes with nothing and stays
	// allowed, and so do --layer and --set, which are ordered lists.
	if o.clash {
		if o.clashOpt != "" {
			fmt.Fprintf(os.Stderr, "%s=%s cannot be combined with %s=%s (see --help)\n",
				o.clashOpt, o.clashA, o.clashOpt, o.clashB)
		} else {
			fmt.Fprintf(os.Stderr, "%s cannot be combined with %s (see --help)\n", o.clashA, o.clashB)
		}
		return 1
	}
	// --unit and --decimal say how to read a bare number, which only the
	// duration and size reads have.
	if o.unitSet && o.kind != kindDuration && o.kind != kindSize {
		fmt.Fprintln(os.Stderr, "--unit needs --duration or --size (see --help)")
		return 1
	}
	if o.decimal && o.kind != kindSize {
		fmt.Fprintln(os.Stderr, "--decimal needs --size (see --help)")
		return 1
	}
	if o.unitSet {
		known := false
		if o.kind == kindDuration {
			_, known = shcl.DurationUnitFromSpelling(o.unit)
		} else {
			_, known = shcl.SizeUnitFromSpelling(o.unit)
		}
		if !known {
			fmt.Fprintf(os.Stderr, "bad --unit value for --%s: %s (see --help)\n", o.kind.name(), o.unit)
			return 1
		}
	}
	// Writing back the merged document would fold the lower layers permanently
	// into the top file, which is the opposite of what layering is for. On 'set'
	// the --set values are edits to the document rather than a layer over it, so
	// persisting them is the whole point; everywhere else they stay ephemeral.
	if o.write && len(o.layers) > 0 {
		fmt.Fprintln(os.Stderr, "--write cannot be combined with --layer (see --help)")
		return 1
	}
	if o.write && len(o.sets) > 0 && cmd != "set" {
		fmt.Fprintf(os.Stderr, "--write cannot be combined with %s (see --help)\n", o.sets[0].opt())
		return 1
	}
	// --default says "substitute this" and --on-bad=error says "fail instead", so
	// the two together are a contradiction. Each used to overwrite the other's
	// mode, which made the answer depend on the order they were typed in.
	if o.was("--default") && o.onBadSet && o.onBadWanted != onBadDefault {
		fmt.Fprintf(os.Stderr, "--default cannot be combined with --on-bad=%s (see --help)\n", o.onBadWanted.name())
		return 1
	}
	// --lossy only overrides the in-place write's refusal, so on its own it says
	// nothing and would read as protection the command never had.
	if o.lossy && !o.write {
		fmt.Fprintln(os.Stderr, "--lossy is only meaningful with --write (see --help)")
		return 1
	}
	// On set, --no-banner shapes only the file a write creates, so without
	// --write it would be accepted and do nothing.
	if o.noBanner && cmd == "set" && !o.write {
		fmt.Fprintln(os.Stderr, "--no-banner is only meaningful with --write (see --help)")
		return 1
	}
	if o.check && o.write {
		fmt.Fprintln(os.Stderr, "--check cannot be combined with --write (see --help)")
		return 1
	}
	// The ops script already has stdin, so a layer cannot read it too.
	if cmd == "set" {
		for _, l := range o.layers {
			if l == "-" {
				fmt.Fprintln(os.Stderr, "--layer=- is not valid for set: stdin carries the ops script or the document (see --help)")
				return 1
			}
		}
	}
	// Stdin reads once; a second '-' would silently get an empty document.
	stdinUses := 0
	for _, l := range o.layers {
		if l == "-" {
			stdinUses++
		}
	}
	if o.schema == "-" {
		stdinUses++
	}
	if len(o.args) > 0 && o.args[0] == "-" {
		stdinUses++
	}
	if stdinUses > 1 {
		fmt.Fprintln(os.Stderr, "'-' (stdin) can be named only once across FILE, --layer and --schema")
		return 1
	}
	return 0
}

// describeRefusal is the per-binding wording behind a setter's bare false: why
// a write was refused. When the path itself is fine what failed is the text,
// and only the caller knows which half of the op that was, so it names it: a
// setter refused for its value used to report the sentence written for
// SetLiteral whatever the op.
func describeRefusal(doc *shcl.Document, path, unwritable string) string {
	switch doc.WriteReason(path) {
	case shcl.Writable:
		return unwritable
	case shcl.ValueInPath:
		return "a path with a value part cannot be written"
	case shcl.Wildcard:
		return "a wildcard path cannot be written"
	case shcl.NoSuchIndex:
		return "no instance at that index"
	case shcl.TooDeep:
		return "deeper than the nesting cap"
	}
	return "not a usable path" // BadPath
}

// sayDiagnostics prints the load's diagnostics, one line each, in the shape
// every command uses.
func sayDiagnostics(diags []shcl.Diagnostic) {
	sayDiagnosticsFrom("", diags)
}

// sayDiagnosticsFrom is the same, labeled with the file the diagnostics came
// from. Under --layer several files are loaded and their line numbers share one
// space on the screen, so two layers with a bad line 2 printed the same thing
// twice with nothing to tell them apart.
func sayDiagnosticsFrom(file string, diags []shcl.Diagnostic) {
	for _, d := range diags {
		// V090-V095 carry a schema line; V096 and V097 are about generation as a
		// whole and carry line 0, so "schema line 0" named a line space they are
		// not in. V099 stands for a schema that did not load and is line 0 too.
		space := "line"
		if strings.HasPrefix(d.Code, "V09") && d.Code != "V096" && d.Code != "V097" && d.Code != "V099" {
			space = "schema line"
		}
		if file == "" {
			fmt.Fprintf(os.Stderr, "%s %d: %s: %s %s\n", space, d.Line, d.Severity, d.Code, d.Message)
		} else {
			fmt.Fprintf(os.Stderr, "%s %s %d: %s: %s %s\n", file, space, d.Line, d.Severity, d.Code, d.Message)
		}
	}
}

// exitIO is a file or stream that could not be read or written. Its own code
// since a script's remedy - fix the path, the permissions, the disk - has
// nothing to do with the remedy for a usage error, which keeps 1.
const exitIO = 8

// unchangedSinceRead says whether FILE still holds the bytes the load read.
// `set` waits on stdin between the load and the save, and an edit made in that
// wait was reverted at exit 0. A gap is left between this read and the
// publish, the width of one save.
func unchangedSinceRead(file, before string) bool {
	now, err := os.ReadFile(file)
	if err == nil && string(now) == before {
		return true
	}
	fmt.Fprintf(os.Stderr, "%s: changed since it was read; nothing written\n", file)
	return false
}

// writeTargetOK says whether a --write FILE is a regular file or nothing yet.
// Asked before the read, since reading a FIFO takes what was written to it and
// the save would then refuse it anyway. A directory is left to the read, which
// names it.
func writeTargetOK(file string) bool {
	if st, err := os.Stat(file); err == nil && !st.Mode().IsRegular() && !st.IsDir() {
		fmt.Fprintf(os.Stderr, "%s: not a regular file\n", file)
		return false
	}
	// A windows reserved name with no device behind it is not there to stat.
	if notADiskFile(file) {
		fmt.Fprintf(os.Stderr, "%s: not a regular file\n", file)
		return false
	}
	return true
}

// notADiskFile is the windows device test; the windows build swaps it in
// (main_windows.go), the same way the library does it. POSIX has no device name
// at a path, so the default answers false.
var notADiskFile = func(string) bool { return false }

// No stream on the other end at all, as opposed to one that failed part way
// through. POSIX says EBADF; windows has no single answer - a handle a shell
// closed comes back as an invalid handle or an invalid function depending on
// how it was closed, and the runtimes map those to their own codes.
func stdinUnattached(err error) bool {
	// Windows hands back a handle that is not a handle, and the runtime answers
	// with its own "invalid argument" rather than a system error number.
	if errors.Is(err, os.ErrInvalid) || errors.Is(err, os.ErrClosed) {
		return true
	}
	var errno syscall.Errno
	if !errors.As(err, &errno) {
		return false
	}
	if errno == syscall.EBADF {
		return true
	}
	return runtime.GOOS == "windows" && (errno == 1 || errno == 6 || errno == syscall.EINVAL)
}

func readInput(file string) (string, error) {
	var b []byte
	var err error
	if file == "-" {
		b, err = io.ReadAll(os.Stdin)
		if err != nil {
			// A stdin that is not attached at all reads as an empty document.
			// POSIX gives EOF for that; windows answers "invalid handle".
			if !stdinUnattached(err) {
				return "", fmt.Errorf("stdin: %w", err)
			}
			b = nil
		}
	} else {
		// The message for reading a directory is the platform's, and windows
		// spells it four different ways depending on the binding. Say it here.
		if fi, serr := os.Stat(file); serr == nil && fi.IsDir() {
			return "", fmt.Errorf("%s: Is a directory", file)
		}
		b, err = os.ReadFile(file)
		if err != nil {
			// FILE: and the system's own message, as the UI guide has it. The
			// path error would name the call and the path a second time.
			var pe *fs.PathError
			if errors.As(err, &pe) {
				err = pe.Err
			}
			return "", fmt.Errorf("%s: %w", file, err)
		}
	}
	// The reference reads as UTF-8 and fails on bad bytes; match its exit path.
	if !utf8.Valid(b) {
		return "", fmt.Errorf("%s: stream did not contain valid UTF-8", file)
	}
	return string(b), nil
}

// loadDocFrom is a load labeled with the file the text came from, so a strict
// failure in one layer of a fold says which layer.
func loadDocFrom(file, text string, strictness shcl.Strictness, keep bool) (*shcl.Document, int) {
	load := shcl.ParseWith
	if keep {
		load = shcl.ParseKeepLines
	}
	doc, err := load(text, strictness)
	if err != nil {
		// Checked form: this is the top-level error path, so a future error type
		// here has to report rather than panic.
		if le, ok := err.(*shcl.LoadError); ok {
			sayDiagnosticsFrom(file, le.Diagnostics)
			errorCount := 0
			for _, d := range le.Diagnostics {
				if d.Severity == shcl.SeverityError {
					errorCount++
				}
			}
			fmt.Fprintf(os.Stderr, "strict load failed: %d error diagnostic(s)\n", errorCount)
		} else {
			fmt.Fprintln(os.Stderr, err)
		}
		return nil, 6
	}
	return doc, 0
}

// writeBack is the in-place half of fmt/set. Overwriting the source is the one
// place a recovered load turns destructive, so the diagnostics go out even
// though the command succeeded, and the save runs through the library's own
// gate rather than a second copy of the rule - the CLI and a consumer program
// cannot then disagree about which rewrites are safe.
// read is the bytes FILE held when the command read it, and nil when this
// write is creating FILE.
func writeBack(doc *shcl.Document, file string, o *opts, read *string, keep bool) int {
	if read != nil && !unchangedSinceRead(file, *read) {
		return exitIO
	}
	// Nothing to write: what the save would publish is already on disk. A
	// rewrite would give the file a new inode and mtime for nothing, so an
	// idempotent --set-default in a provisioning script reported a change on
	// every run, watchers fired, other hard links broke, and a canonical file
	// in a read-only directory failed. The refusal comes first: a load that
	// dropped content refuses the write whatever the bytes say, unless the
	// lines were kept, which writes the dropped lines back as they were.
	var text string
	kept := false
	if keep {
		text, kept = doc.ToTextKeepLines()
	} else {
		text = doc.ToCanonical()
	}
	if read != nil && (o.lossy || kept || doc.LostCount() == 0) && text == *read {
		return 0
	}
	// The text is already built, so the line-keeping save writes it rather
	// than building it again, with the same refusal SaveFileKeepLines makes
	// (20260926 idea 3).
	var werr error
	switch {
	case o.lossy && keep:
		werr = shcl.WriteFileAtomic(file, text)
	case o.lossy:
		werr = doc.SaveFileLossy(file)
	case keep && !kept && doc.LostCount() > 0:
		werr = &shcl.SaveRefused{Path: file, Lost: doc.LostCount()}
	case keep:
		werr = shcl.WriteFileAtomic(file, text)
	default:
		werr = doc.SaveFile(file)
	}
	if werr == nil {
		// A created file is the one write with nothing to compare against
		// afterwards, and a typo in the name used to end at exit 0 with an
		// empty stderr and a new file nobody asked for.
		if read == nil {
			fmt.Fprintf(os.Stderr, "%s: created\n", file)
		}
		// A save meant to keep the lines rewrote the whole file, and that is
		// worth a line (20260926 idea 2).
		if keep && !kept {
			fmt.Fprintf(os.Stderr, "%s: rewritten in the canonical form; the lines could not be kept as they were\n", file)
		}
		return 0
	}
	// The rule stays in the library; only the wording is the CLI's, because the
	// override a user has here is a flag, not a function.
	var refused *shcl.SaveRefused
	if errors.As(werr, &refused) {
		fmt.Fprintf(os.Stderr, "%s: refusing to rewrite: the load dropped %d line(s)/value(s) "+
			"this write would delete (--lossy overrides)\n", file, refused.Lost)
		return 7
	}
	fmt.Fprintln(os.Stderr, werr)
	return exitIO
}

// loadLayered loads file with o's lower-priority --layer files underneath and
// its --set overrides on top - the layered-load fold. Every layer parses at the
// requested strictness; a strict-load failure on any layer aborts like a
// single-file strict failure (exit 6). Returns (doc, 0) or (nil, code).
//
// It prints every layer's diagnostics itself, lowest first, before the --set
// overrides run: they belong to the load, and a refused edit used to return
// with nothing said about them. A merge does not carry diagnostics over, so
// reading them off the merged document drops the ones for FILE itself, which
// is the one the caller named.
func loadLayered(o *opts, file string) (*shcl.Document, int) {
	doc, _, code := loadLayeredFrom(o, file, nil, false)
	return doc, code
}

// loadLayeredFrom is the same fold with FILE's text given rather than read,
// which is how `set` creates a file or takes an empty document, and FILE's
// text handed back. `set` kept its own copy of the fold, and twice a fix to
// this one missed it.
func loadLayeredFrom(o *opts, file string, given *string, keep bool) (*shcl.Document, string, int) {
	texts := make([]string, 0, len(o.layers)+1)
	for _, lf := range o.layers {
		t, err := readInput(lf)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return nil, "", exitIO
		}
		texts = append(texts, t)
	}
	var base string
	if given != nil {
		base = *given
	} else {
		t, err := readInput(file)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return nil, "", exitIO
		}
		base = t
	}
	texts = append(texts, base)
	// Lowest layer first, each labeled with its own file when there is more
	// than one: the line numbers share a space on the screen otherwise, and two
	// layers with a bad line 2 printed the same thing twice.
	names := append(append([]string(nil), o.layers...), file)
	label := func(i int) string {
		if len(names) > 1 {
			return names[i]
		}
		return ""
	}
	// Only a document with no layers under it keeps its lines: a merge drops them.
	doc, code := loadDocFrom(label(0), texts[0], o.strictness, keep && len(texts) == 1)
	if code != 0 {
		return nil, "", code
	}
	sayDiagnosticsFrom(label(0), doc.Diagnostics())
	for i, t := range texts[1:] {
		over, c := loadDocFrom(label(i+1), t, o.strictness, false)
		if c != 0 {
			return nil, "", c
		}
		sayDiagnosticsFrom(label(i+1), over.Diagnostics())
		doc.Merge(over)
	}
	for _, s := range o.sets {
		if !s.apply(doc) {
			fmt.Fprintf(os.Stderr, "%s: cannot write %s: %s\n", s.opt(), s.path, describeRefusal(doc, s.path, "the value text is not one value"))
			return nil, "", 1
		}
	}
	return doc, base, 0
}

// doGet: one value read, formatted for the shell: scalars print as one line,
// arrays one element per line.
func doGet(o *opts) int {
	if len(o.args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: shcl get [type] [options] FILE PATH (see --help)")
		return 1
	}
	file, path := o.args[0], o.args[1]
	doc, code := loadLayered(o, file)
	if doc == nil {
		return code
	}
	var lines []string
	var status shcl.Status
	var slots []shcl.Status
	if o.array {
		switch o.kind {
		case kindInt:
			r := doc.ReadIntArray(path)
			for _, v := range r.Value {
				lines = append(lines, fmt.Sprintf("%d", v))
			}
			status = r.Status
			slots = r.Slots
		case kindFloat:
			r := doc.ReadFloatArray(path)
			for _, v := range r.Value {
				lines = append(lines, shcl.FormatFloat(v))
			}
			status = r.Status
			slots = r.Slots
		case kindBool:
			r := doc.ReadBoolArray(path)
			for _, v := range r.Value {
				lines = append(lines, fmt.Sprintf("%t", v))
			}
			status = r.Status
			slots = r.Slots
		case kindDatetime:
			r := doc.ReadDateTimeArray(path)
			for _, v := range r.Value {
				lines = append(lines, v.String())
			}
			status = r.Status
			slots = r.Slots
		case kindRaw, kindRawInfo, kindDuration, kindSize:
			fmt.Fprintf(os.Stderr, "--%s has no --array form (see --help)\n", o.kind.name())
			return 1
		default:
			r := doc.ReadStringArray(path)
			lines = r.Value
			status = r.Status
			slots = r.Slots
		}
	} else {
		switch o.kind {
		case kindInt:
			r := doc.ReadInt(path)
			lines = []string{fmt.Sprintf("%d", r.Value)}
			status = r.Status
		case kindFloat:
			r := doc.ReadFloat(path)
			lines = []string{shcl.FormatFloat(r.Value)}
			status = r.Status
		case kindBool:
			r := doc.ReadBool(path)
			lines = []string{fmt.Sprintf("%t", r.Value)}
			status = r.Status
		case kindDatetime:
			r := doc.ReadDateTime(path)
			lines = []string{r.Value.String()}
			status = r.Status
		case kindRaw:
			r := doc.ReadRaw(path)
			lines = []string{r.Value}
			status = r.Status
		case kindRawInfo:
			r := doc.ReadRawInfo(path)
			lines = []string{r.Value}
			status = r.Status
		case kindDuration:
			unit, _ := shcl.DurationUnitFromSpelling(o.unit)
			r := doc.ReadDuration(path, unit)
			lines = []string{fmt.Sprintf("%d", r.Value.Milliseconds())}
			status = r.Status
		case kindSize:
			unit, _ := shcl.SizeUnitFromSpelling(o.unit)
			r := doc.ReadSize(path, unit, o.decimal)
			lines = []string{fmt.Sprintf("%d", r.Value)}
			status = r.Status
		default:
			r := doc.ReadString(path)
			lines = []string{r.Value}
			status = r.Status
		}
	}
	// Per-line slot status: falls back to the aggregate for scalar reads.
	slotAt := func(i int) shcl.Status {
		if i < len(slots) {
			return slots[i]
		}
		return status
	}
	// An array or a slot listing is one line per element, so a value holding a
	// line break takes its escaped spelling there. A plain scalar read prints
	// the value as it is, since the whole output is that one value.
	emit := func(lines []string) {
		for i, l := range lines {
			if o.slots {
				outf("%s\t%s\n", slotAt(i), oneLine(l))
			} else if o.array {
				outln(oneLine(l))
			} else {
				outln(l)
			}
		}
	}
	// Why the read failed is worth saying even when the exit code already
	// carries it: at the default mode the user otherwise gets an empty line, a
	// nonzero code, and nothing to go on. Stdout is untouched - this only ever
	// goes to stderr. Two silences are deliberate: default mode, because a
	// caller who supplied a fallback has already said the miss is expected, and
	// Empty outside error mode, because an empty value is a legitimate answer
	// here rather than a failure - the same reason Ok counts it as fine.
	if status != shcl.Good && o.onBad != onBadDefault && (status != shcl.Empty || o.onBad == onBadError) {
		typeName := o.kind.name()
		if o.array {
			typeName = o.kind.name() + " array"
		}
		var reason string
		switch status {
		case shcl.BadType:
			if raw := doc.ReadString(path).Raw; raw != nil {
				reason = fmt.Sprintf("value %s is not a valid %s", quoted(*raw), typeName)
			} else {
				reason = fmt.Sprintf("value is not a valid %s", typeName)
			}
		case shcl.NotFound:
			reason = "no value at that path"
		case shcl.Empty:
			reason = "the value is empty"
		case shcl.Multiple:
			reason = "the path matches multiple instances"
		}
		fmt.Fprintf(os.Stderr, "cannot read %s as %s: %s (in %s)\n", path, typeName, reason, file)
	}
	switch {
	case status == shcl.Good || (status == shcl.Empty && o.onBad == onBadFlag):
		emit(lines)
		return statusCode(status)
	case o.onBad == onBadDefault:
		if len(slots) > 0 {
			// Array read: the default substitutes per bad slot; alignment holds.
			subbed := make([]string, len(lines))
			for i, l := range lines {
				if slotAt(i) == shcl.Good {
					subbed[i] = l
				} else {
					subbed[i] = o.def
				}
			}
			emit(subbed)
		} else if o.slots {
			outf("%s\t%s\n", status, oneLine(o.def))
		} else if o.array {
			outln(oneLine(o.def))
		} else {
			outln(o.def)
		}
		return 0
	case o.onBad == onBadError:
		// The message already went to stderr above; error mode differs only in
		// printing nothing on stdout.
		return statusCode(status)
	default:
		// print the zero/empty value anyway; the exit code carries the status
		emit(lines)
		return statusCode(status)
	}
}

// quoted is the source text, quoted for a message: one line whatever it holds,
// with the same escapes in every binding.
func quoted(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, c := range s {
		switch {
		case c == '"':
			b.WriteString("\\\"")
		case c == '\\':
			b.WriteString("\\\\")
		case c == '\n':
			b.WriteString("\\n")
		case c == '\r':
			b.WriteString("\\r")
		case c == '\t':
			b.WriteString("\\t")
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, "\\u{%x}", c)
		default:
			b.WriteRune(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func doFmt(o *opts) int {
	if len(o.args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: shcl fmt [--write|-w] [options] FILE (see --help)")
		return 1
	}
	file := o.args[0]
	if o.write && file == "-" {
		fmt.Fprintln(os.Stderr, "fmt --write cannot rewrite stdin; drop --write to print, or pass a FILE")
		return 1
	}
	if o.write && !writeTargetOK(file) {
		return exitIO
	}
	doc, read, code := loadLayeredFrom(o, file, nil, false)
	if doc == nil {
		return code
	}
	// --check is migrate --check's sibling, and the spelling every other
	// formatter has: print nothing, and say by the exit code whether a rewrite
	// would change the file. It was `shcl fmt f | cmp -s - f` before.
	if o.check {
		// The save gate --write goes through is asked first, so 6 never
		// promises a rewrite the same command would refuse to make.
		if !o.lossy && doc.LostCount() != 0 {
			fmt.Fprintf(os.Stderr, "%s: fmt --write would refuse: the load dropped %d line(s)/value(s) "+
				"it would delete (--lossy overrides)\n", file, doc.LostCount())
			return 7
		}
		if doc.ToCanonical() == read {
			return 0
		}
		fmt.Fprintf(os.Stderr, "%s: not canonical; fmt --write would rewrite it\n", file)
		return 6
	}
	if o.write {
		return writeBack(doc, file, o, &read, false)
	}
	outs(doc.ToCanonical())
	return 0
}

// rewrittenLines numbers the lines migrate spells differently, counted from
// 1. The rewrite goes line for line and only appends, so line N of the input
// is line N of the output.
func rewrittenLines(before, after string) []int {
	if before == "" {
		return nil
	}
	b := strings.Split(strings.TrimSuffix(before, "\n"), "\n")
	a := strings.Split(after, "\n")
	var lines []int
	for i := 0; i < len(b) && i < len(a); i++ {
		if b[i] != a[i] {
			lines = append(lines, i+1)
		}
	}
	return lines
}

// oldCopyName is where `migrate --write` keeps the file it replaces:
// `_old_v2` before the last dot of the file name, or on the end when it has
// none. A leading dot is part of the name, not an extension.
func oldCopyName(file string) string {
	start := nameStart(file)
	if dot := strings.LastIndex(file[start:], "."); dot > 0 {
		at := start + dot
		return file[:at] + "_old_v2" + file[at:]
	}
	return file + "_old_v2"
}

// nameStart says where the file name starts in a path: after the last
// separator, or on windows after a drive with no separator (C:cfg.shcl). A
// backslash is a separator only on windows.
func nameStart(file string) int {
	start := strings.LastIndex(file, "/") + 1
	if runtime.GOOS != "windows" {
		return start
	}
	if bs := strings.LastIndex(file, "\\") + 1; bs > start {
		start = bs
	}
	if start == 0 && len(file) >= 2 && file[1] == ':' && (file[0]|0x20) >= 'a' && (file[0]|0x20) <= 'z' {
		start = 2
	}
	return start
}

// createCopy is the exclusive create of the old copy, born private. The
// windows build swaps in one that gives the copy the original's DACL
// (main_windows.go).
var createCopy = func(_, old string) (*os.File, error) {
	return os.OpenFile(old, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
}

// keepOriginal writes the original bytes to the old-copy name before the
// migrated text replaces them. The create is exclusive, so an earlier copy is
// never replaced, and the copy is synced before the save starts.
func keepOriginal(file, text string) (string, error) {
	old := oldCopyName(file)
	// FILE: and the system's own message, as the UI guide has it. The path
	// error would name the call and the path a second time.
	bare := func(err error) error {
		var pe *fs.PathError
		if errors.As(err, &pe) {
			return pe.Err
		}
		return err
	}
	f, err := createCopy(file, old)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return "", fmt.Errorf("%s: already exists; migrate keeps the original file there, so nothing was written", old)
		}
		return "", fmt.Errorf("%s: %w", old, bare(err))
	}
	_, err = f.WriteString(text)
	// Born private, then given the original's group and bits, so a 600 config
	// never has a readable copy, and one in a setgid directory does not go to
	// the directory's group. The group first, since a chown clears
	// setuid/setgid. Best effort, the way the save carries both.
	if fi, serr := os.Stat(file); err == nil && serr == nil && runtime.GOOS != "windows" {
		if gid, ok := statGID(fi); ok {
			_ = f.Chown(-1, gid)
		}
		_ = f.Chmod(fi.Mode())
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(old)
		return "", fmt.Errorf("%s: %w", old, bare(err))
	}
	return old, nil
}

// statGID reads the group off a stat result, the way the library does it.
// syscall.Stat_t does not exist on windows, and this file compiles there too.
func statGID(fi os.FileInfo) (int, bool) {
	v := reflect.ValueOf(fi.Sys())
	if v.Kind() == reflect.Ptr {
		if v.IsNil() {
			return 0, false
		}
		v = v.Elem()
	}
	if v.Kind() != reflect.Struct {
		return 0, false
	}
	g := v.FieldByName("Gid")
	if !g.IsValid() || !g.CanUint() {
		return 0, false
	}
	return int(g.Uint()), true
}

// doMigrate: a 2.x file rewritten for the current rules. The rewrite is text
// to text; the load after it is for the diagnostics and the save gate, the
// same gate `fmt --write` goes through.
func doMigrate(o *opts) int {
	if len(o.args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: shcl migrate [options] FILE (see --help)")
		return 1
	}
	file := o.args[0]
	if o.write && file == "-" {
		fmt.Fprintln(os.Stderr, "migrate --write cannot rewrite stdin; drop --write to print, or pass a FILE")
		return 1
	}
	if o.write && !writeTargetOK(file) {
		return exitIO
	}
	text, err := readInput(file)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitIO
	}
	m := shcl.Migrate(text, o.from2x)
	doc, code := loadDocFrom("", m.Text, o.strictness, false)
	if doc == nil {
		return code
	}
	sayDiagnosticsFrom("", doc.Diagnostics())
	// The file says it was written for these rules, so there is nothing to do
	// and nothing to write. Saying so beats printing the input back silently.
	if m.Current {
		fmt.Fprintf(os.Stderr, "%s: nothing to migrate: the file already names its format\n", file)
		if !o.write && !o.check {
			outs(m.Text)
		}
		return 0
	}
	rc := 0
	if m.Ambiguous != 0 {
		fmt.Fprintf(os.Stderr, "%s: %d value(s) read one way under 2.x and another under these rules, and "+
			"the file does not say which it was written for; left as written (--from-2x rewrites them)\n", file, m.Ambiguous)
		rc = 7
	}
	if m.Lost != 0 {
		fmt.Fprintf(os.Stderr, "%s: %d line(s) bound a value under 2.x that nothing binds now: bracket text "+
			"after the colon, which has no spelling here (--lossy overrides)\n", file, m.Lost)
		if !o.lossy {
			rc = 7
		}
	}
	rewritten := rewrittenLines(text, m.Text)
	// A save keeps a line at an indent no level matches, but 2.x placed some
	// such lines by a looser rule and read them, so a migration that leaves
	// one has not carried the file across. With nothing lost, every one of
	// them is kept.
	misplaced := 0
	for _, d := range doc.Diagnostics() {
		if d.Code == "E012" || d.Code == "E018" {
			misplaced++
		}
	}
	if o.check {
		for _, n := range rewritten {
			fmt.Fprintf(os.Stderr, "%s:%d: migrate would rewrite this line\n", file, n)
		}
		// Same as fmt --check: the save gate --write goes through is asked
		// before 6, so 6 never promises a rewrite that would be refused.
		if rc == 0 && !o.lossy && doc.LostCount() != 0 {
			fmt.Fprintf(os.Stderr, "%s: migrate --write would refuse: the migrated text drops %d line(s)/value(s) "+
				"on load (--lossy overrides)\n", file, doc.LostCount())
			rc = 7
		} else if rc == 0 && !o.lossy && misplaced != 0 {
			fmt.Fprintf(os.Stderr, "%s: migrate --write would refuse: the migrated text leaves %d line(s) unread "+
				"at an indent no open level matches (--lossy overrides)\n", file, misplaced)
			rc = 7
		}
		if rc == 0 && len(rewritten) != 0 {
			rc = 6
		}
		return rc
	}
	if o.write {
		if rc != 0 {
			fmt.Fprintf(os.Stderr, "%s: refusing to rewrite; nothing changed\n", file)
			return rc
		}
		if doc.LostCount() != 0 && !o.lossy {
			fmt.Fprintf(os.Stderr, "%s: refusing to rewrite: the migrated text drops %d line(s)/value(s) "+
				"on load (--lossy overrides)\n", file, doc.LostCount())
			return 7
		}
		if misplaced != 0 && !o.lossy {
			fmt.Fprintf(os.Stderr, "%s: refusing to rewrite: the migrated text leaves %d line(s) unread "+
				"at an indent no open level matches (--lossy overrides)\n", file, misplaced)
			return 7
		}
		if !unchangedSinceRead(file, text) {
			return exitIO
		}
		// Only a rewrite leaves a 2.x original to keep. A file that just gains
		// the Format line reads the same either way, and may be a 3.0 file
		// with no stamp.
		old := ""
		if len(rewritten) != 0 {
			var err error
			if old, err = keepOriginal(file, text); err != nil {
				fmt.Fprintln(os.Stderr, err)
				return exitIO
			}
		}
		if err := shcl.WriteFileAtomic(file, m.Text); err != nil {
			fmt.Fprintln(os.Stderr, err)
			// With the original still in place the copy would only stand in
			// the way of the next run. A replace that fails part way on
			// windows can leave nothing at FILE, and then the copy is all
			// there is.
			if old != "" {
				if now, rerr := os.ReadFile(file); rerr == nil && string(now) == text {
					_ = os.Remove(old)
				} else {
					fmt.Fprintf(os.Stderr, "%s: the original is %s\n", file, old)
				}
			}
			return exitIO
		}
		if old != "" {
			fmt.Fprintf(os.Stderr, "%s: migrated, %d line(s) rewritten; the original is %s\n", file, len(rewritten), old)
		} else {
			fmt.Fprintf(os.Stderr, "%s: migrated, %d line(s) rewritten\n", file, len(rewritten))
		}
		return 0
	}
	outs(m.Text)
	return rc
}

// codeLine is `CODE  severity  summary` - the one line both explain forms lead
// with.
func codeLine(head string) string {
	f := strings.SplitN(head, "|", 3)
	for len(f) < 3 {
		f = append(f, "")
	}
	return fmt.Sprintf("%s  %-10s  %s", f[0], f[1], f[2])
}

// codeHeads is the head lines of the code table, in table order.
func codeHeads() []string {
	var heads []string
	for _, l := range strings.Split(codes, "\n") {
		if l != "" && !strings.HasPrefix(l, " ") {
			heads = append(heads, l)
		}
	}
	return heads
}

func doExplain(o *opts) int {
	if len(o.args) == 0 {
		var body strings.Builder
		body.WriteString("Diagnostic codes:\n\n")
		for _, h := range codeHeads() {
			body.WriteString(codeLine(h) + "\n")
		}
		body.WriteString("\n'shcl explain CODE' has the rule behind one of them.\n")
		outf("\n%s\n", body.String())
		return 0
	}
	if len(o.args) > 1 {
		fmt.Fprintln(os.Stderr, "usage: shcl explain [CODE] (see --help)")
		return 1
	}
	code := asciiUpper(o.args[0])
	// The entry runs from its head line to the next one. Built up first, since
	// a code the table does not carry prints nothing at all.
	var body strings.Builder
	found := false
	for _, l := range strings.Split(strings.TrimSuffix(codes, "\n"), "\n") {
		if !strings.HasPrefix(l, " ") {
			if found {
				break
			}
			found = strings.SplitN(l, "|", 2)[0] == code
			if found {
				body.WriteString(codeLine(l) + "\n")
			}
			continue
		}
		if found {
			body.WriteString(l + "\n")
		}
	}
	if !found {
		var names []string
		for _, h := range codeHeads() {
			names = append(names, strings.SplitN(h, "|", 2)[0])
		}
		fmt.Fprintf(os.Stderr, "unknown diagnostic code: %s%s (shcl explain lists them all)\n",
			code, suggest(names, code))
		return 1
	}
	outf("\n%s\n", body.String())
	return 0
}

// doTokens prints every line's spans, one line of output per input line: the
// indent length, then each token as kind=start-end with a mark for how it
// was quoted (', ", or ? for a quote that never closed), offsets counted
// from the first character after the indent. A blank line and a comment
// line say so; every other line is tokenized on its own, raw bodies
// included, since this is the lexical view and not the parse.
func doTokens(o *opts) int {
	if len(o.args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: shcl tokens FILE (see --help)")
		return 1
	}
	text, err := readInput(o.args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitIO
	}
	text = strings.TrimPrefix(text, "\ufeff")
	lines := strings.Split(text, "\n")
	for i := range lines {
		lines[i] = strings.TrimRight(lines[i], "\r")
	}
	if strings.HasSuffix(text, "\n") {
		lines = lines[:len(lines)-1]
	}
	span := func(p *shcl.Piece) string {
		mark := ""
		switch p.Quote {
		case shcl.QuoteSingle:
			mark = "'"
		case shcl.QuoteDouble:
			mark = "\""
		case shcl.QuoteOpen:
			mark = "?"
		}
		return fmt.Sprintf("%d-%d%s", p.Start, p.End, mark)
	}
	var tok shcl.Tokens
	var out strings.Builder
	for i, line := range lines {
		ilen := 0
		for ilen < len(line) && (line[ilen] == ' ' || line[ilen] == '\t') {
			ilen++
		}
		rest := strings.TrimRight(line[ilen:], " \t\r")
		fmt.Fprintf(&out, "%d:%d", i+1, ilen)
		if rest == "" {
			out.WriteString(" blank\n")
			continue
		}
		// The parser takes a leading carriage return off with the indent's blanks.
		body := strings.TrimLeft(rest, " \t\r")
		lead := len(rest) - len(body)
		if strings.HasPrefix(body, "#") {
			out.WriteString(" comment\n")
			continue
		}
		// A stacked element and a fence line are value halves on their own. A
		// `*` is an element when a blank follows it, trailing or not, which only
		// the untrimmed line still shows (20260923 item 12).
		after := ilen + lead + 1
		star := strings.HasPrefix(body, "*") && after < len(line) && (line[after] == ' ' || line[after] == '\t' || line[after] == '\r')
		fence := strings.HasPrefix(body, "```") || strings.HasPrefix(body, "~~~")
		if star || fence {
			from := lead
			if star {
				from = lead + 1
			}
			shcl.TokenizeValue(rest, from, shcl.RulesCurrent, &tok)
			if star {
				out.WriteString(" star")
			} else {
				out.WriteString(" fence")
			}
			fmt.Fprintf(&out, " value=%d-%d", tok.Value[0], tok.Value[1])
			for k := range tok.Elements {
				fmt.Fprintf(&out, " elem=%s", span(&tok.Elements[k]))
			}
			if tok.Comment >= 0 {
				fmt.Fprintf(&out, " comment=%d", tok.Comment)
			}
			out.WriteByte('\n')
			continue
		}
		shcl.Tokenize(rest, ':', false, shcl.RulesCurrent, &tok)
		for k := range tok.Segments {
			seg := &tok.Segments[k]
			kind := "name"
			if seg.Star {
				kind = "star"
			}
			fmt.Fprintf(&out, " %s=%s", kind, span(&seg.Name))
			if seg.Selector != nil {
				fmt.Fprintf(&out, " sel=%s", span(seg.Selector))
			}
		}
		if tok.Sep >= 0 {
			fmt.Fprintf(&out, " sep=%d value=%d-%d", tok.Sep, tok.Value[0], tok.Value[1])
			for k := range tok.Elements {
				fmt.Fprintf(&out, " elem=%s", span(&tok.Elements[k]))
			}
		}
		if tok.Comment >= 0 {
			fmt.Fprintf(&out, " comment=%d", tok.Comment)
		}
		if tok.Fault >= 0 {
			fmt.Fprintf(&out, " fault=%d:%s", tok.Fault, tok.FaultReason)
		}
		out.WriteByte('\n')
	}
	outs(out.String())
	return 0
}

// intGrammar matches the reference's i64 FromStr: optional single sign, then
// one or more ASCII digits, nothing else.
func intGrammar(s string) bool {
	if s != "" && (s[0] == '+' || s[0] == '-') {
		s = s[1:]
	}
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// floatGrammar matches the reference's f64 FromStr: optional sign, then
// inf|infinity|nan (any case) or ASCII-digit decimal with optional fraction
// and exponent. No hex, no underscores, no whitespace.
func floatGrammar(s string) bool {
	if s != "" && (s[0] == '+' || s[0] == '-') {
		s = s[1:]
	}
	if s == "" {
		return false
	}
	low := asciiLower(s)
	if low == "inf" || low == "infinity" || low == "nan" {
		return true
	}
	i := 0
	digits := func() int {
		n := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
			n++
		}
		return n
	}
	if digits() > 0 {
		if i < len(s) && s[i] == '.' {
			i++
			digits()
		}
	} else {
		if s[i] != '.' {
			return false
		}
		i++
		if digits() == 0 {
			return false
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		if digits() == 0 {
			return false
		}
	}
	return i == len(s)
}

// parseOpInt gates an ops int like the reference: grammar first, then range.
func parseOpInt(s string) (int64, error) {
	if !intGrammar(s) {
		return 0, fmt.Errorf("bad int: %s", s)
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("bad int: %s", s)
	}
	return n, nil
}

// parseOpFloat gates an ops float like the reference. The language's own
// float reader takes inf and nan, and overflow ends up on them too; the
// document's reader does not, so they are bad values here, the way a bad
// datetime is.
func parseOpFloat(s string) (float64, error) {
	if !floatGrammar(s) {
		return 0, fmt.Errorf("bad float: %s", s)
	}
	n, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsInf(n, 0) || math.IsNaN(n) {
		return 0, fmt.Errorf("bad float: %s", s)
	}
	return n, nil
}

// unescapeOps decodes an ops value: \n \t \\ only; other `\x` stays verbatim.
func unescapeOps(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 >= len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		switch s[i] {
		case 'n':
			b.WriteByte('\n')
		case 't':
			b.WriteByte('\t')
		case '\\':
			b.WriteByte('\\')
		default:
			b.WriteByte('\\')
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

func applyOp(doc *shcl.Document, line string) error {
	f := strings.Split(line, "\t")
	// Every op but the array forms takes a fixed number of tab-separated
	// fields. Extra ones used to be dropped, so a `raw` whose content held a
	// literal tab lost everything after it and still reported success; the
	// escape for a tab inside a value is `\t`.
	want := 0
	switch f[0] {
	case "empty", "remove", "clear-comments", "banner":
		want = 2
	case "raw", "raw-default":
		want = 4
	case "int", "float", "bool", "string", "datetime", "literal", "comment",
		"int-default", "float-default", "bool-default", "string-default",
		"datetime-default", "literal-default":
		want = 3
	}
	if want != 0 && len(f) > want {
		return fmt.Errorf("%s takes %d tab-separated field(s), got %d", f[0], want, len(f))
	}
	get := func(i int) string {
		if i < len(f) {
			return f[i]
		}
		return ""
	}
	path, v := get(1), get(2)
	var arr []string
	if len(f) > 2 {
		arr = f[2:]
	}
	pint := parseOpInt
	pflt := parseOpFloat
	pbool := func(s string) (bool, error) {
		switch s {
		case "true":
			return true, nil
		case "false":
			return false, nil
		}
		return false, fmt.Errorf("bad bool: %s", s)
	}
	ints := func(xs []string) ([]int64, error) {
		out := make([]int64, len(xs))
		for i, s := range xs {
			n, err := pint(s)
			if err != nil {
				return nil, err
			}
			out[i] = n
		}
		return out, nil
	}
	flts := func(xs []string) ([]float64, error) {
		out := make([]float64, len(xs))
		for i, s := range xs {
			n, err := pflt(s)
			if err != nil {
				return nil, err
			}
			out[i] = n
		}
		return out, nil
	}
	bools := func(xs []string) ([]bool, error) {
		out := make([]bool, len(xs))
		for i, s := range xs {
			b, err := pbool(s)
			if err != nil {
				return nil, err
			}
			out[i] = b
		}
		return out, nil
	}
	strs := func(xs []string) []string {
		out := make([]string, len(xs))
		for i, s := range xs {
			out[i] = unescapeOps(s)
		}
		return out
	}
	dt := func(s string) (shcl.DateTime, error) {
		x, ok := shcl.ParseDateTime(s)
		if !ok {
			return x, fmt.Errorf("bad datetime: %s", s)
		}
		return x, nil
	}
	dts := func(xs []string) ([]shcl.DateTime, error) {
		out := make([]shcl.DateTime, len(xs))
		for i, s := range xs {
			x, err := dt(s)
			if err != nil {
				return nil, err
			}
			out[i] = x
		}
		return out, nil
	}
	wrote := false
	switch f[0] {
	case "int":
		n, err := pint(v)
		if err != nil {
			return err
		}
		wrote = doc.SetInt(path, n)
	case "float":
		n, err := pflt(v)
		if err != nil {
			return err
		}
		wrote = doc.SetFloat(path, n)
	case "bool":
		b, err := pbool(v)
		if err != nil {
			return err
		}
		wrote = doc.SetBool(path, b)
	case "string":
		wrote = doc.SetString(path, unescapeOps(v))
	case "datetime":
		x, err := dt(v)
		if err != nil {
			return err
		}
		wrote = doc.SetDateTime(path, x)
	case "literal":
		wrote = doc.SetLiteral(path, v)
	case "literal-default":
		wrote = doc.SetLiteralDefault(path, v)
	case "int-default":
		n, err := pint(v)
		if err != nil {
			return err
		}
		wrote = doc.SetIntDefault(path, n)
	case "float-default":
		n, err := pflt(v)
		if err != nil {
			return err
		}
		wrote = doc.SetFloatDefault(path, n)
	case "bool-default":
		b, err := pbool(v)
		if err != nil {
			return err
		}
		wrote = doc.SetBoolDefault(path, b)
	case "string-default":
		wrote = doc.SetStringDefault(path, unescapeOps(v))
	case "datetime-default":
		x, err := dt(v)
		if err != nil {
			return err
		}
		wrote = doc.SetDateTimeDefault(path, x)
	case "int-array":
		xs, err := ints(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetIntArray(path, xs)
	case "float-array":
		xs, err := flts(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetFloatArray(path, xs)
	case "bool-array":
		xs, err := bools(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetBoolArray(path, xs)
	case "string-array":
		wrote = doc.SetStringArray(path, strs(arr))
	case "datetime-array":
		xs, err := dts(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetDateTimeArray(path, xs)
	case "int-array-default":
		xs, err := ints(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetIntArrayDefault(path, xs)
	case "float-array-default":
		xs, err := flts(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetFloatArrayDefault(path, xs)
	case "bool-array-default":
		xs, err := bools(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetBoolArrayDefault(path, xs)
	case "string-array-default":
		wrote = doc.SetStringArrayDefault(path, strs(arr))
	case "datetime-array-default":
		xs, err := dts(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetDateTimeArrayDefault(path, xs)
	case "raw":
		wrote = doc.SetRaw(path, unescapeOps(get(3)), v)
	case "raw-default":
		wrote = doc.SetRawDefault(path, unescapeOps(get(3)), v)
	case "empty":
		wrote = doc.SetEmpty(path)
	case "comment":
		wrote = doc.SetComment(path, unescapeOps(v))
	case "remove", "clear-comments":
		if unusablePath(doc, path) {
			return fmt.Errorf("cannot %s %s: not a usable path", f[0], path)
		}
		if f[0] == "remove" {
			doc.Remove(path)
		} else {
			doc.ClearComments(path)
		}
		wrote = true
	case "banner":
		// The second field is on or off, not a path.
		if path != "on" && path != "off" {
			return fmt.Errorf("bad banner: %s (on or off)", path)
		}
		doc.SetBanner(path == "on")
		wrote = true
	default:
		return fmt.Errorf("unknown op: %s", f[0])
	}
	if !wrote {
		// Which half of the op had no spelling: the reader is otherwise sent
		// to the value when it was the info string or the comment that failed.
		unwritable := "the value has no spelling that reads back"
		switch f[0] {
		case "literal", "literal-default":
			unwritable = "the value text is not one value"
		case "comment":
			unwritable = "the comment text is not one line"
		case "raw", "raw-default":
			unwritable = rawRefusal(unescapeOps(get(3)))
		}
		return fmt.Errorf("cannot write %s: %s", path, describeRefusal(doc, path, unwritable))
	}
	return nil
}

// rawRefusal: Which half of a `raw` op had no spelling, and why. The half is asked of the
// library rather than worked out here: an empty info string always reads back,
// so a write that still fails with one is the body's fault. Re-deriving the
// rule in the CLI is how the two copies drift.
func rawRefusal(content string) string {
	probe := shcl.New()
	if !probe.SetRaw("p", content, "") {
		return "the block body has no spelling that reads back: a line ending in a carriage return is trimmed on the way back in, and a line spelling the closing fence would end the block early"
	}
	return "the info string has no spelling that reads back: a '#' in it opens a comment, and a line break has no inline spelling"
}

func doSet(o *opts) int {
	if len(o.args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: shcl set [--write|-w] [options] FILE (see --help)")
		return 1
	}
	file := o.args[0]
	if o.write && file == "-" {
		fmt.Fprintln(os.Stderr, "set --write cannot rewrite stdin; drop --write to print, or pass a FILE")
		return 1
	}
	if o.write && !writeTargetOK(file) {
		return exitIO
	}
	// Base doc: with the edits given as options no ops script is read, so a '-'
	// file is the document on stdin the way it is everywhere else; only when
	// stdin is the ops script does '-' mean an empty base. Reading neither threw
	// a piped document away at exit 0.
	// --write names the file this command produces, so a FILE that is not there
	// yet is a create and the edits go into a new document. Only under --write,
	// and only when nothing is at the path at all: without --write there is
	// nothing to create, and a file that exists but cannot be read is still an
	// error rather than something to quietly write over.
	// A created file starts out as the info block, so a new config says what
	// format it is. Comments in an otherwise empty document are the document's
	// trailing trivia, so the edits go above it and the write still goes
	// through the library's save gate.
	// The --layer files sit under it and --set overrides sit on top, before
	// ops, through the same fold every other subcommand uses.
	creating := false
	if o.write && file != "-" {
		if _, serr := os.Stat(file); serr != nil {
			creating = true
		}
	}
	var given *string
	if creating {
		banner := ""
		if !o.noBanner {
			banner = shcl.GenBanner
		}
		given = &banner
	} else if file == "-" && len(o.sets) == 0 {
		empty := ""
		given = &empty
	}
	// Lines the edits leave alone are written back as they were, so a
	// hand-kept file stays the way it was kept. A created file has none.
	doc, read, code := loadLayeredFrom(o, file, given, !creating)
	if doc == nil {
		return code
	}
	// --set carries the edits, so stdin is left alone: reading it here would
	// block on the console for anyone who passed edits as options.
	var ops []byte
	if len(o.sets) == 0 {
		var err error
		// Say so before blocking. With nothing on stdin this used to sit there
		// silently, which reads as a hang rather than as a prompt; the note is
		// unconditional so a pipeline and a terminal behave identically. The
		// program-name prefix marks it as a notice; errors carry none.
		fmt.Fprintln(os.Stderr, "shcl: reading write-ops from stdin (one op per line, tab-separated; end with EOF)")
		ops, err = io.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintf(os.Stderr, "stdin: %s\n", err)
			return exitIO
		}
		// The reference reads ops via read_to_string; mirror its UTF-8 failure,
		// which is a stream that could not be read, not a usage error.
		if !utf8.Valid(ops) {
			fmt.Fprintln(os.Stderr, "stdin: invalid UTF-8")
			return exitIO
		}
	}
	// Byte order marks off the front: Windows PowerShell 5.1 puts one or more
	// before text it pipes to a program (20260924 item 7), and the first op
	// then read as unknown. No op starts with one.
	for n, line := range strings.Split(strings.TrimLeft(string(ops), "\ufeff"), "\n") {
		line = strings.TrimSuffix(line, "\r") // match Rust lines() CRLF handling
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if aerr := applyOp(doc, line); aerr != nil {
			fmt.Fprintf(os.Stderr, "op line %d: %s\n", n+1, aerr)
			return 1
		}
	}
	if o.write {
		// "Create" was decided before the wait on stdin, so a file that turned
		// up meanwhile is refused rather than replaced.
		if _, serr := os.Stat(file); creating && serr == nil {
			fmt.Fprintf(os.Stderr, "%s: file exists (it appeared while the edits were read)\n", file)
			return exitIO
		}
		// The banner seeded an empty document, so the blank line above it was
		// the document's first and the parse drops those on purpose. Put it
		// back now that the edits sit above it, so a created file reads the
		// way init's output does.
		if creating && !o.noBanner {
			text := doc.ToCanonical()
			if head, ok := strings.CutSuffix(text, shcl.GenBanner); ok && head != "" && !strings.HasSuffix(head, "\n\n") {
				doc = shcl.Parse(head + "\n" + shcl.GenBanner)
			}
		}
		// A file that was there is read again first, for the same wait.
		if creating {
			return writeBack(doc, file, o, nil, false)
		}
		return writeBack(doc, file, o, &read, true)
	}
	text, _ := doc.ToTextKeepLines()
	outs(text)
	return 0
}

// schemaFor is the schema check validates against: --schema, else the one the
// file names on its Schema line. A relative path there is read from the
// config file's directory, the way an editor reads it. A URL is left to
// editors, since a check that reads the network because of a line in a file
// is not one to run unattended.
func schemaFor(o *opts, file, text string) (string, bool, error) {
	if o.schemaSet {
		return o.schema, true, nil
	}
	named, ok := shcl.SchemaRef(text)
	if !ok {
		return "", false, nil
	}
	if strings.Contains(named, "://") {
		fmt.Fprintf(os.Stderr, "the file names its schema by URL (%s), which check does not fetch; pass --schema=SCHEMA to validate against it\n", named)
		return "", false, nil
	}
	// Two separators, or the NT prefix, name a share or a device on windows,
	// and a line in a file someone else wrote must not reach another host.
	isSep := func(c byte) bool { return c == '/' || c == '\\' }
	if runtime.GOOS == "windows" && len(named) >= 2 && ((isSep(named[0]) && isSep(named[1])) || strings.HasPrefix(named, `\??\`)) {
		return "", false, fmt.Errorf("%s: a Schema line cannot name a network or device path", named)
	}
	absolute := named[0] == '/' || (runtime.GOOS == "windows" && (named[0] == '\\' ||
		(len(named) >= 2 && named[1] == ':' && (named[0]|0x20) >= 'a' && (named[0]|0x20) <= 'z')))
	if absolute {
		return named, true, nil
	}
	start := 0
	if file != "-" {
		start = nameStart(file)
	}
	if start == 0 {
		return "./" + named, true, nil
	}
	return file[:start] + named, true, nil
}

// readNamedSchema reads the schema a Schema line names. A line in a file
// someone else wrote must not make an unattended check wait on a FIFO or read
// a device until memory runs out, so only a regular file is read.
func readNamedSchema(path string) (string, error) {
	if notADiskFile(path) {
		return "", fmt.Errorf("%s: not a regular file", path)
	}
	regular := func(fi fs.FileInfo, err error) error {
		var pe *fs.PathError
		switch {
		case errors.As(err, &pe):
			return fmt.Errorf("%s: %w", path, pe.Err)
		case err != nil:
			return fmt.Errorf("%s: %w", path, err)
		case fi.IsDir():
			return fmt.Errorf("%s: Is a directory", path)
		case !fi.Mode().IsRegular():
			return fmt.Errorf("%s: not a regular file", path)
		}
		return nil
	}
	// Asked before the open too, since opening a FIFO waits for a writer.
	if err := regular(os.Stat(path)); err != nil {
		return "", err
	}
	f, err := os.Open(path)
	if err != nil {
		return "", regular(nil, err)
	}
	defer f.Close()
	if err := regular(f.Stat()); err != nil {
		return "", err
	}
	b, err := io.ReadAll(f)
	if err != nil {
		return "", regular(nil, err)
	}
	if !utf8.Valid(b) {
		return "", fmt.Errorf("%s: stream did not contain valid UTF-8", path)
	}
	return string(b), nil
}

func doCheck(o *opts) int {
	if len(o.args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: shcl check [options] FILE (see --help)")
		return 1
	}
	text, err := readInput(o.args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitIO
	}
	// A strict load fails and still hands back the document it recovered, which
	// is what the library's one-shot Validate walks. So the schema half runs
	// either way: at strict a user was getting less out of check than at
	// standard on the same file, and check writes nothing, so fmt's refusal to
	// rewrite a strict-failing document does not carry over.
	doc, perr := shcl.ParseWith(text, o.strictness)
	strictFailed := perr != nil
	diags := doc.Diagnostics()
	// --schema: append validation diagnostics under the same contract. The
	// schema itself always loads at Standard (a program artifact); one that
	// does not load cleanly is a single V099 schema fault.
	schemaFile, ok, err := schemaFor(o, o.args[0], text)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitIO
	}
	if ok {
		read := readNamedSchema
		if o.schemaSet {
			read = readInput
		}
		stext, serr := read(schemaFile)
		if serr != nil {
			fmt.Fprintln(os.Stderr, serr)
			return exitIO
		}
		sdoc := shcl.Parse(stext)
		bad := false
		for _, sd := range sdoc.Diagnostics() {
			if sd.Severity == shcl.SeverityError {
				bad = true
			}
		}
		if bad {
			for _, sd := range sdoc.Diagnostics() {
				fmt.Fprintf(os.Stderr, "schema line %d: %s: %s %s\n", sd.Line, sd.Severity, sd.Code, sd.Message)
			}
			diags = append(diags, shcl.Diagnostic{
				Line: 0, Severity: shcl.SeverityError, Message: "schema failed to load", Code: "V099",
			})
		} else {
			// The schema's own load has something to say too: an H001 on a
			// repeated `allowed` is what explains the V092 below it. On
			// stderr with the schema's own line numbers, the way a V099's
			// are - stdout is the code contract.
			for _, sd := range sdoc.Diagnostics() {
				fmt.Fprintf(os.Stderr, "schema line %d: %s: %s %s\n", sd.Line, sd.Severity, sd.Code, sd.Message)
			}
			diags = append(diags, doc.Validate(sdoc)...)
			diags = shcl.SuppressDeclaredRepeats(sdoc, diags)
			diags = shcl.SuppressDeclaredReopens(sdoc, diags)
		}
	}
	// stdout carries the stable codes - the cross-binding contract. The prose is
	// per-binding voice and goes to stderr (which the differential check drops).
	// A V090-V093 line number is a SCHEMA line (the code table says so); the
	// prose names the file so the two number spaces cannot be confused.
	errorCount := 0
	for _, d := range diags {
		outf("line %d: %s: %s\n", d.Line, d.Severity, d.Code)
		if d.Severity == shcl.SeverityError {
			errorCount++
		}
	}
	sayDiagnostics(diags)
	// The codes are the portable half of a diagnostic and nothing else on
	// screen says where to look one up.
	if len(diags) > 0 {
		fmt.Fprintln(os.Stderr, "(run 'shcl explain CODE' for the rule behind a code)")
	}
	switch {
	case strictFailed:
		outf("strict load failed: %d diagnostic(s)\n", len(diags))
		return 6
	case errorCount > 0:
		// Loaded, but lines were dropped: nonzero so a CI gate on check catches it.
		outf("failed: %d diagnostic(s), %d error(s)\n", len(diags), errorCount)
		return 6
	default:
		outf("ok (%d diagnostic(s))\n", len(diags))
		return 0
	}
}

func doInit(o *opts) int {
	if len(o.args) != 0 {
		fmt.Fprintln(os.Stderr, "init takes no file argument (see --help)")
		return 1
	}
	if !o.schemaSet {
		fmt.Fprintln(os.Stderr, "init needs --schema=FILE (see --help)")
		return 1
	}
	stext, err := readInput(o.schema)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return exitIO
	}
	// The schema always loads at Standard - a program artifact, not user data.
	sdoc := shcl.Parse(stext)
	bad := false
	for _, d := range sdoc.Diagnostics() {
		if d.Severity == shcl.SeverityError {
			bad = true
		}
	}
	if bad {
		for _, d := range sdoc.Diagnostics() {
			fmt.Fprintf(os.Stderr, "schema line %d: %s: %s %s\n", d.Line, d.Severity, d.Code, d.Message)
		}
		fmt.Fprintln(os.Stderr, "init: schema failed to load")
		// A broken schema is a config-semantics failure, not a usage error:
		// same exit as `check --schema` reporting it.
		return 6
	}
	text, faults := shcl.Generate(sdoc, o.noBanner)
	if faults != nil {
		sayDiagnostics(faults)
		fmt.Fprintln(os.Stderr, "init: schema has faults")
		return 6
	}
	outs(text)
	return 0
}

// oneLine renders a value for a one-per-line listing. `instances` promises one
// line per instance, and a value holding a line break broke that, so a caller
// splitting on newlines counted more instances than `count` reports. Only such
// a value changes: anything else comes out as it is. The escaped spelling is
// the one genDefaultText writes for the same reason.
func oneLine(v string) string {
	if !strings.ContainsAny(v, "\n\r") {
		return v
	}
	var b strings.Builder
	b.WriteByte('"')
	for _, ch := range v {
		switch ch {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteRune(ch)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func doEnum(o *opts, wantCount bool) int {
	if len(o.args) != 2 {
		name := "instances"
		if wantCount {
			name = "count"
		}
		fmt.Fprintf(os.Stderr, "usage: shcl %s [options] FILE PATH (see --help)\n", name)
		return 1
	}
	file, path := o.args[0], o.args[1]
	doc, code := loadLayered(o, file)
	if doc == nil {
		return code
	}
	if wantCount {
		outln(doc.Count(path))
	} else {
		for _, v := range doc.Instances(path) {
			outln(oneLine(v))
		}
	}
	return 0
}

// doChildren: child field names under a path, one per line, in file order and
// with duplicates kept. PATH may be left out to enumerate the top level. Each
// name comes out in the form a path accepts, so one holding a dot or a quote
// splices back into a path with no further work.
func doChildren(o *opts) int {
	var file, path string
	switch len(o.args) {
	case 1:
		file = o.args[0]
	case 2:
		file, path = o.args[0], o.args[1]
	default:
		fmt.Fprintln(os.Stderr, "usage: shcl children [options] FILE [PATH] (see --help)")
		return 1
	}
	doc, code := loadLayered(o, file)
	if doc == nil {
		return code
	}
	for _, name := range doc.Children(path) {
		outln(shcl.QuoteSegment(name))
	}
	return 0
}

// doPaths: every field path in the document, one per line, in file order and
// deduplicated - the whole-document counterpart of doChildren.
func doPaths(o *opts) int {
	if len(o.args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: shcl paths [options] FILE (see --help)")
		return 1
	}
	doc, code := loadLayered(o, o.args[0])
	if doc == nil {
		return code
	}
	for _, p := range doc.Paths() {
		outln(p)
	}
	return 0
}

var commands = [...]string{"get", "set", "fmt", "check", "init", "count", "instances", "children", "paths", "migrate", "tokens", "explain"}

func run() int {
	argv := os.Args[1:]
	for _, a := range argv {
		if !utf8.ValidString(a) {
			fmt.Fprintln(os.Stderr, "invalid argument encoding (expected UTF-8)")
			return 1
		}
	}
	asked := askedFor(argv)
	// Asking for nothing at all asks for the help, and so does the `help` word,
	// which comes first on the line when it is there.
	if len(argv) == 0 || argv[0] == "help" {
		has := false
		for _, a := range asked {
			has = has || a == "help"
		}
		if !has {
			asked = append([]string{"help"}, asked...)
		}
	}
	// One convention: each output asked for prints once, in the order asked,
	// and the run succeeds. Blank lines go before, between and after, to set
	// the text off from the prompts around it. A lone version line is one line
	// a script reads, so it goes out bare.
	if len(asked) > 0 {
		var blocks []string
		for _, want := range asked {
			switch want {
			case "help":
				topic, code := helpTopic(argv)
				if code != 0 {
					return code
				}
				if topic == "" {
					blocks = append(blocks, help)
				} else {
					blocks = append(blocks, helpFor(topic))
				}
			case "version":
				blocks = append(blocks, versionLine+"\n")
			case "about":
				blocks = append(blocks, about)
			default:
				blocks = append(blocks, donate)
			}
		}
		if len(asked) == 1 && asked[0] == "version" {
			outf("%s\n", versionLine)
		} else {
			outf("\n%s\n", strings.Join(blocks, "\n"))
		}
		return 0
	}
	cmd := argv[0]
	known := false
	for _, c := range commands {
		if c == cmd {
			known = true
			break
		}
	}
	if !known {
		// Before the options are judged, so a typo in the command is reported
		// as that and not as an option the wrong command cannot take.
		if strings.HasPrefix(cmd, "-") && cmd != "--" {
			name := strings.SplitN(cmd, "=", 2)[0]
			if knownOption(name) {
				// It is a real option, just in front of the subcommand. Calling
				// it unknown and then suggesting the same spelling back says
				// nothing about what is actually wrong.
				fmt.Fprintf(os.Stderr, "option %s goes after the subcommand (see --help)\n", name)
			} else {
				fmt.Fprintf(os.Stderr, "unknown option: %s%s (see --help)\n",
					cmd, suggest(optionNames(), name))
			}
		} else {
			fmt.Fprintf(os.Stderr, "unknown command: %s%s (see --help)\n",
				cmd, suggest(commandNames(), cmd))
		}
		return 1
	}
	o, err := parseOpts(argv[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if code := checkOpts(argv[0], o); code != 0 {
		return code
	}
	// A value option in space form takes the next word, so `check --schema FILE`
	// leaves no FILE and the usage line alone never says where it went. Judged
	// after the options, so an option the command does not take is named as
	// that. init and explain want no FILE.
	if cmd != "init" && cmd != "explain" && len(o.args) == 0 && o.swallowedOpt != "" {
		fmt.Fprintf(os.Stderr, "option %s took '%s' as its value, so no FILE is left; spell it %s=VALUE\n",
			o.swallowedOpt, o.swallowedValue, o.swallowedOpt)
		return 1
	}
	// Every command spelled out, and the last arm a refusal rather than a
	// fall-through: with a default arm, adding a name to commands without
	// adding one here quietly ran whichever command the default named, with no
	// compile error and no message. run() gates on commands first, so the arm
	// below is only reachable through that mistake.
	switch argv[0] {
	case "get":
		return doGet(o)
	case "set":
		return doSet(o)
	case "fmt":
		return doFmt(o)
	case "check":
		return doCheck(o)
	case "init":
		return doInit(o)
	case "count":
		return doEnum(o, true)
	case "instances":
		return doEnum(o, false)
	case "children":
		return doChildren(o)
	case "paths":
		return doPaths(o)
	case "migrate":
		return doMigrate(o)
	case "tokens":
		return doTokens(o)
	case "explain":
		return doExplain(o)
	default:
		fmt.Fprintf(os.Stderr, "%s: no dispatch arm (see --help)\n", argv[0])
		return 1
	}
}

func main() {
	os.Exit(run())
}
