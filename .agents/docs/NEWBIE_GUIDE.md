# `sarutahiko-tooling` Newbie Quickstart & Token-Conservation Guide

**Audience:** New human contributors and AI coding assistant drivers (Antigravity, Claude Code, Cursor, Aider).  
**Canonical Package:** [`sarutahiko-tooling`](../README.md)  
**Parent Design Note:** [`docs/notes/ASSISTANT_TOOLING_DESIGN.md`](../../docs/notes/ASSISTANT_TOOLING_DESIGN.md)  

---

## 1. The Core Invariant: Never Dump Whole Modules

In a multi-package Haskell codebase of 30–50+ packages, dumping full 500-line source modules into the conversation context wastes 2,500–4,000 tokens per turn and triggers the **"lost in the middle" attention collapse**.

Always follow the **Progressive Disclosure Funnel**:
```
Level 0: Global Navigation  (docs/INDEX.md, tags)       →   ~10–50 tokens
Level 1: Structural Outline (tree-sitter, ast-grep)     →   ~100–250 tokens
Level 2: Targeted Slice     (view_file Start/EndLine)   →   ~200–500 tokens
```

---

## 2. Fast Symbol Navigation (Level 0 — <15 tokens)

Before opening any file, find the symbol's exact location in `./tags`:
```bash
grep -w "^<SymbolName>" tags
```
*Examples:*
```bash
grep -w "^Field" tags
grep -w "^FileSystemEffect" tags
grep -w "^RecordConstraints" tags
```
This immediately returns the exact file path and line number in $<15$ tokens.

Next, view **only** the relevant lines using `view_file` (e.g. ±15 lines around the symbol).

---

## 3. Instant Compiler Verification with Tweag's Tricorder (<50 tokens)

Do **NOT** run `cabal build all` after small edits. A full cabal build dumps 200–500 lines of terminal logs (~2,500 tokens).

Instead, query the in-memory background GHCi daemon:
```bash
# Query machine-readable compiler errors and warnings in JSON (<50 tokens)
tricorder status --json

# Block until current incremental compilation finishes
tricorder status --wait --json

# Inspect dependency source code directly without downloading tarballs
tricorder source <Module.Name>
```

If the REPL supports Model Context Protocol (configured via [`.mcp.json`](../../.mcp.json)):
- Call MCP tool `status(wait: true)`.

---

## 4. Structural Code Audits with `ast-grep` (<300 tokens)

When refactoring or searching across packages, query the Concrete Syntax Tree directly:
```bash
# Find all GADT effect signatures
sg -p 'data $NAME :: Effect where $$$CONSTRUCTORS' packages/

# Find all extensible record type definitions
sg -p 'type $NAME = Record $F $R' packages/

# Find all interpreter handler functions
sg -p 'run$NAME :: Eff ($EFF : $ES) $A -> Eff $ES $A' packages/

# Find all row constraints
sg -p 'RecordConstraints $F $R $C' packages/
```

---

## 5. LM Program Tracing & Deterministic Replay with Nadeem's `shikumi`

To inspect language-model executions, verify token budgets, and test pipeline determinism:
```bash
# Render the hierarchical trace tree for recorded LM runs
shikumi trace

# Replay a recorded trace offline without spending API tokens
shikumi replay <trace-id>

# Run program evaluations
shikumi eval
```

---

## 6. Token-Budgeted Evidence Packs with `contextful`

When researching unfamiliar features or cross-cutting subsystems:
```bash
# Generate a ranked, cited evidence pack bounded by a token ceiling
cxf pack "<topic-query>" --max-tokens 1500

# Query the codebase with a token budget
cxf search "<query>" --budget 2000
```

---

## 7. The Inviolable Floor: Tier 0 POSIX Baseline

If any daemon, MCP server, or external binary fails or is unavailable on your system:
```bash
cabal build all
cabal test all
```
The codebase **never** requires external daemons or specialized tooling to compile and pass tests.
