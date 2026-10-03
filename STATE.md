# STATE.md — Current Operational Frontier & Immediate Task Queue

Status: LIVING · Updated at every turn/milestone boundary before session reset.  
Audience: Human maintainers and AI coding assistants (Antigravity, Hermes, Claude Code, Aider).  
Reset Rule: Fresh sessions read `PLAN.md` for roadmap invariants and this file for ground truth.

---

## 1. Operational Metadata

* **Timestamp:** 2026-10-03T14:20:00+02:00
* **Git Branch:** `nadia.chambers/yamaarashi-redesign`
* **HEAD Commit:** `1b7ce19` (*Introduce LogicalString and UTF-8 codecs in kogaki-core*)
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
* **Resolution:** **RESOLVED (BLESSED)**
  1. **Canonical Substrate Retained (`utai` / `sarutahiko-model`):**
     - `utai` remains the canonical LLM substrate per `LLM_SUBSTRATE_DESIGN.md` (Noh naming: 謡, the chant).
     - Provides the neutral `ModelAPI` GADT effect signature in `sarutahiko-effect-signatures` / `utai`, canonical request renderer for cache/replay simulation, and direct row-typed wire codecs over `kogaki-wire`.
     - Direct backends: `utai-openai`, `utai-anthropic`, `utai-local` (CLI execution via `Process` effect), and `utai-mock` (deterministic testkit for Phase 1.5 Hokora).
  2. **MCP Sampling as an Additional ModelAPI Backend (`utai-mcp`):**
     - MCP Sampling (`sampling/createMessage`) is integrated as an additional execution backend alongside direct provider transports, rather than replacing `utai`.
     - When embedded in an MCP host (Hermes, Claude Code, etc.), `ModelAPI` can route generation requests through MCP sampling to leverage the host's configured models, API keys, and token budgets.
     - When running standalone (headless daemon, CLI, hermetic tests), `utai` runs directly via its provider backends or mock carrier. Zero REPL lock-in.

### [DECISION-006] Spec Extraction & Task Subdivision Package Structure
* **Topic:** Spec extraction package location, granularity oracle, and library reuse.
* **Resolution:** **RESOLVED (BLESSED)**
  1. **Package Scope & Placement (`packages/yamaarashi-spec`):**
     - Sits within the Yamaarashi package family as `packages/yamaarashi-spec`.
     - Models the specification AST, runs `Control.Selective.Over` for static `VirtualTree` resource over-approximation, and pairs code targets with verification harnesses.
  2. **Library Admissions (`REUSE_REGISTER.md`):**
     - `selective`: ADOPTED for selective workflow construction and ahead-of-time static dependency analysis.
     - `algebraic-graphs` (`alga`): ADOPTED for pure algebraic representation and scheduling of task DAGs.
     - `recursion-schemes`: ADOPTED for corecursive task unfolding (`ana`/`hylo`) and hierarchical decomposition with `IsPrimitive` granularity scoring.
  3. **Decomposition Strategy:**
     - Deterministic rule engines first (zero-token cross-target sweeps, toolchain matrices, test splits).
     - Fallback to LLM planner via `utai` / MCP sampling only for novel, exploratory synthesis tasks.

---

## 5. Recent Completed Actions (Design Reconciliation & Bootstrap Phase)

1. **Reconciled `REUSE_REGISTER.md`:**
   - Admitted `selective` (§2.25), `algebraic-graphs` / `alga` (§2.26), and `recursion-schemes` (§2.27).
   - Updated Porcupine / Kernmantle (§2.12) to record its superseding by Selective + Alga.
2. **Overhauled `YAMAARASHI_DESIGN.md`:**
   - Codified the two-pass Selective Applicative workflow orchestrator, Build Systems à la Carte scheduler, streaming mixture (`yamaarashi-conduit`, `yamaarashi-streamly`), `yamaarashi-spec`, and the 4 wart safeguards.
3. **Reconciled `AGENTIC_TASK_MANAGEMENT_DESIGN.md`:**
   - Corrected goal drift: restored `hashigakari` as the canonical row-native persistence engine, incorporated the Façade Pattern, Selective workflow DAG, and `utai` + MCP sampling.
