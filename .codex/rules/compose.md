---
paths:
  - 'compose/**'
  - 'services/**'
---

# Docker Compose

- `compose.yaml` includes `infra.yaml` and `services/*.yaml`; `compose.local.yaml` adds development
  overrides only.
- Networks: `edge` (Traefik and what it serves) and `internal`. Internal services have no Traefik label
  and no published port.
- Images from GHCR with the version variable of `versions.env` (`${TASK_SERVICE_VERSION}`).
- Every service has a healthcheck, a memory limit and `restart: unless-stopped`.
- `services/*.yaml` are copied from each service's `deploy/compose.yaml` by CI: change them there.
