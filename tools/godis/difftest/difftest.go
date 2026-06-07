// Package difftest is a differential-testing harness for the godis
// Go→Dis compiler. For each Go program in a corpus it:
//
//  1. compiles the program with godis (the in-process compiler package),
//  2. executes the resulting Dis bytecode on the Inferno emulator under
//     both -c0 (interpreter) and -c1 (JIT),
//  3. runs the same program with `go run` to obtain the reference output,
//  4. diffs both emulator runs against the Go reference and classifies the
//     outcome.
//
// The classifier distinguishes a plain divergence (godis disagrees with Go
// the same way in both modes) from a -c0/-c1 mismatch (the interpreter and
// JIT disagree with each other). The latter is the load-bearing invariant:
// the long-standing E2E suite runs interpreter-only and has historically
// masked JIT codegen regressions. Diffing both modes against Go on every run
// surfaces those immediately.
//
// The package is deliberately split from the CLI (cmd/difftest) so the
// classification logic is unit-testable without an emulator.
package difftest

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/NERVsystems/infernode/tools/godis/compiler"
)

// Class is the outcome of differentially testing one program.
type Class string

const (
	// Match: both emulator modes reproduced the Go reference output exactly.
	Match Class = "match"
	// Diverge: the interpreter and JIT agree with each other but disagree
	// with `go run`. A real godis correctness bug, reproducible in either mode.
	Diverge Class = "diverge"
	// JITMismatch: -c0 and -c1 produced different output. A JIT codegen bug
	// (or an interpreter bug the JIT doesn't share). Highest-signal class.
	JITMismatch Class = "c0!=c1"
	// CompileFail: godis could not compile the program.
	CompileFail Class = "compile-fail"
	// Crash: the emulator faulted (panic/fault marker on stderr) in one or
	// both modes rather than producing clean output.
	Crash Class = "crash"
	// GoError: `go run` itself failed or the program is excluded (e.g. marked
	// nondeterministic). Not a godis defect; reported separately and never gated.
	GoError Class = "go-error"
	// Skipped: program carried a `// difftest:skip` directive.
	Skipped Class = "skipped"
)

// AllClasses lists every classification in report order.
var AllClasses = []Class{Match, JITMismatch, Diverge, Crash, CompileFail, GoError, Skipped}

// Program is one unit of the corpus: either a single .go file or a directory
// of .go files (multi-file / multi-package program), mirroring the existing
// godis E2E conventions (compileGo vs compileGoDir).
type Program struct {
	// Name is the stable identifier used in reports and the locked manifest.
	// For a single file it is the path relative to the corpus root; for a
	// directory it is that relative directory path.
	Name string
	// Path is the absolute file or directory path on disk.
	Path string
	// IsDir reports whether Path is a multi-file directory program.
	IsDir bool
	// Skip, if non-empty, is the reason this program is excluded from runs
	// (parsed from a `// difftest:skip <reason>` directive).
	Skip string
}

// Result is the full outcome of testing one Program.
type Result struct {
	Program Program `json:"-"`
	Name    string  `json:"name"`
	Class   Class   `json:"class"`

	GoOut    string `json:"-"`
	C0Out    string `json:"-"`
	C1Out    string `json:"-"`
	C0Crash  bool   `json:"c0_crash,omitempty"`
	C1Crash  bool   `json:"c1_crash,omitempty"`
	CompErr  string `json:"compile_error,omitempty"`
	GoErr    string `json:"go_error,omitempty"`
	Detail   string `json:"detail,omitempty"`
	Duration string `json:"duration,omitempty"`
}

// Config controls a harness run.
type Config struct {
	EmuPath string        // path to the Inferno emulator (o.emu)
	RootDir string        // emu -r root (Inferno "/" maps here)
	Timeout time.Duration // per-emulator-run wall clock (emu hangs; we kill it)
	GoBin   string        // `go` binary (default "go")
	Jobs    int           // parallel workers (default GOMAXPROCS)
	WorkDir string        // scratch dir for .dis files (must be under RootDir)
}

