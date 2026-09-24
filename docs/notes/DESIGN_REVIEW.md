# Project Design Review — Comprehensive Synthesis and Critical Assessment

Status: DRAFT v0.1 · 2026-09-24 (cross-cutting design review)
Related: `NIH_PLAN.md` (the program), `DOC_STRATEGY.md` (corpus governance),
`INFRASTRUCTURE.md` (toolchain and quality gates), `EFFECT_CATALOG_DESIGN.md`
(algebraic effect catalog), `FIELDS_RECORDS_DESIGN.md` (extensible records and
evolution), `YAMAARASHI_DESIGN.md` (streaming stack), `HASHIGAKARI_DESIGN.md` (row
database engine), `MEMORY_ENGINE_DESIGN.md` (utaibon context engine),
`LLM_SUBSTRATE_DESIGN.md` (utai model layer), `HOKORA_SPEC.md` (Phase 1.5 validation
slice), `INSTRUMENTS_SPEC.md` (kakegoe experiment suite), `OBSERVABILITY_DESIGN.md`
(kagami-ita telemetry), `registers/REUSE_REGISTER.md` (doctrine & ledger),
`registers/CODEC_QUIRKS.md` (wire reality), `registers/GLOSSARY.md` (term index)
Audience: Maintainer and future contributors; serves as the definitive pre-implementation
architectural audit and design review across all tiers while the design phase is active.

---

## 0. Executive Summary & Review Verdict

The `sarutahiko` program constitutes an ambitious, highly coherent reimplementation
("NIH") of the modern AI assistant stack — specifically targeted at replacing the
Nadeem Bitar (keiro) ecosystem (`baikai`, `keiro`, `kiroku`, `shibuya`, `kioku`,
`shikumi`, `kin`) and the Nous Research Hermes agent (`HERMES_DESIGN.md`), grounded in
modern Haskell. The design rejects first-iteration architectural compromises
(Template Haskell ORMs, closed nominal DTO hierarchies, nested monad transformer
towers, unversioned ambient context mutation, and unprincipled glue code) in favor
of four foundational pillars:

1. **Open products for data:** Extensible records (`large-anon` SmallArray#-backed
   anonymous records via the maintainer's `large-records-interfaces` fork; `rcast`
   projections; zero internal DTO conversions).
2. **Open sums for syntax:** Row-typed algebraic effect signatures (GADTs over an
   abstract monad parameter `m`; capability rows `Granted :<: es`; dual interpreters
   for `effectful` and `polysemy` held honest by a law testkit).
3. **Layered streams for time:** The **yamaarashi** (山嵐) hybrid streaming stack
   (porcupine task DAGs with Make-like caching over church-encoded element-stream
   kernels over fused `streamly` / mature `conduit` backends).
4. **Existential steppers for resources:** Universal cursor steppers (`Cursor m a`,
   `Subscription m`, `EventCursor m`) managed deterministically by the unified
   `Resource`/`Scoped` effect row, eliminating finalizer races and GC-bound handles.

### 1.1 The Review Verdict

| Dimension | Rating | Finding |
|---|---|---|
| **Architectural Coherence** | **Exceptional** | The records-as-products $\times$ effects-as-sums duality runs cleanly through every layer. Cross-layer abstractions (`SomeRow`, `Scoped`, existential cursors) enforce reuse of concepts rather than proliferation of bespoke mechanisms. |
| **Doctrine & Reuse Discipline** | **High** | The reuse doctrine (`REUSE_REGISTER.md`) is principled and consistently applied. The core test (reusing engines whose cores embody principles, reimplementing vocabularies that are first-iteration nominal wrappers) successfully guides decisions (e.g., `hasql` reused, `persistent`/`servant`/`baikai` rejected). |
| **System Invariants & Laws** | **High** | Laws are explicitly cataloged across domains: row evolution (E1–E7), storage ordering (C1–C6), model provider behavior (L1–L4), observability choke points (K1–K4), and cache stability invariants. |
| **Implementation Readiness** | **High / Phase 0 Unblocked** | The design corpus is complete, with all six critical architectural tensions resolved across canonical docs: the Skinny Spine protocol unblocks Phase 1.5 (`HOKORA_SPEC.md` §4); `Stepper m a` is unified across all specs; the Handlers-as-Records spike protocol and fallbacks are codified (`EFFECT_CATALOG_DESIGN.md` §6.2); the streaming kernel is established as Tier-0 API (`YAMAARASHI_DESIGN.md` §1); `FIELDS_RECORDS_DESIGN.md` §§1–7 are fully drafted with tutorial-level depth; and the Kogaki Codec Strategy (`LLM_SUBSTRATE_DESIGN.md` §5) resolves provider maintenance overhead. |

