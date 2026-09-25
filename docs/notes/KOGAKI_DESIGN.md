# The Kogaki Doctrine & Codec Architecture — Design Note (`kogaki` / 小書)

Status: DRAFT v0.1 · 2026-09-24 — Unified specification for external specification
faithfulness, Unicode/i18n, and protocol codec maintenance across the program.
Related: `NIH_PLAN.md` (§3.3 wire contracts, §6 item 12), `registers/REUSE_REGISTER.md`
(2.1 records, 2.7 JSON/aeson, 2.14 provider codecs, 2.21 shakespeare, 2.22 ICU4C),
`LLM_SUBSTRATE_DESIGN.md` (§5 provider codecs), `FIELDS_RECORDS_DESIGN.md` (§1 evolution,
§2 HKD, §5 combinator laws, §6 recipes), `registers/CODEC_QUIRKS.md` (living wire quirks),
`INSTRUMENTS_SPEC.md` (`kakegoe` fixtures & replay), `DESIGN_REVIEW.md` (§6.1 evaluation),
`transcripts/kogaki-i18n-unicode.md` (the provenance discussion).

**Thesis.** AI assistants sit at the vortex of rapidly churning, externally governed
specifications: Unicode/CLDR versions, shifting LLM provider streaming deltas, and a
sprawling contingent of network protocols and file formats. Traditional engineering
succumbs either to the **FFI monolith trap** (wrapping sprawling C/C++ libraries that leak
imperative handles, destroy build hermeticity, and diverge across environments) or the
**Nominal DTO trap** (manually transcribing thousands of lines of fragile, ad-hoc ADTs
that drag down compilation times and lag upstream changes).

The **Kogaki Doctrine** (named after *kogaki* 小書, the variant-performance annotations
written beside the canonical text in Noh theatre) establishes a single, program-wide
methodology for mastering external specifications: **anatomical donor analysis**,
**build-time machine-readable extraction**, **variant row projections**, **fixture-backed
conformance with external differential oracles**, and **strict agent-turn scope bounding**.

---

## 0. Scope & Unified Architectural Role

The Kogaki Doctrine governs three distinct but structurally isomorphic domains across
`sarutahiko`:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            THE KOGAKI DOCTRINE                              │
├─────────────────────────────────────────────────────────────────────────────┤
│ Five Core Pillars:                                                          │
│ 1. Anatomical Donors          4. Differential CI Oracles                    │
│ 2. Build-Time Extraction      5. Strict Scope Bounding                      │
│ 3. Variant Projections (小書)                                               │
├───────────────────────┬─────────────────────────────┬───────────────────────┤
│ Domain 1: Unicode     │ Domain 2: LLM Provider      │ Domain 3: Supporting  │
│ & Internationalization│ Wire Protocols              │ Codec Bag             │
├───────────────────────┼─────────────────────────────┼───────────────────────┤
│ • Pure-Haskell stack  │ • OpenAI, Anthropic, Gemini │ • MCP (JSON-RPC 2.0)  │
│ • CLDR inheritance    │ • Streaming chunk assembly  │ • LSP open variants   │
│   (root ⊕ lang ⊕ reg) │ • Prompt cache preservation │ • SSE framing         │
│ • Typed message GADTs │ • Quirk tracking in kakegoe │ • OTLP, CloudEvents   │
│ • ICU4C as oracle     │ • Official SDKs as oracles  │ • Arrow, Parquet, CBOR│
└───────────────────────┴─────────────────────────────┴───────────────────────┘
```

The note organizes these domains under the shared doctrine:
- **§1 The Kogaki Doctrine: The Five Pillars of Faithfulness**
- **§2 Domain 1: Unicode, CLDR & The Pure-Haskell i18n Architecture**
- **§3 Domain 2: Rapidly-Evolving LLM API Protocols**
- **§4 Domain 3: The Supporting Protocol & Format Codec Bag**
- **§5 The Kogaki Toolchain, Fixture Pipeline & Differential CI Oracles**

---

## 1. The Kogaki Doctrine: The Five Pillars of Faithfulness

Whenever `sarutahiko` must interface with an external, third-party standard or wire
format, the implementation must satisfy the **Five Pillars of Kogaki**:

### Pillar 1: Anatomical Donors (Source Analysis without Nominal Adoption)
When addressing an external protocol, we do not design in a vacuum or invent wire
quirks from scratch. Instead, we dissect authoritative upstream reference engines
(e.g., ICU4C, Go `x/text`, ICU4X, the official Anthropic/OpenAI TypeScript and Python
SDKs, `baikai`). We analyze their AST structures, stateful chunk accumulation routines,
normalization loops, and error handlings as **anatomical donors**.
*The Rule:* We adopt their parsing logic and protocol insights into our row codecs,
but **strictly reject their nominal DTO wrappers, C memory handles, and imperative APIs**.
The resulting codecs emit and consume `large-anon` records exclusively.

### Pillar 2: Build-Time Extraction Thesis
Manual transcription of external schemas into Haskell types is strictly forbidden:
it is error-prone, drifts silently, and burdens developers with endless boilerplate.
Template Haskell codegen is equally banned in core paths due to compile-time memory
blowups and compiler slowdowns.
*The Rule:* Schemas, data tables, and character property vectors are **extracted at
build time** from machine-readable upstream artifacts (Unicode Character Database UCD,
CLDR XML/JSON, OpenAPI 3.1 specifications, JSON Schema definitions). The extraction tool
generates pure, static data tables (e.g. flat `SmallArray#` vectors, integer codebooks,
and applicative `Record FieldCodec r` recipes) during the build, producing zero runtime
overhead and maintaining strictly linear GHC compilation.

