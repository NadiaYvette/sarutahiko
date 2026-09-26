# **AI Assistant Tooling, Shubham's Recommendations, and Compiler Truth Synthesis**

> **Provenance:** archived pair-programming dialogue transcript (Antigravity CLI / Gemini 3.8,
> 2026-09-25 to 2026-09-26), imported 2026-09-26. Genre: `transcript` — a primary-source record
> of the project's tooling architecture, assistant harness evaluations, and compiler truth
> debates; citable as reasoning history, never as canon (DOC_STRATEGY §1 canonicity table, §5).
> Filename records the topic: synthesis of assistant tooling, Shubham's setup scripts, and
> compiler truth vs. tree-sitter indexing.

&nbsp;

## **1. Background and Initial Inquiries**

### **Context: The Multi-Harness Assistant Environment**
During Phase 1 engineering on `sarutahiko`, experiments were conducted across multiple AI coding
assistant REPLs and runtimes:
- **Primary Harness:** Antigravity CLI (running Gemini 3.8 / Pro models).
- **Secondary / Sandbox Harness:** Hermes Agent running inside a Distrobox container
  (`~/Projects/Workspace/Nadia/` acting as container `$HOME`).
- **Local Bridges & Services:** Configured via Shubham's setup script (`ws-nadia.sh`):
  - OmniRoute proxy (port 20128)
  - FreeLLMAPI (port 3001)
  - OpenCode Bridge (port 20129)
  - Kaggle GPU Bridge (port 20130, dispatching to remote Tesla P100 runners)

### **Shubham's Tooling Recommendation**
The maintainer's friend Shubham, assisting with Hermes and local AI assistant automation, advised:
> *"Tell Gemini to install and setup codebase-mem-cpp, Codegraph and Ponytail plugins for itself
> and always use them. This way each time you give it a prompt or it gives you results, it'll use your tools."*

Source checkouts examined:
- `~/src/codebase-mem-mcp/`
- `~/src/ponytail/`
- `~/src/codegraph/`

---

## **2. Comparative Tool Evaluation**

### **Tool 1: `ponytail` (The Minimalist Senior Dev Skill)**
- **What it is:** A workflow skill forcing minimal, zero-bloat solutions ("question whether the task
  needs to exist at all, reach for the standard library before custom code, native platform features
  before dependencies, one line before fifty").
- **Evaluation:** Aligns 100% with `sarutahiko`'s anti-bloat doctrine (`NIH_PLAN.md` §0, `DOC_STRATEGY.md`,
  and `REUSE_REGISTER.md`).
- **Action:** Installed natively into `.agents/skills/ponytail/SKILL.md` where both Antigravity and Hermes
  can discover and invoke it automatically.

### **Tool 2: `codebase-mem-mcp` (C++ Tree-Sitter Memory Indexer)**
- **What it is:** An MCP server leveraging Tree-sitter in C++ to extract AST nodes, functions, and
  call graphs into a persistent vector or relational graph.
- **Evaluation for Haskell / Sarutahiko:**
  - **Syntax vs. Semantics:** Tree-sitter parsers operate strictly on concrete syntax trees (CST).
    They cannot evaluate Haskell type families, typeclass resolution, functional dependencies, or
    compile-time GHC plugins (like `Data.Record.Anon.Plugin`).
  - **FFI & Memory Overhead:** Running heavy native C++ tree-sitter daemons on large repos consumes
    substantial resident memory on developer laptops.
  - **Verdict:** Highly valuable for polyglot C/C++/Python/Rust projects (e.g. `frankenstein` shims),
    but cannot serve as the semantic truth oracle for row-polymorphic Haskell.

### **Tool 3: `codegraph`**
- **What it is:** Code graph generation using syntactic references.
- **Evaluation:** Suffers the same semantic blindness as Tree-sitter when applied to Haskell:
  it sees names, but cannot resolve which typeclass instance or dictionary is being passed, nor
  can it resolve closed type families or row types.

---

## **3. The Compiler Truth Oracle vs. Syntactic Guessing**

In statically typed, advanced functional programming (GHC2024 with row polymorphism and effect systems),
the **only authoritative arbiter of correctness is the compiler itself**.

