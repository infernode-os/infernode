package difftest

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
)

// Summary aggregates a set of Results into counts and per-class name lists.
type Summary struct {
	Total   int                `json:"total"`
	Counts  map[Class]int      `json:"counts"`
	Members map[Class][]string `json:"members"`
}

// Summarize tallies results by class.
func Summarize(results []Result) Summary {
	s := Summary{
		Total:   len(results),
		Counts:  map[Class]int{},
		Members: map[Class][]string{},
	}
	for _, r := range results {
		s.Counts[r.Class]++
		s.Members[r.Class] = append(s.Members[r.Class], r.Name)
	}
	for _, m := range s.Members {
		sort.Strings(m)
	}
	return s
}

// WriteText prints a human-readable summary followed by the offending programs
// for every non-passing class.
func WriteText(w io.Writer, results []Result) {
	s := Summarize(results)
	fmt.Fprintf(w, "differential test: %d programs\n", s.Total)
	for _, c := range AllClasses {
		if n := s.Counts[c]; n > 0 {
			fmt.Fprintf(w, "  %-12s %d\n", c, n)
		}
	}
	// Detail the classes worth a human's attention.
	for _, c := range []Class{JITMismatch, Diverge, Crash, CompileFail} {
		members := resultsOfClass(results, c)
		if len(members) == 0 {
			continue
		}
		fmt.Fprintf(w, "\n%s (%d):\n", c, len(members))
		for _, r := range members {
			if r.Detail != "" {
				fmt.Fprintf(w, "  %-36s %s\n", r.Name, r.Detail)
			} else if r.CompErr != "" {
				fmt.Fprintf(w, "  %-36s %s\n", r.Name, firstLine(r.CompErr))
			} else {
				fmt.Fprintf(w, "  %s\n", r.Name)
			}
		}
	}
}

// WriteMarkdown writes a report suitable for a CI step summary / artifact.
func WriteMarkdown(w io.Writer, results []Result, title string) {
	s := Summarize(results)
	if title == "" {
		title = "GoDis differential test"
	}
	fmt.Fprintf(w, "# %s\n\n", title)
	fmt.Fprintf(w, "**%d programs** — godis `-c0`/`-c1` vs `go run`\n\n", s.Total)
	fmt.Fprintf(w, "| class | count |\n|---|---|\n")
	for _, c := range AllClasses {
		if n := s.Counts[c]; n > 0 {
			fmt.Fprintf(w, "| `%s` | %d |\n", c, n)
		}
	}
	for _, c := range []Class{JITMismatch, Diverge, Crash, CompileFail} {
		members := resultsOfClass(results, c)
		if len(members) == 0 {
			continue
		}
		fmt.Fprintf(w, "\n## %s (%d)\n\n", c, len(members))
		for _, r := range members {
			d := r.Detail
			if d == "" {
				d = firstLine(r.CompErr)
			}
			fmt.Fprintf(w, "- `%s` — %s\n", r.Name, d)
		}
	}
}

// WriteJSON writes the full result set as JSON.
func WriteJSON(w io.Writer, results []Result) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(struct {
		Summary Summary  `json:"summary"`
		Results []Result `json:"results"`
	}{Summarize(results), results})
}

func resultsOfClass(results []Result, c Class) []Result {
	var out []Result
	for _, r := range results {
		if r.Class == c {
			out = append(out, r)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// FirstLine returns s up to the first newline (exported for CLI use).
func FirstLine(s string) string { return firstLine(s) }

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// LoadLocked reads a locked-corpus manifest: one program name per line, '#'
// comments and blank lines ignored. The locked set names programs that have
// been validated to match `go run` and must keep matching — CI gates on them.
func LoadLocked(path string) (map[string]bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	locked := map[string]bool{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		locked[line] = true
	}
	return locked, sc.Err()
}

// LoadSkip reads a skip manifest: one program name per line with an optional
// `name # reason` suffix. Programs listed here are excluded from execution
// (classified Skipped) — used for testdata programs that have no faithful Go
// oracle (Inferno-only sys calls), that are inherently nondeterministic
// (goroutine/select scheduling, map order, timestamps), or that depend on
// behavior Go leaves implementation-defined (builtin print float format, append
// growth / cap). This keeps such programs out of the corpus without editing the
// upstream testdata files.
func LoadSkip(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	skip := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, reason := line, "skipped"
		if i := strings.IndexByte(line, '#'); i >= 0 {
			name = strings.TrimSpace(line[:i])
			if r := strings.TrimSpace(line[i+1:]); r != "" {
				reason = r
			}
		}
		if name != "" {
			skip[name] = reason
		}
	}
	return skip, sc.Err()
}

// GateLocked checks every locked program against the results. A locked program
// must be present and classified Match; anything else (diverge, c0!=c1, crash,
// compile-fail, missing) is a regression. Returns the list of violations.
func GateLocked(results []Result, locked map[string]bool) []Result {
	byName := map[string]Result{}
	for _, r := range results {
		byName[r.Name] = r
	}
	var violations []Result
	names := make([]string, 0, len(locked))
	for n := range locked {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		r, ok := byName[n]
		if !ok {
			violations = append(violations, Result{Name: n, Class: GoError, Detail: "locked program not found in corpus"})
			continue
		}
		if r.Class != Match {
			violations = append(violations, r)
		}
	}
	return violations
}

// Promote returns the union of the existing locked set and every program that
// newly matched, as a sorted manifest body. Programs are only ever added, never
// removed — a program that regressed stays locked so the gate catches it.
func Promote(results []Result, locked map[string]bool) []string {
	set := map[string]bool{}
	for n := range locked {
		set[n] = true
	}
	for _, r := range results {
		if r.Class == Match {
			set[r.Name] = true
		}
	}
	out := make([]string, 0, len(set))
	for n := range set {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// WriteLocked writes a manifest body with a header comment to path.
func WriteLocked(path string, names []string) error {
	var b strings.Builder
	b.WriteString("# GoDis differential-test locked corpus.\n")
	b.WriteString("# Programs whose godis -c0 AND -c1 output matches `go run`.\n")
	b.WriteString("# CI fails if any listed program stops matching (regression gate).\n")
	b.WriteString("# Regenerate/extend with: go run ./cmd/difftest -promote\n")
	b.WriteString("# One program name per line (path relative to its corpus root).\n\n")
	for _, n := range names {
		b.WriteString(n)
		b.WriteByte('\n')
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}
