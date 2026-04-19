# tmux-master — quick reference

Global skill at `~/.claude/skills/tmux-master/`. Each worker owns its own
tmux session: **session name == worker name**. Registry at
`~/.claude/state/tmux-workers.json`.

## Commands

```bash
BIN=~/.claude/skills/tmux-master/bin

$BIN/tm-fork.sh     cc|codex|bash|custom <name> [cwd] [--cmd C] [--notes S] [--replace]
$BIN/tm-send.sh     <name> [text] [--no-enter] [--accept-prompt] [--stdin]
$BIN/tm-watch.sh    <name> [--lines N]        # default 60
$BIN/tm-wait-idle.sh <name> [--timeout 600] [--poll 3] [--markers "a,b"] [--stable-polls 2]
$BIN/tm-list.sh     [--json]
$BIN/tm-close.sh    <name> [--force]          # kills the worker's tmux session
$BIN/tm-shutdown.sh [--force]                 # closes every registered worker
```

## Attach manually

```bash
tmux attach -t <worker-name>
# Ctrl-b d  detach (worker keeps running)
```

## Naming caveat

Avoid worker names that collide with tmux sessions you already own (e.g.,
`cc`, `codex`). `tm-fork` errors out on collision — pick `cc-solverA`
instead.

## Environment overrides (optional)

```
TM_STATE_DIR        default: ~/.claude/state
TM_REGISTRY         default: $TM_STATE_DIR/tmux-workers.json
TM_CLAUDE_DEFAULT   default: claude
TM_CODEX_DEFAULT    default: /Users/llv23/npm-global/bin/codex
```

## Dependencies

`tmux`, `jq`, `bash`, `shasum`. All standard on macOS (install `jq` via
brew if missing: `brew install jq`).

See `SKILL.md` for recipes and `DESIGN.md` for architecture.
