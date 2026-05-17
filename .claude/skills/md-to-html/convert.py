#!/usr/bin/env python3
"""
md-to-html — self-contained markdown → HTML converter.

Usage:
    python3 convert.py <input.md> [--out-dir DIR] [--split N]

Splits on level-2 headings (##) when total output exceeds --split lines
(default 800). Generates index.html with a table of contents linking to
each split page; each page has prev/next navigation.

No external dependencies. GitHub-flavored markdown subset:
  - Headings (# .. ######)
  - Bold (**) and italic (*)
  - Inline code (`) and fenced code blocks (```lang)
  - Unordered (- ) and ordered (1. ) lists, nested by indentation
  - Tables (pipe-separated with --- header divider)
  - Links [text](url)
  - Blockquotes (> )
  - Horizontal rules (---)
  - Paragraphs

Embedded CSS — readable typography, dark + light modes.
"""

from __future__ import annotations

import argparse
import html
import os
import re
import sys
from pathlib import Path

# ──────────────────────────────────────────────────────────────────────
# CSS — minimal modern; supports prefers-color-scheme.
# ──────────────────────────────────────────────────────────────────────

CSS = """
:root {
  --bg: #fafafa;
  --fg: #1a1a1a;
  --muted: #666;
  --accent: #0066cc;
  --code-bg: #f0f0f0;
  --border: #ddd;
  --table-stripe: #f5f5f5;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #1a1a1a;
    --fg: #e0e0e0;
    --muted: #999;
    --accent: #4da3ff;
    --code-bg: #2a2a2a;
    --border: #333;
    --table-stripe: #222;
  }
}
* { box-sizing: border-box; }
body {
  background: var(--bg);
  color: var(--fg);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  font-size: 16px;
  line-height: 1.6;
  margin: 0;
  padding: 0;
}
.container {
  max-width: 880px;
  margin: 0 auto;
  padding: 32px 24px 64px;
}
nav.topnav {
  background: var(--code-bg);
  border-bottom: 1px solid var(--border);
  padding: 12px 24px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 14px;
}
nav.topnav a { color: var(--accent); text-decoration: none; margin: 0 8px; }
nav.topnav a:hover { text-decoration: underline; }
nav.topnav .crumb { color: var(--muted); }
h1, h2, h3, h4, h5, h6 {
  margin: 1.8em 0 0.6em;
  line-height: 1.25;
  font-weight: 600;
}
h1 { font-size: 2em; border-bottom: 2px solid var(--border); padding-bottom: 0.3em; margin-top: 0.5em; }
h2 { font-size: 1.5em; border-bottom: 1px solid var(--border); padding-bottom: 0.25em; }
h3 { font-size: 1.25em; }
h4 { font-size: 1.1em; color: var(--muted); }
p { margin: 0.8em 0; }
a { color: var(--accent); }
strong { font-weight: 600; }
em { font-style: italic; }
code {
  background: var(--code-bg);
  padding: 2px 6px;
  border-radius: 3px;
  font-family: "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace;
  font-size: 0.92em;
}
pre {
  background: var(--code-bg);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 12px 16px;
  overflow-x: auto;
  font-size: 0.92em;
  line-height: 1.5;
}
pre code {
  background: none;
  padding: 0;
  border-radius: 0;
  font-size: inherit;
}
blockquote {
  border-left: 4px solid var(--accent);
  margin: 1em 0;
  padding: 0.3em 1em;
  color: var(--muted);
  background: var(--code-bg);
}
ul, ol { margin: 0.8em 0; padding-left: 1.8em; }
li { margin: 0.3em 0; }
table {
  border-collapse: collapse;
  margin: 1em 0;
  width: 100%;
  font-size: 0.95em;
}
th, td {
  border: 1px solid var(--border);
  padding: 8px 12px;
  text-align: left;
  vertical-align: top;
}
th {
  background: var(--code-bg);
  font-weight: 600;
}
tr:nth-child(even) td { background: var(--table-stripe); }
hr {
  border: none;
  border-top: 1px solid var(--border);
  margin: 2em 0;
}
.toc {
  background: var(--code-bg);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 12px 24px;
  margin: 1em 0 2em;
}
.toc ul { padding-left: 1.4em; margin: 0.4em 0; }
.toc > h3 { margin-top: 0.4em; }
"""

