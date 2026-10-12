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

    // Wait for Flutter to initialize - just wait, don't rely on selectors
    await page.waitForTimeout(5000);

    // 1. Home screen
    console.log('Capturing home screen...');
    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'home.png'),
      fullPage: false,
    });
    console.log('Captured home.png');

    // 2. Ludo game screen - try to click Ludo button via coordinates
    // Flutter renders to canvas, so text= selectors don't work
    console.log('Attempting to navigate to Ludo game...');
    try {
      // Try clicking at approximate Ludo button position (center-left area)
      await page.mouse.click(300, 350);
      await page.waitForTimeout(3000);
      await page.screenshot({
        path: path.join(SCREENSHOTS_DIR, 'ludo-gameplay.png'),
        fullPage: false,
      });
      console.log('Captured ludo-gameplay.png');
    } catch (e) {
      console.error('Failed to capture ludo-gameplay:', e.message);
      // Fallback: use home image
      fs.copyFileSync(
        path.join(SCREENSHOTS_DIR, 'home.png'),
        path.join(SCREENSHOTS_DIR, 'ludo-gameplay.png')
      );
      console.log('Used home.png as fallback for ludo-gameplay.png');
    }

    // 3. Ludo board view
    console.log('Capturing Ludo board...');
    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'ludo-board.png'),
      fullPage: false,
    });
    console.log('Captured ludo-board.png');

    // 4. Navigate back to home and try Snakes
    console.log('Attempting to navigate to Snakes & Ladders...');
    try {
      // Go back to home
      await page.goto(GAME_URL, { waitUntil: 'networkidle' });
      await page.waitForTimeout(3000);
      
      // Try clicking at approximate Snakes button position (center-right area)
      await page.mouse.click(900, 350);
      await page.waitForTimeout(3000);
      await page.screenshot({
        path: path.join(SCREENSHOTS_DIR, 'snakes-gameplay.png'),
        fullPage: false,
      });
      console.log('Captured snakes-gameplay.png');
    } catch (e) {
      console.error('Failed to capture snakes-gameplay:', e.message);
      // Fallback: use home image
      fs.copyFileSync(
        path.join(SCREENSHOTS_DIR, 'home.png'),
        path.join(SCREENSHOTS_DIR, 'snakes-gameplay.png')
      );
      console.log('Used home.png as fallback for snakes-gameplay.png');
    }

    // 5. Snakes board view
    console.log('Capturing Snakes board...');
    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'snakes-board.png'),
      fullPage: false,
    });
    console.log('Captured snakes-board.png');

    // 6. Create banner (1200x300)
    console.log('Creating banner...');
    await page.setViewportSize({ width: 1200, height: 300 });
    await page.goto(GAME_URL, { waitUntil: 'networkidle' });
    await page.waitForTimeout(3000);
    await page.screenshot({
      path: path.join(SCREENSHOTS_DIR, 'banner.png'),
      clip: { x: 0, y: 0, width: 1200, height: 300 },
    });
    console.log('Captured banner.png');

    console.log('All screenshots captured!');
  } catch (error) {
    console.error('Error capturing screenshots:', error);
    throw error;
  } finally {
    await browser.close();
  }
}

captureScreenshots().catch(() => process.exit(1));