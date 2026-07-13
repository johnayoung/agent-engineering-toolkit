# agent-engineering-toolkit

Immediately usable artifacts from [jyoung.dev](https://jyoung.dev) essays on engineering practices for AI coding agents. Each tool operationalizes one post's framework — the essay is the argument, the artifact is the move.

## Install

Copy a skill directory into your repo's `.claude/skills/` (project-wide) or `~/.claude/skills/` (all your projects):

```bash
cp -r skills/audit-claude-md /path/to/your-repo/.claude/skills/
```

Each skill's script also runs standalone without Claude Code.

## Artifacts

<!-- artifacts:start -->
| Artifact | What it does | Canonical post |
|---|---|---|
| [`audit-claude-md`](skills/audit-claude-md/) | Inventories your CLAUDE.md loading tiers — always-loaded vs lazy vs skills, @imports expanded, token estimates — then routes every section to the tier that should own it | [How to Structure CLAUDE.md: It's a Loading Policy, Not a Document](https://jyoung.dev/blog/claude-md-context-hierarchy/) |
<!-- artifacts:end -->

Each artifact directory carries an `artifact.json` (name, form, canonical post) and a Grounding section citing its sources. Skills with a `scripts/` directory also run standalone, for example:

```bash
skills/audit-claude-md/scripts/audit-claude-md.sh [target-dir]
```

## License

MIT
