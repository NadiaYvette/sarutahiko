# Hashigakari (橋掛かり) — The Database Access Library

Status: DRAFT v0.1 · 2026-09-24
Related: `NIH_PLAN.md` (Tier 5, Phase 4), `YAMAARASHI_DESIGN.md` (streams, Resource effect,
DAG layer), `Haskell Algebraic Effects Pattern Names-2.md` (the source program: greenfield
row-typed DSL on hasql + large-anon, beam retrofit, TriState patches, existential cursors,
linear resource safety)

**Hashigakari** (橋掛かり) is the bridge passageway that carries the actor onto the Noh
stage from the right — fitting for the library that carries rows between the database
stage and the application. (The four hashira 柱 — the character pillars — are held in
reserve as a fallback name, e.g. for the four core modules or a future companion package.)

## 0. What it is, in one paragraph

A greenfield, row-polymorphic query DSL and execution stack: queries are *type-level row
transformations* over anonymous records (large-anon rows, vinyl interop); the SQL wire and
connection machinery are *not* rebuilt — hasql (Postgres, binary protocol, native cursors)
and a direct SQLite binding serve as execution engines behind dialect-indexed compilation.
Zero DTOs end to end: a SELECT yields exactly the record the query defines; `rcast` projects
at the edges; patches are TriState rows compiled to minimal UPDATEs; streaming is
memory-constant via existential cursors finalized through the shared `Resource` effect row.
The greenfield choice follows the source doc's verdict: every legacy ORM predates linear-time
extensible records, and retrofitting their tuple/generics cores means rewriting them anyway.

## 1. Design principles

1. **The query is the record.** No base-entity type, no DTO layer; a query's result row type
   is computed by the query expression itself.
2. **Linear-time compilation.** No GHC.Generics anywhere in schema or row machinery;
   large-anon's SmallArray# representation and large-generics-style dictionaries only.
   The compile-time regression suite includes a ≥40-column table (plan §4 obligation).
3. **Dialects are type-level, execution is existential.** Queries carry a dialect tag;
   features outside a dialect's ceiling are rejected at compile time; backend state hides
   behind existential steppers so application code never sees a backend type.
4. **Resources are effects.** Connections, transactions, and cursors are acquired and
   released through the `Resource`/`Scoped` effect row (`YAMAARASHI_DESIGN.md` §2.2) with
   effectful + polysemy interpreters, per the dual-interface contract (plan §0).
5. **Streaming is yamaarashi.** Result sets unfold into `Stream (Of (Record r)) (Eff es)`;
   element strategy (serial/async), DAG orchestration (`yamaarashi-flow` exports), and
   SSE sinks compose without translation.

## 2. Package layout

| Package | Contents |
|---|---|
| `hashigakari-core` | Row vocabulary over `sarutahiko-fields`: column descriptors, nullability and PG-domain tags, `Record f r` aliases for HKD functors (`Identity`, `TriState`, `Column`), row combinators (append, project, rename, diff, union), and the query AST + smart constructors. Zero backend dependencies. |
| `hashigakari-syntax` | Dialect-indexed SQL compilation from the AST: quoting, placeholders (binary vs textual), LIMIT/OFFSET vs FETCH/TOP ceilings, RETURNING, upserts, JSONB operators gated to Postgres, type-level ceiling enforcement (§3.4). |
| `hashigakari-hasql` | hasql-backed execution: connection settings, session/transaction effects, binary row decoding into anonymous records, cursor declaration + `FETCH FORWARD` stepping. |
| `hashigakari-sqlite` | direct SQLite binding (via `direct-sqlite`): prepared statements, `sqlite3_step` stepper, column decode into anonymous records. |
| `hashigakari-beam` | the `beam-large-anon` bridge: `AnonTable (r :: Row Type) (f :: Type -> Type)` with hand-written `Beamable` instances bypassing GHC.Generics; published standalone on Hackage. |
| `hashigakari-patch` | TriState HKD rows (RFC 7396/6902 semantics), generic diff engine (`Record Identity r` × `Record (TriState) r` → minimal UPDATE), conflict/reject policy. |
| `hashigakari-schema` | schema introspection → row types at runtime; migrations expressed as row diffs; round-trip with `sarutahiko-schema` descriptors. |

Bridge precedent, for calibration: `composite-opaleye` proved the vinyl↔profunctor pattern;
`hashigakari-beam` generalizes it to large-anon and to beam's `Beamable` machinery.

## 3. Core design

### 3.1 Rows and columns

A *column* is a field descriptor: name, base type, nullability, and domain tags (e.g. PG
type families `PGint4`, `PGtext`, `PGjsonb`; SQLite storage classes). Rows are large-anon
records over these descriptors; the HKD functor parameter is the one lever for intent:

```haskell
type Users = '["id" ':= Col PGInt8, "name" ':= Col PGText, "email" ':= Col (Maybe PGText)]

-- one schema, three intents, no DTO types:
type UserExpr   = Record (Column  f) Users   -- SQL expressions
type User       = Record Identity   Users   -- materialized row
type UserPatch  = Record TriState   Users   -- RFC 7396 patch
```