---

## 1. Substrate & Foundation Review (Tier 0 & 0.5)

### 1.1 Extensible Records & Evolution (`FIELDS_RECORDS_DESIGN.md`, `REUSE_REGISTER.md` 2.1)

#### Strengths & Triumphs
- **Exclusivity of Representation:** The decision to standardize internally on
  `large-anon` exclusively — treating `vinyl` merely as a compatibility seam for
  external packages — eliminates dual-representation friction and simplifies
  existential wrappers (`SomeRow`).
- **The E1–E7 Row-Evolution Standard:** Drafted in §1 of `FIELDS_RECORDS_DESIGN.md`,
  this standard is among the finest systems contributions in the corpus:
  - **E1 (Authoritative Tagging):** Strict `(kind, schemaV)` discrimination forbids
    speculative structural decoding.
  - **E2 & E5 (Additive vs Two-Phase Lossy):** Clear operational boundaries
    distinguish minor non-breaking additions with for-older provisions from major
    deprecations.
  - **E6 & E7 (Immutable Bytes & Derived Provenance):** Upgrades as pure read-time
    views over immutable store bytes, with vintage derived from envelope
    `original_version` and field metadata, completely removes the need for ad-hoc
    "defaulted" states in the absence functor.

#### Resolution of Prior Gaps
1. **The Incomplete Note (§§2–7) — RESOLVED:** `FIELDS_RECORDS_DESIGN.md` §§2–7 have been
   fully articulated with tutorial-level depth, defining the HKD functor family (§2),
   the first-class field datum and hybrid registry model in `sarutahiko-fields` (§3),
   the envelope-locus unknown field preservation mechanism (§4), the formal combinator
   laws including right-biased override merge `(⊕)` (§5), linear-time vector decoder
   recipes (§6), and compile-time economics policed by the 40-column regression suite (§7).
2. **Absence Functor Definition (CA1–CA3) — RESOLVED:** Defined and proven in §2.2 as
   `TriState a = Absent | PresentNull | Present !a`, with three states exactly, clean
   projection naturality, canonical wire round-trip preservation, and derived provenance
   (no ad-hoc "Defaulted" variants, satisfying CA3).
3. **Unknown-Field Preservation Locus (Decision 4) — RESOLVED:** Formally settled in §4:
   unknown fields are held strictly in `WireEnvelope a` (`envUnknownFields` and
   `envRawBytes`) at the serialization boundary. Domain `Record f r` stays purely typed.
   E4 is strictly enforced: consuming newer payloads ($V_{orig} > V_{local}$) forbids
   re-serialization, requiring raw byte pass-through.

### 1.2 The Algebraic Effect Catalog (`EFFECT_CATALOG_DESIGN.md`)

#### Strengths & Triumphs
- **Neutrality & Dual Interpreters:** Isolating signatures into
  `sarutahiko-effect-signatures` with zero effect-system dependencies ensures long-term
  portability.
- **Parametric Capability Rows (§6.1):** Replacing runtime permission checks with
  compile-time rank-2 grants (`runPlugin :: (∀ es. Granted :<: es => Eff es ()) -> Eff es ()`)
  is an architectural tour de force. It eliminates Hermes-style allowlist drift by
  construction.
- **PVP-for-Signatures (§6.5):** Recognizing that GADT constructors represent open
  sums and that adding a constructor breaks downstream totality matches the deep
  duality of the program. The recommendation to evolve via new small signatures and
  reinterpretation layers is a masterclass in API design.
- **`Scoped` Unification (§6.3):** Collapsing brackets, transactions, cursor
  lifetimes, and hook regions into a single canonical higher-order pattern resolves
  a ubiquitous source of resource leaks.

#### Resolution of Prior Gaps
1. **The Handlers-as-Records Spike Protocol (§6.2) — RESOLVED:** A standalone spike
   protocol has been formalized in `EFFECT_CATALOG_DESIGN.md` §6.2 with explicit
   success criteria (clean record-merge into `effectful` dynamic dispatch and `polysemy`
   interpreters with $\le$5% overhead) and an immediate zero-churn fallback to
   handwritten interpreters.
