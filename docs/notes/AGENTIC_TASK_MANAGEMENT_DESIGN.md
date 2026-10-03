# Agentic Task Management Design

**Version:** REVISED v0.3 · 2026-10-03 (Reconciled & Blessed)  
**Related:** `NIH_PLAN.md` §6, `YAMAARASHI_DESIGN.md`, `HASHIGAKARI_DESIGN.md`, `LLM_SUBSTRATE_DESIGN.md`,
`STATE.md` (Decisions 1–6), `REUSE_REGISTER.md` (§2.12, §2.25, §2.26, §2.27), `AGENTS.md`

---

## 1. Executive Summary

This document defines the agentic task-management substrate in **sarutahiko**. It reconciles earlier design
explorations with the canonical architecture established across `HASHIGAKARI_DESIGN.md`, `YAMAARASHI_DESIGN.md`,
and the repository's inviolable invariants (`PLAN.md`):

* Guarantees **machine-checkable acceptance** for every task packet (MIT-style correctness), including
  formal verification when required (via tessera/telix/pgcl/etc. harnesses).
* Survives **context resets** via the two-file loop (`PLAN.md`/`STATE.md`), which acts as an operational
  frontier projecting from a durable, row-typed event ledger.
* Executes tasks on **isolated git worktrees** to eliminate cross-talk.
* Persists the task ledger in an **append-only event store table** natively governed by **`hashigakari`**
  (the row-native, effect-based successor to `persistent`), utilizing `large-anon` records and `kogaki-wire` codecs.
* Manages task dispatch through **atomic transaction leases** over the event stream, providing durable FIFO
  delivery without mandating external message broker daemons (`pgmq-hs`).
