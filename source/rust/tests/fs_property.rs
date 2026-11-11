// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! The save's changed, create-only and not-regular checks against a real
//! folder, over cases drawn from `project/fs-rules.tsv`: a load spelling, a
//! save spelling, and what another program did between them. The expected
//! answer comes from reading the folder, never from the library. Its own test
//! binary, since it changes the working folder (2026110616475901).
//!
//! The folder is `SHCL_FS_DIR`, which the pipeline points at a tmpfs made for
//! the run. The budget is `SHCL_FS_SECS` of wall clock, and `SHCL_FUZZ_DUMP`
//! gets every case run, with its answer, in `fs/rust-rows.tsv` and
//! `fs/rust-drawn.tsv`. `SHCL_FS_SEED` runs only that seed, to replay a
//! failure.

mod common;

use common::test_id;
use shcl::{Document, FileStatus, SaveError, SaveOptions, WriteStatus};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Held by each test for its whole run, since both change the working folder.
static CWD: Mutex<()> = Mutex::new(());

const RULES: &str = include_str!("../../../project/fs-rules.tsv");

/// The fewest generated cases a run makes, whatever the budget, so the draw
/// guard has enough to judge.
const MIN_CASES: u64 = 400;

const LOADED: &str = "a: 1\n";
const OTHER: &str = "b: 2\n";
const MARKER: &str = "marker: 1\n";

struct Rule {
	name: String,
	path: String,
	cwd: String,
	os: String,
}

struct Rules {
	spells: Vec<Rule>,
	events: Vec<Rule>,
}

fn rules() -> Rules {
	let mut r = Rules {
		spells: Vec::new(),
		events: Vec::new(),
	};
	for line in RULES.lines() {
		if line.is_empty() || line.starts_with('#') {
			continue;
		}
		let f: Vec<&str> = line.split('\t').collect();
		assert_eq!(f.len(), 5, "fs-rules.tsv: not 5 fields: {line:?}");
		let rule = Rule {
			name: f[1].to_string(),
			path: f[2].to_string(),
			cwd: f[3].to_string(),
			os: f[4].to_string(),
		};
		on_this_os(&rule.os);
		match f[0] {
			"spell" => r.spells.push(rule),
			"event" => r.events.push(rule),
			k => panic!("fs-rules.tsv: no such kind {k:?}"),
		}
	}
	r
}

/// The Windows rows wait for b29w (2026111019505861), so they skip
/// everywhere for now, rather than run untried.
fn on_this_os(os: &str) -> bool {
	match os {
		"any" => true,
		"posix" => cfg!(unix),
		"macos" => cfg!(target_os = "macos"),
		"windows" => false,
		_ => panic!("fs-rules.tsv: no such os {os:?}"),
	}
}

/// splitmix64, since it's a few lines in every binding.
struct SplitMix(u64);

impl SplitMix {
	fn next(&mut self) -> u64 {
		self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
		let mut z = self.0;
		z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
		z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
		z ^ (z >> 31)
	}
	fn below(&mut self, n: usize) -> usize {
		(self.next() % n as u64) as usize
	}
}

#[derive(Clone, Debug)]
struct Case {
	t_there: bool,
	o_there: bool,
	load: usize,
	save: usize,
	events: Vec<usize>,
	create: bool,
	force: bool,
}

