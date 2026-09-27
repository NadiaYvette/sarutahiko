# STATE.md — Current Operational Frontier & Immediate Task Queue

Status: LIVING · Updated at every turn/milestone boundary before session reset.  
Audience: Human maintainers and AI coding assistants (Antigravity, Hermes, Claude Code, Aider).  
Reset Rule: Fresh sessions read `PLAN.md` for roadmap invariants and this file for ground truth.

---

## 1. Operational Metadata

* **Timestamp:** 2026-09-27T04:10:00+02:00
* **Git Branch:** `nadia.chambers/hermes-trial-run-003`
* **HEAD Commit:** `a3cead5` (*feat(mcp): implement MCP 2025-03-26 wire types, StateGuard server, and test suite*)
* **Toolchain:** GHC 9.12.2 / Cabal 3.18.1.0, `GHC2024`, zero warnings (`-Wall -Werror`)
* **Worktree Health:** Clean

---

## 2. Recent Completed Actions

1. **Completed Phase 1 TP-1.5 (`packages/sarutahiko-mcp`):**
   - **`sarutahiko-mcp.cabal` (`8e91f72`):** Registered package in `cabal.project`, configured under `cabal-version: 3.14`, `default-language: GHC2024`, `-Wall -Werror`, with zero `aeson` dependencies.
   - **`Sarutahiko.MCP.Types` (`a3cead5`):** Spec-conformant MCP `2025-03-26` wire types, capability structures, tool definitions, and token-level row codecs using `large-anon` and `kogaki-wire`.
   - **`Sarutahiko.MCP.Server` (`a3cead5`):** Protocol server engine strictly enforcing the **StateGuard Invariant**: rejects any request prior to `notifications/initialized` with JSON-RPC error `-32600` (`errServerNotInitialized`).
   - **`Sarutahiko.MCP.Client` (`a3cead5`):** Stdio/stream client engine for handshake initiation and tool invocation.
   - **Hedgehog Verification Suite (`test-mcp`) (`a3cead5`):** All 5 property tests passed 100 trials each (500 total) verifying StateGuard rejection laws, handshake transitions, and wire codec roundtripping.
2. **Environment & Toolchain Stabilization:**
   - Terminated runaway background Hermes processes (PID 606484 and children) and reclaimed `t_db1d0d0c`.
   - Reverted accidental `.cabal` downgrades; restored canonical `GHC2024` and `cabal-version: 3.14` across all 14 packages.
   - Verified Cabal 3.18.1.0 and GHC 9.12.2 build and test cleanly with zero warnings.

---

## 3. Active Blockers & Known Hazards

* **Model Downgrade / Free Fleet Churn:** Dynamic auto-routing via OmniRoute may silently fall back from high-tier models (Nemotron-3-super-120B) to under-parameterized endpoints. Capability checking remains mandatory.
* **Hermes Kanban Daemon Caution:** The experimental SQLite background daemon (`hermes kanban watch` / `dispatch`) can experience claim stalls. Direct CLI invocation (`hermes chat -q`) or expect driver scripts are preferred when executing on the free fleet.

---

## 4. Immediate Workqueue (The Frontier)

### [TASK-002] Phase 1 TP-1.6: Phase 1 Wire Flagship CLI & Interop Suite
* **Objective:** Author standalone `sarutahiko-mcp` CLI executable and dual-interpreter conformance suite.
* **Deliverables:**
  1. `packages/sarutahiko-mcp/app/Main.hs`: Standalone executable speaking stdio JSON-RPC, exposing default diagnostic tools (`echo`, `calc`, `env`).
  2. Dual-interpreter conformance suite running green under both `sarutahiko-effect-effectful` and `sarutahiko-effect-polysemy`.
  3. Golden fixture verification against `test/fixtures/wire/mcp/hokora-turn.jsonl`.
* **Verification Command:** `cabal test test-wire-conformance` & `cabal run sarutahiko-mcp`
