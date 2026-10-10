// dom.js - a web page's DOM and window, over the natives of jsdom.b.
//
// The engine runs this when it makes a page's realm: it is a function
// given N, the natives, which name nodes by their index in the host's
// document; it fills the global object with the window's interfaces
// and returns the hooks the event loop calls (see jsdom.b).
//
// What is not here is not supported.  Known gaps: shadow DOM content is
// not shown; sessionStorage lasts as long as the page (localStorage and
// cookies persist, in the store and the web jar the host grants); layout
// queries are the host's boxes, not the CSSOM's; no canvas, media or
// workers.

(function (N) {
'use strict';

const G = globalThis;
const ENGINEGLOBALS = new Set(Reflect.ownKeys(G));	// the engine's own, and Intl's
const KEY = Symbol('internal');
const defineProperty = Object.defineProperty;
const W = [];			// wrappers by node index
const ELEMENT = 3, TEXT = 4, COMMENT = 5, DOCUMENT = 1, DOCTYPE = 2;
const HTMLNS = 'http://www.w3.org/1999/xhtml', SVGNS = 'http://www.w3.org/2000/svg',
	MATHNS = 'http://www.w3.org/1998/Math/MathML';
const NSURIS = [HTMLNS, SVGNS, MATHNS];

function hidden(o, props) {
	for (const k of Reflect.ownKeys(props))
		defineProperty(o, k, {value: props[k], writable: true, configurable: true, enumerable: false});
}

function globals(props) {
	hidden(G, props);
}

function str(v) {
	return String(v);
}

function lower(s) {
	return s.replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
}

function upper(s) {
	return s.replace(/[a-z]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 32));
}

function camel(s) {
	return s.replace(/-([a-z])/g, (m, c) => upper(c));
}

function kebab(s) {
	if (s === 'cssFloat')
		return 'float';
	const k = s.replace(/[A-Z]/g, (c) => '-' + lower(c));
	return /^(webkit|moz|ms)-/.test(k) ? '-' + k : k;
}

// ---- DOMException ----

const EXCODES = {IndexSizeError: 1, HierarchyRequestError: 3, WrongDocumentError: 4,
	InvalidCharacterError: 5, NoModificationAllowedError: 7, NotFoundError: 8,
	NotSupportedError: 9, InvalidStateError: 11, SyntaxError: 12, InvalidModificationError: 13,
	NamespaceError: 14, InvalidAccessError: 15, TypeMismatchError: 17, SecurityError: 18,
	NetworkError: 19, AbortError: 20, URLMismatchError: 21, QuotaExceededError: 22,
	TimeoutError: 23, InvalidNodeTypeError: 24, DataCloneError: 25};

class DOMException extends Error {
	constructor(message = '', name = 'Error') {
		super(str(message));
		defineProperty(this, 'name', {value: str(name), writable: true, configurable: true});
	}
	get code() {
		return EXCODES[this.name] || 0;
	}
}

function domerr(name, message) {
	return new DOMException(message, name);
}

// ---- events ----

const CANCELED = Symbol('canceled'), STOP = Symbol('stop'), STOPNOW = Symbol('stopnow'),
	DISPATCHING = Symbol('dispatching'), PASSIVE = Symbol('passive');

class Event {
	constructor(type, init = {}) {
		if (arguments.length === 0)
			throw new TypeError("Failed to construct 'Event': 1 argument required");
		hidden(this, {[CANCELED]: false, [STOP]: false, [STOPNOW]: false, [DISPATCHING]: false, [PASSIVE]: false});
		defineProperty(this, 'isTrusted', {value: false, enumerable: true, configurable: true});
		hidden(this, {_type: str(type), _bubbles: !!init.bubbles, _cancelable: !!init.cancelable,
			_composed: !!init.composed, _target: null, _current: null, _phase: 0, _time: N.now(), _path: null});
	}
	get type() { return this._type; }
	get bubbles() { return this._bubbles; }
	get cancelable() { return this._cancelable; }
	get composed() { return this._composed; }
	get target() { return this._target; }
	get srcElement() { return this._target; }
	get currentTarget() { return this._current; }
	get eventPhase() { return this._phase; }
	get timeStamp() { return this._time; }
	get defaultPrevented() { return this[CANCELED]; }
	get returnValue() { return !this[CANCELED]; }
	set returnValue(v) { if (!v) this.preventDefault(); }
	get cancelBubble() { return this[STOP]; }
	set cancelBubble(v) { if (v) this[STOP] = true; }
	preventDefault() {
		if (this._cancelable && !this[PASSIVE])
			this[CANCELED] = true;
	}
	stopPropagation() { this[STOP] = true; }
	stopImmediatePropagation() { this[STOP] = true; this[STOPNOW] = true; }
	composedPath() {
		return this._path ? this._path.slice() : [];
	}
	initEvent(type, bubbles = false, cancelable = false) {
		if (this[DISPATCHING])
			return;
		this._type = str(type);
		this._bubbles = !!bubbles;
		this._cancelable = !!cancelable;
		this[CANCELED] = false;
	}
}
hidden(Event, {NONE: 0, CAPTURING_PHASE: 1, AT_TARGET: 2, BUBBLING_PHASE: 3});
hidden(Event.prototype, {NONE: 0, CAPTURING_PHASE: 1, AT_TARGET: 2, BUBBLING_PHASE: 3});

function evclass(name, parent, fields) {
	const C = class extends parent {
		constructor(type, init = {}) {
			super(type, init);
			for (const k in fields) {
				const v = init[k] !== undefined ? init[k] : fields[k];
				defineProperty(this, k, {value: v, enumerable: true, configurable: true});
			}
		}
	};
	defineProperty(C, 'name', {value: name});
	return C;
}

const UIEvent = evclass('UIEvent', Event, {view: null, detail: 0});
const MOUSE = {screenX: 0, screenY: 0, clientX: 0, clientY: 0, pageX: 0, pageY: 0, offsetX: 0, offsetY: 0,
	x: 0, y: 0, ctrlKey: false, shiftKey: false, altKey: false, metaKey: false, button: 0, buttons: 0,
	relatedTarget: null, movementX: 0, movementY: 0};
const MouseEvent = evclass('MouseEvent', UIEvent, MOUSE);
hidden(MouseEvent.prototype, {getModifierState() { return false; }});
const PointerEvent = evclass('PointerEvent', MouseEvent, {pointerId: 1, width: 1, height: 1, pressure: 0,
	tiltX: 0, tiltY: 0, pointerType: 'mouse', isPrimary: true});
const WheelEvent = evclass('WheelEvent', MouseEvent, {deltaX: 0, deltaY: 0, deltaZ: 0, deltaMode: 0});
const KeyboardEvent = evclass('KeyboardEvent', UIEvent, {key: '', code: '', location: 0, ctrlKey: false,
	shiftKey: false, altKey: false, metaKey: false, repeat: false, isComposing: false, charCode: 0,
	keyCode: 0, which: 0});
hidden(KeyboardEvent.prototype, {getModifierState() { return false; }});
const FocusEvent = evclass('FocusEvent', UIEvent, {relatedTarget: null});
const InputEvent = evclass('InputEvent', UIEvent, {data: null, inputType: '', isComposing: false});
const CompositionEvent = evclass('CompositionEvent', UIEvent, {data: ''});
const TouchEvent = evclass('TouchEvent', UIEvent, {touches: [], targetTouches: [], changedTouches: []});
const CustomEvent = evclass('CustomEvent', Event, {detail: null});
hidden(CustomEvent.prototype, {initCustomEvent(type, b, c, d) { this.initEvent(type, b, c); defineProperty(this, 'detail', {value: d}); }});
const ErrorEvent = evclass('ErrorEvent', Event, {message: '', filename: '', lineno: 0, colno: 0, error: undefined});
const MessageEvent = evclass('MessageEvent', Event, {data: null, origin: '', lastEventId: '', source: null, ports: []});
const PageTransitionEvent = evclass('PageTransitionEvent', Event, {persisted: false});
const PopStateEvent = evclass('PopStateEvent', Event, {state: null});
const HashChangeEvent = evclass('HashChangeEvent', Event, {oldURL: '', newURL: ''});
const ProgressEvent = evclass('ProgressEvent', Event, {lengthComputable: false, loaded: 0, total: 0});
const SubmitEvent = evclass('SubmitEvent', Event, {submitter: null});
const AnimationEvent = evclass('AnimationEvent', Event, {animationName: '', elapsedTime: 0, pseudoElement: ''});
const TransitionEvent = evclass('TransitionEvent', Event, {propertyName: '', elapsedTime: 0, pseudoElement: ''});
const StorageEvent = evclass('StorageEvent', Event, {key: null, oldValue: null, newValue: null, url: '', storageArea: null});
const PromiseRejectionEvent = evclass('PromiseRejectionEvent', Event, {promise: null, reason: undefined});
const BeforeUnloadEvent = evclass('BeforeUnloadEvent', Event, {});
const SecurityPolicyViolationEvent = evclass('SecurityPolicyViolationEvent', Event, {});

function trusted(ev) {
	defineProperty(ev, 'isTrusted', {value: true, enumerable: true});
	return ev;
}

// a key for each callback, captured or not: a list of listeners knows
// whether it has one with a Set, not a walk
const CAPKEYS = new WeakMap(), BUBKEYS = new WeakMap();

// listeners: target -> Map(type -> [{callback, capture, once, passive}])
const LISTENERS = new WeakMap();
// handler properties (onclick ...): target -> Map(type -> function)
const HANDLERS = new WeakMap();

function listenopts(o) {
	if (typeof o === 'boolean' || o === undefined || o === null)
		return {capture: !!o, once: false, passive: false, signal: null};
	return {capture: !!o.capture, once: !!o.once, passive: !!o.passive, signal: o.signal || null};
}

class EventTarget {
	constructor() {
	}
	addEventListener(type, callback, options) {
		if (callback === null || callback === undefined)
			return;
		const o = listenopts(options);
		if (o.signal && o.signal.aborted)
			return;
		const t = this === undefined || this === null ? G : this;
		let m = LISTENERS.get(t);
		if (!m)
			LISTENERS.set(t, m = new Map());
		type = str(type);
		let l = m.get(type);
		if (!l) {
			m.set(type, l = []);
			hidden(l, {_has: new Set()});	// callbacks by capture: [false-set, true-set] as one Set of pairs' keys
		}
		const key = o.capture ? CAPKEYS : BUBKEYS;
		let ks = key.get(callback);
		if (ks === undefined)
			key.set(callback, ks = {});
		if (l._has.has(ks))
			return;
		l._has.add(ks);
		const ent = {callback, capture: o.capture, once: o.once, passive: o.passive, removed: false, key: ks};
		l.push(ent);
		if (o.signal)
			o.signal.addEventListener('abort', () => t.removeEventListener(type, callback, o.capture));
	}
	removeEventListener(type, callback, options) {
		const t = this === undefined || this === null ? G : this;
		const m = LISTENERS.get(t);
		if (!m)
			return;
		const capture = listenopts(options).capture;
		const l = m.get(str(type));
		if (!l)
			return;
		const ks = (capture ? CAPKEYS : BUBKEYS).get(callback);
		if (ks === undefined || !l._has.has(ks))
			return;
		l._has.delete(ks);
		for (let i = 0; i < l.length; i++)
			if (l[i].key === ks) {
				l[i].removed = true;
				l.splice(i, 1);
				return;
			}
	}
	dispatchEvent(ev) {
		if (!(ev instanceof Event))
			throw new TypeError("Failed to execute 'dispatchEvent': parameter 1 is not of type 'Event'");
		if (ev[DISPATCHING])
			throw domerr('InvalidStateError', 'the event is already being dispatched');
		return dispatch(this === undefined || this === null ? G : this, ev);
	}
}

let currentEvent;

// The event's path (DOM §2.9): up the parents, but a node a slot has
// takes that slot's place in its host's shadow tree, and a shadow root
// is followed by its host unless the event is not composed and began in
// that tree.
function eventpath(target, ev) {
	const path = [target];
	if (isnode(target)) {
		const top = treeroot(idof(target));
		for (let n = target; ;) {
			const p = eventparent(n, ev, top);
			if (!p)
				break;
			path.push(p);
			n = p;
		}
		if (path[path.length - 1] === document)
			path.push(G);
	}
	return path;
}

function eventparent(n, ev, top) {
	if (n instanceof ShadowRoot)
		return !ev._composed && idof(n) === top ? null : n._host;
	const i = idof(n);
	const p = N.parent(i);
	if (!p)
		return null;
	const ph = W[p];
	if (ph && ph._shadowroot) {
		const slot = assignedslot(i, ph._shadowroot);
		if (slot)
			return slot;
	}
	return wrap(p);
}

// the root of node i's tree: the document, a shadow root, or another fragment
function treeroot(i) {
	while (N.parent(i))
		i = N.parent(i);
	return i;
}

// the slot in shadow root sr that node i (a child of sr's host) is
// assigned to: the first slot with the name its slot attribute gives
function assignedslot(i, sr) {
	const k = N.kind(i);
	if (k !== ELEMENT && k !== TEXT)
		return null;
	const name = k === ELEMENT ? (N.attr(i, 'slot') || '') : '';
	for (const s of N.descendants(idof(sr), 'name', 'slot'))
		if ((N.attr(s, 'name') || '') === name)
			return wrap(s);
	return null;
}

// what a listener at t sees as the target: a in its tree, or the host of
// the shadow tree a is in that t is outside of, and so on out (retargeting)
function retarget(a, t) {
	for (;;) {
		if (!isnode(a))
			return a;
		const r = W[treeroot(idof(a))];
		if (!(r instanceof ShadowRoot))
			return a;
		if (isnode(t) && inclusiveshadow(r, t))
			return a;
		a = r._host;
	}
}

// whether root r is t's tree's root, or one its host is in, out to the document
function inclusiveshadow(r, t) {
	for (let x = W[treeroot(idof(t))]; x; ) {
		if (x === r)
			return true;
		if (!(x instanceof ShadowRoot))
			return false;
		x = W[treeroot(idof(x._host))];
	}
	return false;
}

function invoke(t, ev, phase) {
	ev._current = t;
	const m = LISTENERS.get(t);
	const l = m && m.get(ev._type);
	if (l && l.length) {
		for (const e of l.slice()) {
			if (e.removed)
				continue;
			if (phase === 1 && !e.capture || phase === 3 && e.capture)
				continue;
			if (e.once)
				t.removeEventListener(ev._type, e.callback, e.capture);
			ev[PASSIVE] = e.passive;
			try {
				if (typeof e.callback === 'function')
					e.callback.call(t, ev);
				else if (e.callback && typeof e.callback.handleEvent === 'function')
					e.callback.handleEvent(ev);
			} catch (x) {
				report(x);
			}
			ev[PASSIVE] = false;
			if (ev[STOPNOW])
				return;
		}
	}
	if (phase !== 1) {
		const hm = HANDLERS.get(t);
		const h = hm && hm.has(ev._type) ? hm.get(ev._type) : attrhandler(t, ev._type);
		if (typeof h === 'function') {
			try {
				let r;
				if (ev._type === 'error' && t === G && ev instanceof ErrorEvent)
					r = h.call(t, ev.message, ev.filename, ev.lineno, ev.colno, ev.error);
				else
					r = h.call(t, ev);
				if (r === false || ev._type === 'error' && t === G && r === true)
					ev.preventDefault();
			} catch (x) {
				report(x);
			}
		}
	}
}

function dispatch(target, ev) {
	ev[DISPATCHING] = true;
	ev._target = target;
	const path = eventpath(target, ev);
	ev._path = path;
	// a host is at the target phase for an event from inside its shadow tree
	const attarget = path.map((t) => t === target || retarget(target, t) === t);
	const saved = currentEvent;
	currentEvent = ev;
	try {
		for (let k = path.length - 1; k > 0 && !ev[STOP]; k--) {
			ev._target = retarget(target, path[k]);
			ev._phase = attarget[k] ? 2 : 1;
			invoke(path[k], ev, 1);	// (capturing listeners, even at a host)
		}
		if (!ev[STOP]) {
			ev._target = target;
			ev._phase = 2;
			invoke(target, ev, 2);
		}
		for (let k = 1; k < path.length && !ev[STOP]; k++) {
			if (!ev._bubbles && !attarget[k])
				continue;
			ev._target = retarget(target, path[k]);
			ev._phase = attarget[k] ? 2 : 3;
			invoke(path[k], ev, 3);
		}
	} finally {
		currentEvent = saved;
		ev._phase = 0;
		ev._current = null;
		ev[DISPATCHING] = false;
		ev._target = retarget(target, document);
	}
	return !ev[CANCELED];
}

function fire(target, type, init, C = Event) {
	const ev = trusted(new C(type, init || {}));
	return dispatch(target, ev);
}

// on<type> properties, on a prototype; an attribute of the same name sets one too
const EVENTNAMES = ['abort', 'animationend', 'animationiteration', 'animationstart', 'auxclick',
	'beforeinput', 'blur', 'cancel', 'change', 'click', 'close', 'contextmenu', 'copy', 'cut', 'dblclick',
	'drag', 'dragend', 'dragenter', 'dragleave', 'dragover', 'dragstart', 'drop', 'error', 'focus',
	'focusin', 'focusout', 'input', 'invalid', 'keydown', 'keypress', 'keyup', 'load', 'loadeddata',
	'loadedmetadata', 'loadstart', 'mousedown', 'mouseenter', 'mouseleave', 'mousemove', 'mouseout',
	'mouseover', 'mouseup', 'paste', 'pause', 'play', 'playing', 'pointercancel', 'pointerdown',
	'pointerenter', 'pointerleave', 'pointermove', 'pointerout', 'pointerover', 'pointerup', 'progress',
	'reset', 'resize', 'scroll', 'scrollend', 'select', 'selectionchange', 'submit', 'toggle',
	'touchcancel', 'touchend', 'touchmove', 'touchstart', 'transitionend', 'wheel'];
const WINDOWEVENTS = ['afterprint', 'beforeprint', 'beforeunload', 'hashchange', 'languagechange',
	'message', 'messageerror', 'offline', 'online', 'pagehide', 'pageshow', 'popstate',
	'rejectionhandled', 'storage', 'unhandledrejection', 'unload', 'DOMContentLoaded'];

function handlerprops(proto, names) {
	for (const t of names) {
		defineProperty(proto, 'on' + lower(t), {
			configurable: true, enumerable: true,
			get() {
				const m = HANDLERS.get(this);
				const h = m && m.has(t) ? m.get(t) : attrhandler(this, t);
				return h === undefined ? null : h;
			},
			set(f) {
				let m = HANDLERS.get(this);
				if (!m)
					HANDLERS.set(this, m = new Map());
				m.set(t, typeof f === 'function' ? f : null);
			}
		});
	}
}

// an inline handler's source made a function, scoped as a browser scopes it
function inlinehandler(el, name, src) {
	try {
		const form = el instanceof Element ? el.closest('form') : null;
		const f = new Function('document', 'form', 'element', 'event',
			'with (document) with (form || {}) with (element) return function (event) {\n' + src + '\n};');
		return f(document, form, el);
	} catch (x) {
		report(x);
		return null;
	}
}

// ---- nodes ----
//
// A node's wrapper is made when script first sees it and kept, so the
// same node is always the same object.

let idof, isnode;
let document;

class Node extends EventTarget {
	#i;
	constructor(key, i) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		super();
		this.#i = i;
	}
	static {
		idof = (n) => n.#i;
		isnode = (n) => typeof n === 'object' && n !== null && #i in n;
	}
	get nodeType() {
		switch (N.kind(this.#i)) {
		case ELEMENT: return 1;
		case TEXT: return 3;
		case COMMENT: return 8;
		case DOCTYPE: return 10;
		default: return this.#i === 1 ? 9 : 11;
		}
	}
	get nodeName() {
		const i = this.#i;
		switch (N.kind(i)) {
		case ELEMENT: return tagname(i);
		case TEXT: return '#text';
		case COMMENT: return '#comment';
		case DOCTYPE: return N.name(i);
		default: return i === 1 ? '#document' : '#document-fragment';
		}
	}
	get nodeValue() {
		const k = N.kind(this.#i);
		return k === TEXT || k === COMMENT ? N.data(this.#i) : null;
	}
	set nodeValue(v) {
		const k = N.kind(this.#i);
		if (k === TEXT || k === COMMENT)
			setdata(this.#i, v === null ? '' : str(v));
	}
	get parentNode() { return wrap(N.parent(this.#i)); }
	get parentElement() {
		const p = N.parent(this.#i);
		return p && N.kind(p) === ELEMENT ? wrap(p) : null;
	}
	get firstChild() { return wrap(N.first(this.#i)); }
	get lastChild() { return wrap(N.last(this.#i)); }
	get nextSibling() { return wrap(N.next(this.#i)); }
	get previousSibling() { return wrap(N.prev(this.#i)); }
	get childNodes() { return new NodeList(KEY, N.children(this.#i, false).map(wrap)); }
	get ownerDocument() { return this.#i === 1 ? null : document; }
	get isConnected() { return connected(this.#i); }
	get baseURI() { return baseurl(); }
	hasChildNodes() { return N.first(this.#i) !== 0; }
	getRootNode() {
		let i = this.#i;
		for (let p = N.parent(i); p; p = N.parent(p))
			i = p;
		return wrap(i);
	}
	contains(other) {
		if (other === null || other === undefined)
			return false;
		const o = idof(other);
		for (let p = o; p; p = N.parent(p))
			if (p === this.#i)
				return true;
		return false;
	}
	isSameNode(other) { return this === other; }
	isEqualNode(other) {
		if (!isnode(other))
			return false;
		const a = this.#i, b = idof(other);
		if (N.kind(a) !== N.kind(b) || N.name(a) !== N.name(b) || N.data(a) !== N.data(b))
			return false;
		const aa = N.attrs(a), ba = N.attrs(b);
		if (aa.length !== ba.length)
			return false;
		for (let k = 0; k < aa.length; k += 2)
			if (N.attr(b, aa[k]) !== aa[k + 1])
				return false;
		const ac = N.children(a, false), bc = N.children(b, false);
		if (ac.length !== bc.length)
			return false;
		for (let k = 0; k < ac.length; k++)
			if (!wrap(ac[k]).isEqualNode(wrap(bc[k])))
				return false;
		return true;
	}
	compareDocumentPosition(other) {
		const a = this.#i, b = idof(other);
		if (a === b)
			return 0;
		const pa = ancestry(a), pb = ancestry(b);
		if (pa[0] !== pb[0])
			return 1 | 32 | (a < b ? 4 : 2);
		let k = 0;
		while (k < pa.length && k < pb.length && pa[k] === pb[k])
			k++;
		if (k === pa.length)
			return 16 | 4;		// other is a descendant
		if (k === pb.length)
			return 8 | 2;		// other is an ancestor
		for (let s = N.next(pa[k]); s; s = N.next(s))
			if (s === pb[k])
				return 4;
		return 2;
	}
	get textContent() {
		const i = this.#i, k = N.kind(i);
		if (k === TEXT || k === COMMENT)
			return N.data(i);
		if (k === DOCTYPE || i === 1)
			return null;
		return N.textof(i);
	}
	set textContent(v) {
		const i = this.#i, k = N.kind(i);
		v = v === null || v === undefined ? '' : str(v);
		if (k === TEXT || k === COMMENT) {
			setdata(i, v);
			return;
		}
		if (k === DOCTYPE || i === 1)
			return;
		replaceall(i, v === '' ? [] : [N.create(TEXT, '#text', 0)]);
		const t = N.first(i);
		if (t)
			N.setdata(t, v);
	}
	appendChild(child) {
		return insertnode(this.#i, child, 0);
	}
	insertBefore(child, ref) {
		return insertnode(this.#i, child, ref === null || ref === undefined ? 0 : refid(this.#i, ref));
	}
	removeChild(child) {
		const c = nodeid(child);
		if (N.parent(c) !== this.#i)
			throw domerr('NotFoundError', "The node to be removed is not a child of this node.");
		removenode(c);
		return child;
	}
	replaceChild(child, old) {
		const o = nodeid(old);
		if (N.parent(o) !== this.#i)
			throw domerr('NotFoundError', "The node to be replaced is not a child of this node.");
		if (child === old)
			return old;
		const next = N.next(o);
		removenode(o);
		insertnode(this.#i, child, next);
		return old;
	}
	cloneNode(deep = false) {
		return wrap(clone(this.#i, !!deep));
	}
	normalize() {
		const i = this.#i;
		for (let c = N.first(i); c; ) {
			const next = N.next(c);
			if (N.kind(c) === TEXT) {
				if (N.data(c) === '') {
					removenode(c);
				} else {
					let n = next;
					while (n && N.kind(n) === TEXT) {
						const nn = N.next(n);
						setdata(c, N.data(c) + N.data(n));
						removenode(n);
						n = nn;
					}
					c = n;
					continue;
				}
			} else if (N.kind(c) === ELEMENT)
				wrap(c).normalize();
			c = next;
		}
	}
	lookupNamespaceURI(prefix) { return prefix ? null : HTMLNS; }
	lookupPrefix() { return null; }
	isDefaultNamespace(ns) { return ns === HTMLNS; }
}
const NODECONSTS = {ELEMENT_NODE: 1, ATTRIBUTE_NODE: 2, TEXT_NODE: 3, CDATA_SECTION_NODE: 4,
	PROCESSING_INSTRUCTION_NODE: 7, COMMENT_NODE: 8, DOCUMENT_NODE: 9, DOCUMENT_TYPE_NODE: 10,
	DOCUMENT_FRAGMENT_NODE: 11, DOCUMENT_POSITION_DISCONNECTED: 1, DOCUMENT_POSITION_PRECEDING: 2,
	DOCUMENT_POSITION_FOLLOWING: 4, DOCUMENT_POSITION_CONTAINS: 8, DOCUMENT_POSITION_CONTAINED_BY: 16,
	DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC: 32};
for (const k in NODECONSTS) {
	defineProperty(Node, k, {value: NODECONSTS[k], enumerable: true});
	defineProperty(Node.prototype, k, {value: NODECONSTS[k], enumerable: true});
}

function ancestry(i) {
	const a = [];
	for (let p = i; p; p = N.parent(p))
		a.unshift(p);
	return a;
}

function nodeid(n) {
	if (!isnode(n))
		throw new TypeError("parameter is not of type 'Node'");
	return idof(n);
}

function refid(parent, ref) {
	const r = nodeid(ref);
	if (N.parent(r) !== parent)
		throw domerr('NotFoundError', "The node before which the new node is to be inserted is not a child of this node.");
	return r;
}

function connected(i) {
	for (let p = i; p; p = N.parent(p))
		if (p === 1)
			return true;
	return false;
}

function tagname(i) {
	const n = N.name(i);
	return N.ns(i) === 0 ? upper(n) : n;
}

function isfragment(i) {
	return N.kind(i) === DOCUMENT && i !== 1;
}

// ---- changing the tree ----
//
// Every change goes through here, so that mutation observers, scripts
// and custom elements hear of it.

function insertnode(parent, child, before) {
	const c = nodeid(child);
	const pk = N.kind(parent);
	if (pk !== ELEMENT && pk !== DOCUMENT)
		throw domerr('HierarchyRequestError', 'This node type does not support children.');
	for (let p = parent; p; p = N.parent(p))
		if (p === c)
			throw domerr('HierarchyRequestError', 'The new child element contains the parent.');
	if (c === 1 || N.kind(c) === DOCTYPE && parent !== 1)
		throw domerr('HierarchyRequestError', 'Nodes of this type may not be inserted here.');
	if (before === c)
		before = N.next(c);
	let nodes;
	if (isfragment(c)) {
		nodes = N.children(c, false);
		for (const n of nodes)
			N.remove(n);
		if (nodes.length)
			mutated(c, 'childList', {removed: nodes});
	} else {
		const old = N.parent(c);
		if (old) {
			const prev = N.prev(c), next = N.next(c);
			N.remove(c);
			mutated(old, 'childList', {removed: [c], prev, next});
		}
		nodes = [c];
	}
	for (const n of nodes)
		N.insert(parent, n, before);
	if (nodes.length) {
		mutated(parent, 'childList', {added: nodes, prev: N.prev(nodes[0]), next: before});
		if (connected(parent))
			for (const n of nodes)
				inserted(n);
	}
	return child;
}

function removenode(c) {
	const p = N.parent(c);
	if (!p)
		return;
	const was = connected(c);
	const prev = N.prev(c), next = N.next(c);
	N.remove(c);
	mutated(p, 'childList', {removed: [c], prev, next});
	if (was)
		removed(c);
}

function replaceall(parent, nodes) {
	const old = N.children(parent, false);
	const was = connected(parent);
	for (const c of old)
		N.remove(c);
	for (const n of nodes)
		N.insert(parent, n, 0);
	if (old.length || nodes.length)
		mutated(parent, 'childList', {removed: old, added: nodes});
	if (was) {
		for (const c of old)
			removed(c);
		for (const n of nodes)
			inserted(n);
	}
}

function setdata(i, v) {
	const old = N.data(i);
	N.setdata(i, v);
	mutated(i, 'characterData', {old});
}

function setattr(i, name, v) {
	const old = N.attr(i, name);
	N.setattr(i, name, v);
	mutated(i, 'attributes', {name, old});
	attrchanged(i, name, old, v);
}

function delattr(i, name) {
	const old = N.attr(i, name);
	if (old === null)
		return;
	N.delattr(i, name);
	mutated(i, 'attributes', {name, old});
	attrchanged(i, name, old, null);
}

function clone(i, deep) {
	const k = N.kind(i);
	const c = N.create(k, N.name(i), N.ns(i));
	if (k === TEXT || k === COMMENT)
		N.setdata(c, N.data(i));
	const a = N.attrs(i);
	for (let x = 0; x < a.length; x += 2)
		N.setattr(c, a[x], a[x + 1]);
	if (deep)
		for (let ch = N.first(i); ch; ch = N.next(ch))
			N.insert(c, clone(ch, true), 0);
	return c;
}

// a node and what it holds have come into the document
function inserted(n) {
	if (N.kind(n) !== ELEMENT && !isfragment(n))
		return;
	const els = N.kind(n) === ELEMENT ? [n] : [];
	for (const e of N.descendants(n, 'name', '*'))
		els.push(e);
	for (const e of els) {
		const name = N.name(e);
		if (name === 'script' && N.ns(e) === 0)
			scriptinserted(e);
		else if (name.indexOf('-') > 0) {
			const w = wrap(e);
			if (typeof w.connectedCallback === 'function')
				try { w.connectedCallback(); } catch (x) { report(x); }
		}
	}
}

function removed(n) {
	if (N.kind(n) !== ELEMENT)
		return;
	const els = [n, ...N.descendants(n, 'name', '*')];
	for (const e of els)
		if (W[e] && N.name(e).indexOf('-') > 0 && typeof W[e].disconnectedCallback === 'function')
			try { W[e].disconnectedCallback(); } catch (x) { report(x); }
	if (focused && (focused === n || els.includes(focused)))
		focused = 0;
}

// ---- mutation observers ----

const OBSERVERS = [];		// {observer, target (index), options}
let mopending = false;

class MutationRecord {
	constructor(key, f) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		Object.assign(this, f);
	}
}

function mutated(i, type, f) {
	if (OBSERVERS.length === 0)
		return;
	let rec = null;
	for (let p = i; p; p = N.parent(p)) {
		for (const o of OBSERVERS) {
			if (o.target !== p || p !== i && !o.options.subtree)
				continue;
			const opt = o.options;
			if (type === 'attributes' && (!opt.attributes || opt.attributeFilter && !opt.attributeFilter.includes(f.name)))
				continue;
			if (type === 'characterData' && !opt.characterData)
				continue;
			if (type === 'childList' && !opt.childList)
				continue;
			if (!rec)
				rec = {type, target: wrap(i), addedNodes: new NodeList(KEY, (f.added || []).map(wrap)),
					removedNodes: new NodeList(KEY, (f.removed || []).map(wrap)),
					previousSibling: wrap(f.prev || 0), nextSibling: wrap(f.next || 0),
					attributeName: type === 'attributes' ? f.name : null, attributeNamespace: null,
					oldValue: null};
			const r = new MutationRecord(KEY, rec);
			if (type === 'attributes' && opt.attributeOldValue || type === 'characterData' && opt.characterDataOldValue)
				r.oldValue = f.old;
			o.observer._records.push(r);
			if (!mopending) {
				mopending = true;
				queueMicrotask(deliver);
			}
		}
	}
}

function deliver() {
	mopending = false;
	const seen = new Set();
	for (const o of OBSERVERS.slice()) {
		const mo = o.observer;
		if (seen.has(mo))
			continue;
		seen.add(mo);
		if (mo._records.length === 0)
			continue;
		const recs = mo._records;
		mo._records = [];
		try { mo._callback.call(mo, recs, mo); } catch (x) { report(x); }
	}
}

class MutationObserver {
	constructor(callback) {
		if (typeof callback !== 'function')
			throw new TypeError("Failed to construct 'MutationObserver': parameter 1 is not of type 'Function'.");
		hidden(this, {_callback: callback, _records: []});
	}
	observe(target, options = {}) {
		const t = nodeid(target);
		const o = Object.assign({}, options);
		if (o.attributeOldValue || o.attributeFilter)
			o.attributes = o.attributes === undefined ? true : o.attributes;
		if (o.characterDataOldValue)
			o.characterData = o.characterData === undefined ? true : o.characterData;
		if (!o.childList && !o.attributes && !o.characterData)
			throw new TypeError("Failed to execute 'observe' on 'MutationObserver': The options object must set at least one of 'attributes', 'characterData', or 'childList' to true.");
		for (const e of OBSERVERS)
			if (e.observer === this && e.target === t) {
				e.options = o;
				return;
			}
		OBSERVERS.push({observer: this, target: t, options: o});
	}
	disconnect() {
		for (let k = OBSERVERS.length - 1; k >= 0; k--)
			if (OBSERVERS[k].observer === this)
				OBSERVERS.splice(k, 1);
		this._records = [];
	}
	takeRecords() {
		const r = this._records;
		this._records = [];
		return r;
	}
}

// ---- collections ----

class NodeList {
	constructor(key, items) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		for (let k = 0; k < items.length; k++)
			defineProperty(this, k, {value: items[k], enumerable: true});
		hidden(this, {_n: items.length});
	}
	get length() { return this._n; }
	item(k) { k = k >>> 0; return k < this._n ? this[k] : null; }
	forEach(f, self) { for (let k = 0; k < this._n; k++) f.call(self, this[k], k, this); }
	*entries() { for (let k = 0; k < this._n; k++) yield [k, this[k]]; }
	*keys() { for (let k = 0; k < this._n; k++) yield k; }
	*values() { for (let k = 0; k < this._n; k++) yield this[k]; }
	[Symbol.iterator]() { return this.values(); }
}

class HTMLCollection {
	constructor(key, items) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		for (let k = 0; k < items.length; k++)
			defineProperty(this, k, {value: items[k], enumerable: true});
		hidden(this, {_n: items.length});
	}
	get length() { return this._n; }
	item(k) { k = k >>> 0; return k < this._n ? this[k] : null; }
	namedItem(name) {
		for (let k = 0; k < this._n; k++)
			if (this[k].id === name || this[k].getAttribute('name') === name)
				return this[k];
		return null;
	}
	*[Symbol.iterator]() { for (let k = 0; k < this._n; k++) yield this[k]; }
}

function collection(ids) {
	return new HTMLCollection(KEY, ids.map(wrap));
}

class DOMTokenList {
	constructor(key, el, attr) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		hidden(this, {_el: el, _attr: attr, _n: 0});
		this._fill();
	}
	_tokens() {
		const v = N.attr(this._el, this._attr);
		if (!v)
			return [];
		const t = [];
		for (const s of v.split(/[ \t\n\f\r]+/))
			if (s && !t.includes(s))
				t.push(s);
		return t;
	}
	_fill() {
		for (let k = 0; k < this._n; k++)
			delete this[k];
		const t = this._tokens();
		for (let k = 0; k < t.length; k++)
			defineProperty(this, k, {value: t[k], enumerable: true, configurable: true});
		this._n = t.length;
		return t;
	}
	_set(t) {
		setattr(this._el, this._attr, t.join(' '));
		this._fill();
	}
	get length() { return this._fill().length; }
	get value() { return N.attr(this._el, this._attr) || ''; }
	set value(v) { setattr(this._el, this._attr, str(v)); this._fill(); }
	item(k) { const t = this._fill(); k = k >>> 0; return k < t.length ? t[k] : null; }
	contains(s) { return this._tokens().includes(str(s)); }
	add(...ss) {
		const t = this._tokens();
		for (let s of ss) {
			s = token(s);
			if (!t.includes(s))
				t.push(s);
		}
		this._set(t);
	}
	remove(...ss) {
		let t = this._tokens();
		for (let s of ss) {
			s = token(s);
			t = t.filter((x) => x !== s);
		}
		this._set(t);
	}
	toggle(s, force) {
		s = token(s);
		const t = this._tokens();
		const has = t.includes(s);
		if (has && force !== true) {
			this._set(t.filter((x) => x !== s));
			return false;
		}
		if (!has && force !== false) {
			t.push(s);
			this._set(t);
			return true;
		}
		return has;
	}
	replace(a, b) {
		a = token(a);
		b = token(b);
		const t = this._tokens();
		const k = t.indexOf(a);
		if (k < 0)
			return false;
		t[k] = b;
		this._set(t.filter((x, j) => t.indexOf(x) === j));
		return true;
	}
	supports() { return true; }
	forEach(f, self) { this._tokens().forEach((v, k) => f.call(self, v, k, this)); }
	entries() { return this._tokens().entries(); }
	keys() { return this._tokens().keys(); }
	values() { return this._tokens().values(); }
	[Symbol.iterator]() { return this._tokens().values(); }
	toString() { return this.value; }
}

function token(s) {
	s = str(s);
	if (s === '')
		throw domerr('SyntaxError', 'The token provided must not be empty.');
	if (/[ \t\n\f\r]/.test(s))
		throw domerr('InvalidCharacterError', "The token provided ('" + s + "') contains HTML space characters, which are not valid in tokens.");
	return s;
}

class Attr extends Node {
}

class AttrNode {
	constructor(key, el, name) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		hidden(this, {_el: el, _name: name});
	}
	get name() { return this._name; }
	get localName() { return this._name; }
	get nodeName() { return this._name; }
	get namespaceURI() { return null; }
	get prefix() { return null; }
	get specified() { return true; }
	get nodeType() { return 2; }
	get ownerElement() { return wrap(this._el); }
	get value() { const v = N.attr(this._el, this._name); return v === null ? '' : v; }
	set value(v) { setattr(this._el, this._name, str(v)); }
	get nodeValue() { return this.value; }
	get textContent() { return this.value; }
}
Object.setPrototypeOf(AttrNode.prototype, Attr.prototype);

class NamedNodeMap {
	constructor(key, el) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		const a = N.attrs(el);
		for (let k = 0; k < a.length; k += 2)
			defineProperty(this, k / 2, {value: new AttrNode(KEY, el, a[k]), enumerable: true});
		hidden(this, {_el: el, _n: a.length / 2});
	}
	get length() { return this._n; }
	item(k) { k = k >>> 0; return k < this._n ? this[k] : null; }
	getNamedItem(name) {
		name = attrname(this._el, name);
		return N.attr(this._el, name) === null ? null : new AttrNode(KEY, this._el, name);
	}
	getNamedItemNS(ns, name) { return this.getNamedItem(name); }
	removeNamedItem(name) {
		const a = this.getNamedItem(name);
		if (!a)
			throw domerr('NotFoundError', 'No item with that name was found.');
		delattr(this._el, a.name);
		return a;
	}
	setNamedItem(a) { setattr(this._el, a.name, a.value); return null; }
	*[Symbol.iterator]() { for (let k = 0; k < this._n; k++) yield this[k]; }
}

function attrname(el, name) {
	name = str(name);
	return N.ns(el) === 0 ? lower(name) : name;
}

// ---- elements ----

class Element extends Node {
	get tagName() { return tagname(idof(this)); }
	get localName() { return N.name(idof(this)); }
	get namespaceURI() { return NSURIS[N.ns(idof(this))] || null; }
	get prefix() { return null; }
	get id() { return N.attr(idof(this), 'id') || ''; }
	set id(v) { setattr(idof(this), 'id', str(v)); }
	get className() { return N.attr(idof(this), 'class') || ''; }
	set className(v) { setattr(idof(this), 'class', str(v)); }
	get classList() { return new DOMTokenList(KEY, idof(this), 'class'); }
	set classList(v) { setattr(idof(this), 'class', str(v)); }
	get slot() { return N.attr(idof(this), 'slot') || ''; }
	getAttribute(name) { return N.attr(idof(this), attrname(idof(this), name)); }
	getAttributeNS(ns, name) { return N.attr(idof(this), str(name)); }
	setAttribute(name, v) {
		name = attrname(idof(this), name);
		if (!/^[^\s"'>/=\0]+$/.test(name))
			throw domerr('InvalidCharacterError', "'" + name + "' is not a valid attribute name.");
		setattr(idof(this), name, str(v));
	}
	setAttributeNS(ns, name, v) {
		const k = str(name).indexOf(':');
		this.setAttribute(k >= 0 && ns !== 'http://www.w3.org/1999/xlink' ? str(name).slice(k + 1) : name, v);
	}
	removeAttribute(name) { delattr(idof(this), attrname(idof(this), name)); }
	removeAttributeNS(ns, name) { delattr(idof(this), str(name)); }
	hasAttribute(name) { return N.attr(idof(this), attrname(idof(this), name)) !== null; }
	hasAttributeNS(ns, name) { return N.attr(idof(this), str(name)) !== null; }
	hasAttributes() { return N.attrs(idof(this)).length > 0; }
	toggleAttribute(name, force) {
		const i = idof(this);
		name = attrname(i, name);
		const has = N.attr(i, name) !== null;
		if (has && force !== true) {
			delattr(i, name);
			return false;
		}
		if (!has && force !== false)
			setattr(i, name, '');
		return has ? true : force !== false;
	}
	getAttributeNames() {
		const a = N.attrs(idof(this));
		const r = [];
		for (let k = 0; k < a.length; k += 2)
			r.push(a[k]);
		return r;
	}
	get attributes() { return new NamedNodeMap(KEY, idof(this)); }
	getAttributeNode(name) { return this.attributes.getNamedItem(name); }
	get children() { return collection(N.children(idof(this), true)); }
	get childElementCount() { return N.children(idof(this), true).length; }
	get firstElementChild() { return wrap(firstel(N.first(idof(this)))); }
	get lastElementChild() {
		let c = N.last(idof(this));
		while (c && N.kind(c) !== ELEMENT)
			c = N.prev(c);
		return wrap(c);
	}
	get nextElementSibling() { return wrap(firstel(N.next(idof(this)))); }
	get previousElementSibling() {
		let c = N.prev(idof(this));
		while (c && N.kind(c) !== ELEMENT)
			c = N.prev(c);
		return wrap(c);
	}
	get innerHTML() { return N.markup(idof(this), false); }
	set innerHTML(v) {
		const i = idof(this);
		v = v === null ? '' : str(v);
		// the fragment parsing algorithm in the element's context: raw
		// text and RCDATA elements hold the markup as text
		if (N.ns(i) === 0 && RAWTEXT.has(N.name(i))) {
			this.textContent = v;
			return;
		}
		if (N.ns(i) === 0 && (N.name(i) === 'textarea' || N.name(i) === 'title')) {
			this.textContent = rcdata(v);
			return;
		}
		replaceall(templateholder(i), N.parse(v));
	}
	get outerHTML() { return N.markup(idof(this), true); }
	set outerHTML(v) {
		const i = idof(this), p = N.parent(i);
		if (!p)
			return;
		const nodes = N.parse(str(v));
		const next = N.next(i);
		removenode(i);
		for (const n of nodes)
			insertnode(p, wrap(n), next);
	}
	insertAdjacentHTML(where, html) {
		const f = N.create(DOCUMENT, '', 0);
		for (const n of N.parse(str(html)))
			N.insert(f, n, 0);
		adjacent(this, where, wrap(f));
	}
	insertAdjacentElement(where, el) { return adjacent(this, where, el); }
	insertAdjacentText(where, text) { adjacent(this, where, document.createTextNode(text)); }
	querySelector(sel) { return wrap(select(idof(this), sel, false)); }
	querySelectorAll(sel) { return new NodeList(KEY, select(idof(this), sel, true).map(wrap)); }
	matches(sel) { return matches(idof(this), sel); }
	webkitMatchesSelector(sel) { return matches(idof(this), sel); }
	msMatchesSelector(sel) { return matches(idof(this), sel); }
	closest(sel) {
		const i = idof(this);
		for (let p = i; p && N.kind(p) === ELEMENT; p = N.parent(p))
			if (matches(p, sel, i))
				return wrap(p);
		return null;
	}
	getElementsByTagName(name) { return collection(N.descendants(idof(this), 'name', str(name))); }
	getElementsByTagNameNS(ns, name) { return collection(N.descendants(idof(this), 'name', str(name))); }
	getElementsByClassName(names) { return collection(N.descendants(idof(this), 'class', str(names))); }
	remove() { removenode(idof(this)); }
	before(...nodes) { const p = N.parent(idof(this)); if (p) insertnode(p, nodesof(nodes), idof(this)); }
	after(...nodes) { const p = N.parent(idof(this)); if (p) insertnode(p, nodesof(nodes), N.next(idof(this))); }
	replaceWith(...nodes) {
		const i = idof(this), p = N.parent(i);
		if (!p)
			return;
		const f = nodesof(nodes), next = N.next(i);
		removenode(i);
		insertnode(p, f, next === i ? 0 : next);
	}
	append(...nodes) { insertnode(idof(this), nodesof(nodes), 0); }
	prepend(...nodes) { insertnode(idof(this), nodesof(nodes), N.first(idof(this))); }
	replaceChildren(...nodes) {
		const f = nodesof(nodes);
		replaceall(idof(this), []);
		insertnode(idof(this), f, 0);
	}
	getBoundingClientRect() {
		const [shown, x, y, w, h] = N.box(idof(this));
		const [, , sx, sy] = N.viewport();
		return shown ? new DOMRect(x - sx, y - sy, w, h) : new DOMRect(0, 0, 0, 0);
	}
	getClientRects() {
		const [shown] = N.box(idof(this));
		return shown ? [this.getBoundingClientRect()] : [];
	}
	get clientWidth() { return clientsize(idof(this), 3); }
	get clientHeight() { return clientsize(idof(this), 4); }
	get clientTop() { return 0; }
	get clientLeft() { return 0; }
	get scrollWidth() { return clientsize(idof(this), 3); }
	get scrollHeight() {
		const i = idof(this);
		if (i === N.first(1) || N.name(i) === 'body' && N.parent(i) === rootel())
			return N.box(rootel())[4] || N.viewport()[1];
		return clientsize(i, 4);
	}
	get scrollTop() {
		const i = idof(this);
		return i === rootel() || N.name(i) === 'body' ? N.viewport()[3] : 0;
	}
	set scrollTop(v) {
		const i = idof(this);
		if (i === rootel() || N.name(i) === 'body')
			N.scroll(N.viewport()[2], +v | 0);
	}
	get scrollLeft() { return 0; }
	set scrollLeft(v) {}
	scrollIntoView() {
		const [shown, , y] = N.box(idof(this));
		if (shown)
			N.scroll(0, y);
	}
	scrollIntoViewIfNeeded() { this.scrollIntoView(); }
	scroll() {}
	scrollTo() {}
	scrollBy() {}
	attachShadow(init) {
		if (this._shadowroot)
			throw domerr('NotSupportedError', "Failed to execute 'attachShadow' on 'Element': Shadow root cannot be created on a host which already hosts a shadow tree.");
		const f = N.create(DOCUMENT, '', 0);
		const sr = wrap(f);
		Object.setPrototypeOf(sr, ShadowRoot.prototype);
		hidden(sr, {_host: this, _mode: init && init.mode || 'open'});
		hidden(this, {_shadowroot: sr});
		if (sr._mode === 'open')
			hidden(this, {_shadow: sr});
		N.attachshadow(idof(this), f);
		return sr;
	}
	get shadowRoot() { return this._shadow || null; }
	animate() {
		return {cancel() {}, finish() {}, play() {}, pause() {}, reverse() {}, finished: Promise.resolve(),
			onfinish: null, addEventListener() {}, removeEventListener() {}};
	}
	getAnimations() { return []; }
	requestFullscreen() { return Promise.reject(domerr('NotSupportedError', 'fullscreen is not supported')); }
	setPointerCapture() {}
	releasePointerCapture() {}
	hasPointerCapture() { return false; }
	checkVisibility() { return N.box(idof(this))[0] !== 0; }
}

const RAWTEXT = new Set(['script', 'style', 'xmp', 'iframe', 'noembed', 'noframes', 'noscript', 'plaintext']);

// RCDATA's text: character references decoded, nothing else
function rcdata(v) {
	if (v.indexOf('&') < 0)
		return v;
	const nodes = N.parse('<textarea>' + v.replace(/<\/(textarea)/gi, '&lt;/$1') + '</textarea>');
	return nodes.length ? N.textof(nodes[0]) : v;
}

function rootel() {
	return firstel(N.first(1));
}

function firstel(c) {
	while (c && N.kind(c) !== ELEMENT)
		c = N.next(c);
	return c;
}

// the root and the body measure the viewport, as in standards mode
function clientsize(i, k) {
	if (i === rootel())
		return N.viewport()[k - 3];
	const b = N.box(i);
	return b[0] ? b[k] : 0;
}

function nodesof(list) {
	if (list.length === 1 && isnode(list[0]))
		return list[0];
	const f = N.create(DOCUMENT, '', 0);
	for (const n of list) {
		const c = isnode(n) ? idof(n) : textnode(str(n));
		if (N.parent(c))
			removenode(c);
		N.insert(f, c, 0);
	}
	return wrap(f);
}

function textnode(s) {
	const t = N.create(TEXT, '#text', 0);
	N.setdata(t, s);
	return t;
}

function adjacent(el, where, node) {
	const i = idof(el);
	switch (lower(str(where))) {
	case 'beforebegin':
		if (!N.parent(i))
			return null;
		insertnode(N.parent(i), node, i);
		break;
	case 'afterbegin':
		insertnode(i, node, N.first(i));
		break;
	case 'beforeend':
		insertnode(i, node, 0);
		break;
	case 'afterend':
		if (!N.parent(i))
			return null;
		insertnode(N.parent(i), node, N.next(i));
		break;
	default:
		throw domerr('SyntaxError', "The value provided ('" + where + "') is not one of 'beforeBegin', 'afterBegin', 'beforeEnd', or 'afterEnd'.");
	}
	return node;
}

// a compound of a tag, an id and classes, which needs no selector engine
// a compound of a tag, an id and classes, which needs no selector engine
const SIMPLESEL = /^\s*([a-zA-Z][a-zA-Z0-9-]*|\*)?(?:#([a-zA-Z_][\w-]*))?((?:\.[a-zA-Z_][\w-]*)*)\s*$/;

// the elements under i a simple compound selects, in document order; null if not simple
function simplesel(i, sel) {
	const m = SIMPLESEL.exec(sel);
	if (!m || !(m[1] || m[2] || m[3]))
		return null;
	const tag = m[1] && m[1] !== '*' ? lower(m[1]) : null, id = m[2], classes = m[3] ? m[3].slice(1).split('.') : null;
	let cands;
	if (id !== undefined) {
		const e = N.descendants(i, 'id', id);
		cands = e ? [e] : [];
	} else if (classes)
		cands = N.descendants(i, 'class', classes.join(' '));
	else
		return N.descendants(i, 'name', tag);
	const r = [];
	for (const e of cands) {
		if (tag && N.name(e) !== tag && !(N.ns(e) !== 0 && lower(N.name(e)) === tag))
			continue;
		if (id !== undefined && classes) {
			const cl = ' ' + (N.attr(e, 'class') || '').replace(/[\t\n\f\r]/g, ' ') + ' ';
			if (!classes.every((c) => cl.indexOf(' ' + c + ' ') >= 0))
				continue;
		}
		r.push(e);
	}
	return r;
}

// a selector list's top-level parts, and each part's last compound
function selparts(sel) {
	const parts = [];
	let depth = 0, q = '', start = 0, last = 0;
	for (let k = 0; k < sel.length; k++) {
		const c = sel[k];
		if (q) {
			if (c === '\\')
				k++;
			else if (c === q)
				q = '';
			continue;
		}
		if (c === '"' || c === "'")
			q = c;
		else if (c === '(' || c === '[')
			depth++;
		else if (c === ')' || c === ']')
			depth--;
		else if (depth === 0 && c === ',') {
			parts.push([sel.slice(start, k), sel.slice(last, k)]);
			start = last = k + 1;
		} else if (depth === 0 && (c === ' ' || c === '>' || c === '+' || c === '~' || c === '\t' || c === '\n')) {
			if (sel.slice(k + 1).trim() !== '')
				last = k + 1;
		}
	}
	parts.push([sel.slice(start), sel.slice(last)]);
	return parts;
}

function select(i, sel, all) {
	sel = str(sel);
	const fast = simplesel(i, sel);
	if (fast !== null)
		return all ? fast : (fast[0] || 0);
	// right to left: the candidates the last compound of each part
	// selects, matched whole; parts with no simple last compound go to
	// the host's selector engine
	const parts = selparts(sel);
	let cand = [];
	for (const [part, lastc] of parts) {
		const c = simplesel(i, lastc.trim().replace(/^[>+~]\s*/, ''));
		if (c === null)
			return selectall(i, sel, all);
		for (const e of c)
			cand.push(e);
	}
	const hits = [];
	for (const e of cand) {
		const r = N.match(e, sel, i);
		if (r < 0)
			throw domerr('SyntaxError', "'" + sel + "' is not a valid selector.");
		if (r > 0)
			hits.push(e);
	}
	if (parts.length > 1 && hits.length > 1) {
		// several parts: back into document order, once each
		const want = new Set(hits);
		const ordered = [];
		for (const e of N.descendants(i, 'name', '*'))
			if (want.has(e))
				ordered.push(e);
		return all ? ordered : ordered[0];
	}
	return all ? hits : (hits[0] || 0);
}

function selectall(i, sel, all) {
	const r = N.select(i, sel, all);
	if (r === null)
		throw domerr('SyntaxError', "'" + sel + "' is not a valid selector.");
	return r;
}

// scope: the element :scope is, the one asked (closest() asks its ancestors)
function matches(i, sel, scope = i) {
	const r = N.match(i, str(sel), scope);
	if (r < 0)
		throw domerr('SyntaxError', "'" + sel + "' is not a valid selector.");
	return r > 0;
}

// a template's content: its children, moved into a fragment of their own
const TEMPLATES = new Map();

function templatecontent(i) {
	let f = TEMPLATES.get(i);
	if (f === undefined) {
		f = N.create(DOCUMENT, '', 0);
		for (const c of N.children(i, false)) {
			N.remove(c);
			N.insert(f, c, 0);
		}
		TEMPLATES.set(i, f);
	}
	return f;
}

function templateholder(i) {
	return N.name(i) === 'template' && N.ns(i) === 0 ? templatecontent(i) : i;
}

class DOMRectReadOnly {
	constructor(x = 0, y = 0, width = 0, height = 0) {
		hidden(this, {_x: +x, _y: +y, _w: +width, _h: +height});
	}
	get x() { return this._x; }
	get y() { return this._y; }
	get width() { return this._w; }
	get height() { return this._h; }
	get top() { return Math.min(this._y, this._y + this._h); }
	get left() { return Math.min(this._x, this._x + this._w); }
	get bottom() { return Math.max(this._y, this._y + this._h); }
	get right() { return Math.max(this._x, this._x + this._w); }
	toJSON() {
		return {x: this.x, y: this.y, width: this.width, height: this.height, top: this.top,
			left: this.left, bottom: this.bottom, right: this.right};
	}
	static fromRect(r = {}) { return new this(r.x, r.y, r.width, r.height); }
}

class DOMRect extends DOMRectReadOnly {
	get x() { return this._x; }
	set x(v) { this._x = +v; }
	get y() { return this._y; }
	set y(v) { this._y = +v; }
	get width() { return this._w; }
	set width(v) { this._w = +v; }
	get height() { return this._h; }
	set height(v) { this._h = +v; }
}

// ---- style sheets ----
//
// A <style>'s sheet is its text, split into rules; a rule inserted or
// deleted is written back into the text, which the host's styles read.
// A <link>'s sheet has no rules script may see; one made with new is
// not applied.

class CSSRule {
	constructor(key, text, sheet) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		hidden(this, {_t: text, _sheet: sheet});
	}
	get cssText() { return this._t; }
	get parentStyleSheet() { return this._sheet; }
	get parentRule() { return null; }
	get type() { return /^\s*@media/i.test(this._t) ? 4 : /^\s*@import/i.test(this._t) ? 3 : /^\s*@font-face/i.test(this._t) ? 5 : /^\s*@keyframes/i.test(this._t) ? 7 : 1; }
	get selectorText() { const k = this._t.indexOf('{'); return k < 0 ? '' : this._t.slice(0, k).trim(); }
	get style() {
		const k = this._t.indexOf('{'), e = this._t.lastIndexOf('}');
		const rule = this;
		return styledecl({readonly: false, decls: () => parsedecls(k < 0 ? '' : rule._t.slice(k + 1, e < 0 ? undefined : e)),
			save: (m) => { rule._t = rule.selectorText + ' { ' + unparsedecls(m) + ' }'; if (rule._sheet) rule._sheet._write(); }});
	}
}
class CSSStyleRule extends CSSRule {}
class CSSMediaRule extends CSSRule {}

// a style sheet's text split into its rules at the top level
function splitrules(s) {
	const rules = [];
	let depth = 0, start = 0, q = '';
	for (let k = 0; k < s.length; k++) {
		const c = s[k];
		if (q) {
			if (c === '\\')
				k++;
			else if (c === q)
				q = '';
			continue;
		}
		if (c === '/' && s[k + 1] === '*') {
			const e = s.indexOf('*/', k + 2);
			k = e < 0 ? s.length : e + 1;
			continue;
		}
		if (c === '"' || c === "'")
			q = c;
		else if (c === '{')
			depth++;
		else if (c === '}') {
			if (--depth === 0) {
				rules.push(s.slice(start, k + 1).trim());
				start = k + 1;
			}
		} else if (c === ';' && depth === 0) {
			const r = s.slice(start, k + 1).trim();
			if (r)
				rules.push(r);
			start = k + 1;
		}
	}
	return rules.filter((r) => r !== '');
}

class CSSStyleSheet {
	constructor(opts = {}) {
		hidden(this, {_owner: 0, _rules: [], _text: null, _disabled: !!opts.disabled, _media: opts.media || ''});
	}
	_load() {
		if (!this._owner)
			return this._rules;
		if (N.name(this._owner) !== 'style')
			return [];
		const t = N.textof(this._owner);
		if (t !== this._text) {
			this._text = t;
			this._rules = splitrules(t).map((r) => new (/^\s*@media/i.test(r) ? CSSMediaRule : CSSStyleRule)(KEY, r, this));
		}
		return this._rules;
	}
	_write() {
		if (!this._owner || N.name(this._owner) !== 'style')
			return;
		const t = this._rules.map((r) => r._t).join('\n');
		this._text = t;
		replaceall(this._owner, t === '' ? [] : [textnode(t)]);
	}
	get cssRules() {
		if (this._owner && N.name(this._owner) !== 'style')
			throw domerr('SecurityError', "Failed to read the 'cssRules' property from 'CSSStyleSheet': Cannot access rules");
		const r = this._load().slice();
		r.item = (k) => r[k] || null;
		return r;
	}
	get rules() { return this.cssRules; }
	get ownerNode() { return wrap(this._owner); }
	get ownerRule() { return null; }
	get parentStyleSheet() { return null; }
	get href() { return this._owner && N.name(this._owner) === 'link' ? resolve(N.attr(this._owner, 'href') || '') : null; }
	get title() { return this._owner ? N.attr(this._owner, 'title') : null; }
	get type() { return 'text/css'; }
	get media() { const m = this._owner ? N.attr(this._owner, 'media') || '' : this._media; return {mediaText: m, length: m ? 1 : 0, item: () => m || null}; }
	get disabled() { return this._disabled; }
	set disabled(v) { this._disabled = !!v; }
	insertRule(rule, index = 0) {
		const rules = this._load();
		index = index >>> 0;
		if (index > rules.length)
			throw domerr('IndexSizeError', "Failed to execute 'insertRule' on 'CSSStyleSheet': The index provided (" + index + ') is larger than the maximum index (' + rules.length + ').');
		rule = str(rule).trim();
		if (!/^[^{}]*\{[^]*\}$/.test(rule) && !/^@(import|charset|namespace|layer)\b/i.test(rule))
			throw domerr('SyntaxError', "Failed to execute 'insertRule' on 'CSSStyleSheet': Failed to parse the rule '" + rule + "'.");
		rules.splice(index, 0, new (/^\s*@media/i.test(rule) ? CSSMediaRule : CSSStyleRule)(KEY, rule, this));
		this._write();
		return index;
	}
	deleteRule(index) {
		const rules = this._load();
		index = index >>> 0;
		if (index >= rules.length)
			throw domerr('IndexSizeError', "Failed to execute 'deleteRule' on 'CSSStyleSheet': The index provided (" + index + ') is larger than the maximum index (' + (rules.length - 1) + ').');
		rules.splice(index, 1);
		this._write();
	}
	addRule(sel = 'undefined', style = 'undefined', index) {
		this.insertRule(sel + ' { ' + style + ' }', index === undefined ? this._load().length : index);
		return -1;
	}
	removeRule(index = 0) { this.deleteRule(index); }
	replaceSync(text) {
		this._rules = splitrules(str(text)).map((r) => new CSSStyleRule(KEY, r, this));
		this._write();
	}
	replace(text) {
		try {
			this.replaceSync(text);
			return Promise.resolve(this);
		} catch (x) {
			return Promise.reject(x);
		}
	}
}

const SHEETS = new Map();

function stylesheet(i) {
	let sh = SHEETS.get(i);
	if (!sh) {
		sh = new CSSStyleSheet();
		sh._owner = i;
		SHEETS.set(i, sh);
	}
	return sh;
}

// ---- geometry: DOMPoint and DOMMatrix (column-major m11..m44, as the
// Geometry Interfaces have them) ----

class DOMPointReadOnly {
	constructor(x = 0, y = 0, z = 0, w = 1) {
		hidden(this, {_x: +x, _y: +y, _z: +z, _w: +w});
	}
	get x() { return this._x; }
	get y() { return this._y; }
	get z() { return this._z; }
	get w() { return this._w; }
	matrixTransform(m) { return DOMMatrixReadOnly.fromMatrix(m).transformPoint(this); }
	toJSON() { return {x: this._x, y: this._y, z: this._z, w: this._w}; }
	static fromPoint(p = {}) { return new this(p.x, p.y, p.z, p.w === undefined ? 1 : p.w); }
}

class DOMPoint extends DOMPointReadOnly {
	get x() { return this._x; }
	set x(v) { this._x = +v; }
	get y() { return this._y; }
	set y(v) { this._y = +v; }
	get z() { return this._z; }
	set z(v) { this._z = +v; }
	get w() { return this._w; }
	set w(v) { this._w = +v; }
}

const MKEYS = ['m11', 'm12', 'm13', 'm14', 'm21', 'm22', 'm23', 'm24', 'm31', 'm32', 'm33', 'm34', 'm41', 'm42', 'm43', 'm44'];

function mparse(s) {
	s = str(s).trim();
	if (s === '' || s === 'none')
		return [1, 0, 0, 1, 0, 0];
	let m = /^matrix\(([^)]*)\)$/.exec(s) || /^matrix3d\(([^)]*)\)$/.exec(s);
	if (!m)
		throw new SyntaxError("Failed to parse '" + s + "' as a transform list");
	const v = m[1].split(',').map(Number);
	if (v.length !== 6 && v.length !== 16 || v.some((x) => x !== x))
		throw new SyntaxError("Failed to parse '" + s + "' as a transform list");
	return v;
}

class DOMMatrixReadOnly {
	constructor(init) {
		let v = init === undefined ? [1, 0, 0, 1, 0, 0] : typeof init === 'string' ? mparse(init) : Array.from(init, Number);
		const m = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
		let is2d = true;
		if (v.length === 6) {
			m[0] = v[0]; m[1] = v[1]; m[4] = v[2]; m[5] = v[3]; m[12] = v[4]; m[13] = v[5];
		} else if (v.length === 16) {
			for (let k = 0; k < 16; k++)
				m[k] = v[k];
			is2d = false;
		} else
			throw new TypeError("Failed to construct 'DOMMatrix': The sequence must contain 6 elements for a 2D matrix or 16 elements for a 3D matrix.");
		hidden(this, {_m: m, _2d: is2d});
	}
	static fromMatrix(o = {}) {
		if (o instanceof DOMMatrixReadOnly)
			return new this(o._m);
		const r = new this();
		const m = r._m;
		m[0] = o.m11 ?? o.a ?? 1; m[1] = o.m12 ?? o.b ?? 0; m[4] = o.m21 ?? o.c ?? 0; m[5] = o.m22 ?? o.d ?? 1;
		m[12] = o.m41 ?? o.e ?? 0; m[13] = o.m42 ?? o.f ?? 0;
		return r;
	}
	static fromFloat32Array(a) { return new this(Array.from(a)); }
	static fromFloat64Array(a) { return new this(Array.from(a)); }
	get a() { return this._m[0]; }
	get b() { return this._m[1]; }
	get c() { return this._m[4]; }
	get d() { return this._m[5]; }
	get e() { return this._m[12]; }
	get f() { return this._m[13]; }
	get is2D() { return this._2d; }
	get isIdentity() { return this._m.every((x, k) => x === (k % 5 === 0 ? 1 : 0)); }
	_mul(o) {
		const a = this._m, b = o._m, r = new Array(16);
		for (let i = 0; i < 4; i++)
			for (let j = 0; j < 4; j++) {
				let x = 0;
				for (let k = 0; k < 4; k++)
					x += a[k * 4 + j] * b[i * 4 + k];
				r[i * 4 + j] = x;
			}
		const m = new DOMMatrix(r);
		m._2d = this._2d && o._2d;
		return m;
	}
	multiply(o) { return this._mul(DOMMatrixReadOnly.fromMatrix(o)); }
	translate(tx = 0, ty = 0, tz = 0) {
		const t = new DOMMatrix([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, +tx, +ty, +tz, 1]);
		t._2d = tz === 0;
		return this._mul(t);
	}
	scale(sx = 1, sy = sx, sz = 1, ox = 0, oy = 0, oz = 0) {
		const s = new DOMMatrix([+sx, 0, 0, 0, 0, +sy, 0, 0, 0, 0, +sz, 0, 0, 0, 0, 1]);
		s._2d = sz === 1;
		return this.translate(ox, oy, oz)._mul(s).translate(-ox, -oy, -oz);
	}
	rotate(rx = 0, ry, rz) {
		if (ry === undefined && rz === undefined) {
			rz = rx;
			rx = ry = 0;
		}
		const r = (deg) => deg * Math.PI / 180;
		let m = new DOMMatrix(this._m);
		m._2d = this._2d;
		const rot = (ax, deg) => {
			const c = Math.cos(r(deg)), s = Math.sin(r(deg));
			const v = ax === 'z' ? [c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] :
				ax === 'x' ? [1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1] :
				[c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1];
			const t = new DOMMatrix(v);
			t._2d = ax === 'z';
			return t;
		};
		if (+rz)
			m = m._mul(rot('z', +rz));
		if (+ry)
			m = m._mul(rot('y', +ry));
		if (+rx)
			m = m._mul(rot('x', +rx));
		return m;
	}
	inverse() {
		const m = this._m;
		if (this._2d) {
			const det = m[0] * m[5] - m[1] * m[4];
			if (!det)
				return new DOMMatrix([NaN, NaN, NaN, NaN, NaN, NaN]);
			return new DOMMatrix([m[5] / det, -m[1] / det, -m[4] / det, m[0] / det,
				(m[4] * m[13] - m[5] * m[12]) / det, (m[1] * m[12] - m[0] * m[13]) / det]);
		}
		// a general 4x4 inverse by cofactors
		const inv = new Array(16);
		inv[0] = m[5]*m[10]*m[15]-m[5]*m[11]*m[14]-m[9]*m[6]*m[15]+m[9]*m[7]*m[14]+m[13]*m[6]*m[11]-m[13]*m[7]*m[10];
		inv[4] = -m[4]*m[10]*m[15]+m[4]*m[11]*m[14]+m[8]*m[6]*m[15]-m[8]*m[7]*m[14]-m[12]*m[6]*m[11]+m[12]*m[7]*m[10];
		inv[8] = m[4]*m[9]*m[15]-m[4]*m[11]*m[13]-m[8]*m[5]*m[15]+m[8]*m[7]*m[13]+m[12]*m[5]*m[11]-m[12]*m[7]*m[9];
		inv[12] = -m[4]*m[9]*m[14]+m[4]*m[10]*m[13]+m[8]*m[5]*m[14]-m[8]*m[6]*m[13]-m[12]*m[5]*m[10]+m[12]*m[6]*m[9];
		inv[1] = -m[1]*m[10]*m[15]+m[1]*m[11]*m[14]+m[9]*m[2]*m[15]-m[9]*m[3]*m[14]-m[13]*m[2]*m[11]+m[13]*m[3]*m[10];
		inv[5] = m[0]*m[10]*m[15]-m[0]*m[11]*m[14]-m[8]*m[2]*m[15]+m[8]*m[3]*m[14]+m[12]*m[2]*m[11]-m[12]*m[3]*m[10];
		inv[9] = -m[0]*m[9]*m[15]+m[0]*m[11]*m[13]+m[8]*m[1]*m[15]-m[8]*m[3]*m[13]-m[12]*m[1]*m[11]+m[12]*m[3]*m[9];
		inv[13] = m[0]*m[9]*m[14]-m[0]*m[10]*m[13]-m[8]*m[1]*m[14]+m[8]*m[2]*m[13]+m[12]*m[1]*m[10]-m[12]*m[2]*m[9];
		inv[2] = m[1]*m[6]*m[15]-m[1]*m[7]*m[14]-m[5]*m[2]*m[15]+m[5]*m[3]*m[14]+m[13]*m[2]*m[7]-m[13]*m[3]*m[6];
		inv[6] = -m[0]*m[6]*m[15]+m[0]*m[7]*m[14]+m[4]*m[2]*m[15]-m[4]*m[3]*m[14]-m[12]*m[2]*m[7]+m[12]*m[3]*m[6];
		inv[10] = m[0]*m[5]*m[15]-m[0]*m[7]*m[13]-m[4]*m[1]*m[15]+m[4]*m[3]*m[13]+m[12]*m[1]*m[7]-m[12]*m[3]*m[5];
		inv[14] = -m[0]*m[5]*m[14]+m[0]*m[6]*m[13]+m[4]*m[1]*m[14]-m[4]*m[2]*m[13]-m[12]*m[1]*m[6]+m[12]*m[2]*m[5];
		inv[3] = -m[1]*m[6]*m[11]+m[1]*m[7]*m[10]+m[5]*m[2]*m[11]-m[5]*m[3]*m[10]-m[9]*m[2]*m[7]+m[9]*m[3]*m[6];
		inv[7] = m[0]*m[6]*m[11]-m[0]*m[7]*m[10]-m[4]*m[2]*m[11]+m[4]*m[3]*m[10]+m[8]*m[2]*m[7]-m[8]*m[3]*m[6];
		inv[11] = -m[0]*m[5]*m[11]+m[0]*m[7]*m[9]+m[4]*m[1]*m[11]-m[4]*m[3]*m[9]-m[8]*m[1]*m[7]+m[8]*m[3]*m[5];
		inv[15] = m[0]*m[5]*m[10]-m[0]*m[6]*m[9]-m[4]*m[1]*m[10]+m[4]*m[2]*m[9]+m[8]*m[1]*m[6]-m[8]*m[2]*m[5];
		const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
		return new DOMMatrix(inv.map((x) => det ? x / det : NaN));
	}
	transformPoint(p = {}) {
		const m = this._m, x = p.x || 0, y = p.y || 0, z = p.z || 0, w = p.w === undefined ? 1 : p.w;
		return new DOMPoint(m[0] * x + m[4] * y + m[8] * z + m[12] * w, m[1] * x + m[5] * y + m[9] * z + m[13] * w,
			m[2] * x + m[6] * y + m[10] * z + m[14] * w, m[3] * x + m[7] * y + m[11] * z + m[15] * w);
	}
	flipX() { return this.scale(-1, 1); }
	flipY() { return this.scale(1, -1); }
	toFloat32Array() { return new Float32Array(this._m); }
	toFloat64Array() { return new Float64Array(this._m); }
	toString() {
		const m = this._m;
		return this._2d ? 'matrix(' + [m[0], m[1], m[4], m[5], m[12], m[13]].join(', ') + ')' : 'matrix3d(' + m.join(', ') + ')';
	}
	toJSON() {
		const o = {a: this.a, b: this.b, c: this.c, d: this.d, e: this.e, f: this.f, is2D: this._2d, isIdentity: this.isIdentity};
		MKEYS.forEach((k, i) => { o[k] = this._m[i]; });
		return o;
	}
}
MKEYS.forEach((k, i) => defineProperty(DOMMatrixReadOnly.prototype, k, {get() { return this._m[i]; }, configurable: true}));

class DOMMatrix extends DOMMatrixReadOnly {
	multiplySelf(o) { this._m = this.multiply(o)._m; return this; }
	preMultiplySelf(o) { this._m = DOMMatrixReadOnly.fromMatrix(o)._mul(this)._m; return this; }
	translateSelf(x, y, z) { const r = this.translate(x, y, z); this._m = r._m; this._2d = r._2d; return this; }
	scaleSelf(...a) { const r = this.scale(...a); this._m = r._m; this._2d = r._2d; return this; }
	rotateSelf(...a) { const r = this.rotate(...a); this._m = r._m; this._2d = r._2d; return this; }
	invertSelf() { this._m = this.inverse()._m; return this; }
	setMatrixValue(s) { const r = new DOMMatrix(str(s)); this._m = r._m; this._2d = r._2d; return this; }
}
for (const [k, i] of [['a', 0], ['b', 1], ['c', 4], ['d', 5], ['e', 12], ['f', 13]].concat(MKEYS.map((k, i) => [k, i])))
	defineProperty(DOMMatrix.prototype, k, {get() { return this._m[i]; }, set(v) { this._m[i] = +v; }, configurable: true});

// ---- inline style and dataset ----

function parsedecls(s) {
	const m = new Map();
	if (!s)
		return m;
	for (const d of s.split(';')) {
		const k = d.indexOf(':');
		if (k < 0)
			continue;
		const name = d.slice(0, k).trim().toLowerCase();
		let v = d.slice(k + 1).trim();
		let pri = '';
		const im = /\s*!\s*important$/i.exec(v);
		if (im) {
			v = v.slice(0, im.index);
			pri = 'important';
		}
		if (name)
			m.set(name, [v, pri]);
	}
	return m;
}

function unparsedecls(m) {
	let s = '';
	for (const [k, [v, pri]] of m)
		s += (s ? ' ' : '') + k + ': ' + v + (pri ? ' !important' : '') + ';';
	return s;
}

class CSSStyleDeclaration {
	constructor(key) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
	}
}

const STYLEMETHODS = {
	getPropertyValue(o, name) {
		const d = o.decls().get(str(name).toLowerCase());
		return d ? d[0] : '';
	},
	getPropertyPriority(o, name) {
		const d = o.decls().get(str(name).toLowerCase());
		return d ? d[1] : '';
	},
	setProperty(o, name, v, pri = '') {
		if (o.readonly)
			throw domerr('NoModificationAllowedError', 'computed style is read-only');
		name = str(name).toLowerCase();
		const m = o.decls();
		if (v === null || v === undefined || str(v) === '')
			m.delete(name);
		else
			m.set(name.startsWith('--') ? str(name) : name, [str(v), pri ? 'important' : '']);
		o.save(m);
	},
	removeProperty(o, name) {
		if (o.readonly)
			throw domerr('NoModificationAllowedError', 'computed style is read-only');
		name = str(name).toLowerCase();
		const m = o.decls();
		const d = m.get(name);
		m.delete(name);
		o.save(m);
		return d ? d[0] : '';
	},
	item(o, k) {
		const keys = [...o.decls().keys()];
		return keys[k >>> 0] || '';
	},
};

function styledecl(o) {
	const target = new CSSStyleDeclaration(KEY);
	return new Proxy(target, {
		get(t, k, r) {
			if (typeof k === 'symbol')
				return k === Symbol.iterator ? function* () { yield* o.decls().keys(); } : undefined;
			if (k in STYLEMETHODS)
				return (...a) => STYLEMETHODS[k](o, ...a);
			if (k === 'cssText')
				return o.readonly ? '' : unparsedecls(o.decls());
			if (k === 'length')
				return o.decls().size;
			if (k === 'parentRule')
				return null;
			if (k === 'cssFloat')
				k = 'float';
			if (/^\d+$/.test(k))
				return STYLEMETHODS.item(o, +k);
			if (k === 'constructor')
				return CSSStyleDeclaration;
			if (k === 'toString')
				return () => '[object CSSStyleDeclaration]';
			return STYLEMETHODS.getPropertyValue(o, k.startsWith('--') ? k : kebab(k));
		},
		set(t, k, v) {
			if (typeof k === 'symbol')
				return true;
			if (o.readonly)
				return true;
			if (k === 'cssText') {
				o.save(parsedecls(str(v)));
				return true;
			}
			STYLEMETHODS.setProperty(o, k.startsWith('--') ? k : kebab(k), v);
			return true;
		},
		has(t, k) {
			return typeof k === 'string' && (k in STYLEMETHODS || k === 'cssText' || k === 'length' || CSSPROPS.has(k) || o.decls().has(kebab(k)));
		},
		ownKeys() {
			return [...o.decls().keys()].map((k, j) => String(j));
		},
		getOwnPropertyDescriptor(t, k) {
			if (/^\d+$/.test(k) && +k < o.decls().size)
				return {value: STYLEMETHODS.item(o, +k), enumerable: true, configurable: true, writable: false};
			return undefined;
		},
		getPrototypeOf() { return CSSStyleDeclaration.prototype; },
	});
}

const CSSPROPS = new Set(('alignContent alignItems alignSelf animation background backgroundColor ' +
	'backgroundImage border borderRadius bottom boxShadow boxSizing clear clip color columnGap content ' +
	'cursor display flex flexBasis flexDirection flexGrow flexShrink flexWrap float font fontFamily ' +
	'fontSize fontStyle fontWeight gap grid gridArea gridTemplateColumns height inset justifyContent ' +
	'left letterSpacing lineHeight listStyle margin marginBottom marginLeft marginRight marginTop ' +
	'maxHeight maxWidth minHeight minWidth objectFit opacity order outline overflow overflowX overflowY ' +
	'padding paddingBottom paddingLeft paddingRight paddingTop pointerEvents position right rowGap ' +
	'textAlign textDecoration textOverflow textTransform top transform transition userSelect ' +
	'verticalAlign visibility whiteSpace width wordBreak zIndex aspectRatio scrollBehavior').split(' '));

const STYLES = new Map();

function inlinestyle(i) {
	let s = STYLES.get(i);
	if (!s) {
		s = styledecl({
			readonly: false,
			decls: () => parsedecls(N.attr(i, 'style')),
			save: (m) => {
				const t = unparsedecls(m);
				if (t === '')
					delattr(i, 'style');
				else
					setattr(i, 'style', t);
			},
		});
		STYLES.set(i, s);
	}
	return s;
}

function computedstyle(i) {
	const props = () => {
		const m = new Map();
		return m;
	};
	return styledecl({
		readonly: true,
		decls: () => ({
			get: (name) => [N.computed(i, name), ''],
			has: () => true,
			keys: () => [][Symbol.iterator](),
			size: 0,
		}),
		save() {},
	});
}

const DATASETS = new Map();

function dataset(i) {
	let d = DATASETS.get(i);
	if (d)
		return d;
	const attr = (k) => 'data-' + str(k).replace(/[A-Z]/g, (c) => '-' + lower(c));
	const prop = (a) => a.slice(5).replace(/-([a-z])/g, (m, c) => upper(c));
	d = new Proxy({}, {
		get(t, k) {
			if (typeof k === 'symbol')
				return undefined;
			const v = N.attr(i, attr(k));
			return v === null ? undefined : v;
		},
		set(t, k, v) {
			if (typeof k === 'string')
				setattr(i, attr(k), str(v));
			return true;
		},
		deleteProperty(t, k) {
			if (typeof k === 'string')
				delattr(i, attr(k));
			return true;
		},
		has(t, k) {
			return typeof k === 'string' && N.attr(i, attr(k)) !== null;
		},
		ownKeys() {
			const a = N.attrs(i), r = [];
			for (let k = 0; k < a.length; k += 2)
				if (a[k].startsWith('data-'))
					r.push(prop(a[k]));
			return r;
		},
		getOwnPropertyDescriptor(t, k) {
			const v = typeof k === 'string' ? N.attr(i, attr(k)) : null;
			return v === null ? undefined : {value: v, writable: true, enumerable: true, configurable: true};
		},
	});
	DATASETS.set(i, d);
	return d;
}

// ---- HTML elements ----

let focused = 0;

class HTMLElement extends Element {
	constructor(key, i) {
		if (key === KEY) {
			super(KEY, i);
			return;
		}
		// a custom element's constructor, through new or an upgrade
		const def = CUSTOMBYCTOR.get(new.target);
		if (!def)
			throw new TypeError('Illegal constructor');
		const n = upgrading || N.create(ELEMENT, def.name, 0);
		upgrading = 0;
		super(KEY, n);
		W[n] = this;
	}
	get style() { return inlinestyle(idof(this)); }
	set style(v) { setattr(idof(this), 'style', str(v)); }
	get dataset() { return dataset(idof(this)); }
	get innerText() { return N.textof(idof(this)); }
	set innerText(v) { this.textContent = v; }
	get outerText() { return N.textof(idof(this)); }
	get hidden() { return N.attr(idof(this), 'hidden') !== null; }
	set hidden(v) { if (v) setattr(idof(this), 'hidden', ''); else delattr(idof(this), 'hidden'); }
	get tabIndex() {
		const v = N.attr(idof(this), 'tabindex');
		if (v !== null && /^-?\d+$/.test(v.trim()))
			return +v;
		return ['a', 'button', 'input', 'select', 'textarea'].includes(N.name(idof(this))) ? 0 : -1;
	}
	set tabIndex(v) { setattr(idof(this), 'tabindex', str(v | 0)); }
	get offsetWidth() { return clientsize(idof(this), 3); }
	get offsetHeight() { return clientsize(idof(this), 4); }
	get offsetTop() { const b = N.box(idof(this)); return b[0] ? b[2] : 0; }
	get offsetLeft() { const b = N.box(idof(this)); return b[0] ? b[1] : 0; }
	get offsetParent() {
		const i = idof(this);
		if (!N.box(i)[0] || i === rootel() || N.name(i) === 'body')
			return null;
		return document.body;
	}
	get contentEditable() { return N.attr(idof(this), 'contenteditable') || 'inherit'; }
	set contentEditable(v) { setattr(idof(this), 'contenteditable', str(v)); }
	get isContentEditable() { const v = N.attr(idof(this), 'contenteditable'); return v === '' || v === 'true'; }
	focus() {
		const old = focused, i = idof(this);
		if (old === i)
			return;
		focused = i;
		if (old && W[old])
			fire(W[old], 'blur', {}, FocusEvent), fire(W[old], 'focusout', {bubbles: true}, FocusEvent);
		fire(this, 'focus', {}, FocusEvent);
		fire(this, 'focusin', {bubbles: true}, FocusEvent);
	}
	blur() {
		if (focused === idof(this)) {
			focused = 0;
			fire(this, 'blur', {}, FocusEvent);
			fire(this, 'focusout', {bubbles: true}, FocusEvent);
		}
	}
	click() {
		if (this.disabled)
			return;
		const ev = new MouseEvent('click', {bubbles: true, cancelable: true, composed: true});
		if (dispatch(this, ev))
			defaultaction(idof(this), null);
	}
	get accessKey() { return N.attr(idof(this), 'accesskey') || ''; }
	get draggable() { return N.attr(idof(this), 'draggable') === 'true'; }
	get spellcheck() { return N.attr(idof(this), 'spellcheck') !== 'false'; }
	get inert() { return N.attr(idof(this), 'inert') !== null; }
	get popover() { return N.attr(idof(this), 'popover'); }
	showPopover() {}
	hidePopover() {}
	togglePopover() { return false; }
	attachInternals() {
		return {setFormValue() {}, setValidity() {}, checkValidity: () => true, reportValidity: () => true,
			states: new Set(), form: null, labels: []};
	}
}
handlerprops(HTMLElement.prototype, EVENTNAMES);

// reflected attributes: [property, attribute, kind], kind s string, b
// boolean, n integer, u URL, e enumerated (lower case)
function reflect(C, list) {
	for (const [prop, a, kind, dflt] of list) {
		const attr = a || prop.toLowerCase();
		let get, set;
		switch (kind) {
		case 'b':
			get = function () { return N.attr(idof(this), attr) !== null; };
			set = function (v) { if (v) setattr(idof(this), attr, ''); else delattr(idof(this), attr); };
			break;
		case 'n':
			get = function () {
				const v = N.attr(idof(this), attr);
				const n = v === null ? NaN : parseInt(v, 10);
				return isNaN(n) ? (dflt === undefined ? 0 : dflt) : n;
			};
			set = function (v) { setattr(idof(this), attr, str(v | 0)); };
			break;
		case 'u':
			get = function () {
				const v = N.attr(idof(this), attr);
				if (v === null)
					return '';
				const u = parseurl(v.trim(), baseurl());
				return u ? serialize(u) : v;
			};
			set = function (v) { setattr(idof(this), attr, str(v)); };
			break;
		case 'e':
			get = function () {
				const v = N.attr(idof(this), attr);
				return v === null ? (dflt || '') : v.toLowerCase();
			};
			set = function (v) { setattr(idof(this), attr, str(v)); };
			break;
		default:
			get = function () {
				const v = N.attr(idof(this), attr);
				return v === null ? (dflt || '') : v;
			};
			set = function (v) { setattr(idof(this), attr, str(v)); };
		}
		defineProperty(C.prototype, prop, {get, set, enumerable: true, configurable: true});
	}
}

reflect(HTMLElement, [['title'], ['lang'], ['dir', 'dir', 'e'], ['translate', 'translate', 'b'],
	['nonce'], ['autofocus', 'autofocus', 'b'], ['enterKeyHint', 'enterkeyhint'], ['inputMode', 'inputmode']]);

// the parts of a URL, as HTMLAnchorElement and Location have them
function urlparts(C, getu, setu) {
	for (const p of ['protocol', 'username', 'password', 'host', 'hostname', 'port', 'pathname', 'search', 'hash']) {
		defineProperty(C.prototype, p, {
			get() {
				const u = getu(this);
				return u ? URLPARTS[p].get(u) : '';
			},
			set(v) {
				const u = getu(this);
				if (!u)
					return;
				URLPARTS[p].set(u, str(v));
				setu(this, serialize(u));
			},
			enumerable: true, configurable: true,
		});
	}
	defineProperty(C.prototype, 'origin', {get() { const u = getu(this); return u ? origin(u) : ''; }, configurable: true});
}

const HTMLCLASSES = {};

function htmlclass(name, tags, props, base = HTMLElement) {
	const C = {[name]: class extends base {}}[name];
	if (props)
		reflect(C, props);
	for (const t of tags)
		HTMLCLASSES[t] = C;
	globals({[name]: C});
	return C;
}

const HTMLAnchorElement = htmlclass('HTMLAnchorElement', ['a'], [['href', 'href', 'u'], ['target'],
	['rel'], ['download'], ['hreflang'], ['type'], ['referrerPolicy', 'referrerpolicy'], ['ping']]);
hidden(HTMLAnchorElement.prototype, {toString() { return this.href; }});
defineProperty(HTMLAnchorElement.prototype, 'text', {get() { return this.textContent; }, set(v) { this.textContent = v; }, configurable: true});
defineProperty(HTMLAnchorElement.prototype, 'relList', {get() { return new DOMTokenList(KEY, idof(this), 'rel'); }, set(v) { setattr(idof(this), 'rel', str(v)); }, configurable: true});
urlparts(HTMLAnchorElement, (a) => { const h = N.attr(idof(a), 'href'); return h === null ? null : parseurl(h.trim(), baseurl()); },
	(a, v) => setattr(idof(a), 'href', v));
const HTMLAreaElement = htmlclass('HTMLAreaElement', ['area'], [['href', 'href', 'u'], ['alt'], ['coords'], ['shape'], ['target'], ['rel']]);
const HTMLScriptElement = htmlclass('HTMLScriptElement', ['script'], [['src', 'src', 'u'], ['type'],
	['charset'], ['defer', 'defer', 'b'], ['noModule', 'nomodule', 'b'], ['integrity'], ['crossOrigin', 'crossorigin'],
	['referrerPolicy', 'referrerpolicy'], ['event'], ['htmlFor', 'for'], ['fetchPriority', 'fetchpriority']]);
defineProperty(HTMLScriptElement.prototype, 'async', {
	get() { return N.attr(idof(this), 'async') !== null || !PARSERSCRIPT.has(idof(this)) && !ASYNCOFF.has(idof(this)); },
	set(v) { if (v) setattr(idof(this), 'async', ''); else { delattr(idof(this), 'async'); ASYNCOFF.add(idof(this)); } },
	configurable: true});
defineProperty(HTMLScriptElement.prototype, 'text', {get() { return N.textof(idof(this)); }, set(v) { this.textContent = v; }, configurable: true});
hidden(HTMLScriptElement, {supports(t) { return t === 'classic' || t === 'module'; }});
const HTMLLinkElement = htmlclass('HTMLLinkElement', ['link'], [['href', 'href', 'u'], ['rel'], ['type'],
	['media'], ['as'], ['crossOrigin', 'crossorigin'], ['hreflang'], ['integrity'], ['sizes'], ['disabled', 'disabled', 'b'],
	['referrerPolicy', 'referrerpolicy'], ['fetchPriority', 'fetchpriority'], ['imageSrcset', 'imagesrcset']]);
defineProperty(HTMLLinkElement.prototype, 'relList', {get() { return new DOMTokenList(KEY, idof(this), 'rel'); }, set(v) { setattr(idof(this), 'rel', str(v)); }, configurable: true});
defineProperty(HTMLLinkElement.prototype, 'sheet', {get() {
	const i = idof(this);
	return connected(i) && /(^|\s)stylesheet(\s|$)/i.test(N.attr(i, 'rel') || '') ? stylesheet(i) : null;
}, configurable: true});
const HTMLImageElement = htmlclass('HTMLImageElement', ['img'], [['src', 'src', 'u'], ['alt'], ['srcset'],
	['sizes'], ['crossOrigin', 'crossorigin'], ['useMap', 'usemap'], ['isMap', 'ismap', 'b'], ['loading', 'loading', 'e', 'eager'],
	['decoding', 'decoding', 'e', 'auto'], ['referrerPolicy', 'referrerpolicy'], ['fetchPriority', 'fetchpriority']]);
for (const d of ['width', 'height'])
	defineProperty(HTMLImageElement.prototype, d, {
		get() {
			const b = N.box(idof(this));
			if (b[0])
				return b[d === 'width' ? 3 : 4];
			const v = parseInt(N.attr(idof(this), d), 10);
			return isNaN(v) ? 0 : v;
		},
		set(v) { setattr(idof(this), d, str(v | 0)); },
		configurable: true});
hidden(HTMLImageElement.prototype, {decode() { return Promise.resolve(); }});
for (const [p, v] of [['complete', true], ['naturalWidth', 0], ['naturalHeight', 0]])
	defineProperty(HTMLImageElement.prototype, p, {get() { return v; }, configurable: true});
defineProperty(HTMLImageElement.prototype, 'currentSrc', {get() { return this.src; }, configurable: true});

function formcontrol(C) {
	defineProperty(C.prototype, 'form', {
		get() {
			const f = N.attr(idof(this), 'form');
			if (f !== null)
				return document.getElementById(f);
			return this.closest('form');
		}, configurable: true});
	hidden(C.prototype, {
		checkValidity() { return true; },
		reportValidity() { return true; },
		setCustomValidity() {},
	});
	defineProperty(C.prototype, 'validity', {get() { return {valid: true, valueMissing: false, typeMismatch: false, patternMismatch: false, tooLong: false, tooShort: false, rangeUnderflow: false, rangeOverflow: false, stepMismatch: false, badInput: false, customError: false}; }, configurable: true});
	defineProperty(C.prototype, 'willValidate', {get() { return true; }, configurable: true});
	defineProperty(C.prototype, 'validationMessage', {get() { return ''; }, configurable: true});
	defineProperty(C.prototype, 'labels', {get() {
		const id = this.id;
		return new NodeList(KEY, id ? select(1, 'label[for="' + id.replace(/"/g, '\\"') + '"]', true).map(wrap) : []);
	}, configurable: true});
}

// Charon keeps a control's state in its attributes: the value attribute
// is the value, checked is checkedness
const HTMLInputElement = htmlclass('HTMLInputElement', ['input'], [['name'], ['disabled', 'disabled', 'b'],
	['placeholder'], ['readOnly', 'readonly', 'b'], ['required', 'required', 'b'], ['autocomplete'],
	['accept'], ['alt'], ['max'], ['min'], ['step'], ['pattern'], ['multiple', 'multiple', 'b'],
	['maxLength', 'maxlength', 'n', -1], ['minLength', 'minlength', 'n', -1], ['size', 'size', 'n', 20],
	['src', 'src', 'u'], ['formAction', 'formaction', 'u'], ['formMethod', 'formmethod'], ['dirName', 'dirname'],
	['defaultValue', 'value'], ['defaultChecked', 'checked', 'b'], ['indeterminate', 'data-indeterminate', 'b']]);
defineProperty(HTMLInputElement.prototype, 'type', {
	get() {
		const t = (N.attr(idof(this), 'type') || '').toLowerCase();
		return INPUTTYPES.has(t) ? t : 'text';
	},
	set(v) { setattr(idof(this), 'type', str(v)); }, configurable: true});
const INPUTTYPES = new Set(['hidden', 'text', 'search', 'tel', 'url', 'email', 'password', 'date', 'month',
	'week', 'time', 'datetime-local', 'number', 'range', 'color', 'checkbox', 'radio', 'file', 'submit',
	'image', 'reset', 'button']);
defineProperty(HTMLInputElement.prototype, 'value', {
	get() {
		const v = N.attr(idof(this), 'value');
		if (v === null)
			return this.type === 'checkbox' || this.type === 'radio' ? 'on' : '';
		return v;
	},
	set(v) { setattr(idof(this), 'value', v === null ? '' : str(v)); }, configurable: true});
defineProperty(HTMLInputElement.prototype, 'checked', {
	get() { return N.attr(idof(this), 'checked') !== null; },
	set(v) {
		const i = idof(this);
		if (v) {
			if (this.type === 'radio' && this.name)
				for (const r of select(1, 'input[type=radio]', true))
					if (r !== i && N.attr(r, 'name') === this.name)
						delattr(r, 'checked');
			setattr(i, 'checked', '');
		} else
			delattr(i, 'checked');
	}, configurable: true});
defineProperty(HTMLInputElement.prototype, 'valueAsNumber', {get() { return parseFloat(this.value); }, set(v) { this.value = str(v); }, configurable: true});
defineProperty(HTMLInputElement.prototype, 'files', {get() { return null; }, configurable: true});
defineProperty(HTMLInputElement.prototype, 'list', {get() { const l = N.attr(idof(this), 'list'); return l ? document.getElementById(l) : null; }, configurable: true});
hidden(HTMLInputElement.prototype, {
	select() {}, setSelectionRange() {}, setRangeText() {}, showPicker() {},
	stepUp() {}, stepDown() {},
});
for (const p of ['selectionStart', 'selectionEnd'])
	defineProperty(HTMLInputElement.prototype, p, {get() { return this.value.length; }, set(v) {}, configurable: true});
formcontrol(HTMLInputElement);
const HTMLTextAreaElement = htmlclass('HTMLTextAreaElement', ['textarea'], [['name'], ['disabled', 'disabled', 'b'],
	['placeholder'], ['readOnly', 'readonly', 'b'], ['required', 'required', 'b'], ['rows', 'rows', 'n', 2],
	['cols', 'cols', 'n', 20], ['wrap'], ['autocomplete'], ['maxLength', 'maxlength', 'n', -1]]);
defineProperty(HTMLTextAreaElement.prototype, 'value', {get() { return N.textof(idof(this)); }, set(v) { this.textContent = v; }, configurable: true});
defineProperty(HTMLTextAreaElement.prototype, 'defaultValue', {get() { return N.textof(idof(this)); }, set(v) { this.textContent = v; }, configurable: true});
defineProperty(HTMLTextAreaElement.prototype, 'type', {get() { return 'textarea'; }, configurable: true});
hidden(HTMLTextAreaElement.prototype, {select() {}, setSelectionRange() {}, setRangeText() {}});
for (const p of ['selectionStart', 'selectionEnd'])
	defineProperty(HTMLTextAreaElement.prototype, p, {get() { return this.value.length; }, set(v) {}, configurable: true});
formcontrol(HTMLTextAreaElement);
const HTMLButtonElement = htmlclass('HTMLButtonElement', ['button'], [['name'], ['disabled', 'disabled', 'b'],
	['value'], ['formAction', 'formaction', 'u'], ['formMethod', 'formmethod'], ['formNoValidate', 'formnovalidate', 'b']]);
defineProperty(HTMLButtonElement.prototype, 'type', {
	get() { const t = (N.attr(idof(this), 'type') || '').toLowerCase(); return t === 'reset' || t === 'button' ? t : 'submit'; },
	set(v) { setattr(idof(this), 'type', str(v)); }, configurable: true});
formcontrol(HTMLButtonElement);
const HTMLOptionElement = htmlclass('HTMLOptionElement', ['option'], [['disabled', 'disabled', 'b'], ['label'],
	['defaultSelected', 'selected', 'b']]);
defineProperty(HTMLOptionElement.prototype, 'value', {
	get() { const v = N.attr(idof(this), 'value'); return v === null ? N.textof(idof(this)).trim().replace(/\s+/g, ' ') : v; },
	set(v) { setattr(idof(this), 'value', str(v)); }, configurable: true});
defineProperty(HTMLOptionElement.prototype, 'text', {get() { return N.textof(idof(this)).trim().replace(/\s+/g, ' '); }, set(v) { this.textContent = v; }, configurable: true});
defineProperty(HTMLOptionElement.prototype, 'selected', {
	get() { return N.attr(idof(this), 'selected') !== null; },
	set(v) {
		const i = idof(this);
		const sel = this.closest('select');
		if (v && sel && !sel.multiple)
			for (const o of select(idof(sel), 'option', true))
				delattr(o, 'selected');
		if (v) setattr(i, 'selected', ''); else delattr(i, 'selected');
	}, configurable: true});
defineProperty(HTMLOptionElement.prototype, 'index', {get() {
	const sel = this.closest('select');
	return sel ? select(idof(sel), 'option', true).indexOf(idof(this)) : 0;
}, configurable: true});
defineProperty(HTMLOptionElement.prototype, 'form', {get() { return this.closest('form'); }, configurable: true});
const HTMLSelectElement = htmlclass('HTMLSelectElement', ['select'], [['name'], ['disabled', 'disabled', 'b'],
	['multiple', 'multiple', 'b'], ['required', 'required', 'b'], ['size', 'size', 'n', 0], ['autocomplete']]);
defineProperty(HTMLSelectElement.prototype, 'options', {get() {
	const c = collection(select(idof(this), 'option', true));
	const sel = this;
	hidden(c, {add(o, before) { sel.add(o, before); }, remove(k) { sel.remove(k); }});
	defineProperty(c, 'selectedIndex', {get() { return sel.selectedIndex; }, set(v) { sel.selectedIndex = v; }});
	return c;
}, configurable: true});
defineProperty(HTMLSelectElement.prototype, 'selectedOptions', {get() {
	return collection(select(idof(this), 'option', true).filter((o) => N.attr(o, 'selected') !== null));
}, configurable: true});
defineProperty(HTMLSelectElement.prototype, 'selectedIndex', {
	get() {
		const os = select(idof(this), 'option', true);
		const k = os.findIndex((o) => N.attr(o, 'selected') !== null);
		return k >= 0 || this.multiple ? k : os.length ? 0 : -1;
	},
	set(v) {
		const os = select(idof(this), 'option', true);
		for (const o of os)
			delattr(o, 'selected');
		if (v >= 0 && v < os.length)
			setattr(os[v], 'selected', '');
	}, configurable: true});
defineProperty(HTMLSelectElement.prototype, 'value', {
	get() { const k = this.selectedIndex; return k < 0 ? '' : wrap(select(idof(this), 'option', true)[k]).value; },
	set(v) {
		const os = select(idof(this), 'option', true);
		this.selectedIndex = os.findIndex((o) => wrap(o).value === str(v));
	}, configurable: true});
defineProperty(HTMLSelectElement.prototype, 'length', {get() { return select(idof(this), 'option', true).length; }, configurable: true});
defineProperty(HTMLSelectElement.prototype, 'type', {get() { return this.multiple ? 'select-multiple' : 'select-one'; }, configurable: true});
hidden(HTMLSelectElement.prototype, {
	item(k) { return wrap(select(idof(this), 'option', true)[k] || 0); },
	namedItem(name) { return this.options.namedItem(name); },
	add(o, before) { this.insertBefore(o, typeof before === 'number' ? this.options[before] || null : before || null); },
	remove(k) { if (arguments.length === 0) Element.prototype.remove.call(this); else { const o = this.item(k); if (o) o.remove(); } },
});
formcontrol(HTMLSelectElement);
const HTMLFormElement = htmlclass('HTMLFormElement', ['form'], [['action', 'action', 'u'], ['method', 'method', 'e', 'get'],
	['target'], ['name'], ['enctype', 'enctype', 'e', 'application/x-www-form-urlencoded'], ['acceptCharset', 'accept-charset'],
	['noValidate', 'novalidate', 'b'], ['autocomplete'], ['rel']]);
defineProperty(HTMLFormElement.prototype, 'elements', {get() {
	return collection(select(idof(this), 'input,select,textarea,button,fieldset,output,object', true));
}, configurable: true});
defineProperty(HTMLFormElement.prototype, 'length', {get() { return this.elements.length; }, configurable: true});
hidden(HTMLFormElement.prototype, {
	submit() { submitform(idof(this), 0); },
	requestSubmit(submitter) {
		if (fire(this, 'submit', {bubbles: true, cancelable: true, submitter: submitter || null}, SubmitEvent))
			submitform(idof(this), submitter ? idof(submitter) : 0);
	},
	reset() {
		if (fire(this, 'reset', {bubbles: true, cancelable: true}))
			for (const c of select(idof(this), 'input', true))
				N.attr(c, 'type') !== 'hidden' && delattr(c, 'value');
	},
	checkValidity() { return true; },
	reportValidity() { return true; },
});
htmlclass('HTMLFieldSetElement', ['fieldset'], [['disabled', 'disabled', 'b'], ['name']]);
htmlclass('HTMLLabelElement', ['label'], [['htmlFor', 'for']]);
defineProperty(G.HTMLLabelElement.prototype, 'control', {get() { const f = N.attr(idof(this), 'for'); return f ? document.getElementById(f) : this.querySelector('input,select,textarea,button'); }, configurable: true});
htmlclass('HTMLLegendElement', ['legend']);
htmlclass('HTMLOutputElement', ['output'], [['name'], ['htmlFor', 'for']]);
htmlclass('HTMLMetaElement', ['meta'], [['name'], ['content'], ['httpEquiv', 'http-equiv'], ['charset'], ['media']]);
htmlclass('HTMLStyleElement', ['style'], [['type'], ['media'], ['disabled', 'disabled', 'b'], ['nonce']]);
defineProperty(G.HTMLStyleElement.prototype, 'sheet', {get() { return connected(idof(this)) ? stylesheet(idof(this)) : null; }, configurable: true});
htmlclass('HTMLBaseElement', ['base'], [['href', 'href', 'u'], ['target']]);
htmlclass('HTMLTitleElement', ['title']);
defineProperty(G.HTMLTitleElement.prototype, 'text', {get() { return N.textof(idof(this)); }, set(v) { this.textContent = v; }, configurable: true});
const HTMLIFrameElement = htmlclass('HTMLIFrameElement', ['iframe'], [['src', 'src', 'u'], ['srcdoc'], ['name'],
	['allow'], ['allowFullscreen', 'allowfullscreen', 'b'], ['width'], ['height'], ['loading'], ['referrerPolicy', 'referrerpolicy']]);
defineProperty(HTMLIFrameElement.prototype, 'sandbox', {get() { return new DOMTokenList(KEY, idof(this), 'sandbox'); }, set(v) { setattr(idof(this), 'sandbox', str(v)); }, configurable: true});
for (const p of ['contentWindow', 'contentDocument'])
	defineProperty(HTMLIFrameElement.prototype, p, {get() { return null; }, configurable: true});
htmlclass('HTMLFrameElement', ['frame'], [['src', 'src', 'u'], ['name']]);
htmlclass('HTMLEmbedElement', ['embed'], [['src', 'src', 'u'], ['type'], ['width'], ['height']]);
htmlclass('HTMLObjectElement', ['object'], [['data', 'data', 'u'], ['type'], ['name'], ['width'], ['height']]);
const HTMLTemplateElement = htmlclass('HTMLTemplateElement', ['template']);
defineProperty(HTMLTemplateElement.prototype, 'content', {get() { return wrap(templatecontent(idof(this))); }, configurable: true});
const HTMLCanvasElement = htmlclass('HTMLCanvasElement', ['canvas'], [['width', 'width', 'n', 300], ['height', 'height', 'n', 150]]);
hidden(HTMLCanvasElement.prototype, {
	getContext() { return null; },
	toDataURL() { return 'data:,'; },
	toBlob(cb) { setTimeout(() => cb(null), 0); },
});
const HTMLMediaElement = htmlclass('HTMLMediaElement', [], [['src', 'src', 'u'], ['autoplay', 'autoplay', 'b'],
	['controls', 'controls', 'b'], ['loop', 'loop', 'b'], ['muted', 'muted', 'b'], ['preload'],
	['crossOrigin', 'crossorigin'], ['poster', 'poster', 'u'], ['playsInline', 'playsinline', 'b']]);
hidden(HTMLMediaElement.prototype, {
	play() { return Promise.reject(domerr('NotSupportedError', 'media is not supported')); },
	pause() {}, load() {},
	canPlayType() { return ''; },
});
for (const [p, v] of [['paused', true], ['ended', false], ['currentTime', 0], ['duration', NaN], ['volume', 1],
	['readyState', 0], ['networkState', 0], ['playbackRate', 1], ['buffered', {length: 0}], ['error', null],
	['currentSrc', ''], ['videoWidth', 0], ['videoHeight', 0], ['textTracks', []]])
	defineProperty(HTMLMediaElement.prototype, p, {get() { return v; }, set(x) {}, configurable: true});
htmlclass('HTMLVideoElement', ['video'], null, HTMLMediaElement);
htmlclass('HTMLAudioElement', ['audio'], null, HTMLMediaElement);
htmlclass('HTMLSourceElement', ['source'], [['src', 'src', 'u'], ['type'], ['srcset'], ['sizes'], ['media']]);
htmlclass('HTMLTrackElement', ['track'], [['src', 'src', 'u'], ['kind'], ['label'], ['srclang']]);
htmlclass('HTMLPictureElement', ['picture']);
htmlclass('HTMLBodyElement', ['body']);
handlerprops(G.HTMLBodyElement.prototype, WINDOWEVENTS);
htmlclass('HTMLHeadElement', ['head']);
htmlclass('HTMLHtmlElement', ['html'], [['version']]);
htmlclass('HTMLDivElement', ['div'], [['align']]);
htmlclass('HTMLSpanElement', ['span']);
htmlclass('HTMLParagraphElement', ['p'], [['align']]);
htmlclass('HTMLHeadingElement', ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'], [['align']]);
htmlclass('HTMLUListElement', ['ul'], [['type']]);
htmlclass('HTMLOListElement', ['ol'], [['start', 'start', 'n', 1], ['reversed', 'reversed', 'b'], ['type']]);
htmlclass('HTMLLIElement', ['li'], [['value', 'value', 'n']]);
htmlclass('HTMLDListElement', ['dl']);
htmlclass('HTMLPreElement', ['pre', 'listing', 'xmp']);
htmlclass('HTMLQuoteElement', ['blockquote', 'q'], [['cite', 'cite', 'u']]);
htmlclass('HTMLBRElement', ['br']);
htmlclass('HTMLHRElement', ['hr']);
htmlclass('HTMLTableElement', ['table']);
defineProperty(G.HTMLTableElement.prototype, 'rows', {get() { return collection(select(idof(this), 'tr', true)); }, configurable: true});
defineProperty(G.HTMLTableElement.prototype, 'tBodies', {get() { return collection(N.children(idof(this), true).filter((c) => N.name(c) === 'tbody')); }, configurable: true});
htmlclass('HTMLTableSectionElement', ['tbody', 'thead', 'tfoot']);
defineProperty(G.HTMLTableSectionElement.prototype, 'rows', {get() { return collection(N.children(idof(this), true).filter((c) => N.name(c) === 'tr')); }, configurable: true});
htmlclass('HTMLTableRowElement', ['tr']);
defineProperty(G.HTMLTableRowElement.prototype, 'cells', {get() { return collection(N.children(idof(this), true).filter((c) => N.name(c) === 'td' || N.name(c) === 'th')); }, configurable: true});
htmlclass('HTMLTableCellElement', ['td', 'th'], [['colSpan', 'colspan', 'n', 1], ['rowSpan', 'rowspan', 'n', 1], ['headers'], ['scope']]);
htmlclass('HTMLTableCaptionElement', ['caption']);
htmlclass('HTMLTableColElement', ['col', 'colgroup'], [['span', 'span', 'n', 1]]);
htmlclass('HTMLDetailsElement', ['details'], [['open', 'open', 'b'], ['name']]);
htmlclass('HTMLDialogElement', ['dialog'], [['open', 'open', 'b']]);
hidden(G.HTMLDialogElement.prototype, {
	show() { this.open = true; },
	showModal() { this.open = true; },
	close(v) { this.open = false; if (v !== undefined) this.returnValue = str(v); fire(this, 'close', {}); },
});
htmlclass('HTMLMapElement', ['map'], [['name']]);
htmlclass('HTMLModElement', ['ins', 'del'], [['cite', 'cite', 'u'], ['dateTime', 'datetime']]);
htmlclass('HTMLTimeElement', ['time'], [['dateTime', 'datetime']]);
htmlclass('HTMLDataElement', ['data'], [['value']]);
htmlclass('HTMLDataListElement', ['datalist']);
htmlclass('HTMLOptGroupElement', ['optgroup'], [['disabled', 'disabled', 'b'], ['label']]);
htmlclass('HTMLProgressElement', ['progress'], [['max', 'max', 'n', 1]]);
htmlclass('HTMLMeterElement', ['meter']);
htmlclass('HTMLSlotElement', ['slot'], [['name']]);
hidden(G.HTMLSlotElement.prototype, {assignedNodes() { return []; }, assignedElements() { return []; }});
htmlclass('HTMLMenuElement', ['menu']);
htmlclass('HTMLParamElement', ['param'], [['name'], ['value']]);
htmlclass('HTMLFontElement', ['font'], [['color'], ['face'], ['size']]);
const HTMLUnknownElement = htmlclass('HTMLUnknownElement', []);
const KNOWNTAGS = new Set(('abbr address article aside b bdi bdo cite code dd dfn dt em figcaption figure footer ' +
	'header hgroup i kbd main mark nav noscript rp rt ruby s samp search section small strong sub summary sup u var ' +
	'wbr center tt big strike nobr acronym basefont bgsound blink marquee noembed noframes plaintext image').split(' '));

class SVGElement extends Element {
	get style() { return inlinestyle(idof(this)); }
	get dataset() { return dataset(idof(this)); }
	get ownerSVGElement() { return this.closest('svg'); }
	getBBox() { const r = this.getBoundingClientRect(); return {x: 0, y: 0, width: r.width, height: r.height}; }
	focus() {}
	blur() {}
}
handlerprops(SVGElement.prototype, EVENTNAMES);
class SVGGraphicsElement extends SVGElement {}
class SVGSVGElement extends SVGGraphicsElement {
	createSVGPoint() { return {x: 0, y: 0, matrixTransform() { return this; }}; }
}
class MathMLElement extends Element {
	get style() { return inlinestyle(idof(this)); }
}

class CharacterData extends Node {
	get data() { return N.data(idof(this)); }
	set data(v) { setdata(idof(this), v === null ? '' : str(v)); }
	get length() { return N.data(idof(this)).length; }
	appendData(s) { this.data += str(s); }
	substringData(o, n) { return this.data.substr(o, n); }
	insertData(o, s) { const d = this.data; this.data = d.slice(0, o) + str(s) + d.slice(o); }
	deleteData(o, n) { const d = this.data; this.data = d.slice(0, o) + d.slice(o + n); }
	replaceData(o, n, s) { const d = this.data; this.data = d.slice(0, o) + str(s) + d.slice(o + n); }
	get nextElementSibling() { return wrap(firstel(N.next(idof(this)))); }
	get previousElementSibling() { let c = N.prev(idof(this)); while (c && N.kind(c) !== ELEMENT) c = N.prev(c); return wrap(c); }
	remove() { removenode(idof(this)); }
	before(...nodes) { const p = N.parent(idof(this)); if (p) insertnode(p, nodesof(nodes), idof(this)); }
	after(...nodes) { const p = N.parent(idof(this)); if (p) insertnode(p, nodesof(nodes), N.next(idof(this))); }
	replaceWith(...nodes) { Element.prototype.replaceWith.apply(this, nodes); }
}

class Text extends CharacterData {
	constructor(data = '') {
		if (data === KEY) {
			super(KEY, arguments[1]);
			return;
		}
		const i = textnode(str(data));
		super(KEY, i);
		W[i] = this;
	}
	get wholeText() { return this.data; }
	splitText(o) {
		const d = this.data;
		const t = document.createTextNode(d.slice(o));
		this.data = d.slice(0, o);
		const p = N.parent(idof(this));
		if (p)
			insertnode(p, t, N.next(idof(this)));
		return t;
	}
	get assignedSlot() { return null; }
}

class CDATASection extends Text {}

class Comment extends CharacterData {
	constructor(data = '') {
		if (data === KEY) {
			super(KEY, arguments[1]);
			return;
		}
		const i = N.create(COMMENT, '#comment', 0);
		N.setdata(i, str(data));
		super(KEY, i);
		W[i] = this;
	}
}

class ProcessingInstruction extends CharacterData {}

class DocumentType extends Node {
	get name() { return N.name(idof(this)); }
	get publicId() { return ''; }
	get systemId() { return ''; }
	remove() { removenode(idof(this)); }
}

class DocumentFragment extends Node {
	constructor(key, i) {
		if (key === KEY) {
			super(KEY, i);
			return;
		}
		const f = N.create(DOCUMENT, '', 0);
		super(KEY, f);
		W[f] = this;
	}
	get children() { return collection(N.children(idof(this), true)); }
	get childElementCount() { return N.children(idof(this), true).length; }
	get firstElementChild() { return wrap(firstel(N.first(idof(this)))); }
	get lastElementChild() { let c = N.last(idof(this)); while (c && N.kind(c) !== ELEMENT) c = N.prev(c); return wrap(c); }
	getElementById(id) { return wrap(N.descendants(idof(this), 'id', str(id))); }
	querySelector(sel) { return wrap(select(idof(this), sel, false)); }
	querySelectorAll(sel) { return new NodeList(KEY, select(idof(this), sel, true).map(wrap)); }
	append(...nodes) { insertnode(idof(this), nodesof(nodes), 0); }
	prepend(...nodes) { insertnode(idof(this), nodesof(nodes), N.first(idof(this))); }
	replaceChildren(...nodes) { const f = nodesof(nodes); replaceall(idof(this), []); insertnode(idof(this), f, 0); }
	get innerHTML() { return N.markup(idof(this), false); }
	set innerHTML(v) { replaceall(idof(this), N.parse(str(v))); }
}

class ShadowRoot extends DocumentFragment {
	get host() { return this._host; }
	get mode() { return this._mode; }
	get delegatesFocus() { return false; }
	get activeElement() { return null; }
	get adoptedStyleSheets() { return []; }
	set adoptedStyleSheets(v) {}
}

// ---- custom elements ----

const CUSTOM = new Map(), CUSTOMBYCTOR = new Map(), WHENDEFINED = new Map();
let upgrading = 0;

class CustomElementRegistry {
	define(name, ctor, options) {
		name = str(name);
		if (!/^[a-z][-.0-9_a-z·À-￿]*-[-.0-9_a-z·À-￿]*$/.test(name))
			throw domerr('SyntaxError', "'" + name + "' is not a valid custom element name");
		if (CUSTOM.has(name))
			throw domerr('NotSupportedError', "the name '" + name + "' has already been used with this registry");
		if (typeof ctor !== 'function')
			throw new TypeError('the constructor is not a function');
		const def = {name, ctor, observed: (ctor.observedAttributes && [...ctor.observedAttributes]) || []};
		CUSTOM.set(name, def);
		CUSTOMBYCTOR.set(ctor, def);
		for (const e of N.descendants(1, 'name', name))
			upgrade(e, def);
		const w = WHENDEFINED.get(name);
		if (w) {
			w.resolve(ctor);
			WHENDEFINED.delete(name);
		}
	}
	get(name) {
		const d = CUSTOM.get(str(name));
		return d ? d.ctor : undefined;
	}
	getName(ctor) {
		const d = CUSTOMBYCTOR.get(ctor);
		return d ? d.name : null;
	}
	whenDefined(name) {
		name = str(name);
		const d = CUSTOM.get(name);
		if (d)
			return Promise.resolve(d.ctor);
		let w = WHENDEFINED.get(name);
		if (!w) {
			let resolve;
			const p = new Promise((r) => { resolve = r; });
			WHENDEFINED.set(name, w = {promise: p, resolve});
		}
		return w.promise;
	}
	upgrade(root) {
		for (const e of [idof(root), ...N.descendants(idof(root), 'name', '*')]) {
			const d = CUSTOM.get(N.name(e));
			if (d)
				upgrade(e, d);
		}
	}
}

function upgrade(i, def) {
	const old = W[i];
	if (old && Object.getPrototypeOf(old) === def.ctor.prototype)
		return;
	delete W[i];
	upgrading = i;
	let w;
	try {
		w = Reflect.construct(def.ctor, []);
	} catch (x) {
		upgrading = 0;
		W[i] = old;
		report(x);
		return;
	}
	upgrading = 0;
	if (old && old !== w)
		for (const k of Reflect.ownKeys(old))
			try { w[k] = old[k]; } catch (x) {}
	for (const a of def.observed) {
		const v = N.attr(i, a);
		if (v !== null && typeof w.attributeChangedCallback === 'function')
			try { w.attributeChangedCallback(a, null, v); } catch (x) { report(x); }
	}
	if (connected(i) && typeof w.connectedCallback === 'function')
		try { w.connectedCallback(); } catch (x) { report(x); }
}

function attrchanged(i, name, old, v) {
	const w = W[i];
	if (!w || N.name(i).indexOf('-') < 0)
		return;
	const def = CUSTOM.get(N.name(i));
	if (def && def.observed.includes(name) && typeof w.attributeChangedCallback === 'function')
		try { w.attributeChangedCallback(name, old, v); } catch (x) { report(x); }
}

// ---- wrappers ----

function classof(i) {
	switch (N.kind(i)) {
	case ELEMENT: {
		const ns = N.ns(i), name = N.name(i);
		if (ns === 1)
			return name === 'svg' ? SVGSVGElement : SVGElement;
		if (ns === 2)
			return MathMLElement;
		const C = HTMLCLASSES[name];
		if (C)
			return C;
		if (name.indexOf('-') > 0 || KNOWNTAGS.has(name))
			return HTMLElement;
		return HTMLUnknownElement;
	}
	case TEXT: return Text;
	case COMMENT: return Comment;
	case DOCTYPE: return DocumentType;
	default: return i === 1 ? HTMLDocument : DocumentFragment;
	}
}

function wrap(i) {
	if (!i)
		return null;
	let w = W[i];
	if (w)
		return w;
	if (N.kind(i) === ELEMENT && N.ns(i) === 0) {
		const def = CUSTOM.get(N.name(i));
		if (def) {
			upgrading = i;
			try {
				w = Reflect.construct(def.ctor, []);
				upgrading = 0;
				return w;
			} catch (x) {
				upgrading = 0;
				report(x);
			}
		}
	}
	const C = classof(i);
	w = new C(KEY, i);
	W[i] = w;
	return w;
}

// ---- URLs (the WHATWG URL Standard, in the main; no IDNA) ----

const SPECIAL = {'ftp:': '21', 'file:': '', 'http:': '80', 'https:': '443', 'ws:': '80', 'wss:': '443'};
const C0SET = '', FRAGSET = ' "<>`', QUERYSET = ' "#<>', SQUERYSET = ' "#<>\'',
	PATHSET = ' "#<>?`{}^', USERSET = ' "#<>?`{}/:;=@[\\]^|';

function utf8(s) {
	const b = [];
	for (let k = 0; k < s.length; k++) {
		let c = s.charCodeAt(k);
		if (c >= 0xd800 && c <= 0xdbff && k + 1 < s.length) {
			const d = s.charCodeAt(k + 1);
			if (d >= 0xdc00 && d <= 0xdfff) {
				c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
				k++;
			} else
				c = 0xfffd;
		} else if (c >= 0xd800 && c <= 0xdfff)
			c = 0xfffd;
		if (c < 0x80)
			b.push(c);
		else if (c < 0x800)
			b.push(0xc0 | c >> 6, 0x80 | c & 63);
		else if (c < 0x10000)
			b.push(0xe0 | c >> 12, 0x80 | c >> 6 & 63, 0x80 | c & 63);
		else
			b.push(0xf0 | c >> 18, 0x80 | c >> 12 & 63, 0x80 | c >> 6 & 63, 0x80 | c & 63);
	}
	return b;
}

function unutf8(b, start = 0, end = b.length) {
	let s = '';
	for (let k = start; k < end; ) {
		const c = b[k];
		let cp, n;
		if (c < 0x80) { cp = c; n = 1; }
		else if (c >= 0xc2 && c < 0xe0) { cp = c & 31; n = 2; }
		else if (c >= 0xe0 && c < 0xf0) { cp = c & 15; n = 3; }
		else if (c >= 0xf0 && c < 0xf5) { cp = c & 7; n = 4; }
		else { s += '�'; k++; continue; }
		let ok = k + n <= end;
		for (let j = 1; ok && j < n; j++) {
			if ((b[k + j] & 0xc0) !== 0x80)
				ok = false;
			else
				cp = cp << 6 | b[k + j] & 63;
		}
		if (!ok || n === 3 && (cp < 0x800 || cp >= 0xd800 && cp <= 0xdfff) || n === 4 && (cp < 0x10000 || cp > 0x10ffff)) {
			s += '�';
			k++;
			continue;
		}
		s += String.fromCodePoint(cp);
		k += n;
	}
	return s;
}

const HEX = '0123456789ABCDEF';

function pct(s, set) {
	let r = '';
	for (let k = 0; k < s.length; k++) {
		const c = s.charCodeAt(k);
		if (c > 0x20 && c < 0x7f && set.indexOf(s[k]) < 0) {
			r += s[k];
			continue;
		}
		if (c < 0x80) {
			r += '%' + HEX[c >> 4] + HEX[c & 15];
			continue;
		}
		let e = k + 1;
		if (c >= 0xd800 && c <= 0xdbff && e < s.length)
			e++;
		for (const b of utf8(s.slice(k, e)))
			r += '%' + HEX[b >> 4] + HEX[b & 15];
		k = e - 1;
	}
	return r;
}

function unpct(s) {
	if (s.indexOf('%') < 0)
		return s;
	const b = utf8(s), o = [];
	for (let k = 0; k < b.length; k++) {
		if (b[k] === 37 && k + 2 < b.length) {
			const h = parseInt(String.fromCharCode(b[k + 1], b[k + 2]), 16);
			if (!isNaN(h) && /^[0-9a-fA-F]{2}$/.test(String.fromCharCode(b[k + 1], b[k + 2]))) {
				o.push(h);
				k += 2;
				continue;
			}
		}
		o.push(b[k]);
	}
	return unutf8(o);
}

function parsehost(h, special) {
	if (h.startsWith('[')) {
		if (!h.endsWith(']') || !/^\[[0-9a-fA-F:.]+\]$/.test(h))
			return null;
		return h.toLowerCase();
	}
	if (!special)
		return /[ #/:<>?@[\\\]^|]/.test(h) ? null : pct(h, C0SET);
	h = lower(unpct(h));
	if (h === '' || /[\u0000- #%/:<>?@[\\\]^|\u007f]/.test(h))
		return null;
	return h;
}

function normpath(p, special) {
	const segs = p.split('/');
	const out = [];
	for (let k = 1; k < segs.length; k++) {
		const seg = segs[k], ls = seg.toLowerCase();
		const last = k === segs.length - 1;
		if (ls === '.' || ls === '%2e') {
			if (last)
				out.push('');
		} else if (ls === '..' || ls === '.%2e' || ls === '%2e.' || ls === '%2e%2e') {
			out.pop();
			if (last)
				out.push('');
		} else
			out.push(pct(seg, PATHSET));
	}
	return '/' + out.join('/');
}

function parseurl(input, base) {
	if (typeof base === 'string') {
		base = parseurl(base);
		if (!base)
			return null;
	}
	let s = str(input).replace(/^[\u0000- ]+|[\u0000- ]+$/g, '').replace(/[\t\n\r]/g, '');
	const u = {protocol: '', username: '', password: '', host: null, port: '', path: '', opaque: false, query: null, fragment: null};
	const h = s.indexOf('#');
	if (h >= 0) {
		u.fragment = pct(s.slice(h + 1), FRAGSET);
		s = s.slice(0, h);
	}
	const m = /^([a-zA-Z][a-zA-Z0-9+.\-]*):/.exec(s);
	let rel = false;
	if (m) {
		u.protocol = lower(m[1]) + ':';
		s = s.slice(m[0].length);
		if (SPECIAL[u.protocol] === undefined && !s.startsWith('/')) {
			const k = s.indexOf('?');
			if (k >= 0) {
				u.query = pct(s.slice(k + 1), QUERYSET);
				s = s.slice(0, k);
			}
			u.opaque = true;
			u.path = pct(s, C0SET);
			return u;
		}
		if (base && SPECIAL[u.protocol] !== undefined && base.protocol === u.protocol && !/^[\/\\]/.test(s))
			rel = true;
	} else {
		if (!base)
			return null;
		if (base.opaque) {
			if (s !== '' || h < 0)
				return null;
			return Object.assign({}, base, {fragment: u.fragment});
		}
		u.protocol = base.protocol;
		rel = true;
	}
	const special = SPECIAL[u.protocol] !== undefined;
	const q = s.indexOf('?');
	if (q >= 0) {
		u.query = pct(s.slice(q + 1), special ? SQUERYSET : QUERYSET);
		s = s.slice(0, q);
	}
	if (special)
		s = s.replace(/\\/g, '/');
	if (rel && !s.startsWith('//')) {
		u.username = base.username;
		u.password = base.password;
		u.host = base.host;
		u.port = base.port;
		if (s === '') {
			u.path = base.path;
			if (q < 0)
				u.query = base.query;
		} else if (s.startsWith('/'))
			u.path = normpath(s, special);
		else
			u.path = normpath(base.path.slice(0, base.path.lastIndexOf('/') + 1) + s, special);
		return u;
	}
	let auth;
	if (u.protocol === 'file:') {
		if (s.startsWith('//')) {
			s = s.slice(2);
			const k = s.indexOf('/');
			auth = k < 0 ? s : s.slice(0, k);
			s = k < 0 ? '/' : s.slice(k);
		} else
			auth = '';
		u.host = auth === 'localhost' ? '' : parsehost(auth, auth !== '') ?? '';
		u.path = normpath(s.startsWith('/') ? s : '/' + s, true);
		return u;
	}
	if (special)
		s = s.replace(/^\/*/, '');
	else if (s.startsWith('//'))
		s = s.slice(2);
	else {
		u.path = normpath(s, false);
		return u;
	}
	const k = s.indexOf('/');
	auth = k < 0 ? s : s.slice(0, k);
	s = k < 0 ? '' : s.slice(k);
	const at = auth.lastIndexOf('@');
	if (at >= 0) {
		const ui = auth.slice(0, at);
		auth = auth.slice(at + 1);
		const c = ui.indexOf(':');
		u.username = pct(c < 0 ? ui : ui.slice(0, c), USERSET);
		u.password = c < 0 ? '' : pct(ui.slice(c + 1), USERSET);
	}
	let host = auth, port = '';
	const pm = /:(\d*)$/.exec(auth);
	if (pm && !(auth.startsWith('[') && auth.lastIndexOf(']') > pm.index)) {
		host = auth.slice(0, pm.index);
		port = pm[1];
	} else if (/:[^\]]*$/.test(auth) && !auth.startsWith('['))
		return null;
	if (port !== '') {
		const n = parseInt(port, 10);
		if (n > 65535)
			return null;
		port = String(n);
		if (port === SPECIAL[u.protocol])
			port = '';
	}
	u.host = parsehost(host, special);
	if (u.host === null)
		return null;
	u.port = port;
	u.path = s === '' ? (special ? '/' : '') : normpath(s, special);
	return u;
}

function serialize(u, nofrag) {
	let s = u.protocol;
	if (u.host !== null) {
		s += '//';
		if (u.username !== '' || u.password !== '')
			s += u.username + (u.password !== '' ? ':' + u.password : '') + '@';
		s += u.host + (u.port !== '' ? ':' + u.port : '');
	} else if (!u.opaque && u.path.startsWith('//'))
		s += '/.';
	s += u.path;
	if (u.query !== null)
		s += '?' + u.query;
	if (u.fragment !== null && !nofrag)
		s += '#' + u.fragment;
	return s;
}

function origin(u) {
	if (u.protocol === 'blob:') {
		const inner = parseurl(u.path);
		return inner ? origin(inner) : 'null';
	}
	if (SPECIAL[u.protocol] === undefined || u.protocol === 'file:')
		return 'null';
	return u.protocol + '//' + u.host + (u.port !== '' ? ':' + u.port : '');
}

const URLPARTS = {
	protocol: {
		get: (u) => u.protocol,
		set(u, v) {
			const m = /^([a-zA-Z][a-zA-Z0-9+.\-]*)/.exec(v);
			if (!m)
				return;
			const p = lower(m[1]) + ':';
			if ((SPECIAL[p] !== undefined) !== (SPECIAL[u.protocol] !== undefined))
				return;
			u.protocol = p;
			if (u.port === SPECIAL[p])
				u.port = '';
		},
	},
	username: {get: (u) => u.username, set(u, v) { if (u.host) u.username = pct(v, USERSET); }},
	password: {get: (u) => u.password, set(u, v) { if (u.host) u.password = pct(v, USERSET); }},
	host: {
		get: (u) => u.host === null ? '' : u.host + (u.port !== '' ? ':' + u.port : ''),
		set(u, v) {
			if (u.opaque)
				return;
			const m = /^([^:/?#]*)(?::(\d*))?/.exec(v);
			const h = parsehost(m[1], SPECIAL[u.protocol] !== undefined);
			if (h === null)
				return;
			u.host = h;
			if (m[2] !== undefined && m[2] !== '')
				URLPARTS.port.set(u, m[2]);
		},
	},
	hostname: {
		get: (u) => u.host === null ? '' : u.host,
		set(u, v) {
			if (u.opaque)
				return;
			const h = parsehost(v.replace(/[:/?#].*$/, ''), SPECIAL[u.protocol] !== undefined);
			if (h !== null)
				u.host = h;
		},
	},
	port: {
		get: (u) => u.port,
		set(u, v) {
			if (u.host === null || u.host === '' || u.protocol === 'file:')
				return;
			if (v === '') {
				u.port = '';
				return;
			}
			const m = /^\d+/.exec(v);
			if (!m || +m[0] > 65535)
				return;
			u.port = String(+m[0]) === SPECIAL[u.protocol] ? '' : String(+m[0]);
		},
	},
	pathname: {
		get: (u) => u.path,
		set(u, v) {
			if (u.opaque)
				return;
			const special = SPECIAL[u.protocol] !== undefined;
			if (special)
				v = v.replace(/\\/g, '/');
			u.path = normpath(v.startsWith('/') ? v : '/' + v, special);
		},
	},
	search: {
		get: (u) => u.query === null || u.query === '' ? '' : '?' + u.query,
		set(u, v) {
			if (v.startsWith('?'))
				v = v.slice(1);
			u.query = v === '' ? null : pct(v, SPECIAL[u.protocol] !== undefined ? SQUERYSET : QUERYSET);
		},
	},
	hash: {
		get: (u) => u.fragment === null || u.fragment === '' ? '' : '#' + u.fragment,
		set(u, v) {
			if (v.startsWith('#'))
				v = v.slice(1);
			u.fragment = v === '' ? null : pct(v, FRAGSET);
		},
	},
};

class URL {
	constructor(url, base) {
		let b;
		if (base !== undefined) {
			b = parseurl(str(base));
			if (!b)
				throw new TypeError("Failed to construct 'URL': Invalid base URL");
		}
		const u = parseurl(str(url), b);
		if (!u)
			throw new TypeError("Failed to construct 'URL': Invalid URL");
		hidden(this, {_u: u, _sp: null});
	}
	static canParse(url, base) {
		try {
			new URL(url, base);
			return true;
		} catch (x) {
			return false;
		}
	}
	static parse(url, base) {
		try {
			return new URL(url, base);
		} catch (x) {
			return null;
		}
	}
	get href() { return serialize(this._u); }
	set href(v) {
		const u = parseurl(str(v));
		if (!u)
			throw new TypeError("Failed to set the 'href' property on 'URL': Invalid URL");
		this._u = u;
		if (this._sp)
			this._sp._load(u.query || '');
	}
	get origin() { return origin(this._u); }
	get searchParams() {
		if (!this._sp) {
			this._sp = new URLSearchParams(this._u.query || '');
			hidden(this._sp, {_url: this});
		}
		return this._sp;
	}
	toString() { return this.href; }
	toJSON() { return this.href; }
}
for (const p in URLPARTS)
	defineProperty(URL.prototype, p, {
		get() { return URLPARTS[p].get(this._u); },
		set(v) {
			URLPARTS[p].set(this._u, str(v));
			if (p === 'search' && this._sp)
				this._sp._load(this._u.query || '');
		},
		enumerable: true, configurable: true});

function formencode(s) {
	let r = '';
	for (const b of utf8(str(s))) {
		const c = String.fromCharCode(b);
		if (b === 0x20)
			r += '+';
		else if (/[*\-._0-9A-Za-z]/.test(c))
			r += c;
		else
			r += '%' + HEX[b >> 4] + HEX[b & 15];
	}
	return r;
}

function formdecode(s) {
	return unpct(s.replace(/\+/g, ' '));
}

class URLSearchParams {
	constructor(init = '') {
		hidden(this, {_l: [], _url: null});
		if (typeof init === 'object' && init !== null) {
			if (typeof init[Symbol.iterator] === 'function') {
				for (const p of init) {
					const a = [...p];
					if (a.length !== 2)
						throw new TypeError("Failed to construct 'URLSearchParams': Invalid sequence");
					this._l.push([str(a[0]), str(a[1])]);
				}
			} else
				for (const k of Object.keys(init))
					this._l.push([k, str(init[k])]);
		} else
			this._load(str(init));
	}
	_load(s) {
		if (s.startsWith('?'))
			s = s.slice(1);
		this._l = [];
		for (const part of s.split('&')) {
			if (part === '')
				continue;
			const k = part.indexOf('=');
			this._l.push(k < 0 ? [formdecode(part), ''] : [formdecode(part.slice(0, k)), formdecode(part.slice(k + 1))]);
		}
	}
	_update() {
		if (this._url) {
			const s = this.toString();
			this._url._u.query = s === '' ? null : s;
		}
	}
	get size() { return this._l.length; }
	append(k, v) { this._l.push([str(k), str(v)]); this._update(); }
	delete(k, v) {
		k = str(k);
		this._l = this._l.filter(([a, b]) => a !== k || v !== undefined && b !== str(v));
		this._update();
	}
	get(k) { k = str(k); const e = this._l.find(([a]) => a === k); return e ? e[1] : null; }
	getAll(k) { k = str(k); return this._l.filter(([a]) => a === k).map(([, b]) => b); }
	has(k, v) { k = str(k); return this._l.some(([a, b]) => a === k && (v === undefined || b === str(v))); }
	set(k, v) {
		k = str(k);
		v = str(v);
		const k0 = this._l.findIndex(([a]) => a === k);
		if (k0 < 0)
			this._l.push([k, v]);
		else {
			this._l[k0][1] = v;
			this._l = this._l.filter(([a], j) => a !== k || j === k0);
		}
		this._update();
	}
	sort() {
		this._l = this._l.map((e, j) => [e, j]).sort((x, y) => x[0][0] < y[0][0] ? -1 : x[0][0] > y[0][0] ? 1 : x[1] - y[1]).map(([e]) => e);
		this._update();
	}
	forEach(f, self) { for (const [k, v] of this._l.slice()) f.call(self, v, k, this); }
	*entries() { for (const [k, v] of this._l) yield [k, v]; }
	*keys() { for (const [k] of this._l) yield k; }
	*values() { for (const [, v] of this._l) yield v; }
	[Symbol.iterator]() { return this.entries(); }
	toString() { return this._l.map(([k, v]) => formencode(k) + '=' + formencode(v)).join('&'); }
}

// ---- the page's address ----

let pageurl = N.url;
let historystate = null;

function baseurl() {
	const b = N.descendants(1, 'name', 'base').find((e) => N.attr(e, 'href') !== null);
	if (b !== undefined) {
		const u = parseurl(N.attr(b, 'href').trim(), pageurl);
		if (u)
			return serialize(u);
	}
	return pageurl;
}

function resolve(ref) {
	const u = parseurl(str(ref), baseurl());
	return u ? serialize(u) : null;
}

class Location {
	constructor(key) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
	}
	get href() { return pageurl; }
	set href(v) { navigate(v, false); }
	assign(v) { navigate(v, false); }
	replace(v) { navigate(v, true); }
	reload() { N.navigate(pageurl, true); }
	toString() { return pageurl; }
	get ancestorOrigins() { return {length: 0, item() { return null; }, contains() { return false; }}; }
}
urlparts(Location, () => parseurl(pageurl), (l, v) => navigate(v, false));

function navigate(v, replace) {
	const u = resolve(v);
	if (u === null)
		throw domerr('SyntaxError', "'" + v + "' is not a valid URL.");
	if (/^javascript:/i.test(u)) {
		runjsurl(u);
		return;
	}
	const a = parseurl(u), b = parseurl(pageurl);
	if (a && b && serialize(a, true) === serialize(b, true) && a.fragment !== null) {
		// only the fragment: the view moves, the page stays
		const old = pageurl;
		pageurl = u;
		N.navigate(u, replace);
		if (old !== u)
			queuetask(() => fire(G, 'hashchange', {oldURL: old, newURL: u}, HashChangeEvent));
		return;
	}
	N.navigate(u, replace);
}

function runjsurl(u) {
	const src = unpct(u.slice(u.indexOf(':') + 1));
	const [bad, v] = N.eval(src, pageurl);
	if (bad)
		report(v);
}

class History {
	constructor(key) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
	}
	get length() { return 1; }
	get state() { return historystate; }
	get scrollRestoration() { return 'auto'; }
	set scrollRestoration(v) {}
	pushState(state, title, url) { this.replaceState(state, title, url); }
	replaceState(state, title, url) {
		if (url !== undefined && url !== null) {
			const u = resolve(url);
			if (u === null)
				throw domerr('SecurityError', 'bad URL');
			const a = parseurl(u), b = parseurl(pageurl);
			if (origin(a) !== origin(b))
				throw domerr('SecurityError', "A history state object with URL '" + u + "' cannot be created in a document with origin '" + origin(b) + "'.");
			pageurl = u;
		}
		historystate = state === undefined ? null : structuredClone(state);
	}
	back() {}
	forward() {}
	go() {}
}

// ---- the document ----

let readystate = 'loading';
let currentScript = null;
let cookiejar = [];		// [name, value, path, expires (ms or 0)]

class Document extends Node {
	constructor(key, i) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		super(KEY, i);
	}
	get documentElement() { return wrap(rootel()); }
	get head() { const r = rootel(); return r ? wrap(N.children(r, true).find((c) => N.name(c) === 'head') || 0) : null; }
	get body() {
		const r = rootel();
		return r ? wrap(N.children(r, true).find((c) => N.name(c) === 'body' || N.name(c) === 'frameset') || 0) : null;
	}
	set body(v) {
		const old = this.body;
		if (old)
			this.documentElement.replaceChild(v, old);
		else
			this.documentElement.appendChild(v);
	}
	get title() {
		const t = N.descendants(1, 'name', 'title')[0];
		return t ? N.textof(t).trim().replace(/[ \t\n\f\r]+/g, ' ') : '';
	}
	set title(v) {
		let t = N.descendants(1, 'name', 'title')[0];
		if (!t) {
			const head = this.head;
			if (!head)
				return;
			t = N.create(ELEMENT, 'title', 0);
			insertnode(idof(head), wrap(t), 0);
		}
		wrap(t).textContent = v;
	}
	get URL() { return pageurl; }
	get documentURI() { return pageurl; }
	get location() { return location; }
	set location(v) { navigate(v, false); }
	get domain() { const u = parseurl(pageurl); return u && u.host || ''; }
	set domain(v) {}
	get referrer() { return ''; }
	// webfs's jar, chosen by RFC 6265's rules for this page; cookies kept
	// in the page only when there is no webfs (a file: page)
	get cookie() {
		const u = parseurl(pageurl);
		const jar = u && SPECIAL[u.protocol] !== undefined && u.protocol !== 'file:' ? N.jar() : null;
		const now = Date.now();
		if (jar === null) {
			cookiejar = cookiejar.filter((c) => !c[3] || c[3] > now);
			const path = u ? u.path : '/';
			return cookiejar.filter((c) => path.startsWith(c[2])).map((c) => c[0] === '' ? c[1] : c[0] + '=' + c[1]).join('; ');
		}
		const host = u.host, path = u.path, secure = u.protocol === 'https:';
		const out = [];
		for (const line of jar.split('\n')) {
			const f = line.split(' ');
			if (f.length < 3)
				continue;
			const [dom, cpath, nv, exp = '0', sec = '0', http = '0', hostonly = '0'] = f;
			if (http === '1' || sec === '1' && !secure)
				continue;
			if (+exp && +exp * 1000 <= now)
				continue;
			if (hostonly === '1' ? host !== dom : host !== dom && !host.endsWith('.' + dom))
				continue;
			if (!(path === cpath || path.startsWith(cpath) && (cpath.endsWith('/') || path[cpath.length] === '/')))
				continue;
			out.push([cpath.length, nv]);
		}
		out.sort((a, b) => b[0] - a[0]);
		return out.map((x) => x[1]).join('; ');
	}
	set cookie(v) {
		const parts = str(v).split(';');
		const nv = parts[0].trim();
		const k = nv.indexOf('=');
		const name = k < 0 ? '' : nv.slice(0, k).trim(), value = k < 0 ? nv : nv.slice(k + 1).trim();
		const u = parseurl(pageurl);
		let path = u ? u.path.slice(0, Math.max(1, u.path.lastIndexOf('/'))) : '/', expires = 0, domain = null, secure = 0;
		for (const p of parts.slice(1)) {
			const j = p.indexOf('=');
			const a = (j < 0 ? p : p.slice(0, j)).trim().toLowerCase(), av = j < 0 ? '' : p.slice(j + 1).trim();
			if (a === 'path' && av.startsWith('/'))
				path = av;
			else if (a === 'max-age' && /^-?\d+$/.test(av))
				expires = Date.now() + 1000 * av || -1;
			else if (a === 'expires' && !expires) {
				const t = Date.parse(av);
				if (!isNaN(t))
					expires = t || -1;
			} else if (a === 'domain' && av)
				domain = av.replace(/^\./, '').toLowerCase();
			else if (a === 'secure')
				secure = 1;
		}
		const jarok = u && SPECIAL[u.protocol] !== undefined && u.protocol !== 'file:' && N.jar() !== null;
		if (!jarok) {
			cookiejar = cookiejar.filter((c) => c[0] !== name || c[2] !== path);
			if (expires === 0 || expires > Date.now())
				cookiejar.push([name, value, path, expires]);
			return;
		}
		const host = u.host;
		if (domain !== null && host !== domain && !host.endsWith('.' + domain))
			return;	// a domain the page is not in
		if (name === '' || /[\s;]/.test(name) || /[\s;]/.test(value))
			return;
		const secs = expires === 0 ? 0 : expires < 0 ? 1 : Math.ceil(expires / 1000);
		N.jaradd((domain || host) + ' ' + path + ' ' + name + '=' + value + ' ' + secs + ' ' + secure + ' 0 ' + (domain ? 0 : 1));
	}
	get readyState() { return readystate; }
	get characterSet() { return 'UTF-8'; }
	get charset() { return 'UTF-8'; }
	get inputEncoding() { return 'UTF-8'; }
	get contentType() { return 'text/html'; }
	get compatMode() { return 'CSS1Compat'; }
	get hidden() { return false; }
	get visibilityState() { return 'visible'; }
	get webkitVisibilityState() { return 'visible'; }
	get prerendering() { return false; }
	get wasDiscarded() { return false; }
	get designMode() { return 'off'; }
	set designMode(v) {}
	get dir() { const r = rootel(); return r ? N.attr(r, 'dir') || '' : ''; }
	get activeElement() { return focused && connected(focused) ? wrap(focused) : this.body; }
	get defaultView() { return G; }
	get currentScript() { return currentScript; }
	get doctype() { return wrap(N.children(1, false).find((c) => N.kind(c) === DOCTYPE) || 0); }
	get scripts() { return collection(N.descendants(1, 'name', 'script')); }
	get images() { return collection(N.descendants(1, 'name', 'img')); }
	get links() { return collection(select(1, 'a[href],area[href]', true)); }
	get forms() { return collection(N.descendants(1, 'name', 'form')); }
	get embeds() { return collection(N.descendants(1, 'name', 'embed')); }
	get plugins() { return this.embeds; }
	get anchors() { return collection(select(1, 'a[name]', true)); }
	get children() { return collection(N.children(1, true)); }
	get childElementCount() { return N.children(1, true).length; }
	get firstElementChild() { return wrap(rootel()); }
	get lastElementChild() { return wrap(rootel()); }
	get all() { return undefined; }
	get styleSheets() {
		const l = select(1, 'style, link[rel~=stylesheet i]', true).map(stylesheet);
		l.item = (k) => l[k] || null;
		return l;
	}
	get adoptedStyleSheets() { return []; }
	set adoptedStyleSheets(v) {}
	get fonts() { return FONTS; }
	get implementation() { return IMPLEMENTATION; }
	get scrollingElement() { return wrap(rootel()); }
	get fullscreenElement() { return null; }
	get fullscreenEnabled() { return false; }
	get pictureInPictureEnabled() { return false; }
	get timeline() { return {currentTime: N.now()}; }
	get featurePolicy() { return {allowsFeature() { return false; }, features() { return []; }, allowedFeatures() { return []; }}; }
	get permissionsPolicy() { return this.featurePolicy; }
	get lastModified() { return new Date().toLocaleString(); }
	getElementById(id) { return wrap(N.descendants(1, 'id', str(id))); }
	getElementsByName(name) { return new NodeList(KEY, N.descendants(1, 'nameattr', str(name)).map(wrap)); }
	getElementsByTagName(name) { return collection(N.descendants(1, 'name', str(name))); }
	getElementsByTagNameNS(ns, name) { return collection(N.descendants(1, 'name', str(name))); }
	getElementsByClassName(names) { return collection(N.descendants(1, 'class', str(names))); }
	querySelector(sel) { return wrap(select(1, sel, false)); }
	querySelectorAll(sel) { return new NodeList(KEY, select(1, sel, true).map(wrap)); }
	createElement(name, options) {
		name = str(name);
		if (!/^[a-zA-Z_:][^\s"'>/=\0]*$/.test(name) && !/^[a-zA-Z]/.test(name))
			throw domerr('InvalidCharacterError', "The tag name provided ('" + name + "') is not a valid name.");
		name = lower(name);
		const is = options && typeof options === 'object' ? options.is : undefined;
		const def = CUSTOM.get(name);
		if (def) {
			const w = Reflect.construct(def.ctor, []);
			return w;
		}
		const i = N.create(ELEMENT, name, 0);
		if (is)
			N.setattr(i, 'is', str(is));
		return wrap(i);
	}
	createElementNS(ns, qname) {
		ns = ns === null ? '' : str(ns);
		qname = str(qname);
		const local = qname.indexOf(':') >= 0 ? qname.slice(qname.indexOf(':') + 1) : qname;
		const n = NSURIS.indexOf(ns);
		if (n === 0)
			return this.createElement(local);
		return wrap(N.create(ELEMENT, local, n < 0 ? 0 : n));
	}
	createTextNode(s) { return wrap(textnode(str(s))); }
	createComment(s) { return new Comment(s); }
	createCDATASection(s) { return this.createTextNode(s); }
	createProcessingInstruction(t, d) { return new Comment('?' + t + ' ' + d + '?'); }
	createDocumentFragment() { return new DocumentFragment(); }
	createAttribute(name) { return {name: str(name), value: '', nodeType: 2}; }
	createEvent(kind) {
		const C = {event: Event, events: Event, htmlevents: Event, uievent: UIEvent, uievents: UIEvent,
			mouseevent: MouseEvent, mouseevents: MouseEvent, keyboardevent: KeyboardEvent,
			customevent: CustomEvent, messageevent: MessageEvent, focusevent: FocusEvent,
			touchevent: TouchEvent, errorevent: ErrorEvent}[str(kind).toLowerCase()];
		if (!C)
			throw domerr('NotSupportedError', "The provided event type ('" + kind + "') is invalid.");
		const e = new C('');
		return e;
	}
	createRange() { return new Range(); }
	createTreeWalker(root, what = 0xffffffff, filter = null) { return new TreeWalker(KEY, root, what, filter, false); }
	createNodeIterator(root, what = 0xffffffff, filter = null) { return new TreeWalker(KEY, root, what, filter, true); }
	importNode(n, deep = false) { return n.cloneNode(deep); }
	adoptNode(n) { if (n.parentNode) n.parentNode.removeChild(n); return n; }
	hasFocus() { return true; }
	getSelection() { return SELECTION; }
	elementFromPoint() { return null; }
	elementsFromPoint() { return []; }
	caretRangeFromPoint() { return null; }
	execCommand() { return false; }
	queryCommandSupported() { return false; }
	queryCommandEnabled() { return false; }
	exitFullscreen() { return Promise.resolve(); }
	hasStorageAccess() { return Promise.resolve(true); }
	requestStorageAccess() { return Promise.resolve(); }
	startViewTransition(f) {
		const p = Promise.resolve().then(() => f && f());
		return {finished: p, ready: p, updateCallbackDone: p, skipTransition() {}};
	}
	write(...parts) { docwrite(parts.join('')); }
	writeln(...parts) { docwrite(parts.join('') + '\n'); }
	open() { return this; }
	close() {}
	append(...nodes) { insertnode(1, nodesof(nodes), 0); }
	prepend(...nodes) { insertnode(1, nodesof(nodes), N.first(1)); }
}
handlerprops(Document.prototype, EVENTNAMES.concat(['readystatechange', 'visibilitychange', 'DOMContentLoaded',
	'fullscreenchange', 'pointerlockchange', 'securitypolicyviolation']));

class HTMLDocument extends Document {}

class XMLDocument extends Document {}

// document.write: during loading, what is written goes in after the
// running script; after it, the markup is appended to the body
function docwrite(s) {
	const nodes = N.parse(s);
	const cs = currentScript ? idof(currentScript) : 0;
	if (readystate === 'loading' && cs && N.parent(cs)) {
		let next = N.next(cs);
		for (const n of nodes)
			N.insert(N.parent(cs), n, next), next = N.next(n);
		mutated(N.parent(cs), 'childList', {added: nodes});
		return;
	}
	const b = document.body;
	if (b)
		for (const n of nodes)
			insertnode(idof(b), wrap(n), 0);
}

const IMPLEMENTATION = {
	hasFeature() { return true; },
	createHTMLDocument(title) {
		// another document is not to be had: a fragment holding one's tree
		const f = new DocumentFragment();
		const html = document.createElement('html');
		const head = document.createElement('head');
		const body = document.createElement('body');
		html.append(head, body);
		f.appendChild(html);
		if (title !== undefined) {
			const t = document.createElement('title');
			t.textContent = title;
			head.appendChild(t);
		}
		hidden(f, {documentElement: html, head, body, createElement: (n) => document.createElement(n),
			createTextNode: (s) => document.createTextNode(s), getElementById: (id) => f.querySelector('#' + CSS.escape(id))});
		return f;
	},
	createDocument() { return this.createHTMLDocument(); },
	createDocumentType(name) { return {name, nodeType: 10}; },
};

const FONTS = Object.assign(new EventTarget(), {
	ready: Promise.resolve(),
	status: 'loaded',
	load() { return Promise.resolve([]); },
	check() { return true; },
	add() {},
	delete() { return false; },
	forEach() {},
	size: 0,
});
defineProperty(FONTS, 'ready', {value: Promise.resolve(FONTS)});

class Range {
	constructor() {
		hidden(this, {startContainer: document, startOffset: 0, endContainer: document, endOffset: 0, collapsed: true,
			commonAncestorContainer: document});
	}
	setStart(n, o) { this.startContainer = n; this.startOffset = o; }
	setEnd(n, o) { this.endContainer = n; this.endOffset = o; }
	setStartBefore(n) {}
	setStartAfter(n) {}
	setEndBefore(n) {}
	setEndAfter(n) {}
	selectNode(n) { this.startContainer = this.endContainer = n; }
	selectNodeContents(n) { this.startContainer = this.endContainer = n; }
	collapse() { this.collapsed = true; }
	cloneRange() { return Object.assign(new Range(), this); }
	detach() {}
	deleteContents() {}
	extractContents() { return new DocumentFragment(); }
	cloneContents() { return new DocumentFragment(); }
	insertNode(n) {}
	surroundContents() {}
	getBoundingClientRect() { return new DOMRect(); }
	getClientRects() { return []; }
	toString() { return ''; }
	createContextualFragment(html) {
		const f = new DocumentFragment();
		for (const n of N.parse(str(html)))
			N.insert(idof(f), n, 0);
		return f;
	}
}

const SELECTION = {
	rangeCount: 0, isCollapsed: true, type: 'None', anchorNode: null, focusNode: null, anchorOffset: 0, focusOffset: 0,
	getRangeAt() { throw domerr('IndexSizeError', 'no range'); },
	addRange() {}, removeAllRanges() {}, removeRange() {}, empty() {}, collapse() {}, extend() {},
	selectAllChildren() {}, toString() { return ''; }, containsNode() { return false; },
};

const NodeFilter = {FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3, SHOW_ALL: 0xffffffff,
	SHOW_ELEMENT: 1, SHOW_ATTRIBUTE: 2, SHOW_TEXT: 4, SHOW_CDATA_SECTION: 8, SHOW_PROCESSING_INSTRUCTION: 64,
	SHOW_COMMENT: 128, SHOW_DOCUMENT: 256, SHOW_DOCUMENT_TYPE: 512, SHOW_DOCUMENT_FRAGMENT: 1024};

class TreeWalker {
	constructor(key, root, what, filter, iter) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		hidden(this, {root, whatToShow: what >>> 0, filter, currentNode: root, _iter: iter, _ref: root, _before: true});
	}
	_accept(n) {
		const t = n.nodeType;
		if (!(this.whatToShow & (1 << (t - 1))))
			return 3;
		if (!this.filter)
			return 1;
		const f = typeof this.filter === 'function' ? this.filter : this.filter.acceptNode.bind(this.filter);
		return f(n);
	}
	_nextin(i) {
		const r = idof(this.root);
		if (N.first(i))
			return N.first(i);
		for (; i && i !== r; i = N.parent(i))
			if (N.next(i))
				return N.next(i);
		return 0;
	}
	_previn(i) {
		const r = idof(this.root);
		if (i === r)
			return 0;
		let p = N.prev(i);
		if (!p)
			return N.parent(i);
		while (N.last(p))
			p = N.last(p);
		return p;
	}
	nextNode() {
		if (this._iter) {
			let i = idof(this._ref);
			if (this._before) {
				this._before = false;
				if (this._accept(this._ref) === 1)
					return this._ref;
			}
			for (i = this._nextin(i); i; i = this._nextin(i)) {
				this._ref = wrap(i);
				if (this._accept(this._ref) === 1)
					return this._ref;
			}
			return null;
		}
		for (let i = this._nextin(idof(this.currentNode)); i; i = this._nextin(i)) {
			const w = wrap(i);
			const a = this._accept(w);
			if (a === 1) {
				this.currentNode = w;
				return w;
			}
		}
		return null;
	}
	previousNode() {
		for (let i = this._previn(idof(this._iter ? this._ref : this.currentNode)); i; i = this._previn(i)) {
			const w = wrap(i);
			if (this._accept(w) === 1) {
				if (this._iter)
					this._ref = w;
				else
					this.currentNode = w;
				return w;
			}
		}
		return null;
	}
	get referenceNode() { return this._ref; }
	parentNode() {
		for (let i = N.parent(idof(this.currentNode)); i && i !== N.parent(idof(this.root)); i = N.parent(i)) {
			const w = wrap(i);
			if (this._accept(w) === 1) {
				this.currentNode = w;
				return w;
			}
		}
		return null;
	}
	_sib(first, next) {
		for (let i = first(idof(this.currentNode)); i; i = next(i)) {
			const w = wrap(i);
			if (this._accept(w) === 1) {
				this.currentNode = w;
				return w;
			}
		}
		return null;
	}
	firstChild() { return this._sib(N.first, N.next); }
	lastChild() { return this._sib(N.last, N.prev); }
	nextSibling() { return this._sib(N.next, N.next); }
	previousSibling() { return this._sib(N.prev, N.prev); }
	detach() {}
}

// ---- timers ----

const TIMERS = new Map();
let timerid = 0;

function settimer(f, ms, args, repeat) {
	const id = ++timerid;
	if (typeof f !== 'function') {
		const src = str(f);
		f = () => { const [bad, v] = N.eval(src, pageurl); if (bad) report(v); };
	}
	ms = +ms || 0;
	if (ms < 0 || ms !== ms)
		ms = 0;
	TIMERS.set(id, {f, args, ms: repeat ? Math.max(ms, 4) : ms, repeat});
	N.timer(id, ms);
	return id;
}

function timerfired(id) {
	const t = TIMERS.get(id);
	if (!t)
		return;
	if (t.repeat)
		N.timer(id, t.ms);
	else
		TIMERS.delete(id);
	try {
		t.f.apply(G, t.args);
	} catch (x) {
		report(x);
	}
}

function queuetask(f) {
	settimer(f, 0, [], false);
}

let rafs = [], rafid = 0, rafpending = false;

function requestAnimationFrame(f) {
	if (typeof f !== 'function')
		throw new TypeError("Failed to execute 'requestAnimationFrame': The callback provided as parameter 1 is not a function.");
	const id = ++rafid;
	rafs.push([id, f]);
	if (!rafpending) {
		rafpending = true;
		settimer(frame, 16, [], false);
	}
	return id;
}

function frame() {
	rafpending = false;
	const now = N.now();
	const l = rafs;
	rafs = [];
	for (const [, f] of l)
		try { f(now); } catch (x) { report(x); }
	observe();
}

function cancelAnimationFrame(id) {
	rafs = rafs.filter(([k]) => k !== id);
}

function requestIdleCallback(f, opts) {
	return settimer(() => {
		const end = N.now() + 50;
		f({didTimeout: false, timeRemaining: () => Math.max(0, end - N.now())});
	}, 1, [], false);
}

// ---- storage ----

class Storage {
	constructor(key) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		hidden(this, {_m: new Map()});
	}
}

const STORAGEMETHODS = {
	getItem(m, k) { k = str(k); return m.has(k) ? m.get(k) : null; },
	setItem(m, k, v) { m.set(str(k), str(v)); },
	removeItem(m, k) { m.delete(str(k)); },
	clear(m) { m.clear(); },
	key(m, n) { const a = [...m.keys()]; n = n >>> 0; return n < a.length ? a[n] : null; },
};

// localStorage lives in the origin's store, when it has one: lines of
// key and value, a tab between, with backslash, tab and newline escaped;
// written a moment after a change, all of it
function unesc(s) {
	return s.replace(/\\(.)/g, (m, c) => c === 't' ? '\t' : c === 'n' ? '\n' : c);
}

function esc(s) {
	return s.replace(/\\/g, '\\\\').replace(/\t/g, '\\t').replace(/\n/g, '\\n');
}

function persistent(name) {
	const m = new Map();
	const text = N.storeload(name);
	if (text === null)
		return storage(m, null);
	for (const line of text.split('\n')) {
		const k = line.indexOf('\t');
		if (k >= 0)
			m.set(unesc(line.slice(0, k)), unesc(line.slice(k + 1)));
	}
	let pending = false;
	return storage(m, () => {
		if (pending)
			return;
		pending = true;
		queuetask(() => {
			pending = false;
			let t = '';
			for (const [k, v] of m)
				t += esc(k) + '\t' + esc(v) + '\n';
			N.storesave(name, t);
		});
	});
}

function storage(m = new Map(), changed = null) {
	return new Proxy(new Storage(KEY), {
		get(t, k) {
			if (typeof k === 'symbol')
				return t[k];
			if (k in STORAGEMETHODS)
				return (...a) => {
					const r = STORAGEMETHODS[k](m, ...a);
					if (changed && (k === 'setItem' || k === 'removeItem' || k === 'clear'))
						changed();
					return r;
				};
			if (k === 'length')
				return m.size;
			if (k === 'constructor')
				return Storage;
			if (k === 'toString')
				return () => '[object Storage]';
			return m.has(k) ? m.get(k) : undefined;
		},
		set(t, k, v) {
			if (typeof k === 'string') {
				m.set(k, str(v));
				if (changed)
					changed();
			}
			return true;
		},
		deleteProperty(t, k) {
			m.delete(str(k));
			if (changed)
				changed();
			return true;
		},
		has(t, k) { return typeof k === 'string' && (m.has(k) || k in STORAGEMETHODS); },
		ownKeys() { return [...m.keys()]; },
		getOwnPropertyDescriptor(t, k) {
			return m.has(k) ? {value: m.get(k), writable: true, enumerable: true, configurable: true} : undefined;
		},
	});
}

// ---- encodings, base64, blobs ----

class TextEncoder {
	get encoding() { return 'utf-8'; }
	encode(s = '') { return new Uint8Array(utf8(str(s))); }
	encodeInto(s, dst) {
		const b = utf8(str(s));
		const n = Math.min(b.length, dst.length);
		dst.set(b.slice(0, n));
		return {read: str(s).length, written: n};
	}
}

class TextDecoder {
	constructor(label = 'utf-8', opts = {}) {
		label = str(label).trim().toLowerCase();
		const enc = {'utf-8': 'utf-8', utf8: 'utf-8', 'unicode-1-1-utf-8': 'utf-8', 'iso-8859-1': 'windows-1252',
			latin1: 'windows-1252', 'us-ascii': 'windows-1252', ascii: 'windows-1252', 'windows-1252': 'windows-1252',
			'utf-16le': 'utf-16le', 'utf-16': 'utf-16le'}[label];
		if (!enc)
			throw new RangeError("Failed to construct 'TextDecoder': The encoding label provided ('" + label + "') is invalid.");
		hidden(this, {_enc: enc, _fatal: !!opts.fatal, _bom: !opts.ignoreBOM});
	}
	get encoding() { return this._enc; }
	get fatal() { return this._fatal; }
	get ignoreBOM() { return !this._bom; }
	decode(input) {
		if (input === undefined)
			return '';
		let b;
		if (input instanceof ArrayBuffer)
			b = new Uint8Array(input);
		else if (ArrayBuffer.isView(input))
			b = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
		else
			throw new TypeError("Failed to execute 'decode' on 'TextDecoder': The provided value is not of type '(ArrayBuffer or ArrayBufferView)'");
		if (this._enc === 'windows-1252') {
			let s = '';
			for (let k = 0; k < b.length; k++)
				s += String.fromCharCode(b[k]);
			return s;
		}
		if (this._enc === 'utf-16le') {
			let s = '';
			for (let k = 0; k + 1 < b.length; k += 2)
				s += String.fromCharCode(b[k] | b[k + 1] << 8);
			return this._bom && s.charCodeAt(0) === 0xfeff ? s.slice(1) : s;
		}
		let start = 0;
		if (this._bom && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf)
			start = 3;
		const s = unutf8(b, start);
		if (this._fatal && s.indexOf('�') >= 0)
			throw new TypeError("Failed to execute 'decode' on 'TextDecoder': The encoded data was not valid.");
		return s;
	}
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function btoa(s) {
	s = str(s);
	let r = '';
	for (let k = 0; k < s.length; k += 3) {
		const a = s.charCodeAt(k), b = s.charCodeAt(k + 1), c = s.charCodeAt(k + 2);
		if (a > 255 || b > 255 || c > 255)
			throw domerr('InvalidCharacterError', "Failed to execute 'btoa' on 'Window': The string to be encoded contains characters outside of the Latin1 range.");
		r += B64[a >> 2] + B64[(a & 3) << 4 | (k + 1 < s.length ? b >> 4 : 0)] +
			(k + 1 < s.length ? B64[(b & 15) << 2 | (k + 2 < s.length ? c >> 6 : 0)] : '=') +
			(k + 2 < s.length ? B64[c & 63] : '=');
	}
	return r;
}

function atob(s) {
	s = str(s).replace(/[\t\n\f\r ]/g, '');
	if (s.length % 4 === 0)
		s = s.replace(/==?$/, '');
	if (s.length % 4 === 1 || /[^A-Za-z0-9+/]/.test(s))
		throw domerr('InvalidCharacterError', "Failed to execute 'atob' on 'Window': The string to be decoded is not correctly encoded.");
	let r = '', acc = 0, n = 0;
	for (let k = 0; k < s.length; k++) {
		acc = acc << 6 | B64.indexOf(s[k]);
		n += 6;
		if (n >= 8) {
			n -= 8;
			r += String.fromCharCode(acc >> n & 255);
		}
	}
	return r;
}

function bytesof(x) {
	if (typeof x === 'string')
		return utf8(x);
	if (x instanceof ArrayBuffer)
		return [...new Uint8Array(x)];
	if (ArrayBuffer.isView(x))
		return [...new Uint8Array(x.buffer, x.byteOffset, x.byteLength)];
	if (x instanceof Blob)
		return x._b.slice();
	return utf8(str(x));
}

class Blob {
	constructor(parts = [], opts = {}) {
		const b = [];
		for (const p of parts)
			for (const c of bytesof(p))
				b.push(c);
		hidden(this, {_b: b, _type: opts.type ? str(opts.type).toLowerCase() : ''});
	}
	get size() { return this._b.length; }
	get type() { return this._type; }
	text() { return Promise.resolve(unutf8(this._b)); }
	arrayBuffer() { return Promise.resolve(new Uint8Array(this._b).buffer); }
	bytes() { return Promise.resolve(new Uint8Array(this._b)); }
	slice(start = 0, end = this._b.length, type = '') {
		const r = new Blob([], {type});
		r._b = this._b.slice(start, end);
		return r;
	}
	stream() { return streamof(this._b); }
}

class File extends Blob {
	constructor(parts, name, opts = {}) {
		super(parts, opts);
		hidden(this, {_name: str(name), _mod: opts.lastModified || Date.now()});
	}
	get name() { return this._name; }
	get lastModified() { return this._mod; }
}

class FileReader extends EventTarget {
	constructor() {
		super();
		hidden(this, {result: null, readyState: 0, error: null, onload: null, onloadend: null, onerror: null});
	}
	_done(r) {
		this.result = r;
		this.readyState = 2;
		queuetask(() => {
			const ev = new ProgressEvent('load');
			if (typeof this.onload === 'function') this.onload(ev);
			this.dispatchEvent(ev);
			if (typeof this.onloadend === 'function') this.onloadend(new ProgressEvent('loadend'));
		});
	}
	readAsText(b) { this._done(unutf8(b._b)); }
	readAsArrayBuffer(b) { this._done(new Uint8Array(b._b).buffer); }
	readAsDataURL(b) { this._done('data:' + (b.type || 'application/octet-stream') + ';base64,' + btoa(String.fromCharCode(...b._b))); }
	abort() {}
}

const BLOBURLS = new Map();

hidden(URL, {
	createObjectURL(b) {
		const u = 'blob:' + origin(parseurl(pageurl)) + '/' + crypto.randomUUID();
		BLOBURLS.set(u, b);
		return u;
	},
	revokeObjectURL(u) { BLOBURLS.delete(str(u)); },
});

class FormData {
	constructor(form) {
		hidden(this, {_l: []});
		if (form instanceof HTMLFormElement)
			for (const [k, v] of formentries(idof(form), 0))
				this._l.push([k, v]);
	}
	append(k, v, name) { this._l.push([str(k), v instanceof Blob ? v : str(v)]); }
	delete(k) { k = str(k); this._l = this._l.filter(([a]) => a !== k); }
	get(k) { k = str(k); const e = this._l.find(([a]) => a === k); return e ? e[1] : null; }
	getAll(k) { k = str(k); return this._l.filter(([a]) => a === k).map(([, v]) => v); }
	has(k) { k = str(k); return this._l.some(([a]) => a === k); }
	set(k, v) { this.delete(k); this.append(k, v); }
	forEach(f, self) { for (const [k, v] of this._l) f.call(self, v, k, this); }
	*entries() { yield* this._l.map((e) => e.slice()); }
	*keys() { for (const [k] of this._l) yield k; }
	*values() { for (const [, v] of this._l) yield v; }
	[Symbol.iterator]() { return this.entries(); }
}

// a form's entries (HTML §4.10.21.4), with its submitter
function formentries(form, submitter) {
	const r = [];
	for (const c of select(form, 'input,select,textarea,button', true)) {
		const name = N.attr(c, 'name');
		if (name === null || name === '' || N.attr(c, 'disabled') !== null)
			continue;
		const w = wrap(c);
		const tag = N.name(c);
		if (tag === 'input') {
			const t = w.type;
			if ((t === 'checkbox' || t === 'radio') && !w.checked)
				continue;
			if ((t === 'submit' || t === 'image' || t === 'button' || t === 'reset') && c !== submitter)
				continue;
			if (t === 'file')
				continue;
			r.push([name, w.value]);
		} else if (tag === 'button') {
			if (c === submitter)
				r.push([name, w.value]);
		} else if (tag === 'select') {
			for (const o of select(c, 'option', true))
				if (N.attr(o, 'selected') !== null)
					r.push([name, wrap(o).value]);
			if (!w.multiple && !select(c, 'option[selected]', true).length && select(c, 'option', true).length)
				r.push([name, wrap(select(c, 'option', false)).value]);
		} else
			r.push([name, w.value]);
	}
	return r;
}

function submitform(form, submitter) {
	const f = wrap(form);
	const action = (submitter && N.attr(submitter, 'formaction')) || N.attr(form, 'action') || pageurl;
	const method = ((submitter && N.attr(submitter, 'formmethod')) || N.attr(form, 'method') || 'get').toLowerCase();
	const u = parseurl(action, baseurl());
	if (!u)
		return;
	const body = new URLSearchParams(formentries(form, submitter)).toString();
	if (method === 'get') {
		u.query = body;
		navigate(serialize(u), false);
	} else
		console.warn('form submission by POST from script is not supported yet');
}

// ---- fetch ----

const FETCHES = new Map();
let fetchid = 0;

function startfetch(method, url, headers, body, done) {
	const id = ++fetchid;
	FETCHES.set(id, done);
	if (url.startsWith('blob:')) {
		const b = BLOBURLS.get(url);
		queuetask(() => fetched(id, b ? 200 : 404, b ? 'OK' : 'Not Found', url, b && b.type ? 'Content-Type: ' + b.type : '',
			b ? unutf8(b._b) : '', undefined));
		return id;
	}
	N.fetch(id, method, url, headers, body);
	return id;
}

// ---- CORS ----
//
// The page's /mnt/web is an origin filter (appl/lib/web/originfs.b), not
// webfs: it sends the Origin, makes the preflight, decides the cookies,
// and gives a cross-origin response back only if CORS lets this origin
// read it.  A request says only its mode and credentials.

function pageorigin() {
	const u = parseurl(pageurl);
	return u ? origin(u) : 'null';
}

function crossorigin(url) {
	if (/^(data|blob|about):/i.test(url))
		return false;
	const u = parseurl(url);
	return !u || origin(u) !== pageorigin() || origin(u) === 'null';
}

// a script's request: (method, url, headers, body, credentials, mode, done)
function corsfetch(method, url, headers, body, creds, mode, done) {
	const lines = 'mode ' + mode + '\ncredentials ' + creds + '\n' + headerlines(headers);
	if (mode === 'no-cors' && crossorigin(url))
		// sent, but nothing of it is given back: an opaque response
		return startfetch(method, url, lines, body, (status, st, u, header, b, err) =>
			done(err !== undefined ? 0 : -1, '', '', '', '', err));
	return startfetch(method, url, lines, body, done);
}

function fetched(id, status, statustext, url, header, body, err) {
	const done = FETCHES.get(id);
	if (!done)
		return;
	FETCHES.delete(id);
	done(status, statustext, url, header, body, err);
}

function headerlines(h) {
	let s = '';
	for (const [k, v] of h)
		s += k + ': ' + v + '\n';
	return s;
}

class Headers {
	constructor(init) {
		hidden(this, {_m: new Map()});
		if (init instanceof Headers)
			for (const [k, v] of init._m)
				this._m.set(k, v.slice());
		else if (init && typeof init[Symbol.iterator] === 'function')
			for (const [k, v] of init)
				this.append(k, v);
		else if (init && typeof init === 'object')
			for (const k of Object.keys(init))
				this.append(k, init[k]);
	}
	append(k, v) {
		k = str(k).toLowerCase();
		v = str(v).trim();
		const l = this._m.get(k);
		if (l)
			l.push(v);
		else
			this._m.set(k, [v]);
	}
	set(k, v) { this._m.set(str(k).toLowerCase(), [str(v).trim()]); }
	get(k) { const l = this._m.get(str(k).toLowerCase()); return l ? l.join(', ') : null; }
	getSetCookie() { return this._m.get('set-cookie') || []; }
	has(k) { return this._m.has(str(k).toLowerCase()); }
	delete(k) { this._m.delete(str(k).toLowerCase()); }
	forEach(f, self) { for (const [k, v] of this) f.call(self, v, k, this); }
	*entries() { for (const k of [...this._m.keys()].sort()) yield [k, this._m.get(k).join(', ')]; }
	*keys() { for (const [k] of this.entries()) yield k; }
	*values() { for (const [, v] of this.entries()) yield v; }
	[Symbol.iterator]() { return this.entries(); }
}

function parseheaders(s) {
	const h = new Headers();
	for (const line of str(s).split(/\r?\n/)) {
		const k = line.indexOf(':');
		if (k > 0)
			h.append(line.slice(0, k).trim(), line.slice(k + 1).trim());
	}
	return h;
}

function streamof(bytes) {
	let done = false;
	return new ReadableStream({
		pull(c) {
			if (!done) {
				c.enqueue(new Uint8Array(bytes));
				done = true;
			}
			c.close();
		},
	});
}

class ReadableStream {
	constructor(source = {}) {
		const q = [];
		let closed = false, waiting = null;
		const controller = {
			enqueue(v) { if (waiting) { const w = waiting; waiting = null; w({value: v, done: false}); } else q.push(v); },
			close() { closed = true; if (waiting) { const w = waiting; waiting = null; w({value: undefined, done: true}); } },
			error(e) { closed = true; },
			desiredSize: 1,
		};
		hidden(this, {_q: q, locked: false, _pull: () => {
			if (q.length)
				return Promise.resolve({value: q.shift(), done: false});
			if (closed)
				return Promise.resolve({value: undefined, done: true});
			return new Promise((r) => {
				waiting = r;
				if (source.pull)
					Promise.resolve().then(() => source.pull(controller));
			});
		}});
		if (source.start)
			source.start(controller);
	}
	getReader() {
		this.locked = true;
		return {read: () => this._pull(), releaseLock: () => { this.locked = false; }, cancel: () => Promise.resolve(),
			closed: Promise.resolve()};
	}
	cancel() { return Promise.resolve(); }
	async *[Symbol.asyncIterator]() {
		for (;;) {
			const r = await this._pull();
			if (r.done)
				return;
			yield r.value;
		}
	}
	tee() { return [this, this]; }
	pipeTo() { return Promise.resolve(); }
	pipeThrough(t) { return t.readable; }
}

function bodyof(b, headers) {
	if (b === undefined || b === null)
		return null;
	if (typeof b === 'string')
		return b;
	if (b instanceof URLSearchParams) {
		if (headers && !headers.has('content-type'))
			headers.set('content-type', 'application/x-www-form-urlencoded;charset=UTF-8');
		return b.toString();
	}
	if (b instanceof FormData) {
		const boundary = '----infernode' + Math.random().toString(36).slice(2);
		let s = '';
		for (const [k, v] of b._l)
			s += '--' + boundary + '\r\nContent-Disposition: form-data; name="' + k + '"' +
				(v instanceof Blob ? '; filename="' + (v.name || 'blob') + '"\r\nContent-Type: ' + (v.type || 'application/octet-stream') : '') +
				'\r\n\r\n' + (v instanceof Blob ? unutf8(v._b) : v) + '\r\n';
		s += '--' + boundary + '--\r\n';
		if (headers && !headers.has('content-type'))
			headers.set('content-type', 'multipart/form-data; boundary=' + boundary);
		return s;
	}
	if (b instanceof Blob) {
		if (headers && b.type && !headers.has('content-type'))
			headers.set('content-type', b.type);
		return unutf8(b._b);
	}
	if (b instanceof ArrayBuffer || ArrayBuffer.isView(b))
		return unutf8(bytesof(b));
	return str(b);
}

class Body {
	_take() {
		if (this._used)
			return Promise.reject(new TypeError('body stream already read'));
		this._used = true;
		return Promise.resolve(this._body === null ? '' : this._body);
	}
	get bodyUsed() { return this._used; }
	get body() { return this._body === null ? null : streamof(utf8(this._body)); }
	text() { return this._take(); }
	json() { return this._take().then((s) => JSON.parse(s)); }
	arrayBuffer() { return this._take().then((s) => new Uint8Array(utf8(s)).buffer); }
	bytes() { return this._take().then((s) => new Uint8Array(utf8(s))); }
	blob() { return this._take().then((s) => new Blob([s], {type: this.headers.get('content-type') || ''})); }
	formData() { return this._take().then((s) => { const f = new FormData(); for (const [k, v] of new URLSearchParams(s)) f.append(k, v); return f; }); }
}

class Request extends Body {
	constructor(input, init = {}) {
		super();
		let url, method = 'GET', headers, body = null, signal = null;
		if (input instanceof Request) {
			url = input.url;
			method = input.method;
			headers = new Headers(input.headers);
			body = input._body;
			signal = input.signal;
		} else {
			url = resolve(input);
			if (url === null)
				throw new TypeError("Failed to construct 'Request': Invalid URL");
			headers = new Headers();
		}
		if (init.method !== undefined)
			method = str(init.method).toUpperCase();
		if (init.headers !== undefined)
			headers = new Headers(init.headers);
		if (init.body !== undefined)
			body = bodyof(init.body, headers);
		if (init.signal !== undefined)
			signal = init.signal;
		hidden(this, {_url: url, _method: method, _headers: headers, _body: body, _used: false, _signal: signal,
			_credentials: init.credentials || 'same-origin', _mode: init.mode || 'cors', _cache: init.cache || 'default',
			_redirect: init.redirect || 'follow', _referrer: init.referrer || 'about:client'});
	}
	get url() { return this._url; }
	get method() { return this._method; }
	get headers() { return this._headers; }
	get signal() { return this._signal || new AbortController().signal; }
	get credentials() { return this._credentials; }
	get mode() { return this._mode; }
	get cache() { return this._cache; }
	get redirect() { return this._redirect; }
	get referrer() { return this._referrer; }
	get destination() { return ''; }
	get keepalive() { return false; }
	clone() { return new Request(this); }
}

class Response extends Body {
	constructor(body = null, init = {}) {
		super();
		const headers = new Headers(init.headers);
		hidden(this, {_body: bodyof(body, headers), _used: false, _status: init.status === undefined ? 200 : init.status | 0,
			_statusText: init.statusText === undefined ? '' : str(init.statusText), _headers: headers, _url: '',
			_type: 'default', _redirected: false});
	}
	static json(data, init = {}) {
		const r = new Response(JSON.stringify(data), init);
		if (!r.headers.has('content-type'))
			r.headers.set('content-type', 'application/json');
		return r;
	}
	static error() {
		const r = new Response(null, {status: 0});
		r._type = 'error';
		return r;
	}
	static redirect(url, status = 302) {
		return new Response(null, {status, headers: {location: resolve(url)}});
	}
	get status() { return this._status; }
	get ok() { return this._status >= 200 && this._status < 300; }
	get statusText() { return this._statusText; }
	get headers() { return this._headers; }
	get url() { return this._url; }
	get type() { return this._type; }
	get redirected() { return this._redirected; }
	clone() {
		const r = new Response(this._body, {status: this._status, statusText: this._statusText, headers: this._headers});
		r._url = this._url;
		r._type = this._type;
		return r;
	}
}

function abortreason(signal) {
	return signal.reason !== undefined ? signal.reason : domerr('AbortError', 'The user aborted a request.');
}

function fetch(input, init = {}) {
	let req;
	try {
		req = new Request(input, init);
	} catch (x) {
		return Promise.reject(x);
	}
	return new Promise((resolve_, reject) => {
		const signal = req._signal;
		if (signal && signal.aborted) {
			reject(abortreason(signal));
			return;
		}
		const id = corsfetch(req.method, req.url, req.headers, req._body, req._credentials, req._mode, (status, st, url, header, body, err) => {
			if (err !== undefined || status === 0) {
				if (err !== undefined && /^blocked by CORS/.test(err))
					console.error(err);
				reject(new TypeError('Failed to fetch'));
				return;
			}
			if (status === -1) {
				const r = new Response(null, {status: 0});
				r._type = 'opaque';
				resolve_(r);
				return;
			}
			const r = new Response(body === undefined ? null : body, {status, statusText: st, headers: parseheaders(header)});
			r._url = url;
			r._type = crossorigin(req.url) ? 'cors' : 'basic';
			r._redirected = url !== req.url;
			resolve_(r);
		});
		if (signal)
			signal.addEventListener('abort', () => {
				if (FETCHES.delete(id))
					reject(abortreason(signal));
			});
	});
}

class AbortSignal extends EventTarget {
	constructor(key) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		super();
		hidden(this, {_aborted: false, _reason: undefined});
	}
	get aborted() { return this._aborted; }
	get reason() { return this._reason; }
	throwIfAborted() { if (this._aborted) throw this._reason; }
	_abort(reason) {
		if (this._aborted)
			return;
		this._aborted = true;
		this._reason = reason === undefined ? domerr('AbortError', 'signal is aborted without reason') : reason;
		fire(this, 'abort', {});
	}
	static abort(reason) {
		const s = new AbortSignal(KEY);
		s._abort(reason);
		return s;
	}
	static timeout(ms) {
		const s = new AbortSignal(KEY);
		setTimeout(() => s._abort(domerr('TimeoutError', 'signal timed out')), ms);
		return s;
	}
	static any(signals) {
		const s = new AbortSignal(KEY);
		for (const x of signals) {
			if (x.aborted) {
				s._abort(x.reason);
				break;
			}
			x.addEventListener('abort', () => s._abort(x.reason));
		}
		return s;
	}
}
handlerprops(AbortSignal.prototype, ['abort']);

class AbortController {
	constructor() {
		hidden(this, {_signal: new AbortSignal(KEY)});
	}
	get signal() { return this._signal; }
	abort(reason) { this._signal._abort(reason); }
}

// ---- XMLHttpRequest ----

class XMLHttpRequestEventTarget extends EventTarget {}
handlerprops(XMLHttpRequestEventTarget.prototype, ['abort', 'error', 'load', 'loadend', 'loadstart', 'progress', 'timeout']);

class XMLHttpRequestUpload extends XMLHttpRequestEventTarget {}

class XMLHttpRequest extends XMLHttpRequestEventTarget {
	constructor() {
		super();
		hidden(this, {_state: 0, _method: 'GET', _url: '', _async: true, _headers: new Headers(), _status: 0,
			_statusText: '', _rheaders: '', _text: '', _url2: '', _id: 0, responseType: '', timeout: 0,
			withCredentials: false, _upload: new XMLHttpRequestUpload(), _sent: false, _timer: 0});
	}
	get readyState() { return this._state; }
	get status() { return this._status; }
	get statusText() { return this._statusText; }
	get responseURL() { return this._url2; }
	get responseText() {
		if (this.responseType !== '' && this.responseType !== 'text')
			throw domerr('InvalidStateError', "The value is only accessible if the object's 'responseType' is '' or 'text'.");
		return this._text;
	}
	get responseXML() { return null; }
	get response() {
		if (this._state !== 4 && this.responseType !== '' && this.responseType !== 'text')
			return null;
		switch (this.responseType) {
		case 'json':
			try { return JSON.parse(this._text); } catch (x) { return null; }
		case 'arraybuffer':
			return new Uint8Array(utf8(this._text)).buffer;
		case 'blob':
			return new Blob([this._text]);
		case 'document':
			return null;
		default:
			return this._text;
		}
	}
	get upload() { return this._upload; }
	_setstate(s) {
		this._state = s;
		fire(this, 'readystatechange', {});
	}
	open(method, url, async = true) {
		const u = resolve(url);
		if (u === null)
			throw domerr('SyntaxError', "Failed to execute 'open' on 'XMLHttpRequest': Invalid URL");
		this._method = str(method).toUpperCase();
		this._url = u;
		this._async = async !== false;
		this._headers = new Headers();
		this._status = 0;
		this._text = '';
		this._sent = false;
		this._setstate(1);
	}
	setRequestHeader(k, v) {
		if (this._state !== 1 || this._sent)
			throw domerr('InvalidStateError', "Failed to execute 'setRequestHeader' on 'XMLHttpRequest': The object's state must be OPENED.");
		this._headers.append(k, v);
	}
	getResponseHeader(k) {
		if (this._state < 2)
			return null;
		return parseheaders(this._rheaders).get(k);
	}
	getAllResponseHeaders() {
		if (this._state < 2)
			return '';
		let s = '';
		for (const [k, v] of parseheaders(this._rheaders))
			s += k + ': ' + v + '\r\n';
		return s;
	}
	overrideMimeType() {}
	send(body = null) {
		if (this._state !== 1 || this._sent)
			throw domerr('InvalidStateError', "Failed to execute 'send' on 'XMLHttpRequest': The object's state must be OPENED.");
		this._sent = true;
		const b = this._method === 'GET' || this._method === 'HEAD' ? null : bodyof(body, this._headers);
		if (!this._async) {
			const r = N.fetchsync(this._url);
			if (r[0] === 0) {
				this._state = 4;
				throw domerr('NetworkError', "Failed to execute 'send' on 'XMLHttpRequest': Failed to load '" + this._url + "'.");
			}
			this._status = r[0];
			this._statusText = r[0] === 200 ? 'OK' : '';
			this._rheaders = 'Content-Type: ' + r[1];
			this._text = r[2];
			this._url2 = r[3];
			this._setstate(4);
			fire(this, 'load', {}, ProgressEvent);
			fire(this, 'loadend', {}, ProgressEvent);
			return;
		}
		fire(this, 'loadstart', {}, ProgressEvent);
		this._id = corsfetch(this._method, this._url, this._headers, b, this.withCredentials ? 'include' : 'same-origin', 'cors', (status, st, url, header, text, err) => {
			if (this._timer)
				clearTimeout(this._timer);
			if (err !== undefined || status === 0) {
				if (err !== undefined && /^blocked by CORS/.test(err))
					console.error(err);
				this._state = 4;
				this._setstate(4);
				fire(this, 'error', {}, ProgressEvent);
				fire(this, 'loadend', {}, ProgressEvent);
				return;
			}
			this._status = status;
			this._statusText = st;
			this._rheaders = header;
			this._url2 = url;
			this._setstate(2);
			this._text = text === undefined ? '' : text;
			this._setstate(3);
			this._setstate(4);
			const n = this._text.length;
			fire(this, 'progress', {lengthComputable: true, loaded: n, total: n}, ProgressEvent);
			fire(this, 'load', {lengthComputable: true, loaded: n, total: n}, ProgressEvent);
			fire(this, 'loadend', {lengthComputable: true, loaded: n, total: n}, ProgressEvent);
		});
		if (this.timeout > 0)
			this._timer = setTimeout(() => {
				if (FETCHES.delete(this._id)) {
					this._setstate(4);
					fire(this, 'timeout', {}, ProgressEvent);
					fire(this, 'loadend', {}, ProgressEvent);
				}
			}, this.timeout);
	}
	abort() {
		if (FETCHES.delete(this._id)) {
			this._setstate(4);
			fire(this, 'abort', {}, ProgressEvent);
			fire(this, 'loadend', {}, ProgressEvent);
		}
		this._state = 0;
	}
}
handlerprops(XMLHttpRequest.prototype, ['readystatechange']);
for (const [k, v] of [['UNSENT', 0], ['OPENED', 1], ['HEADERS_RECEIVED', 2], ['LOADING', 3], ['DONE', 4]]) {
	defineProperty(XMLHttpRequest, k, {value: v, enumerable: true});
	defineProperty(XMLHttpRequest.prototype, k, {value: v, enumerable: true});
}

function sendBeacon(url, data) {
	const u = resolve(url);
	if (u === null)
		return false;
	startfetch('POST', u, 'mode no-cors\ncredentials include\n', bodyof(data, null), () => {});
	return true;
}

// ---- observers of layout ----

const INTERSECTIONS = [];	// {observer, el, last}
const RESIZES = [];		// {observer, el, last}
let observepending = false;

function scheduleobserve() {
	if (!observepending) {
		observepending = true;
		settimer(() => { observepending = false; observe(); }, 16, [], false);
	}
}

function observe() {
	if (INTERSECTIONS.length === 0 && RESIZES.length === 0)
		return;
	const [vw, vh, sx, sy] = N.viewport();
	const byobs = new Map();
	for (const e of INTERSECTIONS) {
		const [shown, x, y, w, h] = N.box(idof(e.el));
		const rect = shown ? new DOMRectReadOnly(x - sx, y - sy, w, h) : new DOMRectReadOnly();
		const m = e.observer._margin;
		const vis = shown && rect.bottom >= -m && rect.top <= vh + m && rect.right >= -m && rect.left <= vw + m;
		let ratio = 0;
		if (vis) {
			const iw = Math.max(0, Math.min(rect.right, vw) - Math.max(rect.left, 0));
			const ih = Math.max(0, Math.min(rect.bottom, vh) - Math.max(rect.top, 0));
			ratio = w * h > 0 ? Math.min(1, iw * ih / (w * h)) : 1;
		}
		if (e.last === vis && e.lastratio === ratio)
			continue;
		e.last = vis;
		e.lastratio = ratio;
		const ir = vis ? new DOMRectReadOnly(Math.max(rect.left, 0), Math.max(rect.top, 0),
			Math.max(0, Math.min(rect.right, vw) - Math.max(rect.left, 0)), Math.max(0, Math.min(rect.bottom, vh) - Math.max(rect.top, 0))) : new DOMRectReadOnly();
		const entry = {target: e.el, isIntersecting: vis, intersectionRatio: ratio, boundingClientRect: rect,
			intersectionRect: ir, rootBounds: new DOMRectReadOnly(0, 0, vw, vh), time: N.now(), isVisible: vis};
		let l = byobs.get(e.observer);
		if (!l)
			byobs.set(e.observer, l = []);
		l.push(entry);
	}
	for (const e of RESIZES) {
		const [shown, , , w, h] = N.box(idof(e.el));
		const key = shown + ',' + w + ',' + h;
		if (e.last === key)
			continue;
		e.last = key;
		const sz = [{inlineSize: w, blockSize: h}];
		const entry = {target: e.el, contentRect: new DOMRectReadOnly(0, 0, w, h), borderBoxSize: sz, contentBoxSize: sz,
			devicePixelContentBoxSize: sz};
		let l = byobs.get(e.observer);
		if (!l)
			byobs.set(e.observer, l = []);
		l.push(entry);
	}
	for (const [o, entries] of byobs)
		try { o._callback.call(o, entries, o); } catch (x) { report(x); }
}

class IntersectionObserver {
	constructor(callback, opts = {}) {
		if (typeof callback !== 'function')
			throw new TypeError("Failed to construct 'IntersectionObserver': The callback provided as parameter 1 is not a function.");
		const m = parseInt(opts.rootMargin || '0', 10) || 0;
		hidden(this, {_callback: callback, _margin: m, root: opts.root || null, rootMargin: opts.rootMargin || '0px 0px 0px 0px',
			thresholds: [].concat(opts.threshold === undefined ? 0 : opts.threshold)});
	}
	observe(el) {
		nodeid(el);
		if (!INTERSECTIONS.some((e) => e.observer === this && e.el === el))
			INTERSECTIONS.push({observer: this, el, last: undefined, lastratio: undefined});
		scheduleobserve();
	}
	unobserve(el) {
		const k = INTERSECTIONS.findIndex((e) => e.observer === this && e.el === el);
		if (k >= 0)
			INTERSECTIONS.splice(k, 1);
	}
	disconnect() {
		for (let k = INTERSECTIONS.length - 1; k >= 0; k--)
			if (INTERSECTIONS[k].observer === this)
				INTERSECTIONS.splice(k, 1);
	}
	takeRecords() { return []; }
}

class ResizeObserver {
	constructor(callback) {
		if (typeof callback !== 'function')
			throw new TypeError("Failed to construct 'ResizeObserver': The callback provided as parameter 1 is not a function.");
		hidden(this, {_callback: callback});
	}
	observe(el) {
		nodeid(el);
		if (!RESIZES.some((e) => e.observer === this && e.el === el))
			RESIZES.push({observer: this, el, last: undefined});
		scheduleobserve();
	}
	unobserve(el) {
		const k = RESIZES.findIndex((e) => e.observer === this && e.el === el);
		if (k >= 0)
			RESIZES.splice(k, 1);
	}
	disconnect() {
		for (let k = RESIZES.length - 1; k >= 0; k--)
			if (RESIZES[k].observer === this)
				RESIZES.splice(k, 1);
	}
}

// ---- performance ----

const PERFENTRIES = [];
const timeorigin = Date.now() - N.now();

class PerformanceEntry {
	constructor(key, f) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		Object.assign(this, f);
	}
	toJSON() { return Object.assign({}, this); }
}

const PERFOBSERVERS = [];

function perfentry(f) {
	const e = new PerformanceEntry(KEY, f);
	PERFENTRIES.push(e);
	for (const o of PERFOBSERVERS)
		if (o.types.includes(e.entryType))
			queueMicrotask(() => {
				const list = {getEntries: () => [e], getEntriesByType: (t) => t === e.entryType ? [e] : [], getEntriesByName: (n) => n === e.name ? [e] : []};
				try { o.observer._callback.call(o.observer, list, o.observer); } catch (x) { report(x); }
			});
	return e;
}

let navtiming = null;

const performance = Object.assign(Object.create(EventTarget.prototype), {
	now: () => N.now(),
	get timeOrigin() { return timeorigin; },
	timing: null,
	navigation: {type: 0, redirectCount: 0, TYPE_NAVIGATE: 0, TYPE_RELOAD: 1, TYPE_BACK_FORWARD: 2},
	getEntries: () => PERFENTRIES.slice(),
	getEntriesByType: (t) => t === 'navigation' ? [navtiming] : PERFENTRIES.filter((e) => e.entryType === t),
	getEntriesByName: (n, t) => PERFENTRIES.filter((e) => e.name === n && (t === undefined || e.entryType === t)),
	mark(name, opts = {}) {
		return perfentry({name: str(name), entryType: 'mark', startTime: opts.startTime !== undefined ? opts.startTime : N.now(),
			duration: 0, detail: opts.detail === undefined ? null : opts.detail});
	},
	measure(name, start, end) {
		const at = (m) => {
			if (m === undefined)
				return undefined;
			if (typeof m === 'number')
				return m;
			const e = PERFENTRIES.filter((x) => x.name === m).pop();
			// the names of PerformanceTiming's attributes are marks too
			const pt = performance.timing;
			if (!e && pt && typeof pt[m] === 'number' && m !== 'toJSON') {
				if (pt[m] === 0)
					throw domerr('InvalidAccessError', "'" + m + "' is empty: either the event hasn't happened yet, or it would provide cross-origin timing information.");
				return pt[m] - pt.navigationStart;
			}
			if (!e)
				throw domerr('SyntaxError', "The mark '" + m + "' does not exist.");
			return e.startTime;
		};
		let s = 0, t = N.now();
		if (start && typeof start === 'object') {
			s = at(start.start) ?? 0;
			t = at(start.end) ?? (start.duration !== undefined ? s + start.duration : t);
		} else {
			s = at(start) ?? 0;
			t = at(end) ?? t;
		}
		return perfentry({name: str(name), entryType: 'measure', startTime: s, duration: t - s, detail: null});
	},
	clearMarks(name) { remove(PERFENTRIES, (e) => e.entryType === 'mark' && (name === undefined || e.name === name)); },
	clearMeasures(name) { remove(PERFENTRIES, (e) => e.entryType === 'measure' && (name === undefined || e.name === name)); },
	clearResourceTimings() {},
	setResourceTimingBufferSize() {},
	toJSON() { return {timeOrigin: timeorigin}; },
	eventCounts: new Map(),
});

function remove(a, f) {
	for (let k = a.length - 1; k >= 0; k--)
		if (f(a[k]))
			a.splice(k, 1);
}

function navigationtiming() {
	const t = N.now();
	const f = {name: pageurl, entryType: 'navigation', startTime: 0, duration: t, initiatorType: 'navigation',
		nextHopProtocol: 'http/1.1', workerStart: 0, redirectStart: 0, redirectEnd: 0, fetchStart: 0,
		domainLookupStart: 0, domainLookupEnd: 0, connectStart: 0, connectEnd: 0, secureConnectionStart: 0,
		requestStart: 0, responseStart: 0, responseEnd: 0, transferSize: 0, encodedBodySize: 0, decodedBodySize: 0,
		serverTiming: [], unloadEventStart: 0, unloadEventEnd: 0, domInteractive: t, domContentLoadedEventStart: t,
		domContentLoadedEventEnd: t, domComplete: t, loadEventStart: t, loadEventEnd: t, type: 'navigate',
		redirectCount: 0, activationStart: 0, deliveryType: '', renderBlockingStatus: 'non-blocking'};
	navtiming = new PerformanceEntry(KEY, f);
	const o = {};
	for (const k of ['navigationStart', 'unloadEventStart', 'unloadEventEnd', 'redirectStart', 'redirectEnd', 'fetchStart',
		'domainLookupStart', 'domainLookupEnd', 'connectStart', 'connectEnd', 'secureConnectionStart', 'requestStart',
		'responseStart', 'responseEnd', 'domLoading', 'domInteractive', 'domContentLoadedEventStart',
		'domContentLoadedEventEnd', 'domComplete', 'loadEventStart', 'loadEventEnd'])
		o[k] = k.startsWith('unload') || k.startsWith('redirect') || k === 'secureConnectionStart' ? 0 :
			Math.round(timeorigin + (k.startsWith('dom') || k.startsWith('load') ? t : 0));
	o.toJSON = function () { return Object.assign({}, this); };
	performance.timing = o;
}

class PerformanceObserver {
	constructor(callback) {
		hidden(this, {_callback: callback});
	}
	observe(opts = {}) {
		const types = opts.entryTypes || (opts.type ? [opts.type] : []);
		PERFOBSERVERS.push({observer: this, types});
		if (opts.buffered)
			for (const t of types) {
				const es = t === 'navigation' && navtiming ? [navtiming] : PERFENTRIES.filter((e) => e.entryType === t);
				if (es.length)
					queueMicrotask(() => {
						try {
							this._callback.call(this, {getEntries: () => es, getEntriesByType: (x) => es.filter((e) => e.entryType === x),
								getEntriesByName: (n) => es.filter((e) => e.name === n)}, this);
						} catch (x) { report(x); }
					});
			}
	}
	disconnect() { remove(PERFOBSERVERS, (o) => o.observer === this); }
	takeRecords() { return []; }
	static get supportedEntryTypes() { return ['mark', 'measure', 'navigation']; }
}

// ---- console ----

function inspect(v, depth = 0, seen = new Set()) {
	switch (typeof v) {
	case 'string':
		return depth ? JSON.stringify(v) : v;
	case 'undefined':
		return 'undefined';
	case 'function':
		return '[Function: ' + (v.name || 'anonymous') + ']';
	case 'symbol':
		return v.toString();
	case 'bigint':
		return v + 'n';
	case 'object':
		if (v === null)
			return 'null';
		if (seen.has(v))
			return '[Circular]';
		if (v instanceof Error)
			return depth ? '[' + v.name + ': ' + v.message + ']' : (v.stack || v.name + ': ' + v.message);
		if (isnode(v))
			return v.nodeType === 1 ? '<' + v.localName + (v.id ? '#' + v.id : '') + '>' : v.nodeName;
		if (depth > 2)
			return Array.isArray(v) ? '[Array]' : '[Object]';
		seen.add(v);
		try {
			if (Array.isArray(v))
				return '[' + v.slice(0, 50).map((x) => inspect(x, depth + 1, seen)).join(', ') + (v.length > 50 ? ', ...' : '') + ']';
			const ks = Object.keys(v).slice(0, 30);
			const name = v.constructor && v.constructor.name !== 'Object' ? v.constructor.name + ' ' : '';
			return name + '{' + ks.map((k) => k + ': ' + inspect(v[k], depth + 1, seen)).join(', ') + '}';
		} catch (x) {
			return '[object]';
		} finally {
			seen.delete(v);
		}
	default:
		return String(v);
	}
}

function format(args) {
	if (args.length === 0)
		return '';
	let out = '';
	let k = 0;
	if (typeof args[0] === 'string' && args[0].indexOf('%') >= 0) {
		out = args[0].replace(/%[sdifoOcj%]/g, (m) => {
			if (m === '%%')
				return '%';
			if (k + 1 >= args.length)
				return m;
			const a = args[++k];
			switch (m) {
			case '%s': return typeof a === 'string' ? a : inspect(a, 1);
			case '%d': case '%i': return String(parseInt(a, 10));
			case '%f': return String(parseFloat(a));
			case '%c': return '';
			default: return inspect(a, 1);
			}
		});
		k++;
	} else {
		out = inspect(args[0]);
		k = 1;
	}
	for (; k < args.length; k++)
		out += ' ' + inspect(args[k]);
	return out;
}

const counts = new Map(), timers = new Map();
let indent = '';

function logger(level) {
	return function (...args) {
		N.log(indent + (level ? level + ': ' : '') + format(args));
	};
}

const console = {
	log: logger(''), info: logger(''), debug: logger(''), warn: logger('warning'), error: logger('error'),
	trace: logger('trace'), dir: (v) => N.log(indent + inspect(v)), dirxml: logger(''),
	table: (v) => N.log(indent + inspect(v)),
	group(...a) { if (a.length) N.log(indent + format(a)); indent += '  '; },
	groupCollapsed(...a) { this.group(...a); },
	groupEnd() { indent = indent.slice(2); },
	time(l = 'default') { timers.set(l, N.now()); },
	timeEnd(l = 'default') { const t = timers.get(l); if (t !== undefined) { N.log(indent + l + ': ' + (N.now() - t) + ' ms'); timers.delete(l); } },
	timeLog(l = 'default') { const t = timers.get(l); if (t !== undefined) N.log(indent + l + ': ' + (N.now() - t) + ' ms'); },
	count(l = 'default') { const n = (counts.get(l) || 0) + 1; counts.set(l, n); N.log(indent + l + ': ' + n); },
	countReset(l = 'default') { counts.delete(l); },
	assert(c, ...a) { if (!c) N.log(indent + 'Assertion failed' + (a.length ? ': ' + format(a) : '')); },
	clear() {},
	profile() {}, profileEnd() {}, timeStamp() {},
};

// what script threw and nothing caught: the window's error event, then the console
let reporting = false;

function report(x) {
	if (reporting) {
		N.log('error: ' + inspect(x));
		return;
	}
	reporting = true;
	try {
		const message = x instanceof Error ? x.name + ': ' + x.message : 'Uncaught ' + inspect(x, 1);
		const ev = trusted(new ErrorEvent('error', {cancelable: true, message, error: x, filename: pageurl}));
		if (dispatch(G, ev))
			N.log('Uncaught ' + (x instanceof Error ? (x.stack && x.stack.indexOf(x.message) >= 0 ? x.stack : x.name + ': ' + x.message) : inspect(x, 1)));
	} catch (y) {
		N.log('error: ' + inspect(x));
	} finally {
		reporting = false;
	}
}

// ---- the rest of the window ----

const crypto = {
	getRandomValues(a) {
		if (!ArrayBuffer.isView(a) || a instanceof Float32Array || a instanceof Float64Array || a instanceof DataView)
			throw domerr('TypeMismatchError', "Failed to execute 'getRandomValues' on 'Crypto': The provided ArrayBufferView is of type '" + (a && a.constructor && a.constructor.name) + "', which is not an integer array type.");
		if (a.byteLength > 65536)
			throw domerr('QuotaExceededError', "Failed to execute 'getRandomValues' on 'Crypto': The ArrayBufferView's byte length (" + a.byteLength + ') exceeds the number of bytes of entropy available via this API (65536).');
		const b = N.random(a.byteLength);
		new Uint8Array(a.buffer, a.byteOffset, a.byteLength).set(b);
		return a;
	},
	randomUUID() {
		const b = N.random(16);
		b[6] = b[6] & 0x0f | 0x40;
		b[8] = b[8] & 0x3f | 0x80;
		const h = b.map((x) => (x < 16 ? '0' : '') + x.toString(16)).join('');
		return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
	},
	subtle: new Proxy({}, {get: (t, k) => typeof k === 'string' ? () => Promise.reject(domerr('NotSupportedError', 'Web Crypto is not supported')) : undefined}),
};

const UA = 'Mozilla/5.0 (InferNode; Inferno) Charon/1.0';

const navigator = {
	userAgent: UA, appVersion: UA.slice(8), appName: 'Netscape', appCodeName: 'Mozilla', product: 'Gecko',
	productSub: '20030107', vendor: '', vendorSub: '', platform: 'Inferno', language: 'en-US', languages: ['en-US', 'en'],
	onLine: true, cookieEnabled: true, doNotTrack: '1', hardwareConcurrency: 1, maxTouchPoints: 0, deviceMemory: 1,
	webdriver: false, pdfViewerEnabled: false, globalPrivacyControl: true,
	plugins: Object.assign([], {item: () => null, namedItem: () => null, refresh() {}}),
	mimeTypes: Object.assign([], {item: () => null, namedItem: () => null}),
	connection: {effectiveType: '4g', downlink: 10, rtt: 50, saveData: false, type: 'unknown', addEventListener() {}, removeEventListener() {}},
	sendBeacon,
	javaEnabled: () => false,
	vibrate: () => false,
	share: () => Promise.reject(domerr('NotAllowedError', 'sharing is not supported')),
	canShare: () => false,
	registerProtocolHandler() {},
	getGamepads: () => [],
	clipboard: {writeText: () => Promise.reject(domerr('NotAllowedError', 'no clipboard')), readText: () => Promise.reject(domerr('NotAllowedError', 'no clipboard'))},
	permissions: {query: (d) => Promise.resolve({state: 'denied', name: d && d.name, onchange: null, addEventListener() {}})},
	storage: {estimate: () => Promise.resolve({quota: 0, usage: 0}), persist: () => Promise.resolve(false), persisted: () => Promise.resolve(false)},
	mediaDevices: undefined,
	geolocation: undefined,
	serviceWorker: undefined,
	scheduling: {isInputPending: () => false},
	locks: undefined,
};

const screen = {width: 1280, height: 800, availWidth: 1280, availHeight: 800, availLeft: 0, availTop: 0,
	colorDepth: 24, pixelDepth: 24, orientation: {type: 'landscape-primary', angle: 0, addEventListener() {}, removeEventListener() {}},
	isExtended: false};

class MediaQueryList extends EventTarget {
	constructor(key, q) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		super();
		hidden(this, {_q: q, onchange: null});
	}
	get media() { return this._q; }
	get matches() { return N.media(this._q); }
	addListener(f) { this.addEventListener('change', f); }
	removeListener(f) { this.removeEventListener('change', f); }
}

function matchMedia(q) {
	return new MediaQueryList(KEY, str(q));
}

class MessagePort extends EventTarget {
	constructor(key) {
		if (key !== KEY)
			throw new TypeError('Illegal constructor');
		super();
		hidden(this, {_other: null, _onmessage: null, _started: false, _queue: []});
	}
	get onmessage() { return this._onmessage; }
	set onmessage(f) { this._onmessage = f; this.start(); }
	postMessage(data) {
		const o = this._other;
		if (!o)
			return;
		const v = structuredClone(data);
		queuetask(() => {
			const ev = trusted(new MessageEvent('message', {data: v}));
			if (typeof o._onmessage === 'function')
				try { o._onmessage.call(o, ev); } catch (x) { report(x); }
			dispatch(o, ev);
		});
	}
	start() { this._started = true; }
	close() { this._other = null; }
}

class MessageChannel {
	constructor() {
		const a = new MessagePort(KEY), b = new MessagePort(KEY);
		a._other = b;
		b._other = a;
		hidden(this, {port1: a, port2: b});
	}
}

class BroadcastChannel extends EventTarget {
	constructor(name) {
		super();
		hidden(this, {name: str(name), onmessage: null});
	}
	postMessage() {}
	close() {}
}

function postMessage(data, target) {
	const v = structuredClone(data);
	const o = origin(parseurl(pageurl));
	queuetask(() => fire(G, 'message', {data: v, origin: o, source: G}, MessageEvent));
}

function structuredClone(v, opts, seen = new Map()) {
	if (typeof v !== 'object' || v === null) {
		if (typeof v === 'function' || typeof v === 'symbol')
			throw domerr('DataCloneError', String(v) + ' could not be cloned.');
		return v;
	}
	if (seen.has(v))
		return seen.get(v);
	let r;
	if (Array.isArray(v)) {
		r = [];
		seen.set(v, r);
		for (let k = 0; k < v.length; k++)
			r[k] = structuredClone(v[k], opts, seen);
		return r;
	}
	if (v instanceof Date)
		return new Date(v.getTime());
	if (v instanceof RegExp)
		return new RegExp(v.source, v.flags);
	if (v instanceof Map) {
		r = new Map();
		seen.set(v, r);
		for (const [a, b] of v)
			r.set(structuredClone(a, opts, seen), structuredClone(b, opts, seen));
		return r;
	}
	if (v instanceof Set) {
		r = new Set();
		seen.set(v, r);
		for (const a of v)
			r.add(structuredClone(a, opts, seen));
		return r;
	}
	if (v instanceof ArrayBuffer)
		return v.slice(0);
	if (ArrayBuffer.isView(v))
		return new v.constructor(v);
	if (v instanceof Error) {
		const e = new (G[v.name] || Error)(v.message);
		return e;
	}
	if (isnode(v) || v instanceof Blob && false)
		throw domerr('DataCloneError', 'a node could not be cloned.');
	r = {};
	seen.set(v, r);
	for (const k of Object.keys(v))
		r[k] = structuredClone(v[k], opts, seen);
	return r;
}

const CSS = {
	supports(prop, value) {
		if (value === undefined)
			return /^\s*\(?\s*[-a-z]+\s*:/.test(str(prop)) || /selector\(/.test(str(prop));
		return CSSPROPS.has(camel(str(prop))) || str(prop).startsWith('--');
	},
	escape(s) {
		s = str(s);
		let r = '';
		for (let k = 0; k < s.length; k++) {
			const c = s.charCodeAt(k);
			if (c === 0)
				r += '�';
			else if (c >= 1 && c <= 0x1f || c === 0x7f || k === 0 && c >= 0x30 && c <= 0x39 || k === 1 && c >= 0x30 && c <= 0x39 && s[0] === '-')
				r += '\\' + c.toString(16) + ' ';
			else if (k === 0 && s.length === 1 && s === '-')
				r += '\\-';
			else if (c >= 0x80 || c === 0x2d || c === 0x5f || c >= 0x30 && c <= 0x39 || c >= 0x41 && c <= 0x5a || c >= 0x61 && c <= 0x7a)
				r += s[k];
			else
				r += '\\' + s[k];
		}
		return r;
	},
	registerProperty() {},
};

const trustedTypes = {
	createPolicy(name, rules = {}) {
		return {
			name,
			createHTML: (s, ...a) => rules.createHTML ? rules.createHTML(s, ...a) : s,
			createScript: (s, ...a) => rules.createScript ? rules.createScript(s, ...a) : s,
			createScriptURL: (s, ...a) => rules.createScriptURL ? rules.createScriptURL(s, ...a) : s,
		};
	},
	isHTML: () => false, isScript: () => false, isScriptURL: () => false,
	emptyHTML: '', emptyScript: '', defaultPolicy: null,
	getAttributeType: () => null, getPropertyType: () => null,
};

function Image(width, height) {
	const img = document.createElement('img');
	if (width !== undefined)
		img.setAttribute('width', str(width));
	if (height !== undefined)
		img.setAttribute('height', str(height));
	return img;
}
Image.prototype = HTMLImageElement.prototype;

function Option(text = '', value, defaultSelected = false, selected = false) {
	const o = document.createElement('option');
	if (text !== '')
		o.textContent = text;
	if (value !== undefined)
		o.setAttribute('value', str(value));
	if (defaultSelected || selected)
		o.setAttribute('selected', '');
	return o;
}
Option.prototype = HTMLOptionElement.prototype;

function Audio(src) {
	const a = document.createElement('audio');
	if (src !== undefined)
		a.setAttribute('src', str(src));
	return a;
}
Audio.prototype = G.HTMLAudioElement.prototype;

class DOMParser {
	parseFromString(s, type) {
		const d = IMPLEMENTATION.createHTMLDocument();
		// the parsed document's head and body, in place of the new one's
		const [html, head, body] = N.parse(str(s), true);
		const into = (from, to) => {
			if (!from)
				return;
			const a = N.attrs(from);
			for (let x = 0; x < a.length; x += 2)
				N.setattr(idof(to), a[x], a[x + 1]);
			for (const c of N.children(from, false)) {
				N.remove(c);
				N.insert(idof(to), c, 0);
			}
		};
		into(html, d.documentElement);
		into(head, d.head);
		into(body, d.body);
		hidden(d, {querySelector: (sel) => d.documentElement.querySelector(sel),
			querySelectorAll: (sel) => d.documentElement.querySelectorAll(sel),
			getElementsByTagName: (t) => d.documentElement.getElementsByTagName(t),
			title: d.head.querySelector('title') ? d.head.querySelector('title').textContent : ''});
		return d;
	}
}

class XMLSerializer {
	serializeToString(n) {
		return N.markup(idof(n), true);
	}
}

class Window extends EventTarget {}
handlerprops(Window.prototype, EVENTNAMES.concat(WINDOWEVENTS));

// ---- the global object ----

document = wrap(1);
const location = new Location(KEY);
const history = new History(KEY);
const localStorage = persistent('local'), sessionStorage = storage();
const customElements = new CustomElementRegistry();

Object.setPrototypeOf(G, Window.prototype);

globals({
	window: G, self: G, frames: G, parent: G, top: G,
	EventTarget, Event, UIEvent, MouseEvent, PointerEvent, WheelEvent, KeyboardEvent, FocusEvent, InputEvent,
	CompositionEvent, TouchEvent, CustomEvent, ErrorEvent, MessageEvent, PageTransitionEvent, PopStateEvent,
	HashChangeEvent, ProgressEvent, SubmitEvent, AnimationEvent, TransitionEvent, StorageEvent,
	PromiseRejectionEvent, BeforeUnloadEvent, SecurityPolicyViolationEvent, DOMException,
	Node, Element, HTMLElement, SVGElement, SVGGraphicsElement, SVGSVGElement, MathMLElement, CharacterData, Text,
	CDATASection, Comment, ProcessingInstruction, DocumentType, DocumentFragment, ShadowRoot, Document, HTMLDocument,
	XMLDocument, Attr, NamedNodeMap, NodeList, HTMLCollection, DOMTokenList, CSSStyleDeclaration, DOMRect,
	DOMRectReadOnly, MutationObserver, WebKitMutationObserver: MutationObserver, MutationRecord,
	IntersectionObserver, ResizeObserver, PerformanceObserver, PerformanceEntry, CustomElementRegistry,
	Range, TreeWalker, NodeIterator: TreeWalker, NodeFilter, Location, History, Storage, Window,
	CSSStyleSheet, CSSRule, CSSStyleRule, CSSMediaRule, StyleSheet: CSSStyleSheet,
	DOMPoint, DOMPointReadOnly, DOMMatrix, DOMMatrixReadOnly, WebKitCSSMatrix: DOMMatrix,
	URL, URLSearchParams, TextEncoder, TextDecoder, Blob, File, FileReader, FormData, Headers, Request,
	Response, ReadableStream, AbortController, AbortSignal, XMLHttpRequest, XMLHttpRequestEventTarget,
	XMLHttpRequestUpload, MediaQueryList, MessageChannel, MessagePort, BroadcastChannel, DOMParser,
	XMLSerializer, Image, Option, Audio, HTMLUnknownElement,
	document, location, history, navigator, screen, performance, console, crypto, localStorage,
	sessionStorage, customElements, CSS, trustedTypes, visualViewport: undefined,
	setTimeout: (f, ms, ...args) => settimer(f, ms, args, false),
	setInterval: (f, ms, ...args) => settimer(f, ms, args, true),
	clearTimeout: (id) => { TIMERS.delete(+id); },
	clearInterval: (id) => { TIMERS.delete(+id); },
	requestAnimationFrame, cancelAnimationFrame, requestIdleCallback,
	cancelIdleCallback: (id) => { TIMERS.delete(+id); },
	queueMicrotask(f) {
		if (typeof f !== 'function')
			throw new TypeError("Failed to execute 'queueMicrotask' on 'Window': The callback provided as parameter 1 is not a function.");
		Promise.resolve().then(() => { try { f(); } catch (x) { report(x); } });
	},
	structuredClone: (v, opts) => structuredClone(v, opts),
	fetch, atob, btoa, matchMedia, postMessage,
	getComputedStyle: (el) => computedstyle(nodeid(el)),
	getSelection: () => SELECTION,
	scrollTo(x, y) { if (typeof x === 'object' && x) { y = x.top; x = x.left; } N.scroll(+x || 0, +y || 0); },
	scroll(x, y) { G.scrollTo(x, y); },
	scrollBy(x, y) { if (typeof x === 'object' && x) { y = x.top; x = x.left; } const v = N.viewport(); N.scroll(v[2] + (+x || 0), v[3] + (+y || 0)); },
	alert(m) { N.log('alert: ' + str(m === undefined ? '' : m)); },
	confirm(m) { N.log('confirm: ' + str(m === undefined ? '' : m)); return false; },
	prompt(m) { N.log('prompt: ' + str(m === undefined ? '' : m)); return null; },
	print() {}, stop() {}, focus() {}, blur() {}, close() {},
	open() { return null; },
	moveTo() {}, moveBy() {}, resizeTo() {}, resizeBy() {},
	reportError: (x) => report(x),
	captureEvents() {}, releaseEvents() {},
	name: '', status: '', closed: false, opener: null, length: 0, frameElement: null,
	isSecureContext: true, crossOriginIsolated: false, originAgentCluster: false,
	external: {AddSearchProvider() {}, IsSearchProviderInstalled() {}},
	clientInformation: navigator, styleMedia: {type: 'screen', matchMedium: () => false},
	speechSynthesis: undefined, indexedDB: undefined, caches: undefined, ontouchstart: undefined,
});
for (const [k, f] of [['innerWidth', () => N.viewport()[0]], ['innerHeight', () => N.viewport()[1]],
	['outerWidth', () => N.viewport()[0]], ['outerHeight', () => N.viewport()[1]],
	['scrollX', () => N.viewport()[2]], ['scrollY', () => N.viewport()[3]],
	['pageXOffset', () => N.viewport()[2]], ['pageYOffset', () => N.viewport()[3]],
	['screenX', () => 0], ['screenY', () => 0], ['screenLeft', () => 0], ['screenTop', () => 0],
	['devicePixelRatio', () => 1], ['event', () => currentEvent], ['origin', () => origin(parseurl(pageurl))]])
	defineProperty(G, k, {get: f, set(v) { defineProperty(G, k, {value: v, writable: true, configurable: true}); }, configurable: true});
defineProperty(G, 'location', {get: () => location, set: (v) => navigate(v, false), configurable: false});
defineProperty(G, 'document', {value: document, writable: false, configurable: false});

// ---- scripts ----

const STARTED = new Set();	// scripts run, or begun
const PARSERSCRIPT = new Set();	// scripts the parser put in
const ASYNCOFF = new Set();
let loading = true;

const JSTYPES = new Set(['application/ecmascript', 'application/javascript', 'application/x-ecmascript',
	'application/x-javascript', 'text/ecmascript', 'text/javascript', 'text/javascript1.0', 'text/javascript1.1',
	'text/javascript1.2', 'text/javascript1.3', 'text/javascript1.4', 'text/javascript1.5', 'text/jscript',
	'text/livescript', 'text/x-ecmascript', 'text/x-javascript']);

function scripttype(i) {
	const t = N.attr(i, 'type'), l = N.attr(i, 'language');
	if (t === null && (l === null || l === '') || t === '')
		return 'classic';
	if (t === null)
		return JSTYPES.has('text/' + l.toLowerCase()) ? 'classic' : null;
	const tt = t.trim().toLowerCase();
	if (JSTYPES.has(tt))
		return 'classic';
	if (tt === 'module')
		return 'module';
	return null;
}

function execute(i, type, src, url) {
	const prev = currentScript;
	currentScript = type === 'classic' ? wrap(i) : null;
	try {
		const [bad, v] = type === 'module' ? N.evalmodule(src, url) : N.eval(src, url);
		if (bad)
			report(v);
	} finally {
		currentScript = prev;
	}
}

// the document's scripts' sources, fetched at once and in parallel (as
// a browser's preload scanner does), by URL: [status, text, url] when come
// a classic script element's request: no-cors, with cookies
const SCRIPTFETCH = 'mode no-cors\ncredentials include\n';

const PREFETCH = new Map();

function prefetch(url) {
	if (PREFETCH.has(url))
		return;
	const ent = {done: false, r: null};
	PREFETCH.set(url, ent);
	startfetch('GET', url, SCRIPTFETCH, null, (status, st, u, header, body, err) => {
		ent.done = true;
		ent.r = err !== undefined ? [0, '', url] : [status, body || '', u];
		if (waitingfor === url) {
			waitingfor = null;
			queuetask(step);
		}
	});
}

let waitingfor = null;

// run one script of the document's, in order; false if it must wait for its source
function runscript(i) {
	if (STARTED.has(i))
		return true;
	const type = scripttype(i);
	if (!type || type === 'classic' && N.attr(i, 'nomodule') !== null) {
		STARTED.add(i);
		return true;
	}
	const src = N.attr(i, 'src');
	if (src === null) {
		STARTED.add(i);
		execute(i, type, N.textof(i), pageurl);
		return true;
	}
	const url = resolve(src.trim());
	if (url === null || src.trim() === '') {
		STARTED.add(i);
		queuetask(() => fire(wrap(i), 'error', {}));
		return true;
	}
	prefetch(url);
	const ent = PREFETCH.get(url);
	if (!ent.done) {
		waitingfor = url;
		return false;
	}
	STARTED.add(i);
	const r = ent.r;
	if (r[0] < 200 || r[0] >= 300) {
		fire(wrap(i), 'error', {});
		return true;
	}
	execute(i, type, r[1], r[2]);
	fire(wrap(i), 'load', {});
	return true;
}

// a script put into the document by script: an inline one runs now, one
// with a source when it has come
function scriptinserted(i) {
	if (loading || STARTED.has(i))
		return;
	const src = N.attr(i, 'src');
	if (src === null) {
		if (N.first(i) === 0)
			return;		// not started: one that gets text later runs then
		runscript(i);
		return;
	}
	STARTED.add(i);
	const type = scripttype(i);
	if (!type || type === 'classic' && N.attr(i, 'nomodule') !== null)
		return;
	const url = resolve(src.trim());
	if (url === null || src.trim() === '') {
		queuetask(() => fire(wrap(i), 'error', {}));
		return;
	}
	startfetch('GET', url, SCRIPTFETCH, null, (status, st, u, header, body, err) => {
		if (err !== undefined || status < 200 || status >= 300) {
			fire(wrap(i), 'error', {});
			return;
		}
		execute(i, type, body || '', u);
		fire(wrap(i), 'load', {});
	});
}

// a handler from an on... attribute, made when first wanted
function attrhandler(t, type) {
	let el = null;
	if (t === G) {
		if (WINDOWEVENTS.includes(type) || ['load', 'error', 'resize', 'scroll', 'focus', 'blur'].includes(type))
			el = document.body;
	} else if (isnode(t) && N.kind(idof(t)) === ELEMENT)
		el = t;
	if (!el)
		return undefined;
	const src = N.attr(idof(el), 'on' + lower(type));
	if (src === null)
		return undefined;
	const key = src;
	let cache = ATTRHANDLERS.get(t);
	if (!cache)
		ATTRHANDLERS.set(t, cache = new Map());
	const c = cache.get(type);
	if (c && c[0] === key)
		return c[1];
	const f = inlinehandler(el, 'on' + type, src);
	cache.set(type, [key, f]);
	return f;
}
const ATTRHANDLERS = new WeakMap();

// what clicking does when no handler prevents it, for a click from script
function defaultaction(i, submitter) {
	for (let p = i; p && N.kind(p) === ELEMENT; p = N.parent(p)) {
		const name = N.name(p);
		if ((name === 'a' || name === 'area') && N.attr(p, 'href') !== null) {
			const href = N.attr(p, 'href').trim();
			if (href.startsWith('#') || /^javascript:/i.test(href) || N.attr(p, 'target') === null || N.attr(p, 'target') === '_self')
				navigate(href, false);
			return;
		}
		if (name === 'button' || name === 'input' && /^(submit|image)$/i.test(N.attr(p, 'type') || (name === 'button' ? 'submit' : ''))) {
			const t = (N.attr(p, 'type') || 'submit').toLowerCase();
			if (t !== 'submit' && t !== 'image')
				return;
			const f = wrap(p).form;
			if (f && fire(f, 'submit', {bubbles: true, cancelable: true, submitter: wrap(p)}, SubmitEvent))
				submitform(idof(f), p);
			return;
		}
		if (name === 'input' && /^(checkbox|radio)$/i.test(N.attr(p, 'type') || '')) {
			const w = wrap(p);
			w.checked = N.attr(p, 'type').toLowerCase() === 'radio' ? true : !w.checked;
			fire(w, 'input', {bubbles: true}, InputEvent);
			fire(w, 'change', {bubbles: true});
			return;
		}
	}
}

function element(i) {
	while (i && N.kind(i) !== ELEMENT)
		i = N.parent(i);
	return i;
}

function focusable(i) {
	for (let p = i; p && N.kind(p) === ELEMENT; p = N.parent(p))
		if (['input', 'select', 'textarea', 'button', 'a'].includes(N.name(p)) || N.attr(p, 'tabindex') !== null)
			return p;
	return 0;
}

const KEYNAMES = {8: 'Backspace', 9: 'Tab', 10: 'Enter', 13: 'Enter', 27: 'Escape', 127: 'Delete', 0xf00e: 'ArrowUp',
	0x80: 'ArrowDown', 0xf011: 'ArrowLeft', 0xf012: 'ArrowRight', 0xf00d: 'Home', 0xf018: 'End', 0xf00f: 'PageUp',
	0xf013: 'PageDown'};

function hostevent(kind, node, x, y, key) {
	switch (kind) {
	case 'click': {
		const i = element(node);
		if (!i)
			return false;
		const w = wrap(i);
		const [, , sx, sy] = N.viewport();
		const init = {bubbles: true, cancelable: true, composed: true, view: G, detail: 1, clientX: x - sx, clientY: y - sy,
			pageX: x, pageY: y, screenX: x - sx, screenY: y - sy, x: x - sx, y: y - sy, button: 0, buttons: 1};
		fire(w, 'pointerdown', init, PointerEvent);
		fire(w, 'mousedown', init, MouseEvent);
		const f = focusable(i);
		if (f)
			wrap(f).focus();
		else if (focused && W[focused])
			W[focused].blur();
		init.buttons = 0;
		fire(w, 'pointerup', init, PointerEvent);
		fire(w, 'mouseup', init, MouseEvent);
		if (!fire(w, 'click', init, MouseEvent))
			return true;
		// a javascript: link runs here, not in the host
		for (let p = i; p && N.kind(p) === ELEMENT; p = N.parent(p))
			if (N.name(p) === 'a' && N.attr(p, 'href') !== null) {
				const href = N.attr(p, 'href').trim();
				if (/^javascript:/i.test(href)) {
					runjsurl(href);
					return true;
				}
				break;
			}
		return false;
	}
	case 'input': {
		const i = element(node);
		if (!i)
			return false;
		fire(wrap(i), 'input', {bubbles: true, composed: true}, InputEvent);
		fire(wrap(i), 'change', {bubbles: true});
		return false;
	}
	case 'submit':
		return !fire(wrap(node), 'submit', {bubbles: true, cancelable: true, submitter: wrap(x || 0)}, SubmitEvent);
	case 'key': {
		const i = element(node) || focused || idof(document.body || document.documentElement);
		const w = wrap(i);
		const name = KEYNAMES[key] || String.fromCodePoint(key);
		const init = {bubbles: true, cancelable: true, composed: true, view: G, key: name, code: name.length === 1 ? 'Key' + upper(name) : name,
			keyCode: key === 10 ? 13 : key < 128 ? key : 0, which: key === 10 ? 13 : key < 128 ? key : 0};
		let prevented = !fire(w, 'keydown', init, KeyboardEvent);
		if (!prevented && name.length === 1)
			prevented = !fire(w, 'keypress', Object.assign({}, init, {charCode: key}), KeyboardEvent);
		fire(w, 'keyup', init, KeyboardEvent);
		return prevented;
	}
	case 'resize':
		fire(G, 'resize', {}, UIEvent);
		scheduleobserve();
		return false;
	case 'scroll':
		fire(document, 'scroll', {bubbles: true});
		scheduleobserve();
		return false;
	}
	return false;
}

// the page's load: its scripts in document order, each a task of its
// own (so that one slow script does not hold the page, and the page is
// drawn between them), then the load events
function start() {
	navigationtiming();
	importmaps();
	for (const s of N.descendants(1, 'name', 'script')) {
		PARSERSCRIPT.add(s);
		const src = N.attr(s, 'src');
		if (src !== null && scripttype(s) !== null && N.attr(s, 'nomodule') === null) {
			const u = resolve(src.trim());
			if (u !== null && src.trim() !== '')
				prefetch(u);
		}
	}
	step();
}

function step() {
	const next = N.descendants(1, 'name', 'script').find((s) => !STARTED.has(s) && N.ns(s) === 0);
	if (next === undefined) {
		loaded();
		return;
	}
	importmaps();
	if (runscript(next))
		queuetask(step);
}

function loaded() {
	loading = false;
	readystate = 'interactive';
	fire(document, 'readystatechange', {});
	fire(document, 'DOMContentLoaded', {bubbles: true});
	N.drain();
	readystate = 'complete';
	fire(document, 'readystatechange', {});
	const ev = trusted(new Event('load'));
	ev._target = document;
	dispatchwindow(ev);
	dispatchwindow(trusted(new PageTransitionEvent('pageshow', {persisted: false})));
	scheduleobserve();
}

// an event at the window whose target is the document (load), as browsers send it
function dispatchwindow(ev) {
	ev[DISPATCHING] = true;
	if (!ev._target)
		ev._target = G;
	ev._path = [G];
	const saved = currentEvent;
	currentEvent = ev;
	try {
		ev._phase = 2;
		invoke(G, ev, 2);
	} finally {
		currentEvent = saved;
		ev._phase = 0;
		ev._current = null;
		ev[DISPATCHING] = false;
	}
}

// ---- import maps ----

const IMPORTS = [], SCOPES = [];	// [key, address], keys longest first

function urllike(s) {
	return /^(\.{0,2}\/)/.test(s) ? resolve(s) : (parseurl(s) ? serialize(parseurl(s)) : null);
}

function importmaps() {
	for (const s of N.descendants(1, 'name', 'script')) {
		if ((N.attr(s, 'type') || '').trim().toLowerCase() !== 'importmap' || STARTED.has(s))
			continue;
		STARTED.add(s);
		let m;
		try {
			m = JSON.parse(N.textof(s));
		} catch (x) {
			report(x);
			continue;
		}
		const add = (list, map) => {
			for (const k of Object.keys(map || {})) {
				const key = urllike(k) || k, v = map[k];
				const addr = typeof v === 'string' ? resolve(v) : null;
				if (addr !== null && !list.some(([a]) => a === key))
					list.push([key, addr]);
			}
			list.sort((a, b) => b[0].length - a[0].length);
		};
		add(IMPORTS, m.imports);
		for (const sk of Object.keys(m.scopes || {})) {
			const scope = resolve(sk);
			if (scope === null)
				continue;
			let e = SCOPES.find(([k]) => k === scope);
			if (!e)
				SCOPES.push(e = [scope, []]);
			add(e[1], m.scopes[sk]);
		}
		SCOPES.sort((a, b) => b[0].length - a[0].length);
	}
}

function mapin(list, spec) {
	for (const [k, addr] of list) {
		if (k === spec)
			return addr;
		if (k.endsWith('/') && spec.startsWith(k))
			return addr + spec.slice(k.length);
	}
	return null;
}

function modresolve(base, spec) {
	base = base || baseurl();
	const asurl = /^(\.{0,2}\/)/.test(spec) ? (parseurl(spec, base) ? serialize(parseurl(spec, base)) : null) : (parseurl(spec) ? serialize(parseurl(spec)) : null);
	const key = asurl || spec;
	for (const [scope, list] of SCOPES)
		if (base === scope || scope.endsWith('/') && base.startsWith(scope)) {
			const r = mapin(list, key);
			if (r !== null)
				return r;
		}
	const r = mapin(IMPORTS, key);
	if (r !== null)
		return r;
	if (asurl === null)
		throw new TypeError("Failed to resolve module specifier '" + spec + "': relative references must start with '/', './', or '../'");
	return asurl;
}

// Object.prototype.toString names the interface: [object HTMLDivElement],
// [object Window], as pages test for
for (const k of Reflect.ownKeys(G)) {
	if (typeof k !== 'string' || ENGINEGLOBALS.has(k) || !/^[A-Z]/.test(k))
		continue;
	const d = Object.getOwnPropertyDescriptor(G, k);
	const C = d && d.value;
	if (typeof C !== 'function' || C.name !== k || !C.prototype || Object.prototype.hasOwnProperty.call(C.prototype, Symbol.toStringTag))
		continue;
	defineProperty(C.prototype, Symbol.toStringTag, {value: k, configurable: true});
}
defineProperty(G, Symbol.toStringTag, {value: 'Window', configurable: true});

return {
	start,
	timer: timerfired,
	fetched,
	event: hostevent,
	resolve: modresolve,
};
})
