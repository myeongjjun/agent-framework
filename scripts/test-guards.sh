#!/usr/bin/env bash
#
# test-guards.sh — verification harness for the ClickHouse and prod-kubectl
# guard hooks under hooks/clickhouse and hooks/general. Each guard is fed a
# Claude-shaped JSON payload over stdin; the test asserts that the hook either
# allows the command (exit 0) or blocks it (exit 2).
#
# Hermetic: no live ClickHouse / kubectl / filesystem mutation. Each test only
# invokes the guard with a synthetic command string.
#
# Usage:
#   ./scripts/test-guards.sh           # run all guard tests
#   ./scripts/test-guards.sh --verbose # show per-test details
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DDL_HOOK="${ROOT_DIR}/hooks/clickhouse/guard-clickhouse-ddl.sh"
CLUSTER_HOOK="${ROOT_DIR}/hooks/clickhouse/guard-clickhouse-cluster.sh"
FS_HOOK="${ROOT_DIR}/hooks/clickhouse/guard-clickhouse-fs.sh"
KUBECTL_HOOK="${ROOT_DIR}/hooks/general/guard-prod-kubectl.sh"

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

PASS=0
FAIL=0
FAILURES=()

# --- helpers ----------------------------------------------------------------

# run_hook <hook-path> <command-string> -> echoes exit_code
run_hook() {
  local hook="$1" cmd="$2" payload status
  payload="$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  set +e
  printf '%s\n' "$payload" | bash "$hook" >/dev/null 2>&1
  status=$?
  set -e
  printf '%d' "$status"
}

# expect_block <label> <hook> <command>
expect_block() {
  local label="$1" hook="$2" cmd="$3" status
  status="$(run_hook "$hook" "$cmd")"
  if [[ "$status" == "2" ]]; then
    PASS=$((PASS+1))
    if [[ "$VERBOSE" == "1" ]]; then
      printf '  ok  %s\n' "$label"
    fi
  else
    FAIL=$((FAIL+1))
    FAILURES+=("BLOCK expected, got exit=${status}: ${label} | cmd: ${cmd}")
    printf '  FAIL %s (exit=%s, expected 2)\n' "$label" "$status"
  fi
  return 0
}

# expect_allow <label> <hook> <command>
expect_allow() {
  local label="$1" hook="$2" cmd="$3" status
  status="$(run_hook "$hook" "$cmd")"
  if [[ "$status" == "0" ]]; then
    PASS=$((PASS+1))
    if [[ "$VERBOSE" == "1" ]]; then
      printf '  ok  %s\n' "$label"
    fi
  else
    FAIL=$((FAIL+1))
    FAILURES+=("ALLOW expected, got exit=${status}: ${label} | cmd: ${cmd}")
    printf '  FAIL %s (exit=%s, expected 0)\n' "$label" "$status"
  fi
  return 0
}

section() { printf '\n== %s ==\n' "$1"; }

# --- DDL guard tests --------------------------------------------------------

section "guard-clickhouse-ddl.sh"

# Pre-existing rules (regression coverage)
expect_block "DROP TABLE blocked"           "$DDL_HOOK" "clickhouse-client --query 'DROP TABLE foo'"
expect_block "TRUNCATE TABLE blocked"       "$DDL_HOOK" "clickhouse-client -q 'TRUNCATE TABLE foo'"
expect_block "ALTER ... DELETE blocked"     "$DDL_HOOK" "clickhouse-client --query 'ALTER TABLE foo DELETE WHERE 1=1'"
expect_block "DROP PARTITION blocked"       "$DDL_HOOK" "clickhouse-client --query \"ALTER TABLE foo DROP PARTITION '2026-01-01'\""

