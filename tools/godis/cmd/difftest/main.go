// Command difftest is the differential-testing harness for godis.
//
// For every Go program in a corpus it compiles with godis, runs the result on
// the Inferno emulator under both -c0 (interpreter) and -c1 (JIT), runs the
// program with `go run`, and classifies the diff:
//
//	match         both emu modes == go run
//	c0!=c1        interpreter and JIT disagree (JIT codegen bug — highest signal)
//	diverge       both emu modes agree but != go run (godis correctness bug)
//	crash         emulator faulted
//	compile-fail  godis could not compile the program
//	go-error      `go run` failed or program excluded (not a godis defect)
//	skipped       program carries a // difftest:skip directive
//
// Usage:
//
//	difftest [flags] [corpus-root ...]
//
// With no corpus roots it defaults to ../../testdata and ../../corpus relative
// to the binary's working directory (run it from tools/godis).
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/NERVsystems/infernode/tools/godis/difftest"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "difftest:", err)
		os.Exit(2)
	}
}

func run() error {
	var (
		emuPath   = flag.String("emu", "", "path to the Inferno emulator (default: autodetect)")
		rootDir   = flag.String("root", "", "emu -r root directory (default: autodetect repo root)")
		timeout   = flag.Duration("timeout", 4*time.Second, "per-emulator-run timeout (emu hangs and is killed)")
		jobs      = flag.Int("jobs", runtime.NumCPU(), "parallel workers")
		jsonOut   = flag.String("json", "", "write full JSON report to this file")
		mdOut     = flag.String("md", "", "write a Markdown report to this file")
		lockedArg = flag.String("locked", "", "locked-corpus manifest to gate against")
		skipArg   = flag.String("skip", "", "skip manifest (programs to exclude; default: corpus/skip.txt if present)")
		failOn    = flag.String("fail-on", "", "comma-separated classes that cause a nonzero exit (e.g. diverge,c0!=c1,crash)")
		promote   = flag.Bool("promote", false, "add newly-matching programs to the -locked manifest (writes the file)")
		list      = flag.Bool("list", false, "list discovered corpus programs and exit")
		quiet     = flag.Bool("quiet", false, "suppress the per-class detail dump on stdout")
	)
	flag.Parse()

	root := *rootDir
	if root == "" {
		root = autodetectRoot()
		if root == "" {
			return fmt.Errorf("could not autodetect repo root; pass -root")
		}
	}

	emu := *emuPath
	if emu == "" {
		emu = autodetectEmu(root)
		if emu == "" {
			return fmt.Errorf("could not find emulator at %s/emu/Linux/o.emu; build it or pass -emu", root)
		}
	}

	roots := flag.Args()
	if len(roots) == 0 {
		roots = defaultCorpusRoots(root)
	}

	// Name programs relative to tools/godis so names are stable and unique
	// across roots (e.g. "testdata/hello.go", "corpus/seed/x.go").
	nameBase := filepath.Join(root, "tools", "godis")

	progs, err := difftest.DiscoverCorpus(nameBase, roots...)
	if err != nil {
		return fmt.Errorf("discover corpus: %w", err)
	}
	if len(progs) == 0 {
		return fmt.Errorf("no programs found in: %s", strings.Join(roots, ", "))
	}

	// Apply the skip manifest (excludes programs without editing testdata).
	skipPath := *skipArg
	if skipPath == "" {
		def := filepath.Join(nameBase, "_corpus", "skip.txt")
		if _, err := os.Stat(def); err == nil {
			skipPath = def
		}
	}
	if skipPath != "" {
		skip, err := difftest.LoadSkip(skipPath)
		if err != nil {
			return fmt.Errorf("load skip manifest: %w", err)
		}
		for i := range progs {
			if progs[i].Skip == "" {
				if reason, ok := skip[progs[i].Name]; ok {
					progs[i].Skip = reason
				}
			}
		}
	}

	if *list {
		for _, p := range progs {
			kind := "file"
			if p.IsDir {
				kind = "dir"
			}
			skip := ""
			if p.Skip != "" {
				skip = "  (skip: " + p.Skip + ")"
			}
			fmt.Printf("%-40s %-4s %s%s\n", p.Name, kind, p.Path, skip)
		}
		return nil
	}

	runner, err := difftest.NewRunner(difftest.Config{
		EmuPath: emu,
		RootDir: root,
		Timeout: *timeout,
		Jobs:    *jobs,
	})
	if err != nil {
		return err
	}

	fmt.Fprintf(os.Stderr, "difftest: %d programs, %d workers, emu=%s\n", len(progs), *jobs, emu)
	start := time.Now()
	results := runner.Run(progs)
	fmt.Fprintf(os.Stderr, "difftest: completed in %s\n", time.Since(start).Round(time.Second))

	if !*quiet {
		difftest.WriteText(os.Stdout, results)
	}

	if *jsonOut != "" {
		f, err := os.Create(*jsonOut)
		if err != nil {
			return err
		}
		if err := difftest.WriteJSON(f, results); err != nil {
			f.Close()
			return err
		}
		f.Close()
	}
	if *mdOut != "" {
		f, err := os.Create(*mdOut)
		if err != nil {
			return err
		}
		difftest.WriteMarkdown(f, results, "GoDis differential test")
		f.Close()
	}

	// Locked-corpus gate and/or promotion.
	exitCode := 0
	if *lockedArg != "" {
		locked, err := difftest.LoadLocked(*lockedArg)
		if err != nil {
			if !os.IsNotExist(err) {
				return fmt.Errorf("load locked manifest: %w", err)
			}
			locked = map[string]bool{}
		}
		if *promote {
			names := difftest.Promote(results, locked)
			if err := difftest.WriteLocked(*lockedArg, names); err != nil {
				return fmt.Errorf("write locked manifest: %w", err)
			}
			added := len(names) - len(locked)
			fmt.Fprintf(os.Stderr, "difftest: locked corpus now %d programs (+%d)\n", len(names), added)
		} else {
			violations := difftest.GateLocked(results, locked)
			if len(violations) > 0 {
				fmt.Printf("\nLOCKED-CORPUS REGRESSIONS (%d):\n", len(violations))
				for _, v := range violations {
					d := v.Detail
					if d == "" {
						d = v.CompErr
					}
					fmt.Printf("  %-36s %-12s %s\n", v.Name, v.Class, difftest.FirstLine(d))
				}
				exitCode = 1
			} else {
				fmt.Printf("\nlocked corpus: all %d programs still match go run\n", len(locked))
			}
		}
	}

	// Arbitrary class gate (e.g. for the full-corpus reporting job).
	if *failOn != "" {
		gate := map[difftest.Class]bool{}
		for _, c := range strings.Split(*failOn, ",") {
			gate[difftest.Class(strings.TrimSpace(c))] = true
		}
		s := difftest.Summarize(results)
		var hit []string
		for c := range gate {
			if s.Counts[c] > 0 {
				hit = append(hit, fmt.Sprintf("%s=%d", c, s.Counts[c]))
			}
		}
		if len(hit) > 0 {
			fmt.Printf("\nFAIL: gated classes present: %s\n", strings.Join(hit, " "))
			exitCode = 1
		}
	}

	os.Exit(exitCode)
	return nil
}

// autodetectRoot finds the repo root by walking up looking for the emu dir or
// the tools/godis module.
func autodetectRoot() string {
	wd, err := os.Getwd()
	if err != nil {
		return ""
	}
	dir := wd
	for {
		if fi, err := os.Stat(filepath.Join(dir, "emu", "port")); err == nil && fi.IsDir() {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	// Fall back to ../../.. from tools/godis/cmd/difftest.
	if abs, err := filepath.Abs(filepath.Join(wd, "..", "..", "..")); err == nil {
		return abs
	}
	return ""
}

func autodetectEmu(root string) string {
	for _, c := range []string{
		filepath.Join(root, "emu", "Linux", "o.emu"),
		filepath.Join(root, "emu", "MacOSX", "o.emu"),
	} {
		if _, err := os.Stat(c); err == nil {
			abs, _ := filepath.Abs(c)
			return abs
		}
	}
	return ""
}

func defaultCorpusRoots(root string) []string {
	var roots []string
	for _, c := range []string{
		filepath.Join(root, "tools", "godis", "testdata"),
		filepath.Join(root, "tools", "godis", "_corpus"),
	} {
		if _, err := os.Stat(c); err == nil {
			roots = append(roots, c)
		}
	}
	return roots
}
