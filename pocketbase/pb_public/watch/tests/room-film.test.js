const { chromium } = require('/home/alelx/.hermes/hermes-agent/node_modules/playwright');
const MP4 = 'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4';
const FILE = '/tmp/claude-1000/-home-alelx/ed5c7c2d-da97-49de-afd0-3f7cfa359c11/scratchpad/sample.mp4';
const base = 'https://togetherly.day/watch/room/#';
const open = async (b, room) => {
  const c = await b.newContext(); const p = await c.newPage();
  p.on('pageerror', e => console.log('  !! ошибка страницы:', '' + e));
  await p.goto(base + room, { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);
  return p;
};
let ok = true;
const check = (n, c, x = '') => { console.log((c ? '  ✓ ' : '  ✗ ') + n, x); if (!c) ok = false; };

(async () => {
  const b = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required', '--mute-audio'] });

  console.log('1. прямая ссылка на файл');
  const a1 = await open(b, 'flm3k9');
  await a1.fill('#link', MP4);
  await a1.click('#apply');
  await a1.waitForTimeout(2500);
  check('играет в <video>, а не в iframe', await a1.locator('#player video').count() === 1);
  await a1.evaluate(() => { const v = document.querySelector('#player video'); v.currentTime = 5; return v.play().catch(() => {}); });
  await a1.waitForTimeout(2500);
  const b1 = await open(b, 'flm3k9');
  await b1.waitForTimeout(4000);
  check('второй получил то же видео', await b1.locator('#player video').count() === 1);
  const t = await b1.evaluate(() => (document.querySelector('#player video') || {}).currentTime);
  check('второй встал на ту же секунду', t > 3, `у него ${(t || 0).toFixed(1)} с`);

  console.log('2. файл с диска');
  const a2 = await open(b, 'flm7t4');
  await a2.setInputFiles('#file', FILE);
  await a2.waitForTimeout(2000);
  check('свой файл играет', await a2.locator('#player video').count() === 1);
  const b2 = await open(b, 'flm7t4');
  await b2.waitForTimeout(3500);
  const prompt = await b2.locator('#player .player__empty span').textContent().catch(() => '');
  check('партнёру предложено открыть такой же файл', /sample\.mp4/.test(prompt || ''), JSON.stringify(prompt));
  await b2.setInputFiles('#file', FILE);
  await b2.waitForTimeout(2000);
  check('у партнёра файл открылся', await b2.locator('#player video').count() === 1);

  console.log('3. пауза и перемотка ходят в обе стороны');
  await a2.evaluate(() => { const v = document.querySelector('#player video'); v.currentTime = 12; return v.play().catch(() => {}); });
  await a2.waitForTimeout(3000);
  const tb = await b2.evaluate(() => (document.querySelector('#player video') || {}).currentTime);
  check('перемотка догнала партнёра', tb > 9, `у партнёра ${(tb || 0).toFixed(1)} с`);
  await a2.evaluate(() => document.querySelector('#player video').pause());
  await a2.waitForTimeout(2000);
  check('пауза встала у обоих', await b2.evaluate(() => document.querySelector('#player video').paused));

  console.log(ok ? '\nВСЕ ПРОВЕРКИ ПРОЙДЕНЫ' : '\nЕСТЬ ПАДЕНИЯ');
  await b.close();
  process.exit(ok ? 0 : 1);
})();
