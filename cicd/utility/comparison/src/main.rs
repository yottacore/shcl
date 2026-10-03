// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! Measures SHCL against JSON, YAML, TOML and XML on documents that hold the
//! same data in each format.
//!
//! The comparison holds the language constant within a tier: every format in the
//! Rust tier is parsed by a mature native crate, built by the same compiler with
//! the same flags, so what is being compared is formats rather than
//! implementations. The Python tier repeats the exercise over the same documents
//! with the libraries a Python program would really import, which is the only way
//! to tell how much of a format's cost is the format and how much is one
//! implementation of it. Rows are never ranked across tiers.
//!
//! Each measurement runs in its own process, because peak resident memory is
//! only attributable that way - one process that parsed six documents tells you
//! nothing about what any one of them cost.
//!
//! Results go to a SHCL file, which is both the point and the dogfood: the file
//! is read, updated and pruned through this repo's own library.

mod bench;
mod model;

use model::{Fmt, Gen, Shape};
use std::collections::HashMap;
use std::io::Read as _;
use std::process::{Command, Stdio};

const HELP: &str = "\
shcl-comparison - measure SHCL against JSON, YAML, TOML and XML

Usage: shcl-comparison [options]

  --mib N          target size of each scaling shape's SHCL encoding (default
                   16); the config and ddl shapes carry their own realistic size
  --iters N        timed runs per measurement, best wins (default 3); scaled up
                   on a document small enough to parse in microseconds
  --shape NAME     only this shape; repeatable (flat, deep, records, text,
                   config, ddl)
  --tier NAME      only this language tier; repeatable (rust, python)
  --entry KEY      only this library; repeatable (shcl, json, yaml, toml,
                   toml-edit, xml, xml-dom, xml-lxml)
  --out FILE       results file to update (default results.shcl beside this tool)
  --keep-runs N    runs to retain in the results file, newest first (default 20)
  --no-record      print the table and write nothing
  --work DIR       where to generate documents (default a fresh temp dir)
  --keep           leave the generated documents behind
  --verify-units N units used for the pre-flight equivalence check (default 200)
  --no-verify      skip that check
  -h, --help       this text
";

struct Opts {
	mib: usize,
	iters: usize,
	shapes: Vec<Shape>,
	tiers: Vec<Tier>,
	entries: Vec<String>,
	out: String,
	keep_runs: usize,
	record: bool,
	work: Option<String>,
	keep: bool,
	verify_units: usize,
	verify: bool,
}

fn main() {
	let argv: Vec<String> = std::env::args().collect();

	// Worker mode: one measurement, one process, key=value on stdout.
	if argv.len() >= 5 && argv[1] == "--worker" {
		worker(&argv[2], &argv[3], argv[4].parse().unwrap_or(1));
		return;
	}

	let opts = match parse_args(&argv[1..]) {
		Ok(o) => o,
		Err(e) => {
			eprintln!("shcl-comparison: {e}");
			eprintln!("\n{HELP}");
			std::process::exit(2);
		}
	};
	std::process::exit(orchestrate(&opts));
}

