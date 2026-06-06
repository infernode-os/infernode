// Word frequency over a fixed text, emitted in sorted key order.
package main

import (
	"fmt"
	"sort"
	"strings"
)

func main() {
	text := "the quick brown fox the lazy dog the fox"
	freq := map[string]int{}
	for _, w := range strings.Fields(text) {
		freq[w]++
	}
	keys := make([]string, 0, len(freq))
	for k := range freq {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Printf("%s=%d\n", k, freq[k])
	}
}
