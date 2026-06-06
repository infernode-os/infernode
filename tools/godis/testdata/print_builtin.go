package main

func main() {
	print(1, 2, 3)
	print("\n")
	print("a", "b", "c")
	print("\n")
	print(1, "x", 2, true)
	print("\n")
	println(1, 2, 3)
	println("x", "y")
	// fallthrough was masked by the old print-adds-newline bug
	for n := 0; n < 4; n++ {
		switch n {
		case 1:
			print("one ")
			fallthrough
		case 2:
			print("two ")
		}
	}
	println()
}
