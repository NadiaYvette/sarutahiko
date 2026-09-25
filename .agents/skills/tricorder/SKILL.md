---
name: tricorder
description: Check continuous GHCi build status, compiler errors, warnings, or test results via the background tricorder daemon or MCP server. Use when verifying compilation or checking build diagnostics.
user-invocable: true
---

# Checking Build Status with Tricorder

[`tricorder`](file:///home/nyc/src/tricorder/) maintains a continuous background GHCi daemon that compiles packages in the `cabal.project` workspace incrementally.

Using `tricorder` slashes token burn by >95%: instead of dumping 300+ lines of raw GHC build logs into context (~2,500 tokens), it returns machine-readable JSON diagnostics in $<50$ tokens.

## 1. Using the MCP Server (`tricorder-mcp`)

If the assistant environment supports Model Context Protocol (configured via [`.mcp.json`](file:///home/nyc/src/sarutahiko/.mcp.json) or [`.agents/mcp.json`](file:///home/nyc/src/sarutahiko/.agents/mcp.json)):

- **`status`**: Query current compiler errors, warnings, and diagnostics. Pass `wait: true` to block until in-progress compilation finishes.
- **`test_results`**: Query the latest test execution results. Pass `failed: true` to see only failing suites.
- **`source`**: Retrieve Haskell source for installed or dependency modules (e.g. `Data.Map.Strict` or `LargeAnon`).

## 2. CLI Invocation Fallback

When querying via Bash:

```bash
# Query machine-readable compiler errors and warnings in JSON (<50 tokens)
tricorder status --json

# Block until current incremental compilation finishes
tricorder status --wait --json

# Inspect dependency module source code directly from disk
tricorder source <Module.Name>
```

## 3. Tier 0 POSIX Fallback (When Daemon is Not Running)

If the background daemon is not running and you want a non-intrusive compilation check:

```bash
# Verify dependency plans without rebuilding everything
cabal build all --dry-run

# Standard compilation fallback
cabal build all
```
