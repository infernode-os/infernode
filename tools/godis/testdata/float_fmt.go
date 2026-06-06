package main

import "fmt"

// Exercises %.Nf fixed-point formatting (Go's default prec 6 for bare %f,
// explicit precision, width/zero padding, negatives, and carries).
// All cases here round cleanly and match Go's strconv output. Exact
// half-way values (e.g. 2.5 at prec 0) use round-half-away-from-zero and
// are intentionally excluded — see emitFloatFixed's limitation note.
func main() {
	fmt.Printf("%.2f\n", 3.14159)
	fmt.Printf("%.0f\n", 3.7)
	fmt.Printf("%f\n", 1.5)
	fmt.Printf("%.3f\n", -2.5)
	fmt.Printf("%.2f\n", 0.999)
	fmt.Printf("%.4f\n", 0.00012)
	fmt.Printf("%.2f\n", 123456.789)
	fmt.Printf("%.2f\n", 0.0)
	fmt.Printf("%.6f\n", 1234.5)
	fmt.Printf("%.2f\n", 1000000.5)
	fmt.Printf("[%8.2f]\n", -3.14159)
	fmt.Printf("[%08.2f]\n", 3.1)
}
