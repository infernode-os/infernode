#
# jsdate.b - Date (ECMAScript 2025 §21.4).  Included by js.b.
#
# A time value is milliseconds since 1970-01-01T00:00:00Z, NaN when
# invalid.  The local time zone's offset is daytime(2)'s (/locale/timezone).
#

msday: con 86400000.0;

dateinit()
{
	c := ctor("Date", 7, datector, idateproto);
	method(c, "now", 0, date_now);
	method(c, "parse", 1, date_parse);
	method(c, "UTC", 7, date_utc);
	p := idateproto;
	gets := array[] of {
		("getDate", 0), ("getDay", 1), ("getFullYear", 2), ("getHours", 3), ("getMilliseconds", 4),
		("getMinutes", 5), ("getMonth", 6), ("getSeconds", 7), ("getTime", 8), ("getTimezoneOffset", 9),
		("getUTCDate", 10), ("getUTCDay", 11), ("getUTCFullYear", 12), ("getUTCHours", 13),
		("getUTCMilliseconds", 14), ("getUTCMinutes", 15), ("getUTCMonth", 16), ("getUTCSeconds", 17),
		("valueOf", 8), ("getYear", 18),
	};
	for(i := 0; i < len gets; i++) {
		(nm, which) := gets[i];
		h := method(p, nm, 0, dateget);
		setcap(h, array[] of {num(real which)});
	}
	sets := array[] of {
		("setDate", 1, 0), ("setFullYear", 3, 1), ("setHours", 4, 2), ("setMilliseconds", 1, 3),
		("setMinutes", 3, 4), ("setMonth", 2, 5), ("setSeconds", 2, 6),
		("setUTCDate", 1, 10), ("setUTCFullYear", 3, 11), ("setUTCHours", 4, 12), ("setUTCMilliseconds", 1, 13),
		("setUTCMinutes", 3, 14), ("setUTCMonth", 2, 15), ("setUTCSeconds", 2, 16),
	};
	for(i = 0; i < len sets; i++) {
		(nm, l, which) := sets[i];
		h := method(p, nm, l, dateset);
		setcap(h, array[] of {num(real which)});
	}
	method(p, "setTime", 1, dateproto_settime);
	method(p, "setYear", 1, dateproto_setyear);
	method(p, "toDateString", 0, dateproto_todatestring);
	method(p, "toISOString", 0, dateproto_toisostring);
	method(p, "toJSON", 1, dateproto_tojson);
	method(p, "toLocaleDateString", 0, dateproto_todatestring);
	method(p, "toLocaleString", 0, dateproto_tostring);
	method(p, "toLocaleTimeString", 0, dateproto_totimestring);
	method(p, "toString", 0, dateproto_tostring);
	method(p, "toTimeString", 0, dateproto_totimestring);
	utc := method(p, "toUTCString", 0, dateproto_toutcstring);
	defown(p, intern("toGMTString"), Awrite|Aconf, objv(utc));
	h := nativefn("[Symbol.toPrimitive]", 1, dateproto_toprimitive);
	defown(p, asymtoprim, Aconf, objv(h));
}

# ---- the time arithmetic of §21.4.1 ----

flr(x: real): real
{
	return math->floor(x);
}

day(t: real): real
{
	return flr(t / msday);
}

timewithinday(t: real): real
{
	r := math->fmod(t, msday);
	if(r < 0.0)
		r += msday;
	return r;
}

daysinyear(y: real): real
{
	if(math->fmod(y, 4.0) != 0.0)
		return 365.0;
	if(math->fmod(y, 100.0) != 0.0)
		return 366.0;
	if(math->fmod(y, 400.0) != 0.0)
		return 365.0;
	return 366.0;
}

dayfromyear(y: real): real
{
	return 365.0 * (y - 1970.0) + flr((y - 1969.0) / 4.0) - flr((y - 1901.0) / 100.0) + flr((y - 1601.0) / 400.0);
}

timefromyear(y: real): real
{
	return msday * dayfromyear(y);
}

yearfromtime(t: real): real
{
	y := flr(t / (msday * 365.2425)) + 1970.0;
	while(timefromyear(y) > t)
		y -= 1.0;
	while(timefromyear(y + 1.0) <= t)
		y += 1.0;
	return y;
}

inleapyear(t: real): int
{
	return daysinyear(yearfromtime(t)) == 366.0;
}

