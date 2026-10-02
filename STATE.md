# STATE.md — Current Operational Frontier & Immediate Task Queue

Status: LIVING · Updated at every turn/milestone boundary before session reset.  
Audience: Human maintainers and AI coding assistants (Antigravity, Hermes, Claude Code, Aider).  
Reset Rule: Fresh sessions read `PLAN.md` for roadmap invariants and this file for ground truth.

---

## 1. Operational Metadata

* **Timestamp:** 2026-10-02T22:40:20+02:00
* **Git Branch:** `nadia.chambers/yamaarashi-redesign`
* **HEAD Commit:** `5a9d44d` (*docs: add task packet best practices and AI coding context management SOTA transcript*)
* **Toolchain:** GHC 9.12.2 / Cabal 3.18.1.0, `GHC2024`, zero warnings (`-Wall -Werror`)
* **Worktree Health:** Clean

---

## 2. Recent Completed Actions

1. **Committed Canonical Task & Context Documentation (`5a9d44d`):**
   - Added `docs/notes/TASK_PACKET_BEST_PRACTICES.md` establishing fail-fast toolchain verification gates, minimal buildable skeletons, and verifiable task packets.
   - Added `docs/transcripts/AI_Coding_Context_Management_SOTA.md` documenting context management SOTA, REPL-neutral integration via MCP sampling, and the revised Yamaarashi selective orchestration design.
2. **Archived Pre-Pivot Yamaarashi Skeletons (`d8521eb`):**
   - Captured all uncommitted WIP stubs under `packages/yamaarashi*`, experiment `.cabal` changes, and `cabal.project` modifications to isolated archive branch `archive/yamaarashi-pre-pivot-skeletons`.
   - Created clean working branch `nadia.chambers/yamaarashi-redesign` at `5a9d44d`.

---

## 3. Active Blockers & Known Hazards

* **Model Downgrade / Free Fleet Churn:** Dynamic auto-routing via OmniRoute may silently fall back from high-tier models to under-parameterized endpoints. Capability checking remains mandatory.
* **Hermes Kanban Daemon Caution:** The experimental SQLite background daemon (`hermes kanban watch` / `dispatch`) can experience claim stalls. Direct CLI invocation (`hermes chat -q`) or expect driver scripts are preferred when executing on the free fleet.

---

## 4. Immediate Workqueue: Yamaarashi Design Reconciliation Decisions

The following sequential decisions must be resolved to reconcile the revised Yamaarashi design with `YAMAARASHI_DESIGN.md`, `NIH_PLAN.md`, `AGENTIC_TASK_MANAGEMENT_DESIGN.md`, and `PLAN.md`:

### [DECISION-001] Core Identity & Layering Split
* **Topic:** Streaming kernel vs. Selective workflow orchestrator; status of Porcupine.
* **Questions:**
  1. Does `yamaarashi` become the orchestration package family (`packages/yamaarashi`, `packages/yamaarashi-flow`, etc.), and where does element streaming (`Stream (Of a) m r`) reside?
  2. Does Selective Applicative Functors (`selective`) + Shake/Alga officially supersede Porcupine `ArrowFlow`, formally deprecating the Porcupine port in `REUSE_REGISTER.md` §2.12?
* **Status:** PENDING DISCUSSION

### [DECISION-002] Effect Neutrality Architecture
* **Topic:** Tagless-final capability typeclasses vs. GADT signatures.
* **Questions:**
  1. Do we define orchestration capabilities (`Worktree`, `TaskQueue`, `Sampling`) as GADT signatures in `sarutahiko-effect-signatures` per Invariant 5?
  2. Or do we introduce tagless-final typeclasses (`MonadWorktree`, `MonadTaskQueue`) interpreted into `Eff es` via adapter packages?
* **Status:** PENDING DISCUSSION

### [DECISION-003] Queue & Event Persistence Substrate
* **Topic:** Keiro/Kiroku vs. pure PostgreSQL reactor vs. in-memory/SQLite carrier.
* **Questions:**
  1. Do we commit to the `keiro` + `kiroku` + `pgmq-hs` ecosystem, build an independent Postgres event-store/reactor loop, or define an abstract interface supporting both?
  2. How do we ensure lightweight local test execution and Phase 1.5 Hokora vertical slice runs without an external PostgreSQL daemon?
* **Status:** PENDING DISCUSSION

### [DECISION-004] Wire Codecs & Serialization Invariants
* **Topic:** Strict Kogaki zero-transitive-bloat doctrine vs. Aeson.
* **Questions:**
  1. Confirm that task packets, event store records, and JSON-RPC messages strictly use `kogaki-wire` and `sarutahiko-records` (upholding `PLAN.md` Invariant 3).
  2. What format is approved for human-authored task packet specifications (YAML via custom/approved parser, Dhall, or TOML)?
* **Status:** PENDING DISCUSSION

### [DECISION-005] LLM Invocation & REPL Boundary
* **Topic:** MCP Sampling (`sampling/createMessage`) vs. direct model API clients.
* **Questions:**
  1. Is MCP Sampling the primary LLM interaction boundary for Yamaarashi, letting the host REPL manage API keys, routing, and token budgets?
  2. What role remains for `sarutahiko-model` / `utai` (local mock provider, offline fallback, or MCP sampling wrapper)?
* **Status:** PENDING DISCUSSION

### [DECISION-006] Spec Extraction & Task Subdivision Package Structure
* **Topic:** Spec extraction package location, granularity oracle, and library reuse.
* **Questions:**
  1. Package naming and path: `packages/yamaarashi-spec` vs. `packages/sarutahiko-spec`?
  2. Admitting `selective`, `recursion-schemes`, and `algebraic-graphs` into `REUSE_REGISTER.md`.
  3. Spec decomposition order: deterministic rules first (cross-target sweeps), falling back to MCP sampling for novel tasks.
* **Status:** PENDING DISCUSSION
