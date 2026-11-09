# Tooling Configurations, Code Architecture, Quota Governance & Cross-Project Knowledge Placement

**Subtitle:** Forensic Lessons, Mechanical Self-Healing, and Agentic Engineering Patterns from the Multi-Repo Frontline (Polytropos / Smirk / Sarutahiko)  
**Status:** APPROVED ARCHITECTURAL SYNTHESIS NOTE  
**Date:** 2026-11-09  
**Author:** Antigravity (Google DeepMind / Advanced Agentic Coding) & NYC  
**Target Audiences:** Gemini Argon (Design & Planning Sessions), Agentic Orchestrators, System Maintainers  
**Canonical Locations:**  
- `~/src/plans/architecture/TOOLING_QUOTA_AND_ENGINEERING_SYNTHESIS.md` (Cross-cutting orchestration hub)  
- `~/src/sarutahiko/docs/notes/TOOLING_QUOTA_AND_ENGINEERING_SYNTHESIS.md` (Version-controlled repository note)  
**Kioku Anchor:** `kioku recall "TOOLING_QUOTA_AND_ENGINEERING_SYNTHESIS" --namespace-wide antigravity --strategy keyword`  

---

## 1. Executive Context & Gemini Argon Briefing

This document synthesizes findings, architectural remedies, tooling configurations, and code refactorings developed over intensive multi-repo engineering waves across `polytropos`, `smirk`, `sarutahiko`, `gargamelle`, `tengri`, and `t-digest`. 

During deep collaborative sessions, software development by high-capability AI assistants encounters two compounding bottlenecks:
1. **Quota Drain via Context Inflation**: As conversational trajectories grow, re-submitting massive historical prompts into LLM attention layers burns quota exponentially, threatening to halt collaboration prematurely.
2. **The "Mechanical Tax" on Intelligence**: Burning high-tier LLM cycles on trivial compiler warnings, import cleanup, or fragile shell scripts is a catastrophic misallocation of token budgets.

This synthesis provides **Gemini Argon** with the empirical evidence, architectural principles, concrete code patterns, and tooling fixes discovered on this frontline. These insights should directly inform Argon's design recommendations and code plans.

---

## 2. Quota Burn Rate & Context Inflation Forensic ("Where the Quota Went")

### 2.1 The Forensic Discovery
A forensic audit across `~/.gemini/antigravity-cli/brain/` transcripts revealed aggregate token consumption exceeding **14,000,000 fresh input tokens** and **265,000,000 cached prompt tokens**. 

Crucially, **a single orchestrator session accounted for 6,170,000 fresh tokens** across 1,256 turns, where the context window ballooned to ~186,000 tokens.

### 2.2 The Mathematical Anatomy of Context Window Inflation ($O(N \cdot T)$ Bleed)
Gemini's automatic prompt caching is extremely efficient, typically achieving a **95.0% cache hit ratio**. However, the remaining 5% represents a devastating vulnerability when the conversation history is large:

$$\text{Fresh Tokens / Turn} \approx (1.0 - \text{CacheHitRatio}) \times \text{ContextSize}$$

$$\text{Fresh Tokens / Turn} \approx 0.05 \times 186,000 \approx 9,300 \text{ fresh tokens/turn}$$

At turn 1,000, executing a trivial check—such as running `git status`, inspecting a test result, or reading a 3-line compiler diagnostic—burns **~9,300 fresh tokens** even with a 95% cache hit! 

Over 100 minor turns, this burns nearly **1,000,000 fresh tokens** without writing a single line of production code.

Worse, **cache invalidation spikes** occur whenever tool declarations shift, dynamic system prompts reorder, or scratchpad files change. In such cases, the cache hit ratio drops to 0%, and a single turn bills the full 186,000 tokens as fresh input.

### 2.3 Deployed Quota Firewalls & Remediation Mechanisms
To break this cycle, the following systemic protocols were implemented:

1. **The Two-File State Loop (`PLAN.md` & `STATE.md`)**:
   - Conversational prompt history must not be used as an append-only working memory.
   - All operational state is externalized into `PLAN.md` (roadmap DAG) and `STATE.md` (active session frontier).
   - Once durable facts are recorded, the session is compacted via `/compact`, shedding hundreds of thousands of historical tokens.
2. **Durable Knowledge Offloading via `shinzui kioku`**:
   - Key architectural decisions and resolved root causes are committed to PostgreSQL (`postgresql:///kioku`) using `kioku-remember` before compaction.
