const { chromium } = require('/home/alelx/.hermes/hermes-agent/node_modules/playwright');
const CASES = [
  { name: 'MEGA',        room: 'mgr7k2', link: 'https://mega.nz/file/cmgh1T6A#kmPJ2Rjy8yiF2wf28DzZSRvUDioluabBlhZODNxazXE' },
  { name: 'Dropbox',     room: 'dbr4m9', link: 'https://www.dropbox.com/scl/fi/ii31onxewykgdrpohh47a/VID_20260610_173310.mp4?rlkey=01fhb6uci7ab6p66qyagxyid5&st=xk5vlcd6&dl=0' },
  { name: 'Яндекс.Диск', room: 'ydr8t3', link: 'https://disk.yandex.ru/i/h8Mv3-C3iWBAeA' },
];
let ok = true;
const check = (n, c, x = '') => { console.log((c ? '  ✓ ' : '  ✗ ') + n, x); if (!c) ok = false; };

(async () => {
  const b = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required', '--mute-audio'] });
  for (const c of CASES) {
    console.log('\n' + c.name);
    const ctx = await b.newContext({ viewport: { width: 1280, height: 800 } });
    const p = await ctx.newPage();
    p.on('pageerror', e => console.log('  !! ошибка страницы:', ('' + e).slice(0, 120)));
    await p.goto('https://togetherly.day/watch/room/#' + c.room, { waitUntil: 'domcontentloaded' });
    await p.waitForTimeout(2500);
    await p.fill('#link', c.link);
    await p.click('#apply');
    await p.waitForTimeout(9000);

    const info = await p.evaluate(() => {
      const v = document.querySelector('#player video');
      const f = document.querySelector('#player iframe');
      return {
        вид: v ? 'наш плеер' : f ? 'кадр площадки' : 'ничего',
        адрес: (v && v.currentSrc || f && f.src || '').slice(0, 90),
        длительность: v ? (v.duration || 0) : null,
        готовность: v ? v.readyState : null,
        ошибкаВидео: v && v.error ? v.error.code : null,
        статус: document.querySelector('#status').textContent,
        пульт: !document.querySelector('#manual').hidden,
      };
    });
    console.log('   ', JSON.stringify(info, null, 0));

    if (c.name === 'MEGA') {
      check('кадр MEGA поднялся', info.вид === 'кадр площадки' && /mega\.nz\/embed/.test(info.адрес));
      check('пульт включён (управления у MEGA нет)', info.пульт === true);
    } else {
      check('играет в нашем плеере', info.вид === 'наш плеер');
      check('файл реально открылся', (info.длительность || 0) > 0 && !info.ошибкаВидео,
        `длительность ${Math.round(info.длительность || 0)} с, готовность ${info.готовность}`);
      // партнёр должен получить то же самое
      const p2 = await (await b.newContext({ viewport: { width: 1280, height: 800 } })).newPage();
      await p2.goto('https://togetherly.day/watch/room/#' + c.room, { waitUntil: 'domcontentloaded' });
      await p2.waitForTimeout(9000);
      const d2 = await p2.evaluate(() => {
        const v = document.querySelector('#player video');
        return { есть: !!v, длительность: v ? (v.duration || 0) : 0 };
      });
      check('партнёру доехало и открылось', d2.есть && d2.длительность > 0, `у него ${Math.round(d2.длительность)} с`);
    }
    await ctx.close();
  }
  console.log(ok ? '\nВСЕ ТРИ РАБОТАЮТ' : '\nЕСТЬ ПАДЕНИЯ');
  await b.close();
})();
