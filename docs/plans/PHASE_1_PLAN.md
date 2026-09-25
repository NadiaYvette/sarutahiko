# Phase 1 Implementation Plan — Wire Flagship & Lean Protocol Codecs

Status: DRAFT v0.1 · 2026-09-25 — The operational work breakdown structure (WBS)
and hermetic task packets for Phase 1 execution.
Related: `NIH_PLAN.md` (§2 package map, §3.3 wire contracts, §4 roadmap),
`PHASE_0_PLAN.md` (foundation, closures 1–5, TP-0.1–TP-0.6),
`KOGAKI_DESIGN.md` (doctrine for Unicode, codecs, external faithfulness),
`FIELDS_RECORDS_DESIGN.md` (linear-time vector decoder, docrecords introspection),
`EFFECT_CATALOG_DESIGN.md` (neutral signatures, Stepper, Process/Resource),
`HOKORA_SPEC.md` (Phase 1.5 target consumer),
`REUSE_REGISTER.md` (§2.1–§2.3 reuse boundaries).

**Thesis.** Phase 0 establishes the inert internal organs (records, neutral GADTs,
pervasive string normalization, and dual effect interpreters). Phase 1 gives the
system its first external voice. It delivers the **Wire Flagship**: spec-conformant
JSON-RPC 2.0, JSON Schema row mapping, and the Model Context Protocol (MCP 2025-03-26),
enabling `sarutahiko` to communicate directly with external AI REPLs (Hermes, Claude
Code, Zed) and supervise external tool processes.

In accordance with our Noh/NIH doctrine, Phase 1 rejects the bloated dependency trees
of traditional Haskell web stacks (such as `aeson` pulling `scientific`,
`unordered-containers`, `dlist`, and `servant`). Instead, it adopts **row-native,
stream-directed codecs** where parsing decodes directly into `large-anon` vector slots
and porcupine-style `docrecords` metadata feeds runtime schema introspection.

---

## 0. The Five Pre-Implementation Closures

Before writing Phase 1 code, five architectural closures are formally settled:

### Closure 1: The Lean, Row-Native Codec Stance (The Anti-Aeson/Anti-Bloat Principle)
Standard Haskell JSON serialization (`aeson`) drags in transitive dependency weight:
- `Data.Scientific`: Necessary only when JSON numbers must be preserved without knowing
  their target type. In `sarutahiko`, row decoders are statically typed: field types
  (`Int64`, `Word32`, `Double`, `Text`) are known at the record slot. Numbers are parsed
  directly from byte slices into unboxed primitives with zero intermediate heap allocations.
- `Data.HashMap` (`unordered-containers`): Necessary only when objects are represented
  as dynamic key-value maps. In `sarutahiko`, records are `Record f r` backed by `large-anon`
  contiguous arrays indexed by compile-time offsets. Unknown fields are stored in a small,
  sorted vector within `WireEnvelope` (E4 anti-silent-loss guard). Hash maps and SipHash
  overhead are eliminated.
- **Server-Sent Events (SSE):** Implemented directly in `kogaki-wire` over the `yamaarashi`
  streaming kernel as a clean ~80 LOC newline-delimited framing engine (`event:`, `data:`,
  `id:`, `retry:`), eliminating any need for heavyweight web frameworks (`servant`, `wai`, `warp`).

---

### Closure 2: The Docrecords Introspection & Schema Mapping Engine
Drawing on Guillaume Bouchard’s **`porcupine`** design heritage, records in `sarutahiko`
serve as **`docrecords`** (`FIELDS_RECORDS_DESIGN.md` §3):
- Each field `Field (k :: Symbol) (a :: Type)` carries a `KnownField` dictionary with:
  1. Haddock documentation string (`fieldDoc`).
  2. Concrete JSON Schema subset descriptor (`fieldSchema`).
  3. Sensitivity and redaction classification (`fieldSensitivity` for Kagami-ita audit).
- **Introspection without Reflection:** When `sarutahiko-mcp` exposes tools via `tools/list`,
  it does not use runtime reflection or Template Haskell reification. The input record's
  `Row Type` is folded at compile-time/startup using `large-generics` into a strict
  JSON Schema object.
- **Reader-Soup Tool Context:** MCP tool handlers receive inputs as sub-row projections
  (`rcast`) from the active context record soup.

---

### Closure 3: Model Context Protocol (MCP 2025-03-26) State Machine
`sarutahiko-mcp` implements the pinned `2025-03-26` specification with dual-role capability:
1. **Server Role:** Exposes `tools/list` and `tools/call` over `stdio` or SSE to host
   clients (Hermes, Claude Code, Zed). Tool registration is implemented as an extensible
   record of handlers (`Record Identity ToolRow`).
2. **Client Role:** Dispatches tool requests to external MCP subprocesses spawned via
   `sarutahiko-process`.
