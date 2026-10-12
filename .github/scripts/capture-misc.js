// Captures the online/meta screens: Play Online connect form, room lobby,
// leaderboard and settings.
//
// Requires the DART GAME SERVER (not a plain static server) on :8080:
//   dart run bin/server.dart --port 8080 [--db FILE]
// It serves build/web statically plus /ws and /leaderboard, so the lobby's
// same-origin default (ws://localhost:8080/ws) and the leaderboard fetch
// both work. Build the app first: flutter build web --release --wasm.
//
// Coordinates are CSS px at viewport 1200x800 (the app centers a <=520px
// column; Flutter web renders to canvas, so clicks are raw mouse events).
// Screenshots come out 2x (deviceScaleFactor 2).
const { chromium } = require('playwright');
const path = require('path');
const fs = require('fs');

const OUT = '/tmp/shots2';
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

  const back = async (times = 1) => {
    for (let i = 0; i < times; i++) {
      await page.goBack({ waitUntil: 'networkidle' });
      await page.waitForTimeout(2500);
    }
  };

  // ---- HOME ----
  await page.goto(URL, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForTimeout(5000);

  // ---- PLAY ONLINE (connect form) ----
  // "Play Online" button ≈ (548, 624) CSS
  await page.mouse.click(548, 624);
  await page.waitForTimeout(3000);
  await shot('10-play-online');

  // ---- ROOM CREATION (host lobby with room code) ----
  // "Create a room" button ≈ (599, 526) CSS
  await page.mouse.click(599, 526);
  await page.waitForTimeout(4000); // ws connect + lobby state
  await shot('11-room-creation');

  // ---- LEADERBOARD ----
  await back();
  // Trophy icon ≈ (764, 624) CSS
  await page.mouse.click(764, 624);
  await page.waitForTimeout(6000); // server fetch (may cold-start)
  await shot('12-leaderboard');

  // ---- SETTINGS ----
  await back();
  // Gear icon ≈ (812, 624) CSS
  await page.mouse.click(812, 624);
  await page.waitForTimeout(2500);
  await shot('13-settings');

  await browser.close();
  console.log('done ->', OUT);
}

main().catch((e) => { console.error(e); process.exit(1); });
