# Yamaarashi (山嵐) — The Selective Workflow Orchestrator & Hybrid Streaming Stack

Status: REVISED v0.2 · 2026-10-03 (Adjudicated & Blessed)  
Related: `NIH_PLAN.md` §3.5 (streaming gates), §3.6 (layering contract), §6.1 (Noh naming),
`REUSE_REGISTER.md` (§2.12, §2.25, §2.26, §2.27), `STATE.md` (Decisions 1–6), `docs/transcripts/AI_Coding_Context_Management_SOTA.md`

Yamaarashi — Japanese for *porcupine*, literally "mountain storm" — is the package family governing
macro-task orchestration, workflow compilation, and streaming transport in Sarutahiko. The name is
retained in Roman letters for packaging (`yamaarashi-*`).

Originally conceived as a port of Porcupine's `ArrowFlow` over an element-streaming kernel, the design
was overhauled on 2026-10-03 (adjudicating the SOTA context-management analysis in `AI_Coding_Context_Management_SOTA.md`):
the arrow-based approach was formally superseded by **Selective Applicative Functors (`selective`)** and
**algebraic graphs (`alga`)** operating under *Build Systems à la Carte* principles.

---

## 0. What it is, in one paragraph

A two-pass workflow and streaming architecture: task specifications are unpacked and statically
over-approximated to compute resource requirements (`VirtualTree`) prior to runtime (`yamaarashi-spec`);
macro-workflows execute as cached, resumable DAGs with early cutoff over algebraic graphs (`yamaarashi-flow`);
elements move across process and sandbox boundaries via conduit framing adapters (`yamaarashi-conduit`),
and fuse in-process via streamly hot loops (`yamaarashi-streamly`), both presenting the single, neutral
church-encoded stream kernel (`yamaarashi`). The entire family interfaces through the **Façade Pattern**
(monad-neutral tagless capability typeclasses backed by canonical GADT signatures in `sarutahiko-effect-signatures`),
preserving dual-interpreter parity under both `effectful` and `polysemy`.

---

## 1. The Stack & Package Family

```
┌────────────────────────────────────────────────────────────────────────┐
│ yamaarashi-spec      Task specification AST, Control.Selective.Over     │  spec & resource
│                      VirtualTree extractor, recursion-schemes unfolding│  granularity
├────────────────────────────────────────────────────────────────────────┤
│ yamaarashi-flow      Selective task DAG, Build Systems à la Carte       │  task / workflow
│                      scheduler over alga, memoized large-anon chunks    │  granularity
├──────────────────────────────────────┬─────────────────────────────────┤
│ yamaarashi-adapter-effectful         │ yamaarashi-adapter-polysemy     │  effect façade
│ MonadWorktree/Queue for Eff es       │ MonadWorktree/Queue for Sem r   │  adapters
├──────────────────────────────────────┴─────────────────────────────────┤
│ yamaarashi           the element kernel: church-encoded                 │  element
│                      Stream (Of a) m r + typed concurrency wrappers     │  granularity
├───────────────────────────────┬────────────────────────────────────────┤
│ yamaarashi-conduit            │ yamaarashi-streamly                    │  backends /
│ Stdio JSON-RPC framing,       │ In-process SerialT (Eff es) embed,     │  transports
│ OS process pipes, bracketP    │ fused hot loops, element transforms    │
├───────────────────────────────┴────────────────────────────────────────┤
│ Eff es — Resource · Process · TaskQueue · EventStore · ModelAPI · …    │  substrate
└────────────────────────────────────────────────────────────────────────┘
```

### Package Roles

1. **`yamaarashi-spec`** — The task specification AST and static analysis engine.
   - Represents specifications as pure algebraic data structures.
   - Evaluates static resource dependencies ahead-of-time using `Control.Selective.Over` to extract the
     `VirtualTree` (the complete union of all git worktrees, compiler toolchains, SCIP slices, and compute budgets).
   - Drives task subdivision using `recursion-schemes` (`ana`/`hylo`) paired with an `IsPrimitive` granularity
     heuristic, expanding macroscopic goals into atomic leaf task packets.
2. **`yamaarashi-flow`** — The macro-workflow DAG orchestrator and build scheduler.
   - Models dependencies as algebraic graphs (`algebraic-graphs` / `alga`).
   - Implements a pure, clean-slate build scheduler following *Build Systems à la Carte* principles
     (Mokhov, Mitchell, Peyton Jones) with topological execution, memoization, and early cutoff.
   - Intermediate outputs materialize as anonymous records (`large-anon` / `sarutahiko-records`) cached at
     `$_` content-addressed keys with determinism tags.
   - Completely replaces external `shake` and `porcupine` arrow machinery, eliminating `OverloadedLabels`
     collisions with `large-anon`.
