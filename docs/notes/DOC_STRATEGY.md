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
twice drifts. Canonicity per duplication class was fixed in §1; the assessment and
repair halves are decided below, and §4 owns the rot mechanics (note/code
precedence). The assessment half:

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
review, findings→row store, advisory authority.**

**Repair procedure — DECIDED 2026-09-24 (the (c)+(d) synthesis):** the judge's findings may
carry proposed patches — mechanical repairs (path rewrites, stale links, §9 sweep fixes)
especially — as *proposals*; machine labor concentrates where it is safe. **Flag-clearing
is human-gated**: a flag clears only when a maintainer (or subsystem maintainer, per §4's
variegated scope) accepts a repair, with the clearing witnessed by a dated status edit
citing both the finding row and the accepting change SHA. Repairs touching *blessed*
content get no new gate — they ride §3/§4's existing gates (blessing protocol, review
gate) as already decided. **Cadence is batched, not per-finding**: sweep → triage → one
batched repair change per cycle, matching the batched-push policy (INFRASTRUCTURE §12),
so repair churn and push churn get the same answer.

## 3. Lifecycle and authority — DECIDED 2026-09-24 (states, invalidity flags, dead documents)

**Lifecycle stages** (the main line; carried in each document's Status header):

1. `seed` — issue space recorded, policy pending (this document's current state)
2. `draft` — full draft exists, pre-review
3. `review` — under maintainer review; challenges pending resolution
4. `blessed` — decisions adopted; blessing date(s) in the Status header (mechanics:
   the dated status edit in a maintainer commit, plus the document's decision-log row —
   the corpus's de facto practice, now formal)
5. `implemented` — the blessed design realized in code; stamped at the implementing
   change (partial stamps permitted: "implemented (Tier-0 core, 2026-10-…)")
6. `superseded` — replaced; must link its successor
7. `dead` — removed from the tree; tombstoned (below)

**Invalidity flags** — an orthogonal overlay on stages 2–5 (not stages themselves: an
implemented document can be inconsistent without leaving `implemented`, and repair
must not force a re-blessing cycle). Flags, carried in the Status header
(`flags: inconsistent(finding #…), dead-links`):

- `erroneous` — contains factual errors
- `inconsistent` — contradicts other corpus documents or the code (typical doc-drift
  judge finding; the finding row is referenced)
- `stale` — describes behavior that has moved on (the rot vector, §4)
- `dead-links` — references that no longer resolve
- `needs-work` — generic defect flag

Setting/clearing: the doc-drift judge sets flags (advisory, citing finding rows);
humans may flag; the maintainer adjudicates and clears on repair. **Effect of a flag:
the document is not citable as canonical for the fact classes its flags touch** (§1
canonicity), until cleared. Repair is ordinary commits; no re-blessing required unless
the repair changes a decision.

**Revision-in-place vs new document** (the LLM substrate v0.1→v0.2 precedent stands):
revise in place when the document's identity and scope survive the change (correction
of record, the maintainer's challenge preserved in the history); a new document when
the scope or thesis changes (the old one is superseded or killed). Living documents
(inventories, registers) are append-only by their own rules (quirk history: "fixed as
of" notes, never deletion).

**Dead documents and the attic.** Removal is `git rm` plus a tombstone row in
`docs/registers/ATTIC.md` (per §5's directory structure): title, former path, removal commit SHA, last-content SHA, reason,
successor link (if any), and recovery instructions. Git history is the content store
(`git show <last-content-sha>:<former-path>`); nothing is stubbed in-tree. **Versioned
references:** live documents must link haddock version-qualified whenever the
referenced artifact can change — Hackage versioned docs for released packages
(`hackage.haskell.org/package/P-v/docs`), tag-pinned source links otherwise. A dead
(or superseded) document's stale links therefore still resolve: Hackage if released,
else rebuild at the recorded tag on demand (`cabal haddock` at the tag) — and for
removed *documents* (which have no haddock), the last-content SHA is the permanent
address. This keeps the anchor graph (§2) navigable into the past without maintaining
a documentation server.

Still open under this section: contributor rules beyond the maintainer (§8 covers
authority; PR mechanics await collaborators).

## 4. The rot problem — design ahead of code — PARTIALLY DECIDED 2026-09-24

The program's procedure is *designs flow down the mountain, stone flows up*: most notes
describe unbuilt systems. Failure mode: a blessed note silently diverging from the code
that eventually implements it.

**Decided:** the rot vector folds into the doc-drift judge's scope — the drift
examination grows to include the design documents themselves, so there is one judge,
one anchor graph, one finding store, not two regimes (assessment: notes ↔ code,
notes ↔ notes, haddock ↔ both). The implemented marker and precedence rule, however,
are lifecycle matters (§3) and are decided there: `implemented` is stamped at the
implementing change (partial stamps permitted), and precedence is — **code wins at
runtime, the note must be corrected regardless** (a behavior change without a note
correction is an incomplete change; advisory status is not granted to blessed notes).
AGENTS.md carries this to AI assistants as advisory rule 2.

**Stamp mechanics — DECIDED 2026-09-24, protocol form (amended after maintainer
review):** multiple mechanisms coexist as *proposals*; acceptance is human-gated and
variegated by scope. The protocol:

1. **Proposal** — the implementing change self-stamps `proposed-implemented`
   (self-service: the human behind the arriving code proposes the realization);
   automated mechanisms nominate too (judge cross-checks both directions; test suites
   and io-sim evidence are machine witnesses).
2. **Disciplines** — CI gates must pass (unit/macro suites, dual-effect parity,
   e2e smoke; execution evidence citable by the judge).
3. **Gate** — acceptance by the maintainer, or by the package's **subsystem
   maintainer** (the maintainer's delegate for that scope — the Radicle delegate
   model applied to review authority; "vassal" was the maintainer's term, *delegate*
   reserved for key-signing). Gate = branch-merge/PR acceptance point; changes that
   alter decisions additionally require the maintainer's blessing (§8).
4. **Stamp** — `implemented (package, date)`; multi-package designs carry an
   implemented-map so partial realization is explicit (`-hasql (pending)`).

Judge cross-checks both directions: stamps without realizing code; realizing code
without stamps. Dispute default: **maintainer is final**, disagreements recorded in
the corpus (the challenge-and-amend pattern) — pending maintainer confirmation.

**The partial-realization shield — DECIDED 2026-09-24 (declarative, auditable,
expiring).** The problem: consistency checks (dead-code, coverage, judge verdicts)
misfire on deliberately-unrealized pieces. The blessed design is itself the shield
grant: a blessed note carries an **unrealized-surface inventory** — its implemented-
map's `pending` entries plus explicitly deferred scope (e.g. "embeddings land v1.5").
Checks (layer lint, dead-code, judge) suppress-or-annotate findings inside the granted
surface; **every suppressed finding must cite its shield** ("inconsistent — but
shielded by MEMORY §3.4 pending:hasql"), so suppression is auditable; and shields
**expire** — a pending entry with no birth event across a phase boundary converts
from shield to finding (`stale`). Suppression without dishonesty.

**Gates for collaboration — DECIDED 2026-09-24 (structure; staffing deferred).**
CI gates (existing) + review gate (maintainer or subsystem maintainer; blessing-
required changes need the maintainer) + judge checks of shields/stamps as part of
review. On Radicle this maps onto patches and delegate thresholds. Until contributors
exist, the maintainer occupies all gates (the hokora exception — stated so the policy
implies no multi-party fiction). Subsystem-maintainer assignments await the first
collaborators; the mechanism is defined, the staffing is not.

**Pre-birth documentation — DECIDED 2026-09-24 (the frontier).** The mirror of the
attic problem, and thornier: no git history holds ground truth for what does not
exist yet. Two kinds: (a) documentation for as-of-yet unwritten code (most of this
corpus today), (b) references to planned-but-unwritten documentation and artifacts.
These are **not invalidity** — a reference to planned work is healthy — so they do
not ride §3's flag overlay (marking the whole corpus `dead-links` would be absurd).
Mechanism instead:

- **Prospective references:** references to planned artifacts carry an inline
  prospective marker (`[planned: …]`); the anchor graph (§2) gains a *planned* node
  type; the judge's programmatic net treats prospective anchors as **dormant** —
  existence check deferred, not failed.
- **Birth events:** the implementing change that brings the artifact into existence
  also activates its references (removes the prospective markers); if the design dies
  before birth, the references die with it via §3's superseded/dead path — no orphaned
  prospects.
- **Planned-documents inventory:** unwritten-but-planned documents are enumerable,
  not folk knowledge — NIH_PLAN §6 (the backlog) is that inventory; the judge
  cross-checks both directions: born anchors with stale prospective markers, and
  `implemented` stamps without realizing code.

Net effect: the frontier is *typed* (planned, dormant, born) rather than confused
with error states, and the judge's scope now covers the full document life: pre-birth
(dormant anchors), bloom (blessed claims vs code), and death (attic tombstones).

## 5. Structure and discoverability — DECIDED (2026-09-24)

**Directories now** (the tree crossed the threshold with twenty files and the
observability direction landing): `docs/notes/` (design notes and specs; the
suffix-as-genre table — `_DESIGN`, `_SPEC`, `_STRATEGY`, `_PLAN` — still governs within),
`docs/registers/` (living registers and inventories: `REUSE_REGISTER`, `CODEC_QUIRKS`;
the future `ATTIC.md` tombstone register lives here too), `docs/imports/` (third-party
documents and artifacts kept verbatim — currently the Hermes inventory and its rendered
diagrams), `docs/transcripts/` (conversation transcripts as archive). New genres decide
directory and suffix together at creation. Transcripts are freely renamable: the title
records origin, the filename records topic.

**Hybrid index.** `docs/INDEX.md` has two parts: an inventory table *generated* from
Status headers (path, genre, stage, flags, implemented-map — cannot drift by
construction, zero LLM cost) and hand-curated reading paths for §1's three audiences
(arrival order, API-consumer entry points, maintainer corpus map). A script net (zero
LLM) mechanically checks: every relative link resolves, target headings exist, every
document has an inventory row. The judge's semantic layer runs above the script net.

**No archive directory.** Superseded documents stay in place (header + successor link);
dead documents leave via §3's tombstone procedure. The index's "Archived" section is
the archive.

**Tier as index metadata only.** Each note is pinned to a tier column (substrate /
streaming / database / memory / model / surface / cross-cutting); no filenames or
directories encode tiers, so re-tiering is an index edit. The column feeds the judge's
anchor graph (claim → document → tier → package).

**Cross-references: IDs canonical, links convenience.** ID citations (`L2`, `Q7`,
`MAP-§3.4`) are the stable reference layer — they survive renames, all mirrors, and
death (via the tombstone register's last-content SHA). Relative hyperlinks are the
convenience layer: relative paths only (§9 bans absolute and `~/` paths), hard heading
anchors avoided except where verified across renderers. The script net enforces the
convenience layer mechanically; the judge checks semantic sense above it.

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

**The §7 amendment (2026-09-24): assistant-context budgets.** AGENTS.md is an explicit
**pointer file with an ~4 KB budget** — an index into selectively loadable canonical
documents, not a restatement of them (the §1 projection doctrine, promoted to a
design constraint). Empirical trigger: a small-context model (cogito:3b) truncated a
32 KB assembled context against this repo — the consumer, not the corpus, was the
limiter. Corollaries, generalizable to any consumer: canonical documents lead with a
short header block (status, related, thesis) so small-context readers can decide
*whether* to load more without reading it all; the kagami-ita event envelope is
row-decomposed so envelope-without-payload is a valid summary unit
(OBSERVABILITY_DESIGN §7). One maintenance line is additionally added to AGENTS.md
so its own rules are discoverable by assistants.

## 8. Co-authorship and authority

Unusual to this program: the design corpus is **AI-drafted and maintainer-blessed**.
*Policy needed:* say so explicitly, and define what blessing certifies (that the
maintainer read, challenged where needed, and owns the content — the session's
challenge-and-amend record is the intended pattern); the rules for future contributors
(human-drafted proposals land under the same review; CI gates apply to docs).

## 9. Exposure policy — DECIDED 2026-09-24 (everything public; formal references; prominent credit)

**Everything in this repository is meant to be public** — pulled, mirrored, read. No
document class gets a private/no-mirror treatment; the review rule for new content is
the ordinary blessing flow. The maintainer's audit decision: nothing currently in-tree
is an outright publishing hazard (verified: no secrets/credentials; tool-local files
harmless), and any future outright-bad find is alerted and removed immediately.

**Formal references to people.** Our-voice documents refer to **Nadeem Bitar** by full
name (the six bare first-name instances were swept to formal form on decision day); the
affectionate framing ("the answer to Nadeem") is rephrased in our voice to the
**keiro-comparison thesis** — the comparison is with the ecosystem's work, and the
respect is expressed through formality and credit, not familiarity. The maintainer
explicitly welcomes direct feedback from Nadeem Bitar.

**Local paths out, public references in.** `~/src/…` references are replaced by
publicly usable references: GitHub URLs for public repositories, Hackage names for
published packages; the maintainer's own not-yet-public repositories are referenced by
name with *(publication pending)* — and publication becomes the follow-up that keeps
the reference honest. The doc-drift judge's link-checker enforces resolvability
mechanically, so this policy is self-enforcing once the judge runs.

**Cross-ecosystem credit — prominent and granted.** The projects and maintainers whose
code and design analysis has informed this program — **including by the rejection of
their approaches** — receive prominent credit as derivation sources. Per the
maintainer's explicit position: derivation credit is granted **by choice, not
obligation** — even where no direct code use creates a license duty, the credit is
still given, because it is owed in the register's own terms (design analysis is
derivation). Concretely: a `CREDITS.md` at the root listing the keiro ecosystem (baikai,
keiro, kiroku, shibuya, kioku, shikumi), Hermes (Nadeem Bitar), and the upstream
Haskell projects (typed-protocols/IOG, hasql, effectful, polysemy, streamly, conduit,
porcupine, large-records/large-anon, hlint, brittany, and others as the register grows),
each with what was learned from it. License note: design influence carries no license
obligation; **code reuse does** — every REUSE_REGISTER row that lands code records its
license field, and LICENSES/ third-party notices accompany reused code (the
telix-whitepaper LICENSES/ directory is the pattern).

**Tone: the about-face.** Differing-design-decision discussions in our-voice documents
use a respectful engineering register: state what the other design optimizes for, what
we chose instead, and why — criticism targets designs, never people, and charged
phrasings ("counterexamples", "hell", "god object") are rewritten in our voice (the
doctrine now reads "first-iteration designs whose core vocabulary predates these
principles"). Verbatim quoted transcripts (the Gemini conversation records) are
*archived records*: they retain their original language under a quotation header
marking them as unedited third-party-voiced history — our tone policy governs our
voice, not the archive.

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
| 2026-09-24 | §2's repair procedure decided — the (c)+(d) synthesis: judge-proposed patches are free proposals (mechanical repairs especially); flag-clearing human-gated, witnessed by a dated status edit citing finding row + accepting change SHA; blessed-content repairs ride §3/§4's existing gates (no new gate); batched sweep→triage→repair cadence matching the batched-push policy. §2 is now fully decided. |
| 2026-09-24 | §2 amended: the judge must understand the code — consistency is bidirectional; behavioral claims verified against implementing source, examples against compilable code, exit criteria against artifacts; oracle bar raised (code-reading competence), harness bar raised (anchor-graph context assembly), test suites/fixtures citable as execution evidence. |
| 2026-09-24 | §3 decided: seven lifecycle stages (seed/draft/review/blessed/implemented/superseded/dead); invalidity as orthogonal flag overlay (erroneous/inconsistent/stale/dead-links/needs-work) carried in Status headers, flagged documents lose citability for affected fact classes until cleared; blessing mechanics formalized (dated status edit + decision-log row); revision-in-place vs new-document rule with the LLM-substrate precedent; dead documents tombstoned in docs/ATTIC.md with git history as content store; version-qualified haddock linking (Hackage for released versions, tag-pinned rebuilds otherwise). |
| 2026-09-24 | §4 decided (with the pre-birth amendment): rot folds into the doc-drift judge; precedence = code wins at runtime, the note must be corrected regardless; implementing change stamps `implemented`, sub-stamp implemented-maps for multi-package designs; **prospective references** type the pre-birth frontier (planned/dormant/born) — dormant anchors deferred not failed, birth events activate references, NIH_PLAN §6 as the planned-documents inventory; judge covers the full document life. |
| 2026-09-24 | §4 amended: stamping is a protocol (propose → disciplines → gate → stamp); acceptance human-gated and scope-variegated (maintainer or subsystem maintainer — delegate model applied to review authority); partial-realization shield declarative (unrealized-surface inventory in blessed notes, suppression must cite its shield, shields expire across phase boundaries); merge/PR gates structured (CI + review gate + judge checks); maintainer-final dispute default recorded pending confirmation; hokora exception stated; subsystem-maintainer staffing deferred to first collaborators. §3/§4 remainders parked: repair procedure (§2's other half), dispute path confirmation, seed formalities. |
| 2026-09-24 | §9 decided: everything public; formal references (full names; "keiro-comparison thesis" replaces the familiar framing; maintainer welcomes direct feedback from Nadeem Bitar); local paths replaced by publicly usable references (URLs/Hackage; publication-pending markers for the maintainer's own repos, enforced by the judge's link-checker); prominent credit as derivation sources — including by rejection — via CREDITS.md; license fields on reuse rows, LICENSES/ for reused code; tone about-face in our voice (respectful engineering register, criticism of designs not people, charged phrases rewritten; verbatim transcripts preserved as marked archive records). Audit sweep found no secrets; no extraction needed. |
| 2026-09-24 | §9 amended: derivation credit granted as a deliberate choice, not merely where license obligations attach — influence credit is independent of code use. |
| 2026-09-24 | §5 decided: directories now — `docs/notes/`, `docs/registers/`, `docs/imports/` (verbatim third-party material incl. the Hermes inventory and diagrams), `docs/transcripts/` (conversation archives; freely renamable, title = origin, filename = topic, provenance headers on the renamed Gemini transcripts); hybrid index (`docs/INDEX.md`: generated inventory table + hand-curated reading paths, script net beneath the judge); no archive directory (index's Archived section is the archive); tier as index metadata only; cross-references two-layer — ID citations canonical, relative links convenience, enforced by a zero-LLM script net under the judge's semantic layer. |
| 2026-09-24 | §7 amended: assistant-context budgets — AGENTS.md as an explicit ~4 KB pointer file (index into selectively loadable canonical docs), header-blocks-first rule for canonical documents, row-decomposed envelopes (envelope-without-payload as summary unit); empirical trigger: cogito:3b truncating a 32 KB assembled context (the consumer, not the corpus, was the limiter). |
| 2026-09-24 | Backlog item 11 written: `OBSERVABILITY_DESIGN.md` (**kagami-ita** 鏡板, blessed; alternates mawari-butai / hanamiko / mie reserved) — the interpreter edge as the sole instrumentation point (K1–K4: instrumentation is an interpreter concern; dual interfaces with an observer-effect parity law; row-typed envelope events generalized from the memory log; zero-cost-when-absent capability grants); metrics as reductions over the event stream via mergeable quantile sketches (reuse row 2.20: the maintainer's t-digest as owner class, Greenwald–Khanna, Q-digest); replay-based serviceability via the kakegoe recording interpreters; scrub-manifest-gated privacy posture; small-context accommodation (§7 corollaries); open questions O1–O7 (retention defaults, span shape, metrics exposure, recorder home, sampling, envelope home, high-cardinality top-k). |
