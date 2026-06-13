// Command gencorpus generates a deterministic, combinatorial corpus of small
// Go programs for the godis differential-testing harness.
//
// Every generated program is a standalone `package main` with deterministic
// output. Output is produced with the fmt package (to stdout) rather than the
// builtin print/println, because the Go spec leaves builtin print formatting
// (notably floats) implementation-defined, which makes it an unreliable
// differential oracle. The programs deliberately avoid floats, goroutine
// scheduling, and map iteration order so that `go run` is reproducible and can
// serve as ground truth.
//
// Usage:
//
//	gencorpus [-out dir]
//
// The default output directory is the _corpus dir relative to the binary (run
// from tools/godis: `go run ./cmd/gencorpus`). Only previously-generated
// gen_*.go files are cleared first — hand-written seed_*.go programs in the same
// directory are left untouched — so the generated corpus is fully reproducible.
// The directory is named with a leading underscore so the go tool ignores it
// (each program is its own package main).
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type prog struct {
	name string
	body string
}

func main() {
	out := flag.String("out", "", "output directory (default: ../../corpus/generated)")
	flag.Parse()

	dir := *out
	if dir == "" {
		dir = filepath.Join("..", "..", "_corpus")
		if _, err := os.Stat("_corpus"); err == nil {
			dir = "_corpus"
		}
	}
	if err := os.MkdirAll(dir, 0o777); err != nil {
		fmt.Fprintln(os.Stderr, "gencorpus:", err)
		os.Exit(1)
	}
	// Clear previously-generated programs for reproducibility.
	matches, _ := filepath.Glob(filepath.Join(dir, "gen_*.go"))
	for _, m := range matches {
		_ = os.Remove(m)
	}

	progs := generate()
	for _, p := range progs {
		path := filepath.Join(dir, "gen_"+p.name+".go")
		if err := os.WriteFile(path, []byte(p.body), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "gencorpus:", err)
			os.Exit(1)
		}
	}
	fmt.Printf("gencorpus: wrote %d programs to %s\n", len(progs), dir)
}

// generate returns the full deterministic program set.
func generate() []prog {
	var ps []prog
	ps = append(ps, sliceProgs()...)
	ps = append(ps, mapProgs()...)
	ps = append(ps, closureProgs()...)
	ps = append(ps, genericProgs()...)
	ps = append(ps, deferProgs()...)
	ps = append(ps, errorProgs()...)
	ps = append(ps, intProgs()...)
	ps = append(ps, valueCopyProgs()...)
	ps = append(ps, globalProgs()...)
	ps = append(ps, deferRecoverProgs()...)
	ps = append(ps, strconvProgs()...)
	ps = append(ps, miscProgs()...)
	return ps
}