daywithinyear(t: real): real
{
	return day(t) - dayfromyear(yearfromtime(t));
}

# cumulative days before each month (not a leap year)
monthstart := array[] of {0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365};

monthfromtime(t: real): real
{
	d := int daywithinyear(t);
	leap := inleapyear(t);
	for(m := 0; m < 12; m++) {
		end := monthstart[m+1];
		if(m >= 1 && leap)
			end++;
		if(d < end)
			return real m;
	}
	return 11.0;
}

datefromtime(t: real): real
{
	d := int daywithinyear(t);
	m := int monthfromtime(t);
	st := monthstart[m];
	if(m >= 2 && inleapyear(t))
		st++;
	return real (d - st + 1);
}

weekday(t: real): real
{
	r := math->fmod(day(t) + 4.0, 7.0);
	if(r < 0.0)
		r += 7.0;
	return r;
}

hourfromtime(t: real): real
{
	return flr(timewithinday(t) / 3600000.0);
}

minfromtime(t: real): real
{
	return math->fmod(flr(timewithinday(t) / 60000.0), 60.0);
}

secfromtime(t: real): real
{
	return math->fmod(flr(timewithinday(t) / 1000.0), 60.0);
}

msfromtime(t: real): real
{
	return math->fmod(timewithinday(t), 1000.0);
}

finite(x: real): int
{
	return !isnan(x) && x != inf && x != -inf;
}

# ToIntegerOrInfinity for MakeTime and MakeDay's arguments
tint(x: real): real
{
	if(isnan(x) || x == 0.0)
		return 0.0;
	return trunc(x);
}

maketime(h, m, s, ms: real): real
{
	if(!finite(h) || !finite(m) || !finite(s) || !finite(ms))
		return nan;
	return tint(h) * 3600000.0 + tint(m) * 60000.0 + tint(s) * 1000.0 + tint(ms);
}

makeday(year, month, date: real): real
{
	if(!finite(year) || !finite(month) || !finite(date))
		return nan;
	y := tint(year);
	m := tint(month);
	dt := tint(date);
	ym := y + flr(m / 12.0);
	if(!finite(ym) || ym > 400000.0 || ym < -400000.0)
		return nan;
	mn := int math->fmod(m, 12.0);
	if(mn < 0)
		mn += 12;
	days := dayfromyear(ym) + real monthstart[mn];
	if(mn >= 2 && daysinyear(ym) == 366.0)
		days += 1.0;
	return days + dt - 1.0;
}

makedate(d, t: real): real
{
	if(!finite(d) || !finite(t))
		return nan;
	tv := d * msday + t;
	if(!finite(tv))
		return nan;
	return tv;
}

timeclip(t: real): real
{
	if(!finite(t) || math->fabs(t) > 8.64e15)
		return nan;
	return tint(t) + 0.0;
}

# the local time zone's offset from UTC at t (UTC), in ms
tzoffset(t: real): real
{
	if(daytime == nil)
		daytime = load Daytime Daytime->PATH;
	if(daytime == nil || !finite(t))
		return 0.0;
	secs := flr(t / 1000.0);
	if(secs > 2147483647.0 || secs < -2147483648.0)
		secs = math->fmod(secs, 86400.0 * 365.0 * 28.0);	# (outside daytime's range: a similar year)
	tm := daytime->local(int secs);
	if(tm == nil)
		return 0.0;
	return real tm.tzoff * 1000.0;
}

localtime(t: real): real
{
	return t + tzoffset(t);
}

utcfromlocal(t: real): real
{
	if(!finite(t))
		return nan;
	return t - tzoffset(t - tzoffset(t));
}

# ---- the objects ----

thisdate(this: V, name: string): real
{
	if(this.t == Tobj && okind[this.x] == Kdate)
		pick d := odata[this.x] {
		Prim =>
			return d.v.n;
		}
	typeerr("Date.prototype." + name + " called on incompatible receiver " + show(this));
	return nan;
}

setdate(this: V, t: real)
{
	pick d := odata[this.x] {
	Prim =>
		d.v = num(t);
	}
}

# the epoch's millisecond at sys->millisec() == 0, fixed once (so the clock is monotonic)
clockbase := -1.0;

