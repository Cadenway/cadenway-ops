---
paths:
  - '.github/**'
---

# GitHub files

- Own this checkout's GitHub README, community files, templates, code owners and workflows.
  Cadenway has no organization `.github` repository or cross-repository reusable workflows.
  Keep workflows complete here. Duplication is deliberate, as for TypeScript, Prettier and ESLint.
- Every job declares minimal `permissions:`; third-party actions are pinned to a full commit SHA with
  the version in a comment; event data reaches `run:` only through `env:`; no `pull_request_target`.
- A workflow that writes to another repository (the deploy workflow writing into `cadenway-ops`) uses
  the organization GitHub App token inside a protected environment, never a personal token.
- Keep the code of conduct, security policy and issue and PR templates aligned by submitting
  changes through each affected repository's own PR.
