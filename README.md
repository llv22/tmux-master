# tmux-master

Fork, drive, and monitor long-lived CLI workers (Claude Code, Codex, bash) from
another Claude Code session — each worker lives in its **own tmux session** so you
can attach to it, send keystrokes, read its pane buffer, and terminate it cleanly.

- **Global skill location:** `~/.claude/skills/tmux-master/`
- **Registry:** `~/.claude/state/tmux-workers.json` (survives restarts)
- **One worker = one tmux session** (session name == worker name).
- **Driver is environment-agnostic:** main Claude Code can run inside tmux, iTerm,
  a VSCode terminal, anywhere — the helpers talk to the tmux server over its unix
  socket.

---

## 1. Motivation — why this exists

When a long task should run alongside the main Claude Code conversation, the usual
options all have problems:

| Option                              | Problem                                                            |
|-------------------------------------|--------------------------------------------------------------------|
| File-based handoffs (`.local/out`)  | Polling, stale reads, every side has to agree on a protocol.       |
| `Agent` / `Task` subagents          | Short-lived, single reply, no stateful REPL, no easy mid-task steering. |
| Launching `claude` / `codex` inline | Blocks the main session; output is interleaved; no clean kill.     |

`tmux-master` gives the main session a **live stdio channel** to each worker:

- Write keystrokes into the worker's pane (`tm-send`).
- Capture the worker's pane buffer on demand (`tm-watch`, `tm-wait-idle`).
- Kill the worker's entire process tree with one command (`tm-close`).

Concrete use cases it's built for:

1. **Dual solver + evaluator** — spawn a `cc` solver and a `codex` solver on the
   same task, wait for both, then run a `bash` evaluator worker.
2. **Long research/crawl delegation** — hand a multi-minute task to a worker,
   keep main responsive, poll when you need an update.
3. **Human takeover** — user can `tmux attach -t <name>` from any terminal to
   inspect or drive a worker manually; detaching leaves it running.

Non-goals: it's not an MCP server, not a scheduler, not cross-host, and not a
replacement for `Agent` subagents when the work is a single short reply.

---

## 2. Setup

### 2.1 Dependencies

| Tool     | Purpose                                | Install (macOS)        |
|----------|----------------------------------------|------------------------|
| `tmux`   | Process container + pane IO            | `brew install tmux`    |
| `jq`     | Registry (JSON) read/write             | `brew install jq`      |
| `bash`   | 3.2+ — system bash is fine             | preinstalled           |
| `shasum` | Idle detection (buffer hashing)        | preinstalled           |

Verify:

```bash
for c in tmux jq bash shasum; do command -v "$c" || echo "MISSING: $c"; done
```

### 2.2 Install the skill

The skill is a plain directory — no build step. Clone to your Claude skills dir:

```bash
git clone -b develop https://github.com/llv22/tmux-master.git \
  ~/.claude/skills/tmux-master
chmod +x ~/.claude/skills/tmux-master/bin/*.sh
```

Claude Code auto-discovers skills under `~/.claude/skills/`. Restart the main
session so it picks up the new skill's frontmatter from `SKILL.md`.

### 2.3 Optional environment overrides

The helpers honor these env vars (defaults shown):

```bash
TM_STATE_DIR=~/.claude/state                   # where workers.json lives
TM_REGISTRY=$TM_STATE_DIR/tmux-workers.json    # registry file path
TM_CLAUDE_DEFAULT=claude                       # `cc` worker command
TM_CODEX_DEFAULT=/Users/llv23/npm-global/bin/codex   # `codex` worker command
```

Put overrides in `~/.zshrc`/`.bashrc` if your `claude` / `codex` binaries live at
other paths.

### 2.4 Smoke test

```bash
BIN=~/.claude/skills/tmux-master/bin
$BIN/tm-fork.sh bash smoke "$HOME"
$BIN/tm-send.sh smoke "echo hello from worker; date"
$BIN/tm-watch.sh smoke --lines 10
$BIN/tm-close.sh smoke
$BIN/tm-list.sh
```

Expected: `tm-watch` prints `hello from worker` and a timestamp; `tm-list`
afterward shows no entry for `smoke`.