4. **Synchronized `NIH_PLAN.md` & `PLAN.md`:**
   - Updated §3.5 and §3.6 layering contracts, Phase 4 package entries, and Invariants 4 & 5 to codify Selective workflow DAGs and the Façade Pattern.
5. **Established Bootstrap Task Packets Series (`b54027b`):**
   - Added `yamaarashi-01-skeletons.yaml` through `yamaarashi-05-dogfood-harness.yaml`.
   - Cleaned obsolete packets and preserved `fix-kogaki-wire-lexer-nonempty.yaml`.
6. **Executed Packet 01 — Yamaarashi Package Skeletons [TASK-003]:**
   - Created minimal cabal packages and stub exposed modules for `yamaarashi`, `yamaarashi-conduit`, `yamaarashi-streamly`, `yamaarashi-flow`, and `yamaarashi-spec`.
   - Registered all 5 packages in `cabal.project`.
   - Verified clean toolchain build under GHC 9.12.2 / GHC2024 via `cabal v2-build packages/yamaarashi*` with zero errors and zero warnings (`-Wall -Werror`).
7. **Executed Packet 02 — Yamaarashi Streaming Kernel & Boundary Adapters [TASK-004]:**
   - Implemented church-encoded (CPS) free-monad streaming kernel `Stream (Of a) m r` with O(1) left-associated binds via Codensity, core combinators (`yield`, `await`, `inspect`, `next`, `fold`, `fold_`, `foldM`, `map`, `filter`, `take`, `drop`, `toList_`, etc.), existential `unfoldStepper` unrolling, and typed concurrency strategy wrappers (`Serial`, `Async`, `Interleaved`, `Parallel`) in `packages/yamaarashi`.
   - Implemented boundary framing adapters (`streamToConduit`, `conduitToStream`, `linesConduit`, `jsonRpcFraming`, `bracketResource`, `bracketStream`) in `packages/yamaarashi-conduit`.
   - Implemented fused in-process hot-loop embedding (`toStreamly`, `fromStreamly`, `foldRows`, `foldRowsM`) over `streamly-core` in `packages/yamaarashi-streamly`.
   - Added Tasty/Hedgehog property test suite in `packages/yamaarashi/test/Spec.hs` verifying stream composition, folds, short-circuiting, and parity with `drainStepper` (all 8 properties passed with 100 iterations each).
   - Verified clean build and zero warnings (`-Wall -Werror`) across all packages.
8. **Executed Packet 03 — Yamaarashi Selective Flow & Build Systems à la Carte Scheduler [TASK-005]:**
   - Implemented Selective workflow AST, `TaskNode`, and `TaskGraph` over `algebraic-graphs` (`alga`) in `packages/yamaarashi-flow/src/Yamaarashi/Flow/Types.hs`.
   - Implemented clean-slate *Build Systems à la Carte* execution scheduler with topological ordering, memoization at `$_` locations, and early cutoff in `packages/yamaarashi-flow/src/Yamaarashi/Flow/Scheduler.hs`.
   - Defined canonical `Worktree` and `TaskQueue` GADT effect signatures in `packages/sarutahiko-effect-signatures`.
   - Defined open tagless capability typeclasses (`MonadWorktree`, `MonadTaskQueue`) in `packages/yamaarashi-flow/src/Yamaarashi/Flow/Capability.hs` under the project-wide Façade Pattern.
   - Added Tasty/Hedgehog test suite in `packages/yamaarashi-flow/test/Spec.hs` verifying mid-run resumption (A & B skipped from cache, only C executed), early cutoff (identical output hash prunes downstream nodes), cascading changes, and cycle rejection (all 4 tests passing with 100 iterations each).
    - Verified clean compilation across all packages with zero warnings.
