# Local Compose layout

| File | Holds |
| --- | --- |
| `compose/compose.local.yaml` | local Traefik on plain HTTP, `build: ../../cadenway-<x>` with `develop.watch`, Mailpit, Garage (local object store, `full` profile), `DOMAIN=cadenway.localhost`; creates `${COMPOSE_PROJECT_NAME}-edge-local` (`cadenway-edge-local` by default) |

- Locally the edge network is the project's: `compose.local.yaml` points `traefik.docker.network` at
  it, and its Traefik serves only the containers of its own project
  (`--providers.docker.constraints` on `com.docker.compose.project`), so two local stacks on one
  machine (`-p <name>`) never route to each other (`compose/tests/local-isolation.sh`).

Local start, from `compose/`: `cp .env.example .env` once, then `docker compose up -d`; `compose/.env` sets
`COMPOSE_FILE` and `COMPOSE_PROFILES` (`core`, or `full` for every service).
