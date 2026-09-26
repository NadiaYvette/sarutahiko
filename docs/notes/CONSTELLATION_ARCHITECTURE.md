# CONSTELLATION_ARCHITECTURE.md — The Wirth-Grade Full-Stack Ecosystem

Status: DESIGN DOCUMENT · v0.1 · 2026-09-26 (Author: Nadia Yvette Chambers)  
Domain: Cross-Cutting Systems Architecture & Multi-Repository Mesh  
Audience: Maintainers, AI coding assistants, and systems researchers

---

## 1. The Architectural Thesis: Modern Wirthian Clean-Slate Integration

In the history of computing, two contrasting paradigms have claimed the mantle of "building the entire
stack from scratch":

1. **The Eccentric Hobbyist Path (Terry Davis / TempleOS):**  
   Monolithic, non-reentrant, single-address-space ring-0 execution with hardcoded display modes and
   no memory protection. While an impressive individual feat, it lacked formal mathematical semantics,
   type theory, security boundaries, or modern hardware applicability.
2. **The Rigorous Scientific Tradition (Niklaus Wirth / Project Oberon):**  
   At ETH Zürich (1986–1992), Niklaus Wirth and Jürg Gutknecht achieved true full-stack vertical
   integration: from custom hardware (Ceres workstation, custom NS32032/RISC on FPGA) to language design
   (Oberon), single-pass compiler engineering (4,000 lines), and cooperative operating systems (viewer-based
   modular interface). The entire system was completely comprehensible by an individual, formally sound,
   and reproducible.

The maintainer’s panoramic body of work across `~/src/` aspires directly to the **Wirthian tradition**:
a 21st-century, formally verified, full-stack clean slate spanning silicon MMU specifications, coremapless
microkernels, page clustering in general-purpose OSes, multilingual MLIR compilers, neural-symbolic
representation, and row-polymorphic algebraic effect systems.

Crucially, **hierarchy cannot be assumed across this portfolio**: it is not a monolithic top-down tree,
but an **imbricated, interdependent mesh/constellation**.

---

## 2. The Constellation Mesh Topology

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE WIRTH-GRADE GRAND NIH CONSTELLATION                  │
├─────────────────────────────────────────────────────────────────────────────┤
│  HARDWARE & FORMAL MMU:                                                     │
│  - Custom RISC-V MMU Extension (satp 14/15, 256 B base page, inverted      │
│    hashed page table, SLB segment cache, 42 superpage sizes)                │
│  - Codenames: Ajiro (網代), Kusabi (楔), Kasen-42 (歌仙), Sudare (簾)       │
│  - Modelled in Sail, proved in Rocq, emulated in QEMU                       │
├─────────────────────────────────────────────────────────────────────────────┤
│  FORMAL VERIFICATION & TRUST LINE:                                          │
│  - Tessera (~/src/tessera/): §G1–G5 hardware trust line, Sail SMT proofs,   │
│    Rocq axiom-free lemmas, CBMC concurrency models                          │
├─────────────────────────────────────────────────────────────────────────────┤
│  KERNEL SUBSTRATES:                                                         │
│  - Telix (~/src/telix/): Clean-slate coremapless OS kernel, extent/morsel   │
│    allocator, software-managed verified refill handler, completion rings   │
│  - Linux-PGCL (~/src/pgcl/): Page clustering retrofit to Linux across 16+   │
│    architectures (one struct page per cluster, ABI-preserving)              │
│  - FreeBSD-PGCL: Forthcoming port of clustering to FreeBSD VM               │
├─────────────────────────────────────────────────────────────────────────────┤
│  COMPILERS & LANGUAGE SUBSTRATES:                                           │
│  - Frankenstein (~/src/frankenstein/): Multilingual MLIR lowering, arena    │
│    runtimes, cycle collection, bootstrap restoration                        │
│  - Organ-Bank (~/src/organ-bank/): 25+ language shims, organ-ir, organ-extract│
├─────────────────────────────────────────────────────────────────────────────┤
│  NEURAL-SYMBOLIC & MATHEMATICAL SUBSTRATE:                                  │
│  - Peirce / Mowgli (~/src/peirce/, ~/src/mowgli/): Mathematical formalization│
│    and diffusion representation                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  AI AGENT & ALGEBRAIC EFFECT ENGINE:                                        │
│  - Sarutahiko (~/src/sarutahiko/): Row-polymorphic algebraic effects,       │
│    large-anon extensible records, Yamaarashi streaming, Hashigakari DB AST  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Co-Design Dynamics & Interdependencies

