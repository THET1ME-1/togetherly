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
    // Что показывать пришедшему позже: ссылка, переписка этой вкладки и
    // отложенная команда для плеера, который ещё грузится.
    url: '', log: [], synced: false, pending: null, joinedAt: 0,
    // Файл с диска: сам он никуда не уходит, партнёру достаётся только имя,
    // чтобы он открыл у себя такой же.
    file: null,
    // VK и Rutube не отвечают на вопросы, а сами рассказывают о себе
    // событиями: последнее услышанное держим здесь.
    remote: { time: 0, playing: false, ready: false },
  };
  const LOG_LIMIT = 60;

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

  /** Имя гостя живёт в браузере: без него каждая перезагрузка вкладки
   *  выглядела бы приходом нового зрителя. */
  function guestId() {
    const KEY = 'watch-guest';
    try {
      const saved = localStorage.getItem(KEY);
      if (/^g[a-z0-9]{14}$/.test(saved || '')) return saved;
      const abc = 'abcdefghijklmnopqrstuvwxyz0123456789';
      const bytes = new Uint8Array(14);
      crypto.getRandomValues(bytes);
      let id = 'g';
      for (let i = 0; i < bytes.length; i++) id += abc[bytes[i] % abc.length];
      localStorage.setItem(KEY, id);
      return id;
    } catch (_) {
      return '';
    }
  }

  /** Зрители считаются по людям, а не по соединениям: у одного человека их
   *  бывает несколько, пока старое не отвалилось. */
  function countViewers(presence) {
    const clients = (presence && presence.clients) || {};
    const people = new Set();
    Object.keys(clients).forEach((k) => people.add(clients[k].user));
    return Math.max(1, people.size);
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
    if (host.endsWith('disk.yandex.ru') || host.endsWith('disk.yandex.com') || host === 'yadi.sk') {
      // Диск отдаёт настоящую ссылку на файл через открытый API, поэтому
      // видео играет в нашем плеере и синхронизируется посекундно.
      return { kind: 'yadisk', id: url.href };
    }
    if (host.endsWith('dropbox.com')) {
      // dl=1 превращает страницу в сам файл.
      url.searchParams.delete('dl');
      url.searchParams.set('raw', '1');
      return { kind: 'video', id: url.href };
    }
    if (host === 'mega.nz' || host === 'mega.io') {
      const m = url.pathname.match(/\/(?:file|embed)\/([^/]+)/);
      if (m) return { kind: 'mega', id: m[1] + url.hash };
    }
    if (host === 'drive.google.com') {
      // Диск отдаёт только свой просмотрщик: файл он не выдаёт, а плеером
      // изнутри управлять нельзя — отсюда режим пульта ниже.
      const m = url.pathname.match(/\/file\/d\/([^/]+)/);
      if (m) return { kind: 'drive', id: m[1] };
    }
    // Прямая ссылка на файл: браузер играет её сам, поэтому синхронизация тут
    // такая же точная, как у своего файла с диска.
    if (/\.(mp4|m4v|webm|ogv|ogg|mov)$/i.test(url.pathname)) {
      return { kind: 'video', id: url.href };
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
      case 'drive':
        return `https://drive.google.com/file/d/${src.id}/preview`;
      case 'mega':
        return `https://mega.nz/embed/${src.id}`;
      default:
        return '';
    }
  }

  // ── плееры ────────────────────────────────────────────────────────────────
  //
  // У каждой площадки свой способ управления. Общий интерфейс: play, pause,
  // seek, time. Где площадка не отдаёт время (VK, Rutube), синхронизация идёт
  // «вслепую»: команды доходят, а положение подтягивается при старте.

  /** Свой файл и прямая ссылка играют в обычном <video>: полное управление,
   *  секунда в секунду. */
  function mountVideo(src, label) {
    const holder = $('#player');
    holder.innerHTML = '';
    const v = document.createElement('video');
    v.src = src;
    v.controls = true;
    v.playsInline = true;
    v.preload = 'metadata';
    v.className = 'player__video';
    holder.appendChild(v);

    state.kind = 'video';
    state.player = { video: v };
    setManual(false);

    const tell = (cmd) => { if (!state.applying) send(cmd, v.currentTime); };
    v.addEventListener('play', () => tell('play'));
    v.addEventListener('pause', () => tell('pause'));
    v.addEventListener('seeked', () => tell(v.paused ? 'pause' : 'play'));

    if (state.pending) {
      const p = state.pending;
      state.pending = null;
      v.addEventListener('loadedmetadata', () => apply(p.cmd, p.at), { once: true });
    }
    setStatus(label);
  }

  /** Партнёр включил свой файл: показываем, какой именно, и ждём такой же. */
  function askForFile(info) {
    const holder = $('#player');
    holder.innerHTML = '';
    const box = document.createElement('div');
    box.className = 'player__empty';
    const title = document.createElement('span');
    title.textContent = I18N.t('room.fileWanted', { name: info.name });
    const btn = document.createElement('button');
    btn.className = 'btn btn--light btn--compact';
    btn.textContent = I18N.t('room.fileChoose');
    btn.addEventListener('click', () => $('#file').click());
    box.appendChild(title);
    box.appendChild(btn);
    holder.appendChild(box);
    state.file = info;
    state.kind = '';
  }

  function openLocalFile(file) {
    const info = { name: file.name, size: file.size };
    mountVideo(URL.createObjectURL(file), I18N.t('room.filePlaying', { name: file.name }));
    state.url = '';
    state.file = info;
    send('file', 0, info);
    reportSource({ kind: 'file', id: file.name }, 'file://' + file.name);
  }

  /** Публичная ссылка Диска ведёт на страницу, а нам нужен сам файл: его адрес
   *  выдаёт открытый API Яндекса. Ссылка временная, поэтому каждый участник
   *  запрашивает её у себя. */
  function mountYaDisk(publicUrl) {
    setStatus(I18N.t('room.resolving'));
    const api = 'https://cloud-api.yandex.net/v1/disk/public/resources/download?public_key='
      + encodeURIComponent(publicUrl);
    fetch(api)
      .then((r) => r.json())
      .then((d) => {
        if (!d || !d.href) throw new Error('no href');
        state.url = publicUrl;
        mountVideo(d.href, I18N.t('room.playing', { name: labels.yadisk }));
        reportSource({ kind: 'yadisk', id: publicUrl }, publicUrl);
      })
      .catch(() => setStatus(I18N.t('room.badLink')));
  }

  function mountPlayer(src, url) {
    if (src.kind === 'yadisk') {
      state.kind = 'yadisk';
      setManual(false);
      mountYaDisk(src.id);
      if (url) state.url = url;
      return;
    }
    if (src.kind === 'video') {
      mountVideo(src.id, I18N.t('room.playing', { name: I18N.t('room.fileSource') }));
      if (url) state.url = url;
      reportSource(src, url || src.id);
      return;
    }

    const holder = $('#player');
    holder.innerHTML = '';
    state.kind = src.kind;
    if (url) state.url = url;
    setManual(!!MANUAL[src.kind]);

    const frame = document.createElement('iframe');
    frame.src = embedUrl(src);
    frame.allow = 'autoplay; fullscreen; encrypted-media; picture-in-picture';
    frame.allowFullscreen = true;
    frame.id = 'frame';
    holder.appendChild(frame);

    if (src.kind === 'youtube') {
      state.player = new YT.Player('frame', {
        events: {
          onReady: () => {
            // Позиция, доставшаяся от того, кто уже смотрит: применяем её,
            // как только плеер готов принимать команды.
            if (!state.pending) return;
            apply(state.pending.cmd, state.pending.at);
            state.pending = null;
          },
          onStateChange: (e) => {
            if (state.applying) return;
            if (e.data === YT.PlayerState.PLAYING) send('play', ytTime());
            if (e.data === YT.PlayerState.PAUSED) send('pause', ytTime());
          },
        },
      });
    } else {
      state.player = { frame };
      state.remote = { time: 0, playing: false, ready: false };
      if (src.kind === 'vk') {
        // Плеер VK начинает слушать только после init.
        frame.addEventListener('load', () => talk({ method: 'init' }));
      }
      if (src.kind === 'vimeo') {
        // Vimeo рассказывает о себе только подписчикам, а подписку принимает
        // не раньше, чем поднимется сам. Ловить единственный момент готовности
        // ненадёжно, поэтому просим несколько раз: лишняя подписка безвредна.
        const subscribe = () => {
          ['ready', 'play', 'pause', 'playProgress', 'seeked'].forEach((ev) => {
            talk(JSON.stringify({ method: 'addEventListener', value: ev }));
          });
        };
        frame.addEventListener('load', subscribe);
        [400, 1200, 2500, 4500].forEach((ms) => setTimeout(subscribe, ms));
      }
      // Отложенная команда сама применится, как только плеер отзовётся.
    }
    setStatus(I18N.t('room.playing', { name: labelOf(src.kind) }));
    reportSource(src, url || state.url);
  }

  const labels = {
    youtube: 'YouTube', vimeo: 'Vimeo', vk: 'VK Видео', rutube: 'Rutube',
    drive: 'Google Диск', mega: 'MEGA', yadisk: 'Яндекс Диск',
  };
  /** Плеер Google Диска команд не принимает вовсе — только ему нужен пульт. */
  const MANUAL = { drive: true, mega: true };
  const labelOf = (k) => labels[k] || k;

  const ytTime = () => {
    try {
      if (state.kind === 'video') return state.player.video.currentTime || 0;
      if (state.kind === 'vk' || state.kind === 'rutube' || state.kind === 'vimeo') {
        return state.remote.time || 0;
      }
      return state.player.getCurrentTime() || 0;
    } catch (_) { return 0; }
  };

  function apply(cmd, at) {
    state.applying = true;
    try {
      if (state.kind === 'video' && state.player && state.player.video) {
        const v = state.player.video;
        if (Math.abs(v.currentTime - at) > DRIFT) v.currentTime = at;
        if (cmd === 'play') v.play().catch(() => {});
        if (cmd === 'pause') v.pause();
      } else if (state.kind === 'youtube' && state.player && state.player.seekTo) {
        const now = ytTime();
        if (Math.abs(now - at) > DRIFT) state.player.seekTo(at, true);
        if (cmd === 'play') state.player.playVideo();
        if (cmd === 'pause') state.player.pauseVideo();
      } else if (state.kind === 'vk' || state.kind === 'rutube') {
        if (!state.remote.ready) {
          // Плеер ещё не поздоровался: команду выполним, когда он ответит.
          state.pending = { cmd: cmd, at: at };
        } else if (state.kind === 'vk') {
          if (Math.abs(state.remote.time - at) > DRIFT) talk({ method: 'seek', time: at });
          talk({ method: cmd === 'play' ? 'play' : 'pause' });
          state.remote.playing = cmd === 'play';
          state.remote.time = at;
        } else {
          if (Math.abs(state.remote.time - at) > DRIFT) {
            talk(JSON.stringify({ type: 'player:setCurrentTime', data: { time: at } }));
          }
          talk(JSON.stringify({ type: 'player:' + cmd, data: {} }));
          state.remote.playing = cmd === 'play';
          state.remote.time = at;
        }
      } else if (state.kind === 'vimeo') {
        if (Math.abs(state.remote.time - at) > DRIFT) {
          talk(JSON.stringify({ method: 'setCurrentTime', value: at }));
        }
        talk(JSON.stringify({ method: cmd === 'play' ? 'play' : 'pause' }));
        state.remote.playing = cmd === 'play';
        state.remote.time = at;
      }
    } catch (_) { /* плеер ещё не готов — команда придёт со следующим тактом */ }
    setTimeout(() => { state.applying = false; }, state.kind === 'video' ? 300 : 900);
  }

  /** Рассказывает приложению, что сейчас включили: комната живёт во встроенном
   *  браузере, и без этого приложение не знает, что писать в историю. В обычном
   *  браузере вызов просто ничего не делает. */
  function reportSource(src, url) {
    try {
      const bridge = window.flutter_inappwebview;
      if (!bridge || !bridge.callHandler) return;
      const info = { url: url || '', kind: src.kind || '', title: '', thumb: '' };
      if (src.kind === 'youtube') {
        info.thumb = 'https://img.youtube.com/vi/' + src.id + '/hqdefault.jpg';
        try { info.title = state.player.getVideoData().title || ''; } catch (_) { /* ещё грузится */ }
      }
      bridge.callHandler('watchSource', info);
    } catch (_) { /* приложения рядом нет */ }
  }

  // ── чужие плееры ─────────────────────────────────────────────────────────
  //
  // VK принимает объекты {method:'play'}, Rutube — строку {type:'player:play'}.
  // Оба сами рассказывают о паузе, старте и перемотке, поэтому обычная кнопка
  // в плеере работает как команда для обоих.

  /** Команда, пришедшая раньше готовности чужого плеера, ждёт своей минуты. */
  function flushPending() {
    if (!state.pending) return;
    const wanted = state.pending;
    state.pending = null;
    apply(wanted.cmd, wanted.at);
  }

  function talk(payload) {
    try {
      state.player.frame.contentWindow.postMessage(payload, '*');
    } catch (_) { /* кадр ещё не готов */ }
  }

  function onFrameMessage(e) {
    if (!state.player || !state.player.frame || e.source !== state.player.frame.contentWindow) return;

    let msg = e.data;
    if (typeof msg === 'string') {
      try { msg = JSON.parse(msg); } catch (_) { return; }
    }
    if (!msg || typeof msg !== 'object') return;

    let playing = null;
    let time = null;

    if (state.kind === 'vk') {
      if (typeof msg.time === 'number') time = msg.time;
      if (msg.event === 'inited') { state.remote.ready = true; flushPending(); return; }
      if (msg.event === 'started' || msg.event === 'resumed') playing = true;
      if (msg.event === 'paused' || msg.event === 'ended') playing = false;
      if (msg.event === 'seeked') playing = state.remote.playing;
    } else if (state.kind === 'vimeo') {
      const d = msg.data || {};
      if (typeof d.seconds === 'number') time = d.seconds;
      if (msg.event === 'ready') { state.remote.ready = true; flushPending(); return; }
      if (msg.event === 'play' || msg.event === 'playProgress') playing = true;
      if (msg.event === 'pause' || msg.event === 'ended') playing = false;
      if (msg.event === 'seeked') playing = state.remote.playing;
    } else if (state.kind === 'rutube') {
      const d = msg.data || {};
      if (typeof d.time === 'number') time = d.time;
      if (typeof d.currentTime === 'number') time = d.currentTime;
      if (msg.type === 'player:ready') { state.remote.ready = true; flushPending(); return; }
      if (msg.type === 'player:changeState') {
        // Пока крутится реклама, плеер отвечает за неё, а не за фильм.
        if (d.state === 'advert' || d.state === 'buffering' || d.state === 'seeking') return;
        if (d.state === 'playing') { playing = true; state.remote.ready = true; flushPending(); }
        if (d.state === 'pause' || d.state === 'stopped' || d.state === 'completed') playing = false;
      }
    } else {
      return;
    }

    if (time !== null) state.remote.time = time;
    if (playing === null) return;

    const changed = playing !== state.remote.playing;
    state.remote.playing = playing;
    // Пока применяем чужую команду, свои же отголоски обратно не шлём.
    if (changed && !state.applying) send(playing ? 'play' : 'pause', state.remote.time);
  }

  // ── пульт ────────────────────────────────────────────────────────────────
  //
  // Плеер Google Диска, VK и Rutube не отдаёт управление, поэтому кнопки жмёт
  // человек. Комната задаёт момент: обратный отсчёт идёт у обоих сразу.

  function showCountdown(seconds) {
    const holder = $('#player');
    let box = holder.querySelector('.countdown');
    if (!box) {
      box = document.createElement('div');
      box.className = 'countdown';
      holder.appendChild(box);
    }
    let left = seconds;
    const tick = () => {
      box.textContent = left > 0 ? String(left) : I18N.t('room.now');
      if (left < 0) { box.remove(); return; }
      left -= 1;
      setTimeout(tick, 1000);
    };
    tick();
  }

  function flashPause() {
    const holder = $('#player');
    const box = document.createElement('div');
    box.className = 'countdown countdown--pause';
    box.textContent = I18N.t('room.pauseNow');
    holder.appendChild(box);
    setTimeout(() => box.remove(), 2600);
  }

  function setManual(on) {
    const bar = $('#manual');
    if (bar) bar.hidden = !on;
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
        if (src) { $('#link').value = data.url; mountPlayer(src, data.url); }
        break;
      }
      case 'chat':
        remember(data.from, data.name, data.text);
        addMessage(data.name || I18N.t('room.guest'), data.text, false);
        break;
      case 'hello':
        // Кто-то вошёл в уже живую комнату. Сервер ничего не хранит, поэтому
        // ссылку на видео и переписку ему передаёт вкладка того, кто внутри.
        if (!state.url && !state.file && !state.log.length) break;
        send('state', ytTime(), {
          to: data.from,
          url: state.url,
          file: state.file,
          playing: isPlaying(),
          log: state.log.slice(-LOG_LIMIT),
        });
        break;
      case 'state':
        adoptState(data);
        break;
      case 'sync':
        if (state.kind && Math.abs(ytTime() - data.at) > DRIFT) {
          apply(data.playing ? 'play' : 'pause', data.at);
        }
        break;
      case 'countdown':
        showCountdown(3);
        break;
      case 'pauseNow':
        flashPause();
        break;
      case 'file':
        // Файл по сети не передать: партнёр открывает свою копию сам.
        if (state.kind === 'video' && state.file && state.file.name === data.name) break;
        if (!state.kind) askForFile({ name: data.name, size: data.size });
        break;
    }
  }

  /** Переписка живёт только в этой вкладке — из неё же её получает новичок. */
  function remember(from, name, text) {
    state.log.push({ from: from, name: name, text: text });
    if (state.log.length > LOG_LIMIT) state.log.shift();
  }

  const isPlaying = () => {
    try {
      if (state.kind === 'video') return !state.player.video.paused;
      if (state.kind === 'vk' || state.kind === 'rutube' || state.kind === 'vimeo') {
        return state.remote.playing;
      }
      return state.player.getPlayerState() === YT.PlayerState.PLAYING;
    } catch (_) { return false; }
  };

  /** Принимает состояние комнаты: видео с той же секунды и прошлые сообщения. */
  function adoptState(data) {
    if (state.synced || data.to !== state.me) return;
    state.synced = true;

    (data.log || []).forEach((m) => {
      remember(m.from, m.name, m.text);
      addMessage(m.name || I18N.t('room.guest'), m.text, m.from === state.me);
    });

    if (state.kind) return;
    if (!data.url) {
      if (data.file) askForFile(data.file);
      return;
    }
    const src = parseSource(data.url);
    if (!src) return;
    $('#link').value = data.url;
    state.pending = { cmd: data.playing ? 'play' : 'pause', at: data.at || 0 };
    mountPlayer(src, data.url);
    // Площадки, кроме YouTube, о готовности не сообщают.
    if (src.kind !== 'youtube') {
      setTimeout(() => {
        if (!state.pending) return;
        apply(state.pending.cmd, state.pending.at);
        state.pending = null;
      }, 1500);
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
    const el = $('#status');
    if (el) el.textContent = text;
  }

  function setViewers(n) {
    const was = state.viewers;
    state.viewers = n;
    const el = $('#viewers');
    if (el) el.textContent = n === 1 ? I18N.t('room.alone') : I18N.t('room.viewers', { n });
    // Комната открыта сразу, поэтому приход партнёра отмечаем строкой в чате.
    // Переподключения дают дребезг 1↔2, поэтому строка не чаще раза в полминуты.
    if (n > 1 && was <= 1 && performance.now() - state.joinedAt > 30000) {
      state.joinedAt = performance.now();
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
      body: JSON.stringify({ room, guest: guestId() }),
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

    const refreshViewers = () => {
      sub.presence().then((p) => setViewers(countViewers(p))).catch(() => {});
    };

    sub.on('publication', (ctx) => onMessage(ctx.data));
    sub.on('subscribed', () => {
      setStatus(I18N.t('room.ready'));
      refreshViewers();
      // Просим тех, кто уже внутри, прислать ссылку и переписку.
      send('hello');
    });
    sub.on('join', refreshViewers);
    sub.on('leave', refreshViewers);
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
      if (!state.kind || !isPlaying()) return;
      send('sync', ytTime(), { playing: true });
    }, HEARTBEAT);
  }

  // ── запуск ───────────────────────────────────────────────────────────────

  function shareLink() {
    return location.origin + location.pathname + '#' + (state.room || roomFromHash());
  }

  window.addEventListener('message', onFrameMessage);

  window.addEventListener('load', () => {
    I18N.mount();
    $('#chat').dataset.empty = I18N.t('room.chatEmpty');

    const room = roomFromHash();
    if (!room) {
      // Прямой заход без кода: комнаты нет, отправляем на главную.
      location.replace('../');
      return;
    }

    state.room = room;
    $('#code').textContent = room;
    if (navigator.share) $('#share').hidden = false;

    connect(room).catch(() => setStatus(I18N.t('room.lost')));

    $('#apply').addEventListener('click', () => {
      const src = parseSource($('#link').value);
      if (!src) { setStatus(I18N.t('room.badLink')); return; }
      const url = $('#link').value.trim();
      mountPlayer(src, url);
      send('source', 0, { url: url });
    });

    $('#together').addEventListener('click', () => {
      send('countdown', 0);
      showCountdown(3);
    });
    $('#pauseBoth').addEventListener('click', () => {
      send('pauseNow', 0);
      flashPause();
    });

    $('#pick').addEventListener('click', () => $('#file').click());
    $('#file').addEventListener('change', (e) => {
      const file = e.target.files && e.target.files[0];
      if (file) openLocalFile(file);
      e.target.value = '';
    });

    $('#send').addEventListener('click', () => {
      const text = $('#message').value.trim();
      if (!text) return;
      addMessage(I18N.t('room.you'), text, true);
      remember(state.me, I18N.t('room.guest'), text);
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
