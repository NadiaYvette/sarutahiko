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

### 2.5 Hierarchical Diagnostic Scope Attribution (The Wrong-Scope Refactoring Trap)

A pervasive failure mode in AI coding assistant tooling is the **flat-scope assumption** in compiler
diagnostic ingestion. In Haskell, compiler warnings and type errors frequently occur inside deeply
nested syntactic and type-level scopes:
* **Lexical Nesting:** `where` clauses, nested `let` expressions, lambda abstractions, and `do` blocks.
* **Type-Level & Existential Nesting:** GADT pattern matches (introducing local existential type variables
  and local equality constraints `t1 ~ t2`), `ScopedTypeVariables`, and `RankNTypes`.

**The Failure:** When a diagnostic parser or LSP bridge flattens the diagnostic to the top-level binding
(e.g. reporting that function `foo` has a type mismatch, rather than an inner binding 4 levels deep in
a `where` clause), the LLM is misled into refactoring `foo`'s top-level signature. This triggers a cascade
of secondary compiler errors because the error was local to an existential unpack where local equalities held.

**The Design Invariant:** All diagnostic consumers in `sarutahiko` (`tricorder`, `codegraph`, `kagami-ita`)
must preserve the **Scope Path** (`ScopeStack = [ScopeDescriptor]`):
```haskell
data ScopeDescriptor
  = TopModule !ModuleName
  | TopBinding !SymbolName
  | InstanceHead !ClassName !TypeName
  | WhereClause !SymbolName
  | GadtUnpack !ConstructorName ![LocalTyVar]
  | LocalLet !SymbolName
  deriving (Eq, Show, Generic)

type ScopeStack = NonEmpty ScopeDescriptor
```
Every diagnostic emitted into the event envelope or presented to an assistant carries this explicit
lineage. The assistant sees the exact scope boundary where the type mismatch occurs, preventing
destructive out-of-scope edits.

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
to an **honorary package** within the repository: [`sarutahiko-tooling`](../../.agents/README.md).
While not a Cabal library distributed to Hackage, it possesses its own contracts, degradation
hierarchy, lifecycle, and strict boundaries.

Its user-facing documentation has been split into dedicated package guides:

