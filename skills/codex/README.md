# Codex Skill for Claude Code

A Claude Code skill for delegating complex coding tasks to Codex CLI (OpenAI's GPT-5+ reasoning models).

## Overview

This skill enables seamless integration between Claude Code and Codex CLI, allowing you to:

- 🧠 **Leverage high-reasoning models** - Use GPT-5.4 with xhigh reasoning for complex tasks
- 🔄 **Preserve context across agents** - Hand off work between Claude and Codex without losing information
- ⚡ **Optimize for execution** - Use Codex for mechanical bulk edits, Claude for decision-making
- 📦 **Session continuity** - Resume Codex sessions and maintain conversation history

## Quick Start

### Basic Usage

In Claude Code, simply mention Codex:

```
User: "Use codex to implement JWT authentication"
```

Claude will automatically invoke Codex with appropriate configuration.

### With Context Handoff

For longer sessions or when you need to preserve full context:

```
User: "/handoff"  (create context entry)
User: "Use codex with this context to implement the authentication"
```

Claude will read the handoff entry and include it in the Codex prompt.

## Features

### 1. Dispatch Modes

Two dispatch modes are supported (auto-detected):

- **Mode A: cmux+zmx** (recommended) — Persistent Codex sessions via zmx, controlled through cmux split pane. Context retained across prompts. Requires `cmux` automation mode + `zmx`.
- **Mode B: codex exec** (fallback) — Non-interactive execution for environments without cmux/zmx.

### 2. High-Reasoning Models

- **GPT-5.4** (default) - Latest model with maximum capability
- **xhigh reasoning** - Maximum capability for complex tasks
- **Workspace-write** sandbox - Full file modification access

### 2. Handoff Integration

**Problem:** Codex runs independently and doesn't have access to Claude Code's conversation history.

**Solution:** Use handoff entries (`.agent/entry-*.md`) as a context bridge.

**Workflow:**
```
Claude Code → handoff entry → Codex (with context) → results → Claude Code
```

See [Handoff Integration Guide](references/handoff-integration.md) for details.

### 3. Helper Scripts

Pre-built scripts for common workflows:

**`codex-with-context.sh`** - Delegate with existing handoff entry
```bash
./codex-with-context.sh "Implement authentication changes"
```

**`codex-auto-handoff.sh`** - Auto-generate entry and delegate
```bash
./codex-auto-handoff.sh "Refactor authentication system"
```

See [Scripts README](scripts/README.md) for full documentation.

### 4. Session Management

- **Resume sessions** - Continue previous Codex conversations
- **Auto-save** - All sessions automatically persisted
- **Cross-restart** - Sessions survive Claude Code restarts

## Installation

This skill is designed to work within Claude Code's skill system.

### Prerequisites

1. **Codex CLI** - Install from OpenAI
   ```bash
   # Verify installation
   codex --version
   ```

2. **Authentication** - Login to Codex
   ```bash
   codex login
   ```

3. **handoff skill** (optional but recommended) - For context preservation
   ```bash
   # Available in Claude Code skill directory
   ```

### Setup

1. **Enable skill** in Claude Code
   - Skill should auto-load from skills directory

2. **Install helper scripts** (optional)
   ```bash
   # Copy to your project
   cp scripts/codex-*.sh /path/to/project/.agent/
   chmod +x /path/to/project/.agent/codex-*.sh
   ```

## Usage Examples

### Example 1: Simple Delegation

**User:** "Use codex to implement a binary search tree in Rust"

Claude will:
1. Detect "use codex" trigger phrase
2. Invoke codex with appropriate config
3. Return results to user

### Example 2: Long Session Handoff

**User:** *After 50 messages of discussion about authentication*
> "We've discussed the JWT auth design for a while. Create a handoff and delegate implementation to codex."

Claude will:
1. Use `/handoff` to create context entry
2. Include entry in codex prompt
3. Codex implements with full context
4. Results returned for Claude's review

### Example 3: Bulk Refactoring

**User:** "Rename userId to accountId across 47 files"

Claude will:
1. Create handoff with constraints (don't modify tests/, preserve types)
2. Delegate to codex for mechanical refactoring
3. Review results when complete

### Example 4: Session Continuation

**User:** "Continue with codex - add unit tests for the BST"

Claude will:
1. Detect "continue" keyword
2. Use `codex exec resume --last`
3. Codex continues from previous session

## Trigger Phrases

The skill activates on:

- "use codex"
- "ask codex"
- "run codex"
- "call codex"
- "codex cli"
- "GPT-5 reasoning"
- "OpenAI reasoning"
- "continue with codex"
- "resume codex session"

## Configuration

### Default Settings

```bash
# Model
-m gpt-5.4

# Sandbox (allows file modifications)
-s workspace-write

# Reasoning effort (balanced)
-c model_reasoning_effort=high

# Web search (enabled for research)
--enable web_search_request
```

### Customization

Users can request different configurations:

```
"Use codex with read-only sandbox to review this code"
"Use codex with high reasoning (not xhigh) for faster results"
"Use codex without web search for this task"
```

## Handoff Integration

### Why Handoff?

When delegating from Claude Code to Codex:
- ❌ **Problem**: Context loss - Codex doesn't see Claude's conversation
- ✅ **Solution**: Handoff entry - Structured context in `.agent/entry-*.md`

### Quick Handoff Workflow

```bash
# 1. In Claude Code, create handoff entry
/handoff

# 2. Delegate to Codex (Claude does this automatically)
# or manually using helper script:
./codex-with-context.sh "implement feature"

# 3. Review results in Claude Code
```

### What's in a Handoff Entry?

- **Project snapshot** - Git status, branch, changed files
- **Objective** - Clear goal and definition of done
- **Constraints** - What NOT to change (critical!)
- **Decisions made** - Design choices and rationale
- **Work completed** - What's already done
- **Next steps** - Ordered, actionable tasks for Codex
- **Verification commands** - How to test/validate

### Resources

- [Handoff Integration Guide](references/handoff-integration.md) - Comprehensive integration patterns
- [Scripts README](scripts/README.md) - Helper script documentation
- [Session Workflows](references/session-workflows.md) - Session continuation patterns

## Architecture

### Control Plane vs Execution Plane

```
┌─────────────────────────────────────────────┐
│ Control Plane (Claude Code)                │
│ - Decision making                           │
│ - Planning & architecture                   │
│ - Tradeoff analysis                         │
│ - User interaction                          │
└─────────────────┬───────────────────────────┘
                  │
                  │ handoff entry
                  │ (.agent/entry-*.md)
                  ▼
┌─────────────────────────────────────────────┐
│ Execution Plane (Codex CLI)                │
│ - Code implementation                       │
│ - Mechanical edits                          │
│ - Bulk refactoring                          │
│ - Diff/patch generation                     │
└─────────────────┬───────────────────────────┘
                  │
                  │ results
                  ▼
┌─────────────────────────────────────────────┐
│ Control Plane (Claude Code)                │
│ - Review results                            │
│ - Continue next phase                       │
└─────────────────────────────────────────────┘
```

### When to Use Each

**Use Claude Code for:**
- Architectural decisions
- Design discussions
- Tradeoff analysis
- User clarification
- Code review

**Use Codex for:**
- Bulk refactoring (rename across 50 files)
- Mechanical edits (update all imports)
- Implementation of well-defined tasks
- Diff/patch generation
- Large-scale code transformations

## Best Practices

### 1. Create Handoff for Long Sessions

When your Claude session > 40 messages or approaching context limits:
```
/handoff  # Preserve context before delegating
```

### 2. Specify Constraints Clearly

In handoff entries, always include what NOT to change:
```markdown
### 3) Constraints / Do not change
- Do not modify tests/ directory
- Keep API v2 backward compatible
- Preserve database schema
```

### 3. Make Next Steps Actionable

Provide clear, ordered steps for Codex:
```markdown
### 8) Next steps
1. Implement JWT signing in src/auth/jwt.ts
   - Expected: generateToken() and verifyToken() functions
2. Add refresh token logic in src/auth/refresh.ts
   - Expected: Refresh endpoint with token rotation
```

### 4. Include Verification Commands

Always provide commands to validate results:
```markdown
### 9) Commands to run
```bash
npm run build
npm test
npx tsc --noEmit
```
```

### 5. Use Read-Only for Analysis

When you just want review/analysis:
```
"Use codex with read-only sandbox to review this code"
```

## Troubleshooting

### Codex Not Found

**Error:** `codex: command not found`

**Solution:**
```bash
# Install Codex CLI
# See: https://github.com/openai/codex

# Verify installation
codex --version
```

### Context Not Preserved

**Issue:** Codex doesn't seem to know what we discussed

**Solution:**
1. Create handoff entry first: `/handoff`
2. Ensure entry includes key decisions in Decisions Made section
3. Use helper script: `./codex-with-context.sh "task"`

### Constraints Violated

**Issue:** Codex modified files it shouldn't

**Solution:**
1. Make constraints explicit in Decisions Made section
2. Emphasize in delegation: "CRITICAL: Respect Decisions Made (constraints)"
3. Review handoff entry format (v1.0.0)

### Entry Too Large

**Warning:** `Handoff entry is large (> 8KB)`

**Solutions:**
1. Summarize conversation instead of full transcript
2. Use file paths instead of full contents
3. Use `--reference` mode in helper script
4. Split into multiple entries

## Files & Documentation

```
codex/
├── SKILL.md                          # Main skill specification
├── README.md                         # This file
├── references/
│   ├── handoff-integration.md        # Handoff integration guide
│   ├── session-workflows.md          # Session patterns
│   ├── advanced-patterns.md          # Advanced usage
│   ├── command-patterns.md           # CLI examples
│   ├── codex-help.md                 # Codex CLI reference
│   └── codex-config.md               # Configuration options
└── scripts/
    ├── README.md                     # Scripts documentation
    ├── codex-with-context.sh         # Delegate with existing entry
    └── codex-auto-handoff.sh         # Auto-generate entry and delegate
```

## Advanced Topics

- [Advanced Patterns](references/advanced-patterns.md) - Complex configurations
- [Command Patterns](references/command-patterns.md) - CLI usage examples
- [Codex Configuration](references/codex-config.md) - Full config options
- [Codex Help](references/codex-help.md) - CLI command reference

## Contributing

Improvements and feedback welcome:

1. Test the skill and scripts with your workflows
2. Report issues or unexpected behavior
3. Suggest improvements to handoff integration
4. Share successful usage patterns

## Version History

- **v2.1.0** - Handoff integration, helper scripts, comprehensive documentation
- **v2.0.0** - GPT-5.2 support, xhigh reasoning
- **v1.x** - Initial Codex CLI integration

## License

See skill LICENSE file for details.

---

**Quick Links:**
- [SKILL.md](SKILL.md) - Complete skill specification
- [Handoff Integration](references/handoff-integration.md) - Context preservation guide
- [Helper Scripts](scripts/README.md) - Automation tools
- [Session Workflows](references/session-workflows.md) - Usage patterns
