"""Simple doc server — serves Yume docs as rendered HTML at http://localhost:8777"""

import http.server
import os
import re
from pathlib import Path

PORT = 8777
DOCS_DIR = Path(__file__).parent


def md_to_html(md_text: str, title: str) -> str:
    """Quick markdown → HTML (no dependencies needed).

    Mermaid carve-out (2026-05-17): ```mermaid blocks emit
    <div class="mermaid">RAW</div> so the client-side mermaid.js
    UMD library (script tag in the page head) renders them as SVG.
    UMD (not ESM) so the page works on file:// AND http://.
    """
    html = md_text

    def _code_block_replacer(m):
        lang = m.group(1)
        body = m.group(2)
        if lang.lower() == "mermaid":
            # Raw text — mermaid parses its own DSL. No HTML escaping.
            return f'<div class="mermaid">{body}</div>'
        # Regular code block: escape < so e.g. <T> in code text doesn't
        # confuse the browser HTML parser.
        return (
            f'<pre><code class="{lang}">'
            f'{body.replace("<", "&lt;")}'
            f'</code></pre>'
        )

    # Code blocks (```...```)
    html = re.sub(r'```(\w*)\n(.*?)```', _code_block_replacer,
                  html, flags=re.DOTALL)

    # Inline code
    html = re.sub(r'`([^`]+)`', r'<code>\1</code>', html)

    # Headers
    html = re.sub(r'^#### (.+)$', r'<h4>\1</h4>', html, flags=re.MULTILINE)
    html = re.sub(r'^### (.+)$', r'<h3>\1</h3>', html, flags=re.MULTILINE)
    html = re.sub(r'^## (.+)$', r'<h2>\1</h2>', html, flags=re.MULTILINE)
    html = re.sub(r'^# (.+)$', r'<h1>\1</h1>', html, flags=re.MULTILINE)

    # Bold + italic
    html = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', html)
    html = re.sub(r'\*(.+?)\*', r'<em>\1</em>', html)

    # Links
    html = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2" target="_blank">\1</a>', html)

    # Tables
    lines = html.split('\n')
    in_table = False
    new_lines = []
    for line in lines:
        if '|' in line and line.strip().startswith('|'):
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            if all(re.match(r'^[-:]+$', c) for c in cells):
                continue  # skip separator row
            if not in_table:
                new_lines.append('<table>')
                tag = 'th'
                in_table = True
            else:
                tag = 'td'
            row = ''.join(f'<{tag}>{c}</{tag}>' for c in cells)
            new_lines.append(f'<tr>{row}</tr>')
        else:
            if in_table:
                new_lines.append('</table>')
                in_table = False
            new_lines.append(line)
    if in_table:
        new_lines.append('</table>')
    html = '\n'.join(new_lines)

    # Paragraphs (simple: blank lines become breaks)
    html = re.sub(r'\n\n+', '\n<br><br>\n', html)

    return f"""<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>{title} — Yume Docs</title>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<script>
// Mermaid client-side renderer (2026-05-17). UMD build, no ESM —
// works whether the page is opened via file:// or via this server.
(function() {{
  if (typeof mermaid === 'undefined') return;
  // Dark theme — the page palette is GitHub-dark; match.
  mermaid.initialize({{ startOnLoad: true, theme: 'dark', securityLevel: 'loose' }});
}})();
</script>
<style>
  body {{
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    max-width: 900px; margin: 40px auto; padding: 0 20px;
    background: #0d1117; color: #c9d1d9; line-height: 1.6;
  }}
  h1 {{ color: #e6bf4a; border-bottom: 2px solid #30363d; padding-bottom: 8px; }}
  h2 {{ color: #58a6ff; margin-top: 2em; }}
  h3 {{ color: #79c0ff; }}
  a {{ color: #58a6ff; }}
  code {{
    background: #161b22; padding: 2px 6px; border-radius: 3px;
    font-family: 'Fira Code', monospace; font-size: 0.9em;
  }}
  pre {{
    background: #161b22; padding: 16px; border-radius: 6px;
    overflow-x: auto; border: 1px solid #30363d;
  }}
  pre code {{ background: none; padding: 0; }}
  table {{
    border-collapse: collapse; width: 100%; margin: 1em 0;
  }}
  th, td {{
    border: 1px solid #30363d; padding: 8px 12px; text-align: left;
  }}
  th {{ background: #161b22; color: #e6bf4a; }}
  tr:nth-child(even) {{ background: #0d1117; }}
  tr:nth-child(odd) {{ background: #161b22; }}
  strong {{ color: #e6bf4a; }}
  .nav {{ margin-bottom: 20px; padding: 10px; background: #161b22; border-radius: 6px; }}
  .nav a {{ margin-right: 16px; text-decoration: none; }}
  .nav a:hover {{ text-decoration: underline; }}
  /* Mermaid diagrams: center + bordered card so the SVG breathes. */
  .mermaid {{
    background: #161b22; border: 1px solid #30363d; border-radius: 6px;
    padding: 20px; margin: 20px 0; text-align: center; overflow-x: auto;
  }}
  .mermaid svg {{ max-width: 100%; height: auto; }}
</style>
</head><body>
<div class="nav">
  <a href="/">Home</a>
  <a href="/01_game_dev_cycle.md">Game Dev Cycle</a>
  <a href="/02_rpg_systems_guide.md">RPG Systems</a>
  <a href="/03_godot_rpg_ecosystem.md">Godot Ecosystem</a>
</div>
{html}
</body></html>"""


class DocsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.strip('/')

        if path == '' or path == 'index.html':
            # Index page — list all .md files + ADRs.
            top_files = sorted(DOCS_DIR.glob('*.md'))
            top_links = '\n'.join(
                f'<li><a href="/{f.name}">{f.stem.replace("_", " ").title()}</a> — {f.stat().st_size // 1024}KB</li>'
                for f in top_files
            )
            adr_dir = DOCS_DIR / 'adr'
            adr_links = ''
            if adr_dir.exists():
                adr_files = sorted(adr_dir.glob('*.md'))
                adr_links = '\n'.join(
                    f'<li><a href="/adr/{f.name}">{f.stem.replace("-", " ")}</a></li>'
                    for f in adr_files
                )
            content = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Yume Docs</title>
<style>
  body {{ font-family: sans-serif; max-width: 800px; margin: 60px auto;
         background: #0d1117; color: #c9d1d9; padding: 0 20px; }}
  h1 {{ color: #e6bf4a; }}
  h2 {{ color: #58a6ff; margin-top: 2em; border-bottom: 1px solid #30363d;
         padding-bottom: 4px; }}
  a {{ color: #58a6ff; font-size: 1.0em; }}
  li {{ margin: 6px 0; }}
  .adr-list {{ columns: 2; -webkit-columns: 2; -moz-columns: 2; }}
  .adr-list li {{ break-inside: avoid; }}
</style></head><body>
<h1>Yume Docs</h1>
<h2>Top-level docs</h2>
<ul>{top_links}</ul>
<h2>ADRs (architecture decisions)</h2>
<ul class="adr-list">{adr_links}</ul>
</body></html>"""
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(content.encode())
            return

        # Serve markdown file as HTML
        file_path = DOCS_DIR / path
        if file_path.exists() and file_path.suffix == '.md':
            md_text = file_path.read_text()
            title = file_path.stem.replace('_', ' ').title()
            html = md_to_html(md_text, title)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(html.encode())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not found')

    def log_message(self, format, *args):
        pass  # Suppress logs


if __name__ == '__main__':
    server = http.server.HTTPServer(('0.0.0.0', PORT), DocsHandler)
    print(f'Yume Docs server running at http://localhost:{PORT}')
    print(f'Serving from: {DOCS_DIR}')
    server.serve_forever()
