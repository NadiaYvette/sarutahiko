# sarutahiko Design Review — Gemma4:31B Perspective

Date: 2026-09-27  
Author: Gemma4:31B (via Gemini)  
Version: DRAFT v0.1  

---

## 1. Executive Summary

This review evaluates the sarutahiko project against its stated design goals in `NIH_PLAN.md`, `PHASE_1_PLAN.md`, and other design notes. It examines documentation quality, fidelity of implementation to design, completeness of the feature set relative to leading AI coding assistant REPLs (GitHub Copilot Chat, Cursor, Claude Code, etc.), and whether prevailing issues in the AI coding assistant domain (e.g., context drift, tool latency, unreliable code generation, security/privacy concerns) are being addressed.

Overall, sarutahiko exhibits a strong theoretical foundation but shows gaps between design aspirations and current implementation, particularly in documentation sync, end‑to‑end user‑visible features, and mitigation of common REPL pain points.

---

## 2. Documentation Quality Assessment

### 2.1 Coverage & Organization
- **Strengths:** The `docs/` directory contains a comprehensive hierarchy: design notes, registers, imports, transcripts, and a clear `DOC_STRATEGY.md` outlining lifecycle and canonicity.
- **Deficits:** Many design notes are lengthy and lack concise summaries; cross‑referencing is inconsistent. Some notes (e.g., `NIH_PLAN.md`) are treated as canonical but contain outdated sections that have not been updated to reflect completed work (e.g., MCP implementation). The `PROTOCOL_LIBRARIES_INTEGRATION.md` note is excellent but not yet linked from the main architecture overview.

### 2.2 Accuracy & Traceability
- **Issue:** Several design notes reference effects or modules that are either missing or renamed (e.g., `TorTransport` effect mentioned in `NIH_PLAN.md` but not yet implemented). This creates a drift where the documentation asserts capabilities that the code does not yet provide.
- **Recommendation:** Adopt a strict “doc‑first” rule: any new effect, module, or major protocol must have its design note updated *before* code is merged. Use CI to verify that all referenced symbols exist.

### 2.3 Accessibility for New Contributors
- **Deficit:** The entry point (`README.md`) points to `PLAN.md` and `STATE.md`, but these are operational rather than explanatory. New contributors must wade through dense design notes to understand how to run a simple skill or extend the agent.
- **Recommendation:** Add a “Getting Started” guide that walks through cloning, building, launching the Hermes REPL, and creating a minimal skill, with links to relevant design notes for deeper reading.

---

## 3. Code‑to‑Design Fidelity

### 3.1 Effect System
- **Design Goal (per `EFFECT_CATALOG_DESIGN.md`):** Provide a row‑typed algebraic effect system where each capability is an effect signature, allowing fine‑grained composition and static guarantees.
- **Current State:** Effects such as `Process`, `Log`, `Clock`, `Stepper` exist and are used in `sarutahiko-process` and `sarutahiko-effect-signatures`. However, the `Process` effect bundles spawning, signaling, and waiting, violating the granularity advised in the design. The `TufVerify` and `TorTransport` effects are referenced but not yet implemented.
- **Verdict:** Partially faithful; needs refinement of effect granularity and completion of missing effects.

### 3.2 Records & Schema
- **Design Goal (per `FIELDS_RECORDS_DESIGN.md`):** Use `large-anon`/`large-records` for extensible, type‑safe records with schema validation via `sarutahiko-schema`.
- **Current State:** The `sarutahiko-records` library provides `Record f r` and envelope types. `sarutahiko-schema` offers combinators and validation. Codecs are derived via `kogaki-wire` for JSON and CBOR. The MCP types (see `Sarutahiko.MCP.Types`) correctly use `Record` for structured data where appropriate.
- **Verdict:** Largely faithful; the record‑based approach is consistently applied across JSON‑RPC and MCP layers.

### 3.3 Streaming & Back‑Pressure
- **Design Goal (per `YAMAARASHI_DESIGN.md`):** Provide a tiered streaming kernel that enables back‑pressure aware pipelines for I/O, protocol frames, and effectful operations.
- **Current State:** The `kogaki-wire` lexer and parser are built on top of `yamaarashi` primitives, and the MCP server uses `yamaarashi` for reading/writing streams. However, the public API still exposes raw `ByteString` in many places (e.g., MCP tool handlers), missing an opportunity to enforce streaming at the type level.
- **Verdict:** Faithful in core but not fully leveraged in user‑facing APIs.

