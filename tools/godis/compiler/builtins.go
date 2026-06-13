// Package compiler implements a Go-to-Dis compiler.
package compiler

import "github.com/NERVsystems/infernode/tools/godis/dis"

// SysFunc describes a built-in Sys module function.
type SysFunc struct {
	Name      string // Function name (e.g., "print")
	Sig       uint32 // MD5-based type signature (from sysmod.h)
	FrameSize int32  // Frame size in bytes (from sysmod.h)
	NMap      int    // Number of pointer map bytes
	Map       []byte // Pointer bitmap for frame
}

// sysFuncs contains the Sys module function signatures from libinterp/sysmod.h.
// These must match exactly for module linking to work at runtime.
var sysFuncs = map[string]SysFunc{
	"print": {
		Name: "print", Sig: 0xac849033,
		FrameSize: 0, NMap: 0, Map: nil, // varargs: size=0
	},
	"fprint": {
		Name: "fprint", Sig: 0xf46486c8,
		FrameSize: 0, NMap: 0, Map: nil, // varargs: size=0
	},
	"sprint": {
		Name: "sprint", Sig: 0x4c0624b6,
		FrameSize: 0, NMap: 0, Map: nil, // varargs: size=0
	},
	"fildes": {
		Name: "fildes", Sig: 0x1478f993,
		FrameSize: 72, NMap: 0, Map: nil,
	},
	"write": {
		Name: "write", Sig: 0x7cfef557,
		FrameSize: 88, NMap: 2, Map: []byte{0x00, 0xc0},
	},
	"read": {
		Name: "read", Sig: 0x7cfef557,
		FrameSize: 88, NMap: 2, Map: []byte{0x00, 0xc0},
	},
	"open": {
		Name: "open", Sig: 0x8f477f99,
		FrameSize: 80, NMap: 2, Map: []byte{0x00, 0x80},
	},
	"create": {
		Name: "create", Sig: 0x54db77d9,
		FrameSize: 88, NMap: 2, Map: []byte{0x00, 0x80},
	},
	"seek": {
		Name: "seek", Sig: 0xaeccaddb,
		FrameSize: 88, NMap: 2, Map: []byte{0x00, 0x80},
	},
	"sleep": {
		Name: "sleep", Sig: 0xe67bf126,
		FrameSize: 72, NMap: 0, Map: nil,
	},
	"millisec": {
		Name: "millisec", Sig: 0x616977e8,
		FrameSize: 64, NMap: 0, Map: nil,
	},
	"bind": {
		Name: "bind", Sig: 0x66326d91,
		FrameSize: 88, NMap: 2, Map: []byte{0x00, 0xc0},
	},
	"chdir": {
		Name: "chdir", Sig: 0xc6935858,
		FrameSize: 72, NMap: 2, Map: []byte{0x00, 0x80},
	},
	"remove": {
		Name: "remove", Sig: 0xc6935858,
		FrameSize: 72, NMap: 2, Map: []byte{0x00, 0x80},
	},
	"pipe": {
		Name: "pipe", Sig: 0x1f2c52ea,
		FrameSize: 72, NMap: 2, Map: []byte{0x00, 0x80},
	},
	"dup": {
		Name: "dup", Sig: 0x6584767b,
		FrameSize: 80, NMap: 0, Map: nil,
	},
	"pctl": {
		Name: "pctl", Sig: 0x05df27fb,
		FrameSize: 80, NMap: 2, Map: []byte{0x00, 0x40},
	},
	"tokenize": {
		Name: "tokenize", Sig: 0x57338f20,
		FrameSize: 80, NMap: 2, Map: []byte{0x00, 0xc0},
	},
}

// LookupSysFunc returns the SysFunc for a given function name, or nil if not found.
func LookupSysFunc(name string) *SysFunc {
	if f, ok := sysFuncs[name]; ok {
		return &f
	}
	return nil
}

// SysLDTImports returns the LDT imports for all Sys functions used by the program.
func SysLDTImports(names []string) []dis.Import {
	var imports []dis.Import
	for _, name := range names {
		f := LookupSysFunc(name)
		if f != nil {
			imports = append(imports, dis.Import{
				Sig:  f.Sig,
				Name: f.Name,
			})
		}
	}
	return imports
}

// mathFuncs contains the Math builtin module signatures from
// libinterp/mathmod.h. Unary real→real functions share one signature,
// binary (real, real)→real functions another. These must match exactly
// for module linking to work at runtime.
var mathFuncs = map[string]SysFunc{
	"acos":  {Name: "acos", Sig: 0xa1d1fe48, FrameSize: 72},
	"asin":  {Name: "asin", Sig: 0xa1d1fe48, FrameSize: 72},
	"atan":  {Name: "atan", Sig: 0xa1d1fe48, FrameSize: 72},
	"atan2": {Name: "atan2", Sig: 0xf293f6cf, FrameSize: 80},
	"ceil":  {Name: "ceil", Sig: 0xa1d1fe48, FrameSize: 72},
	"cos":   {Name: "cos", Sig: 0xa1d1fe48, FrameSize: 72},
	"exp":   {Name: "exp", Sig: 0xa1d1fe48, FrameSize: 72},
	"fabs":  {Name: "fabs", Sig: 0xa1d1fe48, FrameSize: 72},
	"floor": {Name: "floor", Sig: 0xa1d1fe48, FrameSize: 72},
	"fmod":  {Name: "fmod", Sig: 0xf293f6cf, FrameSize: 80},
	"log":   {Name: "log", Sig: 0xa1d1fe48, FrameSize: 72},
	"log10": {Name: "log10", Sig: 0xa1d1fe48, FrameSize: 72},
	"pow":   {Name: "pow", Sig: 0xf293f6cf, FrameSize: 80},
	"sin":   {Name: "sin", Sig: 0xa1d1fe48, FrameSize: 72},
	"sqrt":  {Name: "sqrt", Sig: 0xa1d1fe48, FrameSize: 72},
	"tan":   {Name: "tan", Sig: 0xa1d1fe48, FrameSize: 72},
}

// LookupMathFunc returns the Math module function descriptor, or nil.
func LookupMathFunc(name string) *SysFunc {
	if f, ok := mathFuncs[name]; ok {
		return &f
	}
	return nil
}