fn parse_args(args: &[String]) -> Result<Opts, String> {
	let mut o = Opts {
		mib: 16,
		iters: 3,
		shapes: Vec::new(),
		tiers: Vec::new(),
		entries: Vec::new(),
		out: format!("{}/results.shcl", env!("CARGO_MANIFEST_DIR")),
		keep_runs: 20,
		record: true,
		work: None,
		keep: false,
		verify_units: 200,
		verify: true,
	};
	let mut i = 0;
	while i < args.len() {
		let a = args[i].as_str();
		macro_rules! next {
			($opt:expr) => {{
				i += 1;
				args.get(i)
					.cloned()
					.ok_or_else(|| format!("{} wants a value", $opt))?
			}};
		}
		match a {
			"-h" | "--help" => {
				print!("{HELP}");
				std::process::exit(0);
			}
			"--mib" => {
				o.mib = next!("--mib")
					.parse()
					.map_err(|_| "--mib wants a positive integer".to_string())?
			}
			"--iters" => {
				o.iters = next!("--iters")
					.parse()
					.map_err(|_| "--iters wants a positive integer".to_string())?
			}
			"--shape" => {
				let v = next!("--shape");
				o.shapes
					.push(Shape::from_name(&v).ok_or(format!("unknown shape: {v}"))?);
			}
			"--tier" => {
				let v = next!("--tier");
				o.tiers
					.push(Tier::from_name(&v).ok_or(format!("unknown tier: {v}"))?);
			}
			"--entry" => o.entries.push(next!("--entry")),
			"--out" => o.out = next!("--out"),
			"--keep-runs" => {
				o.keep_runs = next!("--keep-runs")
					.parse()
					.map_err(|_| "--keep-runs wants an integer".to_string())?
			}
			"--no-record" => o.record = false,
			"--work" => o.work = Some(next!("--work")),
			"--keep" => o.keep = true,
			"--verify-units" => {
				o.verify_units = next!("--verify-units")
					.parse()
					.map_err(|_| "--verify-units wants an integer".to_string())?
			}
			"--no-verify" => o.verify = false,
			other => return Err(format!("unknown option: {other}")),
		}
		i += 1;
	}
	if o.mib == 0 || o.iters == 0 {
		return Err("--mib and --iters must be at least 1".into());
	}
	if o.shapes.is_empty() {
		o.shapes = Shape::all().to_vec();
	}
	if o.tiers.is_empty() {
		o.tiers = vec![Tier::Rust, Tier::Python];
	}
	Ok(o)
}

// Generation

fn emit_unit(g: &mut Gen, o: &mut String, shape: Shape, i: usize) {
	match shape {
		Shape::Flat => {
			let (k, n) = model::flat_unit(i);
			g.entry(o, &k, &n);
		}
		Shape::Deep => {
			let (k, n) = model::deep_unit(i);
			g.entry(o, &k, &n);
		}
		Shape::Text => {
			let (k, n) = model::text_unit(i);
			g.entry(o, &k, &n);
		}
		Shape::Records => {
			let (name, f) = model::record_unit(i);
			// Records and Ddl are the two shapes list_key names; the unwrap cannot fail.
			g.record(o, Shape::Records.list_key().unwrap(), &name, &f);
		}
		Shape::Config => {
			let (k, n) = model::config_unit(i);
			g.entry(o, &k, &n);
		}
		Shape::Ddl => {
			let (name, f) = model::ddl_unit(i);
			// Same as Records: list_key is Some for exactly these two shapes.
			g.record(o, Shape::Ddl.list_key().unwrap(), &name, &f);
		}
	}
}

/// Renders `units` units, or as many as it takes to reach `target` bytes.
fn render(shape: Shape, fmt: Fmt, units: usize, target: Option<usize>) -> (String, usize) {
	let mut g = Gen::new(fmt, shape);
	let mut out = String::with_capacity(target.unwrap_or(1 << 20) + (1 << 16));
	g.doc_open(&mut out);
	let mut n = 0;
	loop {
		match target {
			Some(t) => {
				if out.len() >= t {
					break;
				}
			}
			None => {
				if n >= units {
					break;
				}
			}
		}
		emit_unit(&mut g, &mut out, shape, n);
		n += 1;
	}
	g.doc_close(&mut out);
	(out, n)
}

/// Best-of-N says nothing when N is 3 and the parse takes microseconds, so a
/// small document gets proportionally more runs. The clamp keeps a 64 MiB shape
/// at the count the run asked for.
fn scale_iters(iters: usize, bytes: usize) -> usize {
	iters * ((1 << 20) / bytes.max(1)).clamp(1, 200)
}

// Libraries under test

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Tier {
	Rust,
	Python,
}

impl Tier {
	fn name(self) -> &'static str {
		match self {
			Tier::Rust => "rust",
			Tier::Python => "python",
		}
	}
	fn from_name(s: &str) -> Option<Tier> {
		match s {
			"rust" => Some(Tier::Rust),
			"python" => Some(Tier::Python),
			_ => None,
		}
	}
}

/// One measurable library. The Rust ones come from a static table compiled in;
/// the Python ones are whatever `pyworker.py` reports it can import, so a box
/// without tomlkit measures what it has and the run says what it skipped rather
/// than failing over a library that was never required.
struct Lib {
	tier: Tier,
	key: String,
	format: String,
	library: String,
	version: String,
	retains: String,
	note: String,
}

fn pyworker() -> String {
	format!("{}/pyworker.py", env!("CARGO_MANIFEST_DIR"))
}