now(): real
{
	if(clockbase < 0.0) {
		# /dev/time's microseconds; daytime's seconds without it
		us := big 0;
		if((fd := sys->open("/dev/time", Sys->OREAD)) != nil) {
			b := array[32] of byte;
			if((k := sys->read(fd, b, len b)) > 0)
				us = big string b[0:k];
		}
		ms := real us / 1000.0;
		if(us <= big 0) {
			if(daytime == nil)
				daytime = load Daytime Daytime->PATH;
			ms = real daytime->now() * 1000.0;
		}
		clockbase = ms - real sys->millisec();
	}
	return clockbase + real sys->millisec();
}

datector(nil: V, a, n: int, nt: V, f: int): V
{
	if(nt.t == Tundef)
		return strv(datestring(now(), 0));
	tv: real;
	if(n == 0)
		tv = now();
	else if(n == 1) {
		v := vs[a];
		if(v.t == Tobj && okind[v.x] == Kdate)
			tv = thisdate(v, "");
		else {
			p := toprim(v, 0);
			if(p.t == Tstr)
				tv = parsedate(str(p.x));
			else
				tv = tonumber(p);
		}
		tv = timeclip(tv);
	} else
		tv = timeclip(utcfromlocal(datefromargs(a, n)));
	h := newobj(Kdate, protofromctor(nt, idateproto));
	odata[h] = ref Data.Prim(num(tv));
	f = 0;
	return objv(h);
}

# the date from (year, month[, date[, hours[, minutes[, seconds[, ms]]]]])
datefromargs(a, n: int): real
{
	vals := array[7] of {* => 0.0};
	vals[2] = 1.0;
	for(i := 0; i < n && i < 7; i++)
		vals[i] = tonumber(vs[a+i]);
	y := vals[0];
	if(!isnan(y)) {
		yi := tint(y);
		if(yi >= 0.0 && yi <= 99.0)
			y = 1900.0 + yi;
	}
	return makedate(makeday(y, vals[1], vals[2]), maketime(vals[3], vals[4], vals[5], vals[6]));
}

date_now(nil: V, nil, nil: int, nil: V, nil: int): V
{
	return num(flr(now()));
}

date_parse(nil: V, a, n: int, nil: V, nil: int): V
{
	return num(parsedate(tostring(arg(a, n, 0))));
}

date_utc(nil: V, a, n: int, nil: V, nil: int): V
{
	if(n == 0)
		return num(nan);
	return num(timeclip(datefromargs(a, n)));
}

dateget(this: V, nil, nil: int, nil: V, f: int): V
{
	which := int capof(f, 0).n;
	t := thisdate(this, "get");
	if(which == 8)
		return num(t);
	if(isnan(t))
		return num(nan);
	if(which == 9)
		return num((t - localtime(t)) / 60000.0);
	if(which < 10 || which == 18)
		t = localtime(t);
	case which {
	0 or 10 => return num(datefromtime(t));
	1 or 11 => return num(weekday(t));
	2 or 12 => return num(yearfromtime(t));
	3 or 13 => return num(hourfromtime(t));
	4 or 14 => return num(msfromtime(t));
	5 or 15 => return num(minfromtime(t));
	6 or 16 => return num(monthfromtime(t));
	7 or 17 => return num(secfromtime(t));
	18 => return num(yearfromtime(t) - 1900.0);
	}
	return num(nan);
}

