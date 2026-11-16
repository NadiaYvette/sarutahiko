<!--
SPDX-License-Identifier: EUPL-1.2 OR Apache-2.0
-->
# Commit Authoring & AI Attribution Rules

**Status:** ACTIVE RULE · Bounded Context Extension  
**Canonical Specification:** [`docs/notes/COMMIT_ATTRIBUTION.md`](../../docs/notes/COMMIT_ATTRIBUTION.md)  
**Quick Reference:** [`.agents/ATTRIBUTION.md`](../ATTRIBUTION.md)  
**Enforcement:** [`.githooks/commit-msg`](../../.githooks/commit-msg) · [`.gitmessage`](../../.gitmessage)

---

## 1. Commit Message Structure

Every commit in `polytropos` must follow the imperative-subject plus explanatory HEREDOC body structure:

```gitcommit
Short (<=72 chars) imperative subject line describing the change

Problem statement explaining what was wrong, missing, or required.
Rationale explaining why this particular design decision was taken over
alternatives, citing relevant notes (e.g. DOC_STRATEGY.md §4, D1-D10).

Assisted-by: <Tool> (<Provider> / <Model>)
Orchestrated-by: <Engine>
```

---

## 2. Linux Kernel RFC 2822 Trailer Schema

AI coding assistant attribution must strictly use RFC 2822 trailer format:

1. **`Assisted-by:`** (Required when AI assisted):
   - Format: `Assisted-by: <Tool> (<Provider> / <Model>)` or bare `Assisted-by: <Tool>`
   - Canonical examples:
     - `Assisted-by: Antigravity (Anthropic / claude-4.6-opus)`
     - `Assisted-by: Claude Code (Anthropic / claude-3-7-sonnet)`
     - `Assisted-by: Freebuff`
2. **`Orchestrated-by:`** (Optional when an orchestration framework directed the task):
   - Canonical examples:
     - `Orchestrated-by: Sarutahiko`
     - `Orchestrated-by: Keiro`
     - `Orchestrated-by: Shikumi`

---

## 3. Inviolable Legal & Attribution Boundaries

1. **NEVER use `Co-authored-by:` for AI:**
   - GitHub renders `Co-authored-by:` with an avatar and treats the entity as a legal co-author.
   - Legally and philosophically, AI models cannot hold copyright or enter joint authorship under repository policy.
2. **NEVER use `Signed-off-by:` for AI:**
   - `Signed-off-by:` certifies the Developer Certificate of Origin (DCO §1.1). Only human developers can legally certify origin and licensing compliance.
3. **Automated Enforcement:**
   - Any commit containing `Co-authored-by:.*(bot|ai|claude|gemini|gpt|antigravity)` or missing valid trailers when AI is detected will be rejected by `.githooks/commit-msg`.
