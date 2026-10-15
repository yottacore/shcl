// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// Upgrade and UpgradeFile: a file this version cannot load clean is backed up
// under a timestamped name and written fresh, and a good one is never
// touched. Twins of the reference's tests/upgrade.rs; each pins the clock the
// backup's name reads.

package shcl

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const upgradeClock = "2026-10-04 00:15:00 -420 PDT"

const upgradeV2File = `name: "say \"hi\""
tags: a, b

#
# This config file format is SHCL.
# "Simple Hierarchical Config Language"
#    Legal    SHCL is Copyright © 2026 Jim Collier. License: MIT. No warranty.
#
`

func TestUpgradeLeavesACleanOrStampedFile(t *testing.T) {
	defer testID(t, "Es2fwnG")
	t.Setenv("SHCL_TEST_CLOCK", upgradeClock)
	// a,b is one string now and an array under 2.x, but it loads clean, and
	// nothing says the file is 2.x.
	clean := "a: 1\nb: x,y\n"
	if up := Upgrade(clean, false); !up.Current || up.Text != clean || len(up.Diagnostics) != 0 {
		t.Fatalf("clean file: %+v", up)
	}
	if up := Upgrade("p: a,b\n\n"+GenBanner, true); !up.Current {
		t.Fatalf("stamped file: %+v", up)
	}
	// Old claim below, wrong since 2026101407100010: a beta Format 3 file that
	// loads with an error now converts with fromV2, so it isn't always
	// current. Don't uncomment. The new rule's test is
	// TestWithFromV2AStampedFileWithAnErrorIsTakenAs2x.
	// A beta build stamped the same Format line, so its errors are left too.
	// beta := "tags: a, b\n\n" + GenBanner
	// if up := Upgrade(beta, true); !up.Current || up.Text != beta || up.Format != 3 {
	// 	t.Fatalf("beta file: %+v", up)
	// }
}

func TestWithFromV2AStampedFileWithAnErrorIsTakenAs2x(t *testing.T) {
	defer testID(t, "EsgoTha")
	t.Setenv("SHCL_TEST_CLOCK", upgradeClock)
	// The caller says a 2.x build wrote it, as a beta of 3.0 could have
	// (2026101407100010). The backup name keeps the format the line names.
	beta := "tags: a, b\n\n" + GenBanner
	up := Upgrade(beta, true)
	if up.Current || up.Format != 3 || up.Lost != 0 || up.Text != "tags: [a, b]\n\n"+GenBanner {
		t.Fatalf("beta file: %+v", up)
	}
	e026 := false
	for _, d := range up.Diagnostics {
		e026 = e026 || d.Code == "E026"
	}
	if !e026 {
		t.Fatalf("no E026 in %+v", up.Diagnostics)
	}
	// What it leaves loads clean, so the next start leaves it alone.
	if !Upgrade(up.Text, true).Current {
		t.Fatal("the fresh text is not current")
	}
	// Without fromV2, or when it loads clean, nothing changes.
	if up := Upgrade(beta, false); !up.Current || up.Text != beta {
		t.Fatalf("without fromV2: %+v", up)
	}
	if !Upgrade("p: a,b\n\n"+GenBanner, true).Current {
		t.Fatal("a clean stamped file is not current")
	}
	// Nor when the fresh text would keep an error, which the next start would
	// take as 2.x again.
	stuck := "a: 1\nb 2\n##    Format   3\n"
	if up := Upgrade(stuck, true); !up.Current || up.Text != stuck || len(up.Diagnostics) != 0 {
		t.Fatalf("stuck: %+v", up)
	}
	// A lone stamp at the top goes too.
	if got, want := Upgrade("##    Format   3\nname: x\nrange: 0, 100\n", true).Text, "name: x\nrange: [0, 100]\n\n"+GenBanner; got != want {
		t.Fatalf("top stamp: got %q, want %q", got, want)
	}
	// Migrate keeps leaving it alone: its text can keep a line with an error,
	// and a second run would take that as 2.x again.
	if m := Migrate(beta, true); !m.Current || m.Text != beta {
		t.Fatalf("migrate: %+v", m)
	}
}

func TestUpgradeFromV2RewritesACleanFileThatReadsDifferently(t *testing.T) {
	defer testID(t, "Es2fwpc")
	t.Setenv("SHCL_TEST_CLOCK", upgradeClock)
	// The caller says it is 2.x, where a,b was an array.
	up := Upgrade("p: a,b\n", true)
	if up.Current || up.Lost != 0 || len(up.Diagnostics) != 0 {
		t.Fatalf("from 2.x: %+v", up)
	}
	if want := "p: [a, b]\n\n" + GenBanner; up.Text != want {
		t.Fatalf("got %q, want %q", up.Text, want)
	}
	// Nothing reads differently, so there is nothing to do.
	same := "a: 1\nb: x\n"
	if up := Upgrade(same, true); !up.Current || up.Text != same {
		t.Fatalf("same text: %+v", up)
	}
}

