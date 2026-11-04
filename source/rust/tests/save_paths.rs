// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! The save's changed check, by every spelling of the load's path. Its own
//! test binary, since it changes the working folder, which libtest's other
//! threads share.

mod common;

use common::test_id;
use shcl::{Document, FileStatus, SaveError};
use std::path::Path;

/// One file gives one answer however its path is spelled: bare, `./`,
/// absolute, through a link, in a folder made after the load, or from another
/// working folder. A FIFO swapped in gets the write's own refusal rather than
/// a wait, and a file the check can't read is a change (2026110312163201,
/// 2026110312163202).
#[cfg_attr(
	miri,
	ignore = "saves to disk, and Miri has no fchown or directory fsync"
)]
#[test]
fn a_changed_check_knows_its_file_by_any_spelling() {
	let _id = test_id("detpn");
	let dir = std::env::temp_dir().join(format!("shcl-save-paths-{}", std::process::id()));
	let _ = std::fs::remove_dir_all(&dir);
	std::fs::create_dir_all(dir.join("sub")).unwrap();
	let back = std::env::current_dir().unwrap();
	std::env::set_current_dir(&dir).unwrap();
	let abs = |name: &str| dir.join(name).to_str().unwrap().to_string();
	let read = |p: &str| std::fs::read_to_string(p).unwrap();
	let changed = |p: &str| {
		Err(SaveError::Changed {
			path: p.to_string(),
		})
	};

	// A bare name, gone since the load.
	std::fs::write("i.shcl", "a: 1\n").unwrap();
	let (mut gone, _) = Document::load_file("i.shcl");
	std::fs::remove_file("i.shcl").unwrap();
	assert_eq!(gone.save_file("i.shcl"), changed("i.shcl"));
	assert!(!Path::new("i.shcl").exists());

	// A bare name made where the load found nothing, saved by any spelling.
	let (mut fresh, st) = Document::load_file("h.shcl");
	assert_eq!(st, FileStatus::NotFound);
	let _ = fresh.set_int("a", 1);
	std::fs::write("h.shcl", "b: 2\n").unwrap();
	assert_eq!(fresh.save_file("h.shcl"), changed("h.shcl"));
	assert_eq!(fresh.save_file("./h.shcl"), changed("./h.shcl"));
	assert_eq!(fresh.save_file(&abs("h.shcl")), changed(&abs("h.shcl")));
	assert_eq!(read("h.shcl"), "b: 2\n");

	// Relative at the load, absolute at the save, and the other way round.
	std::fs::write("sub/l.shcl", "a: 1\n").unwrap();
	let (mut rel, _) = Document::load_file("sub/l.shcl");
	let (mut full, _) = Document::load_file(&abs("sub/l.shcl"));
	std::fs::write("sub/l.shcl", "a: 9\n").unwrap();
	assert_eq!(
		rel.save_file(&abs("sub/l.shcl")),
		changed(&abs("sub/l.shcl"))
	);
	assert_eq!(full.save_file("sub/l.shcl"), changed("sub/l.shcl"));
	assert_eq!(read("sub/l.shcl"), "a: 9\n");

	// A folder made after the load.
	let (mut later, st) = Document::load_file("new/n.shcl");
	assert_eq!(st, FileStatus::NotFound);
	std::fs::create_dir("new").unwrap();
	std::fs::write("new/n.shcl", "b: 2\n").unwrap();
	assert_eq!(
		later.save_file(&abs("new/n.shcl")),
		changed(&abs("new/n.shcl"))
	);
	assert_eq!(read("new/n.shcl"), "b: 2\n");

	// Through a link to the folder, with nothing there at the load.
	#[cfg(unix)]
	{
		std::os::unix::fs::symlink("sub", "ln").unwrap();
		let (mut linked, _) = Document::load_file("ln/k.shcl");
		std::fs::write("sub/k.shcl", "b: 2\n").unwrap();
		assert_eq!(linked.save_file("sub/k.shcl"), changed("sub/k.shcl"));
		assert_eq!(read("sub/k.shcl"), "b: 2\n");
	}

	// The same name from another working folder is another file, so it isn't
	// checked.
	std::fs::write("m.shcl", "a: 1\n").unwrap();
	let (mut moved, _) = Document::load_file("m.shcl");
	std::env::set_current_dir("sub").unwrap();
	std::fs::write("m.shcl", "z: 0\n").unwrap();
	assert_eq!(moved.save_file("m.shcl"), Ok(()));
	assert_eq!(read("m.shcl"), "a: 1\n");
	std::env::set_current_dir(&dir).unwrap();

	#[cfg(unix)]
	{
		use shcl::WriteStatus;
		use std::os::unix::fs::PermissionsExt;
		// `.` and a doubled separator under a folder made after the load
		// name no other file (2026110314240418).
		for (dir, load, save) in [
			("dn", "dn/./d.shcl", "dn/d.shcl".to_string()),
			("dd", "dd//d.shcl", abs("dd/d.shcl")),
		] {
			let (mut odd, _) = Document::load_file(load);
			std::fs::create_dir(dir).unwrap();
			std::fs::write(format!("{dir}/d.shcl"), "b: 2\n").unwrap();
			assert_eq!(odd.save_file(&save), changed(&save), "{load} then {save}");
			assert_eq!(read(&format!("{dir}/d.shcl")), "b: 2\n");
		}
		// A missing folder named with `..` is refused, as the kernel refuses
		// it, rather than canceled as text. Windows cancels it itself.
		let (mut through, _) = Document::load_file("q2.shcl");
		assert!(through.save_file("nodir/../q.shcl").is_err());
		assert!(!std::path::Path::new("q.shcl").exists());
		// A FIFO swapped in is refused as the write refuses it, with no wait.
		std::fs::write("f.shcl", "a: 1\n").unwrap();
		let (mut fifo, _) = Document::load_file("./f.shcl");
		std::fs::remove_file("f.shcl").unwrap();
		let made = std::process::Command::new("mkfifo")
			.arg("f.shcl")
			.status()
			.unwrap();
		assert!(made.success());
		match fifo.save_file("./f.shcl") {
			Err(SaveError::Io(e)) => assert_eq!(e.status, WriteStatus::NotRegular),
			other => panic!("a FIFO saved as {other:?}"),
		}

		// A file the check can't read, since another program wrote it and
		// took the read bit off, is a change. Root reads it anyway, so it's
		// only asked where the read fails.
		std::fs::write("p.shcl", "a: 1\n").unwrap();
		let (mut shut, _) = Document::load_file("./p.shcl");
		std::fs::write("p.shcl", "a: 9\n").unwrap();
		std::fs::set_permissions("p.shcl", std::fs::Permissions::from_mode(0o200)).unwrap();
		if std::fs::File::open("p.shcl").is_err() {
			assert_eq!(shut.save_file("./p.shcl"), changed("./p.shcl"));
		}
		std::fs::set_permissions("p.shcl", std::fs::Permissions::from_mode(0o600)).unwrap();
		assert_eq!(read("p.shcl"), "a: 9\n");
	}

	std::env::set_current_dir(back).unwrap();
	let _ = std::fs::remove_dir_all(&dir);
}