# ──────────────────────────────────────────────────────────────────────
# Inline parser — bold, italic, code, links.
# ──────────────────────────────────────────────────────────────────────


def inline(text: str) -> str:
    # Escape HTML first, then re-introduce safe tags.
    text = html.escape(text)
    # Inline code: spans of backticks, longest-match first.
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    # Bold: **text**
    text = re.sub(r"\*\*([^*]+?)\*\*", r"<strong>\1</strong>", text)
    # Italic: *text* (not adjacent to other asterisks)
    text = re.sub(r"(?<!\*)\*([^*\n]+?)\*(?!\*)", r"<em>\1</em>", text)
    # Links: [text](url)
    text = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>',
        text,
    )
    return text


# ──────────────────────────────────────────────────────────────────────
# Block parser — line-based state machine.
# ──────────────────────────────────────────────────────────────────────


def slugify(text: str) -> str:
    s = re.sub(r"[^\w\s-]", "", text.lower())
    s = re.sub(r"[\s_-]+", "-", s).strip("-")
    return s or "section"


def parse_table(lines: list[str], i: int) -> tuple[str, int]:
    """Parse a pipe-table starting at line i. Returns (html, lines_consumed)."""
    # Header line + separator line + body lines.
    header = [c.strip() for c in lines[i].strip().strip("|").split("|")]
    sep = lines[i + 1]
    if "---" not in sep:
        return "", 0
    body = []
    j = i + 2
    while j < len(lines) and lines[j].strip().startswith("|"):
        row = [c.strip() for c in lines[j].strip().strip("|").split("|")]
        body.append(row)
        j += 1
    out = ['<table>', '<thead><tr>']
    for h in header:
        out.append(f'<th>{inline(h)}</th>')
    out.append('</tr></thead><tbody>')
    for row in body:
        out.append('<tr>')
        for cell in row:
            out.append(f'<td>{inline(cell)}</td>')
        out.append('</tr>')
    out.append('</tbody></table>')
    return '\n'.join(out), j - i


def parse_list_block(lines: list[str], i: int) -> tuple[str, int]:
    """Parse one contiguous list block (- or 1.) starting at line i."""
    bullet_re = re.compile(r"^(\s*)([-*+]|\d+\.)\s+(.*)$")
    items: list[tuple[int, str, str]] = []  # (indent, marker, text)
    j = i
    while j < len(lines):
        m = bullet_re.match(lines[j])
        if not m:
            break
        indent = len(m.group(1))
        marker = m.group(2)
        text = m.group(3)
        items.append((indent, marker, text))
        j += 1

    if not items:
        return "", 0

    # Render with nested ul/ol by indent depth (rounded to 2-space units).
    out: list[str] = []
    open_stack: list[tuple[int, str]] = []  # (indent, tag)
    for indent, marker, text in items:
        tag = "ol" if re.match(r"\d+\.", marker) else "ul"
        # Close any deeper levels.
        while open_stack and open_stack[-1][0] > indent:
            out.append(f"</{open_stack[-1][1]}>")
            open_stack.pop()
        # Open a new level if we're deeper.
        if not open_stack or open_stack[-1][0] < indent:
            out.append(f"<{tag}>")
            open_stack.append((indent, tag))
        out.append(f"<li>{inline(text)}</li>")
    while open_stack:
        out.append(f"</{open_stack[-1][1]}>")
        open_stack.pop()
    return "\n".join(out), j - i


