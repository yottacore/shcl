// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! Conformance-corpus runner. Every shipped binding must pass this corpus;
//! the Rust reference runs it natively here. Case layout and reads.tsv column
//! meanings are documented in project/conformance/README.md.

mod common;

use common::test_id;
use shcl::{
	Document, DurationUnit, FORMAT_LINE, FORMAT_LINE_HEAD, FORMAT_MAJOR, MIGRATED_LINE, SizeUnit,
	Strictness, format_version, generate, migrate, migrate_unstamped, parse_datetime,
	quote_segment, schema_ref,
};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

fn corpus_dir() -> PathBuf {
	Path::new(env!("CARGO_MANIFEST_DIR")).join("../../project/conformance")
}

/// TSV-safe form: real newlines/tabs in a value are written \n / \t.
fn tsv_escape(s: &str) -> String {
	s.replace('\n', "\\n").replace('\t', "\\t")
}

fn parse_level(s: Option<&str>) -> Strictness {
	match s {
		None | Some("") | Some("standard") => Strictness::Standard,
		Some("loose") => Strictness::Loose,
		Some("strict") => Strictness::Strict,
		Some(other) => panic!("unknown level '{}' in reads.tsv", other),
	}
}

struct Case {
	name: String,
	// The case's test ID, from its test-id file.
	id: String,
	input: String,
	expected_fmt: String,
	reads: String,
	// Golden `check` stdout at Standard: diag lines (line/severity/code) + summary.
	expected_diags: String,
	// Write dimension (optional): an ops script and its golden canonical output.
	write_ops: Option<String>,
	expected_write: Option<String>,
	// The same ops through the save that keeps lines.
	expected_keep: Option<String>,
	// Bad-op dimension (optional): ops that must each be rejected, applied alone.
	write_bad_ops: Option<String>,
	// Schema dimension (optional): a schema and the golden `check --schema` stdout.
	schema: Option<String>,
	expected_validate: Option<String>,
	// Layered-load dimension (optional): lower-priority layer files (in filename
	// order), optional `path=value` overrides, and the golden merged canonical.
	layers: Vec<String>,
	merge_sets: Option<String>,
	expected_merged: Option<String>,
	// Generation dimension (optional): a schema and the golden `init` output.
	init_schema: Option<String>,
	expected_init: Option<String>,
	// Migration dimension (optional): the golden `migrate` output of the input
	// and the load diagnostics of that output.
	expected_migrate: Option<String>,
	expected_migrate_diags: Option<String>,
}

/// Decode an ops value: \n \t \\ only, others verbatim (mirrors the CLI).
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

/// Apply one write-ops line via the library Writer, with the same value gates
/// the CLI applies. Err = the op must be rejected (bad value or unusable path).
/// The error an op name no runner knows comes back as. A write-bad.ops row
/// spelled wrong is a fixture mistake, and without this it counted as exactly
/// the refusal the row exists to assert.
const UNKNOWN_OP: &str = "unknown op: ";

fn try_apply_op(doc: &mut Document, line: &str) -> Result<(), String> {
	let f: Vec<&str> = line.split('\t').collect();
	let path = f.get(1).copied().unwrap_or("");
	let v = f.get(2).copied().unwrap_or("");
	let pint = |s: &str| s.parse::<i64>().map_err(|_| format!("bad int: {}", s));
	let pflt = |s: &str| s.parse::<f64>().map_err(|_| format!("bad float: {}", s));
	let ints = |xs: &[&str]| xs.iter().map(|s| pint(s)).collect::<Result<Vec<_>, _>>();
	let flts = |xs: &[&str]| xs.iter().map(|s| pflt(s)).collect::<Result<Vec<_>, _>>();
	let pbool = |s: &str| match s {
		"true" => Ok(true),
		"false" => Ok(false),
		_ => Err(format!("bad bool: {}", s)),
	};
	let bools = |xs: &[&str]| xs.iter().map(|s| pbool(s)).collect::<Result<Vec<_>, _>>();
	let dt = |s: &str| parse_datetime(s).ok_or_else(|| format!("bad datetime: {}", s));
	let arr = &f[2.min(f.len())..];
	let wrote = match f.first().copied().unwrap_or("") {
		"int" => doc.set_int(path, pint(v)?),
		"float" => doc.set_float(path, pflt(v)?),
		"bool" => doc.set_bool(path, pbool(v)?),
		"string" => doc.set_string(path, &unescape_ops(v)),
		"datetime" => doc.set_datetime(path, &dt(v)?),
		"literal" => doc.set_literal(path, v),
		"literal-default" => doc.set_literal_default(path, v),
		"int-default" => doc.set_int_default(path, pint(v)?),
		"float-default" => doc.set_float_default(path, pflt(v)?),
		"bool-default" => doc.set_bool_default(path, pbool(v)?),
		"string-default" => doc.set_string_default(path, &unescape_ops(v)),
		"datetime-default" => doc.set_datetime_default(path, &dt(v)?),
		"int-array" => doc.set_int_array(path, &ints(arr)?),
		"float-array" => doc.set_float_array(path, &flts(arr)?),
		"bool-array" => doc.set_bool_array(path, &bools(arr)?),
		"string-array" => {
			let owned: Vec<String> = arr.iter().map(|s| unescape_ops(s)).collect();
			doc.set_string_array(path, &owned.iter().map(|s| s.as_str()).collect::<Vec<_>>())
		}
		"datetime-array" => {
			let dts = arr.iter().map(|s| dt(s)).collect::<Result<Vec<_>, _>>()?;
			doc.set_datetime_array(path, &dts)
		}
		"int-array-default" => doc.set_int_array_default(path, &ints(arr)?),
		"float-array-default" => doc.set_float_array_default(path, &flts(arr)?),
		"bool-array-default" => doc.set_bool_array_default(path, &bools(arr)?),
		"string-array-default" => {
			let owned: Vec<String> = arr.iter().map(|s| unescape_ops(s)).collect();
			doc.set_string_array_default(
				path,
				&owned.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
			)
		}
		"datetime-array-default" => {
			let dts = arr.iter().map(|s| dt(s)).collect::<Result<Vec<_>, _>>()?;
			doc.set_datetime_array_default(path, &dts)
		}
		"raw" => doc.set_raw(path, &unescape_ops(f.get(3).copied().unwrap_or("")), v),
		"raw-default" => {
			doc.set_raw_default(path, &unescape_ops(f.get(3).copied().unwrap_or("")), v)
		}
		"empty" => doc.set_empty(path),
		"comment" => doc.set_comment(path, &unescape_ops(v)),
		"remove" => {
			doc.remove(path);
			true
		}
		"clear-comments" => {
			doc.clear_comments(path);
			true
		}
		"banner" => match path {
			"on" | "off" => {
				doc.set_banner(path == "on");
				true
			}
			_ => return Err(format!("bad banner: {}", path)),
		},
		other => return Err(format!("{}{}", UNKNOWN_OP, other)),
	};
	if !wrote {
		return Err(format!("cannot write {}", path));
	}
	Ok(())
}

/// Good-path wrapper: the op must apply.
fn apply_op(doc: &mut Document, line: &str, at: &str) {
	try_apply_op(doc, line).unwrap_or_else(|e| panic!("{}: {}", at, e));
}

fn load_cases() -> Vec<Case> {
	let dir = corpus_dir();
	let mut cases: Vec<Case> = Vec::new();
	let entries =
		std::fs::read_dir(&dir).unwrap_or_else(|e| panic!("corpus dir {}: {}", dir.display(), e));
	for entry in entries {
		let path = entry.unwrap().path();
		if !path.is_dir() {
			continue;
		}
		// A case directory with no input.shcl is a mistake, not a non-case. The
		// runners all skipped one without a word while check-docs still wanted
		// its README note, so the case read as present and asserted nothing.
		let input = path.join("input.shcl");
		assert!(input.exists(), "{}: missing input.shcl", path.display());
		let read_opt = |name: &str| std::fs::read_to_string(path.join(name)).ok();
		// Layer files: every `layer*.shcl`, read in filename (= priority) order.
		let mut layer_names: Vec<String> = std::fs::read_dir(&path)
			.unwrap()
			.filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
			.filter(|n| n.starts_with("layer") && n.ends_with(".shcl"))
			.collect();
		layer_names.sort();
		let layers: Vec<String> = layer_names
			.iter()
			.map(|n| std::fs::read_to_string(path.join(n)).unwrap())
			.collect();
		cases.push(Case {
			name: path.file_name().unwrap().to_string_lossy().into_owned(),
			id: read_opt("test-id").map_or_else(|| "-------".to_string(), |s| s.trim().to_string()),
			input: std::fs::read_to_string(&input).unwrap(),
			expected_fmt: std::fs::read_to_string(path.join("expected.shcl")).unwrap(),
			reads: std::fs::read_to_string(path.join("reads.tsv")).unwrap(),
			expected_diags: std::fs::read_to_string(path.join("expected-diags.txt")).unwrap(),
			write_ops: read_opt("write.ops"),
			expected_write: read_opt("expected-write.shcl"),
			expected_keep: read_opt("expected-keep.shcl"),
			write_bad_ops: read_opt("write-bad.ops"),
			schema: read_opt("schema.shcl"),
			expected_validate: read_opt("expected-validate.txt"),
			layers,
			merge_sets: read_opt("merge.sets"),
			expected_merged: read_opt("expected-merged.shcl"),
			init_schema: read_opt("init-schema.shcl"),
			expected_init: read_opt("expected-init.shcl"),
			expected_migrate: read_opt("expected-migrate.shcl"),
			expected_migrate_diags: read_opt("expected-migrate-diags.txt"),
		});
	}
	cases.sort_by(|a, b| a.name.cmp(&b.name));
	assert!(
		!cases.is_empty(),
		"no corpus cases found under {}",
		dir.display()
	);
	cases
}

/// Cases failed so far, and how many of the corpus tests have finished.
struct Tally {
	done: usize,
	failed: BTreeSet<String>,
}

static TALLY: Mutex<Tally> = Mutex::new(Tally {
	done: 0,
	failed: BTreeSet::new(),
});

/// Runs `check` on every case, going on past one that fails, then fails the
/// test with the names of those that did. The corpus test to finish last
/// prints one status line per case, failed if any corpus test failed it.
fn each_case(check: impl Fn(&Case)) {
	let cases = load_cases();
	let mut failed = Vec::new();
	for case in &cases {
		if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| check(case))).is_err() {
			failed.push(case.name.clone());
		}
	}
	// Counted off this file, so a new corpus test cannot be left out.
	let tests = include_str!("conformance.rs")
		.matches("\teach_case(|case| {")
		.count();
	let mut tally = TALLY.lock().unwrap_or_else(|e| e.into_inner());
	tally.done += 1;
	tally.failed.extend(failed.iter().cloned());
	if tally.done == tests {
		let _hold = std::io::stderr().lock();
		for case in &cases {
			let status = if tally.failed.contains(&case.name) {
				"FAIL"
			} else {
				"ok"
			};
			common::status_line(status, &case.id, &format!("corpus/{}", case.name));
		}
	}
	drop(tally);
	assert!(
		failed.is_empty(),
		"{} case(s) failed: {}",
		failed.len(),
		failed.join(", ")
	);
}

/// A `duration[@UNIT]` or `size[@UNIT][+decimal]` row type, split: the read,
/// the unit a bare number takes, and whether KB to TB are powers of 1000.
fn unit_type(kind: &str) -> (&str, Option<&str>, bool) {
	let (rest, decimal) = match kind.strip_suffix("+decimal") {
		Some(r) => (r, true),
		None => (kind, false),
	};
	match rest.split_once('@') {
		Some((base, unit)) => (base, Some(unit), decimal),
		None => (rest, None, decimal),
	}
}

fn doc_for(case: &Case, level: Strictness) -> Document {
	Document::parse_with(&case.input, level).unwrap_or_else(|e| {
		panic!(
			"{}: load failed at {:?} but reads.tsv has reads there: {}",
			case.name, level, e
		)
	})
}

#[test]
fn canonical_format_matches_expected() {
	let _id = test_id("Ejri0IT");
	each_case(|case| {
		let got = Document::parse(&case.input).to_canonical();
		assert_eq!(
			got, case.expected_fmt,
			"{}: canonical output differs from expected.shcl",
			case.name
		);
		// The formatter must be a fixpoint: canonicalizing its own output changes nothing.
		let again = Document::parse(&got).to_canonical();
		assert_eq!(again, got, "{}: formatter is not idempotent", case.name);
	});
}

