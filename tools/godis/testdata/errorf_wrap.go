package main

import (
	"errors"
	"fmt"
)

func main() {
	base := errors.New("base failure")
	w := fmt.Errorf("operation failed: %w", base)
	println(w.Error())                       // operation failed: base failure
	w2 := fmt.Errorf("[%w] and more", base)
	println(w2.Error())                      // [base failure] and more
	println("done")                          // no heap corruption at teardown
}
