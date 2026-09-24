# The Fields & Records Layer — Design Note (working: `sarutahiko-fields` / `sarutahiko-records`)

Status: DRAFT v0.2 · 2026-09-24 — §§1–7 fully articulated with tutorials and technical
specifications across all eight decisions for maintainer review
Related: `registers/REUSE_REGISTER.md` 2.1 (the foundation: pre-decisions recorded),
`MEMORY_ENGINE_DESIGN.md` §3.1/§3.4a/§6 (the demand-pull consumer and the worked
example this standard generalizes), `EFFECT_CATALOG_DESIGN.md` (`SomeRow` standard,
PVP-for-signatures as the parallel policy), `INSTRUMENTS_SPEC.md` (canonicalization —
decision 4's hook), `NIH_PLAN.md` §6 item 12 (kogaki — the `merge` consumer, decision
6's hook), `registers/CODEC_QUIRKS.md` (decoder-taxonomy seed, decision 7's hook)

**Thesis.** Every row in the program — memory-log envelopes, JSON-RPC payloads, codec
bags, locale records, message dictionaries — stands on these two packages. The note
fixes their shared standard in demand-pull order: the hardest consumer (the
append-only memory log, the least-reversible decision above the substrate) speaks
first, and every later section satisfies a written contract rather than improvising
vocabulary.

## 0. Scope and pre-decisions

From register 2.1 (2026-09-24): **one internal representation — large-anon,
exclusively**; vinyl exists only as third-party convenience adapters at package seams
(conversions at seams; `SomeRow` and all internal rows are large-anon). **The record
foundation is the maintainer's fork** (`large-records-interfaces`), canonical for the
program — forking being the mechanism that grants private-interface access for
analogue packages — with selective upstreaming of public-surface improvements.

**In-note decision order** (blessed 2026-09-24): §1 the row-evolution standard
(requirements-emitting) → §2 the HKD functor family (satisfies §1's absence
contract) → §3 the field datum & registry (satisfies §1's metadata contract, scoped
by §1–§2) → §4 unknown-field preservation → §5 combinator laws → §6 decoder recipes →
§7 compile-time economics.

---

## 1. The row-evolution standard (decision 3 — DRAFTED, review pending)

Generalizes the memory engine's §3.4a worked example ((kind, schemaV) tagging, witness
registry, strict-across/lenient-within, evolution-by-replay) into the program-wide
standard, adding what the worked example did not need yet: the lossy-change path,
forward compatibility for rolling/multi-writer deployments, and the provenance
derivation.

### 1.1 Which rows are versioned

Versioning is required for rows that cross a **persistence or wire boundary** (log
payloads, stored sessions, wire messages, serialized fixtures); purely transient
in-memory rows need not carry versions — zero cost when absent (the K4 flavor). A
version is a **monotonic integer per row kind**; the tag pair `(kind, schemaV)` is
carried in the envelope, not inferred from structure.

### 1.2 The principles

