// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! `upgrade` and `upgrade_file`: a file this version cannot load clean is
//! backed up under a timestamped name and written fresh, and a good one is
//! never touched. The backup's name reads the clock test_id pins.

mod common;

use common::test_id;
use shcl::{
	Document, GEN_BANNER, UpgradeError, WriteStatus, backup_file_name, migrate, upgrade,
	upgrade_file, write_backup,
};

fn scratch(tag: &str) -> std::path::PathBuf {
	let dir = std::env::temp_dir().join(format!("shcl-upgrade-{}-{}", tag, std::process::id()));
	let _ = std::fs::remove_dir_all(&dir);
	std::fs::create_dir_all(&dir).unwrap();
	dir
}

const V2_FILE: &str = "name: \"say \\\"hi\\\"\"\ntags: a, b\n\n#\n# This config file format is SHCL.\n# \"Simple Hierarchical Config Language\"\n#    Legal    SHCL is Copyright © 2026 Jim Collier. License: MIT. No warranty.\n#\n";

#[test]
fn upgrade_leaves_a_clean_or_stamped_file() {
	let _id = test_id("Es2R4RP");
	// a,b is one string now and an array under 2.x, but it loads clean, and
	// nothing says the file is 2.x.
	let clean = "a: 1\nb: x,y\n";
	let up = upgrade(clean, false);
	assert!(up.current && up.text == clean && up.diagnostics.is_empty());
	let up = upgrade(&stamped_comma_list(), true);
	assert!(up.current);
	// Old claim below, wrong since 2026101407100010: a beta Format 3 file that
	// loads with an error now converts with from_v2, so it isn't always
	// current. Don't uncomment. The new rule's test is
	// with_from_v2_a_stamped_file_with_an_error_is_taken_as_2x.
	// A beta build stamped the same Format line, so its errors are left too.
	// let beta = format!("tags: a, b\n\n{}", GEN_BANNER);
	// let up = upgrade(&beta, true);
	// assert!(up.current && up.text == beta && up.format == 3);
}

#[test]
fn with_from_v2_a_stamped_file_with_an_error_is_taken_as_2x() {
	let _id = test_id("EsgoThZ");
	// The caller says a 2.x build wrote it, as a beta of 3.0 could have
	// (2026101407100010). The backup name keeps the format the line names.
	let beta = format!("tags: a, b\n\n{}", GEN_BANNER);
	let up = upgrade(&beta, true);
	assert!(!up.current && up.format == 3 && up.lost == 0);
	assert!(up.diagnostics.iter().any(|d| d.code == "E026"));
	assert_eq!(up.text, format!("tags: [a, b]\n\n{}", GEN_BANNER));
	// What it leaves loads clean, so the next start leaves it alone.
	assert!(upgrade(&up.text, true).current);
	// Without from_v2, or when it loads clean, nothing changes.
	let up = upgrade(&beta, false);
	assert!(up.current && up.text == beta);
	assert!(upgrade(&stamped_comma_list(), true).current);
	// Old claim below, wrong since 2026101515372401: a fresh text that would
	// keep an error is refused, not current, and names its lines. Don't
	// uncomment. The new rule's test is
	// from_v2_refuses_a_conversion_that_keeps_an_error.
	// Nor when the fresh text would keep an error, which the next start would
	// take as 2.x again.
	// let stuck = "a: 1\nb 2\n##    Format   3\n";
	// let up = upgrade(stuck, true);
	// assert!(up.current && up.text == stuck && up.diagnostics.is_empty());
	// A lone stamp at the top goes too.
	let up = upgrade("##    Format   3\nname: x\nrange: 0, 100\n", true);
	assert_eq!(
		up.text,
		format!("name: x\nrange: [0, 100]\n\n{}", GEN_BANNER)
	);
	// migrate keeps leaving it alone: its text can keep a line with an error,
	// and a second run would take that as 2.x again.
	let m = migrate(&beta, true);
	assert!(m.current && m.text == beta);
}

