# The collector image is distroless. BusyBox supplies the local health probe.
FROM otel/opentelemetry-collector-contrib:0.165.0@sha256:e40d61f10c9a617cca1ffd1be4d7e2b3a4b0f0001798ff07e58cabe82e618cea AS collector
FROM busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
COPY --from=collector /otelcol-contrib /otelcol-contrib
USER 10001:10001
ENTRYPOINT ["/otelcol-contrib"]
