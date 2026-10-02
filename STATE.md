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
* **Resolution:** **RESOLVED (BLESSED)**
  1. **Package Family Layout:**
     - `packages/yamaarashi`: Neutral element streaming kernel (`Stream (Of a) m r`) and concurrency strategies.
     - `packages/yamaarashi-conduit`: Byte boundary framing (stdio JSON-RPC, line framing), process pipes, and inter-task IPC with bracketed resource cleanup.
     - `packages/yamaarashi-streamly`: In-process fused hot-loops for element/row-typed transforms.
     - `packages/yamaarashi-flow`: Free Selective + `alga` task graph orchestrator with memoization, early cutoff, and record caching (built on *Build Systems à la Carte* principles to avoid external Shake bloat).
     - `packages/yamaarashi-spec`: Spec AST, `Control.Selective.Over` VirtualTree walker, and recursive unfolding (`recursion-schemes` `ana`/`hylo`).
  2. **Arrows Deprecated:** Porcupine `ArrowFlow` and Kernmantle are officially superseded by Selective + Alga. Eliminates `OverloadedLabels` conflicts with `large-anon`.
  3. **Warts Safeguarded:**
     - Macro-DAG is strictly Selective (static); dynamic agentic fix/retry loops live inside leaf task runners (monadic/state machine).
     - Two-pass execution: Pass 1 calculates static `VirtualTree` via `Control.Selective.Over` using pure descriptors; Pass 2 executes and provisions resources.

### [DECISION-002] Effect Neutrality Architecture
* **Topic:** Tagless-final capability typeclasses vs. GADT signatures.
* **Resolution:** **RESOLVED (BLESSED)**
  1. **Standard Façade Pattern Adopted:**
     - **Base Vocabulary (Reified GADTs):** Domain operations (`Worktree`, `TaskQueue`, `Sampling`, etc.) remain defined as neutral first-order/higher-order GADTs in `packages/sarutahiko-effect-signatures`. This preserves `kagami-ita` tracing/replay, introspectability, and dual-interpreter parity testing (`sarutahiko-effect-testkit`) per `PLAN.md` Invariant 5.
     - **Consumer Façade (Tagless-Final Typeclasses):** High-level orchestrators (`yamaarashi-flow`, etc.) define and expose lightweight, open capability typeclasses (`MonadWorktree`, `MonadTaskQueue`, etc.). Orchestrator logic is written purely in terms of these typeclasses with zero dependency on `effectful` or `polysemy`.
     - **Adapter Modules:** Thin adapter packages/modules (`yamaarashi-adapter-effectful`, `yamaarashi-adapter-polysemy`) bind `Eff es` and `Sem r` to the typeclasses by forwarding method calls to the underlying GADTs.
  2. **Repo-Wide Migration Directive:**
     - The Façade Pattern becomes the project-wide effect neutrality standard.
     - Eventual sweeps will be scheduled across the repository to retrofit existing packages where GADTs or tagless-final classes were used to the exclusion of the other.

### [DECISION-003] Queue & Event Persistence Substrate
* **Topic:** Keiro/Kiroku vs. pure PostgreSQL reactor vs. in-memory/SQLite carrier.
* **Resolution:** **RESOLVED (BLESSED)**
  1. **Canonical Engine Re-Affirmed (`hashigakari`):**
     - Corrected goal drift in `AGENTIC_TASK_MANAGEMENT_DESIGN.md`. Restored `hashigakari` as the row-native, effect-governed replacement for `persistent`.
     - The **Event Store** is an append-only event log table of `large-anon` records.
     - The **Task Queue** is managed natively through event transitions and atomic transaction leases without mandatory external message brokers.
     - Projections (Kanban board, task readiness, session context, metrics) are pure reducers (folds) over the event stream.
  2. **Façade Pattern Carriers:**
     - Capabilities defined as GADTs (`EventStore`, `TaskQueue`) in `sarutahiko-effect-signatures` and tagless-final typeclasses (`MonadEventStore`, `MonadTaskQueue`) in `yamaarashi-flow`.
     - **Tier 0:** In-memory STM carrier for instant, zero-IO property testing (`sarutahiko-effect-testkit`).
     - **Tier 1:** `hashigakari-sqlite` embedded carrier for hermetic CI, local CLI, and the Phase 1.5 Hokora vertical slice (zero external daemons).
     - **Tier 2:** `hashigakari-hasql` for scaled multi-worker PostgreSQL deployments.
     - **Tier 3:** Optional `keiro`/`pgmq-hs` bridge adapter if arena interop is needed.
  3. **Hashigakari Backend Expansion Roadmap:**
     - Added MongoDB, MySQL, and Redis compatibility/feature-parity targets.
     - Placed ODBC on the protocol roadmap for enterprise/cross-engine connectivity.

### [DECISION-004] Wire Codecs & Serialization Invariants
* **Topic:** Strict Kogaki zero-transitive-bloat doctrine vs. Aeson.
* **Resolution:** **RESOLVED (BLESSED)**
  1. **Strict Zero-Aeson Doctrine Re-Affirmed:**
     - References to `aeson` in `AI_Coding_Context_Management_SOTA.md` were drift. The strict zero-transitive-bloat invariant (`PLAN.md` Invariant 3) holds across all packages.
     - All wire serialization, task packets, event records, and JSON-RPC messages use `kogaki-core` and `kogaki-wire` over `large-anon` / `sarutahiko-records`.
  2. **Dhall Evaluator Reuse & Row-Typed Bridge (`sarutahiko-format-dhall`):**
     - Per `REUSE_REGISTER.md` §2.13, we reuse the mature Dhall evaluator and bridge the marshalling boundary into `large-anon` rows.
     - Provides an effect-based row-typed interface (`evalDhallRow`) mapping Dhall's typed records directly to `large-anon` rows without rewriting the evaluator.
     - Dhall serves as the canonical typed configuration format for human-authored and generated task/pipeline specifications.

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
