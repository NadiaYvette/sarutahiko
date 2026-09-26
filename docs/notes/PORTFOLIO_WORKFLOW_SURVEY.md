# PORTFOLIO_WORKFLOW_SURVEY.md — Interrelated Project Tracking, Workflow Engines & Native Vector Topologies

Status: SURVEY & ARCHITECTURAL NOTE · v0.1 · 2026-09-26 (Author: Nadia Yvette Chambers)  
Domain: Cross-Cutting Systems Engineering, Portfolio Workflow Tracking & Vector Algorithms  
Related: `NIH_PLAN.md` (roadmap), `CONSTELLATION_ARCHITECTURE.md` (mesh topology), `HASHIGAKARI_DESIGN.md` (data access)

---

## 1. The Core Dilemma: The Panoramic Brambles vs. Linear Task Trackers

The maintainer’s body of work spans an interconnected constellation:
- **Hardware & MMU:** Custom RISC-V MMU (`satp` 14/15, 256 B base page, inverted hashed page table).
- **Formal Verification:** `tessera` (Sail specs, Rocq lemmas, CBMC concurrency models).
- **Kernel Substrates:** `telix` (coremapless extent VM) and `linux-pgcl` / `freebsd-pgcl` (page clustering).
- **Compilers:** `frankenstein` (MLIR lowering) and `organ-bank` (25+ language shims).
- **Mathematical / Neuro-Symbolic:** `peirce` / `mowgli`.
- **Agent Substrate:** `sarutahiko` (row-typed algebraic effects, Yamaarashi streaming, Hashigakari database AST).

### Why Standard Project Management Collapses
Standard developer tracking tools (GitHub Issues, Trello, Jira, standard Kanban boards) assume **isolated, linear tasks** moving through flat columns (`To Do → In Progress → Done`).  
In reality, the portfolio is an **imbricated DAG (Directed Acyclic Graph) / Hypergraph**:
- An AST extraction pass in `organ-bank` unblocks an MLIR lowering pass in `frankenstein`.
- Which provides concrete test fixtures for `kogaki` wire codecs in `sarutahiko`.
- While kernel Defect #143 analysis in `pgcl` alters the proof obligations in `tessera`.

A linear board loses all causal relationships, producing a chaotic "vista of brambles."

---

## 2. Survey of Pre-Existing Systems & Methodologies for Interrelated Project Tracking

To manage cross-cutting polyrepo ecosystems without losing dependencies, several paradigms exist across computer science:

### 2.1 Graph-Based & Dependency Task Engines
1. **Taskwarrior / Timewarrior:**
   - *Core Mechanism:* Command-line, plain-text/JSON task manager supporting explicit dependency edges (`task 102 modify depends:45,88`).
   - *Strengths:* Automatically calculates the **active frontier** (tasks whose dependencies are 100% satisfied). Computes dynamic urgency scores based on blocker status and deadlines. Headless, easily scripted, zero-daemon.
   - *Fit:* Excellent for personal CLI workflow tracking across multi-repo dependencies.
2. **Emacs Org-Mode / Org-Roam / Org-Agenda:**
   - *Core Mechanism:* Outline-based plain-text markup with bidirectional networked links, task states (`TODO`, `WAITING`, `BLOCKED`), and transclusion.
   - *Strengths:* `org-agenda` can aggregate tasks across dozens of separate repositories and directories (`~/src/*/TODO.org`) into a single unified timeline or dependency view.
   - *Fit:* The gold standard for human-centric associative note-taking and imbricated idea tracking.
3. **Beads / Linear DAGs / GitLab Epics:**
   - *Core Mechanism:* Multi-repository issue tracking with explicit parent-child and blocking dependency trees.

### 2.2 Monorepo / Multi-Repo Co-Design & Revision DAGs
1. **Pants / Bazel (Build Target Graphs):**
   - *Core Mechanism:* Hermetic multi-language build systems centered on queryable Directed Acyclic Graphs (`bazel query 'deps(//...)'`).
   - *Relevance:* While heavyweight for simple note-tracking, their concept of **fine-grained target caching and dependency invalidation** is the exact model required when cross-cutting changes touch compiler shims and kernel harnesses.
2. **Jujutsu (`jj`):**
   - *Core Mechanism:* A Git-compatible version control system that models working copies and commits as a **first-class Directed Acyclic Graph** with anonymous branch heads and automatic conflict reification.
   - *Relevance:* Eliminates branch management friction when developing interrelated changes across multiple repositories simultaneously.
