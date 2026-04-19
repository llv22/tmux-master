#!/usr/bin/env bash
# tmux-master: block until a worker looks idle (marker match + buffer stable).
# Usage: tm-wait-idle.sh <name> [--timeout N] [--poll N] [--markers "a,b,c"]
#                       [--stable-polls N]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_registry.sh
source "$SCRIPT_DIR/_registry.sh"

_tm_require tmux jq shasum

timeout=600
poll=3
markers=""
stable_polls=2

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)      timeout="$2"; shift 2 ;;
    --poll)         poll="$2"; shift 2 ;;
    --markers)      markers="$2"; shift 2 ;;
    --stable-polls) stable_polls="$2"; shift 2 ;;
    -h|--help)
      echo "tm-wait-idle <name> [--timeout N] [--poll N] [--markers 'a,b'] [--stable-polls N]" >&2
      exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

[[ ${#args[@]} -eq 1 ]] || { echo "tm-wait-idle <name>" >&2; exit 2; }
name="${args[0]}"

_tm_init_registry
_tm_worker_exists "$name" || { echo "no such worker: $name" >&2; exit 1; }

kind=$(_tm_worker_field "$name" kind)
if [[ -z "$markers" ]]; then
  # NB: tmux capture-pane strips trailing whitespace; markers must not end in space.
  case "$kind" in
    cc)    markers="❯,Razzle-dazzling,Cooked for,Thundering" ;;
    codex) markers="codex>,▌" ;;
    bash)  markers="\$,#" ;;
    *)     markers="\$" ;;
  esac
fi

target=$(_tm_target "$name")
elapsed=0
last_hash=""
stable_count=0

while [[ $elapsed -lt $timeout ]]; do
  if ! _tm_session_alive "$name"; then
    echo "worker '$name' session died" >&2
    exit 1
  fi

  buf=$(tmux capture-pane -pt "$target" -S -40)
  last_line=$(printf '%s\n' "$buf" | awk 'NF {last=$0} END {print last}')
  buf_hash=$(printf '%s' "$buf" | shasum | awk '{print $1}')

  marker_hit=false
  IFS=',' read -ra MARR <<< "$markers"
  for m in "${MARR[@]}"; do
    [[ -n "$m" && "$last_line" == *"$m"* ]] && { marker_hit=true; break; }
  done

  if $marker_hit && [[ "$buf_hash" == "$last_hash" ]]; then
    stable_count=$((stable_count + 1))
    if [[ $stable_count -ge $stable_polls ]]; then
      printf '%s\n' "$buf"
      echo "---" >&2
      echo "idle: marker matched + stable for ${stable_count} poll(s)" >&2
      exit 0
    fi
  elif $marker_hit; then
    stable_count=1
  else
    stable_count=0
  fi

  last_hash="$buf_hash"
  sleep "$poll"
  elapsed=$((elapsed + poll))
done

tmux capture-pane -pt "$target" -S -60
echo "---" >&2
echo "idle: TIMEOUT after ${timeout}s (worker still running)" >&2
exit 124
