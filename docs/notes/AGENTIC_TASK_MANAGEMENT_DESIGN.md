# Agentic Task Management Design

**Version:** DRAFT v0.1  
**Date:** 2026-09-27  
**Related:** NIH_PLAN.md §6, YAMAARASHI_DESIGN.md, PHASE_*_PLAN.md, AGENTS.md, HERMES_INTEGRATION.md (typed-language-model-arena)

---

## 1. Executive Summary

This document unifies the agentic task‑management substrate currently evolving in **sarutahiko** with proven patterns from **Nadeem Bitar’s AI ecosystem** (keiro, keiro‑runtime‑kenshou, kioku, kiroku, pgmq‑hs, etc.) and the **tiered agent architecture** explored in **typed‑language‑model‑arena**.  
The result is a **durable, event‑sourced, DAG‑orchestrated task system** that:

* Guarantees **machine‑checkable acceptance** for every task packet (MIT‑style correctness).  
* Survives **context resets** via the two‑file loop (`PLAN.md`/`STATE.md`).  
* Executes tasks on **isolated git worktrees** to avoid cross‑talk.  
* Persists the task ledger in an **append‑only event store** (kioku) backed by a **PGMQ‑based work‑queue** (keiro/pgmq‑hs) for reliable, at‑least‑once delivery.  
* Provides **observable DAG execution** via yamaarashi‑flow (porcupine ArrowFlow) with back‑pressure aware scheduling.  
* Exposes a **Kanban‑style UI** (hermes_cli/kanban*) that reads the event store to render boards, while workers pull ready tasks from the queue.  
* Integrates with the **typed‑language‑model‑arena tiered pipeline** (ReAct agents, tracing, multimodal tooling) as optional worker implementations.

---

## 2. Core Concepts

| Concept | Origin | Role |
|---|---|---|
| **Hermetic Task Packet (TP)** | sarutahiko (PHASE_*_PLAN.md) | Atomic unit of work with explicit pre‑/post‑conditions and verification command. |
| **Two‑File Loop (PLAN.md / STATE.md)** | sarutahiko (AGENTS.md) | Separates immutable spec from mutable operational frontier; survives context resets. |
| **Yamaarashi‑Flow / Porcupine ArrowFlow** | sarutahiko (YAMAARASHI_DESIGN.md) | Declarative DAG orchestrator; tasks are nodes, edges encode data/control dependencies. |
| **Kanban Swarm Service** | sarutahiko (NIH_PLAN.md §6) | Runtime service that maintains a task board, dispatches ready tasks to workers. |
| **PGMQ‑Based Work Queue** | Nadeem Bitar (pgmq‑hs, keiro‑runtime‑kenshou) | Durable, FIFO queue with exactly‑once semantics (via transactional dequeue) for task dispatch. |
| **Kioku Event Store** | Nadeem Bitar (kioku) | Append‑only log of all task lifecycle events (claimed, started, completed, failed). Provides replay‑able audit trail. |
| **Kiorku Event Streams** | Nadeem Bitar (kiroku) | Typed, partitioned streams derived from the event store for real‑time dashboards and alerting. |
| **Keiro Timers & Workflows** | Nadeem Bitar (keiro, keiro‑runtime‑kenshou) | Declarative timers, delayed retries, and workflow definitions (e.g., exponential back‑off for failed tasks). |
| **Typed‑Language‑Model‑Arena Tiers** | typed‑language‑model‑arena (shikumi‑campaign tiers) | Optional worker implementations: tier‑2 combinators, tier‑3 optimizers, tier‑4 trace/replay, tier‑5 ReAct agents, tier‑6 CLI, tier‑7 streaming/multimodal. |
| **Observability (Kagami‑Ita)** | sarutahiko (OBSERVABILITY_DESIGN.md) | Events from kioku feed tracing, metrics, and replay for debugging agent runs. |

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
          |                           |                   |   linter, etc.)|
          |                           |                   +------------------+
          |                           |                           |
          |                           v                           v
          |                   +------------------+       +------------------+
          |                   |  Task Ledger     |       |  Work Queue (PGMQ)|
          |                   |  (kioku)         |<------|  (durable FIFO)  |
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
          |                   |  Kiorku Streams  |       |  Scheduler (Yama)|
          |                   |  (derived views) |       |  (porcupine DAG) |
          |                   |  - task‑metrics  |       |  - determines   |
          |                   |  - replay topics |       |    ready TPs    |
          |                   +------------------+       +------------------+
          |                           ^                           |
          |                           |                           |
          +---------------------------+---------------------------+
                                      |
                              +------------------+
                              |  Kanban UI (CLI)|
                              |  (hermes_cli/kanban*) |
                              +------------------+
                                      |
                              +------------------+
                              |  Observation &  |
                              |  Replay (Kagami)|
                              +------------------+
