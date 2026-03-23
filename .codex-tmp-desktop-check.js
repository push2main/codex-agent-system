const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1400 } });
  await page.goto('http://100.104.11.76:3211/', { waitUntil: 'networkidle', timeout: 15000 });
  console.log(`approval_cards:${await page.locator('.approval-card').count()}`);
  console.log(`approve_buttons:${await page.locator('[data-task-action="approve"]').count()}`);
  console.log(`pending_visible:${await page.locator('[data-task-scope="pending"]').isVisible()}`);
  console.log(`logs_details:${await page.locator('.logs-panel').count()}`);
  await page.screenshot({ path: '/tmp/codex-dashboard-desktop-check.png', fullPage: true });
  await browser.close();
})();
