#!/usr/bin/env python3
"""Генерирует юридические страницы pb_public из Markdown-исходников в репо.

    PRIVACY_POLICY.md -> pocketbase/pb_public/privacy-policy/index.html
    TERMS_OF_USE.md   -> pocketbase/pb_public/terms/index.html

Зачем свой конвертер: на машинах сборки нет pandoc/python-markdown, а документы
используют узкое подмножество Markdown (заголовки #..####, списки -/1., «---»,
**жирный**, [ссылки](url), абзацы). Держим генератор в repo, чтобы правки
документов можно было перевыкладывать одной командой:

    python3 tool/gen_legal_html.py && \
        scp pocketbase/pb_public/privacy-policy/index.html \
            root@77.91.95.34:/opt/pocketbase/pb_public/privacy-policy/index.html && \
        scp pocketbase/pb_public/terms/index.html \
            root@77.91.95.34:/opt/pocketbase/pb_public/terms/index.html
"""
import html
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (исходник, каталог в pb_public, <title>)
DOCS = [
    ("PRIVACY_POLICY.md", "privacy-policy", "Privacy Policy — Togetherly"),
    ("TERMS_OF_USE.md", "terms", "Terms of Use — Togetherly"),
]

INLINE_BOLD = re.compile(r"\*\*(.+?)\*\*")
INLINE_LINK = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def inline(text: str) -> str:
    """Экранирует HTML и применяет **bold** и [text](url)."""
    text = html.escape(text, quote=False)
    text = INLINE_BOLD.sub(r"<strong>\1</strong>", text)
    text = INLINE_LINK.sub(r'<a href="\2">\1</a>', text)
    return text


def convert(md: str) -> str:
    out: list[str] = []
    # Стек открытых списков: элементы ('ul'|'ol', indent)
    stack: list[tuple[str, int]] = []
    para: list[str] = []

    def close_lists(to_indent: int = -1) -> None:
        while stack and stack[-1][1] >= to_indent >= 0 or (to_indent < 0 and stack):
            tag, _ = stack.pop()
            out.append(f"</{tag}>")

    def flush_para() -> None:
        if para:
            out.append("<p>" + " ".join(inline(p) for p in para) + "</p>")
            para.clear()

    for raw in md.splitlines():
        line = raw.rstrip()
        stripped = line.strip()

        if not stripped:
            flush_para()
            continue

        m = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if m:
            flush_para()
            close_lists()
            level = len(m.group(1))
            out.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
            continue

        if stripped == "---":
            flush_para()
            close_lists()
            out.append("<hr>")
            continue

        m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", line)
        if m:
            flush_para()
            indent = len(m.group(1))
            tag = "ol" if m.group(2).rstrip(".").isdigit() else "ul"
            # Закрываем более глубокие/несовместимые уровни
            while stack and (
                stack[-1][1] > indent or (stack[-1][1] == indent and stack[-1][0] != tag)
            ):
                t, _ = stack.pop()
                out.append(f"</{t}>")
            if not stack or stack[-1][1] < indent:
                stack.append((tag, indent))
                out.append(f"<{tag}>")
            out.append(f"<li>{inline(m.group(3))}</li>")
            continue

        # Продолжение элемента списка (отступ) или обычный абзац
        if stack and line.startswith(" "):
            out.append(inline(stripped))
            continue
        close_lists()
        para.append(stripped)

    flush_para()
    close_lists()
    return "\n".join(out)


def render(body: str, title: str) -> str:
    return f"""<!doctype html>
<html lang=\"ru\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
<title>{title}</title>
<style>
body{{font-family:-apple-system,'Segoe UI',Roboto,sans-serif;background:#fff5f7;color:#33202a;
margin:0;padding:0}}
main{{max-width:760px;margin:0 auto;padding:32px 20px 64px;background:#fff;
box-shadow:0 0 24px rgba(229,87,138,.08)}}
h1{{color:#e5578a;font-size:28px}}h2{{color:#e5578a;margin-top:40px}}
h3{{margin-top:28px}}h4{{margin-top:20px}}
hr{{border:none;border-top:1px solid #f3d3de;margin:32px 0}}
a{{color:#e5578a}}li{{margin:4px 0}}p,li{{line-height:1.55}}
</style>
</head>
<body>
<main>
{body}
</main>
</body>
</html>
"""


def main() -> None:
    for src_name, out_dir, title in DOCS:
        src = ROOT / src_name
        dst = ROOT / "pocketbase" / "pb_public" / out_dir / "index.html"
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(render(convert(src.read_text(encoding="utf-8")), title), encoding="utf-8")
        print(f"OK: {dst} ({dst.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
