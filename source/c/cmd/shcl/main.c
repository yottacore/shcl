// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// shcl CLI - the C binding's command surface. Flags, output, and exit codes
// mirror the Rust reference exactly; the cicd cross-binding check compares them
// byte for byte, so any drift here fails the pipeline.

#ifndef _WIN32
	// fileno/fsync/getpid under -std=c11 need an explicit POSIX feature request.
	// realpath sits behind XSI rather than plain POSIX in glibc, hence both.
	#define _POSIX_C_SOURCE 200809L
	#define _XOPEN_SOURCE 700
#endif

#define SHCL_IMPLEMENTATION
#include "shcl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <locale.h>
#include <errno.h>
#include <math.h>
#include <fcntl.h>
#include <stdarg.h>
#ifdef _WIN32
	#include <windows.h>
	#include <shellapi.h>
	#include <io.h>
	#include <process.h>
	#include <sys/stat.h>
	#define getpid _getpid
	#define fdopen _fdopen
	#define close _close
#else
	#include <unistd.h>
	#include <sys/stat.h>
#endif

// Keep in step with source/rust/Cargo.toml, the canonical version source.
#define VERSION "2.0.0"

// The build number, set only for a stamped build (-DSHCL_BUILD=ID, unquoted).
// The Rust CLI is the one the pipeline stamps; see its build.rs.
#ifdef SHCL_BUILD
	#define SHCL_STR_(x) #x
	#define SHCL_STR(x) SHCL_STR_(x)
	#define VERSION_LINE "shcl v" VERSION " build " SHCL_STR(SHCL_BUILD)
#else
	#define VERSION_LINE "shcl v" VERSION
#endif

static const char *HELP =
	"shcl - Simple Hierarchical Config Language (reference CLI)\n"
	"\n"
	"Usage:\n"
	"  shcl get [type] [options] FILE PATH    read one value (or array) at a path\n"
	"  shcl set [--write|-w] [options] FILE   apply edits (--set, or ops on stdin);\n"
	"                                         print FILE with the edited lines\n"
	"                                         changed (or rewrite FILE in place\n"
	"                                         with --write, which creates FILE\n"
	"                                         when it is not there yet)\n"
	"  shcl fmt [--write|-w] [options] FILE   print the canonical form (or rewrite\n"
	"                                         FILE in place with --write)\n"
	"  shcl check [options] FILE              load and print diagnostics\n"
	"                                         (--schema=SCHEMA, or the file's own\n"
	"                                         '##    Schema   PATH' line, also\n"
	"                                         validates FILE against a schema)\n"
	"  shcl init [--no-banner] --schema=S     print a commented starter config\n"
	"                                         from a schema (required fields live,\n"
	"                                         optional commented, wildcards noted)\n"
	"  shcl count [options] FILE PATH         number of instances at a path\n"
	"  shcl instances [options] FILE PATH     instance values at a path, one per line\n"
	"  shcl children [options] FILE [PATH]    child field names under a path, one per\n"
	"                                         line (the top level when PATH is left\n"
	"                                         out)\n"
	"  shcl paths [options] FILE              every field path in the document, one\n"
	"                                         per line\n"
	"  shcl migrate [options] FILE            rewrite a 2.x file for the current\n"
	"                                         rules (print it, rewrite FILE with\n"
	"                                         --write or -w, keeping a backup of\n"
	"                                         the original beside it, or name the\n"
	"                                         lines it would change with --check)\n"
	"  shcl upgrade [options] FILE            when FILE does not load clean, or\n"
	"                                         with --from-2x reads differently once\n"
	"                                         migrated, print it migrated and made\n"
	"                                         over the way fmt writes it, with the\n"
	"                                         info block (or back it up and rewrite\n"
	"                                         it with --write); anything else is\n"
	"                                         left alone\n"
	"  shcl tokens FILE                       each line's lexical spans, for seeing\n"
	"                                         why the parser read a line as it did\n"
	"                                         (every line on its own, raw bodies\n"
	"                                         included)\n"
	"  shcl explain [CODE]                    what a diagnostic code means (every\n"
	"                                         code, one line each, when CODE is\n"
	"                                         left out)\n"
	"  shcl help [CMD]                        this help (or one subcommand's, with\n"
	"                                         CMD); also -h or --help, which after\n"
	"                                         CMD give that one's\n"
	"  shcl --version                         the version (also -v or -V)\n"
	"  shcl --about | --donate                what shcl is, or how to support it\n"
	"\n"
	"set edits FILE, the base document. Edits go in as the repeatable --set,\n"
	"--set-literal, --set-default, --set-literal-default and --remove options, which\n"
	"persist with --write; given any of them, no ops are read from stdin. Raw blocks\n"
	"go in only as a write-ops script on stdin, which can make the other edits too,\n"
	"one op per line, tab-separated. FILE '-' follows stdin: the document when an\n"
	"option holds the edits, an empty base when the ops script has stdin instead.\n"
	"With --write, a FILE that does not exist yet is created. Lines the edits leave\n"
	"alone come back as they were written; with --layer, or where the edited text\n"
	"would not load back the same, the whole document comes out canonical, the way\n"
	"fmt writes it. A result that would delete lines or values from the file is\n"
	"refused at exit 7, printed or written (--lossy overrides). PATH ends at the\n"
	"first '=' outside quotes and parens, so a selector may hold one. Ops:\n"
	"  int|float|bool|string|datetime<TAB>PATH<TAB>VALUE       set a scalar\n"
	"  <type>-array<TAB>PATH<TAB>V1<TAB>V2...                  set an inline array\n"
	"  <type>[-array]-default<TAB>...                          set only if absent\n"
	"  literal[-default]<TAB>PATH<TAB>TEXT                     set from value syntax\n"
	"  raw[-default]<TAB>PATH<TAB>INFO<TAB>CONTENT             set a raw block\n"
	"  empty<TAB>PATH   comment<TAB>PATH<TAB>TEXT   remove<TAB>PATH\n"
	"  clear-comments<TAB>PATH                                 drop comments above\n"
	"  banner<TAB>on|off                                       add or drop info block\n"
	"String, raw and comment values read escapes as a file does: NEWLINE or TAB\n"
	"between two U+25C9 marks. A backslash is text, and a line starting with # is a\n"
	"script comment.\n"
	"\n"
	"Types (get only; default --string):\n"
	"  --int --float --bool --datetime --string --raw --rawinfo --duration --size\n"
	"  --array                                read the value as an array of the type\n"
	"  --rawinfo reads a raw block's info-string (the fence tag), not its content\n"
	"  --duration prints milliseconds and --size bytes; a bare number takes its\n"
	"  unit from the field name (timeout-ms, cache_mb), else from --unit\n"
	"\n"
	"Options (the subcommands each belongs to are in parentheses):\n"
	"  --default=VALUE                        (get) value to print when the read is\n"
	"                                         not Good (implies --on-bad=default; for\n"
	"                                         arrays, substituted per bad slot)\n"
	"  --on-bad=error|default|flag            (get) error: fail loudly; default:\n"
	"                                         print the default; flag: print the\n"
	"                                         value anyway and report via exit code\n"
	"                                         (the default)\n"
	"  --slots                                (get) prefix each line with its slot\n"
	"                                         status and a tab (per element, or per\n"
	"                                         wildcard slot)\n"
	"  --unit=UNIT                            (get) the unit a bare number is in,\n"
	"                                         for --duration (ms s m h d) or --size\n"
	"                                         (B kB KB MB GB TB KiB MiB GiB TiB),\n"
	"                                         when the field name gives none\n"
	"  --decimal                              (get) --size reads KB to TB as powers\n"
	"                                         of 1000, not 1024\n"
	"  --no-banner                            (init, and set --write when it creates\n"
	"                                         FILE) leave out the info block naming\n"
	"                                         the format and pointing at its spec\n"
	"  --write                                (fmt/set/migrate/upgrade) rewrite\n"
	"                                         FILE in place, written -w too,\n"
	"                                         through a temp file and a rename;\n"
	"                                         refused with a FILE of '-'\n"
	"  --lossy                                (fmt/set/migrate) go ahead even when\n"
	"                                         the result would delete lines or\n"
	"                                         values from the file. Without it the\n"
	"                                         write refuses at exit 7 and changes\n"
	"                                         nothing; set and migrate without\n"
	"                                         --write exit 7 too, and set prints\n"
	"                                         nothing. fmt takes it with --write\n"
	"                                         only\n"
	"  --from-2x                              (migrate/upgrade) the file was\n"
	"                                         written for 2.x, so rewrite the\n"
	"                                         spellings the two rule sets read\n"
	"                                         differently; without it those are\n"
	"                                         left alone and the command exits 7\n"
	"  --check                                (fmt/migrate) print nothing and exit 6\n"
	"                                         when fmt would change the file or\n"
	"                                         migrate would rewrite a line (named on\n"
	"                                         stderr), or 7 when --write would\n"
	"                                         refuse it\n"
	"  --strictness=loose|standard|strict     (get/set/fmt/check/count/instances/\n"
	"                                         children/paths) or 1|2|3 (default\n"
	"                                         standard)\n"
	"  --schema=SCHEMA                        (check/init) validate FILE against a\n"
	"                                         schema; adds V### diagnostics. check\n"
	"                                         without it uses FILE's Schema line\n"
	"  --layer=FILE                           (get/set/fmt/count/instances/children/\n"
	"                                         paths) merge a lower-priority layer\n"
	"                                         under FILE; repeatable, earlier =\n"
	"                                         lower priority\n"
	"  --set=PATH=VALUE                       (get/set/fmt/count/instances/children/\n"
	"                                         paths) override one path as the top\n"
	"                                         layer, after all files; repeatable. On\n"
	"                                         'set' it is an edit to the document\n"
	"                                         itself, so it persists with --write.\n"
	"                                         VALUE goes in as data: its type still\n"
	"                                         follows the text (8 is an int), but a\n"
	"                                         comma or quote in it is content, not\n"
	"                                         syntax\n"
	"  --set-literal=PATH=TEXT                (same subcommands) as --set, except\n"
	"                                         TEXT goes in as value\n"
	"                                         syntax the way a file writes it, so\n"
	"                                         'ports=[80, 443]' writes a two-element\n"
	"                                         array, 'title=\"My App\"' a string and\n"
	"                                         'color=`#FF8800`' a backtick value. A\n"
	"                                         # outside quotes ends the value; text\n"
	"                                         spanning lines is rejected\n"
	"  --set-default=PATH=VALUE               (same) as --set, but only when nothing\n"
	"  --set-literal-default=PATH=TEXT        is at the path yet - the write-out-\n"
	"                                         defaults half of the writer\n"
	"  --remove=PATH                          (same) delete what is at the path,\n"
	"                                         with its subtree. Removing nothing is\n"
	"                                         not an error, but a PATH that cannot\n"
	"                                         parse is\n"
	"The five above share one ordered list, so two of them touching the same path\n"
	"resolve in the order given. Raw blocks still go in through the ops script.\n"
	"\n"
	"Value options accept either spelling: --default=VALUE or --default VALUE. In\n"
	"the space form the next argument is taken as the value whatever it looks like,\n"
	"so --default --int reads --int as the default. Use -- to end the options when a\n"
	"FILE or PATH begins with a dash. The flags -h, --help, -v, -V, --version,\n"
	"--about and --donate count anywhere an option can go. Several in one run each\n"
	"print once, in the order given.\n"
	"An option a subcommand does not use is a usage error, not ignored. Also\n"
	"refused: --write with --layer; --write with --set outside 'set'; --write with a\n"
	"FILE of '-'; --lossy on 'fmt' without --write; --no-banner on 'set' without\n"
	"--write; --check with --write; --layer=- on 'set'; --array with --raw,\n"
	"--rawinfo, --duration or --size; --default with --on-bad=error or\n"
	"--on-bad=flag; '-' named more than once across FILE, --layer and --schema; a\n"
	"PATH that cannot parse, --default or not. Two options that ask for different\n"
	"answers are a usage error whichever order they came in, and both are named:\n"
	"two different type options, or one value option given two different values.\n"
	"Repeating an option with the same value is allowed, and --layer and --set are\n"
	"ordered lists, so they repeat.\n"
	"Every subcommand that loads a document prints the load's diagnostics to stderr,\n"
	"once per run; 'shcl explain CODE' gives the rule behind one of their codes. An\n"
	"in-place write also refuses when the rewrite would delete lines or values\n"
	"from the file (--lossy overrides), and set and migrate without --write exit 7\n"
	"where it would. migrate refuses a file that does not say which rules it was\n"
	"written for, when the two readings differ (--from-2x says it is 2.x), and\n"
	"reports a 2.x binding it cannot convert. With --write, migrate\n"
	"and upgrade keep the original beside FILE as\n"
	"NAME_backup_YYYYmmDD-HHMMSS_format-vN.EXT, in local time, where N is the format\n"
	"it was written for, and write nothing when that name is taken. An upgrade\n"
	"writes even when the fresh file drops lines or values, since the backup keeps\n"
	"them.\n"
	"FILE may be '-' for stdin. With --layer, FILE is the highest file layer and\n"
	"each --layer is merged under it in order; --set applies last. 'fmt' with\n"
	"layers prints the merged canonical document.\n"
	"\n"
	"Exit codes: 0 good, 1 usage error, 2 empty, 3 not found, 4 bad type,\n"
	"5 multiple instances, 6 check failed, strict load failed, init's schema has\n"
	"faults, or --check found a rewrite to make, 7 a result refused for deleting\n"
	"lines or values (--lossy overrides), or migrate or upgrade left something\n"
	"behind, 8 a file or stream could not be read or written.\n";

// About and donate are stdout, so they are byte-for-byte contracts across the
// bindings the same way the help text and the init banner are. The version
// concatenates from the VERSION macro so it cannot drift from `shcl --version`.
static const char *ABOUT =
	VERSION_LINE "\n"
	"Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ].\n"
	"Project: https://github.com/yottacore/shcl\n"
	"Licensed under the MIT License. Full text at:\n"
	"  https://spdx.org/licenses/MIT.html\n"
	"No warranty.\n"
	"\n"
	"Simple Hierarchical Config Language. Forgiving to write, predictable to read.\n"
	"Types live in your code, not in the file, so nothing is guessed at parse time.\n"
	"One broken line is skipped with a note instead of taking down the whole file.\n";

static const char *DONATE =
	"shcl is free software under the MIT License, and stays that way.\n"
	"\n"
	"If it saves you time and you want to give something back:\n"
	"  https://github.com/sponsors/jim-collier\n"
	"  https://ko-fi.com/jimcollier\n"
	"\n"
	"A star on the project, a clear bug report, or a mention to someone who needs it\n"
	"are worth just as much.\n";

// One edit from the --set family: the path, its length, the value, and which
// spelling produced it. The five spellings share one ordered list, so two of
// them touching the same path resolve in the order given.
typedef struct { const char *path; size_t plen; const char *value; const char *opt; } SetOpt;

typedef struct {
	const char *kind;         // int|float|bool|datetime|string|raw
	// Which type option was given. kind cannot answer that, since it starts at
	// the default type.
	const char *kind_opt;     // NULL if no type option was given
	const char *kind_text;    // as it was typed, for the competing-pair message
	// The first competing pair the line held. Two options that ask for different
	// answers are a usage error whichever order they came in, so the pair is
	// recorded here rather than refused on the spot and the "not valid for this
	// subcommand" answer still comes first. clash_opt is set when the pair is one
	// option repeated with a different value, in which case clash[] holds the two
	// values; otherwise clash[] holds whole option spellings.
	const char *clash_opt;    // NULL when clash[] is already whole spellings
	const char *clash[2];     // clash[0] NULL when nothing competed
	int array;
	int slots;
	const char *deflt;        // NULL if unset
	const char *on_bad;       // error|default|flag
	// What an explicit --on-bad asked for, whatever the order. --default sets
	// on_bad too, so without this the two options silently overwrote each other
	// and which one survived depended on which came last.
	const char *on_bad_arg;   // NULL if --on-bad was not given
	const char *on_bad_text;  // as it was typed, for the competing-pair message
	shcl_strictness strictness;
	const char *strictness_text;  // NULL if --strictness was not given
	int write;
	int lossy;
	int from_2x;
	int check;
	int no_banner;
	const char *schema;       // NULL if unset
	const char *unit;         // --unit, read against the type at check time; NULL if unset
	int decimal;
	const char **layers; int nlayers; // lower-priority layers, in listed order (unbounded)
	SetOpt *sets; int nsets;          // final override layer, in the order given (unbounded)
	const char **args; int nargs;     // positional: FILE [PATH]
	const char *seen[16]; int nseen;  // distinct canonical option names, for per-command validation
	// A value option in space form that took the LAST word on the line. That
	// word is usually the FILE, and the usage line alone never says so.
	const char *swallowed_opt, *swallowed_value;   // NULL if none
} Opts;

// A file or stream that could not be read or written. Its own code since a
// script's remedy - fix the path, the permissions, the disk - has nothing to do
// with the remedy for a usage error, which keeps 1.
#define EXIT_IO 8

