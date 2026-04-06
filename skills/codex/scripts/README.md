# Codex Helper Scripts

Helper scripts for integrating handoff entries with Codex CLI delegation.

## Scripts Overview

### 1. `codex-with-context.sh`

Delegate tasks to Codex with context from an existing handoff entry.

**Use when:**
- You already have a handoff entry created (via `/handoff` or manually)
- You want to preserve full Claude Code conversation context
- Session is long and you need to delegate mechanical work

**Quick start:**
```bash
# In Claude Code, create handoff entry first
/handoff

# Then use this script to delegate
./codex-with-context.sh "Implement the authentication changes"
```

**Features:**
- ✅ Reads latest `.agent/entry-*.md` automatically
- ✅ Includes full context in Codex prompt
- ✅ Configurable model, sandbox, reasoning level
- ✅ Inline or reference modes
- ✅ Dry-run support

### 2. `codex-auto-handoff.sh`

Auto-generate handoff entry from current project state and delegate to Codex.

**Use when:**
- You don't have a handoff entry yet
- You want quick context collection and delegation
- You're starting a new task and want to preserve state

**Quick start:**
```bash
# Just describe the task - entry is auto-generated
./codex-auto-handoff.sh "Refactor the authentication system"
```

**Features:**
- ✅ Auto-collects git status, branch, changed files
- ✅ Creates `.agent/entry-YYYYMMDD-HHMMSS-KST.md`
- ✅ Updates `.agent/LATEST.md` pointer
- ✅ Delegates to Codex with generated context
- ✅ Customizable objective, constraints, completed work

---

## Installation

### Option 1: Project-local (recommended)

Copy scripts to your project's `.agent/` directory:

```bash
# From the skill directory
cp scripts/codex-*.sh /path/to/your/project/.agent/

# Make executable
chmod +x /path/to/your/project/.agent/codex-*.sh

# Use from project root
cd /path/to/your/project
.agent/codex-with-context.sh "task"
```

### Option 2: Global installation

Add scripts to your PATH:

```bash
# Copy to ~/bin or /usr/local/bin
cp scripts/codex-*.sh ~/bin/

# Make executable
chmod +x ~/bin/codex-*.sh

# Use from anywhere
codex-with-context.sh "task"
```

### Option 3: Symlink from skill directory

```bash
# From your project root
ln -s /path/to/skills/codex/scripts/codex-with-context.sh .agent/
ln -s /path/to/skills/codex/scripts/codex-auto-handoff.sh .agent/

# Use from project root
.agent/codex-with-context.sh "task"
```

---

## Usage Examples

### Example 1: Using existing handoff entry

**Scenario:** You've been discussing authentication for 50 messages in Claude Code. Now delegate implementation to Codex.

```bash
# Step 1: In Claude Code, create handoff entry
/handoff

# Step 2: Delegate to Codex
./codex-with-context.sh "Implement JWT authentication as discussed"

# Step 3: Review results when Codex completes
```

### Example 2: Auto-generate entry with constraints

**Scenario:** Quick delegation with explicit constraints.

```bash
./codex-auto-handoff.sh \
  --objective "Add search functionality" \
  --constraints "Do not modify tests/, Keep API v2 compatible" \
  "Implement search API in src/api/search.ts"
```

### Example 3: Read-only analysis

**Scenario:** Have Codex review code without making changes.

```bash
./codex-with-context.sh --read-only \
  "Review the authentication code for security issues"
```

### Example 4: Use specific entry file

**Scenario:** Multiple entries exist, want to use a specific one.

```bash
./codex-with-context.sh \
  --entry .agent/entry-20251223-143000-KST.md \
  "Continue the refactoring work"
```

### Example 5: Reference mode (smaller prompt)

**Scenario:** Entry is large, use reference mode to keep prompt small.

```bash
./codex-with-context.sh --reference \
  "Continue work from handoff entry"
```

### Example 6: Dry run (preview)

**Scenario:** See what would be executed without running.

```bash
./codex-with-context.sh --dry-run "Test task"
```

---

## Advanced Usage

### Custom configuration

Both scripts support customization via flags:

```bash
# Use different model
./codex-with-context.sh -m gpt-5.1 "task"

# Lower reasoning effort (faster)
./codex-with-context.sh -r high "simple task"

# Different sandbox mode
./codex-with-context.sh -s read-only "review code"
```

### Combining with other tools

**With git hooks:**

Create `.git/hooks/pre-commit`:
```bash
#!/bin/bash
# Auto-generate handoff entry before commit

if [ -d .ai ]; then
  ./codex-auto-handoff.sh --dry-run \
    --objective "Pre-commit context" \
    "Current state before commit" > /dev/null
fi
```

**With CI/CD:**

```yaml
# .github/workflows/codex-review.yml
name: Codex Code Review

on: [pull_request]

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Review with Codex
        run: |
          ./codex-auto-handoff.sh --read-only \
            "Review this PR for potential issues"
```

**With make:**

