# sarutahiko (猿田彦)

An AI-assistance ecosystem—agent core, surfaces, protocols, formats, code
intelligence, and database access—reimplemented in modern Haskell on extensible
records (`large-anon` / `large-records`), row-typed algebraic effects (`effectful` /
`polysemy`), and the `yamaarashi` streaming stack.

## Author & Maintainer

- **Nadia Yvette Chambers** ([@NadiaYvette](https://github.com/NadiaYvette))
- **ORCID:** [0009-0009-7073-1726](https://orcid.org/0009-0009-7073-1726)
- **Contact:** `nadia.yvette.chambers@ik.me`

## Architectural Corpus & Documentation

The design corpus in `docs/` is the institutional memory of the program:
- **Corpus Index & Reading Map:** [`docs/INDEX.md`](docs/INDEX.md)
- **Program & Decisions:** [`docs/notes/NIH_PLAN.md`](docs/notes/NIH_PLAN.md)
- **Design Review:** [`docs/notes/DESIGN_REVIEW.md`](docs/notes/DESIGN_REVIEW.md)
- **Advisory for AI Coding Assistants:** [`AGENTS.md`](AGENTS.md)

## Code of Conduct

Community participation is governed by the Contributor Covenant version 3.0:
see [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Build & Test

Toolchain: GHC 9.14 / Cabal 3.18 / GHC2024.

```bash
# Build the project
cabal build all

# Run the test suites
cabal test all

# Generate documentation
cabal haddock --open
```
