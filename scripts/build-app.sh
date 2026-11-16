#!/bin/zsh

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)

# The app's name people see: the .app, Finder, Login Items, the Settings
# title and every sentence that names the app (AppInfo.name reads it from the
# bundle). Change it here, or with AGENTBAR_APP_NAME, to rename the app.
# Internal names (bundle ID, ~/.agentbar data, agent-bar module) stay fixed so a
# rename keeps settings and accounts.
app_name="${AGENTBAR_APP_NAME:-Limi}"
# The version people see, and the build number Sparkle compares to offer an
# update: raise app_build with every release. scripts/release.sh reads both here.
app_version="1.4.2"
app_build="12"
bundle_id="kr.co.kalti.limi"
bundle_name="$app_name.app"
bundle_path="$repo_dir/$bundle_name"
install_dir="$HOME/Applications"
install_path="$install_dir/$bundle_name"
build_configuration="release"
should_install=0
# A Developer ID ("Developer ID Application: Name (TEAMID)") signs a release:
# the hardened runtime and a secure timestamp, ready for notarization. Any other
# identity signs as given; none means ad-hoc, for building on your own Mac.
signing_identity="${AGENTBAR_CODE_SIGN_IDENTITY:-}"
# Automatic updates (Sparkle, Sources/agent-bar/App/Updates.swift). Sparkle is
# fetched once into .build/vendor and used only if it is the archive checked
# below. Info.plist gets the feed and the public key updates must be signed with
# (scripts/update-public-key.txt, made once by scripts/make-update-key.swift).
sparkle_version="2.10.1"
sparkle_sha256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
sparkle_dir="${AGENTBAR_VENDOR_DIR:-$repo_dir/.build/vendor}/Sparkle-$sparkle_version"
sparkle_feed="${AGENTBAR_SPARKLE_FEED:-https://kalti.co.kr/limi/appcast.xml}"
update_key_file="$repo_dir/scripts/update-public-key.txt"
usage="Usage: ./scripts/build-app.sh [--install]
  --install                    also install to ~/Applications (the running app must be closed)
  AGENTBAR_CODE_SIGN_IDENTITY  sign with this identity; a Developer ID makes a release build
  AGENTBAR_APP_NAME            the app's name (default Limi)
Releases (sign, notarize, publish): scripts/release.sh"

while (( $# > 0 )); do
  case "$1" in
    --install)
      should_install=1
      ;;
    -h|--help)
      echo "$usage"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "$usage" >&2
      exit 1
      ;;
  esac
  shift
done

fetch_sparkle() {
  [[ -d "$sparkle_dir/Sparkle.framework" ]] && return 0
  local tmp
  tmp=$(mktemp -d)
  echo "Fetching Sparkle $sparkle_version..."
  curl -fsSL -o "$tmp/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
  if ! echo "$sparkle_sha256  $tmp/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null; then
    echo "Sparkle $sparkle_version download does not match its SHA-256" >&2
    rm -rf "$tmp"
    exit 1
  fi
  mkdir -p "$sparkle_dir"
  tar -xJf "$tmp/sparkle.tar.xz" -C "$sparkle_dir"
  rm -rf "$tmp"
}
fetch_sparkle

echo "Building agent-bar ($build_configuration)..."
swift build -c "$build_configuration" --product agent-bar \
  -Xswiftc -F -Xswiftc "$sparkle_dir" \
  -Xlinker -F -Xlinker "$sparkle_dir" \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks

bin_dir=$(swift build -c "$build_configuration" --show-bin-path)
binary_path="$bin_dir/agent-bar"

if [[ ! -x "$binary_path" ]]; then
  echo "Built binary not found: $binary_path" >&2
  exit 1
fi

echo "Creating app bundle at $bundle_path"
rm -rf "$bundle_path"
mkdir -p "$bundle_path/Contents/MacOS"
mkdir -p "$bundle_path/Contents/Resources"
mkdir -p "$bundle_path/Contents/Frameworks"

cp "$binary_path" "$bundle_path/Contents/MacOS/agent-bar"
# App icon; regenerate with scripts/make-app-icons.sh.
cp "$repo_dir/assets/AppIcon.icns" "$bundle_path/Contents/Resources/AppIcon.icns"
# Korean UI; English is the text in the code. See assets/ko.lproj.
cp -R "$repo_dir/assets/ko.lproj" "$bundle_path/Contents/Resources/ko.lproj"
mkdir -p "$bundle_path/Contents/Resources/en.lproj"
ditto "$sparkle_dir/Sparkle.framework" "$bundle_path/Contents/Frameworks/Sparkle.framework"