| ID | Principle | Content |
|---|---|---|
| **E1** | Authoritative tagging | Readers never infer version from structure. Structural coercion across versions is forbidden; cross-version access happens only through declared, total upgrade chains. "Strict across versions" means *no guessing*, not *no reading*. |
| **E2** | Additive by default | A minor version adds fields, never removes or retypes. Every added field carries a **for-older provision** (a default value or an explicit migration clause) attached at introduction (CD1). Each upgrade step `v(n) → v(n+1)` is a total function. |
| **E3** | Forward compatibility | An older reader encountering a newer payload may read it by ignoring fields it does not know. What it ignores is dropped *in the reader's view only* — the payload itself is untouched (E6). Within a known version, unknown fields are handled per decision 4 (preservation locus). |
| **E4** | No re-serialization across forward boundaries | A reader that consumed a payload *newer* than its schema must not re-serialize it — pass-through or reject. This is the anti-silent-loss rule for rolling upgrades and multi-writer stores (MEMORY_ENGINE §6's concurrency world). |
| **E5** | The two-phase lossy path | Field removal or type change = **major version boundary**, and nothing else is. Removal is preceded by a deprecated phase (field retained, marked deprecated, still written); the upgrade function at the boundary documents exactly what is dropped. Retype-under-same-name is forbidden: new field name, deprecate the old. **No silent loss, ever.** |
| **E6** | Stored bytes immutable; upgrades are views | Persisted payloads remain as-written. Upgrade-on-read is a read-time projection; the log is never rewritten to current form. Materializations (rebuilt stores, replay outputs) are *new artifacts* carrying their own provenance (envelope `original_version`). |
| **E7** | Derived provenance | Per-field vintage is **derived, never stored**: `original_version` (envelope) ⊗ field introduction-version (field metadata) ⇒ which fields in an upgraded view are migrated vs as-written. Consequence: the absence representation needs no "defaulted" or "vintage" state (CA3). |

### 1.3 Provenance derivation (E7 in table form)

| Envelope says | Field `f` introduced at | Upgraded view shows |
|---|---|---|
| `original_version = current` | ≤ current | `f` as written |
| `original_version = V < current` | ≤ V | `f` as written (survived every upgrade step) |
| `original_version = V < current` | `V_f > V` | `f` migrated (its for-older provision applied at step `max(V, ·) → V_f`) |

The derivation needs exactly two knowns — the envelope's original version and the
field's introduction version — so both must exist: the first is E6's envelope
requirement; the second is CD1. Nothing about vintage lives in the row.

### 1.4 The emitted contracts

**For decision 5 (the absence representation):**

- **CA1 — Three states, exactly.** An absence-aware field functor with states
  `Absent` (field not in this version), `PresentNull` (explicit null),
  `Present a`. Absent ≠ null on the wire (RFC 7396 merge-patch semantics depend on
  the distinction; `{"a": null}` deletes, `{}` preserves).
- **CA2 — Laws.** The absent/null distinction survives row → canonical encoding →
  row round-trips; absence-mapping composes with projection
  (`project ∘ mapAbsence = mapAbsence ∘ project`).
- **CA3 — No provenance state.** The functor carries no "defaulted" or "vintage"
  variant — provenance is derived per E7. Three states, no fourth.

**For decision 3's consumer, decision 1 (the field datum):**

- **CD1 — Required metadata.** Every field datum carries: introduction-version,
  deprecation status (for E5's two-phase path), and its for-older provision (default
  or migration clause, attached at introduction).
- **CD2 — Declare once, lineage recorded.** Fields are declared once with version
  lineage; the declaration feeds the witness registry (§1.5). The registry model
  itself (global vs module-scoped consumption, plugin interaction) is decision 1's
  to make — this standard only requires the metadata exist.

### 1.5 Conformance and testkit requirements

- **Witness registry.** Every `(kind, schemaV)` occurring in the wild is registered
  with a structure witness and its upgrade chain to current. Unregistered pairs are
  foreign payloads (E1: reject or quarantine, never guess).
- **Per-step laws** (property-tested, the catalog's law-testkit pattern): each
  upgrade step is total (never throws); preserves every non-deprecated field
  exactly; applies declared for-older provisions exactly.
- **Golden chains.** The composed chain from the oldest registered version to
  current, run against golden fixtures: conformance is exact-match, and the composed
  chain is what ships, not per-step improvisation at call sites.
- **Determinism.** Upgrade is a pure function: same payload + same chain ⇒ same
  upgraded view, always (io-sim-friendly; kakegoe-replay-friendly).

### 1.6 The memory engine as specialization

| MEMORY_ENGINE §3.4a / §3.1 | This standard |
|---|---|
| `(kind, schemaV)` tag pair, witness registry | E1 + §1.5 |
| Strict-across / lenient-within | E1 (no guessing) + E3/decision 4 (within-version) |
| Evolution by replay | E2 (additive, total steps) + E6 (views, immutable bytes) |
| Envelope versioning | E6's `original_version` + E7's derivation |
| Additive-only rule | E2 as the default line; E5 adds the lossy path the engine has not yet needed |
| Single-writer turn program (§6) | E4 anticipated for its multi-writer future |

The generalization *adds* to the engine's scheme exactly two things it has not yet
needed: the two-phase lossy path (E5) and the no-re-serialization rule (E4). Both are
recorded there as forward obligations, not changes.

### 1.7 What this section settles and leaves open

Settles: the standard itself — seven principles, the derivation, the contracts, the
conformance machinery. Leaves open **by design**: the absence mechanism (decision 5,
must satisfy CA1–CA3), the metadata mechanism (decision 1, must satisfy CD1–CD2),
the preservation locus (decision 4, constrained by E3/E4), with §2–§7 following the
§0 order.

---

## 2. The HKD functor family (decision 5) — satisfies CA1–CA3

### 2.1 Tutorial: Higher-Kinded Data (HKD) and Anonymous Records

In traditional Haskell, data types are concrete and monomorphic in their field wrappers:

```haskell
-- Traditional nominal record: fields are fixed and concrete
data User = User
  { userId    :: !Int
  , userName  :: !Text
  , userEmail :: !Text
  }
```

This traditional form suffers from severe inflexibility across systems tiers:
1. **Validation / Construction:** When parsing untrusted wire input, fields might be missing, malformed, or null. A parser cannot construct a `User` until every field is valid. Developers typically create a secondary type `data PartialUser = PartialUser { userId :: Maybe Int, ... }`—doubling type definitions and requiring tedious manual mapping.
2. **Partial Updates (RFC 7396 / SQL UPDATE):** A PATCH request or database update modifies a subset of fields. A distinct `data UserPatch = UserPatch { userId :: Maybe (Maybe Int), ... }` is invented.
3. **Projections & Schemas:** If one wants to attach metadata (documentation, SQL column definitions, validation error lists) to each field, yet another type is created.

**Higher-Kinded Data (HKD)** solves this by parameterizing the record over a type constructor `f :: Type -> Type`:

```haskell
-- HKD nominal record
data UserHKD f = UserHKD
  { userId    :: f Int
  , userName  :: f Text
  , userEmail :: f Text
  }
```

Now, a single record definition serves all lifecycle phases:
- `UserHKD Identity` is the canonical, fully-instantiated domain model.
- `UserHKD Maybe` represents optional or partial fields.
- `UserHKD (Const Text)` represents field documentation strings or column aliases.
- `UserHKD (Const (NonEmpty Text))` holds validation error messages per field.

#### How `large-anon` Implements HKD Natively

In `large-anon` (and the maintainer's canonical fork `large-records-interfaces`), anonymous records are **natively functor-parameterized** at the substrate level:

```haskell
-- In Data.Record.Anon.Internal.Advanced:
newtype Record (f :: Type -> Type) (r :: Row Type) = Record (SmallArray# Any)
```

The type parameter `r` is a type-level row (a collection of symbol-type pairs, e.g. `'[ "id" := Int, "name" := Text ]`), and `f` is the field wrapper functor.

Crucially:
- Standard anonymous records `AnonRecord r` are simply the type synonym `Record Identity r`.
- Because `Record f r` is represented internally as a contiguous untyped array (`SmallArray# Any`), the functor wrapper `f` exists **primarily at compile time in the GHC type system**.
- Switching functors (e.g., from `Record TriState r` to `Record Identity r`) does *not* require unpacking and repacking nested constructors or allocating intermediate tuples. It is either a zero-cost unsafe coercion (when wrappers are `newtype`s) or a single, flat, linear-time array map/traverse.

### 2.2 The Blessed Functor Family

`sarutahiko-records` blesses exactly four primitive functors in the core family:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          THE BLESSED FUNCTOR FAMILY                         │
├──────────────┬───────────────────────────────┬──────────────────────────────┤
│ Functor      │ Type Definition               │ Systems Domain               │
├──────────────┼───────────────────────────────┼──────────────────────────────┤
│ `Identity`   │ `newtype Identity a =         │ Canonical runtime state, log │
│              │    Identity { runIdentity :: a }` │ payloads, pure turns       │
├──────────────┼───────────────────────────────┼──────────────────────────────┤
│ `TriState`   │ `data TriState a =            │ Wire envelopes, RFC 7396     │
│              │    Absent                     │ patches, evolution upgrades, │
│              │  | PresentNull                │ SQL nullable updates         │
│              │  | Present !a`                │ (Satisfies CA1–CA3)          │
├──────────────┼───────────────────────────────┼──────────────────────────────┤
│ `Column`     │ `data Column a =              │ Hashigakari query ASTs,      │
│              │    ColExpr !(SQLExpr a)       │ relational projections, SQL  │
│              │  | ColNamed !ColumnName`       │ table definitions            │
├──────────────┼───────────────────────────────┼──────────────────────────────┤
│ `Const c`    │ `newtype Const c a =          │ Field metadata, schema docs, │
│              │    Const { getConst :: c }`   │ validation error vectors     │
└──────────────┴───────────────────────────────┴──────────────────────────────┘
```

#### 1. `Identity` — The Concrete Ground State
Used for all active computation, memory engine events (`SomeRow (Record Identity r)`), LLM context rows, and tool arguments. Guaranteed zero runtime indirection.

#### 2. `TriState` — The Absence & Patch Functor (Satisfies CA1–CA3)
The classical Haskell `Maybe a` is fundamentally inadequate for wire serialization and database updates because it conflates two semantically distinct conditions:
- A field was **omitted** from the payload (`{}`).
- A field was **explicitly provided as null** (`{"key": null}`).

In RFC 7396 (JSON Merge Patch) and SQL `UPDATE` operations:
- Omission (`Absent`) means: *Leave the existing value untouched*.
- Explicit null (`PresentNull`) means: *Delete the field or set the column to NULL*.
- Value (`Present a`) means: *Update the field to this new value*.

`TriState` formalizes this distinction:

```haskell
data TriState a
  = Absent         -- Field omitted / not present in this schema version
  | PresentNull    -- Explicit wire null / SQL NULL
  | Present !a     -- Field present with valid value
  deriving stock (Eq, Show, Functor, Foldable, Traversable)

instance Applicative TriState where
  pure = Present
  Present f <*> Present x = Present (f x)
  Absent    <*> _         = Absent
  _         <*> Absent    = Absent
  PresentNull <*> _       = PresentNull
  _         <*> PresentNull = PresentNull

instance Alternative TriState where
  empty = Absent
  Absent <|> r = r
  l      <|> _ = l
```

##### Contract Verification (CA1–CA3)
- **CA1 (Three States Exactly):** `TriState` possesses exactly three constructors: `Absent`, `PresentNull`, `Present a`. No additional constructors are permitted.
- **CA2 (Laws):**
  1. *Projection Naturality:* Projection distributes cleanly over absence mapping:
     $$\text{project} \circ \text{mapTriState } g = \text{mapTriState } g \circ \text{project}$$
  2. *Round-Trip Faithfulness:* Under canonical encoding:
     - `Absent` $\iff$ key omitted from JSON object.
     - `PresentNull` $\iff$ `"key": null`.
     - `Present x` $\iff$ `"key": encode(x)`.
     Decoding any canonical JSON string back into `Record TriState r` restores the exact constructor.
- **CA3 (No Provenance State):** `TriState` carries **no** `Defaulted a` or `Migrated a` constructor. Field vintage is strictly derived per E7 from envelope `original_version` and field introduction metadata. Adding provenance variants into the functor would pollute wire types and invalidate algebraic laws.

#### 3. `Column` — The Relational Engine Functor
Used in `hashigakari` so that a single row definition `type UserRow = '[ "id" := Int, "name" := Text ]` can describe:
- The database table schema: `Record Column UserRow`
- An active SQL projection expression: `Record Column UserRow`
- The retrieved result row: `Record Identity UserRow`

```haskell
data Column a where
  ColExpr  :: !(SQLExpr a)  -> Column a
  ColNamed :: !ColumnName   -> Column a
  ColLit   :: !a            -> Column a
  deriving stock (Functor)
```

#### 4. `Const c` — The Uniform Metadata Functor
Standard base functor where every field contains a value of type `c`, ignoring the field's underlying data type. Used for:
- Column name lists: `Record (Const Text) r`
- Field docstrings: `Record (Const Doc) r`
- Per-field validation failures: `Record (Const [ValidationError]) r`

### 2.3 Functor Combinators and Row Transformations

`sarutahiko-records` provides linear-time mapping, zipping, and traversal across functor wrappers, utilizing the `large-anon` dictionary-vector infrastructure:

```haskell
-- Functor transformation over all fields
mapRecord
  :: (forall a. f a -> g a)
  -> Record f r
  -> Record g r

-- Constrained mapping (e.g. requires Show for every field)
cmapRecord
  :: AllFields r c
  => Proxy c
  -> (forall a. c a => f a -> g a)
  -> Record f r
  -> Record g r

-- Binary applicative zip
zipWithRecord
  :: (forall a. f a -> g a -> h a)
  -> Record f r
  -> Record g r
  -> Record h r

-- Effectful traversal (e.g. validating TriState -> Either ValidationErrors Identity)
traverseRecord
  :: Applicative m
  => (forall a. f a -> m (g a))
  -> Record f r
  -> m (Record g r)
```

---

## 3. The field datum and registry model (decision 1) — satisfies CD1–CD2

### 3.1 Tutorial: Nominal Selectors vs Symbol-Indexed Field Data

In classical Haskell, record fields are top-level selector functions:
```haskell
data Account = Account { balance :: Int }
data Ledger  = Ledger  { balance :: Int } -- ERROR without DuplicateRecordFields
```

Even with GHC 9.2+ `DuplicateRecordFields` and `OverloadedRecordDot`, fields remain tethered to nominal data type definitions. In extensible records, fields are indexed by type-level strings (`Symbol`):

```haskell
type AccountRow = '[ "balance" := Int, "currency" := Currency ]
```

However, raw type-level strings introduce dangerous systems hazards:
1. **Typo Vulnerability:** Writing `getField @"balence" r` causes compile errors, but writing `"balence"` in a schema upgrade definition silently introduces an unintended field.
2. **Metadata Amnesia:** A raw symbol `"balance"` carries no information about *when* it was introduced, whether it is deprecated, or how older serialized records should be populated if the field is absent.
3. **Refactoring Friction:** Renaming a field across a 20-package repository requires error-prone string grepping.

### 3.2 The Field Datum Architecture

`sarutahiko-fields` elevates fields from inert string literals into **first-class typed data witnesses**:

```haskell
-- The first-class field datum
data FieldDatum (s :: Symbol) (a :: Type) = FieldDatum
  { fdSymbol      :: !(Proxy s)
  , fdIntroVer    :: !SchemaVersion        -- Monotonic introduction version (CD1)
  , fdDeprecation :: !(Maybe Deprecation)  -- Two-phase lossy tracking (CD1, E5)
  , fdForOlder    :: !(ForOlder a)         -- Upgrade provision for older payloads (CD1, E2)
  }

data Deprecation = Deprecated
  { depSince   :: !SchemaVersion
  , depMessage :: !Text
  , depDropAt  :: !SchemaVersion           -- Planned major version removal
  } deriving stock (Eq, Show)

data ForOlder a
  = NoDefault                              -- Introduced at v1; cannot be absent in valid data
  | StaticDefault !a                       -- Deterministic constant fallback
  | DerivedDefault (forall f r. Record f r -> a) -- Dynamic derivation from existing fields
```

#### Contract Verification (CD1–CD2)
- **CD1 (Required Metadata):** Every field declared in the registry carries its monotonic `SchemaVersion`, optional `Deprecation` schedule, and total `ForOlder a` provision.
- **CD2 (Declare Once, Lineage Recorded):** A field datum is defined **exactly once** in a domain module. All packages requiring the field import its typed witness. Lineage is tracked immutably in the witness itself.

### 3.3 The Registry Model: The Hybrid Solution

We reject two naive extremes:
- **The Global Type-Level Registry (Rejected):** Storing a monolithic type-level association list of all fields across the entire program. *Fatal flaw:* Every field addition causes a full rebuild of the entire package tree, destroying compile-time economics.
- **Uncontrolled Local Ad-Hoc Declarations (Rejected):** Allowing each module to invent symbols on the fly. *Fatal flaw:* Inconsistent types for the same concept (e.g. `"session_id" := Text` vs `"sessionId" := UUID`), missing upgrade rules, and broken schema evolution.

**The Blessed Hybrid Registry:**
1. **Domain-Scoped Field Modules:** Fields are grouped into cohesive domain modules inside `sarutahiko-fields` (e.g. `Sarutahiko.Fields.Spine`, `Sarutahiko.Fields.Model`, `Sarutahiko.Fields.Session`):
   ```haskell
   module Sarutahiko.Fields.Spine where

   f_seq :: FieldDatum "seq" Int
   f_seq = FieldDatum Proxy (SchemaVersion 1) Nothing NoDefault

   f_actor :: FieldDatum "actor" ActorId
   f_actor = FieldDatum Proxy (SchemaVersion 1) Nothing NoDefault

   f_cause :: FieldDatum "cause" (Maybe EventId)
   f_cause = FieldDatum Proxy (SchemaVersion 2) Nothing (StaticDefault Nothing)
   ```
2. **First-Class Value and Type Witnesses:**
   Exporting `f_seq` provides both the runtime witness (with CD1 metadata) and the type-level symbol for record construction:
   ```haskell
   type SeqField = "seq" := Int
   ```
3. **Typechecker Plugin Validation:**
   The `large-anon` plugin, supplemented by the `sarutahiko-fields` checker, verifies that any record tagged with a `SchemaVersion V` contains only fields whose `fdIntroVer <= V`.

---

## 4. Unknown-field preservation (decision 4)

### 4.1 Tutorial: The Distributed Evolution Dilemma

In distributed agent systems and append-only event logs, components running different schema versions interact continuously:
- **Writer** runs schema version 3 (knows fields: `A`, `B`, `C`).
- **Reader / Intermediary** runs schema version 2 (knows only: `A`, `B`).

When the Reader consumes a payload from the Writer:
- **Forward Compatibility (E3)** dictates that Reader must succeed in reading `A` and `B`, simply ignoring the unknown field `C`.
- **Anti-Silent-Loss (E4)** dictates that if the Reader forwards, routes, or stores this record, it **must not strip field `C`**. Stripping `C` corrupts data for downstream version 3 consumers.

The fundamental architectural question: **Where should unknown fields be held?**

### 4.2 The Architectural Binary

```
Option A: Row Representation            Option B: Serialization Envelope (Adopted)
┌──────────────────────────────┐        ┌─────────────────────────────────────────┐
│ Record f (r ++ '[            │        │ data WireEnvelope a = WireEnvelope      │
│   "_spurious" := Map Text Val│        │   { envPayload       :: !a              │
│ ])                           │        │   , envUnknownFields :: !(Map Text Val) │
└──────────────────────────────┘        │   , envRawBytes      :: !ByteString     │
  ✖ Pollutes all internal logic         │   }                                     │
  ✖ Breaks record equality              └─────────────────────────────────────────┘
  ✖ Incompatible with large-anon          ✔ Pure records inside domain code
                                          ✔ Zero untyped leakage into business logic
                                          ✔ Exact byte-level hash determinism
```

#### Why Option A (Row-Level Preservation) Fails
Embedding a spurious fields map (`Map Text Value`) directly into `Record f r`:
1. **Pollutes Domain Signatures:** Every function operating on user records must account for the phantom presence of `_spurious`.
2. **Breaks Structural Equality:** Two records with identical logical values compare unequal if an upstream proxy added an unrecognized tracing header.
3. **Violates the `large-anon` Foundation:** `large-anon` relies on compile-time static row schemas mapped to `SmallArray#`. Injecting dynamic maps breaks array layout optimization.

### 4.3 The Adopted Decision: Envelope-Locus Preservation

Unknown fields are preserved **strictly in the `WireEnvelope` at the serialization boundary**:

```haskell
data WireEnvelope a = WireEnvelope
  { envKind            :: !RowKind
  , envSchemaVersion   :: !SchemaVersion      -- Version of the payload schema
  , envOriginalVersion :: !SchemaVersion      -- E6: Version at write time
  , envPayload         :: !a                  -- Typed Record Identity r
  , envRawBytes        :: !ByteString         -- Unmodified wire bytes
  , envUnknownFields   :: !(Map Text Value)   -- Preserved unknown fields
  } deriving stock (Eq, Show, Functor)
```

#### Enforcement of E3 and E4
1. **Decoding (E3):** When decoding wire JSON into `WireEnvelope (Record Identity r)`:
   - Known fields belonging to `r` are decoded into the `Record`.
   - Any extra JSON keys not in `r` are extracted into `envUnknownFields`.
   - The original unmodified wire `ByteString` is preserved in `envRawBytes`.
2. **Re-serialization Guard (E4):**
   - If `envOriginalVersion <= localSystemVersion`: The reader fully understands the schema. It may safely re-serialize `envPayload` to new wire bytes.
   - If `envOriginalVersion > localSystemVersion`: The payload originated from a newer system. The intermediary **must not re-serialize `envPayload`**. It must either pass `envRawBytes` through unmodified or abort with an explicit `ForwardBoundaryReserializationForbidden` exception.

### 4.4 Interaction with `kakegoe` Cache Simulation and Hash Determinism

In modern LLM agent systems, prompt caching (e.g. Anthropic prompt caching, OpenAI prefix caching) requires **strict byte-level stability**:
- Any change in JSON key ordering, insignificant whitespace, or omitted fields alters the SHA-256 prefix hash, causing catastrophic cache misses and $10\times$ cost inflation.
- In `kakegoe` (the instrument harness), replay fidelity requires identical hashes across runs.

By storing `envRawBytes` directly:
- Passing messages through intermediary routers does not alter a single byte of the wire representation.
- Cache simulator hashes are computed over `envRawBytes`, guaranteeing 100% determinism independent of GHC's internal `Map` traversal order.

---

## 5. Combinator laws (decision 6)

### 5.1 The Row Algebra

`sarutahiko-records` defines a closed row algebra for structural manipulation:

```haskell
-- Disjoint union (concatenation)
(++) :: Record f r1 -> Record f r2 -> Record f (r1 ++ r2)

-- Sub-row projection
rcast :: SubRow r sub => Record f r -> Record f sub

-- Difference (subtraction)
(\\) :: SubRow r sub => Record f r -> Record f (r \\ sub)

-- Override Merge (right-biased overlay)
(⊕) :: Record f r1 -> Record f r2 -> Record f (Merge r1 r2)
```

### 5.2 Upstream Foundation: `large-anon`'s `Diff` Core

The row algebra does not reinvent row indexing. It builds directly upon `large-anon`'s internal engine:
- `Data.Record.Anon.Internal.Core.Diff`: Computes compile-time differences between row types as bitmasks and offset permutations.
- Projections (`rcast`) and restrictions (`\\`) compile down to a single memory copy (`copySmallArray#`) with pre-calculated index offsets, executing in sub-microsecond linear time.

### 5.3 The Merge Combinator (`⊕`) and Override Semantics

The novel contribution of `sarutahiko-records` is the formalization of the **merge combinator (`⊕`)**:
When merging two records `r1` and `r2`, fields existing in both rows are resolved using **right-biased override**:

$$\text{Merge } r_1 \; r_2 = (r_1 \setminus r_2) \cup r_2$$

#### The Primary Target Consumers
1. **CLDR Locale Inheritance (`kogaki`):**
   In Unicode Common Locale Data Repository (CLDR), regional formats inherit from parent languages:
   $$\text{Locale}_{\text{en-US}} = \text{Locale}_{\text{root}} \oplus \text{Locale}_{\text{en}} \oplus \text{Locale}_{\text{en-US}}$$
   The US regional profile only specifies overrides (e.g. date format `MM/DD/YYYY`); all other fields fall through to standard English, then root.
2. **Configuration Hierarchy:**
   $$\text{RuntimeConfig} = \text{DefaultConfig} \oplus \text{FileConfig} \oplus \text{EnvConfig} \oplus \text{CliFlags}$$

### 5.4 The Formal Algebraic Laws of `⊕`

The merge operator `(⊕)` satisfies six strict algebraic laws, enforced via Hedgehog property tests:

| Law | Mathematical Statement | Systems Interpretation |
|---|---|---|
| **L1: Associativity** | $(a \oplus b) \oplus c = a \oplus (b \oplus c)$ | Multi-layer overlays (defaults $\oplus$ file $\oplus$ CLI) evaluate identically regardless of grouping. |
| **L2: Left Identity** | $\emptyset \oplus a = a$ | Merging an empty record on the left is a no-op. |
| **L3: Right Identity** | $a \oplus \emptyset = a$ | Merging an empty record on the right is a no-op. |
| **L4: Idempotence** | $a \oplus a = a$ | Merging a record with itself produces an identical record. |
| **L5: Right Precedence** | $\forall k \in \text{dom}(b).\; \pi_k(a \oplus b) = \pi_k(b)$ | The right-hand record strictly overrides any shared field $k$. |
| **L6: Projection Distribution** | $\text{rcast}_s (a \oplus b) = \text{rcast}_{s \cap \text{dom}(a)} a \oplus \text{rcast}_{s \cap \text{dom}(b)} b$ | Projecting a sub-row from a merged record equals merging the projected sub-rows. |

---

## 6. Decoder recipes (decision 7)

### 6.1 The Anti-Generics Thesis

Standard Haskell JSON decoding (`aeson` via `GHC.Generics`) is prohibited in core paths:
```haskell
-- FORBIDDEN in hot paths:
deriveJSON defaultOptions ''UserPayload
```

**Why `GHC.Generics` is Rejected:**
1. **Compiler Bloat:** `GHC.Generics` constructs an enormous balanced tree of metadata wrappers (`M1 (D1 ... (C1 ... (S1 ... (K1 ...)))))`). For large rows (30+ fields), this generates megabytes of intermediate GHC Core, degrading compilation times quadratically ($O(N^2)$).
2. **Opacity:** Derived generic decoders cannot dynamically adjust behavior based on envelope `SchemaVersion` or invoke total `ForOlder a` upgrade provisions without unwieldy custom typeclass instances.
3. **Memory Allocation:** Generic decoding allocates dozens of intermediate algebraic constructors before assembling the final record.

### 6.2 The Decoder Recipe Architecture: "Nth Codec is Field List + Recipe"

In `sarutahiko-records`, a record decoder is constructed as a first-class applicative recipe over the row's fields:

```haskell
-- A single-field decoding recipe
data FieldCodec a = FieldCodec
  { fcKey     :: !Text
  , fcDecoder :: !(Value -> Parser a)
  , fcDefault :: !(Maybe a)
  }

-- A row decoder is a record of field codecs
type RowCodec r = Record FieldCodec r
```

#### Compilation into Linear-Time Vector Deserializers
Under `large-anon`, a `RowCodec r` compiles into a flat, non-allocating parser:
1. At compile time, the plugin provides a vector of field keys and integer array offsets.
2. At runtime, the JSON object's hash table is probed once per expected field key.
3. Decoded values are written directly into an uninitialized `SmallMutableArray# Any`.
4. The array is frozen into `Record Identity r` in $O(N)$ linear time with **zero intermediate AST allocation**.

### 6.3 Canonical JSON Encoding

For cache stability (prompt caching, `kakegoe` hashes, immutable event logging), all row encoders follow strict canonical formatting:
1. **Lexicographical Key Sorting:** Object keys are emitted in strict Unicode code-point order.
2. **Whitespace Minimization:** Zero insignificant whitespace (`{"a":1,"b":2}`).
3. **Absence Functor Semantics:**
   - `Absent` fields: Key omitted entirely.
   - `PresentNull` fields: Emitted as `"key":null`.
   - `Present v` fields: Emitted as `"key":encode(v)`.

### 6.4 Structured Wire Error Taxonomy

Seeded from confirmed entries in `CODEC_QUIRKS.md`, decoding failures never return opaque strings. They emit structured, machine-inspectable diagnostic types:

```haskell
data WireDecodeError
  = MissingRequiredField
      { errField   :: !Text
      , errSchemaV :: !SchemaVersion
      }
  | TypeMismatch
      { errField    :: !Text
      , errExpected :: !Text
      , errActual   :: !Value
      }
  | UnexpectedNull
      { errField :: !Text }
  | UnknownEnumValue
      { errField :: !Text
      , errValue :: !Text
      , errLegal :: ![Text]
      }
  | ClosedEnvelopeViolation
      { errUnexpectedFields :: !(Set Text) }
  | ProviderQuirkViolation
      { errQuirkId :: !Text
      , errDetail  :: !Text
      }
  deriving stock (Eq, Show)
```

---

## 7. Compile-time economics (decision 8)

### 7.1 The Extensible Records Compile-Time Trap

For twenty years, extensible record libraries in Haskell (`HList`, `vinyl`, `extensible`) have suffered from a fatal operational defect: **compile-time scaling collapse**.

#### The Root Cause: Type-Level List Induction
In naive extensible records, a row of 40 fields is represented as a type-level linked list:
```haskell
type BigRow = '[ "f1" := T1, "f2" := T2, ..., "f40" := T40 ]
```
Every record operation (field access, projection, concatenation) requires GHC's constraint solver to perform inductive proof search along the list:
- Accessing field 35 requires unwrapping 35 `Cons` constructors.
- Projecting a sub-row of 20 fields from 40 fields triggers $20 \times 40 = 800$ constraint resolution steps.
- Compile time and GHC memory usage scale as $O(N^2)$ or $O(N^3)$, causing builds to stall for minutes and IDE language servers to run out of memory.

### 7.2 How `large-anon` Solves This: The Plugin Architecture

`large-anon` (and our canonical fork) bypasses type-level list induction entirely through a **GHC Typechecker Plugin**:

```
                       GHC Typechecker Plugin
┌──────────────────┐    Interception Hook    ┌───────────────────────────┐
│ HasField "f35"   │ ──────────────────────> │ Direct Hash Table Lookup  │
│ Record f BigRow  │                         │   Offset = 34             │
└──────────────────┘                         └───────────────────────────┘
                                                           │
                                                           ▼
                                             Emits SmallArray# Index Op
                                             (Zero Inductive Search)
```

1. The plugin intercepts `HasField`, `SubRow`, and `Merge` constraints during type checking.
2. It sorts row symbols lexicographically and assigns static integer indices using fast C++/Haskell algorithms outside GHC's rule engine.
3. It emits GHC Core that indexes directly into `SmallArray#` at constant offset `34#`.
4. **Result:** Compilation time scales **strictly linearly ($O(N)$)** with field count.

### 7.3 Small-Rows Discipline and Factoring Rules

To maintain instantaneous IDE feedback and human legibility, `sarutahiko` enforces the **Small-Rows Discipline**:
- **The 25-Field Ceiling:** No single row type shall declare more than 25 fields directly.
- **Component Factoring:** Large entities must be factored into logical sub-rows and combined via type-level union (`++`):
  ```haskell
  type AgentSessionRow =
    SessionIdentityRow ++
    SessionMetricsRow  ++
    SessionPolicyRow   ++
    SessionStateRow
  ```
- Sub-rows can be independently projected, validated, and tested without dragging in the complete session definition.

### 7.4 Custom `TypeError` Diagnostics

Type mismatch errors in extensible records can produce terrifying multi-page GHC error dumps. `sarutahiko-records` uses GHC's `GHC.TypeLits.TypeError` combined with plugin diagnostics to deliver human-friendly error messages:

```haskell
-- Example Custom Diagnostic:
-- When a developer requests a field missing from the row:
• Error: Field 'usrId' does not exist in record:
    Record Identity SessionRow
  Did you mean 'userId'?
  Known fields in this row are:
    - userId      :: UserId
    - actorId     :: ActorId
    - createdAt   :: UTCTime
```

### 7.5 The $\ge$40-Column Benchmark & Regression Suite

To ensure that no change to GHC flags, dependencies, or record wrappers degrades compilation speed, `sarutahiko-records` includes a standing **Compile-Time Regression Suite**:
- A synthetic test module generating rows of 10, 20, 40, and 80 columns.
- Measured in CI by the nightly compile-time ledger (`INFRASTRUCTURE.md` §2).
- **Quality Gate:** If compiler time per field exceeds $O(N)$ linear threshold (specifically, if compile time for 80 columns exceeds $2.2\times$ compile time for 40 columns), the build fails automatically.
