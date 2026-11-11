// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

package shcl

// The save's changed, create-only and not-regular checks against a real
// folder, over cases drawn from project/fs-rules.tsv: a load spelling, a save
// spelling, and what another program did between them. The expected answer
// comes from reading the folder, never from the library. Rust's
// tests/fs_property.rs is the reference, function for function
// (2026110616475901).
//
// The folder is SHCL_FS_DIR, which the pipeline points at a tmpfs made for the
// run. The budget is SHCL_FS_SECS of wall clock, and SHCL_FUZZ_DUMP gets every
// case run, with its answer, in fs/go-rows.tsv and fs/go-drawn.tsv.
// SHCL_FS_SEED runs only that seed, to replay a failure.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// The fewest generated cases a run makes, whatever the budget, so the draw
// guard has enough to judge.
const fsMinCases = 400

const (
	fsLoaded = "a: 1\n"
	fsOther  = "b: 2\n"
	fsMarker = "marker: 1\n"
)

type fsRule struct {
	name, path, cwd, os string
}

type fsRules struct {
	spells, events []fsRule
}

func fsReadRules(t *testing.T) fsRules {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "project", "fs-rules.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	var r fsRules
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) != 5 {
			t.Fatalf("fs-rules.tsv: not 5 fields: %q", line)
		}
		rule := fsRule{name: f[1], path: f[2], cwd: f[3], os: f[4]}
		fsOnThisOS(rule.os)
		switch f[0] {
		case "spell":
			r.spells = append(r.spells, rule)
		case "event":
			r.events = append(r.events, rule)
		default:
			t.Fatalf("fs-rules.tsv: no such kind %q", f[0])
		}
	}
	return r
}

// The Windows rows wait for b29w (2026111019505861), so they skip
// everywhere for now, rather than run untried.
func fsOnThisOS(osName string) bool {
	switch osName {
	case "any":
		return true
	case "posix":
		return runtime.GOOS != "windows"
	case "macos":
		return runtime.GOOS == "darwin"
	case "windows":
		return false
	}
	panic(fmt.Sprintf("fs-rules.tsv: no such os %q", osName))
}

// splitMix is splitmix64, since it's a few lines in every binding.
type splitMix uint64

