# `sarutahiko-tooling` — Honorary Assistant Environment Package

**Status:** Active Bootstrapping Environment · Governed under [`docs/notes/DOC_STRATEGY.md`](../docs/notes/DOC_STRATEGY.md)  
**Canonical Specification:** [`docs/notes/ASSISTANT_TOOLING_DESIGN.md`](../docs/notes/ASSISTANT_TOOLING_DESIGN.md)  
**Orientation Projection:** [`AGENTS.md`](../AGENTS.md)  

---

## 1. Package Purpose

`sarutahiko-tooling` is an **honorary package** within the `sarutahiko` repository. While it does not publish a Cabal library to Hackage, it maintains strict package-grade contracts:
1. **Zero-Contamination Boundary:** It operates strictly out-of-process via stdio IPC, JSON-RPC (MCP), or local CLI scripts. It never injects external dependencies or version bounds into `cabal.project` or core `packages/`.
2. **Progressive Disclosure:** Quiescent token consumption in AI coding assistant prompts is near-zero; tools and runbooks load strictly on-demand.
3. **Graceful Degradation:** The repository always builds, tests, and runs under the **Tier 0 POSIX Baseline** (`cabal`, `git`, standard shell) without requiring any daemon or external binary.

---

## 2. The Degradation Hierarchy

```
Tier 3: Semantic MCP & Background Daemons (tricorder-mcp, contextful, HLS) [Optional Acceleration]
   ▲
Tier 2: Structural Syntax Matching (ast-grep, tsquery, tree-sitter) [Optional Precision]
   ▲
Tier 1: Shallow Symbol Index (hasktags via bin/generate-tags) [Lightweight, Instant Jump]
   ▲
Tier 0: Vanilla POSIX Baseline (cabal, git, standard POSIX utilities) [MANDATORY INVIOLABLE FLOOR]
```

---

## 3. Bootstrapping Tool Suite

Until `sarutahiko` self-hosts with in-tree components (`sarutahiko-mcp`, `utaibon`, `sarutahiko-parse`), the tooling environment provides immediate developer acceleration via a curated bootstrapping suite:

| Component | Skill / Config | Role & Value |
|---|---|---|
| **Tweag's Tricorder** | [`.agents/skills/tricorder/SKILL.md`](skills/tricorder/SKILL.md) / [`.mcp.json`](../.mcp.json) | Background GHCi compiler diagnostics in $<50$ JSON tokens (slashes token burn by >95%). |
| **Hasktags** | [`.agents/skills/code-navigation/SKILL.md`](skills/code-navigation/SKILL.md) / [`bin/generate-tags`](../bin/generate-tags) | Instant symbol definition jump in $<15$ tokens (`grep -w "^Symbol" tags`). |
| **AST-Grep (`sg`)** | [`.agents/skills/code-navigation/SKILL.md`](skills/code-navigation/SKILL.md) | Syntax tree queries for GADT effects, row-type records, and interpreter handlers. |
| **Nadeem's Shikumi** | [`.agents/skills/shikumi/SKILL.md`](skills/shikumi/SKILL.md) | Hierarchical LM program tracing, offline trace recording, and deterministic replay (`shikumi replay`). |
| **Contextful** | [`.agents/skills/contextful/SKILL.md`](skills/contextful/SKILL.md) | SQLite FTS5 (BM25) search and token-budgeted evidence pack generation. |

---

## 4. Self-Hosting Roadmap

1. **Phase 0 & 1 (Current):** Bootstrapping suite active. Codebase authoring uses `tricorder-mcp`, `hasktags`, and `ast-grep`.
2. **Phase 1.5 (Hokora Vertical Slice):** In-tree SQLite event spine, fail-closed leases, and RPL-1 deterministic replay harness replace external session stores.
3. **Phase 2 & 3 (Full Self-Hosting):**
   - `sarutahiko-mcp` replaces external MCP wrappers.
   - `utaibon` (in-tree event memory with embedded SQLite FTS5 + `sqlite-vec`) replaces external vector/search daemons.
   - `sarutahiko-parse` (in-tree Wagner-Graham incremental GLR / Earley chart parser) replaces external tree-sitter tools.