fn draw(r: &Rules, seed: u64) -> Case {
	let mut g = SplitMix(seed);
	let t_there = g.below(2) == 1;
	let o_there = g.below(2) == 1;
	let load = g.below(r.spells.len());
	let save = g.below(r.spells.len());
	let n = 1 + g.below(2);
	let events = (0..n).map(|_| g.below(r.events.len())).collect();
	let create = g.below(4) == 0;
	let force = g.below(4) == 0;
	Case {
		t_there,
		o_there,
		load,
		save,
		events,
		create,
		force,
	}
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Outcome {
	Ok,
	Changed,
	Exists,
	IsDirectory,
	NotRegular,
	Io,
}

const OUTCOMES: [Outcome; 6] = [
	Outcome::Ok,
	Outcome::Changed,
	Outcome::Exists,
	Outcome::IsDirectory,
	Outcome::NotRegular,
	Outcome::Io,
];

fn classify(r: &Result<bool, SaveError>) -> Outcome {
	match r {
		Ok(_) => Outcome::Ok,
		Err(SaveError::Changed { .. }) => Outcome::Changed,
		Err(SaveError::Exists { .. }) => Outcome::Exists,
		Err(SaveError::Io(e)) => match e.status {
			WriteStatus::IsDirectory => Outcome::IsDirectory,
			WriteStatus::NotRegular => Outcome::NotRegular,
			_ => Outcome::Io,
		},
		Err(e) => panic!("a save this test never asks for: {e:?}"),
	}
}

/// What sits at a path, followed through links, read without the library.
#[derive(Debug, PartialEq)]
enum At {
	Nothing,
	File(Vec<u8>),
	Unreadable,
	Dir,
	Special,
}

fn at(p: &Path) -> At {
	match std::fs::metadata(p) {
		Ok(m) if m.is_file() => match std::fs::read(p) {
			Ok(b) => At::File(b),
			Err(_) => At::Unreadable,
		},
		Ok(m) if m.is_dir() => At::Dir,
		Ok(_) => At::Special,
		Err(_) => At::Nothing,
	}
}

/// The spelling's path, as the library gets it from its working folder.
fn spelled(rule: &Rule, w: &Path) -> String {
	rule.path.replace("{W}", w.to_str().unwrap())
}

/// The same path from the case's root, for reading and events. A join keeps
/// the text as written, so `nodir/..` still meets the kernel.
fn from_root(root: &Path, cwd: &str, path: &str) -> PathBuf {
	let mut p = root.join(cwd).into_os_string();
	if Path::new(path).is_absolute() {
		return PathBuf::from(path);
	}
	p.push("/");
	p.push(path);
	PathBuf::from(p)
}

fn build(root: &Path, c: &Case) {
	let w = root.join("w");
	std::fs::create_dir_all(w.join("sub")).unwrap();
	std::fs::create_dir(root.join("o")).unwrap();
	std::fs::write(w.join("sub/t.shcl"), "s: 1\n").unwrap();
	if c.t_there {
		std::fs::write(w.join("t.shcl"), LOADED).unwrap();
	}
	if c.o_there {
		std::fs::write(root.join("o/t.shcl"), "o: 1\n").unwrap();
	}
	#[cfg(unix)]
	{
		use std::os::unix::fs::symlink;
		symlink(".", w.join("lw")).unwrap();
		symlink("t.shcl", w.join("lt.shcl")).unwrap();
		symlink("gone.shcl", w.join("dl.shcl")).unwrap();
		symlink("cy2.shcl", w.join("cy.shcl")).unwrap();
		symlink("cy.shcl", w.join("cy2.shcl")).unwrap();
	}
}

fn is_fifo(p: &Path) -> bool {
	#[cfg(unix)]
	{
		use std::os::unix::fs::FileTypeExt;
		std::fs::metadata(p).is_ok_and(|m| m.file_type().is_fifo())
	}
	#[cfg(not(unix))]
	{
		let _ = p;
		false
	}
}

/// Another program's act between the load and the save. Each one that the
/// tree makes impossible, such as a write through a link cycle, does nothing,
/// the same in both trees.
fn apply(event: &str, root: &Path, load: &Path, save: &Path) {
	let w = root.join("w");
	let write = |p: &Path| {
		if !is_fifo(p) {
			let _ = std::fs::write(p, OTHER);
		}
	};
	match event {
		"none" | "chdir" => {}
		"write-load" => write(load),
		"write-save" => write(save),
		"remove-load" => {
			let _ = std::fs::remove_file(load);
		}
		"fifo-load" => {
			let _ = std::fs::remove_file(load);
			let _ = std::process::Command::new("mkfifo")
				.arg(load)
				.stderr(std::process::Stdio::null())
				.status();
		}
		"dir-load" => {
			let _ = std::fs::remove_file(load);
			let _ = std::fs::create_dir(load);
		}
		"mkdir" => {
			let _ = std::fs::create_dir(w.join("nodir"));
			let _ = std::fs::create_dir(w.join("nd"));
		}
		#[cfg(unix)]
		"link-made" => {
			let _ = std::os::unix::fs::symlink("sub", w.join("nd"));
		}
		#[cfg(unix)]
		"relink" => {
			use std::os::unix::fs::symlink;
			let _ = std::fs::remove_file(w.join("lw"));
			let _ = symlink("sub", w.join("lw"));
			let _ = std::fs::remove_file(w.join("lt.shcl"));
			let _ = symlink("sub/t.shcl", w.join("lt.shcl"));
		}
		#[cfg(unix)]
		"unread" => {
			use std::os::unix::fs::PermissionsExt;
			// A file only, since a folder without its bits stops the case.
			if std::fs::metadata(load).is_ok_and(|m| m.is_file()) {
				let _ = std::fs::set_permissions(load, std::fs::Permissions::from_mode(0o200));
			}
		}
		e => panic!("no such event {e:?}"),
	}
}

/// Every name under the root, with what it is and holds, links not followed,
/// so a refused save can be shown to have written nothing anywhere.
fn snapshot(root: &Path) -> BTreeMap<String, String> {
	fn walk(dir: &Path, root: &Path, out: &mut BTreeMap<String, String>) {
		let Ok(entries) = std::fs::read_dir(dir) else {
			out.insert(rel(dir, root), "unlistable".to_string());
			return;
		};
		for e in entries {
			let p = e.unwrap().path();
			let m = std::fs::symlink_metadata(&p).unwrap();
			let ft = m.file_type();
			let what = if ft.is_symlink() {
				format!("link {}", std::fs::read_link(&p).unwrap().display())
			} else if ft.is_dir() {
				walk(&p, root, out);
				"dir".to_string()
			} else if ft.is_file() {
				match std::fs::read(&p) {
					Ok(b) => format!("file {:?}", String::from_utf8_lossy(&b)),
					Err(_) => format!("file of {} bytes, unreadable", m.len()),
				}
			} else {
				"special".to_string()
			};
			out.insert(rel(&p, root), what);
		}
	}
	fn rel(p: &Path, root: &Path) -> String {
		p.strip_prefix(root).unwrap().display().to_string()
	}
	let mut out = BTreeMap::new();
	walk(root, root, &mut out);
	out
}

/// Gives back the bits an event took, so the tree can go.
fn remove_tree(root: &Path) {
	#[cfg(unix)]
	fn unlock(p: &Path) {
		use std::os::unix::fs::PermissionsExt;
		let Ok(m) = std::fs::symlink_metadata(p) else {
			return;
		};
		if m.is_dir() {
			let _ = std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o700));
			if let Ok(entries) = std::fs::read_dir(p) {
				for e in entries.flatten() {
					unlock(&e.path());
				}
			}
		}
	}
	#[cfg(unix)]
	unlock(root);
	let _ = std::fs::remove_dir_all(root);
}

