package main

import (
	"fmt"
	"math"
)

// math.Pow with integer exponents (EXPF is integer-power only) and math.Mod
// (which previously used the broken CVTFR/CVTRF truncation).
func main() {
	fmt.Println(int(math.Pow(2, 10)), int(math.Pow(3, 3)), int(math.Pow(5, 2)), int(math.Pow(2, 0)), int(math.Pow(10, 3)))
	fmt.Println(int(math.Mod(10, 3)), int(math.Mod(17, 5)), int(math.Mod(-7, 3)))
}