fn discover_libs(o: &Opts) -> (Vec<Lib>, Vec<String>) {
	let vers = lock_versions();
	let mut libs = Vec::new();
	let mut skipped = Vec::new();

	if o.tiers.contains(&Tier::Rust) {
		for e in bench::ENTRIES {
			libs.push(Lib {
				tier: Tier::Rust,
				key: e.key.to_string(),
				format: e.format.to_string(),
				library: e.library.to_string(),
				version: vers.get(e.library).cloned().unwrap_or_else(|| "?".into()),
				retains: e.retains.to_string(),
				note: e.note.to_string(),
			});
		}
	}

	if o.tiers.contains(&Tier::Python) {
		match Command::new("python3")
			.args([&pyworker(), "--list"])
			.output()
		{
			Err(e) => skipped.push(format!("the whole python tier: cannot run python3 ({e})")),
			Ok(out) => {
				for line in String::from_utf8_lossy(&out.stdout).lines() {
					let f: Vec<&str> = line.split('|').collect();
					match f.as_slice() {
						["available", key, fmt, lib, retains, version, note] => libs.push(Lib {
							tier: Tier::Python,
							key: (*key).to_string(),
							format: (*fmt).to_string(),
							library: (*lib).to_string(),
							// The python binding ships no version of its own, so
							// the repo's is the honest answer for it.
							version: if *version == "working tree" {
								vers.get("shcl")
									.cloned()
									.unwrap_or_else(|| "working tree".into())
							} else {
								(*version).to_string()
							},
							retains: (*retains).to_string(),
							note: (*note).to_string(),
						}),
						["unavailable", key, why] => skipped.push(format!("python/{key}: {why}")),
						_ => {}
					}
				}
			}
		}
	}

	if !o.entries.is_empty() {
		libs.retain(|l| o.entries.contains(&l.key));
	}
	(libs, skipped)
}

// Orchestration

struct Row {
	shape: Shape,
	tier: Tier,
	key: String,
	bytes: usize,
	gzip_bytes: usize,
	m: bench::Measured,
}

fn orchestrate(o: &Opts) -> i32 {
	let mut rc = 0;

	if o.verify && !verify(o) {
		return 1;
	}

	let work = match &o.work {
		Some(d) => {
			let _ = std::fs::create_dir_all(d);
			d.clone()
		}
		None => match mktemp() {
			Ok(d) => d,
			Err(e) => {
				eprintln!("shcl-comparison: {e}");
				return 1;
			}
		},
	};
	let exe = std::env::current_exe().unwrap_or_else(|_| "shcl-comparison".into());

	let (libs, skipped) = discover_libs(o);
	if libs.is_empty() {
		eprintln!("shcl-comparison: no libraries to measure");
		return 1;
	}
	for s in &skipped {
		println!("skipping {s}");
	}

	let mut rows: Vec<Row> = Vec::new();
	let mut units_by_shape: HashMap<&'static str, usize> = HashMap::new();
	let mut iters_by_shape: HashMap<&'static str, usize> = HashMap::new();

	for &shape in &o.shapes {
		// SHCL sets the unit count by hitting the size target; every other
		// format then encodes exactly that data, so size is a result rather
		// than an input. The shapes that carry their own size skip the target
		// and render a fixed number of units instead.
		let (shcl_text, units) = match shape.plan(o.mib) {
			model::Plan::Units(n) => render(shape, Fmt::Shcl, n, None),
			model::Plan::Target(t) => render(shape, Fmt::Shcl, 0, Some(t)),
		};
		let iters = scale_iters(o.iters, shcl_text.len());
		units_by_shape.insert(shape.name(), units);
		iters_by_shape.insert(shape.name(), iters);
		println!(
			"generating {} ({units} units, best of {iters})",
			shape.name()
		);

		let mut path_of: HashMap<&str, String> = HashMap::new();
		let mut bytes_of: HashMap<&str, usize> = HashMap::new();
		let mut gzip_of: HashMap<&str, usize> = HashMap::new();
		for fmt in Fmt::all() {
			let text = if fmt == Fmt::Shcl {
				shcl_text.clone()
			} else {
				render(shape, fmt, units, None).0
			};
			let path = format!("{work}/{}.{}", shape.name(), fmt.ext());
			if let Err(e) = std::fs::write(&path, &text) {
				eprintln!("shcl-comparison: cannot write {path}: {e}");
				return 1;
			}
			bytes_of.insert(fmt.name(), text.len());
			gzip_of.insert(fmt.name(), gzip_size(&path));
			path_of.insert(fmt.name(), path);
		}
		drop(shcl_text);

		for lib in &libs {
			let fmt = Fmt::from_name(&lib.format).expect("a library names a known format");
			let path = &path_of[fmt.name()];
			let m = spawn_worker(&exe, lib, path, iters);
			match &m.failed {
				Some(e) => {
					eprintln!("  {:<6} {:<10} FAILED: {e}", lib.tier.name(), lib.key);
					rc = 1;
				}
				// A progress line per measurement rather than a table per shape:
				// the tables cannot be printed until every shape is in, because
				// the row order comes from an average over all of them.
				None => println!(
					"  {:<6} {:<10} {:>8.3} s  {:>7.0} MiB",
					lib.tier.name(),
					lib.key,
					m.parse_secs,
					mib(m.rss_bytes)
				),
			}
			rows.push(Row {
				shape,
				tier: lib.tier,
				key: lib.key.clone(),
				bytes: bytes_of[fmt.name()],
				gzip_bytes: gzip_of[fmt.name()],
				m,
			});
		}
	}

	if !o.keep && o.work.is_none() {
		let _ = std::fs::remove_dir_all(&work);
	} else {
		println!("\nkept generated documents in {work}");
	}

	// One order everywhere - printed tables and the results file both - so a
	// row keeps its place from shape to shape and the file reads the same way
	// the table does.
	let order = rank(&rows);
	rows.sort_by(|a, b| {
		(a.shape.name(), a.tier.name(), speed(&order, a))
			.partial_cmp(&(b.shape.name(), b.tier.name(), speed(&order, b)))
			.unwrap_or(std::cmp::Ordering::Equal)
	});
	print_tables(&rows, &libs);

	if o.record {
		match record(o, &rows, &libs, &units_by_shape, &iters_by_shape) {
			Ok(id) => println!("\nrecorded run {id} in {}", o.out),
			Err(e) => {
				eprintln!("shcl-comparison: cannot record results: {e}");
				rc = 1;
			}
		}
	}
	rc
}