### Pillar 3: Variant Projections (小書 / Kogaki Semantics)
In classical Noh theatre, a *kogaki* is a small annotation placed beside the master text
specifying a variant performance (different mask, modified chant, altered choreography).
The master play remains constant; variants are annotations projected beside it.
*The Rule:* In `sarutahiko`, canonical domain models and core records are immutable and
versioned. Variations—whether they are regional language localizations (`en-US`),
provider-specific wire formats (Anthropic nested content blocks vs OpenAI flat tool calls),
or protocol dialect options—are represented as **variant projections** composed via the
right-biased override merge combinator (`⊕` from `FIELDS_RECORDS_DESIGN.md` §5):
$$\text{VariantView} = \text{BaseMaster} \oplus \text{SpecificOverrides}$$

### Pillar 4: Conformance Fixtures & Differential CI Oracles
We do not rely on mock tests or synthetic intuitions to verify protocol fidelity.
*The Rule:*
1. Every wire quirk or edge case (recorded in `CODEC_QUIRKS.md`) must be witnessed by a
   raw, recorded wire transcript fixture stored in `kakegoe` (`test/fixtures/wire/`).
2. In nightly CI, property tests run **differential fuzzing against external oracles**:
   the output of our pure-Haskell codecs and Unicode functions is asserted for exact
   semantic equivalence against external reference engines (e.g. system `libicu` or the
   official Anthropic/OpenAI Python SDKs). The reference engine serves as an infallible
   oracle in test suites without ever being linked into production executables.

### Pillar 5: Strict Scope Bounding (Agent-Turn Bounding)
External standards bodies and commercial cloud providers continually expand their surfaces
with enterprise features, speculative APIs, and esoteric options.
*The Rule:* Codec surfaces are **strictly bounded to what the agent turn program actually
executes**. For LLM APIs: streaming text completions, streaming tool calls, thinking
blocks, prompt cache control, and token counts. For Unicode: normalization, segmentation,
bidi, plural selection, and message formatting. Everything else (speech audio, batch
fine-tuning, complex calendar algorithms, C-level text shaping) is categorically deferred
until a concrete agent capability requires it.

---

## 2. Domain 1: Unicode, CLDR & The Pure-Haskell i18n Architecture

### 2.1 The Problem: Why `text-icu` Was Relegated to Oracle
In `REUSE_REGISTER.md` §2.22, the original plan to rely on `text-icu` (FFI bindings to
C++ `libicu`) was revised to pure-Haskell NIH on three fatal operational grounds:
1. **GC Finalization Hazard:** ICU C handles reside in `ForeignPtr`s managed by Haskell's
   garbage collector. Finalization is non-deterministic, risking file descriptor exhaustion
   and resource leaks during high-throughput agent turns.
2. **Environmental Variance & Golden Test Corruption:** `libicu` links against host system
   CLDR data. Different Linux distributions and macOS versions ship different ICU versions,
   causing character collation, date formatting, and line-breaking outputs to differ across
   machines. This corrupts `kakegoe` deterministic golden test suites and hash verification.
