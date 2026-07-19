#!/dis/sh.dis
# wiki9p ingest paths must stay under the service's raw bind point.
load std
path=(/dis .)
/dis/veltro/wiki9p.dis -m /tmp/wiki9p-security >[2] /dev/null &
sleep 1
if {! /tests/wiki9p_security_probe.dis} {
	kill Wiki9p Styx > /dev/null >[2] /dev/null
	raise fail:wiki9p-security
}
kill Wiki9p Styx > /dev/null >[2] /dev/null
