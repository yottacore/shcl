// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! One entry per library under test, plus the measurement itself.
//!
//! Every library parses to its own ecosystem's in-memory document model and
//! serializes back from that model with its own call, so no harness code sits
//! inside a timed region. The one unavoidable exception is noted on its entry.
//!
//! Peak memory comes from the kernel's own high-water mark (`VmHWM`), read once
//! after a single parse with the source text already resident, so the number is
//! "what it costs to hold this document", not "what the process did all day".
//! That makes the measurement Linux-only, which is where this tooling runs.

use std::hint::black_box;
use std::time::Instant;

pub struct Entry {
	pub key: &'static str,
	pub format: &'static str,
	pub library: &'static str,
	/// What survives a load: the file as written, or only its data.
	pub retains: &'static str,
	pub note: &'static str,
}

/// A table, kept as one: rustfmt would put every field of every row on its own
/// line and the seven entries would stop being comparable at a glance.
#[rustfmt::skip]
pub const ENTRIES: &[Entry] = &[
	Entry { key: "shcl", format: "shcl", library: "shcl", retains: "layout+comments",
		note: "the reference implementation in this repo" },
	Entry { key: "json", format: "json", library: "serde_json", retains: "data",
		note: "preserve_order on, so key order survives a load" },
	Entry { key: "yaml", format: "yaml", library: "serde_yaml_ng", retains: "data",
		note: "maintained successor to the archived serde_yaml" },
	Entry { key: "toml", format: "toml", library: "toml", retains: "data",
		note: "the ordinary read path" },
	Entry { key: "toml-edit", format: "toml", library: "toml_edit", retains: "layout+comments",
		note: "the only mainstream non-SHCL parser here that keeps the file as written" },
	Entry { key: "xml", format: "xml", library: "roxmltree", retains: "data",
		note: "fastest XML tree in Rust; read-only, so it has no emit" },
	Entry { key: "xml-dom", format: "xml", library: "xmltree", retains: "data",
		note: "the read/write XML tree, which is the job the other libraries are doing" },
];

/// Which generated file an entry reads.
pub fn source_fmt(key: &str) -> crate::model::Fmt {
	use crate::model::Fmt;
	match key {
		"shcl" => Fmt::Shcl,
		"json" => Fmt::Json,
		"yaml" => Fmt::Yaml,
		"toml" | "toml-edit" => Fmt::Toml,
		_ => Fmt::Xml,
	}
}

pub struct Measured {
	pub parse_secs: f64,
	pub emit_secs: Option<f64>,
	pub emit_bytes: usize,
	pub roundtrip: bool,
	pub scalars: u64,
	pub rss_bytes: u64,
	pub base_rss_bytes: u64,
	pub failed: Option<String>,
}

/// Kernel peak resident set for this process, in bytes.
pub fn vmhwm() -> u64 {
	#[cfg(test)]
	tests::note_read();
	let s = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
	for line in s.lines() {
		if let Some(rest) = line.strip_prefix("VmHWM:")
			&& let Some(kb) = rest.split_whitespace().next()
		{
			return kb.parse::<u64>().unwrap_or(0) * 1024;
		}
	}
	0
}

/// The whole sequence for one owned document model. Parse once for the memory
/// figure with nothing else in flight, then take the best of `iters` runs for
/// each of parse and emit - best-of rather than mean, because scheduler noise
/// only ever adds time.
///
/// Nothing else in flight includes the caller's validity check. Each entry
/// checks in an `if let` whose temporary is gone before this runs. The check as
/// a `match` scrutinee lived until the match ended, after the memory read, and
/// five entries were measured holding two documents.
fn measure<D>(
	src: &str,
	iters: usize,
	count: bool,
	base_rss_bytes: u64,
	parse: impl Fn(&str) -> D,
	emit: Option<&dyn Fn(&D) -> String>,
	scalars: impl Fn(&D) -> u64,
) -> Measured {
	let doc = parse(src);
	let rss_bytes = vmhwm();
	let scalar_count = if count { scalars(&doc) } else { 0 };
	drop(doc);

	let mut parse_secs = f64::MAX;
	for _ in 0..iters {
		let t = Instant::now();
		let d = parse(src);
		let e = t.elapsed().as_secs_f64();
		black_box(&d);
		if e < parse_secs {
			parse_secs = e;
		}
	}

	let doc = parse(src);
	let mut emit_secs = None;
	let mut out = String::new();
	if let Some(emit) = emit {
		let mut best = f64::MAX;
		for _ in 0..iters {
			let t = Instant::now();
			let s = emit(&doc);
			let e = t.elapsed().as_secs_f64();
			if e < best {
				best = e;
			}
			out = s;
		}
		emit_secs = Some(best);
	}

	Measured {
		parse_secs,
		emit_secs,
		emit_bytes: out.len(),
		roundtrip: !out.is_empty() && out == src,
		scalars: scalar_count,
		rss_bytes,
		base_rss_bytes,
		failed: None,
	}
}

