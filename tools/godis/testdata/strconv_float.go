package main

import (
	"fmt"
	"strconv"
)

// strconv.FormatFloat with the 'f' format and constant precision now emits
// real fixed-point text (same path as %.Nf). Cases chosen to round cleanly,
// matching Go's strconv byte-for-byte.
func main() {
	fmt.Println(strconv.FormatFloat(3.14159, 'f', 2, 64))
	fmt.Println(strconv.FormatFloat(1.5, 'f', 4, 64))
	fmt.Println(strconv.FormatFloat(123.456, 'f', 1, 64))
	fmt.Println(strconv.FormatFloat(0.125, 'f', 3, 64))
	fmt.Println(strconv.FormatFloat(-9.99, 'f', 2, 64))
}
