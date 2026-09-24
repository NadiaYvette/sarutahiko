# Sarutahiko — NIH Replacement Plan for the Nadeem Bitar AI Coding Ecosystem, Hermes, and Supporting Software

Status: DRAFT v0.1 · 2026-09-23
Scope: a ground-up Haskell reimplementation ("NIH") of the substantial components of the
Nadeem Bitar AI coding ecosystem and of Hermes (per `HERMES_DESIGN.md`), plus the network
protocols, file formats, and supporting libraries they lean on, built on extensible records
(large-anon / large-records / vinyl interop), row-typed algebraic effects, and row-polymorphic
streaming pipelines. The greenfield database library concept from
`docs/Haskell Algebraic Effects Pattern Names-2.md` is folded in as its own workstream.

Sources consolidated by this plan:

- `docs/Haskell Algebraic Effects Pattern Names.md` and `-2.md` — the records × effects ×
  protocols × file formats × databases program (Gemini conversation, forward-ported
  porcupine/docrecords/record-soup, large-generics/large-records/large-anon ecosystem,
  vinyl interop).
- `docs/HERMES_DESIGN.md` — the component inventory being replaced: plugin system, execution
  surfaces, CLI structure, MCP/JSON-RPC embedding, TUI/gateway/ACP surfaces.
- `docs/hermes_components.dot` — the dependency graph to be re-homed package by package.
- `docs/Reimplementing Tree-sitter and Ctags in Haskell.md` — the code-intelligence workstream
  (incremental GLR parsing, tags indexing, RTS-friendly pure core).

---

## 0. Decisions already taken

| Decision | Choice | Consequence |
|---|---|---|
| Effect system for our executables | **effectful** | Executables use effectful; primop-backed Reader/State, fast, dynamic effect rows. |
| Effect interface packages | **Dual: effectful + polysemy** | Every support library ships an effects-interface package (effect-signature GADTs + per-system interpreters) so downstream users on either system can adopt. Signatures live in neutral core packages; interpreters live in per-system bridge packages. |
| First flagship | **Wire layer (JSON-RPC 2.0 + MCP)** | Proves records + effects on a real protocol, unblocks tool/MCP ecosystem work. |
| Streaming basis | **Deferred pending research gates** | See §3.5: evaluation matrix, candidate flaws, explicit NIH trigger conditions. The wire layer (first flagship) is independent of this decision — it needs only byte-chunk parsing over an abstract stream. |

## 1. Thesis

Every component in scope shares one structural pathology: closed nominal types (ADTs from
GHC.Generics or Template Haskell) modeling what are actually *open, row-shaped* things —
JSON-RPC envelopes, capability objects, plugin payloads, telemetry attributes, SQL rows,
config overlays. The replacement program is:

1. **Rows for data.** All wire shapes, config, telemetry, and query results are anonymous /
   extensible records (large-anon for linear-time wide records; vinyl interop at the edges;
   `rcast` projections instead of DTO conversions).
2. **Rows for effects.** Effect signatures are GADTs (per
   `Haskell Algebraic Effects Pattern Names.md`: effect signature / operational /
   defunctionalization patterns), composed in extensible-variant rows, dispatched by
   records-as-products × variants-as-sums duality.
3. **Streams between them.** Byte transport → row-parsing → routing → sinks as memory-constant
   pipelines whose elements are anonymous records, with the streaming basis chosen per §3.5.
4. **Capabilities at the edges, narrow-waist core** — the one Hermes design rule worth keeping
   verbatim (HERMES_DESIGN §2: prompt-cache safety, Footprint Ladder for core tools).

Non-goals: OS-level sandboxing parity (Hermes ships none; policy-over-sandbox carries over),
bitwise mimicry of upstream file layouts, and rewriting Dhall's internal evaluator (per the
doc's verdict — bridge package instead).

## 2. Target package map

Repo layout (cabal project `sarutahiko`, packages under `sarutahiko/` or a multi-package
cabal.project as it grows):

### Tier 0 — Foundation (records + effects kernels)

| Package | Contents | NIH-of / inspired-by |
|---|---|---|
| `sarutahiko-fields` | Named field definitions shared across rows (`Method`, `Id`, `Params`, tool/hook/session fields); row combinators: concat, project, rename, diff, merge. | the "define a field exactly once" idea from the records doc |
| `sarutahiko-records` | large-anon frontage + vinyl interop + record-soup/docrecords-derived serialization glue: FromJSON/ToJSON for rows, TriState HKD (RFC 7396 patch semantics), unknown-field preservation. | record-soup, docrecords, vinyl |
| `sarutahiko-effect-signatures` | Neutral effect-signature GADTs (no system dependency) + typed operation senders. Both effectful and polysemy interpreters compile against these. | effect signature pattern |
| `sarutahiko-effects-effectful` | effectful interpreters for all core signatures. | — |
| `sarutahiko-effects-polysemy` | polysemy interpreters for the same signatures (maintained, not load-bearing for our executables). | — |
| `yamaarashi` family | The hybrid streaming stack — kernel (`yamaarashi`), conduit and streamly backends (`yamaarashi-conduit`, `yamaarashi-streamly`), and DAG orchestration (`yamaarashi-flow`, porcupine re-homed). Designed in `YAMAARASHI_DESIGN.md`; Tier 0 depends only on the abstract kernel. | porcupine ArrowFlow semantics + conduit/streamly strengths unified |
| `sarutahiko-log` | Row-typed structured log/telemetry events (OTLP-shaped attributes as record fields, not `HashMap Text Value`). | OpenTelemetry concepts |

### Tier 1 — Wire (first flagship)