/// One case's run and its answers.
struct Ran {
	skipped: bool,
	same: bool,
	expected: Outcome,
	got: Outcome,
	line: String,
}

fn describe(r: &Rules, c: &Case) -> String {
	let events: Vec<&str> = c
		.events
		.iter()
		.map(|&e| r.events[e].name.as_str())
		.collect();
	format!(
		"t={} o={} load={} save={} events={} create={} force={}",
		c.t_there as u8,
		c.o_there as u8,
		r.spells[c.load].name,
		r.spells[c.save].name,
		events.join(","),
		c.create as u8,
		c.force as u8,
	)
}

/// The answer the save has to give, from the case's tree, and whether the 2
/// spellings name one file, from the replica: a marker written through the
/// save spelling and read back through the load spelling.
fn oracle(
	save_at: &Path,
	r_save_at: &Path,
	r_load_at: &Path,
	save_path: &str,
	loaded: Option<&[u8]>,
	c: &Case,
) -> (Outcome, bool) {
	let write_verdict = || -> Outcome {
		match std::fs::metadata(r_save_at) {
			Ok(m) if m.is_dir() => Outcome::IsDirectory,
			Ok(m) if !m.is_file() => Outcome::NotRegular,
			_ => match std::fs::OpenOptions::new()
				.write(true)
				.create(true)
				.truncate(true)
				.open(r_save_at)
			{
				Ok(mut f) => {
					f.write_all(MARKER.as_bytes()).unwrap();
					Outcome::Ok
				}
				Err(_) => Outcome::Io,
			},
		}
	};
	let verdict = write_verdict();
	let same = verdict == Outcome::Ok && at(r_load_at) == At::File(MARKER.as_bytes().to_vec());
	if save_path.ends_with('/') || save_path.ends_with("/.") || save_path.ends_with("/..") {
		return (Outcome::IsDirectory, same);
	}
	if c.create && std::fs::symlink_metadata(save_at).is_ok() {
		return (Outcome::Exists, same);
	}
	if c.create || c.force {
		return (verdict, same);
	}
	let expected = match at(save_at) {
		At::Unreadable => Outcome::Changed,
		At::File(b) if loaded != Some(&b[..]) => Outcome::Changed,
		_ => verdict,
	};
	(expected, same)
}

