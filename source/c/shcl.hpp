// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// SHCL for C++. It is not a second parser: every call goes through the C core
// in shcl.h, so it reads and writes byte for byte what the other bindings do.
// The interface mirrors the Rust reference and names nothing from the C one,
// since this half of the file uses std types only. The calls into C live
// below, under SHCL_IMPLEMENTATION. Copy shcl.h and shcl.hpp into your tree,
// and in exactly one .cpp:
//   #define SHCL_IMPLEMENTATION
//   #include "shcl.hpp"
// That file also sees the C interface, so keep it to those two lines, with the
// include above any system header for the reason shcl.h gives. Define
// SHCL_NO_FILE_IO in every file or in none.

#ifndef SHCL_HPP
#define SHCL_HPP

// The C core goes first in the implementation file: its file tier asks for a
// POSIX level, and that only counts before the first system header.
#ifdef SHCL_IMPLEMENTATION
#include "shcl.h"
#endif

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace shcl {

// The values match the C enums, which the implementation checks at compile time.
enum class Strictness { Loose, Standard, Strict };
// Only Error fails a strict load; Hint flags legal but lookalike input.
enum class Severity { Error, Hint };
// Empty is informational: the empty value still comes back.
enum class Status { Good, Empty, NotFound, BadType, Multiple };
// Why a write would fail: the distinctions behind a setter's bare false.
enum class WriteReason { Writable, BadPath, ValueInPath, Wildcard, NoSuchIndex, TooDeep };
// The unit a duration or size read gives a bare number, when the field name
// gives none. Kilo to Tera are powers of 1024 unless the read asks for
// decimal; Kibi to Tebi always are.
enum class DurationUnit { Millis, Seconds, Minutes, Hours, Days };
enum class SizeUnit { Bytes, Kilo, Mega, Giga, Tera, Kibi, Mebi, Gibi, Tebi };

// Nesting cap below the document root, enforced at load and by every setter.
inline constexpr std::size_t MAX_DEPTH = 512;
// The format major the info block names. It moves with the format.
inline constexpr std::uint32_t FORMAT_MAJOR = 3;
// The info block generate() writes at the bottom unless no_banner, for a
// program that writes its own config file.
extern const std::string_view GEN_BANNER;
// What migrate() matches to find a file's Format line, the line itself, and
// the note a migrated file gets under it.
extern const std::string_view FORMAT_LINE_HEAD;
extern const std::string_view FORMAT_LINE;
extern const std::string_view MIGRATED_LINE;
// The start of a line naming the file's schema, written like the Format line.
extern const std::string_view SCHEMA_LINE_HEAD;

class Document;
namespace detail {
struct Access;
bool status_ok(Status s);
}

template <class T> struct Read {
	T value{};
	Status status{};
	// Per-slot statuses, array reads only: one entry per slot the path
	// resolved, aligned with value, so a partially-resolved array says which
	// slots failed and why rather than only that the whole read did. Empty for
	// a scalar read.
	std::vector<Status> slots{};
	// Whether the author addressed this field at all: Good or Empty. Note this
	// deliberately answers differently from get_or, which falls back on Empty
	// like any other non-Good read - ok() asks "is this field spoken for",
	// get_or() asks "do I have a usable value", and an explicitly emptied field
	// is the case where those two diverge.
	bool ok() const { return detail::status_ok(status); }
};

struct Diagnostic {
	std::size_t line{}; // 1-based
	Severity severity{};
	std::string message{};
	// Stable machine code (E001.., H001..). The message prose is not a contract.
	std::string code{};
};

// A datetime's zone suffix as written: Z, or an offset in minutes.
enum class ZoneKind { Utc, Offset };
struct Zone { ZoneKind kind{}; std::int32_t offset_minutes{}; };
struct Date { std::int32_t year{}; std::uint32_t month{}; std::uint32_t day{}; };
// second is empty when the seconds were not written.
struct Time { std::uint32_t hour{}; std::uint32_t minute{}; std::optional<std::uint32_t> second{}; };

// Local (floating) date and time unless a zone suffix was present. The fields
// mirror what was written, so a date-only value has no time and the other way
// around. frac holds the fractional-second digits as typed. It owns all of
// that, so it may outlive the Document it was read from.
struct DateTime {
	std::optional<Date> date{};
	std::optional<Time> time{};
	std::optional<std::string> frac{};
	std::optional<Zone> zone{};
	// The reference's textual form.
	std::string str() const;
};

// Field by field, as the reference compares them: 12:00:00Z and 12:00:00+00:00
// are one moment and two values.
inline bool operator==(const Zone &a, const Zone &b) { return a.kind == b.kind && a.offset_minutes == b.offset_minutes; }
inline bool operator!=(const Zone &a, const Zone &b) { return !(a == b); }
inline bool operator==(const Date &a, const Date &b) { return a.year == b.year && a.month == b.month && a.day == b.day; }
inline bool operator!=(const Date &a, const Date &b) { return !(a == b); }
inline bool operator==(const Time &a, const Time &b) { return a.hour == b.hour && a.minute == b.minute && a.second == b.second; }
inline bool operator!=(const Time &a, const Time &b) { return !(a == b); }
inline bool operator==(const DateTime &a, const DateTime &b) { return a.date == b.date && a.time == b.time && a.frac == b.frac && a.zone == b.zone; }
inline bool operator!=(const DateTime &a, const DateTime &b) { return !(a == b); }

// Status as text, for a log line or a message. Static storage.
const char *to_string(Status s);
// The CLI exit code a read with this status ends on.
int status_code(Status s);
// The CLI's strictness spellings, loose|standard|strict or 1|2|3, in any case.
std::optional<Strictness> strictness_from_arg(std::string_view s);
// A float in the reference's textual form, the spelling a save writes.
std::string format_float(double v);
// Text to a datetime, per the whitelist. Empty when the text is not one.
std::optional<DateTime> parse_datetime(std::string_view s);
// Quote one path segment for splicing into a lookup path, so a user-typed
// name with a dot in it cannot read as nesting.
std::string quote_segment(std::string_view name);

// The tokenizer's view of one line or one lookup path, as `shcl tokens` prints
// it. Every offset is into the text that was tokenized.
enum class Quote { None, Single, Double, Open };
enum class Rules { Current, V2 };
struct Piece { std::size_t start{}; std::size_t end{}; Quote quote{}; };
struct SegTok { Piece name{}; std::optional<Piece> selector{}; bool star{}; };
struct Tokens {
	std::vector<SegTok> segments{};
	std::optional<std::size_t> sep{};
	std::size_t value_start{};
	std::size_t value_end{};
	std::vector<Piece> elements{};
	std::optional<std::size_t> comment{};
	// Where the path stopped making sense, and why. The reason is static text.
	std::optional<std::size_t> fault_at{};
	const char *fault_why = nullptr;
	// The caller's element cap (0 = none), kept across calls. capped says it
	// stopped the scan, and elements is then incomplete.
	std::size_t cap{};
	bool capped{};

	// Asked of the core rather than counted here, so what counts as an element
	// is decided in one place.
	std::size_t element_count() const;
};

// Tokenize one line (sep ':') or one lookup path (path: the bare `*` name
// wildcard is admitted, and a `#` in a selector body is the [#N] index, not a
// comment). text is the line after its indent, or the path. out.cap is read
// and every other field is replaced.
void tokenize(std::string_view text, char sep, bool path, Rules rules, Tokens &out);
// The value half alone: everything from `from` on, split into pieces, with the
// comment found on the way.
void tokenize_value(std::string_view text, std::size_t from, Rules rules, Tokens &out);

// What migrate produced, and what it could not carry across: current when the
// file already names its format, ambiguous for pieces the two rule sets read
// differently and nothing can decide between, lost for lines 2.x bound a value
// on that nothing binds now.
struct Migration {
	std::string text;
	bool current = false;
	std::size_t ambiguous = 0;
	std::size_t lost = 0;
};
// A document written under the 2.x lexical rules, rewritten so this parser
// reads the same tree; text to text, no document involved. from_v2 says the
// file really was written for 2.x, which is the only thing that can settle the
// spellings the two rule sets read differently.
Migration migrate(std::string_view text, bool from_v2);
// migrate() without the version line or the migrated note, for a program that
// writes GEN_BANNER itself, which carries the version line.
Migration migrate_unstamped(std::string_view text, bool from_v2);
// The format major a document's Format line names, read the way migrate reads
// it; none when no line names one. migrate hands a file back untouched exactly
// when this is FORMAT_MAJOR or more.
std::optional<std::uint32_t> format_version(std::string_view text);
// The schema a document's Schema line names, a path or a URL; none when no
// line names one. The first such line wins, and a relative path is the
// caller's to resolve, from the config file's directory.
std::optional<std::string> schema_ref(std::string_view text);
// The unit a value spelling names (ms s m h d; B KB kB MB GB TB KiB MiB GiB
// TiB, letter case read), and the spelling back.
std::optional<DurationUnit> duration_unit_from_spelling(std::string_view s);
std::optional<SizeUnit> size_unit_from_spelling(std::string_view s);
std::string_view spelling(DurationUnit u);
std::string_view spelling(SizeUnit u);

#ifndef SHCL_NO_FILE_IO
// Why a load came back the way it did. A load never fails on the file's
// account: the document is always usable, and empty when the file could not
// be read.
enum class FileStatus { Clean, HadErrors, NotFound, Unreadable };
// Not a bool: Refused is the lost-content gate, which save_file_lossy
// overrides, and folding it into a failed write leaves the caller with an
// override they cannot tell they need.
enum class SaveResult { Ok, Refused, Failed };
// Textual name of a file status, for a log line. Static storage.
const char *to_string(FileStatus s);
// The file's text and Clean, or an empty text with the status saying why. A
// file past max_bytes is Unreadable; 0 is no cap. load_file is this plus a parse.
std::pair<std::string, FileStatus> read_file(const std::string &path, std::size_t max_bytes = 0);
// The temp-file-and-rename write the saves go through, for bytes that are not
// a document. False when it failed, with errno saying why.
bool write_file_atomic(const std::string &path, std::string_view data);
#endif

// A parsed document. Its const members may be called on one Document from
// several threads at once. A member that changes it needs the caller to keep
// every other call off that Document meanwhile, as with any std type.
class Document {
	// The C document. It is never defined on this side, and the Document owns
	// it: moves hand it over, copies are deleted, and destruction frees it.
	struct Handle;
	struct Free { void operator()(Handle *h) const noexcept; };
	std::unique_ptr<Handle, Free> d_;
	explicit Document(Handle *h) noexcept : d_(h) {}
	friend struct detail::Access;

public:
	// An empty document, so a default-constructed Document is usable.
	Document();
	Document(const Document &) = delete;
	Document &operator=(const Document &) = delete;
	Document(Document &&) noexcept = default;
	Document &operator=(Document &&) noexcept = default;

	// False when the parse or load could not allocate and there is no document
	// to work with, and on a moved-from Document. True on any system that has
	// not run out of memory; every call below assumes a true one.
	explicit operator bool() const { return d_ != nullptr; }

	// A parse never fails on the document's account: bad lines are skipped and
	// diagnosed. A strict one that found errors says so in strict_failed().
	static Document parse(std::string_view text);
	static Document parse_with(std::string_view text, Strictness s);
	// parse_with, keeping a copy of the text for to_text_keep_lines().
	static Document parse_keep_lines(std::string_view text, Strictness s);
	// Parse with resource caps (E020 stops the parse past max_nodes, E021
	// refuses a line whose array would exceed max_elements, E022 ends a
	// diagnostics list cut at max_diags with a count of the rest; 0 = no cap).
	static Document parse_limited(std::string_view text, Strictness s, std::size_t max_nodes, std::size_t max_elements, std::size_t max_diags);

	// Parse at a strictness, validate against a schema, and hand back a
	// document whose diagnostics() serve one combined list, parse first. Never
	// fails: error_count() answers "did it fail". An empty schema text skips
	// validation; the H001 and H002 hints the schema disavows are dropped.
	static Document load_and_validate(std::string_view text, std::string_view schema, Strictness s);

#ifndef SHCL_NO_FILE_IO
	// File tier. The status separates absent, unreadable, parsed with errors
	// and clean. An allocation failure is the one exception, and shows as a
	// false document.
	static std::pair<Document, FileStatus> load_file(const std::string &path);
	static std::pair<Document, FileStatus> load_file_with(const std::string &path, Strictness s);
	// load_file_with, keeping the text for to_text_keep_lines().
	static std::pair<Document, FileStatus> load_file_keep_lines(const std::string &path, Strictness s);
	// Canonical text, written atomically: the CLI --write mechanics.
	SaveResult save_file(const std::string &path) const;
	SaveResult save_file_lossy(const std::string &path) const;
	// save_file with to_text_keep_lines(), and whether it kept the lines or
	// wrote the canonical form instead. Refuses the way save_file does.
	std::pair<SaveResult, bool> save_file_keep_lines(const std::string &path) const;
#endif

	// True when a strict load would fail: strict, and an error diagnostic exists.
	bool strict_failed() const;
	Strictness strictness() const;
	std::string to_canonical() const;
	// The text a save that keeps lines writes, and whether it kept them: each
	// line the edits did not touch comes back byte for byte, and the canonical
	// form stands in when the result would not reload as this document, or
	// the document was not loaded to keep its lines, or it took a merge.
	std::pair<std::string, bool> to_text_keep_lines() const;

	// Diagnostics in emission order: parse-time ones, then repeated-leaf hints.
	std::vector<Diagnostic> diagnostics() const;
	// How many error-severity diagnostics the document carries. After
	// load_and_validate, that includes validation errors.
	std::size_t error_count() const;
	// How many lines or values parsing dropped that canonical output cannot
	// re-emit. Content-malformed lines do NOT count - those survive a save.
	// Nonzero is why save_file refuses; save_file_lossy is the override.
	std::size_t lost_count() const;

	// Schema validation (spec.md "Schema validation"): empty result = conforms.
	// Schema faults (V09x, schema-file lines) come first; the surviving
	// constraints still check the document, and the unknown-field sweep skips
	// only when a fault cost a path spelling. The H001/H002 hints a schema
	// disavows are NOT dropped here - they live on the parse's diagnostics,
	// which validation does not touch; load_and_validate is the call that
	// drops them.
	std::vector<Diagnostic> validate(const Document &schema) const;

	// Layered loading: overlay `over` (a higher-priority layer) onto this doc.
	// Leaf names in `over` override; container instances merge by (name, value).
	// A document merged onto itself is left as it is.
	void merge(const Document &over);
	// Give back what repeated writes left behind: the document is rebuilt into
	// fresh storage holding only what it now contains. For a long-running
	// writer; a write-once consumer never needs it.
	void compact();

	// Instance count at a path (0 when nothing matches).
	std::size_t count(std::string_view path) const;
	// Every field path, file order, deduplicated. A segment that is not
	// bare-name-safe comes back quoted, so each path reads back as a lookup.
	std::vector<std::string> paths() const;
	// paths() one instance at a time: every binding's path, with [#i] on each
	// segment whose name its parent repeats, so each path reads one node.
	std::vector<std::string> instance_paths() const;
	// The comment lines above the node(s) at a path, the ones clear_comments
	// takes, each from its `#` on, so a program can tell its own comment from
	// one a user wrote there.
	std::vector<std::string> comments(std::string_view path) const;
	// Instance display values at a path, in file order.
	std::vector<std::string> instances(std::string_view path) const;
	// Child field names under a path, file order, duplicates included; "" is
	// the top level, and a path with several instances lists each one's in
	// turn. Names as stored - quote_segment() splices one into a path.
	std::vector<std::string> children(std::string_view path) const;
	// 1-based source line of the binding at a path; 0 when it does not resolve
	// to exactly one node or the node was writer-built.
	std::size_t line(std::string_view path) const;
	// The plural line(): every binding's line, in file order. Unresolved
	// wildcard slots stay in the list as 0; a miss is the empty vector.
	std::vector<std::size_t> lines(std::string_view path) const;
	// Whether the single scalar value at a path was quoted in the source, so a
	// quoted plain string is distinguishable from a bare word that happens to
	// spell a reserved one. False for anything that is not one scalar element.
	// A written value counts as quoted when a save would quote it.
	bool quoted(std::string_view path) const;
	// Whether a path resolves to at least one node.
	bool exists(std::string_view path) const;
	// The field name at a path exactly as the author wrote it (case
	// unfolded, outer quotes stripped - escape sequences stay as written too,
	// where every other name operation sees them resolved); empty when the path
	// does not resolve to exactly one node.
	std::string authored_name(std::string_view path) const;
	// Why a write at a path would fail. Probes only; never creates.
	WriteReason write_reason(std::string_view path) const;

	// Writes. A setter creates the path as needed and returns false when the
	// path is unusable (write_reason() says why) or the value has no spelling
	// the reader accepts: a non-finite float, a datetime the reader would
	// refuse, a raw info string holding a `#`. Nothing is created on false. An
	// ignored false means the save that follows writes a document missing the
	// edit, hence nodiscard.
	[[nodiscard]] bool set_int(std::string_view path, std::int64_t v);
	[[nodiscard]] bool set_float(std::string_view path, double v);
	[[nodiscard]] bool set_bool(std::string_view path, bool v);
	[[nodiscard]] bool set_string(std::string_view path, std::string_view v);
	[[nodiscard]] bool set_datetime(std::string_view path, const DateTime &v);
	// A fence longer than any content line is picked for it. A body line ending
	// in CR fails the write, since a load takes that CR off.
	[[nodiscard]] bool set_raw(std::string_view path, std::string_view content, std::string_view info);
	// An empty value, which is not the empty string.
	[[nodiscard]] bool set_empty(std::string_view path);

	// Inline arrays, one per call.
	[[nodiscard]] bool set_int_array(std::string_view path, const std::vector<std::int64_t> &v);
	[[nodiscard]] bool set_float_array(std::string_view path, const std::vector<double> &v);
	[[nodiscard]] bool set_bool_array(std::string_view path, const std::vector<bool> &v);
	[[nodiscard]] bool set_string_array(std::string_view path, const std::vector<std::string> &v);
	[[nodiscard]] bool set_datetime_array(std::string_view path, const std::vector<DateTime> &v);

	// Text bound as value syntax rather than as data, so "80, 443" is a
	// two-element array where set_string would store one string. False for text
	// no single line could hold: a line break, or a quote that never closes. A
	// `#` outside quotes ends the value as it would in a file.
	[[nodiscard]] bool set_literal(std::string_view path, std::string_view text);

	// Only-if-absent forms of the setters above. Each writes only where nothing
	// is yet, and returns true when something already is.
	[[nodiscard]] bool set_int_default(std::string_view path, std::int64_t v);
	[[nodiscard]] bool set_float_default(std::string_view path, double v);
	[[nodiscard]] bool set_bool_default(std::string_view path, bool v);
	[[nodiscard]] bool set_string_default(std::string_view path, std::string_view v);
	[[nodiscard]] bool set_datetime_default(std::string_view path, const DateTime &v);
	[[nodiscard]] bool set_literal_default(std::string_view path, std::string_view text);
	[[nodiscard]] bool set_raw_default(std::string_view path, std::string_view content, std::string_view info);
	[[nodiscard]] bool set_int_array_default(std::string_view path, const std::vector<std::int64_t> &v);
	[[nodiscard]] bool set_float_array_default(std::string_view path, const std::vector<double> &v);
	[[nodiscard]] bool set_bool_array_default(std::string_view path, const std::vector<bool> &v);
	[[nodiscard]] bool set_string_array_default(std::string_view path, const std::vector<std::string> &v);
	[[nodiscard]] bool set_datetime_array_default(std::string_view path, const std::vector<DateTime> &v);

	// Delete the nodes at a path, subtrees included, and say how many.
	std::size_t remove(std::string_view path);
	// A leading comment line on the node at a path, creating an empty node when
	// there is none so a section can be annotated. A missing `#` is added. Text
	// holding a line break is refused, since a comment is one line.
	[[nodiscard]] bool set_comment(std::string_view path, std::string_view text);
	// Take off the comment lines above the nodes at a path, so a comment can be
	// replaced, and say how many came off.
	std::size_t clear_comments(std::string_view path);
	// The info block at the end, an old one taken off first; false only takes
	// it off. Says how many old blocks came off.
	std::size_t set_banner(bool on);

	// Typed reads: the value, and why it is missing or unreadable if it is.
	Read<std::int64_t> read_int(std::string_view path) const;
	Read<double> read_float(std::string_view path) const;
	Read<bool> read_bool(std::string_view path) const;
	Read<DateTime> read_datetime(std::string_view path) const;
	Read<std::string> read_string(std::string_view path) const;
	Read<std::string> read_raw(std::string_view path) const;
	Read<std::string> read_raw_info(std::string_view path) const;
	// The datetime as the reference's textual form.
	Read<std::string> read_datetime_str(std::string_view path) const;
	// A duration in whole milliseconds and a size in whole bytes. A bare
	// number takes its unit from the field name when the name ends in one
	// (`timeout-ms`, `cache_mb`), else from unit, and is BadType with neither.
	Read<std::chrono::milliseconds> read_duration(std::string_view path, std::optional<DurationUnit> unit = std::nullopt) const;
	Read<std::int64_t> read_size(std::string_view path, std::optional<SizeUnit> unit = std::nullopt, bool decimal = false) const;
	std::chrono::milliseconds get_duration_or(std::string_view path, std::optional<DurationUnit> unit, std::chrono::milliseconds def) const;
	std::int64_t get_size_or(std::string_view path, std::optional<SizeUnit> unit, bool decimal, std::int64_t def) const;

	// Array reads carry the per-slot statuses in .slots, so a partly-resolved
	// array says which slots failed rather than only that the read did.
	Read<std::vector<std::int64_t>> read_int_array(std::string_view path) const;
	Read<std::vector<double>> read_float_array(std::string_view path) const;
	Read<std::vector<bool>> read_bool_array(std::string_view path) const;
	Read<std::vector<DateTime>> read_datetime_array(std::string_view path) const;
	Read<std::vector<std::string>> read_string_array(std::string_view path) const;
	// Datetimes as their textual form, matching read_datetime_str.
	Read<std::vector<std::string>> read_datetime_array_str(std::string_view path) const;

	// Compile-time-typed read over std::int64_t, double, bool, std::string and
	// DateTime, and a std::vector of any of those. Any other T - a bare `int`
	// included - fails right here with this message, not as a bare
	// undefined-symbol link error.
	template <class T> Read<T> get(std::string_view) const {
		static_assert(sizeof(T) == 0,
			"shcl::Document::get<T>: T must be exactly int64_t, double, bool, std::string or shcl::DateTime, or a std::vector of one");
		return {};
	}

	// Convenience tier: the value, or the call-site fallback unless Good - so a
	// missing/empty/bad/ambiguous read cannot masquerade as a real zero.
	// get_or<T> covers every get<T> type.
	template <class T> T get_or(std::string_view path, T def) const {
		auto r = get<T>(path);
		if (r.status == Status::Good) return std::move(r.value);
		return def;
	}
	// A raw block and its info string are strings too, so no T can pick them.
	std::string get_raw_or(std::string_view path, std::string def) const;
	std::string get_raw_info_or(std::string_view path, std::string def) const;
};

template <> Read<std::int64_t> Document::get<std::int64_t>(std::string_view path) const;
template <> Read<double> Document::get<double>(std::string_view path) const;
template <> Read<bool> Document::get<bool>(std::string_view path) const;
template <> Read<std::string> Document::get<std::string>(std::string_view path) const;
template <> Read<DateTime> Document::get<DateTime>(std::string_view path) const;
template <> Read<std::vector<std::int64_t>> Document::get<std::vector<std::int64_t>>(std::string_view path) const;
template <> Read<std::vector<double>> Document::get<std::vector<double>>(std::string_view path) const;
template <> Read<std::vector<bool>> Document::get<std::vector<bool>>(std::string_view path) const;
template <> Read<std::vector<std::string>> Document::get<std::vector<std::string>>(std::string_view path) const;
template <> Read<std::vector<DateTime>> Document::get<std::vector<DateTime>>(std::string_view path) const;

// Schema-driven generation (`shcl init`): a commented, typed starter config
// from a schema, and the schema's faults (V09x), which are empty exactly when
// the text is good. A footer naming the format and pointing at the spec is
// written last unless no_banner. The schema is left as it was.
std::pair<std::string, std::vector<Diagnostic>> generate(const Document &schema, bool no_banner = false);

// Drop from doc's diagnostics, in place, the hints a schema disavows: H001
// for a field whose declared repeat upper bound is above 1, H002 for a
// section marked `reopen: true`. load_and_validate runs both; a parse
// followed by validate() runs neither.
void suppress_declared_repeats(const Document &schema, Document &doc);
void suppress_declared_reopens(const Document &schema, Document &doc);

} // namespace shcl

