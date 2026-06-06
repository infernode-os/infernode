package main

// Local aggregates whose address is taken but does not escape are stack
// allocated. SSA guarantees their backing storage is zero-initialized, but
// the Dis VM only clears GC-pointer frame slots, leaving scalar slots with
// stale values from whatever previously used that stack region. dirtyArr
// fills the region with non-zero values; cleanArr then declares a fresh
// array, writes only some elements, and reads all of them — the unwritten
// elements must read back as 0.

func dirtyArr() int {
	var a [4]int
	a[0], a[1], a[2], a[3] = 111, 222, 333, 444
	return a[0] + a[1] + a[2] + a[3]
}

func cleanArr() int {
	var a [4]int
	a[0] = 1
	a[2] = 3
	return a[0] + a[1] + a[2] + a[3] // 1 + 0 + 3 + 0
}

func sumPartial() int {
	var b [6]int
	b[5] = 10
	s := 0
	for i := 0; i < 6; i++ {
		s += b[i]
	}
	return s // only b[5] set → 10
}

func main() {
	dirtyArr()
	println(cleanArr()) // 4
	dirtyArr()
	println(sumPartial()) // 10
}