fn run_case(r: &Rules, base: &Path, label: &str, c: &Case) -> Result<Ran, String> {
	let line = format!("{label}\t{}", describe(r, c));
	let skipped = ![c.load, c.save]
		.iter()
		.all(|&s| on_this_os(&r.spells[s].os))
		|| !c.events.iter().all(|&e| on_this_os(&r.events[e].os));
	let mut ran = Ran {
		skipped,
		same: false,
		expected: Outcome::Io,
		got: Outcome::Io,
		line,
	};
	if skipped {
		return Ok(ran);
	}
	let root = base.join(label.replace(':', "-"));
	let x = root.join("x");
	let rp = root.join("r");
	build(&x, c);
	build(&rp, c);
	let load = &r.spells[c.load];
	let save = &r.spells[c.save];
	let (xw, rw) = (x.join("w"), rp.join("w"));
	let load_path = spelled(load, &xw);
	let x_load_at = from_root(&x, &load.cwd, &load_path);
	let r_load_at = from_root(&rp, &load.cwd, &spelled(load, &rw));

	let before_load = at(&x_load_at);
	std::env::set_current_dir(x.join(&load.cwd)).unwrap();
	let (mut doc, st) = Document::load_file(&load_path);
	let read = matches!(st, FileStatus::Clean | FileStatus::HadErrors);
	let loaded = match before_load {
		At::File(b) if read => Some(b),
		_ => None,
	};
	let _ = doc.set_int("k", 7);

	let mut save_cwd = save.cwd.clone();
	for &e in &c.events {
		let name = r.events[e].name.as_str();
		if name == "chdir" {
			save_cwd = if save_cwd == "w" { "o" } else { "w" }.to_string();
		}
		for tree in [&x, &rp] {
			let w = tree.join("w");
			let lp = from_root(tree, &load.cwd, &spelled(load, &w));
			let sp = from_root(tree, &save_cwd, &spelled(save, &w));
			apply(name, tree, &lp, &sp);
		}
	}

	let save_path = spelled(save, &xw);
	let x_save_at = from_root(&x, &save_cwd, &save_path);
	let r_save_at = from_root(&rp, &save_cwd, &spelled(save, &rw));
	let (expected, same) = oracle(
		&x_save_at,
		&r_save_at,
		&r_load_at,
		&save_path,
		loaded.as_deref(),
		c,
	);
	ran.same = same;
	ran.expected = expected;

	let before = snapshot(&x);
	std::env::set_current_dir(x.join(&save_cwd)).unwrap();
	let opts = SaveOptions {
		lossy: true,
		force: c.force,
		create: c.create,
		..SaveOptions::default()
	};
	let first = doc.save_file_with(&save_path, &opts);
	ran.got = classify(&first);
	std::env::set_current_dir(base).unwrap();
	let keep = |why: String| -> Result<Ran, String> {
		Err(format!(
			"{}: {why}\n\tthe tree is kept at {}",
			ran.line,
			root.display()
		))
	};
	if ran.got != expected {
		return keep(format!("expected {expected:?}, got {first:?}"));
	}
	if ran.got == Outcome::Ok {
		// A file already there keeps its mode, so one an event took the read
		// bits off is still unreadable after the save.
		#[cfg(unix)]
		if at(&x_save_at) == At::Unreadable {
			use std::os::unix::fs::PermissionsExt;
			let _ = std::fs::set_permissions(&x_save_at, std::fs::Permissions::from_mode(0o600));
		}
		let text = doc.to_string();
		if at(&x_save_at) != At::File(text.clone().into_bytes()) {
			return keep(format!("saved, but the path holds {:?}", at(&x_save_at)));
		}
		// What this document last wrote is no change, and a create-only
		// save now finds its own file.
		std::env::set_current_dir(x.join(&save_cwd)).unwrap();
		let again = doc.save_file_with(&save_path, &opts);
		std::env::set_current_dir(base).unwrap();
		let want = if c.create {
			Outcome::Exists
		} else {
			Outcome::Ok
		};
		if classify(&again) != want {
			return keep(format!("the second save gave {again:?}"));
		}
	} else if snapshot(&x) != before {
		return keep(format!(
			"refused as {first:?}, but the tree changed:\n\tbefore {before:?}\n\tafter {:?}",
			snapshot(&x)
		));
	}
	remove_tree(&root);
	Ok(ran)
}