| Capability | Syntactic Indexer (`tree-sitter`, `codebase-mem`) | Semantic Truth Oracle (`tricorder`, GHCi) |
|---|---|---|
| Symbol Declaration | Fast, approximate (CST regex/grammar) | Exact (GHC Typechecked Module AST) |
| Type Invariant Validation | None (cannot typecheck) | Inviolable (`-Wall -Werror`) |
| Row-Polymorphism Resolution | Fails completely on anonymous rows | Resolves field existence and type |
| Effect Signature Checking | Blind to row capability composition | Guarantees effect containment |
| Token Cost | 1,000–5,000 tokens of AST noise | < 50 tokens of structured diagnostics |

**The Hierarchy:**
1. **Tier 1 (Fast Jump):** `hasktags` (`./tags`) — instant, zero-memory, deterministic symbol lookup (<15 tokens).
2. **Tier 2 (AST Outlines):** `ast-grep` (`sg`) — pattern-matching CST nodes without FFI daemons.
3. **Tier 3 (Compiler Truth):** `tricorder-mcp` (Tweag) — background GHCi checking on file save (<50 tokens).
4. **Tier 4 (Hybrid Recall):** `contextful` / `kioku` — FTS5 BM25 + embeddings for natural language prose.

---

## **4. Guarding Against Small-Model Drift (Reasoning Heterogeneity)**

When human maintainers switch between flagship frontier models and lighter local models (Hermes Agent
with 7B/70B models), distinct failure modes emerge:
- Hallucinating Cabal package dependencies.
- Whole-file rewrites that silently discard GHC plugins or type signatures.
- Re-introducing generic internet patterns (`aeson`, `lens`) that violate codebase doctrine.
- Concurrency mistakes (forgetting `-threaded`, mismanaging subprocess handles).

**Remedies Adopted:**
1. **Enumerated Negative Constraints:** Prompts must explicitly forbid banned libraries and file rewrites.
2. **The Quarantine Protocol:** When an exploratory agent makes a wrong turn, freeze HEAD to
   `archive/experiment-<topic>-<date>` and `git reset --hard` back to the verified milestone gate.
3. **Container Daemon Synchronization:** Tricorder and background daemons must handle filesystem socket
   boundaries between host and containerized distrobox environments.

---

## **5. Sideband Repositories vs. Upstream Trees: The `pgcl-testscripts` Pattern**

### **The Architecture: Sideband as Root with Upstream as Peer/Submodule**
The maintainer reflected on the structure of `pgcl-testscripts` (on git hosting) vs `~/src/pgcl/` (on disk),
where the Linux kernel work lived as a branch in the Linux kernel while `pgcl` contained test scripts,
reproduction harnesses, diagnostics, documentation, and formal CBMC models:
- **Option 1: Sideband as Root with Submodule Upstream:**  
  *Pros:* Pinning exact commit SHAs; clean reproducible entrypoint for CI.  
  *Cons:* The 5GB+ kernel git history makes submodule operations heavy; detached HEAD friction during
  kernel development; risk of pushing sideband commits with unpushed submodule pointers.
- **Option 2: Symbiotic Worktrees / Sibling Repositories:**  
  *Pros:* A primary object store (`~/src/linux/`) with detached worktrees (`pgcl/kernel-worktree/`) eliminates
  object duplication and submodule friction while allowing out-of-tree builds (`make O=...`).
- **Option 3: Thin Git Bundles (The PGCL Innovation):**  
  As implemented in `~/src/pgcl/kernel-bundles/`, storing a thin git bundle of the development branches
  (~900 KB) atop upstream releases guarantees durability across lightweight git hosts (Framagit, Disroot)
  without hosting multi-gigabyte kernel trees.

---

## **6. The Grand NIH Constellation: The Oberon Precedent**

