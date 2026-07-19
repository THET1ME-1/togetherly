/**
 * Бот баг-репортов @TogetherlyBugsBot: Telegram → Gemini → Todoist.
 *
 * Жил в Firebase Function `telegramWebhook`; после ухода с Firebase её бэкенд
 * перестал подниматься и Telegram получал 503. Переехать на VPS с PocketBase
 * нельзя: российский хостинг и Telegram не видят друг друга (api.telegram.org
 * с VPS — таймаут, вебхук от Telegram до VPS — тоже). Cloudflare вне этой
 * блокировки, поэтому бот живёт здесь.
 *
 * Секреты (wrangler secret put): TELEGRAM_BOT_TOKEN, TODOIST_API_TOKEN,
 * GEMINI_API_KEY, TG_WEBHOOK_SECRET.
 */

const TODOIST_PROJECT_ID = "6ghRcQGgMJv3hwGH";
const TODOIST_ASSIGNEE_ID = "34940569";
const SECTION_SROCHNO = "6gjcfphM67QjC8Qq"; // 🔴 Срочно
const SECTION_OT_POLZOVATELEY = "6gjw3rP83qwqmvvH"; // 🐛 От пользователей

const CATEGORY_META = {
  crash: { labels: ["Баг / Ошибка"], priority: 4, section: SECTION_SROCHNO, emoji: "🔴" },
  ui_bug: { labels: ["Баг / Ошибка", "UI/IX"], priority: 3, section: SECTION_OT_POLZOVATELEY, emoji: "🟠" },
  bug: { labels: ["Баг / Ошибка"], priority: 3, section: SECTION_OT_POLZOVATELEY, emoji: "🟠" },
  performance: { labels: ["Улучшение"], priority: 2, section: SECTION_OT_POLZOVATELEY, emoji: "🟡" },
  feature: { labels: ["Новая фича"], priority: 1, section: SECTION_OT_POLZOVATELEY, emoji: "🟢" },
  question: { labels: ["Вопрос"], priority: 1, section: SECTION_OT_POLZOVATELEY, emoji: "💬" },
};

function classifyFallback(text) {
  const t = text.toLowerCase();
  if (/crash|вылет|падает|force close|не открывается|зависает/.test(t)) return "crash";
  if (/ui|интерфейс|кнопка|экран|отображ|верст|layout|визуал/.test(t)) return "ui_bug";
  if (/не работает|сломал|ошибка|баг|bug|глюк/.test(t)) return "bug";
  if (/медленно|лагает|тормоз|freeze/.test(t)) return "performance";
  if (/хочу|добавьте|было бы|feature|предлагаю|можно ли/.test(t)) return "feature";
  if (/как|вопрос|подскажите|работает ли|есть ли/.test(t)) return "question";
  return "bug";
}

function makeTitle(text) {
  const sentence = text.split(/[.!?\n]/)[0].trim();
  const clean = sentence.replace(
    /^(баг в том,?\s*(что)?|проблема в том,?\s*(что)?|обнаружил,?\s*(что)?|заметил,?\s*(что)?)\s*/i, "");
  const result = clean.charAt(0).toUpperCase() + clean.slice(1);
  return result.length > 70 ? result.slice(0, 67) + "..." : (result || sentence);
}

async function geminiAnalyze(text, apiKey) {
  const prompt = `Ты помощник разработчика мобильного приложения Togetherly (приложение для пар).
Пользователь написал в поддержку: "${text}"

Определи:
1. category — ОДНО из: crash (падает/вылетает), bug (не работает), ui_bug (визуальная проблема), performance (медленно/лагает), feature (запрос новой функции), question (вопрос как что-то работает), spam (бессмыслица/оскорбление)
2. title — короткое название задачи на русском (до 60 символов), начни с глагола или существительного

Ответь ТОЛЬКО JSON без markdown: {"category":"...","title":"..."}`;

  try {
    const res = await fetch(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=" + apiKey,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: { maxOutputTokens: 100, temperature: 0.2 },
        }),
      },
    );
    const json = await res.json();
    const raw = json?.candidates?.[0]?.content?.parts?.[0]?.text?.trim();
    if (!raw) return null;
    const parsed = JSON.parse(raw.replace(/```json|```/g, "").trim());
    return (parsed.category && parsed.title) ? parsed : null;
  } catch (err) {
    console.error("gemini failed:", err);
    return null;
  }
}

async function tgSend(env, chatId, text) {
  try {
    await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML" }),
    });
  } catch (err) { console.error("sendMessage failed:", err); }
}