// ===========================================================================
#ifdef SHCL_IMPLEMENTATION

#include <cstdlib>
#include <mutex>

namespace shcl {

static_assert(static_cast<int>(Strictness::Loose) == SHCL_LOOSE && static_cast<int>(Strictness::Standard) == SHCL_STANDARD && static_cast<int>(Strictness::Strict) == SHCL_STRICT, "Strictness drifted from shcl_strictness");
static_assert(static_cast<int>(Severity::Error) == SHCL_SEV_ERROR && static_cast<int>(Severity::Hint) == SHCL_SEV_HINT, "Severity drifted from shcl_severity");
static_assert(static_cast<int>(Status::Good) == SHCL_GOOD && static_cast<int>(Status::Empty) == SHCL_EMPTY && static_cast<int>(Status::NotFound) == SHCL_NOT_FOUND
	&& static_cast<int>(Status::BadType) == SHCL_BAD_TYPE && static_cast<int>(Status::Multiple) == SHCL_MULTIPLE, "Status drifted from shcl_status");
static_assert(static_cast<int>(WriteReason::Writable) == SHCL_W_WRITABLE && static_cast<int>(WriteReason::BadPath) == SHCL_W_BAD_PATH
	&& static_cast<int>(WriteReason::ValueInPath) == SHCL_W_VALUE_IN_PATH && static_cast<int>(WriteReason::Wildcard) == SHCL_W_WILDCARD
	&& static_cast<int>(WriteReason::NoSuchIndex) == SHCL_W_NO_SUCH_INDEX && static_cast<int>(WriteReason::TooDeep) == SHCL_W_TOO_DEEP, "WriteReason drifted from shcl_write_reason");
static_assert(static_cast<int>(Quote::None) == SHCL_QUOTE_NONE && static_cast<int>(Quote::Single) == SHCL_QUOTE_SINGLE
	&& static_cast<int>(Quote::Double) == SHCL_QUOTE_DOUBLE && static_cast<int>(Quote::Open) == SHCL_QUOTE_OPEN, "Quote drifted from shcl_quote");
static_assert(static_cast<int>(Rules::Current) == SHCL_RULES_CURRENT && static_cast<int>(Rules::V2) == SHCL_RULES_V2, "Rules drifted from shcl_rules");
// The C enums put NONE first, so each unit sits one past its C value.
static_assert(static_cast<int>(DurationUnit::Millis) + 1 == SHCL_DURATION_MS && static_cast<int>(DurationUnit::Days) + 1 == SHCL_DURATION_D, "DurationUnit drifted from shcl_duration_unit");
static_assert(static_cast<int>(SizeUnit::Bytes) + 1 == SHCL_SIZE_B && static_cast<int>(SizeUnit::Tera) + 1 == SHCL_SIZE_TB
	&& static_cast<int>(SizeUnit::Kibi) + 1 == SHCL_SIZE_KIB && static_cast<int>(SizeUnit::Tebi) + 1 == SHCL_SIZE_TIB, "SizeUnit drifted from shcl_size_unit");
#ifndef SHCL_NO_FILE_IO
static_assert(static_cast<int>(FileStatus::Clean) == SHCL_FILE_CLEAN && static_cast<int>(FileStatus::HadErrors) == SHCL_FILE_HAD_ERRORS
	&& static_cast<int>(FileStatus::NotFound) == SHCL_FILE_NOT_FOUND && static_cast<int>(FileStatus::Unreadable) == SHCL_FILE_UNREADABLE, "FileStatus drifted from shcl_file_status");
static_assert(static_cast<int>(SaveResult::Ok) == SHCL_SAVE_OK && static_cast<int>(SaveResult::Refused) == SHCL_SAVE_REFUSED
	&& static_cast<int>(SaveResult::Failed) == SHCL_SAVE_FAILED, "SaveResult drifted from shcl_save_result");
#endif
static_assert(MAX_DEPTH == SHCL_MAX_DEPTH && FORMAT_MAJOR == SHCL_FORMAT_MAJOR, "a constant drifted from shcl.h");

// The strings are the C macros themselves, so there is one copy of each.
const std::string_view GEN_BANNER = SHCL_GEN_BANNER;
const std::string_view FORMAT_LINE_HEAD = SHCL_FORMAT_LINE_HEAD;
const std::string_view FORMAT_LINE = SHCL_FORMAT_LINE;
const std::string_view MIGRATED_LINE = SHCL_MIGRATED_LINE;
const std::string_view SCHEMA_LINE_HEAD = SHCL_SCHEMA_LINE_HEAD;

namespace detail {

struct Access {
	static shcl_doc *doc(const Document &d) noexcept { return reinterpret_cast<shcl_doc *>(d.d_.get()); }
	static Document wrap(shcl_doc *d) noexcept { return Document(reinterpret_cast<Document::Handle *>(d)); }
};

bool status_ok(Status s) { return shcl_status_ok(static_cast<shcl_status>(s)) != 0; }

// A text result with no document behind it still needs a read arena to live in.
struct Scratch {
	shcl_doc *d = shcl_new();
	Scratch() = default;
	Scratch(const Scratch &) = delete;
	Scratch &operator=(const Scratch &) = delete;
	~Scratch() { shcl_free(d); }
};

static std::string str(shcl_str s) { return std::string(s.p, s.n); }
static Status st(shcl_status s) { return static_cast<Status>(s); }
static std::vector<Status> slots(const shcl_status *s, std::size_t n) {
	std::vector<Status> v; v.reserve(n);
	for (std::size_t i = 0; i < n; i++) v.push_back(static_cast<Status>(s[i]));
	return v;
}
static std::vector<std::string> strs(const shcl_str *a, std::size_t n) {
	std::vector<std::string> v; v.reserve(n);
	for (std::size_t i = 0; i < n; i++) v.push_back(str(a[i]));
	return v;
}

// The C view borrows frac from v, so it lives only as long as the call it is for.
static shcl_datetime to_c(const DateTime &v) {
	shcl_datetime c{};
	c.zone = SHCL_ZONE_NONE;
	if (v.date) { c.has_date = 1; c.year = v.date->year; c.month = v.date->month; c.day = v.date->day; }
	if (v.time) {
		c.has_time = 1; c.hour = v.time->hour; c.minute = v.time->minute;
		if (v.time->second) { c.has_sec = 1; c.sec = *v.time->second; }
	}
	if (v.frac) { c.has_frac = 1; c.frac.p = v.frac->data(); c.frac.n = v.frac->size(); }
	if (v.zone) { c.zone = v.zone->kind == ZoneKind::Utc ? SHCL_ZONE_UTC : SHCL_ZONE_OFFSET; c.off_min = v.zone->offset_minutes; }
	return c;
}
static DateTime from_c(const shcl_datetime &c) {
	DateTime v;
	if (c.has_date) v.date = Date{c.year, c.month, c.day};
	if (c.has_time) v.time = Time{c.hour, c.minute, c.has_sec ? std::optional<std::uint32_t>(c.sec) : std::nullopt};
	if (c.has_frac) v.frac = c.frac.p ? std::string(c.frac.p, c.frac.n) : std::string();
	if (c.zone != SHCL_ZONE_NONE) v.zone = Zone{c.zone == SHCL_ZONE_UTC ? ZoneKind::Utc : ZoneKind::Offset, c.off_min};
	return v;
}
static std::string dt_str(const shcl_datetime &c) { char b[SHCL_DT_BUF]; return std::string(b, shcl_datetime_str(&c, b)); }

// What the array setters hand the core. Each lives only for the call.
struct StrArgs { std::vector<const char *> p; std::vector<std::size_t> n; };
static StrArgs str_args(const std::vector<std::string> &v) {
	StrArgs a; a.p.reserve(v.size()); a.n.reserve(v.size());
	for (const std::string &s : v) { a.p.push_back(s.data()); a.n.push_back(s.size()); }
	return a;
}
// std::vector<bool> packs its bits and has no data(), and the core takes ints.
static std::vector<int> bool_args(const std::vector<bool> &v) { return std::vector<int>(v.begin(), v.end()); }
static std::vector<shcl_datetime> dt_args(const std::vector<DateTime> &v) {
	std::vector<shcl_datetime> a; a.reserve(v.size());
	for (const DateTime &x : v) a.push_back(to_c(x));
	return a;
}

// The core's spans live in the read arena, so they are copied before the
// scratch document behind them goes.
static void copy_tokens(const shcl_tokens &t, Tokens &out) {
	auto piece = [](const shcl_piece &p) { return Piece{p.start, p.end, static_cast<Quote>(p.quote)}; };
	out.segments.clear();
	out.segments.reserve(t.nseg);
	for (std::size_t i = 0; i < t.nseg; i++) {
		const shcl_seg_tok &s = t.segments[i];
		out.segments.push_back({piece(s.name), s.has_selector ? std::optional<Piece>(piece(s.selector)) : std::nullopt, s.star != 0});
	}
	out.sep = t.has_sep ? std::optional<std::size_t>(t.sep) : std::nullopt;
	out.value_start = t.value_start;
	out.value_end = t.value_end;
	out.elements.clear();
	out.elements.reserve(t.nelem);
	for (std::size_t i = 0; i < t.nelem; i++) out.elements.push_back(piece(t.elements[i]));
	out.comment = t.has_comment ? std::optional<std::size_t>(t.comment) : std::nullopt;
	out.fault_at = t.has_fault ? std::optional<std::size_t>(t.fault_at) : std::nullopt;
	out.fault_why = t.has_fault ? t.fault_why : nullptr;
	out.capped = t.capped != 0;
}

static shcl_doc *doc(const Document &d) noexcept { return Access::doc(d); }

// Every call on the core writes to the document behind it, const or not: the
// read arena, the scratch arena, the index it builds on first use. A const
// member is safe from several threads at once, as a C++ reader expects of
// const, because each holds its document's lock for the whole call (20260926
// item 7). The locks are a fixed set picked by address, and recursive, since
// a const member can call another and two documents can share one. A write is
// not const and is the caller's to keep to one thread, as with any std type.
static std::recursive_mutex &lock_for(const shcl_doc *p) noexcept {
	static std::recursive_mutex locks[64];
	return locks[(reinterpret_cast<std::uintptr_t>(p) >> 4) % 64];
}
struct Held {
	std::unique_lock<std::recursive_mutex> lock;
	shcl_doc *p;
	operator shcl_doc *() const noexcept { return p; }
};
static Held held(const Document &d) {
	shcl_doc *p = Access::doc(d);
	return Held{std::unique_lock<std::recursive_mutex>(lock_for(p)), p};
}
// Two documents at once, locked together so two threads taking the same pair
// the other way round cannot deadlock.
struct HeldPair {
	std::unique_lock<std::recursive_mutex> a, b;
};
static HeldPair held(const Document &x, const Document &y) {
	HeldPair h{std::unique_lock<std::recursive_mutex>(lock_for(Access::doc(x)), std::defer_lock), std::unique_lock<std::recursive_mutex>(lock_for(Access::doc(y)), std::defer_lock)};
	std::lock(h.a, h.b);
	return h;
}
// Each read hands back the previous one's core memory first. Every result is
// copied into std types, so the arena behind it is dead once the copy is made,
// and a long-lived Document stays flat instead of holding every result until
// it goes. The copy is made while the lock is held.
static Held fresh(const Document &d) {
	Held h = held(d);
	shcl_reads_release(h.p);
	return h;
}

static Migration migration(shcl_migration m) {
	// Owned from the call on, so a throw below cannot leak the C buffer.
	std::unique_ptr<char, void (*)(void *)> p(m.text, &std::free);
	return Migration{std::string(p.get(), m.len), m.current != 0, m.ambiguous, m.lost};
}

} // namespace detail

using detail::Access;

std::string DateTime::str() const { return detail::dt_str(detail::to_c(*this)); }

const char *to_string(Status s) { return shcl_status_name(static_cast<shcl_status>(s)); }
int status_code(Status s) { return shcl_status_code(static_cast<shcl_status>(s)); }

std::optional<Strictness> strictness_from_arg(std::string_view s) {
	shcl_strictness out = SHCL_STANDARD;
	if (!shcl_strictness_from_arg(s.data(), s.size(), &out)) return std::nullopt;
	return static_cast<Strictness>(out);
}

std::string format_float(double v) { char b[SHCL_FLOAT_BUF]; return std::string(b, shcl_format_float(v, b)); }

std::optional<DateTime> parse_datetime(std::string_view s) {
	shcl_datetime out;
	if (!shcl_parse_datetime(s.data(), s.size(), &out)) return std::nullopt;
	return detail::from_c(out);
}

std::string quote_segment(std::string_view name) {
	detail::Scratch k;
	if (!k.d) return std::string();
	return detail::str(shcl_quote_segment(k.d, name.data(), name.size()));
}

std::size_t Tokens::element_count() const {
	std::vector<shcl_piece> e; e.reserve(elements.size());
	for (const Piece &x : elements) e.push_back({x.start, x.end, static_cast<shcl_quote>(x.quote)});
	shcl_tokens t{}; t.elements = e.data(); t.nelem = e.size();
	return shcl_tokens_element_count(&t);
}

void tokenize(std::string_view text, char sep, bool path, Rules rules, Tokens &out) {
	detail::Scratch k;
	shcl_tokens t{}; t.cap = out.cap;
	if (k.d) shcl_tokenize(k.d, text.data(), text.size(), sep, path ? 1 : 0, static_cast<shcl_rules>(rules), &t);
	detail::copy_tokens(t, out);
}

void tokenize_value(std::string_view text, std::size_t from, Rules rules, Tokens &out) {
	detail::Scratch k;
	shcl_tokens t{}; t.cap = out.cap;
	if (k.d) shcl_tokenize_value(k.d, text.data(), text.size(), from, static_cast<shcl_rules>(rules), &t);
	detail::copy_tokens(t, out);
}

Migration migrate(std::string_view text, bool from_v2) { return detail::migration(shcl_migrate(text.data(), text.size(), from_v2 ? 1 : 0)); }
Migration migrate_unstamped(std::string_view text, bool from_v2) { return detail::migration(shcl_migrate_unstamped(text.data(), text.size(), from_v2 ? 1 : 0)); }

std::optional<std::uint32_t> format_version(std::string_view text) {
	std::int64_t v = shcl_format_version(text.data(), text.size());
	if (v < 0) return std::nullopt;
	return static_cast<std::uint32_t>(v);
}

std::optional<DurationUnit> duration_unit_from_spelling(std::string_view s) {
	shcl_duration_unit u = shcl_duration_unit_of(s.data(), s.size());
	if (u == SHCL_DURATION_NONE) return std::nullopt;
	return static_cast<DurationUnit>(static_cast<int>(u) - 1);
}
std::optional<SizeUnit> size_unit_from_spelling(std::string_view s) {
	shcl_size_unit u = shcl_size_unit_of(s.data(), s.size());
	if (u == SHCL_SIZE_NONE) return std::nullopt;
	return static_cast<SizeUnit>(static_cast<int>(u) - 1);
}
std::string_view spelling(DurationUnit u) { return shcl_duration_unit_spelling(static_cast<shcl_duration_unit>(static_cast<int>(u) + 1)); }
std::string_view spelling(SizeUnit u) { return shcl_size_unit_spelling(static_cast<shcl_size_unit>(static_cast<int>(u) + 1)); }

std::optional<std::string> schema_ref(std::string_view text) {
	std::size_t n = 0;
	const char *r = shcl_schema_ref(text.data(), text.size(), &n);
	if (!r) return std::nullopt;
	return std::string(r, n);
}

#ifndef SHCL_NO_FILE_IO
const char *to_string(FileStatus s) { return shcl_file_status_name(static_cast<shcl_file_status>(s)); }

std::pair<std::string, FileStatus> read_file(const std::string &path, std::size_t max_bytes) {
	// Initialized: the status should never depend on the callee having written it.
	shcl_file_status cs = SHCL_FILE_UNREADABLE;
	std::size_t n = 0;
	std::unique_ptr<char, void (*)(void *)> p(shcl_read_file(path.c_str(), max_bytes, &n, &cs), &std::free);
	if (!p) return {std::string(), static_cast<FileStatus>(cs)};
	return {std::string(p.get(), n), static_cast<FileStatus>(cs)};
}

bool write_file_atomic(const std::string &path, std::string_view data) { return shcl_write_file_atomic(path.c_str(), data.data(), data.size()) != 0; }
#endif

void Document::Free::operator()(Handle *h) const noexcept { shcl_free(reinterpret_cast<shcl_doc *>(h)); }

Document::Document() : d_(reinterpret_cast<Handle *>(shcl_new())) {}

Document Document::parse(std::string_view text) { return Access::wrap(shcl_parse(text.data(), text.size())); }
Document Document::parse_with(std::string_view text, Strictness s) { return Access::wrap(shcl_parse_with(text.data(), text.size(), static_cast<shcl_strictness>(s))); }
Document Document::parse_keep_lines(std::string_view text, Strictness s) { return Access::wrap(shcl_parse_keep_lines(text.data(), text.size(), static_cast<shcl_strictness>(s))); }
Document Document::parse_limited(std::string_view text, Strictness s, std::size_t max_nodes, std::size_t max_elements, std::size_t max_diags) {
	return Access::wrap(shcl_parse_limited(text.data(), text.size(), static_cast<shcl_strictness>(s), max_nodes, max_elements, max_diags));
}
Document Document::load_and_validate(std::string_view text, std::string_view schema, Strictness s) {
	return Access::wrap(shcl_load_and_validate(text.data(), text.size(), schema.data(), schema.size(), static_cast<shcl_strictness>(s)));
}

#ifndef SHCL_NO_FILE_IO
std::pair<Document, FileStatus> Document::load_file(const std::string &path) {
	shcl_file_status cs = SHCL_FILE_UNREADABLE;
	Document d = Access::wrap(shcl_load_file(path.c_str(), &cs));
	return {std::move(d), static_cast<FileStatus>(cs)};
}
std::pair<Document, FileStatus> Document::load_file_with(const std::string &path, Strictness s) {
	shcl_file_status cs = SHCL_FILE_UNREADABLE;
	Document d = Access::wrap(shcl_load_file_with(path.c_str(), static_cast<shcl_strictness>(s), &cs));
	return {std::move(d), static_cast<FileStatus>(cs)};
}
std::pair<Document, FileStatus> Document::load_file_keep_lines(const std::string &path, Strictness s) {
	shcl_file_status cs = SHCL_FILE_UNREADABLE;
	Document d = Access::wrap(shcl_load_file_keep_lines(path.c_str(), static_cast<shcl_strictness>(s), &cs));
	return {std::move(d), static_cast<FileStatus>(cs)};
}
SaveResult Document::save_file(const std::string &path) const { return static_cast<SaveResult>(shcl_save_file(detail::held(*this), path.c_str())); }
SaveResult Document::save_file_lossy(const std::string &path) const { return static_cast<SaveResult>(shcl_save_file_lossy(detail::held(*this), path.c_str())); }
std::pair<SaveResult, bool> Document::save_file_keep_lines(const std::string &path) const {
	int k = 0;
	SaveResult r = static_cast<SaveResult>(shcl_save_file_keep_lines(detail::held(*this), path.c_str(), &k));
	return {r, k != 0};
}
#endif

bool Document::strict_failed() const { return shcl_strict_failed(detail::held(*this)) != 0; }
Strictness Document::strictness() const { return static_cast<Strictness>(shcl_strictness_of(detail::held(*this))); }
// The canonical text lives in the read arena like every other result, so a
// save loop that did not release first would hold every copy.
std::string Document::to_canonical() const { return detail::str(shcl_to_canonical(detail::fresh(*this))); }
std::pair<std::string, bool> Document::to_text_keep_lines() const {
	int k = 0;
	std::string t = detail::str(shcl_to_text_keep_lines(detail::fresh(*this), &k));
	return {std::move(t), k != 0};
}

std::vector<Diagnostic> Document::diagnostics() const {
	auto d = detail::held(*this);
	std::vector<Diagnostic> v; std::size_t n = shcl_diag_count(d);
	v.reserve(n);
	for (std::size_t i = 0; i < n; i++)
		v.push_back({shcl_diag_line(d, i), static_cast<Severity>(shcl_diag_severity(d, i)), detail::str(shcl_diag_message(d, i)), shcl_diag_code(d, i)});
	return v;
}
std::size_t Document::error_count() const { return shcl_error_count(detail::held(*this)); }
std::size_t Document::lost_count() const { return shcl_lost_count(detail::held(*this)); }

std::vector<Diagnostic> Document::validate(const Document &schema) const {
	std::vector<Diagnostic> v;
	// Owned from the call on, so a throw while copying cannot leak it.
	auto h = detail::held(*this, schema);
	std::unique_ptr<shcl_validation, void (*)(shcl_validation *)> r(shcl_validate(detail::doc(*this), Access::doc(schema)), &shcl_validation_free);
	if (!r) return v; // an allocation failed; the document is finished
	std::size_t n = shcl_validation_count(r.get());
	v.reserve(n);
	for (std::size_t i = 0; i < n; i++)
		v.push_back({shcl_validation_line(r.get(), i), static_cast<Severity>(shcl_validation_severity(r.get(), i)), detail::str(shcl_validation_message(r.get(), i)), shcl_validation_code(r.get(), i)});
	return v;
}

void Document::merge(const Document &over) { shcl_merge(detail::doc(*this), detail::held(over)); }
void Document::compact() { shcl_compact(detail::doc(*this)); }

std::size_t Document::count(std::string_view path) const { return shcl_count(detail::held(*this), path.data(), path.size()); }
std::vector<std::string> Document::paths() const { auto h = detail::fresh(*this); shcl_str *a; std::size_t n = shcl_paths(h, &a); return detail::strs(a, n); }
std::vector<std::string> Document::instance_paths() const { auto h = detail::fresh(*this); shcl_str *a; std::size_t n = shcl_instance_paths(h, &a); return detail::strs(a, n); }
std::vector<std::string> Document::comments(std::string_view path) const { auto h = detail::fresh(*this); shcl_str *a; std::size_t n = shcl_comments(h, path.data(), path.size(), &a); return detail::strs(a, n); }
std::vector<std::string> Document::instances(std::string_view path) const { auto h = detail::fresh(*this); shcl_str *a; std::size_t n = shcl_instances(h, path.data(), path.size(), &a); return detail::strs(a, n); }
std::vector<std::string> Document::children(std::string_view path) const { auto h = detail::fresh(*this); shcl_str *a; std::size_t n = shcl_children(h, path.data(), path.size(), &a); return detail::strs(a, n); }
std::size_t Document::line(std::string_view path) const { return shcl_line(detail::held(*this), path.data(), path.size()); }
std::vector<std::size_t> Document::lines(std::string_view path) const {
	auto h = detail::fresh(*this);
	std::size_t *a; std::size_t n = shcl_lines(h, path.data(), path.size(), &a);
	return std::vector<std::size_t>(a, a + n);
}
bool Document::quoted(std::string_view path) const { return shcl_quoted(detail::held(*this), path.data(), path.size()) != 0; }
bool Document::exists(std::string_view path) const { return shcl_exists(detail::held(*this), path.data(), path.size()) != 0; }
std::string Document::authored_name(std::string_view path) const { return detail::str(shcl_authored_name(detail::held(*this), path.data(), path.size())); }
WriteReason Document::write_reason(std::string_view path) const { return static_cast<WriteReason>(shcl_write_reason_(detail::held(*this), path.data(), path.size())); }

bool Document::set_int(std::string_view path, std::int64_t v) { return shcl_set_int(detail::doc(*this), path.data(), path.size(), v) != 0; }
bool Document::set_float(std::string_view path, double v) { return shcl_set_float(detail::doc(*this), path.data(), path.size(), v) != 0; }
bool Document::set_bool(std::string_view path, bool v) { return shcl_set_bool(detail::doc(*this), path.data(), path.size(), v ? 1 : 0) != 0; }
bool Document::set_string(std::string_view path, std::string_view v) { return shcl_set_string(detail::doc(*this), path.data(), path.size(), v.data(), v.size()) != 0; }
bool Document::set_datetime(std::string_view path, const DateTime &v) { shcl_datetime c = detail::to_c(v); return shcl_set_datetime(detail::doc(*this), path.data(), path.size(), &c) != 0; }
bool Document::set_raw(std::string_view path, std::string_view content, std::string_view info) { return shcl_set_raw(detail::doc(*this), path.data(), path.size(), content.data(), content.size(), info.data(), info.size()) != 0; }
bool Document::set_empty(std::string_view path) { return shcl_set_empty(detail::doc(*this), path.data(), path.size()) != 0; }
bool Document::set_int_array(std::string_view path, const std::vector<std::int64_t> &v) { return shcl_set_int_array(detail::doc(*this), path.data(), path.size(), v.data(), v.size()) != 0; }
bool Document::set_float_array(std::string_view path, const std::vector<double> &v) { return shcl_set_float_array(detail::doc(*this), path.data(), path.size(), v.data(), v.size()) != 0; }
bool Document::set_bool_array(std::string_view path, const std::vector<bool> &v) { auto b = detail::bool_args(v); return shcl_set_bool_array(detail::doc(*this), path.data(), path.size(), b.data(), b.size()) != 0; }
bool Document::set_string_array(std::string_view path, const std::vector<std::string> &v) { auto a = detail::str_args(v); return shcl_set_string_array(detail::doc(*this), path.data(), path.size(), a.p.data(), a.n.data(), v.size()) != 0; }
bool Document::set_datetime_array(std::string_view path, const std::vector<DateTime> &v) { auto a = detail::dt_args(v); return shcl_set_datetime_array(detail::doc(*this), path.data(), path.size(), a.data(), a.size()) != 0; }
bool Document::set_literal(std::string_view path, std::string_view text) { return shcl_set_literal(detail::doc(*this), path.data(), path.size(), text.data(), text.size()) != 0; }

bool Document::set_int_default(std::string_view path, std::int64_t v) { return shcl_set_int_default(detail::doc(*this), path.data(), path.size(), v) != 0; }
bool Document::set_float_default(std::string_view path, double v) { return shcl_set_float_default(detail::doc(*this), path.data(), path.size(), v) != 0; }
bool Document::set_bool_default(std::string_view path, bool v) { return shcl_set_bool_default(detail::doc(*this), path.data(), path.size(), v ? 1 : 0) != 0; }
bool Document::set_string_default(std::string_view path, std::string_view v) { return shcl_set_string_default(detail::doc(*this), path.data(), path.size(), v.data(), v.size()) != 0; }
bool Document::set_datetime_default(std::string_view path, const DateTime &v) { shcl_datetime c = detail::to_c(v); return shcl_set_datetime_default(detail::doc(*this), path.data(), path.size(), &c) != 0; }
bool Document::set_literal_default(std::string_view path, std::string_view text) { return shcl_set_literal_default(detail::doc(*this), path.data(), path.size(), text.data(), text.size()) != 0; }
bool Document::set_raw_default(std::string_view path, std::string_view content, std::string_view info) { return shcl_set_raw_default(detail::doc(*this), path.data(), path.size(), content.data(), content.size(), info.data(), info.size()) != 0; }
bool Document::set_int_array_default(std::string_view path, const std::vector<std::int64_t> &v) { return shcl_set_int_array_default(detail::doc(*this), path.data(), path.size(), v.data(), v.size()) != 0; }
bool Document::set_float_array_default(std::string_view path, const std::vector<double> &v) { return shcl_set_float_array_default(detail::doc(*this), path.data(), path.size(), v.data(), v.size()) != 0; }
bool Document::set_bool_array_default(std::string_view path, const std::vector<bool> &v) { auto b = detail::bool_args(v); return shcl_set_bool_array_default(detail::doc(*this), path.data(), path.size(), b.data(), b.size()) != 0; }
bool Document::set_string_array_default(std::string_view path, const std::vector<std::string> &v) { auto a = detail::str_args(v); return shcl_set_string_array_default(detail::doc(*this), path.data(), path.size(), a.p.data(), a.n.data(), v.size()) != 0; }
bool Document::set_datetime_array_default(std::string_view path, const std::vector<DateTime> &v) { auto a = detail::dt_args(v); return shcl_set_datetime_array_default(detail::doc(*this), path.data(), path.size(), a.data(), a.size()) != 0; }

std::size_t Document::remove(std::string_view path) { return shcl_remove(detail::doc(*this), path.data(), path.size()); }
bool Document::set_comment(std::string_view path, std::string_view text) { return shcl_set_comment(detail::doc(*this), path.data(), path.size(), text.data(), text.size()) != 0; }
std::size_t Document::clear_comments(std::string_view path) { return shcl_clear_comments(detail::doc(*this), path.data(), path.size()); }
std::size_t Document::set_banner(bool on) { return shcl_set_banner(detail::doc(*this), on ? 1 : 0); }

Read<std::int64_t> Document::read_int(std::string_view path) const { auto h = detail::held(*this); auto r = shcl_read_int(h, path.data(), path.size()); return {r.value, detail::st(r.status)}; }
Read<double> Document::read_float(std::string_view path) const { auto h = detail::held(*this); auto r = shcl_read_float(h, path.data(), path.size()); return {r.value, detail::st(r.status)}; }
Read<bool> Document::read_bool(std::string_view path) const { auto h = detail::held(*this); auto r = shcl_read_bool_(h, path.data(), path.size()); return {r.value != 0, detail::st(r.status)}; }
Read<DateTime> Document::read_datetime(std::string_view path) const { auto h = detail::held(*this); auto r = shcl_read_datetime(h, path.data(), path.size()); return {detail::from_c(r.value), detail::st(r.status)}; }
namespace detail {
inline shcl_duration_unit c_unit(std::optional<DurationUnit> u) { return u ? static_cast<shcl_duration_unit>(static_cast<int>(*u) + 1) : SHCL_DURATION_NONE; }
inline shcl_size_unit c_unit(std::optional<SizeUnit> u) { return u ? static_cast<shcl_size_unit>(static_cast<int>(*u) + 1) : SHCL_SIZE_NONE; }
}
Read<std::chrono::milliseconds> Document::read_duration(std::string_view path, std::optional<DurationUnit> unit) const {
	auto h = detail::held(*this);
	auto r = shcl_read_duration(h, path.data(), path.size(), detail::c_unit(unit));
	return {std::chrono::milliseconds(r.value), detail::st(r.status)};
}
Read<std::int64_t> Document::read_size(std::string_view path, std::optional<SizeUnit> unit, bool decimal) const {
	auto h = detail::held(*this);
	auto r = shcl_read_size(h, path.data(), path.size(), detail::c_unit(unit), decimal ? 1 : 0);
	return {r.value, detail::st(r.status)};
}
std::chrono::milliseconds Document::get_duration_or(std::string_view path, std::optional<DurationUnit> unit, std::chrono::milliseconds def) const {
	return std::chrono::milliseconds(shcl_get_duration_or(detail::held(*this), path.data(), path.size(), detail::c_unit(unit), static_cast<std::int64_t>(def.count())));
}
std::int64_t Document::get_size_or(std::string_view path, std::optional<SizeUnit> unit, bool decimal, std::int64_t def) const {
	return shcl_get_size_or(detail::held(*this), path.data(), path.size(), detail::c_unit(unit), decimal ? 1 : 0, def);
}
Read<std::string> Document::read_string(std::string_view path) const { auto h = detail::fresh(*this); auto r = shcl_read_string(h, path.data(), path.size()); return {detail::str(r.value), detail::st(r.status)}; }
Read<std::string> Document::read_raw(std::string_view path) const { auto h = detail::fresh(*this); auto r = shcl_read_raw(h, path.data(), path.size()); return {detail::str(r.value), detail::st(r.status)}; }
Read<std::string> Document::read_raw_info(std::string_view path) const { auto h = detail::fresh(*this); auto r = shcl_read_raw_info(h, path.data(), path.size()); return {detail::str(r.value), detail::st(r.status)}; }
Read<std::string> Document::read_datetime_str(std::string_view path) const { auto h = detail::held(*this); auto r = shcl_read_datetime(h, path.data(), path.size()); return {detail::dt_str(r.value), detail::st(r.status)}; }

Read<std::vector<std::int64_t>> Document::read_int_array(std::string_view path) const {
	auto h = detail::fresh(*this);
	auto r = shcl_read_int_array(h, path.data(), path.size());
	return {std::vector<std::int64_t>(r.values, r.values + r.n), detail::st(r.status), detail::slots(r.statuses, r.n)};
}
Read<std::vector<double>> Document::read_float_array(std::string_view path) const {
	auto h = detail::fresh(*this);
	auto r = shcl_read_float_array(h, path.data(), path.size());
	return {std::vector<double>(r.values, r.values + r.n), detail::st(r.status), detail::slots(r.statuses, r.n)};
}
Read<std::vector<bool>> Document::read_bool_array(std::string_view path) const {
	auto h = detail::fresh(*this);
	auto r = shcl_read_bool_array(h, path.data(), path.size());
	std::vector<bool> v; v.reserve(r.n); for (std::size_t i = 0; i < r.n; i++) v.push_back(r.values[i] != 0);
	return {std::move(v), detail::st(r.status), detail::slots(r.statuses, r.n)};
}
Read<std::vector<DateTime>> Document::read_datetime_array(std::string_view path) const {
	auto h = detail::fresh(*this);
	auto r = shcl_read_datetime_array(h, path.data(), path.size());
	std::vector<DateTime> v; v.reserve(r.n);
	for (std::size_t i = 0; i < r.n; i++) v.push_back(detail::from_c(r.values[i]));
	return {std::move(v), detail::st(r.status), detail::slots(r.statuses, r.n)};
}
Read<std::vector<std::string>> Document::read_string_array(std::string_view path) const {
	auto h = detail::fresh(*this);
	auto r = shcl_read_string_array(h, path.data(), path.size());
	return {detail::strs(r.values, r.n), detail::st(r.status), detail::slots(r.statuses, r.n)};
}
Read<std::vector<std::string>> Document::read_datetime_array_str(std::string_view path) const {
	auto h = detail::fresh(*this);
	auto r = shcl_read_datetime_array(h, path.data(), path.size());
	std::vector<std::string> v; v.reserve(r.n);
	for (std::size_t i = 0; i < r.n; i++) v.push_back(detail::dt_str(r.values[i]));
	return {std::move(v), detail::st(r.status), detail::slots(r.statuses, r.n)};
}

std::string Document::get_raw_or(std::string_view path, std::string def) const {
	auto r = read_raw(path);
	if (r.status == Status::Good) return std::move(r.value);
	return def;
}
std::string Document::get_raw_info_or(std::string_view path, std::string def) const {
	auto r = read_raw_info(path);
	if (r.status == Status::Good) return std::move(r.value);
	return def;
}

template <> Read<std::int64_t> Document::get<std::int64_t>(std::string_view path) const { return read_int(path); }
template <> Read<double> Document::get<double>(std::string_view path) const { return read_float(path); }
template <> Read<bool> Document::get<bool>(std::string_view path) const { return read_bool(path); }
template <> Read<std::string> Document::get<std::string>(std::string_view path) const { return read_string(path); }
template <> Read<DateTime> Document::get<DateTime>(std::string_view path) const { return read_datetime(path); }
template <> Read<std::vector<std::int64_t>> Document::get<std::vector<std::int64_t>>(std::string_view path) const { return read_int_array(path); }
template <> Read<std::vector<double>> Document::get<std::vector<double>>(std::string_view path) const { return read_float_array(path); }
template <> Read<std::vector<bool>> Document::get<std::vector<bool>>(std::string_view path) const { return read_bool_array(path); }
template <> Read<std::vector<std::string>> Document::get<std::vector<std::string>>(std::string_view path) const { return read_string_array(path); }
template <> Read<std::vector<DateTime>> Document::get<std::vector<DateTime>>(std::string_view path) const { return read_datetime_array(path); }

std::pair<std::string, std::vector<Diagnostic>> generate(const Document &schema, bool no_banner) {
	auto h = detail::held(schema);
	shcl_doc *d = h;
	int ok = 0;
	shcl_reads_release(d);
	std::string text = detail::str(shcl_generate(d, no_banner ? 1 : 0, &ok));
	// The core records its faults on the schema, flagged, after the schema's
	// own diagnostics. They are taken off again, so the schema reads as it did
	// before the call and the faults are this call's only.
	std::vector<Diagnostic> faults;
	std::size_t w = 0;
	for (std::size_t i = 0; i < d->diags.len; i++) {
		const ShclDiag &g = d->diags.data[i];
		if (!g.generated) { d->diags.data[w++] = g; continue; }
		faults.push_back({g.line, static_cast<Severity>(g.sev), std::string(g.message.p, g.message.n), g.code});
	}
	d->diags.len = w;
	return {ok ? std::move(text) : std::string(), std::move(faults)};
}

void suppress_declared_repeats(const Document &schema, Document &doc) { shcl_suppress_declared_repeats(detail::held(schema), Access::doc(doc)); }
void suppress_declared_reopens(const Document &schema, Document &doc) { shcl_suppress_declared_reopens(detail::held(schema), Access::doc(doc)); }

} // namespace shcl

#endif // SHCL_IMPLEMENTATION
#endif // SHCL_HPP