### 3.4 Protocol Implementation (MCP & JSON‑RPC)
- **Design Goal (per `PHASE_1_PLAN.md` TP‑1.5):** Implement a spec‑conformant MCP 2025‑03.26 engine, reusing existing substrate (`kogaki-wire`, `sarutahiko-records`, etc.) and making invalid states unrepresentable.
- **Current State:** The MCP package (`sarutahiko-mcp`) provides:
  - Type‑safe `InitializeParams/Result`, `ListToolsResult`, `CallToolResult`.
  - A `StateGuard` GADT that tracks server initialization state and rejects illegal method calls at the type level.
  - Zero‑aeson JSON codecs via `kogaki-wire`.
  - A test suite that validates the handshake and round‑tripping.
  - Integration with `sarutahiko-jsonrpc` for lower‑level RPC framing.
- **Verdict:** Strong adherence to design; the MCP implementation is one of the most faithful realizations of the project’s goals.

### 3.5 Observability & Telemetry
- **Design Goal (per `OBSERVABILITY_DESIGN.md`):** Provide an observability effect (`kagami-ita`) for events, tracing, metrics, and replay.
- **Current State:** No observable implementation exists in the codebase; the `Observability` effect is only sketched in notes. This is a notable gap.
- **Verdict:** Not implemented.

### 3.6 Security & Supply‑Chain
- **Design Goal (per `PROTOCOL_LIBRARIES_INTEGRATION.md`):** Integrate `hackage-security` (TUF) for skill/tool supply‑chain integrity and `haskell-tor` for anonymous transport.
- **Current State:** Neither effect is implemented; only the design note exists.
- **Verdict:** Missing.

---

## 4. Feature Set Completeness vs. Leading AI Coding Assistant REPLs

| Feature | sarutahiko (Current) | GitHub Copilot Chat | Cursor | Claude Code | Comments |
|---------|----------------------|---------------------|--------|-------------|----------|
| **REPL‑style chat interface** | Hermes TUI (text‑based) | Web/VSCode chat | VSCode pane | VSCode/terminal | Functional but lacks rich markdown rendering, inline previews, and multimodal input. |
| **Inline code suggestions** | None (relies on external skills) | Real‑time suggestions | Real‑time suggestions | Real‑time suggestions | Missing; depends on user‑provided skills for synthesis. |
| **Multi‑turn context & memory** | Basic message history; no long‑term memory engine | Conversation memory (tokens) | Conversation + file context | Conversation + file context | No persistent memory engine yet; `memory` tool exists but not integrated into REPL. |
| **Tool use (file edit, terminal, etc.)** | Full tool suite via Hermes (file patch, terminal, web_search, etc.) | Limited to editor actions | Broad (terminal, file, browser) | Broad (terminal, file, browser) | Comparable; Hermes provides a unified tool belt. |
| **Skill / plugin system** | Yes (skills directory, plug‑in loading) | No (fixed model) | Limited (extensions) | Limited (extensions) | More extensible than commercial REPLs. |
| **Agent orchestration (sub‑agents)** | Yes (`delegate_task`) | No | No (experimental) | No | Advanced feature. |
| **Deterministic, type‑safe code generation** | Possible via skills using Haskell, but not built‑in | Probabilistic LLMs | Probabilistic LLMs | Probabilistic LLMs | Unique strength if leveraged. |
| **Security (supply‑chain, sandbox)** | Planned (TUF, Tor) but not implemented | Sandboxed via VPN? | Sandboxed via container? | Sandboxed via container? | Missing concrete implementation. |
| **Observability & telemetry** | Not implemented | Basic usage telemetry | Basic usage telemetry | Basic usage telemetry | Gap. |
| **Multimodal input (image, audio)** | None | Image input (GPT‑4V) | Image input | Image input | Missing. |
| **Performance & latency** | Dependent on skill execution; Haskell can be fast | Cloud‑latency variable | Cloud‑latency variable | Cloud‑latency variable | Potential for low‑latency local execution. |

