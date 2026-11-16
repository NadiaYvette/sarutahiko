<!--
SPDX-License-Identifier: EUPL-1.2 OR Apache-2.0
-->
# Code Navigation & Token Conservation Rules

**Status:** ACTIVE RULE · Bounded Context Extension  
**Canonical Specification:** [`docs/NEWBIE_GUIDE.md`](../../docs/NEWBIE_GUIDE.md) §1  
**Skill Reference:** [`.agents/skills/code-navigation/SKILL.md`](../skills/code-navigation/SKILL.md)  
**Tooling:** [`bin/generate-tags`](../../bin/generate-tags) · `ast-grep` · `hasktags`

---

## 1. The Token Conservation Funnel

Dumping whole source files burns thousands of context tokens and triggers severe attention degradation. AI assistants must navigate code strictly through the progressive disclosure funnel:

```
                      PROGRESSIVE DISCLOSURE FUNNEL
                                                                    Tokens
┌─────────────────────────────────────────────────────────────┐
│  Level 0: Symbol Jump via ./tags (grep -w "^Symbol" tags)   │   < 15
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│  Level 1: Structural AST Query (ast-grep / sg)              │   < 150
└──────────────────────────────┬──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────┐
│  Level 2: Targeted Slice View (view_file StartLine/EndLine) │   < 300
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Inviolable Operational Rules

1. **Never dump entire modules:**
   - Always supply `StartLine` and `EndLine` to `view_file` when inspecting code.
   - Slices should rarely exceed 60–100 lines at a time.
2. **Use `./tags` for instant symbol discovery:**
   - Look up definitions directly using `grep -w "^<symbol>" tags` or the code-navigation skill.
   - If `tags` is missing or out of date, regenerate it via `./bin/generate-tags`.
3. **Use Structural AST queries for patterns:**
   - Search for typeclass instances, solver cases, or datatype declarations using `ast-grep` (`sg`) rather than scanning files line by line.
