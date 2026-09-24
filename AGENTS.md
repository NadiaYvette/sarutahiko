# AGENTS.md — Advisory Context for AI Coding Assistants

Audience: AI coding assistants (Codebuff, and any tool reading the AGENTS.md
convention). This file is an *orientation projection* per `docs/DOC_STRATEGY.md` §1 —
it points at canonical sources rather than restating them; when this file and a
canonical document disagree, the canonical document wins.

## What this repository is

`sarutahiko` — a Haskell program reimplementing an AI-assistance ecosystem (agent
core, surfaces, protocols, formats, code intelligence, database access) on
extensible records (large-anon/large-records), row-typed algebraic effects, and the
yamaarashi streaming stack. The design corpus in `docs/` is the institutional memory;
code implements blessed designs.

## Read first (in this order)

1. `README.md` — build/run one-liners.
2. `docs/INDEX.md` — corpus inventory and reading map (DOC_STRATEGY §5).
3. `docs/notes/NIH_PLAN.md` — the program: decisions taken (§0), package map (§2),
   contracts (§3), roadmap (§4), naming registry (§6.1).
4. The design note for whatever you're touching (see map below). Layout: `docs/notes/`
   (designs/specs), `docs/registers/` (living registers), `docs/imports/` (verbatim
   third-party material), `docs/transcripts/` (conversation archives).

## Canonical documents map

| Domain | Canonical | Notes |
|---|---|---|
| Program/decisions | `docs/notes/NIH_PLAN.md` | §0 decisions; §6 backlog |
| Streaming | `docs/notes/YAMAARASHI_DESIGN.md` | kernel API/backends, §3.6 layering |
| Database | `docs/notes/HASHIGAKARI_DESIGN.md` | row AST, dialect ceilings, cursors |
| Effect catalog | `docs/notes/EFFECT_CATALOG_DESIGN.md` | signatures, laws, capability rows |
| Memory/context | `docs/notes/MEMORY_ENGINE_DESIGN.md` | spine v0.2, ordering C1–C6, PolicyEffect |
| LLM substrate | `docs/notes/LLM_SUBSTRATE_DESIGN.md` | codec decision, renderer, laws L1–L4 |
| Hokora slice | `docs/notes/HOKORA_SPEC.md` | Phase 1.5 |
| Instruments | `docs/notes/INSTRUMENTS_SPEC.md` | cache simulator, replay harness |
| Reuse decisions | `docs/registers/REUSE_REGISTER.md` | check before adding dependencies |
| Infrastructure | `docs/notes/INFRASTRUCTURE.md` | toolchain, warnings, tests, CI, procedure |
| Codec quirks | `docs/registers/CODEC_QUIRKS.md` | living; fixture-backed rows |
| Documentation policy | `docs/notes/DOC_STRATEGY.md` | lifecycle, flags, canonicity |
| Corpus index | `docs/INDEX.md` | inventory + reading paths |

## Operational advisories (binding unless a canonical doc supersedes)

1. **Pushes are batched** — commit locally and frequently, but push only at session
   end or on maintainer request (`bin/push-all` when it exists). Never push per
   commit; never hammer rate-limited hosts (one retry after a cool-down, then stop).
   Hosting services' network/CPU are a shared resource (INFRASTRUCTURE §12).
2. **Design docs are load-bearing** — if your change makes a blessed document stale,
   update the document in the same change set (DOC_STRATEGY §4 precedence: code wins
   at runtime, but the note must be corrected, not ignored).
3. **Commits:** descriptive-imperative subject, body explains why, Codebuff footer,
   HEREDOC style (INFRASTRUCTURE §12).
4. **Toolchain:** GHC 9.14/cabal 3.18, GHC2024; features opt in via the cabal
   commons only (INFRASTRUCTURE §1). Formatting: brittany. Tests: tasty/hedgehog;
   new effect signatures land in BOTH interpreter packages or not at all
   (EFFECT_CATALOG §6.6 parity gate).
5. **Naming:** Noh-theatre registry governs (NIH_PLAN §6.1); check it before
   proposing package names; keep first-use format (kanji + romaji + gloss).
6. **Secrets/privacy:** no secrets in tree; corpora and fixtures follow the
   scrub-manifest rule (INSTRUMENTS_SPEC §2.4).