/// The python libraries this box can import, as (key, format). The same
/// `--list` call `discover_libs` makes, needed here because the pre-flight runs
/// before the work directory exists.
fn py_entries() -> Vec<(String, Fmt)> {
	let mut out = Vec::new();
	if let Ok(o) = Command::new("python3")
		.args([&pyworker(), "--list"])
		.output()
	{
		for line in String::from_utf8_lossy(&o.stdout).lines() {
			let f: Vec<&str> = line.split('|').collect();
			if let ["available", key, fmt, ..] = f.as_slice() {
				if let Some(fmt) = Fmt::from_name(fmt) {
					out.push(((*key).to_string(), fmt));
				}
			}
		}
	}
	out
}

/// One python library's scalar count for a rendered document. `Ok(None)` is a
/// library the worker could not import after all, which is a skip and not a
/// disagreement.
fn py_count(key: &str, path: &str) -> Result<Option<u64>, String> {
	let out = Command::new("python3")
		.args([pyworker().as_str(), "--count", key, path])
		.output()
		.map_err(|e| format!("cannot run worker: {e}"))?;
	for line in String::from_utf8_lossy(&out.stdout).lines() {
		match line.split_once('=') {
			Some(("scalars", v)) => {
				return v.parse().map(Some).map_err(|_| format!("bad count {v:?}"));
			}
			Some(("skipped", _)) => return Ok(None),
			Some(("failed", v)) => return Err(v.to_string()),
			_ => {}
		}
	}
	Err(format!(
		"worker said nothing (exit {:?})",
		out.status.code()
	))
}

