// Empty fmt.Println()/fmt.Print() must emit a blank line / nothing, not crash.
package main

import "fmt"

func main() {
	fmt.Print("a", "b")
	fmt.Println()
	for i := 0; i < 3; i++ {
		fmt.Print(i, " ")
	}
	fmt.Println()
	fmt.Print()
	fmt.Println("done")
}
