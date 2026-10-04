# Extensible Record + Algebraic Effects Audit

This document lists sarutahiko modules that are good candidates for refactoring to the idiomatic
extensible‑record + algebraic‑effects style (`Eff e (Rec r) a`), along with brief rationale and
what a refactor would entail.

## Candidate Modules

| Package / Sub‑module | Why it fits | Refactor outline |
|----------------------|-------------|------------------|
| **packages/task-manager** (kiroku/keiro/kioku task‑packet system) | Carries worker config, hooks, retry policies; needs logging, metrics, failure handling, async I/O. | Replace custom `TaskM` stack with `Eff es (Rec r) a`. Record `r` holds cfg, hooks, metrics. Effects `es` = Reader, State, Trace, Fail, IO (plus Async if needed). Primitive actions: `reader #cfg .workers`, `modify' $ \s -> s & #metrics .pending +~ 1`, `trace "dispatching task"`. Runner supplies concrete carriers (`runReader initCfg`, `runState initMetrics`, `runTraceIO logger`, `runFailEither`, `runIO`). |
| **packages/memory-engine** (spine v0.2, PolicyEffect, ordering C1‑C6) | Spine is a record of pointers/generation/order/cache; Policy effects already expressed as effect signature; needs tracing, failure, occasional STM/IO. | Model spine as extensible record (`[ "ptr" := Ptr, "gen" := Generation, "order" := Order, "cache" := Cache ]`). Effects row: `[ PolicyEffect, Trace, Fail, IO ]`. Move spine state into a `State` effect over the record; keep existing PolicyEffect carrier. Enables pure `State` carrier for testing. |
| **packages/llm-substrate** (codec decision, renderer, laws L1‑L4) | Holds tokenizer, sampler, max‑len, hooks; needs logging, error handling, ability to swap back‑ends. | Config → extensible record (`[ "tok" := Tokenizer, "sampler" := Sampler, "maxLen" := Int, "hooks" := LLMHooks ]`). Effects: Reader, State (token‑usage counters), Trace, Fail, IO. Renderer/law checks become `Eff` actions (`reader #tok .encode`, `modify' $ \s -> s & #usage +~ n`, `trace "generated token"`). Swap back‑ends by changing the IO carrier or adding an `LLM` effect with multiple interpreters. |
| **packages/hokora** (Phase 1.5 agent surface) | Manages inbox, outbox, policy state; uses custom `HokoraM` (ReaderT+StateT+ExceptT); needs tracing and test doubles. | Replace `HokoraM` with `Eff es (Rec r) a` where `r = [ "inbox" := TBM Msg, "outbox" := TBM Msg, "policy" := Policy ]` and `es = [ Reader, State, Trace, Fail, IO ]`. Inbox/outbox as `State` effects over bounded queues (or keep `TVar` inside record and use `liftIO . atomically`). Unit testing becomes trivial with pure `State` carrier. |
| **packages/instruments** (cache‑simulator, replay harness) | Simulator carries mutable statistics (hits, misses, latency histograms); replay harness reads trace, applies policies, produces reports. | Statistics → extensible record (`[ "hits" := Int, "misses" := Int, "latency" := Histogram ]`). Core simulator step becomes `Eff` action that `modify'` those fields. Add optional `Trace` effect for each memory access. Runner can use pure `State` carrier for fast functional tests or `IO` carrier for real output. |
| **packages/agent-core** (core Agent loop, skill execution, cron) | Loop carries skill routes, cron tables, memory policies, stats; needs failure handling, logging, async external calls (Telegram, HTTP). | Loop state → record (`[ "skills" := SkillMap, "cron" := CronTable, "memPolicy" := MemPolicy, "stats" := AgentStats ]`). Effects: Reader (config), State (loop state), Trace, Fail, IO (external calls), possibly Async for background jobs. Core `processMessage` becomes series of `reader`, `modify'`, `trace`, `liftIO` (or effect-specific `send`/`await`). Enables testing with pure carriers. |
| **packages/koi/koi-loom** (visual‑debugger / REPL UI) | UI state (cursor, open files, breakpoints); needs logging, error pop‑ups, custom renderers. | UI state → extensible record. UI loop becomes `Eff` with Reader (theme/config), State (UI record), Trace (debug logs), Fail (parse errors), IO (terminal rendering). Headless testing trivial with pure carriers. |
| **packages/kogaki-wire** (lexer/SSE) – *only if runtime configurability anticipated* | Currently tight allocation‑free loop with minimal configurability. If plug‑in delimiters, user‑supplied transforms, or metrics collection are added, extensible‑record/effects pay off. | Keep hot‑path lexer pure (`ByteString -> Either err (Token, ByteString)`). Wrap in effect layer supplying Reader config record (`[ "maxDepth" := Int, "strict" := Bool, "hooks" := WireHooks ]`) and optional Trace effect for logging. Allows behaviour changes without re‑lexing entire input. |
| **packages/memory/context** (PolicyEffect, ordering C1‑C6) | Same rationale as memory‑engine. | Same refactor approach: extensible record for spine/context, effect row for PolicyEffect, Trace, Fail, IO. |

## General Refactor Checklist

1. **Identify mutable state** → turn into a record with `:=` fields (using `large‑anon`/`row‑types`).
2. **Identify capabilities** (logging, failure, async, randomness, etc.) → list as effect signatures in an effect row.
3. **Replace custom monad transformers** (`ReaderT … (StateT … (ExceptT … IO))) a`) with a single `Eff es (Rec r) a`.
4. **Write primitive actions** using `reader`, `gets`, `modify'`, `trace`, `throwError`, `liftIO` (or effect‑specific carriers like `send`, `await`).
5. **Provide a runner** that supplies concrete carriers (`runReader initConf`, `runState initState`, `runTraceIO logger`, `runFailEither`, `runIO`, `runAsync`, etc.).
6. **Update tests** to use pure carriers (`runState`, `runReader`, `runTracePure`, `runFailEither`) – often cuts test boilerplate dramatically.
7. **Check performance** – in tight loops keep the hot path pure (as in kogaki‑wire) and only wrap outer orchestrator with effects.

## Expected Benefits

* Elimination of `Has…` typeclass boilerplate and manual `modifyIORef'` calls.
* Open extensibility: new config fields or new effects can be added without touching existing functions.
* Improved testability via pure carriers for state, trace, fail.
* Low performance impact for most code (effect carriers are newtype wrappers; GHC can specialise them away when the effect row is concrete).

This audit captures the modules where the payoff is highest as of branch `nadia.chambers/hermes-trial-run-004`. Feel free to start with one (e.g., task‑manager or memory‑engine) and use the resulting diff as a template for the others.