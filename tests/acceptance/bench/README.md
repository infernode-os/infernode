# Bench tools

What was used on the Pi 3B+ bench beside the batteries, kept because every
one of them found something. They are **specific to that bench**: the board
is at 192.168.1.104, the tester at 192.168.1.151, kernels are built under
`/mnt/orin-ssd/pdfinn/bmbuild`, and the network console's token is read from
`~/pitools/netcons.token`. No credential is in any of them. Change the
addresses at the top of a script to use it elsewhere.

All of them talk to the board through its network console (tcp 17010), one
session per call, a few seconds each: the console is a non-interactive shell
in a namespace of its own, so a loop started with `&` dies with its session
and a redirection that cannot be opened ends the shell.

## Kernels

| tool | what it does |
|---|---|
| `stage.py kernel.img [extra.dis ...]` | A/B stage: copy the kernel to the card as `tryboot.img`, verify its size, ask for one candidate boot, wait, check `/dev/bootimage` is the candidate, promote. About six minutes, card-write bound. |
| `finish-tryboot.py <size>` | promote a candidate that is already running (when `stage.py` was interrupted after "candidate boot requested") |
| `serialload-proof.sh` | the serial loader's end-to-end proof (#639) |

## Soak and memory

| tool | what it does |
|---|---|
| `soak.py` | 48-hour soak: four stress loops each held on its own console session, a 64 MB inbound TCP push every ten minutes to a sink the pusher arms itself (the Ethernet battery's `kill Listen` takes it otherwise), `/dev/memory` every five minutes, the Ethernet and Bluetooth batteries once a day. Log: `~/pitools/soak/soak.log`. |
| `tagsnap.sh` | hourly snapshot of `/dev/memtags`, live main-pool blocks by allocating PC. A leak is a call site whose count only grows; session memory and fragmentation are not. |
| `symtags.py kernel.elf < snapshot` | names those PCs from the build's ELF |
| `memfast.py` | `/dev/memory` every few seconds, for a leak measured in minutes |

## The Ethernet receive path (#633)

| tool | what it does |
|---|---|
| `chipdrops.py` | brackets a 16 MB inbound transfer with the LAN78xx's own statistics (`lan78stats`): `rx dropped frames` is loss no counter above the chip sees |
| `udpblast.py` | UDP in bursts of a chosen size at a fixed average rate: which burst length the chip's 12 KB FIFO survives |
| `dlysweep.py`, `tcpsweep.py reg=val ...` | sweep a chip register on a live link (`lan78stats reg`) against burst loss and against TCP throughput, with the sender's retransmission counters |
| `rxclassify.py`, `rxss.py`, `rxcounters.py`, `rxmeasure.py` | the sender's view of one transfer (`nstat`, `ss -ti`), the board's IP counters, the driver's read and gap histograms |

## Bluetooth

| tool | what it does |
|---|---|
| `btevents.py`, `btstorm.py` | the board's event log across a reconnect storm, against what BlueZ reports (#632: the refusals were the tester's) |

## The hosted emulator

| tool | what it does |
|---|---|
| `runsh.sh test.sh [seconds] [lines]` | run an Inferno-side sh test and print its verdict. A failing sh test exits silently and the emulator never exits, so it runs `sh -c "sh test; echo VERDICT-STATUS: $status"` and waits for that line. |
| `gdbloop.sh [n]` | run a test n times under gdb and keep any run that faults, with a backtrace |
| `slowsess.py 'cmd' ...` | one patient console session, for a board that is slow to greet |
