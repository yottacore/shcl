// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// SHCL reference implementation for C: parser, accessor, writer/formatter.
// Single-header, drop-in: copy this file into your tree and, in exactly ONE .c,
//   #define SHCL_IMPLEMENTATION
//   #include "shcl.h"
// Everything is byte-for-byte with the Rust reference (source/rust); the cicd
// cross-binding check compares CLI stdout + exit codes across every binding.
// The language spec lives in project/spec.md; project/conformance/ pins behavior.
// Structure deliberately mirrors the reference over C-local shortcuts, so a fix
// there ports here by mechanical diff (parity over idiom - see
// project/style-guide_code.md).
//
// The C++ interface in shcl.hpp runs on this core and is not a second parser.
// A C++ caller includes only that one, and sees none of this file.
//
// Compile-time knobs, each defined before the implementation include:
//   SHCL_NO_FILE_IO  leave the file tier out (no file I/O in the library)
//   SHCL_OOM()       what an allocation failure outside a parse does; the
//                    default prints and exits 70, which suits the CLI and
//                    nothing else. A parse or a validate never reaches it:
//                    those unwind and return NULL.
// A hook that longjmps out arms its recovery point with SHCL_SETJMP, below.

// The file tier calls POSIX (fdopen, fileno, fchmod, open, fsync, getpid). Those
// prototypes are feature-gated, and a feature request only counts before the
// first system header - so it goes here rather than beside the code needing it,
// and a consumer who already asked for a level keeps theirs.
#if !defined(SHCL_NO_FILE_IO) && !defined(_WIN32) && !defined(_POSIX_C_SOURCE)
	// Too late to ask: glibc and musl both guard features.h with _FEATURES_H, so
	// its presence here means a system header already fixed the level. Without
	// this the first symptom is "implicit declaration of function 'readlink'"
	// twenty pages down, which names nothing that leads back to include order.
	// The check cannot misfire on a build that would have worked: any level that
	// declares the POSIX calls leaves _POSIX_C_SOURCE defined, and the condition
	// above has already let that through.
	#ifdef _FEATURES_H
		#error "shcl.h has to be included before any system header, because the file tier needs POSIX prototypes and a feature-test request only counts before the first one. Move the include up, or define _POSIX_C_SOURCE 200809L (or _GNU_SOURCE) ahead of everything, or build with SHCL_NO_FILE_IO."
	#endif
	#define _POSIX_C_SOURCE 200809L
	#define _XOPEN_SOURCE 700
#endif

#ifndef SHCL_H
#define SHCL_H

#include <stddef.h>
#include <stdint.h>

// Arm a setjmp recovery point that a longjmp from inside this library has to
// reach. mingw's setjmp hands longjmp a target frame, and longjmp then unwinds
// through SEH to get there. gcc's unwind info for a function that has both a
// frame pointer and saved xmm registers puts those save slots at offsets the
// real unwinder resolves past the top of the stack, and the read faults. Wine
// resolves them from a different base and never sees it, which is why the same
// binary passes there. A NULL frame makes longjmp restore the context without
// unwinding at all, and a C recovery point needs nothing more, since nothing in
// between has a destructor or a __finally. Include <setjmp.h> before using it.
// The full shape is in project/style-guide_code.md under the C deviations.
//
// What it costs an embedder, on mingw x86_64 only: the jump skips the unwind,
// so a C++ frame between the recovery point and the failed allocation does not
// run its destructors, and a __finally block does not run either. That is
// nothing for the library's own two recovery points, and it is not nothing for
// an embedder arming one across their own frames - so on that target, keep the
// frames between the two plain, or accept the leak. Everywhere else the plain
// setjmp is in use and the unwind is the platform's ordinary one. mingw takes
// the same unwinding branch on aarch64, and nothing builds this for aarch64
// windows today; if that changes, the shape has to be measured there before
// the guard is widened rather than assumed to match.
#if defined(__MINGW32__) && defined(__x86_64__) && defined(__SEH__)
	#define SHCL_SETJMP(buf) _setjmp((buf), NULL)
#else
	#define SHCL_SETJMP(buf) setjmp(buf)
#endif

#ifdef __cplusplus
extern "C" {
#endif

// A borrowed byte string (length-delimited; text may hold NUL and is UTF-8).
typedef struct { const char *p; size_t n; } shcl_str;

typedef enum { SHCL_LOOSE, SHCL_STANDARD, SHCL_STRICT } shcl_strictness;
typedef enum { SHCL_SEV_ERROR, SHCL_SEV_HINT } shcl_severity;

// Read status sentinels. Empty is informational - the empty value still returns.
typedef enum {
	SHCL_GOOD, SHCL_EMPTY, SHCL_NOT_FOUND, SHCL_BAD_TYPE, SHCL_MULTIPLE
} shcl_status;

// Why a write would fail (shcl_write_reason_()): the distinctions behind a
// setter's bare 0. SHCL_W_WRITABLE = the path passes the writer's validation;
// the rest name the five ways it cannot.
typedef enum {
	SHCL_W_WRITABLE,
	SHCL_W_BAD_PATH,      // empty path, or the scanner rejected it
	SHCL_W_VALUE_IN_PATH, // the path has a `: value` part; writes take values separately
	SHCL_W_WILDCARD,      // wildcard selectors are query-only
	SHCL_W_NO_SUCH_INDEX, // a `[#k]` instance that does not (and can never) exist
	SHCL_W_TOO_DEEP       // deeper than the nesting cap; the writer never creates past it
} shcl_write_reason;

typedef struct shcl_doc shcl_doc;

// Local (floating) date/time unless a zone suffix was present. has_* fields say
// which parts were written; format via shcl_datetime_str.
typedef enum { SHCL_ZONE_NONE, SHCL_ZONE_UTC, SHCL_ZONE_OFFSET } shcl_zone_kind;
typedef struct {
	int has_date; int32_t year; uint32_t month; uint32_t day;
	int has_time; uint32_t hour; uint32_t minute; int has_sec; uint32_t sec;
	int has_frac; shcl_str frac;      // fractional-second digits, as typed
	shcl_zone_kind zone; int32_t off_min;
} shcl_datetime;

typedef struct { int64_t value;  shcl_status status; } shcl_read_i64;
typedef struct { double  value;  shcl_status status; } shcl_read_f64;
typedef struct { int     value;  shcl_status status; } shcl_read_bool;
typedef struct { shcl_str value; shcl_status status; } shcl_read_str;
typedef struct { shcl_datetime value; shcl_status status; } shcl_read_dt;

// Array results also give one status per slot (element, or wildcard instance)
// in statuses[0..n); status is then the worst slot. NULL on whole-path errors.
typedef struct { int64_t *values; size_t n; shcl_status status; const shcl_status *statuses; } shcl_read_i64_arr;
typedef struct { double  *values; size_t n; shcl_status status; const shcl_status *statuses; } shcl_read_f64_arr;
typedef struct { int     *values; size_t n; shcl_status status; const shcl_status *statuses; } shcl_read_bool_arr;
typedef struct { shcl_str *values; size_t n; shcl_status status; const shcl_status *statuses; } shcl_read_str_arr;
typedef struct { shcl_datetime *values; size_t n; shcl_status status; const shcl_status *statuses; } shcl_read_dt_arr;

// Maximum nesting depth (levels below the document root), enforced at load and
// by the Writer. Deeper lines are skipped with an E016 error. The cap is what
// keeps the recursive tree walks (emit, merge, clone) safely inside every
// binding's stack, so a hostile or machine-generated document can make a load
// fail but never crash the consumer.
#define SHCL_MAX_DEPTH ((size_t)512)

// How much of a file's own name the temporary file beside it borrows, in bytes.
#define SHCL_TMP_NAME_BYTES ((size_t)64)

// A parse never fails on the document's account: bad lines are skipped and
// diagnosed. It returns NULL only when an allocation failed, which is the one
// thing it cannot work around - the process is left standing either way. Text
// need not be NUL terminated. Free with shcl_free.
shcl_doc *shcl_parse(const char *text, size_t len);
shcl_doc *shcl_parse_with(const char *text, size_t len, shcl_strictness s);
// Parse with resource caps beside the strictness: max_nodes stops the parse
// once a line takes the node count past it (one E020 error; the unparsed
// remainder counts as lost), max_elements refuses any line whose array would
// hold more elements (E021, that line alone skipped), max_diags lists only
// that many diagnostics and ends the list with one E022 counting the rest
// (an error whenever an unlisted one was, so the strict gate still fails).
// 0 disables a cap.
shcl_doc *shcl_parse_limited(const char *text, size_t len, shcl_strictness s, size_t max_nodes, size_t max_elements, size_t max_diags);
void shcl_free(shcl_doc *d);

// True when a strict load would fail (strictness==strict and an error diagnostic
// exists). At loose/standard this is always false.
int shcl_strict_failed(const shcl_doc *d);
shcl_strictness shcl_strictness_of(const shcl_doc *d);

// Diagnostics, in emission order (parse-time diagnostics, then repeated-leaf hints).
size_t shcl_diag_count(const shcl_doc *d);
size_t shcl_diag_line(const shcl_doc *d, size_t i);
shcl_severity shcl_diag_severity(const shcl_doc *d, size_t i);
shcl_str shcl_diag_message(const shcl_doc *d, size_t i);
// Stable machine code (E001.., H001..) identifying the diagnostic kind - the
// contract; the message prose is a free, per-binding voice. NUL-terminated.
const char *shcl_diag_code(const shcl_doc *d, size_t i);
// How many lines or values parsing dropped that canonical output cannot
// re-emit - bad indentation, an unusable selector, a line past the depth cap.
// Content-malformed lines do NOT count: those are retained as trivia and
// survive a save. Nonzero means a save would delete hand-written content, so
// shcl_save_file refuses then (shcl_save_file_lossy overrides), and
// shcl_save_file_keep_lines does when it cannot keep the lines. It also counts
// lines the load kept as written that an edit took and design.md's kept-lines
// table does not let it take.
size_t shcl_lost_count(const shcl_doc *d);
// How many error-severity diagnostics the document has - the "did this
// file have errors?" predicate, so recover-and-continue can't read as success
// by accident. Counts whatever the shcl_diag_* accessors hold (after
// shcl_load_and_validate, that includes validation errors).
size_t shcl_error_count(const shcl_doc *d);

// Schema validation (spec.md "Schema validation"): check d against a schema
// document (itself plain SHCL). Zero diagnostics = the document conforms.
// Diagnostic lines are document lines (0 = document scope); schema faults
// (V09x, schema-file lines) come first, and the surviving constraints still
// check the document. The unknown-field sweep runs too, unless a fault cost
// the schema a path spelling (an unreadable `field:` path, or a mount naming
// no declared fragment) - only those can turn declared fields into false
// unknowns; a key-level fault keeps its entry's chain. The result owns copies
// of all its strings - free with shcl_validation_free.
// The H001/H002 hints a schema disavows are NOT dropped by this call: they live
// on the parse's diagnostics, which validation does not touch. Parse then
// validate and they are still there - call shcl_suppress_declared_repeats /
// shcl_suppress_declared_reopens yourself, or use shcl_load_and_validate,
// which runs both for you.
// NULL only when an allocation failed.
typedef struct shcl_validation shcl_validation;
shcl_validation *shcl_validate(shcl_doc *d, shcl_doc *schema);
size_t shcl_validation_count(const shcl_validation *v);
size_t shcl_validation_line(const shcl_validation *v, size_t i);
shcl_severity shcl_validation_severity(const shcl_validation *v, size_t i);
shcl_str shcl_validation_message(const shcl_validation *v, size_t i);
const char *shcl_validation_code(const shcl_validation *v, size_t i);
void shcl_validation_free(shcl_validation *v);

// Drop the H001 hints a schema disavows: a field whose declared repeat upper
// bound is above 1 repeats BY DESIGN (repetition is its instance mechanism),
// so the repeated-bare-leaf hint is structurally a false positive there and
// trains users to ignore hints. Matching is by leaf name - the filter
// consumers were hand-rolling - which errs toward quiet, for a hint. Used by
// `check --schema` and shcl_load_and_validate; call it wherever doc
// diagnostics and a schema meet. Compacts doc's own diagnostic list in place
// (the C spelling of filtering a caller-held list).
void shcl_suppress_declared_repeats(shcl_doc *schema, shcl_doc *doc);

// Sibling for H002: drop the merge hints a schema disavows via `reopen: true`
// on a section's entry - a section meant to be written in parts. Same leaf-name
// matching and in-place compaction as shcl_suppress_declared_repeats.
void shcl_suppress_declared_reopens(shcl_doc *schema, shcl_doc *doc);

// One-shot load-and-validate: parse at a strictness, validate against a
// schema, and hand back a document whose shcl_diag_* accessors serve ONE
// combined list (parse first, then validation - the order `check --schema`
// prints), so half the errors can't vanish because a caller forgot one of the
// two lists. Fails only on an allocation, and then it is NULL: a strict-failing
// document comes back as the document plus its diagnostics (shcl_error_count
// answers "did it fail"). An
// empty schema text skips validation entirely. H001 hints the schema disavows
// (a declared repeat upper bound above 1) are dropped. Free with shcl_free.
shcl_doc *shcl_load_and_validate(const char *text, size_t len, const char *schema, size_t slen, shcl_strictness s);

// File tier (optional companion; compile out with -DSHCL_NO_FILE_IO to keep
// the core free of file I/O). Paths are UTF-8 on every platform: on windows
// they are widened for the file calls rather than read in the active code
// page, so a program's own main() has to hand over UTF-8 too (the wide
// command line, not the narrow argv). Load does not fail on the file's account: the
// document always comes back usable (empty when the file could not be read),
// and the status out-param (may be NULL) separates the four cases a consumer's
// own load path otherwise confuses. NULL means an allocation failed, as for a
// parse. Save writes the canonical text through a temp file in
// the same directory plus a rename - the same mechanics the CLI's --write
// uses - so an interrupted save can never truncate the config it rewrites.
// On windows a failed save can leave nothing at the path, when the old file was
// moved aside and could not be put back. The other bindings' errors name the
// two files then; here errno is all there is, so: the old file is
// .NAME.bakPID.N and the new text .NAME.tmpPID.N, beside the target.
#ifndef SHCL_NO_FILE_IO
typedef enum {
	SHCL_FILE_CLEAN,      /* read and parsed, no error diagnostics (hints allowed) */
	SHCL_FILE_HAD_ERRORS, /* read and parsed, but error diagnostics are present */
	SHCL_FILE_NOT_FOUND,  /* no file at the path */
	SHCL_FILE_UNREADABLE  /* exists but could not be read (permissions, a directory, bad encoding, past a shcl_read_file cap) */
} shcl_file_status;
/* Save refuses while the load dropped content the write would silently delete
   (shcl_lost_count); shcl_save_file_lossy is the override, and is the only way
   to write then. The two failures are separate values rather than one falsey
   answer because they need different handling: a refusal is the caller's to
   reverse, a write failure is the disk's answer with errno describing it. */
typedef enum {
	SHCL_SAVE_OK,      /* written */
	SHCL_SAVE_REFUSED, /* the lost-content gate fired; lossy overrides */
	SHCL_SAVE_FAILED   /* the write itself failed; errno describes it */
} shcl_save_result;
// Textual name of a file status, the shcl_status_name of this enum, so
// logging one reads as a case rather than a number. NUL-terminated, static.
const char *shcl_file_status_name(shcl_file_status s);
shcl_doc *shcl_load_file(const char *path, shcl_file_status *status);
shcl_doc *shcl_load_file_with(const char *path, shcl_strictness s, shcl_file_status *status);
// The read half on its own: the file's text, malloc'd and NUL-terminated (the
// caller frees it), with *len set; or NULL with the status saying why. A file
// past max_bytes is unreadable; 0 is no cap.
char *shcl_read_file(const char *path, size_t max_bytes, size_t *len, shcl_file_status *status);
shcl_save_result shcl_save_file(shcl_doc *d, const char *path);
shcl_save_result shcl_save_file_lossy(shcl_doc *d, const char *path);
int shcl_write_file_atomic(const char *path, const char *data, size_t n);
// shcl_load_file_with, keeping the text for shcl_to_text_keep_lines.
shcl_doc *shcl_load_file_keep_lines(const char *path, shcl_strictness s, shcl_file_status *status);
// shcl_save_file with shcl_to_text_keep_lines: *kept (when not NULL) is 1 when
// it kept the lines, 0 when it wrote the canonical form instead. A line the
// load dropped comes back as written when the lines are kept, so this refuses
// the way shcl_save_file does only when it would write canonical.
shcl_save_result shcl_save_file_keep_lines(shcl_doc *d, const char *path, int *kept);
#endif

// Schema-driven generation (`shcl init --schema`): a commented, typed starter
// config from a schema document. Required paths are live (their `default`, or an
// empty value); optional paths are commented out; wildcard paths are listed in a
// trailing comment block. Prose the generator writes is `##` and a commented-out
// setting is `# `, so the two read apart; both are ordinary comments to the
// language, and nothing reads them back. A path whose last segment selects by
// value is written without that selector when it has a `default`, since a value
// after the selector would be ignored: `env[prod]` with `default: prod` is
// `env: prod`. The output loads clean and validates clean against the
// schema that produced it, both checked against the finished text, so a line
// that does not load, or a schema whose own `default` breaks its field's
// constraints, is a fault (V097) instead of a starter config that fails the
// first time it is checked; the faults go onto the schema document's
// diagnostics. A footer naming the format and pointing at the spec is
// written last unless no_banner; the flag is negative so passing 0 writes the
// footer. *ok is set to 1 on success, 0 if the schema has faults (V09x) - then
// the returned string is empty and nothing was kept. Bytes live in the schema's
// read arena; valid until shcl_free, or until shcl_reads_release. Generation
// faults from an earlier call on the same schema are dropped first, so the list
// describes this call; the schema's own diagnostics stay. A failed allocation
// goes to SHCL_OOM, as for any other call on a built document, once the call
// has given back what it held; it never returns text the self-check did not
// read.
shcl_str shcl_generate(shcl_doc *schema, int no_banner, int *ok);

// The info block shcl_generate writes at the bottom unless no_banner. Public
// because a program that creates a config file of its own writes the same
// block, and a second copy of a byte-for-byte contract drifts.
#define SHCL_GEN_BANNER \
	"##\n" \
	"## This config file format is SHCL.\n" \
	"## \"Simple Hierarchical Config Language\"\n" \
	"##    Format   3\n" \
	"##    Home     https://github.com/yottacore/shcl\n" \
	"##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md\n" \
	"##    Legal    SHCL is Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.\n" \
	"##\n"

// Canonical form (block layout, tabs, insertion order, minimal quoting). The
// returned bytes live in the document's read arena; valid until shcl_free, or
// until shcl_reads_release. The
// bytes may contain NUL - never hand them to a strlen-based API.
shcl_str shcl_to_canonical(shcl_doc *d);
// shcl_parse_with, keeping a copy of the text for shcl_to_text_keep_lines. The
// document is the same one shcl_parse_with gives; only that save differs.
shcl_doc *shcl_parse_keep_lines(const char *text, size_t len, shcl_strictness s);
// The text a save that keeps lines writes, and in *kept (when not NULL) whether
// it kept them. Each line the edits did not touch is the loaded text's own
// line, byte for byte; a changed value is written into its line; new lines are
// indented the way the lines around them are. The result has to reload as this
// document. When it does not, or the document was not loaded with
// shcl_parse_keep_lines or shcl_load_file_keep_lines, or it took a merge, this
// is shcl_to_canonical and *kept is 0. Same lifetime as shcl_to_canonical.
shcl_str shcl_to_text_keep_lines(shcl_doc *d, int *kept);

// Instance count at a path (0 when nothing matches).
size_t shcl_count(shcl_doc *d, const char *path, size_t plen);
// Instance display values, in file order. Writes an arena-owned array to *out.
size_t shcl_instances(shcl_doc *d, const char *path, size_t plen, shcl_str **out);
// 1-based source line of the binding at a path, for consumer checks the
// schema cannot express. 0 when the path does not resolve to exactly one
// node, or the node was writer-built. Merged instances cite the first
// binding's line, matching diagnostics.
size_t shcl_line(shcl_doc *d, const char *path, size_t plen);
// 1 when the single scalar value at a path was quoted in the source, so a
// consumer can tell a quoted plain string from a bare word that happens to
// spell a reserved one - `mode: "on"` against `mode: on`. 0 for anything that
// is not one scalar element (empty, a raw block, an array, an unresolved or
// ambiguous path). A written value counts as quoted when a save would quote
// it. Sits beside shcl_line rather than in the read structs for the same
// reason the raw text does: C keeps those two fields wide.
int shcl_quoted(shcl_doc *d, const char *path, size_t plen);

// The field name at a path exactly as the author wrote it (case unfolded,
// outer quotes stripped), so a message can echo SYMBOLS when the file said
// SYMBOLS. Escape sequences stay as written too: a name is stored, compared
// and emitted with its escapes RESOLVED, so this is the one call that hands the
// source spelling back - which is what an as-authored accessor is for.
// Resolution mirrors shcl_line: empty when the path does not resolve to
// exactly one node. Merged instances keep the first binding's spelling; a
// writer-built node keeps the spelling the setter's path used.
// Borrowed from the document's own arena, so it outlives shcl_reads_release and
// is valid until shcl_free or shcl_compact - the name is stored, not built.
shcl_str shcl_authored_name(shcl_doc *d, const char *path, size_t plen);
// The plural shcl_line: 1-based source lines at a path, in file order, so a
// repeated field - the case that most wants a citable line - yields every
// binding's. Wildcard slots that did not resolve stay in the list as 0, and a
// writer-built node is 0, so indices keep matching shcl_count. Writes an
// arena-owned array to *out.
size_t shcl_lines(shcl_doc *d, const char *path, size_t plen, size_t **out);
// Child field names under a path, in file order, duplicates included - the
// "what keys are in this section?" question shcl_paths (deduplicated,
// path-shaped) cannot answer. An empty or whitespace-only path enumerates the
// top level. A path with several instances lists the children of each in
// turn, the way a dotted path reaches all of them. Names come back as stored;
// shcl_quote_segment makes one splice-safe in a path. Writes an arena-owned
// array to *out.
size_t shcl_children(shcl_doc *d, const char *path, size_t plen, shcl_str **out);
// Every field path in the document, in file order, deduplicated - a query
// recipe for tooling. A segment that is not bare-name-safe is emitted quoted
// and escaped - the form the path scanner accepts - so each path is a
// well-formed lookup path and nothing in the document is hidden. Returns the
// count; *out stays valid until shcl_free, or until shcl_reads_release.
size_t shcl_paths(shcl_doc *d, shcl_str **out);
// shcl_paths one instance at a time: every binding's path in file order, with
// `[#i]` on each segment whose name repeats under its parent, so each path
// reads exactly one node and a repeated block is walked instance by instance.
// Segments are written as shcl_paths writes them. Returns the count; *out
// stays valid until shcl_free, or until shcl_reads_release.
size_t shcl_instance_paths(shcl_doc *d, shcl_str **out);
// Quote one path segment so it can be spliced into a lookup path: a bare name
// passes through, anything else comes back quoted and escaped in the form the
// path scanner accepts. Splicing user-typed text into a path without this is
// path injection - a dotted name silently reads as nesting. Same spelling
// shcl_paths and the canonical emitter produce. Result lives in the
// document's read arena; valid until shcl_free, or until shcl_reads_release.
shcl_str shcl_quote_segment(shcl_doc *d, const char *name, size_t len);

shcl_read_i64  shcl_read_int(shcl_doc *d, const char *path, size_t plen);
shcl_read_f64  shcl_read_float(shcl_doc *d, const char *path, size_t plen);
shcl_read_bool shcl_read_bool_(shcl_doc *d, const char *path, size_t plen);
shcl_read_dt   shcl_read_datetime(shcl_doc *d, const char *path, size_t plen);
shcl_read_str  shcl_read_string(shcl_doc *d, const char *path, size_t plen);
shcl_read_str  shcl_read_raw(shcl_doc *d, const char *path, size_t plen);
shcl_read_str  shcl_read_raw_info(shcl_doc *d, const char *path, size_t plen);

// The unit a duration or size read gives a bare number, when the field name
// gives none; the NONE value asks for none. SHCL_SIZE_KB to SHCL_SIZE_TB are
// powers of 1024 unless the read asks for decimal; KIB to TIB always are.
typedef enum { SHCL_DURATION_NONE, SHCL_DURATION_MS, SHCL_DURATION_S, SHCL_DURATION_M, SHCL_DURATION_H, SHCL_DURATION_D } shcl_duration_unit;
typedef enum { SHCL_SIZE_NONE, SHCL_SIZE_B, SHCL_SIZE_KB, SHCL_SIZE_MB, SHCL_SIZE_GB, SHCL_SIZE_TB, SHCL_SIZE_KIB, SHCL_SIZE_MIB, SHCL_SIZE_GIB, SHCL_SIZE_TIB } shcl_size_unit;
// The unit a value spelling names (ms s m h d; B KB kB MB GB TB KiB MiB GiB
// TiB, letter case read), or the NONE value; and the spelling back, "" for
// NONE. Static strings.
shcl_duration_unit shcl_duration_unit_of(const char *s, size_t n);
shcl_size_unit shcl_size_unit_of(const char *s, size_t n);
const char *shcl_duration_unit_spelling(shcl_duration_unit u);
const char *shcl_size_unit_spelling(shcl_size_unit u);
// A duration in whole milliseconds: `500ms`, `30s`, `1h 30m`, `2d`. A bare
// number takes its unit from the field name when the name ends in one
// (`timeout-ms`, `delay_seconds`), else from unit, and is BAD_TYPE with
// neither. A size in whole bytes the same way: `512MB`, `1.5 GiB`.
shcl_read_i64  shcl_read_duration(shcl_doc *d, const char *path, size_t plen, shcl_duration_unit unit);
shcl_read_i64  shcl_read_size(shcl_doc *d, const char *path, size_t plen, shcl_size_unit unit, int decimal);

shcl_read_i64_arr  shcl_read_int_array(shcl_doc *d, const char *path, size_t plen);
shcl_read_f64_arr  shcl_read_float_array(shcl_doc *d, const char *path, size_t plen);
shcl_read_bool_arr shcl_read_bool_array(shcl_doc *d, const char *path, size_t plen);
shcl_read_dt_arr   shcl_read_datetime_array(shcl_doc *d, const char *path, size_t plen);
shcl_read_str_arr  shcl_read_string_array(shcl_doc *d, const char *path, size_t plen);

// Copy-out reads, for a caller that keeps what it reads and would rather not
// have to call shcl_reads_release. Each leaves the read arena as it found it.
// shcl_read_string_to writes at most cap - 1 bytes and a NUL, like snprintf,
// and sets *len to the whole length, so *len >= cap means the buffer was
// short. The value can hold a NUL, so go by *len. A plain single-string read
// never needed this; one of an array's joined text did.
// The array forms copy the first cap values into out, and the per-slot
// statuses into slots unless it is NULL, and set *n to the whole count, so
// *n > cap means the buffers were short. A string element, and a datetime's
// fraction digits, point into the document itself, valid until shcl_free or
// shcl_compact, not into the read arena. The return is the status the plain
// read gives.
shcl_status shcl_read_string_to(shcl_doc *d, const char *path, size_t plen, char *buf, size_t cap, size_t *len);
shcl_status shcl_read_int_array_to(shcl_doc *d, const char *path, size_t plen, int64_t *out, shcl_status *slots, size_t cap, size_t *n);
shcl_status shcl_read_float_array_to(shcl_doc *d, const char *path, size_t plen, double *out, shcl_status *slots, size_t cap, size_t *n);
shcl_status shcl_read_bool_array_to(shcl_doc *d, const char *path, size_t plen, int *out, shcl_status *slots, size_t cap, size_t *n);
shcl_status shcl_read_datetime_array_to(shcl_doc *d, const char *path, size_t plen, shcl_datetime *out, shcl_status *slots, size_t cap, size_t *n);
shcl_status shcl_read_string_array_to(shcl_doc *d, const char *path, size_t plen, shcl_str *out, shcl_status *slots, size_t cap, size_t *n);

// Give back everything the read calls have handed out. Every result from a read
// - shcl_read_*, shcl_children, shcl_paths, shcl_instance_paths, shcl_comments, shcl_instances, shcl_lines,
// shcl_quote_segment, shcl_to_canonical, shcl_generate - is invalid after this; the document itself is untouched
// and stays readable, so the next read works normally. Optional: leave it alone
// and results live until shcl_free, which is the documented contract and what a
// read-once consumer wants. A process polling the same document in a loop calls
// it between passes so the memory does not climb.
// It levels off rather than going to zero: the largest block stays, so the next
// pass writes into it instead of asking the system again. The resting cost
// after this call is therefore the size of the biggest single result the
// process has ever taken - a shcl_to_canonical of a 100 MiB document leaves
// about that much held until shcl_free.
void shcl_reads_release(shcl_doc *d);
// The write-side counterpart. A write goes into a bump arena and the value it
// replaced stays there until shcl_free, so a process rewriting one field in a
// loop grows by a few dozen bytes per write, and a removed node's storage goes
// the same way. A merge is the case that makes this matter: folding a layer
// rebuilds every parent it touches, so a process merging in a loop grows by
// hundreds of kilobytes a call, not dozens of bytes.
// Compaction rebuilds the document into fresh arenas holding only what it now
// contains - same content, same diagnostics, same lost count, same strictness -
// and gives the old ones back.
// Every read result is invalid after it, as after shcl_reads_release. Optional,
// for a long-running writer; a write-once consumer never needs it. On an
// allocation failure the document is left as it was.
void shcl_compact(shcl_doc *d);

// Convenience tier: the value, or the call-site fallback unless the read is Good
// - so a missing/empty/bad/ambiguous read cannot masquerade as a real zero. The
// string/datetime/raw and array reads keep the shcl_read_* status tier above.
int64_t shcl_get_int(shcl_doc *d, const char *path, size_t plen, int64_t def);
double  shcl_get_float(shcl_doc *d, const char *path, size_t plen, double def);
int     shcl_get_bool(shcl_doc *d, const char *path, size_t plen, int def);
// The same three under the cross-binding spelling: `_or` means "with a
// fallback" in every binding, so a routine ported between two of them cannot
// keep the call name while changing which tier it uses.
int64_t shcl_get_int_or(shcl_doc *d, const char *path, size_t plen, int64_t def);
int64_t shcl_get_duration_or(shcl_doc *d, const char *path, size_t plen, shcl_duration_unit unit, int64_t def);
int64_t shcl_get_size_or(shcl_doc *d, const char *path, size_t plen, shcl_size_unit unit, int decimal, int64_t def);
double  shcl_get_float_or(shcl_doc *d, const char *path, size_t plen, double def);
int     shcl_get_bool_or(shcl_doc *d, const char *path, size_t plen, int def);

// --- Tokenizer: a line's lexical spans, and the 2.x migration ---------------
// The one reader of a line's parts, made public so a tool can see the spans
// the parser sees (`shcl tokens`). Every field is a byte offset into the text
// that was tokenized; nothing is copied. A piece is quoted only when its first
// character is a quote and the matching quote is the last thing before the
// piece ends; SHCL_QUOTE_OPEN is a piece that began with a quote it never
// closed, kept literally, quotes and all.
typedef enum { SHCL_QUOTE_NONE, SHCL_QUOTE_SINGLE, SHCL_QUOTE_DOUBLE, SHCL_QUOTE_OPEN } shcl_quote;
// One piece of the text: byte offsets of its content. For a quoted piece the
// quotes sit just outside the span; for an open or bare piece the span is
// the trimmed text itself.
typedef struct { size_t start, end; shcl_quote quote; } shcl_piece;
// One path segment: its name, an optional `[selector]` body, and whether the
// name was the bare `*` wildcard (lookups only).
typedef struct { shcl_piece name; shcl_piece selector; int has_selector; int star; } shcl_seg_tok;
// The spans of one line, or of one lookup path. Each call clears and reuses
// it, and the two arrays grow in the read arena of the document passed on
// that call. Zero it before its first use, before handing it a different
// document, and after shcl_free, shcl_compact or shcl_reads_release on the one
// it last used; the arrays die with that arena. cap is the caller's element cap (0 = none):
// the scan stops as soon as the value holds more elements than this, and
// capped says it did, with elements then incomplete. cap is kept across calls.
typedef struct {
	shcl_seg_tok *segments; size_t nseg;
	int has_sep; size_t sep;          // the separator (`:` on a line, `=` in --set); none when the path ran to the end or into a comment
	size_t value_start, value_end;    // everything after the separator up to the comment, trimmed
	shcl_piece *elements; size_t nelem; // the value's comma-separated pieces, empty ones included, each trimmed
	int has_comment; size_t comment;  // the `#` that opens a trailing comment
	int has_fault; size_t fault_at; const char *fault_why; // where the path stopped making sense, and why (E014 as a whole)
	size_t cap; int capped;
	size_t seg_cap, elem_cap;         // storage bookkeeping
	const void *arena;                // the read arena the two arrays live in
} shcl_tokens;
// Which spelling the tokenizer reads: the current rules, or the 2.x rules for
// shcl_migrate only.
typedef enum { SHCL_RULES_CURRENT, SHCL_RULES_V2 } shcl_rules;
// Tokenize one line (sep ':') or one lookup path (path: the bare `*` name
// wildcard is admitted, and a `#` in a selector body is the `[#N]` index
// rather than a comment); text is the line after its indent, or the path.
void shcl_tokenize(shcl_doc *d, const char *text, size_t len, char sep, int path, shcl_rules rules, shcl_tokens *out);
// The value half alone: everything from `from` on, split into pieces, with
// the comment found on the way.
void shcl_tokenize_value(shcl_doc *d, const char *text, size_t len, size_t from, shcl_rules rules, shcl_tokens *out);
// How many elements the value holds: a quoted piece counts even when empty
// ("" is a real element), an empty bare slot does not.
size_t shcl_tokens_element_count(const shcl_tokens *t);
// The format major the info block names. It moves with the format, not with
// the header: a file says which rule set it was written for, and nothing else
// does. SHCL_FORMAT_LINE_HEAD is what shcl_migrate matches to find the line,
// so a later major can still read an older file's number. The banner's Syntax
// link names the tag that opened this major, and moves with it.
#define SHCL_FORMAT_MAJOR 3
#define SHCL_FORMAT_LINE_HEAD "##    Format   "
#define SHCL_FORMAT_LINE "##    Format   3"
#define SHCL_MIGRATED_LINE "##    Migrated from SHCL 2.x."
// The start of a line naming the file's schema, written like the Format line,
// for check and for editors: `##    Schema   ./app.schema.shcl`.
#define SHCL_SCHEMA_LINE_HEAD "##    Schema   "

// What shcl_migrate produced, and what it could not keep. text is
// malloc'd and NUL-terminated, the caller frees it, len is its length, and it
// may hold NUL if the input did. current: the file already names its format,
// so there was nothing to migrate and text is the input. ambiguous: pieces the
// two rule sets read differently and nothing can decide between, left as
// written; always 0 when from_v2 said the file is 2.x. lost: lines 2.x bound a
// value on that nothing binds now - bracket text after the colon, or a line
// break in a value that starts like a Windows path.
typedef struct { char *text; size_t len; int current; size_t ambiguous; size_t lost; } shcl_migration;

// Rewrite a document written under the 2.x lexical rules so this parser reads
// the same tree; everything the two rule sets agree on comes through as
// written. from_v2 says the file really is 2.x, which is the only thing that
// can settle the spellings the two rule sets read differently.
// An allocation failure inside it frees its own working memory before SHCL_OOM
// runs, so a hook that longjmps out is not left holding the two arenas.
shcl_migration shcl_migrate(const char *text, size_t len, int from_v2);
// shcl_migrate without the version line or the migrated note, for a program
// that writes SHCL_GEN_BANNER itself, which includes the version line. The
// next run can tell the result is current only once that is written.
shcl_migration shcl_migrate_unstamped(const char *text, size_t len, int from_v2);
// The format major a document's `##    Format   N` line names, read the way
// shcl_migrate reads it, or -1 when no line names one, which is every 2.x file
// and a current one written without the info block. shcl_migrate hands a file
// back untouched exactly when this is SHCL_FORMAT_MAJOR or more, so a program
// can ask before it rewrites anything. Digits past 32 bits read as
// SHCL_FORMAT_MAJOR, since whatever wrote them was not 2.x.
int64_t shcl_format_version(const char *text, size_t len);
// The schema a document's `##    Schema   REF` line names: a path, or a URL
// for an editor to fetch, as a pointer into text with its length in *ref_len.
// NULL when no line names one. The first such line wins, and one inside a raw
// body is that block's content, as with the Format line. Either line may be
// indented, since the formatter indents a comment to the field below it. A
// relative path is the caller's to resolve, from the config file's directory.
const char *shcl_schema_ref(const char *text, size_t len, size_t *ref_len);

// --- Writer: typed emit, defaults, comments, structural edits ---------------
// The reverse of the reads. Each setter builds the canonical stored text for a
// typed value and places it at a path (creating intermediate nodes). New values
// are copied into the arena, so the caller's buffers need not outlive the call.
// Setters return 1 when the write applied, 0 when the path is unusable
// (wildcard, missing [#N] instance, a value part, or past the depth cap) or
// the value has no spelling the reader accepts (a non-finite float, a datetime
// the reader would refuse, a raw info-string holding a `#`) - nothing is
// created on failure. _default forms return 1 when already present.
// Worth checking rather than assuming: an ignored 0 means the save that follows
// writes a document missing the edit, and reports success doing it.
shcl_doc *shcl_new(void); // an empty document (start point for generation), or NULL on an allocation failure
int shcl_exists(shcl_doc *d, const char *path, size_t plen);       // 0/1
// Lines kept as written beside a node stay where they were, and a field opened
// only by the lines under it goes with the last of them. A removed node's
// storage is not reclaimed until shcl_compact or shcl_free.
size_t shcl_remove(shcl_doc *d, const char *path, size_t plen);    // count deleted
int shcl_set_comment(shcl_doc *d, const char *path, size_t plen, const char *text, size_t tlen);
// The comment lines above the node(s) at a path, the ones shcl_clear_comments
// takes, in file order, each from its `#` on. A program can tell its own
// comment from one a user wrote there, and shcl_set_comment puts a line it gave
// back as it was. Returns the count, 0 when the path reaches nothing; *out
// stays valid until shcl_free, or until shcl_reads_release.
size_t shcl_comments(shcl_doc *d, const char *path, size_t plen, shcl_str **out);
// Take off the comment lines above the node(s) at a path, the ones
// shcl_set_comment adds to, so a comment can be replaced rather than stacked.
// Those are the lines the load put between the node and the binding line
// before it, so a heading written for a group of fields goes too. A comment on
// the node's own line stays, and so does a line kept as written for being
// malformed. Returns how many lines came off, 0 when the path reaches nothing.
size_t shcl_clear_comments(shcl_doc *d, const char *path, size_t plen);
// Put the info block (SHCL_GEN_BANNER) at the end of the document, or with on
// 0 just take it off. An old block comes off first, found by its "This config
// file format is SHCL." line, never by its links or Legal line, which a later
// release may word differently. It runs from the lone "##" above that line to
// the next one, so a "##" comment of the file's own stays, even written right
// against it. A version line shcl_migrate stamped comes off too, with the note
// under it. Both are looked for in the footer and above every field but the
// first one and its first child down, since a field added below one by hand
// takes it as its comment. A block at the top of the file is left alone. A
// dotted first line hangs it on its last name, which a saved file writes as the
// first field's first child, so a block there is left alone too, however it got
// there. The library save never adds the block by itself; this is for a program
// that wants it in a file it writes. Returns how many old blocks came off.
size_t shcl_set_banner(shcl_doc *d, int on);
int shcl_set_empty(shcl_doc *d, const char *path, size_t plen);
// Why a write at this path would fail - the reason behind a setter's bare 0,
// so a consumer's error message need not guess. SHCL_W_WRITABLE means the same
// validation the setters run would pass. Probes only; never creates.
shcl_write_reason shcl_write_reason_(shcl_doc *d, const char *path, size_t plen);

int shcl_set_int(shcl_doc *d, const char *path, size_t plen, int64_t v);
int shcl_set_float(shcl_doc *d, const char *path, size_t plen, double v);
int shcl_set_bool(shcl_doc *d, const char *path, size_t plen, int v);
int shcl_set_string(shcl_doc *d, const char *path, size_t plen, const char *s, size_t slen);
int shcl_set_datetime(shcl_doc *d, const char *path, size_t plen, const shcl_datetime *dt);
int shcl_set_raw(shcl_doc *d, const char *path, size_t plen, const char *content, size_t clen, const char *info, size_t ilen);

// Inline arrays, one per call.
int shcl_set_int_array(shcl_doc *d, const char *path, size_t plen, const int64_t *v, size_t n);
int shcl_set_float_array(shcl_doc *d, const char *path, size_t plen, const double *v, size_t n);
int shcl_set_bool_array(shcl_doc *d, const char *path, size_t plen, const int *v, size_t n);
int shcl_set_string_array(shcl_doc *d, const char *path, size_t plen, const char *const *v, const size_t *lens, size_t n);
int shcl_set_datetime_array(shcl_doc *d, const char *path, size_t plen, const shcl_datetime *v, size_t n);

// Binds text as value syntax rather than as data: "80, 443" becomes a
// two-element array where shcl_set_string would store one string that has to be
// quoted. For a caller holding value text - a config line, a user's --set
// argument - that has to be written without knowing its shape first. Returns 0
// for text that could not be one line's value (a line break, or a quote that
// never closes); a # outside quotes ends the value as it would in a file.
int shcl_set_literal(shcl_doc *d, const char *path, size_t plen, const char *text, size_t tlen);

// Default (only-if-absent) forms - the "emit defaults" half of the Writer.
int shcl_set_int_default(shcl_doc *d, const char *path, size_t plen, int64_t v);
int shcl_set_float_default(shcl_doc *d, const char *path, size_t plen, double v);
int shcl_set_bool_default(shcl_doc *d, const char *path, size_t plen, int v);
int shcl_set_string_default(shcl_doc *d, const char *path, size_t plen, const char *s, size_t slen);
int shcl_set_datetime_default(shcl_doc *d, const char *path, size_t plen, const shcl_datetime *dt);
int shcl_set_literal_default(shcl_doc *d, const char *path, size_t plen, const char *text, size_t tlen);
int shcl_set_raw_default(shcl_doc *d, const char *path, size_t plen, const char *content, size_t clen, const char *info, size_t ilen);
int shcl_set_int_array_default(shcl_doc *d, const char *path, size_t plen, const int64_t *v, size_t n);
int shcl_set_float_array_default(shcl_doc *d, const char *path, size_t plen, const double *v, size_t n);
int shcl_set_bool_array_default(shcl_doc *d, const char *path, size_t plen, const int *v, size_t n);
int shcl_set_string_array_default(shcl_doc *d, const char *path, size_t plen, const char *const *v, const size_t *lens, size_t n);
int shcl_set_datetime_array_default(shcl_doc *d, const char *path, size_t plen, const shcl_datetime *v, size_t n);

// --- Layered loading --------------------------------------------------------
// Overlay `over` (a higher-priority layer) onto `d` (the lower one). Container
// instances merge by (name, value) like the in-file rule; a leaf name present
// in `over` replaces d's same-named children at that scope - provided those
// base children are leaves too (real override for scalars, arrays, raw blocks;
// a bare section header merges instead of wiping); over-only nodes are
// appended. `over`'s content is deep-copied into d's arena, so d stays valid
// after `over` is freed.
//
// The fold is not associative: (A+B)+C and A+(B+C) differ where a bare header
// meets an overridden leaf, so a cached upper pair is not the same document the
// CLI's left fold produces. d keeps its own strictness, so a value from a
// stricter layer reads with d's coercion. And a replaced node is kept until
// shcl_free or shcl_compact - hundreds of kilobytes a merge on a large base,
// four orders of magnitude more than a single write, so a process folding
// layers in a loop is the one that has to call shcl_compact rather than the one
// that rewrites a field. It costs a pass over the touched scopes plus an index
// rebuild on the next read. A document merged onto itself is left as it is.
void shcl_merge(shcl_doc *d, const shcl_doc *over);

// CLI/aliases: 1|2|3 or loose|standard|strict. Returns 1 on success.
int shcl_strictness_from_arg(const char *s, size_t n, shcl_strictness *out);

// Format helpers matching the reference's textual output.
// out must be at least SHCL_FLOAT_BUF bytes; returns the byte length written.
#define SHCL_FLOAT_BUF 512
size_t shcl_format_float(double v, char *out);
// Renders a datetime into out (>= SHCL_DT_BUF bytes); returns byte length. A
// frac longer than 30 bytes is truncated, and the whole rendering is clamped to
// SHCL_DT_BUF bytes, so a hand-built value cannot overrun the documented buffer
// (parsed input never gets near either limit).
#define SHCL_DT_BUF 64
size_t shcl_datetime_str(const shcl_datetime *dt, char *out);
// The reverse: text to a datetime, per the whitelist. Returns 1 on success and
// leaves *out untouched on failure. The other three bindings export this, and
// the C CLI reached the internal one only by compiling the implementation into
// its own translation unit.
int shcl_parse_datetime(const char *text, size_t tlen, shcl_datetime *out);
// Status <-> the CLI exit code / textual name.
int shcl_status_code(shcl_status s);
const char *shcl_status_name(shcl_status s);
// Whether the author addressed the field at all: Good or Empty. A status
// predicate rather than a per-struct helper, since every read struct has
// the same status. Note this deliberately answers differently from the
// convenience tier, which falls back on Empty like any other non-Good read -
// this asks "is this field spoken for", shcl_get_int_or asks "do I have a
// usable value", and an explicitly emptied field is where the two diverge.
int shcl_status_ok(shcl_status s);

#ifdef __cplusplus
}
#endif

// ===========================================================================
#ifdef SHCL_IMPLEMENTATION

#ifdef __cplusplus
// The implementation zero-initializes aggregates with the C idiom `{0}`; C++
// -Wextra flags every one as a missing-field-initializer, which would break a
// consumer compiling this header into a C++ TU with -Werror. Scoped to the
// implementation only.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#endif

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <inttypes.h>
#include <setjmp.h>
#include <locale.h>

// SHCL writes a float with '.', but strtod and printf use whatever the host
// locale calls the decimal point - so in a consumer that has called setlocale
// both directions of float conversion need translating. The CLI never sets a
// locale, which is why only library callers ever saw this.
static const char *dec_point(void) {
	const char *p = localeconv()->decimal_point;
	return (p && *p) ? p : ".";
}

// --- arena (bump allocator; growable vectors grow by copy, bulk-freed) -------

// Where an allocation failure goes when there is no call to fail. A parse and a
// validate arm a recovery point first, so those unwind and hand the caller NULL
// instead; what is left is a read, a write or a merge on a document already
// built, and there the default is the CLI's contract (exit 70) - wrong for a
// process that is not the library's to end. An embedder defines SHCL_OOM before
// the implementation to longjmp out, log, or abort on its own terms. Nothing is
// unwound first, so a hook that returns leaks whatever was being built - and
// then aborts, because the allocation it was called for still failed. A hook
// that longjmps arms its recovery point with SHCL_SETJMP, for the reason given
// there: the unwind it starts crosses this library's frames, not just its own.
#ifndef SHCL_OOM
	#define SHCL_OOM() do { fprintf(stderr, "shcl: out of memory\n"); exit(70); } while (0)
#endif

/* Unwind to the recovery point `panic` names, or fall back to the macro when
   nothing armed one. Keeping on with a failed allocation is not an option: a
   bump arena holds its vectors' bookkeeping, so a request served out of
   nowhere hands back node indices that are no longer node indices. */
static void arena_panic(jmp_buf *panic) {
	if (panic) longjmp(*panic, 1);
	SHCL_OOM();
	/* A hook that returns leaves nothing to carry on with - the allocation
	   still failed - so it stops here rather than reading the null pointer one
	   line later, which is what used to happen. */
	abort();
}

typedef struct ShclBlock { struct ShclBlock *next; size_t used, cap; } ShclBlock;
/* last/last_n: the most recent allocation, so a vector or string builder that
   grows with nothing allocated after it extends in place. A bump arena cannot
   free, so without this every doubling abandons the copy before it - measured
   at two thirds of a large parse's memory. `last` always points into `head`.
   panic: where an allocation failure unwinds to; NULL means SHCL_OOM. */
typedef struct { ShclBlock *head; void *last; size_t last_n; int growing; jmp_buf *panic; } ShclArena;

static void *arena_alloc(ShclArena *a, size_t n) {
	n = (n + 15u) & ~(size_t)15u;
	if (n == 0) n = 16;
	if (!a->head || a->head->used + n > a->head->cap) {
		/* A block opened for a vector or builder that just doubled gets room to
		   double once more, so the next growth extends in place instead of
		   abandoning this copy. Without it a buffer that reaches N bytes has
		   spent about 2N getting there, and none of it is reclaimable. */
		size_t cap = n > (size_t)65536 ? (a->growing ? n * 2 : n) : (size_t)65536;
		ShclBlock *b = (ShclBlock *)malloc(sizeof(ShclBlock) + cap);
		if (!b) arena_panic(a->panic);
		b->next = a->head; b->used = 0; b->cap = cap; a->head = b;
	}
	void *p = (char *)(a->head + 1) + a->head->used;
	a->head->used += n;
	a->last = p; a->last_n = n;
	return p;
}
static void arena_free(ShclArena *a) {
	ShclBlock *b = a->head;
	while (b) { ShclBlock *n = b->next; free(b); b = n; }
	a->head = NULL; a->last = NULL; a->last_n = 0; a->growing = 0;
}
/* Hand an arena the recovery point its owner armed. */
static void arena_guard(ShclArena *a, jmp_buf *panic) { a->panic = panic; }
static void *arena_grow(ShclArena *a, void *old, size_t oldcap, size_t newcap, size_t sz) {
	/* Extend in place when nothing has been allocated since `old`. */
	if (old && a->head && old == a->last) {
		size_t want = (newcap * sz + 15u) & ~(size_t)15u;
		if (want <= a->last_n) return old;
		size_t extra = want - a->last_n;
		if (a->head->used + extra <= a->head->cap) {
			a->head->used += extra; a->last_n = want;
			return old;
		}
	}
	a->growing = 1;
	void *p = arena_alloc(a, newcap * sz);
	a->growing = 0;
	if (old && oldcap) memcpy(p, old, oldcap * sz);
	return p;
}
/* A point to roll back to. A bump arena cannot free one allocation, but it can
   give back everything since a mark, which is what a setter needs when the
   value it just encoded turns out to be refused. Only sound when nothing
   allocated after the mark is still referenced. */
typedef struct { ShclBlock *head; size_t used; void *last; size_t last_n; } ShclMark;

static ShclMark arena_mark(ShclArena *a) {
	ShclMark m; m.head = a->head; m.used = a->head ? a->head->used : 0;
	m.last = a->last; m.last_n = a->last_n;
	return m;
}

static void arena_release(ShclArena *a, ShclMark m) {
	while (a->head && a->head != m.head) { ShclBlock *n = a->head->next; free(a->head); a->head = n; }
	if (a->head) a->head->used = m.used;
	a->last = m.last; a->last_n = m.last_n;
}

// Reset a scratch arena, keeping its newest (largest) block so steady-state
// reads never re-malloc. Bump arenas cannot free per-object, so without this
// every resolver temporary would live until shcl_free - a long-running process
// doing reads would grow without bound.
static void arena_reset(ShclArena *a) {
	if (!a->head) return;
	ShclBlock *b = a->head->next;
	while (b) { ShclBlock *n = b->next; free(b); b = n; }
	a->head->next = NULL; a->head->used = 0;
	a->last = NULL; a->last_n = 0;
}
/* Like arena_reset, but the block kept is the largest rather than the newest.
   The name index's chain array is one block sized by the node arena, and a
   consumer merging once a second rebuilds it every time; freed, windows hands
   the block back to the system and faults it in again on the next build, a
   quarter of a millisecond per merge there. Kept, the rebuild reuses it. */
static void arena_reset_largest(ShclArena *a) {
	ShclBlock *best = NULL, *b;
	for (b = a->head; b; b = b->next) if (!best || b->cap > best->cap) best = b;
	for (b = a->head; b;) { ShclBlock *n = b->next; if (b != best) free(b); b = n; }
	a->head = best;
	if (best) { best->next = NULL; best->used = 0; }
	a->last = NULL; a->last_n = 0; a->growing = 0;
}
/* And the other way: the block kept is the smallest. A default form's probe
   judges one value in scratch and keeps nothing, and the newest block there is
   the one that grew for the last value, so arena_reset would hold three times
   the largest value ever defaulted until the document is freed. */
static void arena_reset_smallest(ShclArena *a) {
	ShclBlock *best = NULL, *b;
	for (b = a->head; b; b = b->next) if (!best || b->cap < best->cap) best = b;
	for (b = a->head; b;) { ShclBlock *n = b->next; if (b != best) free(b); b = n; }
	a->head = best;
	if (best) { best->next = NULL; best->used = 0; }
	a->last = NULL; a->last_n = 0; a->growing = 0;
}

#define DEFINE_VEC(Name, T) \
	typedef struct { T *data; size_t len, cap; } Name; \
	static void Name##_push(ShclArena *a, Name *v, T x) { \
		if (v->len == v->cap) { size_t nc = v->cap ? v->cap * 2 : 8; \
			v->data = (T *)arena_grow(a, v->data, v->cap, nc, sizeof(T)); v->cap = nc; } \
		v->data[v->len++] = x; }

// --- byte-string helpers -----------------------------------------------------

typedef shcl_str ShclStr;
static ShclStr s_lit(const char *z) { ShclStr s; s.p = z; s.n = strlen(z); return s; }
static ShclStr s_empty(void) { ShclStr s; s.p = ""; s.n = 0; return s; }
static int s_eq(ShclStr a, ShclStr b) { return a.n == b.n && (a.n == 0 || memcmp(a.p, b.p, a.n) == 0); }
static ShclStr s_dup(ShclArena *a, ShclStr x) {
	if (x.n == 0) return s_empty();
	char *m = (char *)arena_alloc(a, x.n); memcpy(m, x.p, x.n);
	ShclStr r; r.p = m; r.n = x.n; return r;
}
/* Keep s as-is when it already slices the retained input copy (src), else dup
   it into the arena. The parse dups the whole input once and stores slices of
   that copy; this is the store-site gate that makes mixed provenance safe. */
static ShclStr s_keep(ShclArena *a, ShclStr src, ShclStr s) {
	if (s.n && (uintptr_t)s.p >= (uintptr_t)src.p && (uintptr_t)s.p + s.n <= (uintptr_t)src.p + src.n) return s;
	return s_dup(a, s);
}
static ShclStr s_slice(ShclStr s, size_t from, size_t to) { ShclStr r; r.p = s.p + from; r.n = to - from; return r; }
static int s_starts(ShclStr s, const char *pre) {
	size_t n = strlen(pre); return s.n >= n && memcmp(s.p, pre, n) == 0;
}

typedef struct { char *data; size_t len, cap; } ShclSB;
static void sb_put(ShclArena *a, ShclSB *s, const char *p, size_t n) {
	if (!n) return;
	if (s->len + n > s->cap) { size_t nc = s->cap ? s->cap * 2 : 32;
		while (nc < s->len + n) nc *= 2;
		s->data = (char *)arena_grow(a, s->data, s->cap, nc, 1); s->cap = nc; }
	memcpy(s->data + s->len, p, n); s->len += n;
}
/* Open the builder at a size the caller already knows. A bump arena abandons
   every step of a doubling climb, so a 20 MB value built from 32 bytes cost
   about four times its own size. */
static void sb_reserve(ShclArena *a, ShclSB *s, size_t n) {
	if (n <= s->cap) return;
	s->data = (char *)arena_grow(a, s->data, s->cap, n, 1); s->cap = n;
}
static void sb_putc(ShclArena *a, ShclSB *s, char c) { sb_put(a, s, &c, 1); }
static void sb_puts(ShclArena *a, ShclSB *s, const char *z) { sb_put(a, s, z, strlen(z)); }
static void sb_putS(ShclArena *a, ShclSB *s, ShclStr x) { sb_put(a, s, x.p, x.n); }
static ShclStr sb_S(ShclSB *s) { ShclStr r; r.p = s->data ? s->data : ""; r.n = s->len; return r; }

// --- UTF-8 (input is validated at the CLI; here we assume it is well formed) --

static size_t utf8_decode(const char *p, size_t n, size_t i, uint32_t *cp) {
	unsigned char c = (unsigned char)p[i];
	if (c < 0x80) { *cp = c; return 1; }
	if ((c >> 5) == 0x6 && i + 1 < n) {
		*cp = ((uint32_t)(c & 0x1F) << 6) | (p[i + 1] & 0x3F); return 2;
	}
	if ((c >> 4) == 0xE && i + 2 < n) {
		*cp = ((uint32_t)(c & 0x0F) << 12) | ((uint32_t)(p[i + 1] & 0x3F) << 6) | (p[i + 2] & 0x3F); return 3;
	}
	if ((c >> 3) == 0x1E && i + 3 < n) {
		*cp = ((uint32_t)(c & 0x07) << 18) | ((uint32_t)(p[i + 1] & 0x3F) << 12)
			| ((uint32_t)(p[i + 2] & 0x3F) << 6) | (p[i + 3] & 0x3F); return 4;
	}
	*cp = c; return 1;
}
static size_t utf8_encode(uint32_t cp, char out[4]) {
	if (cp < 0x80) { out[0] = (char)cp; return 1; }
	if (cp < 0x800) { out[0] = (char)(0xC0 | (cp >> 6)); out[1] = (char)(0x80 | (cp & 0x3F)); return 2; }
	if (cp < 0x10000) {
		out[0] = (char)(0xE0 | (cp >> 12)); out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
		out[2] = (char)(0x80 | (cp & 0x3F)); return 3;
	}
	out[0] = (char)(0xF0 | (cp >> 18)); out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
	out[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); out[3] = (char)(0x80 | (cp & 0x3F)); return 4;
}
// Byte length of the last codepoint in s (0 if empty); *cp gets its value.
static size_t utf8_last(ShclStr s, uint32_t *cp) {
	if (s.n == 0) { *cp = 0; return 0; }
	size_t i = s.n - 1;
	while (i > 0 && ((unsigned char)s.p[i] & 0xC0) == 0x80) i--;
	utf8_decode(s.p, s.n, i, cp);
	return s.n - i;
}
static void sb_put_cp(ShclArena *a, ShclSB *s, uint32_t cp) {
	char buf[4]; size_t l = utf8_encode(cp, buf); sb_put(a, s, buf, l);
}

// Decode s into a codepoint array with byte offsets (off has n+1 entries).
typedef struct { uint32_t *cp; size_t *off; size_t n; } ShclCPs;
static ShclCPs decode_cps(ShclArena *a, ShclStr s) {
	size_t m = 0;
	for (size_t i = 0; i < s.n;) { uint32_t c; i += utf8_decode(s.p, s.n, i, &c); m++; }
	ShclCPs r; r.n = m;
	r.cp = (uint32_t *)arena_alloc(a, (m ? m : 1) * sizeof(uint32_t));
	r.off = (size_t *)arena_alloc(a, (m + 1) * sizeof(size_t));
	size_t i = 0, k = 0;
	while (i < s.n) { uint32_t c; size_t l = utf8_decode(s.p, s.n, i, &c); r.cp[k] = c; r.off[k] = i; i += l; k++; }
	r.off[m] = s.n;
	return r;
}

// --- whitespace (Rust char::is_whitespace / Unicode White_Space) + ascii ------

static int is_ws(uint32_t c) {
	switch (c) {
	case 0x09: case 0x0A: case 0x0B: case 0x0C: case 0x0D: case 0x20:
	case 0x85: case 0xA0: case 0x1680:
	case 0x2000: case 0x2001: case 0x2002: case 0x2003: case 0x2004:
	case 0x2005: case 0x2006: case 0x2007: case 0x2008: case 0x2009:
	case 0x200A: case 0x2028: case 0x2029: case 0x202F: case 0x205F: case 0x3000:
		return 1;
	default: return 0;
	}
}
static ShclStr trim_start(ShclStr s) {
	size_t i = 0;
	while (i < s.n) { uint32_t c; size_t l = utf8_decode(s.p, s.n, i, &c); if (!is_ws(c)) break; i += l; }
	return s_slice(s, i, s.n);
}
static ShclStr trim_end(ShclStr s) {
	while (s.n) { uint32_t c; size_t l = utf8_last(s, &c); if (!is_ws(c)) break; s.n -= l; }
	return s;
}
static ShclStr s_trim(ShclStr s) { return trim_end(trim_start(s)); }

/* The grammar's wsp: a space, a tab or a carriage return. The parser trims
   with this and nothing wider - a no-break space or a line separator after a
   value is content, and a Unicode trim used to delete it with no diagnostic. */
static int is_wsp(uint32_t c) { return c == ' ' || c == '\t' || c == '\r'; }
static ShclStr trim_wsp_start(ShclStr s) {
	size_t i = 0;
	while (i < s.n && is_wsp((unsigned char)s.p[i])) i++;
	return s_slice(s, i, s.n);
}
static ShclStr trim_wsp_end(ShclStr s) {
	while (s.n && is_wsp((unsigned char)s.p[s.n - 1])) s.n--;
	return s;
}
static ShclStr s_trim_wsp(ShclStr s) { return trim_wsp_end(trim_wsp_start(s)); }
/* Spaces and tabs only, at both ends: a raw body keeps its carriage returns. */
static ShclStr s_trim_sp_tab(ShclStr s) {
	size_t i = 0;
	while (i < s.n && (s.p[i] == ' ' || s.p[i] == '\t')) i++;
	while (s.n > i && (s.p[s.n - 1] == ' ' || s.p[s.n - 1] == '\t')) s.n--;
	return s_slice(s, i, s.n);
}

static int is_adigit(uint32_t c) { return c >= '0' && c <= '9'; }
static int is_aalnum(uint32_t c) {
	return is_adigit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
static int is_bare_name_char(uint32_t c) {
	return (c < 128 && is_aalnum(c)) || c == '-' || c == '_';
}
static int all_adigit0(ShclStr s) { for (size_t i = 0; i < s.n; i++) if (!is_adigit((unsigned char)s.p[i])) return 0; return 1; }
static ShclStr ascii_lower(ShclArena *a, ShclStr s) {
	char *m = (char *)arena_alloc(a, s.n ? s.n : 1);
	for (size_t i = 0; i < s.n; i++) { unsigned char c = (unsigned char)s.p[i]; m[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : (char)c; }
	ShclStr r; r.p = m; r.n = s.n; return r;
}
static ShclStr fold_name(ShclArena *a, ShclStr s) { return ascii_lower(a, s); }
/* True when folding and escape resolution cannot change a name's spelling:
   no A-Z (fold identity), and no backslash inside double quotes, the one
   place a backslash resolves. Then the stored name can be the source slice
   itself. */
static int name_plain(ShclStr s, shcl_quote q) {
	if (q == SHCL_QUOTE_DOUBLE && s.n && memchr(s.p, '\\', s.n)) return 0;
	for (size_t i = 0; i < s.n; i++) {
		unsigned char c = (unsigned char)s.p[i];
		if (c >= 'A' && c <= 'Z') return 0;
	}
	return 1;
}

// --- in-memory model ---------------------------------------------------------

typedef struct { ShclStr text; int quoted; } ShclElement; // text: the logical string - quotes stripped, escapes resolved
DEFINE_VEC(ShclVecEl, ShclElement)

typedef enum { V_EMPTY, V_CELL, V_RAW } ShclVKind;
typedef struct { ShclStr content; ShclStr info; unsigned char fence_char; size_t fence_len; } ShclRawVal;
typedef struct {
	ShclVKind kind;
	ShclElement *els; size_t nels;                 // V_CELL
	size_t cap_els;                            // stacked-list growth only (0 elsewhere)
	ShclRawVal *raw;                               // V_RAW only, else NULL: inline, the four fields sat in every node
} ShclValue;

DEFINE_VEC(ShclVecSize, size_t)
DEFINE_VEC(ShclVecS, ShclStr)

/* One whole-line comment held as trivia, plus whether a blank line preceded
   it - so a blank between comment-only regions survives the round-trip
   (blank runs collapse to one, same as nodes). */
/* depth: levels deeper than the place it is emitted at. A comment written under
   the one before it keeps that nesting, so a commented-out block comes back in
   its shape.
   line: the source line it was read from, for the save that keeps lines; 0 for
   one a write made or moved.
   kept: a misplaced line kept as written that the settle turned into a
   comment, since as written it would bind. It is still the user's line, not a
   comment, so shcl_clear_comments and shcl_comments leave it alone. */
typedef struct { ShclStr text; int blank_before; size_t depth; size_t line; int kept; } ShclLead;
DEFINE_VEC(ShclVecLead, ShclLead)
static ShclLead lead_at(ShclStr text, int blank_before, size_t depth, size_t line) { ShclLead l; l.text = text; l.blank_before = blank_before; l.depth = depth; l.line = line; l.kept = 0; return l; }
static ShclLead lead_make(ShclStr text, int blank_before, size_t depth) { return lead_at(text, blank_before, depth, 0); }
static ShclLead lead_plain(ShclStr text) { return lead_make(text, 0, 0); }
/* A copy into another arena, source line and all. */
static ShclLead lead_copy(ShclArena *a, const ShclLead *l) { ShclLead c = lead_at(s_dup(a, l->text), l->blank_before, l->depth, l->line); c.kept = l->kept; return c; }
/* A copy that no longer stands for a source line, as a merge moves it. */
static ShclLead lead_moved(ShclArena *a, const ShclLead *l) { ShclLead c = lead_make(s_dup(a, l->text), l->blank_before, l->depth); c.kept = l->kept; return c; }
static int lead_is_comment(const ShclLead *l) { return l->text.n && l->text.p[0] == '#' && !l->kept; }
/* A line the load kept as written, settled or not. The save gate counts these
   (design.md, Kept lines under edits). */
static int lead_is_kept_line(const ShclLead *l) { return l->kept || !(l->text.n && l->text.p[0] == '#'); }
static size_t kept_shortfall(const shcl_doc *d);
static size_t kept_taken(shcl_doc *d, size_t node);
/* A kept line among a stacked list's elements, with how many elements come
   before it. */
typedef struct { size_t before; ShclLead lead; } ShclAmong;
DEFINE_VEC(ShclVecAmong, ShclAmong)

/* Comment trivia, verbatim from `#` to end of line. Never part of identity
   or reads; merged instances concatenate leading, first trailing wins
   (later ones demote to leading - a canonical line has room for one). */
typedef struct {
	ShclVecLead leading;
	ShclStr trailing; /* n == 0 = none */
	/* Whole-line comments that followed this node's subtree at a deeper indent
	   than the next binding - they belong to this block, not the next node, so
	   a run trailing a block's last child stays put instead of re-attaching
	   dedented. Emitted after the subtree at this node's depth. */
	ShclVecLead after;
	/* Whole-line comments written inside this node's block when no bound child
	   could take them - a header whose children are all commented still owns
	   those lines. Emitted after the subtree one level deeper than this node. */
	ShclVecLead inside;
	/* Kept lines that sat among this node's stacked list elements. They keep
	   the list stacked on output, so a line fixed by hand is still inside the
	   list. */
	ShclVecAmong among;
} ShclTrivia;

typedef struct {
	ShclStr name;
	/* The name as the author wrote it (case unfolded, quotes and escapes
	   resolved) - what shcl_authored_name hands back, via node_authored.
	   Merged instances keep the first binding's spelling, like shcl_line and
	   comments. Empty = written exactly like `name` (the overwhelmingly
	   common case). */
	ShclStr name_src;
	ShclValue value;
	ShclVecSize children;
	size_t parent;
	size_t line;
	/* Comment trivia, hung off to the side: most nodes have none, and the
	   four empty containers were a third of every node. NULL = none. */
	ShclTrivia *trivia;
	int star_list;  /* value built from stacked "* " lines */
	int star_mixed; /* mix of "* " and field children already diagnosed */
	/* Blank-line grouping is the other half of hand-authored layout: set when
	   a blank line preceded this node's binding line (runs collapse to one). */
	int blank_before;
} ShclNode;
typedef struct { ShclNode *data; size_t len, cap; } ShclVecNode;

/* generated: pushed by shcl_generate, which drops its own at the start of the
   next call. Matching by code dropped too little, and a document that came
   through shcl_load_and_validate can hold V09x of its own. */
typedef struct { size_t line; shcl_severity sev; ShclStr message; const char *code; int generated; } ShclDiag;
DEFINE_VEC(ShclVecDiag, ShclDiag)

/* Hash-keyed child map (the parser's accelerator and the read index); the
   operations sit with the parser below. */
typedef struct ShclCMapEnt { struct ShclCMapEnt *next; uint64_t hash; size_t val; } ShclCMapEnt;
typedef struct { ShclCMapEnt **buckets; size_t cap, len; } ShclCMap;

struct shcl_doc {
	ShclArena arena;
	// Per-resolve temporaries (path scans, resolver vectors, display strings
	// built only to compare). Reset on entry to each resolve, so read-only use
	// of a long-lived document stays flat; anything HANDED BACK to the caller
	// lives in `reads` (valid until shcl_free or shcl_reads_release).
	ShclArena scratch;
	// Results handed back by the read calls. Its own arena so a long-running
	// consumer polling one document can give them back with shcl_reads_release
	// instead of growing until shcl_free. Freed with the document either way,
	// so a caller that never calls it sees the documented lifetime unchanged.
	ShclArena reads;
	ShclVecNode nodes;
	/* Armed for the length of a parse and cleared before it returns: the two
	   vectors above are malloc storage, so they cannot read it off an arena. */
	jmp_buf *panic;
	ShclVecDiag diags;
	shcl_strictness strictness;
	ShclVecLead orphans; /* top-level comments after the last binding line */
	/* Lines or values parsing dropped that canonical output cannot re-emit
	   (bad indentation, an unusable selector, past the depth cap, ...).
	   Content-malformed lines are NOT counted - they are retained as trivia
	   and survive a save. shcl_lost_count serves it; shcl_save_file gates on
	   it. */
	size_t lost;
	/* How many kept lines the document must still write: the load's, plus a
	   merged layer's, less those design.md's kept-lines table lets an edit
	   take. Fewer in the tree than this counts as lost. */
	size_t kept_owed;
	/* Read accelerator: the first child of each (parent, name), chained on to
	   the next same-named sibling, plus the chain tail so an append is O(1).
	   A hash collision chains a stranger in; the lookup checks the name, so
	   the chain is only ever a superset. Built on the first path lookup and
	   kept current by the writer (a new child appends, a removed one
	   unlinks); only a merge drops it. Without it every lookup scans the
	   parent's children, so a flat document read or written key by key was
	   quadratic. Its own arena, freed on drop: the document arena cannot
	   give it back.
	   index_built: 0 none, 1 built, 2 in flux. The build and every append
	   allocate, and an SHCL_OOM hook that longjmps leaves whatever they were
	   in the middle of; a lookup that finds 2 drops the lot and rebuilds,
	   because a half-built chain can loop and a walk over it never ends. */
	ShclArena index_arena;
	int index_built;
	ShclCMap index_first;    /* name_key -> first child */
	ShclCMap index_last;     /* name_key -> chain tail */
	size_t *index_next;  /* per node; NIL ends the chain */
	size_t index_next_cap;
	/* The document a default form checks values against, built on the first
	   one that finds its path already there, and the flag that makes a
	   document a probe: w_set_marked stops once the value is judged and gives
	   the value back, so a probe is never written. */
	shcl_doc *probe_doc;
	int probe;
	/* Holds a misplaced line kept as written, so edits have to settle it. */
	int kept;
	/* What the last settle's kept lines were modeled through, as node and
	   place-in-parent pairs, and a sum of it, so an edit that changes none of
	   it skips the settle. Removing a block above all of it goes unseen, which
	   leaves kept set with no such line left: the next check costs the same,
	   and nothing is wrong. malloc'd; shcl_free and shcl_compact give it back. */
	size_t *kept_near; size_t kept_near_len, kept_near_cap;
	uint64_t kept_sum;
	/* The parse's multi-line bindings, as pairs: a raw block's or a stacked
	   list's binding line and the last line it took. Edits leave it alone;
	   only a reparse reads it. */
	ShclVecSize ends;
	/* Each line counted in lost, once per count, kept only when track_dropped
	   is set, for the save that keeps lines: a capped parse of a huge bad file
	   would hold one per line. Only a reparse reads it. */
	int track_dropped; ShclVecSize dropped;
	/* The text a load kept for shcl_to_text_keep_lines, BOM and all, and
	   empty when that text was already canonical, since the canonical form is
	   then the one that keeps its lines. A merge drops it: the layer's lines
	   are not this text's. */
	int has_source; ShclStr source;
};

/* Point every allocation a document can make at one recovery point, or back at
   SHCL_OOM with NULL. A call that holds documents of its own across other
   allocations arms this, so a longjmping hook cannot strand them. */
static void doc_guard(shcl_doc *d, jmp_buf *panic) {
	if (!d) return;
	d->panic = panic;
	arena_guard(&d->arena, panic); arena_guard(&d->scratch, panic);
	arena_guard(&d->reads, panic); arena_guard(&d->index_arena, panic);
}
#define ROOT ((size_t)0)
#define NODE(d, i) ((d)->nodes.data[i])
#define NIL ((size_t)-1)
/* Stack entry for a binding line that was skipped: it still owns its indent
   level, so the lines written under it are skipped with it instead of
   re-parenting one level up. */
#define DEAD ((size_t)-1)
/* Stack entry for a line whose indent matched no open level (E012): never a
   level a sibling can bind at, but deeper lines are still under it. It sits on
   top of the levels open before it without closing any of them. */
#define UNOPENED ((size_t)-2)
/* Stack entry for a field line refused for its value alone (E019, E023,
   E024): it binds nothing, but its path is fine, so the first line that binds
   under it opens the path as `name:` would and binds there. */
#define LAZY ((size_t)-3)

/* The node vector lives in malloc storage, not the bump arena: the arena
   cannot reclaim the abandoned copy at each doubling, which held about one
   extra full array at peak. realloc extends in place or frees the old block.
   Every doc comes from do_parse (calloc zeroes the vector); shcl_free is the
   one teardown and frees it. */
static void nodes_push(shcl_doc *d, ShclNode x) {
	ShclVecNode *v = &d->nodes;
	if (v->len == v->cap) {
		size_t nc = v->cap ? v->cap * 2 : 8;
		ShclNode *nd = (ShclNode *)realloc(v->data, nc * sizeof(ShclNode));
		if (!nd) arena_panic(d->panic);
		v->data = nd; v->cap = nc;
	}
	v->data[v->len++] = x;
}

/* Nil-safe trivia reads (empty defaults) and the get-or-create for writes;
   the sidecar is allocated in the document arena on the first write. */
static ShclVecLead triv_leading(const ShclNode *n) { if (n->trivia) return n->trivia->leading; ShclVecLead v; memset(&v, 0, sizeof v); return v; }
static ShclStr triv_trailing(const ShclNode *n) { return n->trivia ? n->trivia->trailing : s_empty(); }
static ShclVecLead triv_after(const ShclNode *n) { if (n->trivia) return n->trivia->after; ShclVecLead v; memset(&v, 0, sizeof v); return v; }
static ShclVecLead triv_inside(const ShclNode *n) { if (n->trivia) return n->trivia->inside; ShclVecLead v; memset(&v, 0, sizeof v); return v; }
static ShclVecAmong triv_among(const ShclNode *n) { if (n->trivia) return n->trivia->among; ShclVecAmong v; memset(&v, 0, sizeof v); return v; }
static ShclTrivia *triv_mut(ShclArena *a, ShclNode *n) {
	if (!n->trivia) { n->trivia = (ShclTrivia *)arena_alloc(a, sizeof(ShclTrivia)); memset(n->trivia, 0, sizeof(ShclTrivia)); }
	return n->trivia;
}

/* The as-authored name spelling; empty name_src means "same as name". */
static ShclStr node_authored(const ShclNode *n) { return n->name_src.n ? n->name_src : n->name; }
/* Store a name's authored spelling: the empty sentinel when it matches the
   folded name, so the duplicate string never gets allocated. */
static ShclStr spelled(ShclArena *a, ShclStr name, ShclStr name_src) {
	return s_eq(name_src, name) ? s_empty() : s_dup(a, name_src);
}

/* Stable order by position: an insertion sort, since the lists are short and
   mostly in order already. */
static void among_sort(ShclVecAmong *v) {
	for (size_t i = 1; i < v->len; i++) {
		ShclAmong x = v->data[i];
		size_t j = i;
		while (j > 0 && v->data[j - 1].before > x.before) { v->data[j] = v->data[j - 1]; j--; }
		v->data[j] = x;
	}
}

/* Merge a later instance into an earlier one under the in-file merge rule:
   children and trivia move over, first trailing wins (a second demotes to a
   leading line), first spelling stays. The caller drops the loser from the
   parent's child list; it keeps its arena slot, unreferenced. */
static void fold_node_into(shcl_doc *d, size_t survivor, size_t loser) {
	ShclArena *a = &d->arena;
	ShclVecSize kids = NODE(d, loser).children;
	for (size_t k = 0; k < kids.len; k++) {
		NODE(d, kids.data[k]).parent = survivor;
		ShclVecSize_push(a, &NODE(d, survivor).children, kids.data[k]);
	}
	NODE(d, loser).children.len = 0;
	const ShclTrivia *lt = NODE(d, loser).trivia;
	if (lt) {
		NODE(d, loser).trivia = NULL;
		ShclTrivia *st = triv_mut(a, &NODE(d, survivor));
		for (size_t k = 0; k < lt->leading.len; k++)
			ShclVecLead_push(a, &st->leading, lt->leading.data[k]);
		if (lt->trailing.n) {
			if (st->trailing.n == 0) st->trailing = lt->trailing;
			else ShclVecLead_push(a, &st->leading, lead_plain(lt->trailing));
		}
		for (size_t k = 0; k < lt->after.len; k++)
			ShclVecLead_push(a, &st->after, lt->after.data[k]);
		for (size_t k = 0; k < lt->inside.len; k++)
			ShclVecLead_push(a, &st->inside, lt->inside.data[k]);
		for (size_t k = 0; k < lt->among.len; k++)
			ShclVecAmong_push(a, &st->among, lt->among.data[k]);
		among_sort(&st->among);
	}
}

static ShclValue v_empty(void) { ShclValue v; memset(&v, 0, sizeof v); v.kind = V_EMPTY; return v; }
static int v_is_empty(const ShclValue *v) { return v->kind == V_EMPTY; }

static ShclStr value_display(ShclArena *a, const ShclValue *v) {
	if (v->kind == V_EMPTY) return s_empty();
	if (v->kind == V_RAW) return v->raw->content;
	ShclSB s = {0};
	for (size_t i = 0; i < v->nels; i++) { if (i) sb_puts(a, &s, ", "); sb_putS(a, &s, v->els[i].text); }
	return sb_S(&s);
}

// --- Tokenizer - the one place the lexical rules live ------------------------
//
// Every reading of a line's parts goes through tokenize: the parser's line
// dispatch, the path scanner behind every lookup and setter, the comment and
// comma splits, the element cap, the unterminated-quote check, shcl_set_literal
// and the CLI's --set split. Seven scanners used to have their own copy of
// these rules, and every scanner defect since July was two of them
// disagreeing. The rules, one sentence each:
//
// - A piece (a name, a selector body, a value element) is quoted only when
//   its first character is a quote and the next matching quote is the last
//   thing before the piece ends; inside double quotes a backslash escapes the
//   next character, inside single quotes nothing does. Anywhere else a quote
//   is an ordinary character, and a piece that began with one it never closed
//   is kept literally and reported (E017).
// - Escapes are processed inside double quotes only; bare text and single
//   quotes never process a backslash.
// - `#` outside quotes opens a comment, wherever it sits.
// - A space, a tab and a carriage return are blanks: trimmed at a piece's
//   edge, content in the middle of one.
// - A bare name is ASCII letters, digits, `-` and `_`; a `[` right after a
//   name opens a selector, whose bare body runs to the first `]`; a `[` after
//   the separator starts the value, which the parser refuses (E019).
// - A value is split on unquoted commas, each piece trimmed.
//
// Under SHCL_RULES_V2 the tokenizer reads the 2.x spellings instead, for
// shcl_migrate: a backslash shields the next character in bare and
// single-quoted value text, a bare selector body still runs to its first `]`,
// a separator followed by `[` is the selector sugar, and an open quote
// swallows the rest of the line.
//
// The two span vectors grow in whatever arena the caller hands over - the
// parser's scratch for a parse, the read arena for the public entry points -
// and a tokens struct reused across lines keeps its capacity. Nothing is
// copied out of the text.

typedef shcl_quote ShclQuote; typedef shcl_piece ShclPiece; typedef shcl_seg_tok ShclSegTok;
typedef shcl_tokens ShclTokens; typedef shcl_rules ShclRules;
static ShclStr apply_escapes(ShclArena *a, ShclStr s);
static ShclStr apply_escapes_v2(ShclArena *a, ShclStr s);

static void tok_clear(ShclTokens *t) {
	t->nseg = 0; t->has_sep = 0; t->sep = 0; t->value_start = 0; t->value_end = 0; t->nelem = 0;
	t->has_comment = 0; t->comment = 0; t->has_fault = 0; t->fault_at = 0; t->fault_why = NULL; t->capped = 0;
}
static void tok_push_seg(ShclArena *a, ShclTokens *t, ShclSegTok s) {
	if (t->nseg == t->seg_cap) { size_t nc = t->seg_cap ? t->seg_cap * 2 : 8; t->segments = (ShclSegTok *)arena_grow(a, t->segments, t->seg_cap, nc, sizeof(ShclSegTok)); t->seg_cap = nc; }
	t->segments[t->nseg++] = s;
}
static void tok_push_elem(ShclArena *a, ShclTokens *t, ShclPiece p) {
	if (t->nelem == t->elem_cap) { size_t nc = t->elem_cap ? t->elem_cap * 2 : 8; t->elements = (ShclPiece *)arena_grow(a, t->elements, t->elem_cap, nc, sizeof(ShclPiece)); t->elem_cap = nc; }
	t->elements[t->nelem++] = p;
}
static void tok_fault(ShclTokens *t, size_t at, const char *why) { t->has_fault = 1; t->fault_at = at; t->fault_why = why; }
static int piece_quoted(ShclQuote q) { return q == SHCL_QUOTE_SINGLE || q == SHCL_QUOTE_DOUBLE; }
static size_t min_sz(size_t a, size_t b) { return a < b ? a : b; }

size_t shcl_tokens_element_count(const shcl_tokens *t) {
	size_t n = 0;
	for (size_t i = 0; i < t->nelem; i++) if (t->elements[i].quote != SHCL_QUOTE_NONE || t->elements[i].end > t->elements[i].start) n++;
	return n;
}

static void skip_wsp(ShclStr s, size_t *pos) { while (*pos < s.n && is_wsp((unsigned char)s.p[*pos])) (*pos)++; }

/* Byte length of the UTF-8 character that starts with b. The scan only ever
   compares against ASCII structure characters, which UTF-8 guarantees cannot
   appear inside a multibyte sequence, so it advances by whole characters and
   every offset it records is a character boundary. */
static size_t utf8_len(unsigned char b) {
	if (b < 0x80) return 1;
	if (b >= 0xC0 && b < 0xE0) return 2;
	if (b >= 0xE0 && b < 0xF0) return 3;
	return 4;
}

/* Offset of the quote that closes the one at pos; 0 when there is none. */
static int quote_close(ShclStr s, size_t pos, ShclRules rules, size_t *close) {
	char q = s.p[pos];
	int escapes = q == '"' || rules == SHCL_RULES_V2;
	size_t i = pos + 1;
	while (i < s.n) {
		if (escapes && s.p[i] == '\\' && i + 1 < s.n) { i += 1 + utf8_len((unsigned char)s.p[i + 1]); continue; }
		if (s.p[i] == q) { *close = i; return 1; }
		i += utf8_len((unsigned char)s.p[i]);
	}
	return 0;
}

/* True when the byte at i opens a comment. Being outside quotes is the
   caller's business. */
static int comment_at(ShclStr s, size_t i) {
	return s.p[i] == '#';
}

/* One piece from pos: a value element up to an unquoted comma or comment, or
   a selector body up to an unquoted `]` (term). Fills the trimmed piece and
   returns the offset of what ended it: the terminator, a comment's `#`, or
   the end of the text. comments is 0 only for a selector body in a lookup
   path, where `[#N]` is the index spelling. */
static size_t scan_piece(ShclStr s, size_t pos, char term, ShclRules rules, int comments, ShclPiece *out) {
	skip_wsp(s, &pos);
	size_t start = pos;
	ShclQuote quote = SHCL_QUOTE_NONE;
	if (pos < s.n && (s.p[pos] == '"' || s.p[pos] == '\'')) {
		size_t close;
		if (quote_close(s, pos, rules, &close)) {
			/* A value piece may also end at a comment or the line end; a
			   selector body ends at its bracket and nowhere else. */
			size_t i = close + 1;
			skip_wsp(s, &i);
			int ended = i < s.n ? (s.p[i] == term || (term == ',' && comment_at(s, i))) : term == ',';
			if (ended) {
				out->start = pos + 1; out->end = close;
				out->quote = s.p[pos] == '"' ? SHCL_QUOTE_DOUBLE : SHCL_QUOTE_SINGLE;
				return i;
			}
			/* Text after the closing quote: the quote was a character after
			   all, and the scan restarts at it. 2.x went on from the close
			   with the quotes read as a pair. */
			quote = SHCL_QUOTE_OPEN;
			if (rules == SHCL_RULES_V2) pos = close + 1;
		} else {
			quote = SHCL_QUOTE_OPEN;
			if (rules == SHCL_RULES_V2) {
				/* 2.x: an open quote swallowed the rest of the line. */
				size_t end = s.n;
				while (end > start && is_wsp((unsigned char)s.p[end - 1])) end--;
				out->start = start; out->end = end; out->quote = quote;
				return s.n;
			}
		}
	}
	/* 2.x shielded a backslash in value text only. A bare selector body ran to
	   its first `]`, the same as now, so shielding one here would hide the `]`. */
	int shield = rules == SHCL_RULES_V2 && term == ',';
	size_t content_end = start;
	while (pos < s.n) {
		unsigned char b = (unsigned char)s.p[pos];
		if (shield && b == '\\' && pos + 1 < s.n) { pos += 1 + utf8_len((unsigned char)s.p[pos + 1]); content_end = min_sz(pos, s.n); continue; }
		if (b == (unsigned char)term || (comments && comment_at(s, pos))) break;
		pos += utf8_len(b);
		if (!is_wsp(b)) content_end = min_sz(pos, s.n);
	}
	/* 2.x judged a value piece quoted by its shape after the scan: a quote at
	   both ends, the last one not escaped, however many closes sat between. A
	   selector body had to close right before its `]`, or the line was E014. */
	if (rules == SHCL_RULES_V2 && term == ',' && quote == SHCL_QUOTE_OPEN && content_end - start >= 2 && s.p[content_end - 1] == s.p[start]) {
		size_t run = 0;
		while (run < content_end - 1 - start && s.p[content_end - 2 - run] == '\\') run++;
		if (run % 2 == 0) {
			out->start = start + 1; out->end = content_end - 1;
			out->quote = s.p[start] == '"' ? SHCL_QUOTE_DOUBLE : SHCL_QUOTE_SINGLE;
			return min_sz(pos, s.n);
		}
	}
	out->start = start; out->end = content_end; out->quote = quote;
	return min_sz(pos, s.n);
}

/* The value half: everything from `from` on, split into pieces, with the
   comment found on the way. */
static void scan_value(ShclArena *a, ShclStr text, size_t from, ShclRules rules, ShclTokens *out) {
	size_t pos = from, stop_at, count = 0;
	for (;;) {
		ShclPiece piece; size_t stop = scan_piece(text, pos, ',', rules, 1, &piece);
		tok_push_elem(a, out, piece);
		if (piece.quote != SHCL_QUOTE_NONE || piece.end > piece.start) {
			count++;
			if (out->cap && count > out->cap) { out->capped = 1; out->value_start = from; out->value_end = from; return; }
		}
		if (stop < text.n && text.p[stop] == ',') { pos = stop + 1; continue; }
		if (stop < text.n) { out->has_comment = 1; out->comment = stop; }
		stop_at = stop;
		break;
	}
	size_t va = from; skip_wsp(text, &va);
	size_t vb = stop_at;
	while (vb > va && is_wsp((unsigned char)text.p[vb - 1])) vb--;
	out->value_start = min_sz(va, vb); out->value_end = vb;
	if (out->nelem) {
		ShclPiece *last = &out->elements[out->nelem - 1];
		if (last->quote != SHCL_QUOTE_SINGLE && last->quote != SHCL_QUOTE_DOUBLE && last->end > vb)
			last->end = vb > last->start ? vb : last->start;
	}
}
static void tokenize_value(ShclArena *a, ShclStr text, size_t from, ShclRules rules, ShclTokens *out) {
	tok_clear(out);
	scan_value(a, text, from, rules, out);
}

/* Tokenize one line (sep = ':') or one lookup path (path: the bare `*` name
   wildcard is admitted, and a `#` in a selector body is the `[#N]` index
   rather than a comment); the CLI's --set passes '='. out is cleared and
   reused, so a parse allocates once per document rather than once per line.
   text is the line after its indent, or the path. */
static void tokenize(ShclArena *a, ShclStr text, char sep, int path, ShclRules rules, ShclTokens *out) {
	tok_clear(out);
	ShclStr s = text;
	size_t pos = 0;
	for (;;) {
		skip_wsp(s, &pos);
		if (pos >= s.n) { tok_fault(out, pos, "expected a field name"); return; }
		ShclSegTok seg; memset(&seg, 0, sizeof seg);
		if (s.p[pos] == '"' || s.p[pos] == '\'') {
			size_t close;
			if (!quote_close(s, pos, rules, &close)) { tok_fault(out, pos, "unterminated quote in a field name"); return; }
			seg.name.start = pos + 1; seg.name.end = close;
			seg.name.quote = s.p[pos] == '"' ? SHCL_QUOTE_DOUBLE : SHCL_QUOTE_SINGLE;
			pos = close + 1;
		} else if (path && s.p[pos] == '*') {
			seg.star = 1; pos++;
			seg.name.start = pos - 1; seg.name.end = pos; seg.name.quote = SHCL_QUOTE_NONE;
		} else {
			size_t start = pos;
			while (pos < s.n && is_bare_name_char((unsigned char)s.p[pos])) pos++;
			if (pos == start) { tok_fault(out, pos, "expected a field name"); return; }
			seg.name.start = start; seg.name.end = pos; seg.name.quote = SHCL_QUOTE_NONE;
		}
		skip_wsp(s, &pos);
		int have_open = 0; size_t open = 0;
		if (pos < s.n && s.p[pos] == '[') { have_open = 1; open = pos; }
		if (!have_open && rules == SHCL_RULES_V2 && pos < s.n && s.p[pos] == sep) {
			size_t q = pos + 1; skip_wsp(s, &q);
			if (q < s.n && s.p[q] == '[') { have_open = 1; open = q; }
		}
		if (have_open) {
			if (seg.star) { tok_fault(out, open, "selector on a name wildcard"); return; }
			ShclPiece piece; size_t stop = scan_piece(s, open + 1, ']', rules, !path, &piece);
			if (stop >= s.n || s.p[stop] != ']') { tok_fault(out, open, "unterminated selector"); return; }
			if (piece.end == piece.start && piece.quote == SHCL_QUOTE_NONE) { tok_fault(out, open, "empty selector"); return; }
			if (piece.quote == SHCL_QUOTE_OPEN && rules == SHCL_RULES_V2) { tok_fault(out, open, "unterminated quote in a selector"); return; }
			seg.selector = piece; seg.has_selector = 1;
			pos = stop + 1;
			skip_wsp(s, &pos);
		}
		tok_push_seg(a, out, seg);
		if (pos >= s.n) return;
		char b = s.p[pos];
		if (b == '.') { pos++; continue; }
		if (b == sep) { out->has_sep = 1; out->sep = pos; scan_value(a, text, pos + 1, rules, out); return; }
		if (comment_at(s, pos)) { out->has_comment = 1; out->comment = pos; return; }
		tok_fault(out, pos, "unexpected character after the path");
		return;
	}
}

/* The two arrays belong to the arena they were grown in. Kept across a
   second document, the next push would write into the first one's memory,
   and once that one is freed, into memory nobody owns. A guard, not a
   promise: a freed document whose address comes back looks the same, so the
   header asks the caller to zero the struct. A per-document serial would
   need a global counter, and C99 has no atomics to keep two threads off it. */
static void tok_adopt(ShclArena *a, shcl_tokens *t) {
	if (t->arena == a) return;
	t->segments = NULL; t->seg_cap = 0; t->nseg = 0;
	t->elements = NULL; t->elem_cap = 0; t->nelem = 0;
	t->arena = a;
}
void shcl_tokenize(shcl_doc *d, const char *text, size_t len, char sep, int path, shcl_rules rules, shcl_tokens *out) {
	ShclStr s; s.p = text ? text : ""; s.n = len;
	tok_adopt(&d->reads, out);
	tokenize(&d->reads, s, sep, path, rules, out);
}
void shcl_tokenize_value(shcl_doc *d, const char *text, size_t len, size_t from, shcl_rules rules, shcl_tokens *out) {
	ShclStr s; s.p = text ? text : ""; s.n = len;
	tok_adopt(&d->reads, out);
	tokenize_value(&d->reads, s, from, rules, out);
}

/* The text of a piece as the reader sees it: escapes applied inside double
   quotes, everything else the slice it came in as - the store sites own the
   copy question (s_keep, or an explicit dup). */
static ShclStr piece_text(ShclArena *a, const ShclPiece *p, ShclStr text) {
	ShclStr raw = s_slice(text, p->start, p->end);
	return p->quote == SHCL_QUOTE_DOUBLE ? apply_escapes(a, raw) : raw;
}

/* The element a value piece makes; 0 for an empty bare slot (dropped, never
   an error). */
static int element_of(ShclArena *a, const ShclPiece *p, ShclStr text, ShclElement *out) {
	if (p->quote == SHCL_QUOTE_NONE && p->end == p->start) return 0;
	out->text = piece_text(a, p, text);
	out->quoted = piece_quoted(p->quote);
	return 1;
}

// The value the tokenized pieces give. Element texts go into `a` (only when
// built - see piece_text); the growing element vector is a per-call temporary
// and goes to `tmp`, so only the exact-size final array reaches the document
// arena.
static ShclValue cell_of_tokens(ShclArena *a, ShclArena *tmp, const ShclTokens *tok, ShclStr text) {
	ShclVecEl els = {0};
	for (size_t i = 0; i < tok->nelem; i++) {
		ShclElement e;
		if (element_of(a, &tok->elements[i], text, &e)) ShclVecEl_push(tmp, &els, e);
	}
	if (els.len == 0) return v_empty();
	ShclValue v; memset(&v, 0, sizeof v); v.kind = V_CELL;
	v.els = (ShclElement *)arena_alloc(a, els.len * sizeof(ShclElement));
	memcpy(v.els, els.data, els.len * sizeof(ShclElement));
	v.nels = els.len;
	return v;
}

// Reads text as the value half of a line - see shcl_set_literal.
static int literal_value(ShclArena *a, ShclArena *tmp, ShclStr text, ShclValue *out);

/* The character a \u or \U escape names, from the hex digits in after: four
   after u, eight after U, as in TOML. Returns how many digits it takes, or 0
   for a short run, a surrogate or a value past U+10FFFF. */
static size_t unicode_escape(unsigned char kind, ShclStr after, uint32_t *cp) {
	size_t n = kind == 'u' ? 4 : 8;
	if (after.n < n) return 0;
	uint32_t v = 0;
	for (size_t i = 0; i < n; i++) {
		unsigned char h = (unsigned char)after.p[i]; uint32_t d;
		if (h >= '0' && h <= '9') d = (uint32_t)(h - '0');
		else if (h >= 'a' && h <= 'f') d = (uint32_t)(h - 'a' + 10);
		else if (h >= 'A' && h <= 'F') d = (uint32_t)(h - 'A' + 10);
		else return 0;
		v = v << 4 | d;
	}
	if (v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) return 0;
	*cp = v; return n;
}
// gen-escapes.py: begin
/* Generated from Unicode 18.0 by cicd/utility/gen-escapes.py. Edit the script, not this block. */
static const uint32_t invisible_ranges[][2] = {
	{0x0000, 0x0008},
	{0x000B, 0x001F},
	{0x007F, 0x009F},
	{0x00AD, 0x00AD},
	{0x034F, 0x034F},
	{0x061C, 0x061C},
	{0x115F, 0x1160},
	{0x17B4, 0x17B5},
	{0x180B, 0x180F},
	{0x200B, 0x200B},
	{0x200E, 0x200F},
	{0x2028, 0x202E},
	{0x2060, 0x206F},
	{0x3164, 0x3164},
	{0xFE00, 0xFE0F},
	{0xFEFF, 0xFEFF},
	{0xFFA0, 0xFFA0},
	{0xFFF0, 0xFFFB},
	{0x1BCA0, 0x1BCA3},
	{0x1D173, 0x1D17A},
	{0xE0000, 0xE0FFF},
};
static const uint32_t selector_ranges[][2] = {
	{0x180B, 0x180D},
	{0x180F, 0x180F},
	{0xFE00, 0xFE0F},
	{0xE0100, 0xE01EF},
};
// gen-escapes.py: end
static int in_ranges(const uint32_t (*ranges)[2], size_t n, uint32_t c) {
	for (size_t k = 0; k < n && ranges[k][0] <= c; k++) if (c <= ranges[k][1]) return 1;
	return 0;
}
/* Characters canonical output writes as a \u escape, so a reader of the file
   sees every character that is there: controls with no short escape, the line
   and paragraph separators, the interlinear annotation marks, and what Unicode
   calls default-ignorable, such as zero-width spaces, direction marks and tag
   characters. The zero-width joiner and non-joiner are not in the list, since
   emoji and several scripts need them, and invisible_at keeps two more kinds
   where text needs them. */
static int invisible(uint32_t c) {
	return (c < ' ' || c > '~') && in_ranges(invisible_ranges, sizeof invisible_ranges / sizeof *invisible_ranges, c);
}
/* A character a variation selector can modify: one written as itself that is
   not a blank or a joiner. Another selector is not one, so a run of them
   cannot contain hidden text. */
static int selector_base(uint32_t c) { return c > ' ' && c != 0x200C && c != 0x200D && !invisible(c); }
static int flag_spec(uint32_t c) { return (c >= 0xE0030 && c <= 0xE0039) || (c >= 0xE0061 && c <= 0xE007A); }
/* Whether the tag at t[i] is part of a subdivision flag, as UTS #51 defines
   one: U+1F3F4, three to seven tag digits or lowercase tag letters, and the
   cancel tag. */
static int flag_tag(ShclStr t, size_t i) {
	size_t start = i; int count = 0; uint32_t c;
	for (;;) {
		size_t l = utf8_last(s_slice(t, 0, start), &c);
		if (l == 0 || !flag_spec(c)) break;
		if (++count > 7) return 0;
		start -= l;
	}
	if (utf8_last(s_slice(t, 0, start), &c) != 4 || c != 0x1F3F4) return 0;
	count = 0;
	for (size_t k = start; k < t.n;) {
		k += utf8_decode(t.p, t.n, k, &c);
		if (!flag_spec(c)) return c == 0xE007F && count >= 3;
		if (++count > 7) return 0;
	}
	return 0;
}
/* The width of the character at t[i] when it is written as a \u escape, else
   0. A variation selector stays as written directly after a visible
   character, and the tags of a subdivision flag stay too; anywhere else they
   hide text. A byte that is not UTF-8 is never escaped. */
static size_t invisible_at(ShclStr t, size_t i, uint32_t *cp) {
	size_t l = utf8_decode(t.p, t.n, i, cp);
	if (l == 1 && *cp >= 0x80) return 0;
	if (!invisible(*cp)) return 0;
	if (in_ranges(selector_ranges, sizeof selector_ranges / sizeof *selector_ranges, *cp)) {
		uint32_t p; size_t pl = utf8_last(s_slice(t, 0, i), &p);
		return pl > 0 && !(pl == 1 && p >= 0x80) && selector_base(p) ? 0 : l;
	}
	if (*cp >= 0xE0020 && *cp <= 0xE007F) return flag_tag(t, i) ? 0 : l;
	return l;
}
/* \u takes four digits, so a character past U+FFFF is written with \U. */
static void sb_put_unicode_escape(ShclArena *a, ShclSB *s, uint32_t cp) {
	static const char hex[] = "0123456789ABCDEF";
	int digits = cp > 0xFFFF ? 8 : 4;
	char b[10] = {'\\', cp > 0xFFFF ? 'U' : 'u'};
	for (int k = 0; k < digits; k++) b[2 + k] = hex[(cp >> (4 * (digits - 1 - k))) & 0xF];
	sb_put(a, s, b, (size_t)(2 + digits));
}

// Escape processing (a double-quoted piece): \t \n \\ \" \' \uXXXX
// \UXXXXXXXX. An unknown pair stays literal, which only 2.x text still
// reaches: the current rules refuse one (E023) before anything is read. Text
// with no backslash comes back as the slice it came in as - nearly every
// piece, and a copy per piece would be most of a parse's memory.
static ShclStr resolve_escapes(ShclArena *a, ShclStr s, shcl_rules rules) {
	if (!s.n || !memchr(s.p, '\\', s.n)) return s;
	ShclSB out = {0};
	size_t i = 0;
	while (i < s.n) {
		uint32_t c; size_t l = utf8_decode(s.p, s.n, i, &c); i += l;
		if (c != '\\') { sb_put_cp(a, &out, c); continue; }
		if (i >= s.n) { sb_putc(a, &out, '\\'); break; }
		uint32_t d; size_t l2 = utf8_decode(s.p, s.n, i, &d); i += l2;
		switch (d) {
		case 't': sb_putc(a, &out, '\t'); break;
		case 'n': sb_putc(a, &out, '\n'); break;
		case '\\': sb_putc(a, &out, '\\'); break;
		case '"': sb_putc(a, &out, '"'); break;
		case '\'': sb_putc(a, &out, '\''); break;
		case 'u': case 'U': {
			uint32_t cp; size_t n = rules == SHCL_RULES_CURRENT ? unicode_escape((unsigned char)d, s_slice(s, i, s.n), &cp) : 0;
			if (n) { sb_put_cp(a, &out, cp); i += n; }
			else { sb_putc(a, &out, '\\'); sb_put_cp(a, &out, d); }
			break;
		}
		default: sb_putc(a, &out, '\\'); sb_put_cp(a, &out, d); break;
		}
	}
	return sb_S(&out);
}
static ShclStr apply_escapes(ShclArena *a, ShclStr s) { return resolve_escapes(a, s, SHCL_RULES_CURRENT); }
/* The 2.x reading, for migrate: no \u, so 2.x kept \u0041 as written. */
static ShclStr apply_escapes_v2(ShclArena *a, ShclStr s) { return resolve_escapes(a, s, SHCL_RULES_V2); }

/* The character after the first backslash in raw that starts no escape, or
   the u or U of one that names no character. Only meaningful for a
   double-quoted piece. */
static int unknown_escape(ShclStr raw, uint32_t *c) {
	if (!raw.n || !memchr(raw.p, '\\', raw.n)) return 0;
	for (size_t i = 0; i < raw.n; i++) {
		if (raw.p[i] != '\\') continue;
		/* A double-quoted piece cannot end on a lone backslash: it would have
		   escaped the closing quote. */
		if (i + 1 >= raw.n) return 0;
		i++;
		switch (raw.p[i]) {
		case 't': case 'n': case '\\': case '"': case '\'': break;
		case 'u': case 'U': {
			uint32_t cp;
			if (!unicode_escape((unsigned char)raw.p[i], s_slice(raw, i + 1, raw.n), &cp)) { *c = (unsigned char)raw.p[i]; return 1; }
			break;
		}
		default: utf8_decode(raw.p, raw.n, i, c); return 1;
		}
	}
	return 0;
}
/* unknown_escape by the 2.x rules, which had no \u: a pair 2.x kept as
   written, so migrate doubles its backslash. */
static int v2_kept_escape(ShclStr raw) {
	for (size_t i = 0; i < raw.n; i++) {
		if (raw.p[i] != '\\') continue;
		if (i + 1 >= raw.n) return 0;
		i++;
		switch (raw.p[i]) {
		case 't': case 'n': case '\\': case '"': case '\'': break;
		default: return 1;
		}
	}
	return 0;
}
/* A 2.x pair that is a real \u escape now: 2.x read the text as written and
   the current rules read a character, so only --from-2x can say which. */
static int unicode_pair_differs(ShclStr raw) {
	uint32_t uc;
	return v2_kept_escape(raw) && !unknown_escape(raw, &uc);
}

/* The first unknown escape in a double-quoted name, selector body or, when
   values is set, value element (E023). "C:\work\new" is the usual way to get
   one, and by then its \n is already a newline, so the line is refused rather
   than read with the pair kept. A raw block's info string is not escape text,
   so a fence line passes values 0. */
static int bad_escape(const ShclTokens *tok, ShclStr text, int values, uint32_t *c) {
	for (size_t i = 0; i < tok->nseg; i++) {
		const ShclSegTok *seg = &tok->segments[i];
		if (seg->name.quote == SHCL_QUOTE_DOUBLE && unknown_escape(s_slice(text, seg->name.start, seg->name.end), c)) return 1;
		if (seg->has_selector && seg->selector.quote == SHCL_QUOTE_DOUBLE && unknown_escape(s_slice(text, seg->selector.start, seg->selector.end), c)) return 1;
	}
	if (values)
		for (size_t i = 0; i < tok->nelem; i++)
			if (tok->elements[i].quote == SHCL_QUOTE_DOUBLE && unknown_escape(s_slice(text, tok->elements[i].start, tok->elements[i].end), c)) return 1;
	return 0;
}

/* A double-quoted value that starts like a Windows path, a drive (C:\) or a
   share (\\), and holds a \t or \n escape (E024). "C:\temp" would read as C:,
   a tab and emp, which a path almost never means. Any other pair made the line
   E023 before this is asked. */
static int path_like(const ShclPiece *p, ShclStr text) {
	if (p->quote != SHCL_QUOTE_DOUBLE) return 0;
	ShclStr raw = s_slice(text, p->start, p->end);
	int drive = raw.n >= 3 && ((raw.p[0] | 0x20) >= 'a' && (raw.p[0] | 0x20) <= 'z') && raw.p[1] == ':' && raw.p[2] == '\\';
	if (!drive && !(raw.n >= 2 && raw.p[0] == '\\' && raw.p[1] == '\\')) return 0;
	for (size_t i = 0; i + 1 < raw.n;) {
		if (raw.p[i] != '\\') { i++; continue; }
		if (raw.p[i + 1] == 't' || raw.p[i + 1] == 'n') return 1;
		i += 2;
	}
	return 0;
}

/* True when a double-quoted spelling would be E024. */
static int spells_path_escape(ShclStr quoted) {
	if (quoted.n < 2 || quoted.p[0] != '"') return 0;
	ShclPiece p; p.start = 1; p.end = quoted.n - 1; p.quote = SHCL_QUOTE_DOUBLE;
	return path_like(&p, quoted);
}

// --- Durations and sizes ---------------------------------------------------
// A number with a unit, or a bare number whose unit the field name or the
// caller gives.

static uint64_t duration_millis(shcl_duration_unit u) {
	switch (u) {
	case SHCL_DURATION_MS: return 1;
	case SHCL_DURATION_S: return 1000;
	case SHCL_DURATION_M: return 60000;
	case SHCL_DURATION_H: return 3600000;
	case SHCL_DURATION_D: return 86400000;
	default: return 0;
	}
}
static uint64_t size_bytes(shcl_size_unit u, int decimal) {
	uint64_t k = decimal ? 1000 : 1024;
	switch (u) {
	case SHCL_SIZE_B: return 1;
	case SHCL_SIZE_KB: return k;
	case SHCL_SIZE_MB: return k * k;
	case SHCL_SIZE_GB: return k * k * k;
	case SHCL_SIZE_TB: return k * k * k * k;
	case SHCL_SIZE_KIB: return (uint64_t)1 << 10;
	case SHCL_SIZE_MIB: return (uint64_t)1 << 20;
	case SHCL_SIZE_GIB: return (uint64_t)1 << 30;
	case SHCL_SIZE_TIB: return (uint64_t)1 << 40;
	default: return 0;
	}
}
static const char *const duration_spellings[] = {"", "ms", "s", "m", "h", "d"};
static const char *const size_spellings[] = {"", "B", "KB", "MB", "GB", "TB", "KiB", "MiB", "GiB", "TiB"};
const char *shcl_duration_unit_spelling(shcl_duration_unit u) {
	return (unsigned)u < sizeof duration_spellings / sizeof *duration_spellings ? duration_spellings[u] : "";
}
const char *shcl_size_unit_spelling(shcl_size_unit u) {
	return (unsigned)u < sizeof size_spellings / sizeof *size_spellings ? size_spellings[u] : "";
}
shcl_duration_unit shcl_duration_unit_of(const char *s, size_t n) {
	for (size_t u = 1; u < sizeof duration_spellings / sizeof *duration_spellings; u++)
		if (strlen(duration_spellings[u]) == n && memcmp(duration_spellings[u], s, n) == 0) return (shcl_duration_unit)u;
	return SHCL_DURATION_NONE;
}
/* Letter case is read, since Mb is megabits to most readers; kB is the one
   other spelling taken. */
shcl_size_unit shcl_size_unit_of(const char *s, size_t n) {
	if (n == 2 && memcmp(s, "kB", 2) == 0) return SHCL_SIZE_KB;
	for (size_t u = 1; u < sizeof size_spellings / sizeof *size_spellings; u++)
		if (strlen(size_spellings[u]) == n && memcmp(size_spellings[u], s, n) == 0) return (shcl_size_unit)u;
	return SHCL_SIZE_NONE;
}
/* The longest duration a read gives, in milliseconds: Go's time.Duration
   range, so every binding holds every duration another one reads. */
#define SHCL_DURATION_MAX_MS 9223372036854ULL

/* Field name endings that give a bare number its unit, after a `-` or `_`.
   min, m and s are left out: `retries-min` is a minimum, and a trailing s is
   usually a plural. A capitalized word (`timeoutMs`) is not a boundary,
   since names fold to lower case and fmt writes them folded. */
static const struct { const char *end; shcl_duration_unit unit; } duration_names[] = {
	{"ms", SHCL_DURATION_MS}, {"sec", SHCL_DURATION_S}, {"seconds", SHCL_DURATION_S},
	{"minutes", SHCL_DURATION_M}, {"hours", SHCL_DURATION_H}, {"days", SHCL_DURATION_D},
};
static const struct { const char *end; shcl_size_unit unit; } size_names[] = {
	{"bytes", SHCL_SIZE_B}, {"kb", SHCL_SIZE_KB}, {"mb", SHCL_SIZE_MB}, {"gb", SHCL_SIZE_GB}, {"tb", SHCL_SIZE_TB},
	{"kib", SHCL_SIZE_KIB}, {"mib", SHCL_SIZE_MIB}, {"gib", SHCL_SIZE_GIB}, {"tib", SHCL_SIZE_TIB},
};
/* name ends in end, in any letter case, after a `-` or `_`. */
static int name_ends(ShclStr name, const char *end) {
	size_t n = strlen(end);
	if (name.n <= n) return 0;
	size_t at = name.n - n;
	for (size_t i = 0; i < n; i++) if ((name.p[at + i] | 0x20) != end[i]) return 0;
	return name.p[at - 1] == '-' || name.p[at - 1] == '_';
}
static shcl_duration_unit name_duration_unit(ShclStr name) {
	for (size_t i = 0; i < sizeof duration_names / sizeof *duration_names; i++)
		if (name_ends(name, duration_names[i].end)) return duration_names[i].unit;
	return SHCL_DURATION_NONE;
}
static shcl_size_unit name_size_unit(ShclStr name) {
	for (size_t i = 0; i < sizeof size_names / sizeof *size_names; i++)
		if (name_ends(name, size_names[i].end)) return size_names[i].unit;
	return SHCL_SIZE_NONE;
}
/* A decimal number at the start of s: digits, then a point and more digits
   if there is a point. The two digit runs and where it ended. */
static int decimal_at(ShclStr s, ShclStr *ip, ShclStr *fp, size_t *end) {
	size_t i = 0;
	while (i < s.n && is_adigit((unsigned char)s.p[i])) i++;
	if (i == 0) return 0;
	*ip = s_slice(s, 0, i);
	if (i >= s.n || s.p[i] != '.') { *fp = s_slice(s, i, i); *end = i; return 1; }
	size_t j = i + 1;
	while (j < s.n && is_adigit((unsigned char)s.p[j])) j++;
	if (j == i + 1) return 0;
	*fp = s_slice(s, i + 1, j); *end = j; return 1;
}
/* int.frac times scale, exactly: 0 when that is not a whole number or does
   not fit, so 1.5s is 1500 ms and 0.0001s is refused. At most 18 digits
   after the point count, which keeps the sum in 64 bits: the fraction's
   share is below scale, and dividing out their common factor first gets it
   without a wider product. */
static int scaled(ShclStr ip, ShclStr fp, uint64_t scale, uint64_t *out) {
	while (ip.n && ip.p[0] == '0') { ip.p++; ip.n--; }
	while (fp.n && fp.p[fp.n - 1] == '0') fp.n--;
	if (ip.n > 19 || fp.n > 18) return 0;
	uint64_t whole = 0;
	for (size_t i = 0; i < ip.n; i++) {
		uint64_t dg = (uint64_t)(ip.p[i] - '0');
		if (whole > (UINT64_MAX - dg) / 10) return 0;
		whole = whole * 10 + dg;
	}
	if (whole && scale > UINT64_MAX / whole) return 0;
	uint64_t total = whole * scale;
	if (fp.n) {
		uint64_t part = 0, den = 1;
		for (size_t i = 0; i < fp.n; i++) { part = part * 10 + (uint64_t)(fp.p[i] - '0'); den *= 10; }
		uint64_t a = scale, b = den;
		while (b) { uint64_t t = a % b; a = b; b = t; }
		uint64_t step = den / a;
		if (part % step) return 0;
		uint64_t add = part / step * (scale / a);
		if (total > UINT64_MAX - add) return 0;
		total += add;
	}
	*out = total; return 1;
}
/* A duration in whole milliseconds, and the units the text used, as a bit
   set (bit u for unit u): parts such as `1h 30m`, largest unit first and each
   once, with blanks allowed between a number and its unit and between parts.
   A bare number takes bare, and fails without one. No sign. */
static int parse_duration_text(ShclStr t, shcl_duration_unit bare, int64_t *ms, unsigned *units, shcl_duration_unit *first) {
	t = s_trim_wsp(t);
	ShclStr ip, fp; size_t end;
	*units = 0; *first = SHCL_DURATION_NONE;
	if (decimal_at(t, &ip, &fp, &end) && end == t.n) {
		uint64_t v;
		if (bare == SHCL_DURATION_NONE || !scaled(ip, fp, duration_millis(bare), &v) || v > SHCL_DURATION_MAX_MS) return 0;
		*ms = (int64_t)v; return 1;
	}
	ShclStr rest = t;
	uint64_t total = 0;
	shcl_duration_unit last = SHCL_DURATION_NONE;
	while (rest.n) {
		if (!decimal_at(rest, &ip, &fp, &end)) return 0;
		rest = trim_wsp_start(s_slice(rest, end, rest.n));
		size_t n = 0;
		while (n < rest.n && ((unsigned char)rest.p[n] | 0x20) >= 'a' && ((unsigned char)rest.p[n] | 0x20) <= 'z') n++;
		shcl_duration_unit u = shcl_duration_unit_of(rest.p, n);
		if (u == SHCL_DURATION_NONE || (last != SHCL_DURATION_NONE && last <= u)) return 0;
		uint64_t v;
		if (!scaled(ip, fp, duration_millis(u), &v) || total > UINT64_MAX - v) return 0;
		total += v;
		if (last == SHCL_DURATION_NONE) *first = u;
		last = u;
		*units |= 1u << u;
		rest = trim_wsp_start(s_slice(rest, n, rest.n));
	}
	if (last == SHCL_DURATION_NONE || total > SHCL_DURATION_MAX_MS) return 0;
	*ms = (int64_t)total; return 1;
}
/* A size in whole bytes, and the unit the text used (NONE for a bare
   number): a number, blanks allowed, then a unit. A bare number takes bare,
   and fails without one. No sign. */
static int parse_size_text(ShclStr t, shcl_size_unit bare, int decimal, int64_t *bytes, shcl_size_unit *unit) {
	t = s_trim_wsp(t);
	ShclStr ip, fp; size_t end;
	if (!decimal_at(t, &ip, &fp, &end)) return 0;
	ShclStr rest = trim_wsp_start(s_slice(t, end, t.n));
	*unit = SHCL_SIZE_NONE;
	if (rest.n && (*unit = shcl_size_unit_of(rest.p, rest.n)) == SHCL_SIZE_NONE) return 0;
	shcl_size_unit use = *unit != SHCL_SIZE_NONE ? *unit : bare;
	uint64_t v;
	if (use == SHCL_SIZE_NONE || !scaled(ip, fp, size_bytes(use, decimal), &v) || v > (uint64_t)INT64_MAX) return 0;
	*bytes = (int64_t)v; return 1;
}
/* Whether a name ends in a duration or size unit. Asked before a value's text
   is built for unit_clash, since most names do not, and that text goes in
   scratch nothing frees until the parse ends. */
static int unit_named(ShclStr name) {
	return name_duration_unit(name) != SHCL_DURATION_NONE || name_size_unit(name) != SHCL_SIZE_NONE;
}
/* A value in another unit than the one its field name ends in (H005), as
   `timeout-ms: 5s`. The value's unit is the one read, so this is a hint. */
static int unit_clash(ShclArena *a, ShclStr name, ShclStr text, ShclStr *msg) {
	const char *v = NULL, *nm = NULL;
	shcl_duration_unit nu = name_duration_unit(name);
	int64_t x; unsigned units; shcl_duration_unit first;
	if (nu != SHCL_DURATION_NONE && parse_duration_text(text, SHCL_DURATION_NONE, &x, &units, &first) && !(units & (1u << nu))) {
		v = shcl_duration_unit_spelling(first); nm = shcl_duration_unit_spelling(nu);
	}
	shcl_size_unit su = name_size_unit(name), vu;
	if (!v && su != SHCL_SIZE_NONE && parse_size_text(text, SHCL_SIZE_NONE, 0, &x, &vu) && vu != SHCL_SIZE_NONE && vu != su) {
		v = shcl_size_unit_spelling(vu); nm = shcl_size_unit_spelling(su);
	}
	if (!v) return 0;
	ShclSB m = {0};
	sb_puts(a, &m, "value is in "); sb_puts(a, &m, v); sb_puts(a, &m, " and the name says "); sb_puts(a, &m, nm);
	sb_puts(a, &m, "; the value's unit is the one read");
	*msg = sb_S(&m); return 1;
}

static const char path_msg[] = "value starts like a Windows path, and its \\t or \\n would read as a tab or newline; write a backslash as '\\\\' or use single quotes";

static int any_path_like(const ShclTokens *tok, ShclStr text) {
	for (size_t k = 0; k < tok->nelem; k++)
		if (path_like(&tok->elements[k], text)) return 1;
	return 0;
}

static ShclStr escape_msg(ShclArena *a, uint32_t c) {
	ShclSB m = {0};
	if (c == 'u' || c == 'U') {
		sb_puts(a, &m, "bad escape '\\"); sb_putc(a, &m, (char)c);
		sb_puts(a, &m, "' in double quotes; \\u takes 4 hex digits and \\U takes 8, naming a Unicode character; write a backslash as '\\\\' or use single quotes");
		return sb_S(&m);
	}
	sb_puts(a, &m, "unknown escape '\\");
	if (c == '\n') sb_puts(a, &m, "\\n");
	else if (c == '\r') sb_puts(a, &m, "\\r");
	else if (c == '\t') sb_puts(a, &m, "\\t");
	else sb_put_cp(a, &m, c);
	sb_puts(a, &m, "' in double quotes; write a backslash as '\\\\' or use single quotes");
	return sb_S(&m);
}

/* The restriction a QUOTED [value] selector adds on top of the display
   match: quoting selects the scalar spelling only, so the scalar "a, b" and
   the list a, b stop meeting the same selector. */
static int single_scalar(const ShclValue *v) { return v->kind == V_CELL && v->nels == 1; }

/* The predicate a `[value]` selector matches with: the display form, which is
   built from logical strings, so `["q\"uote"]` finds `'q"uote'` - a
   logical-string match, not spelling against spelling. */
static ShclStr disp_key(ShclArena *a, const ShclValue *v) {
	return value_display(a, v);
}

// FNV-1a, fed the same byte sequence the old built key strings contained -
// the accelerator maps key on a u64 and a hit verifies against the arena, so
// the strings themselves never get built. The hash only has to be stable
// within one parse, not injective; a collision just chains in the slot.
static uint64_t fnv_byte(uint64_t h, unsigned char b) { return (h ^ b) * 1099511628211ull; }
static uint64_t fnv_str(uint64_t h, ShclStr s) {
	for (size_t i = 0; i < s.n; i++) h = fnv_byte(h, (unsigned char)s.p[i]);
	return h;
}
/* A length prefix in decimal, written without allocating. */
static uint64_t fnv_dec(uint64_t h, size_t n) {
	char buf[20];
	size_t i = sizeof buf;
	do { buf[--i] = (char)('0' + n % 10); n /= 10; } while (n);
	while (i < sizeof buf) h = fnv_byte(h, (unsigned char)buf[i++]);
	return h;
}
static uint64_t cmap_hash(ShclStr name, ShclStr key) {
	uint64_t h = 1469598103934665603ull;
	h = fnv_str(h, name);
	h = fnv_byte(h, 0xFFu); /* separator; equality still verifies both parts */
	return fnv_str(h, key);
}
static uint64_t name_key(size_t parent, ShclStr name) {
	uint64_t h = 1469598103934665603ull;
	h = fnv_dec(h, parent);
	h = fnv_byte(h, 0xFFu);
	return fnv_str(h, name);
}

/* Hash of the (name, merge-key) pair, spelling the merge-key byte sequence -
   'e', or each cell element (and the raw info-string) length-prefixed so the
   sequence is injective - without building it as a string. Elements are the
   logical strings, so two spellings of one string are one instance: names
   have followed that rule since 2.0, and a `[value]` selector matches on the
   logical text already. */
static uint64_t merge_hash(ShclStr name, const ShclValue *v) {
	uint64_t h = 1469598103934665603ull;
	h = fnv_str(h, name);
	h = fnv_byte(h, 0xFFu);
	if (v->kind == V_EMPTY) return fnv_byte(h, 'e');
	if (v->kind == V_CELL) {
		h = fnv_byte(h, 'c'); h = fnv_byte(h, ':');
		for (size_t i = 0; i < v->nels; i++) {
			h = fnv_dec(h, v->els[i].text.n);
			h = fnv_byte(h, ':');
			h = fnv_str(h, v->els[i].text);
		}
		return h;
	}
	/* Info-string is part of identity (a `sql` and a `python` block are
	   different values even with equal bodies); fence style is not. */
	h = fnv_byte(h, 'r'); h = fnv_byte(h, ':');
	h = fnv_dec(h, v->raw->info.n);
	h = fnv_byte(h, ':');
	h = fnv_str(h, v->raw->info);
	return fnv_str(h, v->raw->content);
}

/* The exact (name, merge-key) equality a hashed hit is verified with -
   compares what the two key strings would have held, element by element. The
   quoted flag is not part of the key, same as the strings never included it. */
static int value_eq(const ShclValue *a, const ShclValue *b) {
	if (a->kind != b->kind) return 0;
	if (a->kind == V_EMPTY) return 1;
	if (a->kind == V_CELL) {
		if (a->nels != b->nels) return 0;
		for (size_t i = 0; i < a->nels; i++)
			if (!s_eq(a->els[i].text, b->els[i].text)) return 0;
		return 1;
	}
	return s_eq(a->raw->info, b->raw->info) && s_eq(a->raw->content, b->raw->content);
}
static int merge_eq(ShclStr name_a, const ShclValue *va, ShclStr name_b, const ShclValue *vb) {
	return s_eq(name_a, name_b) && value_eq(va, vb);
}


/* Hash of the (name, display) pair a `[value]` selector matches with - what
   disp_key gives, streamed instead of built. */
static uint64_t disp_hash(ShclStr name, const ShclValue *v) {
	uint64_t h = 1469598103934665603ull;
	h = fnv_str(h, name);
	h = fnv_byte(h, 0xFFu);
	if (v->kind == V_CELL) {
		for (size_t i = 0; i < v->nels; i++) {
			if (i) { h = fnv_byte(h, ','); h = fnv_byte(h, ' '); }
			h = fnv_str(h, v->els[i].text);
		}
	} else if (v->kind == V_RAW) {
		h = fnv_str(h, v->raw->content);
	}
	return h;
}
/* The query-side twin of disp_hash: the selector's text is the logical
   string already, so its bytes feed straight in. */
static uint64_t disp_hash_text(ShclStr name, ShclStr want) { return cmap_hash(name, want); }

// Opening fence: a run of >=3 backticks or tildes, then an optional info string.
// The info is a slice of rest; the parse stores it as a slice of the retained
// input copy.
typedef struct { int ok; unsigned char ch; size_t len; ShclStr info; } ShclFence;
static ShclFence fence_open(ShclStr rest) {
	ShclFence f; f.ok = 0; f.ch = 0; f.len = 0; f.info = s_empty();
	if (rest.n == 0) return f;
	unsigned char first = (unsigned char)rest.p[0];
	if (first != '`' && first != '~') return f;
	size_t run = 0;
	while (run < rest.n && (unsigned char)rest.p[run] == first) run++;
	if (run < 3) return f;
	f.ok = 1; f.ch = first; f.len = run;
	f.info = s_trim_wsp(s_slice(rest, run, rest.n));
	return f;
}
/* The fence a field line's value opens, if it opens one. A line that did not
   tokenize opens one too when a fence follows its first colon past where it
   stopped making sense, with no comment before that colon. Read as lines, such
   a body would bind, and its closing fence would open a block of its own. a
   holds the value's pieces for a line that did not tokenize. */
static ShclFence line_fence(ShclArena *a, const ShclTokens *tok, ShclStr rest) {
	if (tok->has_fault) {
		size_t sep = tok->fault_at;
		while (sep < rest.n && rest.p[sep] != ':' && !comment_at(rest, sep)) sep++;
		if (sep >= rest.n || rest.p[sep] != ':') return fence_open(s_empty());
		ShclTokens value; memset(&value, 0, sizeof value);
		tokenize_value(a, rest, sep + 1, SHCL_RULES_CURRENT, &value);
		return fence_open(s_slice(rest, value.value_start, value.value_end));
	}
	if (!tok->has_sep) { ShclFence f; f.ok = 0; f.ch = 0; f.len = 0; f.info = s_empty(); return f; }
	/* A capped scan zeroed the value, and a fence is told by its leading run
	   alone. */
	return fence_open(tok->capped ? s_trim_wsp(s_slice(rest, tok->value_start, rest.n)) : s_slice(rest, tok->value_start, tok->value_end));
}

/* The fence a line opens under the field above it, read as a value. */
static ShclFence child_fence(ShclArena *a, ShclStr rest, ShclTokens *tok) {
	tokenize_value(a, rest, 0, SHCL_RULES_CURRENT, tok);
	/* A capped scan zeroed the value, and a fence is told by its leading run
	   alone. */
	return fence_open(tok->capped ? rest : s_slice(rest, tok->value_start, tok->value_end));
}
/* min_len is the opening fence's length, which the grammar puts at three or
   more, so the length test already rules out the empty line the loop below
   would otherwise accept. */
static int is_fence_close(ShclStr line, unsigned char ch, size_t min_len) {
	ShclStr t = s_trim_sp_tab(line);
	if (t.n < min_len) return 0;
	for (size_t i = 0; i < t.n; i++) if ((unsigned char)t.p[i] != ch) return 0;
	return 1;
}

/* The leading space/tab run of a line (the indent). */
static ShclStr leading_ws(ShclStr line) {
	size_t n = 0;
	while (n < line.n && (line.p[n] == ' ' || line.p[n] == '\t')) n++;
	return s_slice(line, 0, n);
}

/* Remove a raw block's nesting indent from one content line: only what the
   line actually shares with it, so a shallower line (whitespace-only, or
   written flush left) keeps its own spacing rather than being blanked. */
static ShclStr strip_common(ShclStr line, ShclStr common) {
	size_t k = 0;
	while (k < common.n && k < line.n && common.p[k] == line.p[k]) k++;
	return s_slice(line, k, line.n);
}

// --- Migration: a 2.x document rewritten for the current lexical rules -------

static ShclStr quote_text_as(ShclArena *a, ShclStr t, shcl_rules rules);
static ShclStr quote_double_as(ShclArena *a, ShclStr t, shcl_rules rules);
static int needs_quotes(ShclStr t);
static ShclStr emit_element(ShclArena *a, const ShclElement *e);
static ShclElement new_element(ShclStr text);
static ShclStr escape_name(ShclArena *a, ShclStr name);
static ShclStr escape_name_as(ShclArena *a, ShclStr name, shcl_rules rules);
static ShclStr diag_name(ShclArena *a, ShclStr name);
static ShclStr diag_value(ShclArena *a, const ShclValue *v);
static int index_shape(ShclStr body);

/* One edit to a line: replace start..end with the text. */
typedef struct { size_t start, end; ShclStr with; } ShclEdit;
DEFINE_VEC(ShclVecEdit, ShclEdit)
static void edit_push(ShclArena *a, ShclVecEdit *v, size_t start, size_t end, ShclStr with) {
	ShclEdit e; e.start = start; e.end = end; e.with = with; ShclVecEdit_push(a, v, e);
}

static ShclStr s_splice(ShclArena *a, ShclStr text, ShclVecEdit *edits) {
	/* Stable by start, the way the reference sorts, so two edits at one
	   offset keep the order they were found in. */
	for (size_t i = 1; i < edits->len; i++) {
		ShclEdit e = edits->data[i]; size_t j = i;
		while (j > 0 && edits->data[j - 1].start > e.start) { edits->data[j] = edits->data[j - 1]; j--; }
		edits->data[j] = e;
	}
	ShclSB out = {0};
	size_t at = 0;
	for (size_t i = 0; i < edits->len; i++) {
		sb_putS(a, &out, s_slice(text, at, edits->data[i].start));
		sb_putS(a, &out, edits->data[i].with);
		at = edits->data[i].end;
	}
	sb_putS(a, &out, s_slice(text, at, text.n));
	return sb_S(&out);
}

/* True when the current tokenizer reads this spelling as one whole piece,
   quoted the same way, with exactly this text, so nothing has to change. */
static int reads_same(ShclArena *a, ShclStr spelling, int quoted, ShclStr logical) {
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize_value(a, spelling, 0, SHCL_RULES_CURRENT, &tok);
	uint32_t c;
	return tok.nelem == 1
		&& tok.value_start == 0 && tok.value_end == spelling.n
		&& piece_quoted(tok.elements[0].quote) == quoted
		&& tok.elements[0].quote != SHCL_QUOTE_OPEN
		&& !bad_escape(&tok, spelling, 1, &c)
		&& !path_like(&tok.elements[0], spelling)
		&& s_eq(piece_text(a, &tok.elements[0], spelling), logical);
}

/* How a changed piece is written. 2.x read a backslash in bare and
   single-quoted text as an escape too, and double quotes are where both rule
   sets read one alike. No \u goes in, since 2.x would keep it as written.
   So the migrated file reads the same under 2.x, and a second run changes
   nothing. A line break in a value that starts like a Windows path has no
   such spelling: written this way it is E024, so the caller counts it lost. */
static ShclStr migrate_spelling(ShclArena *a, ShclStr logical, int bare) {
	if (memchr(logical.p, '\\', logical.n)) return quote_double_as(a, logical, SHCL_RULES_V2);
	if (bare && !needs_quotes(logical)) return logical;
	return quote_text_as(a, logical, SHCL_RULES_V2);
}

/* True when 2.x read this bare `[...]` body as the JSON-habit array rather
   than a discriminator: more than one element, where a comma behind a
   backslash was not one. */
static int v2_bracket_array(ShclArena *a, ShclStr body) {
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize_value(a, body, 0, SHCL_RULES_V2, &tok);
	return tok.nelem > 1;
}

/* The counters a line rewrite reports back, and the one thing it asks. */
typedef struct { int from_v2; size_t ambiguous; size_t lost; } ShclMigrating;

/* The re-spellings a value's pieces need. Each piece is read the 2.x way
   (escapes everywhere, an open quote kept whole, a quote at both ends making
   it quoted) and rewritten only where the current rules would read the same
   text as something else. */
static void value_edits(ShclArena *a, ShclStr text, const ShclTokens *tok, ShclVecEdit *edits, ShclMigrating *st) {
	for (size_t i = 0; i < tok->nelem; i++) {
		const ShclPiece *p = &tok->elements[i];
		ShclStr raw = s_slice(text, p->start, p->end);
		int quoted = piece_quoted(p->quote);
		size_t ea = quoted ? p->start - 1 : p->start, eb = quoted ? p->end + 1 : p->end;
		if (p->quote == SHCL_QUOTE_NONE && !memchr(raw.p, '\\', raw.n) && raw.n) continue;
		ShclStr logical = apply_escapes_v2(a, raw);
		if (reads_same(a, s_slice(text, ea, eb), quoted, logical)) continue;
		/* A resolved escape is the one edit that turns on which rule set wrote
		   the file: these bytes say one thing under 2.x and another here. An
		   open quote or an empty slot reads alike either way, so it still goes,
		   and so does an unknown pair in double quotes, which both kept. A \u
		   in double quotes is a character now and was text in 2.x. */
		int differs = p->quote == SHCL_QUOTE_DOUBLE ? unicode_pair_differs(raw) : !s_eq(logical, raw);
		if (differs && !st->from_v2) { st->ambiguous++; continue; }
		ShclStr spelling = migrate_spelling(a, logical, !(quoted || p->quote == SHCL_QUOTE_OPEN));
		/* Written the way 2.x read it, the line is E024 and binds nothing. */
		if (spells_path_escape(spelling)) st->lost++;
		edit_push(a, edits, ea, eb, spelling);
	}
}

/* fence_on/ch/len: the block a child-indent or same-line fence opened, which
   the caller copies through until its close. */
static ShclStr migrate_line(ShclArena *ta, ShclArena *a, ShclStr rest, ShclTokens *tok, int *fence_on, unsigned char *fence_ch, size_t *fence_len, ShclMigrating *st) {
	if (rest.n == 0 || rest.p[0] == '#') return rest;
	/* A child-indent fence: 2.x read the info string to the end of the line. */
	ShclFence f = fence_open(rest);
	if (f.ok) { *fence_on = 1; *fence_ch = f.ch; *fence_len = f.len; return rest; }
	ShclVecEdit edits = {0};
	if (rest.p[0] == '*' && rest.n > 1 && is_wsp((unsigned char)rest.p[1])) {
		tokenize_value(ta, rest, 1, SHCL_RULES_V2, tok);
		/* A bare comma was refused (E010), so there is nothing to convert. */
		if (tok->nelem == 1) value_edits(a, rest, tok, &edits, st);
	} else {
		tokenize(ta, rest, ':', 0, SHCL_RULES_V2, tok);
		if (tok->has_fault) return rest;
		size_t last = tok->nseg - 1;
		for (size_t i = 0; i < tok->nseg; i++) {
			const ShclSegTok *seg = &tok->segments[i];
			ShclStr name = s_slice(rest, seg->name.start, seg->name.end);
			/* An unknown pair in double quotes read the same in 2.x, and is
			   E023 now, so its backslash is doubled whichever wrote the file.
			   A \u pair is a character now, so that one needs --from-2x. */
			if (seg->name.quote == SHCL_QUOTE_DOUBLE && v2_kept_escape(name)) {
				if (unicode_pair_differs(name) && !st->from_v2) st->ambiguous++;
				else edit_push(a, &edits, seg->name.start - 1, seg->name.end + 1, escape_name_as(a, apply_escapes_v2(a, name), SHCL_RULES_V2));
			}
			if (seg->name.quote == SHCL_QUOTE_SINGLE && !s_eq(apply_escapes_v2(a, name), name)) {
				if (st->from_v2) edit_push(a, &edits, seg->name.start - 1, seg->name.end + 1, escape_name_as(a, apply_escapes_v2(a, name), SHCL_RULES_V2));
				else st->ambiguous++;
			}
			if (!seg->has_selector) continue;
			const ShclPiece *sel = &seg->selector;
			int quoted = piece_quoted(sel->quote);
			/* Back from the body to the `[`, and forward to the `]`. */
			size_t open = quoted ? sel->start - 1 : sel->start;
			while (open > 0 && is_wsp((unsigned char)rest.p[open - 1])) open--;
			open -= 1;
			size_t close = quoted ? sel->end + 1 : sel->end;
			while (rest.p[close] != ']') close++;
			int has_colon = 0; size_t colon = 0;
			size_t k = open;
			while (k > 0 && is_wsp((unsigned char)rest.p[k - 1])) k--;
			if (k > 0 && rest.p[k - 1] == ':') { has_colon = 1; colon = k - 1; }
			ShclStr body = s_slice(rest, sel->start, sel->end);
			ShclStr logical = apply_escapes_v2(a, body);
			int unknown = sel->quote == SHCL_QUOTE_DOUBLE && v2_kept_escape(body);
			if (i == last && !tok->has_sep) {
				if (has_colon) {
					/* name:[disc] with nothing after it: 2.x read it as
					   `name: disc`. Two or more elements in there was refused
					   as a bracket array - a comma behind a backslash was not
					   one - and an index or the wildcard was refused as a
					   selector, so those stay as written. A bare body moves
					   into a value, where a fence run opens a raw block and a
					   leading `[` is bracket text, so the emitter writes it. */
					if (!quoted && (index_shape(body) || (body.n == 1 && body.p[0] == '*'))) return rest;
					/* 2.x bound the bracket array, as one folded string. There
					   is no spelling to move that to - a value beginning with
					   `[` is bracket text now - so the binding goes, and the
					   caller hears about it rather than reading exit 0. */
					if (!quoted && v2_bracket_array(a, body)) { st->lost++; return rest; }
					if (!s_eq(logical, body) && !st->from_v2) { st->ambiguous++; continue; }
					ShclStr spelling;
					if (!s_eq(logical, body)) spelling = migrate_spelling(a, logical, 0);
					else if (quoted && !unknown) spelling = s_trim_wsp(s_slice(rest, open + 1, close));
					else spelling = migrate_spelling(a, logical, 1);
					/* As a value, a path holding a \t or \n is E024. */
					if (spells_path_escape(spelling)) {
						spelling = migrate_spelling(a, logical, 0);
						if (spells_path_escape(spelling)) st->lost++;
					}
					ShclSB sb = {0}; sb_puts(a, &sb, ": "); sb_putS(a, &sb, spelling);
					edit_push(a, &edits, colon, close + 1, sb_S(&sb));
					continue;
				}
			} else if (has_colon) {
				/* The colon goes, and one space after it when the author
				   spaced both sides, so `base : [x]` comes out `base [x]`. */
				int spaced = colon > 0 && is_wsp((unsigned char)rest.p[colon - 1]) && is_wsp((unsigned char)rest.p[colon + 1]);
				edit_push(a, &edits, colon, colon + 1 + (size_t)spaced, s_empty());
			}
			/* Double quotes already read alike on both sides, so only the other
			   spellings turn on which rule set wrote the file. */
			if (unknown && unicode_pair_differs(body) && !st->from_v2) st->ambiguous++;
			else if (unknown) edit_push(a, &edits, sel->start - 1, sel->end + 1, migrate_spelling(a, logical, 0));
			else if (!s_eq(logical, body) && sel->quote != SHCL_QUOTE_DOUBLE) {
				if (st->from_v2) {
					size_t ea = quoted ? sel->start - 1 : sel->start, eb = quoted ? sel->end + 1 : sel->end;
					edit_push(a, &edits, ea, eb, migrate_spelling(a, logical, 0));
				} else st->ambiguous++;
			}
		}
		if (tok->has_sep) {
			/* A same-line fence: the info string ran to the end of the line. */
			ShclFence vf = fence_open(s_slice(rest, tok->value_start, rest.n));
			if (vf.ok) { *fence_on = 1; *fence_ch = vf.ch; *fence_len = vf.len; return s_splice(a, rest, &edits); }
			value_edits(a, rest, tok, &edits, st);
		}
	}
	return s_splice(a, rest, &edits);
}

/* Walks a document's lines and tells raw-body content from the rest, the way
   one rule set reads the file: the current rules find a block where the parser
   does, and the 2.x rules where the rewrite does. */
typedef struct {
	ShclRules rules;
	ShclTokens tok;
	int fence_on; unsigned char fence_ch; size_t fence_len;
	/* Only the blocks a line opens are wanted, not what the rewrite counts. */
	ShclMigrating dry;
} ShclRawLines;

static void raw_lines_init(ShclRawLines *w, ShclRules rules) {
	memset(w, 0, sizeof *w);
	w->rules = rules;
	w->dry.from_v2 = 1;
}

/* The raw block a line opens under the current rules: a fence line under a
   field, or a field line whose value is a fence, read as the parser reads
   them. A line refused for where it sits or for its text still takes its
   body. */
static ShclFence opens_raw(ShclArena *ta, ShclStr rest, ShclTokens *tok) {
	rest = trim_wsp_start(rest);
	if (rest.p[0] == '`' || rest.p[0] == '~') return child_fence(ta, rest, tok);
	if (rest.p[0] == '#' || rest.p[0] == '*') return fence_open(s_empty());
	tokenize(ta, rest, ':', 0, SHCL_RULES_CURRENT, tok);
	return line_fence(ta, tok, rest);
}

/* The next line's text past its indent in *rest, or 0 when the line is part of
   a raw block, fences included. */
static int raw_lines_step(ShclArena *ta, ShclArena *sc, ShclRawLines *w, ShclStr line, ShclStr *rest) {
	size_t bn = line.n;
	while (bn > 0 && line.p[bn - 1] == '\r') bn--;
	ShclStr body = s_slice(line, 0, bn);
	if (w->fence_on) {
		if (is_fence_close(body, w->fence_ch, w->fence_len)) w->fence_on = 0;
		return 0;
	}
	*rest = trim_wsp_end(s_slice(body, leading_ws(body).n, body.n));
	/* Only a line with a run of three backticks or tildes can open a block, so
	   the rest skip the tokenizer. */
	for (size_t k = 0; k + 2 < rest->n; k++) {
		char c = rest->p[k];
		if ((c == '`' || c == '~') && rest->p[k + 1] == c && rest->p[k + 2] == c) {
			if (w->rules == SHCL_RULES_CURRENT) {
				ShclFence f = opens_raw(ta, *rest, &w->tok);
				w->fence_on = f.ok; w->fence_ch = f.ch; w->fence_len = f.len;
			} else {
				arena_reset(sc);
				migrate_line(ta, sc, *rest, &w->tok, &w->fence_on, &w->fence_ch, &w->fence_len, &w->dry);
			}
			break;
		}
	}
	return 1;
}

/* shcl_format_version() on text with the BOM already off: the major a
   `##    Format   N` line names, or -1 when the document has none. Digits
   that do not fit 32 bits read as "newer than this", since whatever wrote them
   was not 2.x.
   A Format line pasted into a raw body is that block's content, and taking it
   as the file's would rewrite a current file, or leave an old one alone. Where
   the blocks are turns on the rules the file was written under, which is what
   the line itself says: a line naming this format counts outside the blocks
   the parser finds, and an older one outside the blocks the rewrite skips. The
   two differ on a single-quoted name ending in a backslash. A file naming this
   format on any line has nothing to migrate, so the highest line decides: the
   stamp migrate adds comes after an older one, and the next run has to see it. */
static int64_t format_line_version(ShclArena *ta, ShclArena *sc, ShclStr text) {
	size_t headn = sizeof(SHCL_FORMAT_LINE_HEAD) - 1, start = 0;
	int64_t found = -1;
	ShclRawLines now, then;
	raw_lines_init(&now, SHCL_RULES_CURRENT);
	raw_lines_init(&then, SHCL_RULES_V2);
	for (size_t i = 0; i <= text.n; i++) {
		if (i < text.n && text.p[i] != '\n') continue;
		ShclStr raw = s_slice(text, start, i);
		start = i + 1;
		ShclStr current = s_empty(), old = s_empty();
		int in_now = raw_lines_step(ta, sc, &now, raw, &current);
		int in_then = raw_lines_step(ta, sc, &then, raw, &old);
		ShclStr line = in_now ? current : old;
		if (!(in_now || in_then) || line.n <= headn || memcmp(line.p, SHCL_FORMAT_LINE_HEAD, headn) != 0) continue;
		ShclStr n = s_slice(line, headn, line.n);
		uint64_t u = 0; int ok = 1, big = 0;
		for (size_t k = 0; k < n.n; k++) {
			if (!is_adigit((unsigned char)n.p[k])) { ok = 0; break; }
			if (!big) { u = u * 10 + (uint64_t)(n.p[k] - '0'); if (u > UINT32_MAX) big = 1; }
		}
		if (!ok) continue;
		int64_t v = big ? SHCL_FORMAT_MAJOR : (int64_t)u;
		if (v >= SHCL_FORMAT_MAJOR) {
			if (in_now) return v;
		} else if (in_then && v > found) found = v;
	}
	return found;
}

/* Which file this is cannot be read off the text: `p: 'C:\temp'` is one value
   under 2.x and another under these rules, so rewriting a 3.0 file changes what
   it says. So the version line decides. A file that names this format comes
   back untouched; one that names an older format, or a caller passing from_v2,
   gets the backslash re-spellings; anything else gets every other rewrite and
   leaves those pieces alone, counted in st->ambiguous for the caller to refuse
   over. A rewritten file is stamped with the version line, so the second run
   has an answer the first one did not; stamp 0 leaves it off. */
/* The line ending most of the text's lines end with. A tie goes to LF. */
static const char *majority_eol(ShclStr text) {
	size_t crlf = 0, lf = 0;
	for (size_t i = 0; i < text.n; i++) {
		if (text.p[i] != '\n') continue;
		if (i > 0 && text.p[i - 1] == '\r') crlf++;
		else lf++;
	}
	return crlf > lf ? "\r\n" : "\n";
}

static ShclStr migrate(ShclArena *a, ShclArena *sc, ShclStr text, ShclMigrating *st, int *current, int stamp) {
	ShclStr whole = text, bom = s_empty();
	if (text.n >= 3 && (unsigned char)text.p[0] == 0xEF && (unsigned char)text.p[1] == 0xBB && (unsigned char)text.p[2] == 0xBF) {
		bom = s_slice(text, 0, 3);
		text = s_slice(text, 3, text.n);
	}
	int64_t version = format_line_version(a, sc, text);
	if (version >= SHCL_FORMAT_MAJOR) { *current = 1; return whole; }
	if (version >= 0) st->from_v2 = 1;
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	int changed = 0;
	ShclSB out = {0};
	sb_reserve(a, &out, whole.n + 96);
	sb_putS(a, &out, bom);
	int fence_on = 0; unsigned char fence_ch = 0; size_t fence_len = 0;
	/* The output as the parser will read it, for where its raw blocks are. */
	ShclRawLines now;
	raw_lines_init(&now, SHCL_RULES_CURRENT);
	int split = 0;
	size_t start = 0, lineno = 0;
	for (size_t i = 0; i <= text.n; i++) {
		if (i < text.n && text.p[i] != '\n') continue;
		ShclStr line = s_slice(text, start, i);
		if (lineno++ > 0) sb_putc(a, &out, '\n');
		size_t out_start = out.len;
		int raw_then = fence_on;
		size_t bn = line.n;
		while (bn > 0 && line.p[bn - 1] == '\r') bn--;
		ShclStr body = s_slice(line, 0, bn), cr = s_slice(line, bn, line.n);
		if (fence_on) {
			if (is_fence_close(body, fence_ch, fence_len)) fence_on = 0;
			sb_putS(a, &out, line);
		} else {
			arena_reset(sc);
			ShclStr indent = leading_ws(body);
			ShclStr rest_full = s_slice(body, indent.n, body.n);
			ShclStr rest = trim_wsp_end(rest_full);
			ShclStr migrated = migrate_line(a, sc, rest, &tok, &fence_on, &fence_ch, &fence_len, st);
			if (!s_eq(migrated, rest)) changed = 1;
			sb_putS(a, &out, indent);
			sb_putS(a, &out, migrated);
			sb_putS(a, &out, s_slice(rest_full, rest.n, rest_full.n));
			sb_putS(a, &out, cr);
		}
		/* Lines one rule set reads as a raw body and the other as fields are
		   one more thing that reads two ways, counted once per run of them. */
		ShclStr written; written.p = out.data + out_start; written.n = out.len - out_start;
		ShclStr ignored = s_empty();
		int differs = (!raw_lines_step(a, sc, &now, written, &ignored)) != raw_then;
		if (differs && !split && !st->from_v2) st->ambiguous++;
		split = differs;
		start = i + 1;
	}
	/* Stamping a file whose ambiguous pieces were left alone would claim a
	   migration that did not finish, and the next run would then skip it. A
	   document that never closes its raw block has nowhere to put the line
	   either, under either rule set: appended, it would be another line of the
	   block's content. The lines end the way most of the file's do. */
	if (stamp && st->ambiguous == 0 && !fence_on && !now.fence_on) {
		const char *eol = majority_eol(text);
		if (out.len && out.data[out.len - 1] != '\n') sb_puts(a, &out, eol);
		sb_puts(a, &out, SHCL_FORMAT_LINE); sb_puts(a, &out, eol);
		if (changed) { sb_puts(a, &out, SHCL_MIGRATED_LINE); sb_puts(a, &out, eol); }
	}
	return sb_S(&out);
}

/* The two arenas a migration builds in. They sit off the frame so the recovery
   point below can still reach them: a longjmping SHCL_OOM skips this frame, and
   an ordinary local is indeterminate by the time the jump arrives. */
typedef struct { ShclArena a, sc; } ShclMigrateOwn;

/* Rewrite a document written under the 2.x rules so this parser reads the
   same tree. Each line is read with the 2.x tokenizer and rewritten only
   where the two rule sets disagree: a bare or single-quoted piece whose
   backslash meant an escape is double-quoted with that escape; a piece that
   opened a quote it never closed is quoted whole; the name:[disc] selector
   sugar loses its colon, and on a last segment becomes `name: disc`, with
   `disc` written the way the formatter writes a value. A rewritten piece
   holding a backslash is double-quoted, so the result reads the same under
   2.x and a second run changes nothing.
   Everything else - comments, blank lines, raw bodies, layout, a line 2.x
   could not read - comes through as written. One shape has no spelling here
   at all: a fence label holding a `#`, which 2.x ran to the end of the line
   and which now ends at the `#`.
   The output and the reused tokens live in `a`; the per-line temporaries go
   to `sc`, reset per line, so a large document costs its own size and not
   every line's scratch on top. */
static shcl_migration migrate_text(const char *text, size_t len, int from_v2, int stamp) {
	ShclMigrateOwn *volatile own = (ShclMigrateOwn *)calloc(1, sizeof *own);
	if (!own) { SHCL_OOM(); abort(); }
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		/* An allocation failed below. Drop what the two arenas hold - about two
		   megabytes on a large file - then hand the failure on: the allocation
		   still failed, so the hook gets its say with nothing left behind. */
		ShclMigrateOwn *bad = own;
		arena_free(&bad->a); arena_free(&bad->sc); free(bad);
		SHCL_OOM();
		abort();
	}
	arena_guard(&own->a, &panic); arena_guard(&own->sc, &panic);
	ShclStr in; in.p = text ? text : ""; in.n = len;
	ShclMigrating st; st.from_v2 = from_v2; st.ambiguous = 0; st.lost = 0;
	shcl_migration m; m.current = 0;
	ShclStr r = migrate(&own->a, &own->sc, in, &st, &m.current, stamp);
	m.ambiguous = st.ambiguous; m.lost = st.lost; m.len = r.n;
	m.text = (char *)malloc(r.n + 1);
	if (!m.text) {
		ShclMigrateOwn *bad = own;
		arena_free(&bad->a); arena_free(&bad->sc); free(bad);
		SHCL_OOM(); abort();
	}
	memcpy(m.text, r.p, r.n); m.text[r.n] = 0;
	/* The recovery point is this frame's; the arenas go with it, so nothing is
	   left holding a jmp_buf that has gone out of scope. */
	ShclMigrateOwn *done = own;
	arena_free(&done->a); arena_free(&done->sc); free(done);
	return m;
}

shcl_migration shcl_migrate(const char *text, size_t len, int from_v2) {
	return migrate_text(text, len, from_v2, 1);
}

shcl_migration shcl_migrate_unstamped(const char *text, size_t len, int from_v2) {
	return migrate_text(text, len, from_v2, 0);
}

int64_t shcl_format_version(const char *text, size_t len) {
	ShclMigrateOwn *volatile own = (ShclMigrateOwn *)calloc(1, sizeof *own);
	if (!own) { SHCL_OOM(); abort(); }
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		ShclMigrateOwn *bad = own;
		arena_free(&bad->a); arena_free(&bad->sc); free(bad);
		SHCL_OOM();
		abort();
	}
	arena_guard(&own->a, &panic); arena_guard(&own->sc, &panic);
	ShclStr in; in.p = text ? text : ""; in.n = len;
	if (in.n >= 3 && (unsigned char)in.p[0] == 0xEF && (unsigned char)in.p[1] == 0xBB && (unsigned char)in.p[2] == 0xBF) in = s_slice(in, 3, in.n);
	int64_t v = format_line_version(&own->a, &own->sc, in);
	ShclMigrateOwn *done = own;
	arena_free(&done->a); arena_free(&done->sc); free(done);
	return v;
}

/* The Schema line's reference. The line is new in this format, so the blocks
   are the parser's. */
static int schema_line_ref(ShclArena *ta, ShclArena *sc, ShclStr text, ShclStr *out) {
	size_t headn = sizeof(SHCL_SCHEMA_LINE_HEAD) - 1, start = 0;
	ShclRawLines lines;
	raw_lines_init(&lines, SHCL_RULES_CURRENT);
	for (size_t i = 0; i <= text.n; i++) {
		if (i < text.n && text.p[i] != '\n') continue;
		ShclStr raw = s_slice(text, start, i);
		start = i + 1;
		ShclStr rest = s_empty();
		if (!raw_lines_step(ta, sc, &lines, raw, &rest)) continue;
		if (rest.n >= headn && memcmp(rest.p, SHCL_SCHEMA_LINE_HEAD, headn) == 0) {
			ShclStr r = s_trim_wsp(s_slice(rest, headn, rest.n));
			if (r.n) { *out = r; return 1; }
		}
	}
	return 0;
}

/* The recovery path reads only the volatile carrier, so -Wclobbered's guess
   about the walk inlined below is wrong here the way it is for do_parse. */
#if defined(__GNUC__) && !defined(__clang__)
	#pragma GCC diagnostic push
	#pragma GCC diagnostic ignored "-Wclobbered"
#endif
const char *shcl_schema_ref(const char *text, size_t len, size_t *ref_len) {
	ShclMigrateOwn *volatile own = (ShclMigrateOwn *)calloc(1, sizeof *own);
	if (!own) { SHCL_OOM(); abort(); }
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		ShclMigrateOwn *bad = own;
		arena_free(&bad->a); arena_free(&bad->sc); free(bad);
		SHCL_OOM();
		abort();
	}
	arena_guard(&own->a, &panic); arena_guard(&own->sc, &panic);
	ShclStr in; in.p = text ? text : ""; in.n = len;
	if (in.n >= 3 && (unsigned char)in.p[0] == 0xEF && (unsigned char)in.p[1] == 0xBB && (unsigned char)in.p[2] == 0xBF) in = s_slice(in, 3, in.n);
	ShclStr r = s_empty();
	int found = schema_line_ref(&own->a, &own->sc, in, &r);
	ShclMigrateOwn *done = own;
	arena_free(&done->a); arena_free(&done->sc); free(done);
	if (ref_len) *ref_len = found ? r.n : 0;
	return found ? r.p : NULL;
}
#if defined(__GNUC__) && !defined(__clang__)
	#pragma GCC diagnostic pop
#endif

// --- Path scanner (shared by file lines and accessor queries) ----------------

typedef enum { SEL_NONE, SEL_VALUE, SEL_INDEX, SEL_WILDCARD } ShclSelTag;
/* quoted: the selector text was quoted in the path. A quoted selector is
   scalar-only - it matches a single-element value whose logical string equals
   the text - so quoting distinguishes the scalar "a, b" from the two-element
   list a, b, the same way quoting escapes elsewhere. */
typedef struct { ShclSelTag tag; ShclStr value; uint64_t index; int quoted; } ShclSelector; // u64: width must not vary with target pointer size
typedef struct { ShclStr name; ShclStr name_src; ShclSelector sel; int star; } ShclSegment; // name_src: as authored (unfolded, escapes as written); star: bare `*` name wildcard; quoted "*" stays a literal name
DEFINE_VEC(ShclVecSeg, ShclSegment)
typedef struct { int ok; ShclVecSeg segs; int has_value; ShclStr value_text; ShclStr err; } ShclPathScan; // value_text: after the separator colon, before any comment, trimmed

/* The spelling of an index selector - an optional `#`, an optional `+`, then
   digits - whatever its size. The grammar says 1*DIGIT, with no upper bound. */
static int index_shape(ShclStr body) {
	size_t i = 0;
	if (i < body.n && body.p[i] == '#') i++;
	if (i < body.n && body.p[i] == '+') i++;
	if (i >= body.n) return 0;
	for (; i < body.n; i++) if (!is_adigit((unsigned char)body.p[i])) return 0;
	return 1;
}
// usize parse: optional single leading '+', >=1 digit, no overflow.
static int parse_u64(ShclStr s, uint64_t *out) {
	size_t i = 0;
	if (i < s.n && s.p[i] == '+') i++;
	if (i >= s.n) return 0;
	uint64_t v = 0;
	for (; i < s.n; i++) {
		unsigned char c = (unsigned char)s.p[i];
		if (!is_adigit(c)) return 0;
		if (v > (UINT64_MAX - (c - '0')) / 10) return 0;
		v = v * 10 + (c - '0');
	}
	*out = v; return 1;
}

/* What a selector body means: `*` the wildcard, an index shape an index, a
   quoted body a value match, anything else a bare value match. */
static ShclSelector selector_of(ShclArena *a, const ShclPiece *p, ShclStr text) {
	ShclSelector sel; sel.tag = SEL_NONE; sel.value = s_empty(); sel.index = 0; sel.quoted = 0;
	ShclStr body = piece_text(a, p, text);
	uint64_t idx;
	if (piece_quoted(p->quote)) {
		// quotes force a value match, even numeric - and scalar-only
		sel.tag = SEL_VALUE; sel.value = body; sel.quoted = 1; return sel;
	}
	if (body.n == 1 && body.p[0] == '*') { sel.tag = SEL_WILDCARD; return sel; }
	if (body.n >= 1 && body.p[0] == '#' && parse_u64(s_slice(body, 1, body.n), &idx)) { sel.tag = SEL_INDEX; sel.index = idx; return sel; }
	if (parse_u64(body, &idx)) { sel.tag = SEL_INDEX; sel.index = idx; return sel; }
	if (index_shape(body)) {
		/* All digits but past u64: an index no instance can have, not a
		   value selector that would create one on a write. */
		sel.tag = SEL_INDEX; sel.index = UINT64_MAX; return sel;
	}
	sel.tag = SEL_VALUE; sel.value = body; return sel;
}

/* Whether any segment's selector opens a quote it never closes. The tokenizer
   records it; selector_of reads the body bare either way, so only the
   diagnostic depends on this. */
static int selector_open_quote(const ShclTokens *tok) {
	for (size_t i = 0; i < tok->nseg; i++)
		if (tok->segments[i].has_selector && tok->segments[i].selector.quote == SHCL_QUOTE_OPEN) return 1;
	return 0;
}

/* Bracket text (E019): a `[` first after the colon. Read off the first piece
   rather than the value span, since a capped scan empties the span and keeps
   the pieces it built. */
static int bracket_text(const ShclTokens *tok, ShclStr text) {
	if (!tok->has_sep || tok->nelem == 0) return 0;
	ShclPiece p = tok->elements[0];
	return p.quote == SHCL_QUOTE_NONE && p.end > p.start && p.start < text.n && text.p[p.start] == '[';
}

/* The path the tokens give. ok == 0 with err is the tokenizer's fault: input
   that is not a path at all, which the caller skips with a diagnostic. */
static ShclPathScan path_of(ShclArena *a, const ShclTokens *tok, ShclStr text) {
	ShclPathScan ps; ps.ok = 0; memset(&ps.segs, 0, sizeof ps.segs); ps.has_value = 0; ps.value_text = s_empty(); ps.err = s_empty();
	if (tok->has_fault) { ps.err = s_lit(tok->fault_why); return ps; }
	for (size_t i = 0; i < tok->nseg; i++) {
		const ShclSegTok *st = &tok->segments[i];
		ShclStr raw = s_slice(text, st->name.start, st->name.end);
		/* Names resolve escapes, the same rule values follow when they are
		   compared: two spellings of one name are one name. name_src keeps the
		   source spelling, which is what shcl_authored_name hands back.
		   A name with nothing to resolve and no upper case is already its own
		   resolved, folded spelling, so the source slice becomes the name and
		   nothing is allocated. That is nearly every name in a document, and
		   this runs once per segment per line. */
		ShclSegment seg;
		seg.name = name_plain(raw, st->name.quote) ? raw : fold_name(a, piece_text(a, &st->name, text));
		seg.name_src = raw; seg.star = st->star;
		if (st->has_selector) seg.sel = selector_of(a, &st->selector, text);
		else { seg.sel.tag = SEL_NONE; seg.sel.value = s_empty(); seg.sel.index = 0; seg.sel.quoted = 0; }
		ShclVecSeg_push(a, &ps.segs, seg);
	}
	ps.ok = 1; ps.has_value = tok->has_sep;
	if (tok->has_sep) ps.value_text = s_slice(text, tok->value_start, tok->value_end);
	return ps;
}

/* Scan a lookup path `a . b [sel] . c`: the document-line spelling plus the
   bare `*` segment (the name wildcard - any child name), which document lines
   never take; only lookups (reads, the writer probe, schema paths) do.
   Whitespace around dots, colons and brackets is insignificant. */
static ShclPathScan scan_lookup(ShclArena *a, ShclStr input) {
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize(a, input, ':', 1, SHCL_RULES_CURRENT, &tok);
	uint32_t c;
	if (bad_escape(&tok, input, 0, &c)) {
		ShclPathScan ps; ps.ok = 0; memset(&ps.segs, 0, sizeof ps.segs); ps.has_value = 0; ps.value_text = s_empty(); ps.err = s_lit("unknown escape in double quotes");
		return ps;
	}
	return path_of(a, &tok, input);
}

// --- small integer/string helpers used below --------------------------------

static void sb_put_u64(ShclArena *a, ShclSB *s, uint64_t v) {
	char t[24]; int j = 0;
	if (v == 0) t[j++] = '0';
	while (v) { t[j++] = (char)('0' + (v % 10)); v /= 10; }
	char o[24]; for (int k = 0; k < j; k++) o[k] = t[j - 1 - k];
	// cppcheck-suppress uninitvar  ## j >= 1 always (v==0 writes '0'), so o[0..j-1] is filled
	sb_put(a, s, o, (size_t)j);
}
static int s_contains_char(ShclStr s, char c) { for (size_t i = 0; i < s.n; i++) if (s.p[i] == c) return 1; return 0; }

typedef struct { ShclStr indent; size_t node; } ShclStackEnt;
DEFINE_VEC(ShclVecStack, ShclStackEnt)
typedef struct { int present; size_t idx; shcl_status miss; } ShclSlot;
DEFINE_VEC(ShclVecSlot, ShclSlot)

// --- coercion ("intelligent but safe"; Loose re-admits a closed list) --------

static const uint32_t SHCL_CURRENCY[] = {
	'$', 0xA2, 0xA3, 0xA4, 0xA5, 0x20A9, 0x20AA, 0x20AB, 0x20AC, 0x20AD,
	0x20AE, 0x20B1, 0x20B2, 0x20B4, 0x20B9, 0x20BA, 0x20BC, 0x20BD, 0x20BE, 0x20BF,
};
/* The remainder after a leading currency symbol, with the space a person writes
   after one taken off - `$ 1200` reached the int path's thousands branch, which
   trims, and the float path's shape test, which does not. */
static ShclStr strip_currency(ShclStr t) {
	if (t.n == 0) return t;
	uint32_t c; size_t l = utf8_decode(t.p, t.n, 0, &c);
	for (size_t i = 0; i < sizeof(SHCL_CURRENCY) / sizeof(SHCL_CURRENCY[0]); i++)
		if (c == SHCL_CURRENCY[i]) return trim_start(s_slice(t, l, t.n));
	return t;
}

// [+/-]digits, fully consumed, no overflow.
static int parse_i64_s(ShclStr t, int64_t *out) {
	size_t i = 0; int neg = 0;
	if (i < t.n && (t.p[i] == '+' || t.p[i] == '-')) { neg = (t.p[i] == '-'); i++; }
	if (i >= t.n) return 0;
	uint64_t v = 0; uint64_t lim = neg ? (uint64_t)INT64_MAX + 1 : (uint64_t)INT64_MAX;
	for (; i < t.n; i++) {
		unsigned char c = (unsigned char)t.p[i];
		if (!is_adigit(c)) return 0;
		if (v > (lim - (c - '0')) / 10) return 0;
		v = v * 10 + (c - '0');
	}
	if (neg) *out = (v == (uint64_t)INT64_MAX + 1) ? INT64_MIN : -(int64_t)v;
	else *out = (int64_t)v;
	return 1;
}
// radix_digit: the value of an ASCII hex digit, or -1.
static int radix_digit(unsigned char c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}
// radix_body: the digits after a `0x`, `0o` or `0b` prefix, either case, with
// their radix. A bare leading zero is decimal, so `0o` is the one way to write
// an octal mode.
static int radix_body(ShclStr t, unsigned *radix, ShclStr *digits) {
	if (t.n < 3 || t.p[0] != '0') return 0;
	switch (t.p[1]) {
	case 'x': case 'X': *radix = 16; break;
	case 'o': case 'O': *radix = 8; break;
	case 'b': case 'B': *radix = 2; break;
	default: return 0;
	}
	*digits = s_slice(t, 2, t.n);
	for (size_t i = 0; i < digits->n; i++) {
		int d = radix_digit((unsigned char)digits->p[i]);
		if (d < 0 || (unsigned)d >= *radix) return 0;
	}
	return 1;
}
// The magnitude, as u64 (guarded against u64 overflow). The sign range-check is
// the caller's, so the negative i64_min magnitude (0x8000000000000000) reads.
static int parse_radix_u64(ShclStr h, unsigned radix, uint64_t *out) {
	uint64_t v = 0;
	for (size_t i = 0; i < h.n; i++) {
		uint64_t d = (uint64_t)radix_digit((unsigned char)h.p[i]);
		if (v > (UINT64_MAX - d) / radix) return 0;
		v = v * radix + d;
	}
	*out = v; return 1;
}
static void split_byte(ShclArena *a, ShclStr s, char sep, ShclVecS *out) {
	size_t start = 0;
	for (size_t i = 0; i <= s.n; i++)
		if (i == s.n || s.p[i] == sep) { ShclVecS_push(a, out, s_slice(s, start, i)); start = i + 1; }
}

static int parse_int_text(ShclArena *a, const ShclElement *e, shcl_strictness level, int64_t *out);
static int parse_float_text(ShclArena *a, const ShclElement *e, shcl_strictness level, double *out);
static int parse_int_text_wide(ShclArena *a, const ShclElement *e, double *out);

static int float_shape_ok(ShclStr t) {
	ShclStr body = t;
	if (body.n > 0 && (body.p[0] == '+' || body.p[0] == '-')) body = s_slice(body, 1, body.n);
	if (body.n == 0) return 0;
	ShclStr mant = body, exp = s_empty(); int has_exp = 0;
	for (size_t i = 0; i < body.n; i++)
		if (body.p[i] == 'e' || body.p[i] == 'E') { mant = s_slice(body, 0, i); exp = s_slice(body, i + 1, body.n); has_exp = 1; break; }
	if (has_exp) {
		ShclStr xb = exp;
		if (xb.n > 0 && (xb.p[0] == '+' || xb.p[0] == '-')) xb = s_slice(xb, 1, xb.n);
		if (xb.n == 0 || !all_adigit0(xb)) return 0;
	}
	ShclStr ip = mant, fp = s_empty(); int has_dot = 0;
	for (size_t i = 0; i < mant.n; i++)
		if (mant.p[i] == '.') { ip = s_slice(mant, 0, i); fp = s_slice(mant, i + 1, mant.n); has_dot = 1; break; }
	(void)has_dot;
	if (ip.n == 0 && fp.n == 0) return 0;
	return all_adigit0(ip) && all_adigit0(fp);
}
static int strtod_full(ShclArena *a, ShclStr t, double *out) {
	const char *dp = dec_point(); size_t dn = strlen(dp);
	char *buf = (char *)arena_alloc(a, t.n * dn + 1);
	size_t j = 0;
	for (size_t i = 0; i < t.n; i++) {
		if (t.p[i] == '.') { memcpy(buf + j, dp, dn); j += dn; }
		else buf[j++] = t.p[i];
	}
	buf[j] = '\0';
	char *end; double v = strtod(buf, &end);
	if (end != buf + j) return 0;
	/* A literal past the double range is an infinity, which no double holds
	   and no setter can write back: BadType, like a text that is not a number
	   at all. */
	if (!isfinite(v)) return 0;
	*out = v; return 1;
}
static int parse_float_text(ShclArena *a, const ShclElement *e, shcl_strictness level, double *out) {
	ShclStr t = s_trim(e->text); int percent = 0;
	if (level == SHCL_LOOSE) {
		t = strip_currency(t);
		if (t.n > 0 && t.p[t.n - 1] == '%') { t = trim_end(s_slice(t, 0, t.n - 1)); percent = 1; }
	}
	double v;
	if (float_shape_ok(t)) {
		if (!strtod_full(a, t, &v)) return 0;
	} else {
		ShclElement el; el.text = t; el.quoted = e->quoted;
		int64_t iv;
		if (parse_int_text(a, &el, SHCL_STANDARD, &iv)) v = (double)iv;
		else if (!parse_int_text_wide(a, &el, &v)) return 0;
	}
	*out = percent ? v / 100.0 : v; return 1;
}
/* The integer spellings the plain float parse does not read - hex, octal,
   binary and quoted thousands - past the i64 range, as a double: a float read
   is bounded by the double, not by the integer type. A prefixed number goes in
   digit by digit in the double, so every binding rounds the same way; the
   spellings mirror parse_int_text. */
static int parse_int_text_wide(ShclArena *a, const ShclElement *e, double *out) {
	ShclStr t = s_trim(e->text);
	int neg = 0; ShclStr body = t;
	if (t.n > 0 && t.p[0] == '-') { neg = 1; body = s_slice(t, 1, t.n); }
	else if (t.n > 0 && t.p[0] == '+') body = s_slice(t, 1, t.n);
	double v = 0.0;
	unsigned radix; ShclStr digits;
	if (radix_body(body, &radix, &digits)) {
		for (size_t i = 0; i < digits.n; i++)
			v = v * (double)radix + (double)radix_digit((unsigned char)digits.p[i]);
	} else if (e->quoted && s_contains_char(body, ',')) {
		ShclVecS groups = {0}; split_byte(a, body, ',', &groups);
		int wf = groups.len > 1 && groups.data[0].n > 0 && groups.data[0].n <= 3 && all_adigit0(groups.data[0]);
		if (wf) for (size_t k = 1; k < groups.len; k++)
			if (groups.data[k].n != 3 || !all_adigit0(groups.data[k])) { wf = 0; break; }
		if (!wf) return 0;
		ShclSB b = {0};
		for (size_t i = 0; i < body.n; i++) if (body.p[i] != ',') sb_putc(a, &b, body.p[i]);
		if (!strtod_full(a, sb_S(&b), &v)) return 0;
	} else return 0;
	if (!isfinite(v)) return 0;
	*out = neg ? -v : v; return 1;
}
static int parse_int_text(ShclArena *a, const ShclElement *e, shcl_strictness level, int64_t *out) {
	ShclStr t = s_trim(e->text);
	if (level == SHCL_LOOSE) t = strip_currency(t);
	ShclStr body = t;
	if (body.n > 0 && (body.p[0] == '+' || body.p[0] == '-')) body = s_slice(body, 1, body.n);
	if (body.n > 0 && all_adigit0(body)) return parse_i64_s(t, out);
	/* Hex, octal and binary. */
	int neg = 0; ShclStr prefixed = t;
	if (t.n > 0 && t.p[0] == '-') { neg = 1; prefixed = s_slice(t, 1, t.n); }
	else if (t.n > 0 && t.p[0] == '+') { prefixed = s_slice(t, 1, t.n); }
	unsigned radix; ShclStr digits;
	if (radix_body(prefixed, &radix, &digits)) {
		uint64_t m; if (!parse_radix_u64(digits, radix, &m)) return 0;
		if (neg) {
			if (m == (uint64_t)INT64_MAX + 1) *out = INT64_MIN;
			else if (m <= (uint64_t)INT64_MAX) *out = -(int64_t)m;
			else return 0;
		} else {
			if (m <= (uint64_t)INT64_MAX) *out = (int64_t)m;
			else return 0;
		}
		return 1;
	}
	if (e->quoted && s_contains_char(t, ',')) {
		ShclStr sign_body = t;
		if (sign_body.n > 0 && (sign_body.p[0] == '+' || sign_body.p[0] == '-')) sign_body = s_slice(sign_body, 1, sign_body.n);
		ShclVecS groups = {0}; split_byte(a, sign_body, ',', &groups);
		int wf = groups.len > 1 && groups.data[0].n > 0 && groups.data[0].n <= 3 && all_adigit0(groups.data[0]);
		if (wf) for (size_t k = 1; k < groups.len; k++)
			if (groups.data[k].n != 3 || !all_adigit0(groups.data[k])) { wf = 0; break; }
		if (wf) {
			ShclSB b = {0}; for (size_t i = 0; i < t.n; i++) if (t.p[i] != ',') sb_putc(a, &b, t.p[i]);
			return parse_i64_s(sb_S(&b), out);
		}
	}
	if (level == SHCL_LOOSE) {
		double f;
		if (parse_float_text(a, e, level, &f)) {
			double r = round(f);
			/* INT64_MAX has no exact double, so the top bound is 2^63 itself,
			   exclusively; INT64_MIN is exact. */
			if (r >= -9223372036854775808.0 && r < 9223372036854775808.0) {
				*out = (int64_t)r;
				return 1;
			}
		}
	}
	return 0;
}
static int parse_bool_text(ShclArena *a, ShclStr t, shcl_strictness level, int *out) {
	ShclStr s = ascii_lower(a, s_trim(t));
	#define SHCL_EQ(z) (s.n == strlen(z) && memcmp(s.p, z, s.n) == 0)
	if (SHCL_EQ("true")) { *out = 1; return 1; }
	if (SHCL_EQ("false")) { *out = 0; return 1; }
	if (level == SHCL_STRICT) return 0;
	if (SHCL_EQ("yes") || SHCL_EQ("on") || SHCL_EQ("1")) { *out = 1; return 1; }
	if (SHCL_EQ("no") || SHCL_EQ("off") || SHCL_EQ("0")) { *out = 0; return 1; }
	if (level == SHCL_LOOSE) {
		if (SHCL_EQ("t") || SHCL_EQ("y") || SHCL_EQ("enable") || SHCL_EQ("enabled")) { *out = 1; return 1; }
		if (SHCL_EQ("f") || SHCL_EQ("n") || SHCL_EQ("disable") || SHCL_EQ("disabled")) { *out = 0; return 1; }
	}
	#undef SHCL_EQ
	return 0;
}

// --- date/time (closed whitelist; shape match, then calendar validation) -----

static uint32_t month_from_name(ShclArena *a, ShclStr s) {
	static const char *names[] = {
		"jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec",
		"january","february","march","april","june","july","august","september",
		"october","november","december"
	};
	static const uint32_t vals[] = { 1,2,3,4,5,6,7,8,9,10,11,12, 1,2,3,4,6,7,8,9,10,11,12 };
	ShclStr l = ascii_lower(a, s);
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
		if (l.n == strlen(names[i]) && memcmp(l.p, names[i], l.n) == 0) return vals[i];
	return 0;
}
static uint32_t days_in_month(int32_t y, uint32_t m) {
	switch (m) {
	case 1: case 3: case 5: case 7: case 8: case 10: case 12: return 31;
	case 4: case 6: case 9: case 11: return 30;
	case 2: return ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28;
	default: return 0;
	}
}
static int valid_date(int32_t y, uint32_t m, uint32_t d) {
	return m >= 1 && m <= 12 && d >= 1 && d <= days_in_month(y, m);
}
static int parse_num2(ShclStr s, uint32_t *out) {
	if (!(s.n == 1 || s.n == 2) || !all_adigit0(s)) return 0;
	uint32_t v = 0; for (size_t i = 0; i < s.n; i++) v = v * 10 + (uint32_t)(s.p[i] - '0');
	*out = v; return 1;
}
static int parse_year4(ShclStr s, int32_t *out) {
	if (s.n != 4 || !all_adigit0(s)) return 0;
	int32_t v = 0; for (size_t i = 0; i < s.n; i++) v = v * 10 + (s.p[i] - '0');
	*out = v; return 1;
}
static void split_ws(ShclArena *a, ShclStr s, ShclVecS *out) {
	size_t i = 0;
	while (i < s.n) {
		uint32_t c; size_t l = utf8_decode(s.p, s.n, i, &c);
		if (is_ws(c)) { i += l; continue; }
		size_t start = i;
		while (i < s.n) { uint32_t d; size_t l2 = utf8_decode(s.p, s.n, i, &d); if (is_ws(d)) break; i += l2; }
		ShclVecS_push(a, out, s_slice(s, start, i));
	}
}
typedef struct { int ok; int32_t y; uint32_t m, d; } ShclDatePart;
static ShclDatePart parse_date_part(ShclArena *a, ShclStr s) {
	ShclDatePart r; r.ok = 0; r.y = 0; r.m = 0; r.d = 0;
	s = s_trim(s);
	if (s.n == 8 && all_adigit0(s)) {
		int32_t y; uint32_t m, d;
		if (parse_year4(s_slice(s, 0, 4), &y) && parse_num2(s_slice(s, 4, 6), &m) && parse_num2(s_slice(s, 6, 8), &d) && valid_date(y, m, d)) { r.ok = 1; r.y = y; r.m = m; r.d = d; }
		return r;
	}
	ShclVecS toks = {0}; split_ws(a, s, &toks);
	if (toks.len == 3) {
		uint32_t mm;
		if ((mm = month_from_name(a, toks.data[0]))) {
			ShclStr day_tok = toks.data[1];
			if (day_tok.n > 0 && day_tok.p[day_tok.n - 1] == ',') day_tok = s_slice(day_tok, 0, day_tok.n - 1);
			uint32_t d; int32_t y;
			/* The day is DD, like every other form's: a plain integer parse
			   takes a leading '+' and any number of leading zeros, which the
			   whitelist does not list and the delimited spellings refuse. */
			if (parse_num2(day_tok, &d) && parse_year4(toks.data[2], &y) && valid_date(y, mm, d)) { r.ok = 1; r.y = y; r.m = mm; r.d = d; }
			return r;
		}
		if ((mm = month_from_name(a, toks.data[1]))) {
			uint32_t d; int32_t y;
			if (parse_num2(toks.data[0], &d) && parse_year4(toks.data[2], &y) && valid_date(y, mm, d)) { r.ok = 1; r.y = y; r.m = mm; r.d = d; }
			return r;
		}
		return r;
	}
	if (toks.len != 1) return r;
	char delim = 0; int have = 0;
	for (size_t i = 0; i < s.n; i++) if (s.p[i] == '-' || s.p[i] == '/' || s.p[i] == '.') { delim = s.p[i]; have = 1; break; }
	if (!have) return r;
	ShclVecS parts = {0}; split_byte(a, s, delim, &parts);
	if (parts.len != 3) return r;
	for (size_t i = 0; i < parts.len; i++) if (parts.data[i].n == 0) return r;
	size_t dcount = 0; for (size_t i = 0; i < s.n; i++) if (s.p[i] == '-' || s.p[i] == '/' || s.p[i] == '.') dcount++;
	if (dcount != 2) return r;
	if (parts.data[0].n == 4 && all_adigit0(parts.data[0])) {
		int32_t y; uint32_t m, d;
		if (parse_year4(parts.data[0], &y) && parse_num2(parts.data[1], &m) && parse_num2(parts.data[2], &d) && valid_date(y, m, d)) { r.ok = 1; r.y = y; r.m = m; r.d = d; }
		return r;
	}
	uint32_t mm;
	if ((mm = month_from_name(a, parts.data[0]))) {
		uint32_t d; int32_t y;
		if (parse_num2(parts.data[1], &d) && parse_year4(parts.data[2], &y) && valid_date(y, mm, d)) { r.ok = 1; r.y = y; r.m = mm; r.d = d; }
		return r;
	}
	if ((mm = month_from_name(a, parts.data[1]))) {
		uint32_t d; int32_t y;
		if (parse_num2(parts.data[0], &d) && parse_year4(parts.data[2], &y) && valid_date(y, mm, d)) { r.ok = 1; r.y = y; r.m = mm; r.d = d; }
		return r;
	}
	return r;
}
typedef struct {
	int ok; uint32_t h, mi; int has_sec; uint32_t sec;
	int has_frac; ShclStr frac; shcl_zone_kind zone; int32_t off;
} ShclTimePart;
static uint32_t low_a(unsigned char c) { return (c >= 'A' && c <= 'Z') ? (uint32_t)(c + 32) : c; }
static ShclTimePart parse_time_part(ShclArena *a, ShclStr s) {
	ShclTimePart r; memset(&r, 0, sizeof r); r.zone = SHCL_ZONE_NONE;
	ShclStr t = s_trim(s);
	if (t.n > 0 && (t.p[t.n - 1] == 'Z' || t.p[t.n - 1] == 'z')) {
		r.zone = SHCL_ZONE_UTC; t = trim_end(s_slice(t, 0, t.n - 1));
	} else if (t.n >= 6 && ((unsigned char)t.p[t.n - 6] & 0xC0) != 0x80) {
		ShclStr tail = s_slice(t, t.n - 6, t.n);
		unsigned char sign = (unsigned char)tail.p[0];
		if ((sign == '+' || sign == '-') && is_adigit((unsigned char)tail.p[1]) && is_adigit((unsigned char)tail.p[2])
			&& tail.p[3] == ':' && is_adigit((unsigned char)tail.p[4]) && is_adigit((unsigned char)tail.p[5])) {
			int hh = (tail.p[1] - '0') * 10 + (tail.p[2] - '0');
			int mm = (tail.p[4] - '0') * 10 + (tail.p[5] - '0');
			if (hh <= 23 && mm <= 59) {
				int off = hh * 60 + mm; if (sign == '-') off = -off;
				r.zone = SHCL_ZONE_OFFSET; r.off = off;
				t = trim_end(s_slice(t, 0, t.n - 6));
			}
		}
	}
	int meridiem = -1; // 0 = AM, 1 = PM
	if (t.n >= 2 && low_a((unsigned char)t.p[t.n - 1]) == 'm' && low_a((unsigned char)t.p[t.n - 2]) == 'a') { meridiem = 0; t = s_slice(t, 0, t.n - 2); }
	else if (t.n >= 2 && low_a((unsigned char)t.p[t.n - 1]) == 'm' && low_a((unsigned char)t.p[t.n - 2]) == 'p') { meridiem = 1; t = s_slice(t, 0, t.n - 2); }
	t = trim_end(t);
	ShclStr hms = t; ShclStr frac = s_empty(); int has_frac = 0;
	for (size_t i = 0; i < t.n; i++) if (t.p[i] == '.') {
		hms = s_slice(t, 0, i); ShclStr f = s_slice(t, i + 1, t.n);
		if (f.n == 0 || f.n > 9 || !all_adigit0(f)) return r;
		frac = f; has_frac = 1; break;
	}
	ShclVecS parts = {0}; split_byte(a, hms, ':', &parts);
	if (parts.len < 2 || parts.len > 3) return r;
	if (has_frac && parts.len != 3) return r;
	uint32_t h_raw, mi;
	if (!parse_num2(parts.data[0], &h_raw)) return r;
	if (parts.data[1].n != 2 || !parse_num2(parts.data[1], &mi)) return r;
	int has_sec = 0; uint32_t sec = 0;
	if (parts.len == 3) { if (parts.data[2].n != 2 || !parse_num2(parts.data[2], &sec)) return r; has_sec = 1; }
	if (mi > 59 || (has_sec && sec > 59)) return r;
	uint32_t h;
	if (meridiem == -1) { if (h_raw > 23) return r; h = h_raw; }
	else {
		if (h_raw < 1 || h_raw > 12) return r;
		if (meridiem == 0) h = (h_raw == 12) ? 0 : h_raw;
		else h = (h_raw == 12) ? 12 : h_raw + 12;
	}
	r.ok = 1; r.h = h; r.mi = mi; r.has_sec = has_sec; r.sec = sec;
	r.has_frac = has_frac; r.frac = frac;
	return r;
}
static int parse_datetime(ShclArena *a, ShclStr text, shcl_datetime *out) {
	memset(out, 0, sizeof *out); out->zone = SHCL_ZONE_NONE;
	ShclStr t = s_trim(text);
	if (t.n == 0) return 0;
	size_t colon = (size_t)-1;
	for (size_t i = 0; i < t.n; i++) if (t.p[i] == ':') { colon = i; break; }
	if (colon != (size_t)-1) {
		size_t k = colon;
		while (k > 0 && is_adigit((unsigned char)t.p[k - 1]) && colon - k < 2) k--;
		if (k == colon) return 0;
		if (k == 0) {
			ShclTimePart tp = parse_time_part(a, t);
			if (!tp.ok) return 0;
			out->has_time = 1; out->hour = tp.h; out->minute = tp.mi;
			out->has_sec = tp.has_sec; out->sec = tp.sec;
			out->has_frac = tp.has_frac; out->frac = tp.frac; out->zone = tp.zone; out->off_min = tp.off;
			return 1;
		}
		uint32_t sepc; size_t sep_len = utf8_last(s_slice(t, 0, k), &sepc);
		if (!(sepc == 'T' || sepc == 't' || sepc == ' ' || sepc == '_' || sepc == '-' || sepc == '/' || sepc == '.')) return 0;
		ShclDatePart dp = parse_date_part(a, s_slice(t, 0, k - sep_len));
		if (!dp.ok) return 0;
		ShclTimePart tp = parse_time_part(a, s_slice(t, k, t.n));
		if (!tp.ok) return 0;
		out->has_date = 1; out->year = dp.y; out->month = dp.m; out->day = dp.d;
		out->has_time = 1; out->hour = tp.h; out->minute = tp.mi;
		out->has_sec = tp.has_sec; out->sec = tp.sec;
		out->has_frac = tp.has_frac; out->frac = tp.frac; out->zone = tp.zone; out->off_min = tp.off;
		return 1;
	}
	ShclDatePart dp = parse_date_part(a, t);
	if (!dp.ok) return 0;
	out->has_date = 1; out->year = dp.y; out->month = dp.m; out->day = dp.d;
	return 1;
}

// --- parser ------------------------------------------------------------------

/* Per-node hash-of-(name, merge-key) -> matching children. Pure lookup
   accelerator for select_or_create (the linear scan was O(children^2) per
   parent); the children vec keeps the order. Chained buckets, entries
   arena-allocated. An entry has only the hash and a value - no key
   string is built or stored; equality past the hash is the caller's to
   verify against what the value names (merge_eq for the parser maps). Two
   different exact keys can collide in the hash, so same-hash entries keep
   insertion order (append, and the rehash preserves it) and first-inserted
   keeps winning like the scan did. A value that mutates in place (empty
   field filled, star element added) moves its entry via remap_child. */

/* The per-node accelerator slots, the reference's lazy child_map/disp_map
   shape: 8 bytes per node, NULL until the node's first entry, the map struct
   made in the parser arena on demand - an inline struct per node cost three
   times the slot and mostly held empty maps (leaves never fill one). The
   slot vector itself is parser-lifetime malloc storage, like the node vector
   and for the same reason (bump-arena doublings are never given back);
   do_parse frees both at its single exit. */
typedef struct { ShclCMap **data; size_t len, cap; } ShclVecMapPtr;
static void maps_push(jmp_buf *panic, ShclVecMapPtr *v, ShclCMap *x) {
	if (v->len == v->cap) {
		size_t nc = v->cap ? v->cap * 2 : 8;
		ShclCMap **nd = (ShclCMap **)realloc(v->data, nc * sizeof(ShclCMap *));
		if (!nd) arena_panic(panic);
		v->data = nd; v->cap = nc;
	}
	v->data[v->len++] = x;
}
static ShclCMap *map_mut(ShclArena *a, ShclVecMapPtr *v, size_t i) {
	if (!v->data[i]) { v->data[i] = (ShclCMap *)arena_alloc(a, sizeof(ShclCMap)); memset(v->data[i], 0, sizeof(ShclCMap)); }
	return v->data[i];
}

/* First entry with this hash, in insertion order; cmap_next walks the rest.
   m may be NULL: a node whose map was never created has no entries. */
static ShclCMapEnt *cmap_first(const ShclCMap *m, uint64_t h) {
	if (!m || !m->cap) return NULL;
	for (ShclCMapEnt *e = m->buckets[h & (m->cap - 1)]; e; e = e->next)
		if (e->hash == h) return e;
	return NULL;
}
static ShclCMapEnt *cmap_next(ShclCMapEnt *e, uint64_t h) {
	for (e = e->next; e; e = e->next)
		if (e->hash == h) return e;
	return NULL;
}
static void cmap_put(ShclArena *a, ShclCMap *m, uint64_t h, size_t val) {
	if (m->len + 1 > m->cap - m->cap / 4) { /* grow at 75%; also covers cap 0 */
		size_t nc = m->cap ? m->cap * 2 : 8;
		ShclCMapEnt **nb = (ShclCMapEnt **)arena_alloc(a, nc * sizeof(ShclCMapEnt *));
		memset(nb, 0, nc * sizeof(ShclCMapEnt *));
		for (size_t b = 0; b < m->cap; b++)
			for (ShclCMapEnt *e = m->buckets[b], *nx; e; e = nx) {
				nx = e->next;
				/* append, so same-hash entries keep their insertion order */
				size_t db = e->hash & (nc - 1);
				ShclCMapEnt **tail = &nb[db];
				while (*tail) tail = &(*tail)->next;
				e->next = NULL; *tail = e;
			}
		m->buckets = nb; m->cap = nc;
	}
	ShclCMapEnt *e = (ShclCMapEnt *)arena_alloc(a, sizeof *e);
	e->hash = h; e->val = val; e->next = NULL;
	ShclCMapEnt **tail = &m->buckets[h & (m->cap - 1)];
	while (*tail) tail = &(*tail)->next;
	*tail = e;
	m->len++;
}
/* Size an empty map for n entries, when the count is known, so it never grows.
   Each growth leaves the old table behind in the arena. */
static void cmap_reserve(ShclArena *a, ShclCMap *m, size_t n) {
	size_t nc = 8;
	while (nc - nc / 4 < n) nc *= 2;
	m->buckets = (ShclCMapEnt **)arena_alloc(a, nc * sizeof(ShclCMapEnt *));
	memset(m->buckets, 0, nc * sizeof(ShclCMapEnt *));
	m->cap = nc;
}
/* Unlink the (hash, val) entry - a node holds at most one entry per map, so
   nothing else can match the pair. */
static void cmap_del(ShclCMap *m, uint64_t h, size_t val) {
	if (!m || !m->cap) return;
	for (ShclCMapEnt **pp = &m->buckets[h & (m->cap - 1)]; *pp; pp = &(*pp)->next) {
		ShclCMapEnt *e = *pp;
		if (e->hash == h && e->val == val) { *pp = e->next; m->len--; return; }
	}
}

/* A pending whole-line comment during parse: text, source indent (used only
   to decide whether it hangs on a deeper block), and the blank it consumed.
   Both strings slice the retained input copy, except the text of a kept line
   with the raw body it took, built in the document's arena. ceiling is the
   shortest incoming indent already checked against it: a later check can only
   hang it from a shorter one, so a longer one skips it. */
typedef struct { ShclStr text; ShclStr indent; int blank_before; size_t ceiling; size_t line; } ShclPend;
/* One comment on a comment_depth chain: its indent and depth. */
typedef struct { ShclStr indent; size_t depth; } ShclDepthEnt;
DEFINE_VEC(ShclVecDepth, ShclDepthEnt)
DEFINE_VEC(ShclVecPend, ShclPend)
/* Every pending entry before end has a ceiling at or under indent_len. */
typedef struct { size_t end; size_t indent_len; } ShclPendMark;
DEFINE_VEC(ShclVecPendMark, ShclPendMark)
/* A LAZY level's line, for opening it: the stack entry it sits at, its path
   (copied out of the line's arena), and how many pending lines go with it,
   its own included. */
typedef struct { size_t at; ShclSegment *segs; size_t nsegs; size_t line; ShclStr indent; size_t pend; size_t depth; } ShclLazy;
DEFINE_VEC(ShclVecLazy, ShclLazy)

/* What a parse owns outright and has to give back, on the heap rather than in
   do_parse's frame: the recovery path is reached by longjmp, which leaves a
   local the parse has written to indeterminate. */
typedef struct { ShclArena line, hints; ShclVecMapPtr cmaps, dmaps; } ShclParseOwn;

/* pending: whole-line comments waiting for the next line that binds a node.
   The source indent is kept only to decide after-attachment (a comment deeper
   than the next binding hangs on the block it sits in).
   pend_marks: lengths rise along the stack, so a hang check pops the marks
   above its own indent and walks only what they covered. Without it a run of
   retained bad lines is rewalked per line and a plain text file parses in
   quadratic time.
   star_*: a stacked list defers its merge-key remap while it is the open field
   (rebuilding the key per element is O(list^2) time); (key hash, display
   hash) at deferral start, and the deferred remap flushes before any other
   map lookup. */
/* dmaps: per-node hash-of-(name, display) -> first matching child - the
   `[value]` selector accelerator (display is a different, non-injective
   predicate from cmaps' merge key). Ownership is by hash alone and a query
   verifies its hit against the arena; same first-wins discipline, same
   mutation sites. */
// reent_node/reent_line pair up node -> line of the re-open that H002-hinted
// it (linear scan; re-opens are rare). A merge under a hinted container
// combines the same two textual regions, so it hints too even when it ends up on
// the newest child at its own scope - that is how every merged level reports,
// not just the outermost. The stored line splits old children (hint) from ones
// the re-opened region itself created (silent).
/* tmp: the parser's own bookkeeping - the child accelerator, the indent stack,
   the pending-comment list, the line index - is dead the moment parsing ends,
   so it goes in the scratch arena rather than the document's. In a bump arena
   the document's is never reclaimed, and the accelerator alone is one hash map
   per node. Everything a node keeps (name, value, trivia text) is still dup'd
   into the document arena. Nothing resets scratch during a parse; the first
   read after it does. */
typedef struct { shcl_doc *d; ShclArena *tmp; ShclArena *line; ShclArena *hints; ShclStr src; ShclVecStack stack; ShclVecMapPtr *cmaps; ShclVecMapPtr *dmaps; ShclVecPend pending; ShclVecPendMark pend_marks; ShclVecDepth depth_chain; ShclVecDepth held_chain; int star_open; size_t star_node; uint64_t star_key; uint64_t star_disp; int saw_blank; ShclVecSize reent_node; ShclVecSize reent_line;
	/* Parents where a remap ended up on a key a sibling already held: the only
	   places a duplicate can survive the keyed lookup, so the fold starts here. */
	ShclVecSize late_dups;
	/* shcl_parse_limited's caps, 0 = uncapped: nodes counted against the
	   arena (root excluded), elements against a single value's cell. */
	size_t max_nodes, max_elements;
	/* Diagnostic cap: past it nothing is listed, only counted (errors, hints),
	   for the one tail entry the parse ends with. */
	size_t max_diags, unlisted_errors, unlisted_hints;
	/* Indent of the last E012 line kept as written, while the lines after it
	   sit under it; those are E018 and are kept as written too. */
	int has_kept_hold; ShclStr kept_hold;
	int kept_any;
	ShclVecLazy lazies; } ShclParser;

static void push_diag(shcl_doc *d, size_t line, shcl_severity sev, const char *code, ShclStr msg) {
	ShclDiag dg; dg.line = line; dg.sev = sev; dg.message = msg; dg.code = code; dg.generated = 0;
	ShclVecDiag_push(&d->arena, &d->diags, dg);
}
/* A generation fault on the schema document. The text outlives the call, so it
   is copied into the schema's arena here. */
static void push_gen_diag(shcl_doc *schema, size_t line, shcl_severity sev, const char *code, ShclStr msg) {
	ShclDiag dg; dg.line = line; dg.sev = sev; dg.message = s_dup(&schema->arena, msg); dg.code = code; dg.generated = 1;
	ShclVecDiag_push(&schema->arena, &schema->diags, dg);
}
/* Every parse diagnostic goes through here, so the cap sees them all. A
   message is built in the per-line arena and copied into the document only
   when listed, so an unlisted one costs nothing past its own line. */
static void p_diag(ShclParser *P, size_t line, shcl_severity sev, const char *code, ShclStr msg) {
	if (P->max_diags && P->d->diags.len >= P->max_diags) {
		if (sev == SHCL_SEV_ERROR) P->unlisted_errors++; else P->unlisted_hints++;
		return;
	}
	push_diag(P->d, line, sev, code, s_dup(&P->d->arena, msg));
}
static void p_err(ShclParser *P, size_t line, const char *code, ShclStr msg) { p_diag(P, line, SHCL_SEV_ERROR, code, msg); }

static void remap_child(ShclParser *P, size_t node, uint64_t old_key, uint64_t old_disp);
static size_t find_by_value(ShclParser *P, size_t cur, ShclStr name, ShclStr text, int quoted);

/* Apply a stacked list's deferred merge-key remap. Runs before any map lookup
   (and at end of parse), so the map is always fresh when queried. */
static void star_flush(ShclParser *P) {
	if (!P->star_open) return;
	P->star_open = 0;
	remap_child(P, P->star_node, P->star_key, P->star_disp);
}

static size_t select_or_create(ShclParser *P, size_t parent, ShclStr name, ShclStr name_src, ShclValue value, size_t line) {
	ShclArena *a = &P->d->arena;
	star_flush(P);
	uint64_t h = merge_hash(name, &value);
	for (ShclCMapEnt *e = cmap_first(P->cmaps->data[parent], h); e; e = cmap_next(e, h))
		if (merge_eq(NODE(P->d, e->val).name, &NODE(P->d, e->val).value, name, &value)) return e->val;
	size_t idx = P->d->nodes.len;
	ShclNode n; memset(&n, 0, sizeof n);
	n.name = s_keep(a, P->src, name);
	n.name_src = s_eq(name_src, name) ? s_empty() : s_keep(a, P->src, name_src);
	n.value = value; n.parent = parent; n.line = line; n.star_list = 0; n.star_mixed = 0;
	nodes_push(P->d, n);
	ShclVecSize_push(a, &NODE(P->d, parent).children, idx);
	maps_push(P->d->panic, P->cmaps, NULL);
	maps_push(P->d->panic, P->dmaps, NULL);
	cmap_put(P->tmp, map_mut(P->tmp, P->cmaps, parent), h, idx);
	uint64_t hd = disp_hash(name, &value);
	if (!cmap_first(P->dmaps->data[parent], hd))
		cmap_put(P->tmp, map_mut(P->tmp, P->dmaps, parent), hd, idx);
	return idx;
}

/* A node's value mutated in place: move its map entry from the old key to the
   new one. First-wins on both sides so lookups keep matching the earliest
   sibling, like the scan did. */
static void remap_child(ShclParser *P, size_t node, uint64_t old_key, uint64_t old_disp) {
	size_t parent = NODE(P->d, node).parent;
	ShclStr name = NODE(P->d, node).name;
	cmap_del(P->cmaps->data[parent], old_key, node);
	uint64_t h = merge_hash(name, &NODE(P->d, node).value);
	int already = 0;
	for (ShclCMapEnt *e = cmap_first(P->cmaps->data[parent], h); e; e = cmap_next(e, h))
		if (merge_eq(NODE(P->d, e->val).name, &NODE(P->d, e->val).value, name, &NODE(P->d, node).value)) { already = 1; break; }
	if (!already) cmap_put(P->tmp, map_mut(P->tmp, P->cmaps, parent), h, node);
	else ShclVecSize_push(P->tmp, &P->late_dups, parent);
	cmap_del(P->dmaps->data[parent], old_disp, node);
	uint64_t hd = disp_hash(name, &NODE(P->d, node).value);
	if (!cmap_first(P->dmaps->data[parent], hd)) cmap_put(P->tmp, map_mut(P->tmp, P->dmaps, parent), hd, node);
}

/* The trailing comment becomes the last leading line, taking the node's blank
   with it, which is the order the emitter writes them in. */
static void trailing_to_leading(shcl_doc *d, ShclNode *nd) {
	ShclVecLead_push(&d->arena, &nd->trivia->leading, lead_make(nd->trivia->trailing, nd->blank_before, 0));
	nd->trivia->trailing = s_empty();
	nd->blank_before = 0;
}

/* Written stacked: a list holding a kept line among its elements or after
   its last one. */
static int stacks(const ShclNode *nd) {
	if (nd->value.kind != V_CELL || !nd->trivia) return 0;
	if (nd->trivia->among.len) return 1;
	if (!nd->star_list) return 0;
	for (size_t k = 0; k < nd->trivia->inside.len; k++)
		if (!(nd->trivia->inside.data[k].text.n && nd->trivia->inside.data[k].text.p[0] == '#')) return 1;
	return 0;
}

/* A list after an empty binding of its name cannot be written stacked: its
   bare header would merge into that binding on a reload. It goes inline, and
   the lines among its elements go above it, where a reload files what sits
   there. */
static void unstack(shcl_doc *d, ShclNode *nd) {
	nd->star_list = 0;
	if (!nd->trivia) return;
	for (size_t k = 0; k < nd->trivia->among.len; k++)
		ShclVecLead_push(&d->arena, &nd->trivia->leading, nd->trivia->among.data[k].lead);
	nd->trivia->among.len = 0;
}

/* A raw block after an empty binding of its name is written with the fence on
   the binding's line, where no comment can follow it, so the emitter writes its
   trailing comment on a line of its own above, after the node's blank. A
   reload files that line as a leading comment, so file it there now. The
   empties map lives in scratch, like the emitter's. */
static void settle_fence_trailing(shcl_doc *d, size_t n) {
	ShclVecSize kids = NODE(d, n).children;
	size_t k = 0;
	while (k < kids.len && !(NODE(d, kids.data[k]).value.kind == V_RAW && triv_trailing(&NODE(d, kids.data[k])).n) && !stacks(&NODE(d, kids.data[k]))) k++;
	if (k == kids.len) return;
	ShclCMap empties; memset(&empties, 0, sizeof empties);
	for (size_t i = 0; i < kids.len; i++) {
		size_t c = kids.data[i];
		ShclNode *nd = &NODE(d, c);
		uint64_t h = cmap_hash(nd->name, s_empty());
		int seen = 0; /* entries name the empty sibling, so a hit verifies */
		for (ShclCMapEnt *e = cmap_first(&empties, h); e; e = cmap_next(e, h))
			if (s_eq(NODE(d, e->val).name, nd->name)) { seen = 1; break; }
		if (nd->value.kind == V_RAW && seen && nd->trivia && nd->trivia->trailing.n) {
			trailing_to_leading(d, nd);
		} else if (seen && stacks(nd)) {
			unstack(d, nd);
		} else if (v_is_empty(&nd->value) && !seen) {
			cmap_put(&d->scratch, &empties, h, c);
		}
	}
}

/* File a block's comments where a reload does, in place. A block's inside
   comments are written after its last child's block, at that child's level,
   so a reload files them as the last child's own. A child's comments at its
   own level sit right above the next sibling, so a reload files them as that
   sibling's leading ones, from the first one at that level on. The load runs
   this once the tree is final; a merge, a new child and the writer's fold run
   it where they change a child list, or the next step comes out differently
   depending on whether the file was saved in between. The text does not move.
   `from` is the first child whose leading list may gain, so a new last child
   costs one pair; it cannot put a fence after an empty binding either, so
   only a full pass looks for one. */
static void settle_block(shcl_doc *d, size_t n, size_t from) {
	ShclArena *a = &d->arena;
	if (!NODE(d, n).children.len) return;
	if (from <= 1) settle_fence_trailing(d, n);
	ShclNode *nd = &NODE(d, n);
	if (nd->trivia && nd->trivia->inside.len) {
		ShclTrivia *kt = triv_mut(a, &NODE(d, nd->children.data[nd->children.len - 1]));
		for (size_t k = 0; k < nd->trivia->inside.len; k++) ShclVecLead_push(a, &kt->after, nd->trivia->inside.data[k]);
		nd->trivia->inside.len = 0;
	}
	ShclVecSize *kids = &NODE(d, n).children;
	for (size_t i = from ? from : 1; i < kids->len; i++) {
		ShclTrivia *t = NODE(d, kids->data[i - 1]).trivia;
		if (!t) continue;
		size_t at = 0;
		while (at < t->after.len && t->after.data[at].depth != 0) at++;
		if (at == t->after.len) continue;
		ShclTrivia *nt = triv_mut(a, &NODE(d, kids->data[i]));
		ShclVecLead lead = {0};
		for (size_t k = at; k < t->after.len; k++) ShclVecLead_push(a, &lead, t->after.data[k]);
		for (size_t k = 0; k < nt->leading.len; k++) ShclVecLead_push(a, &lead, nt->leading.data[k]);
		nt->leading = lead;
		t->after.len = at;
	}
}

/* The emitter drops a blank before the first thing it prints, so a document
   that kept one there would not survive its own canonical form, and a merge or
   a new first line - where it is no longer first - would place a blank nobody
   wrote. Clear it wherever output starts. */
static void settle_kept(shcl_doc *d); /* with the emitter, which it runs */
static void resettle_kept(shcl_doc *d);
static void settle_first_blank(shcl_doc *d) {
	ShclVecSize kids = NODE(d, ROOT).children;
	if (kids.len) {
		ShclNode *n = &NODE(d, kids.data[0]);
		if (n->trivia && n->trivia->leading.len) n->trivia->leading.data[0].blank_before = 0;
		else n->blank_before = 0;
	} else if (d->orphans.len) {
		d->orphans.data[0].blank_before = 0;
	}
}

/* A value that mutates after its sibling group was keyed - an empty field
   filled by a fence, a stacked list closed - can end up on a key an earlier
   sibling already holds, which the keyed lookup can no longer catch. Fold
   those pairs so the tree matches a reparse of its own canonical text.
   Only the parents remap_child flagged can hold one. Shallowest first, since
   a fold hands the survivor more children and the order they arrive in
   decides whose trailing comment wins; folding keeps depths. Grouping
   temporaries live in scratch (dead before the first resolve resets it). */
typedef struct { size_t depth, node; } ShclLateDup;
static int late_dup_cmp(const void *pa, const void *pb) {
	const ShclLateDup *a = (const ShclLateDup *)pa, *b = (const ShclLateDup *)pb;
	if (a->depth != b->depth) return a->depth < b->depth ? -1 : 1;
	return a->node < b->node ? -1 : a->node > b->node;
}
static void fold_dups_from(ShclParser *P, size_t start);
static void fold_late_dups(ShclParser *P) {
	size_t n = P->late_dups.len;
	if (!n) return;
	ShclLateDup *parents = (ShclLateDup *)arena_alloc(P->tmp, n * sizeof *parents);
	for (size_t i = 0; i < n; i++) {
		size_t depth = 0;
		for (size_t up = P->late_dups.data[i]; up != ROOT; up = NODE(P->d, up).parent) depth++;
		parents[i].depth = depth; parents[i].node = P->late_dups.data[i];
	}
	qsort(parents, n, sizeof *parents, late_dup_cmp);
	for (size_t i = 0; i < n; i++)
		if (i == 0 || parents[i - 1].node != parents[i].node) fold_dups_from(P, parents[i].node);
}

static void hint_fold(ShclParser *P, size_t parent, size_t kept, size_t gone, int apart);
/* Depth-first below start, and only into survivors: a fold moves the loser's
   children up to join the survivor's, where they can pair. A fold hints the
   way a merge at parse time does (select_or_create): when the two were not
   next to each other, or sit under a hinted re-open (20260923 item 11). */
static void fold_dups_from(ShclParser *P, size_t start) {
	shcl_doc *d = P->d;
	ShclArena *t = &d->scratch;
	ShclVecSize stack = {0};
	ShclVecSize_push(t, &stack, start);
	while (stack.len) {
		size_t parent = stack.data[--stack.len];
		/* Keyed to positions in the kept prefix, so a survivor's grew flag sits
		   beside it. */
		ShclCMap first; memset(&first, 0, sizeof first);
		ShclVecSize *ch = &NODE(d, parent).children;
		if (!ch->len) continue;
		cmap_reserve(t, &first, ch->len);
		unsigned char *grew = (unsigned char *)arena_alloc(t, ch->len);
		size_t w = 0;
		for (size_t k = 0; k < ch->len; k++) {
			size_t c = ch->data[k];
			uint64_t h = merge_hash(NODE(d, c).name, &NODE(d, c).value);
			size_t hit = (size_t)-1;
			for (ShclCMapEnt *e = cmap_first(&first, h); e; e = cmap_next(e, h))
				if (merge_eq(NODE(d, ch->data[e->val]).name, &NODE(d, ch->data[e->val]).value, NODE(d, c).name, &NODE(d, c).value)) { hit = e->val; break; }
			if (hit != (size_t)-1) {
				/* Apart when a sibling kept since stands between them, as a
				   merge at parse time asks of the newest child. */
				hint_fold(P, parent, ch->data[hit], c, hit + 1 != w);
				fold_node_into(d, ch->data[hit], c);
				grew[hit] = 1;
			} else {
				cmap_put(t, &first, h, w);
				grew[w] = 0;
				ch->data[w++] = c;
			}
		}
		ch->len = w;
		for (size_t k = 0; k < w; k++)
			if (grew[k]) ShclVecSize_push(t, &stack, ch->data[k]);
	}
}

/* How many levels past its place a pending line is written: the place's own
   level for a comment no deeper than base, the place's own indent, which also
   starts a new chain; for a deeper one, one level under the nearest comment
   before it whose indent its own extends, level with one it equals, or at the
   place's level when there is none. depth_chain holds those comments' indents
   with their depths, innermost last. A field line kept for its value or name
   goes by the same rule over held_chain, the kept lines before it: it holds
   its level on a reload, so it goes deeper only under one of those, which a
   reload holds open for it. A misplaced line, which has its own indent,
   sits at the place's level and leaves both alone. */
static size_t comment_depth(ShclParser *P, ShclStr base, ShclStr text, ShclStr indent) {
	ShclVecDepth *chain = text.n && text.p[0] == '#' ? &P->depth_chain : &P->held_chain;
	ShclDepthEnt e; e.indent = indent; e.depth = 0;
	if (text.n && (text.p[0] == ' ' || text.p[0] == '\t')) return 0;
	if (!(indent.n > base.n && (base.n == 0 || memcmp(indent.p, base.p, base.n) == 0))) {
		chain->len = 0;
		ShclVecDepth_push(P->tmp, chain, e);
		return 0;
	}
	while (chain->len) {
		const ShclDepthEnt *top = &chain->data[chain->len - 1];
		if (s_eq(top->indent, indent)) return top->depth;
		if (indent.n > top->indent.n && (top->indent.n == 0 || memcmp(indent.p, top->indent.p, top->indent.n) == 0)) break;
		chain->len--;
	}
	e.depth = chain->len ? chain->data[chain->len - 1].depth + 1 : 0;
	ShclVecDepth_push(P->tmp, chain, e);
	return e.depth;
}

/* A pending line kept for what it says, not for where it sits: neither a
   comment nor a misplaced line, which has its own indent. */
static int is_field(ShclStr text) {
	return !(text.n && (text.p[0] == '#' || text.p[0] == ' ' || text.p[0] == '\t'));
}

/* Hand pending leading comments (and this line's trailing one) to a node.
   First trailing wins; a later one demotes to leading so nothing is lost.
   Comment text is stored verbatim, so pending and trailing alike are slices
   of the retained input copy - nothing to duplicate. */
static void attach_trivia(ShclParser *P, size_t node, ShclStr indent, ShclStr trailing) {
	ShclArena *a = &P->d->arena;
	if (P->pending.len) {
		ShclTrivia *t = triv_mut(a, &NODE(P->d, node));
		P->depth_chain.len = 0;
		P->held_chain.len = 0;
		for (size_t k = 0; k < P->pending.len; k++) {
			const ShclPend *p = &P->pending.data[k];
			ShclVecLead_push(a, &t->leading, lead_at(p->text, p->blank_before, comment_depth(P, indent, p->text, p->indent), p->line));
		}
		P->pending.len = 0;
		P->pend_marks.len = 0;
	}
	if (trailing.n) {
		ShclTrivia *t = triv_mut(a, &NODE(P->d, node));
		if (t->trailing.n == 0) t->trailing = trailing;
		else ShclVecLead_push(a, &t->leading, lead_plain(trailing));
	}
}

/* Comments written deeper than the incoming line belong to the block they sit
   in, not to the next binding: hang each on the deepest node whose bound
   indent prefixes the comment's, among the levels the incoming line is
   closing. Written at that node's own level the comment trails it (`after`);
   written deeper it sits inside the node's block (`inside`) - so a header
   whose children are all commented still owns them at their depth. Runs
   before the incoming line resolves (and at end of parse with the empty
   indent, so tail comments keep their block). */
static void hang_deeper_pending(ShclParser *P, ShclStr new_indent) {
	if (P->pending.len == 0) return;
	ShclArena *a = &P->d->arena;
	/* Only entries above the last mark at or under this indent can hang. */
	while (P->pend_marks.len && P->pend_marks.data[P->pend_marks.len - 1].indent_len > new_indent.n) P->pend_marks.len--;
	size_t w = P->pend_marks.len ? P->pend_marks.data[P->pend_marks.len - 1].end : 0;
	const size_t start = w;
	/* A comment never goes ahead of the one written before it. Once one stays
	   for the incoming line every later one stays too, and one whose block
	   would be written out before the last one's goes there with it instead.
	   What sits before w stays, so no comment after it can hang. A kept field
	   line is the exception below. */
	int kept = w > 0;
	/* Where the last comment went: stack index, node, at its own level. */
	size_t last_si = (size_t)-1, last_node = 0; int last_own = 0;
	size_t last_field_si = (size_t)-1; int last_field_own = 0;
	P->depth_chain.len = 0;
	P->held_chain.len = 0;
	for (size_t k = w; k < P->pending.len; k++) {
		ShclPend p = P->pending.data[k];
		/* A kept field line goes to the block it sits in whatever stays
		   before it, since that block is its parent on a reload. Comments
		   give way to it. */
		int field = is_field(p.text);
		if ((!kept || field) && p.ceiling > new_indent.n) {
			/* A level shallower than the incoming line stays open and may
			   still gain children, so a comment must not hang there - it
			   would emit below the child; keep it pending instead. */
			size_t si = (size_t)-1, target = (size_t)-1; int at_own_level = 0;
			for (size_t ii = P->stack.len; ii-- > 0;) {
				ShclStr ind = P->stack.data[ii].indent; size_t n = P->stack.data[ii].node;
				if (n != ROOT && n != DEAD && n != UNOPENED && n != LAZY && ind.n >= new_indent.n && p.indent.n >= ind.n && memcmp(p.indent.p, ind.p, ind.n) == 0) {
					/* A list element's column is an entry with the list's node on
					   the list's own entry. It is inside the list, not its level. */
					int column = ii > 0 && P->stack.data[ii - 1].node == n;
					si = ii; target = n; at_own_level = ind.n == p.indent.n && !column; break;
				}
			}
			/* A root node's trailing comment emits at column zero, which is
			   exactly how the document's own trailing comment is written, so
			   keeping the two apart here made a merge depend on whether the
			   layer had been formatted first. Let it orphan, the way a reload
			   of this document's own output reads it. A comment deeper than the
			   node keeps an indent of its own and comes back where it was, so
			   it still hangs. */
			if (target != (size_t)-1 && (!at_own_level || NODE(P->d, target).parent != ROOT)) {
				/* A deeper block is written out first, and a block's inside
				   comments before its after ones. */
				if (last_si != (size_t)-1 && !field && (si > last_si || (si == last_si && !at_own_level && last_own))) { si = last_si; target = last_node; at_own_level = last_own; }
				if (si != last_si || at_own_level != last_own) P->depth_chain.len = 0;
				last_si = si; last_node = target; last_own = at_own_level;
				/* A kept line's parent goes to the same block it does, whatever
				   block the comments between them went to. */
				if (field && (si != last_field_si || at_own_level != last_field_own)) { P->held_chain.len = 0; last_field_si = si; last_field_own = at_own_level; }
				ShclStr base = P->stack.data[si].indent;
				ShclTrivia *t = triv_mut(a, &NODE(P->d, target));
				ShclVecLead *list = at_own_level ? &t->after : &t->inside;
				/* The comments that stayed right above it go along, so the two
				   keep their order and a save can keep both lines. */
				if (field) {
					size_t from = w;
					while (from > start && P->pending.data[from - 1].text.n && P->pending.data[from - 1].text.p[0] == '#') from--;
					for (size_t q = from; q < w; q++) {
						const ShclPend *c = &P->pending.data[q];
						ShclVecLead_push(a, list, lead_at(c->text, c->blank_before, comment_depth(P, base, c->text, c->indent), c->line));
					}
					w = from;
					kept = w > 0;
				}
				ShclVecLead_push(a, list, lead_at(p.text, p.blank_before, comment_depth(P, base, p.text, p.indent), p.line));
				continue;
			}
		}
		kept = 1;
		if (p.ceiling > new_indent.n) p.ceiling = new_indent.n;
		P->pending.data[w++] = p;
	}
	P->pending.len = w;
	if (P->pend_marks.len && P->pend_marks.data[P->pend_marks.len - 1].indent_len == new_indent.n) P->pend_marks.data[P->pend_marks.len - 1].end = w;
	else { ShclPendMark m; m.end = w; m.indent_len = new_indent.n; ShclVecPendMark_push(P->tmp, &P->pend_marks, m); }
}

/* Where a line at an indent sits, without moving anything: found says a
   parent was found (0 is resolve_parent's refusal), and the stack is cut back
   to `to`, or, with push, past a skipped line's column (to, when held) before
   this one's is pushed. The emitter runs it on its model of the stack a reload
   will have. */
typedef struct { int found; size_t parent; int push; int held; size_t to; } ShclLocated;

/* Which open level this indent belongs to, walking down from the top. Equal
   to a level is its sibling. Deeper than a level is its child, unless a level
   opened under that one is still open, in which case the line falls between
   the two. Anything else is a recoverable error. */
static ShclLocated locate_in(const ShclStackEnt *stack, size_t len, ShclStr indent) {
	ShclLocated r; memset(&r, 0, sizeof r);
	for (size_t ii = len; ii-- > 0;) {
		ShclStr ind = stack[ii].indent; size_t node = stack[ii].node;
		if (s_eq(ind, indent)) {
			/* Back at a skipped line's column: refused the same way. */
			if (node == UNOPENED) { r.to = ii + 1; return r; }
			/* Sibling of stack[ii]: its parent is the entry below it. Keep the
			   sentinel; a top-level line resolves to ROOT. */
			size_t parent = (ii == 0) ? ROOT : stack[ii - 1].node;
			r.found = 1; r.parent = parent == UNOPENED ? DEAD : parent; r.to = ii ? ii : 1;
			return r;
		}
		if (indent.n > ind.n && (ind.n == 0 || memcmp(indent.p, ind.p, ind.n) == 0)) {
			/* A skipped line's unopened level sits on top without opening
			   anything, so it does not count as a level in between. */
			if (ii + 1 < len && stack[ii + 1].node != UNOPENED) break;
			r.found = 1; r.parent = node == UNOPENED ? DEAD : node; r.to = ii + 1;
			return r;
		}
		if (node == UNOPENED) { r.to = ii; r.held = 1; }
	}
	/* Skipped, but it holds its own column: whatever is written deeper is
	   skipped with it, and a line back at it is refused the same way instead
	   of binding one level up. It closes nothing, so a later line that matches
	   a level open before it still binds there, as in 2.0.0. The hold ends at
	   the first line neither under it nor at it, this one included, which
	   keeps one on the stack at most. */
	r.push = 1;
	return r;
}

/* resolve_parent() without moving anything. */
static ShclLocated locate(const ShclParser *P, ShclStr indent) { return locate_in(P->stack.data, P->stack.len, indent); }

/* found is locate() on the same indent, which the line loop has already
   asked. */
static int resolve_parent(ShclParser *P, ShclStr indent, ShclLocated found, size_t *out) {
	if (found.push) {
		if (found.held) P->stack.len = found.to;
		ShclStackEnt se; se.indent = indent; se.node = UNOPENED; ShclVecStack_push(P->tmp, &P->stack, se);
	} else {
		P->stack.len = found.to;
	}
	/* Set either way: an older gcc cannot see that no caller reads it on a miss. */
	*out = found.found ? found.parent : ROOT;
	return found.found;
}

/* What became of a line the parser did not bind whole. Only the funnel
   (p_refuse) reads it; the count and the level follow from it. */
typedef enum {
	OUT_VALUE_DROPPED, /* the line binds; a value on it has nowhere to go and is gone */
	OUT_RETAINED,      /* content-malformed: kept verbatim as trivia and written back in place */
	OUT_DROPPED,       /* read but not applicable here; re-emitted it could bind elsewhere, so it is gone and counts */
	OUT_STOPPED        /* the parse stopped before this line; the rest was never read */
} ShclOutcomeKind;
typedef struct { ShclOutcomeKind kind; ShclStr text; int blank_before; const ShclStr *rest; size_t nrest; } ShclOutcome;
static ShclOutcome out_kind(ShclOutcomeKind kind) { ShclOutcome o; memset(&o, 0, sizeof o); o.kind = kind; return o; }
static ShclOutcome out_retained(ShclStr text, int blank_before) { ShclOutcome o = out_kind(OUT_RETAINED); o.text = text; o.blank_before = blank_before; return o; }
static ShclOutcome out_stopped(const ShclStr *rest, size_t nrest) { ShclOutcome o = out_kind(OUT_STOPPED); o.rest = rest; o.nrest = nrest; return o; }

/* The one exit for a line the parser does not bind whole. An arm says what
   became of the line and nothing else: the lost count and the level the line
   holds follow from the outcome here, so no arm can forget either. design.md's
   outcome table gives each code its row. */
static void p_refuse(ShclParser *P, size_t line, const char *code, ShclStr msg, ShclOutcome out, ShclStr indent) {
	p_err(P, line, code, msg);
	int holds = out.kind == OUT_RETAINED || out.kind == OUT_DROPPED;
	size_t n = 0;
	switch (out.kind) {
	case OUT_VALUE_DROPPED: case OUT_DROPPED:
		n = 1;
		break;
	case OUT_STOPPED:
		for (size_t r = 0; r < out.nrest; r++)
			if (s_trim_wsp(out.rest[r]).n) n++;
		break;
	case OUT_RETAINED: break;
	}
	P->d->lost += n;
	/* Which line that was, for the save that keeps lines. Its parse has no node
	   cap, so it never stops early. */
	if (P->d->track_dropped && (out.kind == OUT_VALUE_DROPPED || out.kind == OUT_DROPPED))
		ShclVecSize_push(&P->d->arena, &P->d->dropped, line);
	if (out.kind == OUT_RETAINED) {
		/* One retained outcome makes one pend, and each pend becomes one lead,
		   so right after a load kept_lines() equals this. An arm that files a
		   retained line nowhere breaks that, and the save gate then refuses
		   even a plain fmt --write, as it should. */
		P->d->kept_owed++;
		/* A line kept as written never hangs on a block: its indent is not one
		   the output's levels are written with, so the block it would match
		   here is not the one it matches on a reload. It waits for the next
		   binding line, as do the pending lines after it. */
		ShclPend pd; pd.text = out.text; pd.indent = indent; pd.blank_before = out.blank_before; pd.line = line;
		pd.ceiling = out.text.n && (out.text.p[0] == ' ' || out.text.p[0] == '\t') ? 0 : indent.n;
		ShclVecPend_push(P->tmp, &P->pending, pd);
	}
	/* A refused line owns its indent, so what is written deeper is skipped
	   with it (E018). An indent that matched no level already holds an
	   unopened one, which refuses a sibling the same way; that one stays. */
	size_t top = P->stack.len - 1;
	if (holds && !(s_eq(P->stack.data[top].indent, indent) && P->stack.data[top].node == UNOPENED)) {
		ShclStackEnt se; se.indent = indent; se.node = DEAD; ShclVecStack_push(P->tmp, &P->stack, se);
	}
}

/* A line refused for where it sits rather than for what it says: E012, or
   E018 under one. Written back exactly as it was, it sits the same way on a
   reload, as long as its indent holds a space, since no level the emitter
   opens is written with one. A tab-only indent would bind there, and a line
   opening a raw block would take its body along, so those are dropped. An
   E018 line is kept only under a kept E012 one. rest is the trimmed line
   after its indent and any blanks. */
static void misplaced(ShclParser *P, size_t line, const char *code, ShclStr indent, ShclStr rest, int had_blank, int raw) {
	int e012 = strcmp(code, "E012") == 0;
	int keep = 0;
	if (!raw) {
		if (e012) keep = indent.n && memchr(indent.p, ' ', indent.n) != NULL;
		else keep = P->has_kept_hold && indent.n > P->kept_hold.n && memcmp(indent.p, P->kept_hold.p, P->kept_hold.n) == 0;
	}
	if (keep) P->kept_any = 1;
	ShclStr msg;
	if (e012) {
		P->has_kept_hold = keep; P->kept_hold = keep ? indent : s_empty();
		msg = s_lit("indentation matches no open level");
	} else {
		msg = s_lit("parent line was skipped; line skipped");
	}
	if (!keep) { p_refuse(P, line, code, msg, out_kind(OUT_DROPPED), indent); return; }
	/* Both slice the retained input copy; they sit side by side unless blanks
	   holding a carriage return came between. */
	ShclStr text;
	if (indent.p + indent.n == rest.p) { text.p = indent.p; text.n = indent.n + rest.n; }
	else { ShclSB b = {0}; sb_putS(&P->d->arena, &b, indent); sb_putS(&P->d->arena, &b, rest); text = sb_S(&b); }
	p_refuse(P, line, code, msg, out_retained(text, had_blank), indent);
}

/* Diagnose a line written under a skipped line, and skip it too. Its own
   level stays dead so deeper lines go the same way. */
static void skip_under_dead(ShclParser *P, size_t line, ShclStr indent) {
	p_refuse(P, line, "E018", s_lit("parent line was skipped; line skipped"), out_kind(OUT_DROPPED), indent);
}

/* The single H002 wording site: the merge hint and the schema suppressor
   both come here, same discipline as h001_head. */
static ShclStr h002_head(ShclArena *a, ShclStr name) {
	ShclSB s = {0};
	sb_puts(a, &s, "merged with '"); sb_putS(a, &s, diag_name(a, name)); sb_puts(a, &s, "' at ");
	return sb_S(&s);
}
static size_t reent_get(const ShclParser *P, size_t node) {
	for (size_t i = 0; i < P->reent_node.len; i++)
		if (P->reent_node.data[i] == node) return P->reent_line.data[i];
	return 0;
}
static void reent_set(ShclParser *P, size_t node, size_t line) {
	for (size_t i = 0; i < P->reent_node.len; i++)
		if (P->reent_node.data[i] == node) { P->reent_line.data[i] = line; return; }
	ShclVecSize_push(P->tmp, &P->reent_node, node); ShclVecSize_push(P->tmp, &P->reent_line, line);
}
static void hint_fold(ShclParser *P, size_t parent, size_t kept, size_t gone, int apart) {
	size_t at = NODE(P->d, kept).line, line = NODE(P->d, gone).line;
	size_t rl = reent_get(P, parent);
	int cross_region = (rl != 0 && at < rl);
	if (at != line && (apart || cross_region)) {
		ShclSB m = {0};
		sb_putS(P->line, &m, h002_head(P->line, NODE(P->d, kept).name));
		sb_puts(P->line, &m, "line "); sb_put_u64(P->line, &m, at);
		sb_puts(P->line, &m, " (same name and value combine)");
		p_diag(P, line, SHCL_SEV_HINT, "H002", sb_S(&m));
		reent_set(P, kept, line);
	}
}
static int attach_path(ShclParser *P, size_t parent, ShclSegment *segs, size_t nsegs, ShclValue value, size_t line, ShclStr indent, size_t *out) {
	ShclArena *a = &P->d->arena;
	/* Field child under a stacked list: diagnose the mix once, keep the field. */
	star_flush(P);
	if (NODE(P->d, parent).star_list && !NODE(P->d, parent).star_mixed) {
		NODE(P->d, parent).star_mixed = 1;
		p_err(P, line, "E001", s_lit("field mixed with list elements"));
	}
	/* Nesting cap: parent depth plus the segments this line adds. Checked
	   before any node is created so a rejected line leaves nothing behind. */
	size_t parent_depth = 0;
	for (size_t up = parent; up != ROOT; up = NODE(P->d, up).parent) parent_depth++;
	if (parent_depth + nsegs > SHCL_MAX_DEPTH) {
		ShclSB m = {0}; sb_puts(P->line, &m, "nesting deeper than "); sb_put_u64(P->line, &m, SHCL_MAX_DEPTH); sb_puts(P->line, &m, " levels; line skipped");
		p_refuse(P, line, "E016", sb_S(&m), out_kind(OUT_DROPPED), indent);
		return 0;
	}
	size_t cur = parent;
	for (size_t i = 0; i < nsegs; i++) {
		const ShclSegment *seg = &segs[i];
		int is_last = (i + 1 == nsegs);
		switch (seg->sel.tag) {
		case SEL_VALUE: {
			/* Same display predicate resolution uses, so a selector also
			   selects an array-valued instance instead of
			   creating a spurious second one - via the dmaps accelerator (the
			   inline spelling was quadratic in siblings without it). Create
			   only when nothing matches. */
			size_t found = find_by_value(P, cur, seg->name, seg->sel.value, seg->sel.quoted);
			if (found != (size_t)-1) {
				cur = found;
			} else {
				ShclValue disc; memset(&disc, 0, sizeof disc); disc.kind = V_CELL;
				ShclElement *e = (ShclElement *)arena_alloc(a, sizeof(ShclElement));
				*e = new_element(s_keep(a, P->src, seg->sel.value));
				disc.els = e; disc.nels = 1;
				cur = select_or_create(P, cur, seg->name, seg->name_src, disc, line);
			}
			if (is_last && !v_is_empty(&value)) {
				ShclSB m = {0}; sb_puts(P->line, &m, "value after selector on '"); sb_putS(P->line, &m, diag_name(P->line, seg->name)); sb_puts(P->line, &m, "' ignored");
				p_refuse(P, line, "E002", sb_S(&m), out_kind(OUT_VALUE_DROPPED), indent);
			}
			break;
		}
		case SEL_INDEX: {
			size_t found = (size_t)-1, nth = 0; ShclVecSize ch = NODE(P->d, cur).children;
			for (size_t k = 0; k < ch.len; k++) {
				size_t c = ch.data[k];
				if (!s_eq(NODE(P->d, c).name, seg->name)) continue;
				if (nth == seg->sel.index) { found = c; break; }
				nth++;
			}
			if (found != (size_t)-1) cur = found;
			else {
				ShclSB m = {0}; sb_puts(P->line, &m, "no instance "); sb_put_u64(P->line, &m, seg->sel.index); sb_puts(P->line, &m, " of '"); sb_putS(P->line, &m, diag_name(P->line, seg->name)); sb_putc(P->line, &m, '\'');
				p_refuse(P, line, "E003", sb_S(&m), out_kind(OUT_DROPPED), indent); return 0;
			}
			/* Same as the value selector: the instance is already chosen, so a
			   trailing value has nowhere to bind. */
			if (is_last && !v_is_empty(&value)) {
				ShclSB m = {0}; sb_puts(P->line, &m, "value after selector on '"); sb_putS(P->line, &m, diag_name(P->line, seg->name)); sb_puts(P->line, &m, "' ignored");
				p_refuse(P, line, "E002", sb_S(&m), out_kind(OUT_VALUE_DROPPED), indent);
			}
			break;
		}
		case SEL_WILDCARD:
			p_refuse(P, line, "E004", s_lit("wildcard selector is query-only"), out_kind(OUT_DROPPED), indent); return 0;
		case SEL_NONE: {
			size_t seg_parent = cur;
			size_t before = P->d->nodes.len;
			cur = select_or_create(P, cur, seg->name, seg->name_src, is_last ? value : v_empty(), line);
			/* Two separately-written bindings just combined: legal (the
			   merge rule), but only the parser can see it happened, so
			   say so. Adjacent re-mentions (still the newest binding at
			   this scope) and selector/path-intermediate merges stay
			   silent - those are the deliberate redundant-path idiom.
			   Under a hinted container the newest-child pass does not
			   apply to children the earlier region wrote: those merges
			   combine the same two regions, so every level reports. */
			if (is_last && cur < before && NODE(P->d, cur).line != line) {
				ShclVecSize sib = NODE(P->d, seg_parent).children;
				int non_last = (sib.len == 0 || sib.data[sib.len - 1] != cur);
				size_t rl = reent_get(P, seg_parent);
				int cross_region = (rl != 0 && NODE(P->d, cur).line < rl);
				if (non_last || cross_region) {
					ShclSB m = {0};
					sb_putS(P->line, &m, h002_head(P->line, seg->name));
					sb_puts(P->line, &m, "line "); sb_put_u64(P->line, &m, NODE(P->d, cur).line);
					sb_puts(P->line, &m, " (same name and value combine)");
					p_diag(P, line, SHCL_SEV_HINT, "H002", sb_S(&m));
					reent_set(P, cur, line);
				}
			}
			break;
		}
		}
	}
	*out = cur; return 1;
}

/* The child of `cur` named `name` whose display form is the selector text,
   or (size_t)-1. Quoted selectors only match a single scalar. */
static size_t find_by_value(ShclParser *P, size_t cur, ShclStr name, ShclStr text, int quoted) {
	ShclStr want = text;
	uint64_t hd = disp_hash_text(name, want);
	size_t found = (size_t)-1;
	/* Ownership in dmaps is by hash alone, so the one candidate is verified
	   exactly against the arena; a failed verify is a miss. */
	{
		ShclCMapEnt *e = cmap_first(P->dmaps->data[cur], hd);
		if (e && s_eq(NODE(P->d, e->val).name, name)
			&& s_eq(disp_key(P->line, &NODE(P->d, e->val).value), want))
			found = e->val;
	}
	/* A quoted selector is scalar-only, so it is the one that needs the
	   fallback scan: the accelerator keeps just the first same-display
	   child, which may be the non-scalar one. An unquoted selector takes
	   whatever the accelerator holds and does not scan, so it can bind a raw
	   block where a quoted selector picks the scalar sibling. */
	if (found != (size_t)-1 && quoted && !single_scalar(&NODE(P->d, found).value)) {
		found = (size_t)-1;
	}
	/* A scalar child with this text is exactly the one-element value the
	   merge map is keyed on, so ask that map: a scan of every sibling was the
	   same answer, quadratic on the create path. Nothing here is kept, so
	   the probe value lives on the stack. */
	if (found == (size_t)-1 && quoted) {
		ShclElement el = new_element(want);
		ShclValue disc; memset(&disc, 0, sizeof disc);
		disc.kind = V_CELL; disc.els = &el; disc.nels = 1;
		uint64_t h = merge_hash(name, &disc);
		for (ShclCMapEnt *e = cmap_first(P->cmaps->data[cur], h); e; e = cmap_next(e, h))
			if (merge_eq(NODE(P->d, e->val).name, &NODE(P->d, e->val).value, name, &disc)) { found = e->val; break; }
	}
	return found;
}

/* Consume raw-block content after an opening fence. Returns the value; *next
   gets the next line index. The closing fence's indent is stripped from each
   content line (the opening line's when the block never closes); the rest is
   content. */
static ShclValue consume_raw(ShclParser *P, const ShclStr *lines, size_t nlines, size_t i, size_t open_line, ShclStr open_indent, ShclFence fence, size_t *next) {
	ShclArena *a = &P->d->arena;
	unsigned char ch = fence.ch; size_t len = fence.len; ShclStr info = fence.info;
	ShclVecS content = {0}; int closed = 0; /* line list: parse-lifetime temporary */
	ShclStr nest = open_indent;
	while (i < nlines) {
		if (is_fence_close(lines[i], ch, len)) {
			/* The closing fence's indent is the nesting; everything a content
			   line has past it is content, so a body whose lines all
			   share an indent keeps it (a writer-built block depends on that). */
			nest = leading_ws(lines[i]);
			closed = 1; i++; break;
		}
		ShclVecS_push(P->tmp, &content, lines[i]); i++;
	}
	if (!closed) p_err(P, open_line, "E005", s_lit("unterminated raw block"));
	ShclSB out = {0};
	for (size_t k = 0; k < content.len; k++) {
		if (k) sb_putc(a, &out, '\n');
		sb_putS(a, &out, strip_common(content.data[k], nest));
	}
	ShclValue v; memset(&v, 0, sizeof v);
	v.kind = V_RAW;
	v.raw = (ShclRawVal *)arena_alloc(a, sizeof(ShclRawVal));
	v.raw->content = sb_S(&out); v.raw->info = info; v.raw->fence_char = ch; v.raw->fence_len = len;
	*next = i;
	return v;
}

/* Why a field line that scanned is refused for its value, before the
   element cap: bracket text, a bad escape, or a value that starts like a
   Windows path and holds a \t or \n escape. The code, or NULL. */
static const char *line_fault(ShclArena *a, const ShclTokens *tok, ShclStr text, ShclStr *msg) {
	if (bracket_text(tok, text)) { *msg = s_lit("bracket array syntax; an array is comma-separated, without brackets"); return "E019"; }
	int values = !line_fence(a, tok, text).ok;
	uint32_t esc;
	if (bad_escape(tok, text, values, &esc)) { *msg = escape_msg(a, esc); return "E023"; }
	if (values && any_path_like(tok, text)) { *msg = s_lit(path_msg); return "E024"; }
	return NULL;
}

/* A path segment a LAZY level can open: no index or wildcard selector, which
   could fail to place it. */
static int opens_as_written(const ShclSegment *seg) { return seg->sel.tag == SEL_NONE || seg->sel.tag == SEL_VALUE; }

/* True when a reload holds this kept line's level open (LAZY): a field line
   refused for its value alone, with a path that opens. */
static int opens_later(ShclArena *a, ShclStr text) {
	if (text.n && (text.p[0] == '#' || text.p[0] == '*')) return 0;
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize(a, text, ':', 0, SHCL_RULES_CURRENT, &tok);
	ShclPathScan scan = path_of(a, &tok, text);
	if (!scan.ok) return 0;
	uint32_t esc;
	if (bad_escape(&tok, text, 0, &esc)) return 0;
	for (size_t k = 0; k < scan.segs.len; k++)
		if (!opens_as_written(&scan.segs.data[k])) return 0;
	ShclStr msg;
	return line_fault(a, &tok, text, &msg) != NULL;
}

/* A field line refused for its value alone holds its level open for what is
   written under it. Called right after the refusal pushed the line's level.
   A path that could not open, or would open past the nesting cap, leaves the
   level dead. */
static void hold_open(ShclParser *P, size_t parent, const ShclSegment *segs, size_t nsegs, size_t line, ShclStr indent) {
	size_t at = P->stack.len - 1;
	if (!(P->stack.data[at].node == DEAD && s_eq(P->stack.data[at].indent, indent))) return;
	for (size_t k = 0; k < nsegs; k++)
		if (!opens_as_written(&segs[k])) return;
	while (P->lazies.len && P->lazies.data[P->lazies.len - 1].at >= at) P->lazies.len--;
	size_t depth = 0;
	if (parent == LAZY) {
		if (P->lazies.len) depth = P->lazies.data[P->lazies.len - 1].depth;
	} else {
		for (size_t up = parent; up != ROOT; up = NODE(P->d, up).parent) depth++;
	}
	if (depth + nsegs > SHCL_MAX_DEPTH) return;
	/* The segments live in the line's arena, which the next line resets. */
	ShclSegment *copy = (ShclSegment *)arena_alloc(P->tmp, (nsegs ? nsegs : 1) * sizeof(ShclSegment));
	for (size_t k = 0; k < nsegs; k++) {
		copy[k] = segs[k];
		copy[k].name = s_dup(P->tmp, segs[k].name);
		copy[k].name_src = s_dup(P->tmp, segs[k].name_src);
		copy[k].sel.value = s_dup(P->tmp, segs[k].sel.value);
	}
	P->stack.data[at].node = LAZY;
	ShclLazy lz; lz.at = at; lz.segs = copy; lz.nsegs = nsegs; lz.line = line; lz.indent = indent; lz.pend = P->pending.len; lz.depth = depth + nsegs;
	ShclVecLazy_push(P->tmp, &P->lazies, lz);
}

/* The node a path's first segment bound, from the one its last did. */
static size_t head_of(ShclParser *P, size_t node, size_t nsegs) {
	for (size_t k = 1; k < nsegs; k++) node = NODE(P->d, node).parent;
	return node;
}

/* The first count pending lines become the node's leading lines, or the lines
   inside its block, after its children. */
static void give_pending(ShclParser *P, size_t node, ShclStr indent, size_t count, int inside) {
	if (!count) return;
	ShclArena *a = &P->d->arena;
	ShclTrivia *t = triv_mut(a, &NODE(P->d, node));
	ShclVecLead *list = inside ? &t->inside : &t->leading;
	P->depth_chain.len = 0;
	P->held_chain.len = 0;
	for (size_t j = 0; j < count; j++) {
		const ShclPend *pn = &P->pending.data[j];
		ShclVecLead_push(a, list, lead_at(pn->text, pn->blank_before, comment_depth(P, indent, pn->text, pn->indent), pn->line));
	}
	memmove(P->pending.data, P->pending.data + count, (P->pending.len - count) * sizeof(ShclPend));
	P->pending.len -= count;
	for (size_t j = 0; j < P->pend_marks.len; j++) P->pend_marks.data[j].end = P->pend_marks.data[j].end > count ? P->pend_marks.data[j].end - count : 0;
	for (size_t j = 0; j < P->lazies.len; j++) P->lazies.data[j].pend = P->lazies.data[j].pend > count ? P->lazies.data[j].pend - count : 0;
}

/* The node a line binds under: a LAZY level, and any LAZY one it sits under,
   opens here as an empty field, the way its line would have bound with
   nothing after the colon. Its own line and the comments before it go with
   it. */
static size_t open_lazy(ShclParser *P, size_t parent) {
	if (parent != LAZY) return parent;
	size_t top = P->stack.len - 1;
	size_t from = top;
	while (from > 1 && P->stack.data[from - 1].node == LAZY) from--;
	size_t node = P->stack.data[from - 1].node;
	for (size_t at = from; at <= top; at++) {
		size_t k = P->lazies.len;
		while (k > 0 && P->lazies.data[k - 1].at != at) k--;
		if (k == 0) break;
		ShclLazy lz = P->lazies.data[k - 1];
		memmove(&P->lazies.data[k - 1], &P->lazies.data[k], (P->lazies.len - k) * sizeof(ShclLazy));
		P->lazies.len--;
		/* hold_open let through only a path that opens. */
		size_t opened = 0;
		if (attach_path(P, node, lz.segs, lz.nsegs, v_empty(), lz.line, lz.indent, &opened)) node = opened;
		P->stack.data[at].node = node;
		size_t count = lz.pend < P->pending.len ? lz.pend : P->pending.len;
		give_pending(P, head_of(P, node, lz.nsegs), lz.indent, count, 0);
	}
	return node;
}

/* Where the parse resumes after a refused field line. Every arm that skips one
   comes through here, so a skipped line whose value opens a raw block takes the
   body with it: read as lines, the body would bind or be refused line by line,
   and its closing fence would open a block that runs to the end of the file. A
   line whose path did not parse takes it too, when a fence follows its colon
   (line_fence). */
static size_t skip_field_line(ShclParser *P, const ShclStr *lines, size_t nlines, size_t i, ShclStr indent, const ShclTokens *tok, ShclStr rest) {
	ShclFence f = line_fence(P->tmp, tok, rest);
	if (!f.ok) return i + 1;
	size_t next;
	(void)consume_raw(P, lines, nlines, i + 1, i + 1, indent, f, &next);
	return next;
}

/* skip_field_line() for a line the refusal just kept: the body is kept too, on
   the end of the line's text, so a save writes it back under its line and the
   load still holds one kept line for it. As in a field's block, the closing
   fence's indent comes off each body line, and the body goes one level under
   the line when it is written. A block that never closed gets its closing
   fence, or whatever a save writes after it would read as its body. */
static size_t keep_body(ShclParser *P, const ShclStr *lines, size_t nlines, size_t i, ShclStr indent, const ShclTokens *tok, ShclStr rest) {
	ShclFence f = line_fence(P->tmp, tok, rest);
	if (!f.ok) return i + 1;
	size_t next;
	(void)consume_raw(P, lines, nlines, i + 1, i + 1, indent, f, &next);
	int closed = next > i + 1 && is_fence_close(lines[next - 1], f.ch, f.len);
	size_t body_end = closed ? next - 1 : next;
	ShclStr nest = closed ? leading_ws(lines[next - 1]) : indent;
	if (!P->pending.len) return next;
	ShclArena *a = &P->d->arena;
	ShclPend *last = &P->pending.data[P->pending.len - 1];
	ShclSB text = {0};
	sb_putS(a, &text, last->text);
	for (size_t k = i + 1; k < body_end; k++) { sb_putc(a, &text, '\n'); sb_putS(a, &text, strip_common(lines[k], nest)); }
	sb_putc(a, &text, '\n');
	if (closed) sb_putS(a, &text, s_trim_sp_tab(lines[next - 1]));
	else for (size_t k = 0; k < f.len; k++) sb_putc(a, &text, (char)f.ch);
	last->text = sb_S(&text);
	if (next > i + 1) { ShclVecSize_push(a, &P->d->ends, i + 1); ShclVecSize_push(a, &P->d->ends, next); }
	return next;
}

/* Returns the node the block ended up on ((size_t)-1 = no parent, diagnosed). */
static size_t bind_block(ShclParser *P, size_t parent, ShclValue value, size_t line, ShclStr indent) {
	if (parent == ROOT) { p_refuse(P, line, "E006", s_lit("raw block with no parent field"), out_kind(OUT_DROPPED), indent); return (size_t)-1; }
	if (v_is_empty(&NODE(P->d, parent).value)) {
		uint64_t old_key = merge_hash(NODE(P->d, parent).name, &NODE(P->d, parent).value);
		uint64_t old_disp = disp_hash(NODE(P->d, parent).name, &NODE(P->d, parent).value);
		NODE(P->d, parent).value = value;
		remap_child(P, parent, old_key, old_disp);
		return parent;
	}
	ShclStr name = NODE(P->d, parent).name; ShclStr name_src = node_authored(&NODE(P->d, parent)); size_t gp = NODE(P->d, parent).parent;
	return select_or_create(P, gp, name, name_src, value, line);
}

/* `* name: value` is the YAML habit for a list of objects. Here it is one
   string element, so the parser says so (H003): the text up to its first colon
   has no blank, and the colon ends the text or a blank follows it. */
static int looks_like_binding(ShclStr s) {
	size_t i = 0;
	while (i < s.n && s.p[i] != ':') {
		if (is_wsp((unsigned char)s.p[i])) return 0;
		i++;
	}
	if (i == 0 || i == s.n) return 0;
	return i + 1 == s.n || is_wsp((unsigned char)s.p[i + 1]);
}

/* One stacked-list element (`* scalar`) appends to the parent's array. */
static int add_star_element(ShclParser *P, size_t parent, const ShclTokens *tok, ShclStr text, size_t line, ShclStr indent) {
	ShclArena *a = &P->d->arena;
	if (parent == ROOT) { p_refuse(P, line, "E007", s_lit("list element with no parent field"), out_kind(OUT_DROPPED), indent); return 0; }
	/* Uniform-or-nothing (spec): a mix with field children is not a block array. */
	if (NODE(P->d, parent).children.len != 0) { p_refuse(P, line, "E008", s_lit("list element mixed with field children; ignored"), out_kind(OUT_DROPPED), indent); return 0; }
	/* One scalar per line; a bare comma is an error, not a second element. */
	if (tok->nelem > 1) { p_refuse(P, line, "E010", s_lit("bare comma in list element (one element per line)"), out_kind(OUT_DROPPED), indent); return 0; }
	ShclPiece piece = tok->elements[0];
	ShclElement el;
	if (!element_of(a, &piece, text, &el)) { p_refuse(P, line, "E009", s_lit("empty list element"), out_kind(OUT_DROPPED), indent); return 0; }
	if (piece.quote == SHCL_QUOTE_OPEN) p_err(P, line, "E017", s_lit("unterminated quote in value"));
	int binding_like = !el.quoted && looks_like_binding(el.text);
	ShclStr clash;
	int clashed = unit_clash(P->tmp, NODE(P->d, parent).name, el.text, &clash);
	/* Element cap: each element line past it is refused on its own, the way
	   any other bad element line is. Only a line that would join the list:
	   under a field that already has a value it is E011, cap or not. */
	if (P->max_elements && NODE(P->d, parent).star_list && NODE(P->d, parent).value.kind == V_CELL && NODE(P->d, parent).value.nels >= P->max_elements) {
		ShclSB m = {0}; sb_puts(P->line, &m, "array longer than "); sb_put_u64(P->line, &m, P->max_elements); sb_puts(P->line, &m, " elements; line skipped");
		p_refuse(P, line, "E021", sb_S(&m), out_kind(OUT_DROPPED), indent);
		return 0;
	}
	ShclNode *node = &NODE(P->d, parent);
	if (node->value.kind == V_EMPTY) {
		uint64_t old_key = merge_hash(node->name, &node->value);
		uint64_t old_disp = disp_hash(node->name, &node->value);
		/* Seed capacity for geometric growth: a fresh full-size copy per `* `
		   line kept every discarded copy in the arena - quadratic memory. */
		ShclElement *arr = (ShclElement *)arena_alloc(a, 4 * sizeof(ShclElement)); arr[0] = el;
		node->value.kind = V_CELL; node->value.els = arr; node->value.nels = 1; node->value.cap_els = 4;
		node->star_list = 1;
		remap_child(P, parent, old_key, old_disp);
		/* Defer further remaps until the list closes; the map entry made above
		   stays valid because nothing can look this node up until a non-star
		   line binds (which flushes first). */
		P->star_open = 1; P->star_node = parent; P->star_key = merge_hash(node->name, &node->value); P->star_disp = disp_hash(node->name, &node->value);
	} else if (node->value.kind == V_CELL && node->star_list) {
		if (!P->star_open || P->star_node != parent) {
			star_flush(P);
			P->star_open = 1; P->star_node = parent; P->star_key = merge_hash(node->name, &node->value); P->star_disp = disp_hash(node->name, &node->value);
		}
		if (node->value.nels == node->value.cap_els) {
			size_t nc = node->value.cap_els ? node->value.cap_els * 2 : 4;
			ShclElement *arr = (ShclElement *)arena_alloc(a, nc * sizeof(ShclElement));
			memcpy(arr, node->value.els, node->value.nels * sizeof(ShclElement));
			node->value.els = arr; node->value.cap_els = nc;
		}
		node->value.els[node->value.nels++] = el;
	} else {
		p_refuse(P, line, "E011", s_lit("field already has a value; list element ignored"), out_kind(OUT_DROPPED), indent);
		return 0;
	}
	if (binding_like) p_diag(P, line, SHCL_SEV_HINT, "H003", s_lit("list element looks like a field binding; it is read as a string (quote it to say so)"));
	if (clashed) p_diag(P, line, SHCL_SEV_HINT, "H005", clash);
	/* A kept element holds its column as a dropped one does, with the field as
	   that level's node: a line written deeper binds where it always did, and a
	   line back at the element's column is its sibling, where no level had been
	   opened there and every later sibling was E012 (20260918b item 28). */
	ShclStackEnt se; se.indent = indent; se.node = parent; ShclVecStack_push(P->tmp, &P->stack, se);
	return 1;
}

/* Kept lines waiting for the list element that just joined sat among the
   list's elements, so they stay there; comments still ride the field. */
static void keep_among(ShclParser *P, size_t parent, ShclStr indent) {
	size_t k = 0;
	while (k < P->pending.len && P->pending.data[k].text.n && P->pending.data[k].text.p[0] == '#') k++;
	if (k == P->pending.len) return;
	if (NODE(P->d, parent).value.kind != V_CELL) return;
	size_t before = NODE(P->d, parent).value.nels - 1;
	ShclArena *a = &P->d->arena;
	size_t w = 0;
	P->depth_chain.len = 0;
	P->held_chain.len = 0;
	for (size_t r = 0; r < P->pending.len; r++) {
		ShclPend pd = P->pending.data[r];
		if (pd.text.n && pd.text.p[0] == '#') { P->pending.data[w++] = pd; continue; }
		ShclAmong am; am.before = before; am.lead = lead_make(pd.text, pd.blank_before, comment_depth(P, indent, pd.text, pd.indent));
		ShclVecAmong_push(a, &triv_mut(a, &NODE(P->d, parent))->among, am);
	}
	P->pending.len = w;
	P->pend_marks.len = 0;
}

/* The single H001 wording site: the hint builder and the schema suppressor
   both come here, so the suppressor matches the exact head the builder
   emitted - never a re-parse of free prose. (The leaf name cannot ride on
   the diagnostic itself: consumers build diagnostics literally, so the field
   set is frozen.) */
static ShclStr h001_head(ShclArena *a, ShclStr name) {
	ShclSB s = {0};
	ShclStr shown = diag_name(a, name);
	sb_putc(a, &s, '\'');
	sb_putS(a, &s, shown);
	sb_puts(a, &s, "' repeats as a bare leaf - did you mean '");
	sb_putS(a, &s, shown);
	sb_puts(a, &s, ": ");
	return sb_S(&s);
}

/* The parse's diagnostics in line order, stable, so a hint found only after
   the pass (a fold, a repeated leaf) sits with its line and two on one line
   keep the order they were found in. qsort is not stable, and a late hint
   can sit far from its line, so a bottom-up merge through a scratch buffer.
   A list already in order, the usual case, costs one pass. */
static void diags_by_line(ShclArena *tmp, ShclVecDiag *v) {
	size_t n = v->len, i = 1;
	while (i < n && v->data[i - 1].line <= v->data[i].line) i++;
	if (i >= n) return;
	ShclDiag *src = v->data, *dst = (ShclDiag *)arena_alloc(tmp, n * sizeof *dst);
	for (size_t width = 1; width < n; width *= 2) {
		for (size_t lo = 0; lo < n; lo += 2 * width) {
			size_t mid = n - lo > width ? lo + width : n;
			size_t hi = n - mid > width ? mid + width : n;
			size_t l = lo, r = mid, k = lo;
			while (l < mid && r < hi) dst[k++] = src[r].line < src[l].line ? src[r++] : src[l++];
			while (l < mid) dst[k++] = src[l++];
			while (r < hi) dst[k++] = src[r++];
		}
		ShclDiag *t = src; src = dst; dst = t;
	}
	if (src != v->data) memcpy(v->data, src, n * sizeof *src);
}

static void emit_repeated_leaf_hints(ShclParser *P) {
	ShclArena *a = &P->d->arena;
	/* Grouping bookkeeping (name buckets, member lists, joined displays) is
	   dead on return, so it lives in its own arena, freed here - built in the
	   document arena it cost several times the hints it found and could never
	   be given back. Only the hint messages go into the document arena. The
	   parse owns it rather than this frame, so an allocation failure - which
	   unwinds straight out of here - still has something to free it with. */
	ShclArena *tmp = P->hints;
	arena_guard(tmp, a->panic);
	/* The member list is made only when a name repeats. Nearly every name is
	   seen once, and a list per child was most of what this pass allocated. */
	typedef struct { size_t first; ShclVecSize nodes; } Group;
	for (size_t parent = 0; parent < P->d->nodes.len; parent++) {
		ShclVecSize ch = NODE(P->d, parent).children;
		if (ch.len < 2) continue;
		/* p_diag copies the message out, so nothing from one parent is needed
		   by the next. */
		arena_reset(tmp);
		ShclVecS names = {0}; Group *groups = NULL; size_t ngroups = 0, cgroups = 0;
		ShclCMap group_of; memset(&group_of, 0, sizeof group_of);
		for (size_t k = 0; k < ch.len; k++) {
			size_t c = ch.data[k]; ShclStr nm = NODE(P->d, c).name;
			uint64_t h = cmap_hash(nm, s_empty());
			size_t g = (size_t)-1;
			for (ShclCMapEnt *e = cmap_first(&group_of, h); e; e = cmap_next(e, h))
				if (s_eq(names.data[e->val], nm)) { g = e->val; break; }
			if (g == (size_t)-1) {
				ShclVecS_push(tmp, &names, nm);
				if (ngroups == cgroups) { size_t nc = cgroups ? cgroups * 2 : 8; groups = (Group *)arena_grow(tmp, groups, cgroups, nc, sizeof(Group)); cgroups = nc; }
				memset(&groups[ngroups], 0, sizeof(Group)); groups[ngroups].first = c;
				cmap_put(tmp, &group_of, h, ngroups++);
			} else {
				Group *grp = &groups[g];
				if (grp->nodes.len == 0) ShclVecSize_push(tmp, &grp->nodes, grp->first);
				ShclVecSize_push(tmp, &grp->nodes, c);
			}
		}
		for (size_t gi = 0; gi < ngroups; gi++) {
			ShclVecSize grp = groups[gi].nodes;
			if (grp.len < 2) continue;
			int all_scalar = 1; size_t maxline = 0;
			for (size_t k = 0; k < grp.len; k++) {
				size_t c = grp.data[k];
				if (!(NODE(P->d, c).children.len == 0 && NODE(P->d, c).value.kind == V_CELL && !NODE(P->d, c).star_list)) { all_scalar = 0; break; }
				if (NODE(P->d, c).line > maxline) maxline = NODE(P->d, c).line;
			}
			if (!all_scalar) continue;
			ShclSB joined = {0};
			for (size_t k = 0; k < grp.len; k++) { if (k) sb_puts(tmp, &joined, ", "); sb_putS(tmp, &joined, diag_value(tmp, &NODE(P->d, grp.data[k]).value)); }
			ShclSB m = {0}; sb_putS(tmp, &m, h001_head(tmp, names.data[gi])); sb_putS(tmp, &m, sb_S(&joined)); sb_puts(tmp, &m, "'?");
			p_diag(P, maxline, SHCL_SEV_HINT, "H001", sb_S(&m));
		}
	}
	arena_free(tmp);
}

/* The parse proper. Split from do_parse so that no local of a function holding
   a setjmp is written after it: which of those a compiler thinks an unwind
   could clobber varies by version and optimization level, and -Wclobbered is
   an error here. */
static void parse_body(shcl_doc *d, ShclParseOwn *own, const char *text, size_t len, size_t max_nodes, size_t max_elements, size_t max_diags) {
	ShclArena *a = &d->arena;
	ShclNode root; memset(&root, 0, sizeof root); root.value = v_empty(); root.parent = 0; root.line = 0;
	nodes_push(d, root);
	/* Per-line temporaries - the path scan above all, which allocates a segment
	   vector for every line parsed - reset at the top of each iteration. They
	   cannot share the scratch arena: that one keeps the parser's bookkeeping
	   for the whole parse. Everything a node keeps is dup'd into the document
	   arena before the next reset. */
	ShclParser P; P.d = d; P.tmp = &d->scratch; P.line = &own->line; P.hints = &own->hints; P.cmaps = &own->cmaps; P.dmaps = &own->dmaps; memset(&P.stack, 0, sizeof P.stack); memset(&P.pending, 0, sizeof P.pending); memset(&P.pend_marks, 0, sizeof P.pend_marks); memset(&P.depth_chain, 0, sizeof P.depth_chain); memset(&P.held_chain, 0, sizeof P.held_chain);
	P.star_open = 0; P.star_node = 0; P.star_key = 0; P.star_disp = 0; P.saw_blank = 0;
	P.max_nodes = max_nodes; P.max_elements = max_elements; P.max_diags = max_diags; P.unlisted_errors = 0; P.unlisted_hints = 0;
	P.has_kept_hold = 0; P.kept_hold = s_empty(); P.kept_any = 0; memset(&P.lazies, 0, sizeof P.lazies);
	memset(&P.reent_node, 0, sizeof P.reent_node); memset(&P.reent_line, 0, sizeof P.reent_line); memset(&P.late_dups, 0, sizeof P.late_dups);
	ShclStackEnt e0; e0.indent = s_empty(); e0.node = ROOT; ShclVecStack_push(P.tmp, &P.stack, e0);
	maps_push(d->panic, P.cmaps, NULL);
	maps_push(d->panic, P.dmaps, NULL);
	/* One tokens struct for the whole parse; its two span vectors grow in the
	   scratch arena, so nothing of them stays with the document. */
	ShclTokens tok; memset(&tok, 0, sizeof tok); tok.cap = max_elements;

	ShclStr full; full.p = text ? text : ""; full.n = len;
	if (full.n >= 3 && (unsigned char)full.p[0] == 0xEF && (unsigned char)full.p[1] == 0xBB && (unsigned char)full.p[2] == 0xBF) full = s_slice(full, 3, full.n);
	/* The whole input, retained once in the document arena. Every stored
	   string below is either a slice of this copy (names, element texts,
	   comments, raw info) or built beside it, so nothing references the
	   caller's buffer and per-piece duplication disappears. */
	full = s_dup(a, full);
	P.src = full;
	ShclVecS lines = {0};
	{
		size_t start = 0;
		for (size_t i = 0; i <= full.n; i++) {
			if (i == full.n || full.p[i] == '\n') {
				/* A newline-terminated text splits into one more piece than it
				   has lines. An unterminated raw block took that empty tail as
				   a body line, so the same last line read differently with and
				   without its newline, which the grammar says are one document. */
				if (i == full.n && start == full.n && full.n) break;
				ShclStr l = s_slice(full, start, i);
				/* The whole trailing CR run goes, not just one: a raw block keeps its
				   content untrimmed, so a line left ending in CR would be written back
				   as CRLF and read as neither - the one shape where the count shows. */
				while (l.n > 0 && l.p[l.n - 1] == '\r') l.n--;
				ShclVecS_push(P.tmp, &lines, l);
				start = i + 1;
			}
		}
	}
	size_t i = 0;
	int node_capped = 0;
	while (i < lines.len) {
		/* Node cap: reported at the first line not parsed, so the count can
		   overshoot by at most one line's path. The unparsed remainder counts
		   as lost, which is what keeps shcl_save_file from writing a silently
		   truncated document. */
		if (P.max_nodes && d->nodes.len - 1 > P.max_nodes) {
			ShclSB m = {0}; sb_puts(P.line, &m, "node cap of "); sb_put_u64(P.line, &m, P.max_nodes); sb_puts(P.line, &m, " exceeded; parse stopped");
			p_refuse(&P, i + 1, "E020", sb_S(&m), out_stopped(lines.data + i, lines.len - i), s_empty());
			node_capped = 1;
			break;
		}
		arena_reset(&own->line);
		size_t lineno = i + 1;
		ShclStr line = trim_wsp_end(lines.data[i]);
		size_t ind = 0; while (ind < line.n && (line.p[ind] == ' ' || line.p[ind] == '\t')) ind++;
		ShclStr indent = s_slice(line, 0, ind);
		/* A carriage return is a blank but never indent, so a run of blanks
		   holding one comes off the front of the rest instead. */
		ShclStr rest = trim_wsp_start(s_slice(line, ind, line.n));
		size_t lead = line.n - ind - rest.n;
		if (rest.n == 0) { P.saw_blank = 1; i++; continue; }
		/* Whole-line comment: hold it for the next line that binds a node. It
		   consumes a pending blank into its own flag, so a blank between
		   comment-only regions survives the round-trip. Text and indent are
		   slices of the retained input copy, so they store as-is. */
		if (rest.p[0] == '#') {
			ShclPend pd; pd.text = rest; pd.indent = indent; pd.blank_before = P.saw_blank; pd.ceiling = indent.n; pd.line = lineno; P.saw_blank = 0;
			ShclVecPend_push(P.tmp, &P.pending, pd);
			i++; continue;
		}
		/* A kept misplaced line holds only the lines written under it. */
		if (P.has_kept_hold && !(indent.n > P.kept_hold.n && memcmp(indent.p, P.kept_hold.p, P.kept_hold.n) == 0)) P.has_kept_hold = 0;
		/* Any other line consumes the pending blank; only a field line that
		   binds turns it into grouping. */
		int had_blank = P.saw_blank; P.saw_blank = 0;
		/* A binding line claims the pending comments - but deeper-written ones
		   hang on their own block first. A line refused for where it sits
		   closes nothing, so it leaves them for the next line: kept, its indent
		   would measure the levels differently on a reload, and dropped, a
		   reload never sees it. */
		ShclLocated found = locate(&P, indent);
		if (found.found && found.parent != DEAD) hang_deeper_pending(&P, indent);
		/* Child-indent fence: a value line for its parent field. The fence and
		   its info string are the value; a comment may follow them. */
		ShclFence f; f.ok = 0; f.ch = 0; f.len = 0; f.info = s_empty();
		if (rest.p[0] == '`' || rest.p[0] == '~') f = child_fence(P.tmp, rest, &tok);
		if (f.ok) {
			ShclStr fcomment = tok.has_comment ? s_slice(rest, tok.comment, rest.n) : s_empty();
			size_t parent;
			int resolved = resolve_parent(&P, indent, found, &parent);
			size_t next; ShclValue val = consume_raw(&P, lines.data, lines.len, i + 1, lineno, indent, f, &next);
			/* The body goes with its fence: parsed live, it would read as root
			   bindings and the closing fence would open a second block. */
			if (!resolved) { p_refuse(&P, lineno, "E012", s_lit("indentation matches no open level"), out_kind(OUT_DROPPED), indent); i = next; continue; }
			if (parent == DEAD) skip_under_dead(&P, lineno, indent);
			else if (tok.capped) {
				/* The block goes with its line, or the body would read as live
				   lines. */
				ShclSB m = {0}; sb_puts(P.line, &m, "array longer than "); sb_put_u64(P.line, &m, P.max_elements); sb_puts(P.line, &m, " elements; line skipped");
				p_refuse(&P, lineno, "E021", sb_S(&m), out_kind(OUT_DROPPED), indent);
			}
			else {
				parent = open_lazy(&P, parent);
				/* The fence binds its field again, so a kept field line before
				   it, which sits under that field, stays in the block, with the
				   comments before it. A misplaced line never hangs on a block,
				   so it waits for the next line. */
				size_t kf = P.pending.len, si = P.stack.len;
				while (kf > 0 && !is_field(P.pending.data[kf - 1].text)) kf--;
				while (si > 0 && P.stack.data[si - 1].node != parent) si--;
				if (parent != ROOT && kf > 0 && si > 0) {
					ShclPend *misplaced = (ShclPend *)arena_alloc(P.tmp, kf * sizeof(ShclPend));
					size_t moved = 0, off = 0;
					for (size_t r = 0; r < kf; r++) {
						ShclStr t = P.pending.data[r].text;
						if (!(t.n && (t.p[0] == ' ' || t.p[0] == '\t'))) P.pending.data[moved++] = P.pending.data[r];
						else misplaced[off++] = P.pending.data[r];
					}
					memcpy(P.pending.data + moved, misplaced, off * sizeof(ShclPend));
					give_pending(&P, parent, P.stack.data[si - 1].indent, moved, 1);
				}
				size_t bnode = bind_block(&P, parent, val, lineno, indent);
				if (bnode != (size_t)-1) {
					ShclVecSize_push(a, &d->ends, NODE(d, bnode).line); ShclVecSize_push(a, &d->ends, next);
					attach_trivia(&P, bnode, indent, fcomment);
				}
			}
			i = next; continue;
		}
		if (rest.n >= 1 && rest.p[0] == '*') {
			ShclStr after = s_slice(rest, 1, rest.n);
			/* A `*` alone after the trim: whether a space followed it decides
			   between an empty element and a malformed line, and only the
			   untrimmed line still knows. */
			int spaced = after.n >= 1 && is_wsp((unsigned char)after.p[0]);
			if (after.n == 0 && lines.data[i].n > indent.n + lead + 1) spaced = is_wsp((unsigned char)lines.data[i].p[indent.n + lead + 1]);
			if (spaced) {
				size_t parent;
				if (!resolve_parent(&P, indent, found, &parent)) { misplaced(&P, lineno, "E012", indent, rest, had_blank, 0); i++; continue; }
				if (parent == DEAD) { misplaced(&P, lineno, "E018", indent, rest, had_blank, 0); i++; continue; }
				tokenize_value(P.tmp, rest, 1, SHCL_RULES_CURRENT, &tok);
				uint32_t esc;
				const char *fault = NULL; ShclStr fmsg = s_empty();
				if (bad_escape(&tok, rest, 1, &esc)) { fault = "E023"; fmsg = escape_msg(P.line, esc); }
				else if (any_path_like(&tok, rest)) { fault = "E024"; fmsg = s_lit(path_msg); }
				if (fault) {
					p_refuse(&P, lineno, fault, fmsg, out_retained(trim_wsp_end(rest), had_blank), indent);
					i++; continue;
				}
				parent = open_lazy(&P, parent);
				ShclStr ecomment = tok.has_comment ? s_slice(rest, tok.comment, rest.n) : s_empty();
				/* Elements have no node of their own; trivia rides the field. At the
				   root there is no field (E007), so the comment rides the document
				   like any other pending one. */
				if (parent != ROOT) {
					if (add_star_element(&P, parent, &tok, rest, lineno, indent)) keep_among(&P, parent, indent);
					size_t head = NODE(d, parent).line;
					if (d->ends.len && d->ends.data[d->ends.len - 2] == head) d->ends.data[d->ends.len - 1] = lineno;
					else { ShclVecSize_push(a, &d->ends, head); ShclVecSize_push(a, &d->ends, lineno); }
					attach_trivia(&P, parent, indent, ecomment);
				} else {
					if (ecomment.n) { ShclPend pd; pd.text = ecomment; pd.indent = indent; pd.blank_before = had_blank; pd.ceiling = indent.n; pd.line = 0; ShclVecPend_push(P.tmp, &P.pending, pd); }
					(void)add_star_element(&P, parent, &tok, rest, lineno, indent);
				}
				i++; continue;
			}
			{
				size_t parent;
				if (!resolve_parent(&P, indent, found, &parent)) { misplaced(&P, lineno, "E012", indent, rest, had_blank, 0); i++; continue; }
				if (parent == DEAD) { misplaced(&P, lineno, "E018", indent, rest, had_blank, 0); i++; continue; }
			}
			/* Content-malformed at any position, so safe to retain. The BOM
			   exception the field arm makes cannot apply here: this line
			   starts with the '*' that brought us in. */
			p_refuse(&P, lineno, "E013", s_lit("malformed line: '*' must be followed by a space"), out_retained(trim_wsp_end(rest), had_blank), indent);
			i++; continue;
		}
		/* Field line. */
		tokenize(P.tmp, rest, ':', 0, SHCL_RULES_CURRENT, &tok);
		ShclStr comment = tok.has_comment ? s_slice(rest, tok.comment, rest.n) : s_empty();
		size_t parent;
		if (!resolve_parent(&P, indent, found, &parent)) { misplaced(&P, lineno, "E012", indent, rest, had_blank, line_fence(P.tmp, &tok, rest).ok); i = skip_field_line(&P, lines.data, lines.len, i, indent, &tok, rest); continue; }
		if (parent == DEAD) { misplaced(&P, lineno, "E018", indent, rest, had_blank, line_fence(P.tmp, &tok, rest).ok); i = skip_field_line(&P, lines.data, lines.len, i, indent, &tok, rest); continue; }
		ShclPathScan scan = path_of(&own->line, &tok, rest);
		if (!scan.ok) {
			ShclSB m = {0}; sb_puts(P.line, &m, "malformed line skipped: "); sb_putS(P.line, &m, scan.err);
			/* The column counts bytes from the line start, so all four bindings
			   report it the same on non-ASCII text. */
			sb_puts(P.line, &m, ", at column "); sb_put_u64(P.line, &m, (uint64_t)(indent.n + lead + tok.fault_at + 1));
			/* Content-malformed at any position, so retained - except a line led
			   by a BOM, which the file-start strip would rewrite into something
			   that can bind. */
			int bom = rest.n >= 3 && (unsigned char)rest.p[0] == 0xEF && (unsigned char)rest.p[1] == 0xBB && (unsigned char)rest.p[2] == 0xBF;
			p_refuse(&P, lineno, "E014", sb_S(&m), bom ? out_kind(OUT_DROPPED) : out_retained(trim_wsp_end(rest), had_blank), indent);
			i = bom ? skip_field_line(&P, lines.data, lines.len, i, indent, &tok, rest) : keep_body(&P, lines.data, lines.len, i, indent, &tok, rest);
			continue;
		}
		size_t next = i + 1;
		/* A selector body takes the same open-quote rule as a value element,
		   and the same code: the body is read bare, quotes and all, so the line
		   still binds - somewhere the author did not mean. */
		if (selector_open_quote(&tok)) p_err(&P, lineno, "E017", s_lit("unterminated quote in selector"));
		/* A value written the way JSON, TOML and YAML write an array, or an
		   escape that cannot be read as written or as an escape without
		   guessing. The brackets are not a selector after the colon, and
		   reading the text without them would bake a changed value in, so the
		   line is kept verbatim. Judged before the cap and from the first
		   piece, which the cap keeps: a cap refuses only a line that would
		   bind. Only the value is wrong, so the lines under it still load,
		   under the path opened empty. */
		{
			ShclStr fmsg;
			const char *fault = line_fault(P.line, &tok, rest, &fmsg);
			if (fault) {
				p_refuse(&P, lineno, fault, fmsg, out_retained(trim_wsp_end(rest), had_blank), indent);
				uint32_t esc;
				if (!bad_escape(&tok, rest, 0, &esc)) hold_open(&P, parent, scan.segs.data, scan.segs.len, lineno, indent);
				/* Only a fault in the name leaves a fence to read here. */
				i = keep_body(&P, lines.data, lines.len, i, indent, &tok, rest); continue;
			}
		}
		/* Element cap: the whole line is refused, so a capped load never holds
		   a truncated array that would read as the document's value. The scan
		   stopped at the cap, so nothing past it was built either, and the
		   value span is empty: this has to come before the value is read, or
		   the line would bind as empty. */
		if (tok.capped) {
			ShclSB m = {0}; sb_puts(P.line, &m, "array longer than "); sb_put_u64(P.line, &m, P.max_elements); sb_puts(P.line, &m, " elements; line skipped");
			p_refuse(&P, lineno, "E021", sb_S(&m), out_kind(OUT_DROPPED), indent);
			i = skip_field_line(&P, lines.data, lines.len, i, indent, &tok, rest); continue;
		}
		ShclValue value;
		int celled = 0;
		if (!scan.has_value) {
			/* A clean path with no colon is the one defined repair: the obvious
			   intent is that path with an empty value. */
			p_err(&P, lineno, "E015", s_lit("missing colon; repaired as an empty value"));
			value = v_empty();
		}
		else if (scan.value_text.n == 0) value = v_empty();
		else {
			ShclFence vf = fence_open(scan.value_text);
			if (vf.ok) value = consume_raw(&P, lines.data, lines.len, i + 1, lineno, indent, vf, &next);
			else {
				int open = 0;
				for (size_t k = 0; k < tok.nelem; k++) if (tok.elements[k].quote == SHCL_QUOTE_OPEN) open = 1;
				if (open) p_err(&P, lineno, "E017", s_lit("unterminated quote in value"));
				value = cell_of_tokens(a, &own->line, &tok, rest);
				celled = 1;
			}
		}
		size_t node = 0; /* attach_path fills it; the init quiets gcc's inlining-dependent maybe-uninitialized */
		parent = open_lazy(&P, parent);
		size_t nsegs = scan.segs.len;
		if (attach_path(&P, parent, scan.segs.data, scan.segs.len, value, lineno, indent, &node)) {
			for (size_t k = 0; celled && unit_named(NODE(d, node).name) && k < tok.nelem; k++) {
				ShclStr clash;
				if (unit_clash(P.tmp, NODE(d, node).name, piece_text(P.tmp, &tok.elements[k], rest), &clash)) { p_diag(&P, lineno, SHCL_SEV_HINT, "H005", clash); break; }
			}
			if (had_blank) NODE(d, node).blank_before = 1;
			if (next > i + 1) { ShclVecSize_push(a, &d->ends, lineno); ShclVecSize_push(a, &d->ends, next); }
			/* A kept line before a dotted line sits level with its first
			   segment, so it goes there with the comments before it. Under the
			   last one it would be written deeper and read as a child. */
			if (nsegs > 1) {
				size_t kf = P.pending.len;
				while (kf > 0 && !is_field(P.pending.data[kf - 1].text)) kf--;
				give_pending(&P, head_of(&P, node, nsegs), indent, kf, 0);
			}
			attach_trivia(&P, node, indent, comment);
			ShclStackEnt se; se.indent = indent; se.node = node; ShclVecStack_push(P.tmp, &P.stack, se);
		}
		i = next;
	}
	/* A cap crossed on the document's last line still reports, with nothing
	   left to skip. */
	if (!node_capped && P.max_nodes && d->nodes.len - 1 > P.max_nodes) {
		ShclSB m = {0}; sb_puts(P.line, &m, "node cap of "); sb_put_u64(P.line, &m, P.max_nodes); sb_puts(P.line, &m, " exceeded; parse stopped");
		p_refuse(&P, lines.len, "E020", sb_S(&m), out_stopped(NULL, 0), s_empty());
	}
	star_flush(&P);
	/* Indented tail comments keep their block; only top-level ones orphan.
	   Before the fold, which moves a dropped instance's comments over to the
	   one it joins: after it they would hang on the dropped one. */
	hang_deeper_pending(&P, s_empty());
	fold_late_dups(&P);
	for (size_t n = 0; n < d->nodes.len; n++) settle_block(d, n, 1);
	emit_repeated_leaf_hints(&P);
	/* Before the cap entry, which ends the list. */
	arena_reset(P.hints);
	diags_by_line(P.hints, &d->diags);
	P.depth_chain.len = 0;
	P.held_chain.len = 0;
	for (size_t k = 0; k < P.pending.len; k++)
		ShclVecLead_push(a, &d->orphans, lead_at(P.pending.data[k].text, P.pending.data[k].blank_before, comment_depth(&P, s_empty(), P.pending.data[k].text, P.pending.data[k].indent), P.pending.data[k].line));
	settle_first_blank(d);
	/* The one entry past the cap: what was not listed, and whether any of it
	   was an error, so a consumer scanning the list for errors still finds
	   one and a strict load still fails. */
	if (P.unlisted_errors + P.unlisted_hints) {
		ShclSB m = {0};
		sb_puts(a, &m, "diagnostic cap of "); sb_put_u64(a, &m, P.max_diags);
		sb_puts(a, &m, " reached; "); sb_put_u64(a, &m, P.unlisted_errors + P.unlisted_hints);
		sb_puts(a, &m, " more not listed, "); sb_put_u64(a, &m, P.unlisted_errors); sb_puts(a, &m, " of them errors");
		push_diag(d, 0, P.unlisted_errors ? SHCL_SEV_ERROR : SHCL_SEV_HINT, "E022", sb_S(&m)); /* line 0: about the list */
	}
	/* The parser's scratch is dead by now, and the settle builds in it. */
	d->kept = P.kept_any;
	settle_kept(d);
}

/* -Wclobbered guesses at which locals an unwind could leave indeterminate, and
   it guesses badly once parse_body is inlined into the frame holding the
   setjmp: the recovery path below reads only the two volatile carriers and
   returns. clang has no such warning, so naming it there is itself an error. */
#if defined(__GNUC__) && !defined(__clang__)
	#pragma GCC diagnostic push
	#pragma GCC diagnostic ignored "-Wclobbered"
#endif
static shcl_doc *do_parse(const char *text, size_t len, shcl_strictness strict, size_t max_nodes, size_t max_elements, size_t max_diags, int track_dropped) {
	/* The two the unwind path has to reach. volatile because that path arrives
	   by longjmp, which leaves an ordinary local indeterminate. */
	shcl_doc *volatile doc = (shcl_doc *)calloc(1, sizeof *doc);
	if (!doc) return NULL;
	ShclParseOwn *volatile owned = (ShclParseOwn *)calloc(1, sizeof *owned);
	if (!owned) { free(doc); return NULL; }
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		/* An allocation failed somewhere below. Nothing built so far can be
		   trusted and there is no way to finish, so the whole document goes and
		   the caller gets NULL - with the process still standing, which is the
		   point. */
		shcl_doc *bad = doc; ShclParseOwn *badOwn = owned;
		bad->panic = NULL;
		arena_free(&badOwn->line); arena_free(&badOwn->hints);
		free(badOwn->cmaps.data); free(badOwn->dmaps.data); free(badOwn);
		shcl_free(bad);
		return NULL;
	}
	doc->panic = &panic;
	arena_guard(&doc->arena, &panic); arena_guard(&doc->scratch, &panic);
	arena_guard(&doc->reads, &panic); arena_guard(&doc->index_arena, &panic);
	arena_guard(&owned->line, &panic); arena_guard(&owned->hints, &panic);
	doc->strictness = strict;
	doc->track_dropped = track_dropped;
	parse_body(doc, owned, text, len, max_nodes, max_elements, max_diags);
	/* The recovery point is this frame's; leaving it armed would send a later
	   read or write jumping into a frame that is gone. */
	shcl_doc *d = doc; ShclParseOwn *own = owned;
	d->panic = NULL;
	arena_guard(&d->arena, NULL); arena_guard(&d->scratch, NULL);
	arena_guard(&d->reads, NULL); arena_guard(&d->index_arena, NULL);
	arena_free(&own->line); arena_free(&own->hints);
	free(own->cmaps.data); free(own->dmaps.data); free(own);
	/* The parser borrows scratch for its lines vector, per-parent maps, stack
	   and pending lists - about ten times the input, dead the moment the parse
	   ends. Every resolve resets it anyway, so a document nobody reads would
	   otherwise keep all of it until it was freed. */
	arena_free(&d->scratch);
	return d;
}
#if defined(__GNUC__) && !defined(__clang__)
	#pragma GCC diagnostic pop
#endif

// --- accessor: path resolution ----------------------------------------------

typedef enum { R_NONE, R_ONE, R_MANY, R_SLOTS } ShclRKind;
typedef struct { ShclRKind kind; size_t one; ShclVecSize many; ShclVecSlot slots; } ShclResolved;

/* Size the chain array to the arena, NIL-filled past the old end, so a node
   the writer pushes always has a slot. The array lives in the index arena and
   can move on growth; the stored pointer is the only reference. */
static void index_reserve(shcl_doc *d, size_t need) {
	if (need <= d->index_next_cap) return;
	size_t nc = d->index_next_cap ? d->index_next_cap * 2 : 8;
	while (nc < need) nc *= 2;
	d->index_next = (size_t *)arena_grow(&d->index_arena, d->index_next, d->index_next_cap, nc, sizeof(size_t));
	for (size_t i = d->index_next_cap; i < nc; i++) d->index_next[i] = NIL;
	d->index_next_cap = nc;
}
static void index_append(shcl_doc *d, uint64_t key, size_t node) {
	ShclArena *a = &d->index_arena;
	int was = d->index_built;
	d->index_built = 2;
	index_reserve(d, node + 1);
	d->index_next[node] = NIL;
	ShclCMapEnt *prev = cmap_first(&d->index_last, key);
	if (prev) { d->index_next[prev->val] = node; prev->val = node; }
	else { cmap_put(a, &d->index_first, key, node); cmap_put(a, &d->index_last, key, node); }
	d->index_built = was;
}
/* Walks the chain to find the predecessor; a chain is one name's siblings. */
static void index_unlink(shcl_doc *d, uint64_t key, size_t node) {
	ShclCMapEnt *fe = cmap_first(&d->index_first, key);
	if (!fe) return;
	size_t next = d->index_next[node];
	if (fe->val == node) {
		if (next == NIL) {
			cmap_del(&d->index_first, key, node);
			ShclCMapEnt *le = cmap_first(&d->index_last, key);
			if (le) cmap_del(&d->index_last, key, le->val);
		} else {
			fe->val = next;
		}
	} else {
		size_t c = fe->val;
		while (c != NIL && d->index_next[c] != node) c = d->index_next[c];
		if (c == NIL) return;
		d->index_next[c] = next;
		if (next == NIL) {
			ShclCMapEnt *le = cmap_first(&d->index_last, key);
			if (le) le->val = c;
		}
	}
	d->index_next[node] = NIL;
}
/* A merge drops the index, and so does a lookup that finds a cut-short one; the next lookup rebuilds it. */
static void index_drop(shcl_doc *d) {
	arena_reset_largest(&d->index_arena);
	memset(&d->index_first, 0, sizeof d->index_first);
	memset(&d->index_last, 0, sizeof d->index_last);
	d->index_next = NULL;
	d->index_next_cap = 0;
	d->index_built = 0;
}
static void name_index(shcl_doc *d) {
	if (d->index_built == 1) return;
	if (d->index_built) index_drop(d);
	d->index_built = 2;
	index_reserve(d, d->nodes.len ? d->nodes.len : 1);
	/* From the root, not across the arena: a removed subtree's nodes are still
	   there with their child lists intact, so an arena walk indexes every node
	   the document ever held. Chains stay in file order - a chain is one
	   parent's same-named children, and each parent's are appended in order.
	   The stack rides in the index arena, which this call owns. */
	ShclVecSize stack = {0};
	ShclVecSize_push(&d->index_arena, &stack, ROOT);
	while (stack.len) {
		size_t p = stack.data[--stack.len];
		ShclVecSize ch = NODE(d, p).children;
		for (size_t k = 0; k < ch.len; k++) {
			index_append(d, name_key(p, NODE(d, ch.data[k]).name), ch.data[k]);
			ShclVecSize_push(&d->index_arena, &stack, ch.data[k]);
		}
	}
	d->index_built = 1;
}

static void children_named(shcl_doc *d, ShclArena *a, size_t parent, ShclStr name, ShclVecSize *out) {
	name_index(d);
	ShclCMapEnt *e = cmap_first(&d->index_first, name_key(parent, name));
	size_t c = e ? e->val : NIL;
	while (c != NIL) {
		if (s_eq(NODE(d, c).name, name) && NODE(d, c).parent == parent) ShclVecSize_push(a, out, c);
		c = d->index_next[c];
	}
}

// `group`: a sub-path reaching several nodes joins the slot list instead of
// becoming one SHCL_MULTIPLE slot. Reads want the slot per instance, so they
// leave it off; remove and exists want every node behind the wildcard.
static ShclResolved resolve_from(shcl_doc *d, const size_t *start, size_t nstart, ShclSegment *segs, size_t nsegs, int group) {
	ShclArena *a = &d->scratch; // candidates, slots, compare strings: dead after the call
	ShclVecSize cur = {0};
	// cppcheck-suppress objectIndex  ## single-element callers pass nstart == 1, so start[i] stays at 0
	for (size_t i = 0; i < nstart; i++) ShclVecSize_push(a, &cur, start[i]);
	for (size_t si = 0; si < nsegs; si++) {
		const ShclSegment *seg = &segs[si];
		ShclVecSize next = {0};
		for (size_t k = 0; k < cur.len; k++) {
			ShclVecSize ch = NODE(d, cur.data[k]).children;
			if (seg->star) {
				for (size_t j = 0; j < ch.len; j++) ShclVecSize_push(a, &next, ch.data[j]);
			} else {
				children_named(d, a, cur.data[k], seg->name, &next);
			}
		}
		if (seg->star) {
			// Name wildcard: same per-slot split as `[*]`, over every child.
			ShclSegment *rest = segs + si + 1; size_t nrest = nsegs - si - 1;
			ShclVecSlot slots = {0};
			for (size_t k = 0; k < next.len; k++) {
				ShclSlot sl; sl.present = 0; sl.idx = 0; sl.miss = SHCL_NOT_FOUND;
				if (nrest == 0) { sl.present = 1; sl.idx = next.data[k]; }
				else {
					size_t inst = next.data[k]; ShclResolved r = resolve_from(d, &inst, 1, rest, nrest, group);
					if (r.kind == R_ONE) { sl.present = 1; sl.idx = r.one; }
					else if (r.kind == R_SLOTS) {
						// A wildcard after a wildcard: the inner slots join the
						// outer list, so the two compose into one flat run of
						// leaves rather than one unreadable slot.
						for (size_t j = 0; j < r.slots.len; j++) ShclVecSlot_push(a, &slots, r.slots.data[j]);
						continue;
					}
					else if (r.kind == R_MANY && group) {
						for (size_t j = 0; j < r.many.len; j++) { ShclSlot m; m.present = 1; m.idx = r.many.data[j]; m.miss = SHCL_GOOD; ShclVecSlot_push(a, &slots, m); }
						continue;
					}
					else if (r.kind != R_NONE) sl.miss = SHCL_MULTIPLE;
				}
				ShclVecSlot_push(a, &slots, sl);
			}
			ShclResolved R; R.kind = R_SLOTS; R.slots = slots; memset(&R.many, 0, sizeof R.many); R.one = 0;
			return R;
		}
		switch (seg->sel.tag) {
		case SEL_NONE: cur = next; break;
		case SEL_VALUE: {
			ShclVecSize f = {0};
			ShclStr want = seg->sel.value;
			for (size_t k = 0; k < next.len; k++) if (s_eq(disp_key(a, &NODE(d, next.data[k]).value), want) && (!seg->sel.quoted || single_scalar(&NODE(d, next.data[k]).value))) ShclVecSize_push(a, &f, next.data[k]);
			cur = f; break;
		}
		case SEL_INDEX: {
			ShclVecSize f = {0};
			if (seg->sel.index < next.len) ShclVecSize_push(a, &f, next.data[seg->sel.index]);
			cur = f; break;
		}
		case SEL_WILDCARD: {
			ShclSegment *rest = segs + si + 1; size_t nrest = nsegs - si - 1;
			ShclVecSlot slots = {0};
			for (size_t k = 0; k < next.len; k++) {
				ShclSlot sl; sl.present = 0; sl.idx = 0; sl.miss = SHCL_NOT_FOUND;
				if (nrest == 0) { sl.present = 1; sl.idx = next.data[k]; }
				else {
					size_t inst = next.data[k]; ShclResolved r = resolve_from(d, &inst, 1, rest, nrest, group);
					if (r.kind == R_ONE) { sl.present = 1; sl.idx = r.one; }
					else if (r.kind == R_SLOTS) {
						// A wildcard after a wildcard: the inner slots join the
						// outer list, so the two compose into one flat run of
						// leaves rather than one unreadable slot.
						for (size_t j = 0; j < r.slots.len; j++) ShclVecSlot_push(a, &slots, r.slots.data[j]);
						continue;
					}
					else if (r.kind == R_MANY && group) {
						for (size_t j = 0; j < r.many.len; j++) { ShclSlot m; m.present = 1; m.idx = r.many.data[j]; m.miss = SHCL_GOOD; ShclVecSlot_push(a, &slots, m); }
						continue;
					}
					else if (r.kind != R_NONE) sl.miss = SHCL_MULTIPLE;
				}
				ShclVecSlot_push(a, &slots, sl);
			}
			ShclResolved R; R.kind = R_SLOTS; R.slots = slots; memset(&R.many, 0, sizeof R.many); R.one = 0;
			return R;
		}
		}
	}
	ShclResolved R; memset(&R, 0, sizeof R);
	if (cur.len == 0) R.kind = R_NONE;
	else if (cur.len == 1) { R.kind = R_ONE; R.one = cur.data[0]; }
	else { R.kind = R_MANY; R.many = cur; }
	return R;
}
static int resolve_mode(shcl_doc *d, ShclStr path, ShclResolved *out, int group) {
	// Every public read/query funnels through here, so this reset is the
	// scratch lifetime: the previous resolve's temporaries die now, and the
	// ShclResolved this call fills stays usable until the next resolve.
	arena_reset(&d->scratch);
	ShclPathScan ps = scan_lookup(&d->scratch, path);
	if (!ps.ok || ps.has_value) return 0;
	size_t root = ROOT;
	*out = resolve_from(d, &root, 1, ps.segs.data, ps.segs.len, group);
	return 1;
}
static int resolve(shcl_doc *d, ShclStr path, ShclResolved *out) { return resolve_mode(d, path, out, 0); }
// resolve() with every node behind a wildcard slot in the list, for the callers
// that act on the whole match rather than read one value per instance.
static int resolve_group(shcl_doc *d, ShclStr path, ShclResolved *out) { return resolve_mode(d, path, out, 1); }
static shcl_status value_at(shcl_doc *d, ShclStr path, ShclValue **out) {
	ShclResolved r;
	if (!resolve(d, path, &r)) return SHCL_NOT_FOUND;
	if (r.kind == R_NONE) return SHCL_NOT_FOUND;
	if (r.kind == R_MANY || r.kind == R_SLOTS) return SHCL_MULTIPLE;
	*out = &NODE(d, r.one).value; return SHCL_GOOD;
}
static shcl_status scalar_at(shcl_doc *d, ShclStr path, ShclElement **el) {
	ShclValue *v; shcl_status st = value_at(d, path, &v);
	if (st != SHCL_GOOD) { *el = NULL; return st; }
	if (v->kind == V_EMPTY) { *el = NULL; return SHCL_EMPTY; }
	if (v->kind == V_RAW) { *el = NULL; return SHCL_BAD_TYPE; }
	if (v->nels == 1) { *el = &v->els[0]; return SHCL_GOOD; }
	*el = NULL; return SHCL_BAD_TYPE;
}

// ShclElement list for array reads plus a per-slot pre-status: NULL entry => the
// slot has no coercible scalar and sts[i] already says why (a present element
// can still turn BadType if coercion fails). Wildcard slots stay aligned - the
// spec never drops one silently. The lists go into `a`: public reads pass the
// doc read arena (results live until shcl_free or shcl_reads_release); internal queries pass a private
// arena so probing a caller-owned doc leaves nothing behind.
static shcl_status array_elements(shcl_doc *d, ShclArena *a, ShclStr path, ShclElement ***els, shcl_status **sts, size_t *n) {
	ShclResolved r;
	*els = NULL; *sts = NULL; *n = 0;
	if (!resolve(d, path, &r)) return SHCL_NOT_FOUND;
	if (r.kind == R_SLOTS) {
		size_t m = r.slots.len;
		ShclElement **arr = (ShclElement **)arena_alloc(a, (m ? m : 1) * sizeof(ShclElement *));
		shcl_status *st = (shcl_status *)arena_alloc(a, (m ? m : 1) * sizeof(shcl_status));
		for (size_t i = 0; i < m; i++) {
			arr[i] = NULL;
			if (!r.slots.data[i].present) { st[i] = r.slots.data[i].miss; continue; }
			ShclValue *v = &NODE(d, r.slots.data[i].idx).value;
			if (v->kind == V_EMPTY) st[i] = SHCL_EMPTY;
			else if (v->kind == V_CELL && v->nels == 1) { arr[i] = &v->els[0]; st[i] = SHCL_GOOD; }
			else st[i] = SHCL_BAD_TYPE; // raw block, or an array is not one scalar
		}
		// No slots at all means the wildcard's parent is not there, so the
		// path did not resolve - Empty is for a node that is.
		*els = arr; *sts = st; *n = m; return m == 0 ? SHCL_NOT_FOUND : SHCL_GOOD;
	}
	if (r.kind == R_NONE) return SHCL_NOT_FOUND;
	if (r.kind == R_MANY) return SHCL_MULTIPLE;
	ShclValue *v = &NODE(d, r.one).value;
	if (v->kind == V_EMPTY) return SHCL_EMPTY;
	if (v->kind == V_RAW) return SHCL_BAD_TYPE;
	size_t m = v->nels;
	ShclElement **arr = (ShclElement **)arena_alloc(a, (m ? m : 1) * sizeof(ShclElement *));
	shcl_status *st = (shcl_status *)arena_alloc(a, (m ? m : 1) * sizeof(shcl_status));
	for (size_t i = 0; i < m; i++) { arr[i] = &v->els[i]; st[i] = SHCL_GOOD; }
	*els = arr; *sts = st; *n = m; return SHCL_GOOD;
}

static shcl_status worst_slot(const shcl_status *sts, size_t n, shcl_status floor_) {
	shcl_status w = floor_;
	for (size_t i = 0; i < n; i++) if (sts[i] > w) w = sts[i];
	return w;
}

size_t shcl_count(shcl_doc *d, const char *path, size_t plen) {
	ShclStr p; p.p = path; p.n = plen;
	ShclResolved r; if (!resolve(d, p, &r)) return 0;
	switch (r.kind) { case R_NONE: return 0; case R_ONE: return 1; case R_MANY: return r.many.len; case R_SLOTS: return r.slots.len; }
	return 0;
}
static ShclStr emit_name(ShclArena *a, ShclStr name);

size_t shcl_paths(shcl_doc *d, shcl_str **out) {
	ShclArena *a = &d->reads;
	// Walk stack + dedup set: dead after the call. Every other read resets
	// scratch inside its path lookup; this one takes no path, so it resets
	// here, or the document grows 11 KB per call for its whole lifetime.
	arena_reset(&d->scratch);
	ShclArena *t = &d->scratch;
	typedef struct { size_t node; ShclStr prefix; } PEnt;
	PEnt *stack = NULL; size_t sn = 0, sc = 0;
	shcl_str *arr = NULL; size_t n = 0, cap = 0;
	ShclCMap seen; memset(&seen, 0, sizeof seen);
	#define PPUSH(N, P) do { if (sn == sc) { size_t nc = sc ? sc * 2 : 16; stack = (PEnt *)arena_grow(t, stack, sc, nc, sizeof(PEnt)); sc = nc; } stack[sn].node = (N); stack[sn].prefix = (P); sn++; } while (0)
	ShclVecSize top = NODE(d, ROOT).children;
	for (size_t i = top.len; i > 0; i--) PPUSH(top.data[i - 1], s_empty());
	while (sn) {
		PEnt e = stack[--sn];
		ShclStr seg = emit_name(a, NODE(d, e.node).name);
		ShclStr path;
		if (e.prefix.n == 0) path = seg;
		else { ShclSB b = {0}; sb_putS(a, &b, e.prefix); sb_putc(a, &b, '.'); sb_putS(a, &b, seg); path = sb_S(&b); }
		uint64_t h = cmap_hash(path, s_empty());
		int dup = 0;
		for (ShclCMapEnt *en = cmap_first(&seen, h); en; en = cmap_next(en, h)) {
			ShclStr sp; sp.p = arr[en->val].p; sp.n = arr[en->val].n;
			if (s_eq(sp, path)) { dup = 1; break; }
		}
		if (!dup) {
			cmap_put(t, &seen, h, n);
			if (n == cap) { size_t nc = cap ? cap * 2 : 16; arr = (shcl_str *)arena_grow(a, arr, cap, nc, sizeof(shcl_str)); cap = nc; }
			arr[n].p = path.p; arr[n].n = path.n; n++;
		}
		ShclVecSize kids = NODE(d, e.node).children;
		for (size_t i = kids.len; i > 0; i--) PPUSH(kids.data[i - 1], path);
	}
	#undef PPUSH
	if (!arr) arr = (shcl_str *)arena_alloc(a, sizeof(shcl_str));
	*out = arr; return n;
}

size_t shcl_instance_paths(shcl_doc *d, shcl_str **out) {
	ShclArena *a = &d->reads;
	// Same reset as shcl_paths: this read takes no path.
	arena_reset(&d->scratch);
	ShclArena *t = &d->scratch;
	typedef struct { size_t node; ShclStr path; } PEnt;
	typedef struct { size_t node; size_t total; size_t at; } NCount; // node names the count's name
	PEnt *stack = NULL; size_t sn = 0, sc = 0;
	shcl_str *arr = NULL; size_t n = 0, cap = 0;
	#define PPUSH(N, P) do { if (sn == sc) { size_t nc = sc ? sc * 2 : 16; stack = (PEnt *)arena_grow(t, stack, sc, nc, sizeof(PEnt)); sc = nc; } stack[sn].node = (N); stack[sn].path = (P); sn++; } while (0)
	PPUSH(ROOT, s_empty());
	while (sn) {
		PEnt e = stack[--sn];
		if (e.node != ROOT) {
			if (n == cap) { size_t nc = cap ? cap * 2 : 16; arr = (shcl_str *)arena_grow(a, arr, cap, nc, sizeof(shcl_str)); cap = nc; }
			arr[n].p = e.path.p; arr[n].n = e.path.n; n++;
		}
		ShclVecSize kids = NODE(d, e.node).children;
		if (!kids.len) continue;
		ShclCMap names; memset(&names, 0, sizeof names);
		NCount *counts = (NCount *)arena_alloc(t, kids.len * sizeof(NCount));
		size_t *which = (size_t *)arena_alloc(t, kids.len * sizeof(size_t));
		size_t nn = 0;
		for (size_t i = 0; i < kids.len; i++) {
			ShclStr name = NODE(d, kids.data[i]).name;
			uint64_t h = cmap_hash(name, s_empty());
			size_t hit = NIL;
			for (ShclCMapEnt *en = cmap_first(&names, h); en; en = cmap_next(en, h))
				if (s_eq(NODE(d, counts[en->val].node).name, name)) { hit = en->val; break; }
			if (hit == NIL) { hit = nn++; counts[hit].node = kids.data[i]; counts[hit].total = 0; counts[hit].at = 0; cmap_put(t, &names, h, hit); }
			counts[hit].total++;
			which[i] = hit;
		}
		PEnt *mine = (PEnt *)arena_alloc(t, kids.len * sizeof(PEnt));
		for (size_t i = 0; i < kids.len; i++) {
			ShclStr seg = emit_name(a, NODE(d, kids.data[i]).name);
			ShclSB b = {0};
			if (e.path.n) { sb_putS(a, &b, e.path); sb_putc(a, &b, '.'); }
			sb_putS(a, &b, seg);
			NCount *c = &counts[which[i]];
			if (c->total > 1) {
				char ix[32]; int len = snprintf(ix, sizeof ix, "[#%llu]", (unsigned long long)c->at++);
				ShclStr ixs; ixs.p = ix; ixs.n = (size_t)len;
				sb_putS(a, &b, ixs);
			}
			mine[i].node = kids.data[i]; mine[i].path = sb_S(&b);
		}
		for (size_t i = kids.len; i > 0; i--) PPUSH(mine[i - 1].node, mine[i - 1].path);
	}
	#undef PPUSH
	if (!arr) arr = (shcl_str *)arena_alloc(a, sizeof(shcl_str));
	*out = arr; return n;
}

shcl_str shcl_quote_segment(shcl_doc *d, const char *name, size_t len) {
	ShclStr in; in.p = name; in.n = len;
	ShclStr q = emit_name(&d->reads, in);
	if (q.p == in.p) q = s_dup(&d->reads, in); // bare passthrough: copy so the result outlives the caller's buffer
	shcl_str out; out.p = q.p; out.n = q.n;
	return out;
}

static size_t instances_in(shcl_doc *d, ShclArena *a, ShclStr p, shcl_str **out) {
	// Wildcard slots that did not resolve stay in the list as "" so indices
	// keep matching shcl_count.
	ShclResolved r;
	if (!resolve(d, p, &r)) { *out = (shcl_str *)arena_alloc(a, sizeof(shcl_str)); return 0; }
	if (r.kind == R_SLOTS) {
		size_t m = r.slots.len;
		shcl_str *arr = (shcl_str *)arena_alloc(a, (m ? m : 1) * sizeof(shcl_str));
		for (size_t k = 0; k < m; k++)
			arr[k] = r.slots.data[k].present ? value_display(a, &NODE(d, r.slots.data[k].idx).value) : s_empty();
		*out = arr; return m;
	}
	ShclVecSize nodes = {0};
	if (r.kind == R_ONE) ShclVecSize_push(a, &nodes, r.one);
	else if (r.kind == R_MANY) for (size_t k = 0; k < r.many.len; k++) ShclVecSize_push(a, &nodes, r.many.data[k]);
	shcl_str *arr = (shcl_str *)arena_alloc(a, (nodes.len ? nodes.len : 1) * sizeof(shcl_str));
	for (size_t k = 0; k < nodes.len; k++) arr[k] = value_display(a, &NODE(d, nodes.data[k]).value);
	*out = arr; return nodes.len;
}
size_t shcl_instances(shcl_doc *d, const char *path, size_t plen, shcl_str **out) {
	ShclStr p; p.p = path; p.n = plen;
	return instances_in(d, &d->reads, p, out);
}

size_t shcl_line(shcl_doc *d, const char *path, size_t plen) {
	ShclStr p; p.p = path; p.n = plen;
	ShclResolved r; if (!resolve(d, p, &r)) return 0;
	if (r.kind != R_ONE) return 0;
	return NODE(d, r.one).line; // writer-built nodes have 0
}

int shcl_quoted(shcl_doc *d, const char *path, size_t plen) {
	ShclStr p; p.p = path; p.n = plen; ShclElement *el;
	if (scalar_at(d, p, &el) != SHCL_GOOD) return 0;
	return el->quoted;
}

shcl_str shcl_authored_name(shcl_doc *d, const char *path, size_t plen) {
	ShclStr p; p.p = path; p.n = plen;
	ShclResolved r; if (!resolve(d, p, &r)) return s_empty();
	if (r.kind != R_ONE) return s_empty();
	return node_authored(&NODE(d, r.one));
}

size_t shcl_lines(shcl_doc *d, const char *path, size_t plen, size_t **out) {
	// Wildcard slots that did not resolve stay in the list as 0 so indices
	// keep matching shcl_count.
	ShclArena *a = &d->reads; ShclStr p; p.p = path; p.n = plen;
	ShclResolved r;
	if (!resolve(d, p, &r)) { *out = (size_t *)arena_alloc(a, sizeof(size_t)); return 0; }
	if (r.kind == R_SLOTS) {
		size_t m = r.slots.len;
		size_t *arr = (size_t *)arena_alloc(a, (m ? m : 1) * sizeof(size_t));
		for (size_t k = 0; k < m; k++)
			arr[k] = r.slots.data[k].present ? NODE(d, r.slots.data[k].idx).line : 0;
		*out = arr; return m;
	}
	ShclVecSize nodes = {0};
	if (r.kind == R_ONE) ShclVecSize_push(a, &nodes, r.one);
	else if (r.kind == R_MANY) for (size_t k = 0; k < r.many.len; k++) ShclVecSize_push(a, &nodes, r.many.data[k]);
	size_t *arr = (size_t *)arena_alloc(a, (nodes.len ? nodes.len : 1) * sizeof(size_t));
	for (size_t k = 0; k < nodes.len; k++) arr[k] = NODE(d, nodes.data[k]).line; // writer-built nodes have 0
	*out = arr; return nodes.len;
}

size_t shcl_children(shcl_doc *d, const char *path, size_t plen, shcl_str **out) {
	// Names come back as stored (already arena-owned); only the array is new.
	ShclArena *a = &d->reads; ShclStr p; p.p = path; p.n = plen;
	arena_reset(&d->scratch); // the node list is dead after the call
	ShclVecSize nodes = {0};
	if (s_trim(p).n == 0) {
		ShclVecSize_push(&d->scratch, &nodes, ROOT);
	} else {
		ShclResolved r;
		if (!resolve(d, p, &r)) { *out = (shcl_str *)arena_alloc(a, sizeof(shcl_str)); return 0; }
		if (r.kind == R_ONE) ShclVecSize_push(&d->scratch, &nodes, r.one);
		else if (r.kind == R_MANY) for (size_t k = 0; k < r.many.len; k++) ShclVecSize_push(&d->scratch, &nodes, r.many.data[k]);
		else if (r.kind == R_SLOTS)
			for (size_t k = 0; k < r.slots.len; k++)
				if (r.slots.data[k].present) ShclVecSize_push(&d->scratch, &nodes, r.slots.data[k].idx);
	}
	size_t total = 0;
	for (size_t k = 0; k < nodes.len; k++) total += NODE(d, nodes.data[k]).children.len;
	shcl_str *arr = (shcl_str *)arena_alloc(a, (total ? total : 1) * sizeof(shcl_str));
	size_t n = 0;
	for (size_t k = 0; k < nodes.len; k++) {
		ShclVecSize kids = NODE(d, nodes.data[k]).children;
		for (size_t j = 0; j < kids.len; j++) { arr[n].p = NODE(d, kids.data[j]).name.p; arr[n].n = NODE(d, kids.data[j]).name.n; n++; }
	}
	*out = arr; return n;
}

// --- Writer ------------------------------------------------------------------
// The reverse of the reads. Reads and shcl_to_canonical walk the children vecs,
// so mutating the arena directly is enough - the parser's child map is gone by
// now. New value text is dup'd into the arena; the caller's buffers may go away.

static ShclStr w_dupz(ShclArena *a, const char *p, size_t n) { ShclStr s; s.p = p; s.n = n; return s_dup(a, s); }
static ShclStr w_int_text(ShclArena *a, int64_t v) { char b[32]; int n = snprintf(b, sizeof b, "%lld", (long long)v); return w_dupz(a, b, (size_t)n); }
static ShclStr w_float_text(ShclArena *a, double v) { char b[SHCL_FLOAT_BUF]; size_t n = shcl_format_float(v, b); return w_dupz(a, b, n); }
static ShclStr w_bool_text(int v) { return v ? s_lit("true") : s_lit("false"); }
static ShclStr w_dt_text(ShclArena *a, const shcl_datetime *dt) { char b[SHCL_DT_BUF]; size_t n = shcl_datetime_str(dt, b); return w_dupz(a, b, n); }
/* Whether a datetime's canonical spelling reads back as the same value: the
   setter's inverse-of-the-read promise, checked by making the round trip. */
static int dt_reads_back(ShclArena *scratch, const shcl_datetime *dt) {
	char b[SHCL_DT_BUF]; ShclStr t; t.p = b; t.n = shcl_datetime_str(dt, b);
	shcl_datetime back;
	if (!parse_datetime(scratch, t, &back)) return 0;
	if (back.has_date != dt->has_date || back.has_time != dt->has_time || back.has_sec != dt->has_sec || back.has_frac != dt->has_frac || back.zone != dt->zone) return 0;
	if (dt->has_date && (back.year != dt->year || back.month != dt->month || back.day != dt->day)) return 0;
	if (dt->has_time && (back.hour != dt->hour || back.minute != dt->minute || (dt->has_sec && back.sec != dt->sec))) return 0;
	if (dt->has_frac && !s_eq(back.frac, dt->frac)) return 0;
	if (dt->zone == SHCL_ZONE_OFFSET && back.off_min != dt->off_min) return 0;
	return 1;
}


/* Defined with the emitter: each check is the emitted spelling read back. */
static ShclStr value_half(ShclArena *a, ShclArena *tmp, ShclStr text, ShclTokens *out);
static int value_reads_back(ShclArena *a, const ShclValue *v);
static int name_reads_back(ShclArena *a, ShclStr name);
static int comment_line(ShclArena *a, ShclStr text, ShclStr *out);

// Pick a backtick fence long enough that no content line closes it early.
static void w_choose_fence(ShclStr content, unsigned char *fc, size_t *fl) {
	size_t maxrun = 0, start = 0;
	for (size_t i = 0;; i++) {
		if (i == content.n || content.p[i] == '\n') {
			ShclStr t = s_trim_sp_tab(s_slice(content, start, i));
			if (t.n > 0) {
				int all = 1;
				for (size_t k = 0; k < t.n; k++) if (t.p[k] != '`') { all = 0; break; }
				if (all && t.n > maxrun) maxrun = t.n;
			}
			if (i == content.n) break;
			start = i + 1;
		}
	}
	*fc = '`'; *fl = maxrun + 1 < 3 ? 3 : maxrun + 1;
}

static ShclValue w_cell1(ShclArena *a, ShclStr text) {
	ShclValue v; memset(&v, 0, sizeof v); v.kind = V_CELL;
	ShclElement *e = (ShclElement *)arena_alloc(a, sizeof(ShclElement)); *e = new_element(text);
	v.els = e; v.nels = 1; return v;
}
// Inline-array value; the empty array is an empty value (reads back Empty).
static ShclValue w_array(ShclArena *a, const ShclStr *texts, size_t n) {
	if (n == 0) return v_empty();
	ShclValue v; memset(&v, 0, sizeof v); v.kind = V_CELL;
	ShclElement *els = (ShclElement *)arena_alloc(a, n * sizeof(ShclElement));
	for (size_t i = 0; i < n; i++) els[i] = new_element(texts[i]);
	v.els = els; v.nels = n; return v;
}

static size_t w_new_child(shcl_doc *d, size_t parent, ShclStr name, ShclStr name_src, ShclValue value) {
	/* A list written stacked would get the child after its elements, which
	   reloads as E001, so it goes inline. */
	if (stacks(&NODE(d, parent))) unstack(d, &NODE(d, parent));
	ShclArena *a = &d->arena;
	size_t idx = d->nodes.len;
	ShclNode n; memset(&n, 0, sizeof n);
	n.name = s_dup(a, name); n.name_src = spelled(a, name, name_src); n.value = value; n.parent = parent;
	/* Hand-written files separate top-level sections with a blank line;
	   writer-built ones do the same (the emitter never blanks line 1). */
	n.blank_before = (parent == ROOT);
	nodes_push(d, n);
	ShclVecSize_push(a, &NODE(d, parent).children, idx);
	if (d->index_built == 1) index_append(d, name_key(parent, name), idx);
	settle_block(d, parent, NODE(d, parent).children.len - 1);
	return idx;
}

/* The validation walk w_write_reason and w_place share. `trail`, when non-NULL,
   receives where each segment ended up - (size_t)-1 from the point the path falls
   off the existing tree - so w_place can create from exactly there instead of
   scanning the path and walking the tree a second time. `ps` is the caller's
   already-scanned path, so the scan happens once too. */
static shcl_write_reason w_probe_write(shcl_doc *d, ShclArena *a, const ShclPathScan *psp, size_t *trail) {
	const ShclPathScan ps = *psp;
	if (!ps.ok) return SHCL_W_BAD_PATH;
	if (ps.has_value) return SHCL_W_VALUE_IN_PATH;
	if (ps.segs.len == 0) return SHCL_W_BAD_PATH;
	/* Writer side of the load-time nesting cap: never create deeper. */
	if (ps.segs.len > SHCL_MAX_DEPTH) return SHCL_W_TOO_DEEP;
	/* Once this probe falls off the existing tree, a later `[#k]` can never
	   match (fresh intermediates are created childless), so an index segment
	   past that point is unresolvable. */
	int off = 0; size_t pr = ROOT;
	for (size_t i = 0; i < ps.segs.len; i++) {
		ShclSegment *seg = &ps.segs.data[i];
		if (seg->star) return SHCL_W_WILDCARD;
		if (seg->sel.tag == SEL_WILDCARD) return SHCL_W_WILDCARD;
		if (seg->sel.tag == SEL_INDEX) {
			if (off) return SHCL_W_NO_SUCH_INDEX;
			ShclVecSize matches = {0};
			children_named(d, a, pr, seg->name, &matches);
			if (seg->sel.index >= (uint64_t)matches.len) return SHCL_W_NO_SUCH_INDEX;
			pr = matches.data[seg->sel.index];
		} else if (!off) {
			size_t found = (size_t)-1;
			ShclStr want = (seg->sel.tag == SEL_VALUE) ? seg->sel.value : s_empty();
			ShclVecSize cands = {0};
			children_named(d, a, pr, seg->name, &cands);
			for (size_t k = 0; k < cands.len; k++) {
				size_t c = cands.data[k];
				if (seg->sel.tag == SEL_VALUE && !(s_eq(disp_key(a, &NODE(d, c).value), want) && (!seg->sel.quoted || single_scalar(&NODE(d, c).value)))) continue;
				found = c; break;
			}
			if (found == (size_t)-1) off = 1; else pr = found;
		}
		if (trail) trail[i] = off ? (size_t)-1 : pr;
	}
	return SHCL_W_WRITABLE;
}

// Why a write at this path would fail - the validation walk w_place runs
// before creating anything. SHCL_W_WRITABLE means w_place's gate would pass;
// nothing is created. Temporaries (scan, compare strings) go into `a`.
static shcl_write_reason w_write_reason(shcl_doc *d, ShclArena *a, ShclStr path) {
	ShclPathScan ps = scan_lookup(a, path);
	return w_probe_write(d, a, &ps, NULL);
}

// Walk (creating as needed) to the node a write targets. Returns 1 + *out, or 0
// if the path is unusable for a write (w_write_reason says why). Validation
// runs first, so a doomed path leaves no half-created intermediates behind.
static int w_place(shcl_doc *d, ShclStr path, size_t *out) {
	ShclArena *a = &d->arena;
	// The probe, the scan, and the compare strings are dead once this returns,
	// so they go through scratch (reset like resolve's; no resolve runs in
	// here) - repeated setters must not grow the doc. Only what w_new_child
	// dups persists.
	ShclArena *t = &d->scratch;
	arena_reset(t);
	ShclPathScan ps = scan_lookup(t, path);
	size_t *trail = (size_t *)arena_alloc(t, (ps.segs.len ? ps.segs.len : 1) * sizeof(size_t));
	if (w_probe_write(d, t, &ps, trail) != SHCL_W_WRITABLE) return 0;
	/* Nothing is created until every segment the write would create is known
	   to read back: the name through the name escaper, an instance selector
	   as the value it binds. */
	for (size_t i = 0; i < ps.segs.len; i++) {
		const ShclSegment *seg = &ps.segs.data[i];
		if (trail[i] != (size_t)-1) continue;
		if (!name_reads_back(t, seg->name)) return 0;
		if (seg->sel.tag == SEL_VALUE) {
			ShclValue sv = w_cell1(t, seg->sel.value);
			if (!value_reads_back(t, &sv)) return 0;
		}
	}
	size_t cur = ROOT;
	for (size_t i = 0; i < ps.segs.len; i++) {
		const ShclSegment *seg = &ps.segs.data[i];
		/* The probe already resolved every segment that exists; only the tail
		   it fell off has anything to create. */
		if (trail[i] != (size_t)-1) { cur = trail[i]; continue; }
		if (seg->sel.tag == SEL_NONE) cur = w_new_child(d, cur, seg->name, seg->name_src, v_empty());
		else if (seg->sel.tag == SEL_VALUE) cur = w_new_child(d, cur, seg->name, seg->name_src, w_cell1(a, s_dup(a, seg->sel.value)));
		/* Unreachable: w_probe_write refuses a wildcard outright and an
		   unresolvable index, so neither reaches an empty trail slot. */
		else return 0;
	}
	*out = cur; return 1;
}

/* The write-side twin of settle_fence_trailing: only the written name's
   instances can change, and walking them off the index keeps a write off the
   rest of the block. */
static void w_settle_fence_name(shcl_doc *d, size_t parent, ShclStr name) {
	ShclVecSize cands = {0};
	children_named(d, &d->scratch, parent, name, &cands);
	int seen_empty = 0;
	for (size_t k = 0; k < cands.len; k++) {
		ShclNode *nd = &NODE(d, cands.data[k]);
		if (seen_empty && nd->value.kind == V_RAW && nd->trivia && nd->trivia->trailing.n) trailing_to_leading(d, nd);
		else if (seen_empty && stacks(nd)) unstack(d, nd);
		else if (v_is_empty(&nd->value)) seen_empty = 1;
	}
}

/* Folding moves the loser's children up a level, where they can collide with
   the survivor's own. The parser's fold is depth-first for the same reason;
   only a node that just received children can hold a new pair. */
static void w_fold_dups_below(shcl_doc *d, size_t start) {
	ShclArena *t = &d->scratch;
	ShclVecSize stack = {0};
	ShclVecSize_push(t, &stack, start);
	while (stack.len) {
		size_t parent = stack.data[--stack.len];
		ShclCMap first; memset(&first, 0, sizeof first);
		ShclVecSize *ch = &NODE(d, parent).children;
		if (ch->len) cmap_reserve(t, &first, ch->len);
		size_t w = 0;
		for (size_t k = 0; k < ch->len; k++) {
			size_t c = ch->data[k];
			uint64_t h = merge_hash(NODE(d, c).name, &NODE(d, c).value);
			size_t survivor = (size_t)-1;
			for (ShclCMapEnt *e = cmap_first(&first, h); e; e = cmap_next(e, h))
				if (merge_eq(NODE(d, e->val).name, &NODE(d, e->val).value, NODE(d, c).name, &NODE(d, c).value)) { survivor = e->val; break; }
			if (survivor != (size_t)-1) {
				ShclVecSize moved = NODE(d, c).children;
				fold_node_into(d, survivor, c);
				if (d->index_built == 1) {
					index_unlink(d, name_key(parent, NODE(d, c).name), c);
					for (size_t m = 0; m < moved.len; m++) {
						ShclStr nm = NODE(d, moved.data[m]).name;
						index_unlink(d, name_key(c, nm), moved.data[m]);
						index_append(d, name_key(survivor, nm), moved.data[m]);
					}
				}
				ShclVecSize_push(t, &stack, survivor);
			} else {
				cmap_put(t, &first, h, c);
				ch->data[w++] = c;
			}
		}
		ch->len = w;
		settle_block(d, parent, 1);
	}
}

/* A written value may now collide with a same-named sibling under the in-file
   merge rule; fold the pair the way a reparse would (earlier sibling survives,
   later one folds children and trivia in) so Writer output stays a formatter
   fixpoint. */
static void w_collapse_dup(shcl_doc *d, size_t node) {
	size_t parent = NODE(d, node).parent;
	const ShclNode *me = &NODE(d, node);
	ShclVecSize cands = {0};
	children_named(d, &d->scratch, parent, me->name, &cands);
	size_t other = (size_t)-1;
	for (size_t k = 0; k < cands.len; k++) {
		size_t c = cands.data[k];
		if (c != node && merge_eq(NODE(d, c).name, &NODE(d, c).value, me->name, &me->value)) { other = c; break; }
	}
	if (other == (size_t)-1) return;
	ShclVecSize ch = NODE(d, parent).children;
	size_t pos_node = (size_t)-1, pos_other = (size_t)-1;
	for (size_t k = 0; k < ch.len; k++) {
		if (ch.data[k] == node) pos_node = k;
		else if (ch.data[k] == other) pos_other = k;
	}
	size_t survivor = (pos_other < pos_node) ? other : node;
	size_t loser = (survivor == node) ? other : node;
	ShclVecSize moved = NODE(d, loser).children;
	fold_node_into(d, survivor, loser);
	ShclVecSize *pk = &NODE(d, parent).children;
	size_t w = 0;
	for (size_t k = 0; k < pk->len; k++) if (pk->data[k] != loser) pk->data[w++] = pk->data[k];
	pk->len = w;
	settle_block(d, parent, 1);
	if (d->index_built == 1) {
		index_unlink(d, name_key(parent, NODE(d, loser).name), loser);
		for (size_t k = 0; k < moved.len; k++) {
			ShclStr nm = NODE(d, moved.data[k]).name;
			index_unlink(d, name_key(loser, nm), moved.data[k]);
			index_append(d, name_key(survivor, nm), moved.data[k]);
		}
	}
	w_fold_dups_below(d, survivor);
}

/* The setters encode into the document arena before the path is validated, and
   a bump arena never gives that back - a refused 20 MB write used to cost the
   document 85 MB permanently. w_place allocates only in scratch until its
   probe passes, so on a refusal nothing but the encoded value sits past the
   mark. The mark is taken by the caller, before it encodes. A value refused
   by its read-back is checked in scratch, and nothing resets scratch after a
   refusal, so it goes back here. */
static int w_set_marked(shcl_doc *d, ShclStr path, ShclValue v, ShclMark m) {
	size_t idx;
	if (!value_reads_back(&d->scratch, &v)) { arena_release(&d->arena, m); arena_reset(&d->scratch); return 0; }
	if (d->probe) { arena_release(&d->arena, m); arena_reset_smallest(&d->scratch); return 1; }
	if (!w_place(d, path, &idx)) { arena_release(&d->arena, m); return 0; }
	NODE(d, idx).value = v;
	/* No longer the list the lines among its elements sat in. */
	unstack(d, &NODE(d, idx));
	/* An empty binding or a raw block can put a fence after an empty sibling
	   of its name. */
	int fence_side = v.kind == V_EMPTY || v.kind == V_RAW;
	size_t parent = NODE(d, idx).parent;
	ShclStr name = NODE(d, idx).name;
	w_collapse_dup(d, idx);
	if (fence_side) w_settle_fence_name(d, parent, name);
	settle_first_blank(d);
	resettle_kept(d);
	return 1;
}

shcl_doc *shcl_new(void) { return shcl_parse("", 0); }

int shcl_exists(shcl_doc *d, const char *path, size_t plen) {
	ShclStr p; p.p = path; p.n = plen; ShclResolved r;
	if (!resolve_group(d, p, &r)) return 0;
	if (r.kind == R_ONE || r.kind == R_MANY) return 1;
	if (r.kind == R_SLOTS) for (size_t i = 0; i < r.slots.len; i++) if (r.slots.data[i].present) return 1;
	return 0;
}

static int heads_block(ShclArena *a, const ShclNode *node);
static int opened_by_kept(ShclArena *a, const ShclNode *node);

/* A reload starts a comment run at 0 and steps one level at a time, so a
   comment left after the one it sat under went is pulled back to fit. */
static void restep(ShclVecLead *v) {
	size_t room = 0;
	for (size_t k = 0; k < v->len; k++) {
		if (!(v->data[k].text.n && v->data[k].text.p[0] == '#')) continue;
		if (v->data[k].depth > room) v->data[k].depth = room;
		room = v->data[k].depth + 1;
	}
}

/* What a remove of this node leaves of its lines, by design.md's kept-lines
   table, onto the end of left: the kept lines beside it, with the comments
   that sit with them. Above it that is everything up to its last kept line,
   below it everything from its first, so a comment written against the node
   goes with it. The kept line written in place of its `name:` line goes
   too. */
static void beside_kept(shcl_doc *d, ShclNode *nd, ShclVecLead *left) {
	int heads = heads_block(&d->scratch, nd);
	ShclTrivia *t = nd->trivia;
	if (!t) return;
	size_t end = 0;
	for (size_t k = t->leading.len - (heads ? 1 : 0); k > 0; k--)
		if (lead_is_kept_line(&t->leading.data[k - 1])) { end = k; break; }
	for (size_t k = 0; k < end; k++) ShclVecLead_push(&d->arena, left, t->leading.data[k]);
	t->leading.len = 0;
	size_t from = t->after.len;
	for (size_t k = 0; k < t->after.len; k++)
		if (lead_is_kept_line(&t->after.data[k])) { from = k; break; }
	for (size_t k = from; k < t->after.len; k++) ShclVecLead_push(&d->arena, left, t->after.data[k]);
	t->after.len = from;
}

/* Lines a remove left, put above the sibling that followed them. Takes left. */
static void leave_above(shcl_doc *d, size_t node, ShclVecLead *left) {
	ShclTrivia *t = triv_mut(&d->arena, &NODE(d, node));
	for (size_t k = 0; k < t->leading.len; k++) ShclVecLead_push(&d->arena, left, t->leading.data[k]);
	t->leading = *left;
	restep(&t->leading);
	memset(left, 0, sizeof *left);
}

/* The same, as the document's footer. */
static void leave_orphans(shcl_doc *d, ShclVecLead *left) {
	for (size_t k = 0; k < d->orphans.len; k++) ShclVecLead_push(&d->arena, left, d->orphans.data[k]);
	d->orphans = *left;
	restep(&d->orphans);
	memset(left, 0, sizeof *left);
}

/* Lines a remove left right after node's block: above the next binding line,
   or the footer when there is none. Takes left. */
static void leave_below(shcl_doc *d, size_t node, ShclVecLead *left) {
	size_t at = node;
	while (at != ROOT) {
		size_t up = NODE(d, at).parent;
		ShclVecSize kids = NODE(d, up).children;
		for (size_t k = 0; k + 1 < kids.len; k++)
			if (kids.data[k] == at) { leave_above(d, kids.data[k + 1], left); return; }
		at = up;
	}
	leave_orphans(d, left);
}

/* Lines a remove left after the last of parent's children: the document's
   footer at the top, else after the last child left, else inside the block.
   A misplaced line has no level there, so a reload files it with the next
   binding line, and the comments after it go along; kept field lines still
   go to the block. Takes left. */
static void leave_last(shcl_doc *d, size_t parent, ShclVecLead *left) {
	if (parent == ROOT) { leave_orphans(d, left); return; }
	ShclVecLead below = {0};
	size_t at = left->len;
	for (size_t k = 0; k < left->len; k++) {
		ShclStr x = left->data[k].text;
		if (x.n && (x.p[0] == ' ' || x.p[0] == '\t')) { at = k; break; }
	}
	size_t w = at;
	for (size_t k = at; k < left->len; k++) {
		if (is_field(left->data[k].text)) left->data[w++] = left->data[k];
		else ShclVecLead_push(&d->arena, &below, left->data[k]);
	}
	left->len = w;
	if (w) {
		/* Stacked with no kept line among the elements is gone on a reload, so
		   it may not decide how these lines are written. */
		ShclNode *nd = &NODE(d, parent);
		nd->star_list = stacks(nd);
		ShclVecLead *list = nd->children.len
			? &triv_mut(&d->arena, &NODE(d, nd->children.data[nd->children.len - 1]))->after
			: &triv_mut(&d->arena, nd)->inside;
		for (size_t k = 0; k < w; k++) ShclVecLead_push(&d->arena, list, left->data[k]);
		restep(list);
	}
	memset(left, 0, sizeof *left);
	if (below.len) leave_below(d, parent, &below);
}

/* Still in the tree: each node up to ROOT is in its parent's list. A removed
   node keeps its parent link, so the link alone does not say. */
static int node_live(const shcl_doc *d, size_t node) {
	while (node != ROOT) {
		size_t p = NODE(d, node).parent;
		if (p == DEAD) return 0;
		ShclVecSize kids = NODE(d, p).children;
		size_t k = 0;
		while (k < kids.len && kids.data[k] != node) k++;
		if (k == kids.len) return 0;
		node = p;
	}
	return 1;
}

size_t shcl_remove(shcl_doc *d, const char *path, size_t plen) {
	// Work vectors only, so they go in the scratch the resolve below resets -
	// the document arena is never reset, and a wildcard remove left two vectors
	// sized to the target count sitting in it until shcl_compact.
	ShclArena *a = &d->scratch; ShclStr p; p.p = path; p.n = plen; ShclResolved r;
	if (!resolve_group(d, p, &r)) return 0;
	ShclVecSize targets = {0};
	if (r.kind == R_ONE) ShclVecSize_push(a, &targets, r.one);
	else if (r.kind == R_MANY) targets = r.many;
	else if (r.kind == R_SLOTS) for (size_t i = 0; i < r.slots.len; i++) if (r.slots.data[i].present) ShclVecSize_push(a, &targets, r.slots.data[i].idx);
	// Mark first, rebuild each touched child list once. Dropping one target at
	// a time rebuilt the same list once per target, which is quadratic when a
	// path matches many siblings. The pair of vectors is one vector of (node,
	// parent) pairs in the other three.
	ShclVecSize marked = {0}, parents = {0};
	for (size_t i = 0; i < targets.len; i++) {
		size_t t = targets.data[i]; size_t pn = NODE(d, t).parent;
		// A node already marked would pass DEAD into the rebuild below as an
		// index, so skip it rather than trust resolve never to name one twice.
		if (pn == DEAD) continue;
		if (d->kept_owed > 0) {
			size_t took = kept_taken(d, t);
			d->kept_owed = took < d->kept_owed ? d->kept_owed - took : 0;
		}
		if (d->index_built == 1) index_unlink(d, name_key(pn, NODE(d, t).name), t);
		NODE(d, t).parent = DEAD;
		ShclVecSize_push(a, &marked, t); ShclVecSize_push(a, &parents, pn);
	}
	// Rebuilding a list puts back the parent of every node it drops, so a mark
	// still standing is also the answer to "has this parent been done yet" -
	// no separate pass to dedupe the parents.
	for (size_t i = 0; i < marked.len; i++) {
		if (NODE(d, marked.data[i]).parent != DEAD) continue;
		size_t pn = parents.data[i];
		ShclVecSize *kids = &NODE(d, pn).children;
		ShclVecLead left = {0};
		size_t w = 0;
		for (size_t k = 0; k < kids->len; k++) {
			size_t c = kids->data[k];
			if (NODE(d, c).parent == DEAD) {
				NODE(d, c).parent = pn;
				beside_kept(d, &NODE(d, c), &left);
			} else {
				if (left.len) leave_above(d, c, &left);
				kids->data[w++] = c;
			}
		}
		kids->len = w;
		if (left.len) leave_last(d, pn, &left);
	}
	/* A field opened only by the lines under it goes with the last of them,
	   and its own kept line stays where it was (escblock). */
	ShclVecSize open = {0};
	for (size_t i = 0; i < parents.len; i++) ShclVecSize_push(a, &open, parents.data[i]);
	while (open.len) {
		size_t pn = open.data[--open.len];
		if (pn == ROOT || NODE(d, pn).children.len || !opened_by_kept(&d->scratch, &NODE(d, pn)) || !node_live(d, pn)) continue;
		size_t pp = NODE(d, pn).parent;
		ShclTrivia *t = NODE(d, pn).trivia;
		ShclVecLead left = t->leading;
		for (size_t k = 0; k < t->inside.len; k++) {
			ShclLead l = t->inside.data[k];
			l.depth++;
			ShclVecLead_push(&d->arena, &left, l);
		}
		for (size_t k = 0; k < t->after.len; k++) ShclVecLead_push(&d->arena, &left, t->after.data[k]);
		memset(&t->leading, 0, sizeof t->leading);
		t->inside.len = 0;
		t->after.len = 0;
		if (d->index_built == 1) index_unlink(d, name_key(pp, NODE(d, pn).name), pn);
		ShclVecSize *kids = &NODE(d, pp).children;
		size_t at = 0;
		while (at < kids->len && kids->data[at] != pn) at++;
		if (at == kids->len) continue;
		memmove(kids->data + at, kids->data + at + 1, (kids->len - at - 1) * sizeof *kids->data);
		kids->len--;
		if (at < kids->len) leave_above(d, kids->data[at], &left);
		else leave_last(d, pp, &left);
		ShclVecSize_push(a, &open, pp);
	}
	settle_first_blank(d);
	resettle_kept(d);
	return targets.len;
}

shcl_write_reason shcl_write_reason_(shcl_doc *d, const char *path, size_t plen) {
	ShclStr p; p.p = path; p.n = plen;
	// A probe, not a write: temporaries go into scratch (reset like resolve's -
	// the previous query's die now), never permanently into the doc arena.
	arena_reset(&d->scratch);
	return w_write_reason(d, &d->scratch, p);
}

/* Attach a leading comment line to the node at a path (creating an empty node
   if it does not exist yet, so a section can be annotated). A missing `#` is
   added, and trailing whitespace comes off the way the load takes it, so text
   that is blank leaves a bare `#`. Text holding a line break is refused: a
   comment is one line, and keeping only the first would drop the rest with
   nothing to say so. */
int shcl_set_comment(shcl_doc *d, const char *path, size_t plen, const char *text, size_t tlen) {
	ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; size_t idx;
	ShclStr in; in.p = text ? text : ""; in.n = tlen; ShclStr line;
	if (!comment_line(&d->scratch, in, &line)) { arena_reset(&d->scratch); return 0; }
	/* Copied out ahead of w_place, which resets the scratch the line was built
	   in; a refused place gives the copy straight back. */
	ShclMark m = arena_mark(a);
	ShclStr out = s_dup(a, line);
	if (!w_place(d, p, &idx)) { arena_release(a, m); return 0; }
	/* The node's own blank moves above its first comment; otherwise the blank
	   would separate the comment from what it annotates. Above the first one
	   already there, when there is one. */
	ShclNode *nd = &NODE(d, idx);
	ShclLead lead = lead_plain(out);
	ShclTrivia *t = triv_mut(a, nd);
	if (nd->blank_before) {
		nd->blank_before = 0;
		if (t->leading.len) t->leading.data[0].blank_before = 1;
		else lead.blank_before = 1;
	}
	ShclVecLead_push(a, &t->leading, lead);
	settle_first_blank(d);
	resettle_kept(d);
	return 1;
}

size_t shcl_comments(shcl_doc *d, const char *path, size_t plen, shcl_str **out) {
	ShclArena *a = &d->reads;
	arena_reset(&d->scratch);
	ShclArena *t = &d->scratch; ShclStr p; p.p = path; p.n = plen; ShclResolved r;
	shcl_str *arr = NULL; size_t n = 0, cap = 0;
	ShclVecSize targets = {0};
	if (resolve_group(d, p, &r)) {
		if (r.kind == R_ONE) ShclVecSize_push(t, &targets, r.one);
		else if (r.kind == R_MANY) targets = r.many;
		else if (r.kind == R_SLOTS) for (size_t i = 0; i < r.slots.len; i++) if (r.slots.data[i].present) ShclVecSize_push(t, &targets, r.slots.data[i].idx);
	}
	for (size_t i = 0; i < targets.len; i++) {
		const ShclTrivia *tr = NODE(d, targets.data[i]).trivia;
		if (!tr) continue;
		for (size_t k = 0; k < tr->leading.len; k++) {
			if (!lead_is_comment(&tr->leading.data[k])) continue;
			ShclStr l = tr->leading.data[k].text;
			if (n == cap) { size_t nc = cap ? cap * 2 : 8; arr = (shcl_str *)arena_grow(a, arr, cap, nc, sizeof(shcl_str)); cap = nc; }
			arr[n].p = l.p; arr[n].n = l.n; n++;
		}
	}
	if (!arr) arr = (shcl_str *)arena_alloc(a, sizeof(shcl_str));
	*out = arr; return n;
}

size_t shcl_clear_comments(shcl_doc *d, const char *path, size_t plen) {
	ShclArena *a = &d->scratch; ShclStr p; p.p = path; p.n = plen; ShclResolved r;
	if (!resolve_group(d, p, &r)) return 0;
	ShclVecSize targets = {0};
	if (r.kind == R_ONE) ShclVecSize_push(a, &targets, r.one);
	else if (r.kind == R_MANY) targets = r.many;
	else if (r.kind == R_SLOTS) for (size_t i = 0; i < r.slots.len; i++) if (r.slots.data[i].present) ShclVecSize_push(a, &targets, r.slots.data[i].idx);
	size_t cleared = 0;
	for (size_t i = 0; i < targets.len; i++) {
		ShclNode *nd = &NODE(d, targets.data[i]);
		ShclTrivia *t = nd->trivia;
		if (!t) continue;
		ShclVecLead *ld = &t->leading;
		/* The blank above the run is the one that separates it from what
		   comes before, so it stays with whatever is now first. */
		int blank = ld->len && ld->data[0].blank_before;
		size_t w = 0;
		for (size_t k = 0; k < ld->len; k++) if (!lead_is_comment(&ld->data[k])) ld->data[w++] = ld->data[k];
		size_t gone = ld->len - w;
		ld->len = w;
		if (!gone) continue;
		cleared += gone;
		/* A kept line left in the run may have sat under a comment that went. */
		restep(ld);
		if (w) ld->data[0].blank_before |= blank;
		else nd->blank_before |= blank;
	}
	if (cleared) { settle_first_blank(d); resettle_kept(d); }
	return cleared;
}

/* The info block's first two text lines. An old block is found by the first,
   which no release has worded differently. */
static const char banner_title[] = "## This config file format is SHCL.";
static const char banner_name[] = "## \"Simple Hierarchical Config Language\"";

static int banner_in_run(const ShclLead *l) { return s_starts(l->text, "##") && !l->blank_before; }

/* Take the info block out of v, from the lone "##" above its "This config
   file format is SHCL." line to the next lone "##", and each version line
   shcl_migrate stamped, with the note under it. A block with no closing "##"
   ends after its last line written the block's way. A Schema line in a block
   stays, and so does any other comment around one, even written right against
   it. Returns how many came off; *owed says whether the last one had a blank
   above it with no line after it to take that blank. */
static size_t drop_banners(ShclVecLead *v, int *owed) {
	size_t w = 0, removed = 0, i = 0;
	int prev_kept = 0;
	*owed = 0;
	while (i < v->len) {
		size_t start = i, end = i + 1;
		if (s_eq(v->data[i].text, s_lit(banner_title))) {
			if (prev_kept && !v->data[i].blank_before && s_eq(v->data[w - 1].text, s_lit("##"))) {
				w--;
				start = i - 1;
			}
			size_t close = end;
			while (close < v->len && banner_in_run(&v->data[close]) && !s_eq(v->data[close].text, s_lit("##"))) close++;
			if (close < v->len && banner_in_run(&v->data[close])) end = close + 1;
			else
				while (end < v->len && banner_in_run(&v->data[end]) &&
				       (s_starts(v->data[end].text, "##    ") || s_eq(v->data[end].text, s_lit(banner_name))))
					end++;
		} else if (s_starts(v->data[i].text, SHCL_FORMAT_LINE_HEAD)) {
			if (end < v->len && banner_in_run(&v->data[end]) && s_eq(v->data[end].text, s_lit(SHCL_MIGRATED_LINE))) end++;
		} else {
			v->data[w++] = v->data[i++];
			prev_kept = 1;
			continue;
		}
		/* The blank that set the block off moves to whatever followed it, so
		   the lines around it stay apart. A Schema line in the block is the
		   author's and stays, with the blank. */
		int blank = v->data[start].blank_before;
		size_t at = w;
		for (size_t k = start; k < end; k++)
			if (s_starts(v->data[k].text, SHCL_SCHEMA_LINE_HEAD)) v->data[w++] = v->data[k];
		if (at < w) v->data[at].blank_before = blank;
		else if (end < v->len) v->data[end].blank_before |= blank;
		else *owed = blank;
		removed++;
		prev_kept = 0;
		i = end;
	}
	v->len = w;
	if (removed) {
		/* A reload puts a comment at most one level past the one before it,
		   and the first at none, so what followed a block steps up to that. */
		size_t room = 0;
		for (size_t k = 0; k < v->len; k++) {
			if (!s_starts(v->data[k].text, "#")) continue;
			if (v->data[k].depth > room) v->data[k].depth = room;
			room = v->data[k].depth + 1;
		}
	}
	return removed;
}

size_t shcl_set_banner(shcl_doc *d, int on) {
	ShclArena *t = &d->scratch;
	arena_reset(t);
	size_t removed = 0;
	int owed;
	/* The first line's comments are the top of the file, on the first node
	   down, as a dotted line puts them on its last name. */
	ShclVecSize top = {0};
	for (size_t n = ROOT; NODE(d, n).children.len;) {
		n = NODE(d, n).children.data[0];
		ShclVecSize_push(t, &top, n);
	}
	ShclVecSize stack = {0};
	for (size_t i = 0; i < NODE(d, ROOT).children.len; i++) ShclVecSize_push(t, &stack, NODE(d, ROOT).children.data[i]);
	while (stack.len) {
		size_t n = stack.data[--stack.len];
		for (size_t i = 0; i < NODE(d, n).children.len; i++) ShclVecSize_push(t, &stack, NODE(d, n).children.data[i]);
		int at_top = 0;
		for (size_t i = 0; i < top.len && !at_top; i++) at_top = top.data[i] == n;
		if (at_top || !NODE(d, n).trivia) continue;
		size_t gone = drop_banners(&NODE(d, n).trivia->leading, &owed);
		if (gone) {
			removed += gone;
			NODE(d, n).blank_before |= owed;
		}
	}
	ShclVecLead *o = &d->orphans;
	removed += drop_banners(o, &owed);
	if (on) {
		int open = o->len || NODE(d, ROOT).children.len;
		/* The lines point into the literal, which outlives any document. */
		const char *b = SHCL_GEN_BANNER;
		for (size_t n = 0; *b; n++) {
			const char *nl = strchr(b, '\n');
			ShclStr line; line.p = b; line.n = (size_t)(nl - b);
			ShclVecLead_push(&d->arena, o, lead_make(line, n == 0 && open, 0));
			b = nl + 1;
		}
	}
	settle_first_blank(d);
	resettle_kept(d);
	return removed;
}

int shcl_set_empty(shcl_doc *d, const char *path, size_t plen) { ShclStr p; p.p = path; p.n = plen; ShclMark m = arena_mark(&d->arena); return w_set_marked(d, p, v_empty(), m); }
int shcl_set_int(shcl_doc *d, const char *path, size_t plen, int64_t v) { ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclMark m = arena_mark(a); return w_set_marked(d, p, w_cell1(a, w_int_text(a, v)), m); }
/* An infinity or a NaN has no spelling the reader accepts, and neither does a
   datetime the reader would refuse (month 13, a fraction with no seconds, an
   empty struct): each fails the write rather than binding text that cannot
   read back. */
int shcl_set_float(shcl_doc *d, const char *path, size_t plen, double v) { if (!isfinite(v)) return 0; ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclMark m = arena_mark(a); return w_set_marked(d, p, w_cell1(a, w_float_text(a, v)), m); }
int shcl_set_bool(shcl_doc *d, const char *path, size_t plen, int v) { ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclMark m = arena_mark(a); return w_set_marked(d, p, w_cell1(a, w_bool_text(v)), m); }
int shcl_set_string(shcl_doc *d, const char *path, size_t plen, const char *s, size_t slen) { ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclStr in; in.p = s; in.n = slen; ShclMark m = arena_mark(a); return w_set_marked(d, p, w_cell1(a, s_dup(a, in)), m); }

/* Read text as the value half of a line, for the setters that take value
   syntax rather than data: whatever a file line means with this text is what
   gets stored, so a trailing blank comes off and a `#` outside quotes ends
   the value exactly as they would in a file. What is refused is what a
   file reports as an error, since a setter has no diagnostic to report it
   with: a line break, which no file line can hold, an unterminated quote
   (E017), bracket text (E019, the line kept verbatim - writing it as a
   two-element array holding `[1` and `2]` would be a different wrong answer),
   an unknown escape in double quotes (E023), and a Windows path in double
   quotes holding a \t or \n escape (E024). */
static int literal_value(ShclArena *a, ShclArena *tmp, ShclStr text, ShclValue *out) {
	for (size_t i = 0; i < text.n; i++) { if (text.p[i] == '\n') return 0; }
	/* One copy of the value text up front: the elements slice it, and the
	   caller's buffer need not outlive the call (the setter contract). */
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	ShclStr line = value_half(a, tmp, text, &tok);
	for (size_t i = 0; i < tok.nelem; i++) if (tok.elements[i].quote == SHCL_QUOTE_OPEN) return 0;
	if (tok.value_start < line.n && line.p[tok.value_start] == '[') return 0;
	uint32_t c;
	if (bad_escape(&tok, line, 1, &c) || any_path_like(&tok, line)) return 0;
	*out = cell_of_tokens(a, tmp, &tok, line);
	return 1;
}

int shcl_set_literal(shcl_doc *d, const char *path, size_t plen, const char *text, size_t tlen) {
	ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclStr in; in.p = text; in.n = tlen;
	ShclValue v;
	ShclMark m = arena_mark(a);
	if (!literal_value(a, &d->scratch, in, &v)) { arena_release(a, m); arena_reset(&d->scratch); return 0; }
	return w_set_marked(d, p, v, m);
}
int shcl_set_datetime(shcl_doc *d, const char *path, size_t plen, const shcl_datetime *dt) { if (!dt_reads_back(&d->scratch, dt)) { arena_reset(&d->scratch); return 0; } ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclMark m = arena_mark(a); return w_set_marked(d, p, w_cell1(a, w_dt_text(a, dt)), m); }
// Bind a raw block at a path, picking a fence longer than any content line.
// The info-string is stored as a fence line would read it back (trimmed the
// way the load trims one); one that would not read back whole - it holds a
// line break, or a `#`, which reads as a comment - fails the write, as does a
// body line ending in CR, since the load takes the trailing CR run off every
// line.
int shcl_set_raw(shcl_doc *d, const char *path, size_t plen, const char *content, size_t clen, const char *info, size_t ilen) {
	ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen;
	ShclStr it; it.p = info ? info : ""; it.n = ilen;
	it = s_trim_wsp(it);
	ShclMark m = arena_mark(a);
	ShclStr c = w_dupz(a, content, clen), inf = s_dup(a, it);
	unsigned char fc; size_t fl; w_choose_fence(c, &fc, &fl);
	ShclValue v; memset(&v, 0, sizeof v); v.kind = V_RAW;
	v.raw = (ShclRawVal *)arena_alloc(a, sizeof(ShclRawVal));
	v.raw->content = c; v.raw->info = inf; v.raw->fence_char = fc; v.raw->fence_len = fl;
	return w_set_marked(d, p, v, m);
}

int shcl_set_int_array(shcl_doc *d, const char *path, size_t plen, const int64_t *v, size_t n) {
	ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclMark m = arena_mark(a); ShclStr *t = (ShclStr *)arena_alloc(a, (n ? n : 1) * sizeof(ShclStr));
	for (size_t i = 0; i < n; i++) t[i] = w_int_text(a, v[i]);
	return w_set_marked(d, p, w_array(a, t, n), m);
}
int shcl_set_float_array(shcl_doc *d, const char *path, size_t plen, const double *v, size_t n) {
	for (size_t i = 0; i < n; i++) if (!isfinite(v[i])) return 0;
	ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclMark m = arena_mark(a); ShclStr *t = (ShclStr *)arena_alloc(a, (n ? n : 1) * sizeof(ShclStr));
	for (size_t i = 0; i < n; i++) t[i] = w_float_text(a, v[i]);
	return w_set_marked(d, p, w_array(a, t, n), m);
}
int shcl_set_bool_array(shcl_doc *d, const char *path, size_t plen, const int *v, size_t n) {
	ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclMark m = arena_mark(a); ShclStr *t = (ShclStr *)arena_alloc(a, (n ? n : 1) * sizeof(ShclStr));
	for (size_t i = 0; i < n; i++) t[i] = w_bool_text(v[i]);
	return w_set_marked(d, p, w_array(a, t, n), m);
}
int shcl_set_string_array(shcl_doc *d, const char *path, size_t plen, const char *const *v, const size_t *lens, size_t n) {
	ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclMark m = arena_mark(a); ShclStr *t = (ShclStr *)arena_alloc(a, (n ? n : 1) * sizeof(ShclStr));
	for (size_t i = 0; i < n; i++) { ShclStr in; in.p = v[i]; in.n = lens[i]; t[i] = s_dup(a, in); }
	return w_set_marked(d, p, w_array(a, t, n), m);
}
int shcl_set_datetime_array(shcl_doc *d, const char *path, size_t plen, const shcl_datetime *v, size_t n) {
	for (size_t i = 0; i < n; i++) if (!dt_reads_back(&d->scratch, &v[i])) { arena_reset(&d->scratch); return 0; }
	ShclArena *a = &d->arena; ShclStr p; p.p = path; p.n = plen; ShclMark m = arena_mark(a); ShclStr *t = (ShclStr *)arena_alloc(a, (n ? n : 1) * sizeof(ShclStr));
	for (size_t i = 0; i < n; i++) t[i] = w_dt_text(a, &v[i]);
	return w_set_marked(d, p, w_array(a, t, n), m);
}

/* A default form writes only where nothing is yet. Where something is, it
   writes nothing and reports what a write there would: the path's verdict,
   then the value's, which the same setter gives on the probe document. NULL
   means the path alone refuses. */
static shcl_doc *w_default_probe(shcl_doc *d, const char *path, size_t plen) {
	if (shcl_write_reason_(d, path, plen) != SHCL_W_WRITABLE) return NULL;
	if (!d->probe_doc) {
		shcl_doc *e = shcl_new();
		if (!e) { SHCL_OOM(); return NULL; }
		e->probe = 1;
		d->probe_doc = e;
	}
	/* A refused value leaves its working set in scratch, and nothing else
	   ever resets a probe's. */
	arena_reset_smallest(&d->probe_doc->scratch);
	return d->probe_doc;
}
int shcl_set_int_default(shcl_doc *d, const char *path, size_t plen, int64_t v) { if (!shcl_exists(d, path, plen)) return shcl_set_int(d, path, plen, v); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_int(e, "v", 1, v); }
int shcl_set_float_default(shcl_doc *d, const char *path, size_t plen, double v) { if (!shcl_exists(d, path, plen)) return shcl_set_float(d, path, plen, v); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_float(e, "v", 1, v); }
int shcl_set_bool_default(shcl_doc *d, const char *path, size_t plen, int v) { if (!shcl_exists(d, path, plen)) return shcl_set_bool(d, path, plen, v); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_bool(e, "v", 1, v); }
int shcl_set_string_default(shcl_doc *d, const char *path, size_t plen, const char *s, size_t slen) { if (!shcl_exists(d, path, plen)) return shcl_set_string(d, path, plen, s, slen); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_string(e, "v", 1, s, slen); }
int shcl_set_literal_default(shcl_doc *d, const char *path, size_t plen, const char *text, size_t tlen) { if (!shcl_exists(d, path, plen)) return shcl_set_literal(d, path, plen, text, tlen); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_literal(e, "v", 1, text, tlen); }
int shcl_set_datetime_default(shcl_doc *d, const char *path, size_t plen, const shcl_datetime *dt) { if (!shcl_exists(d, path, plen)) return shcl_set_datetime(d, path, plen, dt); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_datetime(e, "v", 1, dt); }
int shcl_set_raw_default(shcl_doc *d, const char *path, size_t plen, const char *content, size_t clen, const char *info, size_t ilen) { if (!shcl_exists(d, path, plen)) return shcl_set_raw(d, path, plen, content, clen, info, ilen); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_raw(e, "v", 1, content, clen, info, ilen); }
int shcl_set_int_array_default(shcl_doc *d, const char *path, size_t plen, const int64_t *v, size_t n) { if (!shcl_exists(d, path, plen)) return shcl_set_int_array(d, path, plen, v, n); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_int_array(e, "v", 1, v, n); }
int shcl_set_float_array_default(shcl_doc *d, const char *path, size_t plen, const double *v, size_t n) { if (!shcl_exists(d, path, plen)) return shcl_set_float_array(d, path, plen, v, n); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_float_array(e, "v", 1, v, n); }
int shcl_set_bool_array_default(shcl_doc *d, const char *path, size_t plen, const int *v, size_t n) { if (!shcl_exists(d, path, plen)) return shcl_set_bool_array(d, path, plen, v, n); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_bool_array(e, "v", 1, v, n); }
int shcl_set_string_array_default(shcl_doc *d, const char *path, size_t plen, const char *const *v, const size_t *lens, size_t n) { if (!shcl_exists(d, path, plen)) return shcl_set_string_array(d, path, plen, v, lens, n); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_string_array(e, "v", 1, v, lens, n); }
int shcl_set_datetime_array_default(shcl_doc *d, const char *path, size_t plen, const shcl_datetime *v, size_t n) { if (!shcl_exists(d, path, plen)) return shcl_set_datetime_array(d, path, plen, v, n); shcl_doc *e = w_default_probe(d, path, plen); return e && shcl_set_datetime_array(e, "v", 1, v, n); }

// --- Layered loading: overlay a higher-priority document onto a lower one ----

// Deep-copy a value from `over`'s arena into `d`'s, so the merged doc is
// self-contained (over may be freed after the merge).
static ShclValue w_dup_value(ShclArena *a, const ShclValue *v) {
	ShclValue r; memset(&r, 0, sizeof r); r.kind = v->kind;
	if (v->kind == V_CELL) {
		r.nels = v->nels;
		r.els = (ShclElement *)arena_alloc(a, (v->nels ? v->nels : 1) * sizeof(ShclElement));
		for (size_t i = 0; i < v->nels; i++) { r.els[i].text = s_dup(a, v->els[i].text); r.els[i].quoted = v->els[i].quoted; }
	} else if (v->kind == V_RAW) {
		r.raw = (ShclRawVal *)arena_alloc(a, sizeof(ShclRawVal));
		r.raw->content = s_dup(a, v->raw->content); r.raw->info = s_dup(a, v->raw->info);
		r.raw->fence_char = v->raw->fence_char; r.raw->fence_len = v->raw->fence_len;
	}
	return r;
}

// Deep-copy over's subtree at `oi` into d's arena under `parent`. d->nodes may
// reallocate on push, so parent's children vec is fetched only via NODE().
static ShclTrivia *w_clone_trivia(ShclArena *a, const ShclTrivia *st) {
	ShclTrivia *nt = (ShclTrivia *)arena_alloc(a, sizeof(ShclTrivia));
	memset(nt, 0, sizeof(ShclTrivia));
	nt->trailing = s_dup(a, st->trailing);
	for (size_t i = 0; i < st->leading.len; i++) ShclVecLead_push(a, &nt->leading, lead_copy(a, &st->leading.data[i]));
	for (size_t i = 0; i < st->after.len; i++) ShclVecLead_push(a, &nt->after, lead_copy(a, &st->after.data[i]));
	for (size_t i = 0; i < st->inside.len; i++) ShclVecLead_push(a, &nt->inside, lead_copy(a, &st->inside.data[i]));
	for (size_t i = 0; i < st->among.len; i++) {
		ShclAmong am; am.before = st->among.data[i].before;
		am.lead = lead_copy(a, &st->among.data[i].lead);
		ShclVecAmong_push(a, &nt->among, am);
	}
	return nt;
}
static size_t w_clone_subtree(shcl_doc *d, const shcl_doc *over, size_t oi, size_t parent) {
	ShclArena *a = &d->arena;
	const ShclNode *src = &over->nodes.data[oi];
	ShclNode n; memset(&n, 0, sizeof n);
	n.name = s_dup(a, src->name);
	n.name_src = s_dup(a, src->name_src);
	n.value = w_dup_value(a, &src->value);
	n.parent = parent;
	n.line = src->line;
	n.star_list = src->star_list;
	n.star_mixed = src->star_mixed;
	n.blank_before = src->blank_before;
	if (src->trivia) n.trivia = w_clone_trivia(a, src->trivia);
	size_t idx = d->nodes.len;
	nodes_push(d, n);
	// Snapshot the source children (const, stable) before recursing.
	size_t nk = over->nodes.data[oi].children.len;
	for (size_t i = 0; i < nk; i++) {
		size_t ok = over->nodes.data[oi].children.data[i];
		size_t c = w_clone_subtree(d, over, ok, idx);
		ShclVecSize_push(a, &NODE(d, idx).children, c);
	}
	return idx;
}

/* A matched instance keeps the base node, so the over side's comments have to
   move onto it or they are lost. Same rule as an in-file merge: leading
   concatenates in layer order, first trailing wins. Text is dup'd into d's
   arena - over may be freed after the merge. */
static void adopt_trivia(shcl_doc *d, size_t base, const shcl_doc *over, size_t ok) {
	ShclArena *a = &d->arena;
	const ShclTrivia *st = over->nodes.data[ok].trivia;
	if (!st) return;
	ShclTrivia *bt = triv_mut(a, &NODE(d, base));
	for (size_t i = 0; i < st->leading.len; i++)
		ShclVecLead_push(a, &bt->leading, lead_moved(a, &st->leading.data[i]));
	if (st->trailing.n) {
		if (bt->trailing.n == 0) bt->trailing = s_dup(a, st->trailing);
		else ShclVecLead_push(a, &bt->leading, lead_plain(s_dup(a, st->trailing)));
	}
	for (size_t i = 0; i < st->after.len; i++)
		ShclVecLead_push(a, &bt->after, lead_moved(a, &st->after.data[i]));
	for (size_t i = 0; i < st->inside.len; i++)
		ShclVecLead_push(a, &bt->inside, lead_moved(a, &st->inside.data[i]));
	for (size_t i = 0; i < st->among.len; i++) {
		ShclAmong am; am.before = st->among.data[i].before;
		am.lead = lead_moved(a, &st->among.data[i].lead);
		ShclVecAmong_push(a, &bt->among, am);
	}
	among_sort(&bt->among);
}

// One grouping pass over each side, then a single children rebuild: the old
// shape re-filtered the over side per distinct name and re-scanned (and
// re-keyed) the base side per over node - three O(K^2) terms at one parent,
// plus a fresh children vector per replaced name.
static void w_overlay(shcl_doc *d, size_t bp, const shcl_doc *over, size_t op, ShclVecSize *touched) {
	ShclVecSize_push(&d->scratch, touched, bp);
	ShclArena *a = &d->arena;
	ShclArena *t = &d->scratch;
	ShclVecSize okids = over->nodes.data[op].children; // const doc: stable
	// Over side: name -> bucket of child positions, in first-appearance
	// order. Map hits verify against what the entry's value names (hash-only
	// entries store no key).
	ShclVecS order = {0}; ShclVecSize *buckets = NULL; size_t nb = 0, cb = 0;
	ShclCMap group_of; memset(&group_of, 0, sizeof group_of);
	for (size_t i = 0; i < okids.len; i++) {
		size_t k = okids.data[i]; ShclStr nm = over->nodes.data[k].name;
		uint64_t h = cmap_hash(nm, s_empty());
		size_t g = (size_t)-1;
		for (ShclCMapEnt *e = cmap_first(&group_of, h); e; e = cmap_next(e, h))
			if (s_eq(order.data[e->val], nm)) { g = e->val; break; }
		if (g == (size_t)-1) {
			if (nb == cb) { size_t nc = cb ? cb * 2 : 8; buckets = (ShclVecSize *)arena_grow(t, buckets, cb, nc, sizeof(ShclVecSize)); cb = nc; }
			memset(&buckets[nb], 0, sizeof buckets[nb]);
			g = nb++;
			cmap_put(t, &group_of, h, g);
			ShclVecS_push(t, &order, nm);
		}
		ShclVecSize_push(t, &buckets[g], i);
	}
	// Base side, one pass: every child of a name (entries index a posting
	// list, whose first element names it), which names have a container
	// instance, and which child has each (name, merge key). The posting
	// list is what keeps the override arm below off a scan of every base
	// child, which made N overridden leaves quadratic (20260918b item 58).
	ShclVecSize base = {0};
	{ ShclVecSize bk = NODE(d, bp).children; for (size_t i = 0; i < bk.len; i++) ShclVecSize_push(t, &base, bk.data[i]); }
	ShclVecSize *named = NULL; size_t nn = 0, cn = 0;
	ShclCMap by_name, has_cont, by_key;
	memset(&by_name, 0, sizeof by_name); memset(&has_cont, 0, sizeof has_cont); memset(&by_key, 0, sizeof by_key);
	for (size_t i = 0; i < base.len; i++) {
		size_t b = base.data[i]; ShclStr nm = NODE(d, b).name;
		uint64_t hn = cmap_hash(nm, s_empty());
		size_t ni = (size_t)-1;
		for (ShclCMapEnt *e = cmap_first(&by_name, hn); e; e = cmap_next(e, hn))
			if (s_eq(NODE(d, named[e->val].data[0]).name, nm)) { ni = e->val; break; }
		if (ni == (size_t)-1) {
			if (nn == cn) { size_t nc = cn ? cn * 2 : 8; named = (ShclVecSize *)arena_grow(t, named, cn, nc, sizeof(ShclVecSize)); cn = nc; }
			memset(&named[nn], 0, sizeof named[nn]);
			ni = nn++;
			cmap_put(t, &by_name, hn, ni);
		}
		ShclVecSize_push(t, &named[ni], b);
		if (NODE(d, b).children.len > 0) {
			int seenc = 0;
			for (ShclCMapEnt *e = cmap_first(&has_cont, hn); e; e = cmap_next(e, hn))
				if (s_eq(NODE(d, e->val).name, nm)) { seenc = 1; break; }
			if (!seenc) cmap_put(t, &has_cont, hn, b);
		}
		uint64_t hk = merge_hash(nm, &NODE(d, b).value);
		int seenk = 0;
		for (ShclCMapEnt *e = cmap_first(&by_key, hk); e; e = cmap_next(e, hk))
			if (merge_eq(NODE(d, e->val).name, &NODE(d, e->val).value, nm, &NODE(d, b).value)) { seenk = 1; break; }
		if (!seenk) cmap_put(t, &by_key, hk, b);
	}
	// Decide per name. A name whose over-side nodes are all leaves is an
	// override - but only when the base side of the group is leaf-shaped too.
	// Against a base container, a childless over-node is a wrapper mention,
	// not a leaf, so it falls through to the instance merge: a bare section
	// header in a higher layer never wipes the subtree below it. Replaced
	// groups splice in the rebuild; everything appended (unmatched instances,
	// and replaced names base never had) keeps the over file's order, which
	// the per-name pass here would otherwise regroup: app_at is indexed by
	// the over child's position.
	ShclVecSize *rep = (ShclVecSize *)arena_alloc(t, (nb ? nb : 1) * sizeof(ShclVecSize));
	int *is_rep = (int *)arena_alloc(t, (nb ? nb : 1) * sizeof(int));
	size_t *app_at = (size_t *)arena_alloc(t, (okids.len ? okids.len : 1) * sizeof(size_t));
	for (size_t i = 0; i < okids.len; i++) app_at[i] = (size_t)-1;
	size_t nappended = 0;
	int any_rep = 0;
	ShclValue ev; memset(&ev, 0, sizeof ev); ev.kind = V_EMPTY;
	for (size_t gi = 0; gi < nb; gi++) {
		ShclStr name = order.data[gi];
		ShclVecSize grp = buckets[gi];
		memset(&rep[gi], 0, sizeof rep[gi]); is_rep[gi] = 0;
		int over_leafy = 1;
		for (size_t i = 0; i < grp.len; i++) if (over->nodes.data[okids.data[grp.data[i]]].children.len > 0) { over_leafy = 0; break; }
		uint64_t hn = cmap_hash(name, s_empty());
		int inb = 0, bc = 0; size_t bni = (size_t)-1;
		for (ShclCMapEnt *e = cmap_first(&by_name, hn); e; e = cmap_next(e, hn))
			if (s_eq(NODE(d, named[e->val].data[0]).name, name)) { inb = 1; bni = e->val; break; }
		for (ShclCMapEnt *e = cmap_first(&has_cont, hn); e; e = cmap_next(e, hn))
			if (s_eq(NODE(d, e->val).name, name)) { bc = 1; break; }
		if (over_leafy && !bc) {
			for (size_t i = 0; i < grp.len; i++) {
				size_t pos = grp.data[i];
				size_t c = w_clone_subtree(d, over, okids.data[pos], bp);
				if (inb) ShclVecSize_push(t, &rep[gi], c);
				else { app_at[pos] = c; nappended++; }
			}
			if (inb) {
				is_rep[gi] = 1; any_rep = 1;
				/* The replaced leaf's comments go with it, which the spec
				   allows; a content-malformed line retained on it is content
				   the parser promised to keep, so those move onto the
				   replacement. A comment starts with `#`, a retained line
				   never does. The texts already live in the document arena. */
				ShclVecLead kept = {0};
				for (size_t i = 0; i < named[bni].len; i++) {
					size_t b = named[bni].data[i];
					const ShclTrivia *bt = NODE(d, b).trivia;
					if (!bt) continue;
					const ShclVecLead *lists[3] = { &bt->leading, &bt->inside, &bt->after };
					for (size_t li = 0; li < 3; li++) {
						for (size_t k = 0; k < lists[li]->len; k++) {
							if (!(lists[li]->data[k].text.n && lists[li]->data[k].text.p[0] == '#')) ShclVecLead_push(t, &kept, lists[li]->data[k]);
							/* A settled one goes with the leaf's comments
							   (decided 2026-09-28), so it is no longer owed. */
							else if (lists[li]->data[k].kept && d->kept_owed > 0) d->kept_owed--;
						}
						/* The lines among a list's elements come after its leading ones. */
						if (li == 0) {
							for (size_t k = 0; k < bt->among.len; k++) {
								if (!(bt->among.data[k].lead.text.n && bt->among.data[k].lead.text.p[0] == '#')) ShclVecLead_push(t, &kept, bt->among.data[k].lead);
								else if (bt->among.data[k].lead.kept && d->kept_owed > 0) d->kept_owed--;
							}
						}
					}
				}
				if (kept.len) {
					ShclTrivia *ct = triv_mut(a, &NODE(d, rep[gi].data[0]));
					ShclVecLead lead = {0};
					for (size_t k = 0; k < kept.len; k++) ShclVecLead_push(a, &lead, kept.data[k]);
					for (size_t k = 0; k < ct->leading.len; k++) ShclVecLead_push(a, &lead, ct->leading.data[k]);
					ct->leading = lead;
				}
			}
		} else {
			for (size_t i = 0; i < grp.len; i++) {
				size_t pos = grp.data[i];
				size_t ok = okids.data[pos];
				uint64_t hk = merge_hash(name, &over->nodes.data[ok].value);
				size_t b = (size_t)-1;
				for (ShclCMapEnt *e = cmap_first(&by_key, hk); e; e = cmap_next(e, hk))
					if (merge_eq(NODE(d, e->val).name, &NODE(d, e->val).value, name, &over->nodes.data[ok].value)) { b = e->val; break; }
				/* A raw block in the higher layer fills a same-named empty binding
				   below, exactly as a fence line fills one inside a single file.
				   Without it, merging two documents and parsing them run together
				   disagree: both bindings survive here and fold there, so the
				   merged output is not a formatter fixpoint. */
				if (b == (size_t)-1 && over->nodes.data[ok].value.kind == V_RAW) {
					uint64_t he = merge_hash(name, &ev);
					size_t emt = (size_t)-1;
					for (ShclCMapEnt *e = cmap_first(&by_key, he); e; e = cmap_next(e, he))
						if (merge_eq(NODE(d, e->val).name, &NODE(d, e->val).value, name, &ev)) { emt = e->val; break; }
					if (emt != (size_t)-1) {
						NODE(d, emt).value = w_dup_value(a, &over->nodes.data[ok].value);
						cmap_del(&by_key, he, emt);
						int seenk = 0;
						for (ShclCMapEnt *e = cmap_first(&by_key, hk); e; e = cmap_next(e, hk))
							if (merge_eq(NODE(d, e->val).name, &NODE(d, e->val).value, name, &over->nodes.data[ok].value)) { seenk = 1; break; }
						if (!seenk) cmap_put(t, &by_key, hk, emt);
						b = emt;
					}
				}
				if (b != (size_t)-1) {
					/* A stacked spelling no kept line holds is gone on a
					   reload, so it may not decide how the lines the other
					   layer brings are written (20260926 item 4). */
					int stacked = stacks(&NODE(d, b)) || stacks(&over->nodes.data[ok]);
					adopt_trivia(d, b, over, ok);
					NODE(d, b).star_list = stacked;
					w_overlay(d, b, over, ok, touched);
				}
				else { app_at[pos] = w_clone_subtree(d, over, ok, bp); nappended++; }
			}
		}
	}
	if (!any_rep && nappended == 0) return;
	// Rebuild once: each replaced group goes to its name's first original
	// position (dropped nodes stay in the arena, unreferenced - reads and
	// emit walk children from the root), appends go at the end. One splice
	// per group, flagged on the group itself.
	int *spliced = (int *)arena_alloc(t, (nb ? nb : 1) * sizeof(int));
	for (size_t gi = 0; gi < nb; gi++) spliced[gi] = 0;
	/* Built in scratch and copied out exactly sized below: a builder growing in
	   the document arena abandons its doubling chain there, which cost about a
	   megabyte per merge on a 40000-child parent. */
	ShclVecSize nw = {0};
	for (size_t i = 0; i < base.len; i++) {
		size_t b = base.data[i]; ShclStr nm = NODE(d, b).name;
		uint64_t hn = cmap_hash(nm, s_empty());
		size_t g = (size_t)-1;
		for (ShclCMapEnt *e = cmap_first(&group_of, hn); e; e = cmap_next(e, hn))
			if (s_eq(order.data[e->val], nm)) { g = e->val; break; }
		if (g != (size_t)-1 && is_rep[g]) {
			if (!spliced[g]) {
				spliced[g] = 1;
				for (size_t k = 0; k < rep[g].len; k++) ShclVecSize_push(t, &nw, rep[g].data[k]);
			}
		} else {
			ShclVecSize_push(t, &nw, b);
		}
	}
	for (size_t k = 0; k < okids.len; k++) if (app_at[k] != (size_t)-1) ShclVecSize_push(t, &nw, app_at[k]);
	/* Into the parent's own array when it fits, which a leaf override always
	   does: an exact-sized copy per merge abandoned the whole list in the
	   document arena each time - 420 KB per merge on a 40000-key parent, where
	   the spec promises about a megabyte for five hundred. Appends that outgrow
	   it get room to double, so a stack of them amortizes. */
	ShclVecSize kept = NODE(d, bp).children;
	if (!kept.data || nw.len > kept.cap) {
		kept.cap = nw.len ? nw.len * 2 : 1;
		kept.data = (size_t *)arena_alloc(a, kept.cap * sizeof(size_t));
	}
	for (size_t k = 0; k < nw.len; k++) kept.data[k] = nw.data[k];
	kept.len = nw.len;
	NODE(d, bp).children = kept;
}

void shcl_merge(shcl_doc *d, const shcl_doc *over) {
	// The walk reads over while it writes d, so the same document on both sides
	// grew until SHCL_OOM.
	if (over == d) return;
	index_drop(d);
	d->has_source = 0;
	d->lost += over->lost;
	d->kept_owed += over->kept_owed;
	/* The layer's own kept lines were modeled against its own tree. */
	int fresh = over->kept;
	d->kept |= over->kept;
	ShclArena *a = &d->arena;
	arena_reset(&d->scratch); // merge temporaries (compare keys, clone lists) die here
	/* Only a block the overlay visited can have a changed child list or
	   comments; the rest was settled when it was built. Settling the whole tree
	   made every merge cost the document (20260924 item 6). A block's settle
	   writes only below it, so the order does not matter. */
	ShclVecSize touched = {0};
	w_overlay(d, ROOT, over, ROOT, &touched);
	for (size_t k = 0; k < touched.len; k++) settle_block(d, touched.data[k], 1);
	// Layers commonly share a footer; keeping one copy of each keeps a stack
	// of files from repeating it once per layer. Only the lines already here
	// count: a layer's own repeats are its content.
	size_t had = d->orphans.len;
	/* A repeat skipped here may be the comment the next one sat under, and a
	   reload puts a comment at most one level past the comment before it, so
	   none goes deeper than that. */
	size_t room = 0;
	for (size_t k = had; k-- > 0;) if (d->orphans.data[k].text.n && d->orphans.data[k].text.p[0] == '#') { room = d->orphans.data[k].depth + 1; break; }
	for (size_t i = 0; i < over->orphans.len; i++) {
		ShclStr ot = over->orphans.data[i].text;
		size_t depth = over->orphans.data[i].depth;
		/* A kept line with kept lines under it goes in whole, so none of them
		   lands under some other line. */
		int whole = 0;
		if (is_field(ot)) {
			size_t prev = i, next = i + 1;
			while (prev > 0 && !is_field(over->orphans.data[prev - 1].text)) prev--;
			while (next < over->orphans.len && !is_field(over->orphans.data[next].text)) next++;
			whole = (depth > 0 && prev > 0) || (next < over->orphans.len && over->orphans.data[next].depth > 0);
		}
		int dup = 0;
		for (size_t k = 0; k < had && !whole; k++) if (s_eq(d->orphans.data[k].text, ot) && d->orphans.data[k].depth == depth) { dup = 1; break; }
		if (dup) {
			/* The table lets the dedup skip a footer line the base has. */
			if (lead_is_kept_line(&over->orphans.data[i]) && d->kept_owed > 0) d->kept_owed--;
			continue;
		}
		if (ot.n && ot.p[0] == '#') { if (depth > room) depth = room; room = depth + 1; }
		ShclLead o = lead_moved(a, &over->orphans.data[i]);
		o.depth = depth;
		ShclVecLead_push(a, &d->orphans, o);
	}
	settle_first_blank(d);
	if (fresh) settle_kept(d);
	else resettle_kept(d);
}

int64_t shcl_get_int(shcl_doc *d, const char *path, size_t plen, int64_t def) {
	shcl_read_i64 r = shcl_read_int(d, path, plen); return r.status == SHCL_GOOD ? r.value : def;
}
double shcl_get_float(shcl_doc *d, const char *path, size_t plen, double def) {
	shcl_read_f64 r = shcl_read_float(d, path, plen); return r.status == SHCL_GOOD ? r.value : def;
}
int shcl_get_bool(shcl_doc *d, const char *path, size_t plen, int def) {
	shcl_read_bool r = shcl_read_bool_(d, path, plen); return r.status == SHCL_GOOD ? r.value : def;
}
int64_t shcl_get_int_or(shcl_doc *d, const char *path, size_t plen, int64_t def) {
	return shcl_get_int(d, path, plen, def);
}
double shcl_get_float_or(shcl_doc *d, const char *path, size_t plen, double def) {
	return shcl_get_float(d, path, plen, def);
}
int shcl_get_bool_or(shcl_doc *d, const char *path, size_t plen, int def) {
	return shcl_get_bool(d, path, plen, def);
}

shcl_read_i64 shcl_read_int(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_i64 R; ShclStr p; p.p = path; p.n = plen; ShclElement *el; shcl_status st = scalar_at(d, p, &el);
	if (st != SHCL_GOOD) { R.value = 0; R.status = st; return R; }
	int64_t v; if (parse_int_text(&d->scratch, el, d->strictness, &v)) { R.value = v; R.status = SHCL_GOOD; }
	else { R.value = 0; R.status = SHCL_BAD_TYPE; }
	return R;
}
shcl_read_f64 shcl_read_float(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_f64 R; ShclStr p; p.p = path; p.n = plen; ShclElement *el; shcl_status st = scalar_at(d, p, &el);
	if (st != SHCL_GOOD) { R.value = 0; R.status = st; return R; }
	double v; if (parse_float_text(&d->scratch, el, d->strictness, &v)) { R.value = v; R.status = SHCL_GOOD; }
	else { R.value = 0; R.status = SHCL_BAD_TYPE; }
	return R;
}
shcl_read_bool shcl_read_bool_(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_bool R; ShclStr p; p.p = path; p.n = plen; ShclElement *el; shcl_status st = scalar_at(d, p, &el);
	if (st != SHCL_GOOD) { R.value = 0; R.status = st; return R; }
	int v; if (parse_bool_text(&d->scratch, el->text, d->strictness, &v)) { R.value = v; R.status = SHCL_GOOD; }
	else { R.value = 0; R.status = SHCL_BAD_TYPE; }
	return R;
}
shcl_read_dt shcl_read_datetime(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_dt R; ShclStr p; p.p = path; p.n = plen; ShclElement *el; shcl_status st = scalar_at(d, p, &el);
	memset(&R.value, 0, sizeof R.value); R.value.zone = SHCL_ZONE_NONE;
	if (st != SHCL_GOOD) { R.status = st; return R; }
	// scratch, not the doc arena: parse_datetime only allocates split temporaries
	// there, and the frac it hands back slices el->text, which outlives the call.
	if (parse_datetime(&d->scratch, el->text, &R.value)) R.status = SHCL_GOOD;
	else { memset(&R.value, 0, sizeof R.value); R.value.zone = SHCL_ZONE_NONE; R.status = SHCL_BAD_TYPE; }
	return R;
}
/* scalar_at with the node's name, for the reads whose bare number takes its
   unit from the name. */
static shcl_status scalar_named_at(shcl_doc *d, ShclStr path, ShclElement **el, ShclStr *name) {
	ShclResolved r;
	*el = NULL;
	if (!resolve(d, path, &r) || r.kind == R_NONE) return SHCL_NOT_FOUND;
	if (r.kind == R_MANY || r.kind == R_SLOTS) return SHCL_MULTIPLE;
	ShclValue *v = &NODE(d, r.one).value;
	*name = NODE(d, r.one).name;
	if (v->kind == V_EMPTY) return SHCL_EMPTY;
	if (v->kind == V_RAW || v->nels != 1) return SHCL_BAD_TYPE;
	*el = &v->els[0]; return SHCL_GOOD;
}
shcl_read_i64 shcl_read_duration(shcl_doc *d, const char *path, size_t plen, shcl_duration_unit unit) {
	shcl_read_i64 R; ShclStr p; p.p = path; p.n = plen; ShclElement *el; ShclStr name = s_empty();
	shcl_status st = scalar_named_at(d, p, &el, &name);
	R.value = 0;
	if (st != SHCL_GOOD) { R.status = st; return R; }
	shcl_duration_unit bare = name_duration_unit(name);
	if (bare == SHCL_DURATION_NONE) bare = unit;
	unsigned units; shcl_duration_unit first;
	R.status = parse_duration_text(el->text, bare, &R.value, &units, &first) ? SHCL_GOOD : SHCL_BAD_TYPE;
	if (R.status != SHCL_GOOD) R.value = 0;
	return R;
}
shcl_read_i64 shcl_read_size(shcl_doc *d, const char *path, size_t plen, shcl_size_unit unit, int decimal) {
	shcl_read_i64 R; ShclStr p; p.p = path; p.n = plen; ShclElement *el; ShclStr name = s_empty();
	shcl_status st = scalar_named_at(d, p, &el, &name);
	R.value = 0;
	if (st != SHCL_GOOD) { R.status = st; return R; }
	shcl_size_unit bare = name_size_unit(name), vu;
	if (bare == SHCL_SIZE_NONE) bare = unit;
	R.status = parse_size_text(el->text, bare, decimal, &R.value, &vu) ? SHCL_GOOD : SHCL_BAD_TYPE;
	if (R.status != SHCL_GOOD) R.value = 0;
	return R;
}
int64_t shcl_get_duration_or(shcl_doc *d, const char *path, size_t plen, shcl_duration_unit unit, int64_t def) {
	shcl_read_i64 r = shcl_read_duration(d, path, plen, unit); return r.status == SHCL_GOOD ? r.value : def;
}
int64_t shcl_get_size_or(shcl_doc *d, const char *path, size_t plen, shcl_size_unit unit, int decimal, int64_t def) {
	shcl_read_i64 r = shcl_read_size(d, path, plen, unit, decimal); return r.status == SHCL_GOOD ? r.value : def;
}
static ShclStr emit_element(ShclArena *a, const ShclElement *e);

shcl_read_str shcl_read_string(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_str R; ShclStr p; p.p = path; p.n = plen; ShclValue *v; shcl_status st = value_at(d, p, &v);
	if (st != SHCL_GOOD) { R.value = s_empty(); R.status = st; return R; }
	if (v->kind == V_EMPTY) { R.value = s_empty(); R.status = SHCL_EMPTY; }
	else if (v->kind == V_RAW) { R.value = v->raw->content; R.status = SHCL_GOOD; }
	else if (v->nels == 1) { R.value = v->els[0].text; R.status = SHCL_GOOD; }
	else {
		/* Canonical inline form (quoting + escapes intact), so the string
		   re-parses to the same array - not the bare display join. */
		ShclArena *a = &d->reads; ShclSB s = {0};
		for (size_t i = 0; i < v->nels; i++) { if (i) sb_puts(a, &s, ", "); sb_putS(a, &s, emit_element(a, &v->els[i])); }
		R.value = sb_S(&s); R.status = SHCL_GOOD;
	}
	return R;
}
shcl_read_str shcl_read_raw(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_str R; ShclStr p; p.p = path; p.n = plen; ShclValue *v; shcl_status st = value_at(d, p, &v);
	R.value = s_empty(); R.status = st;
	if (st != SHCL_GOOD) return R;
	switch (v->kind) {
	case V_RAW: R.value = v->raw->content; break;
	case V_EMPTY: R.status = SHCL_EMPTY; break;
	case V_CELL: R.status = SHCL_BAD_TYPE; break;
	}
	return R;
}
shcl_read_str shcl_read_raw_info(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_str R; ShclStr p; p.p = path; p.n = plen; ShclValue *v; shcl_status st = value_at(d, p, &v);
	if (st != SHCL_GOOD) { R.value = s_empty(); R.status = st; return R; }
	/* An empty binding has no block, so no info string: `Empty`, the same as a `read_raw` on it. Only a value that is there and is not a block is a type mismatch. */
	if (v->kind == V_RAW) { R.value = v->raw->info; R.status = SHCL_GOOD; }
	else if (v->kind == V_EMPTY) { R.value = s_empty(); R.status = SHCL_EMPTY; }
	else { R.value = s_empty(); R.status = SHCL_BAD_TYPE; }
	return R;
}

static shcl_read_i64_arr read_int_array_in(shcl_doc *d, ShclArena *a, ShclStr p) {
	shcl_read_i64_arr R; ShclElement **els; shcl_status *sts; size_t n;
	shcl_status st = array_elements(d, a, p, &els, &sts, &n);
	if (st != SHCL_GOOD && st != SHCL_EMPTY) { R.values = NULL; R.n = 0; R.status = st; R.statuses = NULL; return R; }
	int64_t *out = (int64_t *)arena_alloc(a, (n ? n : 1) * sizeof(int64_t));
	for (size_t i = 0; i < n; i++) { int64_t v; if (els[i] && parse_int_text(&d->scratch, els[i], d->strictness, &v)) out[i] = v; else { out[i] = 0; if (els[i]) sts[i] = SHCL_BAD_TYPE; } }
	R.values = out; R.n = n; R.status = worst_slot(sts, n, st); R.statuses = sts; return R;
}
shcl_read_i64_arr shcl_read_int_array(shcl_doc *d, const char *path, size_t plen) {
	ShclStr p; p.p = path; p.n = plen;
	return read_int_array_in(d, &d->reads, p);
}
shcl_read_f64_arr shcl_read_float_array(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_f64_arr R; ShclStr p; p.p = path; p.n = plen; ShclElement **els; shcl_status *sts; size_t n;
	shcl_status st = array_elements(d, &d->reads, p, &els, &sts, &n);
	if (st != SHCL_GOOD && st != SHCL_EMPTY) { R.values = NULL; R.n = 0; R.status = st; R.statuses = NULL; return R; }
	double *out = (double *)arena_alloc(&d->reads, (n ? n : 1) * sizeof(double));
	for (size_t i = 0; i < n; i++) { double v; if (els[i] && parse_float_text(&d->scratch, els[i], d->strictness, &v)) out[i] = v; else { out[i] = 0; if (els[i]) sts[i] = SHCL_BAD_TYPE; } }
	R.values = out; R.n = n; R.status = worst_slot(sts, n, st); R.statuses = sts; return R;
}
shcl_read_bool_arr shcl_read_bool_array(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_bool_arr R; ShclStr p; p.p = path; p.n = plen; ShclElement **els; shcl_status *sts; size_t n;
	shcl_status st = array_elements(d, &d->reads, p, &els, &sts, &n);
	if (st != SHCL_GOOD && st != SHCL_EMPTY) { R.values = NULL; R.n = 0; R.status = st; R.statuses = NULL; return R; }
	int *out = (int *)arena_alloc(&d->reads, (n ? n : 1) * sizeof(int));
	for (size_t i = 0; i < n; i++) { int v; if (els[i] && parse_bool_text(&d->scratch, els[i]->text, d->strictness, &v)) out[i] = v; else { out[i] = 0; if (els[i]) sts[i] = SHCL_BAD_TYPE; } }
	R.values = out; R.n = n; R.status = worst_slot(sts, n, st); R.statuses = sts; return R;
}
shcl_read_dt_arr shcl_read_datetime_array(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_dt_arr R; ShclStr p; p.p = path; p.n = plen; ShclElement **els; shcl_status *sts; size_t n;
	shcl_status st = array_elements(d, &d->reads, p, &els, &sts, &n);
	if (st != SHCL_GOOD && st != SHCL_EMPTY) { R.values = NULL; R.n = 0; R.status = st; R.statuses = NULL; return R; }
	shcl_datetime *out = (shcl_datetime *)arena_alloc(&d->reads, (n ? n : 1) * sizeof(shcl_datetime));
	for (size_t i = 0; i < n; i++) {
		memset(&out[i], 0, sizeof out[i]); out[i].zone = SHCL_ZONE_NONE;
		if (els[i]) { if (!parse_datetime(&d->scratch, els[i]->text, &out[i])) { memset(&out[i], 0, sizeof out[i]); out[i].zone = SHCL_ZONE_NONE; sts[i] = SHCL_BAD_TYPE; } }
	}
	R.values = out; R.n = n; R.status = worst_slot(sts, n, st); R.statuses = sts; return R;
}
shcl_read_str_arr shcl_read_string_array(shcl_doc *d, const char *path, size_t plen) {
	shcl_read_str_arr R; ShclStr p; p.p = path; p.n = plen; ShclElement **els; shcl_status *sts; size_t n;
	shcl_status st = array_elements(d, &d->reads, p, &els, &sts, &n);
	if (st != SHCL_GOOD && st != SHCL_EMPTY) { R.values = NULL; R.n = 0; R.status = st; R.statuses = NULL; return R; }
	shcl_str *out = (shcl_str *)arena_alloc(&d->reads, (n ? n : 1) * sizeof(shcl_str));
	for (size_t i = 0; i < n; i++) out[i] = els[i] ? els[i]->text : s_empty();
	R.values = out; R.n = n; R.status = worst_slot(sts, n, st); R.statuses = sts; return R;
}

shcl_status shcl_read_string_to(shcl_doc *d, const char *path, size_t plen, char *buf, size_t cap, size_t *len) {
	ShclMark m = arena_mark(&d->reads);
	shcl_read_str r = shcl_read_string(d, path, plen);
	if (len) *len = r.value.n;
	if (buf && cap) {
		size_t k = r.value.n < cap - 1 ? r.value.n : cap - 1;
		if (k) memcpy(buf, r.value.p, k);
		buf[k] = '\0';
	}
	arena_release(&d->reads, m);
	return r.status;
}

/* The shared tail of the array forms: copy what fits, then give the read
   arena back to the mark taken before the read. */
static shcl_status read_copied(shcl_doc *d, ShclMark m, const void *vals, const shcl_status *sts, size_t count, shcl_status st, void *out, size_t size, shcl_status *slots, size_t cap, size_t *n) {
	size_t k = count < cap ? count : cap;
	if (k && out && vals) memcpy(out, vals, k * size);
	if (k && slots && sts) memcpy(slots, sts, k * sizeof *slots);
	if (n) *n = count;
	arena_release(&d->reads, m);
	return st;
}
shcl_status shcl_read_int_array_to(shcl_doc *d, const char *path, size_t plen, int64_t *out, shcl_status *slots, size_t cap, size_t *n) {
	ShclMark m = arena_mark(&d->reads); shcl_read_i64_arr r = shcl_read_int_array(d, path, plen);
	return read_copied(d, m, r.values, r.statuses, r.n, r.status, out, sizeof *out, slots, cap, n);
}
shcl_status shcl_read_float_array_to(shcl_doc *d, const char *path, size_t plen, double *out, shcl_status *slots, size_t cap, size_t *n) {
	ShclMark m = arena_mark(&d->reads); shcl_read_f64_arr r = shcl_read_float_array(d, path, plen);
	return read_copied(d, m, r.values, r.statuses, r.n, r.status, out, sizeof *out, slots, cap, n);
}
shcl_status shcl_read_bool_array_to(shcl_doc *d, const char *path, size_t plen, int *out, shcl_status *slots, size_t cap, size_t *n) {
	ShclMark m = arena_mark(&d->reads); shcl_read_bool_arr r = shcl_read_bool_array(d, path, plen);
	return read_copied(d, m, r.values, r.statuses, r.n, r.status, out, sizeof *out, slots, cap, n);
}
shcl_status shcl_read_datetime_array_to(shcl_doc *d, const char *path, size_t plen, shcl_datetime *out, shcl_status *slots, size_t cap, size_t *n) {
	ShclMark m = arena_mark(&d->reads); shcl_read_dt_arr r = shcl_read_datetime_array(d, path, plen);
	return read_copied(d, m, r.values, r.statuses, r.n, r.status, out, sizeof *out, slots, cap, n);
}
shcl_status shcl_read_string_array_to(shcl_doc *d, const char *path, size_t plen, shcl_str *out, shcl_status *slots, size_t cap, size_t *n) {
	ShclMark m = arena_mark(&d->reads); shcl_read_str_arr r = shcl_read_string_array(d, path, plen);
	return read_copied(d, m, r.values, r.statuses, r.n, r.status, out, sizeof *out, slots, cap, n);
}

// --- formatter (canonical output) -------------------------------------------

/* Quote a logical string so the tokenizer reads it back as the same string.
   Single quotes are literal, so they are the spelling for text holding a
   double quote or a backslash; double quotes have the escapes, so they are
   the spelling for a line break, a tab, an invisible character, or text
   holding both quote kinds. */
static ShclStr quote_text(ShclArena *a, ShclStr t) { return quote_text_as(a, t, SHCL_RULES_CURRENT); }
/* quote_text for a reader of rules, as in quote_double_as. */
static ShclStr quote_text_as(ShclArena *a, ShclStr t, shcl_rules rules) {
	int control = memchr(t.p, '\n', t.n) || memchr(t.p, '\t', t.n);
	for (size_t i = 0; !control && rules == SHCL_RULES_CURRENT && i < t.n; i++) { uint32_t cp; control = invisible_at(t, i, &cp) != 0; }
	ShclSB s = {0};
	if (!control && !memchr(t.p, '\'', t.n) && (memchr(t.p, '"', t.n) || memchr(t.p, '\\', t.n))) {
		sb_putc(a, &s, '\''); sb_putS(a, &s, t); sb_putc(a, &s, '\'');
		return sb_S(&s);
	}
	return quote_double_as(a, t, rules);
}

/* The double-quoted spelling for a reader of rules. The two read it alike,
   except a \u escape, which 2.x kept as written, so for 2.x an invisible
   character goes in as it is. */
static ShclStr quote_double_with(ShclArena *a, ShclStr t, shcl_rules rules, int path);
static ShclStr quote_double_as(ShclArena *a, ShclStr t, shcl_rules rules) {
	ShclStr out = quote_double_with(a, t, rules, 0);
	/* Written \t or \n, a path is E024 on the reload, and a \u escape reads
	   the same. 2.x kept one as written, so for 2.x a tab goes in as it is, and
	   a line break has no spelling: migrate counts that one lost. */
	if (spells_path_escape(out)) return quote_double_with(a, t, rules, 1);
	return out;
}

static ShclStr quote_double_with(ShclArena *a, ShclStr t, shcl_rules rules, int path) {
	ShclSB s = {0};
	sb_reserve(a, &s, t.n + 2);
	sb_putc(a, &s, '"');
	for (size_t i = 0; i < t.n; i++) {
		char c = t.p[i]; uint32_t cp; size_t l;
		if (c == '\\') sb_puts(a, &s, "\\\\");
		else if (c == '"') sb_puts(a, &s, "\\\"");
		else if ((c == '\n' || c == '\t') && path && rules == SHCL_RULES_CURRENT) sb_put_unicode_escape(a, &s, (uint32_t)c);
		else if (c == '\t' && path) sb_putc(a, &s, c);
		else if (c == '\n') sb_puts(a, &s, "\\n");
		else if (c == '\t') sb_puts(a, &s, "\\t");
		else if (rules == SHCL_RULES_CURRENT && (l = invisible_at(t, i, &cp)) != 0) { sb_put_unicode_escape(a, &s, cp); i += l - 1; }
		else sb_putc(a, &s, c);
	}
	sb_putc(a, &s, '"');
	return sb_S(&s);
}
// leading_zero: a zero followed by another digit, after any sign: `007`,
// `-012`, `00.5`.
static int leading_zero(ShclStr t) {
	if (t.n && (t.p[0] == '+' || t.p[0] == '-')) { t.p++; t.n--; }
	return t.n > 1 && t.p[0] == '0' && t.p[1] >= '0' && t.p[1] <= '9';
}
// is_data_format: true when the text reads as an int, float, bool, or datetime
// at standard strictness - fixed there deliberately, so canonical form cannot
// vary with the load strictness. A number with a leading zero does not count:
// quotes are how a file says the zeros matter, as in a zip code.
// One pass over the bytes before any coercion. At Standard the int, float and
// datetime forms all require at least one ASCII digit; the only formats that do
// not are the boolean words, and the longest of those is "false". An ordinary
// quoted string fails both tests, so emit stops running four full coercions on
// every quoted element it writes.
static int is_data_format(ShclArena *a, const ShclElement *e) {
	int64_t iv; double fv; int bv; shcl_datetime dv;
	int has_digit = 0;
	for (size_t i = 0; i < e->text.n; i++) if (e->text.p[i] >= '0' && e->text.p[i] <= '9') { has_digit = 1; break; }
	if (!has_digit) {
		ShclStr t = s_trim(e->text);
		return t.n <= 5 && parse_bool_text(a, t, SHCL_STANDARD, &bv);
	}
	if (!leading_zero(s_trim(e->text))) {
		if (parse_int_text(a, e, SHCL_STANDARD, &iv)) return 1;
		if (parse_float_text(a, e, SHCL_STANDARD, &fv)) return 1;
	}
	if (parse_bool_text(a, e->text, SHCL_STANDARD, &bv)) return 1;
	if (parse_datetime(a, e->text, &dv)) return 1;
	return 0;
}
// Minimal quoting: bare unless a reserved character (or lookalike hazard) forces it.
static int needs_quotes(ShclStr t) {
	int needs = (t.n == 0);
	if (!needs) {
		size_t i = 0;
		while (i < t.n) { uint32_t c; size_t l = utf8_decode(t.p, t.n, i, &c);
			if (c == ' ' || c == '\t' || c == '\n' || c == ',' || c == ':' || c == '#' || c == '"' || c == '\'' || c == '[' || c == ']') { needs = 1; break; }
			if (invisible_at(t, i, &c)) { needs = 1; break; }
			i += l; }
	}
	/* Edge whitespace still has to force quotes, for the carriage return: it is
	   a blank, so a piece ending in one loses it to the reload. Space and tab
	   are already in the list above. The test is the whole Unicode whitespace
	   set rather than those three, which only ever adds quoting - the parser
	   itself trims no wider than is_wsp, so a leading no-break space is
	   content. Edges only: interior whitespace is never trimmed and quoting it
	   would move bytes. */
	if (!needs && t.n) {
		uint32_t f, l; utf8_decode(t.p, t.n, 0, &f); utf8_last(t, &l);
		if (is_ws(f) || is_ws(l)) needs = 1;
	}
	if (!needs) { ShclFence f = fence_open(t); if (f.ok) needs = 1; }
	return needs;
}
// One addition to minimal quoting: an author-quoted element keeps its quotes unless
// the text reads as one of SHCL's own data formats - quoting those is just spelling
// (readers type the value either way), but quoting a plain string is the escape and
// must survive canonicalization. This clause only ever adds quoting, so a bare emit
// stays safe.
static ShclStr emit_element(ShclArena *a, const ShclElement *e) {
	ShclStr t = e->text;
	int needs = needs_quotes(t) || (e->quoted && !is_data_format(a, e));
	return needs ? quote_text(a, t) : t;
}
// An element no source wrote. It counts as quoted when canonical output will
// quote it, so a read gives the same answer before a save as after one.
static ShclElement new_element(ShclStr text) {
	ShclElement e; e.text = text; e.quoted = needs_quotes(text); return e;
}
/* Emit a stored (escape-resolved) name in a spelling that reads back as the
   same name: bare when it can be, else double-quoted with the escapes
   apply_escapes undoes. */
static ShclStr escape_name(ShclArena *a, ShclStr name) { return escape_name_as(a, name, SHCL_RULES_CURRENT); }
/* escape_name for a reader of rules: under 2.x an invisible character is
   written as it is, since 2.x kept a \u as written. */
static ShclStr escape_name_as(ShclArena *a, ShclStr name, shcl_rules rules) {
	if (name.n > 0) {
		int allbare = 1; size_t i = 0;
		while (i < name.n) { uint32_t c; size_t l = utf8_decode(name.p, name.n, i, &c); i += l; if (!is_bare_name_char(c)) { allbare = 0; break; } }
		if (allbare) return name;
	}
	ShclSB b = {0};
	sb_putc(a, &b, '"');
	for (size_t i = 0; i < name.n; i++) {
		char c = name.p[i]; uint32_t cp; size_t l;
		if (c == '\\') sb_puts(a, &b, "\\\\");
		else if (c == '"') sb_puts(a, &b, "\\\"");
		else if (c == '\t') sb_puts(a, &b, "\\t");
		else if (c == '\n') sb_puts(a, &b, "\\n");
		else if (rules == SHCL_RULES_CURRENT && (l = invisible_at(name, i, &cp)) != 0) { sb_put_unicode_escape(a, &b, cp); i += l - 1; }
		else sb_putc(a, &b, c);
	}
	sb_putc(a, &b, '"');
	return sb_S(&b);
}
static ShclStr emit_name(ShclArena *a, ShclStr name) { return escape_name(a, name); }
/* A field name for a diagnostic message: put the way the emitter would
   write it, so a name with a line break, a dot or a quote cannot pose as
   something it is not - a raw `a.b` reads exactly like `a` nesting `b`, and a
   raw line break splits one diagnostic across two. */
static ShclStr diag_name(ShclArena *a, ShclStr name) { return escape_name(a, name); }
/* One element of a value, written for a diagnostic message: the emitter's
   inline spelling, so a value with a line break cannot split one
   diagnostic across two. */
static ShclStr diag_element(ShclArena *a, const ShclElement *e) { return emit_element(a, e); }
/* A value for a diagnostic message. Only a cell reaches this today, from the
   H001 hint; a raw block has no one-line form worth suggesting. */
static ShclStr diag_value(ShclArena *a, const ShclValue *v) {
	if (v->kind != V_CELL) return value_display(a, v);
	ShclSB b = {0};
	for (size_t i = 0; i < v->nels; i++) { if (i) sb_puts(a, &b, ", "); sb_putS(a, &b, diag_element(a, &v->els[i])); }
	return sb_S(&b);
}

// --- The write side's one rule: what is written has to read back ------------
//
// A setter builds its text through the emitter and reads it back with the
// tokenizer before the document is touched. If the read does not give the
// value it was handed, the write is refused and nothing changes. No setter
// decides for itself what a quote, a `#`, a comma or a carriage return means:
// twelve review items were one setter's private rule disagreeing with the
// parser's. The typed setters keep their own render-and-parse-back on top,
// since a float or a datetime has to read back as that type and not merely as
// the same text. Every check builds in the arena it is handed - scratch at
// each call site, dead by the time the setter returns.

/* The value half of a binding line, the way emit_line writes it. */
static ShclStr emit_cell(ShclArena *a, const ShclElement *els, size_t n) {
	ShclSB out = {0, 0, 0};
	for (size_t i = 0; i < n; i++) { if (i) sb_puts(a, &out, ", "); sb_putS(a, &out, emit_element(a, &els[i])); }
	return sb_S(&out);
}

/* The opening fence line of a raw block: the fence run, then the info string
   behind a space when it would otherwise extend the run. */
static ShclStr emit_fence_line(ShclArena *a, const ShclRawVal *r) {
	ShclSB out = {0, 0, 0};
	for (size_t k = 0; k < r->fence_len; k++) sb_putc(a, &out, (char)r->fence_char);
	if (r->info.n > 0) {
		if ((unsigned char)r->info.p[0] == r->fence_char) sb_putc(a, &out, ' ');
		sb_putS(a, &out, r->info);
	}
	return sb_S(&out);
}

/* True when a piece reads as this exact text, without building it. */
static int piece_is(ShclArena *a, const ShclPiece *p, ShclStr text, ShclStr want) {
	ShclStr raw = s_slice(text, p->start, p->end);
	if (p->quote == SHCL_QUOTE_DOUBLE && raw.n && memchr(raw.p, '\\', raw.n)) return s_eq(apply_escapes(a, raw), want);
	return s_eq(raw, want);
}

/* Scan text as a line's value half, behind the colon a field line puts there.
   `a` holds the line the token spans index into, `tmp` the token
   bookkeeping. */
static ShclStr value_half(ShclArena *a, ShclArena *tmp, ShclStr text, ShclTokens *out) {
	char *m = (char *)arena_alloc(a, text.n + 1);
	m[0] = ':';
	if (text.n) memcpy(m + 1, text.p, text.n);
	ShclStr line; line.p = m; line.n = text.n + 1;
	tokenize_value(tmp, line, 1, SHCL_RULES_CURRENT, out);
	return line;
}

/* True when a value comes back off the page as itself. */
static int value_reads_back(ShclArena *a, const ShclValue *v) {
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	if (v->kind == V_EMPTY) return 1;
	if (v->kind == V_CELL) {
		ShclStr text = emit_cell(a, v->els, v->nels);
		if (text.n && memchr(text.p, '\n', text.n)) return 0;
		ShclStr line = value_half(a, a, text, &tok);
		if (tok.has_comment) return 0;
		/* Compared against the pieces rather than against a rebuilt value: a
		   bulk write runs this per set, and the text is right there. */
		size_t k = 0;
		for (size_t i = 0; i < tok.nelem; i++) {
			const ShclPiece *p = &tok.elements[i];
			if (p->quote == SHCL_QUOTE_NONE && p->end == p->start) continue;
			if (k == v->nels || !piece_is(a, p, line, v->els[k].text)) return 0;
			k++;
		}
		return k == v->nels;
	}
	const ShclRawVal *r = v->raw;
	ShclStr line = emit_fence_line(a, r);
	if (line.n && memchr(line.p, '\n', line.n)) return 0;
	tokenize_value(a, line, 0, SHCL_RULES_CURRENT, &tok);
	ShclFence f = fence_open(s_slice(line, tok.value_start, tok.value_end));
	if (!f.ok || f.ch != r->fence_char || f.len != r->fence_len || !s_eq(f.info, r->info)) return 0;
	/* A body line ending in a carriage return loses it to the load's line-end
	   trim, and one spelling the closing fence would end the block early. */
	size_t start = 0;
	for (size_t i = 0; i <= r->content.n; i++) if (i == r->content.n || r->content.p[i] == '\n') {
		ShclStr l = s_slice(r->content, start, i);
		if (l.n && l.p[l.n - 1] == '\r') return 0;
		if (is_fence_close(l, r->fence_char, r->fence_len)) return 0;
		start = i + 1;
	}
	return 1;
}

/* True when a field name comes back off a line as itself. */
static int name_reads_back(ShclArena *a, ShclStr name) {
	ShclStr text = escape_name(a, name);
	if (text.n && memchr(text.p, '\n', text.n)) return 0;
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize(a, text, ':', 0, SHCL_RULES_CURRENT, &tok);
	return !tok.has_fault && tok.nseg == 1 && !tok.segments[0].has_selector
		&& piece_is(a, &tok.segments[0].name, text, name);
}

/* The comment line this text is written as, 0 when it has no spelling. A `#`
   is added when the text has none. The load trims every line's end, so
   the trimmed text is what gets written; text holding a line break is refused
   rather than cut down to its first line. */
static int comment_line(ShclArena *a, ShclStr text, ShclStr *out) {
	if (text.n && memchr(text.p, '\n', text.n)) return 0;
	ShclStr t = trim_wsp_end(text), line;
	if (t.n && t.p[0] == '#') line = t;
	else if (t.n == 0) line = s_lit("#");
	else { ShclSB b = {0, 0, 0}; sb_puts(a, &b, "# "); sb_putS(a, &b, t); line = sb_S(&b); }
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize_value(a, line, 0, SHCL_RULES_CURRENT, &tok);
	if (!tok.has_comment || tok.comment != 0 || trim_wsp_end(line).n != line.n) return 0;
	*out = line;
	return 1;
}

/* Inline comment, canonically two spaces before the `#`. */
static void emit_trailing(ShclArena *a, ShclSB *out, ShclStr trailing) {
	if (trailing.n) { sb_puts(a, out, "  "); sb_putS(a, out, trailing); }
}
/* Which trivia list a line sits in. */
typedef enum { SITE_LEADING, SITE_INSIDE, SITE_AFTER, SITE_AMONG, SITE_ORPHANS } ShclSite;
typedef struct { size_t node; ShclSite site; size_t i; size_t depth; } ShclFell;
DEFINE_VEC(ShclVecFell, ShclFell)

/* Canonical text on its way out, with a model of the level stack a reload of
   it will have at this point: the sentinel and one level per tab up to open,
   which the last binding line leaves, then what the lines refused since then
   pushed, and the indent of a kept misplaced line that the lines under it are
   kept with. All of it lives in scratch. */
typedef struct {
	ShclArena *a;
	ShclSB out;
	ptrdiff_t open;
	ShclVecStack tail;
	int has_hold; ShclStr hold;
	const char *tabs; size_t ntabs;
	/* settle_kept only: the lines written as comments, where they sit and at
	   what depth, and how many went out as written. Then the nodes the lines
	   since the last binding line came from, each with its place in its
	   parent's list, and those a kept line was modeled through, both as
	   pairs. */
	int record; ShclVecFell fell; size_t verbatim;
	ShclVecSize near; size_t flushed; ShclVecSize kept_near;
	/* shcl_to_text_keep_lines only: where the lines from each source line
	   start (offset, line; 0 for none), each raw body with the tabs its lines
	   are padded with (start, end, pad), and where each value is written on
	   its binding line (start, end), all flat. */
	int lines; ShclVecSize marks, bodies, spans;
} ShclEmit;

static void emit_init(ShclEmit *e, ShclArena *a, size_t cap, int record) {
	memset(e, 0, sizeof *e);
	e->a = a; e->open = -1; e->record = record;
	e->out.cap = cap ? cap : 16;
	e->out.data = (char *)arena_alloc(a, e->out.cap);
}

/* n tabs, from a buffer that only ever gets a bigger successor, so a slice
   handed out earlier stays good. */
static ShclStr emit_tabs(ShclEmit *e, size_t n) {
	if (n > e->ntabs) {
		size_t nc = e->ntabs ? e->ntabs : 64;
		while (nc < n) nc *= 2;
		char *b = (char *)arena_alloc(e->a, nc);
		memset(b, '\t', nc);
		e->tabs = b; e->ntabs = nc;
	}
	ShclStr t; t.p = e->tabs; t.n = n;
	return t;
}

/* A binding line at this depth: the stack is its levels and nothing else. */
static void emit_bound(ShclEmit *e, size_t depth) {
	e->open = (ptrdiff_t)depth;
	e->tail.len = 0;
	e->has_hold = 0;
	e->near.len = 0;
	e->flushed = 0;
}

static void emit_mark(ShclEmit *e, size_t line) {
	if (!e->lines) return;
	ShclVecSize_push(e->a, &e->marks, e->out.len);
	ShclVecSize_push(e->a, &e->marks, line);
}

/* A value written from at to here, the space before it included. */
static void emit_span(ShclEmit *e, size_t at) {
	if (!e->lines) return;
	ShclVecSize_push(e->a, &e->spans, at);
	ShclVecSize_push(e->a, &e->spans, e->out.len);
}

static void emit_near(ShclEmit *e, size_t idx, size_t pos) {
	if (!e->record) return;
	ShclVecSize_push(e->a, &e->near, idx);
	ShclVecSize_push(e->a, &e->near, pos);
}

/* A line at this indent through the reload's resolve_parent(): the parent it
   finds, and the model as it leaves it, not yet taken. */
typedef struct { int found; size_t parent; ptrdiff_t open; const ShclStackEnt *tail; size_t ntail; } ShclTrial;
static ShclTrial emit_resolve(ShclEmit *e, ShclStr indent) {
	size_t levels = (size_t)(e->open + 2);
	ShclStackEnt *st = (ShclStackEnt *)arena_alloc(e->a, (levels + e->tail.len + 1) * sizeof(ShclStackEnt));
	st[0].indent = s_empty(); st[0].node = ROOT;
	for (size_t k = 0; k + 1 < levels; k++) { st[k + 1].indent = emit_tabs(e, k); st[k + 1].node = ROOT; }
	for (size_t k = 0; k < e->tail.len; k++) st[levels + k] = e->tail.data[k];
	size_t len = levels + e->tail.len;
	ShclLocated r = locate_in(st, len, indent);
	if (r.push) {
		if (r.held) len = r.to;
		st[len].indent = indent; st[len].node = UNOPENED; len++;
	} else {
		len = r.to;
	}
	ShclTrial t; t.found = r.found; t.parent = r.parent;
	if (len <= levels) { t.open = (ptrdiff_t)len - 2; t.tail = NULL; t.ntail = 0; }
	else { t.open = e->open; t.tail = st + levels; t.ntail = len - levels; }
	return t;
}

static void emit_take(ShclEmit *e, const ShclTrial *t) {
	e->open = t->open;
	e->tail.len = 0;
	for (size_t k = 0; k < t->ntail; k++) ShclVecStack_push(e->a, &e->tail, t->tail[k]);
}

/* Take a resolve, then the refusal's push: a refused line holds its own column
   unless it already sits there as a skipped line's. */
static void emit_refused(ShclEmit *e, ShclStr indent, const ShclTrial *t) {
	emit_take(e, t);
	if (!(e->tail.len && s_eq(e->tail.data[e->tail.len - 1].indent, indent) && e->tail.data[e->tail.len - 1].node == UNOPENED)) {
		ShclStackEnt se; se.indent = indent; se.node = DEAD; ShclVecStack_push(e->a, &e->tail, se);
	}
}

/* A line a reload binds, such as a list element: it resolves, then holds its
   column with a live node. */
static void emit_placed(ShclEmit *e, ShclStr indent) {
	ShclTrial t = emit_resolve(e, indent);
	emit_take(e, &t);
	ShclStackEnt se; se.indent = indent; se.node = ROOT; ShclVecStack_push(e->a, &e->tail, se);
	e->has_hold = 0;
}

/* True when a field's last leading line is one kept for its value alone,
   naming just this field, so that line is written in place of the bare
   `name:` line: a reload opens the field from it the same way. An empty block
   keeps its own line, since nothing would open the field. Only what a reload
   restores counts, so a document and its reload agree. */
static int heads_block(ShclArena *a, const ShclNode *node) {
	return node->children.len != 0 && opened_by_kept(a, node);
}

/* heads_block() but for the children: a field a reload would open only from
   the lines under it, so it goes with the last of them. */
static int opened_by_kept(ShclArena *a, const ShclNode *node) {
	if (!v_is_empty(&node->value) || node->blank_before || triv_trailing(node).n) return 0;
	ShclVecLead lead = triv_leading(node);
	if (lead.len == 0) return 0;
	const ShclLead *l = &lead.data[lead.len - 1];
	if (l->depth != 0 || (l->text.n && (l->text.p[0] == ' ' || l->text.p[0] == '\t')) || !opens_later(a, l->text)) return 0;
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize(a, l->text, ':', 0, SHCL_RULES_CURRENT, &tok);
	ShclPathScan scan = path_of(a, &tok, l->text);
	return scan.ok && scan.segs.len == 1 && scan.segs.data[0].sel.tag == SEL_NONE && s_eq(scan.segs.data[0].name, node->name);
}

/* A misplaced line's text as the comment it falls back to. */
static ShclStr commented(ShclArena *a, ShclStr text) {
	ShclSB b = {0};
	sb_puts(a, &b, "# "); sb_putS(a, &b, s_slice(text, leading_ws(text).n, text.n));
	return sb_S(&b);
}

/* A kept line, and the raw body and fence it took, if any, which go one level
   under it, as a field's block does. The body moves with its line. */
static void push_kept(ShclEmit *e, ShclStr text, size_t pad) {
	ShclArena *a = e->a;
	const char *nl = text.n ? (const char *)memchr(text.p, '\n', text.n) : NULL;
	if (!nl) { sb_putS(a, &e->out, text); sb_putc(a, &e->out, '\n'); return; }
	size_t cut = (size_t)(nl - text.p);
	sb_putS(a, &e->out, s_slice(text, 0, cut)); sb_putc(a, &e->out, '\n');
	ShclStr block = s_slice(text, cut + 1, text.n);
	size_t body = e->out.len;
	size_t fence = 0;
	for (size_t k = block.n; k > 0; k--) if (block.p[k - 1] == '\n') { fence = k; break; }
	if (fence) {
		size_t start = 0;
		for (size_t k = 0; k < fence; k++) if (block.p[k] == '\n') {
			ShclStr l = s_slice(block, start, k);
			if (l.n) sb_putS(a, &e->out, emit_tabs(e, pad + 1));
			sb_putS(a, &e->out, l); sb_putc(a, &e->out, '\n');
			start = k + 1;
		}
	}
	size_t end = e->out.len;
	sb_putS(a, &e->out, emit_tabs(e, pad + 1));
	sb_putS(a, &e->out, s_slice(block, fence, block.n)); sb_putc(a, &e->out, '\n');
	if (e->lines) {
		ShclVecSize_push(a, &e->bodies, body);
		ShclVecSize_push(a, &e->bodies, end);
		ShclVecSize_push(a, &e->bodies, pad + 1);
	}
}

/* Write a run of comments and kept lines, base levels deep. A misplaced line
   kept as written (its text has its own indent, a comment's never does)
   goes back as it was only where a reload keeps it again, which the model of
   the reload's stack answers the way the parser will: refused for its indent,
   or under the kept line before it. A merge or an edit can leave it where it
   would bind, and there it is written as a comment, which reads the same.
   node, site and first name the list and the index of its first line, for
   settle_kept. */
static void push_leads(ShclEmit *e, const ShclLead *leads, size_t n, size_t base, size_t node, ShclSite site, size_t first) {
	ShclArena *a = e->a;
	size_t last_comment = 0;
	for (size_t i = 0; i < n; i++) {
		const ShclLead *c = &leads[i];
		if (c->blank_before && e->out.len) sb_putc(a, &e->out, '\n');
		/* A kept line among list elements is part of the list's run. */
		if (site != SITE_AMONG) emit_mark(e, c->line);
		if (c->text.n && (c->text.p[0] == ' ' || c->text.p[0] == '\t')) {
			ShclStr indent = leading_ws(c->text);
			ShclTrial t = emit_resolve(e, indent);
			int under = e->has_hold && indent.n > e->hold.n && memcmp(indent.p, e->hold.p, e->hold.n) == 0;
			int keep = !t.found ? memchr(indent.p, ' ', indent.n) != NULL : t.parent == DEAD ? under : 0;
			if (keep) {
				if (!t.found) { e->has_hold = 1; e->hold = indent; }
				emit_refused(e, indent, &t);
				e->verbatim++;
				if (e->record) {
					for (size_t k = e->flushed; k < e->near.len; k++) ShclVecSize_push(a, &e->kept_near, e->near.data[k]);
					e->flushed = e->near.len;
				}
				sb_putS(a, &e->out, c->text); sb_putc(a, &e->out, '\n');
			} else {
				/* Level with the comment before it, so the run's nesting reads
				   back the same. */
				if (e->record) { ShclFell f; f.node = node; f.site = site; f.i = first + i; f.depth = last_comment; ShclVecFell_push(a, &e->fell, f); }
				sb_putS(a, &e->out, emit_tabs(e, base + last_comment));
				sb_puts(a, &e->out, "# "); sb_putS(a, &e->out, s_slice(c->text, indent.n, c->text.n)); sb_putc(a, &e->out, '\n');
			}
			continue;
		}
		size_t pad = base + c->depth;
		if (c->text.n && c->text.p[0] == '#') last_comment = c->depth;
		else {
			/* A kept malformed line resolves and holds its column on a reload,
			   open for the lines under it when only its value was wrong. */
			ShclStr ind = emit_tabs(e, pad);
			ShclTrial t = emit_resolve(e, ind);
			e->has_hold = 0;
			if (t.found && t.parent != DEAD && opens_later(a, c->text)) {
				emit_take(e, &t);
				ShclStackEnt se; se.indent = ind; se.node = ROOT; ShclVecStack_push(a, &e->tail, se);
			}
			else emit_refused(e, ind, &t);
		}
		sb_putS(a, &e->out, emit_tabs(e, pad));
		push_kept(e, c->text, pad);
	}
}

// Emit a sibling run. The parent walk already knows whether an earlier
// same-name sibling is empty (the raw same-line-fence hazard), so one
// seen-empties set here replaces a per-child rescan of the whole run.
static void emit_node(shcl_doc *d, size_t idx, size_t pos, size_t depth, int would_merge, ShclEmit *e);
static void emit_children(shcl_doc *d, const ShclVecSize *kids, size_t depth, ShclEmit *e) {
	ShclCMap empties; memset(&empties, 0, sizeof empties);
	for (size_t i = 0; i < kids->len; i++) {
		size_t c = kids->data[i];
		ShclNode *n = &NODE(d, c);
		uint64_t h = cmap_hash(n->name, s_empty());
		int seen = 0; /* entries name the empty sibling, so a hit verifies */
		for (ShclCMapEnt *en = cmap_first(&empties, h); en; en = cmap_next(en, h))
			if (s_eq(NODE(d, en->val).name, n->name)) { seen = 1; break; }
		int wm = n->value.kind == V_RAW && seen;
		if (v_is_empty(&n->value) && !seen)
			cmap_put(&d->scratch, &empties, h, c);
		emit_node(d, c, i, depth, wm, e);
	}
}

static void emit_line(shcl_doc *d, size_t idx, size_t pos, size_t depth, int would_merge, ShclEmit *e);
static void emit_node(shcl_doc *d, size_t idx, size_t pos, size_t depth, int would_merge, ShclEmit *e) {
	emit_line(d, idx, pos, depth, would_merge, e);
	ShclVecSize ch = NODE(d, idx).children;
	emit_children(d, &ch, depth + 1, e);
	emit_near(e, idx, pos);
	/* Comments this block owns with no child to take them, one deeper. */
	ShclVecLead ins = triv_inside(&NODE(d, idx));
	push_leads(e, ins.data, ins.len, depth + 1, idx, SITE_INSIDE, 0);
	/* Comments that hung on this block after its last child. */
	ShclVecLead aft = triv_after(&NODE(d, idx));
	push_leads(e, aft.data, aft.len, depth, idx, SITE_AFTER, 0);
}

/* Kept out of emit_node, which recurses once per level: its locals would
   otherwise sit in every frame, and a document at the nesting cap ran past a
   1 MB stack in the reference's debug build. */
static void emit_line(shcl_doc *d, size_t idx, size_t pos, size_t depth, int would_merge, ShclEmit *e) {
	/* The whole emit - the output buffer and the quoted/escaped spellings both -
	   is built in scratch; shcl_to_canonical copies the finished bytes into the
	   document arena once. Building it there instead retained several times the
	   output on every save, in an arena that cannot give it back. */
	ShclArena *a = &d->scratch;
	ShclSB *out = &e->out;
	ShclNode *node = &NODE(d, idx);
	ShclValue *v = &node->value;
	ShclVecLead lead = triv_leading(node);
	ShclStr trailing = triv_trailing(node);
	/* Same-line fence spelling can't have an inline comment (an unbalanced
	   quote in the info-string could hide the `#` on reparse), so its trailing
	   comment joins the leading lines instead; the flag comes from the
	   parent's walk. Each blank rides its own comment (or the binding line),
	   never as the first output line. */
	emit_near(e, idx, pos);
	push_leads(e, lead.data, lead.len, depth, idx, SITE_LEADING, 0);
	/* The kept line just written opens this block on a reload. */
	if (heads_block(a, node)) {
		emit_bound(e, depth);
		emit_near(e, idx, pos);
		return;
	}
	if (node->blank_before && out->len) sb_putc(a, out, '\n');
	emit_mark(e, node->line);
	if (would_merge && trailing.n) {
		for (size_t z = 0; z < depth; z++) sb_putc(a, out, '\t');
		sb_putS(a, out, trailing); sb_putc(a, out, '\n');
	}
	for (size_t k = 0; k < depth; k++) sb_putc(a, out, '\t');
	sb_putS(a, out, emit_name(a, node->name));
	sb_putc(a, out, ':');
	emit_bound(e, depth);
	emit_near(e, idx, pos);
	if (v->kind == V_EMPTY) { emit_span(e, out->len); emit_trailing(a, out, trailing); sb_putc(a, out, '\n'); }
	else if (v->kind == V_CELL && stacks(node)) {
		/* Stacked, with the kept lines where they sat. */
		emit_trailing(a, out, trailing);
		sb_putc(a, out, '\n');
		ShclVecAmong am = triv_among(node);
		size_t next = 0;
		for (size_t i = 0; i < v->nels; i++) {
			size_t from = next;
			while (next < am.len && am.data[next].before <= i) next++;
			for (size_t j = from; j < next; j++) push_leads(e, &am.data[j].lead, 1, depth + 1, idx, SITE_AMONG, j);
			ShclStr column = emit_tabs(e, depth + 1);
			sb_putS(a, out, column);
			sb_puts(a, out, "* ");
			sb_putS(a, out, emit_element(a, &v->els[i]));
			sb_putc(a, out, '\n');
			emit_placed(e, column);
		}
		for (size_t j = next; j < am.len; j++) push_leads(e, &am.data[j].lead, 1, depth + 1, idx, SITE_AMONG, j);
	}
	else if (v->kind == V_CELL) {
		size_t at = out->len;
		sb_putc(a, out, ' ');
		sb_putS(a, out, emit_cell(a, v->els, v->nels));
		emit_span(e, at);
		emit_trailing(a, out, trailing);
		sb_putc(a, out, '\n');
	} else {
		const ShclRawVal *r = v->raw;
		if (would_merge) sb_putc(a, out, ' ');
		else { emit_trailing(a, out, trailing); sb_putc(a, out, '\n'); }
		if (!would_merge) for (size_t k = 0; k < depth + 1; k++) sb_putc(a, out, '\t');
		sb_putS(a, out, emit_fence_line(a, r));
		sb_putc(a, out, '\n');
		size_t body = out->len;
		if (r->content.n > 0) {
			size_t start = 0;
			for (size_t i = 0; i <= r->content.n; i++) if (i == r->content.n || r->content.p[i] == '\n') {
				ShclStr l = s_slice(r->content, start, i);
				if (l.n > 0) for (size_t z = 0; z < depth + 1; z++) sb_putc(a, out, '\t');
				sb_putS(a, out, l); sb_putc(a, out, '\n');
				start = i + 1;
			}
		}
		size_t end = out->len;
		for (size_t k = 0; k < depth + 1; k++) sb_putc(a, out, '\t');
		for (size_t k = 0; k < r->fence_len; k++) sb_putc(a, out, (char)r->fence_char);
		sb_putc(a, out, '\n');
		if (e->lines) {
			ShclVecSize_push(e->a, &e->bodies, body);
			ShclVecSize_push(e->a, &e->bodies, end);
			ShclVecSize_push(e->a, &e->bodies, depth + 1);
		}
	}
}

static void emit_all(shcl_doc *d, ShclEmit *e) {
	ShclVecSize rc = NODE(d, ROOT).children;
	emit_children(d, &rc, 0, e);
	/* Comments that never found a following line re-emit at the end. */
	emit_near(e, ROOT, 0);
	push_leads(e, d->orphans.data, d->orphans.len, 0, ROOT, SITE_ORPHANS, 0);
}

/* The canonical text, built in scratch (valid until the next resolve). Emit's
   own temporaries go there too, so a program that saves periodically does not
   grow by several times the output on every save. */
static ShclStr emit_canonical(shcl_doc *d) {
	arena_reset(&d->scratch);
	/* Pre-sized by node count, so the builder does not double its way up. */
	ShclEmit e; emit_init(&e, &d->scratch, d->nodes.len * 24, 0);
	emit_all(d, &e);
	return sb_S(&e.out);
}

/* One pass of settle_kept: returns whether a line moved out of a list. */
static int settle_kept_once(shcl_doc *d) {
	arena_reset(&d->scratch);
	ShclEmit e; emit_init(&e, &d->scratch, 0, 1);
	emit_all(d, &e);
	d->kept = e.verbatim > 0;
	if (e.kept_near.len > d->kept_near_cap) {
		size_t *grown = (size_t *)realloc(d->kept_near, e.kept_near.len * sizeof(size_t));
		if (!grown) arena_panic(d->panic);
		d->kept_near = grown; d->kept_near_cap = e.kept_near.len;
	}
	if (e.kept_near.len) memcpy(d->kept_near, e.kept_near.data, e.kept_near.len * sizeof(size_t));
	d->kept_near_len = e.kept_near.len;
	ShclArena *a = &d->arena;
	size_t among = 0;
	for (size_t k = 0; k < e.fell.len; k++) {
		const ShclFell *f = &e.fell.data[k];
		ShclVecLead *list;
		if (f->site == SITE_AMONG) { among++; continue; }
		if (f->site == SITE_ORPHANS) list = &d->orphans;
		else {
			ShclTrivia *t = triv_mut(a, &NODE(d, f->node));
			list = f->site == SITE_LEADING ? &t->leading : f->site == SITE_INSIDE ? &t->inside : &t->after;
		}
		ShclLead *l = &list->data[f->i];
		l->text = commented(a, l->text);
		l->depth = f->depth;
		l->kept = 1;
	}
	/* Out of each list latest first, so a removal leaves the earlier indices
	   alone, then onto the end of the leading lines in order. */
	ShclVecLead moved = {0};
	for (size_t k = e.fell.len; k-- > 0;) {
		const ShclFell *f = &e.fell.data[k];
		if (f->site != SITE_AMONG) continue;
		ShclTrivia *t = triv_mut(a, &NODE(d, f->node));
		ShclVecLead_push(&d->scratch, &moved, t->among.data[f->i].lead);
		memmove(&t->among.data[f->i], &t->among.data[f->i + 1], (t->among.len - f->i - 1) * sizeof(ShclAmong));
		t->among.len--;
		size_t j = k;
		while (j-- > 0 && e.fell.data[j].site != SITE_AMONG) {}
		if (j != (size_t)-1 && e.fell.data[j].node == f->node) continue;
		size_t depth = 0;
		for (size_t q = t->leading.len; q-- > 0;) if (t->leading.data[q].text.n && t->leading.data[q].text.p[0] == '#') { depth = t->leading.data[q].depth; break; }
		for (size_t q = moved.len; q-- > 0;) {
			ShclLead l = moved.data[q];
			l.text = commented(a, l.text);
			l.depth = depth;
			l.line = 0;
			l.kept = 1;
			ShclVecLead_push(a, &t->leading, l);
		}
		moved.len = 0;
	}
	/* A line moved above the first list in the file is now the first thing
	   written, so its blank goes the way the load's did. */
	if (among) settle_first_blank(d);
	return among > 0;
}

/* Make a misplaced line kept as written into the comment the emitter writes it
   as, wherever it would now bind as written, so the document is the one its
   saved text reloads as and the next edit comes out the same either way. One among
   a list's elements goes above the list, as a reload files a comment there.
   A line moved out of a list can leave it written inline, which changes what
   the lines after it sit under, so it goes again until nothing moves. Runs
   after a load and after each edit, and only while the document holds such a
   line. */
static uint64_t lead_sum(uint64_t h, const ShclLead *l) {
	h = fnv_dec(h, l->depth);
	h = fnv_dec(h, l->text.n);
	return fnv_str(h, l->text);
}

/* Everything the emit model reads from the nodes in kept_near: each one still
   at its place in its parent's list, its child count, its value's form and its
   comment lines. A kept line's parent chain needs no entry, since a binding
   line resets the model to its own depth. */
static uint64_t near_sum(const shcl_doc *d) {
	uint64_t h = 1469598103934665603ull;
	for (size_t k = 0; k + 1 < d->kept_near_len; k += 2) {
		size_t n = d->kept_near[k], pos = d->kept_near[k + 1];
		const ShclNode *nd = &NODE(d, n);
		h = fnv_dec(h, n);
		h = fnv_dec(h, nd->children.len);
		if (n == ROOT) {
			h = fnv_dec(h, d->orphans.len);
			for (size_t i = 0; i < d->orphans.len; i++) h = lead_sum(h, &d->orphans.data[i]);
			continue;
		}
		int linked = nd->parent < d->nodes.len && pos < NODE(d, nd->parent).children.len && NODE(d, nd->parent).children.data[pos] == n;
		h = fnv_byte(h, (unsigned char)linked);
		h = fnv_byte(h, (unsigned char)stacks(nd));
		h = fnv_byte(h, nd->value.kind == V_EMPTY ? 0u : nd->value.kind == V_CELL ? 1u : 2u);
		if (nd->value.kind == V_CELL) h = fnv_dec(h, nd->value.nels);
		if (!nd->trivia) { h = fnv_byte(h, 0u); continue; }
		const ShclVecLead *lists[3] = { &nd->trivia->leading, &nd->trivia->inside, &nd->trivia->after };
		for (size_t j = 0; j < 3; j++) {
			h = fnv_dec(h, lists[j]->len);
			for (size_t i = 0; i < lists[j]->len; i++) h = lead_sum(h, &lists[j]->data[i]);
		}
		h = fnv_dec(h, nd->trivia->among.len);
		for (size_t i = 0; i < nd->trivia->among.len; i++) {
			h = fnv_dec(h, nd->trivia->among.data[i].before);
			h = lead_sum(h, &nd->trivia->among.data[i].lead);
		}
	}
	return h;
}

static void settle_kept(shcl_doc *d) {
	while (d->kept && settle_kept_once(d)) {}
	if (d->kept) d->kept_sum = near_sum(d);
}

/* After an edit. A kept line binds or not by the lines between it and the
   binding line above, so an edit that changed none of the nodes those came
   from cannot move it, and the whole-document emit is skipped (20260924d
   item 2). */
static void resettle_kept(shcl_doc *d) {
	if (d->kept && near_sum(d) != d->kept_sum) settle_kept(d);
}

shcl_str shcl_to_canonical(shcl_doc *d) {
	/* The returned bytes live in the document arena - that is the documented
	   contract. A save goes through emit_canonical directly, so it retains
	   nothing (200 saves of 79 KB grew a document by 17 MB). */
	return s_dup(&d->reads, emit_canonical(d));
}

/* The canonical text with what the save that keeps lines needs to line it up
   against the source, built in scratch. */
static void emit_marked(shcl_doc *d, ShclEmit *e) {
	arena_reset(&d->scratch);
	emit_init(e, &d->scratch, d->nodes.len * 24, 0);
	e->lines = 1;
	emit_all(d, e);
}

/* A run of canonical lines from one source line on (0: from none), with the
   blank lines written before it and the spans of its values, as a range of
   the emit's flat span pairs. As a group, line is the first source line of
   its runs and part_from..part_to the runs. */
typedef struct { size_t line, start, end, blanks, span_from, span_to, part_from, part_to; } ShclUnit;
DEFINE_VEC(ShclVecUnit, ShclUnit)

/* Where the line starting at pos ends, past its newline. */
static size_t line_end(ShclStr text, size_t pos) {
	const char *nl = (const char *)memchr(text.p + pos, '\n', text.n - pos);
	return nl ? (size_t)(nl - text.p) + 1 : text.n;
}

/* The line ending t ends with: CRLF, LF or none. */
static const char *eol_of(ShclStr t) {
	if (t.n >= 2 && t.p[t.n - 2] == '\r' && t.p[t.n - 1] == '\n') return "\r\n";
	if (t.n >= 1 && t.p[t.n - 1] == '\n') return "\n";
	return "";
}

static size_t tabs_of(ShclStr s) {
	size_t n = 0;
	while (n < s.n && s.p[n] == '\t') n++;
	return n;
}

static ShclVecUnit units_of(ShclArena *a, ShclEmit *e) {
	ShclStr text = sb_S(&e->out);
	ShclVecUnit units = {0};
	size_t mi = 0, bi = 0, tag = 0, blanks = 0, pos = 0;
	int open = 0;
	while (pos < text.n) {
		size_t next = line_end(text, pos);
		while (mi < e->marks.len && e->marks.data[mi] <= pos) { tag = e->marks.data[mi + 1]; mi += 2; }
		while (bi < e->bodies.len && e->bodies.data[bi + 1] <= pos) bi += 3;
		int in_body = bi < e->bodies.len && e->bodies.data[bi] <= pos;
		if (text.p[pos] == '\n' && !in_body) { blanks++; open = 0; }
		else if (open && units.len && units.data[units.len - 1].line == tag) units.data[units.len - 1].end = next;
		else {
			ShclUnit u; u.line = tag; u.start = pos; u.end = next; u.blanks = blanks; u.span_from = 0; u.span_to = 0;
			u.part_from = units.len; u.part_to = units.len + 1;
			ShclVecUnit_push(a, &units, u);
			blanks = 0;
			open = 1;
		}
		pos = next;
	}
	size_t si = 0;
	for (size_t k = 0; k < units.len; k++) {
		ShclUnit *u = &units.data[k];
		while (si < e->spans.len && e->spans.data[si] < u->start) si += 2;
		u->span_from = si;
		while (si < e->spans.len && e->spans.data[si] < u->end) si += 2;
		u->span_to = si;
	}
	return units;
}

/* The runs one source line wrote, and every run between them, as one group,
   with a line inside a raw block or a stacked list counted as the binding
   line's. A comment the canonical form writes between a dotted line's block
   and its child sits inside such a group, and the group is kept or rewritten
   whole (20260925b item 2). */
static ShclVecUnit group_units(ShclArena *a, const ShclVecUnit *units, const size_t *owner, size_t n_owner) {
	size_t size = n_owner;
	for (size_t i = 0; i < units->len; i++) if (units->data[i].line + 1 > size) size = units->data[i].line + 1;
	size_t *last = (size_t *)arena_alloc(a, size * sizeof(size_t));
	memset(last, 0, size * sizeof(size_t));
	#define KL_OF(u) ((u).line < n_owner ? owner[(u).line] : (u).line)
	for (size_t i = 0; i < units->len; i++) last[KL_OF(units->data[i])] = i;
	ShclVecUnit groups = {0};
	for (size_t i = 0; i < units->len;) {
		size_t j = i, line = 0;
		for (size_t k = i; k <= j; k++) {
			size_t o = KL_OF(units->data[k]);
			if (o == 0) continue;
			if (last[o] > j) j = last[o];
			if (line == 0 || o < line) line = o;
		}
		#undef KL_OF
		ShclUnit g;
		g.line = line; g.start = units->data[i].start; g.end = units->data[j].end; g.blanks = units->data[i].blanks;
		g.span_from = units->data[i].span_from; g.span_to = units->data[j].span_to;
		g.part_from = i; g.part_to = j + 1;
		ShclVecUnit_push(a, &groups, g);
		i = j + 1;
	}
	return groups;
}

/* One level's indent as the source writes it, when known. */
typedef struct { int has; ShclStr s; } ShclIndent;
DEFINE_VEC(ShclVecIndent, ShclIndent)

static void indents_resize(ShclArena *a, ShclVecIndent *v, size_t n) {
	if (v->len > n) { v->len = n; return; }
	while (v->len < n) { ShclIndent none; none.has = 0; none.s = s_empty(); ShclVecIndent_push(a, v, none); }
}

/* The indent a new line depth levels down gets: the last one written there,
   or the nearest shallower one plus a level. */
static ShclStr indent_for(ShclArena *a, const ShclVecIndent *indents, size_t depth, ShclStr step) {
	size_t j = depth;
	while (j > 0 && (j >= indents->len || !indents->data[j].has)) j--;
	ShclStr base = j < indents->len && indents->data[j].has ? indents->data[j].s : s_empty();
	ShclSB b = {0, 0, 0};
	sb_putS(a, &b, base);
	for (size_t k = j; k < depth; k++) sb_putS(a, &b, step);
	return sb_S(&b);
}

/* A source line written at depth. One whose indent does not nest under the
   level above it, a dotted path for one, says nothing about the levels after
   it. */
static void note_indent(ShclArena *a, ShclVecIndent *indents, size_t depth, ShclStr indent) {
	int fits;
	if (depth == 0) fits = indent.n == 0;
	else {
		fits = indent.n != 0;
		if (fits && depth - 1 < indents->len && indents->data[depth - 1].has) {
			ShclStr up = indents->data[depth - 1].s;
			fits = indent.n > up.n && memcmp(indent.p, up.p, up.n) == 0;
		}
	}
	if (fits) {
		indents_resize(a, indents, depth + 1);
		indents->data[depth].has = 1; indents->data[depth].s = indent;
	} else if (indents->len > 1) indents->len = 1;
}

/* A run the edits wrote, indented the way the lines around it are. A raw
   body keeps its own tabs past the pad, and a kept line its indent. */
static void write_run(ShclArena *a, ShclSB *out, ShclEmit *e, size_t pos, size_t end, ShclVecIndent *indents, ShclStr step, const char *eol) {
	ShclStr text = sb_S(&e->out);
	while (pos < end) {
		size_t next = line_end(text, pos);
		ShclStr line = s_slice(text, pos, next - 1);
		size_t lo = 0, hi = e->bodies.len / 3;
		while (lo < hi) { size_t mid = (lo + hi) / 2; if (e->bodies.data[mid * 3] <= pos) lo = mid + 1; else hi = mid; }
		if (lo > 0 && pos < e->bodies.data[(lo - 1) * 3 + 1]) {
			size_t pad = e->bodies.data[(lo - 1) * 3 + 2];
			if (line.n) {
				sb_putS(a, out, indent_for(a, indents, pad, step));
				sb_putS(a, out, s_slice(line, pad, line.n));
			}
		} else {
			size_t depth = tabs_of(line);
			if (depth < line.n && line.p[depth] == ' ') sb_putS(a, out, line);
			else {
				ShclStr indent = indent_for(a, indents, depth, step);
				sb_putS(a, out, indent);
				sb_putS(a, out, s_slice(line, depth, line.n));
				indents_resize(a, indents, depth + 1);
				indents->data[depth].has = 1; indents->data[depth].s = indent;
			}
		}
		sb_puts(a, out, eol);
		pos = next;
	}
}

/* A source line split for an edit: the text without its trailing blanks, what
   followed that, and where the part after the indent starts. */
typedef struct { ShclStr t, tail, rest; size_t head; } ShclSrcLine;
static ShclSrcLine src_line(ShclStr line) {
	ShclSrcLine r;
	ShclStr body = line;
	if (body.n && body.p[body.n - 1] == '\n') body.n--;
	r.t = trim_wsp_end(body);
	r.tail = s_slice(line, r.t.n, line.n);
	r.rest = trim_wsp_start(s_slice(r.t, leading_ws(r.t).n, r.t.n));
	r.head = r.t.n - r.rest.n;
	return r;
}

/* A binding line the edits rewrote, with the name written the way the source
   line wrote it. 0 unless both lines bind one plain name. */
static int authored_head(ShclArena *a, ShclStr src, ShclStr canon, ShclStr *out) {
	ShclSrcLine sl = src_line(src);
	ShclStr c = s_slice(canon, tabs_of(canon), canon.n);
	ShclStr texts[2]; texts[0] = sl.rest; texts[1] = c;
	size_t sep[2];
	for (size_t k = 0; k < 2; k++) {
		ShclStr text = texts[k];
		if (text.n && (text.p[0] == '#' || text.p[0] == '*')) return 0;
		ShclTokens tok; memset(&tok, 0, sizeof tok);
		tokenize(a, text, ':', 0, SHCL_RULES_CURRENT, &tok);
		if (tok.nseg != 1 || tok.segments[0].has_selector || tok.has_fault || !tok.has_sep) return 0;
		sep[k] = tok.sep;
	}
	ShclSB b = {0, 0, 0};
	sb_putS(a, &b, s_slice(sl.t, 0, sl.head + sep[0] + 1));
	sb_putS(a, &b, s_slice(c, sep[1] + 1, c.n));
	*out = sb_S(&b);
	return 1;
}

/* A run whose only change is its last value, written into the source line in
   place of the old one, so the name, spacing and comment stay as they were.
   0 when anything else changed or the line is not a plain field. */
static int splice_value(ShclArena *a, ShclStr line, ShclEmit *was, const ShclUnit *w, ShclEmit *now, const ShclUnit *u, ShclStr *out) {
	size_t n0 = (w->span_to - w->span_from) / 2, n1 = (u->span_to - u->span_from) / 2;
	if (n0 == 0 || n0 != n1) return 0;
	ShclStr t0 = sb_S(&was->out), t1 = sb_S(&now->out);
	const size_t *s0 = was->spans.data + w->span_from, *s1 = now->spans.data + u->span_from;
	size_t p0 = w->start, p1 = u->start;
	for (size_t k = 0; k < n0; k++) {
		if (!s_eq(s_slice(t0, p0, s0[2 * k]), s_slice(t1, p1, s1[2 * k]))) return 0;
		if (k + 1 < n0 && !s_eq(s_slice(t0, s0[2 * k], s0[2 * k + 1]), s_slice(t1, s1[2 * k], s1[2 * k + 1]))) return 0;
		p0 = s0[2 * k + 1]; p1 = s1[2 * k + 1];
	}
	if (!s_eq(s_slice(t0, p0, w->end), s_slice(t1, p1, u->end))) return 0;
	ShclStr value = s_slice(t1, s1[2 * (n1 - 1)], s1[2 * (n1 - 1) + 1]);
	ShclSrcLine sl = src_line(line);
	if (sl.rest.n && (sl.rest.p[0] == '#' || sl.rest.p[0] == '*')) return 0;
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize(a, sl.rest, ':', 0, SHCL_RULES_CURRENT, &tok);
	if (!tok.has_sep || tok.has_fault) return 0;
	size_t colon = tok.sep, vs = tok.value_start, ve = tok.value_end;
	if (fence_open(s_slice(sl.rest, vs, ve)).ok || bracket_text(&tok, sl.rest)) return 0;
	/* The blanks after the colon stay as they were when there was a value and
	   still is one; the canonical value comes with one space. */
	size_t from = vs == ve ? colon + 1 : ve;
	int gap = vs != ve && value.n && value.p[0] == ' ';
	ShclSB b = {0, 0, 0};
	sb_putS(a, &b, s_slice(sl.t, 0, sl.head + colon + 1));
	if (gap) sb_putS(a, &b, s_slice(sl.rest, colon + 1, vs));
	sb_putS(a, &b, gap ? s_slice(value, 1, value.n) : value);
	sb_putS(a, &b, s_slice(sl.rest, from, sl.rest.n));
	sb_putS(a, &b, sl.tail);
	*out = sb_S(&b);
	return 1;
}

/* splice_value for a group: the runs line up one for one and differ in one,
   the last its source line wrote, so the line's last value is its value.
   *at is the line and *out its new text. */
static int splice_group(ShclArena *a, const ShclVecS *lines, ShclEmit *was, const ShclVecUnit *wr, const ShclUnit *w, ShclEmit *now, const ShclVecUnit *ur, const ShclUnit *u, size_t *at, ShclStr *out) {
	size_t len = w->part_to - w->part_from;
	if (len != u->part_to - u->part_from) return 0;
	ShclStr t0 = sb_S(&was->out), t1 = sb_S(&now->out);
	const ShclUnit *x = wr->data + w->part_from, *y = ur->data + u->part_from;
	size_t hit = NIL;
	for (size_t k = 0; k < len; k++) {
		if (x[k].line != y[k].line || x[k].blanks != y[k].blanks) return 0;
		if (!s_eq(s_slice(t0, x[k].start, x[k].end), s_slice(t1, y[k].start, y[k].end))) {
			if (hit != NIL) return 0;
			hit = k;
		}
	}
	if (hit == NIL) return 0;
	for (size_t k = hit + 1; k < len; k++) if (x[k].line == x[hit].line) return 0;
	size_t l = x[hit].line;
	if (l < 1 || l > lines->len) return 0;
	if (!splice_value(a, lines->data[l - 1], was, &x[hit], now, &y[hit], out)) return 0;
	*at = l;
	return 1;
}

/* What a keep-lines save holds past its own frame: the reparsed source and
   the reload of the result. Off the frame, so a longjmping SHCL_OOM can give
   them back. */
typedef struct { shcl_doc *loaded, *back; } ShclKeepOwn;

static int kl_blank(ShclStr l) {
	while (l.n && l.p[l.n - 1] == '\n') l.n--;
	return s_trim_wsp(l).n == 0;
}

static int code_cmp(const void *x, const void *y) {
	return strcmp(*(const char *const *)x, *(const char *const *)y);
}

/* Each error code d loads with, of loaded with at least as often. */
static int errors_within(ShclArena *a, const shcl_doc *d, const shcl_doc *of) {
	const shcl_doc *docs[2]; docs[0] = d; docs[1] = of;
	const char **codes[2]; size_t count[2];
	for (size_t k = 0; k < 2; k++) {
		codes[k] = (const char **)arena_alloc(a, (docs[k]->diags.len + 1) * sizeof(char *));
		count[k] = 0;
		for (size_t i = 0; i < docs[k]->diags.len; i++)
			if (docs[k]->diags.data[i].sev == SHCL_SEV_ERROR) codes[k][count[k]++] = docs[k]->diags.data[i].code;
		qsort(codes[k], count[k], sizeof(char *), code_cmp);
	}
	size_t j = 0;
	for (size_t i = 0; i < count[0]; i++) {
		while (j < count[1] && strcmp(codes[1][j], codes[0][i]) < 0) j++;
		if (j == count[1] || strcmp(codes[1][j], codes[0][i]) != 0) return 0;
		j++;
	}
	return 1;
}

/* The save that keeps lines, on the loaded text: the loaded document's
   canonical runs line up with the text by the source line each came from,
   and the edited document's runs that match one exactly take that line's
   text. 0 when the result would not reload as d. *out lives in d's scratch,
   or is the source itself. */
/* The lines no group stands for that sat right after a kept group, when the
   group that followed it then does not follow it now. They go out before the
   next source group, a new line not indented past them, or the end. A new line
   indented past them goes first, since one written under a dropped line would
   be dropped with it. A line the load dropped comes back this way. */
static void kl_flush(ShclArena *a, ShclSB *ob, const ShclVecS *lines, unsigned char *left, unsigned char *wrote, size_t from, size_t to) {
	for (size_t k = from; k < to; k++)
		if (left[k]) { sb_putS(a, ob, lines->data[k - 1]); wrote[k] = 1; left[k] = 0; }
}

static int keep_lines(shcl_doc *d, ShclKeepOwn *own, jmp_buf *panic, ShclStr *out) {
	/* A text that was canonical keeps its lines as the canonical form. */
	if (d->source.n == 0) { *out = emit_canonical(d); return 1; }
	ShclArena *a = &d->scratch;
	ShclEmit now; emit_marked(d, &now);
	shcl_doc *ld = own->loaded = do_parse(d->source.p, d->source.n, d->strictness, 0, 0, 0, 1);
	if (!ld) arena_panic(panic);
	doc_guard(ld, panic);
	ShclEmit was; emit_marked(ld, &was);
	ShclStr nowS = sb_S(&now.out), wasS = sb_S(&was.out);
	if (s_eq(nowS, wasS)) { *out = d->source; return 1; }
	ShclStr src = d->source, body = src;
	size_t bom = 0;
	if (src.n >= 3 && (unsigned char)src.p[0] == 0xEF && (unsigned char)src.p[1] == 0xBB && (unsigned char)src.p[2] == 0xBF) { bom = 3; body = s_slice(src, 3, src.n); }
	ShclVecS lines = {0};
	for (size_t pos = 0; pos < body.n;) {
		size_t next = line_end(body, pos);
		ShclVecS_push(a, &lines, s_slice(body, pos, next));
		pos = next;
	}
	size_t n = lines.len;
	#define KL_LINE(l) (lines.data[(l) - 1])
	/* The lines each source line stands for: its own, through the end of a raw
	   block or a stacked list. Ranges that overlap, as a list taken up again
	   further down, run together, and each line in a run counts as the run's
	   first line, which stands for the whole run. */
	size_t *owns = (size_t *)arena_alloc(a, (n + 2) * sizeof(size_t));
	size_t *owner = (size_t *)arena_alloc(a, (n + 2) * sizeof(size_t));
	for (size_t k = 0; k < n + 2; k++) owns[k] = owner[k] = k;
	for (size_t k = 0; k + 1 < ld->ends.len; k += 2) {
		size_t l = ld->ends.data[k], e = ld->ends.data[k + 1];
		if (l > n) continue;
		if (e > n) e = n;
		if (e > owns[l]) owns[l] = e;
	}
	size_t *end = (size_t *)arena_alloc(a, (n + 2) * sizeof(size_t));
	memcpy(end, owns, (n + 2) * sizeof(size_t));
	size_t run = 0, run_end = 0;
	for (size_t k = 1; k <= n; k++) {
		if (k <= run_end) owner[k] = run;
		else run = k;
		if (owns[k] > run_end) run_end = owns[k];
		end[run] = run_end;
	}
	ShclVecUnit wasR = units_of(a, &was), isR = units_of(a, &now);
	ShclVecUnit wasU = group_units(a, &wasR, owner, n + 2), isU = group_units(a, &isR, owner, n + 2);
	/* Each source line's group in the loaded text, and the lines it stands
	   for, through its last run's. */
	size_t *at = (size_t *)arena_alloc(a, (n + 2) * sizeof(size_t));
	for (size_t k = 0; k < n + 2; k++) at[k] = NIL;
	for (size_t i = 0; i < wasU.len; i++) {
		const ShclUnit *g = &wasU.data[i];
		if (g->line == 0 || g->line > n) continue;
		at[g->line] = i;
		for (size_t r = g->part_from; r < g->part_to; r++) {
			size_t rl = wasR.data[r].line;
			if (rl != 0 && rl <= n && end[owner[rl]] > end[g->line]) end[g->line] = end[owner[rl]];
		}
	}
	ShclVecSize claimed = {0};
	for (size_t l = 1; l <= n; l++) if (at[l] != NIL) ShclVecSize_push(a, &claimed, l);
	/* The first group after each one's lines, for telling two that sat next to
	   each other. */
	size_t *next = (size_t *)arena_alloc(a, (n + 2) * sizeof(size_t));
	memset(next, 0, (n + 2) * sizeof(size_t));
	for (size_t k = 0; k < claimed.len; k++) {
		size_t l = claimed.data[k], lo = 0, hi = claimed.len;
		while (lo < hi) { size_t mid = (lo + hi) / 2; if (claimed.data[mid] <= end[l]) lo = mid + 1; else hi = mid; }
		next[l] = lo < claimed.len ? claimed.data[lo] : n + 1;
	}
	/* A line no group stands for, as a repeat the load folded away, goes out
	   only as it was written, between two kept groups or at either end. One
	   that is not blank and is left out makes the save fall back, since every
	   line no edit touched has to come back (20260925c item 1). */
	unsigned char *left = (unsigned char *)arena_alloc(a, n + 2);
	memset(left, 0, n + 2);
	for (size_t k = 1; k <= n; k++) left[k] = !kl_blank(KL_LINE(k));
	for (size_t k = 0; k < claimed.len; k++)
		for (size_t l = claimed.data[k]; l <= end[claimed.data[k]] && l <= n; l++) left[l] = 0;
	/* Which source lines went out as written. Every line the load dropped has
	   to, or the save falls back: a rewritten group can span one, as a stacked
	   list over a refused element (20260926 item 1). */
	unsigned char *wrote = (unsigned char *)arena_alloc(a, n + 2);
	memset(wrote, 0, n + 2);
	/* New lines end the way most of the file's lines do. */
	const char *eol = majority_eol(body);
	/* One level of the source's indent: a line one level in, or failing that
	   the first indented line, a list element or a fence. */
	ShclStr step = s_lit("\t");
	int found = 0;
	for (size_t i = 0; i < wasR.len && !found; i++) {
		const ShclUnit *u = &wasR.data[i];
		if (u->line == 0 || u->line > n || tabs_of(s_slice(wasS, u->start, wasS.n)) != 1) continue;
		ShclStr ind = leading_ws(KL_LINE(u->line));
		if (ind.n) { step = ind; found = 1; }
	}
	for (size_t l = 1; l <= n && !found; l++) {
		if (kl_blank(KL_LINE(l))) continue;
		ShclStr ind = leading_ws(KL_LINE(l));
		if (ind.n) { step = ind; found = 1; }
	}
	ShclSB ob = {0, 0, 0};
	sb_reserve(a, &ob, src.n + nowS.n / 8 + 1);
	sb_putS(a, &ob, s_slice(src, 0, bom));
	ShclVecIndent indents = {0};
	{ ShclIndent top; top.has = 1; top.s = s_empty(); ShclVecIndent_push(a, &indents, top); }
	/* The line of the group just written while it is a source one, and the
	   end of the last source group met, kept or not. */
	size_t prev = 0, reach = 0;
	/* The last kept group whose following lines are still to go out. */
	size_t owed = 0;
	for (size_t i = 0; i < isU.len; i++) {
		const ShclUnit *u = &isU.data[i];
		size_t l = u->line;
		int known = l != 0 && l <= n && at[l] != NIL;
		if (known) {
			/* The canonical form writes this above a source line that sat above
			   it: blocks folded together from two places, or a selector's child
			   under an earlier block. Keeping some of the lines would move the
			   others, so the save falls back. */
			if (l <= reach) return 0;
			reach = end[l];
		}
		const ShclUnit *from = known ? &wasU.data[at[l]] : NULL;
		int same = from && s_eq(s_slice(wasS, from->start, from->end), s_slice(nowS, u->start, u->end));
		ShclStr spliced = s_empty();
		size_t splice_at = 0;
		int has_splice = from && !same && splice_group(a, &lines, &was, &wasR, from, &now, &isR, u, &splice_at, &spliced);
		int kept = same || has_splice;
		/* The blank lines above a group stay while it has a blank before it.
		   The canonical form can write that blank inside a kept group, as a
		   dotted line's child's, while the source has it above. */
		int blanks_stay = u->blanks > 0;
		for (size_t r = u->part_from + 1; kept && r < u->part_to; r++) if (isR.data[r].blanks > 0) blanks_stay = 1;
		/* Between two groups that stay next to each other, the source's own
		   lines: a repeat the load folded away stays, and so do the blank
		   lines. The same before the first group. Before any other group from
		   the source, its own blank lines. */
		if (ob.len > bom && ob.data[ob.len - 1] != '\n') sb_puts(a, &ob, eol);
		size_t depth = tabs_of(s_slice(nowS, u->start, u->end));
		if (owed != 0) {
			int pay;
			if (known) pay = !(kept && prev == owed && next[prev] == l);
			else {
				ShclStr ind = indent_for(a, &indents, depth, step);
				size_t k = end[owed] + 1;
				while (k < next[owed] && !left[k]) k++;
				pay = 0;
				if (k < next[owed]) {
					ShclStr li = leading_ws(KL_LINE(k));
					pay = ind.n <= li.n || (li.n && memcmp(ind.p, li.p, li.n) != 0);
				}
			}
			if (pay) {
				kl_flush(a, &ob, &lines, left, wrote, end[owed] + 1, next[owed]);
				if (ob.len > bom && ob.data[ob.len - 1] != '\n') sb_puts(a, &ob, eol);
				owed = 0;
			}
		}
		if (known) owed = 0;
		if (i == 0) {
			if (kept && claimed.len && claimed.data[0] == l)
				for (size_t k = 1; k < l; k++) { sb_putS(a, &ob, KL_LINE(k)); wrote[k] = 1; left[k] = 0; }
		} else if (kept && prev != 0 && next[prev] == l) {
			int blanks = 0;
			for (size_t k = end[prev] + 1; k < l; k++) if (kl_blank(KL_LINE(k))) blanks = 1;
			for (size_t k = end[prev] + 1; k < l; k++)
				if (blanks_stay || !kl_blank(KL_LINE(k))) { sb_putS(a, &ob, KL_LINE(k)); wrote[k] = 1; left[k] = 0; }
			if (!blanks) for (size_t k = 0; k < u->blanks; k++) sb_puts(a, &ob, eol);
		} else if (known && blanks_stay && l > 1 && kl_blank(KL_LINE(l - 1))) {
			size_t k = l - 1;
			while (k > 1 && kl_blank(KL_LINE(k - 1))) k--;
			for (; k < l; k++) sb_putS(a, &ob, KL_LINE(k));
		} else {
			for (size_t k = 0; k < u->blanks; k++) sb_puts(a, &ob, eol);
		}
		if (kept) {
			/* A spliced line's value replaces the lines it took, as a stacked
			   list's elements. */
			for (size_t k = l; k <= end[l]; k++) {
				if (has_splice && k == splice_at) { sb_putS(a, &ob, spliced); k = owns[k]; }
				else { sb_putS(a, &ob, KL_LINE(k)); wrote[k] = 1; }
			}
			/* A line kept as written holds no level's indent. */
			if (!(u->start + depth < nowS.n && nowS.p[u->start + depth] == ' '))
				note_indent(a, &indents, depth, leading_ws(KL_LINE(wasR.data[from->part_from].line)));
			prev = l;
			owed = l;
		} else {
			/* A binding the edits rewrote keeps its line's indent and name. */
			size_t start = u->start;
			if (known && u->part_to - u->part_from == 1) {
				size_t first = line_end(nowS, u->start);
				ShclStr head;
				if (authored_head(a, KL_LINE(l), s_slice(nowS, u->start, first - 1), &head)) {
					sb_putS(a, &ob, head);
					/* A changed line keeps its own line ending. */
					const char *own_eol = eol_of(KL_LINE(l));
					sb_puts(a, &ob, *own_eol ? own_eol : eol);
					note_indent(a, &indents, depth, leading_ws(KL_LINE(l)));
					start = first;
				}
			}
			write_run(a, &ob, &now, start, u->end, &indents, step, eol);
			prev = 0;
		}
	}
	if (owed != 0) {
		if (ob.len > bom && ob.data[ob.len - 1] != '\n') sb_puts(a, &ob, eol);
		kl_flush(a, &ob, &lines, left, wrote, end[owed] + 1, n + 1);
	}
	/* The blank lines the source ends with stay at the end. */
	if (ob.len > bom && ob.data[ob.len - 1] != '\n') sb_puts(a, &ob, eol);
	size_t tail = 1;
	for (size_t k = 0; k < claimed.len; k++) {
		size_t t = end[claimed.data[k]] + 1;
		if (t > tail) tail = t;
	}
	int all_blank = 1;
	for (size_t k = tail; k <= n; k++) if (!kl_blank(KL_LINE(k))) all_blank = 0;
	if (ob.len > bom && all_blank) for (size_t k = tail; k <= n; k++) sb_putS(a, &ob, KL_LINE(k));
	for (size_t k = 1; k <= n; k++) if (left[k]) return 0;
	for (size_t k = 0; k < ld->dropped.len; k++) if (!wrote[ld->dropped.data[k]]) return 0;
	/* So does a last line with no newline. The line that ends the text now
	   can be one kept with the other line ending. */
	if (body.n && body.p[body.n - 1] != '\n') ob.len -= strlen(eol_of(sb_S(&ob)));
	#undef KL_LINE
	ShclStr text = sb_S(&ob);
	/* The reload has to be the document, and it may not load with an error
	   the source did not have: a child the edits gave an element list that
	   stayed stacked reads back the same and is E001 (20260925b item 1). A line
	   the load dropped went out as written, and the reload has to drop each one
	   again: one that now binds, even to the same document, reads differently
	   from how the file had it. */
	shcl_doc *back = own->back = do_parse(text.p, text.n, d->strictness, 0, 0, 0, 0);
	if (!back) arena_panic(panic);
	doc_guard(back, panic);
	if (back->lost != ld->lost || !s_eq(emit_canonical(back), nowS) || !errors_within(a, back, ld)) return 0;
	*out = text;
	return 1;
}

/* The text a keep-lines save writes, and whether it kept the lines: the
   canonical form when there is no source or the lines would not reload the
   same. *out lives in d's scratch or arena, until the next call on d. */
static int keep_text(shcl_doc *d, ShclStr *out) {
	/* The reparse check cannot see a kept line gone from both the tree and the
	   text, so falling back leaves it to the lost-count gate. */
	if (!d->has_source || kept_shortfall(d) > 0) { *out = emit_canonical(d); return 0; }
	ShclKeepOwn *volatile own = (ShclKeepOwn *)calloc(1, sizeof *own);
	if (!own) { SHCL_OOM(); abort(); }
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		ShclKeepOwn *bad = own;
		shcl_free(bad->loaded); shcl_free(bad->back); free(bad);
		doc_guard(d, NULL);
		SHCL_OOM();
		abort();
	}
	doc_guard(d, &panic);
	int kept = keep_lines(d, own, &panic, out);
	doc_guard(d, NULL);
	ShclKeepOwn *done = own;
	shcl_free(done->loaded); shcl_free(done->back); free(done);
	if (!kept) *out = emit_canonical(d);
	return kept;
}

shcl_str shcl_to_text_keep_lines(shcl_doc *d, int *kept) {
	ShclStr t;
	int k = keep_text(d, &t);
	if (kept) *kept = k;
	return s_dup(&d->reads, t);
}

/* Keep a copy of the loaded text on the document, or nothing when the text is
   already its canonical form. A failed copy frees it and answers NULL, the way
   a failed parse does. */
static void keep_source_in(shcl_doc *k, ShclStr t) {
	k->source = s_eq(emit_canonical(k), t) ? s_empty() : s_dup(&k->arena, t);
	k->has_source = 1;
}
/* The recovery path reads only the volatile carrier, so -Wclobbered's guess
   about the arguments is wrong here the way it is for do_parse. */
#if defined(__GNUC__) && !defined(__clang__)
	#pragma GCC diagnostic push
	#pragma GCC diagnostic ignored "-Wclobbered"
#endif
static shcl_doc *keep_source(shcl_doc *parsed, const char *text, size_t len) {
	shcl_doc *volatile d = parsed;
	if (!d) return NULL;
	ShclStr t; t.p = text ? text : ""; t.n = len;
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		shcl_doc *bad = d;
		shcl_free(bad);
		return NULL;
	}
	doc_guard(d, &panic);
	shcl_doc *k = d;
	keep_source_in(k, t);
	doc_guard(k, NULL);
	return k;
}
#if defined(__GNUC__) && !defined(__clang__)
	#pragma GCC diagnostic pop
#endif

shcl_doc *shcl_parse_keep_lines(const char *text, size_t len, shcl_strictness s) {
	return keep_source(shcl_parse_with(text, len, s), text, len);
}

// --- format helpers + remaining public API ----------------------------------

// Whether a decimal spelling reads back as exactly v, decided with integer
// arithmetic rather than strtod: more than one C runtime (msvcrt, and wine's)
// parses some 15-digit spellings one ulp off, and a spelling that only reads
// back on a correct libc is not a spelling every binding agrees on. A double
// is m * 2^e; a decimal d * 10^k reads back when it sits inside v's rounding
// interval, half a spacing each way, except below a power of two where the
// spacing halves. A midpoint reads back only when m is even (ties to even).
// Both ends are scaled to integers by 2^S * 10^T once per value; a candidate
// then costs one small multiply and a shift before the compare.
typedef struct { uint32_t w[96]; int n; } ShclBig;
static void big_set(ShclBig *b, uint64_t v) { memset(b, 0, sizeof *b); b->w[0] = (uint32_t)v; b->w[1] = (uint32_t)(v >> 32); b->n = b->w[1] ? 2 : (b->w[0] ? 1 : 0); }
static void big_mul_small(ShclBig *b, uint32_t m) {
	uint64_t carry = 0;
	for (int i = 0; i < b->n; i++) { uint64_t t = (uint64_t)b->w[i] * m + carry; b->w[i] = (uint32_t)t; carry = t >> 32; }
	if (carry && b->n < (int)(sizeof b->w / sizeof b->w[0])) b->w[b->n++] = (uint32_t)carry;
}
static void big_mul_pow10(ShclBig *b, int t) {
	static const uint32_t p10[9] = { 1u, 10u, 100u, 1000u, 10000u, 100000u, 1000000u, 10000000u, 100000000u };
	for (; t >= 9; t -= 9) big_mul_small(b, 1000000000u);
	if (t > 0 && t < 9) big_mul_small(b, p10[t]);
}
static void big_shl(ShclBig *b, int bits) {
	int limbs = bits / 32, cap = (int)(sizeof b->w / sizeof b->w[0]);
	if (limbs && b->n) {
		if (b->n + limbs > cap) limbs = cap - b->n;
		memmove(b->w + limbs, b->w, (size_t)b->n * sizeof b->w[0]);
		memset(b->w, 0, (size_t)limbs * sizeof b->w[0]);
		b->n += limbs;
	}
	if (bits % 32) big_mul_small(b, 1u << (bits % 32));
}
static int big_cmp(const ShclBig *a, const ShclBig *b) {
	if (a->n != b->n) return a->n < b->n ? -1 : 1;
	for (int i = a->n; i-- > 0;) if (a->w[i] != b->w[i]) return a->w[i] < b->w[i] ? -1 : 1;
	return 0;
}
typedef struct { ShclBig lo, hi; int S, T, even; } ShclF64Interval;
// exp10 is the decimal exponent of v's 17-digit spelling: the smallest k any
// shorter spelling can have is exp10 - 16, which fixes T for all of them.
static void f64_interval(double v, int exp10, ShclF64Interval *iv) {
	uint64_t bits; memcpy(&bits, &v, sizeof bits);
	int E = (int)((bits >> 52) & 0x7FF); uint64_t F = bits & 0xFFFFFFFFFFFFFull;
	uint64_t m = E ? (F | (1ull << 52)) : F; int e = E ? E - 1075 : -1074;
	int above = e - 1, below = (E > 1 && F == 0) ? e - 2 : e - 1;   // log2 of each half-width
	iv->S = below < 0 ? -below : 0;
	iv->T = exp10 - 16 < 0 ? 16 - exp10 : 0;
	iv->even = (m & 1) == 0;
	// v -+ 2^x = (m * 2^(e-x) -+ 1) * 2^x, and e - x is 1 or 2.
	big_set(&iv->lo, (m << (e - below)) - 1); big_shl(&iv->lo, below + iv->S); big_mul_pow10(&iv->lo, iv->T);
	big_set(&iv->hi, (m << (e - above)) + 1); big_shl(&iv->hi, above + iv->S); big_mul_pow10(&iv->hi, iv->T);
}
static int f64_reads_back(const char *tmp, const ShclF64Interval *iv) {
	// The spelling: digits then an exponent, sign already known to match v.
	const char *s = tmp; if (*s == '-' || *s == '+') s++;
	uint64_t d = 0; int nd = 0;
	for (; *s && *s != 'e' && *s != 'E'; s++) if (*s >= '0' && *s <= '9') { d = d * 10 + (uint64_t)(*s - '0'); nd++; }
	if (!nd || *s == '\0') return 0;
	int k = atoi(s + 1) - (nd - 1);
	if (k + iv->T < 0) return 0;
	ShclBig D; big_set(&D, d); big_mul_pow10(&D, k + iv->T); big_shl(&D, iv->S);
	int cl = big_cmp(&D, &iv->lo), ch = big_cmp(&D, &iv->hi);
	if (cl > 0 && ch < 0) return 1;
	return (cl == 0 || ch == 0) && iv->even;
}

// The correctly rounded string at a precision is the closest one, but at a
// power of two the rounding interval is lopsided, and the neighbor one digit
// up or down can read back while the closest does not. The shortest-digits
// algorithms the other bindings use find it; stepping the last digit of the
// "%.*e" text in tmp by delta (with carry) and reading it back does the same.
// A carry past the leading digit is a shorter spelling, already tried.
static int f64_neighbor(const char *tmp, const ShclF64Interval *iv, int delta, char *out) {
	memcpy(out, tmp, strlen(tmp) + 1);
	char *e = strchr(out, 'e');
	if (!e || e == out) return 0;
	char *p = e - 1;
	for (;;) {
		if (*p >= '0' && *p <= '9') {
			int d = *p - '0' + delta;
			if (d >= 0 && d <= 9) { *p = (char)('0' + d); break; }
			*p = (char)(d < 0 ? '9' : '0');
		}
		if (p == out) return 0;
		p--;
	}
	if (*(out[0] == '-' ? out + 1 : out) == '0') return 0;
	return f64_reads_back(out, iv);
}

size_t shcl_format_float(double v, char *out) {
	if (isnan(v)) { memcpy(out, "NaN", 3); return 3; }
	if (isinf(v)) { if (v < 0) { memcpy(out, "-inf", 4); return 4; } memcpy(out, "inf", 3); return 3; }
	if (v == 0.0) { if (signbit(v)) { memcpy(out, "-0", 2); return 2; } out[0] = '0'; return 1; }
	char tmp[64], alt[64]; int prec;
	// A locale's decimal point is whatever it is; the digit walks skip it.
	ShclF64Interval iv;
	snprintf(tmp, sizeof tmp, "%.16e", v);
	f64_interval(v, atoi(strchr(tmp, 'e') + 1), &iv);
	for (prec = 1; prec <= 17; prec++) {
		snprintf(tmp, sizeof tmp, "%.*e", prec - 1, v);
		if (f64_reads_back(tmp, &iv)) break;
		if (f64_neighbor(tmp, &iv, 1, alt) || f64_neighbor(tmp, &iv, -1, alt)) { memcpy(tmp, alt, sizeof tmp); break; }
	}
	{
		const char *dp = dec_point(); size_t dn = strlen(dp);
		if (dn != 1 || *dp != '.') {
			char *q = strstr(tmp, dp);
			if (q) { *q = '.'; memmove(q + 1, q + dn, strlen(q + dn) + 1); }
		}
	}
	const char *s = tmp; int neg = 0;
	if (*s == '-') { neg = 1; s++; } else if (*s == '+') s++;
	char digits[24]; int nd = 0;
	digits[nd++] = *s++;
	if (*s == '.') { s++; while (*s >= '0' && *s <= '9') digits[nd++] = *s++; }
	int E = 0;
	if (*s == 'e' || *s == 'E') { s++; int es = 1; if (*s == '-') { es = -1; s++; } else if (*s == '+') s++; while (*s >= '0' && *s <= '9') { E = E * 10 + (*s - '0'); s++; } E *= es; }
	int pointPos = E + 1;
	char *o = out; if (neg) *o++ = '-';
	if (pointPos <= 0) { *o++ = '0'; *o++ = '.'; for (int z = 0; z < -pointPos; z++) *o++ = '0'; for (int k = 0; k < nd; k++) *o++ = digits[k]; }
	else if (pointPos >= nd) { for (int k = 0; k < nd; k++) *o++ = digits[k]; for (int z = 0; z < pointPos - nd; z++) *o++ = '0'; }
	else { for (int k = 0; k < pointPos; k++) *o++ = digits[k]; *o++ = '.'; for (int k = pointPos; k < nd; k++) *o++ = digits[k]; }
	return (size_t)(o - out);
}
size_t shcl_datetime_str(const shcl_datetime *dt, char *out) {
	// Every field is public, so a hand-built struct can have values parsing
	// never yields (a -1 sentinel, epoch seconds in sec): render whole into a
	// worst-case local buffer (~109 bytes), then clamp the copy to the
	// documented SHCL_DT_BUF. Parsed values stay under the clamp (<= 56 with
	// the frac cap), so their output is unchanged.
	char b[128];
	char *o = b;
	if (dt->has_date) { o += snprintf(o, sizeof b, "%04d-%02u-%02u", dt->year, dt->month, dt->day); if (dt->has_time) *o++ = 'T'; }
	if (dt->has_time) {
		o += snprintf(o, (size_t)(b + sizeof b - o), "%02u:%02u", dt->hour, dt->minute);
		if (dt->has_sec) o += snprintf(o, (size_t)(b + sizeof b - o), ":%02u", dt->sec);
		if (dt->has_frac) {
			// frac keeps its own cap: the fixed parts plus 30 digits stay
			// inside the clamp for every parsed value.
			size_t fn = dt->frac.n > 30 ? 30 : dt->frac.n;
			*o++ = '.'; memcpy(o, dt->frac.p, fn); o += fn;
		}
	}
	if (dt->zone == SHCL_ZONE_UTC) *o++ = 'Z';
	else if (dt->zone == SHCL_ZONE_OFFSET) {
		// widen before negating: INT32_MIN has no 32-bit negation
		long long off = dt->off_min; char sign = off < 0 ? '-' : '+'; long long ao = off < 0 ? -off : off;
		o += snprintf(o, (size_t)(b + sizeof b - o), "%c%02lld:%02lld", sign, ao / 60, ao % 60);
	}
	size_t n = (size_t)(o - b);
	if (n > SHCL_DT_BUF) n = SHCL_DT_BUF;
	memcpy(out, b, n);
	return n;
}
int shcl_status_code(shcl_status s) {
	switch (s) { case SHCL_GOOD: return 0; case SHCL_EMPTY: return 2; case SHCL_NOT_FOUND: return 3; case SHCL_BAD_TYPE: return 4; case SHCL_MULTIPLE: return 5; }
	return 1;
}
const char *shcl_status_name(shcl_status s) {
	switch (s) { case SHCL_GOOD: return "Good"; case SHCL_EMPTY: return "Empty"; case SHCL_NOT_FOUND: return "NotFound"; case SHCL_BAD_TYPE: return "BadType"; case SHCL_MULTIPLE: return "Multiple"; }
	return "Good";
}
int shcl_status_ok(shcl_status s) { return s == SHCL_GOOD || s == SHCL_EMPTY; }
int shcl_parse_datetime(const char *text, size_t tlen, shcl_datetime *out) {
	/* Its own arena: the internal call splits the text into temporaries, and a
	   standalone caller has no document to lend one. Freed before returning, so
	   nothing here outlives the call. */
	ShclArena a = {0, 0, 0, 0, 0};
	ShclStr t; t.p = text; t.n = tlen;
	shcl_datetime got;
	int ok = parse_datetime(&a, t, &got);
	arena_free(&a);
	if (ok) *out = got;
	return ok;
}

int shcl_strictness_from_arg(const char *s, size_t n, shcl_strictness *out) {
	char buf[16]; if (n >= sizeof buf) return 0;
	for (size_t i = 0; i < n; i++) { unsigned char c = (unsigned char)s[i]; buf[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : (char)c; }
	buf[n] = '\0';
	if (!strcmp(buf, "loose") || !strcmp(buf, "1")) { *out = SHCL_LOOSE; return 1; }
	if (!strcmp(buf, "standard") || !strcmp(buf, "2")) { *out = SHCL_STANDARD; return 1; }
	if (!strcmp(buf, "strict") || !strcmp(buf, "3")) { *out = SHCL_STRICT; return 1; }
	return 0;
}

shcl_doc *shcl_parse(const char *text, size_t len) { return do_parse(text, len, SHCL_STANDARD, 0, 0, 0, 0); }
shcl_doc *shcl_parse_with(const char *text, size_t len, shcl_strictness s) { return do_parse(text, len, s, 0, 0, 0, 0); }
/* Parse with resource caps beside the strictness, for input the consumer does
   not control: a document amplifies to many times its byte size in memory, so
   a size cap alone cannot bound what a load allocates. max_nodes stops the
   parse once a line takes the node count past it - one E020 error, and the
   unparsed remainder counts as lost so a save cannot silently truncate.
   max_elements refuses any line whose array would hold more elements (E021,
   that line alone is skipped). 0 disables a cap, making this shcl_parse_with.
   Both caps are parse-time only; the write API is the consumer's own
   arithmetic. A cap diagnostic is an error, so shcl_error_count answers
   whether a Strict load would have failed; the parsed part stays readable. */
shcl_doc *shcl_parse_limited(const char *text, size_t len, shcl_strictness s, size_t max_nodes, size_t max_elements, size_t max_diags) { return do_parse(text, len, s, max_nodes, max_elements, max_diags, 0); }
void shcl_free(shcl_doc *d) { if (!d) return; shcl_free(d->probe_doc); free(d->nodes.data); free(d->kept_near); arena_free(&d->arena); arena_free(&d->scratch); arena_free(&d->reads); arena_free(&d->index_arena); free(d); }
void shcl_reads_release(shcl_doc *d) { if (d) arena_reset(&d->reads); }
void shcl_compact(shcl_doc *d) {
	if (!d) return;
	/* The copy is off the frame, so the recovery point can give it back: a
	   longjmping SHCL_OOM skips this frame, and every cut-short compaction
	   used to keep the half-built copy for good (20260918b item 22). */
	shcl_doc *volatile fresh = shcl_new();
	if (!fresh) return;
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		shcl_doc *bad = fresh;
		bad->probe_doc = NULL; // d's, never the copy's to free
		shcl_free(bad);
		doc_guard(d, NULL);
		return; // d is left as it was, as the header says
	}
	shcl_doc *n = fresh;
	doc_guard(n, &panic);
	doc_guard(d, &panic);
	ShclArena *a = &n->arena;
	// The tree, root's own trivia included, then everything the load recorded
	// that a save or a strict gate reads off the document.
	const ShclNode *root = &d->nodes.data[ROOT];
	NODE(n, ROOT).blank_before = root->blank_before;
	if (root->trivia) NODE(n, ROOT).trivia = w_clone_trivia(a, root->trivia);
	for (size_t i = 0; i < root->children.len; i++) {
		size_t c = w_clone_subtree(n, d, root->children.data[i], ROOT);
		ShclVecSize_push(a, &NODE(n, ROOT).children, c);
	}
	/* Whole, so a generation fault stays one and the next shcl_generate still
	   drops it (20260926 item 6). */
	for (size_t i = 0; i < d->diags.len; i++) {
		ShclDiag dg = d->diags.data[i];
		dg.message = s_dup(a, dg.message);
		ShclVecDiag_push(a, &n->diags, dg);
	}
	for (size_t i = 0; i < d->orphans.len; i++) ShclVecLead_push(a, &n->orphans, lead_copy(a, &d->orphans.data[i]));
	for (size_t i = 0; i < d->ends.len; i++) ShclVecSize_push(a, &n->ends, d->ends.data[i]);
	n->has_source = d->has_source;
	if (d->has_source) n->source = s_dup(a, d->source);
	n->strictness = d->strictness;
	n->lost = d->lost;
	n->kept_owed = d->kept_owed;
	n->kept = d->kept;
	n->probe_doc = d->probe_doc;
	/* Every node has a new number, so what the last settle recorded names
	   the wrong ones. The copy already cost the document. Before the swap,
	   where a failed allocation still leaves d as it was (20260926 item 3). */
	settle_kept(n);
	doc_guard(n, NULL);
	doc_guard(d, NULL);
	// Swap the rebuilt document in and give the old storage back.
	shcl_doc old = *d;
	*d = *n;
	free(n);
	free(old.nodes.data); free(old.kept_near); arena_free(&old.arena); arena_free(&old.scratch); arena_free(&old.reads); arena_free(&old.index_arena);
}
int shcl_strict_failed(const shcl_doc *d) {
	if (d->strictness != SHCL_STRICT) return 0;
	for (size_t i = 0; i < d->diags.len; i++) if (d->diags.data[i].sev == SHCL_SEV_ERROR) return 1;
	return 0;
}
shcl_strictness shcl_strictness_of(const shcl_doc *d) { return d->strictness; }
size_t shcl_diag_count(const shcl_doc *d) { return d->diags.len; }
size_t shcl_diag_line(const shcl_doc *d, size_t i) { return d->diags.data[i].line; }
shcl_severity shcl_diag_severity(const shcl_doc *d, size_t i) { return d->diags.data[i].sev; }
shcl_str shcl_diag_message(const shcl_doc *d, size_t i) { return d->diags.data[i].message; }
const char *shcl_diag_code(const shcl_doc *d, size_t i) { return d->diags.data[i].code; }

// --- Validator: schema-as-SHCL ----------------------------------------------
// The schema is an ordinary parsed document: a flat list of `field: <path>`
// instances whose children are the constraints (closed vocabulary - see
// spec.md "Schema validation"). Validation reuses the accessor's path scan and
// the typed coercions, so document strictness composes for free. Schema faults
// (V09x) come first and the surviving constraints still check the document;
// the unknown-field sweep skips only when a fault cost a path spelling. One
// line-number space per result.
// Everything (scratch and results) lives in the validation's own arena.

/* scratch: v_unknown's suggestion workspace. On the validation rather than in
   that frame so an allocation failure, which unwinds past it, can free it. */
struct shcl_validation { ShclArena arena, scratch; ShclVecDiag diags; };

static const char *v_schema_types[] = {
	"int", "float", "bool", "string", "datetime", "raw", "duration", "size",
	"int-array", "float-array", "bool-array", "string-array", "datetime-array",
};

typedef enum { ALLOW_INTS, ALLOW_FLOATS, ALLOW_BOOLS, ALLOW_DATES, ALLOW_STRINGS } ShclAllowKind;

typedef struct {
	ShclStr path; // as written in the schema; message text only
	ShclVecSeg segs;
	const char *ty; // member of v_schema_types; NULL = untyped
	int required;
	int has_allowed; ShclAllowKind akind; size_t a_n;
	int64_t *a_ints; double *a_floats; int *a_bools; shcl_datetime *a_dates; ShclStr *a_strs;
	int has_min_i, has_max_i, has_min_f, has_max_f;
	int64_t min_i, max_i; double min_f, max_f;
	/* duration and size: the unit a bare number takes when the field name
	   gives none, base 10 for KB to TB, and the bounds as the schema wrote
	   them, since min_i and max_i hold them in milliseconds or bytes. */
	shcl_duration_unit unit_d; shcl_size_unit unit_s; int decimal;
	ShclStr min_text, max_text;
	int has_repeat; uint64_t rep_lo, rep_hi;
	int reopen;                 // H002 suppressor only; validation ignores it
	ShclStr inherits;           // fragment mounted at this path (subtree shape); .n == 0 = none
	size_t inherits_line; // schema line of the `inherits` key, for V095
	// Generator-only (`shcl init`): validation ignores both. has_* gates them.
	int has_desc; ShclStr desc;
	int has_default; ShclStr default_text;
} ShclVCons;
DEFINE_VEC(ShclVecVCons, ShclVCons)

// An interpreted schema: the top-level constraints plus the named fragments
// their `inherits` keys can mount.
typedef struct { ShclStr name; ShclVecVCons fields; } ShclVFrag;
DEFINE_VEC(ShclVecVFrag, ShclVFrag)
// paths_complete: 0 when a fault cost the schema a path spelling (unreadable
// `field:` path, or a mount naming no declared fragment). Key-level faults
// keep their entry's chain, so only these two classes can turn declared
// fields into false unknowns - the sweep runs unless one of them happened.
/* fmap: fragment name -> index in frags. The other three bindings hold their
   fragments in a map; a linear scan here made the duplicate check quadratic in
   the fragment count, and every mount pays it again. */
typedef struct { ShclVecVCons cons; ShclVecVFrag frags; ShclCMap fmap; int paths_complete; } ShclVSchemaDef;

static size_t v_frag_index(const ShclVSchemaDef *def, ShclStr name) {
	uint64_t h = cmap_hash(name, s_empty());
	for (ShclCMapEnt *e = cmap_first(&def->fmap, h); e; e = cmap_next(e, h))
		if (s_eq(def->frags.data[e->val].name, name)) return e->val;
	return SIZE_MAX;
}

static const ShclVecVCons *v_frag_get(const ShclVSchemaDef *def, ShclStr name) {
	size_t i = v_frag_index(def, name);
	return i == SIZE_MAX ? NULL : &def->frags.data[i].fields;
}

static void v_diag(ShclArena *a, ShclVecDiag *out, size_t line, const char *code, ShclStr msg) {
	ShclDiag dg; dg.line = line; dg.sev = SHCL_SEV_ERROR; dg.message = msg; dg.code = code; dg.generated = 0;
	ShclVecDiag_push(a, out, dg);
}
static ShclStr v_msgz(ShclArena *a, const char *z) { ShclStr s; s.p = z; s.n = strlen(z); return s_dup(a, s); }
/* Schema text for a diagnostic or a generated comment: a path or a type as the
   schema wrote it, with a line break written `\n`, so one diagnostic stays one
   line. Only the break is escaped, so a path reads the way it was written. */
static ShclStr schema_text(ShclArena *a, ShclStr s) {
	int has = 0;
	for (size_t k = 0; k < s.n; k++) if (s.p[k] == '\n') { has = 1; break; }
	if (!has) return s;
	ShclSB b = {0, 0, 0};
	for (size_t k = 0; k < s.n; k++) {
		if (s.p[k] == '\n') sb_puts(a, &b, "\\n");
		else sb_putc(a, &b, s.p[k]);
	}
	return sb_S(&b);
}
static ShclStr v_msg3(ShclArena *a, const char *pre, ShclStr mid, const char *post) {
	ShclSB s = {0, 0, 0};
	sb_puts(a, &s, pre); sb_putS(a, &s, mid); sb_puts(a, &s, post);
	return sb_S(&s);
}
static ShclStr v_msg_key(ShclArena *a, const char *key) {
	ShclSB s = {0, 0, 0};
	sb_puts(a, &s, "bad schema constraint '"); sb_puts(a, &s, key); sb_puts(a, &s, "'");
	return sb_S(&s);
}

// One scalar constraint value, or 0.
static int v_single_text(const ShclValue *v, ShclStr *out) {
	if (v->kind != V_CELL || v->nels != 1) return 0;
	*out = v->els[0].text;
	return 1;
}

/* Two datetimes naming the same moment, whatever the spelling. The struct
   mirrors what was written, so 12:00:00Z and 12:00:00+00:00 are different values
   field by field while naming one time, and 12:00:00 and 12:00:00.0 differ only
   in written precision. A [value] selector matches on text, but an allowed set
   is about the value, so it compares here. An absent zone is local and matches
   no zone at all - that is the one spelling difference that is a real
   difference. */
static ShclStr v_frac_key(ShclStr f) {
	while (f.n && f.p[f.n - 1] == '0') f.n--;
	return f;
}
/* Days since 1970-01-01 for a civil date, negative before it. */
static int64_t v_days_from_civil(int32_t y, uint32_t m, uint32_t d) {
	int64_t yy = m <= 2 ? (int64_t)y - 1 : (int64_t)y;
	int64_t era = (yy >= 0 ? yy : yy - 399) / 400;
	int64_t yoe = yy - era * 400;
	int64_t doy = (153 * (int64_t)((m + 9) % 12) + 2) / 5 + (int64_t)d - 1;
	int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	return era * 146097 + doe - 719468;
}
/* A zoned value as an instant: the written clock less its offset, the date
   carrying the day wrap. A time alone lives on a 24-hour cycle. */
static int64_t v_moment_minutes(const shcl_datetime *x, int32_t off) {
	int64_t hm = (x->has_time ? (int64_t)x->hour * 60 + x->minute : 0) - off;
	if (x->has_date) return v_days_from_civil(x->year, x->month, x->day) * 1440 + hm;
	return ((hm % 1440) + 1440) % 1440;
}
static int v_same_moment(const shcl_datetime *x, const shcl_datetime *y) {
	if (x->has_date != y->has_date || x->has_time != y->has_time) return 0;
	if (x->has_time && (x->has_sec != y->has_sec || (x->has_sec && x->sec != y->sec))) return 0;
	{
		ShclStr a; a.p = x->has_frac ? x->frac.p : ""; a.n = x->has_frac ? x->frac.n : 0;
		ShclStr b; b.p = y->has_frac ? y->frac.p : ""; b.n = y->has_frac ? y->frac.n : 0;
		if (!s_eq(v_frac_key(a), v_frac_key(b))) return 0;
	}
	{
		int xh = x->zone != SHCL_ZONE_NONE, yh = y->zone != SHCL_ZONE_NONE;
		if (xh != yh) return 0;
		if (!xh) {
			if (x->has_date && (x->year != y->year || x->month != y->month || x->day != y->day)) return 0;
			if (x->has_time && (x->hour != y->hour || x->minute != y->minute)) return 0;
			return 1;
		}
		int xo = x->zone == SHCL_ZONE_OFFSET ? x->off_min : 0;
		int yo = y->zone == SHCL_ZONE_OFFSET ? y->off_min : 0;
		return v_moment_minutes(x, xo) == v_moment_minutes(y, yo);
	}
}

// One `field:` instance (top-level or inside a fragment) -> a constraint into
// *out. Zero return = faults were reported and the constraint is dropped.
static int v_parse_field(ShclArena *a, shcl_doc *schema, size_t f, ShclVecDiag *faults, ShclVCons *out) {
	ShclNode *node = &NODE(schema, f);
	ShclStr path;
	if (!v_single_text(&node->value, &path)) {
		v_diag(a, faults, node->line, "V093", v_msgz(a, "bad schema path"));
		return 0;
	}
	ShclPathScan ps = scan_lookup(a, path);
	if (!ps.ok || ps.has_value) {
		v_diag(a, faults, node->line, "V093", v_msg3(a, "bad schema path: ", schema_text(a, path), ""));
		return 0;
	}
	ShclVCons c; memset(&c, 0, sizeof c);
	c.path = path; c.segs = ps.segs;
	// Deferred so `min: 1` may precede `type: int` in the file.
	int required = -1;
	int reopen_seen = 0;
	size_t allowed_at = (size_t)-1, min_at = (size_t)-1, max_at = (size_t)-1, default_at = (size_t)-1;
	size_t unit_at = (size_t)-1, decimal_key_at = (size_t)-1;
	ShclVecSize kids = NODE(schema, f).children;
	for (size_t ki = 0; ki < kids.len; ki++) {
		ShclNode *kid = &NODE(schema, kids.data[ki]);
		if (v_is_empty(&kid->value)) continue; // dangling key: treated as absent
		if (s_eq(kid->name, s_lit("type"))) {
			ShclStr t;
			int ok = v_single_text(&kid->value, &t);
			const char *canon = NULL;
			if (ok) {
				ShclStr low = ascii_lower(a, t);
				for (size_t x = 0; x < sizeof v_schema_types / sizeof v_schema_types[0]; x++)
					if (s_eq(low, s_lit(v_schema_types[x]))) { canon = v_schema_types[x]; break; }
				if (canon) {
					if (c.ty) v_diag(a, faults, kid->line, "V092", v_msg_key(a, "type"));
					else c.ty = canon;
				} else {
					v_diag(a, faults, kid->line, "V091", v_msg3(a, "unknown schema type '", schema_text(a, low), "'"));
				}
			} else {
				v_diag(a, faults, kid->line, "V092", v_msg_key(a, "type"));
			}
		} else if (s_eq(kid->name, s_lit("required"))) {
			ShclStr t; int b = 0;
			int ok = v_single_text(&kid->value, &t) && parse_bool_text(a, t, SHCL_STANDARD, &b);
			if (ok && required < 0) required = b;
			else v_diag(a, faults, kid->line, "V092", v_msg_key(a, "required"));
		} else if (s_eq(kid->name, s_lit("reopen"))) {
			/* Consumed by the H002 suppressor; validation itself ignores it,
			   but a bad value still faults so a typo cannot silently disavow
			   nothing. */
			ShclStr t; int b = 0;
			int ok = v_single_text(&kid->value, &t) && parse_bool_text(a, t, SHCL_STANDARD, &b);
			if (ok && !reopen_seen) { reopen_seen = 1; c.reopen = b; }
			else v_diag(a, faults, kid->line, "V092", v_msg_key(a, "reopen"));
		} else if (s_eq(kid->name, s_lit("allowed"))) {
			if (kid->value.kind == V_CELL && allowed_at == (size_t)-1) allowed_at = kids.data[ki];
			else v_diag(a, faults, kid->line, "V092", v_msg_key(a, "allowed"));
		} else if (s_eq(kid->name, s_lit("min"))) {
			if (kid->value.kind == V_CELL && kid->value.nels == 1 && min_at == (size_t)-1) min_at = kids.data[ki];
			else v_diag(a, faults, kid->line, "V092", v_msg_key(a, "min"));
		} else if (s_eq(kid->name, s_lit("max"))) {
			if (kid->value.kind == V_CELL && kid->value.nels == 1 && max_at == (size_t)-1) max_at = kids.data[ki];
			else v_diag(a, faults, kid->line, "V092", v_msg_key(a, "max"));
		} else if (s_eq(kid->name, s_lit("unit"))) {
			if (kid->value.kind == V_CELL && kid->value.nels == 1 && unit_at == (size_t)-1) unit_at = kids.data[ki];
			else v_diag(a, faults, kid->line, "V092", v_msg_key(a, "unit"));
		} else if (s_eq(kid->name, s_lit("decimal"))) {
			ShclStr t; int b = 0;
			int ok = v_single_text(&kid->value, &t) && parse_bool_text(a, t, SHCL_STANDARD, &b);
			if (ok && decimal_key_at == (size_t)-1) { decimal_key_at = kids.data[ki]; c.decimal = b; }
			else v_diag(a, faults, kid->line, "V092", v_msg_key(a, "decimal"));
		} else if (s_eq(kid->name, s_lit("repeat"))) {
			if (kid->value.kind == V_CELL && !c.has_repeat && (kid->value.nels == 1 || kid->value.nels == 2)) {
				uint64_t lo, hi;
				if (parse_u64(kid->value.els[0].text, &lo) && parse_u64(kid->value.els[kid->value.nels - 1].text, &hi) && lo <= hi) {
					c.has_repeat = 1; c.rep_lo = lo; c.rep_hi = hi;
				} else {
					v_diag(a, faults, kid->line, "V092", v_msg_key(a, "repeat"));
				}
			} else {
				v_diag(a, faults, kid->line, "V092", v_msg_key(a, "repeat"));
			}
		} else if (s_eq(kid->name, s_lit("inherits"))) {
			ShclStr t;
			if (v_single_text(&kid->value, &t) && t.n && c.inherits.n == 0) {
				c.inherits = t; c.inherits_line = kid->line;
			} else {
				v_diag(a, faults, kid->line, "V092", v_msg_key(a, "inherits"));
			}
		} else if (s_eq(kid->name, s_lit("desc"))) {
			// Generator-only (`shcl init`); validation ignores it. First wins.
			// A comma in a sentence makes the value several elements, and the
			// comment is prose: take them all, kept as written.
			if (!c.has_desc && kid->value.kind == V_CELL) {
				ShclSB s = {0, 0, 0};
				for (size_t x = 0; x < kid->value.nels; x++) { if (x) sb_puts(a, &s, ", "); sb_putS(a, &s, kid->value.els[x].text); }
				c.has_desc = 1; c.desc = sb_S(&s);
			}
		} else if (s_eq(kid->name, s_lit("default"))) {
			if (!c.has_default) {
				if (kid->value.kind == V_CELL) {
					c.has_default = 1; c.default_text = emit_cell(a, kid->value.els, kid->value.nels);
				}
				default_at = kids.data[ki];
			}
		} else {
			v_diag(a, faults, kid->line, "V090", v_msg3(a, "unknown schema key '", diag_name(a, kid->name), "'"));
		}
	}
	c.required = required > 0;
	/* A raw block has no inline spelling, so a `default` that is one cannot
	   reach a generated line - it used to be dropped and the field emitted with
	   no value at all - and a `default` under `type: raw` goes out inline and
	   then fails its own type check. */
	if (default_at != (size_t)-1) {
		const ShclNode *dkid = &schema->nodes.data[default_at];
		int raw_typed = c.ty && !strcmp(c.ty, "raw");
		if (dkid->value.kind == V_RAW || (raw_typed && c.has_default))
			v_diag(a, faults, dkid->line, "V092", v_msg_key(a, "default"));
	}
	const char *base = c.ty ? c.ty : "string";
	size_t blen = strlen(base);
	if (blen > 6 && memcmp(base + blen - 6, "-array", 6) == 0) {
		// Base kind name, without the -array suffix (still a literal member).
		for (size_t x = 0; x < sizeof v_schema_types / sizeof v_schema_types[0]; x++)
			if (strlen(v_schema_types[x]) == blen - 6 && memcmp(v_schema_types[x], base, blen - 6) == 0) { base = v_schema_types[x]; break; }
	}
	int is_duration = strcmp(base, "duration") == 0, is_size = strcmp(base, "size") == 0;
	/* `unit` and `decimal` belong to the types that read a bare number in
	   one, and a unit has to be one that type takes. */
	if (unit_at != (size_t)-1) {
		ShclNode *kid = &NODE(schema, unit_at);
		ShclStr t = kid->value.els[0].text;
		if (is_duration) c.unit_d = shcl_duration_unit_of(t.p, t.n);
		if (is_size) c.unit_s = shcl_size_unit_of(t.p, t.n);
		if (c.unit_d == SHCL_DURATION_NONE && c.unit_s == SHCL_SIZE_NONE) v_diag(a, faults, kid->line, "V092", v_msg_key(a, "unit"));
	}
	if (decimal_key_at != (size_t)-1 && !is_size) {
		v_diag(a, faults, NODE(schema, decimal_key_at).line, "V092", v_msg_key(a, "decimal"));
		c.decimal = 0;
	}
	if (allowed_at != (size_t)-1) {
		ShclNode *kid = &NODE(schema, allowed_at);
		ShclElement *els = kid->value.els; size_t n = kid->value.nels;
		// Schema values are read at Standard; only the document's values
		// coerce at the document's strictness.
		int ok = 1;
		c.a_n = n;
		if (strcmp(base, "int") == 0) {
			c.akind = ALLOW_INTS;
			c.a_ints = (int64_t *)arena_alloc(a, (n ? n : 1) * sizeof(int64_t));
			for (size_t x = 0; x < n && ok; x++) ok = parse_int_text(a, &els[x], SHCL_STANDARD, &c.a_ints[x]);
		} else if (strcmp(base, "float") == 0) {
			c.akind = ALLOW_FLOATS;
			c.a_floats = (double *)arena_alloc(a, (n ? n : 1) * sizeof(double));
			for (size_t x = 0; x < n && ok; x++) ok = parse_float_text(a, &els[x], SHCL_STANDARD, &c.a_floats[x]);
		} else if (strcmp(base, "bool") == 0) {
			c.akind = ALLOW_BOOLS;
			c.a_bools = (int *)arena_alloc(a, (n ? n : 1) * sizeof(int));
			for (size_t x = 0; x < n && ok; x++) ok = parse_bool_text(a, els[x].text, SHCL_STANDARD, &c.a_bools[x]);
		} else if (strcmp(base, "datetime") == 0) {
			c.akind = ALLOW_DATES;
			c.a_dates = (shcl_datetime *)arena_alloc(a, (n ? n : 1) * sizeof(shcl_datetime));
			for (size_t x = 0; x < n && ok; x++) ok = parse_datetime(a, els[x].text, &c.a_dates[x]);
		} else if (strcmp(base, "raw") == 0 || is_duration || is_size) {
			/* A raw body has no element space to enumerate, and a duration or
			   size is bounded with min and max rather than listed. */
			ok = 0;
		} else {
			c.akind = ALLOW_STRINGS;
			c.a_strs = (ShclStr *)arena_alloc(a, (n ? n : 1) * sizeof(ShclStr));
			for (size_t x = 0; x < n; x++) c.a_strs[x] = els[x].text;
		}
		if (ok) c.has_allowed = 1;
		else v_diag(a, faults, kid->line, "V092", v_msg_key(a, "allowed"));
	}
	for (int mm = 0; mm < 2; mm++) {
		int is_min = mm == 0;
		size_t at = is_min ? min_at : max_at;
		if (at == (size_t)-1) continue;
		ShclNode *kid = &NODE(schema, at);
		const ShclElement *el = &kid->value.els[0];
		const char *key = is_min ? "min" : "max";
		if (strcmp(base, "int") == 0) {
			int64_t v;
			if (parse_int_text(a, el, SHCL_STANDARD, &v)) {
				if (is_min) { c.has_min_i = 1; c.min_i = v; }
				else { c.has_max_i = 1; c.max_i = v; }
			} else v_diag(a, faults, kid->line, "V092", v_msg_key(a, key));
		} else if (strcmp(base, "float") == 0) {
			double v;
			if (parse_float_text(a, el, SHCL_STANDARD, &v)) {
				if (is_min) { c.has_min_f = 1; c.min_f = v; }
				else { c.has_max_f = 1; c.max_f = v; }
			} else v_diag(a, faults, kid->line, "V092", v_msg_key(a, key));
		} else if (is_duration || is_size) {
			/* Read the way the document's value is: its own unit, then the
			   field name's, then the schema's `unit`. A path that ends in `*`
			   has no one name to give it. */
			ShclStr name = s_empty();
			if (c.segs.len > 0 && !c.segs.data[c.segs.len - 1].star) name = c.segs.data[c.segs.len - 1].name;
			shcl_duration_unit bare_d = name_duration_unit(name);
			if (bare_d == SHCL_DURATION_NONE) bare_d = c.unit_d;
			shcl_size_unit bare_s = name_size_unit(name);
			if (bare_s == SHCL_SIZE_NONE) bare_s = c.unit_s;
			int64_t v; unsigned units; shcl_duration_unit first; shcl_size_unit vu;
			int ok = is_duration ? parse_duration_text(el->text, bare_d, &v, &units, &first)
				: parse_size_text(el->text, bare_s, c.decimal, &v, &vu);
			if (ok) {
				if (is_min) { c.has_min_i = 1; c.min_i = v; c.min_text = el->text; }
				else { c.has_max_i = 1; c.max_i = v; c.max_text = el->text; }
			} else v_diag(a, faults, kid->line, "V092", v_msg_key(a, key));
		} else {
			v_diag(a, faults, kid->line, "V092", v_msg_key(a, key));
		}
	}
	/* A lower bound above the upper one admits nothing, so every value fails
	   twice and the schema, not the config, is what has to change. Reported at
	   the max line. The range goes, not the field: a key-level fault keeps its
	   entry, so the path still legalizes its name chain for the unknown-field
	   sweep, and the document is not told off twice per value for a range it
	   could never have satisfied. */
	if ((c.has_min_i && c.has_max_i && c.min_i > c.max_i)
	    || (c.has_min_f && c.has_max_f && c.min_f > c.max_f)) {
		size_t line = max_at != (size_t)-1 ? NODE(schema, max_at).line : node->line;
		v_diag(a, faults, line, "V092", v_msg_key(a, "max"));
		c.has_min_i = c.has_max_i = c.has_min_f = c.has_max_f = 0;
		c.min_text = c.max_text = s_empty();
	}
	*out = c;
	return 1;
}

// Interpret a parsed schema document into constraints and fragments, plus any
// schema faults (V09x, schema-file lines). Whatever parsed cleanly is kept
// even when faults are present - a broken key drops that key, a broken field
// drops that field - so a caller can still check the document against the
// surviving constraints.
static void v_build_schema(ShclArena *a, shcl_doc *schema, ShclVSchemaDef *def, ShclVecDiag *faults) {
	def->paths_complete = 1;
	ShclVecSize top = NODE(schema, ROOT).children;
	for (size_t fi = 0; fi < top.len; fi++) {
		ShclNode *node = &NODE(schema, top.data[fi]);
		if (s_eq(node->name, s_lit("field"))) {
			ShclVCons c;
			if (v_parse_field(a, schema, top.data[fi], faults, &c)) ShclVecVCons_push(a, &def->cons, c);
			else def->paths_complete = 0;
		} else if (s_eq(node->name, s_lit("fragment"))) {
			ShclStr name;
			if (!v_single_text(&node->value, &name) || name.n == 0) {
				v_diag(a, faults, node->line, "V094", v_msgz(a, "bad schema fragment"));
				continue;
			}
			// Two `fragment` blocks of one name never reach here: the parse
			// merges them into one node and reports H002. Kept as a guard in
			// case that changes, which is why no case pins it.
			if (v_frag_get(def, name)) {
				v_diag(a, faults, node->line, "V094", v_msg3(a, "bad schema fragment '", diag_name(a, name), "': duplicate"));
				continue;
			}
			ShclVFrag fr; fr.name = name; memset(&fr.fields, 0, sizeof fr.fields);
			ShclVecSize kids = NODE(schema, top.data[fi]).children;
			for (size_t ki = 0; ki < kids.len; ki++) {
				const ShclNode *kid = &NODE(schema, kids.data[ki]);
				if (s_eq(kid->name, s_lit("field"))) {
					ShclVCons c;
					if (v_parse_field(a, schema, kids.data[ki], faults, &c)) ShclVecVCons_push(a, &fr.fields, c);
					else def->paths_complete = 0;
				} else {
					ShclSB s = {0, 0, 0};
					sb_puts(a, &s, "bad schema fragment '"); sb_putS(a, &s, diag_name(a, name));
					sb_puts(a, &s, "': unknown key '"); sb_putS(a, &s, diag_name(a, kid->name)); sb_puts(a, &s, "'");
					v_diag(a, faults, kid->line, "V094", sb_S(&s));
				}
			}
			cmap_put(a, &def->fmap, cmap_hash(name, s_empty()), def->frags.len);
			ShclVecVFrag_push(a, &def->frags, fr);
		} else {
			v_diag(a, faults, node->line, "V090", v_msg3(a, "unknown schema key '", diag_name(a, node->name), "'"));
		}
	}
	// Every mount must name a declared fragment; cycles (self or mutual) are
	// legal - expansion is demand-driven against a finite document.
	for (size_t g = 0; g <= def->frags.len; g++) {
		const ShclVecVCons *list = g == 0 ? &def->cons : &def->frags.data[g - 1].fields;
		for (size_t i = 0; i < list->len; i++) {
			const ShclVCons *c = &list->data[i];
			if (c->inherits.n && !v_frag_get(def, c->inherits)) {
				v_diag(a, faults, c->inherits_line, "V095", v_msg3(a, "unknown schema fragment '", diag_name(a, c->inherits), "'"));
				def->paths_complete = 0;
			}
		}
	}
	// One constraint per line in practice, so line order = file order. Insertion
	// sort keeps equal lines stable (qsort is not stable).
	for (size_t i = 1; i < faults->len; i++) {
		ShclDiag key = faults->data[i];
		size_t j = i;
		while (j > 0 && faults->data[j - 1].line > key.line) { faults->data[j] = faults->data[j - 1]; j--; }
		faults->data[j] = key;
	}
}

// Levenshtein distance over codepoints capped at cap, for the "did you mean"
// prose (never the code): anything past the cap comes back as cap + 1. Only
// the band |i - j| <= cap of the table is computed, so a pair costs linear
// time in the names' length, and a length gap past the cap needs no table at
// all.
static size_t v_edit_distance(ShclArena *a, ShclStr sa, ShclStr sb, size_t cap) {
	ShclCPs ca = decode_cps(a, sa);
	ShclCPs cb = decode_cps(a, sb);
	size_t inf = cap + 1;
	if ((ca.n > cb.n ? ca.n - cb.n : cb.n - ca.n) > cap) return inf;
	size_t *prev = (size_t *)arena_alloc(a, (cb.n + 1) * sizeof(size_t));
	size_t *cur = (size_t *)arena_alloc(a, (cb.n + 1) * sizeof(size_t));
	for (size_t j = 0; j <= cb.n; j++) { prev[j] = j < inf ? j : inf; cur[j] = inf; }
	for (size_t i = 1; i <= ca.n; i++) {
		cur[0] = i < inf ? i : inf;
		size_t lo = i > cap ? i - cap : 1;
		size_t hi = i + cap < cb.n ? i + cap : cb.n;
		if (lo > 1) cur[lo - 1] = inf;
		size_t row_min = cur[0];
		for (size_t j = lo; j <= hi; j++) {
			size_t cost = ca.cp[i - 1] == cb.cp[j - 1] ? 0 : 1;
			size_t m = prev[j] + 1;
			if (cur[j - 1] + 1 < m) m = cur[j - 1] + 1;
			if (prev[j - 1] + cost < m) m = prev[j - 1] + cost;
			if (m > inf) m = inf;
			cur[j] = m;
			if (m < row_min) row_min = m;
		}
		if (hi < cb.n) cur[hi + 1] = inf;
		// No cell in a later row can come back under this row's minimum.
		if (row_min > cap) return inf;
		size_t *t = prev; prev = cur; cur = t;
	}
	return prev[cb.n];
}

/* The legal names under one parent chain, each once, in schema order. Every
   unknown field used to be compared with every sibling, and the list held one
   copy per schema field, so a document whose names all miss cost the schema
   times the document (20260918b item 10). Past the first few queries on a
   chain, each name of up to SHCL_SUGGEST_INDEXED characters is filed under
   every spelling it has with up to two characters deleted. Two names within
   edit distance 2 share such a spelling, so a query checks only the names its
   own spellings find. A longer name keeps the scan, filtered by length. */
typedef struct {
	ShclVecS names;
	ShclCMap seen;
	size_t queries;
	int indexed;
	// One map entry per spelling, naming its list in posts. A list per entry
	// would put each name at the tail of one bucket chain, which is quadratic
	// in a common spelling's list.
	ShclCMap index;
	ShclVecSize *posts; size_t nposts, cposts;
	ShclVecSize longs;
	// The query that last looked at each name, so a name found under several
	// spellings is measured once.
	size_t *stamp;
} ShclSuggestNames;
#define SHCL_SUGGEST_INDEXED 16
// Queries the scan answers before a chain gets its index. A few typos in a
// large section should not pay for indexing it.
#define SHCL_SUGGEST_SCANS 16

static void suggest_push(ShclArena *a, ShclSuggestNames *sn, ShclStr name) {
	uint64_t h = fnv_str(1469598103934665603ull, name);
	for (ShclCMapEnt *e = cmap_first(&sn->seen, h); e; e = cmap_next(e, h))
		if (s_eq(sn->names.data[e->val], name)) return;
	cmap_put(a, &sn->seen, h, sn->names.len);
	ShclVecS_push(a, &sn->names, name);
}

static size_t suggest_cps(ShclStr s) {
	size_t n = 0;
	for (size_t i = 0; i < s.n; i++) if (((unsigned char)s.p[i] & 0xC0u) != 0x80u) n++;
	return n;
}

/* Call F with the hash of each spelling of S with none, one or two of its
   characters deleted. The same spelling can come up more than once. */
typedef void (*ShclSpellFn)(void *ctx, uint64_t h);
static void deletion_spellings(ShclArena *tmp, ShclStr s, ShclSpellFn f, void *ctx) {
	size_t n = suggest_cps(s), k = 0;
	size_t *off = (size_t *)arena_alloc(tmp, (n + 1) * sizeof *off);
	for (size_t i = 0; i < s.n; i++) if (((unsigned char)s.p[i] & 0xC0u) != 0x80u) off[k++] = i;
	off[n] = s.n;
	for (size_t x = 0; x <= n; x++) {
		for (size_t y = x; y <= n; y++) {
			// x == n is no deletion; y == n with x < n is one; else two.
			if (x == n && y != n) continue;
			if (x < n && y == x) continue;
			uint64_t h = 1469598103934665603ull;
			for (size_t c = 0; c < n; c++) {
				if (c == x || c == y) continue;
				for (size_t i = off[c]; i < off[c + 1]; i++) h = fnv_byte(h, (unsigned char)s.p[i]);
			}
			f(ctx, h);
		}
	}
}

typedef struct { ShclArena *a; ShclSuggestNames *sn; size_t i; } ShclSpellFile;
static void suggest_file(void *ctx, uint64_t h) {
	ShclSpellFile *c = (ShclSpellFile *)ctx;
	ShclSuggestNames *sn = c->sn;
	ShclCMapEnt *e = cmap_first(&sn->index, h);
	size_t k;
	if (e) k = e->val;
	else {
		if (sn->nposts == sn->cposts) {
			size_t nc = sn->cposts ? sn->cposts * 2 : 8;
			sn->posts = (ShclVecSize *)arena_grow(c->a, sn->posts, sn->cposts, nc, sizeof(ShclVecSize));
			sn->cposts = nc;
		}
		memset(&sn->posts[sn->nposts], 0, sizeof sn->posts[sn->nposts]);
		k = sn->nposts++;
		cmap_put(c->a, &sn->index, h, k);
	}
	// A name's own spellings come in a run, so a repeat is the last entry.
	ShclVecSize *list = &sn->posts[k];
	if (!list->len || list->data[list->len - 1] != c->i) ShclVecSize_push(c->a, list, c->i);
}

typedef struct { ShclArena *tmp; ShclSuggestNames *sn; ShclStr name; int have; size_t best_dist, best_i; } ShclSpellFind;
static void suggest_consider(ShclSpellFind *c, size_t i) {
	size_t dist = v_edit_distance(c->tmp, c->name, c->sn->names.data[i], 2);
	if (dist <= 2 && (!c->have || dist < c->best_dist || (dist == c->best_dist && i < c->best_i))) {
		c->have = 1; c->best_dist = dist; c->best_i = i;
	}
}
static void suggest_find(void *ctx, uint64_t h) {
	ShclSpellFind *c = (ShclSpellFind *)ctx;
	ShclCMapEnt *e = cmap_first(&c->sn->index, h);
	if (!e) return;
	const ShclVecSize *list = &c->sn->posts[e->val];
	for (size_t k = 0; k < list->len; k++) {
		size_t i = list->data[k];
		if (c->sn->stamp[i] == c->sn->queries) continue;
		c->sn->stamp[i] = c->sn->queries;
		suggest_consider(c, i);
	}
}

// Closest legal sibling name (same parent chain, schema order, edit distance
// <= 2) appended as "; did you mean 'x'?" - or nothing. Prose only.
static void v_suggest(ShclArena *a, ShclArena *tmp, ShclSuggestNames *sn, ShclStr name, ShclSB *msg) {
	/* tmp holds the DP rows and codepoint decodes - dead after this call.
	   Resetting per unknown field keeps a wholesale unmatched document (the
	   case this feature exists for) at one sweep's peak. The sibling lists
	   are prebuilt once per validate by v_unknown, and a chain's index lives
	   in the validation arena beside them. */
	arena_reset(tmp);
	if (!sn) return;
	sn->queries++;
	ShclSpellFind find; find.tmp = tmp; find.sn = sn; find.name = name; find.have = 0; find.best_dist = 0; find.best_i = 0;
	if (sn->queries <= SHCL_SUGGEST_SCANS) {
		for (size_t i = 0; i < sn->names.len; i++) suggest_consider(&find, i);
	} else {
		if (!sn->indexed) {
			sn->indexed = 1;
			sn->stamp = (size_t *)arena_alloc(a, (sn->names.len ? sn->names.len : 1) * sizeof *sn->stamp);
			for (size_t i = 0; i < sn->names.len; i++) {
				sn->stamp[i] = 0;
				if (suggest_cps(sn->names.data[i]) > SHCL_SUGGEST_INDEXED) { ShclVecSize_push(a, &sn->longs, i); continue; }
				ShclSpellFile file; file.a = a; file.sn = sn; file.i = i;
				deletion_spellings(tmp, sn->names.data[i], suggest_file, &file);
			}
		}
		size_t qn = suggest_cps(name);
		if (qn <= SHCL_SUGGEST_INDEXED + 2) deletion_spellings(tmp, name, suggest_find, &find);
		for (size_t k = 0; k < sn->longs.len; k++) {
			size_t ln = suggest_cps(sn->names.data[sn->longs.data[k]]);
			if ((ln > qn ? ln - qn : qn - ln) <= 2) suggest_consider(&find, sn->longs.data[k]);
		}
	}
	if (find.have) {
		sb_puts(a, msg, "; did you mean '");
		sb_putS(a, msg, diag_name(a, sn->names.data[find.best_i]));
		sb_puts(a, msg, "'?");
	}
}

// Resolution contexts: the whole document for a plain path; each enclosing
// instance for the part of a path after a wildcard. required/repeat evaluate
// per context (anchor line 0 = document scope), so `server[*].port` + required
// means a port under EACH server - vacuously true with no servers.
typedef struct { size_t anchor; ShclVecSize found; } ShclVCtx;
DEFINE_VEC(ShclVecVCtx, ShclVCtx)

static void v_contexts(ShclArena *a, shcl_doc *d, const size_t *start, size_t nstart, ShclSegment *segs, size_t nsegs, size_t anchor, ShclVecVCtx *out) {
	ShclVecSize cur = {0};
	// cppcheck-suppress objectIndex  ## single-element callers pass nstart == 1, so start[i] stays at 0
	for (size_t i = 0; i < nstart; i++) ShclVecSize_push(a, &cur, start[i]);
	for (size_t si = 0; si < nsegs; si++) {
		const ShclSegment *seg = &segs[si];
		ShclVecSize next = {0};
		for (size_t k = 0; k < cur.len; k++) {
			ShclVecSize ch = NODE(d, cur.data[k]).children;
			if (seg->star) {
				for (size_t j = 0; j < ch.len; j++) ShclVecSize_push(a, &next, ch.data[j]);
			} else {
				children_named(d, a, cur.data[k], seg->name, &next);
			}
		}
		if (seg->star) {
			// Name wildcard: same per-instance split as `[*]`, any child name.
			ShclSegment *rest = segs + si + 1; size_t nrest = nsegs - si - 1;
			if (nrest == 0) {
				ShclVCtx ctx; ctx.anchor = anchor; ctx.found = next; ShclVecVCtx_push(a, out, ctx);
			} else {
				for (size_t k = 0; k < next.len; k++) {
					size_t inst = next.data[k];
					v_contexts(a, d, &inst, 1, rest, nrest, NODE(d, inst).line, out);
				}
			}
			return;
		}
		switch (seg->sel.tag) {
		case SEL_NONE: cur = next; break;
		case SEL_VALUE: {
			ShclVecSize f = {0};
			ShclStr want = seg->sel.value;
			for (size_t k = 0; k < next.len; k++) if (s_eq(disp_key(a, &NODE(d, next.data[k]).value), want) && (!seg->sel.quoted || single_scalar(&NODE(d, next.data[k]).value))) ShclVecSize_push(a, &f, next.data[k]);
			cur = f; break;
		}
		case SEL_INDEX: {
			ShclVecSize f = {0};
			if (seg->sel.index < next.len) ShclVecSize_push(a, &f, next.data[seg->sel.index]);
			cur = f; break;
		}
		case SEL_WILDCARD: {
			ShclSegment *rest = segs + si + 1; size_t nrest = nsegs - si - 1;
			if (nrest == 0) {
				ShclVCtx ctx; ctx.anchor = anchor; ctx.found = next; ShclVecVCtx_push(a, out, ctx);
			} else {
				for (size_t k = 0; k < next.len; k++) {
					size_t inst = next.data[k];
					v_contexts(a, d, &inst, 1, rest, nrest, NODE(d, inst).line, out);
				}
			}
			return;
		}
		}
	}
	ShclVCtx ctx; ctx.anchor = anchor; ctx.found = cur; ShclVecVCtx_push(a, out, ctx);
}

static void v_wrong_type(ShclArena *a, ShclVecDiag *out, size_t line, const ShclVCons *c) {
	ShclSB s = {0, 0, 0};
	sb_puts(a, &s, "wrong type at '"); sb_putS(a, &s, schema_text(a, c->path));
	sb_puts(a, &s, "': value is not a valid "); sb_puts(a, &s, c->ty ? c->ty : "string");
	v_diag(a, out, line, "V003", sb_S(&s));
}
/* Value text for a diagnostic message: line breaks and tabs escaped, so one
   diagnostic is one line. A raw block's body is the value that made this
   necessary - it contains its own newlines. */
static ShclStr v_one_line(ShclArena *a, ShclStr t) {
	ShclSB o = {0, 0, 0};
	sb_reserve(a, &o, t.n);
	for (size_t i = 0; i < t.n; i++) {
		switch (t.p[i]) {
		case '\\': sb_puts(a, &o, "\\\\"); break;
		case '\n': sb_puts(a, &o, "\\n"); break;
		case '\r': sb_puts(a, &o, "\\r"); break;
		case '\t': sb_puts(a, &o, "\\t"); break;
		default: sb_putc(a, &o, t.p[i]); break;
		}
	}
	return sb_S(&o);
}
static void v_not_allowed(ShclArena *a, ShclVecDiag *out, size_t line, const ShclVCons *c, ShclStr text) {
	ShclSB s = {0, 0, 0};
	sb_puts(a, &s, "value not allowed at '"); sb_putS(a, &s, schema_text(a, c->path));
	sb_puts(a, &s, "': "); sb_putS(a, &s, v_one_line(a, text));
	v_diag(a, out, line, "V004", sb_S(&s));
}

// V005/V006. rel is "below min " or "above max "; bound is the schema's own
// spelling of it, so the float half reads the same as the annotation line.
static void v_out_of_range(ShclArena *a, ShclVecDiag *out, size_t line, const ShclVCons *c, const char *code, const char *rel, ShclStr bound, ShclStr text) {
	ShclSB s = {0, 0, 0};
	sb_puts(a, &s, "value "); sb_puts(a, &s, rel); sb_putS(a, &s, bound);
	sb_puts(a, &s, " at '"); sb_putS(a, &s, schema_text(a, c->path));
	sb_puts(a, &s, "': "); sb_putS(a, &s, v_one_line(a, text));
	v_diag(a, out, line, code, sb_S(&s));
}

// Diagnostic messages go to a (they outlive the walk); coercion temporaries
// and compare strings go to lv, the walk level's scratch.
static void v_node(ShclArena *a, ShclArena *lv, shcl_doc *d, const ShclVCons *c, size_t n, ShclVecDiag *out) {
	ShclNode *node = &NODE(d, n);
	size_t line = node->line;
	const char *ty = c->ty;
	size_t tlen = ty ? strlen(ty) : 0;
	int is_array = ty && tlen > 6 && memcmp(ty + tlen - 6, "-array", 6) == 0;
	size_t blen = is_array ? tlen - 6 : tlen;
	// base kind compare helper against a literal
	#define V_BASE_IS(z) (ty && blen == strlen(z) && memcmp(ty, z, blen) == 0)
	if (node->value.kind == V_EMPTY) {
		// Empty passes everything; required already counted it as present.
		return;
	}
	if (node->value.kind == V_RAW) {
		// A raw block satisfies `raw` and scalar `string` (any value reads as a
		// string); every other kind is a type miss.
		if (ty && ((!V_BASE_IS("raw") && !V_BASE_IS("string")) || is_array)) { v_wrong_type(a, out, line, c); return; }
		if (c->has_allowed && c->akind == ALLOW_STRINGS) {
			int found = 0;
			for (size_t x = 0; x < c->a_n; x++) if (s_eq(c->a_strs[x], node->value.raw->content)) { found = 1; break; }
			if (!found) v_not_allowed(a, out, line, c, node->value.raw->content);
		}
		return;
	}
	ShclElement *els = node->value.els; size_t nels = node->value.nels;
	if (V_BASE_IS("raw")) { v_wrong_type(a, out, line, c); return; }
	// A scalar kind on a multi-element value is the array-where-one-scalar-
	// expected miss - except string, which reads arrays.
	if (ty && !is_array && !V_BASE_IS("string") && nels > 1) { v_wrong_type(a, out, line, c); return; }
	if (V_BASE_IS("int")) {
		int64_t *vals = (int64_t *)arena_alloc(lv, (nels ? nels : 1) * sizeof(int64_t));
		for (size_t x = 0; x < nels; x++)
			if (!parse_int_text(lv, &els[x], d->strictness, &vals[x])) { v_wrong_type(a, out, line, c); return; }
		if (c->has_allowed && c->akind == ALLOW_INTS) {
			for (size_t x = 0; x < nels; x++) {
				int found = 0;
				for (size_t y = 0; y < c->a_n; y++) if (c->a_ints[y] == vals[x]) { found = 1; break; }
				if (!found) { v_not_allowed(a, out, line, c, els[x].text); break; }
			}
		}
		if (c->has_min_i) { for (size_t x = 0; x < nels; x++) if (vals[x] < c->min_i) { ShclStr b; char nb[32]; b.p = nb; b.n = (size_t)snprintf(nb, sizeof nb, "%" PRId64, c->min_i); v_out_of_range(a, out, line, c, "V005", "below min ", b, els[x].text); break; } }
		if (c->has_max_i) { for (size_t x = 0; x < nels; x++) if (vals[x] > c->max_i) { ShclStr b; char nb[32]; b.p = nb; b.n = (size_t)snprintf(nb, sizeof nb, "%" PRId64, c->max_i); v_out_of_range(a, out, line, c, "V006", "above max ", b, els[x].text); break; } }
	} else if (V_BASE_IS("float")) {
		double *vals = (double *)arena_alloc(lv, (nels ? nels : 1) * sizeof(double));
		for (size_t x = 0; x < nels; x++)
			if (!parse_float_text(lv, &els[x], d->strictness, &vals[x])) { v_wrong_type(a, out, line, c); return; }
		if (c->has_allowed && c->akind == ALLOW_FLOATS) {
			for (size_t x = 0; x < nels; x++) {
				int found = 0;
				for (size_t y = 0; y < c->a_n; y++) if (c->a_floats[y] == vals[x]) { found = 1; break; }
				if (!found) { v_not_allowed(a, out, line, c, els[x].text); break; }
			}
		}
		if (c->has_min_f) { for (size_t x = 0; x < nels; x++) if (vals[x] < c->min_f) { ShclStr b; char fb[SHCL_FLOAT_BUF]; b.p = fb; b.n = shcl_format_float(c->min_f, fb); v_out_of_range(a, out, line, c, "V005", "below min ", b, els[x].text); break; } }
		if (c->has_max_f) { for (size_t x = 0; x < nels; x++) if (vals[x] > c->max_f) { ShclStr b; char fb[SHCL_FLOAT_BUF]; b.p = fb; b.n = shcl_format_float(c->max_f, fb); v_out_of_range(a, out, line, c, "V006", "above max ", b, els[x].text); break; } }
	} else if (V_BASE_IS("bool")) {
		int *vals = (int *)arena_alloc(lv, (nels ? nels : 1) * sizeof(int));
		for (size_t x = 0; x < nels; x++)
			if (!parse_bool_text(lv, els[x].text, d->strictness, &vals[x])) { v_wrong_type(a, out, line, c); return; }
		if (c->has_allowed && c->akind == ALLOW_BOOLS) {
			for (size_t x = 0; x < nels; x++) {
				int found = 0;
				for (size_t y = 0; y < c->a_n; y++) if ((c->a_bools[y] != 0) == (vals[x] != 0)) { found = 1; break; }
				if (!found) { v_not_allowed(a, out, line, c, els[x].text); break; }
			}
		}
	} else if (V_BASE_IS("datetime")) {
		shcl_datetime *vals = (shcl_datetime *)arena_alloc(lv, (nels ? nels : 1) * sizeof(shcl_datetime));
		for (size_t x = 0; x < nels; x++)
			if (!parse_datetime(lv, els[x].text, &vals[x])) { v_wrong_type(a, out, line, c); return; }
		if (c->has_allowed && c->akind == ALLOW_DATES) {
			for (size_t x = 0; x < nels; x++) {
				int found = 0;
				for (size_t y = 0; y < c->a_n; y++) if (v_same_moment(&c->a_dates[y], &vals[x])) { found = 1; break; }
				if (!found) { v_not_allowed(a, out, line, c, els[x].text); break; }
			}
		}
	} else if (V_BASE_IS("duration") || V_BASE_IS("size")) {
		// A bare number takes its unit from the field name first, as the read
		// does, then the schema's `unit`.
		int is_duration = V_BASE_IS("duration");
		int64_t *vals = (int64_t *)arena_alloc(lv, (nels ? nels : 1) * sizeof(int64_t));
		for (size_t x = 0; x < nels; x++) {
			int ok;
			if (is_duration) {
				shcl_duration_unit bare = name_duration_unit(node->name);
				unsigned units; shcl_duration_unit first;
				ok = parse_duration_text(els[x].text, bare != SHCL_DURATION_NONE ? bare : c->unit_d, &vals[x], &units, &first);
			} else {
				shcl_size_unit bare = name_size_unit(node->name), vu;
				ok = parse_size_text(els[x].text, bare != SHCL_SIZE_NONE ? bare : c->unit_s, c->decimal, &vals[x], &vu);
			}
			if (!ok) { v_wrong_type(a, out, line, c); return; }
		}
		if (c->has_allowed && c->akind == ALLOW_INTS) {
			for (size_t x = 0; x < nels; x++) {
				int found = 0;
				for (size_t y = 0; y < c->a_n; y++) if (c->a_ints[y] == vals[x]) { found = 1; break; }
				if (!found) { v_not_allowed(a, out, line, c, els[x].text); break; }
			}
		}
		if (c->has_min_i && c->min_text.n) { for (size_t x = 0; x < nels; x++) if (vals[x] < c->min_i) { v_out_of_range(a, out, line, c, "V005", "below min ", v_one_line(a, c->min_text), els[x].text); break; } }
		if (c->has_max_i && c->max_text.n) { for (size_t x = 0; x < nels; x++) if (vals[x] > c->max_i) { v_out_of_range(a, out, line, c, "V006", "above max ", v_one_line(a, c->max_text), els[x].text); break; } }
	} else {
		// string kind or untyped: every element coerces; only the allowed set
		// can fail, in logical-string space.
		if (c->has_allowed && c->akind == ALLOW_STRINGS) {
			for (size_t x = 0; x < nels; x++) {
				ShclStr s = els[x].text;
				int found = 0;
				for (size_t y = 0; y < c->a_n; y++) if (s_eq(c->a_strs[y], s)) { found = 1; break; }
				if (!found) { v_not_allowed(a, out, line, c, s); break; }
			}
		}
	}
	#undef V_BASE_IS
}

/* (fragment, node) pairs already mounted: the map holds hashes only, so the
   parallel frag/node lists hold what each entry actually names - that is what
   a hit verifies against. */
typedef struct { ShclCMap map; ShclVecS frag; ShclVecSize node; } ShclVMounts;

// A mounted fragment's fields run per resolved node, right after that node's
// own checks, in fragment order - depth-first, so diagnostic order stays
// derivable. Termination is structural: every mount descends at least one
// document level, and the document is finite (depth capped at 512, so this C
// stack recursion is safe - same rationale as v_contexts' own).
// lv is this level's scratch arena (next slot in the caller's per-level pool);
// resetting it at entry reuses the previous sibling call's block instead of
// retaining every level's temporaries in the validation arena until it is
// freed. Level L's contexts stay live in lv while deeper levels run in lv+1.
static void v_check_from(ShclArena *a, ShclArena *lv, shcl_doc *d, const ShclVCons *c, const ShclVSchemaDef *def, size_t start, size_t anchor0, ShclVecDiag *out, ShclVMounts *mounted) {
	arena_reset(lv);
	ShclVecVCtx ctxs = {0};
	v_contexts(lv, d, &start, 1, c->segs.data, c->segs.len, anchor0, &ctxs);
	// The mount is the constraint's, not the node's, so it is looked up once
	// here rather than once per resolved node.
	const ShclVecVCons *fcs = c->inherits.n ? v_frag_get(def, c->inherits) : NULL;
	for (size_t i = 0; i < ctxs.len; i++) {
		ShclVCtx *ctx = &ctxs.data[i];
		if (c->required && ctx->found.len == 0)
			v_diag(a, out, ctx->anchor, "V002", v_msg3(a, "required path missing: ", schema_text(a, c->path), ""));
		if (c->has_repeat) {
			uint64_t n = (uint64_t)ctx->found.len;
			if (n < c->rep_lo || n > c->rep_hi) {
				ShclSB s = {0, 0, 0};
				sb_puts(a, &s, "instance count out of bounds at '"); sb_putS(a, &s, schema_text(a, c->path));
				sb_puts(a, &s, "': "); sb_put_u64(a, &s, n);
				sb_puts(a, &s, " not in "); sb_put_u64(a, &s, c->rep_lo);
				sb_puts(a, &s, ".."); sb_put_u64(a, &s, c->rep_hi);
				v_diag(a, out, ctx->anchor, "V007", sb_S(&s));
			}
		}
		for (size_t k = 0; k < ctx->found.len; k++) {
			size_t n = ctx->found.data[k];
			v_node(a, lv, d, c, n, out);
			if (c->inherits.n) {
				if (fcs) {
					// Two constraints can resolve to the same node and mount the
					// same fragment there. The second mount would repeat the
					// first's work and its diagnostics, and repeating it per
					// level is what makes a recursive schema cost double per
					// document level, so each pair is done once.
					char kb[sizeof n]; memcpy(kb, &n, sizeof n);
					ShclStr nkey; nkey.p = kb; nkey.n = sizeof n;
					uint64_t h = cmap_hash(c->inherits, nkey);
					int seen = 0;
					for (ShclCMapEnt *e = cmap_first(&mounted->map, h); e; e = cmap_next(e, h))
						if (mounted->node.data[e->val] == n && s_eq(mounted->frag.data[e->val], c->inherits)) { seen = 1; break; }
					if (!seen) {
						size_t mi = mounted->frag.len;
						ShclVecS_push(a, &mounted->frag, c->inherits);
						ShclVecSize_push(a, &mounted->node, n);
						cmap_put(a, &mounted->map, h, mi);
						for (size_t fi = 0; fi < fcs->len; fi++)
							v_check_from(a, lv + 1, d, &fcs->data[fi], def, n, NODE(d, n).line, out, mounted);
					}
				}
			}
		}
	}
}

// Append a segment to a chain key. Chain keys join segments length-prefixed
// (`<len>:<name>`), not with a bare NUL: NUL is legal in a quoted name, so a
// single field named "x\0y" would impersonate the two-segment path x.y. Same
// injectivity reasoning as the merge key's cell encoding - and like it, the
// length unit is each binding's native one (bytes here), because only
// injectivity matters.
static void chain_push(ShclArena *a, ShclSB *chain, ShclStr name) {
	char buf[32];
	snprintf(buf, sizeof buf, "%zu:", name.n);
	sb_puts(a, chain, buf);
	sb_putS(a, chain, name);
}

// Decode the next length-prefixed segment of a chain key at *i. Total: bails
// at the first shape the encoder can't have produced.
static int chain_next(ShclStr chain, size_t *i, ShclStr *nm) {
	size_t k = *i, n = 0;
	if (k >= chain.n) return 0;
	while (k < chain.n && chain.p[k] >= '0' && chain.p[k] <= '9') { n = n * 10 + (size_t)(chain.p[k] - '0'); k++; }
	if (k >= chain.n || chain.p[k] != ':' || k + 1 + n > chain.n) return 0;
	k++;
	*nm = s_slice(chain, k, k + n);
	*i = k + n;
	return 1;
}

// Schema paths bucketed by what their first segment accepts. A path can only
// match a chain whose first part is that segment's name, or anything at all
// when the segment is `*`, so a bucket plus the star list is the whole
// candidate set. Values are positions in the list the index was built from,
// and both callers ask "does any of these match", so bucket order cannot reach
// the answer. Same map shape as `legal` and `sib_of` below: the entries hold
// hashes, and `names` holds what each bucket is keyed on, for the verify.
typedef struct {
	ShclCMap of;
	ShclVecS names;
	ShclVecSize *buckets; size_t nb, cb;
	ShclVecSize stars;
} ShclFirstIdx;

static void fidx_add(ShclArena *a, ShclFirstIdx *ix, size_t pos, ShclVecSeg segs) {
	// A pathless entry keeps its old place in every candidate set: the scan it
	// replaces looked at one, and what it then did is unchanged.
	if (segs.len == 0 || segs.data[0].star) { ShclVecSize_push(a, &ix->stars, pos); return; }
	ShclStr nm = segs.data[0].name;
	uint64_t h = cmap_hash(nm, s_empty());
	size_t g = (size_t)-1;
	for (ShclCMapEnt *e = cmap_first(&ix->of, h); e; e = cmap_next(e, h))
		if (s_eq(ix->names.data[e->val], nm)) { g = e->val; break; }
	if (g == (size_t)-1) {
		if (ix->nb == ix->cb) { size_t nc = ix->cb ? ix->cb * 2 : 8; ix->buckets = (ShclVecSize *)arena_grow(a, ix->buckets, ix->cb, nc, sizeof(ShclVecSize)); ix->cb = nc; }
		memset(&ix->buckets[ix->nb], 0, sizeof ix->buckets[ix->nb]);
		g = ix->nb++;
		cmap_put(a, &ix->of, h, g);
		ShclVecS_push(a, &ix->names, nm);
	}
	ShclVecSize_push(a, &ix->buckets[g], pos);
}

// The bucket for one chain part, or NULL. The star list is the caller's second
// pass; keeping the two apart is what stops a per-node allocation here.
static const ShclVecSize *fidx_bucket(const ShclFirstIdx *ix, ShclStr part) {
	uint64_t h = cmap_hash(part, s_empty());
	for (ShclCMapEnt *e = cmap_first((ShclCMap *)&ix->of, h); e; e = cmap_next(e, h))
		if (s_eq(ix->names.data[e->val], part)) return &ix->buckets[e->val];
	return NULL;
}

// Element-wise chain match against the star-bearing schema paths: a `*`
// segment matches any one name, and every prefix of a path is legal.
static int star_legal(const ShclVecSeg *pats, size_t npats, const ShclFirstIdx *ix, ShclStr chain) {
	if (npats == 0) return 0;
	size_t ci = 0; ShclStr first;
	if (!chain_next(chain, &ci, &first)) return 0;
	const ShclVecSize *bucket = fidx_bucket(ix, first);
	for (int pass = 0; pass < 2; pass++) {
		const ShclVecSize *list = pass ? &ix->stars : bucket;
		if (!list) continue;
		for (size_t bi = 0; bi < list->len; bi++) {
			const ShclVecSeg *p = &pats[list->data[bi]];
			size_t part = 0, i = 0; int match = 1;
			ShclStr nm;
			while (match && chain_next(chain, &i, &nm)) {
				if (part >= p->len || (!p->data[part].star && !s_eq(p->data[part].name, nm))) match = 0;
				part++;
			}
			if (match) return 1;
		}
	}
	return 0;
}

// Chain legality through fragment mounts: the general matcher - element-wise
// like star_legal (stars wild, prefixes legal), and when a mount's whole path
// matched with chain left over, the remainder is retried against the mounted
// fragment's fields. Terminates: every descent consumes >= 1 part. A state is
// (fragment, parts consumed), one byte each in `dead` - row 0 the top-level
// constraints, row k+1 fragment k - and one that has failed is not walked
// again: two mounts of the same fragment at the same depth used to be walked
// both, which is 2^depth on a chain that ends unknown.
// set_idx is one ShclFirstIdx per constraint list, laid out the way `dead` is -
// row 0 the top-level constraints, row k+1 fragment k - rather than keyed by
// fragment name as the reference does, because that numbering is already here.
static int chain_parts_legal(const ShclVecVCons *cons, size_t set, const ShclVSchemaDef *def, const ShclFirstIdx *set_idx, ShclStr chain, size_t from, size_t at, size_t nparts, unsigned char *dead) {
	if (dead[set * (nparts + 1) + at]) return 0;
	// The recursion only descends with parts left over, and the sweep never
	// asks about an empty chain, so there is always a first part to look up.
	size_t fi0 = from; ShclStr first;
	const ShclVecSize *bucket = chain_next(chain, &fi0, &first) ? fidx_bucket(&set_idx[set], first) : NULL;
	for (int pass = 0; pass < 2; pass++) {
		const ShclVecSize *list = pass ? &set_idx[set].stars : bucket;
		if (!list) continue;
		for (size_t bi = 0; bi < list->len; bi++) {
			const ShclVCons *c = &cons->data[list->data[bi]];
			size_t n = c->segs.len;
			size_t part = 0, i = from, rem = from;
			int match = 1;
			ShclStr nm;
			while (match && chain_next(chain, &i, &nm)) {
				if (part < n) {
					if (!c->segs.data[part].star && !s_eq(c->segs.data[part].name, nm)) match = 0;
					if (part + 1 == n) rem = i; // remainder starts past the matched prefix
				}
				part++;
			}
			if (!match) continue;
			if (part <= n) return 1; // a prefix of a legal path
			if (c->inherits.n) {
				size_t fi = v_frag_index(def, c->inherits);
				if (fi != SIZE_MAX && chain_parts_legal(&def->frags.data[fi].fields, fi + 1, def, set_idx, chain, rem, at + n, nparts, dead)) return 1;
			}
		}
	}
	dead[set * (nparts + 1) + at] = 1;
	return 0;
}
static int chain_legal(ShclArena *tmp, const ShclVSchemaDef *def, const ShclFirstIdx *set_idx, ShclStr chain) {
	size_t nparts = 0, i = 0;
	ShclStr nm;
	while (chain_next(chain, &i, &nm)) nparts++;
	size_t cells = (def->frags.len + 1) * (nparts + 1);
	unsigned char *dead = (unsigned char *)arena_alloc(tmp, cells);
	memset(dead, 0, cells);
	return chain_parts_legal(&def->cons, 0, def, set_idx, chain, 0, 0, nparts, dead);
}

// Unknown-field sweep: a schema path legalizes its name chain and every prefix
// (selectors ignored). Only the topmost unknown node is reported; its subtree
// is implied unknown and skipped.
static void v_unknown(ShclArena *a, ShclArena *tmp, shcl_doc *d, const ShclVSchemaDef *def, ShclVecDiag *out) {
	const ShclVecVCons *cons = &def->cons;
	// Chains below a fragment mount only match by descending the mounts.
	int has_mounts = 0;
	for (size_t i = 0; i < cons->len; i++) if (cons->data[i].inherits.n) { has_mounts = 1; break; }
	arena_guard(tmp, a->panic); // v_suggest scratch, reset per unknown field
	// Legal chains in a hash set (the linear scan compounded the quadratic),
	// and sibling names bucketed per parent chain, built once: v_suggest used
	// to rebuild every chain per unknown field. The map entries hold hashes
	// only; legal_chains / sib_chain hold what each names, for the verify.
	ShclCMap legal; memset(&legal, 0, sizeof legal);
	ShclVecS legal_chains = {0};
	ShclCMap sib_of; memset(&sib_of, 0, sizeof sib_of);
	ShclVecS sib_chain = {0}; /* parent chain per sibs bucket */
	ShclSuggestNames *sibs = NULL; size_t nsib = 0, csib = 0;
	// Paths with a `*` segment can't live in the exact-chain hash; they
	// match element-wise (a star matches any one name, prefixes included).
	ShclVecSeg *star_pats = NULL; size_t nstar = 0, cstar = 0;
	for (size_t i = 0; i < cons->len; i++) {
		int has_star = 0;
		for (size_t si = 0; si < cons->data[i].segs.len; si++) if (cons->data[i].segs.data[si].star) { has_star = 1; break; }
		if (has_star) {
			if (nstar == cstar) { size_t nc = cstar ? cstar * 2 : 8; star_pats = (ShclVecSeg *)arena_grow(a, star_pats, cstar, nc, sizeof(ShclVecSeg)); cstar = nc; }
			star_pats[nstar++] = cons->data[i].segs;
		}
		ShclSB chain = {0, 0, 0};
		for (size_t si = 0; si < cons->data[i].segs.len; si++) {
			if (cons->data[i].segs.data[si].star) break; // no sibling entry for '*'; deeper chains are pattern-only
			ShclStr nm = cons->data[i].segs.data[si].name;
			ShclStr pc = s_dup(a, sb_S(&chain));
			uint64_t hp = cmap_hash(pc, s_empty());
			size_t g = (size_t)-1;
			for (ShclCMapEnt *e = cmap_first(&sib_of, hp); e; e = cmap_next(e, hp))
				if (s_eq(sib_chain.data[e->val], pc)) { g = e->val; break; }
			if (g == (size_t)-1) {
				if (nsib == csib) { size_t nc = csib ? csib * 2 : 8; sibs = (ShclSuggestNames *)arena_grow(a, sibs, csib, nc, sizeof(ShclSuggestNames)); csib = nc; }
				memset(&sibs[nsib], 0, sizeof sibs[nsib]);
				g = nsib++;
				cmap_put(a, &sib_of, hp, g);
				ShclVecS_push(a, &sib_chain, pc);
			}
			suggest_push(a, &sibs[g], nm);
			chain_push(a, &chain, nm);
			ShclStr full = s_dup(a, sb_S(&chain));
			uint64_t hf = cmap_hash(full, s_empty());
			int have = 0;
			for (ShclCMapEnt *e = cmap_first(&legal, hf); e; e = cmap_next(e, hf))
				if (s_eq(legal_chains.data[e->val], full)) { have = 1; break; }
			if (!have) { cmap_put(a, &legal, hf, legal_chains.len); ShclVecS_push(a, &legal_chains, full); }
		}
	}
	// Both element-wise matchers used to scan their whole list per document
	// node, which is quadratic once the schema and the document grow together.
	ShclFirstIdx star_idx; memset(&star_idx, 0, sizeof star_idx);
	for (size_t i = 0; i < nstar; i++) fidx_add(a, &star_idx, i, star_pats[i]);
	ShclFirstIdx *set_idx = NULL;
	if (has_mounts) {
		size_t nsets = def->frags.len + 1;
		set_idx = (ShclFirstIdx *)arena_alloc(a, nsets * sizeof(ShclFirstIdx));
		memset(set_idx, 0, nsets * sizeof(ShclFirstIdx));
		for (size_t i = 0; i < cons->len; i++) fidx_add(a, &set_idx[0], i, cons->data[i].segs);
		for (size_t fi = 0; fi < def->frags.len; fi++) {
			const ShclVecVCons *fc = &def->frags.data[fi].fields;
			for (size_t i = 0; i < fc->len; i++) fidx_add(a, &set_idx[fi + 1], i, fc->data[i].segs);
		}
	}
	ShclVecSize snode = {0}; ShclVecS schain = {0}; ShclVecS sshown = {0};
	ShclVecSize top = NODE(d, ROOT).children;
	for (size_t i = top.len; i > 0; i--) {
		ShclVecSize_push(a, &snode, top.data[i - 1]);
		ShclVecS_push(a, &schain, s_empty());
		ShclVecS_push(a, &sshown, s_empty());
	}
	while (snode.len) {
		size_t n = snode.data[snode.len - 1];
		ShclStr pchain = schain.data[snode.len - 1];
		ShclStr pshown = sshown.data[snode.len - 1];
		snode.len--; schain.len--; sshown.len--;
		const ShclNode *node = &NODE(d, n);
		ShclSB cb = {0, 0, 0};
		sb_putS(a, &cb, pchain);
		chain_push(a, &cb, node->name);
		ShclStr chain = sb_S(&cb);
		ShclSB sb2 = {0, 0, 0};
		if (pshown.n) { sb_putS(a, &sb2, pshown); sb_putc(a, &sb2, '.'); }
		sb_putS(a, &sb2, diag_name(a, node->name));
		ShclStr shown = sb_S(&sb2);
		int found = 0;
		{
			uint64_t hc = cmap_hash(chain, s_empty());
			for (ShclCMapEnt *e = cmap_first(&legal, hc); e; e = cmap_next(e, hc))
				if (s_eq(legal_chains.data[e->val], chain)) { found = 1; break; }
		}
		if (!found && !star_legal(star_pats, nstar, &star_idx, chain) && !(has_mounts && chain_legal(tmp, def, set_idx, chain))) {
			ShclSB msg = {0, 0, 0};
			sb_puts(a, &msg, "unknown field '"); sb_putS(a, &msg, shown); sb_puts(a, &msg, "'");
			size_t sg = (size_t)-1;
			uint64_t hpc = cmap_hash(pchain, s_empty());
			for (ShclCMapEnt *e = cmap_first(&sib_of, hpc); e; e = cmap_next(e, hpc))
				if (s_eq(sib_chain.data[e->val], pchain)) { sg = e->val; break; }
			v_suggest(a, tmp, sg == (size_t)-1 ? NULL : &sibs[sg], node->name, &msg);
			v_diag(a, out, node->line, "V001", sb_S(&msg));
			continue;
		}
		ShclVecSize ch = node->children;
		for (size_t i = ch.len; i > 0; i--) {
			ShclVecSize_push(a, &snode, ch.data[i - 1]);
			ShclVecS_push(a, &schain, chain);
			ShclVecS_push(a, &sshown, shown);
		}
	}
	arena_free(tmp);
}

/* The recovery path reads only the two volatile carriers, so -Wclobbered's
   guess about a helper inlined below is wrong here the way it is for
   do_parse. */
#if defined(__GNUC__) && !defined(__clang__)
	#pragma GCC diagnostic push
	#pragma GCC diagnostic ignored "-Wclobbered"
#endif
shcl_validation *shcl_validate(shcl_doc *d, shcl_doc *schema) {
	/* Same shape as do_parse: the two the unwind path has to reach are
	   volatile, the working copies below are not. */
	shcl_validation *volatile val = (shcl_validation *)malloc(sizeof *val);
	if (!val) return NULL;
	memset(val, 0, sizeof *val);
	ShclArena *volatile levels = NULL;
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		shcl_validation *bad = val; ShclArena *badLevels = levels;
		if (badLevels) { for (size_t i = 0; i <= SHCL_MAX_DEPTH; i++) arena_free(&badLevels[i]); free(badLevels); }
		/* The name index is the only thing on the document this call builds,
		   and half of one is worse than none. Everything else it touched is
		   scratch. */
		index_drop(d);
		arena_guard(&d->index_arena, NULL); arena_guard(&d->scratch, NULL); arena_guard(&d->reads, NULL);
		arena_free(&bad->arena); arena_free(&bad->scratch); free(bad);
		return NULL;
	}
	shcl_validation *v = val;
	arena_guard(&v->arena, &panic);
	/* Reading the document allocates too - the name index above all - so the
	   read-side arenas unwind here rather than to SHCL_OOM. */
	arena_guard(&d->index_arena, &panic); arena_guard(&d->scratch, &panic); arena_guard(&d->reads, &panic);
	ShclArena *a = &v->arena;
	ShclVSchemaDef def; memset(&def, 0, sizeof def);
	ShclVecDiag faults = {0};
	v_build_schema(a, schema, &def, &faults);
	v->diags = faults;
	// One scratch arena per mount-recursion level, reset and reused across
	// sibling calls: peak retention is one block per active document level,
	// not every level of every walk. The parser caps depth at SHCL_MAX_DEPTH
	// and every mount starts at least one level deeper, so the pool cannot be
	// outrun; untouched slots never allocate.
	// On the heap, not the stack: one slot per level of the depth cap is 16 KB,
	// which is fine on a main thread and not on a small-stack one.
	ShclArena *lvls = (ShclArena *)calloc(SHCL_MAX_DEPTH + 1, sizeof *lvls);
	if (!lvls) arena_panic(&panic);
	levels = lvls;
	for (size_t i = 0; i <= SHCL_MAX_DEPTH; i++) arena_guard(&lvls[i], &panic);
	// One mount set for the whole schema: two top-level paths can resolve to
	// the same node and mount the same fragment there, and the spec says each
	// fragment runs once per node. Entries live in the validation arena, so
	// the set needs no own teardown.
	ShclVMounts mounted; memset(&mounted, 0, sizeof mounted);
	for (size_t i = 0; i < def.cons.len; i++) v_check_from(a, lvls, d, &def.cons.data[i], &def, ROOT, 0, &v->diags, &mounted);
	// Nothing returns between the alloc and here, so every slot is reached.
	for (size_t i = 0; i <= SHCL_MAX_DEPTH; i++) arena_free(&lvls[i]);
	free(lvls);
	levels = NULL;
	if (def.paths_complete) v_unknown(a, &v->scratch, d, &def, &v->diags);
	/* This frame is about to go; the arenas outlive it. v->scratch is armed
	   inside v_unknown, so it is disarmed here with the rest rather than left
	   pointing at a frame that has returned. */
	arena_guard(&v->arena, NULL); arena_guard(&v->scratch, NULL);
	arena_guard(&d->index_arena, NULL); arena_guard(&d->scratch, NULL); arena_guard(&d->reads, NULL);
	return v;
}
#if defined(__GNUC__) && !defined(__clang__)
	#pragma GCC diagnostic pop
#endif
size_t shcl_validation_count(const shcl_validation *v) { return v->diags.len; }
size_t shcl_validation_line(const shcl_validation *v, size_t i) { return v->diags.data[i].line; }
shcl_severity shcl_validation_severity(const shcl_validation *v, size_t i) { return v->diags.data[i].sev; }
shcl_str shcl_validation_message(const shcl_validation *v, size_t i) {
	shcl_str s; s.p = v->diags.data[i].message.p; s.n = v->diags.data[i].message.n; return s;
}
const char *shcl_validation_code(const shcl_validation *v, size_t i) { return v->diags.data[i].code; }
void shcl_validation_free(shcl_validation *v) { if (!v) return; arena_free(&v->arena); arena_free(&v->scratch); free(v); }

/* Leaf names of the schema entries pick accepts, top-level fields and every
   fragment's fields alike. Read through the built schema, so the names are
   the ones validation will use (escapes resolved) and an entry whose key
   faulted disavows nothing. Everything is built in tmp. */
static int v_pick_repeat(const ShclVCons *c) { return c->has_repeat && c->rep_hi > 1; }
static int v_pick_reopen(const ShclVCons *c) { return c->reopen; }
static ShclVecS v_disavowed_names(shcl_doc *schema, ShclArena *tmp, int (*pick)(const ShclVCons *)) {
	ShclVSchemaDef def; memset(&def, 0, sizeof def);
	ShclVecDiag faults = {0};
	v_build_schema(tmp, schema, &def, &faults);
	ShclVecS names = {0};
	for (size_t g = 0; g <= def.frags.len; g++) {
		const ShclVecVCons *list = g == 0 ? &def.cons : &def.frags.data[g - 1].fields;
		for (size_t i = 0; i < list->len; i++) {
			const ShclVCons *c = &list->data[i];
			if (!pick(c) || c->segs.len == 0) continue;
			/* Name wildcard: no single leaf name to disavow. */
			const ShclSegment *last = &c->segs.data[c->segs.len - 1];
			if (!last->star) ShclVecS_push(tmp, &names, last->name);
		}
	}
	return names;
}

/* Everything a suppressor builds - instance/repeat query results as well as the
   collected names (which must survive the per-read scratch resets) - goes into
   an arena the caller owns: the function owns neither doc, so it must not leave
   allocations behind in either. */
static void suppress_repeats_in(ShclArena *tmp, shcl_doc *schema, shcl_doc *doc) {
	ShclVecS names = v_disavowed_names(schema, tmp, v_pick_repeat);
	if (!names.len) return;
	ShclVecS heads = {0};
	for (size_t k = 0; k < names.len; k++) ShclVecS_push(tmp, &heads, h001_head(tmp, names.data[k]));
	size_t w = 0;
	for (size_t i = 0; i < doc->diags.len; i++) {
		ShclDiag dg = doc->diags.data[i];
		int drop = 0;
		if (strcmp(dg.code, "H001") == 0) {
			ShclStr m = dg.message;
			for (size_t k = 0; k < heads.len; k++) {
				ShclStr h = heads.data[k];
				if (m.n >= h.n && memcmp(m.p, h.p, h.n) == 0) { drop = 1; break; }
			}
		}
		if (!drop) doc->diags.data[w++] = dg;
	}
	doc->diags.len = w;
}

static void suppress_reopens_in(ShclArena *tmp, shcl_doc *schema, shcl_doc *doc) {
	ShclVecS names = v_disavowed_names(schema, tmp, v_pick_reopen);
	if (!names.len) return;
	ShclVecS heads = {0};
	for (size_t k = 0; k < names.len; k++) ShclVecS_push(tmp, &heads, h002_head(tmp, names.data[k]));
	size_t w = 0;
	for (size_t i = 0; i < doc->diags.len; i++) {
		ShclDiag dg = doc->diags.data[i];
		int drop = 0;
		if (strcmp(dg.code, "H002") == 0) {
			ShclStr m = dg.message;
			for (size_t k = 0; k < heads.len; k++) {
				ShclStr h = heads.data[k];
				if (m.n >= h.n && memcmp(m.p, h.p, h.n) == 0) { drop = 1; break; }
			}
		}
		if (!drop) doc->diags.data[w++] = dg;
	}
	doc->diags.len = w;
}

/* The public suppressors own their arena off the frame, so a longjmping
   SHCL_OOM cannot strand it; the failure is handed on once it is freed. */
static void suppress_owned(shcl_doc *schema, shcl_doc *doc, void (*run)(ShclArena *, shcl_doc *, shcl_doc *)) {
	ShclArena *volatile tmp = (ShclArena *)calloc(1, sizeof *tmp);
	if (!tmp) { SHCL_OOM(); abort(); }
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		ShclArena *bad = tmp;
		doc_guard(schema, NULL); doc_guard(doc, NULL);
		arena_free(bad); free(bad);
		SHCL_OOM();
		abort();
	}
	arena_guard(tmp, &panic);
	doc_guard(schema, &panic); doc_guard(doc, &panic);
	run(tmp, schema, doc);
	doc_guard(schema, NULL); doc_guard(doc, NULL);
	ShclArena *done = tmp;
	arena_free(done); free(done);
}
void shcl_suppress_declared_repeats(shcl_doc *schema, shcl_doc *doc) { suppress_owned(schema, doc, suppress_repeats_in); }
void shcl_suppress_declared_reopens(shcl_doc *schema, shcl_doc *doc) { suppress_owned(schema, doc, suppress_reopens_in); }

// How many lines or values parsing dropped that canonical output cannot
// re-emit - bad indentation, an unusable selector, a line past the depth cap.
// Content-malformed lines do NOT count: those are retained as trivia and
// survive a save. Nonzero means a save would delete hand-written content, so
// shcl_save_file refuses then (shcl_save_file_lossy overrides), and
// shcl_save_file_keep_lines does when it cannot keep the lines.
static size_t kept_in(const ShclVecLead *v) {
	size_t n = 0;
	for (size_t i = 0; i < v->len; i++) if (lead_is_kept_line(&v->data[i])) n++;
	return n;
}

static size_t kept_among(const ShclVecAmong *v) {
	size_t n = 0;
	for (size_t i = 0; i < v->len; i++) if (lead_is_kept_line(&v->data[i].lead)) n++;
	return n;
}

/* Kept lines in all of one node's trivia lists. */
static size_t kept_in_lists(const ShclNode *nd) {
	const ShclTrivia *t = nd->trivia;
	if (!t) return 0;
	return kept_in(&t->leading) + kept_in(&t->after) + kept_in(&t->inside) + kept_among(&t->among);
}

/* Kept lines in every list of the subtree under the nodes in stack[0..len),
   those nodes included. A stack, since a recursive walk overflowed Windows'
   1 MB main stack on the deepest legal document; each node goes on it once,
   so the node count bounds it. */
static size_t kept_walk(const shcl_doc *d, size_t *stack, size_t len) {
	size_t n = 0;
	while (len) {
		const ShclNode *nd = &NODE(d, stack[--len]);
		n += kept_in_lists(nd);
		for (size_t k = 0; k < nd->children.len; k++) stack[len++] = nd->children.data[k];
	}
	return n;
}

static size_t *kept_stack(const shcl_doc *d) {
	size_t *stack = (size_t *)malloc((d->nodes.len + 1) * sizeof *stack);
	if (!stack) { SHCL_OOM(); abort(); }
	return stack;
}

/* Kept lines in the live tree and the orphans. From ROOT, since a removed node
   stays in the arena. */
static size_t kept_lines(const shcl_doc *d) {
	size_t *stack = kept_stack(d);
	stack[0] = ROOT;
	size_t n = kept_in(&d->orphans) + kept_walk(d, stack, 1);
	free(stack);
	return n;
}

/* Kept lines the document owes and no longer holds. Free on a document that
   never had one. */
static size_t kept_shortfall(const shcl_doc *d) {
	if (d->kept_owed == 0) return 0;
	size_t have = kept_lines(d);
	return have < d->kept_owed ? d->kept_owed - have : 0;
}

/* The kept lines a remove of node takes, by design.md's table: every one
   written inside its block, and the one written as its own line. Read from
   where the lines sit before the edit, so a remove that drops one beside its
   target is caught by the gate rather than allowed. */
static size_t kept_taken(shcl_doc *d, size_t node) {
	const ShclNode *nd = &NODE(d, node);
	size_t n = 0;
	if (nd->trivia) n = kept_in(&nd->trivia->inside) + kept_among(&nd->trivia->among);
	if (heads_block(&d->scratch, nd) && lead_is_kept_line(&nd->trivia->leading.data[nd->trivia->leading.len - 1])) n++;
	size_t *stack = kept_stack(d);
	for (size_t k = 0; k < nd->children.len; k++) stack[k] = nd->children.data[k];
	n += kept_walk(d, stack, nd->children.len);
	free(stack);
	return n;
}

size_t shcl_lost_count(const shcl_doc *d) { return d->lost + kept_shortfall(d); }

size_t shcl_error_count(const shcl_doc *d) {
	size_t n = 0;
	for (size_t i = 0; i < d->diags.len; i++) if (d->diags.data[i].sev == SHCL_SEV_ERROR) n++;
	return n;
}

/* What a load and validate holds between its calls. Off the frame, so the
   recovery point below can still reach it: a longjmping SHCL_OOM skips this
   frame, and every cut-short call used to keep the document, the schema and
   the validation for good (20260918b item 22). */
typedef struct { shcl_doc *d, *sd; shcl_validation *v; ShclArena tmp; } ShclLoadOwn;

static void load_release(ShclLoadOwn *own, int keep_doc) {
	arena_free(&own->tmp);
	shcl_validation_free(own->v);
	shcl_free(own->sd);
	if (keep_doc) doc_guard(own->d, NULL);
	else shcl_free(own->d);
	free(own);
}

shcl_doc *shcl_load_and_validate(const char *text, size_t len, const char *schema, size_t slen, shcl_strictness s) {
	ShclLoadOwn *volatile own = (ShclLoadOwn *)calloc(1, sizeof *own);
	if (!own) return NULL;
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		load_release(own, 0);
		return NULL;
	}
	arena_guard(&own->tmp, &panic);
	shcl_doc *d = own->d = shcl_parse_with(text, len, s);
	if (!d) { load_release(own, 0); return NULL; }
	doc_guard(d, &panic);
	ShclStr st; st.p = schema ? schema : ""; st.n = schema ? slen : 0;
	if (s_trim(st).n != 0) {
		shcl_doc *sd = own->sd = shcl_parse(schema, slen);
		if (!sd) { load_release(own, 0); return NULL; }
		doc_guard(sd, &panic);
		// A schema that did not load would silently drop the constraints on
		// its broken lines, or report every field as unknown - either way
		// blaming the document for the schema. Say so instead, as `check`
		// does, and validate nothing.
		int sbad = 0;
		for (size_t i = 0; i < sd->diags.len; i++) if (sd->diags.data[i].sev == SHCL_SEV_ERROR) { sbad = 1; break; }
		if (sbad) {
			push_diag(d, 0, SHCL_SEV_ERROR, "V099", s_lit("schema failed to load"));
			load_release(own, 1);
			return d;
		}
		shcl_validation *v = own->v = shcl_validate(d, sd);
		if (!v) { load_release(own, 0); return NULL; }
		// The validate disarmed the document's read arenas on its way out.
		doc_guard(d, &panic);
		for (size_t i = 0; i < v->diags.len; i++) {
			ShclDiag dg = v->diags.data[i];
			/* the validation arena dies below; codes are static strings */
			dg.message = s_dup(&d->arena, dg.message);
			ShclVecDiag_push(&d->arena, &d->diags, dg);
		}
		suppress_repeats_in(&own->tmp, sd, d);
		suppress_reopens_in(&own->tmp, sd, d);
	}
	load_release(own, 1);
	return d;
}

// --- File tier (optional; compile out with -DSHCL_NO_FILE_IO) ----------------

#ifndef SHCL_NO_FILE_IO
#include <errno.h>
#include <fcntl.h>
#ifdef _WIN32
	#include <windows.h>
	// The save's temp-file create reads and sets DACLs. mingw links advapi32
	// by default; gcc refuses the pragma it does not know under -Werror.
	#ifdef _MSC_VER
		#pragma comment(lib, "advapi32")
	#endif
	#include <io.h>
	#include <process.h>
	#include <sys/stat.h>
	#include <wchar.h>
#else
	#include <unistd.h>
	#include <sys/stat.h>
	// realpath is XSI; declared here so the single-header build works under a
	// plain -std=c11 -D_POSIX_C_SOURCE consumer too (the symbol is always in
	// libc even when the prototype is feature-gated away).
	extern char *realpath(const char *, char *);
#endif

#ifdef _WIN32
// The narrow file calls read a path in the active code page, so a UTF-8 path
// with anything outside it cannot be opened - or worse, opens a mojibake name
// that round-trips through the same mistake. Convert once and use the wide
// forms. Bad UTF-8 fails (EINVAL) rather than folding to U+FFFD, which would
// quietly name a different file. malloc'd, and the caller frees it.
static wchar_t *shcl_widen(const char *s) {
	int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
	wchar_t *w = n > 0 ? (wchar_t *)malloc((size_t)n * sizeof(wchar_t)) : NULL;
	if (w) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n);
	else errno = n > 0 ? ENOMEM : EINVAL;
	return w;
}

// The Win32 calls report through GetLastError and leave errno alone, and
// errno is what the header promises a failed write describes. The common
// causes map; the rest is EIO, which at least is not "Success".
static int shcl_errno_from_win32(DWORD e) {
	switch (e) {
	case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: case ERROR_INVALID_DRIVE: return ENOENT;
	case ERROR_ACCESS_DENIED: case ERROR_SHARING_VIOLATION: case ERROR_LOCK_VIOLATION: case ERROR_USER_MAPPED_FILE: return EACCES;
	case ERROR_ALREADY_EXISTS: case ERROR_FILE_EXISTS: return EEXIST;
	case ERROR_NOT_ENOUGH_MEMORY: case ERROR_OUTOFMEMORY: return ENOMEM;
	case ERROR_INVALID_NAME: case ERROR_BAD_PATHNAME: case ERROR_INVALID_PARAMETER: case ERROR_FILENAME_EXCED_RANGE: return EINVAL;
	case ERROR_DISK_FULL: case ERROR_HANDLE_DISK_FULL: return ENOSPC;
	case ERROR_BUSY: return EBUSY;
	case ERROR_DIRECTORY: return ENOTDIR;
	// A link that points at itself. Without this the message read "Invalid
	// argument" where the other three say "too many levels of symbolic links",
	// which is the wording the Save outcomes table uses.
	case ERROR_CANT_RESOLVE_FILENAME: return ELOOP;
	default: return EIO;
	}
}

static int shcl_publish_new_file(const wchar_t *tmp, const wchar_t *target);

// A scanner or an indexer that opens the fresh temp file blocks the replace and
// the rename both, for a moment, and one try made that a failed save.
#define SHCL_PUBLISH_TRIES 5
#define SHCL_PUBLISH_PAUSE_MS 50

static int shcl_path_there(const wchar_t *p) { return GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES; }

// The temp name with its `.tmp` swapped for `.bak`, so the two sit side by side
// and are the same length. The last `.tmp` is the one the save added. Malloc'd
// and the caller frees it; NULL when that fails.
static wchar_t *shcl_backup_name(const wchar_t *tmp) {
	size_t n = wcslen(tmp);
	wchar_t *b = (wchar_t *)malloc((n + 5) * sizeof(wchar_t));
	if (!b) return NULL;
	memcpy(b, tmp, (n + 1) * sizeof(wchar_t));
	wchar_t *name = b;
	for (wchar_t *c = b; *c; c++)
		if (*c == L'\\' || *c == L'/') name = c + 1;
	wchar_t *at = NULL;
	for (wchar_t *p = wcsstr(name, L".tmp"); p; p = wcsstr(p + 1, L".tmp")) at = p;
	if (at) memcpy(at, L".bak", 4 * sizeof(wchar_t));
	else memcpy(b + n, L".bak", 5 * sizeof(wchar_t));
	return b;
}

// The exclusive create of a save's temp file over an existing file. A plain
// create takes the directory's ACL, so the new text of a private config sat
// where others could read it until the replace, and a fallback move published
// that wider ACL. The temp is born with the file's DACL instead. Best effort:
// when that cannot be read, the directory's it is, as for a new file. An fd,
// or -1 with errno set.
static int shcl_create_like(const wchar_t *wfrom, const wchar_t *wto) {
	PSECURITY_DESCRIPTOR sd = NULL;
	DWORD need = 0;
	GetFileSecurityW(wfrom, DACL_SECURITY_INFORMATION, NULL, 0, &need);
	if (need > 0 && (sd = (PSECURITY_DESCRIPTOR)malloc(need)) != NULL && !GetFileSecurityW(wfrom, DACL_SECURITY_INFORMATION, sd, need, &need)) {
		free(sd);
		sd = NULL;
	}
	SECURITY_ATTRIBUTES sa = { (DWORD)sizeof sa, sd, FALSE };
	HANDLE h = CreateFileW(wto, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, sd ? &sa : NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
	if (h == INVALID_HANDLE_VALUE) {
		errno = shcl_errno_from_win32(GetLastError());
		free(sd);
		return -1;
	}
	// A create takes the ACEs but drops the auto-inherited mark, and without it
	// a later change to the directory's ACL does not reach the file once a
	// fallback move makes the temp the config. Setting the same DACL again with
	// the request bit puts it back.
	SECURITY_DESCRIPTOR_CONTROL control = 0;
	DWORD revision = 0;
	if (sd && GetSecurityDescriptorControl(sd, &control, &revision) && (control & SE_DACL_AUTO_INHERITED)
		&& SetSecurityDescriptorControl(sd, SE_DACL_AUTO_INHERIT_REQ, SE_DACL_AUTO_INHERIT_REQ))
		(void)SetFileSecurityW(wto, DACL_SECURITY_INFORMATION, sd);
	free(sd);
	int fd = _open_osfhandle((intptr_t)h, _O_WRONLY | _O_BINARY);
	if (fd < 0) {
		int e = errno;
		CloseHandle(h);
		DeleteFileW(wto);
		errno = e;
	}
	return fd;
}

// ReplaceFile copies the destination's ACLs, security attributes and named
// streams onto the replacement; a move publishes a brand-new file and leaves
// all of it behind. What it does NOT copy is the basic attributes - hidden and
// system - which the save re-applies by hand. It needs the destination to
// exist, and it fails rather than skip a merge it cannot do (no WRITE_DAC,
// say), so a create and any failure fall back to MoveFileEx - which is there
// regardless because C rename() will not replace an existing file on Windows at
// all. WRITE_THROUGH is asked for and documented as unsupported by ReplaceFile;
// the move's own WRITE_THROUGH is the one that means something.
//
// ReplaceFile is given a backup name, because without one a failure between its
// two moves deletes the old file (1176) or leaves it under a name nobody is told
// (1177). With one, 1177 leaves it at the backup and nothing at the target, so
// the old file is put back. If even that fails, neither file is removed, and
// since errno cannot say where they are, the file tier's comment at the top
// does. Any other failure removes the temp file.
static int shcl_publish_file(const wchar_t *tmp, const wchar_t *target) {
	wchar_t *backup = shcl_backup_name(tmp);
	if (!backup) { _wremove(tmp); errno = ENOMEM; return 0; }
	int moved_away = 0;
	DWORD err = 0;
	for (int tries = 1;; tries++) {
		if (!moved_away && shcl_path_there(target)) {
			// The save has gone through, so a backup that will not come off
			// is left rather than failing it.
			if (ReplaceFileW(target, tmp, backup, REPLACEFILE_WRITE_THROUGH, NULL, NULL)) {
				_wremove(backup);
				free(backup);
				return 1;
			}
			moved_away = !shcl_path_there(target) && shcl_path_there(backup);
		}
		if (MoveFileExW(tmp, target, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
			if (moved_away) _wremove(backup);
			free(backup);
			return 1;
		}
		err = GetLastError();
		if (tries == SHCL_PUBLISH_TRIES) break;
		Sleep(SHCL_PUBLISH_PAUSE_MS);
	}
	if (shcl_path_there(target) || (moved_away && shcl_publish_new_file(backup, target))) _wremove(tmp);
	free(backup);
	errno = shcl_errno_from_win32(err);
	return 0;
}

// The publish for a save that found nothing at the path, which must not replace
// a file that turned up since. A move without the replace flag refuses an
// existing target, and needs no hard links.
static int shcl_publish_new_file(const wchar_t *tmp, const wchar_t *target) {
	int ok = MoveFileExW(tmp, target, MOVEFILE_WRITE_THROUGH) != 0;
	if (!ok) errno = shcl_errno_from_win32(GetLastError());
	return ok;
}
#endif

#ifdef _WIN32
static char *shcl_resolve_path(const char *file, int for_save);
#endif
static FILE *shcl_fopen_rb(const char *path) {
#ifdef _WIN32
	// Through the same resolver the write side uses, so a read past MAX_PATH
	// works too: the narrow and wide file calls both refuse such a path unless
	// it has the long-path prefix. A path the resolver cannot resolve is
	// opened as given, which is what it did before. A read never probes a
	// dangling link: the probe creates a file where the link points, and a
	// read has nothing to create.
	char *real = shcl_resolve_path(path, 0);
	wchar_t *w = shcl_widen(real ? real : path);
	free(real);
	FILE *f = w ? _wfopen(w, L"rb") : NULL;
	int e = errno; free(w); errno = e;
	return f;
#else
	return fopen(path, "rb");
#endif
}

// Where the directory part of TARGET ends: the last separator, or NULL for a
// bare name. Windows takes either slash, and a path built with the platform
// separator is all backslashes; a drive-relative `C:x` has no separator at all
// and splits after the colon, where the reference's Path::parent splits it.
static const char *shcl_last_sep(const char *target) {
	const char *sep = strrchr(target, '/');
#ifdef _WIN32
	const char *bs = strrchr(target, '\\');
	if (bs && (!sep || bs > sep)) sep = bs;
	if (!sep && target[0] && target[1] == ':') sep = target + 1;
#endif
	return sep;
}

// At most the first 64 bytes of the name, cut where a character starts, so the
// temp's own length is fixed. Keeping the whole name put the temp over the
// filesystem's 255 bytes at a target name in the low 240s - and the exact
// cut-off moved with the width of the process id, so the same file saved on one
// machine and failed on another. Bytes, not characters: 64 characters of four
// bytes each put it back over. A truncated name can collide; the exclusive
// create and the eight attempts already answer that.
static size_t s_tmp_base(const char *b) {
	size_t i = 0;
	while (i < SHCL_TMP_NAME_BYTES && b[i]) i++;
	while (i > 0 && ((unsigned char)b[i] & 0xC0u) == 0x80u) i--;
	return i;
}

#ifdef _WIN32
// The way back from shcl_widen. malloc'd UTF-8 the caller frees; NULL with
// errno saying why.
static char *shcl_narrow(const wchar_t *w) {
	int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
	char *s = n > 0 ? (char *)malloc((size_t)n) : NULL;
	if (s) WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
	else errno = n > 0 ? ENOMEM : EINVAL;
	return s;
}
// Something is at the path and it is not a disk file: a device name such as
// CON, NUL or COM1. An attribute test cannot see one - a device answers
// GetFileAttributes with the same ARCHIVE bit an ordinary file does - so the
// save read it as a file, tried to replace it, and the refusal came from
// whichever later step happened to fail. Answers 0 for a path with nothing at
// it, which is a save's ordinary create.
static int shcl_not_a_disk_file(const char *path) {
	wchar_t *w = shcl_widen(path);
	if (!w) return 0;
	// The handle first, since it is the OS's own answer and it keeps an exotic
	// but real path (a volume-prefixed `\\.\C:\dir\file`) out of the device case.
	HANDLE h = CreateFileW(w, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
	                       NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
	if (h != INVALID_HANDLE_VALUE) {
		DWORD type = GetFileType(h);
		CloseHandle(h); free(w);
		return type != FILE_TYPE_DISK;
	}
	// CON refuses that open outright (ERROR_INVALID_PARAMETER), and a serial
	// port nobody has answers not-found, so a failed open cannot mean "nothing
	// is there". A reserved name resolves into the device namespace from
	// whatever directory it is typed in, and the full path is where that shows:
	// `\\.\CON` against a drive path for an ordinary name. Long paths overflow
	// the buffer and fall through to the create, which is what they did before.
	wchar_t full[MAX_PATH];
	DWORD n = GetFullPathNameW(w, MAX_PATH, full, NULL);
	free(w);
	// A drive after the prefix is a volume path to a file that is not there
	// yet, which a create has to be let through (20260926 item 8).
	int drive = n >= 6 && ((full[4] >= L'A' && full[4] <= L'Z') || (full[4] >= L'a' && full[4] <= L'z')) && full[5] == L':';
	return n > 0 && n < MAX_PATH
	       && full[0] == L'\\' && full[1] == L'\\' && full[2] == L'.' && full[3] == L'\\' && !drive;
}
// The path a save actually rewrites. A symlink or junction is followed, so a
// save through a linked-in config replaces the file it points at rather than
// the link - the same thing the POSIX side has always done. The answer comes
// back \\?\-prefixed, which is also what takes a path past MAX_PATH, so the
// prefix is kept only where the name would otherwise be too long for the temp
// file beside it; a short path stays the plain name it was. A file that is not
// there yet has no final path, so its full path is prefixed by hand. malloc'd
// UTF-8; NULL with errno saying why. A read passes FOR_SAVE 0 and gets
// ENOENT for a dangling link rather than the probe below.
static char *shcl_resolve_path(const char *file, int for_save) {
	wchar_t *w = shcl_widen(file);
	if (!w) return NULL;
	wchar_t *full = NULL;
	HANDLE h = CreateFileW(w, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
	                       NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
	if (h != INVALID_HANDLE_VALUE) {
		DWORD need = GetFinalPathNameByHandleW(h, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
		if (need && (full = (wchar_t *)malloc((size_t)need * sizeof *full))
		    && !GetFinalPathNameByHandleW(h, full, need, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS)) {
			free(full); full = NULL;
		}
		CloseHandle(h);
	}
	if (!full) {
		// A dangling link: the open above follows links, so it failed, and the
		// full-path fallback below would name the link itself - so the save
		// would put a regular file where the link was. Windows follows a link
		// on create, so creating through it names the file the link points at;
		// the probe file comes away again and the save publishes there. A link
		// this cannot resolve (it points at a directory, or it cycles) is an
		// error rather than a fall-through, since falling through is what ate
		// the link. Rust and Go create through the link and keep it, and the
		// Save outcomes table in design.md says that is the rule.
		WIN32_FIND_DATAW fd;
		HANDLE fh = FindFirstFileW(w, &fd);
		int is_link = 0;
		if (fh != INVALID_HANDLE_VALUE) {
			is_link = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
			          && (fd.dwReserved0 == IO_REPARSE_TAG_SYMLINK || fd.dwReserved0 == IO_REPARSE_TAG_MOUNT_POINT);
			FindClose(fh);
		}
		if (is_link && !for_save) { free(w); errno = ENOENT; return NULL; }
		if (is_link) {
			HANDLE ch = CreateFileW(w, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
			                        NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
			if (ch == INVALID_HANDLE_VALUE) { DWORD e = GetLastError(); free(w); errno = shcl_errno_from_win32(e); return NULL; }
			DWORD need = GetFinalPathNameByHandleW(ch, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
			if (need && (full = (wchar_t *)malloc((size_t)need * sizeof *full))
			    && !GetFinalPathNameByHandleW(ch, full, need, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS)) {
				free(full); full = NULL;
			}
			CloseHandle(ch);
			if (!full) { free(w); errno = EIO; return NULL; }
			DeleteFileW(full);
		} else {
			// Not there yet (or not openable): build the long-path spelling from
			// the full path instead. \\server\share becomes \\?\UNC\server\share.
			DWORD need = GetFullPathNameW(w, 0, NULL, NULL);
			if (!need) { free(w); errno = shcl_errno_from_win32(GetLastError()); return NULL; }
			wchar_t *fp = (wchar_t *)malloc((size_t)need * sizeof *fp);
			if (!fp) { free(w); errno = ENOMEM; return NULL; }
			if (!GetFullPathNameW(w, need, fp, NULL)) {
				DWORD e = GetLastError();
				free(fp); free(w); errno = shcl_errno_from_win32(e); return NULL;
			}
			// Already prefixed (`\\?\` or `\\.\`): it is the spelling a caller
			// reaches for past MAX_PATH, and prefixing it again built
			// `\\?\UNC\?\C:\...`, which no create can open. Under MAX_PATH the
			// strip below happened to undo that, so it bit only long paths.
			int pref = fp[0] == L'\\' && fp[1] == L'\\' && (fp[2] == L'?' || fp[2] == L'.') && fp[3] == L'\\';
			int unc = !pref && fp[0] == L'\\' && fp[1] == L'\\';
			size_t fn = wcslen(fp);
			full = (wchar_t *)malloc((fn + 10) * sizeof *full);
			if (!full) { free(fp); free(w); errno = ENOMEM; return NULL; }
			if (pref) wmemcpy(full, fp, fn + 1);
			else {
				const wchar_t *head = unc ? L"\\\\?\\UNC" : L"\\\\?\\";
				size_t hn = wcslen(head), skip = unc ? 1 : 0;
				wmemcpy(full, head, hn);
				wmemcpy(full + hn, fp + skip, fn - skip + 1);
			}
			free(fp);
		}
	}
	free(w);
	char *out = shcl_narrow(full);
	free(full);
	if (!out) return NULL;
	// The temp file sits beside the target with a suffix of its own, so the
	// prefix stays on anything near the limit, not only over it. Below that it
	// comes off, so an ordinary save writes the plain name it always did.
	size_t on = strlen(out);
	if (on + 48 < MAX_PATH) {
		if (!strncmp(out, "\\\\?\\UNC\\", 8)) { memmove(out + 2, out + 8, on - 8 + 1); }
		else if (!strncmp(out, "\\\\?\\", 4)) memmove(out, out + 4, on - 4 + 1);
	}
	return out;
}
static char *shcl_resolve_target(const char *file) { return shcl_resolve_path(file, 1); }
#endif

#ifndef _WIN32
static int shcl_names_a_directory(const char *path);
// The path a save actually rewrites. A symlink is followed so the write goes
// through it; realpath does that but needs the target to exist, so a dangling
// link is walked by hand and the file is created where it points. A path that
// is no link at all is a plain create at the path as given. A link cycle is an
// error (errno ELOOP): silently creating a regular file in its place would be
// the exact replacement the symlink walk exists to avoid. malloc'd; NULL with
// errno saying why.
static char *shcl_resolve_target(const char *file) {
	char *p = realpath(file, NULL);
	if (p) return p;
	size_t pn = strlen(file);
	if (!(p = (char *)malloc(pn + 1))) return NULL;
	memcpy(p, file, pn + 1);
	for (int hop = 0; hop < 40; hop++) {
		size_t cap = 256; char *link = NULL; ssize_t got;
		for (;;) {
			char *grown = (char *)realloc(link, cap);
			if (!grown) { free(link); free(p); return NULL; }
			link = grown;
			got = readlink(p, link, cap);
			if (got < 0 || (size_t)got < cap) break;
			cap *= 2;
		}
		if (got < 0) { free(link); break; }
		link[got] = '\0';
		// A link whose text ends in a separator, `.` or `..` can only reach a
		// directory, and the kernel refuses to create a file through it.
		if (shcl_names_a_directory(link)) { free(link); free(p); errno = EISDIR; return NULL; }
		if (link[0] == '/') { free(p); p = link; continue; }
		// Relative to the link's own directory; a bare name sits in ".".
		const char *slash = strrchr(p, '/');
		size_t dn = slash ? (size_t)(slash - p) : 0;
		char *joined = (char *)malloc(dn + (size_t)got + 3);
		if (!joined) { free(link); free(p); return NULL; }
		if (!slash) { memcpy(joined, "./", 2); memcpy(joined + 2, link, (size_t)got + 1); }
		else if (dn == 0) { joined[0] = '/'; memcpy(joined + 1, link, (size_t)got + 1); }
		else { memcpy(joined, p, dn); joined[dn] = '/'; memcpy(joined + dn + 1, link, (size_t)got + 1); }
		free(link); free(p); p = joined;
	}
	{
		char probe[1];
		if (readlink(p, probe, sizeof probe) >= 0) { free(p); errno = ELOOP; return NULL; }
	}
	const char *slash = strrchr(p, '/');
	if (!slash) return p;
	size_t dn = (size_t)(slash - p);
	char *dir = (char *)malloc(dn ? dn + 1 : 2);
	if (!dir) return p;
	if (dn) { memcpy(dir, p, dn); dir[dn] = '\0'; } else { dir[0] = '/'; dir[1] = '\0'; }
	char *rd = realpath(dir, NULL);
	free(dir);
	if (!rd) return p;
	size_t rn = strlen(rd), nn = strlen(slash + 1);
	if (rn == 1 && rd[0] == '/') rn = 0; // the root already ends in the separator
	char *out = (char *)malloc(rn + nn + 2);
	if (out) { memcpy(out, rd, rn); out[rn] = '/'; memcpy(out + rn + 1, slash + 1, nn + 1); free(p); p = out; }
	free(rd);
	return p;
}

// fsync the directory a save published into. The fsync on the file only covered
// the file; the rename is a directory change, so without this a power cut right
// after a save can lose the publish and leave the old content. Best effort - a
// filesystem that refuses an fsync on a directory is not a reason to fail a
// write that already succeeded.
static void shcl_sync_dir(const char *target) {
	const char *slash = strrchr(target, '/');
	size_t n = slash ? (size_t)(slash - target) : 0;
	char *dir = (char *)malloc(n + 2);
	if (!dir) return;
	if (!slash) { dir[0] = '.'; n = 1; }
	else if (n == 0) { dir[0] = '/'; n = 1; }
	else memcpy(dir, target, n);
	dir[n] = '\0';
	int dfd = open(dir, O_RDONLY);
	if (dfd >= 0) { (void)fsync(dfd); close(dfd); }
	free(dir);
}

// The publish for a save that found nothing at the path, which must not replace
// a file that turned up since. A hard link fails on anything at the target, so
// the check and the publish are one step, and the temp name comes off after.
// The save has gone through by then, so a temp name that will not come off is
// left rather than failing it. A filesystem with no hard links gets a check and
// a rename, which leaves only that short gap.
static int shcl_publish_new_file(const char *tmp, const char *target) {
	if (link(tmp, target) == 0) { (void)unlink(tmp); return 1; }
	if (errno == EEXIST) return 0;
	struct stat st;
	if (lstat(target, &st) == 0) { errno = EEXIST; return 0; }
	return rename(tmp, target) == 0;
}

// Move the finished temp file over the target; see the windows one for why that
// is a plain rename only here. A failure removes the temp file.
static int shcl_publish_file(const char *tmp, const char *target) {
	if (rename(tmp, target) == 0) return 1;
	int e = errno;
	(void)unlink(tmp);
	errno = e;
	return 0;
}
#endif

/* A path that names a directory rather than a file: it ends in a separator, or
   its last component is `.` or `..`. The OS refuses to open such a path as a
   regular file, but a path cleanup drops the trailing separator first, so a
   save through `f/.` used to rewrite `f` in some bindings. */
static int shcl_names_a_directory(const char *path) {
	size_t n = strlen(path);
	if (!n) return 0;
	char lastc = path[n - 1];
	if (lastc == '/') return 1;
#ifdef _WIN32
	if (lastc == '\\') return 1;
#endif
	const char *last = shcl_last_sep(path);
	last = last ? last + 1 : path;
	return !strcmp(last, ".") || !strcmp(last, "..");
}

// The file tier's write mechanism (also what the CLI's --write uses): a temp
// file in the same dir, then a rename over the target, so an interrupted write
// can never truncate the config it rewrites. The data is synced before the
// rename so a crash cannot publish an empty file. The target is resolved
// through symlinks first (a dangling link gets its file created where it
// points) and the original's whole mode - setuid, setgid and sticky included,
// as an editor's rewrite would keep it - is copied onto the temp file; other
// hard links to the old inode keep the old content (inherent to rename).
// Returns 1 on success, 0 on failure with errno left describing it.
int shcl_write_file_atomic(const char *path, const char *data, size_t n) {
	if (shcl_names_a_directory(path)) { errno = EISDIR; return 0; }
#ifndef _WIN32
	char *real = shcl_resolve_target(path);
	if (!real) return 0;
	const char *target = real;
	#define SHCL_FILE_CLEANUP() do { free(real); } while (0)
	#define SHCL_FILE_UNLINK() remove(tmp)
#else
	char *real = shcl_resolve_target(path);
	if (!real) return 0;
	const char *target = real;
	wchar_t *wtarget = shcl_widen(target), *wtmp = NULL;
	if (!wtarget) { free(real); return 0; }
	// A read-only file cannot be replaced, and a read-only temp cannot be
	// removed after a failure, so the attribute comes off the target for the
	// publish and goes back on the new file after it - the same outcome as
	// POSIX, where the rename never needed the file writable. Hidden and system
	// ride back the same way: ReplaceFile's documented preserve list does not
	// include the basic attributes, and the fallback move keeps nothing, so a
	// hidden config came back visible.
	#define SHCL_CARRIED_ATTRS ((DWORD)(FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM))
	DWORD attrs = GetFileAttributesW(wtarget);
	int read_only = attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_READONLY) != 0;
	DWORD carried = attrs == INVALID_FILE_ATTRIBUTES ? 0 : (attrs & SHCL_CARRIED_ATTRS);
	#define SHCL_FILE_CLEANUP() do { free(real); free(wtarget); free(wtmp); } while (0)
	#define SHCL_FILE_UNLINK() _wremove(wtmp)
#endif
	const char *slash = shcl_last_sep(target);
	size_t tmpcap = strlen(target) + 48;
	char *tmp = (char *)malloc(tmpcap);
	if (!tmp) { SHCL_FILE_CLEANUP(); return 0; }
	// Exclusive create: anything already sitting at the predictable name -
	// including a planted symlink - must fail rather than be written through.
	// A file that already exists keeps its own mode, so its temp is born private
	// and the real mode goes on below - the copy is never briefly readable to
	// anyone the original was not. A file that does not exist yet has no mode to
	// preserve, so it takes the one an ordinary create would: 0666 narrowed by
	// the umask, like every other file the user's tools produce.
#ifndef _WIN32
	struct stat st;
	int have_st = (stat(target, &st) == 0);
	// Only a regular file is replaced. A rename over a FIFO or a device node
	// swaps it for a regular file at exit 0. Save outcomes in design.md is the
	// rule for what a save does with each thing it can find at the path. POSIX
	// has no errno for "not a regular file"; EINVAL is the nearest.
	if (have_st && !S_ISREG(st.st_mode)) {
		errno = S_ISDIR(st.st_mode) ? EISDIR : EINVAL;
		free(tmp); SHCL_FILE_CLEANUP(); return 0;
	}
#else
	if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
		errno = EISDIR;
		free(tmp); SHCL_FILE_CLEANUP(); return 0;
	}
	// The same rule as the POSIX arm above: only a regular file is replaced. The
	// attribute test alone answers just "is it a directory", and a device has no
	// attributes to test.
	if (shcl_not_a_disk_file(target)) {
		errno = EINVAL;
		free(tmp); SHCL_FILE_CLEANUP(); return 0;
	}
#endif
	int fd = -1;
	for (int attempt = 0; attempt < 8; attempt++) {
		if (slash) snprintf(tmp, tmpcap, "%.*s.%.*s.tmp%ld.%d", (int)(slash - target + 1), target, (int)s_tmp_base(slash + 1), slash + 1, (long)getpid(), attempt);
		else snprintf(tmp, tmpcap, ".%.*s.tmp%ld.%d", (int)s_tmp_base(target), target, (long)getpid(), attempt);
#ifdef _WIN32
		free(wtmp);
		if (!(wtmp = shcl_widen(tmp))) break;
		fd = attrs != INVALID_FILE_ATTRIBUTES ? shcl_create_like(wtarget, wtmp)
			: _wopen(wtmp, _O_WRONLY | _O_CREAT | _O_EXCL | _O_BINARY, _S_IREAD | _S_IWRITE);
#else
		fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, have_st ? 0600 : 0666);
#endif
		if (fd >= 0) break;
	}
	if (fd < 0) { free(tmp); SHCL_FILE_CLEANUP(); return 0; }
	FILE *f = fdopen(fd, "wb");
	if (!f) { close(fd); SHCL_FILE_UNLINK(); free(tmp); SHCL_FILE_CLEANUP(); return 0; }
	int ok = (n == 0 || fwrite(data, 1, n, f) == n) && fflush(f) == 0;
#ifdef _WIN32
	ok = ok && _commit(_fileno(f)) == 0;
#else
	ok = ok && fsync(fileno(f)) == 0;
	// On the descriptor, so umask cannot narrow it the way it narrows a create
	// mode, and after the data, because a write by anyone but root clears
	// setuid/setgid. Best effort: a filesystem that cannot store the mode is
	// not a failure.
	// The group first, because a chown clears setuid/setgid on most systems.
	// Best effort like the mode: a caller who is not in the old group keeps its
	// own, which is what it had before this. The owner is not copied - see the
	// file tier in spec.md.
	// The result goes into a variable rather than a (void) cast: glibc marks
	// fchown warn_unused_result, and a cast does not silence that everywhere
	// (gcc 13 on the hosted runner refuses it, gcc 14 here does not).
	if (ok && have_st) { int chown_rc = fchown(fileno(f), (uid_t)-1, st.st_gid); (void)chown_rc; }
	if (ok && have_st) (void)fchmod(fileno(f), st.st_mode & 07777);
#endif
	ok = (fclose(f) == 0) && ok;
	// Nothing was at the path when the save started, so nothing that turns up
	// before the publish is written over. A failed replace decides for itself
	// whether the temp file can go, since on windows it may be all that is left.
	int replacing = 0;
#ifdef _WIN32
	if (read_only) SetFileAttributesW(wtarget, attrs & ~(DWORD)FILE_ATTRIBUTE_READONLY);
	if (ok) {
		replacing = attrs != INVALID_FILE_ATTRIBUTES;
		ok = replacing ? shcl_publish_file(wtmp, wtarget) : shcl_publish_new_file(wtmp, wtarget);
	}
	if (read_only || carried) {
		DWORD now = GetFileAttributesW(wtarget);
		if (now != INVALID_FILE_ATTRIBUTES)
			SetFileAttributesW(wtarget, now | carried | (read_only ? (DWORD)FILE_ATTRIBUTE_READONLY : 0));
	}
	#undef SHCL_CARRIED_ATTRS
#else
	if (ok) {
		replacing = have_st;
		ok = replacing ? shcl_publish_file(tmp, target) : shcl_publish_new_file(tmp, target);
	}
	if (ok) shcl_sync_dir(target);
#endif
	// The unlink must not overwrite the errno the failure left behind.
	if (!ok && !replacing) { int e = errno; SHCL_FILE_UNLINK(); errno = e; }
	free(tmp);
	SHCL_FILE_CLEANUP();
#undef SHCL_FILE_CLEANUP
#undef SHCL_FILE_UNLINK
	return ok ? 1 : 0;
}

// Whole-buffer UTF-8 validation. The parser assumes well-formed input, so the
// file tier has to reject bad bytes the way the reference's read-to-string and
// python's decoding open do.
static int shcl_utf8_valid(const char *p, size_t n) {
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

// File tier, read half on its own: the text of PATH, malloc'd and
// NUL-terminated (the caller frees it), with *LEN set and *STATUS CLEAN; or
// NULL with the status saying why not - NOT_FOUND, or UNREADABLE for
// everything else (permissions, a directory, bad encoding, or a file past
// MAX_BYTES; 0 is no cap). shcl_load_file is this plus a parse. A consumer
// that needs the exact bytes it last saw - to tell its own save coming back as
// a change notification from somebody else's edit - or a bound on how much it
// will read before a parse, calls this and parses the text itself.
char *shcl_read_file(const char *path, size_t max_bytes, size_t *len, shcl_file_status *status) {
	FILE *f = shcl_fopen_rb(path);
	if (!f) {
		if (status) *status = (errno == ENOENT) ? SHCL_FILE_NOT_FOUND : SHCL_FILE_UNREADABLE;
		return NULL;
	}
	// One byte past the cap is read, so a file exactly at it passes and one
	// over is caught without trusting a length from stat.
	size_t limit = (max_bytes && max_bytes < (size_t)-1) ? max_bytes + 1 : (size_t)-1;
	size_t cap = (size_t)1 << 16, n = 0;
	if (cap > limit) cap = limit;
	char *buf = (char *)malloc(cap + 1);
	int rerr = buf == NULL;
	while (!rerr) {
		if (n == cap) {
			if (cap >= limit) break;
			size_t ncap = cap > limit / 2 ? limit : cap * 2;
			char *nb = (char *)realloc(buf, ncap + 1);
			if (!nb) { rerr = 1; break; }
			buf = nb; cap = ncap;
		}
		size_t got = fread(buf + n, 1, cap - n, f);
		n += got;
		if (got < cap - n + got) {
			if (ferror(f)) rerr = 1; // a directory reads this way on POSIX
			break;
		}
	}
	fclose(f);
	if (!rerr && max_bytes && n > max_bytes) rerr = 1;
	// The read succeeds on any bytes, unlike the reference's read-to-string and
	// python's decoding open - so bad encoding needs its own test, or a binary
	// file loads clean, reads back mangled, and a later save writes the mangled
	// version over the original. Its own copy rather than the CLI's: that one
	// also gates argv and stdin, which exist with the file tier compiled out.
	if (!rerr && !shcl_utf8_valid(buf, n)) rerr = 1;
	if (rerr) {
		free(buf);
		if (status) *status = SHCL_FILE_UNREADABLE;
		return NULL;
	}
	buf[n] = '\0';
	if (len) *len = n;
	if (status) *status = SHCL_FILE_CLEAN;
	return buf;
}

// File tier, load half: read and parse PATH. Never fails - the document
// always comes back usable (empty when the file could not be read), and the
// status out-param separates the four cases consumers otherwise confuse:
// absent, present-but-unreadable, parsed with errors, clean.
shcl_doc *shcl_load_file_with(const char *path, shcl_strictness s, shcl_file_status *status) {
	size_t len = 0;
	shcl_file_status st = SHCL_FILE_UNREADABLE;
	char *buf = shcl_read_file(path, 0, &len, &st);
	if (!buf) {
		if (status) *status = st;
		return shcl_parse_with("", 0, s);
	}
	shcl_doc *d = shcl_parse_with(buf, len, s);
	free(buf);
	if (!d) { if (status) *status = st; return NULL; }
	if (status) {
		*status = SHCL_FILE_CLEAN;
		for (size_t i = 0; i < d->diags.len; i++)
			if (d->diags.data[i].sev == SHCL_SEV_ERROR) { *status = SHCL_FILE_HAD_ERRORS; break; }
	}
	return d;
}

const char *shcl_file_status_name(shcl_file_status s) {
	switch (s) { case SHCL_FILE_CLEAN: return "Clean"; case SHCL_FILE_HAD_ERRORS: return "HadErrors"; case SHCL_FILE_NOT_FOUND: return "NotFound"; case SHCL_FILE_UNREADABLE: return "Unreadable"; }
	return "Clean";
}

shcl_doc *shcl_load_file(const char *path, shcl_file_status *status) {
	return shcl_load_file_with(path, SHCL_STANDARD, status);
}

// shcl_load_file_with, keeping the text for shcl_to_text_keep_lines.
shcl_doc *shcl_load_file_keep_lines(const char *path, shcl_strictness s, shcl_file_status *status) {
	size_t len = 0;
	shcl_file_status st = SHCL_FILE_UNREADABLE;
	char *buf = shcl_read_file(path, 0, &len, &st);
	if (!buf) {
		if (status) *status = st;
		return shcl_parse_with("", 0, s);
	}
	shcl_doc *d = shcl_parse_keep_lines(buf, len, s);
	free(buf);
	if (!d) { if (status) *status = st; return NULL; }
	if (status) {
		*status = SHCL_FILE_CLEAN;
		for (size_t i = 0; i < d->diags.len; i++)
			if (d->diags.data[i].sev == SHCL_SEV_ERROR) { *status = SHCL_FILE_HAD_ERRORS; break; }
	}
	return d;
}

// File tier, save half: write the document's canonical text to PATH through
// shcl_write_file_atomic. SHCL_SAVE_OK on success. Refuses when parsing lost
// content that a save would silently delete (shcl_lost_count) - that is
// SHCL_SAVE_REFUSED, distinct from SHCL_SAVE_FAILED so the caller need not
// guess which happened; shcl_save_file_lossy writes anyway.
shcl_save_result shcl_save_file(shcl_doc *d, const char *path) {
	if (shcl_lost_count(d) > 0) return SHCL_SAVE_REFUSED;
	ShclStr c = emit_canonical(d);
	return shcl_write_file_atomic(path, c.p, c.n) ? SHCL_SAVE_OK : SHCL_SAVE_FAILED;
}

// shcl_save_file without the lost-content gate: writes even when parsing
// dropped lines this save deletes. The caller owns that choice. Never returns
// SHCL_SAVE_REFUSED - the gate is the one thing it skips.
shcl_save_result shcl_save_file_lossy(shcl_doc *d, const char *path) {
	ShclStr c = emit_canonical(d);
	return shcl_write_file_atomic(path, c.p, c.n) ? SHCL_SAVE_OK : SHCL_SAVE_FAILED;
}

// shcl_save_file with shcl_to_text_keep_lines: *kept (when not NULL) is 1 when
// it kept the lines, 0 when it wrote the canonical form instead. A line the
// load dropped comes back as written when the lines are kept, so this refuses
// the way shcl_save_file does only when it would write canonical.
shcl_save_result shcl_save_file_keep_lines(shcl_doc *d, const char *path, int *kept) {
	if (kept) *kept = 0;
	ShclStr t;
	int k = keep_text(d, &t);
	if (!k && shcl_lost_count(d) > 0) return SHCL_SAVE_REFUSED;
	if (kept) *kept = k;
	return shcl_write_file_atomic(path, t.p, t.n) ? SHCL_SAVE_OK : SHCL_SAVE_FAILED;
}
#endif /* SHCL_NO_FILE_IO */

// --- Schema-driven generation (`shcl init --schema`) ------------------------

static ShclStr v_allowed_join(ShclArena *a, const ShclVCons *c) {
	ShclSB s = {0, 0, 0};
	char nb[64];
	for (size_t i = 0; i < c->a_n; i++) {
		if (i) sb_puts(a, &s, ", ");
		switch (c->akind) {
			case ALLOW_INTS: { snprintf(nb, sizeof nb, "%" PRId64, c->a_ints[i]); sb_puts(a, &s, nb); break; }
			case ALLOW_FLOATS: { char fb[SHCL_FLOAT_BUF]; ShclStr f; f.p = fb; f.n = shcl_format_float(c->a_floats[i], fb); sb_putS(a, &s, f); break; }
			case ALLOW_BOOLS: sb_puts(a, &s, c->a_bools[i] ? "true" : "false"); break;
			case ALLOW_DATES: { char db[SHCL_DT_BUF]; ShclStr d; d.p = db; d.n = shcl_datetime_str(&c->a_dates[i], db); sb_putS(a, &s, d); break; }
			case ALLOW_STRINGS: sb_putS(a, &s, c->a_strs[i]); break;
		}
	}
	return sb_S(&s);
}

// The `# type, ...` annotation line summarizing a constraint, ASCII only.
static ShclStr v_gen_annotation(ShclArena *a, const ShclVCons *c, ShclStr tyname) {
	ShclSB s = {0, 0, 0};
	char nb[80];
	sb_putS(a, &s, tyname);
	if (c->unit_d != SHCL_DURATION_NONE) { sb_puts(a, &s, " in "); sb_puts(a, &s, shcl_duration_unit_spelling(c->unit_d)); }
	else if (c->unit_s != SHCL_SIZE_NONE) { sb_puts(a, &s, " in "); sb_puts(a, &s, shcl_size_unit_spelling(c->unit_s)); }
	if (c->decimal) sb_puts(a, &s, ", KB to TB in powers of 1000");
	if (c->has_allowed) {
		sb_puts(a, &s, ", one of: "); sb_putS(a, &s, v_allowed_join(a, c));
	}
	// The bounds are their own part of the annotation line, not an alternative
	// to `allowed`. A field can have both, and the validator enforces both. A
	// duration or size bound reads the way the schema wrote it.
	if (c->min_text.n || c->max_text.n) {
		sb_puts(a, &s, ", ");
		if (c->min_text.n && c->max_text.n) { sb_putS(a, &s, c->min_text); sb_putc(a, &s, '-'); sb_putS(a, &s, c->max_text); }
		else if (c->min_text.n) { sb_puts(a, &s, ">= "); sb_putS(a, &s, c->min_text); }
		else { sb_puts(a, &s, "<= "); sb_putS(a, &s, c->max_text); }
	} else if (c->has_min_i || c->has_max_i) {
		if (c->has_min_i && c->has_max_i) snprintf(nb, sizeof nb, ", %" PRId64 "-%" PRId64, c->min_i, c->max_i);
		else if (c->has_min_i) snprintf(nb, sizeof nb, ", >= %" PRId64, c->min_i);
		else snprintf(nb, sizeof nb, ", <= %" PRId64, c->max_i);
		sb_puts(a, &s, nb);
	} else if (c->has_min_f || c->has_max_f) {
		char fb[SHCL_FLOAT_BUF];
		sb_puts(a, &s, ", ");
		if (c->has_min_f && c->has_max_f) {
			ShclStr f; f.p = fb; f.n = shcl_format_float(c->min_f, fb); sb_putS(a, &s, f);
			sb_putc(a, &s, '-');
			ShclStr g; g.p = fb; g.n = shcl_format_float(c->max_f, fb); sb_putS(a, &s, g);
		} else if (c->has_min_f) {
			sb_puts(a, &s, ">= "); ShclStr f; f.p = fb; f.n = shcl_format_float(c->min_f, fb); sb_putS(a, &s, f);
		} else {
			sb_puts(a, &s, "<= "); ShclStr f; f.p = fb; f.n = shcl_format_float(c->max_f, fb); sb_putS(a, &s, f);
		}
	}
	if (c->has_repeat) {
		if (c->rep_lo == c->rep_hi) snprintf(nb, sizeof nb, ", repeat %" PRIu64, c->rep_lo);
		else snprintf(nb, sizeof nb, ", repeat %" PRIu64 "-%" PRIu64, c->rep_lo, c->rep_hi);
		sb_puts(a, &s, nb);
	}
	if (c->required) sb_puts(a, &s, ", required");
	return sb_S(&s);
}

// A field must exist when required or its repeat lower bound is 1+; a
// commented-out line for either would fail the very schema that produced it.
static int g_must_exist(const ShclVCons *c) { return c->required || (c->has_repeat && c->rep_lo >= 1); }
static int g_has_wild(const ShclVCons *c) {
	for (size_t si = 0; si < c->segs.len; si++) if (c->segs.data[si].sel.tag == SEL_WILDCARD) return 1;
	return 0;
}
// `[#N]` needs a pre-existing instance and its `#` would start a comment on a
// binding line. A path deeper than a document may nest cannot be generated
// either: the line would draw E016 on the way back in. A newline in a name or a
// by-value selector is writable, since both are written escaped.
// The reason doubles as the predicate, so the refusal cannot name a path for a
// reason generation did not act on.
static const char *g_why_unwritable(const ShclVCons *c) {
	if (c->segs.len > SHCL_MAX_DEPTH) return "nests past the depth cap";
	for (size_t si = 0; si < c->segs.len; si++) {
		const ShclSegment *sg = &c->segs.data[si];
		if (sg->sel.tag == SEL_INDEX) return "a [#N] selector needs an instance that does not exist yet";
		if (sg->star) return "a * name segment has no name to write";
	}
	return "";
}
static int g_unwritable(const ShclVCons *c) { return g_why_unwritable(c)[0] != '\0'; }
// A repeat lower bound of 2 or more is the one documented shortfall - the line
// is emitted once and the count reported - so it is not the fault below.
static int g_cannot_satisfy(const ShclVCons *c) { return c->required || (c->has_repeat && c->rep_lo == 1); }
// A default with a literal newline cannot sit on a value line; the quoted
// escaped spelling reads back to the same string.
static ShclStr g_default_text(ShclArena *a, ShclStr v) {
	int has = 0;
	for (size_t k = 0; k < v.n; k++) if (v.p[k] == '\n') { has = 1; break; }
	if (!has) return v;
	ShclSB b = {0, 0, 0};
	sb_putc(a, &b, '"');
	for (size_t k = 0; k < v.n; k++) {
		char ch = v.p[k];
		if (ch == '\\') sb_puts(a, &b, "\\\\");
		else if (ch == '"') sb_puts(a, &b, "\\\"");
		else if (ch == '\n') sb_puts(a, &b, "\\n");
		else if (ch == '\t') sb_puts(a, &b, "\\t");
		else sb_putc(a, &b, ch);
	}
	sb_putc(a, &b, '"');
	return sb_S(&b);
}

// Ceiling on how many fields one schema may expand to. Fragments that mount
// each other at more than one path multiply, so a short schema can otherwise
// ask for more output than the machine can hold; past this the generator
// reports a schema fault rather than running until something breaks.
#define GEN_MAX_FIELDS ((size_t)10000)

/* Whether a V007 from the self-check is the sanctioned kind: its message ends
   `: N not in LO..HI`, and LO is 2 or more. */
static int v007_sanctioned(ShclStr message) {
	const char *tail = NULL;
	for (size_t i = 0; i + 8 <= message.n; i++) if (memcmp(message.p + i, " not in ", 8) == 0) tail = message.p + i + 8;
	if (!tail) return 0;
	uint64_t lo = 0; size_t k = 0, n = message.n - (size_t)(tail - message.p);
	while (k < n && tail[k] >= '0' && tail[k] <= '9') { lo = lo * 10 + (uint64_t)(tail[k] - '0'); k++; }
	return k > 0 && lo >= 2;
}

/* Parent lines with a value, keyed by their segment names: the live
   must-exist concrete constraints with a default. A dotted child of one has
   to select that instance by the value, or it names the empty-valued one. */
typedef struct { const ShclVecSeg *segs; ShclStr value; } ShclParentValue;
typedef struct { ShclParentValue *data; size_t len; } ShclParentValues;
static const ShclStr *parent_value_for(const ShclParentValues *pv, const ShclVecSeg *segs, size_t n) {
	for (size_t i = 0; i < pv->len; i++) {
		if (pv->data[i].segs->len != n) continue;
		int eq = 1;
		for (size_t k = 0; k < n && eq; k++) eq = s_eq(pv->data[i].segs->data[k].name, segs->data[k].name);
		if (eq) return &pv->data[i].value;
	}
	return NULL;
}

/* Whether BODY between brackets on a file line reads back as a value selector
   for TEXT, quoted or bare as asked. */
static int selector_reads_back(ShclArena *a, ShclStr body, ShclStr text, int quoted) {
	ShclSB l = {0, 0, 0};
	sb_puts(a, &l, "x["); sb_putS(a, &l, body); sb_puts(a, &l, "]:");
	ShclStr line = sb_S(&l);
	/* The tokenizer reads one line and never sees a line end, so text with a
	   real line break would read back here and then be written across two lines,
	   which is not the same path. A file line cannot hold one, so refuse and let
	   the escaped spelling be tried instead. */
	for (size_t k = 0; k < line.n; k++) if (line.p[k] == '\n' || line.p[k] == '\r') return 0;
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize(a, line, ':', 0, SHCL_RULES_CURRENT, &tok);
	if (selector_open_quote(&tok) || tok.has_comment) return 0;
	ShclPathScan ps = path_of(a, &tok, line);
	if (!ps.ok || ps.segs.len != 1) return 0;
	const ShclSelector *sel = &ps.segs.data[0].sel;
	return sel->tag == SEL_VALUE && s_eq(sel->value, text) && !sel->quoted == !quoted;
}

/* Whether a schema path written on a file line reads back as the same
   segments. A lookup path takes spellings a file line does not. */
static int path_reads_back(ShclArena *a, ShclStr path, const ShclVecSeg *segs) {
	ShclSB l = {0, 0, 0};
	sb_putS(a, &l, path); sb_putc(a, &l, ':');
	ShclStr line = sb_S(&l);
	/* The tokenizer reads one line and never sees a line end, so text with a
	   real line break would read back here and then be written across two lines,
	   which is not the same path. A file line cannot hold one, so refuse and let
	   the escaped spelling be tried instead. */
	for (size_t k = 0; k < line.n; k++) if (line.p[k] == '\n' || line.p[k] == '\r') return 0;
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize(a, line, ':', 0, SHCL_RULES_CURRENT, &tok);
	if (selector_open_quote(&tok) || tok.has_comment) return 0;
	ShclPathScan ps = path_of(a, &tok, line);
	if (!ps.ok || ps.segs.len != segs->len) return 0;
	for (size_t k = 0; k < segs->len; k++) {
		const ShclSegment *x = &ps.segs.data[k], *y = &segs->data[k];
		if (!s_eq(x->name, y->name) || !x->star != !y->star || x->sel.tag != y->sel.tag) return 0;
		if (x->sel.tag == SEL_VALUE && (!s_eq(x->sel.value, y->sel.value) || !x->sel.quoted != !y->sel.quoted)) return 0;
		if (x->sel.tag == SEL_INDEX && x->sel.index != y->sel.index) return 0;
	}
	return 1;
}

/* The selector body that picks out the instance a line `name: v` makes, in
   *OUT, or 0 when no body can. It is built from the elements the reader takes
   out of that line's value, and each candidate is scanned back the way a file
   line is scanned, so none of the scanner's rules is copied here to go stale.
   That copy was the cause twice: an all-digit body past 64 bits, and a quoted
   array element written as the body. One element tries the spelling it was
   written in first; an array has only the bare body, since a quoted selector
   matches one element only, and a bare one the elements joined. */
static int gen_selector_text(ShclArena *a, ShclStr v, ShclStr *out) {
	ShclStr spelled = g_default_text(a, v);
	ShclTokens tok; memset(&tok, 0, sizeof tok);
	tokenize_value(a, spelled, 0, SHCL_RULES_CURRENT, &tok);
	ShclSB d = {0, 0, 0};
	ShclStr first = s_empty();
	for (size_t k = 0; k < tok.nelem; k++) {
		ShclStr e = piece_text(a, &tok.elements[k], spelled);
		if (k == 0) first = e;
		else sb_puts(a, &d, ", ");
		sb_putS(a, &d, e);
	}
	ShclStr display = tok.nelem ? sb_S(&d) : s_empty();
	ShclStr body[3], text[3];
	int quoted[3], n = 0;
	if (tok.nelem == 1) {
		if (piece_quoted(tok.elements[0].quote)) {
			body[n] = s_slice(spelled, tok.value_start, tok.value_end); text[n] = first; quoted[n++] = 1;
		}
		body[n] = display; text[n] = display; quoted[n++] = 0;
		body[n] = quote_text(a, first); text[n] = first; quoted[n++] = 1;
	} else {
		body[n] = display; text[n] = display; quoted[n++] = 0;
	}
	for (int k = 0; k < n; k++) {
		if (selector_reads_back(a, body[k], text[k], quoted[k])) { *out = body[k]; return 1; }
	}
	return 0;
}

// Render parsed segments back as a dotted path, dropping wildcard selectors
// (a generated line targets the one instance it materializes) and quoting a
// name that needs it, so the result is a path the scanner reads back the same.
// A segment whose prefix names a live line with a value selects that
// instance by the value, in place of a wildcard or a bare name. The path goes
// in *OUT; 0 when a selector has no spelling a file line reads back.
static int gen_path_text(ShclArena *a, const ShclVecSeg *segs, const ShclParentValues *pv, ShclStr *out_path) {
	ShclSB out = {0, 0, 0};
	char nb[32];
	for (size_t i = 0; i < segs->len; i++) {
		const ShclSegment *s = &segs->data[i];
		if (i > 0) sb_putc(a, &out, '.');
		if (s->star) sb_putc(a, &out, '*');
		else sb_putS(a, &out, emit_name(a, s->name));
		const ShclStr *v = (i + 1 < segs->len && s->sel.tag != SEL_VALUE) ? parent_value_for(pv, segs, i + 1) : NULL;
		if (v) {
			ShclStr body;
			if (!gen_selector_text(a, *v, &body)) return 0;
			sb_putc(a, &out, '['); sb_putS(a, &out, body); sb_putc(a, &out, ']');
			continue;
		}
		switch (s->sel.tag) {
		case SEL_VALUE: {
			// The body as the schema meant it: a quoted one stays quoted, and
			// a bare one goes bare when a file line reads it back.
			ShclStr qb = quote_text(a, s->sel.value), body;
			if (!s->sel.quoted && selector_reads_back(a, s->sel.value, s->sel.value, 0)) body = s->sel.value;
			else if (selector_reads_back(a, qb, s->sel.value, 1)) body = qb;
			else return 0;
			sb_putc(a, &out, '['); sb_putS(a, &out, body); sb_putc(a, &out, ']'); break;
		}
		case SEL_INDEX: { int nn = snprintf(nb, sizeof nb, "[#%" PRIu64 "]", s->sel.index); sb_put(a, &out, nb, (size_t)nn); break; }
		case SEL_WILDCARD: case SEL_NONE: break;
		}
	}
	*out_path = sb_S(&out);
	return 1;
}

// Inline every fragment mount into a flat constraint list, depth-first in
// schema order, each field's path and segments prefixed by its mount's. A
// mount whose fragment is already expanding (a cycle) stops there and is
// recorded as (path, fragment name) for the trailing not-generated block.
static void g_expand_go(ShclArena *a, const ShclVecVCons *list, const ShclVSchemaDef *def, const ShclStr *at_path, const ShclVecSeg *at_segs, ShclVecS *stack, ShclVecVCons *out, ShclVecS *cut_path, ShclVecS *cut_frag) {
	for (size_t i = 0; i < list->len; i++) {
		const ShclVCons *c = &list->data[i];
		ShclVCons cc = *c;
		if (at_path) {
			ShclSB p = {0, 0, 0};
			sb_putS(a, &p, *at_path); sb_putc(a, &p, '.'); sb_putS(a, &p, c->path);
			cc.path = sb_S(&p);
			ShclVecSeg segs = {0, 0, 0};
			for (size_t k = 0; k < at_segs->len; k++) ShclVecSeg_push(a, &segs, at_segs->data[k]);
			for (size_t k = 0; k < c->segs.len; k++) ShclVecSeg_push(a, &segs, c->segs.data[k]);
			cc.segs = segs;
		}
		ShclStr path = cc.path; ShclVecSeg segs = cc.segs;
		if (out->len > GEN_MAX_FIELDS) return;
		ShclVecVCons_push(a, out, cc);
		if (c->inherits.n) {
			int cycling = 0;
			for (size_t k = 0; k < stack->len; k++) if (s_eq(stack->data[k], c->inherits)) { cycling = 1; break; }
			// A chain long enough to outrun the stack, or a mount that
			// re-enters, stops here and is noted instead of expanded.
			if (cycling || stack->len >= SHCL_MAX_DEPTH) {
				ShclVecS_push(a, cut_path, schema_text(a, path));
				ShclVecS_push(a, cut_frag, schema_text(a, c->inherits));
			} else {
				const ShclVecVCons *fcs = v_frag_get(def, c->inherits);
				if (fcs) {
					ShclVecS_push(a, stack, c->inherits);
					g_expand_go(a, fcs, def, &path, &segs, stack, out, cut_path, cut_frag);
					stack->len--;
				}
			}
		}
	}
}
static void g_expand_mounts(ShclArena *a, const ShclVSchemaDef *def, ShclVecVCons *out, ShclVecS *cut_path, ShclVecS *cut_frag) {
	ShclVecS stack = {0, 0, 0};
	g_expand_go(a, &def->cons, def, NULL, NULL, &stack, out, cut_path, cut_frag);
}

/* What a generation holds while it works: its private arena and the nested
   documents of the self-check. */
typedef struct { ShclArena tmp; shcl_doc *self_, *one; shcl_validation *v; } ShclGenOwn;

static void gen_release(shcl_doc *schema, ShclGenOwn *own) {
	shcl_validation_free(own->v);
	shcl_free(own->one);
	shcl_free(own->self_);
	arena_free(&own->tmp);
	doc_guard(schema, NULL);
	free(own);
}

/* The work of shcl_generate, in a frame of its own so the recovery point in
   the caller leaves nothing here that a longjmp could clobber. */
static shcl_str generate_in(shcl_doc *schema, int no_banner, int *ok, ShclGenOwn *own, jmp_buf *panic) {
	ShclArena *a = &own->tmp;
	ShclVSchemaDef def; memset(&def, 0, sizeof def);
	ShclVecDiag faults = {0, 0, 0};
	/* What an earlier call on this schema pushed is that call's answer, not
	   this one's. Drop it, or a caller generating in a loop collects one copy
	   per attempt and the diagnostic count stops meaning anything. Only what
	   generation pushed goes: the schema's own diagnostics stay. */
	{
		size_t w = 0;
		for (size_t i = 0; i < schema->diags.len; i++) {
			if (schema->diags.data[i].generated) continue;
			schema->diags.data[w++] = schema->diags.data[i];
		}
		schema->diags.len = w;
	}
	// Generation lays the whole schema out, so unlike validation it has no
	// safe partial mode: any fault fails it.
	v_build_schema(a, schema, &def, &faults);
	shcl_str r;
	if (faults.len) {
		// Recorded on the schema document like every other generation fault,
		// so a caller sees the V09x list itself and does not have to rebuild
		// it by validating an empty document (which adds that document's own
		// V002/V007 to the list).
		for (size_t i = 0; i < faults.len; i++) push_gen_diag(schema, faults.data[i].line, faults.data[i].sev, faults.data[i].code, faults.data[i].message);
		if (ok) *ok = 0;
		ShclStr e = s_empty(); r.p = e.p; r.n = e.n; return r;
	}
	if (ok) *ok = 1;
	ShclVecVCons cons = {0, 0, 0};
	ShclVecS cut_path = {0, 0, 0}, cut_frag = {0, 0, 0};
	g_expand_mounts(a, &def, &cons, &cut_path, &cut_frag);
	if (cons.len > GEN_MAX_FIELDS) {
		// Generation-only fault: recorded on the schema document (this
		// signature has no fault list of its own to return).
		ShclSB m = {0, 0, 0};
		sb_puts(a, &m, "schema expands past "); sb_put_u64(a, &m, GEN_MAX_FIELDS);
		sb_puts(a, &m, " fields; fragments mounted at more than one path multiply");
		// the diag outlives this call: its text must leave the private arena
		push_gen_diag(schema, 0, SHCL_SEV_ERROR, "V096", sb_S(&m));
		if (ok) *ok = 0;
		ShclStr e = s_empty(); r.p = e.p; r.n = e.n; return r;
	}
	// Live concrete paths materialize instances; decide which must-exist
	// wildcards get filled (their first-wildcard parent chain is a prefix of
	// some live path's name list). Fixpoint: a fill can materialize another's
	// parent. Live paths are stored as their segment-name lists.
	size_t nlive = 0, clive = 0;
	ShclVecSeg *live = NULL;
	int *fill = (int *)arena_alloc(a, (cons.len ? cons.len : 1) * sizeof *fill);
	for (size_t i = 0; i < cons.len; i++) fill[i] = 0;
	#define LIVE_PUSH(SEGS) do { if (nlive == clive) { clive = clive ? clive * 2 : 8; ShclVecSeg *nl = (ShclVecSeg *)arena_alloc(a, clive * sizeof *nl); for (size_t t = 0; t < nlive; t++) nl[t] = live[t]; live = nl; } live[nlive++] = (SEGS); } while (0)
	for (size_t i = 0; i < cons.len; i++) {
		const ShclVCons *c = &cons.data[i];
		if (!g_has_wild(c) && !g_unwritable(c) && g_must_exist(c)) LIVE_PUSH(c->segs);
	}
	for (;;) {
		int changed = 0;
		for (size_t i = 0; i < cons.len; i++) {
			const ShclVCons *c = &cons.data[i];
			if (fill[i] || !g_has_wild(c) || g_unwritable(c) || !g_must_exist(c)) continue;
			size_t k = 0;
			while (c->segs.data[k].sel.tag != SEL_WILDCARD) k++;
			size_t plen = k + 1; // parent chain: names up to and including the wildcard segment
			int hit = 0;
			for (size_t li = 0; li < nlive && !hit; li++) {
				if (live[li].len < plen) continue;
				int eq = 1;
				for (size_t s2 = 0; s2 < plen; s2++) if (!s_eq(live[li].data[s2].name, c->segs.data[s2].name)) { eq = 0; break; }
				hit = eq;
			}
			// A wildcard in the last segment needs no other line to
			// materialize its parent: the line generated from it is that
			// instance.
			if (plen == c->segs.len) hit = 1;
			if (hit) { fill[i] = 1; LIVE_PUSH(c->segs); changed = 1; }
		}
		if (!changed) break;
	}
	#undef LIVE_PUSH
	/* A live line with a value materializes an instance with that value,
	   and a dotted child names the empty-valued instance instead - so `srv:
	   web` followed by `srv.port:` is two `srv` nodes, and the child never
	   ends up where the schema looks. Any line under such a parent selects it
	   by its value: `srv[web].port:`. */
	ShclParentValues pv; pv.len = 0;
	pv.data = (ShclParentValue *)arena_alloc(a, (cons.len ? cons.len : 1) * sizeof *pv.data);
	for (size_t i = 0; i < cons.len; i++) {
		const ShclVCons *c = &cons.data[i];
		// A filled wildcard emits a valued line of its own, so it belongs here too.
		if ((!g_has_wild(c) || fill[i]) && !g_unwritable(c) && g_must_exist(c) && c->has_default) { pv.data[pv.len].segs = &c->segs; pv.data[pv.len].value = c->default_text; pv.len++; }
	}
	/* A commented line under a commented valued parent has the same problem
	   once both are uncommented, so it selects the parent's default too. A
	   live line keeps the dotted form under a commented parent: selecting by
	   value would make the optional parent exist. The live values go first, so
	   a lookup finds them before a commented one. */
	ShclParentValues cpv; cpv.len = pv.len;
	cpv.data = (ShclParentValue *)arena_alloc(a, (cons.len ? cons.len : 1) * sizeof *cpv.data);
	for (size_t i = 0; i < pv.len; i++) cpv.data[i] = pv.data[i];
	for (size_t i = 0; i < cons.len; i++) {
		const ShclVCons *c = &cons.data[i];
		if (!g_has_wild(c) && !g_unwritable(c) && !g_must_exist(c) && c->has_default) { cpv.data[cpv.len].segs = &c->segs; cpv.data[cpv.len].value = c->default_text; cpv.len++; }
	}
	/* A path that cannot be written at all belongs in the trailing note, but one
	   that must exist can never be satisfied from there: the self-check would
	   then report the document as missing a path, which points at the config
	   rather than at the schema line that cannot be generated.
	   Every such path is named, not just the first: fixing one only to be
	   refused over the next tells nobody how much is wrong. */
	int blocked = 0;
	for (size_t i = 0; i < cons.len; i++) {
		const ShclVCons *c = &cons.data[i];
		if (!g_cannot_satisfy(c) || !g_unwritable(c) || g_has_wild(c)) continue;
		ShclSB m = {0, 0, 0};
		sb_puts(a, &m, "required path cannot be generated: ");
		sb_putS(a, &m, schema_text(a, c->path));
		sb_puts(a, &m, " (");
		sb_puts(a, &m, g_why_unwritable(c));
		sb_puts(a, &m, ")");
		push_gen_diag(schema, 0, SHCL_SEV_ERROR, "V097", sb_S(&m));
		blocked = 1;
	}
	if (blocked) {
		if (ok) *ok = 0;
		ShclStr e = s_empty(); r.p = e.p; r.n = e.n; return r;
	}
	ShclSB out = {0, 0, 0};
	ShclVecS wild_path = {0, 0, 0}, wild_type = {0, 0, 0};
	/* Dropping a trailing `[*]` can render the same line a concrete sibling
	   already wrote; the first spelling wins. A line from a dropped `[value]`
	   selector is its own instance, so two of them with different values are
	   both written: `env[prod]` and `env[dev]` are two `env` lines. A plain
	   line blocks its path; a by-value line blocks only its own value. Hash
	   first, bytes only on a hash hit, so the scan stays cheap at the field
	   cap. */
	ShclVecS emitted = {0, 0, 0};
	uint64_t *emitted_hash = (uint64_t *)arena_alloc(a, (cons.len ? cons.len : 1) * sizeof *emitted_hash);
	int *emitted_plain = (int *)arena_alloc(a, (cons.len ? cons.len : 1) * sizeof *emitted_plain);
	ShclStr *emitted_val = (ShclStr *)arena_alloc(a, (cons.len ? cons.len : 1) * sizeof *emitted_val);
	// A child whose valued parent has no selector spelling cannot be written.
	int unspellable = 0;
	/* One block per generated line - its desc, annotation and binding - and the
	   constraint it came from, so the blocks can be laid out in tree order
	   below. */
	ShclVecS block_text = {0, 0, 0};
	ShclVecSize block_cons = {0, 0, 0};
	// An optional field's line goes out commented, with the constraint it came
	// from, since the self-check below cannot see a comment.
	ShclVecS commented_line = {0, 0, 0};
	ShclVecSize commented_cons = {0, 0, 0};
	for (size_t i = 0; i < cons.len; i++) {
		ShclVCons *c = &cons.data[i];
		ShclStr tyname;
		if (c->ty) { tyname.p = c->ty; tyname.n = strlen(c->ty); } else tyname = s_lit("any");
		if (g_unwritable(c) || (g_has_wild(c) && !fill[i])) {
			ShclVecS_push(a, &wild_path, schema_text(a, c->path)); ShclVecS_push(a, &wild_type, tyname);
			continue;
		}
		// A filled wildcard emits in dotted form, targeting the materialized
		// instance - by its value when the materializing line has one.
		// Rebuilt from the parsed segments, not by cutting text out of the
		// path: the same path can be written several ways, and only the
		// segments say what it means. Otherwise the schema's own spelling.
		const ShclParentValues *values = g_must_exist(c) ? &pv : &cpv;
		int under_valued_parent = 0;
		for (size_t k = 1; k < c->segs.len && !under_valued_parent; k++)
			under_valued_parent = c->segs.data[k - 1].sel.tag == SEL_NONE && parent_value_for(values, &c->segs, k) != NULL;
		// A name with a newline has no verbatim spelling on a binding line;
		// the segment renderer escapes it, so such a path goes through there
		// whether or not it was filled.
		// A value after a last-segment selector is ignored, so a default there
		// goes on the bare path: the line materializes the instance, and
		// validation below decides whether the default names the one selected.
		int selects_by_value = c->has_default && c->segs.len && c->segs.data[c->segs.len - 1].sel.tag == SEL_VALUE;
		// The schema's own spelling is kept when a file line reads it back as
		// the same path. A selector body holding a `#` is fine in a lookup and
		// opens a comment on a file line, so that one goes through the renderer.
		ShclStr path = c->path;
		int spelled = 1;
		if (selects_by_value) {
			ShclVecSeg segs = {0, 0, 0};
			for (size_t k = 0; k < c->segs.len; k++) ShclVecSeg_push(a, &segs, c->segs.data[k]);
			ShclSelector *last = &segs.data[segs.len - 1].sel;
			last->tag = SEL_NONE; last->value = s_empty(); last->index = 0; last->quoted = 0;
			spelled = gen_path_text(a, &segs, values, &path);
		} else if (fill[i] || under_valued_parent || !path_reads_back(a, c->path, &c->segs))
			spelled = gen_path_text(a, &c->segs, values, &path);
		if (!spelled) {
			ShclSB m = {0, 0, 0};
			sb_puts(a, &m, "required path cannot be generated: ");
			sb_putS(a, &m, schema_text(a, c->path));
			sb_puts(a, &m, " (its parent's value has no selector spelling)");
			push_gen_diag(schema, 0, SHCL_SEV_ERROR, "V097", sb_S(&m));
			unspellable = 1;
			continue;
		}
		uint64_t ph = fnv_str(1469598103934665603ull, path);
		ShclStr dval = c->has_default ? c->default_text : s_empty();
		int dup = 0;
		for (size_t k = 0; k < emitted.len && !dup; k++)
			dup = emitted_hash[k] == ph && s_eq(emitted.data[k], path)
				&& (emitted_plain[k] || !selects_by_value || s_eq(emitted_val[k], dval));
		if (dup) continue;
		emitted_hash[emitted.len] = ph;
		emitted_plain[emitted.len] = !selects_by_value;
		emitted_val[emitted.len] = dval;
		ShclVecS_push(a, &emitted, path);
		ShclSB blk = {0};
		if (c->has_desc) {
			size_t start = 0;
			for (size_t k = 0; k <= c->desc.n; k++) {
				if (k == c->desc.n || c->desc.p[k] == '\n') {
					sb_puts(a, &blk, k == start ? "##" : "## ");
					ShclStr ln; ln.p = c->desc.p + start; ln.n = k - start; sb_putS(a, &blk, ln);
					sb_putc(a, &blk, '\n');
					start = k + 1;
				}
			}
		}
		sb_puts(a, &blk, "## "); sb_putS(a, &blk, schema_text(a, v_gen_annotation(a, c, tyname))); sb_putc(a, &blk, '\n');
		ShclSB ln = {0};
		sb_putS(a, &ln, path);
		if (c->has_default) { sb_puts(a, &ln, ": "); sb_putS(a, &ln, g_default_text(a, c->default_text)); }
		else sb_putc(a, &ln, ':');
		sb_putc(a, &ln, '\n');
		if (!g_must_exist(c)) sb_puts(a, &blk, "# ");
		sb_putS(a, &blk, sb_S(&ln));
		if (!g_must_exist(c)) {
			ShclVecS_push(a, &commented_line, sb_S(&ln));
			ShclVecSize_push(a, &commented_cons, i);
		}
		ShclVecS_push(a, &block_text, sb_S(&blk));
		ShclVecSize_push(a, &block_cons, i);
	}
	if (unspellable) {
		if (ok) *ok = 0;
		ShclStr e = s_empty(); r.p = e.p; r.n = e.n; return r;
	}
	/* Tree order, first appearance first. A schema may list a.host.srv before
	   a, and emitted as listed with another field between them, `a: x` re-opens
	   a and the load hints it (H002) - in the one file meant to show the format
	   at its cleanest. Every prefix is ranked by where it first appears (a hash
	   of its length-prefixed names stands for the prefix), so a parent's block
	   comes before its children's, siblings keep schema order, and a schema
	   already in tree order is unchanged. A parent's key is a prefix of its
	   children's and a shorter key sorts first; the merge sort is stable, so
	   two blocks on one path keep their order. */
	size_t nblk = block_text.len, total = 0;
	for (size_t b = 0; b < nblk; b++) total += cons.data[block_cons.data[b]].segs.len;
	size_t *keys = (size_t *)arena_alloc(a, (total ? total : 1) * sizeof *keys);
	size_t *key_at = (size_t *)arena_alloc(a, (nblk + 1) * sizeof *key_at);
	ShclCMap rank = {0, 0, 0};
	size_t pos = 0;
	for (size_t b = 0; b < nblk; b++) {
		const ShclVecSeg *segs = &cons.data[block_cons.data[b]].segs;
		key_at[b] = pos;
		uint64_t h = 1469598103934665603ull;
		for (size_t k = 0; k < segs->len; k++) {
			h = fnv_str(fnv_dec(h, segs->data[k].name.n), segs->data[k].name);
			ShclCMapEnt *e = cmap_first(&rank, h);
			size_t rk = e ? e->val : rank.len;
			if (!e) cmap_put(a, &rank, h, rk);
			keys[pos++] = rk;
		}
	}
	key_at[nblk] = pos;
	size_t *order = (size_t *)arena_alloc(a, (nblk ? nblk : 1) * sizeof *order);
	size_t *merged = (size_t *)arena_alloc(a, (nblk ? nblk : 1) * sizeof *merged);
	for (size_t b = 0; b < nblk; b++) order[b] = b;
	for (size_t width = 1; width < nblk; width *= 2) {
		for (size_t lo = 0; lo < nblk; lo += 2 * width) {
			size_t mid = lo + width < nblk ? lo + width : nblk, hi = lo + 2 * width < nblk ? lo + 2 * width : nblk;
			size_t i = lo, j = mid, o = lo;
			while (i < mid && j < hi) {
				size_t x = order[i], y = order[j], xs = key_at[x], ys = key_at[y];
				int le = 1;
				for (;; xs++, ys++) {
					if (xs == key_at[x + 1]) break;              // x is a prefix of y, or equal
					if (ys == key_at[y + 1]) { le = 0; break; }  // y is a proper prefix of x
					if (keys[xs] != keys[ys]) { le = keys[xs] < keys[ys]; break; }
				}
				if (le) merged[o++] = order[i++]; else merged[o++] = order[j++];
			}
			while (i < mid) merged[o++] = order[i++];
			while (j < hi) merged[o++] = order[j++];
		}
		memcpy(order, merged, nblk * sizeof *order);
	}
	for (size_t n = 0; n < nblk; n++) {
		if (n) sb_putc(a, &out, '\n');
		sb_putS(a, &out, block_text.data[order[n]]);
	}
	// Cycle-cut mounts last: their "type" column names the fragment that
	// belongs at the path.
	for (size_t i = 0; i < cut_path.len; i++) {
		ShclVecS_push(a, &wild_path, cut_path.data[i]);
		ShclVecS_push(a, &wild_type, cut_frag.data[i]);
	}
	if (wild_path.len) {
		if (nblk) sb_putc(a, &out, '\n');
		sb_puts(a, &out, "## Paths needing an instance name (not generated):\n");
		for (size_t i = 0; i < wild_path.len; i++) {
			sb_puts(a, &out, "##   "); sb_putS(a, &out, wild_path.data[i]);
			sb_puts(a, &out, "   "); sb_putS(a, &out, wild_type.data[i]); sb_putc(a, &out, '\n');
		}
	}
	if (!no_banner) {
		if (out.len) sb_putc(a, &out, '\n');
		sb_puts(a, &out, SHCL_GEN_BANNER);
	}
	ShclStr s = sb_S(&out);
	/* The output promises to validate clean against the schema that produced
	   it, so check that here rather than trusting each branch above. A
	   `default` outside its own field's constraints is the schema's fault, and
	   the author should hear about it instead of getting a starter config that
	   fails the first time it is checked. The one sanctioned shortfall is a
	   V007 for a repeat lower bound of 2+: generating that many identical
	   lines merges them into one. A lower bound of 1 is a must-exist path
	   like any other, so its V007 is a fault. */
	{
		// A NULL from a nested call is an allocation that failed, not a text
		// that passed: reading it as "no faults" returned unchecked text.
		shcl_doc *self_ = own->self_ = shcl_parse(s.p, s.n);
		if (!self_) arena_panic(panic);
		doc_guard(self_, panic);
		size_t nbad = 0;
		/* The load comes first, in the order `check --schema` prints: a line that
		   does not load is refused even when validation happens to pass without it. */
		for (size_t i = 0; i < self_->diags.len; i++) {
			const ShclDiag *dg = &self_->diags.data[i];
			if (dg->sev != SHCL_SEV_ERROR) continue;
			ShclSB m = {0, 0, 0};
			sb_puts(a, &m, "generated text does not load: ");
			sb_puts(a, &m, dg->code); sb_putc(a, &m, ' '); sb_putS(a, &m, dg->message);
			/* the diag outlives this call and self_: its text must leave both */
			push_gen_diag(schema, 0, SHCL_SEV_ERROR, "V097", sb_S(&m));
			nbad++;
		}
		shcl_validation *v = own->v = shcl_validate(self_, schema);
		if (!v) arena_panic(panic);
		size_t nv = shcl_validation_count(v);
		for (size_t i = 0; i < nv; i++) {
			const char *code = shcl_validation_code(v, i);
			if (shcl_validation_severity(v, i) != SHCL_SEV_ERROR) continue;
			if (code && strcmp(code, "V007") == 0 && v007_sanctioned(shcl_validation_message(v, i))) continue;
			ShclSB m = {0, 0, 0};
			sb_puts(a, &m, "generated value fails the schema that produced it: ");
			sb_putS(a, &m, shcl_validation_message(v, i));
			/* the diag outlives this call: its text must leave the private arena */
			push_gen_diag(schema, 0, SHCL_SEV_ERROR, "V097", sb_S(&m));
			nbad++;
		}
		shcl_validation_free(v); own->v = NULL;
		shcl_free(self_); own->self_ = NULL;
		/* A commented default fails the same check once someone uncomments it.
		   Each line is read back alone and only its value is checked:
		   uncommenting every line at once would pair a valued parent with a
		   dotted child, which names a second instance, and fault a schema whose
		   lines each work. The value is found through the field's own path, the
		   way validation finds it, so a default naming another instance than the
		   path selects is caught here as it is for a required field. */
		for (size_t j = 0; j < commented_line.len; j++) {
			ShclStr text = commented_line.data[j];
			shcl_doc *one = own->one = shcl_parse(text.p, text.n);
			if (!one) arena_panic(panic);
			doc_guard(one, panic);
			for (size_t i = 0; i < one->diags.len; i++) {
				const ShclDiag *dg = &one->diags.data[i];
				if (dg->sev != SHCL_SEV_ERROR) continue;
				ShclSB m = {0, 0, 0};
				sb_puts(a, &m, "generated text does not load: ");
				sb_puts(a, &m, dg->code); sb_putc(a, &m, ' '); sb_putS(a, &m, dg->message);
				push_gen_diag(schema, 0, SHCL_SEV_ERROR, "V097", sb_S(&m));
				nbad++;
			}
			if (NODE(one, ROOT).children.len) {
				const ShclVCons *cc = &cons.data[commented_cons.data[j]];
				ShclVecVCtx ctxs = {0};
				size_t start = ROOT, nfound = 0;
				v_contexts(a, one, &start, 1, cc->segs.data, cc->segs.len, 0, &ctxs);
				ShclVecDiag found = {0, 0, 0};
				for (size_t k = 0; k < ctxs.len; k++) {
					for (size_t q = 0; q < ctxs.data[k].found.len; q++, nfound++) v_node(a, a, one, cc, ctxs.data[k].found.data[q], &found);
				}
				if (!nfound) {
					ShclSB m = {0, 0, 0};
					sb_puts(a, &m, "generated value fails the schema that produced it: default does not name the instance its path selects: ");
					sb_putS(a, &m, schema_text(a, cc->path));
					push_gen_diag(schema, 0, SHCL_SEV_ERROR, "V097", sb_S(&m));
					nbad++;
				}
				for (size_t i = 0; i < found.len; i++) {
					if (found.data[i].sev != SHCL_SEV_ERROR) continue;
					ShclSB m = {0, 0, 0};
					sb_puts(a, &m, "generated value fails the schema that produced it: ");
					sb_putS(a, &m, found.data[i].message);
					push_gen_diag(schema, 0, SHCL_SEV_ERROR, "V097", sb_S(&m));
					nbad++;
				}
			}
			shcl_free(one); own->one = NULL;
		}
		if (nbad) {
			if (ok) *ok = 0;
			ShclStr e = s_empty(); r.p = e.p; r.n = e.n;
			return r;
		}
	}
	/* Only now does the text leave the private arena, and it goes to the read
	   arena rather than the document's own: a refused call then costs the
	   schema nothing, and a caller generating in a loop can give the copies
	   back with shcl_reads_release. */
	ShclStr kept = s_dup(&schema->reads, s); r.p = kept.p; r.n = kept.n;
	
	return r;
}

shcl_str shcl_generate(shcl_doc *schema, int no_banner, int *ok) {
	// Only the returned bytes are contracted to live in the schema's arena;
	// the constraint/fault lists, expansion copies, and the output builder are
	// ~60x that, so they build in a private arena (shcl_validate's discipline)
	// and die here - the caller may generate from one schema repeatedly. The
	// arena and the self-check's documents sit off the frame, where the
	// recovery point can still reach them (20260918b item 22).
	ShclGenOwn *volatile own = (ShclGenOwn *)calloc(1, sizeof *own);
	if (!own) { SHCL_OOM(); abort(); }
	jmp_buf panic;
	if (SHCL_SETJMP(panic)) {
		/* An allocation failed below, or a nested parse or validate came back
		   NULL for one. Give back what the call holds, then hand the failure
		   on: the self-check did not run, so there is no answer to return. */
		gen_release(schema, own);
		SHCL_OOM();
		abort();
	}
	arena_guard(&own->tmp, &panic);
	doc_guard(schema, &panic);
	/* Called through a volatile pointer so no compiler can inline the work back
	   into this frame, where every local it keeps would sit beside the setjmp. */
	shcl_str (*volatile run)(shcl_doc *, int, int *, ShclGenOwn *, jmp_buf *) = generate_in;
	shcl_str r = run(schema, no_banner, ok, own, &panic);
	gen_release(schema, own);
	return r;
}

#ifdef __cplusplus
#pragma GCC diagnostic pop
#endif

// The implementation's short internal macros would otherwise outlive the header
// in the consumer's own translation unit, where these names are common.
#undef DEFINE_VEC
#undef ROOT
#undef NODE
#undef NIL
#undef DEAD
#undef UNOPENED
#undef GEN_MAX_FIELDS

#endif // SHCL_IMPLEMENTATION
#endif // SHCL_H