func TestAnOlderFormatLineBecomesThisOneInPlace(t *testing.T) {
	defer testID(t, "EsFrOVP")
	t.Setenv("SHCL_TEST_CLOCK", upgradeClock)
	// Nothing else changes, so only the stamp does, and only with fromV2
	// (2026100717500017).
	old := "port: 80\n##    Format   2\n"
	up := Upgrade(old, true)
	if up.Current || up.Format != 2 || up.Lost != 0 || up.Text != "port: 80\n##    Format   3\n" {
		t.Fatalf("restamp: %+v", up)
	}
	h007 := false
	for _, d := range up.Diagnostics {
		h007 = h007 || d.Code == "H007"
	}
	if !h007 {
		t.Fatalf("no H007 in %+v", up.Diagnostics)
	}
	if !Upgrade(up.Text, true).Current {
		t.Fatal("the restamped text is not current")
	}
	if up := Upgrade(old, false); !up.Current || up.Text != old {
		t.Fatalf("without fromV2: %+v", up)
	}
	// Indent, trailing blanks, line end and BOM stay as they were.
	if got, want := Upgrade("\ufeffp: 1\r\n\t##    Format   1  \r\nq: 2", true).Text, "\ufeffp: 1\r\n\t##    Format   3  \r\nq: 2"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	// Migrate writes its stamp there too, and adds one only to a file with
	// none (2026100916475300).
	for _, c := range [][2]string{
		{old, "port: 80\n##    Format   3\n"},
		{"x: a,b\n##    Format   2\ny: 1\n", "x: [a, b]\n##    Format   3\ny: 1\n##    Migrated from SHCL 2.x.\n"},
		{"port: 80\n", "port: 80\n##    Format   3\n"},
	} {
		if got := Migrate(c[0], false).Text; got != c[1] {
			t.Fatalf("migrate %q: got %q, want %q", c[0], got, c[1])
		}
	}
}

func TestAFormatLineAtTheTopGoesWhenTheBlockGoesOn(t *testing.T) {
	defer testID(t, "Esgj35P")
	t.Setenv("SHCL_TEST_CLOCK", upgradeClock)
	// The block names the format, so the file names one (2026101407100001).
	if got, want := Upgrade("##    Format   2\nname: x\nq: a,b\n", true).Text, "name: x\nq: [a, b]\n\n"+GenBanner; got != want {
		t.Fatalf("upgrade: got %q, want %q", got, want)
	}
	doc := Parse("##    Format   2\nname: x\n")
	if n := doc.SetBanner(true); n != 1 || doc.ToCanonical() != "name: x\n\n"+GenBanner {
		t.Fatalf("on: %d %q", n, doc.ToCanonical())
	}
	// Taking the block off leaves the top alone, as does putting one on over
	// a whole block there.
	doc = Parse("##    Format   2\nname: x\n")
	if n := doc.SetBanner(false); n != 0 || doc.ToCanonical() != "##    Format   2\nname: x\n" {
		t.Fatalf("off: %d %q", n, doc.ToCanonical())
	}
	top := GenBanner + "name: x\n"
	doc = Parse(top)
	if n := doc.SetBanner(true); n != 0 || doc.ToCanonical() != top+"\n"+GenBanner {
		t.Fatalf("top block: %d %q", n, doc.ToCanonical())
	}
}

func TestUpgradeWritesAFreshFileWithTheInfoBlock(t *testing.T) {
	defer testID(t, "Es2fws2")
	t.Setenv("SHCL_TEST_CLOCK", upgradeClock)
	up := Upgrade(upgradeV2File, false)
	if up.Current || up.Ambiguous != 0 || up.Lost != 0 || up.Format != 2 {
		t.Fatalf("2.x file: %+v", up)
	}
	e026 := false
	for _, d := range up.Diagnostics {
		e026 = e026 || d.Code == "E026"
	}
	if !e026 {
		t.Fatalf("no E026 in %+v", up.Diagnostics)
	}
	// 2.x's block goes, links or none, and the one init writes takes its
	// place.
	if want := "name: 'say \\\"hi\\\"'\ntags: [a, b]\n\n" + GenBanner; up.Text != want {
		t.Fatalf("got %q, want %q", up.Text, want)
	}
	if !Upgrade(up.Text, false).Current {
		t.Fatal("the fresh text is not current")
	}
}

