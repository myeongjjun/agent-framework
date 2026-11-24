#!/usr/bin/env bats
# The desk definition reads the local profile's Ask-first areas ahead of Do it, then report.

ROOT="$BATS_TEST_DIRNAME/.."

@test "orch definition: Ask-first areas override Do it, then report" {
  grep -q '^\*Ask-first areas\.\*' "$ROOT/agents/orch.md"
  grep -q 'Ask-first areas` under `## Approvals`' "$ROOT/agents/orch.md"
  grep -q 'this overrides Do it, then report' "$ROOT/agents/orch.md"
  grep -q 'Start it only after the user answers' "$ROOT/agents/orch.md"
}

@test "orch-local seed: has the Ask-first areas field under Approvals" {
  run awk '/^## Approvals/{a=1} a && /Ask-first areas/{print "ok"}' "$ROOT/cmux/seeds/orch-local.md"
  [ "$output" = "ok" ]
}
