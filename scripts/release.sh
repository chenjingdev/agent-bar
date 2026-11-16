#!/bin/zsh
# Makes a Limi release: builds with the Developer ID, notarizes, staples, zips,
# signs the zip for Sparkle and, with --publish, puts it on GitHub and in the
# site's update feed.
#   scripts/release.sh [--publish] [notes.html]
# The version is app_version / app_build in scripts/build-app.sh. Raise app_build
# with every release (Sparkle compares it), commit, then run this.
# Without --publish it stops after build/release/Limi.zip, so a release can be
# tried first. With --publish it also:
#   1. tags v<version> and pushes the tag with origin, jsiksn/limi (the source);
#   2. creates the GitHub release on kalti-lab/limi with Limi.zip, so
#      https://github.com/kalti-lab/limi/releases/latest/download/Limi.zip is
#      always the newest one (the site's download button). kalti-lab/limi holds
#      only a README and the releases, so the release gets an annotated tag of
#      the same name there, on that repository's main, dated now;
#   3. adds the version to the update feed, static/limi/appcast.xml in the
#      kalti-site repository. The site also shows the version from that feed.
# Then build, deploy and commit the site (its README).
# A notes file, if given, is HTML: the release notes in the update window, and on
# GitHub followed by a link to the source at this tag. Without one the GitHub
# release has only that link.
# Settings (environment):
#   LIMI_SIGN_IDENTITY    default "Developer ID Application: Jinsik Son (WCP8ASK9HD)"
#   LIMI_NOTARY_PROFILE   notarytool keychain profile, default kalti-notary
#   LIMI_NOTARY_KEYCHAIN  keychain holding it, default ~/.kalti/signing/kalti-signing.keychain-db
#   LIMI_UPDATE_KEY       Sparkle EdDSA private key, default ~/.kalti/signing/limi-sparkle-ed25519.key
#   LIMI_SITE             kalti-site repository, default ~/Desktop/study/kalti-site
#   LIMI_REPO             GitHub repository for releases, default kalti-lab/limi
#   LIMI_SOURCE_REPO      GitHub repository with the source, default jsiksn/limi
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)

publish=0
notes=""
while (( $# > 0 )); do
  case "$1" in
    --publish) publish=1 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1 (scripts/release.sh --help)" >&2; exit 1 ;;
    *) notes="$1" ;;
  esac
  shift
done

identity="${LIMI_SIGN_IDENTITY:-Developer ID Application: Jinsik Son (WCP8ASK9HD)}"
profile="${LIMI_NOTARY_PROFILE:-kalti-notary}"
notary_keychain="${LIMI_NOTARY_KEYCHAIN:-$HOME/.kalti/signing/kalti-signing.keychain-db}"
update_key="${LIMI_UPDATE_KEY:-$HOME/.kalti/signing/limi-sparkle-ed25519.key}"
site="${LIMI_SITE:-$HOME/Desktop/study/kalti-site}"
gh_repo="${LIMI_REPO:-kalti-lab/limi}"
source_repo="${LIMI_SOURCE_REPO:-jsiksn/limi}"

setting() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$script_dir/build-app.sh"; }
version=$(setting app_version)
build=$(setting app_build)
sparkle_version=$(setting sparkle_version)
sign_update="${AGENTBAR_VENDOR_DIR:-$repo_dir/.build/vendor}/Sparkle-$sparkle_version/bin/sign_update"
tag="v$version"
out="$repo_dir/build/release"
zip="$out/Limi.zip"
app="$repo_dir/Limi.app"

[[ -n "$version" && -n "$build" ]] || { echo "could not read app_version/app_build from build-app.sh" >&2; exit 1; }
[[ -f "$update_key" ]] || { echo "no update key at $update_key (swift scripts/make-update-key.swift, once)" >&2; exit 1; }
[[ -z "$notes" || -f "$notes" ]] || { echo "no such notes file: $notes" >&2; exit 1; }
if (( publish )); then
  [[ -z "$(git -C "$repo_dir" status --porcelain)" ]] || { echo "commit first: the release is tagged from HEAD" >&2; exit 1; }
  if git -C "$repo_dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "$tag already exists: raise app_version and app_build in build-app.sh" >&2; exit 1
  fi
  [[ -d "$site/.git" ]] || { echo "no site repository at $site" >&2; exit 1; }
fi

echo "== Limi $version (build $build)"
AGENTBAR_CODE_SIGN_IDENTITY="$identity" "$script_dir/build-app.sh"
mkdir -p "$out"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