func (g *splitMix) next() uint64 {
	*g += 0x9E3779B97F4A7C15
	z := uint64(*g)
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

func (g *splitMix) below(n int) int {
	return int(g.next() % uint64(n))
}

type fsCase struct {
	tThere, oThere bool
	load, save     int
	events         []int
	create, force  bool
}

func fsDraw(r fsRules, seed uint64) fsCase {
	g := splitMix(seed)
	var c fsCase
	c.tThere = g.below(2) == 1
	c.oThere = g.below(2) == 1
	c.load = g.below(len(r.spells))
	c.save = g.below(len(r.spells))
	n := 1 + g.below(2)
	for i := 0; i < n; i++ {
		c.events = append(c.events, g.below(len(r.events)))
	}
	c.create = g.below(4) == 0
	c.force = g.below(4) == 0
	return c
}

type fsOutcome string

// Named as Rust's Debug names them, so the dumps compare as text.
const (
	fsOk          fsOutcome = "Ok"
	fsChanged     fsOutcome = "Changed"
	fsExists      fsOutcome = "Exists"
	fsIsDirectory fsOutcome = "IsDirectory"
	fsNotRegular  fsOutcome = "NotRegular"
	fsIo          fsOutcome = "Io"
)

var fsOutcomes = []fsOutcome{fsOk, fsChanged, fsExists, fsIsDirectory, fsNotRegular, fsIo}

func fsClassify(err error) fsOutcome {
	var c *SaveChanged
	var e *SaveExists
	var w *WriteError
	switch {
	case err == nil:
		return fsOk
	case errors.As(err, &c):
		return fsChanged
	case errors.As(err, &e):
		return fsExists
	case errors.As(err, &w):
		switch w.Status {
		case WriteIsDirectory:
			return fsIsDirectory
		case WriteNotRegular:
			return fsNotRegular
		}
		return fsIo
	}
	panic(fmt.Sprintf("a save this test never asks for: %v", err))
}

// fsAt is what sits at a path, followed through links, read without the
// library.
type fsAt struct {
	kind  string // nothing, file, unreadable, dir, special
	bytes string
}

func fsAtPath(p string) fsAt {
	fi, err := os.Stat(p)
	switch {
	case err != nil:
		return fsAt{kind: "nothing"}
	case fi.Mode().IsRegular():
		b, err := os.ReadFile(p)
		if err != nil {
			return fsAt{kind: "unreadable"}
		}
		return fsAt{kind: "file", bytes: string(b)}
	case fi.IsDir():
		return fsAt{kind: "dir"}
	}
	return fsAt{kind: "special"}
}

// fsSpelled is the spelling's path, as the library gets it from its working
// folder.
func fsSpelled(rule fsRule, w string) string {
	return strings.ReplaceAll(rule.path, "{W}", w)
}

// fsFromRoot is the same path from the case's root, for reading and events.
// Plain text, not filepath.Join, so nodir/.. still meets the kernel.
func fsFromRoot(root, cwd, path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	return root + "/" + cwd + "/" + path
}

func fsBuild(t *testing.T, root string, c fsCase) {
	t.Helper()
	w := filepath.Join(root, "w")
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(w, "sub"), 0o755))
	must(os.Mkdir(filepath.Join(root, "o"), 0o755))
	must(os.WriteFile(filepath.Join(w, "sub", "t.shcl"), []byte("s: 1\n"), 0o644))
	if c.tThere {
		must(os.WriteFile(filepath.Join(w, "t.shcl"), []byte(fsLoaded), 0o644))
	}
	if c.oThere {
		must(os.WriteFile(filepath.Join(root, "o", "t.shcl"), []byte("o: 1\n"), 0o644))
	}
	if runtime.GOOS != "windows" {
		must(os.Symlink(".", filepath.Join(w, "lw")))
		must(os.Symlink("t.shcl", filepath.Join(w, "lt.shcl")))
		must(os.Symlink("gone.shcl", filepath.Join(w, "dl.shcl")))
		must(os.Symlink("cy2.shcl", filepath.Join(w, "cy.shcl")))
		must(os.Symlink("cy.shcl", filepath.Join(w, "cy2.shcl")))
	}
}

func fsIsFifo(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode()&os.ModeNamedPipe != 0
}

// fsRemoveFile removes what's at the path but never a folder, as Rust's
// remove_file, where os.Remove also takes an empty one.
func fsRemoveFile(p string) {
	if fi, err := os.Lstat(p); err == nil && fi.IsDir() {
		return
	}
	_ = os.Remove(p)
}

// fsApply is another program's act between the load and the save. Each one
// that the tree makes impossible, such as a write through a link cycle, does
// nothing, the same in both trees.
func fsApply(event, root, load, save string) {
	w := filepath.Join(root, "w")
	write := func(p string) {
		if !fsIsFifo(p) {
			_ = os.WriteFile(p, []byte(fsOther), 0o644)
		}
	}
	switch event {
	case "none", "chdir":
	case "write-load":
		write(load)
	case "write-save":
		write(save)
	case "remove-load":
		fsRemoveFile(load)
	case "fifo-load":
		fsRemoveFile(load)
		_ = fsMkfifo(load)
	case "dir-load":
		fsRemoveFile(load)
		_ = os.Mkdir(load, 0o755)
	case "mkdir":
		_ = os.Mkdir(filepath.Join(w, "nodir"), 0o755)
		_ = os.Mkdir(filepath.Join(w, "nd"), 0o755)
	case "link-made":
		_ = os.Symlink("sub", filepath.Join(w, "nd"))
	case "relink":
		fsRemoveFile(filepath.Join(w, "lw"))
		_ = os.Symlink("sub", filepath.Join(w, "lw"))
		fsRemoveFile(filepath.Join(w, "lt.shcl"))
		_ = os.Symlink("sub/t.shcl", filepath.Join(w, "lt.shcl"))
	case "unread":
		// A file only, since a folder without its bits stops the case.
		if fi, err := os.Stat(load); err == nil && fi.Mode().IsRegular() {
			_ = os.Chmod(load, 0o200)
		}
	default:
		panic(fmt.Sprintf("no such event %q", event))
	}
}

