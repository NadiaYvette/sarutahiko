<!--
SPDX-License-Identifier: EUPL-1.2 OR Apache-2.0
-->
# Compiler Diagnostics & Test Verification Rules

**Status:** ACTIVE RULE · Bounded Context Extension  
**Canonical Specification:** [`docs/MAINTAINER_GUIDE.md`](../../docs/MAINTAINER_GUIDE.md) §1  
**Skill Reference:** [`.agents/skills/tricorder/SKILL.md`](../skills/tricorder/SKILL.md)  
**Configuration:** [`.agents/mcp.json`](../mcp.json) · [`.mcp.json`](../../.mcp.json)

---

## 1. Zero-Log Diagnostics Verification

Raw `cabal build` output dumps thousands of tokens into prompt history on every invocation. Assistants should verify changes using minimal-token compiler status queries:

1. **Background GHCi Diagnostics ($<50$ tokens):**
   - Query status via `tricorder status --json` or the `tricorder` MCP server (`status(wait: true)`).
   - Returns structured JSON error counts, file paths, and exact diagnostic messages without noise.
2. **Test Suite Verification:**
   - Run `cabal test all` to verify all test suites:
     - `polytropos-core:test:polytropos-core-test` (25 tests for representation, indexing, mutation, projection, matching).
     - `polytropos-plugin:test:smoke` (smoke tests validating plugin Core AST dictionary synthesis).

---

## 2. The Zero-Contamination Doctrine

1. **Never edit `cabal.project` or `.cabal` files for tooling:**
   - Assistant tools (`tricorder`, `contextful`, `hasktags`, `ast-grep`) must remain strictly out-of-process.
   - Do not add Cabal dependencies or flags for assistant tools.
2. **Tier 0 POSIX Baseline Floor:**
   - A fresh clone without any background daemons or external tools installed must always be able to run `cabal build all` and `cabal test all` successfully.
