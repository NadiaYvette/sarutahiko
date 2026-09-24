# The LLM Substrate — Design Note

Status: DRAFT v0.1 · 2026-09-24 (backlog item 8)
Related: `EFFECT_CATALOG_DESIGN.md` (`ModelAPI` signature, mock interpreters, testkit),
`INSTRUMENTS_SPEC.md` §2.1 (the canonical renderer — this note's forced deliverable),
`MEMORY_ENGINE_DESIGN.md` (§5.1 cache contract, §7 secret scoping), `HOKORA_SPEC.md`
(the first consumer), `NIH_PLAN.md` (Tier 2, ledger, offline-codegen rule)
Anchor precedent: **baikai** (`~/src/baikai/` — 媒介, "mediation"), the keiro ecosystem's
provider-neutral LLM client: one dispatch surface (`completeRequest`/`streamRequest`)
routed by a `Model` value, models-as-data with a generated catalog, typed streaming
events with an exactly-one-terminator invariant, categorized errors with `isRetryable`,
`Usage`/`Cost` monoids, and call-time options that *translate/demote* across providers
rather than silently dropping (`ThinkingTranslation`, cache-retention downgrades).
Naming: candidate **utai** (謡, the chant itself — utaibon 謡本 being the libretto book
already reserved for the memory engine); pending blessing per §6.1. Working package
name `sarutahiko-model` until then.

---

## 0. Purpose and the central decision

The LLM substrate is the layer every other top layer consumes: the turn program speaks
to models only through it, the memory engine's policy calls embeddings through it, the
instruments replay it. This note fixes its design — and its central decision, which
follows the same doctrine as hashigakari-over-hasql:

> **Do not rebuild provider transports. `sarutahiko-model` owns the *signature*, the
> row vocabulary, the canonical renderer, and the interpreters; `baikai` remains the
> provider engine.**

Baikai already solves the hardest non-record part of this layer — one dispatch surface
across Anthropic/OpenAI/compatible hosts/local CLIs, typed streams, categorized errors,
cost accounting — and it is part of the ecosystem we are in dialogue with, built on
effectful and streamly (both our choices). Rewriting it would violate the plan's
"never rebuild wire machinery" rule for zero records-side gain. What baikai *lacks* is
exactly what our substrate adds: effect-signature neutrality, row-typed request/event
vocabularies, the canonical renderer, and law-tested mock/recording interpreters.

## 1. Package layout

| Package | Contains |
|---|---|
| `sarutahiko-model` | The `ModelAPI` signature (GADT, per catalog rules), the request/response/event row vocabulary, tool-schema descriptors (shared with `sarutahiko-schema`/MCP), the **canonical renderer**, laws. Zero provider dependencies; zero effect-system dependencies. |
| `sarutahiko-model-baikai` | Production interpreter: `ModelAPI` ops → baikai calls; `Model` records ↔ model rows; usage/cost events emitted as rows. The only production interpreter in v1. |
| `sarutahiko-model-mock` | Deterministic mock (scripted responses) and **transcript-serving** interpreter (kakegoe's replays; the testkit pattern). |

Provider additions, quirks, and transport fixes are **baikai's** to own (upstream
contributions, not forks); our tree adds interpreters only. If baikai lacks an
operation the catalog requires (embeddings — see §6), the gap is either upstreamed to
baikai or served by a thin direct interpreter in `sarutahiko-model-baikai`, never by a
new provider transport in our tree.

## 2. The `ModelAPI` signature

Per catalog rules: GADT over `m`, cursors not streams, laws stated, scope exclusions
explicit.

```haskell
data ModelAPI (m :: Type -> Type) :: Type -> Type where
  Complete :: CompletionReq -> ModelAPI m CompletionResp
  Stream   :: CompletionReq -> ModelAPI m (EventCursor m)
  Embed    :: EmbedReq -> ModelAPI m EmbedResp          -- v1.5; backend availability open
  Count    :: ContextRow -> ModelAPI m TokenCount       -- budget accounting (pure-ish; may consult a tokenizer)

data EventCursor m where                       -- exactly-one-terminator invariant (baikai's law, adopted)
  EventCursor :: st
              -> (st -> m (Maybe (StreamEvent, st)))    -- Nothing = terminator consumed
              -> (st -> m ())
              -> EventCursor m
```

Laws (additions to the catalog's generic ones):

- **L1 (terminator):** every `Stream` yields exactly one terminal event (`Done` or
  `Error`), last. Adopted verbatim from baikai's invariant; the testkit checks it for
  every interpreter, mock included.
- **L2 (usage):** every `Complete`/`Stream` surface `Usage` (input/output/cache-read/
  cache-write/reasoning, disjoint) — monoidal, roll-up to session events. Token
  accounting in the memory engine consumes nothing else.
- **L3 (option honesty):** an option the backend cannot honor is *translated or
  explicitly demoted*, never silently dropped — baikai's `ThinkingTranslation` and
  cache-retention downgrade semantics, adopted as law (the response carries what was
  actually granted).
- **L4 (prefix stability):** given an identical `ContextRow` and identical options, the
  interpreter emits byte-identical requests (testable via the canonical renderer). This
  is the law that makes the memory engine's cache contract real at the transport layer.

Scope exclusions: no retry/backoff policy (that is `Supervise`/turn-program territory —
the interpreter surfaces categorized errors, policy lives above); no secret *storage*
(credential *sources* are a config-layer concern; the interpreter receives a resolved
credential handle); no provider pricing logic beyond baikai's.

## 3. The row vocabulary

Requests, responses, and stream events are rows over `sarutahiko-fields` — the same
field definitions reused across `ContextRow` (memory engine), tool descriptors, and
usage events.

- **`CompletionReq`:** the context row (messages as content-block rows: text, images,
  tool calls/results), tool descriptors, and an options row (`temperature`, `thinking`,
  `cacheRetention`, `responseFormat`, `maxTokens`). Options rows are TriState-patchable
  like everything else in the program.
- **`StreamEvent`:** `EventStart`, `TextDelta`, `ToolCallDelta`, `EventDone Usage`,
  `EventError (ErrorCategory, message)` — baikai's event family as rows, so session
  logging and the memory engine's usage events are row extensions, not conversions.
- **Tool descriptors:** a tool's function-calling schema *is* a row descriptor rendered
  by `sarutahiko-schema` — the same machinery MCP `inputSchema` uses (one
  implementation, two consumers; recorded as the schema package's contract).
- **Models as data:** baikai's `Model` records (API tag, costs, context window, quirks)
  are mirrored as model rows; the generated catalog remains baikai's, projected.

## 4. The canonical renderer (the instruments' forced deliverable)

`renderCanonical :: ProviderFamily -> RequestVersion -> ContextRow -> ByteString`

- Owned here, **shared code** per INSTRUMENTS_SPEC §2.1: the bytes kakegoe's simulator
  hashes must be produced by the same function that (via baikai's transport) shapes the
  request. Honest approximation, stated: providers hash *their* serialization of the
  message prefix; our canonical rendering of that prefix is the right hash target
  because the message array's content and order are what both engines preserve. This
  keeps the declared upper-bound-model status of the cache simulator.
- Versioned per `ProviderFamily` **and** `RequestVersion` (renderer version policy,
  resolving INSTRUMENTS_SPEC §6.1: any byte-affecting change bumps `RequestVersion`;
  experiment manifests record the pair; hashes across versions are explicitly
  incomparable, never silently comparable).
- Golden tests: pinned context rows ⇒ pinned bytes, per family × version — the
  renderer's own conformance suite, plus L4's property check end-to-end.
- `cacheRetention` interacts here: the renderer/interpreter must actually *request*
  retention per options (demotion recorded), or the memory engine's cache economics
  silently evaporate. L3 makes the demotion visible; the turn program surfaces it.

## 5. Concurrency, profiles, secrets

- Interpreters are row-polymorphic over profile scope: the resolved credential handle
  and `Model` travel with the request (Hermes' explicit-profile rule — never frozen at
  import); the interpreter holds no global mutable provider state of its own (baikai's
  process-global registry is contained behind the interpreter boundary and documented
  as such).
- Usage/cost roll-ups are emitted as session events (memory engine vocabulary), so the
  cost ledger is a derived projection, and kakegoe replays carry realistic accounting.
- Streaming concurrency: `EventCursor` steppers unfold into yamaarashi streams; the
  turn program consumes them like any cursor; cancellation via `Resource` teardown.

## 6. Open items

1. **Embeddings coverage:** baikai's README names no embedding API; decide
   upstream-to-baikai vs thin-direct interpreter when `Embed` lands (v1.5; the memory
   engine's lexical-first retrieval means nothing blocks on it).
2. **Transcript format** (kakegoe §6.2): request/response/event rows recorded per
   turn, versioned like corpora; lands with the mock package.
3. **Reasoning/thinking option surface:** adopt baikai's translation semantics
   wholesale (L3) but confirm the row encoding covers clamp/collapse/drop distinctly —
   the memory engine's budget accounting may want to know *which* happened.
4. **Local-CLI providers** (claude -p / codex exec): baikai supports them; the hokora
   should prefer one for its live run (no network dependency, still a real provider
   path through the full stack) — confirm subprocess stderr/exit-code mapping into
   `ErrorCategory` at implementation.
5. **Naming:** bless `utai` (or choose otherwise) before the first real package ships;
   `utaibon`/memory-engine remains reserved alongside.
