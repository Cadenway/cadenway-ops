---
name: cw-tech-postgresql
description: "Design or review PostgreSQL persistence, SQL, transactions, indexes, or migrations in Cadenway."
---

# Postgresql for Cadenway

Read the owning service's persistence and migration rules and its existing expand-contract skill. Each service owns its own database and credentials; do not introduce cross-service database access. Design parameterized queries, transactional invariants, tenant scoping, indexes, and backward-compatible migrations for the actual schema and deployment order. Never read Terraform state or secret environment files. Run targeted persistence and integration tests against disposable infrastructure when available.

Consult the official documentation for the version actually used: https://www.postgresql.org/docs/.
