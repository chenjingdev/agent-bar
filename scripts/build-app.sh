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

cp "$binary_path" "$bundle_path/Contents/MacOS/agent-bar"

cat > "$bundle_path/Contents/Info.plist" <<'PLIST'
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
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
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

codesign --force --deep -s - "$bundle_path" >/dev/null

if [[ "$should_install" -eq 1 ]]; then
  mkdir -p "$install_dir"
  rm -rf "$install_path"
  cp -R "$bundle_path" "$install_path"
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
