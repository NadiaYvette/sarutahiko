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
| **Implementation Readiness** | **Moderate / Gated** | The design corpus is exceptionally thorough, but **critical design and sequencing gaps remain open** that will cause friction if code is cut immediately: the unwritten sections of `FIELDS_RECORDS_DESIGN.md`, the unverified handlers-as-records spike, and the Phase 1.5 dependency inversion. |

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

#### Gaps & Critical Open Items
1. **The Incomplete Note (§§2–7):** While §1 (the evolution standard) is drafted,
   sections 2–7 are currently stubs. Coding cannot safely commence on
   `sarutahiko-records` until §2 (HKD functor family), §3 (field datum & registry
   model), and §4 (unknown-field preservation) are fully articulated.
2. **Absence Functor Definition (CA1–CA3):** The standard emits the requirement for a
   three-state functor (`Absent`, `PresentNull`, `Present a`), effectively `TriState`.
   However, its interaction with `large-anon`'s native `Record f r` and
   `Data/Record/Anon/Internal/Advanced.hs` must be verified.
3. **Unknown-Field Preservation Locus (Decision 4):** There is an unsettled tension
   between preserving unknown fields in the row representation itself (e.g., an
   extra `SmallArray#` or map of unparsed JSON values) versus preserving them
   solely at the serialization edge. If unknown fields are not represented in
   `Record f r`, passing an un-upgraded payload through an intermediate pipeline
   risks silent truncation unless protected by E4.

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

#### Gaps & Critical Open Items
1. **The Handlers-as-Records Spike (§6.2):** Handlers-as-records is blessed in concept,
   but remains an unverified hypothesis. In `effectful`, handler dispatch relies on
   internal unlifting and `Env` manipulation; in `polysemy`, it relies on higher-order
   `Tactics` and type-level membership proofs. A standalone spike must be executed
   before committing to this pattern. If the spike reveals excessive runtime boxing or
   type-system contortions, the project must fall back cleanly to handwritten
   interpreters per system without delaying Phase 0.
2. **Higher-Order Capability Leaks:** The parametricity security argument in §6.1
   holds strictly for first-order operations. If any operation in a `Granted`
   signature accepts a callback or nested computation of type `Eff es' a`, a
   malicious or buggy plugin could attempt to capture ambient capabilities. All
   signatures exposed to capability rows must be verified as strictly first-order, or
   their higher-order arguments must be constrained to the same `Granted` row.
3. **Existential Stepper Signature Standardization:** `EFFECT_CATALOG_DESIGN.md` §4
   defines `Subscription m` as `st -> (st -> m (Maybe (EventRow, st))) -> (st -> m ()) -> Subscription m`.
   Meanwhile, `HASHIGAKARI_DESIGN.md` §3.4 sketches `Cursor es row` parameterized over
   `Eff es`, and `LLM_SUBSTRATE_DESIGN.md` §2 sketches `EventCursor m`. These three
   stepper types must be unified into a single canonical GADT:
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

#### Gaps & Critical Open Items
1. **The NIH Trigger Ambiguity (`NIH_PLAN.md` §3.5 vs `YAMAARASHI_DESIGN.md` §2):**
   `NIH_PLAN.md` §3.5 explicitly mandates an interim strategy: use pinned `conduit`,
   measure benchmarks, and code the NIH kernel *only if two or more gates trip*. In
   contrast, `YAMAARASHI_DESIGN.md` presents the church-encoded CPS kernel
   (`Stream (Of a) (Eff es) r`) as already designed and central. The project must
   clarify whether Phase 0 implements the church-encoded kernel directly or pins
   `conduit` behind an abstract interface. Given the small code size of a CPS free
   monad stream, implementing the church-encoded kernel directly in Phase 0 as the
   sole public interface (with `conduit` as an adapter) is cleaner and eliminates
   transitional churn.

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
2. **Draft Drift in §3.4:** As noted in §1.2 above, `HASHIGAKARI_DESIGN.md` §3.4 still
   contains the unnormalized sketch `Database (Eff es)` and `Cursor (es :: [Effect])`.
   This must be officially updated to the catalog's `Database (m :: Type -> Type)` and
   `Stepper m a` convention.

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

#### Gaps & Critical Open Items
1. **Codec Maintenance Realism (`registers/CODEC_QUIRKS.md`):** Managing wire codecs
   for OpenAI, Anthropic, and Gemini from scratch is a significant ongoing liability.
   Anthropic's nested content block streaming (`ANT-003`, `ANT-004`) and OpenAI's
   chunked tool arguments (`OPEN-004`) require stateful fragment accumulators.
   The project must adhere strictly to the rule: *only support features the agent
   actually consumes* (streaming completions, tool calls, thinking blocks, prompt
   caching). Speculative provider feature coverage must be rejected.
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

