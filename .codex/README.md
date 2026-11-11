# Codex configuration for waypoint-ops

This project mirrors the repository's `.claude/` tooling using Codex-native formats.
`AGENTS.md` remains authoritative. Start Codex in this repository and trust its project configuration.

- `agents/*.toml` contains the specialist roles. They inherit the parent session's permissions.
- `skills/` contains the Codex skills, including equivalents of the Claude Code commands. Invoke the loaded skills as `$wp-*`.
- `rules/` contains the original path-scoped guidance. `config.toml` instructs Codex to read matching rules; Codex does not automatically apply the Claude YAML path selectors.
- `hooks.json` adapts the existing Claude git guard, edit guard and formatter to Codex Bash and `apply_patch` events. The adapters depend on `.claude/hooks/` and are not a complete security boundary: shell-based edits and other tools are not covered by the patch guard. Review and trust the hooks in Codex before relying on them. The formatter runs only where the repository formatter is installed.
- Claude-specific permission allow/deny lists, launch configuration and plugin metadata are not copied: Codex permissions are set by the active session. `config.toml` declares the same MCP servers as `.mcp.json` and selects `gpt-6.1-terra` at high effort for the main session. Specialist files select `gpt-6.1-terra` for Claude Sonnet roles, `gpt-6.1-sol` for Opus roles, and `gpt-6-luna` for Haiku roles, preserving each role's effort. These choices depend on account access and can be overridden by the user.

Check the applicable repository instructions and run the relevant quality gate. Never use a hook refusal as a reason to bypass policy.
