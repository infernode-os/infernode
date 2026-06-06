// 3x3 integer matrix multiply.
package main

import "fmt"

func main() {
	a := [3][3]int{{1, 2, 3}, {4, 5, 6}, {7, 8, 9}}
	b := [3][3]int{{9, 8, 7}, {6, 5, 4}, {3, 2, 1}}
	var c [3][3]int
	for i := 0; i < 3; i++ {
		for j := 0; j < 3; j++ {
			for k := 0; k < 3; k++ {
				c[i][j] += a[i][k] * b[k][j]
			}
		}
	}
	for i := 0; i < 3; i++ {
		fmt.Println(c[i][0], c[i][1], c[i][2])
	}
}