/// The load diagnostics of `text` at Standard, spelled the way `check` prints
/// them: one line per diagnostic, then the summary.
fn diag_text(text: &str) -> String {
	let doc = Document::parse(text);
	let diags = doc.diagnostics();
	let mut got = String::new();
	for d in diags {
		got.push_str(&format!("line {}: {:?}: {}\n", d.line, d.severity, d.code));
	}
	let errors = diags
		.iter()
		.filter(|d| d.severity == shcl::Severity::Error)
		.count();
	if errors > 0 {
		got.push_str(&format!(
			"failed: {} diagnostic(s), {} error(s)\n",
			diags.len(),
			errors
		));
	} else {
		got.push_str(&format!("ok ({} diagnostic(s))\n", diags.len()));
	}
	got
}

#[test]
fn diagnostics_match_expected() {
	let _id = test_id("EkoN15s");
	// Pins count, line, severity, and stable code per case - the same shape
	// `check` prints to stdout at Standard (its cross-binding contract).
	each_case(|case| {
		let got = diag_text(&case.input);
		assert_eq!(
			got, case.expected_diags,
			"{}: diagnostics differ from expected-diags.txt",
			case.name
		);
	});
}

#[test]
fn validation_matches_expected() {
	let _id = test_id("EkstvaW");
	// Schema dimension: golden = the exact `check --schema` stdout at Standard
	// (doc parse diags, then validation diags, then the summary). A schema that
	// does not load cleanly is a single V099, mirroring the CLI.
	each_case(|case| {
		let (schema_text, want) = match (&case.schema, &case.expected_validate) {
			(Some(s), Some(w)) => (s, w),
			(None, None) => return,
			_ => panic!(
				"{}: schema.shcl and expected-validate.txt must come as a pair",
				case.name
			),
		};
		let doc = Document::parse(&case.input);
		let mut diags: Vec<shcl::Diagnostic> = doc.diagnostics().to_vec();
		let sdoc = Document::parse(schema_text);
		if sdoc
			.diagnostics()
			.iter()
			.any(|d| d.severity == shcl::Severity::Error)
		{
			diags.push(shcl::Diagnostic {
				line: 0,
				severity: shcl::Severity::Error,
				message: "schema failed to load".to_string(),
				code: "V099",
			});
		} else {
			diags.extend(doc.validate(&sdoc));
			shcl::suppress_declared_repeats(&sdoc, &mut diags);
			shcl::suppress_declared_reopens(&sdoc, &mut diags);
		}
		let mut got = String::new();
		for d in &diags {
			got.push_str(&format!("line {}: {:?}: {}\n", d.line, d.severity, d.code));
		}
		let errors = diags
			.iter()
			.filter(|d| d.severity == shcl::Severity::Error)
			.count();
		if errors > 0 {
			got.push_str(&format!(
				"failed: {} diagnostic(s), {} error(s)\n",
				diags.len(),
				errors
			));
		} else {
			got.push_str(&format!("ok ({} diagnostic(s))\n", diags.len()));
		}
		assert_eq!(
			got, *want,
			"{}: validation output differs from expected-validate.txt",
			case.name
		);
	});
}

#[test]
fn convenience_tier_falls_back_only_on_good() {
	let _id = test_id("EkgmpQe");
	// The get-tier value survives only on Good; Empty/BadType/NotFound all fall
	// back to the call-site default, so a real zero can't be faked. This pins the
	// semantic every port's *Or/get_*(default=) mirrors.
	let doc =
		Document::parse("a: 42\nb: not-a-number\ne:\narr: 1, 2, 3\nblk:\n\t```html\n\thi\n\t```\n");
	assert_eq!(doc.get_int("a").unwrap_or(9), 42); // Good
	assert_eq!(doc.get_int("b").unwrap_or(9), 9); // BadType
	assert_eq!(doc.get_int("e").unwrap_or(9), 9); // Empty still falls back
	assert_eq!(doc.get_int("missing").unwrap_or(9), 9); // NotFound
	assert_eq!(doc.get_int_array("arr").unwrap_or(vec![7]), vec![1, 2, 3]);
	assert_eq!(doc.get_int_array("missing").unwrap_or(vec![7]), vec![7]);
	// Same reads under the cross-binding spelling: `_or` means "with a
	// fallback" everywhere, so a routine ported between two bindings cannot
	// keep the call name while changing which tier it lands on.
	assert_eq!(doc.get_int_or("a", 9), 42);
	assert_eq!(doc.get_int_or("b", 9), 9);
	assert_eq!(doc.get_int_or("e", 9), 9);
	assert_eq!(doc.get_int_or("missing", 9), 9);
	assert_eq!(doc.get_int_array_or("arr", vec![7]), vec![1, 2, 3]);
	assert_eq!(doc.get_int_array_or("missing", vec![7]), vec![7]);
	assert_eq!(doc.get_string_or("missing", "fb".to_string()), "fb");
	// The raw block's info-string was the one typed read with no convenience
	// tier, so it alone forced a caller down to the status tier.
	assert_eq!(doc.get_raw_info("blk").unwrap(), "html");
	assert_eq!(doc.get_raw_info_or("blk", "fb".to_string()), "html");
	assert_eq!(doc.get_raw_info_or("missing", "fb".to_string()), "fb");
	// ok() and the convenience tier deliberately disagree on an explicitly
	// emptied field: one asks whether the author spoke for it, the other whether
	// there is a usable value.
	assert!(doc.read_int("e").ok());
	assert!(!doc.read_int("missing").ok());
}

#[test]
fn reads_match_expected() {
	let _id = test_id("Ejri0IU");
	each_case(|case| {
		for (n, line) in case.reads.lines().enumerate() {
			if n == 0 || line.trim().is_empty() {
				continue; // header
			}
			let cols: Vec<&str> = line.split('\t').collect();
			assert!(
				cols.len() >= 4,
				"{}: reads.tsv line {} too short",
				case.name,
				n + 1
			);
			let (query, kind, expected, status) = (cols[0], cols[1], cols[2], cols[3]);
			let level = parse_level(cols.get(4).copied());
			let at = format!(
				"{}: reads.tsv line {} ({} {})",
				case.name,
				n + 1,
				query,
				kind
			);

			if kind == "load" {
				let ok = Document::parse_with(&case.input, level).is_ok();
				let want = match expected {
					"ok" => true,
					"fail" => false,
					other => panic!("{}: bad load expectation '{}'", at, other),
				};
				assert_eq!(ok, want, "{}: load outcome", at);
				continue;
			}

			let doc = doc_for(case, level);
			if kind == "schema" {
				let got = schema_ref(&case.input).unwrap_or_else(|| "-".to_string());
				assert_eq!(got, expected, "{}: schema", at);
				continue;
			}
			if kind == "lost" {
				let want: usize = expected
					.parse()
					.unwrap_or_else(|_| panic!("{}: bad lost count", at));
				assert_eq!(doc.lost_count(), want, "{}", at);
				continue;
			}
			if kind == "count" {
				let want: usize = expected
					.parse()
					.unwrap_or_else(|_| panic!("{}: bad count", at));
				assert_eq!(doc.count(query), want, "{}", at);
				continue;
			}
			if kind == "instances" {
				let got = doc.instances(query).join("|");
				assert_eq!(got, expected, "{}", at);
				continue;
			}
			if kind == "children" {
				let got = doc.children(query).join("|");
				assert_eq!(got, expected, "{}", at);
				continue;
			}
			if kind == "paths" {
				let got = doc.paths().join("|");
				assert_eq!(got, expected, "{}", at);
				continue;
			}
			if kind == "instance_paths" {
				let got = doc.instance_paths().join("|");
				assert_eq!(got, expected, "{}", at);
				continue;
			}
			if kind == "comments" {
				let got = doc.comments(query).join("|");
				assert_eq!(got, expected, "{}", at);
				continue;
			}

			let (got_value, got_status, got_slots): (String, shcl::Status, Vec<shcl::Status>) =
				match kind {
					"int" => {
						let r = doc.read_int(query);
						(r.value.to_string(), r.status, r.slots)
					}
					"float" => {
						let r = doc.read_float(query);
						(shcl::format_float(r.value), r.status, r.slots)
					}
					"bool" => {
						let r = doc.read_bool(query);
						(r.value.to_string(), r.status, r.slots)
					}
					"datetime" => {
						let r = doc.read_datetime(query);
						(r.value.to_string(), r.status, r.slots)
					}
					"string" => {
						let r = doc.read_string(query);
						(tsv_escape(&r.value), r.status, r.slots)
					}
					"raw" => {
						let r = doc.read_raw(query);
						(tsv_escape(&r.value), r.status, r.slots)
					}
					"rawinfo" => {
						let r = doc.read_raw_info(query);
						(tsv_escape(&r.value), r.status, r.slots)
					}
					k if k.starts_with("duration") || k.starts_with("size") => {
						let (base, unit, decimal) = unit_type(k);
						if base == "duration" {
							let u = unit
								.map(|u| DurationUnit::from_spelling(u).expect("duration unit"));
							let r = doc.read_duration(query, u);
							(r.value.as_millis().to_string(), r.status, r.slots)
						} else {
							let u = unit.map(|u| SizeUnit::from_spelling(u).expect("size unit"));
							let r = doc.read_size(query, u, decimal);
							(r.value.to_string(), r.status, r.slots)
						}
					}
					"int[]" => {
						let r = doc.read_int_array(query);
						(
							r.value
								.iter()
								.map(|v| v.to_string())
								.collect::<Vec<_>>()
								.join("|"),
							r.status,
							r.slots,
						)
					}
					"float[]" => {
						let r = doc.read_float_array(query);
						(
							r.value
								.iter()
								.map(|v| shcl::format_float(*v))
								.collect::<Vec<_>>()
								.join("|"),
							r.status,
							r.slots,
						)
					}
					"bool[]" => {
						let r = doc.read_bool_array(query);
						(
							r.value
								.iter()
								.map(|v| v.to_string())
								.collect::<Vec<_>>()
								.join("|"),
							r.status,
							r.slots,
						)
					}
					"datetime[]" => {
						let r = doc.read_datetime_array(query);
						(
							r.value
								.iter()
								.map(|v| v.to_string())
								.collect::<Vec<_>>()
								.join("|"),
							r.status,
							r.slots,
						)
					}
					"string[]" => {
						let r = doc.read_string_array(query);
						(
							r.value
								.iter()
								.map(|v| tsv_escape(v))
								.collect::<Vec<_>>()
								.join("|"),
							r.status,
							r.slots,
						)
					}
					other => panic!("{}: unknown type '{}'", at, other),
				};
			assert_eq!(format!("{:?}", got_status), status, "{}: status", at);
			if expected != "-" {
				assert_eq!(got_value, expected, "{}: value", at);
			}
			// Optional 6th column: per-slot statuses, |-joined (needs col 5 set).
			if let Some(want_slots) = cols.get(5) {
				let got = got_slots
					.iter()
					.map(|s| format!("{:?}", s))
					.collect::<Vec<_>>()
					.join("|");
				assert_eq!(&got, want_slots, "{}: slots", at);
			}
		}
	});
}

#[test]
fn write_ops_match_expected() {
	let _id = test_id("EkfphiV");
	each_case(|case| {
		let (ops, want, keep) = match (&case.write_ops, &case.expected_write, &case.expected_keep) {
			(Some(o), Some(w), Some(k)) => (o, w, k),
			(None, None, None) => return,
			_ => panic!(
				"{}: write.ops, expected-write.shcl and expected-keep.shcl come together",
				case.name
			),
		};
		// Base doc loads at Standard; ops build/edit it via the library Writer.
		// The one that keeps lines is the same document.
		let mut doc = Document::parse(&case.input);
		let mut kept = Document::parse_keep_lines(&case.input, Strictness::Standard).unwrap();
		for (n, line) in ops.lines().enumerate() {
			if line.is_empty() || line.starts_with('#') {
				continue;
			}
			let at = format!("{}: write.ops line {}", case.name, n + 1);
			apply_op(&mut doc, line, &at);
			apply_op(&mut kept, line, &at);
		}
		let got = doc.to_canonical();
		let (text, lines) = kept.to_text_keep_lines();
		assert_eq!(
			&text, keep,
			"{}: output differs from expected-keep.shcl",
			case.name
		);
		assert!(
			lines || text == got,
			"{}: a save that kept no lines is not canonical",
			case.name
		);
		assert_eq!(
			Document::parse(&text).to_canonical(),
			got,
			"{}: expected-keep.shcl reloads as another document",
			case.name
		);
		assert_eq!(
			&got, want,
			"{}: writer output differs from expected-write.shcl",
			case.name
		);
		// The written doc must be a formatter fixpoint like any canonical output.
		let again = Document::parse(&got).to_canonical();
		assert_eq!(
			again, got,
			"{}: written output is not a fmt fixpoint",
			case.name
		);
	});
}