echo "== Notarizing (a few minutes)"
notary=(--keychain-profile "$profile")
if [[ -n "$notary_keychain" ]]; then notary+=(--keychain "$notary_keychain"); fi
result=$(xcrun notarytool submit "$zip" "${notary[@]}" --wait 2>&1) || true
echo "$result" | tail -3
if ! echo "$result" | grep -q "status: Accepted"; then
  submission=$(echo "$result" | sed -n 's/^ *id: \([0-9a-f-]*\)$/\1/p' | head -1)
  if [[ -n "$submission" ]]; then xcrun notarytool log "$submission" "${notary[@]}" || true; fi
  echo "notarization did not succeed" >&2
  exit 1
fi
xcrun stapler staple "$app"
spctl -a -vv "$app" 2>&1 | head -2
# The zip people download carries the stapled ticket, so it opens offline too.
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
attrs=$("$sign_update" --ed-key-file "$update_key" "$zip")   # sparkle:edSignature="…" length="…"
echo "== Made $zip"

if (( ! publish )); then
  echo "Not published. Run again with --publish to release it."
  exit 0
fi

echo "== Publishing $tag"
git -C "$repo_dir" tag -a "$tag" -m "Limi $version"
git -C "$repo_dir" push origin "$tag"
# The release repository has no source. Its tag for this release is an annotated
# one on its main, dated now: every tag there points at the same commit, and
# GitHub orders releases by their tag's date. It is made as the source's tagger
# (a fresh clone has no identity of its own). The notes link to the source.
release_clone=$(mktemp -d)
git clone -q --depth 1 "https://github.com/$gh_repo.git" "$release_clone/repo"
git -C "$release_clone/repo" -c user.name="$(git -C "$repo_dir" config user.name)" \
  -c user.email="$(git -C "$repo_dir" config user.email)" tag -a "$tag" -m "Limi $version"
git -C "$release_clone/repo" push -q origin "refs/tags/$tag"
rm -rf "$release_clone"
github_notes="$out/github-notes.html"
{
  if [[ -n "$notes" ]]; then cat "$notes"; echo; fi
  echo "<p>Source code: <a href=\"https://github.com/$source_repo/tree/$tag\">$source_repo at $tag</a></p>"
} > "$github_notes"
gh release create "$tag" "$zip" --repo "$gh_repo" --verify-tag --title "Limi $version" --notes-file "$github_notes"

url="https://github.com/$gh_repo/releases/download/$tag/Limi.zip"
minimum_system=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app/Contents/Info.plist")
python3 - "$site/static/limi/appcast.xml" "$version" "$build" "$minimum_system" "$url" "$attrs" "$notes" <<'PY'
import email.utils, os, re, sys
import xml.etree.ElementTree as ET
path, short, build, minos, url, attrs, notes = sys.argv[1:8]
SP = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SP)
found = dict(re.findall(r'(sparkle:edSignature|length)="([^"]+)"', attrs))
if set(found) != {"sparkle:edSignature", "length"}:
    sys.exit("sign_update did not give a signature and a length")
if os.path.exists(path) and os.path.getsize(path) > 0:
    rss = ET.parse(path).getroot()
else:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Limi"
    ET.SubElement(channel, "link").text = "https://kalti.co.kr/limi/"
    ET.SubElement(channel, "description").text = "Limi updates"
    ET.SubElement(channel, "language").text = "en"
channel = rss.find("channel")
for old in channel.findall("item"):
    if old.findtext(f"{{{SP}}}version") == build:
        channel.remove(old)
item = ET.Element("item")
ET.SubElement(item, "title").text = f"Limi {short}"
ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
ET.SubElement(item, f"{{{SP}}}version").text = build
ET.SubElement(item, f"{{{SP}}}shortVersionString").text = short
ET.SubElement(item, f"{{{SP}}}minimumSystemVersion").text = minos
if notes:
    ET.SubElement(item, "description").text = open(notes, encoding="utf-8").read()
ET.SubElement(item, "enclosure", {
    "url": url, "length": found["length"], "type": "application/octet-stream",
    f"{{{SP}}}edSignature": found["sparkle:edSignature"]})
first = next((i for i, child in enumerate(list(channel)) if child.tag == "item"), len(channel))
channel.insert(first, item)
ET.indent(rss, space="  ")
ET.ElementTree(rss).write(path, encoding="utf-8", xml_declaration=True)
PY
echo "== Added Limi $version (build $build) to $site/static/limi/appcast.xml"
echo "Next: build, deploy and commit the site, so kalti.co.kr/limi offers the update and shows the version."