* **Newbie & Contributor Guide:** [`NEWBIE_GUIDE.md`](../../.agents/docs/NEWBIE_GUIDE.md)  
  A step-by-step tutorial on keeping token burn minimal (<50 tokens per turn) using the
  active bootstrapping suite (Tricorder GHCi daemon, Hasktags definition jumping, `ast-grep`
  structural queries, and Nadeem's `shikumi` CLI).
* **Maintainer & Self-Hosting Guide:** [`MAINTAINER_GUIDE.md`](../../.agents/docs/MAINTAINER_GUIDE.md)  
  Architecture governance for maintainers: zero-contamination dependency boundaries, the
  3-stage transition lifecycle from bootstrapping tools to self-hosted in-tree engines
  (`sarutahiko-mcp`, `utaibon`, `sarutahiko-parse`), living register curation, and the
  batched multi-remote push policy (`bin/push-all`).

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

In [`docs/transcripts/treesitter-ctags-incremental-parsing.md`](../transcripts/treesitter-ctags-incremental-parsing.md), an extensive architectural study
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

---

## 10. Defensive Guidance, Reasoning Heterogeneity & The Experiment Quarantine Protocol

As the assistant tooling ecosystem matures, human maintainers frequently deploy heterogeneous
AI drivers—ranging from flagship frontier models (e.g. Gemini 3.8 Pro, Claude 3.5 Sonnet)
to lighter or open-weights models (e.g. 7B/8B/70B local models via Hermes Agent, Ollama, or
`flash_lite`). 

Developing inside `sarutahiko` imposes unusual cognitive demands: large-anon extensible records,
row-polymorphic algebraic effects, zero-bloat anti-aeson laws, strict `-Wall -Werror`, and POSIX
concurrency invariants. When less-capable or unconstrained models touch this codebase, they
exhibit distinct failure modes that require formal architectural defenses.

### 10.1 The Small-Model Hazard in High-Assurance Codebases

Empirical observations across assistant experiments reveal recurring failure patterns in
reasoning-constrained agents:

1. **Manifest & Config Mangling:** Smaller models frequently hallucinate dependencies in
   `.cabal` files, corrupt Cabal stanza syntax, or delete delicate compiler options
   (such as `-fplugin=Data.Record.Anon.Plugin` or `-threaded`).
2. **Whole-File Rewriting Fatigue:** Rather than issuing targeted, surgical edits via
   `replace_file_content`, less-capable models attempt full-file replacements, dropping
   unrelated typeclass instances, re-introducing previously resolved compiler warnings,
   or silently truncating module exports.
3. **Convention Amnesia & Positive-Bias Drift:** Even when provided extensive architectural
   documentation, smaller models default to generic internet training patterns: reaching
   for `Data.Aeson`, introducing `scientific` or `unordered-containers`, ignoring TriState
   semantics, or polling asynchronous task statuses in tight loops.
4. **Concurrency & POSIX Blindness:** Models under 70B parameters consistently struggle with
   subtle runtime semantics: forgetting `-threaded` runtime flags, assuming `waitForProcess`
   is interruptible by async exceptions, or closing pipes while child buffers still hold data.

### 10.2 Stringent Guidance & Operational Guardrails for Assistants

To safeguard the repository while allowing contributors to experiment with diverse agent harnesses,
the following guardrails govern assistant prompts and tool configurations:

1. **Negative Constraints Over Philosophical Exhortations:**  
   Reasoning-constrained models do not reliably internalize abstract design philosophy. Prompts
   must provide explicit, enumerated **negative constraints** ("Thou Shalt Not"):
   - *FORBIDDEN:* Modifying `cabal.project` or adding Hackage dependencies without explicit maintainer consent.
   - *FORBIDDEN:* Importing `aeson`, `scientific`, or `unordered-containers`.
   - *FORBIDDEN:* Polling `manage_task status` in a loop; execution must pause and await reactive wakeups.
   - *FORBIDDEN:* Attempting whole-file rewrites on modules exceeding 100 lines.
2. **Tier-Restricted Blast Radii:**  
   Lighter models should be restricted to narrow, well-bounded scopes:
   - *Permitted:* Running Tier 1 symbol lookups (`tags`), executing isolated test suites,
     generating documentation, or authoring leaf test cases.
   - *Restricted:* Modifying core effect signatures, altering extensible record internals, or
     refactoring inter-package dependency graphs.
3. **Compiler As Truth Oracle (The Zero-Trust Feedback Loop):**  
   Never accept an assistant's natural-language assurance that "the code is correct." Every turn
   must verify against GHC `-Wall -Werror`. If an agent introduces compiler errors or lints,
   it must immediately address the diagnostic before touching any other file.

### 10.3 The Experiment Quarantine & Archive Branch Protocol

When an experimental REPL run, third-party agent driver (such as Hermes), or exploratory spike
diverges or destabilizes the working tree, maintainers and assistants must execute the
**Quarantine Protocol**:

```
                              THE QUARANTINE PROTOCOL
                              
   [Active Session / Master]
              │
   (Wrong turn / Bungled commits detected)
              │
              ├───► Create Archive Branch:  git branch archive/experiment-<topic>-<date>
              │     (Preserves all exploratory commits, logs, and artifacts permanently)
              │
              └───► Clean Reset to Milestone:  git reset --hard <last-clean-commit>
                    (Restores master to 100% verified, green-test state)
```

- **Step 1: Immediate Freeze & Branch Preservation:**  
  Do not attempt frantic, multi-commit rewrites or force-pushes on the dirty branch. Freeze the
  current HEAD and create a dedicated archive branch:
  ```bash
  git branch archive/experiment-<description>-<YYYYMMDD>
  ```
  This guarantees that no exploratory code, research notes, or experimental configurations are lost.
- **Step 2: Clean Hard Reset to the Last Verified Gate:**  
  Reset the primary working branch (`master`) cleanly to the last verified milestone tag or
  commit (e.g. `rad/master` or the Phase 0/1 gate commit):
  ```bash
  git reset --hard 9a6c1e2  # or target milestone
  ```
- **Step 3: Post-Mortem Documentation:**  
  If the experiment revealed architectural friction or tool incompatibilities (e.g. REPL container
  discovery issues or daemon race conditions), document the findings in `ASSISTANT_TOOLING_DESIGN.md`
  or a living register before resuming development.

### 10.4 REPL Introspection, Daemons, and Synchronization (Tricorder & Hermes)

Cross-REPL testing with tools like Hermes Agent in containerized environments (e.g. `distrobox`)
highlights specific operational realities for background daemons:

1. **Filesystem & Socket Boundaries:**  
   When an assistant runs inside a container (such as a distrobox container) while `tricorder`
   runs on the host (or vice versa), Unix domain sockets, inotify file watch events, and process
   namespaces may not synchronize seamlessly. Daemon tools must expose explicit TCP/stdio fallbacks
   or allow path mapping between host and container paths.
2. **Race-Free Daemon Synchronization:**  
   When multiple agent processes or editor instances query `tricorder` concurrently, lack of
   synchronization around GHCi handles or build locks can cause transient exit code failures.
   Background daemons intended for multi-REPL consumption must implement atomic lockfiles or
   serialized request queues.
3. **Observability Fallbacks:**  
   When a third-party REPL lacks structured observability into its background processes, always
   fall back to deterministic CLI inspection (`cabal build`, `git status -sb`, `ps aux`) from
   a known-good shell to verify system ground truth.

---

## 11. Polyglot Code Intelligence, Frankenstein/Organ-Bank & Generalized Compiler Truth Oracles

### 11.1 Configurable Compiler Truth Oracles (Modern GHC vs. Historical & Bootstrap Portability)

In `sarutahiko`, the compiler truth oracle is pinned to modern GHC (`ghc-9.12` / `ghc-9.14` under `GHC2024`).
However, across the maintainer's broader ecosystem of repositories—particularly in bootstrap restoration
work (`~/src/frankenstein/BOOTSTRAP_RESTORATION.md`) and portability research—codebases deliberately target
historical, minimal, or alternative compilers:
- **Historical GHCs:** GHC 6.x (e.g. 6.12, 6.4) and GHC 7.x.
- **Haskell 98 & Report-Only Compilers:** `nhc98` (Malcolm Wallace & Colin Runciman), `Hugs 98`.
- **Standalone Bootstrap Compilers:** `MicroHs` (Björn Bringert & Lennart Augustsson).
- **Alternative Research Compilers:** `UHC` (Utrecht), `YHC` (York), `HBC` (Chalmers Haskell B Compiler).

#### The Small-Model Hazard in Bootstrap Codebases
If an AI coding assistant evaluates bootstrap code using a modern GHC oracle, it will trigger catastrophic
regressions: forcing modern Prelude conventions, suggesting extensions (`TypeApplications`, `DataKinds`)
that break ancient compilers, or stripping Haskell 98 import statements essential for report-conformant
tools.

#### Parameterized Compiler Oracle Architecture
The compiler truth oracle must therefore be parameterized by a **target dialect profile**:
```haskell
data CompilerOracleProfile
  = ModernGHC
      { ghcVersion  :: Version
      , languageExt :: [Extension]
      , warningGate :: WarningPolicy -- e.g. -Wall -Werror
      }
  | HistoricalGHC
      { ghcVersion  :: Version
      , compatFlags :: [String]
      }
  | BootstrapHaskell98
      { compilerBin :: FilePath     -- e.g. /usr/bin/nhc98 or /usr/bin/hugs
      , reportYear  :: H98Standard  -- Haskell98, Haskell2010
      }
  | MicroHsOracle
      { mhsBinary   :: FilePath
      }
  | CustomToolchainOracle
      { checkCmd    :: FilePath -> [String] -> IO ExitCode
      }
```
When an assistant operates inside an owner-class repo, it reads the target profile from repository
configuration (e.g. `.compiler-oracle.yaml` or Cabal default-language stanzas) and verifies code strictly
against the declared target dialect.

---

### 11.2 Organ-Bank Shims & Frankenstein MLIR as Unified Semantic Navigation

The maintainer's owner-class projects `~/src/organ-bank/` and `~/src/frankenstein/` contain an extraordinary
polyglot compiler substrate:
- **`organ-bank`:** Houses 25+ language shims (Ada, Agda, Common Lisp, C++, C, Erlang, Forth, Fortran, F#,
  GHC, Idris2, Julia, Koka, Lean4, Lua, Mercury/MMC, OCaml, Prolog, PureScript, Rust, Scala3, Scheme,
  SML, Swift, Zig), along with `organ-ir`, `organ-extract`, and `organ-diff`.
- **`frankenstein`:** Explores multi-lingual MLIR dialects, LLVM codegen, arena allocators, cycle collectors,
  and bootstrap restoration.

#### The Problem: LSP Daemon Proliferation
Attempting to support 25 languages by running 25 separate Language Server Protocol daemons simultaneously
would instantly exhaust laptop RAM and thrash CPU scheduling.

#### The Solution: Slices of `organ-extract` for Unified Code Navigation
Instead of spinning up 25 third-party LSPs:
1. **Unified Semantic Extraction:** `organ-extract` parses foreign source files into `organ-ir` representations.
2. **Polyglot Symbol & Tag Generation:** Lightweight slices of `organ-extract` can emit unified ctags/etags
   or AST outline indices. This allows the assistant's Tier 1 `code-navigation` skill to jump to definitions
   seamlessly across Haskell, Mercury, Koka, Idris2, and C without running heavy LSP servers.
3. **Polyglot Compiler Feedback via Tricorder:** `tricorder`'s background daemon model (file-watch $\rightarrow$
   instant diagnostic) can be extended using `organ-bank`'s shims: watching `.mh` (Mercury), `.koka`, or
   `.idr` files and querying the respective compiler shim in the background.

