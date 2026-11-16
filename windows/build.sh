#!/bin/bash
# Builds the Windows install file: build/AgentBar-windows-x64.zip. Nothing is compiled: it is the official
# Node.js node.exe, byte for byte as its makers signed it, and AgentBar's scripts. Runs on a Mac or Linux.
set -euo pipefail
cd "$(dirname "$0")"
NODE_VERSION=26.12.1
NODE_ZIP_SHA=b3efd5c70cba3308ed46e7e699a9b8aac075bbc6b027fcb39c84c31acc25e2b4
NODE_EXE_SHA=1c63f1417e2e26d83ca9a9ec1d548524ab1305bc7209d90ebca56257ff0d84ed
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

mkdir -p build/cache
zip=build/cache/node-v$NODE_VERSION-win-x64.zip
[ -f "$zip" ] || curl -fL --retry 3 -o "$zip" "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-win-x64.zip"
[ "$(sha "$zip")" = "$NODE_ZIP_SHA" ] || { echo "the Node.js download is not the pinned one" >&2; exit 1; }

out=build/AgentBar
rm -rf "$out" build/AgentBar-windows-x64.zip
mkdir -p "$out"
unzip -q -j "$zip" "node-v$NODE_VERSION-win-x64/node.exe" "node-v$NODE_VERSION-win-x64/LICENSE" -d "$out"
mv "$out/LICENSE" "$out/NODE-LICENSE.txt"
[ "$(sha "$out/node.exe")" = "$NODE_EXE_SHA" ] || { echo "node.exe is not the pinned one" >&2; exit 1; }
cp -R app "$out/app"
cp VERSION uninstall.ps1 "$out/"
cp ../LICENSE "$out/LICENSE.txt"
node icon-file.mjs "$out/AgentBar.ico"
(cd build && zip -q -r -X AgentBar-windows-x64.zip AgentBar)
echo "build/AgentBar-windows-x64.zip $(sha build/AgentBar-windows-x64.zip)"
