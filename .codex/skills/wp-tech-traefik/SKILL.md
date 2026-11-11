---
name: wp-tech-traefik
description: "Configure or review Traefik routing, TLS, middleware, and service exposure in Waypoint."
---

# Traefik for Waypoint

Start from the Waypoint ops Compose and Traefik conventions, then inspect the requested router, entrypoint, middleware, and target service. Preserve the intended public endpoints and internal network boundaries; internal services must not gain public routes. Do not expose secrets or invent production domains. Validate the relevant Compose and configuration files with existing checks without deploying.

Consult the official documentation for the version actually used: https://doc.traefik.io/traefik/.
