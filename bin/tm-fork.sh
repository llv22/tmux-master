#!/usr/bin/env bash
# tmux-master: fork a worker as its own tmux session (session name == worker).
# Usage: tm-fork.sh <kind> <name> [cwd] [--cmd <cmd>] [--notes <text>] [--replace]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_registry.sh
source "$SCRIPT_DIR/_registry.sh"

_tm_require tmux jq

usage() {
  cat >&2 <<'EOF'
tm-fork <kind> <name> [cwd] [--cmd <cmd>] [--notes <text>] [--replace]
  kind:    cc | codex | bash | custom
  name:    [A-Za-z0-9_-]+ (also becomes the tmux session name)
  cwd:     defaults to $PWD
  --cmd:   override the default command for the kind
  --notes: free-form string stored in registry
  --replace: close an existing worker of the same name first
EOF
  exit 2
}

kind=""
name=""
cwd="$PWD"
cmd_override=""
notes=""
replace=false

positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cmd)     cmd_override="$2"; shift 2 ;;
    --notes)   notes="$2"; shift 2 ;;
    --replace) replace=true; shift ;;
    -h|--help) usage ;;
    --*)       echo "unknown flag: $1" >&2; usage ;;
    *)         positional+=("$1"); shift ;;
  esac
done

[[ ${#positional[@]} -ge 2 ]] || usage
kind="${positional[0]}"
name="${positional[1]}"
[[ ${#positional[@]} -ge 3 ]] && cwd="${positional[2]}"

[[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] \
  || { echo "worker name must match [A-Za-z0-9_-]+" >&2; exit 2; }

cwd="$(cd "$cwd" 2>/dev/null && pwd)" \
  || { echo "cwd not found: $cwd" >&2; exit 2; }

case "$kind" in
  cc)     cmd="${cmd_override:-$TM_CLAUDE_DEFAULT}" ;;
  codex)  cmd="${cmd_override:-$TM_CODEX_DEFAULT}" ;;
  bash)   cmd="${cmd_override:-bash -l}" ;;
  custom) [[ -n "$cmd_override" ]] \
           || { echo "kind=custom requires --cmd" >&2; exit 2; }
          cmd="$cmd_override" ;;
  *) echo "unknown kind: $kind" >&2; usage ;;
esac

_tm_init_registry
_tm_lock

if _tm_worker_exists "$name"; then
  if $replace; then
    _tm_unlock
    "$SCRIPT_DIR/tm-close.sh" "$name" --force || true
    _tm_lock
  else
    echo "worker '$name' already registered (use --replace to recreate)" >&2
    exit 1
  fi
fi

# Guard against colliding with a pre-existing tmux session of the same name
# (e.g., user's own `cc` or `codex` session that isn't tracked by this skill).
if tmux has-session -t "$name" 2>/dev/null; then
  echo "a tmux session named '$name' already exists (outside this skill);" >&2
  echo "rename your worker or kill that session first: tmux kill-session -t '$name'" >&2
  exit 1
fi

# bash -lc 'exec <cmd>' so login-shell env/direnv apply.
safe_cmd=${cmd//\'/\'\\\'\'}
wrapper="bash -lc 'exec $safe_cmd'"

# Create a dedicated session with the worker as its first (and only) window.
tmux new-session -d -s "$name" -n "main" -c "$cwd" "$wrapper"

# Capture the first window's id for later reference (informational).
window_id=$(tmux display-message -p -t "$name:0" '#{window_id}' 2>/dev/null || echo "")

sleep 1.5
pid=$(tmux list-panes -t "$name:0" -F '#{pane_pid}' 2>/dev/null | head -1 || echo "")
created_at=$(_tm_iso8601)

new=$(jq \
  --arg n "$name" --arg k "$kind" --arg wid "$window_id" \
  --arg pid "$pid" --arg cwd "$cwd" --arg cmd "$cmd" --arg ts "$created_at" \
  --arg notes "$notes" \
  '.workers[$n] = {
     kind: $k,
     session: $n,
     window_id: $wid,
     pid: ($pid | tonumber? // null),
     cwd: $cwd,
     cmd: $cmd,
     created_at: $ts,
     last_send_at: null,
     notes: $notes
   }' \
  "$TM_REGISTRY")
_tm_reg_write "$new"
_tm_unlock

echo "forked $kind worker '$name' (session=$name window=$window_id pid=${pid:-?})"
echo "  cwd:    $cwd"
echo "  cmd:    $cmd"
echo "  attach: tmux attach -t $name"
echo "---- initial pane buffer ----"
tmux capture-pane -pt "$name:0" -S -30 || true