3. **Missing Message Grammars:** `text-icu` exposes C primitives (normalization, collation,
   regex) but *omits* ICU's `MessageFormat` and `PluralRules`—the exact high-level
   grammars required for parameterized agent localization.

### 2.2 Locale-as-Record: CLDR Inheritance via Record Merge (`⊕`)
In the Unicode Common Locale Data Repository (CLDR), locales form an inheritance tree:
$$\text{root} \longrightarrow \text{language} \longrightarrow \text{script} \longrightarrow \text{region} \longrightarrow \text{variant}$$

In `kogaki`, a resolved locale is not an opaque string, but a **first-class extensible record**
built via the right-biased override merge combinator (`⊕` from `FIELDS_RECORDS_DESIGN.md` §5):

```haskell
-- Resolving en-GB locale data:
type LocaleRecord = Record Identity LocaleFields

resolveLocale :: LanguageTag -> LocaleRecord
resolveLocale (LanguageTag "en" (Just "GB") Nothing) =
  localeRoot ⊕ localeEn ⊕ localeEnGB
```

#### The Inheritance Laws
Locale resolution satisfies the algebraic laws of `(⊕)`:
1. **Associativity:** $(a \oplus b) \oplus c = a \oplus (b \oplus c)$
2. **Right-Biased Override:** Regional specializations (e.g. `en-GB` date formats or
   spelling) strictly override language-level defaults, which in turn override root defaults.
3. **Zero Runtime Search:** Merged locale records compile into a flat `SmallArray# Any`
   at startup, enabling $O(1)$ property access during turn execution.

### 2.3 Typed Message GADTs & Presentation-Edge Rendering
Per `DOC_STRATEGY.md` §6, raw UI string literals are strictly forbidden in core agent code.
Messages are modeled as first-class GADTs:

```haskell
-- Core domain: pure typed message intent
data AgentMessage where
  MsgTurnLimitReached  :: !Int -> !Int -> AgentMessage
  MsgToolExecutionFailed :: !ToolName -> !ErrorCode -> !Text -> AgentMessage
  MsgPromptCacheStatus :: !CacheHitStatus -> !ByteCount -> AgentMessage

-- Localization dictionary: extensible record of formatting templates
type MessageCatalog = Record (Const MessageTemplate) AgentMessageRow
```

- **Totality:** The type system guarantees that every message constructor has a
  corresponding entry in the language's message catalog.
- **Presentation Edge:** Localization occurs exclusively at the interpreter boundary
  via the `RenderMessage` capability effect, passing the resolved `LocaleRecord` to format
  plurals, dates, and parameter substitutions.

### 2.4 Phased Pure-Haskell Implementation Scope

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    KOGAKI UNICODE IMPLEMENTATION PHASES                     │
├─────────┬──────────────────────────────┬────────────────────────────────────┤
│ Phase   │ Functional Capabilities      │ Canonical Standards & Extraction   │
├─────────┼──────────────────────────────┼────────────────────────────────────┤
│ **1**   │ • Normalization (NFC, NFD)   │ • UAX #15 (Unicode Normalization)  │
│         │ • Grapheme & Word Breaking   │ • UAX #29 (Text Segmentation)      │
│         │ • Case Mapping & Folding     │ • UnicodeData.txt, DerivedCoreProps│
├─────────┼──────────────────────────────┼────────────────────────────────────┤
│ **2**   │ • BCP-47 Language Tag Parser │ • RFC 5646 / BCP-47                │
│         │ • CLDR Locale Inheritance    │ • CLDR JSON data extraction        │
│         │ • PluralRules (Cardinal/Ord) │ • CLDR Plural Rules specification  │
│         │ • Parameterized MessageFormat│ • ICU MessageFormat 1.0/2.0 grammar│
├─────────┼──────────────────────────────┼────────────────────────────────────┤
│ **3**   │ • Bidirectional Layout       │ • UAX #9 (Unicode Bidi Algorithm)  │
│         │ • UCA Collation (Root + Tail)│ • UTS #10 (Collation Algorithm)    │
│         │ • Number & Currency Format   │ • CLDR Numbering Systems           │
├─────────┼──────────────────────────────┼────────────────────────────────────┤
│ **Edge**│ • Dictionary Breaking (CJK)  │ • External FFI / HarfBuzz / Codex  │
│         │ • Complex Glyph Shaping      │   (retained at terminal/GUI seam)  │
└─────────┴──────────────────────────────┴────────────────────────────────────┘
```

---

## 3. Domain 2: Rapidly-Evolving LLM API Protocols

### 3.1 The Wire Realities of Model Providers
LLM APIs are nominal, unversioned, and continuously drifting:
- **Anthropic:** Messages API uses streaming Server-Sent Events with nested content blocks
  (`content_block_start`, `content_block_delta`, `content_block_stop`), ephemeral prompt
  cache markers (`cache_control: {"type": "ephemeral"}`), and custom thinking blocks
  (`thinking_delta`).
- **OpenAI:** Chat Completions API streams flat deltas with chunked tool arguments
  (`arguments` strings split arbitrarily across multiple chunks), reasoning tokens
  (`reasoning_content`), and distinct prompt cache usage metrics.
- **Gemini:** REST/RPC streaming with polymorphic candidate structures, function call
  parts, and distinct safety rating arrays.

### 3.2 Build-Time OpenAPI Extraction
Rather than hand-crafting nominal Haskell data types for each provider, `kogaki-extract`
processes official OpenAPI 3.1 specifications:

```
Provider OpenAPI Spec (JSON) ───> kogaki-extract ───> Typed Record Codecs
(anthropic_openapi.json)                              (Sarutahiko.Model.Codecs.Anthropic)
                                                      • FieldCodec recipes
                                                      • Discriminator tables
                                                      • Model capability records