---

### 11.3 Upstream Cabal Solving for Tooling Dependencies (`config-ini`, `tasty-hspec`)

When porting tooling dependencies (such as `config-ini` and `tasty-hspec`) to modern GHC (9.12/9.14),
quick local patches often simply delete upper bounds. While sufficient for local builds, upstream
Hackage maintainers require clean, PVP-compliant solutions.

#### The Upstream Solver Procedure:
1. **Run the Solver in Dry-Run Mode:**
   ```bash
   cabal build --dry-run --enable-tests --flags="+..."
   ```
2. **PVP-Bounded Bumps:**
   Rather than uncapping (`foo >= 1.0`), relax bounds by exactly one major PVP version (e.g. `base >= 4.7 && < 4.22`,
   `megaparsec >= 7.0 && < 10.0`).
3. **Conditional Stanzas for Breaking Upstream Changes:**
   Where GHC 9.12+ introduces breaking changes in standard libraries:
   ```cabal
   if impl(ghc >= 9.12)
     build-depends: base >= 4.21 && < 5
   else
     build-depends: base >= 4.7 && < 4.21
   ```
4. **Isolated Upstream PR Branches:**
   Package changes into a dedicated `upstream/ghc914-compat` branch containing only the cabal bound bumps
   and minimal CPP conditionals, verified with clean test passes.

