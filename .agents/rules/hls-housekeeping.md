# HLS & GHC Automated Housekeeping Rule (`hls-housekeeping.md`)

**Status:** ACTIVE OPERATIONAL RULE  
**Author:** Antigravity (Google DeepMind / Advanced Agentic Coding)  
**Tooling:** `hls-autoheal` (`/home/nyc/.local/bin/hls-autoheal`), `haskell-language-server` (`/home/nyc/.local/bin/haskell-language-server`), `yamaarashi-exec autoheal`

---

## 1. Zero-Token Mechanical Auto-Healing Principle

Mundane compiler warnings and diagnostics consume between 10% and 35% of interactive prompt trajectory tokens when resolved through manual multi-turn conversational repair. Every turn re-submits the entire conversation payload (~150k–300k tokens) to resolve a missing import or language pragma.

All agents (Antigravity, Hermes, Sarutahiko) and executors (`yamaarashi-exec`) MUST offload mechanical code repairs to deterministic local tooling before spending prompt context.

---

## 2. Supported Automated Repairs (`hls-autoheal`)

The `/home/nyc/.local/bin/hls-autoheal` utility automates the following mechanical diagnostics:

1. **Unused / Redundant Imports (`GHC-66111` / `-Wunused-imports`)**:
   Automatically deletes redundant `import` lines or trims redundant symbols from explicit import lists.
2. **Deprecated Namespace Specifiers (`GHC-68383` / `-Wpattern-namespace-specifier`)**:
   Converts deprecated `pattern <Ident>` exports/imports into `data <Ident>` for GHC 9.14+ compatibility.
3. **Missing Language Pragmas**:
   Automatically inserts `{-# LANGUAGE <Pragma> #-}` directives when GHC suggests them (e.g. `PatternSynonyms`, `OverloadedStrings`, `DeriveGeneric`, `RecordWildCards`).
4. **Unused Language Pragmas (HLint / GHC)**:
   Automatically prunes unneeded `{-# LANGUAGE ... #-}` pragmas flagged by quality gates.
5. **HLint Micro-Refactorings**:
   Resolves common hints like `maybe <def> id` $\to$ `fromMaybe <def>` and imports `Data.Maybe (fromMaybe)` if missing.

---

## 3. Standard Operational Workflows

### A. Pipe Compiler Diagnostics Directly:
```bash
# In-place repair from standard input
cabal build 2>&1 | hls-autoheal --stdin
bin/<repo>-verify 2>&1 | hls-autoheal --stdin
```

### B. Parse a Failed Build Log:
```bash
hls-autoheal --log /path/to/build.log
```

### C. Run HLS Typecheck Auto-Healer:
```bash
hls-autoheal --hls [packages/.../src]
```

### D. Iterative Build-and-Heal Loop:
```bash
hls-autoheal --build "cabal v2-build -j20 --semaphore"
```

### E. Yamaarashi Automated Pre-Pass:
Inside `yamaarashi-exec run`, verification failures automatically trigger an internal `hls-autoheal` pre-pass on the verification log. If mechanical fixes are applied, `yamaarashi-exec` re-verifies immediately on the same attempt without invoking or billing an LLM repair cycle.