# the setters: which 0-6 local, 10-16 UTC (date, fullyear, hours, ms, minutes, month, seconds)
dateset(this: V, a, n: int, nil: V, f: int): V
{
	which := int capof(f, 0).n;
	t := thisdate(this, "set");
	utc := which >= 10;
	w := which % 10;
	args := array[4] of {* => nan};
	for(i := 0; i < n && i < 4; i++)
		args[i] = tonumber(vs[a+i]);
	given := n;
	if(w == 1) {
		# setFullYear: NaN time becomes +0
		if(isnan(t))
			t = 0.0;
		else if(!utc)
			t = localtime(t);
	} else {
		if(isnan(t))
			return num(nan);
		if(!utc)
			t = localtime(t);
	}
	yr := yearfromtime(t);
	mo := monthfromtime(t);
	dt := datefromtime(t);
	hr := hourfromtime(t);
	mi := minfromtime(t);
	se := secfromtime(t);
	ms := msfromtime(t);
	nd: real;
	case w {
	0 =>
		nd = makedate(makeday(yr, mo, args[0]), timewithinday(t));
	1 =>
		m := mo;
		d := dt;
		if(given > 1)
			m = args[1];
		if(given > 2)
			d = args[2];
		nd = makedate(makeday(args[0], m, d), timewithinday(t));
	2 =>
		m := mi;
		s := se;
		mm := ms;
		if(given > 1)
			m = args[1];
		if(given > 2)
			s = args[2];
		if(given > 3)
			mm = args[3];
		nd = makedate(day(t), maketime(args[0], m, s, mm));
	3 =>
		nd = makedate(day(t), maketime(hr, mi, se, args[0]));
	4 =>
		s := se;
		mm := ms;
		if(given > 1)
			s = args[1];
		if(given > 2)
			mm = args[2];
		nd = makedate(day(t), maketime(hr, args[0], s, mm));
	5 =>
		d := dt;
		if(given > 1)
			d = args[1];
		nd = makedate(makeday(yr, args[0], d), timewithinday(t));
	6 =>
		mm := ms;
		if(given > 1)
			mm = args[1];
		nd = makedate(day(t), maketime(hr, mi, args[0], mm));
	}
	if(!utc)
		nd = utcfromlocal(nd);
	nd = timeclip(nd);
	setdate(this, nd);
	return num(nd);
}

dateproto_settime(this: V, a, n: int, nil: V, nil: int): V
{
	thisdate(this, "setTime");
	t := timeclip(tonumber(arg(a, n, 0)));
	setdate(this, t);
	return num(t);
}

dateproto_setyear(this: V, a, n: int, nil: V, nil: int): V
{
	t := thisdate(this, "setYear");
	y := tonumber(arg(a, n, 0));
	if(isnan(y)) {
		setdate(this, nan);
		return num(nan);
	}
	if(isnan(t))
		t = 0.0;
	else
		t = localtime(t);
	yi := tint(y);
	if(yi >= 0.0 && yi <= 99.0)
		yi += 1900.0;
	d := makeday(yi, monthfromtime(t), datefromtime(t));
	nd := timeclip(utcfromlocal(makedate(d, timewithinday(t))));
	setdate(this, nd);
	return num(nd);
}