3. **Radicle:**
   - *Core Mechanism:* Peer-to-peer code collaboration built on Git, storing issues, discussions, and patch reviews as cryptographically signed Git references (CRDTs).
   - *Relevance:* Fully local-first; tracks repository state and issues without reliance on centralized SaaS hosts.

---

## 3. Nadeem's `keiro` / `keiki` as a Sovereign Human + Agent Task Engine

Nadeem Bitar's agent orchestration stack (`~/src/typed-language-model-arena/cabal.project`) provides an extraordinary, underappreciated foundation for solving this problem natively in Haskell:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                 NADEEM BITAR'S STATE & WORKFLOW STACK                       │
├─────────────────────────────────────────────────────────────────────────────┤
│  keiki:         Pure, zero-database finite-state transducers (symbolic      │
│                 registers, pure transition functions).                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  kiroku-store:  Append-only immutable event log (PostgreSQL WAL or SQLite). │
├─────────────────────────────────────────────────────────────────────────────┤
│  keiro:         Durable execution and distributed workflow runtime over     │
│                 the event log (retries, timeouts, step coordination).       │
├─────────────────────────────────────────────────────────────────────────────┤
│  shibuya:       Supervised worker queues dispatching tasks to handlers.     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Is `keiro` for Computers or Human Affairs?
Technically, `keiro` was engineered for computational workflows (agent loops, tool calls, distributed retries). However, **because it is built on event sourcing and pure state transducers (`keiki`), it can represent human affairs, research milestones, and cross-repo project DAGs identically**:

1. **Event Types:**
   ```haskell
   data TaskEvent
     = TaskCreated   { taskId :: TaskId, repo :: RepoId, description :: Text, dependsOn :: [TaskId] }
     | TaskBlocked   { taskId :: TaskId, reason :: Text }
     | TaskUnblocked { taskId :: TaskId }
     | TaskClaimed   { taskId :: TaskId, actor :: Actor } -- Human (Nadia) or Agent (Antigravity/Hermes)
     | TaskCompleted { taskId :: TaskId, artifactUri :: URI }
   ```
2. **Deterministic Frontier Projection:**  
   The pure transducer consumes the append-only log and computes the **Active Frontier**—the exact list of tasks across all repositories that are ready for execution right now.
3. **Human Helper Tooling:**  
   By authoring a lightweight CLI/TUI helper (`keiro-agenda` or `keiro-board`), the maintainer and AI agents can query the exact same workflow engine, giving both human and machine a unified, ACID-guaranteed ledger of progress across the entire constellation.

---

## 4. Native Haskell Vector Topologies (HNSW, IVF, DiskANN/Vamana)

While `sqlite-vec` provides an immediate C-based bridge for vector similarity, developing **pure, native Haskell vector indexing libraries** aligns with the program's anti-bloat and type-safe principles:

### 4.1 Why Spatial Trees Fail in High Dimensions ($d = 768$)
Spatial trees (`~/src/spatial-trees/`):
- $R$-trees, $R^*$-trees, and $X$-trees partition space using minimal bounding hyper-rectangles.
- In low dimensions ($d \le 16$), bounding boxes cleanly partition space.
- In 768 dimensions (**the curse of dimensionality**), the volume of bounding hypercubes explodes, causing internal node boxes to overlap by nearly 100%. Tree descent degenerates to linear $O(N)$ scan.

### 4.2 The Haskell High-Dimensional Vector Stack Roadmap
To provide native, high-performance vector search in Haskell without C FFI bottlenecks:

1. **Contiguous Unboxed Storage & SIMD Primitives:**
   - Using GHC's `ByteArray#` and unboxed pinned vectors (`Data.Vector.Storable`).
   - Leveraging GHC 9.12/9.14 SIMD vector extensions for hardware-accelerated dot-product and cosine distance computations.
2. **Hierarchical Navigable Small World (HNSW):**
   - High-dimensional skip-lists over proximity graphs.
   - Modeled in Haskell using mutable unboxed adjacency arrays in the `ST` or `IO` monad, wrapped in pure snapshot queries.
3. **Inverted File Index (IVF-PQ):**
   - K-means clustering over vector centroids, storing residual vectors compressed via Product Quantization (8-bit quantization).
4. **DiskANN / Vamana (SSD-Optimized Graph Navigation):**
   - Memory-mapped graph structures where graph nodes align with hardware disk blocks/pages (e.g. 4 KiB or 64 KiB pages), minimizing NVMe read amplification during nearest-neighbor graph traversal.
