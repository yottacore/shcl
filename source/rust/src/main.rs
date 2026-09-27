// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! `shcl` CLI - the Tier 1 command binding. POSIX sh and PowerShell wrap this,
//! so the exit codes and flags below are a stable surface, not conveniences.

use shcl::{
	Diagnostic, Document, GEN_BANNER, Piece, Quote, Rules, SaveError, Severity, Status, Strictness,
	Tokens, format_float, generate, migrate, parse_datetime, schema_ref, suppress_declared_reopens,
	suppress_declared_repeats, tokenize, write_file_atomic,
};
use std::fmt::Write as _;
use std::process::ExitCode;

// Every stdout write goes through these. On windows a reader that closed
// early is not a signal but a write error, and the std print macros turn that
// into a panic, which the release build aborts on; a `fmt` piped into `more`
// must not do that. unix never reaches the error branch: main restores the
// SIGPIPE default and the write kills the process the conventional way.
macro_rules! out {
	($($arg:tt)*) => {{
		use std::io::Write;
		if let Err(e) = write!(std::io::stdout(), $($arg)*) {
			write_failed(&e);
		}
	}};
}
macro_rules! outln {
	($($arg:tt)*) => {{
		use std::io::Write;
		if let Err(e) = writeln!(std::io::stdout(), $($arg)*) {
			write_failed(&e);
		}
	}};
}

// Diagnostics and error messages. A stderr that cannot be written has nowhere
// to report that fact, and the document on stdout is still good, so the write
// result is dropped - what the print macros do instead is panic, which the
// release build turns into an abort with nothing delivered.
// stderr has no buffer, so writeln! straight to it made one write call per
// format piece, about eleven per diagnostic. The line is built first and goes
// out in one.
macro_rules! errln {
	($($arg:tt)*) => {{
		use std::io::Write;
		let line = format!("{}\n", format_args!($($arg)*));
		let _ = std::io::stderr().write_all(line.as_bytes());
	}};
}

/// A stdout write that failed. A reader that closed early is nothing to
/// report, since nobody is there to read it, so that leaves quietly the way Go
/// and C do. Anything else lost the output, which is the same failure as a
/// file that could not be written.
fn write_failed(e: &std::io::Error) -> ! {
	if e.kind() == std::io::ErrorKind::BrokenPipe {
		std::process::exit(0);
	}
	errln!("stdout: {}", e);
	std::process::exit(8)
}

const HELP: &str = "\
shcl - Simple Hierarchical Config Language (reference CLI)

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
                                         rules (print it, rewrite FILE in place
                                         with --write or -w, or name the lines
                                         it would change with --check)
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
  --int --float --bool --datetime --string --raw --rawinfo
  --array                                read the value as an array of the type
  --rawinfo reads a raw block's info-string (the fence tag), not its content

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
";

// About and donate are stdout, so they are byte-for-byte contracts across the
// bindings the same way the help text and the init banner are. The version
// interpolates from the crate so it cannot drift from Cargo.toml, and the build
// number is empty unless the pipeline stamped one (build.rs).
const VERSION_LINE: &str = concat!(
	"shcl v",
	env!("CARGO_PKG_VERSION"),
	env!("SHCL_BUILD_SUFFIX")
);

const ABOUT: &str = concat!(
	"shcl v",
	env!("CARGO_PKG_VERSION"),
	env!("SHCL_BUILD_SUFFIX"),
	"
Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ].
Project: https://github.com/yottacore/shcl
Licensed under the MIT License. Full text at:
  https://spdx.org/licenses/MIT.html
No warranty.

Simple Hierarchical Config Language. Forgiving to write, predictable to read.
Types live in your code, not in the file, so nothing is guessed at parse time.
One broken line is skipped with a note instead of taking down the whole file.
"
);

const DONATE: &str = "\
shcl is free software under the MIT License, and stays that way.

If it saves you time and you want to give something back:
  https://github.com/sponsors/jim-collier
  https://ko-fi.com/jimcollier

A star on the project, a clear bug report, or a mention to someone who needs it
are worth just as much.
";

/// The diagnostic code table behind `shcl explain`. One entry per code: a
/// `CODE|severity|summary` head line, then its detail indented two spaces.
/// spec.md's diagnostic tables are the long form; this is the same rules cut
/// to what a terminal shows. Like the help text it is byte-for-byte across the
/// bindings, and crosscheck compares every code.
const CODES: &str = "\
E001|error|field line under a parent holding stacked '*' list elements
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
  Only \\t, \\n, \\\\, \\\", \\', \\uXXXX and \\UXXXXXXXX are escapes there, and a
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
  \"C:\\temp\" reads as C:, a tab, then emp. The line loads and saves as
  usual, since that is legal, but a path almost never means it. Single
  quotes or no quotes keep each backslash as written; so does doubling it.
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
";

fn status_code(st: Status) -> u8 {
	match st {
		Status::Good => 0,
		Status::Empty => 2,
		Status::NotFound => 3,
		Status::BadType => 4,
		Status::Multiple => 5,
	}
}

/// Which spelling produced one edit. They share a single ordered list, so two
/// options touching the same path resolve in the order given.
#[derive(Clone, Copy, PartialEq)]
enum SetKind {
	Data,
	Literal,
	DataDefault,
	LiteralDefault,
	Remove,
}

/// One `--set`/`--set-literal` override. Both spellings share a list so they
/// apply in the order given, which is what decides the winner when two target
/// the same path.
struct Set {
	path: String,
	value: String,
	kind: SetKind,
}

impl Set {
	fn apply(&self, doc: &mut Document) -> bool {
		match self.kind {
			SetKind::Data => doc.set_string(&self.path, &self.value),
			SetKind::Literal => doc.set_literal(&self.path, &self.value),
			SetKind::DataDefault => doc.set_string_default(&self.path, &self.value),
			SetKind::LiteralDefault => doc.set_literal_default(&self.path, &self.value),
			// Removing nothing is not a failure, the same as the ops script's
			// `remove`: the point of the option is the path's absence after.
			SetKind::Remove => {
				doc.remove(&self.path);
				true
			}
		}
	}
	fn opt(&self) -> &'static str {
		match self.kind {
			SetKind::Data => "--set",
			SetKind::Literal => "--set-literal",
			SetKind::DataDefault => "--set-default",
			SetKind::LiteralDefault => "--set-literal-default",
			SetKind::Remove => "--remove",
		}
	}
}

/// The type options, as one list. `Kind::from_opt` is still the reader; this
/// is for the places that need the spellings themselves - the did-you-mean on
/// a typo, and the per-subcommand help.
const TYPE_OPTS: [&str; 7] = [
	"--int",
	"--float",
	"--bool",
	"--datetime",
	"--string",
	"--raw",
	"--rawinfo",
];

#[derive(Clone, Copy, PartialEq)]
enum Kind {
	Int,
	Float,
	Bool,
	Datetime,
	String,
	Raw,
	RawInfo,
}

impl Kind {
	fn from_opt(opt: &str) -> Option<Kind> {
		Some(match opt {
			"--int" => Kind::Int,
			"--float" => Kind::Float,
			"--bool" => Kind::Bool,
			"--datetime" => Kind::Datetime,
			"--string" => Kind::String,
			"--raw" => Kind::Raw,
			"--rawinfo" => Kind::RawInfo,
			_ => return None,
		})
	}
	fn name(self) -> &'static str {
		match self {
			Kind::Int => "int",
			Kind::Float => "float",
			Kind::Bool => "bool",
			Kind::Datetime => "datetime",
			Kind::String => "string",
			Kind::Raw => "raw",
			Kind::RawInfo => "rawinfo",
		}
	}
}

#[derive(Clone, Copy, PartialEq)]
enum OnBad {
	Error,
	Default,
	Flag,
}

impl OnBad {
	fn name(self) -> &'static str {
		match self {
			OnBad::Error => "error",
			OnBad::Default => "default",
			OnBad::Flag => "flag",
		}
	}
}

struct Opts {
	kind: Kind,
	// Which type option was given, if any. `kind` cannot answer that, since it
	// starts at the default type.
	kind_opt: Option<Kind>,
	kind_text: Option<String>, // as it was typed, for the competing-pair message
	// The first competing pair the line held. Two options that ask for different
	// answers are a usage error whichever order they came in, so the pair is
	// recorded here rather than refused on the spot and the "not valid for this
	// subcommand" answer still comes first. `clash_opt` is set when the pair is
	// one option repeated with a different value, in which case a and b are the
	// two values; otherwise a and b are whole option spellings.
	clash_opt: Option<&'static str>,
	clash: Option<(String, String)>,
	array: bool,
	slots: bool,
	default: Option<String>,
	on_bad: OnBad,
	// What an explicit --on-bad asked for, whatever the order. --default sets
	// on_bad too, so without this the two options silently overwrote each other
	// and which one survived depended on which came last.
	on_bad_arg: Option<OnBad>,
	on_bad_text: Option<String>,
	strictness: Strictness,
	strictness_text: Option<String>,
	write: bool,
	lossy: bool,
	from_2x: bool,
	check: bool,
	no_banner: bool,
	schema: Option<String>,
	layers: Vec<String>,     // lower-priority layers, in listed order
	sets: Vec<Set>,          // final override layer, in the order given
	args: Vec<String>,       // positional: FILE [PATH]
	seen: Vec<&'static str>, // canonical names of options given, for per-command validation
	// A value option in space form that took the LAST word on the line. That
	// word is usually the FILE, and the usage line alone never says so.
	swallowed: Option<(String, String)>,
}

/// Did the command line ask for one of the informational outputs? Only tokens
/// in option position count: the value of a value-taking option and anything
/// after `--` are data (a FILE or PATH spelled `-h` needs the `--` anyway,
/// since the option parser would refuse it). Scanning values too once let a
/// read of a missing path answer with the help text and exit 0.
fn asked_for(argv: &[String]) -> Option<&'static str> {
	let mut i = 0;
	while i < argv.len() {
		let a = argv[i].as_str();
		match a {
			"-h" | "--help" => return Some("help"),
			"-v" | "-V" | "--version" => return Some("version"),
			"--about" => return Some("about"),
			"--donate" => return Some("donate"),
			"--" => return None,
			"--default"
			| "--on-bad"
			| "--strictness"
			| "--schema"
			| "--layer"
			| "--set"
			| "--set-literal"
			| "--set-default"
			| "--set-literal-default"
			| "--remove" => i += 1,
			_ => {}
		}
		i += 1;
	}
	None
}

/// PATH=VALUE at the first `=` outside quotes and brackets, so a selector
/// holding one (`x[a=b].c=1`) still addresses its instance. The tokenizer
/// reads the path half with `=` as its separator, so quotes and brackets
/// mean here exactly what they mean in a file; an argument whose path half
/// is not a path at all has no `=` to split at.
/// A path no document can hold, which a remove would take as a miss and
/// exit 0: one the scanner rejects, or one with a value part. A missing path
/// or a wildcard is still fine.
fn unusable_path(doc: &Document, path: &str) -> bool {
	matches!(
		doc.write_reason(path),
		shcl::WriteReason::BadPath | shcl::WriteReason::ValueInPath
	)
}

fn split_set(arg: &str) -> Option<(&str, &str)> {
	let mut tok = Tokens::default();
	tokenize(arg, b'=', true, Rules::Current, &mut tok);
	tok.sep.map(|i| (&arg[..i], &arg[i + 1..]))
}

