implement Rfc3339;

#
# rfc3339.b — Implementation of module/rfc3339.m
#
# See module/rfc3339.m for the accepted shape and rationale.
#

include "sys.m";
	sys: Sys;

include "daytime.m";
	daytime: Daytime;

include "rfc3339.m";

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(daytime == nil)
		daytime = load Daytime Daytime->PATH;
}

parse(s: string): (int, string)
{
	init();
	if(daytime == nil)
		return (0, "rfc3339: cannot load daytime");

	# Minimum length: YYYY-MM-DDTHH:MM:SSZ = 20 chars
	if(len s < 20)
		return (0, "rfc3339: timestamp too short");

	# Verify fixed punctuation positions.
	if(s[4] != '-' || s[7] != '-' || (s[10] != 'T' && s[10] != ' ') ||
	   s[13] != ':' || s[16] != ':')
		return (0, "rfc3339: bad punctuation (expected YYYY-MM-DDTHH:MM:SS<TZ>)");

	year   := atoi4(s[0:4]);
	month  := atoi2(s[5:7]);
	day    := atoi2(s[8:10]);
	hour   := atoi2(s[11:13]);
	minute := atoi2(s[14:16]);
	sec    := atoi2(s[17:19]);
	if(year < 0 || month < 1 || month > 12 || day < 1 || day > 31 ||
	   hour < 0 || hour > 23 || minute < 0 || minute > 59 ||
	   sec < 0 || sec > 60)
		return (0, "rfc3339: numeric field out of range");

	tz := s[19:];
	# Tolerate fractional seconds (".sss" before the TZ marker) by skipping them.
	if(len tz > 0 && tz[0] == '.') {
		i := 1;
		while(i < len tz && tz[i] >= '0' && tz[i] <= '9')
			i++;
		tz = tz[i:];
	}

	tzoff := 0;  # seconds east of UTC
	if(len tz == 1 && (tz[0] == 'Z' || tz[0] == 'z')) {
		tzoff = 0;
	} else if(len tz == 6 && (tz[0] == '+' || tz[0] == '-') && tz[3] == ':') {
		off_h := atoi2(tz[1:3]);
		off_m := atoi2(tz[4:6]);
		if(off_h < 0 || off_h > 23 || off_m < 0 || off_m > 59)
			return (0, "rfc3339: timezone offset out of range");
		tzoff = (off_h * 3600) + (off_m * 60);
		if(tz[0] == '-')
			tzoff = -tzoff;
	} else {
		return (0, "rfc3339: timezone must be Z, +HH:MM, or -HH:MM");
	}

	tm := ref Daytime->Tm;
	tm.sec = sec; tm.min = minute; tm.hour = hour;
	tm.mday = day; tm.mon = month - 1; tm.year = year - 1900;
	tm.zone = "GMT"; tm.tzoff = 0;
	# tm2epoch interprets tm as GMT. The local clock value the user wrote
	# was offset by tzoff seconds east of UTC, so subtract to get true UTC.
	return (daytime->tm2epoch(tm) - tzoff, "");
}

# atoi2 / atoi4: strict-width unsigned decimal parsers. Return -1 on
# any non-digit character.
atoi2(s: string): int
{
	if(len s != 2 || s[0] < '0' || s[0] > '9' || s[1] < '0' || s[1] > '9')
		return -1;
	return (s[0] - '0') * 10 + (s[1] - '0');
}

atoi4(s: string): int
{
	if(len s != 4)
		return -1;
	v := 0;
	for(i := 0; i < 4; i++) {
		if(s[i] < '0' || s[i] > '9')
			return -1;
		v = v * 10 + (s[i] - '0');
	}
	return v;
}
