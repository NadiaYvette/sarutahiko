# The Observability & Serviceability Substrate — Design Note (kagami-ita 鏡板)

Status: DRAFT v0.1 · 2026-09-24 (backlog item 11, raised and named by the maintainer)
Related: `EFFECT_CATALOG_DESIGN.md` (signature discipline, dual interpreters, capability
rows), `MEMORY_ENGINE_DESIGN.md` (envelope versioning §3.1, compression, PolicyEffect
§5.1.4 — the event vocabulary generalized here), `INSTRUMENTS_SPEC.md` (kakegoe — the
first metrics consumer), `HOKORA_SPEC.md` (the first serviceability consumer),
`INFRASTRUCTURE.md` (io-sim, test tiers), `NIH_PLAN.md` §6.1 (naming registry),
`registers/REUSE_REGISTER.md` 2.20 (mergeable quantile sketches)

**Name.** *kagami-ita* (鏡板) — the mirror-board at the rear of the Noh stage: the
stage's own surface that returns the performance to the audience. The observability
layer is exactly this: the system's own surface turned toward its observers. Blessed
2026-09-24; alternates considered are recorded in §9. Package split is decided at
Phase 0 (working family name `kagami-ita`).

---

## 1. Thesis and scope

Observability here is not a bolt-on library choice (no OpenTelemetry-versus debate);
it falls out of the architecture. Every interesting behavior the ecosystem exhibits
already flows through an effect signature — `ModelAPI` calls, `SessionStore` writes,
`Process` spawns, DB transactions, `PolicyEffect` decisions. The interpreter edge is
therefore the natural — and *only* — instrumentation point. This note fixes the
invariants of that design and records its open questions; it is a design, not a plan.

Scope: what the running system makes visible about itself — event emission, tracing,
metrics, replay-based debugging, serviceability. Consumers: humans; the kakegoe
instruments (first metrics consumer); the doc-drift judge (first machine consumer of
drift findings as rows); future dashboards (Phase 3).

## 2. The choke point — interpreters, not call-site logging

Four invariants (K1–K4), enforceable by catalog law, review gate, and testkit:

- **K1 — instrumentation is an interpreter concern.** Production code writes effect
  calls; no logging/metric literals in business logic. What to observe is decided at
  handler-construction time by adding interpreters to the row.
- **K2 — dual interfaces, observer-effect law.** Every observable effect has a real
  and an instrumented interpreter (the dual-interface doctrine, extended to
  observation); instrumentation must not change semantics — the parity testkit runs
  both and asserts equal observable results. io-sim gives the deterministic twin.
- **K3 — structured, row-typed events.** No printf-style logging. Events are
  existentially packaged rows (`SomeRow`, EFFECT_CATALOG §) under the envelope
  discipline generalized from the memory log: versioned, additive evolution,
  append-only. The catalog's `Log` signature payload *is* the kagami-ita envelope.
- **K4 — zero-cost when absent, granted when present.** No tracing interpreter in the
  handler row ⇒ no cost. Emission capability is granted per subsystem capability-row
  style (`Observe :<: es`), making "who may emit what" compile-time.

## 3. The event vocabulary

Envelope (generalized from MEMORY_ENGINE §3.1 — the one irreversible decision there,
deliberately reused here rather than reinvented):

```
envelope { v      — envelope version (additive evolution, PVP-for-rows)
         , ts     — timestamp (virtual time under io-sim — tests replay instantly)
         , source — emitting subsystem (capability provenance)
         , corr   — correlation id (turn / span / request lineage)
         , kind   — event kind (the row tag below)
         , payload— SomeRow, kind-indexed }
```

Event kinds (seed set; additive): agent-turn boundaries; model-call (request id,
token accounting, cache hits — feeds the utai L1–L4 evidence and the kakegoe
simulator); store transaction; process spawn/exit/signal; hook dispatch; **policy
decision** (every `PolicyEffect` outcome — the audit trail for cache-safety and
salience choices); doc-drift judge findings (measurement-as-rows, the kakegoe §2.5
pattern). Policy decisions are never sampled (O5).

Correlation: ids ride rows between effect boundaries; span/context threading is
O2's decision (scoped effect vs plain row member).

## 4. Metrics as derived views (log-first)

No metrics are pushed through effect calls at the emission site. Metrics are
**reductions over the event stream** — pure functions from envelopes to summary
structures, computed lazily/at-rainbow-boundary and stored in the kakegoe
experiment-record store. This keeps production handlers minimal, makes every metric
recomputable from the log (the replay thesis), and matches the program's
performance-by-theory stance.

