# Licensing and Reuse Provenance — Sarutahiko Ecosystem

Sarutahiko is licensed under the **BSD-3-Clause** license. Original contributions
and architectural syntheses are Copyright (c) 2026, Nadia Yvette Chambers.
See [LICENSE](LICENSE) and [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).

---

## 1. The Derivation & Attribution Principle

Sarutahiko embodies a foundational design philosophy: **rebuilding the software
substrate for AI assistance on row-typed extensible records, algebraic effect
systems, and element streaming pipelines.**

In doing so, this codebase frequently adopts the stance:
> *"Build something like X, but using row-typed extensible records (`large-anon`),
> algebraic effect systems (`effectful` / `polysemy`), and streaming kernels (`yamaarashi`)."*

Per `docs/notes/DOC_STRATEGY.md` §9 and the maintainer's explicit doctrine:
**intellectual derivation credit is granted by deliberate choice, not merely where
statutory copyright laws or license obligations compel it.**

Even where clean-room re-implementation, complete syntactic rewriting, or the absence
of direct patch deltas removes legal copyleft requirements, this repository treats the
synthesis, adaptation, and re-expression of conceptual architectures as genuine
intellectual derivations. Ideas, state-machine designs, streaming semantics, and protocol
patterns re-expressed under algebraic effects and extensible records maintain an unbroken
provenance link to the thinkers and projects that forged them.

Third-party ancestral projects, conceptual donors, and component licenses are detailed
below. Retained upstream licenses and notices are cataloged in the `LICENSES/` directory.

---

## 2. Genealogy & Ancestral Attribution by Subsystem

### 2.1 Streaming Kernel & Concurrency (`yamaarashi`, `yamaarashi-conduit`, `yamaarashi-streamly`)

- **Streamly** (Composewell Technologies, Harendra Kumar; Apache-2.0 / BSD-3-Clause)
  - *Ancestral Role:* Streamly's step-fusion streaming model, sequential stream pipelines,
    and monadic concurrency strategies informed the core abstraction of `yamaarashi`.
    The `yamaarashi-streamly` package provides high-throughput in-process streaming adapters.
  - *Retained Notice:* See [LICENSES/NOTICE-streamly.txt](LICENSES/NOTICE-streamly.txt)
    and [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).
- **Conduit** (Michael Snoyman / FP Complete; MIT)
  - *Ancestral Role:* Conduit's bracketed deterministic resource management (`ResourceT`,
    safe finalization) and push/pull stream operators inspired `yamaarashi`'s bracketed
    cleanup and the bidirectional bridge in `yamaarashi-conduit`.
  - *Terms:* [LICENSES/MIT.txt](LICENSES/MIT.txt).
- **Streaming** (Michael Thompson; BSD-3-Clause)
  - *Ancestral Role:* The CPS Church-encoded free-monad transformer pattern
    (`Stream (Of a) m r`) directly informed `Yamaarashi.Stream`.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).

### 2.2 Workflows, Task Graphs & Subprocesses (`yamaarashi-flow`, `yamaarashi-spec`)

- **Porcupine, Kernmantle & Docrecords** (Yves Parès, Faura et al.; MIT)
  - *Ancestral Role:* Porcupine's pipeline task arrows, cached computation semantics,
    and virtual tree resource sandboxing provided the original functional blueprint for
    task pipelines. In `yamaarashi-flow`, the arrow-based architecture was superseded by
    Selective Applicative Functors to resolve `OverloadedLabels` record syntax collisions
    while preserving Porcupine's resource-caching semantics.
  - *Terms:* [LICENSES/MIT.txt](LICENSES/MIT.txt).
- **Funflow** (Tom Nielsen, Andreas Herrmann / Tweag I/O; MIT)
  - *Ancestral Role:* Functional workflow execution graphs and content-addressed task
    caching concepts informed the task packet execution design.
  - *Terms:* [LICENSES/MIT.txt](LICENSES/MIT.txt).
