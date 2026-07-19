/**
 * Суммарный счётчик установок Togetherly для бейджа shields.io.
 *
 * Зачем: приложение живёт в четырёх местах, и ни один готовый бейдж не умеет
 * складывать их вместе. Плюс у GitHub счётчик релизов нельзя перенести между
 * репозиториями — при переезде на THET1ME-1/togetherly он обнулился, хотя
 * загрузки честно были.
 *
 * Что считаем:
 *   - GitHub: скачивания ТОЛЬКО .apk из релизов обоих репозиториев (живьём).
 *     version.json намеренно НЕ считаем: его дёргает автообновление у каждого
 *     пользователя при каждой проверке, и он раздувал счётчик в разы
 *     (7131 «скачиваний» против 790 реальных APK).
 *   - Google Play и RuStore: числа из консолей, задаются переменными
 *     PLAY_INSTALLS / RUSTORE_INSTALLS (у магазинов нет публичного API
 *     статистики). Обновляются правкой переменной, без передеплоя кода.
 *
 * Роуты:
 *   GET /badge   → JSON для shields.io (endpoint-бейдж)
 *   GET /json    → разбивка по источникам (для отладки и проверки)
 *
 * Бейдж в README:
 *   ![Installs](https://img.shields.io/endpoint?url=https://<worker>/badge)
 */

const GITHUB_REPOS = [
  'THET1ME-1/togetherly',
  'THET1ME-1/togetherly_app_releases',
];

// GitHub троттлит анонимные запросы (60/час на IP), а бейдж могут дёргать
// часто — держим результат в кэше Cloudflare.
const CACHE_SECONDS = 3600;

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

async function collect(env) {
  const perRepo = {};
  let github = 0;
  for (const repo of GITHUB_REPOS) {
    const n = await githubApkDownloads(repo);
    perRepo[repo] = n;
    github += n;
  }
  const play = parseInt(env.PLAY_INSTALLS || '0', 10) || 0;
  const rustore = parseInt(env.RUSTORE_INSTALLS || '0', 10) || 0;
  return { github, perRepo, play, rustore, total: github + play + rustore };
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const cache = caches.default;
    const cacheKey = new Request(url.toString(), request);

    const hit = await cache.match(cacheKey);
    if (hit) return hit;

    let data;
    try {
      data = await collect(env);
    } catch (e) {
      // Бейдж не должен показывать ошибку — отдаём заглушку без кэша.
      return Response.json(
        { schemaVersion: 1, label: 'installs', message: 'n/a', color: 'lightgrey' },
        { headers: { 'Cache-Control': 'no-store' } },
      );
    }

    let body;
    if (url.pathname === '/json') {
      body = data;
    } else {
      body = {
        schemaVersion: 1,
        label: 'installs',
        message: compact(data.total),
        color: '8E4657',
      };
    }

    const res = Response.json(body, {
      headers: { 'Cache-Control': `public, max-age=${CACHE_SECONDS}` },
    });
    ctx.waitUntil(cache.put(cacheKey, res.clone()));
    return res;
  },
};