cat > "$bundle_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>ko</string>
  </array>
  <key>CFBundleDisplayName</key>
  <string>APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>agent-bar</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# The placeholders above come from the settings at the top.
info_plist="$bundle_path/Contents/Info.plist"
plutil -replace CFBundleName -string "$app_name" "$info_plist"
plutil -replace CFBundleDisplayName -string "$app_name" "$info_plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$info_plist"
plutil -replace CFBundleShortVersionString -string "$app_version" "$info_plist"
plutil -replace CFBundleVersion -string "$app_build" "$info_plist"
# Antigravity's local language server answers plain HTTP on 127.0.0.1.
plutil -insert NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true}' "$info_plist"
# Sparkle: where to look for updates (once a day, without asking first) and the
# key every update must be signed with.
if [[ -s "$update_key_file" ]]; then
  plutil -insert SUFeedURL -string "$sparkle_feed" "$info_plist"
  plutil -insert SUPublicEDKey -string "$(tr -d '[:space:]' < "$update_key_file")" "$info_plist"
  plutil -insert SUEnableAutomaticChecks -bool true "$info_plist"
  plutil -insert SUScheduledCheckInterval -integer 86400 "$info_plist"
else
  echo "note: no $update_key_file, so this build does not update itself" >&2
fi

printf 'APPL????' > "$bundle_path/Contents/PkgInfo"

if [[ "$signing_identity" == "Developer ID Application:"* ]]; then
  echo "Signing with: $signing_identity (hardened runtime, secure timestamp)"
  sign=(codesign --force --timestamp --options runtime -s "$signing_identity")
  # Sparkle's helpers are signed inside out, then the framework, then the app
  # that seals them (Sparkle's documented order).
  framework="$bundle_path/Contents/Frameworks/Sparkle.framework"
  "${sign[@]}" "$framework/Versions/B/XPCServices/Installer.xpc" >/dev/null
  "${sign[@]}" --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc" >/dev/null
  "${sign[@]}" "$framework/Versions/B/Autoupdate" >/dev/null
  "${sign[@]}" "$framework/Versions/B/Updater.app" >/dev/null
  "${sign[@]}" "$framework" >/dev/null
  "${sign[@]}" "$bundle_path" >/dev/null
else
  if [[ -z "$signing_identity" ]]; then signing_identity="-"; fi
  echo "Signing with: $signing_identity"
  codesign --force --deep -s "$signing_identity" "$bundle_path" >/dev/null
fi
codesign --verify --deep --strict "$bundle_path"

if [[ "$should_install" -eq 1 ]]; then
  umask 077
  mkdir -p "$install_dir"
  backup_dir="$HOME/Library/Application Support/AgentBar/Backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  if [[ -d "$install_path" ]]; then
    ditto "$install_path" "$backup_dir/$bundle_name"
  fi
  defaults export "$bundle_id" "$backup_dir/settings.plist" >/dev/null 2>&1 || true
  if [[ -d "$HOME/.agentbar/multi-account-v1" ]]; then
    ditto "$HOME/.agentbar/multi-account-v1" "$backup_dir/multi-account-v1"
  fi
  staging_dir=$(mktemp -d "$install_dir/.AgentBar-install.XXXXXX")
  ditto "$bundle_path" "$staging_dir/new.app"
  codesign --verify --deep --strict "$staging_dir/new.app"
  if [[ -d "$install_path" ]]; then
    # The installer requires the running app to be closed before replacement.
    if pgrep -f "^$install_path/Contents/MacOS/agent-bar$" >/dev/null; then
      echo "$app_name is still running; installation stopped. Backup: $backup_dir" >&2
      exit 1
    fi
    mv "$install_path" "$staging_dir/previous.app"
  fi
  if ! mv "$staging_dir/new.app" "$install_path"; then
    if [[ -d "$staging_dir/previous.app" ]]; then mv "$staging_dir/previous.app" "$install_path"; fi
    echo "Installation failed; previous app restored. Backup: $backup_dir" >&2
    exit 1
  fi
  rm -rf "$staging_dir"
  echo "Backup: $backup_dir"
  echo "Installed to $install_path"
else
  echo "Built $bundle_path"
fi

echo "You can launch it with:"
if [[ "$should_install" -eq 1 ]]; then
  echo "open \"$install_path\""
else
  echo "open \"$bundle_path\""
fi
