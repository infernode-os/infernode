// shot.js - render a URL in headless Chromium, as the reference Charon
// is compared with.
//
//   node tools/ref/shot.js [-js] [-full] [-local] <url> <out.png> <width> <height>
//
// Scripts are off unless -js: Charon has no script engine, so the fair
// reference is the page as a script-less browser shows it. -full
// captures the whole page, not just the viewport. -local refuses every
// request off the loopback: the corpus is served with no network, as
// Charon has none in CI, and a font fetched from Google's servers made
// the reference a page Charon was never given. The device scale is 1,
// as Charon's is.
//
// Needs Playwright (with its Chromium) where node can require it.

const { chromium } = require('playwright');

(async () => {
	let args = process.argv.slice(2);
	let js = false, full = false, local = false;
	while (args.length && args[0][0] === '-') {
		const f = args.shift();
		if (f === '-js') js = true;
		else if (f === '-full') full = true;
		else if (f === '-local') local = true;
		else { console.error('unknown flag ' + f); process.exit(2); }
	}
	if (args.length !== 4) {
		console.error('usage: shot.js [-js] [-full] [-local] url out.png width height');
		process.exit(2);
	}
	const [url, out, w, h] = args;
	// the faces Charon has (see fonts.conf)
	// no scrollbar: Charon's viewport is the whole window
	const opts = { args: ['--hide-scrollbars'], env: { ...process.env, FONTCONFIG_FILE: require('path').join(__dirname, 'fonts.conf') } };
	if (process.env.CHROMIUM_PATH) opts.executablePath = process.env.CHROMIUM_PATH;
	const browser = await chromium.launch(opts);
	const ctx = await browser.newContext({
		viewport: { width: +w, height: +h },
		deviceScaleFactor: 1,
		javaScriptEnabled: js,
		colorScheme: 'light',	// as Charon's prefers-color-scheme answers; a dark host theme otherwise leaks in
	});
	if (local)
		await ctx.route('**/*', r => {
			const h = new URL(r.request().url()).hostname;
			if (h === '127.0.0.1' || h === 'localhost' || r.request().url().startsWith('data:'))
				return r.continue();
			return r.abort();
		});
	const page = await ctx.newPage();
	try {
		await page.goto(url, { waitUntil: 'load', timeout: 30000 });
	} catch (e) {
		console.error('shot.js: ' + e.message.split('\n')[0]);
	}
	await page.screenshot({ path: out, fullPage: full });
	await browser.close();
})();
