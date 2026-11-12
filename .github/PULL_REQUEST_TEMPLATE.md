<!--
Title: Conventional Commits, for example `feat(tasks): add sprint burndown`. It becomes the squash
commit on main. See .github/CONTRIBUTING.md.
-->

## Task

Fixes: CAD-

<!-- Use `Refs: CAD-…` instead when this pull request does not complete the task. -->

## Summary

<!-- What changes and why, in a few lines. -->

## Checks run

<!-- Tick what you ran locally. A check you did not run stays unticked, with the reason. -->

- [ ] `docker compose -f compose/compose.yaml -f compose/compose.local.yaml config -q`
- [ ] `yamllint .`
- [ ] `ansible-lint ansible/`
- [ ] `ansible-playbook --syntax-check ansible/playbooks/setup.yml`
- [ ] `terraform -chdir=terraform fmt -check`
- [ ] `terraform -chdir=terraform validate`
- [ ] `shellcheck agent/*.sh`

## Impact

- [ ] Environments affected: <!-- local, staging, prod -->
- [ ] `terraform plan` summary attached (resources added, changed, destroyed)
- [ ] Encrypted secrets changed (`secrets.sops.env`), values never shown
- [ ] Rollback: <!-- how to undo this change -->