The maintainer’s panoramic ecosystem is explicitly non-hierarchical, forming an imbricated constellation
aspiring to the scale of Niklaus Wirth's **Project Oberon** (rather than eccentric, non-rigorous systems
like Terry Davis's TempleOS):

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE WIRTH-GRADE GRAND NIH CONSTELLATION                  │
├─────────────────────────────────────────────────────────────────────────────┤
│  Hardware & MMU:        Custom RISC-V MMU (satp 14/15, 256 B base page,     │
│                         inverted PT, SLB, 42 superpage sizes; Sail/Rocq/QEMU)│
├─────────────────────────────────────────────────────────────────────────────┤
│  Formal Verification:   Tessera (Sail specs, Rocq proofs, CBMC concurrency) │
├─────────────────────────────────────────────────────────────────────────────┤
│  Kernel Substrates:     Telix (coremapless, morsel allocator, extent VM)    │
│                         Linux-PGCL & FreeBSD-PGCL (page clustering retrofit)│
├─────────────────────────────────────────────────────────────────────────────┤
│  Compiler Substrates:   Frankenstein (multilingual MLIR lowering, arena RT) │
│                         Organ-Bank (25+ language shims, organ-ir ASTs)      │
├─────────────────────────────────────────────────────────────────────────────┤
│  AI & Agent Layer:      Sarutahiko (row-polymorphic effects, large-anon,    │
│                         Yamaarashi streaming, Hashigakari database AST)     │
│                         Peirce / Mowgli (neuro-symbolic math & diffusion)   │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Wirth's Oberon as the Gold Standard:** Total vertical integration—from custom RISC processor on
  FPGA to the Oberon language, single-pass compiler, and cooperative OS—comprehensible by one human,
  formally sound, and strictly modular.
- **The Imbricated Mesh:** The repositories do not form a top-down tree. Slices of `organ-bank` feed
  MLIR in `frankenstein`, which feeds fixtures to `kogaki` and `sarutahiko`; `telix` drives the custom
  MMU while `tessera` proves the refill handler; `pgcl` demonstrates page clustering on legacy kernels.

---

## **7. The Custom RISC-V MMU Design & Naming Candidates**

The custom RISC-V MMU extension (proposed `satp` modes 14 and 15) replaces the conventional hardware-walked
radix tree with an **inverted (hashed) page table**, a **POWER9-style SLB segment cache**, and **residue-based
TLB partitioning** covering 42 distinct translation sizes ($g_n = K \cdot 2^{W \cdot n}$, with $K=256\text{ B}$,
$n \in \{0 \dots 41\}$ up to 512 TiB).

### **Naming Candidates:**
1. **Ajiro (網代):** Classical Japanese woven wickerwork lattice / fish trap mesh. Perfectly captures the
   hashed inverted page table lattice (an interconnected mesh rather than a hierarchical radix tree).
2. **Kusabi (楔):** Wedge or keystone. Represents the 256 B base page as the architectural wedge splitting
   the radix-tree deadlock without VAX pathologies.
3. **Kasen (歌仙) / Kasen-42:** Named for the classical 42 poetic masters, commemorating the 42 distinct
   translation sizes.
4. **Sudare (簾):** Slatted partition screen, matching residue-based TLB partitioning.
5. **T-Grain / Morsel-MMU:** Direct architectural attribution linking the 256 B grain to Tessera and Telix.

---

## **8. Ecosystem Documentation Guidelines & Portfolio Standards**

To sweep the portfolio and ensure uniform excellence across all repositories, documentation must adhere
to formal structural guidelines:
1. **Genre Separation (DOC_STRATEGY):** Design notes, specifications, implementation plans, living registers,
   and transcripts are strictly separated.
2. **Diátaxis Alignment:** Clear distinction between Tutorials (learning-oriented), How-To Guides (problem-oriented),
   Reference (information-oriented), and Architecture/Design (understanding-oriented).
3. **Formal Verification & Failure Catalogues:** In system software (`tessera`, `telix`, `pgcl`), documents
   must enumerate explicit Invariants, Proof Obligations, and Failure Catalogues (e.g. `failure-modes-pgcl.md`).
4. **The ~4 KB Pointer Budget for AGENTS.md:** Frontline orientation projections point to canonical documents
   rather than replicating content, preserving context tokens across AI assistant sessions.

---

## **9. Spatial Trees vs. High-Dimensional Vector Graphs (The Curse of Dimensionality)**

The maintainer examined whether vector databases use spatial trees like $R^*$-trees or $X$-trees
(as found in `~/src/spatial-trees/`):
- **Spatial Bounding Trees ($d \le 16$):** $R$-trees, $R^*$-trees, and $X$-trees partition space using minimal
  bounding hyper-rectangles. In 2D, 3D, and up to ~16 dimensions, this prunes large swaths of the search
  space with minimal bounding-box overlap.
- **The Curse of Dimensionality ($d = 768$):** In high-dimensional spaces, the volume of bounding
  hyper-rectangles expands exponentially, causing internal node boxes to overlap almost 100% of the space.
  Tree descent degenerates to linear $O(N)$ scan.
