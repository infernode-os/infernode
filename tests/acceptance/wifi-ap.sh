#!/bin/sh
#
# The access point for the Wi-Fi battery: hostapd on the tester's own
# radio, one scenario at a time, switched by an unprivileged battery
# through a control file. This is the only part that needs root, so it
# is the only part that asks for it:
#
#	sudo tests/acceptance/wifi-ap.sh wlP1p1s0
#
# It takes the interface from NetworkManager, gives it 192.168.7.1/24,
# runs dnsmasq for the station's address, and then waits on
# /tmp/wifi-ap.ctl for lines:
#
#	scenario <name>		bring the AP up as <name> (below)
#	stop			take the AP down, keep waiting
#	quit			give the interface back and exit
#
# Scenarios, named after the hostap hwsim tests they stand in for:
#	open		no security (ap_open)
#	wpa2		WPA2-PSK CCMP (ap_wpa2_psk)
#	wpa2-pmf	WPA2-PSK with 802.11w required (ap_pmf_required)
#	wpa3		WPA3-SAE (sae)
#	wpa2-5g		WPA2-PSK on channel 36 (ap_wpa2_psk 5 GHz)
#	wpa2-hidden	WPA2-PSK, SSID not broadcast (ap_hidden_ssid)
#
# SSID is infernode-test-<name>, passphrase "infernode-acceptance".
# Everything it starts, it stops on quit or on SIGINT.

IF=${1:?usage: wifi-ap.sh <interface>}
CTL=/tmp/wifi-ap.ctl
LOG=/tmp/wifi-ap.log
CONF=/tmp/wifi-ap.conf
PASS=infernode-acceptance
HPID=""

[ "$(id -u)" = 0 ] || { echo "wifi-ap.sh: run me with sudo" >&2; exit 2; }

cleanup() {
	stopap
	pkill -f "dnsmasq --interface=$IF" 2>/dev/null
	nmcli dev set "$IF" managed yes 2>/dev/null
	rm -f "$CTL"
	echo "wifi-ap: interface given back"
}
trap 'cleanup; exit 0' INT TERM

stopap() {
	if [ -n "$HPID" ]; then
		kill "$HPID" 2>/dev/null
		wait "$HPID" 2>/dev/null
		HPID=""
		echo "wifi-ap: down"
	fi
}

conf() {
	name=$1
	{
		echo "interface=$IF"
		echo "driver=nl80211"
		echo "ssid=infernode-test-$name"
		echo "country_code=US"
		echo "ieee80211d=1"
		echo "ctrl_interface=/var/run/hostapd"
		case $name in
		wpa2-5g)
			echo "hw_mode=a"; echo "channel=36"; echo "ieee80211n=1"; echo "ieee80211ac=1" ;;
		*)
			echo "hw_mode=g"; echo "channel=6"; echo "ieee80211n=1" ;;
		esac
		case $name in
		open)
			;;
		wpa2|wpa2-5g)
			echo "wpa=2"; echo "wpa_key_mgmt=WPA-PSK"; echo "rsn_pairwise=CCMP"; echo "wpa_passphrase=$PASS" ;;
		wpa2-hidden)
			echo "ignore_broadcast_ssid=1"
			echo "wpa=2"; echo "wpa_key_mgmt=WPA-PSK"; echo "rsn_pairwise=CCMP"; echo "wpa_passphrase=$PASS" ;;
		wpa2-pmf)
			echo "wpa=2"; echo "wpa_key_mgmt=WPA-PSK-SHA256"; echo "rsn_pairwise=CCMP"; echo "wpa_passphrase=$PASS"
			echo "ieee80211w=2" ;;
		wpa3)
			echo "wpa=2"; echo "wpa_key_mgmt=SAE"; echo "rsn_pairwise=CCMP"; echo "sae_password=$PASS"
			echo "ieee80211w=2" ;;
		*)
			return 1 ;;
		esac
	} > "$CONF"
}

startap() {
	stopap
	conf "$1" || { echo "wifi-ap: no such scenario: $1"; return; }
	hostapd "$CONF" > "$LOG" 2>&1 &
	HPID=$!
	sleep 2
	if kill -0 "$HPID" 2>/dev/null; then
		echo "wifi-ap: up as infernode-test-$1"
	else
		echo "wifi-ap: hostapd failed:"; tail -5 "$LOG"; HPID=""
	fi
}

nmcli dev set "$IF" managed no 2>/dev/null
ip link set "$IF" down
ip addr flush dev "$IF"
ip addr add 192.168.7.1/24 dev "$IF"
ip link set "$IF" up
pkill -f "dnsmasq --interface=$IF" 2>/dev/null
dnsmasq --interface="$IF" --bind-interfaces --except-interface=lo --port=0 \
	--dhcp-range=192.168.7.10,192.168.7.50,12h --dhcp-leasefile=/tmp/wifi-ap.leases \
	--pid-file=/tmp/wifi-ap.dnsmasq.pid || { echo "wifi-ap: dnsmasq failed" >&2; exit 1; }
rm -f "$CTL"; mkfifo "$CTL"; chmod 666 "$CTL"
echo "wifi-ap: ready on $IF (192.168.7.1); waiting on $CTL"

while :; do
	if read -r verb arg < "$CTL"; then
		case $verb in
		scenario)	startap "$arg" ;;
		stop)		stopap ;;
		quit)		cleanup; exit 0 ;;
		"")		;;
		*)		echo "wifi-ap: ? $verb" ;;
		esac
	fi
done
