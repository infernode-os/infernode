package main

// Heap-allocated aggregates (escaping values / new(T)) must be
// zero-initialized per SSA Alloc semantics. Emitting INEWZ (zeroing new)
// instead of INEW ensures unwritten scalar fields read as 0 and pointer
// fields as nil, even when the reused heap block held stale data.

type T struct {
	name string
	a, b int
}

func dirty() string {
	t := new(T)
	t.name = "dirty"
	t.a = 111
	t.b = 222
	return t.name
}

func clean() (string, int, int) {
	t := new(T)
	t.a = 7 // name and b never written → must be "" and 0
	return t.name, t.a, t.b
}

func main() {
	dirty()
	n, a, b := clean()
	var emptyName int
	if n == "" {
		emptyName = 1
	}
	println(emptyName, a, b) // 1 7 0
}
