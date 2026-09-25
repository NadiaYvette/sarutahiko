# AI Coding Assistant Tooling, Code Intelligence & REPL Configuration

Status: DRAFT v0.1 · 2026-09-25 — Conceptual landscape, configuration architecture,
token economics, and graceful degradation hierarchy for AI coding assistant REPLs.
Related: `NIH_PLAN.md` (§2 package map, Tier 4 code intelligence, Tier 3 surfaces),
`DOC_STRATEGY.md` (§1 orientation, §7 small-context accommodation),
`AGENTS.md` (orientation projection for assistant drivers),
`HOKORA_SPEC.md` (Phase 1.5 composition proof),
`INFRASTRUCTURE.md` (toolchain, test matrix, git procedure).

**Thesis.** As software projects grow in architectural sophistication and codebase
volume, relying on brute-force text dumping into an LLM's context window rapidly exhausts
token budgets, degrades reasoning quality, and inflates development costs. Conversely,
mandating heavyweight external language daemons or closed vendor IDE setups creates
insurmountable friction for prospective human contributors.

This document establishes the **conceptual landscape** of AI coding assistant REPLs,
clarifies the distinctions between tools, skills, rules, plugins, hooks, context
engines, and memory providers, details how code intelligence (ctags, tree-sitter,
ast-grep, and LSPs) slashes token consumption, and formulates a **four-tier graceful
degradation hierarchy** that maximizes agent capability while preserving zero-friction
onboarding for human developers.

---

## 1. The Conceptual Landscape: Disentangling the Constellation

Modern AI coding assistant environments (e.g. Antigravity, Claude Code, Cursor, Zed,
Hermes, Aider) compose several distinct architectural concepts that are frequently
conflated. Their definitions, scopes, and lifecycles are sharply differentiated below:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE ASSISTANT CONSTELLATION ARCHITECTURE                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  User Interaction:      Slash Commands (/goal, /plan, /schedule)            │
│  Delegated Work:        Subagents (isolated context, specialized models)    │
├─────────────────────────────────────────────────────────────────────────────┤
│  Context Management:    Context Engine (token accounting, compression)      │
│  Long-Term Storage:     Memory Provider (event log, vector/BM25 retrieval)  │
├─────────────────────────────────────────────────────────────────────────────┤
│  Passive Constraints:   Rules (AGENTS.md, GEMINI.md, hierarchical policy)   │
│  On-Demand Workflows:   Skills (progressive disclosure runbooks)            │
│  Deterministic Guards:  Hooks (lifecycle event scripts: pre/post tool)      │
├─────────────────────────────────────────────────────────────────────────────┤
│  Executable Primitives: Tools (view_file, replace_file_content, run_cmd)   │
│  External Services:     MCP Servers (out-of-process tool/resource bridges)  │
├─────────────────────────────────────────────────────────────────────────────┤
│  Packaging Unit:        Plugins (distributable bundles of skills/rules/MCP) │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 The Taxonomy Defined

| Concept | What It Is | Lifecycle & Scope | Token Footprint |
|---|---|---|---|
| **Tools** | Executable primitive functions callable by the model (e.g. `view_file`, `replace_file_content`, `run_command`). | Ephemeral execution per turn; defined in system prompt or registered via MCP. | Moderate (JSON schema per tool in system prompt: ~50–150 tokens). |
| **Skills** | Specialized, multi-step procedural runbooks and workflows (e.g. `skills/<name>/SKILL.md`). | **On-Demand (Progressive Disclosure):** Only name and description are visible by default; full text loaded *only when activated*. | **Ultra-Low:** ~30–50 tokens quiescent; expands only during execution. |
| **Rules** | Contextual, passive constraints, conventions, and style invariants (e.g. `AGENTS.md`, `GEMINI.md`, `.agents/rules/*.md`). | Injected into context based on active working directory or file paths. | Low-to-Moderate (loaded per turn; deduplicated by resolved path). |
| **Plugins** | Distributable packaging bundles that combine related skills, rules, hooks, and MCP configurations under a single manifest. | Loaded at startup or discovered dynamically in plugin directories. | Determined by contents; unifies installation and dependency management. |
| **Hooks** | Deterministic scripts triggered by agent lifecycle events (e.g. `pre_tool_call`, `post_tool_call`, `on_session_start`). | Deterministic execution outside LLM inference; can block, validate, or mutate payloads. | Zero LLM tokens (runs natively in runtime without model prompting). |
| **MCP Servers** | Model Context Protocol out-of-process servers speaking JSON-RPC over `stdio` or SSE. | External child process; exposes dynamic tool catalogs, prompts, and resources. | Low: tool definitions advertised at startup; execution happens via IPC. |
| **Context Engine** | The in-memory working memory and context window manager. | Runs continuously within the turn loop: manages token counting, context budgeting, deduplication, and prompt cache alignment. | Meta-layer: actively *reduces* token consumption via compression and eviction. |
| **Memory Provider** | Long-term external storage and retrieval of cross-session knowledge and history. | Out-of-band retrieval: searches past sessions, event logs, or documentation via vector embeddings or BM25 indices. | Injects only relevant retrieved snippets (~200–500 tokens) instead of full history. |
| **Slash Commands** | Interactive user-facing shortcuts (e.g. `/goal`, `/plan`, `/schedule`) that switch execution modes. | User-triggered from the REPL prompt; alters turn control flow (e.g. enables autonomous loops). | Minimal UI metadata. |
| **Subagents** | Independent, delegated auxiliary conversations with their own isolated context windows and models. | Launched asynchronously for heavy research, broad searches, or verification passes. | Saves main context: broad exploratory noise stays in subagent; only synthesis returns. |

