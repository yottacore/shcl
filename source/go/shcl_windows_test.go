// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//go:build windows

package shcl

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Hidden and system survive a save. ReplaceFile's documented preserve list does
// not include the basic attributes and the fallback rename carries none, so a
// hidden config used to come back visible. Same fixture in every runner; its
// own file because the symbols are windows-only.
func TestSaveKeepsHiddenAndSystem(t *testing.T) {
	defer testID(t, "Eom3Uj2")
	f := filepath.Join(t.TempDir(), "h.shcl")
	if err := os.WriteFile(f, []byte("a: 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	p, perr := syscall.UTF16PtrFromString(f)
	if perr != nil {
		t.Fatal(perr)
	}
	if serr := syscall.SetFileAttributes(p, syscall.FILE_ATTRIBUTE_HIDDEN|syscall.FILE_ATTRIBUTE_SYSTEM); serr != nil {
		t.Fatal(serr)
	}
	if err := Parse("a: 2\n").SaveFile(f); err != nil {
		t.Fatal(err)
	}
	after, aerr := syscall.GetFileAttributes(p)
	if aerr != nil {
		t.Fatal(aerr)
	}
	if after&syscall.FILE_ATTRIBUTE_HIDDEN == 0 {
		t.Error("file did not come back hidden")
	}
	if after&syscall.FILE_ATTRIBUTE_SYSTEM == 0 {
		t.Error("file did not come back system")
	}
	_ = syscall.SetFileAttributes(p, syscall.FILE_ATTRIBUTE_NORMAL) // cleanup; the checks above are the test
}

func readText(p string) (string, bool) {
	b, err := os.ReadFile(p)
	return string(b), err == nil
}

// Taking add-file away from the target's folder, with the temp file in
// another, lets ReplaceFile move the old file out to the backup and then
// refuses the new one its place: error 1177, with nothing at the target.
// Neither the rename nor putting the old file back can get in either. A save
// always puts its temp file beside the target, so this calls the publish
// directly.
func TestFailedPublishLosesNeitherFile(t *testing.T) {
	defer testID(t, "EqYTuc6")
	root := t.TempDir()
	x, y := filepath.Join(root, "x"), filepath.Join(root, "y")
	for _, d := range []string{x, y} {
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	target, tmp := filepath.Join(y, "t.shcl"), filepath.Join(x, ".t.shcl.tmp1.0")
	backup := filepath.Join(x, ".t.shcl.bak1.0")
	if err := os.WriteFile(target, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tmp, []byte("new\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("icacls", y, "/deny", "*S-1-1-0:(WD)").CombinedOutput(); err != nil {
		t.Fatalf("icacls: %v %s", err, out)
	}
	// The hosted runner's administrator is let through anyway, and the case
	// cannot be set up there.
	probe := filepath.Join(x, "probe")
	if err := os.WriteFile(probe, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if os.Rename(probe, filepath.Join(y, "probe")) == nil {
		// Undo the deny so the temp dir can go. If it stays, that removal says so.
		_ = exec.Command("icacls", y, "/remove:d", "*S-1-1-0").Run()
		t.Logf("skipping the failed-publish fixture (a move into a denied folder went through)")
		return
	}
	perr := windowsPublishFile(tmp, target)
	if out, err := exec.Command("icacls", y, "/remove:d", "*S-1-1-0").CombinedOutput(); err != nil {
		t.Fatalf("icacls: %v %s", err, out)
	}
	if perr == nil {
		t.Fatal("the publish went through")
	}
	msg := perr.Error()
	if got, ok := readText(target); ok && got == "old\n" {
		if isThere(tmp) {
			t.Errorf("the temp file was left: %s", msg)
		}
		return
	}
	if _, ok := readText(target); ok {
		t.Errorf("target holds neither text: %s", msg)
	}
	if got, _ := readText(backup); got != "old\n" {
		t.Errorf("backup holds %q: %s", got, msg)
	}
	if got, _ := readText(tmp); got != "new\n" {
		t.Errorf("temp holds %q: %s", got, msg)
	}
	if !strings.Contains(msg, backup) || !strings.Contains(msg, tmp) {
		t.Errorf("the error does not name both files: %s", msg)
	}
}

// Anything holding the temp file open without delete sharing fails the replace
// and the rename both, the way a scanner looking at a fresh file does. A hold
// that ends in a few milliseconds must not fail the save.
func TestBriefHoldIsWaitedOut(t *testing.T) {
	defer testID(t, "EqYTuc7")
	root := t.TempDir()
	target, tmp := filepath.Join(root, "t.shcl"), filepath.Join(root, ".t.shcl.tmp1.0")
	if err := os.WriteFile(target, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tmp, []byte("new\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	p, perr := syscall.UTF16PtrFromString(tmp)
	if perr != nil {
		t.Fatal(perr)
	}
	hold, herr := syscall.CreateFile(p, syscall.GENERIC_READ, syscall.FILE_SHARE_READ, nil, syscall.OPEN_EXISTING, 0, 0)
	if herr != nil {
		t.Fatal(herr)
	}
	freed := make(chan struct{})
	go func() {
		time.Sleep(20 * time.Millisecond)
		syscall.CloseHandle(hold)
		close(freed)
	}()
	err := windowsPublishFile(tmp, target)
	<-freed
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := readText(target); got != "new\n" {
		t.Errorf("target holds %q", got)
	}
	if isThere(tmp) || isThere(filepath.Join(root, ".t.shcl.bak1.0")) {
		t.Error("the temp or the backup was left behind")
	}
}
