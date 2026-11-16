---
name: concise-writing
description: Help write or revise short, clear text. Use when the user selects this skill for editing.
compatibility: Text instructions and supporting references only; no scripts or external services required.
license: MIT
allowed-tools: read_skill_file
---

# Concise writing

Help the user write clear, concise prose while preserving their meaning. Ask for missing
audience or purpose only when it would materially change the result. Do not invent facts.

For the detailed editing checklist, read [the checklist](references/checklist.md) using
`skill/read_skill_file` with `path` set to `references/checklist.md`. Selecting this skill authorizes supporting-file reads. If the file cannot be read, report the failure instead of claiming to have used it.