/// Loaded to keep its lines and saved with no edits, every input is its own
/// text again, byte for byte.
#[test]
fn keeping_lines_without_edits_writes_the_input() {
	let _id = test_id("EqutO7H");
	each_case(|case| {
		let doc = Document::parse_keep_lines(&case.input, Strictness::Standard)
			.unwrap_or_else(|e| e.document);
		assert!(
			doc.to_text_keep_lines() == (case.input.clone(), true),
			"{}: an unedited save changed the text",
			case.name
		);
	});
}

#[test]
fn layered_merge_matches_expected() {
	let _id = test_id("EkyV757");
	// Layered-load dimension: fold the layer files (lowest first) and input.shcl
	// (highest file layer) via the library `merge`, apply the `path=value`
	// overrides as the top layer, and match the golden merged canonical.
	each_case(|case| {
		let Some(want) = &case.expected_merged else {
			return;
		};
		// Ordered lowest -> highest: the layer*.shcl files, then input.shcl.
		let mut texts: Vec<&str> = case.layers.iter().map(|s| s.as_str()).collect();
		texts.push(&case.input);
		let mut doc = Document::parse(texts[0]);
		for t in &texts[1..] {
			doc.merge(&Document::parse(t));
		}
		if let Some(sets) = &case.merge_sets {
			for line in sets.lines() {
				if line.is_empty() || line.starts_with('#') {
					continue;
				}
				let (p, v) = line
					.split_once('=')
					.unwrap_or_else(|| panic!("{}: bad merge.sets line: {}", case.name, line));
				assert!(
					doc.set_string(p, v),
					"{}: merge.set did not apply: {}",
					case.name,
					line
				);
			}
		}
		let got = doc.to_canonical();
		assert_eq!(
			&got, want,
			"{}: merged output differs from expected-merged.shcl",
			case.name
		);
		// Reads answered by the merged document itself, not just its text: a
		// merged arena holds dropped nodes, a rebuilt index and cloned child
		// lists, and only a read walks those. `instances` is left out because it
		// hands back the source spelling, which canonical output may respell.
		// Same fixture in every runner.
		let back = Document::parse(&got);
		assert_eq!(doc.paths(), back.paths(), "{}: merged paths", case.name);
		for p in doc.paths() {
			assert_eq!(
				doc.count(&p),
				back.count(&p),
				"{}: merged count {}",
				case.name,
				p
			);
			assert_eq!(
				doc.children(&p),
				back.children(&p),
				"{}: merged children {}",
				case.name,
				p
			);
			let (x, y) = (doc.read_string(&p), back.read_string(&p));
			assert_eq!(
				(x.value, x.status),
				(y.value, y.status),
				"{}: merged read {}",
				case.name,
				p
			);
			let (x, y) = (doc.read_string_array(&p), back.read_string_array(&p));
			assert_eq!(
				(x.value, x.status, x.slots),
				(y.value, y.status, y.slots),
				"{}: merged array read {}",
				case.name,
				p
			);
		}
		// The merged doc must be a formatter fixpoint like any canonical output.
		let again = Document::parse(&got).to_canonical();
		assert_eq!(
			again, got,
			"{}: merged output is not a fmt fixpoint",
			case.name
		);
	});
}

#[test]
fn migrate_matches_expected() {
	let _id = test_id("Ept4WPh");
	// Migration dimension: `migrate` on the input must reproduce the golden
	// byte for byte, and the golden's load diagnostics are pinned beside it,
	// so a rewrite that no longer loads cannot pass. A fmt fixpoint is not
	// required, since migrate keeps the author's layout; the migrate fixpoint
	// is checked next.
	each_case(|case| {
		let (want, want_diags) = match (&case.expected_migrate, &case.expected_migrate_diags) {
			(Some(w), Some(d)) => (w, d),
			(None, None) => return,
			_ => panic!(
				"{}: expected-migrate.shcl and expected-migrate-diags.txt must come as a pair",
				case.name
			),
		};
		let got = migrate(&case.input, true).text;
		assert_eq!(
			&got, want,
			"{}: migrate output differs from expected-migrate.shcl",
			case.name
		);
		assert_eq!(
			&diag_text(&got),
			want_diags,
			"{}: migrated text's diagnostics differ from expected-migrate-diags.txt",
			case.name
		);
	});
}

#[test]
fn migrate_is_a_fixpoint() {
	let _id = test_id("EpyXoJW");
	each_case(|case| {
		let once = migrate(&case.input, true).text;
		assert_eq!(
			migrate(&once, true).text,
			once,
			"{}: migrate changes its own output",
			case.name
		);
	});
}

#[test]
fn migrate_unstamped_is_migrate_without_the_stamp() {
	let _id = test_id("Eqps7zO");
	// Over every input, not only the migrate cases: the stamp is the one
	// difference, and a file is current exactly when its Format line says so.
	each_case(|case| {
		for from_v2 in [true, false] {
			let full = migrate(&case.input, from_v2);
			let bare = migrate_unstamped(&case.input, from_v2);
			assert_eq!(
				(bare.current, bare.ambiguous, bare.lost),
				(full.current, full.ambiguous, full.lost),
				"{}: counts differ without the stamp",
				case.name
			);
			assert!(
				!bare.text.contains(FORMAT_LINE_HEAD) || case.input.contains(FORMAT_LINE_HEAD),
				"{}: migrate_unstamped wrote a Format line",
				case.name
			);
			let mut want = bare.text.clone();
			if !full.current && full.text != bare.text {
				if !want.is_empty() && !want.ends_with('\n') {
					want.push('\n');
				}
				want.push_str(FORMAT_LINE);
				want.push('\n');
				if bare.text != case.input {
					want.push_str(MIGRATED_LINE);
					want.push('\n');
				}
			}
			assert_eq!(
				full.text, want,
				"{}: the stamp is not the only difference",
				case.name
			);
			assert_eq!(
				full.current,
				format_version(&case.input).is_some_and(|v| v >= FORMAT_MAJOR),
				"{}: current disagrees with format_version",
				case.name
			);
		}
	});
}

#[test]
fn init_generation_matches_expected() {
	let _id = test_id("EkyZiCX");
	// Generation dimension: `generate` on the schema must reproduce the golden
	// starter config, and that output must itself load cleanly.
	each_case(|case| {
		let (schema, want) = match (&case.init_schema, &case.expected_init) {
			(Some(s), Some(w)) => (s, w),
			(None, None) => return,
			_ => panic!(
				"{}: init-schema.shcl and expected-init.shcl must come as a pair",
				case.name
			),
		};
		let got = generate(&Document::parse(schema), false)
			.unwrap_or_else(|_| panic!("{}: init schema has faults", case.name));
		assert_eq!(
			&got, want,
			"{}: init output differs from expected-init.shcl",
			case.name
		);
		// The footer is the only difference the flag makes: everything before
		// it is byte-for-byte what the default run produced.
		let bare = generate(&Document::parse(schema), true)
			.unwrap_or_else(|_| panic!("{}: init schema has faults", case.name));
		assert!(
			!bare.is_empty() && got.starts_with(&bare),
			"{}: --no-banner output is not a prefix of the default",
			case.name
		);
		assert!(
			got[bare.len()..].contains("This config file format is SHCL."),
			"{}: default init output is missing the format footer",
			case.name
		);
		// The generated starter must be valid SHCL, and load without so much as
		// a hint: a starter that hints on its own first lines (H002 from a
		// parent re-opened after another field) teaches a reader to ignore them.
		let doc = Document::parse(&got);
		assert!(
			doc.diagnostics().is_empty(),
			"{}: generated starter does not load cleanly: {:?}",
			case.name,
			doc.diagnostics()
		);
		// And it must satisfy the very schema that produced it - case 026's
		// golden once failed its own schema (repeat lower bound and a
		// materialized wildcard were ignored).
		let sdoc = Document::parse(schema);
		let vs = doc.validate(&sdoc);
		assert!(
			!vs.iter().any(|d| d.severity == shcl::Severity::Error),
			"{}: generated starter fails its own schema: {:?}",
			case.name,
			vs
		);
	});
}

#[test]
fn depth_cap_boundary_and_writer() {
	let _id = test_id("El5Aber");
	// Exactly at the cap: loads clean, formats, and round-trips.
	let segs: Vec<String> = (0..shcl::MAX_DEPTH).map(|i| format!("a{}", i)).collect();
	let at_cap = format!("{}: 1", segs.join("."));
	let doc = Document::parse(&at_cap);
	assert!(doc.diagnostics().is_empty(), "at-cap doc must load clean");
	let out = doc.to_canonical();
	assert_eq!(Document::parse(&out).to_canonical(), out);
	// One past the cap: a single E016, line skipped, strict load fails.
	let over = format!("a.{}: 1", segs.join("."));
	let doc2 = Document::parse(&over);
	assert_eq!(doc2.diagnostics().len(), 1);
	assert_eq!(doc2.diagnostics()[0].code, "E016");
	assert_eq!(doc2.to_canonical(), "");
	// The Writer refuses to create past the cap and stays a no-op.
	let mut w = Document::new();
	let deep_path = format!("a.{}", segs.join("."));
	assert!(!w.set_int(&deep_path, 1), "a too-deep path is not writable");
	assert!(
		!w.exists("a"),
		"writer must not half-create a too-deep path"
	);
	assert!(w.set_int(&segs.join("."), 2));
	assert!(w.exists("a0"), "writer must still create an at-cap path");
}

