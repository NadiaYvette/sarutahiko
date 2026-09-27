# sarutahiko Design Review — Gemma4:A12B Perspective

Date: 2026-09-27  
Author: Gemma4:A12B (via kaggle)  
Version: DRAFT v0.1  

---

## 1. Executive Summary

`sarutahiko` aims to provide a composable, effect‑typed agent platform built on Haskell’s advanced type system, row‑polymorphic records (`large-anon/large-records`), and the `yamaarashi` streaming stack. This review evaluates the current architecture, identifies strengths and gaps, and offers concrete recommendations aligned with the project’s stated goals (as per `NIH_PLAN.md` and `PHASE_1_PLAN.md`).

---

## 2. High‑Level Architecture Overview

| Layer | Primary Packages | Responsibilities |
|-------|------------------|------------------|
| **Effect Core** | `sarutahiko-effect-signatures`, `sarutahiko-effect-effectful/polysemy` | Define algebraic effects (Process, Log, Clock, Stepper, TufVerify, TorTransport, etc.) |
| **Records & Schema** | `sarutahiko-records`, `sarutahiko-schema` | Typed, extensible records (`Record f r`), JSON/ CBOR codecs, schema validation |
| **Wire Format** | `kogaki-wire` | Zero‑allocation JSON lexer + SSE parser for protocol framing (MCP, JSON‑RPC) |
| **Protocol Engine** | `sarutahiko-jsonrpc`, `sarutahiko-mcp` | JSON‑RPC 2.0 and MCP 2025‑03‑26 implementation, state‑machine guards |
| **Process Supervision** | `sarutahiko-process` | Resource‑bracketed subprocess supervisor with effectful logging |
| **Observability** | (planned) `sarutahiko-observability` | Event tracing, metrics, replay via `kagami-ita` |
| **Application / Surfaces** | (user‑defined skills, Hermes Agent, Hokora, etc.) | Agent surfaces, tooling, memory engine |

Data flow: Effect handlers → Record‑based commands → Wire codec → Network transport (HTTP/WebSocket or Tor) → Peer agent → reverse path.

---

## 3. Strengths

1. **Type‑Safe Extensibility**  
   - Records via `large-anon` allow open, closed, and extensible rows; combining with `kogaki-wire` yields zero‑copy JSON parsing while preserving field‑level type information.

2. **Effect Isolation**  
   - Each capability (process spawning, logging, TUF verification, Tor transport) is encapsulated as an effect signature, enabling mock‑free testing and clear dependency boundaries.

3. **Streaming First**  
   - Leveraging `yamaarashi` gives back‑pressure aware pipelines, crucial for large tool outputs and long‑running agent loops.

4. **Protocol Correctness**  
   - MCP implementation uses GADTs (`StateGuard`) to enforce initialization handshake, preventing illegal states at compile time.

5. **Reuse of Existing Haskell Ecosystem**  
   - Dependencies on well‑maintained libraries (`hedgehog`, `tasty`, `aeson‑compatible` via `large-anon`'s JSON instances) reduce maintenance burden.

---

## 4. Areas for Improvement

### 4.1 Effect Signature Granularity
- Some signatures bundle multiple concerns (e.g., `Process` includes both spawning and signal handling). Splitting into finer-grained effects (`ProcessSpawn`, `ProcessSignal`) would increase composability.

### 4.2 Error Propagation & Diagnostic Context
- Current error types often lose provenance (e.g., `JsonRpcError` only carries a code). Introducing structured error effect with call‑site context (similar to `effectful`'s `Error` effect with `HasCallStack`) would improve debugging.

### 4.3 Schema Evolution Strategy
- While `sarutahiko-schema` provides validation, there is no explicit versioning or migration path for record schemas. Adopting a schema‑registry pattern (like Apicurio) with backward/forward compatibility checks would safer long‑term skill exchange.

### 4.4 Observability Gap
- No built‑in tracing or metrics export. Integrating OpenTelemetry via an `Observability` effect (spans, metrics) would satisfy production operability requirements.

### 4.5 Build & Versioning Consistency
- Mixed `default-language` (GHC2024 vs GHC2021) and `cabal-version` across packages cause warnings. Unifying to GHC2021 and cabal‑version ≥3.4 eliminates warnings and ensures Stable LTS alignment.

### 4.6 Documentation Drift
- Design notes (e.g., `NIH_PLAN.md`) sometimes outrun implementation (e.g., missing `TorTransport` effect). Establish a “doc‑first” rule: any new effect must have a corresponding design note update before implementation.

---

## 5. Concrete Recommendations

| # | Action | Rationale |
|---|--------|-----------|
| 1 | Split `Process` effect into `ProcessSpawn`, `ProcessSignal`, `ProcessWait` | Improves modularity and allows selective mocking. |
| 2 | Introduce `Effectful.Error.WithStack`‑style effect for structured errors with backtrace | Enhances diagnosability of RPC failures and process errors. |
| 3 | Define `SchemaVersion` effect + registry interface for skill/tool manifests | Enables safe schema evolution and automated compatibility checking. |
| 4 | Add `Observability` effect (traces, metrics) backed by OpenTelemetry Haskell bindings | Provides production‑grade operability. |
| 5 | Standardize `default-language: GHC2021` and `cabal-version: >=3.4` in all `.cabal` files | Removes warnings, aligns with Stackage LTS 22+. |
| 6 | Enforce doc‑first policy via CI: check that any new effect signature adds/updates a design note | Keeps documentation synchronized with code. |
| 7 | Replace ad‑hoc `String`-based method checks in `checkStateGuard` with type‑level symbol‑indexed method ADTs | Eliminates runtime string‑matching bugs; leverages GHC’s symbol solver. |
| 8 | Benchmark `kogaki-wire` against `aeson` + `bytebuilder` for typical MCP payloads | Confirms zero‑copy claim; guides future optimizations. |
| 9 | Create a `sarutahiko-protocols` re‑export bundle (MCP, JSON‑RPC, future LLM substrate) | Simplifies user imports and versioning. |
|10| Add golden‑file test suite for MCP handshake using `hokora-turn.jsonl` fixtures | Guarantees conformance across revisions. |

---

## 6. References

- **TUF Specification** – https://theupdateframework.github.io/specification/latest/  
- **Galois `haskell-tor`** – https://github.com/GaloisInc/haskell-tor  
- **`large-anon` / `large-records`** – https://github.com/nikita-volkov/large-anon  
- **`yamaarashi` Design** – `docs/notes/YAMAARASHI_DESIGN.md`  
- **MCP 2025‑03‑26** – `docs/plans/PHASE_1_PLAN.md` (Task Packet 1.5)  
- **Effect Catalog** – `docs/notes/EFFECT_CATALOG_DESIGN.md`  
- **Record Envelope** – `packages/sarutahiko-records/src/Sarutahiko/Records/Envelope.hs`  

---

## 7. Conclusion

The sarutahiko codebase exhibits a strong foundation in type‑safe, effect‑driven design. Addressing the granularity of effects, enriching error and observability semantics, solidifying schema versioning, and unifying build settings will bring the framework closer to production readiness for autonomous agent fleets. Implementing the recommendations above will preserve existing strengths while closing identified gaps.

--- 

*End of Review*