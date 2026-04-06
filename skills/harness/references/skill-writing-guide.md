# Skill Writing Guide

Detailed guide for producing high-quality skills within a harness. Supplements SKILL.md Phase 4.

---

## Table of Contents

1. [Description Writing Patterns](#1-description-writing-patterns)
2. [Body Writing Style](#2-body-writing-style)
3. [Output Format Definition](#3-output-format-definition)
4. [Example Authoring](#4-example-authoring)
5. [Progressive Disclosure Patterns](#5-progressive-disclosure-patterns)
6. [Script Bundling Criteria](#6-script-bundling-criteria)
7. [Data Schema Standards](#7-data-schema-standards)
8. [What NOT to Include](#8-what-not-to-include)

---

## 1. Description Writing Patterns

The description is the sole trigger mechanism. Claude sees only name + description in its `available_skills` list and decides whether to invoke.

### Trigger Mechanics

Claude tends not to invoke skills for tasks it can handle with built-in tools. Simple requests may not trigger even with a perfect description. Complex, multi-step, specialized tasks have higher trigger probability.

### Writing Rules

1. List **what the skill does** + **concrete trigger situations**
2. Add boundary conditions to distinguish from near-miss cases
3. Write slightly "pushy" to compensate for Claude's conservative triggering

### Good Examples

```yaml
description: "Reads, extracts text/tables from, merges, splits, rotates,
  watermarks, encrypts/decrypts, and OCRs PDF files. Use this skill whenever
  a .pdf file is mentioned or a PDF output is requested. Especially useful
  when conversion, editing, or analysis is needed beyond simple reading."
```

```yaml
description: "Handles all spreadsheet operations on Excel/CSV/TSV files:
  column addition, formula calculation, formatting, charts, data cleaning.
  Use this skill when the user mentions a spreadsheet file -- even casually
  ('that xlsx in my downloads folder')."
```

### Bad Examples

- `"Processes data"` -- too vague, no trigger conditions
- `"PDF-related tasks"` -- no specific actions listed

---

## 2. Body Writing Style

### Why-First Principle

LLMs generalize better from understood reasons than from rigid rules. Explain the rationale, not just the command.

**Bad:**
```markdown
ALWAYS use pdfplumber for table extraction. NEVER use PyPDF2 for tables.
```

**Good:**
```markdown
Use pdfplumber for table extraction. PyPDF2 specializes in text extraction
and does not preserve row/column structure. pdfplumber recognizes cell
boundaries and returns structured data.
```

### Generalization Principle

When fixing issues found during testing, generalize at the principle level. Narrow fixes that only match specific test inputs are overfitting.

**Overfit fix:**
```markdown
If a column named "Q4 Revenue" exists, convert it to numeric.
```

**Generalized fix:**
```markdown
When column names contain keywords implying numeric values (revenue, amount,
quantity, etc.), convert those columns to numeric type. Preserve original
values on conversion failure.
```

### Imperative Tone

Use directive language ("Do X", "Use Y", "Generate Z") rather than descriptive ("X can be done", "Y is available"). Skills are instructions, not documentation.

### Context Economy

The context window is a shared resource. For every sentence, ask:
- "Does Claude already know this?" -> delete
- "Would Claude make mistakes without this?" -> keep
- "Would one example replace a long explanation?" -> use the example

---

## 3. Output Format Definition

For skills where output format matters:

```markdown
## Report Structure
Follow this template exactly:

# [Title]
## Summary
## Key Findings
## Recommendations
```

Keep format definitions concise. Include a concrete example when possible -- it communicates more than a spec.

---

## 4. Example Authoring

Examples communicate more effectively than long explanations:

```markdown
## Commit Message Format

**Example 1:**
Input: Add JWT-based user authentication
Output: feat(auth): implement JWT-based authentication

**Example 2:**
Input: Fix password visibility toggle not working on login page
Output: fix(login): repair password visibility toggle button
```

Use 2-3 examples covering the core case and an edge case.

---

## 5. Progressive Disclosure Patterns

### Pattern 1: Domain-specific Splitting

```
bigquery-skill/
+-- SKILL.md (overview + domain selection guide)
+-- references/
    +-- finance.md (revenue, billing metrics)
    +-- sales.md (opportunities, pipeline)
    +-- product.md (API usage, features)
```

When the user asks about revenue, load only finance.md.

### Pattern 2: Conditional Detail

```markdown
## Document Generation
Use docx-js to create new documents. -> See [DOCX-JS.md](references/docx-js.md).

## Document Editing
For simple edits, modify XML directly.
**If tracked changes are needed**: see [REDLINING.md](references/redlining.md).
```

### Pattern 3: Large Reference Files

References over 300 lines should include a table of contents at the top:

```markdown
# API Reference

## Table of Contents
1. [Authentication](#authentication)
2. [Endpoints](#endpoints)
3. [Error Codes](#error-codes)
4. [Rate Limits](#rate-limits)

---
## Authentication
...
```

---

## 6. Script Bundling Criteria

Monitor agent transcripts during test runs. Bundle when you see these signals:

| Signal | Action |
|--------|--------|
| Same helper script generated in 3/3 test runs | Bundle into `scripts/` |
| Same pip/npm install repeated every run | Add dependency installation step to skill |
| Identical multi-step approach repeated | Document as standard procedure in skill body |
| Same error followed by same workaround every time | Document known issue + resolution in skill |

Bundled scripts must be execution-tested before inclusion.

---

## 7. Data Schema Standards

Standard schemas for cross-skill data exchange and test evaluation within a harness.

### eval_metadata.json

Test case metadata:

```json
{
  "eval_id": 0,
  "eval_name": "descriptive-name-here",
  "prompt": "User's task prompt",
  "assertions": [
    "Output contains X",
    "File generated in Y format"
  ]
}
```

### grading.json

Assertion-based grading results:

```json
{
  "expectations": [
    {
      "text": "Output contains 'Seoul'",
      "passed": true,
      "evidence": "Found 'Seoul regional data extraction' in step 3"
    }
  ],
  "summary": {
    "passed": 2,
    "failed": 1,
    "total": 3,
    "pass_rate": 0.67
  }
}
```

**Field names are fixed:** Use `text`, `passed`, `evidence` exactly. Do not substitute with `name`/`met`/`details` or similar variants.

### timing.json

Execution time and token measurement:

```json
{
  "total_tokens": 84852,
  "duration_ms": 23332,
  "total_duration_seconds": 23.3
}
```

Capture `total_tokens` and `duration_ms` from the sub-agent completion notification **immediately** -- this data is only available at notification time and cannot be recovered later.

---

## 8. What NOT to Include in Skills

- README.md, CHANGELOG.md, or other supplementary docs
- Meta-information about the skill creation process (test results, iteration history)
- User-facing documentation (skills are directives for AI agents)
- General knowledge Claude already possesses
