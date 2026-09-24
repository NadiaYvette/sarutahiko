# The Codec Quirk Inventory

Status: LIVING DOCUMENT · v0.1 · 2026-09-24 (resolves LLM_SUBSTRATE_DESIGN open item 1)
Related: `LLM_SUBSTRATE_DESIGN.md` (utai codecs), `INSTRUMENTS_SPEC.md` (transcripts as
fixtures), `REUSE_REGISTER.md` (2.14/2.15), `EFFECT_CATALOG_DESIGN.md` (L1–L3 laws)
Scope: wire-level quirks of the LLM provider families that the `utai-*` codecs must
encode, classify, or work around. This is a **maintenance document**: it is never
"finished"; every transcript review, doc read, or bug triage that surfaces a wire fact
lands here as a row. Initial survey below; growth procedure in §4.

Quirk ID scheme: `<FAMILY>-<NNN>` (FAM = OPEN for OpenAI-compatible, ANT for Anthropic,
GEM for Gemini, LOC for local CLIs, X for cross-family). Status: CONFIRMED (verified
against recorded transcript/docs), REPORTED (secondary source), SUSPECTED (needs
verification).

---

## 1. OpenAI-compatible family (`utai-openai`)

Applies to api.openai.com and the compatible hosts (DeepSeek, OpenRouter, Together,
ollama, vLLM, LM Studio). The family is de-facto standard, but the quirks are mostly
*where compatibility bends*.

| ID | Quirk | Status | Codec obligation |
|---|---|---|---|
| OPEN-001 | **Auth is a bearer header** (`Authorization: Bearer <key>`), but some hosts accept `api-key` header style (Azure-flavored) | CONFIRMED | auth style is a model-catalog row field, not a codec branch |
| OPEN-002 | **Streaming is SSE with `data:` lines; terminal sentinel is the literal `data: [DONE]` line** — not a JSON event | CONFIRMED | L1 terminator mapping: `[DONE]` ⇒ emit `EventDone`; a `finish_reason` on the last chunk precedes it |
| OPEN-003 | **`finish_reason` semantics vary**: `stop`, `length`, `tool_calls`, `content_filter`; some hosts emit `null` on intermediate chunks | CONFIRMED | map to our `StopReason` row; `null` tolerated on all but final |
| OPEN-004 | **Tool calls stream as deltas**: `tool_calls[i].function.arguments` arrives in fragments that must be concatenated by index before JSON parsing | CONFIRMED | codec assembles argument fragments; index-keyed, order not guaranteed across indices |
| OPEN-005 | **Usage reporting placement**: absent by default in streaming unless `stream_options: {include_usage: true}`; when present it arrives as a *separate final chunk* with empty `choices` | CONFIRMED | options row sets the flag; L2 usage taken from the final chunk only |
| OPEN-006 | **Reasoning tokens** (`completion_tokens_details.reasoning_tokens`) appear only in usage details, not as stream events (OpenAI); DeepSeek emits `reasoning_content` deltas instead | CONFIRMED | two encodings behind one reasoning row; L3 translation recorded |
| OPEN-007 | **Empty `choices` arrays** occur on usage-only chunks and some error-ish payloads | CONFIRMED | codec must not assume non-empty |
| OPEN-008 | **Error bodies are JSON with `error.message/type/code`**, but HTTP status taxonomy is the reliable part; some proxies emit non-JSON errors | CONFIRMED | categorized errors keyed on status first, body second; non-JSON bodies still categorized |
| OPEN-009 | **`system` role is a first-class message**, not merged (unlike older Anthropic); some compatible hosts downconvert oddly | CONFIRMED | context row renders `system` verbatim per family; demotion recorded if a host merges |
| OPEN-010 | **ollama/vLLM local hosts**: no TLS, no real auth, occasionally omit fields (e.g. no `usage` at all) | CONFIRMED | L2 law holds per-interpreter: absent usage ⇒ zero-value + `Unavailable` marker, not fabricated zeros |
| OPEN-011 | **Azure OpenAI variant**: `api-key` header, deployment-name-as-model in path, `api-version` query param | REPORTED | if/when Azure lands, it is a model-catalog + auth-style row, not a new codec |

## 2. Anthropic family (`utai-anthropic`)