---

## 12. Panoramic Portfolio Orchestration, Bounded Worker Fleets & Brittany Style Engineering

### 12.1 Managing the "Brambles": DAG/Hypergraph Orchestration vs. Flat Kanban Boards

The maintainer describes a "panoramic vista of brambles of intertwined, imbricated and interrelated ideas
and projects." Standard project management paradigms (flat Kanban boards in Trello, GitHub Projects, or
Hermes Agent) fail in this setting:
- Flat 2D Kanban columns (`To Do` $\rightarrow$ `In Progress` $\rightarrow$ `Done`) assume independent, linear tasks.
- In reality, tasks across `sarutahiko`, `organ-bank`, `frankenstein`, and `kioku` form an **imbricated DAG
  (Directed Acyclic Graph) or Hypergraph**: a breakthrough in `organ-ir` unlocks features in `frankenstein`,
  which feeds `kogaki`, which alters `sarutahiko` codecs.

#### The DAG-Based Portfolio Engine
Rather than flat cards, portfolio orchestration requires:
1. **Topological Task Graphs:** Tasks declare explicit dependency edges (`depends_on: [organ-ir/ast-slice, sarutahiko/tp-1.4]`).
2. **Active Frontier Projection:** Hermes / agent "Boards" are generated dynamically as **projections** of
   the frontier nodes whose dependencies are 100% satisfied.
3. **Event-Sourced Task Ledger:** Drawing from `keiki`'s symbolic-register finite-state transducer model,
   task state transitions are recorded as immutable events, allowing deterministic replay and cross-repo audit.

---

### 12.2 Worker Fleets vs. Local Hardware Bounds (Managing Combinatorial Firecrackers)

While cloud LLM APIs can generate tokens indefinitely, code execution, compiler verification, GHC linking,
and test suites run **locally on developer hardware**.

#### The "Combinatorial Firecracker" Hazard
When orchestrating multi-agent fleets across a matrix of options (e.g. $N$ compilers $\times$ $M$ language
shims $\times$ $K$ test targets), an unconstrained system will spawn dozens of parallel workers. On a
developer laptop (e.g. ThinkPad), this leads to immediate CPU saturation, thermal throttling, memory exhaustion
(OOM killer invocation), and NVMe write endurance degradation.

#### The Safe Execution Architecture:
1. **Strict Concurrency Ceilings:** The orchestrator enforces a hard gate on concurrent local subprocesses
   (`max_concurrent_builds = 2`, `cabal build -j2`).
