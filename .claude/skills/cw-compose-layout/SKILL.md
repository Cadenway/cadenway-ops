---
name: cw-compose-layout
description: "How the Compose files of cadenway-ops fit together for production and local development, with networks, profiles and domains. Load it before changing Compose."
---

# Compose layout

| File | Holds |
| --- | --- |
| `compose/edge.yaml` | project `cadenway-edge`: the one Traefik of a host (80, 443, Let's Encrypt) and the networks `cadenway-edge-staging`, `cadenway-edge-prod` |
| `compose/compose.yaml` | one environment, project `cadenway-<env>`: `include:` of `infra.yaml` and `${CADENWAY_SERVICES:-../environments/staging/services}/<service>.yaml` |
| `compose/infra.yaml` | PostgreSQL (one database per service from `postgres/init/`), Redis, NATS JetStream, Meilisearch |
| `compose/compose.local.yaml` | local Traefik on plain HTTP, `build: ../../cadenway-<x>` with `develop.watch`, Mailpit, Garage (local object store, `full` profile), `DOMAIN=cadenway.localhost`; creates `${COMPOSE_PROJECT_NAME}-edge-local` (`cadenway-edge-local` by default) |
| `environments/<env>/services/<service>.yaml` | what the environment runs, written by the service's deploy workflow with its version; local development runs the staging ones |

- Exposed services join `edge` as `{ name: cadenway-edge-${ENVIRONMENT:-local}, external: true }`, set
  `traefik.docker.network` to it, and name their Traefik router and service
  `<service>-${ENVIRONMENT:-local}`: staging and production can share a host without sharing a network.
- Locally the edge network is the project's: `compose.local.yaml` points `traefik.docker.network` at
  it, and its Traefik serves only the containers of its own project
  (`--providers.docker.constraints` on `com.docker.compose.project`), so two local stacks on one
  machine (`-p <name>`) never route to each other (`compose/tests/local-isolation.sh`).
- On a host the agent sets `CADENWAY_SERVICES=../environments/<env>/services` and passes three env
  files: `/etc/cadenway/env/<env>.env` (Ansible), `versions.env`, the decrypted secrets (single-quoted).

Local start, from `compose/`: `cp .env.example .env` once, then `docker compose up -d`; `compose/.env` sets
`COMPOSE_FILE` and `COMPOSE_PROFILES` (`core`, or `full` for every service).