3. **`yamaarashi`** — The public element-streaming kernel and concurrency API.
   - Church-encoded (CPS) free-monad stream, polymorphic in the base monad: `newtype Stream (Of a) m r`.
   - Zero dependencies on conduit, streamly, or concrete effect systems.
   - Exposes typed concurrency strategies (`Serial`, `Async`, `Interleaved`, `Parallel`) with explicit
     cancellation ownership semantics.
4. **`yamaarashi-conduit`** — Inter-task IPC, boundary framing, and deterministic cleanup.
   - Connects tasks running across isolated OS sandboxes (`bwrap`, Linux namespaces) or process pipes (`typed-process`).
   - Reuses proven framing stock (stdio JSON-RPC framing, SSE line framing, chunked payloads) from `conduit-extra`.
   - Re-homes bracketed finalization (`bracketP`) into the shared `Resource` effect row.
5. **`yamaarashi-streamly`** — Fused in-process execution backend.
   - Embeds streamly's `SerialT` for high-throughput element transformations inside a single process.
   - Provides hot-loop rewrite-rule fusion for tabular row decoding (`hashigakari` cursor streams) and token lexing.
6. **`yamaarashi-adapter-{effectful,polysemy}`** — Effect neutrality bridge.
   - Implements the orchestrator's tagless capability typeclasses (`MonadWorktree`, `MonadTaskQueue`, etc.)
     by delegating method calls to the canonical GADTs in `sarutahiko-effect-signatures`.

---

## 2. The Two-Pass Execution Model & Wart Safeguards

The migration from arrows to `selective` + `alga` addresses four specific architectural pitfalls:

### 2.1 Pass 1: Static Dependency Analysis (`VirtualTree`)
Before any external tool is spawned or git worktree created, `yamaarashi-spec` walks the workflow AST using
`Control.Selective.Over (Set ResourceDescriptor)`:
- It traverses all execution branches—including conditionally deferred or alternative branches—to compute
  the strict over-approximation of every repository, commit, environment variable, toolchain, and sandbox
  capability required.
- **Wart D Safeguard (Pure Descriptors):** Pass 1 inspects pure, inert metadata only (`ResourceDescriptor`).
  It performs *zero* IO or live resource acquisition, guaranteeing zero leakage during analysis.

### 2.2 Pass 2: Scheduler Execution & Early Cutoff
Once the `VirtualTree` is validated and resources are provisioned:
- The scheduler traverses the `alga` graph, stepping tasks whose dependencies are satisfied.
- If an upstream task yields an output identical to a previous run (verified via `kogaki-wire` hash),
  the scheduler triggers **early cutoff**, pruning downstream execution branches without invocation.
- **Wart C Safeguard (Clean-Slate Scheduler):** Avoids Neil Mitchell's external `shake` library. The scheduler
  is implemented natively in ~300 lines of clean GHC2024 code using `alga` and `large-anon`, avoiding
  Shake's file-based database, transitive package bloat, and `FilePath`-string coupling.

### 2.3 Boundary Rule: Macro-DAG vs. Agentic Islands
- **Wart A Safeguard (Static vs. Dynamic):** `Selective` cannot express unbounded loops or dynamically
  spawned graphs at runtime. Therefore:
  - The **Macro-DAG** is strictly Selective (static pipeline of target sweeps, build steps, verification gates).
  - The **Agentic Island** (the inner "generate $\rightarrow$ validate $\rightarrow$ fix" cycle inside a leaf task)
    executes as a monadic effect loop or state machine within the task runner, bounded by attempt fuel.
  - Hierarchical decomposition occurs during Pass 1 via `recursion-schemes` corecursion *before* the static DAG is sealed.

### 2.4 Why Arrows (Porcupine & Kernmantle) Were Superseded
- **The Label Collision:** `kernmantle` relies on `OverloadedLabels` (`#task`) to route arrow ports.
  Sarutahiko's record foundation (`large-anon`, `sarutahiko-fields`) uses `OverloadedLabels` for `#fieldName`.
  In GHC, sharing `IsLabel` across two foundational paradigms creates insurmountable type inference ambiguities.
- **Syntactic & Categorical Opacity:** `proc ... -> do` syntax hides execution graphs behind opaque desugared
  lambdas, preventing static inspection (`Control.Selective.Over`). Selective Applicatives preserve standard
  applicative syntax (`<*?>`, `branch`, `select`) while exposing inspectable structure.

