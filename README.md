# agent-skills

A collection of skills for agents.

## Note

The skills are not fully tested on different environments. Behavior can change with a different agent harness, operating system, or tool setup.

## Claude

To install a skill, clone the repository and move the skill directory into your Claude configuration:

```sh
git clone git@github.com:akena-engineering/agent-skills.git
mv agent-skills/claude-skills/<skill> .claude/skills/<skill>
```

Use `~/.claude/skills/` for a user-wide install. Use the project `.claude/skills/` for one project only.
