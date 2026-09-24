# The Reuse Register — Doctrine and Case Ledger

Status: v0.1 · 2026-09-24
Related: `NIH_PLAN.md` (§0 decisions, §2 package map, the code-volume ledger), all design
notes under `docs/`
Purpose: a standing record of every reuse-or-reimplement decision the program makes, with
reasoning and revisit triggers, so the question "why not just use X?" is answered once, in
writing, and stays answered. If a register outgrows one file, it splits *within
`docs/registers/`* (per-case files plus an index) — the directory decision of
DOC_STRATEGY §5 supersedes the earlier `docs/decisions/` anticipation.

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
   lessons (and its users' complaints) are design input; the Nadeem Bitar (keiro)
   ecosystem is the
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

### 2.18 smirk (regex engine) — REUSED (the owner class; redesign on demand)
The maintainer's own ground-up PCRE engine (`~/src/smirk/`): pure native core (no C,
no FFI), fuel-bounded execution (ReDoS defense matching the program's fail-closed
deadline discipline), resumable continuations, mono-traversable sequence polymorphism,
and — decisively — pre-existing dual effect-interface packages (`smirk-effectful`,
`smirk-polysemy`) matching the program's dual-interface contract. Q1 passes on the
merits; Q2/Q3 are the strongest possible (maintainer *is* upstream). **i18n
obligation (recorded 2026-09-24):** Unicode regex concerns — case-insensitive
matching under locale/simple case folding, Unicode property classes, grapheme-correct
`.` and boundaries — are the known gap between PCRE-class engines and full Unicode
regex semantics; smirk's owner-class redesign scope explicitly includes resolving
them via the program's two-stage Unicode resolution (UCD property tables extracted
from checked-in UCD data files at build time, ICU as oracle). Program placement:
`sarutahiko-tags` (the ctags doc's regex/optlib extraction layer), log pattern
matching, hook command patterns, config edge cases. Unlike ordinary reuse, the design
may be reshaped for program needs (new combinators, row-typed match results, other
effect signatures) — the maintainer-redesign escape hatch of the owner class; the
cost model is that of internal development, not integration.

### 2.19 wai + warp (HTTP interface + server) — REUSED (transport interface, not vocabulary)
The instructive contrast with the servant verdict (2.10): wai is a tiny, frozen,
13-year-stable callback interface — no type-level DSL, no generics, no embedded
vocabulary — so it is *not* the design class the row vocabulary replaces; warp is pure
transport (HTTP/1.1+2, TLS, connection pools), Q1 N/A per the doctrine's transport
exemption, with industry-benchmark performance. Entry points: MCP Streamable-HTTP
transport (server mode of the wire flagship), the Phase-3 gateway, the dashboard. Cost:
one quarantined adapter over wai's minimal `Request`/`Response` types in the surface
package; vocabulary above remains rows. NIH'ing an HTTP server would be the anti-
doctrine: massive effort, zero design gain, against a mature protocol implementation.
Revisit trigger: wai friction in the MCP HTTP transport.

### 2.20 t-digest (NadiaYvette/t-digest) + the mergeable-quantile-sketch family — REUSED (owner class)
The maintainer's ground-up mergeable t-digest (`github.com/NadiaYvette/t-digest`,
publication-pending, flagged by the author as possibly needing rework) anchors the
sketch family for kagami-ita metrics (OBSERVABILITY_DESIGN §4): t-digest for
latency/token-tail distributions, Greenwald–Khanna where deterministic ε-quantile
bounds are wanted, Q-digests (Ivkin et al., arXiv:1907.00236) for small fixed integer
domains. Owner class: total control, redesign permitted as internal development
(reworked publish, algorithm tweaks, Haskell-idiomatic APIs — pure cores are
testkit-able per the catalog). Metrics are reductions over the event stream, so
sketch snapshots are storable rows in kakegoe experiment records. Open corner
recorded as O7: high-cardinality top-k/heavy-hitters is outside the three-family
space; count-min or similar judged per the register when demand arrives.

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
- **lhs2tex** (literate-Haskell → LaTeX): adopt-with-upstreaming when whitepaper or
  book work begins — enhance for the multi-source master-document assembly that
  DOC_STRATEGY §6 names as the literate-Haskell obstacle, depending on kosmikus'
  availability/situation (the brittany precedent: reuse with upstream-relationship
  class). Judge with the book aspiration when it becomes real.
- **hakyll** (site generator; cloned locally): adopt when the tutorial track needs
  navigation/search — replaces the pandoc script for site rendering only; the
  projection doctrine and script net are unchanged. Trigger: tutorial track begins.