#[test]
fn from_v2_refuses_a_conversion_that_keeps_an_error() {
	let _id = test_id("EsoQmU8");
	// The next run with from_v2 would read the fresh text by 2.x rules again,
	// and the 2.x escape on line 1 would grow each time (2026101515372401).
	// So nothing is made, with a Format line or not.
	let v2 = "\"k\u{25c9}Q\u{25c9}\": 1\n'C:\\': ~~~\n\tx\n\t~~~\nport: 8\u{3000}080\n";
	let up = upgrade(v2, true);
	assert!(!up.current && up.text == v2 && up.lost == 0);
	assert_eq!(up.errors_left, vec![5]);
	assert!(
		up.diagnostics
			.iter()
			.any(|d| d.code == "E025" && d.line == 5)
	);
	let stuck = "a: 1\nb 2\n##    Format   3\n";
	let up = upgrade(stuck, true);
	assert!(!up.current && up.text == stuck && up.errors_left == vec![2]);
	assert!(up.diagnostics.iter().any(|d| d.code == "E014"));
	// Without from_v2 a stamped file is current, and nothing would read the
	// fresh text as 2.x again.
	assert!(upgrade(stuck, false).current);
	// With the line fixed it converts, and the second run leaves it alone.
	let fixed = v2.replace("8\u{3000}080", "\"8\u{3000}080\"");
	let up = upgrade(&fixed, true);
	assert!(!up.current && up.errors_left.is_empty());
	assert_eq!(Document::parse(&up.text).error_count(), 0);
	assert!(upgrade(&up.text, true).current);
	// upgrade_file writes nothing, no backup either.
	let dir = scratch("left");
	let file = dir.join("f.shcl");
	let path = file.to_str().unwrap();
	std::fs::write(&file, v2).unwrap();
	let got = upgrade_file(path, true).unwrap_err();
	assert_eq!(
		got,
		UpgradeError::ErrorsLeft {
			path: path.to_string(),
			lines: vec![5]
		}
	);
	assert!(got.to_string().ends_with(
		": line(s) 5 would still have an error once converted from 2.x; nothing written"
	));
	assert_eq!(std::fs::read_to_string(&file).unwrap(), v2);
	assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
	let _ = std::fs::remove_dir_all(&dir);
}

fn stamped_comma_list() -> String {
	format!("p: a,b\n\n{}", GEN_BANNER)
}

#[test]
fn upgrade_from_v2_rewrites_a_clean_file_that_reads_differently() {
	let _id = test_id("Es2a1Jt");
	// The caller says it is 2.x, where a,b was an array.
	let up = upgrade("p: a,b\n", true);
	assert!(!up.current && up.lost == 0 && up.diagnostics.is_empty());
	assert_eq!(up.text, format!("p: [a, b]\n\n{}", GEN_BANNER));
	// Nothing reads differently, so there is nothing to do.
	let same = "a: 1\nb: x\n";
	let up = upgrade(same, true);
	assert!(up.current && up.text == same);
}

#[test]
fn an_older_format_line_becomes_this_one_in_place() {
	let _id = test_id("EsFrOVO");
	// Nothing else changes, so only the stamp does, and only with from_v2
	// (2026100717500017).
	let old = "port: 80\n##    Format   2\n";
	let up = upgrade(old, true);
	assert!(!up.current && up.format == 2 && up.lost == 0);
	assert_eq!(up.text, "port: 80\n##    Format   3\n");
	assert!(up.diagnostics.iter().any(|d| d.code == "H007"));
	assert!(upgrade(&up.text, true).current);
	let up = upgrade(old, false);
	assert!(up.current && up.text == old);
	// Indent, trailing blanks, line end and BOM stay as they were.
	let up = upgrade("\u{feff}p: 1\r\n\t##    Format   1  \r\nq: 2", true);
	assert_eq!(up.text, "\u{feff}p: 1\r\n\t##    Format   3  \r\nq: 2");
	// migrate writes its stamp there too, and adds one only to a file with
	// none (2026100916475300).
	assert_eq!(migrate(old, false).text, "port: 80\n##    Format   3\n");
	assert_eq!(
		migrate("x: a,b\n##    Format   2\ny: 1\n", false).text,
		"x: [a, b]\n##    Format   3\ny: 1\n##    Migrated from SHCL 2.x.\n"
	);
	assert_eq!(
		migrate("port: 80\n", false).text,
		"port: 80\n##    Format   3\n"
	);
}