---

## 2. Code Intelligence: Slashing Token Consumption

The most catastrophic drain on token budgets and model attention is **context pollution**
caused by whole-file dumping. When an agent reads an entire 800-line Haskell module just
to inspect one type signature or call site, it consumes ~3,500 tokens per turn. Over a
10-turn debugging session, re-reading full files wastes tens of thousands of tokens.

Code intelligence replaces whole-file dumping with **progressive, surgical navigation**:

```
                       PROGRESSIVE DISCLOSURE FUNNEL
                                                                    Tokens
  ┌─────────────────────────────────────────────────────────────┐
  │  Level 0: Global Navigation (docs/INDEX.md, ctags, symbol)  │   ~10-50
  └──────────────────────────────┬──────────────────────────────┘
                                 │
  ┌──────────────────────────────▼──────────────────────────────┐
  │  Level 1: Structural Outline (tree-sitter, ast-grep)         │   ~100-250
  └──────────────────────────────┬──────────────────────────────┘
                                 │
  ┌──────────────────────────────▼──────────────────────────────┐
  │  Level 2: Targeted Slice View (view_file StartLine/EndLine) │   ~200-500
  └─────────────────────────────────────────────────────────────┘
```

### 2.1 The Code Intelligence Arsenal

#### 1. `ctags` / `hasktags` (Shallow Line Indexing)
- **What it is:** A flat, fast index (`tags` file) mapping symbol names (functions,
  data types, typeclasses) to exact filenames and line numbers or search patterns.
- **Why it matters:** It is near-instantaneous ($<0.5\text{s}$ generation time) and
  requires zero language server daemons.
- **Token Impact:** Instead of grepping 40 source files, the agent queries the `tags`
  file in 1 step, obtaining the exact file path and line number in $<20$ tokens.

#### 2. `tree-sitter` & `ast-grep` (Syntactic Structural Search)
- **What it is:** Incremental Concrete Syntax Tree (CST) parsing. `ast-grep` provides
  structural pattern matching (e.g. `sg --pattern 'data $NAME = $$$CONSTRUCTORS'`).
- **The "Cross-Language Hoogle" Metaphor:** Unlike regex, which is easily defeated by
  line breaks, comments, and whitespace, structural search queries the parse tree directly.
- **Token Impact:** An agent can request an "AST outline" of a file—extracting only top-level
  data type definitions and function signatures—condensing an 800-line module into a
  tight 40-line summary (~200 tokens instead of ~3,500 tokens).

#### 3. Language Server Protocol (LSP / `haskell-language-server`)
- **What it is:** Full compiler-backed semantic analysis (`textDocument/definition`,
  `textDocument/hover`, `textDocument/typeDefinition`).
- **Token Impact:** Provides exact type signatures for complex expressions without
  forcing the agent to mentally simulate the GHC typechecker over hundreds of imported lines.

---

## 3. The Graceful Degradation Hierarchy

A fundamental design tension in AI assistant engineering is:
1. **Developer Accessibility:** Anyone should be able to clone the repo and run `cabal build`
   with standard GHC tools, without having to configure complex language daemons,
   background containers, or proprietary IDE extensions.
2. **Agent Efficiency:** An assistant should leverage all available code intelligence
   tools to minimize token burn and latency.

To reconcile these goals, `sarutahiko` enforces a **four-tier graceful degradation hierarchy**:

```
Tier 3: Full Semantic Suite (LSP / HLS, Background MCP sidecars) [Optional]
   ▲
Tier 2: Structural AST Search (tree-sitter, ast-grep) [Optional]
   ▲
Tier 1: Shallow Symbol Index (ctags, hasktags) [Lightweight, Opt-In]
   ▲
Tier 0: Vanilla POSIX Baseline (git, cabal, standard shell tools) [MANDATORY]
```

