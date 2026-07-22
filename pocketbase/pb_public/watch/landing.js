/* Лендинг: плитки площадок, меню на телефоне, переход в комнату.
 *
 * Комната живёт отдельной страницей /watch/room/#код — так ссылку можно
 * отправить, открыть в новой вкладке и вернуться назад кнопкой браузера.
 */
(() => {
  'use strict';

  const $ = (s) => document.querySelector(s);

  const PLATFORMS = [
    ['YouTube', '#FF0033', 'M8 5.5v13l11-6.5z', 'youtube.com · youtu.be'],
    ['VK Видео', '#0077FF', 'M4 7h3c.4 3.6 2 5.6 3.2 5.9V7h2.8v4.3c1.2-.1 2.4-1.5 2.8-4.3H19c-.3 2.2-1.4 3.9-2.4 4.6 1 .6 2.3 2 2.9 4.4h-3c-.5-1.6-1.6-2.9-3-3v3H10C6.7 16 4.6 12.4 4 7z', 'vk.com · vkvideo.ru'],
    ['Rutube', '#0D1117', 'M5 6h9.5c2.2 0 3.5 1.2 3.5 3s-1.3 3-3.5 3H12l4 6h-3l-3.6-6H8v6H5V6zm3 2.4v2.2h6c.7 0 1.1-.4 1.1-1.1S14.7 8.4 14 8.4H8z', 'rutube.ru'],
    ['Vimeo', '#17D5FF', 'M20 8.8c-.1 2-1.5 4.7-4.2 8.2-2.8 3.6-5.2 5.4-7.1 5.4-1.2 0-2.2-1.1-3-3.3l-1.6-6C3.5 10.9 3 9.8 2.4 9.8c-.1 0-.6.3-1.4.9L0 9.6c1-.9 2-1.8 3-2.7 1.3-1.2 2.3-1.8 3-1.8 1.6-.2 2.6 1 3 3.4.4 2.7.7 4.3.9 5 .5 2.3 1 3.4 1.6 3.4.5 0 1.2-.7 2.1-2.2.9-1.4 1.4-2.5 1.5-3.3.1-1-.3-1.5-1.4-1.5-.5 0-1 .1-1.5.3.9-3.1 2.7-4.6 5.3-4.5 1.9.1 2.8 1.4 2.7 3.8z', 'vimeo.com'],
  ];

  function drawTiles() {
    const box = $('#tiles');
    if (!box) return;
    box.innerHTML = PLATFORMS.map(([name, color, path, hint]) => `
      <article class="tile">
        <svg viewBox="0 0 24 24" width="30" height="30" aria-hidden="true">
          <path d="${path}" fill="${color}"/>
        </svg>
        <span class="tile__name">${name}</span>
        <span class="tile__hint">${hint}</span>
      </article>`).join('');
  }

  function newRoom() {
    // Без похожих символов: код диктуют вслух.
    const abc = 'abcdefghjkmnpqrstuvwxyz23456789';
    let out = '';
    for (let i = 0; i < 6; i++) out += abc[Math.floor(Math.random() * abc.length)];
    return out;
  }

  const go = (code) => { location.href = 'room/#' + code; };

  window.addEventListener('DOMContentLoaded', () => {
    drawTiles();
    if (window.I18N) I18N.mount();

    $('#create').addEventListener('click', () => go(newRoom()));

    $('#join').addEventListener('click', () => {
      const code = ($('#joinCode').value || '').toLowerCase().replace(/[^a-z0-9]/g, '');
      if (code.length >= 4) go(code);
      else $('#joinCode').focus();
    });
    $('#joinCode').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') $('#join').click();
    });

    const drawer = $('#drawer');
    $('#burger').addEventListener('click', () => { drawer.hidden = !drawer.hidden; });
    drawer.querySelectorAll('a').forEach((a) => {
      a.addEventListener('click', () => { drawer.hidden = true; });
    });
  });
})();