9. **Executed Packet 04 — Yamaarashi Spec Extraction & Task Subdivision [TASK-006]:**
   - Implemented specification AST, inert resource descriptors, and `VirtualTree` in `packages/yamaarashi-spec/src/Yamaarashi/Spec/Types.hs`.
   - Implemented Pass 1 ahead-of-time static analysis via `Control.Selective.Over` in `packages/yamaarashi-spec/src/Yamaarashi/Spec/VirtualTree.hs`, computing strict union over-approximations across conditional branches with zero IO.
   - Implemented corecursive task subdivision via `recursion-schemes` (`hylo`) with `IsPrimitive` granularity scoring and task packet serialization in `packages/yamaarashi-spec/src/Yamaarashi/Spec/Subdivide.hs`.
   - Added Tasty/Hedgehog property test suite in `packages/yamaarashi-spec/test/Spec.hs` (3/3 property tests passing with 100 runs each).
   - Verified all 15 property tests across `yamaarashi`, `yamaarashi-flow`, and `yamaarashi-spec` pass with zero warnings under `-Wall -Werror`.
10. **Executed Packet 05 — Standalone Yamaarashi Runner & First Dogfood Milestone [TASK-007]:**
    - Delivered standalone CLI executable `yamaarashi-exec` in `packages/yamaarashi-flow/app/Main.hs` supporting `run <packet.yaml>`.
    - Registered `typed-process` in `docs/registers/REUSE_REGISTER.md` §2.28 and integrated strongly typed process supervision for git worktree isolation.
    - Connected SQLite event store ledger recording task lifecycle events (`TASK_STARTED`, `WORKTREE_PROVISIONED`, `STEP_STARTED`, `STEP_EXECUTED`, `VERIFICATION_STARTED`, `VERIFICATION_PASSED`, `COMMIT_CREATED`, `TASK_COMPLETED`, `WORKTREE_TEARDOWN`) into `.yamaarashi/events.sqlite3`.
    - Successfully executed the dogfood target `docs/task_packets/fix-kogaki-wire-lexer-nonempty.yaml` through `yamaarashi-exec`:
      1. Spawned isolated worktree at `/home/nyc/src/sarutahiko-wt-fix-kogaki-wire-lexer-nonempty` on branch `yamaarashi/task-fix-kogaki-wire-lexer-nonempty`.
      2. Applied safe, non-empty refactoring to `Kogaki.Wire.Json.Lexer.hs` via `BSC.uncons`.
      3. Passed all 3 verification gates: clean compilation under `-Wall -Werror`, all 14 `test-kogaki-wire` invariant tests passing, and grep audit verifying zero calls to `BSC.head`, `BS.tail`, or `!!` remain.
      4. Generated commit `661e832` with proper attribution trailers and fast-forward merged it into HEAD.
      5. Bracketed cleanup cleanly unmounted and destroyed the isolated worktree directory and temporary branch.
    - Verified all test suites across `kogaki-wire`, `yamaarashi`, `yamaarashi-flow`, and `yamaarashi-spec` pass 100% with zero warnings.
    - **Yamaarashi Orchestrator Bootstrap Series (Packets 01–05) is now COMPLETE!**
11. **Adapted Roadmap Task Packets for Yamaarashi Execution [TASK-008]:**
    - Audited, rewritten, and structured the entire sequence of roadmap task packets in `docs/task_packets/` conforming to `TASK_PACKET_BEST_PRACTICES.md` and the 6 blessed design decisions:
      * `phase1.5-01-hashigakari-sqlite.yaml`: Embedded SQLite carrier for `EventStore` and `TaskQueue` under the Façade Pattern (DECISION-002, DECISION-003), replacing legacy `setup-keiro-state.yaml`.
      * `phase1.5-02-utai-mock.yaml`: LLM substrate `utai` with `ModelAPI` GADT and `utai-mock` deterministic replay carrier for Hokora slice testing (DECISION-005).
      * `phase1.5-03-hokora-slice.yaml`: Phase 1.5 autonomous turn vertical slice proving the skinny spine protocol (`HOKORA_SPEC.md`).
      * `refactor-logical-string.yaml`: Structured `LogicalString` and UTF-8 codecs conforming to `KOGAKI_DESIGN.md` §3.
      * `phase2-agent-core.yaml`: Full agent core ReAct turn loop, tool registry, and session persistence.
      * `phase3-surfaces-codeintel.yaml`: TUI, Gateway, ACP surfaces, and ctags-compatible tag extractor.
