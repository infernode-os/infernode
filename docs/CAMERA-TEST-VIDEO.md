# The camera test video

`tools/camera-test-pattern.py OUT.mp4` makes a video to play, looped, on a
screen in front of a camera: for soaking camsrv(4) and wm/camera(1), and
for checking exposure, white balance and focus against answers known in
advance. Every frame carries a code that says which segment it is and which
frame of that segment, so a captured frame can be placed in the sequence
without timing anything.

This page is everything in the video, so that it can be used without
reading the generator. If the generator changes, this page changes with it.

## The file

| | |
|---|---|
| size | 1280x720, 30 fps |
| length | 9090 frames, 303.0 s, then the player loops it |
| codec | H.264 (libx264, CRF 18, yuv420p, faststart) |
| needs | Python 3 with numpy, ffmpeg with libx264 (on the host; nothing ships) |

```sh
python3 tools/camera-test-pattern.py loop.mp4
```

A player looping it may add a pause at the wrap: on the bench on 2026-11-15
one loop took about 317 s, not 303. **Read the code; do not time the loop.**

## The segments

Times are from the start of the file. Frame numbers are the file's (0-based)
and, in the last column, the segment's own, which is what the code carries.

| seg | starts | length | file frames | what is shown | what it checks |
|---|---|---|---|---|---|
| 1 | 0 s | 30 s | 0-899 | black and white, 5 s each, three times (black first) | auto-exposure settling on a large step |
| 2 | 30 s | 48 s | 900-2339 | black, grey 128, white, grey 64, 1.5 s each, eight times | exposure on smaller and mixed steps |
| 3 | 78 s | 20 s | 2340-2939 | black and white, 0.5 s each (1 Hz), twenty times | exposure under fast change; the sensor's I2C traffic it causes |
| 4 | 98 s | 30 s | 2940-3839 | a fade: white to black at 15 s, back to white at 30 s (level 255·\|2i/900 − 1\|) | exposure follows smoothly, without hunting |
| 5 | 128 s | 20 s | 3840-4439 | neutral grey 128 | white balance: the picture should be grey |
| 6 | 148 s | 20 s | 4440-5039 | eight colour bars | white balance and colour |
| 7 | 168 s | 30 s | 5040-5939 | solid red, green, blue, 5 s each, twice | grey-world white balance's worst case: expect it washed out |
| 8 | 198 s | 45 s | 5940-7289 | a Siemens star and six sets of line pairs | focus and resolution; autofocus |
| 9 | 243 s | 30 s | 7290-8189 | a white bar sweeping across grey | torn or mixed frames; autofocus must refuse it |
| 10 | 273 s | 30 s | 8190-9089 | a yellow block moving across grey | torn or mixed frames |

### The patterns, exactly

- **Grey levels** are full range: black 0, white 255, greys 64 and 128.
- **Colour bars** (seg 6), each 160 px wide, left to right: white (235,235,235),
  yellow (235,235,16), cyan (16,235,235), green (16,235,16), magenta
  (235,16,235), red (235,16,16), blue (16,16,235), black (16,16,16).
- **Primaries** (seg 7) are pure: (255,0,0), (0,255,0), (0,0,255).
- **Siemens star** (seg 8), on white: centre (426,360), a third of the way
  across, radius 300; 72 black spokes and 72 white (black where
  sin 72θ > 0), each 2.5° wide.
- **Line pairs** (seg 8), to the right of the star: six bars, x 720-1199,
  each 80 px tall, tops at y 70, 170, 270, 370, 470, 570. From the top their
  periods are 1, 2, 3, 4, 6 and 8 px black then as many white, starting
  black at x 720. The finest set a camera resolves is its resolution there.
- **Sweeping bar** (seg 9): background 32; a white bar 40 px wide at
  x = 24i mod 1280 in segment frame i: 720 px a second, across in 1.78 s.
- **Moving block** (seg 10): background 64; a yellow (255,255,0) square of
  120 px at x = 64i mod 1280, y = 36i mod 600.

## The frame code

Every frame has the same 16-bit code drawn twice, as a row of blocks near
the top and again near the bottom, over the picture:

```
code = segment << 12 | frame-in-segment        (frame-in-segment from 0)
```

The segment is 1 to 10, and a segment's frame is at most 1349 (seg 8), so it
never wraps 12 bits. The file frame is the segment's start (table above)
plus the frame in segment.

**Where the blocks are**, in the video's pixels:

| | |
|---|---|
| rows | y 40-63 (top) and y 656-679 (bottom), 24 px tall |
| blocks | 16 in a row, block b at x = 80 + 70b, 66 px wide (4 px of picture between) |
| bit order | block 0, the leftmost, is bit 15 (the segment's high bit); block 15 is bit 0 |
| value | white (255) is 1, black (0) is 0 |

So block centres are at x = 113 + 70b, y = 52 and 668. Because 1 is 255 and
0 is 0 whatever is behind them, a block reads as 1 if it is brighter than
mid-grey, on any segment.

**Reading it from a camera's picture**: find the row (16 blocks evenly
spaced, the same height), sample the middle of each, threshold at
mid-grey. The two rows must agree; where one is cropped (a camera seldom
sees the whole screen), use the other. Check the picture's orientation
before reading the bits: the star is left of centre in the video, so a
picture with the star right of centre is mirrored, and its bit 15 is the
rightmost block. On the bench on 2026-11-15 the Pi 5's camera at
camsrv's default `flip 3` showed it mirrored.

Worked example: segment 8, frame 100 is 8<<12 | 100 = 0x8064 =
`1000 0000 0110 0100`: blocks 0, 9, 10 and 13 white, the rest black. It is
file frame 5940 + 100 = 6040, 201.3 s in.

## Using it

Each segment has an answer. For a check that needs a segment (autofocus on
the star, white balance on grey), wait until frames read that segment, then
act; leave margin at the end of short segments.

- **Exposure** (seg 1-4): after each step the picture's mean should settle
  without overshooting; seg 4 should be followed, not chased.
- **White balance** (seg 5): U and V near 128. Seg 7 will not be grey;
  camsrv(4)'s BUGS say why.
- **Focus** (seg 8): sharpness, for instance the mean squared gradient of
  Y, peaks at the right lens position; the finer line pairs separate.
  A sweep of `focus N` over the segment gives the true best for comparison
  with `focus auto`.
- **Autofocus refusing motion** (seg 9, 10): `focus auto` here should fail
  with `the picture is moving` and leave the lens where it was.
- **Torn frames** (seg 9, 10): the bar and the block must be whole in every
  frame; a frame with two positions in it is two frames mixed.

### A note on the NoIR camera

A screen gives off almost no infrared, so the video needs no change for a
camera without an IR filter. Anything else in view does (daylight, lamps):
fill the frame with the screen, or grey-world white balance is pulled by
it. Expect red to read strong on segments 5-7.

## See also

camsrv(4), wm-camera(1), videnc(1), [SOAK.md](SOAK.md).
