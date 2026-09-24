# The Hokora Spec (祠) — Phase 1.5 Vertical Validation Slice

Status: DRAFT v0.1 · 2026-09-24 (spec per NIH_PLAN backlog item 9)
Related: `NIH_PLAN.md` (Phase 1.5; §6 backlog), `MEMORY_ENGINE_DESIGN.md` (§3.1 spine v0.2,
§3.4 ordering contract, §3.4a SomeRow worked example, §5.1.4 PolicyEffect),
`EFFECT_CATALOG_DESIGN.md` (signatures, law testkit, mock interpreters),
`YAMAARASHI_DESIGN.md` (stdio framing, Resource effect), `HASHIGAKARI_DESIGN.md` (store),
`~/src/kuroko/` (the comparison baseline: ≈1k core / 1.9k incl. tests)

---

## 1. Purpose — a small shrine on the peak

The hokora (祠) is a small Shinto shrine: the roadside kind, not the mountain-top temple.
The name is precise for its role in the program's metaphor — designs flow down the
mountain, stone flows up, and the temple (the full agent ecosystem) is Phase 2+. The
hokora is a tiny shrine built on the peak early, to prove the peak is reachable.

Engineering term: a **walking skeleton** (tracer bullet) — the thinnest possible
end-to-end slice that touches *every layer for real*. Its reason to exist is the
walking-skeleton argument already recorded in the plan: substrate APIs designed in
isolation are always wrong in exactly the load-bearing places; the first real consumer
forces them to compose while reshaping them is still cheap.

## 2. One sentence

> A single executable, budgeted ≤2,000 lines of our code (substrate excluded, measured),
> that takes a one-shot CLI prompt, runs one interpreted ReAct turn — one model call, one
> MCP tool call through a real subprocess over a real stdio wire — appends every step to a
> real SQLite event log with the blessed envelope, folds one pure reducer over the log,
> and prints a summary.

## 3. The four jobs

1. **Composition proof.** Exercises the record foundation, the effect catalog with its
   `Resource`/`Scoped` semantics, yamaarashi's framing, and hashigakari's store *in one
   program*, so the seams get fixed at kilometer 2 rather than kilometer 8.
2. **The thesis measurement.** Kuroko delivered agent capability in ≈1k core lines on
   vinyl/persistent, with no wire conformance and a TH-bound store. The hokora delivers
   the same class of capability on our substrate *with* a conformance-tested MCP transport
   and a real event-sourced log. Near budget ⇒ the first datum for the answer-to-Nadeem
   thesis. ≈3× over budget ⇒ an even more valuable datum: the substrate has a problem,
   discovered while it is still cheap to fix.
3. **Catalog stress test.** Every signature it touches — `Process`, `Log`, `ModelAPI`,
   `SessionStore`, `Terminal`, `Resource` — gets a real consumer before Phase 2 hardens
   the catalog. A signature shape that resists its first real user is reshaped now.
4. **Instruments seed.** Its single session is the first input to the §8 metrics pipeline
   (`MEMORY_ENGINE_DESIGN.md`): prefix-hash cache data, event streams for the policy
   harness. Instrumentation from day one.

## 4. The walkthrough — one invocation, layer by layer

Run `hokora "summarize this file"`. Everything that happens, and which blessed design
each step exercises:

1. **CLI (one-shot only).** Parse the prompt argument; no REPL, no session resume.
   *Exercises:* the thinnest edge of config; nothing more.
2. **Turn program (the interpreted ReAct loop).** The *one* piece Phase 2 later
   generalizes. For the hokora: at most one model call, at most one tool call, final
   response — written in `Eff es` against catalog signatures only, no concrete effect
   system named. *Exercises:* the turn-as-value principle; the dual-interface contract —
   the executable runs under effectful; the test suite additionally runs the *same turn
   program* under the polysemy interpreters (the cheapest real proof of the dual-interface
   claim that exists).
3. **`ModelAPI`.** One streaming completion. Real provider for the live run; the catalog's
   **mock model interpreter** for tests — the sanctioned kind of mock, because the mock is
   itself a catalog interpreter obeying the same laws, not a skipped layer.
4. **Tools via MCP subprocess.** The deliberate hard part: the tool lives in a *separate
   process* speaking MCP over stdio — real JSON-RPC framing through yamaarashi, session
   states in the distilled typed-protocols pattern (initialize handshake, tools/call).
   An in-process fake tool exists for unit tests only; the slice's *point* is the real
   subprocess path. *Exercises:* `Process` spawn + Resource-bracketed teardown, yamaarashi
   framing, the session GADT, `Tools` dispatch.
5. **Session log (hashigakari-sqlite).** Every step appends events with the blessed spine
   (§5 below for exact rows): `(kind, schemaV)` in spine columns, payloads as `SomePayload`
   via the witness registry, `(session, seq)` cursors per the ordering contract,
   single-writer. *Exercises:* MEMORY_ENGINE_DESIGN §3.1, §3.4, §3.4a in the first program
   that uses them.
6. **Reducer + summary.** One pure fold — the conversation-tail reducer in miniature —
   walks the session's events; the executable prints event count, token accounting, and
   the final message. *Exercises:* the SomeRow read path, fail-closed filtering, and the
   replay property (delete derived state, replay, identical summary).

