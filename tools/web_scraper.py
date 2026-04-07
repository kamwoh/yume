"""Web scraper — fetches pages with a browser user agent to avoid blocks."""

import sys
import urllib.request
import re
from pathlib import Path


HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}


def fetch_page(url: str) -> str:
    """Fetch a page and return clean text content."""
    req = urllib.request.Request(url, headers=HEADERS)
    resp = urllib.request.urlopen(req, timeout=30)
    html = resp.read().decode("utf-8", errors="ignore")
    return html_to_text(html)


def html_to_text(html: str) -> str:
    """Convert HTML to readable text."""
    # Remove script/style
    text = re.sub(r"<script[^>]*>.*?</script>", "", html, flags=re.DOTALL)
    text = re.sub(r"<style[^>]*>.*?</style>", "", html, flags=re.DOTALL)
    # Convert common tags
    text = re.sub(r"<h[1-6][^>]*>(.*?)</h[1-6]>", r"\n## \1\n", text, flags=re.DOTALL)
    text = re.sub(r"<li[^>]*>(.*?)</li>", r"- \1", text, flags=re.DOTALL)
    text = re.sub(r"<br\s*/?>", "\n", text)
    text = re.sub(r"<p[^>]*>", "\n", text)
    text = re.sub(r"</p>", "\n", text)
    # Remove remaining tags
    text = re.sub(r"<[^>]+>", " ", text)
    # Clean whitespace
    text = re.sub(r"&nbsp;", " ", text)
    text = re.sub(r"&amp;", "&", text)
    text = re.sub(r"&lt;", "<", text)
    text = re.sub(r"&gt;", ">", text)
    text = re.sub(r"&#\d+;", "", text)
    text = re.sub(r"\n\s*\n\s*\n+", "\n\n", text)
    text = re.sub(r"  +", " ", text)
    return text.strip()


def fetch_and_save(url: str, output_path: str) -> None:
    """Fetch a URL and save cleaned text to a file."""
    print(f"Fetching: {url}")
    text = fetch_page(url)
    Path(output_path).write_text(text)
    print(f"Saved: {output_path} ({len(text)} chars)")


def fetch_multiple(urls: list[str], output_dir: str) -> None:
    """Fetch multiple URLs and save each to output_dir."""
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    for url in urls:
        # Generate filename from URL
        name = url.rstrip("/").split("/")[-1]
        if not name or name == "":
            name = "index"
        name = re.sub(r"[^a-zA-Z0-9_-]", "_", name)
        output_path = str(Path(output_dir) / f"{name}.txt")
        try:
            fetch_and_save(url, output_path)
        except Exception as e:
            print(f"ERROR fetching {url}: {e}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python web_scraper.py <url> [output_file]")
        print("  python web_scraper.py --batch <url1> <url2> ... --output <dir>")
        sys.exit(1)

    if sys.argv[1] == "--batch":
        # Find --output flag
        urls = []
        output_dir = "/tmp/scraped"
        i = 2
        while i < len(sys.argv):
            if sys.argv[i] == "--output" and i + 1 < len(sys.argv):
                output_dir = sys.argv[i + 1]
                i += 2
            else:
                urls.append(sys.argv[i])
                i += 1
        fetch_multiple(urls, output_dir)
    else:
        url = sys.argv[1]
        output = sys.argv[2] if len(sys.argv) > 2 else "/tmp/scraped_page.txt"
        fetch_and_save(url, output)
