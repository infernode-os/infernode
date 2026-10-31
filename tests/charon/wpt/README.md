# Charon render conformance fixtures

Small pages in the style of web-platform-tests, each exercising one
feature. Every page is built so that a **correct rendering shows solid
green and no pure red**; red is what shows through when the feature is
missing or wrong. That makes scoring a pixel count, with no reference
images:

```sh
tools/charon-wpt.sh /tmp/wpt               # all fixtures, PNGs left in /tmp/wpt
tools/charon-wpt.sh /tmp/wpt tests/charon/wpt/flex-row.html
```

A fixture passes when its 400x300 render has no red pixels and at least
9000 green ones (a 100x100 square, give or take anti-aliased corners).

Adding a fixture: one feature per file, name it `<area>-<feature>.html`,
keep the green area at least 100x100, and put the red *behind* the thing
under test so that any failure mode (not laid out, laid out in the wrong
place, wrong size) leaves red visible or green missing.

Rendering uses `tools/charon-shot.sh`, which needs the emulator and
`dis/tests/charonshot.dis` (`cd tests; mk install`).
