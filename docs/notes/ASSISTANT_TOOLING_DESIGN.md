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

## 5. Practical Guide for Newbies & Maintainers: The `sarutahiko-tooling` Honorary Package

Per [`DOC_STRATEGY.md`](../notes/DOC_STRATEGY.md), the assistant configuration environment
(`.agents/`, `.mcp.json`, and associated skills, rules, and scripts) is formally elevated
to an **honorary package** within the repository: `sarutahiko-tooling`. While not a Cabal
library distributed to Hackage, it possesses its own contracts, degradation hierarchy,
lifecycle, and strict boundaries.

### 5.1 Newbie Quickstart: Keeping Token Burn Minimal via the Bootstrapping Suite

If you are a newcomer or AI coding assistant running a REPL in this workspace, you have
immediate access to our **bootstrapping toolchain** (leveraging Tweag's `tricorder`,
Nadeem Bitar's `shikumi`, Contextful, and fast symbol indices):

1. **Instant Compiler Checks via Tricorder (<50 tokens):**
   - Instead of running `cabal build all` (which consumes 200–500 lines of terminal output
     and ~2,500 tokens), query structured diagnostics:
     ```bash
     tricorder status --json
     ```
   - If `tricorder-mcp` is active in `.mcp.json`, call the MCP tool `status(wait: true)`.
     The assistant receives only machine-readable errors/warnings with zero terminal clutter.

2. **Never Dump Full Modules (The Progressive Disclosure Rule):**
   - **Step 1 (Find):** Run `grep -w "^SymbolName" tags` (<15 tokens).
   - **Step 2 (View):** Use `view_file` specifying `StartLine` and `EndLine` (±15 lines around
     the symbol). Never read entire 500-line modules just to inspect a signature.

3. **Structural Code Audits via `ast-grep`:**
   - Use `sg` to search Concrete Syntax Trees directly without regex false positives:
     ```bash
     # Find all GADT effect signatures
     sg -p 'data $NAME :: Effect where $$$CONSTRUCTORS' packages/

     # Find all row-typed record definitions
     sg -p 'type $NAME = Record $F $R' packages/
     ```

4. **Tracing & Replay via Nadeem's `shikumi`:**
   - To inspect prompt assemblies, token usage, and tool executions from language-model runs:
     ```bash
     shikumi trace
     ```
   - To deterministically verify an execution without spending network tokens:
     ```bash
     shikumi replay <trace-id>
     ```

5. **Token-Budgeted Context Packs via `contextful`:**
   - When researching cross-cutting features, query Contextful for an evidence pack bounded
     by a strict token ceiling:
     ```bash
     cxf pack "effect handlers polysemy effectful" --max-tokens 1500
     ```

6. **The Inviolable Fallback (Tier 0 POSIX Baseline):**
   - If any daemon, MCP server, or external binary fails or is absent:
     ```bash
     cabal build all
     cabal test all
     ```
     The codebase *never* requires external daemons or specialized tooling to build and test.

---

### 5.2 Maintainer Guide: Repository Hygiene, Honorary Package Governance & Self-Hosting

1. **Honorary Package Boundaries (`sarutahiko-tooling`):**
   - All assistant tooling configurations reside in `.agents/`, `.mcp.json`, or user-local
     directories (`~/.local/bin/`).
   - **Zero Cabal Contamination:** Bootstrapping tools (`tricorder`, `shikumi`, `kioku`,
     `contextful`) must **never** be injected into core `cabal.project` package dependencies.
     They operate strictly out-of-process via stdio IPC / MCP bridges.

2. **The Bootstrapping to Self-Hosting Transition Lifecycle:**
   `sarutahiko` follows a staged self-hosting plan:
   - **Stage 1 (Current Bootstrap):** External tools (`tricorder-mcp`, `shikumi`, `kioku-core`,
     `contextful`, `hasktags`) provide immediate developer acceleration and token savings.
   - **Stage 2 (Hokora Vertical Slice — Phase 1.5):** In-tree SQLite event spine, fail-closed
     leases, and RPL-1 deterministic replay harness replace external session tracking.
   - **Stage 3 (Full Self-Hosting — Phase 2 & 3):** `sarutahiko-mcp` (in-tree MCP server),
     `utaibon` (in-tree event memory with embedded SQLite FTS5 + `sqlite-vec`), and
     `sarutahiko-parse` (in-tree Earley chart parser) replace the bootstrapping suite entirely.

3. **Living Registers as External Memory:**
   - Maintain the single-point-of-truth invariant: when adding dependencies, consult
     [`REUSE_REGISTER.md`](../registers/REUSE_REGISTER.md); when recording provider wire
     peculiarities, update [`CODEC_QUIRKS.md`](../registers/CODEC_QUIRKS.md).
   - Obey the ~4 KB budget in [`AGENTS.md`](../../AGENTS.md). Keep orientation files as pointers;
     never duplicate canonical architectural text.

4. **Tag & Index Hygiene:**
   - Keep generated files (`tags`, `TAGS`, `.ghc.environment.*`, `dist-newstyle/`) strictly
     in `.gitignore`.
   - Run `./bin/generate-tags` whenever modules or signatures are added or renamed.

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

---

## 7. The REPL Configuration Plan & Comparative Evaluation: Is Off-the-Shelf "Better Than Nothing"?

A central question in standing up AI coding assistant infrastructure is whether deploying
off-the-shelf Context Engine and Memory Provider plugins is genuinely an improvement over
having **nothing at all** in those roles, especially when developing a strict, type-driven
Haskell ecosystem like `sarutahiko`.

The evaluation below analyzes the two components independently, followed by the concrete
REPL configuration plan incorporating Tweag's `tricorder`.

### 7.1 Evaluation: Off-the-Shelf Context Engines vs. "Nothing At All"

#### What "Nothing At All" Looks Like
In an AI coding assistant REPL, having "no context engine" means raw, unmanaged linear
message accumulation: every user turn, assistant thought, tool call, compiler diagnostic,
and file view is appended monotonically to the conversation array.

In practice, running with no context engine triggers four distinct failure modes:
1. **Hard Context Exhaustion (Crash):** A 200,000-token context window is consumed rapidly
   during active development (a few multi-file edits and compiler build logs fill 100k+
   tokens in 15–20 turns). Once the ceiling is reached, the model provider returns a fatal
   HTTP 400 `context_length_exceeded` error, abruptly terminating the session.
2. **Attention Collapse ("Lost in the Middle"):** Beyond ~50k tokens of raw terminal transcripts
   and file contents, model reasoning degrades significantly. Invariants and architectural
   rules defined in early turns are drowned out by subsequent noise.
3. **Quadratic Cost Explosion:** If the conversation history is never compacted, every subsequent
   turn re-transmits the entire 100k+ token history. Even with prompt cache read discounts,
   cumulative API token costs balloon quadratically.
4. **Naive FIFO Truncation:** Primitive REPLs that lack a real context engine fall back to
   blind first-in-first-out eviction—dropping the earliest messages to make room. This is
   fatal because it silently evicts the user's initial instructions, project invariants, and
   architectural constraints.

#### The Verdict: Is an Off-the-Shelf Context Engine Better Than Nothing?
**YES, CATEGORICALLY AND EMPHATICALLY.**

Even the simplest off-the-shelf sliding-window or summarization context engine (such as the
built-in compactors in Antigravity or Claude Code, or Continue's context providers):
- **Summarizes Completed Work:** Compresses resolved debugging cycles into compact executive
  summaries (`<CONTEXT_SUMMARY>`), slashing token volume by 70–90%.
- **Evicts Intermediate Tool Artifacts:** Discards raw 500-line GHC build dumps and obsolete diffs
  from earlier turns while retaining the high-level outcome ("Build succeeded at commit X").
- **Preserves Cache Invariants:** Maintains stable prefix alignment, ensuring that prompt caches
  remain warm across turns.
- **Prevents Hard Failures:** Enables indefinitely long development sessions without hitting
  abrupt API context crashes.

**Recommendation:** For `sarutahiko`, always utilize the REPL harness's native context
compactor / sliding-window context engine. Never disable it.

---

### 7.2 Evaluation: Off-the-Shelf Memory Providers vs. "Nothing At All"

Unlike context engines, the evaluation of external memory providers is sharply bifurcated
by the underlying retrieval mechanism:

| Memory Provider Mechanism | Examples | Verdict for `sarutahiko` | Rationale & Token Economics |
|---|---|---|---|
| **Vector Embedding Retrieval** | Chroma, Qdrant, SQLite-vec, LanceDB | **OFTEN WORSE THAN NOTHING** | Semantic blindness in exact type systems: injects noisy, hallucinated snippets; wastes 1,000+ tokens/turn. |
| **Entity / Knowledge Graph** | `@modelcontextprotocol/server-memory` | **MODERATELY BETTER THAN NOTHING** | Retains persistent operational metadata across sessions without re-prompting; minor concurrency caveats. |
| **Git-Tracked Living Registers** | `docs/registers/*.md`, `AGENTS.md` | **THE GOLD STANDARD (BEST)** | 100% deterministic, branch-synchronous, human-auditable, zero-hallucination, zero daemons. |

#### 1. Why Vector Embedding Memory is Often Worse Than Nothing
Vector memory providers chunk text into arbitrary 300–500 token windows, generate dense
embeddings, and inject top-$k$ nearest neighbors based on cosine similarity. In a type-driven,
effect-typed Haskell codebase, this approach fails dramatically:
1. **Syntactic Confusion:** In advanced Haskell (`large-anon`, row-typed effects, Polysemy/Effectful
   dual interpreters), terms like `Record`, `Row`, `Effect`, or `Field` appear in dozens of
   unrelated contexts. Vector search matches on vocabulary rather than type-theoretic semantics,
   frequently injecting outdated, irrelevant, or subtly incompatible code chunks into the prompt.
2. **Hallucination Injection:** Because the model treats retrieved context as authoritative ground
   truth, injecting a stale code snippet from a discarded scratchpad causes the assistant to
   hallucinate non-existent types or superseded APIs.
3. **Token Overhead with Negative Value:** Injecting 3–5 retrieved chunks consumes 1,000–2,000
   tokens per turn. Paying tokens to make the model *less* accurate is the worst possible trade-off.
4. **Superior Deterministic Alternative:** An exact symbol lookup via `hasktags` (`tags`) costs
   $<15$ tokens and returns the exact file and line number with 100% precision.

#### 2. Why Entity / Knowledge Graph Memory is Moderately Useful
Entity memory MCP servers (e.g. `@modelcontextprotocol/server-memory`) store discrete relational
triples: `(sarutahiko, compiler_version, GHC 9.12/9.14)`, `(sarutahiko, commit_trailers, RFC 2822 Assisted-by)`.
- This avoids re-prompting the assistant on permanent repository conventions when starting fresh
  sessions.
- However, it requires active curation (the agent must decide when to call `create_entities`),
  and parallel subagents can encounter concurrency conflicts when writing to the backing JSON store.

#### 3. Why In-Tree Curated Registers Win
The architectural decision in `sarutahiko` is that **Git itself is the canonical long-term memory**:
- Living registers ([`REUSE_REGISTER.md`](../registers/REUSE_REGISTER.md), [`CODEC_QUIRKS.md`](../registers/CODEC_QUIRKS.md), [`GLOSSARY.md`](../registers/GLOSSARY.md))
  and orientation files ([`AGENTS.md`](../../AGENTS.md), [`INDEX.md`](../INDEX.md)) evolve synchronously with the codebase.
- A branch switch updates the memory instantly, eliminating the cross-branch contamination
  endemic to external databases.
- The assistant accesses this memory via **progressive disclosure**: reading [`INDEX.md`](../INDEX.md) (~20 tokens)
  to locate the relevant note, then viewing the exact section on demand.

---

### 7.3 The Active REPL Configuration Plan: Step-by-Step

Based on this evaluation, the concrete configuration plan for AI coding assistant REPLs in
`sarutahiko` is structured as follows:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       ACTIVE REPL CONFIGURATION PLAN                        │
├─────────────────────────────────────────────────────────────────────────────┤
│  Working Memory:       Native sliding-window context compactor (MANDATORY)  │
│  Long-Term Memory:     Curated in-tree registers in docs/registers/ (T1)    │
│  Diagnostics Daemon:   Tweag's tricorder background daemon (T3 optional)    │
│  MCP Bridge:           tricorder-mcp via .mcp.json / .agents/mcp.json       │
│  Symbol Indexing:      hasktags generated via bin/generate-tags (T1)        │
│  Structural Search:    ast-grep (sg) for AST pattern audits (T2)            │
│  Contamination Guard:  Zero mandatory daemons; Tier 0 POSIX always builds   │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Step 1: Symbol Navigation (Tier 1 Baseline)
- Run `./bin/generate-tags` to build the `./tags` symbol index.
- Assistants use [`.agents/skills/code-navigation/SKILL.md`](../../.agents/skills/code-navigation/SKILL.md) to look up symbol definitions in
  $<15$ tokens instead of multi-file grep or full module reads.

#### Step 2: Background Diagnostics via Tweag's Tricorder (Tier 3 Acceleration)
- **Binary Setup:** Ensure `tricorder-mcp` is located in `~/.local/bin/` (or via Nix/Cabal).
- **Workspace MCP Registration:** Expose `tricorder-mcp` via `.mcp.json` at the project root:
  ```json
  {
    "mcpServers": {
      "tricorder": {
        "command": "tricorder-mcp"
      }
    }
  }
  ```
- **Agent Skill Activation:** [`.agents/skills/tricorder/SKILL.md`](../../.agents/skills/tricorder/SKILL.md) informs the assistant how to
  query build diagnostics via MCP (`status`, `test_results`, `source`) or CLI fallback
  (`tricorder status --json`).
- **Token Impact:** Slashes compilation verification turns from ~2,500 tokens (raw `cabal build`)
  down to $<50$ tokens of structured JSON errors/warnings.

#### Step 3: Context Compaction Configuration
- Ensure the REPL harness's context compaction is active (e.g. threshold set at 75–80% of window).
- Instruct the assistant to summarize completed task packets into git commit messages and
  hand off minimal executive context between milestones.

#### Step 4: Zero-Friction Contributor Opt-Out
- All assistant-specific files (`tags`, `TAGS`, `.mcp.json`, `.agents/`) are non-intrusive.
- Any developer who clones `sarutahiko` without `ast-grep`, `hasktags`, or `tricorder` can
  run `cabal build all` and `cabal test all` without errors or warnings.

---

## 8. Advanced Search Systems & Nadeem Bitar's Stack: Hybrid Recall, Shikumi, and Kioku

As a codebase expands to dozens of packages, naive search mechanisms fail along two opposite axes:
1. **Unranked Text Scans (`grep`):** Return hundreds of lines across dependencies, overwhelming
   the context window with noise.
2. **Dense Vector Embeddings:** Lack exact symbol precision, matching on superficial textual
   similarity and injecting stale or hallucinated code fragments into exact type signatures.

To achieve robust, token-efficient intelligence at scale, `sarutahiko` synthesizes lessons from
Nadeem Bitar's Haskell ecosystem (`shikumi`, `kioku`, `keiki`, `baikai`, `settei`) alongside
our multi-tier AST navigation.

### 8.1 Evaluating Nadeem Bitar's Ecosystem for Context Engine & Memory Provider

Nadeem Bitar's (`shinzui`) suite of Haskell packages represents the most advanced prior art
in typed, event-sourced agent infrastructure in the Haskell ecosystem. Their usability for
`sarutahiko`'s Context Engine and Memory Provider is evaluated below:

#### 1. Context Engine: `shikumi` (`Shikumi.Compaction`) — **HIGHLY USABLE (Minor Modification)**
- **What it does:** `Shikumi.Compaction` provides typed sliding-window context compression:
  - `overflowThreshold`: Computes the exact token budget where compaction must trigger based on
    the model's advertised context window and a reserve buffer (default 16,384 tokens).
  - `usageExceedsWindow`: Detects when provider-reported prompt usage crosses the threshold.
  - `compactTail`: Preserves the most recent $N$ items verbatim (default 4 turns) while folding
    the older tail into an LLM-synthesized executive summary.
- **Architectural Match:** `shikumi` runs natively on `effectful` (`Eff es`), directly matching
  `sarutahiko-effect-effectful`.
- **Adaptation Needed:** `shikumi` defines nominal message types (`AssistantContent`, `TextContent`).
  Adapting it to `sarutahiko` involves bridging these frames into row-typed anonymous records
  (`Record f r` via `sarutahiko-records`), ensuring that compaction frames obey our open row schemas.
- **Verdict:** `Shikumi.Compaction` is an exceptional donor/reference implementation for
  `sarutahiko`'s in-tree Context Engine.

#### 2. Memory Provider: `kioku` (記憶) — **USABLE (Architectural Blueprint / Backend Adapter Needed)**
- **What it does:** `kioku` is a full event-sourced agent memory and session library in Haskell:
  - **Durable Memories:** Fact, preference, constraint, pattern, and instruction storage.
  - **Hybrid Recall:** Fuses PostgreSQL full-text search (BM25 lexical ranking) with `pgvector`
    semantic similarity using **Reciprocal Rank Fusion (RRF)** (`Kioku.Recall.fuseRecallCandidates`,
    `rrfTerm`), modulated by recency decay and character budgets (`applyCharacterBudgets`).
  - **Distillation Pipeline:** Progressively distills raw turn evidence (L0) into memory atoms (L1),
    scenes (L2), and persona summaries (L3).
- **Usability Out-of-the-Box:**
  - If a PostgreSQL + `pgvector` instance is available, `kioku` works **out-of-the-box** as an
    external memory service.
  - For `sarutahiko`'s standalone/embedded posture (which targets a zero-daemon embedded **SQLite**
    engine in Phase 1.5 Hokora), `kioku`'s database layer (`kiroku-store` / Postgres) cannot be
    directly embedded without running a Postgres daemon.
- **Adaptation Needed (Relatively Minor):**
  - Extract `kioku`'s **pure algorithmic core** (`Kioku.Recall` RRF scoring, candidate blending,
    decay functions, and distillation models).
  - Substitute the PostgreSQL backend with an embedded SQLite backend using SQLite `FTS5` for
    lexical search and `sqlite-vec` (or simple in-process cosine similarity) for embeddings.
