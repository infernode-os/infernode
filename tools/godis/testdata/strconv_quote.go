package main

import "strconv"

func main() {
	println(strconv.Quote("hi\there"))
	println(strconv.Quote("line1\nline2"))
	println(strconv.Quote(`a"b\c`))
	println(strconv.Quote("plain text"))
	println(strconv.Quote("tab\tand\rreturn"))
}
