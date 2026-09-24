# The Policy Experiment Instruments — Spec

Status: DRAFT v0.1 · 2026-09-24 (spec per NIH_PLAN backlog item 10)
Related: `MEMORY_ENGINE_DESIGN.md` §8 (the empirical protocol this operationalizes),
§5.1.4 (PolicyEffect — policies as decision-producers), `EFFECT_CATALOG_DESIGN.md`
(model interpreters, law testkit), `HOKORA_SPEC.md` (instruments seed, LOC protocol),
`NIH_PLAN.md` §4 (benchmark ledger)
Naming: **kakegoe** (掛け声) — blessed 2026-09-24 as the package title. Kakegoe are the
drummers' calls that coordinate the 四拍子 (shibyōshi, the four-beat coordination of
stick, drum, flute, and voice in Noh) — i.e. *how the ensemble is coordinated*, not the
instruments themselves. That is the faithful description of this package: it coordinates
the system's rhythm (experiments, metrics, seeds) rather than being an instrument. The
one-word English gloss "instruments" slips a little semantically; the Japanese title is
carried as the true name (maintainer's rationale, recorded verbatim in spirit).

---

## 0. Purpose

`MEMORY_ENGINE_DESIGN.md` §8 promises that the memory policy's open questions
(compression triggers, salience features, retrieval depth) are decidable *empirically,
offline, before real usage* — via three instruments. This spec makes those instruments
concrete: their interfaces, the new design requirements building them surfaces (several
are genuinely new constraints on *other* packages), and the build order. The design
work here is mostly discovering what the experiment protocol *demands* of the rest of
the system — six requirements, §2 — rather than the instruments themselves, which are
small pure programs once those requirements hold.

## 1. The three instruments

### 1.1 The prefix-hash cache simulator

Provider prefix caching is a deterministic function of context bytes: identical early
bytes ⇒ hit. The simulator turns this into an offline measurement:

```haskell
-- The canonical renderer is SHARED CODE (see §2.1), not a test reimplementation.
renderCanonical :: ProviderFamily -> ContextRow -> ByteString

-- The simulator: hashes prefix blocks at each turn boundary and intersects
-- with the previous turn's hashes.
data CacheSim = CacheSim { blockBytes :: Int, family :: ProviderFamily }

simulateTurn :: CacheSim -> HashesPrev -> ContextRow -> (HashesNow, CacheVerdict)
-- CacheVerdict = FullHit | PartialHit Ratio | Miss
```

Measurement semantics: per turn, the context is rendered, split into fixed-size blocks,
hashed; the verdict is the fraction of the previous turn's prefix blocks reproduced.
Blocks (not whole prefixes) give partial-hit visibility, which matters for evaluating
suffix-only policies (PolicyEffect `TailOnly` should be ≈1.0 every turn; a
`PrefixBreaking` policy shows its exact decay curve). Hashes are comparable only within
one serializer version (§2.1) and one `blockBytes` — both are recorded in the experiment
manifest (§2.5). The simulator approximates provider behavior; it is an *upper-bound
model* of caching, which is the right direction for gating policy choices: if a policy
wins under pessimistic assumptions, it wins.

### 1.2 The policy replay harness

Under PolicyEffect (§5.1.4), a policy is a program
`∀ es. PolicyCap es => Eff es [SomeDecision]` — so replaying it is a matter of
*supplying interpreters* that are pure functions of frozen inputs:

```haskell
runReplay :: CorpusSession -> Transcripts -> Policy -> ReplayResult
-- interpreters used:
--   SessionStore : served from the corpus snapshot (raw log, cursor semantics per §3.4)
--   ModelAPI     : served from recorded transcripts (deterministic)
--   Log          : captured, not printed
--   Clock        : absent from PolicyCap by definition — no time, no nondeterminism
```

The harness then *simulates* the turn program's executors over the returned decisions:
`extend`/`rewrite` applied to a rebuilt `ContextRow`, cache verdicts from §1.1, token
accounting from the renderer's output. Policies never touch a network, a store, or a
clock; two runs of the same (policy, corpus, transcripts) are byte-identical — which is
itself a property test. The harness reuses the testkit's model-interpreter pattern
(EFFECT_CATALOG_DESIGN §6.6); it is the law harness generalized from "laws" to
"experiments".

The derived metrics, formulas pinned (§2.6), are computed from `ReplayResult` rows.

### 1.3 Corpus + checker

A **corpus** is a directory of synthetic sessions, each a sequence of events *in the
blessed envelope format* (the corpus is a log — dogfooding the same
`SessionStore` interpreters, §2.3), plus per-turn metadata. A **checker** is a pure
predicate over a turn's outcome:

```haskell
data Verdict = Solved | Failed | Uncheckable deriving (Eq, Show)

-- total, deterministic, no model calls; model-graded checking is out of scope for v1
checker :: TurnExpectation -> TurnResult -> Verdict
```

`Uncheckable` is a *reported* verdict, never silently dropped — metric integrity
requires the denominator to be honest (§2.6). Coding-shaped checkers follow the
shikumi-family pattern: file-expectation predicates (a file exists with certain
content shape), pure and cheap.

## 2. What building this demands of the rest of the system

Six requirements, each a real constraint that lands on another package's design. This
section is the spec's most important output.

### 2.1 The canonical context renderer is shared code, not test code

The simulator hashes "the context bytes as the provider sees them." Our approximation
is only meaningful if the *same* rendering produces the bytes sent to the real provider.
So context-row → wire-JSON rendering must exist **once**, as a pure, total function
owned by the LLM substrate (`sarutahiko-model`), versioned per `ProviderFamily`
(field order, whitespace, and message ordering are all part of the hash), and consumed
by both the real `ModelAPI` interpreter and the simulator. If a test reimplements
rendering, the simulator silently diverges from reality and every cache measurement
becomes fiction. *New obligation on the LLM substrate design note:* the renderer is a
named deliverable with its own golden tests.

### 2.2 Recording interpreters must be pure functions of frozen inputs

The harness's interpreters (corpus-served `SessionStore`, transcript-served `ModelAPI`)
must be *deterministic*: same inputs ⇒ same operations ⇒ same outputs. This forbids
serving policies from mutable derived state (raw log only, per the spine principle) and
confirms `Clock`'s absence from `PolicyCap` as load-bearing. The requirement generalizes
the mock-interpreter rule: **mocks are interpreters with laws**, and the testkit's parity
gate covers them like any other interpreter.

### 2.3 The corpus is a log in our own format

Corpus sessions use the blessed envelope (spine v0.2, `SomePayload` witnesses) and load
through the ordinary `SessionStore` interpreters — no parallel ad-hoc format. Corpus
files carry their own `schemaV` and obey strict-across/lenient-within (§3.4a), so corpora
recorded today still replay after payload extensions. *New obligation on the memory
note:* corpus files are the second consumer of the envelope format (after real stores),
which raises the format's test coverage contract.

### 2.4 Privacy: synthetic-first, scrub-manifest-gated

Default corpora are synthetic (seeded generators — generator seeds are manifest data).
Real sessions enter corpora **only** through a scrubbing pipeline that is a
`yamaarashi-flow` projection job emitting a *scrub manifest* (which fields/kinds were
removed or rewritten). Rule: no corpus contains real payloads without a scrub manifest
alongside. This is the memory note's §7 privacy discipline, extended to experiment
artifacts.

### 2.5 Experiment records are data, and experiments must be reproducible

Every experiment run writes a record to a dedicated row-typed store
(`hashigakari-sqlite`): the manifest (policy content hash, corpus content hash,
renderer/serializer version, `blockBytes`, generator seeds, grid-cell parameters, tool
versions) plus measurement rows. The benchmark ledger (NIH_PLAN §4) gains this as its
concrete substrate. Reproducibility rule: **an experiment must be re-runnable from its
manifest alone** — which makes manifest hashes part of the definition of "done" for any
experiment, and makes the Pareto comparisons of the compression sweep auditable after
the fact.

### 2.6 Metric formulas are pinned, with honest denominators

| Metric | Definition |
|---|---|
| `cache_hit_rate(t)` | reproduced prefix blocks at turn *t* ÷ prefix blocks at turn *t* (§1.1) |
| `tokens_per_solved` | Σ context tokens over turns ÷ #Solved, **Uncheckable excluded from the denominator but reported** |
| `compression_frequency` | `rewrite` events ÷ turns |
| `retrieval_precision@k` | relevant-retrieved ÷ k, against corpus relevance tags; **`RetrievalHit` events are derived by the harness from `Retrieve` decisions + tags — policies never write them** (policies return decisions; the harness observes) |
| `rebuild_cost` | wall-clock and allocations for reducer rebuilds (informational) |

Pinning formulas in the spec prevents the classic benchmark failure: metrics drifting
between runs of the same experiment.

## 3. Package layout

| Package | Contains |
|---|---|
| `kakegoe` | cache simulator, replay harness, metric formulas, experiment-record store access, corpus loaders. Depends on: effect-signatures, memory rows, `sarutahiko-model`'s canonical renderer. |
| `kakegoe-gen` | the synthetic corpus generators (separated so the measurement core has no generator dependencies) |

Checkers are *corpus data* (pure functions shipped with corpora), not a package.

## 4. Build order and phase placement

1. **Canonical renderer** (in `sarutahiko-model`, with golden tests) — everything else
   depends on it; started with the LLM substrate note.
2. **Cache simulator** — small; needed for the hokora's metrics seed.
3. **Transcript-serving `ModelAPI` interpreter** (testkit extension) — needed by both
   the harness and ordinary tests; lands with the effect catalog's testkit.
4. **Corpus format + generators** — after the envelope format is real (hokora phase).
5. **Replay harness + experiment records + metric formulas** — completes the §8.2
   experiment designs (grid sweep, ablation, crossover).
6. **Scrubbing pipeline** — deferred until real sessions exist (post-hokora).

The instruments are tooling: excluded from the hokora's ≤2k LOC budget, counted in the
benchmark ledger as tooling lines.

## 5. Validation of the instruments themselves

- Simulator determinism: same (context, params) ⇒ same hashes/verdicts.
- Harness determinism: same (policy, corpus, transcripts) ⇒ byte-identical
  `ReplayResult`.
- Renderer golden tests: pinned context rows ⇒ pinned bytes, per family/version.
- Corpus round-trip: corpus files load via `SessionStore`, reducers over them match
  generators' expectations.
- Metric sanity: a deliberately cache-breaking policy must show decaying
  `cache_hit_rate`; a `TailOnly`-only policy must hold ≈1.0 — the instruments must be
  able to detect the failure modes they exist to find.

## 6. Open items

1. Renderer version policy: when does a `ProviderFamily` renderer change force a new
   serializer version (and thus incomparability with old hashes)? Propose: any
   byte-affecting change bumps it; experiment manifests make the incomparability
   explicit rather than hiding it.
2. Transcript format details (request/response rows, recording fidelity for tool
   streams) — lands with the LLM substrate note.
3. Synthetic generator catalog v1 (which task shapes?) — propose: mirror the hokora
   shapes plus one long-session shape (kanban-like) and one retrieval-heavy shape;
   grows on demand.
4. Noh naming blessing for `kakegoe` (or confirmation of the neutral working name).
