// Generic LIFO stack exercised with ints and strings.
package main

import "fmt"

type Stack[T any] struct{ items []T }

func (s *Stack[T]) Push(v T) { s.items = append(s.items, v) }
func (s *Stack[T]) Pop() (T, bool) {
	var zero T
	if len(s.items) == 0 {
		return zero, false
	}
	v := s.items[len(s.items)-1]
	s.items = s.items[:len(s.items)-1]
	return v, true
}

func main() {
	var s Stack[int]
	for i := 1; i <= 3; i++ {
		s.Push(i * 10)
	}
	for {
		v, ok := s.Pop()
		if !ok {
			break
		}
		fmt.Println(v)
	}

	var t Stack[string]
	t.Push("a")
	t.Push("b")
	v, _ := t.Pop()
	fmt.Println(v)
}
