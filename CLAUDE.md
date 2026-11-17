# cadenway-ops: Claude Code instructions

@AGENTS.md

Start Claude Code in this checkout to activate its project settings and hooks. Rules in
`.claude/rules/` without `paths` load at startup. Read the affected files to load their scoped
rules. The [Claude tooling guide](.claude/README.md) lists agents, commands, skills and
[hook coverage](.claude/README.md#hooks). Follow the shared rules across tools and resolve any
hook refusal without bypassing it.

Use `/cw-quality` for the [full local gate](docs/development.md#full-local-quality-gate).
Read linked reference material on demand. For read-only context from sibling repositories, attach
only the required peers with `--add-dir` (for example, api-gateway, task-service, webapp and billing-service).
Make changes in the owning checkout and pull request.
