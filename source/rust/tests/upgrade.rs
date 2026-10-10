// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//! `upgrade` and `upgrade_file`: a file this version cannot load clean is
//! backed up under a timestamped name and written fresh, and a good one is
//! never touched. Its own binary, since the backup's name reads the clock
//! and every test here pins it the same way before anything else runs.

mod common;

use common::test_id;
use shcl::{GEN_BANNER, UpgradeError, backup_file_name, migrate, upgrade, upgrade_file};

const CLOCK: &str = "2026-10-04 00:15:00 -420 PDT";

fn pin_clock() {
	static ONCE: std::sync::Once = std::sync::Once::new();
	// SAFETY: every test here calls this first, and the Once holds the others
	// back until it is set, so nothing reads the environment meanwhile.
	ONCE.call_once(|| unsafe { std::env::set_var("SHCL_TEST_CLOCK", CLOCK) });
}

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
	pin_clock();
	// a,b is one string now and an array under 2.x, but it loads clean, and
	// nothing says the file is 2.x.
	let clean = "a: 1\nb: x,y\n";
	let up = upgrade(clean, false);
	assert!(up.current && up.text == clean && up.diagnostics.is_empty());
	let up = upgrade(&stamped_comma_list(), true);
	assert!(up.current);
	// A beta build stamped the same Format line, so its errors are left too.
	let beta = format!("tags: a, b\n\n{}", GEN_BANNER);
	let up = upgrade(&beta, true);
	assert!(up.current && up.text == beta && up.format == 3);
}

fn stamped_comma_list() -> String {
	format!("p: a,b\n\n{}", GEN_BANNER)
}

#[test]
fn upgrade_from_v2_rewrites_a_clean_file_that_reads_differently() {
	let _id = test_id("Es2a1Jt");
	pin_clock();
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
	pin_clock();
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
fn upgrade_writes_a_fresh_file_with_the_info_block() {
	let _id = test_id("Es2R4TW");
	pin_clock();
	let up = upgrade(V2_FILE, false);
	assert!(!up.current && up.ambiguous == 0 && up.lost == 0);
	assert_eq!(up.format, 2);
	assert!(up.diagnostics.iter().any(|d| d.code == "E026"));
	// 2.x's block goes, links or none, and the one init writes takes its
	// place.
	let want = format!("name: 'say \\\"hi\\\"'\ntags: [a, b]\n\n{}", GEN_BANNER);
	assert_eq!(up.text, want);
	assert!(upgrade(&up.text, false).current);
}

#[test]
fn upgrade_refuses_text_that_reads_two_ways() {
	let _id = test_id("Es2R4Vy");
	pin_clock();
	let text = "a: x,y\nb: \"q\n";
	let up = upgrade(text, false);
	assert!(!up.current && up.ambiguous == 1 && up.text == text);
	let up = upgrade(text, true);
	assert!(up.ambiguous == 0 && up.text.starts_with("a: [x, y]\nb: '\"q'\n\n##\n"));
}

#[test]
fn backup_name_puts_the_tag_before_the_extension() {
	let _id = test_id("Es2R4YD");
	pin_clock();
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

#[test]
fn upgrade_file_backs_up_then_rewrites() {
	let _id = test_id("Es2R4aS");
	pin_clock();
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
	pin_clock();
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