// The diagnostic code table behind `shcl explain`. One entry per code: a
// `CODE|severity|summary` head line, then its detail indented two spaces.
// spec.md's diagnostic tables are the long form; this is the same rules cut to
// what a terminal shows. Like the help text it is byte-for-byte across the
// bindings, and crosscheck compares every code.
static const char *CODES =
	"E001|error|field line under a parent holding stacked '- ' list items\n"
	"  A parent holds list items or named children, not both. The field line\n"
	"  is kept and the items stay.\n"
	"E002|error|value after a last-segment selector (a.b(X): v)\n"
	"  The selector already says which instance, so the value has nowhere to go\n"
	"  and is ignored. Put the value on the line that creates the instance.\n"
	"E003|error|selector names an instance that does not exist\n"
	"  a(5).b where there is one a. An index selects an existing instance by\n"
	"  position and never creates one, so a binding line should select by value\n"
	"  instead.\n"
	"E004|error|wildcard selector on a binding line\n"
	"  Wildcards read every instance, so there is no single one to write to.\n"
	"  They are query-only.\n"
	"E005|error|unterminated raw block (closing fence never found)\n"
	"  The block runs to the end of the file. Close it with a fence at the\n"
	"  opening fence's indent.\n"
	"E006|error|raw-block fence with no parent field to bind to\n"
	"  A raw block is a field's value, so a fence needs a field line above it.\n"
	"E007|error|stacked '- ' list item with no parent field\n"
	"  A '- value' line is an item of the field above it.\n"
	"E008|error|stacked '- ' list item under a parent with field children\n"
	"  The parent already holds named children, so the item is dropped.\n"
	"E009|error|empty stacked '- ' list item\n"
	"  A '-' with nothing after it has no value to add.\n"
	"E011|error|stacked '- ' item for a field that already has a value\n"
	"  The field's value is kept and the item is ignored. A field is written\n"
	"  one way or the other, not both.\n"
	"E012|error|indentation matches no open level\n"
	"  The line is skipped, and anything written deeper is skipped with it\n"
	"  (E018). A save writes them back as they were when the indent holds a\n"
	"  space. One indented with tabs alone would bind there, so it is lost.\n"
	"  Indent to a column some open parent already uses.\n"
	"E013|error|a line starting with '*', the old list item marker\n"
	"  A list item is written '- value' now. The line is kept as written and\n"
	"  binds nothing, and the other items still load. What is written under it\n"
	"  goes with it.\n"
	"E014|error|malformed line, or a bare field name that needs quotes\n"
	"  A bare name is a letter, then letters, digits, '-' and '_'. One that\n"
	"  breaks only that rule, such as 404 or user name, still reads: the line is\n"
	"  kept, and the lines under it load under that name. Quote the name to fix\n"
	"  it. Any other malformed line is kept as written and the lines under it go\n"
	"  with it; the prose names the reason and the byte column. A quote that\n"
	"  never closes in a field name arrives here too. A raw block the line opens\n"
	"  is kept with it.\n"
	"E015|error|missing colon (repaired as an empty value)\n"
	"  The name binds with no value rather than the line being dropped.\n"
	"E016|error|nesting deeper than the 512-level cap (line skipped)\n"
	"  The cap is what makes any loadable document safe to format, merge and\n"
	"  copy in every binding.\n"
	"E017|error|an open quote or backtick in a value or selector body\n"
	"  A piece that starts with a quote must end with the matching one. The line\n"
	"  is kept verbatim and binds nothing. In a value, the lines under it still\n"
	"  load, under the field with no value. The same typo in a field name is\n"
	"  E014.\n"
	"E018|error|line written under a line that was skipped\n"
	"  It is skipped with it, so a skipped line's block never re-parents one\n"
	"  level up. Fix the line above and this one comes back with it.\n"
	"E019|error|a bracket array that is not well formed\n"
	"  An array is one line, ports: [80, 443], and [] is the empty array. Text\n"
	"  after the closing ']', a bare '[' or ']' inside, an empty element, or no\n"
	"  closing ']' on the line is malformed. Quote the value if it is text:\n"
	"  log: \"[INFO] started\". A list item that is an array is E019 too, since\n"
	"  arrays do not nest. The line is kept verbatim: it binds nothing and\n"
	"  nothing counts as lost. The lines under it still load, under the field\n"
	"  with no value, so a read on the field is Empty when one of them loads and\n"
	"  NotFound when none does.\n"
	"E020|error|node cap exceeded (fires only under a caller-supplied cap)\n"
	"  The parse stopped there and the unparsed remainder counts as lost, so a\n"
	"  later save refuses rather than writing a truncated file.\n"
	"E021|error|array longer than the caller-supplied element cap\n"
	"  The line is skipped whole rather than truncated to a value the author\n"
	"  never wrote. A fence line's info string is split the same way.\n"
	"E022|error/hint|the diagnostics list was cut at the caller-supplied cap\n"
	"  This entry ends the list and counts what was not listed. An error when\n"
	"  any unlisted one was, so a scan for errors still finds one; a hint\n"
	"  otherwise.\n"
	"E023|error|a bad escape\n"
	"  An escape is a name from the escape list between two ◉ marks, such as\n"
	"  ◉TAB◉, ◉NEWLINE◉ or ◉U+200B◉, and a real ◉ is written ◉ESCAPE_CHAR◉.\n"
	"  Anything else between two marks is an error, and so is a mark with no\n"
	"  partner. A backslash is plain text. The line is kept verbatim: it binds\n"
	"  nothing and a read on it is NotFound. When only the value is wrong, the\n"
	"  lines under it still load, under the field with no value, and a read on the\n"
	"  field is Empty once one of them loads. When the name is, a raw block the\n"
	"  line opens is kept with it.\n"
	"E025|error|a tab, a quote, a bracket or a loose colon in bare text\n"
	"  A bare value or list item may hold spaces, kept as typed. A tab or other\n"
	"  whitespace, a quote, a bracket, or a colon with a space or the end after\n"
	"  it is an error: host: a.com port: 80 is two fields on one line. Put each\n"
	"  field on its own line, or quote the value: name: \"O'Brien\". An array\n"
	"  element or a selector body takes no whitespace, and a selector body no\n"
	"  colon, comma or paren either. Whitespace at either end is trimmed first.\n"
	"  The line is kept verbatim and binds nothing. In a value, the lines under\n"
	"  it still load, under the field with no value.\n"
	"E026|error|a bare comma with a space or the end after it\n"
	"  ports: 80, 443 is an error. Write the array in brackets, ports: [80, 443],\n"
	"  or quote text that has a comma. A comma with text right after it is text,\n"
	"  so opts: rw,noatime is one string. The line is kept verbatim and binds\n"
	"  nothing. The lines under it still load, under the field with no value. A\n"
	"  list item with a bare comma, - a, b, is kept the same way, and the other\n"
	"  items still load.\n"
	"E027|error|a list item like - name: or - name: value\n"
	"  A colon with a space or the end after it is how YAML starts an object in\n"
	"  a list, and SHCL writes one as an instance. A colon with text after it is\n"
	"  fine, as in - localhost:8080. Quote the item if it is text: - \"name: a\".\n"
	"  The line is kept as written, and the other items still load.\n"
	"E028|error|an array on a field with lines under it\n"
	"  A field with fields under it takes one plain value or none, so\n"
	"  route: [GET, POST] with lines under it is an error. Give the field one\n"
	"  value and put the list in a field under it: methods: [GET, POST]. The line\n"
	"  is kept verbatim, and the lines under it load under the field with no\n"
	"  value.\n"
	"E029|error|a selector in brackets, the old spelling\n"
	"  Selectors are written in parens: person(Bucky).city, person(\"New York\"),\n"
	"  person(0) and person(*). Brackets are only for arrays. The line is kept\n"
	"  as written and binds nothing. When it selects by value, the lines under\n"
	"  it still load, under the instance it names. On a command line, quote the\n"
	"  path, since a bare ( is a syntax error in most shells.\n"
	"H001|hint|repeated bare leaf (an array written as repeated lines)\n"
	"  Repeated leaves are legal - that is how instances are written - but\n"
	"  'tags: red' twice and 'tags: [red, blue]' look alike, so the parser says\n"
	"  which one it read. A schema's repeat bound above 1 disavows it.\n"
	"H002|hint|a binding merged with a non-adjacent earlier one\n"
	"  Same name and value, so the two combine. Legal, and only the parser can\n"
	"  see it happened. The prose names the earlier line, and a schema can\n"
	"  disavow it per section with 'reopen: true'.\n"
	"H005|hint|a value in another unit than its field name ends in\n"
	"  timeout-ms: 5s reads as 5000 milliseconds, since a unit in the value\n"
	"  wins over the one the name gives a bare number. Legal, and often a slip.\n"
	"V001|error|unknown field\n"
	"  No schema path covers it. Only the topmost unknown node is reported; its\n"
	"  subtree is skipped. The prose has the did-you-mean suggestion.\n"
	"V002|error|required path missing\n"
	"  Declared 'required: yes' and nothing in the document resolves it.\n"
	"V003|error|wrong type\n"
	"  The value does not read as the declared type.\n"
	"V004|error|value not in the allowed set\n"
	"  The line number is the node, at its first offending element.\n"
	"V005|error|below the declared min\n"
	"  The prose names the bound and the value that missed it.\n"
	"V006|error|above the declared max\n"
	"  The prose names the bound and the value that missed it.\n"
	"V007|error|instance count out of repeat bounds\n"
	"  Too few or too many instances of a field the schema bounds with 'repeat'.\n"
	"V090|error|unknown schema key\n"
	"  A schema fault: the key is dropped and the rest of the schema still\n"
	"  checks the document. The line number is a schema line.\n"
	"V091|error|unknown schema type name\n"
	"  A schema fault, on a schema line.\n"
	"V092|error|bad schema constraint value\n"
	"  A schema fault, on a schema line. Also covers min or max without a\n"
	"  numeric type, and 'allowed' with 'type: raw'.\n"
	"V093|error|bad schema path\n"
	"  A schema fault, on a schema line. The path spelling could not be read, so\n"
	"  the unknown-field sweep turns off with it.\n"
	"V094|error|bad fragment declaration\n"
	"  No name, a duplicate, or a non-field key inside. A schema fault, on a\n"
	"  schema line.\n"
	"V095|error|'inherits' names no declared fragment\n"
	"  A schema fault, on a schema line. A mount naming a missing fragment\n"
	"  checks nothing at the mount.\n"
	"V096|error|schema expands to more fields than generation allows\n"
	"  Generation lays every path out flat, so mounts multiply. The line number\n"
	"  is 0: this is about the output, not a schema line.\n"
	"V097|error|generated output does not load, or fails its own schema\n"
	"  init checks its own output before returning it, so a starter config that\n"
	"  would fail its first check is a fault instead. A default outside its\n"
	"  field's constraints is one cause. A required path nothing can generate is\n"
	"  the other, such as one with an index selector, a(0), or a * name. Line 0.\n"
	"V099|error|schema failed to load\n"
	"  The schema had error diagnostics of its own; they are printed above this\n"
	"  with their own line numbers. Line 0.\n";

/* Codes no load reports any more: CODE|severity it had|replacement, with the
   replacement empty when nothing took its rule. An old log can still name one,
   so explain says where it went rather than calling it unknown. */
static const char *RETIRED =
	"E010|error|E026\n"
	"E024|error|\n"
	"H003|hint|\n"
	"H004|hint|\n";

static void outln(const char *p, size_t n) { fwrite(p, 1, n, stdout); fputc('\n', stdout); }

/* A value for a one-per-line listing. `instances` promises one line per
   instance, and a value holding a line break broke that, so a caller splitting
   on newlines counted more instances than `count` reports. Only such a value
   changes: anything else goes out as it is. It goes out quoted with the
   writer's escapes, "a◉NEWLINE◉b", as `init` writes a default. A line break is
   never bare in a name either, so shcl_quote_segment gives exactly that. */
static void out_one_line(shcl_doc *d, const char *p, size_t n) {
	size_t i = 0;
	while (i < n && p[i] != '\n' && p[i] != '\r') i++;
	if (i == n) { outln(p, n); return; }
	shcl_str q = shcl_quote_segment(d, p, n);
	outln(q.p, q.n);
}

