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

## 1. The audience map — DECIDED 2026-09-24: three audiences, three document genres

All three audiences get purpose-built documents, with canonicity per fact class:

**Arrivals → tutorials: a scaled textbook, machine-authored.** Not mere orientation
pages: a *textbook scaled to the project* — chapters with worked code examples that run
against the real packages, and **exercises designed in the maths-textbook tradition**:
problems whose *solutions still force enlightenment* — answers (including AI-assisted
ones) demand enough surrounding explanation that understanding the solution is itself
the exercise. Concretely: exercises carry solution sections written as explanations,
with the worked code in the tutorial's own runnable examples directory; AI-assisted
answering is expected and embraced — the exercise design makes the explanation, not the
answer, the deliverable. **Machine leverage is explicit policy:** the program has
AI authorship available at will (the maintainer commands volumes); documentation
intensity is therefore *not* bounded by human writing time — tutorials, design
manifestos, and **tremendous, highly explanatory API tomes** (not terse references)
are all in scope, with the human effort going to curation, challenges, and blessing
per §8's authority policy. Home: `docs/tutorial/` with a runnable examples directory
per chapter; grows as phases land.

**API consumers → verbose Haddock, deliberately richer than ecosystem convention.**
Policy points, per the maintainer:

- *Verbose but meaningful*: haddock runs to full paragraphs — laws stated, invariants,
  examples, failure behavior — with no minimum-length quota and no filler; the test is
  whether every sentence earns its place, and verbosity is the *default* rather than
  brevity.