fn failed(msg: String) -> Measured {
	Measured {
		parse_secs: 0.0,
		emit_secs: None,
		emit_bytes: 0,
		roundtrip: false,
		scalars: 0,
		rss_bytes: 0,
		base_rss_bytes: 0,
		failed: Some(msg),
	}
}

pub fn run(key: &str, src: &str, iters: usize, count: bool, base: u64) -> Measured {
	match key {
		"shcl" => run_shcl(src, iters, count, base),
		"json" => run_json(src, iters, count, base),
		"yaml" => run_yaml(src, iters, count, base),
		"toml" => run_toml(src, iters, count, base),
		"toml-edit" => run_toml_edit(src, iters, count, base),
		"xml" => run_roxmltree(src, iters, count, base),
		"xml-dom" => run_xmltree(src, iters, count, base),
		other => failed(format!("unknown entry {other}")),
	}
}

// SHCL

fn run_shcl(src: &str, iters: usize, count: bool, base: u64) -> Measured {
	let probe = shcl::Document::parse(src);
	if probe.error_count() > 0 || probe.lost_count() > 0 {
		return failed(format!(
			"{} diagnostics, {} lines lost",
			probe.error_count(),
			probe.lost_count()
		));
	}
	drop(probe);
	measure(
		src,
		iters,
		count,
		base,
		shcl::Document::parse,
		Some(&|d: &shcl::Document| d.to_canonical()),
		shcl_scalars,
	)
}

/// Counted the same way as every other model: one per scalar, one per array
/// element. A container binding holds no value and contributes nothing.
///
/// The walk goes through children() and instances() rather than paths(), which
/// is deduplicated and so collapses every repeated instance into one entry. It
/// resolves each path from the root, which is fine for the small pre-flight
/// document and is why nothing calls it on a measured one.
fn shcl_scalars(d: &shcl::Document) -> u64 {
	shcl_walk(d, "")
}

fn shcl_walk(d: &shcl::Document, prefix: &str) -> u64 {
	let kids = d.children(prefix);
	if kids.is_empty() {
		let r = d.read_string_array(prefix);
		if r.status == shcl::Status::Good {
			return r.value.len() as u64;
		}
		if d.read_raw(prefix).status == shcl::Status::Good {
			return 1;
		}
		return 0;
	}
	let mut seen = std::collections::HashSet::new();
	let mut n = 0;
	for name in kids {
		if !seen.insert(name.clone()) {
			continue;
		} // one visit per distinct name
		let seg = shcl::quote_segment(&name);
		let base = if prefix.is_empty() {
			seg
		} else {
			format!("{prefix}.{seg}")
		};
		let insts = d.instances(&base);
		if insts.len() > 1 {
			for v in insts {
				n += shcl_walk(d, &format!("{base}[{}]", shcl::quote_segment(&v)));
			}
		} else {
			n += shcl_walk(d, &base);
		}
	}
	n
}

// JSON

fn run_json(src: &str, iters: usize, count: bool, base: u64) -> Measured {
	if let Err(e) = serde_json::from_str::<serde_json::Value>(src) {
		return failed(e.to_string());
	}
	measure(
		src,
		iters,
		count,
		base,
		|s| serde_json::from_str::<serde_json::Value>(s).expect("checked above"),
		Some(&|v: &serde_json::Value| serde_json::to_string_pretty(v).unwrap_or_default()),
		json_scalars,
	)
}

fn json_scalars(v: &serde_json::Value) -> u64 {
	match v {
		serde_json::Value::Object(m) => m.values().map(json_scalars).sum(),
		serde_json::Value::Array(a) => a.iter().map(json_scalars).sum(),
		_ => 1,
	}
}

