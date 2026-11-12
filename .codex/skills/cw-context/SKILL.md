---
name: cw-context
description: "What Cadenway is, where the mockup, the integration guide and the repository map live, the product vocabulary (spaces, lists, sprints, tasks, statuses, milestones) and the multi-repository ownership rules. Load it before any decision that depends on the product or on another repository."
---

# Cadenway context

Cadenway is a French work-management product (spaces, lists, sprints, tasks, goals, documents,
Git integration), in the spirit of ClickUp or Linear. The organization in every fixture is
**Atelier Nord**; the signed-in user is **Camille Martin** (`CM`); the demo date is 8 November 2026
and the demo sprint is **Sprint 14** (3 to 17 November).

## Sources of truth

| Source | What it settles |
| --- | --- |
| [Interactive mockup](https://claude.ai/artifact/KYRM7AnsYLiBLBLKy8i4HE) (19 artboards) | Every screen, state and interaction. When this repository and the mockup disagree on behavior, the mockup wins until a decision says otherwise. |
| [Integration guide](https://claude.ai/artifact/CpJHVCiFfF9j3KbHQ2S1Et) | Design tokens, data shapes, component names (`cw-*`), behaviors, Angular 22 mapping, what the mockup only simulates. |
| [Repositories and packages](https://claude.ai/artifact/BPinmYxoF3mbK8w9BMB43N) | The 18 repositories, their data, APIs, events, deployment (Docker Compose, Traefik, Ansible, Terraform, GitOps agent) and open decisions. |
| `../cadenway-api-contracts` | The only definition of public routes (OpenAPI) and events (AsyncAPI). |

## Vocabulary

| Term | Meaning |
| --- | --- |
| Space (`Espace`) | Top container, with a prefix for task ids (`CAD`, `DES`, `MKT`, `OPS`), its own status names and privacy. |
| List / sprint | A list of tasks in a space; a sprint is a dated list with a goal. |
| Task | Id `CAD-482`; 10 statuses in 3 categories (open, active, closed); subtasks up to 3 levels and 25 children; checklist; dependencies without cycles. |
| Milestone (`jalon`) | A dated task without duration; only 4 statuses: À venir, À risque, Atteint, Annulé. |
| Status keys | `triage`, `backlog`, `todo`, `progress`, `review`, `testing`, `waiting`, `blocked`, `done`, `cancelled`. Counters read the category, never the key. |
| Priority keys | `urgente`, `haute`, `moyenne` (default), `basse`. |

## Ownership across repositories

- Each repository owns its data and decisions; the others reach it only through
  `cadenway-api-contracts` (routes, events) and the published `@cadenway/*` packages.
- Coordinate producer contracts, generated packages and consumers **in that order**; every step only
  adds, so each repository ships alone.
- Sibling checkouts are read-only from here. A need in another repository is written as a request
  for its owner (its `cw-*` agents), never as an edit from this session.
- Use published package versions. No `npm link`, no `file:` dependency, no TypeScript alias into a
  sibling's sources, no copied implementation.
