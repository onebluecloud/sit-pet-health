#!/bin/zsh
set -euo pipefail

plugin_root="${1:?plugin root is required}"
plugin_data="${2:?plugin data is required}"
if [[ "$plugin_data" != /* || "$plugin_data" == "/" ]]; then
  print -u2 'plugin data must be a non-root absolute path'
  exit 1
fi
lock_dir="$plugin_data/runtime.lock"
pid_file="$plugin_data/runtime.pid"

mkdir -p "$plugin_data"
if ! mkdir "$lock_dir" 2>/dev/null; then
  if [[ -f "$pid_file" ]]; then
    pid=$(/usr/bin/sed -nE 's/.*"pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$pid_file" | /usr/bin/head -1)
    if [[ -n "$pid" ]] && /bin/kill -0 "$pid" 2>/dev/null; then
      command_line=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
      if [[ "$command_line" == *"runtime-macos.js"* && "$command_line" == *"$plugin_data"* ]]; then
        exit 0
      fi
    fi
  fi
  rm -rf -- "$lock_dir"
  mkdir "$lock_dir"
fi

cleanup() {
  rm -f "$pid_file"
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

/usr/bin/osascript -l JavaScript "$plugin_root/scripts/runtime-macos.js" "$plugin_root" "$plugin_data"
