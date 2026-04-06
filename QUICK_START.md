# Quick Start Guide

## Quick Commands

```bash
# List available skills
./sync-skills.sh --list

# Check sync status (Claude, default)
./sync-skills.sh --status

# Push all skills to Claude (default target)
./sync-skills.sh --push

# Push to Codex
./sync-skills.sh --codex --push

# Push to both targets
./sync-skills.sh --target both --push

# Preview changes (dry run)
./sync-skills.sh --push --dry-run

# Push specific skill
./sync-skills.sh --push codex handoff
```

## Common Workflow

### 1. Edit a skill

```bash
cd ~/projects/agent-framework/skills/codex
vim SKILL.md
# or edit with your preferred editor
```

### 2. Deploy changes

```bash
cd ~/projects/agent-framework
./sync-skills.sh --push codex
```

### 3. Test in Codex/Claude Code

Open Codex/Claude Code and test:
```
User: "Use codex to implement X"
```

### 4. Commit changes

```bash
git add skills/codex/
git commit -m "Update codex skill: add new feature"
git push
```

## Directory Structure

```
agent-framework/
├── sync-skills.sh        ← Sync & deployment script
├── README.md             ← Full documentation
├── QUICK_START.md        ← This file
└── skills/               ← Edit here
    ├── codex/            ← Deployed to ~/.codex/skills/codex and ~/.claude/skills/codex
    ├── handoff/
    └── ...
```

## Development Cycle

```
Edit skill → Deploy → Test → Commit
   ↓           ↓        ↓       ↓
skills/codex  ./sync-skills.sh --push  Codex/Claude  git commit
```

## Key Files

### codex skill
- `skills/codex/SKILL.md` - Main skill spec
- `skills/codex/README.md` - Documentation
- `skills/codex/references/handoff-integration.md` - Handoff guide
- `skills/codex/scripts/` - Helper scripts

### handoff skill
- `skills/handoff/SKILL.md` - Handoff spec

## Troubleshooting

### Skill not loading
```bash
./sync-skills.sh --target both --push codex
# Then restart Codex/Claude Code
```

### Check deployment
```bash
ls -la ~/.codex/skills/codex
ls -la ~/.claude/skills/codex
```

### Verify scripts are executable
```bash
ls -la ~/.codex/skills/codex/scripts/
ls -la ~/.claude/skills/codex/scripts/
# Should show -rwxr-xr-x (set automatically on push)
```

## Tips

- **Always deploy after editing** - Changes in `skills/` don't take effect until pushed
- **Use --dry-run** - Preview changes before deployment
- **Restart Codex/Claude Code** - After pushing to ensure skills reload
- **Use --status** - Quick check of what's drifted

## Full Documentation

- [README.md](README.md) - Complete guide
- [skills/codex/README.md](skills/codex/README.md) - Codex skill docs
- [skills/codex/references/handoff-integration.md](skills/codex/references/handoff-integration.md) - Integration guide

---

**Need help?** Run `./sync-skills.sh --help`
