// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! Deterministic fuzz smoke: mutate the corpus inputs (and some synthetic soup)
//! with a fixed-seed PRNG and assert the invariants that must hold for ANY input:
//! no panic at any strictness, and the canonical formatter is a fixpoint.
//! Iteration count scales via SHCL_FUZZ_ITERS (cicd raises it; default is quick).

mod common;

use common::test_id;
use shcl::{
	Document, Piece, Quote, Rules, SegTok, Severity, Strictness, Tokens, format_version, migrate,
	quote_segment, schema_ref, tokenize, tokenize_value,
};

/// Small deterministic PRNG (xorshift64*); no external crates, stable across runs.
struct Rng(u64);

impl Rng {
	fn next(&mut self) -> u64 {
		let mut x = self.0;
		x ^= x >> 12;
		x ^= x << 25;
		x ^= x >> 27;
		self.0 = x;
		x.wrapping_mul(0x2545F4914F6CDD1D)
	}
	fn below(&mut self, n: usize) -> usize {
		(self.next() % n as u64) as usize
	}
}

// The characters the mutator splices in. The whitespace tail past space and tab
// is why it is worth listing them out: the parser trims the whole Unicode
// White_Space set while the emitter quotes from a much shorter list, and a value
// whose edge falls in that gap used to be truncated on reload. With none of
// these in the set, the fuzzer could not reach it - a corpus case had to.
#[rustfmt::skip]
const INTERESTING: &[char] = &[
	':', '[', ']', ',', '#', '"', '\'', '*', '~', '`', '\t', '\n', ' ', '.', '-', '\\', '%', '$',
	'0', '9', 'a', 'Z', '_', 'é', '\u{feff}',
	'\r',        // carriage return: round-trips, but only if nothing eats it
	'\u{0b}',    // vertical tab
	'\u{0c}',    // form feed
	'\u{85}',    // next line
	'\u{a0}',    // no-break space
	'\u{2028}',  // line separator
	'\u{3000}',  // ideographic space
	'\u{fe0f}',  // variation selector: kept only after a visible character
	'\u{1f3f4}', // black flag, which a subdivision flag's tags follow
	'\u{e0067}', // tag letter g: kept only inside a subdivision flag
	'\u{e007f}', // cancel tag, which ends one
];

/// How many iterations to run, never below `floor`. Split from the environment
/// so the refusals below can be tested without one.
///
/// A misspelled value used to fall back to 300 without a word, so `--ci`'s
/// 200000 became a quick run whenever the pipeline's spelling drifted, and a 0
/// ran nothing at all and reported a pass. Both are a mistake, not a setting.
fn iter_count_from(value: Option<&str>, floor: usize) -> usize {
	let n = match value {
		None => 300,
		Some(v) => v
			.trim()
			.parse::<usize>()
			.unwrap_or_else(|_| panic!("SHCL_FUZZ_ITERS is not a count: {v:?}")),
	};
	assert!(
		n > 0,
		"SHCL_FUZZ_ITERS is 0, so this test would run nothing"
	);
	n.max(floor)
}

fn iter_count(floor: usize) -> usize {
	iter_count_from(std::env::var("SHCL_FUZZ_ITERS").ok().as_deref(), floor)
}

#[test]
fn the_iteration_count_refuses_a_value_that_is_not_one() {
	let _id = test_id("EqMEflw");
	assert_eq!(iter_count_from(None, 1), 300);
	assert_eq!(iter_count_from(Some("20000"), 1), 20000);
	assert_eq!(
		iter_count_from(Some(" 500 "), 2000),
		2000,
		"the floor still wins"
	);
	for bad in ["", "0", "2OO", "-1", "1e5", "20 000"] {
		assert!(
			std::panic::catch_unwind(|| iter_count_from(Some(bad), 1)).is_err(),
			"SHCL_FUZZ_ITERS={bad:?} was accepted"
		);
	}
}

fn mutate(rng: &mut Rng, base: &str) -> String {
	let mut chars: Vec<char> = base.chars().collect();
	let edits = 1 + rng.below(8);
	for _ in 0..edits {
		let kind = rng.below(3);
		let pick = INTERESTING[rng.below(INTERESTING.len())];
		if chars.is_empty() {
			chars.push(pick);
			continue;
		}
		let at = rng.below(chars.len());
		match kind {
			0 => chars.insert(at, pick),
			1 => {
				chars.remove(at);
			}
			_ => chars[at] = pick,
		}
	}
	chars.into_iter().collect()
}

/// A raw block, in any of the forms the line shapes below cannot build: the
/// same-line and the block spelling, backticks or tildes, a run longer than
/// three, an info string, a body of several lines or one shaped like a field,
/// a closer at some other indent, and one that never closes at all. The
/// 20260918 class fix - a field line inside a body is content, not structure -
/// was checked by hand over these and by nothing since.
fn fence(rng: &mut Rng, indent: &str, name: &str) -> String {
	let mark = if rng.below(2) == 0 { "`" } else { "~" };
	let run = mark.repeat(3 + rng.below(3));
	// `c#` is the one that proves the info string ends where the comment does.
	let info = ["", "sql", "c#", " py "][rng.below(4)];
	let inner = format!("{indent}\t");
	let mut lines = match rng.below(2) {
		0 => vec![format!("{indent}{name}: {run}{info}")],
		_ => vec![format!("{indent}{name}:"), format!("{inner}{run}{info}")],
	};
	lines.extend(match rng.below(4) {
		0 => vec![format!("{inner}body")],
		1 => vec![format!("{inner}b: 2"), format!("{inner}# not a comment")],
		// Flush left, deeper than the fence, and empty: all three are content,
		// and the emitter has to pad them back to the closer's indent.
		2 => vec![String::new(), "x".to_string(), format!("{inner}\tdeeper")],
		_ => vec![],
	});
	match rng.below(5) {
		0 => {}
		1 => lines.push(format!("{indent}{run}")),
		2 => lines.push(run.clone()),
		_ => lines.push(format!("{inner}{run}")),
	}
	lines.join("\n")
}

// Line-level shapes the character mutator almost never builds: duplicate keys
// with children under them, a refused line with content beneath it, bracket
// arrays well formed and not, mixed and staircase indent, comments at every
// depth, stacked items against fields. Every defect all four bindings shared in the last
// three rounds was one of these, so half the soup is built from them.
fn structural(rng: &mut Rng) -> String {
	const NAMES: &[&str] = &["a", "b", "c", "srv", "\"q.k\"", "*"];
	let mut out = String::new();
	let mut depth = 0usize;
	for _ in 0..(1 + rng.below(16)) {
		// Indent: usually the current or next level, sometimes a jump back,
		// sometimes a space in place of a tab, sometimes one level too deep.
		depth = match rng.below(8) {
			0 => 0,
			1 => depth + 2,
			2 => depth.saturating_sub(1),
			3 | 4 => depth + 1,
			_ => depth,
		};
		let unit = if rng.below(6) == 0 { " " } else { "\t" };
		let indent = unit.repeat(depth);
		let name = NAMES[rng.below(NAMES.len())];
		// `[x]` is the old selector spelling, refused and kept (E029).
		let sel = match rng.below(7) {
			0 => "(x)",
			1 => "(*)",
			2 => "(1)",
			3 => "[x]",
			_ => "",
		};
		// Shapes 11 to 13 have a `# k` comment behind a selector holding a
		// quote, a backslash or a quoted `)`; see comments_behind_selectors.
		let line = match rng.below(29) {
			0 => format!("{indent}# comment {}", rng.below(3)),
			1 => String::new(),
			2 => format!("{indent}no colon here"),
			3 => format!("{indent}- {}", rng.below(4)),
			4 => format!("{indent}{name}: [{}, {}]", rng.below(9), rng.below(9)),
			5 => format!("{indent}{name}{sel}:"),
			6 => format!("{indent}{name}.{name}{sel}: {}", rng.below(9)),
			// Twice the weight of a plain shape, so the blocks keep their share
			// as shapes are added.
			7 | 26 => fence(rng, &indent, name),
			8 => format!("{indent}{name}: \"open"),
			9 => format!("{indent}{name}: 1, , 2 # trailing"),
			10 => format!("{indent}\u{feff}{name}: 1"),
			11 => format!("{indent}{name}(O'x).{name}: {}  # k", rng.below(9)),
			12 => format!("{indent}{name}(C:\\).{name}: it's  # k"),
			13 => format!("{indent}{name}( \"q)v\" ).{name}: {}  # k", rng.below(9)),
			// A one-element array, glued to the colon or not, which 2.x read
			// as a selector.
			14 => format!(
				"{indent}{name}:{}[v{}]",
				if rng.below(2) == 0 { " " } else { "" },
				rng.below(3)
			),
			// The 3.0 shapes: a `#` glued to a value, a selector body a comment
			// cuts off, bare and single-quoted backslashes, a comment right
			// after the colon, a quote that closes with text after it.
			15 => format!("{indent}{name}: x#y  # k"),
			16 => format!("{indent}{name}(#{}).{name}: {}", rng.below(2), rng.below(9)),
			17 => format!("{indent}{name}: C:\\dir, a\\tb, 'it\\'s'"),
			18 => format!("{indent}{name}:#x"),
			19 => format!("{indent}{name}: \"a\" b, c  # k"),
			20 => format!("{indent}{name}('x).{name}: {}  # k", rng.below(9)),
			// The array and list shapes: the old marker, a malformed array two
			// ways, with its fault past an element cap of one, and an item
			// that is a name or text with a space.
			21 => format!("{indent}* {}", rng.below(4)),
			22 => format!("{indent}{name}: [{}, {}] x", rng.below(9), rng.below(9)),
			23 => format!("{indent}{name}: [{},, {}]", rng.below(9), rng.below(9)),
			24 => format!(
				"{indent}- {}",
				["name:", "a b", "[x]", "\"k:\""][rng.below(4)]
			),
			25 => format!("{indent}{name}: [[{}], {}]", rng.below(9), rng.below(9)),
			_ => format!("{indent}{name}{sel}: {}", rng.below(9)),
		};
		out.push_str(&line);
		out.push('\n');
	}
	out
}

/// A short string over the interesting characters: what a setter is handed
/// when a config value comes from somewhere other than a keyboard.
fn soup_text(rng: &mut Rng, max: usize) -> String {
	let len = rng.below(max);
	(0..len)
		.map(|_| INTERESTING[rng.below(INTERESTING.len())])
		.collect()
}

fn seed_texts() -> Vec<String> {
	let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../project/conformance");
	let mut seeds: Vec<String> = Vec::new();
	// A missing corpus must fail loudly: three synthetic seeds are not a fuzz run.
	let entries =
		std::fs::read_dir(&dir).unwrap_or_else(|e| panic!("corpus dir {}: {}", dir.display(), e));
	for entry in entries.flatten() {
		let p = entry.path().join("input.shcl");
		if let Ok(t) = std::fs::read_to_string(&p) {
			seeds.push(t);
		}
	}
	// read_dir order is unspecified, and the seed order drives every mutation
	// the PRNG makes. Sort so a run is actually reproducible.
	seeds.sort();
	seeds.push("a: 1\n\tb: 2\n".to_string());
	seeds.push("x:\n\t- one\n\t- two\n".to_string());
	seeds.push("r:\n\t~~~\n\tbody\n\t~~~\n".to_string());
	seeds
}

#[test]
fn mutated_inputs_never_panic_and_format_is_fixpoint() {
	let _id = test_id("Ejri0IV");
	let iters = iter_count(1);
	let seeds = seed_texts();
	let mut rng = Rng(0x5EED_CAFE_F00D_0001);
	// SHCL_FUZZ_DUMP: also write the generated inputs out (capped), so the cicd
	// cross-binding check can replay the same soup through every binding's CLI.
	let dump_dir = std::env::var("SHCL_FUZZ_DUMP").ok();
	let dump_max: usize = std::env::var("SHCL_FUZZ_DUMP_MAX")
		.ok()
		.and_then(|v| v.parse().ok())
		.unwrap_or(500);
	for i in 0..iters {
		let text = if i % 2 == 0 {
			let base = &seeds[rng.below(seeds.len())];
			mutate(&mut rng, base)
		} else {
			structural(&mut rng)
		};
		if let Some(dir) = &dump_dir
			&& i < dump_max
		{
			let _ = std::fs::write(format!("{}/fuzz_{:05}.shcl", dir, i), &text);
			// Also emit a derived reads.tsv for a small subset, so the differential
			// check exercises the accessor surface (coercion, levels, arrays) over
			// fuzz soup, not just fmt. Capped so the cross-binding replay stays cheap.
			if i < 30 {
				let paths = Document::parse(&text).paths();
				if !paths.is_empty() {
					let mut tsv = String::from("query\ttype\texpected\tstatus\tlevel\n");
					// Quoted segments may contain a literal tab; those cannot ride
					// a tab-separated row, so leave them to the native runners.
					for p in paths.iter().filter(|p| !p.contains('\t')).take(3) {
						for (ty, lvl) in [
							("string", ""),
							("int", "loose"),
							("bool", "strict"),
							("string[]", ""),
						] {
							tsv.push_str(&format!("{}\t{}\t-\t-\t{}\n", p, ty, lvl));
						}
					}
					let _ = std::fs::write(format!("{}/fuzz_{:05}.reads.tsv", dir, i), tsv);
				}
			}
		}
		// Must never panic at any strictness; Strict may (validly) refuse the load.
		let _ = Document::parse_with(&text, Strictness::Loose);
		let _ = Document::parse_with(&text, Strictness::Strict);
		let doc = Document::parse(&text);
		// A few reads over mutated soup must not panic either.
		let _ = doc.read_int("a.b");
		let _ = doc.read_string_array("x");
		let _ = doc.count("r");
		// One instance path per node, each reading that node alone.
		let each = doc.instance_paths();
		let nodes: usize = doc.paths().iter().map(|p| doc.count(p)).sum();
		assert_eq!(
			each.len(),
			nodes,
			"instance paths miss a node at iteration {}:\n{}",
			i,
			text
		);
		for p in &each {
			assert_eq!(
				doc.count(p),
				1,
				"instance path {:?} does not read one node at iteration {}:\n{}",
				p,
				i,
				text
			);
		}
		// The formatter must be a fixpoint on its own output. A load can build a
		// list no text loads back, under a kept array line (2026100511210900).
		// A save refuses it, so only that unsaved text is not a fixpoint.
		if list_after_empty(&doc) {
			assert!(
				doc.lost_count() > 0,
				"a list no text loads back saves at iteration {i}:\n{text}"
			);
		} else {
			let once = doc.to_canonical();
			let twice = Document::parse(&once).to_canonical();
			assert_eq!(
				twice, once,
				"formatter not idempotent at iteration {} for mutated input:\n{}",
				i, text
			);
		}
		// Both answers to "was this file written for 2.x" have their own set of
		// rewrites, and each has to settle after one pass. An unstamped output
		// is written in the value syntax, which a second pass reads as 2.x
		// text, so only a stamped one is held to it until migrate learns the
		// value syntax (2026100207032800).
		for from_v2 in [true, false] {
			let m = migrate(&text, from_v2).text;
			if format_version(&m).is_none() {
				continue;
			}
			assert_eq!(
				migrate(&m, from_v2).text,
				m,
				"migrate changes its own output at iteration {} (from-2x {}) for mutated input:\n{}",
				i,
				from_v2,
				text
			);
		}
	}
}

/// A write on structural soup must leave a formatter fixpoint: the corpus
/// pins this for a handful of documents, and the one fold defect that broke it
/// (duplicates folded one level and no deeper) was invisible to every
/// value-level check because reads did not change.
#[test]
fn writes_on_structural_soup_stay_fixpoint() {
	let _id = test_id("Eof6zmK");
	let iters = iter_count(1);
	let mut rng = Rng(0x5EED_57A7_1C00_0002);
	for i in 0..iters {
		let text = structural(&mut rng);
		let mut doc = Document::parse(&text);
		let paths = doc.paths();
		let path = if paths.is_empty() || rng.below(4) == 0 {
			format!("new{}.k", rng.below(3))
		} else {
			paths[rng.below(paths.len())].clone()
		};
		// The values come off the soup too, so a setter meets the same text the
		// parser does. Every setter answers false either for a path it could
		// not write - a wildcard or a missing instance among the enumerated
		// paths - or for text it could not write back.
		let before = doc.to_canonical();
		let v = soup_text(&mut rng, 7);
		let op = rng.below(10);
		let applied = match op {
			0 => doc.set_int(&path, 7),
			1 => doc.set_string(&path, &v),
			2 => doc.remove(&path) > 0,
			3 => doc.set_int_default(&path, 1),
			4 => doc.set_empty(&path),
			5 => doc.set_comment(&path, &v),
			6 => doc.set_literal(&path, &v),
			7 => doc.clear_comments(&path) > 0,
			8 => {
				doc.set_banner(v.len().is_multiple_of(2));
				true
			}
			_ => doc.set_raw(&path, &v, &soup_text(&mut rng, 7)),
		};
		if !applied {
			assert_eq!(
				doc.to_canonical(),
				before,
				"a refused write changed the document at iteration {} (path {:?}, value {:?})",
				i,
				path,
				v
			);
		}
		// No text loads that case back, so a save refuses it rather than
		// writing it; only the unsaved text is not a fixpoint.
		if list_after_empty(&doc) {
			assert!(
				doc.lost_count() > 0,
				"a list no text loads back saves at iteration {i} (op {op}, path {path:?}, value {v:?}):\n{text}"
			);
			continue;
		}
		let once = doc.to_canonical();
		let twice = Document::parse(&once).to_canonical();
		assert_eq!(
			twice, once,
			"write on structural soup not a fixpoint at iteration {} (op {}, path {:?}, value {:?}):\n{}",
			i, op, path, v, text
		);
	}
}