The summary structures are **mergeable quantile sketches** (register 2.20 — the
maintainer's own t-digest anchors the family):

| Sketch | Property | Use |
|---|---|---|
| t-digest (own, `github.com/NadiaYvette/t-digest`, publication-pending, may be reworked) | mergeable centroids, tight rank error at tails | latency histograms, token-count distributions |
| Greenwald–Khanna | deterministic ε-quantile bound, no merge emphasis | when strict rank guarantees are wanted |
| Q-digest (Ivkin et al., arXiv:1907.00236) | integer-weighted bucket tree, small fixed domains | status codes, retry counts, cache-hit classes |

Choice per metric is deferred to first use; sketches are pure, hence testkit-able,
and their snapshots are storable rows in experiment records. The three named
algorithms cover the practical space (tail-weighted, guarantee-bound, domain-limited);
the open corner is heavy-hitter/top-k over high-cardinality keys, noted as O7.

## 5. Tracing and replay (serviceability)

The recording interpreters already required by kakegoe (deterministic mock
`ModelAPI`, corpus-as-log) *are* the capture mechanism. A trace is an effect log
under the envelope; **replay** feeds recorded rows to any interpreter — patched code,
alternative policy, io-sim schedule — turning serviceability from "add breakpoints"
into "replay the recording and bisect." Consequences:

- The hokora's replay-from-crash exit criterion is satisfied by construction.
- The doc-drift judge cites execution evidence rather than re-deriving it
  (DOC_STRATEGY §2).
- Debug affordances are cursors/steppers over recordings — the same stepper worldview
  as every other existential cursor in the program.

Dependency direction (O4): recording interpreters live in kagami-ita as substrate;
kakegoe *configures and consumes* them. Instruments measure; kagami-ita makes
measurable.

## 6. Privacy and exposure posture

Traces contain prompts (memory content) and secrets-adjacent material. The
scrub-manifest rule (INSTRUMENTS_SPEC §2.4) governs any trace leaving the machine;
because events are kind-indexed rows, scrubbing is a per-row-kind *policy* — declared
in the same style as PolicyEffect, not ad-hoc string munging. Default sinks are
local; any external export is an explicit interpreter swap at the edge (K1's
corollary: even *where observations go* is an interpreter decision).

## 7. Small-context accommodation (the cogito:3b lesson)

The maintainer's cogito:3b run against this repo truncated a 32 KB assembled context —
the limiting factor was the consumer, not the corpus. Standing policies:

- **AGENTS.md is a pointer file with an explicit ~4 KB budget** — an index into
  selectively loadable canonical documents (the §1 projection doctrine, now a design
  constraint). DOC_STRATEGY §1 records this.
- Every canonical document leads with a short header block (status, related, thesis)
  so a small-context reader can decide *whether* to load more without reading it all.
- The envelope is row-decomposed so envelope-without-payload is a valid summary
  unit; small consumers can ingest kind+corr+ts and defer payloads.
- Event kind registries are enumerable tables (this note, §3) rather than prose.

## 8. Open questions

- **O1 — retention defaults per kind.** Proposal: raw events local-only with a
  rolling window (default 7d); sketch snapshots retained indefinitely in experiment
  records; model-call bodies scrub-gated (§6).
- **O2 — spans: scoped effect or row member?** Scoped (one `Observe` region per
  span) composes with `Scoped` and forbids cross-span leakage by construction; a
  plain row member is simpler but allows unmatched begin/end. Leaning scoped.
- **O3 — metrics exposure.** Pull-from-stream only (per §4) until a Phase-3
  dashboard demands a wire exporter; revisit then.
- **O4 — recording interpreters' home.** kagami-ita (substrate) hosts; kakegoe
  configures (per §5). Confirm when INSTRUMENTS_SPEC next revises.
- **O5 — sampling.** Policy decisions and agent-turn boundaries never sampled;
  per-kind tiering otherwise (O1).
- **O6 — envelope canonical home.** Generalized *from* the memory log; whether the
  definition lifts to the substrate (fields/records tier) or stays referenced from
  MEMORY_ENGINE. Lean substrate lift at Phase 0.
- **O7 — high-cardinality summaries.** Top-k/heavy-hitters over unbounded keys
  (e.g. tool names) — the one practical gap in the three-sketch family; likely
  count-min at need, judged per the register when demand arrives.

## 9. Naming record

Blessed 2026-09-24: **kagami-ita (鏡板)** — mirror-board; the stage's own surface
returning the performance to the audience. Alternates considered and held in the
registry: *mawari-butai* (廻り舞台, the revolving stage — the 360° view), *hanamiko*
(花道, the runway through the audience — the path from stage to observers), *mie*
(見得, the dramatic held pose — snapshot semantics; narrower, reserved). See
`NIH_PLAN.md` §6.1.