- **Selective Applicative Functors** (Andrey Mokhov, Georgy Lukyanov, Simon Marlow, Jeremie Dimino; BSD-3-Clause)
  - *Ancestral Role:* The `selective` library provides the core algebraic foundation for
    `yamaarashi-flow` and `yamaarashi-spec`. Static dependency over-approximation
    (`Control.Selective.Over`) computes `VirtualTree` sandbox requirements prior to execution,
    while conditional combinators (`branch`, `ifS`) govern runtime flow without opaque arrow desugaring.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).
- **Algebraic Graphs (`algebraic-graphs` / `alga`)** (Andrey Mokhov; MIT)
  - *Ancestral Role:* Alga's algebraic graph algebra (`Empty`, `Vertex`, `Overlay`, `Connect`)
    and constructive cycle verification form the workflow graph DAG representation in
    `yamaarashi-flow`, executing under *Build Systems à la Carte* scheduling principles.
  - *Terms:* [LICENSES/MIT.txt](LICENSES/MIT.txt).
- **Recursion Schemes** (Edward Kmett, Eric Mertens; BSD-3-Clause)
  - *Ancestral Role:* Fixed-point recursion combinators (`ana`, `cata`, `hylo`) power the
    task subdivision engine in `yamaarashi-spec`, recursively decomposing macroscopic goals
    into atomic leaf task packets.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).
- **Typed-Process** (Michael Snoyman; MIT)
  - *Ancestral Role:* Strongly-typed subprocess invocation, stream piping, and safe exit code
    handling govern external toolchain execution (`yamaarashi-exec`, `sarutahiko-process`).
  - *Terms:* [LICENSES/MIT.txt](LICENSES/MIT.txt).

### 2.3 Wire Protocols, Parsing & Lexing (`kogaki-core`, `kogaki-wire`, `sarutahiko-jsonrpc`, `sarutahiko-mcp`, `sarutahiko-schema`)

- **Aeson & Attoparsec** (Bryan O'Sullivan et al.; BSD-3-Clause)
  - *Ancestral Role:* While Sarutahiko strictly rejects Aeson's nominal intermediate ASTs
    and heap allocations (the Zero-Aeson doctrine), `kogaki-wire` adopts and re-expresses
    Aeson's and Attoparsec's fast byte-level scanning, whitespace skipping, SIMD alignment,
    and number parsing techniques, streaming parsed tokens directly into `large-anon` records.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).
- **WAI-Extra SSE Parser** (Michael Snoyman; MIT)
  - *Ancestral Role:* The Server-Sent Events line framing parser in `Kogaki.Wire.SSE.Parser`
    adapts the efficient chunk-slicing and field-dispatch logic (`event:`, `data:`, `id:`)
    from `Network.Wai.EventSource`.
  - *Terms:* [LICENSES/MIT.txt](LICENSES/MIT.txt).
- **Mono-Traversable** (Michael Snoyman; MIT)
  - *Ancestral Role:* `Data.NonNull.NonNull` guarantees type-level non-emptiness across
    wire buffers, JSON-RPC batch envelopes (`sarutahiko-jsonrpc`), and tool parameter payloads,
    eliminating partial functions and runtime zero-length errors.
  - *Terms:* [LICENSES/MIT.txt](LICENSES/MIT.txt).
- **Typed-Protocols** (Alexander Vieth, Duncan Coutts, Neil Davies et al. / IOHK; Apache-2.0)
  - *Ancestral Role:* Agency-indexed session types (`ClientAgency`, `ServerAgency`) and
    peer GADTs in `sarutahiko-mcp` distill the state machine patterns of `typed-protocols`.
  - *Terms:* [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).
- **Model Context Protocol (MCP)** (Anthropic; MIT)
  - *Ancestral Role:* The MCP specification (`2025-03-26` / `2024-11-05`) defines the wire schema
    for client/server capability negotiation, tool listing, and tool execution implemented
    by `sarutahiko-mcp`.
  - *Terms:* [LICENSES/MIT.txt](LICENSES/MIT.txt).

### 2.4 Extensible Records & Shared Fields (`sarutahiko-fields`, `sarutahiko-records`, `large-records` ecosystem)