- **Verdict:** `kioku`'s hybrid recall and distillation pipeline is the blessed design blueprint
  for `utaibon` ([`MEMORY_ENGINE_DESIGN.md`](../notes/MEMORY_ENGINE_DESIGN.md)).

#### 3. Pure State Machine Core: `keiki` (継起) — **OUT-OF-THE-BOX REUSABLE**
- **What it does:** A zero-database, pure Haskell library modeling event sourcing, workflows,
  and durable execution as **symbolic-register finite-state transducers**.
- **Usability:** 100% pure Haskell with no external infrastructure dependencies. Can model the
  agent's conversation state machine and turn transitions with guaranteed replayability (RPL-1).

#### 4. Provider Transport & Codecs: `baikai` (媒介) — **REFERENCE & TEST ORACLE**
- **What it does:** Multi-provider LLM transport (Claude, OpenAI, Ollama, CLI subprocesses like
  `claude -p` / `codex exec`), streaming via `streamly`, token cost accounting, and categorised errors.
- **Role in `sarutahiko`:** Judged in [`REUSE_REGISTER.md`](../registers/REUSE_REGISTER.md) §2.14 as
  a reference implementation and test oracle for Tier 3 Model Substrate.

---

### 8.2 The Search Extension Architecture: Towards Hybrid Recall