// fsSnapshot is every name under the root, with what it is and holds, links
// not followed, so a refused save can be shown to have written nothing
// anywhere.
func fsSnapshot(root string) map[string]string {
	out := map[string]string{}
	var walk func(dir string)
	walk = func(dir string) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			out[dir] = "unlistable"
			return
		}
		for _, e := range entries {
			p := filepath.Join(dir, e.Name())
			fi, err := os.Lstat(p)
			if err != nil {
				out[p] = "gone"
				continue
			}
			switch m := fi.Mode(); {
			case m&os.ModeSymlink != 0:
				l, _ := os.Readlink(p)
				out[p] = "link " + l
			case m.IsDir():
				walk(p)
				out[p] = "dir"
			case m.IsRegular():
				b, err := os.ReadFile(p)
				if err != nil {
					out[p] = fmt.Sprintf("file of %d bytes, unreadable", fi.Size())
				} else {
					out[p] = fmt.Sprintf("file %q", b)
				}
			default:
				out[p] = "special"
			}
		}
	}
	walk(root)
	return out
}

// fsRemoveTree gives back the bits an event took, so the tree can go.
func fsRemoveTree(root string) {
	var unlock func(p string)
	unlock = func(p string) {
		fi, err := os.Lstat(p)
		if err != nil || !fi.IsDir() {
			return
		}
		_ = os.Chmod(p, 0o700)
		entries, _ := os.ReadDir(p)
		for _, e := range entries {
			unlock(filepath.Join(p, e.Name()))
		}
	}
	unlock(root)
	_ = os.RemoveAll(root)
}

// fsRan is one case's run and its answers.
type fsRan struct {
	skipped, same bool
	expected, got fsOutcome
	line          string
}

func fsDescribe(r fsRules, c fsCase) string {
	var events []string
	for _, e := range c.events {
		events = append(events, r.events[e].name)
	}
	b := func(v bool) int {
		if v {
			return 1
		}
		return 0
	}
	return fmt.Sprintf("t=%d o=%d load=%s save=%s events=%s create=%d force=%d",
		b(c.tThere), b(c.oThere), r.spells[c.load].name, r.spells[c.save].name,
		strings.Join(events, ","), b(c.create), b(c.force))
}

