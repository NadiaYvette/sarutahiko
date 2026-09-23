# Yamaarashi (山嵐) — The Conduit / Porcupine / Streamly Hybrid Streaming Stack

Status: DRAFT v0.1 · 2026-09-23
Related: `NIH_PLAN.md` §3.5 (streaming gates), §3.6 (layering contract), §6.1 (Noh naming)

Yamaarashi — Japanese for *porcupine*, literally "mountain storm" — is the working name for
the hybrid streaming stack that layers **porcupine's** task-DAG orchestration over the
**conduit / streamly mixture** on a shared effect substrate. The name is kept in Roman
letters for packaging (`yamaarashi-*`). It exists because the three ingredients answer
different questions and were being forced to compete for one layer:

| Ingredient | Native question | Kept for |
|---|---|---|
| porcupine (ArrowFlow) | *How do tasks compose, cache, resume, parallelize?* | DAG orchestration, Make-like caching at `$_` locations, FRP-flavored demand, visualization |
| streamly | *How do elements move fastest?* | Fused hot loops, typed concurrency strategies (`SerialT`/`AsyncT`/`WAsyncT`/`ParallelT`), folds+parsers |
| conduit | *How do bytes and resources behave at boundaries?* | Mature framing adapters, deterministic finalization idioms, ecosystem interop |
| (the effect row) | *What can a step do?* | `Eff es` substrate: `Resource`, `Log`, `StreamingDB`, MCP, model calls — one vocabulary across all layers |

The thesis, matching `NIH_PLAN.md` §3.6: **these never compete for the same layer.**
Porcupine composes *tasks*; the element kernel moves *elements* inside a task body; conduit
and streamly are interchangeable *backends* for that kernel; the effect row is shared by all
of it.

---

## 1. The stack

```
┌───────────────────────────────────────────────────────────────┐
│ yamaarashi-flow      tasks, DAG shapes, caching, resume,      │  task / chunk
│                      viz. PTasks over Eff es; row-typed       │  granularity
│                      chunks at $_ locations                   │
├───────────────────────────────────────────────────────────────┤
│ yamaarashi           the element kernel: church-encoded       │  element
│                      Stream (Of a) (Eff es) r + typed         │  granularity
│                      concurrency strategy wrappers            │
├───────────────┬───────────────────────────┬───────────────────┤
│ yamaarashi-   │ yamaarashi-streamly       │ yamaarashi-       │  backends /
│ conduit       │ SerialT (Eff es) embed,   │ adapters          │  interop
│               │ fused strategies          │                   │
├───────────────┴───────────────────────────┴───────────────────┤
│ Eff es — Resource · Log · StreamingDB · MCP · Model · …       │  substrate
└───────────────────────────────────────────────────────────────┘
```

Package roles:

- **`yamaarashi`** — the kernel and public API. Church-encoded (CPS) free-monad stream,
  polymorphic in the base monad (`Eff es` in practice, any `Monad` in principle):
  `newtype Stream (Of a) m r`. O(1) left-associated `>>=` via the Codensity property; no
  RULES-pragma fragility; one abstract type users can read. Ships: core combinators,
  `Of`-pair producer shape, folds, parsers (byte framing), and the concurrency strategy
  wrappers with *explicit, documented* semantics (see §4).
- **`yamaarashi-conduit`** — `ConduitM ⇄ Stream` adapters in both directions, plus the
  framing stock (stdio JSON-RPC framing, SSE lexing) reused from conduit-extra where it is
  already proven. Exists so ecosystem interop is an import, not a rewrite.
- **`yamaarashi-streamly`** — embeds streamly's `SerialT (Eff es)` as a *backend*: hot loops
  opt into rewrite-rule fusion by becoming concretely typed inside a task body. Also the
  home of the high-throughput fold/parser implementations backing kernel combinators when
  the caller does not care (strategy: kernel API, streamly execution).
- **`yamaarashi-flow`** — porcupine re-homed: base monad `Eff es`, chunks are anonymous
  records (`NIH_PLAN.md` §3.6), purity/determinism tags for LLM-backed tasks with
  invalidation keys (model, sampling params, prompt hash), task-level scheduling and
  cancellation ownership.

Dependency rule: `flow → yamaarashi → {conduit, streamly}` adapters; everything → the effect
signatures (`sarutahiko-effect-signatures`), never a concrete effect system. Adapters are
optional extras; the kernel has zero streaming-library dependencies.

## 2. Kernel design

### 2.1 The type

```haskell
-- CPS / church-encoded; polymorphic in the base monad
newtype Stream (Of a) m r =
  forall s. Stream (s -> (s -> a -> m (Step s)) -> m (Step s) -> m (Step s) -> m r -> m r)
```

(Exact representation is an implementation matter — `streaming`'s `Stream (Of a) m r` shape
is the reference; the Codensity encoding is the default, with a benchmarked non-CPS variant
kept behind the same API if it wins.)

Why this shape:

1. **Fusion-adjacent without RULES.** Left-associated binds stay O(1); pipelines written in
   the natural aesthetic style do not degrade quadratically. We deliberately trade the last
   few percent of streamly's fully-fused sequential throughput (§0 decision) for one readable
   abstract type — and claw it back per-loop via the streamly backend (§3).
2. **Effect-native.** `m = Eff es` is the intended instantiation. Every step may `send` any
   effect: log a row-typed event, read a DB cursor, call an MCP tool. No `MonadIO` escape
   hatches, no lifted-IO seam.
3. **Adapter-friendly.** Being an ordinary transformer-shaped type, conduit and streamly
   adapters are mechanical; neither library needs to know we exist.

### 2.2 Resource safety as an effect, not plumbing