def parse_code_fence(lines: list[str], i: int) -> tuple[str, int]:
    """Parse a fenced code block. Returns (html, consumed_lines).

    Mermaid carve-out (2026-05-17): code blocks with ```mermaid get
    wrapped in <div class="mermaid"> so the mermaid.js client-side
    library (loaded from CDN in the page head) renders them as SVG
    diagrams. Other languages stay as <pre><code class="lang-X">.
    """
    first = lines[i]
    lang = first[3:].strip()
    body: list[str] = []
    j = i + 1
    while j < len(lines) and not lines[j].startswith("```"):
        body.append(lines[j])
        j += 1
    code = "\n".join(body)
    if lang.lower() == "mermaid":
        # Mermaid expects RAW text (no HTML escaping); the library
        # handles its own DSL parsing client-side.
        return f'<div class="mermaid">{code}</div>', (j - i) + 1
    code_esc = html.escape(code)
    lang_attr = f' class="lang-{html.escape(lang)}"' if lang else ""
    return f'<pre><code{lang_attr}>{code_esc}</code></pre>', (j - i) + 1


def md_to_html_blocks(text: str) -> tuple[str, list[tuple[int, str, str]]]:
    """Convert markdown to HTML. Returns (html, toc_entries).

    toc_entries: list of (level, slug, heading_text).
    """
    lines = text.split("\n")
    out: list[str] = []
    toc: list[tuple[int, str, str]] = []
    i = 0
    paragraph: list[str] = []

    def flush_paragraph():
        if paragraph:
            text = " ".join(paragraph).strip()
            if text:
                out.append(f"<p>{inline(text)}</p>")
            paragraph.clear()

    while i < len(lines):
        line = lines[i]

        # Fenced code block
        if line.startswith("```"):
            flush_paragraph()
            block, consumed = parse_code_fence(lines, i)
            out.append(block)
            i += consumed
            continue

        # Heading
        m = re.match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
        if m:
            flush_paragraph()
            level = len(m.group(1))
            text = m.group(2)
            slug = slugify(text)
            # Ensure uniqueness by appending an index if collision.
            existing = {s for _, s, _ in toc}
            base = slug
            n = 1
            while slug in existing:
                n += 1
                slug = f"{base}-{n}"
            toc.append((level, slug, text))
            out.append(f'<h{level} id="{slug}">{inline(text)}</h{level}>')
            i += 1
            continue

        # Horizontal rule
        if re.match(r"^-{3,}\s*$", line):
            flush_paragraph()
            out.append("<hr>")
            i += 1
            continue

        # Blockquote
        if line.startswith("> "):
            flush_paragraph()
            block_lines = []
            while i < len(lines) and lines[i].startswith("> "):
                block_lines.append(lines[i][2:])
                i += 1
            inner = " ".join(block_lines).strip()
            out.append(f"<blockquote>{inline(inner)}</blockquote>")
            continue

        # Table: detect by a "|...|" line followed by a "|---|" line.
        if line.strip().startswith("|") and i + 1 < len(lines) and "---" in lines[i + 1]:
            flush_paragraph()
            block, consumed = parse_table(lines, i)
            if block:
                out.append(block)
                i += consumed
                continue

        # List (- or 1.)
        if re.match(r"^\s*([-*+]|\d+\.)\s+", line):
            flush_paragraph()
            block, consumed = parse_list_block(lines, i)
            out.append(block)
            i += consumed
            continue

        # Blank line
        if not line.strip():
            flush_paragraph()
            i += 1
            continue

        # Paragraph line
        paragraph.append(line.strip())
        i += 1

    flush_paragraph()
    return "\n".join(out), toc


# ──────────────────────────────────────────────────────────────────────
# Page rendering — wraps content in HTML shell, adds nav + TOC.
# ──────────────────────────────────────────────────────────────────────


