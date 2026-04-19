#!/usr/bin/env bash
# tmux-master: shared helpers for all tm-*.sh commands.
# Sourced, not executed.
#
# Model: each worker owns its own tmux session, with session name == worker
# name. The CLI process is the sole occupant of that session's first window.
# tm-close kills the session, which terminates the CLI.

set -euo pipefail

TM_STATE_DIR="${TM_STATE_DIR:-$HOME/.claude/state}"
TM_REGISTRY="${TM_REGISTRY:-$TM_STATE_DIR/tmux-workers.json}"
TM_LOCK_DIR="${TM_LOCK_DIR:-$TM_STATE_DIR/tmux-workers.lock}"
TM_CODEX_DEFAULT="${TM_CODEX_DEFAULT:-/Users/llv23/npm-global/bin/codex}"
TM_CLAUDE_DEFAULT="${TM_CLAUDE_DEFAULT:-claude}"

_tm_require() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 \
      || { echo "tmux-master: missing required command: $cmd" >&2; exit 1; }
  done
}

_tm_init_registry() {
  mkdir -p "$TM_STATE_DIR"
  if [[ ! -f "$TM_REGISTRY" ]]; then
    printf '{"workers":{}}\n' > "$TM_REGISTRY"
  fi
}

_tm_lock() {
  local retries=50
  while ! mkdir "$TM_LOCK_DIR" 2>/dev/null; do
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      echo "tmux-master: could not acquire registry lock ($TM_LOCK_DIR)" >&2
      exit 1
    fi
    sleep 0.1
  done
  trap "_tm_unlock" EXIT
}

_tm_unlock() {
  rmdir "$TM_LOCK_DIR" 2>/dev/null || true
  trap - EXIT
}

_tm_reg_write() {
  local new_content="$1"
  local tmp="$TM_REGISTRY.tmp.$$"
  printf '%s\n' "$new_content" > "$tmp"
  mv "$tmp" "$TM_REGISTRY"
}

_tm_worker_exists() {
  local name="$1"
  jq -e --arg n "$name" '.workers | has($n)' "$TM_REGISTRY" >/dev/null 2>&1
}

_tm_worker_field() {
  local name="$1"
  local field="$2"
  jq -r --arg n "$name" --arg f "$field" '.workers[$n][$f] // empty' "$TM_REGISTRY"
}

# Session name == worker name; each worker owns its own tmux session.
_tm_session_alive() {
  local name="$1"
  tmux has-session -t "$name" 2>/dev/null
}

# Target string for send-keys / capture-pane. Workers always occupy the first
# window of their session.
_tm_target() {
  local name="$1"
  printf '%s:0' "$name"
}

_tm_iso8601() {
  date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'
}
