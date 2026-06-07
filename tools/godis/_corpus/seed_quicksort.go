// Quicksort over a slice of ints, printing the sorted result.
package main

import "fmt"

func quicksort(a []int) {
	if len(a) < 2 {
		return
	}
	pivot := a[len(a)/2]
	var less, equal, greater []int
	for _, v := range a {
		switch {
		case v < pivot:
			less = append(less, v)
		case v == pivot:
			equal = append(equal, v)
		default:
			greater = append(greater, v)
		}
	}
	quicksort(less)
	quicksort(greater)
	copy(a, append(append(less, equal...), greater...))
}

func main() {
	a := []int{5, 2, 9, 1, 7, 3, 8, 4, 6, 0}
	quicksort(a)
	for _, v := range a {
		fmt.Print(v, " ")
	}
	fmt.Println()
}
