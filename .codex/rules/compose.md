---
paths:
  - 'compose/**'
  - 'environments/*/services/**'
---

# Docker Compose

Use `cw-compose-layout` for hosted and local Compose, including the `infra.yaml` and
`CADENWAY_SERVICES` includes, staging definitions for local development and edge naming with
`${ENVIRONMENT:-local}`. Keep local overrides in `compose.local.yaml`. Internal services have no
Traefik labels or published ports.

Use GHCR images with `versions.env` variables such as `${TASK_SERVICE_VERSION}`. Every service
needs a healthcheck, a memory limit and `restart: unless-stopped`. Change source definitions in
the owner service's `deploy/compose.yaml`; deployment copies them into the environment.

## Review example

For example, a worker may need a different memory limit or number of replicas. Before changing
it, document the observed bottleneck and check the total PostgreSQL connections across replicas.
Validate the affected Compose definitions and preserve the existing health and network boundaries.
