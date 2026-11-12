---
name: cw-tech-meilisearch
description: "Implement or review Cadenway search indexing, query behavior, or Meilisearch deployment."
---

# Meilisearch for Cadenway

The search service owns search-index behavior, while ops owns deployment. Inspect existing domain, event and search contracts before changing index documents, asynchronous updates, filtering, ranking, or authorization boundaries. Treat the index as derived data and design for retries and rebuilds according to existing repository rules. Run the relevant search and integration checks when available.

Consult the official documentation for the version actually used: https://www.meilisearch.com/docs.
