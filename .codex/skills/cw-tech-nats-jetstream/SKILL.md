---
name: cw-tech-nats-jetstream
description: "Implement or review NATS JetStream messaging, subscriptions, delivery, or event publication for Cadenway."
---

# Nats Jetstream for Cadenway

Start from the producing service's AsyncAPI contract and existing outbox/event rules. In consuming services and gateways, use the published `@cadenway/nest-messaging` package instead of direct NATS clients; the service kit owns its implementation, and ops owns broker deployment. Preserve event versioning, transactional outbox behavior, idempotency and redelivery handling. Run relevant contract and integration checks when available, and coordinate producer before consumers.

The service kit builds on the `@nats-io/transport-node` and `@nats-io/jetstream` packages. Subjects (`evt.<event-name>`), the single `EVENTS` stream, durable consumer names, retries by delayed negative acknowledgement and the dead-letter stream are fixed by the `cw-outbox-design` skill of cadenway-service-kit: do not choose them per service.

Consult the official documentation for the version actually used: https://docs.nats.io/concepts/jetstream.
