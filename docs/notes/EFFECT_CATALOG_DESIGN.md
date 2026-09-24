# The Effect-Signature Catalog — Design Note

Status: DRAFT v0.1 · 2026-09-24
Related: `NIH_PLAN.md` (§2 Tier 0, backlog item 5), `YAMAARASHI_DESIGN.md` (Resource effect,
streams), `HASHIGAKARI_DESIGN.md` (§3.4 execution), `Haskell Algebraic Effects Pattern
Names.md` (source patterns), `HERMES_DESIGN.md` (compat contract, trust model)
Audience: future maintainers and contributors; assumes familiarity with Haskell GADTs but
not with any particular effect system.

---

## 1. Purpose

This note fixes the design of `sarutahiko-effect-signatures` — the **catalog**: the single,
neutral vocabulary of algebraic effect signatures shared by every package in the program.
It explains the concept from first principles, states the catalog-wide rules, enumerates the
catalog, and records six design improvements that were explicitly blessed by the maintainer
(five adopted; one — the PVP-for-signatures policy — spelled out in §6.5 pending final
blessing). It exists because the catalog is the load-bearing abstraction of the whole
program: errors here propagate to every layer above the substrate.

## 2. Effect signatures from first principles

An effect signature is a **GADT that reifies operations as data** — the deep-embedding /
operational pattern (`Haskell Algebraic Effects Pattern Names.md`):

```haskell
data FileSystem (m :: Type -> Type) :: Type -> Type where
  ReadFile  :: FilePath        -> FileSystem m ByteString
  WriteFile :: FilePath -> ByteString -> FileSystem m ()
```

Three separable pieces:

1. **The GADT** — the *syntax* of an effect: what can be requested. Return types are
   precisely indexed (`ReadFile` yields `ByteString`), which is what makes programs total
   and self-documenting.
2. **The effect row** — an extensible *variant* (open sum) of signatures. A program is
   `Eff es a` where `es` is a type-level list of signatures; `send` injects one signature's
   operation into the ambient row; constraints like `FileSystem :> es` say "this effect is
   available somewhere in the row", with order-independence. The structural duality with
   our record foundation is exact and deliberate: **records are open products, effect rows
   are open sums** — the same mathematics pointed in opposite directions. This is why the
   program treats them as one substrate.
3. **Handlers** — the *semantics*, swappable per interpreter: real filesystem in production,
   in-memory map in tests, replay in property tests. "Test interpreters replace mocking
   frameworks" is the practical payoff.

A program written against signatures performs no I/O itself; it emits requests, and the
handler stack at the executable's edge gives them meaning. Policy, dry-run, replay, and
audit become *alternative handler stacks over the same program* (NIH_PLAN, "the turn is a
value in `Eff es`").

## 3. Why a catalog rather than ad hoc signatures

Three failure modes motivate central curation:

- **The N² vocabulary problem.** If every package defines its own `Logger`, `Clock`,
  `Resource`, the codebase fills with adapter functions between them. The catalog defines
  each vocabulary item exactly once — **signatures are to effects what fields are to rows**
  (compare `sarutahiko-fields`).
- **Neutrality.** The program's dual-interface decision (NIH_PLAN §0: effectful for our
  executables; polysemy supported) requires that domain code never name a concrete effect
  system. The catalog package contains *only* GADTs, laws, and a tiny reference runtime —
  no effectful, no polysemy dependency. Production senders and interpreters live in the
  bridge packages.
- **The contract surface.** Plugins, tools, surfaces, and external interop (the keiro
  contact points) all speak through these signatures. A stable, versioned catalog is the
  compatibility contract everything above the substrate compiles against.

Precedent: `~/src/kuroko/` is the minimal version of exactly this — its three effect groups
(`LLM`, `Tool`, `Store`) are a three-entry catalog that carries a complete agent in ≈1k core
lines. The catalog is the industrialization of that observation.

## 4. Anatomy of a catalog entry

Every entry consists of five things:

1. **The GADT**, `data Sig (m :: Type -> Type) :: Type -> Type`. The `m` parameter enables
   higher-order operations (operations that take computations as arguments).
2. **Senders** — thin typed wrappers per bridge (`append :: SessionStore :> es => EventRow
   -> Eff es EventId`). Kept trivial by construction; correctness is enforced by the
   testkit, not by review.
3. **Laws** — properties every interpreter must satisfy. Examples: `Resource` releases
   exactly once, on success, error, short-circuit, and async exception; `SessionStore`
   reads observe prior appends, ids monotone; `Log` makes *no* cross-thread ordering
   promise. **Documenting the absence of a law is catalog content**: an unstated ordering
   assumption is a future deadlock.
