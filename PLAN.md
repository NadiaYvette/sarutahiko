# PLAN.md — Canonical Engineering Roadmap & Architectural Invariants

Status: LIVING · Aligned with `docs/notes/NIH_PLAN.md` §4 and `docs/notes/HOKORA_SPEC.md`.  
Audience: Human maintainers and AI coding assistants (Antigravity, Hermes, Claude Code, Aider).  
Reset Rule: Fresh agent sessions must read this file alongside `STATE.md` before execution.

---

## 1. Architectural Invariants (The Inviolable Floor)

Every change across all packages must satisfy these six invariants:

1. **Toolchain & Language Baseline:** GHC 9.12.2 / Cabal 3.18, `default-language: GHC2024`. Warnings are errors (`-Wall -Werror`).
2. **Extensible Records over Ad-Hoc Types:** Core domain models use `large-anon` anonymous extensible records. No monolithic custom record definitions where open rows apply (`sarutahiko-fields`, `sarutahiko-records`).
3. **Anti-Aeson / Zero-Transitive Bloat:** No dependency on `aeson`. Wire serialization uses hand-rolled, zero-dependency `kogaki` row-typed codecs (`kogaki-core`, `kogaki-wire`).
4. **Streaming & Workflow Kernel:** Traversal handles across database, effect, and model layers unify under the canonical existential stepper `Stepper m a` (`docs/notes/EFFECT_CATALOG_DESIGN.md` §4) and `yamaarashi` element streams. Macro-workflows execute as Selective Applicative DAGs with static over-approximation and early cutoff (`yamaarashi-flow`, `yamaarashi-spec`).
5. **Dual Interpreter Doctrine & Façade Pattern:** Every effect signature must provide at least two interpreters (production + pure model, e.g. `effectful` and `polysemy`), verified by a Tasty/Hedgehog parity test (`EFFECT_CATALOG_DESIGN.md` §6.6). High-level consumers expose open tagless capability typeclasses (`Monad*`) with thin adapter modules binding them to the underlying GADTs.
6. **Unbounded Hierarchical Scope Nesting:** Scoped regions (`Region`), correlation lineage (`SpanPath`), and diagnostic ingestion (`ScopeStack`) must support arbitrary recursive finite depth without depth ceilings or flat-scope truncation.

---

## 2. Phased Roadmap Overview

```
Phase 0: Toolchain, Clean-Slate Commons & Spikes               [COMPLETED]
   ▼
Phase 1: Protocol Codecs & Algebraic Effect Catalog           [COMPLETED]
   ▼
Phase 1.5: Hokora Vertical Slice (Skinny Spine Proof)          [COMPLETED]
   ▼
Phase 2: Full Agent Core & Memory Engine (utaibon)            [COMPLETED]
   ▼
Phase 3: Observability & Surfaces (TUI, Gateway, ACP, Tags)    [COMPLETED]
   ▼
Phase 4: Data Tier & Protocol Codecs                           [COMPLETED]
   ▼
Phase 5: Self-Hosting & Full Native Orchestration              [NEXT]
```

---

## 3. Phase 1 Tactical Packages & Acceptance Criteria

Phase 1 establishes the row-typed protocol foundations:

| Package | Status | Acceptance Gate |
|---|---|---|
| `packages/sarutahiko-fields` | **DONE** | Canonical field definitions for rows. Builds clean under GHC2024. |
| `packages/sarutahiko-records` | **DONE** | `large-anon` wrappers, row projections, lens-like field combinators. |
| `packages/sarutahiko-jsonrpc` | **DONE** | Zero-dependency JSON-RPC 2.0 wire framing and error models. |
| `packages/sarutahiko-process` | **DONE** | Subprocess execution effect signature and streaming IO handlers. |
| `packages/sarutahiko-mcp` | **ACTIVE** | Model Context Protocol 2025-03-26 client/server implementation. |

### Immediate Milestone: `packages/sarutahiko-mcp` (TP-1.5)
- **Target Spec:** MCP version `2025-03-26` over JSON-RPC 2.0 stdio.
- **Components:**
  1. `Sarutahiko.MCP.Types`: Handshake types (`InitializeRequest`, `InitializeResult`), capabilities, and tool schemas.
  2. `Sarutahiko.MCP.Server`: Protocol server engine hosting agent tools.
  3. `Sarutahiko.MCP.Client`: Client engine for discovering and invoking external MCP tools (`tricorder-mcp`, `contextful`).
  4. **StateGuard Invariant:** Any request received prior to `notifications/initialized` must be rejected with JSON-RPC error code `-32600` (Invalid Request).
  5. **Verification Suite (`test-mcp`):** Hedgehog property test verifying StateGuard rejection gate.

---

## 4. Phase 1.5 Hokora Slice Acceptance (Vertical Slice) [COMPLETED]

1. Minimum viable autonomous turn execution (`docs/notes/HOKORA_SPEC.md`): **VERIFIED**
   - Autonomous ReAct program executing tools through conforming MCP server over JSON-RPC.
   - Session event stream logged to SQLite with blessed Spine v0.2 envelope.
   - Pure conversation-tail reducer folding event stream and computing deterministic prompt-cache prefix hash.
2. Skinny Spine Protocol: `ModelAPI` neutral signature + deterministic `utai-mock` interpreter: **VERIFIED**
   - Dual-carrier testing under `Eff es` and tagless capability typeclasses under the Façade Pattern.
   - 100% passing Hedgehog properties across `hashigakari-sqlite`, `utai`, and `hokora`.