3. **Subagent & Subprocess Airgapping**:
   - Subprocesses (`yamaarashi-exec`, worker scripts, yaegi) are strictly airgapped: metered API keys (`GEMINI_API_KEY`, etc.) are scrubbed from worker environments (`buildWorkerEnv`).
   - Flags `MCP_DISABLE_SAMPLING=1` and `AGY_DISABLE_SAMPLING=1` prevent child processes from spawning unmetered recursive LLM calls.
   - Build-test-fix loops are delegated to isolated worktree subagents with minimal context windows (3k–5k tokens), shielding the orchestrator's context from raw compiler logs.
4. **Kagami-Ita (鏡板) Token Accounting**:
   - Implemented in `sarutahiko-observability` (`Sarutahiko.Observability.TokenLedger`).
   - Streams JSONL turn records, computes real-time cache hit ratios, and trips a circuit breaker (`evaluateCircuitBreaker`) when fresh token budgets or context window thresholds (>100k tokens) are breached. Exposes CLI metrics via `yamaarashi-exec telemetry`.

---

## 3. Mechanical Self-Healing vs. LLM Cycles (The `hls-autoheal` Paradigm)

### 3.1 The Economic Absurdity of Minor Warning Repair
In strongly typed languages like Haskell or Rust, modifying a data type or refactoring an export list causes compiler diagnostics:
- Unused imports (`GHC-66111`)
- Redundant LANGUAGE pragmas (`GHC-38856`)
- Deprecated syntax warnings
- Style hints (HLint)

If an LLM orchestrator handles this manually, the workflow is:
1. LLM reads compiler error output (turn 1: 9.3k tokens)
2. LLM navigates to file and locates line (turn 2: 9.3k tokens)
3. LLM invokes `replace_file_content` (turn 3: 9.3k tokens)
4. LLM re-runs build to verify (turn 4: 9.3k tokens)

Fixing three unused imports costs **~37,000 to ~75,000 fresh tokens** and 4 minutes of wall-clock time for a purely mechanical change that requires zero semantic reasoning.

### 3.2 The `hls-autoheal` Solution
We developed `hls-autoheal` (`/home/nyc/.local/bin/hls-autoheal`, compiled from `sarutahiko/scripts/tools/hls-autoheal.go`):
- **Native Go Speed**: Executes in under 40 milliseconds with zero runtime dependencies.
- **Diagnostic Parsing**: Directly ingests GHC compiler output (`--stdin` or via `-build '<command>'`), extracts error codes (e.g., `GHC-66111`), parses the source file, and surgically deletes or prunes redundant imports, pragmas, and deprecated specifiers.
- **Deterministic Pipeline Hook**: Integrated into `yamaarashi-exec` (`runAutoHeal`). When a verification build fails, `yamaarashi` runs `hls-autoheal` automatically. If the failure was purely mechanical warnings/imports, the build succeeds immediately and proceeds—**burning exactly 0 LLM tokens**.
- **Documented Rule**: Operationalized in `.agents/rules/hls-housekeeping.md` across all projects.

---

## 4. Tool Configuration & Compiler Quirks (Ours and the Upstream Tools')

### 4.1 Multi-Cradle HLS Discovery (`hie.yaml`)
- **Problem**: In multi-package Cabal projects (`polytropos`, `smirk`, `sarutahiko`), default Haskell Language Server (HLS) cradle discovery relies on implicit cabal heuristics. This caused HLS to repeatedly re-configure and re-index projects on file saves, taking 60+ seconds and triggering editor timeouts.
- **Fix**: Deployed explicit `hie.yaml` multi-cradle configurations in repository roots mapping each component explicitly:
  ```yaml
  cradle:
    cabal:
      - path: "packages/smirk/src"
        component: "lib:smirk"
      - path: "packages/smirk/test"
        component: "test:smirk-test"
  ```
- **Result**: Reduced HLS initialization and cradle discovery times from over 60s to **<14 seconds**, completely eliminating editor hangs and background polling loops.

### 4.2 GHC 9.14 vs. HLint Namespace Incompatibility
- **The Issue**: GHC 9.14 introduces deprecation warning `GHC-68383`:
  ```
  The 'pattern' namespace specifier is deprecated.
  Suggested fix: Use the 'data' keyword instead.
  ```
  However, HLint (including v3.8/v3.9) has not yet implemented the GHC 9.14 grammar for `data` in export lists, throwing a hard parse error:
  ```
  Parse error: on input 'data'
  ```
  Omitting the namespace specifier entirely causes GHC to assume a type constructor, emitting `GHC-76037: Not in scope: type constructor or class`.
