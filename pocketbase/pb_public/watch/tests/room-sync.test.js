const { chromium } = require('/home/alelx/.hermes/hermes-agent/node_modules/playwright');
const VIDEO = 'https://youtu.be/A_rDJ-ckxqA';
const base = 'https://togetherly.day/watch/room/#';
const texts = async (p) => p.locator('#chat .msg:not(.msg--system)').allTextContents();
const open = async (b, room) => {
  const c = await b.newContext(); const p = await c.newPage();
  await p.goto(base + room, { waitUntil: 'domcontentloaded' });
  await p.waitForTimeout(2500);
  return { c, p };
};
const say = async (p, t) => { await p.fill('#message', t); await p.click('#send'); await p.waitForTimeout(900); };

(async () => {
  const b = await chromium.launch();
  let ok = true;
  const check = (name, cond, extra = '') => { console.log((cond ? '  ✓ ' : '  ✗ ') + name, extra); if (!cond) ok = false; };

  // 1. Всё подготовлено заранее
  console.log('1. первый готовит видео и чат, второй заходит позже');
  const a = await open(b, 'sq1a7x');
  await a.p.fill('#link', VIDEO); await a.p.click('#apply'); await a.p.waitForTimeout(1500);
  await say(a.p, 'первое'); await say(a.p, 'второе');
  const c2 = await open(b, 'sq1a7x');
  await c2.p.waitForTimeout(2500);
  check('видео доехало', await c2.p.locator('#player iframe').count() === 1);
  const t2 = await texts(c2.p);
  check('оба сообщения доехали в порядке', JSON.stringify(t2) === JSON.stringify(['Гостьпервое', 'Гостьвторое']), JSON.stringify(t2));

  // 2. Ответ второго виден первому
  console.log('2. второй отвечает');
  await say(c2.p, 'ответ');
  check('первый видит ответ', (await texts(a.p)).some(t => t.includes('ответ')));

  // 3. Третий заходит ещё позже
  console.log('3. третий заходит последним');
  const c3 = await open(b, 'sq1a7x');
  await c3.p.waitForTimeout(2500);
  const t3 = await texts(c3.p);
  check('видео у третьего', await c3.p.locator('#player iframe').count() === 1);
  check('вся переписка у третьего', t3.length === 3, JSON.stringify(t3));
  check('ответ не задвоился у первого', (await texts(a.p)).filter(t => t.includes('ответ')).length === 1);

  // 4. Двое заходят в пустую комнату одновременно
  console.log('4. двое заходят в пустую комнату');
  const [d1, d2] = await Promise.all([open(b, 'sq9zz3'), open(b, 'sq9zz3')]);
  await d1.p.waitForTimeout(2000);
  check('чат пуст, ошибок нет', (await texts(d1.p)).length === 0 && (await texts(d2.p)).length === 0);
  await say(d1.p, 'привет');
  check('обычная переписка работает', (await texts(d2.p)).some(t => t.includes('привет')));

  console.log(ok ? '\nВСЕ ПРОВЕРКИ ПРОЙДЕНЫ' : '\nЕСТЬ ПАДЕНИЯ');
  await b.close();
  process.exit(ok ? 0 : 1);
})();