/// Pre-flight: at a small scale, every library has to parse its own file and
/// find the same number of scalar values in it. Five encoders written from one
/// model can still disagree through an escaping mistake, and a size or speed
/// number taken from documents that are not the same data is worthless.
///
/// The python tier is asked the same question through its worker, which counts
/// on request and not while measuring. Without that the check said nothing
/// about seven libraries.
fn verify(o: &Opts) -> bool {
	let mut ok = true;
	let py = if o.tiers.contains(&Tier::Python) {
		py_entries()
	} else {
		Vec::new()
	};
	// The python worker reads a file, so the pre-flight documents get written
	// out. Nothing here is timed, so a temp directory costs the check nothing.
	let work = if py.is_empty() { None } else { mktemp().ok() };
	// A check that cannot run is not a check that passed.
	if work.is_none() && !py.is_empty() {
		eprintln!("verify: no temp directory, so the python tier cannot be checked");
		return false;
	}
	for &shape in &o.shapes {
		let units = shape.verify_units(o.verify_units);
		let mut counts: Vec<(&str, String, u64)> = Vec::new();
		for fmt in Fmt::all() {
			let (text, _) = render(shape, fmt, units, None);
			for e in bench::ENTRIES {
				if bench::source_fmt(e.key) != fmt {
					continue;
				}
				let m = bench::run(e.key, &text, 1, true, 0);
				match m.failed {
					Some(err) => {
						eprintln!("verify: {}/rust/{}: {err}", shape.name(), e.key);
						ok = false;
					}
					None => counts.push(("rust", e.key.to_string(), m.scalars)),
				}
			}
			let Some(work) = work.as_deref() else {
				continue;
			};
			if !py.iter().any(|(_, f)| *f == fmt) {
				continue;
			}
			let path = format!("{work}/verify-{}.{}", shape.name(), fmt.ext());
			if let Err(e) = std::fs::write(&path, &text) {
				eprintln!("verify: cannot write {path}: {e}");
				ok = false;
				continue;
			}
			for (key, _) in py.iter().filter(|(_, f)| *f == fmt) {
				match py_count(key, &path) {
					Ok(Some(n)) => counts.push(("python", key.clone(), n)),
					Ok(None) => {}
					Err(err) => {
						eprintln!("verify: {}/python/{key}: {err}", shape.name());
						ok = false;
					}
				}
			}
		}
		// The four non-SHCL encodings carry the instance label as an ordinary
		// `name` field, which SHCL writes as the binding's own value. Same data,
		// one fewer scalar binding.
		let offset = if shape.list_key().is_some() {
			units as u64
		} else {
			0
		};
		let want = counts
			.iter()
			.find(|(_, k, _)| k == "shcl")
			.map(|(_, _, n)| *n + offset);
		if let Some(want) = want {
			for (tier, k, n) in &counts {
				let got = if k == "shcl" { *n + offset } else { *n };
				if got != want {
					eprintln!(
						"verify: {}/{tier}/{k}: {got} scalars, shcl says {want} - the documents are not the same data",
						shape.name()
					);
					ok = false;
				}
			}
		}
		if ok {
			println!(
				"verify: {} agrees across {} libraries ({units} units, {} scalars)",
				shape.name(),
				counts.len(),
				want.unwrap_or(0)
			);
		}
	}
	if let Some(work) = work {
		let _ = std::fs::remove_dir_all(work);
	}
	ok
}

fn spawn_worker(exe: &std::path::Path, lib: &Lib, path: &str, iters: usize) -> bench::Measured {
	let iters_s = iters.to_string();
	let py = pyworker();
	let out = match lib.tier {
		Tier::Rust => Command::new(exe)
			.args(["--worker", lib.key.as_str(), path, iters_s.as_str()])
			.output(),
		Tier::Python => Command::new("python3")
			.args([py.as_str(), lib.key.as_str(), path, iters_s.as_str()])
			.output(),
	};
	let out = match out {
		Ok(o) => o,
		Err(e) => {
			return bench::Measured {
				parse_secs: 0.0,
				emit_secs: None,
				emit_bytes: 0,
				roundtrip: false,
				scalars: 0,
				rss_bytes: 0,
				base_rss_bytes: 0,
				failed: Some(format!("cannot run worker: {e}")),
			};
		}
	};
	let text = String::from_utf8_lossy(&out.stdout);
	let mut kv: HashMap<&str, &str> = HashMap::new();
	for line in text.lines() {
		if let Some((k, v)) = line.split_once('=') {
			kv.insert(k, v);
		}
	}
	let num = |k: &str| -> f64 { kv.get(k).and_then(|v| v.parse().ok()).unwrap_or(0.0) };
	let int = |k: &str| -> u64 { kv.get(k).and_then(|v| v.parse().ok()).unwrap_or(0) };
	let failed = kv
		.get("failed")
		.or_else(|| kv.get("skipped"))
		.map(|s| (*s).to_string())
		.or_else(|| {
			if out.status.success() {
				None
			} else {
				Some(format!(
					"worker exit {:?}: {}",
					out.status.code(),
					String::from_utf8_lossy(&out.stderr)
						.lines()
						.next()
						.unwrap_or("")
				))
			}
		});
	bench::Measured {
		parse_secs: num("parse-secs"),
		emit_secs: kv.get("emit-secs").and_then(|v| v.parse().ok()),
		emit_bytes: int("emit-bytes") as usize,
		roundtrip: kv.get("roundtrip") == Some(&"true"),
		scalars: int("scalars"),
		rss_bytes: int("rss-bytes"),
		base_rss_bytes: int("base-rss-bytes"),
		failed,
	}
}

