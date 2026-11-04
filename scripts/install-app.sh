#!/bin/zsh

set -euo pipefail

require_stopped() {
  # A process can have been launched through an alias of the destination path.
  # Conservatively require every AgentBar instance to be closed.
  if pgrep -x agent-bar >/dev/null; then
    echo "AgentBar is still running; quit all AgentBar instances before installing." >&2
    return 1
  else
    local check_result=$?
    if [[ "$check_result" -ne 1 ]]; then
      echo "Could not check whether AgentBar is running; installation stopped." >&2
      return 1
    fi
  fi
}

if [[ "$#" -eq 2 && "$1" == "--check-running" ]]; then
  require_stopped "$2"
  exit
fi
if [[ "$#" -ne 2 || "$1" != /* || "$2" != /* || "${2:t}" != "AgentBar.app" ]]; then
  echo "Usage: $0 /absolute/built/AgentBar.app /absolute/destination/AgentBar.app" >&2
  exit 1
fi

source_bundle="$1"
install_path="$2"
install_dir="${install_path:h}"
if [[ ! -d "$source_bundle" || ! -x "$source_bundle/Contents/MacOS/agent-bar" || "$source_bundle" -ef "$install_path" ]]; then
  echo "The source must be a separate built AgentBar app bundle." >&2
  exit 1
fi
if [[ -L "$install_path" || ( -e "$install_path" && ! -d "$install_path" ) ]]; then
  echo "The installation destination must be an app directory, not a file or symlink." >&2
  exit 1
fi

if ! require_stopped "$install_path"; then exit 1; fi
codesign --verify --deep --strict "$source_bundle"
umask 077
mkdir -p "$install_dir"
# Keep this inode between runs: unlinking it could let a later installer lock a
# different file while another process still holds the original lock.
lock_path="$install_dir/.AgentBar.install.lock"
if [[ -L "$lock_path" || ( -e "$lock_path" && ! -f "$lock_path" ) ]]; then
  echo "The installer lock must be a regular file." >&2
  exit 1
fi
: >> "$lock_path"
zmodload zsh/system
if ! zsystem flock -t 0 -f install_lock_fd "$lock_path"; then
  echo "Another AgentBar installer is running for this destination; installation stopped." >&2
  exit 1
fi
# The descriptor remains open through rollback and cleanup. The OS releases it
# when this shell exits, including after an interrupted installation.
staging_dir=$(mktemp -d "$install_dir/.AgentBar-install.XXXXXX")
committed=0
placement_attempted=0

cleanup() {
  local result=$?
  trap - EXIT HUP INT TERM
  if [[ "$committed" -eq 0 ]]; then
    if [[ "$placement_attempted" -eq 1 && ( -e "$install_path" || -L "$install_path" ) ]]; then
      if ! mv "$install_path" "$staging_dir/failed.app"; then
        echo "Could not move the failed installation aside. Recovery files remain at: $staging_dir" >&2
        exit 1
      fi
    fi
    if [[ -d "$staging_dir/previous.app" ]]; then
      if ! mv "$staging_dir/previous.app" "$install_path"; then
        echo "Could not restore the previous app. It is preserved at: $staging_dir/previous.app" >&2
        exit 1
      fi
    fi
  fi
  rm -rf "$staging_dir"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ditto "$source_bundle" "$staging_dir/new.app"
codesign --verify --deep --strict "$staging_dir/new.app"
# Building or copying can take time. Check again immediately before replacement.
if ! require_stopped "$install_path"; then exit 1; fi
if [[ -d "$install_path" ]]; then
  mv "$install_path" "$staging_dir/previous.app"
fi
placement_attempted=1
mv "$staging_dir/new.app" "$install_path"
codesign --verify --deep --strict "$install_path"
committed=1
echo "Installed to $install_path"
