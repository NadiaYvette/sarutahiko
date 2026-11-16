---
name: yamaarashi
description: Autonomous task packet runner and ASCII Kanban board projection via yamaarashi-exec. Use to execute isolated task packets (yamaarashi-exec run) or check the task ledger (yamaarashi-exec kanban).
---

# Yamaarashi Flow & Task Packet Execution

`yamaarashi-exec` executes structured task packets in isolated Git worktrees, validates code through build and audit gates, initiates repair cycles on errors, logs events to SQLite, and performs fast-forward merges upon completion.

---

## 1. Quick Reference Commands

| Command | Action |
|---|---|
| `bin/yamaarashi-exec run docs/task_packets/<packet>.yaml` | Execute a task packet in an isolated worktree branch. |
| `bin/yamaarashi-exec kanban` | Project the current ASCII Kanban state from `.yamaarashi/events.sqlite3`. |

---

## 2. Execution Pipeline

```
[Packet YAML] ──> [git worktree add] ──> [Seed ./tags]
                         │
                         ▼
              [Run Executor: agy / utai / script]
                         │
                         ▼
              [Verification Gate: cabal build + verify.sh]
                 │                           │
              (Failure)                   (Pass)
                 │                           │
                 ▼                           ▼
        [Repair Loop: up to N]      [Git Commit + FF Merge]
```

---

## 3. Degradation & POSIX Fallback

If `yamaarashi-exec` is unavailable:
1. Tasks can be executed manually by reading the `action` blocks in the task packet YAML.
2. Verify changes using `cabal test all` and running `sh scripts/tasks/<id>-verify.sh`.