- **Modern Vector Topologies:** Vector stores therefore bypass spatial bounding trees in favor of
  **Approximate Nearest Neighbor (ANN)** graph and inverted-list structures:
  - **HNSW (Hierarchical Navigable Small World graphs):** Multi-layer proximity skip-graphs ($O(\log N)$ search).
  - **IVF (Inverted File Index):** Voronoi cell clustering around K-means centroids + inverted lists.
  - **DiskANN / Vamana:** High-throughput graph-based ANN engineered for SSDs (implemented in `sqlite-vec-diskann.c`).

---

## **10. Pure-Haskell Native Storage Engines (`haskey-btree` & `spatial-trees`)**

In `sarutahiko`'s data access layer (`hashigakari`), two native Haskell libraries provide hermetic,
zero-C-FFI storage backends:
1. **`haskey-btree` (`~/src/haskey-btree/`):** Henri Verroken & Steven Keuchel's purely functional,
   copy-on-write B-tree implementation with transactional ACID guarantees, eliminating runtime thread
   pinning and native C dependencies.
2. **`spatial-trees` (`~/src/spatial-trees/`):** Multi-dimensional $R^*$-tree and $X$-tree indexing for
   spatial, geometric, and low-dimensional clustering.

---

## **11. Database Parity: PostgreSQL vs. SQLite**

The codebase enforces strict database neutrality in `hashigakari` (Tier 5):
- **Vector Search:** PostgreSQL's `pgvector` (`vector(768)` type, HNSW indexes, `<->`, `<=>` operators)
  exhibits direct semantic parity with SQLite's `sqlite-vec` (`vec0` virtual table, `MATCH` operator).
- **Full-Text Search:** PostgreSQL's native `tsvector` + `tsquery` (with GIN/GiST indexes and `ts_rank_cd`)
  exhibits direct parity with SQLite's `FTS5` (BM25 ranking and porter stemming).
- **Neutrality Guard:** `sqlite-vec` and `FTS5` are chosen strictly as zero-daemon developer tooling for
  local desktop indexing; `sarutahiko` is never locked to an SQLite-only paradigm.

---

## **12. Home-Directory Packaging Aware of System Packages (Spack & Distrobox)**

The challenge of installing packages in `$HOME` without root privileges while remaining aware of the
host system's package database (RPM/Debian) is addressed by:
- **Spack (`~/src/spack/`):** Developed at LLNL for national labs and HPC clusters. It installs entirely
  within `$HOME`, but runs `spack external find` to automatically detect host-installed compilers (GCC, Clang)
  and system libraries (`glibc`, `openssl`), building user-space packages linked directly against host components.
- **Distrobox (`~/Projects/Workspace/Nadia/`):** Mounts the host `$HOME`, shares Wayland/X11 and GPUs,
  while maintaining isolated package manager states.

---

## **13. Durable Workflow Tracking: Nadeem's `keiro` / `keiki` and Kanban**

- **Nadeem's Workflow Stack:**  
  - **`keiro` (経路):** A durable workflow execution engine built over Postgres event logs (`kiroku`).
  - **`keiki` (継起):** A pure, zero-database finite-state transducer core modeling state machines and event streams.
- **Applying to Human + Agent Affairs:**  
  While designed for computer orchestration, `keiro`'s event-sourced model can represent human tasks,
  cross-repo milestones, and project DAGs (`TaskProposed`, `TaskBlocked`, `TaskCompleted`), enabling
  deterministic replay and dependency tracking across the portfolio.
- **Nomenclature:** The Greek word referenced is **`diataxis` (διάταξις - arrangement/classification)**
  or **`tessera` (τέσσερα - four / mosaic tile)**. "Kanban" (看板) is Japanese, meaning signboard or billboard.

---

## **14. Multi-REPL Concurrency & ACID (SQLite WAL Mode & Git Worktrees)**

When multiple AI coding assistants (Antigravity, Hermes, Claude Code) touch shared repository state:
1. **SQLite Concurrency:** Configure **WAL mode (Write-Ahead Logging)** with a busy timeout:
   ```sql
   PRAGMA journal_mode = WAL;
   PRAGMA busy_timeout = 5000;
   ```
   Readers never block writers, and writers never block readers, completely eliminating `database is locked` errors.
