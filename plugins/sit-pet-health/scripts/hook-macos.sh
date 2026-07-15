#!/bin/zsh
set -euo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-${0:A:h:h}}}"
plugin_data="${CLAUDE_PLUGIN_DATA:-${PLUGIN_DATA:-}}"
if [[ -z "$plugin_data" ]]; then
  print '{"systemMessage":"Codex pet health could not start: CLAUDE_PLUGIN_DATA is missing."}'
  exit 0
fi

payload=$(/bin/cat)
current_before=""
if [[ -f "$plugin_data/current-pet.json" ]]; then
  current_before=$(/usr/bin/shasum -a 256 "$plugin_data/current-pet.json" | /usr/bin/awk '{print $1}')
fi
if ! event_name=$(print -rn -- "$payload" | /usr/bin/osascript -l JavaScript "$plugin_root/scripts/hook-event-macos.js" "$plugin_data"); then
  print '{"systemMessage":"Codex pet health could not record the lifecycle event."}'
  exit 0
fi

if [[ "$event_name" == "SessionStart" || ! -f "$plugin_data/current-pet.json" ]]; then
  if ! /bin/zsh "$plugin_root/scripts/prepare-pet-macos.sh" "$plugin_data" >/dev/null; then
    print '{"systemMessage":"Codex pet health could not prepare a read-only pet clone."}'
    exit 0
  fi
fi

current_after=$(/usr/bin/shasum -a 256 "$plugin_data/current-pet.json" | /usr/bin/awk '{print $1}')
if [[ -n "$current_before" && "$current_before" != "$current_after" && -f "$plugin_data/runtime.pid" ]]; then
  pid=$(/usr/bin/sed -nE 's/.*"pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$plugin_data/runtime.pid" | /usr/bin/head -1)
  if [[ -n "$pid" ]] && /bin/kill -0 "$pid" 2>/dev/null; then
    command_line=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
    if [[ "$command_line" == *"runtime-macos.js"* && "$command_line" == *"$plugin_data"* ]]; then
      /bin/kill "$pid" 2>/dev/null || true
      for _ in {1..30}; do
        /bin/kill -0 "$pid" 2>/dev/null || break
        /bin/sleep 0.1
      done
    fi
  fi
fi

/usr/bin/nohup /bin/zsh "$plugin_root/scripts/runtime-macos.sh" "$plugin_root" "$plugin_data" >/dev/null 2>&1 &!