#[test]
fn parse_limited_caps() {
	let _id = test_id("Eoe5NRw");
	// The caps exist because a document amplifies to many times its byte size
	// in memory, so read_file's byte cap alone cannot bound a load. Same
	// fixture in every runner.
	use shcl::Strictness;
	// Node cap: one E020 at the first line not parsed, the remainder counts
	// as lost, and what parsed before the cap stays readable.
	let text = "a: 1\nb: 2\nc: 3\nd: 4\n";
	let doc = Document::parse_limited(text, Strictness::Standard, 2, 0, 0).unwrap();
	let e020: Vec<_> = doc
		.diagnostics()
		.iter()
		.filter(|d| d.code == "E020")
		.collect();
	assert_eq!(e020.len(), 1, "one E020");
	assert_eq!(e020[0].line, 4);
	assert_eq!(doc.lost_count(), 1);
	assert_eq!(doc.get_int("a"), Ok(1));
	assert!(!doc.exists("d"), "the remainder must not parse");
	// A cap crossed by the document's last content line still reports.
	let doc = Document::parse_limited("a: 1\nb: 2\nc: 3", Strictness::Standard, 2, 0, 0).unwrap();
	assert_eq!(
		doc.diagnostics()
			.iter()
			.filter(|d| d.code == "E020")
			.count(),
		1
	);
	assert_eq!(doc.lost_count(), 0, "nothing was dropped");
	// One line may overshoot the cap by its own path; the parse still stops.
	let doc = Document::parse_limited("x.y.z: 1\n", Strictness::Standard, 1, 0, 0).unwrap();
	assert_eq!(
		doc.diagnostics()
			.iter()
			.filter(|d| d.code == "E020")
			.count(),
		1
	);
	assert_eq!(doc.get_int("x.y.z"), Ok(1));
	// 0 is no cap: identical to parse_with.
	let doc = Document::parse_limited(text, Strictness::Standard, 0, 0, 0).unwrap();
	assert!(doc.diagnostics().is_empty());
	// Element cap, inline spelling: the whole line is refused, the rest of the
	// document is untouched.
	let doc =
		Document::parse_limited("arr: 1, 2, 3\nok: 5\n", Strictness::Standard, 0, 2, 0).unwrap();
	let e021: Vec<_> = doc
		.diagnostics()
		.iter()
		.filter(|d| d.code == "E021")
		.collect();
	assert_eq!(e021.len(), 1, "one E021");
	assert_eq!(e021[0].line, 1);
	assert!(!doc.exists("arr"));
	assert_eq!(doc.get_int("ok"), Ok(5));
	assert_eq!(doc.lost_count(), 1);
	// Element cap, stacked spelling: each element line past the cap is refused
	// on its own; the array keeps what fit.
	let doc = Document::parse_limited("arr:\n\t* 1\n\t* 2\n\t* 3\n", Strictness::Standard, 0, 2, 0)
		.unwrap();
	assert_eq!(
		doc.diagnostics()
			.iter()
			.filter(|d| d.code == "E021")
			.count(),
		1
	);
	assert_eq!(doc.get_int_array("arr"), Ok(vec![1, 2]));
	// A cap refuses only a line that would bind: bracket text stays E019 and
	// kept, and an element under a field with a value stays E011.
	let doc = Document::parse_limited(
		"arr: [1, 2, 3]\nk: x\n\t* 1\n",
		Strictness::Standard,
		0,
		1,
		0,
	)
	.unwrap();
	let codes: Vec<_> = doc.diagnostics().iter().map(|d| (d.line, d.code)).collect();
	assert_eq!(codes, vec![(1, "E019"), (3, "E011")]);
	assert_eq!(doc.lost_count(), 1);
	assert!(doc.to_canonical().contains("arr: [1, 2, 3]"));
	// The count the cap judges is the count the array reads back as, spelling
	// by spelling: quoted commas, a backslash (a character, so it shields
	// nothing), empty and blank slots, a Unicode blank (content: only a space
	// or a tab is blank), a quote that never closes (a character too, so the
	// comma after it splits). Refused at one under, kept at exact.
	#[rustfmt::skip]
	let counts: &[(&str, usize)] = &[
		("1, 2, 3", 3), ("\"a, b\", c", 2), ("a\\, b, c", 3), ("a,,b", 2),
		("a, , b", 2), (" a ", 1), ("\"\", ''", 2), ("'a\", b'", 1),
		("\"open, b", 2), ("\\", 1), ("x,\u{3000}", 2), ("x, \u{a0}y", 2), (", , ,", 0),
	];
	for &(spelling, n) in counts {
		let text = format!("v: {spelling}\n");
		let doc = Document::parse_limited(&text, Strictness::Standard, 0, n.max(1), 0).unwrap();
		assert!(
			!doc.diagnostics().iter().any(|d| d.code == "E021"),
			"{spelling:?} at cap {n}"
		);
		if n == 0 {
			assert!(
				doc.exists("v") && doc.get_string_array("v").is_err(),
				"{spelling:?} empty"
			);
		} else {
			assert_eq!(
				doc.get_string_array("v").map(|a| a.len()),
				Ok(n),
				"{spelling:?}"
			);
		}
		if n >= 2 {
			let doc = Document::parse_limited(&text, Strictness::Standard, 0, n - 1, 0).unwrap();
			assert_eq!(doc.lost_count(), 1, "{spelling:?} at cap {}", n - 1);
		}
	}
	// A refused line reports the cap alone: the quote check runs after it, so
	// it never splits a value the cap already turned away.
	let doc = Document::parse_limited("v: a, \"open, b\n", Strictness::Standard, 0, 1, 0).unwrap();
	let codes: Vec<&str> = doc.diagnostics().iter().map(|d| d.code).collect();
	assert_eq!(codes, ["E021"]);
	// A fence whose info string splits past the cap is refused with its block,
	// in both spellings, so the body never reads as live lines. Same fixture in
	// every runner.
	for text in [
		"secrets:\n\t```a,b,c,d\n\tpassword: hunter2\n\t```\nafter: 1\n",
		"secrets: ```a,b,c,d\n\tpassword: hunter2\n\t```\nafter: 1\n",
	] {
		let doc = Document::parse_limited(text, Strictness::Standard, 0, 3, 0).unwrap();
		let codes: Vec<&str> = doc.diagnostics().iter().map(|d| d.code).collect();
		assert_eq!(codes, ["E021"], "{text:?}");
		assert!(!doc.exists("secrets.password"), "{text:?}");
		assert_eq!(doc.get_int("after"), Ok(1), "{text:?}");
		assert_eq!(doc.lost_count(), 1, "{text:?}");
	}
	// Diagnostic cap: the first N are listed and one E022 tail counts the
	// rest. Its severity is Error when any unlisted one was, so a scan of the
	// list for errors still finds one and error_count stays nonzero.
	let bad = "no colon\n".repeat(50);
	let doc = Document::parse_limited(&bad, Strictness::Standard, 0, 0, 10).unwrap();
	assert_eq!(doc.diagnostics().len(), 11);
	assert!(doc.diagnostics()[..10].iter().all(|d| d.code == "E014"));
	let tail = &doc.diagnostics()[10];
	assert_eq!(
		(tail.code, tail.severity, tail.line),
		("E022", shcl::Severity::Error, 0)
	);
	assert_eq!(
		tail.message,
		"diagnostic cap of 10 reached; 40 more not listed, 40 of them errors"
	);
	assert_eq!(doc.error_count(), 11);
	assert!(Document::parse_limited(&bad, Strictness::Strict, 0, 0, 10).is_err());
	// Hints past the cap leave a Hint tail, so a document with no error
	// still loads at Strict.
	let hints = "x: 1\nx: 2\ny: 1\ny: 2\n";
	let doc = Document::parse_limited(hints, Strictness::Strict, 0, 0, 1).unwrap();
	let codes: Vec<(&str, shcl::Severity)> = doc
		.diagnostics()
		.iter()
		.map(|d| (d.code, d.severity))
		.collect();
	assert_eq!(
		codes,
		[
			("H001", shcl::Severity::Hint),
			("E022", shcl::Severity::Hint)
		]
	);
	assert!(
		doc.diagnostics()[1]
			.message
			.ends_with("1 more not listed, 0 of them errors")
	);
	assert_eq!(doc.error_count(), 0);
	// At the cap exactly, nothing is unlisted and there is no tail.
	let doc = Document::parse_limited(hints, Strictness::Standard, 0, 0, 2).unwrap();
	assert_eq!(doc.diagnostics().len(), 2);
	// A cap diagnostic is an error, so a capped Strict load fails - with the
	// parsed part still on the error.
	let err = Document::parse_limited(text, Strictness::Strict, 2, 0, 0).unwrap_err();
	assert_eq!(err.document.get_int("a"), Ok(1));
}

#[test]
fn write_bad_ops_are_rejected() {
	let _id = test_id("El5Gcy6");
	// Bad-op dimension: each write-bad.ops line, applied alone to the case
	// input, must be rejected (bad value, bad datetime, or unusable path) and
	// leave the document unchanged.
	// The names-no-op guard below is only worth something while a misspelled
	// op still comes back told apart from an ordinary refusal.
	let mut probe = Document::parse("a: 1\n");
	let e = try_apply_op(&mut probe, "itn\ta\t1").unwrap_err();
	assert!(
		e.starts_with(UNKNOWN_OP),
		"a misspelled op read as a refusal: {}",
		e
	);
	let e = try_apply_op(&mut probe, "int\ta\tx").unwrap_err();
	assert!(
		!e.starts_with(UNKNOWN_OP),
		"a refusal read as a misspelled op: {}",
		e
	);
	each_case(|case| {
		let Some(bad) = &case.write_bad_ops else {
			return;
		};
		for (n, line) in bad.lines().enumerate() {
			if line.is_empty() || line.starts_with('#') {
				continue;
			}
			let mut doc = Document::parse(&case.input);
			let before = doc.to_canonical();
			match try_apply_op(&mut doc, line) {
				Ok(()) => panic!(
					"{}: write-bad.ops line {} was accepted: {}",
					case.name,
					n + 1,
					line
				),
				Err(e) => assert!(
					!e.starts_with(UNKNOWN_OP),
					"{}: write-bad.ops line {} names no op: {}",
					case.name,
					n + 1,
					line
				),
			}
			assert_eq!(
				doc.to_canonical(),
				before,
				"{}: write-bad.ops line {} changed the document: {}",
				case.name,
				n + 1,
				line
			);
		}
	});
}

#[test]
fn one_shot_load_and_validate() {
	let _id = test_id("Elp3cOg");
	// One combined diagnostics list (parse first, then validation) and an
	// error predicate, so recover-and-continue can't read as success by
	// accident. Same fixture in every runner.
	let text = ": nope\nport: x\n";
	let schema = "field: port\n\ttype: int\n";
	let doc = shcl::Document::load_and_validate(text, schema, Strictness::Standard);
	let codes: Vec<&str> = doc.diagnostics().iter().map(|d| d.code).collect();
	assert_eq!(codes, vec!["E014", "V003"]);
	assert_eq!(doc.error_count(), 2);
	assert_eq!(doc.read_string("port").value, "x"); // doc still usable
	// Strict never throws here; the diagnostics are the answer.
	let strict = shcl::Document::load_and_validate(text, schema, Strictness::Strict);
	assert!(strict.error_count() >= 2);
	// An empty schema declares nothing and validates nothing.
	let plain = shcl::Document::load_and_validate("a: 1\n", "", Strictness::Standard);
	assert_eq!((plain.error_count(), plain.diagnostics().len()), (0, 0));
}

#[test]
fn write_reason_names_the_failure() {
	let _id = test_id("ElouJ8K");
	// The reason behind a setter's bare false. Same fixture in every runner.
	let doc = Document::parse("a:\n\tb: 1\n");
	use shcl::WriteReason::*;
	assert_eq!(doc.write_reason("a.b"), Writable);
	assert_eq!(doc.write_reason("a.new[Boston].x"), Writable); // creatable
	assert_eq!(doc.write_reason(""), BadPath);
	assert_eq!(doc.write_reason("a..b"), BadPath);
	assert_eq!(doc.write_reason("a.b: 2"), ValueInPath);
	assert_eq!(doc.write_reason("a[*].b"), Wildcard);
	assert_eq!(doc.write_reason("a[#5].b"), NoSuchIndex);
	assert_eq!(doc.write_reason("nope[#0].b"), NoSuchIndex);
	let deep = vec!["d"; 513].join(".");
	assert_eq!(doc.write_reason(&deep), TooDeep);
	// A literal line break is writable wherever a path can carry one: a name
	// emits through the name escaper and a selector value through the value
	// emitter, and both spell a break `\n` and read it back as one. The
	// selector was refused while the value emitter still wrote elements in
	// their source spelling and had nothing to escape with. Not corpus-pinnable
	// - an ops line cannot carry a raw newline.
	assert_eq!(doc.write_reason("a[\"p\nq\"].b"), Writable);
	assert_eq!(doc.write_reason("\"x\ny\".b"), Writable);
	assert_eq!(doc.write_reason("\"x\\ny\".b"), Writable);
	// The probe never creates: the doc is unchanged after all of the above.
	assert_eq!(doc.count("a"), 1);
	assert_eq!(doc.paths(), vec!["a", "a.b"]);
}