/// A comment behind a selector stays a comment. A quote, a backslash or a
/// quoted `]` in a selector used to leave the name-half scan in the wrong
/// state, so the `#` after it was read as value text with zero diagnostics,
/// and the write that followed was a fixpoint, so nothing else could see it.
/// The structural shapes that have `# k` are the only source of that text; a
/// swallowed one comes back quoted (`port: "8080  # k"`), so a canonical line
/// holding it has to end with it.
#[test]
fn comments_behind_selectors_stay_comments() {
	let _id = test_id("Ep3OILJ");
	// The four selector shapes on their own first. In the soup a line can be
	// dropped by what sits above it, and a dropped line never reaches the loop
	// below - so the floor there was met by the two shapes that always bind,
	// and all four of the shapes this property is named for could have stopped
	// generating without a word.
	for one in [
		"a(O'x).b: 5  # k",
		"a(C:\\).b: it's  # k",
		"a( \"q)v\" ).b: 5  # k",
		"a('x).b: 5  # k",
	] {
		let doc = Document::parse(one);
		let canon = doc.to_canonical();
		assert_eq!(doc.lost_count(), 0, "line dropped: {:?}\n{}", one, canon);
		let held: Vec<&str> = canon.lines().filter(|l| l.contains("# k")).collect();
		assert!(
			held.len() == 1 && held[0].ends_with("# k"),
			"comment read as value: {:?}\n{}",
			one,
			canon
		);
	}
	let iters = iter_count(1);
	let mut rng = Rng(0x5EED_57A7_1C00_0003);
	let mut seen = 0usize;
	for i in 0..iters {
		let text = structural(&mut rng);
		let canon = Document::parse(&text).to_canonical();
		for line in canon.lines().filter(|l| l.contains("# k")) {
			seen += 1;
			assert!(
				line.ends_with("# k"),
				"comment read as value at iteration {}: {:?}\n{}",
				i,
				line,
				text
			);
		}
	}
	assert!(
		seen > iters / 4,
		"the soup had only {} commented lines",
		seen
	);
}

/// The lost count follows from the diagnostics alone: each code has one
/// outcome (the table in design.md), and lost is the number of dropped or
/// value-dropped lines, so it is zero exactly when no diagnostic says a line
/// was dropped. Nine review items were an arm that counted without saying so
/// or said so without counting; both show here. The retained half is checked
/// by content: a retained line's text comes back in the canonical output.
/// The misplaced lines the outcome table keeps: an `E012` line whose indent
/// holds a space and that opens no raw block, and an `E018` line under one,
/// on the lines up to the first that is not under it. Walked the way the
/// parser walks, raw bodies skipped.
fn kept_misplaced(
	lines: &[&str],
	codes: &std::collections::HashMap<usize, &str>,
) -> std::collections::HashSet<usize> {
	let mut kept = std::collections::HashSet::new();
	let mut hold: Option<&str> = None;
	let mut fence: Option<(u8, usize)> = None;
	let mut tok = Tokens::default();
	for (n, line) in lines.iter().enumerate() {
		if let Some((ch, len)) = fence {
			let t = line.trim_matches([' ', '\t']);
			if t.len() >= len && t.bytes().all(|b| b == ch) {
				fence = None;
			}
			continue;
		}
		let ilen = line.len() - line.trim_start_matches([' ', '\t']).len();
		let indent = &line[..ilen];
		let rest = line[ilen..].trim_start_matches([' ', '\t', '\r']);
		if rest.trim_end_matches([' ', '\t', '\r']).is_empty() || rest.starts_with('#') {
			continue;
		}
		let under = |h: &str| indent.len() > h.len() && indent.starts_with(h);
		if hold.is_some_and(|h| !under(h)) {
			hold = None;
		}
		let value = if rest.starts_with(['`', '~']) {
			tokenize_value(rest, 0, Rules::Current, &mut tok);
			Some(&rest[tok.value.0..tok.value.1])
		} else if rest.starts_with('*') {
			None
		} else {
			field_value(rest, &mut tok)
		};
		let opens = value.and_then(|v| {
			let ch = *v.as_bytes().first()?;
			let run = v.bytes().take_while(|&b| b == ch).count();
			((ch == b'`' || ch == b'~') && run >= 3).then_some((ch, run))
		});
		match codes.get(&(n + 1)) {
			Some(&"E012") => {
				hold = (indent.contains(' ') && opens.is_none()).then_some(indent);
				if hold.is_some() {
					kept.insert(n + 1);
				}
			}
			Some(&"E018") if opens.is_none() && hold.is_some_and(under) => {
				kept.insert(n + 1);
			}
			_ => {}
		}
		fence = opens.or(fence);
	}
	kept
}

#[test]
fn lost_count_follows_the_outcome_table() {
	let _id = test_id("EpFAzfk");
	let iters = iter_count(1);
	let mut rng = Rng(0x5EED_57A7_1C00_0004);
	let (mut lost_seen, mut kept_seen) = (0usize, 0usize);
	for i in 0..iters {
		let text = structural(&mut rng);
		let doc = Document::parse(&text);
		// The parser strips a file-start BOM before it sees line 1; the
		// exception is for a BOM the strip does not reach.
		let lines: Vec<&str> = text
			.strip_prefix('\u{feff}')
			.unwrap_or(&text)
			.lines()
			.collect();
		let canon = doc.to_canonical();
		let codes: std::collections::HashMap<usize, &str> =
			doc.diagnostics().iter().map(|d| (d.line, d.code)).collect();
		let kept = kept_misplaced(&lines, &codes);
		let mut want = 0usize;
		for d in doc.diagnostics() {
			let src = lines.get(d.line.wrapping_sub(1)).copied().unwrap_or("");
			match d.code {
				"E002" | "E003" | "E004" | "E006" | "E007" | "E008" | "E009" | "E011" | "E016"
				| "E021" => want += 1,
				"E012" | "E018" if !kept.contains(&d.line) => want += 1,
				"E012" | "E018" => {
					kept_seen += 1;
					let ilen = src.len() - src.trim_start_matches([' ', '\t']).len();
					let rest = src[ilen..].trim_matches([' ', '\t', '\r']);
					let as_written = format!("{}{}", &src[..ilen], rest);
					let as_comment = format!("# {}", rest);
					assert!(
						canon
							.lines()
							.any(|l| l == as_written || l.trim_start_matches('\t') == as_comment),
						"kept line {} not written back at iteration {}: {:?}\n{}",
						d.line,
						i,
						as_written,
						text
					);
				}
				"E014" if src.trim_start_matches([' ', '\t']).starts_with('\u{feff}') => want += 1,
				"E013" | "E014" | "E019" | "E026" | "E027" | "E028" => {
					kept_seen += 1;
					let kept = src.trim_matches([' ', '\t']);
					// Or as the comment a settle makes of a line under a list
					// that has to go in brackets (E028).
					let as_comment = format!("# {}", kept);
					assert!(
						canon.lines().any(|l| {
							let l = l.trim_matches([' ', '\t']);
							l == kept || l == as_comment
						}),
						"retained line {} not written back at iteration {}: {:?}\n{}",
						d.line,
						i,
						kept,
						text
					);
				}
				_ => {}
			}
		}
		assert_eq!(
			doc.lost_count(),
			want,
			"lost count disagrees with the diagnostics at iteration {}:\n{}",
			i,
			text
		);
		lost_seen += want;
	}
	assert!(
		lost_seen > iters,
		"the soup dropped only {} lines",
		lost_seen
	);
	assert!(
		kept_seen > iters / 8,
		"the soup retained only {} lines",
		kept_seen
	);
}

/// An element cap refuses a line past it whatever its value, and nothing else
/// about a line changes under one. A line the uncapped parse refuses for its
/// path, its name or its shape reads the same under a cap. A line it refuses
/// for its value (`E019`, `E026`, `E027` and the rest) is the same code under
/// a cap, or `E021` when it is past it: since 2026-10-05 the cap wins over a
/// broken value, where it used to lose to one. `E012` and `E018` are left out
/// on both sides: they judge where a line sits, and a capped line above holds
/// its level, so the lines under it move.
#[test]
fn a_cap_refuses_only_a_line_that_would_bind() {
	let _id = test_id("EqKhPQO");
	let iters = iter_count(1);
	const REFUSING: &[&str] = &[
		"E003", "E004", "E006", "E007", "E008", "E009", "E011", "E013", "E014", "E016",
	];
	let mut rng = Rng(0x5EED_57A7_1C00_0009);
	let mut kept_under_cap = 0usize;
	let mut capped_broken = 0usize;
	for i in 0..iters {
		let text = structural(&mut rng);
		let open = Document::parse(&text);
		let capped = Document::parse_limited(&text, Strictness::Standard, 0, 1, 0).unwrap();
		let on = |doc: &Document, n: usize, code: &str| {
			doc.diagnostics()
				.iter()
				.any(|d| d.line == n && d.code == code)
		};
		// Only the first line the cap refuses: up to there the two parses have
		// read the same document, so what the open parse makes of that line is
		// what the capped one would make of it without the cap. After it they
		// are different documents - a dropped line takes its children's level
		// or its parent's field children with it - and a later line may be
		// refused for a different reason in each, which is the same reasoning
		// that keeps E012 and E018 out of the second half below.
		if let Some(d) = capped.diagnostics().iter().find(|d| d.code == "E021") {
			let refused: Vec<_> = open
				.diagnostics()
				.iter()
				.filter(|o| o.line == d.line && REFUSING.contains(&o.code))
				.map(|o| o.code)
				.collect();
			assert!(
				refused.is_empty(),
				"the cap refused line {} that the open parse reads as {:?}, at iteration {}:\n{}",
				d.line,
				refused,
				i,
				text
			);
		}
		// The same rule for the bracket half: a line after the first cap
		// refusal is in a document the open parse never read.
		let first_capped = capped
			.diagnostics()
			.iter()
			.find(|d| d.code == "E021")
			.map_or(usize::MAX, |d| d.line);
		for d in open.diagnostics().iter().filter(|d| d.code == "E019") {
			if d.line > first_capped || on(&capped, d.line, "E012") || on(&capped, d.line, "E018") {
				continue;
			}
			if on(&capped, d.line, "E021") {
				capped_broken += 1;
				continue;
			}
			assert!(
				on(&capped, d.line, "E019"),
				"bracket text on line {} is neither E019 nor E021 under a cap, at iteration {}:\n{}",
				d.line,
				i,
				text
			);
			kept_under_cap += 1;
		}
	}
	assert!(
		kept_under_cap > iters / 16 && capped_broken > iters / 16,
		"the soup checked only {} bracket lines kept and {} refused under a cap",
		kept_under_cap,
		capped_broken
	);
}

/// A field line's value, from the text past its indent: what follows the
/// separator, as the tokenizer reads it. A line that did not tokenize still
/// has one after its first colon past the fault, unless a comment comes
/// first; only its leading run is read.
fn field_value<'t>(rest: &'t str, tok: &mut Tokens) -> Option<&'t str> {
	tokenize(rest, b':', false, Rules::Current, tok);
	match tok.fault {
		Some((at, _)) => {
			let tail = &rest[at..];
			tail.find([':', '#'])
				.filter(|&k| tail.as_bytes()[k] == b':')
				.map(|k| tail[k + 1..].trim_start_matches([' ', '\t', '\r']))
		}
		None => tok.sep.map(|_| &rest[tok.value.0..tok.value.1]),
	}
}

/// A leading run of three or more `` ` `` or `~`, which is how a fence line
/// both opens and closes a block.
fn fence_run(text: &str) -> Option<(char, usize)> {
	let c = text.chars().next()?;
	if c != '`' && c != '~' {
		return None;
	}
	let n = text.chars().take_while(|&x| x == c).count();
	(n >= 3).then_some((c, n))
}

/// Every raw body in the text, as 1-based line numbers: the line that opened
/// the block, and the last line the block covers (its closing fence, or the
/// last line of the file when it never closes). This is the spec's rule spelled
/// out on its own - a block closes at the first later line whose trimmed text
/// is a run of the same character, at least as long as the opener's - so the
/// property below has an oracle rather than the parser's own answer.
///
/// Lexical, and deliberately: what the parser makes of the opening line - a
/// fence with nothing to bind to, a line it skipped - does not change where the
/// body is. A skipped field line takes its body with it, which is the whole
/// point of the property below.
fn raw_spans(text: &str) -> Vec<(usize, usize)> {
	// The load strips a file-start BOM, so it cannot hide a `*` or a `- `.
	let lines: Vec<&str> = text
		.strip_prefix('\u{feff}')
		.unwrap_or(text)
		.lines()
		.collect();
	let mut spans = Vec::new();
	let mut open: Option<(char, usize, usize)> = None;
	let mut tok = Tokens::default();
	for (k, line) in lines.iter().enumerate() {
		let bare = line.trim_start_matches([' ', '\t']);
		if let Some((c, n, at)) = open {
			// Only the blanks the load trims: a no-break space before a fence
			// leaves it body text. A body keeps its carriage returns but the
			// line's trailing run, so one after the indent does too.
			let closer = line.trim_end_matches('\r').trim_matches([' ', '\t']);
			if closer.chars().count() >= n && closer.chars().all(|x| x == c) {
				spans.push((at, k + 1));
				open = None;
			}
			continue;
		}
		// The block spelling: the fence is the whole line. The same-line
		// spelling: it is the value. A `*` is no field name, so such a line
		// has no value and opens nothing, and a comment has none either. Nor
		// does a `- ` item, which is one value and never opens a block.
		if bare.starts_with(['*', '#']) {
			continue;
		}
		let item = bare.trim_start_matches(BLANKS);
		if item
			.strip_prefix('-')
			.is_some_and(|after| after.is_empty() || after.starts_with(BLANKS))
		{
			continue;
		}
		let opens = fence_run(bare).or_else(|| {
			field_value(bare.trim_start_matches([' ', '\t', '\r']), &mut tok).and_then(fence_run)
		});
		if let Some((c, n)) = opens {
			open = Some((c, n, k + 1));
		}
	}
	if let Some((_, _, at)) = open {
		spans.push((at, lines.len()));
	}
	spans
}

// A `*` line opens no block, with a file-start BOM in front of it too.
#[test]
fn a_bom_hides_no_star_from_the_raw_spans() {
	let _id = test_id("ErsMtSw");
	let base = "\u{feff}*aw: ```sql\nbody\n";
	assert!(raw_spans(base).is_empty());
	assert!(kept_text(base).spans.is_empty());
	assert_eq!(raw_spans("\u{feff}aw: ```sql\nbody\n"), [(1, 2)]);
}

// A carriage return after a fence line's indent leaves it body text, as the
// load reads it. A trailing run is still trimmed.
#[test]
fn a_cr_after_the_indent_closes_no_raw_span() {
	let _id = test_id("ErsrQev");
	let base = "a: ~~~\n\t\r~~~\nb\n~~~\n";
	assert_eq!(raw_spans(base), [(1, 4)]);
	assert!(Document::parse(base).diagnostics().is_empty());
	assert_eq!(raw_spans("a: ~~~\n\t~~~\r\r\nb: 1\n"), [(1, 2)]);
}

/// A raw body is content, whatever becomes of the line that opened it. A
/// skipped field line whose value opened a block left the body to be read as
/// lines, and its closing fence then opened a block of its own; nine review
/// items were some arm of that. So no diagnostic may fall on a body line or a
/// closing fence, unless the opening line has no value to read: a `*` name,
/// which is no field at all, or a fence with no field above it to bind to
/// (E006). A path that did not parse (E014) takes its body too.
#[test]
fn raw_bodies_stay_content() {
	let _id = test_id("EqGWdij");
	let iters = iter_count(1);
	let mut rng = Rng(0x5EED_57A7_1C00_0008);
	let (mut seen, mut skipped, mut read_back) = (0usize, 0usize, 0usize);
	for i in 0..iters {
		let text = structural(&mut rng);
		let lines: Vec<&str> = text.lines().collect();
		let doc = Document::parse(&text);
		// Every value the document holds, as one blob - a raw block's value is
		// its body. Silence on the body lines was never enough on its own: a
		// parser that opened the block and ALSO bound the field under it drew no
		// diagnostic and was its own fixpoint, so the body has to be read back.
		// Read through instances rather than get_raw, since a repeated name
		// answers a path lookup with Multiple and the block would go unseen.
		let values = doc
			.paths()
			.iter()
			.flat_map(|p| doc.instances(p))
			.collect::<Vec<_>>()
			.join("\n");
		let diags = doc.diagnostics();
		let on = |n: usize, codes: &[&str]| {
			diags
				.iter()
				.any(|d| d.line == n && (codes.is_empty() || codes.contains(&d.code)))
		};
		for (opener, last) in raw_spans(&text) {
			if on(opener, &["E006"]) {
				continue;
			}
			seen += 1;
			if on(opener, &["E012", "E018"]) {
				skipped += 1;
			}
			for body in (opener + 1)..=last {
				assert!(
					!on(body, &[]),
					"diagnostic on raw body line {} of the block opened at {}, at iteration {}:\n{}",
					body,
					opener,
					i,
					text
				);
				// Only where the opening line itself drew nothing: a skipped or
				// capped opener takes its body with it, which is a separate rule.
				if on(opener, &[]) {
					continue;
				}
				let t = lines[body - 1].trim();
				if t.is_empty() || fence_run(t).is_some() {
					continue;
				}
				assert!(
					values.contains(t),
					"raw body line {} of the block opened at {} did not read back, at iteration {}:\n{}",
					body,
					opener,
					i,
					text
				);
				read_back += 1;
			}
		}
	}
	assert!(seen > iters / 8, "the soup opened only {} blocks", seen);
	assert!(
		read_back > iters / 8,
		"only {} body lines were read back",
		read_back
	);
	assert!(
		skipped > iters / 60,
		"the soup skipped only {} block openers",
		skipped
	);
}

