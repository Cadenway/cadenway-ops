---
name: wp-tech-github-actions
description: "Create or review GitHub Actions workflows and CI configuration in a Waypoint repository."
---

# Github Actions for Waypoint

Each repository owns its complete `.github/` workflows; do not depend on an organization-wide or sibling reusable workflow. Follow its GitHub and commit rules: minimal permissions, third-party actions pinned to full commit SHAs, and no `pull_request_target` on untrusted code. Keep secrets out of logs and files. Use existing workflow validation tools when available and never push to main, bypass hooks, publish, or tag from an agent shell.

Consult the official documentation for the version actually used: https://docs.github.com/en/actions.