2. **Higher-Order Capability Leaks:** The parametricity security argument in §6.1
   holds strictly for first-order operations. All signatures exposed to capability rows
   are audited as first-order or constrained to the same `Granted` row.
3. **Existential Stepper Signature Standardization — RESOLVED:** Unified into the
   canonical `Stepper m a` GADT in `EFFECT_CATALOG_DESIGN.md` §4, `HASHIGAKARI_DESIGN.md`
   §3.4, and `LLM_SUBSTRATE_DESIGN.md` §2:
   ```haskell
   data Stepper m a where
     Stepper :: st
             -> (st -> m (Maybe (a, st)))
             -> (st -> m ())
             -> Stepper m a
   ```

### 1.3 The Streaming Stack (`YAMAARASHI_DESIGN.md`)

#### Strengths & Triumphs
- **Rigorous Separation of Concerns:** Assigning task-level composition, Make-like
  caching, and visualization to `yamaarashi-flow` (porcupine re-homed), while
  relegating element streaming to `yamaarashi` and its backends, resolves a perennial
  dilemma in Haskell streaming.
- **Resource Safety via `Resource`/`Scoped`:** Extracting finalization out of the
  streaming monad into the effect row guarantees that short-circuited pipelines
  (`take`, early exit, exceptions) clean up DB cursors and sockets consistently under
  both `effectful` and `polysemy`.

#### Resolution of Prior Gaps
1. **The NIH Trigger Ambiguity — RESOLVED:** Reconciled in `YAMAARASHI_DESIGN.md` §1 & §3
   and `NIH_PLAN.md` §0 & §3.5. The church-encoded CPS free monad kernel
   (`Stream (Of a) m r`) is declared the **Tier-0 public streaming API** for the program.
   The trigger gates govern whether the internal loop engine is hand-fused or delegates
   to the `streamly` backend; user-facing code and signatures depend exclusively on
   `yamaarashi`'s dependency-free kernel.

---

## 2. Wire & Data Tier Review (Tiers 1 & 5)

### 2.1 Database Access (`HASHIGAKARI_DESIGN.md`)

#### Strengths & Triumphs
- **"The Query is the Record":** Computing output row types directly via type families
  over large-anon records eliminates the boilerplate of nominal entity types, DTO
  layers, and projection tuples.
- **Dialect Ceilings:** Type-level tracking of dialect capabilities (`Supports 'JSONB Postgres`)
  prevents backend-specific features from leaking into portable queries while
  retaining compile-time validation.
- **Engine Reuse Alignment:** Leveraging `hasql` (Postgres binary protocol, applicative
  decoders) and `direct-sqlite` (`sqlite3_step`) exemplifies the doctrine: reuse
  principled engines while replacing nominal query vocabularies.

#### Gaps & Critical Open Items
1. **AST Complexity vs Query Expressiveness:** The query AST in §3.2 covers `Table`,
   `Project`, `Join`, `LeftJoin`, `Filter`, `Aggregate`, `Union`. Real-world agent
   workloads frequently require window functions, Common Table Expressions (CTEs),
   subquery expressions (`EXISTS`, `IN`), and upsert clauses (`ON CONFLICT DO UPDATE`).
   The dialect compilation phase (`hashigakari-syntax`) must define where these
   constructs live without sacrificing linear-time compilation.
2. **Draft Drift in §3.4 — RESOLVED:** `HASHIGAKARI_DESIGN.md` §3.4 has been officially
   updated to normalize `Database` over `(m :: Type -> Type)` and standardizes query
   traversal onto `Stepper m (Record Identity row)`.

### 2.2 Wire Flagship (`sarutahiko-jsonrpc`, `sarutahiko-mcp`, `sarutahiko-schema`)

#### Strengths & Triumphs
- **The First Flagship Strategy:** Prioritizing the wire layer (JSON-RPC 2.0 + MCP)
  in Phase 1 provides immediate interop dividend: the system can act as an MCP
  server or host to Claude Code, Hermes, and Zed from month two.
- **Distilled Typed-Protocols (`NIH_PLAN.md` §ledger, `REUSE_REGISTER.md` 2.6):**
  Distilling agency-indexed states and peer GADTs dependency-light avoids the heavy
  footprint of the full `typed-protocols-1.2.x` framework while preserving the ability
  to swap it in later if pipelining or formal proofs demand it.

