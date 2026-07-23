/* Проверка настоящей синхронизации: команда, поданная в самом плеере одного,
 * доезжает до второго и применяется у него. */
const { chromium } = require('/home/alelx/.hermes/hermes-agent/node_modules/playwright');
const CASES = [
  { name: 'Vimeo', link: 'https://vimeo.com/76979871', room: 'vim3p8',
    play: () => document.querySelector('#player iframe').contentWindow.postMessage(JSON.stringify({ method: 'play' }), '*'),
    pause: () => document.querySelector('#player iframe').contentWindow.postMessage(JSON.stringify({ method: 'pause' }), '*') },
  { name: 'VK Видео', link: 'https://m.vkvideo.ru/video-211232966_456241445?sh=4', room: 'vks1w4',
    play: () => document.querySelector('#player iframe').contentWindow.postMessage({ method: 'play' }, '*'),
    pause: () => document.querySelector('#player iframe').contentWindow.postMessage({ method: 'pause' }, '*') },
  { name: 'Rutube', link: 'https://rutube.ru/video/c393ba0a3da25ecb838cefde50560c61/', room: 'rts6y2',
    play: () => document.querySelector('#player iframe').contentWindow.postMessage(JSON.stringify({ type: 'player:play', data: {} }), '*'),
    pause: () => document.querySelector('#player iframe').contentWindow.postMessage(JSON.stringify({ type: 'player:pause', data: {} }), '*') },
];
let ok = true;
const check = (n, c, x = '') => { console.log((c ? '  ✓ ' : '  ✗ ') + n, x); if (!c) ok = false; };

// собираем события плеера на стороне партнёра — они докажут, что команда применилась
const listen = (p) => p.addInitScript(() => {
  window.__events = [];
  window.addEventListener('message', (e) => {
    let d = e.data;
    if (typeof d === 'string') { try { d = JSON.parse(d); } catch (_) { return; } }
    if (!d || typeof d !== 'object') return;
    const kind = d.event || d.type;
    if (kind && !/timeupdate|currentTime/.test(kind)) window.__events.push(kind);
  });
});

(async () => {
  const b = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required', '--mute-audio'] });
  for (const c of CASES) {
    console.log(c.name);
    const ctxA = await b.newContext({ viewport: { width: 1300, height: 800 } });
    const a = await ctxA.newPage();
    await a.goto('https://togetherly.day/watch/room/#' + c.room, { waitUntil: 'domcontentloaded' });
    await a.waitForTimeout(2000);
    await a.fill('#link', c.link); await a.click('#apply');
    await a.waitForTimeout(6000);
    check('плеер поднялся', await a.locator('#player iframe').count() === 1);

    const ctxB = await b.newContext({ viewport: { width: 1300, height: 800 } });
    const p2 = await ctxB.newPage();
    await listen(p2);
    await p2.goto('https://togetherly.day/watch/room/#' + c.room, { waitUntil: 'domcontentloaded' });
    await p2.waitForTimeout(6000);
    check('партнёр получил тот же ролик', await p2.locator('#player iframe').count() === 1);

    await a.evaluate(c.play);
    await a.waitForTimeout(14000);
    let ev = await p2.evaluate(() => window.__events.slice());
    check('старт применился у партнёра', ev.some(x => /started|resumed|playing|playProgress|^play$|changeState/.test(x)), JSON.stringify(ev.slice(-4)));

    const mark = ev.length;
    await a.evaluate(c.pause);
    await a.waitForTimeout(12000);
    ev = await p2.evaluate(() => window.__events.slice());
    check('пауза применилась у партнёра', ev.slice(mark).some(x => /paused|pause|changeState/.test(x)), JSON.stringify(ev.slice(mark).slice(0, 4)));
    await ctxA.close(); await ctxB.close();
  }
  console.log(ok ? '\nПРОЙДЕНО' : '\nЕСТЬ ПАДЕНИЯ');
  await b.close();
  process.exit(ok ? 0 : 1);
})();