// crashMarkers are substrings the emulator emits on a fault. The Dis VM prints
// these to stdout (e.g. `[Prog] Broken: "sys: segmentation violation ..."`,
// `SYS: process dis fault`) as well as occasionally to stderr, so we scan both
// streams. A marker only escalates an already-diverging result to Crash; a run
// whose output is byte-identical to `go run` is always a Match regardless (see
// Classify), so a program that legitimately prints one of these words is not
// misclassified.
var crashMarkers = []string{
	"broken:",
	"segmentation violation",
	"process dis fault",
	"dereference of nil",
	"module exception",
	"bad ref count",
	"out of memory",
	"trap:",
	"panic:",
}

// skipRe matches a `// difftest:skip [reason]` directive anywhere in a source.
var skipRe = regexp.MustCompile(`(?m)^\s*//\s*difftest:\s*(?:skip|nondeterministic)\b[ \t]*(.*)$`)

// DiscoverCorpus walks one or more corpus roots and returns the programs found.
// Within a root, top-level .go files are single-file programs and immediate
// subdirectories that contain at least one .go file are directory (multi-file /
// multi-package) programs.
//
// Program names are made relative to base, not to each root, so that several
// roots (e.g. testdata and corpus/seed) can be scanned together without name
// collisions and the resulting names ("testdata/hello.go", "corpus/seed/x.go")
// are stable across machines. If a path is not under base, its name falls back
// to a root-relative path.
func DiscoverCorpus(base string, roots ...string) ([]Program, error) {
	absBase, _ := filepath.Abs(base)
	var progs []Program
	seen := map[string]bool{}
	for _, root := range roots {
		absRoot, err := filepath.Abs(root)
		if err != nil {
			return nil, err
		}
		info, err := os.Stat(absRoot)
		if err != nil {
			return nil, err
		}
		// A root may itself be a single directory program.
		if info.IsDir() {
			if err := discoverDir(absBase, absRoot, seen, &progs); err != nil {
				return nil, err
			}
		} else if strings.HasSuffix(absRoot, ".go") {
			p := newFileProgram(absBase, absRoot)
			if !seen[p.Path] {
				seen[p.Path] = true
				progs = append(progs, p)
			}
		}
	}
	sort.Slice(progs, func(i, j int) bool { return progs[i].Name < progs[j].Name })
	return progs, nil
}

func discoverDir(base, dir string, seen map[string]bool, out *[]Program) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		full := filepath.Join(dir, e.Name())
		if e.IsDir() {
			if hasGoFiles(full) {
				p := Program{Name: relName(base, full), Path: full, IsDir: true, Skip: dirSkip(full)}
				if !seen[p.Path] {
					seen[p.Path] = true
					*out = append(*out, p)
				}
			}
			continue
		}
		if strings.HasSuffix(e.Name(), ".go") && !strings.HasSuffix(e.Name(), "_test.go") {
			p := newFileProgram(base, full)
			if !seen[p.Path] {
				seen[p.Path] = true
				*out = append(*out, p)
			}
		}
	}
	return nil
}

func newFileProgram(base, file string) Program {
	return Program{Name: relName(base, file), Path: file, Skip: fileSkip(file)}
}

// relName returns path relative to base in slash form, falling back to the base
// name if path is not under base (e.g. a temp dir on another volume).
func relName(base, path string) string {
	rel, err := filepath.Rel(base, path)
	if err != nil || strings.HasPrefix(rel, "..") {
		return filepath.Base(path)
	}
	return filepath.ToSlash(rel)
}

func hasGoFiles(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".go") {
			return true
		}
	}
	return false
}

func fileSkip(file string) string {
	src, err := os.ReadFile(file)
	if err != nil {
		return ""
	}
	if m := skipRe.FindSubmatch(src); m != nil {
		if r := strings.TrimSpace(string(m[1])); r != "" {
			return r
		}
		return "marked nondeterministic"
	}
	return ""
}

func dirSkip(dir string) string {
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".go") {
			if r := fileSkip(filepath.Join(dir, e.Name())); r != "" {
				return r
			}
		}
	}
	return ""
}

// Runner executes the harness against a corpus.
type Runner struct {
	cfg Config
}