### Tier 0: Vanilla POSIX Baseline (The Inviolable Floor)
- **Prerequisites:** GHC 9.12/9.14, Cabal 3.14+, git, standard POSIX utilities (`grep`, `find`).
- **Behavior:** The codebase builds, tests, and documents with standard cabal commands.
  AI coding assistants operate using standard file tools (`view_file`, `replace_file_content`,
  `run_command`).
- **Guarantee:** No external tool or daemon is mandatory for compilation, testing, or contributing.

### Tier 1: Shallow Symbol Index (`hasktags` / `ctags`)
- **Prerequisites:** `hasktags` (installed via `cabal install hasktags`) or Universal Ctags.
- **Configuration:** Generated via `make tags` or `hasktags -c packages/`. The resulting
  `tags` file is strictly `.gitignore`d.
- **Behavior:** Assistant REPLs use `grep -w "^SymbolName" tags` to locate definitions
  instantly, reading targeted slices via `view_file` rather than broad scans.

### Tier 2: Structural AST Search (`ast-grep` / `tree-sitter`)
- **Prerequisites:** `ast-grep` binary available in `PATH`.
- **Configuration:** Project-level rules stored in `.ast-grep/` (optional).
- **Behavior:** Assistant uses structural pattern matching for refactors (e.g. renaming
  record fields, auditing GADT constructors) without regex false positives.

### Tier 3: Semantic LSP & MCP Sidecars (Maximum Capability)
- **Prerequisites:** `haskell-language-server` (HLS) or custom MCP servers.
- **Configuration:** Defined in user-local or optional workspace MCP configs (`mcp_config.json`).
- **Behavior:** Full semantic hover, auto-completion, and definition lookups exposed directly
  as MCP tools to the agent. If absent, the agent seamlessly falls back to Tier 1/0.

---

## 4. Configuration Guide for AI Coding Assistant REPLs

This section serves as a practical orientation for configuring and driving AI coding
assistant REPLs on this repository.

### 4.1 Project-Level Rule Invariants (`AGENTS.md`)
`AGENTS.md` at the project root is the canonical **orientation projection**:
- It is read automatically by compliant AI assistant REPLs (Antigravity, Codebuff,
  Claude Code, Aider).
- **Budget Discipline:** Kept to $\sim 4\text{ KB}$ per `DOC_STRATEGY.md` §7.
- **Directing Attention:** It contains pointers to canonical documents rather than
  reproducing specifications, preventing context window bloat during initial orientation.

### 4.2 Local Workspace Skills (`.agents/skills/`)
Skills codify multi-step procedural workflows into version-controlled markdown runbooks:
- **Location:** `.agents/skills/<skill-name>/SKILL.md`
- **Structure:**
  ```markdown
  ---
  name: cabal-package-check
  description: Verifies cabal package bounds, commons imports, and compiles warning-free.
  ---
  # Instructions for Cabal Package Verification
  1. Run `cabal check` inside the target package directory.
  2. Verify that GHC2024 commons are imported.
  3. Ensure base bounds are `>= 4.20 && < 5`.
  ```
- **How It Saves Tokens:** The agent's system prompt only contains the name and description
  (~40 tokens). The body is loaded into context *only when the agent decides to execute that check*.

### 4.3 Interactive Slash Commands
- **`/goal`:** Transitions the agent into an autonomous, long-running execution mode.
  Recommended when executing a complete task packet (e.g. TP-0.2) where the agent
  can write modules, run `cabal build`, fix compiler warnings, and commit locally
  without requiring user prompts at every intermediate step.
- **`/plan`:** Requests an interactive, structured work breakdown before code modifications.

---

## 5. Architectural Recommendations for `sarutahiko`

1. **Adopt Tier 1 `hasktags` Generation in Project Scripts:**  
   Provide a zero-dependency script `bin/generate-tags` that runs `hasktags` if present,
   generating a local `tags` file ignored by git.
2. **Preserve Progressive Disclosure in All Documentation:**  
   Keep root files (`README.md`, `AGENTS.md`) compact and pointer-rich. Never embed full
   task packet implementations in orientation files.
3. **Encapsulate Code Intelligence within Tier 4 (`sarutahiko-parse` / `sarutahiko-tags`):**  
   In Phase 4, our own internal `sarutahiko-parse` (Earley chart parser) and `sarutahiko-tags`
   will provide native, row-typed code intelligence, making `sarutahiko` completely
   self-hosting for its own AI coding assistant capabilities without external dependencies.