# New: DETACH/ATTACH
expect_block "DETACH TABLE blocked"         "$DDL_HOOK" "clickhouse-client --query 'DETACH TABLE foo'"
expect_block "DETACH DATABASE blocked"      "$DDL_HOOK" "clickhouse-client --query 'DETACH DATABASE bar'"
expect_block "ATTACH TABLE blocked"         "$DDL_HOOK" "clickhouse-client --query 'ATTACH TABLE foo'"
expect_block "ATTACH DATABASE blocked"      "$DDL_HOOK" "clickhouse-client --query 'ATTACH DATABASE bar'"
expect_block "DETACH PARTITION blocked"     "$DDL_HOOK" "clickhouse-client --query \"ALTER TABLE foo DETACH PARTITION '2026-01-01'\""
expect_block "ATTACH PARTITION blocked"     "$DDL_HOOK" "clickhouse-client --query \"ALTER TABLE foo ATTACH PARTITION '2026-01-01'\""

# New: RBAC
expect_block "DROP USER blocked"            "$DDL_HOOK" "clickhouse-client --query 'DROP USER analyst'"
expect_block "DROP ROLE blocked"            "$DDL_HOOK" "clickhouse-client --query 'DROP ROLE readonly'"
expect_block "REVOKE blocked"               "$DDL_HOOK" "clickhouse-client --query 'REVOKE SELECT ON db.* FROM analyst'"

# New: ALTER COLUMN forms
expect_block "DROP COLUMN blocked"          "$DDL_HOOK" "clickhouse-client --query 'ALTER TABLE foo DROP COLUMN bar'"
expect_block "CLEAR COLUMN blocked"         "$DDL_HOOK" "clickhouse-client --query 'ALTER TABLE foo CLEAR COLUMN bar'"
expect_block "MODIFY COLUMN blocked"        "$DDL_HOOK" "clickhouse-client --query 'ALTER TABLE foo MODIFY COLUMN bar Int32'"
expect_block "RENAME COLUMN blocked"        "$DDL_HOOK" "clickhouse-client --query 'ALTER TABLE foo RENAME COLUMN bar TO baz'"

# Allow paths: read-only, non-clickhouse commands
expect_allow "SELECT allowed"               "$DDL_HOOK" "clickhouse-client --query 'SELECT count() FROM foo'"
expect_allow "SHOW TABLES allowed"          "$DDL_HOOK" "clickhouse-client --query 'SHOW TABLES'"
expect_allow "non-clickhouse command"       "$DDL_HOOK" "ls /tmp"
expect_allow "DESCRIBE allowed"             "$DDL_HOOK" "clickhouse-client --query 'DESCRIBE TABLE foo'"
expect_allow "git commit mentioning DROP"   "$DDL_HOOK" "git commit -m 'add DROP TABLE coverage to clickhouse guard'"
expect_allow "git log filtering"            "$DDL_HOOK" "git log --grep='DROP USER' clickhouse-client"

# --- Cluster guard tests ----------------------------------------------------

section "guard-clickhouse-cluster.sh"

# Pre-existing
expect_block "ON CLUSTER blocked"           "$CLUSTER_HOOK" "clickhouse-client --query 'CREATE TABLE foo ON CLUSTER prod (...)'"
expect_block "SYSTEM STOP REPLICATED SENDS" "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM STOP REPLICATED SENDS'"
expect_block "SYSTEM SHUTDOWN blocked"      "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM SHUTDOWN'"

# New: cache invalidation
expect_block "DROP MARK CACHE blocked"      "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM DROP MARK CACHE'"
expect_block "DROP FILESYSTEM CACHE blocked" "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM DROP FILESYSTEM CACHE'"
expect_block "DROP UNCOMPRESSED CACHE"      "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM DROP UNCOMPRESSED CACHE'"

# New: config reload
expect_block "RELOAD CONFIG blocked"        "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM RELOAD CONFIG'"
expect_block "RELOAD USERS blocked"         "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM RELOAD USERS'"
expect_block "RELOAD DICTIONARY blocked"    "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM RELOAD DICTIONARY mydict'"

