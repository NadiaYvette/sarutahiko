# `sarutahiko-tooling` Maintainer Guide & Self-Hosting Roadmap

**Audience:** Maintainers, subsystem leads, and autonomous AI assistant drivers.  
**Canonical Package:** [`sarutahiko-tooling`](../README.md)  
**Parent Design Note:** [`docs/notes/ASSISTANT_TOOLING_DESIGN.md`](../../docs/notes/ASSISTANT_TOOLING_DESIGN.md)  
**Infrastructure Policy:** [`docs/notes/INFRASTRUCTURE.md`](../../docs/notes/INFRASTRUCTURE.md)  

---

## 1. Honorary Package Boundaries & Zero-Contamination Doctrine

`sarutahiko-tooling` is governed under [`docs/notes/DOC_STRATEGY.md`](../../docs/notes/DOC_STRATEGY.md) as an honorary package:
1. **Zero Cabal Contamination:** Bootstrapping tools (Tweag's `tricorder`, Nadeem Bitar's `shikumi` / `kioku`, `contextful`, `sqlite-vec`) must **never** be injected into `cabal.project` or the `.cabal` files of `packages/`.
2. **Out-of-Process Isolation:** All assistant tooling operates strictly as out-of-process subprocesses communicating over stdio JSON-RPC (MCP) or standard POSIX pipes.
3. **Pristine Core Builds:** A human developer cloning `sarutahiko` must always be able to run `cabal build all` with standard GHC without having any assistant tooling or daemons installed.

---

## 2. The Bootstrapping to Self-Hosting Transition Lifecycle

`sarutahiko` follows a disciplined 3-stage self-hosting roadmap:

```
Stage 1: External Bootstrapping (Current)
  ├── Compiler Diagnostics:  Tweag's tricorder-mcp daemon
  ├── LM Tracing & Replay:   Nadeem's shikumi-cli
  ├── Symbol Jumping:        hasktags (./tags)
  └── Context Packs:         Contextful (FTS5 BM25)
  ▼
Stage 2: Hokora Vertical Slice (Phase 1.5)
  ├── SQLite Event Spine:    hokora-spine-sqlite
  ├── Fail-Closed Leases:    session_locks table with BEGIN IMMEDIATE
  └── Pure Replay Harness:   utai-mock with RPL-1 bit-identical replay
  ▼
Stage 3: Full Self-Hosting (Phase 2 & 3)
  ├── Wire & Tool Server:    sarutahiko-mcp (in-tree MCP server)
  ├── Hybrid Agent Memory:   utaibon (in-tree SQLite FTS5 + sqlite-vec virtual tables)
  ├── Incremental Parser:    sarutahiko-parse (Wagner-Graham incremental GLR / Earley)
  └── Streaming Protocol:    yamaarashi-kernel + yamaarashi-network
```

---

## 3. Living Registers as External Memory

Do not force AI assistants to read 20 design documents to rediscover past decisions. Maintain the living registers as the single source of truth:
* **Dependency & Re-use Decisions:** [`docs/registers/REUSE_REGISTER.md`](../../docs/registers/REUSE_REGISTER.md). Check before adding any dependency.
* **Provider Wire Quirks:** [`docs/registers/CODEC_QUIRKS.md`](../../docs/registers/CODEC_QUIRKS.md). Record every streaming or tool-calling quirk with a fixture-backed test row.
* **Noh Ontology & Vocabulary:** [`docs/registers/GLOSSARY.md`](../../docs/registers/GLOSSARY.md). Register all package names and domain terms.
* **Orientation Budget:** Maintain [`AGENTS.md`](../../AGENTS.md) at ~4 KB. It is an orientation pointer; add links, never inline architectural text.

---

## 4. Index & Tag Hygiene

* Whenever new modules, types, or effect signatures are added or renamed:
  ```bash
  ./bin/generate-tags
  ```
* Ensure generated artifacts (`tags`, `TAGS`, `.ghc.environment.*`, `dist-newstyle/`) remain strictly in [`.gitignore`](../../.gitignore).

---

## 5. Pushing & Multi-Remote Fan-out Policy

Per `INFRASTRUCTURE.md` §12:
1. **Commits are local and frequent:** Commit after every coherent task packet or refactor with descriptive HEREDOC messages and RFC 2822 `Assisted-by:` trailers.
2. **Pushes are batched:** Push only at session end or upon explicit maintainer request. Never hammer hosting services per commit.
3. **Execution:** Use the multi-remote push script:
   ```bash
   ./bin/push-all
   ```
   Pushes `master --follow-tags` to `github`, `all` (Disroot, Framagit, GitCode), and `rad` (Radicle).