3. Thesis measurement: **VERIFIED**
   - Hokora delivered full capability in **664 lines core / 891 total lines** (well within budget ≤2,000 lines).

---

## 5. Phase 2 Agent Core Acceptance [COMPLETED]

1. **Session Engine (`sarutahiko-session`):** **VERIFIED**
   - Session persistence (`utaibon` 謡本) backed by `hashigakari-sqlite`.
   - Pure conversation-tail reducer guaranteeing strict prompt-cache prefix preservation.
   - Deterministic `fnv1a64Hex` hashing and replay parity verified across database reloads.
2. **Hook Execution & Process Supervision (`sarutahiko-hooks`):** **VERIFIED**
   - External hook subprocess supervisor with fail-closed `sigKILL` hard deadline enforcement.
   - Safe mode consent checking and pre-approved command execution.
3. **Capability-Bounded Plugin System (`sarutahiko-plugins`):** **VERIFIED**
   - Plugin manifest parser adhering to zero-transitive-bloat Kogaki wire codecs.
   - Manifest validation against capability allowlists and kill-lists.
4. **Agent Core & Multi-Turn Turn Engine (`sarutahiko-agent`):** **VERIFIED**
   - Dynamic extensible-record tool registry (`ToolRegistry`).
   - Interpreted ReAct-style agent turn program with bounded iteration ($N \le 10$).
   - Multi-turn conversation persistence over SQLite event streams.
   - Standalone CLI executable `sarutahiko` supporting one-shot and multi-turn execution.
5. **Verification & Audit Gate:** **VERIFIED**
   - 16/16 Hedgehog properties passing 100% across all 4 packages with zero warnings under `-Wall -Werror`.
   - Verification script `scripts/tasks/phase2-agent-core-verify.sh` verified end-to-end.
   - Task packet `docs/task_packets/phase2-agent-core.yaml` verified via `yamaarashi-exec` using zero-cost native `utai` executor.

---

## 6. Phase 3 Surfaces & Code Intelligence Acceptance [COMPLETED]

1. **Terminal UI (`sarutahiko-tui`):** **VERIFIED**
   - Extensible record state (`TuiState`), declarative layout, streaming token rendering, keypress cancellation, and JSON-RPC 2.0 communication with agent core.
   - 6 Hedgehog properties passing 100%.
2. **Multi-Platform Chat Gateway (`sarutahiko-gateway`):** **VERIFIED**
   - Telegram, Discord, Slack, and Webhook adapter matrix via `GatewayEffect`, bracketed streaming, and tagless capabilities.
   - 4 Hedgehog properties passing 100%.
3. **Agent Client Protocol Adapter (`sarutahiko-acp`):** **VERIFIED**
   - Stdio JSON-RPC adapter for Zed/editor integration with initialization handshake and tool dispatch.
   - 4 Hedgehog properties passing 100%.
4. **Scope-Stack Tag Extractor (`sarutahiko-tags`):** **VERIFIED**
   - Fast scope-stack symbol tag extractor for Haskell and C emitting Vi/Ex and Universal Ctags JSON Lines format.
   - Standalone CLI executable `sarutahiko-tags`.
   - 4 Hedgehog properties passing 100%.
5. **Verification & Audit Gate:** **VERIFIED**
   - 18/18 Hedgehog properties passing 100% across all 4 packages with zero warnings under `-Wall -Werror`.
   - Verification script `scripts/tasks/phase3-surfaces-codeintel-verify.sh` verified end-to-end.
   - Task packet `docs/task_packets/phase3-surfaces-codeintel.yaml` verified via `yamaarashi-exec` using zero-cost native `utai` executor.

---

## 7. Phase 4 Data Tier & Protocol Codecs Acceptance [COMPLETED]

1. **Row-Typed Relational Query AST (`hashigakari-core`):** **VERIFIED**
   - Typed relational query AST (`Select`, `Projection`, `Where`, `Join`, `Table`, `Filter`, `OrderBy`, `Limit`, `Offset`), column descriptors, and RFC 7396 TriState patch algebra with round-trip diff/apply properties.
   - 4 Hedgehog properties passing 100%.
2. **Dialect-Indexed SQL Compilation (`hashigakari-syntax`):** **VERIFIED**
   - Dialect compilation for PostgreSQL, SQLite, and MySQL targets; compile-time capability ceilings via `Supports` type family; minimal TriState UPDATE statement generation.
   - 5 Hedgehog properties passing 100%.
3. **Scaled Multi-Worker PostgreSQL Streaming (`hashigakari-hasql`):** **VERIFIED**
   - Thread-safe connection pool with bracketed leases (`withHasqlPool`), existential `Stepper IO (Record Identity r)` query streams, `HasqlEffect` GADT, and `MonadHasql` capability class.
   - 4 Hedgehog properties passing 100%.
4. **Row-Typed Dhall Configuration Bridge (`sarutahiko-format-dhall`):** **VERIFIED**
   - Total, dependency-light Dhall record parser and evaluator bridging typed Dhall records directly into `large-anon` rows (`evalDhallRow`) without intermediate Aeson ASTs.
   - 4 Hedgehog properties passing 100%.
5. **Verification & Audit Gate:** **VERIFIED**
   - 17/17 Hedgehog properties passing 100% across all 4 packages with zero warnings under `-Wall -Werror`.
   - Strict Zero-Aeson compliance and zero partial functions verified across all Phase 4 packages.
   - Verification script `scripts/tasks/phase4-data-protocol-verify.sh` verified end-to-end.
   - Task packet `docs/task_packets/phase4-data-protocol.yaml` executed and verified via `yamaarashi-exec` using zero-cost native `utai` executor.



