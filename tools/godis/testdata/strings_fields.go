package main

import "strings"

func main() {
	f := strings.Fields("  a  b   c ")
	println(len(f))              // 3
	println(f[0], f[1], f[2])    // a b c
	println(strings.Join(f, "-")) // a-b-c
	g := strings.Fields("single")
	println(len(g), g[0])        // 1 single
}
