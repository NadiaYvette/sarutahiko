# Phase 1.5 Implementation Plan — The Hokora (祠) Vertical Validation Slice

Status: DRAFT v0.1 · 2026-09-25 — The operational work breakdown structure (WBS)
and hermetic task packets for the Phase 1.5 Hokora vertical slice.
Related: `NIH_PLAN.md` (§2 package map, §4 roadmap, §6 backlog item 9),
`HOKORA_SPEC.md` (the walking skeleton specification, budget ≤2k LOC),
`PHASE_0_PLAN.md` (substrate foundations, closures 1–5),
`PHASE_1_PLAN.md` (wire flagship, MCP engine, subprocess supervisor),
`MEMORY_ENGINE_DESIGN.md` (§3.1 spine v0.2, §3.4 ordering contract, §4 session locking),
`EFFECT_CATALOG_DESIGN.md` (neutral signatures, Stepper m a, dual interpreters),
`KOGAKI_DESIGN.md` (pervasive Unicode, offline token counting),
`~/src/kuroko/` (comparison baseline: ≈1k core / 1.9k incl. tests).

**Thesis.** Substrate APIs designed in isolation are inevitably flawed in the exact
places where they must compose. Phase 1.5 builds the **hokora (祠)**: a small shrine
built on the peak early to prove the peak is reachable. It is the program’s
**walking skeleton** (tracer bullet)—a single CLI executable, strictly budgeted at
$\le 2,000$ lines of our code, taking a one-shot prompt, running one interpreted
ReAct turn in `Eff es`, calling an external MCP tool subprocess over real stdio,
appending every turn step to an event-sourced SQLite database with the blessed
spine v0.2 envelope, folding a pure reducer over the log, and printing a summary.

Phase 1.5 serves as the critical empirical gate: if our extensible records, neutral
effect signatures, and streaming kernels compose cleanly at kilometer 2, we proceed
confidently to Phase 2. If seams resist composition, we discover it and correct the
designs before incurring sunk costs in the full agent core.

---

## 0. The Five Pre-Implementation Closures

Before writing Phase 1.5 code, five specific architectural closures are formally settled:

### Closure 1: The Skinny Spine Extraction Protocol
Per `HOKORA_SPEC.md` §4.1 and `NIH_PLAN.md` §4, Phase 1.5 does not wait for Phase 2
(model provider matrix) or Phase 4 (database relational AST and dialect compilation).
Instead, it pulls forward a minimal **Skinny Spine**:
1. **`ModelAPI` Minimal Slice:** Neutral `ModelAPI` GADT supported by:
   - `utai-mock`: Deterministic catalog interpreter obeying catalog laws L1–L4.
   - Minimal live HTTP client for OpenAI/Anthropic streaming completions using `kogaki-wire`.
2. **`SessionStore` Minimal Slice:** A direct `direct-sqlite` append writer and cursor
   implementing `SessionStore` for spine v0.2 rows. No SQL AST compilation; raw,
   parameterized queries using `sqlite3_step` wrapped in `Stepper m a`.
3. **Turn-as-a-Value:** A single ReAct turn written entirely as a value in `Eff es`
   referencing only neutral effect signatures, verified by executing identically
   under both `effectful` and `polysemy`.

---

### Closure 2: Fail-Closed Session Concurrency & Single-Writer Lease
Per `MEMORY_ENGINE_DESIGN.md` §4.3, concurrent writes to the same session log risk
branching or corrupting the linear event sequence:
- **SQLite Lease Table:**
  ```sql
  CREATE TABLE IF NOT EXISTS session_locks (
    session_id TEXT PRIMARY KEY,
    owner_id   TEXT NOT NULL,
    acquired_at TEXT NOT NULL,
    expires_at  TEXT NOT NULL
  );
  ```
- **Atomic Acquisition:** Hokora executes `BEGIN IMMEDIATE` and attempts an atomic
  upsert with lease expiration check. If another worker holds an active lease, Hokora
  aborts immediately with `SessionConcurrencyLockError` (fail-closed, zero silent races).