4. **At least two interpreters** — one production, one pure model — plus the parity test
   that both obey the laws (§6.6).
5. **Scope exclusions** — what the signature deliberately does *not* cover. This is what
   keeps entries orthogonal; the alternative is god-effects that accrete surface.

Two structural rules run through the whole catalog:

- **Cursors, not streams: canonical `Stepper m a`.** Signatures never expose stream
  types (that would invert the dependency on `yamaarashi`) and never parameterize over a
  concrete `Eff` row (that would break neutrality). All sequential traversal handles
  across the catalog, database, and model layers are unified under one canonical
  existential stepper GADT parameterized by `m`:

  ```haskell
  data Stepper m a where
    Stepper :: st
            -> (st -> m (Maybe (a, st)))   -- step: Nothing = exhaustion / terminal reached
            -> (st -> m ())               -- close: deterministic teardown
            -> Stepper m a
  ```

  Example signature usage:

  ```haskell
  data SessionStore (m :: Type -> Type) :: Type -> Type where
    Append    :: EventRow -> SessionStore m EventId
    ReadRange :: EventId -> EventId -> SessionStore m [EventRow]
    Subscribe :: SessionStore m (Stepper m EventRow)
    Current   :: SessionStore m EventId
  ```

  The `yamaarashi` stream kernel unfolds any `Stepper m a` into `Stream (Of a) m ()`; the
  `Resource`/`Scoped` effect guarantees that `close` runs on stream short-circuit or error.
  This GADT unifies the former `Subscription m` in this catalog, the `Cursor` stepper
  in `HASHIGAKARI_DESIGN.md` §3.4, and `EventCursor m` in `LLM_SUBSTRATE_DESIGN.md` §2.
- **`SomeRow` for row-carrying effects.** `Log`, `EventBus`, and `HookDispatch` carry
  record *values*. If the row appeared in the program's type, every log call would change
  the ambient constraints. Call sites therefore build a concrete row and pass an
  existentially packaged `SomeRow` (a `Record f r` existentially quantified over `r`, with
  a schema tag); a statically-typed "channel" variant remains opt-in for hot paths.

### First-order vs higher-order, and `Scoped`

Operations returning values (`ReadFile`) are first-order; operations taking computations
(`Transaction`, `bracket`) are higher-order, and are where effect systems differ most in
ergonomics. The catalog collapses the recurring higher-order shape into **one pattern**:
`Scoped` — open a region, run a computation, guarantee teardown. Transaction scopes,
resource brackets, cursor lifetimes, and hook-handler regions are all specializations
(§6.3).

### The reference runtime

The catalog ships a tiny free-monad `Eff` used for law tests and documentation examples —
not for production. Production senders/interpreters live in the bridges
(`sarutahiko-effects-effectful`, `sarutahiko-effects-polysemy`); the reference runtime
doubles as the substrate for the pure model interpreters. Sender 3-liners are duplicated
per bridge by design and held honest by the parity testkit.

## 5. The catalog

| Signature | Core operations | Notes |
|---|---|---|
| `Resource`/`Scoped` | bracket, allocate, region | foundation; all teardown routes here |
| `Log` | `log :: SomeRow -> m ()` | severity/namespace are fields of the row; OTLP-shaped attributes |
| `Clock` | now, sleep, deadline | timeouts = `Clock` + `Resource` |
| `Process` | spawn (stdio), wait, kill | Resource-bracketed; the Phase-1 minimal subset (MCP children) |
| `Supervise` | restart trees, deadline-kill, child-env hygiene | shibuya-class layering; composes `Process`, never grows it |
| `FileSystem` | read/write/glob, `Watch` (a `Stepper m FileEvent`) | — |
| `Database` | Query, Stream (cursor), Execute, Transaction | per `HASHIGAKARI_DESIGN.md` §3.4, normalized to `m` |
| `SessionStore` | Append, ReadRange, Subscribe, Current | the memory engine's entire I/O surface; reducers stay pure |
| `ModelAPI` | complete, stream (row events), embed, count | baikai-analog; function-calling schemas as row descriptors |
| `Tools` | dispatch by name + args-row, schema lookup, grants | one registry, many surfaces |
| `HookDispatch` | register, run (bounded, fail-closed) | payloads are `SomeRow`s; additive evolution = row extension |
| `Config` | layered read, resolved-row access | row-union merge per NIH_PLAN Tier 2 |
| `EventBus` | publish, subscribe (namespaced topics) | gateway/platform events |
| `Terminal`/`UI` | render frames, read events | the TUI projection's effect; agent core never sees it |

