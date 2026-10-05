// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! SHCL reference implementation: parser, accessor, writer/formatter.
//! Single file on purpose - the drop-in story is "copy this file into your tree".
//! The language spec lives in project/spec.md; the conformance corpus in
//! project/conformance/ pins every behavior here.
//! Every other binding mirrors this file's structure on purpose (parity over
//! idiom - see project/style-guide_code.md), so restructuring here means
//! restructuring all.

// The library never gives up on a whole file, so a panic macro outside a test
// is an invariant waiting to take a caller down. Every public type is Debug.
#![cfg_attr(
	not(test),
	warn(
		clippy::unwrap_used,
		clippy::expect_used,
		clippy::panic,
		clippy::unreachable
	)
)]
#![warn(missing_debug_implementations)]

use std::collections::{HashMap, HashSet};
use std::hash::{BuildHasherDefault, Hasher};

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

/// Per-document forgiveness knob. Set once at load; composes with per-call onBad.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Strictness {
	Loose,
	#[default]
	Standard,
	Strict,
}

impl Strictness {
	/// Accepts the CLI spellings: loose|standard|strict or 1|2|3.
	pub fn from_arg(s: &str) -> Option<Strictness> {
		match s.to_ascii_lowercase().as_str() {
			"loose" | "1" => Some(Strictness::Loose),
			"standard" | "2" => Some(Strictness::Standard),
			"strict" | "3" => Some(Strictness::Strict),
			_ => None,
		}
	}
}

/// Only `Error` fails a strict load; `Hint` flags legal-but-lookalike input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
	Error,
	Hint,
}

/// One parser or validator finding, tied to a source line.
#[derive(Debug, Clone)]
pub struct Diagnostic {
	pub line: usize, // 1-based
	pub severity: Severity,
	pub message: String,
	/// Stable machine code (E001.., H001..) identifying the diagnostic kind. The
	/// contract lives here; the `message` prose is a free, per-binding voice.
	pub code: &'static str,
}

/// Read status sentinels. `Empty` is informational - the empty value is still returned.
/// Ordered by severity so a worst-of aggregate is just `max`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Status {
	Good,
	Empty,
	NotFound,
	BadType,
	Multiple,
}

impl std::fmt::Display for Status {
	/// The names the other three bindings print. Without this a status reaches
	/// a user-facing message as debug output.
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.write_str(match self {
			Status::Good => "Good",
			Status::Empty => "Empty",
			Status::NotFound => "NotFound",
			Status::BadType => "BadType",
			Status::Multiple => "Multiple",
		})
	}
}

/// What load_file found: the four cases a consumer's own load path otherwise
/// confuses. Clean and HadErrors both have a usable document; NotFound and
/// Unreadable come back with an empty one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileStatus {
	Clean,      // read and parsed, no error diagnostics (hints allowed)
	HadErrors,  // read and parsed, but error diagnostics are present
	NotFound,   // no file at the path
	Unreadable, // exists but could not be read (permissions, a directory, bad encoding, past a read_file cap)
}

/// Why a save did not happen. The two cases need different handling, so they
/// are separate values rather than two spellings of one message: `Refused` is
/// the lost-content gate, which the caller can reverse with `save_file_lossy`,
/// and `Io` is the disk's answer, which they cannot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveError {
	/// This save would delete content from the file (see `lost_count`).
	Refused { path: String, lost: usize },
	/// The write itself failed; has the reported message.
	Io(String),
}

impl std::fmt::Display for SaveError {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			SaveError::Refused { path, lost } => write!(
				f,
				"{}: refusing to save: this write would delete {} line(s)/value(s) from the file (see diagnostics; save_file_lossy overrides)",
				path, lost
			),
			SaveError::Io(m) => f.write_str(m),
		}
	}
}

impl std::error::Error for SaveError {}

/// Why a write would fail (`write_reason()`): the distinctions behind a
/// setter's bare `false`. `Writable` = the path passes the writer's
/// validation; the rest name the five ways it cannot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteReason {
	Writable,
	BadPath,     // empty path, or the scanner rejected it
	ValueInPath, // the path has a `: value` part; writes take values separately
	Wildcard,    // wildcard selectors are query-only
	NoSuchIndex, // a `[#k]` instance that does not (and can never) exist
	TooDeep,     // deeper than the nesting cap; the writer never creates past it
}

/// Full-tier read result: value plus status plus the original raw text (when the
/// path resolved), so a caller can always recover what was actually in the file.
/// Array reads also give one status per slot (element, or wildcard instance) in
/// `slots`; `status` is then the worst slot. Scalar reads leave `slots` empty.
/// `line` is the 1-based source line of the resolved binding (0 when the path
/// did not resolve to one node, or the node was writer-built), so a consumer
/// check the schema cannot express can still cite the line. `quoted` is true
/// when the read's single scalar element was quoted in the source - the escape
/// hatch that lets a downstream language reserve `@null` while `"@null"` stays
/// a plain string. Arrays, raw blocks, and empties leave it false. A written
/// value counts as quoted when a save would quote it. `backtick` is true when
/// that element was a backtick value: raw text the program decodes itself,
/// which SHCL hands back as written. A backtick value counts as quoted too.
#[derive(Debug, Clone)]
pub struct Read<T> {
	pub value: T,
	pub status: Status,
	pub raw: Option<String>,
	pub slots: Vec<Status>,
	pub line: usize,
	pub quoted: bool,
	pub backtick: bool,
}

impl<T> Read<T> {
	fn new(value: T, status: Status, raw: Option<String>) -> Read<T> {
		Read {
			value,
			status,
			raw,
			slots: Vec::new(),
			line: 0,
			quoted: false,
			backtick: false,
		}
	}
	fn with_slots(value: T, status: Status, raw: Option<String>, slots: Vec<Status>) -> Read<T> {
		Read {
			value,
			status,
			raw,
			slots,
			line: 0,
			quoted: false,
			backtick: false,
		}
	}
	fn at(mut self, line: usize, element: Option<&Element>) -> Read<T> {
		self.line = line;
		self.quoted = element.is_some_and(Element::quoted);
		self.backtick = element.is_some_and(|e| e.mark == Mark::Backtick);
		self
	}
	/// Whether the author addressed this field at all: `Good` or `Empty`. Note
	/// this deliberately answers differently from the convenience tier, which
	/// falls back on `Empty` like any other non-Good read - `ok` asks "is this
	/// field spoken for", `get_*_or` asks "do I have a usable value", and an
	/// explicitly emptied field is the case where those two diverge.
	pub fn ok(&self) -> bool {
		matches!(self.status, Status::Good | Status::Empty)
	}
}

/// A failed strict load: the diagnostics that failed it, plus the recovered tree.
#[derive(Debug)]
pub struct LoadError {
	pub diagnostics: Vec<Diagnostic>,
	/// The document the parse produced anyway. Recover-and-continue means the
	/// diagnostics are the point of a failed strict load, and the tree is what
	/// a Standard load would have kept - so a caller can still inspect both.
	pub document: Document,
}

impl std::fmt::Display for LoadError {
	fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
		// Name the first few failures right in the message; the bare count made
		// callers dig for information the error was already holding.
		let errs: Vec<&Diagnostic> = self
			.diagnostics
			.iter()
			.filter(|d| d.severity == Severity::Error)
			.collect();
		write!(f, "strict load failed: {} error diagnostic(s)", errs.len())?;
		for d in errs.iter().take(3) {
			write!(f, "; line {}: {} {}", d.line, d.code, d.message)?;
		}
		if errs.len() > 3 {
			write!(f, "; +{} more", errs.len() - 3)?;
		}
		Ok(())
	}
}

impl std::error::Error for LoadError {}

/// Local (floating) date/time unless a zone suffix was present. Fields mirror
/// what was written: a date-only value has no time, and vice versa.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ShclDateTime {
	pub date: Option<(i32, u32, u32)>,         // (year, month, day)
	pub time: Option<(u32, u32, Option<u32>)>, // (hour, minute, seconds if written)
	pub frac: Option<String>,                  // fractional-second digits as typed
	pub zone: Option<Zone>,
}

/// The name the Go binding uses for the same type; either spelling works.
pub type DateTime = ShclDateTime;

/// Two datetimes name the same moment, whatever the spelling. The struct
/// mirrors what was written, so `12:00:00Z` and `12:00:00+00:00` are different
/// values field by field while naming one time, and `12:00:00` and
/// `12:00:00.0` differ only in written precision. A `[value]` selector matches
/// on text, but an `allowed` set is about the value, so it compares here. An
/// absent zone is local and matches no zone at all - that is the one spelling
/// difference that is a real difference.
fn same_moment(a: &ShclDateTime, b: &ShclDateTime) -> bool {
	let frac = |f: &Option<String>| {
		f.as_deref()
			.map_or(String::new(), |d| d.trim_end_matches('0').to_string())
	};
	let zone = |z: &Option<Zone>| match z {
		Some(Zone::Utc) | Some(Zone::OffsetMinutes(0)) => Some(0),
		Some(Zone::OffsetMinutes(m)) => Some(*m),
		None => None,
	};
	if a.date.is_some() != b.date.is_some()
		|| a.time.is_some() != b.time.is_some()
		|| a.time.map(|t| t.2) != b.time.map(|t| t.2)
		|| frac(&a.frac) != frac(&b.frac)
	{
		return false;
	}
	match (zone(&a.zone), zone(&b.zone)) {
		(None, None) => a.date == b.date && a.time == b.time,
		// Zoned values are instants: the written clock less its offset, the
		// date carrying the day wrap. A time alone lives on a 24-hour cycle.
		(Some(ao), Some(bo)) => {
			let minutes = |dt: &ShclDateTime, off: i32| {
				let hm = dt
					.time
					.map_or(0, |(h, m, _)| i64::from(h) * 60 + i64::from(m))
					- i64::from(off);
				match dt.date {
					Some((y, m, d)) => days_from_civil(y, m, d) * 1440 + hm,
					None => hm.rem_euclid(1440),
				}
			};
			minutes(a, ao) == minutes(b, bo)
		}
		_ => false,
	}
}

/// Days since 1970-01-01 for a civil date, negative before it.
fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
	let y = i64::from(if m <= 2 { y - 1 } else { y });
	let era = y.div_euclid(400);
	let yoe = y - era * 400;
	let doy = (153 * i64::from((m + 9) % 12) + 2) / 5 + i64::from(d) - 1;
	let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	era * 146_097 + doe - 719_468
}

/// A datetime's zone suffix as written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Zone {
	Utc,
	OffsetMinutes(i32),
}

impl std::fmt::Display for ShclDateTime {
	fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
		if let Some((y, m, d)) = self.date {
			write!(f, "{:04}-{:02}-{:02}", y, m, d)?;
			if self.time.is_some() {
				write!(f, "T")?;
			}
		}
		if let Some((h, mi, s)) = self.time {
			write!(f, "{:02}:{:02}", h, mi)?;
			if let Some(sec) = s {
				write!(f, ":{:02}", sec)?;
			}
			if let Some(fr) = &self.frac {
				write!(f, ".{}", fr)?;
			}
		}
		match self.zone {
			Some(Zone::Utc) => write!(f, "Z")?,
			Some(Zone::OffsetMinutes(off)) => {
				let sign = if off < 0 { '-' } else { '+' };
				let a = off.abs();
				write!(f, "{}{:02}:{:02}", sign, a / 60, a % 60)?;
			}
			None => {}
		}
		Ok(())
	}
}

// ---------------------------------------------------------------------------
// In-memory model
// ---------------------------------------------------------------------------
// One rule covers everything: a node is (field-name, value, children); nodes
// merge when (name, value) matches; empty values merge into the wrapper node.

#[derive(Debug, Clone, PartialEq)]
struct Element {
	text: String, // the logical string: quotes stripped, escapes resolved
	mark: Mark,
}

/// How an element was written. The writer keeps the author's quote kind
/// where the text allows it, and a backtick value stays in backticks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mark {
	Bare,
	Single,
	Double,
	Backtick,
}

impl Element {
	fn quoted(&self) -> bool {
		self.mark != Mark::Bare
	}
}

/// One whole-line comment held as trivia, plus whether a blank line preceded
/// it - so a blank between comment-only regions survives the round-trip
/// (blank runs collapse to one, same as nodes).
#[derive(Debug, Clone)]
struct Lead {
	text: String,
	blank_before: bool,
	// Levels deeper than the place it is emitted at. A comment written under
	// the one before it keeps that nesting, so a commented-out block comes
	// back in its shape.
	depth: usize,
	// The source line it was read from, for the save that keeps lines; 0 for
	// one a write made or moved.
	line: usize,
	// A misplaced line kept as written that the settle turned into a comment,
	// since as written it would bind. It is still the user's line, not a
	// comment, so clear_comments and comments leave it alone.
	kept: bool,
}

impl Lead {
	fn plain(text: String) -> Lead {
		Lead {
			text,
			blank_before: false,
			depth: 0,
			line: 0,
			kept: false,
		}
	}

	fn is_comment(&self) -> bool {
		self.text.starts_with('#') && !self.kept
	}

	/// A line the load kept as written, settled or not. The save gate
	/// counts these (design.md, Kept lines under edits).
	fn is_kept_line(&self) -> bool {
		self.kept || !self.text.starts_with('#')
	}
}

/// How many levels past its place a pending line is written: the place's
/// own level for a comment no deeper than `base`, the place's own indent,
/// which also starts a new chain; for a deeper one, one level under the
/// nearest comment before it whose indent its own extends, level with one it
/// equals, or at the place's level when there is none. `chain` holds those
/// comments' indents with their depths, innermost last. A field line kept
/// for its value or name goes by the same rule over `held`, the kept lines
/// before it: it holds its level on a reload, so it goes deeper only under
/// one of those, which a reload holds open for it. That line then takes its
/// place in `chain` at its own level, so a comment nests under it too
/// (2026100218185700). A misplaced line, which has its own indent, sits at
/// the place's level and leaves both alone.
fn comment_depth<'a>(
	chain: &mut Vec<(&'a str, usize)>,
	held: &mut Vec<(&'a str, usize)>,
	base: &str,
	text: &str,
	indent: &'a str,
) -> usize {
	if text.starts_with([' ', '\t']) {
		return 0;
	}
	if text.starts_with('#') {
		return chain_depth(chain, base, indent);
	}
	let depth = chain_depth(held, base, indent);
	// It is written at its own level, so on a reload nothing at that level
	// or deeper is left for a comment after it to nest under.
	while chain.last().is_some_and(|(ind, d)| {
		*d >= depth || !(indent.len() > ind.len() && indent.starts_with(*ind))
	}) {
		chain.pop();
	}
	chain.push((indent, depth));
	depth
}

/// comment_depth() over one chain.
fn chain_depth<'a>(chain: &mut Vec<(&'a str, usize)>, base: &str, indent: &'a str) -> usize {
	if !(indent.len() > base.len() && indent.starts_with(base)) {
		chain.clear();
		chain.push((indent, 0));
		return 0;
	}
	while let Some((ind, depth)) = chain.last() {
		if *ind == indent {
			return *depth;
		}
		if indent.len() > ind.len() && indent.starts_with(*ind) {
			break;
		}
		chain.pop();
	}
	let depth = chain.last().map_or(0, |(_, d)| d + 1);
	chain.push((indent, depth));
	depth
}

/// A pending line kept for what it says, not for where it sits: neither a
/// comment nor a misplaced line, which has its own indent.
fn is_field(text: &str) -> bool {
	!text.starts_with(['#', ' ', '\t'])
}

/// The last array line a node's level was opened by, and what the node had
/// before it: its leading line count, whether it had a trailing comment, and
/// its blank.
struct ArrayLine {
	line: usize,
	leads: usize,
	trailing: bool,
	blank: bool,
}

/// A pending whole-line comment during parse: text, source indent (used only
/// to decide whether it hangs on a deeper block), and the blank it consumed.
/// `ceiling` is the shortest incoming indent already checked against it: a
/// later check can only hang it from a shorter one, so a longer one skips it.
struct Pend<'a> {
	text: String,
	indent: &'a str,
	blank_before: bool,
	ceiling: usize,
	line: usize,
}

#[derive(Debug, Clone, PartialEq)]
enum Value {
	Empty,
	Cell(Element),       // one scalar
	Array(Vec<Element>), // `[a, b]` or a stacked list; `[]` is the empty array
	Raw(Box<RawVal>),    // boxed: the four fields would triple the enum's size
}

#[derive(Debug, Clone, PartialEq)]
struct RawVal {
	content: String,
	info: String,
	fence_char: u8,
	fence_len: usize,
}

impl Value {
	/// Human/display form; also what selectors match against (case-sensitive).
	/// An array is its canonical bracket form, so `x: 80` and `x: [80]` never
	/// display alike.
	fn display(&self) -> String {
		match self {
			Value::Empty => String::new(),
			Value::Cell(e) => e.text.clone(),
			Value::Array(els) => emit_array(els),
			Value::Raw(r) => r.content.clone(),
		}
	}
	fn is_empty(&self) -> bool {
		matches!(self, Value::Empty)
	}
}

#[derive(Debug, Clone)]
struct NodeData {
	name: String, // ASCII-folded to lower; non-ASCII never folds
	value: Value,
	children: Vec<usize>,
	parent: usize,
	line: usize,
	star_list: bool,  // value built from stacked "- " lines, and written that way
	star_mixed: bool, // mix of "- " and field children already diagnosed
	// Comment trivia, boxed off to the side: most nodes have none, and the
	// four empty containers were a third of every node.
	trivia: Option<Box<Trivia>>,
	// Blank-line grouping is the other half of hand-authored layout: set when
	// a blank line preceded this node's binding line (runs collapse to one).
	blank_before: bool,
	// This node has decided its `src` - set by the first source line whose
	// value the node holds, whether or not a string was worth keeping.
	src_set: bool,
	// Verbatim value text from the source line (after the colon, comment
	// stripped, trimmed) - what a read's `raw` hands back. None when the value
	// was synthesized (writer, stacked list, fence) OR when the spelling is
	// exactly the display form; raw falls back to the display form either way.
	src: Option<String>,
	// The name as the author wrote it (case unfolded, quotes and escapes
	// resolved) - what authored_name() hands back, via authored(). Merged
	// instances keep the first binding's spelling, like line() and comments.
	// Empty = written exactly like `name` (the overwhelmingly common case).
	name_src: String,
}

/// Comment trivia, verbatim from `#` to end of line. Never part of identity
/// or reads; merged instances concatenate leading, first trailing wins
/// (later ones demote to leading - a canonical line has room for one).
#[derive(Debug, Clone, Default)]
struct Trivia {
	leading: Vec<Lead>,
	trailing: String, // empty = none
	// Whole-line comments that followed this node's subtree at a deeper indent
	// than the next binding - they belong to this block, not the next node, so
	// a run trailing a block's last child stays put instead of re-attaching
	// dedented. Emitted after the subtree at this node's depth.
	after: Vec<Lead>,
	// Whole-line comments written inside this node's block when no bound child
	// could take them - a header whose children are all commented still owns
	// those lines. Emitted after the subtree one level deeper than this node.
	inside: Vec<Lead>,
	// Kept lines that sat among this node's stacked list elements, each with
	// the number of elements before it. They keep the list stacked on output,
	// so a line fixed by hand is still inside the list.
	among: Vec<(usize, Lead)>,
	// The comment trailing a stacked list item, with the item's index. Like
	// the lines among the items, they keep the list stacked on output.
	notes: Vec<(usize, String)>,
}

impl NodeData {
	fn leading(&self) -> &[Lead] {
		self.trivia.as_deref().map_or(&[], |t| &t.leading)
	}
	fn trailing(&self) -> &str {
		self.trivia.as_deref().map_or("", |t| &t.trailing)
	}
	fn after(&self) -> &[Lead] {
		self.trivia.as_deref().map_or(&[], |t| &t.after)
	}
	fn inside(&self) -> &[Lead] {
		self.trivia.as_deref().map_or(&[], |t| &t.inside)
	}
	fn among(&self) -> &[(usize, Lead)] {
		self.trivia.as_deref().map_or(&[], |t| &t.among)
	}
	fn notes(&self) -> &[(usize, String)] {
		self.trivia.as_deref().map_or(&[], |t| &t.notes)
	}
	fn triv_mut(&mut self) -> &mut Trivia {
		self.trivia.get_or_insert_with(Default::default)
	}
	/// The as-authored name spelling; empty name_src means "same as name".
	fn authored(&self) -> &str {
		if self.name_src.is_empty() {
			&self.name
		} else {
			&self.name_src
		}
	}
}

/// Store a name's authored spelling: the empty sentinel when it matches the
/// folded name, so the duplicate string never gets allocated.
fn spelled(name: &str, name_src: String) -> String {
	if name_src == name {
		String::new()
	} else {
		name_src
	}
}

/// True when a source value spelling is exactly the display form - the case
/// where `src` need not be stored, since raw's fallback reproduces it.
fn src_matches_display(v: &Value, s: &str) -> bool {
	match v {
		Value::Empty => s.is_empty(),
		Value::Raw(r) => s == r.content,
		Value::Cell(e) => s == e.text,
		Value::Array(_) => s == v.display(),
	}
}

/// A parsed SHCL document: the tree, its diagnostics, and its strictness level.
// Clone is a plain deep copy: the arena is index-based, so cloning the vector
// copies the whole tree with no reference to fix up.
#[derive(Debug, Clone)]
pub struct Document {
	arena: Vec<NodeData>,
	diags: Vec<Diagnostic>,
	strictness: Strictness,
	orphans: Vec<Lead>, // top-level comments after the last binding line
	// Lines or values parsing dropped that canonical output cannot re-emit
	// (bad indentation, an unusable selector, past the depth cap, ...).
	// Content-malformed lines are NOT counted - they are retained as trivia
	// and survive a save. lost_count() serves it; save_file() gates on it.
	lost: usize,
	// How many kept lines the document must still write: the load's, plus a
	// merged layer's, less those design.md's kept-lines table lets an edit
	// take. Fewer in the tree than this counts as lost.
	kept_owed: usize,
	// Built on the first path lookup and kept current by the writer (a new
	// child appends, a removed one unlinks); only a merge drops it. Without it
	// every lookup scans the parent's children, so a flat document read or
	// written key by key was quadratic.
	index: std::sync::OnceLock<Box<NameIndex>>,
	// Set only on the document a default form checks values against, never on
	// one a caller holds: set_value stops once the value is judged, so a probe
	// is never written. Built on the first default form that finds its path
	// already there.
	probe: bool,
	probe_doc: Option<Box<Document>>,
	// Holds a misplaced line kept as written, so edits have to settle it.
	kept: bool,
	// Holds an array line kept for the lines under it (E028), which an edit
	// can leave with none.
	arrays: bool,
	// Every list has been put in brackets by a merge, so the next one only
	// has the nodes it brings or visits to do.
	bracketed: bool,
	// What the last settle's kept lines were modeled through, and a sum of
	// it, so an edit that changes none of it skips the settle. Removing a
	// block above all of it goes unseen, which leaves `kept` set with no
	// such line left: the next check costs the same, and nothing is wrong.
	kept_near: Vec<(usize, usize)>,
	kept_sum: u64,
	// The parse's multi-line bindings, from the binding line to the last
	// line each took. Edits leave it alone; only a reparse reads it.
	ends: Vec<(usize, usize)>,
	// Each line counted in `lost`, once per count, when the parse was asked
	// for them. Only a reparse reads it.
	dropped: Vec<usize>,
	// The text a load kept for to_text_keep_lines(), and empty when that text
	// was already canonical, since the canonical form is then the one that
	// keeps its lines. A merge drops it: the layer's lines are not this text's.
	source: Option<String>,
}

/// The first child of each (parent, name), chained on to the next same-named
/// sibling, plus the chain tail so an append is O(1). A hash collision chains
/// a stranger in; the lookup checks the name, so the chain is only ever a
/// superset.
#[derive(Debug, Clone)]
struct NameIndex {
	first: U64Map<usize>,
	last: U64Map<usize>,
	next_same: Vec<usize>, // per node; NIL ends the chain
}

const NIL: usize = usize::MAX;

impl NameIndex {
	fn append(&mut self, key: u64, node: usize) {
		if self.next_same.len() <= node {
			self.next_same.resize(node + 1, NIL);
		}
		self.next_same[node] = NIL;
		match self.last.insert(key, node) {
			Some(prev) => self.next_same[prev] = node,
			None => {
				self.first.insert(key, node);
			}
		}
	}

	// Walks the chain to find the predecessor; a chain is one name's siblings.
	fn unlink(&mut self, key: u64, node: usize) {
		let Some(&head) = self.first.get(&key) else {
			return;
		};
		let next = self.next_same[node];
		if head == node {
			if next == NIL {
				self.first.remove(&key);
				self.last.remove(&key);
			} else {
				self.first.insert(key, next);
			}
		} else {
			let mut c = head;
			while c != NIL && self.next_same[c] != node {
				c = self.next_same[c];
			}
			if c == NIL {
				return;
			}
			self.next_same[c] = next;
			if next == NIL {
				self.last.insert(key, c);
			}
		}
		self.next_same[node] = NIL;
	}
}

fn name_key(parent: usize, name: &str) -> u64 {
	let mut h = Fnv::new();
	h.dec(parent);
	h.byte(0xFF);
	h.bytes(name.as_bytes());
	h.0
}

const ROOT: usize = 0;
// Stack entry for a binding line that was skipped: it still owns its indent
// level, so the lines written under it are skipped with it instead of
// re-parenting one level up.
const DEAD: usize = usize::MAX;
// Stack entry for a line whose indent matched no open level (E012): never a
// level a sibling can bind at, but deeper lines are still under it. It sits
// on top of the levels open before it without closing any of them.
const UNOPENED: usize = usize::MAX - 1;
// Stack entry for a field line refused for its value alone (E017, E019,
// E023, E025) or for a bare name that still reads (E014): it binds nothing,
// but its path is fine, so the first line that binds under it opens the path
// as `name:` would and binds there.
const LAZY: usize = usize::MAX - 2;

/// A LAZY level's line, for opening it: the stack entry it sits at, its
/// path, and how many pending lines go with it, its own included.
struct Lazy<'a> {
	at: usize,
	segs: Vec<Segment>,
	line: usize,
	indent: &'a str,
	pend: usize,
	depth: usize,
}

/// Merge a later instance into an earlier one under the in-file merge rule:
/// children and trivia move over, first trailing wins (a second demotes to a
/// leading line), first spelling stays. The caller drops the loser from the
/// parent's child list; it keeps its arena slot, unreferenced.
fn fold_node_into(arena: &mut [NodeData], survivor: usize, loser: usize) {
	let kids = std::mem::take(&mut arena[loser].children);
	for &k in &kids {
		arena[k].parent = survivor;
	}
	arena[survivor].children.extend(kids);
	if let Some(mut lt) = arena[loser].trivia.take() {
		let st = arena[survivor].triv_mut();
		st.leading.append(&mut lt.leading);
		if !lt.trailing.is_empty() {
			if st.trailing.is_empty() {
				st.trailing = std::mem::take(&mut lt.trailing);
			} else {
				st.leading
					.push(Lead::plain(std::mem::take(&mut lt.trailing)));
			}
		}
		st.after.append(&mut lt.after);
		st.inside.append(&mut lt.inside);
		st.among.append(&mut lt.among);
		st.among.sort_by_key(|a| a.0);
		st.notes.append(&mut lt.notes);
		st.notes.sort_by_key(|n| n.0);
	}
}

/// Where a reload files a block's comments, applied in place. A block's
/// inside comments are written after its last child's block, at that child's
/// level, so a reload files them as the last child's own. A child's comments
/// at its own level sit right above the next sibling, so a reload files them
/// as that sibling's leading ones, from the first one at that level on. The
/// load runs this once the tree is final; a merge, a new child and the
/// writer's fold run it where they change a child list, or the next step
/// comes out differently depending on whether the file was saved in between. The
/// text does not move. `from` is the first child whose leading list may
/// gain, so a new last child costs one pair; it cannot put a fence after an
/// empty binding either, so only a full pass looks for one.
fn settle_block(arena: &mut [NodeData], n: usize, from: usize) {
	let Some(&kid) = arena[n].children.last() else {
		return;
	};
	if from <= 1 {
		settle_fence_trailing(arena, n);
	}
	if let Some(t) = arena[n].trivia.as_deref_mut()
		&& !t.inside.is_empty()
	{
		let moved = std::mem::take(&mut t.inside);
		arena[kid].triv_mut().after.extend(moved);
	}
	for i in from.max(1)..arena[n].children.len() {
		let (prev, next) = (arena[n].children[i - 1], arena[n].children[i]);
		let Some(t) = arena[prev].trivia.as_deref_mut() else {
			continue;
		};
		let Some(at) = t.after.iter().position(|c| c.depth == 0) else {
			continue;
		};
		let mut moved = t.after.split_off(at);
		let nt = arena[next].triv_mut();
		moved.append(&mut nt.leading);
		nt.leading = moved;
	}
}

/// A raw block after an empty binding of its name is written with the fence on
/// the binding's line, where no comment can follow it, so the emitter writes
/// its trailing comment on a line of its own above, after the node's blank. A
/// reload files that line as a leading comment, so file it there now.
fn settle_fence_trailing(arena: &mut [NodeData], n: usize) {
	let fenced = |nd: &NodeData| matches!(nd.value, Value::Raw(_)) && !nd.trailing().is_empty();
	if !arena[n]
		.children
		.iter()
		.any(|&c| fenced(&arena[c]) || stacks(&arena[c]))
	{
		return;
	}
	let mut empties: HashMap<String, usize> = HashMap::new();
	let mut folded = Vec::new();
	for i in 0..arena[n].children.len() {
		let c = arena[n].children[i];
		let nd = &mut arena[c];
		if fenced(nd) && empties.contains_key(&nd.name) {
			trailing_to_leading(nd);
		} else if stacks(nd)
			&& let Some(&e) = empties.get(&nd.name)
		{
			if fold_list_into_empty(arena, e, c) {
				folded.push(c);
			}
		} else if nd.value.is_empty() {
			empties.entry(nd.name.clone()).or_insert(c);
		}
	}
	if !folded.is_empty() {
		arena[n].children.retain(|c| !folded.contains(c));
	}
}

/// A list after an empty binding of its name, which a stacked header would
/// join on a reload. In brackets when it can be. A list with fields under it
/// cannot, so it joins that binding here, as a reload joins it, when that
/// binding has no field the items would land after. True when it
/// joined, and the caller drops it from its parent's children.
fn fold_list_into_empty(arena: &mut [NodeData], empty: usize, list: usize) -> bool {
	unstack(&mut arena[list]);
	let e = &arena[empty];
	if !stacks(&arena[list])
		|| !e.value.is_empty()
		|| !e.children.is_empty()
		|| !e.after().is_empty()
	{
		return false;
	}
	arena[empty].value = std::mem::replace(&mut arena[list].value, Value::Empty);
	arena[empty].star_list = true;
	fold_node_into(arena, empty, list);
	true
}

/// Written stacked: a list the file wrote one `- ` item per line, kept that
/// way like an author's quotes, or one holding a kept line among its items,
/// a comment on one, or a field under it (E001), which in brackets would make
/// the array `E028`.
fn stacks(nd: &NodeData) -> bool {
	matches!(&nd.value, Value::Array(els) if !els.is_empty())
		&& (nd.star_list
			|| !nd.among().is_empty()
			|| !nd.notes().is_empty()
			|| !nd.children.is_empty())
}

/// A list after an empty binding of its name cannot be written stacked: its
/// bare header would merge into that binding on a reload. It goes in
/// brackets, and the lines among its elements and the comments on them go
/// above it, in order, where a reload files what sits there.
fn unstack(nd: &mut NodeData) {
	nd.star_list = false;
	if let Some(t) = nd.trivia.as_deref_mut() {
		let mut notes = t.notes.drain(..).peekable();
		for (at, l) in t.among.drain(..) {
			while let Some((_, n)) = notes.next_if(|n| n.0 < at) {
				t.leading.push(Lead::plain(n));
			}
			t.leading.push(l);
		}
		t.leading.extend(notes.map(|n| Lead::plain(n.1)));
	}
}

/// A merge writes a list in brackets. One with a field under it stays
/// stacked (E001), since in brackets it is E028.
fn bracket(nd: &mut NodeData) {
	if nd.children.is_empty() && (nd.star_list || nd.trivia.is_some()) {
		unstack(nd);
	}
}

/// The trailing comment becomes the last leading line, taking the node's blank
/// with it, which is the order the emitter writes them in.
fn trailing_to_leading(nd: &mut NodeData) {
	let blank_before = std::mem::take(&mut nd.blank_before);
	let t = nd.triv_mut();
	let text = std::mem::take(&mut t.trailing);
	t.leading.push(Lead {
		depth: 0,
		text,
		blank_before,
		line: 0,
		kept: false,
	});
}

/// The emitter drops a blank before the first thing it prints, so a document
/// that kept one there would not survive its own canonical form, and a merge
/// or a new first line - where it is no longer first - would place a blank
/// nobody wrote. Clear it wherever output starts.
fn settle_first_blank(arena: &mut [NodeData], orphans: &mut [Lead]) {
	if let Some(&first) = arena[ROOT].children.first() {
		let n = &mut arena[first];
		match n.trivia.as_mut().and_then(|t| t.leading.first_mut()) {
			Some(c) => c.blank_before = false,
			None => n.blank_before = false,
		}
	} else if let Some(c) = orphans.first_mut() {
		c.blank_before = false;
	}
}

/// Maximum nesting depth (levels below the document root), enforced at load
/// and by the Writer. Deeper lines are skipped with an `E016` error. The cap
/// is what keeps the recursive tree walks (emit, merge, clone) safely inside
/// every binding's stack, so a hostile or machine-generated document can make
/// a load fail but never crash the consumer.
pub const MAX_DEPTH: usize = 512;

/// How much of a file's own name the temporary file beside it borrows, in bytes.
const TMP_NAME_BYTES: usize = 64;

// ---------------------------------------------------------------------------
// Tokenizer - the one place the lexical rules live
// ---------------------------------------------------------------------------
//
// Every reading of a line's parts goes through `tokenize`: the parser's line
// dispatch, the path scanner behind every lookup and setter, the comment and
// comma splits, the element cap, the unterminated-quote check, `SetLiteral`
// and the CLI's `--set` split. Seven scanners used to have their own copy of
// these rules, and every scanner defect since July was two of them
// disagreeing. The rules, one sentence each:
//
// - A piece (a name, a selector body, a value element) is quoted only when
//   its first character is a quote and the next matching quote is the last
//   thing before the piece ends. A backtick quotes a value element the same
//   way, as a raw value. A backslash is plain text everywhere. A piece that
//   began with a quote it never closed is kept literally, and the parser
//   refuses its line (`E017`).
// - `◉NAME◉` escapes are read in bare and quoted value text, quoted names
//   and selector bodies, never in a backtick value, a bare name, a comment
//   or a raw block (`resolve_marks`).
// - `#` outside quotes and backticks opens a comment, wherever it sits.
// - A space, a tab and a carriage return are blanks: trimmed at a piece's
//   edge. In the middle of a bare piece they are whitespace, which the
//   parser refuses (`E025`).
// - A bare name is an ASCII letter, then ASCII letters, digits, `-` and `_`.
//   A file line's name that breaks only that rule still reads, up to the
//   separator, a dot, a bracket or a comment, and is marked `misspelled`
//   (`E014`). A `[` right after a name opens a selector, whose bare body
//   runs to the first `]`.
// - A value is split on unquoted commas, each piece trimmed. More than one
//   piece outside brackets is a bare comma, which the parser refuses
//   (`E026`).
// - A value that starts with `[` is a bracket array: its pieces run to the
//   `]` that closes it, and nothing but a comment may follow. A bare `[` or
//   `]` inside, an empty piece, or no `]` on the line is malformed, which the
//   parser refuses (`E019`). `[]` is the empty array.
//
// Under `Rules::V2` the tokenizer reads the 2.x spellings instead, for
// `migrate`: a backslash shields the next character in bare and single-quoted
// value text, a bare selector body still runs to its first `]`, a separator
// followed by `[` is the selector sugar, and an open quote swallows the rest
// of the line.

/// How a piece was quoted. `Open` is a piece that began with a quote and
/// never closed with the matching quote as its last character: the whole
/// piece is kept literally, quotes and all. `Backtick` is a raw value, read
/// as written: value elements only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Quote {
	None,
	Single,
	Double,
	Backtick,
	Open,
}

/// One piece of the text: byte offsets of its content. For a quoted piece
/// the quotes sit just outside the span; for an open or bare piece the span
/// is the trimmed text itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Piece {
	pub start: usize,
	pub end: usize,
	pub quote: Quote,
}

/// One path segment: its name, an optional `[selector]` body, and whether
/// the name was the bare `*` wildcard (lookups only).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SegTok {
	pub name: Piece,
	pub selector: Option<Piece>,
	pub star: bool,
}

/// The spans of one line, or of one lookup path. Nothing is copied: every
/// field is an offset into the text that was tokenized.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Tokens {
	pub segments: Vec<SegTok>,
	/// Offset of the separator (`:` on a line, `=` in `--set`); None when
	/// the path ran to the end of the text or into a comment.
	pub sep: Option<usize>,
	/// The value: everything after the separator up to the comment, trimmed.
	pub value: (usize, usize),
	/// The value's comma-separated pieces, empty ones included, each trimmed.
	/// For a bracket array, the pieces between the brackets.
	pub elements: Vec<Piece>,
	/// Offset of the `[` that opens a bracket array, when the value is one.
	pub array: Option<usize>,
	/// Where a bracket array stops being well formed, and why (`E019`).
	pub array_fault: Option<(usize, &'static str)>,
	/// Offset of the `#` that opens a trailing comment.
	pub comment: Option<usize>,
	/// Where the path stopped making sense, and why. A faulted line is
	/// malformed as a whole (`E014`).
	pub fault: Option<(usize, &'static str)>,
	/// Offset of the first bare name that breaks the spelling rule but still
	/// reads, such as `404` or `user name` (`E014`, with the level held open).
	pub misspelled: Option<usize>,
	/// The caller's element cap (0 = none): the scan stops as soon as the
	/// value holds more elements than this, so a capped parse never builds
	/// the array it is going to refuse. Kept across `tokenize` calls.
	pub cap: usize,
	/// True when the cap stopped the scan; `elements` is then incomplete.
	pub capped: bool,
}

impl Tokens {
	fn clear(&mut self) {
		self.segments.clear();
		self.sep = None;
		self.value = (0, 0);
		self.elements.clear();
		self.array = None;
		self.array_fault = None;
		self.comment = None;
		self.fault = None;
		self.misspelled = None;
		self.capped = false;
	}
	/// How many elements the value holds: a quoted piece counts even when
	/// empty (`""` is a real element), an empty bare slot does not.
	pub fn element_count(&self) -> usize {
		self.elements
			.iter()
			.filter(|p| p.quote != Quote::None || p.end > p.start)
			.count()
	}
}

/// Which spelling the tokenizer reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rules {
	/// The current rules, listed at the top of this section.
	Current,
	/// The 2.x rules, for `migrate` only.
	V2,
}

/// A blank: space, tab, or a carriage return, which is trimmed wherever a
/// blank is and content in the middle of a piece.
fn is_wsp_byte(b: u8) -> bool {
	b == b' ' || b == b'\t' || b == b'\r'
}

fn is_bare_name_byte(b: u8) -> bool {
	b.is_ascii_alphanumeric() || b == b'-' || b == b'_'
}

fn skip_wsp(s: &[u8], pos: &mut usize) {
	while *pos < s.len() && is_wsp_byte(s[*pos]) {
		*pos += 1;
	}
}

/// Byte length of the UTF-8 character that starts with `b`. The scan only
/// ever compares against ASCII structure characters, which UTF-8 guarantees
/// cannot appear inside a multibyte sequence, so it advances by whole
/// characters and every offset it records is a character boundary.
fn utf8_len(b: u8) -> usize {
	match b {
		0..=0x7F => 1,
		0xC0..=0xDF => 2,
		0xE0..=0xEF => 3,
		_ => 4,
	}
}

/// Where a file line's bare name that breaks the spelling rule stops.
fn name_stop(b: u8, sep: u8) -> bool {
	b == sep
		|| matches!(
			b,
			b'.' | b'[' | b']' | b'#' | b',' | b'"' | b'\'' | b'`' | b'\n'
		)
}

/// Offset of the quote that closes the one at `pos`, or None. 2.x read a
/// backslash as an escape inside quotes; now it is text.
fn quote_close(s: &[u8], pos: usize, rules: Rules) -> Option<usize> {
	let q = s[pos];
	let escapes = rules == Rules::V2;
	let mut i = pos + 1;
	while i < s.len() {
		if escapes && s[i] == b'\\' && i + 1 < s.len() {
			i += 1 + utf8_len(s[i + 1]);
			continue;
		}
		if s[i] == q {
			return Some(i);
		}
		i += utf8_len(s[i]);
	}
	None
}

/// True when the byte at `i` opens a comment. Being outside quotes is the
/// caller's business.
fn comment_at(s: &[u8], i: usize) -> bool {
	s[i] == b'#'
}

/// One piece from `pos`: a value element up to an unquoted comma or comment,
/// or a selector body up to an unquoted `]` (`term`). Returns the trimmed
/// piece and the offset of what ended it: the terminator, a comment's `#`,
/// or the end of the text. `comments` is false only for a selector body in a
/// lookup path, where `[#N]` is the index spelling. In a bracket array
/// (`array`) the `]` that closes it ends a value element too.
fn scan_piece(
	s: &[u8],
	mut pos: usize,
	term: u8,
	rules: Rules,
	comments: bool,
	array: bool,
) -> (Piece, usize) {
	skip_wsp(s, &mut pos);
	let start = pos;
	let mut quote = Quote::None;
	// A backtick quotes a raw value element. 2.x had none, a selector body
	// takes none, and a run of three opens a raw block instead.
	let tick =
		rules == Rules::Current && term == b',' && !s[pos.min(s.len())..].starts_with(b"```");
	if pos < s.len() && (s[pos] == b'"' || s[pos] == b'\'' || (tick && s[pos] == b'`')) {
		match quote_close(s, pos, rules) {
			Some(close) => {
				// A value piece may also end at a comment or the line end;
				// a selector body ends at its bracket and nowhere else.
				let mut i = close + 1;
				skip_wsp(s, &mut i);
				let ended = if i < s.len() {
					s[i] == term || (array && s[i] == b']') || (term == b',' && comment_at(s, i))
				} else {
					term == b','
				};
				if ended {
					let q = match s[pos] {
						b'"' => Quote::Double,
						b'`' => Quote::Backtick,
						_ => Quote::Single,
					};
					return (
						Piece {
							start: pos + 1,
							end: close,
							quote: q,
						},
						i,
					);
				}
				// Text after the closing quote: the quote was a character
				// after all, and the scan restarts at it. 2.x went on from
				// the close with the quotes read as a pair.
				quote = Quote::Open;
				if rules == Rules::V2 {
					pos = close + 1;
				}
			}
			None => {
				quote = Quote::Open;
				if rules == Rules::V2 {
					// 2.x: an open quote swallowed the rest of the line.
					let mut end = s.len();
					while end > start && is_wsp_byte(s[end - 1]) {
						end -= 1;
					}
					return (Piece { start, end, quote }, s.len());
				}
			}
		}
	}
	// 2.x shielded a backslash in value text only. A bare selector body ran to
	// its first `]`, the same as now, so shielding one here would hide the `]`.
	// Now a backslash is text.
	let shield = rules == Rules::V2 && term == b',';
	let mut content_end = start;
	while pos < s.len() {
		let b = s[pos];
		if shield && b == b'\\' && pos + 1 < s.len() {
			pos += 1 + utf8_len(s[pos + 1]);
			content_end = pos.min(s.len());
			continue;
		}
		if b == term || (array && b == b']') || (comments && comment_at(s, pos)) {
			break;
		}
		pos += utf8_len(b);
		if !is_wsp_byte(b) {
			content_end = pos.min(s.len());
		}
	}
	// 2.x judged a value piece quoted by its shape after the scan: a quote at
	// both ends, the last one not escaped, however many closes sat between. A
	// selector body had to close right before its `]`, or the line was E014.
	if rules == Rules::V2
		&& term == b','
		&& quote == Quote::Open
		&& content_end - start >= 2
		&& s[content_end - 1] == s[start]
		&& s[start..content_end - 1]
			.iter()
			.rev()
			.take_while(|&&b| b == b'\\')
			.count() % 2
			== 0
	{
		let q = if s[start] == b'"' {
			Quote::Double
		} else {
			Quote::Single
		};
		return (
			Piece {
				start: start + 1,
				end: content_end - 1,
				quote: q,
			},
			pos.min(s.len()),
		);
	}
	(
		Piece {
			start,
			end: content_end,
			quote,
		},
		pos.min(s.len()),
	)
}

/// The value half: everything from `from` on, split into pieces, with the
/// comment found on the way.
pub fn tokenize_value(text: &str, from: usize, rules: Rules, out: &mut Tokens) {
	out.clear();
	scan_value(text, from, rules, out);
}

fn scan_value(text: &str, from: usize, rules: Rules, out: &mut Tokens) {
	let s = text.as_bytes();
	let mut pos = from;
	skip_wsp(s, &mut pos);
	if rules == Rules::Current && pos < s.len() && s[pos] == b'[' {
		scan_array(text, from, pos, out);
		return;
	}
	pos = from;
	let stop_at;
	let mut count = 0usize;
	loop {
		let (piece, stop) = scan_piece(s, pos, b',', rules, true, false);
		out.elements.push(piece);
		if piece.quote != Quote::None || piece.end > piece.start {
			count += 1;
			if out.cap != 0 && count > out.cap {
				out.capped = true;
				out.value = (from, from);
				return;
			}
		}
		if stop < s.len() && s[stop] == b',' {
			pos = stop + 1;
			continue;
		}
		if stop < s.len() {
			out.comment = Some(stop);
		}
		stop_at = stop;
		break;
	}
	let mut a = from;
	skip_wsp(s, &mut a);
	let mut b = stop_at;
	while b > a && is_wsp_byte(s[b - 1]) {
		b -= 1;
	}
	out.value = (a.min(b), b);
	if let Some(last) = out.elements.last_mut()
		&& !matches!(last.quote, Quote::Single | Quote::Double | Quote::Backtick)
		&& last.end > b
	{
		last.end = b.max(last.start);
	}
}

/// A bracket array from the `[` at `open`: its pieces, each up to an
/// unquoted comma or the `]` that closes it, then nothing but a comment. A
/// fault is noted and the scan goes on, so the comment is still found. Past
/// the element cap the pieces are no longer kept, but the scan still runs to
/// the end, since a malformed array is refused for that and never reaches the
/// cap, which refuses only a line that would bind.
fn scan_array(text: &str, from: usize, open: usize, out: &mut Tokens) {
	let s = text.as_bytes();
	out.array = Some(open);
	let mut pos = open + 1;
	let mut count = 0usize;
	let mut close = None;
	let stop_at = loop {
		let (piece, stop) = scan_piece(s, pos, b',', Rules::Current, true, true);
		if !out.capped {
			out.elements.push(piece);
		}
		if piece.quote == Quote::None && piece.end == piece.start {
			// `[]`, blanks or not, is the empty array; any other empty piece
			// is a slip.
			let only = out.elements.len() == 1 && stop < s.len() && s[stop] == b']';
			if !only {
				out.array_fault
					.get_or_insert((piece.start, "an empty element"));
			}
		} else {
			count += 1;
			if out.cap != 0 && count > out.cap {
				out.capped = true;
			}
			if piece.quote == Quote::None
				&& let Some(k) = s[piece.start..piece.end].iter().position(|&b| b == b'[')
			{
				out.array_fault
					.get_or_insert((piece.start + k, "a '[' inside an array"));
			}
		}
		if stop < s.len() && s[stop] == b',' {
			pos = stop + 1;
			continue;
		}
		if stop < s.len() && s[stop] == b']' {
			close = Some(stop);
		}
		break stop;
	};
	let mut end = stop_at;
	match close {
		Some(at) => {
			let mut after = at + 1;
			skip_wsp(s, &mut after);
			end = after;
			if after < s.len() && !comment_at(s, after) {
				out.array_fault.get_or_insert((after, "text after ']'"));
				// The comment past the stray text, found the way a value finds it.
				loop {
					let (_, stop) = scan_piece(s, after, b',', Rules::Current, true, false);
					if stop < s.len() && s[stop] == b',' {
						after = stop + 1;
						continue;
					}
					end = stop;
					break;
				}
			}
		}
		// The one fault a reader can see from the outside, so it wins.
		None => out.array_fault = Some((open, "no closing ']' on the line")),
	}
	if out.capped {
		out.value = (from, from);
		return;
	}
	if end < s.len() {
		out.comment = Some(end);
	}
	if let [only] = out.elements.as_slice()
		&& only.quote == Quote::None
		&& only.end == only.start
	{
		out.elements.clear();
	}
	let mut b = end;
	while b > open && is_wsp_byte(s[b - 1]) {
		b -= 1;
	}
	out.value = (open, b);
}

/// Tokenize one line (`sep` = `b':'`) or one lookup path (`path`: the bare
/// `*` name wildcard is admitted, and a `#` in a selector body is the `[#N]`
/// index rather than a comment); the CLI's `--set` passes `b'='`. `out` is
/// cleared and reused, so a parse allocates once per document rather than
/// once per line. `text` is the line after its indent, or the path.
pub fn tokenize(text: &str, sep: u8, path: bool, rules: Rules, out: &mut Tokens) {
	out.clear();
	let s = text.as_bytes();
	let mut pos = 0usize;
	loop {
		skip_wsp(s, &mut pos);
		if pos >= s.len() {
			out.fault = Some((pos, "expected a field name"));
			return;
		}
		let mut star = false;
		let name = if s[pos] == b'"' || s[pos] == b'\'' {
			let Some(close) = quote_close(s, pos, rules) else {
				out.fault = Some((pos, "unterminated quote in a field name"));
				return;
			};
			let q = if s[pos] == b'"' {
				Quote::Double
			} else {
				Quote::Single
			};
			let piece = Piece {
				start: pos + 1,
				end: close,
				quote: q,
			};
			pos = close + 1;
			piece
		} else if path && s[pos] == b'*' {
			star = true;
			pos += 1;
			Piece {
				start: pos - 1,
				end: pos,
				quote: Quote::None,
			}
		} else {
			let start = pos;
			while pos < s.len() && is_bare_name_byte(s[pos]) {
				pos += 1;
			}
			// A file line's name that breaks only the spelling rule still
			// reads, so the lines under it can load under it (E014). A lookup
			// path takes the old bare run, any first character. A name led by
			// a byte order mark does not read: at the start of a file the
			// load strips the mark, so the line would bind as something else.
			// One led by a `*` is a list item's line, which never gets here.
			if !path
				&& rules == Rules::Current
				&& !s[start..].starts_with("\u{feff}".as_bytes())
				&& s[start] != b'*'
			{
				let mut end = pos;
				while pos < s.len() && !name_stop(s[pos], sep) {
					let b = s[pos];
					pos = (pos + utf8_len(b)).min(s.len());
					if !is_wsp_byte(b) {
						end = pos;
					}
				}
				pos = end;
				if end > start
					&& (!s[start].is_ascii_alphabetic()
						|| !s[start..end].iter().all(|&b| is_bare_name_byte(b)))
				{
					out.misspelled.get_or_insert(start);
				}
			}
			if pos == start {
				out.fault = Some((pos, "expected a field name"));
				return;
			}
			Piece {
				start,
				end: pos,
				quote: Quote::None,
			}
		};
		skip_wsp(s, &mut pos);
		let mut selector = None;
		let mut open = (pos < s.len() && s[pos] == b'[').then_some(pos);
		if open.is_none() && rules == Rules::V2 && pos < s.len() && s[pos] == sep {
			let mut q = pos + 1;
			skip_wsp(s, &mut q);
			if q < s.len() && s[q] == b'[' {
				open = Some(q);
			}
		}
		if let Some(at) = open {
			if star {
				out.fault = Some((at, "selector on a name wildcard"));
				return;
			}
			let (piece, stop) = scan_piece(s, at + 1, b']', rules, !path, false);
			if stop >= s.len() || s[stop] != b']' {
				out.fault = Some((at, "unterminated selector"));
				return;
			}
			if piece.end == piece.start && piece.quote == Quote::None {
				out.fault = Some((at, "empty selector"));
				return;
			}
			if piece.quote == Quote::Open && rules == Rules::V2 {
				out.fault = Some((at, "unterminated quote in a selector"));
				return;
			}
			selector = Some(piece);
			pos = stop + 1;
			skip_wsp(s, &mut pos);
		}
		out.segments.push(SegTok {
			name,
			selector,
			star,
		});
		if pos >= s.len() {
			return;
		}
		let b = s[pos];
		if b == b'.' {
			pos += 1;
			continue;
		}
		if b == sep {
			out.sep = Some(pos);
			scan_value(text, pos + 1, rules, out);
			return;
		}
		if comment_at(s, pos) {
			out.comment = Some(pos);
			return;
		}
		out.fault = Some((pos, "unexpected character after the path"));
		return;
	}
}

/// Whether a piece's `◉` escapes are read: bare and quoted text. A backtick
/// value is raw, and an open piece is refused before anything reads it.
fn decodes(p: &Piece) -> bool {
	matches!(p.quote, Quote::None | Quote::Single | Quote::Double)
}

/// The text of a piece as the reader sees it: escapes applied, except in a
/// backtick value, which is as written. A bare field name takes no escapes
/// either; `path_of` reads those.
fn piece_text(p: &Piece, text: &str) -> String {
	let raw = &text[p.start..p.end];
	if decodes(p) && raw.contains(ESCAPE_MARK) {
		resolve_marks(raw).unwrap_or_else(|_| raw.to_string())
	} else {
		raw.to_string()
	}
}

/// True when a piece reads as this exact text, without building it.
fn piece_is(p: &Piece, text: &str, want: &str) -> bool {
	let raw = &text[p.start..p.end];
	if decodes(p) && raw.contains(ESCAPE_MARK) {
		resolve_marks(raw).is_ok_and(|t| t == want)
	} else {
		raw == want
	}
}

/// The element a value piece makes, or None for an empty bare slot (dropped,
/// never an error).
fn element_of(p: &Piece, text: &str) -> Option<Element> {
	if p.quote == Quote::None && p.end == p.start {
		return None;
	}
	Some(Element {
		text: piece_text(p, text),
		mark: match p.quote {
			Quote::Single => Mark::Single,
			Quote::Double => Mark::Double,
			Quote::Backtick => Mark::Backtick,
			Quote::None | Quote::Open => Mark::Bare,
		},
	})
}

/// The value the tokenized pieces give: an array for a bracket array, else
/// the one element, or Empty. A second piece outside brackets is a bare
/// comma, which every caller refuses first (`E026`).
fn cell_of_tokens(tok: &Tokens, text: &str) -> Value {
	if tok.array.is_some() {
		return Value::Array(
			tok.elements
				.iter()
				.filter_map(|p| element_of(p, text))
				.collect(),
		);
	}
	match tok.elements.iter().find_map(|p| element_of(p, text)) {
		Some(e) => Value::Cell(e),
		None => Value::Empty,
	}
}

/// Folds A-Z only; non-ASCII passes through untouched. Borrowed when there is
/// nothing to fold, the way piece_text borrows when there is nothing to resolve.
fn fold_name(s: &str) -> std::borrow::Cow<'_, str> {
	if s.bytes().any(|b| b.is_ascii_uppercase()) {
		std::borrow::Cow::Owned(s.to_ascii_lowercase())
	} else {
		std::borrow::Cow::Borrowed(s)
	}
}

/// The grammar's `wsp`: a space, a tab or a carriage return. The parser trims
/// with this and nothing wider - a no-break space or a line separator after a
/// value is content, and a Unicode trim used to delete it with no diagnostic.
fn is_wsp(c: char) -> bool {
	c == ' ' || c == '\t' || c == '\r'
}

fn trim_wsp(s: &str) -> &str {
	s.trim_matches(is_wsp)
}

fn trim_wsp_end(s: &str) -> &str {
	s.trim_end_matches(is_wsp)
}

/// Value text for a diagnostic message: line breaks and tabs escaped, so one
/// diagnostic is one line. A raw block's body is the value that made this
/// necessary - it contains its own newlines.
fn one_line(s: &str) -> String {
	s.replace('\\', "\\\\")
		.replace('\n', "\\n")
		.replace('\r', "\\r")
		.replace('\t', "\\t")
}

/// Schema text for a diagnostic or a generated comment: a path or a type as the
/// schema wrote it, with a line break written `\n`, so one diagnostic stays one
/// line. Only the break is escaped, so a path reads the way it was written.
fn schema_text(s: &str) -> String {
	s.replace('\n', "\\n")
}

/// The 2.x escape reading, for `migrate`: `\t`, `\n`, `\\`, `\"` and `\'`,
/// with any other pair kept as written.
fn apply_escapes_v2(s: &str) -> String {
	let mut out = String::with_capacity(s.len());
	let mut it = s.chars();
	while let Some(c) = it.next() {
		if c != '\\' {
			out.push(c);
			continue;
		}
		match it.next() {
			Some('t') => out.push('\t'),
			Some('n') => out.push('\n'),
			Some('\\') => out.push('\\'),
			Some('"') => out.push('"'),
			Some('\'') => out.push('\''),
			Some(other) => {
				out.push('\\');
				out.push(other);
			}
			None => out.push('\\'),
		}
	}
	out
}

/// The text of a piece with its `◉NAME◉` escapes resolved. The marks pair up
/// left to right, and the text between each pair must be a name on the list
/// or a code point. Err is the message for the first one that is not
/// (`E023`).
fn resolve_marks(raw: &str) -> Result<String, String> {
	let mut out = String::with_capacity(raw.len());
	let mut rest = raw;
	while let Some(at) = rest.find(ESCAPE_MARK) {
		out.push_str(&rest[..at]);
		let after = &rest[at + ESCAPE_MARK.len_utf8()..];
		let Some(close) = after.find(ESCAPE_MARK) else {
			return Err(format!(
				"a '{m}' with no partner; an escape is {m}NAME{m}, and a real {m} is {m}ESCAPE_CHAR{m}",
				m = ESCAPE_MARK
			));
		};
		let name = &after[..close];
		match escape_text(name) {
			Ok(t) => out.push_str(&t),
			Err(why) => return Err(why),
		}
		rest = &after[close + ESCAPE_MARK.len_utf8()..];
	}
	out.push_str(rest);
	Ok(out)
}

/// The text one escape name stands for: a name from the list, either case,
/// or a code point prefix and one to six hex digits.
fn escape_text(name: &str) -> Result<std::borrow::Cow<'static, str>, String> {
	let shown = || format!("{m}{}{m}", one_line(name), m = ESCAPE_MARK);
	if !name.is_empty()
		&& name
			.bytes()
			.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'+'))
	{
		if let Some((_, text)) = ESCAPE_NAMES
			.iter()
			.find(|(n, _)| n.eq_ignore_ascii_case(name))
		{
			return Ok(std::borrow::Cow::Borrowed(text));
		}
		for prefix in CODE_PREFIXES {
			let Some(head) = name.get(..prefix.len()) else {
				continue;
			};
			let digits = &name[prefix.len()..];
			if !head.eq_ignore_ascii_case(prefix)
				|| digits.is_empty()
				|| digits.len() > 6
				|| !digits.bytes().all(|b| b.is_ascii_hexdigit())
			{
				continue;
			}
			return u32::from_str_radix(digits, 16)
				.ok()
				.and_then(char::from_u32)
				.map(|c| std::borrow::Cow::Owned(c.to_string()))
				.ok_or_else(|| format!("escape '{}' names no Unicode character", shown()));
		}
	}
	Err(format!(
		"unknown escape '{}'; an escape is a name from the escape list, and a real {m} is {m}ESCAPE_CHAR{m}",
		shown(),
		m = ESCAPE_MARK
	))
}

// gen-escapes.py: begin
// Generated from Unicode 18.0 by cicd/utility/gen-escapes.py. Edit the script, not this block.
#[rustfmt::skip]
const INVISIBLE: [(u32, u32); 21] = [
	(0x0000, 0x0008),
	(0x000B, 0x001F),
	(0x007F, 0x009F),
	(0x00AD, 0x00AD),
	(0x034F, 0x034F),
	(0x061C, 0x061C),
	(0x115F, 0x1160),
	(0x17B4, 0x17B5),
	(0x180B, 0x180F),
	(0x200B, 0x200B),
	(0x200E, 0x200F),
	(0x2028, 0x202E),
	(0x2060, 0x206F),
	(0x3164, 0x3164),
	(0xFE00, 0xFE0F),
	(0xFEFF, 0xFEFF),
	(0xFFA0, 0xFFA0),
	(0xFFF0, 0xFFFB),
	(0x1BCA0, 0x1BCA3),
	(0x1D173, 0x1D17A),
	(0xE0000, 0xE0FFF),
];
#[rustfmt::skip]
const SELECTORS: [(u32, u32); 4] = [
	(0x180B, 0x180D),
	(0x180F, 0x180F),
	(0xFE00, 0xFE0F),
	(0xE0100, 0xE01EF),
];
#[rustfmt::skip]
const WHITE_SPACE: [(u32, u32); 10] = [
	(0x0009, 0x000D),
	(0x0020, 0x0020),
	(0x0085, 0x0085),
	(0x00A0, 0x00A0),
	(0x1680, 0x1680),
	(0x2000, 0x200A),
	(0x2028, 0x2029),
	(0x202F, 0x202F),
	(0x205F, 0x205F),
	(0x3000, 0x3000),
];
const ESCAPE_MARK: char = '\u{25C9}';
#[rustfmt::skip]
const ESCAPE_NAMES: [(&str, &str); 44] = [
	("NUL", "\u{0}"),
	("NULL", "\u{0}"),
	("BEL", "\u{7}"),
	("BELL", "\u{7}"),
	("BACKSPACE", "\u{8}"),
	("BS", "\u{8}"),
	("TAB", "\u{9}"),
	("HT", "\u{9}"),
	("HORIZONTAL_TAB", "\u{9}"),
	("NEWLINE", "\u{A}"),
	("LF", "\u{A}"),
	("LINEFEED", "\u{A}"),
	("LINE_FEED", "\u{A}"),
	("NEW_LINE", "\u{A}"),
	("VT", "\u{B}"),
	("VERTICAL_TAB", "\u{B}"),
	("VERTICALTAB", "\u{B}"),
	("FF", "\u{C}"),
	("FORM_FEED", "\u{C}"),
	("FORMFEED", "\u{C}"),
	("CR", "\u{D}"),
	("CARRIAGERETURN", "\u{D}"),
	("CARRIAGE_RETURN", "\u{D}"),
	("CRLF", "\u{D}\u{A}"),
	("CARRIAGERETURN_LINEFEED", "\u{D}\u{A}"),
	("CARRIAGE_RETURN_LINE_FEED", "\u{D}\u{A}"),
	("ESC", "\u{1B}"),
	("ESCAPE", "\u{1B}"),
	("DEL", "\u{7F}"),
	("DELETE", "\u{7F}"),
	("SPACE", "\u{20}"),
	("SINGLE_QUOTE", "\u{27}"),
	("SQUOTE", "\u{27}"),
	("S_QUOTE", "\u{27}"),
	("SINGLEQUOTE", "\u{27}"),
	("DOUBLE_QUOTE", "\u{22}"),
	("DQUOTE", "\u{22}"),
	("D_QUOTE", "\u{22}"),
	("DOUBLEQUOTE", "\u{22}"),
	("BACK_TICK", "\u{60}"),
	("BACKTICK", "\u{60}"),
	("TICK", "\u{60}"),
	("ESCAPE_CHAR", "\u{25C9}"),
	("FISHEYE", "\u{25C9}"),
];
#[rustfmt::skip]
const CODE_PREFIXES: [&str; 8] = [
	"U+",
	"UNICODE+",
	"UNICODE-",
	"UNICODE_",
	"UNICODE",
	"U-",
	"U_",
	"U",
];
// gen-escapes.py: end

/// Unicode's White_Space, which a bare value or selector body cannot hold.
fn white_space(c: char) -> bool {
	in_ranges(&WHITE_SPACE, c)
}

/// Characters canonical output writes as an escape, so a reader of the
/// file sees every character that is there: the controls,
/// the line and paragraph separators, the interlinear annotation marks, and
/// what Unicode calls default-ignorable, such as zero-width spaces, direction
/// marks and tag characters. The zero-width joiner and non-joiner are not in
/// the list, since emoji and several scripts need them, and `invisible_at`
/// keeps two more kinds where text needs them.
fn invisible(c: char) -> bool {
	!(' '..='~').contains(&c) && in_ranges(&INVISIBLE, c)
}

fn in_ranges(ranges: &[(u32, u32)], c: char) -> bool {
	let c = c as u32;
	ranges.iter().take_while(|r| r.0 <= c).any(|r| c <= r.1)
}

/// Whether `c`, the character at byte `i` of `t`, is written as an escape. A
/// variation selector stays as written directly after a visible character,
/// and the tags of a subdivision flag stay too; anywhere else they hide text.
fn invisible_at(t: &str, i: usize, c: char) -> bool {
	if !invisible(c) {
		return false;
	}
	if in_ranges(&SELECTORS, c) {
		return !t[..i].chars().next_back().is_some_and(selector_base);
	}
	if ('\u{E0020}'..='\u{E007F}').contains(&c) {
		return !flag_tag(t, i);
	}
	true
}

/// A character a variation selector can modify: one written as itself that
/// is not a blank or a joiner. Another selector is not one, so a run of them
/// cannot contain hidden text.
fn selector_base(c: char) -> bool {
	c > ' ' && c != '\u{200C}' && c != '\u{200D}' && !invisible(c)
}

/// Whether the tag at byte `i` of `t` is part of a subdivision flag, as UTS #51
/// defines one: U+1F3F4, three to seven tag digits or lowercase tag letters,
/// and the cancel tag.
fn flag_tag(t: &str, i: usize) -> bool {
	let spec = |c: char| matches!(c, '\u{E0030}'..='\u{E0039}' | '\u{E0061}'..='\u{E007A}');
	let mut start = i;
	let mut count = 0;
	for c in t[..i].chars().rev() {
		if !spec(c) {
			break;
		}
		count += 1;
		if count > 7 {
			return false;
		}
		start -= c.len_utf8();
	}
	if !t[..start].ends_with('\u{1F3F4}') {
		return false;
	}
	count = 0;
	for c in t[start..].chars() {
		if !spec(c) {
			return c == '\u{E007F}' && count >= 3;
		}
		count += 1;
		if count > 7 {
			return false;
		}
	}
	false
}

/// A character the writer escapes: by its first name when the list has one,
/// otherwise as a code point with at least four hex digits.
fn push_escape(out: &mut String, c: char) {
	use std::fmt::Write;
	let mut buf = [0u8; 4];
	let one: &str = c.encode_utf8(&mut buf);
	out.push(ESCAPE_MARK);
	match ESCAPE_NAMES.iter().find(|(_, text)| *text == one) {
		Some((name, _)) => out.push_str(name),
		None => {
			let _ = write!(out, "{}{:04X}", CODE_PREFIXES[0], c as u32);
		}
	}
	out.push(ESCAPE_MARK);
}

/// The predicate a `[value]` selector matches with: the display form, which
/// is built from logical strings, so `["q\"uote"]` finds `'q"uote'` - a
/// logical-string match, not spelling against spelling.
fn disp_key(v: &Value) -> String {
	v.display()
}

/// The single-element restriction a QUOTED `[value]` selector adds on top of
/// the display match: quoting selects the scalar spelling only.
fn single_scalar(v: &Value) -> bool {
	matches!(v, Value::Cell(_))
}

// FNV-1a, fed the same byte sequence the key strings would contain - the
// accelerator maps key on a u64 and verify hits against the arena, so the
// strings themselves never get built. The hash only has to be stable within
// one parse, not injective; a collision just chains in the slot.
struct Fnv(u64);

impl Fnv {
	fn new() -> Fnv {
		Fnv(0xcbf2_9ce4_8422_2325)
	}
	fn byte(&mut self, b: u8) {
		self.0 = (self.0 ^ u64::from(b)).wrapping_mul(0x100_0000_01b3);
	}
	fn bytes(&mut self, s: &[u8]) {
		for &b in s {
			self.byte(b);
		}
	}
	/// A length prefix in decimal, written without allocating.
	fn dec(&mut self, mut n: usize) {
		let mut buf = [0u8; 20];
		let mut i = buf.len();
		loop {
			i -= 1;
			buf[i] = b'0' + (n % 10) as u8;
			n /= 10;
			if n == 0 {
				break;
			}
		}
		self.bytes(&buf[i..]);
	}
}

/// Hasher for maps keyed on an Fnv value, which is a hash already, so running
/// it through SipHash again is wasted work. Fnv's low bits are its weak ones -
/// a changed input bit only reaches the bits above it - and the table picks a
/// bucket from the low bits, so the top half is folded down.
#[derive(Default, Clone, Copy)]
struct PreHashed(u64);

impl Hasher for PreHashed {
	fn finish(&self) -> u64 {
		self.0
	}
	fn write(&mut self, bytes: &[u8]) {
		for &b in bytes {
			self.0 = (self.0 ^ u64::from(b)).wrapping_mul(0x100_0000_01b3);
		}
	}
	fn write_u64(&mut self, x: u64) {
		self.0 = x ^ (x >> 32);
	}
}

type U64Map<V> = HashMap<u64, V, BuildHasherDefault<PreHashed>>;

/// Hash of the (name, merge-key) pair: nodes with equal pairs collapse into
/// one. The key is 'e', or each cell element (and the raw info-string)
/// length-prefixed so the sequence is injective - a bare NUL separator lets
/// `[a, b]` collide with the single element "a\0b". Elements are the resolved
/// strings, so two spellings of one string are one instance: names have
/// followed that rule since 2.0, and a `[value]` selector matches on the
/// resolved text already. Info-string is part of identity (a `sql` and a
/// `python` block are different values even with equal bodies); fence style
/// is not.
fn merge_hash(name: &str, v: &Value) -> u64 {
	let mut h = Fnv::new();
	h.bytes(name.as_bytes());
	h.byte(0xFF); // separator; equality still verifies both parts
	match v {
		Value::Empty => h.byte(b'e'),
		Value::Cell(e) => {
			h.bytes(b"c:");
			h.dec(e.text.len());
			h.byte(b':');
			h.bytes(e.text.as_bytes());
		}
		// Brackets are part of the value, so `[80]` is not the scalar 80.
		Value::Array(els) => {
			h.bytes(b"a:");
			for e in els {
				h.dec(e.text.len());
				h.byte(b':');
				h.bytes(e.text.as_bytes());
			}
		}
		Value::Raw(r) => {
			h.bytes(b"r:");
			h.dec(r.info.len());
			h.byte(b':');
			h.bytes(r.info.as_bytes());
			h.bytes(r.content.as_bytes());
		}
	}
	h.0
}

/// Hash of the value's merge key alone (no name part).
fn value_hash(v: &Value) -> u64 {
	merge_hash("", v)
}

/// The exact (name, merge-key) equality a hashed hit is verified with -
/// compares what the two key strings would hold, element by element.
fn merge_eq(name_a: &str, va: &Value, name_b: &str, vb: &Value) -> bool {
	if name_a != name_b {
		return false;
	}
	match (va, vb) {
		(Value::Empty, Value::Empty) => true,
		(Value::Cell(a), Value::Cell(b)) => a.text == b.text,
		(Value::Array(a), Value::Array(b)) => {
			a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.text == y.text)
		}
		(Value::Raw(a), Value::Raw(b)) => a.info == b.info && a.content == b.content,
		_ => false,
	}
}

/// Hash of the (name, display) pair a `[value]` selector matches with - what
/// disp_key would give, streamed instead of built. Elements hold the logical
/// string, so the bytes feed straight in.
fn disp_hash(name: &str, v: &Value) -> u64 {
	let mut h = Fnv::new();
	h.bytes(name.as_bytes());
	h.byte(0xFF);
	match v {
		Value::Empty => {}
		Value::Cell(e) => h.bytes(e.text.as_bytes()),
		Value::Array(_) => h.bytes(v.display().as_bytes()),
		Value::Raw(r) => h.bytes(r.content.as_bytes()),
	}
	h.0
}

/// The query-side twin of disp_hash: the selector's logical text, the same
/// bytes the display would contain.
fn disp_hash_text(name: &str, want: &str) -> u64 {
	let mut h = Fnv::new();
	h.bytes(name.as_bytes());
	h.byte(0xFF);
	h.bytes(want.as_bytes());
	h.0
}

/// One accelerator bucket: node indices in insertion order. Nearly always one
/// entry; a second means two different keys collided in the 64-bit hash.
#[derive(Debug)]
enum Slot {
	One(usize),
	Many(Vec<usize>),
}

impl Slot {
	fn push(&mut self, idx: usize) {
		match self {
			Slot::One(a) => *self = Slot::Many(vec![*a, idx]),
			Slot::Many(v) => v.push(idx),
		}
	}
	fn first_match(&self, f: impl Fn(usize) -> bool) -> Option<usize> {
		match self {
			Slot::One(a) => f(*a).then_some(*a),
			Slot::Many(v) => v.iter().copied().find(|&c| f(c)),
		}
	}
	/// Drop `idx` if present; true = the slot is now empty and the caller
	/// should remove the map entry.
	fn remove(&mut self, idx: usize) -> bool {
		match self {
			Slot::One(a) => *a == idx,
			Slot::Many(v) => {
				v.retain(|&c| c != idx);
				if v.len() == 1 {
					let only = v[0];
					*self = Slot::One(only);
					return false;
				}
				v.is_empty()
			}
		}
	}
}

/// The fence a field line's value opens, if it opens one. A line that did
/// not tokenize opens one too when a fence follows its first colon past
/// where it stopped making sense, with no comment before that colon. Read
/// as lines, such a body would bind, and its closing fence would open a
/// block of its own.
fn line_fence(tok: &Tokens, rest: &str) -> Option<(u8, usize, String)> {
	if let Some((at, _)) = tok.fault {
		let s = rest.as_bytes();
		let sep = (at..s.len())
			.find(|&k| s[k] == b':' || comment_at(s, k))
			.filter(|&k| s[k] == b':')?;
		let mut value = Tokens::default();
		tokenize_value(rest, sep + 1, Rules::Current, &mut value);
		return fence_open(&rest[value.value.0..value.value.1]);
	}
	tok.sep?;
	// A capped scan zeroed the value, and a fence is told by its leading run
	// alone.
	fence_open(if tok.capped {
		trim_wsp(&rest[tok.value.0..])
	} else {
		&rest[tok.value.0..tok.value.1]
	})
}

/// The fence a line opens under the field above it, read as a value.
fn child_fence(rest: &str, tok: &mut Tokens) -> Option<(u8, usize, String)> {
	tokenize_value(rest, 0, Rules::Current, tok);
	// A capped scan zeroed the value, and a fence is told by its leading run
	// alone.
	fence_open(if tok.capped {
		rest
	} else {
		&rest[tok.value.0..tok.value.1]
	})
}

/// Opening fence: a run of >=3 backticks or tildes, then an optional info-string.
fn fence_open(rest: &str) -> Option<(u8, usize, String)> {
	let first = rest.as_bytes().first().copied()?;
	if first != b'`' && first != b'~' {
		return None;
	}
	let run = rest.bytes().take_while(|&b| b == first).count();
	if run < 3 {
		return None;
	}
	Some((first, run, trim_wsp(&rest[run..]).to_string()))
}

// `min_len` is the opening fence's length, which the grammar puts at three or
// more, so the length test already rules out the empty line that `all` would
// otherwise accept.
fn is_fence_close(line: &str, ch: u8, min_len: usize) -> bool {
	// A raw body keeps its carriage returns, so only a space or tab is trimmed.
	let t = line.trim_matches([' ', '\t']);
	t.len() >= min_len && t.bytes().all(|b| b == ch)
}

/// The leading space/tab run of a line (the indent).
fn leading_ws(line: &str) -> &str {
	let n = line
		.bytes()
		.take_while(|&b| b == b' ' || b == b'\t')
		.count();
	&line[..n]
}

/// Remove a raw block's nesting indent from one content line: only what the
/// line actually shares with it, so a shallower line (whitespace-only, or
/// written flush left) keeps its own spacing rather than being blanked.
fn strip_common<'a>(line: &'a str, common: &str) -> &'a str {
	let mut k = 0;
	for (a, b) in common.chars().zip(line.chars()) {
		if a != b {
			break;
		}
		k += a.len_utf8();
	}
	&line[k..]
}

// ---------------------------------------------------------------------------
// Migration: a 2.x document rewritten for the current lexical rules
// ---------------------------------------------------------------------------

/// What `migrate` produced, and what it could not keep.
#[derive(Debug)]
pub struct Migration {
	pub text: String,
	/// The file already names its format, so there was nothing to migrate and
	/// `text` is the input.
	pub current: bool,
	/// Pieces the two rule sets read differently and nothing can decide
	/// between, left as written. Always 0 when the caller said the file is 2.x.
	pub ambiguous: usize,
	/// Lines 2.x bound a value on that nothing binds now: bracket text after
	/// the colon, which has no 3.0 spelling to move to.
	pub lost: usize,
}

/// The counters a line rewrite reports back, and the one thing it asks.
struct Migrating {
	from_v2: bool,
	ambiguous: usize,
	lost: usize,
}

/// The format major a document's `##    Format   N` line names, read the way
/// `migrate` reads it. None when no line names one, which is every 2.x file
/// and a current one written without the info block. `migrate` hands a file
/// back untouched exactly when this is `FORMAT_MAJOR` or more, so a program
/// can ask before it rewrites anything.
#[must_use]
pub fn format_version(text: &str) -> Option<u32> {
	format_line_version(text.strip_prefix('\u{feff}').unwrap_or(text))
}

/// format_version() on text with the BOM already off. Digits that do not fit
/// 32 bits read as "newer than this", since whatever wrote them was not 2.x.
///
/// A Format line pasted into a raw body is that block's content, and taking
/// it as the file's would rewrite a current file, or leave an old one alone.
/// Where the blocks are turns on the rules the file was written under, which
/// is what the line itself says: a line naming this format counts outside the
/// blocks the parser finds, and an older one outside the blocks the rewrite
/// skips. The two differ on a single-quoted name ending in a backslash. A file
/// naming this format on any line has nothing to migrate, so the highest line
/// decides: the stamp `migrate` adds comes after an older one, and the next
/// run has to see it.
fn format_line_version(text: &str) -> Option<u32> {
	let mut now = RawLines::new(Rules::Current);
	let mut then = RawLines::new(Rules::V2);
	let mut found: Option<u32> = None;
	for line in text.split('\n') {
		let current = now.step(line);
		let old = then.step(line);
		let Some(n) = current
			.or(old)
			.and_then(|r| r.strip_prefix(FORMAT_LINE_HEAD))
		else {
			continue;
		};
		if n.is_empty() || !n.bytes().all(|c| c.is_ascii_digit()) {
			continue;
		}
		// More digits than fit is not a 2.x file either, so it reads as this
		// major and there is nothing to migrate.
		let v = n.parse().unwrap_or(FORMAT_MAJOR);
		if v >= FORMAT_MAJOR {
			if current.is_some() {
				return Some(v);
			}
		} else if old.is_some() {
			found = found.max(Some(v));
		}
	}
	found
}

/// The schema a document's `##    Schema   REF` line names: a path, or a URL
/// for an editor to fetch. None when no line names one. The first such line
/// wins, and one inside a raw body is that block's content, as with the
/// Format line. Either line may be indented, since the formatter indents a
/// comment to the field below it. A relative path is the caller's to resolve,
/// from the config file's directory.
#[must_use]
pub fn schema_ref(text: &str) -> Option<String> {
	let text = text.strip_prefix('\u{feff}').unwrap_or(text);
	// The Schema line is new in this format, so the blocks are the parser's.
	let mut lines = RawLines::new(Rules::Current);
	for line in text.split('\n') {
		let Some(r) = lines
			.step(line)
			.and_then(|r| r.strip_prefix(SCHEMA_LINE_HEAD))
		else {
			continue;
		};
		let r = trim_wsp(r);
		if !r.is_empty() {
			return Some(r.to_string());
		}
	}
	None
}

/// Walks a document's lines and tells raw-body content from the rest, the
/// way one rule set reads the file: the current rules find a block where the
/// parser does, and the 2.x rules where the rewrite does.
struct RawLines {
	rules: Rules,
	tok: Tokens,
	fence: Option<(u8, usize)>,
	// Only the blocks a line opens are wanted, not what the rewrite counts.
	dry: Migrating,
}

impl RawLines {
	fn new(rules: Rules) -> Self {
		RawLines {
			rules,
			tok: Tokens::default(),
			fence: None,
			dry: Migrating {
				from_v2: true,
				ambiguous: 0,
				lost: 0,
			},
		}
	}

	/// The next line's text past its indent, or None when it is part of a
	/// raw block, fences included.
	fn step<'t>(&mut self, line: &'t str) -> Option<&'t str> {
		let body = line.trim_end_matches('\r');
		if let Some((ch, len)) = self.fence {
			if is_fence_close(body, ch, len) {
				self.fence = None;
			}
			return None;
		}
		let rest = trim_wsp_end(&body[leading_ws(body).len()..]);
		// Only a line with a run of three backticks or tildes can open a
		// block, so the rest skip the tokenizer.
		if rest.contains("```") || rest.contains("~~~") {
			match self.rules {
				Rules::Current => self.fence = opens_raw(rest, &mut self.tok),
				Rules::V2 => {
					migrate_line(rest, &mut self.tok, &mut self.fence, &mut self.dry);
				}
			}
		}
		Some(rest)
	}
}

/// The raw block a line opens under the current rules: a fence line under a
/// field, or a field line whose value is a fence, read as the parser reads
/// them. A line refused for where it sits or for its text still takes its
/// body.
fn opens_raw(rest: &str, tok: &mut Tokens) -> Option<(u8, usize)> {
	let rest = rest.trim_start_matches(is_wsp);
	let fence = if rest.starts_with(['`', '~']) {
		child_fence(rest, tok)
	} else if !is_field_text(rest) {
		None
	} else {
		tokenize(rest, b':', false, Rules::Current, tok);
		line_fence(tok, rest)
	};
	fence.map(|(ch, len, _)| (ch, len))
}

/// Rewrite a document written under the 2.x rules so this parser reads the
/// same tree. Each line is read with the 2.x tokenizer and rewritten only
/// where the two rule sets disagree: a piece whose backslash meant an escape
/// is written the way the writer writes the text 2.x read; a piece that
/// opened a quote it never closed is quoted whole; the `name:[disc]`
/// selector sugar loses its colon, and on a last segment becomes `name: disc`,
/// with `disc` written the way the formatter writes a value. The value
/// syntax's other rewrites, such as quoting a bare value with a space, are
/// not done yet (2026100207032800).
/// Everything else - comments, blank lines, raw bodies, layout, a line 2.x
/// could not read - comes through as written. One shape has no spelling
/// here at all: a fence label holding a `#`, which 2.x ran to the end of the
/// line and which now ends at the `#`.
///
/// Which file this is cannot be read off the text: `p: 'C:\temp'` is one value
/// under 2.x and another under these rules, so rewriting a 3.0 file changes
/// what it says. So the version line decides. A file that names this format is
/// returned untouched; one that names an older format, or a caller passing
/// `from_v2`, gets the backslash re-spellings; anything else gets every other
/// rewrite and leaves those pieces alone, counted in `ambiguous` for the caller
/// to refuse over. A rewritten file is stamped with the version line, so the
/// second run has an answer the first one did not.
pub fn migrate(text: &str, from_v2: bool) -> Migration {
	migrate_text(text, from_v2, true)
}

/// migrate() without the version line or the migrated note, for a program
/// that writes `GEN_BANNER` itself, which includes the version line. The
/// next run can tell the result is current only once that is written.
pub fn migrate_unstamped(text: &str, from_v2: bool) -> Migration {
	migrate_text(text, from_v2, false)
}

/// The line ending most of the text's lines end with. A tie goes to LF.
fn majority_eol(text: &str) -> &'static str {
	let crlf = text.matches("\r\n").count();
	let lf = text.matches('\n').count() - crlf;
	if crlf > lf { "\r\n" } else { "\n" }
}

fn migrate_text(text: &str, from_v2: bool, stamp: bool) -> Migration {
	let (bom, body_text) = match text.strip_prefix('\u{feff}') {
		Some(t) => ("\u{feff}", t),
		None => ("", text),
	};
	let version = format_line_version(body_text);
	if version.is_some_and(|n| n >= FORMAT_MAJOR) {
		return Migration {
			text: text.to_string(),
			current: true,
			ambiguous: 0,
			lost: 0,
		};
	}
	let mut st = Migrating {
		from_v2: from_v2 || version.is_some(),
		ambiguous: 0,
		lost: 0,
	};
	let mut out = String::with_capacity(body_text.len() + 96);
	out.push_str(bom);
	let mut tok = Tokens::default();
	let mut fence: Option<(u8, usize)> = None;
	let mut changed = false;
	// The output as the parser will read it, for where its raw blocks are.
	let mut now = RawLines::new(Rules::Current);
	let mut split = false;
	for (i, line) in body_text.split('\n').enumerate() {
		if i > 0 {
			out.push('\n');
		}
		let start = out.len();
		let raw_then = fence.is_some();
		let body = line.trim_end_matches('\r');
		let cr = &line[body.len()..];
		if let Some((ch, len)) = fence {
			if is_fence_close(body, ch, len) {
				fence = None;
			}
			out.push_str(line);
		} else {
			let indent = leading_ws(body);
			let rest_full = &body[indent.len()..];
			let rest = trim_wsp_end(rest_full);
			// `lost` counts lines, and one line can lose several values.
			let lost_before = st.lost;
			let migrated = migrate_line(rest, &mut tok, &mut fence, &mut st);
			st.lost = lost_before + usize::from(st.lost > lost_before);
			changed |= migrated != rest;
			out.push_str(indent);
			out.push_str(&migrated);
			out.push_str(&rest_full[rest.len()..]);
			out.push_str(cr);
		}
		// Lines one rule set reads as a raw body and the other as fields are
		// one more thing that reads two ways, counted once per run of them.
		let differs = now.step(&out[start..]).is_none() != raw_then;
		if differs && !split && !st.from_v2 {
			st.ambiguous += 1;
		}
		split = differs;
	}
	// Stamping a file whose ambiguous pieces were left alone would claim a
	// migration that did not finish, and the next run would then skip it. A
	// document that never closes its raw block has nowhere to put the line
	// either, under either rule set: appended, it would be another line of the
	// block's content. The lines end the way most of the file's do.
	if stamp && st.ambiguous == 0 && fence.is_none() && now.fence.is_none() {
		let eol = majority_eol(body_text);
		if !out.is_empty() && !out.ends_with('\n') {
			out.push_str(eol);
		}
		out.push_str(FORMAT_LINE);
		out.push_str(eol);
		if changed {
			out.push_str(MIGRATED_LINE);
			out.push_str(eol);
		}
	}
	Migration {
		text: out,
		current: false,
		ambiguous: st.ambiguous,
		lost: st.lost,
	}
}

/// One edit to a line: replace `start..end` with the text.
type Edit = (usize, usize, String);

fn splice(text: &str, mut edits: Vec<Edit>) -> String {
	edits.sort_by_key(|e| e.0);
	let mut out = String::with_capacity(text.len() + 8);
	let mut at = 0;
	for (start, end, with) in edits {
		out.push_str(&text[at..start]);
		out.push_str(&with);
		at = end;
	}
	out.push_str(&text[at..]);
	out
}

/// True when the current tokenizer reads this spelling as one whole piece,
/// quoted the same way, with exactly this text, so nothing has to change.
fn reads_same(spelling: &str, quoted: bool, logical: &str) -> bool {
	let mut tok = Tokens::default();
	tokenize_value(spelling, 0, Rules::Current, &mut tok);
	tok.elements.len() == 1
		&& tok.value == (0, spelling.len())
		&& matches!(tok.elements[0].quote, Quote::Single | Quote::Double) == quoted
		&& piece_fault(&tok.elements[0], spelling, "value").is_none()
		&& piece_text(&tok.elements[0], spelling) == logical
}

/// How a changed piece is written: the way the writer writes the text 2.x
/// read, so a backslash is text and a tab or line break is an escape.
fn migrate_spelling(logical: &str, bare: bool) -> String {
	if bare && !needs_quotes(logical) {
		logical.to_string()
	} else {
		quote_text(logical)
	}
}

/// True when 2.x read this bare `[...]` body as the JSON-habit array rather
/// than a discriminator: more than one element, where a comma behind a
/// backslash was not one.
fn v2_bracket_array(body: &str) -> bool {
	let mut tok = Tokens::default();
	tokenize_value(body, 0, Rules::V2, &mut tok);
	tok.elements.len() > 1
}

/// The re-spellings a value's pieces need. Each piece is read the 2.x way
/// (escapes everywhere, an open quote kept whole, a quote at both ends
/// making it quoted) and rewritten only where the current rules would read
/// the same text as something else.
fn value_edits(text: &str, tok: &Tokens, edits: &mut Vec<Edit>, st: &mut Migrating) {
	for p in &tok.elements {
		let raw = &text[p.start..p.end];
		let quoted = matches!(p.quote, Quote::Single | Quote::Double);
		let (a, b) = if quoted {
			(p.start - 1, p.end + 1)
		} else {
			(p.start, p.end)
		};
		if p.quote == Quote::None && !raw.contains('\\') && !raw.is_empty() {
			continue;
		}
		let logical = apply_escapes_v2(raw);
		if reads_same(&text[a..b], quoted, &logical) {
			continue;
		}
		// A resolved escape is the one edit that turns on which rule set wrote
		// the file: these bytes say one thing under 2.x and another here. An
		// open quote or an empty slot reads alike either way, so it still goes,
		// and so does a pair 2.x kept as written.
		if logical != raw && !st.from_v2 {
			st.ambiguous += 1;
			continue;
		}
		let spelling = migrate_spelling(&logical, !(quoted || p.quote == Quote::Open));
		edits.push((a, b, spelling));
	}
}

fn migrate_line(
	rest: &str,
	tok: &mut Tokens,
	fence: &mut Option<(u8, usize)>,
	st: &mut Migrating,
) -> String {
	if rest.is_empty() || rest.starts_with('#') {
		return rest.to_string();
	}
	// A child-indent fence: 2.x read the info string to the end of the line.
	if let Some((ch, len, _)) = fence_open(rest) {
		*fence = Some((ch, len));
		return rest.to_string();
	}
	let s = rest.as_bytes();
	let mut edits: Vec<Edit> = Vec::new();
	if rest.starts_with('*') && s.get(1).is_some_and(|&b| is_wsp_byte(b)) {
		tokenize_value(rest, 1, Rules::V2, tok);
		// A bare comma was refused (E010), so there is nothing to convert.
		if tok.elements.len() == 1 {
			value_edits(rest, tok, &mut edits, st);
		}
	} else {
		tokenize(rest, b':', false, Rules::V2, tok);
		if tok.fault.is_some() {
			return rest.to_string();
		}
		let last = tok.segments.len() - 1;
		for (i, seg) in tok.segments.iter().enumerate() {
			let name = &rest[seg.name.start..seg.name.end];
			// A backslash pair 2.x resolved in a quoted name is text now.
			if matches!(seg.name.quote, Quote::Single | Quote::Double)
				&& apply_escapes_v2(name) != name
			{
				if st.from_v2 {
					edits.push((
						seg.name.start - 1,
						seg.name.end + 1,
						escape_name(&apply_escapes_v2(name)).into_owned(),
					));
				} else {
					st.ambiguous += 1;
				}
			}
			let Some(sel) = seg.selector else {
				continue;
			};
			let quoted = matches!(sel.quote, Quote::Single | Quote::Double);
			// Back from the body to the `[`, and forward to the `]`.
			let mut open = if quoted { sel.start - 1 } else { sel.start };
			while open > 0 && is_wsp_byte(s[open - 1]) {
				open -= 1;
			}
			open -= 1;
			let mut close = if quoted { sel.end + 1 } else { sel.end };
			while s[close] != b']' {
				close += 1;
			}
			let mut colon = None;
			let mut k = open;
			while k > 0 && is_wsp_byte(s[k - 1]) {
				k -= 1;
			}
			if k > 0 && s[k - 1] == b':' {
				colon = Some(k - 1);
			}
			let body = &rest[sel.start..sel.end];
			let logical = apply_escapes_v2(body);
			if i == last && tok.sep.is_none() {
				if let Some(c) = colon {
					// `name:[disc]` with nothing after it: 2.x read it as
					// `name: disc`. Two or more elements in there was refused
					// as a bracket array - a comma behind a backslash was not
					// one - and an index or the wildcard was refused as a
					// selector, so those stay as written. A bare body moves
					// into a value, where a fence run opens a raw block and a
					// leading `[` is bracket text, so the emitter writes it.
					if !quoted && (index_shape(body) || body == "*") {
						return rest.to_string();
					}
					// 2.x bound the bracket array, as one folded string. There
					// is no spelling to move that to - a value beginning with
					// `[` is bracket text now - so the binding goes, and the
					// caller hears about it rather than reading exit 0.
					if !quoted && v2_bracket_array(body) {
						st.lost += 1;
						return rest.to_string();
					}
					if logical != body && !st.from_v2 {
						st.ambiguous += 1;
						continue;
					}
					let spelling = if logical != body {
						migrate_spelling(&logical, false)
					} else if quoted {
						rest[open + 1..close].trim_matches(is_wsp).to_string()
					} else {
						migrate_spelling(&logical, true)
					};
					edits.push((c, close + 1, format!(": {}", spelling)));
					continue;
				}
			} else if let Some(c) = colon {
				// The colon goes, and one space after it when the author
				// spaced both sides, so `base : [x]` comes out `base [x]`.
				let spaced = c > 0 && is_wsp_byte(s[c - 1]) && is_wsp_byte(s[c + 1]);
				edits.push((c, c + 1 + usize::from(spaced), String::new()));
			}
			// A backslash pair 2.x resolved is text now.
			if logical != body {
				if st.from_v2 {
					let (a, b) = if quoted {
						(sel.start - 1, sel.end + 1)
					} else {
						(sel.start, sel.end)
					};
					edits.push((a, b, migrate_spelling(&logical, false)));
				} else {
					st.ambiguous += 1;
				}
			}
		}
		if tok.sep.is_some() {
			// A same-line fence: the info string ran to the end of the line.
			if let Some((ch, len, _)) = fence_open(&rest[tok.value.0..]) {
				*fence = Some((ch, len));
				return splice(rest, edits);
			}
			value_edits(rest, tok, &mut edits, st);
		}
	}
	splice(rest, edits)
}

// ---------------------------------------------------------------------------
// Path scanner (shared by file lines and accessor queries)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum Selector {
	// quoted: the selector text was quoted in the path. A quoted selector is
	// scalar-only - it matches a single-element value whose logical string
	// equals the text - so quoting distinguishes the scalar "a, b" from the
	// two-element list a, b, the same way quoting escapes elsewhere.
	ByValue { text: String, quoted: bool },
	ByIndex(u64), // u64, not usize: index width must not vary with the target's pointer size
	Wildcard,
}

#[derive(Debug, Clone)]
struct Segment {
	name: String,     // folded, escapes resolved
	name_src: String, // as authored: unfolded, quotes stripped, escapes as written
	selector: Option<Selector>,
	star: bool, // bare `*` name wildcard; quoted "*" stays a literal name
}

struct PathScan {
	segments: Vec<Segment>,
	value: Option<(usize, usize)>, // span of the text after the separator colon, before any comment, trimmed
}

/// The spelling of an index selector - an optional `#`, an optional `+`, then
/// digits - whatever its size. The grammar says `1*DIGIT`, with no upper bound.
fn index_shape(body: &str) -> bool {
	let b = body.strip_prefix('#').unwrap_or(body);
	let b = b.strip_prefix('+').unwrap_or(b);
	!b.is_empty() && b.bytes().all(|c| c.is_ascii_digit())
}

/// usize view of a selector index: None when it does not fit the target's
/// pointer width. An index that big can only mean "no such instance"; a bare
/// `as` cast would wrap into a live element on a 32-bit build.
fn index_usize(k: u64) -> Option<usize> {
	usize::try_from(k).ok()
}

/// What a selector body means: `*` the wildcard, an index shape an index, a
/// quoted body a value match, anything else a bare value match.
fn selector_of(p: &Piece, text: &str) -> Selector {
	let body = piece_text(p, text);
	if matches!(p.quote, Quote::Single | Quote::Double) {
		// quotes force a value match, even numeric - and scalar-only
		return Selector::ByValue {
			text: body,
			quoted: true,
		};
	}
	if body == "*" {
		return Selector::Wildcard;
	}
	if let Some(n) = body.strip_prefix('#').and_then(|d| d.parse::<u64>().ok()) {
		return Selector::ByIndex(n);
	}
	if let Ok(n) = body.parse::<u64>() {
		return Selector::ByIndex(n);
	}
	if index_shape(&body) {
		// All digits but past u64: an index no instance can have, not a
		// value selector that would create one on a write.
		return Selector::ByIndex(u64::MAX);
	}
	Selector::ByValue {
		text: body,
		quoted: false,
	}
}

/// Why a line is refused, and whether its name still reads: then the line
/// holds its level open, so what is written under it loads under that name.
#[derive(Debug)]
struct Fault {
	code: &'static str,
	msg: String,
	opens: bool,
}

impl Fault {
	fn new(code: &'static str, msg: impl Into<String>, opens: bool) -> Fault {
		Fault {
			code,
			msg: msg.into(),
			opens,
		}
	}
}

/// Whitespace or a quote in a bare piece (`E025`), named for the message.
fn bare_trouble(raw: &str) -> Option<&'static str> {
	for c in raw.chars() {
		if white_space(c) {
			return Some("whitespace");
		}
		if matches!(c, '\'' | '"' | '`') {
			return Some("a quote");
		}
	}
	None
}

/// What is wrong with one piece of value text: an open quote (`E017`), a bad
/// escape (`E023`), or whitespace or a quote in bare text (`E025`). `what`
/// names the piece for the message. A backtick value is raw, so only an open
/// one is wrong.
fn piece_fault(p: &Piece, text: &str, what: &str) -> Option<(&'static str, String)> {
	let raw = &text[p.start..p.end];
	match p.quote {
		Quote::Open => Some(("E017", format!("unterminated quote in {}", what))),
		Quote::Backtick => None,
		Quote::None | Quote::Single | Quote::Double => {
			if raw.contains(ESCAPE_MARK)
				&& let Err(msg) = resolve_marks(raw)
			{
				return Some(("E023", msg));
			}
			if p.quote == Quote::None
				&& let Some(trouble) = bare_trouble(raw)
			{
				return Some(("E025", format!("{} in a bare {}; quote it", trouble, what)));
			}
			None
		}
	}
}

/// A malformed bracket array (`E019`). Only the value is wrong, so the name
/// still reads.
fn array_fault(tok: &Tokens) -> Option<Fault> {
	tok.array_fault.map(|(_, why)| {
		Fault::new(
			"E019",
			format!("malformed array, {}; quote the value if it is text", why),
			true,
		)
	})
}

/// The first fault in a value: one of its pieces, then a bare comma outside
/// brackets (`E026`). A piece first, since an open quote or a space is what
/// a comma beside it most often means. Only the value is wrong, so the name
/// still reads.
fn value_fault(tok: &Tokens, text: &str) -> Option<Fault> {
	let what = if tok.array.is_some() {
		"array element"
	} else {
		"value"
	};
	if let Some((code, msg)) = tok.elements.iter().find_map(|p| piece_fault(p, text, what)) {
		return Some(Fault::new(code, msg, true));
	}
	(tok.array.is_none() && tok.elements.len() > 1).then(|| {
		Fault::new(
			"E026",
			"bare comma; an array is written in brackets, [a, b], and text with a comma is quoted",
			true,
		)
	})
}

/// Why a stacked item's value is refused: an array, since arrays do not
/// nest (`E019`), what a value is refused for, a bare comma (`E026`), or a
/// bare name ending in a colon, the way YAML starts an object in a list
/// (`E027`).
fn item_fault(tok: &Tokens, text: &str) -> Option<Fault> {
	if tok.array.is_some() {
		return Some(Fault::new(
			"E019",
			"a list item is one value; arrays do not nest",
			true,
		));
	}
	if let Some((code, msg)) = tok
		.elements
		.iter()
		.find_map(|p| piece_fault(p, text, "list item"))
	{
		return Some(Fault::new(code, msg, true));
	}
	if tok.elements.len() > 1 {
		return Some(Fault::new(
			"E026",
			"bare comma in a list item; an item is one value, and text with a comma is quoted",
			true,
		));
	}
	match tok.elements.as_slice() {
		[p] if p.quote == Quote::None && text[p.start..p.end].ends_with(':') => Some(Fault::new(
			"E027",
			"a list item that is a name ending in ':'; a list of objects is written as instances, and text ending in ':' is quoted",
			true,
		)),
		_ => None,
	}
}

/// A fault in a path that leaves its name unread: a bad escape in a quoted
/// name, or anything a value could have wrong in a selector body. The line
/// takes its block with it, since there is no name to hold open.
fn path_fault(tok: &Tokens, text: &str) -> Option<Fault> {
	for seg in &tok.segments {
		let name = &seg.name;
		if matches!(name.quote, Quote::Single | Quote::Double)
			&& let Err(msg) = resolve_marks(&text[name.start..name.end])
		{
			return Some(Fault::new("E023", msg, false));
		}
		if let Some(sel) = &seg.selector
			&& let Some((code, msg)) = piece_fault(sel, text, "selector")
		{
			return Some(Fault::new(code, msg, false));
		}
	}
	None
}

/// Why a field line that scanned is refused, before the element cap: a path
/// that does not read, a bare name that breaks the spelling rule, a
/// malformed bracket array, a bare comma, or a value with an open quote, a
/// bad escape, or whitespace or a quote in bare text. A raw block's info
/// string is not value text, so a fence line's value is not judged.
fn line_fault(tok: &Tokens, text: &str) -> Option<Fault> {
	if let Some(f) = path_fault(tok, text) {
		return Some(f);
	}
	if tok.misspelled.is_some() {
		return Some(Fault::new(
			"E014",
			"field name needs quotes; a bare name is a letter, then letters, digits, '-' and '_'",
			true,
		));
	}
	if let Some(f) = array_fault(tok) {
		return Some(f);
	}
	if line_fence(tok, text).is_some() {
		return None;
	}
	value_fault(tok, text)
}

/// A path segment a LAZY level can open: no index or wildcard selector,
/// which could fail to place it.
fn opens_as_written(seg: &Segment) -> bool {
	matches!(seg.selector, None | Some(Selector::ByValue { .. }))
}

/// True when a reload holds this kept line's level open (LAZY): a field
/// line refused for its value alone, an array kept for the lines under it,
/// or a bare name that still reads, with a path that opens.
fn opens_later(text: &str) -> bool {
	if !is_field_text(text) {
		return false;
	}
	let mut tok = Tokens::default();
	tokenize(text, b':', false, Rules::Current, &mut tok);
	let Ok(scan) = path_of(&tok, text) else {
		return false;
	};
	scan.segments.iter().all(opens_as_written)
		&& line_fault(&tok, text).map_or(tok.array.is_some(), |f| f.opens)
}

/// A stacked list item's line: `-` then a blank. The blank is what keeps
/// `-x: y` a field line (`E014`) and `- -5` the item `-5`.
fn is_item(text: &str) -> bool {
	let b = text.as_bytes();
	b.first() == Some(&b'-') && b.get(1).is_some_and(|&c| is_wsp_byte(c))
}

/// A line's text after its indent that is read as a field line: not a
/// comment, a list item, or an old `*` item (`E013`).
fn is_field_text(text: &str) -> bool {
	!text.starts_with(['#', '*']) && !is_item(text)
}

/// The path the tokens give. Err(reason) is the tokenizer's fault: input
/// that is not a path at all, which the caller skips with a diagnostic.
fn path_of(tok: &Tokens, text: &str) -> Result<PathScan, String> {
	if let Some((_, reason)) = tok.fault {
		return Err(reason.to_string());
	}
	let mut segments: Vec<Segment> = Vec::with_capacity(tok.segments.len());
	for seg in &tok.segments {
		let raw = &text[seg.name.start..seg.name.end];
		// Names resolve escapes, the same rule values follow when they are
		// compared: two spellings of one name are one name. name_src keeps
		// the source spelling, which is what `authored_name` hands back -
		// empty when it matches, the same sentinel NodeData uses.
		//
		// A name with nothing to resolve and no upper case is already its
		// own resolved, folded spelling, so the source text becomes the name
		// and nothing else is allocated. That is nearly every name in a
		// document, and this runs once per segment per line.
		// A bare name takes no escapes, so only a quoted one resolves them.
		let quoted = matches!(seg.name.quote, Quote::Single | Quote::Double);
		let plain =
			(!quoted || !raw.contains(ESCAPE_MARK)) && !raw.bytes().any(|b| b.is_ascii_uppercase());
		let (name, name_src) = if plain {
			(raw.to_string(), String::new())
		} else if quoted {
			(
				fold_name(&piece_text(&seg.name, text)).into_owned(),
				raw.to_string(),
			)
		} else {
			(fold_name(raw).into_owned(), raw.to_string())
		};
		segments.push(Segment {
			name,
			name_src,
			selector: seg.selector.as_ref().map(|p| selector_of(p, text)),
			star: seg.star,
		});
	}
	Ok(PathScan {
		segments,
		value: tok.sep.map(|_| tok.value),
	})
}

/// Scan a lookup path `a . b [sel] . c`: the document-line spelling plus
/// the bare `*` segment (the name wildcard - any child name), which document
/// lines never take; only lookups (reads, the writer probe, schema paths)
/// do. Whitespace around dots, colons and brackets is insignificant.
fn scan_lookup(input: &str) -> Result<PathScan, String> {
	let mut tok = Tokens::default();
	tokenize(input, b':', true, Rules::Current, &mut tok);
	if let Some(f) = path_fault(&tok, input)
		&& f.code == "E023"
	{
		return Err(f.msg);
	}
	path_of(&tok, input)
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

struct Parser<'a> {
	arena: Vec<NodeData>,
	diags: Vec<Diagnostic>,
	// (indent string, node) for each open level; [0] is the virtual root.
	stack: Vec<(&'a str, usize)>,
	// Per-node hash-of-(name, value-key) -> matching children, parallel to
	// arena and lazily boxed so leaves never allocate one. Pure lookup
	// accelerator for select_or_create; children keeps the order. No key
	// strings are stored - a hit is verified against the arena with merge_eq.
	// The box is the point: an inline Option<HashMap> costs 48 bytes per node.
	#[allow(clippy::box_collection)]
	child_map: Vec<Option<Box<U64Map<Slot>>>>,
	// Per-node hash-of-(name, display) -> first matching child: the `[value]`
	// selector accelerator (its predicate is display(), a different and
	// non-injective key from child_map's). Same first-wins discipline, same
	// mutation sites; ownership is by hash, and a query verifies its hit.
	#[allow(clippy::box_collection)]
	disp_map: Vec<Option<Box<U64Map<usize>>>>,
	// Whole-line comments waiting for the next line that binds a node. The
	// source indent is kept only to decide after-attachment (a comment deeper
	// than the next binding hangs on the block it sits in).
	pending: Vec<Pend<'a>>,
	// (end index, indent length): every pending entry before `end` has a
	// ceiling at or under that length. Lengths rise along the stack, so a
	// hang check pops the marks above its own indent and walks only what
	// they covered. Without it a run of retained bad lines is rewalked per
	// line and a plain text file parses in quadratic time.
	pend_marks: Vec<(usize, usize)>,
	saw_blank: bool, // a blank line waits to become the next bound node's blank_before
	// An open stacked list defers its merge-key remap (rebuilding the key per
	// element is O(list^2) time); (node, key hash, display hash) at deferral
	// start, flushed before any map lookup and at end of parse.
	star_open: Option<(usize, u64, u64)>,
	// Parents where a remap ended up on a key a sibling already held: the only
	// places a duplicate can survive the keyed lookup, so the fold starts here.
	late_dups: Vec<usize>,
	// Node -> line of the re-open that H002-hinted it. A merge under a hinted
	// container combines the same two textual regions, so it hints too even
	// when it ends up on the newest child at its own scope - that is how every
	// merged level reports, not just the outermost. The stored line splits old
	// children (hint) from ones the re-opened region itself created (silent).
	reentered: HashMap<usize, usize>,
	lost: usize,      // dropped lines/values canonical output cannot re-emit
	kept_owed: usize, // lines kept as written, one per Retained outcome
	// Indent of the last E012 line kept as written, while the lines after it
	// sit under it; those are E018 and are kept as written too.
	kept_hold: Option<&'a str>,
	kept_any: bool,
	kept_arrays: bool,
	// The text's lines, and the last array line each node's level was
	// opened by, for one found to have a field under it after it bound
	// (E028).
	src: Vec<&'a str>,
	array_line: HashMap<usize, ArrayLine>,
	// parse_limited's caps, 0 = uncapped: nodes counted against the arena
	// (root excluded), elements against a single value's cell, diagnostics
	// against the list. Past the diagnostic cap nothing is listed, only
	// counted (errors, hints), for the one tail entry the parse ends with.
	max_nodes: usize,
	max_elements: usize,
	max_diags: usize,
	unlisted: (usize, usize),
	// A raw block's or a stacked list's binding line and the last line it
	// took, for the save that keeps lines.
	ends: Vec<(usize, usize)>,
	// Each line counted in `lost`, kept only for the save that keeps lines,
	// since a capped parse of a huge bad file would hold one per line.
	track_dropped: bool,
	dropped: Vec<usize>,
	lazies: Vec<Lazy<'a>>,
}

/// resolve_parent() on a level stack, without moving anything: the parent it
/// hands back, and how it cuts the stack to get there. The emitter runs it on
/// its model of the stack a reload will have.
fn locate_in<S: AsRef<str>>(stack: &[(S, usize)], indent: &str) -> (Option<usize>, Cut) {
	let mut hold = None;
	for i in (0..stack.len()).rev() {
		let (ind, node) = (stack[i].0.as_ref(), stack[i].1);
		if ind == indent {
			if node == UNOPENED {
				// Back at a skipped line's column: refused the same way.
				return (None, Cut::To(i + 1));
			}
			// Sibling of stack[i]: its parent is the entry below it.
			let parent = if i == 0 { ROOT } else { stack[i - 1].1 };
			// Keep the sentinel; a top-level line resolves to ROOT.
			return (
				Some(if parent == UNOPENED { DEAD } else { parent }),
				Cut::To(i.max(1)),
			);
		}
		if indent.len() > ind.len() && indent.starts_with(ind) {
			// A skipped line's unopened level sits on top without opening
			// anything, so it does not count as a level in between.
			if stack.get(i + 1).is_some_and(|e| e.1 != UNOPENED) {
				break;
			}
			return (
				Some(if node == UNOPENED { DEAD } else { node }),
				Cut::To(i + 1),
			);
		}
		if node == UNOPENED {
			hold = Some(i);
		}
	}
	// Skipped, but it holds its own column: whatever is written deeper is
	// skipped with it, and a line back at it is refused the same way
	// instead of binding one level up. It closes nothing, so a later line
	// that matches a level open before it still binds there, as in 2.0.0.
	// The hold ends at the first line neither under it nor at it, this one
	// included, which keeps one on the stack at most.
	(None, Cut::Hold(hold))
}

/// How resolve_parent() cuts the stack: back to a length, or past a skipped
/// line's column to push this one's.
#[derive(Clone, Copy)]
enum Cut {
	To(usize),
	Hold(Option<usize>),
}

/// What became of a line the parser did not bind whole. Only the funnel
/// (`Parser::refuse`) reads it; the count and the level follow from it.
enum Outcome<'a> {
	/// The line binds; a value on it has nowhere to go and is gone.
	ValueDropped,
	/// Content-malformed: kept verbatim as trivia and written back in place,
	/// where it re-diagnoses identically and never reads as a binding.
	Retained { text: String, blank_before: bool },
	/// Read but not applicable here; re-emitted it could bind elsewhere, so
	/// it is gone and counts.
	Dropped,
	/// The parse stopped before this line; the rest was never read.
	Stopped(&'a [&'a str]),
}

impl<'a> Parser<'a> {
	fn new() -> Parser<'a> {
		Parser {
			arena: vec![NodeData {
				name: String::new(),
				value: Value::Empty,
				children: Vec::new(),
				parent: 0,
				line: 0,
				star_list: false,
				star_mixed: false,
				trivia: None,
				blank_before: false,
				src_set: false,
				src: None,
				name_src: String::new(),
			}],
			diags: Vec::new(),
			stack: vec![("", ROOT)],
			child_map: vec![None],
			disp_map: vec![None],
			pending: Vec::new(),
			pend_marks: Vec::new(),
			saw_blank: false,
			star_open: None,
			late_dups: Vec::new(),
			reentered: HashMap::new(),
			lost: 0,
			kept_owed: 0,
			kept_hold: None,
			kept_any: false,
			kept_arrays: false,
			src: Vec::new(),
			array_line: HashMap::new(),
			max_nodes: 0,
			max_elements: 0,
			max_diags: 0,
			unlisted: (0, 0),
			ends: Vec::new(),
			track_dropped: false,
			dropped: Vec::new(),
			lazies: Vec::new(),
		}
	}

	fn limited(max_nodes: usize, max_elements: usize, max_diags: usize) -> Parser<'a> {
		let mut p = Parser::new();
		p.max_nodes = max_nodes;
		p.max_elements = max_elements;
		p.max_diags = max_diags;
		p
	}

	/// Every parse diagnostic goes through here, so the cap sees them all.
	fn diag(&mut self, d: Diagnostic) {
		if self.max_diags != 0 && self.diags.len() >= self.max_diags {
			if d.severity == Severity::Error {
				self.unlisted.0 += 1;
			} else {
				self.unlisted.1 += 1;
			}
			return;
		}
		self.diags.push(d);
	}

	fn err(&mut self, line: usize, code: &'static str, msg: impl Into<String>) {
		let message = msg.into();
		self.diag(Diagnostic {
			line,
			severity: Severity::Error,
			message,
			code,
		});
	}

	/// The one exit for a line the parser does not bind whole. An arm says
	/// what became of the line and nothing else: the lost count and the
	/// level the line holds follow from the outcome here, so no arm can
	/// forget either. design.md's outcome table gives each code its row.
	fn refuse(
		&mut self,
		line: usize,
		code: &'static str,
		msg: impl Into<String>,
		outcome: Outcome,
		indent: &'a str,
	) {
		self.err(line, code, msg);
		let holds = matches!(outcome, Outcome::Retained { .. } | Outcome::Dropped);
		self.lost += match &outcome {
			Outcome::ValueDropped | Outcome::Dropped => 1,
			Outcome::Retained { .. } => 0,
			Outcome::Stopped(rest) => rest.iter().filter(|l| !trim_wsp(l).is_empty()).count(),
		};
		// Which line that was, for the save that keeps lines. Its parse has
		// no node cap, so it never stops early.
		if self.track_dropped && matches!(outcome, Outcome::ValueDropped | Outcome::Dropped) {
			self.dropped.push(line);
		}
		if let Outcome::Retained { text, blank_before } = outcome {
			// One Retained outcome makes one Pend, and each Pend becomes one
			// Lead, so right after a load kept_lines() equals this. An arm
			// that files a retained line nowhere breaks that, and the save
			// gate then refuses even a plain fmt --write, as it should.
			self.kept_owed += 1;
			// A line kept as written never hangs on a block: its indent is not
			// one the output's levels are written with, so the block it would
			// match here is not the one it matches on a reload. It waits for
			// the next binding line, as do the pending lines after it.
			let ceiling = if text.starts_with([' ', '\t']) {
				0
			} else {
				indent.len()
			};
			self.pending.push(Pend {
				text,
				indent,
				blank_before,
				ceiling,
				line,
			});
		}
		// A refused line owns its indent, so what is written deeper is skipped
		// with it (E018). An indent that matched no level already holds an
		// unopened one, which refuses a sibling the same way; that one stays.
		if holds && !matches!(self.stack.last(), Some((i, n)) if *i == indent && *n == UNOPENED) {
			self.stack.push((indent, DEAD));
		}
	}

	/// A field binds under an array line, which a field with lines under it
	/// cannot take (E028). The line is kept as written, written in place of
	/// the field's own, and the field is open with no value, as a line
	/// refused for its value alone opens it. When the line joined an earlier
	/// binding of the same value, that one keeps its value and the field
	/// opens on its own. Returns the field, which takes the level.
	fn array_under(&mut self, node: usize) -> usize {
		let mark = self.array_line.remove(&node);
		let line = mark.as_ref().map_or(self.arena[node].line, |m| m.line);
		let Some(src) = line.checked_sub(1).and_then(|k| self.src.get(k).copied()) else {
			return node;
		};
		let text = trim_wsp_end(src).trim_start_matches(is_wsp).to_string();
		self.err(
			line,
			"E028",
			"an array on a field with lines under it; the field takes one plain value or none",
		);
		self.kept_owed += 1;
		self.kept_arrays = true;
		if let Some(m) = mark.filter(|m| m.line != self.arena[node].line) {
			let (name, name_src, up) = (
				self.arena[node].name.clone(),
				self.arena[node].authored().to_string(),
				self.arena[node].parent,
			);
			// The lines this one brought to the binding it joined go with it,
			// and so do its blank and its comment, which its kept text has.
			let nd = &mut self.arena[node];
			let blank_before = nd.blank_before && !m.blank;
			nd.blank_before = m.blank;
			let t = nd.triv_mut();
			let mut moved = t.leading.split_off(m.leads.min(t.leading.len()));
			if !m.trailing {
				t.trailing.clear();
			} else {
				let mut tok = Tokens::default();
				tokenize(&text, b':', false, Rules::Current, &mut tok);
				if tok.comment.is_some() {
					moved.pop();
				}
			}
			let open = self.select_or_create(up, name, name_src, Value::Empty, line);
			moved.push(Lead {
				depth: 0,
				text,
				blank_before,
				line,
				kept: false,
			});
			self.arena[open].triv_mut().leading.extend(moved);
			if let Some(level) = self.stack.iter_mut().rev().find(|l| l.1 == node) {
				level.1 = open;
			}
			return open;
		}
		let old_key = merge_hash(&self.arena[node].name, &self.arena[node].value);
		let old_disp = disp_hash(&self.arena[node].name, &self.arena[node].value);
		let nd = &mut self.arena[node];
		nd.value = Value::Empty;
		nd.src = None;
		nd.src_set = false;
		let blank_before = std::mem::take(&mut nd.blank_before);
		let t = nd.triv_mut();
		t.trailing.clear();
		t.leading.push(Lead {
			depth: 0,
			text,
			blank_before,
			line,
			kept: false,
		});
		self.remap_child(node, old_key, old_disp);
		node
	}

	/// Find (or create by merge rule) the child of `parent` with this (name, value).
	fn select_or_create(
		&mut self,
		parent: usize,
		name: String,
		name_src: String,
		value: Value,
		line: usize,
	) -> usize {
		self.star_flush();
		let h = merge_hash(&name, &value);
		if let Some(slot) = self.child_map[parent].as_deref().and_then(|m| m.get(&h))
			&& let Some(c) = slot
				.first_match(|c| merge_eq(&self.arena[c].name, &self.arena[c].value, &name, &value))
		{
			return c;
		}
		let idx = self.arena.len();
		let hd = disp_hash(&name, &value);
		let name_src = spelled(&name, name_src);
		self.arena.push(NodeData {
			name,
			name_src,
			value,
			children: Vec::new(),
			parent,
			line,
			star_list: false,
			star_mixed: false,
			trivia: None,
			blank_before: false,
			src_set: false,
			src: None,
		});
		self.arena[parent].children.push(idx);
		self.child_map.push(None);
		self.disp_map.push(None);
		self.child_map[parent]
			.get_or_insert_with(Default::default)
			.entry(h)
			.and_modify(|s| s.push(idx))
			.or_insert(Slot::One(idx));
		self.disp_map[parent]
			.get_or_insert_with(Default::default)
			.entry(hd)
			.or_insert(idx);
		idx
	}

	/// Apply an open stacked list's deferred remap. Runs before any map lookup
	/// (and at end of parse), so both maps are always fresh when queried.
	fn star_flush(&mut self) {
		if let Some((node, key, disp)) = self.star_open.take() {
			self.remap_child(node, key, disp);
		}
	}

	/// A node's value mutated in place (empty field filled, star element added):
	/// move its map entry from the old key to the new one. First-wins on both
	/// sides so lookups keep matching the earliest sibling, like the scan did.
	fn remap_child(&mut self, node: usize, old_key: u64, old_disp: u64) {
		let parent = self.arena[node].parent;
		if let Some(m) = self.child_map[parent].as_deref_mut()
			&& let Some(slot) = m.get_mut(&old_key)
			&& slot.remove(node)
		{
			m.remove(&old_key);
		}
		let new_key = merge_hash(&self.arena[node].name, &self.arena[node].value);
		let already = self.child_map[parent]
			.as_deref()
			.and_then(|m| m.get(&new_key))
			.and_then(|s| {
				s.first_match(|c| {
					merge_eq(
						&self.arena[c].name,
						&self.arena[c].value,
						&self.arena[node].name,
						&self.arena[node].value,
					)
				})
			});
		if already.is_none() {
			self.child_map[parent]
				.get_or_insert_with(Default::default)
				.entry(new_key)
				.and_modify(|s| s.push(node))
				.or_insert(Slot::One(node));
		} else {
			self.late_dups.push(parent);
		}
		if let Some(m) = self.disp_map[parent].as_deref_mut()
			&& m.get(&old_disp) == Some(&node)
		{
			m.remove(&old_disp);
		}
		let new_disp = disp_hash(&self.arena[node].name, &self.arena[node].value);
		self.disp_map[parent]
			.get_or_insert_with(Default::default)
			.entry(new_disp)
			.or_insert(node);
	}

	/// A value that mutates after its sibling group was keyed - an empty field
	/// filled by a fence, a stacked list closed - can end up on a key an earlier
	/// sibling already holds, which the keyed lookup can no longer catch. Fold
	/// those pairs so the tree matches a reparse of its own canonical text.
	/// Only the parents remap_child flagged can hold one. Shallowest first,
	/// since a fold hands the survivor more children and the order they
	/// arrive in decides whose trailing comment wins; folding keeps depths.
	fn fold_late_dups(&mut self) {
		let mut parents: Vec<(usize, usize)> = std::mem::take(&mut self.late_dups)
			.into_iter()
			.map(|p| {
				let (mut depth, mut n) = (0, p);
				while n != ROOT {
					n = self.arena[n].parent;
					depth += 1;
				}
				(depth, p)
			})
			.collect();
		parents.sort_unstable();
		parents.dedup();
		for (_, p) in parents {
			self.fold_dups_from(p);
		}
	}

	/// Depth-first below start, and only into survivors: a fold moves the
	/// loser's children up to join the survivor's, where they can pair. A fold
	/// hints the way a merge at parse time does (select_or_create): when the
	/// two were not next to each other, or sit under a hinted re-open
	/// (20260923 item 11).
	fn fold_dups_from(&mut self, start: usize) {
		let mut stack = vec![start];
		while let Some(parent) = stack.pop() {
			let kids = std::mem::take(&mut self.arena[parent].children);
			// Keyed to positions in keep, so a survivor's grew flag sits beside it.
			let mut first: U64Map<Slot> =
				U64Map::with_capacity_and_hasher(kids.len(), Default::default());
			let mut keep: Vec<usize> = Vec::with_capacity(kids.len());
			let mut grew: Vec<bool> = Vec::with_capacity(kids.len());
			for c in kids {
				let h = merge_hash(&self.arena[c].name, &self.arena[c].value);
				let hit = first.get(&h).and_then(|s| {
					s.first_match(|x| {
						merge_eq(
							&self.arena[keep[x]].name,
							&self.arena[keep[x]].value,
							&self.arena[c].name,
							&self.arena[c].value,
						)
					})
				});
				match hit {
					Some(i) => {
						// Apart when a sibling kept since stands between them,
						// as a merge at parse time asks of the newest child.
						self.hint_fold(parent, keep[i], c, i + 1 != keep.len());
						fold_node_into(&mut self.arena, keep[i], c);
						grew[i] = true;
					}
					None => {
						first
							.entry(h)
							.and_modify(|s| s.push(keep.len()))
							.or_insert(Slot::One(keep.len()));
						keep.push(c);
						grew.push(false);
					}
				}
			}
			for (i, &g) in grew.iter().enumerate() {
				if g {
					stack.push(keep[i]);
				}
			}
			self.arena[parent].children = keep;
		}
	}

	fn hint_fold(&mut self, parent: usize, kept: usize, gone: usize, apart: bool) {
		let (at, line) = (self.arena[kept].line, self.arena[gone].line);
		let cross_region = self.reentered.get(&parent).is_some_and(|&rl| at < rl);
		if at != line && (apart || cross_region) {
			let message = format!(
				"{}line {} (same name and value combine)",
				h002_head(&self.arena[kept].name),
				at
			);
			self.diag(Diagnostic {
				line,
				severity: Severity::Hint,
				message,
				code: "H002",
			});
			self.reentered.insert(kept, line);
		}
	}

	/// Hand pending leading comments (and this line's trailing one) to a node.
	/// First trailing wins; a later one demotes to leading so nothing is lost.
	fn attach_trivia(&mut self, node: usize, indent: &str, trailing: Option<&str>) {
		if !self.pending.is_empty() {
			let t = self.arena[node].triv_mut();
			let (mut chain, mut held) = (Vec::new(), Vec::new());
			for p in self.pending.drain(..) {
				t.leading.push(Lead {
					depth: comment_depth(&mut chain, &mut held, indent, &p.text, p.indent),
					text: p.text,
					blank_before: p.blank_before,
					line: p.line,
					kept: false,
				});
			}
			self.pend_marks.clear();
		}
		if let Some(tr) = trailing {
			let t = self.arena[node].triv_mut();
			if t.trailing.is_empty() {
				t.trailing = tr.to_string();
			} else {
				t.leading.push(Lead::plain(tr.to_string()));
			}
		}
	}

	/// Comments written deeper than the incoming line belong to the block they
	/// sit in, not to the next binding: hang each on the deepest node whose
	/// bound indent prefixes the comment's, among the levels the incoming
	/// line is closing. Written at that node's own level the comment trails
	/// it (`after`); written deeper it sits inside the node's block
	/// (`inside`) - so a header whose children are all commented still owns
	/// them at their depth. Runs before the incoming line resolves (and at
	/// end of parse with the empty indent, so tail comments keep their block).
	fn hang_deeper_pending(&mut self, new_indent: &str) {
		if self.pending.is_empty() {
			return;
		}
		let new_len = new_indent.len();
		// Only entries above the last mark at or under this indent can hang.
		while self.pend_marks.last().is_some_and(|m| m.1 > new_len) {
			self.pend_marks.pop();
		}
		let start = self.pend_marks.last().map_or(0, |m| m.0);
		// Filtered in place: a kept entry is swapped back to the write mark,
		// which never passes the one being read.
		let mut pending = std::mem::take(&mut self.pending);
		let mut w = start;
		// A comment never goes ahead of the one written before it. Once one
		// stays for the incoming line every later one stays too, and one
		// whose block would be written out before the last one's goes there
		// with it instead. What sits before `start` stays, so no comment
		// after it can hang. A kept field line is the exception below.
		let mut kept = start > 0;
		// Where the last comment went: (stack index, node, at its own level).
		let mut last: Option<(usize, usize, bool)> = None;
		let mut chain: Vec<(&str, usize)> = Vec::new();
		let mut held: Vec<(&str, usize)> = Vec::new();
		let mut last_field: Option<(usize, usize, bool)> = None;
		for r in start..pending.len() {
			let p = &mut pending[r];
			// A kept field line goes to the block it sits in whatever stays
			// before it, since that block is its parent on a reload. Comments
			// give way to it.
			let field = is_field(&p.text);
			if (!kept || field) && p.ceiling > new_len {
				// A level shallower than the incoming line stays open and may
				// still gain children, so a comment must not hang there - it
				// would emit below the child; keep it pending instead.
				let target = self
					.stack
					.iter()
					.enumerate()
					.rev()
					.find(|(_, (ind, node))| {
						*node != ROOT
							&& *node != DEAD && *node != UNOPENED
							&& *node != LAZY && ind.len() >= new_indent.len()
							&& p.indent.starts_with(*ind)
					})
					// A list element's column is an entry with the list's node on
					// the list's own entry. It is inside the list, not its level.
					.map(|(si, (ind, n))| {
						let column = si > 0 && self.stack[si - 1].1 == *n;
						(si, *n, ind.len() == p.indent.len() && !column)
					});
				// A root node's trailing comment emits at column zero, which
				// is exactly how the document's own trailing comment is
				// written, so keeping the two apart here made a merge depend on
				// whether the layer had been formatted first. Let it orphan,
				// the way a reload of this document's own output reads it. A
				// comment deeper than the node keeps an indent of its own and
				// comes back where it was, so it still hangs.
				let expressible =
					target.is_some_and(|(_, n, own)| !own || self.arena[n].parent != ROOT);
				if let (Some(mut at), true) = (target, expressible) {
					// A deeper block is written out first, and a block's
					// inside comments before its after ones.
					if let Some(prev) = last
						&& !field && (at.0, !at.2) > (prev.0, !prev.2)
					{
						at = prev;
					}
					if last != Some(at) {
						chain.clear();
					}
					last = Some(at);
					// A kept line's parent goes to the same block it does,
					// whatever block the comments between them went to.
					if field && last_field != Some(at) {
						held.clear();
						last_field = Some(at);
					}
					let base = self.stack[at.0].0;
					let mut leads = Vec::new();
					// The comments that stayed right above it go along, so the
					// two keep their order and a save can keep both lines.
					if field {
						let mut from = w;
						while from > start && pending[from - 1].text.starts_with('#') {
							from -= 1;
						}
						for c in &mut pending[from..w] {
							leads.push(Lead {
								depth: comment_depth(
									&mut chain, &mut held, base, &c.text, c.indent,
								),
								text: std::mem::take(&mut c.text),
								blank_before: c.blank_before,
								line: c.line,
								kept: false,
							});
						}
						w = from;
						kept = w > 0;
					}
					let p = &mut pending[r];
					leads.push(Lead {
						depth: comment_depth(&mut chain, &mut held, base, &p.text, p.indent),
						text: std::mem::take(&mut p.text),
						blank_before: p.blank_before,
						line: p.line,
						kept: false,
					});
					let t = self.arena[at.1].triv_mut();
					if at.2 {
						t.after.extend(leads);
					} else {
						t.inside.extend(leads);
					}
					continue;
				}
			}
			kept = true;
			p.ceiling = p.ceiling.min(new_len);
			pending.swap(w, r);
			w += 1;
		}
		pending.truncate(w);
		self.pending = pending;
		match self.pend_marks.last_mut() {
			Some(m) if m.1 == new_len => m.0 = self.pending.len(),
			_ => self.pend_marks.push((self.pending.len(), new_len)),
		}
	}

	/// Resolve which open level this indent belongs to, walking down from the
	/// top. Equal to a level is its sibling. Deeper than a level is its child,
	/// unless a level opened under that one is still open, in which case the
	/// line falls between the two. Anything else is a recoverable error.
	/// `found` is locate() on the same indent, which the line loop has
	/// already asked.
	fn resolve_parent(&mut self, indent: &'a str, found: (Option<usize>, Cut)) -> Option<usize> {
		let (parent, cut) = found;
		match cut {
			Cut::To(n) => self.stack.truncate(n),
			Cut::Hold(h) => {
				if let Some(h) = h {
					self.stack.truncate(h);
				}
				self.stack.push((indent, UNOPENED));
			}
		}
		parent
	}

	/// resolve_parent() without moving anything.
	fn locate(&self, indent: &str) -> (Option<usize>, Cut) {
		locate_in(&self.stack, indent)
	}

	/// A line refused for where it sits rather than for what it says: `E012`,
	/// or `E018` under one. Written back exactly as it was, it sits the same
	/// way on a reload, as long as its indent holds a space, since no level
	/// the emitter opens is written with one. A tab-only indent would bind
	/// there, and a line opening a raw block would take its body along, so
	/// those are dropped. An `E018` line is kept only under a kept `E012` one.
	fn misplaced(
		&mut self,
		line: usize,
		code: &'static str,
		indent: &'a str,
		rest: &str,
		had_blank: bool,
		raw: bool,
	) {
		let keep = !raw
			&& if code == "E012" {
				indent.contains(' ')
			} else {
				self.kept_hold
					.is_some_and(|h| indent.len() > h.len() && indent.starts_with(h))
			};
		self.kept_any |= keep;
		let msg = if code == "E012" {
			self.kept_hold = keep.then_some(indent);
			"indentation matches no open level"
		} else {
			"parent line was skipped; line skipped"
		};
		let outcome = if keep {
			Outcome::Retained {
				text: format!("{}{}", indent, trim_wsp_end(rest)),
				blank_before: had_blank,
			}
		} else {
			Outcome::Dropped
		};
		self.refuse(line, code, msg, outcome, indent);
	}

	/// Diagnose a line written under a skipped line, and skip it too. Its own
	/// level stays dead so deeper lines go the same way.
	fn skip_under_dead(&mut self, line: usize, indent: &'a str) {
		self.refuse(
			line,
			"E018",
			"parent line was skipped; line skipped",
			Outcome::Dropped,
			indent,
		);
	}

	/// A field line refused for its value alone holds its level open for
	/// what is written under it. Called right after the refusal pushed the
	/// line's level. A path that could not open, or would open past the
	/// nesting cap, leaves the level dead.
	fn hold_open(&mut self, parent: usize, segs: Vec<Segment>, line: usize, indent: &'a str) {
		let at = self.stack.len() - 1;
		if self.stack[at] != (indent, DEAD) || !segs.iter().all(opens_as_written) {
			return;
		}
		self.lazies.retain(|l| l.at < at);
		let mut depth = 0;
		if parent == LAZY {
			depth = self.lazies.last().map_or(0, |l| l.depth);
		} else {
			let mut up = parent;
			while up != ROOT {
				depth += 1;
				up = self.arena[up].parent;
			}
		}
		if depth + segs.len() > MAX_DEPTH {
			return;
		}
		self.stack[at].1 = LAZY;
		self.lazies.push(Lazy {
			at,
			depth: depth + segs.len(),
			segs,
			line,
			indent,
			pend: self.pending.len(),
		});
	}

	/// The node a line binds under: a LAZY level, and any LAZY one it sits
	/// under, opens here as an empty field, the way its line would have
	/// bound with nothing after the colon. Its own line and the comments
	/// before it go with it.
	fn open_lazy(&mut self, parent: usize) -> usize {
		if parent != LAZY {
			return parent;
		}
		let top = self.stack.len() - 1;
		let mut from = top;
		while from > 1 && self.stack[from - 1].1 == LAZY {
			from -= 1;
		}
		let mut node = self.stack[from - 1].1;
		for at in from..=top {
			let Some(k) = self.lazies.iter().rposition(|l| l.at == at) else {
				break;
			};
			let l = self.lazies.remove(k);
			let nsegs = l.segs.len();
			// hold_open() let through only a path that opens.
			if let Some(n) = self.attach_path(node, l.segs, Value::Empty, l.line, l.indent) {
				node = n;
			}
			self.stack[at].1 = node;
			let count = l.pend.min(self.pending.len());
			self.give_pending(self.head_of(node, nsegs), l.indent, count, false);
		}
		node
	}

	/// The node a path's first segment bound, from the one its last did.
	fn head_of(&self, node: usize, nsegs: usize) -> usize {
		let mut head = node;
		for _ in 1..nsegs {
			head = self.arena[head].parent;
		}
		head
	}

	/// The first `count` pending lines become the node's leading lines, or
	/// the lines inside its block, after its children.
	fn give_pending(&mut self, node: usize, indent: &str, count: usize, inside: bool) {
		if count == 0 {
			return;
		}
		let t = self.arena[node].triv_mut();
		let list = if inside {
			&mut t.inside
		} else {
			&mut t.leading
		};
		let (mut chain, mut held) = (Vec::new(), Vec::new());
		for p in self.pending.drain(..count) {
			list.push(Lead {
				depth: comment_depth(&mut chain, &mut held, indent, &p.text, p.indent),
				text: p.text,
				blank_before: p.blank_before,
				line: p.line,
				kept: false,
			});
		}
		for m in &mut self.pend_marks {
			m.0 = m.0.saturating_sub(count);
		}
		for o in &mut self.lazies {
			o.pend = o.pend.saturating_sub(count);
		}
	}

	/// Where the parse resumes after a refused field line. Every arm that
	/// skips one comes through here, so a skipped line whose value opens a
	/// raw block takes the body with it: read as lines, the body would bind
	/// or be refused line by line, and its closing fence would open a block
	/// that runs to the end of the file. A line whose path did not parse
	/// takes it too, when a fence follows its colon (`line_fence`).
	fn skip_field_line(
		&mut self,
		lines: &[&str],
		i: usize,
		indent: &str,
		tok: &Tokens,
		rest: &str,
	) -> usize {
		match line_fence(tok, rest) {
			Some(fence) => self.consume_raw(lines, i + 1, i + 1, indent, fence).1,
			None => i + 1,
		}
	}

	/// skip_field_line() for a line the refusal just kept: the body is kept
	/// too, on the end of the line's text, so a save writes it back under its
	/// line and the load still holds one kept line for it. As in a field's
	/// block, the closing fence's indent comes off each body line, and the
	/// body goes one level under the line when it is written. A block that
	/// never closed gets its closing fence, or whatever a save writes after it
	/// would read as its body.
	fn keep_body(
		&mut self,
		lines: &[&str],
		i: usize,
		indent: &str,
		tok: &Tokens,
		rest: &str,
	) -> usize {
		let Some(fence) = line_fence(tok, rest) else {
			return i + 1;
		};
		let (ch, len) = (fence.0, fence.1);
		let next = self.consume_raw(lines, i + 1, i + 1, indent, fence).1;
		let closed = next > i + 1 && is_fence_close(lines[next - 1], ch, len);
		let (body, nest, close) = if closed {
			let fence_line = lines[next - 1];
			(
				&lines[i + 1..next - 1],
				leading_ws(fence_line),
				fence_line.trim_matches([' ', '\t']).to_string(),
			)
		} else {
			(
				&lines[i + 1..next],
				indent,
				std::iter::repeat_n(char::from(ch), len).collect(),
			)
		};
		let Some(p) = self.pending.last_mut() else {
			return next;
		};
		for l in body {
			p.text.push('\n');
			p.text.push_str(strip_common(l, nest));
		}
		p.text.push('\n');
		p.text.push_str(&close);
		if next > i + 1 {
			self.ends.push((i + 1, next));
		}
		next
	}

	/// Walk path segments under `parent`, select-or-creating; returns the node
	/// for the last segment with `value`. None aborts the line (diagnosed).
	fn attach_path(
		&mut self,
		parent: usize,
		segs: Vec<Segment>,
		value: Value,
		line: usize,
		indent: &'a str,
	) -> Option<usize> {
		// Owned here and handed to the last segment once; Option so the loop
		// can move it out without a clone.
		let mut value = Some(value);
		self.star_flush();
		let parent = if parent != ROOT
			&& !self.arena[parent].star_list
			&& matches!(self.arena[parent].value, Value::Array(_))
		{
			self.array_under(parent)
		} else {
			parent
		};
		// Field child under a stacked list: diagnose the mix once, keep the field.
		if self.arena[parent].star_list && !self.arena[parent].star_mixed {
			self.arena[parent].star_mixed = true;
			self.err(line, "E001", "field mixed with list elements");
		}
		// Nesting cap: parent depth plus the segments this line adds. Checked
		// before any node is created so a rejected line leaves nothing behind.
		let mut parent_depth = 0usize;
		let mut up = parent;
		while up != ROOT {
			parent_depth += 1;
			up = self.arena[up].parent;
		}
		if parent_depth + segs.len() > MAX_DEPTH {
			self.refuse(
				line,
				"E016",
				format!("nesting deeper than {} levels; line skipped", MAX_DEPTH),
				Outcome::Dropped,
				indent,
			);
			return None;
		}
		let mut cur = parent;
		let nsegs = segs.len();
		for (i, seg) in segs.into_iter().enumerate() {
			let is_last = i + 1 == nsegs;
			match (seg.selector, is_last) {
				(Some(Selector::ByValue { text, quoted }), _) => {
					// Same escape-applied display predicate resolve_from uses, so
					// a selector also selects an array-valued instance instead of
					// creating a spurious second one - via the disp_map accelerator
					// (the inline spelling was quadratic in siblings without it).
					// Create only when nothing matches.
					// A quoted selector is scalar-only, so it is the one that needs the
					// fallback scan: the accelerator keeps just the first same-display
					// child, which may be the non-scalar one. An unquoted selector takes
					// whatever the accelerator holds and does not scan, so it can bind a
					// raw block where a quoted selector picks the scalar sibling.
					let found = self.find_by_value(cur, &seg.name, &text, quoted);
					cur = match found {
						Some(c) => c,
						None => {
							let disc = Value::Cell(new_element(text));
							self.select_or_create(
								cur,
								seg.name.clone(),
								seg.name_src.clone(),
								disc,
								line,
							)
						}
					};
					if is_last && value.as_ref().is_some_and(|v| !v.is_empty()) {
						// `a.b[X]: v` - the discriminator is the value; a second
						// value has nowhere unambiguous to go.
						self.refuse(
							line,
							"E002",
							format!("value after selector on '{}' ignored", diag_name(&seg.name)),
							Outcome::ValueDropped,
							indent,
						);
					}
				}
				(Some(Selector::ByIndex(n)), _) => {
					let found = index_usize(n).and_then(|i| {
						self.arena[cur]
							.children
							.iter()
							.copied()
							.filter(|&c| self.arena[c].name == seg.name)
							.nth(i)
					});
					if let Some(found) = found {
						cur = found;
					} else {
						self.refuse(
							line,
							"E003",
							format!("no instance {} of '{}'", n, diag_name(&seg.name)),
							Outcome::Dropped,
							indent,
						);
						return None;
					}
					if is_last && value.as_ref().is_some_and(|v| !v.is_empty()) {
						// Same as the value selector: the instance is already
						// chosen, so a trailing value has nowhere to bind.
						self.refuse(
							line,
							"E002",
							format!("value after selector on '{}' ignored", diag_name(&seg.name)),
							Outcome::ValueDropped,
							indent,
						);
					}
				}
				(Some(Selector::Wildcard), _) => {
					self.refuse(
						line,
						"E004",
						"wildcard selector is query-only",
						Outcome::Dropped,
						indent,
					);
					return None;
				}
				(None, false) => {
					cur = self.select_or_create(cur, seg.name, seg.name_src, Value::Empty, line);
				}
				(None, true) => {
					let parent = cur;
					let before = self.arena.len();
					let v = value.take().unwrap_or(Value::Empty);
					cur = self.select_or_create(cur, seg.name, seg.name_src, v, line);
					// Two separately-written bindings just combined: legal (the
					// merge rule), but only the parser can see it happened, so
					// say so. Adjacent re-mentions (still the newest binding at
					// this scope) and selector/path-intermediate merges stay
					// silent - those are the deliberate redundant-path idiom.
					// Under a hinted container the newest-child pass does not
					// apply to children the earlier region wrote: those merges
					// combine the same two regions, so every level reports.
					if cur < before && self.arena[cur].line != line {
						let non_last = self.arena[parent].children.last() != Some(&cur);
						let cross_region = self
							.reentered
							.get(&parent)
							.is_some_and(|&rl| self.arena[cur].line < rl);
						if non_last || cross_region {
							let at = self.arena[cur].line;
							let message = format!(
								"{}line {} (same name and value combine)",
								h002_head(&self.arena[cur].name),
								at
							);
							self.diag(Diagnostic {
								line,
								severity: Severity::Hint,
								message,
								code: "H002",
							});
							self.reentered.insert(cur, line);
						}
					}
				}
			}
		}
		Some(cur)
	}

	/// The child of `cur` named `name` whose display form is the selector text
	/// (escapes applied), or None. Quoted selectors only match a single scalar.
	fn find_by_value(&self, cur: usize, name: &str, text: &str, quoted: bool) -> Option<usize> {
		let want = text;
		self.disp_map[cur]
			.as_deref()
			.and_then(|m| m.get(&disp_hash_text(name, want)))
			.copied()
			.filter(|&c| self.arena[c].name == name && disp_key(&self.arena[c].value) == want)
			.filter(|&c| !quoted || single_scalar(&self.arena[c].value))
			.or_else(|| {
				// The display map keeps only the first same-display child, which
				// may be an array where a quoted selector wants the scalar. A
				// scalar child with this text is exactly the one-element value
				// the merge map is keyed on, so ask that map: a scan of every
				// sibling was the same answer, quadratic on the create path.
				if !quoted {
					return None;
				}
				let disc = Value::Cell(new_element(want.to_string()));
				self.child_map[cur]
					.as_deref()
					.and_then(|m| m.get(&merge_hash(name, &disc)))
					.and_then(|slot| {
						slot.first_match(|c| {
							merge_eq(&self.arena[c].name, &self.arena[c].value, name, &disc)
						})
					})
			})
	}

	/// Consume raw-block content after an opening fence. Returns (value, next line
	/// index). The closing fence's indent is stripped from each content line
	/// (the opening line's when the block never closes); the rest is content.
	fn consume_raw(
		&mut self,
		lines: &[&str],
		mut i: usize,
		open_line: usize,
		open_indent: &str,
		fence: (u8, usize, String),
	) -> (Value, usize) {
		let (ch, len, info) = fence;
		let mut content: Vec<&str> = Vec::new();
		let mut nest = open_indent;
		let mut closed = false;
		while i < lines.len() {
			if is_fence_close(lines[i], ch, len) {
				// The closing fence's indent is the nesting; everything a content
				// line has past it is content, so a body whose lines all
				// share an indent keeps it (a writer-built block depends on that).
				nest = leading_ws(lines[i]);
				closed = true;
				i += 1;
				break;
			}
			content.push(lines[i]);
			i += 1;
		}
		if !closed {
			self.err(open_line, "E005", "unterminated raw block");
		}
		let stripped: Vec<&str> = content.iter().map(|l| strip_common(l, nest)).collect();
		(
			Value::Raw(Box::new(RawVal {
				content: stripped.join("\n"),
				info,
				fence_char: ch,
				fence_len: len,
			})),
			i,
		)
	}

	/// A bare fence line is a value line for its parent field: fills an empty
	/// value, else creates a new instance of that field (the repeated-leaf rule).
	/// Returns the node the block ended up on (None = no parent, diagnosed).
	fn bind_block(
		&mut self,
		parent: usize,
		value: Value,
		line: usize,
		indent: &'a str,
	) -> Option<usize> {
		if parent == ROOT {
			self.refuse(
				line,
				"E006",
				"raw block with no parent field",
				Outcome::Dropped,
				indent,
			);
			return None;
		}
		if self.arena[parent].value.is_empty() {
			let old_key = merge_hash(&self.arena[parent].name, &self.arena[parent].value);
			let old_disp = disp_hash(&self.arena[parent].name, &self.arena[parent].value);
			self.arena[parent].value = value;
			self.remap_child(parent, old_key, old_disp);
			Some(parent)
		} else {
			// Copied out: select_or_create takes the arena mutably.
			let (name, name_src, grandparent) = (
				self.arena[parent].name.clone(),
				self.arena[parent].authored().to_string(),
				self.arena[parent].parent,
			);
			Some(self.select_or_create(grandparent, name, name_src, value, line))
		}
	}

	/// One stacked-list item (`- scalar`) appends to the parent's array.
	fn add_star_element(
		&mut self,
		parent: usize,
		tok: &Tokens,
		text: &str,
		line: usize,
		indent: &'a str,
	) -> bool {
		if parent == ROOT {
			self.refuse(
				line,
				"E007",
				"list element with no parent field",
				Outcome::Dropped,
				indent,
			);
			return false;
		}
		// Uniform-or-nothing (spec): a mix with field children is not a block array.
		if !self.arena[parent].children.is_empty() {
			self.refuse(
				line,
				"E008",
				"list element mixed with field children; ignored",
				Outcome::Dropped,
				indent,
			);
			return false;
		}
		let piece = tok.elements[0];
		let Some(el) = element_of(&piece, text) else {
			self.refuse(line, "E009", "empty list element", Outcome::Dropped, indent);
			return false;
		};
		let clash = unit_clash(&self.arena[parent].name, &el.text);
		// Element cap: each element line past it is refused on its own, the way
		// any other bad element line is. Only a line that would join the list:
		// under a field that already has a value it is E011, cap or not.
		if self.max_elements != 0
			&& self.arena[parent].star_list
			&& let Value::Array(els) = &self.arena[parent].value
			&& els.len() >= self.max_elements
		{
			self.refuse(
				line,
				"E021",
				format!(
					"array longer than {} elements; line skipped",
					self.max_elements
				),
				Outcome::Dropped,
				indent,
			);
			return false;
		}
		if self.arena[parent].value.is_empty() {
			let old_key = merge_hash(&self.arena[parent].name, &self.arena[parent].value);
			let old_disp = disp_hash(&self.arena[parent].name, &self.arena[parent].value);
			self.arena[parent].value = Value::Array(vec![el]);
			self.arena[parent].star_list = true;
			// First element: remap now (Empty -> cell changes both keys), then
			// open the deferral window with the current keys. Rebuilding the
			// keys per appended element was O(list^2) time; the maps only need
			// to be fresh when queried, and every query flushes first.
			self.remap_child(parent, old_key, old_disp);
			let k = merge_hash(&self.arena[parent].name, &self.arena[parent].value);
			let d = disp_hash(&self.arena[parent].name, &self.arena[parent].value);
			self.star_open = Some((parent, k, d));
		} else if matches!(self.arena[parent].value, Value::Array(_))
			&& self.arena[parent].star_list
		{
			if !matches!(self.star_open, Some((n, _, _)) if n == parent) {
				self.star_flush();
				let old_key = merge_hash(&self.arena[parent].name, &self.arena[parent].value);
				let old_disp = disp_hash(&self.arena[parent].name, &self.arena[parent].value);
				self.star_open = Some((parent, old_key, old_disp));
			}
			if let Value::Array(els) = &mut self.arena[parent].value {
				els.push(el);
			}
		} else {
			self.refuse(
				line,
				"E011",
				"field already has a value; list element ignored",
				Outcome::Dropped,
				indent,
			);
			return false;
		}
		if let Some(m) = clash {
			self.diag(Diagnostic {
				line,
				severity: Severity::Hint,
				message: m,
				code: "H005",
			});
		}
		// A kept element holds its column as a dropped one does, with the field
		// as that level's node: a line written deeper binds where it always did,
		// and a line back at the element's column is its sibling, where no level
		// had been opened there and every later sibling was E012 (20260918b
		// item 28).
		self.stack.push((indent, parent));
		true
	}

	/// Lines waiting for the list element that just joined sat among the
	/// list's elements, so they stay there, comments and kept lines alike.
	fn keep_among(&mut self, parent: usize, indent: &str) {
		if self.pending.is_empty() {
			return;
		}
		let before = match &self.arena[parent].value {
			Value::Array(els) => els.len() - 1,
			_ => return,
		};
		let (mut chain, mut held) = (Vec::new(), Vec::new());
		for p in self.pending.drain(..) {
			self.arena[parent].triv_mut().among.push((
				before,
				Lead {
					depth: comment_depth(&mut chain, &mut held, indent, &p.text, p.indent),
					text: p.text,
					blank_before: p.blank_before,
					line: 0,
					kept: false,
				},
			));
		}
		self.pend_marks.clear();
	}

	/// Legal input that looks like a common mistake: a field repeating as a bare
	/// scalar leaf. Mandatory hint per spec (never fails a load).
	fn emit_repeated_leaf_hints(&mut self) {
		let mut hints: Vec<(usize, String)> = Vec::new();
		for parent in 0..self.arena.len() {
			let children = &self.arena[parent].children;
			if children.len() < 2 {
				continue;
			}
			// Group by name in first-appearance order: hint order must be
			// deterministic or the cross-binding check can't compare `check` output.
			// The member list is made only when a name repeats. Nearly every
			// name is seen once, and a list per child was most of what this
			// pass allocated.
			let mut group_of: HashMap<&str, usize> = HashMap::new();
			let mut by_name: Vec<(&str, usize, Vec<usize>)> = Vec::new();
			for &c in children {
				let name = self.arena[c].name.as_str();
				match group_of.get(name) {
					Some(&g) => {
						let grp = &mut by_name[g];
						if grp.2.is_empty() {
							grp.2.push(grp.1);
						}
						grp.2.push(c);
					}
					None => {
						group_of.insert(name, by_name.len());
						by_name.push((name, c, Vec::new()));
					}
				}
			}
			for (name, _, group) in by_name {
				if group.is_empty() {
					continue;
				}
				let all_scalar_leaves = group.iter().all(|&c| {
					self.arena[c].children.is_empty()
						&& matches!(self.arena[c].value, Value::Cell(_))
				});
				if all_scalar_leaves {
					let line = group.iter().map(|&c| self.arena[c].line).max().unwrap_or(0);
					let joined = group
						.iter()
						.map(|&c| diag_value(&self.arena[c].value))
						.collect::<Vec<_>>()
						.join(", ");
					hints.push((line, format!("{}[{}]'?", h001_head(name), joined)));
				}
			}
		}
		for (line, message) in hints {
			self.diag(Diagnostic {
				line,
				severity: Severity::Hint,
				message,
				code: "H001", // repeated bare leaf
			});
		}
	}

	fn parse(mut self, text: &'a str, strictness: Strictness) -> Document {
		// UTF-8 BOM strip, then split keeping raw lines (CR stripped per line).
		// Lines borrow `text`: they are only read, so no owned copies needed.
		// The whole trailing CR run goes, not just one: a raw block keeps its
		// content untrimmed, so a line left ending in CR would be written back as
		// CRLF and read as neither - the one shape where the count is visible.
		let text = text.strip_prefix('\u{feff}').unwrap_or(text);
		let mut lines: Vec<&str> = text.split('\n').map(|l| l.trim_end_matches('\r')).collect();
		// A newline-terminated text splits into one more piece than it has
		// lines. An unterminated raw block took that empty tail as a body
		// line, so the same last line read differently with and without its
		// newline, which the grammar says are one document.
		if text.ends_with('\n') {
			lines.pop();
		}
		self.src = lines.clone();
		let mut i = 0usize;
		let mut node_capped = false;
		let mut tok = Tokens {
			cap: self.max_elements,
			..Tokens::default()
		};
		while i < lines.len() {
			// Node cap: reported at the first line not parsed, so the count can
			// overshoot by at most one line's path. The unparsed remainder counts
			// as lost, which is what keeps save_file from writing a silently
			// truncated document.
			if self.max_nodes != 0 && self.arena.len() - 1 > self.max_nodes {
				self.refuse(
					i + 1,
					"E020",
					format!("node cap of {} exceeded; parse stopped", self.max_nodes),
					Outcome::Stopped(&lines[i..]),
					"",
				);
				node_capped = true;
				break;
			}
			let lineno = i + 1;
			let line = trim_wsp_end(lines[i]);
			// Indent chars are ASCII space/tab, so a byte scan slices the same run.
			let ilen = line
				.bytes()
				.take_while(|&b| b == b' ' || b == b'\t')
				.count();
			let indent = &line[..ilen];
			// A carriage return is a blank but never indent, so a run of blanks
			// holding one comes off the front of the rest instead.
			let rest = line[ilen..].trim_start_matches(is_wsp);
			let lead = line.len() - ilen - rest.len();
			if rest.is_empty() {
				self.saw_blank = true;
				i += 1;
				continue;
			}
			// Whole-line comment: hold it for the next line that binds a node.
			// It consumes a pending blank into its own flag, so a blank between
			// comment-only regions survives the round-trip.
			if rest.starts_with('#') {
				self.pending.push(Pend {
					text: rest.to_string(),
					indent,
					blank_before: std::mem::take(&mut self.saw_blank),
					ceiling: indent.len(),
					line: lineno,
				});
				i += 1;
				continue;
			}
			// A kept misplaced line holds only the lines written under it.
			if self
				.kept_hold
				.is_some_and(|h| !(indent.len() > h.len() && indent.starts_with(h)))
			{
				self.kept_hold = None;
			}
			// Any other line consumes the pending blank; only a field line that
			// binds turns it into grouping.
			let had_blank = std::mem::take(&mut self.saw_blank);
			// A binding line claims the pending comments - but deeper-written
			// ones hang on their own block first. A line refused for where it
			// sits closes nothing, so it leaves them for the next line: kept,
			// its indent would measure the levels differently on a reload,
			// and dropped, a reload never sees it.
			let found = self.locate(indent);
			let placed = found.0.is_some_and(|p| p != DEAD);
			if placed {
				self.hang_deeper_pending(indent);
			}
			// Child-indent fence: a value line for its parent field. The fence
			// and its info string are the value; a comment may follow them.
			if rest.starts_with(['`', '~'])
				&& let Some(fence) = child_fence(rest, &mut tok)
			{
				let comment = tok.comment.map(|c| &rest[c..]);
				let parent = self.resolve_parent(indent, found);
				let (value, next) = self.consume_raw(&lines, i + 1, lineno, indent, fence);
				let Some(parent) = parent else {
					// The body goes with its fence: parsed live, it would read as
					// root bindings and the closing fence would open a second block.
					self.refuse(
						lineno,
						"E012",
						"indentation matches no open level",
						Outcome::Dropped,
						indent,
					);
					i = next;
					continue;
				};
				if parent == DEAD {
					self.skip_under_dead(lineno, indent);
				} else if tok.capped {
					// The block goes with its line, or the body would read as
					// live lines.
					self.refuse(
						lineno,
						"E021",
						format!(
							"array longer than {} elements; line skipped",
							self.max_elements
						),
						Outcome::Dropped,
						indent,
					);
				} else {
					let parent = self.open_lazy(parent);
					// The fence binds its field again, so a kept field line
					// before it, which sits under that field, stays in the
					// block, with the comments before it. A misplaced line
					// never hangs on a block, so it waits for the next line.
					if parent != ROOT
						&& let Some(k) = self.pending.iter().rposition(|p| is_field(&p.text))
						&& let Some(&(base, _)) =
							self.stack.iter().rev().find(|(_, n)| *n == parent)
					{
						let (mut moved, misplaced): (Vec<_>, Vec<_>) = self
							.pending
							.drain(..=k)
							.partition(|p| !p.text.starts_with([' ', '\t']));
						let count = moved.len();
						moved.extend(misplaced);
						self.pending.splice(0..0, moved);
						self.give_pending(parent, base, count, true);
					}
					if let Some(node) = self.bind_block(parent, value, lineno, indent) {
						self.ends.push((self.arena[node].line, next));
						self.attach_trivia(node, indent, comment);
					}
				}
				i = next;
				continue;
			}
			// Stacked-list item: `-` then a blank. A bare name starts with a
			// letter, so no field line starts that way. A `-` alone after the
			// trim is an empty item only when a blank followed it, and only the
			// untrimmed line still knows; with none it is a field line (E014).
			let item = rest.strip_prefix('-').is_some_and(|after| {
				after.starts_with(is_wsp)
					|| (after.is_empty()
						&& lines[i]
							.as_bytes()
							.get(ilen + lead + 1)
							.is_some_and(|&b| is_wsp_byte(b)))
			});
			if item || rest.starts_with('*') {
				if item {
					let Some(parent) = self.resolve_parent(indent, found) else {
						self.misplaced(lineno, "E012", indent, rest, had_blank, false);
						i += 1;
						continue;
					};
					if parent == DEAD {
						self.misplaced(lineno, "E018", indent, rest, had_blank, false);
						i += 1;
						continue;
					}
					tokenize_value(rest, 1, Rules::Current, &mut tok);
					if let Some(f) = item_fault(&tok, rest) {
						self.refuse(
							lineno,
							f.code,
							f.msg,
							Outcome::Retained {
								text: trim_wsp_end(rest).to_string(),
								blank_before: had_blank,
							},
							indent,
						);
						i += 1;
						continue;
					}
					let parent = self.open_lazy(parent);
					let comment = tok.comment.map(|c| &rest[c..]);
					// Elements have no node of their own; trivia rides the field.
					// At the root there is no field (E007), so the comment rides
					// the document like any other pending one.
					if parent != ROOT {
						let mut comment = comment;
						if self.add_star_element(parent, &tok, rest, lineno, indent) {
							self.keep_among(parent, indent);
							// A comment on an item stays on its item.
							if let (Some(c), Value::Array(els)) =
								(comment, &self.arena[parent].value)
							{
								let at = els.len() - 1;
								self.arena[parent]
									.triv_mut()
									.notes
									.push((at, c.to_string()));
								comment = None;
							}
						}
						let head = self.arena[parent].line;
						match self.ends.last_mut() {
							Some(e) if e.0 == head => e.1 = lineno,
							_ => self.ends.push((head, lineno)),
						}
						self.attach_trivia(parent, indent, comment);
					} else {
						if let Some(c) = comment {
							self.pending.push(Pend {
								text: c.to_string(),
								indent,
								blank_before: had_blank,
								ceiling: indent.len(),
								line: 0,
							});
						}
						self.add_star_element(parent, &tok, rest, lineno, indent);
					}
					i += 1;
					continue;
				}
				let Some(parent) = self.resolve_parent(indent, found) else {
					self.misplaced(lineno, "E012", indent, rest, had_blank, false);
					i += 1;
					continue;
				};
				if parent == DEAD {
					self.misplaced(lineno, "E018", indent, rest, had_blank, false);
					i += 1;
					continue;
				}
				// The old item marker. Content-malformed at any position, so safe
				// to retain, and the items around it still load. The BOM
				// exception the field arm makes cannot apply here: this line
				// starts with the '*' that brought us in.
				self.refuse(
					lineno,
					"E013",
					"a list item is written '- ' now, not '*'",
					Outcome::Retained {
						text: trim_wsp_end(rest).to_string(),
						blank_before: had_blank,
					},
					indent,
				);
				i += 1;
				continue;
			}
			// Field line.
			tokenize(rest, b':', false, Rules::Current, &mut tok);
			let comment = tok.comment.map(|c| &rest[c..]);
			let Some(parent) = self.resolve_parent(indent, found) else {
				let raw = line_fence(&tok, rest).is_some();
				self.misplaced(lineno, "E012", indent, rest, had_blank, raw);
				i = self.skip_field_line(&lines, i, indent, &tok, rest);
				continue;
			};
			if parent == DEAD {
				let raw = line_fence(&tok, rest).is_some();
				self.misplaced(lineno, "E018", indent, rest, had_blank, raw);
				i = self.skip_field_line(&lines, i, indent, &tok, rest);
				continue;
			}
			let scan = match path_of(&tok, rest) {
				Ok(s) => s,
				Err(reason) => {
					// The column counts bytes from the line start, so all four
					// bindings report it the same on non-ASCII text.
					let at = tok.fault.map_or(0, |(pos, _)| pos);
					// Content-malformed at any position, so retained - except a
					// line led by a BOM, which the file-start strip would rewrite
					// into something that can bind.
					let bom = rest.starts_with('\u{feff}');
					let outcome = if bom {
						Outcome::Dropped
					} else {
						Outcome::Retained {
							text: trim_wsp_end(rest).to_string(),
							blank_before: had_blank,
						}
					};
					self.refuse(
						lineno,
						"E014",
						format!(
							"malformed line skipped: {}, at column {}",
							reason,
							indent.len() + lead + at + 1
						),
						outcome,
						indent,
					);
					i = if bom {
						self.skip_field_line(&lines, i, indent, &tok, rest)
					} else {
						self.keep_body(&lines, i, indent, &tok, rest)
					};
					continue;
				}
			};
			let mut next = i + 1;
			// A line that reads only one way, or no way, is kept verbatim
			// rather than read with a guess: a value written the way JSON,
			// TOML and YAML write an array, an open quote, a bad escape, bare
			// whitespace or a quote, or a bare name that breaks the spelling
			// rule. Judged before the cap and from the first piece, which the
			// cap keeps: a cap refuses only a line that would bind. When the
			// name still reads, the lines under it still load, under the path
			// opened empty.
			if let Some(f) = line_fault(&tok, rest) {
				self.refuse(
					lineno,
					f.code,
					f.msg,
					Outcome::Retained {
						text: trim_wsp_end(rest).to_string(),
						blank_before: had_blank,
					},
					indent,
				);
				if f.opens {
					self.hold_open(parent, scan.segments, lineno, indent);
				}
				// Only a fault in the name leaves a fence to read here.
				i = self.keep_body(&lines, i, indent, &tok, rest);
				continue;
			}
			// Element cap: the whole line is refused, so a capped load never
			// holds a truncated array that would read as the document's
			// value. The scan stopped at the cap, so nothing past it was
			// built either, and the value span is empty: this has to come
			// before the value is read, or the line would bind as Empty.
			if tok.capped {
				self.refuse(
					lineno,
					"E021",
					format!(
						"array longer than {} elements; line skipped",
						self.max_elements
					),
					Outcome::Dropped,
					indent,
				);
				i = self.skip_field_line(&lines, i, indent, &tok, rest);
				continue;
			}
			// The verbatim value span, kept for reads' `raw` (only the plain
			// scalar/inline-array case has a one-line source spelling).
			let mut src_text: Option<&str> = None;
			let value_text = scan.value.map(|(a, b)| &rest[a..b]);
			let value = match value_text {
				None => {
					// A clean path with no colon is the one defined repair: the
					// obvious intent is that path with an empty value.
					self.err(lineno, "E015", "missing colon; repaired as an empty value");
					Value::Empty
				}
				Some("") => Value::Empty,
				Some(v) => {
					if let Some(fence) = fence_open(v) {
						// Same-line fence spelling.
						let (val, n) = self.consume_raw(&lines, i + 1, lineno, indent, fence);
						next = n;
						val
					} else {
						src_text = Some(v);
						cell_of_tokens(&tok, rest)
					}
				}
			};
			// Record only when the bound node holds exactly this line's value
			// (a merge into an equal-valued node keeps the first line's span;
			// a value dropped after a last-segment selector records nothing).
			let vkey = src_text.as_ref().map(|_| value_hash(&value));
			let parent = self.open_lazy(parent);
			let nsegs = scan.segments.len();
			if let Some(node) = self.attach_path(parent, scan.segments, value, lineno, indent) {
				if src_text.is_some()
					&& unit_named(&self.arena[node].name)
					&& let Some(m) = tok
						.elements
						.iter()
						.find_map(|p| unit_clash(&self.arena[node].name, &piece_text(p, rest)))
				{
					self.diag(Diagnostic {
						line: lineno,
						severity: Severity::Hint,
						message: m,
						code: "H005",
					});
				}
				if let (Some(s), Some(k)) = (src_text, vkey)
					&& !self.arena[node].src_set
					&& value_hash(&self.arena[node].value) == k
				{
					self.arena[node].src_set = true;
					if !src_matches_display(&self.arena[node].value, s) {
						self.arena[node].src = Some(s.to_string());
					}
				}
				// What the node had before this line, for an array line that
				// turns out to have a field under it.
				let mark = ArrayLine {
					line: lineno,
					leads: self.arena[node].leading().len(),
					trailing: !self.arena[node].trailing().is_empty(),
					blank: self.arena[node].blank_before,
				};
				if had_blank {
					self.arena[node].blank_before = true;
				}
				if next > i + 1 {
					self.ends.push((lineno, next));
				}
				// A kept line before a dotted line sits level with its first
				// segment, so it goes there with the comments before it. Under
				// the last one it would be written deeper and read as a child.
				if nsegs > 1
					&& let Some(k) = self.pending.iter().rposition(|p| is_field(&p.text))
				{
					self.give_pending(self.head_of(node, nsegs), indent, k + 1, false);
				}
				self.attach_trivia(node, indent, comment);
				self.stack.push((indent, node));
				if tok.array.is_some() {
					self.array_line.insert(node, mark);
				}
			}
			i = next;
		}
		// A cap crossed on the document's last line still reports, with nothing
		// left to skip.
		if !node_capped && self.max_nodes != 0 && self.arena.len() - 1 > self.max_nodes {
			self.refuse(
				lines.len(),
				"E020",
				format!("node cap of {} exceeded; parse stopped", self.max_nodes),
				Outcome::Stopped(&[]),
				"",
			);
		}
		self.star_flush();
		// Indented tail comments keep their block; only top-level ones orphan.
		// Before the fold, which moves a dropped instance's comments over to
		// the one it joins: after it they would hang on the dropped one.
		self.hang_deeper_pending("");
		self.fold_late_dups();
		for n in 0..self.arena.len() {
			settle_block(&mut self.arena, n, 1);
		}
		self.emit_repeated_leaf_hints();
		// Line order, so a hint found only after the pass (a fold, a repeated
		// leaf) sits with its line. Stable, so two on one line keep the order
		// they were found in. Before the cap entry, which ends the list.
		self.diags.sort_by_key(|d| d.line);
		let (mut chain, mut held) = (Vec::new(), Vec::new());
		let mut orphans: Vec<Lead> = self
			.pending
			.drain(..)
			.map(|p| Lead {
				depth: comment_depth(&mut chain, &mut held, "", &p.text, p.indent),
				text: p.text,
				blank_before: p.blank_before,
				line: p.line,
				kept: false,
			})
			.collect();
		settle_first_blank(&mut self.arena, &mut orphans);
		// The one entry past the cap: what was not listed, and whether any
		// of it was an error, so a consumer scanning the list for errors
		// still finds one and a Strict load still fails.
		let (errors, hints) = self.unlisted;
		if errors + hints > 0 {
			self.diags.push(Diagnostic {
				line: 0, // about the list, not a line
				severity: if errors > 0 {
					Severity::Error
				} else {
					Severity::Hint
				},
				code: "E022",
				message: format!(
					"diagnostic cap of {} reached; {} more not listed, {} of them errors",
					self.max_diags,
					errors + hints,
					errors
				),
			});
		}
		let mut doc = Document {
			arena: self.arena,
			diags: self.diags,
			strictness,
			orphans,
			lost: self.lost,
			kept_owed: self.kept_owed,
			index: std::sync::OnceLock::new(),
			probe: false,
			probe_doc: None,
			kept: self.kept_any,
			arrays: self.kept_arrays,
			bracketed: false,
			kept_near: Vec::new(),
			kept_sum: 0,
			ends: self.ends,
			dropped: self.dropped,
			source: None,
		};
		doc.settle_kept();
		doc
	}
}

// ---------------------------------------------------------------------------
// Document: load, diagnostics, formatter
// ---------------------------------------------------------------------------

impl Document {
	/// Parse at Standard strictness. Never fails: bad lines are skipped and
	/// diagnosed, good values stay readable.
	pub fn parse(text: &str) -> Document {
		Parser::new().parse(text, Strictness::Standard)
	}

	/// Parse at a chosen strictness. Only Strict can fail (any error diagnostic);
	/// the error still includes the parsed document alongside the diagnostics.
	// The Err includes the whole document by design (recover-and-continue);
	// boxing it would change the public shape for a value built once per load.
	#[allow(clippy::result_large_err)]
	pub fn parse_with(text: &str, strictness: Strictness) -> Result<Document, LoadError> {
		let doc = Parser::new().parse(text, strictness);
		if strictness == Strictness::Strict
			&& doc.diags.iter().any(|d| d.severity == Severity::Error)
		{
			return Err(LoadError {
				diagnostics: doc.diags.clone(),
				document: doc,
			});
		}
		Ok(doc)
	}

	/// Parse with resource caps beside the strictness, for input the consumer
	/// does not control: a document amplifies to many times its byte size in
	/// memory, so a size cap alone cannot bound what a load allocates.
	/// `max_nodes` stops the parse once a line takes the node count past it -
	/// one `E020` error, and the unparsed remainder counts as lost so a save
	/// cannot silently truncate. `max_elements` refuses any line whose array
	/// would hold more elements (`E021`, that line alone is skipped).
	/// `max_diags` bounds the diagnostics list itself - a document of nothing
	/// but bad lines costs a diagnostic per line - by listing the first that
	/// many and ending with one `E022` that counts the rest; error_count and
	/// the Strict gate see that tail as an error whenever an unlisted one was.
	/// 0 disables a cap, making this parse_with. The caps are parse-time only;
	/// the write API is the consumer's own arithmetic. As everywhere, the Err
	/// fires only at Strict, and a cap diagnostic is an error, so a capped
	/// Strict load fails; at other levels the parsed part stays readable.
	#[allow(clippy::result_large_err)]
	pub fn parse_limited(
		text: &str,
		strictness: Strictness,
		max_nodes: usize,
		max_elements: usize,
		max_diags: usize,
	) -> Result<Document, LoadError> {
		let doc = Parser::limited(max_nodes, max_elements, max_diags).parse(text, strictness);
		if strictness == Strictness::Strict
			&& doc.diags.iter().any(|d| d.severity == Severity::Error)
		{
			return Err(LoadError {
				diagnostics: doc.diags.clone(),
				document: doc,
			});
		}
		Ok(doc)
	}

	/// Everything the load recorded (after load_and_validate, validation
	/// findings too).
	pub fn diagnostics(&self) -> &[Diagnostic] {
		&self.diags
	}

	/// How many lines or values parsing dropped that canonical output cannot
	/// re-emit - bad indentation, an unusable selector, a line past the depth
	/// cap. Content-malformed lines do NOT count: those are retained as trivia
	/// and survive a save. Nonzero means a save_file would delete hand-written
	/// content, so save_file refuses then (save_file_lossy overrides), and
	/// save_file_keep_lines does when it cannot keep the lines. It also counts
	/// lines the load kept as written that an edit took and design.md's
	/// kept-lines table does not let it take.
	pub fn lost_count(&self) -> usize {
		self.lost + self.kept_shortfall()
	}

	/// Kept lines the document owes and no longer holds. Free on a document
	/// that never had one.
	fn kept_shortfall(&self) -> usize {
		if self.kept_owed == 0 {
			return 0;
		}
		self.kept_owed.saturating_sub(self.kept_lines())
	}

	/// Kept lines in the live tree and the orphans. From ROOT, since a removed
	/// node stays in the arena; a stack, since a recursive walk overflowed
	/// Windows' 1 MB main stack on the deepest legal document.
	fn kept_lines(&self) -> usize {
		let mut n = kept_in(&self.orphans);
		let mut stack = vec![ROOT];
		while let Some(i) = stack.pop() {
			n += kept_in_lists(&self.arena[i]);
			stack.extend_from_slice(&self.arena[i].children);
		}
		n
	}

	/// The kept lines a remove of `node` takes, by design.md's table: every
	/// one written inside its block, and the one written as its own line.
	/// Read from where the lines sit before the edit, so a remove that drops
	/// one beside its target is caught by the gate rather than allowed.
	fn taken(&self, node: usize) -> usize {
		let nd = &self.arena[node];
		let mut n = kept_in(nd.inside()) + nd.among().iter().filter(|a| a.1.is_kept_line()).count();
		if heads_block(nd) && nd.leading().last().is_some_and(Lead::is_kept_line) {
			n += 1;
		}
		let mut stack = nd.children.clone();
		while let Some(i) = stack.pop() {
			n += kept_in_lists(&self.arena[i]);
			stack.extend_from_slice(&self.arena[i].children);
		}
		n
	}

	/// How many error-severity diagnostics the document has - the "did
	/// this file have errors?" predicate, so recover-and-continue can't read
	/// as success by accident. Counts whatever diagnostics() holds (after
	/// load_and_validate, that includes validation errors).
	pub fn error_count(&self) -> usize {
		self.diags
			.iter()
			.filter(|d| d.severity == Severity::Error)
			.count()
	}

	/// One-shot load-and-validate: parse at a strictness, validate against a
	/// schema, and hand back the document with ONE combined diagnostics
	/// list (parse first, then validation - the order `check --schema`
	/// prints), so half the errors can't vanish because a caller forgot one
	/// of the two lists. Never fails: a strict-failing document comes back as
	/// the document plus its diagnostics (error_count() answers "did it
	/// fail"). An empty schema text skips validation entirely. H001 hints the
	/// schema disavows (a declared repeat upper bound above 1) are dropped.
	pub fn load_and_validate(text: &str, schema_text: &str, strictness: Strictness) -> Document {
		let mut doc = Parser::new().parse(text, strictness);
		if !schema_text.trim().is_empty() {
			let schema = Document::parse(schema_text);
			// A schema that did not load would silently drop the constraints on
			// its broken lines, or report every field as unknown - either way
			// blaming the document for the schema. Say so instead, as `check`
			// does, and validate nothing.
			if schema.diags.iter().any(|d| d.severity == Severity::Error) {
				doc.diags.push(Diagnostic {
					line: 0,
					severity: Severity::Error,
					code: "V099",
					message: "schema failed to load".to_string(),
				});
				return doc;
			}
			let vdiags = doc.validate(&schema);
			doc.diags.extend(vdiags);
			suppress_declared_repeats(&schema, &mut doc.diags);
			suppress_declared_reopens(&schema, &mut doc.diags);
		}
		doc
	}

	/// The level the document was loaded at.
	pub fn strictness(&self) -> Strictness {
		self.strictness
	}

	/// File tier, load half: read and parse PATH at Standard. Never fails -
	/// the document always comes back usable (empty when the file could not
	/// be read), and the status separates the four cases consumers otherwise
	/// confuse: absent, present-but-unreadable, parsed with errors, clean.
	pub fn load_file(path: &str) -> (Document, FileStatus) {
		Document::load_file_with(path, Strictness::Standard)
	}

	/// load_file at a chosen strictness. A strict-failing file reports
	/// HadErrors; the recover-and-continue document still comes back.
	pub fn load_file_with(path: &str, level: Strictness) -> (Document, FileStatus) {
		let text = match read_file(path, 0) {
			Ok(t) => t,
			Err(st) => return (Parser::new().parse("", level), st),
		};
		let doc = Parser::new().parse(&text, level);
		let st = if doc.diags.iter().any(|d| d.severity == Severity::Error) {
			FileStatus::HadErrors
		} else {
			FileStatus::Clean
		};
		(doc, st)
	}

	/// File tier, save half: write this document's canonical text to PATH
	/// through a temp file in the same directory plus a rename, so an
	/// interrupted save can never truncate the config it rewrites - the same
	/// mechanics the CLI's `--write` uses. Refuses when the write would delete
	/// content from the file (see lost_count); save_file_lossy writes
	/// anyway. The Err tells the two apart without matching on prose:
	/// SaveError::Refused is the gate, SaveError::Io is the write failing.
	pub fn save_file(&self, path: &str) -> Result<(), SaveError> {
		let lost = self.lost_count();
		if lost > 0 {
			return Err(SaveError::Refused {
				path: path.to_string(),
				lost,
			});
		}
		write_file_atomic(path, &self.to_canonical()).map_err(SaveError::Io)
	}

	/// save_file without the lost-content gate: writes even when the
	/// write deletes content from the file. The caller owns that choice. Only ever
	/// Errs with SaveError::Io - the gate is the one thing it skips.
	pub fn save_file_lossy(&self, path: &str) -> Result<(), SaveError> {
		write_file_atomic(path, &self.to_canonical()).map_err(SaveError::Io)
	}

	/// Canonical form: block layout, tabs, insertion order, minimal quoting,
	/// redundancy collapsed, comments re-emitted as attached trivia. Scalar
	/// text is never rewritten.
	pub fn to_canonical(&self) -> String {
		let mut e = Emit::new(self.arena.len() * 24, false);
		self.emit_all(&mut e);
		e.out
	}

	/// parse_with, keeping the text for to_text_keep_lines(). The document is
	/// the same one parse_with gives; only the save differs.
	#[allow(clippy::result_large_err)]
	pub fn parse_keep_lines(text: &str, strictness: Strictness) -> Result<Document, LoadError> {
		match Document::parse_with(text, strictness) {
			Ok(mut d) => {
				d.keep_source(text);
				Ok(d)
			}
			Err(mut e) => {
				e.document.keep_source(text);
				Err(e)
			}
		}
	}

	fn keep_source(&mut self, text: &str) {
		self.source = Some(if self.to_canonical() == text {
			String::new()
		} else {
			text.to_string()
		});
	}

	/// load_file_with, keeping the text for to_text_keep_lines().
	pub fn load_file_keep_lines(path: &str, level: Strictness) -> (Document, FileStatus) {
		let text = match read_file(path, 0) {
			Ok(t) => t,
			Err(st) => return (Parser::new().parse("", level), st),
		};
		let mut doc = Parser::new().parse(&text, level);
		let st = if doc.diags.iter().any(|d| d.severity == Severity::Error) {
			FileStatus::HadErrors
		} else {
			FileStatus::Clean
		};
		doc.keep_source(&text);
		(doc, st)
	}

	/// The text a save that keeps lines writes, and whether it kept them.
	/// Each line the edits did not touch is the loaded text's own line, byte
	/// for byte; a changed value is written into its line; new lines are
	/// indented the way the lines around them are. The result has to reload
	/// as this document. When it does not, or the document was not loaded
	/// with parse_keep_lines or load_file_keep_lines, or it took a merge, or
	/// an edit took a kept line it should not have, this is to_canonical()
	/// and false.
	pub fn to_text_keep_lines(&self) -> (String, bool) {
		// The reparse check below cannot see a kept line gone from both the
		// tree and the text, so falling back leaves it to the lost-count gate.
		if let Some(src) = &self.source
			&& self.kept_shortfall() == 0
			&& let Some(t) = keep_lines(src, self)
		{
			return (t, true);
		}
		(self.to_canonical(), false)
	}

	/// save_file with to_text_keep_lines(): Ok(true) when it kept the lines,
	/// Ok(false) when it wrote the canonical form instead. A line the load
	/// dropped comes back as written when the lines are kept, so this
	/// refuses the way save_file does only when it would write canonical.
	pub fn save_file_keep_lines(&self, path: &str) -> Result<bool, SaveError> {
		let (text, kept) = self.to_text_keep_lines();
		let lost = self.lost_count();
		if !kept && lost > 0 {
			return Err(SaveError::Refused {
				path: path.to_string(),
				lost,
			});
		}
		write_file_atomic(path, &text).map_err(SaveError::Io)?;
		Ok(kept)
	}

	fn emit_marked(&self) -> Emit {
		let mut e = Emit::new(self.arena.len() * 24, false);
		e.lines = true;
		self.emit_all(&mut e);
		e
	}

	fn emit_all(&self, e: &mut Emit) {
		self.emit_children(&self.arena[ROOT].children, 0, e);
		// Comments that never found a following line re-emit at the end.
		e.near(ROOT, 0);
		push_leads(e, &self.orphans, 0, (ROOT, Site::Orphans, 0));
	}

	/// Make a misplaced line kept as written into the comment the emitter
	/// writes it as, wherever it would now bind as written, so the document
	/// is the one its saved text reloads as and the next edit comes out the same
	/// either way. One among a list's elements goes above the list, as a
	/// reload files a comment there. Runs after a load and after each edit,
	/// and only while the document holds such a line.
	fn settle_kept(&mut self) {
		self.settle_arrays();
		// A line moved out of a list can leave it written inline, which
		// changes what the lines after it sit under, so go again until
		// nothing moves.
		let was = self.kept;
		while self.kept && self.settle_kept_once() {}
		if self.kept {
			self.kept_sum = self.near_sum();
		}
		// One of those may have been the line under a kept array.
		if was {
			self.settle_arrays();
		}
	}

	/// A kept array line stays kept only while it heads a field with fields
	/// under it (E028). One a merge or an edit leaves anywhere else would
	/// bind on a reload, so it is written as a comment, the way the settle
	/// writes a misplaced line that would read differently.
	fn settle_arrays(&mut self) {
		if !self.arrays {
			return;
		}
		let mut stack = self.arena[ROOT].children.clone();
		while let Some(n) = stack.pop() {
			stack.extend_from_slice(&self.arena[n].children);
			let heads = heads_block(&self.arena[n]);
			let Some(t) = self.arena[n].trivia.as_deref_mut() else {
				continue;
			};
			settle_array_run(&mut t.leading, heads);
			settle_array_run(&mut t.inside, false);
			settle_array_run(&mut t.after, false);
			let mut from = 0;
			while from < t.among.len() {
				let at = t.among[from].0;
				let to = from + t.among[from..].iter().take_while(|a| a.0 == at).count();
				let mut run: Vec<Lead> = t.among[from..to].iter().map(|a| a.1.clone()).collect();
				settle_array_run(&mut run, false);
				for (slot, l) in t.among[from..to].iter_mut().zip(run) {
					slot.1 = l;
				}
				from = to;
			}
		}
		settle_array_run(&mut self.orphans, false);
	}

	/// After an edit. A kept line binds or not by the lines between it and
	/// the binding line above, so an edit that changed none of the nodes
	/// those came from cannot move it, and the whole-document emit is
	/// skipped (20260924d item 2).
	fn resettle_kept(&mut self) {
		if self.kept && self.near_sum() != self.kept_sum {
			self.settle_kept();
		} else {
			self.settle_arrays();
		}
	}

	/// Everything the emit model reads from the nodes in `kept_near`: each
	/// one still at its place in its parent's list, its child count, its
	/// value's form and its comment lines. A kept line's parent chain needs
	/// no entry, since a binding line resets the model to its own depth.
	fn near_sum(&self) -> u64 {
		let mut h = Fnv::new();
		let lead = |h: &mut Fnv, l: &Lead| {
			h.dec(l.depth);
			h.dec(l.text.len());
			h.bytes(l.text.as_bytes());
		};
		for &(n, pos) in &self.kept_near {
			let nd = &self.arena[n];
			h.dec(n);
			h.dec(nd.children.len());
			if n == ROOT {
				h.dec(self.orphans.len());
				for l in &self.orphans {
					lead(&mut h, l);
				}
				continue;
			}
			let linked = self.arena.get(nd.parent).and_then(|p| p.children.get(pos)) == Some(&n);
			h.byte(u8::from(linked));
			h.byte(u8::from(stacks(nd)));
			match &nd.value {
				Value::Empty => h.byte(0),
				Value::Cell(_) => h.byte(1),
				Value::Array(els) => {
					h.byte(3);
					h.dec(els.len());
				}
				Value::Raw(_) => h.byte(2),
			}
			let Some(t) = nd.trivia.as_deref() else {
				h.byte(0);
				continue;
			};
			for list in [&t.leading, &t.inside, &t.after] {
				h.dec(list.len());
				for l in list {
					lead(&mut h, l);
				}
			}
			h.dec(t.among.len());
			for (i, l) in &t.among {
				h.dec(*i);
				lead(&mut h, l);
			}
		}
		h.0
	}

	fn settle_kept_once(&mut self) -> bool {
		let mut e = Emit::new(0, true);
		self.emit_all(&mut e);
		self.kept = e.verbatim > 0;
		self.kept_near = std::mem::take(&mut e.kept_near);
		let mut among: Vec<(usize, usize)> = Vec::new();
		for &(node, site, i, depth) in &e.fell {
			let list = match site {
				Site::Orphans => &mut self.orphans,
				Site::Among => {
					among.push((node, i));
					continue;
				}
				_ => {
					let t = self.arena[node].triv_mut();
					match site {
						Site::Leading => &mut t.leading,
						Site::Inside => &mut t.inside,
						_ => &mut t.after,
					}
				}
			};
			let l = &mut list[i];
			l.text = commented(&l.text);
			l.depth = depth;
			l.kept = true;
		}
		// Out of each list latest first, so a removal leaves the earlier
		// indices alone, then onto the end of the leading lines in order.
		let moved_any = !among.is_empty();
		let mut moved: Vec<Lead> = Vec::new();
		while let Some((node, i)) = among.pop() {
			let t = self.arena[node].triv_mut();
			moved.push(t.among.remove(i).1);
			if among.last().is_some_and(|a| a.0 == node) {
				continue;
			}
			let depth = t
				.leading
				.iter()
				.rev()
				.find(|c| !c.text.starts_with([' ', '\t']))
				.map_or(0, |c| c.depth);
			for mut l in moved.drain(..).rev() {
				l.text = commented(&l.text);
				l.depth = depth;
				l.line = 0;
				l.kept = true;
				t.leading.push(l);
			}
		}
		// A line moved above the first list in the file is now the first
		// thing written, so its blank goes the way the load's did.
		if moved_any {
			settle_first_blank(&mut self.arena, &mut self.orphans);
		}
		moved_any
	}

	/// Emit a sibling run. The parent walk already knows whether an earlier
	/// same-name sibling is empty (the raw same-line-fence hazard), so one
	/// seen-empties set here replaces a per-child rescan of the whole run.
	fn emit_children(&self, kids: &[usize], depth: usize, e: &mut Emit) {
		let mut empties: std::collections::HashSet<&str> = std::collections::HashSet::new();
		for (pos, &c) in kids.iter().enumerate() {
			let n = &self.arena[c];
			let wm = matches!(n.value, Value::Raw { .. }) && empties.contains(n.name.as_str());
			if n.value.is_empty() {
				empties.insert(n.name.as_str());
			}
			self.emit_node(c, pos, depth, wm, e);
		}
	}

	fn emit_node(&self, idx: usize, pos: usize, depth: usize, would_merge: bool, e: &mut Emit) {
		self.emit_line(idx, pos, depth, would_merge, e);
		self.emit_children(&self.arena[idx].children, depth + 1, e);
		e.near(idx, pos);
		// Comments this block owns with no child to take them, one deeper.
		push_leads(
			e,
			self.arena[idx].inside(),
			depth + 1,
			(idx, Site::Inside, 0),
		);
		// Comments that hung on this block after its last child.
		push_leads(e, self.arena[idx].after(), depth, (idx, Site::After, 0));
	}

	// Kept out of emit_node, which recurses once per level: its temporaries
	// would otherwise sit in every frame, and a document at the nesting cap
	// ran past a 1 MB stack in a debug build.
	#[inline(never)]
	fn emit_line(&self, idx: usize, pos: usize, depth: usize, would_merge: bool, e: &mut Emit) {
		let node = &self.arena[idx];
		e.near(idx, pos);
		let pad: String = "\t".repeat(depth);
		// Same-line fence spelling can't have an inline comment (an unbalanced
		// quote in the info-string could hide the `#` on reparse), so its
		// trailing comment joins the leading lines instead; the flag comes from
		// the parent's walk. Each blank rides its own comment (or the binding
		// line), never as the first output line.
		push_leads(e, node.leading(), depth, (idx, Site::Leading, 0));
		// The kept line just written opens this block on a reload.
		if heads_block(node) {
			e.bound(depth);
			e.near(idx, pos);
			return;
		}
		if node.blank_before && !e.out.is_empty() {
			e.out.push('\n');
		}
		e.mark(node.line);
		let out = &mut e.out;
		if would_merge && !node.trailing().is_empty() {
			out.push_str(&pad);
			out.push_str(node.trailing());
			out.push('\n');
		}
		out.push_str(&pad);
		out.push_str(&emit_name(&node.name));
		out.push(':');
		e.bound(depth);
		e.near(idx, pos);
		match &node.value {
			Value::Empty => {
				e.span(e.out.len());
				push_trailing(&mut e.out, node.trailing());
				e.out.push('\n');
			}
			Value::Array(els) if stacks(node) => {
				// Stacked, with the kept lines where they sat.
				push_trailing(&mut e.out, node.trailing());
				e.out.push('\n');
				let among = node.among();
				let mut next = 0;
				for (i, el) in els.iter().enumerate() {
					let from = next;
					while next < among.len() && among[next].0 <= i {
						next += 1;
					}
					for (j, (_, l)) in among[from..next].iter().enumerate() {
						push_leads(
							e,
							std::slice::from_ref(l),
							depth + 1,
							(idx, Site::Among, from + j),
						);
					}
					let column = "\t".repeat(depth + 1);
					e.out.push_str(&column);
					e.out.push_str("- ");
					e.out.push_str(&emit_element(el));
					for (_, n) in node.notes().iter().filter(|n| n.0 == i) {
						push_trailing(&mut e.out, n);
					}
					e.out.push('\n');
					e.placed(&column);
				}
				for (j, (_, l)) in among[next..].iter().enumerate() {
					push_leads(
						e,
						std::slice::from_ref(l),
						depth + 1,
						(idx, Site::Among, next + j),
					);
				}
			}
			Value::Cell(el) => {
				let at = e.out.len();
				e.out.push(' ');
				e.out.push_str(&emit_element(el));
				e.span(at);
				push_trailing(&mut e.out, node.trailing());
				e.out.push('\n');
			}
			Value::Array(els) => {
				let at = e.out.len();
				e.out.push(' ');
				emit_array_into(&mut e.out, els);
				e.span(at);
				push_trailing(&mut e.out, node.trailing());
				e.out.push('\n');
			}
			Value::Raw(r) => {
				let out = &mut e.out;
				let (content, fence_char, fence_len) = (&r.content, &r.fence_char, &r.fence_len);
				// Child-indent spelling is canonical: bare name line, fenced
				// block one level deeper, verbatim content. Exception: if an
				// earlier same-name sibling is empty, the bare `name:` header
				// would merge into it on reparse and the fence would fill that
				// instance instead - so use the same-line spelling there.
				if would_merge {
					out.push(' ');
				} else {
					push_trailing(out, node.trailing());
					out.push('\n');
				}
				let pad: String = "\t".repeat(depth + 1); // block body pad, one deeper
				let fence: String = std::iter::repeat_n(*fence_char as char, *fence_len).collect();
				if !would_merge {
					out.push_str(&pad);
				}
				out.push_str(&emit_fence_line(r));
				out.push('\n');
				let body = out.len();
				if !content.is_empty() {
					for l in content.split('\n') {
						if !l.is_empty() {
							out.push_str(&pad);
						}
						out.push_str(l);
						out.push('\n');
					}
				}
				let end = out.len();
				out.push_str(&pad);
				out.push_str(&fence);
				out.push('\n');
				if e.lines {
					e.bodies.push((body, end, depth + 1));
				}
			}
		}
	}
}

/// Canonical text on its way out, with a model of the level stack a reload
/// of it will have at this point: the sentinel and one level per tab up to
/// `open`, which the last binding line leaves, then what the lines refused
/// since then pushed, and the indent of a kept misplaced line that the
/// lines under it are kept with.
struct Emit {
	out: String,
	open: isize,
	tail: Vec<(String, usize)>,
	hold: Option<String>,
	// settle_kept() only: the lines written as comments, where they sit and
	// at what depth, and how many went out as written. Then the nodes the
	// lines since the last binding line came from, each with its place in
	// its parent's list, and those a kept line was modeled through.
	record: bool,
	fell: Vec<(usize, Site, usize, usize)>,
	verbatim: usize,
	near: Vec<(usize, usize)>,
	flushed: usize,
	kept_near: Vec<(usize, usize)>,
	// to_text_keep_lines() only: where the lines from each source line start
	// (0 for none), each raw body with the tabs its lines are padded with,
	// and where each value is written on its binding line.
	lines: bool,
	marks: Vec<(usize, usize)>,
	bodies: Vec<(usize, usize, usize)>,
	spans: Vec<(usize, usize)>,
}

impl Emit {
	fn new(cap: usize, record: bool) -> Emit {
		Emit {
			out: String::with_capacity(cap),
			open: -1,
			tail: Vec::new(),
			hold: None,
			record,
			fell: Vec::new(),
			verbatim: 0,
			near: Vec::new(),
			flushed: 0,
			kept_near: Vec::new(),
			lines: false,
			marks: Vec::new(),
			bodies: Vec::new(),
			spans: Vec::new(),
		}
	}

	fn mark(&mut self, line: usize) {
		if self.lines {
			self.marks.push((self.out.len(), line));
		}
	}

	/// A value written from `at` to here, the space before it included.
	fn span(&mut self, at: usize) {
		if self.lines {
			self.spans.push((at, self.out.len()));
		}
	}

	/// A binding line at this depth: the stack is its levels and nothing else.
	fn bound(&mut self, depth: usize) {
		self.open = depth as isize;
		self.tail.clear();
		self.hold = None;
		self.near.clear();
		self.flushed = 0;
	}

	fn near(&mut self, idx: usize, pos: usize) {
		if self.record {
			self.near.push((idx, pos));
		}
	}

	/// A line at this indent through the reload's resolve_parent(): the
	/// parent it finds, and the model as it leaves it, not yet taken.
	fn resolve(&self, indent: &str) -> (Option<usize>, isize, Vec<(String, usize)>) {
		let levels = (self.open + 2) as usize;
		let mut stack: Vec<(String, usize)> = Vec::with_capacity(levels + self.tail.len() + 1);
		stack.push((String::new(), ROOT));
		for d in 0..levels - 1 {
			stack.push(("\t".repeat(d), ROOT));
		}
		stack.extend(self.tail.iter().cloned());
		let (parent, cut) = locate_in(&stack, indent);
		match cut {
			Cut::To(n) => stack.truncate(n),
			Cut::Hold(h) => {
				if let Some(h) = h {
					stack.truncate(h);
				}
				stack.push((indent.to_string(), UNOPENED));
			}
		}
		if stack.len() <= levels {
			return (parent, stack.len() as isize - 2, Vec::new());
		}
		(parent, self.open, stack.split_off(levels))
	}

	/// Take a resolve, then the refusal's push: a refused line holds its own
	/// column unless it already sits there as a skipped line's.
	fn refused(&mut self, indent: &str, open: isize, tail: Vec<(String, usize)>) {
		self.open = open;
		self.tail = tail;
		if !matches!(self.tail.last(), Some((i, n)) if i == indent && *n == UNOPENED) {
			self.tail.push((indent.to_string(), DEAD));
		}
	}

	/// A line a reload binds, such as a list element: it resolves, then
	/// holds its column with a live node.
	fn placed(&mut self, indent: &str) {
		let (_, open, tail) = self.resolve(indent);
		self.open = open;
		self.tail = tail;
		self.tail.push((indent.to_string(), ROOT));
		self.hold = None;
	}
}

/// Which trivia list a line sits in.
#[derive(Clone, Copy, PartialEq)]
enum Site {
	Leading,
	Inside,
	After,
	Among,
	Orphans,
}

/// True when a field's last leading line is one kept for its value alone,
/// naming just this field, so that line is written in place of the bare
/// `name:` line: a reload opens the field from it the same way. An empty
/// block keeps its own line, since nothing would open the field. Only what
/// a reload restores counts, so a document and its reload agree.
fn heads_block(node: &NodeData) -> bool {
	!node.children.is_empty() && opened_by_kept(node)
}

/// heads_block() but for the children: a field a reload would open only
/// from the lines under it, so it goes with the last of them.
fn opened_by_kept(node: &NodeData) -> bool {
	if !node.value.is_empty() || node.blank_before || !node.trailing().is_empty() {
		return false;
	}
	let Some(l) = node.leading().last() else {
		return false;
	};
	if l.depth != 0 || l.text.starts_with([' ', '\t']) || !opens_later(&l.text) {
		return false;
	}
	let mut tok = Tokens::default();
	tokenize(&l.text, b':', false, Rules::Current, &mut tok);
	path_of(&tok, &l.text).is_ok_and(|scan| {
		scan.segments.len() == 1
			&& scan.segments[0].selector.is_none()
			&& scan.segments[0].name == node.name
	})
}

fn kept_in(leads: &[Lead]) -> usize {
	leads.iter().filter(|l| l.is_kept_line()).count()
}

/// A reload starts a comment run at 0 and steps one level at a time past
/// the comment or kept field line before it, so a comment left after the
/// line it sat under went is pulled back to fit.
fn restep(leads: &mut [Lead]) {
	let mut room = 0;
	for l in leads.iter_mut() {
		if l.text.starts_with('#') {
			l.depth = l.depth.min(room);
			room = l.depth + 1;
		} else if is_field(&l.text) {
			room = l.depth + 1;
		}
	}
}

/// What a remove of this node leaves of its lines, by design.md's kept-lines
/// table: the kept lines beside it, with the comments that sit with them.
/// Above it that is everything up to its last kept line, below it everything
/// from its first, so a comment written against the node goes with it. The
/// kept line written in place of its `name:` line goes too.
fn beside_kept(nd: &mut NodeData) -> Vec<Lead> {
	let heads = heads_block(nd);
	let Some(t) = nd.trivia.as_deref_mut() else {
		return Vec::new();
	};
	let mut left = std::mem::take(&mut t.leading);
	if heads {
		left.pop();
	}
	left.truncate(
		left.iter()
			.rposition(Lead::is_kept_line)
			.map_or(0, |k| k + 1),
	);
	let from = t
		.after
		.iter()
		.position(Lead::is_kept_line)
		.unwrap_or(t.after.len());
	left.extend(t.after.drain(from..));
	left
}

/// Kept lines in all of one node's trivia lists.
fn kept_in_lists(nd: &NodeData) -> usize {
	kept_in(nd.leading())
		+ kept_in(nd.after())
		+ kept_in(nd.inside())
		+ nd.among().iter().filter(|a| a.1.is_kept_line()).count()
}

/// A misplaced line's text as the comment it falls back to.
fn commented(text: &str) -> String {
	format!("# {}", &text[leading_ws(text).len()..])
}

/// Comments out each kept array line in a run but one written in place of
/// the line of a field with fields under it, the run's last when `heads`
/// says so. Anywhere else no field binds under it on a reload, so it would
/// bind itself. What sat under it goes the same way, since a comment holds
/// no level.
fn settle_array_run(run: &mut [Lead], heads: bool) {
	let mut settled = false;
	for k in 0..run.len() {
		let l = &run[k];
		if l.text.starts_with(['#', ' ', '\t'])
			|| !array_kept(&l.text)
			|| (heads && k + 1 == run.len())
		{
			continue;
		}
		let depth = l.depth;
		let end = run[k + 1..]
			.iter()
			.position(|x| !x.text.starts_with('#') && x.depth <= depth)
			.map_or(run.len(), |e| k + 1 + e);
		for l in &mut run[k..end] {
			if !l.text.starts_with('#') {
				l.text = commented(&l.text);
				l.kept = true;
			}
		}
		settled = true;
	}
	if settled {
		restep(run);
	}
}

/// A field line kept only for the lines under it: a whole array, and
/// nothing else wrong with it (E028).
fn array_kept(text: &str) -> bool {
	if !is_field(text) || !is_field_text(text) {
		return false;
	}
	let mut tok = Tokens::default();
	tokenize(text, b':', false, Rules::Current, &mut tok);
	tok.array.is_some() && path_of(&tok, text).is_ok() && line_fault(&tok, text).is_none()
}

/// A path in a note, kept to one line.
fn note_text(s: &str) -> String {
	s.replace('\n', "\\n").replace('\r', "\\r")
}

/// The code and message the load gave a kept line that names just `name`,
/// at the level of the block it sits in: a field line refused for its value
/// alone, which a reload would read as another `name` once fixed by hand. A
/// line with a raw body could not be commented out as one line.
fn kept_naming(l: &Lead, name: &str) -> Option<(&'static str, String)> {
	if l.depth != 0
		|| !is_field_text(&l.text)
		|| l.text.starts_with([' ', '\t'])
		|| l.text.contains('\n')
	{
		return None;
	}
	let mut tok = Tokens::default();
	tokenize(&l.text, b':', false, Rules::Current, &mut tok);
	let scan = path_of(&tok, &l.text).ok()?;
	let [seg] = scan.segments.as_slice() else {
		return None;
	};
	if seg.selector.is_some() || seg.name != name {
		return None;
	}
	line_fault(&tok, &l.text)
		.filter(|f| f.opens)
		.map(|f| (f.code, f.msg))
}

/// A kept line a setter writes as a comment, with the note giving why and
/// when. It is a plain comment from here on, as a reload reads it.
fn note_lead(l: &mut Lead, path: &str, code: &str, msg: &str) {
	// The reason, without the advice after it.
	let why = msg.split(';').next().unwrap_or_default();
	l.text = format!(
		"{}  ## commented out by shcl when setting {}, {}: {code} {why}",
		commented(&l.text),
		note_text(path),
		note_stamp()
	);
	l.line = 0;
	l.kept = false;
}

/// How many lines after `leads[k]` are written under it: each line deeper
/// than it up to the next field line that is not, with the comments and
/// misplaced lines among them, since neither ends the lines it holds open.
fn run_under(leads: &[Lead], k: usize) -> usize {
	let depth = leads[k].depth;
	let mut last = k;
	for (i, l) in leads.iter().enumerate().skip(k + 1) {
		// A misplaced line is at depth 0, whatever its own indent.
		if l.depth > depth {
			last = i;
		} else if !l.text.starts_with(['#', ' ', '\t']) {
			break;
		}
	}
	last - k
}

/// Local time to the second, with the zone, for a setter's note on a line it
/// commented out. SHCL_TEST_CLOCK stands in for the system clock and zone, so
/// tests can pin the text: "YYYY-mm-DD HH:MM:SS OFFSET_MINUTES [NAME]".
fn note_stamp() -> String {
	let (when, offset, name) = std::env::var("SHCL_TEST_CLOCK")
		.ok()
		.and_then(|s| test_clock(&s))
		.unwrap_or_else(local_clock);
	format!("{when} {}", zone_label(offset, &name))
}

fn test_clock(spec: &str) -> Option<(String, i32, String)> {
	let f: Vec<&str> = spec.split_whitespace().collect();
	if f.len() != 3 && f.len() != 4 {
		return None;
	}
	let offset = f[2].parse().ok()?;
	let name = f.get(3).map_or("", |n| n);
	Some((format!("{} {}", f[0], f[1]), offset, name.to_string()))
}

/// The zone's short name, such as PDT, or its offset when it has none:
/// Windows gives only long names, and some zones a number such as `+03`.
fn zone_label(offset: i32, name: &str) -> String {
	if !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphabetic()) {
		return name.to_string();
	}
	let sign = if offset < 0 { '-' } else { '+' };
	let m = offset.unsigned_abs();
	format!("UTC{sign}{:02}:{:02}", m / 60, m % 60)
}

/// The local time, its offset from UTC in minutes, and the zone's short name.
/// The offset is the local time less UTC for the same instant, since
/// `tm_gmtoff` is not in POSIX's `struct tm`.
#[cfg(unix)]
fn local_clock() -> (String, i32, String) {
	use std::ffi::{c_char, c_int};
	// The nine fields POSIX names, then room for whatever the platform adds,
	// such as glibc's tm_zone, which strftime's %Z reads.
	#[repr(C)]
	#[derive(Clone, Copy)]
	struct Tm {
		sec: c_int,
		min: c_int,
		hour: c_int,
		mday: c_int,
		mon: c_int,
		year: c_int,
		wday: c_int,
		yday: c_int,
		isdst: c_int,
		rest: [u64; 8],
	}
	// time_t is 64 bits on every target this builds for.
	unsafe extern "C" {
		fn tzset();
		fn localtime_r(t: *const i64, out: *mut Tm) -> *mut Tm;
		fn gmtime_r(t: *const i64, out: *mut Tm) -> *mut Tm;
		fn strftime(buf: *mut c_char, max: usize, format: *const c_char, tm: *const Tm) -> usize;
	}
	let now = std::time::SystemTime::now()
		.duration_since(std::time::UNIX_EPOCH)
		.map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0));
	let blank = Tm {
		sec: 0,
		min: 0,
		hour: 0,
		mday: 1,
		mon: 0,
		year: 70,
		wday: 0,
		yday: 0,
		isdst: 0,
		rest: [0; 8],
	};
	let (mut local, mut utc) = (blank, blank);
	let mut buf = [0 as c_char; 64];
	// SAFETY: each call writes only into the buffer it is handed, and the
	// struct is larger than any platform's struct tm.
	let n = unsafe {
		tzset();
		if gmtime_r(&now, &mut utc).is_null() {
			utc = blank;
		}
		if localtime_r(&now, &mut local).is_null() {
			local = utc;
		}
		strftime(buf.as_mut_ptr(), buf.len(), c"%Z".as_ptr(), &local)
	};
	let name: String = buf[..n].iter().map(|&b| char::from(b as u8)).collect();
	let mut days = local.yday - utc.yday;
	if local.year != utc.year {
		days = if local.year < utc.year { -1 } else { 1 };
	}
	let offset = (days * 24 + local.hour - utc.hour) * 60 + local.min - utc.min;
	let when = format!(
		"{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
		local.year + 1900,
		local.mon + 1,
		local.mday,
		local.hour,
		local.min,
		local.sec
	);
	(when, offset, name)
}

/// As the unix one. Windows names a zone only in full, such as "Pacific
/// Daylight Time", so the label is always the offset.
#[cfg(windows)]
fn local_clock() -> (String, i32, String) {
	#[repr(C)]
	#[derive(Clone, Copy, Default)]
	struct SystemTime {
		year: u16,
		month: u16,
		weekday: u16,
		day: u16,
		hour: u16,
		minute: u16,
		second: u16,
		millis: u16,
	}
	#[link(name = "kernel32")]
	unsafe extern "system" {
		fn GetSystemTimeAsFileTime(out: *mut u64);
		fn FileTimeToSystemTime(file_time: *const u64, out: *mut SystemTime) -> i32;
		fn SystemTimeToTzSpecificLocalTime(
			zone: *const core::ffi::c_void,
			utc: *const SystemTime,
			local: *mut SystemTime,
		) -> i32;
		fn SystemTimeToFileTime(st: *const SystemTime, out: *mut u64) -> i32;
	}
	let (mut utc, mut local) = (SystemTime::default(), SystemTime::default());
	let (mut now, mut utc_ft, mut local_ft) = (0u64, 0u64, 0u64);
	// SAFETY: each call writes only into the value it is handed. A FILETIME
	// is two u32 halves, low first, which is a u64 on this little-endian
	// target.
	let ok = unsafe {
		GetSystemTimeAsFileTime(&mut now);
		FileTimeToSystemTime(&now, &mut utc) != 0 && {
			utc.millis = 0;
			SystemTimeToTzSpecificLocalTime(std::ptr::null(), &utc, &mut local) != 0
				&& SystemTimeToFileTime(&utc, &mut utc_ft) != 0
				&& SystemTimeToFileTime(&local, &mut local_ft) != 0
		}
	};
	if !ok {
		local = utc;
		local_ft = utc_ft;
	}
	// FILETIME counts 100 ns ticks.
	let ticks = i64::try_from(local_ft).unwrap_or(0) - i64::try_from(utc_ft).unwrap_or(0);
	let offset = i32::try_from(ticks / 600_000_000).unwrap_or(0);
	let when = format!(
		"{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
		local.year, local.month, local.day, local.hour, local.minute, local.second
	);
	(when, offset, String::new())
}

/// Write a run of comments and kept lines, `base` levels deep. A misplaced
/// line kept as written (its text has its own indent, a comment's never
/// does) goes back as it was only where a reload keeps it again, which the
/// model of the reload's stack answers the way the parser will: refused for
/// its indent, or under the kept line before it. A merge or an edit can
/// leave it where it would bind, and there it is written as a comment,
/// which reads the same. `at` names the list and the index of its first
/// line, for settle_kept().
fn push_leads(e: &mut Emit, leads: &[Lead], base: usize, at: (usize, Site, usize)) {
	let mut last_comment = 0;
	for (i, c) in leads.iter().enumerate() {
		if c.blank_before && !e.out.is_empty() {
			e.out.push('\n');
		}
		// A kept line among list elements is part of the list's run.
		if at.1 != Site::Among {
			e.mark(c.line);
		}
		if c.text.starts_with([' ', '\t']) {
			let indent = leading_ws(&c.text);
			let (parent, open, tail) = e.resolve(indent);
			let under = e
				.hold
				.as_deref()
				.is_some_and(|h| indent.len() > h.len() && indent.starts_with(h));
			let keep = match parent {
				None => indent.contains(' '),
				Some(DEAD) => under,
				Some(_) => false,
			};
			if keep {
				if parent.is_none() {
					e.hold = Some(indent.to_string());
				}
				e.refused(indent, open, tail);
				e.verbatim += 1;
				if e.record {
					e.kept_near.extend_from_slice(&e.near[e.flushed..]);
					e.flushed = e.near.len();
				}
				e.out.push_str(&c.text);
				e.out.push('\n');
			} else {
				// Level with the comment or kept field line before it, so the
				// run's nesting reads back the same.
				if e.record {
					e.fell.push((at.0, at.1, at.2 + i, last_comment));
				}
				e.out.extend(std::iter::repeat_n('\t', base + last_comment));
				e.out.push_str(&commented(&c.text));
				e.out.push('\n');
			}
			continue;
		}
		let pad = base + c.depth;
		last_comment = c.depth;
		if !c.text.starts_with('#') {
			// A kept malformed line resolves and holds its column on a reload,
			// open for the lines under it when only its value was wrong.
			let indent = "\t".repeat(pad);
			let (parent, open, tail) = e.resolve(&indent);
			e.hold = None;
			if parent.is_some_and(|p| p != DEAD) && opens_later(&c.text) {
				e.open = open;
				e.tail = tail;
				e.tail.push((indent, ROOT));
			} else {
				e.refused(&indent, open, tail);
			}
		}
		e.out.extend(std::iter::repeat_n('\t', pad));
		push_kept(e, &c.text, pad);
	}
}

/// A kept line, and the raw body and fence it took, if any, which go one
/// level under it, as a field's block does. The body moves with its line.
fn push_kept(e: &mut Emit, text: &str, pad: usize) {
	let Some((line, block)) = text.split_once('\n') else {
		e.out.push_str(text);
		e.out.push('\n');
		return;
	};
	e.out.push_str(line);
	e.out.push('\n');
	let body = e.out.len();
	let fence = match block.rsplit_once('\n') {
		Some((lines, fence)) => {
			for l in lines.split('\n') {
				if !l.is_empty() {
					e.out.extend(std::iter::repeat_n('\t', pad + 1));
				}
				e.out.push_str(l);
				e.out.push('\n');
			}
			fence
		}
		None => block,
	};
	let end = e.out.len();
	e.out.extend(std::iter::repeat_n('\t', pad + 1));
	e.out.push_str(fence);
	e.out.push('\n');
	if e.lines {
		e.bodies.push((body, end, pad + 1));
	}
}

/// A run of canonical lines from one source line on (0: from none), with
/// the blank lines written before it and the spans of its values. As a
/// group, `line` is the first source line of its runs and `parts` the runs.
struct Unit {
	line: usize,
	start: usize,
	end: usize,
	blanks: usize,
	spans: std::ops::Range<usize>,
	parts: std::ops::Range<usize>,
}

fn units_of(e: &Emit) -> Vec<Unit> {
	let text = e.out.as_bytes();
	let mut units: Vec<Unit> = Vec::new();
	let (mut mi, mut bi, mut tag, mut blanks, mut open) = (0, 0, 0, 0, false);
	let mut pos = 0;
	while pos < text.len() {
		let next = line_end(text, pos);
		while mi < e.marks.len() && e.marks[mi].0 <= pos {
			tag = e.marks[mi].1;
			mi += 1;
		}
		while bi < e.bodies.len() && e.bodies[bi].1 <= pos {
			bi += 1;
		}
		let in_body = bi < e.bodies.len() && e.bodies[bi].0 <= pos;
		match units.last_mut() {
			_ if text[pos] == b'\n' && !in_body => {
				blanks += 1;
				open = false;
			}
			Some(u) if open && u.line == tag => u.end = next,
			_ => {
				units.push(Unit {
					line: tag,
					start: pos,
					end: next,
					blanks,
					spans: 0..0,
					parts: 0..0,
				});
				blanks = 0;
				open = true;
			}
		}
		pos = next;
	}
	let mut si = 0;
	for u in &mut units {
		while si < e.spans.len() && e.spans[si].0 < u.start {
			si += 1;
		}
		let from = si;
		while si < e.spans.len() && e.spans[si].0 < u.end {
			si += 1;
		}
		u.spans = from..si;
	}
	for (i, u) in units.iter_mut().enumerate() {
		u.parts = i..i + 1;
	}
	units
}

/// The runs one source line wrote, and every run between them, as one
/// group, with a line inside a raw block or a stacked list counted as the
/// binding line's. A comment the canonical form writes between a dotted
/// line's block and its child sits inside such a group, and the group is
/// kept or rewritten whole (20260925b item 2).
fn group_units(units: &[Unit], owner: &[usize]) -> Vec<Unit> {
	let of = |u: &Unit| owner.get(u.line).copied().unwrap_or(u.line);
	let mut last = vec![
		0;
		owner
			.len()
			.max(units.iter().map(|u| u.line + 1).max().unwrap_or(0))
	];
	for (i, u) in units.iter().enumerate() {
		last[of(u)] = i;
	}
	let mut groups = Vec::new();
	let mut i = 0;
	while i < units.len() {
		let (mut j, mut line, mut k) = (i, 0, i);
		while k <= j {
			let o = of(&units[k]);
			if o != 0 {
				j = j.max(last[o]);
				line = if line == 0 { o } else { line.min(o) };
			}
			k += 1;
		}
		groups.push(Unit {
			line,
			start: units[i].start,
			end: units[j].end,
			blanks: units[i].blanks,
			spans: units[i].spans.start..units[j].spans.end,
			parts: i..j + 1,
		});
		i = j + 1;
	}
	groups
}

/// Where the line starting at `pos` ends, past its newline.
fn line_end(text: &[u8], pos: usize) -> usize {
	text[pos..]
		.iter()
		.position(|&b| b == b'\n')
		.map_or(text.len(), |i| pos + i + 1)
}

/// The line ending `t` ends with: CRLF, LF or none.
fn eol_of(t: &str) -> &'static str {
	if t.ends_with("\r\n") {
		"\r\n"
	} else if t.ends_with('\n') {
		"\n"
	} else {
		""
	}
}

fn tabs(s: &str) -> usize {
	s.bytes().take_while(|&b| b == b'\t').count()
}

/// The indent a new line `depth` levels down gets: the last one written
/// there, or the nearest shallower one plus a level.
fn indent_for(indents: &[Option<String>], depth: usize, step: &str) -> String {
	let mut j = depth;
	while j > 0 && indents.get(j).is_none_or(|i| i.is_none()) {
		j -= 1;
	}
	let base = indents.get(j).and_then(|i| i.as_deref()).unwrap_or("");
	format!("{}{}", base, step.repeat(depth - j))
}

/// A source line written at `depth`. One whose indent does not nest under
/// the level above it, a dotted path for one, says nothing about the
/// levels after it.
fn note_indent(indents: &mut Vec<Option<String>>, depth: usize, indent: &str) {
	let fits = if depth == 0 {
		indent.is_empty()
	} else {
		!indent.is_empty()
			&& indents
				.get(depth - 1)
				.and_then(|i| i.as_deref())
				.is_none_or(|up| indent.len() > up.len() && indent.starts_with(up))
	};
	if fits {
		indents.resize(depth + 1, None);
		indents[depth] = Some(indent.to_string());
	} else {
		indents.truncate(1);
	}
}

/// A run the edits wrote, indented the way the lines around it are. A raw
/// body keeps its own tabs past the pad, and a kept line its indent.
fn write_run(
	out: &mut String,
	e: &Emit,
	(mut pos, end): (usize, usize),
	indents: &mut Vec<Option<String>>,
	step: &str,
	eol: &str,
) {
	let text = e.out.as_str();
	while pos < end {
		let next = line_end(text.as_bytes(), pos);
		let line = &text[pos..next - 1];
		let b = e.bodies.partition_point(|b| b.0 <= pos);
		match e.bodies[..b].last() {
			Some(&(_, end, pad)) if pos < end => {
				if !line.is_empty() {
					out.push_str(&indent_for(indents, pad, step));
					out.push_str(&line[pad..]);
				}
			}
			_ => {
				let depth = tabs(line);
				if line[depth..].starts_with(' ') {
					out.push_str(line);
				} else {
					let indent = indent_for(indents, depth, step);
					out.push_str(&indent);
					out.push_str(&line[depth..]);
					indents.resize(depth + 1, None);
					indents[depth] = Some(indent);
				}
			}
		}
		out.push_str(eol);
		pos = next;
	}
}

/// A binding line the edits rewrote, with the name written the way the
/// source line wrote it. None unless both lines bind one plain name.
fn authored_head(src: &str, canon: &str) -> Option<String> {
	let t = trim_wsp_end(src.strip_suffix('\n').unwrap_or(src));
	let ilen = t.bytes().take_while(|&b| b == b' ' || b == b'\t').count();
	let rest = t[ilen..].trim_start_matches(is_wsp);
	let head = t.len() - rest.len();
	let c = &canon[tabs(canon)..];
	let mut tok = Tokens::default();
	let mut sep = [0; 2];
	for (k, text) in [rest, c].into_iter().enumerate() {
		if !is_field_text(text) {
			return None;
		}
		tokenize(text, b':', false, Rules::Current, &mut tok);
		if tok.segments.len() != 1 || tok.segments[0].selector.is_some() || tok.fault.is_some() {
			return None;
		}
		sep[k] = tok.sep?;
	}
	Some(format!("{}{}", &t[..head + sep[0] + 1], &c[sep[1] + 1..]))
}

/// A run whose only change is its last value, written into the source line
/// in place of the old one, so the name, spacing and comment stay as they
/// were. None when anything else changed or the line is not a plain field.
fn splice_value(line: &str, was: &Emit, w: &Unit, now: &Emit, u: &Unit) -> Option<String> {
	let (s0, s1) = (&was.spans[w.spans.clone()], &now.spans[u.spans.clone()]);
	if s0.is_empty() || s0.len() != s1.len() {
		return None;
	}
	let (t0, t1) = (&was.out, &now.out);
	let (mut p0, mut p1) = (w.start, u.start);
	for (k, (a, b)) in s0.iter().zip(s1).enumerate() {
		if t0[p0..a.0] != t1[p1..b.0] || (k + 1 < s0.len() && t0[a.0..a.1] != t1[b.0..b.1]) {
			return None;
		}
		(p0, p1) = (a.1, b.1);
	}
	if t0[p0..w.end] != t1[p1..u.end] {
		return None;
	}
	let last = s1[s1.len() - 1];
	let value = &t1[last.0..last.1];
	let t = trim_wsp_end(line.strip_suffix('\n').unwrap_or(line));
	let tail = &line[t.len()..];
	let ilen = t.bytes().take_while(|&b| b == b' ' || b == b'\t').count();
	let rest = t[ilen..].trim_start_matches(is_wsp);
	let head = t.len() - rest.len();
	if !is_field_text(rest) {
		return None;
	}
	let mut tok = Tokens::default();
	tokenize(rest, b':', false, Rules::Current, &mut tok);
	let colon = tok.sep?;
	let (a, b) = path_of(&tok, rest).ok()?.value?;
	if fence_open(&rest[a..b]).is_some() || tok.array_fault.is_some() {
		return None;
	}
	// The blanks after the colon stay as they were when there was a value
	// and still is one; the canonical value comes with one space.
	let (gap, value, from) = match value.strip_prefix(' ') {
		Some(v) if a != b => (&rest[colon + 1..a], v, b),
		_ if a == b => ("", value, colon + 1),
		_ => ("", value, b),
	};
	Some(format!(
		"{}{}{}{}{}",
		&t[..head + colon + 1],
		gap,
		value,
		&rest[from..],
		tail
	))
}

/// splice_value() for a group: the runs line up one for one and differ in
/// one, the last its source line wrote, so the line's last value is its
/// value. The line and its new text.
fn splice_group(
	lines: &[&str],
	was: &Emit,
	(wr, w): (&[Unit], &Unit),
	now: &Emit,
	(ur, u): (&[Unit], &Unit),
) -> Option<(usize, String)> {
	let (a, b) = (&wr[w.parts.clone()], &ur[u.parts.clone()]);
	if a.len() != b.len() {
		return None;
	}
	let mut hit = None;
	for (k, (x, y)) in a.iter().zip(b).enumerate() {
		if x.line != y.line || x.blanks != y.blanks {
			return None;
		}
		if was.out[x.start..x.end] != now.out[y.start..y.end] {
			if hit.is_some() {
				return None;
			}
			hit = Some(k);
		}
	}
	let k = hit?;
	if a[k + 1..].iter().any(|x| x.line == a[k].line) {
		return None;
	}
	let line = lines.get(a[k].line.wrapping_sub(1))?;
	let t = splice_value(line, was, &a[k], now, &b[k])?;
	Some((a[k].line, t))
}

/// to_text_keep_lines() on a loaded text: the loaded document's canonical
/// runs line up with the text by the source line each came from, and the
/// edited document's runs that match one exactly take that line's text.
/// None when the result would not reload as `doc`.
fn keep_lines(src: &str, doc: &Document) -> Option<String> {
	// A text that was canonical keeps its lines as the canonical form.
	if src.is_empty() {
		return Some(doc.to_canonical());
	}
	let now = doc.emit_marked();
	let mut p = Parser::new();
	p.track_dropped = true;
	let loaded_doc = p.parse(src, doc.strictness);
	let loaded = loaded_doc.emit_marked();
	if now.out == loaded.out {
		return Some(src.to_string());
	}
	let (bom, body) = match src.strip_prefix('\u{feff}') {
		Some(b) => ("\u{feff}", b),
		None => ("", src),
	};
	let mut lines: Vec<&str> = Vec::new();
	let mut pos = 0;
	while pos < body.len() {
		let next = line_end(body.as_bytes(), pos);
		lines.push(&body[pos..next]);
		pos = next;
	}
	let n = lines.len();
	let line = |l: usize| lines[l - 1];
	let blank = |l: usize| trim_wsp(line(l).trim_end_matches('\n')).is_empty();
	let indent = |l: usize| {
		let t = line(l);
		&t[..t.bytes().take_while(|&b| b == b' ' || b == b'\t').count()]
	};
	// The lines each source line stands for: its own, through the end of a
	// raw block or a stacked list. Ranges that overlap, as a list taken up
	// again further down, run together, and each line in a run counts as
	// the run's first line, which stands for the whole run.
	let mut own: Vec<usize> = (0..n + 2).collect();
	for &(l, e) in &loaded_doc.ends {
		if l <= n {
			own[l] = own[l].max(e.min(n));
		}
	}
	let mut owner: Vec<usize> = (0..n + 2).collect();
	let mut end = own.clone();
	let (mut first, mut reach) = (0, 0);
	for k in 1..=n {
		if k <= reach {
			owner[k] = first;
		} else {
			first = k;
		}
		reach = reach.max(own[k]);
		end[first] = reach;
	}
	let (was_runs, is_runs) = (units_of(&loaded), units_of(&now));
	let (was, is) = (
		group_units(&was_runs, &owner),
		group_units(&is_runs, &owner),
	);
	// Each source line's group in the loaded text, and the lines it stands
	// for, through its last run's.
	let mut at = vec![NIL; n + 2];
	for (i, g) in was.iter().enumerate() {
		if g.line != 0 && g.line <= n {
			at[g.line] = i;
			for r in &was_runs[g.parts.clone()] {
				if r.line != 0 && r.line <= n {
					end[g.line] = end[g.line].max(end[owner[r.line]]);
				}
			}
		}
	}
	let claimed: Vec<usize> = (1..=n).filter(|&l| at[l] != NIL).collect();
	// The first group after each one's lines, for telling two that sat next
	// to each other.
	let mut next = vec![0; n + 2];
	for &l in &claimed {
		next[l] = claimed.partition_point(|&c| c <= end[l]);
		next[l] = claimed.get(next[l]).copied().unwrap_or(n + 1);
	}
	// A line no group stands for, as a repeat the load folded away, goes out
	// only as it was written, between two kept groups or at either end. One
	// that is not blank and is left out makes the save fall back, since
	// every line no edit touched has to come back (20260925c item 1).
	let mut left: Vec<bool> = (0..n + 2)
		.map(|l| (1..=n).contains(&l) && !blank(l))
		.collect();
	for &l in &claimed {
		left[l..=end[l].min(n)].fill(false);
	}
	// A repeat the load folded away goes when the edits took every line
	// under it, and the blank lines above it go along: the field is still
	// written where it first was. A remove writes no line the document did
	// not write before (2026100115323232).
	let mut present = vec![false; n + 2];
	for r in &is_runs {
		if r.line != 0 && r.line <= n {
			present[owner[r.line]] = true;
		}
	}
	let mut tagged = vec![false; n + 2];
	for r in &was_runs {
		if r.line != 0 && r.line <= n {
			tagged[owner[r.line]] = true;
		}
	}
	let mut dropped = vec![false; n + 2];
	for &k in &loaded_doc.dropped {
		if k <= n {
			dropped[k] = true;
		}
	}
	let mut released = vec![false; n + 2];
	for h in (1..=n).rev() {
		if !left[h] || dropped[h] {
			continue;
		}
		let (mut any, mut all) = (false, true);
		for k in h + 1..=n {
			if blank(k) {
				continue;
			}
			// A line in a raw body or a stacked list is under h when the line
			// it belongs to is, whatever its own indent.
			let o = owner[k];
			let i = indent(k);
			if o == k && !(i.len() > indent(h).len() && i.starts_with(indent(h))) {
				break;
			}
			any = true;
			let gone = released[k] || (tagged[o] && !present[o]);
			if !gone {
				all = false;
				break;
			}
		}
		if any && all {
			left[h] = false;
			released[h] = true;
		}
	}
	// New lines end the way most of the file's lines do.
	let eol = majority_eol(body);
	// One level of the source's indent: the one most blocks use for a line
	// one level in, each block counted once, by its first such line. A tie
	// goes to one tab when that is among them, else to the block first in
	// the file, so one odd block does not set it (2026100115403386). Failing
	// that, the first indented line, a list element or a fence.
	let mut firsts: Vec<usize> = was_runs
		.iter()
		.filter(|u| u.line != 0 && u.line <= n && tabs(&loaded.out[u.start..]) == 1)
		.map(|u| u.line)
		.filter(|&l| !indent(l).is_empty())
		.collect();
	firsts.sort_unstable();
	let mut steps: Vec<(&str, usize)> = Vec::new();
	let (mut top, mut block, mut k) = (0, usize::MAX, 1);
	for &l in &firsts {
		while k <= l {
			if owner[k] == k && !blank(k) && indent(k).is_empty() && !line(k).starts_with('#') {
				top = k;
			}
			k += 1;
		}
		if block == top {
			continue;
		}
		block = top;
		match steps.iter_mut().find(|s| s.0 == indent(l)) {
			Some(s) => s.1 += 1,
			None => steps.push((indent(l), 1)),
		}
	}
	let most = steps.iter().map(|s| s.1).max().unwrap_or(0);
	let step = if steps.iter().any(|s| s.1 == most && s.0 == "\t") {
		"\t"
	} else {
		steps
			.iter()
			.find(|s| s.1 == most)
			.map(|s| s.0)
			.or_else(|| {
				(1..=n)
					.filter(|&l| !blank(l))
					.map(indent)
					.find(|i| !i.is_empty())
			})
			.unwrap_or("\t")
	};
	let mut out = String::with_capacity(src.len() + now.out.len() / 8);
	out.push_str(bom);
	let break_line = |out: &mut String| {
		if out.len() > bom.len() && !out.ends_with('\n') {
			out.push_str(eol);
		}
	};
	// Which source lines went out as written. Every line the load dropped
	// has to, or the save falls back: a rewritten group can span one, as a
	// stacked list over a refused element (20260926 item 1).
	let mut wrote = vec![false; n + 2];
	// The lines no group stands for that sat right after a kept group, when
	// the group that followed it then does not follow it now. They go out
	// before the next source group, a new line not indented past them, or
	// the end. A new line indented past them goes first, since one written
	// under a dropped line would be dropped with it. A line the load dropped
	// comes back this way.
	let flush =
		|out: &mut String, left: &mut [bool], wrote: &mut [bool], from: usize, to: usize| {
			// The blank lines among them stay, up to the last one written.
			let last = (from..to).rev().find(|&k| left[k]).unwrap_or(0);
			for (k, l) in left.iter_mut().enumerate().take(to).skip(from) {
				if *l {
					out.push_str(line(k));
					wrote[k] = true;
					*l = false;
				} else if k < last && blank(k) {
					out.push_str(line(k));
				}
			}
		};
	let mut indents: Vec<Option<String>> = vec![Some(String::new())];
	// The line of the group just written while it is a source one, and the
	// end of the last source group met, kept or not.
	let (mut prev, mut reach) = (0, 0);
	// The last kept group whose following lines are still to go out.
	let mut owed = 0;
	for (i, u) in is.iter().enumerate() {
		let l = u.line;
		let known = l != 0 && l <= n && at[l] != NIL;
		if known {
			// The canonical form writes this above a source line that sat
			// above it: blocks folded together from two places, or a
			// selector's child under an earlier block. Keeping some of the
			// lines would move the others, so the save falls back.
			if l <= reach {
				return None;
			}
			reach = end[l];
		}
		let from = known.then(|| &was[at[l]]);
		let same = from.is_some_and(|w| loaded.out[w.start..w.end] == now.out[u.start..u.end]);
		let spliced = match from {
			Some(w) if !same => splice_group(&lines, &loaded, (&was_runs, w), &now, (&is_runs, u)),
			_ => None,
		};
		let kept = same || spliced.is_some();
		// The blank lines above a group stay while it has a blank before it.
		// The canonical form can write that blank inside a kept group, as a
		// dotted line's child's, while the source has it above.
		let blanks_stay = u.blanks > 0
			|| (kept
				&& is_runs[u.parts.start + 1..u.parts.end]
					.iter()
					.any(|r| r.blanks > 0));
		// Between two groups that stay next to each other, the source's own
		// lines: a repeat the load folded away stays, and so do the blank
		// lines. The same before the first group. Before any other group from
		// the source, its own blank lines.
		break_line(&mut out);
		let depth = tabs(&now.out[u.start..u.end]);
		if owed != 0
			&& if known {
				!(kept && prev == owed && next[prev] == l)
			} else {
				let ind = indent_for(&indents, depth, step);
				(end[owed] + 1..next[owed])
					.find(|&k| left[k])
					.is_some_and(|k| ind.len() <= indent(k).len() || !ind.starts_with(indent(k)))
			} {
			flush(&mut out, &mut left, &mut wrote, end[owed] + 1, next[owed]);
			break_line(&mut out);
			owed = 0;
		}
		if known {
			owed = 0;
		}
		if i == 0 {
			if kept && claimed.first() == Some(&l) {
				(1..l).for_each(|k| {
					out.push_str(line(k));
					wrote[k] = true;
					left[k] = false;
				});
			}
		} else if kept && prev != 0 && next[prev] == l {
			let gap = end[prev] + 1..l;
			let blanks = gap.clone().any(blank);
			// A blank line above a source line written here stays with it.
			let last = gap.clone().rev().find(|&k| !blank(k)).unwrap_or(0);
			for k in gap {
				if blanks_stay || !blank(k) || k < last {
					out.push_str(line(k));
					wrote[k] = true;
					left[k] = false;
				}
			}
			if !blanks {
				(0..u.blanks).for_each(|_| out.push_str(eol));
			}
		} else if known && blanks_stay && l > 1 && blank(l - 1) {
			let mut k = l - 1;
			while k > 1 && blank(k - 1) {
				k -= 1;
			}
			(k..l).for_each(|k| out.push_str(line(k)));
		} else {
			(0..u.blanks).for_each(|_| out.push_str(eol));
		}
		if kept {
			// A spliced line's value replaces the lines it took, as a
			// stacked list's elements.
			let mut k = l;
			while k <= end[l] {
				match &spliced {
					Some((s, t)) if *s == k => {
						out.push_str(t);
						k = own[k];
					}
					_ => {
						out.push_str(line(k));
						wrote[k] = true;
					}
				}
				k += 1;
			}
			// A line kept as written holds no level's indent.
			if !now.out[u.start + depth..].starts_with(' ') {
				let head = was_runs[from.map_or(0, |w| w.parts.start)].line;
				note_indent(&mut indents, depth, indent(head));
			}
			prev = l;
			owed = l;
		} else {
			// A binding the edits rewrote keeps its line's indent and name.
			let mut from = u.start;
			if known && u.parts.len() == 1 {
				let first = line_end(now.out.as_bytes(), u.start);
				if let Some(t) = authored_head(line(l), &now.out[u.start..first - 1]) {
					out.push_str(&t);
					// A changed line keeps its own line ending.
					let own_eol = eol_of(line(l));
					out.push_str(if own_eol.is_empty() { eol } else { own_eol });
					note_indent(&mut indents, depth, indent(l));
					from = first;
				}
			}
			write_run(&mut out, &now, (from, u.end), &mut indents, step, eol);
			prev = 0;
		}
	}
	if owed != 0 {
		break_line(&mut out);
		flush(&mut out, &mut left, &mut wrote, end[owed] + 1, n + 1);
	}
	// The blank lines the source ends with stay at the end.
	break_line(&mut out);
	let tail = claimed.iter().map(|&l| end[l] + 1).max().unwrap_or(1);
	if out.len() > bom.len() && (tail..=n).all(blank) {
		(tail..=n).for_each(|k| out.push_str(line(k)));
	}
	if left.contains(&true) || loaded_doc.dropped.iter().any(|&k| !wrote[k]) {
		return None;
	}
	// So does a last line with no newline. The line that ends the text now
	// can be one kept with the other line ending.
	if !body.is_empty() && !body.ends_with('\n') {
		out.truncate(out.len() - eol_of(&out).len());
	}
	// The reload has to be the document, and it may not load with an error
	// the source did not have: a child the edits gave an element list that
	// stayed stacked reads back the same and is E001 (20260925b item 1). A
	// line the load dropped went out as written, and the reload has to drop
	// each one again: one that now binds, even to the same document, reads
	// differently from how the file had it.
	let back = Parser::new().parse(&out, doc.strictness);
	(back.lost == loaded_doc.lost
		&& back.to_canonical() == now.out
		&& errors_within(&back, &loaded_doc))
	.then_some(out)
}

/// Take the info block out of `leads`, from the lone `##` above its
/// `This config file format is SHCL.` line to the next lone `##`, and each
/// version line `migrate` stamped, with the note under it. A block with no
/// closing `##` ends after its last line written the block's way. A Schema
/// line in a block stays, and so does any other comment around one, even
/// written right against it. Returns how many came off, and whether the last
/// one had a blank above it with no line after it to take that blank.
fn drop_banners(leads: &mut Vec<Lead>) -> (usize, bool) {
	let in_run = |l: &Lead| l.text.starts_with("##") && !l.blank_before;
	let mut keep: Vec<Lead> = Vec::with_capacity(leads.len());
	let (mut removed, mut owed, mut prev_kept) = (0, false, false);
	let mut i = 0;
	while i < leads.len() {
		let mut start = i;
		let mut end = i + 1;
		if leads[i].text == BANNER_TITLE {
			if prev_kept && !leads[i].blank_before && leads[i - 1].text == "##" {
				keep.pop();
				start = i - 1;
			}
			match (end..leads.len())
				.take_while(|&k| in_run(&leads[k]))
				.find(|&k| leads[k].text == "##")
			{
				Some(close) => end = close + 1,
				None => {
					while end < leads.len()
						&& in_run(&leads[end])
						&& (leads[end].text.starts_with("##    ") || leads[end].text == BANNER_NAME)
					{
						end += 1;
					}
				}
			}
		} else if leads[i].text.starts_with(FORMAT_LINE_HEAD) {
			if end < leads.len() && in_run(&leads[end]) && leads[end].text == MIGRATED_LINE {
				end += 1;
			}
		} else {
			keep.push(leads[i].clone());
			prev_kept = true;
			i += 1;
			continue;
		}
		// The blank that set the block off moves to whatever followed it, so
		// the lines around it stay apart. A Schema line in the block is the
		// author's and stays, with the blank.
		let blank = leads[start].blank_before;
		let at = keep.len();
		keep.extend(
			leads[start..end]
				.iter()
				.filter(|l| l.text.starts_with(SCHEMA_LINE_HEAD))
				.cloned(),
		);
		if let Some(first) = keep.get_mut(at) {
			first.blank_before = blank;
		} else {
			match leads.get_mut(end) {
				Some(next) => next.blank_before |= blank,
				None => owed = blank,
			}
		}
		removed += 1;
		prev_kept = false;
		i = end;
	}
	if removed > 0 {
		// What followed a block steps up to fit the run.
		restep(&mut keep);
		*leads = keep;
	}
	(removed, owed)
}

/// Each error code `d` loads with, `of` loaded with at least as often.
fn errors_within(d: &Document, of: &Document) -> bool {
	let codes = |d: &Document| {
		let mut c: Vec<&str> = d
			.diags
			.iter()
			.filter(|x| x.severity == Severity::Error)
			.map(|x| x.code)
			.collect();
		c.sort_unstable();
		c
	};
	let (mine, theirs) = (codes(d), codes(of));
	let mut j = 0;
	for c in mine {
		while j < theirs.len() && theirs[j] < c {
			j += 1;
		}
		if theirs.get(j) != Some(&c) {
			return false;
		}
		j += 1;
	}
	true
}

/// Inline comment, canonically two spaces before the `#`.
fn push_trailing(out: &mut String, trailing: &str) {
	if !trailing.is_empty() {
		out.push_str("  ");
		out.push_str(trailing);
	}
}

/// Emit a stored (escape-resolved) name in a spelling that reads back as the
/// same name: bare when the spelling rule allows it, else quoted the way a
/// value is, escapes and all.
fn escape_name(name: &str) -> std::borrow::Cow<'_, str> {
	if name.as_bytes().first().is_some_and(u8::is_ascii_alphabetic)
		&& name.bytes().all(is_bare_name_byte)
	{
		return std::borrow::Cow::Borrowed(name);
	}
	std::borrow::Cow::Owned(quote_text(name))
}

fn emit_name(name: &str) -> std::borrow::Cow<'_, str> {
	escape_name(name)
}

/// A field name for a diagnostic message: put the way the emitter would
/// write it, so a name with a line break, a dot or a quote cannot pose as
/// something it is not - a raw `a.b` reads exactly like `a` nesting `b`, and a
/// raw line break splits one diagnostic across two.
fn diag_name(name: &str) -> String {
	emit_name(name).into_owned()
}

/// One element of a value, written for a diagnostic message: the emitter's
/// inline spelling, so a value with a line break cannot split one
/// diagnostic across two.
fn diag_element(e: &Element) -> String {
	emit_element(e).into_owned()
}

/// A value for a diagnostic message. Only a scalar reaches this today, from
/// the H001 hint; a raw block has no one-line form worth suggesting.
fn diag_value(v: &Value) -> String {
	match v {
		Value::Cell(e) => diag_element(e),
		Value::Empty | Value::Array(_) | Value::Raw(_) => v.display(),
	}
}

/// Render a float the way the writer and the CLI do: shortest round-trip
/// decimal, never scientific notation, `inf`/`-inf`/`NaN` spelled out. Rust's
/// own Display already does exactly that, which is why this is a wrapper - the
/// other three bindings have to implement it, and a consumer building canonical
/// text by hand should not have to know which of the four they are reading.
#[must_use]
pub fn format_float(v: f64) -> String {
	let s = format!("{v}");
	if !v.is_finite() || v == 0.0 {
		return s;
	}
	// The shortest spelling that reads back is the same in every binding
	// except on an exact tie between two spellings of that length, where core
	// rounds away from zero and Go, Python and C round to even. The correctly
	// rounded spelling of the same length is the to-even one, so use it when
	// it reads back; when it does not (a lopsided interval at a power of
	// two), the shortest one is the only choice and all four agree already.
	let sig = s
		.trim_start_matches('-')
		.replace('.', "")
		.trim_start_matches('0')
		.trim_end_matches('0')
		.len()
		.max(1);
	let e = format!("{v:.*e}", sig - 1);
	if e.parse::<f64>() != Ok(v) {
		return s;
	}
	let (mant, exp) = e.split_once('e').unwrap_or((&e, "0"));
	let digits: String = mant.chars().filter(char::is_ascii_digit).collect();
	let point = exp.parse::<i64>().unwrap_or(0) + 1;
	let mut out = String::new();
	if v.is_sign_negative() {
		out.push('-');
	}
	if point <= 0 {
		out.push_str("0.");
		out.extend(std::iter::repeat_n('0', (-point) as usize));
		out.push_str(&digits);
	} else if point as usize >= digits.len() {
		out.push_str(&digits);
		out.extend(std::iter::repeat_n('0', point as usize - digits.len()));
	} else {
		out.push_str(&digits[..point as usize]);
		out.push('.');
		out.push_str(&digits[point as usize..]);
	}
	out
}

/// Quote one path segment so it can be spliced into a lookup path: a bare name
/// passes through, anything else comes back quoted and escaped in the form the
/// path scanner accepts. Splicing user-typed text into a path without this is
/// path injection - a dotted name silently reads as nesting. Same spelling
/// `paths()` and the canonical emitter produce.
pub fn quote_segment(name: &str) -> String {
	emit_name(name).into_owned()
}

/// The file tier's read half on its own: the text of PATH, or the status that
/// says why not - `NotFound`, or `Unreadable` for everything else (permissions,
/// a directory, bad encoding, or a file past MAX_BYTES; 0 is no cap).
/// `load_file` is this plus a parse. A consumer that needs the exact bytes it
/// last saw - to tell its own save coming back as a change notification from
/// somebody else's edit - or a bound on how much it will read before a parse,
/// calls this and parses the text itself.
pub fn read_file(path: &str, max_bytes: usize) -> Result<String, FileStatus> {
	use std::io::Read;
	let f = std::fs::File::open(path).map_err(|e| {
		if e.kind() == std::io::ErrorKind::NotFound {
			FileStatus::NotFound
		} else {
			FileStatus::Unreadable
		}
	})?;
	// One byte past the cap is read, so a file exactly at it passes and one
	// over is caught without trusting a length from metadata.
	let limit = if max_bytes == 0 {
		u64::MAX
	} else {
		(max_bytes as u64).saturating_add(1)
	};
	let mut bytes = Vec::new();
	f.take(limit)
		.read_to_end(&mut bytes)
		.map_err(|_| FileStatus::Unreadable)?;
	if max_bytes != 0 && bytes.len() > max_bytes {
		return Err(FileStatus::Unreadable);
	}
	String::from_utf8(bytes).map_err(|_| FileStatus::Unreadable)
}

/// The file tier's write mechanism (also what the CLI's `--write` uses): a
/// temp file in the same dir, then a rename over the target,
/// so an interrupted write can never truncate the config it rewrites. The data
/// is synced before the rename so a crash cannot publish an empty file.
///
/// A rename publishes a new inode, so the target is resolved through symlinks
/// first (otherwise a linked-in config gets replaced by a regular file and the
/// real one is left stale) and the original's mode is copied onto the temp file
/// (otherwise a 600 config comes back at whatever the umask allows). Other hard
/// links to the old inode cannot survive a rename and keep the old content.
pub fn write_file_atomic(file: &str, data: &str) -> Result<(), String> {
	use std::io::Write;
	if names_a_directory(file) {
		return Err(format!("{}: Is a directory", file));
	}
	let target = resolve_target(file).map_err(|e| format!("{}: {}", file, e))?;
	let dir = match target.parent() {
		Some(d) if !d.as_os_str().is_empty() => d,
		_ => std::path::Path::new("."),
	};
	let base = target
		.file_name()
		.map(|b| b.to_string_lossy().into_owned())
		.unwrap_or_else(|| file.to_string());
	// At most the first 64 bytes of the name, cut where a character starts, so the
	// temp's own length is fixed. Keeping the whole name put the temp over the
	// filesystem's 255 bytes at a target name in the low 240s - and the exact
	// cut-off moved with the width of the process id, so the same file saved on one
	// machine and failed on another. Bytes, not characters: 64 characters of four
	// bytes each put it back over. A truncated name can collide; the exclusive
	// create and the eight attempts already answer that.
	let mut cut = base.len().min(TMP_NAME_BYTES);
	while !base.is_char_boundary(cut) {
		cut -= 1;
	}
	let base = &base[..cut];
	// Exclusive create: the name is predictable, so anything already sitting
	// there - including a symlink someone else planted - must make this fail
	// rather than be written through. Retry past a stale collision, then give
	// up; refusing to write beats writing somewhere unintended.
	// A file that already exists keeps its own mode, so its temp is born private
	// and the real mode goes on below - the copy is never briefly readable to
	// anyone the original was not. A file that does not exist yet has no mode to
	// preserve, so it takes the one an ordinary create would: 0666 narrowed by
	// the umask, like every other file the user's tools produce.
	let existing = std::fs::metadata(&target).ok();
	// Only a regular file is replaced. A rename over a FIFO or a device node
	// swaps it for a regular file at exit 0. Save outcomes in design.md is the
	// rule for what a save does with each thing it can find at the path.
	if let Some(m) = &existing
		&& !m.is_file()
	{
		let what = if m.is_dir() {
			"Is a directory"
		} else {
			"not a regular file"
		};
		return Err(format!("{}: {}", file, what));
	}
	// The test above cannot see a windows device name; see not_a_disk_file.
	#[cfg(windows)]
	if not_a_disk_file(&target) {
		return Err(format!("{}: not a regular file", file));
	}
	// Windows: a read-only file cannot be replaced, and a read-only temp cannot
	// be removed after a failure, so the attribute comes off the target for the
	// publish and goes back on the new file after it - the same outcome as
	// POSIX, where the rename never needed the file writable. Hidden and system
	// ride back the same way: ReplaceFile's documented preserve list does not
	// include the basic attributes, and the rename fallback keeps nothing, so
	// a hidden config came back visible.
	#[cfg(windows)]
	let read_only = existing
		.as_ref()
		.is_some_and(|m| m.permissions().readonly());
	#[cfg(windows)]
	let carried = {
		use std::os::windows::fs::MetadataExt;
		existing.as_ref().map_or(0, |m| {
			m.file_attributes() & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM)
		})
	};
	let mut file_handle = None;
	let mut tmp = std::path::PathBuf::new();
	let mut last = String::new();
	for attempt in 0..8 {
		tmp = dir.join(format!(".{}.tmp{}.{}", base, std::process::id(), attempt));
		let mut opts = std::fs::OpenOptions::new();
		opts.write(true).create_new(true);
		#[cfg(unix)]
		{
			use std::os::unix::fs::OpenOptionsExt;
			opts.mode(if existing.is_some() { 0o600 } else { 0o666 });
		}
		#[cfg(windows)]
		let opened = if existing.is_some() {
			create_like(&target, &tmp)
		} else {
			opts.open(&tmp)
		};
		#[cfg(not(windows))]
		let opened = opts.open(&tmp);
		match opened {
			Ok(f) => {
				file_handle = Some(f);
				break;
			}
			Err(e) => last = e.to_string(),
		}
	}
	let Some(mut f) = file_handle else {
		return Err(format!("{}: cannot create temporary file: {}", file, last));
	};
	let res = (|| -> std::io::Result<()> {
		f.write_all(data.as_bytes())?;
		f.sync_all()?;
		// On the handle, so umask cannot narrow it the way it narrows a create
		// mode, and after the data, because a write by anyone but root clears
		// setuid/setgid. Best effort: a filesystem that cannot store the mode
		// is not a reason to fail a write that otherwise succeeded. The whole
		// mode goes, setuid/setgid/sticky included, as an editor's rewrite
		// would keep it.
		#[cfg(unix)]
		if let Some(m) = &existing {
			// The group first, because a chown clears setuid/setgid on most
			// systems. Best effort like the mode: a caller who is not in the
			// old group keeps its own, which is what it had before this. The
			// owner is not copied - see the file tier in spec.md.
			use std::os::unix::fs::MetadataExt;
			let _ = std::os::unix::fs::fchown(&f, None, Some(m.gid()));
			let _ = f.set_permissions(m.permissions());
		}
		Ok(())
	})();
	if let Err(e) = res {
		let _ = std::fs::remove_file(&tmp);
		return Err(format!("{}: {}", file, e));
	}
	drop(f);
	#[cfg(windows)]
	if read_only {
		set_read_only(&target, false);
	}
	// Nothing was at the path when the save started, so nothing that turns up
	// before the publish is written over. A failed replace decides for itself
	// whether the temp file can go, since on windows it may be all that is left.
	let published = if existing.is_some() {
		publish_file(&tmp, &target)
	} else {
		publish_new_file(&tmp, &target).inspect_err(|_| {
			let _ = std::fs::remove_file(&tmp);
		})
	};
	#[cfg(windows)]
	if carried != 0 {
		set_attributes(&target, carried); // whether or not the publish went through
	}
	#[cfg(windows)]
	if read_only {
		set_read_only(&target, true); // whether or not the publish went through
	}
	published.map_err(|e| format!("{}: {}", file, e))?;
	sync_dir(dir);
	Ok(())
}

/// A path that names a directory rather than a file: it ends in a separator, or
/// its last component is `.` or `..`. POSIX refuses to open such a path as a
/// regular file, but a canonicalize drops the trailing separator first, so a
/// save through `f/` used to rewrite `f`.
fn names_a_directory(file: &str) -> bool {
	let sep = |c: char| c == '/' || (cfg!(windows) && c == '\\');
	if file.is_empty() {
		return false;
	}
	if file.ends_with(sep) {
		return true;
	}
	let last = file.rsplit(sep).next().unwrap_or("");
	last == "." || last == ".."
}

/// The path a save actually rewrites. A symlink is followed so the write goes
/// through it; canonicalize does that but needs the target to exist, so a
/// dangling link is walked by hand and the file is created where it points.
/// A path that is no link at all is a plain create at the path as given.
/// A link cycle is an error: silently creating a regular file in its place
/// would be the exact replacement the symlink walk exists to avoid.
fn resolve_target(file: &str) -> Result<std::path::PathBuf, String> {
	if let Ok(p) = std::fs::canonicalize(file) {
		return Ok(p);
	}
	let mut p = std::path::PathBuf::from(file);
	for _ in 0..40 {
		let Ok(next) = std::fs::read_link(&p) else {
			break;
		};
		// A link whose text ends in a separator, `.` or `..` can only reach a
		// directory, and the kernel refuses to create a file through it. The
		// path join below would drop the separator.
		if names_a_directory(&next.to_string_lossy()) {
			return Err("Is a directory".to_string());
		}
		p = if next.is_absolute() {
			next
		} else {
			p.parent()
				.filter(|d| !d.as_os_str().is_empty())
				.unwrap_or(std::path::Path::new("."))
				.join(next)
		};
	}
	if std::fs::read_link(&p).is_ok() {
		return Err("too many levels of symbolic links".to_string());
	}
	Ok(match (p.parent(), p.file_name()) {
		(Some(d), Some(n)) if !d.as_os_str().is_empty() => {
			std::fs::canonicalize(d).map(|d| d.join(n)).unwrap_or(p)
		}
		_ => p,
	})
}

#[cfg(windows)]
const FILE_TYPE_DISK: u32 = 0x1;

/// Something is at the path and it is not a disk file: a device name such as
/// CON, NUL or COM1. `std::fs::metadata` cannot see one - a device answers with
/// the same ARCHIVE bit an ordinary file does - so a save read it as a file,
/// tried to replace it, and the refusal came from whichever later step happened
/// to fail. False for a path with nothing at it, which is a save's ordinary
/// create.
#[cfg(windows)]
fn not_a_disk_file(path: &std::path::Path) -> bool {
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
	const FILE_READ_ATTRIBUTES: u32 = 0x80;
	const FILE_SHARE_ALL: u32 = 0x7;
	const OPEN_EXISTING: u32 = 3;
	const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
	const MAX_PATH: usize = 260;
	let wide: Vec<u16> = path
		.as_os_str()
		.encode_wide()
		.chain(std::iter::once(0))
		.collect();
	unsafe {
		// The handle first, since it is the OS's own answer and it keeps an
		// exotic but real path (a volume-prefixed `\\.\C:\dir\file`) out of the
		// device case.
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
		// CON refuses that open outright (ERROR_INVALID_PARAMETER), and a serial
		// port nobody has answers not-found, so a failed open cannot mean
		// "nothing is there". A reserved name resolves into the device namespace
		// from whatever directory it is typed in, and the full path is where that
		// shows: `\\.\CON` against a drive path for an ordinary name. A long path
		// overflows the buffer and falls through to the create, which is what it
		// did before.
		let mut full = [0u16; MAX_PATH];
		let n = GetFullPathNameW(
			wide.as_ptr(),
			MAX_PATH as u32,
			full.as_mut_ptr(),
			std::ptr::null_mut(),
		) as usize;
		// A drive after the prefix is a volume path to a file that is not
		// there yet, which a create has to be let through (20260926 item 8).
		let drive =
			full[4] < 128 && (full[4] as u8).is_ascii_alphabetic() && full[5] == u16::from(b':');
		n > 0
			&& n < MAX_PATH
			&& full[0] == u16::from(b'\\')
			&& full[1] == u16::from(b'\\')
			&& full[2] == u16::from(b'.')
			&& full[3] == u16::from(b'\\')
			&& !drive
	}
}

#[cfg(windows)]
const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
#[cfg(windows)]
const FILE_ATTRIBUTE_SYSTEM: u32 = 0x4;

#[cfg(windows)]
fn set_read_only(path: &std::path::Path, on: bool) {
	if let Ok(m) = std::fs::metadata(path) {
		let mut perms = m.permissions();
		perms.set_readonly(on);
		let _ = std::fs::set_permissions(path, perms);
	}
}

/// Turn attribute bits back on after a publish. std has no setter for the basic
/// attributes, so this is a few lines of FFI beside the ReplaceFile ones.
#[cfg(windows)]
fn set_attributes(path: &std::path::Path, bits: u32) {
	use std::os::windows::ffi::OsStrExt;
	use std::os::windows::fs::MetadataExt;
	#[link(name = "kernel32")]
	unsafe extern "system" {
		fn SetFileAttributesW(name: *const u16, attrs: u32) -> i32;
	}
	let Ok(m) = std::fs::metadata(path) else {
		return;
	};
	let wide: Vec<u16> = path
		.as_os_str()
		.encode_wide()
		.chain(std::iter::once(0))
		.collect();
	unsafe {
		SetFileAttributesW(wide.as_ptr(), m.file_attributes() | bits);
	}
}

/// The exclusive create of a save's temp file over an existing file. A plain
/// create takes the directory's ACL, so the new text of a private config sat
/// where others could read it until the replace, and a fallback move published
/// that wider ACL. The temp is born with the file's DACL instead. Best effort:
/// when that cannot be read, the directory's it is, as for a new file.
#[cfg(windows)]
fn create_like(from: &std::path::Path, to: &std::path::Path) -> std::io::Result<std::fs::File> {
	use std::os::windows::ffi::OsStrExt;
	use std::os::windows::io::FromRawHandle;
	#[repr(C)]
	struct SecurityAttributes {
		length: u32,
		descriptor: *mut u64,
		inherit: i32,
	}
	#[link(name = "advapi32")]
	unsafe extern "system" {
		fn GetFileSecurityW(
			name: *const u16,
			info: u32,
			sd: *mut u64,
			len: u32,
			need: *mut u32,
		) -> i32;
		fn SetFileSecurityW(name: *const u16, info: u32, sd: *mut u64) -> i32;
		fn GetSecurityDescriptorControl(sd: *mut u64, control: *mut u16, revision: *mut u32)
		-> i32;
		fn SetSecurityDescriptorControl(sd: *mut u64, mask: u16, bits: u16) -> i32;
	}
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
	}
	const DACL_SECURITY_INFORMATION: u32 = 0x4;
	const SE_DACL_AUTO_INHERIT_REQ: u16 = 0x0100;
	const SE_DACL_AUTO_INHERITED: u16 = 0x0400;
	const GENERIC_WRITE: u32 = 0x4000_0000;
	const FILE_SHARE_ALL: u32 = 0x7;
	const CREATE_NEW: u32 = 1;
	const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
	let wide = |p: &std::path::Path| -> Vec<u16> {
		p.as_os_str()
			.encode_wide()
			.chain(std::iter::once(0))
			.collect()
	};
	let (src, dst) = (wide(from), wide(to));
	// u64 words, since a security descriptor wants more than byte alignment.
	let mut sd: Vec<u64> = Vec::new();
	let mut need = 0u32;
	unsafe {
		GetFileSecurityW(
			src.as_ptr(),
			DACL_SECURITY_INFORMATION,
			std::ptr::null_mut(),
			0,
			&mut need,
		);
		if need > 0 {
			sd.resize((need as usize).div_ceil(8), 0);
			let len = (sd.len() * 8) as u32;
			if GetFileSecurityW(
				src.as_ptr(),
				DACL_SECURITY_INFORMATION,
				sd.as_mut_ptr(),
				len,
				&mut need,
			) == 0
			{
				sd.clear();
			}
		}
		let sa = SecurityAttributes {
			length: std::mem::size_of::<SecurityAttributes>() as u32,
			descriptor: sd.as_mut_ptr(),
			inherit: 0,
		};
		let handle = CreateFileW(
			dst.as_ptr(),
			GENERIC_WRITE,
			FILE_SHARE_ALL,
			if sd.is_empty() {
				std::ptr::null()
			} else {
				(&raw const sa).cast()
			},
			CREATE_NEW,
			FILE_ATTRIBUTE_NORMAL,
			0,
		);
		if handle == -1 {
			return Err(std::io::Error::last_os_error());
		}
		// A create takes the ACEs but drops the auto-inherited mark, and without
		// it a later change to the directory's ACL does not reach the file once
		// a fallback move makes the temp the config. Setting the same DACL again
		// with the request bit puts it back.
		let (mut control, mut revision) = (0u16, 0u32);
		if !sd.is_empty()
			&& GetSecurityDescriptorControl(sd.as_mut_ptr(), &mut control, &mut revision) != 0
			&& control & SE_DACL_AUTO_INHERITED != 0
			&& SetSecurityDescriptorControl(
				sd.as_mut_ptr(),
				SE_DACL_AUTO_INHERIT_REQ,
				SE_DACL_AUTO_INHERIT_REQ,
			) != 0
		{
			SetFileSecurityW(dst.as_ptr(), DACL_SECURITY_INFORMATION, sd.as_mut_ptr());
		}
		Ok(std::fs::File::from_raw_handle(handle as _))
	}
}

/// Move the finished temp file over the target. On windows that means
/// ReplaceFile rather than a rename: a rename publishes a brand-new file and
/// leaves the destination's ACLs, security attributes and named streams behind,
/// which ReplaceFile copies onto the replacement instead. What it does not
/// copy is the basic attributes - hidden and system - which the save re-applies
/// by hand. It needs the destination to exist, and it fails rather than skip a
/// merge it cannot do (no WRITE_DAC, say), so a create and any failure fall back
/// to the rename. WRITE_THROUGH is asked for and documented as unsupported by
/// ReplaceFile, so the durability here rests on the file's own fsync.
///
/// A failure removes the temp file, except where nothing is left at the target.
#[cfg(not(windows))]
fn publish_file(tmp: &std::path::Path, target: &std::path::Path) -> std::io::Result<()> {
	std::fs::rename(tmp, target).inspect_err(|_| {
		let _ = std::fs::remove_file(tmp);
	})
}

/// A scanner or an indexer that opens the fresh temp file blocks the replace and
/// the rename both, for a moment, and one try made that a failed save.
#[cfg(windows)]
const PUBLISH_TRIES: u32 = 5;
#[cfg(windows)]
const PUBLISH_PAUSE_MS: u64 = 50;

/// ReplaceFile is given a backup name, because without one a failure between
/// its two moves deletes the old file (1176) or leaves it under a name nobody
/// is told (1177). With one, 1177 leaves it at the backup and nothing at the
/// target, so the old file is put back. If even that fails, neither file is
/// removed and the error says where they are.
#[cfg(windows)]
fn publish_file(tmp: &std::path::Path, target: &std::path::Path) -> std::io::Result<()> {
	let backup = backup_name(tmp);
	let mut moved_away = false;
	let mut tries = 0;
	let err = loop {
		if !moved_away && target.exists() {
			// The save has gone through, so a backup that will not come off
			// is left rather than failing it.
			if windows_replace_file(tmp, target, &backup) {
				let _ = std::fs::remove_file(&backup);
				return Ok(());
			}
			moved_away = !target.exists() && backup.exists();
		}
		let e = match std::fs::rename(tmp, target) {
			Ok(()) => {
				if moved_away {
					let _ = std::fs::remove_file(&backup);
				}
				return Ok(());
			}
			Err(e) => e,
		};
		tries += 1;
		if tries == PUBLISH_TRIES {
			break e;
		}
		std::thread::sleep(std::time::Duration::from_millis(PUBLISH_PAUSE_MS));
	};
	if target.exists() || (moved_away && publish_new_file(&backup, target).is_ok()) {
		let _ = std::fs::remove_file(tmp);
		return Err(err);
	}
	let kept = if moved_away {
		format!(
			"{}; the old file is left at {} and the new text at {}",
			err,
			backup.display(),
			tmp.display()
		)
	} else {
		format!("{}; the new text is left at {}", err, tmp.display())
	};
	Err(std::io::Error::new(err.kind(), kept))
}

/// The temp name with its `.tmp` swapped for `.bak`, so the two sit side by
/// side and are the same length. The last `.tmp` is the one the save added.
#[cfg(windows)]
fn backup_name(tmp: &std::path::Path) -> std::path::PathBuf {
	let name = tmp
		.file_name()
		.map(|n| n.to_string_lossy().into_owned())
		.unwrap_or_default();
	match name.rfind(".tmp") {
		Some(at) => tmp.with_file_name(format!("{}.bak{}", &name[..at], &name[at + 4..])),
		None => tmp.with_file_name(format!("{}.bak", name)),
	}
}

// Here rather than under tests/, since the publish is private. A save always
// puts its temp file beside the target, so these call the publish directly.
#[cfg(all(test, windows))]
mod windows_publish {
	use super::publish_file;
	use std::path::Path;

	fn scratch(tag: &str) -> std::path::PathBuf {
		let d = std::env::temp_dir().join(format!("shcl-publish-{}-{}", tag, std::process::id()));
		let _ = std::fs::remove_dir_all(&d);
		std::fs::create_dir_all(&d).unwrap();
		d
	}

	fn text(p: &Path) -> Option<String> {
		std::fs::read_to_string(p).ok()
	}

	// The status line tests/common prints, since that module is out of reach.
	struct TestId(&'static str);

	fn test_id(id: &'static str) -> TestId {
		TestId(id)
	}

	impl Drop for TestId {
		fn drop(&mut self) {
			use std::io::Write;
			let status = if std::thread::panicking() {
				"FAIL"
			} else {
				"ok"
			};
			let thread = std::thread::current();
			let name = thread.name().unwrap_or("?");
			let _ = writeln!(
				std::io::stderr().lock(),
				"{:<4} {} rust {}",
				status,
				self.0,
				name
			);
		}
	}

	fn icacls(args: &[&str]) {
		let ok = std::process::Command::new("icacls")
			.args(args)
			.output()
			.is_ok_and(|o| o.status.success());
		assert!(ok, "icacls {:?} failed", args);
	}

	// Taking add-file away from the target's folder, with the temp file in
	// another, lets ReplaceFile move the old file out to the backup and then
	// refuses the new one its place: error 1177, with nothing at the target.
	// Neither the rename nor putting the old file back can get in either.
	#[test]
	fn a_failed_publish_loses_neither_file() {
		let _id = test_id("EqYTuc4");
		let root = scratch("kept");
		let (x, y) = (root.join("x"), root.join("y"));
		std::fs::create_dir_all(&x).unwrap();
		std::fs::create_dir_all(&y).unwrap();
		let (target, tmp) = (y.join("t.shcl"), x.join(".t.shcl.tmp1.0"));
		let backup = x.join(".t.shcl.bak1.0");
		std::fs::write(&target, "old\n").unwrap();
		std::fs::write(&tmp, "new\n").unwrap();
		let ydir = y.to_string_lossy().into_owned();
		icacls(&[&ydir, "/deny", "*S-1-1-0:(WD)"]);
		// The hosted runner's administrator is let through anyway, and the
		// case cannot be set up there.
		let probe = x.join("probe");
		std::fs::write(&probe, "").unwrap();
		if std::fs::rename(&probe, y.join("probe")).is_ok() {
			icacls(&[&ydir, "/remove:d", "*S-1-1-0"]);
			eprintln!(
				"conformance: skipping the failed-publish fixture (a move into a denied folder went through)"
			);
			let _ = std::fs::remove_dir_all(&root);
			return;
		}
		let published = publish_file(&tmp, &target);
		icacls(&[&ydir, "/remove:d", "*S-1-1-0"]);
		let msg = published.expect_err("the publish went through").to_string();
		if text(&target).as_deref() == Some("old\n") {
			assert!(!tmp.exists(), "the temp file was left: {}", msg);
		} else {
			assert_eq!(text(&target), None, "{}", msg);
			assert_eq!(text(&backup).as_deref(), Some("old\n"), "{}", msg);
			assert_eq!(text(&tmp).as_deref(), Some("new\n"), "{}", msg);
			assert!(msg.contains(&*backup.to_string_lossy()), "{}", msg);
			assert!(msg.contains(&*tmp.to_string_lossy()), "{}", msg);
		}
		let _ = std::fs::remove_dir_all(&root);
	}

	// Anything holding the temp file open without delete sharing fails the
	// replace and the rename both, the way a scanner looking at a fresh file
	// does. A hold that ends in a few milliseconds must not fail the save.
	#[test]
	fn a_brief_hold_is_waited_out() {
		let _id = test_id("EqYTuc5");
		use std::os::windows::fs::OpenOptionsExt;
		let root = scratch("hold");
		let (target, tmp) = (root.join("t.shcl"), root.join(".t.shcl.tmp1.0"));
		std::fs::write(&target, "old\n").unwrap();
		std::fs::write(&tmp, "new\n").unwrap();
		let hold = std::fs::OpenOptions::new()
			.read(true)
			.share_mode(1) // FILE_SHARE_READ
			.open(&tmp)
			.unwrap();
		let freed = std::thread::spawn(move || {
			std::thread::sleep(std::time::Duration::from_millis(20));
			drop(hold);
		});
		let published = publish_file(&tmp, &target);
		freed.join().unwrap();
		published.unwrap();
		assert_eq!(text(&target).as_deref(), Some("new\n"));
		assert!(!tmp.exists());
		assert!(!root.join(".t.shcl.bak1.0").exists());
		let _ = std::fs::remove_dir_all(&root);
	}

	#[link(name = "advapi32")]
	unsafe extern "system" {
		fn GetFileSecurityW(
			name: *const u16,
			info: u32,
			sd: *mut u64,
			len: u32,
			need: *mut u32,
		) -> i32;
		fn ConvertSecurityDescriptorToStringSecurityDescriptorW(
			sd: *mut u64,
			revision: u32,
			info: u32,
			out: *mut *mut u16,
			len: *mut u32,
		) -> i32;
	}
	#[link(name = "kernel32")]
	unsafe extern "system" {
		fn LocalFree(mem: *mut u16) -> *mut u16;
		fn GetModuleHandleW(name: *const u16) -> isize;
		fn GetProcAddress(module: isize, name: *const u8) -> isize;
	}

	// The file's DACL as SDDL, or None when it cannot be read.
	fn sddl(p: &Path) -> Option<String> {
		use std::os::windows::ffi::OsStrExt;
		const DACL_SECURITY_INFORMATION: u32 = 0x4;
		const SDDL_REVISION_1: u32 = 1;
		let wide: Vec<u16> = p
			.as_os_str()
			.encode_wide()
			.chain(std::iter::once(0))
			.collect();
		let mut need = 0u32;
		unsafe {
			GetFileSecurityW(
				wide.as_ptr(),
				DACL_SECURITY_INFORMATION,
				std::ptr::null_mut(),
				0,
				&mut need,
			);
			if need == 0 {
				return None;
			}
			let mut sd = vec![0u64; (need as usize).div_ceil(8)];
			let len = (sd.len() * 8) as u32;
			if GetFileSecurityW(
				wide.as_ptr(),
				DACL_SECURITY_INFORMATION,
				sd.as_mut_ptr(),
				len,
				&mut need,
			) == 0
			{
				return None;
			}
			let mut out: *mut u16 = std::ptr::null_mut();
			if ConvertSecurityDescriptorToStringSecurityDescriptorW(
				sd.as_mut_ptr(),
				SDDL_REVISION_1,
				DACL_SECURITY_INFORMATION,
				&mut out,
				std::ptr::null_mut(),
			) == 0
			{
				return None;
			}
			let n = (0..).take_while(|&i| *out.add(i) != 0).count();
			let s = String::from_utf16_lossy(std::slice::from_raw_parts(out, n));
			LocalFree(out);
			Some(s)
		}
	}

	fn under_wine() -> bool {
		let ntdll: Vec<u16> = "ntdll.dll"
			.encode_utf16()
			.chain(std::iter::once(0))
			.collect();
		unsafe {
			let m = GetModuleHandleW(ntdll.as_ptr());
			m != 0 && GetProcAddress(m, c"wine_get_version".as_ptr().cast()) != 0
		}
	}

	// A save over a file whose DACL is narrower than its directory's must not
	// put the new text under the directory's. Holding the target without delete
	// sharing fails the publish on every try, which keeps the temp file there
	// long enough for a poller to read its DACL. Same fixture in every runner.
	#[test]
	fn temp_file_takes_the_targets_dacl() {
		let _id = test_id("ErO2NoD");
		use std::os::windows::fs::OpenOptionsExt;
		use std::sync::atomic::{AtomicBool, Ordering};
		if under_wine() {
			eprintln!("conformance: skipping the temp-file DACL fixture (wine keeps no ACLs)");
			return;
		}
		let root = scratch("dacl");
		let dir = root.to_string_lossy().into_owned();
		icacls(&[&dir, "/grant", "*S-1-5-32-545:(OI)(CI)(R)"]);
		let grant = format!("{}:(F)", std::env::var("USERNAME").unwrap());
		let setups: [(&str, Vec<&str>, &str); 2] = [
			("a.shcl", vec!["/inheritance:r", "/grant:r", &grant], "D:P"),
			("b.shcl", vec!["/grant", "*S-1-5-19:(R)"], "D:AI"),
		];
		for (name, acl, prefix) in setups {
			let target = root.join(name);
			let t = target.to_string_lossy().into_owned();
			std::fs::write(&target, "a: 1\n").unwrap();
			let mut args = vec![t.as_str()];
			args.extend(acl);
			icacls(&args);
			let want = sddl(&target).unwrap_or_default();
			assert!(
				want.starts_with(prefix),
				"{}: the fixture did not take: {}",
				name,
				want
			);
			let tmp = root.join(format!(".{}.tmp{}.0", name, std::process::id()));
			let hold = std::fs::OpenOptions::new()
				.read(true)
				.share_mode(1) // FILE_SHARE_READ
				.open(&target)
				.unwrap();
			let stop = std::sync::Arc::new(AtomicBool::new(false));
			let poller = {
				let (stop, tmp) = (stop.clone(), tmp.clone());
				std::thread::spawn(move || {
					let mut seen = None;
					while !stop.load(Ordering::Relaxed) {
						if let Some(s) = sddl(&tmp) {
							seen = Some(s);
						}
					}
					seen
				})
			};
			let saved = super::write_file_atomic(&t, "a: 2\n");
			stop.store(true, Ordering::Relaxed);
			let seen = poller.join().unwrap();
			drop(hold);
			assert!(
				saved.is_err(),
				"{}: a save over a held file went through",
				name
			);
			let seen = seen.unwrap_or_else(|| panic!("{}: the temp file was never seen", name));
			assert_eq!(seen, want, "{}: the temp file's DACL", name);
			let left: Vec<String> = std::fs::read_dir(&root)
				.unwrap()
				.filter_map(|e| e.ok())
				.map(|e| e.file_name().to_string_lossy().into_owned())
				.filter(|n| n.contains(".tmp") || n.contains(".bak"))
				.collect();
			assert!(left.is_empty(), "{}: left behind: {:?}", name, left);
			super::write_file_atomic(&t, "a: 2\n").unwrap();
			assert_eq!(sddl(&target), Some(want), "{}: the saved file's DACL", name);
		}
		let fresh = root.join("n.shcl");
		super::write_file_atomic(&fresh.to_string_lossy(), "a: 2\n").unwrap();
		let plain = root.join("p.shcl");
		std::fs::write(&plain, "a: 2\n").unwrap();
		let born = sddl(&plain);
		assert!(born.is_some(), "the plain file's DACL could not be read");
		assert_eq!(sddl(&fresh), born, "a new file's DACL");
		assert_eq!(
			std::fs::read(&fresh).unwrap(),
			std::fs::read(root.join("b.shcl")).unwrap(),
			"an overwrite and a create wrote different bytes"
		);
		// With no DACL to copy, the create still goes through, with the
		// directory's.
		let copied = root.join("c.shcl");
		drop(super::create_like(&root.join("missing.shcl"), &copied).unwrap());
		assert_eq!(sddl(&copied), born, "a temp file with no DACL to copy");
		let _ = std::fs::remove_dir_all(&root);
	}
}

/// The publish for a save that found nothing at the path, which must not
/// replace a file that turned up since. A hard link fails on anything at the
/// target, so the check and the publish are one step, and the temp name comes
/// off after. The save has gone through by then, so a temp name that will not
/// come off is left rather than failing it. A filesystem with no hard links
/// gets a check and a rename, which leaves only that short gap.
#[cfg(not(windows))]
fn publish_new_file(tmp: &std::path::Path, target: &std::path::Path) -> std::io::Result<()> {
	match std::fs::hard_link(tmp, target) {
		Ok(()) => {
			let _ = std::fs::remove_file(tmp);
			Ok(())
		}
		Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Err(e),
		Err(_) if std::fs::symlink_metadata(target).is_ok() => {
			Err(std::io::ErrorKind::AlreadyExists.into())
		}
		Err(_) => std::fs::rename(tmp, target),
	}
}

/// Windows moves without the replace flag, which refuses an existing target the
/// same way and needs no hard links.
#[cfg(windows)]
fn publish_new_file(tmp: &std::path::Path, target: &std::path::Path) -> std::io::Result<()> {
	use std::os::windows::ffi::OsStrExt;
	const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
	#[link(name = "kernel32")]
	unsafe extern "system" {
		fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
	}
	let wide = |p: &std::path::Path| -> Vec<u16> {
		p.as_os_str()
			.encode_wide()
			.chain(std::iter::once(0))
			.collect()
	};
	let (from, to) = (wide(tmp), wide(target));
	if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_WRITE_THROUGH) } != 0 {
		Ok(())
	} else {
		Err(std::io::Error::last_os_error())
	}
}

#[cfg(windows)]
fn windows_replace_file(
	tmp: &std::path::Path,
	target: &std::path::Path,
	backup: &std::path::Path,
) -> bool {
	use std::os::windows::ffi::OsStrExt;
	const REPLACEFILE_WRITE_THROUGH: u32 = 0x1;
	// Declared here rather than pulled from a crate: this file has no
	// dependencies and is not about to grow one for six lines of FFI.
	#[link(name = "kernel32")]
	unsafe extern "system" {
		fn ReplaceFileW(
			replaced: *const u16,
			replacement: *const u16,
			backup: *const u16,
			flags: u32,
			exclude: *mut core::ffi::c_void,
			reserved: *mut core::ffi::c_void,
		) -> i32;
	}
	fn wide(p: &std::path::Path) -> Vec<u16> {
		p.as_os_str()
			.encode_wide()
			.chain(std::iter::once(0))
			.collect()
	}
	let (replaced, replacement, kept) = (wide(target), wide(tmp), wide(backup));
	unsafe {
		ReplaceFileW(
			replaced.as_ptr(),
			replacement.as_ptr(),
			kept.as_ptr(),
			REPLACEFILE_WRITE_THROUGH,
			std::ptr::null_mut(),
			std::ptr::null_mut(),
		) != 0
	}
}

/// fsync the directory a save published into. The fsync on the file only
/// covered the file; the rename is a directory change, so without this a power
/// cut right after a save can lose the publish and leave the old content. Best
/// effort - windows has no directory fsync, and a filesystem that refuses one
/// is not a reason to fail a write that already succeeded.
fn sync_dir(dir: &std::path::Path) {
	#[cfg(unix)]
	if let Ok(d) = std::fs::File::open(dir) {
		let _ = d.sync_all();
	}
	#[cfg(not(unix))]
	let _ = dir;
}

/// The single H001 wording site: the hint builder and the schema suppressor
/// both come here, so the suppressor matches the exact head the builder
/// emitted - never a re-parse of free prose. (The leaf name cannot ride on
/// Diagnostic itself: consumers build Diagnostic literals, so its field set
/// is frozen.)
fn h001_head(name: &str) -> String {
	let shown = diag_name(name);
	format!(
		"'{}' repeats as a bare leaf - did you mean '{}: ",
		shown, shown
	)
}

/// Drop the H001 hints a schema disavows: a field whose declared repeat upper
/// bound is above 1 repeats BY DESIGN (repetition is its instance mechanism),
/// so the repeated-bare-leaf hint is structurally a false positive there and
/// trains users to ignore hints. Matching is by leaf name - the filter
/// consumers were hand-rolling - which errs toward quiet, for a hint. Used by
/// `check --schema` and load_and_validate; call it wherever doc diagnostics
/// and a schema meet.
pub fn suppress_declared_repeats(schema: &Document, diags: &mut Vec<Diagnostic>) {
	let names = disavowed_names(schema, |c| c.repeat.is_some_and(|(_, hi)| hi > 1));
	if names.is_empty() {
		return;
	}
	let heads: Vec<String> = names.iter().map(|n| h001_head(n)).collect();
	diags.retain(|d| d.code != "H001" || !heads.iter().any(|h| d.message.starts_with(h.as_str())));
}

/// Leaf names of the schema entries `pick` accepts, top-level fields and every
/// fragment's fields alike. Read through the built schema, so the names are
/// the ones validation will use (escapes resolved) and an entry whose key
/// faulted disavows nothing.
fn disavowed_names(schema: &Document, pick: impl Fn(&Constraint) -> bool) -> Vec<String> {
	let (def, _) = build_schema(schema);
	let mut names: Vec<String> = Vec::new();
	let frags = def.frags.values().flat_map(|v| v.iter());
	for c in def.cons.iter().chain(frags) {
		if !pick(c) {
			continue;
		}
		// Name wildcard: no single leaf name to disavow.
		if let Some(seg) = c.segs.last().filter(|seg| !seg.star) {
			names.push(seg.name.clone());
		}
	}
	names
}

/// The single H002 wording site: the merge hint and the schema suppressor
/// both come here, same discipline as h001_head.
fn h002_head(name: &str) -> String {
	format!("merged with '{}' at ", diag_name(name))
}

/// Drop the H002 hints a schema disavows: a section whose entry declares
/// `reopen: true` is MEANT to be written in parts, so the merge hint is
/// structurally a false positive there. Matching is by leaf name, same as the
/// H001 suppressor, and it errs toward quiet, for a hint. Used by
/// `check --schema` and load_and_validate; call it wherever doc diagnostics
/// and a schema meet.
pub fn suppress_declared_reopens(schema: &Document, diags: &mut Vec<Diagnostic>) {
	let names = disavowed_names(schema, |c| c.reopen);
	if names.is_empty() {
		return;
	}
	let heads: Vec<String> = names.iter().map(|n| h002_head(n)).collect();
	diags.retain(|d| d.code != "H002" || !heads.iter().any(|h| d.message.starts_with(h.as_str())));
}

/// Minimal quoting (value-syntax.md, Canonical output): bare only when the
/// text has no whitespace, none of the characters that end, open or escape a
/// piece, needs no escape, and does not end in a colon, which a list item
/// would read as a name. A colon inside is text: `2:30PM` stays bare.
fn needs_quotes(t: &str) -> bool {
	t.is_empty()
		|| t.ends_with(':')
		|| t.char_indices().any(|(i, c)| {
			white_space(c)
				|| matches!(c, ',' | '#' | '"' | '\'' | '`' | '[' | ']' | ESCAPE_MARK)
				|| invisible_at(t, i, c)
		}) || fence_open(t).is_some()
}

/// The element as written: bare when it can be, else in the author's quote
/// kind when the text allows it, else the quotes the writer picks. A quoted
/// plain string keeps its quotes, since quoting it is how a file says it is
/// text; a quoted data format loses them, since readers type the value
/// either way. A backtick value stays in backticks whatever it holds.
fn emit_element(e: &Element) -> std::borrow::Cow<'_, str> {
	let t = &e.text;
	if e.mark == Mark::Backtick && backtick_holds(t) {
		return std::borrow::Cow::Owned(format!("`{}`", t));
	}
	if !needs_quotes(t) && (!e.quoted() || is_data_format(e)) {
		return std::borrow::Cow::Borrowed(t);
	}
	std::borrow::Cow::Owned(match e.mark {
		Mark::Single if !t.contains('\'') => quote_with(t, '\''),
		Mark::Double if !t.contains('"') => quote_with(t, '"'),
		_ => quote_text(t),
	})
}

/// Whether text can be a backtick value: no backtick, which would end it,
/// and nothing the writer would have to escape, since a backtick value has
/// no escapes.
fn backtick_holds(t: &str) -> bool {
	!t.char_indices()
		.any(|(i, c)| c == '`' || c == '\n' || c == '\r' || invisible_at(t, i, c))
}

/// An element no source wrote. It counts as quoted when canonical output will
/// quote it, so a read gives the same answer before a save as after one.
fn new_element(text: String) -> Element {
	let mark = if !needs_quotes(&text) {
		Mark::Bare
	} else if picks_single(&text) {
		Mark::Single
	} else {
		Mark::Double
	};
	Element { text, mark }
}

/// True when the text reads as an int, float, bool, or datetime at standard
/// strictness - fixed there deliberately, so canonical form cannot vary with
/// the load strictness. A number with a leading zero does not count: quotes
/// are how a file says the zeros matter, as in a zip code.
fn is_data_format(e: &Element) -> bool {
	// One pass over the bytes before any coercion. At Standard the int, float
	// and datetime forms all require at least one ASCII digit; the only formats
	// that do not are the boolean words, and the longest of those is "false".
	// An ordinary quoted string fails both tests, so emit stops running four
	// full coercions on every quoted element it writes.
	let t = e.text.trim();
	if t.bytes().any(|b| b.is_ascii_digit()) {
		let number = parse_int_text(e, Strictness::Standard).is_some()
			|| parse_float_text(e, Strictness::Standard).is_some();
		return (number && !leading_zero(t))
			|| parse_datetime(&e.text).is_some()
			|| parse_bool_text(t, Strictness::Standard).is_some();
	}
	t.len() <= 5 && parse_bool_text(t, Strictness::Standard).is_some()
}

/// A zero followed by another digit, after any sign: `007`, `-012`, `00.5`.
fn leading_zero(t: &str) -> bool {
	let b = t.strip_prefix(['+', '-']).unwrap_or(t).as_bytes();
	b.len() > 1 && b[0] == b'0' && b[1].is_ascii_digit()
}

/// The quotes the writer picks: double, or single when the text has a `"`
/// and no `'`. A backslash plays no part.
fn picks_single(t: &str) -> bool {
	t.contains('"') && !t.contains('\'')
}

/// Quote a logical string so the tokenizer reads it back as the same string,
/// in the quotes the writer picks.
fn quote_text(t: &str) -> String {
	quote_with(t, if picks_single(t) { '\'' } else { '"' })
}

/// The text in quote `q`, with every character a reader could not see or
/// that would end the piece written as an escape: a line break, a carriage
/// return or the pair of them, a tab, the other controls on the list by
/// name, a hidden character by code point, a real escape mark, and `q`
/// itself.
fn quote_with(t: &str, q: char) -> String {
	let mut out = String::with_capacity(t.len() + 2);
	out.push(q);
	let mut it = t.char_indices().peekable();
	while let Some((i, c)) = it.next() {
		if c == '\r' && it.peek().is_some_and(|&(_, n)| n == '\n') {
			it.next();
			out.push(ESCAPE_MARK);
			out.push_str("CRLF");
			out.push(ESCAPE_MARK);
		} else if c == q || c == ESCAPE_MARK || c == '\t' || c == '\n' || invisible_at(t, i, c) {
			push_escape(&mut out, c);
		} else {
			out.push(c);
		}
	}
	out.push(q);
	out
}

// ---------------------------------------------------------------------------
// The write side's one rule: what is written has to read back
// ---------------------------------------------------------------------------
//
// A setter builds its text through the emitter and reads it back with the
// tokenizer before the document is touched. If the read does not give the
// value it was handed, the write is refused and nothing changes. No setter
// decides for itself what a quote, a `#`, a comma or a carriage return means:
// twelve review items were one setter's private rule disagreeing with the
// parser's. The typed setters keep their own render-and-parse-back on top,
// since a float or a datetime has to read back as that type and not merely as
// the same text.

/// An array the way `emit_line` writes it: `[a, b]`, and `[]` for none.
fn emit_array(els: &[Element]) -> String {
	let mut out = String::new();
	emit_array_into(&mut out, els);
	out
}

fn emit_array_into(out: &mut String, els: &[Element]) {
	out.push('[');
	for (i, e) in els.iter().enumerate() {
		if i > 0 {
			out.push_str(", ");
		}
		out.push_str(&emit_element(e));
	}
	out.push(']');
}

/// The value half of a binding line, the way `emit_line` writes it, or None
/// for a value with no one-line form.
fn emit_value_text(v: &Value) -> Option<String> {
	match v {
		Value::Cell(e) => Some(emit_element(e).into_owned()),
		Value::Array(els) => Some(emit_array(els)),
		Value::Empty | Value::Raw(_) => None,
	}
}

/// The opening fence line of a raw block: the fence run, then the info string
/// behind a space when it would otherwise extend the run.
fn emit_fence_line(r: &RawVal) -> String {
	let mut out: String = std::iter::repeat_n(r.fence_char as char, r.fence_len).collect();
	if !r.info.is_empty() {
		if r.info.as_bytes()[0] == r.fence_char {
			out.push(' ');
		}
		out.push_str(&r.info);
	}
	out
}

/// Scan text as a line's value half, behind the colon a field line puts
/// there. Returns the line the token spans index into.
fn value_half(text: &str, out: &mut Tokens) -> String {
	let line = format!(":{}", text);
	tokenize_value(&line, 1, Rules::Current, out);
	line
}

/// True when a value comes back off the page as itself.
fn value_reads_back(v: &Value) -> bool {
	match v {
		Value::Empty => true,
		Value::Cell(_) | Value::Array(_) => {
			let els = match v {
				Value::Cell(e) => std::slice::from_ref(e),
				Value::Array(els) => els.as_slice(),
				_ => return false,
			};
			let Some(text) = emit_value_text(v) else {
				return false;
			};
			if text.contains('\n') {
				return false;
			}
			let mut tok = Tokens::default();
			let line = value_half(&text, &mut tok);
			if tok.comment.is_some()
				|| tok.array.is_some() != matches!(v, Value::Array(_))
				|| array_fault(&tok).is_some()
				|| value_fault(&tok, &line).is_some()
			{
				return false;
			}
			// Compared against the pieces rather than against a rebuilt value:
			// a bulk write runs this per set, and the text is right there.
			let mut back = tok
				.elements
				.iter()
				.filter(|p| p.quote != Quote::None || p.end > p.start);
			els.iter()
				.all(|e| back.next().is_some_and(|p| piece_is(p, &line, &e.text)))
				&& back.next().is_none()
		}
		Value::Raw(r) => {
			let line = emit_fence_line(r);
			if line.contains('\n') {
				return false;
			}
			let mut tok = Tokens::default();
			tokenize_value(&line, 0, Rules::Current, &mut tok);
			if fence_open(&line[tok.value.0..tok.value.1])
				!= Some((r.fence_char, r.fence_len, r.info.clone()))
			{
				return false;
			}
			// A body line ending in a carriage return loses it to the load's
			// line-end trim, and one spelling the closing fence would end the
			// block early.
			r.content
				.split('\n')
				.all(|l| !l.ends_with('\r') && !is_fence_close(l, r.fence_char, r.fence_len))
		}
	}
}

/// True when a field name comes back off a line as itself.
fn name_reads_back(name: &str) -> bool {
	let text = escape_name(name);
	if text.contains('\n') {
		return false;
	}
	let mut tok = Tokens::default();
	tokenize(&text, b':', false, Rules::Current, &mut tok);
	tok.fault.is_none()
		&& tok.segments.len() == 1
		&& tok.segments[0].selector.is_none()
		&& piece_is(&tok.segments[0].name, &text, name)
}

/// The comment line this text is written as, or None when it has no spelling.
/// A `#` is added when the text has none. The load trims every line's
/// end, so the trimmed text is what gets written; text holding a line break
/// is refused rather than cut down to its first line.
fn comment_line(text: &str) -> Option<String> {
	if text.contains('\n') {
		return None;
	}
	let t = trim_wsp_end(text);
	let line = if t.starts_with('#') {
		t.to_string()
	} else if t.is_empty() {
		"#".to_string()
	} else {
		format!("# {}", t)
	};
	let mut tok = Tokens::default();
	tokenize_value(&line, 0, Rules::Current, &mut tok);
	(tok.comment == Some(0) && trim_wsp_end(&line) == line).then_some(line)
}

// ---------------------------------------------------------------------------
// Accessor: path resolution
// ---------------------------------------------------------------------------

enum Resolved {
	None,
	One(usize),
	Many(Vec<usize>),
	// Wildcard: one slot per instance, in file order; Err = why the sub-path
	// did not reach one node (NotFound missing, Multiple ambiguous).
	Slots(Vec<Result<usize, Status>>),
}

impl Document {
	fn name_index(&self) -> &NameIndex {
		self.index.get_or_init(|| {
			// Boxed so the document stays small on the stack (it rides inside
			// LoadError by value).
			let mut idx = NameIndex {
				first: U64Map::default(),
				last: U64Map::default(),
				next_same: vec![NIL; self.arena.len()],
			};
			// From the root, not across the arena: a removed subtree's nodes
			// are still there with their child lists intact, so an arena walk
			// indexes every node the document ever held. Chains stay in file
			// order - a chain is one parent's same-named children, and each
			// parent's are appended in its own list order.
			let mut stack = vec![ROOT];
			while let Some(p) = stack.pop() {
				for &c in &self.arena[p].children {
					idx.append(name_key(p, &self.arena[c].name), c);
					stack.push(c);
				}
			}
			Box::new(idx)
		})
	}

	fn children_named(&self, parent: usize, name: &str) -> Vec<usize> {
		let idx = self.name_index();
		let mut out = Vec::new();
		let mut c = idx
			.first
			.get(&name_key(parent, name))
			.copied()
			.unwrap_or(NIL);
		while c != NIL {
			if self.arena[c].name == name && self.arena[c].parent == parent {
				out.push(c);
			}
			c = idx.next_same[c];
		}
		out
	}

	// `group`: a sub-path reaching several nodes joins the slot list instead
	// of becoming one Multiple slot. Reads want the slot per instance, so they
	// leave it off; remove and exists want every node behind the wildcard.
	fn resolve_from(&self, start: &[usize], segs: &[Segment], group: bool) -> Resolved {
		let mut cur: Vec<usize> = start.to_vec();
		for (i, seg) in segs.iter().enumerate() {
			let mut next: Vec<usize> = Vec::new();
			for &n in &cur {
				if seg.star {
					next.extend(self.arena[n].children.iter().copied());
				} else {
					next.extend(self.children_named(n, &seg.name));
				}
			}
			if seg.star {
				// Name wildcard: same per-slot split as `[*]`, over every child.
				let rest = &segs[i + 1..];
				let mut slots: Vec<Result<usize, Status>> = Vec::new();
				for inst in next {
					if rest.is_empty() {
						slots.push(Ok(inst));
					} else {
						match self.resolve_from(&[inst], rest, group) {
							Resolved::One(x) => slots.push(Ok(x)),
							Resolved::None => slots.push(Err(Status::NotFound)),
							// A wildcard after a wildcard: the inner slots join the
							// outer list, so the two compose into one flat run of
							// leaves rather than one unreadable slot.
							Resolved::Slots(inner) => slots.extend(inner),
							Resolved::Many(v) if group => slots.extend(v.into_iter().map(Ok)),
							_ => slots.push(Err(Status::Multiple)),
						}
					}
				}
				return Resolved::Slots(slots);
			}
			match &seg.selector {
				None => cur = next,
				Some(Selector::ByValue { text, quoted }) => {
					let want = text.as_str();
					cur = next
						.into_iter()
						.filter(|&c| {
							disp_key(&self.arena[c].value) == want
								&& (!quoted || single_scalar(&self.arena[c].value))
						})
						.collect();
				}
				Some(Selector::ByIndex(k)) => {
					cur = index_usize(*k)
						.and_then(|i| next.get(i))
						.map(|&c| vec![c])
						.unwrap_or_default();
				}
				Some(Selector::Wildcard) => {
					// Remaining path resolves per-instance; slots stay aligned.
					let rest = &segs[i + 1..];
					let mut slots: Vec<Result<usize, Status>> = Vec::new();
					for inst in next {
						if rest.is_empty() {
							slots.push(Ok(inst));
						} else {
							match self.resolve_from(&[inst], rest, group) {
								Resolved::One(x) => slots.push(Ok(x)),
								Resolved::None => slots.push(Err(Status::NotFound)),
								// A wildcard after a wildcard: the inner slots join the
								// outer list, so the two compose into one flat run of
								// leaves rather than one unreadable slot.
								Resolved::Slots(inner) => slots.extend(inner),
								Resolved::Many(v) if group => slots.extend(v.into_iter().map(Ok)),
								_ => slots.push(Err(Status::Multiple)),
							}
						}
					}
					return Resolved::Slots(slots);
				}
			}
		}
		match cur.len() {
			0 => Resolved::None,
			1 => Resolved::One(cur[0]),
			_ => Resolved::Many(cur),
		}
	}

	fn resolve(&self, path: &str) -> Result<Resolved, Status> {
		self.resolve_mode(path, false)
	}

	/// resolve() with every node behind a wildcard slot in the list, for the
	/// callers that act on the whole match rather than read one value per
	/// instance.
	fn resolve_group(&self, path: &str) -> Result<Resolved, Status> {
		self.resolve_mode(path, true)
	}

	fn resolve_mode(&self, path: &str, group: bool) -> Result<Resolved, Status> {
		let scan = scan_lookup(path).map_err(|_| Status::NotFound)?;
		if scan.value.is_some() {
			return Err(Status::NotFound); // a query has no value part
		}
		Ok(self.resolve_from(&[ROOT], &scan.segments, group))
	}

	/// Instance count at a path (0 when nothing matches).
	pub fn count(&self, path: &str) -> usize {
		match self.resolve(path) {
			Ok(Resolved::None) | Err(_) => 0,
			Ok(Resolved::One(_)) => 1,
			Ok(Resolved::Many(v)) => v.len(),
			Ok(Resolved::Slots(s)) => s.len(),
		}
	}

	/// Every field path in the document, in file order, deduplicated - a query
	/// recipe for tooling (the differential harness derives reads over the fuzz
	/// set from it). A segment that is not bare-name-safe is emitted quoted and
	/// escaped - the form the path scanner accepts - so each path is a
	/// well-formed lookup path and nothing in the document is hidden.
	pub fn paths(&self) -> Vec<String> {
		let mut out = Vec::new();
		let mut seen = std::collections::HashSet::new();
		let mut stack: Vec<(usize, String)> = self.arena[ROOT]
			.children
			.iter()
			.rev()
			.map(|&c| (c, String::new()))
			.collect();
		while let Some((node, prefix)) = stack.pop() {
			let seg = emit_name(&self.arena[node].name);
			let path = if prefix.is_empty() {
				seg.into_owned()
			} else {
				format!("{}.{}", prefix, seg)
			};
			if seen.insert(path.clone()) {
				out.push(path.clone());
			}
			for &c in self.arena[node].children.iter().rev() {
				stack.push((c, path.clone()));
			}
		}
		out
	}

	/// 1-based source line of the binding at a path, for consumer checks the
	/// schema cannot express. 0 when the path does not resolve to exactly one
	/// node, or the node was writer-built. Merged instances cite the first
	/// binding's line, matching diagnostics.
	pub fn line(&self, path: &str) -> usize {
		match self.resolve(path) {
			Ok(Resolved::One(n)) => self.arena[n].line,
			_ => 0,
		}
	}

	/// The field name at a path exactly as the author wrote it (case
	/// unfolded, outer quotes stripped), so a message can echo `SYMBOLS` when
	/// the file said SYMBOLS. Escape sequences stay as written too: a name is
	/// stored, compared and emitted with its escapes RESOLVED, so this is the
	/// one call that hands the source spelling back - which is what an
	/// as-authored accessor is for. Resolution mirrors line(): empty when the path
	/// does not resolve to exactly one node. Merged instances keep the first
	/// binding's spelling; a writer-built node keeps the spelling the setter's
	/// path used.
	pub fn authored_name(&self, path: &str) -> String {
		match self.resolve(path) {
			Ok(Resolved::One(n)) => self.arena[n].authored().to_string(),
			_ => String::new(),
		}
	}

	/// The plural line(): 1-based source lines at a path, in file order, so a
	/// repeated field - the case that most wants a citable line - yields every
	/// binding's. Wildcard slots that did not resolve stay in the list as 0,
	/// and a writer-built node is 0, so indices keep matching count().
	pub fn lines(&self, path: &str) -> Vec<usize> {
		match self.resolve(path) {
			Ok(Resolved::One(n)) => vec![self.arena[n].line],
			Ok(Resolved::Many(v)) => v.iter().map(|&n| self.arena[n].line).collect(),
			Ok(Resolved::Slots(s)) => s
				.into_iter()
				.map(|r| match r {
					Ok(n) => self.arena[n].line,
					Err(_) => 0,
				})
				.collect(),
			_ => Vec::new(),
		}
	}

	/// Child field names under a path, in file order, duplicates included -
	/// the "what keys are in this section?" question paths() (deduplicated,
	/// path-shaped) cannot answer. "" enumerates the top level. A path with
	/// several instances lists the children of each in turn, the way a dotted
	/// path reaches all of them. Names come back as stored; quote_segment()
	/// makes one splice-safe in a path.
	pub fn children(&self, path: &str) -> Vec<String> {
		let nodes = if path.trim().is_empty() {
			vec![ROOT]
		} else {
			match self.resolve(path) {
				Ok(Resolved::One(n)) => vec![n],
				Ok(Resolved::Many(v)) => v,
				Ok(Resolved::Slots(s)) => s.into_iter().flatten().collect(),
				_ => return Vec::new(),
			}
		};
		nodes
			.iter()
			.flat_map(|&n| &self.arena[n].children)
			.map(|&c| self.arena[c].name.clone())
			.collect()
	}

	/// paths() one instance at a time: every binding's path in file order,
	/// with `[#i]` on each segment whose name repeats under its parent, so
	/// each path reads exactly one node and a repeated block is walked
	/// instance by instance. Segments are written as paths() writes them.
	pub fn instance_paths(&self) -> Vec<String> {
		let mut out = Vec::new();
		let mut stack: Vec<(usize, String)> = vec![(ROOT, String::new())];
		while let Some((node, prefix)) = stack.pop() {
			if node != ROOT {
				out.push(prefix.clone());
			}
			let kids = &self.arena[node].children;
			let mut total: HashMap<&str, usize> = HashMap::new();
			for &c in kids {
				*total.entry(self.arena[c].name.as_str()).or_insert(0) += 1;
			}
			let mut at: HashMap<&str, usize> = HashMap::new();
			let mut paths = Vec::with_capacity(kids.len());
			for &c in kids {
				let name = self.arena[c].name.as_str();
				let mut path = if prefix.is_empty() {
					emit_name(name).into_owned()
				} else {
					format!("{}.{}", prefix, emit_name(name))
				};
				if total[name] > 1 {
					let i = at.entry(name).or_insert(0);
					path.push_str(&format!("[#{}]", i));
					*i += 1;
				}
				paths.push((c, path));
			}
			stack.extend(paths.into_iter().rev());
		}
		out
	}

	/// Instance values at a path, in file order. Wildcard slots that did not
	/// resolve stay in the list as "" so indices keep matching count().
	pub fn instances(&self, path: &str) -> Vec<String> {
		match self.resolve(path) {
			Ok(Resolved::One(n)) => vec![self.arena[n].value.display()],
			Ok(Resolved::Many(v)) => v.iter().map(|&n| self.arena[n].value.display()).collect(),
			Ok(Resolved::Slots(s)) => s
				.into_iter()
				.map(|r| match r {
					Ok(n) => self.arena[n].value.display(),
					Err(_) => String::new(),
				})
				.collect(),
			_ => Vec::new(),
		}
	}
}

// ---------------------------------------------------------------------------
// Writer: typed emit, defaults, comments, structural edits
// ---------------------------------------------------------------------------
// The reverse of the Accessor. A setter builds the canonical stored text for a
// typed value (the inverse of the matching read) and places it at a path,
// creating intermediate nodes on the way. Reads and to_canonical walk children
// vecs, so mutating the arena directly is enough - the parser's child_map is
// already gone and is not maintained here.

/// Read text as the value half of a line, for the setters that take value
/// syntax rather than data: whatever a file line means with this text is
/// what gets stored, so a trailing blank comes off and a `#` outside quotes
/// ends the value exactly as they would in a file. What is refused is what
/// a file reports as an error, since a setter has no diagnostic to report it
/// with: a line break, which no file line can hold, a malformed bracket
/// array (E019), and whatever a value is refused for on a line: a bare comma
/// (E026), an unterminated quote (E017), a bad escape (E023), or whitespace
/// or a quote in bare text (E025). A bracket array is stored as an array.
fn literal_value(text: &str) -> Option<Value> {
	if text.contains('\n') {
		return None;
	}
	let mut tok = Tokens::default();
	let line = value_half(text, &mut tok);
	// A fence opener has no body here, so it is stored as the text it is,
	// as before backtick values.
	let fence = fence_open(&line[tok.value.0..tok.value.1]).is_some();
	if array_fault(&tok).is_some()
		|| tok.elements.len() > 1 && tok.array.is_none()
		|| (!fence && value_fault(&tok, &line).is_some())
	{
		return None;
	}
	Some(cell_of_tokens(&tok, &line))
}

/// An overwrite keeps the quote kind the old value was written in, when the
/// new text can be written that way (value-syntax.md, Canonical output). The
/// kind is the one a save writes, so the answer is the same after a reload:
/// a quoted data format is written bare.
fn keep_mark(old: &Value, new: &mut Value) {
	let (Value::Cell(was), Value::Cell(now)) = (old, &mut *new) else {
		return;
	};
	let written = match emit_element(was).as_bytes().first() {
		Some(b'\'') => Mark::Single,
		Some(b'"') => Mark::Double,
		Some(b'`') if was.mark == Mark::Backtick => Mark::Backtick,
		_ => Mark::Bare,
	};
	let fits = match written {
		Mark::Bare => return,
		Mark::Single => !now.text.contains('\''),
		Mark::Double => !now.text.contains('"'),
		Mark::Backtick => backtick_holds(&now.text),
	};
	if fits {
		let before = now.mark;
		now.mark = written;
		if !value_reads_back(new)
			&& let Value::Cell(el) = new
		{
			el.mark = before;
		}
	}
}

fn cell_of(text: String) -> Value {
	Value::Cell(new_element(text))
}

/// Pick a backtick fence long enough that no content line closes it early.
fn choose_fence(content: &str) -> (u8, usize) {
	let mut maxrun = 0usize;
	for line in content.split('\n') {
		let t = line.trim_matches([' ', '\t']);
		if !t.is_empty() && t.bytes().all(|b| b == b'`') {
			maxrun = maxrun.max(t.len());
		}
	}
	(b'`', (maxrun + 1).max(3))
}

/// An array setter's value: written in brackets whatever its length, so
/// one element is `[80]` and none is `[]`.
fn array_cell(texts: Vec<String>) -> Value {
	Value::Array(texts.into_iter().map(new_element).collect())
}

impl Document {
	/// A fresh document with no bindings - the start point for schema-driven
	/// generation. Loads at Standard; set values, then to_canonical().
	pub fn new() -> Document {
		Document::parse("")
	}

	fn new_child(&mut self, parent: usize, name: &str, name_src: &str, value: Value) -> usize {
		// A list written stacked would get the child after its elements,
		// which reloads as E001, so it goes inline.
		if stacks(&self.arena[parent]) {
			unstack(&mut self.arena[parent]);
		}
		let idx = self.arena.len();
		self.arena.push(NodeData {
			name: name.to_string(),
			name_src: spelled(name, name_src.to_string()),
			value,
			children: Vec::new(),
			parent,
			line: 0,
			star_list: false,
			star_mixed: false,
			trivia: None,
			// Hand-written files separate top-level sections with a blank line;
			// writer-built ones do the same (the emitter never blanks line 1).
			blank_before: parent == ROOT,
			src_set: false,
			src: None,
		});
		self.arena[parent].children.push(idx);
		if let Some(ix) = self.index.get_mut() {
			ix.append(name_key(parent, name), idx);
		}
		// Kept lines that end the block stay where they were, so the new
		// field goes after the last of them, as a reload files them. The
		// comments after it stay at the end, and so does a kept line the
		// settle wrote as a comment, since a reload reads it as one.
		let tail = if parent == ROOT {
			Some(&mut self.orphans)
		} else {
			self.arena[parent]
				.trivia
				.as_deref_mut()
				.map(|t| &mut t.inside)
		};
		if let Some(tail) = tail
			&& let Some(k) = tail.iter().rposition(|l| !l.text.starts_with('#'))
		{
			let rest = tail.split_off(k + 1);
			let lines = std::mem::replace(tail, rest);
			restep(tail);
			self.arena[idx].triv_mut().leading = lines;
		}
		let last = self.arena[parent].children.len() - 1;
		settle_block(&mut self.arena, parent, last);
		idx
	}

	/// Why a write at this path would fail - the reason behind a setter's bare
	/// `false`, so a consumer's error message need not guess. `Writable` means
	/// the same validation `place()` runs would pass; nothing is created.
	pub fn write_reason(&self, path: &str) -> WriteReason {
		let Ok(scan) = scan_lookup(path) else {
			return WriteReason::BadPath;
		};
		self.probe_write(&scan, &mut Vec::new())
	}

	/// The validation walk `write_reason` and `place` share. `trail` collects
	/// where each segment ended up - `None` from the point the path falls off the
	/// existing tree - so `place` can create from exactly there instead of
	/// scanning the path and walking the tree a second time.
	fn probe_write(&self, scan: &PathScan, trail: &mut Vec<Option<usize>>) -> WriteReason {
		trail.clear();
		if scan.value.is_some() {
			return WriteReason::ValueInPath;
		}
		if scan.segments.is_empty() {
			return WriteReason::BadPath;
		}
		// Writer side of the load-time nesting cap: never create deeper.
		if scan.segments.len() > MAX_DEPTH {
			return WriteReason::TooDeep;
		}
		// The probe walk place() validates with: once it falls off the existing
		// tree, a later `[#k]` can never match (fresh intermediates are created
		// childless), so an index segment past that point is unresolvable.
		let mut probe = Some(ROOT);
		for seg in &scan.segments {
			if seg.star {
				return WriteReason::Wildcard;
			}
			// A newline in a SELECTOR has no one-line spelling, so the emitted
			// binding would split across two lines and reparse as neither. The
			// selector stores its path text raw and the value emitter never
			// escapes a line break, so nothing downstream can rescue it - and
			// the reload loses nothing it can count, so the save gate would not
			// catch it either. A newline in a NAME is fine: names are stored
			// escape-resolved and emitted through the name escaper, which writes
			// a line break as `\n` and reads it back as one.
			match &seg.selector {
				Some(Selector::Wildcard) => return WriteReason::Wildcard,
				Some(Selector::ByIndex(k)) => {
					let Some(c) = probe else {
						return WriteReason::NoSuchIndex;
					};
					let matches = self.children_named(c, &seg.name);
					match index_usize(*k).and_then(|i| matches.get(i)) {
						Some(&m) => probe = Some(m),
						None => return WriteReason::NoSuchIndex,
					}
				}
				Some(Selector::ByValue { text, quoted }) => {
					let want = text.as_str();
					probe = probe.and_then(|c| {
						self.children_named(c, &seg.name).into_iter().find(|&n| {
							disp_key(&self.arena[n].value) == want
								&& (!quoted || single_scalar(&self.arena[n].value))
						})
					});
				}
				None => {
					probe = probe.and_then(|c| self.children_named(c, &seg.name).first().copied());
				}
			}
			trail.push(probe);
		}
		WriteReason::Writable
	}

	/// The node a write at this path lands on when it is already there.
	fn write_target(&self, path: &str) -> Option<usize> {
		let scan = scan_lookup(path).ok()?;
		let mut trail = Vec::new();
		if self.probe_write(&scan, &mut trail) != WriteReason::Writable {
			return None;
		}
		trail.last().copied().flatten()
	}

	/// Walk (creating as needed) to the node a write targets. A trailing name
	/// with no selector hits the first same-named instance (or a new one); a
	/// `[value]` selector selects the matching instance or creates it; `[#k]`
	/// must already exist. None = path unusable for a write (write_reason()
	/// says why). Validation runs first, so a doomed path leaves no
	/// half-created intermediates behind. A `setter` creating a field deals
	/// with the kept lines of its name, as set_child() says.
	fn place(&mut self, path: &str, setter: bool) -> Option<usize> {
		let scan = scan_lookup(path).ok()?;
		let mut trail: Vec<Option<usize>> = Vec::new();
		if self.probe_write(&scan, &mut trail) != WriteReason::Writable {
			return None;
		}
		// Nothing is created until every segment the write would create is
		// known to read back: the name through the name escaper, an instance
		// selector as the value it binds, and the first under a field that
		// takes a field under it, which an array does not (E028).
		for (i, seg) in scan.segments.iter().enumerate() {
			if trail[i].is_some() {
				continue;
			}
			if i > 0
				&& let Some(up) = trail[i - 1]
				&& matches!(self.arena[up].value, Value::Array(_))
			{
				return None;
			}
			if !name_reads_back(&seg.name) {
				return None;
			}
			if let Some(Selector::ByValue { text, .. }) = &seg.selector
				&& !value_reads_back(&cell_of(text.clone()))
			{
				return None;
			}
		}
		let mut cur = ROOT;
		for (i, seg) in scan.segments.iter().enumerate() {
			// The probe already resolved every segment that exists; only the
			// tail it fell off has anything to create.
			if let Some(found) = trail[i] {
				cur = found;
				continue;
			}
			let value = match &seg.selector {
				None => Value::Empty,
				Some(Selector::ByValue { text, .. }) => cell_of(text.clone()),
				// Both are unreachable: probe_write refuses a wildcard outright
				// and an unresolvable index, so neither reaches an empty trail
				// slot. Belt only.
				Some(Selector::ByIndex(_)) | Some(Selector::Wildcard) => return None,
			};
			cur = if setter {
				self.set_child(cur, &seg.name, &seg.name_src, value, path)
			} else {
				self.new_child(cur, &seg.name, &seg.name_src, value)
			};
		}
		Some(cur)
	}

	/// A setter creating a field writes the kept lines of its name in the
	/// block as comments, and with no other field of that name the new one
	/// goes right under the first of them (design.md, Kept lines under
	/// edits).
	fn set_child(
		&mut self,
		parent: usize,
		name: &str,
		name_src: &str,
		value: Value,
		path: &str,
	) -> usize {
		let alone = self.children_named(parent, name).is_empty();
		match self.comment_out_kept(parent, name, path, alone) {
			Some(at) => self.new_child_under(parent, name, name_src, value, at),
			None => self.new_child(parent, name, name_src, value),
		}
	}

	fn set_value(&mut self, path: &str, value: Value) -> bool {
		self.set_value_as(path, value, true)
	}

	/// set_value(), saying whether an overwrite keeps the old value's quote
	/// kind. A literal says its own quotes, so it does not.
	fn set_value_as(&mut self, path: &str, mut value: Value, keep_quotes: bool) -> bool {
		if !value_reads_back(&value) {
			return false;
		}
		if self.probe {
			return true;
		}
		let fresh = self.arena.len();
		// A field with lines under it takes one plain value or none (E028).
		if matches!(value, Value::Array(_))
			&& let Some(n) = self.write_target(path)
			&& !self.arena[n].children.is_empty()
		{
			return false;
		}
		match self.place(path, true) {
			Some(node) => {
				// place() has already done it for a field it created.
				if node < fresh && self.kept_owed > 0 {
					let (parent, name) = (self.arena[node].parent, self.arena[node].name.clone());
					self.comment_out_kept(parent, &name, path, false);
				}
				if keep_quotes {
					keep_mark(&self.arena[node].value, &mut value);
				}
				// A list written stacked stays stacked, as an overwrite keeps
				// quotes, unless there is nothing left to stack.
				let stacked = stacks(&self.arena[node])
					&& matches!(&value, Value::Array(els) if !els.is_empty());
				self.arena[node].value = value;
				self.arena[node].src = None; // written value has no source spelling
				// No longer the list the lines among its elements sat in.
				unstack(&mut self.arena[node]);
				self.arena[node].star_list = stacked;
				// An empty binding or a raw block can put a fence after an
				// empty sibling of its name.
				let fence_side = matches!(self.arena[node].value, Value::Empty | Value::Raw(_));
				let parent = self.arena[node].parent;
				self.collapse_dup(node);
				if fence_side {
					self.settle_fence_name(parent, &self.arena[node].name.clone());
				}
				settle_first_blank(&mut self.arena, &mut self.orphans);
				self.resettle_kept();
				true
			}
			None => false,
		}
	}

	/// A setter writing a field writes every kept line of its name in the
	/// block as a comment with a note, the one heading the field included,
	/// so a hand fix of one later never gives Multiple (design.md, Kept lines
	/// under edits). Each is no longer owed. With `anchor`, the first one is
	/// where a new field goes, and is returned, and the kept lines under it
	/// go under that field. Any other with a kept line under it stays, since
	/// as a comment it would leave that line under the field above.
	fn comment_out_kept(
		&mut self,
		parent: usize,
		name: &str,
		path: &str,
		anchor: bool,
	) -> Option<(Site, usize, usize)> {
		if self.kept_owed == 0 {
			return None;
		}
		let mut first = None;
		for (site, owner, k, code, msg) in self.kept_named(parent, name) {
			let leads = self.leads_mut(site, owner);
			let under = &leads[k + 1..][..run_under(leads, k)];
			// A misplaced line under it is filed by its own text, so it
			// cannot move with it either.
			if under.iter().any(|l| l.text.starts_with([' ', '\t'])) {
				continue;
			}
			if anchor && first.is_none() {
				first = Some((site, owner, k));
			} else if under.iter().any(|l| !l.text.starts_with('#')) {
				continue;
			}
			note_lead(&mut leads[k], path, code, &msg);
			self.kept_owed = self.kept_owed.saturating_sub(1);
		}
		first
	}

	/// The kept lines naming just `name` in the block under `parent`, in the
	/// order they are written, each with the fault the load gave it.
	fn kept_named(
		&self,
		parent: usize,
		name: &str,
	) -> Vec<(Site, usize, usize, &'static str, String)> {
		let mut out = Vec::new();
		let mut scan = |site: Site, owner: usize, leads: &[Lead]| {
			for (k, l) in leads.iter().enumerate() {
				if let Some((code, msg)) = kept_naming(l, name) {
					out.push((site, owner, k, code, msg));
				}
			}
		};
		for &c in &self.arena[parent].children {
			scan(Site::Leading, c, self.arena[c].leading());
			scan(Site::After, c, self.arena[c].after());
		}
		scan(Site::Inside, parent, self.arena[parent].inside());
		if parent == ROOT {
			scan(Site::Orphans, ROOT, &self.orphans);
		}
		out
	}

	fn leads_mut(&mut self, site: Site, owner: usize) -> &mut Vec<Lead> {
		if site == Site::Orphans {
			return &mut self.orphans;
		}
		let t = self.arena[owner].triv_mut();
		match site {
			Site::Leading => &mut t.leading,
			Site::Inside => &mut t.inside,
			_ => &mut t.after,
		}
	}

	/// A new field right under the kept line at `at`, which a setter just
	/// wrote as a comment. The lines written under that line go under the
	/// field, where a reload files them.
	fn new_child_under(
		&mut self,
		parent: usize,
		name: &str,
		name_src: &str,
		value: Value,
		at: (Site, usize, usize),
	) -> usize {
		if stacks(&self.arena[parent]) {
			unstack(&mut self.arena[parent]);
		}
		let (site, owner, k) = at;
		let leads = self.leads_mut(site, owner);
		let mut line = leads.split_off(k);
		let mut rest = line.split_off(1 + run_under(&line, 0));
		let mut under = line.split_off(1);
		for l in &mut under {
			l.depth = l.depth.saturating_sub(1);
		}
		restep(&mut under);
		// Above the field, what was written before the line. After a sibling,
		// that stays with the sibling and the settle below moves it.
		let (leading, after) = if site == Site::After {
			(line, rest)
		} else {
			let mut above = std::mem::take(leads);
			above.append(&mut line);
			if site == Site::Leading {
				restep(&mut rest);
			}
			*leads = rest;
			(above, Vec::new())
		};
		let kids = &self.arena[parent].children;
		let pos = match site {
			Site::Leading => kids.iter().position(|&c| c == owner).unwrap_or(kids.len()),
			Site::After => kids
				.iter()
				.position(|&c| c == owner)
				.map_or(kids.len(), |p| p + 1),
			_ => kids.len(),
		};
		let idx = self.arena.len();
		self.arena.push(NodeData {
			name: name.to_string(),
			name_src: spelled(name, name_src.to_string()),
			value,
			children: Vec::new(),
			parent,
			line: 0,
			star_list: false,
			star_mixed: false,
			trivia: Some(Box::new(Trivia {
				leading,
				after,
				inside: under,
				..Default::default()
			})),
			blank_before: false,
			src_set: false,
			src: None,
		});
		self.arena[parent].children.insert(pos, idx);
		// No other field of this name, so the index order holds.
		if let Some(ix) = self.index.get_mut() {
			ix.append(name_key(parent, name), idx);
		}
		settle_block(&mut self.arena, parent, pos);
		idx
	}

	/// A written value may now collide with a same-named sibling under the
	/// in-file merge rule; fold the pair the way a reparse would (earlier
	/// sibling survives, later one folds children and trivia in) so Writer
	/// output stays a formatter fixpoint.
	fn collapse_dup(&mut self, node: usize) {
		let parent = self.arena[node].parent;
		let me = &self.arena[node];
		let Some(other) = self
			.children_named(parent, &me.name)
			.into_iter()
			.find(|&c| {
				let o = &self.arena[c];
				c != node && merge_eq(&o.name, &o.value, &me.name, &me.value)
			})
		else {
			return;
		};
		let pos = |n: usize| {
			self.arena[parent]
				.children
				.iter()
				.position(|&c| c == n)
				.unwrap_or(usize::MAX)
		};
		let (survivor, loser) = if pos(other) < pos(node) {
			(other, node)
		} else {
			(node, other)
		};
		// The fold appends, so what moved is the survivor's new tail.
		let kept = self.arena[survivor].children.len();
		fold_node_into(&mut self.arena, survivor, loser);
		self.arena[parent].children.retain(|&c| c != loser);
		settle_block(&mut self.arena, parent, 1);
		if let Some(ix) = self.index.get_mut() {
			ix.unlink(name_key(parent, &self.arena[loser].name), loser);
			for &k in &self.arena[survivor].children[kept..] {
				let name = &self.arena[k].name;
				ix.unlink(name_key(loser, name), k);
				ix.append(name_key(survivor, name), k);
			}
		}
		self.fold_dups_below(survivor);
	}

	/// The write-side twin of `settle_fence_trailing`: only the written name's
	/// instances can change, and walking them off the index keeps a write off
	/// the rest of the block.
	fn settle_fence_name(&mut self, parent: usize, name: &str) {
		let mut empty = None;
		for c in self.children_named(parent, name) {
			let nd = &mut self.arena[c];
			if empty.is_some() && matches!(nd.value, Value::Raw(_)) && !nd.trailing().is_empty() {
				trailing_to_leading(nd);
			} else if let Some(e) = empty.filter(|_| stacks(nd)) {
				if fold_list_into_empty(&mut self.arena, e, c) {
					self.arena[parent].children.retain(|&k| k != c);
					if let Some(ix) = self.index.get_mut() {
						ix.unlink(name_key(parent, name), c);
					}
				}
			} else if nd.value.is_empty() && empty.is_none() {
				empty = Some(c);
			}
		}
	}

	/// Folding moves the loser's children up a level, where they can collide
	/// with the survivor's own. The parser's fold is depth-first for the same
	/// reason; only a node that just received children can hold a new pair.
	fn fold_dups_below(&mut self, start: usize) {
		let mut stack = vec![start];
		while let Some(parent) = stack.pop() {
			let kids = std::mem::take(&mut self.arena[parent].children);
			let mut first: U64Map<Slot> =
				U64Map::with_capacity_and_hasher(kids.len(), Default::default());
			let mut keep: Vec<usize> = Vec::with_capacity(kids.len());
			for c in kids {
				let h = merge_hash(&self.arena[c].name, &self.arena[c].value);
				let survivor = first.get(&h).and_then(|s| {
					s.first_match(|x| {
						merge_eq(
							&self.arena[x].name,
							&self.arena[x].value,
							&self.arena[c].name,
							&self.arena[c].value,
						)
					})
				});
				match survivor {
					Some(s) => {
						let kept = self.arena[s].children.len();
						fold_node_into(&mut self.arena, s, c);
						if let Some(ix) = self.index.get_mut() {
							ix.unlink(name_key(parent, &self.arena[c].name), c);
							for &k in &self.arena[s].children[kept..] {
								let name = &self.arena[k].name;
								ix.unlink(name_key(c, name), k);
								ix.append(name_key(s, name), k);
							}
						}
						stack.push(s);
					}
					None => {
						first
							.entry(h)
							.and_modify(|s| s.push(c))
							.or_insert(Slot::One(c));
						keep.push(c);
					}
				}
			}
			self.arena[parent].children = keep;
			settle_block(&mut self.arena, parent, 1);
		}
	}

	/// True when the path resolves to at least one real node.
	pub fn exists(&self, path: &str) -> bool {
		match self.resolve_group(path) {
			Ok(Resolved::One(_)) | Ok(Resolved::Many(_)) => true,
			Ok(Resolved::Slots(s)) => s.iter().any(|r| r.is_ok()),
			_ => false,
		}
	}

	/// Delete the node(s) at a path (with their subtrees); returns how many.
	/// Lines kept as written beside a node stay where they were, and a field
	/// opened only by the lines under it goes with the last of them.
	/// A removed node's storage is not reclaimed, so a process that adds and removes in a loop grows by a few hundred bytes a pair. Reloading the canonical text gives it back.
	pub fn remove(&mut self, path: &str) -> usize {
		let targets: Vec<usize> = match self.resolve_group(path) {
			Ok(Resolved::One(n)) => vec![n],
			Ok(Resolved::Many(v)) => v,
			Ok(Resolved::Slots(s)) => s.into_iter().filter_map(|r| r.ok()).collect(),
			_ => Vec::new(),
		};
		// Mark first, rebuild each touched child list once. Dropping one target
		// at a time rebuilt the same list once per target, which is quadratic
		// when a path matches many siblings.
		let mut pairs: Vec<(usize, usize)> = Vec::with_capacity(targets.len());
		for &t in &targets {
			let p = self.arena[t].parent;
			// A node already marked would pass DEAD into the rebuild below as
			// an index, so skip it rather than trust resolve never to name one
			// twice.
			if p == DEAD {
				continue;
			}
			if self.kept_owed > 0 {
				self.kept_owed = self.kept_owed.saturating_sub(self.taken(t));
			}
			if let Some(ix) = self.index.get_mut() {
				ix.unlink(name_key(p, &self.arena[t].name), t);
			}
			self.arena[t].parent = DEAD;
			pairs.push((t, p));
		}
		// Rebuilding a list puts back the parent of every node it drops, so a
		// mark still standing is also the answer to "has this parent been done
		// yet" - no separate pass to dedupe the parents.
		for &(t, p) in &pairs {
			if self.arena[t].parent != DEAD {
				continue;
			}
			// A list written stacked for the fields under it stays stacked:
			// a remove only takes lines away.
			let stacked = stacks(&self.arena[p]);
			let kids = std::mem::take(&mut self.arena[p].children);
			let mut keep: Vec<usize> = Vec::with_capacity(kids.len());
			let mut left: Vec<Lead> = Vec::new();
			for c in kids {
				if self.arena[c].parent == DEAD {
					self.arena[c].parent = p;
					left.append(&mut beside_kept(&mut self.arena[c]));
				} else {
					if !left.is_empty() {
						self.leave_above(c, std::mem::take(&mut left));
					}
					keep.push(c);
				}
			}
			self.arena[p].children = keep;
			self.arena[p].star_list |= stacked;
			// The next merge has a stacked list to put in brackets.
			self.bracketed &= !stacked;
			if !left.is_empty() {
				self.leave_last(p, left);
			}
		}
		// A field opened only by the lines under it goes with the last of
		// them, and its own kept line stays where it was (escblock).
		let mut open: Vec<usize> = pairs.iter().map(|&(_, p)| p).collect();
		while let Some(p) = open.pop() {
			if p == ROOT
				|| !self.arena[p].children.is_empty()
				|| !opened_by_kept(&self.arena[p])
				|| !self.live(p)
			{
				continue;
			}
			let pp = self.arena[p].parent;
			let t = self.arena[p].triv_mut();
			let mut left = std::mem::take(&mut t.leading);
			let mut under = std::mem::take(&mut t.inside);
			for l in &mut under {
				l.depth += 1;
			}
			left.append(&mut under);
			left.append(&mut t.after);
			if let Some(ix) = self.index.get_mut() {
				ix.unlink(name_key(pp, &self.arena[p].name), p);
			}
			let at = self.arena[pp]
				.children
				.iter()
				.position(|&c| c == p)
				.unwrap_or_default();
			let stacked = stacks(&self.arena[pp]);
			self.arena[pp].children.remove(at);
			self.arena[pp].star_list |= stacked;
			self.bracketed &= !stacked;
			match self.arena[pp].children.get(at) {
				Some(&next) => self.leave_above(next, left),
				None => self.leave_last(pp, left),
			}
			open.push(pp);
		}
		settle_first_blank(&mut self.arena, &mut self.orphans);
		self.resettle_kept();
		targets.len()
	}

	/// Lines a remove left, put above the sibling that followed them.
	fn leave_above(&mut self, node: usize, mut left: Vec<Lead>) {
		let t = self.arena[node].triv_mut();
		left.append(&mut t.leading);
		t.leading = left;
		restep(&mut t.leading);
	}

	/// Lines a remove left after the last of `parent`'s children: the
	/// document's footer at the top, else after the last child left, else
	/// inside the block. A misplaced line has no level there, so a reload
	/// files it with the next binding line, and the comments after it go
	/// along; kept field lines still go to the block.
	fn leave_last(&mut self, parent: usize, mut left: Vec<Lead>) {
		if parent == ROOT {
			left.append(&mut self.orphans);
			self.orphans = left;
			restep(&mut self.orphans);
			return;
		}
		let mut below = Vec::new();
		if let Some(at) = left.iter().position(|l| l.text.starts_with([' ', '\t'])) {
			let mut rest = left.split_off(at);
			let fields: Vec<Lead>;
			(fields, below) = rest.drain(..).partition(|l| is_field(&l.text));
			left.extend(fields);
		}
		if !left.is_empty() {
			// Stacked with no kept line among the elements is gone on a
			// reload, so it may not decide how these lines are written.
			let stacked = stacks(&self.arena[parent]);
			self.arena[parent].star_list = stacked;
			let list = match self.arena[parent].children.last().copied() {
				Some(last) => &mut self.arena[last].triv_mut().after,
				None => &mut self.arena[parent].triv_mut().inside,
			};
			list.append(&mut left);
			restep(list);
		}
		if !below.is_empty() {
			self.leave_below(parent, below);
		}
	}

	/// Lines a remove left right after `node`'s block: above the next
	/// binding line, or the footer when there is none.
	fn leave_below(&mut self, node: usize, mut left: Vec<Lead>) {
		let mut at = node;
		while at != ROOT {
			let up = self.arena[at].parent;
			let kids = &self.arena[up].children;
			if let Some(&next) = kids
				.iter()
				.position(|&c| c == at)
				.and_then(|k| kids.get(k + 1))
			{
				self.leave_above(next, left);
				return;
			}
			at = up;
		}
		left.append(&mut self.orphans);
		self.orphans = left;
		restep(&mut self.orphans);
	}

	/// Still in the tree: each node up to ROOT is in its parent's list. A
	/// removed node keeps its parent link, so the link alone does not say.
	fn live(&self, mut node: usize) -> bool {
		while node != ROOT {
			let p = self.arena[node].parent;
			if p == DEAD || !self.arena[p].children.contains(&node) {
				return false;
			}
			node = p;
		}
		true
	}

	/// Attach a leading comment line to the node at a path (creating an empty
	/// node if it does not exist yet, so a section can be annotated). A missing
	/// `#` is added, and trailing whitespace comes off the way the load takes
	/// it, so text that is blank leaves a bare `#`. Text holding a line break
	/// is refused: a comment is one line, and keeping only the first would
	/// drop the rest with nothing to say so.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_comment(&mut self, path: &str, text: &str) -> bool {
		let Some(c) = comment_line(text) else {
			return false;
		};
		match self.place(path, false) {
			Some(node) => {
				// The node's own blank moves above its first comment; otherwise
				// the blank would separate the comment from what it annotates.
				// Above the first one already there, when there is one.
				let nd = &mut self.arena[node];
				let mut lead = Lead::plain(c);
				if nd.blank_before {
					nd.blank_before = false;
					match nd.triv_mut().leading.first_mut() {
						Some(first) => first.blank_before = true,
						None => lead.blank_before = true,
					}
				}
				nd.triv_mut().leading.push(lead);
				settle_first_blank(&mut self.arena, &mut self.orphans);
				self.resettle_kept();
				true
			}
			None => false,
		}
	}

	/// The comment lines above the node(s) at a path, the ones clear_comments
	/// takes, in file order, each from its `#` on. A program can tell its own
	/// comment from one a user wrote there, and set_comment puts a line it
	/// gave back as it was. Empty when the path reaches nothing.
	pub fn comments(&self, path: &str) -> Vec<String> {
		let targets: Vec<usize> = match self.resolve_group(path) {
			Ok(Resolved::One(n)) => vec![n],
			Ok(Resolved::Many(v)) => v,
			Ok(Resolved::Slots(s)) => s.into_iter().filter_map(|r| r.ok()).collect(),
			_ => Vec::new(),
		};
		targets
			.iter()
			.filter_map(|&t| self.arena[t].trivia.as_deref())
			.flat_map(|tr| &tr.leading)
			.filter(|l| l.is_comment())
			.map(|l| l.text.clone())
			.collect()
	}

	/// Take off the comment lines above the node(s) at a path, the lines
	/// `set_comment` adds to, so a program can replace a comment rather than
	/// stack another one on it. Which lines those are is where the load put
	/// them: everything between the node and the binding line before it, so a
	/// heading written for a group of fields goes too. A comment on the
	/// node's own line stays, and so does a line kept as written for being
	/// malformed. Returns how many lines came off, 0 when the path reaches
	/// nothing.
	pub fn clear_comments(&mut self, path: &str) -> usize {
		let targets: Vec<usize> = match self.resolve_group(path) {
			Ok(Resolved::One(n)) => vec![n],
			Ok(Resolved::Many(v)) => v,
			Ok(Resolved::Slots(s)) => s.into_iter().filter_map(|r| r.ok()).collect(),
			_ => Vec::new(),
		};
		let mut cleared = 0;
		for t in targets {
			let nd = &mut self.arena[t];
			let Some(tr) = nd.trivia.as_deref_mut() else {
				continue;
			};
			let before = tr.leading.len();
			// The blank above the run is the one that separates it from what
			// comes before, so it stays with whatever is now first.
			let blank = tr.leading.first().is_some_and(|l| l.blank_before);
			tr.leading.retain(|l| !l.is_comment());
			let gone = before - tr.leading.len();
			if gone == 0 {
				continue;
			}
			cleared += gone;
			// A kept line left in the run may have sat under a comment that
			// went.
			restep(&mut tr.leading);
			if let Some(first) = tr.leading.first_mut() {
				first.blank_before |= blank;
			} else {
				nd.blank_before |= blank;
			}
		}
		if cleared > 0 {
			settle_first_blank(&mut self.arena, &mut self.orphans);
			self.resettle_kept();
		}
		cleared
	}

	/// Put the info block (`GEN_BANNER`) at the end of the document, or with
	/// `on` false just take it off. An old block comes off first, found by its
	/// `This config file format is SHCL.` line, never by its links or Legal
	/// line, which a later release may word differently. It runs from the
	/// lone `##` above that line to the next one, so a `##` comment of the
	/// file's own stays, even written right against it. A version line
	/// `migrate` stamped comes off too, with the note under it. Both are
	/// looked for in the footer and above every field but the first one and
	/// its first child down, since a field added below one by hand takes it
	/// as its comment. A block at the top of the file is left alone.
	/// A dotted first line hangs it on its last name, which a saved file
	/// writes as the first field's first child, so a block there is left
	/// alone too, however it got there. The library save never adds the
	/// block by itself; this is for a program that wants it in a file it
	/// writes. Returns how many old blocks came off.
	pub fn set_banner(&mut self, on: bool) -> usize {
		let mut removed = 0;
		// The first line's comments are the top of the file, on the first
		// node down, as a dotted line puts them on its last name.
		let mut top = Vec::new();
		let mut n = ROOT;
		while let Some(&c) = self.arena[n].children.first() {
			top.push(c);
			n = c;
		}
		let mut stack: Vec<usize> = self.arena[ROOT].children.clone();
		while let Some(n) = stack.pop() {
			stack.extend_from_slice(&self.arena[n].children);
			if top.contains(&n) {
				continue;
			}
			let Some(tr) = self.arena[n].trivia.as_deref_mut() else {
				continue;
			};
			let (gone, blank) = drop_banners(&mut tr.leading);
			if gone > 0 {
				removed += gone;
				self.arena[n].blank_before |= blank;
			}
		}
		removed += drop_banners(&mut self.orphans).0;
		if on {
			let open = !self.orphans.is_empty() || !self.arena[ROOT].children.is_empty();
			for (n, line) in GEN_BANNER.lines().enumerate() {
				let mut l = Lead::plain(line.to_string());
				l.blank_before = n == 0 && open;
				self.orphans.push(l);
			}
		}
		settle_first_blank(&mut self.arena, &mut self.orphans);
		self.resettle_kept();
		removed
	}

	/// Bind an integer at a path, creating the path as needed; false = path not
	/// writable (write_reason says why - same for every setter). The setters are
	/// must_use because an ignored false means the save that follows writes a
	/// document missing the edit, and reports success doing it.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_int(&mut self, path: &str, v: i64) -> bool {
		self.set_value(path, cell_of(v.to_string()))
	}
	/// Bind a float at a path, in the canonical shortest spelling. An
	/// infinity or a NaN has no spelling the reader accepts, so it fails the
	/// write rather than binding a value that cannot read back.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_float(&mut self, path: &str, v: f64) -> bool {
		if !v.is_finite() {
			return false;
		}
		self.set_value(path, cell_of(format_float(v)))
	}
	/// Bind true/false at a path.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_bool(&mut self, path: &str, v: bool) -> bool {
		self.set_value(path, cell_of(if v { "true" } else { "false" }.to_string()))
	}
	/// Bind a string at a path, escaped so it reads back exactly.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_string(&mut self, path: &str, v: &str) -> bool {
		self.set_value(path, cell_of(v.to_string()))
	}
	/// Bind a datetime at a path, in its canonical spelling. The struct's
	/// fields are public and have no invariant, so a value the reader would
	/// refuse (month 13, a fraction with no seconds, an empty struct) fails
	/// the write rather than binding text that cannot read back.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_datetime(&mut self, path: &str, v: &ShclDateTime) -> bool {
		if !datetime_reads_back(v) {
			return false;
		}
		self.set_value(path, cell_of(v.to_string()))
	}
	/// Bind a raw block at a path, picking a fence longer than any content line.
	/// The info-string is stored as a fence line would read it back (trimmed
	/// the way the load trims one); one that would not read back whole - it
	/// holds a line break, or a `#`, which reads as a comment - fails the
	/// write, as does a body line ending in CR, since the load takes the
	/// trailing CR run off every line.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_raw(&mut self, path: &str, content: &str, info: &str) -> bool {
		let info = trim_wsp(info);
		let (fence_char, fence_len) = choose_fence(content);
		self.set_value(
			path,
			Value::Raw(Box::new(RawVal {
				content: content.to_string(),
				info: info.to_string(),
				fence_char,
				fence_len,
			})),
		)
	}
	/// Bind an empty value at a path (distinct from the empty string).
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_empty(&mut self, path: &str) -> bool {
		self.set_value(path, Value::Empty)
	}

	/// Bind an inline integer array at a path.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_int_array(&mut self, path: &str, v: &[i64]) -> bool {
		self.set_value(path, array_cell(v.iter().map(|x| x.to_string()).collect()))
	}
	/// Bind an inline float array at a path.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_float_array(&mut self, path: &str, v: &[f64]) -> bool {
		if !v.iter().all(|x| x.is_finite()) {
			return false;
		}
		self.set_value(
			path,
			array_cell(v.iter().map(|x| format_float(*x)).collect()),
		)
	}
	/// Bind an inline bool array at a path.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_bool_array(&mut self, path: &str, v: &[bool]) -> bool {
		self.set_value(
			path,
			array_cell(
				v.iter()
					.map(|x| if *x { "true" } else { "false" }.to_string())
					.collect(),
			),
		)
	}
	/// Bind an inline string array at a path, per-element escaped.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_string_array(&mut self, path: &str, v: &[&str]) -> bool {
		self.set_value(path, array_cell(v.iter().map(|x| x.to_string()).collect()))
	}
	/// Bind an inline datetime array at a path.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_datetime_array(&mut self, path: &str, v: &[ShclDateTime]) -> bool {
		if !v.iter().all(datetime_reads_back) {
			return false;
		}
		self.set_value(path, array_cell(v.iter().map(|x| x.to_string()).collect()))
	}

	// Default (only-if-absent) forms - the "emit defaults" half of the Writer.
	// A path that already resolves writes nothing and reports what a write
	// there would: the path's verdict, so a wildcard is refused whether or not
	// its slots happen to resolve, and the value's, which the same setter gives
	// on the probe document.
	fn set_default(&mut self, path: &str, set: impl Fn(&mut Document, &str) -> bool) -> bool {
		if !self.exists(path) {
			return set(self, path);
		}
		if self.write_reason(path) != WriteReason::Writable {
			return false;
		}
		let probe = self.probe_doc.get_or_insert_with(|| {
			Box::new(Document {
				probe: true,
				..Document::new()
			})
		});
		set(probe, "v")
	}
	/// `set_int` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_int_default(&mut self, path: &str, v: i64) -> bool {
		self.set_default(path, |d, p| d.set_int(p, v))
	}
	/// `set_float` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_float_default(&mut self, path: &str, v: f64) -> bool {
		self.set_default(path, |d, p| d.set_float(p, v))
	}
	/// `set_bool` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_bool_default(&mut self, path: &str, v: bool) -> bool {
		self.set_default(path, |d, p| d.set_bool(p, v))
	}
	/// `set_string` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_string_default(&mut self, path: &str, v: &str) -> bool {
		self.set_default(path, |d, p| d.set_string(p, v))
	}
	/// Write TEXT as value syntax rather than as data: `80, 443` becomes a
	/// two-element array where `set_string` would store one string that has to
	/// be quoted. This is how a caller holding value text - a config line, a
	/// user's `--set` argument - writes it without knowing its shape first.
	/// Fails on text that could not be one line's value (see `literal_value`).
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_literal(&mut self, path: &str, text: &str) -> bool {
		match literal_value(text) {
			Some(v) => self.set_value_as(path, v, false),
			None => false,
		}
	}
	/// `set_literal` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_literal_default(&mut self, path: &str, text: &str) -> bool {
		self.set_default(path, |d, p| d.set_literal(p, text))
	}
	/// `set_datetime` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_datetime_default(&mut self, path: &str, v: &ShclDateTime) -> bool {
		self.set_default(path, |d, p| d.set_datetime(p, v))
	}
	/// `set_raw` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_raw_default(&mut self, path: &str, content: &str, info: &str) -> bool {
		self.set_default(path, |d, p| d.set_raw(p, content, info))
	}
	/// `set_int_array` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_int_array_default(&mut self, path: &str, v: &[i64]) -> bool {
		self.set_default(path, |d, p| d.set_int_array(p, v))
	}
	/// `set_float_array` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_float_array_default(&mut self, path: &str, v: &[f64]) -> bool {
		self.set_default(path, |d, p| d.set_float_array(p, v))
	}
	/// `set_bool_array` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_bool_array_default(&mut self, path: &str, v: &[bool]) -> bool {
		self.set_default(path, |d, p| d.set_bool_array(p, v))
	}
	/// `set_string_array` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_string_array_default(&mut self, path: &str, v: &[&str]) -> bool {
		self.set_default(path, |d, p| d.set_string_array(p, v))
	}
	/// `set_datetime_array` only when the path has no node yet.
	#[must_use = "a setter reports whether the write applied; an unusable path writes nothing (see write_reason)"]
	pub fn set_datetime_array_default(&mut self, path: &str, v: &[ShclDateTime]) -> bool {
		self.set_default(path, |d, p| d.set_datetime_array(p, v))
	}
}

// ---------------------------------------------------------------------------
// Layered loading: overlay a higher-priority document onto a lower one.
// ---------------------------------------------------------------------------

impl Document {
	/// Overlay `over` (a higher-priority layer) onto self (the lower one).
	/// Container instances merge by `(name, value)` exactly like the in-file
	/// rule; a leaf name present in `over` *replaces* self's same-named children
	/// at that scope - provided those base children are leaves too - so scalars,
	/// arrays, and raw blocks get real override while a bare section header
	/// merges instead of wiping. over-only nodes are appended. Comment trivia
	/// rides with each node.
	/// `Load(defaults, site, user)` is a left fold of this: each later file
	/// overlaid on the accumulation of the earlier ones.
	/// The fold is not associative: `(A+B)+C` and `A+(B+C)` differ where a bare
	/// header meets an overridden leaf, so a cached upper pair is not the same
	/// document the CLI's left fold produces. self keeps its own strictness,
	/// so a value from a stricter layer reads with self's coercion. And a
	/// replaced node is kept until the document is dropped: this costs a pass
	/// over the touched scopes plus an index rebuild on the next read.
	/// A document merged onto itself is left as it is. The borrow rules make
	/// that call impossible here; the other bindings check for it.
	pub fn merge(&mut self, over: &Document) {
		self.index.take();
		self.source = None;
		self.lost += over.lost;
		self.kept_owed += over.kept_owed;
		// The layer's own kept lines were modeled against its own tree.
		let fresh = over.kept;
		self.kept |= over.kept;
		self.arrays |= over.arrays;
		// Only a block the overlay visited can have a changed child list or
		// comments; the rest was settled when it was built. Settling the whole
		// tree made every merge cost the document (20260924 item 6). A block's
		// settle writes only below it, so the order does not matter.
		// Every list goes in brackets, whatever form its layers used, so a
		// merge of the merged text gives the same text. After the first, only
		// what the overlay brings or visits can be stacked.
		if !self.bracketed {
			for nd in &mut self.arena[1..] {
				bracket(nd);
			}
			self.bracketed = true;
		}
		let mut touched = Vec::new();
		self.overlay(ROOT, over, ROOT, &mut touched);
		for n in touched {
			settle_block(&mut self.arena, n, 1);
		}
		// Layers commonly share a footer; keeping one copy of each keeps a
		// stack of files from repeating it once per layer. Only the lines
		// already here count: a layer's own repeats are its content.
		let had = self.orphans.len();
		// A repeat skipped here may be the line the next one sat under, and a
		// reload puts a comment at most one level past the comment or kept
		// field line before it, so none goes deeper than that.
		let mut room = self
			.orphans
			.iter()
			.rev()
			.find(|l| !l.text.starts_with([' ', '\t']))
			.map_or(0, |l| l.depth + 1);
		// A kept line with kept lines under it goes in whole, so none of
		// them lands under some other line.
		let mut whole = vec![false; over.orphans.len()];
		let fields: Vec<usize> = (0..over.orphans.len())
			.filter(|&i| is_field(&over.orphans[i].text))
			.collect();
		for w in fields.windows(2) {
			if over.orphans[w[1]].depth > 0 {
				whole[w[0]] = true;
				whole[w[1]] = true;
			}
		}
		for (i, o) in over.orphans.iter().enumerate() {
			if whole[i]
				|| !self.orphans[..had]
					.iter()
					.any(|e| e.text == o.text && e.depth == o.depth)
			{
				let mut o = o.clone();
				if o.text.starts_with('#') {
					o.depth = o.depth.min(room);
					room = o.depth + 1;
				} else if is_field(&o.text) {
					room = o.depth + 1;
				}
				self.orphans.push(o);
			} else if o.is_kept_line() {
				// The table lets the dedup skip a footer line the base has.
				self.kept_owed = self.kept_owed.saturating_sub(1);
			}
		}
		settle_first_blank(&mut self.arena, &mut self.orphans);
		if fresh {
			self.settle_kept();
		} else {
			self.resettle_kept();
		}
	}

	// One grouping pass over each side, then a single children rebuild: the
	// old shape re-filtered the over side per distinct name and re-scanned
	// (and re-keyed) the base side per over node - three O(K^2) terms at one
	// parent, plus a full vector rebuild per replaced name.
	/// A matched instance keeps the base node, so the over side's comments have
	/// to move onto it or they are lost. Same rule as an in-file merge: leading
	/// concatenates in layer order, first trailing wins.
	fn adopt_trivia(&mut self, base: usize, over: &Document, ok: usize) {
		let Some(st) = over.arena[ok].trivia.as_deref() else {
			return;
		};
		let bt = self.arena[base].triv_mut();
		bt.leading.extend_from_slice(&st.leading);
		if !st.trailing.is_empty() {
			if bt.trailing.is_empty() {
				bt.trailing = st.trailing.clone();
			} else {
				bt.leading.push(Lead::plain(st.trailing.clone()));
			}
		}
		bt.after.extend_from_slice(&st.after);
		bt.inside.extend_from_slice(&st.inside);
		bt.among.extend_from_slice(&st.among);
		bt.among.sort_by_key(|a| a.0);
		bt.notes.extend_from_slice(&st.notes);
		bt.notes.sort_by_key(|n| n.0);
	}

	fn overlay(
		&mut self,
		base_parent: usize,
		over: &Document,
		over_parent: usize,
		touched: &mut Vec<usize>,
	) {
		touched.push(base_parent);
		let over_kids = &over.arena[over_parent].children;
		// Over side: name -> node bucket, in first-appearance order.
		let mut order: Vec<&str> = Vec::new();
		let mut groups: HashMap<&str, Vec<(usize, usize)>> = HashMap::new();
		for (pos, &k) in over_kids.iter().enumerate() {
			let n = over.arena[k].name.as_str();
			groups
				.entry(n)
				.or_insert_with(|| {
					order.push(n);
					Vec::new()
				})
				.push((pos, k));
		}
		// Base side, one pass: does the name have a container instance, and
		// which child has each (name, key) - every key computed once. The
		// list is cloned because the splices below rewrite it as they go.
		let base_kids = self.arena[base_parent].children.clone();
		let mut has_container: HashMap<String, bool> = HashMap::new();
		let mut by_name: HashMap<String, Vec<usize>> = HashMap::new();
		// Keyed on the hash of (name, merge key) and verified on a hit, so no
		// key text is built per child on either side.
		let mut by_key: U64Map<Slot> =
			U64Map::with_capacity_and_hasher(base_kids.len(), Default::default());
		let find = |arena: &[NodeData], by_key: &U64Map<Slot>, h: u64, name: &str, v: &Value| {
			by_key
				.get(&h)
				.and_then(|s| s.first_match(|x| merge_eq(&arena[x].name, &arena[x].value, name, v)))
		};
		for &b in &base_kids {
			let nd = &self.arena[b];
			let e = has_container.entry(nd.name.clone()).or_insert(false);
			*e = *e || !nd.children.is_empty();
			by_name.entry(nd.name.clone()).or_default().push(b);
			let h = merge_hash(&nd.name, &nd.value);
			if find(&self.arena, &by_key, h, &nd.name, &nd.value).is_none() {
				by_key
					.entry(h)
					.and_modify(|s| s.push(b))
					.or_insert(Slot::One(b));
			}
		}
		// Decide per name. A name whose over-side nodes are all leaves is an
		// override - but only when the base side of the group is leaf-shaped
		// too. Against a base container, a childless over-node is a wrapper
		// mention, not a leaf, so it falls through to the instance merge: a
		// bare section header in a higher layer never wipes the subtree below.
		// Replaced groups splice in the rebuild; everything appended (unmatched
		// instances, and replaced names base never had) keeps the over file's
		// order, which the per-name pass here would otherwise regroup.
		let mut replace: HashMap<&str, Vec<usize>> = HashMap::new();
		let mut appended: Vec<(usize, usize)> = Vec::new();
		for &name in &order {
			let group = &groups[name];
			let over_leafy = group
				.iter()
				.all(|&(_, k)| over.arena[k].children.is_empty());
			let in_base = has_container.contains_key(name);
			let base_container = has_container.get(name).copied().unwrap_or(false);
			if over_leafy && !base_container {
				let clones: Vec<(usize, usize)> = group
					.iter()
					.map(|&(pos, ok)| (pos, self.clone_subtree(over, ok, base_parent)))
					.collect();
				if in_base {
					// The replaced leaf's comments go with it, which the spec
					// allows; a content-malformed line retained on it is
					// content the parser promised to keep, so those move
					// onto the replacement. A comment starts with `#`, a
					// retained line never does.
					let mut kept: Vec<Lead> = Vec::new();
					// Off the index, not a scan of every base child: N leaves
					// overridden by the same N names made this quadratic
					// (20260918b item 58).
					for &b in by_name.get(name).map_or(&[][..], |v| v.as_slice()) {
						let nd = &self.arena[b];
						// The leaf's own comments are the ones a remove would
						// take: above it those after its last kept line, below
						// it those before its first. The rest sit with a kept
						// line beside it and stay. A settled line counts as
						// the comment a reload reads it as.
						let leading = nd.leading();
						let above = leading
							.iter()
							.rposition(|l| !l.text.starts_with('#'))
							.map_or(0, |k| k + 1);
						let after = nd.after();
						let below = after
							.iter()
							.position(|l| !l.text.starts_with('#'))
							.unwrap_or(after.len());
						kept.extend_from_slice(&leading[..above]);
						let among = nd.among().iter().map(|a| &a.1);
						for l in leading[above..]
							.iter()
							.chain(among)
							.chain(nd.inside())
							.chain(&after[..below])
						{
							if !l.text.starts_with('#') {
								kept.push(l.clone());
							} else if l.kept {
								// A settled one goes with the leaf's comments
								// (decided 2026-09-28), so it is no longer owed.
								self.kept_owed = self.kept_owed.saturating_sub(1);
							}
						}
						kept.extend_from_slice(&after[below..]);
					}
					if !kept.is_empty() {
						let t = self.arena[clones[0].1].triv_mut();
						kept.append(&mut t.leading);
						t.leading = kept;
						// Comments from two sources now share one run.
						restep(&mut t.leading);
					}
					replace.insert(name, clones.into_iter().map(|(_, c)| c).collect());
				} else {
					appended.extend(clones);
				}
			} else {
				for &(pos, ok) in group {
					let ov = &over.arena[ok].value;
					let hk = merge_hash(name, ov);
					let mut target = find(&self.arena, &by_key, hk, name, ov);
					// A raw block in the higher layer fills a same-named empty
					// binding below, exactly as a fence line fills one inside a
					// single file. Without it, merging two documents and parsing
					// them run together disagree: both bindings survive here and
					// fold there, so the merged output is not a formatter fixpoint.
					if target.is_none() && matches!(ov, Value::Raw { .. }) {
						let he = merge_hash(name, &Value::Empty);
						if let Some(b) = find(&self.arena, &by_key, he, name, &Value::Empty) {
							self.arena[b].value = ov.clone();
							if by_key.get_mut(&he).is_some_and(|s| s.remove(b)) {
								by_key.remove(&he);
							}
							by_key
								.entry(hk)
								.and_modify(|s| s.push(b))
								.or_insert(Slot::One(b));
							target = Some(b);
						}
					}
					match target {
						Some(b) => {
							// A stacked spelling no kept line holds is gone on
							// a reload, so it may not decide how the lines the
							// other layer brings are written (20260926 item 4).
							self.adopt_trivia(b, over, ok);
							self.overlay(b, over, ok, touched);
							bracket(&mut self.arena[b]);
						}
						None => {
							let c = self.clone_subtree(over, ok, base_parent);
							appended.push((pos, c));
						}
					}
				}
			}
		}
		if replace.is_empty() && appended.is_empty() {
			return;
		}
		// Rebuild once: each replaced group goes to its name's first original
		// position (dropped nodes stay in the arena, unreferenced - reads and
		// emit walk children from the root), appends go at the end.
		let mut newkids: Vec<usize> = Vec::with_capacity(base_kids.len() + appended.len());
		let mut spliced: std::collections::HashSet<&str> = std::collections::HashSet::new();
		for &b in &base_kids {
			let name = self.arena[b].name.as_str();
			match replace.get(name) {
				Some(clones) => {
					if spliced.insert(name) {
						newkids.extend(clones.iter().copied());
					}
				}
				None => newkids.push(b),
			}
		}
		appended.sort_by_key(|&(pos, _)| pos);
		newkids.extend(appended.iter().map(|&(_, c)| c));
		self.arena[base_parent].children = newkids;
	}

	/// Deep-copy `over`'s subtree at `oi` into self's arena under `parent`.
	fn clone_subtree(&mut self, over: &Document, oi: usize, parent: usize) -> usize {
		let src = &over.arena[oi];
		let node = NodeData {
			name: src.name.clone(),
			value: src.value.clone(),
			children: Vec::new(),
			parent,
			line: src.line,
			star_list: src.star_list,
			star_mixed: src.star_mixed,
			trivia: src.trivia.clone(),
			blank_before: src.blank_before,
			src_set: src.src_set,
			src: src.src.clone(),
			name_src: src.name_src.clone(),
		};
		let idx = self.arena.len();
		self.arena.push(node);
		for &ok in &over.arena[oi].children {
			let c = self.clone_subtree(over, ok, idx);
			self.arena[idx].children.push(c);
		}
		bracket(&mut self.arena[idx]);
		idx
	}
}

impl Default for Document {
	fn default() -> Document {
		Document::new()
	}
}

impl std::str::FromStr for Document {
	/// Parsing at Standard cannot fail - a malformed line becomes a diagnostic,
	/// not a refusal - so `"a: 1".parse::<Document>()` is infallible. Use
	/// `parse_with(text, Strictness::Strict)` for the load that can fail.
	type Err = std::convert::Infallible;
	fn from_str(text: &str) -> Result<Document, Self::Err> {
		Ok(Document::parse(text))
	}
}

impl std::fmt::Display for Document {
	/// The canonical form, so `println!("{doc}")` prints the document the way
	/// `fmt` would write it.
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.write_str(&self.to_canonical())
	}
}

// ---------------------------------------------------------------------------
// Coercion ("intelligent but safe"; Loose re-admits a closed list of tricks)
// ---------------------------------------------------------------------------

const CURRENCY: &[char] = &[
	'$', '¢', '£', '¤', '¥', '₩', '₪', '₫', '€', '₭', '₮', '₱', '₲', '₴', '₹', '₺', '₼', '₽', '₾',
	'₿',
];

/// The remainder after a leading currency symbol, with the space a person
/// writes after one taken off - `$ 1200` reached the int path's thousands
/// branch, which trims, and the float path's shape test, which does not.
fn strip_currency(t: &str) -> &str {
	let mut it = t.chars();
	match it.next() {
		Some(c) if CURRENCY.contains(&c) => it.as_str().trim_start(),
		_ => t,
	}
}

fn parse_int_text(e: &Element, level: Strictness) -> Option<i64> {
	let mut t = e.text.trim();
	if level == Strictness::Loose {
		t = strip_currency(t);
	}
	// Plain decimal.
	let body = t.strip_prefix(['+', '-']).unwrap_or(t);
	if !body.is_empty() && body.bytes().all(|b| b.is_ascii_digit()) {
		return t.parse::<i64>().ok();
	}
	// Hex, octal and binary.
	let (neg, prefixed) = match t.strip_prefix('-') {
		Some(r) => (true, r),
		None => (false, t.strip_prefix('+').unwrap_or(t)),
	};
	if let Some((radix, digits)) = radix_body(prefixed) {
		// Parse the magnitude as u64, then range-check against the sign, so the
		// negative i64::MIN magnitude (0x8000000000000000) reads like its decimal
		// spelling instead of overflowing an i64 parse.
		let m = u64::from_str_radix(digits, radix).ok()?;
		return if neg {
			if m == (i64::MAX as u64) + 1 {
				Some(i64::MIN)
			} else if m <= i64::MAX as u64 {
				Some(-(m as i64))
			} else {
				None
			}
		} else if m <= i64::MAX as u64 {
			Some(m as i64)
		} else {
			None
		};
	}
	// Thousands separators, only inside quotes (bare commas are reserved).
	if e.quoted() && t.contains(',') {
		let sign_body = t.strip_prefix(['+', '-']).unwrap_or(t);
		let groups: Vec<&str> = sign_body.split(',').collect();
		let well_formed = groups.len() > 1
			&& !groups[0].is_empty()
			&& groups[0].len() <= 3
			&& groups[0].bytes().all(|b| b.is_ascii_digit())
			&& groups[1..]
				.iter()
				.all(|g| g.len() == 3 && g.bytes().all(|b| b.is_ascii_digit()));
		if well_formed {
			return t.replace(',', "").parse::<i64>().ok();
		}
	}
	// Loose: a float (including %) rounds, half away from zero.
	if level == Strictness::Loose
		&& let Some(f) = parse_float_text(e, level)
	{
		let r = f.round();
		// i64::MAX has no exact f64 - the cast rounds it up to 2^63 - so a
		// `<=` against it lets 2^63 in and the cast below saturates to a value
		// the text never said. Bound on 2^63 itself, exclusively. i64::MIN is
		// exact, so the low end needs no such care.
		if r >= i64::MIN as f64 && r < 9_223_372_036_854_775_808.0 {
			return Some(r as i64);
		}
	}
	None
}

/// The digits after a `0x`, `0o` or `0b` prefix, either case, with their
/// radix. A bare leading zero is decimal, so `0o` is the one way to write an
/// octal mode.
fn radix_body(t: &str) -> Option<(u32, &str)> {
	let b = t.as_bytes();
	if b.len() < 3 || b[0] != b'0' {
		return None;
	}
	let radix = match b[1] {
		b'x' | b'X' => 16,
		b'o' | b'O' => 8,
		b'b' | b'B' => 2,
		_ => return None,
	};
	let digits = &t[2..];
	digits
		.bytes()
		.all(|c| char::from(c).is_digit(radix))
		.then_some((radix, digits))
}

fn float_shape_ok(t: &str) -> bool {
	let body = t.strip_prefix(['+', '-']).unwrap_or(t);
	if body.is_empty() {
		return false;
	}
	let (mantissa, exp) = match body.split_once(['e', 'E']) {
		Some((m, x)) => (m, Some(x)),
		None => (body, None),
	};
	if let Some(x) = exp {
		let xb = x.strip_prefix(['+', '-']).unwrap_or(x);
		if xb.is_empty() || !xb.bytes().all(|b| b.is_ascii_digit()) {
			return false;
		}
	}
	let (int_part, frac_part) = match mantissa.split_once('.') {
		Some((a, b)) => (a, b),
		None => (mantissa, ""),
	};
	if int_part.is_empty() && frac_part.is_empty() {
		return false;
	}
	int_part.bytes().all(|b| b.is_ascii_digit()) && frac_part.bytes().all(|b| b.is_ascii_digit())
}

fn parse_float_text(e: &Element, level: Strictness) -> Option<f64> {
	let mut t = e.text.trim();
	let mut percent = false;
	if level == Strictness::Loose {
		t = strip_currency(t);
		if let Some(inner) = t.strip_suffix('%') {
			t = inner.trim_end();
			percent = true;
		}
	}
	let v = if float_shape_ok(t) {
		// A literal past the double range parses as an infinity, which no
		// double holds and no setter can write back: BadType, like a text
		// that is not a number at all.
		t.parse::<f64>().ok().filter(|v| v.is_finite())?
	} else {
		// An integer is a valid float on read (incl. hex, octal, binary and quoted thousands).
		let el = Element {
			text: t.to_string(),
			mark: e.mark,
		};
		match parse_int_text_no_loose(&el) {
			Some(i) => i as f64,
			None => parse_int_text_wide(&el)?,
		}
	};
	Some(if percent { v / 100.0 } else { v })
}

/// Integer forms only (no Loose float fallback) - used by the float path so the
/// two can't recurse into each other.
fn parse_int_text_no_loose(e: &Element) -> Option<i64> {
	parse_int_text(e, Strictness::Standard)
}

/// The integer spellings the plain float parse does not read - hex, octal,
/// binary and quoted thousands - past the i64 range, as a double: a float read
/// is bounded by the double, not by the integer type. A prefixed number goes
/// in digit by digit in the double, so every binding rounds the same way; the
/// spellings mirror parse_int_text.
fn parse_int_text_wide(e: &Element) -> Option<f64> {
	let t = e.text.trim();
	let (neg, body) = match t.strip_prefix('-') {
		Some(r) => (true, r),
		None => (false, t.strip_prefix('+').unwrap_or(t)),
	};
	let v = if let Some((radix, digits)) = radix_body(body) {
		digits.bytes().fold(0.0f64, |v, b| {
			v * f64::from(radix) + f64::from(char::from(b).to_digit(radix).unwrap_or(0))
		})
	} else if e.quoted() && body.contains(',') {
		let groups: Vec<&str> = body.split(',').collect();
		let well_formed = groups.len() > 1
			&& !groups[0].is_empty()
			&& groups[0].len() <= 3
			&& groups[0].bytes().all(|b| b.is_ascii_digit())
			&& groups[1..]
				.iter()
				.all(|g| g.len() == 3 && g.bytes().all(|b| b.is_ascii_digit()));
		if !well_formed {
			return None;
		}
		body.replace(',', "").parse::<f64>().ok()?
	} else {
		return None;
	};
	if !v.is_finite() {
		return None;
	}
	Some(if neg { -v } else { v })
}

fn parse_bool_text(t: &str, level: Strictness) -> Option<bool> {
	let s = t.trim().to_ascii_lowercase();
	match (level, s.as_str()) {
		(_, "true") => Some(true),
		(_, "false") => Some(false),
		(Strictness::Strict, _) => None,
		(_, "yes") | (_, "on") | (_, "1") => Some(true),
		(_, "no") | (_, "off") | (_, "0") => Some(false),
		(Strictness::Loose, "t")
		| (Strictness::Loose, "y")
		| (Strictness::Loose, "enable")
		| (Strictness::Loose, "enabled") => Some(true),
		(Strictness::Loose, "f")
		| (Strictness::Loose, "n")
		| (Strictness::Loose, "disable")
		| (Strictness::Loose, "disabled") => Some(false),
		_ => None,
	}
}

// ---------------------------------------------------------------------------
// Durations and sizes: a number with a unit, or a bare number whose unit the
// field name or the caller gives
// ---------------------------------------------------------------------------

/// The unit a duration read gives a bare number, when the field name gives
/// none. Smallest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum DurationUnit {
	Millis,
	Seconds,
	Minutes,
	Hours,
	Days,
}

impl DurationUnit {
	fn millis(self) -> u64 {
		match self {
			DurationUnit::Millis => 1,
			DurationUnit::Seconds => 1_000,
			DurationUnit::Minutes => 60_000,
			DurationUnit::Hours => 3_600_000,
			DurationUnit::Days => 86_400_000,
		}
	}

	/// The spelling a value uses: `ms`, `s`, `m`, `h` or `d`.
	#[must_use]
	pub fn spelling(self) -> &'static str {
		match self {
			DurationUnit::Millis => "ms",
			DurationUnit::Seconds => "s",
			DurationUnit::Minutes => "m",
			DurationUnit::Hours => "h",
			DurationUnit::Days => "d",
		}
	}

	/// The unit a value spelling names, lower case only.
	#[must_use]
	pub fn from_spelling(s: &str) -> Option<DurationUnit> {
		match s {
			"ms" => Some(DurationUnit::Millis),
			"s" => Some(DurationUnit::Seconds),
			"m" => Some(DurationUnit::Minutes),
			"h" => Some(DurationUnit::Hours),
			"d" => Some(DurationUnit::Days),
			_ => None,
		}
	}
}

/// The unit a size read gives a bare number, when the field name gives none.
/// `Kilo` to `Tera` are powers of 1024 unless the read asks for decimal;
/// `Kibi` to `Tebi` always are.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SizeUnit {
	Bytes,
	Kilo,
	Mega,
	Giga,
	Tera,
	Kibi,
	Mebi,
	Gibi,
	Tebi,
}

impl SizeUnit {
	fn bytes(self, decimal: bool) -> u64 {
		let k: u64 = if decimal { 1000 } else { 1024 };
		match self {
			SizeUnit::Bytes => 1,
			SizeUnit::Kilo => k,
			SizeUnit::Mega => k * k,
			SizeUnit::Giga => k * k * k,
			SizeUnit::Tera => k * k * k * k,
			SizeUnit::Kibi => 1 << 10,
			SizeUnit::Mebi => 1 << 20,
			SizeUnit::Gibi => 1 << 30,
			SizeUnit::Tebi => 1 << 40,
		}
	}

	/// The spelling a value uses: `B`, `KB`, `MB`, `GB`, `TB`, `KiB`, `MiB`,
	/// `GiB` or `TiB`.
	#[must_use]
	pub fn spelling(self) -> &'static str {
		match self {
			SizeUnit::Bytes => "B",
			SizeUnit::Kilo => "KB",
			SizeUnit::Mega => "MB",
			SizeUnit::Giga => "GB",
			SizeUnit::Tera => "TB",
			SizeUnit::Kibi => "KiB",
			SizeUnit::Mebi => "MiB",
			SizeUnit::Gibi => "GiB",
			SizeUnit::Tebi => "TiB",
		}
	}

	/// The unit a value spelling names. Letter case is read, since `Mb` is
	/// megabits to most readers; `kB` is the one other spelling taken.
	#[must_use]
	pub fn from_spelling(s: &str) -> Option<SizeUnit> {
		match s {
			"B" => Some(SizeUnit::Bytes),
			"KB" | "kB" => Some(SizeUnit::Kilo),
			"MB" => Some(SizeUnit::Mega),
			"GB" => Some(SizeUnit::Giga),
			"TB" => Some(SizeUnit::Tera),
			"KiB" => Some(SizeUnit::Kibi),
			"MiB" => Some(SizeUnit::Mebi),
			"GiB" => Some(SizeUnit::Gibi),
			"TiB" => Some(SizeUnit::Tebi),
			_ => None,
		}
	}
}

/// The longest duration a read gives, in milliseconds: Go's `time.Duration`
/// range, so every binding holds every duration another one reads.
const DURATION_MAX_MS: u64 = 9_223_372_036_854;

/// Field name endings that give a bare number its unit, after a `-` or `_`.
/// `min`, `m` and `s` are left out: `retries-min` is a minimum, and a
/// trailing `s` is usually a plural. A capitalized word (`timeoutMs`) is not
/// a boundary, since names fold to lower case and `fmt` writes them folded.
const DURATION_NAMES: [(&str, DurationUnit); 6] = [
	("ms", DurationUnit::Millis),
	("sec", DurationUnit::Seconds),
	("seconds", DurationUnit::Seconds),
	("minutes", DurationUnit::Minutes),
	("hours", DurationUnit::Hours),
	("days", DurationUnit::Days),
];

const SIZE_NAMES: [(&str, SizeUnit); 9] = [
	("bytes", SizeUnit::Bytes),
	("kb", SizeUnit::Kilo),
	("mb", SizeUnit::Mega),
	("gb", SizeUnit::Giga),
	("tb", SizeUnit::Tera),
	("kib", SizeUnit::Kibi),
	("mib", SizeUnit::Mebi),
	("gib", SizeUnit::Gibi),
	("tib", SizeUnit::Tebi),
];

/// The unit a field name ends in, from `table`: the ending, in any letter
/// case, after a `-` or `_`.
fn name_unit<U: Copy>(name: &str, table: &[(&str, U)]) -> Option<U> {
	let b = name.as_bytes();
	table.iter().find_map(|&(end, unit)| {
		let at = b.len().checked_sub(end.len()).filter(|&at| at > 0)?;
		(b[at..].eq_ignore_ascii_case(end.as_bytes()) && matches!(b[at - 1], b'-' | b'_'))
			.then_some(unit)
	})
}

/// A decimal number at the start of `s`: digits, then a point and more
/// digits if there is a point. The two digit runs, and where it ended.
fn decimal_at(s: &str) -> Option<(&str, &str, usize)> {
	let b = s.as_bytes();
	let int = b.iter().take_while(|c| c.is_ascii_digit()).count();
	if int == 0 {
		return None;
	}
	if b.get(int) != Some(&b'.') {
		return Some((&s[..int], "", int));
	}
	let frac = b[int + 1..]
		.iter()
		.take_while(|c| c.is_ascii_digit())
		.count();
	if frac == 0 {
		return None;
	}
	Some((&s[..int], &s[int + 1..int + 1 + frac], int + 1 + frac))
}

/// `int.frac` times `scale`, exactly. None when that is not a whole number
/// or does not fit, so `1.5s` is 1500 ms and `0.0001s` is refused. At most
/// 18 digits after the point count, which keeps the sum in 64 bits: the
/// fraction's share is below `scale`, and dividing out their common factor
/// first gets it without a wider product.
fn scaled(int: &str, frac: &str, scale: u64) -> Option<u64> {
	let int = int.trim_start_matches('0');
	let frac = frac.trim_end_matches('0');
	if int.len() > 19 || frac.len() > 18 {
		return None;
	}
	let whole: u64 = if int.is_empty() { 0 } else { int.parse().ok()? };
	let mut total = whole.checked_mul(scale)?;
	if !frac.is_empty() {
		let part: u64 = frac.parse().ok()?;
		let den = 10u64.pow(frac.len() as u32);
		let (mut a, mut b) = (scale, den);
		while b != 0 {
			(a, b) = (b, a % b);
		}
		let step = den / a;
		if !part.is_multiple_of(step) {
			return None;
		}
		total = total.checked_add(part / step * (scale / a))?;
	}
	Some(total)
}

/// A duration in whole milliseconds, and the units the text used: parts
/// such as `1h 30m`, largest unit first and each once, with blanks allowed
/// between a number and its unit and between parts. A bare number takes
/// `bare`, and is None without one. No sign.
fn parse_duration_text(t: &str, bare: Option<DurationUnit>) -> Option<(i64, Vec<DurationUnit>)> {
	let t = trim_wsp(t);
	if let Some((int, frac, end)) = decimal_at(t)
		&& end == t.len()
	{
		let ms = scaled(int, frac, bare?.millis())?;
		return (ms <= DURATION_MAX_MS).then(|| (ms as i64, Vec::new()));
	}
	let mut rest = t;
	let mut total: u64 = 0;
	let mut units: Vec<DurationUnit> = Vec::new();
	while !rest.is_empty() {
		let (int, frac, end) = decimal_at(rest)?;
		rest = rest[end..].trim_start_matches(is_wsp);
		let n = rest.bytes().take_while(u8::is_ascii_alphabetic).count();
		let unit = DurationUnit::from_spelling(&rest[..n])?;
		if units.last().is_some_and(|&u| u <= unit) {
			return None;
		}
		total = total.checked_add(scaled(int, frac, unit.millis())?)?;
		units.push(unit);
		rest = rest[n..].trim_start_matches(is_wsp);
	}
	if units.is_empty() || total > DURATION_MAX_MS {
		return None;
	}
	Some((total as i64, units))
}

/// A size in whole bytes, and the unit the text used: a number, blanks
/// allowed, then a unit. A bare number takes `bare`, and is None without
/// one. No sign.
fn parse_size_text(
	t: &str,
	bare: Option<SizeUnit>,
	decimal: bool,
) -> Option<(i64, Option<SizeUnit>)> {
	let t = trim_wsp(t);
	let (int, frac, end) = decimal_at(t)?;
	let rest = t[end..].trim_start_matches(is_wsp);
	let unit = if rest.is_empty() {
		None
	} else {
		Some(SizeUnit::from_spelling(rest)?)
	};
	let n = scaled(int, frac, unit.or(bare)?.bytes(decimal))?;
	(n <= i64::MAX as u64).then_some((n as i64, unit))
}

/// Whether a name ends in a duration or size unit. Asked before a value's
/// text is built for `unit_clash`, since most names do not.
fn unit_named(name: &str) -> bool {
	name_unit(name, &DURATION_NAMES).is_some() || name_unit(name, &SIZE_NAMES).is_some()
}

/// A value in another unit than the one its field name ends in (`H005`), as
/// `timeout-ms: 5s`. The value's unit is the one read, so this is a hint.
fn unit_clash(name: &str, text: &str) -> Option<String> {
	let said = |v: &str, n: &str| {
		format!(
			"value is in {} and the name says {}; the value's unit is the one read",
			v, n
		)
	};
	if let Some(nu) = name_unit(name, &DURATION_NAMES)
		&& let Some((_, units)) = parse_duration_text(text, None)
		&& !units.contains(&nu)
	{
		return Some(said(units[0].spelling(), nu.spelling()));
	}
	if let Some(nu) = name_unit(name, &SIZE_NAMES)
		&& let Some((_, Some(vu))) = parse_size_text(text, None, false)
		&& vu != nu
	{
		return Some(said(vu.spelling(), nu.spelling()));
	}
	None
}

// ---------------------------------------------------------------------------
// Date/time (closed whitelist; shape match, then calendar validation)
// ---------------------------------------------------------------------------

const MONTHS: &[(&str, u32)] = &[
	("jan", 1),
	("feb", 2),
	("mar", 3),
	("apr", 4),
	("may", 5),
	("jun", 6),
	("jul", 7),
	("aug", 8),
	("sep", 9),
	("oct", 10),
	("nov", 11),
	("dec", 12),
	("january", 1),
	("february", 2),
	("march", 3),
	("april", 4),
	("june", 6),
	("july", 7),
	("august", 8),
	("september", 9),
	("october", 10),
	("november", 11),
	("december", 12),
];

fn month_from_name(s: &str) -> Option<u32> {
	let l = s.to_ascii_lowercase();
	MONTHS.iter().find(|(n, _)| *n == l).map(|(_, m)| *m)
}

fn days_in_month(y: i32, m: u32) -> u32 {
	match m {
		1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
		4 | 6 | 9 | 11 => 30,
		2 => {
			if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 {
				29
			} else {
				28
			}
		}
		_ => 0,
	}
}

fn valid_date(y: i32, m: u32, d: u32) -> bool {
	(1..=12).contains(&m) && d >= 1 && d <= days_in_month(y, m)
}

fn parse_date_part(s: &str) -> Option<(i32, u32, u32)> {
	let s = s.trim();
	// Compact 8-digit YYYYMMDD.
	if s.len() == 8 && s.bytes().all(|b| b.is_ascii_digit()) {
		let y: i32 = s[..4].parse().ok()?;
		let m: u32 = s[4..6].parse().ok()?;
		let d: u32 = s[6..8].parse().ok()?;
		return valid_date(y, m, d).then_some((y, m, d));
	}
	// Space-separated named-month forms; a comma may follow the day in "Mon DD, YYYY".
	let toks: Vec<&str> = s.split_whitespace().collect();
	if toks.len() == 3 {
		// The day is DD, like every other form's: a plain integer parse takes a
		// leading '+' and any number of leading zeros, which the whitelist does
		// not list and the delimited spellings already refuse.
		if let Some(m) = month_from_name(toks[0]) {
			let day_tok = toks[1].strip_suffix(',').unwrap_or(toks[1]);
			let d: u32 = parse_num2(day_tok)?;
			let y: i32 = parse_year4(toks[2])?;
			return valid_date(y, m, d).then_some((y, m, d));
		}
		if let Some(m) = month_from_name(toks[1]) {
			let d: u32 = parse_num2(toks[0])?;
			let y: i32 = parse_year4(toks[2])?;
			return valid_date(y, m, d).then_some((y, m, d));
		}
		return None;
	}
	if toks.len() != 1 {
		return None;
	}
	// Delimited forms: one of - / . used uniformly.
	let delim = s.chars().find(|c| matches!(c, '-' | '/' | '.'))?;
	let parts: Vec<&str> = s.split(delim).collect();
	if parts.len() != 3 || parts.iter().any(|p| p.is_empty()) {
		return None;
	}
	// The delimiter must be uniform: no other delimiter chars anywhere.
	if s.chars().filter(|c| matches!(c, '-' | '/' | '.')).count() != 2 {
		return None;
	}
	if parts[0].len() == 4 && parts[0].bytes().all(|b| b.is_ascii_digit()) {
		// Year-first all-numeric.
		let y: i32 = parts[0].parse().ok()?;
		let m: u32 = parse_num2(parts[1])?;
		let d: u32 = parse_num2(parts[2])?;
		return valid_date(y, m, d).then_some((y, m, d));
	}
	if let Some(m) = month_from_name(parts[0]) {
		let d: u32 = parse_num2(parts[1])?;
		let y: i32 = parse_year4(parts[2])?;
		return valid_date(y, m, d).then_some((y, m, d));
	}
	if let Some(m) = month_from_name(parts[1]) {
		let d: u32 = parse_num2(parts[0])?;
		let y: i32 = parse_year4(parts[2])?;
		return valid_date(y, m, d).then_some((y, m, d));
	}
	None // everything else (MM/DD/YYYY, 2-digit years, epoch) is rejected by decision
}

fn parse_year4(s: &str) -> Option<i32> {
	(s.len() == 4 && s.bytes().all(|b| b.is_ascii_digit())).then(|| s.parse().ok())?
}

fn parse_num2(s: &str) -> Option<u32> {
	((s.len() == 1 || s.len() == 2) && s.bytes().all(|b| b.is_ascii_digit()))
		.then(|| s.parse().ok())?
}

/// (hour, minute, seconds-if-written), fraction digits, zone.
type TimeParts = ((u32, u32, Option<u32>), Option<String>, Option<Zone>);

/// Time with optional meridiem, fraction, zone: `H:MM[:SS[.f+]][ AM|PM][Z|+HH:MM]`.
fn parse_time_part(s: &str) -> Option<TimeParts> {
	let mut t = s.trim();
	// Zone suffix first (only valid after a time).
	let mut zone: Option<Zone> = None;
	if let Some(rest) = t.strip_suffix(['Z', 'z']) {
		zone = Some(Zone::Utc);
		t = rest.trim_end();
	} else if t.len() >= 6 {
		// Byte-wise on purpose: a str slice here can fall mid-char and panic when
		// the tail holds multibyte text. All-ASCII match implies the cut is a
		// char boundary, so the later &t[..len-6] is safe.
		let tail = &t.as_bytes()[t.len() - 6..];
		let sign = tail[0];
		if (sign == b'+' || sign == b'-')
			&& tail[1].is_ascii_digit()
			&& tail[2].is_ascii_digit()
			&& tail[3] == b':'
			&& tail[4].is_ascii_digit()
			&& tail[5].is_ascii_digit()
		{
			let hh = i32::from(tail[1] - b'0') * 10 + i32::from(tail[2] - b'0');
			let mm = i32::from(tail[4] - b'0') * 10 + i32::from(tail[5] - b'0');
			if hh <= 23 && mm <= 59 {
				let mut off = hh * 60 + mm;
				if sign == b'-' {
					off = -off;
				}
				zone = Some(Zone::OffsetMinutes(off));
				t = t[..t.len() - 6].trim_end();
			}
		}
	}
	// Meridiem: mandatory minutes already implied by the H:MM shape; dotted
	// a.m. is rejected (the '.' fails the digit checks below).
	let mut meridiem: Option<bool> = None; // true = PM
	let lower = t.to_ascii_lowercase();
	if let Some(rest) = lower.strip_suffix("am") {
		meridiem = Some(false);
		t = &t[..rest.trim_end().len()];
	} else if let Some(rest) = lower.strip_suffix("pm") {
		meridiem = Some(true);
		t = &t[..rest.trim_end().len()];
	}
	let t = t.trim_end();
	// Fraction: only after seconds, '.' delimiter, 1-9 digits.
	let (hms, frac) = match t.split_once('.') {
		Some((a, f)) => {
			if f.is_empty() || f.len() > 9 || !f.bytes().all(|b| b.is_ascii_digit()) {
				return None;
			}
			(a, Some(f.to_string()))
		}
		None => (t, None),
	};
	let parts: Vec<&str> = hms.split(':').collect();
	if parts.len() < 2 || parts.len() > 3 {
		return None;
	}
	if frac.is_some() && parts.len() != 3 {
		return None; // fraction can only follow HH:MM:SS
	}
	let h_raw: u32 = parse_num2(parts[0])?;
	let mi: u32 = (parts[1].len() == 2)
		.then(|| parse_num2(parts[1]))
		.flatten()?;
	let sec: Option<u32> = match parts.get(2) {
		Some(p) => Some((p.len() == 2).then(|| parse_num2(p)).flatten()?),
		None => None,
	};
	if mi > 59 || sec.is_some_and(|x| x > 59) {
		return None;
	}
	let h = match meridiem {
		None => {
			if h_raw > 23 {
				return None;
			}
			h_raw
		}
		Some(pm) => {
			if !(1..=12).contains(&h_raw) {
				return None;
			}
			match (pm, h_raw) {
				(false, 12) => 0,
				(false, x) => x,
				(true, 12) => 12,
				(true, x) => x + 12,
			}
		}
	};
	Some(((h, mi, sec), frac, zone))
}

/// Whether a datetime's canonical spelling reads back as the same value: the
/// setter's inverse-of-the-read promise, checked by making the round trip.
fn datetime_reads_back(v: &ShclDateTime) -> bool {
	parse_datetime(&v.to_string()).as_ref() == Some(v)
}

/// Whole-value date/time parse per the whitelist. None = BadType.
pub fn parse_datetime(text: &str) -> Option<ShclDateTime> {
	let t = text.trim();
	if t.is_empty() {
		return None;
	}
	if let Some(colon) = t.find(':') {
		// Scan back over the 1-2 hour digits to find where the time starts.
		let bytes = t.as_bytes();
		let mut k = colon;
		while k > 0 && bytes[k - 1].is_ascii_digit() && colon - k < 2 {
			k -= 1;
		}
		if k == colon {
			return None; // ':' with no hour digits before it
		}
		if k == 0 {
			// Time-only value.
			let ((h, mi, s), frac, zone) = parse_time_part(t)?;
			return Some(ShclDateTime {
				date: None,
				time: Some((h, mi, s)),
				frac,
				zone,
			});
		}
		// Combined: one separator char between date and time.
		let sep = t[..k].chars().last()?;
		if !matches!(sep, 'T' | 't' | ' ' | '_' | '-' | '/' | '.') {
			return None;
		}
		let date_str = &t[..k - sep.len_utf8()];
		let date = parse_date_part(date_str)?;
		let ((h, mi, s), frac, zone) = parse_time_part(&t[k..])?;
		return Some(ShclDateTime {
			date: Some(date),
			time: Some((h, mi, s)),
			frac,
			zone,
		});
	}
	// Date-only.
	let date = parse_date_part(t)?;
	Some(ShclDateTime {
		date: Some(date),
		time: None,
		frac: None,
		zone: None,
	})
}

// ---------------------------------------------------------------------------
// Accessor: typed reads
// ---------------------------------------------------------------------------

impl Document {
	/// Single node at a path, or the failing status.
	fn node_at(&self, path: &str) -> Result<usize, Status> {
		match self.resolve(path)? {
			Resolved::None => Err(Status::NotFound),
			Resolved::Many(_) | Resolved::Slots(_) => Err(Status::Multiple),
			Resolved::One(n) => Ok(n),
		}
	}

	/// A read's `raw`: the verbatim source value text when the value came from
	/// one source line, else the display form (writer-built, stacked list, raw
	/// block - shapes with no one-line source spelling).
	fn raw_of(&self, n: usize) -> String {
		match &self.arena[n].src {
			Some(s) => s.clone(),
			None => self.arena[n].value.display(),
		}
	}

	/// The one element a scalar read takes: `[80]` reads as 80 and `[]` as
	/// empty, while two elements are not one scalar.
	fn scalar_element<'a>(&self, v: &'a Value) -> Result<&'a Element, Status> {
		match v {
			Value::Empty => Err(Status::Empty),
			Value::Raw { .. } => Err(Status::BadType),
			Value::Cell(e) => Ok(e),
			Value::Array(els) => match els.as_slice() {
				[] => Err(Status::Empty),
				[e] => Ok(e),
				_ => Err(Status::BadType),
			},
		}
	}

	fn read_scalar<T: Default>(
		&self,
		path: &str,
		coerce: impl Fn(&Element) -> Option<T>,
	) -> Read<T> {
		let node = match self.node_at(path) {
			Ok(n) => n,
			Err(st) => return Read::new(T::default(), st, None),
		};
		let value = &self.arena[node].value;
		let raw = Some(self.raw_of(node));
		let line = self.arena[node].line;
		match self.scalar_element(value) {
			Ok(el) => match coerce(el) {
				Some(v) => Read::new(v, Status::Good, raw).at(line, Some(el)),
				None => Read::new(T::default(), Status::BadType, raw).at(line, Some(el)),
			},
			Err(st) => Read::new(T::default(), st, raw).at(line, None),
		}
	}

	/// Full-tier integer read at a path, coerced per the document's strictness.
	pub fn read_int(&self, path: &str) -> Read<i64> {
		let lvl = self.strictness;
		self.read_scalar(path, |e| parse_int_text(e, lvl))
	}

	/// Full-tier float read at a path, coerced per the document's strictness.
	pub fn read_float(&self, path: &str) -> Read<f64> {
		let lvl = self.strictness;
		self.read_scalar(path, |e| parse_float_text(e, lvl))
	}

	/// Full-tier bool read at a path, coerced per the document's strictness.
	pub fn read_bool(&self, path: &str) -> Read<bool> {
		let lvl = self.strictness;
		self.read_scalar(path, |e| parse_bool_text(&e.text, lvl))
	}

	/// Full-tier datetime read at a path.
	pub fn read_datetime(&self, path: &str) -> Read<ShclDateTime> {
		self.read_scalar(path, |e| parse_datetime(&e.text))
	}

	/// read_scalar with the node's name, for the reads whose bare number
	/// takes its unit from the name.
	fn read_named<T: Default>(
		&self,
		path: &str,
		coerce: impl Fn(&Element, &str) -> Option<T>,
	) -> Read<T> {
		match self.node_at(path) {
			Ok(n) => {
				let name = self.arena[n].name.as_str();
				self.read_scalar(path, |e| coerce(e, name))
			}
			Err(st) => Read::new(T::default(), st, None),
		}
	}

	/// Full-tier duration read at a path, in whole milliseconds: `500ms`,
	/// `30s`, `1h 30m`, `2d`. A bare number takes its unit from the field
	/// name when the name ends in one (`timeout-ms`, `delay_seconds`), else
	/// from `unit`, and is BadType with neither.
	pub fn read_duration(
		&self,
		path: &str,
		unit: Option<DurationUnit>,
	) -> Read<std::time::Duration> {
		self.read_named(path, |e, name| {
			let bare = name_unit(name, &DURATION_NAMES).or(unit);
			parse_duration_text(&e.text, bare)
				.map(|(ms, _)| std::time::Duration::from_millis(ms as u64))
		})
	}

	/// Full-tier size read at a path, in whole bytes: `512MB`, `1.5 GiB`. A
	/// bare number takes its unit the way a duration does. `KB` to `TB` are
	/// powers of 1024 unless `decimal` is set.
	pub fn read_size(&self, path: &str, unit: Option<SizeUnit>, decimal: bool) -> Read<i64> {
		self.read_named(path, |e, name| {
			let bare = name_unit(name, &SIZE_NAMES).or(unit);
			parse_size_text(&e.text, bare, decimal).map(|(n, _)| n)
		})
	}

	/// Any value reads as a string: a raw block yields its content, an array its
	/// canonical bracket form. Escapes are applied.
	pub fn read_string(&self, path: &str) -> Read<String> {
		let node = match self.node_at(path) {
			Ok(n) => n,
			Err(st) => return Read::new(String::new(), st, None),
		};
		let value = &self.arena[node].value;
		let raw = Some(self.raw_of(node));
		let line = self.arena[node].line;
		match value {
			Value::Empty => Read::new(String::new(), Status::Empty, raw).at(line, None),
			Value::Raw(r) => Read::new(r.content.clone(), Status::Good, raw).at(line, None),
			Value::Cell(e) => Read::new(e.text.clone(), Status::Good, raw).at(line, Some(e)),
			// Canonical bracket form (quoting + escapes intact), so the string
			// re-parses to the same array, and `[80]` never reads as `80`.
			Value::Array(els) => Read::new(emit_array(els), Status::Good, raw).at(line, None),
		}
	}

	/// Raw-block content (verbatim). Non-block values are BadType.
	pub fn read_raw(&self, path: &str) -> Read<String> {
		let node = match self.node_at(path) {
			Ok(n) => n,
			Err(st) => return Read::new(String::new(), st, None),
		};
		let value = &self.arena[node].value;
		let raw = Some(self.raw_of(node));
		let line = self.arena[node].line;
		match value {
			Value::Raw(r) => Read::new(r.content.clone(), Status::Good, raw).at(line, None),
			Value::Empty => Read::new(String::new(), Status::Empty, raw).at(line, None),
			Value::Cell(_) | Value::Array(_) => {
				Read::new(String::new(), Status::BadType, raw).at(line, None)
			}
		}
	}

	/// The advisory info-string of a raw block ("" when absent).
	pub fn read_raw_info(&self, path: &str) -> Read<String> {
		let node = match self.node_at(path) {
			Ok(n) => n,
			Err(st) => return Read::new(String::new(), st, None),
		};
		let raw = Some(self.raw_of(node));
		let line = self.arena[node].line;
		// An empty binding has no block, so no info string: `Empty`, the same as a `read_raw` on it. Only a value that is there and is not a block is a type mismatch.
		match &self.arena[node].value {
			Value::Raw(r) => Read::new(r.info.clone(), Status::Good, raw).at(line, None),
			Value::Empty => Read::new(String::new(), Status::Empty, raw).at(line, None),
			Value::Cell(_) | Value::Array(_) => {
				Read::new(String::new(), Status::BadType, raw).at(line, None)
			}
		}
	}

	fn read_array<T: Default>(
		&self,
		path: &str,
		coerce: impl Fn(&Element) -> Option<T>,
	) -> Read<Vec<T>> {
		// Wildcard paths: one slot per instance, missing sub-paths keep their slot
		// (spec: never silently dropped). Each slot reads like a scalar of the
		// target type and records its own status; the aggregate is the worst one.
		match self.resolve(path) {
			Err(st) => Read::new(Vec::new(), st, None),
			Ok(Resolved::Slots(slots)) => {
				let mut out: Vec<T> = Vec::new();
				let mut sts: Vec<Status> = Vec::new();
				for slot in &slots {
					match slot {
						Err(st) => {
							out.push(T::default());
							sts.push(*st);
						}
						Ok(n) => match self.scalar_element(&self.arena[*n].value) {
							Ok(el) => {
								let (v, st) = coerced(&coerce, el);
								out.push(v);
								sts.push(st);
							}
							Err(st) => {
								out.push(T::default());
								sts.push(st);
							}
						},
					}
				}
				// No slots at all means the wildcard's parent is not there, so
				// the path did not resolve - Empty is for a node that is.
				let status = if sts.is_empty() {
					Status::NotFound
				} else {
					sts.iter().copied().max().unwrap_or(Status::Good)
				};
				Read::with_slots(out, status, None, sts)
			}
			Ok(Resolved::None) => Read::new(Vec::new(), Status::NotFound, None),
			Ok(Resolved::Many(_)) => Read::new(Vec::new(), Status::Multiple, None),
			Ok(Resolved::One(n)) => {
				let value = &self.arena[n].value;
				let raw = Some(self.raw_of(n));
				let line = self.arena[n].line;
				match value {
					Value::Empty => Read::new(Vec::new(), Status::Empty, raw).at(line, None),
					Value::Raw { .. } => Read::new(Vec::new(), Status::BadType, raw).at(line, None),
					Value::Cell(_) | Value::Array(_) => {
						let els = match value {
							Value::Array(els) => els.as_slice(),
							Value::Cell(e) => std::slice::from_ref(e),
							_ => &[],
						};
						let mut out = Vec::with_capacity(els.len());
						let mut sts = Vec::with_capacity(els.len());
						for el in els {
							let (v, st) = coerced(&coerce, el);
							out.push(v);
							sts.push(st);
						}
						let status = sts.iter().copied().max().unwrap_or(Status::Good);
						// A one-element value has a single scalar element, so
						// the flag means the same thing here as on the scalar
						// read of the same node. `[]` is an empty array, which
						// is Good, where an empty value is Empty.
						let only = if let [el] = els { Some(el) } else { None };
						Read::with_slots(out, status, raw, sts).at(line, only)
					}
				}
			}
		}
	}

	/// Full-tier integer-array read at a path (per-slot statuses in `slots`).
	pub fn read_int_array(&self, path: &str) -> Read<Vec<i64>> {
		let lvl = self.strictness;
		self.read_array(path, |e| parse_int_text(e, lvl))
	}

	/// Full-tier float-array read at a path.
	pub fn read_float_array(&self, path: &str) -> Read<Vec<f64>> {
		let lvl = self.strictness;
		self.read_array(path, |e| parse_float_text(e, lvl))
	}

	/// Full-tier bool-array read at a path.
	pub fn read_bool_array(&self, path: &str) -> Read<Vec<bool>> {
		let lvl = self.strictness;
		self.read_array(path, |e| parse_bool_text(&e.text, lvl))
	}

	/// Full-tier datetime-array read at a path.
	pub fn read_datetime_array(&self, path: &str) -> Read<Vec<ShclDateTime>> {
		self.read_array(path, |e| parse_datetime(&e.text))
	}

	/// Full-tier string-array read at a path, escapes applied per element.
	pub fn read_string_array(&self, path: &str) -> Read<Vec<String>> {
		self.read_array(path, |e| Some(e.text.clone()))
	}

	// Full tier, Result form: Ok(value) on Good; the sentinel otherwise. Empty
	// still comes back as Err(Empty) here; use read_* to also get the empty value.

	/// `read_int` reduced to a `Result`.
	pub fn get_int(&self, path: &str) -> Result<i64, Status> {
		let r = self.read_int(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_float` reduced to a `Result`.
	pub fn get_float(&self, path: &str) -> Result<f64, Status> {
		let r = self.read_float(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_bool` reduced to a `Result`.
	pub fn get_bool(&self, path: &str) -> Result<bool, Status> {
		let r = self.read_bool(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_string` reduced to a `Result`.
	pub fn get_string(&self, path: &str) -> Result<String, Status> {
		let r = self.read_string(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_raw` reduced to a `Result`.
	pub fn get_raw(&self, path: &str) -> Result<String, Status> {
		let r = self.read_raw(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_raw_info` reduced to a `Result`.
	pub fn get_raw_info(&self, path: &str) -> Result<String, Status> {
		let r = self.read_raw_info(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_datetime` reduced to a `Result`.
	pub fn get_datetime(&self, path: &str) -> Result<ShclDateTime, Status> {
		let r = self.read_datetime(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_duration` reduced to a `Result`.
	pub fn get_duration(
		&self,
		path: &str,
		unit: Option<DurationUnit>,
	) -> Result<std::time::Duration, Status> {
		let r = self.read_duration(path, unit);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_size` reduced to a `Result`.
	pub fn get_size(
		&self,
		path: &str,
		unit: Option<SizeUnit>,
		decimal: bool,
	) -> Result<i64, Status> {
		let r = self.read_size(path, unit, decimal);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	// Array get-tier: Ok only when the whole read is Good, so `.unwrap_or(def)`
	// gives the convenience "the array, or this fallback array" - the array
	// analogue of the scalar get_*. Per-slot substitution is the full read_*
	// tier (its `slots`) or the CLI's --default, not this.
	/// `read_int_array` reduced to a `Result`.
	pub fn get_int_array(&self, path: &str) -> Result<Vec<i64>, Status> {
		let r = self.read_int_array(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_float_array` reduced to a `Result`.
	pub fn get_float_array(&self, path: &str) -> Result<Vec<f64>, Status> {
		let r = self.read_float_array(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_bool_array` reduced to a `Result`.
	pub fn get_bool_array(&self, path: &str) -> Result<Vec<bool>, Status> {
		let r = self.read_bool_array(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_string_array` reduced to a `Result`.
	pub fn get_string_array(&self, path: &str) -> Result<Vec<String>, Status> {
		let r = self.read_string_array(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	/// `read_datetime_array` reduced to a `Result`.
	pub fn get_datetime_array(&self, path: &str) -> Result<Vec<ShclDateTime>, Status> {
		let r = self.read_datetime_array(path);
		if r.status == Status::Good {
			Ok(r.value)
		} else {
			Err(r.status)
		}
	}

	// Convenience tier: the value, or the call-site fallback unless the read is
	// Good. `get_int(p).unwrap_or(0)` says the same thing and still works; these
	// exist so the spelling that means "with a fallback" is `_or` in every
	// binding, and a routine ported between two of them cannot keep the call
	// name while changing which tier it uses.

	/// The integer at a path, or `def` when the read is not Good.
	pub fn get_int_or(&self, path: &str, def: i64) -> i64 {
		self.get_int(path).unwrap_or(def)
	}

	/// The float at a path, or `def` when the read is not Good.
	pub fn get_float_or(&self, path: &str, def: f64) -> f64 {
		self.get_float(path).unwrap_or(def)
	}

	/// The bool at a path, or `def` when the read is not Good.
	pub fn get_bool_or(&self, path: &str, def: bool) -> bool {
		self.get_bool(path).unwrap_or(def)
	}

	/// The string at a path, or `def` when the read is not Good.
	pub fn get_string_or(&self, path: &str, def: String) -> String {
		self.get_string(path).unwrap_or(def)
	}

	/// The raw-block content at a path, or `def` when the read is not Good.
	pub fn get_raw_or(&self, path: &str, def: String) -> String {
		self.get_raw(path).unwrap_or(def)
	}

	/// The raw block's info-string at a path, or `def` when the read is not Good.
	pub fn get_raw_info_or(&self, path: &str, def: String) -> String {
		self.get_raw_info(path).unwrap_or(def)
	}

	/// The datetime at a path, or `def` when the read is not Good.
	pub fn get_datetime_or(&self, path: &str, def: ShclDateTime) -> ShclDateTime {
		self.get_datetime(path).unwrap_or(def)
	}

	/// The duration at a path, or `def` when the read is not Good.
	pub fn get_duration_or(
		&self,
		path: &str,
		unit: Option<DurationUnit>,
		def: std::time::Duration,
	) -> std::time::Duration {
		self.get_duration(path, unit).unwrap_or(def)
	}

	/// The size at a path, or `def` when the read is not Good.
	pub fn get_size_or(&self, path: &str, unit: Option<SizeUnit>, decimal: bool, def: i64) -> i64 {
		self.get_size(path, unit, decimal).unwrap_or(def)
	}

	/// The integer array at a path, or `def` when the read is not Good.
	pub fn get_int_array_or(&self, path: &str, def: Vec<i64>) -> Vec<i64> {
		self.get_int_array(path).unwrap_or(def)
	}

	/// The float array at a path, or `def` when the read is not Good.
	pub fn get_float_array_or(&self, path: &str, def: Vec<f64>) -> Vec<f64> {
		self.get_float_array(path).unwrap_or(def)
	}

	/// The bool array at a path, or `def` when the read is not Good.
	pub fn get_bool_array_or(&self, path: &str, def: Vec<bool>) -> Vec<bool> {
		self.get_bool_array(path).unwrap_or(def)
	}

	/// The string array at a path, or `def` when the read is not Good.
	pub fn get_string_array_or(&self, path: &str, def: Vec<String>) -> Vec<String> {
		self.get_string_array(path).unwrap_or(def)
	}

	/// The datetime array at a path, or `def` when the read is not Good.
	pub fn get_datetime_array_or(&self, path: &str, def: Vec<ShclDateTime>) -> Vec<ShclDateTime> {
		self.get_datetime_array(path).unwrap_or(def)
	}
}

// ---------------------------------------------------------------------------
// Validator: schema-as-SHCL
// ---------------------------------------------------------------------------
// The schema is an ordinary parsed document: a flat list of `field: <path>`
// instances whose children are the constraints (closed vocabulary - see
// spec.md "Schema validation"). Validation reuses the accessor's path scan and
// the typed coercions, so document strictness composes for free. Schema faults
// (V09x) come first and the surviving constraints still check the document;
// the unknown-field sweep skips only when a fault cost a path spelling. One
// line-number space per result.

const SCHEMA_TYPES: [&str; 13] = [
	"int",
	"float",
	"bool",
	"string",
	"datetime",
	"raw",
	"duration",
	"size",
	"int-array",
	"float-array",
	"bool-array",
	"string-array",
	"datetime-array",
];

// The allowed set, pre-coerced at schema-build time into the constraint's type
// space so per-node checks are a plain contains().
#[derive(Clone)]
enum AllowedSet {
	Ints(Vec<i64>),
	Floats(Vec<f64>),
	Bools(Vec<bool>),
	Dates(Vec<ShclDateTime>),
	Strings(Vec<String>),
}

#[derive(Clone)]
struct Constraint {
	path: String, // as written in the schema; message text only
	segs: Vec<Segment>,
	ty: Option<String>, // member of SCHEMA_TYPES
	required: bool,
	allowed: Option<AllowedSet>,
	min_i: Option<i64>,
	max_i: Option<i64>,
	min_f: Option<f64>,
	max_f: Option<f64>,
	// duration and size: the unit a bare number takes when the field name
	// gives none, base 10 for KB to TB, and the bounds as the schema wrote
	// them, since min_i and max_i hold them in milliseconds or bytes.
	unit_d: Option<DurationUnit>,
	unit_s: Option<SizeUnit>,
	decimal: bool,
	bound_text: (Option<String>, Option<String>),
	repeat: Option<(u64, u64)>,
	reopen: bool,             // H002 suppressor only; validation ignores it
	inherits: Option<String>, // fragment mounted at this path (subtree shape)
	inherits_line: usize,     // schema line of the `inherits` key, for V095
	// Generator-only (`shcl init`): validation ignores both.
	desc: Option<String>,         // `desc`, a one-line description
	default_text: Option<String>, // `default`, emitted as an inline value
}

/// An interpreted schema: the top-level constraints plus the named fragments
/// their `inherits` keys can mount.
struct SchemaDef {
	cons: Vec<Constraint>,
	frags: HashMap<String, Vec<Constraint>>,
	// False when a fault cost the schema a path spelling (unreadable `field:`
	// path, or a mount naming no declared fragment). Key-level faults keep
	// their entry's chain, so only these two classes can turn declared fields
	// into false unknowns - the sweep runs unless one of them happened.
	paths_complete: bool,
}

/// One slot of an array read: the coerced value, or the type's default with
/// BadType.
fn coerced<T: Default>(coerce: &impl Fn(&Element) -> Option<T>, el: &Element) -> (T, Status) {
	match coerce(el) {
		Some(v) => (v, Status::Good),
		None => (T::default(), Status::BadType),
	}
}

fn vdiag(out: &mut Vec<Diagnostic>, line: usize, code: &'static str, msg: String) {
	out.push(Diagnostic {
		line,
		severity: Severity::Error,
		message: msg,
		code,
	});
}

/// One scalar constraint value (escapes applied), or None for anything else.
fn single_text(v: &Value) -> Option<String> {
	match v {
		Value::Cell(e) => Some(e.text.clone()),
		_ => None,
	}
}

/// A schema value's elements: a scalar's one, or an array's.
fn elements_of(v: &Value) -> &[Element] {
	match v {
		Value::Cell(e) => std::slice::from_ref(e),
		Value::Array(els) => els,
		Value::Empty | Value::Raw(_) => &[],
	}
}

/// Interpret a parsed schema document into constraints and fragments, plus
/// any schema faults (V09x, schema-file lines). Whatever parsed cleanly is
/// kept even when faults are present - a broken key drops that key, a broken
/// field drops that field - so a caller can still check the document against
/// the surviving constraints.
fn build_schema(schema: &Document) -> (SchemaDef, Vec<Diagnostic>) {
	let mut faults: Vec<Diagnostic> = Vec::new();
	let mut cons: Vec<Constraint> = Vec::new();
	let mut frags: HashMap<String, Vec<Constraint>> = HashMap::new();
	let mut paths_complete = true;
	for &f in &schema.arena[ROOT].children {
		let node = &schema.arena[f];
		match node.name.as_str() {
			"field" => {
				if let Some(c) = parse_field(schema, f, &mut faults) {
					cons.push(c);
				} else {
					paths_complete = false;
				}
			}
			"fragment" => {
				let name = single_text(&node.value).filter(|n| !n.is_empty());
				let Some(name) = name else {
					vdiag(
						&mut faults,
						node.line,
						"V094",
						"bad schema fragment".to_string(),
					);
					continue;
				};
				// Two `fragment` blocks of one name never reach here: the parse
				// merges them into one node and reports H002. Kept as a guard in
				// case that changes, which is why no case pins it.
				if frags.contains_key(&name) {
					vdiag(
						&mut faults,
						node.line,
						"V094",
						format!("bad schema fragment '{}': duplicate", diag_name(&name)),
					);
					continue;
				}
				let mut fcs: Vec<Constraint> = Vec::new();
				for &k in &schema.arena[f].children {
					let kid = &schema.arena[k];
					if kid.name == "field" {
						if let Some(c) = parse_field(schema, k, &mut faults) {
							fcs.push(c);
						} else {
							paths_complete = false;
						}
					} else {
						vdiag(
							&mut faults,
							kid.line,
							"V094",
							format!(
								"bad schema fragment '{}': unknown key '{}'",
								diag_name(&name),
								diag_name(&kid.name)
							),
						);
					}
				}
				frags.insert(name, fcs);
			}
			other => {
				vdiag(
					&mut faults,
					node.line,
					"V090",
					format!("unknown schema key '{}'", diag_name(other)),
				);
			}
		}
	}
	// Every mount must name a declared fragment; cycles (self or mutual) are
	// legal - expansion is demand-driven against a finite document.
	for c in cons.iter().chain(frags.values().flatten()) {
		if let Some(fr) = &c.inherits
			&& !frags.contains_key(fr)
		{
			vdiag(
				&mut faults,
				c.inherits_line,
				"V095",
				format!("unknown schema fragment '{}'", diag_name(fr)),
			);
			paths_complete = false;
		}
	}
	// One constraint per line in practice, so line order = file order.
	faults.sort_by_key(|d| d.line);
	(
		SchemaDef {
			cons,
			frags,
			paths_complete,
		},
		faults,
	)
}

/// One `field:` instance (top-level or inside a fragment) -> a Constraint.
/// None = faults were reported and the constraint is dropped.
fn parse_field(schema: &Document, f: usize, faults: &mut Vec<Diagnostic>) -> Option<Constraint> {
	let node = &schema.arena[f];
	let Some(path) = single_text(&node.value) else {
		vdiag(faults, node.line, "V093", "bad schema path".to_string());
		return None;
	};
	let segs = match scan_lookup(&path) {
		Ok(s) if s.value.is_none() => s.segments,
		_ => {
			vdiag(
				faults,
				node.line,
				"V093",
				format!("bad schema path: {}", schema_text(&path)),
			);
			return None;
		}
	};
	let mut c = Constraint {
		path,
		segs,
		ty: None,
		required: false,
		allowed: None,
		min_i: None,
		max_i: None,
		min_f: None,
		max_f: None,
		unit_d: None,
		unit_s: None,
		decimal: false,
		bound_text: (None, None),
		repeat: None,
		reopen: false,
		inherits: None,
		inherits_line: 0,
		desc: None,
		default_text: None,
	};
	// Deferred so `min: 1` may precede `type: int` in the file.
	let mut required: Option<bool> = None;
	let mut reopen_seen = false;
	let mut allowed_at: Option<usize> = None;
	let mut default_at: Option<usize> = None;
	let mut min_at: Option<usize> = None;
	let mut max_at: Option<usize> = None;
	let mut unit_at: Option<usize> = None;
	let mut decimal_at_key: Option<usize> = None;
	for &k in &schema.arena[f].children {
		let kid = &schema.arena[k];
		if kid.value.is_empty() {
			continue; // dangling key: treated as absent
		}
		match kid.name.as_str() {
			"type" => match single_text(&kid.value).map(|t| t.to_ascii_lowercase()) {
				Some(t) if SCHEMA_TYPES.contains(&t.as_str()) => {
					if c.ty.is_some() {
						vdiag(
							faults,
							kid.line,
							"V092",
							"bad schema constraint 'type'".to_string(),
						);
					} else {
						c.ty = Some(t);
					}
				}
				Some(t) => {
					vdiag(
						faults,
						kid.line,
						"V091",
						format!("unknown schema type '{}'", schema_text(&t)),
					);
				}
				None => vdiag(
					faults,
					kid.line,
					"V092",
					"bad schema constraint 'type'".to_string(),
				),
			},
			"required" => {
				let v =
					single_text(&kid.value).and_then(|t| parse_bool_text(&t, Strictness::Standard));
				match v {
					Some(b) if required.is_none() => required = Some(b),
					_ => vdiag(
						faults,
						kid.line,
						"V092",
						"bad schema constraint 'required'".to_string(),
					),
				}
			}
			// Consumed by the H002 suppressor; validation itself ignores it,
			// but a bad value still faults so a typo cannot silently disavow
			// nothing.
			"reopen" => {
				let v =
					single_text(&kid.value).and_then(|t| parse_bool_text(&t, Strictness::Standard));
				match v {
					Some(b) if !reopen_seen => {
						reopen_seen = true;
						c.reopen = b;
					}
					_ => vdiag(
						faults,
						kid.line,
						"V092",
						"bad schema constraint 'reopen'".to_string(),
					),
				}
			}
			"allowed" => match &kid.value {
				Value::Cell(_) if allowed_at.is_none() => allowed_at = Some(k),
				Value::Array(els) if !els.is_empty() && allowed_at.is_none() => {
					allowed_at = Some(k)
				}
				_ => vdiag(
					faults,
					kid.line,
					"V092",
					"bad schema constraint 'allowed'".to_string(),
				),
			},
			"min" => match &kid.value {
				Value::Cell(_) if min_at.is_none() => min_at = Some(k),
				_ => vdiag(
					faults,
					kid.line,
					"V092",
					"bad schema constraint 'min'".to_string(),
				),
			},
			"max" => match &kid.value {
				Value::Cell(_) if max_at.is_none() => max_at = Some(k),
				_ => vdiag(
					faults,
					kid.line,
					"V092",
					"bad schema constraint 'max'".to_string(),
				),
			},
			"unit" => match &kid.value {
				Value::Cell(_) if unit_at.is_none() => unit_at = Some(k),
				_ => vdiag(
					faults,
					kid.line,
					"V092",
					"bad schema constraint 'unit'".to_string(),
				),
			},
			"decimal" => {
				let v =
					single_text(&kid.value).and_then(|t| parse_bool_text(&t, Strictness::Standard));
				match v {
					Some(b) if decimal_at_key.is_none() => {
						decimal_at_key = Some(k);
						c.decimal = b;
					}
					_ => vdiag(
						faults,
						kid.line,
						"V092",
						"bad schema constraint 'decimal'".to_string(),
					),
				}
			}
			"repeat" => match elements_of(&kid.value) {
				els if c.repeat.is_none() && matches!(els.len(), 1 | 2) => {
					let lo = els[0].text.parse::<u64>().ok();
					let hi = els.last().and_then(|e| e.text.parse::<u64>().ok());
					match (lo, hi) {
						(Some(a), Some(b)) if a <= b => c.repeat = Some((a, b)),
						_ => vdiag(
							faults,
							kid.line,
							"V092",
							"bad schema constraint 'repeat'".to_string(),
						),
					}
				}
				_ => vdiag(
					faults,
					kid.line,
					"V092",
					"bad schema constraint 'repeat'".to_string(),
				),
			},
			"inherits" => match single_text(&kid.value).filter(|t| !t.is_empty()) {
				Some(t) if c.inherits.is_none() => {
					c.inherits = Some(t);
					c.inherits_line = kid.line;
				}
				_ => vdiag(
					faults,
					kid.line,
					"V092",
					"bad schema constraint 'inherits'".to_string(),
				),
			},
			// Generator-only (`shcl init`); validation ignores both. First
			// occurrence wins (a merged schema could have two).
			"desc" => {
				// The comment is prose, so an array's elements are all taken,
				// kept as written.
				if c.desc.is_none() {
					c.desc = match &kid.value {
						Value::Cell(_) | Value::Array(_) => Some(
							elements_of(&kid.value)
								.iter()
								.map(|e| e.text.clone())
								.collect::<Vec<_>>()
								.join(", "),
						),
						Value::Empty | Value::Raw(_) => None,
					};
				}
			}
			"default" => {
				if c.default_text.is_none() {
					c.default_text = emit_value_inline(&kid.value);
					default_at = Some(k);
				}
			}
			other => vdiag(
				faults,
				kid.line,
				"V090",
				format!("unknown schema key '{}'", diag_name(other)),
			),
		}
	}
	c.required = required.unwrap_or(false);
	// A raw block has no inline spelling, so a `default` that is one cannot
	// reach a generated line - it used to be dropped and the field emitted with
	// no value at all - and a `default` under `type: raw` goes out inline and
	// then fails its own type check.
	if let Some(dk) = default_at {
		let kid = &schema.arena[dk];
		let raw_default = matches!(kid.value, Value::Raw(_));
		let raw_typed = c.ty.as_deref().is_some_and(|t| t == "raw");
		if raw_default || (raw_typed && c.default_text.is_some()) {
			vdiag(
				faults,
				kid.line,
				"V092",
				"bad schema constraint 'default'".to_string(),
			);
		}
	}
	let base =
		c.ty.as_deref()
			.map(|t| t.strip_suffix("-array").unwrap_or(t))
			.unwrap_or("string");
	// `unit` and `decimal` belong to the types that read a bare number in
	// one, and a unit has to be one that type takes.
	if let Some(u) = unit_at {
		let kid = &schema.arena[u];
		let text = single_text(&kid.value).unwrap_or_default();
		match base {
			"duration" => c.unit_d = DurationUnit::from_spelling(&text),
			"size" => c.unit_s = SizeUnit::from_spelling(&text),
			_ => {}
		}
		if c.unit_d.is_none() && c.unit_s.is_none() {
			vdiag(
				faults,
				kid.line,
				"V092",
				"bad schema constraint 'unit'".to_string(),
			);
		}
	}
	if let Some(d) = decimal_at_key
		&& base != "size"
	{
		vdiag(
			faults,
			schema.arena[d].line,
			"V092",
			"bad schema constraint 'decimal'".to_string(),
		);
		c.decimal = false;
	}
	// A duration or size bound is read the way the document's value is: its
	// own unit, then the field name's, then the schema's `unit`. A path that
	// ends in `*` has no one name to give it.
	let name = c
		.segs
		.last()
		.filter(|seg| !seg.star)
		.map_or("", |seg| seg.name.as_str());
	let quantity = |e: &Element| -> Option<i64> {
		match base {
			"duration" => {
				let bare = name_unit(name, &DURATION_NAMES).or(c.unit_d);
				parse_duration_text(&e.text, bare).map(|(v, _)| v)
			}
			"size" => {
				let bare = name_unit(name, &SIZE_NAMES).or(c.unit_s);
				parse_size_text(&e.text, bare, c.decimal).map(|(v, _)| v)
			}
			_ => None,
		}
	};
	if let Some(a) = allowed_at {
		let kid = &schema.arena[a];
		// allowed_at is only ever set for a scalar or an array.
		let els = elements_of(&kid.value);
		// Schema values are read at Standard; only the document's values
		// coerce at the document's strictness.
		let set = match base {
			"int" => els
				.iter()
				.map(|e| parse_int_text(e, Strictness::Standard))
				.collect::<Option<Vec<_>>>()
				.map(AllowedSet::Ints),
			"float" => els
				.iter()
				.map(|e| parse_float_text(e, Strictness::Standard))
				.collect::<Option<Vec<_>>>()
				.map(AllowedSet::Floats),
			"bool" => els
				.iter()
				.map(|e| parse_bool_text(&e.text, Strictness::Standard))
				.collect::<Option<Vec<_>>>()
				.map(AllowedSet::Bools),
			"datetime" => els
				.iter()
				.map(|e| parse_datetime(&e.text))
				.collect::<Option<Vec<_>>>()
				.map(AllowedSet::Dates),
			// A raw body has no element space to enumerate, and a duration
			// or size is bounded with min and max rather than listed.
			"raw" | "duration" | "size" => None,
			_ => Some(AllowedSet::Strings(
				els.iter().map(|e| e.text.clone()).collect(),
			)),
		};
		match set {
			Some(s) => c.allowed = Some(s),
			None => vdiag(
				faults,
				kid.line,
				"V092",
				"bad schema constraint 'allowed'".to_string(),
			),
		}
	}
	for (at, is_min) in [(min_at, true), (max_at, false)] {
		let Some(m) = at else { continue };
		let kid = &schema.arena[m];
		// min/max is only ever a scalar; if that invariant slips, skip the
		// constraint rather than abort the consumer.
		let Value::Cell(el) = &kid.value else {
			continue;
		};
		let key = if is_min { "min" } else { "max" };
		match base {
			"int" => match parse_int_text(el, Strictness::Standard) {
				Some(v) if is_min => c.min_i = Some(v),
				Some(v) => c.max_i = Some(v),
				None => vdiag(
					faults,
					kid.line,
					"V092",
					format!("bad schema constraint '{}'", key),
				),
			},
			"float" => match parse_float_text(el, Strictness::Standard) {
				Some(v) if is_min => c.min_f = Some(v),
				Some(v) => c.max_f = Some(v),
				None => vdiag(
					faults,
					kid.line,
					"V092",
					format!("bad schema constraint '{}'", key),
				),
			},
			"duration" | "size" => match quantity(el) {
				Some(v) if is_min => {
					c.min_i = Some(v);
					c.bound_text.0 = Some(el.text.clone());
				}
				Some(v) => {
					c.max_i = Some(v);
					c.bound_text.1 = Some(el.text.clone());
				}
				None => vdiag(
					faults,
					kid.line,
					"V092",
					format!("bad schema constraint '{}'", key),
				),
			},
			_ => vdiag(
				faults,
				kid.line,
				"V092",
				format!("bad schema constraint '{}'", key),
			),
		}
	}
	// A lower bound above the upper one admits nothing, so every value fails
	// twice and the schema, not the config, is what has to change. Reported at
	// the `max` line, which is the one a reader has to look at with `min`.
	let crossed = matches!((c.min_i, c.max_i), (Some(lo), Some(hi)) if lo > hi)
		|| matches!((c.min_f, c.max_f), (Some(lo), Some(hi)) if lo > hi);
	if crossed {
		vdiag(
			faults,
			max_at.map_or(schema.arena[f].line, |m| schema.arena[m].line),
			"V092",
			"bad schema constraint 'max'".to_string(),
		);
		// The range goes, not the field: a key-level fault keeps its entry, so
		// the path still legalizes its name chain for the unknown-field sweep,
		// and the document is not told off twice per value for a range it
		// could never have satisfied.
		c.min_i = None;
		c.max_i = None;
		c.min_f = None;
		c.max_f = None;
		c.bound_text = (None, None);
	}
	Some(c)
}

/// A schema `default`/`allowed` value re-emitted as an inline value (minimal
/// quoting, an array in brackets). None for empty or raw - neither has a
/// usable one-line form. Used by the generator, not the validator.
fn emit_value_inline(v: &Value) -> Option<String> {
	emit_value_text(v)
}

// ---------------------------------------------------------------------------
// Schema-driven generation: a schema + the Writer -> a commented starter config.
// ---------------------------------------------------------------------------

fn allowed_join(a: &AllowedSet) -> String {
	match a {
		AllowedSet::Ints(v) => v
			.iter()
			.map(|x| x.to_string())
			.collect::<Vec<_>>()
			.join(", "),
		AllowedSet::Floats(v) => v
			.iter()
			.map(|x| format_float(*x))
			.collect::<Vec<_>>()
			.join(", "),
		AllowedSet::Bools(v) => v
			.iter()
			.map(|x| if *x { "true" } else { "false" }.to_string())
			.collect::<Vec<_>>()
			.join(", "),
		AllowedSet::Dates(v) => v
			.iter()
			.map(|x| x.to_string())
			.collect::<Vec<_>>()
			.join(", "),
		AllowedSet::Strings(v) => v.join(", "),
	}
}

/// The `# type, ...` annotation line summarizing a constraint, ASCII only.
fn gen_annotation(c: &Constraint, tyname: &str) -> String {
	let mut parts: Vec<String> = vec![tyname.to_string()];
	if let Some(u) = c.unit_d {
		parts[0] = format!("{} in {}", tyname, u.spelling());
	} else if let Some(u) = c.unit_s {
		parts[0] = format!("{} in {}", tyname, u.spelling());
	}
	if c.decimal {
		parts.push("KB to TB in powers of 1000".to_string());
	}
	if let Some(a) = &c.allowed {
		parts.push(format!("one of: {}", allowed_join(a)));
	}
	// The bounds are their own part of the annotation line, not an alternative
	// to `allowed`. A field can have both, and the validator enforces both.
	// A duration or size bound reads the way the schema wrote it.
	if c.bound_text.0.is_some() || c.bound_text.1.is_some() {
		parts.push(match &c.bound_text {
			(Some(lo), Some(hi)) => format!("{}-{}", lo, hi),
			(Some(lo), None) => format!(">= {}", lo),
			(None, Some(hi)) => format!("<= {}", hi),
			(None, None) => String::new(), // guarded above; keep the map total
		});
	} else if c.min_i.is_some() || c.max_i.is_some() {
		parts.push(match (c.min_i, c.max_i) {
			(Some(lo), Some(hi)) => format!("{}-{}", lo, hi),
			(Some(lo), None) => format!(">= {}", lo),
			(None, Some(hi)) => format!("<= {}", hi),
			(None, None) => String::new(), // guarded above; keep the map total
		});
	} else if c.min_f.is_some() || c.max_f.is_some() {
		parts.push(match (c.min_f, c.max_f) {
			(Some(lo), Some(hi)) => format!("{}-{}", format_float(lo), format_float(hi)),
			(Some(lo), None) => format!(">= {}", format_float(lo)),
			(None, Some(hi)) => format!("<= {}", format_float(hi)),
			(None, None) => String::new(), // guarded above; keep the map total
		});
	}
	if let Some((lo, hi)) = c.repeat {
		parts.push(if lo == hi {
			format!("repeat {}", lo)
		} else {
			format!("repeat {}-{}", lo, hi)
		});
	}
	if c.required {
		parts.push("required".to_string());
	}
	parts.join(", ")
}

/// A default with a literal newline cannot sit on a value line; the quoted
/// escaped spelling reads back to the same string.
fn gen_default_text(v: &str) -> String {
	if !v.contains('\n') {
		return v.to_string();
	}
	quote_text(v)
}

/// Whether a V007 from the self-check is the sanctioned kind: its message
/// ends `: N not in LO..HI`, and LO is 2 or more.
fn v007_sanctioned(message: &str) -> bool {
	message
		.rsplit(" not in ")
		.next()
		.and_then(|range| range.split("..").next())
		.and_then(|lo| lo.parse::<u64>().ok())
		.is_some_and(|lo| lo >= 2)
}

/// Emit a commented, typed starter config from a schema (`shcl init --schema`).
/// Paths that must exist (required, or a repeat lower bound of 1+) are live
/// (their `default`, or an empty value); optional paths are commented out so
/// the file is valid and minimal as-is. Prose the generator writes is `##`
/// and a commented-out setting is `# `, so the two read apart; both are
/// ordinary comments to the language, and nothing reads them back. A must-exist wildcard path whose
/// parent gets materialized by another live line is generated too, in dotted
/// form - otherwise the file would fail the very schema that produced it -
/// and remaining wildcard or `[#N]` paths (which cannot be materialized) are
/// listed in a trailing comment block. A path whose last segment selects by
/// value is written without that selector when it has a `default`, since a
/// value after the selector would be ignored: `env[prod]` with `default: prod`
/// is `env: prod`. The output always loads clean and
/// validates clean against its schema, except a repeat lower bound of 2+
/// (identical generated lines would merge, so the shortfall is reported).
/// The promise is checked against the finished text, both its load and its
/// validation, so a line that does not load, or a schema whose own `default`
/// breaks its field's constraints, is a fault (`V097`) instead of a starter
/// config that fails the first time it is checked.
/// A footer naming the format and pointing at the spec is written last unless
/// `no_banner`; the flag is negative so leaving it alone writes the footer.
/// Err = schema faults (V09x), same as `validate`/`check --schema`.
pub fn generate(schema: &Document, no_banner: bool) -> Result<String, Vec<Diagnostic>> {
	// Generation lays the whole schema out, so unlike validation it has no
	// safe partial mode: any fault fails it.
	let (def, faults) = build_schema(schema);
	if !faults.is_empty() {
		return Err(faults);
	}
	let (cons, cuts) = expand_mounts(&def);
	if cons.len() > GEN_MAX_FIELDS {
		return Err(vec![Diagnostic {
			line: 0,
			severity: Severity::Error,
			code: "V096",
			message: format!(
				"schema expands past {} fields; fragments mounted at more than one path multiply",
				GEN_MAX_FIELDS
			),
		}]);
	}
	let must_exist = |c: &Constraint| c.required || matches!(c.repeat, Some((lo, _)) if lo >= 1);
	let has_wild = |c: &Constraint| {
		c.segs
			.iter()
			.any(|s| matches!(s.selector, Some(Selector::Wildcard)))
	};
	// `[#N]` needs a pre-existing instance and its `#` would start a comment on
	// a binding line. A path deeper than a document may nest cannot be generated
	// either: the line would draw E016 on the way back in. A newline in a name
	// or a by-value selector is writable, since both are written escaped.
	// The reason doubles as the predicate, so the refusal below can never name a
	// path for a reason generation did not act on.
	let why_unwritable = |c: &Constraint| -> &'static str {
		if c.segs.len() > MAX_DEPTH {
			return "nests past the depth cap";
		}
		for s in &c.segs {
			if matches!(s.selector, Some(Selector::ByIndex(_))) {
				return "a [#N] selector needs an instance that does not exist yet";
			}
			if s.star {
				return "a * name segment has no name to write";
			}
		}
		""
	};
	let unwritable = |c: &Constraint| !why_unwritable(c).is_empty();
	// Live concrete paths materialize instances; decide which must-exist
	// wildcards get filled (their first-wildcard parent chain is a prefix of
	// some live path). Fixpoint: a fill can materialize another's parent.
	let mut live: Vec<Vec<&str>> = cons
		.iter()
		.filter(|c| !has_wild(c) && !unwritable(c) && must_exist(c))
		.map(|c| names_of(&c.segs))
		.collect();
	let mut fill = vec![false; cons.len()];
	loop {
		let mut changed = false;
		for (i, c) in cons.iter().enumerate() {
			if fill[i] || !has_wild(c) || unwritable(c) || !must_exist(c) {
				continue;
			}
			let Some(k) = c
				.segs
				.iter()
				.position(|s| matches!(s.selector, Some(Selector::Wildcard)))
			else {
				continue;
			};
			let parent = names_of(&c.segs[..k + 1]);
			// A wildcard in the last segment needs no other line to
			// materialize its parent: the line generated from it is that
			// instance.
			if k + 1 == c.segs.len()
				|| live
					.iter()
					.any(|p| p.len() >= parent.len() && p[..parent.len()] == parent[..])
			{
				fill[i] = true;
				live.push(names_of(&c.segs));
				changed = true;
			}
		}
		if !changed {
			break;
		}
	}
	// A live line with a value materializes an instance with that value,
	// and a dotted child names the empty-valued instance instead - so `srv:
	// web` followed by `srv.port:` is two `srv` nodes, and the child never
	// ends up where the schema looks. Any line under such a parent selects it
	// by its value: `srv[web].port:`.
	// A filled wildcard emits a valued line of its own, so it belongs here too.
	// First wins, as the line it selects does: of two lines on one path the
	// first spelling is the one written, and its value is the instance.
	let mut parent_values: HashMap<Vec<&str>, &str> = HashMap::new();
	for (i, c) in cons.iter().enumerate() {
		if (!has_wild(c) || fill[i])
			&& !unwritable(c)
			&& must_exist(c)
			&& let Some(d) = c.default_text.as_deref()
		{
			parent_values.entry(names_of(&c.segs)).or_insert(d);
		}
	}
	// A commented line under a commented valued parent has the same problem
	// once both are uncommented, so it selects the parent's default too. A
	// live line keeps the dotted form under a commented parent: selecting by
	// value would make the optional parent exist.
	let mut commented_values = parent_values.clone();
	for c in &cons {
		if !has_wild(c)
			&& !unwritable(c)
			&& !must_exist(c)
			&& let Some(d) = c.default_text.as_deref()
		{
			commented_values.entry(names_of(&c.segs)).or_insert(d);
		}
	}
	// A path that cannot be written at all belongs in the trailing note, but one
	// that must exist can never be satisfied from there: the self-check would
	// then report the document as missing a path, which points at the config
	// rather than at the schema line that cannot be generated.
	// A repeat lower bound of 2 or more is the one documented shortfall - the
	// line is emitted once and the count reported - so it is not this fault.
	// Every such path is named, not just the first: fixing one only to be
	// refused over the next tells nobody how much is wrong.
	let cannot_satisfy =
		|c: &Constraint| c.required || matches!(c.repeat, Some((lo, _)) if lo == 1);
	let blocked: Vec<Diagnostic> = cons
		.iter()
		.filter(|c| cannot_satisfy(c) && unwritable(c) && !has_wild(c))
		.map(|c| Diagnostic {
			line: 0,
			severity: Severity::Error,
			code: "V097",
			message: format!(
				"required path cannot be generated: {} ({})",
				schema_text(&c.path),
				why_unwritable(c)
			),
		})
		.collect();
	if !blocked.is_empty() {
		return Err(blocked);
	}
	let mut wild: Vec<(String, String)> = Vec::new();
	// Dropping a trailing `[*]` can render the same line a concrete sibling
	// already wrote; the first spelling wins. A line from a dropped `[value]`
	// selector is its own instance, so two of them with different values are
	// both written: `env[prod]` and `env[dev]` are two `env` lines. Each path
	// maps to None once a plain line wrote it, or to the values written so far.
	let mut emitted: HashMap<String, Option<HashSet<String>>> = HashMap::new();
	// A child whose valued parent has no selector spelling cannot be written.
	let mut unspellable: Vec<Diagnostic> = Vec::new();
	// One block per generated line - its desc, annotation and binding - with
	// the path's names, so the blocks can be laid out in tree order below.
	let mut blocks: Vec<(Vec<String>, String)> = Vec::new();
	// An optional field's line goes out commented, with the constraint it came
	// from, since the self-check below cannot see a comment.
	let mut commented: Vec<(usize, String)> = Vec::new();
	for (i, c) in cons.iter().enumerate() {
		let tyname = c.ty.clone().unwrap_or_else(|| "any".to_string());
		if unwritable(c) || (has_wild(c) && !fill[i]) {
			wild.push((schema_text(&c.path), tyname));
			continue;
		}
		// A filled wildcard emits in dotted form, targeting the materialized
		// instance - by its value when the materializing line has one.
		// Rebuilt from the parsed segments, not by cutting text out of the
		// path: the same path can be written several ways, and only the
		// segments say what it means. Otherwise the schema's own spelling.
		let values = if must_exist(c) {
			&parent_values
		} else {
			&commented_values
		};
		let under_valued_parent = (1..c.segs.len()).any(|k| {
			c.segs[k - 1].selector.is_none() && values.contains_key(&names_of(&c.segs[..k]))
		});
		// A name with a newline has no verbatim spelling on a binding line;
		// the segment renderer escapes it, so such a path goes through there
		// whether or not it was filled.
		// A value after a last-segment selector is ignored, so a default there
		// goes on the bare path: the line materializes the instance, and
		// validation below decides whether the default names the one selected.
		let selects_by_value = c.default_text.is_some()
			&& matches!(
				c.segs.last().and_then(|s| s.selector.as_ref()),
				Some(Selector::ByValue { .. })
			);
		// The schema's own spelling is kept when a file line reads it back as
		// the same path. A selector body holding a `#` is fine in a lookup and
		// opens a comment on a file line, so that one goes through the renderer.
		let path = if selects_by_value {
			let mut segs = c.segs.clone();
			if let Some(last) = segs.last_mut() {
				last.selector = None;
			}
			gen_path_text(&segs, values)
		} else if fill[i] || under_valued_parent || !path_reads_back(&c.path, &c.segs) {
			gen_path_text(&c.segs, values)
		} else {
			Some(c.path.clone())
		};
		let Some(path) = path else {
			unspellable.push(Diagnostic {
				line: 0,
				severity: Severity::Error,
				code: "V097",
				message: format!(
					"required path cannot be generated: {} (its parent's value has no selector spelling)",
					schema_text(&c.path)
				),
			});
			continue;
		};
		let dup = match (emitted.get_mut(&path), selects_by_value) {
			(None, _) => {
				let first = selects_by_value
					.then(|| HashSet::from([c.default_text.clone().unwrap_or_default()]));
				emitted.insert(path.clone(), first);
				false
			}
			(Some(Some(vals)), true) => !vals.insert(c.default_text.clone().unwrap_or_default()),
			(Some(_), _) => true,
		};
		if dup {
			continue;
		}
		let mut block = String::new();
		if let Some(d) = &c.desc {
			for line in d.split('\n') {
				block.push_str(if line.is_empty() { "##" } else { "## " });
				block.push_str(line);
				block.push('\n');
			}
		}
		block.push_str("## ");
		// The annotation is a comment: a newline smuggled in via an allowed
		// string value must not break out of it.
		block.push_str(&schema_text(&gen_annotation(c, &tyname)));
		block.push('\n');
		let prefix = if must_exist(c) { "" } else { "# " };
		match &c.default_text {
			Some(v) => {
				let line = format!("{}: {}\n", path, gen_default_text(v));
				block.push_str(prefix);
				block.push_str(&line);
				if !must_exist(c) {
					commented.push((i, line));
				}
			}
			None => {
				let line = format!("{}:\n", path);
				block.push_str(prefix);
				block.push_str(&line);
				if !must_exist(c) {
					commented.push((i, line));
				}
			}
		}
		let names: Vec<String> = names_of(&c.segs).iter().map(|s| s.to_string()).collect();
		blocks.push((names, block));
	}
	// Tree order, first appearance first. A schema may list `a.host.srv`
	// before `a`, and emitted as listed with another field between them,
	// `a: x` re-opens `a` and the load hints it (H002) - in the one file meant
	// to show the format at its cleanest. Every prefix is ranked by where it
	// first appears, so a parent's block comes before its children's, siblings
	// keep schema order, and a schema already in tree order is unchanged.
	let mut rank: HashMap<&[String], usize> = HashMap::new();
	for (names, _) in &blocks {
		for k in 1..=names.len() {
			let next = rank.len();
			rank.entry(&names[..k]).or_insert(next);
		}
	}
	// A parent's key is a prefix of its children's, and a shorter key sorts
	// first; the sort is stable, so two blocks on one path keep their order.
	let mut order: Vec<usize> = (0..blocks.len()).collect();
	order.sort_by_cached_key(|&i| {
		let names = &blocks[i].0;
		(1..=names.len())
			.map(|k| rank[&names[..k]])
			.collect::<Vec<usize>>()
	});
	let mut out = String::new();
	for (n, &i) in order.iter().enumerate() {
		if n > 0 {
			out.push('\n');
		}
		out.push_str(&blocks[i].1);
	}
	// Cycle-cut mounts last: their "type" column names the fragment that
	// belongs at the path.
	wild.extend(cuts);
	if !wild.is_empty() {
		if !blocks.is_empty() {
			out.push('\n');
		}
		out.push_str("## Paths needing an instance name (not generated):\n");
		for (p, t) in &wild {
			out.push_str(&format!("##   {}   {}\n", p, t));
		}
	}
	if !unspellable.is_empty() {
		return Err(unspellable);
	}
	if !no_banner {
		if !out.is_empty() {
			out.push('\n');
		}
		out.push_str(GEN_BANNER);
	}
	// The output promises to validate clean against the schema that produced
	// it, so check that here rather than trusting each branch above. A
	// `default` outside its own field's constraints is the schema's fault, and
	// the author should hear about it instead of getting a starter config that
	// fails the first time it is checked. The one sanctioned shortfall is a
	// V007 for a repeat lower bound of 2+: generating that many identical
	// lines merges them into one. A lower bound of 1 is a must-exist path
	// like any other, so its V007 is a fault.
	// The load comes first, in the order `check --schema` prints: a line that
	// does not load is refused even when validation happens to pass without it.
	let gdoc = Document::parse(&out);
	let mut bad: Vec<Diagnostic> = gdoc
		.diagnostics()
		.iter()
		.filter(|d| d.severity == Severity::Error)
		.map(|d| Diagnostic {
			line: 0,
			severity: Severity::Error,
			code: "V097",
			message: format!("generated text does not load: {} {}", d.code, d.message),
		})
		.chain(
			gdoc.validate(schema)
				.into_iter()
				.filter(|d| {
					d.severity == Severity::Error
						&& !(d.code == "V007" && v007_sanctioned(&d.message))
				})
				.map(|d| Diagnostic {
					line: 0,
					severity: Severity::Error,
					code: "V097",
					message: format!(
						"generated value fails the schema that produced it: {}",
						d.message
					),
				}),
		)
		.collect();
	// A commented default fails the same check once someone uncomments it. Each
	// line is read back alone and only its value is checked: uncommenting every
	// line at once would pair a valued parent with a dotted child, which names
	// a second instance, and fault a schema whose lines each work. The value is
	// found through the field's own path, the way validation finds it, so a
	// default naming another instance than the path selects is caught here
	// as it is for a required field.
	for (i, line) in &commented {
		let one = Document::parse(line);
		bad.extend(
			one.diagnostics()
				.iter()
				.filter(|d| d.severity == Severity::Error)
				.map(|d| Diagnostic {
					line: 0,
					severity: Severity::Error,
					code: "V097",
					message: format!("generated text does not load: {} {}", d.code, d.message),
				}),
		);
		if one.arena[ROOT].children.is_empty() {
			continue;
		}
		let mut ctxs: Vec<(usize, Vec<usize>)> = Vec::new();
		one.v_contexts(vec![ROOT], &cons[*i].segs, 0, &mut ctxs);
		let nodes: Vec<usize> = ctxs.into_iter().flat_map(|(_, f)| f).collect();
		if nodes.is_empty() {
			bad.push(Diagnostic {
				line: 0,
				severity: Severity::Error,
				code: "V097",
				message: format!(
					"generated value fails the schema that produced it: default does not name the instance its path selects: {}",
					schema_text(&cons[*i].path)
				),
			});
			continue;
		}
		let mut found = Vec::new();
		for n in nodes {
			one.v_node(&cons[*i], n, &mut found);
		}
		bad.extend(
			found
				.into_iter()
				.filter(|d| d.severity == Severity::Error)
				.map(|d| Diagnostic {
					line: 0,
					severity: Severity::Error,
					code: "V097",
					message: format!(
						"generated value fails the schema that produced it: {}",
						d.message
					),
				}),
		);
	}
	if !bad.is_empty() {
		return Err(bad);
	}
	Ok(out)
}

/// Ceiling on how many fields one schema may expand to. Fragments that mount
/// each other at more than one path multiply, so a short schema can otherwise
/// ask for more output than the machine can hold; past this the generator
/// reports a schema fault rather than running until something breaks.
const GEN_MAX_FIELDS: usize = 10_000;

/// Footer telling whoever opens the generated file what the format is and
/// where its spec lives. It is output, so every binding emits these bytes
/// exactly; the Legal line names SHCL as its subject so it cannot be read as
/// a claim over the config it sits in. Public because a program that creates
/// a config file of its own writes the same block, and a second copy of a
/// byte-for-byte contract drifts.
pub const GEN_BANNER: &str = "\
##
## This config file format is SHCL.
## \"Simple Hierarchical Config Language\"
##    Format   3
##    Home     https://github.com/yottacore/shcl
##    Syntax   https://github.com/yottacore/shcl/blob/v3.0.0-beta1/project/spec.md
##    Legal    SHCL is Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]. License: MIT. No warranty.
##
";

/// The info block's first two text lines. `set_banner` finds an old block by
/// the first, which no release has worded differently.
const BANNER_TITLE: &str = "## This config file format is SHCL.";
const BANNER_NAME: &str = "## \"Simple Hierarchical Config Language\"";

/// The format major the info block names. Bumped with the format, not with the
/// crate: a file says which rule set it was written for, and nothing else.
/// The banner's Syntax link names the tag that opened this major, and moves
/// with it.
pub const FORMAT_MAJOR: u32 = 3;

/// The start of the block's version line, up to the number. `migrate` matches
/// on this and reads the digits after it, so a later major can still tell an
/// older file from one of its own.
pub const FORMAT_LINE_HEAD: &str = "##    Format   ";

/// The whole version line, as the block has it. A program writing a config
/// of its own emits `GEN_BANNER`, which includes this; `migrate` appends this
/// line on its own to a file it rewrote, since that file has no block to add
/// it to and inventing one would write bytes the document does not hold.
pub const FORMAT_LINE: &str = "##    Format   3";

/// The start of a line naming the file's schema, written like the Format line,
/// for `check` and for editors: `##    Schema   ./app.schema.shcl`.
pub const SCHEMA_LINE_HEAD: &str = "##    Schema   ";

/// Written under `FORMAT_LINE` on a file `migrate` actually changed. It is a
/// note for whoever opens the file; nothing reads it back.
pub const MIGRATED_LINE: &str = "##    Migrated from SHCL 2.x.";

/// Render parsed segments back as a dotted path, dropping wildcard selectors
/// (a generated line targets the one instance it materializes) and quoting a
/// name that needs it, so the result is a path the scanner reads back the same.
/// A segment whose prefix names a live line with a value selects that
/// instance by the value, in place of a wildcard or a bare name. None when a
/// selector has no spelling a file line reads back.
fn gen_path_text(segs: &[Segment], parent_values: &HashMap<Vec<&str>, &str>) -> Option<String> {
	let mut out = String::new();
	for (i, s) in segs.iter().enumerate() {
		if i > 0 {
			out.push('.');
		}
		if s.star {
			out.push('*');
		} else {
			out.push_str(&emit_name(&s.name));
		}
		if i + 1 < segs.len()
			&& !matches!(s.selector, Some(Selector::ByValue { .. }))
			&& let Some(v) = parent_values.get(&names_of(&segs[..=i]))
		{
			out.push('[');
			out.push_str(&gen_selector_text(v)?);
			out.push(']');
			continue;
		}
		match &s.selector {
			Some(Selector::ByValue { text, quoted }) => {
				// The body as the schema meant it: a quoted one stays quoted,
				// and a bare one goes bare when a file line reads it back.
				let quoted_body = quote_text(text);
				let body = if !*quoted && selector_reads_back(text, text, false) {
					text.clone()
				} else if selector_reads_back(&quoted_body, text, true) {
					quoted_body
				} else {
					return None;
				};
				out.push('[');
				out.push_str(&body);
				out.push(']');
			}
			Some(Selector::ByIndex(k)) => {
				out.push_str(&format!("[#{}]", k));
			}
			Some(Selector::Wildcard) | None => {}
		}
	}
	Some(out)
}

/// The selector body that picks out the instance a line `name: v` makes, or
/// None when no body can. It is built from the elements the reader takes out
/// of that line's value, and each candidate is scanned back the way a file
/// line is scanned, so none of the scanner's rules is copied here to go stale.
/// That copy was the cause twice: an all-digit body past 64 bits, and a
/// quoted array element written as the body. One element tries the spelling
/// it was written in first; an array has only the bare body, since a quoted
/// selector matches one element only, and a bare one the elements joined.
fn gen_selector_text(v: &str) -> Option<String> {
	let spelled = gen_default_text(v);
	let mut tok = Tokens::default();
	tokenize_value(&spelled, 0, Rules::Current, &mut tok);
	let els: Vec<String> = tok
		.elements
		.iter()
		.map(|p| piece_text(p, &spelled))
		.collect();
	let display = els.join(", ");
	let mut tries: Vec<(String, &str, bool)> = Vec::new();
	if let [only] = tok.elements.as_slice() {
		if matches!(only.quote, Quote::Single | Quote::Double) {
			tries.push((spelled[tok.value.0..tok.value.1].to_string(), &els[0], true));
		}
		tries.push((display.clone(), &display, false));
		tries.push((quote_text(&els[0]), &els[0], true));
	} else {
		tries.push((display.clone(), &display, false));
	}
	tries
		.into_iter()
		.find(|(body, text, quoted)| selector_reads_back(body, text, *quoted))
		.map(|(body, _, _)| body)
}

/// Whether `body` between brackets on a file line reads back as a value
/// selector for `text`, quoted or bare as asked.
fn selector_reads_back(body: &str, text: &str, quoted: bool) -> bool {
	let line = format!("x[{}]:", body);
	// The tokenizer reads one line and never sees a line end, so text with a
	// real line break would read back here and then be written across two lines,
	// which is not the same path. A file line cannot hold one, so refuse and let
	// the escaped spelling be tried instead.
	if line.contains('\n') || line.contains('\r') {
		return false;
	}
	let mut tok = Tokens::default();
	tokenize(&line, b':', false, Rules::Current, &mut tok);
	if tok.comment.is_some() || tok.misspelled.is_some() || path_fault(&tok, &line).is_some() {
		return false;
	}
	path_of(&tok, &line).is_ok_and(|p| {
		matches!(p.segments.as_slice(), [seg] if seg.selector
			== Some(Selector::ByValue { text: text.to_string(), quoted }))
	})
}

/// Whether a schema path written on a file line reads back as the same
/// segments. A lookup path takes spellings a file line does not.
fn path_reads_back(path: &str, segs: &[Segment]) -> bool {
	let line = format!("{}:", path);
	// The tokenizer reads one line and never sees a line end, so text with a
	// real line break would read back here and then be written across two lines,
	// which is not the same path. A file line cannot hold one, so refuse and let
	// the escaped spelling be tried instead.
	if line.contains('\n') || line.contains('\r') {
		return false;
	}
	let mut tok = Tokens::default();
	tokenize(&line, b':', false, Rules::Current, &mut tok);
	if tok.comment.is_some() || tok.misspelled.is_some() || path_fault(&tok, &line).is_some() {
		return false;
	}
	path_of(&tok, &line).is_ok_and(|p| {
		p.segments.len() == segs.len()
			&& p.segments
				.iter()
				.zip(segs)
				.all(|(a, b)| a.name == b.name && a.star == b.star && a.selector == b.selector)
	})
}

fn names_of(segs: &[Segment]) -> Vec<&str> {
	segs.iter().map(|s| s.name.as_str()).collect()
}

/// Inline every fragment mount into a flat constraint list, depth-first in
/// schema order, each field's path and segments prefixed by its mount's. A
/// mount whose fragment is already expanding (a cycle) stops there and is
/// returned as (path, fragment name) for the trailing not-generated block.
fn expand_mounts(def: &SchemaDef) -> (Vec<Constraint>, Vec<(String, String)>) {
	fn go(
		list: &[Constraint],
		def: &SchemaDef,
		at: Option<(&str, &[Segment])>,
		stack: &mut Vec<String>,
		out: &mut Vec<Constraint>,
		cuts: &mut Vec<(String, String)>,
	) {
		for c in list {
			let mut cc = c.clone();
			if let Some((p, s)) = at {
				cc.path = format!("{}.{}", p, c.path);
				let mut segs = s.to_vec();
				segs.extend(c.segs.iter().cloned());
				cc.segs = segs;
			}
			let path = cc.path.clone();
			let segs = cc.segs.clone();
			if out.len() > GEN_MAX_FIELDS {
				return;
			}
			out.push(cc);
			if let Some(fr) = &c.inherits {
				// A chain long enough to outrun the stack, or a mount that
				// re-enters, stops here and is noted instead of expanded.
				if stack.iter().any(|x| x == fr) || stack.len() >= MAX_DEPTH {
					cuts.push((schema_text(&path), schema_text(fr)));
				} else if let Some(fcs) = def.frags.get(fr) {
					stack.push(fr.clone());
					go(fcs, def, Some((&path, &segs)), stack, out, cuts);
					stack.pop();
				}
			}
		}
	}
	let mut out: Vec<Constraint> = Vec::new();
	let mut cuts: Vec<(String, String)> = Vec::new();
	let mut stack: Vec<String> = Vec::new();
	go(&def.cons, def, None, &mut stack, &mut out, &mut cuts);
	(out, cuts)
}

/// Levenshtein distance capped at `cap`, for the "did you mean" prose (never
/// the code): anything past the cap comes back as `cap + 1`. Only the band
/// `|i - j| <= cap` of the table is computed, so a pair costs linear time in
/// the names' length, and a length gap past the cap needs no table at all.
fn edit_distance(a: &str, b: &str, cap: usize) -> usize {
	let a: Vec<char> = a.chars().collect();
	let b: Vec<char> = b.chars().collect();
	let inf = cap + 1;
	if a.len().abs_diff(b.len()) > cap {
		return inf;
	}
	let mut prev: Vec<usize> = (0..=b.len()).map(|j| j.min(inf)).collect();
	let mut cur = vec![inf; b.len() + 1];
	for i in 1..=a.len() {
		cur[0] = i.min(inf);
		let lo = i.saturating_sub(cap).max(1);
		let hi = (i + cap).min(b.len());
		if lo > 1 {
			cur[lo - 1] = inf;
		}
		let mut row_min = cur[0];
		for j in lo..=hi {
			let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 };
			cur[j] = (prev[j] + 1)
				.min(cur[j - 1] + 1)
				.min(prev[j - 1] + cost)
				.min(inf);
			row_min = row_min.min(cur[j]);
		}
		if hi < b.len() {
			cur[hi + 1] = inf;
		}
		// No cell in a later row can come back under this row's minimum.
		if row_min > cap {
			return inf;
		}
		std::mem::swap(&mut prev, &mut cur);
	}
	prev[b.len()]
}

impl Document {
	/// Validate this document against a schema document (itself plain SHCL -
	/// spec.md "Schema validation"). Empty result = the document conforms.
	/// Diagnostic lines are document lines (0 = document scope); schema faults
	/// (V09x, schema-file lines) come first, and the surviving constraints
	/// still check the document. The unknown-field sweep runs too, unless a
	/// fault cost the schema a path spelling (an unreadable `field:` path, or
	/// a mount naming no declared fragment) - only those can turn declared
	/// fields into false unknowns; a key-level fault keeps its entry's chain.
	/// The H001/H002 hints a schema disavows are NOT dropped by this call: they
	/// live on the parse's diagnostics, which validation does not touch. Parse
	/// then validate and they are still there - apply
	/// `suppress_declared_repeats`/`suppress_declared_reopens` yourself, or use
	/// `load_and_validate`, which runs both for you.
	pub fn validate(&self, schema: &Document) -> Vec<Diagnostic> {
		let (def, faults) = build_schema(schema);
		let mut out = faults;
		// One mount set for the whole schema: two top-level paths can resolve
		// to the same node and mount the same fragment there, and the spec
		// says each fragment runs once per node.
		let mut mounted = std::collections::HashSet::new();
		for c in &def.cons {
			self.v_check_from(c, &def, ROOT, 0, &mut out, &mut mounted);
		}
		if def.paths_complete {
			self.v_unknown(&def, &mut out);
		}
		out
	}

	// Resolution contexts: the whole document for a plain path; each enclosing
	// instance for the part of a path after a wildcard. required/repeat evaluate
	// per context (anchor line 0 = document scope), so `server[*].port` +
	// required means a port under EACH server - vacuously true with no servers.
	fn v_contexts(
		&self,
		start: Vec<usize>,
		segs: &[Segment],
		anchor: usize,
		out: &mut Vec<(usize, Vec<usize>)>,
	) {
		let mut cur = start;
		for (i, seg) in segs.iter().enumerate() {
			let mut next: Vec<usize> = Vec::new();
			for &n in &cur {
				if seg.star {
					next.extend(self.arena[n].children.iter().copied());
				} else {
					next.extend(self.children_named(n, &seg.name));
				}
			}
			if seg.star {
				// Name wildcard: same per-instance split as `[*]`, any child name.
				let rest = &segs[i + 1..];
				if rest.is_empty() {
					out.push((anchor, next));
				} else {
					for inst in next {
						let line = self.arena[inst].line;
						self.v_contexts(vec![inst], rest, line, out);
					}
				}
				return;
			}
			match &seg.selector {
				None => cur = next,
				Some(Selector::ByValue { text, quoted }) => {
					let want = text.as_str();
					cur = next
						.into_iter()
						.filter(|&c| {
							disp_key(&self.arena[c].value) == want
								&& (!quoted || single_scalar(&self.arena[c].value))
						})
						.collect();
				}
				Some(Selector::ByIndex(k)) => {
					cur = index_usize(*k)
						.and_then(|i| next.get(i))
						.map(|&c| vec![c])
						.unwrap_or_default();
				}
				Some(Selector::Wildcard) => {
					let rest = &segs[i + 1..];
					if rest.is_empty() {
						out.push((anchor, next));
					} else {
						for inst in next {
							let line = self.arena[inst].line;
							self.v_contexts(vec![inst], rest, line, out);
						}
					}
					return;
				}
			}
		}
		out.push((anchor, cur));
	}

	// A mounted fragment's fields run per resolved node, right after that
	// node's own checks, in fragment order - depth-first, so diagnostic order
	// stays derivable. Termination is structural: every mount descends at
	// least one document level, and the document is finite.
	fn v_check_from<'d>(
		&self,
		c: &'d Constraint,
		def: &'d SchemaDef,
		start: usize,
		anchor0: usize,
		out: &mut Vec<Diagnostic>,
		mounted: &mut std::collections::HashSet<(&'d str, usize)>,
	) {
		let mut ctxs: Vec<(usize, Vec<usize>)> = Vec::new();
		self.v_contexts(vec![start], &c.segs, anchor0, &mut ctxs);
		for (anchor, found) in &ctxs {
			if c.required && found.is_empty() {
				vdiag(
					out,
					*anchor,
					"V002",
					format!("required path missing: {}", schema_text(&c.path)),
				);
			}
			if let Some((lo, hi)) = c.repeat {
				let n = found.len() as u64;
				if n < lo || n > hi {
					vdiag(
						out,
						*anchor,
						"V007",
						format!(
							"instance count out of bounds at '{}': {} not in {}..{}",
							schema_text(&c.path),
							n,
							lo,
							hi
						),
					);
				}
			}
			for &n in found {
				self.v_node(c, n, out);
				if let Some(fr) = &c.inherits
					&& let Some(fcs) = def.frags.get(fr)
				{
					// Two constraints can resolve to the same node and mount the
					// same fragment there. The second mount would repeat the
					// first's work and its diagnostics, and repeating it per
					// level is what makes a recursive schema cost double per
					// document level, so each pair is done once.
					if mounted.insert((fr.as_str(), n)) {
						for fc in fcs {
							self.v_check_from(fc, def, n, self.arena[n].line, out, mounted);
						}
					}
				}
			}
		}
	}

	fn v_node(&self, c: &Constraint, n: usize, out: &mut Vec<Diagnostic>) {
		let node = &self.arena[n];
		let line = node.line;
		let kind = c.ty.as_deref();
		let base = kind
			.map(|t| t.strip_suffix("-array").unwrap_or(t))
			.unwrap_or("string");
		let is_array = kind.is_some_and(|t| t.ends_with("-array"));
		let wrong = |out: &mut Vec<Diagnostic>| {
			vdiag(
				out,
				line,
				"V003",
				format!(
					"wrong type at '{}': value is not a valid {}",
					schema_text(&c.path),
					kind.unwrap_or("string")
				),
			);
		};
		match &node.value {
			// Empty passes everything; required already counted it as present.
			Value::Empty => {}
			Value::Raw(r) => {
				let content = &r.content;
				// A raw block satisfies `raw` and scalar `string` (any value
				// reads as a string); every other kind is a type miss.
				if kind.is_some() && (base != "raw" && base != "string" || is_array) {
					wrong(out);
					return;
				}
				if let Some(AllowedSet::Strings(set)) = &c.allowed
					&& !set.contains(content)
				{
					vdiag(
						out,
						line,
						"V004",
						format!(
							"value not allowed at '{}': {}",
							schema_text(&c.path),
							one_line(content)
						),
					);
				}
			}
			Value::Cell(_) | Value::Array(_) => {
				let els = elements_of(&node.value);
				if base == "raw" {
					wrong(out);
					return;
				}
				// A string read of an array is its bracket form, so that is
				// the text the allowed set sees: `x: 80` and `x: [80]` are two
				// values.
				if !is_array && base == "string" && matches!(node.value, Value::Array(_)) {
					let text = node.value.display();
					if let Some(AllowedSet::Strings(set)) = &c.allowed
						&& !set.contains(&text)
					{
						vdiag(
							out,
							line,
							"V004",
							format!(
								"value not allowed at '{}': {}",
								schema_text(&c.path),
								one_line(&text)
							),
						);
					}
					return;
				}
				// A scalar kind on a multi-element value is the array-where-one-
				// scalar-expected miss.
				if !is_array && els.len() > 1 {
					wrong(out);
					return;
				}
				match base {
					"int" => {
						let parsed: Option<Vec<i64>> = els
							.iter()
							.map(|e| parse_int_text(e, self.strictness))
							.collect();
						let Some(vals) = parsed else {
							wrong(out);
							return;
						};
						if let Some(AllowedSet::Ints(set)) = &c.allowed
							&& let Some(i) = vals.iter().position(|v| !set.contains(v))
						{
							vdiag(
								out,
								line,
								"V004",
								format!(
									"value not allowed at '{}': {}",
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
						if let Some(lo) = c.min_i
							&& let Some(i) = vals.iter().position(|v| *v < lo)
						{
							vdiag(
								out,
								line,
								"V005",
								format!(
									"value below min {} at '{}': {}",
									lo,
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
						if let Some(hi) = c.max_i
							&& let Some(i) = vals.iter().position(|v| *v > hi)
						{
							vdiag(
								out,
								line,
								"V006",
								format!(
									"value above max {} at '{}': {}",
									hi,
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
					}
					"float" => {
						let parsed: Option<Vec<f64>> = els
							.iter()
							.map(|e| parse_float_text(e, self.strictness))
							.collect();
						let Some(vals) = parsed else {
							wrong(out);
							return;
						};
						if let Some(AllowedSet::Floats(set)) = &c.allowed
							&& let Some(i) = vals.iter().position(|v| !set.contains(v))
						{
							vdiag(
								out,
								line,
								"V004",
								format!(
									"value not allowed at '{}': {}",
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
						if let Some(lo) = c.min_f
							&& let Some(i) = vals.iter().position(|v| *v < lo)
						{
							vdiag(
								out,
								line,
								"V005",
								format!(
									"value below min {} at '{}': {}",
									format_float(lo),
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
						if let Some(hi) = c.max_f
							&& let Some(i) = vals.iter().position(|v| *v > hi)
						{
							vdiag(
								out,
								line,
								"V006",
								format!(
									"value above max {} at '{}': {}",
									format_float(hi),
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
					}
					"bool" => {
						let parsed: Option<Vec<bool>> = els
							.iter()
							.map(|e| parse_bool_text(&e.text, self.strictness))
							.collect();
						let Some(vals) = parsed else {
							wrong(out);
							return;
						};
						if let Some(AllowedSet::Bools(set)) = &c.allowed
							&& let Some(i) = vals.iter().position(|v| !set.contains(v))
						{
							vdiag(
								out,
								line,
								"V004",
								format!(
									"value not allowed at '{}': {}",
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
					}
					"datetime" => {
						let parsed: Option<Vec<ShclDateTime>> =
							els.iter().map(|e| parse_datetime(&e.text)).collect();
						let Some(vals) = parsed else {
							wrong(out);
							return;
						};
						if let Some(AllowedSet::Dates(set)) = &c.allowed
							&& let Some(i) = vals
								.iter()
								.position(|v| !set.iter().any(|s| same_moment(s, v)))
						{
							vdiag(
								out,
								line,
								"V004",
								format!(
									"value not allowed at '{}': {}",
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
					}
					// A bare number takes its unit from the field name first,
					// as the read does, then the schema's `unit`.
					"duration" | "size" => {
						let name = node.name.as_str();
						let parsed: Option<Vec<i64>> = els
							.iter()
							.map(|e| match base {
								"duration" => {
									let bare = name_unit(name, &DURATION_NAMES).or(c.unit_d);
									parse_duration_text(&e.text, bare).map(|(v, _)| v)
								}
								_ => {
									let bare = name_unit(name, &SIZE_NAMES).or(c.unit_s);
									parse_size_text(&e.text, bare, c.decimal).map(|(v, _)| v)
								}
							})
							.collect();
						let Some(vals) = parsed else {
							wrong(out);
							return;
						};
						if let Some(AllowedSet::Ints(set)) = &c.allowed
							&& let Some(i) = vals.iter().position(|v| !set.contains(v))
						{
							vdiag(
								out,
								line,
								"V004",
								format!(
									"value not allowed at '{}': {}",
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
						if let (Some(lo), Some(t)) = (c.min_i, &c.bound_text.0)
							&& let Some(i) = vals.iter().position(|v| *v < lo)
						{
							vdiag(
								out,
								line,
								"V005",
								format!(
									"value below min {} at '{}': {}",
									one_line(t),
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
						if let (Some(hi), Some(t)) = (c.max_i, &c.bound_text.1)
							&& let Some(i) = vals.iter().position(|v| *v > hi)
						{
							vdiag(
								out,
								line,
								"V006",
								format!(
									"value above max {} at '{}': {}",
									one_line(t),
									schema_text(&c.path),
									one_line(&els[i].text)
								),
							);
						}
					}
					// string kind or untyped: every element coerces; only the
					// allowed set can fail, in logical-string space.
					_ => {
						if let Some(AllowedSet::Strings(set)) = &c.allowed {
							let bad = els.iter().find(|e| !set.contains(&e.text));
							if let Some(b) = bad {
								vdiag(
									out,
									line,
									"V004",
									format!(
										"value not allowed at '{}': {}",
										schema_text(&c.path),
										one_line(&b.text)
									),
								);
							}
						}
					}
				}
			}
		}
	}

	// Unknown-field sweep: a schema path legalizes its name chain and every
	// prefix (selectors ignored). Only the topmost unknown node is reported;
	// its subtree is implied unknown and skipped.
	fn v_unknown(&self, def: &SchemaDef, out: &mut Vec<Diagnostic>) {
		let cons = &def.cons;
		// Chains below a fragment mount only match by descending the mounts.
		let has_mounts = cons.iter().any(|c| c.inherits.is_some());
		let mut legal: std::collections::HashSet<String> = std::collections::HashSet::new();
		// Sibling names per parent chain, built once (schema order): v_suggest
		// used to rebuild every chain per unknown field, which bit hardest on
		// the wholesale-unmatched documents the feature exists for.
		let mut siblings: HashMap<String, SuggestNames> = HashMap::new();
		// Paths with a `*` segment can't live in the exact-chain hash; they
		// match element-wise (a star matches any one name, prefixes included).
		let mut star_pats: Vec<&[Segment]> = Vec::new();
		for c in cons {
			if c.segs.iter().any(|s| s.star) {
				star_pats.push(&c.segs);
			}
			let mut chain = String::new();
			for s in &c.segs {
				if s.star {
					break; // no sibling entry for '*'; deeper chains are pattern-only
				}
				siblings.entry(chain.clone()).or_default().push(&s.name);
				chain_push(&mut chain, &s.name);
				legal.insert(chain.clone());
			}
		}
		// Both element-wise matchers below used to scan their whole list per
		// document node, which is quadratic once the schema and the document
		// grow together. A path can only match a chain whose first part its
		// own first segment accepts, so one bucket lookup replaces the scan.
		let star_idx = first_index(star_pats.iter().copied());
		let set_idx: HashMap<String, FirstIndex> = if has_mounts {
			// Keyed the way chain_parts_legal's `dead` is: "" for the
			// top-level list, otherwise the fragment name.
			std::iter::once((String::new(), first_index(cons.iter().map(|c| &c.segs[..]))))
				.chain(
					def.frags
						.iter()
						.map(|(k, v)| (k.clone(), first_index(v.iter().map(|c| &c.segs[..])))),
				)
				.collect()
		} else {
			HashMap::new()
		};
		let mut stack: Vec<(usize, String, String)> = self.arena[ROOT]
			.children
			.iter()
			.rev()
			.map(|&c| (c, String::new(), String::new()))
			.collect();
		while let Some((n, pchain, pshown)) = stack.pop() {
			let node = &self.arena[n];
			let mut chain = pchain.clone();
			chain_push(&mut chain, &node.name);
			let seg = diag_name(&node.name);
			let shown = if pshown.is_empty() {
				seg
			} else {
				format!("{}.{}", pshown, seg)
			};
			let known = legal.contains(&chain)
				|| star_legal(&star_pats, &star_idx, &chain)
				|| (has_mounts && chain_legal(cons, &def.frags, &set_idx, &chain));
			if !known {
				let hint = v_suggest(&mut siblings, &pchain, &node.name);
				vdiag(
					out,
					node.line,
					"V001",
					format!("unknown field '{}'{}", shown, hint),
				);
				continue;
			}
			for &k in node.children.iter().rev() {
				stack.push((k, chain.clone(), shown.clone()));
			}
		}
	}
}

/// Chain keys join segments length-prefixed (`<len>:<name>`), not with a bare
/// NUL: NUL is legal in a quoted name, so a single field named "x\0y" would
/// impersonate the two-segment path x.y. Same injectivity reasoning as
/// Value::key's cell encoding - and like it, the length unit is each
/// binding's native one (bytes here), because only injectivity matters.
fn chain_push(chain: &mut String, name: &str) {
	chain.push_str(&name.len().to_string());
	chain.push(':');
	chain.push_str(name);
}

/// Decode a chain key back into its segments. Total: bails at the first
/// shape the encoder can't have produced.
fn chain_parts(chain: &str) -> Vec<&str> {
	let mut parts = Vec::new();
	let b = chain.as_bytes();
	let mut i = 0;
	while i < b.len() {
		let mut n = 0usize;
		while i < b.len() && b[i].is_ascii_digit() {
			n = n * 10 + (b[i] - b'0') as usize;
			i += 1;
		}
		if i >= b.len() || b[i] != b':' || i + 1 + n > b.len() {
			break;
		}
		i += 1;
		parts.push(&chain[i..i + n]);
		i += n;
	}
	parts
}

/// Element-wise chain match against the star-bearing schema paths: a `*`
/// segment matches any one name, and every prefix of a path is legal.
fn star_legal(pats: &[&[Segment]], idx: &FirstIndex, chain: &str) -> bool {
	if pats.is_empty() {
		return false;
	}
	let parts: Vec<&str> = chain_parts(chain);
	idx.candidates(parts[0]).any(|pi| {
		let p = pats[pi];
		p.len() >= parts.len()
			&& parts
				.iter()
				.enumerate()
				.all(|(i, seg)| p[i].star || p[i].name == *seg)
	})
}

/// Schema paths bucketed by what their first segment accepts. A path can only
/// match a chain whose first part is that segment's name, or anything at all
/// when the segment is `*`, so a lookup plus the star bucket is the whole
/// candidate set. Values are positions in the list the index was built from.
/// Both callers ask "does any of these match", so bucket order cannot reach
/// the answer.
struct FirstIndex {
	by_name: HashMap<String, Vec<usize>>,
	stars: Vec<usize>,
}

impl FirstIndex {
	fn candidates<'a>(&'a self, part: &str) -> impl Iterator<Item = usize> + 'a {
		self.by_name
			.get(part)
			.into_iter()
			.flatten()
			.copied()
			.chain(self.stars.iter().copied())
	}
}

fn first_index<'a>(paths: impl Iterator<Item = &'a [Segment]>) -> FirstIndex {
	let mut idx = FirstIndex {
		by_name: HashMap::new(),
		stars: Vec::new(),
	};
	for (i, segs) in paths.enumerate() {
		// A pathless entry keeps its old place in every candidate set: the
		// scan it replaces looked at one, and what it then did is unchanged.
		match segs.first() {
			Some(s) if !s.star => idx.by_name.entry(s.name.clone()).or_default().push(i),
			_ => idx.stars.push(i),
		}
	}
	idx
}

/// Chain legality through fragment mounts: the general matcher - element-wise
/// like star_legal (stars wild, prefixes legal), and when a mount's whole path
/// matched with chain left over, the remainder is retried against the mounted
/// fragment's fields. Terminates: every descent consumes >= 1 part. A state
/// is (fragment, parts consumed), and one that has failed is not walked again:
/// two mounts of the same fragment at the same depth used to be walked both,
/// which is 2^depth on a chain that ends unknown.
fn chain_legal(
	cons: &[Constraint],
	frags: &HashMap<String, Vec<Constraint>>,
	set_idx: &HashMap<String, FirstIndex>,
	chain: &str,
) -> bool {
	let parts: Vec<&str> = chain_parts(chain);
	let mut dead: std::collections::HashSet<(&str, usize)> = std::collections::HashSet::new();
	chain_parts_legal(cons, "", frags, set_idx, &parts, 0, &mut dead)
}

fn chain_parts_legal<'a>(
	cons: &'a [Constraint],
	set: &'a str,
	frags: &'a HashMap<String, Vec<Constraint>>,
	set_idx: &HashMap<String, FirstIndex>,
	parts: &[&str],
	at: usize,
	dead: &mut std::collections::HashSet<(&'a str, usize)>,
) -> bool {
	if dead.contains(&(set, at)) {
		return false;
	}
	let rest = &parts[at..];
	// The recursion only descends with parts left over, and the sweep never
	// asks about an empty chain, so `rest` always has a first part to look up.
	let cand: Vec<usize> = match set_idx.get(set) {
		Some(idx) => idx.candidates(rest[0]).collect(),
		None => (0..cons.len()).collect(),
	};
	for &ci in &cand {
		let c = &cons[ci];
		let n = c.segs.len();
		let k = rest.len().min(n);
		if (0..k).all(|i| c.segs[i].star || c.segs[i].name == rest[i]) {
			if rest.len() <= n {
				return true;
			}
			if let Some(fr) = &c.inherits
				&& let Some(fcs) = frags.get(fr)
				&& chain_parts_legal(fcs, fr, frags, set_idx, parts, at + n, dead)
			{
				return true;
			}
		}
	}
	dead.insert((set, at));
	false
}

/// Closest legal sibling name (same parent chain, schema order, edit distance
/// <= 2) as "; did you mean 'x'?" - or nothing. Prose only, never contract.
fn v_suggest(
	siblings: &mut HashMap<String, SuggestNames>,
	parent_chain: &str,
	name: &str,
) -> String {
	match siblings
		.get_mut(parent_chain)
		.and_then(|names| names.closest(name))
	{
		Some(n) => format!("; did you mean '{}'?", diag_name(n)),
		None => String::new(),
	}
}

/// The legal names under one parent chain, each once, in schema order. Every
/// unknown field used to be compared with every sibling, and the list held one
/// copy per schema field, so a document whose names all miss cost the schema
/// times the document (20260918b item 10). Past the first few queries on a
/// chain, each name of up to SUGGEST_INDEXED characters is filed under every
/// spelling it has with up to two characters deleted. Two names within edit
/// distance 2 share such a spelling, so a query checks only the names its own
/// spellings find. A longer name keeps the scan, filtered by length.
#[derive(Default)]
struct SuggestNames {
	names: Vec<String>,
	seen: HashSet<String>,
	queries: usize,
	index: Option<U64Map<Vec<usize>>>,
	long: Vec<usize>,
	// The query that last looked at each name, so a name found under several
	// spellings is measured once.
	stamp: Vec<usize>,
}

const SUGGEST_INDEXED: usize = 16;
/// Queries answered by the scan before a chain gets its index. A few typos in
/// a large section should not pay for indexing it.
const SUGGEST_SCANS: usize = 16;

impl SuggestNames {
	fn push(&mut self, name: &str) {
		if self.seen.insert(name.to_string()) {
			self.names.push(name.to_string());
		}
	}

	fn closest(&mut self, name: &str) -> Option<&str> {
		self.queries += 1;
		let mut best: Option<(usize, usize)> = None;
		let mut consider = |i: usize, names: &[String]| {
			let dist = edit_distance(name, &names[i], 2);
			if dist <= 2 && best.is_none_or(|b| (dist, i) < b) {
				best = Some((dist, i));
			}
		};
		if self.queries <= SUGGEST_SCANS {
			for i in 0..self.names.len() {
				consider(i, &self.names);
			}
		} else {
			if self.index.is_none() {
				let mut index: U64Map<Vec<usize>> = U64Map::default();
				for (i, n) in self.names.iter().enumerate() {
					let cs: Vec<char> = n.chars().collect();
					if cs.len() > SUGGEST_INDEXED {
						self.long.push(i);
						continue;
					}
					deletion_spellings(&cs, |h| {
						let list = index.entry(h).or_default();
						if list.last() != Some(&i) {
							list.push(i);
						}
					});
				}
				self.index = Some(index);
				self.stamp = vec![0; self.names.len()];
			}
			let q: Vec<char> = name.chars().collect();
			let (index, stamp) = (self.index.as_ref()?, &mut self.stamp);
			if q.len() <= SUGGEST_INDEXED + 2 {
				deletion_spellings(&q, |h| {
					for &i in index.get(&h).map_or(&[][..], |v| &v[..]) {
						if stamp[i] != self.queries {
							stamp[i] = self.queries;
							consider(i, &self.names);
						}
					}
				});
			}
			for &i in &self.long {
				if self.names[i].chars().count().abs_diff(q.len()) <= 2 {
					consider(i, &self.names);
				}
			}
		}
		best.map(|(_, i)| self.names[i].as_str())
	}
}

/// Call `f` with the hash of each spelling of `cs` with none, one or two of
/// its characters deleted. The same spelling can come up more than once.
fn deletion_spellings(cs: &[char], mut f: impl FnMut(u64)) {
	let hash = |skip_a: usize, skip_b: usize| {
		let mut h = Fnv::new();
		let mut buf = [0u8; 4];
		for (k, c) in cs.iter().enumerate() {
			if k != skip_a && k != skip_b {
				h.bytes(c.encode_utf8(&mut buf).as_bytes());
			}
		}
		h.0
	};
	let none = usize::MAX;
	f(hash(none, none));
	for a in 0..cs.len() {
		f(hash(a, none));
		for b in a + 1..cs.len() {
			f(hash(a, b));
		}
	}
}

// The save gate on kept lines, from inside: once the edits that lose one are
// fixed, no public call reaches the gate, so these take a line out by hand.
#[cfg(test)]
mod kept_gate {
	use super::*;

	// The status line tests/common prints, since that module is out of reach.
	struct TestId(&'static str);

	fn test_id(id: &'static str) -> TestId {
		TestId(id)
	}

	impl Drop for TestId {
		fn drop(&mut self) {
			use std::io::Write;
			let status = if std::thread::panicking() {
				"FAIL"
			} else {
				"ok"
			};
			let thread = std::thread::current();
			let name = thread.name().unwrap_or("?");
			let _ = writeln!(
				std::io::stderr().lock(),
				"{:<4} {} rust {}",
				status,
				self.0,
				name
			);
		}
	}

	const BASE: &str = "x: 1\nr: [1, 2\ny: 3\n";

	#[test]
	fn a_kept_line_gone_from_the_tree_refuses_the_save() {
		let _id = test_id("EreRyr7");
		let mut doc = Document::parse_keep_lines(BASE, Strictness::Standard).unwrap();
		assert_eq!(doc.lost_count(), 0);
		let y = doc.arena[ROOT]
			.children
			.iter()
			.copied()
			.find(|&c| doc.arena[c].name == "y")
			.unwrap();
		let gone = doc.arena[y].triv_mut().leading.pop().unwrap();
		assert!(gone.is_kept_line(), "{:?}", gone);
		assert_eq!(doc.lost_count(), 1);
		assert!(!doc.to_text_keep_lines().1);
		let dir = std::env::temp_dir().join(format!("shcl-keptgate-{}", std::process::id()));
		std::fs::create_dir_all(&dir).unwrap();
		let path = dir.join("f.shcl");
		let path = path.to_str().unwrap();
		std::fs::write(path, BASE).unwrap();
		let refused = doc.save_file(path).unwrap_err();
		assert!(matches!(refused, SaveError::Refused { lost: 1, .. }));
		assert_eq!(
			refused.to_string(),
			format!(
				"{path}: refusing to save: this write would delete 1 line(s)/value(s) from the file (see diagnostics; save_file_lossy overrides)"
			)
		);
		assert!(matches!(
			doc.save_file_keep_lines(path),
			Err(SaveError::Refused { lost: 1, .. })
		));
		assert_eq!(std::fs::read_to_string(path).unwrap(), BASE);
		let _ = std::fs::remove_dir_all(&dir);
	}

	// design.md's table: a remove takes the kept line written as the field's
	// own line, and nothing beside it.
	#[test]
	fn a_remove_takes_the_kept_line_heading_its_field() {
		let _id = test_id("EreUeCs");
		let mut doc = Document::parse("a: [1\n\tb: 2\ny: 3\n");
		assert_eq!(doc.remove("a"), 1);
		assert_eq!(doc.lost_count(), 0);
		assert_eq!(doc.to_canonical(), "y: 3\n");
	}

	// design.md's table: a remove leaves the kept lines beside its target,
	// above or below it, with the comments above them (2026100307163901).
	#[test]
	fn a_remove_leaves_the_kept_lines_beside_it() {
		let _id = test_id("ErgToYw");
		for (text, path, want) in [
			(BASE, "y", "x: 1\nr: [1, 2\n"),
			("x: 1\nbad name: 1\ny: 3\n", "y", "x: 1\nbad name: 1\n"),
			("j:\n\tr: [1\n\tq: 1\nz: 2\n", "j.q", "j:\n\tr: [1\nz: 2\n"),
			("j:\n\tq: 1\n\tr: [1\nz: 2\n", "j.q", "j:\n\tr: [1\nz: 2\n"),
			(
				"j:\n\tq: 1\n\tr: [1\n\tw: 3\nz: 2\n",
				"j.q",
				"j:\n\tr: [1\n\tw: 3\nz: 2\n",
			),
			(
				"# on r\nr: [1\n# on y\ny: 3\nz: 1\n",
				"y",
				"# on r\nr: [1\nz: 1\n",
			),
		] {
			let mut doc = Document::parse(text);
			assert_eq!(doc.remove(path), 1, "{text:?}");
			assert_eq!(doc.lost_count(), 0, "{text:?}");
			let out = doc.to_canonical();
			assert_eq!(out, want, "{text:?}");
			assert_eq!(Document::parse(&out).to_canonical(), out, "{text:?}");
		}
	}

	// A field opened only by the lines under it goes with the last of them,
	// and its kept line stays (escblock; 2026100307163907).
	#[test]
	fn a_field_opened_by_a_kept_line_goes_with_its_last_line() {
		let _id = test_id("ErgToax");
		for (text, path, want) in [
			("a: [1\n\tb: 2\ny: 3\n", "a.b", "a: [1\ny: 3\n"),
			(
				"a: [1\n\tb: 2\n\tc: 3\ny: 3\n",
				"a.b",
				"a: [1\n\tc: 3\ny: 3\n",
			),
			(
				"a: [1\n\tb: 2\n\tr: [3\ny: 3\n",
				"a.b",
				"a: [1\n\tr: [3\ny: 3\n",
			),
			(
				"o: [9\n\ta: [1\n\t\tb: 2\ny: 3\n",
				"o.a.b",
				"o: [9\n\ta: [1\ny: 3\n",
			),
			("o:\n\ta: [1\n\t\tb: 2\n", "o.a.b", "o:\n\ta: [1\n"),
		] {
			let mut doc = Document::parse(text);
			assert_eq!(doc.remove(path), 1, "{text:?}");
			assert_eq!(doc.lost_count(), 0, "{text:?}");
			let out = doc.to_canonical();
			assert_eq!(out, want, "{text:?}");
			assert_eq!(Document::parse(&out).to_canonical(), out, "{text:?}");
		}
	}

	// A setter on a field a kept line opened writes that line as a comment
	// with a note, so the file has one line for the field (2026100307163907).
	// The stamp is the real clock's here; the CLI rows pin it.
	#[test]
	fn a_setter_comments_out_the_kept_line_heading_its_target() {
		let _id = test_id("ErleUnO");
		for (text, path, above, line, why, rest) in [
			(
				"a: [1\n\tb: 2\ny: 3\n",
				"a",
				"",
				"# a: [1",
				"E019 malformed array, no closing ']' on the line",
				"a: 5\n\tb: 2\ny: 3\n",
			),
			(
				"o:\n\ta: \"x◉Q◉\"\n\t\tb: 2\n",
				"o.a",
				"o:\n",
				"\t# a: \"x◉Q◉\"",
				"E023 unknown escape '◉Q◉'",
				"\ta: 5\n\t\tb: 2\n",
			),
			(
				"p: C:\\Program Files\n\tq: 1\n",
				"p",
				"",
				"# p: C:\\Program Files",
				"E025 whitespace in a bare value",
				"p: 5\n\tq: 1\n",
			),
			(
				"r: \"open\n\tq: 1\n",
				"r",
				"",
				"# r: \"open",
				"E017 unterminated quote in value",
				"r: 5\n\tq: 1\n",
			),
			(
				"404: x\n\tq: 1\n",
				"\"404\"",
				"",
				"# 404: x",
				"E014 field name needs quotes",
				"\"404\": 5\n\tq: 1\n",
			),
		] {
			let mut doc = Document::parse_keep_lines(text, Strictness::Standard)
				.unwrap_or_else(|e| e.document);
			assert!(doc.set_int(path, 5), "{text:?}");
			assert_eq!(doc.lost_count(), 0, "{text:?}");
			let out = doc.to_canonical();
			let (first, after) = out
				.strip_prefix(above)
				.and_then(|o| o.split_once('\n'))
				.unwrap_or_default();
			let head = format!("{line}  ## commented out by shcl when setting {path}, ");
			let stamp = first
				.strip_prefix(&head)
				.and_then(|s| s.strip_suffix(&format!(": {why}")))
				.unwrap_or_else(|| panic!("{text:?} wrote {out:?}"));
			assert!(is_stamp(stamp), "{stamp:?}");
			assert_eq!(after, rest, "{text:?}");
			let back = Document::parse(&out);
			assert!(back.diagnostics().is_empty(), "{out:?}");
			assert_eq!(back.count(path), 1, "{out:?}");
			assert_eq!(back.to_canonical(), out);
			assert_eq!(doc.to_text_keep_lines(), (out.clone(), true));
		}
		// Only the field the kept line opened: a child of it, or a field
		// beside a kept line, leaves the line as it was.
		for (path, want) in [
			("a.c", "a: [1\n\tb: 2\n\tc: 5\n"),
			("z", "a: [1\n\tb: 2\n\nz: 5\n"),
		] {
			let mut doc = Document::parse("a: [1\n\tb: 2\n");
			assert!(doc.set_int(path, 5));
			assert_eq!(doc.to_canonical(), want);
		}
	}

	// A setter writing `a` writes every kept line named `a` in that block as
	// the noted comment, and a field it creates goes right under the first
	// of them, so a later hand fix never gives Multiple (2026100307163907).
	#[test]
	fn a_setter_comments_out_every_kept_line_of_its_name() {
		let _id = test_id("ErmXhmZ");
		let note = |path: &str| {
			format!(
				"  ## commented out by shcl when setting {path}, STAMP: E019 malformed array, no closing ']' on the line"
			)
		};
		let (na, noa, nac) = (note("a"), note("o.a"), note("a.c"));
		for (text, path, want, count) in [
			// No loaded `a`: the new line goes under the first comment.
			(
				"a: [1\ny: 3\n",
				"a",
				format!("# a: [1{na}\na: 5\ny: 3\n"),
				1,
			),
			(
				"x: 1\na: [1\ny: 3\na: [2\n",
				"a",
				format!("x: 1\n# a: [1{na}\na: 5\ny: 3\n# a: [2{na}\n"),
				1,
			),
			// What was under the line goes under the new one.
			(
				"a: [1\n\t# under\n\tb: [2\ny: 3\n",
				"a",
				format!("# a: [1{na}\na: 5\n\t# under\n\tb: [2\ny: 3\n"),
				1,
			),
			// At the end of a block.
			(
				"o:\n\tx: 1\n\ta: [1\n",
				"o.a",
				format!("o:\n\tx: 1\n\t# a: [1{noa}\n\ta: 5\n"),
				1,
			),
			// A field made on the way writes its line too.
			(
				"a: [1\ny: 3\n",
				"a.c",
				format!("# a: [1{nac}\na:\n\tc: 5\ny: 3\n"),
				1,
			),
			// A loaded `a` changes in place.
			(
				"a: 1\nb: [1\na: [2\n",
				"a",
				format!("a: 5\nb: [1\n# a: [2{na}\n"),
				1,
			),
			// Two valid lines stay as they are, and so does a kept line with
			// a kept line under it, which as a comment would leave that line
			// under the field above.
			("a: 1\na: 2\n", "a", "a: 5\na: 2\n".to_string(), 2),
			(
				"a: 1\na: [2\n\tc: [3\n",
				"a",
				"a: 5\na: [2\n\tc: [3\n".to_string(),
				1,
			),
		] {
			let mut doc = Document::parse_keep_lines(text, Strictness::Standard)
				.unwrap_or_else(|e| e.document);
			assert!(doc.set_int(path, 5), "{text:?}");
			assert_eq!(doc.lost_count(), 0, "{text:?}");
			let out = doc.to_canonical();
			assert_eq!(unstamp(&out), want, "{text:?}");
			let back = Document::parse(&out);
			assert_eq!(back.count(path), count, "{out:?}");
			assert_eq!(back.to_canonical(), out);
			assert_eq!(doc.to_text_keep_lines(), (out.clone(), true));
		}
		// set_comment makes the field without touching the line.
		let mut doc = Document::parse("a: [1\ny: 3\n");
		assert!(doc.set_comment("a", "n"));
		assert_eq!(doc.to_canonical(), "a: [1\ny: 3\n\n# n\na:\n");
	}

	/// Each note's stamp, checked, as STAMP.
	fn unstamp(text: &str) -> String {
		let mut out = String::new();
		for line in text.split_inclusive('\n') {
			let Some((head, tail)) = line.split_once("## commented out by shcl when setting ")
			else {
				out.push_str(line);
				continue;
			};
			let (path, rest) = tail.split_once(", ").unwrap_or_default();
			let (stamp, why) = rest.split_once(": ").unwrap_or_default();
			assert!(is_stamp(stamp), "{line:?}");
			out.push_str(&format!(
				"{head}## commented out by shcl when setting {path}, STAMP: {why}"
			));
		}
		out
	}

	fn is_stamp(s: &str) -> bool {
		let (when, zone) = s.split_at(s.len().min(19));
		let digits = when.bytes().enumerate().all(|(k, b)| match k {
			4 | 7 => b == b'-',
			10 => b == b' ',
			13 | 16 => b == b':',
			_ => b.is_ascii_digit(),
		});
		let Some(zone) = zone.strip_prefix(' ') else {
			return false;
		};
		digits
			&& when.len() == 19
			&& (zone_label(0, zone) == zone
				|| zone.len() == 9 && zone.starts_with("UTC") && zone.as_bytes()[6] == b':')
	}

	// The zone's short name, else its offset; and the test clock's form.
	#[test]
	fn a_note_names_the_zone_or_its_offset() {
		let _id = test_id("ErleV68");
		assert_eq!(zone_label(-420, "PDT"), "PDT");
		assert_eq!(zone_label(-420, ""), "UTC-07:00");
		assert_eq!(zone_label(240, "+04"), "UTC+04:00");
		assert_eq!(zone_label(330, "IST"), "IST");
		assert_eq!(zone_label(-150, "-0230"), "UTC-02:30");
		assert_eq!(zone_label(0, "Pacific Daylight Time"), "UTC+00:00");
		assert_eq!(zone_label(0, ""), "UTC+00:00");
		assert_eq!(
			test_clock("2026-10-04 00:15:00 -420 PDT"),
			Some(("2026-10-04 00:15:00".to_string(), -420, "PDT".to_string()))
		);
		assert_eq!(
			test_clock("2026-10-04 00:15:00 60"),
			Some(("2026-10-04 00:15:00".to_string(), 60, String::new()))
		);
		assert_eq!(test_clock("2026-10-04 00:15:00"), None);
		assert_eq!(test_clock("2026-10-04 00:15:00 x PDT"), None);
		let (when, offset, name) = local_clock();
		assert!(
			is_stamp(&format!("{when} {}", zone_label(offset, &name))),
			"{when:?} {offset} {name:?}"
		);
		assert!(offset.abs() <= 14 * 60, "{offset}");
	}

	#[test]
	fn a_merged_layer_owes_its_kept_lines() {
		let _id = test_id("EreRysn");
		let mut doc = Document::parse("a: 1\n");
		doc.merge(&Document::parse(BASE));
		assert_eq!(doc.lost_count(), 0);
		assert!(doc.to_canonical().contains("r: [1, 2\n"));
		// Owed, not just present: taking it out again is a loss.
		let y = doc.arena[ROOT]
			.children
			.iter()
			.copied()
			.find(|&c| doc.arena[c].name == "y")
			.unwrap();
		doc.arena[y].triv_mut().leading.pop();
		assert_eq!(doc.lost_count(), 1);
	}

	// design.md's table: a settled kept line on a leaf the layer replaces
	// goes with the leaf's comments, so it is no longer owed.
	#[test]
	fn a_replaced_leaf_takes_its_settled_kept_line() {
		let _id = test_id("ErfGoMI");
		let mut doc = Document::parse("x: 0\n\tc: 2\n  a: 5\nb: 1\n");
		assert_eq!(doc.remove("x.c"), 1);
		assert_eq!(doc.to_canonical(), "x: 0\n# a: 5\nb: 1\n");
		assert_eq!(doc.lost_count(), 0);
		doc.merge(&Document::parse("b: 9\n"));
		assert_eq!(doc.to_canonical(), "x: 0\nb: 9\n");
		assert_eq!(doc.lost_count(), 0);
	}

	// design.md's table: the footer dedup skips a layer's kept line the base
	// already has, so that copy is not owed.
	#[test]
	fn a_footer_line_the_base_has_is_not_owed_twice() {
		let _id = test_id("ErfGoMJ");
		let mut doc = Document::parse("bad name: 1\n");
		doc.merge(&Document::parse("bad name: 1\n"));
		assert_eq!(doc.to_canonical(), "bad name: 1\n");
		assert_eq!(doc.lost_count(), 0);
	}

	// design.md's table: a replaced leaf takes only its own comments, the
	// ones a remove would take. A settled line or a comment past a kept line
	// beside it stays with that line.
	#[test]
	fn a_replaced_leaf_leaves_the_lines_beside_it() {
		let _id = test_id("ErkSy71");
		let mut doc = Document::parse("    srv: a\n  srv[x]: [3\nb[x]: [4\n# mine\nq: c\n");
		assert_eq!(
			doc.to_canonical(),
			"srv: a\n# srv[x]: [3\nb[x]: [4\n# mine\nq: c\n"
		);
		doc.merge(&Document::parse("q: 9\n"));
		assert_eq!(doc.to_canonical(), "srv: a\n# srv[x]: [3\nb[x]: [4\nq: 9\n");
		assert_eq!(doc.lost_count(), 0);
		let mut doc = Document::parse("p:\n\tq: c\n\t# mine\n\tb[x]: [4\n\t# n\n");
		doc.merge(&Document::parse("p:\n\tq: 9\n"));
		assert_eq!(doc.to_canonical(), "p:\n\tb[x]: [4\n\t# n\n\tq: 9\n");
		assert_eq!(doc.lost_count(), 0);
	}
}