// NewRunner validates cfg and returns a Runner.
func NewRunner(cfg Config) (*Runner, error) {
	if cfg.EmuPath == "" {
		return nil, fmt.Errorf("difftest: EmuPath is required")
	}
	if cfg.RootDir == "" {
		return nil, fmt.Errorf("difftest: RootDir is required")
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 4 * time.Second
	}
	if cfg.GoBin == "" {
		cfg.GoBin = "go"
	}
	if cfg.Jobs <= 0 {
		cfg.Jobs = 1
	}
	if cfg.WorkDir == "" {
		cfg.WorkDir = filepath.Join(cfg.RootDir, "tmp", "difftest")
	}
	if err := os.MkdirAll(cfg.WorkDir, 0o777); err != nil {
		return nil, fmt.Errorf("difftest: create workdir: %w", err)
	}
	// emu needs a writable /tmp inside the Inferno namespace for file-creating
	// programs; mirror the E2E suite's ensureInfernoTmp.
	_ = os.MkdirAll(filepath.Join(cfg.RootDir, "tmp"), 0o777)
	return &Runner{cfg: cfg}, nil
}

// Run tests every program, fanning out across cfg.Jobs workers. Results are
// returned in corpus (sorted) order.
func (r *Runner) Run(progs []Program) []Result {
	results := make([]Result, len(progs))
	sem := make(chan struct{}, r.cfg.Jobs)
	var wg sync.WaitGroup
	for i := range progs {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			results[i] = r.RunOne(progs[i])
		}(i)
	}
	wg.Wait()
	return results
}

// RunOne tests a single program end to end.
func (r *Runner) RunOne(p Program) Result {
	start := time.Now()
	res := Result{Program: p, Name: p.Name}
	defer func() { res.Duration = time.Since(start).Round(time.Millisecond).String() }()

	if p.Skip != "" {
		res.Class = Skipped
		res.Detail = p.Skip
		return res
	}

	// Oracle first: if Go itself can't run it, there is nothing to diff against.
	goOut, goErr := r.runGo(p)
	res.GoOut = goOut
	if goErr != "" {
		res.Class = GoError
		res.GoErr = goErr
		return res
	}

	disPath, compErr := r.compile(p)
	if compErr != "" {
		res.Class = CompileFail
		res.CompErr = compErr
		return res
	}
	defer os.Remove(disPath)

	c0Out, c0Crash := r.runEmu(disPath, "-c0")
	c1Out, c1Crash := r.runEmu(disPath, "-c1")
	res.C0Out, res.C1Out = c0Out, c1Out
	res.C0Crash, res.C1Crash = c0Crash, c1Crash

	res.Class = Classify(goOut, c0Out, c1Out, c0Crash, c1Crash)
	res.Detail = detail(res.Class, goOut, c0Out, c1Out)
	return res
}

// Classify is the pure decision function, factored out for unit testing.
//
// Precedence is deliberate:
//
//   - A -c0/-c1 disagreement is JITMismatch even if one mode happens to match
//     Go, because the modes disagreeing with each other is itself the bug.
//   - Otherwise, output byte-identical to `go run` is a Match — a genuine VM
//     fault cannot reproduce Go's complete output, so this also protects
//     programs that legitimately print a crash-marker word.
//   - A fault marker (in either mode) on a non-matching, mode-agreeing result
//     escalates Diverge to the more informative Crash.
func Classify(goOut, c0Out, c1Out string, c0Crash, c1Crash bool) Class {
	if c0Out != c1Out {
		return JITMismatch
	}
	// modes agree from here on
	if c0Out == goOut {
		return Match
	}
	if c0Crash || c1Crash {
		return Crash
	}
	return Diverge
}

func detail(class Class, goOut, c0Out, c1Out string) string {
	switch class {
	case JITMismatch:
		return fmt.Sprintf("c0=%s c1=%s go=%s", trunc(c0Out), trunc(c1Out), trunc(goOut))
	case Diverge, Crash:
		return fmt.Sprintf("got=%s want=%s", trunc(c0Out), trunc(goOut))
	default:
		return ""
	}
}

func trunc(s string) string {
	s = strings.ReplaceAll(s, "\n", "\\n")
	const max = 80
	if len(s) > max {
		return fmt.Sprintf("%q…", s[:max])
	}
	return fmt.Sprintf("%q", s)
}