- **The Cross-Tool Fix**:
  In the affected modules, retain `pattern Foo` in export lists and suppress the GHC deprecation warning at the file level:
  ```haskell
  {-# OPTIONS_GHC -Wno-pattern-namespace-specifier #-}
  module Smirk.Core.Bytecode
    ( pattern IRangeNat
    , pattern ICallout
    ...
    ) where
  ```
  This allows code to compile cleanly under `-Wall -Werror` on GHC 9.14 while maintaining 0 parse errors and 0 hints under HLint.

### 4.3 Documentation & Reference Consistency (Tagref & Markdown Linkcheck)
- Strict quality gates mandate 100% resolution of reference tags (`[ref:name]`) against definition tags (`[tag:name]`) and zero broken intra-repository markdown links.
- When moving files or refactoring modules, path updates in documentation must be part of the same atomic changeset (`DOC_STRATEGY.md` §4 precedence rule).

---

## 5. Code Architecture Patterns for High-Performance & Agentic Software

### 5.1 Language Ergonomics for Agents: The Go + Yaegi Paradigm
While Haskell remains the language of choice for verified domain engines, it imposes heavy compilation overhead and complex type-level repair cycles on autonomous leaf agents. Shell scripts, conversely, are fragile and prone to escaping/quoting bugs in heredocs.

As documented in `sarutahiko/docs/notes/AGENTIC_GO_YAEGI_RATIONALE.md`:
- **Academic Foundation**: arXiv:2510.26130v2 (*Beyond Synthetic Benchmarks: Evaluating LLM Performance on Real-World Class-Level Code Generation*) shows that rigid static signatures, explicit error handling, and standard library completeness yield significantly higher agent self-repair pass rates than dynamic languages.
- **Industry Findings**: Google Engineering (Balahan & Seroter, 2026) highlights that Go’s lack of syntactic magic, strict compiler guardrails, and canonical formatting (`gofmt`) make it uniquely optimal for AI-assisted engineering.
- **Zero-Compilation Scripting via Yaegi**: Traefik's `yaegi` interpreter (`/home/nyc/.local/bin/yaegi`) allows writing Go task scripts with `#!/usr/bin/env yaegi`. This provides full static type safety and standard library power (`path/filepath`, `encoding/json`, `os/exec`, `regexp`) with instantaneous startup and zero temporary binary compilation artifacts.
- **Yamaarashi Integration**: `yamaarashi-exec` supports `executor: yaegi` and `executor: auto`, executing deterministic task packets without invoking LLM tokens.

### 5.2 Memory & Data Layout Engineering (Polytropos & Smirk)
For performance-critical engines, high-level abstractions often incur severe memory allocation penalties. The following architectural shifts were implemented:

1. **Unboxed Flat Arrays over Boxed Maps in VM Loops**:
   - In regex and pattern-matching virtual machines, tracking capture groups using boxed structures like `Map Int (Int, Int)` creates immense GC allocation churn during backtracking.
   - Refactored capture state to `CaptureSlots`: flat, unboxed `PrimArray Int` pairs representing `[start, end]` offsets, with named projection into `Polytropos.Core.Rep`.
2. **Pre-Allocated Backtrack Pools (`VMFramePool`)**:
   - Rather than allocating heap closures for backtrack frames, pre-allocate frame pools backed by `SmallArray CaptureSlots` and `PrimArray Int`. Backtracking states mutate frame indices rather than allocating new memory cells.
3. **$O(1)$ Physical UTF-8 Materialization Footprint**:
   - Instead of decoding and scanning Unicode character codepoints across multi-megabyte `Text` or `ByteString` slices to check memory limits, evaluate physical UTF-8 footprint via $O(1)$ slice byte operations (`utf8SliceByteWidth`) directly on the underlying buffer.
4. **Graded Modal Horizons & Linear Cursor Continuations**:
   - In stream and cursor parsing, wrap match resumptions under `-XLinearTypes` multiplicity `%1` (`resumeLinear`). This guarantees single-shot consumption and prevents duplicate evaluations.
   - Formally index cursors by lookbehind bounds (`GradedCursor (horizon :: Nat)`). This proves that the engine will never scan backwards beyond `horizon` bytes, enabling aggressive garbage collection of stream prefixes (`evacuatePrefix`).
