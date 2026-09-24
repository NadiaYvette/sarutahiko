# The Fields & Records Layer — Design Note (working: `sarutahiko-fields` / `sarutahiko-records`)

Status: DRAFT v0.1 · 2026-09-24 — §1 (the row-evolution standard, decision 3) drafted
for maintainer review; remaining sections open per §0's decision order
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

*Pending; writes against §1.4's contract. Candidates on the table: `Identity`
(concrete rows), `Const`-composition (projections), `TriState` (CA1's three states),
`Column` (hashigakari nullability). The fork's `Record f r` is natively
functor-parameterized (`Data/Record/Anon/Internal/Advanced.hs`), so this section
blesses the family and its laws, not the mechanism.*

## 3. The field datum and registry model (decision 1) — satisfies CD1–CD2

*Pending; scoped by §1–§2. The note's centerpiece: field-as-first-class-datum
(name, type, CD1 metadata), registry model, large-anon plugin interaction.*

## 4. Unknown-field preservation (decision 4)

*Pending; constrained by E3/E4. The binary: preserved in the row representation
(spurious-fields map beside typed columns) vs. in the serialization layer only.
Decider: the kakegoe canonicalization interaction — whether unknown fields are
hashed (deterministically) or excluded from hashes.*

## 5. Combinator laws (decision 6)

*Pending. Inherited in part from large-anon's `Diff` core; the new element is
`merge`'s associativity/override semantics, chosen against kogaki's CLDR
inheritance consumer (root ⊕ lang ⊕ region, later-override-wins).*

## 6. Decoder recipes (decision 7)

*Pending. Per-field codecs composed per-row; canonical-JSON form; error taxonomy
seeded from CODEC_QUIRKS CONFIRMED rows. The "Nth codec is a field list plus a
recipe" economics claim's mechanism.*

## 7. Compile-time economics (decision 8)

*Pending. Custom `TypeError` messaging, row-diff debugging utilities (built above
the foundation per register 2.1), the small-rows style rule; policed by the nightly
compile-time ledger.*