The interdependencies between these repositories are structural and bi-directional:

1. **MMU Hardware $\leftrightarrow$ Telix $\leftrightarrow$ Tessera:**  
   The custom RISC-V MMU modes 14/15 require a kernel built around extents rather than radix trees.
   `telix` provides the coremapless extent allocator and software refill handler, while `tessera`
   proves the refill handler's coherence and determinism in Rocq.
2. **Page Clustering $\leftrightarrow$ General-Purpose OSes (`pgcl`):**  
   While `telix` explores clean-slate coremapless VM, `linux-pgcl` and `freebsd-pgcl` prove that page
   clustering can decouple allocation granularity from MMU page size in existing monolithic kernels
   without breaking the userspace ABI. Defect #143 analysis in `pgcl` directly feeds back into
   formal concurrency models in `tessera`.
3. **Foreign Surface Analysis $\leftrightarrow$ Compilers $\leftrightarrow$ Agent Codecs:**  
   `organ-bank` shims (25+ languages) and `organ-extract` parse foreign source ASTs into `organ-ir`.
   `frankenstein` lowers these representations into MLIR dialects. In turn, `sarutahiko`'s `kogaki`
   codec layer uses these compiler ASTs as test oracles and structural fixtures for protocol encoding.

---

## 4. The Sideband Repository Pattern

Large-scale modifications to monolithic upstreams (Linux kernel, FreeBSD, QEMU) must avoid cluttering
upstream trees with out-of-tree test scripts, CBMC proofs, and reproduction suites.

### The Trade-Off Space:
- **Submodules as Root:** Registering the upstream kernel as a submodule inside the harness (`pgcl/linux/`)
  pins exact commit SHAs, but introduces severe friction: 5 GB+ cloning overhead, frequent detached HEAD
  commits, and complex rebase mechanics.
- **Symbiotic Worktrees / Peer Repositories:** Maintaining `~/src/linux/` as a sibling repository and
  mounting lightweight `git worktree` instances or specifying out-of-tree build targets (`KDIR=...`)
  is the most frictionless operational workflow for active development.
- **Thin Git Bundles (The PGCL Pattern):** To ensure full repository durability across privacy-conscious
  or quota-limited git hosts (Framagit, Disroot) that cannot host 5 GB kernel trees, `~/src/pgcl/kernel-bundles/`
  stores thin git bundles (≈900 KB) containing all development branches against release tags (e.g. `v7.1`).
  Any user can unbundle the development branch onto a stock Linux clone in seconds.

---

## 5. Ecosystem-Wide Documentation Standards & Diátaxis Alignment

To ensure that all repositories across the constellation maintain uniform engineering rigor, the
documentation strategy established in `sarutahiko/docs/DOC_STRATEGY.md` is elevated to an ecosystem standard:

1. **Strict Genre Separation:**
   - **Design Notes (`notes/*.md`):** Problem statements, rationale, invariant definitions, rejected alternatives.
   - **Specifications (`specs/*.md`):** Formal state machines, wire formats, RFC-2119 keywords, proof obligations.
   - **Plans (`plans/*.md`):** Hermetic Work Breakdown Structures, verifiable task packets, exit gates.
   - **Living Registers (`registers/*.md`):** Attics, reuse decisions, codec quirks, glossaries.
   - **Transcripts (`transcripts/*.md`):** Archival primary sources, provenance trails, reasoning history (non-normative).
   - **Orientation Projections (`AGENTS.md`):** Strict ~4 KB pointer budgets directing AI coding assistants
     to canonical sources without token bloat.
2. **Diátaxis Framework Integration:** Clear conceptual separation between Tutorials (learning-oriented),
   How-To Guides (task-oriented), Reference (information-oriented), and Explanation/Architecture (understanding-oriented).
3. **Formal Verification Trails:** System software repositories must maintain explicit `failure-modes-*.md`,
   invariant catalogues, and proof-obligation matrices.

---

## 6. Index State Partitioning & Multi-Tier Scoping

