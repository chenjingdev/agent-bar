#!/usr/bin/env bash
set -euo pipefail

CACHE_DIR="${HOME}/.agentbar"
STATUSLINE_CACHE="${CACHE_DIR}/claude-statusline.json"
TMP_INPUT="$(mktemp "${TMPDIR:-/tmp}/agent-bar-statusline.XXXXXX")"
trap 'rm -f "$TMP_INPUT"' EXIT

cat >"$TMP_INPUT"

if [ -s "$TMP_INPUT" ]; then
  mkdir -p "$CACHE_DIR"
  cp "$TMP_INPUT" "${STATUSLINE_CACHE}.tmp"
  mv "${STATUSLINE_CACHE}.tmp" "$STATUSLINE_CACHE"
fi

resolve_node() {
  local candidate
  candidate="$(command -v node 2>/dev/null || true)"
  for candidate in \
    "$candidate" \
    /opt/homebrew/bin/node \
    /usr/local/bin/node \
    /usr/bin/node
  do
    if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

resolve_hud_script() {
  local candidate
  local latest_dir

  candidate="${HOME}/.claude/plugins/marketplaces/claude-hud/dist/index.js"
  if [ -f "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  latest_dir="$(
    ls -d "${HOME}"/.claude/plugins/cache/claude-hud/claude-hud/*/ 2>/dev/null \
      | awk -F/ '{ print $(NF-1) "\t" $0 }' \
      | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
      | tail -1 \
      | cut -f2- \
      || true
  )"

  if [ -n "$latest_dir" ] && [ -f "${latest_dir}dist/index.js" ]; then
    printf '%s\n' "${latest_dir}dist/index.js"
    return 0
  fi

  return 1
}

NODE_BIN="$(resolve_node || true)"
HUD_SCRIPT="$(resolve_hud_script || true)"

if [ -z "$NODE_BIN" ] || [ -z "$HUD_SCRIPT" ]; then
  exit 0
fi

"$NODE_BIN" "$HUD_SCRIPT" <"$TMP_INPUT"
