# Forking agent-framework

## Quick Summary

Fork `agent-framework` to create your own agent workspace with domain-specific skills. This guide is written so an agent can execute it top to bottom with explicit commands, branches, and verification. Keep framework assets, add your domain assets, and verify after every major step before moving on.

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| `bash` | 4.0+ | Required by the sync/release scripts. macOS ships 3.x by default, so install a newer bash first. |
| `jq` | 1.6+ | Required by `analyze-activity.sh` and several hook/report workflows. |
| `python3` | 3.8+ | Required for `scripts/extract-traces.py`; Python 3.11+ is a good default for new forks. |
| `rsync` | current | Required by `sync-all.sh` Step 5 to deploy the `scripts/orchestrator/` subtree to `~/.orchestrator/`. |
| Claude Code CLI | current | Required if Claude is one of your deployment targets. |
| Codex CLI | current | Optional, but required for `codex`, `collab`, and dual-target workflows. |
| [`cmux`](https://github.com/myeongjjun/cmux) + [`zmx`](https://github.com/myeongjjun/zmx) | current | Required for the orchestrator daemon, conductor, and `handoff-rotate`. Without these the repo still works in a standalone skill/hook mode — the orchestrator scripts just stay dormant until started. |

## Choose Your Path (A/B/C routing)

Run this first:

```bash
export CLAUDE_SKILLS="${HOME}/.claude/skills"
export CODEX_SKILLS="${HOME}/.codex/skills"
export CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

printf 'Claude skills:\n'
ls -1 "$CLAUDE_SKILLS" 2>/dev/null || true

printf '\nClaude hooks from settings.json:\n'
jq '.hooks // {}' "$CLAUDE_SETTINGS" 2>/dev/null || echo '{}'

printf '\nCodex skills:\n'
ls -1 "$CODEX_SKILLS" 2>/dev/null || true
```

Route with this decision:

```bash
if [ -n "$(for d in "$CLAUDE_SKILLS" "$CODEX_SKILLS"; do [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1 -type d; done | head -1)" ]; then
  echo "Go to Section B: existing deployed setup detected."
else
  echo "Go to Section A: no deployed skills detected."
fi
```

If you want to keep your current setup running and adopt the framework in stages, go to Section C instead of doing a full migration now.

Note: `sync-skills.sh` only syncs immediate child directories of `skills/`. Keep skills flat and encode domain ownership in the directory name, for example `skills/payments-triage/`, not `skills/payments/triage/`.

## Section A: Fresh Start

### A.1 Clone your fork

```bash
export FORK_URL="git@github.com:<your-org>/agent-framework.git"
export FORK_ROOT="${HOME}/src/agent-framework"

if [ -d "$FORK_ROOT/.git" ]; then
  git -C "$FORK_ROOT" pull --ff-only
else
  git clone "$FORK_URL" "$FORK_ROOT"
fi
cd "$FORK_ROOT"
```

Verify:

```bash
git remote -v
git status --short
```

If the clone already existed, continue to A.2. Otherwise continue to A.2.

### A.2 Verify framework-only baseline

```bash
cd "$FORK_ROOT"
find skills -maxdepth 1 -mindepth 1 -type d | sort
find hooks -maxdepth 2 -type f | sort
```

The framework repo ships only framework skills and hooks. No domain pack removal needed. Continue to A.3.

### A.3 Add one domain-owned placeholder before first deploy

```bash
cd "$FORK_ROOT"
export DOMAIN="payments"

mkdir -p "skills/${DOMAIN}-triage" "hooks/${DOMAIN}"
```

Verify:

```bash
find "skills/${DOMAIN}-triage" -maxdepth 1 -type d
find "hooks/${DOMAIN}" -maxdepth 1 -type d
```

If you are not ready to add domain assets yet, leave those directories empty and continue to A.4. Otherwise add your first `SKILL.md` and hook scripts before A.4.

### A.4 Deploy the framework baseline

`./scripts/sync-all.sh` runs five steps: skills, hooks, agents, top-level global scripts, and the `scripts/orchestrator/` subtree to `~/.orchestrator/`. Verify each surface landed.

```bash
cd "$FORK_ROOT"
./scripts/sync-all.sh
```

Verify:

```bash
./sync-skills.sh --status
./sync-hooks.sh --status
./sync-agents.sh --status
ls -1 "$HOME/.claude/skills" 2>/dev/null | sort
ls -1 "$HOME/.codex/skills" 2>/dev/null | sort
ls -1 "$HOME/.claude/agents" 2>/dev/null | sort
jq '.hooks // {}' "$HOME/.claude/settings.json" 2>/dev/null || echo '{}'
ls -1 "$HOME/.orchestrator/scripts/orchestrator" 2>/dev/null | head -10 || echo 'orchestrator not deployed (skip if you are not using cmux+zmx)'
```

If deploy fails, fix that before adding more domain content. The orchestrator subtree is only needed if you plan to use `collab`, dispatch, or rotation — the standalone skill/hook path works without it. Otherwise continue to A.5.

### A.5 Initialize ACP in the first project that will use the fork

```bash
cd /path/to/your-project
pwd
ls -a
```

Agent command:

```text
/acp-init
```

Verify:

```bash
ls -ld AGENTS.md CLAUDE.md agent-context agent-context/decisions agent-context/constraints
```

If `AGENTS.md` already exists, `/acp-init` will upgrade it. Otherwise it will initialize ACP from scratch.

### A.6 Tag the baseline, then start observability after a few real sessions

```bash
cd "$FORK_ROOT"
git status --short
./scripts/agent-release.sh tag "Initial fork baseline"
./scripts/agent-release.sh current
```

After you have a few real sessions:

```bash
cd "$FORK_ROOT"
./scripts/analyze-activity.sh --source all --days 7 --report || true
ls -1 "$HOME/.claude/logs/reports" 2>/dev/null | tail -5 || true
```

Agent command:

```text
/observe --days 7
```

Verify:

```bash
ls -1 "$HOME/.claude/logs/proposals" 2>/dev/null | tail -5 || true
```

If no proposal file appears yet, use the fork for a few more sessions and rerun `/observe`. Otherwise continue with `/improve` when you are ready.

## Section B: Migrate Existing Setup (Main Path)

Set these once before starting:

```bash
export DOMAIN="payments"
export FORK_URL="git@github.com:<your-org>/agent-framework.git"
export FORK_ROOT="${HOME}/src/agent-framework"
export CLAUDE_SKILLS="${HOME}/.claude/skills"
export CODEX_SKILLS="${HOME}/.codex/skills"
export CLAUDE_HOOKS="${HOME}/.claude/hooks"
export CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
```

### B.1: Inventory

```bash
printf 'Claude skills:\n'
ls -1 "$CLAUDE_SKILLS" 2>/dev/null || true

printf '\nClaude hooks from settings.json:\n'
jq '.hooks // {}' "$CLAUDE_SETTINGS" 2>/dev/null || echo '{}'

printf '\nCodex skills:\n'
ls -1 "$CODEX_SKILLS" 2>/dev/null || true
```

Verify:

```bash
if [ -n "$(for d in "$CLAUDE_SKILLS" "$CODEX_SKILLS"; do [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1 -type d; done | head -1)" ]; then
  echo "Existing setup found. Continue to B.2."
else
  echo "No deployed skills found. Go to Section A."
fi
```

If the verification says no deployed skills were found, go to Section A. Otherwise continue to B.2.

### B.2: Clone agent-framework

```bash
if [ -d "$FORK_ROOT/.git" ]; then
  git -C "$FORK_ROOT" pull --ff-only
else
  git clone "$FORK_URL" "$FORK_ROOT"
fi
cd "$FORK_ROOT"
```

Verify:

```bash
git remote -v
git status --short
find skills -maxdepth 1 -mindepth 1 -type d | sort
find hooks -maxdepth 2 -type f | sort
```

If the fork does not exist yet, create it first and rerun B.2. Otherwise continue to B.3.

### B.3: Migrate skills

The repo uses a flat `skills/*` layout. Domain-owned skills should be named like `skills/${DOMAIN}-triage/`, `skills/${DOMAIN}-release/`, and so on.

```bash
cd "$FORK_ROOT"

FRAMEWORK_SKILLS="acp-constraint acp-decision acp-init codex collab handoff harness improve observe quick-dashboard takeover"
TEMPLATE_DOMAIN_SKILLS="daily weekly ticket research postmortem ch-ops wiki-edit"

for base in "$CLAUDE_SKILLS" "$CODEX_SKILLS"; do
  [ -d "$base" ] || continue
  for skill_dir in "$base"/*; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"

    case " $FRAMEWORK_SKILLS $TEMPLATE_DOMAIN_SKILLS " in
      *" $skill_name "*) echo "skip known skill: $skill_name" ;;
      *)
        target_dir="skills/${DOMAIN}-${skill_name}"
        if [ -e "$target_dir" ]; then
          echo "skip existing target: $target_dir"
        else
          cp -R "$skill_dir" "$target_dir"
          echo "copied $skill_name -> $target_dir"
        fi
        ;;
    esac
  done
done
```

Verify:

```bash
find skills -maxdepth 1 -mindepth 1 -type d -name "${DOMAIN}-*" | sort
```

If the verification is empty, you had no custom deployed skills to migrate; skip to B.4. Otherwise review the copied directories and continue to B.4.

### B.4: Migrate hooks

```bash
cd "$FORK_ROOT"
mkdir -p "hooks/${DOMAIN}"

FRAMEWORK_HOOKS="guard-prod-kubectl.sh guard-acp-direct-edit.sh guard-deployed-artifact-edit.sh guard-direct-session-control.sh session-start-review.sh"
TEMPLATE_DOMAIN_HOOKS=""  # no example domain hooks in framework repo

jq -r '
  (.hooks // {})
  | to_entries[]
  | .key as $event
  | .value[]
  | (.matcher // "") as $matcher
  | .hooks[]
  | select(.type == "command")
  | [(.command | split("/") | last | split(" ") | .[0]), $event, $matcher, (.timeout // 5 | tostring)]
  | @tsv
' "$CLAUDE_SETTINGS" 2>/dev/null | while IFS=$'\t' read -r hook event matcher timeout; do
  case " $FRAMEWORK_HOOKS $TEMPLATE_DOMAIN_HOOKS " in
    *" $hook "*) echo "skip known hook: $hook" ;;
    *)
      if [ -f "$CLAUDE_HOOKS/$hook" ] && [ ! -f "hooks/${DOMAIN}/${hook}" ]; then
        cp "$CLAUDE_HOOKS/$hook" "hooks/${DOMAIN}/${hook}"
        chmod +x "hooks/${DOMAIN}/${hook}"
        echo "copied hook -> hooks/${DOMAIN}/${hook}"
      fi

      if ! rg -Fq "| ${hook} |" hooks/HOOKS.md; then
        printf '| %s | %s | %s | %s | %s | migrated from legacy setup |\n' \
          "$hook" "$DOMAIN" "$event" "$matcher" "$timeout" >> hooks/HOOKS.md
        echo "registered hook in hooks/HOOKS.md: $hook"
      else
        echo "hook already registered in hooks/HOOKS.md: $hook"
      fi
      ;;
  esac
done
```

Verify:

```bash
find "hooks/${DOMAIN}" -maxdepth 1 -type f -name '*.sh' | sort
rg -n "^\| .* \| ${DOMAIN} \|" hooks/HOOKS.md || true
```

If both verification commands are empty, you had no custom legacy hooks to migrate; skip to B.5. Otherwise continue to B.5.

### B.5: Verify framework-only baseline

The framework repo ships no example domain pack. No removal needed. Continue to B.6.

### B.6: Deploy and verify

`./scripts/sync-all.sh` runs five steps: skills, hooks, agents, top-level global scripts, and the `scripts/orchestrator/` subtree to `~/.orchestrator/`. Verify each surface landed.

```bash
cd "$FORK_ROOT"
./scripts/sync-all.sh
```

Verify:

```bash
./sync-skills.sh --status
./sync-hooks.sh --status
./sync-agents.sh --status
ls -1 "$CLAUDE_SKILLS" 2>/dev/null | sort
ls -1 "$CODEX_SKILLS" 2>/dev/null | sort
ls -1 "$HOME/.claude/agents" 2>/dev/null | sort
jq '.hooks // {}' "$CLAUDE_SETTINGS" 2>/dev/null || echo '{}'
ls -1 "$HOME/.orchestrator/scripts/orchestrator" 2>/dev/null | head -10 || echo 'orchestrator not deployed (skip if you are not using cmux+zmx)'
```

If `sync-skills.sh --status` still shows `deployed only` skills that you do not want, remove those directories from `~/.claude/skills/` and `~/.codex/skills/`, then rerun B.6. Same pattern applies to `sync-agents.sh --status` for stale agent definitions under `~/.claude/agents/`. Otherwise continue to B.7.

### B.7: Initialize ACP

```bash
cd /path/to/your-project
pwd
ls -a
```

Agent command:

```text
/acp-init
```

Verify:

```bash
ls -ld AGENTS.md CLAUDE.md agent-context agent-context/decisions agent-context/constraints
```

If the target project already has `AGENTS.md`, `/acp-init` will upgrade it in place. Otherwise it will initialize ACP from scratch.

### B.8: Tag first release

```bash
cd "$FORK_ROOT"
git status --short
./scripts/agent-release.sh tag "Initial fork baseline"
```

Verify:

```bash
./scripts/agent-release.sh current
./scripts/agent-release.sh list | head -10
```

If the working tree is not clean, commit your migration changes first and rerun B.8. Otherwise continue to B.9.

### B.9: Start observability

Use the fork normally for a few sessions first, then run:

```bash
cd "$FORK_ROOT"
./scripts/analyze-activity.sh --source all --days 7 --report || true
ls -1 "$HOME/.claude/logs/reports" 2>/dev/null | tail -5 || true
```

Agent command:

```text
/observe --days 7
```

Verify:

```bash
ls -1 "$HOME/.claude/logs/proposals" 2>/dev/null | tail -5 || true
```

If no proposal file is created yet, keep using the fork and rerun `/observe` later. Otherwise review proposals with `/improve`.

## Section C: Gradual Adoption

### Phase 1: `sync-skills.sh` only

```bash
export FORK_ROOT="${HOME}/src/agent-framework"
if [ -d "$FORK_ROOT/.git" ]; then
  git -C "$FORK_ROOT" pull --ff-only
else
  git clone git@github.com:<your-org>/agent-framework.git "$FORK_ROOT"
fi
cd "$FORK_ROOT"
./sync-skills.sh --target both --push
```

Verify:

```bash
./sync-skills.sh --status
ls -1 "$HOME/.claude/skills" 2>/dev/null | sort
ls -1 "$HOME/.codex/skills" 2>/dev/null | sort
```

If you only need shared skills first, stop here. Otherwise continue to Phase 2.

### Phase 2: ACP

```bash
cd /path/to/your-project
pwd
ls -a
```

Agent command:

```text
/acp-init
```

Verify:

```bash
ls -ld AGENTS.md CLAUDE.md agent-context agent-context/decisions agent-context/constraints
```

If ACP is working in the target project, continue to Phase 3. Otherwise fix ACP first.

### Phase 3: hooks

> **Note**: `sync-hooks.sh --push` deploys all hook categories by default. Use `--profile <your-domain>` to limit which categories are deployed.
>
> If your existing setup had inline hook commands (not file-based), you will need to manually extract them into `hooks/<your-domain>/<name>.sh` scripts and register them in `hooks/HOOKS.md`.

```bash
cd "${HOME}/src/agent-framework"
./sync-hooks.sh --push
```

Verify:

```bash
./sync-hooks.sh --status
jq '.hooks // {}' "$HOME/.claude/settings.json" 2>/dev/null || echo '{}'
```

If you only need framework guardrails, stop here. Otherwise add your own `hooks/<domain>/` category and continue.

### Phase 4: observability

```bash
cd "${HOME}/src/agent-framework"
./scripts/analyze-activity.sh --source all --days 7 --report || true
ls -1 "$HOME/.claude/logs/reports" 2>/dev/null | tail -5 || true
```

Agent command:

```text
/observe --days 7
```

Verify:

```bash
ls -1 "$HOME/.claude/logs/proposals" 2>/dev/null | tail -5 || true
```

If proposals are useful, continue to Phase 5. Otherwise keep running without the improvement loop for now.

### Phase 5: collaboration

```bash
cd "${HOME}/src/agent-framework"
./sync-skills.sh --target both --push collab codex handoff takeover
git worktree list
```

Agent command:

```text
/collab
```

Verify:

```bash
git worktree list
ls -1 "$HOME/.codex/skills" 2>/dev/null | grep -E 'collab|codex|handoff|takeover' || true
```

If collaboration adds too much process, stop at Phase 4. Otherwise keep the full stack.

## Framework vs Domain Reference

| Layer | Keep or Replace | Paths | Verification |
|-------|-----------------|-------|--------------|
| Framework skills | Keep | `skills/acp-*`, `skills/codex`, `skills/collab`, `skills/handoff`, `skills/harness`, `skills/improve`, `skills/observe`, `skills/quick-dashboard`, `skills/takeover` | `find skills -maxdepth 1 -mindepth 1 -type d | sort` |
| Framework hooks | Keep | `hooks/general/*`, `hooks/observability/*` | `find hooks/general hooks/observability -maxdepth 1 -type f | sort` |
| Your domain skills | Add | `skills/<domain>-*/` | `find skills -maxdepth 1 -mindepth 1 -type d -name '<domain>-*'` |
| Your domain hooks | Add | `hooks/<domain>/` | `find hooks/<domain> -maxdepth 1 -type f -name '*.sh'` |
| New domain skills | Add | Flat `skills/<domain>-*/` directories | `find skills -maxdepth 1 -mindepth 1 -type d -name '<domain>-*'` |
| New domain hooks | Add | `hooks/<domain>/` plus rows in `hooks/HOOKS.md` | `find hooks/<domain> -maxdepth 1 -type f -name '*.sh'` and `rg -n '^\| .* \| <domain> \|' hooks/HOOKS.md` |

## Recommended Customization Order

1. Get a clean framework-only deploy first with `./scripts/sync-all.sh`.
2. Initialize ACP in the first real project with `/acp-init`.
3. Migrate or write one domain-owned skill under a flat `skills/<domain>-*/` name.
4. Add one domain hook category under `hooks/<domain>/` and register it in `hooks/HOOKS.md`.
5. Remove any remaining example domain references from docs and manifests.
6. Tag the baseline with `./scripts/agent-release.sh tag "Initial fork baseline"`.
7. Start `/observe` only after you have enough real usage to generate meaningful traces.
8. Add `/collab` after the single-agent flow is already stable.

## What a Healthy Fork Looks Like

```text
agent-framework/
├── skills/                   # framework skills + your flat domain skills
│   ├── acp-constraint/
│   ├── acp-decision/
│   ├── acp-init/
│   ├── codex/
│   ├── collab/
│   ├── handoff/
│   ├── harness/
│   ├── improve/
│   ├── observe/
│   ├── quick-dashboard/
│   ├── takeover/
│   ├── <domain>-triage/
│   └── <domain>-release/
├── hooks/
│   ├── general/              # framework guards (always deployed)
│   ├── observability/        # framework session-review
│   ├── <domain>/             # your domain hooks
│   └── HOOKS.md              # source of truth for sync-hooks.sh
├── agents/                   # flat Claude Code agent definitions
│   └── approver.md           # framework-provided auto-approver
├── scripts/
│   ├── sync-all.sh           # canonical deploy entry point
│   ├── conductor.sh          # sibling-session dispatch lifecycle
│   ├── orchestrator/         # long-lived daemon subtree (deployed to ~/.orchestrator/)
│   ├── agent-release.sh      # capability versioning / rollback
│   ├── analyze-activity.sh   # trace-report generator
│   ├── extract-traces.py     # unified Claude + Codex transcript extractor
│   └── handoff-rotate.sh     # RAM-compression rotation via orchestrator
├── agent-context/            # ACP: decisions + constraints
│   ├── decisions/
│   └── constraints/
├── configs/                  # optional scaffolding slot (empty in framework)
├── plugins/                  # optional scaffolding slot (empty in framework)
├── templates/                # optional scaffolding slot (empty in framework)
├── sync-skills.sh            # skill sync (Claude / Codex / both)
├── sync-hooks.sh             # hook sync (category + profile)
├── sync-agents.sh            # agent definition sync
├── README.md
├── FORKING.md                # this file
├── AGENTS.md                 # ACP guide for agents running in this repo
└── LICENSE
```
