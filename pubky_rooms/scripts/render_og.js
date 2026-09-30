// Renders the share image priv/static/images/og.png (1200×630) from assets/og/index.html
// with the same Chromium the QA scripts use. Run from pubky_rooms/:
//
//   NODE_PATH=/path/to/node_modules/with/playwright node scripts/render_og.js
//
// (Playwright is not a dependency of this project; any checkout that has it works,
// e.g. NODE_PATH=~/CODE/pubky-app/node_modules.) Commit the PNG; the source HTML is
// the thing to edit. Nothing here runs in production.
const path = require('path');
const { chromium } = require('playwright');

const source = path.resolve(__dirname, '../assets/og/index.html');
const target = path.resolve(__dirname, '../priv/static/images/og.png');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.goto(`file://${source}`, { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: target, type: 'png', clip: { x: 0, y: 0, width: 1200, height: 630 } });
  await browser.close();
  console.log(`wrote ${target}`);
})().catch((e) => { console.error(e); process.exit(1); });