def render_page(
    title: str,
    body_html: str,
    toc: list[tuple[int, str, str]],
    nav_prev: tuple[str, str] | None = None,
    nav_next: tuple[str, str] | None = None,
    nav_index: str | None = None,
    include_toc: bool = True,
) -> str:
    nav_parts = []
    if nav_index:
        nav_parts.append(f'<span class="crumb">📖</span> <a href="{nav_index}">Index</a>')
    nav_right = []
    if nav_prev:
        nav_right.append(f'<a href="{nav_prev[1]}">← {html.escape(nav_prev[0])}</a>')
    if nav_next:
        nav_right.append(f'<a href="{nav_next[1]}">{html.escape(nav_next[0])} →</a>')
    nav_html = ""
    if nav_parts or nav_right:
        nav_html = (
            '<nav class="topnav">'
            f'<div>{"".join(nav_parts)}</div>'
            f'<div>{" ".join(nav_right)}</div>'
            "</nav>"
        )

    toc_html = ""
    if include_toc and toc:
        toc_html = '<div class="toc"><h3>Contents</h3><ul>'
        for level, slug, text in toc:
            if level > 3:  # skip h4+ in TOC
                continue
            indent = "  " * max(0, level - 2)
            toc_html += f'{indent}<li><a href="#{slug}">{html.escape(text)}</a></li>'
        toc_html += "</ul></div>"

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{html.escape(title)}</title>
<style>{CSS}</style>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<script>
// Mermaid client-side renderer (2026-05-17). Picks up every
// <div class="mermaid">...</div> emitted by parse_code_fence.
// Uses the UMD build (not ESM) so it works when the HTML is opened
// directly via file:// — ESM modules require an http(s) origin per
// browser CORS rules and silently no-op on file:// pages.
(function() {{
  if (typeof mermaid === 'undefined') return;
  var isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  mermaid.initialize({{ startOnLoad: true, theme: isDark ? 'dark' : 'default', securityLevel: 'loose' }});
}})();
</script>
</head>
<body>
{nav_html}
<div class="container">
{toc_html}
{body_html}
</div>
</body>
</html>
"""


# ──────────────────────────────────────────────────────────────────────
# Splitter — break HTML into multiple pages by H2 boundary.
# ──────────────────────────────────────────────────────────────────────


def split_by_h2(
    body_html: str, toc: list[tuple[int, str, str]], max_lines: int
) -> list[tuple[str, str, list[tuple[int, str, str]]]]:
    """
    Split if body_html has more lines than max_lines. Returns list of
    (page_title, page_html, page_toc). Single-element list if no split.
    """
    if body_html.count("\n") <= max_lines:
        return [("", body_html, toc)]

    # Find H2 boundaries.
    h2_pattern = re.compile(r'<h2 id="([^"]+)">(.*?)</h2>', re.DOTALL)
    boundaries = [(m.start(), m.group(1), re.sub("<[^>]+>", "", m.group(2)))
                  for m in h2_pattern.finditer(body_html)]
    if len(boundaries) < 2:
        return [("", body_html, toc)]

    # First page: everything BEFORE the first H2 → goes into the index as preamble.
    pages: list[tuple[str, str, list[tuple[int, str, str]]]] = []
    preamble = body_html[: boundaries[0][0]].strip()

    # Each H2 becomes a page with everything until the next H2.
    for idx, (start, slug, title) in enumerate(boundaries):
        end = boundaries[idx + 1][0] if idx + 1 < len(boundaries) else len(body_html)
        page_html = body_html[start:end]
        # The page's own TOC is the H3+H4 entries that fall within this range.
        page_toc: list[tuple[int, str, str]] = []
        for level, s, t in toc:
            if level < 2:
                continue
            # Find the position of this heading in the HTML.
            heading_pos = body_html.find(f'id="{s}"')
            if heading_pos == -1:
                continue
            if start <= heading_pos < end:
                page_toc.append((level, s, t))
        pages.append((title, page_html, page_toc))

    # Inject preamble at top of index TOC (returned as part of the first page meta).
    # We attach the preamble to the index, not to the H2 pages.
    if preamble:
        # Prepend a meta entry — page 0 is "index" not a real H2 split.
        pages.insert(0, ("Overview", preamble, []))
    return pages


# ──────────────────────────────────────────────────────────────────────
# Main entry.
# ──────────────────────────────────────────────────────────────────────


def main() -> int:
    p = argparse.ArgumentParser(description="Convert markdown to HTML (split if long).")
    p.add_argument("input", help="path to .md file")
    p.add_argument("--out-dir", default=None,
                   help="output dir (default: same dir as input)")
    p.add_argument("--split", type=int, default=800,
                   help="split into multiple pages if HTML > N lines (default 800)")
    args = p.parse_args()

    in_path = Path(args.input)
    if not in_path.exists():
        print(f"error: {in_path} not found", file=sys.stderr)
        return 1

    out_dir = Path(args.out_dir) if args.out_dir else in_path.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = in_path.stem

    text = in_path.read_text(encoding="utf-8")
    body_html, toc = md_to_html_blocks(text)

    pages = split_by_h2(body_html, toc, args.split)

    if len(pages) == 1:
        out = out_dir / f"{stem}.html"
        out.write_text(
            render_page(stem, pages[0][1], toc, include_toc=True),
            encoding="utf-8",
        )
        print(f"wrote {out}")
        return 0

    # Multi-page: pages directory + index.html
    pages_dir = out_dir / f"{stem}_pages"
    pages_dir.mkdir(exist_ok=True)

    # Generate filenames.
    file_names = []
    for idx, (title, _, _) in enumerate(pages):
        slug = slugify(title) if title else f"part-{idx}"
        file_names.append(f"{idx:02d}-{slug}.html")

    # Index page: TOC linking to each split.
    index_body = '<div class="container">'
    if pages and pages[0][0] == "Overview":
        index_body += pages[0][1]  # preamble
    index_body += "<h2>Contents</h2><ul>"
    for idx, (title, _, _) in enumerate(pages):
        if title == "Overview":
            continue
        index_body += f'<li><a href="{stem}_pages/{file_names[idx]}">{html.escape(title)}</a></li>'
    index_body += "</ul></div>"

    index_html = f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{html.escape(stem)}</title>
<style>{CSS}</style>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<script>
// Mermaid client-side renderer (2026-05-17). Uses the UMD build —
// works for both file:// and HTTP page opens. ESM modules require
// http(s) origin per browser CORS rules; the UMD global doesn't.
(function() {{
  if (typeof mermaid === 'undefined') return;
  var isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  mermaid.initialize({{ startOnLoad: true, theme: isDark ? 'dark' : 'default', securityLevel: 'loose' }});
}})();
</script>
</head><body>{index_body}</body></html>"""
    (out_dir / f"{stem}.html").write_text(index_html, encoding="utf-8")
    print(f"wrote {out_dir / f'{stem}.html'} (index)")

    # Write each split page.
    for idx, (title, body, page_toc) in enumerate(pages):
        if title == "Overview":
            continue  # preamble lives in index
        prev_link = None
        next_link = None
        if idx > 0 and pages[idx - 1][0] != "Overview":
            prev_link = (pages[idx - 1][0], file_names[idx - 1])
        elif idx == 1 and pages[0][0] == "Overview":
            prev_link = None  # index serves as "prev"
        if idx + 1 < len(pages):
            next_link = (pages[idx + 1][0], file_names[idx + 1])

        page_html = render_page(
            f"{stem} — {title}",
            body,
            page_toc,
            nav_prev=prev_link,
            nav_next=next_link,
            nav_index=f"../{stem}.html",
            include_toc=True,
        )
        (pages_dir / file_names[idx]).write_text(page_html, encoding="utf-8")

    print(f"wrote {len(pages) - 1} split pages to {pages_dir}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