fn worker(key: &str, path: &str, iters: usize) {
	let src = match std::fs::read_to_string(path) {
		Ok(s) => s,
		Err(e) => {
			println!("failed=cannot read {path}: {e}");
			return;
		}
	};
	let base = bench::vmhwm(); // source text resident, nothing parsed yet
	let m = bench::run(key, &src, iters, false, base);
	if let Some(e) = m.failed {
		println!("failed={}", e.replace('\n', " "));
		return;
	}
	println!("parse-secs={:.6}", m.parse_secs);
	if let Some(s) = m.emit_secs {
		println!("emit-secs={s:.6}");
	}
	println!("emit-bytes={}", m.emit_bytes);
	println!("roundtrip={}", m.roundtrip);
	println!("scalars={}", m.scalars);
	println!("rss-bytes={}", m.rss_bytes);
	println!("base-rss-bytes={}", m.base_rss_bytes);
}

// Reporting

fn mib(bytes: u64) -> f64 {
	bytes as f64 / (1024.0 * 1024.0)
}

/// Geometric mean of a library's parse time across the shapes it ran. The
/// geometric one rather than the arithmetic, so one large shape cannot decide
/// the whole order on its own.
fn rank(rows: &[Row]) -> HashMap<(Tier, String), f64> {
	let mut acc: HashMap<(Tier, String), (f64, usize)> = HashMap::new();
	for r in rows {
		if r.m.failed.is_some() || r.m.parse_secs <= 0.0 {
			continue;
		}
		let e = acc.entry((r.tier, r.key.clone())).or_insert((0.0, 0));
		e.0 += r.m.parse_secs.ln();
		e.1 += 1;
	}
	acc.into_iter()
		.map(|(k, (sum, n))| (k, (sum / n as f64).exp()))
		.collect()
}

/// A row that never produced a time sorts last rather than first.
fn speed(order: &HashMap<(Tier, String), f64>, r: &Row) -> f64 {
	*order.get(&(r.tier, r.key.clone())).unwrap_or(&f64::MAX)
}

fn retains_of<'a>(libs: &'a [Lib], r: &Row) -> &'a str {
	libs.iter()
		.find(|l| l.tier == r.tier && l.key == r.key)
		.map_or("?", |l| l.retains.as_str())
}

fn print_tables(rows: &[Row], libs: &[Lib]) {
	println!(
		"\nRows are ordered by the geometric mean of each library's parse time over\nevery shape measured, fastest first. Tiers are listed apart and never ranked\nagainst each other - they are different languages, not different formats."
	);
	let mut cur = ("", "");
	for r in rows {
		let group = (r.shape.name(), r.tier.name());
		if group != cur {
			cur = group;
			println!("\n{} / {}", r.shape.name(), r.tier.name());
			println!(
				"  {:<10} {:>9} {:>9} {:>9} {:>8} {:>9} {:>9} {:>7}  {:<16} round-trip",
				"library",
				"MiB",
				"gzip MiB",
				"parse s",
				"MiB/s",
				"emit s",
				"peak MiB",
				"x input",
				"retains"
			);
		}
		if let Some(e) = &r.m.failed {
			println!("  {:<10} {:>9}  FAILED: {e}", r.key, "-");
			continue;
		}
		println!(
			"  {:<10} {:>9.2} {:>9.2} {:>9.3} {:>8.1} {:>9} {:>9.0} {:>7.1}  {:<16} {}",
			r.key,
			mib(r.bytes as u64),
			mib(r.gzip_bytes as u64),
			r.m.parse_secs,
			mib(r.bytes as u64) / r.m.parse_secs,
			r.m.emit_secs.map_or("-".to_string(), |s| format!("{s:.3}")),
			mib(r.m.rss_bytes),
			r.m.rss_bytes as f64 / r.bytes as f64,
			retains_of(libs, r),
			if r.m.emit_secs.is_none() {
				"-"
			} else if r.m.roundtrip {
				"byte-identical"
			} else {
				"reformatted"
			},
		);
	}
}

