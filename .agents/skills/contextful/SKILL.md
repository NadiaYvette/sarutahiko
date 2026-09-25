---
name: contextful
description: Query project context packs, local FTS5 BM25 search, and token-budgeted citations via Contextful.
user-invocable: true
---

# Project Context & Search with Contextful

[`contextful`](file:///home/nyc/src/contextful/) provides a local context management and search engine for agentic AI using SQLite FTS5 (BM25 lexical ranking) and tree-sitter AST parsing.

Instead of reading dozens of files, Contextful indexes the workspace once and returns ranked, cited, token-budgeted **context packs**.

## Usage Workflows

### 1. Generating Context Packs for Queries
To retrieve a token-budgeted context pack matching a specific query:
```bash
# Query the indexed codebase with a token budget
cxf search "<query>" --budget 2000

# Generate an evidence pack for a feature or task
cxf pack "effect handlers polysemy effectful" --max-tokens 1500
```

### 2. Inspecting Project Index Status
To check index coverage, file counts, and database status:
```bash
cxf status
```

### 3. Progressive Disclosure Fallback
If `contextful` is not built or running, fall back directly to:
1. `grep -w "^Symbol" tags` (Level 0 definition lookup)
2. `sg -p '<pattern>' packages/` (Level 1 AST structural search)
3. `rg --type haskell "<symbol>" packages/` (Level 2 text search)