// miscProgs covers user variadic functions, type switches, deterministic
// channel pipelines, per-iteration loop captures, select-with-default,
// and struct-valued maps.
func miscProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"variadic_user", header([]string{"fmt"}, `	fmt.Println(sum("three", 1, 2, 3))
	fmt.Println(sum("none"))
	s := []int{4, 5}
	fmt.Println(sum("spread", s...))
}

func sum(label string, xs ...int) int {
	t := 0
	for _, x := range xs {
		t += x
	}
	fmt.Println(label, len(xs))
	return t
`)})

	ps = append(ps, prog{"typeswitch_describe", header([]string{"fmt"}, `	fmt.Println(describe(7), describe("hi"), describe(false), describe([]int{1, 2}), describe(3.5))
}

func describe(v interface{}) string {
	switch x := v.(type) {
	case int:
		return fmt.Sprintf("int:%d", x)
	case string:
		return "str:" + x
	case bool:
		if x {
			return "bool:t"
		}
		return "bool:f"
	case []int:
		return fmt.Sprintf("slice:%d", len(x))
	default:
		return "other"
	}
`)})

	ps = append(ps, prog{"chan_worker", header([]string{"fmt"}, `	in := make(chan int, 8)
	out := make(chan int, 8)
	go worker(in, out)
	for i := 1; i <= 5; i++ {
		in <- i
	}
	close(in)
	total := 0
	for i := 0; i < 5; i++ {
		total += <-out
	}
	fmt.Println(total)
}

func worker(in <-chan int, out chan<- int) {
	for v := range in {
		out <- v * v
	}
`)})

	ps = append(ps, prog{"loop_capture", header([]string{"fmt"}, `	funcs := []func() int{}
	for i := 0; i < 3; i++ {
		funcs = append(funcs, func() int { return i })
	}
	for _, f := range funcs {
		fmt.Println(f())
	}
`)})

	ps = append(ps, prog{"select_default", header([]string{"fmt"}, `	ch := make(chan int, 1)
	select {
	case v := <-ch:
		fmt.Println("got", v)
	default:
		fmt.Println("empty")
	}
	ch <- 9
	select {
	case v := <-ch:
		fmt.Println("got", v)
	default:
		fmt.Println("empty")
	}
`)})

	ps = append(ps, prog{"map_structval", header([]string{"fmt"}, `	type rec struct {
		name string
		hits int
	}
	m := map[int]rec{}
	m[1] = rec{"a", 10}
	m[2] = rec{"b", 20}
	m[1] = rec{"a2", 11}
	v, ok := m[1]
	fmt.Println(v.name, v.hits, ok)
	_, miss := m[9]
	fmt.Println(miss)
	delete(m, 1)
	fmt.Println(len(m))
	w := m[2]
	fmt.Println(w.name, w.hits)
	m[3] = rec{"c", 30}
	fmt.Println(len(m), m[3].name)
`)})

	ps = append(ps, prog{"labeled_flow", header([]string{"fmt"}, `	a, b := 1, 2
	a, b = b, a
	fmt.Println(a, b)
	steps := 0
outer:
	for i := 0; i < 4; i++ {
		for j := 0; j < 4; j++ {
			steps++
			if i*j == 6 {
				break outer
			}
			if j == 2 {
				continue outer
			}
		}
	}
	fmt.Println(steps)
`)})

	return ps
}

// intProgs exercises integer semantics edges: truncated division and
// remainder with negative operands, sub-word truncation, unsigned
// comparison and division, and shift behavior.
func intProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"int_negdiv", header([]string{"fmt"}, `	pairs := [][2]int{{7, 3}, {-7, 3}, {7, -3}, {-7, -3}}
	for _, p := range pairs {
		fmt.Println(p[0]/p[1], p[0]%p[1])
	}
`)})

	ps = append(ps, prog{"int_subword", header([]string{"fmt"}, `	var a int8 = 127
	a++
	var b uint8 = 255
	b++
	var c int16 = 32767
	c++
	var d uint16 = 65535
	d++
	var e int32 = 2147483647
	e++
	fmt.Println(a, b, c, d, e)
	p, q := uint8(200), uint8(100)
	fmt.Println(p + q)
`)})

	ps = append(ps, prog{"int_unsigned", header([]string{"fmt"}, `	var big uint64 = 1 << 63
	var small uint64 = 5
	fmt.Println(big > small)
	fmt.Println(big / 2)
	fmt.Println(uint32(4000000000) > uint32(5))
	var x uint = 3
	x -= 5
	fmt.Println(x > 1000)
`)})

	ps = append(ps, prog{"int_shift", header([]string{"fmt"}, `	fmt.Println(1<<10, 1024>>3)
	var v int64 = -8
	fmt.Println(v >> 1)
	var u uint64 = 1 << 62
	fmt.Println(u<<1, u>>61)
	n := 4
	fmt.Println(1<<n, 256>>n)
`)})

	ps = append(ps, prog{"int_bitops", header([]string{"fmt"}, `	a, b := 0xF0, 0x3C
	fmt.Println(a&b, a|b, a^b, a&^b)
	fmt.Println(^a)
	count := 0
	for x := 0x5A; x != 0; x &= x - 1 {
		count++
	}
	fmt.Println(count)
`)})

	return ps
}

