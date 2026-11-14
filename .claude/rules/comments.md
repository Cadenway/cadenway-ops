---
paths:
  - '**/*.yml'
  - '**/*.yaml'
  - '**/*.tf'
  - 'agent/**'
---

# Comments and documentation

- Explain why: record operational constraints, failure modes, ordering, recovery and security
  decisions where they matter. Do not restate a task, variable or resource name.
- Document public Terraform inputs and outputs with their native `description`; document Ansible
  roles and variables in their existing role documentation. Explain shell functions and interfaces
  with comments appropriate to shell, not TypeScript JSDoc.
- Cite the relevant runbook or decision when it constrains behavior. Keep documentation current,
  never include secret values, and do not add commented-out code or TODOs without a task ID.
- Run the repository's applicable formatting, Terraform, Ansible and shell checks for changed files.
  Do not claim TypeScript or UI-specific ESLint checks apply to this infrastructure repository.

## Detailed examples and review

Write repository comments and documentation in English. Explain constraints, ordering, operational
consequences and recovery decisions, not the syntax of a task or resource. Place comments next to the
relevant declaration and update them in the same change. Never copy real secrets, keys, decrypted
environment contents, Terraform state or personal data into comments, examples or logs. Do not leave
commented-out commands or a TODO without a task ID.

### Terraform

- Give public `variable` and `output` blocks a useful native `description` explaining meaning,
  units, expected values and sensitivity when applicable. Add `type`, validation and `sensitive`
  where appropriate; a description must not claim a property the code does not enforce.
- Comment resource dependencies or ordering only when their reason is not apparent. Keep examples
  generic and never hard-code an actual tenant, host, address or credential.

```hcl
variable "retention_days" {
  description = "Number of days to retain backup archives."
  type        = number
}
```

### Ansible and Compose

- Document the purpose and accepted values of role variables in their role documentation. Explain
  non-obvious idempotence, privilege boundaries, handlers and required ordering at the relevant task.
- Document Compose environment variables and health checks in the appropriate service documentation
  or example configuration. Explain exposure, dependencies and startup behavior only where useful.
  Do not use TypeScript JSDoc or class region markers in YAML or HCL.

### Shell and runbooks

- Document an externally invoked script or non-obvious function with its purpose, arguments,
  expected environment, exit behavior and side effects. Quote variables and follow the repository's
  shell conventions; do not place comments in lieu of error handling.
- Link the relevant deploy, recovery, restore or rotation runbook when it explains an operational
  choice. State preconditions and rollback limits accurately and keep instructions consistent.

```sh
# Checks whether a service is listed as running.
# Arguments: service name.
# Returns success when the service is listed as running.
is_service_running() {
  docker compose ps --status running --services | grep -Fx -- "$1"
}
```

### Verification

Review operational claims against the implementation and check links and examples. Run the scoped
formatter and the Terraform, Ansible or shell validation applicable to the files changed. These
instructions do not install an automatic comment linter; do not report a check that did not run.