// Whole-buffer UTF-8 validation, matching Rust read_to_string rejecting bad bytes.
static int utf8_valid(const char *p, size_t n) {
	size_t i = 0;
	while (i < n) {
		unsigned char c = (unsigned char)p[i];
		if (c < 0x80) { i++; continue; }
		size_t need; uint32_t cp; uint32_t lo;
		if ((c >> 5) == 0x6) { need = 1; cp = c & 0x1F; lo = 0x80; }
		else if ((c >> 4) == 0xE) { need = 2; cp = c & 0x0F; lo = 0x800; }
		else if ((c >> 3) == 0x1E) { need = 3; cp = c & 0x07; lo = 0x10000; }
		else return 0;
		if (i + need >= n) return 0;
		for (size_t k = 1; k <= need; k++) { unsigned char cc = (unsigned char)p[i + k]; if ((cc & 0xC0) != 0x80) return 0; cp = (cp << 6) | (cc & 0x3F); }
		if (cp < lo || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
		i += need + 1;
	}
	return 1;
}

// realloc that never returns NULL: on OOM, free the old block and exit 70 (was a
// silent segfault on unchecked realloc).
static void *xrealloc(void *p, size_t n) {
	void *q = realloc(p, n);
	if (!q) { free(p); fprintf(stderr, "shcl: out of memory\n"); exit(70); }
	return q;
}

// The library reports an allocation failure by handing back NULL rather than
// ending the process, which is right for an embedder whose process is not the
// library's to end. This one owns its process and has nowhere to carry on to,
// so it takes the same exit as above.
static void *xdoc(void *p) {
	if (!p) { fprintf(stderr, "shcl: out of memory\n"); exit(70); }
	return p;
}

// Reads FILE (or stdin for "-") fully. Returns malloc'd buffer + len, or NULL on
// error (message printed to stderr). Rejects invalid UTF-8 like the reference.
// A narrow fopen reads the path in the active code page. The argv here is
// UTF-8 (see utf8_argv), so the file opens go through the library's wide
// open, which is the only way a name outside the code page reaches its file.
static FILE *open_rb(const char *file) {
#ifdef _WIN32
	return shcl_fopen_rb(file);
#else
	return fopen(file, "rb");
#endif
}

// Nothing at the path at all, as opposed to something there that will not open.
// fopen rather than stat/access so the check needs no platform header: a
// directory opens here and a protected file sets EACCES, so both stay errors.
static int path_absent(const char *file) {
	FILE *p = open_rb(file);
	if (p) { fclose(p); return 0; }
	return errno == ENOENT;
}

// The message for reading a directory is the platform's, and windows
// puts it four different ways depending on the binding, so all four
// print this one instead.
static int is_a_directory(const char *file) {
#ifdef _WIN32
	wchar_t *w = shcl_widen(file);
	if (!w) return 0;
	DWORD a = GetFileAttributesW(w);
	free(w);
	return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
#else
	struct stat st;
	return stat(file, &st) == 0 && S_ISDIR(st.st_mode);
#endif
}

// A --write FILE is a regular file or nothing yet. Asked before the read,
// since reading a FIFO takes what was written to it and the save would then
// refuse it anyway. A directory is left to the read, which names it. Windows
// has no FIFO at a path but it has device names, and a read of CON there waits
// on the console rather than returning, so the answer has to come first.
static int write_target_ok(const char *file) {
#ifndef _WIN32
	struct stat st;
	if (stat(file, &st) == 0 && !S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) {
		fprintf(stderr, "%s: not a regular file\n", file);
		return 0;
	}
#else
	if (!is_a_directory(file) && shcl_not_a_disk_file(file)) {
		fprintf(stderr, "%s: not a regular file\n", file);
		return 0;
	}
#endif
	return 1;
}

static char *read_stream(FILE *f, const char *who, size_t max, size_t *len);
static char *read_input(const char *file, size_t *len) {
	int is_stdin = strcmp(file, "-") == 0;
	const char *who = is_stdin ? "stdin" : file;
	if (!is_stdin && is_a_directory(file)) { fprintf(stderr, "%s: Is a directory\n", who); return NULL; }
	FILE *f = is_stdin ? stdin : open_rb(file);
	if (!f) { fprintf(stderr, "%s: %s\n", who, strerror(errno)); return NULL; }
	return read_stream(f, who, 0, len);
}

// The rest of read_input, once FILE is open. It closes f unless it is stdin.
// More than MAX bytes is refused, with 0 for no cap. The reads are a fixed
// 64 KiB, so one past the cap is what tells a file at it from one over it.
static char *read_stream(FILE *f, const char *who, size_t max, size_t *len) {
	char *buf = NULL; size_t cap = 0, n = 0;
	int is_stdin = f == stdin;
	char chunk[65536]; size_t r;
	errno = 0;
	while ((r = fread(chunk, 1, sizeof chunk, f)) > 0) {
		if (n + r > cap) { cap = (n + r) * 2; buf = (char *)xrealloc(buf, cap ? cap : 1); }
		memcpy(buf + n, chunk, r); n += r;
		if (max && n > max) {
			if (f != stdin) fclose(f);
			fprintf(stderr, "%s: too large for a schema (over 16 MiB)\n", who);
			free(buf); return NULL;
		}
	}
	int ferr = ferror(f);
	// A stdin that is not attached at all reads as an empty document, the way
	// every binding treats it. POSIX says EBADF; windows reports a handle a
	// shell closed as an invalid handle or an invalid function, which the C
	// runtime hands back as EINVAL.
	if (ferr && is_stdin && (errno == EBADF || errno == EINVAL)) ferr = 0;
	if (f != stdin) fclose(f);
	if (ferr) { fprintf(stderr, "%s: %s\n", who, strerror(errno)); free(buf); return NULL; }
	if (!buf) { buf = (char *)xrealloc(NULL, 1); }
	if (!utf8_valid(buf, n)) { fprintf(stderr, "%s: stream did not contain valid UTF-8\n", who); free(buf); return NULL; }
	*len = n; return buf;
}

// A string read at the path that comes back unquoted and in brackets. A read
// of an array is never quoted, though shcl_quoted gives a one-element array
// its element's flag; an array's element never reads as the array's own
// bracket text, which is how one is told from a quoted "[x]".
static int reads_bracketed(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_str r = shcl_read_string(d, path, plen);
	if (r.status != SHCL_GOOD || !r.value.n || r.value.p[0] != '[') return 0;
	if (!shcl_quoted(d, path, plen)) return 1;
	shcl_read_str_arr sa = shcl_read_string_array(d, path, plen);
	return sa.status == SHCL_GOOD && (sa.n != 1 || sa.values[0].n != r.value.n || memcmp(sa.values[0].p, r.value.p, r.value.n) != 0);
}

// A field with lines under it takes one plain value or none (E028), so an
// array there, or a field made under an array, is refused for where it goes.
// NULL when neither is why.
static const char *array_refusal(shcl_doc *d, const char *path, size_t plen, int array) {
	shcl_str *kids;
	if (array && shcl_children(d, path, plen, &kids)) return "a field with lines under it takes one plain value or none";
	ShclArena a; memset(&a, 0, sizeof a);
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	ShclStr p; p.p = path; p.n = plen;
	tokenize(&a, p, '=', 1, SHCL_RULES_CURRENT, &tok);
	const char *why = NULL;
	for (size_t k = 1; k < tok.nseg && !why; k++) {
		size_t quoted = tok.segments[k].name.quote != SHCL_QUOTE_NONE;
		size_t up = tok.segments[k].name.start - quoted;
		while (up > 0 && path[up - 1] == '.') up--;
		// Brackets on a value that reads unquoted are an array's.
		if (reads_bracketed(d, path, up)) why = "an array takes no lines under it";
	}
	arena_free(&a);
	return why;
}

// Value text that starts an array, past any leading whitespace.
static int array_text(const char *v, size_t n) {
	size_t i = 0;
	while (i < n && v[i] && strchr(" \t\r\n\v\f", v[i])) i++;
	return i < n && v[i] == '[';
}

// The per-binding wording behind a setter's bare 0.
// Why a write was refused. When the path itself is fine what failed is the
// text, and only the caller knows which half of the op that was, so it names
// it: a setter refused for its value used to report the sentence written for
// shcl_set_literal whatever the op.
static const char *bad_path(const char *path, size_t plen); // beside split_set
static const char *describe_refusal(shcl_doc *d, const char *path, size_t plen, int array, const char *unwritable) {
	switch (shcl_write_reason_(d, path, plen)) {
	case SHCL_W_WRITABLE: { const char *why = array_refusal(d, path, plen, array); return why ? why : unwritable; }
	case SHCL_W_BAD_PATH: return bad_path(path, plen);
	case SHCL_W_VALUE_IN_PATH: return "a path with a value part cannot be written";
	case SHCL_W_WILDCARD: return "a wildcard path cannot be written";
	case SHCL_W_NO_SUCH_INDEX: return "no instance at that index";
	case SHCL_W_TOO_DEEP: return "deeper than the nesting cap";
	}
	return "not a usable path";
}

// One diagnostic line in the shape every command uses: `line N: Severity:
// CODE message` (`schema line` for the V090-V093 schema-fault codes).
static void say_diag_from(const char *file, size_t line, shcl_severity sev, const char *code, shcl_str msg);
static void say_diag(size_t line, shcl_severity sev, const char *code, shcl_str msg) {
	say_diag_from("", line, sev, code, msg);
}

// The same, labeled with the file the diagnostic came from. Under --layer
// several files are loaded and their line numbers share one space on the
// screen, so two layers with a bad line 2 printed the same thing twice with
// nothing to tell them apart.
static void say_diag_from(const char *file, size_t line, shcl_severity sev, const char *code, shcl_str msg) {
	/* V090-V095 have a schema line; V096 and V097 are about generation as a
	   whole and have line 0, so "schema line 0" named a line space they are not
	   in. V099 stands for a schema that did not load and is line 0 too. */
	const char *space = (!strncmp(code, "V09", 3) && strcmp(code, "V096") && strcmp(code, "V097")
		&& strcmp(code, "V099")) ? "schema line" : "line";
	if (*file) fprintf(stderr, "%s ", file);
	fprintf(stderr, "%s %zu: %s: %s ", space, line, sev == SHCL_SEV_ERROR ? "Error" : "Hint", code);
	fwrite(msg.p, 1, msg.n, stderr); fputc('\n', stderr);
}
// The load's diagnostics, one line each.
static void say_diagnostics_from(const char *file, const shcl_doc *d) {
	size_t n = shcl_diag_count(d);
	for (size_t i = 0; i < n; i++)
		say_diag_from(file, shcl_diag_line(d, i), shcl_diag_severity(d, i), shcl_diag_code(d, i), shcl_diag_message(d, i));
}

// Prints diagnostics to stderr and returns 6 on strict load failure, else 0.
static int strict_gate_from(const char *file, const shcl_doc *d);
static int strict_gate(const shcl_doc *d) { return strict_gate_from("", d); }

// The same, labeled with the file the document came from, so a strict failure
// in one layer of a fold says which layer.
static int strict_gate_from(const char *file, const shcl_doc *d) {
	if (!shcl_strict_failed(d)) return 0;
	say_diagnostics_from(file, d);
	size_t n = shcl_diag_count(d), nerr = 0;
	for (size_t i = 0; i < n; i++) if (shcl_diag_severity(d, i) == SHCL_SEV_ERROR) nerr++;
	fprintf(stderr, "strict load failed: %zu error diagnostic(s)\n", nerr);
	return 6;
}

// Holds a merged doc and the input buffers its nodes still reference (the base
// layer's node strings are not dup'd off its text). The over-layers are kept
// too: a merge does not pass diagnostics on, so their docs are the only
// place the layers' own diagnostics live. Free everything with layered_free.
typedef struct { shcl_doc *doc; shcl_doc **overs; int novers; char **texts; int ntexts;
	const char **names; int nnames; size_t base_len; } LayeredDoc;

static void layered_push_text(LayeredDoc *L, char *t) {
	L->texts = (char **)xrealloc(L->texts, ((size_t)L->ntexts + 1) * sizeof *L->texts);
	L->texts[L->ntexts++] = t;
}

// Merge dd under/over the doc built so far, keeping it alive for its diagnostics.
static void layered_push_doc(LayeredDoc *L, shcl_doc *dd) {
	if (!L->doc) { L->doc = dd; return; }
	shcl_merge(L->doc, dd);
	L->overs = (shcl_doc **)xrealloc(L->overs, ((size_t)L->novers + 1) * sizeof *L->overs);
	L->overs[L->novers++] = dd;
}

static void layered_free(LayeredDoc *L) {
	free((void *)L->names); L->names = NULL; L->nnames = 0;
	if (L->doc) shcl_free(L->doc);
	for (int i = 0; i < L->novers; i++) shcl_free(L->overs[i]);
	free(L->overs);
	for (int i = 0; i < L->ntexts; i++) free(L->texts[i]);
	free(L->texts);
	L->doc = NULL; L->overs = NULL; L->novers = 0; L->texts = NULL; L->ntexts = 0;
}

// Every layer's diagnostics, lowest first. Reading them off the merged doc
// alone would drop the ones for FILE itself, which is the one the caller named.
static void say_layered_diagnostics(const LayeredDoc *L) {
	// Each labeled with its own file when there is more than one: the line
	// numbers share a space on the screen otherwise.
	int lbl = L->nnames > 1;
	say_diagnostics_from(lbl ? L->names[0] : "", L->doc);
	for (int i = 0; i < L->novers; i++)
		say_diagnostics_from(lbl && i + 1 < L->nnames ? L->names[i + 1] : "", L->overs[i]);
}

// Load `file` with o's lower-priority --layer files underneath it and its --set
// overrides on top - the layered-load fold. Every layer parses at the requested
// strictness; a strict-load failure on any aborts (exit 6). Returns 0 and fills
// *out on success, else an exit code (nothing to free on failure).
// A path no document can hold, which a remove would take as a miss and exit
// 0: one the scanner rejects, or one with a value part. A missing path or a
// wildcard is still fine.
static int unusable_path(shcl_doc *d, const char *path, size_t plen) {
	shcl_write_reason r = shcl_write_reason_(d, path, plen);
	return r == SHCL_W_BAD_PATH || r == SHCL_W_VALUE_IN_PATH;
}

// A path with a selector in brackets, the old spelling (E029). A 2.x habit
// still types it, so a refusal names it.
static int bracket_path(const char *path, size_t plen) {
	ShclArena a; memset(&a, 0, sizeof a);
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	ShclStr ps; ps.p = path; ps.n = plen;
	tokenize(&a, ps, ':', 1, SHCL_RULES_CURRENT, &tok);
	int has = tok.has_bracket_selector;
	arena_free(&a);
	return has;
}

#define BRACKET_PATH "a selector is written in parens now, name(value)"

// What a path the scanner refused is called.
static const char *bad_path(const char *path, size_t plen) {
	return bracket_path(path, plen) ? BRACKET_PATH : "not a usable path";
}

// A read's PATH that cannot parse is a usage error, the same as --remove's.
// The library reads it as NotFound, so `get --default` would print the
// default at exit 0 and a 2.x script would never hear about it.
static int refuse_read_path(const char *path, size_t plen) {
	shcl_doc *empty = shcl_parse("", 0);
	int unusable = unusable_path(empty, path, plen);
	shcl_free(empty);
	if (!unusable) return 0;
	fprintf(stderr, "bad PATH (%s): %s (see --help)\n", bad_path(path, plen), path);
	return 1;
}

// PATH=VALUE at the first `=` outside quotes and parens, so a selector
// holding one (`x(a=b).c=1`) still addresses its instance. The tokenizer reads
// the path half with `=` as its separator, so quotes and parens mean here
// exactly what they mean in a file; an argument whose path half is not a path
// at all has no `=` to split at. Returns 0 then.
static int split_set(const char *arg, size_t *plen, const char **val) {
	ShclArena a; memset(&a, 0, sizeof a);
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize(&a, s_lit(arg), '=', 1, SHCL_RULES_CURRENT, &tok);
	int ok = tok.has_sep;
	*plen = ok ? tok.sep : 0; *val = ok ? arg + tok.sep + 1 : arg;
	arena_free(&a);
	return ok;
}

// Apply one --set/--set-literal override. Both spellings share a list so they
// apply in the order given, which decides the winner when two target one path.
static int set_apply(shcl_doc *d, const SetOpt *s) {
	size_t vlen = strlen(s->value);
	int ok;
	if (!strcmp(s->opt, "--remove")) {
		// Removing nothing is not a failure, the same as the ops script's
		// `remove`: the point of the option is the path's absence after.
		shcl_remove(d, s->path, s->plen);
		return 1;
	}
	if (!strcmp(s->opt, "--set-literal")) ok = shcl_set_literal(d, s->path, s->plen, s->value, vlen);
	else if (!strcmp(s->opt, "--set-default")) ok = shcl_set_string_default(d, s->path, s->plen, s->value, vlen);
	else if (!strcmp(s->opt, "--set-literal-default")) ok = shcl_set_literal_default(d, s->path, s->plen, s->value, vlen);
	else ok = shcl_set_string(d, s->path, s->plen, s->value, vlen);
	if (!ok) fprintf(stderr, "%s: cannot write %.*s: %s\n", s->opt, (int)s->plen, s->path, describe_refusal(d, s->path, s->plen, strcmp(s->opt, "--set") && array_text(s->value, vlen), "the value text is not one value"));
	return ok;
}

static int load_layered_from(Opts *o, const char *file, char *given, size_t given_len, int keep, LayeredDoc *out);
static int load_layered(Opts *o, const char *file, LayeredDoc *out) {
	return load_layered_from(o, file, NULL, 0, 0, out);
}

// The same fold with FILE's text given rather than read (a malloc'd buffer the
// fold then owns), which is how `set` creates a file or takes an empty
// document. FILE's text is the last of out->texts, base_len bytes. `set` kept
// its own copy of the fold, and twice a fix to this one missed it.
static int load_layered_from(Opts *o, const char *file, char *given, size_t given_len, int keep, LayeredDoc *out) {
	out->doc = NULL; out->overs = NULL; out->novers = 0; out->texts = NULL; out->ntexts = 0;
	out->names = (const char **)xrealloc(NULL, (size_t)(o->nlayers + 1) * sizeof *out->names);
	out->nnames = 0; out->base_len = 0;
	// Lowest -> highest file layer: the --layer files in order, then FILE.
	// Every file is read before any is loaded, as in the reference, so a
	// missing layer is exit 8 even when one before it fails a strict load.
	size_t *lens = (size_t *)xrealloc(NULL, (size_t)(o->nlayers + 1) * sizeof *lens);
	for (int i = 0; i <= o->nlayers; i++) {
		const char *fname = i < o->nlayers ? o->layers[i] : file;
		out->names[out->nnames++] = fname;
		char *t;
		if (i == o->nlayers && given) { t = given; lens[i] = given_len; given = NULL; }
		else t = read_input(fname, &lens[i]);
		if (!t) { free(given); free(lens); layered_free(out); return EXIT_IO; }
		layered_push_text(out, t);
		// Here, not after the loop: gcc -O3 can't rule out a loop that never ran.
		if (i == o->nlayers) out->base_len = lens[i];
	}
	for (int i = 0; i <= o->nlayers; i++) {
		const char *t = out->texts[i];
		// Only a document with no layers under it keeps its lines: a merge drops them.
		shcl_doc *dd = xdoc(keep && o->nlayers == 0 ? shcl_parse_keep_lines(t, lens[i], o->strictness) : shcl_parse_with(t, lens[i], o->strictness));
		int g = strict_gate_from(o->nlayers ? out->names[i] : "", dd);
		if (g) { shcl_free(dd); free(lens); layered_free(out); return g; }
		layered_push_doc(out, dd);
	}
	free(lens);
	// The load's diagnostics belong to the load, so they go out before any edit
	// runs: a refused --set used to return with nothing said about them.
	say_layered_diagnostics(out);
	for (int i = 0; i < o->nsets; i++) {
		if (!set_apply(out->doc, &o->sets[i])) { layered_free(out); return 1; }
	}
	return 0;
}

// The source text, quoted for a message: one line whatever it holds, with
// the same escapes in every binding.
static char *quoted(const char *p, size_t n) {
	size_t cap = n * 8 + 3;
	char *out = (char *)xrealloc(NULL, cap);
	size_t w = 0;
	out[w++] = '"';
	for (size_t i = 0; i < n; i++) {
		unsigned char c = (unsigned char)p[i];
		if (c == '"') { out[w++] = '\\'; out[w++] = '"'; }
		else if (c == '\\') { out[w++] = '\\'; out[w++] = '\\'; }
		else if (c == '\n') { out[w++] = '\\'; out[w++] = 'n'; }
		else if (c == '\r') { out[w++] = '\\'; out[w++] = 'r'; }
		else if (c == '\t') { out[w++] = '\\'; out[w++] = 't'; }
		else if (c < 0x20 || c == 0x7f) w += (size_t)snprintf(out + w, cap - w, "\\u{%x}", c);
		else out[w++] = (char)c;
	}
	out[w++] = '"';
	out[w] = '\0';
	return out;
}

static int do_get(Opts *o) {
	if (o->nargs != 2) { fprintf(stderr, "usage: shcl get [type] [options] FILE PATH (see --help)\n"); return 1; }
	const char *file = o->args[0], *path = o->args[1]; size_t plen = strlen(path);
	if (refuse_read_path(path, plen)) return 1;
	LayeredDoc L; int gate = load_layered(o, file, &L);
	if (gate) return gate;
	shcl_doc *d = L.doc;

	shcl_status status = SHCL_GOOD;
	const shcl_status *slotSts = NULL; size_t nSlots = 0;
	char fbuf[SHCL_FLOAT_BUF];
	// Buffer output lines so the on-bad modes can suppress them uniformly. Each
	// line either borrows arena/const memory (owned=0) or is formatted into own[].
	// Owned entries keep p NULL: own[] lives inside the growable array, so a stored
	// self-pointer goes stale on realloc - LINEPTR picks the live one at print time.
	struct { const char *p; size_t n; char own[SHCL_FLOAT_BUF]; int owned; } *lines = NULL;
	size_t nlines = 0, clines = 0;
	#define LINEPTR(I) (lines[I].owned ? lines[I].own : lines[I].p)
	#define PUSHLINE_BYTES(P, N) do { if (nlines == clines) { clines = clines ? clines * 2 : 8; lines = xrealloc(lines, clines * sizeof *lines); } lines[nlines].p = (P); lines[nlines].n = (N); lines[nlines].owned = 0; nlines++; } while (0)
	#define PUSHLINE_FMT(FMT, ...) do { if (nlines == clines) { clines = clines ? clines * 2 : 8; lines = xrealloc(lines, clines * sizeof *lines); } int k = snprintf(lines[nlines].own, SHCL_FLOAT_BUF, FMT, __VA_ARGS__); lines[nlines].p = NULL; lines[nlines].n = (size_t)k; lines[nlines].owned = 1; nlines++; } while (0)
	#define PUSHLINE_BUF(B, N) do { if (nlines == clines) { clines = clines ? clines * 2 : 8; lines = xrealloc(lines, clines * sizeof *lines); } memcpy(lines[nlines].own, (B), (N)); lines[nlines].p = NULL; lines[nlines].n = (N); lines[nlines].owned = 1; nlines++; } while (0)

	if (o->array) {
		if (!strcmp(o->kind, "int")) { shcl_read_i64_arr r = shcl_read_int_array(d, path, plen); status = r.status; slotSts = r.statuses; nSlots = r.n; for (size_t i = 0; i < r.n; i++) PUSHLINE_FMT("%" PRId64, r.values[i]); }
		else if (!strcmp(o->kind, "float")) { shcl_read_f64_arr r = shcl_read_float_array(d, path, plen); status = r.status; slotSts = r.statuses; nSlots = r.n; for (size_t i = 0; i < r.n; i++) { size_t k = shcl_format_float(r.values[i], fbuf); PUSHLINE_BUF(fbuf, k); } }
		else if (!strcmp(o->kind, "bool")) { shcl_read_bool_arr r = shcl_read_bool_array(d, path, plen); status = r.status; slotSts = r.statuses; nSlots = r.n; for (size_t i = 0; i < r.n; i++) PUSHLINE_BYTES(r.values[i] ? "true" : "false", r.values[i] ? 4 : 5); }
		else if (!strcmp(o->kind, "datetime")) { shcl_read_dt_arr r = shcl_read_datetime_array(d, path, plen); status = r.status; slotSts = r.statuses; nSlots = r.n; for (size_t i = 0; i < r.n; i++) { size_t k = shcl_datetime_str(&r.values[i], fbuf); PUSHLINE_BUF(fbuf, k); } }
		else if (!strcmp(o->kind, "raw") || !strcmp(o->kind, "rawinfo") || !strcmp(o->kind, "duration") || !strcmp(o->kind, "size")) { fprintf(stderr, "--%s has no --array form (see --help)\n", o->kind); free(lines); layered_free(&L); return 1; }
		else { shcl_read_str_arr r = shcl_read_string_array(d, path, plen); status = r.status; slotSts = r.statuses; nSlots = r.n; for (size_t i = 0; i < r.n; i++) PUSHLINE_BYTES(r.values[i].p, r.values[i].n); }
	} else {
		if (!strcmp(o->kind, "int")) { shcl_read_i64 r = shcl_read_int(d, path, plen); status = r.status; PUSHLINE_FMT("%" PRId64, r.value); }
		else if (!strcmp(o->kind, "float")) { shcl_read_f64 r = shcl_read_float(d, path, plen); status = r.status; size_t k = shcl_format_float(r.value, fbuf); PUSHLINE_BUF(fbuf, k); }
		else if (!strcmp(o->kind, "bool")) { shcl_read_bool r = shcl_read_bool_(d, path, plen); status = r.status; PUSHLINE_BYTES(r.value ? "true" : "false", r.value ? 4 : 5); }
		else if (!strcmp(o->kind, "datetime")) { shcl_read_dt r = shcl_read_datetime(d, path, plen); status = r.status; size_t k = shcl_datetime_str(&r.value, fbuf); PUSHLINE_BUF(fbuf, k); }
		else if (!strcmp(o->kind, "raw")) { shcl_read_str r = shcl_read_raw(d, path, plen); status = r.status; PUSHLINE_BYTES(r.value.p, r.value.n); }
		else if (!strcmp(o->kind, "rawinfo")) { shcl_read_str r = shcl_read_raw_info(d, path, plen); status = r.status; PUSHLINE_BYTES(r.value.p, r.value.n); }
		else if (!strcmp(o->kind, "duration")) {
			shcl_duration_unit u = o->unit ? shcl_duration_unit_of(o->unit, strlen(o->unit)) : SHCL_DURATION_NONE;
			shcl_read_i64 r = shcl_read_duration(d, path, plen, u); status = r.status; PUSHLINE_FMT("%" PRId64, r.value);
		}
		else if (!strcmp(o->kind, "size")) {
			shcl_size_unit u = o->unit ? shcl_size_unit_of(o->unit, strlen(o->unit)) : SHCL_SIZE_NONE;
			shcl_read_i64 r = shcl_read_size(d, path, plen, u, o->decimal); status = r.status; PUSHLINE_FMT("%" PRId64, r.value);
		}
		else { shcl_read_str r = shcl_read_string(d, path, plen); status = r.status; PUSHLINE_BYTES(r.value.p, r.value.n); }
	}

	// Per-line slot status: falls back to the aggregate for scalar reads.
	#define SLOT_AT(I) (slotSts && (I) < nSlots ? slotSts[I] : status)
	// An array or a slot listing is one line per element, so a value holding a
	// line break takes its escaped spelling there. A plain scalar read prints
	// the value as it is, since the whole output is that one value.
	#define EMITLINE(I, P, N) do { \
		if (o->slots) printf("%s\t", shcl_status_name(SLOT_AT(I))); \
		if (o->slots || o->array) out_one_line(d, (P), (N)); else outln((P), (N)); \
	} while (0)
	// Why the read failed is worth saying even when the exit code already
	// shows it: at the default mode the user otherwise gets an empty line, a
	// nonzero code, and nothing to go on. Stdout is untouched - this only ever
	// goes to stderr. Two silences are deliberate: default mode, because a
	// caller who supplied a fallback has already said the miss is expected, and
	// Empty outside error mode, because an empty value is a legitimate answer
	// here rather than a failure - the same reason shcl_status_ok counts it so.
	if (status != SHCL_GOOD && strcmp(o->on_bad, "default") != 0
	    && (status != SHCL_EMPTY || !strcmp(o->on_bad, "error"))) {
		char tbuf[32];
		snprintf(tbuf, sizeof tbuf, o->array ? "%s array" : "%s", o->kind);
		if (status == SHCL_BAD_TYPE) {
			// The reason quotes the text only when the path resolved to a node;
			// read_string answers Good or Empty exactly then.
			shcl_read_str rs = shcl_read_string(d, path, plen);
			if (rs.status == SHCL_GOOD || rs.status == SHCL_EMPTY) {
				char *q = quoted(rs.value.p, rs.value.n);
				fprintf(stderr, "cannot read %s as %s: value %s is not a valid %s (in %s)\n", path, tbuf, q, tbuf, file);
				free(q);
			} else
				fprintf(stderr, "cannot read %s as %s: value is not a valid %s (in %s)\n", path, tbuf, tbuf, file);
		} else if (status == SHCL_NOT_FOUND) {
			fprintf(stderr, "cannot read %s as %s: no value at that path (in %s)\n", path, tbuf, file);
		} else if (status == SHCL_EMPTY) {
			fprintf(stderr, "cannot read %s as %s: the value is empty (in %s)\n", path, tbuf, file);
		} else {
			fprintf(stderr, "cannot read %s as %s: the path matches multiple instances (in %s)\n", path, tbuf, file);
		}
	}
	int rc;
	int flag_ok = (status == SHCL_GOOD) || (status == SHCL_EMPTY && !strcmp(o->on_bad, "flag"));
	if (flag_ok) {
		for (size_t i = 0; i < nlines; i++) EMITLINE(i, LINEPTR(i), lines[i].n);
		rc = shcl_status_code(status);
	} else if (!strcmp(o->on_bad, "default")) {
		const char *dv = o->deflt ? o->deflt : "";
		if (slotSts && nSlots > 0) {
			// Array read: the default substitutes per bad slot; alignment holds.
			for (size_t i = 0; i < nlines; i++) {
				if (SLOT_AT(i) == SHCL_GOOD) EMITLINE(i, LINEPTR(i), lines[i].n);
				else EMITLINE(i, dv, strlen(dv));
			}
		} else {
			if (o->slots) { printf("%s\t", shcl_status_name(status)); out_one_line(d, dv, strlen(dv)); }
			else if (o->array) out_one_line(d, dv, strlen(dv));
			else outln(dv, strlen(dv));
		}
		rc = 0;
	} else if (!strcmp(o->on_bad, "error")) {
		// The message already went to stderr above; error mode differs only in
		// printing nothing on stdout.
		rc = shcl_status_code(status);
	} else {
		for (size_t i = 0; i < nlines; i++) EMITLINE(i, LINEPTR(i), lines[i].n);
		rc = shcl_status_code(status);
	}
	free(lines); layered_free(&L); return rc;
}

// The in-place half of fmt/set. Overwriting the source is the one place a
// recovered load turns destructive, so the diagnostics go out even though the
// command succeeded, and the save runs through the library's own gate rather
// than a second copy of the rule - the CLI and a consumer program cannot then
// disagree about which rewrites are safe.
// Whether the directory holding `file` can take a new entry - the probe
// behind the temp-create wording on a failed save.
// Can the target's directory take a temp file? Asked by creating one, because
// that is what the library's write does: _waccess reports every existing
// directory writable on windows, so an ACL-protected one got the bare errno
// where the other three name the phase. Only ever called on the failure path,
// and the probe is removed immediately.
static int dir_takes_a_temp(const char *file) {
	const char *slash = strrchr(file, '/');
#ifdef _WIN32
	const char *bs = strrchr(file, '\\');
	if (bs && (!slash || bs > slash)) slash = bs;
#endif
	char probe[4096];
	if (!slash) snprintf(probe, sizeof probe, ".shcl-probe%ld", (long)getpid());
	else if (slash == file) snprintf(probe, sizeof probe, "/.shcl-probe%ld", (long)getpid());
	else snprintf(probe, sizeof probe, "%.*s/.shcl-probe%ld", (int)(slash - file), file, (long)getpid());
#ifdef _WIN32
	wchar_t *w = shcl_widen(probe);
	int fd = w ? _wopen(w, _O_WRONLY | _O_CREAT | _O_EXCL | _O_BINARY, _S_IREAD | _S_IWRITE) : -1;
	if (fd >= 0) { _close(fd); _wunlink(w); }
	free(w);
	return fd >= 0;
#else
	int fd = open(probe, O_WRONLY | O_CREAT | O_EXCL, 0600);
	if (fd >= 0) { close(fd); unlink(probe); }
	return fd >= 0;
#endif
}

