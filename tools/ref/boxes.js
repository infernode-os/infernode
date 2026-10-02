// boxes.js - each element's border box in Chromium, scripts off:
//   B /html[1]/body[1]/div[2] x y w h	(or "none" if it has no box)
// the same lines charonshot -b prints, for tools/ref/boxdiff.py.
const { chromium } = require('playwright');
(async () => {
	const [url, w, h] = process.argv.slice(2);
	const b = await chromium.launch({ args: ['--hide-scrollbars'], env: { ...process.env, FONTCONFIG_FILE: require('path').join(__dirname, 'fonts.conf') } });
	const p = await (await b.newContext({ javaScriptEnabled: false, deviceScaleFactor: 1,
		viewport: { width: +w, height: +h } })).newPage();
	await p.goto(url, { waitUntil: 'load', timeout: 30000 }).catch(e => {});
	// a page that navigates (meta refresh) destroys the context: settle, retry
	const run = () => p.evaluate(() => {
		const out = [];
		const walk = (el, path) => {
			for (const c of el.children) {
				let k = 1;
				for (let s = c.previousElementSibling; s; s = s.previousElementSibling)
					if (s.localName === c.localName) k++;
				const pp = path + '/' + c.localName + '[' + k + ']';
				const rs = c.getClientRects();
				if (rs.length === 0) out.push('B ' + pp + ' none');
				else {
					const r = c.getBoundingClientRect();
					out.push('B ' + pp + ' ' + [r.x + scrollX, r.y + scrollY, r.width, r.height].map(Math.round).join(' '));
				}
				walk(c, pp);
			}
		};
		walk(document, '');
		return out;
	});
	let lines;
	for (let i = 0; ; i++) {
		try { lines = await run(); break; }
		catch (e) { if (i >= 3) throw e; await p.waitForLoadState('load').catch(() => {}); await p.waitForTimeout(300); }
	}
	console.log(lines.join('\n'));
	await b.close();
})();
