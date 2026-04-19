# tmux-master — Design

**Status:** IMPLEMENTED — smoke-tested end-to-end.
**Owner:** Orlando Ding
**Date:** 2026-04-18 (revised same day — per-worker-session model)
**Location:** `~/.claude/skills/tmux-master/` (global scope)

---

## 1. Motivation

Main Claude Code session needs to **drive worker CLI agents** (Claude Code, Codex) as
subprocesses and orchestrate multi-agent workflows (solver → evaluator, parallel
solvers, review loops) **without going through file-based handoffs**.

Files-as-IPC is slow (polling, latency), error-prone (partial writes, stale reads),
and requires both sides to agree on a protocol. A tmux pane, by contrast, is a **live
stdio channel**: main writes keys in, captures pane buffer out. The worker runs its
normal interactive CLI — no cooperation required.

**Primary use cases** (concrete, not baked into the skill):
- Spawn `cc` solver + `codex` solver on the same task, then run evaluator against both.
- Delegate a long task to a worker while main stays responsive.
- Parallel attack agents against a hardened benchmark (the BPMN hardening loop).
- Hand a heavy research crawl to a worker and poll its output.

**Secondary benefit:** the user can `tmux attach -t ecc-workers` at any time to
inspect, intervene, or take over a worker manually.

## 2. Non-goals

- Not an MCP server. This is plain tmux + bash.
- Not a scheduler. Workers run when spawned; orchestration logic lives in the caller.
- Not a replacement for Task/Agent subagents when the work is short-lived and
  context-bounded. tmux-master is for **long-lived, stateful, interactive CLI
  workers** — things that own their own session state.
- Not cross-host. Workers run locally in the user's tmux server.

## 3. Architecture

**Master (caller) is environment-agnostic.** Main Claude Code can be running in a
plain iTerm tab, a VSCode terminal, inside tmux, inside a screen session — anywhere.
The skill never assumes the master is in tmux. It talks to the tmux server over the
unix socket using the `tmux` client, which works identically from any shell.

**Each worker owns its own tmux session.** Session name == worker name == registry
key. The CLI process is the sole occupant of that session's first window. When
`tm-close` kills the session, the CLI goes with it. Rationale: each worker is a
first-class addressable unit (attach via `tmux attach -t <name>`, list via
`tmux list-sessions`, kill with a single `kill-session`). This matches how the
user already runs `cc` and `codex` as separate top-level tmux sessions.

```
┌─ master: main Claude Code (anywhere — tmux, iTerm, VSCode term, …) ──┐
│                                                                       │
│   /tm-fork cc cc-solverA "/path/to/project"                          │
│           │                                                           │
│           ▼                                                           │
│   bin/tm-fork.sh ──► tmux new-session -d -s cc-solverA -n main       │
│                       -c /path/to/project                             │
│                       "bash -lc 'exec claude'"                       │
│                       ──► registers in workers.json                   │
│                                                                       │
│   /tm-send cc-solverA "solve the BPMN task ..."                      │
│           │                                                           │
│           ▼                                                           │
│   bin/tm-send.sh  ──► tmux send-keys -t cc-solverA:0 -l <txt>; Enter │
│                                                                       │
│   /tm-watch cc-solverA --lines 80                                    │
│           │                                                           │
│           ▼                                                           │
│   bin/tm-watch.sh ──► tmux capture-pane -pt cc-solverA:0 -S          │
└───────────────────────────────────────────────────────────────────────┘
                                │ tmux unix socket
                                ▼
     Per-worker tmux sessions (one session per worker, lazy-created)
     ┌────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
     │ cc-solverA │  │ codex-sol.. │  │ evalr       │  │ (user's own │
     │ (claude)   │  │ (codex)     │  │ (bash)      │  │  cc, codex) │
     └────────────┘  └─────────────┘  └─────────────┘  └─────────────┘
     `tmux attach -t cc-solverA` attaches directly to that worker.
```

**Key invariants:**
- Session name == worker name == registry key; no `window:pane` navigation needed.
- `tm-fork` refuses if a tmux session of that name already exists (whether skill-
  owned or external). Protects the user's pre-existing `cc`, `codex` sessions.
- `tm-close <name>` → `tmux kill-session -t <name>` → CLI process terminates
  cleanly (SIGHUP to the pane group).

## 4. Registry schema

`~/.claude/state/tmux-workers.json`:

