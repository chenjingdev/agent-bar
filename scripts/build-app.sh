#!/bin/zsh

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$script_dir/.." && pwd)

bundle_name="AgentBar.app"
bundle_path="$repo_dir/$bundle_name"
install_dir="$HOME/Applications"
install_path="$install_dir/$bundle_name"
build_configuration="release"
should_install=0
signing_identity="${AGENTBAR_CODE_SIGN_IDENTITY:-}"
app_version="${AGENTBAR_VERSION:-$("$script_dir/version.sh")}"
build_number="${AGENTBAR_BUILD_NUMBER:-$("$script_dir/version.sh" --build)}"
public_update_key=$(<"$repo_dir/config/sparkle-public-key.txt")

for arg in "$@"; do
  case "$arg" in
    --install)
      should_install=1
      ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: ./scripts/build-app.sh [--install]" >&2
      exit 1
      ;;
  esac
done

if [[ "$should_install" -eq 1 ]]; then
  "$script_dir/install-app.sh" --check-running "$install_path"
fi

echo "Building agent-bar ($build_configuration)..."
swift build -c "$build_configuration" --product agent-bar

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
framework_path="$repo_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$framework_path" "$bundle_path/Contents/Frameworks/Sparkle.framework"

cat > "$bundle_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>AgentBar</string>
  <key>CFBundleExecutable</key>
  <string>agent-bar</string>
  <key>CFBundleIdentifier</key>
  <string>dev.chenjing.agent-bar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AgentBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$app_version</string>
  <key>CFBundleVersion</key>
  <string>$build_number</string>
  <key>SUFeedURL</key>
  <string>https://github.com/chenjingdev/agent-bar/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>$public_update_key</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>3600</integer>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$bundle_path/Contents/PkgInfo"

if [[ -z "$signing_identity" ]]; then
  for candidate in "FreshRestart Local Code Signing" "Screen Translate Local Code Signing"; do
    if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$candidate\""; then
      signing_identity="$candidate"
      break
    fi
  done
fi
if [[ -z "$signing_identity" ]]; then signing_identity="-"; fi
echo "Signing with: $signing_identity"
sign_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
  sign_options+=(--options runtime --timestamp)
fi
framework="$bundle_path/Contents/Frameworks/Sparkle.framework"
codesign "${sign_options[@]}" "$framework/Versions/B/XPCServices/Installer.xpc"
codesign "${sign_options[@]}" --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
codesign "${sign_options[@]}" "$framework/Versions/B/Autoupdate"
codesign "${sign_options[@]}" "$framework/Versions/B/Updater.app"
codesign "${sign_options[@]}" "$framework"
codesign "${sign_options[@]}" "$bundle_path"
codesign --verify --deep --strict "$bundle_path"

if [[ "$should_install" -eq 1 ]]; then
  "$script_dir/install-app.sh" "$bundle_path" "$install_path"
else
  echo "Built $bundle_path"
fi

echo "You can launch it with:"
if [[ "$should_install" -eq 1 ]]; then
  echo "open \"$install_path\""
else
  echo "open \"$bundle_path\""
fi
