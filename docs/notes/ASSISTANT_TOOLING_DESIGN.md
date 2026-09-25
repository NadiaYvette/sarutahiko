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

### 2.2 The Local Tooling Inventory

An audit of the local development environment reveals a rich, already-installed
suite of AST-aware and agent-specialized tools:

| Binary | Location | Primary Role & Capabilities |
|---|---|---|
| **`ast-grep` (`sg`)** | `~/.cargo/bin/ast-grep` | Ultra-fast structural code search, linting, and rewrite using tree-sitter syntax trees. |
| **`topiary`** | `~/.cargo/bin/topiary` | Tree-sitter-based universal code formatter (Tweag) driven by tree-sitter query files. |
| **`tsquery`** | `~/.local/bin/tsquery` | Dedicated CLI for executing raw tree-sitter S-expression queries against source files. |
| **`hasktags`** | `/usr/bin/hasktags` | Instant Haskell symbol indexer; scans `packages/` in $<0.1\text{s}$ generating `tags`. |
| **`ctags`** | `/usr/bin/ctags` | Universal Ctags fallback for multi-language symbol extraction. |
| **`cabal-fmt`** | `~/.local/bin/cabal-fmt` | Deterministic formatter for `.cabal` package definition files. |

### 2.3 `tricorder` (`~/src/tricorder/`): Background GHCi Daemon for AI Agents

`~/src/tricorder/` is a specialized developer tool built specifically for **Haskell + LLM coding agents**:
- **Continuous Background Compilation:** Runs a persistent GHCi daemon that monitors all packages
  in a `cabal.project` workspace, rebuilding incrementally on file change events.
- **Token Conservation Advantage:** Instead of an AI assistant executing a full `cabal build all`
  (which dumps 200–500 lines of terminal output and takes 5–15 seconds), the agent queries:
  ```bash
  tricorder status --json
  ```
  or connects directly to the bundled **`tricorder-mcp`** server. The assistant receives only
  structured JSON diagnostics (`file`, `line`, `col`, `message`) in $<50$ tokens.
- **Dependency Source Exploration:** Provides `tricorder source Some.Module` to retrieve the
  exact source of a dependency from disk without guessing package paths.

### 2.4 `haskell-language-server` (`~/src/haskell-language-server/`)

The canonical Haskell Language Server (HLS) provides full semantic type checking, definition
jumps, and cross-references. While heavy to run continuously in resource-constrained environments,
HLS can be bridged to AI assistants via:
1. **Editor Bridge:** Zed, Cursor, or VS Code passing LSP diagnostics to the AI assistant.
2. **LSP-to-MCP Bridge:** Running an MCP adapter that exposes HLS `textDocument/definition` and
   `textDocument/hover` as callable agent tools.

---

## 3. Context Engines & Memory Providers: Off-the-Shelf vs. In-Tree

AI coding assistants require two levels of memory:
1. **Working Memory (Context Engine):** Manages the in-flight conversation context window.
2. **Long-Term Memory (Memory Provider):** Retains facts, decisions, and past turns across sessions.

### 3.1 Off-the-Shelf Solutions (Available Today)

Where off-the-shelf components exist and how to obtain them:

| Category | Product / Package | Source & Installation | Mechanism |
|---|---|---|---|
| **Context Engine** | **Continue.dev Context Providers** | `npm install -g @continuedev/core` | Extensible `@codebase` (vector search via LanceDB), `@docs`, and `@diff` context injecters. |
| **Context Engine** | **Antigravity / Claude Compactors** | Built-in to REPL harnesses | Sliding-window summarization: compresses older turns when context reaches 80% capacity. |
| **Context Engine** | **Mem0 / Letta** | `pip install mem0ai` / `letta` | Automatically extracts facts, user preferences, and project decisions into a local graph/vector store. |
| **Memory Provider** | **Anthropic Memory MCP Server** | `npm install -g @modelcontextprotocol/server-memory` | Official reference MCP memory server: stores entities, relations, and observations as a local JSON graph. |
| **Memory Provider** | **SQLite-vec MCP Server** | `pip install mcp-server-sqlite` / npm | Local SQLite database with vector similarity extensions, exposed over stdio as an MCP server. |
| **Memory Provider** | **Chroma / Qdrant MCP** | Docker / pip / npm | Local vector database running local embedding models (e.g. `all-MiniLM-L6-v2`) for semantic code search. |

