# The Inferno Shell

InferNode carries two shell dialects that are not interchangeable:
host-side scripts (`tests/host/`, `tools/`, `build-*.sh`) are POSIX
`sh`, and everything that runs *inside* Inferno (`tests/inferno/`,
`lib/sh/`, boot scripts, anything with a `#!/dis/sh.dis` shebang) is
Inferno `sh` — an rc-style shell descended from Plan 9's rc, not a
POSIX shell. This page is the reference for the second dialect.
POSIX habits here are the most common review comment we make.

The full paper is in-tree at `doc/sh.ms`; `man/1/sh` is the
reference manual.


## POSIX → Inferno translation

| POSIX habit | Inferno sh |
|---|---|
| `a && b` | `a ; b` (no `&&`, no `\|\|`) |
| `for i in x y; do ...; done` | `for i in x y { ... }` |
| `if [ -d /x ]; then` | `if {ftest -d /x} { ... }` |
| `. script.sh` | `run script.sh` |
| `VAR=v cmd` | `VAR=v; cmd` |
| exit status tests | `raise 'fail:reason'` / `raise 'skip:reason'` |
| `"$var/path"` (empty var → `/path`) | `$var^/path` **raises** `null list in concatenation` when `$var` is empty — guard with `if {! ~ $#var 0}` before any `^` on command-substitution output |
| `cmd > $f` failing quietly in an `if` | a failed redirection **raises past `if {...}`**, aborting the script — to assert "writing $f fails", let the command open it: `cp /dev/null $f` |

The last two rows are semantic, not stylistic — rc-legal scripts
that raise at runtime, and both have shipped as real bugs: an
unguarded null-list concatenation in a boot probe aborts the entire
boot for every user, and the redirection rule is why the tutorial's
contract test asserts write-denial with `cp` (see
[TUTORIAL-9P-SERVICE.md](TUTORIAL-9P-SERVICE.md), step 5). The
advisory style gate cannot catch these — it checks style, not
semantics; semantics are this page's job.


## Script conventions

- Scripts begin `#!/dis/sh.dis` and usually `load std`.
- Quoting is single-quote based, with `''` to embed a quote.
  Variables are *lists*; `$"var` flattens one to a single string,
  `$#var` is its length, `` `{cmd} `` captures command output as a
  list.
- A backgrounded 9P server (`svc &`) keeps the emulator alive until
  killed — remember that in test scripts (the poll-for-sentinel
  pattern in the `limbo-test` skill exists because of it).
- Scripts under `tests/inferno/` must be committed executable (mode
  100755) — `sh->system()` execs the path, and a 644 script fails as
  "file does not exist". CI enforces this (`tools/verify-sh-exec.sh`).
- `raise 'skip:reason'` marks a test SKIP to the runner;
  `raise 'fail:reason'` marks it FAIL.
- The shell can drive Tk directly (`load tk`, `man/1/sh-tk`) —
  available for harness work, currently unused by any test.


## Further reading

- `doc/sh.ms` — the original paper, in-tree.
- `man/1/sh` — the reference; `man/1/sh-tk` for the Tk builtins.
- [LIMBO-FOR-GO-PROGRAMMERS.md](LIMBO-FOR-GO-PROGRAMMERS.md) — the
  language this shell composes with.
- The `limbo-test` skill — where each kind of script lives and how
  the runners treat them.
