---
description: Convert a markdown design doc (GDD, milestone, ADR, etc.) into a self-contained HTML page. Splits into multiple pages with prev/next nav + index when the doc is long. Use whenever the user asks to "view as HTML", "convert to HTML", "render this doc", or wants a more readable / shareable format than raw markdown.
allowed-tools: Bash, Read
---

# /md-to-html — Markdown → HTML converter

Renders a markdown file (typically a design doc, ADR, or GDD) as
styled HTML. For long docs (> ~800 lines of HTML output), splits into
one page per H2 section with an index + prev/next navigation. No
external dependencies — pure Python stdlib.

## When to invoke this skill

- User says "convert this to HTML", "render as HTML", "view this in a browser"
- User wants to share or print a design doc
- A long design doc (GDD, milestone spec, ADR) would benefit from
  per-section pagination + a clickable TOC
- User asks for a stylable / reflow-friendly version of a markdown file

## When NOT to invoke

- The user just wants you to read the markdown (use `Read` directly)
- The markdown is a code-comment or inline snippet (no value)
- The user wants the actual file edited (use `Edit`, not this skill)

## Usage

```
python3 .claude/skills/md-to-html/convert.py <input.md> [--out-dir DIR] [--split N]
```

Arguments:

| Flag | Default | Purpose |
|---|---|---|
| `input` | — (required) | Path to a `.md` file |
| `--out-dir DIR` | input's directory | Where to write the `.html` output (and `_pages/` subfolder if split) |
| `--split N` | 800 | Threshold (lines of HTML output) before splitting into multiple files |

## Output layout

**Short doc** (HTML output ≤ split threshold):

```
<input-dir>/
├── <stem>.md
└── <stem>.html          ← single page, embedded TOC + CSS
```

**Long doc** (HTML output > split threshold):

```
<input-dir>/
├── <stem>.md
├── <stem>.html          ← index: preamble + ToC linking to each split
└── <stem>_pages/
    ├── 00-overview.html ← optional preamble (everything before the first H2)
    ├── 01-<slug-of-first-h2>.html
    ├── 02-<slug-of-second-h2>.html
    └── …                ← prev/next nav between adjacent pages; "Index" link back
```

Each page has:
- Embedded CSS (light + dark mode via `prefers-color-scheme`)
- A clickable in-page Table of Contents (H1/H2/H3 entries)
- Top-bar nav: index link (left) + prev/next page links (right)
- Anchor links from headings (clickable + URL-shareable)

## Supported markdown (GitHub-flavored subset)

| Element | Syntax | Renders as |
|---|---|---|
| Headings | `#` to `######` | `<h1>` to `<h6>` with id-slugs |
| Bold | `**bold**` | `<strong>` |
| Italic | `*italic*` | `<em>` |
| Inline code | `` `code` `` | `<code>` |
| Fenced code | ` ```lang\ncode\n``` ` | `<pre><code class="lang-X">` |
| Lists | `- item` or `1. item` | nested `<ul>` / `<ol>` by indent |
| Tables | pipe `\|--\|` syntax | `<table>` with striped rows |
| Blockquotes | `> quote` | `<blockquote>` |
| Horizontal rules | `---` | `<hr>` |
| Links | `[text](url)` | `<a href>` |

Not supported (use plain text or escape if needed):

- Footnotes
- HTML-in-markdown (escaped automatically)
- Math / LaTeX
- Multi-line list items with nested code blocks (single-line items only)

**Mermaid** (added 2026-05-17): fenced blocks with ```mermaid get
wrapped in `<div class="mermaid">` and rendered client-side by
mermaid.js (loaded from CDN, ~50KB). Works for flowcharts,
sequence diagrams, state diagrams, class diagrams, etc. Requires
an internet connection on first page load (subsequent loads use
the browser cache).

## Examples

### Convert a milestone doc (one page if short)

```bash
python3 .claude/skills/md-to-html/convert.py docs/games/aldenmere/three_days_to_eat_milestone.md
# → docs/games/aldenmere/three_days_to_eat_milestone.html
```

### Convert a long GDD with custom split threshold

```bash
python3 .claude/skills/md-to-html/convert.py docs/games/aldenmere/phase1_GDD.md --split 600
# If GDD has >600 lines of HTML, splits into per-H2 pages.
# Otherwise renders as single page.
```

### Convert with a separate output directory

```bash
python3 .claude/skills/md-to-html/convert.py docs/adr/0040-camera-relative-wasd.md \
  --out-dir /tmp/yume-adr-html
# Output: /tmp/yume-adr-html/0040-camera-relative-wasd.html
```

## What to report back

After running, surface to the user:

1. The output path(s) — full path to the index + count of split pages if applicable
2. Whether the doc was rendered as one page or split (and why — line count)
3. A short suggestion on how to view it (e.g., `xdg-open <path>` or
   `cd <dir> && python3 -m http.server` if they want to serve it)
4. Nothing else — keep the response under 6 lines

## What this skill DOES NOT do

- ❌ Edit the source markdown (read-only on input)
- ❌ Download external CSS/JS — output is fully self-contained
- ❌ Render math / LaTeX — see "Not supported" above
- ✓ Mermaid blocks DO render (added 2026-05-17 via CDN mermaid.js)
- ❌ Generate PDFs — use a browser's print-to-PDF on the HTML output
- ❌ Pull markdown from URLs — local files only

## Implementation file

`convert.py` (~450 LoC, pure stdlib). See the file's docstring for the
exact markdown subset supported and the rendering algorithm.

## Empirical case (2026-05-10)

Built to answer "view the Aldenmere GDD + Three Days to Eat milestone
spec as HTML pages." The full Aldenmere `phase1_GDD.md` (~1100 lines)
splits into ~12 per-H2 pages with a clickable index. The
`three_days_to_eat_milestone.md` (~330 lines) renders as a single
page. Same skill works for ADRs, review notes, design briefs, or any
markdown doc.
