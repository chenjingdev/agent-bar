#!/bin/zsh
# Releases AgentBar from this Mac to https://github.com/chenjingdev-archive/agent-bar/releases:
#
#   1. builds AgentBar.app signed with the Developer ID in this Mac's keychain
#      (hardened runtime, secure timestamp; scripts/build-app.sh);
#   2. has Apple notarize it and staples the ticket to the app;
#   3. zips it and writes appcast.xml, both signed with AgentBar's Sparkle key
#      (the keychain item of account dev.chenjing.agent-bar, never printed), so
#      every installed AgentBar takes it from releases/latest/download/appcast.xml
#      (older ones ask chenjingdev/agent-bar, which GitHub sends here);
#   4. tags v<version>, pushes main and the tag to the agent-bar repository and
#      publishes the release with the zip, appcast.xml and SHA256SUMS.txt.
#
# Notarization uses an App Store Connect API key, given by
#   AGENTBAR_NOTARY_KEY        path to AuthKey_<id>.p8
#   AGENTBAR_NOTARY_KEY_ID     its key ID
#   AGENTBAR_NOTARY_ISSUER     its issuer ID
# or a notarytool keychain profile in AGENTBAR_NOTARY_PROFILE.
# AGENTBAR_REMOTE names the git remote of chenjingdev-archive/agent-bar (default agentbar).

set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_dir"
gh_repo="chenjingdev-archive/agent-bar"
remote="${AGENTBAR_REMOTE:-agentbar}"
sparkle_account="dev.chenjing.agent-bar"
sparkle_bin="$repo_dir/.build/vendor/Sparkle-2.10.1/bin"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit first: the release is built from HEAD." >&2; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || { echo "Release from main." >&2; exit 1; }

if [[ -n "${AGENTBAR_NOTARY_PROFILE:-}" ]]; then
  notary=(--keychain-profile "$AGENTBAR_NOTARY_PROFILE")
else
  : "${AGENTBAR_NOTARY_KEY:?Set AGENTBAR_NOTARY_KEY, _KEY_ID and _ISSUER, or AGENTBAR_NOTARY_PROFILE.}"
  notary=(--key "$AGENTBAR_NOTARY_KEY" --key-id "${AGENTBAR_NOTARY_KEY_ID:?}" --issuer "${AGENTBAR_NOTARY_ISSUER:?}")
fi

./scripts/build-app.sh
app="$repo_dir/AgentBar.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
tag="v$version"
codesign -dv "$app" 2>&1 | grep -q "Authority=Developer ID Application" \
  || { echo "AgentBar.app is not signed with a Developer ID." >&2; exit 1; }

output="$repo_dir/work/release"
rm -rf "$output"; mkdir -p "$output"
archive="AgentBar-$tag-macos-arm64.zip"

echo "== Notarizing $version"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/notarize.zip"
xcrun notarytool submit "$output/notarize.zip" "${notary[@]}" --wait
rm "$output/notarize.zip"
xcrun stapler staple "$app"
spctl --assess --type execute -vv "$app"

echo "== Packaging and signing the update feed"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
"$sparkle_bin/generate_appcast" --account "$sparkle_account" --maximum-deltas 0 \
  --download-url-prefix "https://github.com/$gh_repo/releases/download/$tag/" \
  --link "https://github.com/$gh_repo" "$output"
"$sparkle_bin/sign_update" --account "$sparkle_account" --verify "$output/appcast.xml"
(cd "$output" && shasum -a 256 "$archive" appcast.xml > SHA256SUMS.txt)

echo "== Publishing $tag"
git tag -a "$tag" -m "AgentBar $version"
git push "$remote" main "$tag"
gh release create "$tag" -R "$gh_repo" "$output/$archive" "$output/appcast.xml" "$output/SHA256SUMS.txt" \
  --title "AgentBar $version" --generate-notes --latest
echo "Released https://github.com/$gh_repo/releases/tag/$tag"