func TestUpgradeRefusesTextThatReadsTwoWays(t *testing.T) {
	defer testID(t, "Es2fwuQ")
	t.Setenv("SHCL_TEST_CLOCK", upgradeClock)
	text := "a: x,y\nb: \"q\n"
	if up := Upgrade(text, false); up.Current || up.Ambiguous != 1 || up.Text != text {
		t.Fatalf("unsaid: %+v", up)
	}
	if up := Upgrade(text, true); up.Ambiguous != 0 || !strings.HasPrefix(up.Text, "a: [x, y]\nb: '\"q'\n\n##\n") {
		t.Fatalf("from 2.x: %+v", up)
	}
}

func TestBackupNamePutsTheTagBeforeTheExtension(t *testing.T) {
	defer testID(t, "Es2fwwd")
	t.Setenv("SHCL_TEST_CLOCK", upgradeClock)
	tag := "_backup_20261004-001500_format-v2"
	for _, c := range []struct {
		file   string
		format int
		want   string
	}{
		{"f.shcl", 2, "f" + tag + ".shcl"},
		{"a/b.c.shcl", 2, "a/b.c" + tag + ".shcl"},
		{".shclrc", 2, ".shclrc" + tag},
		{"d.x/f", 2, "d.x/f" + tag},
		{"f.shcl", 3, "f_backup_20261004-001500_format-v3.shcl"},
	} {
		if got := BackupFileName(c.file, c.format); got != c.want {
			t.Errorf("BackupFileName(%q, %d) = %q, want %q", c.file, c.format, got, c.want)
		}
	}
}

func TestUpgradeFileBacksUpThenRewrites(t *testing.T) {
	defer testID(t, "Es2fwyv")
	t.Setenv("SHCL_TEST_CLOCK", upgradeClock)
	dir := t.TempDir()
	file := filepath.Join(dir, "f.shcl")
	if err := os.WriteFile(file, []byte(upgradeV2File), 0o600); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(file, 0o640); err != nil {
			t.Fatal(err)
		}
	}
	up, err := UpgradeFile(file, false)
	if err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(dir, "f_backup_20261004-001500_format-v2.shcl")
	if up.Backup != backup {
		t.Fatalf("backup %q, want %q", up.Backup, backup)
	}
	if got, _ := os.ReadFile(backup); string(got) != upgradeV2File {
		t.Fatalf("backup holds %q", got)
	}
	if got, _ := os.ReadFile(file); string(got) != up.Text {
		t.Fatalf("file holds %q, want %q", got, up.Text)
	}
	if runtime.GOOS != "windows" {
		fi, err := os.Stat(backup)
		if err != nil {
			t.Fatal(err)
		}
		if mode := fi.Mode().Perm(); mode != 0o640 {
			t.Fatalf("backup mode %o, want 640", mode)
		}
	}
	// The second start finds a current file and writes nothing.
	again, err := UpgradeFile(file, false)
	if err != nil || !again.Current || again.Backup != "" {
		t.Fatalf("second run: %+v, %v", again, err)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 2 {
		t.Fatalf("%d entries, want 2", len(ents))
	}
}

func TestUpgradeFileNeverWritesOverABackup(t *testing.T) {
	defer testID(t, "Es2fx19")
	t.Setenv("SHCL_TEST_CLOCK", upgradeClock)
	dir := t.TempDir()
	file := filepath.Join(dir, "f.shcl")
	if err := os.WriteFile(file, []byte(upgradeV2File), 0o600); err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(dir, "f_backup_20261004-001500_format-v2.shcl")
	if err := os.WriteFile(backup, []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := UpgradeFile(file, false)
	var ue *UpgradeError
	if !errors.As(err, &ue) || ue.Kind != UpgradeBackupTaken || ue.Path != backup {
		t.Fatalf("taken: %v", err)
	}
	if got, _ := os.ReadFile(file); string(got) != upgradeV2File {
		t.Fatalf("file holds %q", got)
	}
	if got, _ := os.ReadFile(backup); string(got) != "x\n" {
		t.Fatalf("backup holds %q", got)
	}
	// Nothing at the path, and text that reads two ways, write nothing.
	_, err = UpgradeFile(filepath.Join(dir, "none.shcl"), false)
	if !errors.As(err, &ue) || ue.Kind != UpgradeNotFound {
		t.Fatalf("missing: %v", err)
	}
	amb := filepath.Join(dir, "amb.shcl")
	if err := os.WriteFile(amb, []byte("a: x,y\nb: \"q\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = UpgradeFile(amb, false)
	if !errors.As(err, &ue) || ue.Kind != UpgradeAmbiguous || ue.Count != 1 {
		t.Fatalf("ambiguous: %v", err)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 3 {
		t.Fatalf("%d entries, want 3", len(ents))
	}
}
