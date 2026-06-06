package main

import (
	"fmt"
	"math"
)

// math.Floor/Ceil/Trunc/Round previously used a real32 precision round-trip
// (CVTFR/CVTRF) that does not truncate, so all four were wrong. They now build
// on emitTruncToLong (truncate toward zero) / CVTFL (round half-away).
func main() {
	vals := []float64{3.7, 3.2, -3.7, -3.2, 5.0, 2.5, -2.5, 0.4}
	for _, v := range vals {
		fmt.Println(int(math.Floor(v)), int(math.Ceil(v)), int(math.Trunc(v)), int(math.Round(v)))
	}
}
