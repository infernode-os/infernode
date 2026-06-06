package main

import "sort"

type person struct {
	name string
	age  int
}

func main() {
	s := []int{3, 1, 4, 1, 5, 9, 2, 6}
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	for _, v := range s {
		println(v)
	}
	sort.Slice(s, func(i, j int) bool { return s[i] > s[j] })
	println(s[0], s[7])

	people := []person{{"bob", 30}, {"amy", 25}, {"cal", 28}}
	sort.Slice(people, func(i, j int) bool { return people[i].age < people[j].age })
	for _, p := range people {
		println(p.name, p.age)
	}
}