// FILE still holds the bytes the load read. `set` waits on stdin between the
// load and the save, and an edit made in that wait was reverted at exit 0. A
// gap is left between this read and the publish, the width of one save.
static int holds_bytes(const char *file, const char *before, size_t n) {
	FILE *f = open_rb(file);
	int same = f != NULL;
	if (f) {
		char buf[65536]; size_t got, at = 0;
		while (same && (got = fread(buf, 1, sizeof buf, f)) > 0) {
			same = at + got <= n && !memcmp(buf, before + at, got);
			at += got;
		}
		same = same && !ferror(f) && at == n;
		fclose(f);
	}
	return same;
}

static int unchanged_since_read(const char *file, const char *before, size_t n) {
	int same = holds_bytes(file, before, n);
	if (!same) fprintf(stderr, "%s: changed since it was read; nothing written\n", file);
	return same;
}

// read is the bytes FILE held when the command read it, and NULL when this
// write is creating FILE.
static int write_back(shcl_doc *d, const char *file, Opts *o, const char *read, size_t read_len, int keep) {
	if (read && !unchanged_since_read(file, read, read_len)) return EXIT_IO;
	// Nothing to write: what the save would publish is already on disk. A
	// rewrite would give the file a new inode and mtime for nothing, so an
	// idempotent --set-default in a provisioning script reported a change on
	// every run, watchers fired, other hard links broke, and a canonical file
	// in a read-only directory failed. The refusal comes first: a load that
	// dropped content refuses the write whatever the bytes say, unless the
	// lines were kept, which writes the dropped lines back as they were.
	int kept = 0;
	shcl_str c = keep ? shcl_to_text_keep_lines(d, &kept) : shcl_to_canonical(d);
	if (read && (o->lossy || kept || shcl_lost_count(d) == 0)
		&& c.n == read_len && (c.n == 0 || memcmp(c.p, read, c.n) == 0)) return 0;
	// The text is already built, so the line-keeping save writes it rather
	// than building it again, with the same refusal shcl_save_file_keep_lines
	// makes (20260926 idea 3).
	shcl_save_result r;
	if (o->lossy && keep) r = shcl_write_file_atomic(file, c.p, c.n) ? SHCL_SAVE_OK : SHCL_SAVE_FAILED;
	else if (o->lossy) r = shcl_save_file_lossy(d, file);
	else if (keep && !kept && shcl_lost_count(d) > 0) r = SHCL_SAVE_REFUSED;
	else if (keep) r = shcl_write_file_atomic(file, c.p, c.n) ? SHCL_SAVE_OK : SHCL_SAVE_FAILED;
	else r = shcl_save_file(d, file);
	if (r == SHCL_SAVE_OK) {
		// A created file is the one write with nothing to compare against
		// afterwards, and a typo in the name used to end at exit 0 with an
		// empty stderr and a new file nobody asked for.
		if (!read) fprintf(stderr, "%s: created\n", file);
		// A save meant to keep the lines rewrote the whole file, and that is
		// worth a line (20260926 idea 2).
		if (keep && !kept) fprintf(stderr, "%s: rewritten in the canonical form; the lines could not be kept as they were\n", file);
		return 0;
	}
	// The rule stays in the library; only the wording is the CLI's, because the
	// override a user has here is a flag, not a function.
	if (r == SHCL_SAVE_REFUSED) {
		fprintf(stderr, "%s: refusing to rewrite: this write would delete %zu line(s)/value(s) from the file (--lossy overrides)\n", file, shcl_lost_count(d));
		return 7;
	}
	// The library reports a failed save through errno alone; the phase worth
	// naming is the temp-file create, which is what failed when the target's
	// directory cannot take one.
	int e = errno;
	if (!dir_takes_a_temp(file)) fprintf(stderr, "%s: cannot create temporary file: %s\n", file, strerror(e));
	else fprintf(stderr, "%s: %s\n", file, strerror(e));
	return EXIT_IO;
}

static int do_fmt(Opts *o) {
	if (o->nargs != 1) { fprintf(stderr, "usage: shcl fmt [--write|-w] [options] FILE (see --help)\n"); return 1; }
	const char *file = o->args[0];
	if (o->write && strcmp(file, "-") == 0) {
		fprintf(stderr, "fmt --write cannot rewrite stdin; drop --write to print, or pass a FILE\n");
		return 1;
	}
	if (o->write && !write_target_ok(file)) return EXIT_IO;
	LayeredDoc L; int gate = load_layered(o, file, &L);
	if (gate) return gate;
	int rc;
	// --check is migrate --check's sibling, and the spelling every other
	// formatter has: print nothing, and say by the exit code whether a rewrite
	// would change the file. It was `shcl fmt f | cmp -s - f` before.
	if (o->check) {
		// The save gate --write goes through is asked first, so 6 never
		// promises a rewrite the same command would refuse to make.
		if (!o->lossy && shcl_lost_count(L.doc) != 0) {
			fprintf(stderr, "%s: fmt --write would refuse: it would delete %zu line(s)/value(s) from the file (--lossy overrides)\n", file, shcl_lost_count(L.doc));
			rc = 7;
		} else {
			shcl_str c = shcl_to_canonical(L.doc);
			const char *was = L.texts[L.ntexts - 1];
			if (c.n == L.base_len && (c.n == 0 || memcmp(c.p, was, c.n) == 0)) rc = 0;
			else {
				fprintf(stderr, "%s: not canonical; fmt --write would rewrite it\n", file);
				rc = 6;
			}
		}
	} else if (o->write) {
		rc = write_back(L.doc, file, o, L.texts[L.ntexts - 1], L.base_len, 0);
	} else {
		shcl_str c = shcl_to_canonical(L.doc);
		fwrite(c.p, 1, c.n, stdout);
		rc = 0;
	}
	layered_free(&L); return rc;
}

// How many lines migrate writes differently, each named on stderr when a file
// name is given. The rewrite goes line for line and only appends, so line N of
// the input is line N of the output. It never touches a line's carriage
// returns, but the stamp ends an unterminated last line the way most lines
// end, which can put a CR after it, so those are left out of the compare.
static size_t rewritten_lines(const char *file, const char *before, size_t blen, const char *after, size_t alen) {
	size_t count = 0, n = 0, bi = 0, ai = 0;
	if (blen && before[blen - 1] == '\n') blen--;
	else if (!blen) return 0;
	for (;;) {
		n++;
		const char *be = memchr(before + bi, '\n', blen - bi);
		size_t bl = be ? (size_t)(be - (before + bi)) : blen - bi;
		const char *ae = ai <= alen ? memchr(after + ai, '\n', alen - ai) : NULL;
		size_t al = ae ? (size_t)(ae - (after + ai)) : alen - ai;
		size_t bt = bl, at = al;
		while (bt && before[bi + bt - 1] == '\r') bt--;
		while (at && after[ai + at - 1] == '\r') at--;
		if (bt != at || memcmp(before + bi, after + ai, bt) != 0) {
			count++;
			if (file) fprintf(stderr, "%s:%zu: migrate would rewrite this line\n", file, n);
		}
		if (!be || !ae) break;
		bi += bl + 1; ai += al + 1;
	}
	return count;
}

// Where the file name starts in a path: after the last separator, or on
// windows after a drive with no separator (C:cfg.shcl). A backslash is a
// separator only on windows.
static size_t name_start(const char *file) {
	const char *sep = strrchr(file, '/');
#ifdef _WIN32
	const char *bs = strrchr(file, '\\');
	if (bs && (!sep || bs > sep)) sep = bs;
	unsigned char c = (unsigned char)file[0];
	if (!sep && (c | 0x20) >= 'a' && (c | 0x20) <= 'z' && file[1] == ':') return 2;
#endif
	return sep ? (size_t)(sep - file) + 1 : 0;
}

// A 2.x file rewritten for the current rules. The rewrite is text to text;
// the load after it is for the diagnostics and the save gate, the same gate
// `fmt --write` goes through.
// The save gate migrate --write goes through, asked without writing: 7 with
// the reason on stderr when the write would refuse, else 0.
static int migrate_would_refuse(const char *file, const shcl_doc *d, size_t misplaced, const Opts *o) {
	if (o->lossy) return 0;
	if (shcl_lost_count(d) != 0) {
		fprintf(stderr, "%s: migrate --write would refuse: the migrated text drops %zu line(s)/value(s) on load (--lossy overrides)\n", file, shcl_lost_count(d));
		return 7;
	}
	if (misplaced != 0) {
		fprintf(stderr, "%s: migrate --write would refuse: the migrated text leaves %zu line(s) unread at an indent no open level matches (--lossy overrides)\n", file, misplaced);
		return 7;
	}
	return 0;
}

static int do_migrate(const Opts *o) {
	if (o->nargs != 1) { fprintf(stderr, "usage: shcl migrate [options] FILE (see --help)\n"); return 1; }
	const char *file = o->args[0];
	if (o->write && strcmp(file, "-") == 0) {
		fprintf(stderr, "migrate --write cannot rewrite stdin; drop --write to print, or pass a FILE\n");
		return 1;
	}
	if (o->write && !write_target_ok(file)) return EXIT_IO;
	size_t len; char *text = read_input(file, &len);
	if (!text) return EXIT_IO;
	shcl_migration m = shcl_migrate(text, len, o->from_2x);
	shcl_doc *d = xdoc(shcl_parse_with(m.text, m.len, o->strictness));
	int rc = strict_gate(d);
	if (rc) { shcl_free(d); free(m.text); free(text); return rc; }
	say_diagnostics_from("", d);
	// The file says it was written for these rules, so there is nothing to do
	// and nothing to write. Saying so beats printing the input back silently.
	if (m.current) {
		fprintf(stderr, "%s: nothing to migrate: the file already names its format\n", file);
		if (!o->write && !o->check) fwrite(m.text, 1, m.len, stdout);
		shcl_free(d); free(m.text); free(text);
		return 0;
	}
	if (m.ambiguous) {
		fprintf(stderr, "%s: %zu value(s) read one way under 2.x and another under these rules, and the file does not say which it was written for; left as written (--from-2x rewrites them)\n", file, m.ambiguous);
		rc = 7;
	}
	if (m.lost) {
		fprintf(stderr, "%s: %zu line(s) bound a value under 2.x that nothing binds now: bracket text after the colon, a selector holding a comma, or a comma list with lines under it, which have no spelling here (--lossy overrides)\n", file, m.lost);
		if (!o->lossy) rc = 7;
	}
	// With nothing ambiguous, the stamp is left off only when a raw block runs
	// to the end of the file, where the line would be the block's content.
	// Unstamped, the next run could not tell the file was migrated.
	if (!m.ambiguous && shcl_format_version(m.text, m.len) < SHCL_FORMAT_MAJOR) {
		fprintf(stderr, "%s: a raw block never closes, so there is nowhere to put the Format line; close it and run migrate again\n", file);
		rc = 7;
	}
	size_t rewritten = rewritten_lines(o->check ? file : NULL, text, len, m.text, m.len);
	// A save keeps a line at an indent no level matches, but 2.x placed some
	// such lines by a looser rule and read them, so a migration that leaves one
	// has not brought the file across. With nothing lost, every one of them is
	// kept.
	size_t misplaced = 0;
	for (size_t k = 0; k < shcl_diag_count(d); k++) {
		const char *c = shcl_diag_code(d, k);
		if (!strcmp(c, "E012") || !strcmp(c, "E018")) misplaced++;
	}
	if (o->check) {
		// Same as fmt --check: the save gate --write goes through is asked
		// before 6, so 6 never promises a rewrite that would be refused.
		if (rc == 0) rc = migrate_would_refuse(file, d, misplaced, o);
		if (rc == 0 && rewritten) rc = 6;
	} else if (o->write) {
		if (rc) {
			fprintf(stderr, "%s: refusing to rewrite; nothing changed\n", file);
		} else if (shcl_lost_count(d) != 0 && !o->lossy) {
			fprintf(stderr, "%s: refusing to rewrite: the migrated text drops %zu line(s)/value(s) on load (--lossy overrides)\n", file, shcl_lost_count(d));
			rc = 7;
		} else if (misplaced != 0 && !o->lossy) {
			fprintf(stderr, "%s: refusing to rewrite: the migrated text leaves %zu line(s) unread at an indent no open level matches (--lossy overrides)\n", file, misplaced);
			rc = 7;
		} else if (!unchanged_since_read(file, text, len)) {
			rc = EXIT_IO;
		} else {
			// Only a rewrite leaves a 2.x original to keep. A file that just
			// gains the Format line reads the same either way, and may be a
			// 3.0 file with no stamp.
			char *old = NULL, *why = NULL;
			int64_t version = shcl_format_version(text, len);
			if (rewritten && shcl_write_backup(file, text, len, version < 0 ? 2u : (uint32_t)version, &old, &why) != SHCL_UPGRADE_OK) {
				fprintf(stderr, "%s\n", why);
				free(why);
				rc = EXIT_IO;
			} else if (!shcl_write_file_atomic(file, m.text, m.len)) {
				int e = errno;
				if (!dir_takes_a_temp(file)) fprintf(stderr, "%s: cannot create temporary file: %s\n", file, strerror(e));
				else fprintf(stderr, "%s: %s\n", file, strerror(e));
				// With the original still in place the copy would only stand
				// in the way of the next run. A replace that fails part way on
				// windows can leave nothing at FILE, and then the copy is all
				// there is.
				if (old && holds_bytes(file, text, len)) {
					upgrade_remove(old);
				} else if (old) {
					fprintf(stderr, "%s: the original is %s\n", file, old);
				}
				rc = EXIT_IO;
			} else if (old) {
				fprintf(stderr, "%s: migrated, %zu line(s) rewritten; the original is %s\n", file, rewritten, old);
			} else {
				fprintf(stderr, "%s: migrated, %zu line(s) rewritten\n", file, rewritten);
			}
			free(old);
		}
	} else {
		// The text itself keeps every line, so it prints whatever the gate
		// says, but the exit is the one --write would give, as for the
		// refusals above (2026100717500003).
		if (rc == 0) rc = migrate_would_refuse(file, d, misplaced, o);
		fwrite(m.text, 1, m.len, stdout);
	}
	shcl_free(d); free(m.text); free(text);
	return rc;
}

// A file this shcl cannot load clean, backed up and written fresh: the
// library's shcl_upgrade_file with --write, and its text half without, which
// prints the fresh text and touches nothing.
static int do_upgrade(const Opts *o) {
	if (o->nargs != 1) { fprintf(stderr, "usage: shcl upgrade [options] FILE (see --help)\n"); return 1; }
	const char *file = o->args[0];
	if (o->write && strcmp(file, "-") == 0) {
		fprintf(stderr, "upgrade --write cannot rewrite stdin; drop --write to print, or pass a FILE\n");
		return 1;
	}
	if (o->write && !write_target_ok(file)) return EXIT_IO;
	shcl_upgraded up;
	if (o->write) {
		char *why = NULL;
		shcl_upgrade_error e = shcl_upgrade_file(file, o->from_2x, &up, &why);
		if (e != SHCL_UPGRADE_OK) {
			if (e == SHCL_UPGRADE_AMBIGUOUS) fprintf(stderr, "%s (--from-2x rewrites them)\n", why);
			else fprintf(stderr, "%s\n", why);
			free(why);
			shcl_upgraded_free(&up);
			return e == SHCL_UPGRADE_AMBIGUOUS ? 7 : EXIT_IO;
		}
	} else {
		size_t len; char *text = read_input(file, &len);
		if (!text) return EXIT_IO;
		up = shcl_upgrade(text, len, o->from_2x);
		free(text);
	}
	if (up.current) {
		fprintf(stderr, "%s: nothing to upgrade: it loads clean or names its format\n", file);
		if (!o->write) fwrite(up.text, 1, up.len, stdout);
		shcl_upgraded_free(&up);
		return 0;
	}
	say_diagnostics_from("", up.diagnostics);
	if (up.ambiguous != 0) {
		fprintf(stderr, "%s: %zu value(s) read one way under 2.x and another under these rules, and the file does not say which it was written for; nothing written (--from-2x rewrites them)\n", file, up.ambiguous);
		shcl_upgraded_free(&up);
		return 7;
	}
	if (up.lost != 0)
		fprintf(stderr, "%s: %zu line(s)/value(s) do not carry over to the fresh file%s\n", file, up.lost, o->write ? "; the backup keeps them" : "");
	if (o->write) fprintf(stderr, "%s: upgraded; the original is %s\n", file, up.backup);
	else fwrite(up.text, 1, up.len, stdout);
	shcl_upgraded_free(&up);
	return 0;
}

// One piece's span for `tokens`: start-end plus a mark for how it was quoted
// (`'`, `"`, a backtick, or `?` for a quote that never closed).
static void say_span(const shcl_piece *p) {
	const char *mark = p->quote == SHCL_QUOTE_SINGLE ? "'" : p->quote == SHCL_QUOTE_DOUBLE ? "\"" : p->quote == SHCL_QUOTE_BACKTICK ? "`" : p->quote == SHCL_QUOTE_OPEN ? "?" : "";
	printf("%zu-%zu%s", p->start, p->end, mark);
}

// A bracket array's `[` and, when it is malformed, where and why.
static void say_array(const ShclTokens *tok) {
	if (tok->has_array) printf(" array=%zu", tok->array);
	if (tok->has_array_fault) printf(" array-fault=%zu:%s", tok->array_fault_at, tok->array_fault_why);
}

// Every line's spans, one line of output per input line: the indent length,
// then each token as `kind=start-end` with its quote mark, offsets counted
// from the first character after the indent. A blank line and a comment line
// say so; every other line is tokenized on its own, raw bodies included, since
// this is the lexical view and not the parse.
static int do_tokens(const Opts *o) {
	if (o->nargs != 1) { fprintf(stderr, "usage: shcl tokens FILE (see --help)\n"); return 1; }
	size_t len; char *text = read_input(o->args[0], &len);
	if (!text) return EXIT_IO;
	const char *p = text; size_t n = len;
	if (n >= 3 && (unsigned char)p[0] == 0xEF && (unsigned char)p[1] == 0xBB && (unsigned char)p[2] == 0xBF) { p += 3; n -= 3; }
	ShclArena a; memset(&a, 0, sizeof a);
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	size_t start = 0, lineno = 0;
	for (size_t i = 0; i <= n; i++) {
		if (i < n && p[i] != '\n') continue;
		// A newline-terminated text splits into one more piece than it has
		// lines; that empty tail is not a line.
		if (i == n && n > 0 && p[n - 1] == '\n') break;
		ShclStr line; line.p = p + start; line.n = i - start;
		start = i + 1;
		while (line.n > 0 && line.p[line.n - 1] == '\r') line.n--;
		lineno++;
		size_t ilen = 0;
		while (ilen < line.n && (line.p[ilen] == ' ' || line.p[ilen] == '\t')) ilen++;
		ShclStr rest = trim_wsp_end(s_slice(line, ilen, line.n));
		printf("%zu:%zu", lineno, ilen);
		if (rest.n == 0) { printf(" blank\n"); continue; }
		// The parser takes a leading carriage return off with the indent's blanks.
		ShclStr body = trim_wsp_start(rest);
		size_t lead = rest.n - body.n;
		if (body.n && body.p[0] == '#') { printf(" comment\n"); continue; }
		// A list item and a fence line are value halves on their own. A `-` is
		// an item when a blank follows it, trailing or not, which only the
		// untrimmed line still shows (20260923 item 12).
		size_t after = ilen + lead + 1;
		int item = body.n && body.p[0] == '-' && after < line.n && (line.p[after] == ' ' || line.p[after] == '\t' || line.p[after] == '\r');
		int fence = s_starts(body, "```") || s_starts(body, "~~~");
		if (item || fence) {
			tokenize_value(&a, rest, lead + (item ? 1 : 0), SHCL_RULES_CURRENT, &tok);
			printf(item ? " item" : " fence");
			printf(" value=%zu-%zu", tok.value_start, tok.value_end);
			say_array(&tok);
			for (size_t k = 0; k < tok.nelem; k++) { printf(" elem="); say_span(&tok.elements[k]); }
			if (tok.has_comment) printf(" comment=%zu", tok.comment);
			printf("\n");
			continue;
		}
		tokenize(&a, rest, ':', 0, SHCL_RULES_CURRENT, &tok);
		for (size_t k = 0; k < tok.nseg; k++) {
			printf(" %s=", tok.segments[k].star ? "star" : "name"); say_span(&tok.segments[k].name);
			if (tok.segments[k].has_selector) { printf(" sel="); say_span(&tok.segments[k].selector); }
		}
		if (tok.has_sep) {
			printf(" sep=%zu value=%zu-%zu", tok.sep, tok.value_start, tok.value_end);
			say_array(&tok);
			for (size_t k = 0; k < tok.nelem; k++) { printf(" elem="); say_span(&tok.elements[k]); }
		}
		if (tok.has_comment) printf(" comment=%zu", tok.comment);
		if (tok.has_fault) printf(" fault=%zu:%s", tok.fault_at, tok.fault_why);
		printf("\n");
	}
	arena_free(&a);
	free(text);
	return 0;
}