---

## 3. Agent Core, Context & Models (Tier 2)

### 3.1 The Memory/Context Engine (`MEMORY_ENGINE_DESIGN.md` - utaibon)

#### Strengths & Triumphs
- **Spine v0.2 Decoupling (Address vs Meaning):** The strict rule that the event
  envelope carries only what is required for routing, decoding, traversal, and
  retention (`seq`, `eventId`, `kind`, `schemaV`, `ts`, `session`, `actor`, `cause`,
  `payload`), leaving domain data entirely to `SomeRow` payloads, is an exemplary
  systems design choice.
- **The Ordering Contract (C1–C6):** Restricting all consumers to
  `ORDER BY seq ASC WITHIN session`, while treating timestamps `ts` as purely
  informational (Law T), prevents cross-dialect divergence between SQLite and Postgres.
- **Policy as First-Class Effect (`PolicyEffect` §5.1.4):** Isolating cache-preserving
  operations (`TailOnly`) from cache-breaking operations (`PrefixBreaking`) via
  `SomeDecision` creates a transparent audit trail for prompt caching.

#### Gaps & Critical Open Items
1. **Vector / Embedding Retrieval Deferral:** Retrieval is deferred to v1.5. For
   extended agent conversations before compression triggers, semantic recall will be
   absent. The project should confirm whether a pure lexical/BM25 or SQLite FTS5
   reducer should serve as an interim retrieval bridge in Phase 2.
2. **Single-Writer vs Multi-Writer Guardrails:** While the memory engine enforces
   single-writer per session, the row-evolution standard (E4) introduces
   anti-silent-loss rules for rolling upgrades. The interaction between SQLite
   WAL mode locking and concurrent CLI/TUI invocations on the same session must be
   explicitly handled with fail-closed locks.

### 3.2 The LLM Substrate (`LLM_SUBSTRATE_DESIGN.md` - utai)

#### Strengths & Triumphs
- **The v0.2 Reversal (Baikai as Reference, Not Engine):** Reversing the v0.1 decision
  to wrap `baikai` and instead treating provider APIs as members of the protocol
  codec bag is completely faithful to the program's doctrine. Baikai's nominal ADTs
  would have polluted the core; adopting its laws (L1–L4) while NIH'ing the codecs
  secures zero-DTO purity.
- **The Canonical Renderer:** Mandating a single shared renderer for
  `ContextRow -> ByteString` per provider family guarantees byte-level prefix stability
  (Law L4), making prompt cache hits deterministic and measurable.
- **Normalized Stepper Traversal:** `EventCursor m` has been normalized to the canonical
  `Stepper m StreamEvent` GADT in `LLM_SUBSTRATE_DESIGN.md` §2.

#### Resolution of Prior Gaps & Remaining Items
1. **Codec Maintenance Realism & The Kogaki Codec Strategy — ADDRESSED:** The risk of
   codec drift against rapidly moving provider APIs has been resolved by adopting the
   **Kogaki Codec Strategy** (`LLM_SUBSTRATE_DESIGN.md` §5, `CODEC_QUIRKS.md` §6). By
   combining upstream donor source analysis, build-time schema extraction from OpenAPI
   specs, fixture-backed quirk tracking in `kakegoe`, differential fuzzing against
   external SDK oracles, and strict bounding to agent-turn needs, the maintenance
   burden is transformed into an automated, verifiable engineering protocol.
2. **Pure Token Counting:** `Count :: ContextRow -> ModelAPI m TokenCount` requires an
   honest implementation for budget management. Calling provider APIs for token
   counting is slow and network-dependent; relying on rough character heuristics
   risks context overflow (`ANT-010`). An in-tree or cleanly isolated BPE tokenizer
   is required for offline predictability in `kakegoe`.

---

## 4. Cross-Cutting Systems & Specs Review

### 4.1 The Hokora Slice (`HOKORA_SPEC.md`)

#### Strengths & Triumphs
- **The Walking Skeleton Principle:** Building a full vertical slice early
  (CLI → ReAct turn → Model call → MCP stdio tool → SQLite spine log → reducer summary)
  in $\le$2,000 LOC provides the ultimate reality check for the entire architecture.
- **Dual-Interface Proof:** Executing the *exact same turn program* under both
  `effectful` and `polysemy` interpreters in the Hokora test suite provides concrete
  proof of the dual-interface contract.

