package main

func sum(a, b int64) int64 { return a + b }

func main() {
	var x int64 = 1 << 40
	println(x)

	var y int64 = 5000000000
	println(y + 1)
	println(y - 1)
	println(y * 2)
	println(y / 3)
	println(y % 7)

	// Value crossing a function-call boundary (8-byte arg + return copy).
	println(sum(3000000000, 2000000000))

	// 64-bit comparison.
	if y > 4000000000 {
		println("big")
	} else {
		println("small")
	}

	// Negative 64-bit constant (low word has bit 31 set).
	var neg int64 = -3000000000
	println(neg)

	// Bitwise ops above bit 31.
	var m int64 = 0xF00000000
	println(m & 0x300000000)
	println(m >> 4)

	// A medium constant (> 16 bits) as a multiplier exercises the middle
	// operand, which is only 16 bits wide and must be materialized.
	var n int64 = 3000000
	println(n * 4000)

	// Conversions to/from int64.
	var i int = 100
	println(int64(i) * 50000000)
	var f float64 = 3.0e9
	println(int64(f))
	var u uint = 4000000000
	println(uint64(u))
}
