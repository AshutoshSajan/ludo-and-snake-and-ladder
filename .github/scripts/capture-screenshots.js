const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const SCREENSHOTS_DIR = path.join(__dirname, '../../assets/screenshots');
const GAME_URL = 'http://localhost:8080';

async function captureScreenshots() {
  // Ensure screenshots directory exists
  if (!fs.existsSync(SCREENSHOTS_DIR)) {
    fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
  }

  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({
    viewport: { width: 1200, height: 800 },
    deviceScaleFactor: 2,
  });

  try {
    console.log('Navigating to game...');
    await page.goto(GAME_URL, { waitUntil: 'networkidle', timeout: 60000 });

    // Wait for Flutter to initialize
    await page.waitForSelector('flt-glass-pane', { timeout: 30000 });
    await page.waitForTimeout(3000); // Extra time for animations/assets

    // 1. Home screen
    console.log('Capturing home screen...');
    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'home.png'),
      fullPage: false,
    });

    // 2. Ludo gameplay - navigate to Ludo game
    console.log('Navigating to Ludo...');
    await page.click('text=Ludo');
    await page.waitForTimeout(2000);
    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'ludo-gameplay.png'),
      fullPage: false,
    });

    // 3. Ludo board view
    console.log('Capturing Ludo board...');
    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'ludo-board.png'),
      fullPage: false,
    });

    // 4. Navigate back and go to Snakes & Ladders
    console.log('Navigating to Snakes & Ladders...');
    await page.goBack();
    await page.waitForTimeout(1000);
    await page.click('text=Snakes');
    await page.waitForTimeout(2000);
    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'snakes-gameplay.png'),
      fullPage: false,
    });

    // 5. Snakes board view
    console.log('Capturing Snakes board...');
    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'snakes-board.png'),
      fullPage: false,
    });

    // 6. Create banner (1200x300)
    console.log('Creating banner...');
    await page.setViewportSize({ width: 1200, height: 300 });
    await page.goto(GAME_URL, { waitUntil: 'networkidle' });
    await page.waitForSelector('flt-glass-pane', { timeout: 30000 });
    await page.waitForTimeout(2000);
    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'banner.png'),
      clip: { x: 0, y: 0, width: 1200, height: 300 },
    });

    console.log('All screenshots captured!');
  } catch (error) {
    console.error('Error capturing screenshots:', error);
    throw error;
  } finally {
    await browser.close();
  }
}

captureScreenshots().catch(() => process.exit(1));