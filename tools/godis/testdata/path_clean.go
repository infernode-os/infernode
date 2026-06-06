package main

import "path"

func main() {
	cases := []string{
		"/a/b/../c", "a//b/./c", "", "/..", "a/b/../../c",
		"/a/./b/", "..", "../a", "/../a", "/a/b/c/../../d",
		"x/.", "./x", "/", "//", "a/b/c",
	}
	for _, s := range cases {
		println(path.Clean(s))
	}
}
