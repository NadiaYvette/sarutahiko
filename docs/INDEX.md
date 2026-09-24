# docs/INDEX.md — Corpus Inventory and Reading Map

Status: LIVING DOCUMENT · v0.1 · 2026-09-24 (per DOC_STRATEGY §5, decided 2026-09-24)

The index has two parts per §5's hybrid decision: an **inventory table** (generated
from Status headers — the script net that regenerates and checks it is pending; until
then it is maintained by hand under the same discipline) and **reading paths** for the
three audiences of DOC_STRATEGY §1. Tier is *index metadata only* — no filenames or
directories encode it (§5). ID citations are canonical; relative links are convenience
and are checked by the script net (§5).

## Part 1 — Inventory

| Path | Genre | Stage | Tier | Flags |
|---|---|---|---|---|
| `notes/NIH_PLAN.md` | plan | draft | cross-cutting | — |
| `notes/DOC_STRATEGY.md` | strategy | seed | cross-cutting | — |
| `notes/INFRASTRUCTURE.md` | strategy | draft (blessed as start) | cross-cutting | — |
| `notes/EFFECT_CATALOG_DESIGN.md` | design | draft | substrate | — |
| `notes/FIELDS_RECORDS_DESIGN.md` | design | draft | substrate | — |
| `notes/YAMAARASHI_DESIGN.md` | design | draft | streaming | — |
| `notes/HASHIGAKARI_DESIGN.md` | design | draft | database | — |
| `notes/MEMORY_ENGINE_DESIGN.md` | design | draft | memory | — |
| `notes/LLM_SUBSTRATE_DESIGN.md` | design | draft | model | — |
| `notes/HOKORA_SPEC.md` | spec | draft | cross-cutting (vertical slice) | — |
| `notes/INSTRUMENTS_SPEC.md` | spec | draft | cross-cutting (measurement) | — |
| `notes/OBSERVABILITY_DESIGN.md` | design | draft | cross-cutting (observability) | — |
| `registers/REUSE_REGISTER.md` | register | living | cross-cutting | — |
| `registers/CODEC_QUIRKS.md` | register (living) | living | model | — |
| `registers/GLOSSARY.md` | register (term index) | living | cross-cutting | — |
| `imports/HERMES_DESIGN.md` | import | static | cross-cutting | — |
| `imports/hermes_components.*` | import (diagrams) | static | cross-cutting | — |
| `transcripts/gemini-effect-algebras.md` | transcript | archive | cross-cutting | — |
| `transcripts/gemini-rows-for-mcp-lsp.md` | transcript | archive | cross-cutting | — |
| `transcripts/web-style-guides.md` | transcript | archive | cross-cutting (style survey) | — |

Archived: none (the tombstone register, `registers/ATTIC.md`, will list dead
documents here when any exist; superseded documents stay in place with successor
links — no archive directory per §5).

Planned, not yet written (the pre-birth frontier — prospective references to these
are *dormant*, not dead links, per DOC_STRATEGY §4): `registers/ATTIC.md`; the
tutorial track (`docs/tutorial/`); the glossary (`registers/GLOSSARY.md`).

## Part 2 — Reading paths

**Arrivals (orientation).** `README.md` → this index → the package map in
`notes/NIH_PLAN.md` §2 → `notes/HOKORA_SPEC.md` (the Phase-1.5 vertical slice is the
fastest honest view of what the program is building) → the design note for whatever
drew you here. The tutorial track (`docs/tutorial/`, scaled-textbook genre) is
planned and will become the recommended entry point when written.

**API consumers.** Haddock is canonical for laws once packages exist (§1 canonicity
table); until then, the law inventories live in `notes/EFFECT_CATALOG_DESIGN.md`
(L1–L4 for `ModelAPI`, catalog laws) and `notes/LLM_SUBSTRATE_DESIGN.md`. Quirk IDs
(`Q…`) resolve in `registers/CODEC_QUIRKS.md`.

**Maintainers (the corpus, in dependency order).** `notes/NIH_PLAN.md` (the program)
→ `notes/EFFECT_CATALOG_DESIGN.md` (the load-bearing abstraction) → the domain notes
in tier order (substrate → streaming → database → memory → model) → the specs
(hokora, instruments) → the registers (check before every dependency and every
provider integration) → `notes/DOC_STRATEGY.md` + `notes/INFRASTRUCTURE.md` (how the
corpus and the toolchain themselves are governed).
