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

### 3.1 The envelope row

Every event is a row with a fixed administrative spine and an open payload:

```haskell
type Envelope extra =
  '[ "eventId"   ':= UUID          -- monotone per store (kiroku-style)
   , "kind"      ':= Kind          -- closed enum of event families
   , "schemaV"   ':= Natural       -- payload schema version
   , "ts"        ':= UTCTime
   , "session"   ':= SessionId
   , "actor"     ':= Actor         -- user | model | tool:<name> | system:<component>
   , "cause"     ':= Maybe UUID    -- provenance chain (tool call caused observation)
   , "payload"   ':= SomeRow       -- existentially packaged, tagged by (kind, schemaV)
   ] ++ extra
```

The spine is chosen so that *every* reducer and every retrieval index can be built from
spine fields alone, without decoding payloads — `payload` is only decoded by reducers that
have opted into a specific `(kind, schemaV)`.

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
   and Postgres (fleet). The only safe assumptions are: monotone insertion ids (not UUID
   ordering), session-scoped linearizability, and no cross-session ordering. Reducers that
   would need global ordering are wrong and get redesigned.

### 3.3 What counts as an event

Err on the side of *too many* kinds, factored late: `MessageAppended`, `ToolInvoked`,
`ToolObserved`, `ContextCompressed`, `CheckpointTaken`, `PinnedAdded`/`Removed`,
`MemoryWritten` (long-term), `RetrievalHit` (feedback for policy learning), `BudgetAdjusted`.
Compression *writes an event* (`ContextCompressed`) rather than mutating history — the
cache-breaking moment is thus itself in the log, replayable and auditable.

## 4. Reducers — the easy part, stated precisely

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
4. Policy components must *declare* their cache impact: `Pure` (reads only), `TailOnly`
  (appends), `PrefixBreaking` (requires §5.1.2 conditions). The type
  `PolicyEffect = PrefixBreaking | TailOnly | Pure` is a row field on every policy
  component, checked by the turn program — the capability-row idea applied to cache
  hygiene.

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
3. The `PolicyEffect` row-field type's exact encoding and its enforcement point in the
   turn program (§5.1.4) — not metric-decidable: decided by an expressiveness trial
   (can the encoding express all §5.1 contract clauses and reject a violating policy at
   the enforcement point across a scenario suite?), i.e. compile-time, not runtime.
4. Retrieval backends: lexical index shape (§5.3) and whether embeddings land in Phase 2
   or 3 (hokora ships lexical only) — decided by the §8.2 precision@k crossover.
5. The `SomeRow` tagging scheme for `(kind, schemaV)` — interplay with the catalog's
   `SomeRow` standard (EFFECT_CATALOG_DESIGN §6.4) needs one worked example — decided by
   property tests (round-trip, reducer filtering, cross-dialect), correctness-gated.
6. Build the §8 instruments themselves: cache simulator, policy harness, first synthetic
   corpus + checker. This is a backlog item in its own right (see NIH_PLAN backlog),
   sized for the hokora phase.
