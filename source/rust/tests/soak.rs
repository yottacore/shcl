// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! Heap growth over many rounds of load, read, set, save, merge, and validate
//! across the corpus. Nothing is kept from one round to the next, so the heap
//! after round 2N should be the heap after round N. Round N, not round 0: the
//! first rounds fill whatever caches there are. Its own binary, since the
//! allocator is global and dhat allows one profiler per process.

mod common;

use common::test_id;
use shcl::{Document, Strictness};
use std::path::{Path, PathBuf};

#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;

/// Growth from round N to round 2N that still passes. The noise is 0 here, and
/// a leak of 10 bytes per case per round is over it.
const MARGIN_BYTES: u64 = 4 * 1024;

struct Case {
	input: PathBuf,
	layer: Option<String>,
	schema: Option<String>,
}

fn corpus() -> Vec<Case> {
	let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../project/conformance");
	let mut dirs: Vec<PathBuf> = std::fs::read_dir(&root)
		.unwrap()
		.map(|e| e.unwrap().path())
		.filter(|p| p.join("input.shcl").is_file())
		.collect();
	dirs.sort();
	dirs.iter()
		.map(|d| Case {
			input: d.join("input.shcl"),
			layer: std::fs::read_to_string(d.join("layer1.shcl")).ok(),
			schema: std::fs::read_to_string(d.join("schema.shcl")).ok(),
		})
		.collect()
}

fn round(cases: &[Case], save_to: &str) {
	for case in cases {
		let (mut doc, _) = Document::load_file(case.input.to_str().unwrap());
		for path in doc.paths() {
			let _ = doc.read_string(&path);
			let _ = doc.read_int(&path);
			let _ = doc.children(&path);
		}
		let _ = doc.set_string("soak.name", "round");
		let _ = doc.set_int("soak.count", 42);
		let _ = doc.save_file(save_to);
		let _ = doc.save_file_keep_lines(save_to);
		if let Some(layer) = &case.layer {
			doc.merge(&Document::parse(layer));
		}
		if let Some(schema) = &case.schema {
			let text = doc.to_canonical();
			let _ = Document::load_and_validate(&text, schema, Strictness::Standard);
		}
	}
}

fn artifacts() -> PathBuf {
	Path::new(env!("CARGO_MANIFEST_DIR")).join("../../cicd/artifacts/soak")
}

#[cfg_attr(miri, ignore = "dhat's backtrace per allocation is far too slow there")]
#[test]
fn heap_holds_steady_over_rounds() {
	let _id = test_id("de2ns");
	let rounds: usize = std::env::var("SHCL_SOAK_ROUNDS")
		.ok()
		.and_then(|v| v.parse().ok())
		.unwrap_or(2);
	let cases = corpus();
	assert!(
		cases.len() > 100,
		"the corpus walk found {} cases",
		cases.len()
	);
	let dir = std::env::temp_dir().join(format!("shcl-soak-{}", std::process::id()));
	std::fs::create_dir_all(&dir).unwrap();
	let save_to = dir.join("soak.shcl").to_string_lossy().into_owned();
	let out = artifacts();
	std::fs::create_dir_all(&out).unwrap();
	let _ = std::fs::remove_file(out.join("rust-dhat-heap.json"));

	let _profiler = dhat::Profiler::builder()
		.testing()
		.file_name(out.join("rust-dhat-heap.json"))
		.build();
	let mut at = Vec::with_capacity(2 * rounds);
	for _ in 0..2 * rounds {
		round(&cases, &save_to);
		at.push(dhat::HeapStats::get());
	}
	let (n, n2) = (&at[rounds - 1], &at[2 * rounds - 1]);
	let grew = n2.curr_bytes.saturating_sub(n.curr_bytes) as u64;

	let mut report = format!(
		"rust soak: {} cases, {} rounds, margin {} bytes\nround\tcurr_bytes\tcurr_blocks\tmax_bytes\ttotal_bytes\n",
		cases.len(),
		2 * rounds,
		MARGIN_BYTES
	);
	for (i, s) in at.iter().enumerate() {
		report.push_str(&format!(
			"{}\t{}\t{}\t{}\t{}\n",
			i + 1,
			s.curr_bytes,
			s.curr_blocks,
			s.max_bytes,
			s.total_bytes
		));
	}
	report.push_str(&format!(
		"grew {grew} bytes from round {rounds} to round {}\n",
		2 * rounds
	));
	let _ = std::fs::write(out.join("rust-soak.txt"), &report);
	let _ = std::fs::remove_dir_all(&dir);

	// A failed dhat::assert! writes the heap profile beside the report.
	dhat::assert!(
		grew <= MARGIN_BYTES,
		"heap grew {} bytes from round {} to round {}:\n{}",
		grew,
		rounds,
		2 * rounds,
		report
	);
}
