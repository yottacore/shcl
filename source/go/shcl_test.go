// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

// Conformance-corpus runner. Every shipped binding must pass this corpus; the
// Go binding runs it natively here. Case layout and reads.tsv column meanings
// are documented in project/conformance/README.md.

package shcl

import (
	"errors"
	"fmt"
	"io/fs"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func corpusDir() string {
	return filepath.Join("..", "..", "project", "conformance")
}

// tsvEscape gives the TSV-safe form: real newlines/tabs in a value are
// written \n / \t.
func tsvEscape(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, "\n", "\\n"), "\t", "\\t")
}

func parseLevel(t *testing.T, s string) Strictness {
	switch s {
	case "", "standard":
		return Standard
	case "loose":
		return Loose
	case "strict":
		return Strict
	}
	t.Fatalf("unknown level '%s' in reads.tsv", s)
	return Standard
}

type corpusCase struct {
	name        string
	id          string // the case's test ID, from its test-id file
	input       string
	expectedFmt string
	reads       string
	// Golden `check` stdout at Standard: diag lines (line/severity/code) + summary.
	expectedDiags string
	// Write dimension (optional): an ops script and its golden canonical output.
	writeOps      string
	expectedWrite string
	hasWrite      bool
	// The same ops through the save that keeps lines.
	expectedKeep string
	// Bad-op dimension (optional): ops that must each be rejected, applied alone.
	writeBadOps string
	hasWriteBad bool
	// Schema dimension (optional): a schema and the golden `check --schema` stdout.
	schema           string
	expectedValidate string
	hasSchema        bool
	// Layered-load dimension (optional): lower-priority layer files (in filename
	// order), optional `path=value` overrides, and the golden merged canonical.
	layers         []string
	mergeSets      string
	expectedMerged string
	hasMerge       bool
	// Generation dimension (optional): a schema and the golden `init` output.
	initSchema   string
	expectedInit string
	hasInit      bool
	// Migration dimension (optional): the golden `migrate` output of the input
	// and the load diagnostics of that output.
	expectedMigrate      string
	expectedMigrateDiags string
	hasMigrate           bool
}

func loadCases(t *testing.T) []corpusCase {
	dir := corpusDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("corpus dir %s: %v", dir, err)
	}
	var cases []corpusCase
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		caseDir := filepath.Join(dir, entry.Name())
		// A case directory with no input.shcl is a mistake, not a non-case: it
		// used to be skipped without a word while check-docs still wanted its
		// README note, so the case read as present and asserted nothing.
		input, err := os.ReadFile(filepath.Join(caseDir, "input.shcl"))
		if err != nil {
			t.Fatalf("%s: %v", entry.Name(), err)
		}
		expected, err := os.ReadFile(filepath.Join(caseDir, "expected.shcl"))
		if err != nil {
			t.Fatalf("%s: %v", entry.Name(), err)
		}
		reads, err := os.ReadFile(filepath.Join(caseDir, "reads.tsv"))
		if err != nil {
			t.Fatalf("%s: %v", entry.Name(), err)
		}
		diags, err := os.ReadFile(filepath.Join(caseDir, "expected-diags.txt"))
		if err != nil {
			t.Fatalf("%s: %v", entry.Name(), err)
		}
		id := "-------"
		if b, err := os.ReadFile(filepath.Join(caseDir, "test-id")); err == nil {
			id = strings.TrimSpace(string(b))
		}
		cc := corpusCase{
			name:          entry.Name(),
			id:            id,
			input:         string(input),
			expectedFmt:   string(expected),
			reads:         string(reads),
			expectedDiags: string(diags),
		}
		ops, errOps := os.ReadFile(filepath.Join(caseDir, "write.ops"))
		ew, errWrite := os.ReadFile(filepath.Join(caseDir, "expected-write.shcl"))
		ek, errKeep := os.ReadFile(filepath.Join(caseDir, "expected-keep.shcl"))
		if (errOps == nil) != (errWrite == nil) || (errOps == nil) != (errKeep == nil) {
			t.Fatalf("%s: write.ops, expected-write.shcl and expected-keep.shcl come together", entry.Name())
		}
		if errOps == nil {
			cc.writeOps, cc.expectedWrite, cc.expectedKeep, cc.hasWrite = string(ops), string(ew), string(ek), true
		}
		if bad, err := os.ReadFile(filepath.Join(caseDir, "write-bad.ops")); err == nil {
			cc.writeBadOps, cc.hasWriteBad = string(bad), true
		}
		if sch, err := os.ReadFile(filepath.Join(caseDir, "schema.shcl")); err == nil {
			ev, err2 := os.ReadFile(filepath.Join(caseDir, "expected-validate.txt"))
			if err2 != nil {
				t.Fatalf("%s: schema.shcl without expected-validate.txt", entry.Name())
			}
			cc.schema, cc.expectedValidate, cc.hasSchema = string(sch), string(ev), true
		}
		if em, err := os.ReadFile(filepath.Join(caseDir, "expected-merged.shcl")); err == nil {
			// Layer files: every layer*.shcl, in filename (= priority) order.
			// The directory was just read for the case files, so a failure here
			// would mean it vanished mid-run; the case then has no layers and
			// the merge assertion below reports it.
			dirEntries, _ := os.ReadDir(caseDir)
			var layerNames []string
			for _, de := range dirEntries {
				n := de.Name()
				if strings.HasPrefix(n, "layer") && strings.HasSuffix(n, ".shcl") {
					layerNames = append(layerNames, n)
				}
			}
			sort.Strings(layerNames)
			for _, n := range layerNames {
				lb, lerr := os.ReadFile(filepath.Join(caseDir, n))
				if lerr != nil {
					t.Fatalf("%s: %v", entry.Name(), lerr)
				}
				cc.layers = append(cc.layers, string(lb))
			}
			if ms, err2 := os.ReadFile(filepath.Join(caseDir, "merge.sets")); err2 == nil {
				cc.mergeSets = string(ms)
			}
			cc.expectedMerged, cc.hasMerge = string(em), true
		}
		if is, err := os.ReadFile(filepath.Join(caseDir, "init-schema.shcl")); err == nil {
			ei, err2 := os.ReadFile(filepath.Join(caseDir, "expected-init.shcl"))
			if err2 != nil {
				t.Fatalf("%s: init-schema.shcl without expected-init.shcl", entry.Name())
			}
			cc.initSchema, cc.expectedInit, cc.hasInit = string(is), string(ei), true
		}
		em, emErr := os.ReadFile(filepath.Join(caseDir, "expected-migrate.shcl"))
		emd, emdErr := os.ReadFile(filepath.Join(caseDir, "expected-migrate-diags.txt"))
		if (emErr == nil) != (emdErr == nil) {
			t.Fatalf("%s: expected-migrate.shcl and expected-migrate-diags.txt must come as a pair", entry.Name())
		}
		if emErr == nil {
			cc.expectedMigrate, cc.expectedMigrateDiags, cc.hasMigrate = string(em), string(emd), true
		}
		cases = append(cases, cc)
	}
	sort.Slice(cases, func(i, j int) bool { return cases[i].name < cases[j].name })
	if len(cases) == 0 {
		t.Fatalf("no corpus cases found under %s", dir)
	}
	return cases
}

// testID prints the test's status line with its test ID. Every test defers it
// first thing, so it runs last and sees a failure, a skip or a panic.
func testID(t *testing.T, id string) {
	r := recover()
	status := "ok"
	if r != nil || t.Failed() {
		status = "FAIL"
	} else if t.Skipped() {
		status = "skip"
	}
	statusLine(status, id, t.Name())
	if r != nil {
		panic(r)
	}
}

func statusLine(status, id, name string) {
	fmt.Printf("%-4s %s go %s\n", status, id, name)
}

// Every corpus case some test ran, in order, and the ones any test failed.
// TestMain prints a line for each after the run.
var (
	corpusRan    []corpusCase
	corpusFailed = map[string]bool{}
)

// eachCase runs check on every case as its own subtest, so one failing case
// leaves the rest checked.
func eachCase(t *testing.T, check func(t *testing.T, c corpusCase)) {
	cases := loadCases(t)
	if corpusRan == nil {
		corpusRan = cases
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			defer func() {
				if t.Failed() {
					corpusFailed[c.name] = true
				}
			}()
			check(t, c)
		})
	}
}

func TestMain(m *testing.M) {
	code := m.Run()
	for _, c := range corpusRan {
		status := "ok"
		if corpusFailed[c.name] {
			status = "FAIL"
		}
		statusLine(status, c.id, "corpus/"+c.name)
	}
	os.Exit(code)
}

// unitType splits a `duration[@UNIT]` or `size[@UNIT][+decimal]` row type:
// the read, the unit a bare number takes, and whether KB to TB are powers of
// 1000.
func unitType(kind string) (string, string, bool) {
	rest, decimal := strings.CutSuffix(kind, "+decimal")
	base, unit, _ := strings.Cut(rest, "@")
	return base, unit, decimal
}

func docFor(t *testing.T, c *corpusCase, level Strictness) *Document {
	doc, err := ParseWith(c.input, level)
	if err != nil {
		t.Fatalf("%s: load failed at level %d but reads.tsv has reads there: %v", c.name, level, err)
	}
	return doc
}

func TestCanonicalFormatMatchesExpected(t *testing.T) {
	defer testID(t, "EjsS8bA")
	eachCase(t, func(t *testing.T, c corpusCase) {
		got := Parse(c.input).ToCanonical()
		if got != c.expectedFmt {
			t.Errorf("%s: canonical output differs from expected.shcl\ngot:\n%s\nwant:\n%s", c.name, got, c.expectedFmt)
			return
		}
		// The formatter must be a fixpoint: canonicalizing its own output changes nothing.
		if again := Parse(got).ToCanonical(); again != got {
			t.Errorf("%s: formatter is not idempotent", c.name)
		}
	})
}

// opTextTest resolves an ops value's escapes with the file's reader; a
// backslash is text (mirrors the CLI's opText).
func opTextTest(s string) (string, error) {
	if !strings.Contains(s, "◉") {
		return s, nil
	}
	var text string
	if strings.Contains(s, `"`) && !strings.Contains(s, "'") {
		text = "v: '" + s + "'\n"
	} else {
		text = "v: \"" + strings.ReplaceAll(s, `"`, "◉DOUBLE_QUOTE◉") + "\"\n"
	}
	doc := Parse(text)
	for _, d := range doc.Diagnostics() {
		if d.Severity == SeverityError {
			return "", errors.New(d.Message)
		}
	}
	return doc.ReadString("v").Value, nil
}

