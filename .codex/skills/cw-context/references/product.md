# Product vocabulary and fixtures

Cadenway is a French work-management product (spaces, lists, sprints, tasks, goals, documents,
Git integration), in the spirit of ClickUp or Linear. The organization in every fixture is
**Atelier Nord**; the signed-in user is **Camille Martin** (`CM`); the demo date is 8 November 2026
and the demo sprint is **Sprint 14** (3 to 17 November).

## Vocabulary

| Term | Meaning |
| --- | --- |
| Space (`Espace`) | Top container, with a prefix for task ids (`CAD`, `DES`, `MKT`, `OPS`), its own status names and privacy. |
| List / sprint | A list of tasks in a space; a sprint is a dated list with a goal. |
| Task | Id `CAD-482`; 10 statuses in 3 categories (open, active, closed); subtasks up to 3 levels and 25 children; checklist; dependencies without cycles. |
| Milestone (`jalon`) | A dated task without duration; only 4 statuses: À venir, À risque, Atteint, Annulé. |
| Status keys | `triage`, `backlog`, `todo`, `progress`, `review`, `testing`, `waiting`, `blocked`, `done`, `cancelled`. Counters read the category, never the key. |
| Priority keys | `urgente`, `haute`, `moyenne` (default), `basse`. |