12. **Reorganized Repository into Component-Grouped Monorepo Structure [TASK-009-PREP]:**
    - Grouped all packages under `packages/` into their canonical Noh component families under Pattern A (`packages/<component>/<full-package-name>`):
      * `packages/kogaki/`: `kogaki-core`, `kogaki-wire`
      * `packages/yamaarashi/`: `yamaarashi`, `yamaarashi-conduit`, `yamaarashi-streamly`, `yamaarashi-flow`, `yamaarashi-spec`
      * `packages/sarutahiko/`: `sarutahiko-fields`, `sarutahiko-records`, `sarutahiko-schema`, `sarutahiko-process`, `sarutahiko-jsonrpc`, `sarutahiko-mcp`, `sarutahiko-effect-signatures`, `sarutahiko-effect-effectful`, `sarutahiko-effect-polysemy`, `sarutahiko-effect-testkit`
      * Preserved `packages/spikes/handlers-as-records`
    - Updated `cabal.project` to reference the new component-nested package paths.
    - Updated `packages/yamaarashi/yamaarashi-flow/app/Main.hs` paths for `kogaki-wire` verification.
    - Updated all task packets (`phase1.5-01-hashigakari-sqlite.yaml`, `phase1.5-02-utai-mock.yaml`, `phase1.5-03-hokora-slice.yaml`, `phase2-agent-core.yaml`, `phase3-surfaces-codeintel.yaml`, `phase4-data-protocol.yaml`, `refactor-logical-string.yaml`) to use package names in `packages:` and component paths in actions.
    - Verified full compilation with `cabal v2-build all` and 100% test passes across all 6 suites (`kogaki-wire`, `sarutahiko-mcp`, `sarutahiko-jsonrpc`, `yamaarashi-spec`, `yamaarashi-flow`, `yamaarashi`).
13. **Executed Pre-Phase 1.5 Sweep 01 — Effect Framework Neutrality via Façade Pattern [TASK-009] (`0a169e5`):**
    - Promoted full subprocess lifecycle GADT (`Process m`) to `packages/sarutahiko/sarutahiko-effect-signatures` with zero concrete effect library dependencies (DECISION-002).
    - Implemented tagless-final capability typeclass `MonadProcess` and bracketed runner `withSupervisedChild` in `packages/sarutahiko/sarutahiko-process/src/Sarutahiko/Process/Capability.hs`.
    - Implemented pure POSIX supervisor and environment hygiene in `packages/sarutahiko/sarutahiko-process/src/Sarutahiko/Process/Supervisor.hs`.
    - Purged direct `effectful-core` dependencies from `sarutahiko-process` and `sarutahiko-mcp`.
    - Implemented dual-interpreter instances for `Eff es` and `Sem r` in `sarutahiko-effect-effectful` and `sarutahiko-effect-polysemy`.
    - Verified dual-interpreter parity in `sarutahiko-effect-testkit` (Clock, Resource, Process, Log parity tests all 100% passing).
    - Executed cleanly via `yamaarashi-exec run docs/task_packets/sweep-01-effect-facade.yaml` with zero warnings under `-Wall -Werror`.
14. **Executed Pre-Phase 1.5 Sweep 02 — Type-Level Non-Emptiness via `mono-traversable` [TASK-010] (`fad81ac`):**
    - Registered `mono-traversable` in `docs/registers/REUSE_REGISTER.md` §2.29 for sequence polymorphism and non-emptiness guarantees (`NonNull`).
    - Added `mono-traversable >= 1.0.17` to `packages/kogaki/kogaki-wire`, `packages/sarutahiko/sarutahiko-jsonrpc`, and `packages/sarutahiko/sarutahiko-mcp`.
    - Enforced `NonNull Text` for JSON-RPC `reqMethod` and `rawReqMethod` with `IsString (NonNull Text)` instance.
    - Added `dispatchBatch` and `dispatchTypedBatch` for structural non-emptiness in JSON-RPC batching, returning spec-compliant `-32600 Invalid Request` on empty batches or empty methods without partial matches.
    - Enforced `SseFieldLabel` (`NonNull ByteString`) and `renderDataLine` in `Kogaki.Wire.SSE.Parser`, eliminating all partial operations (`BSC.head`, `BS.tail`).
    - Executed via `yamaarashi-exec`, passed all verification checks, and verified all 3 test suites (`test-kogaki-wire`, `test-jsonrpc`, `test-mcp`) passing 100% with zero warnings under `-Wall -Werror`.
