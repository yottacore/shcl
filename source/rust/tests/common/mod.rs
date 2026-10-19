// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! One status line per test, with the test's ID, for the pipeline's console.

use std::io::Write;

/// Held for the length of a test. Its line goes out when it drops, as a
/// failure when that is by a panic.
pub struct TestId(&'static str);

/// Every test calls this first, so it also pins the clock.
pub fn test_id(id: &'static str) -> TestId {
	pin_clock();
	TestId(id)
}

/// The clock every test runs on, set by the first test to start. A setter's
/// note and a backup's name read it, and two of them made a second apart
/// differ. Tests share one environment across libtest's threads, so it is set
/// once and never changed; a test that needs the real clock runs the CLI with
/// the variable removed.
fn pin_clock() {
	static ONCE: std::sync::Once = std::sync::Once::new();
	// SAFETY: every test calls test_id first, and the Once holds the others
	// back until it is set, so nothing reads the environment meanwhile.
	ONCE.call_once(|| unsafe {
		std::env::set_var("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT")
	});
}

impl Drop for TestId {
	fn drop(&mut self) {
		let status = if std::thread::panicking() {
			"FAIL"
		} else {
			"ok"
		};
		// libtest names each test's thread after the test.
		let thread = std::thread::current();
		status_line(status, self.0, thread.name().unwrap_or("?"));
	}
}

/// Straight to stderr, since libtest captures only the print macros. Its own
/// per-test lines on stdout are the pipeline's to drop.
pub fn status_line(status: &str, id: &str, name: &str) {
	let _ = writeln!(
		std::io::stderr().lock(),
		"{:<4} {} rust {}",
		status,
		id,
		name
	);
}