// compile builds the program to a .dis file in WorkDir and returns its path,
// or a compile-error string. The file is created under RootDir so emu can load
// it via an Inferno-absolute path.
func (r *Runner) compile(p Program) (disPath, compErr string) {
	defer func() {
		if rec := recover(); rec != nil {
			compErr = fmt.Sprintf("compiler panic: %v", rec)
		}
	}()

	c := compiler.New()
	var mod interface {
		EncodeToBytes() ([]byte, error)
	}
	var err error

	if p.IsDir {
		entries, derr := os.ReadDir(p.Path)
		if derr != nil {
			return "", derr.Error()
		}
		var names []string
		var srcs [][]byte
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") || strings.HasSuffix(e.Name(), "_test.go") {
				continue
			}
			src, rerr := os.ReadFile(filepath.Join(p.Path, e.Name()))
			if rerr != nil {
				return "", rerr.Error()
			}
			names = append(names, e.Name())
			srcs = append(srcs, src)
		}
		c.BaseDir = p.Path
		mod, err = c.CompileFiles(names, srcs)
	} else {
		src, rerr := os.ReadFile(p.Path)
		if rerr != nil {
			return "", rerr.Error()
		}
		c.BaseDir = filepath.Dir(p.Path)
		mod, err = c.CompileFile(filepath.Base(p.Path), src)
	}
	if err != nil {
		return "", err.Error()
	}

	encoded, err := mod.EncodeToBytes()
	if err != nil {
		return "", "encode: " + err.Error()
	}

	// Unique, collision-free name under WorkDir.
	sum := sha256.Sum256([]byte(p.Name))
	disPath = filepath.Join(r.cfg.WorkDir, hex.EncodeToString(sum[:8])+".dis")
	if err := os.WriteFile(disPath, encoded, 0o644); err != nil {
		return "", "write: " + err.Error()
	}
	return disPath, ""
}

// runEmu executes a .dis file under the given JIT mode ("-c0" or "-c1") and
// returns its stdout plus whether the run crashed. The emulator does not exit
// cleanly — it hangs after the program returns — so we always run under a
// timeout and treat the kill as expected, keeping whatever stdout was produced.
func (r *Runner) runEmu(disPath, mode string) (out string, crashed bool) {
	rel, err := filepath.Rel(r.cfg.RootDir, disPath)
	if err != nil {
		return "", true
	}
	infernoPath := "/" + filepath.ToSlash(rel)

	ctx, cancel := context.WithTimeout(context.Background(), r.cfg.Timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, r.cfg.EmuPath, "-r"+r.cfg.RootDir, mode, infernoPath)
	cmd.Dir = r.cfg.RootDir
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	_ = cmd.Run() // timeout-kill is expected; rc is not meaningful.

	return stdout.String(), hasCrashMarker(stdout.String()) || hasCrashMarker(stderr.String())
}

func hasCrashMarker(stderr string) bool {
	low := strings.ToLower(stderr)
	for _, m := range crashMarkers {
		if strings.Contains(low, m) {
			return true
		}
	}
	return false
}

// runGo executes the program with `go run` and returns its combined output, or
// an error string if the build/run failed (nonzero exit).
//
// We capture stdout and stderr through a single writer so the two streams stay
// in program-write order. This is required because Go's builtin print/println
// write to stderr while godis routes those builtins to the emulator's stdout;
// comparing godis stdout against go's combined output is the only way the two
// agree on the dominant corpus pattern (200+ programs use builtin println).
// On a clean run `go run` emits nothing of its own to stderr, so the combined
// buffer is exactly the program's output. On failure (build error / panic /
// nonzero exit) the captured text becomes the error string.
func (r *Runner) runGo(p Program) (out, goErr string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, r.cfg.GoBin, "run", p.Path)
	var combined strings.Builder
	cmd.Stdout = &combined
	cmd.Stderr = &combined
	err := cmd.Run()
	if err != nil {
		msg := strings.TrimSpace(combined.String())
		if msg == "" {
			msg = err.Error()
		}
		return "", msg
	}
	return combined.String(), ""
}