// fsOracle is the answer the save has to give, from the case's tree, and
// whether the 2 spellings name one file, from the replica: a marker written
// through the save spelling and read back through the load spelling.
func fsOracle(saveAt, rSaveAt, rLoadAt, savePath string, loaded *string, c fsCase) (fsOutcome, bool) {
	verdict := func() fsOutcome {
		if fi, err := os.Stat(rSaveAt); err == nil {
			if fi.IsDir() {
				return fsIsDirectory
			}
			if !fi.Mode().IsRegular() {
				return fsNotRegular
			}
		}
		f, err := os.OpenFile(rSaveAt, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
		if err != nil {
			return fsIo
		}
		_, _ = f.WriteString(fsMarker)
		_ = f.Close()
		return fsOk
	}()
	same := verdict == fsOk && fsAtPath(rLoadAt) == fsAt{kind: "file", bytes: fsMarker}
	if strings.HasSuffix(savePath, "/") || strings.HasSuffix(savePath, "/.") || strings.HasSuffix(savePath, "/..") {
		return fsIsDirectory, same
	}
	if _, err := os.Lstat(saveAt); c.create && err == nil {
		return fsExists, same
	}
	if c.create || c.force {
		return verdict, same
	}
	switch a := fsAtPath(saveAt); {
	case a.kind == "unreadable":
		return fsChanged, same
	case a.kind == "file" && (loaded == nil || *loaded != a.bytes):
		return fsChanged, same
	}
	return verdict, same
}

func fsRunCase(t *testing.T, r fsRules, base, label string, c fsCase) (fsRan, error) {
	t.Helper()
	ran := fsRan{line: label + "\t" + fsDescribe(r, c), expected: fsIo, got: fsIo}
	ran.skipped = !fsOnThisOS(r.spells[c.load].os) || !fsOnThisOS(r.spells[c.save].os)
	for _, e := range c.events {
		if !fsOnThisOS(r.events[e].os) {
			ran.skipped = true
		}
	}
	if ran.skipped {
		return ran, nil
	}
	root := filepath.Join(base, strings.ReplaceAll(label, ":", "-"))
	x := filepath.Join(root, "x")
	rp := filepath.Join(root, "r")
	fsBuild(t, x, c)
	fsBuild(t, rp, c)
	load := r.spells[c.load]
	save := r.spells[c.save]
	xw, rw := filepath.Join(x, "w"), filepath.Join(rp, "w")
	loadPath := fsSpelled(load, xw)
	xLoadAt := fsFromRoot(x, load.cwd, loadPath)
	rLoadAt := fsFromRoot(rp, load.cwd, fsSpelled(load, rw))

	beforeLoad := fsAtPath(xLoadAt)
	if err := os.Chdir(filepath.Join(x, load.cwd)); err != nil {
		t.Fatal(err)
	}
	doc, st := LoadFile(loadPath)
	var loaded *string
	if beforeLoad.kind == "file" && (st == FileClean || st == FileHadErrors) {
		loaded = &beforeLoad.bytes
	}
	_ = doc.SetInt("k", 7)

	saveCwd := save.cwd
	for _, e := range c.events {
		name := r.events[e].name
		if name == "chdir" {
			if saveCwd == "w" {
				saveCwd = "o"
			} else {
				saveCwd = "w"
			}
		}
		for _, tree := range []string{x, rp} {
			w := filepath.Join(tree, "w")
			lp := fsFromRoot(tree, load.cwd, fsSpelled(load, w))
			sp := fsFromRoot(tree, saveCwd, fsSpelled(save, w))
			fsApply(name, tree, lp, sp)
		}
	}

	savePath := fsSpelled(save, xw)
	xSaveAt := fsFromRoot(x, saveCwd, savePath)
	rSaveAt := fsFromRoot(rp, saveCwd, fsSpelled(save, rw))
	expected, same := fsOracle(xSaveAt, rSaveAt, rLoadAt, savePath, loaded, c)
	ran.same = same
	ran.expected = expected

	before := fsSnapshot(x)
	if err := os.Chdir(filepath.Join(x, saveCwd)); err != nil {
		t.Fatal(err)
	}
	opts := SaveOptions{Lossy: true, Force: c.force, Create: c.create}
	_, first := doc.SaveFileWith(savePath, opts)
	ran.got = fsClassify(first)
	if err := os.Chdir(base); err != nil {
		t.Fatal(err)
	}
	keep := func(why string) (fsRan, error) {
		return ran, fmt.Errorf("%s: %s\n\tthe tree is kept at %s", ran.line, why, root)
	}
	if ran.got != expected {
		return keep(fmt.Sprintf("expected %s, got %v", expected, first))
	}
	if ran.got == fsOk {
		// A file already there keeps its mode, so one an event took the read
		// bits off is still unreadable after the save.
		if fsAtPath(xSaveAt).kind == "unreadable" {
			_ = os.Chmod(xSaveAt, 0o600)
		}
		if a := fsAtPath(xSaveAt); a != (fsAt{kind: "file", bytes: doc.ToCanonical()}) {
			return keep(fmt.Sprintf("saved, but the path holds %v", a))
		}
		// What this document last wrote is no change, and a create-only
		// save now finds its own file.
		if err := os.Chdir(filepath.Join(x, saveCwd)); err != nil {
			t.Fatal(err)
		}
		_, again := doc.SaveFileWith(savePath, opts)
		if err := os.Chdir(base); err != nil {
			t.Fatal(err)
		}
		want := fsOk
		if c.create {
			want = fsExists
		}
		if fsClassify(again) != want {
			return keep(fmt.Sprintf("the second save gave %v", again))
		}
	} else if after := fsSnapshot(x); !reflect.DeepEqual(after, before) {
		return keep(fmt.Sprintf("refused as %v, but the tree changed:\n\tbefore %v\n\tafter %v", first, before, after))
	}
	fsRemoveTree(root)
	return ran, nil
}

// fsBaseDir is the folder the cases go in: SHCL_FS_DIR, or the temp folder
// with a note, never the project tree.
func fsBaseDir(t *testing.T, test string) string {
	t.Helper()
	parent := os.Getenv("SHCL_FS_DIR")
	if parent == "" {
		parent = os.TempDir()
		fmt.Fprintf(os.Stderr, "note: SHCL_FS_DIR is not set, so the filesystem cases go under %s\n", parent)
	}
	base := filepath.Join(parent, fmt.Sprintf("shcl-fs-go-%d-%s", os.Getpid(), test))
	fsRemoveTree(base)
	if err := os.MkdirAll(base, 0o755); err != nil {
		t.Fatal(err)
	}
	real, err := filepath.EvalSymlinks(base)
	if err != nil {
		t.Fatal(err)
	}
	return real
}

// fsDump writes the cases a test ran in fs/NAME.tsv under SHCL_FUZZ_DUMP, up
// to SHCL_FUZZ_DUMP_MAX lines.
func fsDump(t *testing.T, name string, lines []string) {
	t.Helper()
	dir := os.Getenv("SHCL_FUZZ_DUMP")
	if dir == "" {
		return
	}
	max := 5000
	if n, err := strconv.Atoi(strings.TrimSpace(os.Getenv("SHCL_FUZZ_DUMP_MAX"))); err == nil {
		max = n
	}
	if len(lines) > max {
		lines = lines[:max]
	}
	dir = filepath.Join(dir, "fs")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(l + "\n")
	}
	if err := os.WriteFile(filepath.Join(dir, name+".tsv"), []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}

func fsDumpLine(ran fsRan) string {
	if ran.skipped {
		return ran.line + "\tskipped"
	}
	same := 0
	if ran.same {
		same = 1
	}
	return fmt.Sprintf("%s\tsame=%d\t%s", ran.line, same, ran.got)
}

// fsBudgetSecs is SHCL_FS_SECS, 2 when unset. A value that isn't a count is a
// mistake, not a setting.
func fsBudgetSecs(t *testing.T) int {
	t.Helper()
	v, set := os.LookupEnv("SHCL_FS_SECS")
	if !set {
		return 2
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil || n < 0 {
		t.Fatalf("SHCL_FS_SECS is not a count: %q", v)
	}
	return n
}

type fsRow struct {
	id string
	// only is the row's own platform where its spellings don't say, for an
	// item whose bug was on one platform only.
	only       string
	t, o       bool
	load, save string
	events     []string
	create     bool
	expected   fsOutcome
}

// fsRows is one row per past bug of the class, each a case the generator can
// draw. 2026110313211991 was the CLIs' own check; its library twin is the FIFO
// row.
var fsRows = []fsRow{
	{"2026102910482342", "any", true, false, "bare", "bare", []string{"write-load"}, false, fsChanged},
	{"2026110312163201-gone", "any", true, false, "bare", "dot", []string{"remove-load"}, false, fsOk},
	{"2026110312163201-made", "any", false, false, "bare", "bare", []string{"write-load"}, false, fsChanged},
	{"2026110312163201-abs", "any", true, false, "dot", "abs", []string{"write-load"}, false, fsChanged},
	{"2026110312163202-fifo", "any", true, false, "dot", "dot", []string{"fifo-load"}, false, fsNotRegular},
	{"2026110312163202-unread", "any", true, false, "dot", "dot", []string{"write-load", "unread"}, false, fsChanged},
	{"2026110312163207", "any", false, false, "dangle", "dangle", []string{"none"}, true, fsExists},
	{"2026110314064292", "any", false, false, "bare", "nodir", []string{"none"}, false, fsIo},
	{"2026110314240418", "any", false, false, "nddot", "nd", []string{"mkdir", "write-load"}, false, fsChanged},
	{"2026110408432594-link", "windows", false, false, "dangle", "dangle", []string{"none"}, true, fsExists},
	{"2026110408432594-dot", "windows", false, false, "nddot", "nd", []string{"mkdir", "write-load"}, false, fsChanged},
	{"2026110613470307", "any", false, false, "nodir", "nodir", []string{"mkdir", "write-save"}, false, fsChanged},
	{"2026110613470307-otherwd", "any", true, true, "bare", "bare", []string{"chdir"}, false, fsChanged},
	{"2026110613470307-case", "macos", true, false, "case", "bare", []string{"write-load"}, false, fsChanged},
	{"2026110613470308-trail", "any", true, false, "bare", "trail", []string{"none"}, false, fsIsDirectory},
	{"2026110613470308-dot", "any", true, false, "bare", "traildot", []string{"none"}, true, fsIsDirectory},
	{"2026110613470308-swap", "any", true, false, "bare", "bare", []string{"dir-load"}, false, fsIsDirectory},
}

func fsIndex(t *testing.T, rules []fsRule, name string) int {
	t.Helper()
	for i, r := range rules {
		if r.name == name {
			return i
		}
	}
	t.Fatalf("fs-rules.tsv has no %q, which a fixed row names", name)
	return -1
}

// fsEnter keeps the working folder for the test's end, since the cases change
// it.
func fsEnter(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the Windows rows wait for b29w (2026111019505861)")
	}
	back, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(back) })
}