`Error`, `Reader`, `State` remain upstream-provided per system; domain signatures never
embed concrete primitive effects — interpreters translate. Layering rule for growth:
**compose signatures at interpreter level** (e.g. `Supervise` over `Process`); do not grow
GADTs to absorb other signatures' concerns.

## 6. The six design improvements (blessed)

### 6.1 Capability rows — grants as parametricity

**Problem.** Hermes enforces plugin capability at runtime: allowlists, `has_capability()`
checks, fail-closed gates. Runtime checks are code, and code can be forgotten.

**Decision.** Make the effect row itself the capability set. A plugin receives a rank-2
computation:

```haskell
registerPlugin :: ∀ es. Plugin es => PluginDef es  -- Plugin es constrains WHICH effects
-- concretely:
runPlugin :: (∀ es. Granted :<: es => Eff es ()) -> Eff es ()
```

Inside the rank-2 wrapper, the plugin can only name effects the grantor put in the row —
in *any* ambient row, by parametricity. Enforcement is compile-time; audit is reading a
type; a class of policy code dies.

**Soundness obligations** (what the implementation must get right):

- The grantor never exposes `IOE`/primitive effects through granted rows.
- Higher-order operations must not provide an escape hatch: no granted effect may accept an
  `Eff es'` computation and run it in a *richer* row than the plugin was granted. Audited
  per signature at catalog-review time; the testkit includes an escape-attempt suite.
- **The security argument is a parametricity theorem** and is recorded as such: a written
  proof sketch (the free-theorem-style obligation that a rank-2 `∀ es. Granted :<: es =>
  Eff es ()` consumer cannot name effects outside `Granted`, under the interpreter's
  operational semantics) lives in this note's §6.1 follow-up, with the escape-attempt
  suite as its empirical check — not its replacement (INFRASTRUCTURE §5.2 tier 1).
- Runtime gates that are *UX* rather than capability (per-call consent prompts for shell
  hooks, TTY approval) remain runtime — they need human input, not type safety.

**Replaces:** `mcp_allowlist`-style allowlist plumbing for plugin code paths.

### 6.2 Handlers as extensible records

**Problem.** Each bridge hand-writes interpreter plumbing per system, and the records/effects
duality — the intellectual core of the program — stops at the type level.

**Decision.** Make interpreters *literal* record values: an interpreter is a record of
handler functions keyed by signature; handler fragments compose by record merge (row union
with conflict detection) exactly like data rows. The dual-interface promise then costs
almost nothing: the same fragment set, two mechanical materializations (effectful handlers,
polysemy interpreters).

**Status/boundary.** Blessed as design intent, subject to the **Phase 0 Handlers-as-Records
Spike Protocol**. The spike evaluates whether row composition of handlers is viable
against both systems' native internal representation:

1. **`effectful` Target:** Dynamic handlers wrap operations in an unlifted environment
   (`interpret :: (∀ es' a. sig (Eff es') a -> Eff es a) -> Eff (sig : es) b -> Eff es b`).
   The spike tests whether a record of handler functions `Record (HandlerEff es) sigs`
   can be folded into a composed handler without per-call dictionary boxing or dynamic
   type lookup overhead.
2. **`polysemy` Target:** Higher-order operations use `Tactics` and `Weaving`. The spike
   tests whether record fields can cleanly instantiate `interpretH` while preserving
   higher-order state distribution.
3. **Evaluation Criteria:**
   - *Ergonomics:* Does `h1 ⊕ h2` (record merge) produce an interpreter without manual
     type annotations at call sites?
   - *Performance:* Does GHC's optimizer inline the record projections, matching the
     microbenchmark throughput of handwritten interpreters?
   - *Totality:* Does omitting a handler for a signature in the row produce a clear,
     localized compile-time `TypeError`?
4. **Fallback Path:** If either system's internal machinery resists clean record
   composition, **fall back immediately to handwritten interpreters per system**
   (`runFileSystemEffectful`, `runFileSystemPolysemy`). Handlers-as-records is then
   retained as documentation of the duality rather than blocking bridge implementation.

### 6.3 `Scoped` unification

**Problem.** Brackets, transactions, cursor lifetimes, and hook-handler regions are four
spellings of one shape: *open a region, run a computation, guarantee teardown*. Four
spellings means four sets of laws and four chances to leak.

**Decision.** One canonical higher-order pattern in the catalog:

```haskell
data Scoped (m :: Type -> Type) :: Type -> Type where
  Region :: ResourceKey -> m ()           -- finalizer
         -> m a -> Scoped m a             -- body, always finalized
```

