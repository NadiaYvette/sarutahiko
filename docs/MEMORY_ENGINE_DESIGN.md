# The Memory/Context Engine — Design Note

Status: DRAFT v0.1 · 2026-09-24
Related: `EFFECT_CATALOG_DESIGN.md` (`SessionStore`, `ModelAPI`, `SomeRow`),
`HASHIGAKARI_DESIGN.md` (the log substrate), `YAMAARASHI_DESIGN.md` (derived-data
pipelines), `HERMES_DESIGN.md` (prompt-cache invariant, compression), `NIH_PLAN.md`
(backlog item 7; keiro contact points — kioku is the ecosystem's reference implementation
of this layer)
Naming: deliberately open — per `NIH_PLAN.md` §6.1 the term will be chosen from Noh
vocabulary with a collision check; `kioku` (記憶, "memory") is of course taken by the keiro
ecosystem itself. Placeholder in this note: **the memory engine**.

---

## 1. Purpose — and a correction of record

This note fixes the design content of the memory/context engine. It also corrects an
impression left by earlier discussion: "the memory engine is gluing codecs + database +
event loops" is true of its **plumbing** and materially incomplete. The engine has three
parts of very different difficulty:

| Part | Difficulty | Nature |
|---|---|---|
| The **event log** | systems design | one irreversible decision (envelope versioning) plus concurrency semantics |
| **Reducers** (derived views) | easy, exactly as suspected | pure folds; the gluing thesis holds here |
| **Policy** (what enters context, what gets compressed, what gets retrieved) | genuine design space | heuristics with a hard invariant (cache safety) and no ground truth to test against |

The plumbing is glue. The policy is where agent *quality* actually lives — Hermes' context
engine, kioku's salience machinery, and every serious agent's token-budget management are
policy, not plumbing. And one part of the "glue" — schema evolution of an append-only log —
is a real systems problem that must be designed *before* the first event is written, because
logs are the one artifact in the program you cannot rewrite.

## 2. The shape

```
                    ┌──────────────────────────────────────────┐
                    │  CONTEXT BUDGET (the product)            │
                    │  Record Identity ContextRow              │
                    └───────────────▲──────────────────────────┘
                                    │ compose (pure)
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
┌───────┴────────┐        ┌─────────┴────────┐        ┌─────────┴─────────┐
│ TAIL: session  │        │ MIDDLE: pinned/  │        │ HEAD: system      │
│ events (cache- │        │ retrieved blocks │        │ prompt + skills   │
│ stable prefix) │        │ (cache-hostile)  │        │ (per-profile)     │
└───────┬────────┘        └─────────┬────────┘        └─────────┬─────────┘
        │ fold                      │ select                    │ assemble
┌───────▼───────────────────────────────────────────────────┐
│ SessionStore (event log)          │ ModelAPI (embed/rank) │
│ hashigakari-sqlite / -hasql       │ policy effects        │
└───────────────────────────────────────────────────────────┘
```

- The **log** is the only write path. Everything else is derived data, rebuildable.
- **Reducers** are pure folds over the log producing projections: conversation tail, kanban
  state, checkpoint summaries, retrieval indexes.
- **Policy** decides the composition of the context row handed to `ModelAPI` — and is the
  only component permitted to *break* the cached prefix, under the contract below.

## 3. The event log and envelope versioning (the irreversible decision)

The log's schema is decided once and lived with forever. Hermes' compat contract and the
PVP-for-signatures policy are both precedents for the *discipline*; the difference is that
hook payloads can be migrated by re-running producers, while log events are immutable
history.

### 3.1 The envelope row (v0.2 — blessed 2026-09-24)

**The principle: the spine is the *address*, not the *meaning*.** Spine = exactly what an
event needs to be routed, decoded, traversed, audited, and retained *without knowing what
it means*. Payload = the meaning. A field earns spine only if a reducer that must work
across all `(kind, schemaV)` pairs forever, with zero schema knowledge, needs it; those
reducers are session-tail assembly, audit, retention/pruning, and causal traversal. Every
future "should this be spine?" question is decided by three mechanical tests: the
**address test** (routing/identity/decode dispatch), the **universal-reducer test** (does
an eternal schema-blind reducer need it), and the **adversarial test** (if this changed
later, where would it live? — any plausible answer ⇒ payload).