#[test]
fn setters_refuse_a_value_the_reader_refuses() {
	let _id = test_id("Eof29pY");
	// Each setter is the inverse of its read, so a value with no spelling the
	// reader accepts fails the write and leaves the document alone. Same
	// fixture in every runner.
	use shcl::{ShclDateTime, Zone};
	let mut doc = Document::parse("z: 0\n");
	for v in [f64::INFINITY, f64::NEG_INFINITY, f64::NAN] {
		assert!(!doc.set_float("f", v), "{v}");
		assert!(!doc.set_float_default("f", v), "{v}");
		assert!(!doc.set_float_array("f", &[1.0, v]), "{v}");
		// A default form on a path that is already there writes nothing, and
		// still refuses what the plain setter would.
		assert!(!doc.set_float_default("z", v), "{v}");
		assert!(!doc.set_float_array_default("z", &[1.0, v]), "{v}");
	}
	assert!(doc.set_float("f", 2.5) && doc.get_float("f") == Ok(2.5));
	assert!(doc.set_float_default("z", 2.5) && doc.get_float("z") == Ok(0.0));
	let good = |d: Option<(i32, u32, u32)>, t: Option<(u32, u32, Option<u32>)>| ShclDateTime {
		date: d,
		time: t,
		frac: None,
		zone: None,
	};
	let with = |dt: ShclDateTime, frac: Option<&str>, zone: Option<Zone>| ShclDateTime {
		frac: frac.map(str::to_string),
		zone,
		..dt
	};
	let bad = [
		ShclDateTime::default(),                                 // nothing written
		good(Some((2026, 13, 1)), None),                         // month 13
		good(Some((2026, 2, 30)), None),                         // February 30
		good(Some((-1, 1, 1)), None),                            // negative year
		good(None, Some((24, 0, None))),                         // hour 24
		with(good(None, Some((1, 2, None))), Some("5"), None),   // fraction with no seconds
		with(good(None, Some((1, 2, Some(3)))), Some(""), None), // empty fraction
		with(good(None, Some((1, 2, Some(3)))), Some("12345678901"), None), // 11 digits
		with(
			good(None, Some((1, 2, None))),
			None,
			Some(Zone::OffsetMinutes(9999)),
		), // +166:39
		with(good(Some((2026, 1, 1)), None), None, Some(Zone::Utc)), // zone on a date alone
	];
	for dt in &bad {
		assert!(!doc.set_datetime("d", dt), "{dt}");
		assert!(!doc.set_datetime_default("d", dt), "{dt}");
		assert!(
			!doc.set_datetime_array("d", &[good(Some((2026, 1, 1)), None), dt.clone()]),
			"{dt}"
		);
		assert!(!doc.set_datetime_default("z", dt), "{dt}");
		assert!(
			!doc.set_datetime_array_default("z", &[good(Some((2026, 1, 1)), None), dt.clone()]),
			"{dt}"
		);
	}
	let ok = with(
		good(Some((2026, 1, 2)), Some((3, 4, Some(5)))),
		Some("60"),
		Some(Zone::OffsetMinutes(-90)),
	);
	assert!(doc.set_datetime("d", &ok));
	assert_eq!(doc.get_datetime("d"), Ok(ok));
	assert_eq!(
		doc.to_canonical(),
		"z: 0\n\nf: 2.5\n\nd: \"2026-01-02T03:04:05.60-01:30\"\n"
	);
}

#[test]
fn a_line_break_in_a_path_writes_and_reads_back() {
	let _id = test_id("EpGigIK");
	// Both halves of a path can carry one and spell it `\n`: a name through the
	// name escaper, a selector value through the value emitter. The selector
	// was refused while elements were stored in their source spelling and the
	// emitter had nothing to escape with. Same fixture in every runner.
	let mut doc = Document::parse("z: 0\n");
	assert!(doc.set_int("x[\"p\nq\"].c", 1));
	assert!(doc.set_int("\"a\nb\".c", 1));
	let text = doc.to_canonical();
	let back = Document::parse(&text);
	assert_eq!(back.error_count(), 0);
	assert_eq!(back.to_canonical(), text);
	assert_eq!(back.read_int("x[\"p\\nq\"].c").value, 1);
	assert_eq!(back.read_int("\"a\\nb\".c").value, 1);
	assert_eq!(back.read_int("\"a\nb\".c").value, 1);
}

#[test]
fn raw_block_line_endings_normalize_and_round_trip() {
	let _id = test_id("EnLyQsU");
	// A raw body is the only content kept untrimmed, so it is the only place a
	// trailing CR survives the load - and one written back becomes CRLF, which
	// reads as neither. The whole trailing run comes off instead; a CR inside a
	// line is content and stays. Same fixture in every runner: a golden would be
	// rewritten by any platform's line-ending translation.
	let doc = Document::parse("r:\n\t~~~\n\tone\r\r\n\ta\rb\n\t~~~\n");
	assert_eq!(doc.read_raw("r").value, "one\na\rb");
	let canon = doc.to_canonical();
	assert_eq!(Document::parse(&canon).to_canonical(), canon);
}

#[test]
fn children_and_instance_paths_walk_a_repeated_key() {
	let _id = test_id("Eqps7zP");
	// gitsby's report: children() on a repeated key answered nothing, and a
	// walk had to know to index each instance.
	let doc =
		Document::parse("account: w\n\temail: e@x\n\t\tsshkey: k1\n\temail: f@x\n\t\tsshkey: k2\n");
	assert_eq!(doc.children("account[#0].email"), vec!["sshkey", "sshkey"]);
	assert_eq!(doc.children("account.email[#1]"), vec!["sshkey"]);
	assert_eq!(
		doc.instance_paths(),
		vec![
			"account",
			"account.email[#0]",
			"account.email[#0].sshkey",
			"account.email[#1]",
			"account.email[#1].sshkey",
		]
	);
	assert_eq!(
		doc.get_string("account.email[#1].sshkey"),
		Ok("k2".to_string())
	);
}

#[test]
fn read_surface_line_quoted_children() {
	let _id = test_id("ElorUZk");
	// line/quoted on the read result, line(path), children(path). Same
	// fixture in every runner (C pins the same answers on shcl_quoted and
	// shcl_line; its read structs stay value+status).
	let text = "a: @null\nb: \"@null\"\ncode:\n\thook: 1\n\thook: 2\n\tdone: 3\n";
	let doc = Document::parse(text);
	assert!(!doc.read_string("a").quoted);
	assert!(doc.read_string("b").quoted);
	assert!(!doc.read_string("code").quoted);
	assert!(!doc.read_string("missing").quoted);
	// An array read of the same node answers the same: a one-element cell has
	// a single scalar element, so the flag means what it does on the scalar
	// read. More than one element, and there is no single element to report.
	assert!(doc.read_string_array("b").quoted);
	assert!(!doc.read_string_array("a").quoted);
	assert!(
		!Document::parse("m: \"x\", \"y\"\n")
			.read_string_array("m")
			.quoted
	);
	assert_eq!(doc.read_string("b").line, 2);
	assert_eq!(doc.line("code.done"), 6);
	assert_eq!(doc.line("code"), 3);
	assert_eq!(doc.line("missing"), 0);
	// lines(): the plural - a repeated field cites every binding, wildcard
	// slots keep their index (0 = unresolved), a miss is the empty list.
	assert_eq!(doc.line("code.hook"), 0); // Multiple - the singular's gap
	assert_eq!(doc.lines("code.hook"), vec![4, 5]);
	assert_eq!(doc.lines("code.done"), vec![6]);
	assert_eq!(doc.lines("a"), vec![1]);
	assert_eq!(doc.lines("code[*].done"), vec![6]);
	assert_eq!(doc.lines("code[*].nope"), vec![0]);
	assert!(doc.lines("missing").is_empty());
	assert_eq!(doc.children("code"), vec!["hook", "hook", "done"]);
	assert_eq!(doc.children(""), vec!["a", "b", "code"]);
	assert!(doc.children("missing").is_empty());
	// authored_name(): the author's spelling, unfolded; merged instances keep
	// the first binding's; unresolved or Multiple is empty; writer-built
	// keeps the setter path's spelling.
	let text2 = "SYMBOLS: 3\nCode:\n\tx: 1\ncode:\n\ty: 2\n";
	let mut d2 = Document::parse(text2);
	assert_eq!(d2.authored_name("symbols"), "SYMBOLS");
	assert_eq!(d2.authored_name("SYMBOLS"), "SYMBOLS");
	assert_eq!(d2.authored_name("code"), "Code");
	assert_eq!(d2.authored_name("missing"), "");
	assert!(d2.set_int("NewTop.n", 1));
	assert_eq!(d2.authored_name("newtop"), "NewTop");
	// Escapes ARE resolved on a name, so both spellings of the path find the
	// same node - while authored_name still hands back the source spelling,
	// which is the one thing it is for. Same fixture in every runner.
	let d3 = Document::parse("\"Ab\\tCd\": 2\n");
	assert_eq!(d3.authored_name("\"ab\\tcd\""), "Ab\\tCd");
	assert_eq!(d3.authored_name("\"ab\tcd\""), "Ab\\tCd");
	assert_eq!(d3.read_int("\"ab\tcd\"").value, 2);
	// Canonical output folds the case, as it always has, and escapes the tab.
	assert_eq!(d3.to_canonical(), "\"ab\\tcd\": 2\n");
}

#[test]
fn file_tier_load_save() {
	let _id = test_id("EnEYHTs");
	// load_file/save_file: the status separates absent / unreadable / parsed
	// with errors / clean, and a save round-trips through the atomic write.
	// Same fixture in every runner.
	use shcl::FileStatus;
	let dir = std::env::temp_dir().join(format!("shcl-filetier-{}", std::process::id()));
	std::fs::create_dir_all(&dir).unwrap();
	let f = dir.join("t.shcl");
	let fs = f.to_str().unwrap();

	let (_, st) = Document::load_file(fs);
	assert_eq!(st, FileStatus::NotFound);
	let (_, st) = Document::load_file(dir.to_str().unwrap()); // a directory is not readable
	assert_eq!(st, FileStatus::Unreadable);
	// Bad encoding is unreadable too: the parser assumes well-formed text, so a
	// binary file loading clean would read back mangled and a later save would
	// write the mangled version over the original.
	std::fs::write(&f, b"a: 1\nb: \xff\xfe bad\n").unwrap();
	let (doc, st) = Document::load_file(fs);
	assert_eq!(st, FileStatus::Unreadable);
	assert_eq!(doc.to_canonical(), "");

	std::fs::write(&f, "a: 1\n: broken\n").unwrap();
	let (doc, st) = Document::load_file(fs);
	assert_eq!(st, FileStatus::HadErrors);
	assert_eq!(doc.get_int("a"), Ok(1));

	std::fs::write(&f, "a: 1\nb: x\n").unwrap();
	let (mut doc, st) = Document::load_file(fs);
	assert_eq!(st, FileStatus::Clean);
	// read_file is the load's read half on its own: the exact bytes, or the
	// status. The cap counts bytes, and a file exactly at it passes. Same
	// fixture in every runner.
	assert_eq!(shcl::read_file(fs, 0), Ok("a: 1\nb: x\n".to_string()));
	assert_eq!(shcl::read_file(fs, 10), Ok("a: 1\nb: x\n".to_string()));
	assert_eq!(shcl::read_file(fs, 9), Err(FileStatus::Unreadable));
	assert_eq!(
		shcl::read_file(dir.join("none.shcl").to_str().unwrap(), 0),
		Err(FileStatus::NotFound)
	);
	assert!(doc.set_int("c", 3));
	doc.save_file(fs).unwrap();
	let (back, st) = Document::load_file(fs);
	assert_eq!(st, FileStatus::Clean);
	assert_eq!(back.to_canonical(), doc.to_canonical());

	// Creating a file and overwriting one are two different code paths in the
	// write - the create picks its own mode, the overwrite copies the target's,
	// and the publish step differs by platform (windows goes through
	// ReplaceFile, with a rename fallback). Both run everywhere: an overwrite
	// used to throw outright on windows in the python binding, which no
	// POSIX-only fixture could ever have caught. Same fixture in every runner.
	let fresh = dir.join("fresh.shcl");
	let fresh_s = fresh.to_str().unwrap().to_string();
	let fdoc = Document::parse("a: 1\n");
	fdoc.save_file(&fresh_s).unwrap();
	let (back, st) = Document::load_file(&fresh_s);
	assert_eq!(st, FileStatus::Clean);
	assert_eq!(back.to_canonical(), "a: 1\n");
	fdoc.save_file(&fresh_s).unwrap();
	let (back, st) = Document::load_file(&fresh_s);
	assert_eq!(st, FileStatus::Clean);
	assert_eq!(back.to_canonical(), "a: 1\n");

	// A new file lands where an ordinary create lands - 0666 narrowed by the
	// umask - and an existing one keeps the mode it had. Neither is visible on
	// stdout, so no corpus case can see either, and neither is a windows
	// concept, so the mode half is POSIX-only.
	#[cfg(unix)]
	{
		use std::os::unix::fs::PermissionsExt;
		let mode_of =
			|p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
		let probe = dir.join("probe");
		std::fs::File::create(&probe).unwrap();
		let born = dir.join("born.shcl");
		fdoc.save_file(born.to_str().unwrap()).unwrap();
		assert_eq!(mode_of(&born), mode_of(&probe));
		std::fs::set_permissions(&born, std::fs::Permissions::from_mode(0o640)).unwrap();
		fdoc.save_file(born.to_str().unwrap()).unwrap();
		assert_eq!(mode_of(&born), 0o640);
		// setuid and setgid come over too: applying the mode before the data
		// lets the kernel clear them on the write.
		let id_of =
			|p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o7777;
		std::fs::set_permissions(&born, std::fs::Permissions::from_mode(0o6750)).unwrap();
		if id_of(&born) == 0o6750 {
			fdoc.save_file(born.to_str().unwrap()).unwrap();
			assert_eq!(id_of(&born), 0o6750, "save dropped a set-id bit");
		} else {
			// Setgid is cleared when the file's group is not one of the caller's,
			// which happens on ordinary boxes. The skip was silent, so this
			// fixture passed wherever it fired.
			eprintln!(
				"conformance: skipping the set-id fixture (mode came back {:o}, want 6750)",
				id_of(&born)
			);
		}
		let _ = std::fs::remove_file(&probe);
		let _ = std::fs::remove_file(&born);
	}
	let _ = std::fs::remove_file(&fresh);

	let _ = std::fs::remove_file(&f);
	let _ = std::fs::remove_dir(&dir);
}