---

### Closure 3: Exact Event Row Payloads (Spine v0.2)
The Hokora event log records five canonical event variants in `session_events`:

| Event Kind | Schema Version | Payload Record (`Record Identity r`) |
|---|---|---|
| `"session_start"` | `1` | `'{ "sessionId": Text, "model": Text, "startedAt": UTCTime }` |
| `"user_prompt"` | `1` | `'{ "prompt": Text, "tokenEstimate": Int }` |
| `"model_call"` | `1` | `'{ "callId": Text, "tool": Text, "arguments": WireEnvelope '[] }` |
| `"tool_result"` | `1` | `'{ "callId": Text, "output": Text, "isError": Bool, "durationMs": Int }` |
| `"turn_summary"` | `1` | `'{ "turn": Int, "inputTokens": Int, "outputTokens": Int, "durationMs": Int }` |

Payloads serialize via `sarutahiko-records` with unknown fields preserved in
`WireEnvelope` (E4 anti-silent-loss guard).

---

### Closure 4: Real Stdio Subprocess MCP Execution
To guarantee that tool execution tests real IPC seams rather than in-memory fakes:
- The default tool is an external subprocess (`calc` or `echo`) running over stdio.
- Spawned via `sarutahiko-process`, bracketed under `Resource` / `Scoped`.
- Piped stdio communicates via `sarutahiko-mcp` (JSON-RPC 2.0 handshake $\rightarrow$ `tools/call`).
- **Fail-Closed Teardown:** Turn timeouts or parent process crashes trigger `SIGTERM`
  followed by hard `SIGKILL` (zero zombie processes).

---

### Closure 5: The Pure Conversation-Tail Reducer & Replay Property
The Hokora executable exercises event sourcing directly:
- **Pure Reducer:** A pure left fold over the event stream:
  $$\text{reducer} :: \text{SessionState} \rightarrow \text{Event} \rightarrow \text{SessionState}$$
- **The Replay Law (RPL-1):**
  Deleting all derived in-memory state and replaying the SQLite event log through the
  reducer yields the exact same `SessionState` bit-identically.
- The summary prints event count, token totals (counted via `kogaki-core`), tool latency,
  and the final response message.

---