Aliases carry no runtime cost: `Record f r` is the large-anon record with a functor-mapped
dictionary, so expression/row/patch views of one schema are one definition.

### 3.2 The query AST

Relational algebra as row transformations; the AST node computes the output row type:

| Node | Row-type rule | Notes |
|---|---|---|
| `Table t` | yields `t` | from `hashigakari-schema` definitions |
| `Project r1 r2` | sub-row of `r1` | `rcast`-backed; the projection *is* the record |
| `Join r1 r2 on` | `r1 ++ r2` (conflicting names rejected at compile time) | name-based, not position-based |
| `LeftJoin r1 r2 on` | `r1 ++ Nullable r2` | type-level nullability lift |
| `Filter r p` | `r` | `p` built from `Record (Column f) r` expressions |
| `Aggregate r by agg` | the aggregation row | keys ++ aggregates |
| `Window r w` | `r ++ w` | window functions (ranking, offsets, cumulative aggregates) |
| `With name cte q` | yields `RowOf q` | scoped CTEs (`WITH` clauses); named subquery row in scope |
| `WithRecursive cte q`| yields `RowOf q` | recursive CTEs; guarded by `Supports 'RecursiveCTE` |
| `Union r` | `r` | row equality enforced |
| `Insert/Update/Delete` | affected/returning row | TriState patches compile to SET lists |
| `Upsert t conflict act`| affected/returning row | `ON CONFLICT DO UPDATE/NOTHING` using `TriState` patch |

#### Query Expressiveness Extensions
1. **Window Functions (`Window r w`):**
   - AST node: `Window :: Query d p r -> Record (WindowExpr f) w -> Query d p (r ++ w)`
   - Computes window frames: `OVER (PARTITION BY keys ORDER BY ord [ROWS/RANGE frame])`.
   - Supported expressions: `RowNumber`, `Rank`, `DenseRank`, `Lead offset def`, `Lag offset def`,
     and windowed aggregates (`WinSum`, `WinAvg`, `WinCount`).
   - Type rule: appends computed window columns `w` to input row `r`; conflicting field names
     are rejected at compile time.
2. **Common Table Expressions (`With` / `WithRecursive`):**
   - AST node: `With :: KnownSymbol name => Proxy name -> Query d p1 r1 -> Query d p2 r2 -> Query d (p1 ++ p2) r2`
   - Scopes intermediate named queries into the type environment without runtime view creation.
   - Recursive CTEs (`WithRecursive`) require base union step and dialect validation:
     `Supports 'RecursiveCTE d ~ 'True`.
3. **Upserting (`Upsert`):**
   - AST node: `Upsert :: Table t -> ConflictTarget t -> ConflictAction t -> Returning r -> Query d p r`
   - Actions: `DoNothing` or `DoUpdate (Record TriState t)` (leveraging the `TriState` functor
     from `FIELDS_RECORDS_DESIGN.md` §2.2).
   - Generates PostgreSQL / SQLite $\ge$3.24 `INSERT INTO ... ON CONFLICT (keys) DO UPDATE SET ...`
     with exact field mapping.

Smart constructors keep the AST surface small; the row-type rules are type families, so a
JOIN or window projection that would duplicate a field name is a compile error, not a runtime surprise.

### 3.3 Compilation

- **Dialect tags & Capability Ceilings.**
  `data Dialect = Postgres | SQLite` (open to growth). Queries verify feature support via
  type-level capability constraints:
  ```haskell
  type family Supports (feat :: Capability) (d :: Dialect) :: Bool where
    Supports 'JSONB            'Postgres = 'True
    Supports 'JSONB            'SQLite   = 'False
    Supports 'WindowFunctions  'Postgres = 'True
    Supports 'WindowFunctions  'SQLite   = 'True  -- Supported in SQLite >= 3.25
    Supports 'CTEs             'Postgres = 'True
    Supports 'CTEs             'SQLite   = 'True  -- Supported in SQLite >= 3.8.3
    Supports 'RecursiveCTE     'Postgres = 'True
    Supports 'RecursiveCTE     'SQLite   = 'True
    Supports 'Upsert           'Postgres = 'True
    Supports 'Upsert           'SQLite   = 'True  -- Supported in SQLite >= 3.24
  ```
  If a query invokes a feature not supported by the target dialect, compilation fails with
  a custom `TypeError` indicating the unsupported capability and target dialect ceiling.
- **Phases:** AST → dialect-normalized algebra → SQL text + placeholder vector (one-pass
  pretty-printer per dialect; no intermediate strings). Compilation is pure and cached.
- **Placeholders** map 1:1 onto hasql's binary encoders and SQLite's bind families; the
  parameter row type is computed with the same machinery as result rows.

### 3.4 Execution

