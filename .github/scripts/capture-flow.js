const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const OUT = '/tmp/shots';
const URL = 'http://localhost:8080';

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({
    viewport: { width: 1200, height: 800 },
    deviceScaleFactor: 2,
  });

  const shot = (name, opts = {}) =>
    page.screenshot({ path: path.join(OUT, name + '.png'), ...opts });

  // ---- HOME ----
  await page.goto(URL, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForTimeout(5000);
  await shot('01-home');

  // ---- LUDO ----
  // Ludo card center ~ (598, 370) CSS
  await page.mouse.click(598, 370);
  await page.waitForTimeout(2500);
  await shot('02-ludo-setup');

  // "Start game" button ~ (597, 499) CSS
  await page.mouse.click(597, 499);
  await page.waitForTimeout(3000);
  await shot('03-ludo-game');

  // Roll red corner die (~271, 693 CSS) several times; bot plays between turns.
  // After each roll, tap the four red yard token slots so a multi-choice
  // awaitingMove state still plays a move (single-choice moves auto-play).
  const redYardSlots = [[339, 569], [416, 569], [339, 650], [416, 650]];
  for (let i = 0; i < 10; i++) {
    await page.mouse.click(271, 693);
    await page.waitForTimeout(2000);
    for (const [x, y] of redYardSlots) {
      await page.mouse.click(x, y);
      await page.waitForTimeout(500);
    }
    await page.waitForTimeout(1500);
  }
  await shot('04-ludo-after-rolls');
  // Board-only crop (board spans roughly x 244..954, y 57..772 CSS)
  await shot('05-ludo-board', {
    clip: { x: 244, y: 60, width: 710, height: 710 },
  });

  // ---- SNAKES ----
  await page.goto(URL, { waitUntil: 'networkidle' });
  await page.waitForTimeout(4000);
  // Snakes card center ~ (598, 521) CSS
  await page.mouse.click(598, 521);
  await page.waitForTimeout(2500);
  await shot('06-snakes-setup');

  // "Start game" button ~ (597, 427) CSS
  await page.mouse.click(597, 427);
  await page.waitForTimeout(3000);
  await shot('07-snakes-game');

  // ROLL button ~ (658, 741) CSS several times
  for (let i = 0; i < 8; i++) {
    await page.mouse.click(658, 741);
    await page.waitForTimeout(3500);
  }
  await shot('08-snakes-after-rolls');
  // Board-only crop (board spans roughly x 336..861, y 58..580 CSS)
  await shot('09-snakes-board', {
    clip: { x: 336, y: 58, width: 526, height: 524 },
  });

  await browser.close();
  console.log('done ->', OUT);
}

main().catch((e) => { console.error(e); process.exit(1); });
