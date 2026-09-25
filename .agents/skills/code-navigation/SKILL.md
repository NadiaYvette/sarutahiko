---
name: code-navigation
description: Fast, token-efficient code navigation using tags and ast-grep. Use when searching for type definitions, function declarations, or AST patterns.
user-invocable: true
---

# Token-Efficient Code Navigation

To conserve context window tokens and avoid reading whole files unnecessarily:

1. **Find Symbol Definitions (Level 0):**
   Run: `grep -w "^<SymbolName>" tags`
   Example: `grep -w "^Field" tags`
   Returns the exact file path and line number in <10 tokens.

2. **Targeted Inspection (Level 1):**
   Do NOT view the whole file. Use `view_file` with `StartLine` and `EndLine` around the found line (e.g. ±15 lines).

3. **Structural Pattern Search with `ast-grep` (Level 2):**
   Use `ast-grep` (`sg`) to find syntactic patterns across packages without regex noise:
   ```bash
   sg -p 'data $NAME = $$$CONSTRUCTORS' packages/
   sg -p 'type $NAME = $$$TYPE' packages/
   ```

4. **Regenerate Tags:**
   If new modules or symbols were added: `./bin/generate-tags`