/// Levenshtein distance capped at `cap`; past it, `cap + 1`. The validator has
/// one of these for schema field names, but it is not public API and the CLI's
/// lists are a dozen short words, so the CLI computes its own.
fn edit_distance(a: &str, b: &str, cap: usize) -> usize {
	let a: Vec<char> = a.chars().collect();
	let b: Vec<char> = b.chars().collect();
	let inf = cap + 1;
	if a.len().abs_diff(b.len()) > cap {
		return inf;
	}
	let mut prev: Vec<usize> = (0..=b.len()).collect();
	let mut cur = vec![0usize; b.len() + 1];
	for i in 1..=a.len() {
		cur[0] = i;
		for j in 1..=b.len() {
			let cost = usize::from(a[i - 1] != b[j - 1]);
			cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
		}
		std::mem::swap(&mut prev, &mut cur);
	}
	prev[b.len()].min(inf)
}

/// "; did you mean 'x'?" for the nearest candidate within two edits, or
/// nothing. Same wording the validator's unknown-field suggestion uses, and
/// prose either way - a typo's exit code is 1 whether or not this has an idea.
fn suggest(cands: &[&str], word: &str) -> String {
	// Every candidate is ASCII, and C counts distance in bytes where the other
	// three count characters, so a word that is not ASCII gets no suggestion
	// rather than one the four bindings could disagree on.
	if !word.is_ascii() {
		return String::new();
	}
	let w = word.to_ascii_lowercase();
	let mut best: Option<(usize, &str)> = None;
	for c in cands {
		let d = edit_distance(&w, &c.to_ascii_lowercase(), 2);
		if d <= 2 && best.is_none_or(|(bd, _)| d < bd) {
			best = Some((d, c));
		}
	}
	match best {
		Some((_, c)) => format!("; did you mean '{}'?", c),
		None => String::new(),
	}
}

/// Every command word, for the same. The informational four are commands to a
/// user typing one, whatever the dispatch calls them.
fn command_names() -> Vec<&'static str> {
	let mut v: Vec<&'static str> = COMMANDS.to_vec();
	v.extend(["help", "version", "about", "donate"]);
	v
}

/// Every option spelling some subcommand takes. Built from the table
/// `check_opts` judges against, so a new option becomes suggestable the moment
/// it is accepted somewhere.
fn option_names() -> Vec<&'static str> {
	// The informational flags are in no subcommand's table but are options to
	// anyone typing one.
	let mut v: Vec<&'static str> = vec!["--help", "--version", "--about", "--donate"];
	for cmd in COMMANDS {
		for o in allowed_opts(cmd) {
			if *o == "--<type>" {
				for t in TYPE_OPTS {
					if !v.contains(&t) {
						v.push(t);
					}
				}
			} else if !v.contains(o) {
				v.push(o);
			}
		}
	}
	v
}

/// A real option by any spelling, `-w` included. The suggestions draw on
/// `option_names` alone, which leaves the short form out.
fn known_option(name: &str) -> bool {
	name == "-w" || option_names().contains(&name)
}

fn parse_opts(argv: &[String]) -> Result<Opts, String> {
	let mut o = Opts {
		kind: Kind::String,
		kind_opt: None,
		kind_text: None,
		clash_opt: None,
		clash: None,
		array: false,
		slots: false,
		default: None,
		on_bad: OnBad::Flag,
		on_bad_arg: None,
		on_bad_text: None,
		strictness: Strictness::Standard,
		strictness_text: None,
		write: false,
		lossy: false,
		from_2x: false,
		check: false,
		no_banner: false,
		schema: None,
		layers: Vec::new(),
		sets: Vec::new(),
		args: Vec::new(),
		seen: Vec::new(),
		swallowed: None,
	};
	// Value-taking options accept both --opt=VALUE and the space form --opt VALUE.
	let mut i = 0;
	while i < argv.len() {
		let a = argv[i].as_str();
		// Everything after `--` is positional, so a file or path may begin
		// with a dash.
		if a == "--" {
			o.args.extend(argv[i + 1..].iter().cloned());
			return Ok(o);
		}
		if let Some(k) = Kind::from_opt(a) {
			if let (Some(prev), Some(prev_text)) = (o.kind_opt, o.kind_text.take())
				&& prev != k
			{
				note_clash(&mut o, None, &prev_text, a);
			}
			o.kind = k;
			o.kind_opt = Some(k);
			o.kind_text = Some(a.to_string());
			o.seen.push("--<type>");
			i += 1;
			continue;
		}
		match a {
			"--array" => {
				o.array = true;
				o.seen.push("--array");
			}
			"--slots" => {
				o.slots = true;
				o.seen.push("--slots");
			}
			"--write" | "-w" => {
				o.write = true;
				o.seen.push("--write");
			}
			"--lossy" => {
				o.lossy = true;
				o.seen.push("--lossy");
			}
			"--from-2x" => {
				o.from_2x = true;
				o.seen.push("--from-2x");
			}
			"--check" => {
				o.check = true;
				o.seen.push("--check");
			}
			"--no-banner" => {
				o.no_banner = true;
				o.seen.push("--no-banner");
			}
			"--default"
			| "--on-bad"
			| "--strictness"
			| "--schema"
			| "--layer"
			| "--set"
			| "--set-literal"
			| "--set-default"
			| "--set-literal-default"
			| "--remove" => {
				i += 1;
				let v = argv
					.get(i)
					.ok_or_else(|| format!("missing value for {} (try {}=VALUE)", a, a))?;
				set_value_opt(&mut o, a, v)?;
				if i + 1 == argv.len() {
					o.swallowed = Some((a.to_string(), v.clone()));
				}
			}
			_ if a.starts_with("--default=") => set_value_opt(&mut o, "--default", &a[10..])?,
			_ if a.starts_with("--on-bad=") => set_value_opt(&mut o, "--on-bad", &a[9..])?,
			_ if a.starts_with("--strictness=") => set_value_opt(&mut o, "--strictness", &a[13..])?,
			_ if a.starts_with("--schema=") => set_value_opt(&mut o, "--schema", &a[9..])?,
			_ if a.starts_with("--layer=") => set_value_opt(&mut o, "--layer", &a[8..])?,
			_ if a.starts_with("--set=") => set_value_opt(&mut o, "--set", &a[6..])?,
			_ if a.starts_with("--set-literal-default=") => {
				set_value_opt(&mut o, "--set-literal-default", &a[22..])?
			}
			_ if a.starts_with("--set-literal=") => {
				set_value_opt(&mut o, "--set-literal", &a[14..])?
			}
			_ if a.starts_with("--set-default=") => {
				set_value_opt(&mut o, "--set-default", &a[14..])?
			}
			_ if a.starts_with("--remove=") => set_value_opt(&mut o, "--remove", &a[9..])?,
			_ if a.starts_with('-') && a.len() > 1 => {
				// The suggestion is against the name half: `--stricness=1` is a
				// typo in the option, not in a spelling that includes a value.
				let name = a.split('=').next().unwrap_or(a);
				// Every value option is matched above, so a real name here is a
				// flag given a value. Calling it unknown would suggest it back.
				if known_option(name) {
					return Err(format!("option {} takes no value (see --help)", name));
				}
				return Err(format!(
					"unknown option: {}{} (see --help)",
					a,
					suggest(&option_names(), name)
				));
			}
			_ => o.args.push(argv[i].clone()),
		}
		i += 1;
	}
	Ok(o)
}

/// Record the first competing pair. Only the first is kept: the line is already
/// a usage error, and a second pair would just change which one gets named.
fn note_clash(o: &mut Opts, opt: Option<&'static str>, a: &str, b: &str) {
	if o.clash.is_none() {
		o.clash_opt = opt;
		o.clash = Some((a.to_string(), b.to_string()));
	}
}

fn set_value_opt(o: &mut Opts, name: &str, v: &str) -> Result<(), String> {
	match name {
		"--default" => {
			if let Some(prev) = o.default.take()
				&& prev != v
			{
				note_clash(o, Some("--default"), &prev, v);
			}
			o.default = Some(v.to_string());
			o.on_bad = OnBad::Default;
			o.seen.push("--default");
		}
		"--on-bad" => {
			let mode = match v.to_ascii_lowercase().as_str() {
				"error" => OnBad::Error,
				"default" => OnBad::Default,
				"flag" => OnBad::Flag,
				_ => return Err(format!("bad --on-bad value: {} (see --help)", v)),
			};
			if let Some(prev) = o.on_bad_text.take()
				&& o.on_bad_arg != Some(mode)
			{
				note_clash(o, Some("--on-bad"), &prev, v);
			}
			o.on_bad = mode;
			o.on_bad_arg = Some(mode);
			o.on_bad_text = Some(v.to_string());
			o.seen.push("--on-bad");
		}
		"--strictness" => {
			let level = Strictness::from_arg(v)
				.ok_or_else(|| format!("bad --strictness value: {} (see --help)", v))?;
			if let Some(prev) = o.strictness_text.take()
				&& o.strictness != level
			{
				note_clash(o, Some("--strictness"), &prev, v);
			}
			o.strictness = level;
			o.strictness_text = Some(v.to_string());
			o.seen.push("--strictness");
		}
		"--schema" => {
			if let Some(prev) = o.schema.take()
				&& prev != v
			{
				note_clash(o, Some("--schema"), &prev, v);
			}
			o.schema = Some(v.to_string());
			o.seen.push("--schema");
		}
		"--layer" => {
			o.layers.push(v.to_string());
			o.seen.push("--layer");
		}
		"--remove" => {
			if v.is_empty() {
				return Err("bad --remove value (want PATH) (see --help)".to_string());
			}
			if unusable_path(&Document::new(), v) {
				return Err(format!(
					"bad --remove value (not a usable path): {} (see --help)",
					v
				));
			}
			o.sets.push(Set {
				path: v.to_string(),
				value: String::new(),
				kind: SetKind::Remove,
			});
			o.seen.push("--remove");
		}
		"--set" | "--set-literal" | "--set-default" | "--set-literal-default" => {
			let (p, val) = split_set(v).filter(|(p, _)| !p.is_empty()).ok_or_else(|| {
				format!(
					"bad {} value (want PATH=VALUE, quotes and brackets balanced): {} (see --help)",
					name, v
				)
			})?;
			let (kind, canon) = match name {
				"--set-literal" => (SetKind::Literal, "--set-literal"),
				"--set-default" => (SetKind::DataDefault, "--set-default"),
				"--set-literal-default" => (SetKind::LiteralDefault, "--set-literal-default"),
				_ => (SetKind::Data, "--set"),
			};
			o.sets.push(Set {
				path: p.to_string(),
				value: val.to_string(),
				kind,
			});
			o.seen.push(canon);
		}
		_ => return Err(format!("unknown option: {}", name)),
	}
	Ok(())
}

/// The options each subcommand takes. `check_opts` judges against it, the
/// per-subcommand help is cut from the full help with it, and the shell
/// completions carry the same table (check-completions.bash diffs the two).
fn allowed_opts(cmd: &str) -> &'static [&'static str] {
	let allowed: &[&str] = match cmd {
		"get" => &[
			"--<type>",
			"--array",
			"--slots",
			"--default",
			"--on-bad",
			"--strictness",
			"--layer",
			"--set",
			"--set-literal",
			"--set-default",
			"--set-literal-default",
			"--remove",
		],
		"set" => &[
			"--strictness",
			"--layer",
			"--set",
			"--set-literal",
			"--set-default",
			"--set-literal-default",
			"--remove",
			"--write",
			"--lossy",
			"--no-banner",
		],
		"fmt" => &[
			"--write",
			"--lossy",
			"--check",
			"--strictness",
			"--layer",
			"--set",
			"--set-literal",
			"--set-default",
			"--set-literal-default",
			"--remove",
		],
		"check" => &["--strictness", "--schema"],

		"init" => &["--schema", "--no-banner"],
		"migrate" => &["--write", "--lossy", "--from-2x", "--check"],
		"tokens" | "explain" => &[],
		"count" | "instances" | "children" | "paths" => &[
			"--strictness",
			"--layer",
			"--set",
			"--set-literal",
			"--set-default",
			"--set-literal-default",
			"--remove",
		],
		_ => &[],
	};
	allowed
}