As code intelligence databases (`.hiedb`, `tags`, `csearch` trigrams, AST graphs) proliferate,
a fundamental state partitioning challenge arises: most developer tools assume a single, leaf-level
project root, whereas constellation research frequently requires searches across wide, imbricated fields.

The architecture resolves this through a **4-tier partitioned scoping hierarchy**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       INDEX STATE PARTITIONING TIERS                        │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 1: Leaf Project Scope (Local .tags, .hiedb, per-repo FTS5)            │
│          - Confined to current working tree; updated on file save.          │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 2: Subsystem Constellation Scope (tessera + telix + pgcl cluster)     │
│          - Dedicated multi-repo cluster index (e.g. cluster-vm.csearchindex)│
│          - Bridges hardware proofs, coremapless OS, and kernel clustering.  │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 3: Global Workspace Scope (~/src/ wide-field index)                   │
│          - Complete flat-file trigram index (cindex ~/src) allowing instant │
│            regex search across all owner-class and reference repositories.  │
├─────────────────────────────────────────────────────────────────────────────┤
│  Tier 4: Ephemeral External Universe (Hackage, crates.io, opam)             │
│          - Ephemeral, read-only indices of external package registries      │
│            without cloning full upstream repositories onto local disks.     │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Mechanism for SQLite Stores:** Sibling `.hiedb` or `symbols.sqlite3` databases use SQLite's
  `ATTACH DATABASE` mechanism or unified schema tables with a `repo_id` column, allowing queries to
  either isolate a single leaf repo or union-query across the entire constellation.
- **Mechanism for Trigram Searches:** Tools like `csearch` switch scopes via environment variables
  (`export CSEARCHINDEX=~/.cache/indices/cluster-kernel.csearchindex`), giving agents explicit control
  over query blast radius.

---

## 7. Dense Embeddings, Vector Storage (`sqlite-vec`), and Hybrid RRF

While trigram search (`csearch`) and lexical search (FTS5 BM25) match literal characters and words,
they are semantically blind: searching for "handling translation faults" will miss documentation that
refers exclusively to "MMU refill trap dispatch" because the words share no overlap.

### 7.1 What Dense Embeddings Are and Why They Differ
- **Dense Embeddings:** A neural encoder (transformer) projects an arbitrary paragraph or code snippet
  into a high-dimensional vector space (e.g. 384 or 768 floating-point numbers). Concepts that share
  semantic meaning cluster close together (measured by cosine similarity or inner product), regardless
  of terminology divergence.
- **The Blindness of Pure Vector Search:** Pure vector search is notoriously "fuzzy" on code: it cannot
  guarantee exact identifier matching (it frequently confuses `runProcessIO` with `withSupervisedChild`),
  producing hallucinated false positives.
- **The Solution — Hybrid Reciprocal Rank Fusion (RRF):**  
  As designed in `kioku` and `MEMORY_ENGINE_DESIGN.md`, the ideal retrieval pipeline fuses:
  $$\text{Score}(d) = \frac{1}{60 + \text{Rank}_{\text{BM25}}(d)} + \frac{1}{60 + \text{Rank}_{\text{Vec}}(d)}$$
  Exact symbol matches receive top rank via BM25, while dense embeddings retrieve semantically relevant
  passages that used divergent phrasing.

### 7.2 The Zero-Daemon Local Software Stack
Dense embeddings can be deployed completely locally without heavyweight background daemons or external
SaaS dependencies:
1. **Vector Storage: `sqlite-vec` (`~/src/sqlite-vec/`):**  
   Compiles directly via `make loadable` into a zero-overhead C extension (`vec0.so`). It exposes virtual
   tables (`CREATE VIRTUAL TABLE vec_items USING vec0(...)`) allowing vector KNN searches natively
   inside SQLite alongside FTS5 tables.
2. **Lightweight Embedding Encoders (Zero-GPU, Fast CPU):**  
   - Models: Small, highly optimized open models like `nomic-embed-text-v1.5` (137M parameters, ~150 MB)
     or `bge-small-en-v1.5` (~67 MB).
   - Execution Engines: `llama.cpp` (`llama-embedding` binary or `llama-server --embedding`) or pure Rust
     `fastembed-rs` (ONNX runtime embedded, no Python dependencies).

