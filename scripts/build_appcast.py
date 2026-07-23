#!/usr/bin/env python3
"""Maintain a cumulative Sparkle appcast for XDownloader.

Sparkle picks the item with the highest ``sparkle:version``, so the feed must
list EVERY released version, not just the newest. This script reads the existing
cumulative appcast (if any), drops any item for the version being published (so
re-running a release is idempotent), prepends the new item, and writes the full
feed back. Because every version stays in the feed, the newest release is always
advertised correctly regardless of the order releases are published in.

The enclosure still points at the GitHub Release asset; only the feed itself is
hosted (on GitHub Pages). EdDSA signing happens in CI via ``sign_update``; its
output is passed in verbatim as ``--sig-attrs``.
"""

import argparse
import re

HEADER = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<rss version="2.0" '
    'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
    "  <channel>\n"
    "    <title>XDownloader</title>\n"
)
FOOTER = "  </channel>\n</rss>\n"

# Items are machine-generated with the fixed shape below (no nested <item>, no
# CDATA), so a non-greedy block match is a safe way to carry prior entries over.
ITEM_RE = re.compile(r"<item>.*?</item>", re.DOTALL)
SHORT_VERSION_RE = re.compile(
    r"<sparkle:shortVersionString>([^<]*)</sparkle:shortVersionString>"
)


def existing_items(text):
    return ITEM_RE.findall(text)


def short_version(item):
    match = SHORT_VERSION_RE.search(item)
    return match.group(1) if match else None


def build_item(args):
    return (
        "    <item>\n"
        f"      <title>{args.version}</title>\n"
        f"      <pubDate>{args.pub_date}</pubDate>\n"
        f"      <sparkle:version>{args.numeric}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>\n"
        f"      <sparkle:minimumSystemVersion>{args.min_system}</sparkle:minimumSystemVersion>\n"
        f"      <sparkle:releaseNotesLink>{args.notes_link}</sparkle:releaseNotesLink>\n"
        f'      <enclosure url="{args.enclosure_url}" {args.sig_attrs} '
        'type="application/octet-stream"/>\n'
        "    </item>"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--existing", help="Path to the current appcast.xml (optional)")
    parser.add_argument("--version", required=True, help="Marketing version, e.g. 1.7.0")
    parser.add_argument("--numeric", required=True, help="Monotonic sparkle:version")
    parser.add_argument("--min-system", default="14.0")
    parser.add_argument("--notes-link", required=True)
    parser.add_argument("--enclosure-url", required=True)
    parser.add_argument("--sig-attrs", required=True, help="sign_update output attributes")
    parser.add_argument("--pub-date", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    carried = []
    if args.existing:
        try:
            with open(args.existing, encoding="utf-8") as handle:
                carried = existing_items(handle.read())
        except FileNotFoundError:
            carried = []
    # Drop a prior item for this same version so re-publishing a tag is idempotent.
    carried = [item for item in carried if short_version(item) != args.version]

    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(HEADER)
        handle.write(build_item(args) + "\n")
        for item in carried:
            handle.write(item.strip() + "\n")
        handle.write(FOOTER)


if __name__ == "__main__":
    main()