#[test]
fn read_file_at_the_largest_cap() {
	let _id = test_id("EoLwIlh");
	// A cap spelled as the type maximum used to overflow the over-cap probe and
	// read nothing. Same fixture in every runner.
	let dir = std::env::temp_dir().join(format!("shcl-readcap-{}", std::process::id()));
	std::fs::create_dir_all(&dir).unwrap();
	let f = dir.join("t.shcl");
	std::fs::write(&f, "a: 1\n").unwrap();
	assert_eq!(
		shcl::read_file(f.to_str().unwrap(), usize::MAX),
		Ok("a: 1\n".to_string())
	);
	let _ = std::fs::remove_file(&f);
	let _ = std::fs::remove_dir(&dir);
}

#[test]
fn set_raw_keeps_a_shared_indent_and_trims_the_info() {
	let _id = test_id("EoLwIli");
	// The body's shared indent survives a reload (the closing fence's indent is
	// what comes off), the info-string is stored as a fence line reads it
	// back, and an info with a line break or a `#` has no spelling and fails
	// the write. Same fixture in every runner.
	let mut doc = Document::new();
	assert!(doc.set_raw("q", "  a\n  b", " sql "));
	let back = Document::parse(&doc.to_canonical());
	assert_eq!(back.get_raw("q"), Ok("  a\n  b".to_string()));
	assert_eq!(back.read_raw_info("q").value, "sql");
	assert!(!doc.set_raw("q", "x", "a\nb"));
	// A trailing CR is a blank and comes off, as the load takes it; one
	// mid-info is content.
	assert!(doc.set_raw("q", "x", "ab\r"));
	assert_eq!(
		Document::parse(&doc.to_canonical())
			.read_raw_info("q")
			.value,
		"ab"
	);
	assert!(doc.set_raw("q", "x", "a\rb"));
	assert_eq!(
		Document::parse(&doc.to_canonical())
			.read_raw_info("q")
			.value,
		"a\rb"
	);
	assert!(!doc.set_raw("q", "x", "a # b"));
	// An info string has no quoting of its own: quotes are characters in it,
	// so they hide nothing, and a `#` glued to the label opens a comment too.
	assert!(!doc.set_raw("q", "x", "\"a # b\""));
	assert!(!doc.set_raw("q", "x", "c#"));
	// A body line ending in CR has no fence spelling: the load takes the whole
	// trailing CR run off every line, so it is refused rather than lost. A CR
	// mid-line is content and still round-trips.
	assert!(!doc.set_raw("q", "a\r\nb", ""));
	assert!(!doc.set_raw("q", "\r", ""));
	assert!(doc.set_raw("q", "a\rb", ""));
	let back = Document::parse(&doc.to_canonical());
	assert_eq!(back.get_raw("q"), Ok("a\rb".to_string()));
}

#[cfg(unix)]
#[test]
fn save_creates_the_file_behind_a_dangling_symlink() {
	let _id = test_id("EoLwIlj");
	// A link to a file that is not there yet is written through like any other
	// link: the file appears where the link points and the link stays a link.
	// Same fixture in every POSIX runner.
	let dir = std::env::temp_dir().join(format!("shcl-dangling-{}", std::process::id()));
	std::fs::create_dir_all(dir.join("real")).unwrap();
	let link = dir.join("c.shcl");
	std::os::unix::fs::symlink("real/c.shcl", &link).unwrap();
	let doc = Document::parse("a: 1\n");
	doc.save_file(link.to_str().unwrap()).unwrap();
	assert!(
		std::fs::symlink_metadata(&link)
			.unwrap()
			.file_type()
			.is_symlink()
	);
	assert_eq!(
		std::fs::read_to_string(dir.join("real/c.shcl")).unwrap(),
		"a: 1\n"
	);
	let _ = std::fs::remove_file(&link);
	let _ = std::fs::remove_file(dir.join("real/c.shcl"));
	let _ = std::fs::remove_dir(dir.join("real"));
	let _ = std::fs::remove_dir(&dir);
}

#[cfg(unix)]
#[test]
fn save_reports_a_symlink_cycle_instead_of_replacing_it() {
	let _id = test_id("EoUxXlQ");
	// Two links pointing at each other resolve to nothing, so the save fails
	// and says why. It must not "fix" the cycle by dropping a regular file over
	// one of the links. Same fixture in every POSIX runner.
	let dir = std::env::temp_dir().join(format!("shcl-cycle-{}", std::process::id()));
	std::fs::create_dir_all(&dir).unwrap();
	let (a, b) = (dir.join("a.shcl"), dir.join("b.shcl"));
	std::os::unix::fs::symlink("b.shcl", &a).unwrap();
	std::os::unix::fs::symlink("a.shcl", &b).unwrap();
	let doc = Document::parse("a: 1\n");
	assert!(doc.save_file(a.to_str().unwrap()).is_err());
	for link in [&a, &b] {
		assert!(
			std::fs::symlink_metadata(link)
				.unwrap()
				.file_type()
				.is_symlink(),
			"a symlink cycle was replaced by a regular file"
		);
	}
	let _ = std::fs::remove_file(&a);
	let _ = std::fs::remove_file(&b);
	let _ = std::fs::remove_dir(&dir);
}

#[cfg(unix)]
#[test]
fn save_replaces_only_a_regular_file() {
	let _id = test_id("EqLbKe8");
	// Save outcomes in design.md, the rows the CLI's own check hides. A FIFO
	// was swapped for a regular file at exit 0, a link whose text names a
	// directory made a file of that name, and Go cleaned `lnk/..` as text where
	// the kernel follows lnk first. Same fixture in every POSIX runner.
	let dir = std::env::temp_dir().join(format!("shcl-targets-{}", std::process::id()));
	let _ = std::fs::remove_dir_all(&dir);
	std::fs::create_dir_all(dir.join("real/sub")).unwrap();
	std::fs::create_dir_all(dir.join("top")).unwrap();
	let doc = Document::parse("a: 1\n");
	let fifo = dir.join("p.shcl");
	assert!(
		std::process::Command::new("mkfifo")
			.arg(&fifo)
			.status()
			.unwrap()
			.success()
	);
	assert!(doc.save_file(fifo.to_str().unwrap()).is_err());
	assert!(
		std::os::unix::fs::FileTypeExt::is_fifo(
			&std::fs::symlink_metadata(&fifo).unwrap().file_type()
		),
		"a FIFO was replaced by a regular file"
	);
	let ldir = dir.join("l.shcl");
	std::os::unix::fs::symlink("d/", &ldir).unwrap();
	assert!(doc.save_file(ldir.to_str().unwrap()).is_err());
	assert!(
		!dir.join("d").exists(),
		"a link naming a directory made a file"
	);
	std::os::unix::fs::symlink("../real/sub", dir.join("top/lnkdir")).unwrap();
	std::os::unix::fs::symlink("../x.shcl", dir.join("real/sub/f.shcl")).unwrap();
	doc.save_file(dir.join("top/lnkdir/f.shcl").to_str().unwrap())
		.unwrap();
	assert_eq!(
		std::fs::read_to_string(dir.join("real/x.shcl")).unwrap(),
		"a: 1\n"
	);
	assert!(!dir.join("top/x.shcl").exists());
	let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(windows)]
#[test]
fn save_rewrites_a_read_only_file() {
	let _id = test_id("EoLwIlk");
	// A read-only target is rewritten, as it is on POSIX, and comes back
	// read-only; no temp file is left behind. Same fixture in every runner.
	let dir = std::env::temp_dir().join(format!("shcl-readonly-{}", std::process::id()));
	std::fs::create_dir_all(&dir).unwrap();
	let f = dir.join("ro.shcl");
	std::fs::write(&f, "a: 1\n").unwrap();
	let mut perms = std::fs::metadata(&f).unwrap().permissions();
	perms.set_readonly(true);
	std::fs::set_permissions(&f, perms).unwrap();
	let doc = Document::parse("a: 2\n");
	doc.save_file(f.to_str().unwrap()).unwrap();
	assert_eq!(std::fs::read_to_string(&f).unwrap(), "a: 2\n");
	assert!(std::fs::metadata(&f).unwrap().permissions().readonly());
	let left: Vec<_> = std::fs::read_dir(&dir).unwrap().collect();
	assert_eq!(left.len(), 1);
	let mut perms = std::fs::metadata(&f).unwrap().permissions();
	perms.set_readonly(false);
	std::fs::set_permissions(&f, perms).unwrap();
	// Hidden and system come back too: ReplaceFile's preserve list does not
	// include the basic attributes and the fallback rename carries none, so a
	// hidden config used to come back visible.
	set_attrs(&f, 0x2 | 0x4);
	Document::parse("a: 3\n")
		.save_file(f.to_str().unwrap())
		.unwrap();
	let after = {
		use std::os::windows::fs::MetadataExt;
		std::fs::metadata(&f).unwrap().file_attributes()
	};
	assert!(after & 0x2 != 0, "file did not come back hidden");
	assert!(after & 0x4 != 0, "file did not come back system");
	set_attrs(&f, 0x80); // FILE_ATTRIBUTE_NORMAL, so the cleanup below works
	let _ = std::fs::remove_file(&f);
	let _ = std::fs::remove_dir(&dir);
}

#[cfg(windows)]
fn set_attrs(path: &std::path::Path, attrs: u32) {
	use std::os::windows::ffi::OsStrExt;
	#[link(name = "kernel32")]
	unsafe extern "system" {
		fn SetFileAttributesW(name: *const u16, attrs: u32) -> i32;
	}
	let wide: Vec<u16> = path
		.as_os_str()
		.encode_wide()
		.chain(std::iter::once(0))
		.collect();
	unsafe {
		SetFileAttributesW(wide.as_ptr(), attrs);
	}
}

/// A path that names a directory - it ends in a separator, or its last
/// component is `.` or `..` - is not a document. A canonicalize drops the
/// trailing separator first, so `save_file("f/")` used to rewrite `f`. Same
/// fixture in every runner.
#[test]
fn save_refuses_a_directory_shaped_path() {
	let _id = test_id("EomvfCq");
	let dir = std::env::temp_dir().join(format!("shcl-dirpath-{}", std::process::id()));
	std::fs::create_dir_all(&dir).unwrap();
	let f = dir.join("f.shcl");
	std::fs::write(&f, "a: 1\n").unwrap();
	let doc = Document::parse("a: 2\n");
	for suffix in ["/", "/.", "/.."] {
		let p = format!("{}{}", f.display(), suffix);
		assert!(
			doc.save_file(&p).is_err(),
			"save through {:?} was accepted",
			p
		);
	}
	assert_eq!(std::fs::read_to_string(&f).unwrap(), "a: 1\n");
	assert!(doc.save_file(f.to_str().unwrap()).is_ok());
	assert_eq!(std::fs::read_to_string(&f).unwrap(), "a: 2\n");
	let _ = std::fs::remove_file(&f);
	let _ = std::fs::remove_dir(&dir);
}

