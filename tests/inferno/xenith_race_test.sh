#!/dis/sh.dis
#
# Xenith driven by a client and its user at once, where it froze or
# exited: the checks are in tests/xenith_race_helper.b, which this runs.
#
# Prerequisites:
#   - Xenith must be running
#   - /mnt/xenith must be mounted
#   - /tmp is writable
#
# tests/host/xenith_race_test.sh starts Xenith and runs this.

load std

if {! ftest -f /mnt/xenith/new/ctl} {
	raise 'skip:Xenith not mounted at /mnt/xenith'
}

/dis/tests/xenith_race_helper.dis