/// A Schema or Format line counts exactly where the parser reads it as a
/// comment, and not inside a raw body. The line walk that finds them used the
/// 2.x tokenizer, where a backslash escapes in single quotes too, so after
/// `'C:\': ~~~` it missed the block and took the line in its body as the
/// file's. Judged on files that load without an error, since a line the
/// parser refuses for its text may still read its body as lines.
#[test]
fn schema_and_format_lines_follow_the_parser() {
	let _id = test_id("ErfuRfE");
	const NAMES: &[&str] = &["a", "b", "'C:\\'", "'a\\'", "\"c\\\\\"", "'q\\'.r'"];
	let iters = iter_count(1);
	let mut rng = Rng(0x5EED_5C4E_3A00_0011);
	let (mut inside, mut outside) = (0usize, 0usize);
	for i in 0..iters {
		let mut lines: Vec<String> = Vec::new();
		for _ in 0..(1 + rng.below(6)) {
			let name = NAMES[rng.below(NAMES.len())];
			let block = match rng.below(4) {
				0 => format!("{name}: {}", rng.below(9)),
				1 => format!("# note {}", rng.below(3)),
				_ => fence(&mut rng, "", name),
			};
			lines.extend(block.lines().map(str::to_string));
		}
		let at = rng.below(lines.len() + 1);
		let indent = if rng.below(2) == 0 { "" } else { "\t" };
		let mark = ["Schema   mark.shcl", "Format   3"][rng.below(2)];
		lines.insert(at, format!("{indent}##    {mark}"));
		let text = lines.join("\n") + "\n";
		let doc = Document::parse(&text);
		if doc
			.diagnostics()
			.iter()
			.any(|d| d.severity == Severity::Error)
		{
			continue;
		}
		let in_body = doc
			.paths()
			.iter()
			.flat_map(|p| doc.instances(p))
			.any(|v| v.contains(mark));
		if in_body {
			inside += 1;
		} else {
			outside += 1;
		}
		let counted = if mark.starts_with("Schema") {
			schema_ref(&text).is_some()
		} else {
			format_version(&text).is_some()
		};
		assert_eq!(
			counted,
			!in_body,
			"the {} line counted {} where the parser reads it {} a raw body, at iteration {}:\n{}",
			mark,
			counted,
			if in_body { "in" } else { "outside" },
			i,
			text
		);
	}
	assert!(
		inside > iters / 20,
		"only {} lines landed in a raw body",
		inside
	);
	assert!(
		outside > iters / 20,
		"only {} lines landed outside one",
		outside
	);
}

/// A list with a field under it (E001) after an empty binding of its name
/// that has fields of its own. A merge or an edit can leave one, and then no
/// text reloads as it: stacked, its header joins that binding and its items
/// are dropped (E008), and in brackets it is E028 (2026100511210900). The
/// save gate counts its items lost, so it is never written; the properties
/// that compare written text check that and skip the rest.
fn list_after_empty(doc: &Document) -> bool {
	doc.instance_paths().iter().any(|p| {
		let r = doc.read_string(p);
		let list = !doc.children(p).is_empty()
			&& r.status == shcl::Status::Good
			&& !r.quoted
			&& r.value.starts_with('[');
		let Some((head, k)) = p
			.strip_suffix(')')
			.and_then(|q| q.rsplit_once('('))
			.and_then(|(h, k)| Some((h, k.parse::<usize>().ok()?)))
		else {
			return false;
		};
		list && (0..k).any(|j| {
			let e = format!("{head}({j})");
			doc.read_string(&e).status == shcl::Status::Empty && !doc.children(&e).is_empty()
		})
	})
}

/// The fmt property's case: a kept array line (E028) with a wildcard line
/// under it builds a list no text loads back, and the save refuses it.
#[test]
fn a_kept_array_line_can_build_the_list_no_text_loads_back() {
	let _id = test_id("Erxfmqc");
	let doc = Document::parse("srv.srv: 2\nsrv: [v1]\n\tq(*): 7\n\t- 0\n\tc: 1\n");
	assert!(list_after_empty(&doc), "{}", doc.to_canonical());
	assert!(doc.lost_count() > 0);
}

/// Layered merge over mutated soup: overlaying one document on another must
/// never panic and the merged result must be a formatter fixpoint - the same
/// guarantee `fmt` gives, now for the composed document.
#[test]
fn merge_never_panics_and_stays_fixpoint() {
	let _id = test_id("EkyV758");
	let iters = iter_count(1);
	let seeds = seed_texts();
	let mut rng = Rng(0x5EED_CAFE_F00D_0007);
	for i in 0..iters {
		let a_i = rng.below(seeds.len());
		let a = mutate(&mut rng, &seeds[a_i]);
		let b_i = rng.below(seeds.len());
		let b = mutate(&mut rng, &seeds[b_i]);
		let mut doc = Document::parse(&a);
		doc.merge(&Document::parse(&b));
		if list_after_empty(&doc) {
			assert!(
				doc.lost_count() > 0,
				"a merged list no text loads back saves at iteration {i}:\nA:\n{a}\nB:\n{b}"
			);
			continue;
		}
		let once = doc.to_canonical();
		let twice = Document::parse(&once).to_canonical();
		assert_eq!(
			twice, once,
			"merged output not idempotent at iteration {} for:\nA:\n{}\nB:\n{}",
			i, a, b
		);
		// Onto an empty base a merge reads as the layer: nothing to match, so
		// every node comes across in file order. Only the lists' form may
		// differ, since a merge writes every list in brackets, so a merge of
		// that text gives the same text again.
		let mut empty = Document::new();
		empty.merge(&Document::parse(&b));
		let layer = Document::parse(&b);
		assert_eq!(
			empty.paths(),
			layer.paths(),
			"merge onto empty base changed the paths at iteration {} for:\n{}",
			i,
			b
		);
		for p in layer.paths() {
			let (x, y) = (empty.read_string(&p), layer.read_string(&p));
			assert_eq!(
				(x.value, x.status),
				(y.value, y.status),
				"merge onto empty base changed {:?} at iteration {} for:\n{}",
				p,
				i,
				b
			);
		}
		for text in [empty.to_canonical(), once.clone()] {
			let mut again = Document::new();
			again.merge(&Document::parse(&text));
			assert_eq!(
				again.to_canonical(),
				text,
				"a merge of merged output changed it at iteration {} for:\nA:\n{}\nB:\n{}",
				i,
				a,
				b
			);
		}
		// Reads answered by the merged document itself, not just its text. A
		// merged arena holds dropped nodes, a rebuilt index and cloned child
		// lists, and only a read walks those; the text compare above cannot
		// see them. Every eighth iteration, since it walks every path.
		//
		// `instances` is left out on purpose: it hands back the SOURCE
		// spelling, and canonical output legitimately rewrites a value -
		// escaping a quote to keep it on one line, say - so the two differ for
		// a reason that has nothing to do with merging.
		if i % 8 == 0 {
			let back = Document::parse(&once);
			assert_eq!(doc.paths(), back.paths(), "paths differ at iteration {}", i);
			for p in doc.paths() {
				assert_eq!(doc.count(&p), back.count(&p), "count {:?} at {}", p, i);
				assert_eq!(
					doc.children(&p),
					back.children(&p),
					"children {:?} at {}",
					p,
					i
				);
				let (x, y) = (doc.read_string(&p), back.read_string(&p));
				assert_eq!(
					(x.value, x.status),
					(y.value, y.status),
					"read {:?} at {}",
					p,
					i
				);
				let (x, y) = (doc.read_string_array(&p), back.read_string_array(&p));
				assert_eq!(
					(x.value, x.status, x.slots),
					(y.value, y.status, y.slots),
					"array read {:?} at {}",
					p,
					i
				);
			}
		}
		// A layer and its canonical form must merge the same: a load that
		// keeps a bit its own emitter cannot re-emit makes the fold depend on
		// whether the caller formatted the layer first.
		let mut from_text = Document::parse(&a);
		from_text.merge(&Document::parse(&b));
		let mut from_canon = Document::parse(&a);
		from_canon.merge(&Document::parse(&Document::parse(&b).to_canonical()));
		assert_eq!(
			from_canon.to_canonical(),
			from_text.to_canonical(),
			"merging a layer differs from merging its canonical form at iteration {} for:\nA:\n{}\nB:\n{}",
			i,
			a,
			b
		);
	}
}

/// Writer round-trip: a set_string value must read back verbatim (encode is the
/// exact inverse of the string read), survive emit + reparse, and leave the
/// document a formatter fixpoint - even for the reserved/escape/fence hazards.
#[test]
fn writer_roundtrips_and_stays_fixpoint() {
	let _id = test_id("Ekfzh7g");
	let iters = iter_count(1);
	let mut rng = Rng(0x5EED_0000_1234_ABCD);
	for i in 0..iters {
		let s = soup_text(&mut rng, 12);
		let mut d = Document::new();
		assert!(d.set_string("k", &s));
		// In-memory: encode is the exact inverse of the scalar string read.
		let mem = d.read_string("k");
		assert_eq!(mem.value, s, "in-memory set/read #{} for {:?}", i, s);
		// Through emit + reparse: the value survives quoting/escaping intact.
		let text = d.to_canonical();
		let rt = Document::parse(&text).read_string("k");
		assert_eq!(rt.value, s, "reparse round-trip #{} for {:?}", i, s);
		assert_eq!(
			Document::parse(&text).to_canonical(),
			text,
			"writer output not a fixpoint #{} for {:?}",
			i,
			s
		);
		// The written document and its own reload agree on the source spelling
		// too, not just on the value: a text with both quote kinds used to
		// store one form and reparse as another.
		assert_eq!(
			d.instances("k"),
			Document::parse(&text).instances("k"),
			"instances differ between a written document and its reload #{} for {:?}",
			i,
			s
		);
		// Array form: each element unquotes/unescapes back to itself.
		let b = soup_text(&mut rng, 12);
		let mut da = Document::new();
		assert!(da.set_string_array("k", &[s.as_str(), b.as_str()]));
		let ra = Document::parse(&da.to_canonical()).read_string_array("k");
		assert_eq!(
			ra.value,
			vec![s.clone(), b.clone()],
			"array round-trip #{}",
			i
		);
	}
}

/// A merge or an edit leaves the document its own saved text reloads as,
/// comments included, so the next step comes out the same whether or not the file
/// was saved in between. Comments were filed one way by a load and another by
/// a merge, a new child or the writer's fold three times in three days; the
/// text fixpoint cannot see it, since both placements are fixpoints.
#[test]
fn edits_and_merges_match_a_reload() {
	let _id = test_id("Eqk24nZ");
	let iters = iter_count(1);
	let seeds = seed_texts();
	let mut rng = Rng(0x5EED_0923_C0DE_0003);
	for i in 0..iters {
		let base = if rng.below(3) == 0 {
			let seed = rng.below(seeds.len());
			mutate(&mut rng, &seeds[seed])
		} else {
			structural(&mut rng)
		};
		let mut live = Document::parse(&base);
		let mut log = format!("base:\n{base}");
		for _ in 0..(2 + rng.below(3)) {
			let text = live.to_canonical();
			let mut back = Document::parse(&text);
			let paths = live.paths();
			let path = if paths.is_empty() || rng.below(3) == 0 {
				format!(
					"{}.{}",
					["a", "b", "m"][rng.below(3)],
					["c", "d", "x"][rng.below(3)]
				)
			} else {
				paths[rng.below(paths.len())].clone()
			};
			let v = format!("v{}", rng.below(3));
			let op = rng.below(12);
			let layer = structural(&mut rng);
			for d in [&mut live, &mut back] {
				let _ = match op {
					0 | 1 => {
						d.merge(&Document::parse(&layer));
						true
					}
					2 => d.set_int(&path, 7),
					3 => d.set_string(&path, &v),
					4 => d.remove(&path) > 0,
					5 => d.set_comment(&path, &v),
					6 => d.set_empty(&path),
					7 => d.set_raw(&path, "body", &v),
					8 => d.set_int_default(&path, 1),
					9 => d.set_literal(&path, &v),
					10 => d.clear_comments(&path) > 0,
					_ => {
						d.set_banner(v != "v0");
						true
					}
				};
			}
			log.push_str(&match op {
				0 | 1 => format!("merge:\n{layer}"),
				_ => format!("op {op} at {path:?}\n"),
			});
			let (a, b) = (
				unstamped(&live.to_canonical()),
				unstamped(&back.to_canonical()),
			);
			if list_after_empty(&live) {
				assert!(
					live.lost_count() > 0,
					"a list no text loads back saves at iteration {i}:\n{log}"
				);
				break;
			}
			assert!(
				a == b || ((op == 4 || op == 10) && reload_took_only_comments(&a, &b)),
				"a step on the document and on its reload differ at iteration {i}:\n{log}"
			);
		}
	}
}

/// A kept line the settle turned into a comment is still the user's line, so
/// clear_comments and a remove beside it leave it (design.md, Kept lines under
/// edits). The canonical text writes it as a comment, and the reload takes it
/// like one, so the two cannot agree (20260926 item 2). True when that is all
/// that differs: the reload's comment lines are some of the document's, in
/// order, and without comment and blank lines the two load as one document.
/// A comment the reload took can also take a blank with it, step the
/// comments after it back a level, or leave a kept line heading the block
/// below, so the rest is compared as documents. A check of the target's
/// comments missed one below the target (2026100506223902).
fn reload_took_only_comments(live: &str, back: &str) -> bool {
	let comment = |l: &&str| l.trim_start_matches('\t').starts_with('#');
	let mut have = live
		.lines()
		.filter(comment)
		.map(|l| l.trim_start_matches('\t'));
	let mut took = back
		.lines()
		.filter(comment)
		.map(|l| l.trim_start_matches('\t'));
	if !took.all(|c| have.any(|h| h == c)) {
		return false;
	}
	let bare = |text: &str| {
		let rest: String = text
			.lines()
			.filter(|l| !l.is_empty() && !comment(l))
			.flat_map(|l| [l, "\n"])
			.collect();
		Document::parse(&rest).to_canonical()
	};
	bare(live) == bare(back)
}

/// The issue's steps, which the fuzz reached with the value syntax: the
/// setter comments out `a: [1` and makes `a` with the lines under it, and the
/// new `c` goes between the kept line and the settled one, so the settled
/// line sits below it. The remove leaves it there. The reload reads a plain
/// comment and takes it with the field.
#[test]
fn a_remove_keeps_a_settled_line_below_it() {
	let _id = test_id("ErpmA09");
	let mut live = Document::parse("a: [1\n\t\t\": \n\t d-: 2\n\te: 3\n");
	assert_eq!(live.clear_comments("a.d"), 0);
	assert!(live.set_empty("a.c"));
	assert!(live.set_raw("b.c", "body", "v0"));
	let mut back = Document::parse(&live.to_canonical());
	assert_eq!(live.remove("a.c"), 1);
	assert_eq!(back.remove("a.c"), 1);
	let (a, b) = (
		unstamped(&live.to_canonical()),
		unstamped(&back.to_canonical()),
	);
	assert!(a.contains("\n\t\":\n\t# d-: 2\n\nb:\n"), "{a}");
	assert!(b.contains("\n\t\":\n\nb:\n"), "{b}");
	assert!(reload_took_only_comments(&a, &b));
	assert!(!reload_took_only_comments(&b, &a));
}

/// A config the way people write one: a steady indent of tabs or spaces,
/// comments, blank lines, odd spacing, quoted values, lists and raw blocks,
/// sometimes with CRLF line ends.
fn tidy(rng: &mut Rng) -> String {
	let unit = ["\t", "  ", "    "][rng.below(3)];
	let eol = if rng.below(5) == 0 { "\r\n" } else { "\n" };
	let mut out = String::new();
	let mut depth = 0usize;
	for n in 0..(1 + rng.below(14)) {
		if depth > 0 && rng.below(4) == 0 {
			depth -= 1;
		}
		let ind = unit.repeat(depth);
		let inner = unit.repeat(depth + 1);
		let name = format!("{}{}", ["k", "Srv", "port", "x_y"][rng.below(4)], n);
		let line = match rng.below(10) {
			0 => format!("{ind}# note {n}"),
			1 => String::new(),
			2 => {
				depth += 1;
				format!("{ind}{name}:")
			}
			3 => format!("{ind}{name}:   \"quoted {n}\"   # c{n}"),
			4 => format!("{ind}{name}: a, b,  c"),
			5 => format!("{ind}{name}:{eol}{inner}* one{eol}{inner}* two"),
			6 => format!(
				"{ind}{name}:{eol}{inner}```{eol}{inner}body {n}{eol}{inner}  deeper{eol}{inner}```"
			),
			7 => format!("{ind}{name}.sub: {}", rng.below(100)),
			_ => format!("{ind}{name}: {}", rng.below(100)),
		};
		out.push_str(&line);
		out.push_str(eol);
	}
	out
}