/// One subcommand's slice of the help: its usage entry, the type block when it
/// takes one, and the option entries `allowed_opts` lets it have. Cut from the
/// full help rather than written out a second time, so the two cannot drift
/// and the four bindings stay byte-identical for free. An entry keeps the
/// "(get)" style annotation it carries there, which still reads true.
fn help_for(cmd: &str) -> String {
	let mut out = String::from("Usage:\n");
	let want = format!("  shcl {} ", cmd);
	let mut taking = false;
	for l in HELP.lines() {
		if l.starts_with("  shcl ") {
			taking = l.starts_with(&want);
		} else if taking && !l.starts_with("   ") {
			taking = false;
		}
		if taking {
			out.push_str(l);
			out.push('\n');
		}
	}
	// A paragraph of the full help that opens with the subcommand's own name is
	// that subcommand's - today that is set's write-ops block, which is the
	// half of set a user most needs in front of them.
	let lead = format!("{} ", cmd);
	let mut first = true;
	for l in HELP
		.lines()
		.skip_while(|l| !l.starts_with(&lead))
		.take_while(|l| !l.is_empty())
	{
		if first {
			out.push('\n');
			first = false;
		}
		out.push_str(l);
		out.push('\n');
	}
	let allowed = allowed_opts(cmd);
	if allowed.contains(&"--<type>") {
		out.push('\n');
		for l in HELP
			.lines()
			.skip_while(|l| !l.starts_with("Types ("))
			.take_while(|l| !l.is_empty())
		{
			out.push_str(l);
			out.push('\n');
		}
	}
	// The option entries, in the order the full help lists them. A head line is
	// `  --name`; the deeper-indented lines under it are its text, and the
	// first line at column zero ends the block.
	let mut opts = String::new();
	let mut in_block = false;
	let mut keep = false;
	for l in HELP.lines() {
		if !in_block {
			in_block = l.starts_with("Options (");
			continue;
		}
		if l.starts_with("  --") {
			let name = l[2..].split(['=', ' ']).next().unwrap_or("");
			keep = allowed.contains(&name);
		} else if !l.starts_with("   ") {
			break;
		}
		if keep {
			opts.push_str(l);
			opts.push('\n');
		}
	}
	if opts.is_empty() {
		out.push_str(&format!("\n{} takes no options.\n", cmd));
	} else {
		out.push_str("\nOptions (the subcommands each belongs to are in parentheses):\n");
		out.push_str(&opts);
	}
	out.push_str("\nSee 'shcl help' for the full text, and 'shcl explain CODE' for a code.\n");
	out
}

/// Every option must be meaningful for its subcommand; an option that would be
/// silently ignored (`set --write` before it existed, `--schema` on `get`) is a
/// usage error instead.
fn check_opts(cmd: &str, o: &Opts) -> Result<(), u8> {
	let allowed = allowed_opts(cmd);
	for s in &o.seen {
		if !allowed.contains(s) {
			if *s == "--<type>" {
				errln!("type options are not valid for {} (see --help)", cmd);
			} else if cmd == "init" && *s == "--strictness" {
				// Deliberate, not an oversight: the schema is a program artifact,
				// so it always loads at Standard - the same rule `check --schema`
				// follows for the schema half.
				errln!(
					"option --strictness not valid for init: a schema always loads at standard strictness, being a program artifact rather than user data (see --help)"
				);
			} else if cmd == "check"
				&& matches!(
					*s,
					"--layer"
						| "--set" | "--set-literal"
						| "--set-default" | "--set-literal-default"
						| "--remove"
				) {
				// The one refusal a user is likely to want anyway: check reports
				// line numbers, and a merged document has no single file to
				// number against. Naming the pipeline turns a dead end into a
				// one-liner.
				errln!(
					"option {} not valid for check: diagnostics cite line numbers, which a merged document has none of. Pipe instead: shcl fmt {} ... FILE | shcl check --schema=SCHEMA -",
					s,
					s
				);
			} else {
				errln!("option {} not valid for {} (see --help)", s, cmd);
			}
			return Err(1);
		}
	}
	// Options that ask for different answers used to resolve last-wins with
	// nothing said, so which answer you got depended on typing order. Two type
	// options are one case, one value option given two values the other.
	// Repeating an option with the same value competes with nothing and stays
	// allowed, and so do --layer and --set, which are ordered lists.
	if let Some((a, b)) = &o.clash {
		match o.clash_opt {
			Some(opt) => errln!(
				"{}={} cannot be combined with {}={} (see --help)",
				opt,
				a,
				opt,
				b
			),
			None => errln!("{} cannot be combined with {} (see --help)", a, b),
		}
		return Err(1);
	}
	// Writing back the merged document would fold the lower layers permanently
	// into the top file, which is the opposite of what layering is for. On 'set'
	// the --set values are edits to the document rather than a layer over it, so
	// persisting them is the whole point; everywhere else they stay ephemeral.
	if o.write && !o.layers.is_empty() {
		errln!("--write cannot be combined with --layer (see --help)");
		return Err(1);
	}
	if o.write && !o.sets.is_empty() && cmd != "set" {
		errln!(
			"--write cannot be combined with {} (see --help)",
			o.sets[0].opt()
		);
		return Err(1);
	}
	// --default says "substitute this" and --on-bad=error says "fail instead", so
	// the two together are a contradiction. Each used to overwrite the other's
	// mode, which made the answer depend on the order they were typed in.
	if o.default.is_some()
		&& let Some(mode) = o.on_bad_arg
		&& mode != OnBad::Default
	{
		errln!(
			"--default cannot be combined with --on-bad={} (see --help)",
			mode.name()
		);
		return Err(1);
	}
	// --lossy only overrides the in-place write's refusal, so on its own it says
	// nothing and would read as protection the command never had.
	if o.lossy && !o.write {
		errln!("--lossy is only meaningful with --write (see --help)");
		return Err(1);
	}
	// On set, --no-banner shapes only the file a write creates, so without
	// --write it would be accepted and do nothing.
	if o.no_banner && cmd == "set" && !o.write {
		errln!("--no-banner is only meaningful with --write (see --help)");
		return Err(1);
	}
	if o.check && o.write {
		errln!("--check cannot be combined with --write (see --help)");
		return Err(1);
	}
	// The ops script already has stdin, so a layer cannot read it too.
	if cmd == "set" && o.layers.iter().any(|l| l == "-") {
		errln!(
			"--layer=- is not valid for set: stdin carries the ops script or the document (see --help)"
		);
		return Err(1);
	}
	// Stdin reads once; a second '-' would silently get an empty document.
	let stdin_uses = o.layers.iter().filter(|l| *l == "-").count()
		+ usize::from(o.schema.as_deref() == Some("-"))
		+ usize::from(o.args.first().map(|f| f == "-").unwrap_or(false));
	if stdin_uses > 1 {
		errln!("'-' (stdin) can be named only once across FILE, --layer and --schema");
		return Err(1);
	}
	Ok(())
}

/// Which half of a `raw` op had no spelling, and why. The half is asked of the
/// library rather than worked out here: an empty info string always reads back,
/// so a write that still fails with one is the body's fault. Re-deriving the
/// rule in the CLI is how the two copies drift.
fn raw_refusal(content: &str) -> &'static str {
	let mut probe = Document::new();
	if !probe.set_raw("p", content, "") {
		"the block body has no spelling that reads back: a line ending in a carriage return is trimmed on the way back in, and a line spelling the closing fence would end the block early"
	} else {
		"the info string has no spelling that reads back: a '#' in it opens a comment, and a line break has no inline spelling"
	}
}