#### Critical Architecture Tension: The Phase 1.5 Dependency Inversion
There is a fundamental sequencing conflict between `NIH_PLAN.md` §4 and `HOKORA_SPEC.md`:
- `NIH_PLAN.md` schedules `sarutahiko-model` (LLM substrate) in **Phase 2 (weeks 10–20)**
  and `hashigakari-sqlite` in **Phase 4 (weeks 24–40)**.
- Yet `HOKORA_SPEC.md` schedules the Hokora in **Phase 1.5 (between Phase 1 and 2)**,
  requiring both a functioning model call (`utai-mock` and live provider) and a
  persisted SQLite event log!

**Resolution:** This review proposes the **"Skinny Spine" sequencing rule**:
Phase 1.5 does *not* wait for Phase 4 `hashigakari` (with its full query AST and
dialect compilation). Instead, Phase 1.5 consumes a minimal *Tier-0 SQLite log writer*
(raw parameterized SQL appending the blessed spine v0.2 columns). Similarly, it
consumes only the `utai` signature and `utai-mock` (with a bare-bones HTTP client
for the live run). Full AST compilation and provider sprawl remain in their later
phases. This sequencing must be formally noted in `NIH_PLAN.md`.

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

Before code is written for Phase 0, the following six architectural tensions must be
adjudicated:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       CRITICAL ARCHITECTURAL TENSIONS                       │
├────────────────────────────────┬────────────────────────────────────────────┤
│ 1. Phase 1.5 Dependency        │ Hokora needs SQLite and ModelAPI, which are│
│    Inversion                   │ scheduled in Phase 4 and Phase 2.          │
│    --> ACTION: Adopt "Skinny Spine" extraction protocol.                    │
├────────────────────────────────┼────────────────────────────────────────────┤
│ 2. Incomplete Tier-0 Records   │ FIELDS_RECORDS_DESIGN §§2–7 are stubs;     │
│    Specification               │ absence functor and SomeRow need types.    │
│    --> ACTION: Draft §§2–4 before cutting cabal files.                      │
├────────────────────────────────┼────────────────────────────────────────────┤
│ 3. Handlers-as-Records Risk    │ Intellectual core of duality is unverified │
│                                │ against effectful and polysemy internals.  │
│    --> ACTION: Run standalone empirical spike in Phase 0.                   │
├────────────────────────────────┼────────────────────────────────────────────┤
│ 4. Streaming Kernel Gate vs    │ Trigger gates say "defer kernel", but note │
│    Design Ambiguity            │ describes church-encoded kernel as core.   │
│    --> ACTION: Declare church-encoded kernel as Tier-0 API.                 │
├────────────────────────────────┼────────────────────────────────────────────┤
│ 5. Codec Maintenance Overhead  │ NIH provider codecs face rapid API churn.  │
│    --> ACTION: Strictly bound codec scope to agent consumption needs.       │
├────────────────────────────────┼────────────────────────────────────────────┤
│ 6. Stepper Signature           │ Three different existential steppers are   │
│    Proliferation               │ sketched across catalog, db, and model.    │
│    --> ACTION: Unify into canonical `Stepper m a` GADT.                     │
└────────────────────────────────┴────────────────────────────────────────────┘
```

---

## 7. Strategic Recommendations & Immediate Action Plan

To transition seamlessly from the design phase into Phase 0 execution, work should
proceed in the following four tightly sequenced stages:

### Stage 1: Close Foundation Specifications (1–2 days)
1. Complete `FIELDS_RECORDS_DESIGN.md` §§2–4:
   - Formulate the HKD Functor family (`Identity`, `TriState`, `Column`).
   - Define `SomeRow` existentially over `Record f r` with `Tag k v`.
   - Decide Decision 4: unknown fields preserved in serialization edge with E4
     enforcement.
2. Normalize all stepper sketches (`Subscription m`, `Cursor es row`, `EventCursor m`)
   to the single canonical `Stepper m a` GADT in `EFFECT_CATALOG_DESIGN.md`.

### Stage 2: The Phase 0 Proof Spikes (1 week)
1. Initialize the multi-package `cabal.project` with GHC2024 commons and pinned
   GHC 9.14 toolchain.
2. Execute the **Handlers-as-Records Spike**:
   - Verify record merge of handler functions into `effectful` dynamic dispatch and
     `polysemy` tactics.
   - If clean: adopt. If brittle: fall back immediately to handwritten bridge
     interpreters.
3. Code the minimal `sarutahiko-fields` and `sarutahiko-records` packages.
   Implement the 40-column compile-time test to establish the performance baseline.

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

The `sarutahiko` design corpus is an extraordinary work of systems architecture. It
avoids the ad-hoc pragmatism that leads to architectural rot, choosing instead to
ground the entire ecosystem in deep, dual algebraic foundations. Its risks are not
flaws of conception, but the natural challenges of high-ambition designs: verifying
type-level mechanics against real runtimes, holding compilation overhead linear, and
disciplining execution sequencing. With the resolutions and roadmap outlined in this
review, the project is poised to cross the threshold from design into a landmark
Haskell implementation.