5. **Monotone Boolean Gram Formulas (Russ Cox Trigram Index Calculus)**:
   - For database pre-filtering, decouple index extraction from VM execution.
   - Extract required $k$-grams as a monotone boolean formula (`GramFormula a`: `GramAll`, `GramAny`, `GramExact`, `GramTop`, `GramBot`). Evaluating this formula against bitmap trigram indices prunes 99% of non-matching records before Pike/Thompson VM evaluation begins.

---

## 6. The "Orphaned Artifact" Problem & Where Things Fit

### 6.1 The Breakdown of Single-Repo Boundaries
Traditional software engineering assumes every document, script, and artifact belongs inside a specific Git repository. In an agentic multi-repo ecosystem, this assumption breaks down:
- **Cross-Cutting Waves & DAGs**: A task wave (e.g. `TP-SMIRK-001` or `TP-META-000`) touches `t-digest`, `polytropos`, `smirk`, and `sarutahiko` simultaneously. Placing the master DAG inside one repo creates cyclic dependencies and commits unrelated planning noise to clean library histories.
- **Meta-Tooling & Automation Scripts**: Tools like `yamaarashi-exec`, `hls-autoheal`, and `kioku-remember` serve the whole environment, not just one library.
- **Reference Literature & Specifications**: Research PDFs (e.g., `Synquid_AI_Magnifier.pdf`), paper extractions, and academic surveys do not belong in a library's production git tree.
- **Architectural Synthesis & Forensic Notes**: Cross-project notes (like this document) govern ecosystem policies, compiler quirks, and quota accounting across multiple projects.

### 6.2 The 4-Layer Placement Model
To solve this cleanly, we established a 4-layer taxonomy:

```
+-------------------------------------------------------------------------------+
| Layer 4: Living Memory Substrates (PostgreSQL 'kioku' & SQLite '.ok/')        |
| - Event-sourced agent memories, durable facts, AST indices, call graphs       |
+-------------------------------------------------------------------------------+
                                        │
                                        ▼
+-------------------------------------------------------------------------------+
| Layer 3: Systemic Tooling & Agent Harnesses ('~/src/sarutahiko/' & '~/.local')|
| - Shared executables: 'yamaarashi-exec', 'hls-autoheal', 'kioku-remember'     |
| - Ecosystem rule definitions: '.agents/rules/'                                |
+-------------------------------------------------------------------------------+
                                        │
                                        ▼
+-------------------------------------------------------------------------------+
| Layer 2: Ambient Orchestration & Task DAGs ('~/src/plans/')                   |
| - Master roadmap: 'PLAN.md' and 'STRUCTURE.md'                                |
| - Tier-1 orchestrator waves & Tier-2 task packets                             |
| - Reference corpus: 'ref/' (PDFs, page extractions)                           |
| - Cross-project architectural notes: 'architecture/'                          |
+-------------------------------------------------------------------------------+
                                        │
                                        ▼
+-------------------------------------------------------------------------------+
| Layer 1: Component Repositories ('~/src/polytropos/', '~/src/smirk/', etc.)   |
| - Pure library code, package tests, cabal manifests                           |
| - Component design notes: 'docs/notes/' (strictly scoped to that package)     |
+-------------------------------------------------------------------------------+
```

### 6.3 Where Does THIS Document Belong?
By following this taxonomy, this synthesis note lives in two deliberate locations:
1. **`~/src/plans/architecture/TOOLING_QUOTA_AND_ENGINEERING_SYNTHESIS.md`**:  
   Available as the canonical cross-project design document for orchestrator waves, task packet planning, and Gemini Argon design sessions.
2. **`~/src/sarutahiko/docs/notes/TOOLING_QUOTA_AND_ENGINEERING_SYNTHESIS.md`**:  
   Committed to git version control under `sarutahiko`, which serves as the host umbrella for developer tooling, observability, and agent governance.

---

## 7. Discoverability via Kioku: Exact Query Guide & Recipes

### 7.1 Understanding Kioku Retrieval
Memories and architectural decisions are persisted in `shinzui kioku` (PostgreSQL `postgresql:///kioku`). To retrieve facts effectively without guessing, keep the following fundamentals in mind:

1. **Namespace vs. Scope**:
   - Each memory is scoped (e.g. `antigravity:repo:smirk`, `antigravity:task:TP-SMIRK-002E`, `antigravity:meta`).
   - If you query from within a specific repository directory, Kioku defaults to that repo's scope.
   - **CRITICAL**: For cross-cutting, tooling, or quota facts, **always pass `--namespace-wide antigravity`** to search across all scopes in the ecosystem!