- **katip / co-log / polysemy-log** (structured/composable logging): not posed as
  dependencies — kagami-ita's `Log` signature plus the row-typed envelope
  (OBSERVABILITY_DESIGN K1–K3) subsumes their designs (co-log's composable `LogAction`
  ≈ interpreter composition; katip's structured sinks ≈ interpreter sinks; the
  polysemy-log effect shape ≈ the catalog's `Log`). Recorded as nearest-neighbor
  reference designs so "why not just use katip?" stays answered. Trigger: any adoption
  pressure lands here first.
- **yesod / shakespeare `RenderMessage`** (typed i18n messages): pattern adopted,
  implementation declined — messages-as-data with total per-language dictionaries and
  edge rendering is exactly DOC_STRATEGY §6's typed-message rule, and yesod's handler
  helpers (`addMessageI`, `languages`) prove the shape at scale. The *implementation*
  stays unadopted on four counts, each replaced by row machinery: Template-Haskell
  `.msg`-file codegen (ours: message types as plain GADTs/rows, translation dictionaries
  as extensible records — totality by type inference, no TH; file formats remain a
  projection if wanted); `RenderMessage site msg` site-coupling (ours: a rendering
  capability in the effect row, serving TUI/log/HTTP surfaces alike); languages as
  bare `[Text]` (ours: typed language tags, BCP-47 via text-icu at the edge); and
  `Text`-only rendering with no plural/ICU support (ours: per-(locale, sink) rendering;
  ICU plural/select via the shim-or-pure decision of row 2.22 — text-icu does *not*
  bind MessageFormat, an assumption corrected on review 2026-09-24). The future
  shakespeare-derived i18n package is **designated a derived work of shakespeare**
  per the §9 credit convention (pattern adopted, implementation rewritten) — queued
  for CREDITS.md at the remediation commit. Reference: `~/src/yesod`
  (publication-pending), `Text.Shakespeare.I18N`.
  Trigger: first real surface ships user-facing strings (Phase 3).

### 2.22 text-icu (ICU4C bindings) — role revised 2026-09-24: oracle and reference source, not dependency (the i18n NIH decision)
**The direction (maintainer, 2026-09-24): the internationalisation ecosystem is NIH'd
pure-Haskell**, with faithfulness carried by (a) source analysis of ICU4C (semantic
ground truth) and the pure reimplementations Go x-text / ICU4X (architectural
references — ICU4X, the Consortium's own pure-Rust ICU, is the existence proof and
design donor), (b) formal verification aimed where it is strong (normalization
confluence; collation transitivity per UTS #10's mechanized axioms; bidi algebraic
properties), (c) empirical regression testing against the official UCD/CLDR
conformance files plus ICU as second oracle. Extensible records carry the redesign:
locale as a resolved record (CLDR inheritance as record merge — root ⊕ lang ⊕ region),
services as capability-granted effects, ICU-parity as an enforced law of the dual
interfaces, UCD/CLDR versions pinned in-tree (hermetic — row 2.22's three caveats
invert into design goals). Phased scope: normalization/case/properties, bidi,
plural rules + classic MessageFormat, BCP-47/locale resolution, number formatting
first; collation UCA+simple-tailoring then full CLDR tailoring; Gregorian+tz then
calendars; **dictionary-based breaking and text shaping stay at the edge** (codex /
harfbuzz) absent a heroic decision. The original reuse verdict is retained below as
the historical record and as the oracle role's justification.

---

### 2.22a text-icu (ICU4C bindings) — the original verdict (2026-09-24): REUSED as the locale primitive layer (with three recorded caveats)
ICU is the reference implementation of Unicode services — collation, normalization,
segmentation, case mapping, charset conversion/detection, regex, number/date
formatting, all backed by CLDR data. Reimplementing it fails Q1/Q2/Q3 outright (no
embedded vocabulary, pure protocol/data layer); the only design-class question is
API shape, and text-icu's thin FFI layer is exactly the kind of surface we
row-describe at the edge. **The three caveats, reviewed 2026-09-24:**

1. **Non-deterministic cleanup.** ICU handles live in `ForeignPtr`s finalized by GC —
   release is not prompt or deterministic. Our interpreters wrap ICU opens in the
   catalog's `Resource` scope (deterministic, bracketed) rather than trusting
   finalizers; text-icu's API permits this where handles are first-class (collators,
   break iterators) and is used value-style elsewhere.
2. **The locale-services layer is missing.** ICU4C's `MessageFormat`, `PluralRules`,
   `ListFormatter`, and the modern locale matcher are *not bound* by text-icu. When
   real locale work begins, the choice is a small FFI shim over `u_formatMessage`-era
   APIs or a pure-Haskell MessageFormat implementation (parser + plural selectors —
   plausibly a codec-bag-shaped NIH candidate; CLDR plural data as a checked-in
   projection). Decided at demand time per the register. The shim option has an
   existing precedent: **bidi-icu** (Kmett, in the codex monorepo) is precisely such
   a small shim — a single `.hsc` over ICU's `ubidi_*` — written for the Unicode
   Bidirectional Algorithm; see the parked bidi row below.