---

## 3. Mental model

```
  main Claude Code  ──keystrokes──►  ┌─────────────────────┐   tmux session: cc-solverA
  (anywhere)                         │  claude (worker)    │   ├─ pane owns stdio
                    ◄──pane buffer── └─────────────────────┘   └─ kill-session ⇒ clean exit

  main Claude Code  ──keystrokes──►  ┌─────────────────────┐   tmux session: codex-solverA
                    ◄──pane buffer── │  codex (worker)     │
                                     └─────────────────────┘
```

- Main never becomes the worker — it only sends keys and captures output.
- The **registry** (`~/.claude/state/tmux-workers.json`) tracks which tmux sessions
  the skill owns. A tmux session you started manually outside the skill will *not*
  appear in `tm-list` and won't be touched by `tm-shutdown`.

---

## 4. Commands — cheat sheet

All helpers live in `~/.claude/skills/tmux-master/bin/`. Add them to your PATH or
set a short alias:

```bash
BIN=~/.claude/skills/tmux-master/bin
```

| Command                                   | Purpose                                                     |
|-------------------------------------------|-------------------------------------------------------------|
| `tm-fork.sh <kind> <name> [cwd] [flags]`  | Spawn a worker (`cc` \| `codex` \| `bash` \| `custom`).     |
| `tm-send.sh <name> [text] [flags]`        | Send keystrokes (optional `--accept-prompt`, `--stdin`).    |
| `tm-watch.sh <name> [--lines N]`          | Print last N lines of the worker's pane (default 60).       |
| `tm-wait-idle.sh <name> [flags]`          | Block until the worker looks idle (marker + stable buffer). |
| `tm-list.sh [--json]`                     | Show all registered workers (kind, cwd, created, alive?).   |
| `tm-close.sh <name> [--force]`            | Graceful stop (Ctrl-C, Ctrl-D) then kill-session.           |
| `tm-shutdown.sh [--force]`                | Close every registered worker.                              |

`kind` resolves to a default spawn command:

- `cc`     → `$TM_CLAUDE_DEFAULT` (default: `claude`)
- `codex`  → `$TM_CODEX_DEFAULT`  (default: `/Users/llv23/npm-global/bin/codex`)
- `bash`   → `bash -l`
- `custom` → requires `--cmd "<command>"`

All kinds spawn under `bash -lc 'exec <cmd>'` so `.zshrc` / `.bashrc` / direnv
apply.

**Naming rule:** worker name matches `[A-Za-z0-9_-]+` and must not collide with
an existing tmux session (so avoid `cc`, `codex` if you already use those). Use
`cc-solverA`, `codex-reviewer`, etc.

---

## 5. Driving a worker: trigger → wait → feedback

The driving loop is always the same three steps. Here it is for a `cc` worker:

```bash
BIN=~/.claude/skills/tmux-master/bin

# 1. TRIGGER — spawn and send the task
$BIN/tm-fork.sh cc cc-solverA /path/to/project \
    --notes "attempt 1 on TASK_PROMPT.md"
$BIN/tm-send.sh cc-solverA \
    "Read TASK_PROMPT.md and produce .local/cc/modified_process.bpmn20.xml"

# 2. WAIT — block until the worker goes idle (or timeout)
$BIN/tm-wait-idle.sh cc-solverA --timeout 1800 --poll 5

# 3. FEEDBACK — read the last chunk of the pane for main Claude to consume
$BIN/tm-watch.sh cc-solverA --lines 200
```

### 5.1 `tm-send` — sending input

- Positional text: `tm-send.sh NAME "one-liner prompt"`
- Multiline via stdin:
  ```bash
  $BIN/tm-send.sh cc-solverA --stdin <<'PROMPT'
  Read TASK_PROMPT.md.
  Plan the change.
  Produce the BPMN output.
  PROMPT
  ```