- *Mathematical notation used properly.* Haddock renders no TeX; the program's practice:
  inline Unicode math (∀ es, O(n), r₁ ++ r₂ — already the corpus's style), and display
  math/diagrams as **rendered SVG figures included via haddock image markup**
  (`<<docs/figs/….svg>>`), generated from a checked-in source DSL rather than drawn by
  hand (candidates: mermaid → SVG pre-render, PlantUML, svgbob, or TikZ via a build
  script — choice deferred to first use; the check-in-source + render-to-SVG pattern is
  the decision).
- *Links used radically*: `--hyperlinked-source` for code-to-code navigation; URLs to
  academic papers (DOI/arXiv) wherever a design note cites a source (the corpus already
  carries citations — the Wagner–Graham paper, Well-Typed's large-records post);
  hyperlinks to sibling repos (kuroko, brittany, smirk, typed-protocols, the keiro
  stack) and to relevant webpages/specs (MCP spec sections, RFCs). Haddock's URL
  auto-linking plus explicit markup; the rule is that a claim with an external source
  *links to it*.

**Maintainers → the design corpus, with a whitepaper distillation in the telix genre.**
The notes/registers remain the working corpus (canonical for rationale and decisions).
Over it, the program produces **whitepapers**: LaTeX (lualatex/biber pipeline,
telix-whitepaper `~/src/telix-whitepaper/` as the pattern — multi-part `src/`, a real
`.bib` corpus, glossary, reproducible `build.sh`, markdown export), **grounded in the
code** (every claim linking to the implementing package/module), with full academic
referencing and links to codebases and online material. First candidate: the program
paper itself (records-as-products × effects-as-sums × the code-volume ledger with the
kuroko/hokora measurements) — written when the hokora gives it its measurement.
Position in the map: the whitepaper is the *distillation* of the notes for the widest
maintainer/researcher audience; it cites notes and code rather than replacing them.
**Apparatus donors:** the maintainer's earlier LaTeX projects illustrate mechanisms to
lift. From `telix-whitepaper`: the pipeline shape, multi-part sources, bib corpus, glossary.
From the nadie journal series (`~/src/nadie-v0.6.0/` et al.): **multiple named indices
via `imakeidx` + `truexindy`** with per-index UTF-8 collation and language modules
(nadie runs seven: artists/bigots/events/concepts/places/media/persons — ours would be
e.g. concepts/packages/protocols/laws/kami/Noh-terms), **multilingual `babel` setup with
per-script font fallbacks** (nadie carries fourteen languages; ours needs at minimum
English + Japanese for the Noh vocabulary — kanji rendering in the whitepaper is a
requirement, not a nicety), biblatex `autocite` conventions, and `minted` for code
listings. The nadie series also stands as the cautionary example the maintainer intends:
retrofitting indices into an existing LaTeX project foundered; lesson — apparatus is
designed in from the whitepaper template's first commit, never retrofitted.

Canonicity per fact class (resolving the open question): **laws** — haddock canonical
(notes carry the design rationale for them); **wire quirks** — CODEC_QUIRKS canonical
(codec haddock links to quirk IDs); **decisions** — REUSE_REGISTER/INFRASTRUCTURE/
DOC_STRATEGY canonical per domain (notes carry the narrative); **naming** — the NIH_PLAN
registry; **tutorials** — canonical for orientation facts only, always deferring to
canonical sources for technical claims (with links, per policy).

## 2. Single-source-of-truth and drift — PARTIALLY DECIDED 2026-09-24 (assessment half)

Planned duplications already exist: laws (catalog note ↔ haddock ↔ property tests),
quirks (CODEC_QUIRKS ↔ fixtures ↔ codec haddocks), naming (registry ↔ READMEs ↔ cabal
synopses), decisions (INFRASTRUCTURE ↔ CI config ↔ cabal commons). Any fact written
twice drifts. Canonicity per duplication class was fixed in §1; the open halves are
the *repair procedure* and §4's rot mechanics (note/code precedence). The assessment
half is now decided:

**The doc-drift judge (blessed component).** An LLM-powered assessment instrument,
added to the component list (Noh name to be chosen at package-planning time), that
finds drift, inaccuracy, and as-yet-unidentified documentation rot across the whole
corpus — explicitly whole-codebase searches, not PR-scoped review.

*SaaS PR-reviewers dismissed (recorded rationale).* CodeRabbit/Qodo/Greptile/
Copilot-review are PR-lifecycle-scoped: they review diffs at merge time. Our problem
is corpus-wide sweeps to find drift nobody has filed — as-yet-unidentified drift
between notes and code, not just review of a diff that mentions both. SaaS tools
therefore do not reach the actual requirement; they remain noted (see survey) for
possible PR-time convenience later, but are not the mechanism.

*Programmed pre-filtering to bound LLM invocation burden.* The corpus is
machine-anchorable by design — laws have IDs (L1–L4, C1–C6, E1–E6, S1–S6), quirks have
IDs, exit criteria are enumerated, obligations are per-row, canonicity is decided per
fact class (§1). The judge therefore works in stages: deterministic programming first
(extract anchorable claims; verify link targets exist; check code symbols named in
notes exist in the implementing packages; check quirk/law IDs referenced by tests
match the registers) — the cheap, exhaustive, zero-LLM net; LLM invocations then
concentrate on the residue (semantic drift a program cannot see: prose describing
behavior the code no longer has, stale rationales, inaccurate explanations). Most
tasks should be covered by the programmatic net; broader, less-structured LLM scans
run occasionally (nightly/weekly cadence) over the remainder.

*Code comprehension is part of the judge's job (remark 2026-09-24).* Consistency is
bidirectional — prose must match the code *as it is*, not as the notes wish it were —
so the judge must actually read and understand the implementing source: the
behavioral claims of a law are checked against the interpreter/handler that implements
it, example snippets against compilable/running code, exit criteria against the
artifacts that satisfy them, quirk obligations against the codec paths that encode
them. This raises the bar on the oracles (code-reading competence, not just prose
diffing — a reason not to lean on SaaS diff-reviewers) and on the harness (context
assembly must pair each claim with the right source files — the anchor graph again:
claims point at IDs, IDs point at packages, packages are read). The three-tier test
strategy supplies ground truth where it exists: property suites and fixtures are
execution evidence the judge can cite, and haddock (per §1 canonicity) is checked
against both notes and code.

*Fallible-oracle consensus.* Each LLM is treated as an individually fallible but
mostly-reliable oracle: findings pass on **consensus** (multiple models agreeing);
**any single veto triggers a more intensive review** (targeted re-examination with
more context, possibly more models) and potential revision. Multi-model by policy —
at least two distinct providers, disagreement escalates, never auto-repairs.

*Authority unchanged (§8):* the judge flags; the maintainer adjudicates and blesses
repairs. Findings land as rows in the experiment-record store (kakegoe §2.5 pattern —
doc-drift findings are measurements). *Trajectory:* start external (harness or
headless agentic CLI), then dogfood — the sarutahiko agent core running doc-drift
checks as effect programs is the intended Phase-2 self-application.

*Tooling survey (the classes considered):*

| Class | Examples | Assessment |
|---|---|---|
| SaaS AI PR-reviewers | CodeRabbit, Qodo Merge (OSS, self-hostable Action), Greptile, Copilot review | **Dismissed as the mechanism**: PR-diff-scoped, not corpus-sweep-scoped; noted for possible PR-time convenience later; local-model option matters anyway for §9 exposure of named cross-ecosystem analysis |
| LLM-as-judge eval frameworks | promptfoo (declarative YAML pipelines, any provider, assertions, CI-native), DeepEval (pytest-style, faithfulness/hallucination metrics), RAGAS (groundedness) | **The flexible core** — build the judge as a versioned eval suite with structured verdicts |
| Headless agentic CLIs | rubric-driven whole-corpus passes (the session's own tooling class) | Most flexible for our unusual shape; homegrown cost |
| Direct provider APIs / local models | provider APIs; ollama/vLLM local | The substrate under the above two; local models relevant for exposure-sensitive subsets (§9) |

**Choice: class 2/3 harness (promptfoo-style or headless agentic) with
programmatic pre-filtering, multi-oracle consensus with veto-triggered intensive
review, findings→row store, advisory authority.** Repair procedure remains open.

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
| 2026-09-24 | §1 decided: three audiences, three genres — tutorials for arrivals; verbose, math-and-link-rich Haddock for API consumers (SVG figures from checked-in DSL sources; external citations and repo links as policy); design corpus + LaTeX whitepaper distillation (telix genre: lualatex/biber, `.bib` corpus, grounded-in-code) for maintainers. Canonicity fixed per fact class: laws→haddock, quirks→CODEC_QUIRKS, decisions→registers, naming→registry. |
| 2026-09-24 | §1 amended: tutorials upgraded to scaled-textbook with enlightenment-forcing exercises (AI-assisted answering expected; explanation is the deliverable) and machine-authorship as explicit policy — volumes on command, human effort spent on curation/challenge/blessing. Whitepaper apparatus donors named: telix (pipeline shape) + nadie (imakeidx/truexindy named indices with UTF-8 collation, multilingual babel with per-script fonts — Japanese required for Noh vocabulary, biblatex autocite, minted); apparatus designed in from the template's first commit, never retrofitted (the nadie retrofit failure is the cautionary example). |
| 2026-09-24 | §2 partially decided (assessment half): the doc-drift judge blessed as a component — corpus-wide LLM assessment with programmatic pre-filtering (ID/symbol/link nets bound the invocation burden), fallible-oracle consensus (≥2 providers; any veto triggers intensive review), findings to the row store, advisory authority. SaaS PR-reviewers dismissed as the mechanism (PR-diff-scoped vs our as-yet-unidentified-drift sweeps) with rationale and survey recorded. Repair procedure still open. |
