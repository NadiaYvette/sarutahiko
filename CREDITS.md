# Credits and Intellectual Acknowledgments — Sarutahiko

This document honors the researchers, engineers, and open-source maintainers whose
work, designs, and architectural principles informed the creation of Sarutahiko.
Per `docs/notes/DOC_STRATEGY.md` §9, credit in this repository is granted **by choice,
not mere legal obligation** — celebrating the conceptual debts we owe across the
ecosystem.

---

## 1. Key Individuals and Ecosystems

### Nadeem Bitar (The Keiro Ecosystem)
- **Projects:** *baikai*, *keiro*, *kiroku*, *shibuya*, *kioku*, *shikumi*, *keiki*
- **Contribution:** Nadeem Bitar's extensive suite of Haskell AI-assistance libraries
  provided invaluable empirical evidence and rich architectural foundations. Sarutahiko's
  "keiro-comparison thesis" acknowledges these first-iteration designs as the direct
  inspiration for our row-typed, algebraic-effect re-grounding. Specifically, `baikai`'s
  provider laws (L1 terminal chunk, L2 usage monoids, L3 option honesty), `shikumi`'s
  context compaction algorithms, `kioku`'s hybrid BM25/vector memory recall, and `keiki`'s
  pure event-sourcing transducers directly informed the design of `utai`, `sarutahiko-session`,
  and `hokora`.

### Nous Research Inc. & The Hermes Community
- **Project:** *Hermes Agent* (Teknium and the Nous Research engineering team)
- **Contribution:** Pioneered the state-of-the-art open-source AI agent architecture.
  Hermes Agent's narrow-waist core, prompt-cache preservation rules, fail-closed
  subprocess hook contracts (`sigKILL` deadline discipline), and dynamic plugin capability
  grants provided the operational blueprint for Sarutahiko's Tier 2 agent core
  (`sarutahiko-agent`, `sarutahiko-hooks`, `sarutahiko-plugins`, `sarutahiko-session`).

### Edsko de Vries & Well-Typed
- **Projects:** *large-records*, *large-anon*, *large-generics*, *typelet*
- **Contribution:** Solved the decades-old Haskell record problem by introducing $O(1)$
  compile-time wide records and anonymous row types (`Record f r`). Their groundbreaking
  work forms the bedrock upon which the entire Sarutahiko ecosystem is constructed.

### Andrey Mokhov & The Newcastle / Jane Street Research Group
- **Projects:** *Selective Applicative Functors* (`selective`), *Algebraic Graphs* (`alga`),
  *Build Systems à la Carte*
- **Contribution:** Formulated the mathematics of Selective Applicative Functors and
  algebraic graph representations. Their work enabled `yamaarashi-flow` to achieve static
  dependency over-approximation and dynamic workflow execution without the ergonomic
  penalties or label collisions of arrow notation.

### Michael Snoyman & FP Complete
- **Projects:** *conduit*, *typed-process*, *mono-traversable*, *wai*
- **Contribution:** Established enduring standards for high-assurance Haskell systems:
  bracketed deterministic resource reclamation (`ResourceT`), strongly typed process
  supervision, and monomorphic non-emptiness guarantees (`NonNull`).

### Harendra Kumar & Composewell Technologies
- **Project:** *Streamly*
- **Contribution:** Advanced the frontier of pure Haskell streaming through step-fusion,
  unifying concurrent and sequential stream evaluation into a single monadic interface.

### Michael Thompson
- **Project:** *Streaming*
- **Contribution:** Pioneered the elegant Church-encoded CPS free monad transformer
  pattern (`Stream (Of a) m r`) that powers `Yamaarashi.Stream`.

### Bryan O'Sullivan, Mark Wotton, Colin Paul Adams & The Aeson Team
- **Projects:** *aeson*, *attoparsec*, *text*
- **Contribution:** Set the industry standard for high-throughput byte parsing and JSON
  processing in Haskell. Their low-level scanning algorithms and UTF-8 handling techniques
  guided the zero-allocation parser in `kogaki-wire`.

### Nikita Volkov
- **Project:** *Hasql*
- **Contribution:** Demonstrated the superiority of explicit applicative row encoders and
  decoders over typeclass-driven magic for PostgreSQL wire protocols, establishing the
  ideological template for `hashigakari`.

### Travis Whitaker & The Beam Contributors
- **Project:** *Beam*
- **Contribution:** Formulated typed relational query combinators and higher-kinded
  database schema expressions in Haskell, inspiring Hashigakari's relational projections
  and `beam-large-anon`.

### Sandy Maguire
- **Project:** *Polysemy*
- **Contribution:** Pioneered higher-order algebraic effects in Haskell, providing the
  interpreter framework for Sarutahiko's dual-effect parity architecture.

### Ertugrul Söylemez & Dominik Peteler
- **Project:** *Effectful*
- **Contribution:** Re-grounded algebraic effects on unlifted primitive state and fast
  dynamic dispatch, powering Sarutahiko's production runtime and CLI executables.

### Edward Kmett
- **Projects:** *recursion-schemes*, *ad*, *lens*, *thc*
- **Contribution:** Master of categorical recursion combinators (`ana`, `cata`, `hylo`)
  used for task packet decomposition, and author of the impeccable provenance standards
  in `thc` that served as the model for Sarutahiko's own licensing audit.

### Anthony Cowley
- **Project:** *Vinyl*
- **Contribution:** Authored the pioneering extensible records library in Haskell,
  whose universe-polymorphic field tagging and row lenses inspired `sarutahiko-fields`.

### Yves Parès & Faura
- **Projects:** *porcupine*, *kernmantle*, *record-soup*, *docrecords*
- **Contribution:** Formulated the "define a field exactly once" doctrine, TriState
  patching semantics, and virtual filesystem sandboxing for task pipelines.

### Tom Nielsen & Andreas Herrmann (Tweag I/O)
- **Project:** *Funflow*
- **Contribution:** Pioneered functional task workflow engines and content-addressed
  task execution graphs.

### Alexander Vieth, Duncan Coutts, Neil Davies (IOHK)
- **Project:** *Typed-Protocols*
- **Contribution:** Formulated agency-indexed state machines and session type proofs
  governing peer-to-peer wire protocols.

### Anthropic
- **Project:** *Model Context Protocol (MCP)*
- **Contribution:** Defined the open JSON-RPC standard for universal AI assistant tooling
  and context exchange.

---

## 2. Institutional and Academic Lineage

- **Data Types à la Carte** (Wouter Swierstra, 2008): Defunctionalized GADT sum-of-products
  foundations for algebraic effects.
- **Selective Applicative Functors** (Andrey Mokhov et al., ICFP 2019): Static analysis and
  branching between Applicative and Monad.
- **Build Systems à la Carte** (Andrey Mokhov, Neil Mitchell, Simon Peyton Jones, ICFP 2018):
  Scheduling, caching, and early cutoff theory.
- **RFC 7396 (JSON Merge Patch)** (Paul Hoffman, Richard Snell): TriState HKD update algebra.
- **RFC 8259 (The JSON Data Interchange Format)**: Strict wire representation without
  surrogate laxity.