// Reads an open stream fully into a malloc'd buffer (ops script; no UTF-8 gate).
static char *read_all_fp(FILE *f, size_t *len) {
	char *buf = NULL; size_t cap = 0, n = 0, r; char chunk[65536];
	while ((r = fread(chunk, 1, sizeof chunk, f)) > 0) {
		if (n + r > cap) { cap = (n + r) * 2; buf = (char *)xrealloc(buf, cap ? cap : 1); }
		memcpy(buf + n, chunk, r); n += r;
	}
	if (!buf) buf = (char *)xrealloc(NULL, 1);
	*len = n; return buf;
}

/* An ops-script value with its escapes resolved, ◉TAB◉ and ◉NEWLINE◉ and the
   rest of the file's names, so a tab or a line break can sit on one op line. A
   backslash is text, as in a file (2026100717500002). The file's own reader
   does it, on the value in quotes, so the two can't drift. Returns
   1 with the text in *out, or 0 with the reader's message there; the caller
   frees it either way. */
static int op_text(const char *in, size_t n, char **out, size_t *outn) {
	static const char mark[] = "\xe2\x97\x89", dq[] = "\xe2\x97\x89" "DOUBLE_QUOTE" "\xe2\x97\x89";
	int marked = 0, has_dq = 0, has_sq = 0;
	for (size_t i = 0; i < n; i++) {
		if (i + 3 <= n && memcmp(in + i, mark, 3) == 0) marked = 1;
		if (in[i] == '"') has_dq = 1;
		if (in[i] == '\'') has_sq = 1;
	}
	if (!marked) {
		*out = (char *)xrealloc(NULL, n ? n : 1);
		if (n) memcpy(*out, in, n);
		*outn = n;
		return 1;
	}
	char q = has_dq && !has_sq ? '\'' : '"';
	char *text = (char *)xrealloc(NULL, n * (sizeof dq - 1) + 8), *w = text;
	memcpy(w, "v: ", 3); w += 3;
	*w++ = q;
	for (size_t i = 0; i < n; i++) {
		if (in[i] == '"' && q == '"') { memcpy(w, dq, sizeof dq - 1); w += sizeof dq - 1; }
		else *w++ = in[i];
	}
	*w++ = q; *w++ = '\n';
	shcl_doc *v = xdoc(shcl_parse(text, (size_t)(w - text)));
	free(text);
	int ok = 1;
	shcl_str got = { "", 0 };
	for (size_t i = 0; i < shcl_diag_count(v); i++)
		if (shcl_diag_severity(v, i) == SHCL_SEV_ERROR) { got = shcl_diag_message(v, i); ok = 0; break; }
	if (ok) got = shcl_read_string(v, "v", 1).value;
	*out = (char *)xrealloc(NULL, got.n ? got.n : 1);
	if (got.n) memcpy(*out, got.p, got.n);
	*outn = got.n;
	shcl_free(v);
	return ok;
}

// Which half of a `raw` op had no spelling, and why. The half is asked of the
// library rather than worked out here: an empty info string always reads back,
// so a write that still fails with one is the body's fault. Re-deriving the
// rule in the CLI is how the two copies drift.
static const char *raw_refusal(const char *content, size_t contn) {
	shcl_doc *probe = shcl_new();
	int body_ok = probe && shcl_set_raw(probe, "p", 1, content, contn, "", 0);
	shcl_free(probe);
	return body_ok ? "the info string has no spelling that reads back: a '#' in it opens a comment, and a line break has no inline spelling"
	               : "the block body has no spelling that reads back: a line ending in a carriage return is trimmed on the way back in, and a line spelling the closing fence would end the block early";
}


// Reference-equivalent op-value gates: the same grammar Rust's i64/f64 FromStr
// accepts, checked before conversion, so `abc`, `0x10`, `1_0`, padded or
// non-ASCII digits, and out-of-range magnitudes are rejected instead of being
// silently coerced (and no fixed staging buffer can truncate a long literal).
static int g_i64(const char *p, size_t n, int64_t *out) {
	size_t i = 0;
	if (i < n && (p[i] == '+' || p[i] == '-')) i++;
	if (i == n) return 0;
	for (size_t k = i; k < n; k++) if (p[k] < '0' || p[k] > '9') return 0;
	char *b = (char *)xrealloc(NULL, n + 1); memcpy(b, p, n); b[n] = 0;
	errno = 0; char *end; long long v = strtoll(b, &end, 10);
	int ok = *end == 0 && errno != ERANGE;
	free(b);
	if (!ok) return 0;
	*out = (int64_t)v; return 1;
}
static int g_ci_eq(const char *p, size_t n, const char *kw) {
	size_t kn = strlen(kw);
	if (n != kn) return 0;
	for (size_t i = 0; i < n; i++) { char c = p[i]; if (c >= 'A' && c <= 'Z') c += 32; if (c != kw[i]) return 0; }
	return 1;
}
static int g_f64(const char *p, size_t n, double *out) {
	size_t i = 0;
	if (i < n && (p[i] == '+' || p[i] == '-')) i++;
	if (!(g_ci_eq(p + i, n - i, "inf") || g_ci_eq(p + i, n - i, "infinity") || g_ci_eq(p + i, n - i, "nan"))) {
		size_t d1 = 0, d2 = 0;
		while (i < n && p[i] >= '0' && p[i] <= '9') { i++; d1++; }
		if (i < n && p[i] == '.') { i++; while (i < n && p[i] >= '0' && p[i] <= '9') { i++; d2++; } }
		if (d1 + d2 == 0) return 0;
		if (i < n && (p[i] == 'e' || p[i] == 'E')) {
			i++;
			if (i < n && (p[i] == '+' || p[i] == '-')) i++;
			size_t d3 = 0;
			while (i < n && p[i] >= '0' && p[i] <= '9') { i++; d3++; }
			if (d3 == 0) return 0;
		}
		if (i != n) return 0;
	}
	// The language's own float reader takes inf and nan, and overflow ends up on
	// them too; the document's reader does not, so they are bad values here,
	// the way a bad datetime is.
	char *b = (char *)xrealloc(NULL, n + 1); memcpy(b, p, n); b[n] = 0;
	*out = strtod(b, NULL);
	free(b);
	return isfinite(*out) ? 1 : 0;
}
// Exactly `true` or `false`; anything else is a bad value, like a bad int.
static int g_bool(const char *p, size_t n, int *out) {
	if (n == 4 && memcmp(p, "true", 4) == 0) { *out = 1; return 1; }
	if (n == 5 && memcmp(p, "false", 5) == 0) { *out = 0; return 1; }
	return 0;
}

// The `op line N:` prefix every ops-script error has.
static void op_err(size_t lineno, const char *fmt, ...) {
	va_list ap;
	fprintf(stderr, "op line %zu: ", lineno);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

// Windows calls NUL a terminal through _isatty, so a console mode decides there.
static int stdin_is_terminal(void) {
#ifdef _WIN32
	DWORD mode;
	return GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &mode) != 0;
#else
	return isatty(STDIN_FILENO);
#endif
}

// op_text for one field of op line LINENO, saying why on a failure. 1 with the
// text in *out for the caller to free, else 0 with nothing to free.
static int op_field(size_t lineno, const char *path, size_t plen, const char *in, size_t n, char **out, size_t *outn) {
	if (op_text(in, n, out, outn)) return 1;
	op_err(lineno, "cannot write %.*s: %.*s", (int)plen, path, (int)*outn, *out);
	free(*out);
	*out = NULL;
	return 0;
}

// Apply one write-ops line. A "-default" suffix means "only if absent": values
// are gated FIRST (a malformed value fails even when the path already exists,
// matching the reference's argument-evaluation order), then the op runs as the
// base setter or, with the suffix, as its default form. Returns 0 or 1 (error).
static int apply_op(shcl_doc *d, const char *line, size_t linelen, size_t lineno) {
	size_t nf = 1;
	for (size_t i = 0; i < linelen; i++) if (line[i] == '\t') nf++;
	const char **fp = (const char **)xrealloc(NULL, nf * sizeof *fp);
	size_t *fn = (size_t *)xrealloc(NULL, nf * sizeof *fn);
	{ size_t k = 0, start = 0; for (size_t i = 0; i <= linelen; i++) if (i == linelen || line[i] == '\t') { fp[k] = line + start; fn[k] = i - start; k++; start = i + 1; } }
	// Every op but the array forms takes a fixed number of tab-separated
	// fields. Extra ones used to be dropped, so a `raw` whose content held a
	// literal tab lost everything after it and still reported success; the
	// escape for a tab inside a value is `◉TAB◉`.
	{
		int bad = 0;
		static const struct { const char *op; size_t want; } counts[] = {
			{ "empty", 2 }, { "remove", 2 }, { "clear-comments", 2 }, { "banner", 2 },
			{ "raw", 4 }, { "raw-default", 4 },
			{ "int", 3 }, { "float", 3 }, { "bool", 3 }, { "string", 3 },
			{ "datetime", 3 }, { "literal", 3 }, { "comment", 3 },
			{ "int-default", 3 }, { "float-default", 3 }, { "bool-default", 3 },
			{ "string-default", 3 }, { "datetime-default", 3 }, { "literal-default", 3 },
		};
		for (size_t i = 0; i < sizeof counts / sizeof counts[0]; i++) {
			if (strlen(counts[i].op) != fn[0] || memcmp(counts[i].op, fp[0], fn[0]) != 0) continue;
			if (nf > counts[i].want) {
				fprintf(stderr, "op line %zu: %s takes %zu tab-separated field(s), got %zu\n",
					lineno, counts[i].op, counts[i].want, nf);
				bad = 1;
			}
			break;
		}
		if (bad) { free(fp); free(fn); return 1; }
	}
	const char *path = nf > 1 ? fp[1] : ""; size_t plen = nf > 1 ? fn[1] : 0;
	const char *v = nf > 2 ? fp[2] : ""; size_t vn = nf > 2 ? fn[2] : 0;
	int rc = 0, wrote = 1;
	char *content = NULL; size_t contentn = 0; // a raw op's, for the refusal below
	size_t opn_full = fn[0]; // the op as written, for the unknown-op message
	int only_absent = 0;
	if (fn[0] >= 8 && memcmp(fp[0] + fn[0] - 8, "-default", 8) == 0) {
		only_absent = 1;
		fn[0] -= 8; // strip suffix; the base op handles the actual write
	}
	#define OP(s) (fn[0] == strlen(s) && memcmp(fp[0], s, fn[0]) == 0)
	// A default op is the library's default form, so a path that is already
	// there still has its value and its path judged the way a write would.
	#define SET(fn, ...) (only_absent ? fn##_default(d, path, plen, __VA_ARGS__) : fn(d, path, plen, __VA_ARGS__))
	size_t an = nf > 2 ? nf - 2 : 0; // array element count (fields from index 2)
	if (OP("int")) { int64_t x; if (!g_i64(v, vn, &x)) { op_err(lineno, "bad int: %.*s", (int)vn, v); rc = 1; } else wrote = SET(shcl_set_int, x); }
	else if (OP("float")) { double x; if (!g_f64(v, vn, &x)) { op_err(lineno, "bad float: %.*s", (int)vn, v); rc = 1; } else wrote = SET(shcl_set_float, x); }
	else if (OP("bool")) { int x; if (!g_bool(v, vn, &x)) { op_err(lineno, "bad bool: %.*s", (int)vn, v); rc = 1; } else wrote = SET(shcl_set_bool, x); }
	else if (OP("string")) { char *b; size_t m; if (!op_field(lineno, path, plen, v, vn, &b, &m)) rc = 1; else { wrote = SET(shcl_set_string, b, m); free(b); } }
	else if (OP("datetime")) { shcl_datetime dt; ShclStr sv; sv.p = v; sv.n = vn; if (!parse_datetime(&d->arena, sv, &dt)) { op_err(lineno, "bad datetime: %.*s", (int)vn, v); rc = 1; } else wrote = SET(shcl_set_datetime, &dt); }
	else if (OP("literal")) { wrote = SET(shcl_set_literal, v, vn); }
	else if (OP("int-array")) { int64_t *a = (int64_t *)xrealloc(NULL, (an ? an : 1) * sizeof *a); memset(a, 0, (an ? an : 1) * sizeof *a); for (size_t i = 0; i < an && !rc; i++) if (!g_i64(fp[2 + i], fn[2 + i], &a[i])) { op_err(lineno, "bad int: %.*s", (int)fn[2 + i], fp[2 + i]); rc = 1; } if (!rc) wrote = SET(shcl_set_int_array, a, an); free(a); }
	else if (OP("float-array")) { double *a = (double *)xrealloc(NULL, (an ? an : 1) * sizeof *a); memset(a, 0, (an ? an : 1) * sizeof *a); for (size_t i = 0; i < an && !rc; i++) if (!g_f64(fp[2 + i], fn[2 + i], &a[i])) { op_err(lineno, "bad float: %.*s", (int)fn[2 + i], fp[2 + i]); rc = 1; } if (!rc) wrote = SET(shcl_set_float_array, a, an); free(a); }
	else if (OP("bool-array")) { int *a = (int *)xrealloc(NULL, (an ? an : 1) * sizeof *a); memset(a, 0, (an ? an : 1) * sizeof *a); for (size_t i = 0; i < an && !rc; i++) if (!g_bool(fp[2 + i], fn[2 + i], &a[i])) { op_err(lineno, "bad bool: %.*s", (int)fn[2 + i], fp[2 + i]); rc = 1; } if (!rc) wrote = SET(shcl_set_bool_array, a, an); free(a); }
	else if (OP("string-array")) {
		// Zeroed, not just sized: an empty array writes nothing here and the setter
		// reads nothing, but a compiler that inlines the allocator cannot see that
		// and calls the slots uninitialized. gcc 13 does, 14 and 15 do not.
		char **sv = (char **)xrealloc(NULL, (an ? an : 1) * sizeof *sv); size_t *sl = (size_t *)xrealloc(NULL, (an ? an : 1) * sizeof *sl);
		memset(sv, 0, (an ? an : 1) * sizeof *sv); memset(sl, 0, (an ? an : 1) * sizeof *sl);
		for (size_t i = 0; i < an && !rc; i++) if (!op_field(lineno, path, plen, fp[2 + i], fn[2 + i], &sv[i], &sl[i])) rc = 1;
		if (!rc) wrote = SET(shcl_set_string_array, (const char *const *)sv, sl, an);
		for (size_t i = 0; i < an; i++) free(sv[i]);
		free(sv); free(sl);
	}
	else if (OP("datetime-array")) {
		shcl_datetime *a = (shcl_datetime *)xrealloc(NULL, (an ? an : 1) * sizeof *a);
		for (size_t i = 0; i < an && !rc; i++) { ShclStr sv; sv.p = fp[2 + i]; sv.n = fn[2 + i]; if (!parse_datetime(&d->arena, sv, &a[i])) { op_err(lineno, "bad datetime: %.*s", (int)fn[2 + i], fp[2 + i]); rc = 1; } }
		if (!rc) wrote = SET(shcl_set_datetime_array, a, an);
		free(a);
	}
	else if (OP("raw")) { if (!op_field(lineno, path, plen, nf > 3 ? fp[3] : "", nf > 3 ? fn[3] : 0, &content, &contentn)) rc = 1; else wrote = SET(shcl_set_raw, content, contentn, v, vn); }
	else if (OP("empty") && !only_absent) wrote = shcl_set_empty(d, path, plen);
	else if (OP("comment") && !only_absent) { char *b; size_t m; if (!op_field(lineno, path, plen, v, vn, &b, &m)) rc = 1; else { wrote = shcl_set_comment(d, path, plen, b, m); free(b); } }
	else if ((OP("remove") || OP("clear-comments")) && !only_absent && unusable_path(d, path, plen)) {
		op_err(lineno, "cannot %.*s %.*s: %s", (int)fn[0], fp[0], (int)plen, path, bad_path(path, plen)); rc = 1;
	}
	else if (OP("remove") && !only_absent) shcl_remove(d, path, plen);
	else if (OP("clear-comments") && !only_absent) shcl_clear_comments(d, path, plen);
	// The second field is on or off, not a path.
	else if (OP("banner") && !only_absent) {
		if (plen == 2 && memcmp(path, "on", 2) == 0) shcl_set_banner(d, 1);
		else if (plen == 3 && memcmp(path, "off", 3) == 0) shcl_set_banner(d, 0);
		else { op_err(lineno, "bad banner: %.*s (on or off)", (int)plen, path); rc = 1; }
	}
	else { op_err(lineno, "unknown op: %.*s", (int)opn_full, fp[0]); rc = 1; }
	if (rc == 0 && !wrote) {
		// Which half of the op had no spelling: the reader is otherwise sent to
		// the value when it was the info string or the comment that failed.
		const char *unwritable = "the value has no spelling that reads back";
		if (OP("literal")) unwritable = "the value text is not one value";
		else if (OP("comment")) unwritable = "the comment text is not one line";
		else if (OP("raw")) unwritable = raw_refusal(content, contentn);
		int array = (fn[0] > 6 && memcmp(fp[0] + fn[0] - 6, "-array", 6) == 0) || (OP("literal") && array_text(v, vn));
		op_err(lineno, "cannot write %.*s: %s", (int)plen, path, describe_refusal(d, path, plen, array, unwritable));
		rc = 1;
	}
	#undef SET
	#undef OP
	free(content);
	free(fp); free(fn);
	return rc;
}