// valueCopyProgs exercises Go's by-value copy semantics for arrays and
// structs (assignment, parameter passing, range copies).
func valueCopyProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"array_value_copy", header([]string{"fmt"}, `	a := [3]int{1, 2, 3}
	b := a
	b[0] = 99
	fmt.Println(a[0], b[0])
	mutate(a)
	fmt.Println(a[1])
}

func mutate(arr [3]int) {
	arr[1] = 42
`)})

	ps = append(ps, prog{"struct_value_copy", header([]string{"fmt"}, `	type point struct{ x, y int }
	p := point{1, 2}
	q := p
	q.x = 9
	fmt.Println(p.x, q.x)
	pts := []point{{1, 1}, {2, 2}}
	for _, v := range pts {
		v.y = 0
	}
	fmt.Println(pts[0].y, pts[1].y)
`)})

	ps = append(ps, prog{"matrix_dynamic", header([]string{"fmt"}, `	var m [4][3]int
	for i := 0; i < 4; i++ {
		for j := 0; j < 3; j++ {
			m[i][j] = i*3 + j
		}
	}
	total := 0
	for i := 0; i < 4; i++ {
		for j := 0; j < 3; j++ {
			total += m[i][j]
		}
	}
	fmt.Println(total, m[3][2], m[0][0])
`)})

	ps = append(ps, prog{"array_in_struct", header([]string{"fmt"}, `	type buf struct {
		n    int
		data [4]int
	}
	var b buf
	for i := 0; i < 4; i++ {
		b.data[i] = i * i
		b.n++
	}
	c := b
	c.data[0] = 100
	fmt.Println(b.n, b.data[0], b.data[3], c.data[0])
`)})

	return ps
}

// globalProgs exercises package-level variable initialization: literal
// initializers, dependencies between globals, init() interplay, and
// interface-typed globals.
func globalProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"global_init_order", header([]string{"fmt"}, `	fmt.Println(a, b, c)
}

var a = 10
var b = a * 2
var c = b + a

func init() {
	c += 100
`)})

	ps = append(ps, prog{"global_map_init", header([]string{"fmt"}, `	fmt.Println(scores["alice"], scores["bob"], len(scores))
	scores["carol"] = 3
	fmt.Println(len(scores))
}

var scores = map[string]int{"alice": 1, "bob": 2}

func init() {
	scores["alice"]++
`)})

	ps = append(ps, prog{"global_slice_init", header([]string{"fmt"}, `	total := 0
	for _, v := range primes {
		total += v
	}
	fmt.Println(total, len(primes), names[1])
}

var primes = []int{2, 3, 5, 7, 11}
var names = []string{"zero", "one", "two"}

func init() {
	names = append(names, "three")
`)})

	ps = append(ps, prog{"global_iface", header([]string{"errors", "fmt"}, `	fmt.Println(errA.Error())
	if errA != errB {
		fmt.Println("distinct")
	}
	fmt.Println(counter())
	fmt.Println(counter())
}

var errA = errors.New("alpha")
var errB = errors.New("beta")
var calls = 0

func counter() int {
	calls++
	return calls
`)})

	return ps
}

// deferRecoverProgs exercises the runtime defer model: conditional defers,
// defers in loops with recover, and named results assigned by deferred
// closures on the panic path.
func deferRecoverProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"defer_conditional", header([]string{"fmt"}, `	report(true)
	report(false)
}

func report(c bool) {
	if c {
		defer fmt.Println("cleanup")
	}
	fmt.Println("work", c)
`)})

	ps = append(ps, prog{"defer_recover_named", header([]string{"fmt"}, `	fmt.Println(safeDiv(10, 2))
	fmt.Println(safeDiv(1, 0))
}

func safeDiv(a, b int) (q int, err string) {
	defer func() {
		if r := recover(); r != nil {
			err = "caught"
		}
	}()
	q = a / b
	return q, ""
`)})

	ps = append(ps, prog{"defer_loop_recover", header([]string{"fmt"}, `	fmt.Println(run())
}

func run() (out int) {
	defer func() {
		recover()
		out = -1
	}()
	for i := 1; i <= 3; i++ {
		defer func(v int) { fmt.Println("undo", v) }(i)
	}
	panic("stop")
`)})

	ps = append(ps, prog{"defer_mixed_args", header([]string{"fmt"}, `	x := 5
	defer fmt.Println("captured", x)
	x = 9
	s := "hi"
	defer fmt.Println(s, x)
	s = "bye"
	fmt.Println("body", s, x)
`)})

	return ps
}