3. **Capability Negotiation:** Client and server capabilities are represented as open rows
   (`Record Identity CapabilityRow`), allowing experimental vendor extensions (`_meta`,
   `experimental`) without schema breakage.

---

### Closure 4: The Resource-Bracketed Subprocess & Stdio Supervisor
MCP tool invocation requires executing external child processes (e.g. CLI tools, Python
scripts, SQLite servers). Phase 1 introduces `sarutahiko-process`:
- Exposes a minimal `Process` effect GADT:
  ```haskell
  data Process (m :: Type -> Type) :: Type -> Type where
    SpawnChild :: !ProcessConfig -> Process m (ChildHandle m)
    ReadStdout :: !(ChildHandle m) -> Process m (Stream (Of ByteString) m ())
    WriteStdin :: !(ChildHandle m) -> !ByteString -> Process m ()
    WaitChild  :: !(ChildHandle m) -> Process m ExitCode
    KillChild  :: !(ChildHandle m) -> !Signal -> Process m ()
  ```
- **Hermetic Resource Bracketing:** Every `ChildHandle` is acquired inside a `Resource` /
  `Scoped` region. If a turn times out or aborts, child processes receive `SIGTERM`,
  followed by a hard `SIGKILL` deadline, guaranteeing zero zombie processes.
- **Child Environment Hygiene:** Subprocesses run with scrubbed environments (`PATH`,
  `TERM`, `LANG=C.UTF-8` only); credentials and secrets are injected strictly via
  stdin pipes or explicit capability rows.

---

### Closure 5: Golden Wire Fixture & Interop Conformance
Phase 1 verification is anchored on the 6-step JSON-RPC wire trace fixed in
`test/fixtures/wire/mcp/hokora-turn.jsonl`:
1. `initialize` request $\rightarrow$ capability response.
2. `notifications/initialized`.
3. `tools/list` request $\rightarrow$ tool catalog response.
4. `tools/call` request (`echo` / `calc`) $\rightarrow$ result response.
5. Bidirectional ping/pong heartbeat.
6. Clean shutdown / `close`.

Both `sarutahiko-effect-effectful` and `sarutahiko-effect-polysemy` must execute this
sequence identically against external mock scripts and live Claude Code stdio.

---

