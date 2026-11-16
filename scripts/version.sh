#!/bin/zsh
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
build_number=$(git -C "$repo_dir" rev-list --count HEAD)
case "${1:-}" in
  --build) echo "$build_number" ;;
  "") echo "$(<"$repo_dir/VERSION").$build_number" ;;
  *) echo "Usage: $0 [--build]" >&2; exit 1 ;;
esac