#[test]
fn a_format_line_at_the_top_goes_when_the_block_goes_on() {
	let _id = test_id("Esgj35O");
	// The block names the format, so the file names one (2026101407100001).
	let up = upgrade("##    Format   2\nname: x\nq: a,b\n", true);
	assert_eq!(up.text, format!("name: x\nq: [a, b]\n\n{}", GEN_BANNER));
	let mut doc = Document::parse("##    Format   2\nname: x\n");
	assert_eq!(doc.set_banner(true), 1);
	assert_eq!(doc.to_canonical(), format!("name: x\n\n{}", GEN_BANNER));
	// Taking the block off leaves the top alone, as does putting one on over
	// a whole block there.
	let mut doc = Document::parse("##    Format   2\nname: x\n");
	assert_eq!(doc.set_banner(false), 0);
	assert_eq!(doc.to_canonical(), "##    Format   2\nname: x\n");
	let top = format!("{}name: x\n", GEN_BANNER);
	let mut doc = Document::parse(&top);
	assert_eq!(doc.set_banner(true), 0);
	assert_eq!(doc.to_canonical(), format!("{}\n{}", top, GEN_BANNER));
}

#[test]
fn upgrade_writes_a_fresh_file_with_the_info_block() {
	let _id = test_id("Es2R4TW");
	let up = upgrade(V2_FILE, false);
	assert!(!up.current && up.ambiguous == 0 && up.lost == 0);
	assert_eq!(up.format, 2);
	assert!(up.diagnostics.iter().any(|d| d.code == "E026"));
	// 2.x's block goes, links or none, and the one init writes takes its
	// place.
	// Old claim below, wrong since 2026101911300000: the value is the text
	// 2.x read, with the backslash pairs resolved. Don't uncomment.
	// let want = format!("name: 'say \\\"hi\\\"'\ntags: [a, b]\n\n{}", GEN_BANNER);
	let want = format!("name: 'say \"hi\"'\ntags: [a, b]\n\n{}", GEN_BANNER);
	assert_eq!(up.text, want);
	assert!(upgrade(&up.text, false).current);
}

#[test]
fn upgrade_refuses_text_that_reads_two_ways() {
	let _id = test_id("Es2R4Vy");
	let text = "a: x,y\nb: \"q\n";
	let up = upgrade(text, false);
	assert!(!up.current && up.ambiguous == 1 && up.text == text);
	let up = upgrade(text, true);
	assert!(up.ambiguous == 0 && up.text.starts_with("a: [x, y]\nb: '\"q'\n\n##\n"));
}

#[test]
fn backup_name_puts_the_tag_before_the_extension() {
	let _id = test_id("Es2R4YD");
	let tag = "_backup_20261004-001500_format-v2";
	assert_eq!(backup_file_name("f.shcl", 2), format!("f{tag}.shcl"));
	assert_eq!(
		backup_file_name("a/b.c.shcl", 2),
		format!("a/b.c{tag}.shcl")
	);
	assert_eq!(backup_file_name(".shclrc", 2), format!(".shclrc{tag}"));
	assert_eq!(backup_file_name("d.x/f", 2), format!("d.x/f{tag}"));
	assert_eq!(
		backup_file_name("f.shcl", 3),
		"f_backup_20261004-001500_format-v3.shcl"
	);
}

