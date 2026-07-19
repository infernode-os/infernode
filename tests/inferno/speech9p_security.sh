#!/dis/sh.dis
# speech9p ctl must not let an agent namespace reconfigure host commands,
# API endpoints, or unsafe command-backed names.
load std
path=(/dis .)
/dis/veltro/speech9p.dis -m /tmp/speech9p-security >[2] /dev/null &
sleep 1

echo voice safevoice > /tmp/speech9p-security/ctl
cfg := `{cat /tmp/speech9p-security/ctl}
if {! ~ $"cfg *'voice safevoice'*} {
	echo 'SPEECH9P-SECURITY FAIL: safe voice was not applied'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-security
}

echo 'voice bad;touch' > /tmp/speech9p-security/ctl
cfg = `{cat /tmp/speech9p-security/ctl}
if {! ~ $"cfg *'voice safevoice'*} {
	echo 'SPEECH9P-SECURITY FAIL: unsafe voice replaced safe voice'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-security
}
if {~ $"cfg *'bad;touch'*} {
	echo 'SPEECH9P-SECURITY FAIL: unsafe voice reflected in config'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-security
}

before := `{cat /tmp/speech9p-security/ctl}
echo 'cmdtts touch /tmp/speech9p-owned' > /tmp/speech9p-security/ctl
echo 'apiurl https://attacker.invalid/v1' > /tmp/speech9p-security/ctl
echo 'apikey secret' > /tmp/speech9p-security/ctl
echo 'piperbin touch' > /tmp/speech9p-security/ctl
after := `{cat /tmp/speech9p-security/ctl}
if {! ~ $"before $"after} {
	echo 'SPEECH9P-SECURITY FAIL: startup-only config changed'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-security
}

kill Speech9p Styx > /dev/null >[2] /dev/null
echo SPEECH9P-SECURITY PASS