async function handleUpdate(update, env) {
  const message = update.message || update.channel_post;
  if (!message) return;

  // У фото берём последний размер — он самый крупный.
  let mediaFileId = null;
  let mediaMime = "image/jpeg";
  if (message.photo?.length) {
    mediaFileId = message.photo[message.photo.length - 1].file_id;
  } else if (message.video) {
    mediaFileId = message.video.file_id;
    mediaMime = message.video.mime_type || "video/mp4";
  } else if (message.document) {
    mediaFileId = message.document.file_id;
    mediaMime = message.document.mime_type || "application/octet-stream";
  }

  const text = (message.caption || message.text || "").trim();
  if (!text && !mediaFileId) return;

  const chatId = message.chat.id;
  const from = message.from || {};
  const username = from.username ? `@${from.username}` : (from.first_name || "Аноним");
  const tgLink = from.username ? `https://t.me/${from.username}` : null;

  if (text.startsWith("/")) {
    if (text === "/start") {
      await tgSend(env, chatId,
        "👋 Привет! Опиши баг или проблему в Togetherly — я создам задачу для разработчика. " +
        "Можешь приложить скриншот или видео.");
    }
    return;
  }

  const taskText = text || (mediaMime.startsWith("image") ? "Скриншот от пользователя" : "Видео от пользователя");

  const gemini = await geminiAnalyze(taskText, env.GEMINI_API_KEY);
  const category = gemini?.category || classifyFallback(taskText);
  const title = gemini?.title || makeTitle(taskText);

  if (category === "spam") {
    await tgSend(env, chatId, "Спасибо за обращение!");
    console.log(`spam от ${username}, пропущено`);
    return;
  }

  const meta = CATEGORY_META[category];
  if (!meta) return;

  const replyLine = tgLink ? `\n\n↩️ Ответить: ${tgLink}` : "";
  const created = await fetch("https://api.todoist.com/api/v1/tasks", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${env.TODOIST_API_TOKEN}`,
    },
    body: JSON.stringify({
      content: title,
      description: `От ${username}:\n\n${taskText}${replyLine}`,
      project_id: TODOIST_PROJECT_ID,
      section_id: meta.section,
      priority: meta.priority,
      labels: meta.labels,
      assignee_id: TODOIST_ASSIGNEE_ID,
    }),
  });

  if (!created.ok) {
    console.error(`todoist error ${created.status}:`, await created.text());
    await tgSend(env, chatId, "😔 Не получилось создать задачу. Разработчик уже в курсе, попробуй позже.");
    return;
  }

  const task = await created.json();

  // Медиа прикрепляем комментарием: Todoist сам скачает файл по file_url
  // (ссылка Telegram живёт около часа — этого хватает).
  if (mediaFileId && task?.id) {
    try {
      const fileRes = await fetch(
        `https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/getFile?file_id=${mediaFileId}`);
      const fileJson = await fileRes.json();
      const filePath = fileJson?.ok ? fileJson.result?.file_path : null;
      if (filePath) {
        await fetch("https://api.todoist.com/api/v1/comments", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${env.TODOIST_API_TOKEN}`,
          },
          body: JSON.stringify({
            task_id: String(task.id),
            content: "📎 Вложение от пользователя",
            attachment: {
              file_name: filePath.split("/").pop(),
              file_type: mediaMime,
              file_url: `https://api.telegram.org/file/bot${env.TELEGRAM_BOT_TOKEN}/${filePath}`,
            },
          }),
        });
      }
    } catch (err) { console.error("media attach failed:", err); }
  }

  const mediaNote = mediaFileId ? " + 📎" : "";
  const replyText = category === "question"
    ? `💬 Вопрос получен, ${username}! Разработчик ответит в ближайшее время.`
    : `${meta.emoji} Принято! Спасибо, ${username}.\nМетка: <b>${meta.labels.join(", ")}</b>${mediaNote}`;
  await tgSend(env, chatId, replyText);

  console.log(`[${category}] от ${username}: "${title}"${mediaFileId ? " [media]" : ""}`);
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "POST") return new Response("ok");

    // Без secret_token роут открыт всему интернету: любой мог бы насыпать задач
    // в Todoist. Telegram шлёт его в заголовке при каждом апдейте.
    const secret = request.headers.get("X-Telegram-Bot-Api-Secret-Token");
    if (secret !== env.TG_WEBHOOK_SECRET) return new Response("unauthorized", { status: 401 });

    let update;
    try { update = await request.json(); } catch { return new Response("ok"); }

    // Отвечаем Telegram сразу, обработку доигрываем в фоне: иначе он посчитает
    // медленный ответ недоставкой и переотправит апдейт — получим дубли задач.
    ctx.waitUntil(handleUpdate(update, env).catch((err) => console.error("unhandled:", err)));
    return new Response("ok");
  },
};
