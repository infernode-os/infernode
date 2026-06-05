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
}
