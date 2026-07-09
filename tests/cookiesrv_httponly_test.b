implement CookiesrvHttponlyTest;

include "sys.m";
	sys: Sys;
include "draw.m";
include "../appl/charon/cookiesrv.m";

CookiesrvHttponlyTest: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

fail(msg: string)
{
	sys->print("COOKIESRV HTTPONLY FAIL: %s\n", msg);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	ckmod := load Cookiesrv Cookiesrv->PATH;
	if(ckmod == nil) {
		sys->print("COOKIESRV HTTPONLY FAIL: load: %r\n");
		return;
	}
	sys->remove("/tmp/cookiesrv_httponly_test");
	c := ckmod->start("/tmp/cookiesrv_httponly_test", 0);
	if(c == nil) {
		fail("start");
		return;
	}
	Client: import ckmod;
	c.set("example.com", "/account/index.html", "sid=secret; Path=/; HttpOnly");
	http := c.getcookies("example.com", "/account/index.html", 0);
	if(http != "sid=secret") {
		fail("http path did not receive HttpOnly cookie: " + http);
		return;
	}
	js := c.getscriptcookies("example.com", "/account/index.html", 0);
	if(js != "") {
		fail("script path read HttpOnly cookie: " + js);
		return;
	}
	c.setscript("example.com", "/account/index.html", "sid=evil; Path=/");
	http = c.getcookies("example.com", "/account/index.html", 0);
	if(http != "sid=secret") {
		fail("script overwrote HttpOnly cookie: " + http);
		return;
	}
	c.setscript("example.com", "/account/index.html", "visible=yes; Path=/; HttpOnly");
	js = c.getscriptcookies("example.com", "/account/index.html", 0);
	if(js != "visible=yes") {
		fail("script-set HttpOnly attribute was not ignored: " + js);
		return;
	}
	sys->print("COOKIESRV HTTPONLY PASS: script cannot read or overwrite HttpOnly cookies\n");
}