```json
{
  "session": "ecc-workers",
  "workers": {
    "solverA": {
      "kind": "cc",
      "window": "solverA",
      "window_id": "@42",
      "pid": 54321,
      "cwd": "/Users/llv23/Documents/.../project",
      "cmd": "claude",
      "created_at": "2026-04-18T16:40:00-07:00",
      "last_send_at": "2026-04-18T16:42:10-07:00",
      "notes": "cc solver attempt 1"
    },
    "evalRunner": {
      "kind": "bash",
      "window": "evalRunner",
      "window_id": "@43",
      "pid": 54400,
      "cwd": "/Users/llv23/Documents/.../project",
      "cmd": "bash",
      "created_at": "2026-04-18T16:41:00-07:00",
      "last_send_at": null,
      "notes": null
    }
  }
}
```

- `kind` ∈ `{cc, codex, bash, custom}`. Only affects spawn command + default prompts.
- `window_id` (tmux's `@N`) is the **stable handle** — survives window renames.
- `pid` is the pane's foreground process PID at spawn time (informational; PID may
  rotate as CLI spawns subprocesses).
- Registry is written atomically (write to `.tmp` then `mv`).

## 5. Command spec

All commands are **slash-invoked** through the skill. Internally they shell out to
`bin/*.sh` helpers.

### 5.1 `/tm-fork <kind> <name> [cwd] [--cmd <cmd>] [--notes <text>]`
Spawn a worker. Creates the `ecc-workers` session on first call.

- Errors if `<name>` already in registry (unless `--replace`, which closes old first).
- `kind=cc` → `cmd` defaults to `claude` (resolved via `PATH`; spawned as
  `bash -lc 'exec claude'` so login-shell env/direnv apply).
- `kind=codex` → `cmd` defaults to **`/Users/llv23/npm-global/bin/codex`** (absolute
  path; this binary is in npm-global which is not always on the default PATH).
  Overridable via `--cmd`.
- `kind=bash` → `cmd` defaults to `bash -l` (for running evaluators etc.).
- `kind=custom` → `--cmd` required.
- Waits ~2s after spawn, captures first buffer, returns it so caller sees the
  worker's startup banner and can confirm readiness.

### 5.2 `/tm-send <name> <text> [--no-enter] [--accept-prompt]`
Send text to worker. Uses `send-keys -l` (literal) so shell metacharacters are safe,
then sends `Enter` unless `--no-enter`.

- `--accept-prompt` is a convenience: sends `1` + Enter (for Claude's permission
  prompts like the one encountered this session).
- `<text>` can be multiline; we split on `\n` and send each line with Enter so it
  lands as the CLI expects.
- Updates `last_send_at` in registry.

### 5.3 `/tm-watch <name> [--lines N] [--since-last-send]`
Capture pane buffer.

- Default: last 60 lines.
- `--since-last-send` trims to output after `last_send_at` (approximated by searching
  for the sent text marker in the buffer).
- Returns plain text — caller (main Claude) reads it into context.

### 5.4 `/tm-wait-idle <name> [--timeout 600] [--poll 3] [--markers "❯,✓,DONE"]`
Block until worker looks idle. Idle heuristic:

1. Capture pane tail.
2. Check if last non-empty line matches any `--markers` (default set tuned for
   `claude` prompt `❯`, codex prompt, bash `$`/`#`).
3. Check if buffer has been unchanged for `N` consecutive polls (N=2).

Returns the final captured buffer. Timeout returns with `status=timeout` but does
not kill the worker.

### 5.5 `/tm-list`
Show registry: name, kind, cwd, created_at, last_send_at, alive? (is window still
in tmux session).

### 5.6 `/tm-close <name> [--force]`
Graceful: send `Ctrl-C` then `Ctrl-D`, wait 3s, then kill-window if still alive.
`--force` skips graceful phase. Removes from registry.

### 5.7 `/tm-shutdown [--force]`
Close every worker, then `tmux kill-session -t ecc-workers`. Clears registry.

