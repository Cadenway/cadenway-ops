---
name: cw-tech-opentelemetry
description: "Implement or review OpenTelemetry traces and observability integration in Cadenway backends and operations."
---

# Opentelemetry for Cadenway

Inspect the owning repository's observability conventions and existing telemetry before adding instrumentation. The service kit owns shared technical plumbing, services and gateways consume it, and ops owns deployment configuration. Preserve trace context across relevant request and message boundaries, avoid sensitive data and unbounded labels, and verify through the available focused checks. Do not assume an exporter, collector or backend that the repository has not configured.

Traces and metrics leave through OTLP over HTTP, towards the endpoint named by `OTEL_EXPORTER_OTLP_ENDPOINT`; nothing is exported when it is unset. An ESM application starts with the instrumentation loader hook, and no instrumentation supports NestJS 12, so the service kit names the spans itself. The log fields, the redaction and the start-up command are in the `cw-logging-and-tracing` skill, where the repository has it.

Consult the official documentation for the version actually used: https://opentelemetry.io/docs/.
