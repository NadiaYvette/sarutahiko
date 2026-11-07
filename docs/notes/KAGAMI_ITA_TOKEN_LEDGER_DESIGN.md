# Kagami-Ita (鏡板) Token Accounting & Quota Governance — Design Note

Status: DRAFT v0.1 · 2026-11-07  
Package: `sarutahiko-observability`  
Related: `OBSERVABILITY_DESIGN.md` (the canonical Kagami-Ita substrate §2 K1–K4),
`LLM_SUBSTRATE_DESIGN.md` (Utai model call signatures and prompt cache preservation),
`MEMORY_ENGINE_DESIGN.md` (envelope versioning and offloading to Kioku/Kiroku)

---

## 1. Thesis & Forensic Diagnosis (Where the Quota Went)

On 2026-11-07, an extensive forensic audit of transcripts across `~/.gemini/antigravity-cli/brain/`
revealed the following aggregate token consumption:

| Metric | Measured Value | Analysis |
|---|---|---|
| **Cumulative Fresh Input Tokens** | 14,028,211 tokens | High cost un-cached consumption |
| **Cumulative Prompt Cache Reads** | 265,935,298 tokens | 95.0% ecosystem cache hit ratio |
| **Cumulative Generated Output** | 717,419 tokens | Standard model completion volume |
| **Top Consumer (Single Session)** | 6,170,000 fresh tokens | Primary orchestrator conversation |
| **Orchestrator Turn Count** | 1,256 turns | Deep long-running multi-wave session |
| **Peak Context Window Size** | ~186,000 tokens | Massive transcript inflation |

### The Core Pathology: Context Window Inflation

The primary driver of quota exhaustion was **context window inflation**:
1. At turn 1,200, the conversation context window contained ~186,000 tokens.
2. Even with Google Gemini's automatic prompt caching achieving a 95% cache hit ratio,
   each wake-up, status check, or leaf tool step still incurred:
   $$\text{Fresh Tokens} \approx 0.05 \times 186,000 \approx 9,300 \text{ tokens/turn}$$
3. Over hundreds of incremental orchestrator turns (verifying builds, querying subagents,
   checking git status), these 9.3k chunks accumulated into millions of fresh input tokens.
4. Cache invalidation spikes: Whenever dynamic tool declarations shifted or system prompt
   prefixes invalidated the cache, a single turn incurred the entire 186,000 fresh tokens.

---

## 2. The Kagami-Ita (鏡板) Architecture

In Noh theatre, the **Kagami-Ita** (鏡板) is the sacred mirror-board at the back of the stage
featuring an ancient pine tree (*oi-matsu*). It reflects all movements of the actors, chorus,
and orchestra without distortion.

In Sarutahiko, `sarutahiko-observability` implements Kagami-Ita as the pure token accounting
and circuit-breaking substrate:

```
+-----------------------------------------------------------------------+
|                        Kagami-Ita Substrate                           |
|                    (sarutahiko-observability)                         |
|                                                                       |
|  +--------------------+   +-------------------+   +----------------+  |
|  |  Transcript JSONL  |-->|    TokenLedger    |-->| CircuitBreaker |  |
|  |     Ingestion      |   |  (Totals & Ratios)|   |   & Alarms     |  |
|  +--------------------+   +-------------------+   +----------------+  |
|                                     |                                 |
|                                     v                                 |
|                     +-------------------------------+                 |
|                     | Markdown & Prometheus Metrics |                 |
|                     +-------------------------------+                 |
+-----------------------------------------------------------------------+
```

### Invariants

- **K-TOK-1 (Deterministic Accounting):** Token accounting is a pure reduction over turn
  records. No mutable global variables or network calls are required to compute metrics.
- **K-TOK-2 (Cache Hit Metric):** Cache efficiency is canonically defined as:
  $$\text{CacheHitRatio} = \frac{\text{TotalCacheRead}}{\text{TotalFreshInput} + \text{TotalCacheRead}}$$
- **K-TOK-3 (Circuit Breaker Tripping):** When configured quota budgets (`QuotaBudget`) are
  breached, `evaluateCircuitBreaker` trips to `BreakerTripped` to prevent runaway polling loops.
- **K-TOK-4 (Inflation Warnings):** When context window size exceeds 100,000 tokens, the
  system generates a `SeverityWarning` alerting the orchestrator to execute `/compact` or offload
  historical turns to Kioku/Kiroku.

---

## 3. Component Hierarchy (`sarutahiko-observability`)

1. **`Sarutahiko.Observability.TokenLedger`**:
   - `TurnTokenRecord`: Turn-level breakdown (fresh input, cache read, cache creation, output tokens).
   - `TokenTotals`: Cumulative counters and wall-clock execution time.
   - `QuotaBudget`: Configurable thresholds for maximum fresh tokens, turn spikes, and context window limits.
   - `QuotaAlert`: Structured warnings and critical alarms.
   - `formatLedgerSummary` & `formatPrometheusMetrics`: Dual human/machine exposition formats.

2. **`Sarutahiko.Observability.Transcript`**:
   - Zero-dependency JSONL parser streaming `transcript.jsonl` entries directly into the ledger.
   - Robust to non-model events (ignoring user prompts, tool results without token counts).

3. **`Sarutahiko.Observability.KagamiIta`**:
   - `OperationalDiagnosis`: Heuristic evaluation of token health.
   - `evaluateCircuitBreaker`: Pure circuit-breaker state machine (`BreakerClosed` | `BreakerTripped`).
   - Strategic remediation recommendations (context compaction, subagent isolation, cache stabilization).

---

## 4. Operational Recommendations for Quota Preservation

1. **Mandatory Subagent Delegation for Synthesis Waves:**
   - Long compilation loops, test iterations, and code synthesis must run in leaf subagents (`yamaarashi-exec run` or `invoke_subagent`).
   - Leaf subagents receive isolated, minimal context windows (~5,000 tokens), preventing the 186k orchestrator context from being evaluated on every GHC compiler pass.
2. **Context Window Compaction Triggers:**
   - When the orchestrator turn count approaches 100 turns or context exceeds 100k tokens, invoke `/compact` or transfer conversation logs to the Kioku vector/FTS store.
3. **Prompt Cache Prefix Freezing:**
   - System prompts, tool definitions, and skill manifests must remain frozen and ordered deterministically at the head of the prompt.
   - Avoid mutating tool descriptions dynamically between turns.