### 5.8 `/tm-attach`
Prints the command for the user to run: `tmux attach -t ecc-workers`. (Main Claude
can't attach itself — this is informational.)

## 6. Idle-detection markers

Per-kind defaults (in `bin/tm-wait-idle.sh`):

| kind  | markers                                    |
|-------|--------------------------------------------|
| cc    | `❯ `, `✢ Cooked`, `Razzle-dazzling`       |
| codex | `▌`, `codex>`                              |
| bash  | `$ `, `# `                                 |

User-overridable per call.

**Caveat:** markers are heuristics. Main Claude should still verify task completion
by inspecting the captured text, not just trust idle detection. For critical
handoffs, the worker's own "DONE" marker in its output is more reliable.

## 7. Permission-prompt handling (cc-specific)

Claude Code workers sometimes block on "Do you want to proceed? 1. Yes / 2. Yes,
always / 3. No" prompts. Two strategies:

1. **Pre-allow** via `~/.claude/settings.json` (user-managed) — best for known
   tool patterns.
2. **Reactive** via `/tm-send <name> --accept-prompt` — sends `1` + Enter.

The skill will not auto-detect and auto-accept — that's a security footgun. Main
Claude must see the prompt in `/tm-watch` output and decide.

## 8. Example recipes (not part of the skill, illustrative)

### 8.1 Dual solver + evaluator
```
/tm-fork cc cc-solver /path/to/task
/tm-fork codex codex-solver /path/to/task
/tm-send cc-solver "Read TASK_PROMPT.md and produce modified_process.bpmn20.xml"
/tm-send codex-solver "Read TASK_PROMPT.md and produce modified_process.bpmn20.xml"
/tm-wait-idle cc-solver --timeout 1800
/tm-wait-idle codex-solver --timeout 1800
/tm-fork bash evalr /path/to/task
/tm-send evalr "python evaluate_L3.py --bpmn .local/cc/modified.xml ..."
/tm-wait-idle evalr
/tm-watch evalr --lines 200
```

### 8.2 Autonomous hardening loop
(driven by main Claude in a single session; each round spawns fresh solvers,
evaluates, then `/tm-close` and iterates)

## 9. Implementation layout

```
~/.claude/skills/tmux-master/
├── DESIGN.md              (this file)
├── SKILL.md               (skill doc + command routing)
├── bin/
│   ├── tm-fork.sh
│   ├── tm-send.sh
│   ├── tm-watch.sh
│   ├── tm-wait-idle.sh
│   ├── tm-list.sh
│   ├── tm-close.sh
│   ├── tm-shutdown.sh
│   └── _registry.sh       (shared: read/write workers.json with jq)
└── README.md              (user-facing quick reference)
```

State: `~/.claude/state/tmux-workers.json` (created on first fork).

## 10. Dependencies

- `tmux` (any recent version; `@` window IDs are pre-2.x stable)
- `jq` (registry manipulation)
- `bash` 3.2+ (macOS default works)
- No Python, no Node.

## 11. Edge cases & decisions

| Case                                         | Handling                                      |
|----------------------------------------------|-----------------------------------------------|
| `ecc-workers` session killed externally      | `/tm-list` flags all workers `alive=false`; next `/tm-fork` recreates session |
| Worker pane crashed / CLI exited             | `/tm-list` shows `alive=false`; `/tm-send` to dead worker errors |
| `send-keys -l` with Unicode                  | tmux handles UTF-8 since 2.2; fine            |
| Very long prompts (>4KB)                     | Chunk to 2KB segments, send sequentially      |
| Multiple main Claudes concurrently using skill | Registry uses file lock (`flock`) during writes |
| Worker inside a Docker container             | Out of scope — spawn command has to run the container interactively if user wants it |
| Windows not showing `@id` (old tmux)         | Fall back to name-based targeting; lose stability across renames |

## 12. Resolved decisions (2026-04-18)

1. **Master environment-agnostic** — master does not need to be in tmux. Skill talks
   to tmux server via unix socket; works from any shell/terminal. Only workers live
   in tmux. (§3 updated.)
2. **Login-shell inheritance** — workers spawn under `bash -lc 'exec <cmd>'` so
   `.zshrc`/`.bashrc`/direnv apply. (§5.1 updated.)
3. **Codex CLI path** — `/Users/llv23/npm-global/bin/codex` (absolute; not on
   default PATH). Hard-coded as default for `kind=codex`, overridable via `--cmd`.
   (§5.1 updated.)
4. **Session name** — `ecc-workers` (workers-only; no conflict with master's own
   tmux session if master happens to be in one).

## 13. Approval checklist

- [ ] Scope and non-goals accurate
- [ ] Registry schema OK
- [ ] Command set complete (nothing missing, nothing excess)
- [ ] Idle-detection heuristic acceptable as best-effort
- [ ] Permission-prompt policy (manual, not auto) OK
- [ ] Layout + dependencies OK
- [ ] Open questions answered

Once checked off, I'll implement `SKILL.md` + `bin/*.sh` + `README.md` in a single
pass.
