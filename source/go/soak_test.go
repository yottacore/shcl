// SPDX-License-Identifier: MIT
// Copyright © 2026 Jim Collier [ID: 2უNაɘ«҂թȹɤξπ๙¿ձϖ]

package shcl

import (
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strconv"
	"testing"
)

// The corpus files one soak round goes over, by path, so each round reads
// them from disk again.
type soakCase struct {
	input, schema, layer string
}

func soakCases(t *testing.T) []soakCase {
	entries, err := os.ReadDir(corpusDir())
	if err != nil {
		t.Fatalf("corpus: %v", err)
	}
	var cases []soakCase
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		dir := filepath.Join(corpusDir(), e.Name())
		c := soakCase{input: filepath.Join(dir, "input.shcl")}
		if _, err := os.Stat(filepath.Join(dir, "schema.shcl")); err == nil {
			c.schema = filepath.Join(dir, "schema.shcl")
		}
		if _, err := os.Stat(filepath.Join(dir, "layer1.shcl")); err == nil {
			c.layer = filepath.Join(dir, "layer1.shcl")
		}
		cases = append(cases, c)
	}
	return cases
}

// soakHeap is what the heap holds once the garbage from the rounds before is
// gone. Two collections, since a finalizer the first one queues frees its
// memory only in the second.
func soakHeap() uint64 {
	runtime.GC()
	runtime.GC()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	return ms.HeapInuse
}

// Load, read, set, save, merge and validate over every corpus file, round
// after round. Round N to 2N is what's judged: the first rounds grow pools
// and caches that then stay put.
func TestSoakHeapSettles(t *testing.T) {
	defer testID(t, "Et01j4C")
	if raceOn {
		t.Skip("the plain run soaks; -race only slows it")
	}
	// Sampled every 4 KB rather than every 512 KB, so a small leak still shows
	// in the profile. Sampling every byte doubled the soak's time.
	defer func(rate int) { runtime.MemProfileRate = rate }(runtime.MemProfileRate)
	runtime.MemProfileRate = 4096
	cases := soakCases(t)
	saveTo := filepath.Join(t.TempDir(), "soak.shcl")
	const rounds = 4
	// Measured at 4 rounds: N and 2N at most 16 KB apart. Keeping each
	// document's path list grows it about 350 KB.
	const margin = 128 << 10
	saved, validated := 0, 0
	round := func(r int) {
		for _, c := range cases {
			doc, st := LoadFile(c.input)
			if st != FileClean && st != FileHadErrors {
				t.Fatalf("%s: load %v", c.input, st)
			}
			for _, p := range doc.Paths() {
				doc.ReadString(p)
			}
			doc.SetInt("soak.round", int64(r))
			doc.SetString("soak.case", strconv.Itoa(r)+" "+c.input)
			if doc.SaveFileLossy(saveTo) == nil {
				saved++
				back, _ := LoadFile(saveTo)
				doc.Merge(back)
			}
			if c.layer != "" {
				over, _ := LoadFile(c.layer)
				doc.Merge(over)
			}
			if c.schema != "" {
				schema, _ := LoadFile(c.schema)
				doc.Validate(schema)
				validated++
			}
		}
	}
	var heap, routines [2]uint64
	for r := 1; r <= 2*rounds; r++ {
		round(r)
		if r%rounds == 0 {
			heap[r/rounds-1] = soakHeap()
			routines[r/rounds-1] = uint64(runtime.NumGoroutine())
		}
	}
	if saved == 0 || validated == 0 {
		t.Fatalf("the loop saved %d and validated %d times", saved, validated)
	}
	writeSoakProfile(t)
	t.Logf("heap in use at round %d: %d, at %d: %d", rounds, heap[0], 2*rounds, heap[1])
	if heap[1] > heap[0]+margin {
		t.Errorf("heap in use grew from %d at round %d to %d at round %d, past the %d margin; profile in cicd/artifacts/soak/", heap[0], rounds, heap[1], 2*rounds, margin)
	}
	if routines[1] != routines[0] {
		t.Errorf("goroutines went from %d at round %d to %d at round %d", routines[0], rounds, routines[1], 2*rounds)
	}
}

func writeSoakProfile(t *testing.T) {
	dir := filepath.Join("..", "..", "cicd", "artifacts", "soak")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("artifacts: %v", err)
	}
	f, err := os.Create(filepath.Join(dir, "go-heap.pprof"))
	if err != nil {
		t.Fatalf("artifacts: %v", err)
	}
	err = pprof.Lookup("heap").WriteTo(f, 0)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		t.Fatalf("heap profile: %v", err)
	}
}