/// The per-binding wording behind a setter's bare `false`.
/// Why a write was refused. When the path itself is fine what failed is the
/// text, and only the caller knows which half of the op that was, so it names
/// it: a setter refused for its value used to report the sentence written for
/// `set_literal` whatever the op.
fn describe_refusal(doc: &Document, path: &str, unwritable: &'static str) -> &'static str {
	match doc.write_reason(path) {
		shcl::WriteReason::Writable => unwritable,
		shcl::WriteReason::BadPath => "not a usable path",
		shcl::WriteReason::ValueInPath => "a path with a value part cannot be written",
		shcl::WriteReason::Wildcard => "a wildcard path cannot be written",
		shcl::WriteReason::NoSuchIndex => "no instance at that index",
		shcl::WriteReason::TooDeep => "deeper than the nesting cap",
	}
}

/// The load's diagnostics, one line each, in the shape every command uses.
fn say_diagnostics(diags: &[Diagnostic]) {
	say_diagnostics_from("", diags);
}

/// The same, labeled with the file the diagnostics came from. Under `--layer`
/// several files are loaded and their line numbers share one space on the
/// screen, so two layers with a bad line 2 printed the same thing twice with
/// nothing to tell them apart.
fn say_diagnostics_from(file: &str, diags: &[Diagnostic]) {
	for d in diags {
		// V090-V095 carry a schema line; V096 and V097 are about generation as a
		// whole and carry line 0, so "schema line 0" named a line space they are
		// not in. V099 stands for a schema that did not load and is line 0 too.
		let space = if d.code.starts_with("V09") && !matches!(d.code, "V096" | "V097" | "V099") {
			"schema line"
		} else {
			"line"
		};
		if file.is_empty() {
			errln!(
				"{} {}: {:?}: {} {}",
				space,
				d.line,
				d.severity,
				d.code,
				d.message
			);
		} else {
			errln!(
				"{} {} {}: {:?}: {} {}",
				file,
				space,
				d.line,
				d.severity,
				d.code,
				d.message
			);
		}
	}
}

/// Load `file` with `o`'s lower-priority `--layer` files underneath it and its
/// `--set` overrides on top - the layered-load fold. Every layer parses at the
/// requested strictness; a strict-load failure on any layer aborts like a
/// single-file strict failure (exit 6, nothing printed).
///
/// Prints every layer's diagnostics itself, lowest layer first, before the
/// `--set` overrides run: they belong to the load, and a refused edit used to
/// return before anything was said about them. A merge does not carry
/// diagnostics over, so the merged document only holds the lowest layer's -
/// reading them off it drops the diagnostics for FILE itself, which is the one
/// the caller named.
fn load_layered(o: &Opts, file: &str) -> Result<Document, u8> {
	load_layered_from(o, file, None, false).map(|(doc, _)| doc)
}

/// The same fold with FILE's text given rather than read, which is how `set`
/// creates a file or takes an empty document, and FILE's text handed back.
/// `set` kept its own copy of the fold, and twice a fix to this one missed it.
fn load_layered_from(
	o: &Opts,
	file: &str,
	base: Option<String>,
	keep: bool,
) -> Result<(Document, String), u8> {
	// Lowest -> highest file layer: the --layer files in order, then FILE.
	let mut texts: Vec<String> = Vec::with_capacity(o.layers.len() + 1);
	for lf in &o.layers {
		texts.push(read_input(lf).map_err(|e| {
			errln!("{}", e);
			EXIT_IO
		})?);
	}
	let base_text = match base {
		Some(t) => t,
		None => read_input(file).map_err(|e| {
			errln!("{}", e);
			EXIT_IO
		})?,
	};
	texts.push(base_text);
	// Lowest layer first, each labeled with its own file when there is more
	// than one: the line numbers share a space on the screen otherwise, and two
	// layers with a bad line 2 printed the same thing twice.
	let names: Vec<&str> = o
		.layers
		.iter()
		.map(String::as_str)
		.chain(std::iter::once(file))
		.collect();
	let label = |i: usize| if names.len() > 1 { names[i] } else { "" };
	// Only a document with no layers under it keeps its lines: a merge drops them.
	let mut doc = load_from(label(0), &texts[0], o.strictness, keep && texts.len() == 1)?;
	say_diagnostics_from(label(0), doc.diagnostics());
	for (i, t) in texts[1..].iter().enumerate() {
		let over = load_from(label(i + 1), t, o.strictness, false)?;
		say_diagnostics_from(label(i + 1), over.diagnostics());
		doc.merge(&over);
	}
	for s in &o.sets {
		if !s.apply(&mut doc) {
			errln!(
				"{}: cannot write {}: {}",
				s.opt(),
				s.path,
				describe_refusal(&doc, &s.path, "the value text is not one value")
			);
			return Err(1);
		}
	}
	let base_text = texts.pop().unwrap_or_default();
	Ok((doc, base_text))
}

/// The in-place half of `fmt`/`set`. Overwriting the source is the one place a
/// recovered load turns destructive, so the diagnostics go out even though the
/// command succeeded, and the save runs through the library's own gate rather
/// than a second copy of the rule - the CLI and a consumer program cannot then
/// disagree about which rewrites are safe.
fn write_back(doc: &Document, file: &str, o: &Opts, read: Option<&str>, keep: bool) -> u8 {
	// `read` is the bytes FILE held when the command read it, and None when
	// this write is creating FILE.
	if let Some(before) = read
		&& !unchanged_since_read(file, before)
	{
		return EXIT_IO;
	}
	// Nothing to write: what the save would publish is already on disk. A
	// rewrite would give the file a new inode and mtime for nothing, so an
	// idempotent `--set-default` in a provisioning script reported a change on
	// every run, watchers fired, other hard links broke, and a canonical file
	// in a read-only directory failed. The refusal comes first: a load that
	// dropped content refuses the write whatever the bytes say, unless the
	// lines were kept, which writes the dropped lines back as they were.
	let (text, kept) = if keep {
		doc.to_text_keep_lines()
	} else {
		(doc.to_canonical(), false)
	};
	if let Some(before) = read
		&& (o.lossy || kept || doc.lost_count() == 0)
		&& text == before
	{
		return 0;
	}
	let r = match (o.lossy, keep) {
		(true, true) => write_file_atomic(file, &text).map_err(SaveError::Io),
		(true, false) => doc.save_file_lossy(file),
		(false, true) => doc.save_file_keep_lines(file).map(|_| ()),
		(false, false) => doc.save_file(file),
	};
	match r {
		Ok(()) => {
			// A created file is the one write with nothing to compare against
			// afterwards, and a typo in the name used to end at exit 0 with an
			// empty stderr and a new file nobody asked for.
			if read.is_none() {
				errln!("{}: created", file);
			}
			0
		}
		Err(SaveError::Refused { lost, .. }) => {
			// The rule stays in the library; only the wording is the CLI's,
			// because the override a user has here is a flag, not a function.
			errln!(
				"{}: refusing to rewrite: the load dropped {} line(s)/value(s) this write would delete (--lossy overrides)",
				file,
				lost
			);
			7
		}
		Err(e) => {
			errln!("{}", e);
			EXIT_IO
		}
	}
}

/// FILE still holds the bytes the load read. `set` waits on stdin between the
/// load and the save, and an edit made in that wait was reverted at exit 0.
/// A gap is left between this read and the publish, the width of one save.
fn unchanged_since_read(file: &str, before: &str) -> bool {
	match std::fs::read(file) {
		Ok(now) if now == before.as_bytes() => true,
		_ => {
			errln!("{}: changed since it was read; nothing written", file);
			false
		}
	}
}

/// A file or stream that could not be read or written. Its own code since a
/// script's remedy - fix the path, the permissions, the disk - has nothing to
/// do with the remedy for a usage error, which keeps 1.
const EXIT_IO: u8 = 8;

/// Something is at the path and it is not a disk file: a device name such as
/// CON, NUL or COM1. `std::fs::metadata` cannot see one - a device answers with
/// the same ARCHIVE bit an ordinary file does. The library has the same call
/// for its own save; this is a second copy because it is private there and the
/// CLI has to answer before it reads FILE, not after.
#[cfg(windows)]
fn not_a_disk_file(file: &str) -> bool {
	use std::os::windows::ffi::OsStrExt;
	#[link(name = "kernel32")]
	unsafe extern "system" {
		fn CreateFileW(
			name: *const u16,
			access: u32,
			share: u32,
			sa: *const u8,
			disp: u32,
			flags: u32,
			tmpl: isize,
		) -> isize;
		fn GetFileType(handle: isize) -> u32;
		fn CloseHandle(handle: isize) -> i32;
		fn GetFullPathNameW(name: *const u16, len: u32, buf: *mut u16, part: *mut *mut u16) -> u32;
	}
	const FILE_TYPE_DISK: u32 = 0x1;
	const FILE_READ_ATTRIBUTES: u32 = 0x80;
	const FILE_SHARE_ALL: u32 = 0x7;
	const OPEN_EXISTING: u32 = 3;
	const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
	const MAX_PATH: usize = 260;
	let wide: Vec<u16> = std::ffi::OsStr::new(file)
		.encode_wide()
		.chain(std::iter::once(0))
		.collect();
	unsafe {
		let handle = CreateFileW(
			wide.as_ptr(),
			FILE_READ_ATTRIBUTES,
			FILE_SHARE_ALL,
			std::ptr::null(),
			OPEN_EXISTING,
			FILE_FLAG_BACKUP_SEMANTICS,
			0,
		);
		if handle != -1 {
			let kind = GetFileType(handle);
			CloseHandle(handle);
			return kind != FILE_TYPE_DISK;
		}
		let mut full = [0u16; MAX_PATH];
		let n = GetFullPathNameW(
			wide.as_ptr(),
			MAX_PATH as u32,
			full.as_mut_ptr(),
			std::ptr::null_mut(),
		) as usize;
		n > 0
			&& n < MAX_PATH
			&& full[0] == u16::from(b'\\')
			&& full[1] == u16::from(b'\\')
			&& full[2] == u16::from(b'.')
			&& full[3] == u16::from(b'\\')
	}
}

/// A `--write` FILE is a regular file or nothing yet. Asked before the read,
/// since reading a FIFO takes what was written to it and the save would then
/// refuse it anyway, and since a read of windows CON waits on the console
/// rather than returning. A directory is left to the read, which names it.
fn write_target_ok(file: &str) -> bool {
	#[cfg(windows)]
	if !std::path::Path::new(file).is_dir() && not_a_disk_file(file) {
		errln!("{}: not a regular file", file);
		return false;
	}
	match std::fs::metadata(file) {
		Ok(m) if !m.is_file() && !m.is_dir() => {
			errln!("{}: not a regular file", file);
			false
		}
		_ => true,
	}
}

/// No stream on the other end at all, as opposed to one that failed part way
/// through. POSIX says EBADF; windows has no single answer - a handle a shell
/// closed comes back as an invalid handle or an invalid function depending on
/// how it was closed, and the runtimes map those to their own codes.
fn stdin_unattached(e: &std::io::Error) -> bool {
	match e.raw_os_error() {
		Some(9) => cfg!(unix),
		Some(1) | Some(6) | Some(22) => cfg!(windows),
		_ => false,
	}
}

fn read_input(file: &str) -> Result<String, String> {
	if file == "-" {
		let mut s = String::new();
		use std::io::Read;
		if let Err(e) = std::io::stdin().read_to_string(&mut s) {
			// A stdin that is not attached at all reads as an empty document.
			// POSIX gives EOF for that; windows answers "invalid handle".
			if !stdin_unattached(&e) {
				return Err(format!("stdin: {}", e));
			}
			s.clear();
		}
		Ok(s)
	} else {
		// The message for reading a directory is the platform's, and windows
		// spells it four different ways depending on the binding. Say it here.
		if std::fs::metadata(file).map(|m| m.is_dir()).unwrap_or(false) {
			return Err(format!("{}: Is a directory", file));
		}
		std::fs::read_to_string(file).map_err(|e| format!("{}: {}", file, e))
	}
}

/// A load, labeled with the file the text came from, so a strict failure in
/// one layer of a fold says which layer.
fn load_from(file: &str, text: &str, strictness: Strictness, keep: bool) -> Result<Document, u8> {
	let loaded = if keep {
		Document::parse_keep_lines(text, strictness)
	} else {
		Document::parse_with(text, strictness)
	};
	match loaded {
		Ok(d) => Ok(d),
		Err(e) => {
			say_diagnostics_from(file, &e.diagnostics);
			let errors = e
				.diagnostics
				.iter()
				.filter(|d| d.severity == Severity::Error)
				.count();
			errln!("strict load failed: {} error diagnostic(s)", errors);
			Err(6)
		}
	}
}

/// One value read, formatted for the shell: scalars print as one line, arrays
/// one element per line.
fn do_get(o: &Opts) -> u8 {
	let [file, path] = o.args.as_slice() else {
		errln!("usage: shcl get [type] [options] FILE PATH (see --help)");
		return 1;
	};
	let doc = match load_layered(o, file) {
		Ok(d) => d,
		Err(code) => return code,
	};
	let (lines, status, slots): (Vec<String>, Status, Vec<Status>) = if o.array {
		match o.kind {
			Kind::Int => {
				let r = doc.read_int_array(path);
				(
					r.value.iter().map(|v| v.to_string()).collect(),
					r.status,
					r.slots,
				)
			}
			Kind::Float => {
				let r = doc.read_float_array(path);
				(
					r.value.iter().map(|v| format_float(*v)).collect(),
					r.status,
					r.slots,
				)
			}
			Kind::Bool => {
				let r = doc.read_bool_array(path);
				(
					r.value.iter().map(|v| v.to_string()).collect(),
					r.status,
					r.slots,
				)
			}
			Kind::Datetime => {
				let r = doc.read_datetime_array(path);
				(
					r.value.iter().map(|v| v.to_string()).collect(),
					r.status,
					r.slots,
				)
			}
			Kind::Raw | Kind::RawInfo => {
				errln!("--{} has no --array form (see --help)", o.kind.name());
				return 1;
			}
			Kind::String => {
				let r = doc.read_string_array(path);
				(r.value, r.status, r.slots)
			}
		}
	} else {
		match o.kind {
			Kind::Int => {
				let r = doc.read_int(path);
				(vec![r.value.to_string()], r.status, Vec::new())
			}
			Kind::Float => {
				let r = doc.read_float(path);
				(vec![format_float(r.value)], r.status, Vec::new())
			}
			Kind::Bool => {
				let r = doc.read_bool(path);
				(vec![r.value.to_string()], r.status, Vec::new())
			}
			Kind::Datetime => {
				let r = doc.read_datetime(path);
				(vec![r.value.to_string()], r.status, Vec::new())
			}
			Kind::Raw => {
				let r = doc.read_raw(path);
				(vec![r.value], r.status, Vec::new())
			}
			Kind::RawInfo => {
				let r = doc.read_raw_info(path);
				(vec![r.value], r.status, Vec::new())
			}
			Kind::String => {
				let r = doc.read_string(path);
				(vec![r.value], r.status, Vec::new())
			}
		}
	};
	// Per-line slot status: falls back to the aggregate for scalar reads.
	let slot_at = |i: usize| slots.get(i).copied().unwrap_or(status);
	// An array or a slot listing is one line per element, so a value holding a
	// line break takes its escaped spelling there. A plain scalar read prints
	// the value as it is, since the whole output is that one value.
	let emit = |lines: &[String]| {
		for (i, l) in lines.iter().enumerate() {
			if o.slots {
				outln!("{:?}\t{}", slot_at(i), one_line(l));
			} else if o.array {
				outln!("{}", one_line(l));
			} else {
				outln!("{}", l);
			}
		}
	};
	// Why the read failed is worth saying even when the exit code already
	// carries it: at the default mode the user otherwise gets an empty line, a
	// nonzero code, and nothing to go on. Stdout is untouched - this only ever
	// goes to stderr. Two silences are deliberate: `default` mode, because a
	// caller who supplied a fallback has already said the miss is expected, and
	// Empty outside `error` mode, because an empty value is a legitimate answer
	// here rather than a failure - the same reason `ok()` counts it as fine.
	let say = status != Status::Good
		&& o.on_bad != OnBad::Default
		&& (status != Status::Empty || o.on_bad == OnBad::Error);
	if say {
		let type_name = if o.array {
			format!("{} array", o.kind.name())
		} else {
			o.kind.name().to_string()
		};
		let reason = match status {
			Status::BadType => match doc.read_string(path).raw {
				Some(raw) => format!("value {} is not a valid {}", quoted(&raw), type_name),
				None => format!("value is not a valid {}", type_name),
			},
			Status::NotFound => "no value at that path".to_string(),
			Status::Empty => "the value is empty".to_string(),
			Status::Multiple => "the path matches multiple instances".to_string(),
			Status::Good => String::new(), // handled above; keep the match total
		};
		errln!(
			"cannot read {} as {}: {} (in {})",
			path,
			type_name,
			reason,
			file
		);
	}
	match (status, o.on_bad) {
		(Status::Good, _) | (Status::Empty, OnBad::Flag) => {
			emit(&lines);
			status_code(status)
		}
		(_, OnBad::Default) => {
			if !slots.is_empty() {
				// Array read: the default substitutes per bad slot; alignment holds.
				let dv = o.default.clone().unwrap_or_default();
				let subbed: Vec<String> = lines
					.iter()
					.enumerate()
					.map(|(i, l)| {
						if slot_at(i) == Status::Good {
							l.clone()
						} else {
							dv.clone()
						}
					})
					.collect();
				emit(&subbed);
			} else {
				let dv = o.default.clone().unwrap_or_default();
				if o.slots {
					outln!("{:?}\t{}", status, one_line(&dv));
				} else if o.array {
					outln!("{}", one_line(&dv));
				} else {
					outln!("{}", dv);
				}
			}
			0
		}
		// The message already went to stderr above; error mode differs only in
		// printing nothing on stdout.
		(_, OnBad::Error) => status_code(status),
		(_, OnBad::Flag) => {
			// print the zero/empty value anyway; the exit code carries the status
			emit(&lines);
			status_code(status)
		}
	}
}

/// The source text, quoted for a message: one line whatever it holds, with
/// the same escapes in every binding.
fn quoted(s: &str) -> String {
	let mut out = String::with_capacity(s.len() + 2);
	out.push('"');
	for c in s.chars() {
		match c {
			'"' => out.push_str("\\\""),
			'\\' => out.push_str("\\\\"),
			'\n' => out.push_str("\\n"),
			'\r' => out.push_str("\\r"),
			'\t' => out.push_str("\\t"),
			c if (c as u32) < 0x20 || c == '\x7f' => {
				out.push_str(&format!("\\u{{{:x}}}", c as u32))
			}
			c => out.push(c),
		}
	}
	out.push('"');
	out
}

fn do_fmt(o: &Opts) -> u8 {
	let [file] = o.args.as_slice() else {
		errln!("usage: shcl fmt [--write|-w] [options] FILE (see --help)");
		return 1;
	};
	if o.write && file == "-" {
		errln!("fmt --write cannot rewrite stdin; drop --write to print, or pass a FILE");
		return 1;
	}
	if o.write && !write_target_ok(file) {
		return EXIT_IO;
	}
	let (doc, read) = match load_layered_from(o, file, None, false) {
		Ok(loaded) => loaded,
		Err(code) => return code,
	};
	// `--check` is `migrate --check`'s sibling, and the spelling every other
	// formatter has: print nothing, and say by the exit code whether a rewrite
	// would change the file. It was `shcl fmt f | cmp -s - f` before.
	if o.check {
		// The save gate `--write` goes through is asked first, so 6 never
		// promises a rewrite the same command would refuse to make.
		if !o.lossy && doc.lost_count() != 0 {
			errln!(
				"{}: fmt --write would refuse: the load dropped {} line(s)/value(s) it would delete (--lossy overrides)",
				file,
				doc.lost_count()
			);
			return 7;
		}
		if doc.to_canonical() == read {
			return 0;
		}
		errln!("{}: not canonical; fmt --write would rewrite it", file);
		return 6;
	}
	if o.write {
		return write_back(&doc, file, o, Some(&read), false);
	}
	out!("{}", doc.to_canonical());
	0
}

/// The numbers of the lines migrate spells differently, counted from 1. The
/// rewrite goes line for line and only appends, so line N of the input is line
/// N of the output.
fn rewritten_lines(before: &str, after: &str) -> Vec<usize> {
	if before.is_empty() {
		return Vec::new();
	}
	let before = before.strip_suffix('\n').unwrap_or(before);
	before
		.split('\n')
		.zip(after.split('\n'))
		.enumerate()
		.filter(|(_, (a, b))| a != b)
		.map(|(i, _)| i + 1)
		.collect()
}

/// A 2.x file rewritten for the current rules. The rewrite is text to text;
/// the load after it is for the diagnostics and the save gate, the same gate
/// `fmt --write` goes through.
fn do_migrate(o: &Opts) -> u8 {
	let [file] = o.args.as_slice() else {
		errln!("usage: shcl migrate [options] FILE (see --help)");
		return 1;
	};
	if o.write && file == "-" {
		errln!("migrate --write cannot rewrite stdin; drop --write to print, or pass a FILE");
		return 1;
	}
	if o.write && !write_target_ok(file) {
		return EXIT_IO;
	}
	let text = match read_input(file) {
		Ok(t) => t,
		Err(e) => {
			errln!("{}", e);
			return EXIT_IO;
		}
	};
	let m = migrate(&text, o.from_2x);
	let doc = match load_from("", &m.text, o.strictness, false) {
		Ok(d) => d,
		Err(code) => return code,
	};
	say_diagnostics_from("", doc.diagnostics());
	// The file says it was written for these rules, so there is nothing to do
	// and nothing to write. Saying so beats printing the input back silently.
	if m.current {
		errln!(
			"{}: nothing to migrate: the file already names its format",
			file
		);
		if !o.write && !o.check {
			out!("{}", m.text);
		}
		return 0;
	}
	let mut rc = 0;
	if m.ambiguous != 0 {
		errln!(
			"{}: {} value(s) read one way under 2.x and another under these rules, and the file does not say which it was written for; left as written (--from-2x rewrites them)",
			file,
			m.ambiguous
		);
		rc = 7;
	}
	if m.lost != 0 {
		errln!(
			"{}: {} line(s) bound a value under 2.x that nothing binds now: bracket text after the colon, which has no spelling here (--lossy overrides)",
			file,
			m.lost
		);
		if !o.lossy {
			rc = 7;
		}
	}
	let rewritten = rewritten_lines(&text, &m.text);
	// A save keeps a line at an indent no level matches, but 2.x placed some
	// such lines by a looser rule and read them, so a migration that leaves
	// one has not carried the file across. With nothing lost, every one of
	// them is kept.
	let misplaced = doc
		.diagnostics()
		.iter()
		.filter(|d| d.code == "E012" || d.code == "E018")
		.count();
	if o.check {
		for n in &rewritten {
			errln!("{}:{}: migrate would rewrite this line", file, n);
		}
		// Same as `fmt --check`: the save gate `--write` goes through is asked
		// before 6, so 6 never promises a rewrite that would be refused.
		if rc == 0 && !o.lossy && doc.lost_count() != 0 {
			errln!(
				"{}: migrate --write would refuse: the migrated text drops {} line(s)/value(s) on load (--lossy overrides)",
				file,
				doc.lost_count()
			);
			rc = 7;
		} else if rc == 0 && !o.lossy && misplaced != 0 {
			errln!(
				"{}: migrate --write would refuse: the migrated text leaves {} line(s) unread at an indent no open level matches (--lossy overrides)",
				file,
				misplaced
			);
			rc = 7;
		}
		if rc == 0 && !rewritten.is_empty() {
			rc = 6;
		}
		return rc;
	}
	if o.write {
		if rc != 0 {
			errln!("{}: refusing to rewrite; nothing changed", file);
			return rc;
		}
		if doc.lost_count() != 0 && !o.lossy {
			errln!(
				"{}: refusing to rewrite: the migrated text drops {} line(s)/value(s) on load (--lossy overrides)",
				file,
				doc.lost_count()
			);
			return 7;
		}
		if misplaced != 0 && !o.lossy {
			errln!(
				"{}: refusing to rewrite: the migrated text leaves {} line(s) unread at an indent no open level matches (--lossy overrides)",
				file,
				misplaced
			);
			return 7;
		}
		if !unchanged_since_read(file, &text) {
			return EXIT_IO;
		}
		return match write_file_atomic(file, &m.text) {
			Ok(()) => {
				errln!("{}: migrated, {} line(s) rewritten", file, rewritten.len());
				0
			}
			Err(e) => {
				errln!("{}", e);
				EXIT_IO
			}
		};
	}
	out!("{}", m.text);
	rc
}

/// `CODE  severity  summary` - the one line both explain forms lead with.
fn code_line(head: &str) -> String {
	let mut f = head.split('|');
	let code = f.next().unwrap_or("");
	let sev = f.next().unwrap_or("");
	let summary = f.next().unwrap_or("");
	format!("{}  {:<10}  {}", code, sev, summary)
}

/// The head lines of the code table, in table order.
fn code_heads() -> impl Iterator<Item = &'static str> {
	CODES.lines().filter(|l| !l.starts_with(' '))
}