```

### 3.1. Task Lifecycle (Events stored in kioku)

1. **TP_CREATED** – when a new task packet is added to `PLAN.md` (or via external issue).  
2. **TP_ENQUEUED** – the scheduler (yamaarashi‑flow) places the TP onto the PGMQ work‑queue when all upstream dependencies are satisfied.  
3. **TP_CLAIMED** – a worker atomically dequeues the task from PGMQ and records claim (includes worker ID, worktree path, timestamp).  
4. **TP_STARTED** – worker begins execution (calls `cabal build`, sets up environment).  
5. **TP_VERIFYING** – worker runs the prescribed verification command (test suite, linter, golden‑fixture diff).  
6. **TP_COMPLETED** – verification succeeded (exit‑code 0); worker commits changes with proper Git trailers (`Assisted-by:`, `Closes: TP-…`).  
7. **TP_FAILED** – verification failed; worker may trigger a **Keiro retry workflow** (exponential back‑off, dead‑letter queue after N attempts).  
8. **TP_CANCELLED** – manual cancellation or superseded by a newer spec.

All events are immutable, append‑only, and globally ordered by kioku’s logical clock.

### 3.2. Worker Isolation

* Each claimed task receives a fresh **git worktree** linked to the current branch, ensuring a clean sandbox.  
* The worktree is scoped to the task’s required packages (determined from `PLAN.md`/`STATE.md` and the task’s cabal‑project snippet).  
* After completion (or final failure) the worktree is removed; only the committed changes survive.

### 3.3. Integration with Typed‑Language‑Model‑Arena

* Workers may be instantiated as **tier‑5 ReAct agents** (from `typed-language-model-arena/shikumi‑campaign/tier5/Tier5ReActAgent.hs`) when the task admits exploratory, tool‑using behavior (e.g., prototyping a new effect signature).  
* For deterministic, compile‑time‑bound tasks (e.g., implementing a new Record field), workers revert to the standard **hermes‑agent** CLI (level‑2 agentic CLI with rubric).  
* Tier‑4 trace/replay (`Tier4TraceReplay.hs`) enables deterministic re‑execution of a failed task using the recorded event log, aiding debugging.  
* Tier‑6/7 provide optional CLI or streaming interfaces for operators to inspect the task ledger in real time.

---

## 4. Contrast with Prior Sarutahiko Design

| Feature | Prior Design | Enhanced Design (this doc) |
|---|---|---|
| **Task Queue** | In‑memory dispatcher within the kanban swarm (volatile). | Durable PGMQ‑based FIFO queue with transactional dequeue; survives Hermes restarts. |
| **Task Ledger** | Implicit in Git commits + `STATE.md`. | Explicit append‑only event store (kioku) with kiorku streams for observability. |
| **Retry / Back‑off** | Ad‑hoc manual re‑run. | Declarative Keiro workflows (timers, exponential back‑off, dead‑letter). |
| **Worker Isolation** | None; tasks run in the same Hermes process (risk of state leakage). | Isolated git worktrees per task, guaranteeing hermeticity. |
| **Observability** | Logs + manual inspection. | Structured events → kioku → kiorku → Prometheus/Grafana + Kagami‑Ita replay. |
| **Agent Variety** | Primarily Hermes agentic CLI (level‑2). | Pluggable worker tiers (ReAct, tracing, streaming) from typed‑language‑model‑arena. |
| **DAG Orchestration** | Yamaarashi‑flow (porcupine) already present. | Unchanged, but now tightly coupled to PGMQ enqueue/dequeue semantics. |
| **Verification Gating** | Post‑run test check (manual). | Enforced by worker before emitting `TP_COMPLETED`; failure triggers retry workflow. |

---

## 5. Implementation Roadmap (Task Packets)

| TP ID | Description | Acceptance Criteria |
|---|---|---|
| TP‑ATM‑0.1 | Add `kioku` and `pgmq-hs` as dependencies in `sarutahiko.cabal` and `cabal.project`. | Builds successfully; `cabal test` passes for existing suites. |
| TP‑ATM‑0.2 | Define the event schema in `Sarutahiko/Task/Event.hs` (claimed, started, completed, failed, etc.) using `Record`-based payloads. | Round‑trip CBOR/JSON via `kogaki-wire` works; property‑test serialization. |
| TP‑ATM‑0.3 | Implement `TaskQueue.PGMQ` wrapper offering `enqueueTask :: TaskId -> IO ()` and `dequeueTask :: IO (Maybe (TaskId, TaskPayload))` with transactional semantics. | Queue FIFO under concurrent producers/consumers; no lost tasks under process crash (tested via `kill -9`). |
| TP‑ATM‑0.4 | Extend `Yamaarashi.Flow.Scheduler` to enqueue ready TPs onto the PGMQ when all upstream edges are satisfied. | DAG execution respects dependencies; tasks appear in queue only after predecessors emit `TP_COMPLETED`. |
| TP‑ATM‑0.5 | Implement `Worker.ClaimLoop` that: (a) spawns a git worktree, (b) dequeues a task, (c) records `TP_CLAIMED`, (d) runs build → verify → commit or retry. | End‑to‑end execution of a sample TP (e.g., add a trivial Record field) ends with a git commit and `TP_COMPLETED` event. |
| TP‑ATM‑0.6 | Hook the Kanban UI (`hermes_cli/kanban*`) to read from kioku (via a read‑only projection) and display columns: **Backlog**, **Ready**, **In‑Progress**, **Done**, **Failed**. | UI updates in real‑time as events are appended; matches internal queue state. |
| TP‑ATM‑0.7 | Integrate Keiro retry workflow: after `TP_FAILED`, schedule a retry with back‑off (1s, 2s, 4s, …) up to 5 attempts, then move to Dead‑Letter queue. | Failed tasks automatically retry; after max attempts they appear in DLQ and alert via kiorku stream. |
| TP‑ATM‑0.8 | Provide an optional worker factory that can instantiate a tier‑5 ReAct agent from `typed-language-model-arena` when a task is flagged `exploratory:true` in its metadata. | Exploratory tasks are handled by ReAct agent; deterministic tasks use standard worker. |
| TP‑ATM‑0.9 | Add observability hooks: emit task‑level metrics (latency, retry count) to a kiorku stream; expose via Prometheus endpoint. | Metrics scrapable; tracing via Kagami‑Ita reproduces a task’s execution from event log. |
| TP‑ATM‑1.0 | Write documentation and update `AGENTS.md` to reflect the new two‑file loop guarantees (now with durable ledger). | Documentation renders without warnings; `make doc-check` passes. |

Each TP follows the **hermetic** contract:  

* **Preconditions:** Reads `PLAN.md`/`STATE.md`, verifies DAG state.  
* **Postconditions:** Either (a) new git commit with correct trailers and `TP_COMPLETED` event, or (b) `TP_FAILED` event plus optional retry schedule.  
* **Verification:** Must run the associated test/linter command and observe exit‑code 0 before emitting success.

---

## 6. Relationship to Nadeem Bitar’s AI Ecosystem

| Bitar Component | Use in This Design | Rationale |
|---|---|---|
| **pgmq‑hs** | Durable FIFO work queue with transactional dequeue. | Guarantees exactly‑once delivery even if worker crashes mid‑task. |
| **kioku** | Append‑only event store for task lifecycle events. | Provides immutable audit trail, enables replay, supports temporal queries. |
| **kiorku** | Typed streams derived from kioku for real‑time dashboards and alerting. | Decouples observation from storage; allows multiple consumers (UI, metrics, alerting). |
| **keiro / keiro‑runtime‑kenshou** | Declarative timers and retry workflows (exponential back‑off, dead‑letter). | Removes ad‑hoc sleep loops; provides observable retry policies. |
| **mori / mori‑schema** (not directly used but referenced) | Potential future schema evolution for event versions. | Ensures forward/backward compatibility as the event schema evolves. |
| **settei** (configuration) | Could be used to parameterize queue sizes, retry limits, worker counts. | Externalizes tuning without code changes. |
| **shikumi / shikumi‑campaign** | Source of tiered agent implementations (ReAct, tracing, etc.) used as optional workers. | Leverages existing, well‑tested agent scaffolding from the arena. |

---

## 7. Relationship to Typed‑Language‑Model‑Arena

The arena supplies **pluggable worker strata** that can be selected per‑task based on metadata:

* **Tier‑2 Combinators** – pure functional pipelines (good for data‑transform TPs).  
* **Tier‑3 Optimizers** – equivalence‑checking or property‑based validation workers.  
* **Tier‑4 Trace/Replay** – enables deterministic re‑run of a failed TP using the recorded event log (useful for debugging flaky tests).  
* **Tier‑5 ReAct Agent** – general‑purpose, tool‑using agent for exploratory or ill‑specified TPs (e.g., prototyping a new effect signature).  
* **Tier‑6 CLI** – standard hermes‑agent CLI with rubric (default worker for most TPs).  
* **Tier‑7 Streaming / Multimodal** – workers that need to ingest/produce audio, video, or live data streams (e.g., TPs that augment a model with new modality).  

The worker factory reads a flag `workerTier` from the task’s metadata (stored in the event payload) and instantiates the appropriate stratum.

---

## 8. Open Questions & Future Work

1. **Exactly‑once semantics across worker crash:**  
   PGMQ provides transactional dequeue, but we must ensure that the side‑effects (build, test, commit) are either fully committed or rolled back on crash. Current approach relies on the idempotency of the verification step and the ability to re‑run from scratch in a fresh worktree. Investigate integrating with `keiro`’s durable timers to trigger a cleanup rollback on failure.

2. **Event store compaction:**  
   As the kioku log grows, we may need snapshotting + compaction (similar to event‑sourcing snapshots). Consider integrating `mori`’s B‑tree for periodic snapshots of the task ledger state.

3. **Multi‑repository task packets:**  
   Currently tasks are confined to the sarutahiko monorepo. Future work could extend the ledger to track cross‑repo dependencies (e.g., a task in `sarutahiko-mcp` that depends on a version bump in `sarutahiko-records`). This would require a global DAG across repositories, possibly using `keiro`‑based distributed locks.

4. **Security & sandboxing:**  
   Worktree isolation prevents in‑process state leakage but does not limit filesystem or network access. Explore integrating with `seihou` (capability‑based sandbox) or `keiki` to restrict worker capabilities per task.

5. **Human‑in‑the‑loop escalation:**  
   For tasks that repeatedly fail after max retries, the system could automatically create a GitHub issue (via `openapi-hs` or `okf‑kit`) and notify a maintainer through the `kiorku` alert stream.

---

## 9. References

* **nih_plan.md** – Runtime services, kanban swarm, pure reducers.  
* **yamaarashi_design.md** – Streaming kernel, yamaarashi‑flow, porcupine ArrowFlow.  
* **phase_*_plan.md** – Hermetic task packet format and acceptance criteria.  
* **agents.md** – Staged Context Reset & Two‑File Loop.  
* **hermes_cli/kanban\*.py** – Existing Kanban UI and dispatcher.  
* **typed‑language‑model‑arena/** – Tiered agent implementations (shikumi‑campaign).  
* **keiro**, **keiro‑runtime‑kenshou**, **kioku**, **kiorku**, **pgmq‑hs** – Nadeem Bitar’s libraries (repos cloned under `~/src/`).  
* **obsrvability_design.md** – Kagami‑Ita event tracing and replay.  

---  
*Authored by Hermes Agent (model: gemini‑3.8‑flash via geminidirect).  
Assisted-by: gemma4:31B (Gemini) for background synthesis.*