### 3.2 In-Tree `sarutahiko` Vision: Utaibon (謡本)

While off-the-shelf memory servers provide immediate utility, they have critical limitations
for high-assurance Haskell development:
- **Lossy & Unstructured:** Vector similarity search frequently retrieves syntactically similar
  snippets that are semantically irrelevant or hallucinated.
- **No Concurrency Safety:** Multiple agent sessions writing to the same knowledge graph risk
  corrupting or interleaving facts.

**Utaibon's Event-Sourced Architecture ([`MEMORY_ENGINE_DESIGN.md`](../notes/MEMORY_ENGINE_DESIGN.md)):**
- **Strict Event Log:** Every turn is an immutable row in SQLite `session_events` with spine v0.2.
- **Fail-Closed Session Locking:** Atomic lease acquisition via `session_locks` with `BEGIN IMMEDIATE`.
- **Pure Fold Reducers:** Retrieval, checkpoints, and session history are pure left-folds over the
  event log, guaranteeing bit-identical replay (RPL-1).
- **Prompt-Cache Alignment:** Invariant ordering C1–C6 guarantees maximum prefix sharing for
  hardware prompt caches.

---

## 4. The Graceful Degradation Hierarchy

A fundamental design tension in AI assistant engineering is:
1. **Developer Accessibility:** Anyone should be able to clone the repo and run `cabal build`
   with standard GHC tools, without having to configure complex language daemons,
   background containers, or proprietary IDE extensions.
2. **Agent Efficiency:** An assistant should leverage all available code intelligence
   tools to minimize token burn and latency.

To reconcile these goals, `sarutahiko` enforces a **four-tier graceful degradation hierarchy**:

```
Tier 3: Full Semantic Suite (LSP / HLS, Background MCP sidecars, tricorder-mcp) [Optional]
   ▲
Tier 2: Structural AST Search (tree-sitter, ast-grep, topiary) [Optional]
   ▲
Tier 1: Shallow Symbol Index (ctags, hasktags via bin/generate-tags) [Lightweight, Opt-In]
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
- **Prerequisites:** `hasktags` or Universal Ctags.
- **Configuration:** Generated via `./bin/generate-tags`. Output file `./tags` is `.gitignore`d.
- **Behavior:** Assistant REPLs use `grep -w "^SymbolName" tags` to locate definitions
  instantly, reading targeted slices via `view_file` rather than broad scans.

### Tier 2: Structural AST Search (`ast-grep` / `topiary`)
- **Prerequisites:** `ast-grep` (`sg`) or `topiary` in `PATH`.
- **Behavior:** Assistant uses structural pattern matching for refactors (e.g. renaming
  record fields, auditing GADT constructors) without regex false positives.

### Tier 3: Semantic LSP & MCP Sidecars (Maximum Capability)
- **Prerequisites:** `tricorder`, `haskell-language-server`, or external MCP memory servers.
- **Configuration:** Defined in optional workspace MCP configs (`mcp_config.json`).
- **Behavior:** Continuous background diagnostics and semantic type search. If absent, the
  assistant seamlessly falls back to Tier 1/0.

---

## 5. Practical Guide for Newbies & Maintainers

### 5.1 Newbie Quickstart: Keeping Token Burn Minimal
If you are running an AI coding assistant REPL on this codebase and want to minimize token costs:

1. **Generate the Symbol Tags:**
   ```bash
   ./bin/generate-tags
   ```
2. **Never Dump Full Modules:**
   - Instead of asking the assistant to *"read all packages to find where Field is"*, ask:
     *"Find where Field is defined using tags and show only the definition."*
   - The assistant will query `tags` and view just lines 10–25 of `Sarutahiko/Fields.hs` (20 tokens vs 2,000 tokens).
3. **Use Structural Search for Code Audits:**
   ```bash
   # Find all data type definitions across packages
   sg -p 'data $NAME = $$$CONSTRUCTORS' packages/
   ```
4. **Use Autonomous Mode for Complete Task Packets:**
   - Type `/goal` when starting a task packet (e.g. TP-0.2) so the assistant can write modules,
     run compiler checks, and commit locally without back-and-forth prompting.

### 5.2 Maintainer Guide: Repository Hygiene & Progressive Disclosure
1. **Keep `AGENTS.md` and `README.md` Lean:**  
   Always obey the $\sim 4\text{ KB}$ budget in `AGENTS.md`. Add pointer links, never inline
   large implementations.
2. **Keep `.agents/skills/` Modular:**  
   Write self-contained, single-purpose skills (`.agents/skills/<name>/SKILL.md`). The system
   prompt only displays the 2-line description until activated.
3. **Keep `tags` Ignored:**  
   Ensure generated index files (`tags`, `TAGS`, `.ghc.environment.*`) remain strictly in `.gitignore`.

---

## 6. The Packaging Precedent: Lessons from Tweag's Tricorder & agent-plugins.org

An examination of Tweag’s [`tricorder`](file:///home/nyc/src/tricorder/) provides a valuable,
real-world precedent for how AI agent capabilities should be packaged and distributed across
diverse REPL platforms.

### 6.1 The Unified `agent-plugins.org` Structure
Rather than inventing an ad-hoc layout, `tricorder` adopts the emerging open standard
schemas from `agent-plugins.org`:

```
agent-plugins/my-plugin/
├── plugin.json         # Manifest schema: https://agent-plugins.org/schemas/1.0.0/plugin.schema.json
├── mcp.json            # MCP server schema: https://agent-plugins.org/schemas/1.0.0/mcp.schema.json
└── skills/             # On-demand markdown procedural runbooks
    └── my-skill/
        └── SKILL.md