/// The folder the cases go in: `SHCL_FS_DIR`, or the temp folder with a
/// note, never the project tree.
fn base_dir(test: &str) -> PathBuf {
	let parent = match std::env::var_os("SHCL_FS_DIR") {
		Some(d) => PathBuf::from(d),
		None => {
			let t = std::env::temp_dir();
			eprintln!(
				"note: SHCL_FS_DIR is not set, so the filesystem cases go under {}",
				t.display()
			);
			t
		}
	};
	let base = parent.join(format!("shcl-fs-{}-{test}", std::process::id()));
	remove_tree(&base);
	std::fs::create_dir_all(&base).unwrap();
	base.canonicalize().unwrap()
}

/// The cases a test ran, in `fs/NAME.tsv` under `SHCL_FUZZ_DUMP`, up to
/// `SHCL_FUZZ_DUMP_MAX` lines.
fn dump(name: &str, lines: &[String]) {
	let Some(dir) = std::env::var_os("SHCL_FUZZ_DUMP") else {
		return;
	};
	let max: usize = std::env::var("SHCL_FUZZ_DUMP_MAX")
		.ok()
		.and_then(|v| v.trim().parse().ok())
		.unwrap_or(5000);
	let dir = PathBuf::from(dir).join("fs");
	std::fs::create_dir_all(&dir).unwrap();
	let mut f = std::fs::File::create(dir.join(format!("{name}.tsv"))).unwrap();
	for l in lines.iter().take(max) {
		writeln!(f, "{l}").unwrap();
	}
}

fn dump_line(ran: &Ran) -> String {
	if ran.skipped {
		format!("{}\tskipped", ran.line)
	} else {
		format!("{}\tsame={}\t{:?}", ran.line, ran.same as u8, ran.got)
	}
}

/// The budget in seconds: `SHCL_FS_SECS`, 2 when unset. A value that isn't a
/// count is a mistake, not a setting.
fn budget_secs() -> u64 {
	match std::env::var("SHCL_FS_SECS") {
		Err(_) => 2,
		Ok(v) => v
			.trim()
			.parse::<u64>()
			.unwrap_or_else(|_| panic!("SHCL_FS_SECS is not a count: {v:?}")),
	}
}

