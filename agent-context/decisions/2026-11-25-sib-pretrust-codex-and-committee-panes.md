# ADR-009: sib pre-trust covers Codex siblings, and install lists the unattended pane roots

- **Date**: 2026-11-25
- **Status**: Accepted (2026-11-28)
- **Deciders**: user (accepted 2026-11-28), with Claude
- **Amends**: [ADR-006](2026-11-13-sib-trust-allowlist.md)

## Context

Committee member panes (`agent-scout`) worked in a new folder per meeting
under `/private/tmp/agent-scout`. That root is outside `$HOME`, so the sib
allowlist (ADR-006) could never pre-trust it. The first meeting failed:
the Claude members waited at the trust dialog, and the meeting was recorded
as held.

Codex has its own folder-trust screen ("Trust this folder?": Trust and
continue / Open restricted). sib did not detect it, so a Codex pane there
would time out as "input box never appeared". Codex keeps trust per exact
dir in `config.toml` (`[projects."<dir>"] trust_level`), not per parent.

The office (`brief`) has the same shape: it hands role art to one Codex
pane at a time, in a new job folder per job under
`~/.local/share/cmux/office-art/jobs/`. No allowlist entry covered it, so
that pane stopped at Codex's trust screen too.

## Decision

1. `agent-scout` uses the pane root `~/.local/share/cmux/hr/panes` by
   default. Before any pane opens, `convene` and `evaluate` ask
   `sib trusted <root>/<member-folder>`. If sib does not cover it, the run
   stops with exit 6 and the fix, and no meeting record is written.
2. The sib allowlist also pre-trusts **Codex** siblings: sib appends
   `[projects."<dir>"] trust_level = "trusted"` to
   `${CODEX_HOME:-~/.codex}/config.toml` once. An existing table for the
   dir, an explicit `untrusted` included, stays as it is. sib never writes
   a key that needs escaping. The `$HOME`-only and one-segment `*` rules of
   ADR-006 apply unchanged.
3. sib treats Codex's trust screen as a start screen: no prompt, exit 6.
4. `install.sh` adds `~/.local/share/cmux/hr/panes/*` and
   `~/.local/share/cmux/office-art/jobs/*` to sib's `trusted-dirs` once
   each, under a comment line. It also moves a local
   committee config whose root is still `/private/tmp/agent-scout` to the
   new default.
5. Before it opens an art pane, `brief` asks `sib trusted <job dir>`. If
   sib does not cover it, no pane opens, the reason goes to `untrusted` in
   the office-art `state.json`, and those roles wait until the next day.

Code: commits `9815e96` and `2a10e79`.

## Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| (b) Trust `/private/tmp/agent-scout` in Claude and Codex directly | No sib change | Outside `$HOME`, so sib cannot manage it; folder names change per meeting, and Codex trust is per exact dir |
| (c) The user approves each member pane by hand | No standing grant | Members run unattended; every meeting waits at every pane |

## Consequences

### Positive

- After install, member panes and office-art panes start with no trust
  screen.
- A pane root that sib cannot trust stops the meeting before any pane
  opens, instead of a failed meeting counted as held.
- A Codex pane at its trust screen is reported, not left to time out.

### Negative

- ADR-006 left Codex siblings untouched. Now every allowlist entry also
  trusts Codex there. A trusted Codex project loads its project config,
  hooks and exec policies.
- ADR-006 says entries are added only on the user's say-so. Here install
  adds two entries itself. They cover only folders `agent-scout` and
  `brief` create: `task.md` with `answer.json`, or with the SVG answers.

### Neutral

- `sib trusted <dir>` is a read-only check other tools can use.

## Implementation Notes

`scripts/install.sh` writes the two `trusted-dirs` entries on each
machine; a machine installed before this ADR needs one re-run.

## References

- [ADR-006](2026-11-13-sib-trust-allowlist.md) — the allowlist this amends
- Tests: `tests/sib-spawn.bats` (folder-trust section), `tests/agent-scout.bats`
  (`panes:`), `tests/brief-tree.bats` (`office art:`), `tests/install.bats`
  (unattended panes)