## 5. The exact event rows

Spine per MEMORY_ENGINE_DESIGN §3.1 v0.2 (seq, eventId, kind, schemaV, ts, session, actor,
cause, payload; laws T/A/X in force). The hokora declares exactly these payloads in its
witness registry (§3.4a pattern):

| Event | `(kind, schemaV)` | Payload row | Written by |
|---|---|---|---|
| `SessionOpened` | `("session_opened", 1)` | `'[ "model" ':= Text, "cwd" ':= FilePath ]` | startup |
| `MessageAppended` | `("message", 1)` | `'[ "role" ':= Role, "content" ':= Text ]` | turn program (user + assistant) |
| `ToolInvoked` | `("tool_invoked", 1)` | `'[ "name" ':= Text, "args" ':= SomePayload-tagged row ]` | turn program |
| `ToolObserved` | `("tool_observed", 1)` | `'[ "callId" ':= UUID, "output" ':= Text, "ok" ':= Bool ]` | turn program |
| `SessionClosed` | `("session_closed", 1)` | `'[ "reason" ':= Text ]` | shutdown (normal or Resource-finalized) |

Rules binding here: `cause` links `ToolObserved` → its `ToolInvoked`; the assistant
`MessageAppended` after a tool observation carries `cause` → `ToolObserved` (the causal
tree of §3.1); `ts` is informational (law T); `actor` is stored as text with total-parse
reading (law A). No `ContextCompressed`, no pinning events — policy is out of scope; the
registry is code, so Phase 2 extends it by replay (never migration).

## 6. The turn-program skeleton

```haskell
-- policy-free, surface-free, effect-system-free: the whole program
hokoraTurn :: ∀ es. (ModelAPI :<: es, Tools :<: es, SessionStore :<: es,
                    Log :<: es, Resource :<: es)
           => Text -> Eff es Text
hokoraTurn prompt = do
  sid  <- openSession                          -- SessionOpened
  appendUserMessage sid prompt                 -- MessageAppended (user)
  reply0 <- completeStream sid                 -- ModelAPI (≤1 call)
  case wantTool reply0 of                      -- at most ONE tool call
    Nothing -> pure reply0
    Just (name, args) -> do
      cid    <- invokeTool sid name args       -- ToolInvoked
      obs    <- awaitObservation cid           -- ToolObserved
      reply1 <- completeWithObservation sid obs
      closeSession sid "done"                  -- SessionClosed
      pure reply1
```

Executable = `runEffectful (Resource-bracketed … (hokoraTurn prompt))` printed to stdout.
Test suite = the *same* `hokoraTurn` under the polysemy interpreters with the mock model —
the dual-interface proof. The turn program never names an effect system, a transport, or a
store; that is the whole point of it.

## 7. Exclusions — and the mock/skip distinction

- No REPL/TUI/gateway (surfaces are Phase-3 projections); no hooks, approvals, grants
  beyond the trivial; **no compression/salience/retrieval policy** — the log *schema* is
  exercised, the policy is not (the hokora writes events; it never mutates context); no
  conformance machinery beyond the property tests the substrate already ships.
- The honesty rule: **mocking a dependency ≠ skipping a layer.** Mock model = allowed (a
  catalog interpreter). In-process fake tool = unit tests only (the real subprocess path
  must run). A fake SQLite store = forbidden (the store *is* the exercise).

## 8. The LOC measurement protocol

- **Counted in:** the executable plus its hokora-local modules (event rows, witness
  registry, turn program, reducer, main) — the shrine.
- **Counted out:** all substrate packages (fields, records, effect-signatures, bridges,
  yamaarashi family, hashigakari family) — the mountain.
- **Two numbers:** hokora-core and hokora-test reported separately (tests are maintenance
  burden too, but the kuroko comparison is cleaner core-to-core; kuroko's ≈1k/1.9k split
  maps onto this).
- **Method:** mechanical line count, stated once in the ledger (no comment-stripping
  debates), applied **identically to kuroko** — which is recounted under the same protocol
  — and both recorded in the benchmark ledger at the Phase-1.5 exit commit.
- **What the number claims:** "agent capability through every layer costs X lines when the
  substrate deletes the boilerplate." What it does *not* claim: that the whole ecosystem is
  small.

## 9. Exit criteria (Phase 1.5 done when)

1. The executable runs end-to-end: real MCP subprocess + real SQLite + live model.
2. The same turn program passes its test suite under **both** effect-system interpreters.
3. LOC ≤ budget; both hokora and kuroko numbers recorded in the ledger.
4. Replay property: derived state deleted → replay → byte-identical summary.
5. The session yields the §8 metrics seed (prefix hashes, event stream export).

## 10. What graduates vs what is scaffolding

- **Graduates into Phase 2:** the event rows and witness registry, the turn-program shape,
  the tail reducer, the LOC protocol, the metrics seed — the shrine's content.
- **Scaffolding:** the one-shot CLI shell, which becomes the first room of the temple
  (`sarutahiko`'s one-shot mode) rather than being discarded.