15. **Executed Pre-Phase 1.5 Sweep 03 — `LogicalString` and UTF-8 Codecs [TASK-011] (`1b7ce19`):**
    - Introduced canonical `LogicalString` newtype over `Text` in `packages/kogaki/kogaki-core/src/Kogaki/Core/String.hs` with total boundary conversions (`fromByteString`, `fromByteStringLenient`, `toByteString`, `fromText`, `toText`) and `MonoTraversable` instance.
    - Updated `Kogaki.Wire.Json.Decode` with row-native `FromJsonField` and `ToJsonField` instances for `LogicalString` and `NonNull LogicalString`.
    - Integrated `tokenLogicalString` in `Kogaki.Wire.Json.Lexer` and `sseDataLogical` / `mkSseEventLogical` in `Kogaki.Wire.SSE.Parser`.
    - Enforced zero partial functions across `kogaki-core` and `kogaki-wire`.
    - Added Hedgehog property test suite in `packages/kogaki/kogaki-core/test/Spec.hs` (6/6 tests passing with 100 runs each).
    - Executed cleanly via `yamaarashi-exec run docs/task_packets/refactor-logical-string.yaml` in isolated git worktree with SQLite event tracking, passed verification gates, and fast-forward merged to HEAD.
16. **Integrated First-Class Hermes Agent Delegation in `yamaarashi-exec`:**
    - Extended `TaskPacket` envelope and parser in `packages/yamaarashi/yamaarashi-flow/app/Main.hs` with `executor` (`hermes`, `script`, `auto`), `model`, `skills`, `max_turns`, and `run_budget` fields adhering to Zero-Aeson parsing.
    - Added automated seeding of `./tags` into isolated worktree on provision to grant spawned leaf workers instant, zero-token symbol lookups.
    - Implemented `runHermesStep` delegating turn execution headlessly (`hermes chat --in <wtDir> --query-file ... --oneshot --yolo --accept-hooks`) with full access to code intelligence tools (`tags`, `tricorder`, `contextful`).
    - Integrated structured markdown prompt synthesis (`buildHermesPrompt`) embedding task invariants, ground rules, and verbatim YAML blueprints.
    - Updated git commit creator with Linux kernel-style `Assisted-by` attribution reflecting Hermes / OmniRoute models alongside Antigravity architecture attribution.
    - Verified compilation and test suite (`yamaarashi-flow-test`) passing 100% with zero warnings under `-Wall -Werror`.

---

## 6. Immediate Workqueue (The Frontier)

> [!NOTE] Strategic Pause Boundary & Zero-Token Delegation Ready
> Foundational refactors and first-class Hermes execution delegation are COMPLETE.
> `yamaarashi-exec` is equipped to delegate task packets directly to zero-token Hermes instances (`executor: hermes`) with local code intelligence tools (`tags`, `tricorder`).
> Operational frontier is primed for Phase 1.5 Packet 01 (`phase1.5-01-hashigakari-sqlite`).

### [TASK-012] Execute Phase 1.5 Packet 01: phase1.5-01-hashigakari-sqlite
* **Objective:** Implement `packages/hashigakari/hashigakari-sqlite` embedded carrier for event store and task queue.
* **Verification Command:** `cabal v2-run yamaarashi-flow:exe:yamaarashi-exec -- run docs/task_packets/phase1.5-01-hashigakari-sqlite.yaml`

### [TASK-013] Execute Phase 1.5 Packet 02: phase1.5-02-utai-mock
* **Objective:** Implement `packages/utai/utai` and `utai-mock` deterministic carrier.
* **Verification Command:** `cabal v2-run yamaarashi-flow:exe:yamaarashi-exec -- run docs/task_packets/phase1.5-02-utai-mock.yaml`

### [TASK-014] Execute Phase 1.5 Packet 03: phase1.5-03-hokora-slice
* **Objective:** Assemble Phase 1.5 Hokora autonomous turn vertical slice.
* **Verification Command:** `cabal v2-run yamaarashi-flow:exe:yamaarashi-exec -- run docs/task_packets/phase1.5-03-hokora-slice.yaml`
