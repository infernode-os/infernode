package difftest

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestClassify(t *testing.T) {
	tests := []struct {
		name                string
		goOut, c0Out, c1Out string
		c0Crash, c1Crash    bool
		want                Class
	}{
		{"match", "ok\n", "ok\n", "ok\n", false, false, Match},
		{"diverge both modes agree", "ok\n", "bad\n", "bad\n", false, false, Diverge},
		{"jit mismatch wins over match", "ok\n", "ok\n", "bad\n", false, false, JITMismatch},
		{"jit mismatch wins over crash", "ok\n", "ok\n", "", false, true, JITMismatch},
		{"crash both modes", "ok\n", "", "", true, true, Crash},
		{"crash but modes differ is jit", "ok\n", "a\n", "b\n", true, true, JITMismatch},
		{"empty go empty modes match", "", "", "", false, false, Match},
		{"identical to go wins over crash flag", "ok\n", "ok\n", "ok\n", true, true, Match},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Classify(tt.goOut, tt.c0Out, tt.c1Out, tt.c0Crash, tt.c1Crash)
			if got != tt.want {
				t.Errorf("Classify = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestHasCrashMarker(t *testing.T) {
	if !hasCrashMarker("fs: foo\nmodule exception: nil deref\n") {
		t.Error("expected crash marker detected")
	}
	if hasCrashMarker("fs: fsqid: top-bit dev: 0xfe00\n") {
		t.Error("benign fs line must not count as crash")
	}
	if hasCrashMarker("") {
		t.Error("empty stderr is not a crash")
	}
}

func TestDiscoverCorpus(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, "a.go"), "package main\nfunc main(){}\n")
	mustWrite(t, filepath.Join(dir, "b.go"), "package main\n// difftest:skip map order\nfunc main(){}\n")
	mustWrite(t, filepath.Join(dir, "ignore_test.go"), "package main\n")
	sub := filepath.Join(dir, "multi")
	if err := os.Mkdir(sub, 0o777); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, filepath.Join(sub, "main.go"), "package main\nfunc main(){}\n")
	mustWrite(t, filepath.Join(sub, "helper.go"), "package main\n")

	progs, err := DiscoverCorpus(dir, dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	skips := map[string]string{}
	dirs := map[string]bool{}
	for _, p := range progs {
		names = append(names, p.Name)
		if p.Skip != "" {
			skips[p.Name] = p.Skip
		}
		dirs[p.Name] = p.IsDir
	}
	want := []string{"a.go", "b.go", "multi"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("names = %v, want %v (no _test.go, dir collapsed)", names, want)
	}
	if skips["b.go"] != "map order" {
		t.Errorf("b.go skip reason = %q, want %q", skips["b.go"], "map order")
	}
	if !dirs["multi"] {
		t.Errorf("multi should be a directory program")
	}
}

func TestGateLocked(t *testing.T) {
	results := []Result{
		{Name: "good.go", Class: Match},
		{Name: "bad.go", Class: Diverge},
		{Name: "jit.go", Class: JITMismatch},
	}
	locked := map[string]bool{"good.go": true, "bad.go": true, "missing.go": true}
	v := GateLocked(results, locked)
	got := map[string]Class{}
	for _, r := range v {
		got[r.Name] = r.Class
	}
	if _, ok := got["good.go"]; ok {
		t.Error("good.go matched, should not be a violation")
	}
	if got["bad.go"] != Diverge {
		t.Errorf("bad.go violation class = %q", got["bad.go"])
	}
	if got["missing.go"] != GoError {
		t.Errorf("missing.go should be flagged as not-found, got %q", got["missing.go"])
	}
	if len(v) != 2 {
		t.Errorf("expected 2 violations (bad, missing), got %d", len(v))
	}
}

func TestPromote(t *testing.T) {
	results := []Result{
		{Name: "new.go", Class: Match},
		{Name: "bad.go", Class: Diverge},
	}
	locked := map[string]bool{"old.go": true, "bad.go": true}
	got := Promote(results, locked)
	want := []string{"bad.go", "new.go", "old.go"} // bad.go stays (never removed)
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Promote = %v, want %v", got, want)
	}
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