fn do_explain(o: &Opts) -> u8 {
	let code = match o.args.as_slice() {
		[] => {
			let mut body = String::from("Diagnostic codes:\n\n");
			for h in code_heads() {
				body.push_str(&code_line(h));
				body.push('\n');
			}
			body.push_str("\n'shcl explain CODE' has the rule behind one of them.\n");
			out!("\n{}\n", body);
			return 0;
		}
		[c] => c.to_ascii_uppercase(),
		_ => {
			errln!("usage: shcl explain [CODE] (see --help)");
			return 1;
		}
	};
	// The entry runs from its head line to the next one. Built up first, since
	// a code the table does not carry prints nothing at all.
	let mut body = String::new();
	let mut found = false;
	for l in CODES.lines() {
		if !l.starts_with(' ') {
			if found {
				break;
			}
			found = l.split('|').next() == Some(code.as_str());
			if found {
				body.push_str(&code_line(l));
				body.push('\n');
			}
			continue;
		}
		if found {
			body.push_str(l);
			body.push('\n');
		}
	}
	if !found {
		let names: Vec<&str> = code_heads()
			.map(|h| h.split('|').next().unwrap_or(""))
			.collect();
		errln!(
			"unknown diagnostic code: {}{} (shcl explain lists them all)",
			code,
			suggest(&names, &code)
		);
		return 1;
	}
	out!("\n{}\n", body);
	0
}

