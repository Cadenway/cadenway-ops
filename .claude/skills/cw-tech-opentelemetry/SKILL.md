---
name: cw-tech-opentelemetry
description: "Implement or review OpenTelemetry traces and observability integration in Cadenway backends and operations."
---

# Opentelemetry for Cadenway

Inspect the owning repository's observability conventions and existing telemetry before adding instrumentation. The service kit owns shared technical plumbing, services and gateways consume it, and ops owns deployment configuration. Preserve trace context across relevant request and message boundaries, avoid sensitive data and unbounded labels, and verify through the available focused checks. Do not assume an exporter, collector or backend that the repository has not configured.

Consult the official documentation for the version actually used: https://opentelemetry.io/docs/.