static int do_set(Opts *o) {
	if (o->nargs != 1) { fprintf(stderr, "usage: shcl set [--write|-w] [options] FILE (see --help)\n"); return 1; }
	const char *file = o->args[0];
	if (o->write && strcmp(file, "-") == 0) {
		fprintf(stderr, "set --write cannot rewrite stdin; drop --write to print, or pass a FILE\n");
		return 1;
	}
	if (o->write && !write_target_ok(file)) return EXIT_IO;
	// Base doc: with the edits given as options no ops script is read, so a '-'
	// file is the document on stdin the way it is everywhere else; only when
	// stdin is the ops script does '-' mean an empty base. Reading neither threw
	// a piped document away at exit 0.
	// --write names the file this command produces, so a FILE that is not there
	// yet is a create and the edits go into a new document. Only under --write,
	// and only when nothing is at the path at all: without --write there is
	// nothing to create, and a file that exists but cannot be read is still an
	// error rather than something to quietly write over. Checked before the
	// read, not after: read_input prints its own diagnostic, and a create has
	// nothing to report.
	// A created file starts out as the info block, so a new config says what
	// format it is. Comments in an otherwise empty document are the document's
	// trailing trivia, so the edits go above it and the write still goes
	// through the library's save gate.
	// The --layer files sit under it and --set overrides sit on top, before
	// ops, through the same fold every other subcommand uses.
	int creating = o->write && strcmp(file, "-") != 0 && path_absent(file);
	char *given = NULL; size_t given_len = 0;
	if (creating && !o->no_banner) {
		given_len = strlen(SHCL_GEN_BANNER);
		given = (char *)xrealloc(NULL, given_len + 1);
		memcpy(given, SHCL_GEN_BANNER, given_len + 1);
	}
	else if (creating || (!strcmp(file, "-") && o->nsets == 0)) { given = (char *)xrealloc(NULL, 1); given[0] = '\0'; }
	// Lines the edits leave alone are written back as they were, so a
	// hand-kept file stays the way it was kept. A created file has none.
	LayeredDoc L; int lgate = load_layered_from(o, file, given, given_len, !creating, &L);
	if (lgate) return lgate;
	shcl_doc *d = L.doc;
	// --set gives the edits, so stdin is left alone: reading it here would
	// block on the console for anyone who passed edits as options.
	size_t opslen = 0; char *ops = NULL;
	if (o->nsets == 0) {
		// Say so before blocking at a terminal, where nothing on stdin used to
		// read as a hang. A pipe gets no note, since a script piping ops in
		// knows (2026100717500018).
		if (stdin_is_terminal()) fprintf(stderr, "shcl: reading write-ops from stdin (one op per line, tab-separated; end with EOF)\n");
		ops = read_all_fp(stdin, &opslen);
		// The ops script gets the same UTF-8 gate as any file input (exit 1).
		if (!utf8_valid(ops, opslen)) {
			fprintf(stderr, "stdin: stream did not contain valid UTF-8\n");
			free(ops); layered_free(&L); return EXIT_IO;
		}
	}
	/* Byte order marks off the front: Windows PowerShell 5.1 puts one or more
	   before text it pipes to a program (20260924 item 7), and the first op
	   then read as unknown. No op starts with one. */
	int rc = 0; size_t start = 0, lineno = 0;
	while (opslen - start >= 3 && (unsigned char)ops[start] == 0xEF && (unsigned char)ops[start + 1] == 0xBB && (unsigned char)ops[start + 2] == 0xBF) start += 3;
	for (size_t i = start; i <= opslen; i++) {
		if (i == opslen || ops[i] == '\n') {
			size_t end = i;
			if (end > start && ops[end - 1] == '\r') end--; // match Rust lines() CRLF
			size_t n = end - start;
			lineno++;
			if (n > 0 && ops[start] != '#') { if (apply_op(d, ops + start, n, lineno)) { rc = 1; break; } }
			if (i == opslen) break;
			start = i + 1;
		}
	}
	// The re-parse below borrows its text, so both outlive write_back.
	shcl_doc *nd = NULL; char *nt = NULL;
	if (rc == 0) {
		// "Create" was decided before the wait on stdin, so a file that turned up
		// meanwhile is refused rather than replaced.
		if (o->write && creating && !path_absent(file)) {
			fprintf(stderr, "%s: file exists (it appeared while the edits were read)\n", file);
			rc = EXIT_IO;
		}
		else if (o->write) {
			// The banner seeded an empty document, so the blank line above it
			// was the document's first and the parse drops those on purpose.
			// Put it back now that the edits sit above it, so a created file
			// reads the way init's output does.
			if (creating && !o->no_banner) {
				shcl_str c = shcl_to_canonical(d);
				size_t bl = strlen(SHCL_GEN_BANNER);
				size_t hl = c.n > bl ? c.n - bl : 0;
				if (hl > 0 && !memcmp(c.p + hl, SHCL_GEN_BANNER, bl)
					&& !(hl >= 2 && c.p[hl - 1] == '\n' && c.p[hl - 2] == '\n')) {
					nt = (char *)xrealloc(NULL, c.n + 1);
					memcpy(nt, c.p, hl); nt[hl] = '\n'; memcpy(nt + hl + 1, SHCL_GEN_BANNER, bl);
					nd = xdoc(shcl_parse_with(nt, c.n + 1, o->strictness));
				}
			}
			// A file that was there is read again first, for the same wait.
			rc = write_back(nd ? nd : d, file, o, creating ? NULL : L.texts[L.ntexts - 1], L.base_len, !creating);
		}
		else {
			// `shcl set f ... > f.new && mv f.new f` is a common edit, so the
			// print answers the way --write would: the same refusal, and the
			// same word when the lines could not be kept. Only a print with no
			// layers tried to keep them (2026100717500003).
			int kept = 0;
			shcl_str c = shcl_to_text_keep_lines(d, &kept);
			if (!kept && !o->lossy && shcl_lost_count(d) > 0) {
				fprintf(stderr, "%s: refusing to print: this result would delete %zu line(s)/value(s) from the file (--lossy overrides)\n", file, shcl_lost_count(d));
				rc = 7;
			} else {
				fwrite(c.p, 1, c.n, stdout);
				if (!kept && o->nlayers == 0) fprintf(stderr, "%s: printed in the canonical form; the lines could not be kept as they were\n", file);
			}
		}
	}
	if (nd) shcl_free(nd);
	free(nt); free(ops); layered_free(&L); return rc;
}

/* The schema check validates against: --schema, else the one the file names
   on its Schema line. A relative path there is read from the config file's
   directory, the way an editor reads it. A URL is left to editors, since a
   check that reads the network because of a line in a file is not one to run
   unattended. The caller frees what comes back. */
static char *schema_for(const Opts *o, const char *file, const char *text, size_t len, size_t *out_len, int *refused) {
	size_t n;
	const char *named;
	*refused = 0;
	if (o->schema) { named = o->schema; n = strlen(named); }
	else if (!(named = shcl_schema_ref(text, len, &n))) return NULL;
	else {
		for (size_t i = 0; i + 3 <= n; i++)
			if (memcmp(named + i, "://", 3) == 0) {
				fprintf(stderr, "the file names its schema by URL (%.*s), which check does not fetch; pass --schema=SCHEMA to validate against it\n", (int)n, named);
				return NULL;
			}
#ifdef _WIN32
		/* Two separators, or the NT prefix, name a share or a device, and a
		   line in a file someone else wrote must not reach another host. */
		int two = n >= 2 && (named[0] == '/' || named[0] == '\\') && (named[1] == '/' || named[1] == '\\');
		if (two || (n >= 4 && memcmp(named, "\\??\\", 4) == 0)) {
			fwrite(named, 1, n, stderr);
			fprintf(stderr, ": a Schema line cannot name a network or device path\n");
			*refused = 1;
			return NULL;
		}
#endif
	}
	unsigned char c = (unsigned char)named[0];
	int absolute = o->schema || c == '/';
#ifdef _WIN32
	absolute = absolute || c == '\\' || (n >= 2 && named[1] == ':' && (c | 0x20) >= 'a' && (c | 0x20) <= 'z');
#endif
	const char *dir = "./"; size_t dn = 2;
	size_t start = strcmp(file, "-") != 0 ? name_start(file) : 0;
	if (start) { dir = file; dn = start; }
	char *out = (char *)xrealloc(NULL, dn + n + 1), *w = out;
	if (!absolute) { memcpy(w, dir, dn); w += dn; }
	memcpy(w, named, n); w[n] = '\0';
	*out_len = (size_t)(w - out) + n;
	return out;
}

/* The most a Schema line's file may hold. A regular file can still read
   without end: the kernel's page map has size 0 and reads as hundreds of GiB. */
#define SCHEMA_LINE_MAX ((size_t)16 << 20)

/* The schema a Schema line names. A line in a file someone else wrote must not
   make an unattended check wait on a FIFO or read a device until memory runs
   out, so only a regular file is read, and no more of it than SCHEMA_LINE_MAX.
   The path comes from the file, so unlike argv it can hold a NUL. */
static char *read_named_schema(const char *path, size_t pn, size_t *len) {
	if (memchr(path, 0, pn)) {
		fwrite(path, 1, pn, stderr);
		fprintf(stderr, ": %s\n", strerror(EINVAL));
		return NULL;
	}
#ifdef _WIN32
	if (!is_a_directory(path) && shcl_not_a_disk_file(path)) {
		fprintf(stderr, "%s: not a regular file\n", path);
		return NULL;
	}
	if (is_a_directory(path)) { fprintf(stderr, "%s: Is a directory\n", path); return NULL; }
	FILE *f = open_rb(path);
	if (!f) { fprintf(stderr, "%s: %s\n", path, strerror(errno)); return NULL; }
	/* Asked again of the handle, since the path can change after the test. */
	if (GetFileType((HANDLE)_get_osfhandle(_fileno(f))) != FILE_TYPE_DISK) {
		fprintf(stderr, "%s: not a regular file\n", path);
		fclose(f);
		return NULL;
	}
	return read_stream(f, path, SCHEMA_LINE_MAX, len);
#else
	/* Asked before the open too, since opening a FIFO waits for a writer. */
	struct stat st;
	if (stat(path, &st) == 0 && !S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) {
		fprintf(stderr, "%s: not a regular file\n", path);
		return NULL;
	}
	if (is_a_directory(path)) { fprintf(stderr, "%s: Is a directory\n", path); return NULL; }
	/* The path can turn into a FIFO between the stat and the open, so the open
	   does not wait, and the flag comes straight back off: only the open
	   waits, and the fstat refuses a FIFO before any read. */
	int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) { fprintf(stderr, "%s: %s\n", path, strerror(errno)); return NULL; }
	int flags = fcntl(fd, F_GETFL);
	if (flags == -1 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == -1) {
		fprintf(stderr, "%s: %s\n", path, strerror(errno));
		close(fd);
		return NULL;
	}
	if (fstat(fd, &st) == 0 && !S_ISREG(st.st_mode)) {
		fprintf(stderr, "%s: not a regular file\n", path);
		close(fd);
		return NULL;
	}
	FILE *f = fdopen(fd, "rb");
	if (!f) { fprintf(stderr, "%s: %s\n", path, strerror(errno)); close(fd); return NULL; }
	return read_stream(f, path, SCHEMA_LINE_MAX, len);
#endif
}

static int do_check(const Opts *o) {
	if (o->nargs != 1) { fprintf(stderr, "usage: shcl check [options] FILE (see --help)\n"); return 1; }
	size_t len; char *text = read_input(o->args[0], &len);
	if (!text) return EXIT_IO;
	shcl_doc *d = xdoc(shcl_parse_with(text, len, o->strictness));
	// --schema: append validation diagnostics under the same contract. The
	// schema itself always loads at Standard (a program artifact); one that
	// does not load cleanly is a single V099 schema fault.
	shcl_validation *val = NULL;
	shcl_doc *sd = NULL;
	char *stext = NULL;
	int v99 = 0;
	/* A strict load leaves the document it recovered, which is what the
	   library's one-shot validate walks. So the schema half runs either way: at
	   strict a user was getting less out of check than at standard on the same
	   file, and check writes nothing, so fmt's refusal to rewrite a
	   strict-failing document does not apply. */
	size_t spn = 0;
	int refused;
	char *schema_file = schema_for(o, o->args[0], text, len, &spn, &refused);
	if (refused) { shcl_free(d); free(text); return EXIT_IO; }
	if (schema_file) {
		size_t slen;
		stext = o->schema ? read_input(schema_file, &slen) : read_named_schema(schema_file, spn, &slen);
		free(schema_file);
		if (!stext) { shcl_free(d); free(text); return EXIT_IO; }
		sd = xdoc(shcl_parse(stext, slen));
		size_t sn = shcl_diag_count(sd);
		for (size_t i = 0; i < sn; i++) if (shcl_diag_severity(sd, i) == SHCL_SEV_ERROR) v99 = 1;
		if (v99) {
			for (size_t i = 0; i < sn; i++) {
				const char *sev = shcl_diag_severity(sd, i) == SHCL_SEV_ERROR ? "Error" : "Hint";
				shcl_str m = shcl_diag_message(sd, i);
				fprintf(stderr, "schema line %zu: %s: %s ", shcl_diag_line(sd, i), sev, shcl_diag_code(sd, i));
				fwrite(m.p, 1, m.n, stderr); fputc('\n', stderr);
			}
		} else {
			/* The schema's own load has something to say too: an H001 on a
			   repeated `allowed` is what explains the V092 below it. On stderr
			   with the schema's own line numbers, the way a V099's are -
			   stdout is the code contract. */
			for (size_t i = 0; i < sn; i++) {
				const char *sev = shcl_diag_severity(sd, i) == SHCL_SEV_ERROR ? "Error" : "Hint";
				shcl_str m = shcl_diag_message(sd, i);
				fprintf(stderr, "schema line %zu: %s: %s ", shcl_diag_line(sd, i), sev, shcl_diag_code(sd, i));
				fwrite(m.p, 1, m.n, stderr); fputc('\n', stderr);
			}
			val = xdoc(shcl_validate(d, sd));
			shcl_suppress_declared_repeats(sd, d);
			shcl_suppress_declared_reopens(sd, d);
		}
	}
	size_t n = shcl_diag_count(d), nerr = 0;
	size_t nval = val ? shcl_validation_count(val) : 0;
	size_t total = n + nval + (v99 ? 1 : 0);
	// stdout gets the stable codes - the cross-binding contract. The prose is
	// per-binding voice and goes to stderr (which the differential check drops).
	for (size_t i = 0; i < n; i++) {
		const char *sev = shcl_diag_severity(d, i) == SHCL_SEV_ERROR ? "Error" : "Hint";
		if (shcl_diag_severity(d, i) == SHCL_SEV_ERROR) nerr++;
		printf("line %zu: %s: %s\n", shcl_diag_line(d, i), sev, shcl_diag_code(d, i));
		say_diag(shcl_diag_line(d, i), shcl_diag_severity(d, i), shcl_diag_code(d, i), shcl_diag_message(d, i));
	}
	if (v99) {
		printf("line 0: Error: V099\n");
		shcl_str v99m; v99m.p = "schema failed to load"; v99m.n = 21;
		say_diag(0, SHCL_SEV_ERROR, "V099", v99m);
		nerr++;
	}
	for (size_t i = 0; i < nval; i++) {
		const char *sev = shcl_validation_severity(val, i) == SHCL_SEV_ERROR ? "Error" : "Hint";
		if (shcl_validation_severity(val, i) == SHCL_SEV_ERROR) nerr++;
		const char *code = shcl_validation_code(val, i);
		printf("line %zu: %s: %s\n", shcl_validation_line(val, i), sev, code);
		// A V090-V093 line number is a SCHEMA line (the code table says so);
		// the prose names the file so the number spaces cannot be confused.
		say_diag(shcl_validation_line(val, i), shcl_validation_severity(val, i), code, shcl_validation_message(val, i));
	}
	// The codes are the portable half of a diagnostic and nothing else on
	// screen says where to look one up.
	if (total > 0) fprintf(stderr, "(run 'shcl explain CODE' for the rule behind a code)\n");
	int rc;
	if (shcl_strict_failed(d)) {
		printf("strict load failed: %zu diagnostic(s)\n", total); rc = 6;
	} else if (nerr > 0) {
		// Loaded, but lines were dropped: nonzero so a CI gate on check catches it.
		printf("failed: %zu diagnostic(s), %zu error(s)\n", total, nerr); rc = 6;
	} else {
		printf("ok (%zu diagnostic(s))\n", total); rc = 0;
	}
	shcl_validation_free(val);
	if (sd) shcl_free(sd);
	free(stext);
	shcl_free(d); free(text); return rc;
}

static int do_init(const Opts *o) {
	if (o->nargs > 0) { fprintf(stderr, "init takes no file argument (see --help)\n"); return 1; }
	if (!o->schema) { fprintf(stderr, "init needs --schema=FILE (see --help)\n"); return 1; }
	size_t slen; char *stext = read_input(o->schema, &slen);
	if (!stext) return EXIT_IO;
	// The schema always loads at Standard - a program artifact, not user data.
	shcl_doc *sd = xdoc(shcl_parse(stext, slen));
	int bad = 0; size_t sn = shcl_diag_count(sd);
	for (size_t i = 0; i < sn; i++) if (shcl_diag_severity(sd, i) == SHCL_SEV_ERROR) bad = 1;
	if (bad) {
		for (size_t i = 0; i < sn; i++) {
			const char *sev = shcl_diag_severity(sd, i) == SHCL_SEV_ERROR ? "Error" : "Hint";
			shcl_str m = shcl_diag_message(sd, i);
			fprintf(stderr, "schema line %zu: %s: %s ", shcl_diag_line(sd, i), sev, shcl_diag_code(sd, i));
			fwrite(m.p, 1, m.n, stderr); fputc('\n', stderr);
		}
		fprintf(stderr, "init: schema failed to load\n");
		// A broken schema is a config-semantics failure, not a usage error:
		// same exit as `check --schema` reporting it.
		shcl_free(sd); free(stext); return 6;
	}
	int ok = 0;
	// Generation-only faults are recorded on the schema document as it runs;
	// anything past this mark came from the call below.
	size_t diagMark = shcl_diag_count(sd);
	shcl_str text = shcl_generate(sd, o->no_banner, &ok);
	if (!ok) {
		size_t nd = shcl_diag_count(sd);
		for (size_t i = diagMark; i < nd; i++)
			say_diag(shcl_diag_line(sd, i), shcl_diag_severity(sd, i), shcl_diag_code(sd, i), shcl_diag_message(sd, i));
		fprintf(stderr, "init: schema has faults\n");
		shcl_free(sd); free(stext); return 6;
	}
	fwrite(text.p, 1, text.n, stdout);
	shcl_free(sd); free(stext); return 0;
}

static int do_enum(Opts *o, int want_count) {
	if (o->nargs != 2) {
		const char *name = want_count ? "count" : "instances";
		fprintf(stderr, "usage: shcl %s [options] FILE PATH (see --help)\n", name);
		return 1;
	}
	const char *file = o->args[0], *path = o->args[1]; size_t plen = strlen(path);
	if (refuse_read_path(path, plen)) return 1;
	LayeredDoc L; int gate = load_layered(o, file, &L);
	if (gate) return gate;
	shcl_doc *d = L.doc;
	if (want_count) printf("%zu\n", shcl_count(d, path, plen));
	else { shcl_str *vals; size_t n = shcl_instances(d, path, plen, &vals); for (size_t i = 0; i < n; i++) out_one_line(d, vals[i].p, vals[i].n); }
	layered_free(&L); return 0;
}

// The type option's kind name (--int -> "int"), or NULL when a is no type
// option.
// The type options, as one list. kind_from_opt is still the reader; this is
// for the places that need the spellings themselves - the did-you-mean on a
// typo, and the per-subcommand help.
static const char *const TYPE_OPTS[] = { "--int", "--float", "--bool", "--datetime", "--string", "--raw", "--rawinfo", "--duration", "--size", NULL };

static const char *kind_from_opt(const char *a) {
	static const char *const kinds[] = { "int", "float", "bool", "datetime", "string", "raw", "rawinfo", "duration", "size" };
	if (a[0] != '-' || a[1] != '-') return NULL;
	for (size_t i = 0; i < sizeof kinds / sizeof kinds[0]; i++)
		if (!strcmp(a + 2, kinds[i])) return kinds[i];
	return NULL;
}

// Record a distinct canonical option name for per-command validation.
static void opt_seen(Opts *o, const char *name) {
	for (int i = 0; i < o->nseen; i++) if (!strcmp(o->seen[i], name)) return;
	if (o->nseen < 16) o->seen[o->nseen++] = name;
}

static void opt_push(const char ***arr, int *n, const char *v) {
	*arr = (const char **)xrealloc((void *)*arr, ((size_t)*n + 1) * sizeof **arr);
	(*arr)[(*n)++] = v;
}

static void set_push(Opts *o, const char *path, size_t plen, const char *value, const char *opt) {
	o->sets = (SetOpt *)xrealloc(o->sets, ((size_t)o->nsets + 1) * sizeof *o->sets);
	o->sets[o->nsets].path = path; o->sets[o->nsets].plen = plen;
	o->sets[o->nsets].value = value; o->sets[o->nsets].opt = opt;
	o->nsets++;
}

static void opts_free(Opts *o) {
	free((void *)o->layers); free(o->sets); free((void *)o->args);
	o->layers = o->args = NULL; o->sets = NULL; o->nlayers = o->nsets = o->nargs = 0;
}


// Record the first competing pair. Only the first is kept: the line is already
// a usage error, and a second pair would just change which one gets named.
static void note_clash(Opts *o, const char *opt, const char *a, const char *b) {
	if (!o->clash[0]) { o->clash_opt = opt; o->clash[0] = a; o->clash[1] = b; }
}

// Apply a value-taking option's value. Returns 0 ok, 1 on a bad value.
static int set_value_opt(Opts *o, const char *name, const char *v) {
	if (!strcmp(name, "--default")) {
		if (o->deflt && strcmp(o->deflt, v)) note_clash(o, "--default", o->deflt, v);
		o->deflt = v; o->on_bad = "default"; opt_seen(o, "--default");
	}
	else if (!strcmp(name, "--on-bad")) {
		const char *mode;
		if (g_ci_eq(v, strlen(v), "error")) mode = "error";
		else if (g_ci_eq(v, strlen(v), "default")) mode = "default";
		else if (g_ci_eq(v, strlen(v), "flag")) mode = "flag";
		else { fprintf(stderr, "bad --on-bad value: %s (see --help)\n", v); return 1; }
		if (o->on_bad_text && strcmp(o->on_bad_arg, mode)) note_clash(o, "--on-bad", o->on_bad_text, v);
		o->on_bad = o->on_bad_arg = mode;
		o->on_bad_text = v;
		opt_seen(o, "--on-bad");
	} else if (!strcmp(name, "--strictness")) {
		shcl_strictness level;
		if (!shcl_strictness_from_arg(v, strlen(v), &level)) { fprintf(stderr, "bad --strictness value: %s (see --help)\n", v); return 1; }
		if (o->strictness_text && o->strictness != level) note_clash(o, "--strictness", o->strictness_text, v);
		o->strictness = level; o->strictness_text = v;
		opt_seen(o, "--strictness");
	} else if (!strcmp(name, "--schema")) {
		if (o->schema && strcmp(o->schema, v)) note_clash(o, "--schema", o->schema, v);
		o->schema = v; opt_seen(o, "--schema");
	} else if (!strcmp(name, "--unit")) {
		if (o->unit && strcmp(o->unit, v)) note_clash(o, "--unit", o->unit, v);
		o->unit = v; opt_seen(o, "--unit");
	} else if (!strcmp(name, "--layer")) {
		opt_push(&o->layers, &o->nlayers, v); opt_seen(o, "--layer");
	} else if (!strcmp(name, "--remove")) {
		if (!*v) { fprintf(stderr, "bad --remove value (want PATH) (see --help)\n"); return 1; }
		shcl_doc *empty = shcl_parse("", 0);
		int unusable = unusable_path(empty, v, strlen(v));
		shcl_free(empty);
		if (unusable) { fprintf(stderr, "bad --remove value (%s): %s (see --help)\n", bad_path(v, strlen(v)), v); return 1; }
		set_push(o, v, strlen(v), "", "--remove"); opt_seen(o, "--remove");
	} else if (!strcmp(name, "--set") || !strcmp(name, "--set-literal")
	           || !strcmp(name, "--set-default") || !strcmp(name, "--set-literal-default")) {
		size_t plen; const char *val;
		if (!split_set(v, &plen, &val) || plen == 0) { fprintf(stderr, "bad %s value (want PATH=VALUE, quotes and parens balanced): %s (see --help)\n", name, v); return 1; }
		set_push(o, v, plen, val, name); opt_seen(o, name);
	}
	return 0;
}

