FROM docker:28.5.2-cli@sha256:625d9431a9f54c5a2bc90f24f0e1c3d55b1349fd857dd85035f98c2c9acbdd4d
COPY tests/e2e.sh /tmp/backup-e2e.sh
RUN apk add --quiet --no-cache bash && bash /tmp/backup-e2e.sh --prepare-runner && rm /tmp/backup-e2e.sh
CMD ["bash", "/backup/tests/e2e.sh"]