* Orchestrates workflows via **`yamaarashi-flow`** (Selective Applicative Functors over `alga` DAGs under
  *Build Systems à la Carte* principles, replacing Porcupine's arrow-based engine).
* Implements the **Façade Pattern** for effect neutrality: open capability typeclasses (`MonadTaskQueue`,
  `MonadEventStore`, `MonadWorktree`) backed by neutral GADT signatures in `sarutahiko-effect-signatures`.
* Integrates **`utai`** as the canonical LLM substrate, with **MCP Sampling (`utai-mcp`)** available as an
  additional backend to delegate model execution to host REPLs (Hermes, Claude Code) when embedded.

---

## 2. Core Concepts

| Concept | Origin / Implementation | Role |
|---|---|---|
| **Hermetic Task Packet (TP)** | sarutahiko (`TASK_PACKET_BEST_PRACTICES.md`) | Atomic unit of work with fail-fast verification steps, minimal buildable skeletons, and explicit pre-/post-conditions. |
| **Two-File Loop (`PLAN.md` / `STATE.md`)** | sarutahiko (`AGENTS.md`) | Durable operational frontier surviving context resets; projects active task state from the event ledger. |
| **Yamaarashi-Flow (Selective DAG)** | sarutahiko (`YAMAARASHI_DESIGN.md`) | Two-pass Selective Applicative workflow orchestrator; ahead-of-time `VirtualTree` over-approximation and *Build Systems à la Carte* scheduling. |
| **Hashigakari Event Store** | sarutahiko (`HASHIGAKARI_DESIGN.md`) | Append-only event log table of `large-anon` records; zero Template Haskell; runs under `Resource` / `StreamingDB` effects. |
| **Native Task Queue** | sarutahiko (`hashigakari`) | FIFO dispatch and visibility timeouts via atomic row transitions (`UPDATE ... RETURNING` in Postgres; SQLite transactions). |
| **Façade Effect Architecture** | sarutahiko (`STATE.md` Decision 2) | Monad-agnostic capability typeclasses in orchestrator modules, delegating to dual-interpreted GADTs (`sarutahiko-effect-signatures`). |
| **Utai & MCP Sampling** | sarutahiko (`LLM_SUBSTRATE_DESIGN.md`) | Direct provider row codecs (`utai-openai`, `utai-anthropic`) with MCP Sampling (`utai-mcp`) for host-delegated generation. |
| **Pure State Projections** | sarutahiko (`NIH_PLAN.md` §6) | Kanban boards, task readiness, and session histories are pure reducers (folds) over the event stream. |
| **Formal Verification Harnesses** | arena (`VERIFICATION_LADDER.md`) | External verification drivers (tessera, telix, pgcl) invoked as machine-checked acceptance steps. |

---

## 3. Architecture Overview

```
+----------------------+       +---------------------+       +---------------------+
|  PLAN.md (Spec)      | --->  |  STATE.md (Frontier)| --->  |  Worker Pool        |
|  (immutable roadmap) |       |  (next TP, blockers)|       |  (isolated worktree)|
+----------------------+       +---------------------+       +---------------------+
          ^                           ^                           ^
          |                           |                           |
          |                           |                           v
          |                           |                   +------------------+
          |                           |                   |  Verification   |
          |                           |                   |  (cabal test,   |
          |                           |                   |   linter, VF)   |
          |                           |                   +------------------+
          |                           |                           |
          |                           v                           v
          |                   +------------------+       +------------------+
          |                   |  Task Ledger     |       |  Task Queue      |
          |                   |  (hashigakari)   |<------|  (atomic leases) |
          |                   |  - events:       |       |  - enqueue:      |
          |                   |    * TP_CLAIMED  |       |    NEW_TASK      |
          |                   |    * TP_STARTED  |       |  - dequeue:      |
          |                   |    * TP_COMPLETED|       |    READY_TASK    |
          |                   |    * TP_FAILED   |       +------------------+
          |                   +------------------+               |
          |                           ^                           |
          |                           |                           |
          |                           |                           v
          |                   +------------------+       +------------------+
          |                   |  Pure Reducers   |       |  Scheduler       |
          |                   |  (state folds)   |       |  (yamaarashi-flow|
          |                   |  - kanban view   |       |   selective DAG) |
          |                   |  - readiness     |       +------------------+
          |                   +------------------+               |
          |                           ^                           |
          |                           |                           |
          +---------------------------+---------------------------+
                                      |
                              +------------------+
                              |  Kanban UI (TUI) |
                              |  (pure view)     |
                              +------------------+
                                      |
                              +------------------+
                              |  Observation &   |
                              |  Replay (Kagami) |
                              +------------------+
```

### 3.1. Task Lifecycle Events
All task events are immutable `large-anon` records serialized via `kogaki-wire`:
1. **`TP_CREATED`** — Task packet declared in specification or Dhall manifest.
2. **`TP_ENQUEUED`** — Scheduler places the task into the ready state when its upstream Selective dependencies evaluate to complete.
3. **`TP_CLAIMED`** — Worker atomically claims task lease (recording worker ID, isolated worktree path, lease deadline).
4. **`TP_STARTED`** — Worker provisions worktree, verifies toolchain skeleton, and begins execution.
5. **`TP_VERIFYING`** — Worker executes machine-checked verification commands (build check, test suite, formal proof harness).
6. **`TP_COMPLETED`** — Verification returned exit-code 0; worker commits git changes with kernel trailers (`Assisted-by:`).
7. **`TP_FAILED`** — Verification failed; worker triggers back-off retry loop or dead-letter escalation.
8. **`TP_CANCELLED`** — Task manually aborted or pruned by Selective early cutoff.

### 3.2. Worker Isolation & Worktree Lifecycle
* Every claimed task executes in a dedicated, isolated **git worktree** (`git worktree add --detach <path> <commit>`).
* Static resource requirements (`VirtualTree`) computed during `yamaarashi-spec` Pass 1 dictate required toolchains and sandbox policies.
* Upon completion or final failure, the worktree is cleaned up (`git worktree remove --force`), ensuring zero cross-task pollution.

---

## 4. Reconciliation of Persistence & Goal Drift

Earlier drafts (`v0.2`) drifted toward external dependencies (`pgmq-hs`, `kiroku`, `keiro`), introducing mandatory
external PostgreSQL daemons and nominal schemas that conflicted with Sarutahiko's clean-slate invariants.
This has been reconciled under **`hashigakari`** and the **Façade Pattern**:

| Feature | Interim v0.2 Draft (Drifted) | Reconciled v0.3 Canonical Architecture |
|---|---|---|
| **Persistence Engine** | External `kiroku` event store. | **`hashigakari`** row-polymorphic event store table (`large-anon` records). |
| **Task Queue** | External `pgmq-hs` (requiring live Postgres + PGMQ extension). | **Native atomic transaction leases** in `hashigakari` (zero external broker). |
| **Carrier Tiering** | Monolithic Postgres dependency. | **Tiered Façade:** In-memory STM (Tier 0), `hashigakari-sqlite` (Tier 1 for local/Hokora/CI), `hashigakari-hasql` (Tier 2 for Postgres). Optional Tier-3 `pgmq` adapter. |
| **DAG Orchestration** | Porcupine `ArrowFlow`. | **`yamaarashi-flow` (Selective Functors + `alga`)**; avoids `OverloadedLabels` conflicts with `large-anon`. |
| **Wire Codecs** | Aeson (drift). | **`kogaki-wire`** hand-rolled zero-dependency row codecs (`PLAN.md` Invariant 3). |
| **LLM Access** | Unspecified / hardcoded external calls. | **`utai`** direct provider row codecs + **MCP Sampling (`utai-mcp`)** for host REPL integration. |

---

## 5. Implementation Roadmap (Task Packets)

| TP ID | Description | Acceptance Criteria |
|---|---|---|
| **TP-ATM-0.1** | Define `EventStore` and `TaskQueue` GADT signatures in `sarutahiko-effect-signatures`. | Zero dependencies; defines typed event record envelopes and queue lease primitives. |
| **TP-ATM-0.2** | Author STM in-memory carriers for `EventStore` and `TaskQueue` in `sarutahiko-effect-testkit`. | Dual-interpreter parity tests pass 100 Hedgehog trials for atomic enqueue, claim, and completion. |
| **TP-ATM-0.3** | Implement `hashigakari-sqlite` carrier for `EventStore` and `TaskQueue`. | Hermetic event append and atomic lease dequeue verified under SQLite WAL with zero external daemons. |
| **TP-ATM-0.4** | Implement tagless `MonadTaskQueue` / `MonadEventStore` façade classes in `yamaarashi-flow`. | Adapter packages (`yamaarashi-adapter-effectful`, `yamaarashi-adapter-polysemy`) bind `Eff es` and `Sem r` cleanly. |
| **TP-ATM-0.5** | Implement `Worker.WorktreeLoop` executing tasks inside isolated git worktrees. | Automatic worktree creation, fail-fast toolchain check, verification command execution, and clean teardown. |
| **TP-ATM-0.6** | Implement pure reducer for Kanban board state projection. | Pure function `[EventRecord] -> KanbanState`; accurately projects Backlog, Ready, In-Progress, and Done columns. |
| **TP-ATM-0.7** | Integrate `utai-mcp` Sampling backend for agentic synthesis tasks. | Worker dispatches synthesis prompts via MCP `sampling/createMessage` to host REPL without embedding vendor SDKs. |
| **TP-ATM-0.8** | Integrate formal verification harness invocation (`VERIFICATION_LADDER.md`). | Worker recognizes formal proof verification commands (`tessera`, `telix`) and gates `TP_COMPLETED` on exit-code 0. |

---

## 6. References

* **`YAMAARASHI_DESIGN.md`** — Selective workflow orchestrator, Build Systems à la Carte, streaming mixture.
* **`HASHIGAKARI_DESIGN.md`** — Row-native database DSL and execution stack over large-anon.
* **`LLM_SUBSTRATE_DESIGN.md`** — Utai model substrate, canonical request renderer, and MCP sampling.
* **`TASK_PACKET_BEST_PRACTICES.md`** — Early toolchain verification and minimal buildable skeletons.
* **`REUSE_REGISTER.md`** — Standing ledger of library reuse and reimplementation decisions.
* **`PLAN.md` & `STATE.md`** — Architectural invariants and active operational frontier.