- **Large-Records, Large-Anon & Large-Generics** (Edsko de Vries / Well-Typed; BSD-3-Clause)
  - *Ancestral Role:* The extensible record foundation of the entire repository. Sarutahiko
    uses a maintained fork (`NadiaYvette/large-records`, tag `v0.4.0-nadia`) providing $O(1)$
    compile-time wide records, anonymous record rows (`Record f r`), and `typelet` indexing.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).
- **Vinyl** (Anthony Cowley; BSD-3-Clause)
  - *Ancestral Role:* Universe-polymorphic field tagging and row lenses provided early
    architectural inspiration for `sarutahiko-fields` and interoperability shims.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).
- **Record-Soup & RFC 7396 JSON Merge Patch** (Yves Parès; MIT)
  - *Ancestral Role:* TriState HKD semantics (`Keep`, `Replace a`, `Delete`) in
    `sarutahiko-records` synthesize record-soup row operations with RFC 7396 merge patches.
  - *Terms:* [LICENSES/MIT.txt](LICENSES/MIT.txt).

### 2.5 Relational Databases & Event Sourcing (`hashigakari-core`, `hashigakari-syntax`, `hashigakari-hasql`, `hashigakari-sqlite`, `hashigakari-beam`)

- **Direct-SQLite** (Irene Knittel, Jan Snajder; BSD-3-Clause) & **SQLite** (Public Domain / Blessing)
  - *Ancestral Role:* Low-level C FFI statement preparation and stepping mechanics wrap
    `sqlite3_step` into an existential row stepper `Stepper (Eff es) a`.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt) and
    [LICENSES/SQLite-Blessing.txt](LICENSES/SQLite-Blessing.txt).
- **Hasql** (Nikita Volkov; MIT)
  - *Ancestral Role:* Hasql's explicit applicative row encoders and decoders (avoiding
    typeclass-directed magic) represent the golden standard of database access in Haskell,
    directly inspiring Hashigakari's row-decoding design, connection pool management, and
    existential stepper query streams in `hashigakari-hasql`.
  - *Terms:* [LICENSES/MIT.txt](LICENSES/MIT.txt).
- **Beam** (Travis Whitaker; Apache-2.0) & **Rel8** (Ollie Charles; BSD-3-Clause)
  - *Ancestral Role:* Statically typed schema and table combinators informed the design of
    `beam-large-anon` and Hashigakari's relational query AST (`Select`, `Projection`, `Join`,
    `Where`, `Filter`) and dialect-indexed SQL compilers (`hashigakari-core`, `hashigakari-syntax`).
  - *Retained Notice:* See [LICENSES/NOTICE-beam.txt](LICENSES/NOTICE-beam.txt) and
    [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).

### 2.6 Algebraic Effect Systems (`sarutahiko-effect-*`)

- **Effectful** (Ertugrul Söylemez, Dominik Peteler; BSD-3-Clause)
  - *Ancestral Role:* High-performance, unlifted state/reader effect runtime used for all
    executable binaries and primary production interpreters.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).
- **Polysemy** (Sandy Maguire; BSD-3-Clause)
  - *Ancestral Role:* Higher-order effect framework used to fulfill Sarutahiko's dual-interpreter
    parity requirement, ensuring all libraries export both `effectful` and `polysemy` interpreters.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).
- **Effect Signature Pattern / Data Types à la Carte** (Wouter Swierstra, Nicolas Wu, Tom Schrijvers, Ralf Hinze)
  - *Ancestral Role:* Separation of effect syntax (defunctionalized GADTs in
    `sarutahiko-effect-signatures`) from operational interpreters.

### 2.7 Autonomous Agent Core (`sarutahiko-agent`, `sarutahiko-session`, `sarutahiko-hooks`, `sarutahiko-plugins`)

- **Hermes Agent** (Nous Research Inc., Teknium et al.; MIT / Apache-2.0)
  - *Ancestral Role:* Hermes Agent's operational lifecycle, bounded turn stepping ($N \le 10$),
    prompt-cache-safe conversation persistence, fail-closed subprocess hooks (`sigKILL` deadlines),
    and dynamic capability plugin discovery serve as direct architectural donors for Tier 2.
  - *Retained Notice:* See [LICENSES/NOTICE-hermes.txt](LICENSES/NOTICE-hermes.txt),
    [LICENSES/MIT.txt](LICENSES/MIT.txt), and [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).