2. **POSIX Process Niceness:** Local worker commands run under deprioritized scheduling:
   ```bash
   nice -n 19 ionice -c 3 cabal test ...
   ```
3. **Content-Addressed Build Caching:** Shared artifact stores prevent combinatorial workers from rebuilding
   identical dependencies.
4. **Asynchronous Ledger Queueing:** Agents do not spin or sleep in memory; tasks are queued in an embedded
   SQLite task database, and agents wake up reactively upon task completion notifications.

---

### 12.3 Brittany Style Engineering: Developing a Personal Haskell Formatting Profile

The maintainer favors `brittany` over opinionated, monolithic formatters (`ormolu`, `fourmolu`) because
Brittany leverages `ghc-exactprint` and a Wadler/Leijen-style layout algorithm that respects human layout
intent, preserves column alignments, and accommodates distinct personal coding aesthetics.

#### The Methodology for Synthesizing Nadia's Brittany Profile:
1. **Curate Exemplar Modules:** Select 3–5 representative, hand-crafted Haskell files from the owner's
   repositories that exhibit the desired aesthetic (GADT column alignment, record layout, comment placement).
2. **Differential Config Tuning:**
   Run Brittany over the exemplars using a parameter grid search on `.brittany.yaml` settings:
   - `conf_layout.lconfig_cols` (column width)
   - `conf_layout.lconfig_indentPolicy`
   - `conf_layout.lconfig_indentAmount`
   - `conf_layout.lconfig_importColumn`
   - `conf_layout.lconfig_hangingTypeSignatures`
   Minimize the `git diff --word-diff` against the original handwritten exemplars.
3. **Document Layout Engine Gaps:** Where Brittany's default engine cannot produce the desired formatting
   (e.g., custom indentation for `large-anon` `(=:)` row constructors or multi-line comment blocks),
   isolate the exact AST nodes.
4. **Brittany Extension Roadmap:** If needed, author a local fork or patch to Brittany's document-builder
   pipeline adding targeted layout combinators for extensible record syntax.

---

### 12.4 Cascading Rigor Across Nadia-Owned Repositories

To bring all owner-class repositories up to the architectural and operational standards established in
`sarutahiko`, an incremental 4-level onboarding ladder is defined:

```
┌─────────────────────────────────────────────────────────────────────────────┐
1. Level 1: Orientation Projection (AGENTS.md, README, License, Cabal Bounds)  │
├─────────────────────────────────────────────────────────────────────────────┤
2. Level 2: Diagnostic & Navigation Harness (tags, code-navigation, Oracle)   │
├─────────────────────────────────────────────────────────────────────────────┤
3. Level 3: Architectural Documentation (docs/INDEX.md, Registers, Laws)       │
├─────────────────────────────────────────────────────────────────────────────┤
4. Level 4: Continuous Verification (Hermetic Tests, GHC -Wall -Werror)        │
└─────────────────────────────────────────────────────────────────────────────┘
```

By executing this migration systematically across repositories as token and compute budgets permit,
the entire multi-repo workspace achieves uniform assistant compatibility and verifiable correctness.

---

### 12.5 The Token Economics of Task Execution: Monolithic Goal Loops vs. Decoupled Kanban Workqueues

A critical operational question in AI coding assistant engineering is how autonomous tasks should be
structured to avoid catastrophic context accumulation, token burn, and compaction stalls.

#### 1. The Structural Dilemma: Monolithic Loops vs. Decoupled Task Queues

Two competing execution topologies exist in modern agentic runtimes:

```
A. Monolithic Single-Session Goal Loop (The "Ralph / Devin / /goal" Pattern)
   [Turn 1: 5k] ──► [Turn 2: 15k] ──► ... ──► [Turn 10: 97k] ──► [Compaction Stall (10m)] ──► Degraded Context
   (All turns, terminal chatter, compiler errors accumulate in a single monotonically growing context window)

B. Decoupled Task-Queue Pipeline (The "Kanban / SWE-Bench Scaffolder" Pattern)
   Macro-State:  Repository Files + PLAN.md / STATE.md + External Ledger (~/.hermes/kanban.db)
                        │                     │                      │
                        ▼                     ▼                      ▼
   Card 1: [Worker 1: ~4k] ──► Card 2: [Worker 2: ~4k] ──► Card 3: [Worker 3: ~4k]
   (Ephemeral OS processes; each worker starts with a pristine context window, commits, and terminates)
```

