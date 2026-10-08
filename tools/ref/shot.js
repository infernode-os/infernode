// shot.js - render a URL in headless Chromium, as the reference Charon
// is compared with.
//
//   node tools/ref/shot.js [-js] [-full] <url> <out.png> <width> <height>
//
// Scripts are off unless -js: Charon has no script engine, so the fair
// reference is the page as a script-less browser shows it. -full
// captures the whole page, not just the viewport. The device scale is 1,
// as Charon's is.
//
// Needs Playwright (with its Chromium) where node can require it.

const { chromium } = require('playwright');

(async () => {
	let args = process.argv.slice(2);
	let js = false, full = false;
	while (args.length && args[0][0] === '-') {
		const f = args.shift();
		if (f === '-js') js = true;
		else if (f === '-full') full = true;
		else { console.error('unknown flag ' + f); process.exit(2); }
	}
	if (args.length !== 4) {
		console.error('usage: shot.js [-js] [-full] url out.png width height');
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
	const page = await ctx.newPage();
	try {
		await page.goto(url, { waitUntil: 'load', timeout: 30000 });
	} catch (e) {
		console.error('shot.js: ' + e.message.split('\n')[0]);
	}
	await page.screenshot({ path: out, fullPage: full });
	await browser.close();
})();