Conduit's real invention — `bracketP` discipline — is re-homed into the shared substrate as
a `Resource`/`Scoped` effect row member (bracket semantics with guaranteed finalization on
short-circuit), interpreted once per effect system (`sarutahiko-effects-{effectful,polysemy}`).
Consequences:

- The kernel has *no* finalization machinery of its own; acquisition/finalization are effect
  operations. Early exit (`take 10` on a million-row cursor) finalizes through the row —
  under both effect systems, by construction.
- `yamaarashi-flow` gets uniform teardown for free: an ArrowChoice branch skipped at the DAG
  level still finalizes inner streams, because both layers share `Eff es`.
- DB cursors (`hashigakari-core`'s existential `DBCursor` steppers, `HASHIGAKARI_DESIGN.md`
  §3.4) unfold into `Stream`
  and are covered by the same guarantee — the §3.5 gate-1 concern is designed out rather
  than benchmarked away.

### 2.3 What the kernel deliberately does not do

- **No cross-task fusion.** Element fusion stops at `yamaarashi-flow` task boundaries, where
  chunks materialize for caching. That is the sanctioned throughput-for-aesthetics trade,
  repaid in resume-after-crash and per-task debugging (`NIH_PLAN.md` §3.6).
- **No global backpressure policy.** The kernel provides demand-driven pulls; the DAG layer
  provides task-level pull (a task runs when inputs are ready); each layer owns its
  discipline, documented per level.
- **No bidirectional pipe type.** Conduit's Client/Server duality is *not* ported. All our
  duplex cases factor into one-way streams plus outbound-send-as-effect-operation: MCP stdio
  (requests + notifications out, responses + notifications in), SSE (out only), DB cursors
  (pull only). One less contravariant slot, no `Await`/`HaveOutput` ceremony.

## 3. Backend strategy (the "conduit/streamly mixture", resolved)

The mixture is not a compromise between two finalists; it is a *policy*:

| Situation | Reach for | Why |
|---|---|---|
| Default code, aesthetics matter | `yamaarashi` kernel | One abstract type, effect-native, readable signatures |
| Profiled hot loop (e.g. Parquet column decode, JSON frame lexing) | `yamaarashi-streamly` (`SerialT (Eff es)` inside the body) | Rewriting-rule fusion where it measurably pays; locally concretely typed |
| Byte boundary / ecosystem interop (HTTP bodies, process pipes, third-party conduit sources) | `yamaarashi-conduit` adapters | Already-proven framing; zero-rewrite interop |
| Concurrent producers/consumers | kernel strategy wrappers (backed by streamly machinery or `Eff`'s concurrency) | Typed, explicit semantics (§4) |

Rule of thumb recorded for reviewers: **the kernel is the API; the backends are
implementations.** No user-facing signature may mention conduit or streamly; internal
signatures may, inside task bodies only.

## 4. Concurrency strategies

The kernel exposes strategy wrappers with explicit, documented semantics (typed like
streamly's `SerialT`/`AsyncT`/`WAsyncT`/`ParallelT`), so "which discipline" is a type-level,
reviewable choice rather than a runtime accident:

- `Serial` — strict sequencing (default; matches the aesthetics-first mandate).
- `Async` — left-biased concurrency: evaluate the left stream; the right runs ahead.
- `Interleaved` — fair round-robin (WAsync).
- `Parallel` — race, first result wins.

Two obligations accompany them:

1. **Cancellation ownership** is documented per level: the DAG layer cancels tasks; strategy
   wrappers cancel their own children; the `Resource` effect reaps anything left. One
   paragraph each, in this doc's §6 maintenance section and in Haddock.
2. **Determinism tagging:** `Parallel`/`Interleaved` are incompatible with
   `yamaarashi-flow`'s cache-replay unless the task is tagged deterministic; the flow layer
   rejects untagged non-serial strategies in cached tasks (compile-time where the row makes
   it expressible, else a load-time check).

## 5. Worked examples (the acceptance shapes)

These three recur in `NIH_PLAN.md`; each must exist as an executable example in the repo
before Phase-2 exit, as the library's conformance targets:

1. **Zero-DTO DB→SSE export.** SQL query → existential `DBCursor` stepper → `Stream` of
   anonymous records → `rcast` drops sensitive fields → SSE frames out. Memory-constant;
   early-exit finalizes the cursor via `Resource`; no DTO anywhere.
2. **MCP stdio duplex.** Byte chunks in → conduit framing adapter → request/notification
   rows → open-variant method dispatch → effect senders (`Tools`, `FileSystem`) → response
   rows → frames out; outbound server-initiated requests ride an effect operation. This is
   also `sarutahiko-mcp`'s Phase-1 flagship shape.
3. **DAG export with resume.** porcupine task graph (fetch → transform → aggregate) with
   record-typed chunks at `$_` locations; kill mid-run; re-run resumes from cached chunks;
   an LLM-backed task's cache entry invalidates when model/sampling/prompt-hash keys change.

## 6. Maintenance obligations

- The kernel stays dependency-free (no conduit, no streamly, no effect system); adapters and
  backends carry the dependencies so pinning churn (§3.5 gate 4) is absorbed at the edges.
- Benchmark ledger (`NIH_PLAN.md` §4): kernel vs. streamly-native vs. conduit on the §5
  shapes; the §3.5 gates are re-run with this ledger at the Tier-1 exit.
- Haddock contract: every combinator states its strictness, finalization behavior under
  short-circuit, and allowed effect rows.
- If streamly major-version churn forces a second migration in one release cycle, gate 4
  trips and the `yamaarashi-streamly` backend is demoted to optional-extra while the kernel
  absorbs its strategies natively.