```

- **`plugin.json`:** Holds canonical metadata (`name`, `description`, `version`, `keywords`).
- **`mcp.json`:** Defines the server startup command using `${PLUGIN_ROOT}` variable
  interpolation (e.g. `"${PLUGIN_ROOT}/servers/my-mcp-binary"`), ensuring the plugin remains
  relocatable regardless of where it is installed.
- **`skills/`:** Houses the progressive-disclosure runbooks (`SKILL.md`) that teach the LLM
  how and when to invoke the tool.

### 6.2 Multi-REPL Projections via Projections Directories
A major operational challenge is supporting multiple AI coding assistants simultaneously
(Claude Code, Antigravity, OpenAI Codex, Zed) without duplicating configuration code.
`tricorder` demonstrates the projection pattern:
- The canonical implementation lives in `agent-plugins/`.
- Platform-specific adapter folders project this implementation cleanly:
  - `.claude-plugin/marketplace.json` $\rightarrow$ points to `./agent-plugins/*`
  - `.codex-plugin/` $\rightarrow$ points to `./agent-plugins/*`
  - `.agents/plugins/marketplace.json` $\rightarrow$ points to `./agent-plugins/*`

### 6.3 Application to `sarutahiko`
`sarutahiko` adopts this precedent in two directions:
1. **Outbound Capability Export (Phase 1 Wire Flagship):**  
   When `sarutahiko-mcp` is delivered in Phase 1, it will package its tool catalog (record
   introspection, schema translation, ReAct execution) using this exact `agent-plugins.org`
   structure. Any external assistant (Claude Code, Cursor, Zed) can install `sarutahiko`
   as an MCP plugin by pointing to its `marketplace.json`.
2. **Inbound Developer Tooling (Zero-Contamination Consumption):**  
   Developers running `sarutahiko` locally can mount developer plugins (such as `tricorder-mcp`
   from `~/src/tricorder/`) in their private assistant configurations to accelerate feedback
   loops, without imposing any build-time or runtime dependencies on the `sarutahiko` core codebase.
