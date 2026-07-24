# TAK/UAS live video in the Matrix player — architecture & runbook

How a UAS gimbal feed from the NERV simulation fleet appears, live and
annotated, in InferNode's Matrix video player — and how the same feed
reaches nerv-gcs (the ATAK plugin) on a handset.  Verified end-to-end
2026-07-20 (drone view, motion, detection box on screen; user-confirmed).

## 1. The architecture

The insight that makes this almost free: **manto already re-serves UAS
video in vid9p's own schema over 9P.**  Its SPEC (§9.3) cites
`vid9p.b` by line number; `feeds/<id>/fmt` and `feeds/<id>/frame` are
byte-compatible with `/mnt/video/<id>`.  No transcoding, no protocol
glue: the feed is already a filesystem, so displaying it is a mount
plus a player that understands live (transportless) sources.

```
┌─────────────── Mac (renderer bench, nerv-gcs/docs/BENCH.md) ───────────────┐
│ Gazebo (gz-sim, iris_runway + gimbal)                                      │
│   └ GstCameraPlugin: 720p → x264 zerolatency → RTP/H.264                   │
│        ├──────────────► UDP 5600 (leg to the perception node)              │
│        └ gst-launch: udpsrc 5600 → rtpstreampay → tcpserversink :5601      │
│                          (RFC4571 framing — the HANDSET video channel)     │
│ ArduPilot SITL (gazebo-iris, gimbal parms) — MAVLink tcp 5760/5762         │
└────────────────────────────────────────────────────────────────────────────┘
                 │ RTP/H.264 UDP :5600
                 ▼
┌────────────── hephaestus (Jetson AGX Orin, perception node) ───────────────┐
│ mantod (NERVsystems/manto): NVDEC/CPU decode → YOLO on DLA →               │
│   /mnt/vision 9P on tcp 127.0.0.1:6630                                     │
│     feeds/<id>/fmt    "<w> <h> i420 <fps>"      ← vid9p schema, exactly    │
│     feeds/<id>/frame  ANNOTATED I420, join-live ring of 8, reads PARK      │
│     feeds/<id>/{status,stats,detections,chips/}                            │
│ TAK Server (docker, mTLS :8089, web :8443); takconnector :7089             │
│ ArduPilot SITL (SAR scenario, hilsim.mav-1) — MAVLink tcp :5760/5762/5763  │
└────────────────────────────────────────────────────────────────────────────┘
                 │ ssh -L 16630:127.0.0.1:6630          │ RFC4571 tcp :5601
                 ▼                                      ▼ (via adb or relay)
┌──────── any InferNode ────────┐        ┌────── Android: ATAK + nerv-gcs ───┐
│ mount -A tcp!…!16630 /tmp/vision       │ plugin video source:              │
│ wm/matrix …/tak-uas            │       │  UDP RTP :5600 or RFC4571 :5601   │
│  → video-pane, LIVE mode       │       │ MAVLink tcp → SITL :5762          │
└────────────────────────────────┘       │ TAK mTLS → hephaestus :8089       │
                                         └───────────────────────────────────┘
```

NB the *current* live rig is a HIL mashup: the rendered pixels come from
the Mac bench's iris world, while the `hilsim.mav-1` telemetry that manto
georeferences against comes from the hephaestus SAR vehicle — hence the
feed's honest `degraded: telemetry pose stale/absent` (image-plane
detections only).  The plumbing is identical when both come from one
vehicle.

## 2. Contracts

**vid9p frame schema** (`appl/cmd/vid9p.b`): `fmt` reads
`"<w> <h> i420 <fps>"`; `frame` is tightly-packed planar I420,
`framesize = w*h*3/2` bytes per frame.

**manto live semantics** (manto `docs/SPEC.md` §9.3): `frame` is
unbounded; a ring of the last 8 frames is kept.  A fresh fid's first
read gets the newest frame (join-live); sequential reads get successive
frames; a reader that falls off the ring resumes at the oldest retained
— frames are skipped, never blocked; a fully caught-up read PARKS until
the next frame arrives.  Consequence: **the server paces the client**,
and a slow link degrades to lower fps instead of growing latency.

**video-pane live mode** (`appl/matrix/video-pane.b`): a mount whose
`status` has no `pos=` field (or no status file) is a live sequential
source.  The pane spawns a reader proc that consumes framesize-byte
chunks on a private fid — blocking by design, since manto parks the
read — and hands complete frames to the GUI tick over a two-buffer
ping-pong.  Transport keys are inert; the strip shows
`LIVE <w>x<h> stream`.  vid9p-backed mounts (with `pos=`) behave as
before: server-side transport, seek/pause/DVR.

## 3. Runbook A — the feed in InferNode's Matrix player

One command, from this repo's root, with ssh access to the perception
node:

```sh
./demo-tak.sh              # defaults to host "hephaestus"
./demo-tak.sh <host>       # any node running manto on :6630
```

It opens `ssh -L 16630:127.0.0.1:6630 <host>` (manto binds localhost
only, by design, until fleet keyring auth lands), mounts the vision
tree in a fresh emu, and loads `/lib/matrix/compositions/tak-uas`,
which is just:

```
layout vsplit 100 0
top video-pane /tmp/vision/feeds/gz-uas
```

Edit the feed path for other feeds (`ls /tmp/vision/feeds`).  Manual
equivalent inside any emu:

```sh
mkdir -p /tmp/vision
mount -A tcp!127.0.0.1!16630 /tmp/vision
wm/matrix /lib/matrix/compositions/tak-uas
```

### Sanity checks

```sh
# on the perception node — is manto alive and fed?
cat /tmp/vision/status                  # "status running feeds=…"
cat /tmp/vision/feeds/gz-uas/fmt        # "1280 720 i420 30"
cat /tmp/vision/feeds/gz-uas/stats      # frames_in should be climbing
cat /tmp/vision/feeds/gz-uas/status     # state=… decode=… pose=…
```

### Troubleshooting

- **"no video" in the pane**: the mount failed (check the tunnel:
  `nc -z 127.0.0.1 16630`) or the feed id in the crystallisation
  doesn't exist (`ls /tmp/vision/feeds`).
- **Frozen frame**: producer stopped (check `stats` frames_in) — the
  pane's reader parks until frames resume, then rejoins live
  automatically.
- **Low fps**: expected over ssh/WiFi — 720p raw I420 is ~41 MB/s at
  full rate; the ring semantics skip frames to match the link.  A
  compressed 9P leg is the long-term fix (INFR-267).
- **`degraded: telemetry pose stale`** in feed status: manto lacks
  usable platform pose; detections are image-plane only.  Video is
  unaffected.

## 4. Runbook B — the same feed in nerv-gcs (ATAK, Android)

nerv-gcs's video core takes **raw RTP H.264 on UDP :5600** on the
handset, or **RFC4571 (RTP-over-TCP framing) on :5601** — see
`nerv-gcs/docs/BENCH.md` (the authoritative bench doc; its harness,
certs, and plugin-trust notes apply).

Control legs first (the handset is on the same network as hephaestus):

- **TAK**: ATAK → hephaestus `:8089` (mTLS; bench CA, cert password
  convention per BENCH.md / nerv-tak-deploy runbook).
- **MAVLink** ("connect to the UAS"): plugin MAVLink source →
  `tcp://<hephaestus>:5762` — SITL's SERIAL2, listening on 0.0.0.0.
  The vehicle (`hilsim.mav-1` in the current SAR rig) appears in the
  plugin.

Video, two ways:

- **USB / adb (bench-standard)**: the Mac already runs the RFC4571
  server (`… rtpstreampay ! tcpserversink 127.0.0.1:5601`).  With the
  handset on USB: `adb reverse tcp:5601 tcp:5601`, then point the
  plugin's video source at RFC4571 `localhost:5601`.
- **WiFi (no cable)**: bridge the spare RFC4571 channel back to RTP at
  the phone, without touching the running bench pipeline:

  ```sh
  gst-launch-1.0 tcpclientsrc host=127.0.0.1 port=5601 \
    ! "application/x-rtp-stream,media=video,encoding-name=H264,payload=96" \
    ! rtpstreamdepay ! udpsink host=<PHONE_WIFI_IP> port=5600
  ```

  and set the plugin's video source to UDP :5600.  (This consumes the
  idle 5601 listener; the direct 5600 leg to hephaestus is untouched,
  so manto and the handset stream simultaneously.)

Plugin caveats (from BENCH.md, hard-won): every `adb install -r`
resets ATAK's plugin trust — re-enable via the "Load plugin: NERV GCS"
prompt.  **Never `adb uninstall`** — it wipes plugin data.

## 5. Ports & endpoints

| Where | Port | What |
|---|---|---|
| renderer (Mac bench) | udp 5600 → perception node | RTP/H.264 gimbal camera (GstCameraPlugin, SPS/PPS in-band) |
| renderer (Mac bench) | tcp 5601 | RFC4571 framing of the same stream (handset channel) |
| hephaestus | udp 5600 | mantod ingest (`[[feed]] url = "rtp://127.0.0.1:5600"`) |
| hephaestus | tcp 6630 (localhost) | manto `/mnt/vision` 9P — mount this |
| hephaestus | tcp 6640+n (localhost) | manto → argus sensor fabric, per feed |
| hephaestus | tcp 5760/5762/5763 | ArduPilot SITL MAVLink |
| hephaestus | tcp 8089 / 8443 | TAK Server mTLS streaming / web+API |
| anywhere | tcp 16630 (convention) | ssh -L tunnel to a node's manto 6630 |

## 6. Open items

- Compressed leg over 9P (raw 720p I420 ≈ 41 MB/s at 30 fps) — INFR-267
  territory: Rust-native 9P in vdec/manto with on-demand H.264.
- Port the Matrix video modules to nerva3 so perception nodes can view
  their own feeds (nerva3 today carries phase-1 vid9p only).
- The exact socket path of the renderer→hephaestus 5600 leg is
  configured inside the running bench session (not recovered from
  process tables); recorded here as the one link taken on evidence of
  flow rather than of configuration.