- **ReAct: Synergizing Reasoning and Acting in Language Models** (Shunyu Yao et al.)
  - *Ancestral Role:* The interleaved Thought / Action / Observation reasoning loop implemented
    in `Sarutahiko.Agent.stepTurn`.

### 2.8 Model Substrate & The Keiro Ecosystem (`utai`, `hokora`, `utaibon`)

- **The Keiro Ecosystem: Baikai, Keiro, Kiroku, Shibuya, Kioku, Shikumi, Keiki** (Nadeem Bitar)
  - *Ancestral Role:* Nadeem Bitar's extensive suite of AI-assistance Haskell tools provided
    deep design insights, benchmark data, and algorithmic blueprints:
    * `baikai`: Provider laws (L1 terminal chunk, L2 usage monoid, L3 option honesty) and
      categorized provider error taxonomies adopted in `Utai`.
    * `shikumi`: Context window compaction algorithms (`reserveTokens`, `compactTail`) adapted
      for `Sarutahiko.Session`.
    * `kioku`: Hybrid FTS/BM25 and vector retrieval architecture blueprint for `utaibon`.
    * `keiki`: Pure event-sourcing state machines for replay and session hydration.
- **OpenAI & Anthropic Wire Specifications** (OpenAI / Anthropic)
  - *Ancestral Role:* Wire format definitions for chat completion SSE streaming and payload framing.

### 2.9 Developer Tooling, Formatters & Linters

- **Brittany** (Lennart Spitzner; AGPL-3.0)
  - *Ancestral Role:* Canonical code formatter for Sarutahiko, incorporating Nadia Yvette Chambers'
    42-commit series modernizing GHC 9.14 support, comment fidelity, and layout alignments.
  - *Terms:* [LICENSES/AGPL-3.0.txt](LICENSES/AGPL-3.0.txt).
- **HLint** (Neil Mitchell; BSD-3-Clause)
  - *Ancestral Role:* Codebase linting and syntactic analysis.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).
- **Smirk** (Nadia Yvette Chambers; BSD-3-Clause)
  - *Ancestral Role:* Pure native PCRE regex engine with fuel-bounded execution for safe matching.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).
- **T-Digest** (Nadia Yvette Chambers; BSD-3-Clause)
  - *Ancestral Role:* Mergeable quantile sketches for latency and token distribution telemetry.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).
- **Contextful** (Inferensys; Apache-2.0 / MIT)
  - *Ancestral Role:* Local FTS5 context engine and code search CLI.
  - *Terms:* [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt) and [LICENSES/MIT.txt](LICENSES/MIT.txt).

### 2.10 Formats & Configuration Bridges (`sarutahiko-format-dhall`)

- **Dhall** (Gabriel Gonzalez; BSD-3-Clause)
  - *Ancestral Role:* The Dhall programmable configuration language's typed records, total
    evaluation, and hermetic guarantees directly informed `sarutahiko-format-dhall`'s total
    parser and record bridge, evaluating typed Dhall configuration files directly into
    `large-anon` anonymous row structures without intermediate Aeson ASTs.
  - *Terms:* [LICENSES/BSD-3-Clause.txt](LICENSES/BSD-3-Clause.txt).

---

## 3. Retained Notices and Multi-Licensing Compliance

Where Sarutahiko adapts concepts, schemas, or algorithms from projects licensed under
**Apache-2.0** (such as Streamly, Beam, Typed-Protocols, or Hermes Agent), all statutory
attribution obligations of Apache License 2.0 §4(d) are satisfied by the prominent
retained notices in `LICENSES/` and the descriptions in each derived package's `.cabal` file.

Where projects are licensed under **BSD-3-Clause**, **BSD-2-Clause**, or **MIT**, the
respective copyright and permission notices are preserved intact in `LICENSES/` and
cited across package descriptions.
