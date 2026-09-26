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