```

1. **Extraction:** `kogaki-extract` parses the provider schema, extracts request/response
   product types, and generates static `Record FieldCodec r` definitions.
2. **Zero Nominal Overhead:** Decoded wire events immediately become `large-anon` records:
   ```haskell
   type AnthropicDeltaRow = '[ "text" ':= Text, "index" ':= Int ]
   type DeltaRecord = Record Identity AnthropicDeltaRow
   ```
3. **No Template Haskell:** Code generation runs as a pre-build step or standalone tool,
   checking generated codebook hashes into git for instant build reproducibility.

### 3.3 Stateful Fragment Accumulation (Quirk Solvers)
Streaming APIs emit fragmented tool call arguments and reasoning tokens. The parser cannot
yield complete records until fragments coalesce:

```haskell
-- Canonical Fragment Accumulator
data ChunkAccumulator
  = AccText !Text
  | AccToolCall !ToolCallId !FunctionName !Text  -- Text holds growing JSON buffer
  | AccThinking !Text
```

- When an `OPEN-004` chunked tool argument delta arrives, the accumulator appends raw
  string slices to the buffer.
- On delimiter or block stop (`ANT-003`), the accumulated buffer is decoded via the
  pre-compiled `RowCodec` into the typed tool argument record.

### 3.4 Canonical Rendering & Cache Determinism (Law L4)
LLM prompt caching requires bit-for-bit identical prefixes. Any fluctuation in JSON key
ordering, whitespace, or unicode escaping destroys the provider cache hit.
`kogaki` enforces **Law L4 (Canonical Prefix Invariance)**:
1. Object keys are serialized in lexicographical order.
2. UTF-8 byte sequences are strictly canonicalized (NFC normalization).
3. The rendered prefix byte stream is guaranteed identical across calls, verified by
   `kakegoe` offline hash simulation.

---

## 4. Domain 3: The Supporting Protocol & Format Codec Bag

The Kogaki Doctrine extends to all wire protocols across `sarutahiko`:

### 4.1 MCP (Model Context Protocol) & JSON-RPC 2.0
- **Bidirectional Open Variants:** JSON-RPC requests, notifications, and responses are
  modeled as open variants over anonymous records.
- **Dynamic Tool Schemas:** An MCP tool definition publishes its input schema as a
  `Record Column r`. The Kogaki extraction pipeline converts this directly into the
  provider-compliant JSON Schema object sent to Anthropic/OpenAI function calling APIs.

### 4.2 Streaming & Framing (SSE & LSP)
- **SSE (Server-Sent Events):** The `yamaarashi` SSE framing layer consumes raw byte
  streams, decodes `event:` and `data:` fields into an envelope record, and yields
  `Stepper m StreamEvent` with zero buffer copying.
- **LSP (Language Server Protocol):** Header-based framing (`Content-Length: ...\r\n\r\n`)
  unfolds into open record dispatches based on the `method` string.

### 4.3 Columnar & Binary Formats (Arrow, Parquet, CBOR)
- **Zero-Copy Arrow RecordBatches:** In Phase 4, Apache Arrow arrays map directly to
  records of vectors:
  ```haskell
  type ArrowBatchRow = '[ "timestamps" ':= Vector Int64, "values" ':= Vector Double ]
  type BatchRecord = Record Vector ArrowBatchRow
  ```
- **Unknown-Field Preservation (E3/E4):** CBOR, MessagePack, and CloudEvents envelopes
  preserve unknown wire fields in `WireEnvelope` (`envRawBytes` and `envUnknownFields`),
  enforcing E4 (no re-serialization across forward boundaries).

---

## 5. The Kogaki Toolchain, Fixture Pipeline & Differential CI Oracles

### 5.1 The `kakegoe` Conformance Fixture Pipeline
Every quirk cataloged in `CODEC_QUIRKS.md` is tied to an immutable fixture:

```
test/fixtures/wire/
  ├── anthropic/
  │   ├── ANT-003-nested-content-blocks.stream.txt   (Raw SSE capture)
  │   └── ANT-004-thinking-delta.stream.txt
  ├── openai/
  │   └── OPEN-004-chunked-tool-args.stream.txt
  └── unicode/
      ├── NormalizationTest.txt                      (Official UCD conformance)
      └── CollationTest_CLDR.txt
