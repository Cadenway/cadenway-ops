---
paths:
  - 'compose/**'
  - 'environments/*/services/**'
---

# Docker Compose

- `compose.yaml` includes `infra.yaml` and `${CADENWAY_SERVICES:-../environments/staging/services}/*.yaml`:
  the agent points it at `environments/<env>/services/`; locally it runs the staging definitions;
  `compose.local.yaml` adds development overrides only.
- Networks: `edge` (`cadenway-edge-<env>`, external, created by `edge.yaml`; Traefik and what it serves)
  and `internal`. Internal services have no Traefik label and no published port. Traefik router,
  service and network names carry `${ENVIRONMENT:-local}`.
- Images from GHCR with the version variable of `versions.env` (`${TASK_SERVICE_VERSION}`).
- Every service has a healthcheck, a memory limit and `restart: unless-stopped`.
- `environments/<env>/services/*.yaml` are copied from each service's `deploy/compose.yaml` by its
  deploy workflow: change them there.