| Package | Contents | NIH-of |
|---|---|---|
| `sarutahiko-jsonrpc` | JSON-RPC 2.0 core: requests/notifications/responses as rows over `sarutahiko-fields`; open-variant method dispatch; batch; error taxonomy. | jsonrpc libs, haskell-lsp's substrate |
| `sarutahiko-mcp` | MCP over `sarutahiko-jsonrpc`: initialize handshake → capability rows (union/intersection instead of `Maybe`- forests), tools/list, tools/call, stdio + SSE/Streamable-HTTP transports. | Hermes `tools/mcp_tool_*`, pinned `2025-03-26` wire compat |
| `sarutahiko-lsp` | LSP on the same core; capabilities rows, `$/`-extension pass-through via row extension. | haskell-lsp / lsp |
| `sarutahiko-schema` | JSON Schema subset reader/writer (MCP `inputSchema` ⇄ internal row descriptors; no remote fetch at load, per Hermes behavior). | Hermes schema layer |

### Tier 2 — Agent core (Hermes replacement)

| Package | Contents | NIH-of |
|---|---|---|
| `sarutahiko-agent` | The turn loop, tool registry (one registry, many surfaces), toolsets, hooks with bounded/fail-closed `pre_tool_call` semantics, sessions. | `run_agent.py`, `agent/turn_*`, `tools/registry.py` |
| `sarutahiko-plugins` | Plugin system: manifest reading, discovery order, load deadlines, registration context as a *record effect* (register tools/hooks/commands by extending a row), capability grants, kill-list enforcement at install AND load. | `plugins_loader.py`, `plugins_dispatch.py`, PluginContext |
| `sarutahiko-hooks` | Shell-hook surface: stdin-JSON → stdout-JSON subprocess convention, consent allowlists, safe mode. | `agent/shell_hooks.py` |
| `sarutahiko-session` | Conversation/session persistence; prompt-cache-safe evolution rules; compression as the only sanctioned mid-conversation mutation. | `hermes_state*.py` |
| `sarutahiko-config` | Config as layered records: defaults ⊕ file ⊕ profile ⊕ env overlay with row-union merge; resolved-field tracking in the type. | `config*.py` siblings |
| `sarutahiko-model` | Model-provider profiles, streaming completion interface as an effect signature (SSE row events). | provider plugins, `model_*` |

### Tier 3 — Surfaces

| Package | Contents | NIH-of |
|---|---|---|
| `sarutahiko-cli` | Table-driven command registry (single source for help/autocomplete/dispatch), REPL, one-shot mode. | `cli.py` + mixins, `commands.py` |
| `sarutahiko-tui` | TUI backend speaking JSON-RPC to the core (same wire layer as everything else). | `tui_gateway/` |
| `sarutahiko-gateway` | Long-lived service runner, platform adapters as effect interpreters. | `gateway/` |
| `sarutahiko-acp` | ACP (Agent Client Protocol — Zed's editor↔agent protocol, JSON-RPC over stdio; Hermes' `acp_adapter/` surface) | `acp_adapter/` |

### Tier 4 — Code intelligence

| Package | Contents | NIH-of |
|---|---|---|
| `sarutahiko-parse` | Incremental GLR per Wagner–Graham: CST nodes as anonymous records of monoidal annotations; damage tracking via finger-tree/2-3 refold; subtree reuse; re-synchronization; error recovery. | tree-sitter |
| `sarutahiko-tags` | Shallow index extraction: FSM/regex opt-in per language, scope stack, then query-based extraction over `sarutahiko-parse` trees. | ctags / universal-ctags |

### Tier 5 — Data

The database access library is designed in `HASHIGAKARI_DESIGN.md` and named for the
hashigakari (橋掛かり), the bridge passageway onto the Noh stage (hashira 柱 held in
reserve as fallback):

| Package | Contents | NIH-of |
|---|---|---|
| `hashigakari-core` | Row-typed query AST (SELECT = row projection, JOIN = row concat with compile-time name-conflict rejection), column descriptors, HKD intents (`Record (Column f) r` / `Identity` / `TriState`), row combinators. | greenfield DSL from the records doc |
| `hashigakari-syntax` | Dialect-indexed SQL compilation with type-level portability ceilings. | — |
| `hashigakari-hasql` | hasql-backed execution + binary streaming of anonymous records, cursor declaration/FETCH. | — |
| `hashigakari-sqlite` | Direct SQLite execution (`sqlite3_step` stepper). | — |
| `hashigakari-beam` | The `beam-large-anon` bridge: `AnonTable (r :: Row Type) (f :: Type -> Type)` with hand-written `Beamable` bypassing GHC.Generics; standalone Hackage package. | beam retrofit idea |
| `hashigakari-patch` | TriState HKD rows (RFC 7396/6902), generic diff engine → minimal UPDATEs. | — |
| `hashigakari-schema` | Introspection → row types; migrations as row diffs. | — |
| `sarutahiko-format-*` | Format readers/writers on the row basis: Parquet/Arrow projection pushdown, CBOR/MessagePack open envelopes, TOML/YAML/HCL overlays, Dhall marshalling bridge (evaluator untouched), RFC 6902/7396. | file-format program from the doc |
| `sarutahiko-proto-*` | Remaining row-shaped protocols in demand order: GraphQL (selection sets as record projections; fragments = row concat), CloudEvents (envelope + extension-attribute rows), OTLP spans, system IPC (D-Bus, Wayland, 9P) as open rows of signals/methods. | protocol program from the doc |

Everything above Tier 0 depends on `sarutahiko-effect-signatures`, never on a concrete effect
system; only executables depend on `sarutahiko-effects-effectful`.

### From substrate to ecosystem — the remaining climb

The five substrate bags — (1) extensible-record network protocol codecs, (2) extensible-record
file format codecs, (3) `yamaarashi`, (4) `hashigakari`, (5) the large-*/vinyl record
foundation — move and store rows but have no behavior. Note (1) and (2) are really *one* bag
with two spouts: both are field dictionaries + generic codecs + envelope preservation over the
same `sarutahiko-fields` vocabulary, so the marginal cost of the Nth codec is a field list and
a decoder recipe, not a new serializer. The climb to the Nadeem Bitar / Hermes ecosystems adds
behavior layers, each standing on the row substrate:

| Layer | Contents (NIH-of) | Principal code-volume lever |
|---|---|---|
| **Effect runtime** (Tier 0.5, planned) | Signature GADTs; `Resource`/`Scoped`; effectful + polysemy interpreters; concurrency strategies | GADT signatures + handler stacks replace MTL class towers; test interpreters replace mocking frameworks |
| **Runtime services** (new) | Process spawn/supervision over yamaarashi stdio (MCP servers, shell hooks, terminal backends local/docker/ssh/modal) with deadline-kill and child-env hygiene; cron/heartbeat/timers (scheduled jobs, kanban swarm); namespaced row-typed event bus (`ctx.emit`). Noh mapping candidate: the kuroko-family idea already noted in §6.1 — decide whether the in-tree family reuses the name or leaves it to `~/src/kuroko/` | every service is one effect signature + interpreters; supervision is Resource-bracketed; no if/elif dispatch ladders |
| **LLM substrate** (expands Tier 2's `sarutahiko-model`) | Provider effect: streaming completions as row-typed SSE events; function-calling schemas = row descriptors via `sarutahiko-schema` (same machinery MCP `inputSchema` needs); provider profiles; secrets/credentials effect with explicit profile scope; token/context accounting feeding the prompt-cache rules | one signature covers all providers; capability *rows* not per-provider ADTs; TriState applies to provider config patches |
| **Agent core** (Tier 2, sharpened) | One row-typed registry for tools/commands/skills/hooks with every surface view *derived*; the turn loop as an interpreted program: hooks, approval gates, session persistence; context engine (memory providers, compression as the sole sanctioned mutation); plugins via registration-as-row-extension, capability grants, kill lists | **the turn is a value in `Eff es`** — policy, dry-run, replay, and audit are alternative handler stacks on the *same program*, not code forks; additive payload evolution = row extension |
| **Workspace & code intelligence** (Tier 4 + additions) | Incremental GLR + tags (as planned); FS watch, git integration, editor surfaces via `sarutahiko-lsp` | LogicT nondeterminism replaces stack fork/join plumbing; monoidal finger-tree annotations replace offset bookkeeping; generic traversals replace per-language walkers |
| **Surfaces** (Tier 3) | CLI, TUI (JSON-RPC), gateway, ACP, dashboard | every surface is a projection of the registry + a transport; surface-specific business logic has no place to exist |
| **Distribution** | Plugin catalog (YAML + pinned hashes), portable packages, versioned row vocabularies | manifests validate against the same row-descriptor machinery |

What we deliberately do **not** build: models themselves, an OS sandbox, terminal multiplexers,
editors — the ecosystem consumes upstream for those.

#### The code-volume ledger

The strategy for keeping this manageable is that every layer's boilerplate is deleted by a
different language feature, and the mapping is deliberate design surface:

| Feature | Deletes | Pays off in |
|---|---|---|
| Extensible records + `rcast` | DTO types, per-message ADTs, conversion functions | codec bags, agent rows, DB projections |
| Generic derivation over rows (large-generics / sop-core) + `DerivingVia` | per-type FromJSON/ToJSON/CBOR/SQL instances | both codec bags: one generic decoder each, not one per message |
| HKD functor-mapped records | patch/partial/expression type families per entity | hashigakari TriState, config overlays, provider config patches |
| Effect signatures (GADTs) + handler stacks | MTL class towers, mocking frameworks, policy/audit code forks | every layer; biggest single win in the agent turn loop |
| Type families as row-type rules | runtime validators and their error paths | hashigakari AST, config row-union merge, capability intersection |
| Type-level state machines (small, fixed spaces only) | illegal-state error handling | MCP/LSP handshake phases, transaction scopes, plugin load phases — internal invariants use phantom-indexed GADTs directly; the wire layer's session machines follow the typed-protocols pattern (agency-indexed states + peer GADT, `~/src/typed-protocols/` as reference), distilled dependency-light with a typed-protocols-compatible shape (§0 decision: distill first, swap in the full framework as a backend if pipelining or its proof layer earns their weight) |
| LogicT / nondeterminism monads | manual GLR stack fork/join management | `sarutahiko-parse` |
| Monoidal annotations (finger trees / 2-3 trees) | offset/length/line bookkeeping | `sarutahiko-parse`, streaming framing |
| Church/CPS encoding | RULES-pragma noise and specialized pipeline variants | `yamaarashi` |
| Custom type errors + row-diff debugging utilities | debugging/support burden (indirect volume) | all row-heavy code |
| `QualifiedDo` / `OverloadedRecordDot` sugar | visual volume only (aesthetics mandate) | row-heavy call sites |
| Offline codegen, sparingly (never runtime TH) | hand-transcription of external metamodels (LSP metamodel, MCP schema → row definitions) | protocol codec bag |
| Linear types (stretch goal) | finalizer/cleanup code and the GC-timing bug class | cursors, process handles |

Disciplines that make the ledger hold: no user-facing signature mentions a backend; registries
are derived, never synchronized by hand; every field lands exactly once in
`sarutahiko-fields`; interpreters, not `if` ladders.

#### Contact points with the Nadeem Bitar (keiro) ecosystem

Documented in `~/src/typed-language-model-arena/cabal.project` — the keiro stack, staged by
layer: `keiki` (pure transducer core), `kiroku-store` (Postgres event store + OTel
trace-context), `shibuya-core` (supervised queue workers) + `shibuya-kiroku-adapter`,
`keiro`/`keiro-core` (workflow runtime over one Postgres log), `kioku-api`/`kioku-core`
(event-sourced agent memory), alongside `baikai`/`baikai-openai` (LLM client) and the
`shikumi` family (eval harness). Notable compat signals: the stack builds on **GHC 9.12.4 /
GHC2024** and `shikumi-coder` depends on **effectful ≥2.5** — our effect-system and
toolchain choices align with the ecosystem we are patterned on.

Mapping to our layers (theirs → ours): `keiki` → `sarutahiko-fields`/`yamaarashi`
transformations; `baikai` → LLM substrate (`sarutahiko-model`); `kioku` → session/memory
context engine (agent core); `shibuya` → runtime-services supervision effect; `keiro` →
`yamaarashi-flow` durable orchestration; `kiroku` → hashigakari + row-typed event envelopes
(the CloudEvents vocabulary already in the protocol bag).

**Interop-first contact strategy.** Because the keiro stack is Postgres-log-centric and ours
is row-centric, the *first* contact point is data, not agents: `hashigakari` reading/writing
kiroku-style event stores with row-typed envelopes can interoperate long before any agent
core exists. Wire-level contact with Hermes itself arrives with the Phase-1 MCP flagship.
Full replacement of the top layers (memory, workflow, supervision) is the last contact, not
the first — the plan's layer order already matches this gradient.

#### The maintenance-burden thesis and the kuroko precedent

The program is, explicitly, an answer to Nadeem Bitar's stack: the claim is that the same
capabilities fall out of a dramatically smaller core maintenance burden when the substrate is
rows + effects + streams. The working evidence is `~/src/kuroko/` — an effectful autonomous
agent sidecar, complete agent capability in ≈1k core LOC (<1.5k claimed; 1.9k incl. tests):
Dhall-typed policies, ReAct workflow as a porcupine DAG with a CAS-store step cache, and
three effect groups (`LLM` with OpenAI/Claude/Mock handlers; `Tool` with vinyl/docrec rows,
auto-JSON-Schema and an MCP server bridge; `Store` on persistent-effectful/SQLite WAL). This
plan industrializes the kuroko thesis — same move, with our own record foundation, dual
effect interfaces, wire conformance, and the full surface spectrum. Two consequences:

- **Memory/context engine = log + reducers + policy.** Event-sourcing is native here: one
  row-typed event log (hashigakari over SQLite/Postgres, CloudEvents-shaped envelopes from
  the protocol bag) + pure reducers (sessions, kanban, checkpoints, retrieval indexes are all
  different `fold`s over the same log) + policy (salience, compression — Hermes' only
  sanctioned context mutation — and embedding-based retrieval as an LLM effect). The
  sophisticated part is policy, not plumbing; kuroko's Store pillar and kioku's
  "event-sourced agent memory" both validate the shape. hashigakari replaces kuroko's
  persistent/TH dependency with row-native access.
- **Mixins die into rows + effects.** Hermes' `HermesCLI` + 17 mixins (§HERMES_DESIGN Layer 1)
  is the god-object pattern; the row-typed equivalent is: each mixin becomes a record of UI
  state fields + an effect signature + handlers, and the facade becomes a polymorphic row.
  Module cycles (their lazy-import dance) become effect-row membership.

#### TUI approaches (Tier 3 survey)

| Route | Mechanism | Assessment |
|---|---|---|
| ANSI + haskeline | line-oriented REPL, SGR escapes, streaming frames | the MVP surface; kuroko-style; near-zero code |
| **brick / vty** | declarative pure `Widget n` trees, TEA-ish event loop, viewports/focus; vty-crossplatform is the maintained base | mainline full-screen choice; mature; state rows + open-variant events slot straight into our machinery |
| reflex-vty | FRP over vty: `Dynamic (Record r)` time-varying state as the UI | highest-level fit (the reactive graph *is* the render), thinner ecosystem, keep as experiment |
| Ink child (Hermes parity) | Node/Ink TUI child speaking JSON-RPC to the core — literally Hermes' `--tui` architecture | zero Haskell UI code; a compat surface, not a cop-out; rides our wire layer |
| (none) — embed in editors | ACP surface | Footprint Ladder logic applies to UI too: the editor is a surface we can borrow |

Whatever the route, the TUI is a projection of the registries over the wire layer — state as
rows, events as extensible variants, modal overlays (clarify/approval/palette) as
mode-indexed GADT states, render loop as a yamaarashi stream of frames.

## 3. Architectural contracts

### 3.1 Row discipline
- One field definition, many rows. No per-message ADTs for wire types; rows plus open-variant
  dispatch. Unknown fields are *preserved* (open envelopes), never dropped.
- Projections are `rcast`-style and zero-cost; DTO types are banned at *internal* module
  boundaries. Sanctioned exception (LLM_SUBSTRATE §1.1): adapters to external nominal APIs
  (baikai, etc.) live entirely inside bridge packages, are logic-free, and are
  round-trip property-tested.
- TriState HKD (`Record (TriState) r`) is the single patch representation (RFC 7396/6902),
  with a generic diff engine computing minimal SQL UPDATEs for the db tier.

### 3.2 Effect contracts
- Each capability = one signature GADT in `sarutahiko-effect-signatures` (e.g. `Tools`,
  `FileSystem`, `SessionStore`, `ModelAPI`, `HookDispatch`, `StreamingDB`).
- `handleRPC`-style dispatch: parsed request row → `case getField @Method` → effect senders →
  response row constructed by field extension. This is the records-duality seam from the doc.
- Session state grows rows, not monoliths: post-handshake capability records live inside
  Reader/State; handlers constrain with `HasField`, not concrete env types.
- Bounded hooks: hot-path hook handlers run with deadlines, abandoned on hang; `pre_tool_call`
  fails closed (verbatim Hermes semantics).

### 3.3 Wire contracts
- `sarutahiko-jsonrpc` is dialect-agnostic; MCP and LSP are thin row-vocabularies over it.
- Transports (stdio framing, SSE, Streamable HTTP) are byte→row pipelines in `yamaarashi`
  terms — the wire flagship does not need the §3.5 decision to land.
- Wire-compat test suites are built from spec examples (MCP pinned version, JSON-RPC 2.0
  errata) and run against upstream implementations for interop confidence.

### 3.4 Hermes invariants carried over
1. Prompt-cache safety: additive hook payloads only; no mid-conversation toolset swaps;
   compression is the sole sanctioned context mutation.
2. Narrow-waist core: new capability = CLI command + skill, service-gated tool, plugin, or MCP
   server; core tools last (Footprint Ladder).
3. One registry, many surfaces: the tool registry and command registry derive every consumer
   view (CLI help, TUI, gateway, ACP).
4. Policy over sandbox: allowlists, consent files, capability grants, fail-closed gates,
   load deadlines, kill lists at install and load.
5. Explicit profile scope: never freeze home/config at import time; scope travels with the
   turn (Hermes `hermes_home_key()` analog).

### 3.5 Streaming basis — research findings and decision gates

Requirements: memory-constant pipelines; effects mid-stream (each element may touch
`Eff es`); early-exit resource safety (cursor/sockets closed on short-circuit); SSE and
stdio framing; DB cursor unfolding; row elements without per-element boxing penalties;
concurrency (fan-out to gateway platforms).

Candidates evaluated:

| Option | Strengths | Flaws / risks | Verdict |
|---|---|---|---|
| **conduit** | Battle-tested; deterministic prompt finalization (its core selling point); mature ecosystem (`conduit-extra`, network, process); SSE/JSON-RPC examples abound in the docs. | Historical design turbulence ("core flaw of pipes and conduit" debates); leftovers concept adds incidental complexity; per-element allocation overhead vs fused designs. | Strong fallback; safest interop. |
| **streamly** | Best-in-class fused performance (order-of-magnitude benchmarks vs conduit/pipes); folds+parsers model fits byte→row framing well; native concurrency combinators. | Large surface ("hard to evaluate; it's big"); significant API churn across major versions (0.8→0.9→0.10→0.11 breaks); upstream-coupled dependencies have caused ecosystem friction. | Performance favorite; pin exact version; isolate behind the `yamaarashi` kernel. |
| **streaming / pipes** | Minimal, composable cores. | Lower adoption momentum today; pipes' elegance vs usability tension documented; performance below fused designs. | Not selected. |
| **porcupine (forward port)** | ArrowFlow task-DAG semantics: declarative pipeline graphs, task-level parallelism, docrecords/record-soup lineage matches the record basis. | Oriented to task graphs and `$_` location trees, not element-level byte streams; unwieldy as the *transport* layer; better as a layer *above* element streams for DAG orchestration. | Use for orchestration/DAG layer, not the element-stream kernel. |
| **NIH kernel** | Exact control: effect-integrated `Stream (es :: [Effect]) a`, linear finalization, zero dependency churn; existential steppers unify DB cursors and transports. | Must reimplement framing, parsers, concurrency; ongoing maintenance; risk of subtle resource bugs. | Only if gates below trip. |

**Decision gates (NIH trigger conditions).** Commit to coding the NIH `yamaarashi` kernel only
if, during Tier-1 bring-up on an *interim* basis (conduit, pinned):
1. Early-exit finalization of effectful streams proves unsafe or unergonomic under conduit's
   bracket model when combined with effect rows (i.e., we cannot guarantee cursor/socket
   closure without contortions);
2. Per-element overhead measurably harms the SSE/stdio transport budget (established by
   benchmark against streamly, using `composewell/streaming-benchmarks` methodology);
3. The dual effect-interface contract (§0) cannot be expressed cleanly because the stream type
   hardcodes a monad stack rather than an effect row;
4. Version churn forces repeated breakage (two or more forced major migrations within a
   release cycle).

Otherwise: **streamly pinned behind the `yamaarashi` kernel** as the element-stream basis, with
**conduit adapters** where ecosystem interop demands it, and **porcupine's ArrowFlow semantics**
re-homed as the DAG/orchestration layer (`yamaarashi-flow`) atop the kernel. Re-decide at the
Tier-2 milestone with the benchmark data in hand.

DB cursors are decoupled from this choice by design: the existential `DBCursor` stepper
(GADT holding backend state + step + close) unfolds into whichever stream kernel wins, and
linear/bracketed consumption guarantees cleanup regardless of backend (Postgres
`DECLARE/FETCH` vs SQLite `sqlite3_step`). The database library itself is designed in
`HASHIGAKARI_DESIGN.md`.

**Addendum (kernel + backends option).** The candidates above need not be mutually
exclusive. A church-encoded (CPS) free-monad kernel — `Stream (Of a) (Eff es) a`, polymorphic
in the base monad — fuses sequential binds by construction (Codensity-style, O(1)
left-associated `>>=`), capturing much of streamly's sequential-throughput advantage without
RULES-pragma fragility, while remaining an ordinary transformer-stack-shaped type that
conduit/streamly/pipes adapters can embed or be embedded by. Two observations sharpen the
question:
1. Resource safety is separable from the stream monad: expressed as a `Resource`/`Scoped`
   *effect row* (bracket semantics with guaranteed finalization on short-circuit), it subsumes
   conduit's `bracketP` without bespoke stream plumbing — and works under both effect systems
   via the dual-interface packages.
2. streamly's non-sequential strengths (rewrite-rule-fused pure loops; concurrent
   alternation/applicative streams) are best kept as *backends/strategies* behind the kernel
   (`SerialT (Eff es)` embeds directly) rather than reimplemented.
