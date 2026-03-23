const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage();
  const errors = [];
  page.on('console', (msg) => {
    const text = msg.text();
    if (msg.type() === 'error') errors.push(`console:${text}`);
    console.log(`console:${msg.type()}:${text}`);
  });
  page.on('pageerror', (err) => {
    errors.push(`pageerror:${err.message}`);
    console.log(`pageerror:${err.message}`);
  });
  await page.goto('http://100.104.11.76:3211/', { waitUntil: 'networkidle', timeout: 15000 });
  const initialApprove = await page.locator('[data-task-action="approve"]').count();
  await page.waitForTimeout(18000);
  const finalApprove = await page.locator('[data-task-action="approve"]').count();
  const searchNote = (await page.locator('#task-search-note').textContent()) || '';
  console.log(`initialApprove:${initialApprove}`);
  console.log(`finalApprove:${finalApprove}`);
  console.log(`searchNote:${searchNote}`);
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exit(1);
  }
  await browser.close();
})();