```haskell
type Envelope extra =
  '[ "seq"      ':= Word64        -- store-local monotone position; THE only ordering (§3.4)
   , "eventId"  ':= UUID          -- identity; referenced by causes; survives pruning/exports
   , "kind"     ':= Kind          -- closed enum of event families (additive only)
   , "schemaV"  ':= Natural       -- payload schema version (decode dispatch, fail-closed)
   , "ts"       ':= UTCTime       -- INFORMATIONAL; never used for ordering (law T)
   , "session"  ':= SessionId     -- partition key
   , "actor"    ':= Text          -- user | model | tool:<name> | system:<component>;
                                  -- stored as text, total parse with catch-all (law A)
   , "cause"    ':= Maybe UUID    -- single causal parent (tool call → observation)
   , "payload"  ':= SomeRow       -- existentially packaged, tagged by (kind, schemaV)
   ] ++ extra                   -- compile-time, deployment-level extension ONLY (law X)
```

Field examination record (v0.2):

- **`seq`/`eventId` split** (repairs the v0.1 sketch): identity and ordering are two
  different needs. `eventId` never changes and is what `cause` references; `seq` is the
  store-local position that defines the fold order. Conflating them (monotone UUIDs) is
  impossible; ordering by UUID is random; see §3.4.
- **`ts` law (T):** clocks do not order events (NTP steps, skew, same-ms collisions).
  `ts` is informational (display, retention age, debugging); **no reducer may order by
  `ts`**; `seq` is the only ordering. This also rejects hybrid logical clocks: we are
  single-writer per session; HLC machinery would bake distributed assumptions into a
  design that §6 rejects.
- **`actor` law (A):** a closed enum in forever-data must round-trip unknown values (a
  future `Actor` constructor must not corrupt old stores under old code). Representation:
  store as `Text`, construct via smart constructors, read via total parse with a
  catch-all — the open-envelope rule from the formats bag.
- **`cause` and compression spans:** a single optional parent makes the causal graph a
  tree, which is correct for tool→observation chains. Compression summarizes a *span*, so
  `ContextCompressed` events carry the span (`fromSeq`/`toSeq`) **in their payload** —
  the tail reducer is exactly the reducer that must understand compression anyway, so
  span-in-payload applies the spine principle rather than violating it. The audit reducer
  never needs span boundaries. (Alternative rejected for v0.2: general
  `causes := [UUID]` DAG — heavier indexes, no current consumer.)
- **`extra` law (X):** the tail parameter exists for *compile-time, deployment-level*
  spine extension only (e.g. a fleet build adding `tenant` before any store exists).
  It is never a runtime escape hatch — runtime spine growth would contradict rule 4.

### 3.2 The versioning rules

1. **Payloads are rows; evolution is row extension.** New optional fields extend a payload
   row at the same `schemaV` — old reducers ignore unknown fields by construction (the
   records half of the duality works *for* us here).
2. **Any payload change that old reducers would misread bumps `schemaV`.** Reducers declare
   the `(kind, schemaV)` pairs they understand; the log layer refuses to hand a reducer an
   event it did not declare (fail-closed, per the house trust discipline).
3. **`kind` is closed and append-only itself.** New event *families* are new `kind`s
   (additive, cheap); a `kind` is never re-typed. This is PVP-for-signatures transposed to
   data: the sum of kinds evolves by addition.
4. **The spine is forever.** Its fields are picked to be derivable from nothing (no
   migration possible). Anything that might later need to change (token counts? embedding
   model ids?) starts as a payload field, never a spine field.
5. **Cross-dialect honesty.** The log must behave identically on SQLite (hokora, single-user)
   and Postgres (fleet). The ordering assumptions admitted are exactly those of §3.4;
   reducers that would need any other ordering are wrong and get redesigned.

### 3.3 What counts as an event

Err on the side of *too many* kinds, factored late: `MessageAppended`, `ToolInvoked`,
`ToolObserved`, `ContextCompressed`, `CheckpointTaken`, `PinnedAdded`/`Removed`,
`MemoryWritten` (long-term), `RetrievalHit` (feedback for policy learning), `BudgetAdjusted`.
Compression *writes an event* (`ContextCompressed`) rather than mutating history — the
cache-breaking moment is thus itself in the log, replayable and auditable.

### 3.4 The ordering contract (blessed alongside spine v0.2)

