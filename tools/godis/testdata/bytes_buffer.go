package main

import "bytes"

func main() {
	var buf bytes.Buffer
	buf.WriteString("hello ")
	buf.WriteString("world")
	buf.WriteByte('!')
	println(buf.String())        // hello world!
	println(buf.Len())           // 12
	buf.Reset()
	buf.WriteString("abc")
	println(buf.String(), buf.Len()) // abc 3
}
