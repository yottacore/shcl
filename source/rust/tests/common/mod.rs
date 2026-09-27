// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! One status line per test, with the test's ID, for the pipeline's console.

use std::io::Write;

/// Held for the length of a test. Its line goes out when it drops, as a
/// failure when that is by a panic.
pub struct TestId(&'static str);

pub fn test_id(id: &'static str) -> TestId {
	TestId(id)
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