// YAML

fn run_yaml(src: &str, iters: usize, count: bool, base: u64) -> Measured {
	if let Err(e) = serde_yaml_ng::from_str::<serde_yaml_ng::Value>(src) {
		return failed(e.to_string());
	}
	measure(
		src,
		iters,
		count,
		base,
		|s| serde_yaml_ng::from_str::<serde_yaml_ng::Value>(s).expect("checked above"),
		Some(&|v: &serde_yaml_ng::Value| serde_yaml_ng::to_string(v).unwrap_or_default()),
		yaml_scalars,
	)
}

fn yaml_scalars(v: &serde_yaml_ng::Value) -> u64 {
	match v {
		serde_yaml_ng::Value::Mapping(m) => m.values().map(yaml_scalars).sum(),
		serde_yaml_ng::Value::Sequence(a) => a.iter().map(yaml_scalars).sum(),
		_ => 1,
	}
}

// TOML

fn run_toml(src: &str, iters: usize, count: bool, base: u64) -> Measured {
	if let Err(e) = src.parse::<toml::Table>() {
		return failed(e.to_string());
	}
	measure(
		src,
		iters,
		count,
		base,
		|s| s.parse::<toml::Table>().expect("checked above"),
		Some(&|t: &toml::Table| toml::to_string(t).unwrap_or_default()),
		|t: &toml::Table| t.values().map(toml_scalars).sum(),
	)
}

fn toml_scalars(v: &toml::Value) -> u64 {
	match v {
		toml::Value::Table(t) => t.values().map(toml_scalars).sum(),
		toml::Value::Array(a) => a.iter().map(toml_scalars).sum(),
		_ => 1,
	}
}

fn run_toml_edit(src: &str, iters: usize, count: bool, base: u64) -> Measured {
	if let Err(e) = src.parse::<toml_edit::DocumentMut>() {
		return failed(e.to_string());
	}
	measure(
		src,
		iters,
		count,
		base,
		|s| s.parse::<toml_edit::DocumentMut>().expect("checked above"),
		Some(&|d: &toml_edit::DocumentMut| d.to_string()),
		|d: &toml_edit::DocumentMut| edit_scalars(d.as_item()),
	)
}

fn edit_scalars(it: &toml_edit::Item) -> u64 {
	match it {
		toml_edit::Item::Table(t) => t.iter().map(|(_, v)| edit_scalars(v)).sum(),
		toml_edit::Item::ArrayOfTables(a) => a
			.iter()
			.map(|t| t.iter().map(|(_, v)| edit_scalars(v)).sum::<u64>())
			.sum(),
		toml_edit::Item::Value(v) => edit_value_scalars(v),
		toml_edit::Item::None => 0,
	}
}

fn edit_value_scalars(v: &toml_edit::Value) -> u64 {
	match v {
		toml_edit::Value::Array(a) => a.iter().map(edit_value_scalars).sum(),
		toml_edit::Value::InlineTable(t) => t.iter().map(|(_, v)| edit_value_scalars(v)).sum(),
		_ => 1,
	}
}

// XML

/// roxmltree borrows the source instead of copying it, which is most of why it
/// is fast and is a fair thing to show. It has no writer, by design, so the emit
/// column is empty rather than filled with harness code the other rows do not
/// have.
fn run_roxmltree(src: &str, iters: usize, count: bool, base: u64) -> Measured {
	if let Err(e) = roxmltree::Document::parse(src) {
		return failed(e.to_string());
	}

	let doc = roxmltree::Document::parse(src).expect("checked above");
	let rss_bytes = vmhwm();
	let scalars = if count {
		rox_scalars(doc.root_element())
	} else {
		0
	};
	drop(doc);

	let mut parse_secs = f64::MAX;
	for _ in 0..iters {
		let t = Instant::now();
		let d = roxmltree::Document::parse(src).expect("checked above");
		let e = t.elapsed().as_secs_f64();
		black_box(&d);
		if e < parse_secs {
			parse_secs = e;
		}
	}

	Measured {
		parse_secs,
		emit_secs: None,
		emit_bytes: 0,
		roundtrip: false,
		scalars,
		rss_bytes,
		base_rss_bytes: base,
		failed: None,
	}
}

