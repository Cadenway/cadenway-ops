# Git and commits

- **Trunk-based on `main`.** `main` is protected: it only receives squash-merged pull requests.
  Never push to it, never merge into it locally.
- **Branch names**: `<type>/<lowercase-kebab-description>`, with a type among `feat`, `fix`, `docs`,
  `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. Put the Waypoint task id
  first in the description when there is one: `feat/way-482-sso-screen`. Waypoint's own Git
  integration links the branch to the task through that id. Never an agent name as a prefix.
- **Commits and PR titles** follow Conventional Commits: `type(scope): subject`, English, imperative,
  lowercase subject, no trailing period, at most 100 characters; `!` only for a breaking change.
  Mention the task id in the body (`Refs: WAY-482`, or `Fixes: WAY-482` when the merge completes it).
- **Versions** are never bumped by hand: this repository is not versioned; every merge to `main` is the new state.
- Stage only the files of your task; preserve other people's changes in the working tree.
- Never force-push, never amend or rebase a pushed commit, never bypass hooks (`--no-verify`).
