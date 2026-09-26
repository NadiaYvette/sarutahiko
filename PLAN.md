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
4. **Streaming Kernel:** Traversal handles across database, effect, and model layers unify under the canonical existential stepper `Stepper m a` (`docs/notes/EFFECT_CATALOG_DESIGN.md` §4), which unrolls into `yamaarashi` element streams.
5. **Dual Interpreter Doctrine & Parity Gate:** Every effect signature must provide at least two interpreters (production + pure model, e.g. `effectful` and `polysemy`), verified by a Tasty/Hedgehog parity test (`EFFECT_CATALOG_DESIGN.md` §6.6).
6. **Unbounded Hierarchical Scope Nesting:** Scoped regions (`Region`), correlation lineage (`SpanPath`), and diagnostic ingestion (`ScopeStack`) must support arbitrary recursive finite depth without depth ceilings or flat-scope truncation.

---

## 2. Phased Roadmap Overview

```
Phase 0: Toolchain, Clean-Slate Commons & Spikes               [COMPLETED]
   ▼
Phase 1: Protocol Codecs & Algebraic Effect Catalog           [IN PROGRESS - TP-1.5 NEXT]
   ▼
Phase 1.5: Hokora Vertical Slice (Skinny Spine Proof)          [QUEUED]
   ▼
Phase 2: LLM Substrate (utai) & Memory Engine (utaibon)       [QUEUED]
   ▼
Phase 3: Observability (kagami-ita) & Surfaces (Rich TUI)      [QUEUED]
   ▼
Phase 4: Code Intelligence & Typed Model Arena                 [QUEUED]
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

## 4. Phase 1.5 Hokora Slice Acceptance (Vertical Slice)

1. Minimum viable autonomous turn execution (`docs/notes/HOKORA_SPEC.md`).
2. Skinny Spine Protocol: `ModelAPI` neutral signature + deterministic `utai-mock` interpreter.
3. Doc-drift judge verification.
