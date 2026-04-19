#!/usr/bin/env bash
# tmux-master: kill a worker's session (terminates the CLI) and deregister.
# Usage: tm-close.sh <name> [--force]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_registry.sh
source "$SCRIPT_DIR/_registry.sh"

_tm_require tmux jq

force=false
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   force=true; shift ;;
    -h|--help) echo "tm-close <name> [--force]" >&2; exit 2 ;;
    *)         args+=("$1"); shift ;;
  esac
done

[[ ${#args[@]} -eq 1 ]] || { echo "tm-close <name>" >&2; exit 2; }
name="${args[0]}"

_tm_init_registry
_tm_worker_exists "$name" || { echo "no such worker: $name" >&2; exit 1; }

target=$(_tm_target "$name")

if _tm_session_alive "$name"; then
  if ! $force; then
    # Graceful: interrupt any running command, then EOF the shell/CLI.
    tmux send-keys -t "$target" C-c 2>/dev/null || true
    sleep 0.5
    tmux send-keys -t "$target" C-d 2>/dev/null || true
    sleep 2
  fi
  # Kill the session regardless — takes the CLI process with it.
  if _tm_session_alive "$name"; then
    tmux kill-session -t "$name" 2>/dev/null || true
  fi
fi

_tm_lock
new=$(jq --arg n "$name" 'del(.workers[$n])' "$TM_REGISTRY")
_tm_reg_write "$new"
_tm_unlock

echo "closed worker '$name' (session '$name' killed)"