struct Row {
	id: &'static str,
	/// The row's own platform where its spellings don't say, for an item
	/// whose bug was on one platform only.
	only: &'static str,
	t: bool,
	o: bool,
	load: &'static str,
	save: &'static str,
	events: &'static [&'static str],
	create: bool,
	expected: Outcome,
}

/// One row per past bug of the class, each a case the generator can draw.
/// 2026110313211991 was the CLIs' own check; its library twin is the FIFO row.
#[rustfmt::skip]
const ROWS: &[Row] = &[
	Row { id: "2026102910482342", only: "any", t: true, o: false, load: "bare", save: "bare", events: &["write-load"], create: false, expected: Outcome::Changed },
	Row { id: "2026110312163201-gone", only: "any", t: true, o: false, load: "bare", save: "dot", events: &["remove-load"], create: false, expected: Outcome::Ok },
	Row { id: "2026110312163201-made", only: "any", t: false, o: false, load: "bare", save: "bare", events: &["write-load"], create: false, expected: Outcome::Changed },
	Row { id: "2026110312163201-abs", only: "any", t: true, o: false, load: "dot", save: "abs", events: &["write-load"], create: false, expected: Outcome::Changed },
	Row { id: "2026110312163202-fifo", only: "any", t: true, o: false, load: "dot", save: "dot", events: &["fifo-load"], create: false, expected: Outcome::NotRegular },
	Row { id: "2026110312163202-unread", only: "any", t: true, o: false, load: "dot", save: "dot", events: &["write-load", "unread"], create: false, expected: Outcome::Changed },
	Row { id: "2026110312163207", only: "any", t: false, o: false, load: "dangle", save: "dangle", events: &["none"], create: true, expected: Outcome::Exists },
	Row { id: "2026110314064292", only: "any", t: false, o: false, load: "bare", save: "nodir", events: &["none"], create: false, expected: Outcome::Io },
	Row { id: "2026110314240418", only: "any", t: false, o: false, load: "nddot", save: "nd", events: &["mkdir", "write-load"], create: false, expected: Outcome::Changed },
	Row { id: "2026110408432594-link", only: "windows", t: false, o: false, load: "dangle", save: "dangle", events: &["none"], create: true, expected: Outcome::Exists },
	Row { id: "2026110408432594-dot", only: "windows", t: false, o: false, load: "nddot", save: "nd", events: &["mkdir", "write-load"], create: false, expected: Outcome::Changed },
	Row { id: "2026110613470307", only: "any", t: false, o: false, load: "nodir", save: "nodir", events: &["mkdir", "write-save"], create: false, expected: Outcome::Changed },
	Row { id: "2026110613470307-otherwd", only: "any", t: true, o: true, load: "bare", save: "bare", events: &["chdir"], create: false, expected: Outcome::Changed },
	Row { id: "2026110613470307-case", only: "macos", t: true, o: false, load: "case", save: "bare", events: &["write-load"], create: false, expected: Outcome::Changed },
	Row { id: "2026110613470308-trail", only: "any", t: true, o: false, load: "bare", save: "trail", events: &["none"], create: false, expected: Outcome::IsDirectory },
	Row { id: "2026110613470308-dot", only: "any", t: true, o: false, load: "bare", save: "traildot", events: &["none"], create: true, expected: Outcome::IsDirectory },
	Row { id: "2026110613470308-swap", only: "any", t: true, o: false, load: "bare", save: "bare", events: &["dir-load"], create: false, expected: Outcome::IsDirectory },
];

fn index(names: &[Rule], name: &str) -> usize {
	names
		.iter()
		.position(|r| r.name == name)
		.unwrap_or_else(|| panic!("fs-rules.tsv has no {name:?}, which a fixed row names"))
}

