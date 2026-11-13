---
name: cw-tech-object-storage
description: "Implement or review Cadenway object-storage attachments, S3-compatible access, or local Garage configuration."
---

# Object Storage for Cadenway

Storage-service owns attachment access and object lifecycle; ops owns OVH Object Storage and the local Garage deployment (`compose/compose.local.yaml`, `compose/garage/garage.toml`). Follow the repository's storage contracts, tenant boundaries, access controls and existing lifecycle conventions. Never read or output credentials or object contents not needed for the task. Use disposable test buckets or mocks for authorized checks and avoid mutating real buckets.

Consult the official documentation for the version actually used: https://garagehq.deuxfleurs.fr/documentation/ for the local store, https://docs.aws.amazon.com/AmazonS3/latest/API/ for the S3 API.