- Fix the HIL mashup: same vehicle for pixels and pose ends the
  `pose stale` degradation and enables georeferenced boxes.

## 7. Reloadable stack (one command per host)

The whole rig re-raises idempotently — each script starts only what's
missing, so they double as health checks. Canonical copies live in
`tools/tak-uas/`; deployed to the hosts as:

| Host | Command | Brings up |
|---|---|---|
| minipc | `bash ~/nerva-sim/stack-up-minipc.sh` | Gazebo+SITL (sim-up.sh), camstream → heph:5610, phone mavproxy (tcpin:15762), adb reverses, video tunnel → heph:5601 |
| hephaestus | `bash ~/bin/stack-up-heph.sh` | mantod (DLA inference, CPU decode, 9P :6630), manto-broadcast (one x264 encode → tee → RFC4571 :5601 + MPEG-TS :5602), takconnector host proxy :7089 |
| Mac | `./demo-tak.sh` | 5602 tunnel + local vdec decode + Matrix player (compressed leg; `demo-tak-raw.sh` = old raw-9P fallback) |

Bring-up order after a cold start: minipc → hephaestus → Mac/phone.
If gazebo wedges (frozen `/clock`, control service timeouts): reboot the
minipc and re-run — see UAS-163.

Hard-won streaming rules baked into `manto-broadcast.sh`:
- `mpegtsmux alignment=7 pat-interval=900 pmt-interval=900 si-interval=900`
  — without the alignment, a client joining mid-stream lands mid-TS-packet
  and never decodes ("non-existing PPS", INFR-396).
- tee branches need `queue leaky=downstream` (a client-less sink otherwise
  backpressures the whole tee) with DEEP buffers (300) — shallow ones drop
  frames mid-GOP on transient stalls and artefact the phone.
- x264 `intra-refresh=true` so residual corruption heals progressively.
- NVENC (`nvv4l2h264enc`) encodes fine but its stream currently defeats
  mid-stream joiners; parked until the SPS/PPS handling is solved (NVDEC
  itself is dead pending NOPS-139).
- vid9p live retention MUST be bounded at 720p: `demo-tak.sh` passes
  `-w 12` (12 s DVR ≈ 166 MB). The 60 s default fills the 1 GB Dis heap
  in ~2 min — vid9p stops reading, vdec dies, the pane goes "no video".
- Restarting manto-broadcast drops the emu's vdec connection and it does
  NOT auto-reconnect: `tools/tak-uas/demo-tak-watch.sh` heals this (~25 s).
- Rebuilding vdec on macOS needs homebrew ffmpeg 6:
  `PKG_CONFIG_PATH=/opt/homebrew/opt/ffmpeg@6/lib/pkgconfig cargo build --release`.
  A STALE vdec binary fails silently in `--y4m -` mode (writes a file
  literally named `-` instead of stdout) — vid9p never gets the header,
  `mount {vid9p ...}` hangs, matrix never launches, the pane is blank.
  rig-test T4.0 guards this class.
- x264 `intra-refresh=true` is BANNED on the broadcast: it removes
  periodic IDRs, so mid-stream joiners may never sync (rejoin lottery).
  Short GOPs (key-int-max=15) give both fast artefact recovery and
  reliable joins.

## 8. Fleet operation (3 vehicles, selective switching)

The roster carries all three sysids natively — the nerv-gcs vehicle
dropdown lists `mav-1/2/3` and control switches per vehicle in the
plugin UI. VIDEO follows the *selected* vehicle via
`select-vehicle.sh <1|2|3>` (minipc): it aims the single camstream at
the chosen bird's camera topic, feeding manto's one ingest — phone
(:5601) and emu (:5602) then both show that vehicle, boxes included.
One camera streams at a time until manto can serve multiple feeds
concurrently (NERVsystems/manto#4); when that lands, restore the saved
3-feed config (`mantod-live.toml.fleet-3feed`), start the b/c
broadcasts, and `demo-tak-fleet.sh` gives the 3-pane spectate wall.

Fleet bring-up (canonical copies in tools/tak-uas/): minipc
`sim-up-fleet.sh` (gazebo ao_fleet ×3 iris, 3× SITL, MAV_SYSID 1/2/3 —
NB ArduPilot 4.8 renamed SYSID_THISMAV; the old name is silently
ignored in defaults files — one aggregating mavproxy), then
`camstream-fleet.sh` / `select-vehicle.sh`. mav_cot_bridge needs
`--sysid 1` on a multi-vehicle fan-out or its track mixes all birds.

## 9. References

- `demo-tak.sh`, `lib/matrix/compositions/tak-uas` (this repo)
- `appl/matrix/video-pane.b` — live-sequential mode
- `docs/H264-9P-BRIDGE.md` — the vid9p bridge design of record
- NERVsystems/manto `docs/SPEC.md` §9 — /mnt/vision, normative
- NERVsystems/nerv-gcs `docs/BENCH.md` — bench stack, handset wiring
- NERVsystems `SIM-ENV-HANDOFF.md` — hephaestus sim environment