# New: lifecycle / replica state
expect_block "RESTART DISK blocked"         "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM RESTART DISK default'"
expect_block "RESTORE REPLICA blocked"      "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM RESTORE REPLICA foo'"
expect_block "DROP TABLE REPLICA blocked"   "$CLUSTER_HOOK" "clickhouse-client --query \"SYSTEM DROP TABLE REPLICA 'r1' FROM TABLE foo\""
expect_block "UNFREEZE blocked"             "$CLUSTER_HOOK" "clickhouse-client --query \"SYSTEM UNFREEZE WITH NAME 'snap'\""
expect_block "SUSPEND blocked"              "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM SUSPEND FOR 5 SECOND'"
expect_block "JEMALLOC blocked"             "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM JEMALLOC FLUSH PROFILE'"
expect_block "ENABLE FAILPOINT blocked"     "$CLUSTER_HOOK" "clickhouse-client --query 'SYSTEM ENABLE FAILPOINT replication'"

# Allow paths
expect_allow "SELECT system.parts allowed"  "$CLUSTER_HOOK" "clickhouse-client --query 'SELECT * FROM system.parts'"
expect_allow "non-clickhouse command"       "$CLUSTER_HOOK" "ls /tmp"
expect_allow "SYSTEM read-only"             "$CLUSTER_HOOK" "clickhouse-client --query 'SELECT * FROM system.replication_queue'"
expect_allow "git commit mentioning SYSTEM" "$CLUSTER_HOOK" "git commit -m 'guard SYSTEM SHUTDOWN on clickhouse'"

# --- Filesystem guard tests -------------------------------------------------

section "guard-clickhouse-fs.sh"

# Block: direct mutation of CH data/config
expect_block "rm /var/lib/clickhouse/data"  "$FS_HOOK" "rm -rf /var/lib/clickhouse/data/foo"
expect_block "rm /var/lib/clickhouse/store" "$FS_HOOK" "sudo rm -rf /var/lib/clickhouse/store/abc"
expect_block "mv /var/lib/clickhouse"       "$FS_HOOK" "mv /tmp/foo /var/lib/clickhouse/data/db/table/foo"
expect_block "chmod /etc/clickhouse-server" "$FS_HOOK" "chmod 644 /etc/clickhouse-server/config.xml"
expect_block "sed -i config"                "$FS_HOOK" "sed -i 's/foo/bar/' /etc/clickhouse-server/users.xml"
expect_block "echo > config"                "$FS_HOOK" "echo '<config/>' > /etc/clickhouse-server/config.d/x.xml"
expect_block "tee config"                   "$FS_HOOK" "echo '<x/>' | tee /etc/clickhouse-server/config.d/y.xml"
expect_block "cp into data"                 "$FS_HOOK" "cp /tmp/foo.bin /var/lib/clickhouse/data/db/table/"
expect_block "find -delete on data"         "$FS_HOOK" "find /var/lib/clickhouse/data -name '*.tmp' -delete"
expect_block "mkdir under data"             "$FS_HOOK" "mkdir -p /var/lib/clickhouse/data/db/table"
expect_block "rm /var/lib/clickhouse-keeper" "$FS_HOOK" "rm -rf /var/lib/clickhouse-keeper/snapshot"
expect_block "shred config"                 "$FS_HOOK" "shred -u /etc/clickhouse-server/users.xml"
expect_block "ln -sf into data"             "$FS_HOOK" "ln -sf /dev/null /var/lib/clickhouse/data/db/table/x"