daynames := array[] of {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
monthnames := array[] of {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

pad2(x: real): string
{
	return sys->sprint("%.2d", int x);
}

yearstr(y: real): string
{
	if(y < 0.0)
		return sys->sprint("-%.4d", int -y);
	return sys->sprint("%.4d", int y);
}

# DateString, TimeString, TimeZoneString; parts: 0 all, 1 date, 2 time
datestring(tv: real, parts: int): string
{
	if(isnan(tv))
		return "Invalid Date";
	t := localtime(tv);
	ds := daynames[int weekday(t)] + " " + monthnames[int monthfromtime(t)] + " " + pad2(datefromtime(t)) + " " + yearstr(yearfromtime(t));
	off := (t - tv) / 60000.0;
	sign := "+";
	if(off < 0.0) {
		sign = "-";
		off = -off;
	}
	tz := "GMT" + sign + pad2(flr(off / 60.0)) + pad2(math->fmod(off, 60.0));
	ts := pad2(hourfromtime(t)) + ":" + pad2(minfromtime(t)) + ":" + pad2(secfromtime(t)) + " " + tz;
	case parts {
	1 => return ds;
	2 => return ts;
	}
	return ds + " " + ts;
}

dateproto_tostring(this: V, nil, nil: int, nil: V, nil: int): V
{
	return strv(datestring(thisdate(this, "toString"), 0));
}

dateproto_todatestring(this: V, nil, nil: int, nil: V, nil: int): V
{
	return strv(datestring(thisdate(this, "toDateString"), 1));
}

dateproto_totimestring(this: V, nil, nil: int, nil: V, nil: int): V
{
	return strv(datestring(thisdate(this, "toTimeString"), 2));
}

dateproto_toutcstring(this: V, nil, nil: int, nil: V, nil: int): V
{
	t := thisdate(this, "toUTCString");
	if(isnan(t))
		return strv("Invalid Date");
	return strv(daynames[int weekday(t)] + ", " + pad2(datefromtime(t)) + " " + monthnames[int monthfromtime(t)] + " " + yearstr(yearfromtime(t)) + " " +
		pad2(hourfromtime(t)) + ":" + pad2(minfromtime(t)) + ":" + pad2(secfromtime(t)) + " GMT");
}

dateproto_toisostring(this: V, nil, nil: int, nil: V, nil: int): V
{
	t := thisdate(this, "toISOString");
	if(!finite(t))
		throwerr(RangeError, "invalid time value");
	y := yearfromtime(t);
	ys: string;
	if(y >= 0.0 && y <= 9999.0)
		ys = sys->sprint("%.4d", int y);
	else if(y < 0.0)
		ys = sys->sprint("-%.6d", int -y);
	else
		ys = sys->sprint("+%.6d", int y);
	return strv(ys + "-" + pad2(monthfromtime(t) + 1.0) + "-" + pad2(datefromtime(t)) + "T" +
		pad2(hourfromtime(t)) + ":" + pad2(minfromtime(t)) + ":" + pad2(secfromtime(t)) + "." +
		sys->sprint("%.3d", int msfromtime(t)) + "Z");
}

dateproto_tojson(this: V, nil, nil: int, nil: V, nil: int): V
{
	o := objv(toobject(this));
	tv := toprim(o, 1);
	if(tv.t == Tnum && !finite(tv.n))
		return null;
	return invoke(o, intern("toISOString"), nil);
}

dateproto_toprimitive(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("Date.prototype[Symbol.toPrimitive] called on non-object");
	h := arg(a, n, 0);
	hint := 0;
	if(h.t == Tstr) {
		case str(h.x) {
		"string" or "default" => hint = 2;
		"number" => hint = 1;
		* => typeerr("invalid hint");
		}
	} else
		typeerr("invalid hint");
	return ordinarytoprim(this, hint);
}

# OrdinaryToPrimitive
ordinarytoprim(v: V, hint: int): V
{
	first := atostring;
	second := avalueof;
	if(hint == 1) {
		first = avalueof;
		second = atostring;
	}
	f := getv(v, first);
	if(iscallable(f)) {
		r := call(f, v, nil);
		if(r.t != Tobj)
			return r;
	}
	f = getv(v, second);
	if(iscallable(f)) {
		r := call(f, v, nil);
		if(r.t != Tobj)
			return r;
	}
	typeerr("cannot convert object to primitive value");
	return undef;
}

# ---- parsing: the ISO format (§21.4.1.32), then the toString and toUTCString formats ----

parsedate(s: string): real
{
	s = trimws(s, 1, 1);
	t := parseiso(s);
	if(!isnan(t) || len s == 0)
		return t;
	return parseloose(s);
}

digits(s: string, i, n: int): (int, int)
{
	if(i + n > len s)
		return (-1, i);
	v := 0;
	for(k := 0; k < n; k++) {
		c := s[i+k];
		if(c < '0' || c > '9')
			return (-1, i);
		v = v * 10 + c - '0';
	}
	return (v, i + n);
}

parseiso(s: string): real
{
	i := 0;
	y: int;
	sign := 1;
	if(i < len s && (s[i] == '+' || s[i] == '-')) {
		if(s[i] == '-')
			sign = -1;
		(y, i) = digits(s, i + 1, 6);
		if(y < 0 || sign == -1 && y == 0)
			return nan;
	} else {
		(y, i) = digits(s, 0, 4);
		if(y < 0)
			return nan;
	}
	year := real (sign * y);
	mon := 1;
	dd := 1;
	if(i < len s && s[i] == '-') {
		(mon, i) = digits(s, i + 1, 2);
		if(mon < 1 || mon > 12)
			return nan;
		if(i < len s && s[i] == '-') {
			(dd, i) = digits(s, i + 1, 2);
			if(dd < 1 || dd > 31)
				return nan;
		}
	}
	hh := 0;
	mm := 0;
	ss := 0;
	ms := 0;
	datetime := 0;
	utc := 1;
	off := 0.0;
	if(i < len s && s[i] == 'T') {
		datetime = 1;
		(hh, i) = digits(s, i + 1, 2);
		if(hh < 0 || i >= len s || s[i] != ':')
			return nan;
		(mm, i) = digits(s, i + 1, 2);
		if(mm < 0)
			return nan;
		if(i < len s && s[i] == ':') {
			(ss, i) = digits(s, i + 1, 2);
			if(ss < 0)
				return nan;
			if(i < len s && s[i] == '.') {
				i++;
				st := i;
				while(i < len s && s[i] >= '0' && s[i] <= '9')
					i++;
				if(i == st)
					return nan;
				frac := s[st:i] + "000";
				ms = int frac[0:3];
			}
		}
		if(hh > 24 || mm > 59 || ss > 59 || hh == 24 && (mm != 0 || ss != 0 || ms != 0))
			return nan;
		utc = 0;
		if(i < len s && s[i] == 'Z') {
			utc = 1;
			i++;
		} else if(i < len s && (s[i] == '+' || s[i] == '-')) {
			sg := 1.0;
			if(s[i] == '-')
				sg = -1.0;
			oh, om: int;
			(oh, i) = digits(s, i + 1, 2);
			if(oh < 0 || i >= len s || s[i] != ':')
				return nan;
			(om, i) = digits(s, i + 1, 2);
			if(om < 0 || oh > 23 || om > 59)
				return nan;
			utc = 1;
			off = sg * real (oh * 60 + om) * 60000.0;
		}
	}
	if(i != len s)
		return nan;
	# the day must exist in its month
	if(real dd > dimonth(year, mon - 1))
		return nan;
	t := makedate(makeday(year, real (mon - 1), real dd), maketime(real hh, real mm, real ss, real ms));
	if(datetime && !utc)
		t = utcfromlocal(t);
	return timeclip(t - off);
}

dimonth(y: real, m: int): real
{
	d := monthstart[m+1] - monthstart[m];
	if(m == 1 && daysinyear(y) == 366.0)
		d++;
	return real d;
}

# "Tue Oct 10 2026 09:00:00 GMT+0100" and "Tue, 10 Oct 2026 09:00:00 GMT" and the like
parseloose(s: string): real
{
	(nil, f) := sys->tokenize(s, " ,");
	year := -1.0;
	mon := -1;
	dd := -1;
	hh := 0;
	mm := 0;
	ss := 0;
	off := 0.0;
	haveoff := 0;
	for(; f != nil; f = tl f) {
		w := hd f;
		m := monthindex(w);
		if(m >= 0) {
			mon = m;
			continue;
		}
		if(dayindex(w) >= 0)
			continue;
		if(len w >= 3 && w[0:3] == "GMT" || w == "UTC" || w == "Z") {
			haveoff = 1;
			r := w[3:];
			if(w == "UTC" || w == "Z")
				r = "";
			if(len r >= 5 && (r[0] == '+' || r[0] == '-')) {
				(oh, nil) := digits(r, 1, 2);
				(om, nil) := digits(r, 3, 2);
				if(oh < 0 || om < 0)
					return nan;
				off = real (oh * 60 + om) * 60000.0;
				if(r[0] == '-')
					off = -off;
			}
			continue;
		}
		if(len w > 0 && w[0] == '(')
			break;
		if(hasch(w, ':')) {
			(nil, parts) := sys->tokenize(w, ":");
			if(len parts < 2)
				return nan;
			hh = int hd parts;
			mm = int hd tl parts;
			if(len parts > 2)
				ss = int hd tl tl parts;
			continue;
		}
		if(isdigits(w)) {
			v := int w;
			if(dd < 0 && len w <= 2)
				dd = v;
			else
				year = real v;
			continue;
		}
		if(len w > 1 && w[0] == '-' && isdigits(w[1:])) {
			year = -real int w[1:];
			continue;
		}
		return nan;
	}
	if(year < -271821.0 || mon < 0 || dd < 0)
		return nan;
	t := makedate(makeday(year, real mon, real dd), maketime(real hh, real mm, real ss, 0.0));
	if(haveoff)
		return timeclip(t - off);
	return timeclip(utcfromlocal(t));
}

monthindex(w: string): int
{
	if(len w < 3)
		return -1;
	for(i := 0; i < 12; i++)
		if(tolower(w[0:3]) == tolower(monthnames[i]))
			return i;
	return -1;
}

dayindex(w: string): int
{
	if(len w < 3)
		return -1;
	for(i := 0; i < 7; i++)
		if(tolower(w[0:3]) == tolower(daynames[i]))
			return i;
	return -1;
}

hasch(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return 1;
	return 0;
}

isdigits(s: string): int
{
	if(s == "")
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}
