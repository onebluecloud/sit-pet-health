#!/bin/zsh
set -euo pipefail

plugin_root="${1:-${0:A:h:h}}"
plugin_data="${2:-}"
if [[ -z "$plugin_data" ]]; then
  version_directory="$plugin_root"
  plugin_directory="${version_directory:h}"
  marketplace_directory="${plugin_directory:h}"
  cache_directory="${marketplace_directory:h}"
  plugins_directory="${cache_directory:h}"
  if [[ "${cache_directory:t}" != "cache" || "${plugins_directory:t}" != "plugins" ]]; then
    print -u2 'Plugin data is required when launching outside an installed Codex plugin cache.'
    exit 1
  fi
  plugin_data="$plugins_directory/data/${plugin_directory:t}-${marketplace_directory:t}"
  export CODEX_HOME="${CODEX_HOME:-${plugins_directory:h}}"
fi

export CLAUDE_PLUGIN_ROOT="$plugin_root"
export CLAUDE_PLUGIN_DATA="$plugin_data"
print -rn -- '{"hook_event_name":"SessionStart","session_id":""}' | /bin/zsh "$plugin_root/scripts/hook-macos.sh"
for _ in {1..20}; do
  [[ -f "$plugin_data/runtime.pid" ]] && break
  /bin/sleep 0.1
done
print "{\"ok\":$([[ -f "$plugin_data/runtime.pid" ]] && print true || print false),\"pluginData\":\"$plugin_data\"}"
