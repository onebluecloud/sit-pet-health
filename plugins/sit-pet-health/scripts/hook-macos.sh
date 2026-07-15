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
enhancement_required=false
if [[ -f "$plugin_data/current-pet.json" ]]; then
  current_before=$(/usr/bin/shasum -a 256 "$plugin_data/current-pet.json" | /usr/bin/awk '{print $1}')
fi
if ! event_name=$(print -rn -- "$payload" | /usr/bin/osascript -l JavaScript "$plugin_root/scripts/hook-event-macos.js" "$plugin_data"); then
  print '{"systemMessage":"Codex pet health could not record the lifecycle event."}'
  exit 0
fi

if [[ "$event_name" == "SessionStart" || ! -f "$plugin_data/current-pet.json" ]]; then
  if ! prepare_output=$(/bin/zsh "$plugin_root/scripts/prepare-pet-macos.sh" "$plugin_data"); then
    print '{"systemMessage":"No Codex pet was found. Ask the user for either a one-sentence pet description or a reference image. Then follow the installed upgrade-codex-pet-health Skill and its bundled hatch-pet workflow, package only into CLAUDE_PLUGIN_DATA/custom-sources, prepare the private health clone, and launch it immediately. Do not modify CODEX_HOME/pets."}'
    exit 0
  fi
  if [[ "$prepare_output" == *'"enhancementRequired":true'* ]]; then
    enhancement_required=true
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
if [[ "$enhancement_required" == "true" ]]; then
  print '{"systemMessage":"RousePet is already visible with safe fallback actions. Follow the installed upgrade-codex-pet-health Skill to generate the missing tired, sick, and rest animations inside the private clone, visually approve the contact sheet, and atomically activate the extension. Never modify the official pet."}'
fi
