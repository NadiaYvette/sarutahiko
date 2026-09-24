# The Documentation Strategy

Status: SEED · v0.1 · 2026-09-24 — the issue space recorded before policy decisions;
each section becomes a policy decision with rationale as the maintainer and agent work
through them. Companion to `INFRASTRUCTURE.md` §6 (which holds the tooling slice:
Haddock enforcement, the four layers) — this document owns the *policy*.
Related: `NIH_PLAN.md` (the corpus's origin), `REUSE_REGISTER.md` (register discipline),
`EFFECT_CATALOG_DESIGN.md` (laws), `CODEC_QUIRKS.md` (living-document precedent)

---

## 0. What this document is

The program's documentation corpus is already operating (ten-plus design notes, three
living registers, blessed-decision marks, a Noh naming registry) but its *policies* are
implicit. This seed records the issue space as seen before decisions land; as each
policy is decided, its section here is rewritten from "issue" to "decision + rationale."
The document is itself the first exemplar of the lifecycle rules it will define.

## 1. The audience map is triple — decide which document is canonical per fact class

Three audiences want different documents: **arrivals** (orientation: what the program
is, the mountain metaphor, the map), **API consumers** (Haddock: signatures, laws,
examples — including external consumers: hashigakari-beam users, smirk, the cross-REPL
products), and **maintainers** (the design corpus: rationale, adversarial review
records, decision provenance). The same fact — e.g. the cache-safety contract — is
wanted by all three in different forms. *Policy needed:* for each fact class (laws,
wire quirks, decisions, naming, procedures), which document is canonical and which
documents are projections.

*Current de facto:* design notes canonical for rationale; haddock will be canonical
for laws (per INFRASTRUCTURE §6.1); the naming registry (NIH_PLAN §6.1) canonical for
names.

## 2. Single-source-of-truth and drift

Planned duplications already exist: laws (catalog note ↔ haddock ↔ property tests),
quirks (CODEC_QUIRKS ↔ fixtures ↔ codec haddocks), naming (registry ↔ READMEs ↔ cabal
synopses), decisions (INFRASTRUCTURE ↔ CI config ↔ cabal commons). Any fact written
twice drifts. *Policy needed:* per duplication class — which copy is authoritative;
whether secondary copies are generated or test-checked (e.g. law IDs referenced by
property tests; haddock links to note sections); and the repair procedure when a check
catches divergence.

## 3. Lifecycle and authority

De facto states exist (draft → review → blessed → implemented → revised) but are
unformalized. *Policy needed:* transition rules; what blessing means mechanically (the
corpus's practice: a dated status edit recording the maintainer's decision); and
**revision-in-place vs new document** when reality diverges — the LLM substrate
v0.1→v0.2 precedent (revision in place, correction-of-record, the maintainer's
challenge preserved as part of the history) versus fresh documents; how much history
is preserved (the quirk inventory's append-only rule with "fixed as of" notes may or
may not generalize).

## 4. The rot problem — design ahead of code

The program's procedure is *designs flow down the mountain, stone flows up*: most notes
describe unbuilt systems. Failure mode: a blessed note silently diverging from the code
that eventually implements it. *Policy needed:* the "implemented" marker (who stamps
it, when); whether blessed notes are load-bearing (must be updated in the same PR as
behavior changes) or advisory; and the precedence rule when note and code disagree.

## 5. Structure and discoverability

`docs/` is flat with ten-plus documents and growing (REUSE_REGISTER already anticipates
reorganizing to `docs/decisions/`). *Policy needed:* an index with a map (what to read
in what order for arrivals); naming conventions for standing documents (registers,
inventories) vs point-in-time notes; the archive rule (when a document moves aside);
whether notes map onto the package tiers; cross-reference conventions that survive all
five mirrors (relative links — verified to resolve in every renderer we're mirrored
on).

## 6. Rendering and build infrastructure

*Policy needed:* Haddock specifics beyond warnings-as-failures (module intros; a laws
presentation format; combined-program haddock with `--hoogle` vs per-package);
markdown corpus rendering (plain everywhere vs a generated docs site — noting five
mirrors, so what is canonical when renderings differ); diagrams (ASCII renders
everywhere; mermaid only on some hosts); and the **glossary** — the program's
vocabulary is growing fast (spine, envelope, witness registry, decision, PolicyEffect,
cursor, stepper, tier, bundle, hokora, …) and needs a canonical glossary with a
maintenance owner.

## 7. Terminology and style control

The Noh registry must be used consistently (first-use rule: kanji + romaji + gloss per
document). The corpus has de facto developed a dense, rationale-first, table-heavy
style. *Policy needed:* codify the style or leave it to osmosis; voice rules; the
relationship between the naming registry and prose usage.

## 8. Co-authorship and authority

Unusual to this program: the design corpus is **AI-drafted and maintainer-blessed**.
*Policy needed:* say so explicitly, and define what blessing certifies (that the
maintainer read, challenged where needed, and owns the content — the session's
challenge-and-amend record is the intended pattern); the rules for future contributors
(human-drafted proposals land under the same review; CI gates apply to docs).

## 9. Exposure policy — public mirrors

The GitHub mirror is **public**, and the corpus contains evaluative analysis of another
person's ecosystem by name (the "answer to Nadeem" framing — respectful, but named and
public), local paths (`~/src/…`), references to private repositories, and internal
decision history. The maintainer has committed all of it knowingly; *policy should make
that a decision rather than an accident*: what is safe to publish; whether any document
class ever gets a private/no-mirror treatment; the review rule for newly public-bound
content; and the cross-ecosystem diplomacy stance (named analysis of others' work).

## 10. Boundaries with adjacent artifacts

*Policy needed:* CHANGELOGs (PVP-tied — decided in INFRASTRUCTURE §6.3, cross-referenced
here); ADR correspondence (our design notes *are* architecture decision records, richer
than the ADR format — name that and decline foreign formats); TODOs/trackers (notes
currently carry open items in trailing sections — keep, or does a tracker own them?);
the benchmark ledger (row-typed store, separate artifact); corpora/fixture
documentation (owned by kakegoe).

## 11. The measurement interaction

LOC budgets (hokora ≤2k) and the maintenance-burden thesis: documentation is real
maintenance burden too, but counting it against core-LOC budgets would distort the
comparison. *Policy needed:* docs live outside LOC budgets — and the documentation
*intensity* of the program (rationale living in prose, code small) should be a visible
number, because it is part of the answer-to-Nadeem argument rather than a hidden cost.

## 12. Decision log

| Date | Decision |
|---|---|
| 2026-09-24 | Seed created: §1–§11 recorded as open issues; policy decisions to be logged here as they land. |