A third, deeper unification exists: streaming-as-effect via delimited continuations
(`eff`-style `Yield`-effect handlers unify the effect runtime and the stream driver — the
stream *is* a handled coroutine). Effectful itself is primop-based, not
continuation-based, so this is its own kernel path; evaluate alongside the §3.5 gates at the
Tier-1 exit. Net effect on this plan: "pick one winner" becomes "kernel + backends"; the
NIH trigger gates are unchanged, and the wire flagship remains independent of the outcome.

The hybrid stack is now designed as the **yamaarashi (山嵐, "porcupine") family** —
`yamaarashi` kernel, `yamaarashi-conduit` / `yamaarashi-streamly` backends,
`yamaarashi-flow` DAG orchestration — see `YAMAARASHI_DESIGN.md`; the §3.5 gates govern
*when kernel work is coded*, not whether the design exists.

### 3.6 Layering contract — DAG orchestration over element streams

Detailed in `YAMAARASHI_DESIGN.md`; the contract in brief:
`yamaarashi-flow` (porcupine re-homed, base monad `Eff es`) orchestrates *tasks*;
`yamaarashi` (kernel + streamly/conduit backends) moves *elements* inside task bodies.
Neither replaces the other; the contract is:

- **Granularity.** Task/chunk caching at porcupine boundaries (`$_` locations); element
  streaming within bodies. Element-level fusion intentionally does not cross a task edge —
  that is the throughput-for-aesthetics trade (§0), repaid in resume-after-crash, per-task
  debugging, and porcupine-viz visualization.
