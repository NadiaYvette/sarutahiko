# The Attribution Register — Conceptual Lineage and Multi-Licensing Audit

Status: LIVING · v0.1 · 2026-10-04  
Related: [NOTICE.md](../../NOTICE.md), [CREDITS.md](../../CREDITS.md), [REUSE_REGISTER.md](REUSE_REGISTER.md), `NIH_PLAN.md`  
Purpose: A comprehensive, standing record of every conceptual derivation, intellectual ancestor,
re-expressed algorithm, and third-party license across all packages in the Sarutahiko repository.

---

## 1. Operating Doctrine

Per `docs/notes/DOC_STRATEGY.md` §9 and the maintainer's standing policy:
- **Intellectual credit is granted by choice, not mere legal obligation.**
- Even where clean-room re-implementation, complete syntactic rewriting, or the absence
  of direct patch deltas removes legal copyleft requirements, this repository treats the
  synthesis, adaptation, and re-expression of conceptual architectures as genuine
  intellectual derivations.
- All derived packages carry explicit acknowledgment in their `.cabal` files, module Haddock
  headers, and pointers to [NOTICE.md](../../NOTICE.md).
- Upstream license texts and Apache-2.0 §4(d) notices are preserved intact under `LICENSES/`.

---

## 2. Package Provenance and Derivation Matrix

