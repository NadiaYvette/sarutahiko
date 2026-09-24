# The LLM Substrate — Design Note

Status: DRAFT v0.1 · 2026-09-24 (backlog item 8)
Related: `EFFECT_CATALOG_DESIGN.md` (`ModelAPI` signature, mock interpreters, testkit),
`INSTRUMENTS_SPEC.md` §2.1 (the canonical renderer — this note's forced deliverable),
`MEMORY_ENGINE_DESIGN.md` (§5.1 cache contract, §7 secret scoping), `HOKORA_SPEC.md`
(the first consumer), `NIH_PLAN.md` (Tier 2, ledger, offline-codegen rule)
Anchor precedent: **baikai** (`~/src/baikai/` — 媒介, "mediation") — the keiro ecosystem's
provider-neutral LLM client, retained as *reference implementation and design-lesson
donor*, not as engine (§0). Precedent for the revised decision: kuroko's own LLM pillar
(hand-rolled OpenAI/Claude streaming handlers) — provider transports were NIH'd once
before on the vinyl-era stack.
Naming: candidate **utai** (謡, the chant itself — utaibon 謡本 being the libretto book
already reserved for the memory engine); pending blessing per §6.1. Working package
name `sarutahiko-model` until then.

---

## 0. Purpose and the central decision (revised v0.2)

The LLM substrate is the layer every other top layer consumes: the turn program speaks
to models only through it, the memory engine's policy calls embeddings through it, the
instruments replay it. The v0.1 draft proposed reusing baikai as the provider engine,
transplanting the hashigakari-over-hasql doctrine. **That transplant was an analogy
mismatch, and the maintainer correctly challenged it:** the glue-only alternative
exists (the arena consumes the keiro stack directly), so adoption must be justified by
more than reuse — and under the program's actual motivations (design aesthetics,
re-grounding Haskell coverage in the row/effects/streams principles, redesign in light
of first iterations, integration contact with our protocol stacks) it fails. Hasql
earned reuse because its core *already embodies* compositional row-adjacent design;
baikai's core vocabulary (`Message`/`Content`/`Options`/`Response` nominal ADTs) is
precisely the first-iteration design class this program replaces. The revised central
decision:

> **Provider APIs are members of the protocol/format codec bag.** The OpenAI-compatible
> family and the Anthropic family are two row-shaped wire protocols (JSON envelopes,
> SSE event streams, open options), implemented with the bag's own machinery;
> local-CLI providers (claude -p, codex exec) run through the `Process` signature.
> Baikai is a reference implementation and design-lesson donor — its laws and
> taxonomies are confirmed and adopted; its code is not depended on.

This follows the plan's own demand-order logic: no other wire protocol in the program
is exercised by every layer daily. It also strengthens the answer-to-Nadeem thesis:
kuroko already demonstrated provider access without first-iteration dependencies; the
substrate makes that cheaper still (SSE framing via yamaarashi, row codecs, open
envelopes, `Process`-bracketed CLIs). Design lessons adopted from baikai (provenance
now "confirmed against first iteration"): the exactly-one-terminator stream law (L1),
disjoint-usage monoids (L2), option translation/demotion honesty (L3), categorized
errors with `isRetryable`, and — as independent validation of the catalog's §6.2 —
baikai's own evolution from a `Provider` typeclass + existential to a registry of
operation-records (handlers-as-records, first-iteration experience converging on the
blessed design).

## 1. Package layout

