// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// Upgrade and UpgradeFile: a file this version cannot load clean is backed up
// under a timestamped name and written fresh, and a good one is never
// touched. Twins of the reference's tests/upgrade.rs. The backup's name reads
// the clock TestMain pins.

package shcl

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const upgradeV2File = `name: "say \"hi\""
tags: a, b

#
# This config file format is SHCL.
# "Simple Hierarchical Config Language"
#    Legal    SHCL is Copyright © 2026 Jim Collier. License: MIT. No warranty.
#
`

func TestUpgradeLeavesACleanOrStampedFile(t *testing.T) {
	defer testID(t, "ddmk7")
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
	defer testID(t, "ddy84")
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
	// Old claim below, wrong since 2026101515372401: a fresh text that would
	// keep an error is refused, not current, and names its lines. Don't
	// uncomment. The new rule's test is
	// TestFromV2RefusesAConversionThatKeepsAnError.
	// Nor when the fresh text would keep an error, which the next start would
	// take as 2.x again.
	// stuck := "a: 1\nb 2\n##    Format   3\n"
	// if up := Upgrade(stuck, true); !up.Current || up.Text != stuck || len(up.Diagnostics) != 0 {
	// 	t.Fatalf("stuck: %+v", up)
	// }
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

func TestFromV2RefusesAConversionThatKeepsAnError(t *testing.T) {
	defer testID(t, "de02v")
	// The next run with fromV2 would read the fresh text by 2.x rules again,
	// and the 2.x escape on line 1 would grow each time (2026101515372401).
	// So nothing is made, with a Format line or not.
	v2 := "\"k\u25c9Q\u25c9\": 1\n'C:\\': ~~~\n\tx\n\t~~~\nport: 8\u3000080\n"
	up := Upgrade(v2, true)
	if up.Current || up.Text != v2 || up.Lost != 0 || len(up.ErrorsLeft) != 1 || up.ErrorsLeft[0] != 5 {
		t.Fatalf("2.x file: %+v", up)
	}
	e025 := false
	for _, d := range up.Diagnostics {
		e025 = e025 || (d.Code == "E025" && d.Line == 5)
	}
	if !e025 {
		t.Fatalf("no E025 on line 5 in %+v", up.Diagnostics)
	}
	stuck := "a: 1\nb 2\n##    Format   3\n"
	if up := Upgrade(stuck, true); up.Current || up.Text != stuck || len(up.ErrorsLeft) != 1 || up.ErrorsLeft[0] != 2 || len(up.Diagnostics) == 0 {
		t.Fatalf("stuck: %+v", up)
	}
	// Without fromV2 a stamped file is current, and nothing would read the
	// fresh text as 2.x again.
	if !Upgrade(stuck, false).Current {
		t.Fatal("stuck without fromV2 is not current")
	}
	// With the line fixed it converts, and the second run leaves it alone.
	fixed := strings.Replace(v2, "8\u3000080", "\"8\u3000080\"", 1)
	up = Upgrade(fixed, true)
	if up.Current || len(up.ErrorsLeft) != 0 || Parse(up.Text).ErrorCount() != 0 {
		t.Fatalf("fixed: %+v", up)
	}
	if !Upgrade(up.Text, true).Current {
		t.Fatal("fixed: the fresh text is not current")
	}
	// UpgradeFile writes nothing, no backup either.
	dir := t.TempDir()
	path := filepath.Join(dir, "f.shcl")
	if err := os.WriteFile(path, []byte(v2), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := UpgradeFile(path, true)
	var ue *UpgradeError
	if !errors.As(err, &ue) || ue.Kind != UpgradeErrorsLeft || ue.Path != path || len(ue.Lines) != 1 || ue.Lines[0] != 5 {
		t.Fatalf("UpgradeFile: %v", err)
	}
	if want := ": line(s) 5 would still have an error once converted from 2.x; nothing written"; !strings.HasSuffix(err.Error(), want) {
		t.Fatalf("message: %q", err.Error())
	}
	if b, _ := os.ReadFile(path); string(b) != v2 {
		t.Fatalf("the file changed: %q", b)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 1 {
		t.Fatalf("%d entries, not the file alone", len(ents))
	}
}

func TestABlockKeptAtTheTopNamesThisFormatToo(t *testing.T) {
	defer testID(t, "debk6")
	// The lone stamp comes off, and the block kept above the first field's
	// child named another format, which the fresh text then read as its own
	// (2026102309053667).
	text := "a: 1\n##    Format   3\n##\n## This config file format is SHCL.\n##    Format   4\n   b\n"
	if v, ok := FormatVersion(text); !ok || v != 3 {
		t.Fatalf("input names %d, %v", v, ok)
	}
	up := Upgrade(text, true)
	if up.Current || len(up.ErrorsLeft) != 0 || up.Ambiguous != 0 {
		t.Fatalf("not made over: %+v", up)
	}
	if v, ok := FormatVersion(up.Text); !ok || v != 3 || strings.Contains(up.Text, "Format   4") {
		t.Fatalf("fresh text names %d, %v: %q", v, ok, up.Text)
	}
	if !Upgrade(up.Text, false).Current {
		t.Fatalf("a second run made it over again: %q", up.Text)
	}
	// SetBanner takes the same path.
	d := Parse("a: 1\n##    Format   3\n##\n## This config file format is SHCL.\n##    Format   4\n   b: 2\n")
	d.SetBanner(true)
	if v, ok := FormatVersion(d.ToCanonical()); !ok || v != 3 {
		t.Fatalf("SetBanner: names %d, %v", v, ok)
	}
}

func TestUpgradeKeepsEachLineWhereItWas(t *testing.T) {
	defer testID(t, "dej59")
	// Blank lines and a raw block on its field's line stay put, so a line
	// number in the old file names the same line in the fresh one
	// (2026102620591101).
	text := "\n\nt:\n\taliases: a, b\n\n\n\nu: ~~~\nraw\n~~~\nw: 2\n"
	for _, fromV2 := range []bool{true, false} {
		up := Upgrade(text, fromV2)
		if up.Current || len(up.ErrorsLeft) != 0 {
			t.Fatalf("%v: not made over: %+v", fromV2, up)
		}
		if !strings.HasPrefix(up.Text, "\n\nt:\n\taliases: [a, b]\n\n\n\nu: ~~~\nraw\n~~~\nw: 2\n") {
			t.Fatalf("%v: lines moved: %q", fromV2, up.Text)
		}
		if !Upgrade(up.Text, false).Current {
			t.Fatalf("%v: a second run made it over again: %q", fromV2, up.Text)
		}
	}
}

func TestUpgradeFromV2RewritesACleanFileThatReadsDifferently(t *testing.T) {
	defer testID(t, "ddmk8")
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
	defer testID(t, "ddqrq")
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
	defer testID(t, "ddy7t")
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
	defer testID(t, "ddmk9")
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
	// Old claim below, wrong since 2026101911300000: the value is the text
	// 2.x read, with the backslash pairs resolved. Don't uncomment.
	// if want := "name: 'say \\\"hi\\\"'\ntags: [a, b]\n\n" + GenBanner; up.Text != want {
	if want := "name: 'say \"hi\"'\ntags: [a, b]\n\n" + GenBanner; up.Text != want {
		t.Fatalf("got %q, want %q", up.Text, want)
	}
	if !Upgrade(up.Text, false).Current {
		t.Fatal("the fresh text is not current")
	}
}

func TestUpgradeRefusesTextThatReadsTwoWays(t *testing.T) {
	defer testID(t, "ddmka")
	text := "a: x,y\nb: \"q\n"
	if up := Upgrade(text, false); up.Current || up.Ambiguous != 1 || up.Text != text {
		t.Fatalf("unsaid: %+v", up)
	}
	if up := Upgrade(text, true); up.Ambiguous != 0 || !strings.HasPrefix(up.Text, "a: [x, y]\nb: '\"q'\n\n##\n") {
		t.Fatalf("from 2.x: %+v", up)
	}
}

func TestBackupNamePutsTheTagBeforeTheExtension(t *testing.T) {
	defer testID(t, "ddmkb")
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
	defer testID(t, "ddmkc")
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
	defer testID(t, "ddmkd")
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

// The file and its text are both strings, and swapped they wrote a backup
// named after the text and returned its name (2026101807501110).
func TestWriteBackupRefusesASwappedFileAndText(t *testing.T) {
	defer testID(t, "de4bb")
	dir := t.TempDir()
	file := filepath.Join(dir, "f.shcl")
	// Read as a path the text names a spot in dir, so a backup made of it
	// would show there.
	text := dir + "/port: 80\nhost: x\n"
	got, err := WriteBackup(text, file, 3)
	var ue *UpgradeError
	if !errors.As(err, &ue) {
		t.Fatalf("swapped: %q, %v", got, err)
	}
	// A newline is no part of a windows name, so the create refuses it there.
	if runtime.GOOS != "windows" && (ue.Kind != UpgradeNotFound || ue.Path != text) {
		t.Fatalf("swapped: %v", err)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 0 {
		t.Fatalf("%d entries, want 0", len(ents))
	}
	sub := filepath.Join(dir, "d")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	_, err = WriteBackup(sub, "x: 1\n", 3)
	var we *WriteError
	if !errors.As(err, &ue) || ue.Kind != UpgradeIO || !errors.As(err, &we) || we.Status != WriteIsDirectory {
		t.Fatalf("backup of a directory: %v", err)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 1 || ents[0].Name() != "d" {
		t.Fatalf("left %v", ents)
	}
}