// strconvProgs exercises strconv success and error paths.
func strconvProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"strconv_paths", header([]string{"fmt", "strconv"}, `	for _, s := range []string{"42", "-7", "+9", "007", "", "abc", "1x", " 3"} {
		n, err := strconv.Atoi(s)
		if err != nil {
			fmt.Println("err:", err.Error())
		} else {
			fmt.Println("ok:", n)
		}
	}
	fmt.Println(strconv.Itoa(-12345))
	fmt.Println(strconv.FormatInt(255, 16), strconv.FormatInt(8, 2))
`)})

	ps = append(ps, prog{"strconv_parse", header([]string{"fmt", "strconv"}, `	v, err := strconv.ParseInt("-9000", 10, 64)
	fmt.Println(v, err == nil)
	u, uerr := strconv.ParseUint("123", 10, 64)
	fmt.Println(u, uerr == nil)
	_, bad := strconv.ParseUint("-1", 10, 64)
	fmt.Println(bad != nil)
	b, _ := strconv.ParseBool("true")
	fmt.Println(b)
`)})

	return ps
}

// header builds a program with the given imports and main body.
func header(imports []string, body string) string {
	var b strings.Builder
	b.WriteString("// Code generated by gencorpus; DO NOT EDIT.\n")
	b.WriteString("package main\n\n")
	switch len(imports) {
	case 0:
	case 1:
		fmt.Fprintf(&b, "import %q\n\n", imports[0])
	default:
		b.WriteString("import (\n")
		for _, im := range imports {
			fmt.Fprintf(&b, "\t%q\n", im)
		}
		b.WriteString(")\n\n")
	}
	b.WriteString("func main() {\n")
	b.WriteString(body)
	b.WriteString("}\n")
	return b.String()
}

func sliceProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"slice_append_len", header([]string{"fmt"}, `	s := []int{}
	for i := 1; i <= 5; i++ {
		s = append(s, i*i)
	}
	fmt.Println(len(s))
	sum := 0
	for _, v := range s {
		sum += v
	}
	fmt.Println(sum)
`)})

	ps = append(ps, prog{"slice_copy", header([]string{"fmt"}, `	src := []int{1, 2, 3, 4}
	dst := make([]int, 2)
	n := copy(dst, src)
	fmt.Println(n, dst[0], dst[1])
`)})

	ps = append(ps, prog{"slice_subslice", header([]string{"fmt"}, `	s := []int{10, 20, 30, 40, 50}
	a := s[1:4]
	fmt.Println(len(a), a[0], a[2])
	b := s[:2]
	fmt.Println(len(b), b[1])
`)})

	ps = append(ps, prog{"slice_2d", header([]string{"fmt"}, `	grid := make([][]int, 3)
	for i := range grid {
		grid[i] = make([]int, 3)
		for j := range grid[i] {
			grid[i][j] = i*3 + j
		}
	}
	total := 0
	for _, row := range grid {
		for _, v := range row {
			total += v
		}
	}
	fmt.Println(total)
`)})

	return ps
}

func mapProgs() []prog {
	var ps []prog

	// Iterate over sorted keys to keep output deterministic.
	ps = append(ps, prog{"map_count", header([]string{"fmt", "sort"}, `	m := map[string]int{}
	words := []string{"a", "b", "a", "c", "b", "a"}
	for _, w := range words {
		m[w]++
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Println(k, m[k])
	}
`)})

	ps = append(ps, prog{"map_commaok", header([]string{"fmt"}, `	m := map[int]string{1: "one", 2: "two"}
	v, ok := m[1]
	fmt.Println(v, ok)
	_, ok2 := m[9]
	fmt.Println(ok2)
	delete(m, 1)
	fmt.Println(len(m))
`)})

	return ps
}

func closureProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"closure_counter", header([]string{"fmt"}, `	counter := func() func() int {
		n := 0
		return func() int { n++; return n }
	}()
	fmt.Println(counter())
	fmt.Println(counter())
	fmt.Println(counter())
`)})

	ps = append(ps, prog{"closure_accumulate", header([]string{"fmt"}, `	total := 0
	add := func(x int) { total += x }
	for i := 1; i <= 4; i++ {
		add(i)
	}
	fmt.Println(total)
`)})

	// Per-iteration variable capture (Go 1.22+ loop semantics).
	ps = append(ps, prog{"closure_loopvar", header([]string{"fmt"}, `	fns := make([]func() int, 0, 3)
	for i := 0; i < 3; i++ {
		fns = append(fns, func() int { return i })
	}
	for _, f := range fns {
		fmt.Println(f())
	}
`)})

	return ps
}

func genericProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"generic_minmax", header([]string{"fmt"}, `	fmt.Println(gmax(3, 7))
	fmt.Println(gmax("apple", "banana"))
	fmt.Println(gmin(3, 7))
}

type ordered interface {
	~int | ~string
}

func gmax[T ordered](a, b T) T {
	if a > b {
		return a
	}
	return b
}

func gmin[T ordered](a, b T) T {
	if a < b {
		return a
	}
	return b
`)})

	ps = append(ps, prog{"generic_mapfilter", header([]string{"fmt"}, `	in := []int{1, 2, 3, 4, 5}
	doubled := mapper(in, func(x int) int { return x * 2 })
	sum := 0
	for _, v := range doubled {
		sum += v
	}
	fmt.Println(sum)
	evens := filter(in, func(x int) bool { return x%2 == 0 })
	fmt.Println(len(evens), evens[0], evens[1])
}

func mapper[T, U any](s []T, f func(T) U) []U {
	out := make([]U, len(s))
	for i, v := range s {
		out[i] = f(v)
	}
	return out
}

func filter[T any](s []T, keep func(T) bool) []T {
	var out []T
	for _, v := range s {
		if keep(v) {
			out = append(out, v)
		}
	}
	return out
`)})

	return ps
}

func deferProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"defer_order", header([]string{"fmt"}, `	for i := 1; i <= 3; i++ {
		defer fmt.Println("deferred", i)
	}
	fmt.Println("body done")
`)})

	// Defer inside a loop, in a helper, runs at function return (LIFO).
	ps = append(ps, prog{"defer_in_loop", header([]string{"fmt"}, `	fmt.Println(run())
}

func run() int {
	sum := 0
	for i := 0; i < 4; i++ {
		defer func(v int) { sum += v }(i)
	}
	// Defers haven't run yet here; they fire after the return value is fixed.
	return collect()
}

func collect() int {
	n := 0
	defer func() { n = 99 }()
	return n
`)})

	// Named return modified by defer.
	ps = append(ps, prog{"defer_named_return", header([]string{"fmt"}, `	fmt.Println(withDefer())
}

func withDefer() (result int) {
	defer func() { result *= 2 }()
	result = 21
	return result
`)})

	return ps
}

func errorProgs() []prog {
	var ps []prog

	ps = append(ps, prog{"error_new", header([]string{"errors", "fmt"}, `	err := errors.New("boom")
	if err != nil {
		fmt.Println("got:", err.Error())
	}
`)})

	ps = append(ps, prog{"error_wrap", header([]string{"errors", "fmt"}, `	base := errors.New("base failure")
	wrapped := fmt.Errorf("operation failed: %w", base)
	fmt.Println(wrapped.Error())
	if errors.Is(wrapped, base) {
		fmt.Println("is base")
	}
	fmt.Println(errors.Unwrap(wrapped).Error())
`)})

	ps = append(ps, prog{"error_sentinel", header([]string{"errors", "fmt"}, `	_, err := lookup(0)
	if errors.Is(err, errNotFound) {
		fmt.Println("not found")
	}
	v, err := lookup(2)
	if err == nil {
		fmt.Println("ok", v)
	}
}

var errNotFound = errors.New("not found")

func lookup(i int) (int, error) {
	if i == 0 {
		return 0, errNotFound
	}
	return i * 10, nil
`)})

	return ps
}
