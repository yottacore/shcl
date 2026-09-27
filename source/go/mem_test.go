// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

package shcl

// Allocation bounds the corpus cannot see: a capped parse must not hold what
// it is about to refuse.

import (
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// heldBy returns the heap bytes still live after f ran, with what f returned
// kept alive across the measurement: what the document holds, not what the
// parse allocated on the way (a per-line message the cap drops is garbage
// the collector takes back, not growth).
func heldBy(f func() any) uint64 {
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	keep := f()
	runtime.GC()
	runtime.ReadMemStats(&after)
	runtime.KeepAlive(keep)
	if after.HeapAlloc < before.HeapAlloc {
		return 0 // the second collection also took back something older
	}
	return after.HeapAlloc - before.HeapAlloc
}

// allocatedBy returns the heap bytes f allocated in total, freed or not - what
// the parse built on the way rather than what it kept. A line built in full and
// then refused is garbage by the time heldBy reads the heap, which is exactly
// the defect the element cap exists for. Rust measures the peak, C the total
// allocated, Python the tracemalloc peak; this is Go's spelling of the same.
func allocatedBy(f func() any) uint64 {
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	keep := f()
	runtime.ReadMemStats(&after)
	runtime.KeepAlive(keep)
	return after.TotalAlloc - before.TotalAlloc
}

func TestElementCapBoundsTheParse(t *testing.T) {
	defer testID(t, "EoezJiD")
	text := "arr: " + strings.Repeat("1, ", 200000) + "\nok: 5\n"
	capped := allocatedBy(func() any {
		doc, _ := ParseLimited(text, Standard, 0, 8, 0) // only Strict returns an error
		if doc.LostCount() != 1 {
			t.Fatalf("lost %d", doc.LostCount())
		}
		return doc
	})
	// The refused line used to be built in full first (78x the text), so the
	// cap saved nothing. What a capped parse holds is the text and its lines.
	if capped > uint64(len(text))*8 {
		t.Fatalf("a capped parse held the array it refused: %d bytes for %d of text", capped, len(text))
	}
}

func TestDiagnosticCapBoundsTheParse(t *testing.T) {
	defer testID(t, "EofAXrV")
	// The stacked spelling refuses each element line past the cap on its own,
	// and every refusal is a diagnostic: with the element cap alone, 200k
	// refused lines cost more than the elements they refused. The diagnostic
	// cap is what bounds that.
	text := "arr:\n" + strings.Repeat("\t* 1\n", 200000)
	capped := heldBy(func() any {
		doc, _ := ParseLimited(text, Standard, 0, 8, 100) // only Strict returns an error
		if len(doc.Diagnostics()) != 101 || doc.LostCount() != 200000-8 {
			t.Fatalf("diags %d lost %d", len(doc.Diagnostics()), doc.LostCount())
		}
		return doc
	})
	if capped > uint64(len(text))*8 {
		t.Fatalf("a diagnostic-capped parse held its unlisted diagnostics: %d bytes for %d of text", capped, len(text))
	}
}

func TestRangeFaultsCostTheirMessage(t *testing.T) {
	defer testID(t, "EqYsOIq")
	// Each V004 to V006 message escapes its value, and the escape built a 6 KB
	// replacer table per message until the replacer was shared. The same
	// document with every value in range is the baseline, so what is left is
	// the cost of the faults alone.
	var schema, inRange, outOfRange strings.Builder
	const fields = 2000
	for i := 0; i < fields; i++ {
		schema.WriteString("field: k" + strconv.Itoa(i) + "\n\ttype: int\n\tmax: 10\n")
		inRange.WriteString("k" + strconv.Itoa(i) + ": 5\n")
		outOfRange.WriteString("k" + strconv.Itoa(i) + ": 50\n")
	}
	clean := allocatedBy(func() any { return LoadAndValidate(inRange.String(), schema.String(), Standard) })
	faulty := allocatedBy(func() any {
		doc := LoadAndValidate(outOfRange.String(), schema.String(), Standard)
		n := 0
		for _, dg := range doc.Diagnostics() {
			if dg.Code == "V006" {
				n++
			}
		}
		if n != fields {
			t.Fatalf("want %d V006, got %d", fields, n)
		}
		return doc
	})
	if faulty > clean && (faulty-clean)/fields > 2048 {
		t.Fatalf("a range fault allocated %d bytes", (faulty-clean)/fields)
	}
}

func TestArenaSizedToTheDocument(t *testing.T) {
	defer testID(t, "Eqew0Xo")
	// Grown by append, the arena cost about an eighth of fmt and a sixth of
	// peak memory on a large file. Sized from the line count it has no slack,
	// and lines that make no node must not reserve room the document keeps.
	var flat strings.Builder
	for i := 0; i < 50000; i++ {
		flat.WriteString("k" + strconv.Itoa(i) + ": 1\n")
	}
	doc := Parse(flat.String())
	if len(doc.arena) != 50001 || cap(doc.arena) != len(doc.arena) {
		t.Fatalf("flat: %d nodes in an arena of %d", len(doc.arena), cap(doc.arena))
	}
	sparse := "a: 1\n" + strings.Repeat("# note\n\n", 20000) + "arr:\n" + strings.Repeat("\t* 1\n", 20000)
	doc = Parse(sparse)
	if cap(doc.arena) > 2*len(doc.arena) {
		t.Fatalf("sparse: %d nodes in an arena of %d", len(doc.arena), cap(doc.arena))
	}
	// The sparse case never reaches the trim, since the count already skips
	// its lines. Refused lines are counted and make no node, so these do.
	doc = Parse("a: 1\n" + strings.Repeat(": x\n", 20000))
	if cap(doc.arena) > 2*len(doc.arena) {
		t.Fatalf("refused: %d nodes in an arena of %d", len(doc.arena), cap(doc.arena))
	}
	// A raw body makes no node either, and the trim would hide one counted,
	// since what it costs is the peak before the trim. Exact counts, with a
	// field after each close, so a count that never finds the close fails.
	for _, c := range []struct {
		raw  string
		want int
	}{
		{"a: 1\nb: ```\n" + strings.Repeat("\tbody: x\n", 20000) + "```\nc: 2\n", 3},
		{"a: 1\nb:\n\t~~~~ sql\n" + strings.Repeat("\t~~~\n", 20000) + "\t~~~~\nc: 2\n", 4},
	} {
		if n := trimCountingNodeLines(strings.Split(c.raw, "\n")); n != c.want {
			t.Fatalf("a raw body document counted %d node lines, want %d", n, c.want)
		}
	}
}
