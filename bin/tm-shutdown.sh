#!/usr/bin/env bash
# tmux-master: close every registered worker (kills each worker's tmux session).
# Usage: tm-shutdown.sh [--force]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_registry.sh
source "$SCRIPT_DIR/_registry.sh"

_tm_require tmux jq

force=false
[[ "${1:-}" == "--force" ]] && force=true

_tm_init_registry

names=""
if jq -e '.workers | length > 0' "$TM_REGISTRY" >/dev/null 2>&1; then
  names=$(jq -r '.workers | keys[]' "$TM_REGISTRY")
fi

while IFS= read -r n; do
  [[ -z "$n" ]] && continue
  if $force; then
    "$SCRIPT_DIR/tm-close.sh" "$n" --force || true
  else
    "$SCRIPT_DIR/tm-close.sh" "$n" || true
  fi
done <<< "$names"

_tm_lock
printf '{"workers":{}}\n' > "$TM_REGISTRY"
_tm_unlock

echo "tmux-master: all registered workers closed."
