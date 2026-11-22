# Constraint: Requirement Sentences (RFC 2119 + ASD-STE100)

- **Category**: code-style
- **Severity**: high
- **Created**: 2026-11-20
- **Last Verified**: 2026-11-23
- **Scope**: All personas (L1 baseline)

## Description

Every English sentence that states a requirement for an agent uses one
RFC 2119 keyword and the ASD-STE100 sentence rules, and passes
`req-lint`.

## Scope

- **Applies to**: `agents/*.md`, the workflow sections of
  `skills/*/SKILL.md`, `agent-context/constraints/*.md`, and any persona
  file whose fields are requirements (for example agent-home manifest
  `boundary` and `success_criteria.criterion`).
- **Excludes**: Korean output examples and trigger phrases (see
  `code-style-skill-language-convention`), quoted text, code blocks.

A sentence is a requirement when it contains an uppercase keyword. A
sentence without one is a description.

## Rule

Keywords (RFC 2119 / RFC 8174, uppercase only):

| Keyword | Meaning |
|---|---|
| `MUST` | Required, with no exception. |
| `MUST NOT` | Prohibited, with no exception. |
| `SHOULD` / `SHOULD NOT` | Required unless the stated exception applies. |
| `MAY` | Permitted. Not a statement of ability or possibility. |

Sentence rules:

- **R1** A requirement sentence MUST be in English.
- **R2** A requirement sentence MUST use the form `[If|When <condition>, ]<subject> <keyword> <verb> ...`.
- **R3** A requirement sentence MUST contain exactly one keyword.
- **R4** A writer MUST NOT use `SHALL`, `REQUIRED`, `RECOMMENDED` or `OPTIONAL` as keywords.
- **R5** A requirement sentence MUST NOT contain a lowercase `must`, `should`, `may` or `shall`.
- **R6** A `SHOULD` sentence MUST state its exception with `unless` or `except`.
- **R7** A requirement sentence MUST have 20 words or fewer, and a code span counts as one word.
- **R8** A writer MUST NOT put a keyword in a description, a table of terms or a rejected alternative.

Requirement IDs and trace (constraints only):

- **R9** Each requirement sentence in a constraint MUST start its own list item with an ID `**R<n>**`.
- **R10** A writer MUST NOT renumber an ID or reuse the ID of a removed requirement.
- **R11** Each ID MUST have a row in the `## Trace` table of its constraint.
- **R12** A Trace row MUST name a test file that contains the full ID, or start with `manual`.

The full ID is `<file-stem>.R<n>`, for example
`code-style-requirement-sentences.R7`. A test that checks a requirement
starts its name with the full ID. A new requirement takes the next
free number.

The checks below are manual
(ASD-STE100 rules that a script cannot check):

- [ ] Active voice, and the subject is the actor (STE 3.x).
- [ ] One instruction per sentence; "A or B" becomes two sentences (STE 5.2).
- [ ] One term for one concept, used the same way in every file.
- [ ] No vague words ("properly", "valid", "as needed") without a definition.
- [ ] Numbers have units.

## Rationale

Agent specs in this framework are English
(`code-style-skill-language-convention`), so ASD-STE100 applies as
written, not only as principles. RFC 2119 gives each requirement a
level that a reader and a script can see. Lowercase "should" leaves
the level unclear: an agent cannot tell a rule from advice.

Sources and what was confirmed (2026-11-20):

- RFC 2119 and RFC 8174 define the keywords; RFC 8174 makes only the
  uppercase forms keywords.
- ASD-STE100 Issue 9 (January 2025), via simplified-english.co.uk
  `rules-ste9.html`: rule 5.1 (20 words in a procedural sentence),
  rule 5.2 (one instruction in each sentence), rule 5.4 (a comma
  after a leading descriptive statement).
- Not confirmed from the Issue 9 dictionary: whether `should`, `shall`
  and `may` are approved words. The keyword set rests on RFC 2119,
  not on the STE dictionary.
- Prior art: tobyilee/trealworld `tstack/skills/t-mode/references/doc-style.md`
  (RFC 2119 levels with STE100 principles for Korean documents).

## Verification

```bash
# Markdown: checks only sentences with an uppercase keyword
req-lint --md agents/*.md skills/*/SKILL.md agent-context/constraints/*.md

# Constraints: every requirement has an ID and a trace row
req-lint --trace

# A list of requirements, one per line (persona lints call this)
printf '%s\n' "claw MUST NOT write a secret to a log." | req-lint --subject claw
```

The CI job `req-lint` (`.github/workflows/ci.yml`) runs the Markdown check, the
trace check and `tests/req-lint.bats` on every push to `main`. `req-lint` is `bin/req-lint`; `scripts/install.sh` links it to
`~/.local/bin/req-lint`. A persona lint that depends on it fails when
it is missing.

## Trace

| ID | Check |
|---|---|
| R1 | `tests/req-lint.bats` |
| R2 | `tests/req-lint.bats` |
| R3 | `tests/req-lint.bats` |
| R4 | `tests/req-lint.bats` |
| R5 | `tests/req-lint.bats` |
| R6 | `tests/req-lint.bats` |
| R7 | `tests/req-lint.bats` |
| R8 | manual: review at edit time (agent-home `manifest-lint` checks its description fields) |
| R9 | `tests/req-lint.bats` |
| R10 | manual: review the diff of any constraint for changed or reused IDs |
| R11 | `tests/req-lint.bats` |
| R12 | `tests/req-lint.bats` |

## Exceptions

- **Never** for new or edited requirement sentences.
- Existing sentences that use lowercase "must"/"should" are
  descriptions until someone rewrites them; rewrite them when you edit
  that section.

## Examples

### Allowed

```text
claw MUST NOT write a secret to chat, a log or a file.
If claw cannot read `claw-local.md`, claw MUST NOT make changes.
The agent SHOULD log each step, unless the user turns logging off.
```

### Not Allowed

```text
claw should not leak secrets.              # lowercase level
Secrets MUST NOT be written to logs.       # passive, no actor
claw MUST ask first and MAY retry.         # two keywords
claw SHOULD retry.                         # SHOULD without an exception
claw MUST NOT send a message to a chat channel or a person, unless the user asks in the same session.   # 21 words
```

## References

- `bin/req-lint` — the checker
- `code-style-skill-language-convention.md` — why specs are English
- https://www.rfc-editor.org/rfc/rfc2119 , https://www.rfc-editor.org/rfc/rfc8174
- https://simplified-english.co.uk/rules-ste9.html