fn rox_scalars(n: roxmltree::Node) -> u64 {
	let mut kids = n.children().filter(roxmltree::Node::is_element).peekable();
	if kids.peek().is_none() {
		return 1;
	}
	kids.map(rox_scalars).sum()
}

fn run_xmltree(src: &str, iters: usize, count: bool, base: u64) -> Measured {
	if let Err(e) = xmltree::Element::parse(src.as_bytes()) {
		return failed(e.to_string());
	}
	measure(
		src,
		iters,
		count,
		base,
		|s: &str| xmltree::Element::parse(s.as_bytes()).expect("checked above"),
		Some(&|e: &xmltree::Element| {
			let mut buf = Vec::new();
			let _ = e.write(&mut buf);
			String::from_utf8(buf).unwrap_or_default()
		}),
		xt_scalars,
	)
}

fn xt_scalars(e: &xmltree::Element) -> u64 {
	let kids: Vec<&xmltree::Element> = e.children.iter().filter_map(|c| c.as_element()).collect();
	if kids.is_empty() {
		return 1;
	}
	kids.into_iter().map(xt_scalars).sum()
}

#[cfg(test)]
mod tests {
	use std::alloc::{GlobalAlloc, Layout, System};
	use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};

	/// Heap bytes live now, and at the moment the memory figure was read.
	static LIVE: AtomicUsize = AtomicUsize::new(0);
	static AT_READ: AtomicUsize = AtomicUsize::new(0);

	struct Counting;

	unsafe impl GlobalAlloc for Counting {
		unsafe fn alloc(&self, l: Layout) -> *mut u8 {
			let p = unsafe { System.alloc(l) };
			if !p.is_null() {
				LIVE.fetch_add(l.size(), Relaxed);
			}
			p
		}
		unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
			unsafe { System.dealloc(p, l) };
			LIVE.fetch_sub(l.size(), Relaxed);
		}
		unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
			let q = unsafe { System.realloc(p, l, n) };
			if !q.is_null() {
				LIVE.fetch_add(n, Relaxed);
				LIVE.fetch_sub(l.size(), Relaxed);
			}
			q
		}
	}

	#[global_allocator]
	static A: Counting = Counting;

	pub fn note_read() {
		AT_READ.store(LIVE.load(Relaxed), Relaxed);
	}

	/// Heap one parsed document holds, parsed with the same call its entry uses.
	fn one_document(key: &str, src: &str) -> usize {
		let before = LIVE.load(Relaxed);
		macro_rules! held {
			($e:expr) => {{
				let d = $e;
				let n = LIVE.load(Relaxed) - before;
				drop(d);
				n
			}};
		}
		match key {
			"shcl" => held!(shcl::Document::parse(src)),
			"json" => held!(serde_json::from_str::<serde_json::Value>(src).unwrap()),
			"yaml" => held!(serde_yaml_ng::from_str::<serde_yaml_ng::Value>(src).unwrap()),
			"toml" => held!(src.parse::<toml::Table>().unwrap()),
			"toml-edit" => held!(src.parse::<toml_edit::DocumentMut>().unwrap()),
			"xml" => held!(roxmltree::Document::parse(src).unwrap()),
			_ => held!(xmltree::Element::parse(src.as_bytes()).unwrap()),
		}
	}

	/// The memory figure is "what it costs to hold this document", so when it is
	/// read exactly one document may be alive. A validity check kept alive past
	/// the read doubled five of the seven entries.
	#[test]
	fn memory_figure_holds_one_document() {
		let mut over = Vec::new();
		for e in super::ENTRIES {
			let fmt = super::source_fmt(e.key);
			let (src, _) = crate::render(crate::model::Shape::Records, fmt, 2000, None);
			let one = one_document(e.key, &src);
			let before = LIVE.load(Relaxed);
			let m = super::run(e.key, &src, 1, false, 0);
			assert!(m.failed.is_none(), "{}: {:?}", e.key, m.failed);
			let held = AT_READ.load(Relaxed).saturating_sub(before);
			if held >= one + one / 2 {
				over.push(format!(
					"{}: {held} bytes live at the read, one document is {one}",
					e.key
				));
			}
		}
		assert!(over.is_empty(), "{}", over.join("\n"));
	}
}