Why there is a contract at all: SQLite and Postgres differ in where their ordering
*guarantees* actually live, and a design that exploits an implementation behavior rather
than a guaranteed one works on the hokora and breaks on the fleet. The contract makes the
walked path (`seq` within a `session` partition) the only thing anyone may rely on, and
everything else either documented-but-unexploitable or forbidden.

**The three-level order hierarchy.**

1. **The walked path (the contract).** `ORDER BY seq ASC WITHIN session` — `seq` is
   store-local, monotone, dense, and the *only* ordering primitive. Every consumer uses
   this and nothing else. It is delivered as an explicit cursor, never assumed from
   scan order.
2. **Documented, unexploitable (table scan order).** An unrouted full-log scan is
   *observed* to come back in `seq` order per session (both engines) — recorded here so
   nobody rediscovers it and leans on it. Optimization only: a scan may use it as a
   heuristic, then *verify* contiguity cheaply and fall back to an explicit sort on
   violation. Correctness never reads scan order.
3. **Undefined and never used:** cross-session ordering (except: two events *known* to
   come from one conversation, ordered by their `seq`s); `ts` ordering (law T);
   `nextval`-shared-sequence global order (fleet-only, see below).

**How each engine delivers level 1.**

- *Postgres:* `bigserial`-style `seq` in the events table (per-store monotone, dense,
  gap-free in single-writer use); per-session reads are an index over `(session, seq)`.
  For kiroku-adjacent deployments only: a Postgres `SEQUENCE` can give a global append
  order — a documented dialect *extension*, used solely as a tie-break for read-only
  fleet aggregation, never for projections (which must stay dialect-neutral).
- *SQLite:* `INTEGER PRIMARY KEY` (`rowid`) aliased as `seq` — monotone, dense,
  single-writer by §6's model.

**Contract items.**