/// Every line's spans, one line of output per input line: the indent
/// length, then each token as `kind=start-end` with a mark for how it was
/// quoted (`'`, `"`, or `?` for a quote that never closed), offsets counted
/// from the first character after the indent. A blank line and a comment
/// line say so; every other line is tokenized on its own, raw bodies
/// included, since this is the lexical view and not the parse.
fn do_tokens(o: &Opts) -> u8 {
	let [file] = o.args.as_slice() else {
		errln!("usage: shcl tokens FILE (see --help)");
		return 1;
	};
	let text = match read_input(file) {
		Ok(t) => t,
		Err(e) => {
			errln!("{}", e);
			return EXIT_IO;
		}
	};
	let text = text.strip_prefix('\u{feff}').unwrap_or(&text);
	let mut lines: Vec<&str> = text.split('\n').map(|l| l.trim_end_matches('\r')).collect();
	if text.ends_with('\n') {
		lines.pop();
	}
	let mut tok = Tokens::default();
	let mut out = String::new();
	for (i, line) in lines.iter().enumerate() {
		let ilen = line
			.bytes()
			.take_while(|&b| b == b' ' || b == b'\t')
			.count();
		let rest = &line[ilen..];
		let rest = rest.trim_end_matches([' ', '\t', '\r']);
		let _ = write!(out, "{}:{}", i + 1, ilen);
		if rest.is_empty() {
			out.push_str(" blank\n");
			continue;
		}
		// The parser takes a leading carriage return off with the indent's blanks.
		let body = rest.trim_start_matches([' ', '\t', '\r']);
		let lead = rest.len() - body.len();
		if body.starts_with('#') {
			out.push_str(" comment\n");
			continue;
		}
		let mark = |p: &Piece| match p.quote {
			Quote::None => "",
			Quote::Single => "'",
			Quote::Double => "\"",
			Quote::Open => "?",
		};
		// A stacked element and a fence line are value halves on their own.
		let star = body.starts_with('*') && body[1..].starts_with([' ', '\t', '\r']);
		let fence = body.starts_with("```") || body.starts_with("~~~");
		if star || fence {
			shcl::tokenize_value(rest, lead + usize::from(star), Rules::Current, &mut tok);
			out.push_str(if star { " star" } else { " fence" });
			let _ = write!(out, " value={}-{}", tok.value.0, tok.value.1);
			for p in &tok.elements {
				let _ = write!(out, " elem={}-{}{}", p.start, p.end, mark(p));
			}
			if let Some(at) = tok.comment {
				let _ = write!(out, " comment={}", at);
			}
			out.push('\n');
			continue;
		}
		tokenize(rest, b':', false, Rules::Current, &mut tok);
		for seg in &tok.segments {
			let kind = if seg.star { "star" } else { "name" };
			let name = &seg.name;
			let _ = write!(out, " {}={}-{}{}", kind, name.start, name.end, mark(name));
			if let Some(sel) = &seg.selector {
				let _ = write!(out, " sel={}-{}{}", sel.start, sel.end, mark(sel));
			}
		}
		if let Some(at) = tok.sep {
			let _ = write!(out, " sep={} value={}-{}", at, tok.value.0, tok.value.1);
			for p in &tok.elements {
				let _ = write!(out, " elem={}-{}{}", p.start, p.end, mark(p));
			}
		}
		if let Some(at) = tok.comment {
			let _ = write!(out, " comment={}", at);
		}
		if let Some((at, why)) = tok.fault {
			let _ = write!(out, " fault={}:{}", at, why);
		}
		out.push('\n');
	}
	out!("{}", out);
	0
}

/// Decode an ops-script value: \n \t \\ only; other `\x` stays verbatim. The
/// setters re-encode, so this is just for embedding newlines/tabs on one line.
fn unescape_ops(s: &str) -> String {
	let mut out = String::with_capacity(s.len());
	let mut it = s.chars();
	while let Some(c) = it.next() {
		if c != '\\' {
			out.push(c);
			continue;
		}
		match it.next() {
			Some('n') => out.push('\n'),
			Some('t') => out.push('\t'),
			Some('\\') => out.push('\\'),
			Some(other) => {
				out.push('\\');
				out.push(other);
			}
			None => out.push('\\'),
		}
	}
	out
}

fn apply_op(doc: &mut Document, line: &str) -> Result<(), String> {
	let f: Vec<&str> = line.split('\t').collect();
	// Every op but the array forms takes a fixed number of tab-separated
	// fields. Extra ones used to be dropped, so a `raw` whose content held a
	// literal tab lost everything after it and still reported success; the
	// escape for a tab inside a value is `\t`.
	let want = match f.first().copied().unwrap_or("") {
		"empty" | "remove" | "clear-comments" | "banner" => 2,
		"raw" | "raw-default" => 4,
		"int" | "float" | "bool" | "string" | "datetime" | "literal" | "comment"
		| "int-default" | "float-default" | "bool-default" | "string-default"
		| "datetime-default" | "literal-default" => 3,
		// An array form takes any number of elements; an unknown op is named below.
		_ => 0,
	};
	if want != 0 && f.len() > want {
		return Err(format!(
			"{} takes {} tab-separated field(s), got {}",
			f[0],
			want,
			f.len()
		));
	}
	let path = f.get(1).copied().unwrap_or("");
	let val = || f.get(2).copied().unwrap_or("");
	let pint = |s: &str| s.parse::<i64>().map_err(|_| format!("bad int: {}", s));
	// The language's own float reader takes inf and nan; the document's does
	// not, so they are bad values here, the way a bad datetime is.
	let pflt = |s: &str| {
		s.parse::<f64>()
			.ok()
			.filter(|v| v.is_finite())
			.ok_or_else(|| format!("bad float: {}", s))
	};
	let pbool = |s: &str| match s {
		"true" => Ok(true),
		"false" => Ok(false),
		_ => Err(format!("bad bool: {}", s)),
	};
	let arr = &f[2.min(f.len())..];
	let wrote = match f.first().copied().unwrap_or("") {
		"int" => doc.set_int(path, pint(val())?),
		"float" => doc.set_float(path, pflt(val())?),
		"bool" => doc.set_bool(path, pbool(val())?),
		"string" => doc.set_string(path, &unescape_ops(val())),
		"datetime" => {
			let dt = parse_datetime(val()).ok_or_else(|| format!("bad datetime: {}", val()))?;
			doc.set_datetime(path, &dt)
		}
		"literal" => doc.set_literal(path, val()),
		"literal-default" => doc.set_literal_default(path, val()),
		"int-default" => doc.set_int_default(path, pint(val())?),
		"float-default" => doc.set_float_default(path, pflt(val())?),
		"bool-default" => doc.set_bool_default(path, pbool(val())?),
		"string-default" => doc.set_string_default(path, &unescape_ops(val())),
		"datetime-default" => {
			let dt = parse_datetime(val()).ok_or_else(|| format!("bad datetime: {}", val()))?;
			doc.set_datetime_default(path, &dt)
		}
		"int-array" => doc.set_int_array(
			path,
			&arr.iter().map(|s| pint(s)).collect::<Result<Vec<_>, _>>()?,
		),
		"float-array" => doc.set_float_array(
			path,
			&arr.iter().map(|s| pflt(s)).collect::<Result<Vec<_>, _>>()?,
		),
		"bool-array" => doc.set_bool_array(
			path,
			&arr.iter()
				.map(|s| pbool(s))
				.collect::<Result<Vec<_>, _>>()?,
		),
		"string-array" => {
			let owned: Vec<String> = arr.iter().map(|s| unescape_ops(s)).collect();
			doc.set_string_array(path, &owned.iter().map(|s| s.as_str()).collect::<Vec<_>>())
		}
		"datetime-array" => {
			let dts: Vec<_> = arr
				.iter()
				.map(|s| parse_datetime(s).ok_or_else(|| format!("bad datetime: {}", s)))
				.collect::<Result<Vec<_>, _>>()?;
			doc.set_datetime_array(path, &dts)
		}
		"int-array-default" => doc.set_int_array_default(
			path,
			&arr.iter().map(|s| pint(s)).collect::<Result<Vec<_>, _>>()?,
		),
		"float-array-default" => doc.set_float_array_default(
			path,
			&arr.iter().map(|s| pflt(s)).collect::<Result<Vec<_>, _>>()?,
		),
		"bool-array-default" => doc.set_bool_array_default(
			path,
			&arr.iter()
				.map(|s| pbool(s))
				.collect::<Result<Vec<_>, _>>()?,
		),
		"string-array-default" => {
			let owned: Vec<String> = arr.iter().map(|s| unescape_ops(s)).collect();
			doc.set_string_array_default(
				path,
				&owned.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
			)
		}
		"datetime-array-default" => {
			let dts: Vec<_> = arr
				.iter()
				.map(|s| parse_datetime(s).ok_or_else(|| format!("bad datetime: {}", s)))
				.collect::<Result<Vec<_>, _>>()?;
			doc.set_datetime_array_default(path, &dts)
		}
		"raw" => doc.set_raw(path, &unescape_ops(f.get(3).copied().unwrap_or("")), val()),
		"raw-default" => {
			doc.set_raw_default(path, &unescape_ops(f.get(3).copied().unwrap_or("")), val())
		}
		"empty" => doc.set_empty(path),
		"comment" => doc.set_comment(path, &unescape_ops(val())),
		"remove" | "clear-comments" if unusable_path(doc, path) => {
			return Err(format!("cannot {} {}: not a usable path", f[0], path));
		}
		"remove" => {
			doc.remove(path);
			true
		}
		"clear-comments" => {
			doc.clear_comments(path);
			true
		}
		// The second field is on or off, not a path.
		"banner" => match path {
			"on" | "off" => {
				doc.set_banner(path == "on");
				true
			}
			_ => return Err(format!("bad banner: {} (on or off)", path)),
		},
		other => return Err(format!("unknown op: {}", other)),
	};
	if !wrote {
		// Which half of the op had no spelling: the reader is otherwise sent to
		// the value when it was the info string or the comment that failed.
		let unwritable = match f[0] {
			"literal" | "literal-default" => "the value text is not one value",
			"comment" => "the comment text is not one line",
			"raw" | "raw-default" => raw_refusal(&unescape_ops(f.get(3).copied().unwrap_or(""))),
			_ => "the value has no spelling that reads back",
		};
		return Err(format!(
			"cannot write {}: {}",
			path,
			describe_refusal(doc, path, unwritable)
		));
	}
	Ok(())
}

