#!/usr/bin/env bash
# tmux-master: send text to a worker via tmux send-keys.
# Usage: tm-send.sh <name> [text] [--no-enter] [--accept-prompt] [--stdin]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_registry.sh
source "$SCRIPT_DIR/_registry.sh"

_tm_require tmux jq

usage() {
  cat >&2 <<'EOF'
tm-send <name> [text] [--no-enter] [--accept-prompt] [--stdin]
  --no-enter:      do not append Enter (single-line text only)
  --accept-prompt: send "1" + Enter (answers Claude Code permission prompt)
  --stdin:         read text from stdin instead of positional arg
EOF
  exit 2
}

name=""
text=""
send_enter=true
accept_prompt=false
read_stdin=false

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-enter)      send_enter=false; shift ;;
    --accept-prompt) accept_prompt=true; shift ;;
    --stdin)         read_stdin=true; shift ;;
    -h|--help)       usage ;;
    *)               args+=("$1"); shift ;;
  esac
done

[[ ${#args[@]} -ge 1 ]] || usage
name="${args[0]}"
if [[ ${#args[@]} -ge 2 ]]; then
  text="${args[*]:1}"
fi
if $read_stdin; then
  text="$(cat)"
fi

_tm_init_registry
_tm_worker_exists "$name" || { echo "no such worker: $name" >&2; exit 1; }
_tm_session_alive "$name" || { echo "worker '$name' session is not alive" >&2; exit 1; }

target=$(_tm_target "$name")

if $accept_prompt; then
  tmux send-keys -t "$target" "1"
  tmux send-keys -t "$target" Enter
elif [[ -z "$text" ]]; then
  :
elif [[ "$text" == *$'\n'* ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    tmux send-keys -t "$target" -l "$line"
    tmux send-keys -t "$target" Enter
  done <<< "$text"
else
  tmux send-keys -t "$target" -l "$text"
  $send_enter && tmux send-keys -t "$target" Enter
fi

_tm_lock
ts=$(_tm_iso8601)
new=$(jq --arg n "$name" --arg ts "$ts" \
  '.workers[$n].last_send_at = $ts' "$TM_REGISTRY")
_tm_reg_write "$new"
_tm_unlock

bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
echo "sent ${bytes} bytes to '$name'"