To prevent both the token floods of naive text search and the hallucinations of naive vector search,
`sarutahiko` defines a 3-layer search expansion roadmap:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       ADVANCED CODE SEARCH ARCHITECTURE                     │
├─────────────────────────────────────────────────────────────────────────────┤
│  Layer 1: Deterministic Symbol Indexing  (hasktags, tags jumping)           │
│           - Zero false positives, <15 tokens, instant jump to definition.   │
├─────────────────────────────────────────────────────────────────────────────┤
│  Layer 2: Structural AST Search          (ast-grep, tree-sitter, tsquery)   │
│           - Pattern-matches syntax trees, ignoring whitespace/comments.     │
│           - Slices GADT effect signatures, row records, and interpreters.   │
├─────────────────────────────────────────────────────────────────────────────┤
│  Layer 3: Hybrid Lexical + Semantic RRF  (FTS5 + Embeddings via kioku)     │
│           - Fuses exact keyword matches (BM25) with semantic intent.        │
│           - Reciprocal Rank Fusion ensures exact symbols never get lost.    │
└─────────────────────────────────────────────────────────────────────────────┘
```

1. **Deterministic Symbols First (Tier 1):** Definitions are resolved exclusively via `tags`.
2. **Syntactic Outlines Second (Tier 2):** When auditing architectures or finding all handlers,
   `ast-grep` queries the Concrete Syntax Tree directly.
3. **Hybrid Recall for Long-Term Memory (Tier 2/3):** Adopts `kioku`'s RRF formulation to blend
   sparse lexical search (FTS5) with dense embeddings, ensuring that queries for exact identifiers
   (`RecordConstraints`) receive rank 1 while still allowing conceptual natural language queries.

---

### 8.3 Complementary LSP Tooling: LaTeX with `texlab` (`~/src/texlab/`)

`texlab` is a cross-platform Language Server Protocol server for LaTeX written in Rust.

- **Role in `sarutahiko`:** While the primary codebase documentation is GitHub Flavored Markdown
  (`docs/notes/*.md`), any formal academic papers, monographs, or TikZ architectural diagrams
  typeset in LaTeX (e.g. `docs/papers/`) can leverage `texlab` for semantic completion, citation
  jumps, hover documentation, and syntax diagnostics.
- **Build & Activation:**
  ```bash
  cargo build --release --manifest-path=/home/nyc/src/texlab/Cargo.toml
  ```
  Once compiled, `texlab` can be registered in project LSP or MCP bridges for LaTeX authoring.

---

## 9. The Embedded SQLite Search & Bootstrapping Architecture: Contextful, Sqlite-Vec, and Arena Integration

### 9.1 In-Process Monorepo (`typed-language-model-arena`) vs. Out-of-Process IPC (MCP/stdio)

A recurring architectural question in agent systems is whether to link all libraries
into a single monolithic binary or to run them as isolated child processes communicating
via stdio pipes or JSON-RPC (MCP).

The experience in `~/src/typed-language-model-arena/` provides crucial clarity:
1. **The Role of In-Process Monorepo Linking:**  
   In `typed-language-model-arena`, Nadeem Bitar's complete four-layer stack (`baikai`, `shikumi`,
   `keiki`, `kiroku`, `keiro`, `kioku`) is successfully compiled and linked together under GHC 9.12.4.
   This was **not** a fool's errand. It provides the **laboratory proof**:
   - Zero-serialization, in-memory function calls between pure transducers (`keiki`) and effectful
     LM programs (`shikumi`).
   - End-to-end type safety across the entire event sourcing and memory pipeline.
   - Immediate benchmarking of token usage and cache hits without IPC latency.
2. **The Role of Out-of-Process IPC (MCP / Stdio Pipes):**  
   Conversely, when integrating with AI coding assistant REPLs (Antigravity, Claude Code, Cursor),
   **out-of-process IPC is mandatory at the harness boundary**:
   - **Process Isolation:** If an external LLM request times out, throws an unhandled exception,
     or crashes on a native C extension (e.g. pgvector or tree-sitter FFI), only the child process dies.
     The parent REPL remains intact and can restart the worker.
   - **Zero Dependency Contamination:** An out-of-process tool (such as `shikumi-cli` or `tricorder-mcp`)
     runs in its own closure. It never forces its Cabal bounds (e.g. `containers`, `aeson`, `lens`)
     onto `sarutahiko`'s pristine minimal core.
   - **Hot Swapping & Self-Hosting:** The assistant can interact with `shikumi` today, and swap to
     `sarutahiko-mcp` tomorrow without modifying the REPL runtime.

**Conclusion:** We maintain in-process linking in `arena` for deep type-checked experiments, while
exposing its capabilities to the REPL through out-of-process CLI commands and MCP servers.

---

### 9.2 Embedded SQLite Search: Contextful, FTS5 BM25, and Sqlite-Vec

Two projects in the local environment—`~/src/contextful/` and `~/src/sqlite-vec/`—illuminate
the ideal data architecture for embedded agent memory:

#### 1. Contextful: FTS5 BM25 + Web-Tree-Sitter for Evidence Packs
`contextful` (`~/src/contextful/`) demonstrates that effective codebase retrieval does not
require whole-file ingestion. By pairing:
- **SQLite FTS5:** Full-text search with BM25 lexical relevance scoring.
- **Tree-Sitter AST Parsing:** Semantic chunking that aligns with function and type definitions
  rather than arbitrary character counts.
- **Token-Budgeted Packs:** Returning concise evidence slices bounded by an explicit token ceiling.

#### 2. `sqlite-vec`: Zero-Daemon Vector Embeddings
`sqlite-vec` (`~/src/sqlite-vec/`) and the broader `sqlite-ecosystem` prove that vector similarity
search does **not** mandate running heavyweight external vector databases (such as Chroma,
Qdrant, or Pinecone), nor does it require a PostgreSQL server with `pgvector`.
- `sqlite-vec` compiles into a lightweight loadable extension (or statically embedded C file)
  providing `vec0` virtual tables for float, int8, and binary embeddings.
- **Architectural Impact for Utaibon & Hokora:** In Phase 1.5 Hokora and Phase 2 Utaibon,
  `sarutahiko` can embed both lexical search (via built-in SQLite `FTS5`) and semantic embeddings
  (via `sqlite-vec`) directly inside the local `utaibon.sqlite3` database. This delivers
  `kioku`-grade hybrid recall (BM25 + vector similarity via Reciprocal Rank Fusion) in a
  **single, zero-daemon, fully portable SQLite file**.

---

### 9.3 Native Haskell Tree-Sitter & Ctags (Wagner-Graham Incremental GLR Parsing)

In [`docs/Reimplementing Tree-sitter and Ctags in Haskell.md`](../Reimplementing%20Tree-sitter%20and%20Ctags%20in%20Haskell.md), an extensive architectural study
analyzes the mechanics of native Haskell syntax analysis:
- **Wagner-Graham Incremental GLR Parsing:**
  Standard parsers re-tokenize the entire file on every keystroke. Tree-sitter's brilliance
  lies in incremental parsing: marking damaged nodes, shifting intact subtrees directly from
  the old Concrete Syntax Tree in $O(1)$ time, and breaking open only damaged subtrees.
- **Eliminating C FFI Bottlenecks:**
  Standard Tree-sitter bindings rely on C FFI, which pins GHC runtime threads, forces cross-boundary
  heap allocations, and complicates multi-threaded concurrency.
- **The Sarutahiko Parse Blueprint (`sarutahiko-parse`):**
  This study informs Tier 4 code intelligence: authoring an effect-oriented, row-typed Wagner-Graham
  incremental GLR / Earley chart parser in pure Haskell. Until `sarutahiko-parse` matures, we
  rely on Tier 1 `hasktags` and Tier 2 `ast-grep` (`sg`) as our zero-overhead operational bridges.

---

### 9.4 The Bootstrapping Stack Registry & Fallback Hierarchy

The active assistant configuration (`sarutahiko-tooling`) harmonizes all local tools into
a unified capability hierarchy:

| Tool / Server | Source | Role in `sarutahiko` | Invocation Mechanism |
|---|---|---|---|
| **`tricorder-mcp`** | Tweag's `tricorder` (`~/.local/bin/tricorder-mcp`) | Background GHCi compiler diagnostics (<50 tokens). | MCP tool `status(wait: true)` via `.mcp.json`. |
| **`hasktags`** | `/usr/bin/hasktags` (`./tags`) | Instant symbol definition lookup (<15 tokens). | `grep -w "^Symbol" tags` via `code-navigation` skill. |
| **`ast-grep` (`sg`)** | `~/.cargo/bin/ast-grep` | Structural AST pattern matching and refactoring. | `sg -p '<pattern>' packages/` via `code-navigation`. |
| **`shikumi-cli`** | Nadeem's `shikumi` (`~/.local/bin/shikumi`) | Hierarchical LM tracing, deterministic replay, and eval. | `shikumi trace`, `shikumi replay` via `shikumi` skill. |
| **`contextful`** | `~/src/contextful/` | FTS5 BM25 search and token-budgeted context packs. | `cxf pack` via `contextful` skill. |
| **Tier 0 POSIX** | `cabal`, `git`, standard shell | Inviolable baseline; guarantees clean builds without daemons. | `cabal build all`, `cabal test all`. |



