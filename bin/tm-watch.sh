#!/usr/bin/env bash
# tmux-master: capture a worker's pane buffer.
# Usage: tm-watch.sh <name> [--lines N]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_registry.sh
source "$SCRIPT_DIR/_registry.sh"

_tm_require tmux jq

lines=60
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lines)   lines="$2"; shift 2 ;;
    -h|--help) echo "tm-watch <name> [--lines N]" >&2; exit 2 ;;
    *)         args+=("$1"); shift ;;
  esac
done

[[ ${#args[@]} -eq 1 ]] || { echo "tm-watch <name>" >&2; exit 2; }
name="${args[0]}"

_tm_init_registry
_tm_worker_exists "$name" || { echo "no such worker: $name" >&2; exit 1; }
_tm_session_alive "$name" || { echo "worker '$name' session is not alive" >&2; exit 1; }

tmux capture-pane -pt "$(_tm_target "$name")" -S "-$lines"
