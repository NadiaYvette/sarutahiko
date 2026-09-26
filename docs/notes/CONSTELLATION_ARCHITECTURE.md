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
