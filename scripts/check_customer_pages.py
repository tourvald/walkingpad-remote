"""Validate static customer pages and, optionally, their exact deployed bytes."""

import argparse
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlparse
from urllib.request import urlopen


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.has_title = False
        self.headings = 0
        self.russian = False
        self.viewport = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        assert tag not in {"script", "iframe", "form", "input"}, tag
        self.has_title |= tag == "title"
        self.headings += tag == "h1"
        self.russian |= tag == "html" and attrs.get("lang") == "ru"
        self.viewport |= tag == "meta" and attrs.get("name") == "viewport"
        if tag in {"a", "link"}:
            self.links.append(attrs["href"])


def check(site_url=None):
    root = Path(__file__).resolve().parents[1] / "website"
    assert (root / ".nojekyll").is_file()
    for name in ("index.html", "privacy.html", "support.html"):
        path = root / name
        content = path.read_text(encoding="utf-8")
        assert "черновик" not in content.lower(), path
        page = Page()
        page.feed(content)
        assert page.russian and page.viewport and page.has_title and page.headings == 1, path
        for link in page.links:
            parsed = urlparse(link)
            if parsed.scheme:
                assert parsed.scheme in {"https", "mailto"}, link
            else:
                target = (root / parsed.path).resolve()
                assert target.is_relative_to(root) and target.is_file(), link
        print(f"PASS {name}: landmarks, local links, no forms/scripts or draft text")
    if site_url:
        assert site_url.startswith("https://") and site_url.endswith("/")
        for path in sorted(root.iterdir()):
            if path.name.startswith("."):
                continue
            with urlopen(urljoin(site_url, path.name), timeout=30) as response:
                assert response.status == 200, path
                assert response.read() == path.read_bytes(), path
            print(f"PASS live {path.name}: HTTP 200, exact source bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site-url", help="Published HTTPS site root with trailing slash")
    check(parser.parse_args().site_url)
