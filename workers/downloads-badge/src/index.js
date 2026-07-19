/**
 * Счётчики Togetherly для бейджей shields.io.
 *
 * Главный источник — собственная админка (PocketBase, /modapi/stats). Она знает
 * РЕАЛЬНОЕ число пользователей со всех платформ разом: Google Play, RuStore,
 * APK с GitHub и iOS. Это честнее суммы магазинных счётчиков, потому что не
 * двоит одного человека, поставившего приложение из двух мест.
 *
 * Почему не считаем скачивания магазинов:
 *   - у Google Play и RuStore нет публичного API статистики (только консоли);
 *   - счётчик релизов GitHub нельзя перенести между репозиториями, при переезде
 *     на THET1ME-1/togetherly он обнулился;
 *   - бейдж `downloads/total` у GitHub считал в основном version.json, который
 *     дёргает автообновление у каждого пользователя (7131 «скачиваний» против
 *     790 реальных APK).
 *
 * Роуты:
 *   GET /badge      → пользователи (главный бейдж)
 *   GET /badge/apk  → скачивания .apk с GitHub (оба репозитория)
 *   GET /json       → разбивка для проверки
 *
 * ВАЖНО: наружу отдаём ТОЛЬКО агрегированные числа. Полный ответ /modapi/stats
 * содержит внутреннюю аналитику и никогда не проксируется.
 */

const STATS_URL = 'https://togetherly.duckdns.org/modapi/stats';
const GITHUB_REPOS = [
  'THET1ME-1/togetherly',
  'THET1ME-1/togetherly_app_releases',
];

// Кэш бережёт и лимит анонимных запросов GitHub (60/час), и PocketBase —
// /modapi/stats это пачка COUNT(*) по SQLite, дёргать её часто незачем.
const CACHE_SECONDS = 3600;

// Версия в ключе кэша: без неё после деплоя Cloudflare ещё час отдаёт ответы
// старой формы (уже наступали на это). Поднимать при смене формата ответа.
const CACHE_VERSION = 'v2';

async function totalUsers(env) {
  if (!env.MOD_SECRET) return 0;
  const res = await fetch(STATS_URL, {
    headers: { 'X-Mod-Secret': env.MOD_SECRET, 'User-Agent': 'togetherly-badge' },
  });
  if (!res.ok) throw new Error(`stats ${res.status}`);
  const data = await res.json();
  return data.totalUsers || 0;
}

async function githubApkDownloads(repo) {
  let total = 0;
  for (let page = 1; page <= 5; page++) {
    const res = await fetch(
      `https://api.github.com/repos/${repo}/releases?per_page=100&page=${page}`,
      { headers: { 'User-Agent': 'togetherly-badge', Accept: 'application/vnd.github+json' } },
    );
    if (!res.ok) break;
    const releases = await res.json();
    if (!Array.isArray(releases) || releases.length === 0) break;
    for (const rel of releases) {
      for (const asset of rel.assets || []) {
        if (asset.name && asset.name.toLowerCase().endsWith('.apk')) {
          total += asset.download_count || 0;
        }
      }
    }
    if (releases.length < 100) break;
  }
  return total;
}

function compact(n) {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M';
  if (n >= 1_000) return (n / 1_000).toFixed(1).replace(/\.0$/, '') + 'k';
  return String(n);
}

const badge = (label, message, color) => ({ schemaVersion: 1, label, message, color });

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const cache = caches.default;
    const cacheKey = new Request(`${url.origin}${url.pathname}?cv=${CACHE_VERSION}`, request);

    const hit = await cache.match(cacheKey);
    if (hit) return hit;

    let body;
    try {
      if (url.pathname === '/badge/apk') {
        let apk = 0;
        for (const r of GITHUB_REPOS) apk += await githubApkDownloads(r);
        body = badge('apk downloads', compact(apk), '8E4657');
      } else if (url.pathname === '/json') {
        const perRepo = {};
        let apk = 0;
        for (const r of GITHUB_REPOS) {
          perRepo[r] = await githubApkDownloads(r);
          apk += perRepo[r];
        }
        body = { users: await totalUsers(env), githubApk: apk, perRepo };
      } else {
        body = badge('users', compact(await totalUsers(env)), 'E75480');
      }
    } catch (e) {
      // Бейдж не должен показывать поломку — отдаём заглушку и НЕ кэшируем.
      return Response.json(badge('users', 'n/a', 'lightgrey'), {
        headers: { 'Cache-Control': 'no-store' },
      });
    }

    const res = Response.json(body, {
      headers: { 'Cache-Control': `public, max-age=${CACHE_SECONDS}` },
    });
    ctx.waitUntil(cache.put(cacheKey, res.clone()));
    return res;
  },
};