## 1. The Hermetic Task Packets (Work Breakdown Structure)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          PHASE 1 TASK PACKETS                               │
├────────────┬─────────────────────────────┬──────────────────────────────────┤
│ Packet ID  │ Target Scope                │ Deliverables                     │
├────────────┼─────────────────────────────┼──────────────────────────────────┤
│ **TP-1.1** │ `kogaki-wire`               │ Zero-bloat JSON lexer & SSE      │
│            │                             │ streaming chunker                │
├────────────┼─────────────────────────────┼──────────────────────────────────┤
│ **TP-1.2** │ `sarutahiko-jsonrpc`        │ JSON-RPC 2.0 framing, dispatch,  │
│            │                             │ and error taxonomy               │
├────────────┼─────────────────────────────┼──────────────────────────────────┤
│ **TP-1.3** │ `sarutahiko-schema`         │ JSON Schema subset ⇄ large-anon  │
│            │                             │ row descriptor compiler          │
├────────────┼─────────────────────────────┼──────────────────────────────────┤
│ **TP-1.4** │ `sarutahiko-process`        │ Resource-bracketed stdio process │
│            │                             │ spawner and supervisor           │
├────────────┼─────────────────────────────┼──────────────────────────────────┤
│ **TP-1.5** │ `sarutahiko-mcp`            │ MCP 2025-03-26 server and client │
│            │                             │ protocol engine                  │
├────────────┼─────────────────────────────┼──────────────────────────────────┤
│ **TP-1.6** │ Phase 1 Wire Flagship CLI   │ Standalone `sarutahiko-mcp` CLI  │
│            │ & Interop Suite             │ & dual-effect conformance suite  │
└────────────┴─────────────────────────────┴──────────────────────────────────┘
```

---

### Task Packet TP-1.1: `kogaki-wire` — Zero-Bloat JSON Lexer & SSE Chunker
- **Target Scope:** Lean byte-level tokenization and SSE stream parsing without `scientific` or `unordered-containers`.
- **Dependencies:** `packages/kogaki-core`, `packages/sarutahiko-records`.
- **Exact Module Paths:**
  - `packages/kogaki-wire/src/Kogaki/Wire/Json/Lexer.hs`
  - `packages/kogaki-wire/src/Kogaki/Wire/Json/Decode.hs`
  - `packages/kogaki-wire/src/Kogaki/Wire/SSE/Parser.hs`
- **Core Types:**
  ```haskell
  data JsonToken
    = TkObjectOpen
    | TkObjectClose
    | TkArrayOpen
    | TkArrayClose
    | TkKey {-# UNPACK #-} !ByteString
    | TkString {-# UNPACK #-} !Text
    | TkInt {-# UNPACK #-} !Int64
    | TkDouble {-# UNPACK #-} !Double
    | TkBool !Bool
    | TkNull

  data SseEvent = SseEvent
    { sseId    :: !(Maybe Text)
    , sseEvent :: !(Maybe Text)
    , sseData  :: !ByteString
    , sseRetry :: !(Maybe Int)
    } deriving stock (Eq, Show)
  ```
- **Invariants & Laws:**
  1. *Zero Intermediate AST:* `decodeJsonRow` reads directly from `ByteString` chunks into unboxed field vectors without materializing an intermediate `Value` tree.
  2. *SSE Round-Trip Equivalence:* Unfolding an `SseEvent` to raw bytes and parsing it through `parseSseStream` yields the original event bit-identically.
- **Verification Commands:**
  ```bash
  cabal test sarutahiko-wire:test-kogaki-wire --test-options="-p /JsonLexer/"
  cabal test sarutahiko-wire:test-kogaki-wire --test-options="-p /SseRoundTrip/"
  ```

---

### Task Packet TP-1.2: `sarutahiko-jsonrpc` — Core Protocol Engine
- **Target Scope:** Spec-conformant JSON-RPC 2.0 framing, batching, error codes, and row-directed dispatch.
- **Dependencies:** `packages/kogaki-wire`, `packages/sarutahiko-records`.
- **Exact Module Paths:**
  - `packages/sarutahiko-jsonrpc/src/Sarutahiko/JsonRpc/Types.hs`
  - `packages/sarutahiko-jsonrpc/src/Sarutahiko/JsonRpc/Error.hs`
  - `packages/sarutahiko-jsonrpc/src/Sarutahiko/JsonRpc/Dispatch.hs`
- **Core Types:**
  ```haskell
  data JsonRpcId = IdInt !Int64 | IdString !Text | IdNull
    deriving stock (Eq, Ord, Show)

  data JsonRpcRequest r = JsonRpcRequest
    { reqId     :: !(Maybe JsonRpcId) -- Nothing = Notification
    , reqMethod :: !Text
    , reqParams :: !(Record Identity r)
    }

  data JsonRpcResponse r
    = JsonRpcSuccess !JsonRpcId !(Record Identity r)
    | JsonRpcFailure !(Maybe JsonRpcId) !JsonRpcError

  data JsonRpcError = JsonRpcError
    { errCode    :: !Int
    , errMessage :: !Text
    , errData    :: !(Maybe (WireEnvelope '[]))
    } deriving stock (Eq, Show)
  ```
- **Invariants & Laws:**
  1. *Standard Error Bounds:* Predefined JSON-RPC error codes strictly adhere to the specification: ParseError (-32700), InvalidRequest (-32600), MethodNotFound (-32601), InvalidParams (-32602), InternalError (-32603).
  2. *Notification Silence:* Notifications (`reqId = Nothing`) must never produce a response frame on the wire.
- **Verification Commands:**
  ```bash
  cabal test sarutahiko-jsonrpc:test-jsonrpc --test-options="-p /SpecConformance/"
  ```

---

### Task Packet TP-1.3: `sarutahiko-schema` — Row Descriptors ⇄ JSON Schema Compiler
- **Target Scope:** Bi-directional translation between `large-anon` row types and JSON Schema subset descriptors.
- **Dependencies:** `packages/sarutahiko-fields`, `packages/sarutahiko-records`.
- **Exact Module Paths:**
  - `packages/sarutahiko-schema/src/Sarutahiko/Schema/Types.hs`
  - `packages/sarutahiko-schema/src/Sarutahiko/Schema/Compile.hs`
  - `packages/sarutahiko-schema/src/Sarutahiko/Schema/Validate.hs`
- **Core Types:**
  ```haskell
  data SchemaNode
    = SchemaObject !(Map Text SchemaNode) ![Text] -- properties, required
    | SchemaString !(Maybe Text)                  -- format/pattern
    | SchemaInteger !(Maybe Int64) !(Maybe Int64) -- min, max
    | SchemaNumber
    | SchemaBoolean
    | SchemaArray !SchemaNode
    deriving stock (Eq, Show)

  class KnownRowSchema (r :: Row Type) where
    rowToSchema :: proxy r -> SchemaNode
  ```
- **Invariants & Laws:**
  1. *No Network Fetch:* Schemas compile strictly offline. Remote `$ref` resolution is rejected with `RemoteSchemaRefUnsupported`.
  2. *Docrecords Extraction:* Field docstrings (`fieldDoc`) are automatically populated into the schema's `"description"` attribute.
- **Verification Commands:**
  ```bash
  cabal test sarutahiko-schema:test-schema --test-options="-p /DocrecordsExtraction/"
  ```

---

### Task Packet TP-1.4: `sarutahiko-process` — Resource-Bracketed Subprocess Supervisor
- **Target Scope:** Safe child process lifecycle over piped stdio with deadline kills and clean environment scrubbing.
- **Dependencies:** `packages/sarutahiko-effect-signatures`, `packages/sarutahiko-effect-effectful`.
- **Exact Module Paths:**
  - `packages/sarutahiko-process/src/Sarutahiko/Process/Signature.hs`
  - `packages/sarutahiko-process/src/Sarutahiko/Process/Interpreter.hs`
- **Core Types:**
  ```haskell
  data ProcessConfig = ProcessConfig
    { cmdPath :: !FilePath
    , cmdArgs :: ![Text]
    , cmdEnv  :: ![(Text, Text)]
    , cmdCwd  :: !(Maybe FilePath)
    , timeout :: !NominalDiffTime
    } deriving stock (Eq, Show)
  ```
- **Invariants & Laws:**
  1. *Fail-Closed Termination:* If a process exceeds its deadline timeout or the parent `Eff es` computation aborts, `SIGTERM` is sent immediately. If not exited within 500ms, `SIGKILL` is issued. No zombies.
  2. *Environment Hygiene:* Host environment variables are scrubbed by default. Only an explicit allowlist passes to child processes.
- **Verification Commands:**
  ```bash
  cabal test sarutahiko-process:test-process --test-options="-p /DeadlineKill/"
  ```

---

### Task Packet TP-1.5: `sarutahiko-mcp` — MCP 2025-03-26 Protocol Engine
- **Target Scope:** Model Context Protocol implementation for both server (hosting tools) and client (invoking tools).
- **Dependencies:** `packages/sarutahiko-jsonrpc`, `packages/sarutahiko-schema`, `packages/sarutahiko-process`.
- **Exact Module Paths:**
  - `packages/sarutahiko-mcp/src/Sarutahiko/MCP/Types.hs`
  - `packages/sarutahiko-mcp/src/Sarutahiko/MCP/Server.hs`
  - `packages/sarutahiko-mcp/src/Sarutahiko/MCP/Client.hs`
  - `packages/sarutahiko-mcp/src/Sarutahiko/MCP/Capabilities.hs`
- **Core Types:**
  ```haskell
  data ToolDef = ToolDef
    { toolName        :: !Text
    , toolDescription :: !Text
    , toolInputSchema :: !SchemaNode
    } deriving stock (Eq, Show)

  data McpServerState = McpServerState
    { serverInitialized  :: !Bool
    , clientCapabilities :: !(WireEnvelope '[])
    , registeredTools    :: !(Map Text ToolHandler)
    }
  ```
- **Invariants & Laws:**
  1. *State Guard:* Any request other than `initialize` or `ping` received prior to `notifications/initialized` returns JSON-RPC error `-32600` (ServerNotInitialized).
  2. *Schema Enforcement:* Incoming `tools/call` arguments are validated against `toolInputSchema` before invoking the underlying Haskell handler.
- **Verification Commands:**
  ```bash
  cabal test sarutahiko-mcp:test-mcp --test-options="-p /StateGuard/"
  ```

---

### Task Packet TP-1.6: Phase 1 Wire Flagship CLI & Interop Suite
- **Target Scope:** The compiled executable `sarutahiko-mcp` and end-to-end conformance testing against Claude Code and Hermes.
- **Dependencies:** All Phase 0 and Phase 1 packages.
- **Exact Module Paths:**
  - `packages/sarutahiko-mcp/app/Main.hs`
  - `test/suites/wire/McpConformanceSpec.hs`
- **Execution Target:**
  The `sarutahiko-mcp` executable starts over `stdio`, registers default diagnostic tools (`echo`, `calc`, `env`), and satisfies the golden fixture trace `test/fixtures/wire/mcp/hokora-turn.jsonl`.
- **Dual-Interpreter Parity Gate:**
  The entire conformance suite runs green under both:
  - `sarutahiko-effect-effectful` (production loop)
  - `sarutahiko-effect-polysemy` (seam compatibility adapter)
- **Deterministic Verification Commands:**
  ```bash
  # 1. Run full golden wire fixture
  cabal run test-wire-conformance -- --fixture test/fixtures/wire/mcp/hokora-turn.jsonl

  # 2. Verify dual-effect interpreter parity
  cabal test test-wire-conformance --test-options="-p /EffectfulParity/"
  cabal test test-wire-conformance --test-options="-p /PolysemyParity/"

  # 3. Test stdio loop with mock client
  python3 test/scripts/mock_mcp_client.py --exec "cabal run sarutahiko-mcp"
  ```