/// A written value carrying both quote kinds is stored the way its own reload
/// stores it, so `instances` and a read's raw text agree across a save. The
/// emitter escapes the double quotes; the writer used to keep them bare. Same
/// fixture in every runner.
#[test]
fn written_spelling_matches_its_reload() {
	let _id = test_id("EommtF2");
	let mut d = Document::parse("x: 1\n");
	assert!(d.set_string("k", "q\"q'"));
	let back = Document::parse(&d.to_canonical());
	assert_eq!(back.instances("k"), d.instances("k"));
	assert_eq!(d.get_string_or("k", String::new()), "q\"q'");
}

/// The name index used to be rebuilt by walking the arena, which still holds
/// every node a set-and-remove cycle ever made - so the first read after a
/// merge grew with the number of edits, not with the document. Timed against
/// the same document with no dead nodes; the ratio is what matters, since an
/// absolute figure would be a machine constant. Same fixture in every runner.
#[test]
fn index_rebuild_ignores_removed_nodes() {
	let _id = test_id("EomjcaW");
	let mut ms = [0.0f64; 2];
	for (churned, slot) in ms.iter_mut().enumerate() {
		let mut d = Document::parse("g:\n\tk: 1\n");
		if churned == 1 {
			// A subtree per cycle, not a leaf. A removed leaf leaves its
			// parent's list, so the old walk only stepped over it and cost
			// three times a sound build. A removed subtree keeps its own list,
			// and the old walk indexed every dead child.
			for i in 0..50_000 {
				assert!(d.set_int("g.tmp.x", i));
				assert_eq!(d.remove("g.tmp"), 1);
			}
		}
		let other = Document::parse("g:\n\tk: 1\n");
		let t0 = std::time::Instant::now();
		for _ in 0..2000 {
			d.merge(&other);
			assert_eq!(d.get_int_or("g.k", -1), 1);
		}
		*slot = t0.elapsed().as_secs_f64() * 1000.0;
	}
	// A generous ratio on purpose: the chain array is still sized by the arena,
	// which is a memset the walk cannot avoid. What the bound catches is the
	// walk itself going over every dead node, which is orders larger. Two
	// thousand merges put that cost well past the constant term a shared
	// runner needs; at two hundred the constant could absorb the defect.
	// A clock too coarse to see the fresh side leaves the ratio with no
	// denominator. That used to skip the judgment, and it skipped it silently
	// on the one platform where it fires - the hosted windows job. The constant
	// term alone is an absolute figure on whatever machine is running, so it
	// gets room: the healthy churned side has measured half a second there, and
	// the defect is tens of seconds.
	let bound = if ms[0] <= 0.0 {
		3000.0
	} else {
		ms[0] * 25.0 + 1000.0
	};
	assert!(
		ms[1] <= bound,
		"index rebuild after churn {:.1} ms against {:.1} ms fresh (bound {:.1} ms) - it walks nodes the document no longer holds",
		ms[1],
		ms[0],
		bound
	);
}

/// A merge settles the comments of the blocks it visited, not of the whole
/// tree: a whole-tree pass made each small merge cost the document, and a
/// caller folding many layers onto a big one paid it every time. Timed against
/// the same merges with the big block left out. Same fixture in every runner.
#[test]
fn merge_settles_only_what_it_touched() {
	let _id = test_id("EqoaM6C");
	let mut ms = [0.0f64; 2];
	for (big, slot) in ms.iter_mut().enumerate() {
		let mut text = String::from("g:\n\tk: 1\n");
		if big == 1 {
			text.push_str("big:\n");
			for i in 0..100_000 {
				text.push_str(&format!("\tc{i}: {i}\n"));
			}
		}
		let mut d = Document::parse(&text);
		let other = Document::parse("g:\n\tk: 1\n");
		let t0 = std::time::Instant::now();
		for _ in 0..2000 {
			d.merge(&other);
		}
		*slot = t0.elapsed().as_secs_f64() * 1000.0;
		assert_eq!(d.get_int_or("g.k", -1), 1);
	}
	// The same bound as the index fixture above: the defect is a walk over a
	// hundred thousand nodes per merge, seconds past the constant term.
	let bound = if ms[0] <= 0.0 {
		3000.0
	} else {
		ms[0] * 25.0 + 1000.0
	};
	assert!(
		ms[1] <= bound,
		"2000 merges beside a big block {:.1} ms against {:.1} ms without it (bound {:.1} ms) - the merge settles blocks it never touched",
		ms[1],
		ms[0],
		bound
	);
}

/// A misplaced line kept as written made every edit and merge re-emit the
/// whole document to settle it, even one far from the line. Timed against
/// the same steps on the same document without the line. Same fixture in
/// every runner.
#[test]
fn a_far_kept_line_costs_an_edit_nothing() {
	let _id = test_id("EqqmFxQ");
	let mut ms = [0.0f64; 2];
	for (kept, slot) in ms.iter_mut().enumerate() {
		let mut text = String::from("g:\n\tk: 1\nbig:\n");
		for i in 0..100_000 {
			text.push_str(&format!("\tc{i}: {i}\n"));
		}
		if kept == 1 {
			text.push_str(" x: y\n");
		}
		let mut d = Document::parse(&text);
		let other = Document::parse("g:\n\tj: 1\n");
		let t0 = std::time::Instant::now();
		// Edits first: a merge drops the name index, and the edit after it
		// would rebuild it over the whole document either way.
		for i in 0..500 {
			assert!(d.set_int("g.k", i));
		}
		for _ in 0..500 {
			d.merge(&other);
		}
		*slot = t0.elapsed().as_secs_f64() * 1000.0;
		assert_eq!(d.get_int_or("g.k", -1), 499);
		assert_eq!(d.to_canonical().ends_with("\n x: y\n"), kept == 1);
	}
	let bound = if ms[0] <= 0.0 {
		3000.0
	} else {
		ms[0] * 25.0 + 1000.0
	};
	assert!(
		ms[1] <= bound,
		"500 edits and merges beside a kept line {:.1} ms against {:.1} ms without it (bound {:.1} ms) - each one settles the whole document",
		ms[1],
		ms[0],
		bound
	);
}

#[test]
fn standard_trait_surface() {
	let _id = test_id("EnLJ3Jw");
	// Rust-only: the traits a rust user reaches for before reading any docs.
	// Nothing here is new behavior, so there is no cross-binding fixture - the
	// other three already export the same capabilities under their own names.
	use std::str::FromStr;
	let doc = Document::from_str("a: 1\nb: 2\n").unwrap();
	assert_eq!(doc.to_string(), doc.to_canonical());
	assert_eq!(
		"a: 1\n".parse::<Document>().unwrap().to_canonical(),
		"a: 1\n"
	);
	// Clone is a deep copy: editing the copy must not reach the original.
	let mut copy = doc.clone();
	assert!(copy.set_int("a", 9));
	assert_eq!(doc.get_int("a"), Ok(1));
	assert_eq!(copy.get_int("a"), Ok(9));
	assert_eq!(shcl::Status::BadType.to_string(), "BadType");
	assert_eq!(shcl::format_float(1.5), "1.5");
	assert_eq!(shcl::format_float(f64::INFINITY), "inf");
	assert_eq!(shcl::format_float(f64::NAN), "NaN");
	// Go's name for the datetime type, kept as an alias here and in Python.
	let _: shcl::DateTime = shcl::ShclDateTime::default();
}

#[test]
fn lost_and_save_gate() {
	let _id = test_id("EnEclpx");
	// Content-malformed lines are retained as trivia (lost_count 0, the line
	// survives a save); position-dependent drops count as lost and make
	// save_file refuse until the caller opts into save_file_lossy. Same
	// fixture in every runner.
	let kept = Document::parse("a: 1\nsquare-miles 300\nb: 2\n");
	assert_eq!(kept.lost_count(), 0);
	assert!(kept.to_canonical().contains("square-miles 300\n"));
	// An indent matching no level is kept as written when it holds a space,
	// which no level the emitter writes can equal, and lost when it is tabs.
	let spaced = Document::parse("a:\n\tb: 1\n  c: 2\n\td: 3\n");
	assert_eq!(spaced.lost_count(), 0);
	assert_eq!(spaced.to_canonical(), "a:\n\tb: 1\n  c: 2\n\td: 3\n");
	let lost = Document::parse("a:\n\t\tb: 1\n\tc: 2\n");
	assert_eq!(lost.lost_count(), 1);
	let dir = std::env::temp_dir().join(format!("shcl-lostgate-{}", std::process::id()));
	std::fs::create_dir_all(&dir).unwrap();
	let f = dir.join("t.shcl");
	let fs = f.to_str().unwrap();
	assert!(kept.save_file(fs).is_ok());
	let (back, _) = Document::load_file(fs);
	assert!(back.to_canonical().contains("square-miles 300\n"));
	assert!(lost.save_file(fs).is_err());
	assert!(lost.save_file_lossy(fs).is_ok());
	// A refusal and a failed write are separate values, not two spellings of one
	// message, and the gate answers before any i/o - so an unwritable path still
	// reports the refusal. Same fixture in every runner.
	let bad = dir.join("nope").join("t.shcl");
	let bads = bad.to_str().unwrap();
	assert!(matches!(kept.save_file(bads), Err(shcl::SaveError::Io(_))));
	assert!(matches!(
		lost.save_file(bads),
		Err(shcl::SaveError::Refused { lost: 1, .. })
	));
	// A save that keeps lines writes the dropped line back as it was, so it
	// refuses only when it falls back to canonical. Here removing the line
	// above it would make it a child of `a`.
	let mut keep =
		Document::parse_keep_lines("a:\n\t\tb: 1\n\tc: 2\n", Strictness::Standard).unwrap();
	assert!(keep.set_int("a.b", 5));
	assert!(matches!(keep.save_file_keep_lines(fs), Ok(true)));
	assert_eq!(
		std::fs::read_to_string(fs).unwrap(),
		"a:\n\t\tb: 5\n\tc: 2\n"
	);
	assert_eq!(keep.remove("a.b"), 1);
	assert!(matches!(
		keep.save_file_keep_lines(fs),
		Err(shcl::SaveError::Refused { lost: 1, .. })
	));
	let _ = std::fs::remove_file(&f);
	let _ = std::fs::remove_dir(&dir);
}

#[test]
fn strict_failure_carries_document() {
	let _id = test_id("Elop5Fg");
	// A failed strict load hands back the document and names the first
	// failures in the message - the diagnostics are the point.
	let e = Document::parse_with("ok: 1\n: nope\n", Strictness::Strict).unwrap_err();
	assert!(!e.diagnostics.is_empty());
	assert_eq!(e.document.read_int("ok").value, 1);
	let msg = e.to_string();
	assert!(msg.contains("; line "), "{}", msg);
}

#[test]
fn raw_is_source_text() {
	let _id = test_id("ElonRnN");
	// raw: the verbatim value span from the source line - not the display
	// join, which rewrites `{2,3}` to `{2, 3}`. Same fixture in every runner
	// whose read result exposes raw (the C read structs deliberately do not).
	let doc = Document::parse("regex: ^\\d{2,3}$\nlist: a,  \"b c\"\n");
	assert_eq!(doc.read_string("regex").raw.as_deref(), Some("^\\d{2,3}$"));
	assert_eq!(
		doc.read_string_array("list").raw.as_deref(),
		Some("a,  \"b c\"")
	);
	// A written value has no source spelling; raw falls back to display. The
	// selector's escaped spelling must land on the existing instance.
	let mut doc2 = Document::parse("who: 'q\"uote'\n");
	assert!(doc2.set_int("who[\"q\\\"uote\"].n", 5));
	assert_eq!(doc2.count("who"), 1);
	let r = doc2.read_int("who['q\"uote'].n");
	assert_eq!((r.value, r.status), (5, shcl::Status::Good));
	assert_eq!(doc2.read_int("who['q\"uote'].n").raw.as_deref(), Some("5"));
}

#[test]
fn paths_enumeration_shape() {
	let _id = test_id("El5WdwW");
	// paths(): file order, deduplicated, non-bare segments quoted so every
	// path resolves. Same fixture is pinned in every runner.
	let doc = Document::parse("a: 1\na.b: 2\n\"q n\": 3\nx:\n\tb: 4\nx.b: 5\n");
	assert_eq!(doc.paths(), vec!["a", "a.b", "\"q n\"", "x", "x.b"]);
	for p in doc.paths() {
		assert!(doc.count(&p) >= 1, "emitted path does not resolve: {}", p);
	}
	// quote_segment: same spelling both directions, injection-safe.
	assert_eq!(quote_segment("port"), "port");
	assert_eq!(quote_segment("q n"), "\"q n\"");
	assert_eq!(quote_segment("a.b"), "\"a.b\"");
	let r = doc.read_int(&quote_segment("q n"));
	assert_eq!((r.value, r.status), (3, shcl::Status::Good));
}