#### Resolution: The Skinny Spine Sequencing Rule (Adopted)
The Phase 1.5 dependency inversion between `NIH_PLAN.md` §4 and `HOKORA_SPEC.md` has
been **formally resolved and codified** across the design corpus (`HOKORA_SPEC.md` §4,
`NIH_PLAN.md` §4, `HASHIGAKARI_DESIGN.md` §3.4, `LLM_SUBSTRATE_DESIGN.md` §1):
- Phase 1.5 consumes the minimal **Skinny Spine SQLite writer**: raw parameterized SQL
  appending the spine v0.2 columns directly to SQLite, bypassing the full query AST and
  dialect compilation of Phase 4 `hashigakari`.
- Phase 1.5 consumes `utai-mock` (and a thin raw SSE streaming client for live runs),
  bypassing full provider codec sprawl of Phase 2.
- Full AST compilation and provider breadth remain safely in their scheduled phases.

### 4.2 Policy Instruments (`INSTRUMENTS_SPEC.md` - kakegoe)

#### Strengths & Triumphs
- **Empirical Governance:** Replacing subjective debate over compression thresholds and
  salience heuristics with offline replay over synthetic corpora, prefix-hash cache
  simulation, and pinned metric formulas establishes a truly scientific development
  loop.
- **Corpus-as-Log Dogfooding:** Storing synthetic evaluation corpora in the exact
  same event log envelope format enables reuse of `SessionStore` interpreters directly.

### 4.3 Observability (`OBSERVABILITY_DESIGN.md` - kagami-ita)

#### Strengths & Triumphs
- **Interpreter-Edge Choke Point (K1–K4):** Forbidding logging and metric literals in
  domain code, and instead capturing behavior exclusively at the interpreter
  boundary via capability-granted wrappers, preserves core purity.
- **Log-Derived Quantile Sketches:** Computing metrics as pure reductions over the event
  stream using mergeable sketches (t-digest, Greenwald–Khanna, Q-digest) ensures that
  all telemetry is deterministic and replayable.

---

## 5. Governance, Toolchain & Procedure

### 5.1 Infrastructure (`INFRASTRUCTURE.md`)
- **Hypermodern Toolchain:** Pinning GHC 9.14, Cabal 3.18, and GHC2024, with zero
  effort spent on legacy compiler compatibility, is fully justified by the project's
  ambition.
- **Upstreamed Tooling:** Reusing `brittany` and `hlint` while maintaining direct
  upstream relationships and active patch series avoids the abandonment risks of
  traditional forks.
- **Three-Tier Testing & io-sim:** Tasty runner orchestrating Hedgehog property suites,
  golden renderer outputs, and deterministic `io-sim` concurrency schedules guarantees
  verification rigor.

### 5.2 Documentation Strategy (`DOC_STRATEGY.md`)
- **Policy v1.0 Decided:** All 11 sections are decided, establishing a mature,
  multi-audience governance framework (tutorials, haddock tomes, LaTeX whitepapers).
- **The Doc-Drift Judge:** Combining zero-LLM deterministic pre-filtering (verifying
  symbols, anchors, and law IDs) with multi-model consensus review addresses the
  primary vulnerability of documentation-heavy architectures: silent drift.

---

## 6. Synthesis of Critical Tensions & Gaps