/// The save that keeps lines writes text that reloads as the document with
/// no error the base did not have, or the canonical form when it cannot; a
/// load with no edits writes its own text back. On tidy configs, plain
/// edits keep their lines nearly always, so a change that quietly fell back
/// to the canonical form every time fails here too. A new field at the top
/// keeps every line of the base that is not blank, in order, whenever the
/// save keeps lines at all.
#[test]
fn keeping_lines_reloads_as_the_document() {
	let _id = test_id("EqutO7I");
	let iters = iter_count(300);
	let seeds = seed_texts();
	let mut rng = Rng(0x5EED_0925_4B33_0001);
	let (mut tries, mut kept_tidy) = (0usize, 0usize);
	for i in 0..iters {
		let shape = rng.below(4);
		let base = match shape {
			0 => {
				let seed = rng.below(seeds.len());
				mutate(&mut rng, &seeds[seed])
			}
			1 => structural(&mut rng),
			_ => tidy(&mut rng),
		};
		let mut doc =
			Document::parse_keep_lines(&base, Strictness::Standard).unwrap_or_else(|e| e.document);
		assert_eq!(
			doc.to_text_keep_lines(),
			(base.clone(), true),
			"iteration {i}: no edits, text changed:\n{base}"
		);
		// Any base that keeps its lines and loads clean, not only a tidy one:
		// a repeat the load folded away comes back too (20260925c item 1). A
		// kept misplaced line is left out, since it turns into a comment once
		// a new field above it would take it as a child.
		let clean = !doc
			.diagnostics()
			.iter()
			.any(|d| d.severity == Severity::Error);
		let mut added = doc.clone();
		let set = (clean || shape >= 2) && added.set_int("zz_new", 1);
		assert!(set || shape < 2, "iteration {i}: no new field:\n{base}");
		if set {
			let (text, kept) = added.to_text_keep_lines();
			let bare = |l: &str| l.trim_end_matches(['\r', '\n']).to_string();
			let no_bom = |t: &str| t.strip_prefix('\u{feff}').unwrap_or(t).to_string();
			let (text, base) = (no_bom(&text), no_bom(&base));
			let mut rest = text.split_inclusive('\n').map(bare);
			let all_there = base
				.split_inclusive('\n')
				.filter(|l| !l.trim().is_empty())
				.all(|l| rest.any(|t| t == bare(l)));
			assert!(
				(kept || shape < 2) && (!kept || all_there),
				"iteration {i}: a new field moved or dropped a line:\n{base}--- wrote\n{text}"
			);
		}
		let mut log = format!("base:\n{base}");
		for step in 0..(1 + rng.below(3)) {
			let paths = doc.paths();
			let path = if paths.is_empty() || rng.below(4) == 0 {
				format!("z{step}")
			} else {
				paths[rng.below(paths.len())].clone()
			};
			let op = rng.below(9);
			let _ = match op {
				0 => doc.set_int(&path, 7),
				1 => doc.set_string(&path, "new text"),
				2 => doc.remove(&path) > 0,
				3 => doc.set_comment(&path, "added"),
				4 => doc.clear_comments(&path) > 0,
				5 => doc.set_int(&format!("{path}.kid{step}"), 3),
				6 => doc.set_empty(&path),
				7 => doc.set_banner(true) > 0,
				_ => doc.set_raw(&path, "one\n\ttwo", "sh"),
			};
			log.push_str(&format!("op {op} at {path:?}\n"));
		}
		let want = doc.to_canonical();
		let (text, kept) = doc.to_text_keep_lines();
		if kept {
			let back = Document::parse(&text);
			assert_eq!(
				back.to_canonical(),
				want,
				"iteration {i}: kept lines reload as another document:\n{log}--- wrote\n{text}"
			);
			let errors = |d: &Document| {
				let mut c: Vec<&str> = d
					.diagnostics()
					.iter()
					.filter(|d| d.severity == Severity::Error)
					.map(|d| d.code)
					.collect();
				c.sort_unstable();
				c
			};
			let mut had = errors(&Document::parse(&base)).into_iter();
			assert!(
				errors(&back).iter().all(|c| had.any(|h| h == *c)),
				"iteration {i}: kept lines load with a new error:\n{log}--- wrote\n{text}"
			);
			// Every line the load dropped went out as written, so the reload
			// drops each one again (20260926 item 1).
			assert_eq!(
				back.lost_count(),
				Document::parse(&base).lost_count(),
				"iteration {i}: kept lines lost a dropped line:\n{log}--- wrote\n{text}"
			);
		} else {
			assert_eq!(
				text, want,
				"iteration {i}: a fallback that is not canonical:\n{log}"
			);
		}
		if shape >= 2 {
			tries += 1;
			kept_tidy += usize::from(kept);
		}
	}
	// A child under a stacked list or a dotted line, and a comment on a dotted
	// path, fall back by design. Tidy configs hold both, so the share that
	// keeps its lines moves with the seed set, between about 89 and 93 percent.
	assert!(
		kept_tidy * 100 >= tries * 85,
		"only {kept_tidy} of {tries} tidy configs kept their lines"
	);
}

/// Where each line a load refused for its value (`E017`, `E019`, `E023`,
/// `E025`) binds once fixed. Each is cut back to `name:`, the way a reload
/// opens it when a line under it binds, and the node its line made gives
/// the path. Pairs of (N, path), N being the line's text's place in
/// `texts`, sorted. None when the load dropped a line, since a save drops
/// it again and the lines under it go with it. A raw fence takes its body
/// along, so a value that opens one stays as it was.
fn kept_paths(text: &str, texts: &mut Vec<String>) -> Option<Vec<(usize, String)>> {
	let doc = Document::parse(text);
	if doc.lost_count() > 0 {
		return None;
	}
	let mut lines: Vec<String> = text.split('\n').map(str::to_string).collect();
	let mut tok = Tokens::default();
	let mut kept: Vec<(usize, usize)> = Vec::new();
	for d in doc.diagnostics() {
		if !matches!(d.code, "E017" | "E019" | "E023" | "E025") || d.line == 0 {
			continue;
		}
		let line = &lines[d.line - 1];
		let rest = line.trim_start_matches([' ', '\t']);
		let indent = &line[..line.len() - rest.len()];
		tokenize(rest, b':', false, Rules::Current, &mut tok);
		let Some(sep) = tok.sep else {
			continue;
		};
		if rest[tok.value.0..].starts_with(['`', '~']) {
			continue;
		}
		let key = rest.trim_end().to_string();
		let n = texts.iter().position(|t| *t == key).unwrap_or_else(|| {
			texts.push(key);
			texts.len() - 1
		});
		kept.push((d.line, n));
		lines[d.line - 1] = format!("{indent}{}", &rest[..=sep]);
	}
	// A dotted line makes a node per segment; the last one seen is its own.
	let fixed = Document::parse(&lines.join("\n"));
	let mut by_line: std::collections::HashMap<usize, String> = std::collections::HashMap::new();
	for p in fixed.instance_paths() {
		if let Some(&l) = fixed.lines(&p).first() {
			by_line.insert(l, without_instances(&p));
		}
	}
	// Two lines written alike can trade which one makes the node the other
	// joins, so only a text that appears once is compared.
	let once = |n: usize| kept.iter().filter(|k| k.1 == n).count() == 1;
	let mut at: Vec<(usize, String)> = kept
		.iter()
		.filter(|k| once(k.1))
		.filter_map(|&(l, n)| by_line.get(&l).map(|p| (n, p.clone())))
		.collect();
	at.sort();
	Some(at)
}

/// The pairs both sides have the same number of for their N. A line that
/// joins a node an earlier line made has no node of its own, and a save can
/// write the two in either order.
fn common(a: &[(usize, String)], b: &[(usize, String)]) -> Vec<(usize, String)> {
	let count = |v: &[(usize, String)], n: usize| v.iter().filter(|p| p.0 == n).count();
	a.iter()
		.filter(|p| count(a, p.0) == count(b, p.0))
		.cloned()
		.collect()
}

/// An instance path with its `(i)` selectors taken out: a save may write
/// a repeated block as one, or one as two.
fn without_instances(path: &str) -> String {
	let mut out = String::with_capacity(path.len());
	let mut quoted: Option<char> = None;
	let mut rest = path;
	while let Some(c) = rest.chars().next() {
		if quoted.is_none()
			&& let Some(tail) = rest.strip_prefix('(')
			&& let Some(end) = tail.find(')')
			&& end > 0
			&& tail[..end].bytes().all(|b| b.is_ascii_digit())
		{
			rest = &tail[end + 1..];
			continue;
		}
		match quoted {
			Some(q) if c == q => quoted = None,
			None if c == '"' || c == '\'' => quoted = Some(c),
			_ => {}
		}
		out.push(c);
		rest = &rest[c.len_utf8()..];
	}
	out
}

/// Blocks nested under lines refused for their value alone, mixed with
/// lines that bind, comments and blanks, so a kept line often has kept
/// lines, and nothing else, written under it.
fn kept_soup(rng: &mut Rng) -> String {
	let unit = ["\t", "  ", "    "][rng.below(3)];
	let mut out = String::new();
	let mut depth = 0usize;
	for n in 0..(1 + rng.below(12)) {
		depth = rng.below(depth + 2);
		let ind = unit.repeat(depth);
		let name = ["a", "b", "srv", "\"q.k\"", "a.b"][rng.below(5)];
		let line = match rng.below(12) {
			0 => format!("{ind}# note {n}"),
			1 => String::new(),
			2 => format!("{ind}{name}: {n}"),
			3 => format!("{ind}{name}:"),
			4 => format!("{ind}- {n}"),
			5 => format!("{ind}{name}: \"a◉Q◉b\""),
			6 => format!("{ind}{name}: C:\\Program Files"),
			7 => format!("{ind}{name}(x): [{n}"),
			8 => format!("{ind}{name}: {n}, {n}"),
			9 => format!("{ind}- name:"),
			_ => format!("{ind}{name}: [{n}"),
		};
		out.push_str(&line);
		out.push('\n');
	}
	out
}

/// A kept line reloads at the same path, under the same parent lines, after
/// a canonical save and after one that keeps lines. As written it binds
/// nothing, so each is compared by where it would bind once its value is
/// fixed (2026100213205957).
#[test]
fn kept_lines_keep_their_path() {
	let _id = test_id("ErZx5Et");
	let iters = iter_count(300);
	let seeds = seed_texts();
	let mut rng = Rng(0x5EED_1002_1320_0001);
	let mut checked = 0usize;
	// SHCL_FUZZ_DUMP: these go out too, so the cross-binding check holds the
	// other bindings to the same bytes on the same soup.
	let dump_dir = std::env::var("SHCL_FUZZ_DUMP").ok();
	let dump_max: usize = std::env::var("SHCL_FUZZ_DUMP_MAX")
		.ok()
		.and_then(|v| v.parse().ok())
		.unwrap_or(500);
	for i in 0..iters {
		let base = match rng.below(4) {
			0 => {
				let seed = rng.below(seeds.len());
				mutate(&mut rng, &seeds[seed])
			}
			1 => structural(&mut rng),
			_ => kept_soup(&mut rng),
		};
		if let Some(dir) = &dump_dir
			&& i < dump_max
		{
			let _ = std::fs::write(format!("{dir}/kept_{i:05}.shcl"), &base);
		}
		let mut texts = Vec::new();
		let Some(want) = kept_paths(&base, &mut texts) else {
			continue;
		};
		if want.is_empty() {
			continue;
		}
		checked += 1;
		let once = Document::parse(&base).to_canonical();
		let got = kept_paths(&once, &mut texts).unwrap_or_default();
		assert_eq!(
			common(&got, &want),
			common(&want, &got),
			"iteration {i}: a kept line moved in the canonical save:\n{base}--- wrote\n{once}"
		);
		// A new field changes no kept line's parent.
		let mut doc =
			Document::parse_keep_lines(&base, Strictness::Standard).unwrap_or_else(|e| e.document);
		if !doc.set_int("zz_new", 1) {
			continue;
		}
		let (text, _) = doc.to_text_keep_lines();
		let got = kept_paths(&text, &mut texts).unwrap_or_default();
		assert_eq!(
			common(&got, &want),
			common(&want, &got),
			"iteration {i}: a kept line moved in the save that keeps lines:\n{base}--- wrote\n{text}"
		);
	}
	assert!(
		checked * 4 >= iters,
		"only {checked} of {iters} inputs had a kept line to check"
	);
}

/// kept_soup with two shapes spliced in, each a third of the time, at a line
/// boundary and that line's indent. One is a block holding a line refused for
/// its name that opens a raw block, its body and fence at the line's own
/// indent or one deeper. The body is kept with its line; read as fields at the
/// line's own indent, it once let the save through. The other is a field opened from a kept line with one line under it, which
/// a remove of that line takes with it, leaving the kept line.
fn kept_soup_spliced(rng: &mut Rng) -> String {
	let soup = kept_soup(rng);
	let mut lines: Vec<String> = soup.lines().map(str::to_string).collect();
	let mut splice = |rng: &mut Rng, shape: &dyn Fn(&mut Rng, &str) -> String| {
		let at = rng.below(lines.len() + 1);
		let ind = lines.get(at).map_or(String::new(), |l| {
			l[..l.len() - l.trim_start_matches([' ', '\t']).len()].to_string()
		});
		let block = shape(rng, &ind);
		lines.insert(at, block);
	};
	if rng.below(3) == 0 {
		splice(rng, &|rng, ind| {
			let inner = format!("{ind}\t");
			let body = if rng.below(2) == 0 {
				inner.clone()
			} else {
				format!("{inner}\t")
			};
			let run = ["run: x y", "echo hi", "run: 1"][rng.below(3)];
			format!("{ind}blk:\n{inner}bad name: ~~~\n{body}{run}\n{body}~~~")
		});
	}
	if rng.below(3) == 0 {
		splice(rng, &|rng, ind| {
			format!("{ind}lz: [{}\n{ind}\tonly: 2", rng.below(9))
		});
	}
	let mut out = lines.join("\n");
	out.push('\n');
	out
}

/// The lines of a text the outcome table keeps as written, by number and
/// trimmed text, and each raw span one of them opens: its opener, and its body
/// and fence. Read from the diagnostics and the spec's lexical rules, not the
/// parser's tree.
struct KeptText {
	lines: Vec<(usize, String)>,
	spans: Vec<(String, Vec<String>)>,
}

fn kept_text(text: &str) -> KeptText {
	let doc = Document::parse(text);
	let lines: Vec<&str> = text
		.strip_prefix('\u{feff}')
		.unwrap_or(text)
		.lines()
		.collect();
	let codes: std::collections::HashMap<usize, &str> =
		doc.diagnostics().iter().map(|d| (d.line, d.code)).collect();
	let misplaced = kept_misplaced(&lines, &codes);
	let spans = raw_spans(text);
	// A body line is the block's content, whatever the parser made of it.
	let in_body = |n: usize| spans.iter().any(|&(o, c)| n > o && n <= c);
	let mut at: std::collections::BTreeSet<usize> = std::collections::BTreeSet::new();
	for d in doc.diagnostics() {
		let Some(src) = lines.get(d.line.wrapping_sub(1)) else {
			continue;
		};
		let bare = src.trim_start_matches([' ', '\t']);
		let kept = match d.code {
			"E014" => !bare.starts_with('\u{feff}'),
			"E013" | "E017" | "E019" | "E023" | "E025" | "E026" | "E027" | "E028" => true,
			"E012" | "E018" => misplaced.contains(&d.line),
			_ => false,
		};
		if kept {
			at.insert(d.line);
		}
	}
	let mut out = KeptText {
		lines: Vec::new(),
		spans: Vec::new(),
	};
	for &n in &at {
		if in_body(n) {
			continue;
		}
		let line = lines[n - 1].trim_matches(BLANKS).to_string();
		if let Some(&(_, close)) = spans.iter().find(|s| s.0 == n) {
			let body = lines[n..close.min(lines.len())]
				.iter()
				.map(|l| l.trim_matches(BLANKS).to_string())
				.collect();
			out.spans.push((line.clone(), body));
		}
		out.lines.push((n, line));
	}
	out
}

/// The blanks the format trims. `str::trim` also takes a next-line or a
/// no-break space, which are content here, so a kept line led by one compared
/// unequal to the comment a settle made of it.
const BLANKS: [char; 3] = [' ', '\t', '\r'];

/// A trimmed line with the `# ` a settle puts in front taken off. The settle
/// keeps any other blank that followed the indent, so trim again.
fn unsettled(t: &str) -> &str {
	t.strip_prefix("# ").map_or(t, |t| t.trim_matches(BLANKS))
}

