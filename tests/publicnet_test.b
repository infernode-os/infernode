implement PublicnetTest;

include "sys.m";
	sys: Sys;
include "draw.m";
include "publicnet.m";
	publicnet: Publicnet;

PublicnetTest: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	publicnet = load Publicnet Publicnet->PATH;
	if(publicnet == nil) {
		sys->print("PUBLICNET FAIL: load: %r\n");
		return;
	}
	publicnet->init();
	private := array[] of {
		"0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1",
		"169.254.169.254", "172.16.0.1", "192.168.1.1",
		"198.18.0.1", "224.0.0.1", "255.255.255.255"
	};
	for(i := 0; i < len private; i++)
		if(publicnet->publicipv4(private[i]) != 0) {
			sys->print("PUBLICNET FAIL: accepted private/reserved %s\n", private[i]);
			return;
		}
	malformed := array[] of {"", "1.2.3", "1.2.3.4.5", "256.1.1.1", "::1", "localhost"};
	for(i = 0; i < len malformed; i++)
		if(publicnet->publicipv4(malformed[i]) != -1) {
			sys->print("PUBLICNET FAIL: accepted malformed %s\n", malformed[i]);
			return;
		}
	if(publicnet->publicipv4("8.8.8.8") != 1) {
		sys->print("PUBLICNET FAIL: rejected public address\n");
		return;
	}
	(addr, err) := publicnet->dialaddr("127.0.0.1", "80");
	if(err == nil || addr != nil) {
		sys->print("PUBLICNET FAIL: loopback dial address issued\n");
		return;
	}
	(addr, err) = publicnet->dialaddr("8.8.8.8", "53");
	if(err != nil || addr != "tcp!8.8.8.8!53") {
		sys->print("PUBLICNET FAIL: public pin addr=%s err=%s\n", addr, err);
		return;
	}
	sys->print("PUBLICNET PASS: classify, deny loopback, pin public address\n");
}