fn do_set(o: &Opts) -> u8 {
	let [file] = o.args.as_slice() else {
		errln!("usage: shcl set [--write|-w] [options] FILE (see --help)");
		return 1;
	};
	if o.write && file == "-" {
		errln!("set --write cannot rewrite stdin; drop --write to print, or pass a FILE");
		return 1;
	}
	if o.write && !write_target_ok(file) {
		return EXIT_IO;
	}
	// Base doc: with the edits given as options no ops script is read, so a '-'
	// file is the document on stdin the way it is everywhere else; only when
	// stdin is the ops script does '-' mean an empty base. Reading neither threw
	// a piped document away at exit 0.
	// --write names the file this command produces, so a FILE that is not there
	// yet is a create and the edits land in a new document. Only under --write,
	// and only when nothing is at the path at all: without --write there is
	// nothing to create, and a file that exists but cannot be read is still an
	// error rather than something to quietly write over.
	// A created file starts out as the info block, so a new config says what
	// format it is. Comments in an otherwise empty document are the
	// document's trailing trivia, so the edits land above it and the write
	// still goes through the library's save gate.
	// The --layer files sit under it and --set overrides sit on top, before
	// ops, through the same fold every other subcommand uses.
	let creating = o.write && file != "-" && !std::path::Path::new(file).exists();
	let base = if creating {
		Some(if o.no_banner {
			String::new()
		} else {
			GEN_BANNER.to_string()
		})
	} else if file == "-" && o.sets.is_empty() {
		Some(String::new())
	} else {
		None
	};
	// Lines the edits leave alone are written back as they were, so a
	// hand-kept file stays the way it was kept. A created file has none.
	let (mut doc, read) = match load_layered_from(o, file, base, !creating) {
		Ok(loaded) => loaded,
		Err(code) => return code,
	};
	// --set carries the edits, so stdin is left alone: reading it here would
	// block on the console for anyone who passed edits as options.
	let mut ops = String::new();
	if o.sets.is_empty() {
		use std::io::Read;
		// Say so before blocking. With nothing on stdin this used to sit there
		// silently, which reads as a hang rather than as a prompt; the note is
		// unconditional so a pipeline and a terminal behave identically. The
		// program-name prefix marks it as a notice; errors carry none.
		errln!("shcl: reading write-ops from stdin (one op per line, tab-separated; end with EOF)");
		if let Err(e) = std::io::stdin().read_to_string(&mut ops) {
			errln!("stdin: {}", e);
			return EXIT_IO;
		}
	}
	// Split on the newline and take one CR off each piece: that is the CR of a
	// CRLF, or of a CRLF at EOF that lost its LF. A second one is the value's,
	// and `lines()` plus a strip used to eat it.
	for (n, line) in ops.split('\n').enumerate() {
		let line = line.strip_suffix('\r').unwrap_or(line);
		if line.is_empty() || line.starts_with('#') {
			continue;
		}
		if let Err(e) = apply_op(&mut doc, line) {
			errln!("op line {}: {}", n + 1, e);
			return 1;
		}
	}
	if o.write {
		// "Create" was decided before the wait on stdin, so a file that turned
		// up meanwhile is refused rather than replaced.
		if creating && std::path::Path::new(file).exists() {
			errln!(
				"{}: file exists (it appeared while the edits were read)",
				file
			);
			return EXIT_IO;
		}
		// The banner seeded an empty document, so the blank line above it was
		// the document's first and the parse drops those on purpose. Put it
		// back now that the edits sit above it, so a created file reads the
		// way init's output does.
		if creating && !o.no_banner {
			let text = doc.to_canonical();
			if let Some(head) = text.strip_suffix(GEN_BANNER)
				&& !head.is_empty()
				&& !head.ends_with("\n\n")
			{
				doc = Document::parse(&format!("{}\n{}", head, GEN_BANNER));
			}
		}
		// A file that was there is read again first, for the same wait.
		return write_back(
			&doc,
			file,
			o,
			(!creating).then_some(read.as_str()),
			!creating,
		);
	}
	out!("{}", doc.to_text_keep_lines().0);
	0
}

/// The schema `check` validates against: `--schema`, else the one the file
/// names on its Schema line. A relative path there is read from the config
/// file's directory, the way an editor reads it. A URL is left to editors,
/// since a check that reads the network because of a line in a file is not
/// one to run unattended.
fn schema_for(o: &Opts, file: &str, text: &str) -> Option<String> {
	if o.schema.is_some() {
		return o.schema.clone();
	}
	let named = schema_ref(text)?;
	if named.contains("://") {
		errln!(
			"the file names its schema by URL ({}), which check does not fetch; pass --schema=SCHEMA to validate against it",
			named
		);
		return None;
	}
	let b = named.as_bytes();
	let absolute = b[0] == b'/'
		|| b[0] == b'\\'
		|| (b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':');
	if absolute {
		return Some(named);
	}
	let dir = match file.rfind(['/', '\\']) {
		Some(k) if file != "-" => &file[..k],
		_ => ".",
	};
	Some(format!("{}/{}", dir, named))
}

fn do_check(o: &Opts) -> u8 {
	let [file] = o.args.as_slice() else {
		errln!("usage: shcl check [options] FILE (see --help)");
		return 1;
	};
	let text = match read_input(file) {
		Ok(t) => t,
		Err(e) => {
			errln!("{}", e);
			return EXIT_IO;
		}
	};
	// A strict load fails and still hands back the document it recovered, which
	// is what the library's one-shot `load_and_validate` validates. So the schema
	// half runs either way: at strict a user was getting less out of `check` than
	// at standard on the same file, and `check` writes nothing, so `fmt`'s refusal
	// to rewrite a strict-failing document does not carry over.
	let (doc, strict_failed) = match Document::parse_with(&text, o.strictness) {
		Ok(doc) => (doc, false),
		Err(e) => (e.document, true),
	};
	let diags = {
		let mut diags = doc.diagnostics().to_vec();
		// --schema: append validation diagnostics under the same contract.
		// The schema itself always loads at Standard (a program artifact);
		// one that does not load cleanly is a single V099 schema fault.
		if let Some(schema_file) = &schema_for(o, file, &text) {
			let stext = match read_input(schema_file) {
				Ok(t) => t,
				Err(e) => {
					errln!("{}", e);
					return EXIT_IO;
				}
			};
			let sdoc = Document::parse(&stext);
			if sdoc
				.diagnostics()
				.iter()
				.any(|d| d.severity == Severity::Error)
			{
				for d in sdoc.diagnostics() {
					errln!(
						"schema line {}: {:?}: {} {}",
						d.line,
						d.severity,
						d.code,
						d.message
					);
				}
				diags.push(Diagnostic {
					line: 0,
					severity: Severity::Error,
					message: "schema failed to load".to_string(),
					code: "V099",
				});
			} else {
				// The schema's own load has something to say too: an H001
				// on a repeated `allowed` is what explains the V092 below
				// it. On stderr with the schema's own line numbers, the
				// way a V099's are - stdout is the code contract.
				for d in sdoc.diagnostics() {
					errln!(
						"schema line {}: {:?}: {} {}",
						d.line,
						d.severity,
						d.code,
						d.message
					);
				}
				diags.extend(doc.validate(&sdoc));
				suppress_declared_repeats(&sdoc, &mut diags);
				suppress_declared_reopens(&sdoc, &mut diags);
			}
		}
		diags
	};
	// stdout carries the stable codes - the cross-binding contract. The prose is
	// per-binding voice and goes to stderr (which the differential check drops).
	// A V090-V093 line number is a SCHEMA line (the code table says so); the
	// prose names the file so the two number spaces cannot be confused.
	for d in &diags {
		outln!("line {}: {:?}: {}", d.line, d.severity, d.code);
	}
	say_diagnostics(&diags);
	// The codes are the portable half of a diagnostic and nothing else on
	// screen says where to look one up.
	if !diags.is_empty() {
		errln!("(run 'shcl explain CODE' for the rule behind a code)");
	}
	let errors = diags
		.iter()
		.filter(|d| d.severity == Severity::Error)
		.count();
	if strict_failed {
		outln!("strict load failed: {} diagnostic(s)", diags.len());
		6
	} else if errors > 0 {
		// Loaded, but lines were dropped: nonzero so a CI gate on check catches it.
		outln!("failed: {} diagnostic(s), {} error(s)", diags.len(), errors);
		6
	} else {
		outln!("ok ({} diagnostic(s))", diags.len());
		0
	}
}

fn do_init(o: &Opts) -> u8 {
	if !o.args.is_empty() {
		errln!("init takes no file argument (see --help)");
		return 1;
	}
	let Some(schema_file) = &o.schema else {
		errln!("init needs --schema=FILE (see --help)");
		return 1;
	};
	let stext = match read_input(schema_file) {
		Ok(t) => t,
		Err(e) => {
			errln!("{}", e);
			return EXIT_IO;
		}
	};
	// The schema always loads at Standard - a program artifact, not user data.
	let sdoc = Document::parse(&stext);
	if sdoc
		.diagnostics()
		.iter()
		.any(|d| d.severity == Severity::Error)
	{
		for d in sdoc.diagnostics() {
			errln!(
				"schema line {}: {:?}: {} {}",
				d.line,
				d.severity,
				d.code,
				d.message
			);
		}
		errln!("init: schema failed to load");
		// A broken schema is a config-semantics failure, not a usage error:
		// same exit as `check --schema` reporting it.
		return 6;
	}
	match generate(&sdoc, o.no_banner) {
		Ok(text) => {
			out!("{}", text);
			0
		}
		Err(faults) => {
			// V090-V095 carry a schema line; V096 and V097 are about generation
			// as a whole and carry line 0, so "schema line 0" named a line space
			// they are not in.
			say_diagnostics(&faults);
			errln!("init: schema has faults");
			6
		}
	}
}

/// A value in a one-per-line listing. `instances` promises one line per
/// instance, and a value holding a line break broke that, so a caller splitting
/// on newlines counted more instances than `count` reports. Only such a value
/// changes: anything else comes out as it is. The escaped spelling is the one
/// `gen_default_text` writes for the same reason.
fn one_line(v: &str) -> String {
	if !v.contains('\n') && !v.contains('\r') {
		return v.to_string();
	}
	let mut s = String::from("\"");
	for ch in v.chars() {
		match ch {
			'\\' => s.push_str("\\\\"),
			'"' => s.push_str("\\\""),
			'\n' => s.push_str("\\n"),
			'\r' => s.push_str("\\r"),
			'\t' => s.push_str("\\t"),
			c => s.push(c),
		}
	}
	s.push('"');
	s
}

fn do_enum(o: &Opts, want_count: bool) -> u8 {
	let [file, path] = o.args.as_slice() else {
		let name = if want_count { "count" } else { "instances" };
		errln!("usage: shcl {} [options] FILE PATH (see --help)", name);
		return 1;
	};
	let doc = match load_layered(o, file) {
		Ok(d) => d,
		Err(code) => return code,
	};
	if want_count {
		outln!("{}", doc.count(path));
	} else {
		for v in doc.instances(path) {
			outln!("{}", one_line(&v));
		}
	}
	0
}

/// Child field names under a path, one per line, in file order and with
/// duplicates kept. PATH may be left out to enumerate the top level. Each name
/// comes out in the form a path accepts, so one holding a dot or a quote
/// splices back into a path with no further work.
fn do_children(o: &Opts) -> u8 {
	let (file, path) = match o.args.as_slice() {
		[file] => (file.as_str(), ""),
		[file, path] => (file.as_str(), path.as_str()),
		_ => {
			errln!("usage: shcl children [options] FILE [PATH] (see --help)");
			return 1;
		}
	};
	let doc = match load_layered(o, file) {
		Ok(d) => d,
		Err(code) => return code,
	};
	for name in doc.children(path) {
		outln!("{}", shcl::quote_segment(&name));
	}
	0
}

/// Every field path in the document, one per line, in file order and
/// deduplicated - the whole-document counterpart of `children`.
fn do_paths(o: &Opts) -> u8 {
	let [file] = o.args.as_slice() else {
		errln!("usage: shcl paths [options] FILE (see --help)");
		return 1;
	};
	let doc = match load_layered(o, file) {
		Ok(d) => d,
		Err(code) => return code,
	};
	for p in doc.paths() {
		outln!("{}", p);
	}
	0
}

const COMMANDS: [&str; 12] = [
	"get",
	"set",
	"fmt",
	"check",
	"init",
	"count",
	"instances",
	"children",
	"paths",
	"migrate",
	"tokens",
	"explain",
];