/// How many of `want` a text writes, each line used once: as written, or as
/// the comment the settle makes of it.
fn missing_kept(text: &str, want: &[String]) -> Vec<String> {
	// The keep save writes a file-start BOM back; the load strips it.
	let mut lines: Vec<Option<&str>> = text
		.strip_prefix('\u{feff}')
		.unwrap_or(text)
		.lines()
		.map(|l| Some(l.trim_matches(BLANKS)))
		.collect();
	let mut missing = Vec::new();
	for w in want {
		// As written first: a kept line can start with a `#` behind some
		// other blank, and its settled form can too.
		let at = lines
			.iter()
			.position(|l| *l == Some(w.as_str()))
			.or_else(|| {
				lines
					.iter()
					.position(|l| l.is_some_and(|t| unsettled(t) == w))
			});
		match at {
			Some(k) => lines[k] = None,
			None => missing.push(w.clone()),
		}
	}
	missing
}

/// The text with the time in each setter's note left out. A step runs on
/// the document and on its reload one after the other, and each reads the
/// clock, which can tick between the two.
fn unstamped(text: &str) -> String {
	let mut out = String::with_capacity(text.len());
	for line in text.split_inclusive('\n') {
		let Some(k) = line.find("  ## commented out by shcl when setting ") else {
			out.push_str(line);
			continue;
		};
		// The stamp is the date and time, then the zone up to the colon.
		let stamp = line[k..].char_indices().map(|(i, _)| k + i).find(|&i| {
			let b = &line.as_bytes()[i..];
			b.len() > 20
				&& b[..19].iter().enumerate().all(|(j, &c)| match j {
					4 | 7 => c == b'-',
					10 => c == b' ',
					13 | 16 => c == b':',
					_ => c.is_ascii_digit(),
				}) && b[19] == b' '
		});
		match stamp.and_then(|i| line[i + 20..].find(": ").map(|e| (i, i + 20 + e))) {
			Some((from, to)) => {
				out.push_str(&line[..from]);
				out.push_str("STAMP");
				out.push_str(&line[to..]);
			}
			None => out.push_str(line),
		}
	}
	out
}

/// The kept lines a setter on `path` wrote as comments, one entry for each
/// such comment the text gained: `# LINE  ## commented out by shcl when
/// setting PATH, ...`, by design.md's table.
fn setter_comments(before: &str, after: &str, path: &str) -> Vec<String> {
	let note = format!(
		"  ## commented out by shcl when setting {}, ",
		path.replace('\n', "\\n").replace('\r', "\\r")
	);
	let lines = |text: &str| -> Vec<String> {
		text.lines()
			.filter_map(|l| {
				let t = l.trim_matches(BLANKS).strip_prefix("# ")?;
				let k = t.find(note.as_str())?;
				Some(t[..k].trim_matches(BLANKS).to_string())
			})
			.collect()
	};
	let mut had = lines(before);
	let mut out = Vec::new();
	for l in lines(after) {
		match had.iter().position(|h| *h == l) {
			Some(k) => {
				had.remove(k);
			}
			None => out.push(l),
		}
	}
	out
}

/// Where a setter on `path` may write kept lines as comments by design.md's
/// table, as 0-based positions in canonical text: the lines at the level of
/// the target's parent's block. A block written under a repeated header is
/// that block too. A path from the document has every parent, but under a
/// parent with two instances the setter may pick one that lacks the rest,
/// and a field made on the way does the same at its own level.
fn setter_reach(canon: &str, path: &str) -> std::collections::BTreeSet<usize> {
	let doc = Document::parse(canon);
	let lines: Vec<&str> = canon.lines().collect();
	let tabs = |l: &str| l.len() - l.trim_start_matches('\t').len();
	// A misplaced line has no level, and no setter writes one as a comment.
	let level = |l: &str| {
		!l.trim_matches(BLANKS).is_empty()
			&& !l[..l.len() - l.trim_start_matches([' ', '\t']).len()].contains(' ')
	};
	let mut chain: Vec<String> = doc
		.paths()
		.into_iter()
		.filter(|p| path.starts_with(&format!("{p}.")))
		.collect();
	chain.sort_by_key(String::len);
	let made = chain
		.iter()
		.position(|p| doc.count(p) > 1)
		.map_or(chain.len(), |d| d + 1);
	let mut reach = std::collections::BTreeSet::new();
	let mut blocks = vec![(0, lines.len())];
	for depth in 0..=chain.len() {
		if depth >= made {
			reach.extend(
				blocks
					.iter()
					.flat_map(|&(from, to)| from..to)
					.filter(|&k| level(lines[k]) && tabs(lines[k]) == depth),
			);
		}
		let Some(p) = chain.get(depth) else {
			break;
		};
		let heads: std::collections::HashSet<&str> = doc
			.lines(p)
			.into_iter()
			.filter(|&n| n > 0 && n <= lines.len())
			.map(|n| lines[n - 1])
			.collect();
		let mut next = Vec::new();
		for &(from, to) in &blocks {
			for k in from..to {
				// A field made on the way can go under any kept line there,
				// and takes the lines under it.
				if !level(lines[k])
					|| tabs(lines[k]) != depth
					|| (depth < made && !heads.contains(lines[k]))
				{
					continue;
				}
				let end = (k + 1..to)
					.find(|&j| level(lines[j]) && tabs(lines[j]) <= depth)
					.unwrap_or(to);
				next.push((k + 1, end));
			}
		}
		blocks = next;
	}
	reach
}

/// A line without the note a setter puts on it, and whether it had one.
fn noteless(l: &str) -> (&str, bool) {
	let t = l.trim_matches(BLANKS);
	match t
		.strip_prefix("# ")
		.and_then(|c| c.split_once("  ## commented out by shcl when setting "))
	{
		Some((line, _)) => (line.trim_matches(BLANKS), true),
		None => (unsettled(t), false),
	}
}

/// The lines of `listed` a setter on `path` wrote as comments outside its
/// reach, or dropped. Each copy outside its reach is still in the same
/// stretch without a note, and no copy is gone. A count by text cannot tell
/// a copy in the target's block from one in another. A copy in reach may
/// move, since a setter that folds two fields of the name into one moves
/// the lines with the field. No line from the target's first line to the
/// end of its last block is a bound.
fn setter_left_behind(before: &str, after: &str, path: &str, listed: &[String]) -> Vec<String> {
	if listed.is_empty() {
		return Vec::new();
	}
	let reach = setter_reach(before, path);
	let had: Vec<(&str, bool)> = before.lines().map(noteless).collect();
	let now: Vec<(&str, bool)> = after.lines().map(noteless).collect();
	let had_text: Vec<&str> = had.iter().map(|l| l.0).collect();
	let now_text: Vec<&str> = now.iter().map(|l| l.0).collect();
	let listed = |t: &str| listed.iter().any(|s| s == t);
	// A stacked list's kept lines move above the target's own line, and a
	// setter that folds two instances of it into one moves what is between.
	let lines: Vec<&str> = before.lines().collect();
	let tabs = |l: &str| l.len() - l.trim_start_matches('\t').len();
	let (mut first, mut last) = (usize::MAX, 0);
	for n in Document::parse(before).lines(path) {
		if n == 0 || n > lines.len() {
			continue;
		}
		let depth = tabs(lines[n - 1]);
		let end = (n..lines.len())
			.find(|&j| {
				let l = lines[j];
				!l.trim_matches(BLANKS).is_empty()
					&& !l[..l.len() - l.trim_start_matches([' ', '\t']).len()].contains(' ')
					&& tabs(l) <= depth
			})
			.unwrap_or(lines.len());
		(first, last) = (first.min(n - 1), last.max(end));
	}
	let own = first..last;
	let mut out: Vec<String> = Vec::new();
	for (from, to) in stretches(&had_text, &now_text, |k| {
		!listed(had_text[k]) && !own.contains(&k)
	}) {
		let mut texts: Vec<&str> = from
			.clone()
			.map(|k| had[k].0)
			.filter(|t| listed(t))
			.collect();
		texts.sort_unstable();
		texts.dedup();
		for t in texts {
			let away = from
				.clone()
				.filter(|&k| !reach.contains(&k) && !own.contains(&k) && had[k] == (t, false))
				.count();
			let still = now[to.clone()].iter().filter(|l| **l == (t, false)).count();
			if still < away {
				out.push(t.to_string());
			}
		}
	}
	// A copy inside the target's own block can be raw body text the setter
	// replaces, so only the copies outside it are owed.
	for t in had_text.iter().filter(|t| listed(t)) {
		let away = had_text
			.iter()
			.enumerate()
			.filter(|&(k, l)| l == t && !own.contains(&k))
			.count();
		let still = now_text.iter().filter(|l| *l == t).count();
		if still < away && !out.iter().any(|o| o == t) {
			out.push((*t).to_string());
		}
	}
	out
}

/// The lines of canonical text a remove of `path` takes by design.md's
/// table: each line the path names, which is the field's own line or the kept
/// line written in its place, and every line after it written deeper, up to
/// the first that is not. A misplaced line keeps its own indent, with a space
/// in it, and belongs with the next line written with tabs, so it is taken
/// only when that one is. Read from the text, so the oracle is not the code
/// that drops. Each line comes with where it sat, as a 0-based position.
fn taken_lines(canon: &str, path: &str) -> Vec<(usize, String)> {
	let lines: Vec<&str> = canon.lines().collect();
	let tabs = |l: &str| l.len() - l.trim_start_matches('\t').len();
	let mut out = Vec::new();
	for n in Document::parse(canon).lines(path) {
		if n == 0 || n > lines.len() {
			continue;
		}
		let depth = tabs(lines[n - 1]);
		out.push((n - 1, lines[n - 1].trim_matches(BLANKS).to_string()));
		let mut waiting = Vec::new();
		for (k, l) in lines.iter().enumerate().skip(n) {
			// Blank as the load reads it: a kept line can be all other space.
			if l.trim_matches([' ', '\t', '\r']).is_empty() {
				continue;
			}
			if l[..l.len() - l.trim_start_matches([' ', '\t']).len()].contains(' ') {
				waiting.push((k, l.trim_matches(BLANKS).to_string()));
				continue;
			}
			if tabs(l) <= depth {
				break;
			}
			out.append(&mut waiting);
			out.push((k, l.trim_matches(BLANKS).to_string()));
		}
	}
	out
}

/// Where canonical text's footer starts, as a 1-based line number: the first
/// line at no indent past the last field's line. The load keeps everything
/// from there on as the document's own lines, not a field's. Canonical text
/// writes a field's raw body deeper than the field, so no body line is at no
/// indent, and a kept line's body goes out under the kept line.
fn footer_start(canon: &str) -> usize {
	let doc = Document::parse(canon);
	let lines: Vec<&str> = canon.lines().collect();
	let last = doc
		.paths()
		.iter()
		.flat_map(|p| doc.lines(p))
		.max()
		.unwrap_or(0);
	(last + 1..=lines.len())
		.find(|&n| {
			let l = lines[n - 1];
			!l.trim_matches([' ', '\t', '\r']).is_empty() && !l.starts_with([' ', '\t'])
		})
		.unwrap_or(lines.len() + 1)
}

/// The footer of canonical text, each line as its depth in tabs and its
/// text after them. A misplaced line is written with its own indent, and the
/// dedup compares that too, so the spaces in it stay.
fn footer(canon: &str) -> Vec<(usize, &str)> {
	let lines: Vec<&str> = canon.lines().collect();
	lines[(footer_start(canon) - 1).min(lines.len())..]
		.iter()
		.map(|l| {
			(
				l.len() - l.trim_start_matches('\t').len(),
				l.trim_start_matches('\t').trim_end_matches(BLANKS),
			)
		})
		.filter(|l| !l.1.is_empty())
		.collect()
}

/// The kept lines of a layer that a merge onto `before` skips by design.md's
/// table: a footer line the base's footer already has, at the same depth. A
/// field-like one with a deeper one after it goes in whole, so neither of the
/// two is skipped. Read from both canonical texts, where the footer is written
/// last and each line at its depth.
fn footer_skips(before: &str, layer: &str) -> Vec<String> {
	let had = footer(before);
	let canon = Document::parse(layer).to_canonical();
	let theirs = footer(&canon);
	let fields: Vec<usize> = (0..theirs.len())
		.filter(|&k| !theirs[k].1.starts_with('#'))
		.collect();
	let mut whole = vec![false; theirs.len()];
	for w in fields.windows(2) {
		if theirs[w[1]].0 > 0 {
			whole[w[0]] = true;
			whole[w[1]] = true;
		}
	}
	(0..theirs.len())
		.filter(|&k| !theirs[k].1.starts_with('#') && !whole[k] && had.contains(&theirs[k]))
		.map(|k| theirs[k].1.trim_matches(BLANKS).to_string())
		.collect()
}

/// Canonical text's trimmed lines, with a raw block's fence joined to the
/// `name:` line above it. The fence goes on the name's line only after an
/// empty field of the same name, so a remove that takes that field moves it
/// down, which writes no new line.
fn fences_joined(canon: &str) -> Vec<String> {
	let tabs = |l: &str| l.len() - l.trim_start_matches('\t').len();
	let fence = |l: &str| {
		["```", "~~~"]
			.iter()
			.any(|f| l.trim_start_matches('\t').starts_with(f))
	};
	let mut out: Vec<String> = Vec::new();
	let mut lines = canon.lines().peekable();
	while let Some(l) = lines.next() {
		let t = l.trim_matches(BLANKS);
		match lines.peek() {
			Some(&f) if t.ends_with(':') && fence(f) && tabs(f) == tabs(l) + 1 => {
				out.push(format!("{t} {}", f.trim_matches(BLANKS)));
				lines.next();
			}
			_ => out.push(t.to_string()),
		}
	}
	out
}

/// The leaves of `base` a merge of `over` replaces, each as a path that names
/// every parent by its instance, `a(0).b(2).c`. A layer's instance merges
/// into the base instance with the same name and value, so a parent counts
/// only when exactly one base instance reads the same. A name the layer has
/// only as leaves, where the base has it with no children, is replaced. Read
/// from the two documents' paths and values, not from the merge.
fn replaced_leaves(base: &Document, over: &Document, at: (&str, &str), out: &mut Vec<String>) {
	let join = |pre: &str, seg: &str| {
		if pre.is_empty() {
			seg.to_string()
		} else {
			format!("{pre}.{seg}")
		}
	};
	let mut names = over.children(at.1);
	let mut seen = std::collections::HashSet::new();
	names.retain(|n| seen.insert(n.clone()));
	for name in names {
		let seg = quote_segment(&name);
		let (bn, on) = (join(at.0, &seg), join(at.1, &seg));
		let instances = base.count(&bn);
		if instances == 0 {
			continue;
		}
		if over.children(&on).is_empty() && base.children(&bn).is_empty() {
			out.push(bn);
			continue;
		}
		for i in 0..over.count(&on) {
			let oi = format!("{on}({i})");
			let o = over.read_string(&oi);
			let hits: Vec<String> = (0..instances)
				.map(|k| format!("{bn}({k})"))
				.filter(|b| {
					let r = base.read_string(b);
					r.status == o.status && r.value == o.value && r.raw == o.raw
				})
				.collect();
			if let [b] = hits.as_slice() {
				replaced_leaves(base, over, (b, &oi), out);
			}
		}
	}
}

/// What a merge of a layer may take from the base by design.md's table, read
/// from the base's canonical text. A leaf the layer replaces takes the lines
/// a remove of it takes from the reparsed text, and of those the settled kept
/// lines go, each listed with its `# ` taken off. The reparse reads a settled
/// line as a plain comment, so every comment there is listed. `near` has
/// those lines and every other line between the field lines either side of
/// such a leaf, as 0-based positions, since a merge moves a replaced leaf's
/// lines with it, to where the first leaf of that name was.
struct LeafCut {
	had: String,
	near: std::collections::BTreeSet<usize>,
	settled: Vec<String>,
}

fn replaced_leaf_lines(before: &str, layer: &str) -> LeafCut {
	let base = Document::parse(before);
	let over = Document::parse(&Document::parse(layer).to_canonical());
	let had = base.to_canonical();
	let mut leaves = Vec::new();
	replaced_leaves(&base, &over, ("", ""), &mut leaves);
	let mut cut = std::collections::BTreeSet::new();
	let mut near = std::collections::BTreeSet::new();
	let mut settled = Vec::new();
	let lines: Vec<&str> = had.lines().collect();
	let fields: std::collections::BTreeSet<usize> = base
		.paths()
		.iter()
		.flat_map(|p| base.lines(p))
		.filter(|&n| n > 0)
		.collect();
	for p in leaves {
		for n in base.lines(&p).into_iter().filter(|&n| n > 0) {
			let from = fields.range(..n).next_back().copied().unwrap_or(0);
			let to = fields
				.range(n + 1..)
				.next()
				.copied()
				.unwrap_or(lines.len() + 1);
			near.extend(from..to - 1);
		}
		let mut less = base.clone();
		less.remove(&p);
		let left = less.to_canonical();
		let mut left = left
			.lines()
			.map(|l| unsettled(l.trim_matches(BLANKS)))
			.peekable();
		let mut gone = Vec::new();
		for (k, l) in lines.iter().enumerate() {
			if left.peek() == Some(&unsettled(l.trim_matches(BLANKS))) {
				left.next();
			} else {
				gone.push(k);
			}
		}
		// A remove that wrote a line of its own leaves no plain answer, so
		// nothing is excused.
		if left.next().is_some() {
			continue;
		}
		for k in gone {
			if !cut.insert(k) {
				continue;
			}
			if let Some(t) = lines[k].trim_matches(BLANKS).strip_prefix("# ") {
				settled.push(t.trim_matches(BLANKS).to_string());
			}
		}
	}
	near.extend(cut);
	LeafCut { had, near, settled }
}

