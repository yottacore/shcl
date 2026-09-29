// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! Deterministic fuzz smoke: mutate the corpus inputs (and some synthetic soup)
//! with a fixed-seed PRNG and assert the invariants that must hold for ANY input:
//! no panic at any strictness, and the canonical formatter is a fixpoint.
//! Iteration count scales via SHCL_FUZZ_ITERS (cicd raises it; default is quick).

mod common;

use common::test_id;
use shcl::{
	Document, Piece, Quote, Rules, SegTok, Severity, Strictness, Tokens, migrate, tokenize,
	tokenize_value,
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
// arrays, mixed and staircase indent, comments at every depth, stacked
// elements against fields. Every defect all four bindings shared in the last
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
		let sel = match rng.below(6) {
			0 => "[x]",
			1 => "[*]",
			2 => "[#1]",
			_ => "",
		};
		// Shapes 11 to 13 carry a `# k` comment behind a selector holding a
		// quote, a backslash or a quoted `]`; see comments_behind_selectors.
		let line = match rng.below(24) {
			0 => format!("{indent}# comment {}", rng.below(3)),
			1 => String::new(),
			2 => format!("{indent}no colon here"),
			3 => format!("{indent}* {}", rng.below(4)),
			4 => format!("{indent}{name}: [{}, {}]", rng.below(9), rng.below(9)),
			5 => format!("{indent}{name}{sel}:"),
			6 => format!("{indent}{name}.{name}{sel}: {}", rng.below(9)),
			7 => fence(rng, &indent, name),
			8 => format!("{indent}{name}: \"open"),
			9 => format!("{indent}{name}: 1, , 2 # trailing"),
			10 => format!("{indent}\u{feff}{name}: 1"),
			11 => format!("{indent}{name}[O'x].{name}: {}  # k", rng.below(9)),
			12 => format!("{indent}{name}[C:\\].{name}: it's  # k"),
			13 => format!("{indent}{name}[ \"q]v\" ].{name}: {}  # k", rng.below(9)),
			// One bracketed value, and the sugar spelling of a selector: neither
			// loses anything, unlike shape 4.
			14 => format!(
				"{indent}{name}:{}[v{}]",
				if rng.below(2) == 0 { " " } else { "" },
				rng.below(3)
			),
			// The 3.0 shapes: a `#` glued to a value, an index selector a
			// comment cuts off, bare and single-quoted backslashes, a comment
			// right after the colon, a quote that closes with text after it.
			15 => format!("{indent}{name}: x#y  # k"),
			16 => format!("{indent}{name}[#{}].{name}: {}", rng.below(2), rng.below(9)),
			17 => format!("{indent}{name}: C:\\dir, a\\tb, 'it\\'s'"),
			18 => format!("{indent}{name}:#x"),
			19 => format!("{indent}{name}: \"a\" b, c  # k"),
			20 => format!("{indent}{name}['x].{name}: {}  # k", rng.below(9)),
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
	seeds.push("x:\n\t* one\n\t* two\n".to_string());
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
					// Quoted segments may carry a literal tab; those cannot ride
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
		// The formatter must be a fixpoint on its own output.
		let once = doc.to_canonical();
		let twice = Document::parse(&once).to_canonical();
		assert_eq!(
			twice, once,
			"formatter not idempotent at iteration {} for mutated input:\n{}",
			i, text
		);
		// Both answers to "was this file written for 2.x" have their own set of
		// rewrites, and each has to settle after one pass.
		for from_v2 in [true, false] {
			let m = migrate(&text, from_v2).text;
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
/// The structural shapes that carry `# k` are the only source of that text; a
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
		"a[O'x].b: 5  # k",
		"a[C:\\].b: it's  # k",
		"a[ \"q]v\" ].b: 5  # k",
		"a['x].b: 5  # k",
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
		"the soup carried only {} commented lines",
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
			tokenize(rest, b':', false, Rules::Current, &mut tok);
			(tok.fault.is_none() && tok.sep.is_some()).then(|| &rest[tok.value.0..tok.value.1])
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
				"E002" | "E003" | "E004" | "E006" | "E007" | "E008" | "E009" | "E010" | "E011"
				| "E016" | "E021" => want += 1,
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
				"E013" | "E014" | "E019" => {
					kept_seen += 1;
					let kept = src.trim_matches([' ', '\t']);
					assert!(
						canon.lines().any(|l| l.trim_matches([' ', '\t']) == kept),
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

/// An element cap refuses only a line that would otherwise bind. A line the
/// uncapped parse refuses or keeps verbatim reads the same under a cap, since
/// a code judged after the cap check used to lose to it: bracket text under a
/// cap came out `E021` and lost, where uncapped it is `E019` and kept. `E012`
/// and `E018` are left out on both sides: they judge where a line sits, and a
/// capped line above holds its level, so the lines under it move.
#[test]
fn a_cap_refuses_only_a_line_that_would_bind() {
	let _id = test_id("EqKhPQO");
	let iters = iter_count(1);
	const REFUSING: &[&str] = &[
		"E003", "E004", "E006", "E007", "E008", "E009", "E010", "E011", "E013", "E014", "E016",
		"E019",
	];
	let mut rng = Rng(0x5EED_57A7_1C00_0009);
	let mut kept_under_cap = 0usize;
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
			assert!(
				on(&capped, d.line, "E019"),
				"bracket text on line {} is not E019 under a cap, at iteration {}:\n{}",
				d.line,
				i,
				text
			);
			kept_under_cap += 1;
		}
	}
	assert!(
		kept_under_cap > iters / 8,
		"the soup checked only {} bracket lines under a cap",
		kept_under_cap
	);
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
	let lines: Vec<&str> = text.lines().collect();
	let mut spans = Vec::new();
	let mut open: Option<(char, usize, usize)> = None;
	for (k, line) in lines.iter().enumerate() {
		let bare = line.trim_start_matches([' ', '\t']);
		if let Some((c, n, at)) = open {
			let closer = line.trim();
			if closer.chars().count() >= n && closer.chars().all(|x| x == c) {
				spans.push((at, k + 1));
				open = None;
			}
			continue;
		}
		// The block spelling: the fence is the whole line. The same-line
		// spelling: it is the value half. No name the soup builds holds a
		// `: `, so the first one is the field's. A `*` is no field name, so
		// such a line has no value and opens nothing.
		if bare.starts_with('*') {
			continue;
		}
		let value = line.split_once(": ").map(|(_, v)| v.trim_start());
		if let Some((c, n)) = fence_run(bare).or_else(|| value.and_then(fence_run)) {
			open = Some((c, n, k + 1));
		}
	}
	if let Some((_, _, at)) = open {
		spans.push((at, lines.len()));
	}
	spans
}

/// A raw body is content, whatever becomes of the line that opened it. A
/// skipped field line whose value opened a block left the body to be read as
/// lines, and its closing fence then opened a block of its own; nine review
/// items were some arm of that. So no diagnostic may fall on a body line or a
/// closing fence, unless the opening line has no value to read: a `*` name,
/// which is no field at all, a path that did not parse (E014), or a fence with
/// no field above it to bind to (E006).
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
			if on(opener, &["E006", "E014"]) {
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
		let once = doc.to_canonical();
		let twice = Document::parse(&once).to_canonical();
		assert_eq!(
			twice, once,
			"merged output not idempotent at iteration {} for:\nA:\n{}\nB:\n{}",
			i, a, b
		);
		// Onto an empty base a merge is the identity: nothing to match, so
		// every node and every footer line comes across in file order.
		let mut empty = Document::new();
		empty.merge(&Document::parse(&b));
		assert_eq!(
			empty.to_canonical(),
			Document::parse(&b).to_canonical(),
			"merge onto empty base is not the identity at iteration {} for:\n{}",
			i,
			b
		);
		// Reads answered by the merged document itself, not just its text. A
		// merged arena holds dropped nodes, a rebuilt index and cloned child
		// lists, and only a read walks those; the text compare above cannot
		// see them. Every eighth iteration, since it walks every path.
		//
		// `instances` is left out on purpose: it hands back the SOURCE
		// spelling, and canonical output legitimately respells a value -
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
		// too, not just on the value: a text carrying both quote kinds used to
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
			// A kept line the settle turned into a comment is still the user's
			// line and survives clear_comments. The canonical text writes it as
			// a comment, so on the reload it is one, and the two cannot agree
			// (20260926 item 2).
			let settled = op == 10 && live.comments(&path) != back.comments(&path);
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
			assert!(
				settled || live.to_canonical() == back.to_canonical(),
				"a step on the document and on its reload differ at iteration {i}:\n{log}"
			);
		}
	}
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

/// Lines built from the grammar with their spans known as they are laid
/// down, so the tokenizer has an oracle outside itself: the four bindings
/// agreeing on `tokens` proves parity, and this is what proves the spans are
/// the grammar's. Every piece kind the grammar has is drawn here: bare and
/// quoted names, bare and quoted selector bodies, bare, quoted, empty and
/// open elements, blanks wherever the grammar allows them (a carriage
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
	fn pick(&mut self, rng: &mut Rng, set: &[&str], n: usize) {
		for _ in 0..n {
			self.text.push_str(set[rng.below(set.len())]);
		}
	}
	/// A quoted piece: the quote, content that cannot close it, the quote. No
	/// `]` inside either, for the reason bare() gives.
	fn quoted(&mut self, rng: &mut Rng) -> Piece {
		let double = rng.below(2) == 0;
		let q = if double { '"' } else { '\'' };
		self.text.push(q);
		let start = self.text.len();
		// Inside double quotes a backslash escapes the next character, so an
		// escaped quote stays inside; inside single quotes a backslash is a
		// character and only the quote itself is off limits.
		let set: &[&str] = if double {
			&[
				"a", "Z", " ", "\\\"", "\\\\", "'", "#", ",", "[", ":", "\u{e9}", "\\a",
			]
		} else {
			&[
				"a", "Z", " ", "\"", "\\", "#", ",", "[", ":", "\u{e9}", "\\\\",
			]
		};
		// The first content character is a letter, and a quote of the other
		// kind inside is followed by one: a comma or a blank after a quote
		// would let an open piece earlier on the line close on it.
		self.pick(rng, &["a", "Z"], 1);
		for _ in 0..rng.below(5) {
			let c = set[rng.below(set.len())];
			self.text.push_str(c);
			if c == "'" || c == "\"" {
				self.text.push('a');
			}
		}
		let end = self.text.len();
		self.text.push(q);
		Piece {
			start,
			end,
			quote: if double { Quote::Double } else { Quote::Single },
		}
	}
	/// A bare piece for a value or a selector body: no comma, no bracket,
	/// no leading quote, no `#`, no edge blank. `open` makes it start with a quote it never closes the
	/// quoted way. No `]` at all, and no quote as a bare piece's last
	/// character: a quote that opens a piece closes at the next matching
	/// quote when that one sits right before the piece's terminator,
	/// wherever on the line it is, so those two shapes would hand an open
	/// piece a closing quote from a later one. That reading is the rule, not
	/// a defect; the generator just keeps to lines with one reading.
	fn bare(&mut self, rng: &mut Rng, term: char, open: bool) -> Piece {
		let start = self.text.len();
		let mut set: Vec<&str> = vec!["a", "Z", "-", "_", ".", ":", "\\", "\u{e9}", "'", "\"", "["];
		set.retain(|c| !c.starts_with(term));
		if open {
			// The quote either never closes or closes with text after it;
			// either way the tokenizer reads the piece bare.
			let q = if rng.below(2) == 0 { "\"" } else { "'" };
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
			}
		}
		if self.text.ends_with(['\'', '"']) {
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
			self.quoted(rng)
		} else {
			let start = self.text.len();
			let n = 1 + rng.below(4);
			self.pick(rng, &["a", "Z", "0", "-", "_"], n);
			Piece {
				start,
				end: self.text.len(),
				quote: Quote::None,
			}
		};
		let mut selector = None;
		if rng.below(2) == 0 {
			self.wsp(rng);
			self.text.push('[');
			self.wsp(rng);
			let body = match rng.below(4) {
				0 => self.quoted(rng),
				1 => self.bare(rng, ']', true),
				_ => self.bare(rng, ']', false),
			};
			self.wsp(rng);
			self.text.push(']');
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
				}
				g.wsp(rng);
				let piece = match rng.below(5) {
					0 => {
						let at = g.text.len();
						Piece {
							start: at,
							end: at,
							quote: Quote::None,
						}
					}
					1 => g.quoted(rng),
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
				Quote::Single | Quote::Double => first.start - 1,
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
		"a[b]",
		"a[b].c",
		"a[*].c",
		"a[*]",
		"\"x:y\"",
		"\"x#y\"",
		"\"x y\"",
		"\"x.y\"",
		"a['#']",
		"a[\"b c\"]",
		"a[\" b\"]",
		"a[b#c]",
		"a.b[c].d",
		"\"a b\"[c]",
		"a[~~~]",
		"a.b[c]",
		"a[*].b[c]",
		"a[\"b\"]",
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
		Some("1, 2"),
		Some("\"\""),
		Some("\"*\""),
		Some("\"7\""),
	];
	const REQUIRED: &str = "\trequired: yes\n";
	const KINDS: &[&str] = &[REQUIRED, "\trepeat: 1\n", ""];
	const CHILDREN: &[&str] = &["a.c", "a[*].c", "a[b].c", "a.c[d]", "a[*]", "a[b]"];
	const CHILD_DEFAULTS: &[Option<&str>] =
		&[None, Some("v"), Some("b"), Some("d"), Some("\"~~~y\"")];
	fn field(path: &str, default: Option<&str>, kind: &str) -> String {
		let mut s = format!(
			"field: \"{}\"\n{}",
			path.replace('\\', "\\\\").replace('"', "\\\""),
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
		generate_checked("field: \"a[b]\"\n\trequired: yes\n\tdefault: b\n").as_deref(),
		Some("## any, required\na: b\n"),
		"a default naming the selected instance must generate"
	);
	let spaced = generate_checked("field: \"\\\"a b\\\"[c]\"\n\trequired: yes\n\tdefault: c\n")
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
	assert_eq!(generated, 1041, "grid schemas that generate");
}