---

## 3. The Streaming Mixture: Boundary IPC vs. In-Process Fusion

The division between Conduit, Streamly, and the Kernel is an architectural policy, not a temporary compromise:

| Granularity / Boundary | Chosen Component | Rationale |
|---|---|---|
| **Public API / Default Signatures** | `yamaarashi` kernel | Single abstract CPS type `Stream (Of a) m r`, zero streaming dependencies, effect-native. |
| **Sandbox & Process Boundary (IPC)** | `yamaarashi-conduit` | Deterministic framing over OS pipes/sockets (`bracketP`), chunked JSON-RPC framing, leak-free teardown. |
| **In-Process Hot Loops** | `yamaarashi-streamly` | GHC rewrite-rule fusion inside task bodies, unboxed element throughput for `hashigakari` rows. |
| **Task / Record Granularity** | `yamaarashi-flow` | Anonymous record chunks (`large-anon`) materialized at `$_` locations, content-addressed caching. |

---

## 4. Effect Neutrality via the Façade Pattern

To satisfy the Dual Interpreter Doctrine (`PLAN.md` Invariant 5) without tying the orchestrator to a concrete
effect monad, Yamaarashi implements the project-wide **Façade Pattern**:

1. **Reified GADTs (`sarutahiko-effect-signatures`):**
   Low-level operations are defined as neutral GADTs (`Worktree`, `TaskQueue`, `EventStore`, `Process`, `ModelAPI`).
   Interpreted into `Eff es` (`sarutahiko-effect-effectful`) and `Sem r` (`sarutahiko-effect-polysemy`) with
   Hedgehog parity tests (`sarutahiko-effect-testkit`).
2. **Consumer Façade (`yamaarashi-flow`):**
   High-level workflows are written against open capability typeclasses:
   ```haskell
   class Monad m => MonadWorktree m where
     withWorktree :: WorktreeSpec -> (FilePath -> m a) -> m a

   class Monad m => MonadTaskQueue m where
     claimTask    :: WorkerId -> m (Maybe TaskPacket)
     completeTask :: TaskId -> TaskResult -> m ()
   ```
3. **Adapter Modules:**
   Thin leaf modules instantiate the typeclasses by sending the corresponding GADT operations:
   ```haskell
   -- In yamaarashi-adapter-effectful:
   instance (Worktree :> es) => MonadWorktree (Eff es) where
     withWorktree spec k = ...
   ```

---

## 5. Concurrency Strategies & Determinism Tagging

The kernel exposes strategy wrappers with typed, explicit semantics:
- `Serial` — Strict sequencing (default; deterministic).
- `Async` — Left-biased speculative concurrency.
- `Interleaved` — Fair round-robin streaming.
- `Parallel` — Race concurrency (first result wins).

**Determinism Rule:** `Parallel` and `Interleaved` strategies are incompatible with cached task replay
unless tagged with a determinism exemption. `yamaarashi-flow` rejects untagged non-serial execution in cached nodes.

---

## 6. Worked Examples (Acceptance Conformance Shapes)

Each of the following three shapes serves as an executable verification target before Phase 2 exit:

1. **Zero-DTO DB $\rightarrow$ SSE Export:**
   `hashigakari-sqlite` query $\rightarrow$ existential stepper $\rightarrow$ `Stream` of `large-anon` records $\rightarrow$
   `rcast` drops sensitive columns $\rightarrow$ `yamaarashi-conduit` SSE frames out. Constant memory; early exit
   triggers deterministic cleanup via `Resource`.
2. **MCP Stdio Duplex with Sampling (`utai-mcp`):**
   Inbound process stdin $\rightarrow$ conduit framing adapter $\rightarrow$ `kogaki-wire` JSON-RPC row decoding $\rightarrow$
   open-variant method dispatch $\rightarrow$ LLM generation delegated via MCP Sampling (`sampling/createMessage`)
   back to host REPL $\rightarrow$ response row framed back to stdout.
3. **Selective Task Workflow with Resumption & Early Cutoff:**
   `yamaarashi-spec` parses a multi-compiler sweep (Linux + illumos + FreeBSD) $\rightarrow$ Pass 1 extracts `VirtualTree` $\rightarrow$
   `yamaarashi-flow` scheduler provisions isolated worktrees $\rightarrow$ steps compile tasks in parallel $\rightarrow$
   verification failure triggers local fix loop $\rightarrow$ killing process mid-run and re-executing resumes cleanly from
   cached `$_` record chunks.
