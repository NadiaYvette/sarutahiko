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
Naming: **utai** (謡, the chant itself) — blessed 2026-09-24. The LLM is the voice of the
computer (*vox calculi*); utaibon 謡本 — the libretto book the chant is performed from —
remains reserved for the memory engine, the pairing reading exactly right. Packages:
`utai` (signature/rows/renderer/laws/catalog), `utai-openai`, `utai-anthropic`,
`utai-local`, `utai-mock`.

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
is exercised by every layer daily. It also strengthens the keiro-comparison thesis:
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
| `utai` | The `ModelAPI` signature (GADT, per catalog rules), the request/response/event row vocabulary, tool-schema descriptors (shared with `sarutahiko-schema`/MCP), the **canonical renderer**, laws, the model-catalog rows (hand-maintained v1; offline-codegen from provider docs later, per the ledger rule). Zero provider dependencies; zero effect-system dependencies. |
| `utai-openai` | The OpenAI-compatible codec (chat completions + SSE streaming + embeddings endpoint): one de-facto standard covering DeepSeek, OpenRouter, Together, ollama, vLLM, …. |
| `utai-anthropic` | The Anthropic messages codec (event taxonomy, cache-control, thinking surface). |
| `utai-gemini` | The Google Gemini generateContent codec — third family; reference: louter (`~/src/louter/`, incl. its `GEMINI_STREAMING_FORMATS.md` and tests). |
| `utai-local` | Local-CLI providers (claude -p, codex exec) as a `Process`-signature interpreter. |
| `utai-mock` | Deterministic mock (scripted responses) and **transcript-serving** interpreter (kakegoe's replays; the testkit pattern). |

**Sequencing Note (The Phase 1.5 Skinny Spine Protocol):** Full `sarutahiko-model`
and multi-provider codecs land in Phase 2. However, the Phase 1.5 Hokora vertical slice
requires executing a model completion. Under the **Skinny Spine protocol**
(`NIH_PLAN.md` §4, `HOKORA_SPEC.md` §4), the neutral `ModelAPI` signature and the
deterministic `utai-mock` interpreter (alongside a bare-bones HTTP client or local CLI
call for the live run) are pulled forward to Phase 1.5. Full provider catalog
expansion and offline codegen remain in Phase 2.

## 2. The `ModelAPI` signature

Per catalog rules: GADT over `m`, canonical `Stepper m a` handles (not stream types,
not bespoke cursor GADTs), laws stated, scope exclusions explicit.

```haskell
data ModelAPI (m :: Type -> Type) :: Type -> Type where
  Complete :: CompletionReq -> ModelAPI m CompletionResp
  Stream   :: CompletionReq -> ModelAPI m (Stepper m StreamEvent)
  Embed    :: EmbedReq -> ModelAPI m EmbedResp          -- v1.5; backend availability open
  Count    :: ContextRow -> ModelAPI m TokenCount       -- budget accounting (pure-ish; may consult a tokenizer)
```

`Stream` yields the canonical `Stepper m StreamEvent` (defined in
`EFFECT_CATALOG_DESIGN.md` §4), which unfolds into `yamaarashi` element streams and
is finalized under `Resource`/`Scoped`. The former bespoke `EventCursor m` is unified
into this standard.

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

## 5. The Kogaki Codec Strategy (Maintenance via Extraction, Fixtures, and Oracles)

The central objection to writing provider codecs from scratch (the "codec maintenance
problem", `DESIGN_REVIEW.md` §6 Tension 5) is that external model provider wire APIs drift,
add subtle streaming nuances, and change chunking conventions across releases.
Under the **kogaki strategy** (specified program-wide in `KOGAKI_DESIGN.md`,
transposing the Unicode/i18n doctrine from `registers/REUSE_REGISTER.md` 2.22 and
`docs/transcripts/kogaki-i18n-unicode.md`), this burden is managed by a principled
five-part discipline rather than ongoing ad-hoc triage:

1. **Upstream Source Analysis (Reference Donors):**
   Rather than adopting third-party SDKs as nominal dependencies (which violates the
   zero-DTO principle and brings large dependency graphs), we treat official and
   established libraries (`baikai`, the official Python/TypeScript SDKs, `louter` for Gemini)
   as *reference donors*. We inspect their internal delta-assembly logic, SSE chunking
   heuristics, and error classification algorithms (using our source-analysis tools
   like `organ-bank` and `frankenstein` where foreign C/Rust/Python source analysis is
   warranted) to extract semantic ground truth directly into our pure row decoders.
2. **The Build-Time Extraction Thesis:**
   Provider wire schemas, model catalogs, and capability descriptors are not hand-transcribed
   into nominal boilerplate. Following the extraction thesis, machine-readable upstream
   artifacts (OpenAPI specifications, JSON Schema declarations, provider model inventories)
   are checked in as data files, and typed row definitions (`sarutahiko-fields`) and
   decoder dictionaries are extracted at build time. Build-time codegen keeps artifacts
   hermetic, inspectable, and immune to Template Haskell compiler fragility.
3. **Recorded Transcripts as Hermetic Golden Fixtures:**
   Provider wire behavior is verified not against speculative synthetic mocks, but
   against **recorded wire transcripts** (raw SSE byte streams, chunked tool call fragments,
   multi-block thinking deltas, usage trailers) captured from real provider interactions
   and checked into `kakegoe` corpora. Every quirk row in `registers/CODEC_QUIRKS.md` is
   backed by a concrete transcript fixture. If a provider changes chunk placement, the
   fixture captures it and property tests flag the divergence immediately.
4. **Differential Fuzzing Against External Oracles:**
   In scheduled/nightly CI runs, the pure Haskell codecs and the canonical renderer are
   tested against live provider endpoints (or local ollama/vLLM instances) as external
   oracles. Differential tests verify that our request serializer produces byte/semantic
   equivalence with the provider's expectations and that our streaming parser accepts
   real-time provider events without dropped fields or malformed state.
5. **Strict Scope Bounding (Phased Scope):**
   Vendor sprawl is strictly bounded by the agent core's actual demand. We reject
   speculative API coverage (audio streaming, file upload batches, fine-tuning APIs).
   The codecs encode *only* what the turn program consumes:
   - Chat completions and streaming text/tool deltas.
   - Tool calling schema generation and chunk assembly (`OPEN-004`, `ANT-004`).
   - Thinking/reasoning block preservation (`OPEN-006`, `ANT-007`).
   - Explicit prompt-cache control markers (`ANT-006`).
   - Disjoint monoidal usage accounting (`L2`).

## 6. Concurrency, profiles, secrets

- Interpreters are row-polymorphic over profile scope: the resolved credential handle
  and `Model` travel with the request (Hermes' explicit-profile rule — never frozen at
  import); interpreters hold no global mutable provider state; connection reuse
  (TLS-manager caching per host) is an interpreter concern done per-profile.
- Usage/cost roll-ups are emitted as session events (memory engine vocabulary), so the
  cost ledger is a derived projection, and kakegoe replays carry realistic accounting.
- Streaming concurrency: canonical `Stepper m StreamEvent` steppers unfold into
  yamaarashi streams; the turn program consumes them like any cursor; cancellation
  via `Resource`/`Scoped` teardown.

## 7. Open items

1. ~~**Codec quirk inventory v1**~~ — resolved: `registers/CODEC_QUIRKS.md` (2026-09-24),
   whose rows carry the auth-header/SSE-taxonomy/usage-placement survey; louter's Gemini
   streaming tests remain the seed fixtures for the third family.
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
5. ~~**Naming:** bless `utai` (or choose otherwise)~~ — blessed 2026-09-24: `utai`
   (NIH_PLAN §6.1); `utaibon` remains reserved for the memory engine.
