#!/usr/bin/env python3
"""Check that published artifacts describe the same app and archive."""

import hashlib
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET
import zipfile


def verify(directory: Path) -> None:
    sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    feed = ET.parse(directory / "appcast.xml")
    items = feed.findall("./channel/item")
    assert len(items) == 1, "Release feed must contain exactly the packaged update"
    item = items[0]
    enclosure = item.find("enclosure")
    assert enclosure is not None
    version = item.findtext(f"{sparkle}shortVersionString")
    archive_name = f"AgentBar-v{version}-macos-arm64.zip"
    archive_path = directory / archive_name
    with zipfile.ZipFile(archive_path) as archive:
        info = plistlib.loads(archive.read("AgentBar.app/Contents/Info.plist"))
        assert "AgentBar.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" in archive.namelist()
    assert version == info["CFBundleShortVersionString"]
    assert item.findtext(f"{sparkle}version") == info["CFBundleVersion"]
    assert info["SURequireSignedFeed"] and info["SUVerifyUpdateBeforeExtraction"]
    assert info["SUEnableAutomaticChecks"] and info["SUAutomaticallyUpdate"]
    assert enclosure.attrib["url"] == f"https://github.com/chenjingdev/agent-bar/releases/download/v{version}/{archive_name}"
    assert int(enclosure.attrib["length"]) == archive_path.stat().st_size
    assert enclosure.attrib[f"{sparkle}edSignature"]
    for entry in (directory / "SHA256SUMS.txt").read_text().splitlines():
        digest, filename = entry.split(maxsplit=1)
        assert hashlib.sha256((directory / filename.strip()).read_bytes()).hexdigest() == digest
    print(f"Release artifacts verified: {version} (build {info['CFBundleVersion']})")


if __name__ == "__main__":
    verify(Path(sys.argv[1]))