## 1. The Hermetic Task Packets (Work Breakdown Structure)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PHASE 1.5 TASK PACKETS                              │
├──────────────┬─────────────────────────────┬────────────────────────────────┤
│ Packet ID    │ Target Scope                │ Deliverables                   │
├──────────────┼─────────────────────────────┼────────────────────────────────┤
│ **TP-1.5.1** │ `sarutahiko-store-sqlite`   │ Skinny Spine direct-sqlite     │
│              │                             │ writer, lease lock, cursors    │
├──────────────┼─────────────────────────────┼────────────────────────────────┤
│ **TP-1.5.2** │ `sarutahiko-model-skinny`   │ `ModelAPI` interpreter,        │
│              │                             │ `utai-mock`, live HTTP client  │
├──────────────┼─────────────────────────────┼────────────────────────────────┤
│ **TP-1.5.3** │ `sarutahiko-reducer-skinny` │ Pure conversation-tail reducer │
│              │                             │ and event fold engine          │
├──────────────┼─────────────────────────────┼────────────────────────────────┤
│ **TP-1.5.4** │ `sarutahiko-turn-skinny`    │ Interpreted ReAct turn value   │
│              │                             │ in `Eff es`                    │
├──────────────┼─────────────────────────────┼────────────────────────────────┤
│ **TP-1.5.5** │ `hokora` CLI Executable     │ Standalone CLI, budget audit,  │
│              │ & Parity Gate               │ dual-effect verification suite │
└──────────────┴─────────────────────────────┴────────────────────────────────┘
```

---

### Task Packet TP-1.5.1: `sarutahiko-store-sqlite` — Skinny Spine SQLite Writer
- **Target Scope:** SQLite session append writer implementing `SessionStore` with fail-closed locking and `Stepper m a` event streaming.
- **Dependencies:** `packages/sarutahiko-records`, `packages/sarutahiko-effect-signatures`, `direct-sqlite`.
- **Exact Module Paths:**
  - `packages/sarutahiko-store-sqlite/src/Sarutahiko/Store/Sqlite/Schema.hs`
  - `packages/sarutahiko-store-sqlite/src/Sarutahiko/Store/Sqlite/Lock.hs`
  - `packages/sarutahiko-store-sqlite/src/Sarutahiko/Store/Sqlite/Writer.hs`
  - `packages/sarutahiko-store-sqlite/src/Sarutahiko/Store/Sqlite/Reader.hs`
- **Core Schema & Types:**
  ```haskell
  data SessionLock = SessionLock
    { lockSessionId  :: !Text
    , lockOwnerId    :: !Text
    , lockAcquiredAt :: !UTCTime
    , lockExpiresAt  :: !UTCTime
    } deriving stock (Eq, Show)

  data StoredEvent = StoredEvent
    { eventSeq       :: {-# UNPACK #-} !Int64
    , eventSessionId :: !Text
    , eventKind      :: !Text
    , eventSchemaV   :: {-# UNPACK #-} !Int
    , eventTimestamp :: !UTCTime
    , eventPayload   :: !ByteString
    } deriving stock (Eq, Show)
  ```
- **Invariants & Laws:**
  1. *Linear Sequence Guarantee:* Event sequence numbers (`eventSeq`) are strictly monotonically increasing ($1, 2, 3, \dots$) per session.
  2. *Locking Mutual Exclusion:* Attempting to append events to a session held by another active lease immediately raises `SessionConcurrencyLockError`.
- **Verification Commands:**
  ```bash
  cabal test sarutahiko-store-sqlite:test-sqlite-skinny --test-options="-p /LockConcurrency/"
  cabal test sarutahiko-store-sqlite:test-sqlite-skinny --test-options="-p /LinearSequence/"
  ```

---

### Task Packet TP-1.5.2: `sarutahiko-model-skinny` — Minimal Model Client & Mock
- **Target Scope:** Implementing `ModelAPI` via the deterministic `utai-mock` and a minimal streaming HTTP client.
- **Dependencies:** `packages/sarutahiko-effect-signatures`, `packages/kogaki-wire`, `packages/kogaki-core`.
- **Exact Module Paths:**
  - `packages/sarutahiko-model-skinny/src/Sarutahiko/Model/UtaiMock.hs`
  - `packages/sarutahiko-model-skinny/src/Sarutahiko/Model/StreamingClient.hs`
- **Core Types:**
  ```haskell
  data ModelChoice
    = ChoiceText !Text
    | ChoiceToolCall !Text !Text !ByteString -- callId, toolName, argsJson
    deriving stock (Eq, Show)

  data ModelStreamChunk
    = ChunkDeltaText !Text
    | ChunkStop !StopReason
    deriving stock (Eq, Show)
  ```
- **Invariants & Laws:**
  1. *Catalog Laws L1–L4:* `utai-mock` satisfies deterministic token consumption, proper stop reason delivery, and replay consistency.
  2. *Resource Bracketing:* HTTP response sockets are finalized promptly via `Resource` / `Scoped` on stream termination or interruption.
- **Verification Commands:**
  ```bash
  cabal test sarutahiko-model-skinny:test-model-skinny --test-options="-p /UtaiMockLaws/"
  ```

---

### Task Packet TP-1.5.3: `sarutahiko-reducer-skinny` — Conversation Reducer & Replay
- **Target Scope:** Pure conversation-tail fold over stored event streams, computing token usage and reconstructing turn history.
- **Dependencies:** `packages/sarutahiko-records`, `packages/kogaki-core`.
- **Exact Module Paths:**
  - `packages/sarutahiko-reducer-skinny/src/Sarutahiko/Reducer/Types.hs`
  - `packages/sarutahiko-reducer-skinny/src/Sarutahiko/Reducer/Tail.hs`
- **Core Types:**
  ```haskell
  data TurnState = TurnState
    { tsSessionId    :: !Text
    , tsTurnCount    :: {-# UNPACK #-} !Int
    , tsTotalTokens  :: {-# UNPACK #-} !Int
    , tsLastOutput   :: !(Maybe Text)
    , tsToolCallsRun :: ![Text]
    } deriving stock (Eq, Show)

  stepReducer :: TurnState -> StoredEvent -> Either ReducerError TurnState
  ```
- **Invariants & Laws:**
  1. *Replay Law (RPL-1):* $\text{foldlM stepReducer } s_0 \text{ events} = \text{reconstructedState}$ bit-identically across arbitrary replays.
  2. *Fail-Closed Filtering:* Unknown event kinds or incompatible schema versions return a structured `UnrecognizedSchemaVersion` error without silent mutation.
- **Verification Commands:**
  ```bash
  cabal test sarutahiko-reducer-skinny:test-reducer --test-options="-p /ReplayBitIdentical/"
  ```

---

### Task Packet TP-1.5.4: `sarutahiko-turn-skinny` — Interpreted ReAct Turn Value
- **Target Scope:** The single-turn ReAct program expressed as an abstract program value in `Eff es`.
- **Dependencies:** `packages/sarutahiko-effect-signatures`, `packages/sarutahiko-process`, `packages/sarutahiko-mcp`.
- **Exact Module Paths:**
  - `packages/sarutahiko-turn-skinny/src/Sarutahiko/Turn/ReAct.hs`
- **Core Program Signature:**
  ```haskell
  runSingleTurn
    :: ( Process :> es
       , SessionStore :> es
       , ModelAPI :> es
       , Log :> es
       , Clock :> es
       , Resource :> es
       )
    => Text -> Eff es TurnState
  ```
- **Execution Flow:**
  1. Acquire session lock and append `session_start` and `user_prompt` events.
  2. Invoke `ModelAPI.StreamCompletion`; stream response chunks and log tokens.
  3. If model requests tool call, dispatch to external MCP subprocess via `sarutahiko-process`.
  4. Receive tool result from stdio; append `tool_result` event to SQLite.
  5. Feed tool output back to `ModelAPI` for final answer generation; append `turn_summary`.
  6. Fold conversation-tail reducer over log; return `TurnState`.
- **Invariants & Laws:**
  1. *Neutral Signature Exclusivity:* `runSingleTurn` does not import `effectful` or `polysemy` directly; it compiles purely against neutral capability constraints.
- **Verification Commands:**
  ```bash
  cabal test sarutahiko-turn-skinny:test-turn --test-options="-p /NeutralCompilation/"
  ```

---

### Task Packet TP-1.5.5: `hokora` CLI Executable & Dual-Interpreter Parity Gate
- **Target Scope:** The compiled standalone executable `hokora`, budget measurement, and dual-effect verification.
- **Dependencies:** All Phase 0, Phase 1, and Phase 1.5 packages.
- **Exact Module Paths:**
  - `packages/hokora/app/Main.hs`
  - `test/suites/hokora/HokoraParitySpec.hs`
- **The Code-Volume Budget Rule:**
  The Hokora executable code (excluding substrate libraries) is audited via `cloc`:
  $$\text{Code Volume} \le 2,000 \text{ LOC}$$
- **Dual-Interpreter Parity Gate:**
  The exact same `runSingleTurn` program runs green under both:
  - `sarutahiko-effect-effectful` (production executable)
  - `sarutahiko-effect-polysemy` (test harness)
- **Deterministic Verification Commands:**
  ```bash
  # 1. Execute live Hokora ReAct turn against mock subprocess
  cabal run hokora -- "calculate 17 * 43" --mock-model --db /tmp/hokora.db

  # 2. Run dual-effect parity tests
  cabal test hokora:test-parity --test-options="-p /EffectfulVsPolysemy/"

  # 3. Verify SQLite replay law
  cabal run hokora-replay -- --db /tmp/hokora.db

  # 4. Measure code volume against <= 2,000 LOC ceiling
  sh scripts/measure_hokora_budget.sh
  ```
