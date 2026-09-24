# Project Infrastructure — Standing Decisions and Procedure

Status: v0.1 (FIRST CUT — blessed as a start 2026-09-24; maintainer review pending on
items 1–6, items 7–12 are draft defaults amendable in review)
Related: `NIH_PLAN.md` (§4 ledger, §6.5 PVP-for-signatures), `EFFECT_CATALOG_DESIGN.md`
(§6.6 testkit parity gate), `YAMAARASHI_DESIGN.md` (§6 kernel dependency budget),
`MEMORY_ENGINE_DESIGN.md` (§3.4 SQL-lint mandate), `INSTRUMENTS_SPEC.md` (kakegoe),
`CODEC_QUIRKS.md` (fixture conformance), `REUSE_REGISTER.md`
Role: the counterpart to the reuse register — infrastructure decisions get a row here,
with reasoning and revisit triggers, so tooling questions are answered once.

---

## 1. Toolchain policy (amended 2026-09-24: hypermodern)

- **Stance: hypermodern, by explicit maintainer decision.** Track the latest stable
  toolchain — GHC 9.14 and cabal 3.18.x at the time of writing — and spend **no effort
  on backward compatibility with elder toolchains** (this amends the drafted 9.10+
  support window; the draft's single-back-version aspiration is dropped). The theme of
  the project — re-grounding coverage in the most advanced design principles — is
  inconsistent with dragging elder-compiler legs.
- **Language edition: GHC2024** (`sarutahiko.cabal`'s commons bump from GHC2021 lands
  with the first Tier-0 code). The catalog's GADT/row style assumes it.
- **Language features:** the maintainer's working set — `BlockArguments`,
  `LambdaCase`, `ScopedTypeVariables`, and `PartialTypeSignatures` within the
  development process. `ScopedTypeVariables` (and `LambdaCase`) ride in the GHC2024
  baseline; `BlockArguments` and `PartialTypeSignatures` are explicit opt-ins in the
  commons, the latter governed by `-Wpartial-type-signatures` so unresolved holes
  surface before shipping (dev convenience, not shipped sloppiness). The style leans
  on new-GHC features as they stabilize (e.g. or-patterns when the pinned GHC ships
  them) — the commons are the single place feature flags live.
- **Reproducibility:** a checked-in `cabal.project.freeze` against the pinned
  compiler; `cabal.project` lists local packages explicitly as the tree grows.
- **Support window: latest stable, period.** CI runs the single pinned compiler (no
  back-compat matrix legs). The forward-ported large-* stack is ours, so latest-GHC
  compatibility is maintainable by construction. Revisit trigger: a critical
  dependency lacking latest-GHC support ⇒ temporary pin-back (recorded here, never a
  fork); ghcup makes the pin a one-line change. Nix flakes remain optional per-repo
  (baikai-style), never program-mandatory.

## 2. Formatting — brittany (amended 2026-09-24; fourmolu draft superseded)

- **`brittany`**, enforced as `brittany --check` in CI, applied in place locally; no
  commit hooks (CI is authoritative; hooks rot). `cabal-fmt --check` for `.cabal` files
  in the same CI job.
- **Rationale (maintainer):** aesthetic preference for brittany's output over
  fourmolu's, *plus* an unusually strong provenance position: the maintainer has a
  42-commit series in `~/src/brittany` ahead of the (stale) lspitzner upstream —
  GHC 9.14 extension/layout support, extensive comment-handling repairs, test-suite
  modernization — and a close relationship with the new package maintainer who adopted
  brittany and included that series. Formatting adjustments we need can flow upstream,
  which is the same relationship the doctrine gives hlint.
- **Trade-offs, honestly stated** (the fourmolu draft's case, kept for the register):
  fourmolu's advantage is *predictability* — a single opinionated style, zero-config by
  philosophy, the de-facto ecosystem default (arena/baikai ship fourmolu.yaml), so
  external contributors meet no surprises; brittany's advantages are *expressiveness*
  (it makes intelligent use of horizontal space and alignment rather than forcing one
  canonical layout — the aesthetic the maintainer prefers) and *comment fidelity*
  (retains newlines/comments where they were, a real property for a codebase dense with
  law annotations). brittany's historical risks — the old README's "effectively
  unmaintained" banner and GHC-API coupling — are directly addressed by the maintainer's
  series (GHC 9.14 support now in the fork) and by the upstream relationship; the fork
  is 42 ahead / 0 behind, and Hackage's latest is 0.14.0.2.
- **Condition of adoption:** the CI formatter is the *new upstream*
  (`github.com/xwinus/brittany`, the adopting maintainer — Vaclav Svejcar — with 161
  commits of active development beyond the stale lspitzner master, including the
  maintainer's 42-commit series, now fully merged and verified contained), pinned by
  commit; the pin moves to its Hackage releases as they land. Revisit trigger: brittany
  failing to format a GHC feature we adopt (or-patterns etc.) faster than we can extend
  it upstream.
- Register: REUSE_REGISTER gains a brittany row (2.16) — reuse-with-upstreaming,
  distinct from 2.4/2.13 (engine reuse) because here we carry the development weight.
  hlint (2.17): reuse with rule patching, same pattern.

## 3. Linting

- `hlint` with a checked-in `.hlint.yaml` for deliberate ignores (each ignore carries a
  comment saying why).
- `cabal check` (and later `weeder`) in CI: weeder matters here because the layering
  discipline makes dead exports a design smell, not just tidiness.
- **Custom lints (the design-mandated ones), as CI jobs:**
  - *SQL-lint*: any log query ordering by anything other than `(session, seq)` fails
    (MEMORY_ENGINE §3.4 enforcement).
  - *Parity lint*: every effect signature's interpreters exist in both bridge packages;
    a signature added to one without the other fails the build (EFFECT_CATALOG §6.6's
    gate, mechanically).
  - *Layer lint*: package dependency directions must match NIH_PLAN §2's tier graph
    (checked via the explicit `cabal.project` package list + build-depends audit).

## 4. Warning-freedom

- Baseline in the cabal commons: `-Wall -Widentities` (present) plus
  `-Wincomplete-uni-patterns -Wincomplete-record-updates -Wmissing-deriving-strategies`.
- `-Wall` includes `-Wincomplete-patterns`, which is **load-bearing** for the
  PVP-for-signatures policy (total interpreter matches are the compat mechanism) — the
  commons carry a comment saying exactly that, so nobody "cleans up" the flags.
- `-Werror` only on the pinned CI GHC version, never locally, never on the floating
  matrix entries (new GHC warnings must not break contributor builds).

## 5. Testing stack — tasty + hedgehog + tasty-golden, three tiers

- **Runner: tasty** (composes property/golden/unit under one entry point).
- **Property: hedgehog** (integrated shrinking via Applicative — no hand-written
  shrinkers for our deep row/GADT data), **QuickCheck permitted where interop demands**
  — and interop pull is strong: typed-protocols, io-classes/io-sim, and the Cardano
  test machinery are QuickCheck-based. One *runner* is the invariant; both engines may
  sit behind it.
- **Golden: tasty-golden** (renderer bytes per family×version, golden SQL per dialect,
  quirk fixtures). **Benchmarks: tasty-bench** (same runner invariant).
- **Concurrency testing: io-sim** (deterministic scheduler from the io-classes stack —
  agent turns, supervision restarts, and yamaarashi strategies run under reproducible
  schedules; races become fixtures), dejafu as the alternative exploration engine.
- **Engines:** tmp-postgres for real-Postgres dialect-parity tests (C5); temp-dir
  SQLite; recording interpreters/transcript fixtures replace HTTP-mocking libraries
  by design (none admitted).

### 5.1 Tiers — macro testing is distinct from unit testing, structurally

Separate cabal test-suites per tier so CI selects them:

- **`test:unit`** — pure functions, codecs, reducers, witness dispatch, type-level
  machinery. Fast; every push, every matrix leg.
- **`test:macro`** — a layer with real collaborators in a controlled environment:
  hokora turn under mock model + in-process tool + real SQLite; dual-effect parity;
  dialect parity on real engines; codec suites against transcript fixtures. The
  hokora's *mock ≠ skip a layer* rule is this tier's boundary rule.
- **`test:e2e`** — full fidelity: hokora live run (real MCP subprocess + local-CLI or
  real provider + real store), conformance against upstream implementations,
  replay-from-crash. Smoke on push; full on nightly alongside the kakegoe sweeps
  (which are measurement, not assertion — §11).

### 5.2 Formal verification — a separate axis, employed surgically

Scope note: this document holds strategy and rationale; *per-component* test and
verification plans (which properties for the log, which for codecs, which for the turn
program) live in the component design notes and the roadmap — e.g. MEMORY_ENGINE §5's
property list, HOKORA_SPEC's exit criteria, the catalog's per-signature laws.

Verification (proofs over all inputs) is distinct from testing (sampling) — but Haskell
blurs the boundary, so the policy is a four-step spectrum with a surgical rule:

1. **Type-level verification (free, pervasive):** GADT state indices, `PolicyEffect`
   phantoms, `Scoped` regions, capability rows. The capability-row grant's security
   argument *is a parametricity theorem* — the catalog note must carry a written proof
   sketch, with the escape-attempt suite as its empirical check, not its replacement.
2. **Property laws (the workhorse):** L1–L4, C5, replay identity — universal claims,
   sampled.
3. **Liquid Haskell refinements (pragmatic middle, opportunistic):** log/cursor
   invariants (`seq` monotonicity, cursor bounds, dispatch totality) when that layer
   exists.
4. **Model checking / deduction (heavyweight, two named targets):** a TLA+/PlusCal
   spec of the MCP handshake (or inherited Agda proofs — which count double in the
   typed-protocols adoption decision) and of the `Supervise` restart/kill-timeout
   policy — the timing/interleaving properties sampling is weakest at. **Tooling:**
   nothing in-tree and nothing NIH'd — TLA+/PlusCal sources in `spec/`, checked with
   TLC (`tla2tools` jar + a JRE) or Apalache (symbolic/SMT checker, available locally
   at `~/src/apalache`); spec invariants are then mirrored as hedgehog properties so
   the proof artifact and the CI artifact agree. Liquid Haskell (clone at
   `~/src/liquidhaskell/`, as-needed): its GHC-plugin cost begins only when the first
   refinements land; adopt-time check that the release supports the pinned GHC
   (hypermodern rule applies). TLA+ tooling confirmed locally: `~/src/tlaplus/` (TLC,
   the explicit-state checker — jar + JRE) and `~/src/apalache/` (symbolic/SMT); both
   external tools over `spec/` sources, nothing in-tree.

Most of the program stays property-tested: codec/row/glue/reducer code is where the
type discipline plus laws already suffice, and full verification there is ceremony.
Meaningful verification concentrates exactly where sampling is weakest: interleaving,
timing, resource guarantees, protocol deadlocks.

### 5.3 Alternatives considered — the rationale ledger

Recorded so the comparisons stay answered (same discipline as the reuse register).

**Runners.** *Hspec* — BDD DSL (`describe`/`it`) in its own `SpecM`; ubiquitous and
readable; but integrating other test kinds needs adapter packages
(hspec-hedgehog/golden), eroding the one-runner invariant at each seam. *tasty* — a
framework of frameworks: one `TestTree`, providers lift into it (hunit, hedgehog,
quickcheck, golden, bench, doctest), and an **ingredient** system controls execution
(workers, timeouts, `-p` per-test pattern selection — which is also how the §5.1 tiers
are selectable). *sydtest* — the modern dark horse: parallel-safe **resource
composition** (fresh resources per test via setup functions), built-in webserver and
process-spawn testing, native QuickCheck *and* hedgehog support; costs are the smaller
community and the pull toward its validity-family ecosystem. Its differentiators
overlap what we build anyway (`Process` effect + testkit interpreters *are* a resource
model). **Choice: tasty.** Revisit sydtest if e2e ergonomics chafe.

**Property engines.** *QuickCheck* (the 2000 original): `Arbitrary` class with explicit
generators **and explicit per-type shrink functions** — the crux: neglected shrinkers
(`shrink = const []` defaults) fail to minimize failures on deep types, and our types
(`SomePayload` existentials, wide rows, witness GADTs) are the hard case. Also its
unmatched asset: 25 years of ecosystem — `Arbitrary` instances in dependencies,
state-machine testing (quickcheck-state-machine, IOG's fork), and the IOG test
machinery we interop with. *Hedgehog*: **integrated shrinking** — generators are
Applicative-structured and the shrink tree is derived from the generator, so structural
shrinking is free; no hand-written shrinkers ever; costs are no `Arbitrary` interop
(bridged via `Hedgehog.QuickCheck`), smaller instance ecosystem, and the QC-side
state-machine center of gravity. *genvalidity*: derivable QuickCheck generators with
systematic invalid-data production (good for parser round-trips); drags the validity
family; doesn't fix shrinking. *leancheck*: enumerative (`Listable`, deterministic,
enumeration order = shrink order); elegant for small closed types, combinatorially
hopeless for wide/recursive data. **Choice: hedgehog for our types; `Hedgehog.QuickCheck`
adapters where IOG machinery wants `Gen`; QuickCheck-native suites where a dependency's
conformance suite is QC-shaped.**

**Concurrency testing.** *dejafu* — systematic interleaving exploration (bounded
systematic, random, round-robin schedules) over an instrumented `ConcT` monad; strong
coverage guarantees, heavy re-execution cost, slowed development. *io-sim* (io-classes
stack) — a **drop-in simulated IO monad with a deterministic scheduler and virtual
time** (the clock advances when all threads block ⇒ timeout/timer tests run instantly
and deterministically); typed-protocols drivers run on it directly; recent versions add
automatic race exploration (`exploreRaces`); traces are reproducible fixtures. Its
interface discipline (code against `io-classes`, not raw IO) is *not a tax here* — it
is the dual-interface doctrine applied to time and concurrency: `Clock`/`Process`/
`Supervise` interpreters get real-IO and io-sim instances, the same turn program under
both. **Choice: io-sim** (also the practical harness for the §5.2 tier-4 properties —
deterministic schedules now, TLA+ proofs alongside). dejafu noted as the alternative
for raw-IO code we decline to interface-discipline.

**Database engines in tests.** *tmp-postgres* — a real Postgres (initdb in a temp dir,
ephemeral port) per suite; cost is initdb seconds + CI binary availability, mitigated
by its cluster-cache (initdb once, clone per test). *Service containers* (CI
`services:`) — same engine, deployment-realistic, but break hermetic local runs.
*Temp-dir SQLite* — instant/hermetic but the *other* dialect; cannot catch
Postgres-specific behavior (rollback sequence gaps, MVCC edges). **Strategy: SQLite
temp-dir in `test:unit` (fast, hermetic); the C5 dialect-parity macro property runs
both engines — SQLite always, real Postgres via tmp-postgres in CI (cluster-cached),
service container optionally for nightly full runs.**

**HTTP mocking — none, by design.** Our codecs consume byte streams below the layer
mocking libraries address; recorded transcript fixtures (kakegoe corpus format) *are*
the mocks — feeding recorded bytes through a codec is the test, and quirk rows point at
fixtures. If a Phase-3 surface needs server-level tests, `Network.Wai.Test`
(in-process WAI requests, no sockets) is the right tool at that layer — not an HTTP
mocking library.

**Benchmarks.** *criterion* — the statistical gold standard (bootstrapped CIs,
kernel-density reports); slow, runner-independent; retained as a *deep-dive*
investigation tool, not infrastructure. *gauge* — a criterion fork, cleaner internals,
same methodology; no differentiator for us. *tasty-bench* — criterion-quality
linear-regression measurement inside the tasty tree **with regression comparison
against previously recorded results** — which is the ledger integration exactly
(nightly runs compare against recorded bounds). **Choice: tasty-bench** (one-runner
invariant), and the role framing matters more than the tool: performance in this
program is achieved by *fundamental redesign and theory brought into practice*
(church-encoded O(1) binds, linear-time large-anon rows, io-sim determinism) —
benchmarks exist to validate that the theory landed (regression detection, design
confirmation), not to guide micro-tuning.

## 6. Documentation strategy (first-class)

Four layers, with enforcement:

1. **Haddock** — every exported symbol documented; *laws stated in haddock* (the
   catalog's per-entry law obligation lives here, not just in docs/); `cabal haddock`
   warnings treated as failures in CI (undocumented exports break the build, like
   warnings).
2. **The design-note corpus** (`docs/`) — conventions now written down as they have
   de facto operated: Status header with draft/blessed dates and reviewer; Related
   cross-references; the blessed-vs-proposed distinction; living documents with named
   review cadences (CODEC_QUIRKS at phase exits, REUSE_REGISTER on demand, this file);
   the **procedure**: design note → maintainer blessing (recorded with date) →
   implemented → haddock-maintained; designs flow down the mountain, code flows up.
3. **Per-package `CHANGELOG.md`** — PVP-tied (the blessed PVP-for-signatures policy
   requires the log to point at); updated in the same PR as the change.
4. **READMEs** — program-level in root; one-paragraph per package (name provenance
   included — the Noh naming is part of the documentation, per the registry).

## 7. CI/CD — GitHub Actions, push-mirrors stay push-only

- Host: GitHub Actions (the four mirrors + Radicle stay push-only; running CI on four
  hosts buys nothing). Reference workflow: typed-protocols' `haskell.yml` (IOG's
  setup-haskell actions; dependabot already in their tree — copy the shape).
- **Matrix:** single leg — the pinned latest-stable GHC (per §1's hypermodern
  stance) × {test:unit, test:macro, dual-effect parity}; test:e2e smoke on push,
  full on the nightly job.
- **Jobs:** lint (fourmolu --check, cabal-fmt --check, hlint, cabal check, weeder once
  packages exist), custom lints (SQL-lint, parity lint, layer lint), docs
  (`cabal haddock`), test matrix, **nightly benchmarks** writing to the ledger
  (kakegoe runtime metrics; the compile-time ledger job — fixed GHC, timing script,
  ≥40-column table — keeps the large-* advantage honest).
- **Mirroring:** `bin/push-all` checked in — `git push all master --follow-tags` plus
  `git push rad master`, the five-host fan-out as one command (the session's manual
  sequence, made procedural).
- Branch protection on `master` (status checks required) once the first CI run is green.

## 8. Versioning & releases

- PVP everywhere; PVP-for-signatures (§6.5) for the effect catalog; additive-via-new-
  signature as the default evolution route.
- Tags `v<pkg>-<version>` per package release, pushed with `--follow-tags` via
  `bin/push-all`; CHANGELOG entry in the same PR as the version bump.
- The program itself versions as one `sarutahiko` repo; package versions move
  independently per PVP.

## 9. Dependency hygiene

- Explicit PVP bounds on every dependency (the arena/baikai style).
- **Kernel dependency budget (hard rule):** `yamaarashi` and
  `sarutahiko-effect-signatures` depend on nothing beyond
  base/text/bytestring/containers (+ their own internals); enforced by review against
  the tier graph and the layer lint.
- Tier-labeled dependency additions: any new build-depends names its tier in the PR
  description; tier-0 additions are design events (this register gets a row).

## 10. Repo hygiene

- `.gitignore` (dist-newstyle, GHC artifacts) — present since the first commit.
- `hie.yaml` per package (gen-hie output checked in) so HLS works from clone.
- Secrets: environment variables only; never in tree, never in corpora (the
  scrub-manifest rule, INSTRUMENTS_SPEC §2.4, applies to all fixtures).
- `bin/` for procedural scripts (push-all; later: ledger queries, fixture tooling).

## 11. Benchmark & ledger infrastructure

- Runtime metrics: kakegoe's instruments (cache simulator, replay harness) — CI runs
  them nightly, the ledger records experiment manifests (re-runnable from manifest
  alone). Benchmarking stance (per §5.3): performance is earned by design and theory,
  so benchmarks validate designs (tasty-bench regression bounds) rather than tune
  implementations.
- Compile-time ledger: nightly job, pinned GHC, timing script over the wide-record
  fixture set (≥40-column table); regressions above the recorded bound fail the
  nightly.
- The ledger's home: a row-typed experiment store per INSTRUMENTS_SPEC §2.5, not
  ad-hoc files.

## 12. Procedure & prose rules

- **Commits:** descriptive-imperative subject; body explains the *why*; Codebuff
  footer per session convention; HEREDOC style for multi-line messages.
- **Pushing (amended 2026-09-24, hosting-resources policy):** commits are local and
  frequent; **pushes are batched** — at session end or on maintainer request, not
  after every commit. AI-assisted development that pushes per change overtaxes
  hosting services' network/CPU (a documented maintainer complaint); rate-limited
  hosts get cool-downs and at most one retry, never hammering. `bin/push-all` is the
  single fan-out point so batching is one command when it does happen.
- **Flow:** trunk-based `master`; solo PR-less but CI-gated; design review happens
  *in the notes* (adversarial questions and their resolutions are recorded in the
  documents — the docs are the institutional memory, not PR threads).
- **Register discipline:** every new tooling/dependency/infrastructure decision gets a
  row here (or in REUSE_REGISTER if it is a reuse question) before or with the change.

## 13. CI workflow skeleton (reference shape)

```yaml
name: CI
on: [push, pull_request]
jobs:
  lint:        # fourmolu --check; cabal-fmt --check; hlint; cabal check; custom lints
  docs:        # cabal haddock (warnings = failures)
  test:        # matrix: ghc {[9.10, 9.12]} × {core, dual-effect parity}
  nightly:     # scheduled: kakegoe metrics + compile-time ledger → ledger store
```

(Concrete action versions copied from typed-protocols' haskell.yml when the first
package exists; the skeleton pins intent, not versions.)

## 14. Open items

1. Maintainer review of items 1–6 (toolchain, fourmolu, lint set, warning set,
   tasty+hedgehog, docs strategy) — blessed as a start; amendments expected.
2. `sarutahiko.cabal` commons bump to GHC2024 + feature opt-ins (BlockArguments,
   PartialTypeSignatures) + warning additions — lands with the first Tier-0 code, not
   before (no code, no CI).
3. CI enablement timing: with the first real package (Phase 0), not with docs-only
   commits.
4. ~~Radicle CI note.~~ Decided: none — push-only by design; revisit only if Radicle
   gains a hosted-CI story worth the register's attention.