Before code was written for Phase 0, six critical architectural tensions were identified.
All six have now been adjudicated, with five formally resolved in the canonical design notes
and the fifth (codec maintenance) resolved via the evaluation below:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                 CRITICAL ARCHITECTURAL TENSIONS — STATUS                    │
├────────────────────────────────┬────────────────────────────────────────────┤
│ 1. Phase 1.5 Dependency        │ RESOLVED IN DOCS:                          │
│    Inversion                   │ Skinny Spine extraction protocol adopted in│
│                                │ HOKORA_SPEC §4 & NIH_PLAN §4.              │
├────────────────────────────────┼────────────────────────────────────────────┤
│ 2. Incomplete Tier-0 Records   │ RESOLVED IN DOCS:                          │
│    Specification               │ FIELDS_RECORDS_DESIGN §§1–7 fully drafted  │
│                                │ (TriState CA1–CA3, registry, (⊕) laws).    │
├────────────────────────────────┼────────────────────────────────────────────┤
│ 3. Handlers-as-Records Risk    │ RESOLVED IN DOCS:                          │
│    Unverified Duality          │ Phase 0 spike protocol & fallback criteria │
│                                │ formalized in EFFECT_CATALOG §6.2.         │
├────────────────────────────────┼────────────────────────────────────────────┤
│ 4. Streaming Kernel Gate vs    │ RESOLVED IN DOCS:                          │
│    Design Ambiguity            │ Church-encoded kernel declared as Tier-0   │
│                                │ public API in YAMAARASHI §1 & NIH_PLAN §0. │
├────────────────────────────────┼────────────────────────────────────────────┤
│ 5. Codec Maintenance Overhead  │ RESOLVED IN DOCS / EVALUATED BELOW:        │
│    NIH Wire Codecs vs Churn    │ Kogaki Codec Strategy adopted in           │
│                                │ LLM_SUBSTRATE §5 & CODEC_QUIRKS §6.        │
├────────────────────────────────┼────────────────────────────────────────────┤
│ 6. Stepper Signature           │ RESOLVED IN DOCS:                          │
│    Proliferation               │ Unified into canonical `Stepper m a` GADT  │
│                                │ across catalog §4, db §3.4, model §2.      │
└────────────────────────────────┴────────────────────────────────────────────┘
```

---

### 6.1 Architectural Evaluation: Applying the Kogaki Strategies to Codec Maintenance

#### The Proposal
The maintainer proposed that a set of strategies akin to the discussion on **kogaki**
(小書) for internationalization and Unicode handling (recorded in
`docs/transcripts/kogaki-i18n-unicode.md`) be adapted to solve the problem of LLM provider
wire codec maintenance (OpenAI, Anthropic, Gemini).

#### Context & Structural Analogy
In internationalization and Unicode engineering, systems face an intractable maintenance
hazard: the domain (ICU4C, CLDR tables, Unicode segmentation rules, complex scripts,
bidirectional layout, plural selection) is vast, governed by third-party standards
bodies, continually changing, and riddled with subtle corner cases. Blindly wrapping
an entire C library leaks imperative idioms and environmental variance; writing manual
parsers from scratch leads to endless bug channelling and maintenance exhaustion.

The `kogaki` strategy addressed this by decomposing i18n into five disciplined pillars:
1. **Upstream Source Analysis / Anatomical Donors:** Using reference implementations
   (ICU, formatjs, unicode-transforms) as structural donors to inspect parser logic
   without inheriting their imperative C memory handles or untyped strings.
2. **Build-Time Extraction:** Deriving data tables, plural rules, and schemas directly
   from machine-readable upstream artifacts (CLDR XML/JSON) at build time, completely
   bypassing manual type curation and expensive Template Haskell.
3. **Variant Projections (Kogaki / 小書):** Treating localized renderings as variant
   annotations projected beside a canonical master text, combined via right-biased
   override merge (`root ⊕ lang ⊕ region`).
4. **Differential Fuzzing / External Oracles:** Testing output fidelity in CI by comparing
   against reference implementations (e.g. system ICU or formatjs) as external ground-truth
   test oracles.
5. **Strict Scope Bounding:** Scoping the core strictly to what the application needs
   (presentation-edge rendering), deferring speculative coverage.

#### Mapping Kogaki to LLM Wire Codec Maintenance

The maintenance dynamics of LLM provider wire codecs are structurally identical to i18n:
OpenAI, Anthropic, and Gemini continuously alter streaming deltas, introduce novel chunk
structures (`ANT-003` content block nesting, `ANT-004` thinking blocks, `OPEN-004` chunked
tool call arguments), and publish multi-thousand-line API specs.

Applying the five Kogaki pillars yields the **Kogaki Codec Strategy**
(`LLM_SUBSTRATE_DESIGN.md` §5, `CODEC_QUIRKS.md` §6):

| Kogaki i18n Pillar | LLM Codec Analog | Implementation Mechanism |
|---|---|---|
| **1. Anatomical Donors** | Official SDK & Baikai Analysis | Official TypeScript/Python SDKs and `baikai` are analyzed to understand delta accumulation and event sequencing. We extract their wire protocols into our row codecs while strictly rejecting their nominal DTO wrappers. |
| **2. Build-Time Extraction** | OpenAPI & Schema Extraction | Provider wire schemas, tool schemas, and model taxonomies are extracted from machine-readable OpenAPI/JSON Schema definitions at build time. Zero manual nominal DTO typing; zero Template Haskell. |
| **3. Fixture-Backed Conformance** | `kakegoe` Wire Fixtures | Every confirmed quirk in `CODEC_QUIRKS.md` is backed by recorded raw wire transcripts in `kakegoe`. Codecs are tested against real-world captures, not synthetic mocks. |
| **4. External Oracles** | Differential Testing in CI | Nightly CI runs property tests comparing `sarutahiko-model` decoder outputs against official SDKs or live provider endpoints. The official SDK acts as a test oracle without becoming a production dependency. |
| **5. Strict Scope Bounding** | Agent-Turn Bounding | Codecs support *only* what the agent turn executes: streaming text/tools, reasoning blocks, prompt cache markers, and token counts. Speculative endpoints (audio, fine-tuning, batch APIs) are categorically excluded. |

#### Reviewer Assessment & Verdict
**The proposal is strongly and unconditionally endorsed.**

Treating provider APIs not as arbitrary external services requiring manual DTO maintenance,
but as a **bounded protocol compilation problem backed by differential oracles**, resolves
the central dilemma of the LLM substrate. It gives `sarutahiko` the zero-DTO purity of
extensible records while providing automated guarantees against provider wire drift.

---

## 7. Strategic Recommendations & Immediate Action Plan

With Stage 1 (Closing Foundation Specifications) **fully completed**, the project
transitions directly into Phase 0 execution. Work proceeds in three active stages:

### Stage 1: Close Foundation Specifications — COMPLETED
- [x] Complete `FIELDS_RECORDS_DESIGN.md` §§1–7 (`Identity`, `TriState` CA1–CA3,
      `Column`, `sarutahiko-fields` CD1–CD2, `WireEnvelope` E3/E4, `(⊕)` laws,
      linear-time vector decoder recipes, 40-col regression suite).
- [x] Standardize all existential steppers to canonical `Stepper m a` GADT.
- [x] Codify Phase 0 Handlers-as-Records Spike Protocol and fallback criteria.
- [x] Clarify streaming kernel as Tier-0 public API.
- [x] Adopt Skinny Spine sequencing protocol for Hokora Phase 1.5.
- [x] Adopt Kogaki Codec Strategy for LLM wire maintenance.

### Stage 2: The Phase 0 Proof Spikes (Immediate Next Step — 1 week)
1. Initialize the multi-package `cabal.project` with GHC2024 commons and pinned
   GHC 9.14 toolchain (`INFRASTRUCTURE.md` §1).
2. Execute the **Handlers-as-Records Spike** (`EFFECT_CATALOG_DESIGN.md` §6.2):
   - Benchmark record merge of handler functions into `effectful` dynamic dispatch and
     `polysemy` tactics.
   - If clean ($\le$5% overhead): adopt as canonical pattern.
   - If brittle: fall back immediately to handwritten dual-interpreter bridges.
3. Code minimal `sarutahiko-fields` and `sarutahiko-records` packages.
   Implement the 40-column compile-time test to establish the baseline in the nightly ledger.

### Stage 3: The Minimal Effect Catalog & Streaming Kernel (2 weeks)
1. Implement `sarutahiko-effect-signatures` with the unified `Resource`/`Scoped`,
   `Log`, `Process`, `Clock`, and `SessionStore` GADTs.
2. Implement the church-encoded `Stream (Of a) m r` kernel in `yamaarashi`.
3. Stand up `sarutahiko-effect-testkit` and assert dual-interpreter parity under
   both `effectful` and `polysemy` in CI.

### Stage 4: The Skinny Spine to Hokora (Phase 1 & 1.5)
1. Build `sarutahiko-jsonrpc` and `sarutahiko-mcp` (wire flagship).
2. Wire the **Skinny Spine**:
   - Minimal SQLite append-only writer for spine v0.2.
   - `utai-mock` and minimal SSE streaming client.
   - Assemble the Hokora tracer bullet (`hokora "..."`) and measure against the
     $\le$2,000 LOC target.

---

## 8. Conclusion

The `sarutahiko` design corpus has successfully resolved its foundational tensions.
By uniting extensible records, row-typed algebraic effects, existential steppers, and the
Kogaki codec strategy into an integrated, law-governed architecture, the project has
eliminated the ad-hoc compromises that plagued earlier Haskell systems. The design phase
is complete, the foundations are solid, and the path is clear for Phase 0 implementation.
