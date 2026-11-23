# Staging telemetry

This optional project receives OTLP/HTTP from staging services on
`http://cadenway-staging-otel:4318`. The collector exposes its metrics to Prometheus and forwards
traces to Tempo. Prometheus retains data in its default local volume and Tempo retains trace blocks
for 48 hours. The services join the staging internal network and publish no host ports.

An operator can run `ansible-playbook ansible/playbooks/observability.yml --limit <staging-host>`
after the GitOps agent has created `cadenway-staging_internal`. The playbook installs a systemd
unit separate from the GitOps service. Configure the OTLP endpoint in the staging service
definitions after the project is reachable. Containers must be restarted to pick up that setting.

The collector image is distroless and has no HTTP probe executable. Check its live scrape from
the Prometheus container with `docker compose exec prometheus promtool query instant
http://localhost:9090 up`. The `otel-collector` target must report `1`. Check Tempo with
`docker compose exec tempo /busybox/wget -qO- http://localhost:3200/ready`. Tempo may take about
a minute to become ready. The GitOps agent's existing webhook reports deployment failures.