| ID | Quirk | Status | Codec obligation |
|---|---|---|---|
| ANT-001 | **Auth is two headers**: `x-api-key` + `anthropic-version` (mandatory, dated) | CONFIRMED | version pinned per catalog row; missing version = hard 4xx |
| ANT-002 | **System prompt is a top-level `system` field**, not a message role | CONFIRMED | context row ⇒ request rendering differs structurally from OPEN-009; the renderer is family-parameterized for exactly this |
| ANT-003 | **Streaming event taxonomy is typed**: `message_start`, `content_block_start`, `content_block_delta` (`text_delta`/`input_json_delta`), `content_block_stop`, `message_delta` (with `stop_reason` + cumulative usage), `message_stop`, plus `ping` and `error` | CONFIRMED | the richest taxonomy; L1 terminator = `message_stop`/`error`; `ping` is a no-op to absorb |
| ANT-004 | **Tool arguments stream as `input_json_delta.partial_json`** — must be concatenated then parsed; a block-level `input` is absent until stop | CONFIRMED | same assembly duty as OPEN-004 but different field path; the *row* for "assembled tool arguments" is shared |
| ANT-005 | **Usage is cumulative in `message_delta`** (`output_tokens`), initial counts in `message_start` (input + cache fields) | CONFIRMED | L2: take message_start + final message_delta; do not sum deltas |
| ANT-006 | **Prompt caching is explicit**: `cache_control: {type: "ephemeral"}` markers on content blocks; cache-read/cache-write tokens surface in usage details | CONFIRMED | cache markers are an options/row feature — the renderer must place them per policy (memory engine's cache contract meets the wire here) |
| ANT-007 | **Thinking**: `thinking: {type: "enabled", budget_tokens}`; thinking arrives as its own content blocks (`thinking` type) with signature fields; budget is clamped per model — clamp recorded in response | CONFIRMED | L3: clamp surfaced; thinking blocks stored as content rows, signature preserved for replay |
| ANT-008 | **Error taxonomy**: `invalid_request_error`, `authentication_error`, `permission_error`, `not_found_error`, `request_too_large`, `rate_limit_error`, `api_error`, `overloaded_error` (+ 529 overloaded status); `request.id` header for support | CONFIRMED | maps to catalog `ErrorCategory`; `overloaded` ⇒ retryable |
| ANT-009 | **Rate-limit headers** (`anthropic-ratelimit-*` including `tokens-remaining`) are richer than OpenAI's | CONFIRMED | surfaced as log events; retry policy consumes them above the codec |
| ANT-010 | **Long requests**: no hard request-size doc guarantee; context-overflow is signaled as `invalid_request_error` with a prompt-is-too-long message pattern | REPORTED | `ContextOverflow` category by message pattern until a structured field exists |

## 3. Gemini family (`utai-gemini`)

| ID | Quirk | Status | Codec obligation |
|---|---|---|---|
| GEM-001 | **Auth is a query param** (`?key=`) or `x-goog-api-key` header | CONFIRMED (louter) | query-param style must not leak into URLs logged at info level; header style preferred |
| GEM-002 | **Method-in-path dispatch**: `models/{model}:generateContent` / `:streamGenerateContent` / `:countTokens` | CONFIRMED (louter) | the colon-verb pattern is URL structure, not body structure; renderer emits per family |
| GEM-003 | **Dual streaming modes**: `?alt=sse` (default, `data:` lines) vs `?alt=json` (a JSON array of chunks) | CONFIRMED (louter) | codec speaks SSE; `alt=json` accepted as input format for transcripts/fixtures |
| GEM-004 | **Per-chunk `usageMetadata`** (promptTokenCount/candidatesTokenCount/totalTokenCount), not tail-only | CONFIRMED (louter) | L2: last chunk's metadata is authoritative; intermediate counts may be partial |
| GEM-005 | **Termination is `finishReason` on the last candidate** (`STOP`, `MAX_TOKENS`, `SAFETY`, `RECITATION`, …) — there is no `[DONE]` sentinel | CONFIRMED (louter) | L1 mapping: finishReason-present chunk ⇒ terminator; SAFETY/RECITATION map to `ContentFiltered` |
| GEM-006 | **System instruction is a dedicated field** (`systemInstruction`), not a message role; contents carry `role: user/model` only | CONFIRMED | renderer family branch (like ANT-002) |
| GEM-007 | **Safety blocking is inline**: `promptFeedback.blockReason` on the first chunk, or `finishReason: SAFETY` mid-stream; blocked candidates can carry no content | CONFIRMED (louter tests) | content-filter category; empty-candidate payloads tolerated |
| GEM-008 | **Thinking/reasoning**: `thinkingConfig` with `thinkingBudget`; budget 0 disables (on supporting models) | REPORTED | L3 clamp/demote recorded; row field mirrors ANT-007 intent |
| GEM-009 | **Counting**: `:countTokens` endpoint exists as a distinct method | CONFIRMED (louter) | `Count` op maps here for this family |

## 4. Local CLI providers (`utai-local`)

| ID | Quirk | Status | Codec obligation |
|---|---|---|---|
| LOC-001 | **claude -p / codex exec speak their own output conventions** (JSON lines or formatted text by flag), not SSE | CONFIRMED | the "codec" is output-format parsing + flag assembly; recorded transcripts cover both tools |
| LOC-002 | **Exit codes and stderr carry error information** distinct from stdout payload | CONFIRMED | `ErrorCategory` mapping must consume exit code + stderr, per hokora open item 4 |
| LOC-003 | **No usage accounting** (or tool-specific approximations) | CONFIRMED | L2 zero-value + `Unavailable` marker, as OPEN-010 |

## 5. Cross-family observations (X)

| ID | Observation | Consequence |
|---|---|---|
| X-001 | **The same three duties recur**: argument-fragment assembly (OPEN-004/ANT-004), usage extraction with distinct placement (OPEN-005/ANT-005/GEM-004), terminator detection with distinct sentinels (OPEN-002/ANT-003/GEM-005) | the *row* vocabulary carries the shared products (assembled args, usage, stop reason); only the extraction recipes are per-family — the codec split that makes two packages (not five) sufficient |
| X-002 | **Error categories should be decided by status+category-enum first, message text last**; message-pattern matching is the fallback for unstructured cases only (ANT-010) | keeps `isRetryable` honest across hosts that reword messages |
| X-003 | **Every family can silently truncate** (`length`/`MAX_TOKENS`) — truncation is a *result*, not an error | `StopReason` row carries it; memory engine's budget accounting reads it |

## 6. Growth procedure and the Kogaki Codec Strategy

Quirk tracking is governed by the **kogaki strategy** (transposed from the pure-Haskell
internationalisation methodology in `registers/REUSE_REGISTER.md` 2.22 and
`docs/transcripts/kogaki-i18n-unicode.md`):

1. **Source Analysis of Upstream Donors:** When providers modify streaming event
   structures, we inspect the official reference implementations (`anthropic-sdk-python`,
   `openai-python`, `google-genai`, `baikai`) to discover parser invariants and
   fragment assembly logic without adopting their nominal DTO hierarchies.
2. **Build-Time Extraction Thesis:** Wire schemas, parameter descriptors, and model
   taxonomies are extracted from checked-in machine-readable upstream specifications
   (OpenAPI specs, JSON Schema catalogs) at build time, avoiding manual transcription
   and Template Haskell fragility.
3. **Fixture-Backed Quirk Rows:** Every CONFIRMED row in this register is backed by a
   concrete recorded wire transcript (raw SSE bytes, chunked JSON deltas) stored in the
   `kakegoe` corpus. A quirk is never speculative; it is witnessed by bytes.
4. **Differential Fuzzing Against Live Oracles:** Scheduled CI jobs run identical test
   prompts through both our pure codecs and official provider SDKs / live APIs, flagging
   wire drift before it impacts agent turns.
5. **Strict Scope Bounding:** Codec maintenance is restricted to features actively
   consumed by the agent turn program (streaming text, tool arguments, reasoning deltas,
   prompt caching markers, usage roll-ups). Speculative endpoints are rejected.
6. **Promotion & History:**
   - A quirk enters this table when: (a) a recorded transcript shows a wire fact the
     codec must handle, (b) provider docs state a behavior, or (c) a bug's root cause is
     a wire assumption.
   - Status transitions: `SUSPECTED` → `REPORTED` (secondary source) → `CONFIRMED`
     (fixture recorded in tree).
   - Demotions: When a provider fixes behavior, the row gains a "fixed as of <date>"
     note rather than being deleted (living register history is append-only).