```makefile
# Makefile
.PHONY: codex-implement
codex-implement:
	./.agent/codex-with-context.sh "Implement next steps from handoff"

.PHONY: codex-review
codex-review:
	./.agent/codex-auto-handoff.sh --read-only \
		"Review current changes for issues"
```

---

## Troubleshooting

### Script not found

**Error:** `./codex-with-context.sh: No such file or directory`

**Solutions:**
1. Check you're in the correct directory
2. Ensure scripts are in `.agent/` or your PATH
3. Use full path: `/full/path/to/codex-with-context.sh`

### Permission denied

**Error:** `Permission denied: ./codex-with-context.sh`

**Solution:**
```bash
chmod +x ./codex-with-context.sh
chmod +x ./codex-auto-handoff.sh
```

### No handoff entry found

**Error:** `Error: No handoff entry found`

**Solutions:**
1. Create entry first: `/handoff` in Claude Code
2. Use auto-handoff: `./codex-auto-handoff.sh "task"`
3. Specify entry file: `./codex-with-context.sh -e path/to/entry.md "task"`

### Codex CLI not found

**Error:** `codex: command not found`

**Solutions:**
1. Install Codex CLI: see https://github.com/openai/codex
2. Ensure `codex` is in your PATH
3. Verify installation: `codex --version`

### Entry too large

**Warning:** `Handoff entry is large (10000 bytes > 8192 bytes)`

**Solutions:**
1. Use `--reference` mode: `./codex-with-context.sh --reference "task"`
2. Summarize the entry (edit `.agent/entry-*.md`)
3. Split into multiple smaller entries
4. Move large diffs to separate `.diff` files

---

## Script Options Reference

### codex-with-context.sh

```
Usage: codex-with-context.sh [OPTIONS] "task description"

OPTIONS:
  -h, --help              Show help
  -e, --entry FILE        Use specific entry (default: latest)
  -m, --model MODEL       Model (default: gpt-5.2)
  -s, --sandbox MODE      Sandbox (default: workspace-write)
  -r, --reasoning LEVEL   Reasoning (default: xhigh)
  --read-only             Read-only sandbox
  --inline                Include entry inline (default)
  --reference             Reference entry by path
  --dry-run               Show command without executing
```

### codex-auto-handoff.sh

```
Usage: codex-auto-handoff.sh [OPTIONS] "task description"

OPTIONS:
  -h, --help                  Show help
  -o, --objective TEXT        Primary objective
  -c, --constraints TEXT      Constraints (comma-separated)
  --completed TEXT            Work completed (comma-separated)
  -m, --model MODEL           Model (default: gpt-5.2)
  -s, --sandbox MODE          Sandbox (default: workspace-write)
  -r, --reasoning LEVEL       Reasoning (default: xhigh)
  --read-only                 Read-only sandbox
  --skip-entry                Skip entry creation
  --dry-run                   Preview entry without executing
```

---

## Best Practices

### 1. Create handoff entry in Claude Code first

For maximum context preservation:
```bash
# In Claude Code
/handoff

# Then delegate
./codex-with-context.sh "implement feature"
```

### 2. Use meaningful task descriptions

❌ Bad:
```bash
./codex-with-context.sh "do it"
```

✅ Good:
```bash
./codex-with-context.sh "Implement JWT authentication with refresh tokens in src/auth/, following the design we discussed"
```

### 3. Specify constraints explicitly

```bash
./codex-auto-handoff.sh \
  --constraints "Do not modify tests/, Keep API v2 compatible, Preserve database schema" \
  "Refactor user model"
```

### 4. Use read-only for analysis

```bash
# Review without modifying files
./codex-with-context.sh --read-only "Review for security issues"
```

### 5. Dry run before important tasks

```bash
# Preview what will be executed
./codex-with-context.sh --dry-run "critical refactor"

# Review the command, then run for real
./codex-with-context.sh "critical refactor"
```

---

## Integration with Claude Code Skills

These scripts complement Claude Code skills:

**Workflow:**

1. **Claude Code** - Discussion, planning, decision-making
   ```
   User: "Let's design the authentication system"
   Claude: [discusses options, makes decisions]
   ```

2. **handoff skill** - Create structured context
   ```
   /handoff
   ```

3. **codex-with-context.sh** - Delegate implementation
   ```bash
   ./codex-with-context.sh "Implement authentication as designed"
   ```

4. **Claude Code** - Review results, continue next phase
   ```
   User: "Review the implementation"
   Claude: [reviews Codex output, suggests improvements]
   ```

---

## Future Enhancements

Planned features:

- [ ] Auto-detect when to use handoff (context limit warning)
- [ ] Interactive mode for selecting from multiple entries
- [ ] Entry diff viewer before delegation
- [ ] Post-codex result handoff auto-generation
- [ ] Integration with Claude Code as native skill commands
- [ ] Template support for different project types
- [ ] Entry compression/summarization

---

## Support

For issues or questions:

1. Check this README and script `--help` output
2. Review `references/handoff-integration.md` for detailed integration guide
3. Consult `SKILL.md` for skill documentation
4. Open an issue in the skill repository

---

## License

These scripts are part of the codex skill for Claude Code.
See the skill LICENSE file for details.
