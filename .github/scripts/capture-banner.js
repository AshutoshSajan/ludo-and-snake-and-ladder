// Renders .github/scripts/banner.html to assets/screenshots/banner.png
// at 2x (2400x800 from a 1200x400 CSS canvas). Needs --allow-file-access-
// from-files so the @font-face rules can load the bundled Roboto TTFs.
const path = require('path');
const { chromium } = require('playwright');

(async () => {
  // Local runs can point at an installed Chrome; CI keeps using the bundle.
  const launchOptions = { args: ['--allow-file-access-from-files'] };
  if (process.env.CHROME_PATH) {
    launchOptions.executablePath = process.env.CHROME_PATH;
  }
  const browser = await chromium.launch(launchOptions);
  const page = await browser.newPage({
    viewport: { width: 1200, height: 400 },
    deviceScaleFactor: 2,
  });
  const html = 'file://' + path.resolve(__dirname, 'banner.html');
  await page.goto(html, { waitUntil: 'networkidle' });
  await page.evaluate(() => document.fonts.ready);
  const out = path.resolve(__dirname, '../../assets/screenshots/banner.png');
  await page.screenshot({ path: out, clip: { x: 0, y: 0, width: 1200, height: 400 } });
  console.log('wrote ' + out);
  await browser.close();
})();
