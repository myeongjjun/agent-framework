#!/usr/bin/env bats
# Tests for scripts/install.sh and scripts/verify.sh.
#
# Each test copies the tracked framework tree into a throwaway dir and runs
# that copy's scripts against a throwaway HOME, so the real ~/.claude,
# ~/.codex, ~/.local/bin and ~/.cmuxterm are never read or written, and a
# test may edit "L1 source" without touching this checkout.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FW="$BATS_TEST_TMPDIR/fw"
  mkdir -p "$FW"
  git -C "$REPO_ROOT" ls-files -z | (cd "$REPO_ROOT" && tar --null -T - -cf -) | tar -xf - -C "$FW"

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset XDG_CONFIG_HOME XDG_DATA_HOME CLAUDE_CONFIG_DIR
  # install.sh ends with `brief render`; never let it reach a live cmux.
  export BRIEF_CMUX=/usr/bin/false

  INSTALL="$FW/scripts/install.sh"
  VERIFY="$FW/scripts/verify.sh"
}

first_hook() { basename "$(ls "$FW"/hooks/general/*.sh | head -1)"; }

@test "fresh install deploys every L1 surface into an empty HOME" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"L1 install complete."* ]]

  for s in "$FW"/skills/*/; do
    s="${s%/}"; n="$(basename "$s")"
    [ "$(readlink "$HOME/.claude/skills/$n")" = "$s" ]
    [ "$(readlink "$HOME/.codex/skills/$n")" = "$s" ]
  done
  for h in "$FW"/hooks/*/*.sh; do
    d="$HOME/.claude/hooks/$(basename "$h")"
    [ -f "$d" ] && [ ! -L "$d" ] && [ -x "$d" ]
    cmp -s "$h" "$d"
  done
  for b in "$FW"/bin/*; do
    [ -f "$b" ] || continue
    [ "$(readlink "$HOME/.local/bin/$(basename "$b")")" = "$b" ]
  done
  [ "$(readlink "$HOME/.local/bin/brief")" = "$FW/cmux/brief" ]
  cmp -s "$FW/AGENTS.md" "$HOME/.claude/AGENTS.md.framework-base"
  [ -f "$HOME/.claude/agents/orch.md" ]
  [ -x "$HOME/.claude/statusline.sh" ]
  [ -f "$HOME/.cmuxterm/automations.json" ]
  [ -d "$HOME/.local/share/cmux/orch/.git" ]
  [ -s "$HOME/.claude/.framework-owned" ]
  [ -s "$HOME/.claude/.framework-checksums" ]
}

@test "verify reports in sync right after install" {
  "$INSTALL" >/dev/null
  run "$VERIFY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
}

@test "re-running install changes nothing" {
  "$INSTALL" >/dev/null
  before="$(cd "$HOME" && find .claude .codex .local/bin -print0 | sort -z | xargs -0 ls -ld | awk '{print $1, $NF}'; cat .claude/.framework-owned)"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  after="$(cd "$HOME" && find .claude .codex .local/bin -print0 | sort -z | xargs -0 ls -ld | awk '{print $1, $NF}'; cat .claude/.framework-owned)"
  [ "$before" = "$after" ]
  run "$VERIFY"
  [ "$status" -eq 0 ]
}

@test "--dry-run deploys nothing" {
  run "$INSTALL" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/.framework-checksums" ]
  [ ! -e "$HOME/.claude/.framework-owned" ]
  [ ! -e "$HOME/.claude/hooks" ]
  [ ! -e "$HOME/.cmuxterm/automations.json" ]
  [ -z "$(find "$HOME" -type l)" ]
}

@test "verify without a snapshot exits 3" {
  run "$VERIFY"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no snapshot"* ]]
}

@test "verify flags L1 source changed since install (exit 1)" {
  "$INSTALL" >/dev/null
  echo "# changed" >> "$FW/hooks/general/$(first_hook)"
  run "$VERIFY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"source vs snapshot DRIFT"* ]]
}

@test "verify flags a missing deployed hook (exit 2)" {
  "$INSTALL" >/dev/null
  h="$(first_hook)"
  rm "$HOME/.claude/hooks/$h"
  run "$VERIFY"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing: $HOME/.claude/hooks/$h"* ]]
}

@test "a hook another layer wrote is kept, and verify only lists it" {
  "$INSTALL" >/dev/null
  h="$HOME/.claude/hooks/$(first_hook)"
  echo "persona copy" > "$h"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"written by another layer — kept"* ]]
  [ "$(cat "$h")" = "persona copy" ]
  run "$VERIFY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"other layer: $h"* ]]
}

@test "--force takes a hook back from another layer" {
  "$INSTALL" >/dev/null
  n="$(first_hook)"
  echo "persona copy" > "$HOME/.claude/hooks/$n"
  run "$INSTALL" --force
  [ "$status" -eq 0 ]
  cmp -s "$FW/hooks/general/$n" "$HOME/.claude/hooks/$n"
}

@test "an L1 copy left stale by a source update is redeployed" {
  "$INSTALL" >/dev/null
  n="$(first_hook)"
  echo "# v2" >> "$FW/hooks/general/$n"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  cmp -s "$FW/hooks/general/$n" "$HOME/.claude/hooks/$n"
  run "$VERIFY"
  [ "$status" -eq 0 ]
}

@test "an owned copy whose source left L1 is removed" {
  "$INSTALL" >/dev/null
  n="$(first_hook)"
  rm "$FW/hooks/general/$n"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/hooks/$n" ]
  ! grep -q "/$n\$" "$HOME/.claude/.framework-owned"
}

@test "a non-symlink bin target is refused (exit 3) until --force" {
  mkdir -p "$HOME/.local/bin"
  echo "user tool" > "$HOME/.local/bin/sib"
  run "$INSTALL"
  [ "$status" -eq 3 ]
  [[ "$output" == *"bin sib"*"not a symlink"* ]]
  [ "$(cat "$HOME/.local/bin/sib")" = "user tool" ]
  # The refusal does not stop the other sections.
  [ -s "$HOME/.claude/.framework-checksums" ]

  run "$INSTALL" --force
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.local/bin/sib")" = "$FW/bin/sib" ]
}

@test "a skill dir another layer copied in is kept, and --force links it" {
  n="$(basename "$(ls -d "$FW"/skills/*/ | head -1)")"
  mkdir -p "$HOME/.claude/skills/$n"
  echo persona > "$HOME/.claude/skills/$n/SKILL.md"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ ! -L "$HOME/.claude/skills/$n" ]
  [ "$(cat "$HOME/.claude/skills/$n/SKILL.md")" = persona ]
  run "$VERIFY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"other layer: $HOME/.claude/skills/$n"* ]]

  run "$INSTALL" --force
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.claude/skills/$n")" = "$FW/skills/$n" ]
}

