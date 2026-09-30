// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

//go:build windows

package shcl

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
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

var (
	sddlAdvapi32         = syscall.NewLazyDLL("advapi32.dll")
	procSddlFileSecurity = sddlAdvapi32.NewProc("GetFileSecurityW")
	procSddlToStringSDDL = sddlAdvapi32.NewProc("ConvertSecurityDescriptorToStringSecurityDescriptorW")
)

// sddl is the file's DACL as SDDL, and false when it cannot be read.
func sddl(path string) (string, bool) {
	const daclSecurityInformation = 0x4
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return "", false
	}
	var need uint32
	_, _, _ = procSddlFileSecurity.Call(uintptr(unsafe.Pointer(p)), daclSecurityInformation, 0, 0, uintptr(unsafe.Pointer(&need)))
	if need == 0 {
		return "", false
	}
	sd := make([]uint64, (need+7)/8)
	r, _, _ := procSddlFileSecurity.Call(uintptr(unsafe.Pointer(p)), daclSecurityInformation,
		uintptr(unsafe.Pointer(&sd[0])), uintptr(len(sd)*8), uintptr(unsafe.Pointer(&need)))
	if r == 0 {
		return "", false
	}
	var out *uint16
	r, _, _ = procSddlToStringSDDL.Call(uintptr(unsafe.Pointer(&sd[0])), 1, daclSecurityInformation, uintptr(unsafe.Pointer(&out)), 0)
	if r == 0 {
		return "", false
	}
	n := 0
	for *(*uint16)(unsafe.Add(unsafe.Pointer(out), n*2)) != 0 {
		n++
	}
	s := syscall.UTF16ToString(unsafe.Slice(out, n))
	_, _ = syscall.LocalFree(syscall.Handle(uintptr(unsafe.Pointer(out))))
	return s, true
}

func underWine() bool {
	return syscall.NewLazyDLL("ntdll.dll").NewProc("wine_get_version").Find() == nil
}

func icaclsOK(t *testing.T, args ...string) {
	t.Helper()
	if out, err := exec.Command("icacls", args...).CombinedOutput(); err != nil {
		t.Fatalf("icacls %v: %v %s", args, err, out)
	}
}

// A save over a file whose DACL is narrower than its directory's must not put
// the new text under the directory's. Holding the target without delete sharing
// fails the publish on every try, which keeps the temp file there long enough
// for a poller to read its DACL. Same fixture in every runner.
func TestTempFileTakesTargetsDACL(t *testing.T) {
	defer testID(t, "ErO2NoE")
	if underWine() {
		t.Skip("wine keeps no ACLs")
	}
	root := t.TempDir()
	icaclsOK(t, root, "/grant", "*S-1-5-32-545:(OI)(CI)(R)")
	setups := []struct {
		name, prefix string
		acl          []string
	}{
		{"a.shcl", "D:P", []string{"/inheritance:r", "/grant:r", os.Getenv("USERNAME") + ":(F)"}},
		{"b.shcl", "D:AI", []string{"/grant", "*S-1-5-19:(R)"}},
	}
	for _, s := range setups {
		target := filepath.Join(root, s.name)
		if err := os.WriteFile(target, []byte("a: 1\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		icaclsOK(t, append([]string{target}, s.acl...)...)
		want, _ := sddl(target)
		if !strings.HasPrefix(want, s.prefix) {
			t.Fatalf("%s: the fixture did not take: %s", s.name, want)
		}
		tmp := filepath.Join(root, "."+s.name+".tmp"+strconv.Itoa(os.Getpid())+".0")
		p, perr := syscall.UTF16PtrFromString(target)
		if perr != nil {
			t.Fatal(perr)
		}
		hold, herr := syscall.CreateFile(p, syscall.GENERIC_READ, syscall.FILE_SHARE_READ, nil, syscall.OPEN_EXISTING, 0, 0)
		if herr != nil {
			t.Fatal(herr)
		}
		stop, seen := make(chan struct{}), make(chan string)
		go func() {
			last := ""
			for {
				select {
				case <-stop:
					seen <- last
					return
				default:
				}
				if got, ok := sddl(tmp); ok {
					last = got
				}
			}
		}()
		serr := WriteFileAtomic(target, "a: 2\n")
		close(stop)
		got := <-seen
		_ = syscall.CloseHandle(hold) // the checks below are the test
		if serr == nil {
			t.Fatalf("%s: a save over a held file went through", s.name)
		}
		if got == "" {
			t.Errorf("%s: the temp file was never seen", s.name)
		} else if got != want {
			t.Errorf("%s: the temp file's DACL is %s, want %s", s.name, got, want)
		}
		entries, rerr := os.ReadDir(root)
		if rerr != nil {
			t.Fatal(rerr)
		}
		for _, e := range entries {
			if strings.Contains(e.Name(), ".tmp") || strings.Contains(e.Name(), ".bak") {
				t.Errorf("%s: left behind: %s", s.name, e.Name())
			}
		}
		if err := WriteFileAtomic(target, "a: 2\n"); err != nil {
			t.Fatal(err)
		}
		if after, _ := sddl(target); after != want {
			t.Errorf("%s: the saved file's DACL is %s, want %s", s.name, after, want)
		}
	}
	fresh, plain := filepath.Join(root, "n.shcl"), filepath.Join(root, "p.shcl")
	if err := WriteFileAtomic(fresh, "a: 2\n"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(plain, []byte("a: 2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	born, ok := sddl(plain)
	if !ok {
		t.Fatal("the plain file's DACL could not be read")
	}
	if got, _ := sddl(fresh); got != born {
		t.Errorf("a new file's DACL is %s, want %s", got, born)
	}
	nb, _ := os.ReadFile(fresh)
	bb, _ := os.ReadFile(filepath.Join(root, "b.shcl"))
	if string(nb) != string(bb) {
		t.Errorf("an overwrite and a create wrote different bytes: %q and %q", bb, nb)
	}
	// With no DACL to copy, the create still goes through, with the
	// directory's.
	copied := filepath.Join(root, "c.shcl")
	cf, cerr := windowsCreateTemp(filepath.Join(root, "missing.shcl"), copied, 0o600)
	if cerr != nil {
		t.Fatal(cerr)
	}
	_ = cf.Close() // only its DACL is checked
	if got, _ := sddl(copied); got != born {
		t.Errorf("a temp file with no DACL to copy has %s, want %s", got, born)
	}
}