// Recording, through this repo's own library

fn record(
	o: &Opts,
	rows: &[Row],
	libs: &[Lib],
	units: &HashMap<&'static str, usize>,
	iters: &HashMap<&'static str, usize>,
) -> Result<String, String> {
	let (mut doc, status) = shcl::Document::load_file(&o.out);
	match status {
		shcl::FileStatus::Clean | shcl::FileStatus::NotFound => {}
		other => return Err(format!("{} is unusable ({other:?})", o.out)),
	}

	let id = run_id();
	let vers = lock_versions();
	let run = format!("run[{id}]");
	macro_rules! set {
		($path:expr, $v:expr) => {
			let _ = doc.set_string(&$path, $v);
		};
	}

	set!(
		format!("{run}.tool"),
		&format!("shcl-comparison {}", env!("CARGO_PKG_VERSION"))
	);
	set!(
		format!("{run}.shcl-version"),
		vers.get("shcl").map_or("?", String::as_str)
	);
	set!(format!("{run}.host-cpu"), &cpu_model());
	set!(format!("{run}.os"), &uname());
	set!(
		format!("{run}.notes"),
		"same data in every format; one process per measurement; best of N runs; \
libraries ordered by geometric-mean parse time, fastest first; tiers are separate languages and are not ranked against each other"
	);
	let _ = doc.set_int(
		&format!("{run}.host-cores"),
		std::thread::available_parallelism().map_or(0, |n| n.get() as i64),
	);
	let _ = doc.set_int(&format!("{run}.target-mib"), o.mib as i64);
	let _ = doc.set_int(&format!("{run}.iterations"), o.iters as i64);

	// What each library IS goes under the run once; what it DID goes under the
	// shape. Repeating five facts under every shape made the file four times
	// longer and no more informative.
	let order = rank(rows);
	for l in libs {
		let about = format!("{run}.tier[{}].library[{}]", l.tier.name(), l.key);
		set!(format!("{about}.format"), &l.format);
		set!(format!("{about}.library"), &l.library);
		set!(format!("{about}.version"), &l.version);
		set!(format!("{about}.retains"), &l.retains);
		set!(format!("{about}.note"), &l.note);
		if let Some(g) = order.get(&(l.tier, l.key.clone())) {
			// The number the row order is derived from, so the ordering in this
			// file can be re-derived rather than trusted.
			let _ = doc.set_float(&format!("{about}.rank-parse-secs"), round6(*g));
		}
	}

	for r in rows {
		let sh = format!("{run}.tier[{}].shape[{}]", r.tier.name(), r.shape.name());
		let _ = doc.set_int(
			&format!("{sh}.units"),
			*units.get(r.shape.name()).unwrap_or(&0) as i64,
		);
		let _ = doc.set_int(
			&format!("{sh}.iterations"),
			*iters.get(r.shape.name()).unwrap_or(&0) as i64,
		);
		let lib = format!("{sh}.library[{}]", r.key);
		if let Some(f) = &r.m.failed {
			set!(format!("{lib}.failed"), f);
			continue;
		}
		let _ = doc.set_int(&format!("{lib}.bytes"), r.bytes as i64);
		let _ = doc.set_int(&format!("{lib}.gzip-bytes"), r.gzip_bytes as i64);
		let _ = doc.set_float(&format!("{lib}.parse-secs"), round6(r.m.parse_secs));
		let _ = doc.set_float(
			&format!("{lib}.parse-mib-per-sec"),
			round2(mib(r.bytes as u64) / r.m.parse_secs),
		);
		match r.m.emit_secs {
			Some(s) => {
				let _ = doc.set_float(&format!("{lib}.emit-secs"), round6(s));
				let _ = doc.set_int(&format!("{lib}.emit-bytes"), r.m.emit_bytes as i64);
				let _ = doc.set_bool(&format!("{lib}.roundtrip-identical"), r.m.roundtrip);
			}
			None => {
				set!(
					format!("{lib}.emit-secs"),
					"n/a - the library has no writer"
				);
			}
		}
		let _ = doc.set_float(&format!("{lib}.peak-rss-mib"), round2(mib(r.m.rss_bytes)));
		let _ = doc.set_float(
			&format!("{lib}.model-rss-mib"),
			round2(mib(r.m.rss_bytes.saturating_sub(r.m.base_rss_bytes))),
		);
		let _ = doc.set_float(
			&format!("{lib}.rss-per-input-byte"),
			round2(r.m.rss_bytes as f64 / r.bytes as f64),
		);
	}

	prune(&mut doc, o.keep_runs);
	doc.save_file(&o.out).map_err(|e| e.to_string())?;
	Ok(id)
}

