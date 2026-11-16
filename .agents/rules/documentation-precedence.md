<!--
SPDX-License-Identifier: EUPL-1.2 OR Apache-2.0
-->
# Documentation Policy & Precedence Rules

**Status:** ACTIVE RULE · Bounded Context Extension  
**Canonical Specification:** [`docs/notes/DOC_STRATEGY.md`](../../docs/notes/DOC_STRATEGY.md)  
**Corpus Inventory:** [`docs/INDEX.md`](../../docs/INDEX.md)  
**Session Loop:** [`PLAN.md`](../../PLAN.md) · [`STATE.md`](../../STATE.md)

---

## 1. The Precedence Rule (`DOC_STRATEGY.md` §4)

> **Code wins at runtime; the note must be corrected regardless.**  
> A behaviour change without a note correction is an incomplete change. Blessed notes are not granted advisory status.

1. **Design notes are load-bearing:**
   - If an implementation change alters types, paths, solver algorithms, or representation layouts described in `docs/notes/`, update the corresponding note in the **same commit**.
2. **Open questions (§7) are deliberate:**
   - Do not unilaterally settle open design questions in code without explicit maintainer blessing. The unrealized surface is guarded by design.

---

## 2. Context Budgets & Orientation Projections

1. **`AGENTS.md` ~4 KB Budget:**
   - `AGENTS.md` is an orientation projection file, not a repository of rules or specs.
   - Never inflate `AGENTS.md` with inlined rule text or tutorial material. Add links, not content.
2. **The Two-File Loop (`PLAN.md` & `STATE.md`):**
   - Fresh sessions initialize operational context from `PLAN.md` and `STATE.md`.
   - Update `STATE.md` before ending or resetting any session to preserve the operational frontier.

---

## 3. Living Registers & Inventories

- Documents under `docs/registers/` (e.g., `PACKAGES.md`) and provenance records (`THIRD_PARTY.md`, `PROVENANCE.md`) are **append-only living registers**.
- Changes to package layouts, licences, or dependencies must register updates in these ledgers in the same change set.