// Value gates mirror the CLI's exactly: grammar first (reference FromStr
// shape), then range; float overflow yields +/-Inf, not an error.
func intGrammarTest(s string) bool {
	if s != "" && (s[0] == '+' || s[0] == '-') {
		s = s[1:]
	}
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func floatGrammarTest(s string) bool {
	if s != "" && (s[0] == '+' || s[0] == '-') {
		s = s[1:]
	}
	if s == "" {
		return false
	}
	low := strings.ToLower(s)
	if low == "inf" || low == "infinity" || low == "nan" {
		return true
	}
	i := 0
	digits := func() int {
		n := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
			n++
		}
		return n
	}
	if digits() > 0 {
		if i < len(s) && s[i] == '.' {
			i++
			digits()
		}
	} else {
		if s[i] != '.' {
			return false
		}
		i++
		if digits() == 0 {
			return false
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		if digits() == 0 {
			return false
		}
	}
	return i == len(s)
}

// errUnknownOp is what an op name this runner does not have comes back as. A
// write-bad.ops row spelled wrong is a fixture mistake, and without telling it
// apart it counted as exactly the refusal the row exists to assert.
var errUnknownOp = errors.New("unknown op")

// tryApplyOpTest applies one write-ops line via the library Writer, with the
// same value gates the CLI applies. A non-nil error = the op must be rejected
// (bad value or unusable path).
func tryApplyOpTest(doc *Document, line string) error {
	f := strings.Split(line, "\t")
	get := func(i int) string {
		if i < len(f) {
			return f[i]
		}
		return ""
	}
	path, v := get(1), get(2)
	arr := []string{}
	if len(f) > 2 {
		arr = f[2:]
	}
	pint := func(s string) (int64, error) {
		if !intGrammarTest(s) {
			return 0, fmt.Errorf("bad int: %s", s)
		}
		n, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			return 0, fmt.Errorf("bad int: %s", s)
		}
		return n, nil
	}
	pflt := func(s string) (float64, error) {
		if !floatGrammarTest(s) {
			return 0, fmt.Errorf("bad float: %s", s)
		}
		n, err := strconv.ParseFloat(s, 64)
		if err != nil || math.IsInf(n, 0) || math.IsNaN(n) {
			return 0, fmt.Errorf("bad float: %s", s)
		}
		return n, nil
	}
	ints := func(xs []string) ([]int64, error) {
		o := make([]int64, len(xs))
		for i, s := range xs {
			n, err := pint(s)
			if err != nil {
				return nil, err
			}
			o[i] = n
		}
		return o, nil
	}
	flts := func(xs []string) ([]float64, error) {
		o := make([]float64, len(xs))
		for i, s := range xs {
			n, err := pflt(s)
			if err != nil {
				return nil, err
			}
			o[i] = n
		}
		return o, nil
	}
	pbool := func(s string) (bool, error) {
		switch s {
		case "true":
			return true, nil
		case "false":
			return false, nil
		}
		return false, fmt.Errorf("bad bool: %s", s)
	}
	bools := func(xs []string) ([]bool, error) {
		o := make([]bool, len(xs))
		for i, s := range xs {
			b, err := pbool(s)
			if err != nil {
				return nil, err
			}
			o[i] = b
		}
		return o, nil
	}
	strs := func(xs []string) ([]string, error) {
		o := make([]string, len(xs))
		for i, s := range xs {
			t, err := opTextTest(s)
			if err != nil {
				return nil, err
			}
			o[i] = t
		}
		return o, nil
	}
	dt := func(s string) (DateTime, error) {
		x, ok := ParseDateTime(s)
		if !ok {
			return x, fmt.Errorf("bad datetime: %s", s)
		}
		return x, nil
	}
	dts := func(xs []string) ([]DateTime, error) {
		o := make([]DateTime, len(xs))
		for i, s := range xs {
			x, err := dt(s)
			if err != nil {
				return nil, err
			}
			o[i] = x
		}
		return o, nil
	}
	wrote := SetOk
	switch f[0] {
	case "int":
		n, err := pint(v)
		if err != nil {
			return err
		}
		wrote = doc.SetInt(path, n)
	case "float":
		n, err := pflt(v)
		if err != nil {
			return err
		}
		wrote = doc.SetFloat(path, n)
	case "bool":
		b, err := pbool(v)
		if err != nil {
			return err
		}
		wrote = doc.SetBool(path, b)
	case "string":
		t, err := opTextTest(v)
		if err != nil {
			return err
		}
		wrote = doc.SetString(path, t)
	case "datetime":
		x, err := dt(v)
		if err != nil {
			return err
		}
		wrote = doc.SetDateTime(path, x)
	case "literal":
		wrote = doc.SetLiteral(path, v)
	case "literal-default":
		wrote = doc.SetLiteralDefault(path, v)
	case "int-default":
		n, err := pint(v)
		if err != nil {
			return err
		}
		wrote = doc.SetIntDefault(path, n)
	case "float-default":
		n, err := pflt(v)
		if err != nil {
			return err
		}
		wrote = doc.SetFloatDefault(path, n)
	case "bool-default":
		b, err := pbool(v)
		if err != nil {
			return err
		}
		wrote = doc.SetBoolDefault(path, b)
	case "string-default":
		t, err := opTextTest(v)
		if err != nil {
			return err
		}
		wrote = doc.SetStringDefault(path, t)
	case "datetime-default":
		x, err := dt(v)
		if err != nil {
			return err
		}
		wrote = doc.SetDateTimeDefault(path, x)
	case "int-array":
		xs, err := ints(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetIntArray(path, xs)
	case "float-array":
		xs, err := flts(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetFloatArray(path, xs)
	case "bool-array":
		xs, err := bools(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetBoolArray(path, xs)
	case "string-array":
		xs, err := strs(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetStringArray(path, xs)
	case "datetime-array":
		xs, err := dts(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetDateTimeArray(path, xs)
	case "int-array-default":
		xs, err := ints(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetIntArrayDefault(path, xs)
	case "float-array-default":
		xs, err := flts(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetFloatArrayDefault(path, xs)
	case "bool-array-default":
		xs, err := bools(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetBoolArrayDefault(path, xs)
	case "string-array-default":
		xs, err := strs(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetStringArrayDefault(path, xs)
	case "datetime-array-default":
		xs, err := dts(arr)
		if err != nil {
			return err
		}
		wrote = doc.SetDateTimeArrayDefault(path, xs)
	case "raw":
		t, err := opTextTest(get(3))
		if err != nil {
			return err
		}
		wrote = doc.SetRaw(path, t, v)
	case "raw-default":
		t, err := opTextTest(get(3))
		if err != nil {
			return err
		}
		wrote = doc.SetRawDefault(path, t, v)
	case "empty":
		wrote = doc.SetEmpty(path)
	case "comment":
		t, err := opTextTest(v)
		if err != nil {
			return err
		}
		wrote = doc.SetComment(path, t)
	case "remove":
		doc.Remove(path)
		wrote = SetOk
	case "clear-comments":
		doc.ClearComments(path)
		wrote = SetOk
	case "banner":
		if path != "on" && path != "off" {
			return fmt.Errorf("bad banner: %s", path)
		}
		doc.SetBanner(path == "on")
		wrote = SetOk
	default:
		return fmt.Errorf("%w: %s", errUnknownOp, f[0])
	}
	if wrote != SetOk {
		return fmt.Errorf("cannot write %s: %v", path, wrote)
	}
	return nil
}

// applyOpTest is the good-path wrapper: the op must apply.
func applyOpTest(t *testing.T, doc *Document, line, at string) {
	if err := tryApplyOpTest(doc, line); err != nil {
		t.Fatalf("%s: %s", at, err)
	}
}

// diagText is the load diagnostics of text at Standard, written the way
// `check` prints them: one line per diagnostic, then the summary.
func diagText(text string) string {
	diags := Parse(text).Diagnostics()
	var got strings.Builder
	errors := 0
	for _, d := range diags {
		fmt.Fprintf(&got, "line %d: %s: %s\n", d.Line, d.Severity, d.Code)
		if d.Severity == SeverityError {
			errors++
		}
	}
	if errors > 0 {
		fmt.Fprintf(&got, "failed: %d diagnostic(s), %d error(s)\n", len(diags), errors)
	} else {
		fmt.Fprintf(&got, "ok (%d diagnostic(s))\n", len(diags))
	}
	return got.String()
}

func TestDiagnosticsMatchExpected(t *testing.T) {
	defer testID(t, "EkoN15t")
	// Pins count, line, severity, and stable code per case - the same shape
	// `check` prints to stdout at Standard (its cross-binding contract).
	eachCase(t, func(t *testing.T, c corpusCase) {
		got := diagText(c.input)
		if got != c.expectedDiags {
			t.Errorf("%s: diagnostics differ from expected-diags.txt\ngot:\n%s\nwant:\n%s", c.name, got, c.expectedDiags)
		}
	})
}

func TestMigrateMatchesExpected(t *testing.T) {
	defer testID(t, "Ept4WPi")
	// Migration dimension: Migrate on the input must reproduce the golden byte
	// for byte, and the golden's load diagnostics are pinned beside it, so a
	// rewrite that no longer loads cannot pass. A fmt fixpoint is not required,
	// since migrate keeps the author's layout; the migrate fixpoint is checked
	// next.
	eachCase(t, func(t *testing.T, c corpusCase) {
		if !c.hasMigrate {
			return
		}
		got := Migrate(c.input, true).Text
		if got != c.expectedMigrate {
			t.Errorf("%s: migrate output differs from expected-migrate.shcl\ngot:\n%s\nwant:\n%s", c.name, got, c.expectedMigrate)
		}
		if d := diagText(got); d != c.expectedMigrateDiags {
			t.Errorf("%s: migrated text's diagnostics differ from expected-migrate-diags.txt\ngot:\n%s\nwant:\n%s", c.name, d, c.expectedMigrateDiags)
		}
	})
}

func TestMigrateIsAFixpoint(t *testing.T) {
	defer testID(t, "EpyXoJX")
	eachCase(t, func(t *testing.T, c corpusCase) {
		once := Migrate(c.input, true).Text
		if again := Migrate(once, true).Text; again != once {
			t.Errorf("%s: migrate changes its own output\ngot:\n%s\nwant:\n%s", c.name, again, once)
		}
	})
}

func TestMigrateUnstampedIsMigrateWithoutTheStamp(t *testing.T) {
	defer testID(t, "Eqpzw7U")
	// Over every input, not only the migrate cases: the stamp is the one
	// difference, and a file is current exactly when its Format line says so.
	eachCase(t, func(t *testing.T, c corpusCase) {
		for _, fromV2 := range []bool{true, false} {
			full := Migrate(c.input, fromV2)
			bare := MigrateUnstamped(c.input, fromV2)
			if bare.Current != full.Current || bare.Ambiguous != full.Ambiguous || bare.Lost != full.Lost {
				t.Errorf("%s: counts differ without the stamp", c.name)
			}
			if strings.Contains(bare.Text, FormatLineHead) && !strings.Contains(c.input, FormatLineHead) {
				t.Errorf("%s: MigrateUnstamped wrote a Format line", c.name)
			}
			// The stamp's lines end the way most of the input's lines do.
			eol := "\n"
			if crlf := strings.Count(c.input, "\r\n"); crlf > strings.Count(c.input, "\n")-crlf {
				eol = "\r\n"
			}
			want := bare.Text
			if !full.Current && full.Text != bare.Text {
				if want != "" && !strings.HasSuffix(want, "\n") {
					want += eol
				}
				want += FormatLine + eol
				if bare.Text != c.input {
					want += MigratedLine + eol
				}
			}
			if full.Text != want {
				t.Errorf("%s: the stamp is not the only difference", c.name)
			}
			v, ok := FormatVersion(c.input)
			if full.Current != (ok && v >= FormatMajor) {
				t.Errorf("%s: current disagrees with FormatVersion", c.name)
			}
		}
	})
}

func TestValidationMatchesExpected(t *testing.T) {
	defer testID(t, "Eksumuu")
	// Schema dimension: golden = the exact `check --schema` stdout at Standard
	// (doc parse diags, then validation diags, then the summary). A schema that
	// does not load cleanly is a single V099, mirroring the CLI. It comes from
	// Validate itself, and LoadAndValidate has to give the same list, so every
	// entry point is held to the one golden.
	eachCase(t, func(t *testing.T, c corpusCase) {
		if !c.hasSchema {
			return
		}
		doc := Parse(c.input)
		diags := append([]Diagnostic{}, doc.Diagnostics()...)
		sdoc := Parse(c.schema)
		diags = append(diags, doc.Validate(sdoc)...)
		bad := false
		for _, sd := range sdoc.Diagnostics() {
			if sd.Severity == SeverityError {
				bad = true
			}
		}
		if !bad {
			diags = SuppressDeclaredRepeats(sdoc, diags)
			diags = SuppressDeclaredReopens(sdoc, diags)
		}
		var got strings.Builder
		errors := 0
		for _, d := range diags {
			fmt.Fprintf(&got, "line %d: %s: %s\n", d.Line, d.Severity, d.Code)
			if d.Severity == SeverityError {
				errors++
			}
		}
		var lv strings.Builder
		for _, d := range lvStandard(t, c.input, c.schema).Diagnostics() {
			fmt.Fprintf(&lv, "line %d: %s: %s\n", d.Line, d.Severity, d.Code)
		}
		if lv.String() != got.String() {
			t.Errorf("%s: LoadAndValidate disagrees with parse then validate\ngot:\n%s\nwant:\n%s", c.name, lv.String(), got.String())
		}
		if errors > 0 {
			fmt.Fprintf(&got, "failed: %d diagnostic(s), %d error(s)\n", len(diags), errors)
		} else {
			fmt.Fprintf(&got, "ok (%d diagnostic(s))\n", len(diags))
		}
		if got.String() != c.expectedValidate {
			t.Errorf("%s: validation output differs from expected-validate.txt\ngot:\n%s\nwant:\n%s", c.name, got.String(), c.expectedValidate)
		}
	})
}

func TestWriteOpsMatchExpected(t *testing.T) {
	defer testID(t, "Ekfzh7h")
	eachCase(t, func(t *testing.T, c corpusCase) {
		if !c.hasWrite {
			return
		}
		// The one that keeps lines is the same document.
		doc := Parse(c.input)
		kept, err := ParseKeepLines(c.input, Standard)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		for n, line := range strings.Split(c.writeOps, "\n") {
			line = strings.TrimSuffix(line, "\r")
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			at := fmt.Sprintf("%s: write.ops line %d", c.name, n+1)
			applyOpTest(t, doc, line, at)
			applyOpTest(t, kept, line, at)
		}
		got := doc.ToCanonical()
		text, lines := kept.ToTextKeepLines()
		if text != c.expectedKeep {
			t.Errorf("%s: output differs from expected-keep.shcl\ngot:\n%s\nwant:\n%s", c.name, text, c.expectedKeep)
		}
		if !lines && text != got {
			t.Errorf("%s: a save that kept no lines is not canonical", c.name)
		}
		if Parse(text).ToCanonical() != got {
			t.Errorf("%s: expected-keep.shcl reloads as another document", c.name)
		}
		if got != c.expectedWrite {
			t.Errorf("%s: writer output differs from expected-write.shcl\ngot:\n%s\nwant:\n%s", c.name, got, c.expectedWrite)
			return
		}
		if again := Parse(got).ToCanonical(); again != got {
			t.Errorf("%s: written output is not a fmt fixpoint", c.name)
		}
	})
}

// TestKeepingLinesWithoutEditsWritesTheInput: loaded to keep its lines and
// saved with no edits, every input is its own text again, byte for byte.
func TestKeepingLinesWithoutEditsWritesTheInput(t *testing.T) {
	defer testID(t, "EqvA7Zo")
	eachCase(t, func(t *testing.T, c corpusCase) {
		doc, _ := ParseKeepLines(c.input, Standard)
		if text, kept := doc.ToTextKeepLines(); text != c.input || !kept {
			t.Errorf("%s: an unedited save changed the text", c.name)
		}
	})
}

func TestWriteBadOpsAreRejected(t *testing.T) {
	defer testID(t, "El5Gcy7")
	// Bad-op dimension: each write-bad.ops line, applied alone to the case
	// input, must be rejected (bad value, bad datetime, or unusable path) and
	// leave the document unchanged.
	// The names-no-op guard below is only worth something while a misspelled
	// op still comes back told apart from an ordinary refusal.
	probe := Parse("a: 1\n")
	if err := tryApplyOpTest(probe, "itn\ta\t1"); !errors.Is(err, errUnknownOp) {
		t.Errorf("a misspelled op read as a refusal: %v", err)
	}
	if err := tryApplyOpTest(probe, "int\ta\tx"); err == nil || errors.Is(err, errUnknownOp) {
		t.Errorf("a refusal read as a misspelled op: %v", err)
	}
	eachCase(t, func(t *testing.T, c corpusCase) {
		if !c.hasWriteBad {
			return
		}
		for n, line := range strings.Split(c.writeBadOps, "\n") {
			line = strings.TrimSuffix(line, "\r")
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			doc := Parse(c.input)
			before := doc.ToCanonical()
			switch err := tryApplyOpTest(doc, line); {
			case err == nil:
				t.Errorf("%s: write-bad.ops line %d was accepted: %s", c.name, n+1, line)
				continue
			case errors.Is(err, errUnknownOp):
				t.Errorf("%s: write-bad.ops line %d names no op: %s", c.name, n+1, line)
				continue
			}
			if got := doc.ToCanonical(); got != before {
				t.Errorf("%s: write-bad.ops line %d changed the document: %s", c.name, n+1, line)
			}
		}
	})
}

// lvStandard is LoadAndValidate at Standard, which never errs.
func lvStandard(t *testing.T, text, schema string) *Document {
	t.Helper()
	doc, err := LoadAndValidate(text, schema, Standard)
	if err != nil {
		t.Fatalf("LoadAndValidate at Standard: %v", err)
	}
	return doc
}

func TestOneShotLoadAndValidate(t *testing.T) {
	defer testID(t, "Elp3cOh")
	// One combined diagnostics list (parse first, then validation) and an
	// error predicate, so recover-and-continue can't read as success by
	// accident. Same fixture in every runner.
	text := ": nope\nport: x\n"
	schema := "field: port\n\ttype: int\n"
	doc := lvStandard(t, text, schema)
	var codes []string
	for _, d := range doc.Diagnostics() {
		codes = append(codes, d.Code)
	}
	if strings.Join(codes, ",") != "E014,V003" {
		t.Errorf("codes: got %v, want [E014 V003]", codes)
	}
	if got := doc.ErrorCount(); got != 2 {
		t.Errorf("error count: got %d, want 2", got)
	}
	if got := doc.ReadString("port").Value; got != "x" { // doc still usable
		t.Errorf("port: got %q, want \"x\"", got)
	}
	// Commented out 2026-10-08: Strict fails here as it does in ParseWith
	// (2026100717500012); TestStrictFailsTheSameFromEveryEntryPoint has it.
	// // Strict never errors out here; the diagnostics are the answer.
	// strict := LoadAndValidate(text, schema, Strict)
	// if strict.ErrorCount() < 2 {
	// 	t.Errorf("strict error count: got %d, want >= 2", strict.ErrorCount())
	// }
	strict, err := LoadAndValidate(text, schema, Strict)
	if err == nil || strict.ErrorCount() != 2 {
		t.Errorf("strict: got err %v, %d errors, want a LoadError and 2", err, strict.ErrorCount())
	}
	// An empty schema declares nothing and validates nothing.
	plain := lvStandard(t, "a: 1\n", "")
	if plain.ErrorCount() != 0 || len(plain.Diagnostics()) != 0 {
		t.Errorf("plain: got %d errors, %d diags, want 0, 0", plain.ErrorCount(), len(plain.Diagnostics()))
	}
}

func TestStrictFailsTheSameFromEveryEntryPoint(t *testing.T) {
	defer testID(t, "Es9mP4v")
	// Strict fails the load on any error diagnostic, from every entry point,
	// with the document beside the error. The file tier and the one-shot gave
	// a plain document where ParseWith failed. Same fixture in every runner.
	dir := t.TempDir()
	f := filepath.Join(dir, "t.shcl")
	text := ": nope\nport: 1\n"
	if err := os.WriteFile(f, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	schema := "field: port\n\ttype: int\n"
	type run struct {
		name string
		doc  *Document
		err  error
	}
	var runs []run
	add := func(name string, doc *Document, err error) { runs = append(runs, run{name, doc, err}) }
	doc, err := ParseWith(text, Strict)
	add("ParseWith", doc, err)
	doc, err = ParseLimited(text, Strict, 0, 0, 0)
	add("ParseLimited", doc, err)
	doc, err = ParseKeepLines(text, Strict)
	add("ParseKeepLines", doc, err)
	doc, err = LoadAndValidate(text, schema, Strict)
	add("LoadAndValidate", doc, err)
	doc, _, err = LoadFileWith(f, Strict)
	add("LoadFileWith", doc, err)
	doc, _, err = LoadFileKeepLines(f, Strict)
	add("LoadFileKeepLines", doc, err)
	for _, r := range runs {
		var le *LoadError
		if !errors.As(r.err, &le) {
			t.Errorf("%s: a strict load with an error gave %v, want a *LoadError", r.name, r.err)
			continue
		}
		if len(le.Diagnostics) != 1 || le.Diagnostics[0].Code != "E014" {
			t.Errorf("%s: diagnostics %v, want a lone E014", r.name, le.Diagnostics)
		}
		if v, st := le.Document.GetInt("port"); st != Good || v != 1 || r.doc != le.Document {
			t.Errorf("%s: the document does not come back", r.name)
		}
	}
	// A schema finding is an error in the same list, so it fails the
	// one-shot at Strict too.
	var le *LoadError
	if _, err := LoadAndValidate("port: x\n", schema, Strict); !errors.As(err, &le) || len(le.Diagnostics) != 1 || le.Diagnostics[0].Code != "V003" {
		t.Errorf("schema finding at Strict: got %v, want a LoadError with a lone V003", err)
	}
	// Below Strict nothing fails, and the file status says HadErrors.
	if _, err := ParseWith(text, Standard); err != nil {
		t.Errorf("ParseWith at Standard: %v", err)
	}
	if _, err := ParseLimited(text, Standard, 0, 0, 0); err != nil {
		t.Errorf("ParseLimited at Standard: %v", err)
	}
	if _, err := ParseKeepLines(text, Standard); err != nil {
		t.Errorf("ParseKeepLines at Standard: %v", err)
	}
	if d, err := LoadAndValidate(text, schema, Standard); err != nil || d.ErrorCount() != 1 {
		t.Errorf("LoadAndValidate at Standard: %v", err)
	}
	if _, st, err := LoadFileWith(f, Standard); err != nil || st != FileHadErrors {
		t.Errorf("LoadFileWith at Standard: %v, %v", st, err)
	}
	if _, st, err := LoadFileKeepLines(f, Standard); err != nil || st != FileHadErrors {
		t.Errorf("LoadFileKeepLines at Standard: %v, %v", st, err)
	}
	// A file that could not be read has no diagnostics, so Strict gives its
	// status like any other level.
	none := filepath.Join(dir, "none.shcl")
	if _, st, err := LoadFileWith(none, Strict); err != nil || st != FileNotFound {
		t.Errorf("LoadFileWith on a missing file: %v, %v", st, err)
	}
	if _, st, err := LoadFileKeepLines(none, Strict); err != nil || st != FileNotFound {
		t.Errorf("LoadFileKeepLines on a missing file: %v, %v", st, err)
	}
}

func TestOneShotLoadReportsABrokenSchema(t *testing.T) {
	defer testID(t, "Eqzz38W")
	// A schema that does not load would otherwise drop the constraints on its
	// broken lines, or report every field as unknown - blaming the document.
	// Same fixture in every runner.
	schema := "field: apikey\n\ttype: string\n  required: true\n"
	doc := lvStandard(t, "host: example\n", schema)
	ds := doc.Diagnostics()
	if len(ds) != 1 {
		t.Fatalf("expected only the schema fault, got %v", ds)
	}
	if ds[0].Code != "V099" {
		t.Errorf("code: got %s, want V099", ds[0].Code)
	}
	if got := doc.ErrorCount(); got != 1 {
		t.Errorf("error count: got %d, want 1", got)
	}
	// A schema that loads still validates normally.
	if got := lvStandard(t, "host: example\n", "field: host\n").ErrorCount(); got != 0 {
		t.Errorf("loading schema: got %d errors, want 0", got)
	}
	// An empty schema still means "skip validation", not "everything unknown".
	if got := lvStandard(t, "host: example\n", "").ErrorCount(); got != 0 {
		t.Errorf("empty schema: got %d errors, want 0", got)
	}
}

func TestValidateAndGenerateReportABrokenSchema(t *testing.T) {
	defer testID(t, "Es8Oq5C")
	// The quote never closes, so the max line is lost and a parse then
	// validate passed 99999 with no word. Same fixture in every runner.
	schema := Parse("field: port\n\ttype: int\n\tmax: \"65535\n")
	vs := Parse("port: 99999\n").Validate(schema)
	if len(vs) != 1 || vs[0].Code != "V099" || vs[0].Line != 0 || vs[0].Severity != SeverityError {
		t.Errorf("validate: got %v, want a lone V099", vs)
	}
	text, faults := Generate(schema, true)
	if text != "" || len(faults) != 1 || faults[0].Code != "V099" {
		t.Errorf("generate: got %q, %v, want a lone V099", text, faults)
	}
	// A document that came through LoadAndValidate holds V codes of its own,
	// and they are not load errors when it is used as a schema.
	checked := lvStandard(t, "field: port\n", "field: other\n")
	if ds := checked.Diagnostics(); len(ds) == 0 || ds[0].Code != "V001" {
		t.Fatalf("checked schema: got %v, want V001 first", ds)
	}
	if vs := Parse("port: 1\n").Validate(checked); len(vs) != 0 {
		t.Errorf("checked schema as a schema: got %v, want none", vs)
	}
}

func TestNulNameDoesNotSatisfyADottedSchemaPath(t *testing.T) {
	defer testID(t, "Eqzz38X")
	// The unknown-field chain key is length-prefixed, not NUL-joined: a single
	// field whose name literally contains a NUL must not impersonate the
	// two-segment path x.y. Same fixture in every runner.
	schema := Parse("field: x.y\n")
	doc := Parse("\"x\x00y\": 1\n")
	vs := doc.Validate(schema)
	if len(vs) != 1 {
		t.Fatalf("NUL-bearing name slipped past the sweep: %v", vs)
	}
	if vs[0].Code != "V001" {
		t.Errorf("code: got %s, want V001", vs[0].Code)
	}
	if !strings.HasPrefix(vs[0].Message, "unknown field ") {
		t.Errorf("message: got %q", vs[0].Message)
	}
	// The genuinely two-segment spelling still validates clean.
	if vs := Parse("x:\n\ty: 1\n").Validate(schema); len(vs) != 0 {
		t.Errorf("x.y: got %v, want none", vs)
	}
}

// A path the scanner refuses, or one with a value part, is BadPath on every
// read with a status, where a path that parses and finds nothing stays
// NotFound. The no-status calls give their empty answer and Or its default.
// Same fixture in every runner.
func TestBadPathReadsSayBadPath(t *testing.T) {
	defer testID(t, "Es9JVrY")
	doc := Parse("site: a\n\tport: 1\n")
	if st := doc.ReadInt("site(0).port").Status; st != Good {
		t.Fatalf("site(0).port: %v", st)
	}
	if st := doc.ReadInt("nope").Status; st != NotFound {
		t.Fatalf("nope: %v", st)
	}
	for _, p := range []string{"site[0].port", "site(.port", "site..port", "", "user name", "site.port: 1", "h:p"} {
		r := doc.ReadInt(p)
		if r.Status != BadPath || r.Value != 0 || r.Raw != nil {
			t.Errorf("ReadInt(%q) = %v %v %v", p, r.Status, r.Value, r.Raw)
		}
		sts := []Status{
			doc.ReadFloat(p).Status, doc.ReadBool(p).Status, doc.ReadString(p).Status,
			doc.ReadRaw(p).Status, doc.ReadRawInfo(p).Status, doc.ReadDateTime(p).Status,
			doc.ReadDuration(p, DurationNone).Status, doc.ReadSize(p, SizeNone, false).Status,
			doc.ReadFloatArray(p).Status, doc.ReadBoolArray(p).Status,
			doc.ReadStringArray(p).Status, doc.ReadDateTimeArray(p).Status,
		}
		for i, st := range sts {
			if st != BadPath {
				t.Errorf("read %d of %q: %v", i, p, st)
			}
		}
		if a := doc.ReadIntArray(p); a.Status != BadPath || len(a.Value) != 0 || len(a.Slots) != 0 {
			t.Errorf("ReadIntArray(%q) = %v %v %v", p, a.Status, a.Value, a.Slots)
		}
		if _, st := doc.GetInt(p); st != BadPath {
			t.Errorf("GetInt(%q): %v", p, st)
		}
		if _, st := doc.GetStringArray(p); st != BadPath {
			t.Errorf("GetStringArray(%q): %v", p, st)
		}
		if v := doc.GetIntOr(p, 8); v != 8 {
			t.Errorf("GetIntOr(%q) = %d", p, v)
		}
		if n := doc.Count(p); n != 0 {
			t.Errorf("Count(%q) = %d", p, n)
		}
		if v := doc.Instances(p); len(v) != 0 {
			t.Errorf("Instances(%q) = %v", p, v)
		}
		if v := doc.Children(p); p != "" && len(v) != 0 {
			t.Errorf("Children(%q) = %v", p, v)
		}
	}
	// The empty path is the top level for Children, as documented.
	if v := doc.Children(""); !reflect.DeepEqual(v, []string{"site"}) {
		t.Errorf("Children(\"\") = %v", v)
	}
	// Last in the order, so a worst-of aggregate puts it on top.
	if BadPath <= Multiple || BadPath.String() != "BadPath" {
		t.Errorf("BadPath order or name: %d %q", BadPath, BadPath.String())
	}
}

// The list reads' status twins: BadPath for a path that cannot be read,
// NotFound for one that matches nothing, Good otherwise, with the value the
// plain call gives. Same fixture in every runner.
func TestListReadsSayBadPath(t *testing.T) {
	defer testID(t, "EsDQqYe")
	doc := Parse("site: a\n\tport: 1\nsite: b\n")
	if c := doc.ReadCount("site"); c.Value != 2 || c.Status != Good || c.Line != 0 {
		t.Errorf("ReadCount(site) = %d %v %d", c.Value, c.Status, c.Line)
	}
	if c := doc.ReadCount("site(0)"); c.Value != 1 || c.Status != Good || c.Line != 1 {
		t.Errorf("ReadCount(site(0)) = %d %v %d", c.Value, c.Status, c.Line)
	}
	// An unresolved wildcard slot still counts, as in Count.
	if c := doc.ReadCount("site(*).port"); c.Value != 2 || c.Status != Good {
		t.Errorf("ReadCount(site(*).port) = %d %v", c.Value, c.Status)
	}
	if st := doc.ReadCount("nope").Status; st != NotFound {
		t.Errorf("ReadCount(nope): %v", st)
	}
	if st := doc.ReadCount("nope(*)").Status; st != NotFound {
		t.Errorf("ReadCount(nope(*)): %v", st)
	}
	if i := doc.ReadInstances("site"); !reflect.DeepEqual(i.Value, []string{"a", "b"}) || i.Status != Good {
		t.Errorf("ReadInstances(site) = %q %v", i.Value, i.Status)
	}
	if i := doc.ReadInstances("site(*).port"); !reflect.DeepEqual(i.Value, []string{"1", ""}) || i.Status != Good {
		t.Errorf("ReadInstances(site(*).port) = %q %v", i.Value, i.Status)
	}
	if st := doc.ReadInstances("nope").Status; st != NotFound {
		t.Errorf("ReadInstances(nope): %v", st)
	}
	if k := doc.ReadChildren("site(0)"); !reflect.DeepEqual(k.Value, []string{"port"}) || k.Status != Good || k.Line != 1 {
		t.Errorf("ReadChildren(site(0)) = %q %v %d", k.Value, k.Status, k.Line)
	}
	// An empty section is Good, a missing one NotFound.
	if k := doc.ReadChildren("site(1)"); len(k.Value) != 0 || k.Status != Good {
		t.Errorf("ReadChildren(site(1)) = %q %v", k.Value, k.Status)
	}
	if st := doc.ReadChildren("nope").Status; st != NotFound {
		t.Errorf("ReadChildren(nope): %v", st)
	}
	if k := doc.ReadChildren(""); strings.Join(k.Value, "|") != "site|site" || k.Status != Good {
		t.Errorf("ReadChildren(\"\") = %q %v", k.Value, k.Status)
	}
	for _, p := range []string{"site[0].port", "site(.port", "site..port", "", "user name", "site.port: 1", "h:p"} {
		if c := doc.ReadCount(p); c.Value != 0 || c.Status != BadPath || len(c.Slots) != 0 {
			t.Errorf("ReadCount(%q) = %d %v %v", p, c.Value, c.Status, c.Slots)
		}
		if i := doc.ReadInstances(p); len(i.Value) != 0 || i.Status != BadPath {
			t.Errorf("ReadInstances(%q) = %q %v", p, i.Value, i.Status)
		}
		if k := doc.ReadChildren(p); p != "" && (len(k.Value) != 0 || k.Status != BadPath) {
			t.Errorf("ReadChildren(%q) = %q %v", p, k.Value, k.Status)
		}
	}
}

func TestCheckSetPathNamesTheFailure(t *testing.T) {
	defer testID(t, "ElouJ8L")
	// The path's half of a setter's status. Same fixture in every runner.
	doc := Parse("a:\n\tb: 1\n")
	if got := doc.CheckSetPath("a.b"); got != SetOk {
		t.Errorf("a.b: got %v, want Ok", got)
	}
	if got := doc.CheckSetPath("a.new(Boston).x"); got != SetOk { // creatable
		t.Errorf("a.new(Boston).x: got %v, want Ok", got)
	}
	if got := doc.CheckSetPath(""); got != SetBadPath {
		t.Errorf("empty path: got %v, want BadPath", got)
	}
	if got := doc.CheckSetPath("a..b"); got != SetBadPath {
		t.Errorf("a..b: got %v, want BadPath", got)
	}
	if got := doc.CheckSetPath("a.b: 2"); got != SetValueInPath {
		t.Errorf("a.b: 2: got %v, want ValueInPath", got)
	}
	if got := doc.CheckSetPath("a(*).b"); got != SetWildcard {
		t.Errorf("a(*).b: got %v, want Wildcard", got)
	}
	if got := doc.CheckSetPath("a(5).b"); got != SetNoSuchIndex {
		t.Errorf("a(5).b: got %v, want NoSuchIndex", got)
	}
	if got := doc.CheckSetPath("nope(0).b"); got != SetNoSuchIndex {
		t.Errorf("nope(0).b: got %v, want NoSuchIndex", got)
	}
	deep := strings.TrimSuffix(strings.Repeat("d.", 513), ".")
	if got := doc.CheckSetPath(deep); got != SetTooDeep {
		t.Errorf("deep path: got %v, want TooDeep", got)
	}
	// A literal line break is writable wherever a path can have one: a name
	// emits through the name escaper and a selector value through the value
	// emitter, and both write a break \n and read it back as one. The selector
	// was refused while the value emitter still wrote elements in their source
	// spelling and had nothing to escape with. Not corpus-pinnable - an ops
	// line cannot contain a raw newline.
	if got := doc.CheckSetPath("a(\"p\nq\").b"); got != SetOk {
		t.Errorf("newline in selector: got %v, want Ok", got)
	}
	if got := doc.CheckSetPath("\"x\ny\".b"); got != SetOk {
		t.Errorf("newline in name: got %v, want Ok", got)
	}
	if got := doc.CheckSetPath("\"x\\ny\".b"); got != SetOk {
		t.Errorf("escaped newline in name: got %v, want Ok", got)
	}
	// The probe never creates: the doc is unchanged after all of the above.
	if n := doc.Count("a"); n != 1 {
		t.Errorf("count a: got %d, want 1", n)
	}
	if got := doc.Paths(); strings.Join(got, ",") != "a,a.b" {
		t.Errorf("paths: got %v", got)
	}
}

// The values a setter refuses on a path CheckSetPath passes. Each one here is
// refused, writes nothing, and the path checks SetOk. Same fixture in every
// runner, plus Go's own: text that is not valid UTF-8.
// TestSetterStatusNamesEachRefusal has the status each one gives.
func TestRefusedValuesPassThePathCheck(t *testing.T) {
	defer testID(t, "Es9S4kK")
	text := "ports: [80, 443]\nsec:\n\tx: 1\n"
	month13 := DateTime{HasDate: true, Year: 2026, Month: 13, Day: 1}
	cases := []struct {
		what, path string
		set        func(d *Document) SetStatus
	}{
		{"NaN float", "f", func(d *Document) SetStatus { return d.SetFloat("f", math.NaN()) }},
		{"infinite float", "f", func(d *Document) SetStatus { return d.SetFloat("f", math.Inf(1)) }},
		{"infinite float in an array", "f", func(d *Document) SetStatus { return d.SetFloatArray("f", []float64{1, math.Inf(-1)}) }},
		{"month 13", "t", func(d *Document) SetStatus { return d.SetDateTime("t", month13) }},
		{"raw info with #", "r", func(d *Document) SetStatus { return d.SetRaw("r", "body", "sh # x") }},
		{"raw info with a line break", "r", func(d *Document) SetStatus { return d.SetRaw("r", "body", "sh\nx") }},
		{"raw body line ending in CR", "r", func(d *Document) SetStatus { return d.SetRaw("r", "a\r\nb", "") }},
		{"comment with a line break", "sec.x", func(d *Document) SetStatus { return d.SetComment("sec.x", "a\nb") }},
		{"literal of two values", "l", func(d *Document) SetStatus { return d.SetLiteral("l", "a, b") }},
		{"literal with an open quote", "l", func(d *Document) SetStatus { return d.SetLiteral("l", "\"abc") }},
		{"literal with a line break", "l", func(d *Document) SetStatus { return d.SetLiteral("l", "a\nb") }},
		{"array on a field with lines under it", "sec", func(d *Document) SetStatus { return d.SetIntArray("sec", []int64{1, 2}) }},
		{"literal array on a field with lines under it", "sec", func(d *Document) SetStatus { return d.SetLiteral("sec", "[1, 2]") }},
		// The path check says UnderArray for this one now (2026100907362300),
		// since no value could go there. TestSetterStatusNamesEachRefusal has
		// it.
		// {"field under an array", "ports.x", func(d *Document) SetStatus { return d.SetInt("ports.x", 1) }},
		{"string that is not UTF-8", "s", func(d *Document) SetStatus { return d.SetString("s", "a\xffb") }},
		{"comment that is not UTF-8", "sec.x", func(d *Document) SetStatus { return d.SetComment("sec.x", "a\xffb") }},
	}
	want := Parse(text).ToCanonical()
	for _, c := range cases {
		doc := Parse(text)
		if c.set(doc) == SetOk {
			t.Errorf("%s: the setter wrote", c.what)
		}
		if got := doc.CheckSetPath(c.path); got != SetOk {
			t.Errorf("%s: CheckSetPath = %v, want Ok", c.what, got)
		}
		if got := doc.ToCanonical(); got != want {
			t.Errorf("%s: wrote %q", c.what, got)
		}
	}
}

// Every status a setter gives, in the order every binding numbers them. The
// other three print the same names. Same fixture in every runner.
func TestSetterStatusValuesInOrder(t *testing.T) {
	defer testID(t, "EsDeJ9a")
	all := []SetStatus{
		SetOk,
		SetBadPath,
		SetValueInPath,
		SetWildcard,
		SetNoSuchIndex,
		SetTooDeep,
		SetMultiple,
		SetUnderArray,
		SetHasChildren,
		SetNotFinite,
		SetBadDateTime,
		SetBadRawInfo,
		SetBadRawBody,
		SetBadComment,
		SetNotOneValue,
		SetNotUtf8,
		SetOutOfRange,
		SetNoReadBack,
	}
	names := []string{
		"Ok",
		"BadPath",
		"ValueInPath",
		"Wildcard",
		"NoSuchIndex",
		"TooDeep",
		"Multiple",
		"UnderArray",
		"HasChildren",
		"NotFinite",
		"BadDateTime",
		"BadRawInfo",
		"BadRawBody",
		"BadComment",
		"NotOneValue",
		"NotUtf8",
		"OutOfRange",
		"NoReadBack",
	}
	if len(all) != len(names) {
		t.Fatalf("%d values, %d names", len(all), len(names))
	}
	for i, s := range all {
		if s.String() != names[i] {
			t.Errorf("value %d is %q, want %q", i, s.String(), names[i])
		}
		if int(s) != i {
			t.Errorf("%v is %d, want %d", s, int(s), i)
		}
	}
}

// A setter's status names why it wrote nothing. A path reason is the one
// CheckSetPath gives, and wins over a value reason when both apply, since the
// path is what to fix first; a value reason comes with a path that checks
// Ok. A default form on a path already there writes nothing and gives what
// the plain setter would. Same fixture in every runner, plus Go's own:
// NotUtf8 for value, comment, info and body text, and BadPath for a path that
// is not UTF-8. OutOfRange and NoReadBack have no case: an int64 is in range,
// and no other value is known that fails to read back.
func TestSetterStatusNamesEachRefusal(t *testing.T) {
	defer testID(t, "EsDeJBi")
	text := "a:\n\tb: 1\nports: [80, 443]\nsec:\n\tx: 1\nport: 1\nport: 2\n"
	month13 := DateTime{HasDate: true, Year: 2026, Month: 13, Day: 1}
	deep := strings.TrimSuffix(strings.Repeat("d.", 513), ".")
	cases := []struct {
		path string
		want SetStatus
		set  func(d *Document) SetStatus
	}{
		{"a.b", SetOk, func(d *Document) SetStatus { return d.SetInt("a.b", 2) }},
		{"a.c", SetOk, func(d *Document) SetStatus { return d.SetFloat("a.c", 2.5) }},
		{"a.b", SetOk, func(d *Document) SetStatus { return d.SetIntDefault("a.b", 9) }},
		{"", SetBadPath, func(d *Document) SetStatus { return d.SetInt("", 1) }},
		{"a..b", SetBadPath, func(d *Document) SetStatus { return d.SetString("a..b", "v") }},
		{"a.b: 2", SetValueInPath, func(d *Document) SetStatus { return d.SetInt("a.b: 2", 1) }},
		{"a(*).b", SetWildcard, func(d *Document) SetStatus { return d.SetInt("a(*).b", 1) }},
		{"a(5).b", SetNoSuchIndex, func(d *Document) SetStatus { return d.SetInt("a(5).b", 1) }},
		{deep, SetTooDeep, func(d *Document) SetStatus { return d.SetInt(deep, 1) }},
		{"port", SetMultiple, func(d *Document) SetStatus { return d.SetInt("port", 9) }},
		{"ports.x", SetUnderArray, func(d *Document) SetStatus { return d.SetInt("ports.x", 1) }},
		{"ports.x.y", SetUnderArray, func(d *Document) SetStatus { return d.SetInt("ports.x.y", 1) }},
		{"ports.x", SetUnderArray, func(d *Document) SetStatus { return d.SetComment("ports.x", "c") }},
		{"ports.x", SetUnderArray, func(d *Document) SetStatus { return d.SetIntDefault("ports.x", 1) }},
		{"sec", SetHasChildren, func(d *Document) SetStatus { return d.SetIntArray("sec", []int64{1, 2}) }},
		{"sec", SetHasChildren, func(d *Document) SetStatus { return d.SetStringArray("sec", []string{"v"}) }},
		{"sec", SetHasChildren, func(d *Document) SetStatus { return d.SetLiteral("sec", "[1, 2]") }},
		{"f", SetNotFinite, func(d *Document) SetStatus { return d.SetFloat("f", math.NaN()) }},
		{"f", SetNotFinite, func(d *Document) SetStatus { return d.SetFloatArray("f", []float64{1, math.Inf(1)}) }},
		{"a.b", SetNotFinite, func(d *Document) SetStatus { return d.SetFloatDefault("a.b", math.NaN()) }},
		{"t", SetBadDateTime, func(d *Document) SetStatus { return d.SetDateTime("t", month13) }},
		{"r", SetBadRawInfo, func(d *Document) SetStatus { return d.SetRaw("r", "body", "sh # x") }},
		{"r", SetBadRawInfo, func(d *Document) SetStatus { return d.SetRaw("r", "body", "sh\nx") }},
		{"a.b", SetBadRawInfo, func(d *Document) SetStatus { return d.SetRawDefault("a.b", "body", "sh # x") }},
		{"r", SetBadRawBody, func(d *Document) SetStatus { return d.SetRaw("r", "a\r\nb", "") }},
		{"sec.x", SetBadComment, func(d *Document) SetStatus { return d.SetComment("sec.x", "a\nb") }},
		{"l", SetNotOneValue, func(d *Document) SetStatus { return d.SetLiteral("l", "a, b") }},
		{"l", SetNotOneValue, func(d *Document) SetStatus { return d.SetLiteral("l", "\"abc") }},
		{"l", SetNotOneValue, func(d *Document) SetStatus { return d.SetLiteral("l", "a\nb") }},
		{"a.b", SetNotOneValue, func(d *Document) SetStatus { return d.SetLiteralDefault("a.b", "a, b") }},
		// Both halves wrong: the path's reason.
		{"a(*).b", SetWildcard, func(d *Document) SetStatus { return d.SetFloat("a(*).b", math.NaN()) }},
		{"ports.x", SetUnderArray, func(d *Document) SetStatus { return d.SetLiteral("ports.x", "a, b") }},
		{"a..b", SetBadPath, func(d *Document) SetStatus { return d.SetComment("a..b", "a\nb") }},
		{"a(5).b", SetNoSuchIndex, func(d *Document) SetStatus { return d.SetRaw("a(5).b", "x", "#") }},
		{"port", SetMultiple, func(d *Document) SetStatus { return d.SetIntArray("port", []int64{1}) }},
		{"port", SetMultiple, func(d *Document) SetStatus { return d.SetFloatDefault("port", math.NaN()) }},
		// Go's own: text that is not UTF-8. It wins over the other value
		// reasons, and a path's reason still wins over it.
		{"s", SetNotUtf8, func(d *Document) SetStatus { return d.SetString("s", "a\xffb") }},
		{"s", SetNotUtf8, func(d *Document) SetStatus { return d.SetStringArray("s", []string{"x", "a\xffb"}) }},
		{"s", SetNotUtf8, func(d *Document) SetStatus { return d.SetLiteral("s", "a\xffb") }},
		{"s", SetNotUtf8, func(d *Document) SetStatus { return d.SetLiteral("s", "a\xff, b") }},
		{"sec.x", SetNotUtf8, func(d *Document) SetStatus { return d.SetComment("sec.x", "a\xffb") }},
		{"sec.x", SetNotUtf8, func(d *Document) SetStatus { return d.SetComment("sec.x", "a\xff\nb") }},
		{"r", SetNotUtf8, func(d *Document) SetStatus { return d.SetRaw("r", "a\xffb", "") }},
		{"r", SetNotUtf8, func(d *Document) SetStatus { return d.SetRaw("r", "body", "sh\xff") }},
		{"r", SetNotUtf8, func(d *Document) SetStatus { return d.SetRaw("r", "a\xff\r\nb", "#") }},
		{"a.b", SetNotUtf8, func(d *Document) SetStatus { return d.SetStringDefault("a.b", "a\xffb") }},
		{"port", SetMultiple, func(d *Document) SetStatus { return d.SetString("port", "a\xffb") }},
		{"a\xff.b", SetBadPath, func(d *Document) SetStatus { return d.SetInt("a\xff.b", 1) }},
		{"a\xff.b", SetBadPath, func(d *Document) SetStatus { return d.SetString("a\xff.b", "a\xffb") }},
	}
	pathReasons := map[SetStatus]bool{
		SetBadPath:     true,
		SetValueInPath: true,
		SetWildcard:    true,
		SetNoSuchIndex: true,
		SetTooDeep:     true,
		SetMultiple:    true,
		SetUnderArray:  true,
	}
	for _, c := range cases {
		doc := Parse(text)
		before := doc.ToCanonical()
		got := c.set(doc)
		if got != c.want {
			t.Errorf("%q: got %v, want %v", c.path, got, c.want)
		}
		checked := Parse(text).CheckSetPath(c.path)
		if pathReasons[c.want] && checked != c.want {
			t.Errorf("%q: CheckSetPath = %v, want %v", c.path, checked, c.want)
		}
		if !pathReasons[c.want] && checked != SetOk {
			t.Errorf("%q: CheckSetPath = %v, want Ok", c.path, checked)
		}
		if got != SetOk && doc.ToCanonical() != before {
			t.Errorf("%q: wrote something", c.path)
		}
	}
}

// A setter on a path that matches more than one field at any step writes
// nothing and the path checks Multiple, so a write never says Ok where the
// read after it would say Multiple. An index or value selector picks one.
// Same fixture in every runner.
func TestRepeatedPathRefusesASetter(t *testing.T) {
	defer testID(t, "Es9aZSG")
	text := "port: 1\nport: 2\nsite: a\n\troot: /x\nsite: b\n\troot: /y\nsec:\n\tk: 1\n\tk: 2\n"
	cases := []struct {
		path string
		set  func(d *Document) SetStatus
	}{
		{"port", func(d *Document) SetStatus { return d.SetInt("port", 9) }},
		{"port", func(d *Document) SetStatus { return d.SetString("port", "9") }},
		{"port", func(d *Document) SetStatus { return d.SetLiteral("port", "9") }},
		{"port", func(d *Document) SetStatus { return d.SetIntArray("port", []int64{9}) }},
		{"port", func(d *Document) SetStatus { return d.SetEmpty("port") }},
		{"port", func(d *Document) SetStatus { return d.SetRaw("port", "x", "") }},
		{"port", func(d *Document) SetStatus { return d.SetComment("port", "c") }},
		{"port", func(d *Document) SetStatus { return d.SetIntDefault("port", 9) }},
		{"port", func(d *Document) SetStatus { return d.SetLiteralDefault("port", "9") }},
		{"site.root", func(d *Document) SetStatus { return d.SetString("site.root", "/z") }},
		{"site.new", func(d *Document) SetStatus { return d.SetString("site.new", "v") }},
		{"site.new", func(d *Document) SetStatus { return d.SetStringDefault("site.new", "v") }},
		{"sec.k", func(d *Document) SetStatus { return d.SetInt("sec.k", 9) }},
		{"sec.k.x", func(d *Document) SetStatus { return d.SetInt("sec.k.x", 9) }},
	}
	want := Parse(text).ToCanonical()
	for _, c := range cases {
		doc := Parse(text)
		if got := c.set(doc); got != SetMultiple {
			t.Errorf("%s: the setter gave %v, want Multiple", c.path, got)
		}
		if got := doc.CheckSetPath(c.path); got != SetMultiple {
			t.Errorf("%s: CheckSetPath = %v, want Multiple", c.path, got)
		}
		if got := doc.ToCanonical(); got != want {
			t.Errorf("%s: wrote %q", c.path, got)
		}
	}
	doc := Parse(text)
	if doc.SetInt("port(1)", 9) != SetOk || doc.SetString("site(1).root", "/z") != SetOk || doc.SetString("site(a).root", "/w") != SetOk || doc.SetInt("sec.k(0)", 7) != SetOk {
		t.Fatalf("a setter naming one instance was refused")
	}
	if doc.GetIntOr("port(0)", 0) != 1 || doc.GetIntOr("port(1)", 0) != 9 || doc.GetStringOr("site(b).root", "") != "/z" || doc.GetStringOr("site(a).root", "") != "/w" || doc.GetIntOr("sec.k(0)", 0) != 7 {
		t.Fatalf("wrote the wrong instance: %q", doc.ToCanonical())
	}
	// A remove takes every instance it matches, as a read sees them.
	if n := doc.Remove("port"); n != 2 {
		t.Fatalf("Remove(port) = %d, want 2", n)
	}
	if got := doc.CheckSetPath("port"); got != SetOk {
		t.Fatalf("CheckSetPath(port) after the remove = %v", got)
	}
}

func TestSettersRefuseAValueTheReaderRefuses(t *testing.T) {
	defer testID(t, "Eof29pZ")
	// Each setter is the inverse of its read, so a value with no spelling the
	// reader accepts fails the write and leaves the document alone. Same
	// fixture in every runner.
	doc := Parse("z: 0\n")
	for _, v := range []float64{math.Inf(1), math.Inf(-1), math.NaN()} {
		if doc.SetFloat("f", v) != SetNotFinite || doc.SetFloatDefault("f", v) != SetNotFinite || doc.SetFloatArray("f", []float64{1, v}) != SetNotFinite {
			t.Fatalf("float %v was written, or not as NotFinite", v)
		}
		// A default form on a path that is already there writes nothing, and
		// still refuses what the plain setter would.
		if doc.SetFloatDefault("z", v) != SetNotFinite || doc.SetFloatArrayDefault("z", []float64{1, v}) != SetNotFinite {
			t.Fatalf("float %v passed a default form on a present path", v)
		}
	}
	if v, st := 2.5, Good; doc.SetFloat("f", v) != SetOk || func() bool { g, s := doc.GetFloat("f"); return g != v || s != st }() {
		t.Fatalf("a finite float was refused")
	}
	if doc.SetFloatDefault("z", 2.5) != SetOk || func() bool { g, _ := doc.GetFloat("z"); return g != 0 }() {
		t.Fatalf("a finite float default on a present path was refused or written")
	}
	date := func(y, m, d int) DateTime { return DateTime{HasDate: true, Year: y, Month: m, Day: d} }
	clock := func(h, mi int, sec int, hasSec bool, frac string) DateTime {
		return DateTime{HasTime: true, Hour: h, Minute: mi, HasSeconds: hasSec, Second: sec, Frac: frac}
	}
	offset := func(dt DateTime, min int) DateTime { dt.Zone = &Zone{Kind: ZoneOffset, OffsetMinutes: min}; return dt }
	utc := func(dt DateTime) DateTime { dt.Zone = &Zone{Kind: ZoneUTC}; return dt }
	bad := []DateTime{
		{},                                      // nothing written
		date(2026, 13, 1),                       // month 13
		date(2026, 2, 30),                       // February 30
		date(-1, 1, 1),                          // negative year
		clock(24, 0, 0, false, ""),              // hour 24
		clock(1, 2, 0, false, "5"),              // fraction with no seconds
		clock(1, 2, 3, true, "12345678901"),     // 11 digits
		offset(clock(1, 2, 0, false, ""), 9999), // +166:39
		utc(date(2026, 1, 1)),                   // zone on a date alone
	}
	for _, dt := range bad {
		if doc.SetDateTime("d", dt) != SetBadDateTime || doc.SetDateTimeDefault("d", dt) != SetBadDateTime || doc.SetDateTimeArray("d", []DateTime{date(2026, 1, 1), dt}) != SetBadDateTime {
			t.Fatalf("datetime %q was written, or not as BadDateTime", dt.String())
		}
		if doc.SetDateTimeDefault("z", dt) != SetBadDateTime || doc.SetDateTimeArrayDefault("z", []DateTime{date(2026, 1, 1), dt}) != SetBadDateTime {
			t.Fatalf("datetime %q passed a default form on a present path", dt.String())
		}
	}
	ok := offset(DateTime{HasDate: true, Year: 2026, Month: 1, Day: 2, HasTime: true, Hour: 3, Minute: 4, HasSeconds: true, Second: 5, Frac: "60"}, -90)
	if doc.SetDateTime("d", ok) != SetOk {
		t.Fatalf("a valid datetime was refused")
	}
	if got, st := doc.GetDateTime("d"); st != Good || got.String() != ok.String() {
		t.Fatalf("datetime read back as %q %v", got.String(), st)
	}
	if got := doc.ToCanonical(); got != "z: 0\n\nf: 2.5\n\nd: \"2026-01-02T03:04:05.60-01:30\"\n" {
		t.Fatalf("document after the refusals: %q", got)
	}
}

// A backtick value is raw text the program decodes itself: read as written,
// with its own flag beside Quoted. A setter keeps the backticks when the new
// text can be written that way. Same fixture in every runner.
func TestABacktickValueReadsRawWithItsFlag(t *testing.T) {
	defer testID(t, "Ery85QE")
	doc := Parse("c: `#FF8800`\nq: \"x\"\nb: x\na: [`1`, b]\nn: `7`\n")
	if r := doc.ReadString("c"); r.Value != "#FF8800" || !r.Quoted || !r.Backtick {
		t.Fatalf("c: %q %v %v", r.Value, r.Quoted, r.Backtick)
	}
	if r := doc.ReadString("q"); !r.Quoted || r.Backtick {
		t.Fatalf("q: %v %v", r.Quoted, r.Backtick)
	}
	if r := doc.ReadString("b"); r.Quoted || r.Backtick {
		t.Fatalf("b: %v %v", r.Quoted, r.Backtick)
	}
	if r := doc.ReadStringArray("a"); len(r.Value) != 2 || r.Quoted || r.Backtick {
		t.Fatalf("a: %v %v %v", r.Value, r.Quoted, r.Backtick)
	}
	if r := doc.ReadInt("n"); r.Value != 7 || !r.Backtick {
		t.Fatalf("n: %d %v", r.Value, r.Backtick)
	}
	if doc.SetString("c", "#00FF00") != SetOk || !doc.ReadString("c").Backtick {
		t.Fatal("an overwrite lost the backticks")
	}
	if doc.SetString("c", "a`b") != SetOk || doc.ReadString("c").Backtick {
		t.Fatal("a backtick value holding a backtick")
	}
	if got := doc.ToCanonical(); !strings.HasPrefix(got, "c: \"a`b\"\n") {
		t.Fatalf("wrote %q", got)
	}
}

func TestRawBlockLineEndingsNormalizeAndRoundTrip(t *testing.T) {
	defer testID(t, "EnLyQsV")
	// A raw body is the only content kept untrimmed, so it is the only place a
	// trailing CR survives the load - and one written back becomes CRLF, which
	// reads as neither. The whole trailing run comes off instead; a CR inside a
	// line is content and stays. Same fixture in every runner: a golden would be
	// rewritten by any platform's line-ending translation.
	doc := Parse("r:\n\t~~~\n\tone\r\r\n\ta\rb\n\t~~~\n")
	if got := doc.ReadRaw("r").Value; got != "one\na\rb" {
		t.Errorf("raw content: got %q", got)
	}
	canon := doc.ToCanonical()
	if again := Parse(canon).ToCanonical(); again != canon {
		t.Errorf("not a fixpoint: %q vs %q", again, canon)
	}
}

func TestChildrenAndInstancePathsWalkARepeatedKey(t *testing.T) {
	defer testID(t, "Eqpzw7V")
	// gitsby's report: Children() on a repeated key answered nothing, and a
	// walk had to know to index each instance.
	doc := Parse("account: w\n\temail: e@x\n\t\tsshkey: k1\n\temail: f@x\n\t\tsshkey: k2\n")
	if got := strings.Join(doc.Children("account(0).email"), "|"); got != "sshkey|sshkey" {
		t.Errorf("children across instances: got %q", got)
	}
	if got := strings.Join(doc.Children("account.email(1)"), "|"); got != "sshkey" {
		t.Errorf("children of one instance: got %q", got)
	}
	want := "account|account.email(0)|account.email(0).sshkey|account.email(1)|account.email(1).sshkey"
	if got := strings.Join(doc.InstancePaths(), "|"); got != want {
		t.Errorf("instance paths: got %q want %q", got, want)
	}
	if v, st := doc.GetString("account.email(1).sshkey"); st != Good || v != "k2" {
		t.Errorf("read through an instance path: %q %v", v, st)
	}
}

func TestReadSurfaceLineQuotedChildren(t *testing.T) {
	defer testID(t, "ElorUZl")
	// Line/Quoted on the read result, Line(path), Children(path). Same
	// fixture in every runner (C pins the same answers on shcl_quoted and
	// shcl_line; its read structs stay value+status).
	text := "a: @null\nb: \"@null\"\ncode:\n\thook: 1\n\thook: 2\n\tdone: 3\n"
	doc := Parse(text)
	if doc.ReadString("a").Quoted {
		t.Error("a reads quoted")
	}
	if !doc.ReadString("b").Quoted {
		t.Error("b reads unquoted")
	}
	if doc.ReadString("code").Quoted {
		t.Error("a block reads quoted")
	}
	// An array read of the same node answers the same: a one-element cell has a
	// single scalar element, so the flag means what it does on the scalar read.
	// More than one element, and there is no single element to report.
	if !doc.ReadStringArray("b").Quoted {
		t.Error("a one-element quoted cell reads unquoted as an array")
	}
	if doc.ReadStringArray("a").Quoted {
		t.Error("a one-element bare cell reads quoted as an array")
	}
	if Parse("m: [\"x\", \"y\"]\n").ReadStringArray("m").Quoted {
		t.Error("a two-element cell reports a single element's quoting")
	}
	if doc.ReadString("missing").Quoted {
		t.Error("a missing path reads quoted")
	}
	if got := doc.ReadString("b").Line; got != 2 {
		t.Errorf("b line: got %d, want 2", got)
	}
	if got := doc.Line("code.done"); got != 6 {
		t.Errorf("code.done line: got %d, want 6", got)
	}
	if got := doc.Line("code"); got != 3 {
		t.Errorf("code line: got %d, want 3", got)
	}
	if got := doc.Line("missing"); got != 0 {
		t.Errorf("missing line: got %d, want 0", got)
	}
	// Lines(): the plural - a repeated field cites every binding, wildcard
	// slots keep their index (0 = unresolved), a miss is the empty list.
	if got := doc.Line("code.hook"); got != 0 { // Multiple - the singular's gap
		t.Errorf("code.hook line: got %d, want 0", got)
	}
	if got := doc.Lines("code.hook"); fmt.Sprint(got) != "[4 5]" {
		t.Errorf("code.hook lines: got %v", got)
	}
	if got := doc.Lines("code.done"); fmt.Sprint(got) != "[6]" {
		t.Errorf("code.done lines: got %v", got)
	}
	if got := doc.Lines("a"); fmt.Sprint(got) != "[1]" {
		t.Errorf("a lines: got %v", got)
	}
	if got := doc.Lines("code(*).done"); fmt.Sprint(got) != "[6]" {
		t.Errorf("code(*).done lines: got %v", got)
	}
	if got := doc.Lines("code(*).nope"); fmt.Sprint(got) != "[0]" {
		t.Errorf("code(*).nope lines: got %v", got)
	}
	if got := doc.Lines("missing"); len(got) != 0 {
		t.Errorf("missing lines: got %v", got)
	}
	if got := doc.Children("code"); strings.Join(got, ",") != "hook,hook,done" {
		t.Errorf("code children: got %v", got)
	}
	if got := doc.Children(""); strings.Join(got, ",") != "a,b,code" {
		t.Errorf("top children: got %v", got)
	}
	if got := doc.Children("missing"); len(got) != 0 {
		t.Errorf("missing children: got %v", got)
	}
	// AuthoredName(): the author's spelling, unfolded; merged instances keep
	// the first binding's; unresolved or Multiple is empty; writer-built
	// keeps the setter path's spelling.
	d2 := Parse("SYMBOLS: 3\nCode:\n\tx: 1\ncode:\n\ty: 2\n")
	if got := d2.AuthoredName("symbols"); got != "SYMBOLS" {
		t.Errorf("AuthoredName(symbols): got %q", got)
	}
	if got := d2.AuthoredName("code"); got != "Code" {
		t.Errorf("AuthoredName(code): got %q", got)
	}
	if got := d2.AuthoredName("missing"); got != "" {
		t.Errorf("AuthoredName(missing): got %q", got)
	}
	if d2.SetInt("NewTop.n", 1) != SetOk {
		t.Errorf("SetInt NewTop.n failed")
	}
	if got := d2.AuthoredName("newtop"); got != "NewTop" {
		t.Errorf("AuthoredName(newtop): got %q", got)
	}
	// Escapes ARE resolved on a name, so both spellings of the path find the
	// same node - while AuthoredName still hands back the source spelling,
	// which is the one thing it is for. Same fixture in every runner.
	d3 := Parse("\"Ab◉TAB◉Cd\": 2\n")
	if got := d3.AuthoredName("\"ab\tcd\""); got != "Ab◉TAB◉Cd" {
		t.Errorf("AuthoredName via the literal spelling: got %q", got)
	}
	if got := d3.ReadInt("\"ab\tcd\"").Value; got != 2 {
		t.Errorf("read via the literal spelling: got %d", got)
	}
	// Canonical output folds the case, as it always has, and escapes the tab.
	if got := d3.ToCanonical(); got != "\"ab◉TAB◉cd\": 2\n" {
		t.Errorf("canonical name spelling: got %q", got)
	}
	if got := d3.AuthoredName("\"ab◉tab◉cd\""); got != "Ab◉TAB◉Cd" {
		t.Errorf("AuthoredName escaped: got %q", got)
	}
}

func TestFileTierLoadSave(t *testing.T) {
	defer testID(t, "EnEYHTt")
	// LoadFile/SaveFile: the status separates absent / unreadable / parsed
	// with errors / clean, and a save round-trips through the atomic write.
	// Same fixture in every runner.
	dir := t.TempDir()
	f := dir + "/t.shcl"

	if _, st := LoadFile(f); st != FileNotFound {
		t.Errorf("missing file: got status %v", st)
	}
	if _, st := LoadFile(dir); st != FileUnreadable { // a directory is not readable
		t.Errorf("directory: got status %v", st)
	}
	// Bad encoding is unreadable too: the parser assumes well-formed text, so a
	// binary file loading clean would read back mangled and a later save would
	// write the mangled version over the original.
	if err := os.WriteFile(f, []byte("a: 1\nb: \xff\xfe bad\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if d, st := LoadFile(f); st != FileUnreadable || d.ToCanonical() != "" {
		t.Errorf("bad encoding: got status %v canonical %q", st, d.ToCanonical())
	}

	if err := os.WriteFile(f, []byte("a: 1\n: broken\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	doc, st := LoadFile(f)
	if st != FileHadErrors {
		t.Errorf("broken file: got status %v", st)
	}
	if v, vst := doc.GetInt("a"); vst != Good || v != 1 {
		t.Errorf("broken file read: got %v %v", v, vst)
	}

	if err := os.WriteFile(f, []byte("a: 1\nb: x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	doc, st = LoadFile(f)
	if st != FileClean {
		t.Errorf("clean file: got status %v", st)
	}
	// ReadFile is the load's read half on its own: the exact bytes, or the
	// status. The cap counts bytes, and a file exactly at it passes. Same
	// fixture in every runner.
	if text, rst := ReadFile(f, 0); rst != FileClean || text != "a: 1\nb: x\n" {
		t.Errorf("ReadFile: got %v %q", rst, text)
	}
	if text, rst := ReadFile(f, 10); rst != FileClean || text != "a: 1\nb: x\n" {
		t.Errorf("ReadFile at the cap: got %v %q", rst, text)
	}
	if text, rst := ReadFile(f, 9); rst != FileUnreadable || text != "" {
		t.Errorf("ReadFile past the cap: got %v %q", rst, text)
	}
	if _, rst := ReadFile(dir+"/none.shcl", 0); rst != FileNotFound {
		t.Errorf("ReadFile missing: got %v", rst)
	}
	if doc.SetInt("c", 3) != SetOk {
		t.Fatal("SetInt failed")
	}
	if err := doc.SaveFile(f); err != nil {
		t.Fatal(err)
	}
	back, st := LoadFile(f)
	if st != FileClean {
		t.Errorf("saved file: got status %v", st)
	}
	if back.ToCanonical() != doc.ToCanonical() {
		t.Errorf("save round-trip mismatch")
	}

	// Creating a file and overwriting one are two different code paths in the
	// write - the create picks its own mode, the overwrite copies the target's,
	// and the publish step differs by platform (windows goes through
	// ReplaceFile, with a rename fallback). Both run everywhere: an overwrite
	// used to throw outright on windows in the python binding, which no
	// POSIX-only fixture could ever have caught. Same fixture in every runner.
	fresh := dir + "/fresh.shcl"
	fdoc := Parse("a: 1\n")
	for _, pass := range []string{"new", "overwritten"} {
		if serr := fdoc.SaveFile(fresh); serr != nil {
			t.Fatalf("%s file: %v", pass, serr)
		}
		fback, fst := LoadFile(fresh)
		if fst != FileClean || fback.ToCanonical() != "a: 1\n" {
			t.Errorf("%s file did not round-trip: status %v", pass, fst)
		}
	}

	// A new file ends up where an ordinary create puts one - 0666 narrowed by the
	// umask - and an existing one keeps the mode it had. Neither is visible on
	// stdout, so no corpus case can see either, and neither is a windows
	// concept, so the mode half is POSIX-only.
	if runtime.GOOS != "windows" {
		modeOf := func(p string) os.FileMode {
			st, serr := os.Stat(p)
			if serr != nil {
				t.Fatal(serr)
			}
			return st.Mode().Perm()
		}
		probe := dir + "/probe"
		h, cerr := os.Create(probe)
		if cerr != nil {
			t.Fatal(cerr)
		}
		if cerr := h.Close(); cerr != nil {
			t.Fatal(cerr)
		}
		born := dir + "/born.shcl"
		if serr := fdoc.SaveFile(born); serr != nil {
			t.Fatal(serr)
		}
		if modeOf(born) != modeOf(probe) {
			t.Errorf("new file: got mode %v, want %v", modeOf(born), modeOf(probe))
		}
		if cerr := os.Chmod(born, 0o640); cerr != nil {
			t.Fatal(cerr)
		}
		if serr := fdoc.SaveFile(born); serr != nil {
			t.Fatal(serr)
		}
		if modeOf(born) != 0o640 {
			t.Errorf("existing file: got mode %v, want -rw-r-----", modeOf(born))
		}
		// setuid and setgid come over too: applying the mode before the data
		// lets the kernel clear them on the write.
		idOf := func(p string) os.FileMode {
			st, serr := os.Stat(p)
			if serr != nil {
				t.Fatal(serr)
			}
			return st.Mode() & (os.ModePerm | os.ModeSetuid | os.ModeSetgid)
		}
		wantID := os.FileMode(0o750) | os.ModeSetuid | os.ModeSetgid
		// BSD gives a new file the directory's group, and refuses setgid on a
		// file whose group the caller is not in. Its own group fixes both.
		_ = os.Chown(born, -1, os.Getegid())
		if cerr := os.Chmod(born, wantID); cerr == nil && idOf(born) == wantID {
			if serr := fdoc.SaveFile(born); serr != nil {
				t.Fatal(serr)
			}
			if idOf(born) != wantID {
				t.Errorf("save dropped a set-id bit: got %v, want %v", idOf(born), wantID)
			}
		} else {
			// Setgid is cleared when the file's group is not one of the caller's,
			// which happens on ordinary boxes. The skip was silent, so this
			// fixture passed wherever it fired.
			t.Logf("skipping the set-id fixture (mode came back %v, want %v)", idOf(born), wantID)
		}
	}
}

func TestSaveFileErrorWrapsTheCause(t *testing.T) {
	defer testID(t, "Eqzz38Y")
	// A caller tells a missing directory from a full disk with errors.Is, not
	// by matching the message, so the save wraps the i/o error.
	err := Parse("a: 1\n").SaveFile(filepath.Join(t.TempDir(), "missing", "t.shcl"))
	if err == nil {
		t.Fatal("save into a missing directory succeeded")
	}
	if !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("error does not wrap fs.ErrNotExist: %v", err)
	}
}

// Every reason a write gives, in the order every binding numbers them. The
// other three print the same names. Same fixture in every runner.
func TestWriteStatusValuesInOrder(t *testing.T) {
	defer testID(t, "EsEhCG0")
	all := []WriteStatus{
		WriteOk,
		WriteNotFound,
		WriteUnreadable,
		WritePermissionDenied,
		WriteDiskFull,
		WriteReadOnly,
		WriteIsDirectory,
		WriteNotRegular,
		WriteOther,
	}
	names := []string{"Ok", "NotFound", "Unreadable", "PermissionDenied", "DiskFull", "ReadOnly", "IsDirectory", "NotRegular", "Other"}
	for i, s := range all {
		if int(s) != i || s.String() != names[i] {
			t.Errorf("%d: %d %q, want %q", i, int(s), s.String(), names[i])
		}
	}
}

// writeStatusIn is the reason inside a failed write's error, or WriteOk.
func writeStatusIn(t *testing.T, err error) WriteStatus {
	t.Helper()
	if err == nil {
		return WriteOk
	}
	var we *WriteError
	if !errors.As(err, &we) {
		t.Fatalf("not a *WriteError: %T %v", err, err)
	}
	return we.Status
}

// A failed write says why as a value, beside the message it always had: from
// WriteFileAtomic, a save, WriteBackup and UpgradeFile. A full disk and a
// read-only filesystem can't be made here without root; TestWriteStatusOf
// maps those. Same fixture in every runner.
func TestWriteStatusNamesEachFailure(t *testing.T) {
	defer testID(t, "EsEhCG1")
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	at := func(name string) string { return filepath.Join(dir, name) }
	check := func(what string, err error, want WriteStatus) {
		t.Helper()
		if got := writeStatusIn(t, err); got != want {
			t.Errorf("%s: %v (%v), want %v", what, got, err, want)
		}
	}
	doc := Parse("a: 1\n")
	check("a plain write", WriteFileAtomic(at("ok.shcl"), "a: 1\n"), WriteOk)
	missing := at("nope/t.shcl")
	err := WriteFileAtomic(missing, "a: 1\n")
	check("into a missing folder", err, WriteNotFound)
	if err == nil || !strings.HasPrefix(err.Error(), missing) || !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("into a missing folder: %v", err)
	}
	check("save into a missing folder", doc.SaveFile(missing), WriteNotFound)
	check("lossy save into a missing folder", doc.SaveFileLossy(missing), WriteNotFound)
	kd, kerr := ParseKeepLines("a: 1\n", Standard)
	if kerr != nil {
		t.Fatal(kerr)
	}
	_, err = kd.SaveFileKeepLines(missing)
	check("kept save into a missing folder", err, WriteNotFound)
	// Part of the path is a file: the folder isn't there either.
	check("under a file", WriteFileAtomic(at("ok.shcl/t.shcl"), "a: 1\n"), WriteNotFound)
	check("over a directory", WriteFileAtomic(at("sub"), "a: 1\n"), WriteIsDirectory)
	check("through a trailing separator", WriteFileAtomic(at("ok.shcl")+"/", "a: 1\n"), WriteIsDirectory)
	_, err = UpgradeFile(at("sub"), false)
	check("upgrade of a directory", err, WriteIsDirectory)
	if err := os.WriteFile(at("bin.shcl"), []byte("a: \xff\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err = UpgradeFile(at("bin.shcl"), false)
	check("upgrade of a file that is not UTF-8", err, WriteUnreadable)
	if runtime.GOOS == "windows" {
		return
	}
	fifo := at("p.shcl")
	if err := exec.Command("mkfifo", fifo).Run(); err != nil {
		t.Fatal(err)
	}
	check("over a FIFO", WriteFileAtomic(fifo, "a: 1\n"), WriteNotRegular)
	_, err = UpgradeFile(fifo, false)
	check("upgrade of a FIFO", err, WriteNotRegular)
	// root writes anyway, so the rows wait for a probe that is refused.
	shut := at("shut")
	if err := os.Mkdir(shut, 0o755); err != nil {
		t.Fatal(err)
	}
	v2 := filepath.Join(shut, "v2.shcl")
	if err := os.WriteFile(v2, []byte("x: a,b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(shut, 0o500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(shut, 0o700)
	if os.WriteFile(filepath.Join(shut, "probe"), nil, 0o644) == nil {
		return
	}
	check("into a shut folder", WriteFileAtomic(filepath.Join(shut, "t.shcl"), "a: 1\n"), WritePermissionDenied)
	_, err = WriteBackup(v2, "x: a,b\n", 2)
	check("backup into a shut folder", err, WritePermissionDenied)
	_, err = UpgradeFile(v2, true)
	check("upgrade in a shut folder", err, WritePermissionDenied)
}

// The table from an OS error to a write's reason. Most rows can't be made to
// happen on a test box: a full disk, a read-only mount, a file held open.
func TestWriteStatusOf(t *testing.T) {
	defer testID(t, "EsEhCG2")
	rows := []struct {
		err  error
		want WriteStatus
	}{
		{fs.ErrNotExist, WriteNotFound},
		{fs.ErrPermission, WritePermissionDenied},
		{fs.ErrExist, WriteOther},
		{errors.New("x"), WriteOther},
		{&WriteError{Status: WriteIsDirectory, Err: errors.New("x")}, WriteIsDirectory},
	}
	if runtime.GOOS != "windows" {
		rows = append(rows, []struct {
			err  error
			want WriteStatus
		}{
			{syscall.EPERM, WritePermissionDenied},
			{syscall.ENOENT, WriteNotFound},
			{syscall.EIO, WriteOther},
			{syscall.EACCES, WritePermissionDenied},
			{syscall.ENOTDIR, WriteNotFound},
			{syscall.EISDIR, WriteIsDirectory},
			{syscall.ENOSPC, WriteDiskFull},
			{syscall.EROFS, WriteReadOnly},
			{syscall.EDQUOT, WriteDiskFull},
			{&fs.PathError{Op: "open", Path: "x", Err: syscall.ENOSPC}, WriteDiskFull},
		}...)
	} else {
		for _, r := range []struct {
			code uintptr
			want WriteStatus
		}{
			{2, WriteNotFound}, {3, WriteNotFound}, {15, WriteNotFound}, {53, WriteNotFound}, {67, WriteNotFound}, {267, WriteNotFound},
			{5, WritePermissionDenied}, {32, WritePermissionDenied}, {33, WritePermissionDenied}, {1224, WritePermissionDenied},
			{39, WriteDiskFull}, {112, WriteDiskFull}, {1295, WriteDiskFull},
			{19, WriteReadOnly}, {1117, WriteOther},
		} {
			rows = append(rows, struct {
				err  error
				want WriteStatus
			}{syscall.Errno(r.code), r.want})
		}
	}
	for _, r := range rows {
		if got := writeStatusOf(r.err); got != r.want {
			t.Errorf("%v: %v, want %v", r.err, got, r.want)
		}
	}
}

func TestReadFileAtTheLargestCap(t *testing.T) {
	defer testID(t, "EoLznCy")
	// A cap given as the type maximum used to overflow the over-cap probe and
	// read nothing. Same fixture in every runner.
	f := filepath.Join(t.TempDir(), "t.shcl")
	if err := os.WriteFile(f, []byte("a: 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if text, st := ReadFile(f, math.MaxInt); st != FileClean || text != "a: 1\n" {
		t.Errorf("ReadFile at the largest cap: got %v %q", st, text)
	}
}

func TestSetRawKeepsASharedIndentAndTrimsTheInfo(t *testing.T) {
	defer testID(t, "EoLznCz")
	// The body's shared indent survives a reload (the closing fence's indent is
	// what comes off), the info-string is stored as a fence line reads it
	// back, and an info with a line break or a `#` has no spelling and fails
	// the write. Same fixture in every runner.
	doc := New()
	if doc.SetRaw("q", "  a\n  b", " sql ") != SetOk {
		t.Fatal("SetRaw failed")
	}
	back := Parse(doc.ToCanonical())
	if v, st := back.GetRaw("q"); st != Good || v != "  a\n  b" {
		t.Errorf("shared indent: got %q %v", v, st)
	}
	if info := back.ReadRawInfo("q").Value; info != "sql" {
		t.Errorf("info: got %q, want sql", info)
	}
	if doc.SetRaw("q", "x", "a\nb") == SetOk {
		t.Error("info with a newline was accepted")
	}
	// A trailing CR is a blank and comes off, as the load takes it; one
	// mid-info is content.
	if doc.SetRaw("q", "x", "ab\r") != SetOk {
		t.Fatal("info ending in a carriage return was refused")
	}
	if info := Parse(doc.ToCanonical()).ReadRawInfo("q").Value; info != "ab" {
		t.Errorf("trailing CR info: got %q, want ab", info)
	}
	if doc.SetRaw("q", "x", "a\rb") != SetOk {
		t.Fatal("info with a mid-string carriage return was refused")
	}
	if info := Parse(doc.ToCanonical()).ReadRawInfo("q").Value; info != "a\rb" {
		t.Errorf("mid-string CR info: got %q", info)
	}
	if doc.SetRaw("q", "x", "a # b") == SetOk {
		t.Error("info with a spaced # was accepted")
	}
	// An info string has no quoting of its own: quotes are characters in it,
	// so they hide nothing, and a `#` glued to the label opens a comment too.
	if doc.SetRaw("q", "x", "\"a # b\"") == SetOk {
		t.Error("info with a quoted # was accepted")
	}
	if doc.SetRaw("q", "x", "c#") == SetOk {
		t.Error("info with a glued # was accepted")
	}
	// A body line ending in CR has no fence spelling: the load takes the whole
	// trailing CR run off every line, so it is refused rather than lost. A CR
	// mid-line is content and still round-trips.
	if doc.SetRaw("q", "a\r\nb", "") == SetOk {
		t.Error("body with a line-ending carriage return was accepted")
	}
	if doc.SetRaw("q", "\r", "") == SetOk {
		t.Error("body of one carriage return was accepted")
	}
	if doc.SetRaw("q", "a\rb", "") != SetOk {
		t.Fatal("body with a mid-line carriage return was refused")
	}
	back = Parse(doc.ToCanonical())
	if v, st := back.GetRaw("q"); st != Good || v != "a\rb" {
		t.Errorf("mid-line CR: got %q %v", v, st)
	}
}

func TestSaveCreatesTheFileBehindADanglingSymlink(t *testing.T) {
	defer testID(t, "EoLznD0")
	// A link to a file that is not there yet is written through like any other
	// link: the file appears where the link points and the link stays a link.
	// Same fixture in every POSIX runner.
	if runtime.GOOS == "windows" {
		t.Skip("POSIX symlink fixture")
	}
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "real"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "c.shcl")
	if err := os.Symlink("real/c.shcl", link); err != nil {
		t.Fatal(err)
	}
	if err := Parse("a: 1\n").SaveFile(link); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Lstat(link); err != nil || st.Mode()&os.ModeSymlink == 0 {
		t.Errorf("link was replaced: %v %v", st, err)
	}
	if got, err := os.ReadFile(filepath.Join(dir, "real", "c.shcl")); err != nil || string(got) != "a: 1\n" {
		t.Errorf("file behind the link: got %q %v", got, err)
	}
}

func TestSaveReportsASymlinkCycleInsteadOfReplacingIt(t *testing.T) {
	defer testID(t, "EoUxXlR")
	// Two links pointing at each other resolve to nothing, so the save fails
	// and says why. It must not "fix" the cycle by dropping a regular file over
	// one of the links. Same fixture in every POSIX runner.
	if runtime.GOOS == "windows" {
		t.Skip("POSIX symlink fixture")
	}
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a.shcl"), filepath.Join(dir, "b.shcl")
	if err := os.Symlink("b.shcl", a); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("a.shcl", b); err != nil {
		t.Fatal(err)
	}
	if err := Parse("a: 1\n").SaveFile(a); err == nil {
		t.Error("a symlink cycle saved without an error")
	}
	for _, link := range []string{a, b} {
		if st, err := os.Lstat(link); err != nil || st.Mode()&os.ModeSymlink == 0 {
			t.Errorf("a symlink cycle was replaced by a regular file: %v %v", st, err)
		}
	}
}

func TestTokenizeValueTakesANegativeOffsetAsZero(t *testing.T) {
	defer testID(t, "EqLxvWy")
	// The reference's offset is unsigned, so a negative one has nothing else
	// it can mean. Go panicked inside skipWsp and Python read it as an offset
	// from the end (20260918b item 31). Same fixture in the Python runner.
	var a, b Tokens
	TokenizeValue("x, 'y' # c", -3, RulesCurrent, &a)
	TokenizeValue("x, 'y' # c", 0, RulesCurrent, &b)
	if !reflect.DeepEqual(a.Elements, b.Elements) || a.Value != b.Value || a.Comment != b.Comment {
		t.Errorf("negative offset: %+v, from zero: %+v", a, b)
	}
}

func TestABadUTF8ByteKeepsItsClosingQuote(t *testing.T) {
	defer testID(t, "ErryPpd")
	// A stray continuation byte or a cut-short sequence stepped over the
	// closing quote, so the line was E017 (2026100511212359). The value comes
	// back with the byte in it. Same fixture in the C runner.
	values := []string{"a b \x80 c", "\x80", "a\x80 b", "a b \xff c", "x\xe9", "\xf0\x9f\x98", "\xc3", "é"}
	for _, v := range values {
		for _, q := range []string{`"`, "'"} {
			d := Parse("v: " + q + v + q + "\n")
			for _, g := range d.Diagnostics() {
				t.Errorf("%q: %s %s", v, g.Code, g.Message)
			}
			if got, st := d.GetString("v"); st != Good || got != v {
				t.Errorf("%q quoted with %s: got %q, %v", v, q, got, st)
			}
		}
	}
	// A cut-short sequence ending the line must not step past its end.
	for _, v := range []string{"x\xf0", "x\xe9\x80", "\xdf"} {
		d := Parse("v: " + v)
		if got, st := d.GetString("v"); st != Good || got != v {
			t.Errorf("bare %q at the end: got %q, %v", v, got, st)
		}
	}
}

func TestMergeOntoItselfLeavesItAlone(t *testing.T) {
	defer testID(t, "EqLqxgm")
	// A document merged onto itself is left as it is (20260918b item 19). The
	// walk read over while it wrote d, so Go doubled a retained line, Python
	// grew without end and C ran out of memory. Every corpus input, and the
	// three lines that showed it. Same fixture in every runner.
	texts := []string{"# c\na: 1\nbad line\n"}
	for _, c := range loadCases(t) {
		texts = append(texts, c.input)
	}
	for _, text := range texts {
		d := Parse(text)
		before := d.ToCanonical()
		d.Merge(d)
		if got := d.ToCanonical(); got != before {
			t.Errorf("merge onto itself changed the document:\n%q\nbecame\n%q", before, got)
		}
	}
}

func TestSaveReplacesOnlyARegularFile(t *testing.T) {
	defer testID(t, "EqLbKe9")
	// Save outcomes in design.md, the rows the CLI's own check hides. A FIFO
	// was swapped for a regular file at exit 0, a link whose text names a
	// directory made a file of that name, and Go cleaned `lnk/..` as text where
	// the kernel follows lnk first. Same fixture in every POSIX runner.
	if runtime.GOOS == "windows" {
		t.Skip("POSIX FIFO and symlink fixture")
	}
	dir := t.TempDir()
	for _, d := range []string{"real/sub", "top"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	doc := Parse("a: 1\n")
	fifo := filepath.Join(dir, "p.shcl")
	if err := exec.Command("mkfifo", fifo).Run(); err != nil {
		t.Fatal(err)
	}
	if err := doc.SaveFile(fifo); err == nil {
		t.Error("a FIFO saved without an error")
	}
	if st, err := os.Lstat(fifo); err != nil || st.Mode()&os.ModeNamedPipe == 0 {
		t.Errorf("a FIFO was replaced by a regular file: %v %v", st, err)
	}
	ldir := filepath.Join(dir, "l.shcl")
	if err := os.Symlink("d/", ldir); err != nil {
		t.Fatal(err)
	}
	if err := doc.SaveFile(ldir); err == nil {
		t.Error("a link naming a directory saved without an error")
	}
	if _, err := os.Lstat(filepath.Join(dir, "d")); err == nil {
		t.Error("a link naming a directory made a file")
	}
	if err := os.Symlink("../real/sub", filepath.Join(dir, "top", "lnkdir")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../x.shcl", filepath.Join(dir, "real", "sub", "f.shcl")); err != nil {
		t.Fatal(err)
	}
	if err := doc.SaveFile(filepath.Join(dir, "top", "lnkdir", "f.shcl")); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(dir, "real", "x.shcl")); err != nil || string(got) != "a: 1\n" {
		t.Errorf("file behind lnk/..: got %q %v", got, err)
	}
	if _, err := os.Lstat(filepath.Join(dir, "top", "x.shcl")); err == nil {
		t.Error("lnk/.. was cleaned as text")
	}
}

func TestSaveRewritesAReadOnlyFile(t *testing.T) {
	defer testID(t, "EoLznD1")
	// A read-only target is rewritten, as it is on POSIX, and comes back
	// read-only; no temp file is left behind. Same fixture in every runner.
	if runtime.GOOS != "windows" {
		t.Skip("windows read-only attribute fixture")
	}
	dir := t.TempDir()
	f := filepath.Join(dir, "ro.shcl")
	if err := os.WriteFile(f, []byte("a: 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(f, 0o444); err != nil {
		t.Fatal(err)
	}
	if err := Parse("a: 2\n").SaveFile(f); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(f); err != nil || string(got) != "a: 2\n" {
		t.Errorf("read-only file: got %q %v", got, err)
	}
	if st, err := os.Stat(f); err != nil || st.Mode().Perm()&0o200 != 0 {
		t.Errorf("read-only attribute did not come back: %v %v", st, err)
	}
	if left, err := os.ReadDir(dir); err != nil || len(left) != 1 {
		t.Errorf("temp file left behind: %d entries %v", len(left), err)
	}
	if err := os.Chmod(f, 0o666); err != nil {
		t.Fatal(err)
	}
}

// A path that names a directory - it ends in a separator, or its last component
// is `.` or `..` - is not a document. A path cleanup drops the trailing
// separator first, so a save through `f/.` used to rewrite `f`. Same fixture in
// every runner.
func TestSaveRefusesADirectoryShapedPath(t *testing.T) {
	defer testID(t, "EomvfCr")
	dir := t.TempDir()
	f := filepath.Join(dir, "f.shcl")
	if err := os.WriteFile(f, []byte("a: 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	doc := Parse("a: 2\n")
	for _, suffix := range []string{"/", "/.", "/.."} {
		if err := doc.SaveFile(f + suffix); err == nil {
			t.Errorf("save through %q was accepted", f+suffix)
		}
	}
	if got, err := os.ReadFile(f); err != nil || string(got) != "a: 1\n" {
		t.Errorf("a refused save changed the file: %q %v", got, err)
	}
	if err := doc.SaveFile(f); err != nil {
		t.Fatal(err)
	}
}

// A Go string can hold any bytes; a document is UTF-8. Text that is not valid
// UTF-8 fails the write rather than storing a replacement character per bad
// byte and reporting success. Go-only: the other three cannot hold such a
// string in the first place.
// Both halves of a path can contain a line break and write it \n: a name through
// the name escaper, a selector value through the value emitter. The selector
// was refused while elements were stored in their source spelling and the
// emitter had nothing to escape with. Same fixture in every runner.
func TestALineBreakInAPathWritesAndReadsBack(t *testing.T) {
	defer testID(t, "EpGigIL")
	doc := Parse("z: 0\n")
	if doc.SetInt("x(\"p\nq\").c", 1) != SetOk || doc.SetInt("\"a\nb\".c", 1) != SetOk {
		t.Fatal("a line break in a path was refused")
	}
	text := doc.ToCanonical()
	back := Parse(text)
	if back.ErrorCount() != 0 {
		t.Errorf("the reload has %d error(s):\n%s", back.ErrorCount(), text)
	}
	if got := back.ToCanonical(); got != text {
		t.Errorf("not a fixpoint:\n%s", text)
	}
	for _, p := range []string{"x(\"p◉NEWLINE◉q\").c", "\"a◉NEWLINE◉b\".c", "\"a\nb\".c"} {
		if r := back.ReadInt(p); r.Value != 1 {
			t.Errorf("read %q got %d", p, r.Value)
		}
	}
}

func TestSetStringRefusesInvalidUTF8(t *testing.T) {
	defer testID(t, "EomvfCs")
	d := Parse("a: 1\n")
	bad := string([]byte{0x61, 0xff, 0x62})
	if got := d.SetString("k", bad); got != SetNotUtf8 {
		t.Errorf("SetString on text that is not UTF-8 gave %v", got)
	}
	if got := d.SetStringArray("k", []string{"ok", bad}); got != SetNotUtf8 {
		t.Errorf("SetStringArray on an element that is not UTF-8 gave %v", got)
	}
	// Every other way text reaches the page. Each used to save and then fail
	// the next load of the whole file. Text in a path is the path's fault.
	for name, c := range map[string]struct {
		want SetStatus
		set  func() SetStatus
	}{
		"SetRaw content":    {SetNotUtf8, func() SetStatus { return d.SetRaw("k", bad, "") }},
		"SetRaw info":       {SetNotUtf8, func() SetStatus { return d.SetRaw("k", "x", bad) }},
		"SetRawDefault":     {SetNotUtf8, func() SetStatus { return d.SetRawDefault("k", bad, "") }},
		"SetComment":        {SetNotUtf8, func() SetStatus { return d.SetComment("a", bad) }},
		"SetLiteral bare":   {SetNotUtf8, func() SetStatus { return d.SetLiteral("k", bad) }},
		"SetLiteral quoted": {SetNotUtf8, func() SetStatus { return d.SetLiteral("k", `"`+bad+`"`) }},
		"SetLiteralDefault": {SetNotUtf8, func() SetStatus { return d.SetLiteralDefault("k", bad) }},
		"SetStringDefault":  {SetNotUtf8, func() SetStatus { return d.SetStringDefault("k", bad) }},
		"a name":            {SetBadPath, func() SetStatus { return d.SetInt(bad, 1) }},
		"a quoted name":     {SetBadPath, func() SetStatus { return d.SetInt(`"`+bad+`"`, 1) }},
		"a selector":        {SetBadPath, func() SetStatus { return d.SetInt("s("+bad+").x", 1) }},
	} {
		if got := c.set(); got != c.want {
			t.Errorf("%s on text that is not UTF-8 gave %v, want %v", name, got, c.want)
		}
	}
	if d.ToCanonical() != "a: 1\n" {
		t.Errorf("a refused write changed the document: %q", d.ToCanonical())
	}
	if d.SetString("k", "fine") != SetOk {
		t.Error("SetString refused valid text")
	}
}

// A written value with both quote kinds is stored the way its own reload
// stores it, so Instances and a read's raw text agree across a save. The
// emitter escapes the double quotes; the writer used to keep them bare. Same
// fixture in every runner.
func TestWrittenSpellingMatchesItsReload(t *testing.T) {
	defer testID(t, "EommtF3")
	d := Parse("x: 1\n")
	if d.SetString("k", "q\"q'") != SetOk {
		t.Fatal("set_string refused")
	}
	back := Parse(d.ToCanonical())
	if got, want := strings.Join(back.Instances("k"), "|"), strings.Join(d.Instances("k"), "|"); got != want {
		t.Errorf("instances after a reload %q, written %q", got, want)
	}
	if got := d.GetStringOr("k", ""); got != "q\"q'" {
		t.Errorf("read back %q", got)
	}
}

// The name index used to be rebuilt by walking the arena, which still holds
// every node a set-and-remove cycle ever made - so the first read after a merge
// grew with the number of edits, not with the document. Timed against the same
// document with no dead nodes; the ratio is what matters, since an absolute
// figure would be a machine constant. Same fixture in every runner.
func TestIndexRebuildIgnoresRemovedNodes(t *testing.T) {
	defer testID(t, "EomjcaX")
	var ms [2]float64
	for churned := 0; churned < 2; churned++ {
		d := Parse("g:\n\tk: 1\n")
		if churned == 1 {
			// A subtree per cycle, not a leaf. A removed leaf leaves its
			// parent's list, so the old walk only stepped over it and cost
			// three times a sound build. A removed subtree keeps its own list,
			// and the old walk indexed every dead child.
			for i := 0; i < 50000; i++ {
				if d.SetInt("g.tmp.x", int64(i)) != SetOk || d.Remove("g.tmp") != 1 {
					t.Fatalf("churn cycle %d: set or remove refused", i)
				}
			}
		}
		other := Parse("g:\n\tk: 1\n")
		t0 := time.Now()
		for i := 0; i < 2000; i++ {
			d.Merge(other)
			if got := d.GetIntOr("g.k", -1); got != 1 {
				t.Fatalf("index walk: got %d", got)
			}
		}
		ms[churned] = float64(time.Since(t0).Microseconds()) / 1000.0
	}
	// A generous ratio on purpose: the chain slice is still sized by the arena,
	// which is a fill the walk cannot avoid. What the bound catches is the walk
	// itself going over every dead node.
	// A shared runner is where a tight bound flakes: the churned side is real
	// work and gets descheduled, the fresh side is under a millisecond and does
	// not. The factor is what catches the defect - the rebuild used to grow
	// with the number of edits, which is orders rather than a fraction - so the
	// constant can absorb a slow machine. Two thousand merges put the defect
	// at seconds to tens of seconds, well past that constant; at two hundred
	// it could hide under it.
	// A clock too coarse to see the fresh side leaves the ratio with no
	// denominator. That used to skip the judgment, and it skipped it silently -
	// through t.Logf, which the gate does not pass -v to - on the one platform
	// where it fires, this hosted windows job. The constant term alone is an
	// absolute figure on whatever machine is running, so it gets room: the
	// healthy churned side has measured half a second there, and the defect is
	// tens of seconds.
	bound := ms[0]*25 + 1000
	if ms[0] <= 0 {
		bound = 3000
	}
	if ms[1] > bound {
		t.Errorf("index rebuild after churn %.1f ms against %.1f ms fresh (bound %.1f ms) - it walks nodes the document no longer holds", ms[1], ms[0], bound)
	}
}

// A merge settles the comments of the blocks it visited, not of the whole tree:
// a whole-tree pass made each small merge cost the document, and a caller
// folding many layers onto a big one paid it every time. Timed against the same
// merges with the big block left out. Same fixture in every runner.
func TestMergeSettlesOnlyWhatItTouched(t *testing.T) {
	defer testID(t, "EqoaM6D")
	var ms [2]float64
	for big := 0; big < 2; big++ {
		var text strings.Builder
		text.WriteString("g:\n\tk: 1\n")
		if big == 1 {
			text.WriteString("big:\n")
			for i := 0; i < 100000; i++ {
				fmt.Fprintf(&text, "\tc%d: %d\n", i, i)
			}
		}
		d := Parse(text.String())
		other := Parse("g:\n\tk: 1\n")
		t0 := time.Now()
		for i := 0; i < 2000; i++ {
			d.Merge(other)
		}
		ms[big] = float64(time.Since(t0).Microseconds()) / 1000.0
		if got := d.GetIntOr("g.k", -1); got != 1 {
			t.Fatalf("merged read: got %d", got)
		}
	}
	// The same bound as the index fixture above: the defect is a walk over a
	// hundred thousand nodes per merge, seconds past the constant term.
	bound := ms[0]*25 + 1000
	if ms[0] <= 0 {
		bound = 3000
	}
	if ms[1] > bound {
		t.Errorf("2000 merges beside a big block %.1f ms against %.1f ms without it (bound %.1f ms) - the merge settles blocks it never touched", ms[1], ms[0], bound)
	}
}

// A misplaced line kept as written made every edit and merge re-emit the whole
// document to settle it, even one far from the line. Timed against the same
// steps on the same document without the line. Same fixture in every runner.
func TestAFarKeptLineCostsAnEditNothing(t *testing.T) {
	defer testID(t, "EqqmFxR")
	var ms [2]float64
	for kept := 0; kept < 2; kept++ {
		var text strings.Builder
		text.WriteString("g:\n\tk: 1\nbig:\n")
		for i := 0; i < 100000; i++ {
			fmt.Fprintf(&text, "\tc%d: %d\n", i, i)
		}
		if kept == 1 {
			text.WriteString(" x: y\n")
		}
		d := Parse(text.String())
		other := Parse("g:\n\tj: 1\n")
		t0 := time.Now()
		// Edits first: a merge drops the name index, and the edit after it
		// would rebuild it over the whole document either way.
		for i := 0; i < 500; i++ {
			if d.SetInt("g.k", int64(i)) != SetOk {
				t.Fatalf("SetInt refused")
			}
		}
		for i := 0; i < 500; i++ {
			d.Merge(other)
		}
		ms[kept] = float64(time.Since(t0).Microseconds()) / 1000.0
		if got := d.GetIntOr("g.k", -1); got != 499 {
			t.Fatalf("edited read: got %d", got)
		}
		if strings.HasSuffix(d.ToCanonical(), "\n x: y\n") != (kept == 1) {
			t.Fatalf("the kept line is not where the fixture put it")
		}
	}
	bound := ms[0]*25 + 1000
	if ms[0] <= 0 {
		bound = 3000
	}
	if ms[1] > bound {
		t.Errorf("500 edits and merges beside a kept line %.1f ms against %.1f ms without it (bound %.1f ms) - each one settles the whole document", ms[1], ms[0], bound)
	}
}

func TestLostAndSaveGate(t *testing.T) {
	defer testID(t, "EnEclpy")
	// Content-malformed lines are retained as trivia (LostCount 0, the line
	// survives a save); position-dependent drops count as lost and make
	// SaveFile refuse until the caller opts into SaveFileLossy. Same fixture
	// in every runner.
	kept := Parse("a: 1\nsquare-miles 300\nb: 2\n")
	if kept.LostCount() != 0 {
		t.Errorf("kept LostCount: got %d", kept.LostCount())
	}
	if !strings.Contains(kept.ToCanonical(), "square-miles 300\n") {
		t.Errorf("retained line missing from canonical output")
	}
	// An indent matching no level is kept as written when it holds a space,
	// which no level the emitter writes can equal, and lost when it is tabs.
	spaced := Parse("a:\n\tb: 1\n  c: 2\n\td: 3\n")
	if spaced.LostCount() != 0 {
		t.Errorf("spaced LostCount: got %d", spaced.LostCount())
	}
	if got := spaced.ToCanonical(); got != "a:\n\tb: 1\n  c: 2\n\td: 3\n" {
		t.Errorf("spaced line not kept as written: %q", got)
	}
	lost := Parse("a:\n\t\tb: 1\n\tc: 2\n")
	if lost.LostCount() != 1 {
		t.Errorf("lost LostCount: got %d", lost.LostCount())
	}
	f := t.TempDir() + "/t.shcl"
	if err := kept.SaveFile(f); err != nil {
		t.Fatal(err)
	}
	back, _ := LoadFile(f)
	if !strings.Contains(back.ToCanonical(), "square-miles 300\n") {
		t.Errorf("retained line lost through save round-trip")
	}
	if err := lost.SaveFile(f); err == nil {
		t.Errorf("SaveFile did not refuse a lossy save")
	}
	if err := lost.SaveFileLossy(f); err != nil {
		t.Fatal(err)
	}
	// A refusal and a failed write are separate values, not two spellings of one
	// message, and the gate answers before any i/o - so an unwritable path still
	// reports the refusal. Same fixture in every runner.
	bad := t.TempDir() + "/nope/t.shcl"
	var refused *SaveRefused
	if err := kept.SaveFile(bad); err == nil || errors.As(err, &refused) {
		t.Errorf("a failed write reported as a refusal: %v", err)
	}
	if err := lost.SaveFile(bad); !errors.As(err, &refused) || refused.Lost != 1 {
		t.Errorf("refusal did not survive an unwritable path: %v", err)
	}
	// A save that keeps lines writes the dropped line back as it was, so it
	// refuses only when it falls back to canonical. Here removing the line
	// above it would make it a child of `a`.
	keep, err := ParseKeepLines("a:\n\t\tb: 1\n\tc: 2\n", Standard)
	if err != nil {
		t.Fatal(err)
	}
	if keep.SetInt("a.b", 5) != SetOk {
		t.Fatal("SetInt a.b refused")
	}
	if k, err := keep.SaveFileKeepLines(f); err != nil || !k {
		t.Errorf("keep save with a dropped line: kept %v, err %v", k, err)
	}
	if got, _ := os.ReadFile(f); string(got) != "a:\n\t\tb: 5\n\tc: 2\n" {
		t.Errorf("keep save wrote %q", got)
	}
	if keep.Remove("a.b") != 1 {
		t.Fatal("Remove a.b")
	}
	if _, err := keep.SaveFileKeepLines(f); !errors.As(err, &refused) || refused.Lost != 1 {
		t.Errorf("keep save that fell back did not refuse: %v", err)
	}
}

func TestStrictFailureCarriesDocument(t *testing.T) {
	defer testID(t, "Elop5Fh")
	// A failed strict load hands back the document (non-nil, and on the
	// error too) and names the first failures in the message.
	doc, err := ParseWith("ok: 1\n: nope\n", Strict)
	if err == nil || doc == nil {
		t.Fatalf("want non-nil doc and error, got %v %v", doc, err)
	}
	le := err.(*LoadError)
	if le.Document != doc || len(le.Diagnostics) == 0 {
		t.Fatalf("error does not include the document/diagnostics")
	}
	if r := doc.ReadInt("ok"); r.Value != 1 {
		t.Fatalf("doc unusable: %v", r)
	}
	if !strings.Contains(err.Error(), "; line ") {
		t.Fatalf("message lacks diagnostics: %s", err.Error())
	}
}

func TestParseLimitedCaps(t *testing.T) {
	defer testID(t, "Eoe5NRx")
	// The caps exist because a document amplifies to many times its byte size
	// in memory, so ReadFile's byte cap alone cannot bound a load. Same
	// fixture in every runner.
	codeCount := func(d *Document, code string) (n int, line int) {
		for _, g := range d.Diagnostics() {
			if g.Code == code {
				n++
				line = g.Line
			}
		}
		return
	}
	// Node cap: one E020 at the first line not parsed, the remainder counts
	// as lost, and what parsed before the cap stays readable.
	text := "a: 1\nb: 2\nc: 3\nd: 4\n"
	doc, err := ParseLimited(text, Standard, 2, 0, 0)
	if err != nil {
		t.Fatalf("standard must not fail: %v", err)
	}
	if n, line := codeCount(doc, "E020"); n != 1 || line != 4 {
		t.Fatalf("want one E020 at line 4, got %d at %d", n, line)
	}
	if doc.LostCount() != 1 {
		t.Fatalf("lost: %d", doc.LostCount())
	}
	if v, st := doc.GetInt("a"); v != 1 || st != Good {
		t.Fatalf("a: %d %v", v, st)
	}
	if doc.Exists("d") {
		t.Fatalf("the remainder must not parse")
	}
	// A cap crossed by the document's last content line still reports. The
	// Standard calls from here on drop the error, which only Strict returns.
	doc, _ = ParseLimited("a: 1\nb: 2\nc: 3", Standard, 2, 0, 0)
	if n, _ := codeCount(doc, "E020"); n != 1 || doc.LostCount() != 0 {
		t.Fatalf("last-line cross: %d E020, lost %d", n, doc.LostCount())
	}
	// One line may overshoot the cap by its own path; the parse still stops.
	doc, _ = ParseLimited("x.y.z: 1\n", Standard, 1, 0, 0)
	if n, _ := codeCount(doc, "E020"); n != 1 {
		t.Fatalf("deep line: %d E020", n)
	}
	if v, st := doc.GetInt("x.y.z"); v != 1 || st != Good {
		t.Fatalf("overshot line must still be in the document: %d %v", v, st)
	}
	// 0 is no cap: identical to ParseWith.
	doc, _ = ParseLimited(text, Standard, 0, 0, 0)
	if len(doc.Diagnostics()) != 0 {
		t.Fatalf("uncapped: %v", doc.Diagnostics())
	}
	// A cap near MaxInt is as good as none, and a negative one stops at the
	// first line. Sizing the arena from either used to panic.
	for _, capAt := range []int{math.MaxInt, math.MaxInt - 1, math.MaxInt - 2} {
		doc, _ = ParseLimited(text, Standard, capAt, 0, 0)
		if len(doc.Diagnostics()) != 0 {
			t.Fatalf("cap %d: %v", capAt, doc.Diagnostics())
		}
	}
	for _, capAt := range []int{-1, -3, math.MinInt} {
		doc, _ = ParseLimited(text, Standard, capAt, 0, 0)
		if n, line := codeCount(doc, "E020"); n != 1 || line != 1 {
			t.Fatalf("cap %d: %d E020 at %d", capAt, n, line)
		}
		// The arena is trimmed after the parse, so the reserve is read here.
		if w := arenaWant(200000, capAt); w != 1 {
			t.Fatalf("cap %d reserves %d slots for a parse that stops at line 1", capAt, w)
		}
	}
	for _, c := range []struct{ lines, capAt, want int }{{10, 0, 11}, {10, 2, 4}, {10, 9, 11}, {10, math.MaxInt, 11}} {
		if w := arenaWant(c.lines, c.capAt); w != c.want {
			t.Fatalf("%d lines under cap %d reserve %d, want %d", c.lines, c.capAt, w, c.want)
		}
	}
	// Element cap, bracket spelling: the whole line is refused, the rest of
	// the document is untouched.
	doc, _ = ParseLimited("arr: [1, 2, 3]\nok: 5\n", Standard, 0, 2, 0)
	if n, line := codeCount(doc, "E021"); n != 1 || line != 1 {
		t.Fatalf("want one E021 at line 1, got %d at %d", n, line)
	}
	if doc.Exists("arr") {
		t.Fatalf("refused line must not bind")
	}
	if v, st := doc.GetInt("ok"); v != 5 || st != Good {
		t.Fatalf("ok: %d %v", v, st)
	}
	if doc.LostCount() != 1 {
		t.Fatalf("lost: %d", doc.LostCount())
	}
	// Element cap, stacked spelling: each element line past the cap is
	// refused on its own; the array keeps what fit.
	doc, _ = ParseLimited("arr:\n\t- 1\n\t- 2\n\t- 3\n", Standard, 0, 2, 0)
	if n, _ := codeCount(doc, "E021"); n != 1 {
		t.Fatalf("star: %d E021", n)
	}
	if v, st := doc.GetIntArray("arr"); st != Good || !reflect.DeepEqual(v, []int64{1, 2}) {
		t.Fatalf("star array: %v %v", v, st)
	}
	// A malformed array past the cap stayed E019 and kept. Since 2026-10-05
	// the cap wins over a broken value, so this is E021 now: see
	// TestACapWinsOverABrokenValue.
	// doc, _ = ParseLimited("arr: [1,, 2, 3]\nk: x\n\t- 1\n", Standard, 0, 1, 0)
	// got := ""
	// for _, d := range doc.Diagnostics() {
	// 	got += fmt.Sprintf("%d %s;", d.Line, d.Code)
	// }
	// if got != "1 E019;3 E011;" || doc.LostCount() != 1 || !strings.Contains(doc.ToCanonical(), "arr: [1,, 2, 3]") {
	// 	t.Fatalf("cap over a refused line: %q lost %d", got, doc.LostCount())
	// }
	// The count the cap judges is the count the array reads back as, spelling
	// by spelling: quoted commas, a backslash (a character, so it shields
	// nothing), the empty array, a quoted Unicode blank (content: only a space
	// or a tab is blank, and bare it is E025). Refused at one under, kept at
	// exact. A quote that never closes made the comma after it split before
	// the value syntax; that line is E017 now and binds nothing. An empty slot
	// is E019 now, and a bare comma E026.
	counts := []struct {
		spelling string
		n        int
	}{
		{"[1, 2, 3]", 3}, {"[\"a, b\", c]", 2}, {"[a\\, b, c]", 3}, {"[]", 0},
		{"[ ]", 0}, {" a ", 1}, {"[\"\", '']", 2}, {"'a\", b'", 1},
		// {"\"open, b", 2},
		{"\\", 1}, {"[x,\"\u3000\"]", 2}, {"[x, \"\u00a0y\"]", 2}, {"[80]", 1},
	}
	for _, c := range counts {
		text := "v: " + c.spelling + "\n"
		cap := c.n
		if cap == 0 {
			cap = 1
		}
		doc, _ = ParseLimited(text, Standard, 0, cap, 0)
		if n, _ := codeCount(doc, "E021"); n != 0 {
			t.Fatalf("%q at cap %d: E021", c.spelling, c.n)
		}
		if v, st := doc.GetStringArray("v"); c.n == 0 {
			if st != Good || len(v) != 0 {
				t.Fatalf("%q: want empty, got %v %v", c.spelling, v, st)
			}
		} else if st != Good || len(v) != c.n {
			t.Fatalf("%q: want %d elements, got %v %v", c.spelling, c.n, v, st)
		}
		if c.n >= 2 {
			doc, _ = ParseLimited(text, Standard, 0, c.n-1, 0)
			if doc.LostCount() != 1 {
				t.Fatalf("%q at cap %d: not refused", c.spelling, c.n-1)
			}
		}
	}
	// An open quote was judged before the cap and kept the line. Since
	// 2026-10-05 the cap wins: see TestACapWinsOverABrokenValue.
	// doc, _ = ParseLimited("v: [a, \"open, b]\n", Standard, 0, 1, 0)
	// if len(doc.Diagnostics()) != 1 || doc.Diagnostics()[0].Code != "E017" || doc.LostCount() != 0 {
	// 	t.Fatalf("refused line: %v", doc.Diagnostics())
	// }
	// A fence whose info string splits past the cap is refused with its block,
	// in both spellings, so the body never reads as live lines. Same fixture in
	// every runner. Only a comma with a blank after it splits since 20261006.
	for _, text := range []string{
		"secrets:\n\t```a, b, c, d\n\tpassword: hunter2\n\t```\nafter: 1\n",
		"secrets: ```a, b, c, d\n\tpassword: hunter2\n\t```\nafter: 1\n",
	} {
		doc, _ = ParseLimited(text, Standard, 0, 3, 0)
		if len(doc.Diagnostics()) != 1 || doc.Diagnostics()[0].Code != "E021" {
			t.Fatalf("%q: %v", text, doc.Diagnostics())
		}
		if doc.Exists("secrets.password") {
			t.Fatalf("%q: the body bound", text)
		}
		if v, st := doc.GetInt("after"); v != 1 || st != Good {
			t.Fatalf("%q: after: %d %v", text, v, st)
		}
		if doc.LostCount() != 1 {
			t.Fatalf("%q: lost %d", text, doc.LostCount())
		}
	}
	// Diagnostic cap: the first N are listed and one E022 tail counts the
	// rest. Its severity is Error when any unlisted one was, so a scan of the
	// list for errors still finds one and ErrorCount stays nonzero.
	bad := strings.Repeat("no colon\n", 50)
	doc, _ = ParseLimited(bad, Standard, 0, 0, 10)
	if len(doc.Diagnostics()) != 11 {
		t.Fatalf("diag cap: %d listed", len(doc.Diagnostics()))
	}
	for _, d := range doc.Diagnostics()[:10] {
		if d.Code != "E014" {
			t.Fatalf("diag cap: listed %s", d.Code)
		}
	}
	tail := doc.Diagnostics()[10]
	if tail.Code != "E022" || tail.Severity != SeverityError || tail.Line != 0 ||
		tail.Message != "diagnostic cap of 10 reached; 40 more not listed, 40 of them errors" {
		t.Fatalf("diag cap tail: %+v", tail)
	}
	if doc.ErrorCount() != 11 {
		t.Fatalf("diag cap: error count %d", doc.ErrorCount())
	}
	if _, err := ParseLimited(bad, Strict, 0, 0, 10); err == nil {
		t.Fatalf("diag cap: capped strict load must fail")
	}
	// Hints past the cap leave a Hint tail, so a document with no error
	// still loads at Strict.
	hints := "x: 1\nx: 2\ny: 1\ny: 2\n"
	doc, err = ParseLimited(hints, Strict, 0, 0, 1)
	if err != nil || len(doc.Diagnostics()) != 2 || doc.Diagnostics()[0].Code != "H001" ||
		doc.Diagnostics()[1].Code != "E022" || doc.Diagnostics()[1].Severity != SeverityHint ||
		!strings.HasSuffix(doc.Diagnostics()[1].Message, "1 more not listed, 0 of them errors") || doc.ErrorCount() != 0 {
		t.Fatalf("hint tail: %v %+v", err, doc.Diagnostics())
	}
	// At the cap exactly, nothing is unlisted and there is no tail.
	doc, _ = ParseLimited(hints, Standard, 0, 0, 2)
	if len(doc.Diagnostics()) != 2 {
		t.Fatalf("at the cap: %+v", doc.Diagnostics())
	}
	// A cap diagnostic is an error, so a capped Strict load fails - with the
	// parsed part still on the error.
	doc, err = ParseLimited(text, Strict, 2, 0, 0)
	if err == nil {
		t.Fatalf("capped strict load must fail")
	}
	if v, st := doc.GetInt("a"); v != 1 || st != Good {
		t.Fatalf("failed strict doc unusable: %d %v", v, st)
	}
}

// An item or a line past the caller's element cap is E021 and dropped, even
// when its value is broken: the cap wins over a value fault. A fault in the
// path or the name still comes first, and a broken item within the cap is
// still kept. Same fixture in every runner.
func TestACapWinsOverABrokenValue(t *testing.T) {
	defer testID(t, "Ery85QC")
	codes := func(text string, capAt int) (string, int, string) {
		doc, _ := ParseLimited(text, Standard, 0, capAt, 0)
		got := ""
		for _, d := range doc.Diagnostics() {
			got += fmt.Sprintf("%d %s;", d.Line, d.Code)
		}
		return got, doc.LostCount(), doc.ToCanonical()
	}
	// Bracket arrays: an empty slot, an open quote, no closing bracket, text
	// after it. Each is E021 at a cap below its length, and its own code at a
	// cap that fits.
	for _, c := range []struct{ text, own string }{
		{"arr: [1,, 2, 3]\n", "E019"},
		{"arr: [a, \"open, b]\n", "E017"},
		{"arr: [a, b, c\n", "E019"},
		{"arr: [a, b] c\n", "E019"},
		{"arr: [a, b c, d]\n", "E025"},
	} {
		got, lost, out := codes(c.text, 1)
		if got != "1 E021;" || lost != 1 || strings.Contains(out, "arr") {
			t.Fatalf("%q at cap 1: %q lost %d out %q", c.text, got, lost, out)
		}
		got, lost, _ = codes(c.text, 9)
		if got != "1 "+c.own+";" || lost != 0 {
			t.Fatalf("%q under the cap: %q lost %d", c.text, got, lost)
		}
	}
	// A bare comma outside brackets counts its pieces the same way.
	if got, _, _ := codes("a: x, y, z\n", 2); got != "1 E021;" {
		t.Fatalf("bare comma past the cap: %q", got)
	}
	if got, _, _ := codes("a: x, y, z\n", 3); got != "1 E026;" {
		t.Fatalf("bare comma within the cap: %q", got)
	}
	// A stacked item past the cap is dropped whatever it holds; within the
	// cap a broken one is kept and the list loads around it.
	got, lost, out := codes("x:\n\t- a\n\t- b\n\t- \"open\n\t- c d\nz: 1\n", 2)
	if got != "4 E021;5 E021;" || lost != 2 || out != "x:\n\t- a\n\t- b\nz: 1\n" {
		t.Fatalf("items past the cap: %q lost %d out %q", got, lost, out)
	}
	got, lost, out = codes("x:\n\t- a\n\t- \"open\n\t- b\n", 2)
	if got != "3 E017;" || lost != 0 || !strings.Contains(out, "- \"open") {
		t.Fatalf("a broken item within the cap: %q lost %d out %q", got, lost, out)
	}
	// An element under a field with a value is E011, cap or not.
	if got, _, _ := codes("k: x\n\t- 1\n", 1); got != "2 E011;" {
		t.Fatalf("item under a value: %q", got)
	}
	// The path and the name are judged first.
	if got, _, _ := codes("404: [a, b, c]\n", 1); got != "1 E014;" {
		t.Fatalf("a bad name past the cap: %q", got)
	}
}

func TestNoColonRepairStaysNarrow(t *testing.T) {
	defer testID(t, "Ery85QD")
	// Only one clean name or path with no colon is repaired (E015), a bad
	// bare name like 404 included. Anything with a blank in a bare name could
	// be a name or a name and a value, so it is E014 and kept as written.
	for _, c := range []struct{ line, quoted string }{
		{"square-miles 300", "\"square-miles 300\""},
		{"this is ! not parseable", "\"this is ! not parseable\""},
		{"user name", "\"user name\""},
		{"user\tname", "\"user◉TAB◉name\""},
		{"a.b c", "a.\"b c\""},
	} {
		doc := Parse("k: 1\n" + c.line + "\nz: 2\n")
		d := doc.Diagnostics()
		if len(d) != 1 || d[0].Code != "E014" {
			t.Fatalf("%q: %v", c.line, d)
		}
		if n := doc.LostCount(); n != 0 {
			t.Fatalf("%q: LostCount %d", c.line, n)
		}
		if got := doc.ToCanonical(); got != "k: 1\n"+c.line+"\nz: 2\n" {
			t.Fatalf("%q wrote %q", c.line, got)
		}
		if doc.Exists(c.quoted) {
			t.Fatalf("%q bound %s", c.line, c.quoted)
		}
	}
	doc := Parse("a:\n\t  square-miles 300\n")
	if got := doc.Diagnostics()[0].Message; got != "malformed line skipped: unexpected character after the path, at column 17" {
		t.Fatalf("message %q", got)
	}
	for _, c := range []struct{ line, out string }{
		{"404", "\"404\":"},
		{"-x", "\"-x\":"},
		{"a.9b", "a:\n\t\"9b\":"},
	} {
		doc := Parse(c.line + "\n")
		d := doc.Diagnostics()
		if len(d) != 1 || d[0].Code != "E015" {
			t.Fatalf("%q: %v", c.line, d)
		}
		if got := doc.ToCanonical(); got != c.out+"\n" {
			t.Fatalf("%q wrote %q", c.line, got)
		}
	}
}

func TestRawIsSourceText(t *testing.T) {
	defer testID(t, "ElonRnO")
	// Raw: the verbatim value span from the source line - not the display
	// join, which rewrites `{2,3}` to `{2, 3}`. Same fixture in every runner
	// whose read result exposes raw (the C read structs deliberately do not).
	doc := Parse("regex: \"^\\d{2,3}$\"\nlist: [a,  \"b c\"]\n")
	if r := doc.ReadString("regex"); r.Raw == nil || *r.Raw != "\"^\\d{2,3}$\"" {
		t.Errorf("regex raw: got %v", r.Raw)
	}
	if r := doc.ReadStringArray("list"); r.Raw == nil || *r.Raw != "[a,  \"b c\"]" {
		t.Errorf("list raw: got %v", r.Raw)
	}
	// A written value has no source spelling; raw falls back to display. The
	// selector's escaped spelling must reach the existing instance.
	doc2 := Parse("who: 'q\"uote'\n")
	if doc2.SetInt("who(\"q◉DQUOTE◉uote\").n", 5) != SetOk {
		t.Fatal("SetInt with escaped selector failed")
	}
	if n := doc2.Count("who"); n != 1 {
		t.Errorf("who count: got %d, want 1", n)
	}
	r := doc2.ReadInt("who('q\"uote').n")
	if r.Value != 5 || r.Status != Good {
		t.Errorf("read back: got (%d, %v), want (5, Good)", r.Value, r.Status)
	}
	if r.Raw == nil || *r.Raw != "5" {
		t.Errorf("written raw: got %v, want 5", r.Raw)
	}
}

func TestLayeredMergeMatchesExpected(t *testing.T) {
	defer testID(t, "EkyV759")
	// Layered-load dimension: fold the layer files (lowest first) and input.shcl
	// (highest file layer) via the library Merge, apply the path=value overrides
	// as the top layer, and match the golden merged canonical.
	eachCase(t, func(t *testing.T, c corpusCase) {
		if !c.hasMerge {
			return
		}
		texts := append(append([]string(nil), c.layers...), c.input)
		doc := Parse(texts[0])
		for _, t2 := range texts[1:] {
			doc.Merge(Parse(t2))
		}
		for _, line := range strings.Split(c.mergeSets, "\n") {
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			eq := strings.IndexByte(line, '=')
			if eq < 0 {
				t.Fatalf("%s: bad merge.sets line: %s", c.name, line)
			}
			if doc.SetString(line[:eq], line[eq+1:]) != SetOk {
				t.Fatalf("%s: merge.set did not apply: %s", c.name, line)
			}
		}
		got := doc.ToCanonical()
		// Reads answered by the merged document itself, not just its text: a
		// merged arena holds dropped nodes, a rebuilt index and cloned child
		// lists, and only a read walks those. Instances is left out because it
		// hands back the source spelling, which canonical output may rewrite.
		// Same fixture in every runner.
		back := Parse(got)
		if !reflect.DeepEqual(doc.Paths(), back.Paths()) {
			t.Errorf("%s: merged paths differ from a reparse", c.name)
		}
		for _, p := range doc.Paths() {
			if doc.Count(p) != back.Count(p) {
				t.Errorf("%s: merged count %s", c.name, p)
			}
			if !reflect.DeepEqual(doc.Children(p), back.Children(p)) {
				t.Errorf("%s: merged children %s", c.name, p)
			}
			x, y := doc.ReadString(p), back.ReadString(p)
			if x.Value != y.Value || x.Status != y.Status {
				t.Errorf("%s: merged read %s", c.name, p)
			}
			xa, ya := doc.ReadStringArray(p), back.ReadStringArray(p)
			if !reflect.DeepEqual(xa.Value, ya.Value) || xa.Status != ya.Status || !reflect.DeepEqual(xa.Slots, ya.Slots) {
				t.Errorf("%s: merged array read %s", c.name, p)
			}
		}
		if got != c.expectedMerged {
			t.Errorf("%s: merged output differs from expected-merged.shcl\ngot:\n%s\nwant:\n%s", c.name, got, c.expectedMerged)
			return
		}
		if again := Parse(got).ToCanonical(); again != got {
			t.Errorf("%s: merged output is not a fmt fixpoint", c.name)
		}
	})
}

func TestInitGenerationMatchesExpected(t *testing.T) {
	defer testID(t, "EkyZiCY")
	// Generation dimension: Generate on the schema must reproduce the golden
	// starter config, and that output must itself load cleanly.
	eachCase(t, func(t *testing.T, c corpusCase) {
		if !c.hasInit {
			return
		}
		got, faults := Generate(Parse(c.initSchema), false)
		if faults != nil {
			t.Fatalf("%s: init schema has faults", c.name)
		}
		if got != c.expectedInit {
			t.Errorf("%s: init output differs from expected-init.shcl\ngot:\n%s\nwant:\n%s", c.name, got, c.expectedInit)
			return
		}
		// The footer is the only difference the flag makes: everything before
		// it is byte-for-byte what the default run produced.
		bare, _ := Generate(Parse(c.initSchema), true)
		if bare == "" || !strings.HasPrefix(got, bare) {
			t.Errorf("%s: --no-banner output is not a prefix of the default", c.name)
			return
		}
		if !strings.Contains(got[len(bare):], "This config file format is SHCL.") {
			t.Errorf("%s: default init output is missing the format footer", c.name)
		}
		// Valid SHCL, and not so much as a hint: a starter that hints on its own
		// first lines (H002 from a parent re-opened after another field) teaches
		// a reader to ignore them.
		doc := Parse(got)
		if len(doc.Diagnostics()) > 0 {
			t.Errorf("%s: generated starter does not load cleanly: %v", c.name, doc.Diagnostics())
		}
		// And it must satisfy the very schema that produced it - case 026's
		// golden once failed its own schema (repeat lower bound and a
		// materialized wildcard were ignored).
		vs := doc.Validate(Parse(c.initSchema))
		for _, d := range vs {
			if d.Severity == SeverityError {
				t.Errorf("%s: generated starter fails its own schema: %+v", c.name, vs)
				break
			}
		}
	})
}

// Go-only: nearly every name is already folded, and the helper used to copy the
// whole string into a byte slice before discovering it had nothing to change.
// Asserted as an allocation count rather than a time, since a constant-factor
// win has no wall-clock threshold that both fires and does not flake.
func TestAsciiLowerDoesNotCopyAFoldedName(t *testing.T) {
	defer testID(t, "EoXMm6a")
	var sink string
	folded := strings.Repeat("server-config-name-", 40)
	if n := testing.AllocsPerRun(200, func() { sink = asciiLower(folded) }); n != 0 {
		t.Errorf("asciiLower allocated %v time(s) on an already-folded name, want 0", n)
	}
	if sink != folded {
		t.Errorf("asciiLower changed an already-folded name")
	}
	mixed := strings.Repeat("Server-Config-Name-", 40)
	if got := asciiLower(mixed); got != folded {
		t.Errorf("asciiLower(mixed) = %q", got[:40])
	}
}

func TestSuppressLeavesTheCallersDiagnosticsAlone(t *testing.T) {
	defer testID(t, "EoaIuFU")
	// It returns a new list, which reads as a copy, so filtering the caller's
	// slice in place left the document's own diagnostics shuffled and
	// duplicated. The reference takes its list by reference, so the mutation is
	// expected there and not here.
	doc := Parse("unique: a\nunique: b\nnote: x\nnote: y\n")
	schema := Parse("field: unique\n\ttype: string\n\trepeat: [1, 9]\nfield: note\n\ttype: string\n")
	diags := doc.Diagnostics()
	if len(diags) < 2 {
		t.Fatalf("want two H001 hints to filter, got %d diagnostic(s)", len(diags))
	}
	before := append([]Diagnostic(nil), diags...)
	for _, filter := range []func(*Document, []Diagnostic) []Diagnostic{SuppressDeclaredRepeats, SuppressDeclaredReopens} {
		filter(schema, diags)
		if !reflect.DeepEqual(diags, before) {
			t.Fatalf("the caller's slice changed: %v, want %v", diags, before)
		}
	}
	// The filter has to be doing something, or the check above is vacuous.
	if len(SuppressDeclaredRepeats(schema, diags)) != 1 {
		t.Fatal("the filter dropped no hint, so nothing above was proved")
	}
	// The keep-everything path and Diagnostics() itself have to hand out
	// their own backing array too: shared with the document's, a caller's
	// append and the document's next append end up in the same slot.
	none := Parse("field: other\n")
	for name, kept := range map[string][]Diagnostic{
		"SuppressDeclaredRepeats": SuppressDeclaredRepeats(none, diags),
		"SuppressDeclaredReopens": SuppressDeclaredReopens(none, diags),
		"Diagnostics":             doc.Diagnostics(),
	} {
		if len(kept) != len(diags) {
			t.Fatalf("%s: want %d diagnostics kept, got %d", name, len(diags), len(kept))
		}
		if &kept[0] == &diags[0] || &kept[0] == &doc.diags[0] {
			t.Fatalf("%s: returned the caller's or the document's own backing array", name)
		}
	}
	// A failed strict load hands out the same list, and used to hand out the
	// document's own: writing through it changed what the document reports.
	_, err := ParseWith("a\n", Strict)
	var le *LoadError
	if !errors.As(err, &le) || len(le.Diagnostics) == 0 {
		t.Fatal("want a strict load failure with diagnostics")
	}
	le.Diagnostics[0].Message = "rewritten by the caller"
	if bad := le.Document.Diagnostics(); bad[0].Message == "rewritten by the caller" {
		t.Fatal("LoadError shares the document's diagnostics list")
	}
}

func TestConvenienceTierFallsBackOnlyOnGood(t *testing.T) {
	defer testID(t, "EkgmpQf")
	// Mirror of the reference: the *Or value survives only on Good; Empty,
	// BadType, and NotFound all yield the call-site fallback.
	d := Parse("a: 42\nb: not-a-number\ne:\narr: [1, 2, 3]\nblk:\n\t```html\n\thi\n\t```\n")
	if got := d.GetIntOr("a", 9); got != 42 {
		t.Fatalf("GetIntOr Good = %d, want 42", got)
	}
	for _, p := range []string{"b", "e", "missing"} {
		if got := d.GetIntOr(p, 9); got != 9 {
			t.Fatalf("GetIntOr(%q) = %d, want fallback 9", p, got)
		}
	}
	if got := d.GetIntArrayOr("arr", []int64{7}); len(got) != 3 || got[0] != 1 || got[2] != 3 {
		t.Fatalf("GetIntArrayOr Good = %v, want [1 2 3]", got)
	}
	if got := d.GetIntArrayOr("missing", []int64{7}); len(got) != 1 || got[0] != 7 {
		t.Fatalf("GetIntArrayOr missing = %v, want fallback [7]", got)
	}
	// The array status tier, the reduction the scalars already had: the whole
	// read's status beside the resolved values.
	if got, st := d.GetIntArray("arr"); st != Good || len(got) != 3 {
		t.Fatalf("GetIntArray(arr) = %v, %v", got, st)
	}
	if _, st := d.GetIntArray("missing"); st != NotFound {
		t.Fatalf("GetIntArray(missing) status = %v, want NotFound", st)
	}
	// The raw block's info-string was the one typed read with no convenience
	// tier, so it alone forced a caller down to the status tier.
	if got, st := d.GetRawInfo("blk"); st != Good || got != "html" {
		t.Fatalf("GetRawInfo(blk) = %q, %v", got, st)
	}
	if got := d.GetRawInfoOr("blk", "fb"); got != "html" {
		t.Fatalf("GetRawInfoOr Good = %q, want html", got)
	}
	if got := d.GetRawInfoOr("missing", "fb"); got != "fb" {
		t.Fatalf("GetRawInfoOr missing = %q, want fallback", got)
	}
	// Ok and the convenience tier deliberately disagree on an explicitly
	// emptied field: one asks whether the author spoke for it, the other whether
	// there is a usable value.
	if !d.ReadInt("e").Ok() {
		t.Error("an emptied field is not Ok")
	}
	if d.ReadInt("missing").Ok() {
		t.Error("a missing field is Ok")
	}
}

func TestReadsMatchExpected(t *testing.T) {
	defer testID(t, "EjsS8bB")
	eachCase(t, func(t *testing.T, c corpusCase) {
		for n, line := range strings.Split(c.reads, "\n") {
			if n == 0 || strings.TrimSpace(line) == "" {
				continue // header
			}
			cols := strings.Split(line, "\t")
			if len(cols) < 4 {
				t.Fatalf("%s: reads.tsv line %d too short", c.name, n+1)
			}
			query, kind, expected, status := cols[0], cols[1], cols[2], cols[3]
			level := Standard
			if len(cols) > 4 {
				level = parseLevel(t, cols[4])
			}
			at := fmt.Sprintf("%s: reads.tsv line %d (%s %s)", c.name, n+1, query, kind)

			if kind == "load" {
				_, err := ParseWith(c.input, level)
				ok := err == nil
				var want bool
				switch expected {
				case "ok":
					want = true
				case "fail":
					want = false
				default:
					t.Fatalf("%s: bad load expectation '%s'", at, expected)
				}
				if ok != want {
					t.Errorf("%s: load outcome: got ok=%t want ok=%t", at, ok, want)
				}
				continue
			}

			doc := docFor(t, &c, level)
			if kind == "schema" {
				got, ok := SchemaRef(c.input)
				if !ok {
					got = "-"
				}
				if got != expected {
					t.Errorf("%s: schema: got %q want %q", at, got, expected)
				}
				continue
			}
			if kind == "lost" {
				want, err := strconv.Atoi(expected)
				if err != nil {
					t.Fatalf("%s: bad lost count", at)
				}
				if got := doc.LostCount(); got != want {
					t.Errorf("%s: lost: got %d want %d", at, got, want)
				}
				continue
			}
			if kind == "count" {
				want, err := strconv.Atoi(expected)
				if err != nil {
					t.Fatalf("%s: bad count", at)
				}
				if got := doc.Count(query); got != want {
					t.Errorf("%s: count: got %d want %d", at, got, want)
				}
				// A status other than `-` pins the Read twin too.
				if r := doc.ReadCount(query); status != "-" && (r.Value != want || r.Status.String() != status) {
					t.Errorf("%s: ReadCount: got %d %v want %d %s", at, r.Value, r.Status, want, status)
				}
				continue
			}
			if kind == "instances" {
				if got := strings.Join(doc.Instances(query), "|"); got != expected {
					t.Errorf("%s: instances: got %q want %q", at, got, expected)
				}
				if r := doc.ReadInstances(query); status != "-" && (strings.Join(r.Value, "|") != expected || r.Status.String() != status) {
					t.Errorf("%s: ReadInstances: got %q %v want %q %s", at, r.Value, r.Status, expected, status)
				}
				continue
			}
			if kind == "children" {
				if got := strings.Join(doc.Children(query), "|"); got != expected {
					t.Errorf("%s: children: got %q want %q", at, got, expected)
				}
				if r := doc.ReadChildren(query); status != "-" && (strings.Join(r.Value, "|") != expected || r.Status.String() != status) {
					t.Errorf("%s: ReadChildren: got %q %v want %q %s", at, r.Value, r.Status, expected, status)
				}
				continue
			}
			if kind == "paths" {
				if got := strings.Join(doc.Paths(), "|"); got != expected {
					t.Errorf("%s: paths: got %q want %q", at, got, expected)
				}
				continue
			}
			if kind == "instance_paths" {
				if got := strings.Join(doc.InstancePaths(), "|"); got != expected {
					t.Errorf("%s: instance_paths: got %q want %q", at, got, expected)
				}
				continue
			}
			if kind == "comments" {
				if got := strings.Join(doc.Comments(query), "|"); got != expected {
					t.Errorf("%s: comments: got %q want %q", at, got, expected)
				}
				continue
			}

			var gotValue string
			var gotStatus Status
			var gotSlots []Status
			switch kind {
			case "int":
				r := doc.ReadInt(query)
				gotValue, gotStatus = strconv.FormatInt(r.Value, 10), r.Status
			case "float":
				r := doc.ReadFloat(query)
				gotValue, gotStatus = FormatFloat(r.Value), r.Status
			case "bool":
				r := doc.ReadBool(query)
				gotValue, gotStatus = strconv.FormatBool(r.Value), r.Status
			case "datetime":
				r := doc.ReadDateTime(query)
				gotValue, gotStatus = r.Value.String(), r.Status
			case "string":
				r := doc.ReadString(query)
				gotValue, gotStatus = tsvEscape(r.Value), r.Status
			case "raw":
				r := doc.ReadRaw(query)
				gotValue, gotStatus = tsvEscape(r.Value), r.Status
			case "rawinfo":
				r := doc.ReadRawInfo(query)
				gotValue, gotStatus = tsvEscape(r.Value), r.Status
			case "int[]":
				r := doc.ReadIntArray(query)
				gotSlots = r.Slots
				parts := make([]string, len(r.Value))
				for i, v := range r.Value {
					parts[i] = strconv.FormatInt(v, 10)
				}
				gotValue, gotStatus = strings.Join(parts, "|"), r.Status
			case "float[]":
				r := doc.ReadFloatArray(query)
				gotSlots = r.Slots
				parts := make([]string, len(r.Value))
				for i, v := range r.Value {
					parts[i] = FormatFloat(v)
				}
				gotValue, gotStatus = strings.Join(parts, "|"), r.Status
			case "bool[]":
				r := doc.ReadBoolArray(query)
				gotSlots = r.Slots
				parts := make([]string, len(r.Value))
				for i, v := range r.Value {
					parts[i] = strconv.FormatBool(v)
				}
				gotValue, gotStatus = strings.Join(parts, "|"), r.Status
			case "datetime[]":
				r := doc.ReadDateTimeArray(query)
				gotSlots = r.Slots
				parts := make([]string, len(r.Value))
				for i, v := range r.Value {
					parts[i] = v.String()
				}
				gotValue, gotStatus = strings.Join(parts, "|"), r.Status
			case "string[]":
				r := doc.ReadStringArray(query)
				gotSlots = r.Slots
				parts := make([]string, len(r.Value))
				for i, v := range r.Value {
					parts[i] = tsvEscape(v)
				}
				gotValue, gotStatus = strings.Join(parts, "|"), r.Status
			default:
				if !strings.HasPrefix(kind, "duration") && !strings.HasPrefix(kind, "size") {
					t.Fatalf("%s: unknown type '%s'", at, kind)
				}
				base, unit, decimal := unitType(kind)
				if base == "duration" {
					u, ok := DurationUnitFromSpelling(unit)
					if unit != "" && !ok {
						t.Fatalf("%s: bad duration unit %q", at, unit)
					}
					r := doc.ReadDuration(query, u)
					gotValue, gotStatus = strconv.FormatInt(r.Value.Milliseconds(), 10), r.Status
				} else {
					u, ok := SizeUnitFromSpelling(unit)
					if unit != "" && !ok {
						t.Fatalf("%s: bad size unit %q", at, unit)
					}
					r := doc.ReadSize(query, u, decimal)
					gotValue, gotStatus = strconv.FormatInt(r.Value, 10), r.Status
				}
			}
			if gotStatus.String() != status {
				t.Errorf("%s: status: got %s want %s", at, gotStatus, status)
			}
			if expected != "-" && gotValue != expected {
				t.Errorf("%s: value: got %q want %q", at, gotValue, expected)
			}
			// Optional 6th column: per-slot statuses, |-joined (needs col 5 set).
			if len(cols) > 5 {
				parts := make([]string, len(gotSlots))
				for i, st := range gotSlots {
					parts[i] = st.String()
				}
				if got := strings.Join(parts, "|"); got != cols[5] {
					t.Errorf("%s: slots: got %q want %q", at, got, cols[5])
				}
			}
		}
	})
}

func TestPathsEnumerationShape(t *testing.T) {
	defer testID(t, "El5WdwX")
	// Paths(): file order, deduplicated, non-bare segments quoted so every
	// path resolves. Same fixture is pinned in every runner.
	doc := Parse("a: 1\na.b: 2\n\"q n\": 3\nx:\n\tb: 4\nx.b: 5\n")
	got := doc.Paths()
	want := []string{"a", "a.b", "\"q n\"", "x", "x.b"}
	if len(got) != len(want) {
		t.Fatalf("paths: got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("paths: got %v want %v", got, want)
		}
	}
	for _, p := range got {
		if doc.Count(p) < 1 {
			t.Fatalf("emitted path does not resolve: %s", p)
		}
	}
	// QuoteSegment: same spelling both directions, injection-safe.
	if QuoteSegment("port") != "port" || QuoteSegment("q n") != "\"q n\"" || QuoteSegment("a.b") != "\"a.b\"" {
		t.Fatalf("QuoteSegment spelling drift")
	}
	if r := doc.ReadInt(QuoteSegment("q n")); r.Value != 3 || r.Status != Good {
		t.Fatalf("quoted segment read: %v %v", r.Value, r.Status)
	}
}

// setterSoup is the alphabet the setter round-trip fixture draws from: every
// character that means something to the tokenizer, plus a blank the load trims
// and a no-break space it does not. Same fixture in every runner, except the
// last entry: a Go string can hold bytes that are not UTF-8, which Rust cannot
// hold, Python refuses at save and C leaves to its caller.
var setterSoup = []string{"\"", "'", "\\", "#", ",", "[", "]", "\r", "\n", " ", "\t", "\u00a0", "a", "\xff"}

// soupInputs is every string of one and two characters over that alphabet, and
// the empty string.
func soupInputs() []string {
	out := []string{""}
	for _, a := range setterSoup {
		out = append(out, a)
		for _, b := range setterSoup {
			out = append(out, a+b)
		}
	}
	return out
}

// Digits past 32 bits are not a 2.x file either, so they read as the current
// major, in every binding (20260926 item 9).
func TestFormatVersionCapsAt32Bits(t *testing.T) {
	defer testID(t, "Er7vwJ6")
	if v, ok := FormatVersion("##    Format   4294967295\na: 1\n"); !ok || v != 4294967295 {
		t.Errorf("4294967295 read as %d", v)
	}
	if v, ok := FormatVersion("##    Format   4294967296\na: 1\n"); !ok || v != FormatMajor {
		t.Errorf("4294967296 read as %d", v)
	}
}

// TestStampReadsSayWhy: the Format and Schema lines read with a status, so an
// unstamped file and a damaged stamp read apart, and the load's H006 and H007
// hints say the same as the Format read on every row. Rust's
// stamp_reads_say_why has the same rows.
func TestStampReadsSayWhy(t *testing.T) {
	defer testID(t, "EsEtTdQ")
	formats := []struct {
		text   string
		value  int
		status Status
		line   int
		hint   string
	}{
		{"a: 1\n", 0, NotFound, 0, ""},
		{"a: 1\n##    Format   3\n", 3, Good, 2, ""},
		{"##    Format   4\na: 1\n", 4, Good, 1, "H006"},
		{"a: 1\n##    Format   2\n", 2, Good, 2, "H007"},
		{"a: 1\n##    Format   3x\n", 0, BadType, 2, ""},
		{"a: 1\n##    Format\n", 0, Empty, 2, ""},
		{"a: 1\n##    Format   \n", 0, Empty, 2, ""},
		{"##    Format   x\n##    Format   2\n", 2, Good, 2, "H007"},
		{"note: ~~~\n##    Format   4\n~~~\n", 0, NotFound, 0, ""},
		{"a: 1\n##    Format  3\n", 0, NotFound, 0, ""},
		{"\ufeff##    Format   5\n", 5, Good, 1, "H006"},
		{"##    Format   4294967296\n", FormatMajor, Good, 1, ""},
		{"a:\n\t##    Format   1\n\tb: 1\n", 1, Good, 2, "H007"},
	}
	for _, c := range formats {
		r := ReadFormatVersion(c.text)
		if r.Value != c.value || r.Status != c.status || r.Line != c.line {
			t.Errorf("%q: read %d %v line %d", c.text, r.Value, r.Status, r.Line)
		}
		if v, ok := FormatVersion(c.text); ok != (c.status == Good) || v != c.value {
			t.Errorf("%q: FormatVersion gave %d %v", c.text, v, ok)
		}
		var got []string
		for _, d := range Parse(c.text).Diagnostics() {
			if d.Code == "H006" || d.Code == "H007" {
				got = append(got, fmt.Sprintf("%s@%d", d.Code, d.Line))
			}
		}
		want := ""
		if c.hint != "" {
			want = fmt.Sprintf("%s@%d", c.hint, c.line)
		}
		if strings.Join(got, ",") != want {
			t.Errorf("%q: hints %v, want %q", c.text, got, want)
		}
	}
	schemas := []struct {
		text   string
		value  string
		status Status
		line   int
	}{
		{"a: 1\n", "", NotFound, 0},
		{"##    Schema   ./s.shcl\n", "./s.shcl", Good, 1},
		{"##    Schema\na: 1\n", "", Empty, 1},
		{"##    Schema   \n##    Schema   b.shcl\n", "b.shcl", Good, 2},
		{"x: ~~~\n##    Schema   a\n~~~\n", "", NotFound, 0},
	}
	for _, c := range schemas {
		r := ReadSchemaRef(c.text)
		if r.Value != c.value || r.Status != c.status || r.Line != c.line {
			t.Errorf("%q: read %q %v line %d", c.text, r.Value, r.Status, r.Line)
		}
		if v, ok := SchemaRef(c.text); ok != (c.status == Good) || v != c.value {
			t.Errorf("%q: SchemaRef gave %q %v", c.text, v, ok)
		}
	}
}

// TestSettersWriteOnlyWhatReadsBack: a setter writes only what reads back. Each
// one builds its text through the emitter and hands it to the tokenizer before
// the document is touched, so for every input either the call refuses and the
// document is byte-identical, or the canonical text reloads to itself and the
// read gives the value back. Twelve review items were one setter's own trim,
// carriage-return or `#` rule disagreeing with the parser's. Every accepted
// write also goes into one document that is saved and loaded back at the end,
// since the file tier checks what an in-memory reload does not: a setter once
// took bytes the save wrote and the next load refused. Same fixture in every
// runner.
func TestSettersWriteOnlyWhatReadsBack(t *testing.T) {
	defer testID(t, "EpGigIM")
	all := Parse("")
	slot := 0
	for _, s := range soupInputs() {
		for kind := 0; kind < 6; kind++ {
			doc := Parse("k: 1\n")
			before := doc.ToCanonical()
			set := func(d *Document, p string) SetStatus {
				switch kind {
				case 0:
					return d.SetString(p, s)
				case 1:
					return d.SetLiteral(p, s)
				case 2:
					return d.SetComment(p, s)
				case 3:
					return d.SetRaw(p, s, "t")
				case 4:
					return d.SetRaw(p, "body", s)
				}
				return d.SetStringArray(p, []string{"x", s})
			}
			applied := set(doc, "k") == SetOk
			if applied {
				slot++
				if set(all, "k"+strconv.Itoa(slot)) != SetOk {
					t.Fatalf("slot %d refused what k took (setter %d, input %q)", slot, kind, s)
				}
			}
			if !applied {
				if doc.ToCanonical() != before {
					t.Fatalf("a refused write changed the document (setter %d, input %q)", kind, s)
				}
				continue
			}
			text := doc.ToCanonical()
			back := Parse(text)
			if back.ToCanonical() != text {
				t.Fatalf("written text is not a fixpoint (setter %d, input %q):\n%s", kind, s, text)
			}
			if !reflect.DeepEqual(back.Instances("k"), doc.Instances("k")) {
				t.Fatalf("the value read differs after a reload (setter %d, input %q):\n%s", kind, s, text)
			}
			switch kind {
			case 0:
				if r := back.ReadString("k"); r.Value != s {
					t.Fatalf("string %q: got %q", s, r.Value)
				}
			case 2:
				// A comment has no accessor of its own, so the oracle is the
				// text: whatever the load would keep of what was handed in has
				// to be in the document, not a shortened form of it.
				if !strings.Contains(text, strings.TrimRight(s, " \t\r")) {
					t.Fatalf("the comment handed in is not in the document (%q):\n%s", s, text)
				}
			case 3, 4:
				bv, bs := back.GetRaw("k")
				dv, ds := doc.GetRaw("k")
				if bv != dv || bs != ds {
					t.Fatalf("raw body %q: got %q %v, want %q %v", s, bv, bs, dv, ds)
				}
				if back.ReadRawInfo("k").Value != doc.ReadRawInfo("k").Value {
					t.Fatalf("raw info %q: got %q", s, back.ReadRawInfo("k").Value)
				}
			case 5:
				if got := back.ReadStringArray("k").Value; !reflect.DeepEqual(got, []string{"x", s}) {
					t.Fatalf("array %q: got %q", s, got)
				}
			}
		}
		// The same rule for a name: whatever QuoteSegment writes has to come
		// back as one segment holding that name, or the write is refused.
		path := QuoteSegment(s)
		doc := Parse("k: 1\n")
		before := doc.ToCanonical()
		applied := doc.SetString(path, "v") == SetOk
		if applied && all.SetString(path, "v") != SetOk {
			t.Fatalf("the name %q was refused the second time", s)
		}
		if !applied {
			if doc.ToCanonical() != before {
				t.Fatalf("a refused name write changed the document (%q)", s)
			}
			continue
		}
		text := doc.ToCanonical()
		back := Parse(text)
		if back.ToCanonical() != text {
			t.Fatalf("name %q is not a fixpoint:\n%s", s, text)
		}
		if r := back.ReadString(path); r.Value != "v" {
			t.Fatalf("name %q did not read back:\n%s", s, text)
		}
	}
	f := filepath.Join(t.TempDir(), "all.shcl")
	if err := all.SaveFile(f); err != nil {
		t.Fatalf("every accepted write together would not save: %v", err)
	}
	back, st := LoadFile(f)
	if st != FileClean {
		t.Fatalf("every accepted write together loaded %v", st)
	}
	if back.ToCanonical() != all.ToCanonical() {
		t.Fatalf("every accepted write together changed on a save and load")
	}
}

// A setter's status agrees with CheckSetPath over the setter soup: a path
// reason is what CheckSetPath gives for that path, a value reason comes with a
// path that checks Ok, and a refusal writes nothing. Rust runs the same
// property over its structural fuzz soup (EsDRhJo); Go has no fuzz harness,
// so the soup is the setter alphabet, through the value and the path both.
func TestSetterStatusAgreesWithThePathCheck(t *testing.T) {
	defer testID(t, "EsDemw3")
	text := "a:\n\tb: 1\nports: [80, 443]\nsec:\n\tx: 1\nport: 1\nport: 2\n"
	pathReasons := map[SetStatus]bool{
		SetBadPath:     true,
		SetValueInPath: true,
		SetWildcard:    true,
		SetNoSuchIndex: true,
		SetTooDeep:     true,
		SetMultiple:    true,
		SetUnderArray:  true,
	}
	seen := map[SetStatus]bool{}
	step := 0
	for _, v := range soupInputs() {
		paths := []string{"a.b", "new.k", "a.b.kid", "a(*).b", "a(7).b", "a..x", "port", "ports.x", "sec", "sec.x", "a.b: 1", QuoteSegment(v) + ".k", "a(" + v + ").k"}
		for _, path := range paths {
			doc := Parse(text)
			checked := doc.CheckSetPath(path)
			before := doc.ToCanonical()
			op := step % 10
			step++
			var got SetStatus
			switch op {
			case 0:
				got = doc.SetInt(path, 7)
			case 1:
				got = doc.SetString(path, v)
			case 2:
				got = doc.SetLiteral(path, v)
			case 3:
				got = doc.SetComment(path, v)
			case 4:
				got = doc.SetRaw(path, v, v)
			case 5:
				got = doc.SetIntArray(path, []int64{1, 2})
			case 6:
				f := 1.5
				if len(v)%2 == 0 {
					f = math.NaN()
				}
				got = doc.SetFloat(path, f)
			case 7:
				got = doc.SetLiteralDefault(path, v)
			case 8:
				got = doc.SetIntArrayDefault(path, []int64{3})
			default:
				got = doc.SetEmpty(path)
			}
			seen[got] = true
			want := SetOk
			if pathReasons[got] {
				want = got
			}
			if checked != want {
				t.Fatalf("op %d at %q with %q gave %v, CheckSetPath %v", op, path, v, got, checked)
			}
			if got != SetOk && doc.ToCanonical() != before {
				t.Fatalf("op %d at %q with %q gave %v and wrote", op, path, v, got)
			}
		}
	}
	// Guard: the soup still reaches path and value reasons both.
	for _, want := range []SetStatus{SetOk, SetBadPath, SetValueInPath, SetWildcard, SetNoSuchIndex, SetMultiple, SetUnderArray, SetHasChildren, SetNotFinite, SetBadRawInfo, SetBadRawBody, SetBadComment, SetNotOneValue, SetNotUtf8} {
		if !seen[want] {
			t.Errorf("never saw %v", want)
		}
	}
}

// seqGen is the sequence fixture's generator: xorshift64* on a fixed seed, so
// every runner builds the same documents and the same steps.
type seqGen struct{ s uint64 }

func (g *seqGen) below(n int) int {
	x := g.s
	x ^= x >> 12
	x ^= x << 25
	x ^= x >> 27
	g.s = x
	return int((x * 0x2545F4914F6CDD1D) % uint64(n))
}

var seqNames = []string{"a", "b", "m"}

// doc builds a small document out of the lines that have comments and blanks
// somewhere a later step can move them: comments at every depth, empty and
// reopened blocks, a same-line fence with a comment after an empty binding, and
// misplaced lines kept as written, one of them among a list's elements.
func (g *seqGen) doc() string {
	var out strings.Builder
	depth := 0
	for n := 1 + g.below(10); n > 0; n-- {
		switch g.below(6) {
		case 0:
			depth = 0
		case 1:
			if depth > 0 {
				depth--
			}
		case 2:
			if depth < 3 {
				depth++
			}
		}
		ind := strings.Repeat("\t", depth)
		name := seqNames[g.below(3)]
		switch g.below(10) {
		case 0:
			out.WriteString(ind + "# c" + strconv.Itoa(g.below(3)))
		case 1:
		case 2:
			out.WriteString(ind + name + ":")
		case 3:
			out.WriteString(ind + name + ": " + strconv.Itoa(g.below(3)))
		case 4:
			out.WriteString(ind + name + ": ```x  # t\n" + ind + "\tbody\n" + ind + "\t```")
		case 5:
			out.WriteString(ind + name + ": " + strconv.Itoa(g.below(3)) + "  # t")
		case 6:
			out.WriteString(ind + name + "." + name + ": 1")
		case 7:
			out.WriteString(ind + " " + name + ": " + strconv.Itoa(g.below(3)))
		case 8:
			out.WriteString(ind + name + ":\n" + ind + "\t- 1\n" + ind + " x: 1\n" + ind + "\t- 2")
		default:
			out.WriteString(ind + "\t# deep")
		}
		out.WriteString("\n")
	}
	return out.String()
}

// noNewErrors: every error code text loads with, base loaded with at least as
// often.
func noNewErrors(text, base string) bool {
	count := map[string]int{}
	for _, d := range Parse(base).Diagnostics() {
		if d.Severity == SeverityError {
			count[d.Code]++
		}
	}
	for _, d := range Parse(text).Diagnostics() {
		if d.Severity == SeverityError {
			count[d.Code]--
			if count[d.Code] < 0 {
				return false
			}
		}
	}
	return true
}

// keepsEveryLine: on a base that loads clean, a new field saved with the lines
// kept writes every line of the base that is not blank, in order. A repeat the
// load folded away comes back too (20260925c item 1). A kept misplaced line is
// left out, since it turns into a comment once a new field above it would take
// it as a child.
func keepsEveryLine(base string) bool {
	doc, _ := ParseKeepLines(base, Standard)
	for _, d := range doc.Diagnostics() {
		if d.Severity == SeverityError {
			return true
		}
	}
	if doc.SetInt("zz_new", 1) != SetOk {
		return true
	}
	text, kept := doc.ToTextKeepLines()
	if !kept {
		return true
	}
	rest := strings.Split(text, "\n")
	for _, l := range strings.Split(base, "\n") {
		if strings.TrimSpace(l) == "" {
			continue
		}
		for len(rest) > 0 && rest[0] != l {
			rest = rest[1:]
		}
		if len(rest) == 0 {
			return false
		}
		rest = rest[1:]
	}
	return true
}

// TestEditsAndMergesMatchAReload: a merge or an edit leaves the document its own
// saved text reloads as, comments included, so the next step comes out the same
// whether or not the file was saved in between. Comments were filed one way by
// a load and another by a merge, a new child or the writer's fold three times
// in three days, and the text fixpoint cannot see it, since both placements
// are fixpoints. Same fixture in every runner.
func TestEditsAndMergesMatchAReload(t *testing.T) {
	defer testID(t, "Eqk24na")
	g := seqGen{s: 0x5EED0923C0DE0003}
	for i := 0; i < 3000; i++ {
		base := g.doc()
		live, _ := ParseKeepLines(base, Standard)
		log := "base:\n" + base
		if !keepsEveryLine(base) {
			t.Fatalf("a new field moved or dropped a line at iteration %d:\n%s", i, log)
		}
		for steps := 2 + g.below(3); steps > 0; steps-- {
			back := Parse(live.ToCanonical())
			paths := live.Paths()
			var path string
			if len(paths) == 0 || g.below(3) == 0 {
				path = seqNames[g.below(3)] + "." + seqNames[g.below(3)]
			} else {
				path = paths[g.below(len(paths))]
			}
			v := "v" + strconv.Itoa(g.below(3))
			op := g.below(11)
			layer := g.doc()
			for _, d := range []*Document{live, back} {
				switch op {
				case 0, 1:
					d.Merge(Parse(layer))
				case 2:
					d.SetInt(path, 7)
				case 3:
					d.SetString(path, v)
				case 4:
					d.Remove(path)
				case 5:
					d.SetComment(path, v)
				case 6:
					d.SetEmpty(path)
				case 7:
					d.SetRaw(path, "body", v)
				case 8:
					d.SetIntDefault(path, 1)
				case 9:
					d.ClearComments(path)
				default:
					d.SetBanner(v != "v0")
				}
			}
			if op <= 1 {
				log += "merge:\n" + layer
			} else {
				log += fmt.Sprintf("op %d at %q\n", op, path)
			}
			if listAfterEmpty(live) {
				if live.LostCount() == 0 {
					t.Fatalf("a list no text loads back saves at iteration %d:\n%s", i, log)
				}
				break
			}
			if a, b := live.ToCanonical(), back.ToCanonical(); a != b && !((op == 4 || op == 9) && reloadTookOnlyComments(a, b)) {
				t.Fatalf("a step on the document and on its reload differ at iteration %d:\n%s--- live\n%s--- reload\n%s", i, log, a, b)
			}
			// The save that keeps lines reloads as the document with no error
			// the base did not have, or is its canonical form.
			if text, kept := live.ToTextKeepLines(); kept && Parse(text).ToCanonical() != live.ToCanonical() {
				t.Fatalf("kept lines reload as another document at iteration %d:\n%s--- wrote\n%s", i, log, text)
			} else if kept && !noNewErrors(text, base) {
				t.Fatalf("kept lines load with a new error at iteration %d:\n%s--- wrote\n%s", i, log, text)
			} else if kept && Parse(text).LostCount() != Parse(base).LostCount() {
				// Every line the load dropped went out as written (20260926
				// item 1).
				t.Fatalf("kept lines lost a dropped line at iteration %d:\n%s--- wrote\n%s", i, log, text)
			} else if !kept && text != live.ToCanonical() {
				t.Fatalf("a save that kept no lines is not canonical at iteration %d:\n%s", i, log)
			}
		}
	}
}

// listAfterEmpty: a list with a field under it (E001) after an empty binding
// of its name that has fields of its own. A merge or an edit can leave one,
// and then no text reloads as it: stacked, its header joins that binding and
// its items are dropped (E008), and in brackets it is E028
// (2026100511210900). The save gate counts its items lost, so it is never
// written; the fixture checks that and skips the rest.
func listAfterEmpty(doc *Document) bool {
	for _, p := range doc.InstancePaths() {
		r := doc.ReadString(p)
		if len(doc.Children(p)) == 0 || r.Status != Good || r.Quoted || !strings.HasPrefix(r.Value, "[") {
			continue
		}
		if !strings.HasSuffix(p, ")") {
			continue
		}
		open := strings.LastIndex(p, "(")
		if open < 0 {
			continue
		}
		k, err := strconv.Atoi(p[open+1 : len(p)-1])
		if err != nil {
			continue
		}
		for j := 0; j < k; j++ {
			e := p[:open] + "(" + strconv.Itoa(j) + ")"
			if doc.ReadString(e).Status == Empty && len(doc.Children(e)) != 0 {
				return true
			}
		}
	}
	return false
}

// reloadTookOnlyComments: a kept line the settle turned into a comment is
// still the user's line, so ClearComments and a remove beside it leave it
// (design.md, Kept lines under edits). The canonical text writes it as a
// comment, and the reload takes it like one, so the two cannot agree
// (20260926 item 2). True when that is all that differs: the reload's comment
// lines are some of the document's, in order, and without comment and blank
// lines the two load as one document. A comment the reload took can also
// take a blank with it, step the comments after it back a level, or leave a
// kept line heading the block below, so the rest is compared as documents. A
// check of the target's comments missed one below the target
// (2026100506223902).
func reloadTookOnlyComments(live, back string) bool {
	comment := func(l string) bool { return strings.HasPrefix(strings.TrimLeft(l, "\t"), "#") }
	var have []string
	for _, l := range strings.Split(live, "\n") {
		if comment(l) {
			have = append(have, strings.TrimLeft(l, "\t"))
		}
	}
	for _, l := range strings.Split(back, "\n") {
		if !comment(l) {
			continue
		}
		for len(have) > 0 && have[0] != strings.TrimLeft(l, "\t") {
			have = have[1:]
		}
		if len(have) == 0 {
			return false
		}
		have = have[1:]
	}
	bare := func(text string) string {
		var rest strings.Builder
		for _, l := range strings.Split(text, "\n") {
			if l != "" && !comment(l) {
				rest.WriteString(l + "\n")
			}
		}
		return Parse(rest.String()).ToCanonical()
	}
	return bare(live) == bare(back)
}

// The issue's steps, which the fuzz reached with the value syntax: the setter
// comments out `a: [1` and makes `a` with the lines under it, and the new `c`
// goes between the kept line and the settled one, so the settled line sits
// below it. The remove leaves it there. The reload reads a plain comment and
// takes it with the field.
func TestARemoveKeepsASettledLineBelowIt(t *testing.T) {
	defer testID(t, "ErpmA2G")
	live := Parse("a: [1\n\t\t\": \n\t d-: 2\n\te: 3\n")
	if n := live.ClearComments("a.d"); n != 0 {
		t.Fatalf("cleared %d", n)
	}
	if live.SetEmpty("a.c") != SetOk || live.SetRaw("b.c", "body", "v0") != SetOk {
		t.Fatalf("a setter refused")
	}
	back := Parse(live.ToCanonical())
	if live.Remove("a.c") != 1 || back.Remove("a.c") != 1 {
		t.Fatalf("a remove missed")
	}
	a, b := live.ToCanonical(), back.ToCanonical()
	if !strings.Contains(a, "\n\t\":\n\t# d-: 2\n\nb:\n") {
		t.Fatalf("the document wrote %q", a)
	}
	if !strings.Contains(b, "\n\t\":\n\nb:\n") {
		t.Fatalf("the reload wrote %q", b)
	}
	if !reloadTookOnlyComments(a, b) || reloadTookOnlyComments(b, a) {
		t.Fatalf("reloadTookOnlyComments got it wrong:\n%s---\n%s", a, b)
	}
}

// The save gate on kept lines, from inside: once the edits that lose one are
// fixed, no public call reaches the gate, so these take a line out by hand.
const keptGateBase = "x: 1\nr: [1, 2\ny: 3\n"

func childNamed(d *Document, name string) int {
	for _, c := range d.arena[root].children {
		if d.arena[c].name == name {
			return c
		}
	}
	return -1
}

func TestAKeptLineGoneFromTheTreeRefusesTheSave(t *testing.T) {
	defer testID(t, "EreUzvf")
	doc, err := ParseKeepLines(keptGateBase, Standard)
	if err != nil {
		t.Fatal(err)
	}
	if n := doc.LostCount(); n != 0 {
		t.Fatalf("lost %d before the edit", n)
	}
	tv := doc.arena[childNamed(doc, "y")].trivMut()
	gone := tv.leading[len(tv.leading)-1]
	tv.leading = tv.leading[:len(tv.leading)-1]
	if !gone.isKeptLine() {
		t.Fatalf("not a kept line: %+v", gone)
	}
	if n := doc.LostCount(); n != 1 {
		t.Fatalf("LostCount %d, want 1", n)
	}
	if _, kept := doc.ToTextKeepLines(); kept {
		t.Fatal("the keep save kept lines with one gone")
	}
	path := filepath.Join(t.TempDir(), "f.shcl")
	if err := os.WriteFile(path, []byte(keptGateBase), 0o644); err != nil {
		t.Fatal(err)
	}
	var refused *SaveRefused
	if err := doc.SaveFile(path); !errors.As(err, &refused) || refused.Lost != 1 {
		t.Fatalf("SaveFile: %v", err)
	}
	if want := path + ": refusing to save: this write would delete 1 line(s)/value(s) from the file (see diagnostics; SaveFileLossy overrides)"; refused.Error() != want {
		t.Fatalf("SaveFile said %q, want %q", refused.Error(), want)
	}
	if _, err := doc.SaveFileKeepLines(path); !errors.As(err, &refused) || refused.Lost != 1 {
		t.Fatalf("SaveFileKeepLines: %v", err)
	}
	if b, _ := os.ReadFile(path); string(b) != keptGateBase {
		t.Fatalf("file changed: %q", b)
	}
}

// design.md's table: a remove takes the kept line written as the field's own
// line, and nothing beside it.
func TestARemoveTakesTheKeptLineHeadingItsField(t *testing.T) {
	defer testID(t, "EreUzxY")
	doc := Parse("a: [1\n\tb: 2\ny: 3\n")
	if n := doc.Remove("a"); n != 1 {
		t.Fatalf("removed %d", n)
	}
	if n := doc.LostCount(); n != 0 {
		t.Fatalf("LostCount %d, want 0", n)
	}
	if got := doc.ToCanonical(); got != "y: 3\n" {
		t.Fatalf("wrote %q", got)
	}
}

type removeCase struct{ text, path, want string }

func checkRemoves(t *testing.T, cases []removeCase) {
	t.Helper()
	for _, c := range cases {
		doc := Parse(c.text)
		if n := doc.Remove(c.path); n != 1 {
			t.Fatalf("%q: removed %d", c.text, n)
		}
		if n := doc.LostCount(); n != 0 {
			t.Fatalf("%q: LostCount %d, want 0", c.text, n)
		}
		out := doc.ToCanonical()
		if out != c.want {
			t.Fatalf("%q: wrote %q, want %q", c.text, out, c.want)
		}
		if back := Parse(out).ToCanonical(); back != out {
			t.Fatalf("%q: reload wrote %q", c.text, back)
		}
	}
}

// design.md's table: a remove leaves the kept lines beside its target, above
// or below it, with the comments above them (2026100307163901).
func TestARemoveLeavesTheKeptLinesBesideIt(t *testing.T) {
	defer testID(t, "ErgTocq")
	checkRemoves(t, []removeCase{
		{keptGateBase, "y", "x: 1\nr: [1, 2\n"},
		{"x: 1\nbad name: 1\ny: 3\n", "y", "x: 1\nbad name: 1\n"},
		{"j:\n\tr: [1\n\tq: 1\nz: 2\n", "j.q", "j:\n\tr: [1\nz: 2\n"},
		{"j:\n\tq: 1\n\tr: [1\nz: 2\n", "j.q", "j:\n\tr: [1\nz: 2\n"},
		{"j:\n\tq: 1\n\tr: [1\n\tw: 3\nz: 2\n", "j.q", "j:\n\tr: [1\n\tw: 3\nz: 2\n"},
		{"# on r\nr: [1\n# on y\ny: 3\nz: 1\n", "y", "# on r\nr: [1\nz: 1\n"},
	})
}

// A field opened only by the lines under it goes with the last of them, and
// its kept line stays (escblock; 2026100307163907).
func TestAFieldOpenedByAKeptLineGoesWithItsLastLine(t *testing.T) {
	defer testID(t, "ErgToef")
	checkRemoves(t, []removeCase{
		{"a: [1\n\tb: 2\ny: 3\n", "a.b", "a: [1\ny: 3\n"},
		{"a: [1\n\tb: 2\n\tc: 3\ny: 3\n", "a.b", "a: [1\n\tc: 3\ny: 3\n"},
		{"a: [1\n\tb: 2\n\tr: [3\ny: 3\n", "a.b", "a: [1\n\tr: [3\ny: 3\n"},
		{"o: [9\n\ta: [1\n\t\tb: 2\ny: 3\n", "o.a.b", "o: [9\n\ta: [1\ny: 3\n"},
		{"o:\n\ta: [1\n\t\tb: 2\n", "o.a.b", "o:\n\ta: [1\n"},
	})
}

// A setter on a field a kept line opened writes that line as a comment with
// a note, so the file has one line for the field (2026100307163907).
func TestASetterCommentsOutTheKeptLineHeadingItsTarget(t *testing.T) {
	defer testID(t, "Erlf124")
	t.Setenv("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT")
	for _, c := range []struct{ text, path, want string }{
		{"a: [1\n\tb: 2\ny: 3\n", "a",
			"# a: [1  ## commented out by shcl when setting a, 2026-10-04 00:15:00 PDT: E019 malformed array, no closing ']' on the line\na: 5\n\tb: 2\ny: 3\n"},
		{"o:\n\ta: \"x◉Q◉\"\n\t\tb: 2\n", "o.a",
			"o:\n\t# a: \"x◉Q◉\"  ## commented out by shcl when setting o.a, 2026-10-04 00:15:00 PDT: E023 unknown escape '◉Q◉'\n\ta: 5\n\t\tb: 2\n"},
		{"p: host: a.com\n\tq: 1\n", "p",
			"# p: host: a.com  ## commented out by shcl when setting p, 2026-10-04 00:15:00 PDT: E025 a colon then a space in a bare value\np: 5\n\tq: 1\n"},
		{"r: \"open\n\tq: 1\n", "r",
			"# r: \"open  ## commented out by shcl when setting r, 2026-10-04 00:15:00 PDT: E017 unterminated quote in value\nr: 5\n\tq: 1\n"},
		{"404: x\n\tq: 1\n", "\"404\"",
			"# 404: x  ## commented out by shcl when setting \"404\", 2026-10-04 00:15:00 PDT: E014 field name needs quotes\n\"404\": 5\n\tq: 1\n"},
	} {
		doc, _ := ParseKeepLines(c.text, Standard)
		if doc.SetInt(c.path, 5) != SetOk {
			t.Fatalf("%q: SetInt refused", c.text)
		}
		if n := doc.LostCount(); n != 0 {
			t.Fatalf("%q: LostCount %d", c.text, n)
		}
		out := doc.ToCanonical()
		if out != c.want {
			t.Fatalf("%q wrote\n%q\nwant\n%q", c.text, out, c.want)
		}
		back := Parse(out)
		if len(back.Diagnostics()) != 0 || back.Count(c.path) != 1 || back.ToCanonical() != out {
			t.Fatalf("%q: reload of %q differs", c.text, out)
		}
		if keep, kept := doc.ToTextKeepLines(); keep != out || !kept {
			t.Fatalf("%q: keep save %q %v", c.text, keep, kept)
		}
	}
	// Only the field the kept line opened: a child of it, or a field beside
	// a kept line, leaves the line as it was.
	for _, c := range []struct{ path, want string }{
		{"a.c", "a: [1\n\tb: 2\n\tc: 5\n"},
		{"z", "a: [1\n\tb: 2\n\nz: 5\n"},
	} {
		doc := Parse("a: [1\n\tb: 2\n")
		if doc.SetInt(c.path, 5) != SetOk || doc.ToCanonical() != c.want {
			t.Fatalf("%s: wrote %q", c.path, doc.ToCanonical())
		}
	}
}

// A setter writing `a` writes every kept line named `a` in that block as the
// noted comment, and a field it creates goes right under the first of them,
// so a later hand fix never gives Multiple (2026100307163907).
func TestASetterCommentsOutEveryKeptLineOfItsName(t *testing.T) {
	defer testID(t, "ErmXhpm")
	t.Setenv("SHCL_TEST_CLOCK", "2026-10-04 00:15:00 -420 PDT")
	note := func(path string) string {
		return "  ## commented out by shcl when setting " + path + ", 2026-10-04 00:15:00 PDT: E019 malformed array, no closing ']' on the line"
	}
	na, noa, nac := note("a"), note("o.a"), note("a.c")
	for _, c := range []struct {
		text, path, want string
		count            int
	}{
		// No loaded `a`: the new line goes under the first comment.
		{"a: [1\ny: 3\n", "a", "# a: [1" + na + "\na: 5\ny: 3\n", 1},
		{"x: 1\na: [1\ny: 3\na: [2\n", "a", "x: 1\n# a: [1" + na + "\na: 5\ny: 3\n# a: [2" + na + "\n", 1},
		// What was under the line goes under the new one.
		{"a: [1\n\t# under\n\tb: [2\ny: 3\n", "a", "# a: [1" + na + "\na: 5\n\t# under\n\tb: [2\ny: 3\n", 1},
		// At the end of a block.
		{"o:\n\tx: 1\n\ta: [1\n", "o.a", "o:\n\tx: 1\n\t# a: [1" + noa + "\n\ta: 5\n", 1},
		// A field made on the way writes its line too.
		{"a: [1\ny: 3\n", "a.c", "# a: [1" + nac + "\na:\n\tc: 5\ny: 3\n", 1},
		// A loaded `a` changes in place.
		{"a: 1\nb: [1\na: [2\n", "a", "a: 5\nb: [1\n# a: [2" + na + "\n", 1},
		// A kept line with a kept line under it stays as it is, since as a
		// comment it would leave that line under the field above.
		// Two valid lines wrote the first one here until a setter on a
		// repeated path was refused (2026100717500010); the refusal is
		// checked below.
		// {"a: 1\na: 2\n", "a", "a: 5\na: 2\n", 2},
		{"a: 1\na: [2\n\tc: [3\n", "a", "a: 5\na: [2\n\tc: [3\n", 1},
	} {
		doc, _ := ParseKeepLines(c.text, Standard)
		if doc.SetInt(c.path, 5) != SetOk {
			t.Fatalf("%q: SetInt refused", c.text)
		}
		if n := doc.LostCount(); n != 0 {
			t.Fatalf("%q: LostCount %d", c.text, n)
		}
		out := doc.ToCanonical()
		if out != c.want {
			t.Fatalf("%q wrote\n%q\nwant\n%q", c.text, out, c.want)
		}
		back := Parse(out)
		if back.Count(c.path) != c.count || back.ToCanonical() != out {
			t.Fatalf("%q: reload of %q differs", c.text, out)
		}
		if keep, kept := doc.ToTextKeepLines(); keep != out || !kept {
			t.Fatalf("%q: keep save %q %v", c.text, keep, kept)
		}
	}
	// Two valid lines stay as they are: the setter refuses the path.
	two, _ := ParseKeepLines("a: 1\na: 2\n", Standard)
	if two.SetInt("a", 5) == SetOk {
		t.Fatalf("SetInt took a repeated path")
	}
	if keep, kept := two.ToTextKeepLines(); keep != "a: 1\na: 2\n" || !kept {
		t.Fatalf("two valid lines: keep save %q %v", keep, kept)
	}
	// SetComment makes the field without touching the line.
	doc := Parse("a: [1\ny: 3\n")
	if doc.SetComment("a", "n") != SetOk || doc.ToCanonical() != "a: [1\ny: 3\n\n# n\na:\n" {
		t.Fatalf("SetComment wrote %q", doc.ToCanonical())
	}
}

// The zone's short name, else its offset; and the test clock's form.
func TestANoteNamesTheZoneOrItsOffset(t *testing.T) {
	defer testID(t, "Erlf14o")
	for _, c := range []struct {
		offset     int
		name, want string
	}{
		{-420, "PDT", "PDT"},
		{-420, "", "UTC-07:00"},
		{240, "+04", "UTC+04:00"},
		{330, "IST", "IST"},
		{-150, "-0230", "UTC-02:30"},
		{0, "Pacific Daylight Time", "UTC+00:00"},
		{0, "", "UTC+00:00"},
	} {
		if got := zoneLabel(c.offset, c.name); got != c.want {
			t.Fatalf("zoneLabel(%d, %q) = %q, want %q", c.offset, c.name, got, c.want)
		}
	}
	if w, o, n, ok := testClock("2026-10-04 00:15:00 -420 PDT"); !ok || w != "2026-10-04 00:15:00" || o != -420 || n != "PDT" {
		t.Fatalf("testClock: %q %d %q %v", w, o, n, ok)
	}
	if w, o, n, ok := testClock("2026-10-04 00:15:00 60"); !ok || w != "2026-10-04 00:15:00" || o != 60 || n != "" {
		t.Fatalf("testClock: %q %d %q %v", w, o, n, ok)
	}
	for _, bad := range []string{"2026-10-04 00:15:00", "2026-10-04 00:15:00 x PDT"} {
		if _, _, _, ok := testClock(bad); ok {
			t.Fatalf("testClock(%q) took it", bad)
		}
	}
	when, offset, name := localClock()
	stamp := regexp.MustCompile(`^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ([A-Za-z]+|UTC[+-]\d\d:\d\d)$`)
	if label := when + " " + zoneLabel(offset, name); !stamp.MatchString(label) || offset < -14*60 || offset > 14*60 {
		t.Fatalf("local clock: %q (%d)", label, offset)
	}
}

func TestAMergedLayerOwesItsKeptLines(t *testing.T) {
	defer testID(t, "EreUzzO")
	doc := Parse("a: 1\n")
	doc.Merge(Parse(keptGateBase))
	if n := doc.LostCount(); n != 0 {
		t.Fatalf("LostCount %d after the merge", n)
	}
	if !strings.Contains(doc.ToCanonical(), "r: [1, 2\n") {
		t.Fatalf("merged line missing:\n%s", doc.ToCanonical())
	}
	// Owed, not just present: taking it out again is a loss.
	tv := doc.arena[childNamed(doc, "y")].trivMut()
	tv.leading = tv.leading[:len(tv.leading)-1]
	if n := doc.LostCount(); n != 1 {
		t.Fatalf("LostCount %d, want 1", n)
	}
}

// design.md's table: a settled kept line on a leaf the layer replaces goes
// with the leaf's comments, so it is no longer owed.
func TestAReplacedLeafTakesItsSettledKeptLine(t *testing.T) {
	defer testID(t, "ErfGoMK")
	doc := Parse("x: 0\n\tc: 2\n  a: 5\nb: 1\n")
	if n := doc.Remove("x.c"); n != 1 {
		t.Fatalf("removed %d", n)
	}
	if got := doc.ToCanonical(); got != "x: 0\n# a: 5\nb: 1\n" {
		t.Fatalf("after the remove %q", got)
	}
	doc.Merge(Parse("b: 9\n"))
	if got := doc.ToCanonical(); got != "x: 0\nb: 9\n" {
		t.Fatalf("after the merge %q", got)
	}
	if n := doc.LostCount(); n != 0 {
		t.Fatalf("LostCount %d, want 0", n)
	}
}

// design.md's table: the footer dedup skips a layer's kept line the base
// already has, so that copy is not owed.
func TestAFooterLineTheBaseHasIsNotOwedTwice(t *testing.T) {
	defer testID(t, "ErfGoML")
	doc := Parse("bad name: 1\n")
	doc.Merge(Parse("bad name: 1\n"))
	if got := doc.ToCanonical(); got != "bad name: 1\n" {
		t.Fatalf("wrote %q", got)
	}
	if n := doc.LostCount(); n != 0 {
		t.Fatalf("LostCount %d, want 0", n)
	}
}

// design.md's table: a replaced leaf takes only its own comments, the ones a
// remove would take. A settled line or a comment past a kept line beside it
// stays with that line.
func TestAReplacedLeafLeavesTheLinesBesideIt(t *testing.T) {
	defer testID(t, "ErkSyFW")
	doc := Parse("    srv: a\n  srv(x): [3\nb(x): [4\n# mine\nq: c\n")
	if got := doc.ToCanonical(); got != "srv: a\n# srv(x): [3\nb(x): [4\n# mine\nq: c\n" {
		t.Fatalf("loaded %q", got)
	}
	doc.Merge(Parse("q: 9\n"))
	if got := doc.ToCanonical(); got != "srv: a\n# srv(x): [3\nb(x): [4\nq: 9\n" {
		t.Fatalf("after the merge %q", got)
	}
	if n := doc.LostCount(); n != 0 {
		t.Fatalf("LostCount %d, want 0", n)
	}
	doc = Parse("p:\n\tq: c\n\t# mine\n\tb(x): [4\n\t# n\n")
	doc.Merge(Parse("p:\n\tq: 9\n"))
	if got := doc.ToCanonical(); got != "p:\n\tb(x): [4\n\t# n\n\tq: 9\n" {
		t.Fatalf("after the block merge %q", got)
	}
	if n := doc.LostCount(); n != 0 {
		t.Fatalf("block LostCount %d, want 0", n)
	}
}

// A comma splits a value outside brackets only with a blank, a comment or
// the end after it; inside brackets every one does (value-syntax.md,
// 20261006). 2.x split on every comma, which migrate still reads.
func TestACommaSplitsABareValueOnlyBeforeABlank(t *testing.T) {
	defer testID(t, "Ery85QF")
	var tok Tokens
	for _, c := range []struct {
		line   string
		pieces int
	}{
		{"x: rw,noatime", 1},
		{"x: ,a", 1},
		{"x: a,,b", 1},
		{"x: a, b", 2},
		{"x: a,", 2},
		{"x: a,# c", 2},
		{"x: a,\tb", 2},
		{"x: [a,b]", 2},
		{"x: [rw,noatime, c]", 3},
	} {
		Tokenize(c.line, ':', false, RulesCurrent, &tok)
		if len(tok.Elements) != c.pieces {
			t.Fatalf("%q: %d pieces, want %d", c.line, len(tok.Elements), c.pieces)
		}
	}
	Tokenize("x: a,b", ':', false, RulesV2, &tok)
	if len(tok.Elements) != 2 {
		t.Fatalf("2.x: %d pieces", len(tok.Elements))
	}
}

// Spaces in a bare value or item are fine. A tab, a bracket, a quote, or a
// colon or comma with a blank or the end after it is one error, and its
// message says what to do.
func TestBareSpacesColonsAndCommas(t *testing.T) {
	defer testID(t, "Ery85QG")
	for _, c := range []struct{ text, code, fix string }{
		{"x: host: a.com port: 80\n", "E025", "put each field on its own line"},
		{"x: done:\n", "E025", "quote it"},
		{"x: a\tb\n", "E025", "quote it"},
		{"x: a[b]c\n", "E025", "quote it"},
		{"x: [New York, Boston]\n", "E025", "quote it"},
		{"x: [a:, b]\n", "E025", "quote it"},
		{"x: a,\n", "E026", "write an array in brackets"},
		{"x: 80, 443\n", "E026", "write an array in brackets"},
		{"x: a: b, c\n", "E025", "put each field on its own line"},
		{"x:\n\t- name: value\n", "E027", "as instances"},
		{"x:\n\t- name:\n", "E027", "as instances"},
		{"x:\n\t- a, b\n", "E026", "quote the text"},
		{"x:\n\t- a\tb\n", "E025", "quote it"},
		{"x:\n\t- [a]\n", "E019", "quote the item"},
		{"x(a:b).y: 1\n", "E025", "quote it"},
		{"x(a,b).y: 1\n", "E025", "quote it"},
		{"x(a[b).y: 1\n", "E025", "quote it"},
		{"x(a(b).y: 1\n", "E025", "quote it"},
	} {
		d := Parse(c.text).Diagnostics()
		if len(d) != 1 || d[0].Code != c.code || !strings.Contains(d[0].Message, c.fix) {
			t.Fatalf("%q: %v", c.text, d)
		}
	}
	for _, c := range []struct{ text, path, want string }{
		{"x: My  App\n", "x", "My  App"},
		{"x: rw,noatime\n", "x", "rw,noatime"},
		{"x: :0\n", "x", ":0"},
		{"x: https://a.com:8080/p?q=1,2\n", "x", "https://a.com:8080/p?q=1,2"},
		{"x: Jul 12 2026  # c\n", "x", "Jul 12 2026"},
		{"x:\n\t- New  York\n\t- :0\n", "x", "[\"New  York\", \":0\"]"},
	} {
		doc := Parse(c.text)
		if d := doc.Diagnostics(); len(d) != 0 {
			t.Fatalf("%q: %v", c.text, d)
		}
		if got, st := doc.GetString(c.path); st != Good || got != c.want {
			t.Fatalf("%q: %q %v", c.text, got, st)
		}
	}
	if _, st := Parse("x: 80,443\n").GetInt("x"); st == Good {
		t.Fatal("80,443 read as a number")
	}
}

// The reader takes a colon or comma bare where it is text, but the writer
// quotes any whitespace, colon, comma, paren or bracket wherever it sits, so
// nobody has to know the reader's rules. A quoted value keeps its quotes and
// its quote kind, a quoted number included.
func TestTheWriterQuotesAColonOrComma(t *testing.T) {
	defer testID(t, "Ery85QH")
	doc := New()
	if doc.SetString("opts", "rw,noatime") != SetOk || doc.SetString("display", ":0") != SetOk || doc.SetString("end", "a,") != SetOk ||
		doc.SetString("title", "My App") != SetOk || doc.SetStringArray("tags", []string{"rw,noatime", "b"}) != SetOk ||
		doc.SetString("call", "f(x)") != SetOk || doc.SetString("box", "a[0]") != SetOk || doc.SetString("tabbed", "a\tb") != SetOk ||
		doc.SetString("plain", "a-b.c/d") != SetOk {
		t.Fatal("a setter refused")
	}
	out := doc.ToCanonical()
	for _, want := range []string{
		"opts: \"rw,noatime\"\n",
		"display: \":0\"\n",
		"end: \"a,\"\n",
		"title: \"My App\"\n",
		"tags: [\"rw,noatime\", b]\n",
		"call: \"f(x)\"\n",
		"box: \"a[0]\"\n",
		"tabbed: \"a◉TAB◉b\"\n",
		"plain: a-b.c/d\n",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("%q not in %q", want, out)
		}
	}
	back := Parse(out)
	if got := back.ToCanonical(); got != out {
		t.Fatalf("reload wrote %q", got)
	}
	if v, st := back.GetStringArray("tags"); st != Good || !reflect.DeepEqual(v, []string{"rw,noatime", "b"}) {
		t.Fatalf("tags: %v %v", v, st)
	}
	doc = Parse("n: \"1,000\"\n")
	if got := doc.ToCanonical(); got != "n: \"1,000\"\n" {
		t.Fatalf("wrote %q", got)
	}
	if v, st := doc.GetInt("n"); st != Good || v != 1000 {
		t.Fatalf("n: %d %v", v, st)
	}
	doc = Parse("ver: \"8\"\nok: 'true'\nat: 2:30PM\nhost: localhost:8080\n")
	if got := doc.ToCanonical(); got != "ver: \"8\"\nok: 'true'\nat: \"2:30PM\"\nhost: \"localhost:8080\"\n" {
		t.Fatalf("wrote %q", got)
	}
	if v, st := doc.GetInt("ver"); st != Good || v != 8 {
		t.Fatalf("ver: %d %v", v, st)
	}
	if doc.SetInt("ver", 9) != SetOk || !strings.HasPrefix(doc.ToCanonical(), "ver: \"9\"\n") {
		t.Fatalf("ver set wrote %q", doc.ToCanonical())
	}
	hint := Parse("t: a,b\nt: c\n").Diagnostics()[0]
	if hint.Code != "H001" || !strings.Contains(hint.Message, "t: [\"a,b\", c]") {
		t.Fatalf("hint %v", hint)
	}
}

// migrate writes a 2.x comma list in brackets, with or without a blank
// after the comma, since 2.x read both as arrays. In a file that does not
// say it is 2.x, `a,b` is a string under these rules, so it is left and
// counted; `a, b` is an error here, so it converts either way. A lone bare
// value these rules refuse is quoted.
func TestMigrateBracketsA2xCommaList(t *testing.T) {
	defer testID(t, "ErykhtD")
	m := Migrate("x: a, b\ny: a,b\nz: \"q\", r\nw: New York,,b\nv: done:\nu: rw,noatime\n", true)
	if m.Ambiguous != 0 {
		t.Fatalf("ambiguous %d", m.Ambiguous)
	}
	if !strings.HasPrefix(m.Text, "x: [a, b]\ny: [a, b]\nz: [\"q\", r]\nw: [\"New York\", b]\nv: \"done:\"\nu: [rw, noatime]\n") {
		t.Fatalf("%q", m.Text)
	}
	if d := Parse(m.Text).Diagnostics(); len(d) != 0 {
		t.Fatalf("%v", d)
	}
	m = Migrate("x: a, b\ny: a,b\n", false)
	if m.Ambiguous != 1 {
		t.Fatalf("ambiguous %d", m.Ambiguous)
	}
	if !strings.HasPrefix(m.Text, "x: [a, b]\ny: a,b\n") {
		t.Fatalf("%q", m.Text)
	}
}

// A 2.x `*` item becomes `- `, and an item these rules would read as
// something else is quoted, such as one that looks like `- name: value`.
func TestMigrateWritesStarItemsAsDashes(t *testing.T) {
	defer testID(t, "ErykhtE")
	m := Migrate("list:\n\t* a\n\t* key: value\n\t* 'c'\n\t* O'Brien\n", true)
	if !strings.HasPrefix(m.Text, "list:\n\t- a\n\t- \"key: value\"\n\t- 'c'\n\t- \"O'Brien\"\n") {
		t.Fatalf("%q", m.Text)
	}
	back := Parse(m.Text)
	if d := back.Diagnostics(); len(d) != 0 {
		t.Fatalf("%v", d)
	}
	if v, st := back.GetStringArray("list"); st != Good || !reflect.DeepEqual(v, []string{"a", "key: value", "c", "O'Brien"}) {
		t.Fatalf("list: %q %v", v, st)
	}
}

// A bare 2.x name not led by a letter is quoted, so `-x: y` and `- :0` stay
// fields rather than reading as list items, and `404` stays a name.
func TestMigrateQuotesANameNotLedByALetter(t *testing.T) {
	defer testID(t, "ErykhtF")
	m := Migrate("404: a\n-x: y\nl:\n\t- :0\na.9b: 2\n_id: 7\n", true)
	if !strings.HasPrefix(m.Text, "\"404\": a\n\"-x\": y\nl:\n\t\"-\" :0\na.\"9b\": 2\n\"_id\": 7\n") {
		t.Fatalf("%q", m.Text)
	}
	back := Parse(m.Text)
	if d := back.Diagnostics(); len(d) != 0 {
		t.Fatalf("%v", d)
	}
	if v, st := back.GetString("\"-x\""); st != Good || v != "y" {
		t.Fatalf("-x: %q %v", v, st)
	}
	if v, st := back.GetString("l.\"-\""); st != Good || v != "0" {
		t.Fatalf("l.-: %q %v", v, st)
	}
	if v, st := back.GetInt("a.\"9b\""); st != Good || v != 2 {
		t.Fatalf("a.9b: %d %v", v, st)
	}
}

// 2.x read a `◉` as text. A name, a bare value and a selector body holding
// one get the escape for a real mark, so they still read as that text.
func TestMigrateEscapesARealMark(t *testing.T) {
	defer testID(t, "ErykhtG")
	m := Migrate("\"a\u25C9q\u25C9\": 1\nbare: My\u25C9SPACE\u25C9App\ns[x\u25C9y].p: 2\n", true)
	back := Parse(m.Text)
	if d := back.Diagnostics(); len(d) != 0 {
		t.Fatalf("%v\n%s", d, m.Text)
	}
	if p := back.Paths(); len(p) < 2 || p[0] != "\"a\u25C9ESCAPE_CHAR\u25C9q\u25C9ESCAPE_CHAR\u25C9\"" || p[1] != "bare" {
		t.Fatalf("%q\n%s", p, m.Text)
	}
	if v, st := back.GetString("bare"); st != Good || v != "My\u25C9SPACE\u25C9App" {
		t.Fatalf("bare: %q %v", v, st)
	}
	if n := back.Count("s"); n != 1 {
		t.Fatalf("count s %d", n)
	}
	if v, st := back.GetString("s(0)"); st != Good || v != "x\u25C9y" {
		t.Fatalf("s(0): %q %v", v, st)
	}
}

// A 2.x selector goes in parens, and a bare body these rules refuse, such
// as one with a quote or a space, is quoted, so its block still loads.
func TestMigrateQuotesABareSelectorTheseRulesRefuse(t *testing.T) {
	defer testID(t, "ErykhtH")
	m := Migrate("srv[O'Brien].port: 1\nsrv[New York].port: 2\n", true)
	if !strings.HasPrefix(m.Text, "srv(\"O'Brien\").port: 1\nsrv(\"New York\").port: 2\n") {
		t.Fatalf("%q", m.Text)
	}
	back := Parse(m.Text)
	if d := back.Diagnostics(); len(d) != 0 {
		t.Fatalf("%v", d)
	}
	if n := back.Count("srv"); n != 2 {
		t.Fatalf("count srv %d", n)
	}
}

// Every 2.x selector goes in parens: an index, a value, the sugar on a
// segment before the last, and a body with a paren in it, quoted. A selector
// in brackets is E029 under these rules, so a file that does not say it is
// 2.x gets the same rewrite, with nothing counted.
func TestMigrateWritesSelectorsInParens(t *testing.T) {
	defer testID(t, "ErykhtI")
	text := "a[x].k: 1\nb: y\nb[0].k: 2\nc[a(b)].k: 3\ne:[f].g: 4\nr[\"x\"]:\n\ts: 1\n"
	want := "a(x).k: 1\nb: y\nb(0).k: 2\nc(\"a(b)\").k: 3\ne(f).g: 4\nr(\"x\"):\n\ts: 1\n"
	for _, fromV2 := range []bool{true, false} {
		m := Migrate(text, fromV2)
		if m.Ambiguous != 0 || m.Lost != 0 {
			t.Fatalf("fromV2 %v: ambiguous %d, lost %d\n%s", fromV2, m.Ambiguous, m.Lost, m.Text)
		}
		if !strings.HasPrefix(m.Text, want) {
			t.Fatalf("fromV2 %v: %q", fromV2, m.Text)
		}
	}
	back := Parse(Migrate(text, true).Text)
	if d := back.Diagnostics(); len(d) != 0 {
		t.Fatalf("%v", d)
	}
	for path, want := range map[string]int64{"c(\"a(b)\").k": 3, "e(f).g": 4, "b(y).k": 2, "r(x).s": 1} {
		if v, st := back.GetInt(path); st != Good || v != want {
			t.Errorf("%s: %d %v", path, v, st)
		}
	}
}

// What 2.x bound and nothing spells now is counted lost, so the CLI
// refuses at 7: a selector with a comma, which matched an array value, and
// a comma list with lines under it. A list of only empty slots, which 2.x
// read as empty, is an empty value.
func TestMigrateCountsWhatNothingSpells(t *testing.T) {
	defer testID(t, "ErykhtJ")
	if m := Migrate("a[x, y].b: 1\n", true); m.Lost != 1 {
		t.Fatalf("lost %d", m.Lost)
	}
	if m := Migrate("a: 1, 2\n\tb: 1\nc: 3, 4\n", true); m.Lost != 1 {
		t.Fatalf("lost %d\n%s", m.Lost, m.Text)
	}
	m := Migrate("e: ,\nf: , # c\n", true)
	if m.Lost != 0 {
		t.Fatalf("lost %d", m.Lost)
	}
	if !strings.HasPrefix(m.Text, "e:\nf: # c\n") {
		t.Fatalf("%q", m.Text)
	}
	back := Parse(m.Text)
	if d := back.Diagnostics(); len(d) != 0 {
		t.Fatalf("%v", d)
	}
	if _, st := back.GetString("e"); st != Empty {
		t.Fatalf("e: %v", st)
	}
}

// A file that does not say it is 2.x could be a 3.0 one. A piece that reads
// clean under these rules too, such as an escape, a backtick value, `[a]` or
// a `- ` item, is left as written and counted, so the CLI asks for
// --from-2x rather than changing a correct file at exit 0. A selector in
// brackets is E029 now, so its line is rewritten the 2.x way.
func TestMigrateLeavesWhatReadsCleanNow(t *testing.T) {
	defer testID(t, "ErykhtK")
	text := "x: \"a\u25C9TAB\u25C9b\"\n\"n\u25C9TAB\u25C9\": 1\nl:\n\t- :0\ns[\"\u25C9TAB\u25C9\"].p: 1\nb: `abc`\nc: [a]\n"
	m := Migrate(text, false)
	if m.Ambiguous != 5 {
		t.Fatalf("ambiguous %d\n%s", m.Ambiguous, m.Text)
	}
	want := strings.Replace(text, "s[\"\u25C9TAB\u25C9\"]", "s(\"\u25C9ESCAPE_CHAR\u25C9TAB\u25C9ESCAPE_CHAR\u25C9\")", 1)
	if m.Text != want {
		t.Fatalf("got %q\nwant %q", m.Text, want)
	}
	if !strings.Contains(Migrate(text, true).Text, "ESCAPE_CHAR") {
		t.Fatal("no ESCAPE_CHAR with fromV2")
	}
}

// A list with a field under it (E001) after an empty binding of its name
// that has fields: no text loads it back, since a reload joins the list's
// header to that binding and drops its items (E008). The load is left as it
// is; a save that would write it refuses (2026100511210900). An edit and a
// merge can each leave one. Same fixture in every runner.
func TestAListNoTextLoadsBackRefusesToSave(t *testing.T) {
	defer testID(t, "EryDfqr")
	src := "x: v\n\tf: 1\nx:\n\t- a\n\t- b\n\tg: 2\n"
	doc, _ := ParseKeepLines(src, Standard)
	if doc.LostCount() != 0 {
		t.Fatalf("load lost %d", doc.LostCount())
	}
	if doc.SetEmpty("x(v)") != SetOk {
		t.Fatal("set empty refused")
	}
	text := doc.ToCanonical()
	if text != "x:\n\tf: 1\nx:\n\t- a\n\t- b\n\tg: 2\n" {
		t.Fatalf("canonical %q", text)
	}
	if n := Parse(text).LostCount(); n != 2 {
		t.Fatalf("the reload drops both items: %d", n)
	}
	if doc.LostCount() != 2 {
		t.Fatalf("lost %d", doc.LostCount())
	}
	if _, kept := doc.ToTextKeepLines(); kept {
		t.Fatal("the source was canonical, and still no lines are kept")
	}
	f := filepath.Join(t.TempDir(), "t.shcl")
	if err := os.WriteFile(f, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	var refused *SaveRefused
	if err := doc.SaveFile(f); !errors.As(err, &refused) || refused.Lost != 2 {
		t.Fatalf("save: %v", err)
	}
	if _, err := doc.SaveFileKeepLines(f); !errors.As(err, &refused) || refused.Lost != 2 {
		t.Fatalf("keep save: %v", err)
	}
	if b, _ := os.ReadFile(f); string(b) != src {
		t.Fatalf("file changed: %q", b)
	}
	if err := doc.SaveFileLossy(f); err != nil {
		t.Fatalf("lossy save: %v", err)
	}
	// The same through a merge: the list arrives over an empty binding.
	merged := Parse("x:\n\tf: 1\n")
	merged.Merge(Parse("x:\n\t- a\n\t- b\n\tg: 2\n"))
	if merged.LostCount() != 2 {
		t.Fatalf("merge lost %d: %q", merged.LostCount(), merged.ToCanonical())
	}
	// An empty binding with no fields takes the list in, so nothing is lost,
	// and a list with no field under it goes in brackets.
	for _, src := range []string{"x: v\nx:\n\t- a\n\tg: 2\n", "x: v\n\tf: 1\nx:\n\t- a\n\t- b\n"} {
		doc := Parse(src)
		if doc.SetEmpty("x(v)") != SetOk || doc.LostCount() != 0 {
			t.Fatalf("%q: lost %d: %q", src, doc.LostCount(), doc.ToCanonical())
		}
	}
}

// A setter that empties a field joins the stacked list after it, fields and
// all, as a reload would. A read made before the write has the lookup built,
// and the fields that moved still have to be found through it.
func TestAListJoiningAnEmptiedFieldKeepsItsFieldsFound(t *testing.T) {
	defer testID(t, "EryDfsy")
	for _, c := range []struct{ src, path, field, want string }{
		{"b: x\nb:\n\t- 3\n\tk: 1\n", "b(0)", "b.k", "1"},
		{"b: x\nb: y z\n\t- 3\n\tk: 1\n", "b(0)", "b.k", "1"},
		{"x: v\nx:\n\t- a\n\tg: 2\n", "x(v)", "x.g", "2"},
	} {
		doc := Parse(c.src)
		if _, st := doc.GetString(c.field); st != Good {
			t.Fatalf("%q: before: %v", c.src, st)
		}
		if doc.SetEmpty(c.path) != SetOk {
			t.Fatalf("%q: set empty refused", c.src)
		}
		back := Parse(doc.ToCanonical())
		if v, st := back.GetString(c.field); st != Good || v != c.want {
			t.Fatalf("%q: reload: %q %v", c.src, v, st)
		}
		if v, st := doc.GetString(c.field); st != Good || v != c.want {
			t.Fatalf("%q: live: %q %v", c.src, v, st)
		}
		if !reflect.DeepEqual(doc.Paths(), back.Paths()) {
			t.Fatalf("%q: paths %v vs %v", c.src, doc.Paths(), back.Paths())
		}
	}
}

// A load can build that list too, under a kept array line (E028). The
// canonical text writes the line as a comment and cannot load the list back,
// so that save refuses. The source text does, so with no edits the save that
// keeps lines writes it as it was.
func TestAListTheSourceLoadsBackKeepsItsLines(t *testing.T) {
	defer testID(t, "EryDfv3")
	src := "c:\n\ts: 1\nc: [1]\n\tb(*): 1\n\t- 3\n\ta: 2\n"
	doc, _ := ParseKeepLines(src, Standard)
	if doc.LostCount() != 2 {
		t.Fatalf("the wildcard line and the item: lost %d", doc.LostCount())
	}
	if text, kept := doc.ToTextKeepLines(); !kept || text != src {
		t.Fatalf("keep: %v %q", kept, text)
	}
	f := filepath.Join(t.TempDir(), "t.shcl")
	if err := os.WriteFile(f, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	var refused *SaveRefused
	if err := doc.SaveFile(f); !errors.As(err, &refused) || refused.Lost != 2 {
		t.Fatalf("save: %v", err)
	}
	if kept, err := doc.SaveFileKeepLines(f); err != nil || !kept {
		t.Fatalf("keep save: %v %v", kept, err)
	}
	if b, _ := os.ReadFile(f); string(b) != src {
		t.Fatalf("file changed: %q", b)
	}
}

// A merge adds a list with a field under it as a new instance after an empty
// binding of its name. A comment or kept line left after the binding held the
// join off, though a reload joins the two (2026100520243961).
func TestAMergedListJoinsAnEmptyFieldPastAComment(t *testing.T) {
	defer testID(t, "EryDfx5")
	layer := Parse("p:\n\ts:\n\t\t- 0\n\t\tc: 1\n")
	for _, base := range []string{
		"p:\n\ts:\n\t# c\n",
		"p:\n\ts:\n\tk: [1\n",
		"p:\n\ts:\n\t# c\n\t\t# d\n",
		"p:\n\ts:\n\t# c\n\tt: 2\n",
	} {
		doc := Parse(base)
		doc.Merge(layer)
		text := doc.ToCanonical()
		back := Parse(text)
		if back.ToCanonical() != text {
			t.Fatalf("%q: not a fixpoint: %q", base, text)
		}
		if !reflect.DeepEqual(doc.Paths(), back.Paths()) {
			t.Fatalf("%q: paths %v vs %v", base, doc.Paths(), back.Paths())
		}
		for _, d := range []*Document{doc, back} {
			if v, st := d.GetString("p.s.c"); st != Good || v != "1" {
				t.Fatalf("%q: p.s.c %q %v", base, v, st)
			}
		}
		if n := len(doc.Instances("p.s")); n != 1 {
			t.Fatalf("%q: %d instances", base, n)
		}
	}
}

// The remove twin: the merge without the gap builds the list no text loads
// back, after a binding with a field. A remove that takes that field joins
// the list, and one that takes the list's field puts it in brackets, as a
// reload reads each.
func TestARemoveSettlesAListAfterAnEmptyField(t *testing.T) {
	defer testID(t, "EryDfzB")
	for _, c := range []struct{ path, want string }{
		{"p.s.x", "p:\n\ts:\n\t\t- 0\n\t\tc: 1\n"},
		{"p.s.c", "p:\n\ts:\n\t\tx: 1\n\ts: [0]\n"},
	} {
		doc := Parse("p:\n\ts:\n\t\tx: 1\n")
		doc.Merge(Parse("p:\n\ts:\n\t\t- 0\n\t\tc: 1\n"))
		if doc.LostCount() == 0 {
			t.Fatalf("%s: the list no text loads back", c.path)
		}
		if n := doc.Remove(c.path); n != 1 {
			t.Fatalf("%s: removed %d", c.path, n)
		}
		text := doc.ToCanonical()
		if text != c.want {
			t.Fatalf("%s: %q", c.path, text)
		}
		back := Parse(text)
		if back.ToCanonical() != text || !reflect.DeepEqual(doc.Paths(), back.Paths()) {
			t.Fatalf("%s: reload differs", c.path)
		}
		if doc.LostCount() != 0 {
			t.Fatalf("%s: lost %d", c.path, doc.LostCount())
		}
	}
}

// A field with lines under it takes one plain value or none (E028), so a
// setter puts no field under an array and no array over fields. Each used to
// write text that reloads as E028.
func TestASetterKeepsFieldsAndArraysApart(t *testing.T) {
	defer testID(t, "EryDg1D")
	src := "l: [a]\nc: 1\n\tk: 2\n"
	doc := Parse(src)
	if doc.SetInt("l.c", 1) == SetOk {
		t.Fatalf("a field under an array: %q", doc.ToCanonical())
	}
	if doc.SetLiteral("c", "[1, 2]") == SetOk || doc.SetStringArray("c", []string{"1"}) == SetOk {
		t.Fatalf("an array over fields: %q", doc.ToCanonical())
	}
	if doc.ToCanonical() != src {
		t.Fatalf("changed: %q", doc.ToCanonical())
	}
	// An array with nothing under it takes a new one, and a stacked list
	// written with '- ' stays stacked.
	doc = Parse("l: [a]\nz:\n\t- a\n\t- b\n")
	if doc.SetStringArray("l", []string{"b", "c"}) != SetOk || doc.SetStringArray("z", []string{"x"}) != SetOk {
		t.Fatal("an array setter refused")
	}
	if got := doc.ToCanonical(); got != "l: [b, c]\nz:\n\t- x\n" {
		t.Fatalf("got %q", got)
	}
}

// A selector is written in parens. One in brackets is the old spelling: a
// file line is E029 and kept, and a lookup, a setter or a schema path in
// brackets is refused. A body starting with `#`, the old index, is refused
// too. Same fixture in every runner.
func TestBracketSelectorsAreTheOldSpelling(t *testing.T) {
	defer testID(t, "Eryg0ZB")
	doc := Parse("srv: web\n\tport: 80\nsrv[web]:\n\thost: h\n")
	d := doc.Diagnostics()
	if len(d) != 1 || d[0].Code != "E029" || d[0].Line != 3 {
		t.Fatalf("diagnostics %v", d)
	}
	if n := doc.LostCount(); n != 0 {
		t.Fatalf("LostCount %d", n)
	}
	if v := doc.ReadString("srv(web).host").Value; v != "h" {
		t.Fatalf("srv(web).host = %q", v)
	}
	if n := doc.Count("srv"); n != 1 {
		t.Fatalf("srv count %d", n)
	}
	// Was NotFound until reads got BadPath (2026100717500001).
	// if st := doc.ReadString("srv[web].host").Status; st != NotFound {
	// 	t.Fatalf("srv[web].host status %v", st)
	// }
	if st := doc.ReadString("srv[web].host").Status; st != BadPath {
		t.Fatalf("srv[web].host status %v", st)
	}
	if n := doc.Count("srv[web]"); n != 0 {
		t.Fatalf("srv[web] count %d", n)
	}
	for path, want := range map[string]SetStatus{"srv[web].x": SetBadPath, "srv(#0).x": SetBadPath, "srv(0).x": SetOk} {
		if got := doc.CheckSetPath(path); got != want {
			t.Errorf("CheckSetPath(%q) = %v, want %v", path, got, want)
		}
	}
	if doc.SetInt("srv[web].x", 1) == SetOk {
		t.Fatal("a setter took a path in brackets")
	}
	if doc.SetInt("srv(web).x", 1) != SetOk {
		t.Fatal("a setter refused srv(web).x")
	}
	if got := doc.ToCanonical(); !strings.HasPrefix(got, "srv[web]:\nsrv: web\n") {
		t.Fatalf("got %q", got)
	}
	var tok Tokens
	Tokenize("a(x).b[y].c: 1", ':', false, RulesCurrent, &tok)
	if tok.BracketSelector != 6 {
		t.Fatalf("BracketSelector %d, want 6", tok.BracketSelector)
	}
	Tokenize("a(x).b(y).c: 1", ':', false, RulesCurrent, &tok)
	if tok.BracketSelector != -1 {
		t.Fatalf("BracketSelector %d, want -1", tok.BracketSelector)
	}
	schema := Parse("field: \"srv[*].port\"\n")
	found := false
	for _, v := range Parse("srv: a\n").Validate(schema) {
		if v.Code == "V093" && strings.Contains(v.Message, "parens") {
			found = true
		}
	}
	if !found {
		t.Fatal("no V093 naming parens")
	}
}

// A parent whose default is an array has no selector a child line can use,
// since a selector matches one plain value. Generation refuses it rather
// than write a child that makes another instance.
func TestInitRefusesAChildOfAnArrayParent(t *testing.T) {
	defer testID(t, "Eryg0bK")
	schema := Parse("field: tags\n\trequired: yes\n\tdefault: [a]\nfield: tags.k\n\trequired: yes\n")
	text, faults := Generate(schema, true)
	found := false
	for _, d := range faults {
		if d.Code == "V097" && strings.Contains(d.Message, "no selector spelling") {
			found = true
		}
	}
	if !found {
		t.Fatalf("a child of an array parent generated: %q %v", text, faults)
	}
}