| Package | Ancestral Projects & Thinkers | Upstream Licenses | Upstream URLs / References | Derivation & Re-Expression Nature |
|---|---|---|---|---|
| `packages/yamaarashi/yamaarashi` | `streaming` (Michael Thompson), `streamly` (Harendra Kumar), `conduit` (Michael Snoyman) | BSD-3-Clause, Apache-2.0, MIT | [streaming](https://hackage.haskell.org/package/streaming), [streamly](https://streamly.composewell.com/), [conduit](https://github.com/snoyberg/conduit) | Church-encoded CPS free monad streaming kernel (`Stream (Of a) m r`) with bracketed resource cleanup and concurrency strategies. |
| `packages/yamaarashi/yamaarashi-conduit` | `conduit` (Michael Snoyman) | MIT | [conduit](https://github.com/snoyberg/conduit) | Bidirectional bridge between `Stepper` / `Stream` and `ConduitT` with bracketed finalization. |
| `packages/yamaarashi/yamaarashi-streamly` | `streamly` (Harendra Kumar) | Apache-2.0 / BSD-3-Clause | [streamly](https://streamly.composewell.com/) | High-performance in-process streaming backend converting between `SerialT` and `Stepper`. |
| `packages/yamaarashi/yamaarashi-flow` | `porcupine` / `kernmantle` (Yves Parès), `funflow` (Tom Nielsen), `selective` (Andrey Mokhov), `alga` (Andrey Mokhov), `typed-process` (Michael Snoyman) | MIT, BSD-3-Clause | [porcupine](https://github.com/tweag/porcupine), [funflow](https://github.com/tweag/funflow), [selective](https://github.com/snowleopard/selective), [alga](https://github.com/snowleopard/alga) | Free Selective Applicative Functors over algebraic graph DAGs with content caching, superseding ArrowFlow. Subprocess supervision via `typed-process`. |
| `packages/yamaarashi/yamaarashi-spec` | `recursion-schemes` (Edward Kmett), `selective` (Andrey Mokhov) | BSD-3-Clause | [recursion-schemes](https://github.com/ekmett/recursion-schemes), [selective](https://github.com/snowleopard/selective) | Fixed-point recursive subdivision (`ana`, `hylo`) of macroscopic goals into atomic task packets. |
| `packages/kogaki/kogaki-core` | `text` (Bryan O'Sullivan), `aeson` (Bryan O'Sullivan et al.) | BSD-2-Clause, BSD-3-Clause | [text](https://github.com/haskell/text), [aeson](https://github.com/haskell/aeson) | Dependency-light zero-copy UTF-8 text slicing, RFC 8259 validation, string unescaping. |
| `packages/kogaki/kogaki-wire` | `aeson` (Bryan O'Sullivan et al.), `attoparsec` (Bryan O'Sullivan), `wai-extra` (Michael Snoyman), `mono-traversable` (Michael Snoyman) | BSD-3-Clause, MIT | [aeson](https://github.com/haskell/aeson), [attoparsec](https://github.com/haskell/attoparsec), [wai](https://github.com/yesodweb/wai), [mono-traversable](https://github.com/snoyberg/mono-traversable) | Zero-Aeson streaming wire lexer, byte scanning, SSE chunk framing (`wai-extra`), and `NonNull` buffer invariants. |
| `packages/hashigakari/hashigakari-sqlite` | `direct-sqlite` (Irene Knittel, Jan Snajder), `hasql` (Nikita Volkov), `beam` (Travis Whitaker), SQLite | BSD-3-Clause, MIT, Apache-2.0, Public Domain (Blessing) | [direct-sqlite](https://hackage.haskell.org/package/direct-sqlite), [hasql](https://github.com/nikita-volkov/hasql), [beam](https://github.com/haskell-beam/beam) | Existential SQLite stepper wrapping `sqlite3_step`, applicative row decoding directly into `Record Identity r`, append-only event store, and atomic task leases. |
| `packages/sarutahiko/sarutahiko-fields` | `large-records` / `large-anon` (Edsko de Vries), `vinyl` (Anthony Cowley), `docrecords` (Yves Parès) | BSD-3-Clause, MIT | [large-records](https://github.com/well-typed/large-records), [vinyl](https://github.com/acowley/vinyl) | Shared singleton field definitions (`Field`) across JSON-RPC, MCP, hooks, sessions, and databases. |
| `packages/sarutahiko/sarutahiko-records` | `large-anon` (Edsko de Vries), `record-soup` (Yves Parès), RFC 7396 | BSD-3-Clause, MIT | [large-records](https://github.com/well-typed/large-records), [record-soup](https://hackage.haskell.org/package/record-soup) | Wide record projection (`rcast`), row extension/restriction, and TriState HKD merge patch semantics. |
| `packages/sarutahiko/sarutahiko-effect-signatures` | *Data Types à la Carte* (Wouter Swierstra), `effectful`, `polysemy` | BSD-3-Clause | ICFP 2008 Swierstra paper, [effectful](https://github.com/haskell-effectful/effectful), [polysemy](https://github.com/polysemy-research/polysemy) | Runtime-neutral effect signature GADTs (`KV`, `FileSystem`, `Clock`, `Log`, `Subprocess`, `ProcessLifecycle`, `Resource`). |
| `packages/sarutahiko/sarutahiko-effect-effectful` | `effectful` (Ertugrul Söylemez, Dominik Peteler) | BSD-3-Clause | [effectful](https://github.com/haskell-effectful/effectful) | Fast unlifted state/reader interpreters with handlers-as-records dynamic dispatch optimization. |
| `packages/sarutahiko/sarutahiko-effect-polysemy` | `polysemy` (Sandy Maguire) | BSD-3-Clause | [polysemy](https://github.com/polysemy-research/polysemy) | First-class higher-order effect interpreters for downstream Polysemy compatibility. |
| `packages/sarutahiko/sarutahiko-effect-testkit` | In-memory mock carriers | BSD-3-Clause | — | Deterministic pure STM carriers for zero-IO testing of effect signatures. |
| `packages/sarutahiko/sarutahiko-process` | `typed-process` (Michael Snoyman) | MIT | [typed-process](https://github.com/snoyberg/typed-process) | Strongly typed subprocess execution and stream management under algebraic effects. |
| `packages/sarutahiko/sarutahiko-jsonrpc` | JSON-RPC 2.0 (Working Group), `haskell-lsp` (Alan Zimmerman), `mono-traversable` (Michael Snoyman) | MIT | [JSON-RPC 2.0](https://www.jsonrpc.org/specification), [lsp](https://github.com/haskell/lsp) | Row-typed JSON-RPC 2.0 protocol core where envelopes are extensible records over `sarutahiko-fields`. |
| `packages/sarutahiko/sarutahiko-schema` | JSON Schema draft-07 / 2020-12, Hermes schema layer (Nous Research) | MIT, Apache-2.0 | [JSON Schema](https://json-schema.org/), [hermes-agent](https://hermes-agent.nousresearch.com/) | Lightweight schema subset translator between MCP `inputSchema` and row descriptors without remote fetches. |
| `packages/sarutahiko/sarutahiko-mcp` | Model Context Protocol (Anthropic), `typed-protocols` (IOHK), Hermes MCP tools (Nous Research) | MIT, Apache-2.0 | [MCP Spec](https://modelcontextprotocol.io/), [typed-protocols](https://github.com/input-output-hk/typed-protocols) | Full MCP server and client implementation over row types and agency-indexed session states. |
| `packages/sarutahiko/sarutahiko-session` | Hermes Agent session persistence (Nous Research), `shikumi` (Nadeem Bitar), `keiki` (Nadeem Bitar) | MIT, Apache-2.0, BSD-3-Clause | [hermes-agent](https://hermes-agent.nousresearch.com/), [shikumi](https://github.com/nadeemb/shikumi) | Conversation persistence (`utaibon`), prompt-cache prefix preservation, and token window compaction. |
| `packages/sarutahiko/sarutahiko-hooks` | Hermes Agent shell hooks (Nous Research), `typed-process` (Michael Snoyman) | MIT, Apache-2.0 | [hermes-agent](https://hermes-agent.nousresearch.com/) | Subprocess hook supervisor with fail-closed `sigKILL` hard deadlines, consent checking, and JSON pipes. |
| `packages/sarutahiko/sarutahiko-plugins` | Hermes Agent plugin loader (Nous Research) | MIT, Apache-2.0 | [hermes-agent](https://hermes-agent.nousresearch.com/) | Dynamic plugin discovery, capability grants, and tool/hook registration as record effects. |
| `packages/sarutahiko/sarutahiko-agent` | Hermes Agent turn loop (Nous Research), ReAct (Yao et al.), Keiro (Nadeem Bitar) | MIT, Apache-2.0 | [hermes-agent](https://hermes-agent.nousresearch.com/) | Autonomous turn loop, bounded ReAct cognitive stepping, hook supervisors, and CLI executable `sarutahiko`. |
| `packages/sarutahiko/sarutahiko-tui` | `brick` & `vty` (Jonathan Daugherty), Hermes Agent TUI (Nous Research), Kuroko (Nadeem Bitar) | BSD-3-Clause, MIT | [brick](https://github.com/jtdaugherty/brick), [hermes-agent](https://hermes-agent.nousresearch.com/) | Terminal UI with extensible record session state, streaming token rendering, and JSON-RPC communication. |
| `packages/sarutahiko/sarutahiko-gateway` | Kuroko / Keiro (Nadeem Bitar), `conduit` (Michael Snoyman) | BSD-3-Clause, MIT | [keiro](https://github.com/nadeemb/keiro), [conduit](https://github.com/snoyberg/conduit) | Multi-platform chat gateway (Telegram, Discord, Slack, Webhook) via `GatewayEffect` and bracketed conduit streams. |
| `packages/sarutahiko/sarutahiko-acp` | Agent Client Protocol (Zed Industries), Model Context Protocol (Anthropic), Hermes Agent (Nous Research) | Apache-2.0, MIT | [acp](https://github.com/zed-industries/zed) | Agent Client Protocol stdio adapter forwarding requests to agent core for editor integration. |
| `packages/sarutahiko/sarutahiko-tags` | Universal Ctags (Darren Hiebert, Masatake Yamato), `smirk` (Nadia Yvette Chambers) | GPL-2.0 / BSD-3-Clause | [universal-ctags](https://ctags.io/) | Scope-stack tag extractor emitting ctags tab-delimited and Universal Ctags JSON Lines. |
| `packages/utai/utai` | `baikai` (Nadeem Bitar), OpenAI & Anthropic wire protocols | BSD-3-Clause, MIT | [baikai](https://github.com/nadeemb/baikai) | Pure model substrate (*vox calculi*), zero-token OpenAI-compatible codecs, SSE folding, and laws L1–L4. |
| `packages/hashigakari/hashigakari-core` | `beam` (Travis Whitaker), `rel8` (Ollie Charles), `hasql` (Nikita Volkov), RFC 7396 (Mark Nottingham) | BSD-3-Clause, Apache-2.0 | [beam](https://github.com/haskell-beam/beam), [rel8](https://github.com/circuithub/rel8), [hasql](https://github.com/nikita-volkov/hasql) | Row-typed relational query AST (`Select`, `Projection`, `Where`, `Join`, `OrderBy`, `Limit`, `Offset`) parameterized by extensible schema rows, with RFC 7396 TriState patch algebra for minimal field updates. |
| `packages/hashigakari/hashigakari-syntax` | SQL-92 / SQL-99 standards, `beam` (Travis Whitaker), PostgreSQL, SQLite, MySQL | BSD-3-Clause, Apache-2.0, GPL-2.0 / LGPL-2.1 | [beam](https://github.com/haskell-beam/beam), [postgresql](https://www.postgresql.org/), [sqlite](https://sqlite.org/) | Dialect-indexed SQL query and patch compilation with type-level capability ceilings (`Supports` type family for dialect feature verification). |
| `packages/hashigakari/hashigakari-hasql` | `hasql` (Nikita Volkov), `hasql-pool` (Nikita Volkov), `postgresql-libpq` | MIT, BSD-3-Clause | [hasql](https://github.com/nikita-volkov/hasql), [postgresql-libpq](https://hackage.haskell.org/package/postgresql-libpq) | Scaled multi-worker PostgreSQL streaming backend via existential `Stepper IO (Record Identity r)`, bracketed connection pool leases, `HasqlEffect` GADT, and `MonadHasql` capability class. |
| `packages/sarutahiko/sarutahiko-format-dhall` | `dhall` (Gabriel Gonzalez) | BSD-3-Clause | [dhall-lang](https://github.com/dhall-lang/dhall-haskell) | Total, dependency-light Dhall record parser and evaluator bridging typed Dhall records directly into `large-anon` rows (`evalDhallRow`) without rewriting upstream evaluators or importing `aeson`. |
| `packages/hokora/hokora` | Keiro / Kiroku / Keiki (Nadeem Bitar), SQLite | BSD-3-Clause, Public Domain | [keiro](https://github.com/nadeemb/keiro) | Skinny vertical slice proving SQLite event store, session hydration, and autonomous single turn. |
| `packages/spikes/handlers-as-records` | Handlers-as-Records hypothesis, `large-anon`, `effectful`, `polysemy` | BSD-3-Clause | `EFFECT_CATALOG_DESIGN.md` | Empirical spike demonstrating that extensible record handler dispatch outperforms GADT dispatch. |

---

## 3. License Text and Notice Index

- **BSD-3-Clause:** [LICENSES/BSD-3-Clause.txt](../../LICENSES/BSD-3-Clause.txt)
- **BSD-2-Clause:** [LICENSES/BSD-2-Clause.txt](../../LICENSES/BSD-2-Clause.txt)
- **MIT:** [LICENSES/MIT.txt](../../LICENSES/MIT.txt)
- **Apache-2.0:** [LICENSES/Apache-2.0.txt](../../LICENSES/Apache-2.0.txt)
- **AGPL-3.0:** [LICENSES/AGPL-3.0.txt](../../LICENSES/AGPL-3.0.txt)
- **SQLite Blessing:** [LICENSES/SQLite-Blessing.txt](../../LICENSES/SQLite-Blessing.txt)
- **Streamly Notice:** [LICENSES/NOTICE-streamly.txt](../../LICENSES/NOTICE-streamly.txt)
- **Beam Notice:** [LICENSES/NOTICE-beam.txt](../../LICENSES/NOTICE-beam.txt)
- **Hermes Notice:** [LICENSES/NOTICE-hermes.txt](../../LICENSES/NOTICE-hermes.txt)