- **Records.** Task inputs/outputs are anonymous records; `rcast` at boundaries implements
  row-polymorphic routing. ArrowFlow's ArrowChoice decides *which branch* on values; row
  types decide *which fields* statically. The two answer orthogonal questions and compose
  cleanly (porcupine's docrecords/record-soup lineage is why).
- **Kernel locality.** The element kernel choice is per-task-body and invisible to the DAG:
  church-encoded kernel by default, `SerialT (Eff es)` for hot loops, conduit adapters at
  byte boundaries. The conduit/streamly mixture is an implementation detail, not an
  architecture-wide commitment (backend policy in `YAMAARASHI_DESIGN.md` §3).
- **Backpressure is layered.** Porcupine's pull-based (FRP-flavored) demand drives tasks;
  the element kernel manages per-element demand within a body. Each layer owns its own
  discipline; no global backpressure policy.
- **Resource safety is global.** The `Resource` effect row (shared `Eff es` substrate)
  finalizes inner element streams even when an ArrowChoice branch is skipped or the pipeline
  aborts mid-task — one uniform finalization story, no separate bracketP bookkeeping.
- **Caching vs non-determinism.** Porcupine's Make-like location caching assumes
  deterministic tasks; LLM-backed tasks carry a purity/determinism tag with invalidation keys
  (model, sampling params, prompt hash) supplied by `sarutahiko-model`. This is the one
  place porcupine's build-system heritage needs extending for agent workloads; policy lives
  in `yamaarashi-flow`.
- **Concurrency is two-level.** Task-level scheduling belongs to the DAG (a task runs when
  its inputs are ready); element-level strategies (streamly async/parallel wrappers) live
  inside bodies. Document per level who owns cancellation.
- **Placement.** Gateway multiplexing uses per-connection linear pipelines (no DAG);
  cross-connection fan-out, DB→transform→SSE exports, and scheduled/kanban jobs are true
  DAGs (caching/resume shine); the agent turn loop stays imperative. Not everything is a
  DAG — the layering makes that a choice, not an accident.

## 4. Roadmap

### Phase 0 — Foundation (weeks 1–6)
- `sarutahiko-fields`, `sarutahiko-records` (row JSON + TriState + envelope preservation).
- `sarutahiko-effect-signatures` + both interpreter packages; CI matrix runs every library
  test against *both* effect systems.
- Streaming interim = conduit pinned while the `yamaarashi` kernel is designed (its design
  already lives in `YAMAARASHI_DESIGN.md`); benchmark harness stood up early
  (streaming-benchmarks methodology) so §3.5 gates are decided on data.
- Exit: rows round-trip JSON; a demo effectful+polysemy program shares one signature package.

### Phase 1 — Wire flagship (weeks 5–12, overlaps Phase 0 tail)
- `sarutahiko-jsonrpc` with spec-example conformance suite.
- `sarutahiko-mcp`: initialize/tools/capability rows; stdio + SSE transports; interop tests
  against an upstream MCP client and server.
- `sarutahiko-schema` (JSON Schema subset ⇄ row descriptors).
- Exit: a `sarutahiko` executable speaks MCP stdio against Hermes or Claude Code as client;
  conformance suite green under both effect-system interpreters.
- Scope note: Phase 1 also pulls in the *minimal* `Spawn`/`Process` signature subset (stdio
  children only, Resource-bracketed) — MCP servers must be spawned; the full supervision
  layer (shibuya-class) stays deferred to the runtime-services layer.

### Phase 1.5 — the hokora (祠) — vertical validation slice

A small shrine on the peak, built early to prove the mountain holds: a kuroko-scale tracer
bullet through *every* layer in one executable — one-shot CLI → interpreted ReAct turn (one
model call, one MCP tool over yamaarashi stdio transport) → session events appended to a
hashigakari-sqlite row log → one pure reducer → printed summary. Excluding substrate
packages, budget ≤2k LOC, measured. This is the first quantitative datum for the
answer-to-Nadeem thesis (kuroko ≈1k LOC on vinyl/persistent; the hokora is the same claim on
our substrate, with wire conformance and a real store). It validates the effect-signature
catalog against a real consumer before Phase 2 hardens it — the walking-skeleton argument:
substrate APIs are only trustworthy once something on the peak stands on them.

### Phase 2 — Agent core (weeks 10–20)
- `sarutahiko-agent`, `-session`, `-config`, `-hooks`, `-plugins`, `-model`.
- Hermes invariants (§3.4) enforced by construction where possible: additive payloads via row
  extension; fail-closed hook deadlines in the effect runtime.
- CLI with table-driven registry; one-shot mode.
- Exit: `sarutahiko chat` replays a real Hermes session; a ported plugin loads under the
  deadline + kill-list rules.

### Phase 3 — Surfaces + code intelligence (weeks 18–30)
- `sarutahiko-tui` (JSON-RPC to core), `-gateway`, `-acp`.
- `sarutahiko-parse` incremental GLR core (annotations as monoidal record fields; damage
  tracking; reuse; resync), then `sarutahiko-tags` scope-stack extraction; golden tests
  against tree-sitter/ctags outputs.
- Exit: TUI and gateway drive the same agent through the same registries; tags output
  matches universal-ctags on a corpus.

### Phase 4 — Data tier (weeks 24–40)
- `hashigakari-core` AST + dialect compilation; `-hasql` streaming execution of anonymous
  records; `-sqlite`; `-patch`; `-schema` (see `HASHIGAKARI_DESIGN.md`).
- `hashigakari-beam` (`beam-large-anon`) published as a standalone Hackage bridge.
- `yamaarashi-flow`: porcupine re-homed over `Eff es` with row-typed chunks (§3.6),
  including the cache-invalidation policy for non-deterministic (LLM-backed) tasks;
  `yamaarashi` kernel + backends per `YAMAARASHI_DESIGN.md`.
- Format packages by demand order: CBOR/MessagePack envelopes → TOML/YAML overlays →
  Parquet/Arrow projection pushdown → Dhall bridge → RFC 6902/7396 diff engine wired into
  `db-core` UPDATE synthesis.
- Protocol packages by demand order: GraphQL → CloudEvents → OTLP enrichment of
  `sarutahiko-log` → system IPC (D-Bus/Wayland/9P).
- Exit: zero-DTO pipeline demonstrated — SQL query → anonymous record stream → `rcast`
  → MCP tool response, with sensitive fields dropped by projection. Conformance shapes also
  serve as `yamaarashi` acceptance targets (`YAMAARASHI_DESIGN.md` §5); DB cursor streaming
  is designed in `HASHIGAKARI_DESIGN.md` §3.4.

### Ongoing streams
- Benchmark ledger (streaming, record width/compile-time, parser incremental latency) — the
  compile-time regression suite must include a ≥40-column table to keep the large-* advantage
  honest.
- Effect-interface parity: every new signature lands in both interpreter packages in the same
  PR, or the PR does not land.
- Docs: each package ships a design note under `docs/` mirroring the source-doc style.

## 5. Risks

| Risk | Mitigation |
|---|---|
| Type-level error-message pain (rows misaligned) | Investment in custom type errors (`TypeError`), row-diff debugging utilities in `sarutahiko-records`, and a style rule preferring small rows + named fields. |
| Dual effect-interface maintenance burden | Signatures kept tiny and neutral; interpreters are thin; CI parity gate; polysemy package allowed to lag marked with `@since` notes if needed. |
| Streaming NIH scope creep | Gates in §3.5 are explicit and benchmark-driven; kernel work may not begin until at least two gates trip. |
| Protocol drift (MCP spec versions) | Wire version pinned per release (Hermes pins `2025-03-26`); row vocabulary versioned; conformance suite updated on spec bumps. |
| Ecosystem availability of large-* ports | Tier-0 work validates the forward-ported stack first; vinyl fallback path defined (records doc shows vinyl interop is maintained). |
| Incremental parser complexity (GLR forks, error recovery) | Phase 3 only after wire+agent prove the records/effects seam; start with LR-then-fork subset; Wagner–Graham paper as test oracle. |

## 6. Backlog — parked directions

Recorded 2026-09-23 so they survive context switches; pick up after the design-mulling pause.

1. Sketch the `sarutahiko-fields` + `sarutahiko-records` API surface (field definitions, row
   combinators, JSON glue) as a design note.
2. Start Phase 0: multi-package `cabal.project` plus Tier-0 package stubs.
3. Draft the MCP conformance test plan (spec examples → row-typed fixtures) to nail Phase-1
   exit criteria.
4. Streaming deep-dive: prototype the church-encoded kernel + `Resource`-effect sketch and
   run the §3.5 gates/benchmarks (see §3.5 addendum).
5. **Effect-signature catalog design note** (highest design-need; precedes Tier-0 code):
   now written — see `EFFECT_CATALOG_DESIGN.md` (catalog rules, the fourteen signatures,
   and the blessed improvements: capability rows, handlers-as-records, `Scoped` unification,
   `SomeRow` packaging, PVP-for-signatures policy, law testkit). Original summary: the
   full GADT catalog — `Resource`/`Scoped`, `Spawn` (minimal subset), `Log`, `SessionStore`,
   `ModelAPI`, `HookDispatch`, `StreamingDB` — their laws, handler discipline, and the
   dual-interpreter package layout rules. The load-bearing abstraction; errors here
   propagate to every layer. Catalog-wide rules it must fix: signatures expose existential
   steppers/cursors parameterized by `m`, never stream types or concrete `Eff` rows
   (normalizes HASHIGAKARI_DESIGN §3.4); row-carrying effects (`Log`, `EventBus`,
   `HookDispatch`) receive existentially packaged `SomeRow`s so call sites stay
   constraint-clean; scoped regions (transaction/bracket/cursor/hook-handler) unify under
   one `Scoped` pattern; the package ships a reference free-monad runtime for law tests
   while production senders/interpreters live in the bridges, held honest by a parity
   testkit. Open design questions to adjudicate: (i) effect row as capability set — plugins
   receive `forall es. Granted :<: es => Eff es ()`, making grants parametric/compile-time
   instead of Hermes-style runtime allowlists (escape/continuation soundness needs care);
   (ii) handlers as extensible records (interpreters built by record merge — duality made
   executable; needs a spike against both systems' native handler shapes); (iii) PVP-for-
   signatures policy (GADT constructors are breaking; additive evolution via new signatures
   + reinterpretation + deprecation windows, mirroring Hermes' additive-payload discipline);
6. **MCP session GADT design note** — the deciding artifact for the typed-protocols (a) vs
   (c) choice: symmetric-peer handling, unknown-method escape state, whether the distilled
   pattern suffices or the 1.2.x framework (with lookahead) earns its weight.
7. **Memory/context engine design note**: now written — see `MEMORY_ENGINE_DESIGN.md`
   (three-part decomposition: event log with envelope versioning as the one irreversible
   decision, pure reducers as the easy glue, and policy as the real design space — cache-
   safety contract with type-declared `PolicyEffect`, salience, compression, retrieval,
   single-writer concurrency, store-level forgetting). Original summary: event-log schema
   with envelope versioning (the one least-reversible decision above the substrate — logs
   are append-only, so get row-evolution right first), reducer library, policy effects
   (salience, compression, retrieval).
8. **LLM substrate design note** — now written as **utai**: see `LLM_SUBSTRATE_DESIGN.md`
   (v0.2 decision: provider APIs are codec-bag members — two row-codecs, OpenAI-compatible
   + Anthropic, local CLIs via `Process`, baikai as reference/donor; the `ModelAPI`
   signature with laws L1–L4 including transport-level prefix stability; the canonical
   renderer with per-family×version golden tests; profiles/secrets/usage-as-events).
   Original summary: provider effect with row-typed SSE events, function-calling schemas
   as row descriptors (shared with MCP `inputSchema`), secrets/profile scope,
   token/context accounting feeding the cache rules.
9. **Hokora slice spec** (the Phase-1.5 tracer bullet): exact event rows, turn program, and
   the LOC measurement protocol.
10. **Policy experiment instruments** — now spec'd as `kakegoe`: see `INSTRUMENTS_SPEC.md` (cache
    simulator, replay harness, corpus + checkers; six cross-package requirements the
    instruments impose — canonical renderer as shared code in `sarutahiko-model`,
    deterministic recording interpreters, corpus-as-log, scrub-manifest-gated privacy,
    experiment records as data, pinned metric formulas). Original summary: prefix-hash
    cache simulator, pure-policy replay harness with deterministic mock `ModelAPI`,
    synthetic corpus + task checker (shikumi-pattern). Grid sweep decides compression
    policy; ablation decides salience v1; precision@k crossover decides retrieval
    backends. Irreversible/contract decisions (log spine, dialect assumptions,
    cache-safety invariant) stay review/property-gated, not metric-tuned.

Suggested design order: **5 → 6/3 → 7 → 8 → 9**, with 1–2 as the first code and 4
bench-gated. Rationale: the effect catalog is the temple's true foundation — every later
signature must compile against its discipline; the memory log's envelope versioning is the
only top-layer decision that is expensive to reverse; the TUI/surface designs are
intentionally last (they are projections, and §TUI survey shows they are thin once the
registries exist). **Status (2026-09-24): items 5, 6, 7, 8, and the instruments spec
(item 10) are written — EFFECT_CATALOG_DESIGN, the MCP session-GADT decision is recorded
in NIH_PLAN §ledger row (distill-first, typed-protocols-compatible), MEMORY_ENGINE,
LLM_SUBSTRATE, HOKORA_SPEC, INSTRUMENTS_SPEC — and items 1–2 (Tier-0 code) are the next
action.**

### 6.1 Naming convention

Projects and packages are named after Noh theatre vocabulary, honouring the conceptual debt
to Nadeem Bitar's extensive work (whose projects appear as dependencies in
`~/src/typed-language-model-arena/`); `sarutahiko` doubles as the Hermes analogue (guiding
kami at the threshold). One deliberate exception: `yamaarashi` (山嵐, "porcupine") names the
streaming-stack family as a nod to porcupine itself, kept in Roman letters for packaging.
The database access library is `hashigakari` (橋掛かり), the bridge onto the stage — apt
for the library that carries rows between the database and the application (and beams are
involved); the four hashira 柱 are held in reserve as a fallback name. Registered 2026-09-24
as candidates (mappings proposed, pending maintainer blessing): **utaibon** (謡本, the
vocal libretto — the words the performance follows) → the memory/context engine, resolving
that note's naming placeholder; **katatsuke** (型付, choreography notation) → reserved for
the future workflow/turn-choreography runtime (keiro-analog); **tetsuke** (手付, percussion
score) → the scheduler/heartbeat/timeout service; **kantsuke** (管付, the nohkan flute's
score — the cueing notation) → the event bus (cueing and signaling); **nohkan** (能管,the flute instrument itself) → held in reserve. **Blessed 2026-09-24: kakegoe (掛け声)** — the
drummers' calls coordinating the 四拍子 (shibyōshi) ensemble — names the
policy-experiment instruments package (`kakegoe`, `kakegoe-gen`; formerly the working
name `sarutahiko-instruments`), with the maintainer's rationale: kakegoe name *the
coordination* of the ensemble, not the instruments themselves, which is faithful to what
that package is (the English gloss "instruments" slips a little; the Japanese title is
the true name). **Blessed 2026-09-24: utai (謡)** — the chant; the LLM layer
(`utai`, `utai-openai`, `utai-anthropic`, `utai-local`, `utai-mock`), per the
maintainer: the LLM (perhaps with speech synthesis) is the voice of the computer — *vox
calculi, vox dei* — with utaibon 謡本 (the libretto book) reserved for the memory engine,
the chant/book pairing reading exactly right. (Corrections 2026-09-24: 謡本 is utaibon, not
katatsuke; the flute score is kantsuke, the instrument nohkan — maintainer's terms
corrected in registry.) Existing usage to respect: `~/src/kuroko/` — the stagehands, i.e.
the unseen handlers that move props on and off the stage (maps naturally to process
supervision/harness/runner roles). Reserve Noh terms deliberately and check for collisions
with existing repos before naming new packages; candidate future mappings (to be confirmed
by the maintainer, not assumed): kuroko-family = supervisors/schedulers, waki =
interlocutor surfaces (adapters that talk to the world), kyōgen interludes = fast auxiliary
pathways, mugen/kami-mono = the overarching agentic core.
