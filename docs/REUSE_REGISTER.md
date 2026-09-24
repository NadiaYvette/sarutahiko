# The Reuse Register — Doctrine and Case Ledger

Status: v0.1 · 2026-09-24
Related: `NIH_PLAN.md` (§0 decisions, §2 package map, the code-volume ledger), all design
notes under `docs/`
Purpose: a standing record of every reuse-or-reimplement decision the program makes, with
reasoning and revisit triggers, so the question "why not just use X?" is answered once, in
writing, and stays answered. When this document outgrows `docs/`'s flat layout, it becomes
`docs/decisions/` (one file per case, or an index — to be decided by its actual growth
shape, per the maintainer's anticipation).

---

## 1. The doctrine

The program's motivations for reimplementation are stated once, here, because every case
below is judged against them:

1. **Design aesthetics** — the codebase should be built from the blessed principles
   (rows for shape, effects for behavior, streams for time, GADTs for legal states).
2. **Re-grounding Haskell coverage** — points of functionality long covered by
   first-iteration Haskell libraries deserve re-coverage under more advanced design
   principles.
3. **Redesign from first-iteration experience** — where a first iteration exists, its
   lessons (and its users' complaints) are design input; Nadeem's stack is the
   richest such source we have.
4. **Integration contact** — components must compose with our protocol stacks, record
   vocabulary, and effect catalog without per-call-site adapters.

Against those, reuse is favored when a candidate satisfies the **core test**:

> **Reuse engines whose cores already embody the principles; reimplement protocols and
> vocabularies whose cores are first-iteration counterexamples.**

Operationalized as three questions, asked in order:

- **Q1 (core embodiment).** Does the candidate's *core* (not its edges) already embody the
  principles at least as well as we would? (hasql's applicative decoders: yes. A nominal
  DTO vocabulary: no — that is the thing being replaced.)
- **Q2 (seam containment).** If reused, does all contact happen at a small, stable,
  logic-free seam — with nothing leaking into signatures, rows, or user-facing APIs?
- **Q3 (provenance economics).** Is the maintenance we inherit (churn, upstream coupling,
  API drift) cheaper than building and maintaining the replacement *at this layer*? The
  code-volume ledger is the accounting frame.

A "no" on Q1 is usually fatal unless the candidate is a pure *transport* (Q1 does not
apply to bytes); a "no" on Q2 or Q3 can be cured by layering. Decisions are recorded with
their revisit triggers; a triggered revisit re-enters the ledger at the top.

## 2. The case ledger

### 2.1 large-records / large-anon / large-generics (foundation) — REUSE (ours)
The forward-ported record foundation *is* the program's basis; vinyl interop maintained.
Not a decision so much as the ground the doctrine stands on.

### 2.2 effectful + polysemy (effect runtimes) — REUSE, with dual-interface rule
Our executables run effectful; every library ships neutral signature packages with both
interpreters (NIH_PLAN §0). Q1: yes — both embody effect-row composition; our contribution
is the *catalog* above them, not a new runtime. Rolling our own kernel was considered under
the streaming analysis and rejected there for the same reasons. Revisit triggers: a
fundamental expressive gap in effect rows (e.g. capability-row soundness failing), or the
streaming-as-effect spike (`eff`-style continuations) concluding runtimes should be
continuation-based.

### 2.3 conduit / streamly (streaming backends) — REUSE as backends, KERNEL as API
The yamaarashi decision (YAMAARASHI_DESIGN §3, §3.5 gates): the dependency-free
church-encoded kernel is the API; streamly (pinned) and conduit are embeddable backends;
porcupine's semantics are re-homed as the DAG layer. Q1 on streamly's *sequential core*
was judged "embodies, but via compiler magic rather than design we can extend" — hence
backend, not API. Gates trip kernel work only on benchmark evidence.

### 2.4 hasql (Postgres engine) — REUSE as engine (hashigakari over it)
The case that calibrated the doctrine. Q1: **yes, unusually strongly** — hasql's core is
already compositional design: explicit applicative row decoders/encoders (no typeclass
driving deserialization), a mechanically-sympathetic binary-protocol implementation,
native cursor support. It is the "engine whose core embodies the principles" almost
verbatim. Q2: hashigakari's existential cursor steppers contain it exactly. Q3: connection
pools, binary protocol decoding, and TLS are low-ROI to rebuild and high-risk to get wrong.
**What we build instead of on top of its query layer:** the row-typed AST, dialect
compilation, TriState patches (`HASHIGAKARI_DESIGN.md` §0: "the SQL wire and connection
machinery are *not* rebuilt; hasql serves as execution engine"). Revisit triggers: hasql
stalling on a GHC major we need; a need for non-Postgres *binary-protocol* features it
cannot express (SQLite path already exists separately, so this is narrow); a future
effect-native redesign of connection lifecycle that hasql's session model resists.
Source-doc corroboration: the records doc's verdict ("use hasql strictly as the backend
execution engine") preceded and matches this analysis.

### 2.5 SQLite (via direct-sqlite) — REUSE as engine (hashigakari over it)
Same shape as 2.4 at the C boundary: `sqlite3_step` as a stepper, SQL dialect ceiling
handled by hashigakari-syntax. The C library itself is out of NIH scope by Q3 (decades of
correctness we cannot improve; FFI cost is contained in one interpreter).

### 2.6 typed-protocols (session-type framework) — DISTILL FIRST, framework as future backend
Decision recorded in NIH_PLAN (state-machine ledger row) and committed to the wire-layer
plan: internal invariants use phantom-indexed GADTs directly; the MCP/LSP session machines
follow typed-protocols' pattern (agency-indexed states + peer GADT) distilled
dependency-light, in a framework-compatible shape so the full 1.2.x framework — including
lookahead — can slot in as a backend if pipelining/lookahead or the proof layer earns their
weight. Q1: yes (the pattern is right); Q2/Q3 tipped toward distill because our wire layer
needs symmetric peers + unknown-method tolerance, which means custom states on top anyway.
Revisit trigger: the Phase-1 session GADT's expressiveness trial.

### 2.7 aeson (JSON) — REUSE as bytes layer, ROW CODECS above it
JSON bytes parsing/serializing is transport (Q1 N/A). Our record codecs (record-soup/
docrecords lineage) produce/consume aeson Values; aeson never appears in signatures or
user-facing rows. Per-format envelopes and unknown-field preservation live in the codec
layer. Revisit trigger: none foreseen; the abstraction seam is trivial.

### 2.8 persistent / esqueleto (ORM layer) — NOT REUSED (superseded by hashigakari)
The records doc's analysis stands: persistent's TH-generated nominal entities bind tables
to ADTs, the exact anti-pattern; esqueleto's projection tuple-exhaustion is the symptom
class the row AST eliminates. No Q1 case exists. Revisit trigger: none — hashigakari
replaces the layer outright.

### 2.9 beam / rel8 (query builders) — NOT REUSED; BRIDGE as the boundary contribution
Per the records doc and HASHIGAKARI_DESIGN §4: gutting beam's tuple mechanics means
rewriting it; rel8 is Postgres-tight with its own HKD generics. The chosen contribution is
`hashigakari-beam` (`beam-large-anon`) — a standalone bridge giving *beam users* rows at
their boundaries while our tree uses hashigakari natively. Q3: bridge cost is small,
publication value is ecosystem-wide. Revisit trigger: if the bridge needs beam AST changes
to work, stop (scope guard already written).

### 2.10 servant (web/type-level routing) — NOT REUSED (deferred beside the codec bag)
The maintainer's question, grounded: baikai rides `servant-client ^>=0.20` plus the
`openai` SDK (itself servant-based); servant's role there is type-level route/service
description compiled to clients, with `ClientEnv` = base URL + `Manager` (baikai's
`Http.hs` caches exactly that pairing). **Our verdict: servant is a first-iteration
type-level vocabulary for HTTP services — the same design class our row vocabulary
replaces — and its analogue is therefore deferred to the codec bag, not adopted.**
Reasoning per doctrine: (a) Q1 fails — servant's core is generic-rep-derived route types
and combinators, precisely the compile-time-cost class large-anon exists to bypass, and
HTTP/JSON transport does not need another embedded DSL to describe it (Q1-N/A transport
exemption applies to *bytes*, not to route *vocabularies*); (b) our protocols layer
describes endpoints as *rows* (methods, paths, option rows) and dispatches through open
variants — MCP/JSON-RPC needed no route DSL, and the same machinery serves REST-ish
surfaces (the gateway's web server, dashboard) when Phase 3 arrives; (c) where servant
genuinely shines — deriving typed clients from a service description — our equivalent is
schema descriptors + row codecs, already committed for MCP `inputSchema` and provider
APIs. So: no servant dependency anywhere in the tree; if a Phase-3 surface wants
type-level route documentation, it gets a row-descriptor renderer instead. Revisit
trigger: a concrete integration (e.g. consuming an existing servant-typed third-party API)
where wrapping costs exceed writing a codec — judged per-case in this register.
Corollary noted: the `openai` SDK (servant-generated, haddocks-verified by baikai's own
comments as occasionally diverging from reality) is doubly displaced by `utai-openai` —
by the codec decision *and* by the servant verdict.

### 2.11 http-client / http2 / tls (HTTP transport) — REUSE as transport (pending first use)
Bytes-level; Q1 N/A. The LLM codecs and gateway surfaces ride `http-client` (+ http2/TLS)
behind `Resource`-managed interpreters. The reuse doctrine's transport exemption applies
in full. Revisit trigger: none foreseen.

### 2.12 porcupine (task DAG) — RE-HOME (reimplement semantics on our substrate)
The forward port is ours already; yamaarashi-flow re-homes ArrowFlow over `Eff es` with
row-typed chunks and the determinism-tagged cache. Not a reuse question but a relocation,
recorded for completeness.

### 2.13 Dhall (configuration evaluator) — REUSE the evaluator, BRIDGE the marshalling
The source doc's verdict, unchanged: Dhall's evaluator is a mature implementation of a
language whose row types are runtime-evaluated — mapping them onto our static rows is a
marshalling concern only (`sarutahiko-format-dhall`, a bridge package), never evaluator
rewriting. Q1 on the evaluator itself: yes. Revisit trigger: none.

### 2.14 baikai (provider-neutral LLM client) — NOT REUSED as engine; REFERENCE + DONOR
The v0.2 decision (`LLM_SUBSTRATE_DESIGN.md` §0): the glue-only path exists (the arena),
so adoption needed justification beyond reuse and fails under the program's motivations;
its nominal vocabulary is the first-iteration class the program replaces; the
hashigakari-over-hasql transplant was an analogy mismatch (hasql's core embodies the
principles; baikai's does not). Provider APIs are codec-bag members: `utai-openai`,
`utai-anthropic`, `utai-local`. Baikai's laws survive adopted-and-confirmed (L1 terminator,
L2 usage monoids, L3 option honesty, categorized errors); its registry evolution
validates handlers-as-records. Revisit triggers: a provider family whose codec cost is
provably disproportionate (recorded transcripts will tell), or an upstream baikai
development we'd rather contribute to than duplicate (e.g. a row-native renaissance —
unlikely, but the register keeps the door labeled).

### 2.15 The `openai` Hackage SDK — NOT REUSED (doubly displaced)
Servant-generated client bindings; displaced by the codec decision (2.14) and the servant
verdict (2.10). Baikai's own experience (haddocks diverging from actual API behavior)
counted as evidence that generated bindings drift from wire reality — our codecs are
verified against recorded transcripts instead.

### 2.16 brittany (formatter) — REUSED, WITH UPSTREAMING (maintainer is the contributor)
Chosen over fourmolu (INFRASTRUCTURE §2): the maintainer prefers brittany's
expressive layout (intelligent horizontal space and alignment; comment fidelity) and
holds an unusual provenance position — a 42-commit series in `~/src/brittany` ahead of
the stale lspitzner upstream (GHC 9.14 support, comment-handling repairs, test
modernization), with a close relationship to the new package maintainer who adopted
brittany and included the series. Formatting adjustments flow upstream rather than
forking. Risk (GHC-API coupling, historical unmaintained banner) is managed by the
series itself; CI pins the fork (or its Hackage successor). Revisit trigger: brittany
failing to format an adopted GHC feature faster than upstream extension.

### 2.17 hlint (linter) — REUSED, WITH RULE PATCHING
No credible alternative exists, and NIH is a heavy lift versus protocol libraries (the
cost class is different: semantics-preserving source transformation over the full GHC
AST). Maintainer holds a clone (`~/src/hlint/`); program-specific rules and rule
patches flow upstream. The design-mandated custom lints (SQL ordering, dual-effect
parity, layer directions) remain bespoke CI jobs — hlint is the general linter, not
the layer-lint substrate.

## 3. Cases to be decided (parked, with their trigger)

- **warp / wai** (HTTP server): Phase-3 surfaces (gateway, dashboard). Expected: reuse
  transport, row-describe the surface; judge against the servant analysis when real.
- **brick / vty vs reflex-vty** (TUI): Phase-3; the TUI survey holds; judge with the
  registry+projection design in hand.
- **http2 server push / websocket libraries** (gateway platforms): judge per platform at
  Phase 3; transport exemption expected to hold.
- **zip / csv / xml staple codecs** (format bag demand order): expected codec-bag
  members; Q1 almost always fails for their nominal wrappers (the wrappers are the
  layer), transport exemption covers none of them — but each gets its own row when its
  demand arrives, per the doc.
- **kiroku / shibuya / keiro / kioku** (keiro stack): interop-first contact strategy
  (NIH_PLAN); reuse-or-reimplement is not currently posed — hashigakari reads/writes
  their formats; deeper integration decisions wait for the contact spike.