- No trailing Enter (e.g., typing a prefix you'll complete later):
  `tm-send.sh NAME "word" --no-enter`
- **Claude Code permission prompt** (`Do you want to proceed? 1. Yes…`):
  `tm-send.sh NAME --accept-prompt` (sends `1` + Enter).

### 5.2 `tm-wait-idle` — when is the worker "done"?

Idle is a **best-effort** heuristic: it captures the pane tail every `--poll`
seconds and declares idle when

1. the last non-empty line matches one of `--markers` (per-kind defaults below), **and**
2. the pane buffer hash hasn't changed for `--stable-polls` consecutive polls
   (default 2).

| kind  | default markers                                 |
|-------|-------------------------------------------------|
| cc    | `❯`, `Razzle-dazzling`, `Cooked for`, `Thundering` |
| codex | `codex>`, `▌`                                   |
| bash  | `$`, `#`                                        |

Override for custom prompts:

```bash
$BIN/tm-wait-idle.sh myworker --markers "DONE,ALL_TESTS_PASSED" --timeout 900
```

On timeout the helper exits 124 but leaves the worker running — you can retry
`tm-wait-idle` with a longer timeout, or `tm-watch` to inspect progress.

**Don't trust idle alone for correctness.** After `tm-wait-idle` returns, verify
by checking the artifact the worker was asked to produce (file exists, JSON
parses, tests pass).

### 5.3 `tm-watch` — reading the pane

```bash
$BIN/tm-watch.sh cc-solverA --lines 120   # last 120 lines of the worker's pane
```

Capture is a snapshot — the buffer is truncated by tmux's scrollback limit.
For a larger window, the user can attach manually:

```bash
tmux attach -t cc-solverA       # Ctrl-b d to detach, worker keeps running
```

---

## 6. Managing multiple workers

```bash
$BIN/tm-list.sh                 # human-readable table
$BIN/tm-list.sh --json | jq .   # machine-readable
$BIN/tm-close.sh cc-solverA     # stop one
$BIN/tm-shutdown.sh             # stop all registered workers
```

Typical parallel solver + evaluator recipe:

```bash
$BIN/tm-fork.sh cc    cc-solver    /path/to/task
$BIN/tm-fork.sh codex codex-solver /path/to/task

$BIN/tm-send.sh cc-solver    "Solve per TASK_PROMPT.md"
$BIN/tm-send.sh codex-solver "Solve per TASK_PROMPT.md"

$BIN/tm-wait-idle.sh cc-solver    --timeout 1800
$BIN/tm-wait-idle.sh codex-solver --timeout 1800

$BIN/tm-fork.sh bash evalr /path/to/task
$BIN/tm-send.sh evalr "python evaluate.py --bpmn .local/cc/out.xml"
$BIN/tm-wait-idle.sh evalr --timeout 300
$BIN/tm-watch.sh evalr --lines 200

$BIN/tm-close.sh cc-solver
$BIN/tm-close.sh codex-solver
$BIN/tm-close.sh evalr
```

---

## 7. Troubleshooting

| Symptom                                                     | Cause / fix                                                           |
|-------------------------------------------------------------|------------------------------------------------------------------------|
| `a tmux session named 'X' already exists (outside this skill)` | You already run a personal session of that name. Pick a new worker name or `tmux kill-session -t X`. |
| `worker 'X' already registered`                             | Previous run left it around. `tm-close X` or `tm-fork ... --replace`. |
| `tm-wait-idle` exits 124 (timeout)                          | Worker is still working, prompt text differs, or it's blocked on a permission prompt. Inspect with `tm-watch`. |
| `tm-send` says "worker session is not alive"                | CLI exited (crash / `exit`). Re-fork or check `tm-watch` for the last error. |
| Nothing shows up in `tm-list`                               | Registry not initialized yet — any successful `tm-fork` creates it.    |
| Claude Code workers stall on permission prompt              | `tm-watch` the worker, then `tm-send <name> --accept-prompt`. For known-safe commands, pre-allow them in `~/.claude/settings.json`. |

---

## 8. Uninstall

```bash
~/.claude/skills/tmux-master/bin/tm-shutdown.sh --force
rm -rf ~/.claude/skills/tmux-master
rm -f  ~/.claude/state/tmux-workers.json
```

---

See [`SKILL.md`](SKILL.md) for the slash-invocable skill contract and more
recipes, and [`DESIGN.md`](DESIGN.md) for the full architecture (registry
schema, command spec, edge cases, design decisions).
