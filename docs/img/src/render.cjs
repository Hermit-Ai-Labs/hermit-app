// Renders the README figures: <key>/figure.html -> ../<key>-light.png and ../<key>-dark.png (2400 px wide).
//   PW=/path/to/node_modules/playwright node render.cjs [key ...]
// Every figure.html takes ?theme=light|dark and exposes window.figureReady (a promise) and window.figureCheck(),
// which returns { problems: [...] } from its own layout checks (overlaps, text under 13.5 px, text off the canvas).
// pngquant, when installed, shrinks the PNGs; the 28 px transparent corners survive it.
const { chromium } = require(process.env.PW || 'playwright');
const { execFileSync } = require('child_process');
const fs = require('fs'), path = require('path');
const ALL = ['system_overview', 'money_move', 'private_cloud', 'assistant_loop', 'keys_accounts'];
const keys = process.argv.slice(2).length ? process.argv.slice(2) : ALL;
const OUT = process.env.OUT || path.join(__dirname, '..');
(async () => {
  const b = await chromium.launch();
  let bad = 0;
  for (const key of keys) for (const theme of ['light', 'dark']) {
    const p = await b.newPage({ viewport: { width: 1200, height: 1000 }, deviceScaleFactor: 2 });
    const errs = []; p.on('pageerror', e => errs.push(String(e))); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
    await p.goto('file://' + path.join(__dirname, key, 'figure.html') + '?theme=' + theme);
    await p.evaluate(() => window.figureReady);
    const res = await p.evaluate(() => {
      const fig = document.getElementById('fig') || document.body;
      return { h: Math.ceil(fig.getBoundingClientRect().height), problems: window.figureCheck().problems,
        fonts: document.fonts.check("600 19px Geist") && document.fonts.check("450 13.5px 'Geist Mono'") };
    });
    await p.setViewportSize({ width: 1200, height: res.h });
    const file = path.join(OUT, `${key}-${theme}.png`);
    await p.screenshot({ path: file, omitBackground: true, clip: { x: 0, y: 0, width: 1200, height: res.h } });
    await p.close();
    try { execFileSync('pngquant', ['--quality=85-100', '--speed=1', '--strip', '--force', '--output', file, file]); } catch (e) { /* keep the lossless PNG */ }
    const problems = [...errs, ...res.problems, ...(res.fonts ? [] : ['fonts did not load'])];
    bad += problems.length;
    console.log(`${key}-${theme}.png  1200x${res.h}  ${Math.round(fs.statSync(file).size / 1024)} KB  ${problems.length ? '' : 'ok'}`);
    for (const x of problems) console.log('   - ' + x);
  }
  await b.close();
  process.exit(bad ? 1 : 0);
})();