// Every past bug of the class, as a fixed row the generator can draw too.
func TestTheSaveChecksHoldOnEveryPastPathBug(t *testing.T) {
	defer testID(t, "df4c4")
	r := fsReadRules(t)
	fsEnter(t)
	base := fsBaseDir(t, "rows")
	var lines, failed []string
	for _, row := range fsRows {
		c := fsCase{tThere: row.t, oThere: row.o, load: fsIndex(t, r.spells, row.load), save: fsIndex(t, r.spells, row.save), create: row.create}
		for _, e := range row.events {
			c.events = append(c.events, fsIndex(t, r.events, e))
		}
		if !fsOnThisOS(row.only) {
			lines = append(lines, "row:"+row.id+"\tskipped")
			continue
		}
		// Every row runs, so one red run names each past bug that's back.
		ran, err := fsRunCase(t, r, base, "row:"+row.id, c)
		if err != nil {
			failed = append(failed, err.Error())
			continue
		}
		lines = append(lines, fsDumpLine(ran))
		if !ran.skipped && ran.expected != row.expected {
			failed = append(failed, fmt.Sprintf("%s: the oracle says %s, the row %s", ran.line, ran.expected, row.expected))
		}
	}
	fsDump(t, "go-rows", lines)
	if len(failed) > 0 {
		t.Fatal(strings.Join(failed, "\n"))
	}
	fsRemoveTree(base)
}