```

#### The Recording Protocol
1. When a new provider quirk is observed, the raw HTTP/SSE wire stream is recorded into
   a `.stream.txt` fixture using `utai-record`.
2. The fixture is scrubbed of all secrets (API keys, authorization headers) per
   `INSTRUMENTS_SPEC.md` §2.4.
3. A property test is added asserting that `sarutahiko-model` decodes the fixture into the
   expected typed event sequence with zero errors.

### 5.2 Nightly Differential Oracle Matrix

In nightly CI, `sarutahiko` tests its pure-Haskell decoders against external oracles:

```
                    ┌────────────────────────────┐
                    │    Raw Wire Test Inputs    │
                    └─────────────┬──────────────┘
                                  │
                  ┌───────────────┴───────────────┐
                  ▼                               ▼
       ┌─────────────────────┐         ┌─────────────────────┐
       │  sarutahiko-model   │         │    External Oracle  │
       │  (Pure Haskell)     │         │ (Python/TS SDK, ICU)│
       └──────────┬──────────┘         └──────────┬──────────┘
                  │                               │
                  ▼                               ▼
       ┌─────────────────────┐         ┌─────────────────────┐
       │ Decoded Event Stream│         │ Decoded Event Stream│
       └──────────┬──────────┘         └──────────┬──────────┘
                  │                               │
                  └───────────────┬───────────────┘
                                  ▼
                         Assert Exact Match
                        (Structural Parity)
```

1. **LLM Wire Oracles:** The test runner invokes the official Python SDKs (`anthropic-python`,
   `openai-python`) in a subprocess on identical raw fixture streams, comparing the
   resulting objects against our Haskell record stream.
2. **Unicode Oracles:** Normalization, casing, and collation outputs are asserted for
   exact byte equivalence against system `libicu` via a dedicated test harness (`kogaki-oracle`).
3. **Outcome:** Any divergence between our pure-Haskell codecs and the upstream reference
   engine triggers an immediate CI failure before reaching production.

---

## 6. Summary of Architectural Contracts

| Contract ID | Name | Statement |
|---|---|---|
| **K1** | **Donor Integrity** | Upstream SDKs/C libraries are used strictly as anatomical donors; nominal types and C handles never enter core rows or signatures. |
| **K2** | **Extraction Exclusivity** | Codec schemas, property tables, and taxonomies are extracted from machine-readable files at build time; zero Template Haskell in core. |
| **K3** | **Variant Override** | Locale inheritance, provider profiles, and dialect options compose via right-biased override merge (`(⊕)`). |
| **K4** | **Fixture Grounding** | Every confirmed quirk in `CODEC_QUIRKS.md` is witnessed by an immutable raw wire fixture in `kakegoe`. |
| **K5** | **Differential Oracle Parity** | Nightly CI asserts exact semantic parity against external reference engines acting as oracles. |
| **K6** | **Agent-Turn Bounding** | Codec scope is strictly bounded to what the agent turn program executes; speculative features are rejected. |