fn run(cmd: &str, o: &Opts) -> u8 {
	if let Err(code) = check_opts(cmd, o) {
		return code;
	}
	// A value option in space form takes the next word, so `check --schema FILE`
	// leaves no FILE and the usage line alone never says where it went. Judged
	// after the options, so an option the command does not take is named as
	// that. init and explain want no FILE.
	if cmd != "init"
		&& cmd != "explain"
		&& o.args.is_empty()
		&& let Some((name, v)) = &o.swallowed
	{
		errln!(
			"option {} took '{}' as its value, so no FILE is left; spell it {}=VALUE",
			name,
			v,
			name
		);
		return 1;
	}
	// Every command spelled out, and the last arm a refusal rather than a
	// fall-through: with a catch-all, adding a name to COMMANDS without adding
	// an arm here quietly ran whichever command the catch-all named, with no
	// compile error and no message. main() gates on COMMANDS first, so the arm
	// below is only reachable through that mistake.
	match cmd {
		"get" => do_get(o),
		"set" => do_set(o),
		"fmt" => do_fmt(o),
		"check" => do_check(o),
		"init" => do_init(o),
		"count" => do_enum(o, true),
		"instances" => do_enum(o, false),
		"children" => do_children(o),
		"paths" => do_paths(o),
		"migrate" => do_migrate(o),
		"tokens" => do_tokens(o),
		"explain" => do_explain(o),
		other => {
			errln!("{}: no dispatch arm (see --help)", other);
			1
		}
	}
}

#[cfg(feature = "profiling")]
const PROFILE_FREQ: i32 = 199;
#[cfg(feature = "profiling")]
const PROFILE_BLOCKLIST: [&str; 4] = ["libc", "libpthread", "vdso", "libgcc"];

/// pprof files a sample under the start address of each function on its stack,
/// then names the whole bucket from the inline frames of whichever sample
/// opened it. Fat LTO folds most of the parser into one function, so every
/// sample in it got one name, and the top of the graph was an accessor that
/// happened to be first. It asks libgcc for that start address through this
/// symbol, and a definition in the binary wins over the shared library's, so
/// answering with the address itself files each instruction on its own and
/// its inline frames are its own. Profiling builds only.
#[cfg(feature = "profiling")]
#[unsafe(no_mangle)]
pub extern "C" fn _Unwind_FindEnclosingFunction(
	pc: *mut std::ffi::c_void,
) -> *mut std::ffi::c_void {
	pc
}

/// cicd profiler stage only (profiling builds, SHCL_PROFILE_OUT set): repeat the
/// command under an in-process sampler for SHCL_PROFILE_SECS, then write a
/// flamegraph SVG. Never compiled into a normal build.
#[cfg(feature = "profiling")]
fn run_profiled(cmd: &str, o: &Opts, out: &str) -> u8 {
	let secs: u64 = std::env::var("SHCL_PROFILE_SECS")
		.ok()
		.and_then(|v| v.parse().ok())
		.unwrap_or(8);
	let guard = pprof::ProfilerGuardBuilder::default()
		.frequency(PROFILE_FREQ)
		.blocklist(&PROFILE_BLOCKLIST)
		.build()
		.expect("pprof: failed to start profiler");
	let deadline = std::time::Instant::now() + std::time::Duration::from_secs(secs);
	let mut code = run(cmd, o);
	while std::time::Instant::now() < deadline {
		code = run(cmd, o);
	}
	let report = guard
		.report()
		.build()
		.expect("pprof: failed to build report");
	let file = std::fs::File::create(out).expect("pprof: failed to create SVG");
	report
		.flamegraph(file)
		.expect("pprof: failed to write flamegraph");
	// The blocklist above drops a sample whose leaf is inside libc rather than
	// truncating it, so allocation, copying and write time never reach the
	// graph and every percentage in it is a share of what survived. It is there
	// to keep the signal handler out of libc's own unwinder, so the drop stays;
	// what it cannot do is go unsaid. The count rides beside the SVG so the
	// report can repeat it.
	let kept: isize = report.data.values().sum();
	let expected = secs as isize * PROFILE_FREQ as isize;
	std::fs::write(
		format!("{}.samples", out),
		format!("{} {}\n", kept, expected),
	)
	.ok();
	errln!(
		"shcl: wrote flamegraph -> {} ({} of about {} samples; the rest had a leaf inside libc)",
		out,
		kept,
		expected
	);
	code
}

/// cicd profiler stage only (SHCL_PROFILE_CHECK set): the sampler's
/// attribution against a workload whose answer is known, so a graph is not
/// trusted on faith. Two loops inlined into one function cost three to one,
/// and their samples have to split about that way. When a bucket takes one
/// name for the whole function, one of them gets everything.
#[cfg(feature = "profiling")]
fn profile_check() -> u8 {
	let guard = pprof::ProfilerGuardBuilder::default()
		.frequency(PROFILE_FREQ)
		.blocklist(&PROFILE_BLOCKLIST)
		.build()
		.expect("pprof: failed to start profiler");
	let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
	let mut x = 0u64;
	while std::time::Instant::now() < deadline {
		x ^= calibrate_both(std::hint::black_box(20_000));
	}
	std::hint::black_box(x);
	let report = guard
		.report()
		.build()
		.expect("pprof: failed to build report");
	let (mut three, mut one) = (0isize, 0isize);
	for (frames, n) in &report.data {
		let names: Vec<String> = frames.frames.iter().flatten().map(|s| s.name()).collect();
		if names.iter().any(|n| n.contains("calibrate_three")) {
			three += n;
		} else if names.iter().any(|n| n.contains("calibrate_one")) {
			one += n;
		}
	}
	let share = 100 * three / (three + one).max(1);
	let ok = three + one >= 200 && (65..=85).contains(&share);
	errln!(
		"shcl: profiler attribution {}: {} of {} samples in the 3-to-1 loop pair went to the larger, {}% where 75% is right",
		if ok { "ok" } else { "WRONG" },
		three,
		three + one,
		share
	);
	u8::from(!ok)
}

#[cfg(feature = "profiling")]
#[inline(never)]
fn calibrate_both(n: u64) -> u64 {
	calibrate_three(std::hint::black_box(3 * n)) ^ calibrate_one(std::hint::black_box(n))
}

#[cfg(feature = "profiling")]
#[inline(always)]
fn calibrate_three(n: u64) -> u64 {
	let mut x = 0x9e37u64;
	for k in 0..n {
		x = x.rotate_left(5) ^ k.wrapping_mul(0x9e37_79b9_7f4a_7c15);
	}
	x
}

#[cfg(feature = "profiling")]
#[inline(always)]
fn calibrate_one(n: u64) -> u64 {
	let mut x = 0x7f4au64;
	for k in 0..n {
		x = x.rotate_left(7) ^ k.wrapping_mul(0xc2b2_ae3d_27d4_eb4f);
	}
	x
}

/// Rust's runtime sets SIGPIPE to SIG_IGN, so a closed stdout comes back as an
/// EPIPE write error and the next println! panics (exit 134). Restore SIG_DFL so
/// a broken pipe kills us by signal - the conventional 141 - like head/cat, and
/// matching the other bindings. Self-contained extern to stay zero-dep.
#[cfg(unix)]
fn reset_sigpipe() {
	const SIGPIPE: i32 = 13;
	const SIG_DFL: usize = 0;
	unsafe {
		unsafe extern "C" {
			fn signal(signum: i32, handler: usize) -> usize;
		}
		signal(SIGPIPE, SIG_DFL);
	}
}
#[cfg(not(unix))]
fn reset_sigpipe() {}

fn main() -> ExitCode {
	let code = run_cli();
	// A tail still sitting in the buffer when the work is done fails the same
	// way a write does.
	if let Err(e) = std::io::Write::flush(&mut std::io::stdout()) {
		write_failed(&e);
	}
	ExitCode::from(code)
}

fn run_cli() -> u8 {
	reset_sigpipe();
	#[cfg(feature = "profiling")]
	if std::env::var_os("SHCL_PROFILE_CHECK").is_some() {
		return profile_check();
	}
	let argv: Vec<String> = match std::env::args_os()
		.skip(1)
		.map(|a| a.into_string())
		.collect::<Result<Vec<_>, _>>()
	{
		Ok(v) => v,
		Err(_) => {
			errln!("invalid argument encoding (expected UTF-8)");
			return 1;
		}
	};
	let first = argv.first().map(|s| s.as_str());
	let asked = asked_for(&argv);
	// One convention: asking for the help - by name, by flag, or by asking for
	// nothing at all - prints it and succeeds. The blank lines separate the
	// block from the surrounding prompts. A bare run used to print the same
	// text unpadded and exit 1, which read as neither a help nor an error.
	if asked == Some("help") || first == Some("help") || argv.is_empty() {
		// `shcl help CMD` and `shcl CMD --help` narrow to one subcommand. In the
		// flag form the command is the first word, which a bare `--help` is not.
		let topic = if first == Some("help") {
			// A help flag after `help` asks for the same thing twice, so it is
			// no topic: `help --help` and `help get -h` print what they name.
			let words: Vec<&str> = argv[1..]
				.iter()
				.map(|s| s.as_str())
				.filter(|w| !matches!(*w, "-h" | "--help"))
				.collect();
			if words.len() > 1 {
				errln!("usage: shcl help [CMD] (see --help)");
				return 1;
			}
			words.first().copied()
		} else {
			first.filter(|f| !f.starts_with('-'))
		};
		match topic {
			// The informational words are the full help's own last two lines,
			// so there is nothing narrower to show for them.
			None | Some("help") | Some("version") | Some("about") | Some("donate") => {
				out!("\n{}\n", HELP)
			}
			Some(t) if COMMANDS.contains(&t) => out!("\n{}\n", help_for(t)),
			Some(t) => {
				errln!(
					"unknown command: {}{} (see --help)",
					t,
					suggest(&command_names(), t)
				);
				return 1;
			}
		}
		return 0;
	}
	if asked == Some("version") || first == Some("version") {
		outln!("{}", VERSION_LINE);
		return 0;
	}
	if asked == Some("about") || first == Some("about") {
		out!("\n{}\n", ABOUT);
		return 0;
	}
	if asked == Some("donate") || first == Some("donate") {
		out!("\n{}\n", DONATE);
		return 0;
	}
	let cmd = argv[0].as_str();
	if !COMMANDS.contains(&cmd) {
		// Before the options are judged, so a typo in the command is reported
		// as that and not as an option the wrong command cannot take.
		if cmd.starts_with('-') && cmd != "--" {
			let name = cmd.split('=').next().unwrap_or(cmd);
			if known_option(name) {
				// It is a real option, just in front of the subcommand. Calling
				// it unknown and then suggesting the same spelling back says
				// nothing about what is actually wrong.
				errln!("option {} goes after the subcommand (see --help)", name);
			} else {
				errln!(
					"unknown option: {}{} (see --help)",
					cmd,
					suggest(&option_names(), name)
				);
			}
		} else {
			errln!(
				"unknown command: {}{} (see --help)",
				cmd,
				suggest(&command_names(), cmd)
			);
		}
		return 1;
	}
	let o = match parse_opts(&argv[1..]) {
		Ok(o) => o,
		Err(e) => {
			errln!("{}", e);
			return 1;
		}
	};
	#[cfg(feature = "profiling")]
	if let Ok(out) = std::env::var("SHCL_PROFILE_OUT") {
		return run_profiled(cmd, &o, &out);
	}
	run(cmd, &o)
}