/// The copies of a line `cut` lists that sat away from the replaced leaves
/// and are missing from the same place in `merged`. Two lines of one text are
/// one entry in a count, so a merge that kept the leaf's copy and dropped
/// another would pass one. A place is the stretch between the nearest lines
/// either side that each text writes once, in the same order in both, so a
/// line may move within it. A copy is a comment or a kept line. The lines
/// near a replaced leaf move with it, so they are neither copies nor bounds.
fn left_behind(cut: &LeafCut, merged: &str) -> Vec<String> {
	if cut.settled.is_empty() {
		return Vec::new();
	}
	let raw: Vec<&str> = cut.had.lines().collect();
	let had: Vec<&str> = raw
		.iter()
		.map(|l| unsettled(l.trim_matches(BLANKS)))
		.collect();
	let now: Vec<&str> = merged
		.lines()
		.map(|l| unsettled(l.trim_matches(BLANKS)))
		.collect();
	let kept: std::collections::HashSet<usize> =
		kept_text(&cut.had).lines.iter().map(|l| l.0 - 1).collect();
	let listed = |t: &str| cut.settled.iter().any(|s| s == t);
	let copy = |k: usize| {
		!cut.near.contains(&k)
			&& listed(had[k])
			&& (raw[k].trim_matches(BLANKS).starts_with('#') || kept.contains(&k))
	};
	let mut out = Vec::new();
	for (from, to) in stretches(&had, &now, |k| !cut.near.contains(&k) && !listed(had[k])) {
		let mut need: Vec<&str> = from.filter(|&k| copy(k)).map(|k| had[k]).collect();
		for l in &now[to] {
			if let Some(k) = need.iter().position(|t| t == l) {
				need.remove(k);
			}
		}
		out.extend(need.into_iter().map(str::to_string));
	}
	out
}

/// Two texts cut into the same stretches, as half-open ranges of each. A
/// bound is a line `bound` allows that each text writes once, and the
/// stretches are cut at the longest run of bounds in the same order in both.
/// The lines between two bounds may move among themselves.
fn stretches(
	had: &[&str],
	now: &[&str],
	bound: impl Fn(usize) -> bool,
) -> Vec<(std::ops::Range<usize>, std::ops::Range<usize>)> {
	let mut seen: std::collections::HashMap<&str, (usize, usize)> =
		std::collections::HashMap::new();
	for l in had {
		seen.entry(l).or_default().0 += 1;
	}
	for l in now {
		seen.entry(l).or_default().1 += 1;
	}
	let pairs: Vec<(usize, usize)> = (0..had.len())
		.filter(|&k| !had[k].is_empty() && bound(k) && seen[had[k]] == (1, 1))
		.filter_map(|k| now.iter().position(|l| *l == had[k]).map(|j| (k, j)))
		.collect();
	let mut best = vec![(1usize, usize::MAX); pairs.len()];
	for x in 0..pairs.len() {
		for y in 0..x {
			if pairs[y].1 < pairs[x].1 && best[y].0 + 1 > best[x].0 {
				best[x] = (best[y].0 + 1, y);
			}
		}
	}
	let mut run = Vec::new();
	let mut at = (0..pairs.len()).max_by_key(|&x| best[x].0);
	while let Some(x) = at {
		run.push(pairs[x]);
		at = (best[x].1 != usize::MAX).then_some(best[x].1);
	}
	run.reverse();
	let mut edges = vec![(0, 0)];
	edges.extend(run.iter().map(|&(k, j)| (k + 1, j + 1)));
	edges.push((had.len() + 1, now.len() + 1));
	edges
		.windows(2)
		.map(|w| (w[0].0..w[1].0 - 1, w[0].1..w[1].1 - 1))
		.collect()
}

/// The copies of a line a remove took, by text, that sat away from it and
/// are missing from the same stretch of `after`. A count by text cannot tell
/// the taken copy from another. `taken` is where the taken lines sat, as
/// 0-based positions in `before`. The comments right above and below them
/// may go with the target, so they are neither copies nor bounds. Nothing
/// between the field lines either side of the target is a bound, and no
/// misplaced line is, since one beside the target moves down to just above
/// the next field line. A misplaced copy may move down the same way.
fn remove_left_behind(
	before: &str,
	after: &str,
	taken: &[usize],
	listed: &[String],
) -> Vec<String> {
	if listed.is_empty() {
		return Vec::new();
	}
	let raw: Vec<&str> = before.lines().collect();
	let had: Vec<&str> = raw
		.iter()
		.map(|l| unsettled(l.trim_matches(BLANKS)))
		.collect();
	let now: Vec<&str> = after
		.lines()
		.map(|l| unsettled(l.trim_matches(BLANKS)))
		.collect();
	let doc = Document::parse(before);
	let fields: std::collections::BTreeSet<usize> = doc
		.paths()
		.iter()
		.flat_map(|p| doc.lines(p))
		.filter(|&n| n > 0)
		.map(|n| n - 1)
		.collect();
	let mut gone: std::collections::BTreeSet<usize> = taken.iter().copied().collect();
	let note = |k: usize| raw[k].trim_matches(BLANKS).starts_with('#');
	let blank = |k: usize| raw[k].trim_matches(BLANKS).is_empty();
	let mut near = gone.clone();
	for &k in &gone {
		let to = fields
			.range(k + 1..)
			.find(|f| !gone.contains(f))
			.copied()
			.unwrap_or(raw.len());
		near.extend(k..to);
		// The lines above it back to the field line before are its leads, and
		// the remove leaves them with a misplaced one moved below the block.
		let from = fields.range(..k).next_back().map_or(0, |f| f + 1);
		near.extend(from..k);
	}
	// A settled line and a comment of one text are one line of canonical
	// text, so the comments either side may be the target's own.
	let mut theirs = Vec::new();
	for &k in &gone {
		let mut up = k;
		while up > 0 && !gone.contains(&(up - 1)) && (note(up - 1) || blank(up - 1)) {
			up -= 1;
			theirs.push(up);
		}
		let mut down = k + 1;
		while down < raw.len() && !gone.contains(&down) && (note(down) || blank(down)) {
			theirs.push(down);
			down += 1;
		}
	}
	near.extend(theirs.iter().copied());
	gone.extend(theirs);
	let kept: std::collections::HashSet<usize> =
		kept_text(before).lines.iter().map(|l| l.0 - 1).collect();
	let listed = |t: &str| listed.iter().any(|s| s == t);
	let copy = |k: usize| !gone.contains(&k) && listed(had[k]) && (note(k) || kept.contains(&k));
	// A misplaced line beside the target moves down, past lines that stay.
	let misplaced = |k: usize| {
		raw[k][..raw[k].len() - raw[k].trim_start_matches([' ', '\t']).len()].contains(' ')
	};
	let mut out = Vec::new();
	// A misplaced copy can go down past its stretch, to where a reload files
	// it, so it is looked for from there to the end, each line found once.
	let mut found = vec![false; now.len()];
	for (from, to) in stretches(&had, &now, |k| {
		!near.contains(&k) && !listed(had[k]) && !misplaced(k)
	}) {
		let (low, mut need): (Vec<usize>, Vec<usize>) =
			from.filter(|&k| copy(k)).partition(|&k| misplaced(k));
		for l in &now[to.clone()] {
			if let Some(k) = need.iter().position(|&t| had[t] == *l) {
				need.remove(k);
			}
		}
		for k in low {
			match (to.start..now.len()).find(|&j| !found[j] && now[j] == had[k]) {
				Some(j) => found[j] = true,
				None => need.push(k),
			}
		}
		out.extend(need.into_iter().map(|k| had[k].to_string()));
	}
	out
}

/// The misplaced lines between canonical text's last field line and its
/// footer, trimmed. No binding line follows them, so the load keeps them as
/// the document's own lines too, and a merge can write one after the base's
/// footer, where the settle makes a comment of it.
fn misplaced_tail(canon: &str) -> Vec<&str> {
	let doc = Document::parse(canon);
	let lines: Vec<&str> = canon.lines().collect();
	let last = doc
		.paths()
		.iter()
		.flat_map(|p| doc.lines(p))
		.max()
		.unwrap_or(0);
	let bodies = raw_spans(canon);
	(last + 1..footer_start(canon).min(lines.len() + 1))
		.filter(|&n| !bodies.iter().any(|&(o, c)| n > o && n <= c))
		.map(|n| lines[n - 1])
		.filter(|l| l[..l.len() - l.trim_start_matches([' ', '\t']).len()].contains(' '))
		.map(|l| l.trim_matches(BLANKS))
		.collect()
}

/// The footer lines the dedup skipped that `merged` wrote anyway, beyond what
/// the base's footer and the layer's account for. Such a line is in the wrong
/// place, so the merge may have dropped some other copy of it, which a count
/// by text would not show.
fn footer_piled(before: &str, layer: &str, merged: &str, skipped: &[String]) -> Vec<String> {
	let canon = Document::parse(layer).to_canonical();
	let count = |text: &str, t: &str| {
		let foot = footer(text)
			.iter()
			.filter(|l| unsettled(l.1.trim_matches(BLANKS)) == t)
			.count();
		let tail = misplaced_tail(text)
			.iter()
			.filter(|l| unsettled(l) == t)
			.count();
		foot + tail
	};
	let mut out: Vec<String> = Vec::new();
	for t in skipped {
		if out.contains(t) {
			continue;
		}
		let skips = skipped.iter().filter(|s| *s == t).count();
		if count(merged, t) + skips > count(before, t) + count(&canon, t) {
			out.push(t.clone());
		}
	}
	out
}

// A misplaced line past the layer's last field comes in after the base's
// footer as a comment. It is the layer's own line, not a copy of the footer
// line the dedup skipped.
#[test]
fn a_misplaced_tail_line_is_no_skipped_copy() {
	let _id = test_id("ErsPRww");
	let (base, layer) = ("a: 1\n- name:\n", "q:\n\t- 5\n    - name:\n- name:\n");
	let mut doc = Document::parse(base);
	let before = doc.to_canonical();
	let skipped = footer_skips(&before, layer);
	assert_eq!(skipped, ["- name:"]);
	doc.merge(&Document::parse(layer));
	let after = doc.to_canonical();
	assert_eq!(after, "a: 1\nq: [5]\n- name:\n# - name:\n");
	assert!(footer_piled(&before, layer, &after, &skipped).is_empty());
	let piled = "a: 1\nq: [5]\n- name:\n# - name:\n- name:\n";
	assert_eq!(footer_piled(&before, layer, piled, &skipped), skipped);
}

// The two merge exceptions in the property go by where a line sits, and a
// leaf under a repeated parent counts.
#[test]
fn merge_exceptions_go_by_position() {
	let _id = test_id("ErpR2rr");
	let mut doc = Document::parse("s: u\n\tb: 1\ns: v\n\tx: 0\n\t\tc: 2\n\t  a: 5\n\tb: 1\n");
	assert_eq!(doc.remove("s(v).x.c"), 1);
	let before = doc.to_canonical();
	let leaf = replaced_leaf_lines(&before, "s: v\n\tb: 9\n");
	assert_eq!(leaf.settled, ["a: 5"]);
	doc.merge(&Document::parse("s: v\n\tb: 9\n"));
	assert_eq!(doc.to_canonical(), "s: u\n\tb: 1\ns: v\n\tx: 0\n\tb: 9\n");
	assert_eq!(
		left_behind(&leaf, &doc.to_canonical()),
		Vec::<String>::new()
	);
	// The leaf's copy goes and the other stays. Keeping the leaf's and
	// dropping the other writes the same lines, so only the place shows it.
	let before = "x: 0\n# a: 5\nb: 1\ny: 2\n# a: 5\nz: 3\n";
	let leaf = replaced_leaf_lines(before, "b: 9\n");
	assert_eq!(leaf.settled, ["a: 5"]);
	let mut doc = Document::parse(before);
	doc.merge(&Document::parse("b: 9\n"));
	assert_eq!(doc.to_canonical(), "x: 0\nb: 9\ny: 2\n# a: 5\nz: 3\n");
	assert_eq!(
		left_behind(&leaf, &doc.to_canonical()),
		Vec::<String>::new()
	);
	let swapped = "x: 0\n# a: 5\nb: 9\ny: 2\nz: 3\n";
	assert!(missing_kept(swapped, &["a: 5".to_string()]).is_empty());
	assert_eq!(left_behind(&leaf, swapped), ["a: 5"]);
	// A footer line the base has is skipped, and the layer's other copy of it
	// comes in under its field.
	let (before, layer) = ("a: 1\nbad name: 1\n", "c: 2\n\tbad name: 1\nbad name: 1\n");
	let skipped = footer_skips(before, layer);
	assert_eq!(skipped, ["bad name: 1"]);
	let mut doc = Document::parse(before);
	doc.merge(&Document::parse(layer));
	let after = doc.to_canonical();
	assert_eq!(after, "a: 1\nc: 2\n\tbad name: 1\nbad name: 1\n");
	assert_eq!(
		footer_piled(before, layer, &after, &skipped),
		Vec::<String>::new()
	);
	assert_eq!(
		footer_piled(
			before,
			layer,
			"a: 1\nc: 2\nbad name: 1\nbad name: 1\n",
			&skipped
		),
		["bad name: 1"]
	);
}

// The property's remove and setter steps also go by where a line sits. Each
// case is the library's answer, then the same lines with the wrong copy taken,
// which a count by text passes.
#[test]
fn remove_and_setter_exceptions_go_by_position() {
	let _id = test_id("ErqSBCw");
	let base = "x: 0\na: [1\ny: 1\na: [1\n\tb: 2\nz: 3\n";
	let mut doc =
		Document::parse_keep_lines(base, Strictness::Standard).unwrap_or_else(|e| e.document);
	let before = doc.to_canonical();
	let taken = taken_lines(&before, "a");
	assert_eq!(taken, [(3, "a: [1".to_string()), (4, "b: 2".to_string())]);
	assert_eq!(doc.remove("a"), 1);
	let after = doc.to_canonical();
	assert_eq!(after, "x: 0\na: [1\ny: 1\nz: 3\n");
	let listed = ["a: [1".to_string()];
	assert!(remove_left_behind(&before, &after, &[3, 4], &listed).is_empty());
	let swapped = "x: 0\ny: 1\na: [1\nz: 3\n";
	assert!(missing_kept(swapped, &listed).is_empty());
	assert_eq!(
		remove_left_behind(&before, swapped, &[3, 4], &listed),
		listed
	);
	// A setter writes only its own block's kept lines as comments.
	let base = "x:\n\ta: [1\n\tq: 0\ny:\n\ta: [1\n\tq: 0\n";
	let mut doc =
		Document::parse_keep_lines(base, Strictness::Standard).unwrap_or_else(|e| e.document);
	let before = doc.to_canonical();
	assert_eq!(setter_reach(&before, "x.a"), [1, 2].into_iter().collect());
	assert!(doc.set_int("x.a", 7));
	let after = doc.to_canonical();
	let note = "  ## commented out by shcl when setting x.a, STAMP: E019 malformed array, no closing ']' on the line";
	assert_eq!(
		unstamped(&after),
		format!("x:\n\t# a: [1{note}\n\ta: 7\n\tq: 0\ny:\n\ta: [1\n\tq: 0\n")
	);
	let listed = setter_comments(&before, &after, "x.a");
	assert_eq!(listed, ["a: [1"]);
	assert!(setter_left_behind(&before, &after, "x.a", &listed).is_empty());
	let swapped = format!("x:\n\ta: [1\n\ta: 7\n\tq: 0\ny:\n\t# a: [1{note}\n\tq: 0\n");
	assert_eq!(setter_comments(&before, &swapped, "x.a"), listed);
	assert!(missing_kept(&swapped, &listed).is_empty());
	assert_eq!(
		setter_left_behind(&before, &swapped, "x.a", &listed),
		listed
	);
}

// A misplaced line beside a removed field goes down past the kept lines
// that stay, as a reload files it, and the property allows that for a copy
// of the field's own line too. It still finds one that went up or is gone.
#[test]
fn a_misplaced_copy_moves_down() {
	let _id = test_id("ErsETOT");
	let base = "k:\n\tj: 1\n  a:\n\tb: [8] x\n\t\ta:\n";
	let mut doc =
		Document::parse_keep_lines(base, Strictness::Standard).unwrap_or_else(|e| e.document);
	let before = doc.to_canonical();
	assert_eq!(before, base);
	let taken = taken_lines(&before, "k.b.a");
	assert_eq!(taken, [(4, "a:".to_string())]);
	assert_eq!(doc.remove("k.b.a"), 1);
	let after = doc.to_canonical();
	assert_eq!(after, "k:\n\tj: 1\n\tb: [8] x\n  a:\n");
	assert_eq!(
		Document::parse("k:\n\tj: 1\n  a:\n\tb: [8] x\n").to_canonical(),
		after
	);
	let listed = ["a:".to_string()];
	assert!(remove_left_behind(&before, &after, &[4], &listed).is_empty());
	for wrong in ["  a:\nk:\n\tj: 1\n\tb: [8] x\n", "k:\n\tj: 1\n\tb: [8] x\n"] {
		assert_eq!(remove_left_behind(&before, wrong, &[4], &listed), listed);
	}
}

