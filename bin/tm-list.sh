#!/usr/bin/env bash
# tmux-master: list all registered workers with liveness.
# Usage: tm-list.sh [--json]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_registry.sh
source "$SCRIPT_DIR/_registry.sh"

_tm_require tmux jq

as_json=false
[[ "${1:-}" == "--json" ]] && as_json=true

_tm_init_registry

if $as_json; then
  jq '.' "$TM_REGISTRY"
  exit 0
fi

if ! jq -e '.workers | length > 0' "$TM_REGISTRY" >/dev/null; then
  echo "no workers registered."
  echo "(registry: $TM_REGISTRY)"
  exit 0
fi

printf "%-20s %-6s %-5s %-19s %s\n" NAME KIND ALIVE CREATED CWD
printf "%-20s %-6s %-5s %-19s %s\n" ---- ---- ----- ------- ---

while IFS= read -r n; do
  [[ -z "$n" ]] && continue
  kind=$(_tm_worker_field "$n" kind)
  created=$(_tm_worker_field "$n" created_at | cut -c1-19)
  cwd=$(_tm_worker_field "$n" cwd)
  if _tm_session_alive "$n"; then alive=yes; else alive=no; fi
  printf "%-20s %-6s %-5s %-19s %s\n" "$n" "$kind" "$alive" "$created" "$cwd"
done < <(jq -r '.workers | keys[]' "$TM_REGISTRY")

echo
echo "attach individual worker: tmux attach -t <name>"
