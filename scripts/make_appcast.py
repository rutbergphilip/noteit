#!/usr/bin/env python3
"""Writes a Sparkle appcast.xml with a single release item.

    make_appcast.py --version 1.2.0 --build 202610141030 --dmg NoteIt-1.2.0.dmg \
        --url https://github.com/.../NoteIt-1.2.0.dmg --notes notes.md \
        [--ed-signature <sign_update -p output>] --output appcast.xml

Release notes are converted from Markdown to HTML with a small converter that handles
headings, bullet lists, paragraphs, inline code, links and bold text.
"""

import argparse
import email.utils
import html
import os
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MINIMUM_SYSTEM_VERSION = "14.0"


def inline(text):
    parts = re.split(r"(`[^`]+`)", text)
    out = []
    for part in parts:
        if len(part) > 1 and part.startswith("`") and part.endswith("`"):
            out.append("<code>" + html.escape(part[1:-1], quote=False) + "</code>")
            continue
        s = html.escape(part, quote=False)
        s = re.sub(
            r"\[([^\]]+)\]\(([^)\s]+)\)",
            lambda m: '<a href="' + m.group(2).replace('"', "&quot;") + '">' + m.group(1) + "</a>",
            s,
        )
        s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
        out.append(s)
    return "".join(out)


def markdown_to_html(markdown):
    blocks = []
    paragraph = []
    items = []

    def flush_paragraph():
        if paragraph:
            blocks.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    def flush_list():
        if items:
            blocks.append("<ul>\n" + "\n".join("<li>" + inline(i) + "</li>" for i in items) + "\n</ul>")
            items.clear()

    for raw in markdown.splitlines():
        line = raw.rstrip()
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        bullet = re.match(r"^\s*[-*+]\s+(.*)$", line)
        if not line.strip():
            flush_paragraph()
            flush_list()
        elif heading:
            flush_paragraph()
            flush_list()
            level = len(heading.group(1))
            blocks.append(f"<h{level}>" + inline(heading.group(2).strip()) + f"</h{level}>")
        elif bullet:
            flush_paragraph()
            items.append(bullet.group(1).strip())
        elif items and raw[:1].isspace():
            items[-1] += " " + line.strip()
        else:
            flush_list()
            paragraph.append(line.strip())
    flush_paragraph()
    flush_list()
    return "\n".join(blocks)


def cdata(text):
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def attr(value):
    return html.escape(str(value), quote=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", required=True, help="marketing version, e.g. 1.2.0")
    parser.add_argument("--build", required=True, help="CFBundleVersion of the build")
    parser.add_argument("--dmg", required=True, help="path to the DMG (for its length)")
    parser.add_argument("--url", required=True, help="download URL of the DMG")
    parser.add_argument("--notes", required=True, help="Markdown release notes file")
    parser.add_argument("--ed-signature", default="", help="EdDSA signature from sign_update -p")
    parser.add_argument("--output", required=True, help="where to write appcast.xml")
    args = parser.parse_args()

    if not re.fullmatch(r"[0-9]+", args.build):
        sys.exit(f"error: build number must be numeric, got {args.build!r}")
    length = os.path.getsize(args.dmg)
    with open(args.notes, encoding="utf-8") as f:
        notes_html = markdown_to_html(f.read())
    if not notes_html:
        sys.exit("error: release notes are empty")

    enclosure = (
        f'<enclosure url="{attr(args.url)}" length="{length}" type="application/octet-stream"'
        + (f' sparkle:edSignature="{attr(args.ed_signature)}"' if args.ed_signature else "")
        + " />"
    )
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
  <channel>
    <title>NoteIt</title>
    <link>https://github.com/rutbergphilip/noteit</link>
    <description>NoteIt updates</description>
    <language>en</language>
    <item>
      <title>{attr("NoteIt " + args.version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{attr(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{attr(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <description>{cdata(notes_html)}</description>
      {enclosure}
    </item>
  </channel>
</rss>
"""

    root = ET.fromstring(xml.encode("utf-8"))
    item = root.find("channel/item")
    if item is None or item.find(f"{{{SPARKLE_NS}}}version").text != args.build:
        sys.exit("error: generated appcast is malformed")

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(xml)


if __name__ == "__main__":
    main()
