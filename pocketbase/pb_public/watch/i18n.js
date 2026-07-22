/* Русский и английский для лендинга и комнаты.
 *
 * Тексты лежат в одном словаре, разметка помечена data-i18n. Язык берётся из
 * выбора человека, а если выбора не было — из языка браузера. Русский
 * показываем только тем, у кого браузер русский: остальным английский понятнее.
 */
(() => {
  'use strict';

  const DICT = {
    ru: {
      'nav.how': 'Как работает',
      'nav.where': 'Площадки',
      'nav.privacy': 'Приватность',
      'nav.app': 'Приложение',

      'hero.eyebrow': 'Комната на двоих в браузере',
      'hero.title1': 'СМОТРИМ',
      'hero.title2': 'ОДНО',
      'hero.title3': 'КИНО',
      'hero.lead': 'Один тайм-код на двоих. Пауза, перемотка и чат приезжают партнёру мгновенно.',
      'hero.create': 'Создать комнату',
      'hero.code': 'Код',
      'hero.join': 'Войти',
      'hero.note': 'Без регистрации. Комната открывается за секунду.',

      'demo.label': 'Пример комнаты',
      'demo.code': 'Код',
      'demo.viewers': 'Зрителей',
      'demo.sync': 'Синхронно · расхождение 0.2 с',
      'demo.msg1': 'уже включила',
      'demo.msg2': 'догоняю',

      'how.kicker': '→ Как это работает',
      'how.1.title': 'Создайте',
      'how.1.text': 'Комната появляется сразу и живёт, пока вы в ней. Регистрация не нужна.',
      'how.2.title': 'Позовите',
      'how.2.text': 'Отправьте ссылку. Партнёр открывает её и оказывается рядом.',
      'how.3.title': 'Смотрите',
      'how.3.text': 'Поставил паузу один, встала у обоих. Время подтягивается само.',

      'where.kicker': '→ Откуда смотреть',
      'where.foot': 'Вставьте ссылку на ролик или фильм с любой из площадок. Своё видео тоже подойдёт: прямая ссылка на файл открывается как есть.',

      'privacy.kicker': '→ Что остаётся на сервере',
      'privacy.title': 'Ничего',
      'privacy.lead': 'Комната существует, пока в ней есть люди. Закрыли вкладки, и она исчезла вместе со ссылкой на видео и перепиской. В базе не появляется ни одной записи.',
      'privacy.1.title': 'Без аккаунта',
      'privacy.1.text': 'Вход анонимный, почта не нужна.',
      'privacy.2.title': 'Без истории',
      'privacy.2.text': 'Сообщения живут только в открытых вкладках.',
      'privacy.3.title': 'Без файлов',
      'privacy.3.text': 'Видео отдаёт площадка, а не мы.',

      'promo.kicker': '→ А ещё есть приложение',
      'promo.title': 'Togetherly для пар',
      'promo.text': 'Общие воспоминания, календарь настроений, подарки друг другу и виджеты на экране телефона.',
      'promo.btn': 'Скачать',

      'foot.privacy': 'Конфиденциальность',
      'foot.terms': 'Условия',

      // комната
      'room.waiting': 'Ждём партнёра',
      'room.waitingText': 'Отправьте ссылку — как только он откроет её, начнём.',
      'room.copy': 'Скопировать ссылку',
      'room.copied': 'Ссылка скопирована',
      'room.share': 'Поделиться',
      'room.code': 'Код комнаты',
      'room.alone': 'вы один',
      'room.viewers': 'смотрят: {n}',
      'room.empty': 'Вставьте ссылку на видео',
      'room.linkPlaceholder': 'Ссылка на YouTube, VK, Rutube или Vimeo',
      'room.play': 'Включить',
      'room.chat': 'Чат',
      'room.message': 'Написать…',
      'room.connecting': 'Подключаюсь…',
      'room.ready': 'Комната готова',
      'room.lost': 'Связь потеряна, переподключаюсь…',
      'room.offline': 'Нет связи',
      'room.badLink': 'Ссылка не с той площадки',
      'room.playing': 'Играет: {name}',
      'room.leave': 'Выйти',
      'room.you': 'Вы',
      'room.guest': 'Гость',
      'room.partnerJoined': 'Партнёр в комнате',
    },
    en: {
      'nav.how': 'How it works',
      'nav.where': 'Sources',
      'nav.privacy': 'Privacy',
      'nav.app': 'App',

      'hero.eyebrow': 'A room for two, right in the browser',
      'hero.title1': 'ONE MOVIE',
      'hero.title2': 'TWO',
      'hero.title3': 'SCREENS',
      'hero.lead': 'One timecode for both of you. Pause, seek and chat reach your partner instantly.',
      'hero.create': 'Create a room',
      'hero.code': 'Code',
      'hero.join': 'Join',
      'hero.note': 'No sign-up. The room opens in a second.',

      'demo.label': 'Room preview',
      'demo.code': 'Code',
      'demo.viewers': 'Watching',
      'demo.sync': 'In sync · drift 0.2 s',
      'demo.msg1': 'already playing',
      'demo.msg2': 'catching up',

      'how.kicker': '→ How it works',
      'how.1.title': 'Create',
      'how.1.text': 'The room opens instantly and lives while you are in it. No sign-up.',
      'how.2.title': 'Invite',
      'how.2.text': 'Send the link. Your partner opens it and lands next to you.',
      'how.3.title': 'Watch',
      'how.3.text': 'One of you pauses, it pauses for both. Time catches up on its own.',

      'where.kicker': '→ Where to watch from',
      'where.foot': 'Paste a link from any of these. Your own video works too: a direct file link plays as is.',

      'privacy.kicker': '→ What stays on the server',
      'privacy.title': 'Nothing',
      'privacy.lead': 'The room exists while people are in it. Close the tabs and it is gone, along with the video link and the chat. Not a single record is written.',
      'privacy.1.title': 'No account',
      'privacy.1.text': 'Anonymous entry, no email needed.',
      'privacy.2.title': 'No history',
      'privacy.2.text': 'Messages live only in open tabs.',
      'privacy.3.title': 'No files',
      'privacy.3.text': 'Video comes from the platform, not from us.',

      'promo.kicker': '→ There is an app, too',
      'promo.title': 'Togetherly for couples',
      'promo.text': 'Shared memories, a mood calendar, gifts for each other and widgets on your home screen.',
      'promo.btn': 'Download',

      'foot.privacy': 'Privacy',
      'foot.terms': 'Terms',

      'room.waiting': 'Waiting for your partner',
      'room.waitingText': 'Send the link. The moment they open it, we start.',
      'room.copy': 'Copy link',
      'room.copied': 'Link copied',
      'room.share': 'Share',
      'room.code': 'Room code',
      'room.alone': 'just you',
      'room.viewers': 'watching: {n}',
      'room.empty': 'Paste a video link',
      'room.linkPlaceholder': 'Link to YouTube, VK, Rutube or Vimeo',
      'room.play': 'Play',
      'room.chat': 'Chat',
      'room.message': 'Message…',
      'room.connecting': 'Connecting…',
      'room.ready': 'Room is ready',
      'room.lost': 'Connection lost, reconnecting…',
      'room.offline': 'Offline',
      'room.badLink': 'That link is from another platform',
      'room.playing': 'Playing: {name}',
      'room.leave': 'Leave',
      'room.you': 'You',
      'room.guest': 'Guest',
      'room.partnerJoined': 'Your partner is here',
    },
  };

  const KEY = 'togetherly.watch.lang';

  function detect() {
    const saved = localStorage.getItem(KEY);
    if (saved === 'ru' || saved === 'en') return saved;
    const langs = navigator.languages || [navigator.language || 'en'];
    return langs.some((l) => String(l).toLowerCase().startsWith('ru')) ? 'ru' : 'en';
  }

  const I18N = {
    lang: detect(),

    t(key, vars) {
      let text = (DICT[this.lang] && DICT[this.lang][key]) || DICT.ru[key] || key;
      if (vars) {
        Object.keys(vars).forEach((k) => {
          text = text.replace('{' + k + '}', vars[k]);
        });
      }
      return text;
    },

    apply(root) {
      const scope = root || document;
      scope.querySelectorAll('[data-i18n]').forEach((el) => {
        el.textContent = this.t(el.getAttribute('data-i18n'));
      });
      scope.querySelectorAll('[data-i18n-ph]').forEach((el) => {
        el.placeholder = this.t(el.getAttribute('data-i18n-ph'));
      });
      scope.querySelectorAll('[data-i18n-aria]').forEach((el) => {
        el.setAttribute('aria-label', this.t(el.getAttribute('data-i18n-aria')));
      });
      document.documentElement.lang = this.lang;
      document.querySelectorAll('[data-lang-btn]').forEach((btn) => {
        btn.classList.toggle('is-on', btn.getAttribute('data-lang-btn') === this.lang);
      });
    },

    set(lang) {
      if (lang !== 'ru' && lang !== 'en') return;
      this.lang = lang;
      localStorage.setItem(KEY, lang);
      this.apply();
      document.dispatchEvent(new CustomEvent('langchange', { detail: lang }));
    },

    mount() {
      document.querySelectorAll('[data-lang-btn]').forEach((btn) => {
        btn.addEventListener('click', () => this.set(btn.getAttribute('data-lang-btn')));
      });
      this.apply();
    },
  };

  window.I18N = I18N;
})();
