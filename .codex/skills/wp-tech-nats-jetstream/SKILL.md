---
name: wp-tech-nats-jetstream
description: "Implement or review NATS JetStream messaging, subscriptions, delivery, or event publication for Waypoint."
---

# Nats Jetstream for Waypoint

Start from the producing service's AsyncAPI contract and existing outbox/event rules. In consuming services and gateways, use the published `@waypoint/nest-messaging` package instead of direct NATS clients; the service kit owns its implementation, and ops owns broker deployment. Preserve event versioning, transactional outbox behavior, idempotency and redelivery handling. Run relevant contract and integration checks when available, and coordinate producer before consumers.

Consult the official documentation for the version actually used: https://docs.nats.io/concepts/jetstream.
