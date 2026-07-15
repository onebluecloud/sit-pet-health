#!/bin/zsh
set -euo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-${0:A:h:h}}}"
plugin_data="${1:-${CLAUDE_PLUGIN_DATA:-${PLUGIN_DATA:-}}}"
source_pet="${2:-}"
source_directory="${3:-}"

if [[ -z "$plugin_data" ]]; then
  print -u2 'CLAUDE_PLUGIN_DATA is required.'
  exit 1
fi

/usr/bin/osascript -l JavaScript "$plugin_root/scripts/prepare-pet-macos.js" "$plugin_data" "$source_pet" "$source_directory" "$plugin_root"
