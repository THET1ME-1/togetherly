/* Комната совместного просмотра.
 *
 * Сервер ничего не хранит: комната — это канал в Centrifugo, который живёт,
 * пока в нём есть люди. Ссылка на видео и переписка существуют только в
 * открытых вкладках.
 *
 * Синхронизация: тот, кто трогает плеер, шлёт в канал своё состояние
 * (играет/пауза + секунда). Остальные подтягиваются, если разошлись больше
 * чем на полторы секунды — иначе дёрганье от каждого мелкого расхождения.
 */
(() => {
  'use strict';

  const WS = 'wss://togetherly.day/connection/websocket';
  const DRIFT = 1.5;          // допустимое расхождение, секунды
  const HEARTBEAT = 3000;     // как часто ведущий шлёт своё время

  const $ = (sel) => document.querySelector(sel);
  const state = {
    room: '', channel: '', me: '', centrifuge: null, sub: null,
    player: null, kind: '', applying: false, lastSent: 0, viewers: 1,
  };

  const PLATFORMS = [
    ['YouTube', '#FF0033', 'M8 5.5v13l11-6.5z'],
    ['VK', '#0077FF', 'M4 7h3c.4 3.6 2 5.6 3.2 5.9V7h2.8v4.3c1.2-.1 2.4-1.5 2.8-4.3H19c-.3 2.2-1.4 3.9-2.4 4.6 1 .6 2.3 2 2.9 4.4h-3c-.5-1.6-1.6-2.9-3-3v3H10C6.7 16 4.6 12.4 4 7z'],
    ['Rutube', 'currentColor', 'M5 6h9.5c2.2 0 3.5 1.2 3.5 3s-1.3 3-3.5 3H12l4 6h-3l-3.6-6H8v6H5V6zm3 2.4v2.2h6c.7 0 1.1-.4 1.1-1.1S14.7 8.4 14 8.4H8z'],
    ['Vimeo', '#17D5FF', 'M20 8.8c-.1 2-1.5 4.7-4.2 8.2-2.8 3.6-5.2 5.4-7.1 5.4-1.2 0-2.2-1.1-3-3.3l-1.6-6C3.5 10.9 3 9.8 2.4 9.8c-.1 0-.6.3-1.4.9L0 9.6c1-.9 2-1.8 3-2.7 1.3-1.2 2.3-1.8 3-1.8 1.6-.2 2.6 1 3 3.4.4 2.7.7 4.3.9 5 .5 2.3 1 3.4 1.6 3.4.5 0 1.2-.7 2.1-2.2.9-1.4 1.4-2.5 1.5-3.3.1-1-.3-1.5-1.4-1.5-.5 0-1 .1-1.5.3.9-3.1 2.7-4.6 5.3-4.5 1.9.1 2.8 1.4 2.7 3.8z'],
  ];

  function drawPlatforms(el, size) {
    if (!el) return;
    el.innerHTML = PLATFORMS.map(([name, color, path]) =>
      `<span class="chip"><svg viewBox="0 0 24 24" width="${size}" height="${size}" ` +
      `aria-hidden="true"><path d="${path}" fill="${color}"/></svg>${name}</span>`
    ).join('');
  }

  // ── комната ───────────────────────────────────────────────────────────────

  function roomFromHash() {
    return (location.hash || '').replace('#', '').toLowerCase()
      .replace(/[^a-z0-9]/g, '').slice(0, 12);
  }

  function newRoom() {
    // Без похожих символов: код диктуют голосом.
    const abc = 'abcdefghjkmnpqrstuvwxyz23456789';
    let out = '';
    for (let i = 0; i < 6; i++) out += abc[Math.floor(Math.random() * abc.length)];
    return out;
  }

  // ── источники видео ───────────────────────────────────────────────────────

  /** Разбирает ссылку в описание источника или null, если площадка чужая. */
  function parseSource(raw) {
    let url;
    try {
      url = new URL(raw.trim());
    } catch (_) {
      return null;
    }
    const host = url.hostname.replace(/^www\./, '');

    if (host === 'youtu.be') {
      return { kind: 'youtube', id: url.pathname.slice(1) };
    }
    if (host.endsWith('youtube.com')) {
      const v = url.searchParams.get('v');
      if (v) return { kind: 'youtube', id: v };
      const m = url.pathname.match(/\/(embed|shorts|live)\/([^/?]+)/);
      if (m) return { kind: 'youtube', id: m[2] };
    }
    if (host.endsWith('vimeo.com')) {
      const m = url.pathname.match(/\/(\d+)/);
      if (m) return { kind: 'vimeo', id: m[1] };
    }
    if (host.endsWith('vk.com') || host.endsWith('vkvideo.ru')) {
      // vk.com/video-123_456 либо ?z=video-123_456
      const m = (url.pathname + url.search).match(/video(-?\d+)_(\d+)/);
      if (m) return { kind: 'vk', id: m[1] + '_' + m[2] };
    }
    if (host.endsWith('rutube.ru')) {
      const m = url.pathname.match(/\/video\/([0-9a-f]+)/);
      if (m) return { kind: 'rutube', id: m[1] };
    }
    return null;
  }

  function embedUrl(src) {
    switch (src.kind) {
      case 'youtube':
        return `https://www.youtube.com/embed/${src.id}?enablejsapi=1&rel=0&playsinline=1`;
      case 'vimeo':
        return `https://player.vimeo.com/video/${src.id}?api=1&playsinline=1`;
      case 'vk': {
        const [oid, id] = src.id.split('_');
        return `https://vk.com/video_ext.php?oid=${oid}&id=${id}&js_api=1`;
      }
      case 'rutube':
        return `https://rutube.ru/play/embed/${src.id}/`;
      default:
        return '';
    }
  }

  // ── плееры ────────────────────────────────────────────────────────────────
  //
  // У каждой площадки свой способ управления. Общий интерфейс: play, pause,
  // seek, time. Где площадка не отдаёт время (VK, Rutube), синхронизация идёт
  // «вслепую»: команды доходят, а положение подтягивается при старте.

  function mountPlayer(src) {
    const holder = $('#player');
    holder.innerHTML = '';
    state.kind = src.kind;

    const frame = document.createElement('iframe');
    frame.src = embedUrl(src);
    frame.allow = 'autoplay; fullscreen; encrypted-media; picture-in-picture';
    frame.allowFullscreen = true;
    frame.id = 'frame';
    holder.appendChild(frame);

    if (src.kind === 'youtube') {
      state.player = new YT.Player('frame', {
        events: {
          onStateChange: (e) => {
            if (state.applying) return;
            if (e.data === YT.PlayerState.PLAYING) send('play', ytTime());
            if (e.data === YT.PlayerState.PAUSED) send('pause', ytTime());
          },
        },
      });
    } else {
      state.player = { frame };
    }
    setStatus(I18N.t('room.playing', { name: labelOf(src.kind) }));
  }

  const labels = { youtube: 'YouTube', vimeo: 'Vimeo', vk: 'VK Видео', rutube: 'Rutube' };
  const labelOf = (k) => labels[k] || k;

  const ytTime = () => {
    try { return state.player.getCurrentTime() || 0; } catch (_) { return 0; }
  };

  function apply(cmd, at) {
    state.applying = true;
    try {
      if (state.kind === 'youtube' && state.player && state.player.seekTo) {
        const now = ytTime();
        if (Math.abs(now - at) > DRIFT) state.player.seekTo(at, true);
        if (cmd === 'play') state.player.playVideo();
        if (cmd === 'pause') state.player.pauseVideo();
      } else if (state.player && state.player.frame) {
        // Vimeo и VK понимают postMessage; Rutube — свой протокол.
        const w = state.player.frame.contentWindow;
        if (state.kind === 'vimeo') {
          w.postMessage(JSON.stringify({ method: cmd === 'play' ? 'play' : 'pause' }), '*');
          if (cmd === 'play') w.postMessage(JSON.stringify({ method: 'setCurrentTime', value: at }), '*');
        } else if (state.kind === 'vk') {
          w.postMessage(JSON.stringify({ event: cmd === 'play' ? 'play' : 'pause' }), '*');
        } else if (state.kind === 'rutube') {
          w.postMessage(JSON.stringify({ type: 'player:' + cmd, data: {} }), '*');
        }
      }
    } catch (_) { /* плеер ещё не готов — команда придёт со следующим тактом */ }
    setTimeout(() => { state.applying = false; }, 300);
  }

  // ── обмен ────────────────────────────────────────────────────────────────

  function send(type, at, extra) {
    if (!state.sub) return;
    const payload = Object.assign({ t: type, at: at || 0, from: state.me }, extra || {});
    state.sub.publish(payload).catch(() => {});
  }

  function onMessage(data) {
    if (!data || data.from === state.me) return;
    switch (data.t) {
      case 'play':
      case 'pause':
        apply(data.t, data.at);
        break;
      case 'source': {
        const src = parseSource(data.url);
        if (src) { $('#link').value = data.url; mountPlayer(src); }
        break;
      }
      case 'chat':
        addMessage(data.name || I18N.t('room.guest'), data.text, false);
        break;
      case 'sync':
        if (state.kind === 'youtube' && state.player && state.player.getCurrentTime) {
          const diff = Math.abs(ytTime() - data.at);
          if (diff > DRIFT) apply(data.playing ? 'play' : 'pause', data.at);
        }
        break;
    }
  }

  // ── чат ──────────────────────────────────────────────────────────────────

  function addMessage(who, text, mine) {
    const box = $('#chat');
    const el = document.createElement('div');
    el.className = 'msg' + (mine ? ' msg--mine' : '');
    el.innerHTML = `<span class="msg__who"></span>`;
    el.querySelector('.msg__who').textContent = who;
    el.appendChild(document.createTextNode(text));
    box.appendChild(el);
    box.scrollTop = box.scrollHeight;
  }

  function setStatus(text) {
    const a = $('#status'), b = $('#status2');
    if (a) a.textContent = text;
    if (b) b.textContent = text;
  }

  function setViewers(n) {
    state.viewers = n;
    const el = $('#viewers');
    if (el) el.textContent = n === 1 ? I18N.t('room.alone') : I18N.t('room.viewers', { n });
    // Партнёр пришёл — уходим с экрана ожидания в саму комнату.
    if (n > 1) openStage();
  }

  function openStage() {
    if (!$('#waiting').hidden) {
      $('#waiting').hidden = true;
      $('#stage').hidden = false;
      addSystem(I18N.t('room.partnerJoined'));
    }
  }

  function addSystem(text) {
    const box = $('#chat');
    if (!box) return;
    const el = document.createElement('div');
    el.className = 'msg msg--system';
    el.textContent = text;
    box.appendChild(el);
    box.scrollTop = box.scrollHeight;
  }

  // ── подключение ──────────────────────────────────────────────────────────

  async function connect(room) {
    const res = await fetch('/api/watch/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ room }),
    });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || 'token');

    state.room = room;
    state.me = data.userId;
    state.channel = data.channel;

    const centrifuge = new Centrifuge(WS, { token: data.connectionToken });
    const sub = centrifuge.newSubscription(data.channel, {
      token: data.subscriptionToken,
    });

    sub.on('publication', (ctx) => onMessage(ctx.data));
    sub.on('subscribed', (ctx) => {
      setStatus(I18N.t('room.ready'));
      setViewers((ctx.presence && Object.keys(ctx.presence).length) || 1);
      sub.presence().then((p) => setViewers(Object.keys(p.clients || {}).length || 1))
        .catch(() => {});
    });
    sub.on('join', () => setViewers(state.viewers + 1));
    sub.on('leave', () => setViewers(Math.max(1, state.viewers - 1)));
    sub.on('error', () => setStatus(I18N.t('room.lost')));

    centrifuge.on('connected', () => setStatus(I18N.t('room.ready')));
    centrifuge.on('disconnected', () => setStatus(I18N.t('room.offline')));

    sub.subscribe();
    centrifuge.connect();

    state.centrifuge = centrifuge;
    state.sub = sub;

    // Ведущий — тот, кто последним трогал плеер: он раз в три секунды шлёт
    // своё время, чтобы вылечить накопленный дрейф.
    setInterval(() => {
      if (state.kind !== 'youtube' || !state.player || !state.player.getPlayerState) return;
      try {
        const playing = state.player.getPlayerState() === YT.PlayerState.PLAYING;
        if (playing) send('sync', ytTime(), { playing: true });
      } catch (_) {}
    }, HEARTBEAT);
  }

  // ── запуск ───────────────────────────────────────────────────────────────

  function shareLink() {
    return location.origin + location.pathname + '#' + (state.room || roomFromHash());
  }

  window.addEventListener('load', () => {
    I18N.mount();

    const room = roomFromHash();
    if (!room) {
      // Прямой заход без кода: комнаты нет, отправляем на главную.
      location.replace('../');
      return;
    }

    state.room = room;
    $('#code').textContent = room;
    $('#shareLink').textContent = shareLink().replace(/^https?:\/\//, '');
    if (navigator.share) $('#share').hidden = false;

    connect(room).catch(() => setStatus(I18N.t('room.lost')));

    $('#apply').addEventListener('click', () => {
      openStage();
      const src = parseSource($('#link').value);
      if (!src) { setStatus(I18N.t('room.badLink')); return; }
      mountPlayer(src);
      send('source', 0, { url: $('#link').value.trim() });
    });

    $('#send').addEventListener('click', () => {
      const text = $('#message').value.trim();
      if (!text) return;
      addMessage(I18N.t('room.you'), text, true);
      send('chat', 0, { text, name: I18N.t('room.guest') });
      $('#message').value = '';
    });
    $('#message').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') $('#send').click();
    });

    const share = $('#share');
    if (share) {
      share.addEventListener('click', () => {
        navigator.share({ url: shareLink() }).catch(() => {});
      });
    }
    const copy2 = $('#copy2');
    if (copy2) copy2.addEventListener('click', () => $('#copy').click());

    $('#copy').addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(shareLink());
        setStatus(I18N.t('room.copied'));
      } catch (_) {
        setStatus(shareLink());
      }
    });
  });
})();
