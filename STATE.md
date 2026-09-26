# STATE.md — Current Operational Frontier & Immediate Task Queue

Status: LIVING · Updated at every turn/milestone boundary before session reset.  
Audience: Human maintainers and AI coding assistants (Antigravity, Hermes, Claude Code, Aider).  
Reset Rule: Fresh sessions read `PLAN.md` for roadmap invariants and this file for ground truth.

---

## 1. Operational Metadata

* **Timestamp:** 2026-09-26T22:52:00+02:00
* **Git Branch:** `master`
* **HEAD Commit:** `9c329d0` (*docs: codify unbounded hierarchical scope nesting across effect and diagnostic layers*)
* **Upstream Sync:** 17 commits ahead of `rad/master` (batched push policy strictly enforced; push only on maintainer instruction via `bin/push-all`)
* **Toolchain:** GHC 9.12.2 / Cabal 3.18, `GHC2024`, zero warnings (`-Wall -Werror`)
* **Worktree Health:** Clean

---

## 2. Recent Completed Actions

1. **Codified Unbounded Hierarchical Scope Nesting (`9c329d0`):**
   - Formalized Laws S1–S4 for `Scoped` in `docs/notes/EFFECT_CATALOG_DESIGN.md` §6.3, guaranteeing unbounded recursive depth without depth ceilings.
   - Resolved Open Question O2 in `docs/notes/OBSERVABILITY_DESIGN.md` §8: spans are first-class `Scoped` regions with inductive `SpanPath` trees.
   - Added Section 2.5 to `docs/notes/ASSISTANT_TOOLING_DESIGN.md` mandating `ScopeStack` preservation in `tricorder` and `codegraph` to prevent wrong-scope refactoring errors.
2. **Hermes Trial Run Quiescence & Branch Preservation:**
   - Trial branch `nadia.chambers/hermes-trial-run-001` preserved with commit `010e673` capturing Hermes's WIP code attempts.
   - Docs commit `722a2f6` cherry-picked to `master` as `9c329d0`.
3. **Host Tooling Suite Fully Configured & Repaired:**
   - **`~/.hermes/config.yaml` Defect Repair:** Migrated deprecated `custom_providers` list to modern `providers:` mapping (`api:` endpoints). Verified zero deprecation warnings under `hermes doctor`.
   - **MCP Tool Integration:** Configured `/home/nyc/.local/bin/codegraph-mcp` (AST & call-graph queries), `/home/nyc/.local/bin/open-kioku` (evidence graph & impact analysis), and authored `/home/nyc/.local/bin/keiro-ops-mcp` (durable workflow & PGMQ operations) in `~/.hermes/config.yaml`.
   - **Continuous AST Auto-Indexing Daemon:** Created, enabled, and launched `codegraph-daemon.service` under `systemd --user` with `CODEGRAPH_TELEMETRY=off`, continuously watching `sarutahiko` and indexing AST/call-graph changes to RocksDB in the background.

---

## 3. Active Blockers & Known Hazards

* **Hermes Downgrade Hazard:** When autonomous agents attempt cabal package setup, they may attempt to regress `cabal-version: 3.14` to `3.0` or `default-language: GHC2024` to `GHC2021`. The GHC2024 / 3.14 baseline must be strictly maintained.
* **Model Downgrade / Free Fleet Churn:** Dynamic auto-routing via OmniRoute may silently fall back from high-tier models (Nemotron-3-super-120B / Claude) to under-parameterized endpoints. Capability checking remains mandatory.

---

## 4. Immediate Workqueue (The Frontier)

### [TASK-001] Phase 1 TP-1.5: `packages/sarutahiko-mcp` Implementation
* **Objective:** Author clean, lawful MCP 2025-03-26 client/server implementation in `packages/sarutahiko-mcp/`.
* **Prerequisites:** Register package in `cabal.project` under `with-compiler: ghc-9.12.2`.
* **Files to Author:**
  1. `packages/sarutahiko-mcp/sarutahiko-mcp.cabal`: `cabal-version: 3.14`, `default-language: GHC2024`, zero warnings.
  2. `src/Sarutahiko/MCP/Types.hs`: JSON-RPC wire structures, protocol version `2025-03-26`, initialization frames.
  3. `src/Sarutahiko/MCP/Server.hs`: Tool provider engine enforcing **StateGuard** (return `-32600` on pre-initialization calls).
  4. `src/Sarutahiko/MCP/Client.hs`: Tool consumer engine speaking stdio transport.
  5. `test/Main.hs`: Tasty/Hedgehog test suite verifying StateGuard rejection laws (`test-mcp`).
* **Verification Command:** `cabal test test-mcp`