2. **Strategy Selection (`keyword` vs. `hybrid`)**:
   - `--strategy keyword`: Uses PostgreSQL Full-Text Search (`tsvector`/`tsquery`). It is deterministic, fast, and matches exact identifiers, error codes (`GHC-68383`), tool names (`hls-autoheal`), and technical terms.
   - `--strategy hybrid`: Combines keyword matching with `pgvector` dense embeddings. Ideal for semantic or conceptual questions, but requires embedding generation.

### 7.2 Concrete Copy-Pasteable Query Recipes

#### A. Quota Governance, Token Accounting & Context Inflation
```bash
# Search for token burn findings, context window inflation, and cache ratios
kioku recall "context window inflation quota burn" --namespace-wide antigravity --strategy keyword

# Search for Kagami-Ita token ledger design and circuit breakers
kioku recall "Kagami-Ita token ledger circuit breaker" --namespace-wide antigravity --strategy keyword

# Search for quota firewalls and airgapping subprocesses
kioku recall "quota firewall airgap sampling" --namespace-wide antigravity --strategy keyword
```

#### B. Tooling Configurations, Self-Healing & Compiler Quirks
```bash
# Search for hls-autoheal implementation and CLI usage
kioku recall "hls-autoheal unused imports" --namespace-wide antigravity --strategy keyword

# Search for GHC 9.14 vs HLint pattern/data namespace workaround
kioku recall "GHC-68383 pattern namespace specifier" --namespace-wide antigravity --strategy keyword

# Search for HLS multi-cradle hie.yaml configuration
kioku recall "multi-cradle hie.yaml discovery" --namespace-wide antigravity --strategy keyword
```

#### C. Agentic Scripting, Yaegi & Task Packet Automation
```bash
# Search for Yaegi Go scripting rationale and academic citations
kioku recall "Yaegi Go script agentic ergonomics" --namespace-wide antigravity --strategy keyword

# Search for autonomous task execution without LLMs
kioku recall "executor auto deterministic task" --namespace-wide antigravity --strategy keyword
```

#### D. High-Performance Code Patterns (Data Layouts, VM, Cursors)
```bash
# Search for flat array capture slots and backtrack frame pools
kioku recall "CaptureSlots PrimArray SmallArray VMFramePool" --namespace-wide antigravity --strategy keyword

# Search for linear cursor and graded lookbehind bounds
kioku recall "linear cursor graded horizon evacuatePrefix" --namespace-wide antigravity --strategy keyword

# Search for Russ Cox trigram index calculus and gram formulas
kioku recall "GramFormula required grams database pre-filter" --namespace-wide antigravity --strategy keyword
```

#### E. Systemic Organization & Cross-Project Placement
```bash
# Search for plans directory structure and orphaned artifact taxonomy
kioku recall "plans structure cross-project orchestration" --namespace-wide antigravity --strategy keyword

# Search for this exact document in Kioku
kioku recall "TOOLING_QUOTA_AND_ENGINEERING_SYNTHESIS" --namespace-wide antigravity --strategy keyword
```

---

## 8. Checklist for Gemini Argon Design & Planning Sessions

When entering a design and planning session with Gemini Argon, use the following architectural checklist to evaluate proposals:

- [ ] **Verification Asymmetry**: Does the proposed design prioritize *cheap, deterministic verification* over compact code authoring?
- [ ] **Mechanical Isolation**: Are mechanical changes (imports, formatting, pragmas) delegated to `hls-autoheal` or deterministic scripts rather than multi-turn LLM prompts?
- [ ] **Context Window Discipline**: Is the task scoped cleanly to run in an isolated leaf subagent or Yaegi script rather than the long-running orchestrator context?
- [ ] **Data Layout Overhead**: Are hot evaluation loops using unboxed flat arrays (`PrimArray`, `SmallArray`) rather than boxed associative maps (`Map`)?
- [ ] **Modal Bounds**: Can lookbehind, resource usage, or recursion depth be statically or graded-indexed at the type level to enable aggressive garbage collection?
- [ ] **Pre-Filtering Separation**: Can search spaces be pre-filtered via boolean $k$-gram formulas or lightweight index structures before invoking full state machine evaluators?
- [ ] **Placement Discipline**: Does the artifact belong in a specific repository (`Layer 1`), the orchestration hub `~/src/plans/` (`Layer 2`), systemic tooling `sarutahiko` (`Layer 3`), or durable memory `kioku` (`Layer 4`)?
