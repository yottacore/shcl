// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// Allocation bounds the corpus cannot see: a capped parse must not hold what
// it is about to refuse. Its own test binary because the counting allocator
// is global to the process, and the other test files run in parallel.

mod common;

use common::test_id;
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard};

struct Counting;
static IN_USE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

fn note(delta: isize) {
	let now = if delta >= 0 {
		IN_USE.fetch_add(delta as usize, Ordering::Relaxed) + delta as usize
	} else {
		IN_USE.fetch_sub((-delta) as usize, Ordering::Relaxed) - (-delta) as usize
	};
	PEAK.fetch_max(now, Ordering::Relaxed);
}

// SAFETY: every call goes straight to System, with only a counter on the side.
unsafe impl GlobalAlloc for Counting {
	unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
		note(layout.size() as isize);
		ALLOCS.fetch_add(1, Ordering::Relaxed);
		// SAFETY: the caller keeps GlobalAlloc's contract, passed on as is.
		unsafe { System.alloc(layout) }
	}
	unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
		note(-(layout.size() as isize));
		// SAFETY: the caller keeps GlobalAlloc's contract, passed on as is.
		unsafe { System.dealloc(ptr, layout) }
	}
	unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
		note(new_size as isize - layout.size() as isize);
		// SAFETY: the caller keeps GlobalAlloc's contract, passed on as is.
		unsafe { System.realloc(ptr, layout, new_size) }
	}
}

#[global_allocator]
static GLOBAL: Counting = Counting;

static ALLOCS: AtomicUsize = AtomicUsize::new(0);

// One test at a time, and one lock for all of them: the harness runs the tests
// in this file on threads, and the counters are global. A test takes its turn
// before it builds its input, or the build counts into whichever measurement
// is running beside it (2026101308163572).
static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

type Turn = MutexGuard<'static, ()>;

fn my_turn() -> Turn {
	// A failed test poisons the lock. The rest still measure fine.
	ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner())
}

/// Allocation calls made while f runs. The path scan used to build and free two
/// strings per segment per line, which no timing threshold could catch: it is a
/// few percent of a parse and inside the noise of any machine.
/// The harness's own threads still allocate now and then, so a single reading
/// can only come out too high. The same call repeated is deterministic, so the
/// lowest of several is the real figure.
fn allocs_during(_turn: &Turn, mut f: impl FnMut()) -> usize {
	let mut best = usize::MAX;
	for _ in 0..5 {
		let start = ALLOCS.load(Ordering::Relaxed);
		f();
		best = best.min(ALLOCS.load(Ordering::Relaxed) - start);
	}
	best
}

// The race only shows when the harness happens to run 2 of these side by side,
// so no run of the tests proves the order. Read it from the source instead:
// every test here opens on its ID and then its turn, before anything else.
#[test]
fn every_test_takes_its_turn_first() {
	let _id = test_id("EstZ5TB");
	let _turn = my_turn();
	let src = include_str!("mem_caps.rs");
	let mut tests = 0;
	let mut late = Vec::new();
	for chunk in src.split("#[test]\n").skip(1) {
		let mut body = chunk
			.lines()
			.map(str::trim)
			.filter(|l| !l.is_empty() && !l.starts_with("//"));
		let name = body.next().unwrap_or("");
		tests += 1;
		let id = body.next().unwrap_or("");
		let turn = body.next().unwrap_or("");
		let took_turn = turn.starts_with("let ") && turn.ends_with("= my_turn();");
		if !id.starts_with("let _id = test_id(") || !took_turn {
			late.push(name);
		}
	}
	assert!(
		tests >= 4,
		"found {tests} tests in mem_caps.rs; has the #[test] line changed?"
	);
	assert!(
		late.is_empty(),
		"these take their turn after doing something else first: {late:?}"
	);
}

#[cfg_attr(
	all(miri, not(shcl_miri_all)),
	ignore = "slow under Miri; --miri-all runs it"
)]
#[test]
fn a_plain_name_costs_the_scan_nothing() {
	let _id = test_id("EoneEzg");
	let turn = my_turn();
	use shcl::{Document, Strictness};
	// Same document twice over, once with one segment a line and once with
	// four. The extra segments add no extra text, so anything the count
	// gains is the scan allocating per segment.
	let lines = 2_000;
	let flat: String = (0..lines).map(|i| format!("k{}: v\n", i)).collect();
	let deep: String = (0..lines).map(|i| format!("a.b.c.k{}: v\n", i)).collect();
	let one = allocs_during(&turn, || {
		Document::parse_with(&flat, Strictness::Standard).unwrap();
	});
	let four = allocs_during(&turn, || {
		Document::parse_with(&deep, Strictness::Standard).unwrap();
	});
	// Three more segments a line. What is left is the segment vector growing to
	// hold them, about one allocation per extra segment; the scan used to add
	// two more on top of that, for the resolved and the folded spelling.
	let extra = four.saturating_sub(one);
	assert!(
		extra < lines * 3 * 2,
		"the path scan allocates per segment: {} allocations for {} lines of four segments against {} for one",
		four,
		lines,
		one
	);
}

/// Peak bytes held above the starting point while f runs: what the call
/// needed at its worst, not what it touched in total.
fn peak_during(_turn: &Turn, f: impl FnOnce()) -> usize {
	let start = IN_USE.load(Ordering::Relaxed);
	PEAK.store(start, Ordering::Relaxed);
	f();
	PEAK.load(Ordering::Relaxed) - start
}

#[cfg_attr(
	all(miri, not(shcl_miri_all)),
	ignore = "slow under Miri; --miri-all runs it"
)]
#[test]
fn element_cap_bounds_the_parse() {
	let _id = test_id("EoezJiC");
	let turn = my_turn();
	use shcl::{Document, Strictness};
	let text = format!("arr: [{}1]\nok: 5\n", "1, ".repeat(200_000));
	let capped = peak_during(&turn, || {
		let doc = Document::parse_limited(&text, Strictness::Standard, 0, 8, 0).unwrap();
		assert_eq!(doc.lost_count(), 1);
		assert_eq!(doc.get_int("ok"), Ok(5));
	});
	// The refused line used to be built in full first (48x the text), so the
	// cap saved nothing. What a capped parse holds is the text and its lines.
	assert!(
		capped < text.len() * 8,
		"a capped parse held the array it refused: {capped} bytes for {} of text",
		text.len()
	);
}

#[cfg_attr(
	all(miri, not(shcl_miri_all)),
	ignore = "slow under Miri; --miri-all runs it"
)]
#[test]
fn diagnostic_cap_bounds_the_parse() {
	let _id = test_id("EofAXrU");
	let turn = my_turn();
	use shcl::{Document, Strictness};
	// The stacked spelling refuses each element line past the cap on its own,
	// and every refusal is a diagnostic: with the element cap alone, 200k
	// refused lines cost more than the elements they refused. The diagnostic
	// cap is what bounds that.
	let text = format!("arr:\n{}", "\t- 1\n".repeat(200_000));
	let capped = peak_during(&turn, || {
		let doc = Document::parse_limited(&text, Strictness::Standard, 0, 8, 100).unwrap();
		assert_eq!(doc.diagnostics().len(), 101);
		assert_eq!(doc.lost_count(), 200_000 - 8);
	});
	assert!(
		capped < text.len() * 8,
		"a diagnostic-capped parse held its unlisted diagnostics: {capped} bytes for {} of text",
		text.len()
	);
}
