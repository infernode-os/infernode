package difftest

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// TestE2ELocked is the differential-testing regression gate. It compiles every
// corpus program with godis, runs it on the emulator under -c0 and -c1, diffs
// both against `go run`, and fails if any program in corpus/locked.txt has
// stopped matching `go run` (in either mode).
//
// Because a locked program must classify as Match — which requires
// -c0 == -c1 == go run — this test continuously enforces the -c0/-c1
// consistency invariant that the interpreter-only suite cannot. New divergences
// outside the locked set are reported (t.Log) but do not fail the build; they
// are the ranked worklist for follow-up fixes (see docs/DIFFTEST-FINDINGS.md).
//
// The test skips when the emulator or the go toolchain is unavailable; CI
// guarantees both are present so the gate is enforced there.
func TestE2ELocked(t *testing.T) {
	emu := locate("../../../emu/Linux/o.emu", "../../../emu/MacOSX/o.emu")
	if emu == "" {
		t.Skip("emulator not found; build it to run the differential gate")
	}
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go toolchain not found")
	}
	root := absOr(t, "../../..")        // repo root for emu -r
	nameBase := absOr(t, "..")          // tools/godis: program-name base
	testdata := absOr(t, "../testdata") // existing E2E programs
	corpus := absOr(t, "../_corpus")    // seed + generated programs

	progs, err := DiscoverCorpus(nameBase, testdata, corpus)
	if err != nil {
		t.Fatalf("discover corpus: %v", err)
	}

	// Apply the skip manifest (no faithful go oracle / nondeterministic).
	if skip, err := LoadSkip(absOr(t, "../_corpus/skip.txt")); err == nil {
		for i := range progs {
			if progs[i].Skip == "" {
				if reason, ok := skip[progs[i].Name]; ok {
					progs[i].Skip = reason
				}
			}
		}
	}

	runner, err := NewRunner(Config{
		EmuPath: emu,
		RootDir: root,
		Timeout: 5 * time.Second,
		Jobs:    runtime.NumCPU(),
	})
	if err != nil {
		t.Fatalf("new runner: %v", err)
	}

	results := runner.Run(progs)
	s := Summarize(results)
	t.Logf("differential test: %d programs", s.Total)
	for _, c := range AllClasses {
		if n := s.Counts[c]; n > 0 {
			t.Logf("  %-12s %d", c, n)
		}
	}

	// Hard gate: every locked program must still match.
	locked, err := LoadLocked(absOr(t, "../_corpus/locked.txt"))
	if err != nil {
		t.Fatalf("load locked manifest: %v", err)
	}
	for _, v := range GateLocked(results, locked) {
		d := v.Detail
		if d == "" {
			d = v.CompErr
		}
		t.Errorf("LOCKED REGRESSION %s [%s]: %s", v.Name, v.Class, FirstLine(d))
	}

	// Non-blocking worklist: divergences outside the locked set.
	byName := map[string]Result{}
	for _, r := range results {
		byName[r.Name] = r
	}
	for _, r := range results {
		if locked[r.Name] {
			continue
		}
		switch r.Class {
		case Diverge, JITMismatch, Crash, CompileFail:
			t.Logf("worklist %s [%s]: %s", r.Name, r.Class, FirstLine(r.Detail+r.CompErr))
		}
	}
}

func locate(candidates ...string) string {
	for _, c := range candidates {
		abs, err := filepath.Abs(c)
		if err != nil {
			continue
		}
		if _, err := os.Stat(abs); err == nil {
			return abs
		}
	}
	return ""
}

func absOr(t *testing.T, p string) string {
	t.Helper()
	abs, err := filepath.Abs(p)
	if err != nil {
		t.Fatalf("abs %s: %v", p, err)
	}
	return abs
}