// Cases drawn by seed for the budget. Each case is a pure function of its
// seed, so a failure replays from the seed in its message. A run that never
// drew each spelling, event, answer, and both one file and 2, fails, since it
// didn't test what it says.
func TestTheSaveChecksHoldOnDrawnPathsAndEvents(t *testing.T) {
	defer testID(t, "df4c5")
	r := fsReadRules(t)
	fsEnter(t)
	base := fsBaseDir(t, "drawn")
	if v, set := os.LookupEnv("SHCL_FS_SEED"); set {
		seed, err := strconv.ParseUint(strings.TrimSpace(v), 10, 64)
		if err != nil {
			t.Fatalf("SHCL_FS_SEED is not a seed: %q", v)
		}
		ran, err := fsRunCase(t, r, base, fmt.Sprintf("seed:%d", seed), fsDraw(r, seed))
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintln(os.Stderr, fsDumpLine(ran))
		fsRemoveTree(base)
		return
	}
	until := time.Now().Add(time.Duration(fsBudgetSecs(t)) * time.Second)
	spells := map[int]bool{}
	events := map[int]bool{}
	outcomes := map[fsOutcome]bool{}
	sames := map[bool]bool{}
	var lines []string
	seed := uint64(0)
	for seed < fsMinCases || time.Now().Before(until) {
		c := fsDraw(r, seed)
		ran, err := fsRunCase(t, r, base, fmt.Sprintf("seed:%d", seed), c)
		if err != nil {
			t.Fatal(err)
		}
		lines = append(lines, fsDumpLine(ran))
		if !ran.skipped {
			spells[c.load] = true
			spells[c.save] = true
			for _, e := range c.events {
				events[e] = true
			}
			outcomes[ran.got] = true
			sames[ran.same] = true
		}
		seed++
	}
	fsDump(t, "go-drawn", lines)
	for i, s := range r.spells {
		if fsOnThisOS(s.os) && !spells[i] {
			t.Errorf("%d cases never drew the spelling %s", seed, s.name)
		}
	}
	for i, e := range r.events {
		if fsOnThisOS(e.os) && !events[i] {
			t.Errorf("%d cases never drew the event %s", seed, e.name)
		}
	}
	for _, o := range fsOutcomes {
		if !outcomes[o] {
			t.Errorf("%d cases never gave %s", seed, o)
		}
	}
	if len(sames) != 2 {
		t.Errorf("%d cases never gave both one file and 2", seed)
	}
	fsRemoveTree(base)
}