// Defined below, beside the command table they read.
static size_t option_names(const char **v, size_t cap);
static void suggest(char *out, size_t outsz, const char **cands, size_t ncands, const char *word);

// A real option by any spelling, -w included. The suggestions draw on
// option_names alone, which leaves the short form out.
static int known_option(const char *name) {
	if (!strcmp(name, "-w")) return 1;
	const char *cands[64];
	size_t n = option_names(cands, sizeof cands / sizeof cands[0]);
	for (size_t k = 0; k < n; k++) if (!strcmp(cands[k], name)) return 1;
	return 0;
}

static int parse_opts(int argc, char **argv, int from, Opts *o) {
	o->kind = "string"; o->kind_opt = o->kind_text = NULL; o->clash_opt = NULL; o->clash[0] = o->clash[1] = NULL;
	o->array = 0; o->slots = 0; o->deflt = NULL; o->on_bad = "flag"; o->on_bad_arg = NULL; o->on_bad_text = NULL;
	o->strictness = SHCL_STANDARD; o->strictness_text = NULL; o->write = 0; o->lossy = 0; o->from_2x = 0; o->check = 0; o->no_banner = 0; o->schema = NULL; o->unit = NULL; o->decimal = 0;
	o->layers = o->args = NULL; o->sets = NULL; o->nlayers = o->nsets = o->nargs = 0; o->nseen = 0;
	o->swallowed_opt = o->swallowed_value = NULL;
	// Value-taking options accept both --opt=VALUE and the space form --opt VALUE.
	for (int i = from; i < argc; i++) {
		const char *a = argv[i];
		// Everything after `--` is positional, so a file or path may begin
		// with a dash.
		if (!strcmp(a, "--")) {
			for (int k = i + 1; k < argc; k++) opt_push(&o->args, &o->nargs, argv[k]);
			return 0;
		}
		const char *k = kind_from_opt(a);
		if (k) {
			// Both spellings are argv or static text, so the pair outlives the parse.
			if (o->kind_opt && strcmp(o->kind_opt, k)) note_clash(o, NULL, o->kind_text, a);
			o->kind = o->kind_opt = k; o->kind_text = a; opt_seen(o, "--<type>");
		}
		else if (!strcmp(a, "--array")) { o->array = 1; opt_seen(o, "--array"); }
		else if (!strcmp(a, "--slots")) { o->slots = 1; opt_seen(o, "--slots"); }
		else if (!strcmp(a, "--write") || !strcmp(a, "-w")) { o->write = 1; opt_seen(o, "--write"); }
		else if (!strcmp(a, "--lossy")) { o->lossy = 1; opt_seen(o, "--lossy"); }
		else if (!strcmp(a, "--from-2x")) { o->from_2x = 1; opt_seen(o, "--from-2x"); }
		else if (!strcmp(a, "--check")) { o->check = 1; opt_seen(o, "--check"); }
		else if (!strcmp(a, "--no-banner")) { o->no_banner = 1; opt_seen(o, "--no-banner"); }
		else if (!strcmp(a, "--decimal")) { o->decimal = 1; opt_seen(o, "--decimal"); }
		else if (!strcmp(a, "--default") || !strcmp(a, "--on-bad") || !strcmp(a, "--strictness") || !strcmp(a, "--schema") || !strcmp(a, "--unit") || !strcmp(a, "--layer") || !strcmp(a, "--set") || !strcmp(a, "--set-literal") || !strcmp(a, "--set-default") || !strcmp(a, "--set-literal-default") || !strcmp(a, "--remove")) {
			if (i + 1 >= argc) { fprintf(stderr, "missing value for %s (try %s=VALUE)\n", a, a); return 1; }
			if (set_value_opt(o, a, argv[++i])) return 1;
			if (i + 1 == argc) { o->swallowed_opt = a; o->swallowed_value = argv[i]; }
		}
		else if (!strncmp(a, "--default=", 10)) { if (set_value_opt(o, "--default", a + 10)) return 1; }
		else if (!strncmp(a, "--on-bad=", 9)) { if (set_value_opt(o, "--on-bad", a + 9)) return 1; }
		else if (!strncmp(a, "--strictness=", 13)) { if (set_value_opt(o, "--strictness", a + 13)) return 1; }
		else if (!strncmp(a, "--schema=", 9)) { if (set_value_opt(o, "--schema", a + 9)) return 1; }
		else if (!strncmp(a, "--unit=", 7)) { if (set_value_opt(o, "--unit", a + 7)) return 1; }
		else if (!strncmp(a, "--layer=", 8)) { if (set_value_opt(o, "--layer", a + 8)) return 1; }
		else if (!strncmp(a, "--set-literal=", 14)) { if (set_value_opt(o, "--set-literal", a + 14)) return 1; }
		else if (!strncmp(a, "--set-literal-default=", 22)) { if (set_value_opt(o, "--set-literal-default", a + 22)) return 1; }
		else if (!strncmp(a, "--set-default=", 14)) { if (set_value_opt(o, "--set-default", a + 14)) return 1; }
		else if (!strncmp(a, "--remove=", 9)) { if (set_value_opt(o, "--remove", a + 9)) return 1; }
		else if (!strncmp(a, "--set=", 6)) { if (set_value_opt(o, "--set", a + 6)) return 1; }
		else if (a[0] == '-' && a[1] != '\0') {
			// The suggestion is against the name half: `--stricness=1` is a typo
			// in the option, not in a spelling that includes a value.
			const char *cands[64];
			char hint[96], name[64];
			const char *eq = strchr(a, '=');
			size_t len = eq ? (size_t)(eq - a) : strlen(a);
			if (len >= sizeof name) len = sizeof name - 1;
			memcpy(name, a, len);
			name[len] = '\0';
			// Every value option is matched above, so a real name here is a flag
			// given a value. Calling it unknown would suggest it back.
			if (known_option(name)) { fprintf(stderr, "option %s takes no value (see --help)\n", name); return 1; }
			size_t n = option_names(cands, sizeof cands / sizeof cands[0]);
			suggest(hint, sizeof hint, cands, n, name);
			fprintf(stderr, "unknown option: %s%s (see --help)\n", a, hint);
			return 1;
		}
		else opt_push(&o->args, &o->nargs, a);
	}
	return 0;
}

// Child field names under a path, one per line, in file order and with
// duplicates kept. PATH may be left out to enumerate the top level. Each name
// comes out in the form a path accepts, so one holding a dot or a quote splices
// back into a path with no further work.
static int do_children(Opts *o) {
	const char *file, *path = "";
	if (o->nargs == 1) file = o->args[0];
	else if (o->nargs == 2) { file = o->args[0]; path = o->args[1]; }
	else { fprintf(stderr, "usage: shcl children [options] FILE [PATH] (see --help)\n"); return 1; }
	// The empty path is the top level here, as the library documents it.
	if (*path && refuse_read_path(path, strlen(path))) return 1;
	LayeredDoc L; int gate = load_layered(o, file, &L);
	if (gate) return gate;
	shcl_str *names = NULL;
	size_t n = shcl_children(L.doc, path, strlen(path), &names);
	for (size_t i = 0; i < n; i++) {
		shcl_str q = shcl_quote_segment(L.doc, names[i].p, names[i].n);
		fwrite(q.p, 1, q.n, stdout); putchar('\n');
	}
	layered_free(&L);
	return 0;
}

// Every field path in the document, one per line, in file order and
// deduplicated - the whole-document counterpart of do_children.
static int do_paths(Opts *o) {
	if (o->nargs != 1) { fprintf(stderr, "usage: shcl paths [options] FILE (see --help)\n"); return 1; }
	LayeredDoc L; int gate = load_layered(o, o->args[0], &L);
	if (gate) return gate;
	shcl_str *ps = NULL;
	size_t n = shcl_paths(L.doc, &ps);
	for (size_t i = 0; i < n; i++) { fwrite(ps[i].p, 1, ps[i].n, stdout); putchar('\n'); }
	layered_free(&L);
	return 0;
}

// The options each subcommand takes. check_opts judges against it, the
// per-subcommand help is cut from the full help with it, and the shell
// completions have the same table (check-completions.bash diffs the two).
static const char *const *allowed_opts(const char *cmd) {
	static const char *get_ok[] = { "--<type>", "--array", "--slots", "--unit", "--decimal", "--default", "--on-bad", "--strictness", "--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove", NULL };
	static const char *set_ok[] = { "--strictness", "--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove", "--write", "--lossy", "--no-banner", NULL };
	static const char *fmt_ok[] = { "--write", "--lossy", "--check", "--strictness", "--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove", NULL };
	static const char *check_ok[] = { "--strictness", "--schema", NULL };
	static const char *init_ok[] = { "--schema", "--no-banner", NULL };
	static const char *migrate_ok[] = { "--write", "--lossy", "--from-2x", "--check", NULL };
	static const char *upgrade_ok[] = { "--write", "--from-2x", NULL };
	static const char *enum_ok[] = { "--strictness", "--layer", "--set", "--set-literal", "--set-default", "--set-literal-default", "--remove", NULL };
	static const char *none_ok[] = { NULL };
	const char *const *allowed = none_ok;
	if (!strcmp(cmd, "get")) allowed = get_ok;
	else if (!strcmp(cmd, "set")) allowed = set_ok;
	else if (!strcmp(cmd, "fmt")) allowed = fmt_ok;
	else if (!strcmp(cmd, "check")) allowed = check_ok;
	else if (!strcmp(cmd, "init")) allowed = init_ok;
	else if (!strcmp(cmd, "migrate")) allowed = migrate_ok;
	else if (!strcmp(cmd, "upgrade")) allowed = upgrade_ok;
	else if (!strcmp(cmd, "count") || !strcmp(cmd, "instances")
	         || !strcmp(cmd, "children") || !strcmp(cmd, "paths")) allowed = enum_ok;
	return allowed;
}

// Every option must be meaningful for its subcommand; an option that would be
// silently ignored (`set --write` before it existed, `--schema` on `get`) is a
// usage error instead.
static int check_opts(const char *cmd, const Opts *o) {
	const char *const *allowed = allowed_opts(cmd);
	for (int i = 0; i < o->nseen; i++) {
		int ok = 0;
		for (int k = 0; allowed[k]; k++) if (!strcmp(o->seen[i], allowed[k])) { ok = 1; break; }
		if (!ok) {
			if (!strcmp(o->seen[i], "--<type>")) fprintf(stderr, "type options are not valid for %s (see --help)\n", cmd);
			// Deliberate, not an oversight: the schema is a program artifact, so
			// it always loads at Standard - the same rule `check --schema`
			// follows for the schema half.
			else if (!strcmp(cmd, "init") && !strcmp(o->seen[i], "--strictness"))
				fprintf(stderr, "option --strictness not valid for init: a schema always loads at standard strictness, being a program artifact rather than user data (see --help)\n");
			// The one refusal a user is likely to want anyway: check reports
			// line numbers, and a merged document has no single file to number
			// against. Naming the pipeline turns a dead end into a one-liner.
			else if (!strcmp(cmd, "check") && (!strcmp(o->seen[i], "--layer") || !strcmp(o->seen[i], "--set") || !strcmp(o->seen[i], "--set-literal")
				|| !strcmp(o->seen[i], "--set-default") || !strcmp(o->seen[i], "--set-literal-default") || !strcmp(o->seen[i], "--remove")))
				fprintf(stderr, "option %s not valid for check: diagnostics cite line numbers, which a merged document has none of. Pipe instead: shcl fmt %s ... FILE | shcl check --schema=SCHEMA -\n", o->seen[i], o->seen[i]);
			else fprintf(stderr, "option %s not valid for %s (see --help)\n", o->seen[i], cmd);
			return 1;
		}
	}
	// Options that ask for different answers used to resolve last-wins with
	// nothing said, so which answer you got depended on typing order. Two type
	// options are one case, one value option given two values the other.
	// Repeating an option with the same value competes with nothing and stays
	// allowed, and so do --layer and --set, which are ordered lists.
	if (o->clash[0]) {
		if (o->clash_opt)
			fprintf(stderr, "%s=%s cannot be combined with %s=%s (see --help)\n", o->clash_opt, o->clash[0], o->clash_opt, o->clash[1]);
		else
			fprintf(stderr, "%s cannot be combined with %s (see --help)\n", o->clash[0], o->clash[1]);
		return 1;
	}
	// --unit and --decimal say how to read a bare number, which only the
	// duration and size reads have.
	int unit_kind = !strcmp(o->kind, "duration") || !strcmp(o->kind, "size");
	if (o->unit && !unit_kind) { fprintf(stderr, "--unit needs --duration or --size (see --help)\n"); return 1; }
	if (o->decimal && strcmp(o->kind, "size") != 0) { fprintf(stderr, "--decimal needs --size (see --help)\n"); return 1; }
	if (o->unit) {
		size_t n = strlen(o->unit);
		int known = !strcmp(o->kind, "duration") ? shcl_duration_unit_of(o->unit, n) != SHCL_DURATION_NONE : shcl_size_unit_of(o->unit, n) != SHCL_SIZE_NONE;
		if (!known) { fprintf(stderr, "bad --unit value for --%s: %s (see --help)\n", o->kind, o->unit); return 1; }
	}
	// Writing back the merged document would fold the lower layers permanently
	// into the top file, which is the opposite of what layering is for. On 'set'
	// the --set values are edits to the document rather than a layer over it, so
	// persisting them is the whole point; everywhere else they stay ephemeral.
	if (o->write && o->nlayers > 0) {
		fprintf(stderr, "--write cannot be combined with --layer (see --help)\n");
		return 1;
	}
	if (o->write && o->nsets > 0 && strcmp(cmd, "set")) {
		fprintf(stderr, "--write cannot be combined with %s (see --help)\n", o->sets[0].opt);
		return 1;
	}
	// --default says "substitute this" and --on-bad=error says "fail instead",
	// so the two together are a contradiction. Each used to overwrite the
	// other's mode, which made the answer depend on the order they were typed
	// in.
	if (o->deflt && o->on_bad_arg && strcmp(o->on_bad_arg, "default") != 0) {
		fprintf(stderr, "--default cannot be combined with --on-bad=%s (see --help)\n", o->on_bad_arg);
		return 1;
	}
	// --lossy only overrides a refusal, and fmt refuses only in place, so there
	// it would read as protection the command never had. set and migrate ask
	// the gate on stdout too (2026100717500003).
	if (o->lossy && !o->write && !strcmp(cmd, "fmt")) {
		fprintf(stderr, "--lossy is only meaningful with --write (see --help)\n");
		return 1;
	}
	// On set, --no-banner shapes only the file a write creates, so without
	// --write it would be accepted and do nothing.
	if (o->no_banner && !strcmp(cmd, "set") && !o->write) {
		fprintf(stderr, "--no-banner is only meaningful with --write (see --help)\n");
		return 1;
	}
	if (o->check && o->write) {
		fprintf(stderr, "--check cannot be combined with --write (see --help)\n");
		return 1;
	}
	// The ops script already has stdin, so a layer cannot read it too.
	if (!strcmp(cmd, "set")) {
		for (int i = 0; i < o->nlayers; i++) {
			if (!strcmp(o->layers[i], "-")) {
				fprintf(stderr, "--layer=- is not valid for set: stdin already has the ops script or the document (see --help)\n");
				return 1;
			}
		}
	}
	// Stdin reads once; a second '-' would silently get an empty document.
	int stdin_uses = 0;
	for (int i = 0; i < o->nlayers; i++) if (!strcmp(o->layers[i], "-")) stdin_uses++;
	if (o->schema && !strcmp(o->schema, "-")) stdin_uses++;
	if (o->nargs > 0 && !strcmp(o->args[0], "-")) stdin_uses++;
	if (stdin_uses > 1) {
		fprintf(stderr, "'-' (stdin) can be named only once across FILE, --layer and --schema\n");
		return 1;
	}
	return 0;
}

// The informational outputs the command line asks for, each once, in the order
// first asked, into asked[4]; the count comes back. Only tokens in option
// position count: the value of a value-taking option and anything after `--`
// are data (a FILE or PATH written `-h` needs the `--` anyway, since the
// option parser would refuse it). Scanning values too once let a read of a
// missing path answer with the help text and exit 0. --about opens with the
// version line, so it covers --version.
static size_t asked_for(int argc, char **argv, const char **asked) {
	size_t n = 0;
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i], *want = NULL;
		if (!strcmp(a, "-h") || !strcmp(a, "--help")) want = "help";
		else if (!strcmp(a, "-v") || !strcmp(a, "-V") || !strcmp(a, "--version")) want = "version";
		else if (!strcmp(a, "--about")) want = "about";
		else if (!strcmp(a, "--donate")) want = "donate";
		else if (!strcmp(a, "--")) break;
		else if (!strcmp(a, "--default") || !strcmp(a, "--on-bad") || !strcmp(a, "--strictness") || !strcmp(a, "--schema") || !strcmp(a, "--unit") || !strcmp(a, "--layer") || !strcmp(a, "--set") || !strcmp(a, "--set-literal") || !strcmp(a, "--set-default") || !strcmp(a, "--set-literal-default") || !strcmp(a, "--remove")) i++;
		int seen = 0;
		for (size_t k = 0; k < n; k++) seen = seen || !strcmp(asked[k], want ? want : "");
		if (want && !seen) asked[n++] = want;
	}
	int about = 0;
	for (size_t k = 0; k < n; k++) about = about || !strcmp(asked[k], "about");
	if (about) {
		size_t kept = 0;
		for (size_t k = 0; k < n; k++) if (strcmp(asked[k], "version") != 0) asked[kept++] = asked[k];
		n = kept;
	}
	return n;
}

// The flags that ask for an informational output.
static int is_info_flag(const char *a) {
	return !strcmp(a, "-h") || !strcmp(a, "--help") || !strcmp(a, "-v") || !strcmp(a, "-V")
		|| !strcmp(a, "--version") || !strcmp(a, "--about") || !strcmp(a, "--donate");
}

static const char *const COMMANDS[] = { "get", "set", "fmt", "check", "init", "count", "instances", "children", "paths", "migrate", "upgrade", "tokens", "explain" };
static int is_command(const char *cmd) {
	for (size_t i = 0; i < sizeof COMMANDS / sizeof COMMANDS[0]; i++)
		if (!strcmp(cmd, COMMANDS[i])) return 1;
	return 0;
}


// Levenshtein distance capped at cap; past it, cap + 1. The validator has one
// of these for schema field names, but it is not public API and the CLI's
// lists are a dozen short words, so the CLI computes its own. It counts bytes
// where the other three count characters, which is why suggest() refuses a
// word that is not ASCII.
static size_t edit_distance(const char *a, const char *b, size_t cap) {
	size_t la = strlen(a), lb = strlen(b), inf = cap + 1;
	if ((la > lb ? la - lb : lb - la) > cap) return inf;
	size_t prev[64], cur[64];
	if (lb + 1 > sizeof prev / sizeof prev[0]) return inf;
	for (size_t j = 0; j <= lb; j++) prev[j] = j;
	for (size_t i = 1; i <= la; i++) {
		cur[0] = i;
		for (size_t j = 1; j <= lb; j++) {
			size_t cost = a[i - 1] == b[j - 1] ? 0 : 1;
			size_t m = prev[j] + 1;
			if (cur[j - 1] + 1 < m) m = cur[j - 1] + 1;
			if (prev[j - 1] + cost < m) m = prev[j - 1] + cost;
			cur[j] = m;
		}
		memcpy(prev, cur, (lb + 1) * sizeof prev[0]);
	}
	return prev[lb] < inf ? prev[lb] : inf;
}

static char lower_byte(char c) { return c >= 'A' && c <= 'Z' ? (char)(c + 32) : c; }