/// After any edits, every kept line no edit's target took is in the saved
/// text, or the save refuses (design.md, Kept lines under edits). Also: an
/// edit raises the lost count only where the table says, and a remove adds
/// no line. What a merge, a remove or a setter takes is held by where it sat,
/// since a count by text passes one that took the wrong copy.
#[test]
fn kept_lines_survive_edits() {
	let _id = test_id("EreT6dh");
	let iters = iter_count(300);
	let seeds = seed_texts();
	let mut rng = Rng(0x5EED_1003_0731_0001);
	let (mut with_kept, mut removes_near) = (0usize, 0usize);
	// SHCL_FUZZ_DUMP: each input with the edits that took, refused or not,
	// so the cross-binding check holds the other three to the same exit code
	// and bytes. A merge has no CLI form, so those are not dumped.
	let dump_dir = std::env::var("SHCL_FUZZ_DUMP")
		.ok()
		.map(|d| format!("{d}/kept"));
	if let Some(dir) = &dump_dir {
		std::fs::create_dir_all(dir).unwrap_or_else(|e| panic!("dump dir {dir}: {e}"));
	}
	let mut dumped = 0usize;
	for i in 0..iters {
		let base = match rng.below(4) {
			0 => {
				let seed = rng.below(seeds.len());
				mutate(&mut rng, &seeds[seed])
			}
			1 => structural(&mut rng),
			_ => kept_soup_spliced(&mut rng),
		};
		let mut doc =
			Document::parse_keep_lines(&base, Strictness::Standard).unwrap_or_else(|e| e.document);
		let found = kept_text(&base);
		let mut want: Vec<String> = found.lines.iter().map(|l| l.1.clone()).collect();
		let mut spans = found.spans;
		with_kept += usize::from(!want.is_empty());
		let mut lost = Document::parse(&base).lost_count();
		let mut log = format!("base: {base:?}\n");
		let mut ops = String::new();
		let mut merged = false;
		for step in 0..rng.below(4) {
			let paths = doc.paths();
			let path = if paths.is_empty() || rng.below(4) == 0 {
				format!("z{step}")
			} else {
				paths[rng.below(paths.len())].clone()
			};
			let before = doc.to_canonical();
			let op = rng.below(15);
			let (took, line) = match op {
				0 => (doc.set_int(&path, 7), format!("int\t{path}\t7")),
				1 => (
					doc.set_string(&path, "new text"),
					format!("string\t{path}\tnew text"),
				),
				2 => (
					doc.set_literal(&path, "9, 8"),
					format!("literal\t{path}\t9, 8"),
				),
				3 => (
					doc.set_comment(&path, "added"),
					format!("comment\t{path}\tadded"),
				),
				4 => (
					doc.clear_comments(&path) > 0,
					format!("clear-comments\t{path}"),
				),
				5 => (doc.set_empty(&path), format!("empty\t{path}")),
				6 => (
					doc.set_raw(&path, "one\n\ttwo", "sh"),
					format!("raw\t{path}\tsh\tone\\n\\ttwo"),
				),
				7 => {
					doc.set_banner(true);
					(true, "banner\ton".to_string())
				}
				8 => {
					doc.set_banner(false);
					(true, "banner\toff".to_string())
				}
				9 => (
					doc.set_int_default(&path, 5),
					format!("int-default\t{path}\t5"),
				),
				10 => {
					let layer = kept_soup(&mut rng);
					let over = Document::parse(&layer);
					lost += over.lost_count();
					let theirs = kept_text(&layer);
					// The table's two merge exceptions, each a line picked by
					// where it sits and taken off the expected lines once.
					// Copies of one text are one entry there, so the merged
					// text is held to those places below.
					let mut theirs_lines: Vec<String> =
						theirs.lines.into_iter().map(|l| l.1).collect();
					let skipped = footer_skips(&before, &layer);
					for t in &skipped {
						if let Some(k) = theirs_lines.iter().rposition(|l| l == t) {
							theirs_lines.remove(k);
						}
					}
					want.extend(theirs_lines);
					let leaf = replaced_leaf_lines(&before, &layer);
					for t in &leaf.settled {
						if let Some(k) = want.iter().position(|w| w == t) {
							want.remove(k);
							spans.retain(|s| s.0 != *t);
						}
					}
					spans.extend(theirs.spans);
					doc.merge(&over);
					merged = true;
					log.push_str(&format!("merge {layer:?}\n"));
					let after = doc.to_canonical();
					let moved = left_behind(&leaf, &after);
					assert!(
						moved.is_empty(),
						"iteration {i}: the merge moved or dropped {moved:?} from beside a leaf it replaced:\n{log}--- before\n{before}--- after\n{after}"
					);
					let piled = footer_piled(&before, &layer, &after, &skipped);
					assert!(
						piled.is_empty(),
						"iteration {i}: the merge wrote footer line(s) {piled:?} its dedup skips:\n{log}--- before\n{before}--- after\n{after}"
					);
					(false, String::new())
				}
				_ => {
					let taken = taken_lines(&before, &path);
					let near = !want.is_empty();
					let n = doc.remove(&path);
					if n > 0 {
						removes_near += usize::from(near);
						// Each taken line comes off the expected lines once, by
						// text, so the other copies are held to their places.
						let mut listed = Vec::new();
						// A raw body line is no kept line, whatever its text.
						let bodies = raw_spans(&before);
						for (k, t) in &taken {
							if bodies.iter().any(|&(o, c)| *k + 1 > o && *k < c) {
								continue;
							}
							// As written first: a kept line can start with a `#`
							// behind some other blank.
							let at = want
								.iter()
								.position(|w| w == t)
								.or_else(|| want.iter().position(|w| w == unsettled(t)));
							if let Some(k) = at {
								want.remove(k);
								listed.push(unsettled(t).to_string());
							}
							spans.retain(|s| s.0 != *t && s.0 != unsettled(t));
						}
						let after = doc.to_canonical();
						let at: Vec<usize> = taken.iter().map(|l| l.0).collect();
						let moved = remove_left_behind(&before, &after, &at, &listed);
						assert!(
							moved.is_empty(),
							"iteration {i}: removing {path:?} moved or dropped {moved:?}, a copy of a line it took:\n{log}--- before\n{before}--- after\n{after}"
						);
					}
					(n > 0, format!("remove\t{path}"))
				}
			};
			if took {
				ops.push_str(&line);
				ops.push('\n');
			}
			// A setter writes the kept line heading its target as a comment
			// with a note naming the path, and it is a comment from then on.
			if took && matches!(op, 0 | 1 | 2 | 5 | 6 | 9) {
				let after = doc.to_canonical();
				let mut listed = Vec::new();
				for w in setter_comments(&before, &after, &path) {
					if let Some(k) = want.iter().position(|x| *x == w) {
						want.remove(k);
						listed.push(w);
					}
				}
				let moved = setter_left_behind(&before, &after, &path, &listed);
				assert!(
					moved.is_empty(),
					"iteration {i}: setting {path:?} commented out or dropped {moved:?} away from its block:\n{log}op {op} at {path:?}\n--- before\n{before}--- after\n{after}"
				);
			}
			log.push_str(&format!("op {op} at {path:?}\n"));
			// A list no text loads back counts its items lost, so the save
			// refuses it (2026100511210900), and the steps after it go
			// unchecked.
			if list_after_empty(&doc) {
				assert!(
					doc.lost_count() > lost,
					"iteration {i}: a list no text loads back saves:\n{log}"
				);
				break;
			}
			// (b) Only the table's own losses: none outside a merge's.
			assert_eq!(
				doc.lost_count(),
				lost,
				"iteration {i}: op {op} raised the lost count:\n{log}--- before\n{before}--- after\n{}",
				doc.to_canonical()
			);
			// (c) A remove only takes lines away.
			if op > 10 && took {
				// A settle can turn a line into a comment, or back.
				let had: std::collections::HashSet<String> = fences_joined(&before)
					.into_iter()
					.map(|l| unsettled(&l).to_string())
					.collect();
				let after = doc.to_canonical();
				let new: Vec<String> = fences_joined(&after)
					.into_iter()
					.filter(|t| !t.is_empty() && !had.contains(unsettled(t)))
					.collect();
				assert!(
					new.is_empty(),
					"iteration {i}: removing {path:?} wrote {new:?}:\n{log}--- before\n{before}--- after\n{after}"
				);
			}
		}
		if let Some(dir) = &dump_dir
			&& !merged
			&& dumped < 100
		{
			std::fs::write(format!("{dir}/{i:05}.shcl"), &base).expect("dump input");
			std::fs::write(format!("{dir}/{i:05}.ops"), &ops).expect("dump ops");
			dumped += 1;
		}
		// (a) Every kept line no target took is written, or the save refuses.
		let canon = doc.to_canonical();
		let (keep, kept) = doc.to_text_keep_lines();
		let saves = [
			("canonical", canon, doc.lost_count() > 0),
			("keep", keep, !kept && doc.lost_count() > 0),
		];
		for (which, text, refused) in saves {
			if refused {
				continue;
			}
			let missing = missing_kept(&text, &want);
			assert!(
				missing.is_empty(),
				"iteration {i}: the {which} save lost kept line(s) {missing:?}:\n{log}--- wrote\n{text}"
			);
			let written: Vec<&str> = text
				.strip_prefix('\u{feff}')
				.unwrap_or(&text)
				.lines()
				.map(|t| t.trim_matches(BLANKS))
				.collect();
			for (opener, body) in &spans {
				let whole: Vec<&str> = std::iter::once(opener.as_str())
					.chain(body.iter().map(String::as_str))
					.collect();
				if written.windows(whole.len()).any(|w| w == whole.as_slice()) {
					continue;
				}
				panic!(
					"iteration {i}: the {which} save split the raw block {whole:?}:\n{log}--- wrote\n{text}"
				);
			}
		}
	}
	assert!(
		with_kept * 4 >= iters,
		"only {with_kept} of {iters} inputs had a kept line"
	);
	assert!(
		removes_near * 20 >= iters,
		"only {removes_near} of {iters} inputs removed a field beside a kept line"
	);
}

/// A config like tidy()'s where each line ends in LF or CRLF on its own, all
/// one kind, alternating (a tie when the count is even) or at random, and a
/// third of them with no final newline. Every line is written the way the
/// canonical form never writes it, with a blank before the colon or at the
/// end, so a line written fresh cannot pass for one kept or changed. Raw body
/// lines and closing fences cannot be written that way, so they come back
/// apart and go unchecked.
fn mixed_eol(rng: &mut Rng) -> (String, Vec<String>) {
	let unit = ["\t", "  ", "    "][rng.below(3)];
	let mut lines: Vec<String> = Vec::new();
	let mut raw: Vec<String> = Vec::new();
	let mut depth = 0usize;
	for n in 0..(1 + rng.below(14)) {
		if depth > 0 && rng.below(4) == 0 {
			depth -= 1;
		}
		let ind = unit.repeat(depth);
		let inner = unit.repeat(depth + 1);
		let name = format!("{}{}", ["k", "Srv", "port", "x_y"][rng.below(4)], n);
		match rng.below(10) {
			0 => lines.push(format!("{ind}# note {n} ")),
			1 => lines.push(String::new()),
			2 => {
				depth += 1;
				lines.push(format!("{ind}{name} :"));
			}
			3 => lines.push(format!("{ind}{name} :  \"quoted {n}\"   # c{n} ")),
			4 => lines.push(format!("{ind}{name} :  a{n}, b,  c ")),
			5 => lines.extend([
				format!("{ind}{name} :"),
				format!("{inner}* one{n} "),
				format!("{inner}* two{n} "),
			]),
			6 => {
				let body = [
					format!("{inner}body {n}"),
					format!("{inner}  deeper {n}"),
					format!("{inner}```"),
				];
				lines.push(format!("{ind}{name} :  ```"));
				raw.extend(body.iter().cloned());
				lines.extend(body);
			}
			7 => lines.push(format!("{ind}{name}.sub :  {} ", rng.below(100))),
			_ => lines.push(format!("{ind}{name} :  {} ", rng.below(100))),
		}
	}
	let mode = rng.below(4);
	let mut out = String::new();
	for (k, l) in lines.iter().enumerate() {
		out.push_str(l);
		let crlf = match mode {
			0 => false,
			1 => true,
			2 => k % 2 == 1,
			_ => rng.below(2) == 0,
		};
		out.push_str(if crlf { "\r\n" } else { "\n" });
	}
	if rng.below(3) == 0 {
		out.truncate(out.trim_end_matches(['\r', '\n']).len());
	}
	(out, raw)
}

/// Each line of a text and its line ending: CRLF, LF, or none on a last line
/// with no newline.
fn eol_lines(text: &str) -> Vec<(&str, &str)> {
	text.split_inclusive('\n')
		.map(|l| {
			let body = match l.strip_suffix('\n') {
				Some(b) => b.strip_suffix('\r').unwrap_or(b),
				None => l,
			};
			(body, &l[body.len()..])
		})
		.collect()
}

/// The ending owed to the one source line a line stands for: its own, or
/// the majority one when it had none. None when several could be it.
fn one<'a>(hits: &[&(&str, &'a str)], majority: &'a str) -> Option<&'a str> {
	match hits {
		[(_, e)] => Some(if e.is_empty() { majority } else { e }),
		_ => None,
	}
}

/// The keep save ends each line the way the spec says: a line kept as
/// written keeps its own ending, a changed line keeps its own, a new line
/// takes the file's majority one with a tie going to LF, and a source line
/// that had none, the last of a file with no final newline, takes the
/// majority one too. A file with no final newline keeps none, and nothing is
/// left of the last line's own ending, a lone CR included. A line counts as
/// the source's when its text, or failing that its name through the colon,
/// is one source line's. Only the save that kept the lines is held to it;
/// the fallback is canonical and LF.
#[test]
fn keeping_lines_ends_each_line_by_the_rule() {
	let _id = test_id("ErTmDwQ");
	let iters = iter_count(300);
	let mut rng = Rng(0x5EED_1001_E01F_0001);
	// Kept and changed lines whose ending is not the majority one, new lines,
	// tied files, and files with no final newline whose last line moved.
	let mut seen = [0usize; 5];
	// SHCL_FUZZ_DUMP: the first inputs checked here, each with the edits that
	// took as a write-ops script, go to an eol/ folder beside the fmt dump.
	// crosscheck replays them through every binding's keep save. Capped, since
	// each one is a write per binding.
	let dump_dir = std::env::var("SHCL_FUZZ_DUMP")
		.ok()
		.map(|d| format!("{d}/eol"));
	if let Some(dir) = &dump_dir {
		std::fs::create_dir_all(dir).unwrap_or_else(|e| panic!("dump dir {dir}: {e}"));
	}
	let mut dumped = 0usize;
	for i in 0..iters {
		let (base, raw) = mixed_eol(&mut rng);
		let mut doc =
			Document::parse_keep_lines(&base, Strictness::Standard).unwrap_or_else(|e| e.document);
		let mut log = format!("base: {base:?}\n");
		let mut ops = String::new();
		for step in 0..(1 + rng.below(3)) {
			let paths = doc.paths();
			let path = if paths.is_empty() || rng.below(4) == 0 {
				format!("z{step}")
			} else {
				paths[rng.below(paths.len())].clone()
			};
			let op = rng.below(9);
			let (took, line) = match op {
				0 => (doc.set_int(&path, 7), format!("int\t{path}\t7")),
				1 => (
					doc.set_string(&path, "new text"),
					format!("string\t{path}\tnew text"),
				),
				2 => (doc.remove(&path) > 0, format!("remove\t{path}")),
				3 => (
					doc.set_comment(&path, "added"),
					format!("comment\t{path}\tadded"),
				),
				4 => (
					doc.clear_comments(&path) > 0,
					format!("clear-comments\t{path}"),
				),
				5 => (
					doc.set_int(&format!("{path}.kid{step}"), 3),
					format!("int\t{path}.kid{step}\t3"),
				),
				6 => (doc.set_empty(&path), format!("empty\t{path}")),
				// The count is of old blocks taken off; the new one goes on
				// either way.
				7 => {
					doc.set_banner(true);
					(true, "banner\ton".to_string())
				}
				_ => (
					doc.set_raw(&path, "one\n\ttwo", "sh"),
					format!("raw\t{path}\tsh\tone\\n\\ttwo"),
				),
			};
			// An edit that did not take changed nothing, so the script leaves
			// it out rather than ask the CLIs to refuse it.
			if took {
				ops.push_str(&line);
				ops.push('\n');
			}
			log.push_str(&format!("op {op} at {path:?}\n"));
		}
		let (text, kept) = doc.to_text_keep_lines();
		if !kept || text == base {
			continue;
		}
		if let Some(dir) = &dump_dir
			&& dumped < 100
		{
			std::fs::write(format!("{dir}/{i:05}.shcl"), &base).expect("dump input");
			std::fs::write(format!("{dir}/{i:05}.ops"), &ops).expect("dump ops");
			dumped += 1;
		}
		let source = eol_lines(&base);
		let crlf = source.iter().filter(|l| l.1 == "\r\n").count();
		let lf = source.iter().filter(|l| l.1 == "\n").count();
		let majority = if crlf > lf { "\r\n" } else { "\n" };
		let no_final = !base.is_empty() && !base.ends_with('\n');
		seen[3] += usize::from(crlf == lf && crlf > 0);
		let lines = eol_lines(&text);
		let head = |t: &str| t.find(':').map(|k| t[..=k].to_string());
		for (j, &(line, eol)) in lines.iter().enumerate() {
			let fail = || format!("iteration {i}, line {}:\n{log}--- wrote {text:?}", j + 1);
			assert!(
				!line.contains('\r'),
				"a carriage return left over, {}",
				fail()
			);
			if j + 1 == lines.len() {
				assert_eq!(eol.is_empty(), no_final, "the final newline, {}", fail());
				if no_final {
					seen[4] += usize::from(source.last().map(|l| l.0) != Some(line));
					continue;
				}
			}
			if line.trim().is_empty() || raw.iter().any(|r| r == line) {
				continue;
			}
			let same: Vec<_> = source.iter().filter(|s| s.0 == line).collect();
			let (want, class) = if !same.is_empty() {
				(one(&same, majority), 0)
			} else if let Some(h) = head(line) {
				let named: Vec<_> = source
					.iter()
					.filter(|s| head(s.0).as_ref() == Some(&h))
					.collect();
				match named.len() {
					0 => (Some(majority), 2),
					_ => (one(&named, majority), 1),
				}
			} else {
				(Some(majority), 2)
			};
			let Some(want) = want else { continue };
			assert_eq!(
				eol,
				want,
				"a {} line ends wrong, {}",
				["kept", "changed", "new"][class],
				fail()
			);
			seen[class] += usize::from(class == 2 || want != majority);
		}
	}
	assert!(
		seen.iter().all(|&n| n > 0),
		"a case never came up (kept, changed, new, tie, no final newline): {seen:?}"
	);
}

