package main

import (
	"fmt"
	"math"
)

// Integer constants larger than a 30-bit Dis immediate (±~536M) must be
// materialized from the module data section, not encoded inline.
func main() {
	fmt.Println(2147483647)
	fmt.Println(1000000000)
	fmt.Println(1073741824) // 1 << 30
	fmt.Println(-2000000000)
	fmt.Println(math.MaxInt32, math.MaxInt16, math.MinInt32)
}
