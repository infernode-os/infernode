package main

// Go's int(float) truncates toward zero. The Dis CVTFW/CVTFL opcodes round
// half-away-from-zero, so the compiler truncates explicitly (emitTruncToLong).

func main() {
	xs := []float64{3.7, 3.2, 3.9, -3.7, -3.2, 2.999, 5.0, 0.9, -0.9}
	for _, x := range xs {
		println(int(x))
	}
}