3. **CLDR/ICU-version variance.** Behavior (plural rules, collation tailoring, date
   patterns) varies with the system ICU version, and text-icu links system ICU via
   pkg-config. Doctrine contains this: locale rendering lives at the presentation
   edge, so metrics and experiment records never route through it (reproducibility of
   the ledger is unaffected); CI pins the ICU version where golden fixtures of
   rendered output exist. Corollary: locale-rendered text is never a *protocol*
   artifact.

Maintenance note: text-icu now lives under the haskell GitHub organization and was
last released 0.8.x (2024) — alive, slow-moving; transliteration split into the
`text-icu-translit` subpackage. Companion note: for the normalization slice alone,
**unicode-transforms** (pure Haskell NFC/NFD/NFKC) is the hermetic alternative —
preferred wherever normalization appears *below* the presentation edge (protocol
codecs, fixture canonicalization, log key normalization), because it removes the
system-ICU variance of caveat 3 from layers that must be reproducible; text-icu (or
ICU itself) remains the edge-layer choice for collation/dates/numbers, and doubles
as the test *oracle* for property suites over our pure Unicode helpers. **The
extraction thesis (maintainer, 2026-09-24):** the general mechanism behind
unicode-transforms — *build-time codegen of Unicode tables from upstream data
files* — generalizes program-wide: any UCD/CLDR table we need (case folding,
property classes, plural rules) is extracted from checked-in UCD/CLDR **data files**
at build time, with parsing static tables out of FFI-bound C sources (as smirk
could for pcre2) only the fallback when no data file exists — data files always
preferred where they exist. Template-Haskell extraction is declined: build-time
codegen keeps the artifacts hermetic, inspectable, and GHC-release-independent.
Adoption
timing: with the first real surface needing collation/date/number rendering beyond
the ASCII minimum (Phase 3), or with the i18n package (2.21) whichever comes first.
- **i18n** (`Data.Text.I18n`, Hackage; cloned locally): gettext-style runtime
  catalogs — locale dictionary lookup with placeholder substitution and plural
  forms. Pattern-adjacent to the typed-message rule but untyped at the core (string
  keys, lookups at call sites), so implementation is declined where the
  shakespeare-derived design (2.21) uses message GADTs + record dictionaries; its
  **runtime catalog loading** remains the reference for the translation-file
  projection format. Trigger: first surface shipping user-facing strings (Phase 3).
- **organ-bank / frankenstein** (maintainer's own; owner class): source-analysis
  tooling for the i18n faithfulness program — organ-bank's shim translators for
  foreign-source surface analysis, frankenstein's LLVM/MLIR-level reassembly work —
  the program-internal donors for the C/other-language source analysis of
  REUSE_REGISTER 2.22's faithfulness triad, alongside per-language third-party
  parsers (tree-sitter grammars, libclang) register-judged per language at demand.
  Recorded as program tooling rather than third-party references; redesign/expansion
  is internal development. Trigger: i18n note (backlog 12) reaches its
  source-analysis phase.
- **bidi-icu + the codex monorepo** (Kmett; cloned locally): `bidi-icu` is a minimal
  `.hsc` shim over ICU's `ubidi_*` (UAX #9 bidirectional algorithm) — the existing
  precedent for the shim option of row 2.22 caveat 2, and the likely bidi primitive
  for any mixed-direction text at the presentation edge (Licensing: BSD-2 OR
  Apache-2.0; experimental, version 0). The wider codex monorepo (`harfbuzz` text
  shaping, `smawk` optimal line-breaking via totally-monotone matrices, `freetype`,
  fontconfig) is the natural reuse stack if the Phase-3 surfaces grow beyond the TUI
  toward real glyph rendering — judged as a bundle when that demand arrives.
  Trigger: bidi need or dashboard/GUI work (Phase 3).
- **unicode-tricks** (Hackage; cloned locally): ~30 modules of character-block
  helpers (braille, chess, dice, sextant blocks…) over the `unicode` property
  package — charming but TUI-cosmetic, no protocol/record relevance; declined
  without a case unless the kakegoe dashboards want pretty terminal rendering,
  at which point it is re-judged as a cosmetic dependency (transport-class). Trigger:
  dashboard development (Phase 3).
- **kiroku / shibuya / keiro / kioku** (keiro stack): interop-first contact strategy
  (NIH_PLAN); reuse-or-reimplement is not currently posed — hashigakari reads/writes
  their formats; deeper integration decisions wait for the contact spike.
