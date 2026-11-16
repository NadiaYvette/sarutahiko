<!--
SPDX-License-Identifier: EUPL-1.2 OR Apache-2.0
-->
# Typechecker Plugin Invariants

**Status:** ACTIVE RULE · Bounded Context Extension  
**Canonical Specification:** [`docs/MAINTAINER_GUIDE.md`](../../docs/MAINTAINER_GUIDE.md) §2  
**Implementation:** [`packages/polytropos-plugin/src/Polytropos/Plugin.hs`](../../packages/polytropos-plugin/src/Polytropos/Plugin.hs)  
**Specification Tests:** [`packages/polytropos-core/test/Main.hs`](../../packages/polytropos-core/test/Main.hs)

---

## 1. Literal Evidence & Zero Type-Level Search

1. **Emit literal constants only:**
   - The TcPlugin solves `FieldIndex` and `ConstructorIndex` by directly computing the literal `Int` or `Word` offset.
   - Never emit recursive type-level search evidence or inductive dictionary trees.
2. **The handwritten tests are the specification:**
   - The instances in `packages/polytropos-core/test/Main.hs` specify what the plugin must synthesize. A test or plugin implementation that performs type-level search breaks the core design invariant (D3 / compile-time scalability).

---

## 2. Core AST Dictionary Synthesis Invariants

1. **Direct Core AST Construction:**
   - For `RowEq` and `RowShow`, synthesize Core dictionary bindings directly in `tcPluginSolve`.
   - Access payload slots from `repVals` via `indexSmallArray#` at literal offset indices.
2. **Avoid GHC Selector Mangling (`$sel:...`):**
   - Do not query or generate GHC record selector IDs (which mangle names to `$sel:<field>:<Record>`).
   - Use exported top-level accessors (`unRowRep`, `repVals`, `repTag`) or direct constructor deconstruction.
3. **GHC 9.14 Module Resolution:**
   - In GHC 9.14+, base types and primitives originate in `GHC.Internal.*` modules (e.g. `GHC.Internal.Data.Foldable`, `GHC.Internal.Show`). Lookups must account for internal module origins.
