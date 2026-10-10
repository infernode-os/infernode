// intl.js - Intl for a web page's realm.
//
// The engine runs this before dom.js.  It is a small Intl: English
// words and formats, with the separators of a few other locales; the
// other locales a page asks for are accepted and formatted as English.
// There is no time zone database: times are the host's local time or
// UTC, whatever zone a page names.  The toLocale methods of Number,
// BigInt, Date, Array and String go through it.

(function () {
'use strict';

const defineProperty = Object.defineProperty;

function hidden(o, props) {
	for (const k of Reflect.ownKeys(props))
		defineProperty(o, k, {value: props[k], writable: true, configurable: true, enumerable: false});
}

function tag(C, name) {
	defineProperty(C.prototype, Symbol.toStringTag, {value: name, configurable: true});
}

// ---- locales ----

function canon(t) {
	if (typeof t !== 'string' && (typeof t !== 'object' || t === null))
		throw new TypeError('Incorrect locale information provided');
	t = String(t instanceof Locale ? t.toString() : t);
	if (!/^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$/.test(t))
		throw new RangeError('Incorrect locale information provided');
	return t.split('-').map((p, i) => i === 0 ? p.toLowerCase() :
		p.length === 2 ? p.toUpperCase() :
		p.length === 4 && /^[A-Za-z]+$/.test(p) ? p[0].toUpperCase() + p.slice(1).toLowerCase() :
		p.toLowerCase()).join('-');
}

function canonlist(l) {
	if (l === undefined)
		return [];
	if (typeof l === 'string' || l instanceof Locale)
		return [canon(l)];
	const r = [];
	for (const t of Object(l)) {
		const c = canon(t);
		if (!r.includes(c))
			r.push(c);
	}
	return r;
}

function pick(l) {
	const a = canonlist(l);
	return a.length ? a[0] : 'en-US';
}

function lang(loc) {
	return loc.split('-')[0];
}

// grouping and decimal separators
const SEPS = {
	en: [',', '.'], de: ['.', ','], es: ['.', ','], it: ['.', ','], nl: ['.', ','],
	pt: ['.', ','], id: ['.', ','], tr: ['.', ','], da: ['.', ','],
	fr: [' ', ','], ru: [' ', ','], pl: [' ', ','], sv: [' ', ','],
	nb: [' ', ','], fi: [' ', ','], cs: [' ', ','], uk: [' ', ','],
	ja: [',', '.'], ko: [',', '.'], th: [',', '.'], hi: [',', '.'], he: [',', '.'],
};

function seps(loc) {
	if (loc === 'de-CH')
		return ['’', '.'];
	return SEPS[lang(loc)] || SEPS.en;
}

function opt(o, k, allowed, dflt) {
	let v = o[k];
	if (v === undefined)
		return dflt;
	v = String(v);
	if (allowed && !allowed.includes(v))
		throw new RangeError(`Value ${v} out of range for Intl options property ${k}`);
	return v;
}

function numopt(o, k, lo, hi, dflt) {
	let v = o[k];
	if (v === undefined)
		return dflt;
	v = Number(v);
	if (!(v >= lo && v <= hi))
		throw new RangeError(`${k} value is out of range.`);
	return Math.floor(v);
}

function options(o) {
	return o === undefined ? Object.create(null) : Object(o);
}

function supported(l) {
	return canonlist(l);
}

class Locale {
	constructor(t, o) {
		if (new.target === undefined)
			throw new TypeError("Constructor Intl.Locale requires 'new'");
		const parts = canon(t).split('-');
		o = options(o);
		let language = parts[0], script, region;
		for (const p of parts.slice(1)) {
			if (/^[A-Z][a-z]{3}$/.test(p))
				script = p;
			else if (/^([A-Z]{2}|\d{3})$/.test(p))
				region = p;
		}
		if (o.language !== undefined)
			language = String(o.language);
		if (o.script !== undefined)
			script = String(o.script);
		if (o.region !== undefined)
			region = String(o.region);
		hidden(this, {_language: language, _script: script, _region: region,
			_calendar: o.calendar, _hourCycle: o.hourCycle, _numberingSystem: o.numberingSystem});
	}
	get language() { return this._language; }
	get script() { return this._script; }
	get region() { return this._region; }
	get baseName() { return [this._language, this._script, this._region].filter(Boolean).join('-'); }
	get calendar() { return this._calendar; }
	get hourCycle() { return this._hourCycle; }
	get numberingSystem() { return this._numberingSystem; }
	maximize() { return this; }
	minimize() { return this; }
	toString() { return this.baseName; }
	getWeekInfo() { return {firstDay: 7, weekend: [6, 7], minimalDays: 1}; }
	getTextInfo() { return {direction: ['ar', 'he', 'fa', 'ur'].includes(this._language) ? 'rtl' : 'ltr'}; }
}
tag(Locale, 'Intl.Locale');

// ---- numbers ----

const CURRENCY = {USD: '$', EUR: '€', GBP: '£', JPY: '¥', CNY: 'CN¥', INR: '₹', KRW: '₩',
	CAD: 'CA$', AUD: 'A$', BRL: 'R$', MXN: 'MX$', ILS: '₪', VND: '₫', THB: '฿', TWD: 'NT$',
	NZD: 'NZ$', HKD: 'HK$', PHP: '₱'};
const CURRENCYNAME = {USD: 'US dollars', EUR: 'euros', GBP: 'British pounds', JPY: 'Japanese yen'};
const NOFRACTION = ['JPY', 'KRW', 'VND', 'CLP', 'ISK', 'HUF', 'TWD'];
const UNITS = {
	kilometer: ['km', 'kilometers'], meter: ['m', 'meters'], centimeter: ['cm', 'centimeters'],
	millimeter: ['mm', 'millimeters'], mile: ['mi', 'miles'], foot: ['ft', 'feet'], inch: ['in', 'inches'],
	kilogram: ['kg', 'kilograms'], gram: ['g', 'grams'], pound: ['lb', 'pounds'],
	liter: ['L', 'liters'], milliliter: ['mL', 'milliliters'],
	second: ['sec', 'seconds'], minute: ['min', 'minutes'], hour: ['hr', 'hours'], day: ['days', 'days'],
	week: ['wks', 'weeks'], month: ['mths', 'months'], year: ['yrs', 'years'],
	millisecond: ['ms', 'milliseconds'], byte: ['byte', 'bytes'], kilobyte: ['kB', 'kilobytes'],
	megabyte: ['MB', 'megabytes'], gigabyte: ['GB', 'gigabytes'], terabyte: ['TB', 'terabytes'],
	percent: ['%', 'percent'], celsius: ['°C', 'degrees Celsius'], fahrenheit: ['°F', 'degrees Fahrenheit'],
	'kilometer-per-hour': ['km/h', 'kilometers per hour'], 'mile-per-hour': ['mph', 'miles per hour'],
};

// x (finite, >= 0) as a decimal string rounded to f fraction digits
function fixed(x, f) {
	if (x >= 1e21) {
		let s = BigInt(Math.round(x)).toString();
		return f > 0 ? s + '.' + '0'.repeat(f) : s;
	}
	return x.toFixed(f);
}

// x rounded to p significant digits, as a plain decimal string
function precise(x, p) {
	if (x === 0)
		return '0';
	const e = Math.floor(Math.log10(x));
	const f = Math.max(0, p - 1 - e);
	let s = f <= 100 ? x.toFixed(f) : x.toPrecision(p);
	// toFixed keeps digits beyond p when e is large: round them away
	if (f === 0 && e + 1 > p) {
		const k = 10 ** (e + 1 - p);
		s = fixed(Math.round(x / k) * k, 0);
	}
	return s;
}

class NumberFormat {
	constructor(l, o) {
		const loc = pick(l);
		o = options(o);
		const style = opt(o, 'style', ['decimal', 'percent', 'currency', 'unit'], 'decimal');
		const currency = o.currency === undefined ? undefined : String(o.currency).toUpperCase();
		if (style === 'currency' && currency === undefined)
			throw new TypeError('Currency code is required with currency style.');
		const unit = o.unit === undefined ? undefined : String(o.unit);
		if (style === 'unit' && unit === undefined)
			throw new TypeError('Unit is required with unit style.');
		const notation = opt(o, 'notation', ['standard', 'scientific', 'engineering', 'compact'], 'standard');
		const cdig = style === 'currency' ? (NOFRACTION.includes(currency) ? 0 : 2) : 0;
		const minf = numopt(o, 'minimumFractionDigits', 0, 100, undefined);
		const maxf = numopt(o, 'maximumFractionDigits', 0, 100, undefined);
		let mnf = minf !== undefined ? minf : cdig;
		let mxf = maxf !== undefined ? maxf :
			Math.max(mnf, style === 'currency' ? cdig : style === 'percent' ? 0 : notation === 'compact' ? 0 : 3);
		if (minf === undefined && mnf > mxf)
			mnf = mxf;
		if (mnf > mxf)
			throw new RangeError('maximumFractionDigits value is out of range.');
		let mns = numopt(o, 'minimumSignificantDigits', 1, 21, undefined);
		let mxs = numopt(o, 'maximumSignificantDigits', 1, 21, undefined);
		if (mns !== undefined || mxs !== undefined) {
			mns = mns ?? 1;
			mxs = mxs ?? 21;
			if (mns > mxs)
				throw new RangeError('maximumSignificantDigits value is out of range.');
		} else if (notation === 'compact' && minf === undefined && maxf === undefined) {
			mns = 1;
			mxs = 2;
		}
		let grouping = o.useGrouping;
		grouping = grouping === undefined ? (notation === 'compact' ? 'min2' : 'auto') :
			grouping === false || grouping === 'false' ? false : grouping === true ? 'always' : String(grouping);
		hidden(this, {_r: {
			locale: loc, numberingSystem: 'latn', style, currency,
			currencyDisplay: opt(o, 'currencyDisplay', ['code', 'symbol', 'narrowSymbol', 'name'], 'symbol'),
			currencySign: opt(o, 'currencySign', ['standard', 'accounting'], 'standard'),
			unit, unitDisplay: opt(o, 'unitDisplay', ['short', 'narrow', 'long'], 'short'),
			minimumIntegerDigits: numopt(o, 'minimumIntegerDigits', 1, 21, 1),
			minimumFractionDigits: mnf, maximumFractionDigits: mxf,
			minimumSignificantDigits: mns, maximumSignificantDigits: mxs,
			useGrouping: grouping, notation,
			compactDisplay: opt(o, 'compactDisplay', ['short', 'long'], 'short'),
			signDisplay: opt(o, 'signDisplay', ['auto', 'never', 'always', 'exceptZero', 'negative'], 'auto'),
			roundingMode: 'halfExpand',
		}});
	}
	get format() {
		const f = (x) => this.formatToParts(x).map((p) => p.value).join('');
		defineProperty(this, 'format', {value: f, configurable: true});
		return f;
	}
	resolvedOptions() {
		const r = {};
		for (const [k, v] of Object.entries(this._r))
			if (v !== undefined)
				r[k] = v;
		return r;
	}
	formatRange(a, b) {
		return this.format(a) + '–' + this.format(b);
	}
	formatRangeToParts(a, b) {
		return [...this.formatToParts(a).map((p) => ({...p, source: 'startRange'})),
			{type: 'literal', value: '–', source: 'shared'},
			...this.formatToParts(b).map((p) => ({...p, source: 'endRange'}))];
	}
	formatToParts(x) {
		const r = this._r;
		if (typeof x === 'bigint')
			x = Number(x);
		else if (typeof x === 'string' && x.trim() !== '' && !isNaN(x))
			x = Number(x);
		else
			x = Number(x);
		const parts = [];
		const neg = x < 0 || Object.is(x, -0);
		let a = Math.abs(x);
		if (r.style === 'percent')
			a *= 100;
		let suffix = '', exp = null;
		if (a === a && a !== Infinity) {
			if (r.notation === 'compact' && a >= 1000) {
				const words = r.compactDisplay === 'long' ? [' thousand', ' million', ' billion', ' trillion'] : ['K', 'M', 'B', 'T'];
				let k = Math.min(Math.floor(Math.log10(a) / 3), 4);
				let v = a / 10 ** (3 * k);
				// rounding can carry into the next magnitude: 999.9K is 1M
				if (Number(this._digits(v)) >= 1000 && k < 4) {
					k++;
					v = a / 10 ** (3 * k);
				}
				a = v;
				suffix = words[k - 1];
			} else if ((r.notation === 'scientific' || r.notation === 'engineering') && a !== 0) {
				let e = Math.floor(Math.log10(a));
				if (r.notation === 'engineering')
					e -= ((e % 3) + 3) % 3;
				a /= 10 ** e;
				exp = e;
			}
		}
		const sign = (() => {
			const zero = a === 0 || Number(this._digits(a)) === 0;
			switch (r.signDisplay) {
			case 'never': return '';
			case 'always': return neg ? '-' : '+';
			case 'exceptZero': return zero ? '' : neg ? '-' : '+';
			case 'negative': return neg && !zero ? '-' : '';
			default: return neg ? '-' : '';
			}
		})();
		const accounting = r.style === 'currency' && r.currencySign === 'accounting' && sign === '-';
		if (accounting)
			parts.push({type: 'literal', value: '('});
		else if (sign)
			parts.push({type: sign === '-' ? 'minusSign' : 'plusSign', value: sign});
		let cur = null;
		if (r.style === 'currency') {
			const c = r.currency;
			cur = r.currencyDisplay === 'code' ? c + ' ' : r.currencyDisplay === 'name' ? null :
				r.currencyDisplay === 'narrowSymbol' ? (CURRENCY[c] || c).replace(/^[A-Z]+(?=\W)/, '') : (CURRENCY[c] || c + ' ');
			if (cur !== null && lang(r.locale) === 'en')
				parts.push({type: 'currency', value: cur.trimEnd()}), cur.endsWith(' ') && parts.push({type: 'literal', value: ' '});
		}
		if (a !== a)
			parts.push({type: 'nan', value: 'NaN'});
		else if (a === Infinity)
			parts.push({type: 'infinity', value: '∞'});
		else
			this._numparts(this._digits(a), parts);
		if (exp !== null)
			parts.push({type: 'exponentSeparator', value: 'E'}, {type: 'exponentInteger', value: String(exp)});
		if (suffix)
			parts.push(suffix[0] === ' ' ? {type: 'literal', value: ' '} : null, {type: 'compact', value: suffix.trim()});
		if (r.style === 'percent')
			parts.push({type: 'percentSign', value: '%'});
		else if (r.style === 'currency' && (cur === null || lang(r.locale) !== 'en')) {
			const n = r.currencyDisplay === 'name' ? (CURRENCYNAME[r.currency] || r.currency) : cur.trimEnd();
			parts.push({type: 'literal', value: ' '}, {type: 'currency', value: n});
		} else if (r.style === 'unit') {
			const u = UNITS[r.unit];
			const long = r.unitDisplay === 'long';
			const name = u ? u[long ? 1 : 0] : r.unit;
			if (r.unit === 'percent' && !long)
				parts.push({type: 'unit', value: '%'});
			else
				parts.push({type: 'literal', value: r.unitDisplay === 'narrow' && u && u[0].length <= 2 ? '' : ' '},
					{type: 'unit', value: long && a === 1 ? name.replace(/s$/, '') : name});
		}
		if (accounting)
			parts.push({type: 'literal', value: ')'});
		return parts.filter(Boolean);
	}
	_digits(a) {
		const r = this._r;
		let s;
		if (r.maximumSignificantDigits !== undefined) {
			s = precise(a, r.maximumSignificantDigits);
			const sig = s.replace('.', '').replace(/^0+/, '').length;
			if (sig < r.minimumSignificantDigits)
				s = a.toPrecision(r.minimumSignificantDigits);
			else if (s.includes('.'))
				s = s.replace(/\.?0+$/, '');
		} else {
			s = fixed(a, r.maximumFractionDigits);
			if (s.includes('.')) {
				let [i, f] = s.split('.');
				while (f.length > r.minimumFractionDigits && f.endsWith('0'))
					f = f.slice(0, -1);
				s = f ? i + '.' + f : i;
			}
		}
		return s;
	}
	_numparts(s, parts) {
		const r = this._r;
		let [i, f] = s.split('.');
		i = i.padStart(r.minimumIntegerDigits, '0');
		const [g, d] = seps(r.locale);
		const group = r.useGrouping === 'always' || r.useGrouping === 'auto' ? i.length > 3 :
			r.useGrouping === 'min2' ? i.length > 4 : false;
		if (group) {
			const first = i.length % 3 || 3;
			parts.push({type: 'integer', value: i.slice(0, first)});
			for (let k = first; k < i.length; k += 3)
				parts.push({type: 'group', value: g}, {type: 'integer', value: i.slice(k, k + 3)});
		} else
			parts.push({type: 'integer', value: i});
		if (f)
			parts.push({type: 'decimal', value: d}, {type: 'fraction', value: f});
	}
	static supportedLocalesOf(l) { return supported(l); }
}
tag(NumberFormat, 'Intl.NumberFormat');

// ---- dates ----

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
	'September', 'October', 'November', 'December'];
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const DATEFIELDS = ['weekday', 'era', 'year', 'month', 'day', 'dayPeriod', 'hour', 'minute', 'second',
	'fractionalSecondDigits', 'timeZoneName'];

function hostzone() {
	return new Date(2000, 0, 1).getTimezoneOffset() === 0 && new Date(2000, 6, 1).getTimezoneOffset() === 0 ? 'UTC' : 'Etc/Unknown';
}

class DateTimeFormat {
	constructor(l, o) {
		const loc = pick(l);
		o = options(o);
		const r = {locale: loc, calendar: 'gregory', numberingSystem: 'latn'};
		let tz = o.timeZone === undefined ? hostzone() : String(o.timeZone);
		if (/^(utc|gmt|etc\/utc|etc\/gmt)$/i.test(tz))
			tz = 'UTC';
		r.timeZone = tz;
		r.utc = tz === 'UTC';
		const ds = opt(o, 'dateStyle', ['full', 'long', 'medium', 'short'], undefined);
		const ts = opt(o, 'timeStyle', ['full', 'long', 'medium', 'short'], undefined);
		let any = false;
		for (const k of DATEFIELDS) {
			if (o[k] !== undefined) {
				r[k] = k === 'fractionalSecondDigits' ? numopt(o, k, 1, 3) : String(o[k]);
				any = true;
			}
		}
		if (any && (ds || ts))
			throw new TypeError("Can't set option " + DATEFIELDS.find((k) => o[k] !== undefined) + ' when dateStyle or timeStyle is used');
		if (ds)
			r.dateStyle = ds;
		if (ts)
			r.timeStyle = ts;
		if (!any && !ds && !ts) {
			r.year = 'numeric';
			r.month = 'numeric';
			r.day = 'numeric';
		}
		const h12 = o.hour12 !== undefined ? !!o.hour12 : o.hourCycle !== undefined ? /h1[12]/.test(o.hourCycle) : lang(loc) === 'en';
		if (r.hour !== undefined || ts) {
			r.hourCycle = h12 ? 'h12' : 'h23';
			r.hour12 = h12;
		}
		hidden(this, {_r: r});
	}
	resolvedOptions() {
		const r = {...this._r};
		delete r.utc;
		return r;
	}
	get format() {
		const f = (d) => this.formatToParts(d).map((p) => p.value).join('');
		defineProperty(this, 'format', {value: f, configurable: true});
		return f;
	}
	formatRange(a, b) {
		return this.format(a) + ' – ' + this.format(b);
	}
	formatToParts(d) {
		const t = d === undefined ? Date.now() : Number(d instanceof Date ? d.getTime() : d);
		if (t !== t)
			throw new RangeError('Invalid time value');
		const r = this._r, D = new Date(t), U = r.utc;
		const v = {
			year: U ? D.getUTCFullYear() : D.getFullYear(), month: U ? D.getUTCMonth() : D.getMonth(),
			day: U ? D.getUTCDate() : D.getDate(), wd: U ? D.getUTCDay() : D.getDay(),
			hour: U ? D.getUTCHours() : D.getHours(), minute: U ? D.getUTCMinutes() : D.getMinutes(),
			second: U ? D.getUTCSeconds() : D.getSeconds(), ms: U ? D.getUTCMilliseconds() : D.getMilliseconds(),
		};
		let f = r;
		if (r.dateStyle || r.timeStyle) {
			f = {hour12: r.hour12};
			switch (r.dateStyle) {
			case 'full': Object.assign(f, {weekday: 'long', month: 'long', day: 'numeric', year: 'numeric'}); break;
			case 'long': Object.assign(f, {month: 'long', day: 'numeric', year: 'numeric'}); break;
			case 'medium': Object.assign(f, {month: 'short', day: 'numeric', year: 'numeric'}); break;
			case 'short': Object.assign(f, {month: 'numeric', day: 'numeric', year: '2-digit'}); break;
			}
			switch (r.timeStyle) {
			case 'full': case 'long': Object.assign(f, {hour: 'numeric', minute: '2-digit', second: '2-digit', timeZoneName: 'short'}); break;
			case 'medium': Object.assign(f, {hour: 'numeric', minute: '2-digit', second: '2-digit'}); break;
			case 'short': Object.assign(f, {hour: 'numeric', minute: '2-digit'}); break;
			}
		}
		const P = [];
		const lit = (s) => P.push({type: 'literal', value: s});
		const two = (n) => String(n).padStart(2, '0');
		const year = f.year === '2-digit' ? two(v.year % 100) : String(v.year);
		const textmonth = f.month === 'long' || f.month === 'short' || f.month === 'narrow';
		const month = f.month === 'long' ? MONTHS[v.month] : f.month === 'short' ? MONTHS[v.month].slice(0, 3) :
			f.month === 'narrow' ? MONTHS[v.month][0] : f.month === '2-digit' ? two(v.month + 1) : String(v.month + 1);
		const day = f.day === '2-digit' ? two(v.day) : String(v.day);
		const wd = f.weekday === 'long' ? DAYS[v.wd] : f.weekday === 'short' ? DAYS[v.wd].slice(0, 3) : f.weekday === 'narrow' ? DAYS[v.wd][0] : null;
		const hasdate = f.year || f.month || f.day || f.weekday;
		if (wd) {
			P.push({type: 'weekday', value: wd});
			if (f.year || f.month || f.day)
				lit(', ');
		}
		if (textmonth) {
			P.push({type: 'month', value: month});
			if (f.day)
				lit(' '), P.push({type: 'day', value: day});
			if (f.year)
				lit(f.day ? ', ' : ' '), P.push({type: 'year', value: year});
		} else {
			const fields = [];
			if (f.month)
				fields.push({type: 'month', value: month});
			if (f.day)
				fields.push({type: 'day', value: day});
			if (f.year)
				fields.push({type: 'year', value: year});
			if (lang(r.locale) !== 'en' || r.locale === 'en-GB' || r.locale === 'en-AU' || r.locale === 'en-IN') {
				const mi = fields.findIndex((p) => p.type === 'month');
				if (mi >= 0 && fields[mi + 1]?.type === 'day')
					[fields[mi], fields[mi + 1]] = [fields[mi + 1], fields[mi]];
			}
			const sep = lang(r.locale) === 'de' ? '.' : '/';
			fields.forEach((p, k) => {
				if (k)
					lit(sep);
				P.push(p);
			});
		}
		if (f.hour || f.minute || f.second) {
			if (hasdate)
				lit(', ');
			const h12 = f.hour12 ?? (r.hour12 ?? lang(r.locale) === 'en');
			let h = v.hour;
			if (f.hour) {
				if (h12)
					h = h % 12 || 12;
				P.push({type: 'hour', value: f.hour === '2-digit' || !h12 && f.minute ? two(h) : String(h)});
			}
			if (f.minute) {
				if (f.hour)
					lit(':');
				P.push({type: 'minute', value: f.hour || f.minute === '2-digit' ? two(v.minute) : String(v.minute)});
			}
			if (f.second) {
				if (f.hour || f.minute)
					lit(':');
				P.push({type: 'second', value: f.hour || f.minute || f.second === '2-digit' ? two(v.second) : String(v.second)});
				if (f.fractionalSecondDigits)
					lit('.'), P.push({type: 'fractionalSecond', value: String(v.ms).padStart(3, '0').slice(0, f.fractionalSecondDigits)});
			}
			if (f.hour && h12)
				lit(' '), P.push({type: 'dayPeriod', value: v.hour < 12 ? 'AM' : 'PM'});
			if (f.timeZoneName)
				lit(' '), P.push({type: 'timeZoneName', value: U ? 'UTC' : zonename(D)});
		}
		return P;
	}
	static supportedLocalesOf(l) { return supported(l); }
}
tag(DateTimeFormat, 'Intl.DateTimeFormat');

function zonename(D) {
	const m = -D.getTimezoneOffset();
	if (m === 0)
		return 'GMT';
	const a = Math.abs(m);
	return 'GMT' + (m < 0 ? '-' : '+') + Math.floor(a / 60) + (a % 60 ? ':' + String(a % 60).padStart(2, '0') : '');
}

// ---- plurals, relative times, lists ----

class PluralRules {
	constructor(l, o) {
		o = options(o);
		hidden(this, {_r: {locale: pick(l), type: opt(o, 'type', ['cardinal', 'ordinal'], 'cardinal'),
			minimumIntegerDigits: 1, minimumFractionDigits: 0, maximumFractionDigits: 3,
			pluralCategories: undefined}});
	}
	select(n) {
		n = Number(n);
		if (this._r.type === 'ordinal') {
			const t = n % 10, h = n % 100;
			return t === 1 && h !== 11 ? 'one' : t === 2 && h !== 12 ? 'two' : t === 3 && h !== 13 ? 'few' : 'other';
		}
		return n === 1 ? 'one' : 'other';
	}
	selectRange(a, b) { return this.select(b); }
	resolvedOptions() {
		return {...this._r, pluralCategories: this._r.type === 'ordinal' ? ['few', 'one', 'two', 'other'] : ['one', 'other']};
	}
	static supportedLocalesOf(l) { return supported(l); }
}
tag(PluralRules, 'Intl.PluralRules');

const RELUNITS = ['year', 'quarter', 'month', 'week', 'day', 'hour', 'minute', 'second'];

class RelativeTimeFormat {
	constructor(l, o) {
		o = options(o);
		hidden(this, {_r: {locale: pick(l), style: opt(o, 'style', ['long', 'short', 'narrow'], 'long'),
			numeric: opt(o, 'numeric', ['always', 'auto'], 'always'), numberingSystem: 'latn'}});
	}
	format(v, unit) {
		return this.formatToParts(v, unit).map((p) => p.value).join('');
	}
	formatToParts(v, unit) {
		v = Number(v);
		unit = String(unit).replace(/s$/, '');
		if (!RELUNITS.includes(unit) || !isFinite(v))
			throw new RangeError('Invalid unit argument for format() ' + unit);
		const r = this._r;
		if (r.numeric === 'auto') {
			const special = {day: {'-1': 'yesterday', 0: 'today', 1: 'tomorrow'},
				year: {'-1': 'last year', 0: 'this year', 1: 'next year'},
				month: {'-1': 'last month', 0: 'this month', 1: 'next month'},
				week: {'-1': 'last week', 0: 'this week', 1: 'next week'},
				quarter: {'-1': 'last quarter', 0: 'this quarter', 1: 'next quarter'},
				hour: {0: 'this hour'}, minute: {0: 'this minute'}, second: {0: 'now'}};
			const s = special[unit]?.[Object.is(v, -0) ? 0 : v];
			if (s)
				return [{type: 'literal', value: s}];
		}
		const a = Math.abs(v);
		const short = {year: 'yr.', quarter: 'qtr.', month: 'mo.', week: 'wk.', day: 'day', hour: 'hr.', minute: 'min.', second: 'sec.'};
		const name = r.style === 'long' ? (a === 1 ? unit : unit + 's') :
			short[unit] === 'day' ? (a === 1 ? 'day' : 'days') : a === 1 || unit === 'month' || unit === 'hour' || unit === 'minute' || unit === 'second' ? short[unit] : short[unit].replace('.', 's.');
		const num = new NumberFormat(r.locale).formatToParts(a).map((p) => ({...p, unit}));
		const past = v < 0 || Object.is(v, -0);
		return past ? [...num, {type: 'literal', value: ' ' + name + ' ago'}] :
			[{type: 'literal', value: 'in '}, ...num, {type: 'literal', value: ' ' + name}];
	}
	resolvedOptions() { return {...this._r}; }
	static supportedLocalesOf(l) { return supported(l); }
}
tag(RelativeTimeFormat, 'Intl.RelativeTimeFormat');

class ListFormat {
	constructor(l, o) {
		o = options(o);
		hidden(this, {_r: {locale: pick(l), type: opt(o, 'type', ['conjunction', 'disjunction', 'unit'], 'conjunction'),
			style: opt(o, 'style', ['long', 'short', 'narrow'], 'long')}});
	}
	format(list) {
		return this.formatToParts(list).map((p) => p.value).join('');
	}
	formatToParts(list) {
		const a = [];
		for (const s of list) {
			if (typeof s !== 'string')
				throw new TypeError('Iterable yielded ' + String(s) + ' which is not a string');
			a.push(s);
		}
		const r = this._r;
		const word = r.type === 'disjunction' ? 'or' : r.type === 'unit' ? '' : r.style === 'long' ? 'and' : '&';
		const P = [];
		a.forEach((s, k) => {
			if (k > 0) {
				const last = k === a.length - 1;
				let sep = r.type === 'unit' ? (r.style === 'narrow' ? ' ' : ', ') :
					last ? (a.length > 2 ? ', ' : ' ') + word + ' ' : ', ';
				P.push({type: 'literal', value: sep});
			}
			P.push({type: 'element', value: s});
		});
		return P;
	}
	resolvedOptions() { return {...this._r}; }
	static supportedLocalesOf(l) { return supported(l); }
}
tag(ListFormat, 'Intl.ListFormat');

// ---- collation, segmentation, names ----

function fold(s, sens, ignorePunctuation) {
	s = String(s);
	if (ignorePunctuation)
		s = s.replace(/[\p{P}\s]/gu, '');
	if (sens === 'base' || sens === 'accent')
		s = s.toLowerCase();
	if (sens === 'base' || sens === 'case')
		s = s.normalize('NFD').replace(/\p{M}/gu, '');
	return s;
}

class Collator {
	constructor(l, o) {
		o = options(o);
		const usage = opt(o, 'usage', ['sort', 'search'], 'sort');
		hidden(this, {_r: {locale: pick(l), usage, sensitivity: opt(o, 'sensitivity', ['base', 'accent', 'case', 'variant'], 'variant'),
			ignorePunctuation: !!o.ignorePunctuation, collation: 'default',
			numeric: !!o.numeric, caseFirst: opt(o, 'caseFirst', ['upper', 'lower', 'false'], 'false')}});
	}
	get compare() {
		const r = this._r;
		const f = (a, b) => {
			a = fold(a, r.sensitivity, r.ignorePunctuation);
			b = fold(b, r.sensitivity, r.ignorePunctuation);
			if (r.numeric) {
				const re = /(\d+)|(\D+)/g;
				const x = a.match(re) || [], y = b.match(re) || [];
				for (let k = 0; k < Math.min(x.length, y.length); k++) {
					if (/^\d/.test(x[k]) && /^\d/.test(y[k])) {
						const d = Number(x[k]) - Number(y[k]);
						if (d)
							return d < 0 ? -1 : 1;
					} else {
						const c = x[k].localeCompare(y[k]);
						if (c)
							return c;
					}
				}
				return x.length === y.length ? 0 : x.length < y.length ? -1 : 1;
			}
			return a.localeCompare(b);
		};
		defineProperty(this, 'compare', {value: f, configurable: true});
		return f;
	}
	resolvedOptions() { return {...this._r}; }
	static supportedLocalesOf(l) { return supported(l); }
}
tag(Collator, 'Intl.Collator');

class Segments {
	constructor(s, g) {
		hidden(this, {_s: s, _g: g});
	}
	_all() {
		const s = this._s, out = [];
		const re = this._g === 'word' ? /[\p{L}\p{N}_'’]+|\s+|./gsu :
			this._g === 'sentence' ? /[^.!?]*(?:[.!?]+|$)\s*/gsu :
			/\P{M}\p{M}*|\p{M}+/gsu;
		let m;
		while ((m = re.exec(s)) !== null && m[0] !== '') {
			const seg = {segment: m[0], index: m.index, input: s};
			if (this._g === 'word')
				seg.isWordLike = /[\p{L}\p{N}]/u.test(m[0]);
			out.push(seg);
		}
		return out;
	}
	containing(i = 0) {
		i = Math.trunc(Number(i)) || 0;
		return this._all().find((x) => i >= x.index && i < x.index + x.segment.length);
	}
	[Symbol.iterator]() {
		return this._all()[Symbol.iterator]();
	}
}

class Segmenter {
	constructor(l, o) {
		o = options(o);
		hidden(this, {_r: {locale: pick(l), granularity: opt(o, 'granularity', ['grapheme', 'word', 'sentence'], 'grapheme')}});
	}
	segment(s) { return new Segments(String(s), this._r.granularity); }
	resolvedOptions() { return {...this._r}; }
	static supportedLocalesOf(l) { return supported(l); }
}
tag(Segmenter, 'Intl.Segmenter');

const LANGNAMES = {en: 'English', de: 'German', fr: 'French', es: 'Spanish', it: 'Italian', pt: 'Portuguese',
	ja: 'Japanese', ko: 'Korean', zh: 'Chinese', ru: 'Russian', ar: 'Arabic', hi: 'Hindi', nl: 'Dutch',
	sv: 'Swedish', pl: 'Polish', tr: 'Turkish', th: 'Thai', he: 'Hebrew', el: 'Greek', uk: 'Ukrainian'};
const REGIONNAMES = {US: 'United States', GB: 'United Kingdom', DE: 'Germany', FR: 'France', JP: 'Japan',
	CN: 'China', IN: 'India', BR: 'Brazil', CA: 'Canada', AU: 'Australia', ES: 'Spain', IT: 'Italy',
	MX: 'Mexico', KR: 'South Korea', RU: 'Russia', TH: 'Thailand', NL: 'Netherlands', SE: 'Sweden'};

class DisplayNames {
	constructor(l, o) {
		o = options(o);
		const type = opt(o, 'type', ['language', 'region', 'script', 'currency', 'calendar', 'dateTimeField'], undefined);
		if (type === undefined)
			throw new TypeError('Required option "type" is missing');
		hidden(this, {_r: {locale: pick(l), style: opt(o, 'style', ['long', 'short', 'narrow'], 'long'), type,
			fallback: opt(o, 'fallback', ['code', 'none'], 'code')}});
	}
	of(code) {
		code = String(code);
		const r = this._r;
		const n = r.type === 'language' ? LANGNAMES[code] : r.type === 'region' ? REGIONNAMES[code] :
			r.type === 'currency' ? CURRENCYNAME[code] : undefined;
		return n !== undefined ? n : r.fallback === 'code' ? code : undefined;
	}
	resolvedOptions() { return {...this._r}; }
	static supportedLocalesOf(l) { return supported(l); }
}
tag(DisplayNames, 'Intl.DisplayNames');

// Collator, DateTimeFormat and NumberFormat may be called without new
function callable(C) {
	const F = {[C.name]: function (l, o) {
		return new.target ? Reflect.construct(C, [l, o], new.target) : new C(l, o);
	}}[C.name];
	defineProperty(F, 'prototype', {value: C.prototype});
	hidden(C.prototype, {constructor: F});
	hidden(F, {supportedLocalesOf: supported});
	return F;
}

const Intl = {};
hidden(Intl, {
	Collator: callable(Collator), DateTimeFormat: callable(DateTimeFormat), NumberFormat: callable(NumberFormat),
	DisplayNames, ListFormat, Locale, PluralRules,
	RelativeTimeFormat, Segmenter,
	getCanonicalLocales: canonlist,
	supportedValuesOf(k) {
		switch (String(k)) {
		case 'currency': return Object.keys(CURRENCY).sort();
		case 'unit': return Object.keys(UNITS).sort();
		case 'calendar': return ['gregory'];
		case 'collation': return ['default'];
		case 'numberingSystem': return ['latn'];
		case 'timeZone': return ['UTC'];
		default: throw new RangeError('Invalid key : ' + String(k));
		}
	},
});
defineProperty(Intl, Symbol.toStringTag, {value: 'Intl', configurable: true});
hidden(globalThis, {Intl});

// ---- the toLocale methods ----

const cache = new Map();
function cached(C, l, o) {
	if (o !== undefined)
		return new C(l, o);
	const k = C.name + '|' + String(l);
	let f = cache.get(k);
	if (!f) {
		f = new C(l);
		cache.set(k, f);
	}
	return f;
}

hidden(Number.prototype, {toLocaleString(l, o) {
	return cached(NumberFormat, l, o).format(Number.prototype.valueOf.call(this));
}});
hidden(BigInt.prototype, {toLocaleString(l, o) {
	return cached(NumberFormat, l, o).format(BigInt.prototype.valueOf.call(this));
}});
hidden(String.prototype, {localeCompare(that, l, o) {
	if (this === null || this === undefined)
		throw new TypeError('String.prototype.localeCompare called on null or undefined');
	const s = String(this), t = String(that);
	if (l === undefined && o === undefined)
		return s < t ? -1 : s > t ? 1 : 0;
	return cached(Collator, l, o).compare(s, t);
}});
const datestr = (defaults) => function (l, o) {
	const t = Date.prototype.getTime.call(this);
	if (t !== t)
		return 'Invalid Date';
	o = o === undefined ? defaults : Object.assign({}, o);
	if (o !== defaults && !DATEFIELDS.some((k) => o[k] !== undefined) && !o.dateStyle && !o.timeStyle)
		Object.assign(o, defaults);
	return new DateTimeFormat(l, o).format(t);
};
hidden(Date.prototype, {
	toLocaleString: datestr({year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: '2-digit', second: '2-digit'}),
	toLocaleDateString: datestr({year: 'numeric', month: 'numeric', day: 'numeric'}),
	toLocaleTimeString: datestr({hour: 'numeric', minute: '2-digit', second: '2-digit'}),
});
})
