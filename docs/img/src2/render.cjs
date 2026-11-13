// Renders the README figures: <key>/figure.html -> ../<key>.png (1200 CSS px at 2x = 2400 px wide).
// One image per figure. Each has its own colours and a 28 px transparent corner, so it reads as a card on
// GitHub's light and dark pages.
//   PW=/path/to/node_modules/playwright node docs/img/src2/render.cjs [key ...]
// Every page exposes window.figureReady (a promise) and window.figureCheck() -> { problems: [...] }.
// pngquant, when installed, shrinks the PNG in place. PREVIEW=<dir> also writes an 880 px wide copy with Pillow.
const { chromium } = require(process.env.PW || 'playwright');
const { execFileSync } = require('child_process');
const fs = require('fs'), path = require('path');
const ALL = ['system_overview', 'money_move', 'private_cloud', 'assistant_loop', 'keys_accounts', 'black_box', 'ai_insurance'];
const keys = process.argv.slice(2).length ? process.argv.slice(2) : ALL;
const OUT = path.join(__dirname, '..');
(async () => {
  const b = await chromium.launch();
  let bad = 0;
  for (const key of keys) {
    const p = await b.newPage({ viewport: { width: 1200, height: 1000 }, deviceScaleFactor: 2 });
    const errs = []; p.on('pageerror', e => errs.push(String(e))); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
    await p.goto('file://' + path.join(__dirname, key, 'figure.html'));
    await p.evaluate(() => window.figureReady);
    const res = await p.evaluate(() => ({
      h: Math.ceil((document.getElementById('fig') || document.body).getBoundingClientRect().height),
      problems: window.figureCheck().problems,
      dots: document.body.innerText.includes('·'),
      fonts: document.fonts.check("600 58px Geist") && document.fonts.check("500 18px 'Geist Mono'"),
    }));
    await p.setViewportSize({ width: 1200, height: res.h });
    const file = path.join(OUT, key + '.png');
    await p.screenshot({ path: file, omitBackground: true, clip: { x: 0, y: 0, width: 1200, height: res.h } });
    await p.close();
    try { execFileSync('pngquant', ['--quality=80-100', '--speed=1', '--strip', '--force', '--output', file, file]); } catch (e) { /* keep the lossless PNG */ }
    const problems = [...errs, ...res.problems, ...(res.fonts ? [] : ['fonts did not load']), ...(res.dots ? ['middle dot found'] : [])];
    bad += problems.length;
    console.log(`${key}.png  2400x${res.h * 2}  ${Math.round(fs.statSync(file).size / 1024)} KB  ${problems.length ? '' : 'ok'}`);
    for (const x of problems) console.log('   - ' + x);
  }
  await b.close();
  process.exit(bad ? 1 : 0);
})();