### 4.1 Observed Gaps
- **No built‑in LLM‑powered code suggestion**: sarutahiko currently relies on external skills for code generation; it does not provide an integrated, real‑time suggestion engine.
- **Weak multimodal support**: No handling of images, audio, or other non‑text modalities.
- **Incomplete security supply‑chain**: TUF and Tor effects are designed but not coded.
- **Limited observability**: No tracing, metrics, or replay integrated into the REPL loop.

### 4.2 Strengths Relative to Competitors
- **Deterministic, type‑safe extensibility**: Skills are written in Haskell with full type safety, enabling provably correct extensions.
- **Effect‑system isolation**: Plugins declare their effects explicitly, reducing unintended side‑effects.
- **Agent delegation**: Ability to spawn sub‑agents for parallel work is unprecedented in mainstream REPLs.
- **Streaming‑first architecture**: Back‑pressure aware pipelines can handle large outputs without deadlock.

---

## 5. Prevailing Issues in AI Coding Assistant REPLs & Sarutahiko’s Mitigation

| Issue | Description | Sarutahiko Status |
|-------|-------------|-------------------|
| **Context drift / token limits** | Long sessions cause forgetting or hallucination due to limited context window. | Partially addressed via explicit memory tool and skill‑based persistence, but no automatic summarization or hierarchical context management. |
| **Tool latency & unreliability** | External tool calls (e.g., web search, terminals) can hang or fail. | Hermes provides timeouts and background processes; however, no built‑in retry policies or circuit‑breaker patterns are standardized. |
| **Over‑reliance on probabilistic LLMs** | Leads to non‑deterministic output, licensing concerns, and safety risks. | Sarutahiko can avoid LLMs entirely by using skills written in Haskell; adoption depends on user discipline. |
| **Data privacy & code leakage** | Cloud‑based REPLs may expose proprietary code. | Local‑first design; data remains on‑device unless explicit delivery chosen. |
| **Supply‑chain attacks via plugins** | Malicious extensions can compromise the host. | Planned TUF verification for skill distribution; not yet implemented. |
| **Lack of observability** | Hard to debug why an agent behaved a certain way. | Missing observability effect; logs exist but are unstructured. |
| **Poor error propagation** | Vague error messages hinder troubleshooting. | Error types exist (e.g., `JsonRpcError`) but often lack stack traces or context. |

### 5.1 Recommendations to Close Gaps
1. **Implement a hierarchical memory engine** (per `MEMORY_ENGINE_DESIGN.md`) that automatically summarizes old turns and stores salient facts.
2. **Standardize tool contracts with retry, timeout, and circuit‑breaker policies** in the `Process` and `Effect` layers.
3. **Provide an optional LLM‑skill bridge** (e.g., a skill that calls a local LLM via an effect) for users who want probabilistic suggestions while preserving the ability to disable it.
4. **Add multimodal input effects** (`ImageInput`, `AudioInput`) and corresponding codecs in `kogaki-wire`.
5. **Complete the TUF and Tor effects** per `PROTOCOL_LIBRARIES_INTEGRATION.md` and integrate them into the skill‑fetch and agent‑communication pathways.
6. **Deploy the observability effect** (`kagami-ita`) to emit structured events, traces, and metrics; expose a REPL command to view recent traces.
7. **Enrich error effects with call‑stack context** (similar to `effectful`'s `Error` with `HasCallStack`) and propagate them through the MCP/JSON‑RPC layers.

---

## 6. Conclusion

Sarutahiko achieves a high degree of design fidelity in its core architecture—especially the effect system, record‑based data modeling, streaming foundations, and the MCP protocol implementation. However, the project falls short in translating its ambitious design notes into a fully-featured, user‑ready AI coding assistant REPL. Documentation drift, missing observability and security components, and the absence of an integrated, LLM‑powered suggestion engine prevent it from competing feature‑for‑feature with mainstream offerings.

Addressing the recommendations above—particularly implementing the memory engine, observability, TUF/Tor effects, and enriching the REPL UI with multimodal and suggestion capabilities—will bring sarutahiko closer to its vision of a composable, secure, and observable agent platform while retaining its unique strengths in type safety, extensibility, and deterministic code generation.

--- 

*End of Review*