| Dimension | Monolithic Goal Loop (`/goal`, Ralph Loop) | Decoupled Task Queue (Kanban Board) |
|---|---|---|
| **Session Model** | Single continuous conversation thread | Ephemeral, isolated OS process per card |
| **Context Trend** | Monotonic accumulation: $O(N)$ tokens ($30\text{k} \to 60\text{k} \to 97\text{k}$) | Constant per milestone: $O(1)$ tokens ($\approx 3\text{k}–5\text{k}$ tokens per worker) |
| **Attention Economics** | Quadratic degradation ($O(N^2)$ KV-cache); "lost in the middle" drift | Pristine attention floor for every architectural subtask |
| **Compaction Hazard** | **High**: Compaction eventually forces massive summarization prompts | **Zero**: Workers complete bounded cards and exit before compaction triggers |
| **Fallback Fragility** | Auxiliary compression on slow/rate-limited models hangs for 5–10 mins | Tasks fail-stop in SQLite without corrupting other pipeline stages |
| **State Persistence** | Volatile LLM scratchpad and conversation transcript | Durable SQLite rows, Git commits, and filesystem artifacts |

#### 2. Industry-Wide Phenomenon: Is This Hermes-Specific or Universal?

This phenomenon is **not an idiosyncrasy of Hermes Agent**; it is an industry-wide structural invariant
governing transformer-based LLMs and autonomous agent scaffolding:

1. **OpenAI & SWE-bench Scaffolders:** High-scoring SWE-bench evaluation harnesses never attempt to resolve
   complex, multi-step engineering benchmarks in a single unbounded session. Instead, they isolate task
   execution in fresh sandboxes with bounded micro-prompts.
2. **Anthropic Claude Code & Cursor Agent:** Claude Code’s built-in `/compact` facility suffers identical
   degradation when session contexts pass 100k tokens. Multi-hour refactoring tasks reliably degrade unless
   the user resets the context window at milestone boundaries.
3. **Multi-Agent Research (PaperQA, AutoGen, CrewAI):** Conversational agent swarms (where parent agents
   hold continuous dialogues with children) have been broadly abandoned in production in favor of
   **blackboard / message-queue architectures**: workers pull tasks from a queue, operate ephemerally,
   and write structured evidence back to a database.
4. **The Externalized Two-File Loop (`PLAN.md` & `STATE.md`):** By externalizing engineering state to
   Git-versioned markdown documents, the repository itself serves as the durable blackboard, allowing
   successive $O(1)$-context agent passes to execute long-horizon projects without context amnesia.

#### 3. Operational Rule of Thumb
- **Reach for `/goal`** for tightly bounded, single-file iterations where progress is verified in 2–4 turns
  (e.g., "Fix the 3 type errors in module X and ensure `cabal build` passes").
- **Reach for Kanban** for multi-step feature implementations, architectural refactors, and tactical
  packages (e.g., Phase 1 TP-1.5), decomposing work into dependent cards with clean process isolation.

#### 4. The First-Class `yamaarashi-exec` Hermes Runner (`executor: hermes`)

To operationalize the decoupled Kanban / SWE-bench scaffolder pattern directly in `sarutahiko`,
[`packages/yamaarashi/yamaarashi-flow/app/Main.hs`](../../packages/yamaarashi/yamaarashi-flow/app/Main.hs) natively
supports spawning ephemeral Hermes leaf workers (`executor: hermes`) inside isolated git worktrees:

1. **Worktree Provisioning & Intel Seeding:** When `yamaarashi-exec run <packet.yaml>` runs, it
   creates a temporary git worktree (`sarutahiko-wt-<id>`) and seeds `./tags` from the parent repo,
   granting the spawned worker instant, zero-token symbol lookups (`grep -w "^<Symbol>" tags`).
2. **Headless Execution:** Invokes `hermes chat --in <wtDir> --query-file <prompt> --oneshot --yolo --accept-hooks`
   preloaded with skills (`code-navigation`, `tricorder`, `contextful`).
3. **Zero-Token Feedback Loop:** The worker iterates against local compiler diagnostics (`tricorder status --json`,
   `<50` tokens) routing through zero-token provider endpoints (`custom:omniroute`, `custom:opencode`).
4. **Outer Verification Gate & Attribution:** Once Hermes exits, `yamaarashi-exec` enforces the
   inviolable verification gate (`cabal v2-build`, `cabal v2-test`, and `<id>-verify.sh`).
   If all gates pass, it creates a git commit with Linux kernel-style `Assisted-by:` and
   `Orchestrated-by:` trailers, and fast-forward merges the worktree to `HEAD`.