/// Every past bug of the class, as a fixed row the generator can draw too.
#[cfg_attr(miri, ignore = "makes files, links and FIFOs on disk")]
#[cfg_attr(windows, ignore = "the Windows rows wait for b29w (2026111019505861)")]
#[test]
fn the_save_checks_hold_on_every_past_path_bug() {
	let _id = test_id("df4bw");
	let _held = CWD.lock().unwrap_or_else(|e| e.into_inner());
	let r = rules();
	let base = base_dir("rows");
	let mut lines = Vec::new();
	let mut failed = Vec::new();
	for row in ROWS {
		let c = Case {
			t_there: row.t,
			o_there: row.o,
			load: index(&r.spells, row.load),
			save: index(&r.spells, row.save),
			events: row.events.iter().map(|e| index(&r.events, e)).collect(),
			create: row.create,
			force: false,
		};
		if !on_this_os(row.only) {
			lines.push(format!("row:{}\tskipped", row.id));
			continue;
		}
		// Every row runs, so one red run names each past bug that's back.
		match run_case(&r, &base, &format!("row:{}", row.id), &c) {
			Err(e) => failed.push(e),
			Ok(ran) => {
				lines.push(dump_line(&ran));
				if !ran.skipped && ran.expected != row.expected {
					failed.push(format!(
						"{}: the oracle says {:?}, the row {:?}",
						ran.line, ran.expected, row.expected
					));
				}
			}
		}
	}
	dump("rust-rows", &lines);
	assert!(failed.is_empty(), "{}", failed.join("\n"));
	remove_tree(&base);
}

/// Cases drawn by seed for the budget. Each case is a pure function of its
/// seed, so a failure replays from the seed in its message. A run that never
/// drew each spelling, event, answer, and both one file and 2, fails, since
/// it didn't test what it says.
#[cfg_attr(miri, ignore = "makes files, links and FIFOs on disk")]
#[cfg_attr(windows, ignore = "the Windows rows wait for b29w (2026111019505861)")]
#[test]
fn the_save_checks_hold_on_drawn_paths_and_events() {
	let _id = test_id("df4bx");
	let _held = CWD.lock().unwrap_or_else(|e| e.into_inner());
	let r = rules();
	let base = base_dir("drawn");
	if let Ok(v) = std::env::var("SHCL_FS_SEED") {
		let seed: u64 = v
			.trim()
			.parse()
			.unwrap_or_else(|_| panic!("SHCL_FS_SEED is not a seed: {v:?}"));
		let c = draw(&r, seed);
		let ran =
			run_case(&r, &base, &format!("seed:{seed}"), &c).unwrap_or_else(|e| panic!("{e}"));
		eprintln!("{}", dump_line(&ran));
		remove_tree(&base);
		return;
	}
	let until = std::time::Instant::now() + std::time::Duration::from_secs(budget_secs());
	let mut spells = BTreeSet::new();
	let mut events = BTreeSet::new();
	let mut outcomes = BTreeSet::new();
	let mut sames = BTreeSet::new();
	let mut lines = Vec::new();
	let mut seed = 0u64;
	while seed < MIN_CASES || std::time::Instant::now() < until {
		let c = draw(&r, seed);
		let ran =
			run_case(&r, &base, &format!("seed:{seed}"), &c).unwrap_or_else(|e| panic!("{e}"));
		lines.push(dump_line(&ran));
		if !ran.skipped {
			spells.insert(c.load);
			spells.insert(c.save);
			events.extend(c.events.iter().copied());
			outcomes.insert(ran.got);
			sames.insert(ran.same);
		}
		seed += 1;
	}
	dump("rust-drawn", &lines);
	for (i, s) in r.spells.iter().enumerate() {
		assert!(
			!on_this_os(&s.os) || spells.contains(&i),
			"{seed} cases never drew the spelling {}",
			s.name
		);
	}
	for (i, e) in r.events.iter().enumerate() {
		assert!(
			!on_this_os(&e.os) || events.contains(&i),
			"{seed} cases never drew the event {}",
			e.name
		);
	}
	for o in OUTCOMES {
		assert!(outcomes.contains(&o), "{seed} cases never gave {o:?}");
	}
	assert_eq!(
		sames.len(),
		2,
		"{seed} cases never gave both one file and 2"
	);
	eprintln!("fs property: {seed} cases");
	remove_tree(&base);
}