# Allow: read-only, redirect to non-sensitive, no sensitive path
expect_allow "ls /var/lib/clickhouse"       "$FS_HOOK" "ls -la /var/lib/clickhouse/data"
expect_allow "du -sh data"                  "$FS_HOOK" "du -sh /var/lib/clickhouse/data"
expect_allow "find without -delete"         "$FS_HOOK" "find /var/lib/clickhouse/data -name '*.bin'"
expect_allow "cat to /tmp"                  "$FS_HOOK" "cat /etc/clickhouse-server/config.xml > /tmp/snap.xml"
expect_allow "rm /tmp"                      "$FS_HOOK" "rm /tmp/foo"
expect_allow "stat sensitive path"          "$FS_HOOK" "stat /var/lib/clickhouse/data"
expect_allow "head config"                  "$FS_HOOK" "head -n 50 /etc/clickhouse-server/config.xml"
expect_allow "no sensitive path"            "$FS_HOOK" "rm -rf /tmp/build"
expect_allow "git commit referencing path"  "$FS_HOOK" "git commit -m 'guard mutation of /var/lib/clickhouse/data'"

# --- prod kubectl guard tests -----------------------------------------------

section "guard-prod-kubectl.sh"

# Block: high-risk mutating verbs on prod context
expect_block "apply to prod context"        "$KUBECTL_HOOK" "kubectl --context=prod apply -f deploy.yaml"
expect_block "delete pod prod"              "$KUBECTL_HOOK" "kubectl --context=prod delete pod foo"
expect_block "patch deployment prod ns"     "$KUBECTL_HOOK" "kubectl -n prod-app patch deployment api -p '{}'"
expect_block "scale prod"                   "$KUBECTL_HOOK" "kubectl --context=prod-cluster scale deploy api --replicas=0"
expect_block "edit prod"                    "$KUBECTL_HOOK" "kubectl --context=prod edit deploy api"
expect_block "replace prod"                 "$KUBECTL_HOOK" "kubectl --context=prod replace -f api.yaml"
expect_block "rollout restart prod"         "$KUBECTL_HOOK" "kubectl --context=prod rollout restart deploy/api"
expect_block "kubectl cp into prod pod"     "$KUBECTL_HOOK" "kubectl --context=prod cp ./foo pod/api:/tmp/foo"
expect_block "create on prod"               "$KUBECTL_HOOK" "kubectl --context=prod create -f svc.yaml"
expect_block "drain prod node"              "$KUBECTL_HOOK" "kubectl --context=prod drain node-1"
expect_block "exec with DROP on prod"       "$KUBECTL_HOOK" "kubectl --context=prod exec ch-0 -- clickhouse-client -q 'DROP TABLE foo'"
expect_block "exec with REVOKE on prod"     "$KUBECTL_HOOK" "kubectl --context=prod exec ch-0 -- clickhouse-client -q 'REVOKE SELECT ON db.* FROM analyst'"
expect_block "exec with SYSTEM on prod"     "$KUBECTL_HOOK" "kubectl --context=prod exec ch-0 -- clickhouse-client -q 'SYSTEM RELOAD CONFIG'"

# Allow: get/describe/logs and non-prod
expect_allow "get pods on prod"             "$KUBECTL_HOOK" "kubectl --context=prod get pods"
expect_allow "describe deployment prod"     "$KUBECTL_HOOK" "kubectl --context=prod describe deployment api"
expect_allow "logs prod"                    "$KUBECTL_HOOK" "kubectl --context=prod logs ch-0"
expect_allow "exec read-only on prod"       "$KUBECTL_HOOK" "kubectl --context=prod exec ch-0 -- clickhouse-client -q 'SELECT 1'"
expect_allow "apply on staging context"     "$KUBECTL_HOOK" "kubectl --context=staging apply -f deploy.yaml"
expect_allow "delete pod on dev"            "$KUBECTL_HOOK" "kubectl --context=dev delete pod foo"
expect_allow "non-kubectl"                  "$KUBECTL_HOOK" "echo prod apply"
expect_allow "kubectl get with prod label"  "$KUBECTL_HOOK" "kubectl --context=staging get pods -l env=prod"
expect_allow "staging apply prod file"      "$KUBECTL_HOOK" "kubectl --context=staging apply -f prod-config.yaml"

# --- summary ---------------------------------------------------------------

printf '\n== summary ==\n'
printf '  pass: %d\n  fail: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
