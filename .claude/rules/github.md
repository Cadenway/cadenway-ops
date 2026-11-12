---
paths:
  - '.github/**'
---

# GitHub files

- `.github/` belongs to this repository: README, community files, issue and pull request templates,
  code owners and workflows. Cadenway has no organization `.github` repository; nothing is inherited.
- Workflows are complete here: no reusable workflow called from another repository. The duplication
  across repositories is deliberate, like the TypeScript, Prettier and ESLint configurations.
- Every job declares minimal `permissions:`; third-party actions are pinned to a full commit SHA with
  the version in a comment; event data reaches `run:` only through `env:`; no `pull_request_target`.
- A workflow that writes to another repository (the deploy workflow writing into `cadenway-ops`) uses
  the organization GitHub App token inside a protected environment, never a personal token.
- The shared parts (code of conduct, security policy, issue and pull request templates) keep the same
  wording in every repository: a change here is repeated in the others through their own pull
  requests.
