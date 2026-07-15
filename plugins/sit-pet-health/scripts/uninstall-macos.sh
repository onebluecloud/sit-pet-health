#!/bin/zsh
set -euo pipefail

plugin_data="${1:-${CLAUDE_PLUGIN_DATA:-}}"
if [[ -z "$plugin_data" || "$plugin_data" != /* || "$plugin_data" == "/" || "${plugin_data:t}" != sit-pet-health-* ]]; then
  print -u2 'Refusing to remove a directory that is not a sit-pet-health plugin data root.'
  exit 1
fi
if [[ -L "$plugin_data" ]]; then
  print -u2 'Refusing to remove a symlink plugin data directory.'
  exit 1
fi

pid_file="$plugin_data/runtime.pid"
if [[ -f "$pid_file" ]]; then
  pid=$(/usr/bin/sed -nE 's/.*"pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$pid_file" | /usr/bin/head -1)
  if [[ -n "$pid" ]] && /bin/kill -0 "$pid" 2>/dev/null; then
    command_line=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
    if [[ "$command_line" == *"runtime-macos.js"* && "$command_line" == *"$plugin_data"* ]]; then
      /bin/kill "$pid" 2>/dev/null || true
    fi
  fi
fi
/bin/rm -rf -- "$plugin_data"
print "{\"ok\":$([[ ! -e "$plugin_data" ]] && print true || print false),\"removedPluginData\":\"$plugin_data\"}"
