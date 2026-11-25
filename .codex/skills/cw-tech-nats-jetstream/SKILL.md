---
name: cw-tech-nats-jetstream
description: "Implement or review NATS JetStream messaging, subscriptions, delivery, or event publication for Cadenway."
---

# Nats Jetstream for Cadenway

Start from the producing service's AsyncAPI contract and existing outbox/event rules. In consuming services and gateways, use the published `@cadenway/nest-messaging` package instead of direct NATS clients; the service kit owns its implementation, and ops owns broker deployment. Preserve event versioning, transactional outbox behavior, idempotency and redelivery handling. Run relevant contract and integration checks when available, and coordinate producer before consumers.

The service kit builds on the `@nats-io/transport-node` and `@nats-io/jetstream` packages. Use its
`cw-outbox-design` guidance for subjects, durable consumer names and delayed negative
acknowledgements. Cadenway Ops provisions the `EVENTS`, `EVENTS_RESTRICTED` and `EVENTS_DLQ`
streams, and the `REALTIME_AUTHORIZATION_ADVISORIES` latch of the realtime gateway, whose subjects
follow its invalidation handlers. See `cadenway-ops/docs/messaging.md` for stream purposes and
permissions.

Consult the official documentation for the version actually used: https://docs.nats.io/concepts/jetstream.