- **Effects.** One signature, normalized to `m` per catalog rules:

  ```haskell
  data Database (m :: Type -> Type) :: Type -> Type where
    Query       :: Query dialect params row -> Record Identity params
                -> Database m (Maybe (Record Identity row))             -- single row
    Stream      :: Query dialect params row -> Record Identity params
                -> Database m (Stepper m (Record Identity row))         -- memory-constant
    Execute     :: Query dialect params ('["rowsAffected" ':= Int])
                -> Record Identity params
                -> Database m Int
    Transaction :: m a -> Database m a                                  -- Scoped specialization
  ```

- **Canonical Steppers.** Backend state hides in the canonical `Stepper m a` GADT
  (defined in `EFFECT_CATALOG_DESIGN.md` §4):

  ```haskell
  -- Stepper m (Record Identity row) unfolds into yamaarashi streams
  ```

  Postgres: `DECLARE … CURSOR` + `FETCH FORWARD n` inside the transaction scope;
  SQLite: the `sqlite3_stmt` pointer + `sqlite3_step`. `Stepper` unfolds into a
  `yamaarashi` stream; `Resource`/`Scoped` finalization guarantees `close` on
  short-circuit — the linear/bracketed guarantee from the source doc, realized through
  the effect row.

- **Sequencing Note (The Phase 1.5 Skinny Spine Protocol):** Full `hashigakari`
  (relational AST, dialect compilation, hasql execution, migrations) lands in Phase 4.
  However, the Phase 1.5 Hokora slice requires persisting events to SQLite with the
  blessed spine v0.2. Under the **Skinny Spine protocol** (`NIH_PLAN.md` §4,
  `HOKORA_SPEC.md` §4), a minimal, self-contained SQLite append writer using direct
  `sqlite3_step` parameter binding is pulled forward to Phase 1.5, allowing Hokora to
  run without waiting for Phase 4 AST machinery.

- **Transactions.** `Transaction` scopes are the only place cursors may live (Postgres
  semantics); the effect interpreter enforces nesting rules; session/pool management is an
  interpreter detail (`hashigakari-hasql` pools, `hashigakari-sqlite` single-writer).

### 3.5 Patches

`hashigakari-patch` gives every schema a patch row for free:

- `Record (TriState) r`: `Keep | Clear | Set a` — exactly RFC 7396's three states, no
  `Maybe (Maybe a)`.
- The diff engine compares `Record Identity r` against `Record (TriState) r` and emits the
  minimal `Update` AST node (only `Set` fields in the SET list), which `hashigakari-syntax`
  compiles per dialect.
- Merge-patch application to JSONB columns (Postgres) and to stored JSON documents reuses
  the same TriState engine; RFC 6902 arrays are a thin extension.

## 4. The beam bridge (`hashigakari-beam`)

Standalone, publishable, and upstreamable-in-spirit:

```haskell
newtype AnonTable (r :: Row Type) (f :: Type -> Type) = AnonTable (Record f r)

instance Beamable (AnonTable r) where
  zipBeamFieldsM :: Applicative m
                 => (forall x. Columnar' f x -> Columnar' g x -> m (Columnar' h x))
                 -> AnonTable r f -> AnonTable r g -> m (AnonTable r h)
  -- implemented by folding large-anon's row dictionaries; O(n), no Generics.Rep
```

- Kind alignment via the newtype (`beam` wants `(* -> *) -> *`); `zipBeamFieldsM` and
  `tblSkeleton` map onto large-anon's linear-time row combinators (the doc's §2 path).
- Payoff: ad-hoc projections return `AnonTable r Identity` — a first-class anonymous record
  that feeds JSON-RPC/MCP/SSE with `rcast` and zero DTOs (the doc's §3 payoff).
- Scope guard: this bridge does *not* rewrite beam's query AST; tuple flattening stays
  beam's problem. The bridge exists so beam users can opt into rows at their boundaries.

## 5. Testing

- **Property tests:** row-type rules (JOIN name conflicts, nullability lift, projection
  subsets); TriState diff minimality; placeholder/encoder round-trips.
- **Conformance:** run the same AST suite against both backends on a shared fixture schema;
  cursor early-exit must finalize inside both interpreters (effectful + polysemy) — the
  parity gate from plan §4 applies here too.
- **Golden SQL:** per-dialect pretty-printer snapshots, including the portability-ceiling
  rejections.
- **Compile-time ledger:** the ≥40-column table compiles in bounded time; wide-record
  benchmarks keep the large-* advantage honest (plan §4).

## 6. Non-goals and escalations

- **No new wire protocol.** hasql and direct-sqlite carry the wire; if a third backend is
  needed (e.g. MSSQL via ODBC), it enters as a new existential stepper + dialect tag, not a
  core change.
- **No ORM.** Relations, not entities; there is no lazy-association machinery to invent.
- **No Dhall evaluator work.** The Dhall bridge (marshalling Dhall configs into anonymous
  records) is a `sarutahiko-format-dhall` concern and stays out of hashigakari (source-doc
  verdict).
- Escalation path if the AST + type families hit a wall: fall back to
  `hashigakari-hasql`'s explicit decoder combinators (the source doc's "fastest working
  integration") while the DSL is reworked — the row vocabulary and execution layer are
  independently valuable, so the DSL is replaceable without sinking the library.
