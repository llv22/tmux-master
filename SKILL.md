---
name: tmux-master
description: |
  Fork, drive, and monitor long-lived worker CLIs (Claude Code, Codex, bash)
  each in its own tmux session (session name == worker name). Use to spawn
  solver/evaluator/reviewer workers, send them instructions, capture their
  output, and close them. Triggers on "fork worker", "spawn cc worker",
  "spawn codex worker", "drive tmux worker", "run parallel solvers",
  "orchestrate solver and evaluator".
allowed-tools: Bash(~/.claude/skills/tmux-master/bin/tm-*.sh:*), Bash(tmux:*), Read
user-invocable: true
---

# tmux-master

Drive interactive CLI workers from the main Claude Code session via tmux.
Master is environment-agnostic (any terminal or tmux session); each worker
lives in its own tmux session named after the worker. `tm-close` kills that
session, which cleanly terminates the CLI process.

- Registry: `~/.claude/state/tmux-workers.json` (global, survives sessions).
- Session-per-worker: attach any worker directly with `tmux attach -t <name>`.

See `DESIGN.md` for architecture and `README.md` for a quick reference.

## Commands

All helpers live in `~/.claude/skills/tmux-master/bin/` and are safe to call
directly via Bash. Each prints human-readable status to stdout.

```
tm-fork.sh      <kind> <name> [cwd] [--cmd C] [--notes S] [--replace]
tm-send.sh      <name> [text] [--no-enter] [--accept-prompt] [--stdin]
tm-watch.sh     <name> [--lines N]
tm-wait-idle.sh <name> [--timeout N] [--poll N] [--markers "a,b,c"]
                       [--stable-polls N]
tm-list.sh      [--json]
tm-close.sh     <name> [--force]
tm-shutdown.sh  [--force]
```

`<kind>` ∈ `{cc, codex, bash, custom}`. Defaults:

- `cc`    → `claude`
- `codex` → `/Users/llv23/npm-global/bin/codex`
- `bash`  → `bash -l`
- `custom` → requires `--cmd`

All workers spawn under `bash -lc 'exec <cmd>'` so `.zshrc`/`.bashrc`/direnv
apply.

**Naming caveat:** worker name == tmux session name. If a tmux session of
that name already exists (e.g., your own `cc` or `codex` session), `tm-fork`
refuses to overwrite it — pick a distinct name like `cc-solverA`.

## Typical recipes

### 1. Spawn a worker and give it a task

```bash
~/.claude/skills/tmux-master/bin/tm-fork.sh cc cc-solverA "/path/to/project"
~/.claude/skills/tmux-master/bin/tm-send.sh cc-solverA "Solve task per TASK_PROMPT.md"
~/.claude/skills/tmux-master/bin/tm-wait-idle.sh cc-solverA --timeout 1800
~/.claude/skills/tmux-master/bin/tm-watch.sh cc-solverA --lines 120
```

### 2. Accept a Claude permission prompt

When `tm-watch` shows `Do you want to proceed? 1. Yes ...`:

```bash
~/.claude/skills/tmux-master/bin/tm-send.sh cc-solverA --accept-prompt
```

### 3. Dual solver + evaluator

```bash
tm-fork.sh cc    cc-solver    "/path/to/task"
tm-fork.sh codex codex-solver "/path/to/task"
tm-send.sh cc-solver    "... task prompt ..."
tm-send.sh codex-solver "... task prompt ..."
tm-wait-idle.sh cc-solver    --timeout 1800
tm-wait-idle.sh codex-solver --timeout 1800
tm-fork.sh bash evalr "/path/to/task"
tm-send.sh evalr "python evaluate.py --bpmn .local/cc/out.xml"
tm-wait-idle.sh evalr --timeout 300
tm-watch.sh evalr --lines 200
# Cleanup:
tm-close.sh cc-solver; tm-close.sh codex-solver; tm-close.sh evalr
```

### 4. Inspect or take over a worker manually

The user can attach from any other terminal:

```
tmux attach -t cc-solverA
```

Ctrl-b d to detach; the worker keeps running.

## Behavior contracts

- **Registry is source of truth** for which workers the skill owns. A tmux
  session created outside the skill won't appear in `tm-list`.
- **Idle detection is best-effort.** Markers + buffer-stability is heuristic;
  always verify task completion by reading `tm-watch` output or checking the
  filesystem artifacts the worker was asked to produce.
- **Permission prompts are not auto-accepted.** Master must see the prompt in
  `tm-watch` output and decide whether to send `--accept-prompt`.

## When to use a different tool

- Short, context-bounded delegation with a **single reply** → use the
  general-purpose or specialized Task/Agent subagent instead; tmux-master
  is for long-lived, stateful, interactive workers.
- Quick one-shot Codex call returning structured output → use the `relay`
  skill instead.
- Same-process fast parallel subagents → use the Agent tool with
  `run_in_background: true`.