/// Run ids sort chronologically, so keeping the newest is a tail of the sorted
/// instance list.
fn prune(doc: &mut shcl::Document, keep: usize) {
	if keep == 0 {
		return;
	}
	let mut ids = doc.instances("run");
	if ids.len() <= keep {
		return;
	}
	ids.sort();
	for id in &ids[..ids.len() - keep] {
		doc.remove(&format!("run[{id}]"));
	}
}

fn round2(v: f64) -> f64 {
	(v * 100.0).round() / 100.0
}
fn round6(v: f64) -> f64 {
	(v * 1_000_000.0).round() / 1_000_000.0
}

// Environment odds and ends

fn shell(cmd: &str, args: &[&str]) -> String {
	Command::new(cmd)
		.args(args)
		.output()
		.ok()
		.filter(|o| o.status.success())
		.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
		.unwrap_or_default()
}

fn run_id() -> String {
	let s = shell("date", &["+%Y%m%d-%H%M%S"]);
	if !s.is_empty() {
		return s;
	}
	let secs = std::time::SystemTime::now()
		.duration_since(std::time::UNIX_EPOCH)
		.map_or(0, |d| d.as_secs());
	format!("epoch-{secs}")
}

fn uname() -> String {
	let s = shell("uname", &["-srm"]);
	if s.is_empty() {
		std::env::consts::OS.to_string()
	} else {
		s
	}
}

fn cpu_model() -> String {
	let s = std::fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
	for line in s.lines() {
		if let Some(rest) = line.split_once(':')
			&& line.starts_with("model name")
		{
			return rest.1.trim().to_string();
		}
	}
	"unknown".to_string()
}

fn mktemp() -> Result<String, String> {
	let d = shell("mktemp", &["-d", "/tmp/shcl-comparison.XXXXXX"]);
	if d.is_empty() {
		Err("mktemp failed".into())
	} else {
		Ok(d)
	}
}

/// gzip at its default level, which is what anyone shipping a compressed config
/// actually gets. Shelled out rather than pulling a compression crate in for one
/// number.
fn gzip_size(path: &str) -> usize {
	let f = match std::fs::File::open(path) {
		Ok(f) => f,
		Err(_) => return 0,
	};
	let child = Command::new("gzip")
		.arg("-c")
		.stdin(Stdio::from(f))
		.stdout(Stdio::piped())
		.spawn();
	let mut child = match child {
		Ok(c) => c,
		Err(_) => return 0,
	};
	let mut n = 0usize;
	if let Some(mut out) = child.stdout.take() {
		let mut buf = [0u8; 1 << 16];
		while let Ok(got) = out.read(&mut buf) {
			if got == 0 {
				break;
			}
			n += got;
		}
	}
	let _ = child.wait();
	n
}

/// Versions come from this tool's own committed lockfile, so a recorded run
/// always names the libraries it actually measured.
fn lock_versions() -> HashMap<String, String> {
	let mut out = HashMap::new();
	let text = std::fs::read_to_string(format!("{}/Cargo.lock", env!("CARGO_MANIFEST_DIR")))
		.unwrap_or_default();
	if let Ok(t) = text.parse::<toml::Table>()
		&& let Some(toml::Value::Array(pkgs)) = t.get("package")
	{
		for p in pkgs {
			if let (Some(toml::Value::String(n)), Some(toml::Value::String(v))) =
				(p.get("name"), p.get("version"))
			{
				out.insert(n.clone(), v.clone());
			}
		}
	}
	out
}