| Package | Contains |
|---|---|
| `sarutahiko-model` | The `ModelAPI` signature (GADT, per catalog rules), the request/response/event row vocabulary, tool-schema descriptors (shared with `sarutahiko-schema`/MCP), the **canonical renderer**, laws, the model-catalog rows (hand-maintained v1; offline-codegen from provider docs later, per the ledger rule). Zero provider dependencies; zero effect-system dependencies. |
| `sarutahiko-model-openai` | The OpenAI-compatible codec (chat completions + SSE streaming + embeddings endpoint): one de-facto standard covering DeepSeek, OpenRouter, Together, ollama, vLLM, …. |
| `sarutahiko-model-anthropic` | The Anthropic messages codec (event taxonomy, cache-control, thinking surface). |
| `sarutahiko-model-local` | Local-CLI providers (claude -p, codex exec) as a `Process`-signature interpreter. |
| `sarutahiko-model-mock` | Deterministic mock (scripted responses) and **transcript-serving** interpreter (kakegoe's replays; the testkit pattern). |

Codec quirks, auth variants, and provider drift are owned by the two codec packages
and tracked against recorded provider transcripts (kakegoe corpora double as golden
fixtures). Because the codecs are protocol-bag members, they inherit the bag's
conformance discipline; because there are two, vendor sprawl stays bounded — new
"vendors" are model-catalog rows, not new code paths.

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

Laws (additions to the catalog's generic ones; provenance = confirmed against baikai's
first iteration):

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
  Under the codec decision it is testable *end to end*: codec → renderer → bytes are
  all ours.

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
- **Models as data:** model catalogs are rows (API family, base URL, costs, context
  window, quirks — baikai's `Model` shape confirmed as the right fields); generated
  catalogs remain an offline-codegen option from provider documentation (ledger rule),
  with hand-maintained rows as the v1 truth.
- **Embeddings:** resolved by the OpenAI-compatible codec's `/v1/embeddings` endpoint
  (the codec bag's first embeddings consumer; baikai's `Baikai.Embedding` module
  confirmed the field shape as reference). `Embed` stays v1.5; lexical-first retrieval
  still unblocks nothing.

## 4. The canonical renderer (the instruments' forced deliverable)

`renderCanonical :: ProviderFamily -> RequestVersion -> ContextRow -> ByteString`

- Owned here, **shared code** per INSTRUMENTS_SPEC §2.1: the bytes kakegoe's simulator
  hashes must be produced by the same function that (via our codecs) shapes the
  request. Under the codec decision this is exact, not approximate: renderer → codec →
  bytes are all ours, and the honest-approximation caveat of the bridge era is
  retired — providers hash their serialization of the message prefix, and the codec
  *is* that serialization. The simulator's declared upper-bound status now comes only
  from block-splitting, not from any divergence between measured and sent bytes.
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
  import); interpreters hold no global mutable provider state; connection reuse
  (TLS-manager caching per host) is an interpreter concern done per-profile.
- Usage/cost roll-ups are emitted as session events (memory engine vocabulary), so the
  cost ledger is a derived projection, and kakegoe replays carry realistic accounting.
- Streaming concurrency: `EventCursor` steppers unfold into yamaarashi streams; the
  turn program consumes them like any cursor; cancellation via `Resource` teardown.

## 6. Open items

1. **Codec quirk inventory v1** (the new §1's first deliverable): auth header styles;
   SSE event taxonomies and their row encodings (Anthropic's typed event stream vs
   OpenAI's delta objects); tool-call delta shapes; usage-report placement (stream
   tail vs separate event); retry-relevant response headers. Built against recorded
   provider transcripts as golden fixtures.
2. **Transcript format** (kakegoe §6.2): request/response/event rows recorded per
   turn, versioned like corpora; lands with the mock package — now also serving as
   the codecs' golden-fixture format.
3. **Reasoning/thinking option surface:** adopt baikai's translation semantics
   wholesale (L3) but confirm the row encoding covers clamp/collapse/drop distinctly —
   the memory engine's budget accounting may want to know *which* happened.
4. **Hokora live-run provider:** two zero-network options — a local CLI via `Process`
   (claude -p / codex exec) or an OpenAI-compatible codec against a localhost host
   (ollama/vLLM); confirm stderr/exit-code mapping into `ErrorCategory` for the CLI
   path at implementation. Either exercises the full stack.
5. **Naming:** bless `utai` (or choose otherwise) before the first real package ships;
   `utaibon`/memory-engine remains reserved alongside.