// "; did you mean 'x'?" for the nearest candidate within two edits, or an
// empty string. Same wording the validator's unknown-field suggestion uses,
// and prose either way - a typo's exit code is 1 whether or not this has an
// idea. C fills the caller's buffer where the other three return the clause.
static void suggest(char *out, size_t outsz, const char **cands, size_t ncands, const char *word) {
	out[0] = '\0';
	// Every candidate is ASCII, and this counts distance in bytes where the
	// other three count characters, so a word that is not ASCII gets no
	// suggestion rather than one the four bindings could disagree on.
	char w[64];
	size_t wl = strlen(word);
	if (wl >= sizeof w) return;
	for (size_t i = 0; i < wl; i++) {
		if ((unsigned char)word[i] >= 0x80) return;
		w[i] = lower_byte(word[i]);
	}
	w[wl] = '\0';
	const char *best = NULL;
	size_t bestd = 3;
	for (size_t i = 0; i < ncands; i++) {
		char c[64];
		size_t cl = strlen(cands[i]);
		if (cl >= sizeof c) continue;
		for (size_t j = 0; j <= cl; j++) c[j] = lower_byte(cands[i][j]);
		size_t d = edit_distance(w, c, 2);
		if (d <= 2 && d < bestd) { best = cands[i]; bestd = d; }
	}
	if (best) snprintf(out, outsz, "; did you mean '%s'?", best);
}

// Every command word, for the same. The informational flags are in the list
// too, so a word left over from 2.x, such as `version`, points at its flag.
static size_t command_names(const char **v, size_t cap) {
	static const char *const extra[] = { "help", "--version", "--about", "--donate" };
	size_t n = 0;
	for (size_t i = 0; i < sizeof COMMANDS / sizeof COMMANDS[0] && n < cap; i++) v[n++] = COMMANDS[i];
	for (size_t i = 0; i < sizeof extra / sizeof extra[0] && n < cap; i++) v[n++] = extra[i];
	return n;
}

static size_t push_unique(const char **v, size_t n, size_t cap, const char *name) {
	for (size_t i = 0; i < n; i++) if (!strcmp(v[i], name)) return n;
	if (n < cap) v[n++] = name;
	return n;
}

// Every option spelling some subcommand takes. Built from the table check_opts
// judges against, so a new option becomes suggestable the moment it is
// accepted somewhere.
static size_t option_names(const char **v, size_t cap) {
	// The informational flags are in no subcommand's table but are options to
	// anyone typing one.
	static const char *const info[] = { "--help", "--version", "--about", "--donate" };
	size_t n = 0;
	for (size_t i = 0; i < sizeof info / sizeof info[0] && n < cap; i++) v[n++] = info[i];
	for (size_t c = 0; c < sizeof COMMANDS / sizeof COMMANDS[0]; c++) {
		const char *const *a = allowed_opts(COMMANDS[c]);
		for (size_t k = 0; a[k]; k++) {
			if (!strcmp(a[k], "--<type>"))
				for (size_t t = 0; TYPE_OPTS[t]; t++) n = push_unique(v, n, cap, TYPE_OPTS[t]);
			else n = push_unique(v, n, cap, a[k]);
		}
	}
	return n;
}

// From the first line of text starting with lead to the blank line after it,
// with a blank line above. Nothing at all when no line starts with lead.
static void print_block(const char *text, const char *lead) {
	size_t ll = strlen(lead);
	for (const char *p = text; *p;) {
		const char *e = strchr(p, '\n');
		size_t n = e ? (size_t)(e - p) : strlen(p);
		if (!strncmp(p, lead, ll)) {
			putchar('\n');
			while (*p) {
				e = strchr(p, '\n');
				n = e ? (size_t)(e - p) : strlen(p);
				if (n == 0) return;
				printf("%.*s\n", (int)n, p);
				if (!e) return;
				p = e + 1;
			}
			return;
		}
		p = e ? e + 1 : p + n;
	}
}

// The option entries of the full help this subcommand takes, in the order the
// help lists them. A head line is `  --name`; the deeper-indented lines under
// it are its text, and the first line at column zero ends the block. Counted
// on the first pass and printed on the second, since the heading above them is
// only right when there is one.
static int help_options(const char *cmd, int print) {
	const char *const *allowed = allowed_opts(cmd);
	int count = 0, keep = 0, in_block = 0;
	for (const char *p = HELP; *p;) {
		const char *e = strchr(p, '\n');
		size_t n = e ? (size_t)(e - p) : strlen(p);
		if (!in_block) {
			in_block = !strncmp(p, "Options (", 9);
			p = e ? e + 1 : p + n;
			continue;
		}
		if (!strncmp(p, "  --", 4)) {
			size_t len = 2;
			while (len < n && p[len] != '=' && p[len] != ' ') len++;
			keep = 0;
			for (int k = 0; allowed[k]; k++)
				if (!strncmp(p + 2, allowed[k], len - 2) && strlen(allowed[k]) == len - 2) keep = 1;
			if (keep) count++;
		} else if (strncmp(p, "   ", 3)) break;
		if (keep && print) printf("%.*s\n", (int)n, p);
		p = e ? e + 1 : p + n;
	}
	return count;
}

// One subcommand's slice of the help: its usage entry, the type block when it
// takes one, and the option entries allowed_opts lets it have. Cut from the
// full help rather than written out a second time, so the two cannot drift and
// the four bindings stay byte-identical for free. An entry keeps the "(get)"
// style annotation it has there, which still reads true. The other three
// build the text and print it once; C prints as it goes, having no builder.
static void print_help_for(const char *cmd) {
	char want[64], lead[64];
	snprintf(want, sizeof want, "  shcl %s ", cmd);
	snprintf(lead, sizeof lead, "%s ", cmd);
	printf("Usage:\n");
	int taking = 0;
	for (const char *p = HELP; *p;) {
		const char *e = strchr(p, '\n');
		size_t n = e ? (size_t)(e - p) : strlen(p);
		if (!strncmp(p, "  shcl ", 7)) taking = !strncmp(p, want, strlen(want));
		else if (taking && strncmp(p, "   ", 3)) taking = 0;
		if (taking) printf("%.*s\n", (int)n, p);
		p = e ? e + 1 : p + n;
	}
	// A paragraph of the full help that opens with the subcommand's own name is
	// that subcommand's - today that is set's write-ops block, which is the
	// half of set a user most needs in front of them.
	print_block(HELP, lead);
	const char *const *allowed = allowed_opts(cmd);
	for (int k = 0; allowed[k]; k++)
		if (!strcmp(allowed[k], "--<type>")) { print_block(HELP, "Types ("); break; }
	if (help_options(cmd, 0) > 0) {
		printf("\nOptions (the subcommands each belongs to are in parentheses):\n");
		help_options(cmd, 1);
	} else {
		printf("\n%s takes no options.\n", cmd);
	}
	printf("\nSee 'shcl help' for the full text, and 'shcl explain CODE' for a code.\n");
}

// The subcommand a help asks about, into *topic (NULL for none). `shcl help
// CMD` names it after the word, which takes one topic at most and the
// informational flags; `shcl CMD --help` names it first. A help flag after
// `help` asks for the same thing twice, so it is no topic. An empty word is
// still a topic, as it is in the reference: `help ''` names no command, which
// is not the same as naming none. A usage error comes back as its exit code.
static int help_topic(int argc, char **argv, const char **topic) {
	*topic = NULL;
	if (argc <= 1) return 0;
	if (!strcmp(argv[1], "help")) {
		int nwords = 0;
		for (int k = 2; k < argc; k++) {
			if (is_info_flag(argv[k])) continue;
			if (nwords++ == 0) *topic = argv[k];
		}
		if (nwords > 1) { fprintf(stderr, "usage: shcl help [CMD] (see --help)\n"); return 1; }
	} else if (argv[1][0] != '-') *topic = argv[1];
	if (!*topic || !strcmp(*topic, "help")) { *topic = NULL; return 0; }
	if (is_command(*topic)) return 0;
	const char *cands[32];
	size_t n = command_names(cands, sizeof cands / sizeof cands[0]);
	char hint[96];
	suggest(hint, sizeof hint, cands, n, *topic);
	fprintf(stderr, "unknown command: %s%s (see --help)\n", *topic, hint);
	return 1;
}

// `CODE  severity  summary` - the one line both explain forms lead with.
static void code_line(const char *head) {
	const char *bar1 = strchr(head, '|');
	const char *bar2 = bar1 ? strchr(bar1 + 1, '|') : NULL;
	const char *end = strchr(head, '\n');
	if (!bar1 || !bar2 || !end) return;
	printf("%.*s  %-10.*s  %.*s\n", (int)(bar1 - head), head,
	       (int)(bar2 - bar1 - 1), bar1 + 1, (int)(end - bar2 - 1), bar2 + 1);
}

// Prints the explain entry for a retired code and returns 1, or prints
// nothing and returns 0 when the code was never one.
static int retired_entry(const char *code) {
	size_t cl = strlen(code);
	for (const char *p = RETIRED; *p;) {
		const char *e = strchr(p, '\n');
		const char *bar1 = strchr(p, '|');
		const char *bar2 = bar1 ? strchr(bar1 + 1, '|') : NULL;
		if (!e || !bar2 || bar2 > e) break;
		if ((size_t)(bar1 - p) == cl && !strncmp(p, code, cl)) {
			int sevn = (int)(bar2 - bar1 - 1), byn = (int)(e - bar2 - 1);
			const char *sev = bar1 + 1, *by = bar2 + 1;
			char head[160];
			putchar('\n');
			if (byn == 0) {
				snprintf(head, sizeof head, "%s|retired|%.*s, with no replacement\n", code, sevn, sev);
				code_line(head);
				printf("  Loads no longer report %s, and no other code took its rule.\n", code);
			} else {
				snprintf(head, sizeof head, "%s|retired|%.*s, replaced by %.*s\n", code, sevn, sev, byn, by);
				code_line(head);
				printf("  Loads no longer report %s. 'shcl explain %.*s' has the rule now.\n", code, byn, by);
			}
			putchar('\n');
			return 1;
		}
		p = e + 1;
	}
	return 0;
}

static int do_explain(const Opts *o) {
	if (o->nargs == 0) {
		printf("\nDiagnostic codes:\n\n");
		for (const char *p = CODES; *p;) {
			const char *e = strchr(p, '\n');
			if (*p != ' ') code_line(p);
			if (!e) break;
			p = e + 1;
		}
		printf("\n'shcl explain CODE' has the rule behind one of them.\n\n");
		return 0;
	}
	if (o->nargs > 1) { fprintf(stderr, "usage: shcl explain [CODE] (see --help)\n"); return 1; }
	// Heap rather than a fixed buffer: a long bogus code has to come back in
	// the message whole, the way the other three print it.
	size_t cl = strlen(o->args[0]);
	char *code = (char *)xrealloc(NULL, cl + 1);
	for (size_t i = 0; i < cl; i++) {
		char c = o->args[0][i];
		code[i] = c >= 'a' && c <= 'z' ? (char)(c - 32) : c;
	}
	code[cl] = '\0';
	// Found first, then printed: a code the table does not have prints nothing
	// at all.
	const char *head = NULL;
	for (const char *p = CODES; *p;) {
		const char *e = strchr(p, '\n');
		if (*p != ' ' && !strncmp(p, code, cl) && p[cl] == '|') { head = p; break; }
		if (!e) break;
		p = e + 1;
	}
	if (!head && retired_entry(code)) {
		free(code);
		return 0;
	}
	if (!head) {
		const char *names[64];
		size_t n = 0;
		for (const char *p = CODES; *p && n < sizeof names / sizeof names[0];) {
			const char *e = strchr(p, '\n');
			if (*p != ' ') names[n++] = p;
			if (!e) break;
			p = e + 1;
		}
		// The names are table lines, so each is compared up to its own bar.
		char cands[64][8];
		const char *cp[64];
		for (size_t i = 0; i < n; i++) {
			const char *bar = strchr(names[i], '|');
			size_t len = bar ? (size_t)(bar - names[i]) : 0;
			if (len >= sizeof cands[0]) len = sizeof cands[0] - 1;
			memcpy(cands[i], names[i], len);
			cands[i][len] = '\0';
			cp[i] = cands[i];
		}
		char hint[96];
		suggest(hint, sizeof hint, cp, n, code);
		fprintf(stderr, "unknown diagnostic code: %s%s (shcl explain lists them all)\n", code, hint);
		free(code);
		return 1;
	}
	free(code);
	putchar('\n');
	code_line(head);
	for (const char *p = strchr(head, '\n'); p && *(p + 1) == ' ';) {
		const char *e = strchr(p + 1, '\n');
		size_t n = e ? (size_t)(e - (p + 1)) : strlen(p + 1);
		printf("%.*s\n", (int)n, p + 1);
		if (!e) break;
		p = e;
	}
	putchar('\n');
	return 0;
}

#ifdef _WIN32
// The narrow argv arrives in the active code page, best-fit mapped: a name
// the page cannot encode becomes a different name, and `--write` then rewrites
// a different file. The wide command line is exact; hand it over as UTF-8,
// which is what the library's file tier expects. NULL when the conversion
// fails (nothing sensible is left to run).
static char **utf8_argv(int *argc) {
	int n = 0;
	wchar_t **wargv = CommandLineToArgvW(GetCommandLineW(), &n);
	if (!wargv) return NULL;
	char **out = (char **)calloc((size_t)n + 1, sizeof *out);
	if (!out) return NULL;
	for (int i = 0; i < n; i++) {
		int len = WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, NULL, 0, NULL, NULL);
		if (len <= 0 || !(out[i] = (char *)malloc((size_t)len))) return NULL;
		WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, out[i], len, NULL, NULL);
	}
	LocalFree(wargv);
	*argc = n;
	return out;
}
#endif

static int cli_main(int argc, char **argv) {
	setlocale(LC_ALL, "C"); // strtod/printf must use '.' regardless of environment
#ifndef _WIN32
	// The Rust, Go and Python runtimes point a standard stream that was closed
	// before the start at the null device; C's does not, so every write would
	// fail with EBADF where the other three quietly drop it - and the next
	// file opened would get fd 1 and be written over.
	for (int fd = 0; fd <= 2; fd++)
		if (fcntl(fd, F_GETFD) == -1 && errno == EBADF) {
			int nfd = open("/dev/null", fd == 0 ? O_RDONLY : O_WRONLY);
			if (nfd != fd && nfd >= 0) close(nfd);
		}
#endif
#ifdef _WIN32
	// Byte-for-byte with the reference: no CRLF translation on any stream.
	_setmode(_fileno(stdin), _O_BINARY);
	_setmode(_fileno(stdout), _O_BINARY);
	_setmode(_fileno(stderr), _O_BINARY);
	if (!(argv = utf8_argv(&argc))) { fprintf(stderr, "cannot read the command line\n"); return 1; }
#endif
	// Reject non-UTF-8 argv up front (exit 1), matching the reference; the parser
	// assumes valid UTF-8, and a garbled arg is a usage error, not a real miss.
	for (int i = 1; i < argc; i++) {
		if (!utf8_valid(argv[i], strlen(argv[i]))) {
			fprintf(stderr, "invalid argument encoding (expected UTF-8)\n");
			return 1;
		}
	}
	const char *asked[5];
	size_t nasked = asked_for(argc, argv, asked);
	// Asking for nothing at all asks for the help, and so does the `help` word,
	// which comes first on the line when it is there.
	if (argc <= 1 || !strcmp(argv[1], "help")) {
		int has = 0;
		for (size_t k = 0; k < nasked; k++) has = has || !strcmp(asked[k], "help");
		if (!has) { memmove(asked + 1, asked, nasked * sizeof asked[0]); asked[0] = "help"; nasked++; }
	}
	/* One convention: each output asked for prints once, in the order asked,
	   and the run succeeds. Blank lines go before, between and after, to set
	   the text off from the prompts around it. A lone version line is one line
	   a script reads, so it goes out bare. The topic is settled before anything
	   prints, since a bad one is a usage error with nothing on stdout. */
	if (nasked) {
		const char *topic = NULL;
		for (size_t k = 0; k < nasked; k++)
			if (!strcmp(asked[k], "help")) { int code = help_topic(argc, argv, &topic); if (code) return code; }
		if (nasked == 1 && !strcmp(asked[0], "version")) { printf("%s\n", VERSION_LINE); return 0; }
		for (size_t k = 0; k < nasked; k++) {
			putchar('\n');
			if (!strcmp(asked[k], "help")) { if (topic) print_help_for(topic); else fputs(HELP, stdout); }
			else if (!strcmp(asked[k], "version")) printf("%s\n", VERSION_LINE);
			else if (!strcmp(asked[k], "about")) fputs(ABOUT, stdout);
			else fputs(DONATE, stdout);
		}
		putchar('\n');
		return 0;
	}
	const char *cmd = argv[1];
	if (!is_command(cmd)) {
		// Before the options are judged, so a typo in the command is reported
		// as that and not as an option the wrong command cannot take.
		const char *cands[64];
		char hint[96], name[64];
		if (cmd[0] == '-' && strcmp(cmd, "--") != 0) {
			// The suggestion is against the name half: `--stricness=1` is a typo
			// in the option, not in a spelling that includes a value.
			const char *eq = strchr(cmd, '=');
			size_t len = eq ? (size_t)(eq - cmd) : strlen(cmd);
			if (len >= sizeof name) len = sizeof name - 1;
			memcpy(name, cmd, len);
			name[len] = '\0';
			size_t n = option_names(cands, sizeof cands / sizeof cands[0]);
			if (known_option(name)) {
				// It is a real option, just in front of the subcommand. Calling
				// it unknown and then suggesting the same spelling back says
				// nothing about what is actually wrong.
				fprintf(stderr, "option %s goes after the subcommand (see --help)\n", name);
			} else {
				suggest(hint, sizeof hint, cands, n, name);
				fprintf(stderr, "unknown option: %s%s (see --help)\n", cmd, hint);
			}
		} else {
			size_t n = command_names(cands, sizeof cands / sizeof cands[0]);
			suggest(hint, sizeof hint, cands, n, cmd);
			fprintf(stderr, "unknown command: %s%s (see --help)\n", cmd, hint);
		}
		return 1;
	}
	Opts o;
	if (parse_opts(argc, argv, 2, &o)) { opts_free(&o); return 1; }
	int rc;
	if (check_opts(cmd, &o)) rc = 1;
	// A value option in space form takes the next word, so `check --schema FILE`
	// leaves no FILE and the usage line alone never says where it went. Judged
	// after the options, so an option the command does not take is named as
	// that. init and explain want no FILE.
	else if (strcmp(cmd, "init") != 0 && strcmp(cmd, "explain") != 0 && o.nargs == 0 && o.swallowed_opt) {
		fprintf(stderr, "option %s took '%s' as its value, so no FILE is left; write it %s=VALUE\n",
			o.swallowed_opt, o.swallowed_value, o.swallowed_opt);
		rc = 1;
	}
	else if (!strcmp(cmd, "get")) rc = do_get(&o);
	else if (!strcmp(cmd, "set")) rc = do_set(&o);
	else if (!strcmp(cmd, "fmt")) rc = do_fmt(&o);
	else if (!strcmp(cmd, "check")) rc = do_check(&o);
	else if (!strcmp(cmd, "init")) rc = do_init(&o);
	else if (!strcmp(cmd, "count")) rc = do_enum(&o, 1);
	else if (!strcmp(cmd, "instances")) rc = do_enum(&o, 0);
	else if (!strcmp(cmd, "children")) rc = do_children(&o);
	else if (!strcmp(cmd, "paths")) rc = do_paths(&o);
	else if (!strcmp(cmd, "migrate")) rc = do_migrate(&o);
	else if (!strcmp(cmd, "upgrade")) rc = do_upgrade(&o);
	else if (!strcmp(cmd, "tokens")) rc = do_tokens(&o);
	else if (!strcmp(cmd, "explain")) rc = do_explain(&o);
	// A refusal rather than a fall-through: with one, adding a name to COMMANDS
	// without adding a branch here quietly ran whichever command the last line
	// named, with no message. main gates on COMMANDS first, so this is only
	// reachable through that mistake.
	else { fprintf(stderr, "%s: no dispatch arm (see --help)\n", cmd); rc = 1; }
	opts_free(&o);
	return rc;
}

int main(int argc, char **argv) {
	int code = cli_main(argc, argv);
	// A tail still sitting in the buffer when the work is done fails the same
	// way a write does. A reader that closed early is nothing to report -
	// nobody is there to read it - so that leaves quietly; anything else lost
	// the output, which is the same failure as a file that could not be
	// written.
	if (fflush(stdout) != 0 || ferror(stdout)) {
		if (errno == EPIPE) return 0;
		fprintf(stderr, "stdout: %s\n", strerror(errno));
		return 8;
	}
	return code;
}
