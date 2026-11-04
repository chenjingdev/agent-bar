#!/bin/zsh
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
bundle="$repo_dir/AgentBar.app"
output_dir="$repo_dir/work/release"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")
archive="AgentBar-v$version-macos-arm64.zip"
sparkle_bin="$repo_dir/.build/artifacts/sparkle/Sparkle/bin"

: "${SPARKLE_PRIVATE_KEY:?Set SPARKLE_PRIVATE_KEY to the Sparkle signing key.}"
codesign --verify --deep --strict "$bundle"
rm -rf "$output_dir"
mkdir -p "$output_dir"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$output_dir/$archive"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/generate_appcast" \
  --ed-key-file - \
  --maximum-deltas 0 \
  --download-url-prefix "https://github.com/chenjingdev/agent-bar/releases/download/v$version/" \
  --link https://github.com/chenjingdev/agent-bar \
  "$output_dir"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/sign_update" --verify --ed-key-file - "$output_dir/appcast.xml"
archive_signature=$(python3 -c 'import sys,xml.etree.ElementTree as ET; print(ET.parse(sys.argv[1]).find("./channel/item/enclosure").attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"])' "$output_dir/appcast.xml")
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/sign_update" --verify --ed-key-file - "$output_dir/$archive" "$archive_signature"
(cd "$output_dir" && shasum -a 256 "$archive" appcast.xml > SHA256SUMS.txt)
python3 "$repo_dir/scripts/verify-release.py" "$output_dir"
