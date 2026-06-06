package main

import "strings"

func main() {
	var b strings.Builder
	for i := 0; i < 3; i++ {
		b.WriteString("ab")
	}
	b.WriteByte('!')
	println(b.String())   // ababab!
	println(b.Len())      // 7
	b.Reset()
	b.WriteString("xy")
	b.WriteString("z")
	println(b.String())   // xyz
	println(b.Len())      // 3
}
