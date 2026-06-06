package main

// Plain int / uint are 64-bit (Go word width). Values above the old 32-bit
// range must survive arithmetic, call boundaries, indexing and conversion.

func add(a, b int) int { return a + b }

func main() {
	var x int = 3000000000
	println(x + x)        // 6000000000
	println(x * 3)        // 9000000000
	println(x / 7)        // 428571428
	println(x % 7)        // 3000000000 % 7 = 4

	// Constant beyond 32 bits and a function-call boundary.
	println(1 << 40)      // 1099511627776
	println(add(4000000000, 5000000000)) // 9000000000

	// Negative wide int.
	var neg int = -5000000000
	println(neg)          // -5000000000
	println(neg / 1000)   // -5000000

	// Narrowing conversions truncate as in Go.
	var big int = 300
	println(int8(big))    // 44
	var v int = 5000000000
	println(int32(v))     // 705032704

	// A wide value stored and read back through a slice.
	a := make([]int, 4)
	a[2] = 9000000000
	i := 1 + 1
	println(a[i])         // 9000000000
	println(len(a) * 2000000000) // 8000000000

	// uint past the int64 range prints unsigned.
	var u uint = 1 << 63
	println(u)            // 9223372036854775808
}
