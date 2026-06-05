package main

// make([]T, len, cap) with len != cap, then append.
func main() {
	a := make([]int, 3)
	println(len(a))            // 3
	b := make([]int, 3, 5)
	println(len(b), b[0])      // 3 0

	s := make([]int, 0, 4)
	println(len(s))            // 0
	for i := 0; i < 6; i++ {
		s = append(s, i*i)
	}
	println(len(s), s[0], s[5]) // 6 0 25
	println(cap(s) >= 6)        // true

	c := make([]int, 2, 8)
	c = append(c, 9)
	println(len(c), c[0], c[2]) // 3 0 9
}