#[test]
fn generation_bounds_a_multiplying_schema() {
	let _id = test_id("ElupzhR");
	// A chain longer than the nesting cap would outrun the stack if it were
	// followed all the way down; it is noted like a re-entering mount instead.
	// Too big for a golden, so it is pinned here (like the depth-cap case).
	let mut s = String::new();
	for i in 0..2000 {
		s.push_str(&format!(
			"fragment: f{}\n\tfield: c{}\n\t\tinherits: f{}\n",
			i,
			i,
			i + 1
		));
	}
	s.push_str("fragment: f2000\n\tfield: leaf\nfield: top\n\tinherits: f0\n");
	let out = generate(&Document::parse(&s), false).expect("deep chain should generate");
	assert!(
		out.contains("not generated"),
		"deep chain should be noted, not expanded"
	);
	// And what it does emit still loads clean, which is generation's promise.
	assert_eq!(Document::parse(&out).diagnostics().len(), 0);

	// Fragments mounted at two paths each double per level. Past the field
	// ceiling that is a schema fault, not an output nothing can hold.
	let mut b = String::new();
	for i in 0..26 {
		b.push_str(&format!(
			"fragment: g{}\n\tfield: a\n\t\tinherits: g{}\n\tfield: b\n\t\tinherits: g{}\n",
			i,
			i + 1,
			i + 1
		));
	}
	b.push_str("fragment: g26\n\tfield: leaf\nfield: top\n\tinherits: g0\n");
	let err = generate(&Document::parse(&b), false).expect_err("multiplying schema should fault");
	assert_eq!(err.len(), 1);
	assert_eq!(err[0].code, "V096");
}

#[test]
fn one_shot_load_reports_a_broken_schema() {
	let _id = test_id("Eluygyu");
	// A schema that does not load would otherwise drop the constraints on its
	// broken lines, or report every field as unknown - blaming the document.
	// Same fixture in every runner.
	let schema = "field: apikey\n\ttype: string\n  required: true\n";
	let doc = Document::load_and_validate("host: example\n", schema, Strictness::Standard);
	let ds = doc.diagnostics();
	assert_eq!(ds.len(), 1, "expected only the schema fault, got {:?}", ds);
	assert_eq!(ds[0].code, "V099");
	assert_eq!(doc.error_count(), 1);
	// A schema that loads still validates normally.
	let ok = Document::load_and_validate("host: example\n", "field: host\n", Strictness::Standard);
	assert_eq!(ok.error_count(), 0);
	// An empty schema still means "skip validation", not "everything unknown".
	let none = Document::load_and_validate("host: example\n", "", Strictness::Standard);
	assert_eq!(none.error_count(), 0);
}

#[test]
fn quote_segment_backslash_round_trips() {
	let _id = test_id("Elv59bc");
	// A name ending in a backslash: the quoted spelling must not let the
	// closing quote be read as an escape pair.
	let mut doc = Document::new();
	let p = quote_segment("a\\");
	assert!(
		doc.set_int(&p, 7),
		"path from quote_segment must be writable"
	);
	let r = doc.read_int(&p);
	assert_eq!((r.value, r.status), (7, shcl::Status::Good));
	// Survives emit + reparse, and every enumerated path still resolves.
	let re = Document::parse(&doc.to_canonical());
	assert_eq!(re.read_int(&p).value, 7);
	for path in re.paths() {
		assert!(
			re.count(&path) >= 1,
			"emitted path does not resolve: {}",
			path
		);
	}
	// Runs of backslashes: only a dangling odd run doubles.
	for name in ["\\", "a\\\\", "b\\\\\\", "\\.x"] {
		let mut d2 = Document::new();
		let q = quote_segment(name);
		assert!(d2.set_int(&q, 3), "unwritable path for {:?}", name);
		assert_eq!(d2.read_int(&q).value, 3, "value lost for {:?}", name);
	}
}

#[test]
fn repeat_suppression_uses_parsed_leaf() {
	let _id = test_id("Elv59bd");
	// A quoted last segment with a dot must not disavow an unrelated field
	// that happens to carry the split-off text.
	let schema = Document::parse("field: a.\"b.c\"\n\trepeat: 0, 5\nfield: c\n");
	let doc = Document::parse("c: 1\nc: 2\n");
	let mut diags = doc.diagnostics().to_vec();
	assert_eq!(diags.iter().filter(|d| d.code == "H001").count(), 1);
	shcl::suppress_declared_repeats(&schema, &mut diags);
	assert_eq!(
		diags.iter().filter(|d| d.code == "H001").count(),
		1,
		"hint on 'c' wrongly suppressed by the a.\"b.c\" repeat"
	);
	// The declared leaf itself stays disavowed, quoted dot and all.
	let doc2 = Document::parse("a:\n\t\"b.c\": 1\n\t\"b.c\": 2\n");
	let mut d2 = doc2.diagnostics().to_vec();
	assert_eq!(d2.iter().filter(|d| d.code == "H001").count(), 1);
	shcl::suppress_declared_repeats(&schema, &mut d2);
	assert_eq!(d2.iter().filter(|d| d.code == "H001").count(), 0);
}

#[test]
fn huge_selector_index_is_not_found() {
	let _id = test_id("Elv59be");
	// An index at or past 2^32 must report not-found on every target width,
	// never wrap into a live element (pins the contract; 64-bit passes either way).
	let doc = Document::parse("a: 1\na: 2\n");
	assert_eq!(
		doc.read_int("a[#4294967296]").status,
		shcl::Status::NotFound
	);
	assert_eq!(
		doc.read_int("a[#18446744073709551615]").status,
		shcl::Status::NotFound
	);
	assert_eq!(doc.count("a[#4294967296]"), 0);
	assert_eq!(
		doc.write_reason("a[#4294967296]"),
		shcl::WriteReason::NoSuchIndex
	);
	let mut w = Document::parse("a: 1\na: 2\n");
	assert!(!w.set_int("a[#4294967296]", 9));
	// In-range still works.
	assert_eq!(doc.read_int("a[#1]").value, 2);
}

#[test]
fn nul_name_does_not_satisfy_a_dotted_schema_path() {
	let _id = test_id("ElvEcEa");
	// The unknown-field chain key is length-prefixed, not NUL-joined: a single
	// field whose name literally contains a NUL must not impersonate the
	// two-segment path x.y. Same fixture in every runner.
	let schema = Document::parse("field: x.y\n");
	let doc = Document::parse("\"x\u{0}y\": 1\n");
	let vs = doc.validate(&schema);
	assert_eq!(vs.len(), 1, "NUL-bearing name slipped past the sweep");
	assert_eq!(vs[0].code, "V001");
	assert!(vs[0].message.starts_with("unknown field "));
	// The genuinely two-segment spelling still validates clean.
	let ok = Document::parse("x:\n\ty: 1\n");
	assert!(ok.validate(&schema).is_empty());
}

/// The alphabet the setter round-trip fixture draws from: every character
/// that means something to the tokenizer, plus a blank the load trims and a
/// no-break space it does not. Same fixture in every runner.
const SETTER_SOUP: &[&str] = &[
	"\"", "'", "\\", "#", ",", "[", "]", "\r", "\n", " ", "\t", "\u{a0}", "a",
];

/// Every string of one and two characters over that alphabet, and the empty
/// string.
fn soup_inputs() -> Vec<String> {
	let mut out = vec![String::new()];
	for a in SETTER_SOUP {
		out.push((*a).to_string());
		for b in SETTER_SOUP {
			out.push(format!("{}{}", a, b));
		}
	}
	out
}

/// A setter writes only what reads back. Each one builds its text through the
/// emitter and hands it to the tokenizer before the document is touched, so
/// for every input either the call refuses and the document is byte-identical,
/// or the canonical text reloads to itself and the read gives the value back.
/// Twelve review items were one setter's own trim, carriage-return or `#` rule
/// disagreeing with the parser's. Every accepted write also goes into one
/// document that is saved and loaded back at the end, since the file tier
/// checks what an in-memory reload does not: a setter once took bytes the
/// save wrote and the next load refused. Same fixture in every runner.
#[test]
fn setters_write_only_what_reads_back() {
	let _id = test_id("EpGRxM0");
	let mut all = Document::parse("");
	let mut slot = 0;
	for s in soup_inputs() {
		for kind in 0..6 {
			let mut doc = Document::parse("k: 1\n");
			let before = doc.to_canonical();
			let set = |d: &mut Document, p: &str| match kind {
				0 => d.set_string(p, &s),
				1 => d.set_literal(p, &s),
				2 => d.set_comment(p, &s),
				3 => d.set_raw(p, &s, "t"),
				4 => d.set_raw(p, "body", &s),
				_ => d.set_string_array(p, &["x", s.as_str()]),
			};
			let applied = set(&mut doc, "k");
			if applied {
				slot += 1;
				assert!(
					set(&mut all, &format!("k{slot}")),
					"slot {slot} refused what k took (setter {kind}, input {s:?})"
				);
			}
			if !applied {
				assert_eq!(
					doc.to_canonical(),
					before,
					"a refused write changed the document (setter {}, input {:?})",
					kind,
					s
				);
				continue;
			}
			let text = doc.to_canonical();
			let back = Document::parse(&text);
			assert_eq!(
				back.to_canonical(),
				text,
				"written text is not a fixpoint (setter {}, input {:?}):\n{}",
				kind,
				s,
				text
			);
			assert_eq!(
				back.instances("k"),
				doc.instances("k"),
				"the value read differs after a reload (setter {}, input {:?}):\n{}",
				kind,
				s,
				text
			);
			match kind {
				0 => assert_eq!(back.read_string("k").value, s, "string {:?}", s),
				// A comment has no accessor of its own, so the oracle is the
				// text: whatever the load would keep of what was handed in has
				// to be in the document, not a shortened form of it.
				2 => assert!(
					text.contains(s.trim_end_matches([' ', '\t', '\r'])),
					"the comment handed in is not in the document ({:?}):\n{}",
					s,
					text
				),
				3 | 4 => {
					assert_eq!(back.get_raw("k"), doc.get_raw("k"), "raw body {:?}", s);
					assert_eq!(
						back.read_raw_info("k").value,
						doc.read_raw_info("k").value,
						"raw info {:?}",
						s
					);
				}
				5 => assert_eq!(
					back.read_string_array("k").value,
					vec!["x".to_string(), s.clone()],
					"array {:?}",
					s
				),
				_ => {}
			}
		}
		// The same rule for a name: whatever `quote_segment` spells has to come
		// back as one segment holding that name, or the write is refused.
		let path = shcl::quote_segment(&s);
		let mut doc = Document::parse("k: 1\n");
		let before = doc.to_canonical();
		let applied = doc.set_string(&path, "v");
		if applied {
			assert!(
				all.set_string(&path, "v"),
				"the name {s:?} was refused the second time"
			);
		}
		if !applied {
			assert_eq!(
				doc.to_canonical(),
				before,
				"a refused name write changed the document ({:?})",
				s
			);
			continue;
		}
		let text = doc.to_canonical();
		let back = Document::parse(&text);
		assert_eq!(
			back.to_canonical(),
			text,
			"name {:?} is not a fixpoint:\n{}",
			s,
			text
		);
		assert_eq!(
			back.read_string(&path).value,
			"v",
			"name {:?} did not read back:\n{}",
			s,
			text
		);
	}
	let dir = std::env::temp_dir().join(format!("shcl-setters-{}", std::process::id()));
	std::fs::create_dir_all(&dir).unwrap();
	let f = dir.join("all.shcl");
	let fs = f.to_str().unwrap();
	assert!(
		all.save_file(fs).is_ok(),
		"every accepted write together would not save"
	);
	let (back, st) = Document::load_file(fs);
	assert_eq!(
		st,
		shcl::FileStatus::Clean,
		"every accepted write together did not load clean"
	);
	assert_eq!(
		back.to_canonical(),
		all.to_canonical(),
		"every accepted write together changed on a save and load"
	);
	std::fs::remove_dir_all(&dir).unwrap();
}