@test "the cmux report rule reaches Claude rules and a marked Codex AGENTS.md block" {
  mkdir -p "$HOME/.codex"
  printf '# my codex rules\nkeep me\n' > "$HOME/.codex/AGENTS.md"
  "$INSTALL" >/dev/null
  cmp -s "$FW/cmux/session-report.md" "$HOME/.claude/rules/cmux-session-report.md"
  grep -q "keep me" "$HOME/.codex/AGENTS.md"
  grep -q "brief report" "$HOME/.codex/AGENTS.md"
  [ "$(grep -c 'cmux-session-report:start' "$HOME/.codex/AGENTS.md")" -eq 1 ]

  # Re-install replaces the block in place; a source edit flows through.
  printf '\nextra line\n' >> "$FW/cmux/session-report.md"
  run "$VERIFY"
  [ "$status" -ne 0 ]
  "$INSTALL" >/dev/null
  [ "$(grep -c 'cmux-session-report:start' "$HOME/.codex/AGENTS.md")" -eq 1 ]
  grep -q "extra line" "$HOME/.codex/AGENTS.md"
  grep -q "keep me" "$HOME/.codex/AGENTS.md"
  run "$VERIFY"
  [ "$status" -eq 0 ]
}

@test "unattended panes: install lists the committee and office-art roots in sib's allowlist once, and moves the old /tmp root" {
  mkdir -p "$HOME/.local/share/cmux/orch"
  sed 's|^- root: .*|- root: /private/tmp/agent-scout   # old default|' "$FW/cmux/seeds/agent-committee.md" \
    > "$HOME/.local/share/cmux/orch/agent-committee.md"
  "$INSTALL" >/dev/null
  grep -qx '~/.local/share/cmux/hr/panes/\*' "$HOME/.config/sib/trusted-dirs"
  grep -qx -- '- root: ~/.local/share/cmux/hr/panes' "$HOME/.local/share/cmux/orch/agent-committee.md"
  "$INSTALL" >/dev/null
  [ "$(grep -c 'hr/panes' "$HOME/.config/sib/trusted-dirs")" -eq 1 ]
  [ "$(grep -c 'office-art/jobs' "$HOME/.config/sib/trusted-dirs")" -eq 1 ]
  mkdir -p "$HOME/.local/share/cmux/hr/panes" "$HOME/.local/share/cmux/office-art/jobs"
  SIB_EXTRA_PATH= run "$HOME/.local/bin/sib" trusted "$HOME/.local/share/cmux/hr/panes/2026-11-25-jobs-propose-1"
  [ "$status" -eq 0 ]
  SIB_EXTRA_PATH= run "$HOME/.local/bin/sib" trusted "$HOME/.local/share/cmux/office-art/jobs/office-art-12345"
  [ "$status" -eq 0 ]
}
