#!/bin/zsh
set -euo pipefail

package_root="${1:-${0:A:h:h}}"
skip_launch="${2:-}"

# Restore Codex UI metadata from RED Skill upload-safe text carriers.
while IFS= read -r -d '' yaml_txt; do
  /bin/cp -f "$yaml_txt" "${yaml_txt%.txt}"
done < <(/usr/bin/find "$package_root" -type f -name '*.yaml.txt' -print0)

if ! command -v codex >/dev/null 2>&1; then
  print -u2 'Codex Desktop/CLI is required. This package does not install a separate app.'
  exit 1
fi

if [[ ! -f "$package_root/.agents/plugins/marketplace.json" ]]; then
  print -u2 "Invalid RedSkill package: missing .agents/plugins/marketplace.json"
  exit 1
fi

market_json="$(codex plugin marketplace add "$package_root" --json)"
marketplace_name="$(print -r -- "$market_json" | /usr/bin/sed -n 's/.*"marketplaceName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[[ -n "$marketplace_name" ]] || { print -u2 'Could not read marketplace name.'; exit 1; }

install_json="$(codex plugin add "sit-pet-health@$marketplace_name" --json)"
installed_path="$(print -r -- "$install_json" | /usr/bin/sed -n 's/.*"installedPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[[ -n "$installed_path" ]] || { print -u2 'Could not read installed plugin path.'; exit 1; }

launched=false
if [[ "$skip_launch" != "--skip-launch" ]]; then
  /bin/zsh "$installed_path/scripts/launch-macos.sh" "$installed_path"
  launched=true
fi

print "{\"ok\":true,\"marketplace\":\"$marketplace_name\",\"installedPath\":\"$installed_path\",\"launched\":$launched}"
