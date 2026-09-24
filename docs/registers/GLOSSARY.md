# docs/registers/GLOSSARY.md — Term Index

Status: LIVING DOCUMENT · v0.1 · 2026-09-24 (per DOC_STRATEGY §6, decided 2026-09-24)

A term *index*, not a restating authority: one-line definitions plus links to each
term's canonical home (the defining document stays canonical, per §1). Entries are
added in the same change as the term's introducing document; the script net checks
link targets. First-use rule in prose (§7): kanji + romaji + gloss.

## Program and corpus

- **sarutahiko** (猿田彦) — the program; guiding kami at the threshold, the Hermes analogue. → `../notes/NIH_PLAN.md` §1
- **keiro-comparison thesis** — the framing that sarutahiko answers the keiro ecosystem's first iterations with advanced design principles. → `../notes/DOC_STRATEGY.md` §9
- **doc-drift judge** — the LLM assessment instrument checking corpus↔code consistency; advisory authority, findings as rows. → `../notes/DOC_STRATEGY.md` §2
- **script net** — the zero-LLM mechanical check layer (link resolution, inventory completeness) beneath the judge. → `../notes/DOC_STRATEGY.md` §5
- **genre suffix** — `_DESIGN`/`_SPEC`/`_REGISTER`/…, governing within `docs/notes/`. → `../notes/DOC_STRATEGY.md` §5
- **prospective reference** — a reference to planned-but-unborn work; dormant, not a dead link, until its birth event. → `../notes/DOC_STRATEGY.md` §4
- **implemented-map** — the per-package sub-stamp of partial realization in a Status header. → `../notes/DOC_STRATEGY.md` §4
- **partial-realization shield** — the declarative, auditable, expiring suppression grant for unrealized design surface. → `../notes/DOC_STRATEGY.md` §4

## Effects and rows

- **capability row** — the effect row as a compile-time grant set (`Granted :<: es`). → `../notes/EFFECT_CATALOG_DESIGN.md`
- **`SomeRow`** — the existentially packaged row carried by row-emitting effects (`Log`, `EventBus`, `HookDispatch`). → `../notes/EFFECT_CATALOG_DESIGN.md`
- **PVP-for-signatures** — additive evolution policy for GADT effect signatures (new signatures + reinterpretation + deprecation windows). → `../notes/EFFECT_CATALOG_DESIGN.md`
- **typed message** — user-facing text as message constructors (data), rendered per-locale at the presentation edge; no display-string literals in core code. → `../notes/DOC_STRATEGY.md` §6
- **envelope** — the versioned, append-only event wrapper generalized from the memory log; row-decomposed so envelope-without-payload is a valid summary unit. → `../notes/OBSERVABILITY_DESIGN.md` §3
- **cursor / stepper** — existentially packaged, `m`-parameterized traversal handles exposed by signatures instead of streams. → `../notes/HASHIGAKARI_DESIGN.md` §3.4

## Layers and packages

- **yamaarashi** (山嵐) — the conduit/porcupine/streamly hybrid streaming stack. → `../notes/YAMAARASHI_DESIGN.md`
- **hashigakari** (橋掛かり) — the database access library; the bridge onto the stage. → `../notes/HASHIGAKARI_DESIGN.md`
- **utaibon** (謡本) — the memory/context engine; the libretto the performance follows. → `../notes/MEMORY_ENGINE_DESIGN.md`
- **spine v0.2** — the core log fields always present; the one least-reversible decision above the substrate. → `../notes/MEMORY_ENGINE_DESIGN.md` §3.1
- **PolicyEffect** — policy decisions as a typed effect (cache safety, salience, compression); never sampled. → `../notes/MEMORY_ENGINE_DESIGN.md` §5.1.4
- **utai** (謡) — the LLM layer; *vox calculi*. → `../notes/LLM_SUBSTRATE_DESIGN.md`
- **kakegoe** (掛け声) — the policy-experiment instruments; the calls coordinating the ensemble. → `../notes/INSTRUMENTS_SPEC.md`
- **kagami-ita** (鏡板) — the observability & serviceability layer; the mirror-board. → `../notes/OBSERVABILITY_DESIGN.md`
- **hokora** (祠) — the Phase-1.5 vertical validation slice. → `../notes/HOKORA_SPEC.md`
- **C1–C6** — the cross-dialect ordering contract on the log substrate. → `../notes/MEMORY_ENGINE_DESIGN.md` §3.4