#[cfg_attr(
	miri,
	ignore = "saves to disk, and Miri has no fchown or directory fsync"
)]
#[test]
fn upgrade_file_backs_up_then_rewrites() {
	let _id = test_id("Es2R4aS");
	let dir = scratch("write");
	let file = dir.join("f.shcl");
	let path = file.to_str().unwrap();
	std::fs::write(&file, V2_FILE).unwrap();
	#[cfg(unix)]
	{
		use std::os::unix::fs::PermissionsExt;
		std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o640)).unwrap();
	}
	let up = upgrade_file(path, false).unwrap();
	let backup = dir.join("f_backup_20261004-001500_format-v2.shcl");
	assert_eq!(up.backup, backup.to_str().unwrap());
	assert_eq!(std::fs::read_to_string(&backup).unwrap(), V2_FILE);
	assert_eq!(std::fs::read_to_string(&file).unwrap(), up.text);
	#[cfg(unix)]
	{
		use std::os::unix::fs::PermissionsExt;
		let mode = std::fs::metadata(&backup).unwrap().permissions().mode();
		assert_eq!(mode & 0o7777, 0o640);
	}
	// The second start finds a current file and writes nothing.
	let again = upgrade_file(path, false).unwrap();
	assert!(again.current && again.backup.is_empty());
	assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 2);
	let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn upgrade_file_never_writes_over_a_backup() {
	let _id = test_id("Es2R4ch");
	let dir = scratch("taken");
	let file = dir.join("f.shcl");
	let path = file.to_str().unwrap();
	std::fs::write(&file, V2_FILE).unwrap();
	let backup = dir.join("f_backup_20261004-001500_format-v2.shcl");
	std::fs::write(&backup, "x\n").unwrap();
	let got = upgrade_file(path, false);
	assert_eq!(
		got.unwrap_err(),
		UpgradeError::BackupTaken(backup.to_str().unwrap().to_string())
	);
	assert_eq!(std::fs::read_to_string(&file).unwrap(), V2_FILE);
	assert_eq!(std::fs::read_to_string(&backup).unwrap(), "x\n");
	// Nothing at the path, and text that reads two ways, write nothing.
	let none = dir.join("none.shcl");
	assert!(matches!(
		upgrade_file(none.to_str().unwrap(), false),
		Err(UpgradeError::NotFound(_))
	));
	let amb = dir.join("amb.shcl");
	std::fs::write(&amb, "a: x,y\nb: \"q\n").unwrap();
	assert!(matches!(
		upgrade_file(amb.to_str().unwrap(), false),
		Err(UpgradeError::Ambiguous { count: 1, .. })
	));
	assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 3);
	let _ = std::fs::remove_dir_all(&dir);
}

/// The file and its text are both strings, and swapped they wrote a backup
/// named after the text and returned its name (2026101807501110).
#[cfg_attr(
	miri,
	ignore = "saves to disk, and Miri has no fchown or directory fsync"
)]
#[test]
fn write_backup_refuses_a_swapped_file_and_text() {
	let _id = test_id("Et6Am2s");
	let dir = scratch("swap");
	let file = dir.join("f.shcl").to_str().unwrap().to_string();
	// Read as a path the text names a spot in dir, so a backup made of it
	// would show there.
	let text = format!("{}/port: 80\nhost: x\n", dir.to_str().unwrap());
	let got = write_backup(&text, &file, 3);
	assert!(got.is_err(), "{got:?}");
	// A newline is no part of a windows name, so the create refuses it there.
	#[cfg(not(windows))]
	assert_eq!(got, Err(UpgradeError::NotFound(text.clone())));
	assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
	let sub = dir.join("d");
	std::fs::create_dir(&sub).unwrap();
	match write_backup(sub.to_str().unwrap(), "x: 1\n", 3) {
		Err(UpgradeError::Io(e)) => assert_eq!(e.status, WriteStatus::IsDirectory),
		other => panic!("backup of a directory: {other:?}"),
	}
	let left: Vec<_> = std::fs::read_dir(&dir)
		.unwrap()
		.map(|e| e.unwrap().file_name())
		.collect();
	assert_eq!(left, vec![std::ffi::OsString::from("d")]);
	let _ = std::fs::remove_dir_all(&dir);
}
