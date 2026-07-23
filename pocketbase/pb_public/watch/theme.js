/* Переключатель светлой и тёмной темы.
 *
 * Саму тему ставит короткий скрипт в <head> ещё до отрисовки, иначе страница
 * успевает моргнуть светлым. Здесь только кнопка и запоминание выбора.
 */
(() => {
  'use strict';

  const KEY = 'watch-theme';
  const root = document.documentElement;

  window.addEventListener('DOMContentLoaded', () => {
    const btn = document.getElementById('theme');
    if (!btn) return;

    const sync = () => btn.setAttribute('aria-pressed', String(root.dataset.theme === 'dark'));
    sync();

    btn.addEventListener('click', () => {
      root.dataset.theme = root.dataset.theme === 'dark' ? 'light' : 'dark';
      try { localStorage.setItem(KEY, root.dataset.theme); } catch (_) { /* приватный режим */ }
      sync();
    });
  });
})();