/// Lines built from the grammar with their spans known as they are laid
/// down, so the tokenizer has an oracle outside itself: the four bindings
/// agreeing on `tokens` proves parity, and this is what proves the spans are
/// the grammar's. Every piece kind the grammar has is drawn here: bare and
/// quoted names, bare and quoted selector bodies, bare, quoted, backtick,
/// empty and open elements, blanks wherever the grammar allows them (a carriage
/// return among them), a comment glued or spaced, non-ASCII text.
#[test]
fn tokens_follow_the_grammar() {
	let _id = test_id("EpFkZy4");
	let iters = iter_count(2000);
	let mut rng = Rng(0x5EED_70CE_0000_0005);
	let mut tok = Tokens::default();
	for i in 0..iters {
		let (line, want) = grammar_line(&mut rng);
		tokenize(&line, b':', false, Rules::Current, &mut tok);
		assert_eq!(tok, want, "iteration {i}: {line:?}");
	}
}

struct LineGen {
	text: String,
	want: Tokens,
}

impl LineGen {
	fn wsp(&mut self, rng: &mut Rng) {
		self.text
			.push_str(["", " ", "\t", "  ", "\r", " \r\t"][rng.below(6)]);
	}
	/// At least one blank: what makes a comma split a value.
	fn blank(&mut self, rng: &mut Rng) {
		self.text
			.push_str([" ", "\t", "  ", "\r", " \r\t"][rng.below(5)]);
	}
	fn pick(&mut self, rng: &mut Rng, set: &[&str], n: usize) {
		for _ in 0..n {
			self.text.push_str(set[rng.below(set.len())]);
		}
	}
	/// A quoted piece: the quote, content that cannot close it, the quote. No
	/// `]` inside either, for the reason bare() gives. `tick` lets it be a
	/// backtick value, which only a value element can be.
	fn quoted(&mut self, rng: &mut Rng, tick: bool) -> Piece {
		let (q, quote) = match rng.below(if tick { 3 } else { 2 }) {
			0 => ('"', Quote::Double),
			1 => ('\'', Quote::Single),
			_ => ('`', Quote::Backtick),
		};
		self.text.push(q);
		let start = self.text.len();
		// A backslash is a character, so only the quote itself is off limits.
		let all = [
			"a", "Z", " ", "\"", "'", "`", "\\", "#", ",", "[", ":", "\u{e9}", "\\a",
		];
		let set: Vec<&str> = all.into_iter().filter(|c| !c.contains(q)).collect();
		// The first content character is a letter, and a quote of the other
		// kind inside is followed by one: a comma or a blank after a quote
		// would let an open piece earlier on the line close on it.
		self.pick(rng, &["a", "Z"], 1);
		for _ in 0..rng.below(5) {
			let c = set[rng.below(set.len())];
			self.text.push_str(c);
			if c == "'" || c == "\"" || c == "`" {
				self.text.push('a');
			}
		}
		let end = self.text.len();
		self.text.push(q);
		Piece { start, end, quote }
	}
	/// A bare piece for a value or a selector body: no bracket, no leading
	/// quote, no `#`, no edge blank, and in a value no comma but one with a
	/// letter after it, which is text. `open` makes it start with a quote it
	/// never closes the quoted way. No `]` or `)` at all, and no quote as a bare piece's last
	/// character: a quote that opens a piece closes at the next matching
	/// quote when that one sits right before the piece's terminator,
	/// wherever on the line it is, so those two shapes would hand an open
	/// piece a closing quote from a later one. That reading is the rule, not
	/// a defect; the generator just keeps to lines with one reading.
	fn bare(&mut self, rng: &mut Rng, term: char, open: bool) -> Piece {
		let start = self.text.len();
		let mut set: Vec<&str> = vec![
			"a", "Z", "-", "_", ".", ":", "\\", "\u{e9}", "'", "\"", "`", "[", "(",
		];
		set.retain(|c| !c.starts_with(term));
		if open {
			// The quote either never closes or closes with text after it;
			// either way the tokenizer reads the piece bare. A backtick opens
			// only a value element.
			let q = ["\"", "'", "`"][rng.below(if term == ',' { 3 } else { 2 })];
			self.text.push_str(q);
			set.retain(|c| c != &q);
			let n = 1 + rng.below(3);
			self.pick(rng, &set, n);
			if rng.below(2) == 0 {
				self.text.push_str(q);
				self.text.push_str(" b");
			}
		} else {
			// First character: neither a quote nor a bracket.
			self.pick(rng, &["a", "Z", "-", "_", ".", ":", "\\", "\u{e9}"], 1);
			for _ in 0..rng.below(4) {
				// A blank is content mid-piece.
				if rng.below(5) == 0 {
					self.text.push([' ', '\r'][rng.below(2)]);
				}
				let c = set[rng.below(set.len())];
				self.text.push_str(c);
				if term == ',' && rng.below(6) == 0 {
					self.text.push_str(",a");
				}
			}
		}
		if self.text.ends_with(['\'', '"', '`']) {
			self.text.push('a');
		}
		Piece {
			start,
			end: self.text.len(),
			quote: if open { Quote::Open } else { Quote::None },
		}
	}
	fn segment(&mut self, rng: &mut Rng) -> SegTok {
		let name = if rng.below(3) == 0 {
			self.quoted(rng, false)
		} else {
			let start = self.text.len();
			let n = 1 + rng.below(4);
			self.pick(rng, &["a", "Z", "0", "-", "_"], n);
			// Not led by a letter: it still reads, and the line says so.
			if !self.text.as_bytes()[start].is_ascii_alphabetic() {
				self.want.misspelled.get_or_insert(start);
			}
			Piece {
				start,
				end: self.text.len(),
				quote: Quote::None,
			}
		};
		let mut selector = None;
		if rng.below(2) == 0 {
			self.wsp(rng);
			// Now and then the old spelling in brackets, which reads the same
			// and is noted (E029).
			let (open, close) = if rng.below(4) == 0 {
				self.want.bracket_selector.get_or_insert(self.text.len());
				('[', ']')
			} else {
				('(', ')')
			};
			self.text.push(open);
			self.wsp(rng);
			let body = match rng.below(4) {
				0 => self.quoted(rng, false),
				1 => self.bare(rng, close, true),
				_ => self.bare(rng, close, false),
			};
			self.wsp(rng);
			self.text.push(close);
			selector = Some(body);
		}
		SegTok {
			name,
			selector,
			star: false,
		}
	}
}

fn grammar_line(rng: &mut Rng) -> (String, Tokens) {
	let mut g = LineGen {
		text: String::new(),
		want: Tokens::default(),
	};
	let nseg = 1 + rng.below(3);
	for i in 0..nseg {
		if i > 0 {
			g.wsp(rng);
			g.text.push('.');
		}
		g.wsp(rng);
		let seg = g.segment(rng);
		g.want.segments.push(seg);
	}
	g.wsp(rng);
	match rng.below(4) {
		0 => {}
		1 => {
			// A comment right after the path, glued or not.
			g.text.push_str(["# c", " # c"][rng.below(2)]);
			g.want.comment = Some(g.text.len() - 3);
		}
		_ => {
			g.want.sep = Some(g.text.len());
			g.text.push(':');
			let npieces = rng.below(4);
			if npieces == 0 {
				g.wsp(rng);
				let at = g.text.len();
				g.want.elements.push(Piece {
					start: at,
					end: at,
					quote: Quote::None,
				});
			}
			for j in 0..npieces {
				if j > 0 {
					g.wsp(rng);
					g.text.push(',');
					g.blank(rng);
				} else {
					g.wsp(rng);
				}
				let piece = match rng.below(5) {
					0 => {
						let at = g.text.len();
						Piece {
							start: at,
							end: at,
							quote: Quote::None,
						}
					}
					1 => g.quoted(rng, true),
					2 => g.bare(rng, ',', true),
					_ => g.bare(rng, ',', false),
				};
				g.want.elements.push(piece);
			}
			// The value runs from its first piece (opening quote included) to
			// after its last non-blank character, comma or closing quote
			// included; an empty value is a point.
			let end = g.text.trim_end_matches([' ', '\t', '\r']).len();
			if rng.below(2) == 0 {
				g.text.push_str(["# c", "  # c"][rng.below(2)]);
				g.want.comment = Some(g.text.len() - 3);
			}
			// An empty piece sits where the scan gave up on it: at the comma,
			// the comment or the end that follows the blank, not at the blank.
			for p in &mut g.want.elements {
				if p.quote == Quote::None && p.start == p.end {
					let rest = &g.text[p.start..];
					p.start += rest.len() - rest.trim_start_matches([' ', '\t', '\r']).len();
					p.end = p.start;
				}
			}
			let first = g.want.elements[0];
			let start = match first.quote {
				Quote::Single | Quote::Double | Quote::Backtick => first.start - 1,
				_ => first.start,
			};
			g.want.value = (start, end.max(start));
		}
	}
	(g.text, g.want)
}

/// The self-check's sanctioned shortfall, written again here rather than
/// borrowed: a V007 whose `not in LO..HI` has LO of 2 or more.
fn v007_shortfall(message: &str) -> bool {
	let Some(at) = message.rfind(" not in ") else {
		return false;
	};
	message[at + " not in ".len()..]
		.split("..")
		.next()
		.and_then(|lo| lo.parse::<u64>().ok())
		.is_some_and(|lo| lo >= 2)
}

/// Generate from a schema that loads, and hold an `Ok` to the promise itself:
/// the starter loads with no error and validates clean apart from the
/// shortfall. None when the schema does not load or generation refuses.
fn generate_checked(schema_text: &str) -> Option<String> {
	let sdoc = Document::parse(schema_text);
	if sdoc
		.diagnostics()
		.iter()
		.any(|d| d.severity == Severity::Error)
	{
		return None;
	}
	let text = shcl::generate(&sdoc, true).ok()?;
	let gdoc = Document::parse(&text);
	let load: Vec<String> = gdoc
		.diagnostics()
		.iter()
		.filter(|d| d.severity == Severity::Error)
		.map(|d| format!("{} {}", d.code, d.message))
		.collect();
	assert!(
		load.is_empty(),
		"generated starter does not load: {:?}\nschema:\n{}\nstarter:\n{}",
		load,
		schema_text,
		text
	);
	let bad: Vec<String> = gdoc
		.validate(&sdoc)
		.into_iter()
		.filter(|d| {
			d.severity == Severity::Error && !(d.code == "V007" && v007_shortfall(&d.message))
		})
		.map(|d| format!("{} {}", d.code, d.message))
		.collect();
	assert!(
		bad.is_empty(),
		"generated starter fails its schema: {:?}\nschema:\n{}\nstarter:\n{}",
		bad,
		schema_text,
		text
	);
	Some(text)
}

/// A generated starter loads clean and validates clean against the schema that
/// produced it (spec, Schema-driven generation). The library checks its own
/// text, so this checks every `Ok` again without trusting that. The grid is
/// every path shape and default a selector can meet; floors keep the gate from
/// passing by refusing.
#[test]
fn generated_starters_load_and_validate_clean() {
	let _id = test_id("EptVfIO");
	let iters = iter_count(1);
	const PATHS: &[&str] = &[
		"a",
		"a.b",
		"a(b)",
		"a(b).c",
		"a(*).c",
		"a(*)",
		"\"x:y\"",
		"\"x#y\"",
		"\"x y\"",
		"\"x.y\"",
		"a('#')",
		"a(\"b c\")",
		"a(\" b\")",
		"a(b#c)",
		"a.b(c).d",
		"\"a b\"(c)",
		"a(~~~)",
		"a.b(c)",
		"a(*).b(c)",
		"a(\"b\")",
	];
	const DEFAULTS: &[Option<&str>] = &[
		None,
		Some("hello"),
		Some("b"),
		Some("\"b\""),
		Some("c"),
		Some("\"c\""),
		Some("\"~~~x\""),
		Some("'#x'"),
		Some("\" b\""),
		Some("\"b c\""),
		Some("\"#\""),
		Some("'#'"),
		Some("\"[x]\""),
		Some("[1, 2]"),
		Some("\"\""),
		Some("\"*\""),
		Some("\"7\""),
	];
	const REQUIRED: &str = "\trequired: yes\n";
	const KINDS: &[&str] = &[REQUIRED, "\trepeat: 1\n", ""];
	const CHILDREN: &[&str] = &["a.c", "a(*).c", "a(b).c", "a.c(d)", "a(*)", "a(b)"];
	const CHILD_DEFAULTS: &[Option<&str>] =
		&[None, Some("v"), Some("b"), Some("d"), Some("\"~~~y\"")];
	fn field(path: &str, default: Option<&str>, kind: &str) -> String {
		let mut s = format!(
			"field: \"{}\"\n{}",
			path.replace('◉', "◉ESCAPE_CHAR◉")
				.replace('"', "◉DOUBLE_QUOTE◉"),
			kind
		);
		if let Some(d) = default {
			s.push_str(&format!("\tdefault: {}\n", d));
		}
		s
	}
	let mut grid: Vec<String> = Vec::new();
	for p in PATHS {
		for d in DEFAULTS {
			for k in KINDS {
				grid.push(field(p, *d, k));
			}
		}
	}
	for ch in CHILDREN {
		for cd in CHILD_DEFAULTS {
			for d in DEFAULTS {
				grid.push(field("a", *d, REQUIRED) + &field(ch, *cd, REQUIRED));
			}
			grid.push(field("a", None, "") + &field(ch, *cd, REQUIRED));
		}
	}
	let generated = grid
		.iter()
		.filter(|s| generate_checked(s).is_some())
		.count();

	let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../project/conformance");
	let entries =
		std::fs::read_dir(&dir).unwrap_or_else(|e| panic!("corpus dir {}: {}", dir.display(), e));
	let mut seeds: Vec<String> = entries
		.flatten()
		.filter_map(|e| std::fs::read_to_string(e.path().join("init-schema.shcl")).ok())
		.collect();
	seeds.sort();
	assert!(!seeds.is_empty(), "no init-schema.shcl in the corpus");
	let mut rng = Rng(0x5EED_CAFE_F00D_0005);
	// Without a count here the loop asserted nothing: generate_checked only
	// checks what it generated, so a run whose every mutated schema was refused
	// came back clean.
	let mut mutated = 0usize;
	for _ in 0..iters {
		let base = &seeds[rng.below(seeds.len())];
		if generate_checked(&mutate(&mut rng, base)).is_some() {
			mutated += 1;
		}
	}
	assert!(
		mutated > iters / 16,
		"only {} of {} mutated schemas generated",
		mutated,
		iters
	);

	assert_eq!(
		generate_checked("field: \"a(b)\"\n\trequired: yes\n\tdefault: b\n").as_deref(),
		Some("## any, required\na: b\n"),
		"a default naming the selected instance must generate"
	);
	let spaced = generate_checked("field: '\"a b\"(c)'\n\trequired: yes\n\tdefault: c\n")
		.expect("a quoted name with a selector default must generate");
	assert!(
		spaced.lines().any(|l| l == "\"a b\": c"),
		"quoted name lost its bare line:\n{}",
		spaced
	);
	// Recorded after 20260909 item 5. A change to this count needs a reason on
	// the backlog item that moves it. 20260918 item 4 took it from 1171: the
	// 132 optional fields whose default names another instance than the path
	// selects are refused now, as the required ones already were. 20260918b
	// item 26 took it to 1041: `a[b#c]` required, and at repeat 1, generate
	// `a["b#c"]:` where the bare body was a comment and the schema refused.
	// 2026100207032800 took it to 1029: the 12 whose parent defaults to an
	// array and has a child, which has no selector spelling once a bare
	// selector body cannot hold a space.
	assert_eq!(generated, 1029, "grid schemas that generate");
}