2. **Git Concurrency:** Multiple agents must never run concurrent commits in the same working directory
   (which collides on `.git/index.lock`). Agents must utilize **Git Worktrees** (`git worktree add`),
   giving each assistant an isolated working directory sharing a single `.git/objects` store.

---

## **15. Doctorow's Critique, "Theory-Free" Meaning, and the Logic Onion Reconciliation**

The maintainer reflected on Cory Doctorow's critique of purely statistical curve-fitting and the
failure of dense vector embeddings to capture genuine semantic meaning:
- **The "Theory-Free" Hazard:** Vector embeddings reflect distributional co-occurrence (Firth: "you shall
  know a word by the company it keeps"). They have zero truth conditions (Tarski), zero rigid designation
  across possible worlds (Kripke), zero deontic inferential scorekeeping (Brandom), and no triadic sign
  structure (Peirce).
- **The "LLM Override Pathology" in `peirce`:** In earlier experiments in `~/src/peirce/`, passing structured
  logic through an end-to-end LLM caused the statistical probability cloud to swallow and erode the
  rigorous philosophical and modal-logical representations, turning formal inference into mushy associative
  approximations.
- **The Reconciliation in the Logic Onion (`mowgli`):**
  Embeddings are stripped of their sovereign status and assigned their proper role as **continuous perceptual
  sensors (Layer 1 $\rightarrow$ Layer 2)**:
  - *Firstness (Qualisigns):* Vector embeddings represent continuous qualitative textures and perceptual affinities.
  - *Secondness (Sinsigns/Indices):* Concrete tokens and indexical references in text.
  - *Thirdness (Legisigns/Symbols/Arguments):* Formal logic, Kripke frames, and event calculus ontologies.
  - *Golden Law:* **Embeddings propose; Logic disposes.** Tiny CPU models (~60–150 MB running in 5–8 ms on
    existing laptop hardware) propose candidate ontological bindings to guide deterministic parsers, while
    discrete modal logic enforces invariant truth conditions with zero hallucination.
- **The "Tera/Cray" Consolidation:** Formally documented in
  `~/src/mowgli/docs/architecture/HYBRID_SEMIOTIC_EMBEDDING_DESIGN.md` and `~/src/peirce/docs/hybrid-semiotic-embedding-architecture.md`,
  planning the project merger of `peirce`'s 10-class sign engine and Kripke tables into `mowgli`'s 7-layer
  Logic Onion stack.

---

## **16. Pre-LLM NLP Algorithmic Survey & Symbolic Reimplementation Roadmap**

The maintainer surveyed the pre-deep-learning natural language processing algorithmic design space
to guide clean-slate reimplementations under an NIH philosophy:
- **Full Survey Document:** Formally authored in `~/src/mowgli/docs/research/PRE_LLM_NLP_ALGORITHMIC_SURVEY.md`
  and cross-referenced in `~/src/peirce/docs/PRE_LLM_NLP_ALGORITHMIC_SURVEY.md`.
- **Six Strata Cataloged:**
  1. *Morphology & WFSTs:* Two-Level Morphology (TWOL, Koskenniemi); reference implementations `foma` (C)
     and `OpenFst` (C++).
  2. *Syntactic Parsing & Categorial Grammars:* Combinatory Categorial Grammar (Steedman; `C&C Parser`, `OpenCCG`)
     where syntactic reductions transparently evaluate lambda-calculus semantics; Earley/CKY charts; HPSG (`ACE`, `PET`).
  3. *Sequence Modeling:* Linear-chain Conditional Random Fields (CRFs; Lafferty, McCallum, Pereira; `CRF++`, `Wapiti`)
     avoiding label bias via global partition function normalization.
  4. *Discourse Representation & Semantics:* Johan Bos's `Boxer` mapping CCG parses into Discourse Representation
     Structures (DRT / Neo-Davidsonian event semantics); Abstract Meaning Representation (AMR / `JAMR`); FrameNet / PropBank.
  5. *Reference Resolution:* The Stanford Multi-Pass Deterministic Sieve (Raghunathan et al.); Jerry Hobbs' syntactic
     tree traversal; Centering Theory ($C_b, C_f$ transitions).
  6. *Lexical Ontologies:* WordNet synset graph metrics and ConceptNet relational assertions.
- **The Synthesis:** The entire pipeline executes locally on laptop CPUs in deterministic polynomial time,
  producing sound first-order / modal logic formulas with zero hallucination.




