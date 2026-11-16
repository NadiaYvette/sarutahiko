<!--
SPDX-License-Identifier: EUPL-1.2 OR Apache-2.0
-->
# Operational Rule: Kioku Memory & Context Offloading Loop

**Status:** ACTIVE RULE · Bounded Context Extension  
**Memory Substrate:** `shinzui kioku` (PostgreSQL `postgresql:///kioku`)  
**CLI Tools:** `/home/nyc/.local/bin/kioku` · `/home/nyc/.local/bin/kioku-remember`  
**Session Loop:** [`PLAN.md`](../../PLAN.md) · [`STATE.md`](../../STATE.md) · [`AGENTS.md`](../../AGENTS.md)

---

## 1. Context Trimming & Quota Preservation Mandate

Accumulating conversation turns in multi-package workspaces increases token overhead on every turn.

To arrest quota drain while retaining high-fidelity recall:

1. **Offload Durable Context:** Before session resets or at `PLAN.md` / `STATE.md` synchronization points, offload decisions, architectural discoveries, and verified invariants using `kioku-remember`:
   ```bash
   kioku-remember "Tengri savdag socket daemon listens on $XDG_RUNTIME_DIR/tengri.sock" --tags "architecture,savdag"
   ```
2. **Update the Two-File Loop:** Reflect active frontiers in `PLAN.md` and `STATE.md`.
3. **Compaction Cadence:** Once offloaded, recommend or trigger `/compact` every 40–50 turns or immediately upon completing a task packet to shed obsolete conversational history.
4. **Recall On-Demand:** Retrieve stored facts with `kioku recall`:
   ```bash
   kioku recall "<query>" --namespace-wide antigravity --strategy keyword
   ```

---

## 2. Distinction from `open-kioku`

- **`open-kioku` (`ok`):** Code navigation, definitions, references, AST symbol graph in `.ok/`.
- **`shinzui kioku` (`kioku`):** Agent memory, session turns, distilled scenes (L2), persona (L3), and keyword/hybrid memory retrieval in PostgreSQL `postgresql:///kioku`.
