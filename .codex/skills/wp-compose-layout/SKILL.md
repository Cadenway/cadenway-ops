---
name: wp-compose-layout
description: "How the Compose files of waypoint-ops fit together for production and local development, with networks, profiles and domains. Load it before changing Compose."
---

# Compose layout

| File | Holds |
| --- | --- |
| `compose/compose.yaml` | `include:` of `infra.yaml` and `../services/*.yaml` |
| `compose/infra.yaml` | Traefik, PostgreSQL (one database per service from `postgres/init/`), Redis, NATS JetStream, Meilisearch |
| `compose/compose.local.yaml` | `build: ../../waypoint-<x>` with `develop.watch`, MinIO, Mailpit, `DOMAIN=waypoint.localhost` |
| `services/<service>.yaml` | copied from each service's `deploy/compose.yaml` |

Local start: `docker compose -f compose.yaml -f compose.local.yaml --profile core up -d` from `compose/`.
