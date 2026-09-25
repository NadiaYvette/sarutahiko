---
name: shikumi
description: Execute, trace, optimize, and replay typed language-model programs and compaction routines via Nadeem Bitar's shikumi CLI.
user-invocable: true
---

# Typed LM Programs & Tracing with Shikumi

[`shikumi`](file:///home/nyc/src/shikumi/) is Nadeem Bitar's framework for typed, structured, evaluable language-model programs in Haskell.

It provides deterministic execution, hierarchical tracing, context compaction, and replay.

## Available Workflows

### 1. Inspect Hierarchical Traces
Render the full trace tree for recorded LM runs to inspect exact prompt assembly, token budgets, and tool invocations:
```bash
shikumi trace
```

### 2. Deterministic Replay
Replay a recorded trace without making external network calls to verify pipeline determinism:
```bash
shikumi replay <trace-id>
```

### 3. Program Evaluation
Evaluate a typed LM program against its dataset and metric:
```bash
shikumi eval
```

### 4. Sliding-Window Context Compaction
Reference implementation for sliding-window context compression:
See `Shikumi.Compaction` in [`/home/nyc/src/shikumi/shikumi/src/Shikumi/Compaction.hs`](file:///home/nyc/src/shikumi/shikumi/src/Shikumi/Compaction.hs).