- **C1.** `seq` is store-local, monotone, dense (no gaps); it has no meaning outside its
  store and must never appear in exported or compared data (identity is `eventId`'s job).
- **C2.** Sessions are linearizable (§6): within a session, one total order by `seq`,
  writes append at the tail. Across sessions, no order exists.
- **C3.** Cursor discipline: consumers receive `(session, seq)` cursors; reads resume by
  `WHERE session = ? AND seq > ?`. No `OFFSET`-style positional paging, no scan-order
  reliance.
- **C4.** `ts` is informational only (law T already says this; C4 applies it to SQL:
  `ts` indexes exist for retention queries only, never for ordering queries).
- **C5.** Snapshot/replay equivalence: replaying `events ORDER BY seq WITHIN session`
  on either dialect yields byte-identical projections.
- **C6.** `updatedAt`-style timestamp columns are *forbidden* anywhere in the log
  schema — an append-only design should never want them, and their presence is the
  classic vector for silently reintroducing timestamp ordering.

**Known dialect differences (documented, unexploitable).** Postgres MVCC may move dead
rows to the physical tail after VACUUM, and AUTOINCREMENT-vs-rowid recycling details
differ; SQLite rowid reuse after deletes is avoided by never deleting (retention prunes
whole stores or prefixes with `seq` bookkeeping). None of these are order *guarantees*,
so none are load-bearing.

**Enforcement.** Property tests: identical event streams through SQLite and Postgres
interpreters produce identical projections (C5); a generator that shuffles `ts` and
interleaves sessions must not change any projection. SQL-lint rule: any log query that
`ORDER BY`s something other than `(session, seq)` fails CI.

**What is *not* admitted** (redesigned, not accommodated): reducers needing global
cross-session order; schedulers inferring sequence from time; `ts`-windowed folds; any
use of scan order for correctness. If a future feature wants one of these, the feature is
wrong for this log.

**Revisitation triggers** (the events that would reopen this contract, per the maintainer's
revisit-if-it-fails-us principle): (i) multi-writer sessions (§6 abandoned) ⇒ seq becomes
Lamport/portz-style logical clocks; (ii) active-active replication ⇒ HLC or CRDT event
mesh, spine extension via `extra` before any affected store exists; (iii) kiroku-interop
needing a shared global order ⇒ adopt their monotone-id convention behind the cursor
interface, which is exactly why C1/C3 confine `seq` behind an explicit cursor today.

## 4. Reducers — the easy part, stated precisely

(Consumers of §3.4: all folds walk `(session, seq)` cursors and nothing else.)

A reducer is a pure `fold` over `(kind, schemaV)`-filtered events producing a projection.
Discipline:

- **Total over declared versions, fail-closed over undeclared ones** (§3.2.2).
- **Idempotent under replay** — projections are rebuildable from any prefix or from
  snapshots; replay is the *only* migration mechanism the design offers.
- **Snapshotting** for long sessions: a `CheckpointTaken` event stores a projection digest
  + state row; reducers hydrate from the nearest checkpoint. Checkpoints are themselves
  events, so the fold never special-cases them.
- The projections needed for Phase 2: conversation tail (the cache-stable prefix),
  kanban/task state, pinned-blocks set, and a lightweight retrieval index (§5.3).
- All of these are *also* expressible as `yamaarashi-flow` tasks — rebuilds and
  rehydrations are DAG jobs with caching, which is where the flow layer earns its keep in
  the engine.

## 5. Policy — the real design space

Policy composes the context row. Three sub-problems, each with a hard constraint and an
open design:

### 5.1 The cache-safety contract (the invariant everything else serves)

Per-provider prefix caching means: **byte-identical context prefix ⇒ cached ⇒ cheap and
fast; any change to early content ⇒ full re-pricing of the turn.** The contract, carried
over from Hermes and made enforceable here:

1. The tail (messages so far) is append-only *within a turn sequence*; only compression may
  mutate it.
2. Compression is the sole sanctioned mutation, it writes `ContextCompressed`, and it
  requires either an explicit turn boundary or user consent (`--now`-style opt-in).
3. Toolsets, system-prompt sections, and skills are frozen for the duration of a
  conversation turn sequence (the Footprint Ladder rule from HERMES_DESIGN).
4. **PolicyEffect — the encoding (v0.2, spec'd; adopt via the expressiveness trial).**
   Principle: *policies propose, the turn program disposes*. Components never write
   context — physically, because context-writing is not in their effect row; the turn
   program is the single writer. PolicyEffect classifies not components but **decisions**:
   a closed kind `PolicyEffect = Pure | TailOnly | PrefixBreaking` carried as a phantom on
   decision data, consumed by exactly one executor per class:

   ```haskell
   data PolicyEffect = Pure | TailOnly | PrefixBreaking

   data Decision (e :: PolicyEffect) where
     Score    :: Salience          -> Decision 'Pure            -- informs; touches nothing
     Retrieve :: NonEmpty BlockRef -> Decision 'TailOnly        -- appended to the suffix
     Restate  :: BlockRef          -> Decision 'TailOnly
     Compress :: Span -> SummaryKey -> Decision 'PrefixBreaking

   type PolicyCap es = (SessionStore :<: es, ModelAPI :<: es, Log :<: es)
   type Policy = ∀ es. PolicyCap es => Eff es [SomeDecision]   -- no context-write effect

   extend  :: Context -> [Decision 'TailOnly] -> Context       -- appends only
   rewrite :: ConsentGated -> Context
        -> NonEmpty (Decision 'PrefixBreaking) -> (Context, CacheInvalidated 'True)
   ```

   Enforcement points: **E1** row construction (no context-write API exists for any
   component, any row — capability rows); **E2** `Decision` exported abstract, smart
   constructors per stage module (`Compress` built only in the compression stage);
   **E3** `extend` accepts only `TailOnly` decisions (misrouting is a type error);
   **E4** `rewrite` requires a `ConsentGated` proof produced only by the approval stage
   (the runtime UX gate at the one prefix-breaking path); **E5** system sections/toolsets
   are turn-program *inputs* fixed per sequence, never policy outputs (Footprint Ladder
   by construction); **E6** cache status is structural — prefix unchanged ⟺ `rewrite` not
   called — cross-checked against `ContextCompressed` log events in property tests.
   Packaging honesty: policies return existentially wrapped decisions carrying a runtime
   singleton witness (`SPolicyEffect e`); `partition` splits `SomeDecision`s into typed
   lists — the SomeRow rule again (types don't cross packaging; one runtime dispatch at
   the boundary buys type safety on the far side). Phantoms/singletons erase; the
   partition is O(n) dispatch a runtime-tag design needs anyway.

   **Expressiveness trial (adoption gate).** S1 context-mutating component → no API
   (compile); S2 `PrefixBreaking` routed to `extend` → type error; S3 `Compress` built
   outside the compression stage → constructor hidden (compile); S4 `rewrite` without
   consent → compile; S5 mid-sequence toolset swap via policy → unrepresentable; S6
   policy ordering log reads by `ts` / across sessions → rejected by §3.4 property
   tests. Adopted iff all six behave as specified. Note: adding a fourth class = adding
   an executor = design event (PVP-for-data). Beyond safety: policies-as-decision-
   producers is exactly the shape §8's replay harness consumes — the safety encoding and
   the measurement instruments are one decision.

This is where the engine is *not* glue: a policy that is naively "smart" (dynamic
retrieval, eager summarization) destroys the cache and costs more than it saves. The
design must make the cache-hostile path *type-visible* and consent-gated.

### 5.2 Salience and compression

- **Salience** scores events for "deserves to remain in context": recency, actor weight,
  causal depth (children of user-visible turns), tool-failure flagging, explicit pins.
  Open design: scoring is a pure function over spine fields first (cheap, indexable), with
  payload-deep scoring as a paid, cached second pass.
- **Compression** replaces a span of the tail with a summary event. Design decisions to
  make in the note's next revision: trigger policy (token budget thresholds vs turn
  boundaries), span selection (contiguous vs salience-clustered), summary provenance (the
  summarizing model + prompt hash become invalidation keys, exactly the
  `yamaarashi-flow` determinism-tag rule applied to compression), and the *loss budget*
  (what categories may be dropped outright vs must be summarized).
- Compression composes with the hokora/turn loop as an effect: `Compress :: Span ->
  ModelAPI-summary -> SessionStore-append` — its cache-breaking nature is carried in its
  type per §5.1.4.

### 5.3 Retrieval (long-term memory)

- Indexes over the log (lexical first; embeddings via `ModelAPI.embed` as the second
  backend) are projections (§4), rebuilt by replay, cached by `yamaarashi-flow`.
- Retrieval policy selects middle-blocks: query construction from the current turn, top-k
  with a *declared* `PrefixBreaking` impact — retrieved blocks must enter *after* the
  stable prefix, or the cache contract is violated; the design slots them between tail and
  system head, never inside it.
- `RetrievalHit` events record what was retrieved and whether it was used, giving the
  salience function a feedback signal — the one place the engine learns, and it learns
  from its own log.

## 6. Concurrency and multi-writer

- **Single-writer per session** (the gateway routes by session; shibuya-class supervision
  owns the worker). The log layer enforces session-scoped linearizability; concurrent
  *sessions* are independent streams, which is what makes SQLite viable for the hokora and
  small deployments.
- Cross-session aggregates (fleet dashboards, global retrieval) are read-only projections
  over the union stream, eventually consistent by design — no distributed-transaction
  machinery is admitted.
- Subagents: a child session references its parent by `session` spine field + a
  `ParentLink` payload; supervision events (spawn/death) are log events, so the crash
  story is uniform with everything else.

## 7. Privacy and secrets

- Payloads may contain secrets (tool outputs, env dumps). The engine's rule: **secrets are
  never spine fields, and policy components that could emit payloads are
  `Pure`/`TailOnly`-scoped away from secret-producing actors**; the capability row for the
  policy interpreter simply does not include effects that can read secret sources.
- Forgetting is a real requirement (user deletes a session, right-to-erasure): the log
  supports **store-level** deletion (whole session files/rows) but *not* surgical
  mid-history edits; policies must therefore be designed so "delete this from memory"
  maps to store-level operations plus rebuilds. This constraint must be stated to users
  as a product fact, not papered over.

## 8. Metrics that decide the open questions — the empirical protocol

The engine's open questions (compression triggers, salience weights, retrieval depth) are
not decidable a priori — but most are decidable *empirically*, offline, before real usage.
The protocol, stated so experiments are reproducible:

**8.1 The three instruments.**

1. **The prefix-hash cache simulator.** Provider prefix caching is a deterministic
   function of context bytes: identical early bytes ⇒ hit. Cache hit rate is therefore
   *simulable offline with zero provider calls* — hash the prefix at each turn boundary,
   compare against the previous turn's hashes. This makes the most expensive-feeling
   question (does this policy destroy the cache?) the cheapest to answer.
2. **The policy harness.** A policy is a pure function `(log prefix) -> decisions`.
   The harness replays N policies over the same log prefixes against a *deterministic*
   mock `ModelAPI` (the kuroko Mock precedent) or recorded provider transcripts, and
   measures: tokens-in-context per turn, simulated cache hits (8.1.1), compression
   frequency, retrieval selections, and — where the workload has a checker — task success.
3. **Workload corpora with checkers.** Synthetic-first (privacy): seeded multi-step task
   suites in the shape the agent will serve (replays of hokora sessions once real;
   kanban-like long jobs; transcript-like interactions). Task success needs a checker —
   for coding-shaped workloads, the *pattern* of the keiro ecosystem's `shikumi` eval
   harness family is the reference; our hokora-scale checker is a thin pure predicate.

**8.2 The experiment designs.**

- **Compression (trigger × span × loss budget):** a grid sweep; each cell scored by
  tokens-per-solved-task, cache-hit retention, and post-compression task success; report
  the Pareto frontier and *choose an operating point from the frontier*, not by taste.
- **Salience v1 (feature set over spine fields):** ablation over the feature lattice;
  the shipped set is the cheapest subset within ε of the full set's score.
- **Retrieval (lexical vs embeddings, depth k):** precision@k against judged relevance on
  seeded queries, plus index rebuild cost; the embeddings decision is a measured crossover,
  not a religion.

**8.3 What is *not* empirically decidable — and what gates it instead.**

| Decision | Why not tunable | Gate |
|---|---|---|
| Spine fields (§3.1) | irreversibility; no metric can price a future migration | adversarial design review: "if this changed later, where would it live?" — anything with a plausible answer moves to payload |
| Cross-dialect ordering assumptions (§3.2.5) | correctness, not quality | property tests: same events ⇒ identical projections on SQLite and Postgres |
| Cache-safety contract (§5.1) | invariant, not objective | pass/fail around every experiment; a policy that violates it is disqualified, however well it scores |
| Real-usage salience drift | needs actual users | re-evaluation at Phase 3 on fleet metrics; the harness gives direction, deployment gives verdict |

Guard: synthetic corpora overfit. Every harness number is directional until reproduced on
real (consented, anonymized) sessions at Phase 3; the plan's benchmark ledger (NIH_PLAN
§4) records both origins.

