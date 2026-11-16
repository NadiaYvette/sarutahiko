<!--
SPDX-License-Identifier: EUPL-1.2 OR Apache-2.0
-->
# Operational Rule: Task Packet Execution & Worktree Isolation

**Status:** ACTIVE RULE · Bounded Context Extension  
**Runner:** `yamaarashi-exec` (`/home/nyc/.local/bin/yamaarashi-exec`)  
**Session Loop:** [`PLAN.md`](../../PLAN.md) · [`STATE.md`](../../STATE.md) · [`AGENTS.md`](../../AGENTS.md)

---

## 1. Executor Selection & Airgap Invariants

To avoid quota drain, airgap timeouts, and broken MCP stalls:

1. **Default to `executor: auto` for Scripted Tasks:**
   When task packet implementation steps can be formulated in a task shell or Haskell script (`scripts/tasks/<TASK_ID>.sh`), declare `executor: auto` in the task packet YAML. This executes deterministically in an isolated worktree without LLM sampling overhead or network roundtrips.
2. **Zero-Polling Discipline:**
   When background tasks or subagent commands are launched, never poll in a loop (`manage_task status`, `pgrep`, `ps`, or timer scheduling). Allow the runtime notification mechanism to resume execution reactively.
3. **Worktree Cleanliness:**
   `yamaarashi-exec` merges fast-forward into `master`. Ensure the main repository working tree has 0 uncommitted changes prior to launch.
4. **Physical Gate Verification:**
   All task packets must pass all 5 physical quality gates via `./bin/tengri-verify` (HLint, tests, Tagref, linkcheck, CLOC >= 50.0%) prior to final fast-forward merge.
