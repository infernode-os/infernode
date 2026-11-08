# tests/soak

One soak runner for every Raspberry Pi on the bench. The design is [docs/SOAK.md](../../docs/SOAK.md).

    tests/soak/soak.py --board pi3 --hours 2 --batteries --card \
        --elf $BUILD/bcm2837-kernel.elf

- **Finding the board.** `--board` is a name in `~/pitools/boards`.
- **Driving it.** The runner uses the network console, or serial when there is no console or with `--serial-only`. It reads the serial capture whenever `sercap.py` is capturing that board.
- **Choosing loads.**
  - Every load in `LOADS` runs if the resources it needs are present.
  - A load whose resource is missing is reported as `SKIP` with the reason.
  - A load whose resource goes away mid-run is reported as `LOST`.
  - `--loads` and `--skip` narrow the set.
  - `--vmstress` and `--flood` turn on the optional loads. Every option is recorded in the run's header and its summary.
- **Output.**
  - Each run writes to `~/soak/runs/<board>-<start>-<kernel>/`: `soak.log`, `samples.tsv`, `resources.json`, `memtags/`, `fails/`, `battery-*.txt` and `summary.txt`.
  - It adds a row to `~/soak/ledger.tsv`.
  - It takes locks under `~/soak/locks/` on the Jetson's shared NIC, `hci0` and the USB gadget.
- **Stopping it.** A run stops on its own at the end, or early on SIGTERM. Either way it removes `/tmp/soak/run` on the board, which ends the board's loops, and writes the summary.