`Transaction`, cursor scopes, and hook regions become specializations (thin senders over
`Region` with backend keys). One law set: finalizer runs exactly once, on every exit path,
in LIFO order; regions may nest; async exceptions are respected.

### 6.4 `SomeRow` packaging

**Problem.** Row-carrying effects would, if typed naively, put the row in the program's
type: every `log r` would alter the ambient constraints — unusable.

**Decision.** The catalog standardizes the existential wrapper: `SomeRow` packages a
`Record f r` existentially over `r` with a schema tag; effects receive `SomeRow`s; call
sites build concrete rows and package them. A statically-typed channel variant (row visible
in the type) remains opt-in for hot paths. Small rule, felt everywhere.

### 6.5 PVP-for-signatures — evolution policy (proposed)

**The acronym.** PVP = the Haskell **Package Versioning Policy** (`pvp.haskell.org`):
versions `A.B.C.D`, where A.B bump on *breaking* API changes, C.D on additions/patches
(the summary is quoted in `sarutahiko.cabal`'s comments).

**The problem.** PVP's categories assume the *records* half of our duality and mislead on
the *variants* half. Adding a field to a row is genuinely non-breaking — old consumers
ignore it. But a signature is an open **sum**, and interpreters are *total pattern matches*
over its constructors: adding a GADT constructor is "additive" in the data sense yet
**breaking for every closed handler downstream** (the interpreter stops being exhaustive).
A naive minor bump ships breakage disguised as a patch.

**The policy.**

| Change | Who breaks | Version action |
|---|---|---|
| Add an *operation* to an existing signature GADT | interpreter authors (totality) | leading-component bump, **or** prefer the additive route below |
| Add a *new signature* + a reinterpretation into existing effects | nobody | minor bump — the preferred evolution path |
| Add a sender / clarify a law | nobody | minor bump |
| Retype or remove a constructor | everyone | leading bump + deprecation window (≥2 minor releases, mirroring Hermes' compat contract) |

The **additive route** is the Haskell-specific move that makes growth cheap: instead of
growing a GADT, add a new small signature plus an interpreter that re-expresses it in terms
of the existing ones. Nothing closed breaks; convenience constructors merge later across
the window. Effect systems make interpretation layering native composition, so this route
is usually *less* work than editing the GADT.

Detection stays mechanical: `-Wincomplete-patterns` in both bridges plus the testkit's
parity suite turn "you broke the interpreters" into a red CI badge rather than a downstream
surprise. This policy is Hermes' additive-payload/cache-safe-evolution discipline
transposed from hook payloads (rows — data) to signatures (variants — syntax): the two
halves of the duality have the same evolution problem with opposite costs, and both get an
explicit answer.

**Status:** blessed by the maintainer (2026-09-24).

### 6.6 The law testkit

**Problem.** The dual-interface promise (every signature interpretable under effectful
*and* polysemy, forever) needs an enforcement mechanism cheaper than vigilance.

**Decision.** `sarutahiko-effect-testkit`: a generic property harness each signature
instantiates with (a) its laws, (b) a pure model interpreter, (c) operation scenarios.
CI runs every signature's laws against *both* bridges' interpreters — the parity gate from
NIH_PLAN §4 ("every new signature lands in both interpreter packages in the same PR, or the
PR does not land" becomes checkable rather than aspirational). Also hosts the escape-attempt
suite for §6.1.

## 7. Package layout consequences

| Package | Contains |
|---|---|
| `sarutahiko-effect-signatures` | GADTs, senders' *types*, laws (as properties + docs), `SomeRow`, `Scoped`, reference runtime. Zero system dependencies. |
| `sarutahiko-effects-effectful` | senders + production interpreters (effectful) |
| `sarutahiko-effects-polysemy` | senders + interpreters (polysemy) |
| `sarutahiko-effect-testkit` | the property harness; CI parity gate; escape-attempt suite |

## 8. Non-goals

- No third effect-system bridge until a real consumer demands one (the interface packages
  exist precisely so this is additive later).
- No monad-translator compatibility shims; the rows are the composition mechanism.
- No capability *revocation* at runtime for in-process plugins (grant structure is fixed at
  registration; processes and allowlists still exist at the edges for foreign code).

## 9. Remaining open items

1. Handlers-as-records spike against both systems (§6.2) — gates the bridge packages.
2. Capability-row soundness proof obligations worked into the testkit's escape suite (§6.1).
3. ~~Final blessing of the PVP-for-signatures policy (§6.5).~~ Blessed 2026-09-24.
4. Exact `Database` signature refinement with hasql/sqlite interpreter sketches
   (`HASHIGAKARI_DESIGN.md` §3.4 normalization to this note's rules).