The hokora instruments all of this from day one on its single session; design iterations
happen against these numbers, not against intuition.

## 9. Non-goals

- No learned/embedded policy models in v1 — salience starts as pure spine-field
  heuristics; the feedback log exists so a learned policy *can* be added behind the same
  interface later.
- No cross-device sync, no CRDT machinery: the log is per-store, single-writer,
  session-linearizable. Fleet aggregation is projections, not replication.
- No mid-history edits, ever (§3, §7) — history is immutable; corrections are new events.
- No automatic secret redaction in v1 (policy isolation by capability row instead); a
  redaction pass is a possible future `yamaarashi-flow` projection job.

## 10. What remains to decide here (the next revision's agenda)

1. Compression trigger/span/loss-budget policy, stated as testable rules (§5.2) — decided
   by the §8.2 grid sweep once the harness exists; the *rules' form* (threshold vs
   turn-boundary triggering) is itself a grid dimension, not a pre-decision.
2. Salience v1 feature set over spine fields (§5.2) — decided by §8.2 ablation; ship the
   cheapest subset within ε.
3. The `PolicyEffect` encoding — now spec'd in §5.1.4 v0.2 (decisions phantom-tagged by
   a closed kind, capability-row components, single-writer turn program, consent proof);
   adoption via the six-scenario expressiveness trial at implementation time.
4. Retrieval backends: lexical index shape (§5.3) and whether embeddings land in Phase 2
   or 3 (hokora ships lexical only) — decided by the §8.2 precision@k crossover.
5. The `SomeRow` tagging scheme for `(kind, schemaV)` — interplay with the catalog's
   `SomeRow` standard (EFFECT_CATALOG_DESIGN §6.4) needs one worked example — decided by
   property tests (round-trip, reducer filtering, cross-dialect), correctness-gated.
6. Build the §8 instruments themselves: cache simulator, policy harness, first synthetic
   corpus + checker. This is a backlog item in its own right (see NIH_PLAN backlog),
   sized for the hokora phase.
